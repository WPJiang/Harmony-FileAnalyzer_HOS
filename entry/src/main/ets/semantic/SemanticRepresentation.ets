﻿/**
 * SemanticRepresentation - Generates semantic blocks from file content
 *
 * 完整语义表征流程：
 * 1. 文本提取（本地OCR/解析器）
 * 2. 文本描述生成（本地摘要/云端LLM）
 * 3. 关键词提取（ChineseTokenizer分词）
 * 4. 向量编码（MindSpore Lite/云端API/本地哈希）
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SemanticBlock, DataBlock, ModalityType, FileRecord, FileMetadata } from '../models/Index';
import { KeywordExtractor, TextDescriptionGenerator } from './KeywordExtractor';
import { LocalOCRService } from '../services/LocalOCRService';
import { EmbeddingService, MindSporeEmbeddingService, LocalEmbeddingService } from './EmbeddingService';
import { ApiService } from '../services/ApiService';
import { ChineseTokenizer } from '../utils/ChineseTokenizer';
import { FilenameSemanticAnalyzer, FilenameAnalysisResult } from './FilenameSemanticAnalyzer';
import { DatabaseManager } from '../database/DatabaseManager';
import { LocalImageAnalysisService } from '../services/LocalImageAnalysisService';

/**
 * 语义文本拼接字段配置接口
 */
interface SemanticTextFieldsConfig {
  vector: string[];
  bm25: string[];
}

/**
 * 语义表征配置
 */
export interface SemanticRepresentationConfig {
  maxDescriptionLength: number;
  maxKeywords: number;
  useCloudLLM: boolean;
  useMindSpore: boolean;
}

/**
 * 语义表征结果
 */
export interface RepresentationResult {
  semanticBlock: SemanticBlock;
  processingTime: number;
  encoderUsed: string;
  wasOffline: boolean;
}

export class SemanticRepresentation {
  private keywordExtractor: KeywordExtractor;
  private descriptionGenerator: TextDescriptionGenerator;
  private localOCRService: LocalOCRService;
  private embeddingService: EmbeddingService;
  private filenameAnalyzer: FilenameSemanticAnalyzer;
  private apiService: ApiService | null = null;
  private context: common.Context | null = null;
  private config: SemanticRepresentationConfig;
  private dbManager: DatabaseManager | null = null;
  // 图片文字提取方式配置（两个独立设置）
  // 原始图片文件（jpg/png等），默认caption（与Python一致）
  private imageFileTextMethod: string = 'caption';
  // 解析得到的图片（PDF/PPT中的图片），默认ocr
  private parsedImageTextMethod: string = 'ocr';
  // 嵌入模型最大文本长度
  private embeddingMaxTextLength: number = 128;
  // 文本描述最大长度（与Python description.max_length=512一致）
  private descriptionMaxLength: number = 512;
  // 语义文本拼接字段配置，与Python一致
  private semanticTextFields: SemanticTextFieldsConfig = {
    vector: ['semantic_filename', 'text_description'],
    bm25: ['semantic_filename', 'text_description']
  };

  constructor(config?: Partial<SemanticRepresentationConfig>) {
    const useCloudLLM = config?.useCloudLLM !== undefined ? config.useCloudLLM : true;
    const useMindSpore = config?.useMindSpore !== undefined ? config.useMindSpore : true;
    this.config = {
      maxDescriptionLength: config?.maxDescriptionLength || 512,
      maxKeywords: config?.maxKeywords || 10,
      useCloudLLM: useCloudLLM,
      useMindSpore: useMindSpore
    };

    this.keywordExtractor = new KeywordExtractor(this.config.maxKeywords);
    this.descriptionGenerator = new TextDescriptionGenerator(this.config.maxDescriptionLength);
    this.localOCRService = new LocalOCRService();
    this.embeddingService = new EmbeddingService();
    this.filenameAnalyzer = new FilenameSemanticAnalyzer();
  }

  setApiService(apiService: ApiService): void {
    this.apiService = apiService;
    this.embeddingService.setApiService(apiService);
  }

  setContext(context: common.Context): void {
    this.context = context;
    this.embeddingService.setContext(context);
  }

  setDatabaseManager(dbManager: DatabaseManager): void {
    this.dbManager = dbManager;
  }

  setImageFileTextMethod(method: string): void {
    this.imageFileTextMethod = method;
    console.info('[SemanticRep] imageFileTextMethod set to:', method);
  }

  setParsedImageTextMethod(method: string): void {
    this.parsedImageTextMethod = method;
    console.info('[SemanticRep] parsedImageTextMethod set to:', method);
  }

  setEmbeddingMaxTextLength(length: number): void {
    this.embeddingMaxTextLength = length > 0 ? length : 128;
    console.info('[SemanticRep] embeddingMaxTextLength set to:', this.embeddingMaxTextLength);
  }

  setDescriptionMaxLength(length: number): void {
    this.descriptionMaxLength = length > 0 ? length : 512;
    // 更新descriptionGenerator的配置
    this.descriptionGenerator.setMaxLength(this.descriptionMaxLength);
    console.info('[SemanticRep] descriptionMaxLength set to:', this.descriptionMaxLength);
  }

  async initialize(): Promise<void> {
    // 初始化OCR服务
    await this.localOCRService.initialize();

    // 初始化分词器
    if (this.context) {
      await this.keywordExtractor.initialize(this.context);
    }

    // 初始化向量编码服务
    this.embeddingService.setMaxTextLength(this.embeddingMaxTextLength);
    await this.embeddingService.initialize();

    console.info('[SemanticRepresentation] Initialized, encoder:', this.embeddingService.getActiveEncoder(), 'maxTextLength:', this.embeddingMaxTextLength);
  }

  /**
   * 完整语义表征流程
   */
  async represent(block: DataBlock): Promise<SemanticBlock> {
    const startTime = Date.now();
    let textContent = '';

    // Step 1: 提取文本内容
    textContent = await this.extractText(block);

    // 添加文件名上下文
    if (block.filePath) {
      const fileName = block.filePath.split('/').pop() || '';
      textContent = `[${fileName}]\n${textContent}`;
    }

    // Step 2: 生成文本描述
    const textDescription = await this.generateDescription(textContent, block.metadata);

    // Step 3: 提取关键词
    const keywords = this.keywordExtractor.extract(textContent);

    // Step 4: 生成语义向量
    const semanticVector = await this.embeddingService.encode(textDescription);

    // Step 5: 提取时间和地点信息
    const timeInfo = this.extractTimeInfo(textContent);
    const locationInfo = this.extractLocationInfo(textContent);

    // 构建结果
    const result = new SemanticBlock();
    result.setBlockId(block.blockId);
    result.setTextDescription(textDescription);
    result.setKeywords(keywords);
    result.setSemanticVector(semanticVector);
    result.setModality(block.modality);
    result.setOriginalMetadata(block.metadata);

    const processingTime = Date.now() - startTime;
    console.info(`[SemanticRepresentation] Block ${block.blockId} processed in ${processingTime}ms`);

    return result;
  }

  /**
   * 提取文本内容 - 与Python逻辑一致
   */
  private async extractText(block: DataBlock): Promise<string> {
    let textContent = '';

    // 判断是否为图片类型
    const isImage = block.modality === ModalityType.IMAGE;

    // 判断是否为原始图片文件（与Python一致，通过metadata.source判断）
    let isImageFile = false;
    if (isImage && block.metadata) {
      const source = block.metadata['source'] as string || '';
      isImageFile = source === 'image_parser';
      console.info(`[SemanticRep] Block source=${source}, isImageFile=${isImageFile}`);
    }

    // 图片类型处理
    if (isImage) {
      // 使用block.addr作为图片路径（与Python一致）
      const imagePath = block.addr || block.filePath;
      console.info(`[SemanticRep] Image path from addr: ${imagePath?.substring(0, 80)}`);

      if (imagePath) {
        // 根据图片来源选择配置（两个独立设置）
        // 原始图片文件使用imageFileTextMethod，解析图片使用parsedImageTextMethod
        const method = isImageFile ? this.imageFileTextMethod : this.parsedImageTextMethod;
        const useCaption = method === 'caption';
        console.info(`[SemanticRep] method=${method}, useCaption=${useCaption} (isImageFile=${isImageFile}, imageFileMethod=${this.imageFileTextMethod}, parsedImageMethod=${this.parsedImageTextMethod})`);

        if (useCaption) {
          // Caption模式：使用LLM生成图片描述
          console.info('[SemanticRep] Using Caption mode for image');
          textContent = await this.generateImageCaption(imagePath);
        } else {
          // OCR模式：对图片中文字进行识别
          console.info('[SemanticRep] Using OCR mode for image');
          textContent = await this.extractTextFromImage(imagePath);
        }
      }
    }
    // PDF模态：可能有页面内容
    else if (block.modality === ModalityType.PDF) {
      textContent = block.textContent || '';
    }
    // 其他模态：从addr读取文本内容（与Python _read_block_content一致）
    else {
      if (block.addr) {
        textContent = await this.readTextFromAddr(block.addr);
      }
      if (!textContent) {
        textContent = block.textContent || '';
      }
    }

    console.info(`[SemanticRep] Extracted text length: ${textContent.length}`);
    return textContent;
  }

  /**
   * 从addr读取文本内容（与Python _read_block_content一致）
   * 对大文本进行截断处理，避免主线程阻塞
   */
  private async readTextFromAddr(addr: string): Promise<string> {
    if (!addr) return '';

    // 最大文本长度限制（避免主线程阻塞）
    const MAX_TEXT_LENGTH = 50000; // 50KB 文本足够生成语义向量

    try {
      const file = await fileIo.open(addr, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const size = stat.size;

      if (size > 0) {
        // 如果文件太大，只读取前 MAX_TEXT_LENGTH 字节
        const readSize = Math.min(size, MAX_TEXT_LENGTH * 4); // UTF-8 最多 4 bytes/char
        const buffer = new ArrayBuffer(readSize);
        await fileIo.read(file.fd, buffer);
        await fileIo.close(file.fd);

        // 使用分块解码避免阻塞
        const decoder = util.TextDecoder.create('utf-8');
        const uint8Buffer = new Uint8Array(buffer);

        // 对于大 buffer，使用 yield 分块解码
        let decodedText = '';
        const CHUNK_SIZE = 10000; // 每次解码 10KB

        for (let offset = 0; offset < uint8Buffer.length; offset += CHUNK_SIZE) {
          const chunkEnd = Math.min(offset + CHUNK_SIZE, uint8Buffer.length);
          const chunk = uint8Buffer.slice(offset, chunkEnd);
          decodedText += decoder.decodeToString(chunk);

          // 每处理一个块后 yield 主线程
          if (offset % (CHUNK_SIZE * 5) === 0 && offset > 0) {
            await new Promise<void>((resolve) => setTimeout(() => resolve(), 5));
          }

          // 如果已经达到最大长度，停止解码
          if (decodedText.length >= MAX_TEXT_LENGTH) {
            decodedText = decodedText.substring(0, MAX_TEXT_LENGTH);
            break;
          }
        }

        console.info(`[SemanticRep] readTextFromAddr: size=${size}, readSize=${readSize}, textLength=${decodedText.length}`);
        return decodedText;
      }
      await fileIo.close(file.fd);
    } catch (e) {
      console.warn('[SemanticRep] Failed to read from addr:', addr?.substring(0, 50), e);
    }

    return '';
  }

  /**
   * 根据配置拼接文本字段（与Python _build_text_from_fields一致）
   */
  private buildTextFromFields(
    fields: string[],
    semanticFilename: string,
    textDescription: string,
    keywords: string[]
  ): string {
    const parts: string[] = [];

    for (const field of fields) {
      if (field === 'semantic_filename' && semanticFilename) {
        parts.push(semanticFilename);
      } else if (field === 'text_description' && textDescription) {
        parts.push(textDescription);
      } else if (field === 'keywords' && keywords.length > 0) {
        parts.push(keywords.join(' '));
      }
    }

    return parts.join(' ');
  }

  /**
   * 从图片提取文本（OCR）
   */
  private async extractTextFromImage(imagePath: string): Promise<string> {
    // 优先使用本地OCR
    try {
      const localResult = await this.localOCRService.recognizeImagePath(imagePath);
      if (localResult && localResult.trim()) {
        console.info('[SemanticRep] Local OCR success, text length:', localResult.length);
        return localResult;
      }
    } catch (err) {
      console.warn('[SemanticRep] Local OCR failed:', err);
    }

    // 降级到云端API
    if (this.apiService && this.apiService.isConnected()) {
      try {
        const response = await this.apiService.ocrImage(imagePath);
        console.info('[SemanticRep] Cloud OCR success, text length:', response.text?.length || 0);
        return response.text || '';
      } catch (err) {
        console.warn('[SemanticRep] Cloud OCR failed:', err);
      }
    }

    return '';
  }

  /**
   * 使用Caption模式生成图片描述（与Python ImageCaptionTagger一致）
   * Caption失败时自动降级到OCR
   */
  private async generateImageCaption(imagePath: string): Promise<string> {
    try {
      // 使用LocalImageAnalysisService的caption生成
      const imageService = new LocalImageAnalysisService();
      if (this.context) {
        imageService.setContext(this.context);
      }

      // 尝试生成caption（fileId使用0作为占位符）
      const captionResult = await imageService.generateCaption(imagePath, 0);
      if (captionResult && captionResult.caption && captionResult.caption.trim()) {
        console.info('[SemanticRep] Caption generated successfully:', captionResult.caption.substring(0, 50));
        return captionResult.caption;
      }
    } catch (e) {
      console.warn('[SemanticRep] Caption generation failed, fallback to OCR:', e);
    }

    // Caption失败，降级到OCR
    console.info('[SemanticRep] Falling back to OCR for image');
    return await this.extractTextFromImage(imagePath);
  }

  /**
   * 生成文本描述
   */
  private async generateDescription(text: string, metadata?: FileMetadata): Promise<string> {
    // 优先使用云端LLM生成描述
    if (this.config.useCloudLLM && this.apiService && this.apiService.isConnected()) {
      try {
        const response = await this.apiService.llmDescribe(text);
        if (response.description) {
          return response.description;
        }
      } catch (err) {
        console.warn('[SemanticRep] LLM describe failed, using local fallback');
      }
    }

    // 本地生成描述
    return this.descriptionGenerator.generateStructured(text, metadata);
  }

  /**
   * 提取时间信息
   */
  private extractTimeInfo(text: string): string[] {
    const timePatterns = [
      /\d{4}[-/年]\d{1,2}[-/月]\d{1,2}[日]?/g,       // 2024-01-15 或 2024年1月15日
      /\d{4}[-/]\d{1,2}[-/]\d{1,2}/g,                 // 2024/01/15
      /\d{1,2}[-/]\d{1,2}[-/]\d{4}/g,                 // 01-15-2024
      /\d{4}年\d{1,2}月/g,                            // 2024年1月
      /\d{1,2}月\d{1,2}日/g,                          // 1月15日
      /\d{4}/g                                        // 年份
    ];

    const times: Set<string> = new Set();
    for (const pattern of timePatterns) {
      const matches = text.match(pattern) || [];
      for (const match of matches) {
        times.add(match);
      }
    }

    return Array.from(times).slice(0, 5);
  }

  /**
   * 提取地点信息
   */
  private extractLocationInfo(text: string): string[] {
    const locationPatterns = [
      /[\u4e00-\u9fff]+省[\u4e00-\u9fff]+市/g,        // XX省XX市
      /[\u4e00-\u9fff]+市[\u4e00-\u9fff]+区/g,        // XX市XX区
      /[\u4e00-\u9fff]+省/g,                          // XX省
      /[\u4e00-\u9fff]+市/g,                          // XX市
      /[\u4e00-\u9fff]+区/g,                          // XX区
      /[\u4e00-\u9fff]+县/g                           // XX县
    ];

    const locations: Set<string> = new Set();
    for (const pattern of locationPatterns) {
      const matches = text.match(pattern) || [];
      for (const match of matches) {
        if (match.length >= 2) {
          locations.add(match);
        }
      }
    }

    return Array.from(locations).slice(0, 5);
  }

  /**
   * 批量语义表征（优化处理）
   */
  async representBatch(blocks: DataBlock[], fileRecord?: FileRecord): Promise<SemanticBlock[]> {
    const semanticBlocks: SemanticBlock[] = [];

    // 批量处理：先收集所有文本，然后批量编码
    const textContents: string[] = [];
    const processedBlocks: DataBlock[] = [];

    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      try {
        const textContent = await this.extractText(block);
        if (textContent.trim()) {
          textContents.push(textContent);
          processedBlocks.push(block);
        }

        // 每提取一个block文本后yield，避免OCR/Caption阻塞主线程
        if (i % 1 === 0) {
          await new Promise<void>((resolve) => setTimeout(() => resolve(), 10));
        }
      } catch (err) {
        console.error('[SemanticRep] Failed to extract text from block:', block.blockId, err);
      }
    }

    // 获取语义文件名
    let semanticFilename = '';
    if (fileRecord) {
      semanticFilename = this.filenameAnalyzer.getMeaningfulPart(fileRecord.fileName);
      if (semanticFilename) {
        // 更新数据库中的语义文件名
        if (this.dbManager && fileRecord.id > 0) {
          await this.dbManager.updateFileSemanticFilename(fileRecord.id, semanticFilename);
        }
      }
    }

    // 批量生成描述
    const descriptions = textContents.map(text =>
      this.descriptionGenerator.generateStructured(text)
    );

    // 批量提取关键词
    const keywordsList = textContents.map(text =>
      this.keywordExtractor.extract(text)
    );

    // 根据配置拼接向量文本和BM25文本（与Python一致）
    const textsForVector: string[] = [];
    const textsForBm25: string[] = [];
    for (let i = 0; i < descriptions.length; i++) {
      const textForVector = this.buildTextFromFields(
        this.semanticTextFields.vector,
        semanticFilename,
        descriptions[i],
        keywordsList[i]
      );
      const textForBm25 = this.buildTextFromFields(
        this.semanticTextFields.bm25,
        semanticFilename,
        descriptions[i],
        keywordsList[i]
      );
      textsForVector.push(textForVector);
      textsForBm25.push(textForBm25);
    }

    console.info(`[SemanticRep] textsForVector sample: ${textsForVector[0]?.substring(0, 80)}`);

    // 批量向量编码（使用拼接后的文本）
    const vectors = await this.embeddingService.encodeBatch(textsForVector);

    // 构建结果
    for (let i = 0; i < processedBlocks.length; i++) {
      const block = processedBlocks[i];
      const result = new SemanticBlock();
      result.setBlockId(block.blockId);
      result.setTextDescription(descriptions[i]);
      result.setKeywords(keywordsList[i]);
      result.setSemanticVector(vectors[i]);
      result.setModality(block.modality);
      result.setOriginalMetadata(block.metadata);
      // 保存BM25文本到metadata（与Python bm25_text字段一致）
      const meta: FileMetadata = block.metadata || {};
      meta['bm25_text'] = textsForBm25[i];
      meta['semantic_filename'] = semanticFilename;
      result.setOriginalMetadata(meta);
      semanticBlocks.push(result);
    }

    console.info(`[SemanticRepresentation] Batch processed ${semanticBlocks.length} blocks`);
    return semanticBlocks;
  }

  /**
   * 首页数据块整合语义表征（轻量模式）
   */
  async representFirstPageBlocks(
    blocks: DataBlock[],
    fileRecord?: FileRecord,
    maxLength: number = 256
  ): Promise<SemanticBlock> {
    // 收集所有文本
    const textParts: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      try {
        const textContent = await this.extractText(block);
        if (textContent.trim()) {
          textParts.push(textContent.trim());
        }

        // 每提取一个block文本后yield，避免OCR/Caption阻塞主线程
        if (i % 1 === 0) {
          await new Promise<void>((resolve) => setTimeout(() => resolve(), 10));
        }
      } catch (err) {
        console.warn('[SemanticRep] Failed to extract text from block:', block.blockId);
      }
    }

    // 合并文本
    let combinedText = textParts.join('\n');
    if (combinedText.length > maxLength) {
      combinedText = combinedText.substring(0, maxLength) + '...';
    }

    // 获取语义文件名
    let semanticFilename = '';
    if (fileRecord) {
      semanticFilename = this.filenameAnalyzer.getMeaningfulPart(fileRecord.fileName);
      if (semanticFilename && this.dbManager && fileRecord.id > 0) {
        await this.dbManager.updateFileSemanticFilename(fileRecord.id, semanticFilename);
      }
    }

    // 生成描述
    const textDescription = this.descriptionGenerator.generateStructured(combinedText);

    // 提取关键词
    const keywords = this.keywordExtractor.extract(textDescription);

    // 根据配置拼接向量文本和BM25文本（与Python一致）
    const textForVector = this.buildTextFromFields(
      this.semanticTextFields.vector,
      semanticFilename,
      textDescription,
      keywords
    );
    const textForBm25 = this.buildTextFromFields(
      this.semanticTextFields.bm25,
      semanticFilename,
      textDescription,
      keywords
    );

    console.info(`[SemanticRep] FirstPage textForVector: ${textForVector.substring(0, 80)}`);

    // 生成向量（使用拼接后的文本）
    const semanticVector = await this.embeddingService.encode(textForVector);

    // 构建结果
    const result = new SemanticBlock();
    result.setBlockId(`first_page_${Date.now().toString(16)}`);
    result.setTextDescription(textDescription);
    result.setKeywords(keywords);
    result.setSemanticVector(semanticVector);
    result.setModality(ModalityType.TEXT);

    const metadata: FileMetadata = {};
    metadata['sourceBlocksCount'] = blocks.length;
    metadata['combinedTextLength'] = textParts.join('\n').length;
    metadata['maxLength'] = maxLength;
    metadata['parsingMode'] = 'light_first_page_combined';
    metadata['bm25_text'] = textForBm25;
    if (semanticFilename) {
      metadata['semanticFilename'] = semanticFilename;
    }
    result.setOriginalMetadata(metadata);

    return result;
  }

  /**
   * 快速文本表征（用于查询）
   */
  async representText(text: string): Promise<SemanticBlock> {
    const textDescription = this.descriptionGenerator.generate(text);
    const keywords = this.keywordExtractor.extract(text);
    const semanticVector = await this.embeddingService.encode(textDescription);

    const result = new SemanticBlock();
    result.setBlockId(`text_${Date.now().toString(16)}`);
    result.setTextDescription(textDescription);
    result.setKeywords(keywords);
    result.setSemanticVector(semanticVector);
    result.setModality(ModalityType.TEXT);
    const emptyMeta: FileMetadata = {};
    result.setOriginalMetadata(emptyMeta);
    return result;
  }

  /**
   * 仅向量编码
   */
  async encodeText(text: string): Promise<number[]> {
    return await this.embeddingService.encode(text);
  }

  /**
   * 仅关键词提取
   */
  extractKeywords(text: string): string[] {
    return this.keywordExtractor.extract(text);
  }

  /**
   * 仅描述生成
   */
  generateDescriptionLocal(text: string): string {
    return this.descriptionGenerator.generate(text);
  }

  /**
   * 分析文件名语义
   */
  analyzeFilename(filename: string): FilenameAnalysisResult {
    return this.filenameAnalyzer.analyze(filename);
  }

  /**
   * 获取文件名有意义部分
   */
  getMeaningfulFilenamePart(filename: string): string {
    return this.filenameAnalyzer.getMeaningfulPart(filename);
  }

  /**
   * 获取当前编码器信息
   */
  getEncoderInfo(): string {
    return this.embeddingService.getActiveEncoder();
  }

  /**
   * 检查MindSpore是否可用
   */
  isMindSporeAvailable(): boolean {
    return this.embeddingService.isMindSporeAvailable();
  }

  /**
   * 训练本地编码器（可选，提升TF-IDF质量）
   */
  async trainLocalEncoder(documents: string[]): Promise<void> {
    await this.embeddingService.trainLocalEncoder(documents);
  }

  /**
   * 获取嵌入服务实例（用于分类服务计算类别向量）
   */
  getEmbeddingService(): EmbeddingService {
    return this.embeddingService;
  }

  async release(): Promise<void> {
    await this.localOCRService.release();
    await this.embeddingService.release();
  }
}