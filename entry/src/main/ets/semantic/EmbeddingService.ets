/**
 * EmbeddingService - Text embedding service
 *
 * 编码优先级：
 * 1. MindSpore Lite端侧推理（MiniLM模型 + BPE分词器）- 离线、最快
 * 2. 后端API（云端向量编码服务）
 * 3. 本地N-gram哈希向量（备选方案，无需模型）
 *
 * 注意：HMS Retrieval Kit 不提供独立的 embedding 向量生成接口，
 * 仅用于向量检索场景，因此不在此使用。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { worker } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ApiService } from '../services/ApiService';
import { EmbeddingResult, createEmptyEmbeddingResult, cosineSimilarity } from '../models/EmbeddingResult';
import { MindSporeEmbeddingService as MsEmbeddingService } from './MindSporeEmbeddingService';

const VECTOR_DIM = 384;

// Worker 消息事件类型
interface WorkerMessageEvent {
  data: WorkerResponse;
}

// Worker 错误事件类型
interface WorkerErrorEvent {
  message: string;
}

// Worker 响应数据类型
type WorkerResponseData = number[] | number[][] | null;

// Pending request callback 类型
interface PendingRequestCallback {
  resolve: (data: WorkerResponseData) => void;
  reject: (err: Error) => void;
}

function createZeroVector(dim: number): number[] {
  const vec: number[] = [];
  for (let i = 0; i < dim; i++) {
    vec.push(0);
  }
  return vec;
}

/**
 * MindSpore Lite端侧向量编码服务包装器
 * 使用 Worker 线程执行推理，完全避免阻塞主线程
 */
export class MindSporeEmbeddingService {
  private static readonly VECTOR_DIM = 384;
  private msService: MsEmbeddingService | null = null;
  private context: common.Context | null = null;
  private initialized: boolean = false;
  private workerInstance: worker.ThreadWorker | null = null;
  private workerReady: boolean = false;
  // Promise-based callback registry for Worker responses
  private pendingRequests: Map<string, PendingRequestCallback> = new Map();
  private requestId: number = 0;

  /**
   * 初始化 MindSpore Lite 服务 - Worker线程推理
   */
  async initialize(context: common.Context): Promise<boolean> {
    this.context = context;
    try {
      this.initialized = true;
      this.initWorkerAsync();
      console.info('[MindSporeEmbeddingService] Initialization complete (Worker mode)');
      return true;
    } catch (err) {
      console.error('[MindSporeEmbeddingService] Initialization failed:', err);
      this.initialized = false;
      return false;
    }
  }

  /**
   * 异步初始化 Worker
   */
  private initWorkerAsync(): void {
    if (!this.context) return;

    setTimeout(async () => {
      try {
        const filesDir = this.context!.filesDir;
        const modelPath = `${filesDir}/minilm_l6_v2_int32.ms`;
        const vocabPath = `${filesDir}/vocab_full.json`;

        await this.ensureFileInFilesDir(modelPath, 'embedding/minilm_l6_v2_int32.ms');
        await this.ensureFileInFilesDir(vocabPath, 'embedding/vocab_full.json');

        this.workerInstance = new worker.ThreadWorker('entry/ets/workers/MindSporeWorker.ets');

        this.workerInstance.onmessage = (e: WorkerMessageEvent) => {
          const response = e.data as WorkerResponse;
          const requestId = response.requestId || '';

          if (requestId && this.pendingRequests.has(requestId)) {
            const callback = this.pendingRequests.get(requestId);
            this.pendingRequests.delete(requestId);
            if (response.success) {
              callback?.resolve(response.data);
            } else {
              callback?.reject(new Error(response.message));
            }
          } else if (response.type === 'initResult') {
            this.workerReady = response.success;
            console.info('[MindSporeEmbeddingService] Worker init result:', response.success);
          }
        };

        this.workerInstance.onerror = (e: WorkerErrorEvent) => {
          console.error('[MindSporeEmbeddingService] Worker error:', e.message);
          this.pendingRequests.forEach((cb) => cb.reject(new Error(e.message)));
          this.pendingRequests.clear();
        };

        this.workerInstance.postMessage({
          type: 'init',
          requestId: 'init',
          data: { modelPath, vocabPath }
        });

        console.info('[MindSporeEmbeddingService] Worker initialization started');
      } catch (err) {
        console.error('[MindSporeEmbeddingService] Worker init failed:', err);
        this.workerReady = false;
      }
    }, 100);
  }

  /**
   * 确保文件存在于 filesDir，如果不存在则从 rawfile 复制
   */
  private async ensureFileInFilesDir(destPath: string, rawfilePath: string): Promise<void> {
    if (!this.context) return;

    try {
      // 强制删除旧文件，确保使用最新的rawfile版本
      try {
        await fileIo.unlink(destPath);
        console.info(`[MindSporeEmbeddingService] Deleted old file: ${destPath}`);
      } catch (e) {
        // 文件不存在，正常
      }

      // 从 rawfile 复制
      console.info(`[MindSporeEmbeddingService] Copying ${rawfilePath} to ${destPath}...`);
      const resourceMgr = this.context.resourceManager;
      const uint8Buffer = await resourceMgr.getRawFileContent(rawfilePath);

      if (uint8Buffer && uint8Buffer.byteLength > 0) {
        // Uint8Array 转 ArrayBuffer
        const arrayBuffer = new ArrayBuffer(uint8Buffer.byteLength);
        const view = new Uint8Array(arrayBuffer);
        for (let i = 0; i < uint8Buffer.byteLength; i++) {
          view[i] = uint8Buffer[i];
        }

        // 写入文件
        const destFile = await fileIo.open(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        await fileIo.write(destFile.fd, arrayBuffer);
        await fileIo.close(destFile.fd);

        console.info(`[MindSporeEmbeddingService] Copied ${rawfilePath} to ${destPath}, size: ${arrayBuffer.byteLength}`);
      }
    } catch (copyErr) {
      console.error(`[MindSporeEmbeddingService] Failed to copy ${rawfilePath}:`, copyErr);
    }
  }

  /**
   * 使用 Worker 进行向量编码（非阻塞）
   */
  async encode(text: string): Promise<number[] | null> {
    // 优先使用 Worker（非阻塞）
    if (this.workerReady && this.workerInstance) {
      const requestId = `encode_${++this.requestId}`;

      return new Promise<number[] | null>((resolve, reject) => {
        // 设置超时（30秒）
        const timeout = setTimeout(() => {
          this.pendingRequests.delete(requestId);
          console.warn('[MindSporeEmbeddingService] Worker encode timeout, fallback to main thread');
          // 降级到主线程执行
          this.encodeMainThread(text).then(resolve).catch(reject);
        }, 30000);

        this.pendingRequests.set(requestId, {
          resolve: (data: WorkerResponseData) => {
            clearTimeout(timeout);
            // data 类型为 number[] | number[][] | null，需要类型断言
            const vectorData = data as number[] | null;
            resolve(vectorData);
          },
          reject: (err: Error) => {
            clearTimeout(timeout);
            console.warn('[MindSporeEmbeddingService] Worker encode failed:', err.message);
            // 降级到主线程执行
            this.encodeMainThread(text).then(resolve).catch(reject);
          }
        });

        this.workerInstance!.postMessage({
          type: 'encode',
          requestId: requestId,
          data: { text: text }
        });
      });
    }

    // Worker 未就绪，使用主线程执行
    return this.encodeMainThread(text);
  }

  /**
   * Worker 不可用时的降级方案 - 直接返回null让上层走本地编码器
   */
  private async encodeMainThread(text: string): Promise<number[] | null> {
    console.warn('[MindSporeEmbeddingService] Worker not available, returning null for local encoder fallback');
    return null;
  }

  /**
   * 批量编码 - 使用 Worker 逐个处理
   */
  async encodeBatch(texts: string[]): Promise<number[][]> {
    const vectors: number[][] = [];

    if (this.workerReady && this.workerInstance) {
      for (let i = 0; i < texts.length; i++) {
        const vector = await this.encode(texts[i]);
        vectors.push(vector || createZeroVector(MindSporeEmbeddingService.VECTOR_DIM));

        // 增加间隔到100ms，让Worker推理稳定
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));
      }
      return vectors;
    }

    // Worker 未就绪
    for (let i = 0; i < texts.length; i++) {
      const vector = await this.encodeMainThread(texts[i]);
      vectors.push(vector || createZeroVector(MindSporeEmbeddingService.VECTOR_DIM));
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 15));
    }
    return vectors;
  }

  /**
   * 检查服务是否可用
   */
  isAvailable(): boolean {
    return this.initialized && (this.workerReady || this.msService !== null);
  }

  /**
   * 释放资源
   */
  async release(): Promise<void> {
    // 释放 Worker
    if (this.workerInstance) {
      this.workerInstance.postMessage({
        type: 'release',
        requestId: 'release',
        data: {}
      });

      // 等待 Worker 释放完成
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));

      this.workerInstance.terminate();
      this.workerInstance = null;
      this.workerReady = false;
    }

    // 释放主线程服务
    if (this.msService) {
      await this.msService.unload();
      this.msService = null;
    }

    this.pendingRequests.clear();
    this.initialized = false;
    console.info('[MindSporeEmbeddingService] Service released');
  }
}

// Worker 消息响应类型
interface WorkerResponse {
  type: 'initResult' | 'encodeResult' | 'encodeBatchResult' | 'error';
  requestId?: string;
  success: boolean;
  data: number[] | number[][] | null;
  message: string;
}

/**
 * 本地向量编码服务（N-gram TF-IDF + 哈希向量）
 * 作为MindSpore Lite不可用时的备选方案
 */

interface LocalEmbeddingStatus {
  isFitted: boolean;
  vocabularySize: number;
  documentCount: number;
}

export class LocalEmbeddingService {
  private static readonly VECTOR_DIM = VECTOR_DIM;
  private static readonly FNV_PRIME = 16777619;
  private static readonly FNV_OFFSET = 2166136261;

  // N-gram范围：2-gram到4-gram
  private ngramRange: [number, number] = [2, 4];

  // 词表：词到索引的映射（用于TF-IDF）
  private vocabulary: Map<string, number> = new Map();
  private vocabularySize: number = 0;

  // IDF值缓存
  private idf: Map<string, number> = new Map();
  private documentCount: number = 0;

  // 是否已训练
  private isFitted: boolean = false;

  /**
   * 训练词表（可选，用于更精确的TF-IDF向量）
   * 如果不调用此方法，将使用哈希向量作为后备
   */
  async fit(documents: string[]): Promise<void> {
    const docFreq: Map<string, number> = new Map();
    this.vocabulary.clear();
    this.idf.clear();
    this.vocabularySize = 0;

    // 统计文档频率
    for (const doc of documents) {
      const ngrams = this.extractNgrams(doc);
      const uniqueNgrams = new Set(ngrams);

      for (const ngram of uniqueNgrams) {
        docFreq.set(ngram, (docFreq.get(ngram) || 0) + 1);
      }
    }

    this.documentCount = documents.length;

    // 构建词表和IDF值
    const sortedEntries: [string, number][] = [];
    docFreq.forEach((freq: number, ngram: string) => {
      sortedEntries.push([ngram, freq]);
    });
    sortedEntries.sort((a, b) => b[1] - a[1]);

    const topNgrams = sortedEntries.slice(0, LocalEmbeddingService.VECTOR_DIM);

    let idx = 0;
    for (const entry of topNgrams) {
      const ngram = entry[0];
      const freq = entry[1];
      this.vocabulary.set(ngram, idx);
      // IDF = log(N / df)，加1平滑
      this.idf.set(ngram, Math.log((this.documentCount + 1) / (freq + 1)) + 1);
      idx++;
    }

    this.vocabularySize = this.vocabulary.size;
    this.isFitted = true;

    console.info(`[LocalEmbeddingService] Fitted vocabulary with ${this.vocabularySize} n-grams from ${this.documentCount} documents`);
  }

  /**
   * 提取N-gram特征
   */
  private extractNgrams(text: string): string[] {
    const ngrams: string[] = [];
    const normalizedText = this.normalizeText(text);

    for (let n = this.ngramRange[0]; n <= this.ngramRange[1]; n++) {
      for (let i = 0; i <= normalizedText.length - n; i++) {
        ngrams.push(normalizedText.substring(i, i + n));
      }
    }

    return ngrams;
  }

  /**
   * 文本预处理：分词和归一化
   */
  private normalizeText(text: string): string {
    // 统一转小写，保留中文、英文、数字
    return text.toLowerCase()
      .replace(/[^\u4e00-\u9fffa-z0-9]/g, '')
      .trim();
  }

  /**
   * TF-IDF向量编码
   * 需要先调用fit()训练词表
   */
  tfidfEncode(text: string): number[] {
    const vector = createZeroVector(LocalEmbeddingService.VECTOR_DIM);

    if (!this.isFitted || this.vocabularySize === 0) {
      return this.hashEncode(text);
    }

    const ngrams = this.extractNgrams(text);

    // 计算词频(TF)
    const termFreq: Map<string, number> = new Map();
    for (const ngram of ngrams) {
      termFreq.set(ngram, (termFreq.get(ngram) || 0) + 1);
    }

    // 构建TF-IDF向量
    termFreq.forEach((tf: number, ngram: string) => {
      const idx = this.vocabulary.get(ngram);
      if (idx !== undefined && idx < LocalEmbeddingService.VECTOR_DIM) {
        const idfVal = this.idf.get(ngram);
        const idf = idfVal !== undefined ? idfVal : 1;
        vector[idx] = tf * idf;
      }
    });

    return this.normalize(vector);
  }

  /**
   * 改进的哈希向量编码（使用FNV-1a哈希）
   * 不需要预训练，适用于任意文本
   */
  hashEncode(text: string): number[] {
    const vector = createZeroVector(LocalEmbeddingService.VECTOR_DIM);
    const ngrams = this.extractNgrams(text);

    // 使用特征哈希(Feature Hashing)技术
    for (const ngram of ngrams) {
      const hash = this.fnv1aHash(ngram);
      const idx = hash % LocalEmbeddingService.VECTOR_DIM;

      // 使用符号哈希决定正负，增加区分度
      const signHash = this.fnv1aHash(ngram + '_sign');
      const sign = (signHash % 2 === 0) ? 1 : -1;

      vector[idx] += sign * 1.0;
    }

    return this.normalize(vector);
  }

  /**
   * FNV-1a哈希算法
   * 比简单哈希具有更好的分布性
   */
  private fnv1aHash(str: string): number {
    let hash = LocalEmbeddingService.FNV_OFFSET >>> 0;

    for (let i = 0; i < str.length; i++) {
      hash ^= str.charCodeAt(i);
      // 使用Math.imul模拟32位无符号乘法
      hash = Math.imul(hash, LocalEmbeddingService.FNV_PRIME) >>> 0;
    }

    return hash;
  }

  /**
   * 向量归一化(L2范数)
   */
  private normalize(vector: number[]): number[] {
    let sum = 0;
    for (const val of vector) {
      sum += val * val;
    }
    const norm = Math.sqrt(sum);

    if (norm < 1e-10) {
      return vector;
    }

    const result: number[] = [];
    for (const val of vector) {
      result.push(val / norm);
    }
    return result;
  }

  /**
   * 编码文本（自动选择最佳方法）
   */
  encode(text: string): number[] {
    if (!text || text.trim().length === 0) {
      return createZeroVector(LocalEmbeddingService.VECTOR_DIM);
    }

    // 如果已训练词表，使用TF-IDF；否则使用哈希编码
    if (this.isFitted) {
      return this.tfidfEncode(text);
    }

    return this.hashEncode(text);
  }

  /**
   * 批量编码
   */
  encodeBatch(texts: string[]): number[][] {
    return texts.map(text => this.encode(text));
  }

  /**
   * 计算余弦相似度
   */
  static cosineSimilarity(vec1: number[], vec2: number[]): number {
    if (vec1.length !== vec2.length) {
      console.warn('[LocalEmbeddingService] Vector dimensions mismatch');
      return 0;
    }

    let dotProduct = 0;
    let norm1 = 0;
    let norm2 = 0;

    for (let i = 0; i < vec1.length; i++) {
      dotProduct += vec1[i] * vec2[i];
      norm1 += vec1[i] * vec1[i];
      norm2 += vec2[i] * vec2[i];
    }

    const denom = Math.sqrt(norm1) * Math.sqrt(norm2);
    return denom > 0 ? dotProduct / denom : 0;
  }

  /**
   * 计算欧氏距离
   */
  static euclideanDistance(vec1: number[], vec2: number[]): number {
    if (vec1.length !== vec2.length) {
      return Infinity;
    }

    let sum = 0;
    for (let i = 0; i < vec1.length; i++) {
      const diff = vec1[i] - vec2[i];
      sum += diff * diff;
    }

    return Math.sqrt(sum);
  }

  /**
   * 获取服务状态
   */
  getStatus(): LocalEmbeddingStatus {
    const status: LocalEmbeddingStatus = {
      isFitted: this.isFitted,
      vocabularySize: this.vocabularySize,
      documentCount: this.documentCount
    };
    return status;
  }

  /**
   * 重置服务
   */
  reset(): void {
    this.vocabulary.clear();
    this.idf.clear();
    this.vocabularySize = 0;
    this.documentCount = 0;
    this.isFitted = false;
  }
}

export class EmbeddingService {
  private initialized: boolean = false;
  private context: common.Context | null = null;
  private apiService: ApiService | null = null;

  // 嵌入模型最大文本长度
  private maxTextLength: number = 128;

  // MindSpore Lite端侧编码服务
  private mindSporeEncoder: MindSporeEmbeddingService = new MindSporeEmbeddingService();
  private mindSporeInitialized: boolean = false;

  // 本地向量编码服务（备选）
  private localEncoder: LocalEmbeddingService = new LocalEmbeddingService();

  async initialize(): Promise<void> {
    if (this.initialized) return;

    console.info('[EmbeddingService] Starting initialization...');

    // 1. 尝试初始化MindSpore Lite端侧推理
    if (this.context) {
      console.info('[EmbeddingService] Attempting MindSpore Lite initialization...');
      try {
        this.mindSporeInitialized = await this.mindSporeEncoder.initialize(this.context);
        if (this.mindSporeInitialized) {
          console.info('[EmbeddingService] MindSpore Lite initialized successfully');
        } else {
          console.warn('[EmbeddingService] MindSpore Lite returned false, model may not have loaded');
        }
      } catch (err) {
        console.error('[EmbeddingService] MindSpore Lite initialization error:', JSON.stringify(err));
        this.mindSporeInitialized = false;
      }
    } else {
      console.warn('[EmbeddingService] No context provided, skipping MindSpore Lite');
    }

    // 2. 如果 MindSpore 不可用，检查后端 API
    if (!this.mindSporeInitialized) {
      if (this.apiService && this.apiService.isConnected()) {
        console.info('[EmbeddingService] Will use Backend API for embedding');
      } else {
        console.info('[EmbeddingService] Will use local N-gram encoder as fallback');
      }
    }

    this.initialized = true;
    console.info(`[EmbeddingService] Embedding service initialized, active encoder: ${this.getActiveEncoder()}`);
  }

  setContext(context: common.Context): void {
    this.context = context;
  }

  setApiService(apiService: ApiService): void {
    this.apiService = apiService;
  }

  setMaxTextLength(length: number): void {
    this.maxTextLength = length > 0 ? length : 128;
    console.info('[EmbeddingService] maxTextLength set to:', this.maxTextLength);
  }

  /**
   * 设置MindSpore模型文件名（需要在rawfile目录）
   */
  setMindSporeModel(modelName: string): void {
    // 需要重新初始化
    this.mindSporeInitialized = false;
    this.initialized = false;
  }

  /**
   * 训练本地编码器（可选，提升TF-IDF向量质量）
   */
  async trainLocalEncoder(documents: string[]): Promise<void> {
    await this.localEncoder.fit(documents);
    console.info('[EmbeddingService] Local encoder trained on', documents.length, 'documents');
  }

  async encode(text: string): Promise<number[]> {
    if (!text || text.trim().length === 0) {
      return createZeroVector(VECTOR_DIM);
    }

    // 应用文本截断（基于最大文本长度配置）
    let truncatedText = text;
    if (text.length > this.maxTextLength) {
      truncatedText = text.substring(0, this.maxTextLength);
      console.info(`[EmbeddingService] Text truncated from ${text.length} to ${this.maxTextLength} chars`);
    }

    // 编码优先级：
    // 1. MindSpore Lite端侧推理（最快、离线）
    // 2. 后端API（云端）
    // 3. 本地N-gram哈希向量（备选）

    // 1. 优先使用MindSpore Lite端侧推理
    if (this.mindSporeInitialized) {
      try {
        const msVector = await this.mindSporeEncoder.encode(truncatedText);
        if (msVector && msVector.length > 0) {
          // 检查向量有效性
          const validCount = msVector.filter(v => !isNaN(v) && isFinite(v) && v !== 0).length;
          const sample = msVector.slice(0, 5).map(v => v.toFixed(4));
          console.info(`[EmbeddingService] MindSpore vector: len=${msVector.length}, valid=${validCount}, sample=[${sample.join(', ')}]`);
          if (validCount > msVector.length * 0.5) {
            return msVector;
          } else {
            console.warn('[EmbeddingService] MindSpore vector has too many invalid values, fallback to local encoder');
          }
        }
      } catch (err) {
        console.warn('[EmbeddingService] MindSpore Lite encode failed:', err);
      }
    }

    // 2. 尝试后端API
    if (this.apiService && this.apiService.isConnected()) {
      try {
        const response = await this.apiService.embedText(truncatedText);
        if (response.vector && response.vector.length > 0) {
          const validCount = response.vector.filter(v => !isNaN(v) && isFinite(v)).length;
          console.info(`[EmbeddingService] API vector: len=${response.vector.length}, valid=${validCount}`);
          if (validCount === response.vector.length) {
            return response.vector;
          }
        }
      } catch (err) {
        console.warn('[EmbeddingService] Backend embedding failed:', err);
      }
    }

    // 3. 回退：本地N-gram哈希向量编码
    console.info('[EmbeddingService] Using local encoder fallback');
    const localVector = this.localEncoder.encode(truncatedText);
    const localValid = localVector.filter(v => !isNaN(v) && isFinite(v)).length;
    console.info(`[EmbeddingService] Local vector: len=${localVector.length}, valid=${localValid}`);
    return localVector;
  }

  async encodeBatch(texts: string[]): Promise<number[][]> {
    // 如果MindSpore可用，批量编码更高效
    if (this.mindSporeInitialized) {
      return this.mindSporeEncoder.encodeBatch(texts);
    }

    const vectors: number[][] = [];
    for (let i = 0; i < texts.length; i++) {
      const vector = await this.encode(texts[i]);
      vectors.push(vector);

      // 每编码一个文本后yield，避免MindSpore predict阻塞主线程
      if (i % 1 === 0) {
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 15));
      }
    }
    return vectors;
  }

  /**
   * 计算两个文本的相似度
   */
  async similarity(text1: string, text2: string): Promise<number> {
    const vec1 = await this.encode(text1);
    const vec2 = await this.encode(text2);
    return LocalEmbeddingService.cosineSimilarity(vec1, vec2);
  }

  /**
   * 计算两个向量的余弦相似度
   */
  static cosineSimilarity(vec1: number[], vec2: number[]): number {
    return LocalEmbeddingService.cosineSimilarity(vec1, vec2);
  }

  /**
   * 计算两个向量的欧氏距离
   */
  static euclideanDistance(vec1: number[], vec2: number[]): number {
    return LocalEmbeddingService.euclideanDistance(vec1, vec2);
  }

  /**
   * 获取本地编码器（供外部使用）
   */
  getLocalEncoder(): LocalEmbeddingService {
    return this.localEncoder;
  }

  /**
   * 获取MindSpore编码器（供外部使用）
   */
  getMindSporeEncoder(): MindSporeEmbeddingService {
    return this.mindSporeEncoder;
  }

  /**
   * 检查MindSpore Lite是否可用
   */
  isMindSporeAvailable(): boolean {
    return this.mindSporeInitialized && this.mindSporeEncoder.isAvailable();
  }

  /**
   * 获取当前使用的编码方式
   */
  getActiveEncoder(): string {
    if (this.mindSporeInitialized && this.mindSporeEncoder.isAvailable()) {
      return 'MindSpore Lite';
    }
    if (this.apiService && this.apiService.isConnected()) {
      return 'Backend API';
    }
    return 'Local N-gram';
  }

  async release(): Promise<void> {
    await this.mindSporeEncoder.release();
    this.mindSporeInitialized = false;
    this.initialized = false;
    this.localEncoder.reset();
    console.info('[EmbeddingService] Embedding service released');
  }
}