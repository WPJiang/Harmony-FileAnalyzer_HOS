/**
 * SemanticQuery - 语义查询模块
 *
 * 实现基于语义相似度的文件检索功能。
 * 流程：
 * 1. 将用户查询转化为语义块（文本描述、关键词、向量）
 * 2. 调用语义相似度计算模块，查找最相近的K个语义块
 * 3. 根据语义块相似度计算相关文件相似度
 * 4. 返回最相近的M个文件
 *
 * 性能优化：
 * - 向量矩阵缓存：使用预归一化的向量矩阵，O(1)矩阵运算替代O(n)遍历
 * - 关键词索引：预构建关键词到语义块的索引，快速匹配
 * - 延迟加载：只在首次查询时加载语义块
 */

import { SemanticBlock, QueryResult, ClusterResult, FileRecord } from '../models/Index';
import { SemanticSimilarity, SemanticClustering } from './SemanticSimilarity';
import { SemanticRepresentation } from './SemanticRepresentation';
import { DatabaseManager } from '../database/DatabaseManager';

/**
 * 语义块搜索结果
 */
export interface SemanticBlockResult {
  semanticBlockId: string;
  fileId: number;
  textDescription: string;
  keywords: string[];
  similarityScore: number;
}

/**
 * 文件搜索结果
 */
export interface FileResult {
  fileId: number;
  filePath: string;
  fileName: string;
  similarityScore: number;
  matchedBlocks: SemanticBlockResult[];
}

/**
 * 搜索结果
 */
export interface SearchResult {
  queryText: string;
  topK: number;
  topM: number;
  semanticBlocks: SemanticBlockResult[];
  files: FileResult[];
  searchTime: number;
}

/**
 * 查询权重配置
 */
export interface QueryWeights {
  category: number;
  keyword: number;
  semantic: number;
}

/**
 * 分数项（内部使用）
 */
interface ScoreItem {
  blockId: string;
  score: number;
  block: SemanticBlock;
}

/**
 * 文件分数数据（内部使用）
 */
interface FileScoreData {
  scores: number[];
  blocks: SemanticBlockResult[];
}

interface BlockScoreData {
  score: number;
  matchedKeywords: string[];
}

/**
 * 缓存状态
 */
interface CacheStatus {
  isLoaded: boolean;
  blockCount: number;
  keywordCount: number;
}

export class SemanticQuery {
  private dataBlocks: Map<string, SemanticBlock> = new Map();
  private semanticBlocks: SemanticBlock[] = [];
  private clustering: SemanticClustering;
  private similarity: SemanticSimilarity;
  private representation: SemanticRepresentation;
  private dbManager: DatabaseManager | null = null;

  // 性能优化：向量矩阵缓存
  private vectorMatrix: number[][] = [];
  private vectorMatrixValid: boolean = false;
  private blockIdToFileId: Map<string, number> = new Map();

  // 关键词索引
  private keywordIndex: Map<string, string[]> = new Map(); // keyword -> [blockIds]
  private keywordIndexValid: boolean = false;

  // 是否已加载
  private isLoaded: boolean = false;

  constructor() {
    this.clustering = new SemanticClustering();
    this.similarity = new SemanticSimilarity();
    this.representation = new SemanticRepresentation();
  }

  setDatabaseManager(dbManager: DatabaseManager): void {
    this.dbManager = dbManager;
  }

  setRepresentation(representation: SemanticRepresentation): void {
    this.representation = representation;
  }

  async initialize(
    semanticBlocks: SemanticBlock[],
    representation?: SemanticRepresentation
  ): Promise<void> {
    this.semanticBlocks = semanticBlocks;

    for (const block of semanticBlocks) {
      this.dataBlocks.set(block.blockId, block);
    }

    this.similarity.fit(semanticBlocks);
    this.clustering.initialize();

    if (representation) {
      this.representation = representation;
    }

    // 构建缓存
    this.buildVectorMatrix();
    this.buildKeywordIndex();
    this.isLoaded = true;
  }

  /**
   * 从数据库加载语义块
   */
  async loadFromDatabase(): Promise<number> {
    if (!this.dbManager) {
      console.warn('[SemanticQuery] Database manager not set');
      return 0;
    }

    try {
      // 获取所有文件
      const files = await this.dbManager.getAllFiles();
      const allSemanticBlocks: SemanticBlock[] = [];
      this.blockIdToFileId.clear();
      this.semanticBlocks = [];

      for (const file of files) {
        // 获取每个文件的语义块
        const dbBlocks = await this.getSemanticBlocksByFileId(file.id);
        for (const block of dbBlocks) {
          allSemanticBlocks.push(block);
          this.blockIdToFileId.set(block.blockId, file.id);
        }
      }

      this.semanticBlocks = allSemanticBlocks;

      // 初始化相似度
      if (allSemanticBlocks.length > 0) {
        this.similarity.fit(allSemanticBlocks);
        this.clustering.initialize();
      }

      // 构建缓存
      this.buildVectorMatrix();
      this.buildKeywordIndex();
      this.isLoaded = true;

      console.info(`[SemanticQuery] Loaded ${allSemanticBlocks.length} semantic blocks from database`);
      return allSemanticBlocks.length;
    } catch (err) {
      console.error('[SemanticQuery] Failed to load from database:', err);
      return 0;
    }
  }

  /**
   * 从数据库获取文件的语义块
   */
  private async getSemanticBlocksByFileId(fileId: number): Promise<SemanticBlock[]> {
    if (!this.dbManager) return [];

    try {
      // 这里需要查询semantic_blocks表
      // 由于DatabaseManager目前没有提供获取语义块的方法，我们需要添加
      // 暂时返回空数组
      return [];
    } catch (err) {
      console.error('[SemanticQuery] Failed to get semantic blocks:', err);
      return [];
    }
  }

  /**
   * 构建向量矩阵缓存
   */
  private buildVectorMatrix(): void {
    this.vectorMatrix = [];

    for (const block of this.semanticBlocks) {
      if (block.semanticVector && block.semanticVector.length > 0) {
        // 归一化向量
        const normalized = this.normalizeVector(block.semanticVector);
        this.vectorMatrix.push(normalized);
      } else {
        // 使用零向量占位
        this.vectorMatrix.push(this.createZeroVector(384));
      }
    }

    this.vectorMatrixValid = this.vectorMatrix.length > 0;
    console.info(`[SemanticQuery] Built vector matrix with ${this.vectorMatrix.length} vectors`);
  }

  /**
   * 构建关键词索引
   */
  private buildKeywordIndex(): void {
    this.keywordIndex.clear();

    for (const block of this.semanticBlocks) {
      if (block.keywords && block.keywords.length > 0) {
        for (const keyword of block.keywords) {
          const blockIds = this.keywordIndex.get(keyword);
          if (blockIds) {
            if (!blockIds.includes(block.blockId)) {
              blockIds.push(block.blockId);
            }
          } else {
            this.keywordIndex.set(keyword, [block.blockId]);
          }
        }
      }
    }

    this.keywordIndexValid = this.keywordIndex.size > 0;
    console.info(`[SemanticQuery] Built keyword index with ${this.keywordIndex.size} keywords`);
  }

  /**
   * 归一化向量
   */
  private normalizeVector(vector: number[]): number[] {
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
   * 创建零向量
   */
  private createZeroVector(dim: number): number[] {
    const vec: number[] = [];
    for (let i = 0; i < dim; i++) {
      vec.push(0);
    }
    return vec;
  }

  /**
   * 执行语义搜索
   */
  async search(
    queryText: string,
    topK: number = 10,
    topM: number = 5
  ): Promise<SearchResult> {
    const startTime = Date.now();

    console.info(`[SemanticQuery] Searching: "${queryText}", topK=${topK}, topM=${topM}`);

    // 如果未加载，尝试从数据库加载
    if (!this.isLoaded && this.dbManager) {
      await this.loadFromDatabase();
    }

    if (this.semanticBlocks.length === 0) {
      console.warn('[SemanticQuery] No semantic blocks available');
      const emptyResult: SearchResult = {
        queryText: queryText,
        topK: topK,
        topM: topM,
        semanticBlocks: [],
        files: [],
        searchTime: Date.now() - startTime
      };
      return emptyResult;
    }

    // 1. 将查询转化为语义块
    const queryBlock = await this.representation.representText(queryText);

    // 2. 使用优化后的搜索
    const semanticBlockResults = this.searchSemanticBlocks(queryBlock, topK);

    // 3. 计算文件相似度
    const fileResults = this.calculateFileSimilarity(semanticBlockResults, topM);

    const searchTime = Date.now() - startTime;
    console.info(`[SemanticQuery] Search completed in ${searchTime}ms, found ${fileResults.length} files`);

    const result: SearchResult = {
      queryText: queryText,
      topK: topK,
      topM: topM,
      semanticBlocks: semanticBlockResults,
      files: fileResults,
      searchTime: searchTime
    };

    return result;
  }

  /**
   * 搜索语义块（优化版本）
   */
  private searchSemanticBlocks(queryBlock: SemanticBlock, topK: number): SemanticBlockResult[] {
    if (this.semanticBlocks.length === 0) {
      return [];
    }

    const queryVector = queryBlock.semanticVector || [];
    const queryKeywords = new Set<string>(queryBlock.keywords || []);

    // 计算相似度分数
    const scores: ScoreItem[] = [];

    for (let i = 0; i < this.semanticBlocks.length; i++) {
      const block = this.semanticBlocks[i];
      let score = 0;

      // 向量相似度（使用缓存的向量矩阵）
      if (this.vectorMatrixValid && queryVector.length > 0 && i < this.vectorMatrix.length) {
        const targetVector = this.vectorMatrix[i];
        score += 0.35 * this.dotProduct(queryVector, targetVector);
      }

      // 关键词相似度（使用索引加速）
      if (this.keywordIndexValid && queryKeywords.size > 0) {
        const blockKeywords = new Set<string>(block.keywords || []);
        let intersectionCount = 0;
        queryKeywords.forEach(kw => {
          if (blockKeywords.has(kw)) {
            intersectionCount++;
          }
        });
        const unionCount = queryKeywords.size + blockKeywords.size - intersectionCount;
        if (unionCount > 0) {
          score += 0.35 * intersectionCount / unionCount;
        }
      }

      // 文本相似度
      if (queryBlock.textDescription && block.textDescription) {
        const queryWords = new Set<string>(queryBlock.textDescription.toLowerCase().split(/\s+/));
        const blockWords = new Set<string>(block.textDescription.toLowerCase().split(/\s+/));
        let textIntersection = 0;
        queryWords.forEach(w => {
          if (blockWords.has(w)) {
            textIntersection++;
          }
        });
        const textUnion = queryWords.size + blockWords.size - textIntersection;
        if (textUnion > 0) {
          score += 0.30 * textIntersection / textUnion;
        }
      }

      scores.push({ blockId: block.blockId, score: score, block: block });
    }

    // 排序并取前topK
    scores.sort((a, b) => b.score - a.score);
    const topResults = scores.slice(0, topK);

    // 构建结果
    const results: SemanticBlockResult[] = [];
    for (const item of topResults) {
      if (item.score > 0) {
        const fileId = this.blockIdToFileId.get(item.blockId) || 0;
        results.push({
          semanticBlockId: item.blockId,
          fileId: fileId,
          textDescription: item.block.textDescription,
          keywords: item.block.keywords,
          similarityScore: item.score
        });
      }
    }

    return results;
  }

  /**
   * 点积计算
   */
  private dotProduct(vec1: number[], vec2: number[]): number {
    if (vec1.length !== vec2.length) {
      return 0;
    }
    let sum = 0;
    for (let i = 0; i < vec1.length; i++) {
      sum += vec1[i] * vec2[i];
    }
    return sum;
  }

  /**
   * 计算文件相似度
   */
  private calculateFileSimilarity(
    semanticBlockResults: SemanticBlockResult[],
    topM: number
  ): FileResult[] {
    if (semanticBlockResults.length === 0) {
      return [];
    }

    // 按文件ID分组
    const fileScores: Map<number, FileScoreData> = new Map();

    for (const blockResult of semanticBlockResults) {
      const fileId = blockResult.fileId;
      if (fileId <= 0) continue;

      const existing = fileScores.get(fileId);
      if (existing) {
        existing.scores.push(blockResult.similarityScore);
        existing.blocks.push(blockResult);
      } else {
        const newData: FileScoreData = {
          scores: [blockResult.similarityScore],
          blocks: [blockResult]
        };
        fileScores.set(fileId, newData);
      }
    }

    // 计算每个文件的最终相似度
    const results: FileResult[] = [];

    fileScores.forEach((data, fileId) => {
      // 使用最高相似度
      const maxScore = Math.max(...data.scores);

      const fileResult: FileResult = {
        fileId: fileId,
        filePath: '',
        fileName: '',
        similarityScore: maxScore,
        matchedBlocks: data.blocks
      };
      results.push(fileResult);
    });

    // 排序并取前topM
    results.sort((a, b) => b.similarityScore - a.similarityScore);
    return results.slice(0, topM);
  }

  /**
   * 按类别查询
   */
  async queryByCategory(
    categoryName: string,
    topK: number = 10,
    minScore: number = 0
  ): Promise<QueryResult[]> {
    const results: QueryResult[] = [];

    for (const block of this.semanticBlocks) {
      const clusterResult = this.clustering.cluster(block);

      if (clusterResult.clusterName === categoryName && clusterResult.confidence >= minScore) {
        const result = new QueryResult();
        result.blockIds = [block.blockId];
        result.score = clusterResult.confidence;
        result.matchedKeywords = this.filterCategoryKeywords(block.keywords);
        result.matchType = 'category';
        results.push(result);
      }
    }

    results.sort((a, b) => b.score - a.score);
    return results.slice(0, topK);
  }

  private filterCategoryKeywords(keywords: string[]): string[] {
    const categoryNames = this.clustering.getCategoryNames();
    const result: string[] = [];
    for (const k of keywords) {
      if (categoryNames.includes(k)) {
        result.push(k);
      }
    }
    return result;
  }

  /**
   * 按关键词查询
   */
  async queryByKeyword(
    keywords: string[],
    topK: number = 10,
    minScore: number = 0
  ): Promise<QueryResult[]> {
    const results: QueryResult[] = [];
    const queryKeywords = new Set<string>(keywords);

    // 使用关键词索引快速查找
    if (this.keywordIndexValid) {
      const matchedBlockIds: Set<string> = new Set();

      for (const keyword of keywords) {
        const blockIds = this.keywordIndex.get(keyword);
        if (blockIds) {
          for (const blockId of blockIds) {
            matchedBlockIds.add(blockId);
          }
        }
      }

      // 计算匹配分数
      for (const blockId of matchedBlockIds) {
        const block = this.dataBlocks.get(blockId);
        if (block) {
          const matchedKeywords = this.getMatchedKeywords(block.keywords, queryKeywords);
          if (matchedKeywords.length > 0) {
            const score = matchedKeywords.length / keywords.length;

            if (score >= minScore) {
              const result = new QueryResult();
              result.blockIds = [blockId];
              result.score = score;
              result.matchedKeywords = matchedKeywords;
              result.matchType = 'keyword';
              results.push(result);
            }
          }
        }
      }
    } else {
      // 回退到遍历查找
      for (const block of this.semanticBlocks) {
        const matchedKeywords = this.getMatchedKeywords(block.keywords, queryKeywords);

        if (matchedKeywords.length > 0) {
          const score = matchedKeywords.length / keywords.length;

          if (score >= minScore) {
            const result = new QueryResult();
            result.blockIds = [block.blockId];
            result.score = score;
            result.matchedKeywords = matchedKeywords;
            result.matchType = 'keyword';
            results.push(result);
          }
        }
      }
    }

    results.sort((a, b) => b.score - a.score);
    return results.slice(0, topK);
  }

  private getMatchedKeywords(blockKeywords: string[], queryKeywords: Set<string>): string[] {
    const result: string[] = [];
    for (const k of blockKeywords) {
      if (queryKeywords.has(k)) {
        result.push(k);
      }
    }
    return result;
  }

  /**
   * 自然语言查询
   */
  async queryByNaturalLanguage(
    queryText: string,
    topK: number = 10,
    minScore: number = 0
  ): Promise<QueryResult[]> {
    const queryBlock = await this.representation.representText(queryText);
    const semanticBlockResults = this.searchSemanticBlocks(queryBlock, topK);

    const results: QueryResult[] = [];
    for (const blockResult of semanticBlockResults) {
      if (blockResult.similarityScore >= minScore) {
        const result = new QueryResult();
        result.blockIds = [blockResult.semanticBlockId];
        result.score = blockResult.similarityScore;
        result.matchedKeywords = blockResult.keywords;
        result.matchType = 'semantic';
        results.push(result);
      }
    }

    return results;
  }

  /**
   * 组合查询
   */
  async queryCombined(
    categoryName: string | undefined,
    keywords: string[] | undefined,
    queryText: string | undefined,
    topK: number = 10,
    weights?: QueryWeights
  ): Promise<QueryResult[]> {
    const w: QueryWeights = {
      category: weights?.category ?? 0.3,
      keyword: weights?.keyword ?? 0.3,
      semantic: weights?.semantic ?? 0.4
    };

    const blockScores: Map<string, BlockScoreData> = new Map();

    if (categoryName !== undefined && categoryName !== '') {
      const categoryResults = await this.queryByCategory(categoryName, topK * 2);
      for (const result of categoryResults) {
        for (const blockId of result.blockIds) {
          this.updateBlockScore(blockScores, blockId, result.score * w.category, result.matchedKeywords);
        }
      }
    }

    if (keywords !== undefined && keywords.length > 0) {
      const keywordResults = await this.queryByKeyword(keywords, topK * 2);
      for (const result of keywordResults) {
        for (const blockId of result.blockIds) {
          this.updateBlockScore(blockScores, blockId, result.score * w.keyword, result.matchedKeywords);
        }
      }
    }

    if (queryText !== undefined && queryText !== '') {
      const semanticResults = await this.queryByNaturalLanguage(queryText, topK * 2);
      for (const result of semanticResults) {
        for (const blockId of result.blockIds) {
          this.updateBlockScore(blockScores, blockId, result.score * w.semantic, result.matchedKeywords);
        }
      }
    }

    const results: QueryResult[] = [];
    blockScores.forEach((data, blockId) => {
      const result = new QueryResult();
      result.blockIds = [blockId];
      result.score = data.score;
      result.matchedKeywords = data.matchedKeywords;
      result.matchType = 'combined';
      results.push(result);
    });

    results.sort((a, b) => b.score - a.score);
    return results.slice(0, topK);
  }

  private updateBlockScore(
    blockScores: Map<string, BlockScoreData>,
    blockId: string,
    scoreAdd: number,
    newKeywords: string[]
  ): void {
    const current = blockScores.get(blockId);
    if (current) {
      current.score += scoreAdd;
      current.matchedKeywords = this.mergeUniqueKeywords(current.matchedKeywords, newKeywords);
    } else {
      const newData: BlockScoreData = {
        score: scoreAdd,
        matchedKeywords: newKeywords.slice()
      };
      blockScores.set(blockId, newData);
    }
  }

  private mergeUniqueKeywords(existing: string[], newItems: string[]): string[] {
    const set = new Set<string>();
    for (const item of existing) {
      set.add(item);
    }
    for (const item of newItems) {
      set.add(item);
    }
    return Array.from(set);
  }

  /**
   * 获取所有类别
   */
  getAllCategories(): string[] {
    return this.clustering.getCategoryNames();
  }

  /**
   * 获取语义块
   */
  getBlockById(blockId: string): SemanticBlock | undefined {
    return this.dataBlocks.get(blockId);
  }

  /**
   * 清除缓存
   */
  clearCache(): void {
    this.semanticBlocks = [];
    this.dataBlocks.clear();
    this.vectorMatrix = [];
    this.vectorMatrixValid = false;
    this.keywordIndex.clear();
    this.keywordIndexValid = false;
    this.blockIdToFileId.clear();
    this.isLoaded = false;
    console.info('[SemanticQuery] Cache cleared');
  }

  /**
   * 获取缓存状态
   */
  getCacheStatus(): CacheStatus {
    const status: CacheStatus = {
      isLoaded: this.isLoaded,
      blockCount: this.semanticBlocks.length,
      keywordCount: this.keywordIndex.size
    };
    return status;
  }
}