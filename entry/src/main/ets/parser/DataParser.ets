﻿import { DataBlock, ModalityType, FileRecord, DataBlockBatchItem, SemanticBlockBatchItem, SemanticBlock, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { PDFParser } from './PDFParser';
import { ImageParser } from './ImageParser';
import { TextParser } from './TextParser';
import { WordParser } from './WordParser';
import { ExcelParser } from './ExcelParser';
import { PptParser } from './PptParser';
import { SemanticRepresentation } from '../semantic/Index';
import { FilenameSemanticAnalyzer, FilenameAnalysisResult } from '../semantic/FilenameSemanticAnalyzer';
import { DatabaseManager } from '../database/DatabaseManager';

/**
 * 解析模式配置
 */
export class ParseConfig {
  mode: number = 1; // 1=light, 2=deep
  lightModeMaxLength: number = 256;
  generateSemantic: boolean = true;
  storeToDatabase: boolean = false;

  constructor(mode?: number, lightModeMaxLength?: number, generateSemantic?: boolean, storeToDatabase?: boolean) {
    if (mode !== undefined) this.mode = mode;
    if (lightModeMaxLength !== undefined) this.lightModeMaxLength = lightModeMaxLength;
    if (generateSemantic !== undefined) this.generateSemantic = generateSemantic;
    if (storeToDatabase !== undefined) this.storeToDatabase = storeToDatabase;
  }
}

/**
 * 解析结果（包含数据块和语义块）
 */
export interface ParseResult {
  dataBlocks: DataBlock[];
  semanticBlocks: SemanticBlock[];
  fileId: number;
  processingTime: number;
  parsingMode: string;
}

export class DataParser {
  private parsers: Map<string, BaseParser> = new Map();
  private config: ParseConfig;
  private semanticRepresentation: SemanticRepresentation | null = null;
  private filenameAnalyzer: FilenameSemanticAnalyzer;
  private dbManager: DatabaseManager | null = null;

  constructor(config?: ParseConfig) {
    this.config = config !== undefined ? config : new ParseConfig();
    this.filenameAnalyzer = new FilenameSemanticAnalyzer();
    this.initializeParsers();
  }

  setSemanticRepresentation(representation: SemanticRepresentation): void {
    this.semanticRepresentation = representation;
  }

  setDatabaseManager(dbManager: DatabaseManager): void {
    this.dbManager = dbManager;
  }

  setConfig(config: ParseConfig): void {
    this.config = config;
  }

  private initializeParsers(): void {
    const pdfParser = new PDFParser();
    const imageParser = new ImageParser(true);
    const textParser = new TextParser();
    const wordParser = new WordParser();
    const excelParser = new ExcelParser();
    const pptParser = new PptParser();

    this.parsers.set('pdf', pdfParser);

    const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'livp', 'tiff', 'tif', 'ico', 'svg'];
    for (const ext of imageExts) {
      this.parsers.set(ext, imageParser);
    }

    const textExts = ['txt', 'md', 'json', 'xml', 'html', 'csv'];
    for (const ext of textExts) {
      this.parsers.set(ext, textParser);
    }

    // Office file parsers
    this.parsers.set('docx', wordParser);
    this.parsers.set('doc', wordParser);
    this.parsers.set('xlsx', excelParser);
    this.parsers.set('xls', excelParser);
    this.parsers.set('pptx', pptParser);
    this.parsers.set('ppt', pptParser);
  }

  async parseFile(filePath: string): Promise<DataBlock[]> {
    const ext = filePath.toLowerCase().split('.').pop() || '';
    const parser = this.parsers.get(ext);

    if (!parser) {
      console.warn(`[DataParser] No parser for extension: ${ext}`);
      return [];
    }

    try {
      const blocks = await parser.parse(filePath);

      if (this.config.mode === 1 && blocks.length > 0) {
        return this.processLightMode(filePath, blocks);
      }

      // Deep mode: return all blocks
      for (const block of blocks) {
        const meta: FileMetadata = block.metadata as FileMetadata;
        meta['parsingMode'] = 'deep';
        block.setMetadata(meta);
      }

      return blocks;
    } catch (err) {
      console.error(`[DataParser] Failed to parse file ${filePath}:`, err);
      return [];
    }
  }

  /**
   * 解析文件并生成语义块（完整流程）
   */
  async parseFileWithSemantic(filePath: string, fileRecord?: FileRecord): Promise<ParseResult> {
    const startTime = Date.now();
    const ext = filePath.toLowerCase().split('.').pop() || '';
    const parser = this.parsers.get(ext);

    if (!parser) {
      console.warn(`[DataParser] No parser for extension: ${ext}`);
      const emptyResult: ParseResult = {
        dataBlocks: [],
        semanticBlocks: [],
        fileId: 0,
        processingTime: Date.now() - startTime,
        parsingMode: 'none'
      };
      return emptyResult;
    }

    try {
      // Step 1: Parse file content
      const blocks = await parser.parse(filePath);

      if (blocks.length === 0) {
        const emptyResult: ParseResult = {
          dataBlocks: [],
          semanticBlocks: [],
          fileId: fileRecord?.id ?? 0,
          processingTime: Date.now() - startTime,
          parsingMode: this.config.mode === 1 ? 'light' : 'deep'
        };
        return emptyResult;
      }

      // Step 2: Process according to mode
      let processedBlocks: DataBlock[];
      let semanticBlocks: SemanticBlock[] = [];
      let parsingMode: string;

      if (this.config.mode === 1) {
        // Light mode: first page only
        processedBlocks = this.processLightMode(filePath, blocks);
        parsingMode = 'light';

        // Generate semantic block for first page combined content
        if (this.config.generateSemantic && this.semanticRepresentation) {
          const combinedBlock = await this.semanticRepresentation.representFirstPageBlocks(
            processedBlocks,
            fileRecord,
            this.config.lightModeMaxLength
          );
          semanticBlocks.push(combinedBlock);
        }
      } else {
        // Deep mode: all pages
        processedBlocks = blocks;
        parsingMode = 'deep';

        for (const block of processedBlocks) {
          const meta: FileMetadata = block.metadata as FileMetadata;
          meta['parsingMode'] = 'deep';
          block.setMetadata(meta);
        }

        // Generate semantic blocks for all content
        if (this.config.generateSemantic && this.semanticRepresentation) {
          semanticBlocks = await this.semanticRepresentation.representBatch(
            processedBlocks,
            fileRecord
          );
        }
      }

      // Step 3: Store to database if configured
      let fileId = fileRecord?.id ?? 0;
      if (this.config.storeToDatabase && this.dbManager && fileRecord) {
        fileId = await this.storeToDatabase(fileRecord, processedBlocks, semanticBlocks);
      }

      const processingTime = Date.now() - startTime;
      console.info(`[DataParser] Parsed ${filePath} in ${processingTime}ms, mode=${parsingMode}, blocks=${processedBlocks.length}`);

      const result: ParseResult = {
        dataBlocks: processedBlocks,
        semanticBlocks: semanticBlocks,
        fileId: fileId,
        processingTime: processingTime,
        parsingMode: parsingMode
      };

      return result;
    } catch (err) {
      console.error(`[DataParser] Failed to parse file ${filePath}:`, err);
      const errorResult: ParseResult = {
        dataBlocks: [],
        semanticBlocks: [],
        fileId: 0,
        processingTime: Date.now() - startTime,
        parsingMode: 'error'
      };
      return errorResult;
    }
  }

  /**
   * 存储解析结果到数据库
   */
  private async storeToDatabase(
    fileRecord: FileRecord,
    dataBlocks: DataBlock[],
    semanticBlocks: SemanticBlock[]
  ): Promise<number> {
    if (!this.dbManager) return 0;

    try {
      // Add file if not exists
      let fileId = fileRecord.id;
      if (fileId <= 0) {
        const now = new Date();
        const nowStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`;
        fileId = await this.dbManager.addFile(
          fileRecord.filePath,
          fileRecord.fileName,
          fileRecord.fileSize,
          fileRecord.fileType,
          fileRecord.modifiedTime || nowStr,
          fileRecord.createdTime || nowStr,
          fileRecord.directoryPath ?? ''
        );
      }

      // Store semantic filename
      const semanticFilename = this.filenameAnalyzer.getMeaningfulPart(fileRecord.fileName);
      if (semanticFilename) {
        await this.dbManager.updateFileSemanticFilename(fileId, semanticFilename);
      }

      // Store data blocks
      if (dataBlocks.length > 0) {
        const dataBlockItems: DataBlockBatchItem[] = [];
        for (const block of dataBlocks) {
          // addr应该指向缓存文件路径，如果缓存失败(addr为空)则fallback到filePath
          const effectiveAddr = block.addr || block.filePath || '';
          console.info(`[DataParser] DataBlock addr: block.addr='${block.addr}', effective='${effectiveAddr.substring(0, 80)}'`);
          const item: DataBlockBatchItem = {
            blockId: block.blockId,
            fileId: fileId,
            modality: block.modality.toString(),
            addr: effectiveAddr,
            pageNumber: block.pageNumber ?? 0,
            position: '',
            metadata: JSON.stringify(block.metadata)
          };
          dataBlockItems.push(item);
        }
        await this.dbManager.addDataBlocksBatch(dataBlockItems);
      }

      // Store semantic blocks
      if (semanticBlocks.length > 0) {
        const semanticBlockItems: SemanticBlockBatchItem[] = [];
        for (const block of semanticBlocks) {
          // Convert number[] vector to Uint8Array
          const vectorBytes = this.encodeVectorToBytes(block.semanticVector ?? []);
          const item: SemanticBlockBatchItem = {
            semanticBlockId: block.blockId,
            dataBlockIds: [],
            fileId: fileId,
            textDescription: block.textDescription ?? '',
            keywords: block.keywords ?? [],
            semanticVector: vectorBytes,
            semanticFilename: semanticFilename
          };
          semanticBlockItems.push(item);
        }
        await this.dbManager.addSemanticBlocksBatch(semanticBlockItems);
      }

      console.info(`[DataParser] Stored ${dataBlocks.length} data blocks and ${semanticBlocks.length} semantic blocks for file ${fileId}`);
      return fileId;
    } catch (err) {
      console.error('[DataParser] Failed to store to database:', err);
      return 0;
    }
  }

  /**
   * 将向量数组编码为字节
   */
  private encodeVectorToBytes(vector: number[]): Uint8Array {
    // 384维向量，每个float32需要4字节
    const buffer = new ArrayBuffer(vector.length * 4);
    const view = new DataView(buffer);
    for (let i = 0; i < vector.length; i++) {
      view.setFloat32(i * 4, vector[i], true);
    }
    return new Uint8Array(buffer);
  }

  /**
   * 获取文件名语义分析
   */
  analyzeFilename(filename: string): FilenameAnalysisResult {
    return this.filenameAnalyzer.analyze(filename);
  }

  /**
   * 获取文件名有意义部分
   */
  getMeaningfulFilename(filename: string): string {
    return this.filenameAnalyzer.getMeaningfulPart(filename);
  }

  private processLightMode(filePath: string, blocks: DataBlock[]): DataBlock[] {
    const ext = filePath.toLowerCase().split('.').pop() || '';
    const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'livp', 'tiff', 'tif', 'ico', 'svg'];
    const multiPageExts = ['pdf'];

    let isImage = false;
    for (const e of imageExts) {
      if (e === ext) {
        isImage = true;
        break;
      }
    }

    let isMultiPage = false;
    for (const e of multiPageExts) {
      if (e === ext) {
        isMultiPage = true;
        break;
      }
    }

    if (isImage) {
      const imageBlocks: DataBlock[] = [];
      for (const b of blocks) {
        if (b.modality === ModalityType.IMAGE) {
          imageBlocks.push(b);
        }
      }
      if (imageBlocks.length > 0) {
        imageBlocks[0].textContent = `[Image file: ${filePath.split('/').pop()}]`;
        return [imageBlocks[0]];
      }
      return [];
    }

    if (isMultiPage) {
      const firstPageBlocks: DataBlock[] = [];
      for (const b of blocks) {
        if (b.pageNumber === 1) {
          firstPageBlocks.push(b);
        }
      }
      if (firstPageBlocks.length > 0) {
        for (const block of firstPageBlocks) {
          const meta: FileMetadata = block.metadata as FileMetadata;
          meta['parsingMode'] = 'lightFirstPage';
          block.setMetadata(meta);
        }
        return firstPageBlocks;
      }
      // 如果没有首页数据块，使用第一个数据块（与Python保持一致）
      if (blocks.length > 0) {
        const firstBlock = blocks[0];
        const meta: FileMetadata = firstBlock.metadata as FileMetadata;
        meta['parsingMode'] = 'lightFirstPage';
        firstBlock.setMetadata(meta);
        return [firstBlock];
      }
      // 如果没有任何块，返回空数组（Parser应该已经创建了占位块）
      return [];
    }

    // 对于其他文件类型，保留已有的blocks（它们应该已经有正确的addr）
    if (blocks.length > 0) {
      for (const block of blocks) {
        const meta: FileMetadata = block.metadata as FileMetadata;
        meta['parsingMode'] = 'light';
        block.setMetadata(meta);
      }
      return blocks;
    }

    // 如果没有任何块，返回空数组
    return [];
  }

  getSupportedExtensions(): string[] {
    return Array.from(this.parsers.keys());
  }
}
