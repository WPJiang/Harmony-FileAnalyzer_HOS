# HarmonyOS文件分析器完整实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** 完整复现Python工程file_analyzer的所有功能到HarmonyOS手机应用，一对一实现所有模块

**Architecture:**
- 本地处理：文件解析、OCR、语义表征（含embedding向量）、BM25、相似度融合
- 云LLM：图片Caption生成（可选）
- 数据库：SQLite存储文件、数据块、语义块、分类结果

**Tech Stack:** HarmonyOS ArkTS/ETS + @kit.CoreFileKit + @hms.ai.ocr + @hms.data.retrieval + SQLite

---

## 问题分析：当前实现的缺陷

### 用户反馈
> "处理流程的功能划分不对。语义表征不是只做关键词提取，分类也不是只用关键词匹配。"

### 当前实现vs原始需求对比

| 功能模块 | Python原始实现 | 当前HarmonyOS实现 | 问题 |
|---------|---------------|------------------|------|
| 语义表征 | 文本描述+关键词+jieba分词+embedding向量 | 仅关键词提取 | ❌ 缺少embedding向量生成 |
| 相似度计算 | BM25+向量余弦+Jaccard+时间+地点融合 | 无 | ❌ 完全缺失 |
| 分类 | 相似度融合(0.35+0.25+0.25+0.08+0.07) | 关键词匹配 | ❌ 简化为关键词匹配 |
| 聚类 | KMeans+8个默认类别+增量随机类别 | 无 | ❌ 完全缺失 |
| 语义查询 | 向量搜索+BM25+关键词混合检索 | 简单名称搜索 | ❌ 缺少向量搜索 |

---

## 模块映射：Python → HarmonyOS

### 1. 数据解析模块 (data_parser)
**Python文件:** `data_parser/*.py`
**HarmonyOS路径:** `entry/src/main/ets/parser/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| DataParser | 解析调度器 | DataParser.ets | ✅ 已有框架 |
| BaseParser | 解析基类 | BaseParser.ets | ✅ 已有 |
| PDFParser | PDF解析 | PDFParser.ets | ⚠️ 需完善 |
| ImageParser | 图片解析+OCR | ImageParser.ets | ⚠️ 需完善 |
| TextParser | 文本解析 | TextParser.ets | ✅ 已有 |
| WordParser | Word解析 | - | ❌ 鸿蒙无原生API |
| ExcelParser | Excel解析 | - | ❌ 鸿蒙无原生API |
| PPTParser | PPT解析 | - | ❌ 鸿蒙无原生API |

### 2. 语义表征模块 (semantic_representation)
**Python文件:** `semantic_representation/semantic_representation.py`
**HarmonyOS路径:** `entry/src/main/ets/semantic/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| SemanticBlock | 语义块数据结构 | SemanticBlock.ets | ⚠️ 已有但不完整 |
| FilenameSemanticAnalyzer | 文件名语义分析 | - | ❌ 缺失 |
| KeywordExtractor | jieba关键词提取 | - | ❌ 需实现分词 |
| TextDescriptionGenerator | 文本描述生成 | - | ❌ 缺失 |
| ImageTextExtractor | 图片OCR提取 | LocalOCRService.ets | ✅ 已有 |
| SentenceTransformerEmbedding | SentenceBERT向量 | - | ⚠️ 需用MindSpore或HMS |
| SemanticRepresentation | 主类-语义表征生成 | SemanticRepresentation.ets | ⚠️ 不完整 |

**关键缺失:** embedding向量生成！
- Python使用 `paraphrase-multilingual-MiniLM-L12-v2` 模型
- HarmonyOS选项:
  1. `@hms.data.retrieval` - 华为向量检索API
  2. MindSpore Lite - 端侧推理
  3. 云API调用

### 3. 语义相似度模块 (semantic_similarity)
**Python文件:** `semantic_similarity/semantic_similarity.py`
**HarmonyOS路径:** `entry/src/main/ets/semantic/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| BM25 | BM25文本相关性算法 | - | ❌ 完全缺失 |
| VectorSimilarity | 向量余弦相似度 | - | ❌ 缺失 |
| KeywordSimilarity | Jaccard关键词相似度 | - | ❌ 缺失 |
| TimeSimilarity | 时间相似度 | - | ❌ 缺失 |
| LocationSimilarity | 地点相似度 | - | ❌ 缺失 |
| SemanticSimilarity | 相似度融合计算 | - | ❌ 完全缺失 |

**权重配置:**
```
vector_weight = 0.35
bm25_weight = 0.25
keyword_weight = 0.25
time_weight = 0.08
location_weight = 0.07
```

### 4. 语义分类模块 (semantic_classification)
**Python文件:** `semantic_classification/semantic_classification.py`
**HarmonyOS路径:** `entry/src/main/ets/semantic/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| SemanticClassification | 分类主类 | LocalClassificationService.ets | ❌ 简化为关键词匹配 |
| - classify_by_similarity() | 相似度分类 | - | ❌ 缺失 |
| - classify_by_llm() | LLM分类 | - | ⚠️ 云端可选 |

### 5. 语义聚类模块 (semantic_clustering)
**Python文件:** `semantic_clustering/semantic_clustering.py`
**HarmonyOS路径:** `entry/src/main/ets/semantic/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| SemanticClustering | KMeans聚类 | SemanticClustering.ets | ⚠️ 已有不完整 |
| SemanticCategory | 类别定义 | - | ❌ 缺失 |
| ClusterResult | 聚类结果 | - | ❌ 缺失 |

**默认类别 (8个):**
1. 技术文档
2. 商业报告
3. 学术论文
4. 会议演示
5. 合同协议
6. 产品说明
7. 新闻资讯
8. 个人文档

### 6. 语义查询模块 (semantic_query)
**Python文件:** `semantic_query/semantic_query.py`
**HarmonyOS路径:** `entry/src/main/ets/semantic/`

| Python类 | 功能 | HarmonyOS实现 | 状态 |
|---------|------|--------------|------|
| SemanticQuery | 语义搜索 | FileAnalysisService.searchFiles() | ⚠️ 简化为名称搜索 |
| SemanticBlockResult | 块搜索结果 | - | ❌ 缺失 |
| FileResult | 文件搜索结果 | - | ❌ 缺失 |
| SearchResult | 搜索结果 | - | ❌ 缺失 |

### 7. 数据库模块 (database)
**Python文件:** `database/database.py`
**HarmonyOS路径:** `entry/src/main/ets/database/`

| 数据表 | 功能 | HarmonyOS实现 | 状态 |
|-------|------|--------------|------|
| files | 文件记录 | DatabaseManager.ets | ✅ 已有 |
| data_blocks | 数据块 | DatabaseManager.ets | ✅ 已有 |
| semantic_blocks | 语义块 | DatabaseManager.ets | ⚠️ 需补充vector字段 |
| semantic_categories | 语义类别 | - | ❌ 缺失 |
| classification_results | 分类结果 | - | ❌ 缺失 |
| user_queries | 用户查询 | - | ❌ 缺失 |

**文件状态枚举:**
- PENDING (0) - 待处理
- PARSED (1) - 已解析
- PRELIMINARY (2) - 初步分析（语义表征完成）
- DEEP (3) - 深入分析

---

## Task 1: 实现中文分词服务

**Files:**
- Create: `entry/src/main/ets/services/JiebaService.ets`

### 背景
Python使用jieba进行中文分词，HarmonyOS无原生分词API。

### 方案
1. 移植jieba核心算法到TypeScript
2. 使用预编译的词典文件
3. 实现精确模式分词

### 1.1 分词服务实现

```typescript
// JiebaService.ets - 中文分词服务
export class JiebaService {
  private dict: Map<string, number> = new Map(); // 词语->词频
  private initialized: boolean = false;

  async initialize(): Promise<void> {
    // 加载词典文件
    const dictData = await this.loadDict();
    // 构建DAG
  }

  cut(text: string): string[] {
    // 精确模式分词
    // 基于DAG和动态规划
  }

  extractTags(text: string, topK: number): string[] {
    // TF-IDF关键词提取
  }
}
```

---

## Task 2: 实现BM25算法

**Files:**
- Create: `entry/src/main/ets/semantic/BM25.ets`

### 算法说明
BM25是文本相关性评分算法，用于衡量查询词与文档的相关性。

### 参数
- k1 = 1.5 (词频饱和参数)
- b = 0.75 (文档长度归一化参数)

### 2.1 BM25实现

```typescript
// BM25.ets
export class BM25 {
  private k1: number = 1.5;
  private b: number = 0.75;
  private docFreqs: Map<string, number> = new Map();
  private docLen: number[] = [];
  private avgdl: number = 0;
  private docTermFreqs: Map<string, number>[] = [];
  private idf: Map<string, number> = new Map();

  fit(documents: string[][]): void {
    // 计算IDF、文档长度等
  }

  getScore(query: string[], docIdx: number): number {
    // BM25公式: IDF * (tf * (k1+1)) / (tf + k1*(1-b+b*docLen/avgdl))
  }

  getScores(query: string[]): number[] {
    // 返回所有文档的BM25分数
  }
}
```

---

## Task 3: 实现向量相似度计算

**Files:**
- Create: `entry/src/main/ets/semantic/VectorSimilarity.ets`

### 3.1 余弦相似度

```typescript
// VectorSimilarity.ets
export class VectorSimilarity {
  static cosineSimilarity(vec1: number[], vec2: number[]): number {
    if (vec1.length !== vec2.length) return 0;
    
    let dot = 0, norm1 = 0, norm2 = 0;
    for (let i = 0; i < vec1.length; i++) {
      dot += vec1[i] * vec2[i];
      norm1 += vec1[i] * vec1[i];
      norm2 += vec2[i] * vec2[i];
    }
    
    const denom = Math.sqrt(norm1) * Math.sqrt(norm2);
    return denom > 0 ? dot / denom : 0;
  }

  static cosineSimilarityMatrix(
    queryVectors: number[][],
    targetVectors: number[][]
  ): number[][] {
    // 矩阵形式的批量相似度计算
  }
}
```

---

## Task 4: 实现关键词相似度

**Files:**
- Create: `entry/src/main/ets/semantic/KeywordSimilarity.ets`

### 4.1 Jaccard相似度

```typescript
// KeywordSimilarity.ets
export class KeywordSimilarity {
  static jaccardSimilarity(keywords1: string[], keywords2: string[]): number {
    const set1 = new Set(keywords1);
    const set2 = new Set(keywords2);
    
    const intersection = new Set([...set1].filter(x => set2.has(x)));
    const union = new Set([...set1, ...set2]);
    
    return union.size > 0 ? intersection.size / union.size : 0;
  }

  static overlapCoefficient(keywords1: string[], keywords2: string[]): number {
    // 重叠系数
  }
}
```

---

## Task 5: 实现时间/地点相似度

**Files:**
- Create: `entry/src/main/ets/semantic/TimeSimilarity.ets`
- Create: `entry/src/main/ets/semantic/LocationSimilarity.ets`

### 5.1 时间相似度

```typescript
// TimeSimilarity.ets
export class TimeSimilarity {
  private static TIME_PATTERNS = [
    /\d{4}-\d{2}-\d{2}/,
    /\d{4}\/\d{2}\/\d{2}/,
    /\d{4}年\d{1,2}月\d{1,2}日/,
    // ...
  ];

  static extractTimes(text: string): string[] {
    // 从文本提取时间表达
  }

  static timeSimilarity(times1: string[], times2: string[]): number {
    // 计算时间相似度
    // 同年同月同日 = 1.0
    // 同年同月不同日 = 0.8-0.9
    // 同年不同月 = 1 - 月差/12
    // 不同年 = 按年差衰减
  }
}
```

### 5.2 地点相似度

```typescript
// LocationSimilarity.ets
export class LocationSimilarity {
  private static LOCATION_PATTERNS = [
    /[\u4e00-\u9fa5]+省/,
    /[\u4e00-\u9fa5]+市/,
    /[\u4e00-\u9fa5]+区/,
    // ...
  ];

  static extractLocations(text: string): string[] {
    // 从文本提取地点
  }

  static locationSimilarity(locations1: string[], locations2: string[]): number {
    // 计算地点相似度
  }
}
```

---

## Task 6: 实现语义相似度融合

**Files:**
- Create: `entry/src/main/ets/semantic/SemanticSimilarity.ets`

### 权重配置
```typescript
const DEFAULT_WEIGHTS = {
  vector: 0.35,
  bm25: 0.25,
  keyword: 0.25,
  time: 0.08,
  location: 0.07
};
```

### 6.1 融合计算

```typescript
// SemanticSimilarity.ets
export interface SimilarityResult {
  queryId: string;
  targetId: string;
  vectorSimilarity: number;
  bm25Score: number;
  keywordSimilarity: number;
  timeSimilarity: number;
  locationSimilarity: number;
  fusedScore: number;
}

export class SemanticSimilarity {
  private vectorWeight: number = 0.35;
  private bm25Weight: number = 0.25;
  private keywordWeight: number = 0.25;
  private timeWeight: number = 0.08;
  private locationWeight: number = 0.07;

  private bm25: BM25 = new BM25();
  private targetBlocks: SemanticBlock[] = [];
  private targetVectors: number[][] = [];

  fit(targetBlocks: SemanticBlock[]): void {
    // 初始化BM25，收集向量
  }

  computeSimilarity(queryBlock: SemanticBlock, targetBlock: SemanticBlock): SimilarityResult {
    // 计算各维度相似度
    const vectorSim = VectorSimilarity.cosineSimilarity(
      queryBlock.semanticVector, targetBlock.semanticVector);
    const bm25Score = this.bm25.getScore(/*...*/);
    const keywordSim = KeywordSimilarity.jaccardSimilarity(
      queryBlock.keywords, targetBlock.keywords);
    const timeSim = TimeSimilarity.timeSimilarity(/*...*/);
    const locationSim = LocationSimilarity.locationSimilarity(/*...*/);

    // 融合
    const fusedScore = 
      this.vectorWeight * vectorSim +
      this.bm25Weight * bm25Score +
      this.keywordWeight * keywordSim +
      this.timeWeight * timeSim +
      this.locationWeight * locationSim;

    return { /*...*/ fusedScore };
  }

  search(queryBlock: SemanticBlock, topK: number): SimilarityResult[] {
    // 搜索最相似的K个块
  }
}
```

---

## Task 7: 实现语义分类服务

**Files:**
- Modify: `entry/src/main/ets/services/LocalClassificationService.ets`

### 7.1 重构分类服务

```typescript
// LocalClassificationService.ets - 重构
export class LocalClassificationService {
  private semanticSimilarity: SemanticSimilarity;
  private categories: SemanticCategory[] = [];

  async initialize(): Promise<void> {
    // 初始化默认类别
    // 初始化相似度计算器
  }

  classifyBySimilarity(semanticBlock: SemanticBlock): ClassificationResult {
    // 使用相似度融合分类
    // 计算与每个类别中心的相似度
    // 返回最佳类别和置信度
  }

  classify(text: string, fileType: string): ClassificationResult {
    // 创建临时语义块
    // 调用相似度分类
  }
}
```

---

## Task 8: 实现KMeans聚类

**Files:**
- Create: `entry/src/main/ets/semantic/KMeans.ets`
- Create: `entry/src/main/ets/semantic/SemanticClustering.ets`

### 8.1 KMeans算法

```typescript
// KMeans.ets
export class KMeans {
  private nClusters: number;
  private maxIterations: number = 100;
  private centroids: number[][] = [];

  fit(data: number[][]): void {
    // KMeans拟合
  }

  predict(point: number[]): number {
    // 预测簇标签
  }

  getCentroids(): number[][] {
    return this.centroids;
  }
}
```

### 8.2 语义聚类

```typescript
// SemanticClustering.ets
export interface ClusterResult {
  blockId: string;
  clusterId: number;
  clusterName: string;
  confidence: number;
}

export class SemanticClustering {
  private static DEFAULT_CATEGORIES: SemanticCategory[] = [
    { name: "技术文档", keywords: ["技术", "API", "接口", "开发"] },
    { name: "商业报告", keywords: ["市场", "销售", "收入", "利润"] },
    { name: "学术论文", keywords: ["研究", "实验", "方法", "结果"] },
    { name: "会议演示", keywords: ["会议", "演示", "培训", "PPT"] },
    { name: "合同协议", keywords: ["合同", "协议", "条款", "甲方"] },
    { name: "产品说明", keywords: ["产品", "功能", "使用", "操作"] },
    { name: "新闻资讯", keywords: ["新闻", "报道", "发布", "消息"] },
    { name: "个人文档", keywords: ["个人", "简历", "经历", "教育"] },
  ];

  private categories: SemanticCategory[] = [];
  private categoryVectors: number[][] = [];
  private kmeans: KMeans | null = null;

  async initialize(): Promise<void> {
    // 初始化类别向量
  }

  cluster(block: SemanticBlock): ClusterResult {
    // 计算到各类别中心的距离
    // 返回最近类别
  }

  clusterBatch(blocks: SemanticBlock[]): ClusterResult[] {
    // 批量聚类
  }
}
```

---

## Task 9: 实现语义查询

**Files:**
- Create: `entry/src/main/ets/semantic/SemanticQuery.ets`

### 9.1 语义搜索

```typescript
// SemanticQuery.ets
export interface SearchResult {
  queryText: string;
  semanticBlocks: SemanticBlockResult[];
  files: FileResult[];
}

export class SemanticQuery {
  private dbManager: DatabaseManager;
  private semanticRep: SemanticRepresentation;
  private semanticSimilarity: SemanticSimilarity;

  async search(queryText: string, topK: number = 10, topM: number = 5): Promise<SearchResult> {
    // 1. 将查询转化为语义块
    const queryBlock = await this.queryToSemanticBlock(queryText);

    // 2. 加载语义块缓存
    await this.loadSemanticBlocksCache();

    // 3. 相似度搜索
    const blockResults = this.semanticSimilarity.search(queryBlock, topK);

    // 4. 计算文件相似度
    const fileResults = this.calculateFileSimilarity(blockResults, topM);

    return {
      queryText,
      semanticBlocks: blockResults,
      files: fileResults
    };
  }

  private async queryToSemanticBlock(text: string): Promise<SemanticBlock> {
    // 将查询文本转化为语义块（含向量）
  }
}
```

---

## Task 10: 完善语义表征模块

**Files:**
- Modify: `entry/src/main/ets/semantic/SemanticRepresentation.ets`

### 10.1 完整语义表征流程

```typescript
// SemanticRepresentation.ets
export class SemanticRepresentation {
  private jiebaService: JiebaService;
  private embeddingService: EmbeddingService;

  async represent(block: DataBlock, dbManager?: DatabaseManager, fileId?: number): Promise<SemanticBlock> {
    // 1. 提取文本内容
    const textContent = await this.extractText(block);

    // 2. 生成文本描述
    const textDescription = this.generateDescription(textContent);

    // 3. 提取关键词（jieba）
    const keywords = this.jiebaService.extractTags(textDescription, 10);

    // 4. 生成语义向量
    const semanticVector = await this.embeddingService.encode(textDescription);

    // 5. 创建语义块
    return new SemanticBlock(
      block.blockId,
      textDescription,
      keywords,
      semanticVector,
      block.modality,
      block.metadata
    );
  }

  async representBatch(blocks: DataBlock[]): Promise<SemanticBlock[]> {
    // 批量处理（性能优化）
  }
}
```

---

## Task 11: 完善数据库模块

**Files:**
- Modify: `entry/src/main/ets/database/DatabaseManager.ets`

### 11.1 添加缺失表

```typescript
// 新增表
- semantic_categories: 语义类别表
- classification_results: 分类结果表
- user_queries: 用户查询表
```

### 11.2 完善字段

```typescript
// semantic_blocks表添加字段
- bm25_text: string  // 用于BM25计算的文本
- metadata: string   // JSON格式，存储类别相似度
```

---

## Task 12: 重构文件分析服务

**Files:**
- Modify: `entry/src/main/ets/services/FileAnalysisService.ets`

### 12.1 完整分析流程

```typescript
// FileAnalysisService.ets
export class FileAnalysisService {
  // 1. 扫描目录
  async scanDirectory(path: string): Promise<ScanResult> { /*...*/ }

  // 2. 解析文件
  async parseFile(fileId: number): Promise<DataBlock[]> { /*...*/ }

  // 3. 语义表征
  async semanticRepresent(fileId: number): Promise<SemanticBlock[]> { /*...*/ }

  // 4. 分类
  async classify(fileId: number): Promise<ClassificationResult[]> { /*...*/ }

  // 5. 完整分析（串联以上步骤）
  async analyzeFile(fileId: number): Promise<boolean> { /*...*/ }

  // 6. 语义搜索
  async searchFiles(query: string, topK: number): Promise<FileRecord[]> { /*...*/ }
}
```

---

## 文件变更汇总

| 文件 | 变更类型 | 主要变更 |
|------|---------|---------|
| JiebaService.ets | 新建 | 中文分词服务 |
| BM25.ets | 新建 | BM25算法实现 |
| VectorSimilarity.ets | 新建 | 向量相似度计算 |
| KeywordSimilarity.ets | 新建 | 关键词相似度计算 |
| TimeSimilarity.ets | 新建 | 时间相似度计算 |
| LocationSimilarity.ets | 新建 | 地点相似度计算 |
| SemanticSimilarity.ets | 新建 | 相似度融合计算 |
| KMeans.ets | 新建 | KMeans聚类算法 |
| SemanticClustering.ets | 新建 | 语义聚类服务 |
| SemanticQuery.ets | 新建 | 语义查询服务 |
| SemanticRepresentation.ets | 修改 | 完善语义表征流程 |
| LocalClassificationService.ets | 重构 | 使用相似度融合分类 |
| DatabaseManager.ets | 修改 | 添加缺失表和字段 |
| FileAnalysisService.ets | 重构 | 完整分析流程 |

---

## Embedding方案决定

**选择:** 使用 `@hms.data.retrieval` API
- 华为原生向量检索服务
- 自动生成embedding向量
- 支持相似度搜索
- 无需额外模型文件

---

## 验证测试

1. **单元测试**: 每个模块独立测试
2. **集成测试**: 端到端流程测试
3. **性能测试**: 大文件处理性能
4. **真机测试**: 在HarmonyOS手机上验证

---

## 注意事项

1. **embedding向量**: 需要确定使用MindSpore Lite还是@hms.data.retrieval
2. **中文分词**: jieba词典需要打包到应用中
3. **内存管理**: 向量数据可能占用较多内存
4. **性能优化**: 批量处理优于逐个处理