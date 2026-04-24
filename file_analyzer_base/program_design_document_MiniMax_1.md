# File Analyzer 项目程序设计文档

## 1. 项目概述

File Analyzer 是一个多功能文件分析工程，支持多种文件格式（PPT、Word、PDF、WAV、JPG等）的解析和分析。通过数据解析、语义表征、语义相似度计算和语义分类等模块，实现对不同模态文件的统一处理和分析。

### 1.1 主要功能

- **多格式文件解析**：支持PDF、Word、PPT、图片和音频等多种文件格式的解析
- **语义表征**：将不同模态的数据转化为统一的语义表示（文本描述、关键词、语义向量）
- **语义相似度计算**：融合向量相似度、BM25分数和关键词相似度
- **语义分类**：基于预定义语义类别进行文件分类
- **OCR文本提取**：支持图片OCR识别，提取图片中的文字内容
- **数据库持久化**：使用SQLite存储文件信息、数据块、语义块和分类结果
- **GUI界面**：提供PyQt5图形用户界面，支持目录扫描、文件分析和结果展示

### 1.2 技术栈

- **编程语言**：Python 3.10+
- **GUI框架**：PyQt5
- **数据库**：SQLite3
- **核心依赖**：
  - sentence-transformers（语义向量生成）
  - paddleocr/paddlepaddle（OCR文字识别）
  - jieba（中文分词）
  - numpy（数值计算）
  - pdfplumber/pymupdf（PDF解析）
  - python-pptx（PPT解析）
  - python-docx（Word解析）
  - Pillow（图片处理）
  - pydub（音频处理）

---

## 2. 系统架构

### 2.1 整体架构

```mermaid
flowchart TB
    subgraph UI["UI层 - PyQt5"]
        direction TB
        MW[主窗口 MainWindow]
        FB[文件浏览器 FileBrowser]
        CP[分类结果面板 ClassificationPanel]
        SP[搜索面板 SearchPanel]
        RP[推荐面板 RecommendationPanel]
        PP[预览面板 PreviewPanel]
    end
    
    subgraph Business["业务逻辑层"]
        direction TB
        DS[目录扫描模块 DirectoryScanner]
        DP[数据解析模块 DataParser]
        SR[语义表征模块 SemanticRepresentation]
        SS[语义相似度模块 SemanticSimilarity]
        SC[语义分类模块 SemanticClassification]
        SQ[语义查询模块 SemanticQuery]
    end
    
    subgraph DataAccess["数据访问层"]
        direction TB
        DB[(DatabaseManager)]
        FT[文件表 files]
        DT[数据块表 data_blocks]
        ST[语义块表 semantic_blocks]
        CT[分类结果表 classification_results]
    end
    
    UI --> Business
    Business --> DataAccess
    
    MW --> DS
    MW --> DP
    MW --> SC
    
    DP --> PDF[PDF解析器]
    DP --> WP[Word解析器]
    DP --> PPT[PPT解析器]
    DP --> IP[图片解析器]
    DP --> AP[音频解析器]
    
    SR --> EM[嵌入模型]
    SR --> KE[关键词提取器]
    SR --> ITE[图片文本提取器]
    
    IP --> POCR[PaddleOCR]
    ITE --> POCR
    
    SS --> VS[向量相似度]
    SS --> BM[BM25]
    SS --> KS[关键词相似度]
    
    SC --> SS
    
    DB --> FT
    DB --> DT
    DB --> ST
    DB --> CT
```

### 2.2 模块依赖关系

```mermaid
flowchart LR
    subgraph Core["核心模块"]
        DP[数据解析模块]
        SR[语义表征模块]
        SS[语义相似度模块]
        SC[语义分类模块]
    end
    
    subgraph Parser["解析器"]
        PDF[PDFParser]
        WP[WordParser]
        PPT[PPTParser]
        IP[ImageParser]
        AP[AudioParser]
    end
    
    subgraph Model["模型层"]
        ST[SentenceTransformer]
        KE[jieba关键词提取]
        OCR[PaddleOCR]
    end
    
    subgraph Storage["存储层"]
        DB[(SQLite)]
    end
    
    DP --> PDF
    DP --> WP
    DP --> PPT
    DP --> IP
    DP --> AP
    
    SR --> ST
    SR --> KE
    SR --> OCR
    
    SS --> DB
    SC --> DB
    DP --> DB
    SR --> DB
```

---

## 3. 核心业务流程

### 3.1 文件分析主流程

```mermaid
sequenceDiagram
    participant User as 用户
    participant UI as UI界面
    participant DS as 目录扫描模块
    participant DP as 数据解析模块
    participant SR as 语义表征模块
    participant SC as 语义分类模块
    participant DB as 数据库
    
    User->>UI: 选择目录
    UI->>DS: 扫描目录
    DS->>DB: 写入文件表(files)
    DB-->>UI: 返回文件列表
    
    UI->>UI: 显示树形目录
    
    User->>UI: 点击分析按钮
    UI->>DP: 解析文件(mode=1轻量或2深度)
    DP-->>UI: 返回数据块列表
    
    UI->>DB: 写入数据块表(data_blocks)
    
    UI->>SR: 生成语义表征
    SR->>DB: 写入语义块表(semantic_blocks)
    SR-->>UI: 返回语义块
    
    UI->>SC: 执行分类
    SC-->>UI: 返回分类结果
    
    UI->>DB: 写入分类结果表
    UI->>DB: 更新文件表状态和类别
    
    UI-->>User: 显示分类结果
```

### 3.2 数据解析流程

```mermaid
flowchart TD
    A[开始解析文件] --> B{解析模式}
    B -->|轻量模式 1| C[图片文件]
    B -->|轻量模式 1| D[多页文档]
    B -->|深度模式 2| E[逐页/逐块解析]
    
    C --> C1[生成单个数据块]
    C1 --> C2[文本: Image file: 文件名]
    
    D --> D1[生成单个数据块]
    D1 --> D2[文本: 标题 + 首页内容]
    D2 --> D3[截断到max_length]
    
    E --> E1[PDF: 按页解析]
    E --> E2[Word: 按段落解析]
    E --> E3[PPT: 按幻灯片解析]
    E --> E4[图片: 逐个处理]
    
    E1 --> F[返回多个数据块]
    E2 --> F
    E3 --> F
    E4 --> F
    
    C2 --> G[写入数据库]
    D3 --> G
    F --> G
    
    G --> H[结束]
```

### 3.3 OCR处理流程

```mermaid
flowchart TD
    A[图片文件解析] --> B[生成基础描述]
    B --> C["文本: [Image file: 文件名]"]
    
    C --> D{是否启用OCR}
    D -->|是| E[调用PaddleOCR]
    D -->|否| F[返回基础描述]
    
    E --> G[识别图片文字]
    G --> H{是否识别成功}
    
    H -->|是| I[拼接: 基础描述 + OCR文字]
    H -->|否| F
    
    I --> J[返回完整描述]
    F --> J
    
    J --> K[写入数据块表]
```

---

## 4. 模块设计

### 4.1 目录扫描模块

#### 4.1.1 类关系图

```mermaid
classDiagram
    class DirectoryScanner {
        +get_default_directories() Dict[str, str]
        +scan_default_directories() Dict[str, List[str]]
        +scan_directory(directory: str, recursive: bool) List[str]
        +get_directory_structure(directory: str) Dict[str, Any]
    }
    
    class Config {
        +enabled_directories: Dict[str, bool]
        +exclude_patterns: List[str]
    }
    
    DirectoryScanner --> Config
```

#### 4.1.2 核心方法

| 方法名 | 参数 | 返回值 | 功能描述 |
|-------|------|--------|----------|
| `get_default_directories` | 无 | Dict[str, str] | 获取Windows默认目录路径 |
| `scan_default_directories` | 无 | Dict[str, List[str]] | 扫描所有启用的默认目录 |
| `scan_directory` | directory: str, recursive: bool | List[str] | 扫描指定目录 |
| `get_directory_structure` | directory: str | Dict[str, Any] | 获取目录树形结构 |

### 4.2 数据解析模块

#### 4.2.1 类关系图

```mermaid
classDiagram
    class DataParser {
        +parse(file_path: str, parsing_mode: int) List[DataBlock]
        +parse_directory(directory: str, recursive: bool) Dict[str, List[DataBlock]]
        +can_parse(file_path: str) bool
    }
    
    class BaseParser {
        +parse(file_path: str) List[DataBlock]
    }
    
    class PDFParser {
        +parse(file_path: str) List[DataBlock]
    }
    
    class WordParser {
        +parse(file_path: str) List[DataBlock]
    }
    
    class PPTParser {
        +parse(file_path: str) List[DataBlock]
    }
    
    class ImageParser {
        -use_ocr: bool
        -ocr_engine: str
        +parse(file_path: str) List[DataBlock]
    }
    
    class AudioParser {
        +parse(file_path: str) List[DataBlock]
    }
    
    class DataBlock {
        +block_id: str
        +modality: str
        +content: bytes
        +text_content: str
        +page_number: int
        +position: Dict
        +metadata: Dict
    }
    
    DataParser --> BaseParser
    BaseParser <|-- PDFParser
    BaseParser <|-- WordParser
    BaseParser <|-- PPTParser
    BaseParser <|-- ImageParser
    BaseParser <|-- AudioParser
    DataParser --> DataBlock
    ImageParser --> DataBlock
```

#### 4.2.2 解析模式说明

```mermaid
flowchart LR
    subgraph Light["轻量模式 (mode=1)"]
        L1[图片: 单数据块]
        L2[多页文档: 单数据块]
        L3[文本截断: max_length=256]
    end
    
    subgraph Deep["深度模式 (mode=2)"]
        D1[PDF: 逐页解析]
        D2[Word: 按段落解析]
        D3[PPT: 逐幻灯片解析]
        D4[图片: 逐个处理]
    end
    
    Config["config.json: parsing.mode"] --> Light
    Config --> Deep
```

#### 4.2.3 核心方法

| 方法名 | 参数 | 返回值 | 功能描述 |
|-------|------|--------|----------|
| `parse` | file_path: str, parsing_mode: int | List[DataBlock] | 解析文件为数据块 |
| `parse_directory` | directory: str, recursive: bool | Dict[str, List[DataBlock]] | 解析目录下的文件 |
| `can_parse` | file_path: str | bool | 检查是否支持该文件格式 |

### 4.3 语义表征模块

#### 4.3.1 类关系图

```mermaid
classDiagram
    class SemanticRepresentation {
        +represent(block: DataBlock, db_manager, data_block_id, file_id) SemanticBlock
        +represent_batch(blocks: List[DataBlock]) List[SemanticBlock]
    }
    
    class EmbeddingModel {
        +encode(texts: List[str]) np.ndarray
        +encode_single(text: str) np.ndarray
    }
    
    class SentenceTransformerEmbedding {
        +encode(texts: List[str]) np.ndarray
        +encode_single(text: str) np.ndarray
    }
    
    class KeywordExtractor {
        +extract(text: str) List[str]
    }
    
    class ImageTextExtractor {
        -use_ocr: bool
        -ocr_engine: str
        +extract(image_path: str) str
    }
    
    class SemanticBlock {
        +semantic_block_id: str
        +data_block_id: int
        +file_id: int
        +text_description: str
        +keywords: List[str]
        +semantic_vector: bytes
    }
    
    SemanticRepresentation --> EmbeddingModel
    EmbeddingModel <|-- SentenceTransformerEmbedding
    SemanticRepresentation --> KeywordExtractor
    SemanticRepresentation --> ImageTextExtractor
    SemanticRepresentation --> SemanticBlock
```

#### 4.3.2 嵌入模型配置

```mermaid
flowchart TD
    A[配置 config.json] --> B{embedding.type}
    
    B -->|"sentence_transformer"| C[paraphrase-multilingual-MiniLM-L12-v2]
    B -->|"text2vec"| D[shibing624/text2vec-base-chinese]
    B -->|"openai"| E[text-embedding-ada-002]
    
    C --> F[本地加载]
    D --> F
    E --> G[API调用]
```

#### 4.3.3 核心方法

| 方法名 | 参数 | 返回值 | 功能描述 |
|-------|------|--------|----------|
| `represent` | block: DataBlock, db_manager, data_block_id, file_id | SemanticBlock | 生成语义块并写入数据库 |
| `represent_batch` | blocks: List[DataBlock] | List[SemanticBlock] | 批量生成语义块 |
| `encode_single` | text: str | np.ndarray | 编码单个文本为语义向量 |
| `extract` | text: str | List[str] | 提取文本关键词 |

### 4.4 语义分类模块

#### 4.4.1 类关系图

```mermaid
classDiagram
    class SemanticClassification {
        +classify(semantic_block: SemanticBlock) ClassificationResult
        +classify_batch(semantic_blocks: List[SemanticBlock]) List[ClassificationResult]
        +get_category_names() List[str]
    }
    
    class SemanticCategory {
        +name: str
        +description: str
        +keywords: List[str]
    }
    
    class ClassificationResult {
        +file_id: int
        +semantic_block_id: str
        +category_name: str
        +confidence: float
        +all_scores: Dict[str, float]
    }
    
    class SimilarityCalculator {
        +compute_similarity(block: SemanticBlock, category: SemanticCategory) float
    }
    
    SemanticClassification --> SemanticCategory
    SemanticClassification --> ClassificationResult
    SemanticClassification --> SimilarityCalculator
```

#### 4.4.2 预定义语义类别

```mermaid
flowchart TB
    A[8个预定义类别] --> B[技术文档]
    A --> C[商业报告]
    A --> D[学术论文]
    A --> E[会议演示]
    A --> F[合同协议]
    A --> G[产品说明]
    A --> H[新闻资讯]
    A --> I[个人文档]
    
    B --> B1[关键词: 技术、API、开发、代码...]
    C --> C1[关键词: 市场、销售、收入...]
    D --> D1[关键词: 研究、实验、方法...]
    E --> E1[关键词: 会议、演示、培训...]
```

#### 4.4.3 相似度权重配置

```mermaid
flowchart LR
    A[相似度计算] --> B[向量相似度]
    A --> C[BM25分数]
    A --> D[关键词相似度]
    A --> E[时间相似度]
    A --> F[地点相似度]
    
    B --> B1[权重: 0.35]
    C --> C1[权重: 0.30]
    D --> D1[权重: 0.35]
    E --> E1[权重: 0.00]
    F --> F1[权重: 0.00]
    
    B1 --> G[融合得分]
    C1 --> G
    D1 --> G
    E1 --> G
    F1 --> G
```

#### 4.4.4 核心方法

| 方法名 | 参数 | 返回值 | 功能描述 |
|-------|------|--------|----------|
| `classify` | semantic_block: SemanticBlock | ClassificationResult | 对语义块进行分类 |
| `classify_batch` | semantic_blocks: List[SemanticBlock] | List[ClassificationResult] | 批量分类 |
| `get_category_names` | 无 | List[str] | 获取所有类别名称 |

### 4.5 语义相似度模块

#### 4.5.1 类关系图

```mermaid
classDiagram
    class SemanticSimilarity {
        +fit(target_blocks: List[SemanticBlock])
        +compute_similarity(query_block: SemanticBlock, target_block: SemanticBlock) SimilarityResult
        +search(query_block: SemanticBlock, top_k: int, min_score: float) List[SimilarityResult]
    }
    
    class BM25 {
        +fit(documents: List[List[str]])
        +get_score(query: List[str], doc_idx: int) float
    }
    
    class VectorSimilarity {
        +cosine_similarity(vec1: np.ndarray, vec2: np.ndarray) float
    }
    
    class KeywordSimilarity {
        +jaccard_similarity(keywords1: List[str], keywords2: List[str]) float
    }
    
    class SimilarityResult {
        +query_id: str
        +target_id: str
        +fused_score: float
    }
    
    SemanticSimilarity --> BM25
    SemanticSimilarity --> VectorSimilarity
    SemanticSimilarity --> KeywordSimilarity
    SemanticSimilarity --> SimilarityResult
```

### 4.6 数据库模块

#### 4.6.1 数据表关系图

```mermaid
erDiagram
    files ||--o{ data_blocks : "has"
    files ||--o{ semantic_blocks : "has"
    files ||--o{ classification_results : "has"
    data_blocks ||--o{ semantic_blocks : "generates"
    semantic_categories ||--o{ classification_results : "categorizes"
```

#### 4.6.2 文件表 (files)

```mermaid
classDiagram
    class FileRecord {
        +id: int
        +file_path: str
        +file_name: str
        +file_size: int
        +file_type: str
        +modified_time: datetime
        +created_time: datetime
        +analysis_status: int  "0=待分析,1=初步分析,2=深入分析"
        +semantic_categories: str  "JSON: [{category, confidence}, ...]"
        +directory_path: str
        +added_time: datetime
    }
```

#### 4.6.3 核心方法

| 方法名 | 参数 | 返回值 | 功能描述 |
|-------|------|--------|----------|
| `add_file` | file_path, file_name, file_size, file_type, ... | int | 添加文件记录 |
| `add_data_block` | block_id, file_id, modality, content, ... | int | 添加数据块记录 |
| `add_semantic_block` | semantic_block_id, data_block_id, file_id, ... | int | 添加语义块记录 |
| `add_classification_result` | file_id, semantic_block_id, category_name, ... | int | 添加分类结果 |
| `update_file_status` | file_id, status | bool | 更新文件分析状态 |
| `update_file_semantic_categories` | file_id, categories | bool | 更新文件语义类别 |
| `get_files_by_status` | status | List[FileRecord] | 获取指定状态的文件 |
| `clear_all_tables` | 无 | bool | 清空所有数据表 |

### 4.7 UI模块

#### 4.7.1 类关系图

```mermaid
classDiagram
    class MainWindow {
        +db_manager: DatabaseManager
        +analyze_worker: AnalyzeWorker
        +setup_ui()
        +on_scan_directory()
        +on_analyze()
        +on_clear_history()
    }
    
    class AnalyzeWorker {
        +progress: pyqtSignal
        +finished: pyqtSignal
        +error: pyqtSignal
        +run()
    }
    
    class FileBrowser {
        +display_directory_structure()
        +on_item_clicked()
    }
    
    class ClassificationPanel {
        +display_results()
        +build_tree()
    }
    
    class SearchPanel {
        +perform_search()
    }
    
    class PreviewPanel {
        +preview_file()
    }
    
    MainWindow --> AnalyzeWorker
    MainWindow --> FileBrowser
    MainWindow --> ClassificationPanel
    MainWindow --> SearchPanel
    MainWindow --> PreviewPanel
```

#### 4.7.2 UI布局结构

```mermaid
flowchart TB
    subgraph MainWindow["主窗口布局"]
        direction TB
        Menu[菜单栏: 文件/编辑/视图/帮助]
        Toolbar[工具栏: 分析按钮 | 清空历史 | 搜索框]
        
        subgraph Content["内容区域"]
            direction LR
            Left[推荐面板<br/>左侧面板] --> Right[中心区域<br/>分类结果/文件预览]
        end
        
        Status[状态栏]
    end
    
    Menu --> Toolbar
    Toolbar --> Content
    Content --> Status
```

---

## 5. 数据库设计

### 5.1 文件表 (files)

| 字段名 | 数据类型 | 约束 | 描述 |
|-------|---------|------|------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | 文件ID |
| `file_path` | TEXT | NOT NULL, UNIQUE | 文件完整路径 |
| `file_name` | TEXT | NOT NULL | 文件名 |
| `file_size` | INTEGER | NOT NULL | 文件大小（字节） |
| `file_type` | TEXT | NOT NULL | 文件类型（扩展名） |
| `modified_time` | TIMESTAMP | NOT NULL | 文件修改时间 |
| `created_time` | TIMESTAMP | NOT NULL | 文件创建时间 |
| `analysis_status` | INTEGER | DEFAULT 0 | 分析状态（0:待分析, 1:初步分析, 2:深入分析） |
| `semantic_categories` | TEXT | | 语义类别JSON |
| `directory_path` | TEXT | NOT NULL | 所在目录路径 |
| `added_time` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | 添加时间 |

### 5.2 数据块表 (data_blocks)

| 字段名 | 数据类型 | 约束 | 描述 |
|-------|---------|------|------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | 数据块ID |
| `block_id` | TEXT | NOT NULL, UNIQUE | 数据块唯一标识 |
| `file_id` | INTEGER | NOT NULL, FOREIGN KEY | 关联文件ID |
| `modality` | TEXT | NOT NULL | 模态类型 |
| `content` | BLOB | | 原始内容 |
| `text_content` | TEXT | | 文本内容 |
| `page_number` | INTEGER | | 页码 |
| `position` | TEXT | | 位置信息JSON |
| `metadata` | TEXT | | 元数据JSON |
| `created_time` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | 创建时间 |

### 5.3 语义块表 (semantic_blocks)

| 字段名 | 数据类型 | 约束 | 描述 |
|-------|---------|------|------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | 语义块ID |
| `semantic_block_id` | TEXT | NOT NULL, UNIQUE | 语义块唯一标识 |
| `data_block_id` | INTEGER | NOT NULL, FOREIGN KEY | 关联数据块ID |
| `file_id` | INTEGER | NOT NULL, FOREIGN KEY | 关联文件ID |
| `text_description` | TEXT | NOT NULL | 文本描述 |
| `keywords` | TEXT | NOT NULL | 关键词JSON数组 |
| `semantic_vector` | BLOB | | 语义向量 |
| `created_time` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | 创建时间 |

### 5.4 语义类别表 (semantic_categories)

| 字段名 | 数据类型 | 约束 | 描述 |
|-------|---------|------|------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | 类别ID |
| `category_name` | TEXT | NOT NULL, UNIQUE | 类别名称 |
| `description` | TEXT | NOT NULL | 类别描述 |
| `keywords` | TEXT | NOT NULL | 类别关键词JSON数组 |
| `created_time` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | 创建时间 |

### 5.5 分类结果表 (classification_results)

| 字段名 | 数据类型 | 约束 | 描述 |
|-------|---------|------|------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | 结果ID |
| `file_id` | INTEGER | NOT NULL, FOREIGN KEY | 关联文件ID |
| `semantic_block_id` | TEXT | NOT NULL | 关联语义块ID |
| `category_name` | TEXT | NOT NULL | 类别名称 |
| `confidence` | REAL | NOT NULL | 置信度（0-1） |
| `all_scores` | TEXT | | 所有类别得分JSON |
| `created_time` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | 创建时间 |

---

## 6. 配置文件

### 6.1 配置文件结构

```mermaid
flowchart TB
    A[config.json] --> B[initial_directory]
    A --> C[classification]
    A --> D[similarity_weights]
    A --> E[categories]
    A --> F[embedding]
    A --> G[keyword]
    A --> H[description]
    A --> I[image]
    A --> J[parsing]
    
    C --> C1[method: similarity]
    D --> D1[vector_weight: 0.35]
    D --> D2[bm25_weight: 0.30]
    D --> D3[keyword_weight: 0.35]
    
    F --> F1[type: sentence_transformer]
    F --> F2[model_name: paraphrase-multilingual-MiniLM-L12-v2]
    
    I --> I1[use_ocr: true]
    I --> I2[ocr_model: paddleocr]
    
    J --> J1[mode: 1]
    J --> J2[max_text_length: 256]
```

### 6.2 配置项说明

| 配置项 | 类型 | 默认值 | 说明 |
|-------|------|-------|------|
| `initial_directory` | string | - | 初始目录路径 |
| `classification.method` | string | "similarity" | 分类方法 |
| `embedding.type` | string | "sentence_transformer" | 嵌入模型类型 |
| `keyword.top_k` | int | 10 | 关键词提取数量 |
| `image.use_ocr` | bool | true | 是否使用OCR |
| `parsing.mode` | int | 1 | 解析模式: 1轻量/2深度 |
| `parsing.max_text_length` | int | 256 | 轻量模式最大文本长度 |

---

## 7. 测试

### 7.1 测试目录结构

```mermaid
flowchart TB
    A[tests/] --> B[test_data_parser.py]
    A --> C[test_pdf_parser.py]
    A --> D[test_directory_scanner.py]
    A --> E[test_all.py]
    
    F[test_data/] --> F1[1.jpg]
    F --> F2[LLMBook.pdf]
    F --> F3[sample.txt]
    
    G[data_test_debug/] --> G1[教育部学籍在线验证报告_张美娜-学士.pdf]
```

### 7.2 PDF解析测试输出规则

```mermaid
flowchart LR
    A[PDF解析测试] --> B{数据块类型}
    
    B -->|文本块| C[txt_block_<id>.txt]
    B -->|图片块| D[pic_block_<id>.<扩展名>]
```

---

## 8. 打包与部署

### 8.1 打包配置

```mermaid
flowchart TB
    A[PyInstaller打包] --> B[文件分析管理器.spec]
    B --> C[build_exe.py]
    C --> D[dist/文件分析管理器/]
    D --> E[文件分析管理器.exe]
    
    E --> F[开发模式: python ui/main_window.py]
    E --> G[打包模式: 双击exe运行]
```

---

## 9. 总结

### 9.1 已实现功能

```mermaid
flowchart TB
    A[已实现功能] --> B[✓ 多格式文件解析]
    A --> C[✓ 轻量/深度解析模式]
    A --> D[✓ 语义表征生成]
    A --> E[✓ OCR图片识别]
    A --> F[✓ 语义相似度计算]
    A --> G[✓ 语义分类]
    A --> H[✓ SQLite数据库]
    A --> I[✓ 分析状态管理]
    A --> J[✓ PyQt5图形界面]
    A --> K[✓ 树形目录展示]
    A --> L[✓ 打包exe]
```

### 9.2 技术特点

- **模块化设计**：各模块职责清晰，易于维护和扩展
- **配置灵活**：通过配置文件控制解析模式、OCR开关、分类方法等
- **数据库持久化**：支持分析状态跟踪和历史数据管理
- **GUI交互友好**：支持目录树展示、分类结果展示

---

**文档版本**：3.0  
**更新日期**：2026-03-10  
**主要更新**：
- 新增目录扫描模块设计（含mermaid类图）
- 新增数据解析模块详细设计（轻量/深度解析模式）
- 新增OCR功能集成说明（PaddleOCR）
- 新增数据库模块设计（SQLite，5张表）
- 新增UI模块设计（PyQt5）
- 新增配置文件完整说明
- 新增测试目录和打包部署说明
- 整体架构、类关系、核心流程均采用mermaid方式生成
