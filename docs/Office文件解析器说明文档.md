# Office文件解析器说明文档

本文档详细说明了HarmonyOS平台上PPTX、DOCX、XLSX文件的解析实现。

## 目录

1. [概述](#概述)
2. [代码量统计](#代码量统计)
3. [架构设计](#架构设计)
4. [ZIP文件读取 (ZipReader)](#zip文件读取)
5. [PPTX解析 (PptParser)](#pptx解析)
6. [DOCX解析 (WordParser)](#docx解析)
7. [XLSX解析 (ExcelParser)](#xlsx解析)
8. [数据块结构](#数据块结构)
9. [缓存机制](#缓存机制)

---

## 概述

Office 2007及以后版本（PPTX、DOCX、XLSX）采用Open Packaging Convention (OPC)格式，本质上是一个ZIP压缩包，内部包含多个XML文件和媒体资源。

### 文件结构对比

| 文件类型 | 主要XML文件 | 媒体目录 |
|---------|------------|---------|
| PPTX | `ppt/slides/slide*.xml` | `ppt/media/` |
| DOCX | `word/document.xml` | `word/media/` |
| XLSX | `xl/worksheets/sheet*.xml` | `xl/media/` |

---

## 代码量统计

### 各模块代码行数

| 文件 | 位置 | 代码行数 | 主要功能 |
|------|------|----------|---------|
| ZipReader.ets | `entry/src/main/ets/parser/` | 420 | ZIP文件读取、DEFLATE解压 |
| PptParser.ets | `entry/src/main/ets/parser/` | 580 | PPTX幻灯片解析、表格Markdown转换、媒体提取 |
| WordParser.ets | `entry/src/main/ets/parser/` | 500 | DOCX段落解析、表格Markdown转换、媒体提取 |
| ExcelParser.ets | `entry/src/main/ets/parser/` | 678 | XLSX工作表解析、共享字符串、Markdown表格 |
| DataParser.ets | `entry/src/main/ets/parser/` | 426 | 解析器调度、格式识别 |
| BaseParser.ets | `entry/src/main/ets/parser/` | 82 | 解析器基类、DataBlock定义 |
| CacheUtils.ets | `entry/src/main/ets/utils/` | 419 | 缓存目录管理、文件保存 |
| **总计** | - | **3105** | - |

### 模块占比

```
┌──────────────────────────────────────────────────────────────┐
│                    代码量占比分布                              │
├──────────────────────────────────────────────────────────────┤
│  ExcelParser ████████████████████████░░░░░░░░░░░░  23.6%     │
│  PptParser   ████████████████████░░░░░░░░░░░░░░░░░  15.4%     │
│  DataParser  ███████████████████░░░░░░░░░░░░░░░░░░  14.8%     │
│  ZipReader   ███████████████████░░░░░░░░░░░░░░░░░░  14.6%     │
│  CacheUtils  ██████████████████░░░░░░░░░░░░░░░░░░░  14.6%     │
│  WordParser  █████████████████░░░░░░░░░░░░░░░░░░░░  14.2%     │
│  BaseParser  ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   2.8%     │
└──────────────────────────────────────────────────────────────┘
```

---

## 架构设计

### 类继承关系

```
BaseParser (基类)
    ├── PptParser (PPTX解析)
    ├── WordParser (DOCX解析)
    ├── ExcelParser (XLSX解析)
    └── ...
```

### 解析流程

```
┌─────────────────────────────────────────────────────────────┐
│                     解析流程                                  │
├─────────────────────────────────────────────────────────────┤
│  1. 检查文件格式 (canParse)                                   │
│  2. 获取缓存路径 (CacheUtils.getDataBlocksCachePath)         │
│  3. 读取ZIP文件 (ZipReader.readZipFile)                      │
│  4. 提取关键XML文件                                           │
│  5. 解析XML提取文本/表格内容                                  │
│  6. 提取媒体图片                                              │
│  7. 保存到缓存文件                                            │
│  8. 创建DataBlock返回                                        │
└─────────────────────────────────────────────────────────────┘
```

---

## ZIP文件读取

### 核心类：ZipReader

位置：`entry/src/main/ets/parser/ZipReader.ets`

### ZIP文件结构

ZIP文件由三部分组成：

```
┌────────────────────────────────────────────┐
│  Local File Headers (文件数据)             │
│  - 签名: 0x04034b50                         │
│  - 文件名、压缩方法、数据                    │
├────────────────────────────────────────────┤
│  Central Directory (中央目录)              │
│  - 签名: 0x02014b50                         │
│  - 所有文件的元数据索引                      │
├────────────────────────────────────────────┤
│  End of Central Directory (EOCD)           │
│  - 签名: 0x06054b50                         │
│  - 中央目录位置、文件总数                    │
└────────────────────────────────────────────┘
```

### 关键方法

#### 1. readZipFile(filePath: string)

完整读取ZIP文件并返回所有条目。

```typescript
static async readZipFile(filePath: string): Promise<Map<string, ZipEntry>>
```

**处理步骤：**

1. 打开文件并读取全部内容到内存
2. 从文件末尾查找EOCD（End of Central Directory）
3. 解析Central Directory获取所有文件条目信息
4. 依次解析每个Local File Header
5. 对压缩数据执行DEFLATE解压
6. 返回Map<文件名, ZipEntry>

#### 2. findEndOfCentralDir(bytes: Uint8Array)

从文件末尾反向搜索EOCD签名。

```typescript
private static findEndOfCentralDir(bytes: Uint8Array): number
```

EOCD最小22字节，可能包含最多65535字节的注释，因此需要反向搜索。

#### 3. parseCentralDir(bytes: Uint8Array, eocdOffset: number)

解析Central Directory，获取每个文件的：

- 文件名
- Local Header偏移位置
- 压缩大小
- 解压大小
- 压缩方法

**重要：** Central Directory包含准确的文件大小信息，比Local File Header更可靠（尤其是Data Descriptor模式）。

#### 4. inflate(compressed: Uint8Array, expectedSize: number)

使用HarmonyOS内置zlib库解压DEFLATE数据。

```typescript
async function inflate(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array | null>
```

**关键参数：**

- `windowBits = -15`：ZIP使用raw deflate（无zlib/gzip头），需要负数windowBits

### ZipEntry接口

```typescript
export interface ZipEntry {
  name: string;              // 文件名（如 "ppt/slides/slide1.xml"）
  compressedSize: number;    // 压缩后大小
  uncompressedSize: number;  // 解压后大小
  compressionMethod: number; // 0=STORED, 8=DEFLATE
  data: Uint8Array | null;   // 解压后的数据
}
```

### 使用示例

```typescript
const entries = await ZipReader.readZipFile(filePath);

// 获取特定文件
const slideXml = entries.get('ppt/slides/slide1.xml');

// 按模式提取多个文件
const slides = await ZipReader.extractFilesByPattern(
  filePath, 
  /^ppt\/slides\/slide\d+\.xml$/
);
```

---

## PPTX解析

### 核心类：PptParser

位置：`entry/src/main/ets/parser/PptParser.ets`

### PPTX文件结构

```
pptx文件.zip
├── ppt/
│   ├── slides/
│   │   ├── slide1.xml      ← 幻灯片1内容
│   │   ├── slide2.xml      ← 幻灯片2内容
│   │   └── ...
│   ├── slideLayouts/       ← 幻灯片布局模板
│   ├── slideMasters/       ← 幻灯片母版
│   ├── media/
│   │   ├── image1.png      ← 嵌入图片
│   │   ├── image2.jpg
│   │   └── ...
│   └── presentation.xml    ← 演示文稿元数据
├── docProps/
│   └── core.xml            ← 文档属性
└── [Content_Types].xml     ← 内容类型定义
```

### 解析步骤详解

#### Step 1: 读取ZIP

```typescript
const entries = await ZipReader.readZipFile(filePath);
```

#### Step 2: 提取幻灯片

匹配模式：`/^ppt\/slides\/slide\d+\.xml$/`

```typescript
entries.forEach((entry, name) => {
  if (PptParser.SLIDE_PATTERN.test(name) && entry.data) {
    const xmlContent = this.decodeUtf8(entry.data);
    slides.set(name, xmlContent);
  }
});
```

#### Step 3: 解析幻灯片XML

PowerPoint使用DrawingML格式表示文本和表格，核心元素：

**文本结构：**

```xml
<p:sp>                    <!-- Shape (形状) -->
  <p:txBody>              <!-- Text Body (文本主体) -->
    <a:p>                  <!-- Paragraph (段落) -->
      <a:r>                <!-- Run (文本段) -->
        <a:t>文本内容</a:t> <!-- Text (文本) -->
      </a:r>
    </a:p>
  </p:txBody>
</p:sp>
```

**表格结构（<a:tbl>）：**

```xml
<p:graphicFrame>                          <!-- 图形框架（包含表格） -->
  <a:graphic>
    <a:graphicData uri="...table...">
      <a:tbl>                              <!-- Table (表格) -->
        <a:tblPr/>                         <!-- 表格属性 -->
        <a:tblGrid>                        <!-- 列定义 -->
          <a:gridCol w="5000"/>
        </a:tblGrid>
        <a:tr h="370">                     <!-- Row (行) -->
          <a:tc>                           <!-- Cell (单元格) -->
            <a:txBody>                     <!-- 单元格文本 -->
              <a:p>
                <a:r>
                  <a:t>单元格内容</a:t>
                </a:r>
              </a:p>
            </a:txBody>
          </a:tc>
        </a:tr>
      </a:tbl>
    </a:graphicData>
  </a:graphic>
</p:graphicFrame>
```

**提取逻辑：**

```typescript
private parseSlideXml(xmlContent: string): string {
  // Step 1: 提取<a:tbl>表格并转换为Markdown
  const tblPattern = /<a:tbl[^>]*>([\s\S]*?)<\/a:tbl>/g;
  // 每个表格调用 parsePptxTableToMarkdown() 转换

  // Step 2: 从XML中移除表格内容，避免单元格文本被重复提取
  const cleanXml = xmlContent.replace(/<a:tbl[^>]*>[\s\S]*?<\/a:tbl>/g, '');

  // Step 3: 从剩余内容提取<a:t>文本
  const aTPattern = /<a:t[^>]*>([^<]*)<\/a:t>/g;

  // Step 4: 合并输出（非表格文本 + Markdown表格）
  return contentParts.join('\n\n');
}
```

**表格Markdown转换：**

```typescript
private parsePptxTableToMarkdown(tableXml: string): string {
  // 1. 提取所有<a:tr>行
  // 2. 每行提取所有<a:tc>单元格
  // 3. 每个单元格从<a:txBody> → <a:p> → <a:r> → <a:t>提取文本
  // 4. 格式化为Markdown表格

  // 输出示例:
  // | 列1 | 列2 | 列3 |
  // | --- | --- | --- |
  // | 值1 | 值2 | 值3 |
}
```

#### Step 4: 提取媒体图片

匹配模式：`/^ppt\/media\/(image\d+\.(png|jpg|jpeg|gif|svg|bmp|webp|emf|wmf))$/i`

图片保存为独立的DataBlock，modality = IMAGE。

### 输出格式

每个幻灯片生成一个DataBlock：

- **内容类型**: TEXT
- **pageNumber**: 幻灯片编号 (1, 2, 3...)
- **addr**: 缓存文件路径 (`slide_1.md`, `slide_2.md`...)
- **内容**: 文本段落 + 表格以Markdown表格格式内嵌，保留行列结构

---

## DOCX解析

### 核心类：WordParser

位置：`entry/src/main/ets/parser/WordParser.ets`

### DOCX文件结构

```
docx文件.zip
├── word/
│   ├── document.xml       ← 文档主要内容
│   ├── styles.xml         ← 样式定义
│   ├── numbering.xml      ← 列表编号
│   ├── media/
│   │   ├── image1.png     ← 嵌入图片
│   │   └── ...
│   └── ...
├── docProps/
│   └── core.xml           ← 文档属性
└── [Content_Types].xml
```

### 解析步骤详解

#### Step 1: 提取document.xml

```typescript
const DOCUMENT_XML = 'word/document.xml';
const entry = entries.get(DOCUMENT_XML);
const xmlContent = this.decodeUtf8(entry.data);
```

#### Step 2: 解析文档内容（段落 + 表格）

Word文档的XML结构包含段落和表格，按出现顺序处理：

**段落结构：**

```xml
<w:p>                      <!-- Paragraph (段落) -->
  <w:r>                    <!-- Run (文本段) -->
    <w:t>文本内容</w:t>     <!-- Text (文本) -->
  </w:r>
</w:p>
```

**表格结构（<w:tbl>）：**

```xml
<w:tbl>                               <!-- Table (表格) -->
  <w:tblPr/>                          <!-- 表格属性 -->
  <w:tblGrid>                         <!-- 列定义 -->
    <w:gridCol w:w="3000"/>
  </w:tblGrid>
  <w:tr>                              <!-- Row (行) -->
    <w:trPr/>                         <!-- 行属性（可标识表头行） -->
    <w:tc>                            <!-- Cell (单元格) -->
      <w:tcPr>                        <!-- 单元格属性 -->
        <w:gridSpan w:val="2"/>       <!-- 合并列（可选） -->
      </w:tcPr>
      <w:p>                           <!-- 单元格内段落 -->
        <w:r><w:t>单元格内容</w:t></w:r>
      </w:p>
    </w:tc>
  </w:tr>
</w:tbl>
```

**文档内容提取（按顺序处理段落和表格）：**

```typescript
private parseDocumentXml(xmlContent: string): string {
  // 提取<w:body>内容
  const bodyMatch = xmlContent.match(/<w:body[^>]*>([\s\S]*)<\/w:body>/);
  const content = bodyMatch ? bodyMatch[1] : xmlContent;

  // 使用组合正则按顺序匹配<w:tbl>和<w:p>元素
  // <w:tbl>会消费其内部的<w:p>，防止重复匹配
  const elementPattern = /<(w:tbl|w:p)\b[^>]*>[\s\S]*?<\/\1>/g;

  // 对每个匹配的元素：
  // - <w:tbl> → 调用 parseDocxTableToMarkdown() 转为Markdown表格
  // - <w:p>   → 调用 extractTextFromParagraph() 提取段落文本

  return resultParts.join('\n\n');
}
```

**表格Markdown转换：**

```typescript
private parseDocxTableToMarkdown(tableXml: string): string {
  // 1. 提取所有<w:tr>行
  // 2. 每行提取所有<w:tc>单元格
  // 3. 处理gridSpan合并单元格
  // 4. 从单元格内<w:p>段落提取文本
  // 5. 格式化为Markdown表格

  // 输出示例:
  // | 姓名 | 年龄 | 城市 |
  // | --- | --- | --- |
  // | 张三 | 25 | 北京 |
}
```

#### Step 3: 处理XML实体

```typescript
private unescapeXml(text: string): string {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}
```

### 输出格式

整个文档生成一个DataBlock：

- **内容类型**: TEXT
- **pageNumber**: 1
- **addr**: 缓存文件路径 (`text_1.md`)
- **内容**: 段落文本 + 表格以Markdown表格格式内嵌，保留行列结构，按文档顺序输出

---

## XLSX解析

### 核心类：ExcelParser

位置：`entry/src/main/ets/parser/ExcelParser.ets`

### XLSX文件结构

```
xlsx文件.zip
├── xl/
│   ├── worksheets/
│   │   ├── sheet1.xml     ← 工作表1
│   │   ├── sheet2.xml     ← 工作表2
│   │   └── ...
│   ├── sharedStrings.xml  ← 共享字符串表
│   ├── workbook.xml       ← 工作簿信息（工作表名称）
│   ├── styles.xml         ← 样式定义
│   ├── media/
│   │   ├── image1.png     ← 嵌入图片
│   │   └── ...
│   └── ...
├── docProps/
│   └── core.xml
└── [Content_Types].xml
```

### 解析步骤详解

#### Step 1: 提取共享字符串表

Excel使用共享字符串表（Shared Strings）优化存储，重复文本只存储一次。

```typescript
const SHARED_STRINGS_XML = 'xl/sharedStrings.xml';

private parseSharedStringsXml(xmlContent: string): string[] {
  // 匹配所有<si> (string item)
  const siPattern = /<si[^>]*>(.*?)<\/si>/gs;
  
  // 每个<si>可能包含:
  // - 简单文本: <t>内容</t>
  // - 富文本: <r><t>内容</t></r>...
}
```

#### Step 2: 提取工作表名称

从 `workbook.xml` 获取实际的工作表名称：

```xml
<sheet name="Sheet1" sheetId="1" r:id="rId1"/>
<sheet name="数据表" sheetId="2" r:id="rId2"/>
```

#### Step 3: 解析工作表内容

工作表结构：

```xml
<sheetData>
  <row r="1">                          <!-- 行号=1 -->
    <c r="A1" t="s">                    <!-- 单元格A1，类型=共享字符串 -->
      <v>0</v>                          <!-- 值=字符串索引0 -->
    </c>
    <c r="B1">                          <!-- 单元格B1，类型=数字 -->
      <v>100</v>
    </c>
  </row>
</sheetData>
```

**单元格类型处理：**

| 类型代码 | 说明 | 处理方式 |
|---------|------|---------|
| `t="s"` | 共享字符串 | 从sharedStrings表查找 |
| `t="b"` | 布尔值 | 1→"true", 0→"false" |
| `t="d"` | 日期 | 返回原始值 |
| `t="e"` | 错误 | `[错误: 值]` |
| 无类型 | 数字 | 直接返回值 |

#### Step 4: 生成Markdown表格

```typescript
private parseWorksheet(xmlContent: string, sharedStrings: string[]): string {
  // 1. 解析所有行和单元格
  // 2. 记录列位置 (A, B, C...)
  // 3. 生成Markdown表格格式
  
  // 输出格式:
  // ## SheetName
  // | A | B | C |
  // |---|---|---|
  // | value1 | value2 | value3 |
}
```

**列号转换：**

```typescript
// A -> 0, B -> 1, Z -> 25, AA -> 26
private columnLetterToIndex(letter: string): number {
  let result = 0;
  for (let i = 0; i < letter.length; i++) {
    result = result * 26 + (letter.charCodeAt(i) - 64);
  }
  return result - 1;
}

// 0 -> A, 1 -> B, 25 -> Z, 26 -> AA
private columnIndexToLetter(index: number): string {
  // ... 处理26进制转换
}
```

### 输出格式

每个工作表生成一个DataBlock：

- **内容类型**: TABLE
- **pageNumber**: 工作表编号 (1, 2, 3...)
- **addr**: 缓存文件路径 (`table_Sheet1.md`, `table_数据表.md`)

---

## 数据块结构

### DataBlock接口

```typescript
class DataBlock {
  blockId: string;         // 唯一标识 (格式: filePath_index_type)
  modality: ModalityType;  // 内容类型 (TEXT, TABLE, IMAGE)
  content: string;         // 文本内容或描述
  textContent: string;     // 用于语义分析的文本
  filePath: string;        // 原始文件路径
  addr: string;            // 缓存文件路径
  pageNumber: number;      // 页/表/幻灯片编号
  metadata: FileMetadata;  // 元数据
}
```

### ModalityType枚举

| 类型 | 说明 | 使用场景 |
|-----|------|---------|
| TEXT | 文本内容 | PPT幻灯片、Word段落 |
| TABLE | 表格内容 | Excel工作表 |
| IMAGE | 图片内容 | 嵌入媒体图片 |

### Metadata结构

```typescript
interface FileMetadata {
  source: string;       // 解析器标识 ('pptparser', 'wordparser', 'excelparser')
  fileName: string;     // 文件名
  format: string;       // 格式 ('pptx', 'docx', 'xlsx')
  parsingMode: string;  // 解析模式 ('local', 'placeholder', 'error')
  
  // PPTX特有
  slideNumber?: number;
  slideName?: string;
  
  // DOCX特有
  // 无额外字段
  
  // XLSX特有
  sheetName?: string;
  sheetIndex?: number;
  worksheetFile?: string;
  
  // 媒体图片通用
  mediaName?: string;
  mediaFileName?: string;
  mediaIndex?: number;
  
  // 缓存路径
  cachePath?: string;
  
  // 错误信息
  error?: string;
}
```

---

## 缓存机制

### CacheUtils类

位置：`entry/src/main/ets/utils/CacheUtils.ets`

### 缓存目录结构

```
<cacheDir>/data_blocks/
├── 简易电商系统_4_1视图架构设计_3958ccf4_3bbd/
│   ├── slide_1.md           ← PPT幻灯片1（Markdown格式，含表格）
│   ├── slide_2.md
│   ├── image1.png           ← 嵌入图片
│   └── ...
├── 文档名称_哈希/
│   ├── text_1.md            ← Word文本（Markdown格式，含表格）
│   ├── image1.png
│   └── ...
├── 表格文件_哈希/
│   ├── table_Sheet1.md      ← Excel工作表(Markdown格式)
│   ├── table_数据表.md
│   └── ...
```

### 缓存路径命名规则

```typescript
// 文件名 + 哈希值避免冲突
cachePath = `${cacheDir}/data_blocks/${baseName}_${hash}/`;
```

### 保存方法

```typescript
// 保存文本
await cacheUtils.saveTextToCache(content, cachePath, fileName);

// 保存二进制（图片）
await cacheUtils.saveBinaryToCache(buffer, cachePath, fileName);
```

### addr字段用途

| 场景 | addr值 |
|-----|--------|
| 文本块 | 缓存文本文件路径 |
| 图片块 | 缓存图片文件路径 |
| 占位块 | 原始文件路径 |
| 错误块 | 原始文件路径 |

---

## 错误处理

### 解析错误分类

| 错误类型 | parsingMode | 处理方式 |
|---------|-------------|---------|
| 缓存目录创建失败 | 'error' | 返回单个错误块 |
| ZIP读取失败 | 'error' | 返回单个错误块 |
| 无内容提取 | 'placeholder' | 返回占位块 |
| 解析成功 | 'local' | 返回实际内容块 |

### 错误块内容

```typescript
block.setContent(`[PPT演示文稿解析错误: ${fileName}]`);
block.setMetadata({
  'source': 'pptparser',
  'error': error.message,
  'parsingMode': 'error'
});
```

---

## 性能优化

### ZIP读取优化

1. **使用Central Directory大小信息**：避免Data Descriptor模式的解析问题
2. **按偏移排序处理**：顺序读取提高IO效率
3. **批量解压**：一次性解压所有条目

### XML解析优化

1. **正则表达式匹配**：避免完整DOM解析开销
2. **增量提取**：只处理需要的元素
3. **跳过空内容**：减少不必要的处理

### 内存管理

1. **及时释放ZIP数据**：解析完成后释放原始字节数组
2. **缓存文件持久化**：避免重复解析

---

## 扩展建议

### 支持更多格式属性

当前实现提取基本文本，可扩展：

- **PPTX**: 幻灯片标题、备注、动画
- **DOCX**: 样式信息、批注、修订
- **XLSX**: 公式、图表、条件格式

### 支持更多媒体类型

- EMF/WMF矢量图转换
- 嵌入OLE对象
- 音频/视频提取

### 并行解析

大型文件可采用Worker线程并行解析多个sheet/slide。

---

## 参考文档

- [ECMA-376: Office Open XML File Formats](https://www.ecma-international.org/publications-and-standards/standards/ecma-376/)
- [ISO/IEC 29500: Information technology — Document description and processing languages](https://www.iso.org/standard/72571.html)
- [ZIP File Format Specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
- [HarmonyOS zlib API](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/zlib-dev-guide)

---

## C++ Office转换器（DOC/PPT/XLS → DOCX/PPTX/XLSX）

### 概述

`entry/src/main/cpp/office_converter/` 目录包含 C++ 实现的 Office 二进制格式转换器，将旧格式文件转换为 OOXML 格式：

| 输入格式 | 输出格式 | 主要代码文件 |
|---------|---------|-------------|
| DOC (Word 97-2003) | DOCX | `ww8_table_parser.hpp`, `docx_writer.hpp` |
| PPT (PowerPoint 97-2003) | PPTX | `office_converter.cpp` |
| XLS (Excel 97-2003) | XLSX | `office_converter.cpp` |

### HarmonyOS 平台兼容性问题

#### 问题：`std::vector<uint8_t>` iterator 构造函数异常

**现象**：在 HarmonyOS 上使用 `std::vector<uint8_t>(str.begin(), str.end())` 将字符串转换为 vector 时，会抛出 `std::length_error: vector` 异常导致程序崩溃。

**根因分析**：
- HarmonyOS 使用 musl libc，与 Windows MSVC 的内存分配机制不同
- iterator 构造函数在 musl libc 下的 `max_size()` 计算或内存分配存在兼容性问题
- Windows test 代码使用 minizip 库，直接传递字符串指针（`str.c_str()`），不需要创建 vector

**解决方案**：使用 `resize + memcpy` 替代 iterator 构造：

```cpp
// ❌ 问题代码 - iterator 构造
std::vector<uint8_t> vec(str.begin(), str.end());

// ✅ 安全代码 - resize + memcpy
inline std::vector<uint8_t> stringToVector(const std::string& str) {
    std::vector<uint8_t> result;
    if (str.size() > 0) {
        result.resize(str.size());
        std::memcpy(result.data(), str.data(), str.size());
    }
    return result;
}
```

#### DOCX vs PPTX 实现差异

| 项目 | DOCX (`docx_writer.hpp`) | PPTX (`office_converter.cpp`) |
|-----|-------------------------|------------------------------|
| ZIP 打包 | 自己实现 `DocxZipWriter` | 自己实现 `createZIP` |
| CRC32 | 使用 zlib `crc32()` | 自己实现 `CRC32_TABLE` + `calculateCRC32()` |
| 字符串转 vector | 使用 `stringToVector()` (已修复) | 使用 iterator 构造 (暂未修复) |
| 库依赖 | zlib | 无额外依赖 |

**注意**：PPTX 目前能正常工作，但代码中仍使用 iterator 构造方式。建议未来统一改为 `resize + memcpy` 方式以确保稳定性。

### 代码架构

```
entry/src/main/cpp/office_converter/
├── office_converter.cpp      # 主转换逻辑、PPT/XLS 转换、ZIP 打包
├── office_converter.h        # 头文件定义
├── ww8_structs.hpp           # WW8 (DOC) 结构体定义
├── ww8_table_parser.hpp      # DOC 表格解析器 (LibreOffice 算法移植)
├── ole2_parser.hpp           # OLE2 CFB 容器解析
└── docx_writer.hpp           # DOCX ZIP 打包写入器
```

### 转换流程

```
DOC 文件转换流程:
1. OLE2Parser::open() → 解析 OLE2 容器结构
2. 读取 WordDocument、0Table/1Table 流
3. WW8TableParser::parseDocument() → 解析 WW8 二进制格式
   - 解析 FIB (文件信息块)
   - 解析 Piece Table (CP→FC 映射)
   - 解析 PAPX (段落属性)
   - 检测表格边界 (bStartTab/bStopTab)
   - 解析 TC80 结构 (单元格合并信息)
4. DocxWriter::writeDocument() → 生成 DOCX
   - DocxContentBuilder 构建 document.xml
   - DocxZipWriter 打包 ZIP 文件
```

### 关键移植说明

WW8 表格解析算法移植自 LibreOffice `sw/source/filter/ww8/`：

| LibreOffice 文件 | 移植内容 |
|-----------------|---------|
| `ww8struc.hxx` | WW8_TCellVer8、WW8_TCell 结构体 |
| `ww8par.cxx` | 表格边界检测逻辑 |
| `ww8par2.cxx` | sprmTDefTable 解析 |
| `ww8scan.cxx` | FKP、Piece Table 解析 |

---

## 参考文档（C++ 转换器）