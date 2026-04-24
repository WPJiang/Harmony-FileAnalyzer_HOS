/**
 * LocalClassificationService - 本地分类服务
 *
 * 支持三种分类方式：
 * 1. 相似度分类（similarity）- 基于语义向量、BM25、关键词融合相似度
 * 2. 聚类分类（cluster）- 基于语义向量聚类
 * 3. LLM分类（llm）- 使用LLM模型进行分类
 *
 * 参考 Python 项目 semantic_classification.py 实现
 */

import { SemanticBlock, SemanticCategoryRecord } from '../models/Index';
import { DatabaseManager } from '../database/Index';
import { SemanticClustering, VectorSimilarity, BM25, KeywordSimilarity, TimeSimilarity, LocationSimilarity } from '../semantic/SemanticSimilarity';
import { EmbeddingService } from '../semantic/EmbeddingService';
import { LlamaNapi } from '../native/LlamaNapi';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 分类结果
 * 与Python ClassificationResult一致
 */
export interface ClassificationResult {
  blockId: string;
  categoryName: string;
  confidence: number;
  allScores: Record<string, number>;
}

/**
 * LLM解析结果
 */
interface LLMParseResult {
  category: string;
  confidence: number;
}

/**
 * 类别配置输出
 */
interface CategoryConfigOutput {
  name: string;
  description: string;
  keywords: string[];
}

/**
 * 配置输出
 */
interface ConfigOutput {
  classification_method: string;
  similarity_weights: SimilarityWeights;
  categories: CategoryConfigOutput[];
}

/**
 * 语义类别
 * 与Python SemanticCategory一致
 */
export interface SemanticCategoryConfig {
  name: string;
  description: string;
  keywords: string[];
}

/**
 * 分类方法枚举
 */
export enum ClassificationMethod {
  SIMILARITY = 'similarity',  // 相似度融合分类
  CLUSTER = 'cluster',        // 聚类分类
  LLM = 'llm'                 // LLM分类
}

/**
 * 相似度权重配置
 * 与Python config.json中的similarity_weights一致
 */
export interface SimilarityWeights {
  vectorWeight: number;      // 向量相似度权重，默认0.35
  bm25Weight: number;        // BM25权重，默认0.25
  keywordWeight: number;     // 关键词权重，默认0.25
  timeWeight: number;        // 时间权重，默认0.08
  locationWeight: number;    // 地点权重，默认0.07
}

// 默认类别（与Python config.json完全一致）
const DEFAULT_CATEGORIES: SemanticCategoryConfig[] = [
  {
    name: '技术文档',
    description: '技术规范、API文档、技术手册、开发文档等',
    keywords: ['技术', 'API', '接口', '开发', '代码', '系统', '架构', '配置', '部署', '服务器', '程序', '函数', '模块', '框架', '数据库']
  },
  {
    name: '商业报告',
    description: '商业计划、市场分析、财务报告、商业提案等',
    keywords: ['市场', '销售', '收入', '利润', '客户', '竞争', '战略', '投资', '商业', '业务', '增长', '运营', '营销', '品牌', '渠道']
  },
  {
    name: '学术论文',
    description: '研究论文、学术文章、研究报告、学位论文等',
    keywords: ['研究', '实验', '方法', '结果', '分析', '理论', '模型', '数据', '论文', '引用', '摘要', '结论', '假设', '验证', '文献']
  },
  {
    name: '会议演示',
    description: '会议PPT、演讲稿、培训材料、汇报材料等',
    keywords: ['会议', '演示', '培训', '演讲', 'PPT', '展示', '介绍', '汇报', '方案', '计划', '议程', '讨论', '总结', '要点', '目标']
  },
  {
    name: '合同协议',
    description: '合同、协议、法律文件、条款文件等',
    keywords: ['合同', '协议', '条款', '甲方', '乙方', '法律', '责任', '义务', '权利', '签署', '违约', '赔偿', '期限', '生效', '终止']
  },
  {
    name: '产品说明',
    description: '产品手册、使用指南、说明书、操作手册等',
    keywords: ['产品', '功能', '使用', '操作', '说明', '指南', '特性', '规格', '型号', '安装', '设置', '步骤', '注意', '维护', '故障']
  },
  {
    name: '新闻资讯',
    description: '新闻报道、新闻稿、媒体文章、资讯内容等',
    keywords: ['新闻', '报道', '发布', '消息', '媒体', '记者', '事件', '宣布', '最新', '动态', '采访', '声明', '关注', '热点', '头条']
  },
  {
    name: '个人文档',
    description: '简历、个人陈述、信函、个人记录等',
    keywords: ['个人', '简历', '经历', '教育', '技能', '自我', '介绍', '申请', '工作', '职位', '求职', '面试', '推荐', '背景', '成就']
  }
];

export class LocalClassificationService {
  // 分类方法
  private classificationMethod: ClassificationMethod = ClassificationMethod.SIMILARITY;

  // 相似度权重（与Python config.json一致）
  private weights: SimilarityWeights = {
    vectorWeight: 0.35,
    bm25Weight: 0.3,
    keywordWeight: 0.35,
    timeWeight: 0.0,
    locationWeight: 0.0
  };

  // 类别配置
  private categories: SemanticCategoryConfig[] = DEFAULT_CATEGORIES;
  private categoryNames: string[] = [];
  private categoryDescriptions: Record<string, string> = {};
  private categoryVectors: Record<string, number[]> = {};
  private categoryTexts: Record<string, string> = {};

  // 聚类服务（用于cluster方法）
  private semanticClustering: SemanticClustering;

  // 嵌入服务（用于计算类别向量）
  private embeddingService: EmbeddingService | null = null;
  private isInitialized: boolean = false;

  // 数据库管理器（用于存储类别向量）
  private dbManager: DatabaseManager | null = null;

  // LLM服务（用于llm方法）
  private context: common.Context | null = null;
  private llamaNapi: LlamaNapi | null = null;

  constructor() {
    this.semanticClustering = new SemanticClustering();
    this.semanticClustering.initialize();
    this.initCategoryConfig();
  }

  /**
   * 初始化类别配置
   */
  private initCategoryConfig(): void {
    this.categoryNames = this.categories.map(c => c.name);
    this.categoryDescriptions = {};
    this.categoryTexts = {};

    for (const cat of this.categories) {
      this.categoryDescriptions[cat.name] = cat.description;
      // 构建类别文本（与Python config.json一致：BM25只使用name字段）
      this.categoryTexts[cat.name] = cat.name;
    }
  }

  /**
   * 设置分类方法
   */
  setClassificationMethod(method: ClassificationMethod | string): void {
    if (typeof method === 'string') {
      this.classificationMethod = method as ClassificationMethod;
    } else {
      this.classificationMethod = method;
    }
    console.info(`[LocalClassificationService] Classification method set to: ${this.classificationMethod}`);
  }

  /**
   * 获取分类方法
   */
  getClassificationMethod(): ClassificationMethod {
    return this.classificationMethod;
  }

  /**
   * 设置相似度权重
   */
  setSimilarityWeights(weights: SimilarityWeights): void {
    this.weights = weights;
    console.info(`[LocalClassificationService] Similarity weights updated: vector=${weights.vectorWeight}, bm25=${weights.bm25Weight}, keyword=${weights.keywordWeight}`);
  }

  /**
   * 设置Context（用于LLM分类）
   */
  setContext(context: common.Context): void {
    this.context = context;
  }

  /**
   * 设置数据库管理器（用于存储类别向量）
   */
  setDbManager(dbManager: DatabaseManager): void {
    this.dbManager = dbManager;
  }

  /**
   * 设置类别配置（从数据库加载）
   * @param categoryRecords 从数据库获取的类别记录列表
   */
  setCategoriesFromDatabase(categoryRecords: SemanticCategoryRecord[]): void {
    if (categoryRecords.length === 0) {
      console.warn('[LocalClassificationService] No categories provided, using defaults');
      this.categories = DEFAULT_CATEGORIES;
    } else {
      const newCategories: SemanticCategoryConfig[] = [];
      for (const record of categoryRecords) {
        const config: SemanticCategoryConfig = {
          name: record.categoryName,
          description: record.description || '',
          keywords: record.keywords || []
        };
        newCategories.push(config);
      }
      this.categories = newCategories;
    }
    this.initCategoryConfig();
    console.info(`[LocalClassificationService] Categories set from database: ${this.categories.length} categories`);
  }

  /**
   * 初始化服务
   * @param embeddingService 嵌入服务（可选，用于计算类别向量）
   */
  async initialize(embeddingService?: EmbeddingService): Promise<void> {
    if (this.classificationMethod === ClassificationMethod.LLM) {
      // LLM模式初始化
      await this.initLLMClient();
      this.isInitialized = true;
      console.info(`[LocalClassificationService] Initialized (LLM mode), categories: ${this.categories.length}`);
      return;
    }

    // 相似度/聚类模式初始化
    if (embeddingService) {
      this.embeddingService = embeddingService;
      await this.computeAndStoreCategoryVectors();
    }

    this.isInitialized = true;
    console.info(`[LocalClassificationService] Initialized (${this.classificationMethod} mode), categories: ${this.categories.length}`);
  }

  /**
   * 初始化LLM客户端
   */
  private async initLLMClient(): Promise<void> {
    if (this.context === null) {
      console.warn('[LocalClassificationService] Context not set, LLM classification unavailable');
      return;
    }

    try {
      this.llamaNapi = new LlamaNapi();
      // 模型加载由外部服务负责（LlamaCaptionService）
      console.info('[LocalClassificationService] LLM client created');
    } catch (e) {
      console.error(`[LocalClassificationService] Failed to init LLM client: ${e}`);
      this.llamaNapi = null;
    }
  }

  /**
   * 计算类别向量
   */
  /**
   * 计算并存储类别向量到数据库（与Python semantic_clustering一致）
   */
  private async computeAndStoreCategoryVectors(): Promise<void> {
    if (!this.embeddingService) {
      console.warn('[LocalClassificationService] No embedding service, category vectors not computed');
      return;
    }

    this.categoryVectors = {};
    let storedCount = 0;

    for (const cat of this.categories) {
      // 构建向量文本（与Python vector_fields一致：name + description + keywords）
      const text = `${cat.name} ${cat.description} ${cat.keywords.join(' ')}`;
      try {
        const vector = await this.embeddingService.encode(text);
        if (vector && vector.length > 0) {
          // 检查向量数据有效性
          const validValues = vector.filter(v => !isNaN(v) && isFinite(v));
          console.info(`[LocalClassificationService] Vector for ${cat.name}: length=${vector.length}, valid=${validValues.length}, sample=[${vector.slice(0, 5).join(', ')}]`);

          if (validValues.length === vector.length) {
            this.categoryVectors[cat.name] = vector;

            // 存储到数据库（与Python update_category_vector一致）
            if (this.dbManager) {
              // 获取类别ID
              const categories = await this.dbManager.getSemanticCategoriesBySystem('默认类别体系');
              for (const dbCat of categories) {
                if (dbCat.categoryName === cat.name) {
                  // 检查是否已有向量
                  if (!dbCat.semanticVector || dbCat.semanticVector.length === 0) {
                    // 将向量转换为 Uint8Array 存储
                    const float32Array = new Float32Array(vector);
                    const uint8Array = new Uint8Array(float32Array.buffer);
                    console.info(`[LocalClassificationService] Converting to Uint8Array: float32Len=${float32Array.length}, uint8Len=${uint8Array.length}`);
                    await this.dbManager.updateCategoryVector(dbCat.id, uint8Array);
                    storedCount++;
                    console.info(`[LocalClassificationService] Stored vector for category: ${cat.name}`);
                  } else {
                    console.info(`[LocalClassificationService] Category ${cat.name} already has vector in DB (len=${dbCat.semanticVector.length})`);
                  }
                  break;
                }
              }
            }
          } else {
            console.warn(`[LocalClassificationService] Vector for ${cat.name} has invalid values: ${validValues.length}/${vector.length} valid`);
          }
        }
      } catch (e) {
        console.warn(`[LocalClassificationService] Failed to compute vector for ${cat.name}: ${e}`);
      }
    }
    console.info(`[LocalClassificationService] Category vectors computed: ${Object.keys(this.categoryVectors).length}, stored to DB: ${storedCount}`);
  }

  /**
   * 分类单个语义块
   * 与Python classify方法一致
   */
  classifyBlock(semanticBlock: SemanticBlock): ClassificationResult {
    if (!this.isInitialized) {
      console.warn('[LocalClassificationService] Not initialized, call initialize() first');
    }

    switch (this.classificationMethod) {
      case ClassificationMethod.LLM:
        return this.classifyWithLLM(semanticBlock);
      case ClassificationMethod.CLUSTER:
        return this.classifyWithCluster(semanticBlock);
      default:
        return this.classifyWithSimilarity(semanticBlock);
    }
  }

  /**
   * 相似度融合分类
   * 与Python _classify_with_similarity方法一致
   */
  private classifyWithSimilarity(block: SemanticBlock): ClassificationResult {
    const allScores: Record<string, number> = {};

    // 获取查询向量
    let queryVector: number[] | null = null;
    if (block.semanticVector && block.semanticVector.length > 0) {
      queryVector = block.semanticVector;
    } else if (block.textDescription && this.embeddingService) {
      // 如果没有向量，尝试生成（但这里同步方法无法调用async）
      console.warn('[LocalClassificationService] Block has no semantic vector, similarity may be inaccurate');
    }

    const queryText = block.textDescription || '';
    const queryKeywords = block.keywords || [];

    for (const cat of this.categories) {
      const score = this.computeFusedSimilarity(
        queryVector,
        queryText,
        queryKeywords,
        cat
      );
      allScores[cat.name] = score;
    }

    // 找到最佳分类
    let bestCategory = '其他';
    let bestScore = 0;
    for (const name of this.categoryNames) {
      if (allScores[name] > bestScore) {
        bestScore = allScores[name];
        bestCategory = name;
      }
    }

    return {
      blockId: block.blockId,
      categoryName: bestCategory,
      confidence: bestScore,
      allScores: allScores
    };
  }

  /**
   * 计算融合相似度
   * 与Python _compute_fused_similarity方法一致
   */
  private computeFusedSimilarity(
    queryVector: number[] | null,
    queryText: string,
    queryKeywords: string[],
    category: SemanticCategoryConfig
  ): number {
    // 向量相似度
    const vectorSim = this.computeVectorSimilarity(queryVector, category.name);

    // BM25分数
    const bm25Score = this.computeBM25Score(queryText, category.name);

    // 关键词相似度
    const keywordSim = this.computeKeywordSimilarity(queryKeywords, category.keywords);

    // 融合分数（与Python一致）
    const fusedScore = (
      this.weights.vectorWeight * vectorSim +
      this.weights.bm25Weight * bm25Score +
      this.weights.keywordWeight * keywordSim
    );

    return fusedScore;
  }

  /**
   * 计算向量相似度
   */
  private computeVectorSimilarity(queryVector: number[] | null, categoryName: string): number {
    if (!queryVector || queryVector.length === 0) {
      return 0.0;
    }

    const categoryVector = this.categoryVectors[categoryName];
    if (!categoryVector || categoryVector.length === 0) {
      return 0.0;
    }

    return VectorSimilarity.cosineSimilarity(queryVector, categoryVector);
  }

  /**
   * 计算BM25分数
   */
  private computeBM25Score(queryText: string, categoryName: string): number {
    if (!queryText) {
      return 0.0;
    }

    const categoryText = this.categoryTexts[categoryName];
    if (!categoryText) {
      return 0.0;
    }

    // 简化的BM25计算
    const queryTokens = this.tokenize(queryText);
    const catTokens = this.tokenize(categoryText);

    // 计算词频
    const catTermFreq: Record<string, number> = {};
    for (const token of catTokens) {
      catTermFreq[token] = (catTermFreq[token] || 0) + 1;
    }

    const k1 = 1.5;
    const b = 0.75;
    const catLen = catTokens.length;
    const avgdl = catLen;

    let score = 0.0;
    for (const term of queryTokens) {
      if (catTermFreq[term] !== undefined) {
        const tf = catTermFreq[term];
        const idf = Math.log(2); // 简化：假设只有1个文档
        const numerator = tf * (k1 + 1);
        const denominator = tf + k1 * (1 - b + b * catLen / avgdl);
        score += idf * numerator / denominator;
      }
    }

    // 归一化
    if (score > 0) {
      score = score / (1 + score);
    }

    return Math.min(score, 1.0);
  }

  /**
   * 计算关键词相似度（Jaccard）
   */
  private computeKeywordSimilarity(queryKeywords: string[], categoryKeywords: string[]): number {
    if (!queryKeywords || queryKeywords.length === 0 || !categoryKeywords || categoryKeywords.length === 0) {
      return 0.0;
    }

    return KeywordSimilarity.jaccardSimilarity(queryKeywords, categoryKeywords);
  }

  /**
   * 聚类分类
   * 使用SemanticClustering服务
   */
  private classifyWithCluster(block: SemanticBlock): ClassificationResult {
    const clusterResult = this.semanticClustering.cluster(block);
    const allScores = this.semanticClustering.getCategoryScores(block);

    return {
      blockId: block.blockId,
      categoryName: clusterResult.clusterName,
      confidence: clusterResult.confidence,
      allScores: allScores
    };
  }

  /**
   * LLM分类（异步）
   * 由于LLM调用是异步的，这里返回一个Promise
   */
  async classifyWithLLMAsync(block: SemanticBlock, imagePath?: string): Promise<ClassificationResult> {
    // 检查LLM服务可用性
    if (!this.llamaNapi && !this.context) {
      console.warn('[LocalClassificationService] LLM not available, fallback to similarity');
      return this.classifyWithSimilarity(block);
    }

    const defaultResult: ClassificationResult = {
      blockId: block.blockId,
      categoryName: '其他',
      confidence: 0.0,
      allScores: { '其他': 0.0 }
    };

    try {
      // 构建分类prompt
      const prompt = this.buildClassificationPrompt(block.textDescription);

      // 如果有图片路径，使用图片分类
      if (imagePath && this.llamaNapi && this.llamaNapi.isLoaded()) {
        // 图片分类需要调用图片caption服务，然后基于caption分类
        // 这里简化处理：先获取caption，再分类
        console.info(`[LocalClassificationService] LLM classification with image: ${imagePath}`);
      }

      // 文本分类 - 使用generate方法
      if (this.llamaNapi && this.llamaNapi.isLoaded()) {
        const response = await this.llamaNapi.generate(prompt, 64);
        const parsedResult = this.parseLLMResponse(response);
        return {
          blockId: block.blockId,
          categoryName: parsedResult.category,
          confidence: parsedResult.confidence,
          allScores: this.buildAllScoresFromCategory(parsedResult.category, parsedResult.confidence)
        };
      }

      return defaultResult;
    } catch (e) {
      console.error(`[LocalClassificationService] LLM classification failed: ${e}`);
      return defaultResult;
    }
  }

  /**
   * LLM分类（同步版本，返回fallback结果）
   */
  private classifyWithLLM(block: SemanticBlock): ClassificationResult {
    // LLM是异步调用，同步版本返回默认结果并提示需要异步调用
    console.warn('[LocalClassificationService] LLM classification requires async call, use classifyWithLLMAsync');
    return {
      blockId: block.blockId,
      categoryName: '其他',
      confidence: 0.0,
      allScores: { '其他': 0.0 }
    };
  }

  /**
   * 构建分类prompt
   */
  private buildClassificationPrompt(text: string): string {
    const categoryList = this.categoryNames.join(', ');
    return `请将以下文本分类到最合适的类别中。

类别列表：${categoryList}

文本内容：
${text.substring(0, 500)}

请回答最合适的类别名称和置信度（0-1之间的数字），格式为：
类别: xxx
置信度: 0.xx

只输出分类结果，不要解释。`;
  }

  /**
   * 解析LLM响应
   */
  private parseLLMResponse(response: string): LLMParseResult {
    const defaultResult: LLMParseResult = { category: '其他', confidence: 0.5 };

    if (!response) {
      return defaultResult;
    }

    // 尝试解析类别和置信度
    const categoryMatch = response.match(/类别[：:]\s*([^\n]+)/);
    const confidenceMatch = response.match(/置信度[：:]\s*([\d.]+)/);

    let category = defaultResult.category;
    let confidence = defaultResult.confidence;

    if (categoryMatch) {
      const extractedCategory = categoryMatch[1].trim();
      // 检查是否在类别列表中
      if (this.categoryNames.includes(extractedCategory)) {
        category = extractedCategory;
      }
    }

    if (confidenceMatch) {
      const extractedConfidence = parseFloat(confidenceMatch[1]);
      if (extractedConfidence >= 0 && extractedConfidence <= 1) {
        confidence = extractedConfidence;
      }
    }

    const result: LLMParseResult = { category, confidence };
    return result;
  }

  /**
   * 构建allScores从单个类别
   */
  private buildAllScoresFromCategory(category: string, confidence: number): Record<string, number> {
    const allScores: Record<string, number> = {};
    for (const name of this.categoryNames) {
      allScores[name] = 0.0;
    }
    allScores[category] = confidence;
    return allScores;
  }

  /**
   * 文本分词
   */
  private tokenize(text: string): string[] {
    const tokens: string[] = [];
    // 中文按字符分
    const chinesePattern = /[\u4e00-\u9fff]+/g;
    const chineseMatches = text.match(chinesePattern) || [];
    for (const match of chineseMatches) {
      for (let i = 0; i < match.length; i++) {
        tokens.push(match[i]);
      }
    }
    // 英文按单词分
    const englishPattern = /[a-zA-Z]+/g;
    const englishMatches = text.match(englishPattern) || [];
    for (const match of englishMatches) {
      tokens.push(match.toLowerCase());
    }
    return tokens;
  }

  /**
   * 获取所有类别名称
   */
  getCategoryNames(): string[] {
    return this.categoryNames;
  }

  /**
   * 获取类别描述
   */
  getCategoryDescription(name: string): string {
    return this.categoryDescriptions[name] || '';
  }

  /**
   * 使用语义块进行分类（兼容旧接口）
   */
  classifyBySemanticBlock(semanticBlock: SemanticBlock): ClassificationResult {
    return this.classifyBlock(semanticBlock);
  }

  /**
   * 根据文本内容分类（关键词匹配备选）
   */
  classifyText(text: string): ClassificationResult {
    const scores: Record<string, number> = {};
    let maxScore = 0;
    let maxCategory = '其他';

    for (const cat of this.categories) {
      const score = this.calculateKeywordMatchScore(text, cat.keywords);
      scores[cat.name] = score;

      if (score > maxScore) {
        maxScore = score;
        maxCategory = cat.name;
      }
    }

    // 归一化置信度
    const totalScore = Object.values(scores).reduce((a, b) => a + b, 0);
    const confidence = totalScore > 0 ? maxScore / totalScore : 0;

    return {
      blockId: '',
      categoryName: maxCategory,
      confidence: confidence,
      allScores: scores
    };
  }

  /**
   * 计算关键词匹配得分
   */
  private calculateKeywordMatchScore(text: string, keywords: string[]): number {
    if (keywords.length === 0) return 0;

    const lowerText = text.toLowerCase();
    let matchCount = 0;

    for (const keyword of keywords) {
      if (lowerText.includes(keyword.toLowerCase())) {
        matchCount++;
      }
    }

    const keywordRatio = matchCount / keywords.length;
    return Math.min(keywordRatio, 1.0);
  }

  /**
   * 根据文件类型推断分类
   */
  classifyByFileType(fileType: string): ClassificationResult {
    const typeCategoryMap: Record<string, string> = {
      'jpg': '个人文档', 'jpeg': '个人文档', 'png': '个人文档',
      'gif': '个人文档', 'bmp': '个人文档', 'webp': '个人文档',
      'mp4': '个人文档', 'mov': '个人文档', 'avi': '个人文档',
      'mp3': '个人文档', 'wav': '个人文档',
      'json': '技术文档', 'xml': '技术文档', 'html': '技术文档',
      'css': '技术文档', 'js': '技术文档', 'py': '技术文档',
      'java': '技术文档', 'cpp': '技术文档', 'c': '技术文档', 'h': '技术文档'
    };

    const lowerType = fileType.toLowerCase().replace('.', '');
    const category = typeCategoryMap[lowerType] || '其他';

    const scores: Record<string, number> = {};
    for (const name of this.categoryNames) {
      scores[name] = name === category ? 1.0 : 0.0;
    }

    return {
      blockId: '',
      categoryName: category,
      confidence: category !== '其他' ? 0.9 : 0.3,
      allScores: scores
    };
  }

  /**
   * 综合分类
   */
  classify(textOrBlock: string | SemanticBlock, fileType?: string): ClassificationResult {
    if (typeof textOrBlock !== 'string') {
      // 语义块分类
      const semanticResult = this.classifyBySemanticBlock(textOrBlock);

      if (fileType) {
        const typeResult = this.classifyByFileType(fileType);
        if (semanticResult.confidence < 0.3 && typeResult.confidence > 0.8) {
          return typeResult;
        }
      }

      return semanticResult;
    }

    // 字符串输入：关键词匹配分类
    const text = textOrBlock;
    const textResult = this.classifyText(text);

    let typeResult: ClassificationResult;
    if (fileType) {
      typeResult = this.classifyByFileType(fileType);
    } else {
      typeResult = {
        blockId: '',
        categoryName: '其他',
        confidence: 0,
        allScores: {}
      };
    }

    if (text.length < 50 || textResult.confidence < 0.2) {
      return typeResult;
    }

    if (typeResult.confidence > 0.8 && typeResult.categoryName !== '其他') {
      return typeResult;
    }

    // 综合两种结果
    const combinedScores: Record<string, number> = {};
    for (const name of this.categoryNames) {
      const textScore = textResult.allScores[name] || 0;
      const typeScore = typeResult.allScores[name] || 0;
      combinedScores[name] = textScore * 0.7 + typeScore * 0.3;
    }

    let maxScore = 0;
    let maxCategory = '其他';
    for (const name of this.categoryNames) {
      if (combinedScores[name] > maxScore) {
        maxScore = combinedScores[name];
        maxCategory = name;
      }
    }

    const totalScore = Object.values(combinedScores).reduce((a, b) => a + b, 0);
    const confidence = totalScore > 0 ? maxScore / totalScore : 0;

    return {
      blockId: '',
      categoryName: maxCategory,
      confidence: confidence,
      allScores: combinedScores
    };
  }

  /**
   * 获取所有分类类别（兼容旧接口）
   */
  getCategories(): string[] {
    return this.categoryNames;
  }

  /**
   * 获取配置信息
   */
  getConfig(): ConfigOutput {
    const categoryOutputs: CategoryConfigOutput[] = [];
    for (const c of this.categories) {
      const output: CategoryConfigOutput = {
        name: c.name,
        description: c.description,
        keywords: c.keywords
      };
      categoryOutputs.push(output);
    }

    const config: ConfigOutput = {
      classification_method: this.classificationMethod,
      similarity_weights: this.weights,
      categories: categoryOutputs
    };
    return config;
  }
}