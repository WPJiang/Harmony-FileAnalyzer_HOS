import { SemanticBlock, SimilarityResult, SemanticCategory, ClusterResult } from '../models/Index';

export class VectorSimilarity {
  static cosineSimilarity(vec1: number[], vec2: number[]): number {
    if (!vec1 || !vec2 || vec1.length === 0 || vec2.length === 0) {
      return 0.0;
    }

    if (vec1.length !== vec2.length) {
      return 0.0;
    }

    let dotProduct = 0;
    let norm1 = 0;
    let norm2 = 0;

    for (let i = 0; i < vec1.length; i++) {
      dotProduct += vec1[i] * vec2[i];
      norm1 += vec1[i] * vec1[i];
      norm2 += vec2[i] * vec2[i];
    }

    const denominator = Math.sqrt(norm1) * Math.sqrt(norm2);
    if (denominator === 0) {
      return 0.0;
    }

    return dotProduct / denominator;
  }

  static cosineSimilarityMatrix(
    queryVectors: number[][],
    targetVectors: number[][]
  ): number[][] {
    const result: number[][] = [];

    for (const queryVec of queryVectors) {
      const row: number[] = [];
      for (const targetVec of targetVectors) {
        row.push(VectorSimilarity.cosineSimilarity(queryVec, targetVec));
      }
      result.push(row);
    }

    return result;
  }
}

export class KeywordSimilarity {
  static jaccardSimilarity(keywords1: string[], keywords2: string[]): number {
    if (!keywords1 || !keywords2 || keywords1.length === 0 || keywords2.length === 0) {
      return 0.0;
    }

    const set1 = new Set<string>(keywords1);
    const set2 = new Set<string>(keywords2);

    let intersectionCount = 0;
    set1.forEach(item => {
      if (set2.has(item)) {
        intersectionCount++;
      }
    });

    const unionCount = set1.size + set2.size - intersectionCount;

    if (unionCount === 0) {
      return 0.0;
    }

    return intersectionCount / unionCount;
  }

  static overlapCoefficient(keywords1: string[], keywords2: string[]): number {
    if (!keywords1 || !keywords2 || keywords1.length === 0 || keywords2.length === 0) {
      return 0.0;
    }

    const set1 = new Set<string>(keywords1);
    const set2 = new Set<string>(keywords2);

    let intersectionCount = 0;
    set1.forEach(item => {
      if (set2.has(item)) {
        intersectionCount++;
      }
    });

    const minSize = Math.min(set1.size, set2.size);

    if (minSize === 0) {
      return 0.0;
    }

    return intersectionCount / minSize;
  }
}

/**
 * TimeSimilarity - 时间相似度计算
 *
 * 从文本中提取时间表达，计算时间相似度
 */
export class TimeSimilarity {
  private static TIME_PATTERNS: RegExp[] = [
    /\d{4}-\d{2}-\d{2}/g,                    // 2024-01-15
    /\d{4}\/\d{2}\/\d{2}/g,                  // 2024/01/15
    /\d{4}年\d{1,2}月\d{1,2}日/g,             // 2024年1月15日
    /\d{1,2}月\d{1,2}日/g,                    // 1月15日
    /\d{4}年/g,                               // 2024年
    /\d{4}/g                                  // 独立年份
  ];

  static extractTimes(text: string): string[] {
    if (!text) return [];

    const times: string[] = [];
    for (const pattern of TimeSimilarity.TIME_PATTERNS) {
      const matches = text.match(pattern);
      if (matches) {
        for (const match of matches) {
          times.push(match);
        }
      }
    }

    const uniqueTimes: string[] = [];
    const seenTimes: Set<string> = new Set();
    for (const t of times) {
      if (!seenTimes.has(t)) {
        seenTimes.add(t);
        uniqueTimes.push(t);
      }
    }
    return uniqueTimes;
  }

  static timeSimilarity(times1: string[], times2: string[]): number {
    if (!times1 || !times2 || times1.length === 0 || times2.length === 0) {
      return 0.0;
    }

    let maxSim = 0.0;
    for (const t1 of times1) {
      for (const t2 of times2) {
        const sim = TimeSimilarity.computeTimeSimilarity(t1, t2);
        maxSim = Math.max(maxSim, sim);
      }
    }

    return maxSim;
  }

  private static computeTimeSimilarity(time1: string, time2: string): number {
    const year1 = TimeSimilarity.parseYear(time1);
    const year2 = TimeSimilarity.parseYear(time2);

    if (year1 === null || year2 === null) {
      return 0.0;
    }

    const yearDiff = Math.abs(year1 - year2);

    if (yearDiff === 0) {
      const month1 = TimeSimilarity.parseMonth(time1);
      const month2 = TimeSimilarity.parseMonth(time2);

      if (month1 !== null && month2 !== null) {
        if (month1 === month2) {
          const day1 = TimeSimilarity.parseDay(time1);
          const day2 = TimeSimilarity.parseDay(time2);

          if (day1 !== null && day2 !== null) {
            return day1 === day2 ? 1.0 : 0.8;
          }
          return 0.9;
        } else {
          const monthDiff = Math.abs(month1 - month2);
          return Math.max(0.0, 1.0 - monthDiff / 12.0);
        }
      }
      return 0.9;
    }

    if (yearDiff <= 1) {
      return Math.max(0.0, 1.0 - yearDiff * 0.3);
    } else if (yearDiff <= 5) {
      return Math.max(0.0, 0.7 - (yearDiff - 1) * 0.1);
    } else {
      return Math.max(0.0, 0.4 - (yearDiff - 5) * 0.05);
    }
  }

  private static parseYear(timeStr: string): number | null {
    const yearMatch = timeStr.match(/(\d{4})/);
    if (yearMatch) {
      return parseInt(yearMatch[1]);
    }
    return null;
  }

  private static parseMonth(timeStr: string): number | null {
    const monthMatch = timeStr.match(/(\d{1,2})月/);
    if (monthMatch) {
      return parseInt(monthMatch[1]);
    }

    if (timeStr.includes('-') || timeStr.includes('/')) {
      const parts = timeStr.split(/[-\/]/);
      if (parts.length >= 2) {
        return parseInt(parts[1]);
      }
    }
    return null;
  }

  private static parseDay(timeStr: string): number | null {
    const dayMatch = timeStr.match(/(\d{1,2})日/);
    if (dayMatch) {
      return parseInt(dayMatch[1]);
    }

    if (timeStr.includes('-') || timeStr.includes('/')) {
      const parts = timeStr.split(/[-\/]/);
      if (parts.length >= 3) {
        return parseInt(parts[2]);
      }
    }
    return null;
  }
}

/**
 * LocationSimilarity - 地点相似度计算
 *
 * 从文本中提取地点表达，计算地点相似度
 */
export class LocationSimilarity {
  private static LOCATION_PATTERNS: RegExp[] = [
    /[\u4e00-\u9fa5]+省/g,
    /[\u4e00-\u9fa5]+市/g,
    /[\u4e00-\u9fa5]+区/g,
    /[\u4e00-\u9fa5]+县/g,
    /(北京|上海|广州|深圳|杭州|南京|武汉|成都|重庆|西安|天津|苏州|长沙|郑州|济南|青岛|沈阳|大连|厦门|宁波)/g,
    /[\u4e00-\u9fa5]+路/g,
    /[\u4e00-\u9fa5]+街/g,
    /[\u4e00-\u9fa5]+道/g
  ];

  private static COMMON_LOCATIONS: Map<string, string> = new Map([
    ['北京', '北京'],
    ['上海', '上海'],
    ['广州', '广州'],
    ['深圳', '深圳'],
    ['杭州', '杭州'],
    ['南京', '南京'],
    ['武汉', '武汉'],
    ['成都', '成都'],
    ['重庆', '重庆'],
    ['西安', '西安']
  ]);

  static extractLocations(text: string): string[] {
    if (!text) return [];

    const locations: string[] = [];
    for (const pattern of LocationSimilarity.LOCATION_PATTERNS) {
      const matches = text.match(pattern);
      if (matches) {
        for (const match of matches) {
          const normalized = LocationSimilarity.COMMON_LOCATIONS.get(match) || match;
          locations.push(normalized);
        }
      }
    }

    const uniqueLocations: string[] = [];
    const seenLocations: Set<string> = new Set();
    for (const loc of locations) {
      if (!seenLocations.has(loc)) {
        seenLocations.add(loc);
        uniqueLocations.push(loc);
      }
    }
    return uniqueLocations;
  }

  static locationSimilarity(locations1: string[], locations2: string[]): number {
    if (!locations1 || !locations2 || locations1.length === 0 || locations2.length === 0) {
      return 0.0;
    }

    const set1 = new Set(locations1);
    const set2 = new Set(locations2);

    // 检查是否有交集
    const intersectionList: string[] = [];
    set1.forEach(item => {
      if (set2.has(item)) {
        intersectionList.push(item);
      }
    });
    if (intersectionList.length > 0) {
      return 1.0;
    }

    // 计算最相似的地点对
    let maxSim = 0.0;
    for (const loc1 of set1) {
      for (const loc2 of set2) {
        const sim = LocationSimilarity.computeLocationSimilarity(loc1, loc2);
        maxSim = Math.max(maxSim, sim);
      }
    }

    return maxSim;
  }

  private static computeLocationSimilarity(loc1: string, loc2: string): number {
    if (loc1 === loc2) {
      return 1.0;
    }

    // 清理地名后缀
    const loc1Clean = loc1.replace(/市|省|区|县/g, '');
    const loc2Clean = loc2.replace(/市|省|区|县/g, '');

    if (loc1Clean === loc2Clean) {
      return 0.9;
    }

    // 检查是否是常见城市
    const commonCities = ['北京', '上海', '广州', '深圳', '杭州', '南京', '武汉', '成都', '重庆', '西安'];
    const idx1 = commonCities.indexOf(loc1Clean);
    const idx2 = commonCities.indexOf(loc2Clean);

    if (idx1 >= 0 && idx2 >= 0) {
      const diff = Math.abs(idx1 - idx2);
      return Math.max(0.3, 1.0 - diff * 0.15);
    }

    return 0.0;
  }
}

export class BM25 {
  private k1: number;
  private b: number;
  private docFreqs: Map<string, number> = new Map();
  private docLen: number[] = [];
  private avgdl: number = 0;
  private docTermFreqs: Map<string, number>[] = [];
  private nDocs: number = 0;
  private idf: Map<string, number> = new Map();

  constructor(k1: number = 1.5, b: number = 0.75) {
    this.k1 = k1;
    this.b = b;
  }

  fit(documents: string[][]): void {
    this.nDocs = documents.length;
    this.docLen = documents.map(doc => doc.length);
    this.avgdl = this.docLen.reduce((a, b) => a + b, 0) / this.nDocs;

    this.docFreqs.clear();
    this.docTermFreqs = [];

    for (const doc of documents) {
      const termFreqs = new Map<string, number>();
      for (const term of doc) {
        const freq = termFreqs.get(term);
        if (freq !== undefined) {
          termFreqs.set(term, freq + 1);
        } else {
          termFreqs.set(term, 1);
        }
      }
      this.docTermFreqs.push(termFreqs);

      const keys = Array.from(termFreqs.keys());
      for (const term of keys) {
        const freq = this.docFreqs.get(term);
        if (freq !== undefined) {
          this.docFreqs.set(term, freq + 1);
        } else {
          this.docFreqs.set(term, 1);
        }
      }
    }

    this.calcIdf();
  }

  private calcIdf(): void {
    this.idf.clear();
    const entries = Array.from(this.docFreqs.entries());
    for (const entry of entries) {
      const term = entry[0];
      const freq = entry[1];
      const idfValue = Math.log((this.nDocs - freq + 0.5) / (freq + 0.5) + 1);
      this.idf.set(term, idfValue);
    }
  }

  getScore(query: string[], docIdx: number): number {
    if (docIdx >= this.docTermFreqs.length) {
      return 0.0;
    }

    let score = 0.0;
    const docTermFreq = this.docTermFreqs[docIdx];
    const docLen = this.docLen[docIdx];

    for (const term of query) {
      const tf = docTermFreq.get(term);
      if (!tf) continue;

      const idfValue = this.idf.get(term);
      const idf = idfValue !== undefined ? idfValue : 0;

      const numerator = tf * (this.k1 + 1);
      const denominator = tf + this.k1 * (1 - this.b + this.b * docLen / this.avgdl);
      score += idf * numerator / denominator;
    }

    return score;
  }

  getScores(query: string[]): number[] {
    const scores: number[] = [];
    for (let i = 0; i < this.nDocs; i++) {
      scores.push(this.getScore(query, i));
    }
    return scores;
  }
}

interface SimilarityConfig {
  vectorWeight?: number;
  bm25Weight?: number;
  keywordWeight?: number;
}

export class SemanticSimilarity {
  private vectorWeight: number = 0.35;
  private bm25Weight: number = 0.25;
  private keywordWeight: number = 0.25;
  private timeWeight: number = 0.08;
  private locationWeight: number = 0.07;

  private bm25: BM25;
  private isFitted: boolean = false;
  private targetBlocks: SemanticBlock[] = [];
  private targetVectors: number[][] = [];
  // 缓存时间和地点提取结果
  private targetTimes: Map<string, string[]> = new Map();
  private targetLocations: Map<string, string[]> = new Map();

  constructor(config?: SimilarityConfig) {
    if (config) {
      if (config.vectorWeight !== undefined) this.vectorWeight = config.vectorWeight;
      if (config.bm25Weight !== undefined) this.bm25Weight = config.bm25Weight;
      if (config.keywordWeight !== undefined) this.keywordWeight = config.keywordWeight;
    }
    this.bm25 = new BM25();
  }

  fit(targetBlocks: SemanticBlock[]): void {
    this.targetBlocks = targetBlocks;
    const documents: string[][] = [];
    const vectors: number[][] = [];

    // 清空缓存
    this.targetTimes.clear();
    this.targetLocations.clear();

    for (const block of targetBlocks) {
      documents.push(this.tokenize(block.textDescription));
      if (block.semanticVector && block.semanticVector.length > 0) {
        vectors.push(block.semanticVector);
      }
      // 预计算时间和地点
      this.targetTimes.set(block.blockId, TimeSimilarity.extractTimes(block.textDescription));
      this.targetLocations.set(block.blockId, LocationSimilarity.extractLocations(block.textDescription));
    }

    this.bm25.fit(documents);
    this.targetVectors = vectors;
    this.isFitted = true;
  }

  computeSimilarity(queryBlock: SemanticBlock, targetBlock: SemanticBlock): SimilarityResult {
    const vectorSim = VectorSimilarity.cosineSimilarity(
      queryBlock.semanticVector,
      targetBlock.semanticVector
    );

    const queryTokens = this.tokenize(queryBlock.textDescription);
    const targetTokens = this.tokenize(targetBlock.textDescription);

    const bm25Scorer = new BM25();
    bm25Scorer.fit([targetTokens]);
    const bm25Score = bm25Scorer.getScore(queryTokens, 0);

    const keywordSim = KeywordSimilarity.jaccardSimilarity(
      queryBlock.keywords,
      targetBlock.keywords
    );

    // 计算时间相似度
    const queryTimes = TimeSimilarity.extractTimes(queryBlock.textDescription);
    const targetTimes = TimeSimilarity.extractTimes(targetBlock.textDescription);
    const timeSim = TimeSimilarity.timeSimilarity(queryTimes, targetTimes);

    // 计算地点相似度
    const queryLocations = LocationSimilarity.extractLocations(queryBlock.textDescription);
    const targetLocations = LocationSimilarity.extractLocations(targetBlock.textDescription);
    const locationSim = LocationSimilarity.locationSimilarity(queryLocations, targetLocations);

    const fusedScore = this.fuseScores(vectorSim, bm25Score, keywordSim, timeSim, locationSim);

    const result = new SimilarityResult();
    result.queryId = queryBlock.blockId;
    result.targetId = targetBlock.blockId;
    result.vectorSimilarity = vectorSim;
    result.bm25Score = bm25Score;
    result.keywordSimilarity = keywordSim;
    result.timeSimilarity = timeSim;
    result.locationSimilarity = locationSim;
    result.fusedScore = fusedScore;
    return result;
  }

  search(queryBlock: SemanticBlock, topK: number = 10, minScore: number = 0): SimilarityResult[] {
    if (!this.isFitted) {
      throw new Error('Model not fitted. Call fit() first.');
    }

    const results: SimilarityResult[] = [];
    const queryTokens = this.tokenize(queryBlock.textDescription);
    const bm25Scores = this.bm25.getScores(queryTokens);

    // 提取查询的时间和地点
    const queryTimes = TimeSimilarity.extractTimes(queryBlock.textDescription);
    const queryLocations = LocationSimilarity.extractLocations(queryBlock.textDescription);

    const vectorScores: number[] = [];
    if (this.targetVectors.length > 0 && queryBlock.semanticVector && queryBlock.semanticVector.length > 0) {
      for (const targetVec of this.targetVectors) {
        vectorScores.push(VectorSimilarity.cosineSimilarity(queryBlock.semanticVector, targetVec));
      }
    } else {
      for (let i = 0; i < this.targetBlocks.length; i++) {
        vectorScores.push(0);
      }
    }

    for (let i = 0; i < this.targetBlocks.length; i++) {
      const block = this.targetBlocks[i];
      const keywordSim = KeywordSimilarity.jaccardSimilarity(
        queryBlock.keywords,
        block.keywords
      );

      // 从缓存获取时间和地点
      const targetTimes = this.targetTimes.get(block.blockId) || [];
      const targetLocations = this.targetLocations.get(block.blockId) || [];

      const timeSim = TimeSimilarity.timeSimilarity(queryTimes, targetTimes);
      const locationSim = LocationSimilarity.locationSimilarity(queryLocations, targetLocations);

      const vectorScore = vectorScores[i] !== undefined ? vectorScores[i] : 0;
      const bm25Normalized = this.normalizeBm25(bm25Scores[i]);
      const fusedScore = this.fuseScores(
        vectorScore,
        bm25Normalized,
        keywordSim,
        timeSim,
        locationSim
      );

      if (fusedScore >= minScore) {
        const result = new SimilarityResult();
        result.queryId = queryBlock.blockId;
        result.targetId = block.blockId;
        result.vectorSimilarity = vectorScore;
        result.bm25Score = bm25Scores[i];
        result.keywordSimilarity = keywordSim;
        result.timeSimilarity = timeSim;
        result.locationSimilarity = locationSim;
        result.fusedScore = fusedScore;
        results.push(result);
      }
    }

    results.sort((a, b) => b.fusedScore - a.fusedScore);
    return results.slice(0, topK);
  }

  private tokenize(text: string): string[] {
    const tokens: string[] = [];
    const chinesePattern = /[\u4e00-\u9fff]+/g;
    const englishPattern = /[a-zA-Z]+/g;

    const chineseMatches = text.match(chinesePattern) || [];
    for (const match of chineseMatches) {
      for (let i = 0; i < match.length; i++) {
        tokens.push(match[i]);
      }
    }

    const englishMatches = text.match(englishPattern) || [];
    for (const match of englishMatches) {
      tokens.push(match.toLowerCase());
    }

    return tokens;
  }

  private fuseScores(
    vectorSim: number,
    bm25Score: number,
    keywordSim: number,
    timeSim: number,
    locationSim: number
  ): number {
    return (
      this.vectorWeight * vectorSim +
      this.bm25Weight * bm25Score +
      this.keywordWeight * keywordSim +
      this.timeWeight * timeSim +
      this.locationWeight * locationSim
    );
  }

  private normalizeBm25(score: number): number {
    return 1 - Math.exp(-score / 10);
  }
}

export class SemanticClustering {
  private categories: SemanticCategory[] = [];
  private categoryVectors: number[][] = [];
  private initialized: boolean = false;

  constructor() {
    this.initializeDefaultCategories();
  }

  private initializeDefaultCategories(): void {
    this.categories = [];

    let cat = new SemanticCategory();
    cat.setName('技术文档');
    cat.setDescription('技术规范、API文档、技术手册等');
    cat.setKeywords(['技术', 'API', '接口', '开发', '代码', '系统', '架构', '配置', '部署', '服务器']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('商业报告');
    cat.setDescription('商业计划、市场分析、财务报告等');
    cat.setKeywords(['市场', '销售', '收入', '利润', '客户', '竞争', '战略', '投资', '商业', '业务']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('学术论文');
    cat.setDescription('研究论文、学术文章、研究报告等');
    cat.setKeywords(['研究', '实验', '方法', '结果', '分析', '理论', '模型', '数据', '论文', '引用']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('会议演示');
    cat.setDescription('会议PPT、演讲稿、培训材料等');
    cat.setKeywords(['会议', '演示', '培训', '演讲', 'PPT', '展示', '介绍', '汇报', '方案', '计划']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('合同协议');
    cat.setDescription('合同、协议、法律文件等');
    cat.setKeywords(['合同', '协议', '条款', '甲方', '乙方', '法律', '责任', '义务', '权利', '签署']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('产品说明');
    cat.setDescription('产品手册、使用指南、说明书等');
    cat.setKeywords(['产品', '功能', '使用', '操作', '说明', '指南', '特性', '规格', '型号', '安装']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('新闻资讯');
    cat.setDescription('新闻报道、新闻稿、媒体文章等');
    cat.setKeywords(['新闻', '报道', '发布', '消息', '媒体', '记者', '事件', '宣布', '最新', '动态']);
    this.categories.push(cat);

    cat = new SemanticCategory();
    cat.setName('个人文档');
    cat.setDescription('简历、个人陈述、信函等');
    cat.setKeywords(['个人', '简历', '经历', '教育', '技能', '自我', '介绍', '申请', '工作', '职位']);
    this.categories.push(cat);
  }

  initialize(): void {
    this.computeCategoryCenters();
    this.initialized = true;
  }

  private computeCategoryCenters(): void {
    this.categoryVectors = [];

    for (const category of this.categories) {
      const center = this.computeCenter(category);
      this.categoryVectors.push(center);
      category.setCenterVector(center);
    }
  }

  private computeCenter(category: SemanticCategory): number[] {
    const dim = 384;
    const vector: number[] = [];
    for (let i = 0; i < dim; i++) {
      vector.push(0);
    }
    const texts: string[] = [category.description];
    for (const k of category.keywords) {
      texts.push(k);
    }
    const count = texts.length;

    for (const text of texts) {
      const hash = this.simpleHash(text);
      for (let i = 0; i < dim; i++) {
        vector[i] += (hash * (i + 1)) % 100 / 100;
      }
    }

    for (let i = 0; i < dim; i++) {
      vector[i] /= count;
    }

    return this.normalize(vector);
  }

  private simpleHash(text: string): number {
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
      hash = ((hash << 5) - hash) + text.charCodeAt(i);
      hash = hash & hash;
    }
    return Math.abs(hash);
  }

  private normalize(vector: number[]): number[] {
    let sum = 0;
    for (const val of vector) {
      sum += val * val;
    }
    const norm = Math.sqrt(sum);
    if (norm === 0) return vector;

    const result: number[] = [];
    for (const val of vector) {
      result.push(val / norm);
    }
    return result;
  }

  cluster(block: SemanticBlock): ClusterResult {
    if (!this.initialized) {
      this.initialize();
    }

    let vector: number[];
    if (block.semanticVector && block.semanticVector.length > 0) {
      vector = block.semanticVector;
    } else {
      const tempCategory = new SemanticCategory();
      tempCategory.setDescription(block.textDescription);
      tempCategory.setKeywords(block.keywords);
      vector = this.computeCenter(tempCategory);
    }

    const distances: [number, number][] = [];
    for (let i = 0; i < this.categoryVectors.length; i++) {
      const dist = this.computeDistance(vector, this.categoryVectors[i]);
      distances.push([i, dist]);
    }

    distances.sort((a, b) => a[1] - b[1]);
    const bestEntry = distances[0];
    const bestIdx = bestEntry[0];
    const bestDist = bestEntry[1];
    const confidence = this.computeConfidence(distances);

    const result = new ClusterResult();
    result.blockId = block.blockId;
    result.clusterId = bestIdx;
    result.clusterName = this.categories[bestIdx].name;
    result.confidence = confidence;
    result.distanceToCenter = bestDist;
    return result;
  }

  clusterBatch(blocks: SemanticBlock[]): ClusterResult[] {
    const results: ClusterResult[] = [];
    for (const block of blocks) {
      results.push(this.cluster(block));
    }
    return results;
  }

  private computeDistance(vec1: number[], vec2: number[]): number {
    if (vec1.length !== vec2.length) return 1.0;

    let dot = 0;
    let norm1 = 0;
    let norm2 = 0;

    for (let i = 0; i < vec1.length; i++) {
      dot += vec1[i] * vec2[i];
      norm1 += vec1[i] * vec1[i];
      norm2 += vec2[i] * vec2[i];
    }

    const denominator = Math.sqrt(norm1) * Math.sqrt(norm2);
    if (denominator === 0) return 1.0;

    return 1 - dot / denominator;
  }

  private computeConfidence(distances: [number, number][]): number {
    if (distances.length < 2) return 1.0;

    const bestDist = distances[0][1];
    const secondDist = distances[1][1];

    if (secondDist === 0) return 0.5;

    const ratio = bestDist / secondDist;
    return Math.max(0, Math.min(1, 1 - ratio));
  }

  getCategoryNames(): string[] {
    return this.categories.map(c => c.name);
  }

  getCategoryScores(block: SemanticBlock): Record<string, number> {
    if (!this.initialized) {
      this.initialize();
    }

    let vector: number[];
    if (block.semanticVector && block.semanticVector.length > 0) {
      vector = block.semanticVector;
    } else {
      const tempCategory = new SemanticCategory();
      tempCategory.setDescription(block.textDescription);
      tempCategory.setKeywords(block.keywords);
      vector = this.computeCenter(tempCategory);
    }

    const scores: Record<string, number> = {};
    for (let i = 0; i < this.categoryVectors.length; i++) {
      const dist = this.computeDistance(vector, this.categoryVectors[i]);
      const similarity = Math.max(0, Math.min(1, 1 - dist));
      scores[this.categories[i].name] = similarity;
    }

    return scores;
  }
}
