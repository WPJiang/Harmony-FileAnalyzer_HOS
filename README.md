# File Analyzer HarmonyOS NEXT

HarmonyOS NEXT 文件分析应用，支持多格式文件解析、语义表征和智能分类。

> 本项目是 [File Analyzer (Python版)](./file_analyzer_base/README.md) 的 HarmonyOS NEXT 移植版本。

---

## 功能特性

| 功能 | 说明 |
|------|------|
| 多格式解析 | PDF、Word、PPT、Excel、图片、音频 |
| 语义表征 | 文本描述生成、关键词提取、向量编码 |
| 相似度计算 | 向量相似度 + BM25 + 关键词融合 |
| 智能分类 | 基于预定义类别的文件自动归类 |
| 本地 OCR | HiAI 文字识别服务 |
| 图片描述 | MindSpore Lite 端侧推理 / 云端 LLM |

---

## 环境要求

| 项目 | 版本 |
|------|------|
| DevEco Studio | 5.0+ |
| HarmonyOS SDK | API 12+ |
| 测试设备 | HarmonyOS NEXT 手机 |

---

## 快速开始

### 编译

```bash
export DEVECO_SDK_HOME="/path/to/DevEco Studio/sdk"
cd FileAnalyzer_HOS
hvigorw assembleHap --no-daemon
```

### 安装

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

### 启动

```bash
hdc shell "aa start -a EntryAbility -b com.example.fileanalyzer_hos"
```

---

## 项目结构

```
entry/src/main/ets/
├── entryability/          # 应用入口
├── pages/                 # 页面
│   ├── Index.ets          # 主页面
│   └── TestPage.ets       # 测试页面
├── parser/                # 文件解析器
│   ├── ZipReader.ets      # ZIP 解压缩
│   ├── PDFParser.ets      # PDF 解析
│   ├── ImageParser.ets    # 图片解析
│   ├── WordParser.ets     # Word 解析
│   ├── PptParser.ets      # PPT 解析
│   └── ExcelParser.ets    # Excel 解析
├── semantic/              # 语义处理
│   ├── EmbeddingService.ets          # 向量编码服务
│   ├── MindSporeEmbeddingService.ets # MindSpore 推理
│   ├── SemanticRepresentation.ets   # 语义表征
│   └── KeywordExtractor.ets         # 关键词提取
├── services/              # 业务服务
│   ├── LocalOCRService.ets           # 本地 OCR
│   ├── LocalImageAnalysisService.ets # 图片分析
│   ├── ApiService.ets                # 后端 API
│   └── FileAnalysisService.ets       # 文件分析
├── tokenizers/            # 分词器
│   └── BPETokenizer.ets   # BPE 分词器
├── utils/                 # 工具类
│   ├── CacheUtils.ets     # 缓存管理
│   └── ModelLoaderUtils.ets # 模型加载
├── models/                # 数据模型
└── database/              # 数据库管理
```

---

## 核心技术

### 向量编码

| 优先级 | 编码方式 | 特点 |
|--------|----------|------|
| 1 | MindSpore Lite | MiniLM-L6-v2 模型，端侧离线推理，最快 |
| 2 | Backend API | 云端向量编码服务，需网络 |
| 3 | Local N-gram | FNV-1a 哈希向量，无需模型，备选方案 |

> **说明**：HMS Retrieval Kit 不提供独立 embedding 生成接口，仅用于向量检索场景。

### Office 文件解析

Office 文件（PPTX/DOCX/XLSX）采用 ZIP 容器格式，使用系统内置 `@ohos.zlib` 解压缩：

| 文件类型 | 内容路径 | 嵌入图片路径 |
|----------|----------|--------------|
| PPTX | `ppt/slides/slide*.xml` | `ppt/media/` |
| DOCX | `word/document.xml` | `word/media/` |
| XLSX | `xl/worksheets/sheet*.xml` | `xl/media/` |

**解析流程**：

```
Office文件 → ZipReader → Central Directory → zlib.inflate → XML解析 → DataBlock
```

**关键技术点**：

| 技术点 | 说明 |
|--------|------|
| Raw Deflate | `windowBits = -15`，ZIP 使用无 zlib 头的 deflate |
| Central Directory | 获取准确偏移和大小，解决 Data Descriptor 模式问题 |
| XML 提取 | `<a:t>` (PPT)、`<w:t>` (Word)、`<v>` (Excel) |
| 图片提取 | 支持 png/jpg/gif/svg/bmp/webp/emf/wmf |

**测试验证**：

| 文件 | 类型 | 压缩 | 结果 |
|------|------|------|------|
| 简易电商系统.pptx | PPTX | DEFLATE | ✓ 8 slides + 嵌入图片 |
| 高等数学课程介绍.pptx | PPTX | STORED | ✓ 5 slides |
| 矩阵求导.docx | DOCX | DEFLATE | ✓ 1 block |
| 企业贷模型版产品字典.xlsx | XLSX | DEFLATE | ✓ 1 block + 嵌入图片 |

---

## 配置说明

### 图片文本提取

| 方式 | 适用场景 |
|------|----------|
| OCR | 识别图片中的文字（默认） |
| Caption | LLM 生成图片描述 |

> PDF/PPT/Word 嵌入图片始终使用 OCR。

### Caption 模式

| 模式 | 说明 |
|------|------|
| LOCAL | MindSpore Lite 端侧推理 |
| CLOUD | 云端 LLM API（需配置 API Key） |

### 编码器选择

设置页面可选择编码方式：

| 选项 | 说明 |
|------|------|
| MindSpore | 端侧 MiniLM-L6-v2 模型 |
| 后端 API | 云端向量编码服务 |
| 本地 | N-gram 哈希向量 |

---

## 已知问题与修复

### MindSpore Lite loadModelFromBuffer 返回 null

| 项目 | 内容 |
|------|------|
| **现象** | 读取 rawfile 成功但返回 null |
| **根因** | `Uint8Array` 与 `ArrayBuffer` 类型不匹配 |
| **修复** | 转换为原生 ArrayBuffer，或复制到 filesDir 后加载 |

```typescript
// Uint8Array → ArrayBuffer 转换
const modelBuffer = uint8Buffer.buffer.slice(
  uint8Buffer.byteOffset,
  uint8Buffer.byteOffset + uint8Buffer.byteLength
);
```

---

## 模型文件

| 文件 | 路径 | 大小 |
|------|------|------|
| MiniLM-L6-v2 模型 | `rawfile/embedding/minilm_l6_v2_int32.ms` | ~90MB |
| BPE 分词器词汇表 | `rawfile/embedding/vocab_full.json` | ~230KB |
| Qwen 0.8B 模型 | `rawfile/caption/qwen_0.8b_q4.gguf` | ~500MB |

---

## License

MIT