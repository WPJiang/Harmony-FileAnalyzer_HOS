# File Analyzer 项目

## 项目简介

File Analyzer 是一个多功能文件分析工程，支持多种文件格式（PPT、Word、PDF、WAV、JPG等）的解析和分析。通过数据解析、语义表征、语义相似度计算和语义聚类等模块，实现对不同模态文件的统一处理和分析。

### 主要功能

- **多格式文件解析**：支持PPT、Word、PDF、WAV、JPG等多种文件格式的解析
- **语义表征**：将不同模态的数据转化为统一的语义表示（文本描述、关键词、语义向量）
- **语义相似度计算**：融合向量相似度、BM25分数和关键词相似度
- **语义聚类**：基于预定义语义类别进行聚类分析

## 系统架构

本项目采用模块化设计，主要包含以下核心模块：

1. **数据解析模块**：解析不同格式文件为统一数据块
2. **语义表征模块**：生成文本描述、关键词和语义向量
3. **语义相似度计算模块**：计算不同语义块之间的相似度
4. **语义聚类模块**：基于预定义类别进行语义聚类

## 快速开始

### 环境要求

- Python 3.8+
- Conda（推荐）

### 安装步骤

1. **创建虚拟环境**

```bash
# 创建虚拟环境
conda create -n file_analyzer python=3.8

# 激活虚拟环境
conda activate file_analyzer
```

2. **安装依赖**

```bash
# 安装项目依赖
pip install -r requirements.txt
```

### 基本用法

```python
from file_analyzer import DataParser, SemanticRepresentation, SemanticSimilarity, SemanticClustering

# 1. 解析文件
parser = DataParser()
data_blocks = parser.parse('example.pdf')

# 2. 生成语义表征
rep = SemanticRepresentation()
semantic_blocks = rep.represent_batch(data_blocks)

# 3. 计算相似度
sim = SemanticSimilarity()
sim.fit(semantic_blocks)
query_block = semantic_blocks[0]
similarity_results = sim.search(query_block, top_k=5)

# 4. 聚类分析
cluster = SemanticClustering()
for block in semantic_blocks:
    result = cluster.cluster(block)
    print(f"Block {block.block_id} clustered to: {result.category_name}")
```

## 模块详情

### 数据解析模块

支持以下文件格式：

| 格式 | 扩展名 | 解析器类 |
|------|--------|----------|
| PDF | .pdf | PDFParser |
| Word | .doc, .docx | WordParser |
| PowerPoint | .ppt, .pptx | PPTParser |
| 图片 | .jpg, .jpeg, .png, .gif | ImageParser |
| 音频 | .wav, .mp3 | AudioParser |

### 语义表征模块

支持以下语义向量生成模型：

| 模型名称 | 库 | 默认模型 | 特点 |
|---------|------|----------|------|
| SentenceTransformer | sentence-transformers | paraphrase-multilingual-MiniLM-L12-v2 | 支持多语言 |
| Text2Vec | text2vec | shibing624/text2vec-base-chinese | 针对中文优化 |
| OpenAI | openai | text-embedding-ada-002 | 需要API密钥 |

### 语义相似度计算模块

融合以下相似度计算方法：

- **向量相似度**：使用余弦相似度计算语义向量之间的相似度
- **BM25分数**：基于文本的BM25算法计算相似度
- **关键词相似度**：使用Jaccard相似度计算关键词之间的相似度
- **融合相似度**：加权融合以上三种相似度

### 语义聚类模块

预定义语义类别：

| 类别名称 | 描述 | 关键词 |
|---------|------|--------|
| 技术文档 | 技术规范、API文档、技术手册等 | 技术、API、接口、开发、代码、系统、架构、配置、部署、服务器 |
| 业务文档 | 业务流程、需求文档、市场分析等 | 业务、流程、需求、市场、分析、方案、策略、规划、运营、管理 |
| 财务文档 | 财务报表、预算、审计报告等 | 财务、报表、预算、审计、成本、收益、利润、投资、税务、资金 |
| 人事文档 | 招聘、培训、绩效考核等 | 人事、招聘、培训、绩效、考核、薪资、福利、晋升、离职、考勤 |
| 法律文档 | 合同、协议、法规等 | 法律、合同、协议、法规、条款、权利、义务、责任、纠纷、诉讼 |

## 配置说明

### 语义表征配置

```python
config = {
    'embedding': {
        'type': 'sentence_transformer',  # 可选: sentence_transformer, text2vec, openai
        'model_name': 'paraphrase-multilingual-MiniLM-L12-v2'  # 模型名称
    },
    'keyword': {
        'method': 'jieba',  # 关键词提取方法
        'top_k': 10  # 关键词提取数量
    },
    'description': {
        'max_length': 512  # 文本描述最大长度
    }
}

rep = SemanticRepresentation(config)
```

### 语义相似度配置

```python
config = {
    'fusion': {
        'vector_weight': 0.4,  # 向量相似度权重
        'bm25_weight': 0.4,  # BM25分数权重
        'keyword_weight': 0.2  # 关键词相似度权重
    },
    'bm25': {
        'k1': 1.5,  # BM25参数
        'b': 0.75  # BM25参数
    }
}

sim = SemanticSimilarity(config)
```

## 测试

运行测试脚本验证功能：

```bash
# 运行基本测试
python file_analyzer/tests/run_test.py

# 运行完整测试
python file_analyzer/tests/test_all.py

# 测试语义向量生成
python test_semantic_vector.py
```

## 扩展指南

### 扩展文件格式

1. 继承 `BaseParser` 类
2. 实现 `parse` 方法
3. 在 `DataParser` 中注册新的解析器

### 扩展语义向量模型

1. 继承 `EmbeddingModel` 类
2. 实现 `encode` 和 `encode_single` 方法
3. 在 `SemanticRepresentation._init_embedding_model` 中添加新模型类型

### 扩展语义类别

1. 创建 `SemanticCategory` 实例
2. 在 `SemanticClustering` 初始化时传入自定义类别列表

## 性能优化

- **模型加载**：语义向量模型首次加载较慢，建议在应用启动时预加载
- **批量处理**：对于大量文件，使用批量处理方法（如 `represent_batch`）提高效率
- **缓存**：对于重复处理的文件，建议缓存解析结果和语义表征
- **并行处理**：对于大规模文件分析，考虑使用多线程或多进程并行处理

## 应用场景

- **文档管理系统**：自动分类和组织文档
- **信息检索**：基于语义的文档搜索
- **知识图谱构建**：从文档中提取知识
- **智能问答系统**：基于文档内容回答问题
- **内容推荐**：基于语义相似度推荐相关文档

## 依赖说明

主要依赖包：

- sentence-transformers：语义向量生成
- jieba：中文分词
- numpy：数值计算
- pdfplumber：PDF解析
- python-pptx：PPT解析
- python-docx：Word解析
- Pillow：图片处理
- pydub：音频处理

## 版本信息

- **版本**：1.0.0
- **更新日期**：2026-02-27

## 许可证

本项目采用 MIT 许可证。

## 联系方式

如有问题或建议，请联系项目维护者。