/**
 * FileAnalysisService - Main service for file analysis operations
 *
 * 使用本地处理进行文件解析、OCR、分类
 * 使用云端LLM进行语义描述和高级分析
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { FileRecord, FileStatus, CategoryScore, FileMetadata } from '../models/Index';
import { DatabaseManager } from '../database/Index';
import { DataParser, ParseConfig, ImageParser, PDFParser, TextParser } from '../parser/Index';
import { SemanticRepresentation, SemanticClustering } from '../semantic/Index';
import { ApiService } from './ApiService';
import { LocalOCRService } from './LocalOCRService';
import { LocalClassificationService, ClassificationResult } from './LocalClassificationService';
import { LocalImageAnalysisService } from './LocalImageAnalysisService';
import { EmbeddingService } from '../semantic/EmbeddingService';

export interface ScanResult {
  totalFiles: number;
  successCount: number;
  failCount: number;
  files: FileRecord[];
}

export interface AnalysisProgress {
  current: number;
  total: number;
  currentFile: string;
  status: string;
}

export interface AnalyzeFilesResult {
  success: number;
  failed: number;
}

export class FileAnalysisService {
  private context: common.Context;
  private dbManager: DatabaseManager;
  private dataParser: DataParser;
  private semanticRep: SemanticRepresentation;
  private semanticClustering: SemanticClustering;
  private localClassificationService: LocalClassificationService;
  private embeddingService: EmbeddingService;
  private apiService: ApiService | null = null;

  constructor(context: common.Context) {
    this.context = context;
    this.dbManager = new DatabaseManager(context);
    const config = new ParseConfig(1, 256);
    this.dataParser = new DataParser(config);
    this.semanticRep = new SemanticRepresentation();
    this.semanticClustering = new SemanticClustering();
    this.localClassificationService = new LocalClassificationService();
    this.embeddingService = new EmbeddingService();
  }

  setApiService(apiService: ApiService): void {
    this.apiService = apiService;
  }

  async initialize(): Promise<void> {
    await this.dbManager.initialize();
    await this.semanticRep.initialize();
    this.semanticRep.setContext(this.context);
    this.semanticClustering.initialize();
    await this.embeddingService.setContext(this.context);
    await this.embeddingService.initialize();

    // Try to connect to backend API
    if (this.apiService) {
      this.semanticRep.setApiService(this.apiService);
      try {
        const health = await this.apiService.checkHealth();
        console.info('[FileAnalysisService] Backend API connected, models_loaded:', health.models_loaded);
      } catch (err) {
        console.warn('[FileAnalysisService] Backend API not available, using local processing');
      }
    }
  }

  async scanDirectory(
    directoryPath: string,
    recursive: boolean = true
  ): Promise<ScanResult> {
    const result: ScanResult = {
      totalFiles: 0,
      successCount: 0,
      failCount: 0,
      files: []
    };

    try {
      // Try backend API scan first
      if (this.apiService && this.apiService.isConnected()) {
        try {
          const scanResponse = await this.apiService.scanDirectory(directoryPath, recursive);
          for (const fileInfo of scanResponse.files) {
            try {
              const fileRecord = await this.addFileToDatabase(
                fileInfo.path,
                directoryPath
              );
              if (fileRecord) {
                result.files.push(fileRecord);
                result.successCount++;
              }
            } catch (err) {
              console.error(`[FileAnalysisService] Failed to add file ${fileInfo.path}:`, err);
              result.failCount++;
            }
          }
          result.totalFiles = scanResponse.total;
          return result;
        } catch (err) {
          console.warn('[FileAnalysisService] Backend scan failed, using local scan');
        }
      }

      // Local fallback
      const files = await this.listFiles(directoryPath, recursive);
      result.totalFiles = files.length;

      for (const filePath of files) {
        try {
          const fileRecord = await this.addFileToDatabase(filePath, directoryPath);
          if (fileRecord) {
            result.files.push(fileRecord);
            result.successCount++;
          }
        } catch (err) {
          console.error(`[FileAnalysisService] Failed to add file ${filePath}:`, err);
          result.failCount++;
        }
      }
    } catch (err) {
      console.error('[FileAnalysisService] Failed to scan directory:', err);
    }

    return result;
  }

  async analyzeFile(
    fileId: number,
    onProgress?: (progress: AnalysisProgress) => void
  ): Promise<boolean> {
    const fileRecord = await this.dbManager.getFileById(fileId);
    if (!fileRecord) {
      console.error('[FileAnalysisService] File not found:', fileId);
      return false;
    }

    // Try backend API analysis first
    if (this.apiService && this.apiService.isConnected()) {
      try {
        if (onProgress) {
          onProgress({
            current: 0,
            total: 3,
            currentFile: fileRecord.fileName,
            status: 'Backend analysis'
          });
        }

        const analyzeResponse = await this.apiService.analyzeFile(fileRecord.filePath);
        if (analyzeResponse.file_id > 0) {
          // Update local database with results
          const categories: CategoryScore[] = [];
          for (const cat of analyzeResponse.categories) {
            const score = new CategoryScore();
            score.category = cat.category;
            score.confidence = cat.confidence;
            categories.push(score);
          }
          await this.dbManager.updateFileSemanticCategories(fileId, categories);
          await this.dbManager.updateFileStatus(fileId, FileStatus.PRELIMINARY);

          if (onProgress) {
            onProgress({
              current: 3,
              total: 3,
              currentFile: fileRecord.fileName,
              status: 'Done'
            });
          }
          return true;
        }
      } catch (err) {
        console.warn('[FileAnalysisService] Backend analysis failed, using local:', err);
      }
    }

    // Local fallback
    return this.localAnalyzeFile(fileRecord, onProgress);
  }

  private async localAnalyzeFile(
    fileRecord: FileRecord,
    onProgress?: (progress: AnalysisProgress) => void
  ): Promise<boolean> {
    try {
      if (onProgress) {
        onProgress({
          current: 0,
          total: 4,
          currentFile: fileRecord.fileName,
          status: 'Parsing'
        });
      }

      const dataBlocks = await this.dataParser.parseFile(fileRecord.filePath);

      for (const block of dataBlocks) {
        await this.dbManager.addDataBlock(
          block.blockId,
          fileRecord.id,
          block.modality.toString(),
          block.addr ?? block.filePath ?? '',  // 使用block.addr，与Python一致
          block.pageNumber,
          JSON.stringify(block.position || {}),
          JSON.stringify(block.metadata || {})
        );
      }

      await this.dbManager.updateFileStatus(fileRecord.id, FileStatus.PARSED);

      const dbDataBlocks = await this.dbManager.getDataBlocksByFile(fileRecord.id);
      const blockIdToDbId: Map<string, number> = new Map();
      for (const db of dbDataBlocks) {
        blockIdToDbId.set(db.blockId, db.id);
      }

      if (onProgress) {
        onProgress({
          current: 1,
          total: 4,
          currentFile: fileRecord.fileName,
          status: 'Semantic representation'
        });
      }

      this.semanticRep.setDatabaseManager(this.dbManager);
      const semanticBlocks = await this.semanticRep.representBatch(dataBlocks, fileRecord);

      const semanticFilename = this.semanticRep.getMeaningfulFilenamePart(fileRecord.fileName);
      if (semanticFilename) {
        await this.dbManager.updateFileSemanticFilename(fileRecord.id, semanticFilename);
      }

      for (const semanticBlock of semanticBlocks) {
        const dataBlockIds: number[] = [];
        if (semanticBlock.originalMetadata && semanticBlock.originalMetadata['sourceBlockId']) {
          const sourceId = semanticBlock.originalMetadata['sourceBlockId'] as string;
          const dbId = blockIdToDbId.get(sourceId);
          if (dbId) {
            dataBlockIds.push(dbId);
          }
        } else {
          for (const dbBlock of dbDataBlocks) {
            dataBlockIds.push(dbBlock.id);
          }
        }

        const vectorBytes = semanticBlock.semanticVector && semanticBlock.semanticVector.length > 0
          ? new Uint8Array(new Float32Array(semanticBlock.semanticVector).buffer)
          : new Uint8Array(0);

        await this.dbManager.addSemanticBlock(
          semanticBlock.blockId,
          dataBlockIds,
          fileRecord.id,
          semanticBlock.textDescription,
          semanticBlock.keywords,
          vectorBytes,
          semanticFilename,
          {}
        );

        // 向量存储暂时跳过（HMS Retrieval Kit 不提供独立 embedding 生成）
          // TODO: 集成 aip-data-intelligence-embedding 服务后重新实现向量存储
          /*
          try {
            await this.embeddingService.storeText(
              semanticBlock.blockId,
              semanticBlock.textDescription,
              { 'fileId': fileRecord.id, 'fileName': fileRecord.fileName }
            );
          } catch (embedErr) {
            console.warn('[FileAnalysisService] Failed to store embedding:', embedErr);
          }
          */
      }

      if (onProgress) {
        onProgress({
          current: 2,
          total: 4,
          currentFile: fileRecord.fileName,
          status: 'Classification'
        });
      }

      const categories: CategoryScore[] = [];
      const isImage = this.isImageFile(fileRecord.fileType);

      for (const semanticBlock of semanticBlocks) {
        const defaultResult = this.localClassificationService.classifyBySemanticBlock(semanticBlock);

        await this.dbManager.addClassificationResult(
          fileRecord.id,
          semanticBlock.blockId,
          defaultResult.categoryName,
          defaultResult.confidence,
          defaultResult.allScores,
          '默认类别体系'
        );

        const blockMetadata: Record<string, Record<string, number>> = {};
        blockMetadata['默认类别体系'] = defaultResult.allScores;

        if (isImage) {
          const imageResult = this.localClassificationService.classifyBySemanticBlock(semanticBlock);
          await this.dbManager.addClassificationResult(
            fileRecord.id,
            semanticBlock.blockId,
            imageResult.categoryName,
            imageResult.confidence,
            imageResult.allScores,
            '图片数据默认分类'
          );
          blockMetadata['图片数据默认分类'] = imageResult.allScores;
        }

        await this.dbManager.updateSemanticBlockMetadata(semanticBlock.blockId, blockMetadata);

        const existingCat = categories.find(c => c.category === defaultResult.categoryName);
        if (!existingCat) {
          const cat = new CategoryScore();
          cat.category = defaultResult.categoryName;
          cat.confidence = defaultResult.confidence;
          categories.push(cat);
        }
      }

      if (onProgress) {
        onProgress({
          current: 3,
          total: 4,
          currentFile: fileRecord.fileName,
          status: 'Updating metadata'
        });
      }

      await this.dbManager.updateFileSemanticCategories(fileRecord.id, categories);
      await this.dbManager.updateFileStatus(fileRecord.id, FileStatus.PRELIMINARY);

      if (isImage) {
        try {
          const imageService = new LocalImageAnalysisService();
          imageService.setContext(this.context);
          const metadata = await imageService.extractImageMetadata(fileRecord.filePath);
          const existingMetadata: FileMetadata = fileRecord.metadata || {} as FileMetadata;
          existingMetadata['width'] = metadata.width;
          existingMetadata['height'] = metadata.height;
          existingMetadata['format'] = metadata.format;
          if (metadata.dateTime) {
            existingMetadata['dateTime'] = metadata.dateTime;
          }
          if (metadata.make) {
            existingMetadata['make'] = metadata.make;
          }
          if (metadata.model) {
            existingMetadata['model'] = metadata.model;
          }
          if (metadata.gpsLatitude && metadata.gpsLongitude) {
            existingMetadata['gpsLatitude'] = metadata.gpsLatitude;
            existingMetadata['gpsLongitude'] = metadata.gpsLongitude;
          }
          await this.dbManager.updateFileMetadata(fileRecord.id, existingMetadata);

          const originalCreatedTime = imageService.formatDateTime(metadata);
          const location = await imageService.formatLocationAsync(metadata);  // 使用异步版本获取精确地名
          const hasInfo = !!(originalCreatedTime || location);
          const status = hasInfo ? '已分析有信息' : '已分析无信息';
          await this.dbManager.updateSpatiotemporalStatus(fileRecord.id, status, originalCreatedTime, location);
        } catch (imgErr) {
          console.warn('[FileAnalysisService] Image metadata extraction failed:', imgErr);
        }
      }

      if (onProgress) {
        onProgress({
          current: 4,
          total: 4,
          currentFile: fileRecord.fileName,
          status: 'Done'
        });
      }

      return true;
    } catch (err) {
      console.error('[FileAnalysisService] Local analysis failed:', err);
      return false;
    }
  }

  /**
   * 将 Unix 时间戳转换为 YYYY-MM-DD HH:MM:SS 格式
   */
  private formatTimestampToDateTime(timestamp: number): string {
    const date = new Date(timestamp * 1000);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    const second = String(date.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  }

  private isImageFile(fileType: string): boolean {
    const imageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'tif', 'webp', 'heic', 'heif'];
    return imageExtensions.some(ext => fileType.toLowerCase() === ext);
  }

  async analyzeFiles(
    fileIds: number[],
    onProgress?: (progress: AnalysisProgress) => void
  ): Promise<AnalyzeFilesResult> {
    const result: AnalyzeFilesResult = { success: 0, failed: 0 };

    for (let i = 0; i < fileIds.length; i++) {
      const success = await this.analyzeFile(fileIds[i], (p) => {
        if (onProgress) {
          onProgress({
            current: i * 3 + p.current,
            total: fileIds.length * 3,
            currentFile: p.currentFile,
            status: p.status
          });
        }
      });

      if (success) {
        result.success++;
      } else {
        result.failed++;
      }
    }

    return result;
  }

  async searchFiles(queryText: string, topK: number = 10): Promise<FileRecord[]> {
    // Try backend API first
    if (this.apiService && this.apiService.isConnected()) {
      try {
        const searchResponse = await this.apiService.search(queryText, topK);
        const results: FileRecord[] = [];
        for (const fileResult of searchResponse.results) {
          const record = await this.dbManager.getFileById(fileResult.file_id);
          if (record) {
            results.push(record);
          }
        }
        return results;
      } catch (err) {
        console.warn('[FileAnalysisService] Backend search failed, using local');
      }
    }

    // 本地向量搜索暂时跳过（HMS Retrieval Kit 不提供独立 embedding 生成）
    // TODO: 集成 aip-data-intelligence-embedding 服务后重新实现向量检索
    /*
    try {
      const vectorResults = await this.embeddingService.searchSimilar(queryText, topK);
      if (vectorResults.length > 0) {
        const results: FileRecord[] = [];
        for (const vr of vectorResults) {
          // 从metadata中获取fileId
          const fileId = vr.metadata?.['fileId'] as number;
          if (fileId) {
            const record = await this.dbManager.getFileById(fileId);
            if (record) {
              results.push(record);
            }
          }
        }
        if (results.length > 0) {
          return results;
        }
      }
    } catch (err) {
      console.warn('[FileAnalysisService] Vector search failed, using name search');
    }
    */

    // Fallback: name-based search
    const files = await this.dbManager.getAllFiles();
    const results: FileRecord[] = [];
    const queryLower = queryText.toLowerCase();

    for (const file of files) {
      if (file.fileName.toLowerCase().includes(queryLower) ||
        file.filePath.toLowerCase().includes(queryLower)) {
        results.push(file);
        if (results.length >= topK) break;
      }
    }

    return results;
  }

  async getFilesByCategory(category: string): Promise<FileRecord[]> {
    const files = await this.dbManager.getAllFiles();
    const results: FileRecord[] = [];
    for (const file of files) {
      for (const c of file.semanticCategories) {
        if (c.category === category) {
          results.push(file);
          break;
        }
      }
    }
    return results;
  }

  async getFileById(fileId: number): Promise<FileRecord | null> {
    return await this.dbManager.getFileById(fileId);
  }

  async deleteFile(fileId: number): Promise<boolean> {
    return await this.dbManager.deleteFile(fileId);
  }

  async close(): Promise<void> {
    await this.semanticRep.release();
    await this.embeddingService.release();
  }

  // ============ Private helpers ============

  private async listFiles(
    directoryPath: string,
    recursive: boolean
  ): Promise<string[]> {
    const files: string[] = [];
    const supportedExtensions = this.dataParser.getSupportedExtensions();

    try {
      await this.traverseDirectory(directoryPath, recursive, files, supportedExtensions);
    } catch (err) {
      console.error('[FileAnalysisService] Failed to list files:', err);
    }

    return files;
  }

  private async traverseDirectory(
    dirPath: string,
    recursive: boolean,
    files: string[],
    extensions: string[]
  ): Promise<void> {
    try {
      const list = await fileIo.listFile(dirPath);

      for (const fileName of list) {
        const fullPath = `${dirPath}/${fileName}`;

        try {
          const stat = await fileIo.stat(fullPath);

          if (stat.isDirectory() && recursive) {
            await this.traverseDirectory(fullPath, recursive, files, extensions);
          } else if (stat.isFile()) {
            const ext = fileName.split('.').pop()?.toLowerCase();
            if (ext && this.containsExtension(extensions, ext)) {
              files.push(fullPath);
            }
          }
        } catch (err) {
          console.error(`[FileAnalysisService] Failed to stat ${fullPath}:`, err);
        }
      }
    } catch (err) {
      console.error(`[FileAnalysisService] Failed to traverse ${dirPath}:`, err);
    }
  }

  private containsExtension(extensions: string[], ext: string): boolean {
    for (const e of extensions) {
      if (e === ext) return true;
    }
    return false;
  }

  private async addFileToDatabase(
    filePath: string,
    directoryPath: string
  ): Promise<FileRecord | null> {
    try {
      const stat = await fileIo.stat(filePath);
      const fileName = filePath.split('/').pop() || '';
      const fileType = fileName.split('.').pop() || '';

      // 将Unix时间戳转换为datetime格式字符串
      const modifiedTimeStr = this.formatTimestampToDateTime(Number(stat.mtime));
      const createdTimeStr = this.formatTimestampToDateTime(Number(stat.atime));

      const fileId = await this.dbManager.addFile(
        filePath,
        fileName,
        stat.size,
        fileType,
        modifiedTimeStr,
        createdTimeStr,
        directoryPath
      );

      if (fileId > 0) {
        const record = await this.dbManager.getFileById(fileId);
        return record || null;
      }
    } catch (err) {
      console.error(`[FileAnalysisService] Failed to add file to database:`, err);
    }

    return null;
  }
}
