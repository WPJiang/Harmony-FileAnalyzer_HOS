# HarmonyOS文件分析器实现总结

> 本文档记录了HarmonyOS文件分析器从Python桌面应用迁移到手机端的完整实现过程

## 概述

**目标:** 将Windows Python桌面应用完整迁移为HarmonyOS手机应用，实现除LLM云服务外的所有功能本地运行。

**技术栈:** HarmonyOS ArkTS/ETS + MindSpore Lite Kit + HMS OCR + HMS Retrieval + RdbStore

---

## 已完成任务

### Task #29: 实现本地中文分词器 ✅

**文件:**
- `entry/src/main/ets/utils/ChineseTokenizer.ets`
- `entry/src/main/resources/rawfile/dict_small.txt`

**功能:**
- 正向最大匹配算法
- 支持自定义词典加载
- TF-IDF关键词提取
- 文本相似度计算

**API:**
```typescript
const tokenizer = new ChineseTokenizer();
await tokenizer.loadDictionary(context);
const tokens = tokenizer.tokenize('这是一个测试句子');
const keywords = tokenizer.extractKeywords('文本内容', 10);
```

---

### Task #32: 实现Office文件解析器 ✅

**文件:**
- `entry/src/main/ets/parser/ZipReader.ets`
- `entry/src/main/ets/parser/WordParser.ets`
- `entry/src/main/ets/parser/ExcelParser.ets`
- `entry/src/main/ets/parser/PptParser.ets`
- `entry/src/main/ets/parser/DataParser.ets` (修改)

**实现原理:**
Office文件本质是ZIP压缩包，通过解压读取XML内容：

| 文件类型 | XML路径 | 提取标签 |
|---------|---------|---------|
| .docx | word/document.xml | `<w:t>` |
| .xlsx | xl/sharedStrings.xml + xl/worksheets/*.xml | `<t>` |
| .pptx | ppt/slides/slide*.xml | `<a:t>` |

**支持的扩展名:**
- Word: `.docx`
- Excel: `.xlsx`, `.xls`
- PowerPoint: `.pptx`

---

### Task #33: 完善本地向量编码器 ✅

**文件:**
- `entry/src/main/ets/semantic/EmbeddingService.ets`

**LocalEmbeddingService类:**
- N-gram特征提取 (2-gram到4-gram)
- TF-IDF向量编码
- FNV-1a哈希向量编码
- 向量归一化 (L2范数)

**API:**
```typescript
const encoder = new LocalEmbeddingService();
await encoder.fit(documents); // 可选：训练词表
const vector = encoder.encode('文本内容'); // 返回384维向量
const similarity = LocalEmbeddingService.cosineSimilarity(vec1, vec2);
```

---

### Task #35: 集成MindSpore Lite端侧向量编码 ✅

**文件:**
- `entry/src/main/ets/semantic/EmbeddingService.ets` (新增MindSporeEmbeddingService类)
- `entry/src/main/resources/rawfile/vocab.txt`

**编码优先级:**
```
1. MindSpore Lite端侧推理（离线、最快）
   ↓ (模型不可用时)
2. 后端API（云端embedding）
   ↓ (网络不可用时)
3. HMS Retrieval API
   ↓ (API不可用时)
4. 本地N-gram哈希向量（备选）
```

**MindSporeEmbeddingService API:**
```typescript
const msEncoder = new MindSporeEmbeddingService();
const success = await msEncoder.initialize(context, 'text_embedding.ms');
if (success) {
  const vector = await msEncoder.encode('文本内容');
}
```

**使用MindSpore Lite:**
1. 将`.ms`格式的文本嵌入模型放入 `rawfile/text_embedding.ms`
2. 系统自动检测并使用MindSpore Lite
3. 模型推荐：
   - `paraphrase-multilingual-MiniLM-L12-v2` - 多语言句向量
   - `text2vec-chinese` - 中文句向量
   - `bge-small-zh` - 中文嵌入模型

**参考文档:**
- [MindSpore Lite Kit介绍](https://gitee.com/openharmony/docs/raw/master/en/application-dev/ai/mindspore/MindSpore-Lite-Kit-Introduction.md)
- [ArkTS API使用指南](https://gitee.com/openharmony/docs/raw/master/en/application-dev/ai/mindspore/mindspore-guidelines-based-js.md)

---

### Task #31: 完善语义表征服务 ✅

**文件:**
- `entry/src/main/ets/semantic/KeywordExtractor.ets`
- `entry/src/main/ets/semantic/SemanticRepresentation.ets`

**完整语义表征流程:**
```
输入文本
    ↓
1. 文本提取（本地OCR/解析器）
    ↓
2. 文本描述生成（本地摘要/云端LLM）
    ↓
3. 关键词提取（ChineseTokenizer分词）
    ↓
4. 向量编码（MindSpore Lite/云端API/本地哈希）
    ↓
5. 时间/地点信息提取
    ↓
SemanticBlock输出
```

**新增API:**
```typescript
// KeywordExtractor
extractWithTFIDF(text: string, idf: Map<string, number>): string[]

// TextDescriptionGenerator
generateStructured(text: string, metadata?: Record<string, Object>): string

// SemanticRepresentation
extractTimeInfo(text: string): string[]
extractLocationInfo(text: string): string[]
representBatch(blocks: DataBlock[]): Promise<SemanticBlock[]>
getEncoderInfo(): string
isMindSporeAvailable(): boolean
```

---

### Task #34: 完善UI界面 ✅

**文件:**
- `entry/src/main/ets/pages/Index.ets`

**新增功能:**
- 标题栏显示编码器状态（MindSpore Lite/本地模式）
- 工作流按钮支持离线处理（不再强制依赖API连接）
- 离线模式指示器
- 设置页面显示编码器详细状态

**UI状态变量:**
```typescript
@State encoderStatus: string = '初始化中...';
@State isOfflineMode: boolean = false;
```

---

## 模块完成状态

| 模块 | 状态 | 说明 |
|-----|------|------|
| 中文分词 | ✅ | ChineseTokenizer.ets（正向最大匹配） |
| 向量编码 | ✅ | MindSpore Lite / HMS Retrieval / 本地哈希 |
| 语义表征 | ✅ | 完整流程：OCR→描述→关键词→向量 |
| 相似度计算 | ✅ | BM25 + 向量余弦 + Jaccard + 时间 + 地点 |
| 分类服务 | ✅ | 相似度融合分类 |
| Office解析 | ✅ | Word/Excel/PPT（ZIP+XML） |
| PDF解析 | ✅ | HMS PDF服务 + OCR |
| 图片OCR | ✅ | HMS OCR API |
| 数据库 | ✅ | RdbStore |
| UI界面 | ✅ | 完整工作流 + 离线支持 |

---

## 文件结构

```
entry/src/main/ets/
├── database/
│   ├── DatabaseManager.ets
│   └── Index.ets
├── models/
│   ├── DataBlock.ets
│   ├── SemanticBlock.ets
│   ├── SemanticModels.ets
│   └── Index.ets
├── parser/
│   ├── BaseParser.ets
│   ├── DataParser.ets
│   ├── PDFParser.ets
│   ├── ImageParser.ets
│   ├── TextParser.ets
│   ├── ZipReader.ets      # 新增
│   ├── WordParser.ets     # 新增
│   ├── ExcelParser.ets    # 新增
│   ├── PptParser.ets      # 新增
│   └── Index.ets
├── semantic/
│   ├── EmbeddingService.ets   # 修改：新增MindSporeEmbeddingService
│   ├── KeywordExtractor.ets   # 修改：集成ChineseTokenizer
│   ├── SemanticRepresentation.ets  # 修改：完整流程
│   ├── SemanticSimilarity.ets
│   ├── SemanticQuery.ets
│   └── Index.ets
├── services/
│   ├── ApiService.ets
│   ├── FileAnalysisService.ets
│   ├── LocalOCRService.ets
│   ├── LocalClassificationService.ets
│   └── Index.ets
├── utils/
│   ├── ChineseTokenizer.ets   # 新增
│   └── Index.ets
├── pages/
│   ├── Index.ets              # 修改：UI完善
│   └── Settings.ets
└── viewmodel/
    ├── FileViewModel.ets
    └── Index.ets

entry/src/main/resources/rawfile/
├── dict_small.txt    # 中文词典（2419词）
└── vocab.txt         # 词表文件（用于tokenization）
```

---

## API依赖

| Kit/API | 用途 | 导入方式 |
|---------|------|---------|
| MindSpore Lite Kit | 端侧模型推理 | `import { mindSporeLite } from '@kit.MindSporeLiteKit'` |
| Core File Kit | 文件操作 | `import { fileIo } from '@kit.CoreFileKit'` |
| Image Kit | 图像解码 | `import { image } from '@kit.ImageKit'` |
| HMS OCR | 文字识别 | `import { textRecognition } from '@hms.ai.ocr.textRecognition'` |
| HMS Retrieval | 向量检索 | `import retrieval from '@hms.data.retrieval'` |
| HMS PDF | PDF解析 | `import { pdfService } from '@hms.officeservice.pdfservice'` |
| RdbStore | 本地数据库 | `import relationalStore from '@ohos.data.relationalStore'` |

---

## 性能考虑

1. **内存管理**
   - 向量数据使用Float32Array
   - 大文件分块处理
   - 及时释放MindSpore模型资源

2. **批量处理优化**
   - `representBatch()` 批量语义表征
   - `encodeBatch()` 批量向量编码

3. **离线优先**
   - 优先使用MindSpore Lite端侧推理
   - 网络不可用时自动降级到本地处理

---

## 测试建议

1. **单元测试**
   - 测试中文分词准确性
   - 测试向量编码维度和归一化
   - 测试Office文件解析

2. **集成测试**
   - 端到端文件分析流程
   - 离线模式完整测试
   - MindSpore模型加载测试

3. **真机测试**
   - 需要在HarmonyOS手机上验证
   - HMS服务需要真机环境

---

## 已知限制

1. **Office格式**
   - 仅支持较新的格式（.docx, .xlsx, .pptx）
   - 复杂格式可能解析不完整

2. **MindSpore Lite**
   - 需要自行准备`.ms`格式模型文件
   - 模型文件会增加应用体积

3. **中文分词**
   - 基于词典的正向最大匹配，精度有限
   - 未登录词处理简单

---

## 更新日志

- **2026-04-07**: 完成所有任务，实现完整迁移