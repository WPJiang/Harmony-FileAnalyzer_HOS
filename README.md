# File Analyzer HarmonyOS (FileAnalyzer_HOS)

HarmonyOS NEXT 版本的文件分析应用，支持多种文件格式的解析、语义表征和语义聚类。

## 项目简介

本项目是 [File Analyzer](./file_analyzer_base/README.md) 的 HarmonyOS NEXT 移植版本，实现以下核心功能：

- **多格式文件解析**：支持 PDF、Word(docx)、PPT(pptx)、图片(jpg/png/gif/heic/livp)、音频(wav) 等格式
- **语义表征**：文本描述生成、关键词提取、语义向量编码
- **语义相似度计算**：融合向量相似度、BM25 分数和关键词相似度
- **语义聚类**：基于预定义类别进行文件自动分类
- **本地 OCR**：基于 HiAI 文字识别服务
- **图片描述**：支持本地 MindSpore Lite 和云端 LLM 两种模式

## 环境要求

- DevEco Studio 5.0+
- HarmonyOS NEXT SDK (API 12+)
- 测试设备：HarmonyOS NEXT 手机

## 快速开始

### 编译

```bash
export DEVECO_SDK_HOME="/path/to/DevEco Studio/sdk"
cd FileAnalyzer_HOS
"/path/to/DevEco Studio/tools/hvigor/bin/hvigorw.bat" assembleHap --no-daemon
```

### 安装到设备

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

### 启动应用

```bash
hdc shell "aa start -a EntryAbility -b com.example.fileanalyzer_hos"
```

## 项目结构

```
entry/src/main/ets/
├── entryability/      # 应用入口
├── pages/             # 页面
│   ├── Index.ets      # 主页面
│   ├── Settings.ets   # 设置页面
│   └── TestPage.ets   # 测试页面
├── parser/            # 文件解析器
│   ├── PDFParser.ets
│   ├── ImageParser.ets
│   ├── WordParser.ets
│   ├── PptParser.ets
│   └── AudioParser.ets
├── semantic/          # 语义处理
│   ├── SemanticRepresentation.ets  # 语义表征主流程
│   ├── EmbeddingService.ets       # 向量编码服务
│   ├── MindSporeEmbeddingService.ets  # MindSpore Lite 模型推理
│   ├── KeywordExtractor.ets       # 关键词提取
│   └── FilenameSemanticAnalyzer.ets   # 文件名语义分析
├── services/          # 业务服务
│   ├── LocalOCRService.ets       # 本地 OCR
│   ├── LocalImageAnalysisService.ets  # 图片分析
│   ├── ApiService.ets            # 后端 API
│   └── FileAnalysisService.ets   # 文件分析服务
├── models/            # 数据模型
├── database/          # 数据库管理
├── tokenizers/        # 分词器 (BPE Tokenizer)
├── utils/             # 工具类
│   ├── ModelLoaderUtils.ets      # MindSpore 模型加载
│   ├── ChineseTokenizer.ets      # 中文分词
│   └── CacheUtils.ets            # 缓存管理
└── testing/           # 集成测试
```

## 向量编码优先级

1. **MindSpore Lite 端侧推理**：MiniLM-L6-v2 模型 + BPE 分词器（离线、最快）
2. **后端 API**：云端向量编码服务
3. **本地 N-gram 哈希向量**：无需模型的备选方案

**说明**：HMS Retrieval Kit (`@hms.data.retrieval`) 不提供独立的 embedding 向量生成接口，仅用于向量检索/语义搜索场景，因此不在编码服务中使用。华为开发者文档中的 `aip-data-intelligence-embedding` 服务为新增的向量化API，待后续验证集成。

## Office 文件解析方案

### 概述

Office 文件（PPTX、DOCX、XLSX）采用 ZIP 容器格式，内部包含 XML 文件描述内容和元数据。HarmonyOS 版本使用系统内置的 `@ohos.zlib` 模块进行 ZIP 解压缩，避免了自定义 DEFLATE 实现的复杂性。

### 文件结构

| 文件类型 | ZIP 结构 |
|---------|---------|
| **PPTX** | `ppt/slides/slide*.xml` - 幻灯片内容；`ppt/presentation.xml` - 演示文稿元数据 |
| **DOCX** | `word/document.xml` - 文档内容；`word/styles.xml` - 样式定义 |
| **XLSX** | `xl/worksheets/sheet*.xml` - 工作表内容；`xl/sharedStrings.xml` - 共享字符串 |

### 解析流程

```mermaid
flowchart LR
    A[Office文件] --> B[ZipReader]
    B --> C[ZIP Central Directory解析]
    C --> D[定位文件条目]
    D --> E[zlib.inflate解压]
    E --> F[XML解析]
    F --> G[文本提取]
    G --> H[DataBlock输出]
```

### ZIP 解压缩实现

使用 HarmonyOS 内置的 `@ohos.zlib` 模块处理 DEFLATE 压缩数据：

```typescript
import zlib from '@ohos.zlib';

async function inflate(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array | null> {
  // 创建 Zip 对象
  const zip = zlib.createZipSync();

  // 创建输出缓冲区
  const outputBuffer = new ArrayBuffer(expectedSize);

  // 创建 ZStream
  const strm: zlib.ZStream = {
    nextIn: compressed.buffer.slice(compressed.byteOffset, compressed.byteOffset + compressed.length),
    availableIn: compressed.length,
    nextOut: outputBuffer,
    availableOut: expectedSize
  };

  // 初始化 inflate (windowBits=-15 用于 raw deflate，ZIP 文件使用此格式)
  await zip.inflateInit2(strm, -15);

  // 执行解压缩
  await zip.inflate(strm, zlib.CompressFlushMode.FINISH);

  // 清理
  await zip.inflateEnd(strm);

  return new Uint8Array(outputBuffer, 0, strm.totalOut || expectedSize);
}
```

### 关键技术点

1. **Raw Deflate 格式**：ZIP 文件中的 DEFLATE 数据是 raw deflate（无 zlib/gzip 头），需要设置 `windowBits = -15`

2. **Central Directory 解析**：通过解析 ZIP 的 Central Directory 获取准确的条目偏移和大小，解决 Data Descriptor 模式下 Local File Header 尺寸为 0 的问题

3. **XML 文本提取**：
   - PPTX：提取 `<a:t>` 标签中的文本内容
   - DOCX：提取 `<w:t>` 标签中的文本内容
   - XLSX：提取 `<v>` 标签中的单元格值

4. **嵌入图片提取**：
   - PPTX：提取 `ppt/media/image*.png/jpg` 等图片文件
   - DOCX：提取 `word/media/image*.png/jpg` 等图片文件
   - XLSX：提取 `xl/media/image*.png/jpg` 等图片文件
   - 图片保存到文件对应的缓存目录，生成 IMAGE 类型 DataBlock

### 解析器文件

| 解析器 | 文件路径 | 说明 |
|-------|---------|------|
| ZipReader | `parser/ZipReader.ets` | ZIP 文件读取和 DEFLATE 解压缩 |
| PptParser | `parser/PptParser.ets` | PPTX 幻灯片文本提取 + 嵌入图片提取 |
| WordParser | `parser/WordParser.ets` | DOCX 文档文本提取 + 嵌入图片提取 |
| ExcelParser | `parser/ExcelParser.ets` | XLSX 工作表数据提取 + 嵌入图片提取 |

### 测试验证

经过测试验证，以下 Office 文件解析正常：

| 文件名 | 类型 | 压缩方式 | 解析结果 |
|--------|------|---------|---------|
| 简易电商系统.pptx | PPTX | DEFLATE | ✓ 8 slides |
| 高等数学课程介绍.pptx | PPTX | STORED | ✓ 5 slides |
| 矩阵求导.docx | DOCX | DEFLATE | ✓ 1 block |
| 企业贷模型版产品字典.xlsx | XLSX | DEFLATE | ✓ 1 block |
| BTP班车表.xlsx | XLSX | DEFLATE | ✓ 1 block |

### 历史问题修复

**问题**：自定义 DEFLATE inflate 实现的 Dynamic Huffman 解码产生乱码输出，导致 Office 文件无法正确解析。

**原因分析**：
- Dynamic Huffman (blockType=2) 的 Huffman 表构建和解码逻辑存在错误
- Fixed Huffman (blockType=1) 对 PNG 文件正常，但对 XML 文件解码失败
- RFC 1951 规定的 MSB first 位读取顺序实现不正确

**解决方案**：放弃自定义 DEFLATE 实现，改用 HarmonyOS 系统内置的 `@ohos.zlib` 模块，该模块提供了完整的 zlib API 支持。

### 嵌入图片提取

Office 文件中的嵌入图片存储在 ZIP 容器的 media 目录下：

```
PPTX: ppt/media/image1.png, image2.jpg, ...
DOCX: word/media/image1.png, image2.jpg, ...
XLSX: xl/media/image1.png, image2.jpg, ...
```

**提取流程**：

1. 使用正则表达式匹配 media 目录下的图片文件：
   ```typescript
   private static readonly MEDIA_PATTERN = /^ppt\/media\/(image\d+\.(png|jpg|jpeg|gif|svg|bmp|webp|emf|wmf))$/i;
   ```

2. 从 ZIP entries 中筛选匹配的图片条目

3. 将图片二进制数据保存到缓存目录：
   ```typescript
   const imageCachePath = await cacheUtils.saveBinaryToCache(
     entry.data.buffer,
     cachePath,
     imageFileName
   );
   ```

4. 创建 IMAGE 类型 DataBlock，设置：
   - `modality`: `ModalityType.IMAGE`
   - `addr`: 缓存图片路径
   - `metadata`: 包含 mediaName, mediaFileName, mediaIndex 等信息

**支持的图片格式**：png, jpg, jpeg, gif, svg, bmp, webp, emf, wmf

## 已知问题与修复记录

### MindSpore Lite loadModelFromBuffer 返回 null

**现象**：`mindSporeLite.loadModelFromBuffer()` 读取 rawfile 缓冲区成功（90MB），但返回 null，导致设置页面显示"不可用"。

**根因**：`resourceManager.getRawFileContent()` 返回 `Uint8Array`，而 `mindSporeLite.loadModelFromBuffer()` 需要原生 `ArrayBuffer`。直接传入 `Uint8Array` 时 API 不报错但返回 null。

**修复方案**（两步保护）：

1. **类型转换**：在 `ModelLoaderUtils.loadMsModel()` 中将 `Uint8Array` 转换为 `ArrayBuffer`：
   ```typescript
   const uint8Buffer = await resourceMgr.getRawFileContent(modelPath);
   const modelBuffer = uint8Buffer.buffer.slice(
     uint8Buffer.byteOffset,
     uint8Buffer.byteOffset + uint8Buffer.byteLength
   );
   const model = await mindSporeLite.loadModelFromBuffer(modelBuffer, config);
   ```

2. **filesDir 降级加载**：如果 rawfile 加载仍返回 null，将模型从 rawfile 复制到 `context.filesDir`，再以 `ArrayBuffer` 方式读取并加载：
   ```typescript
   // 复制到 filesDir
   const destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
   fileIo.writeSync(destFile.fd, uint8Buffer);
   fileIo.closeSync(destFile);

   // 以 ArrayBuffer 读取
   const arrayBuffer = new ArrayBuffer(stat.size);
   fileIo.readSync(file.fd, arrayBuffer);

   // 加载模型
   this.model = await mindSporeLite.loadModelFromBuffer(arrayBuffer, msContext);
   ```

**涉及文件**：
- `entry/src/main/ets/utils/ModelLoaderUtils.ets` - rawfile 读取时 Uint8Array -> ArrayBuffer 转换
- `entry/src/main/ets/semantic/MindSporeEmbeddingService.ets` - filesDir 降级加载逻辑

**参考**：AItest 项目通过 `fileIo.readSync` 将模型读入 `new ArrayBuffer()` 后调用 `loadModelFromBuffer`，始终使用原生 `ArrayBuffer`，避免了此问题。

## 配置说明

### 图片文本提取方式

- **OCR**（默认）：对图片中文字进行识别
- **Caption**：使用 LLM 生成图片描述

注：PDF/PPT/Word 中嵌入的图片始终使用 OCR。

### Caption 模式

- **LOCAL**：端侧 MindSpore Lite 推理
- **CLOUD**：云端 LLM API（需配置 API Key）

## 模型文件

模型文件位于 `entry/src/main/resources/rawfile/embedding/`：

| 文件 | 说明 | 大小 |
|------|------|------|
| `minilm_l6_v2_int32.ms` | MiniLM-L6-v2 MindSpore Lite 模型 (INT32) | ~90MB |
| `vocab_full.json` | BPE 分词器词汇表 (BERT格式, 30522 tokens) | ~230KB |
