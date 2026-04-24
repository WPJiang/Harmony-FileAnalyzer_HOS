import os
import sys
import json
from typing import List, Optional, Dict, Any
from dataclasses import dataclass
import numpy as np

_base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _base_dir not in sys.path:
    sys.path.insert(0, _base_dir)

from logger import processing_logger


@dataclass
class ClassificationResult:
    block_id: str
    category_name: str
    confidence: float
    all_scores: Dict[str, float]
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'block_id': self.block_id,
            'category_name': self.category_name,
            'confidence': self.confidence,
            'all_scores': self.all_scores
        }


@dataclass
class SemanticCategory:
    name: str
    description: str
    keywords: List[str]
    text_representation: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'name': self.name,
            'description': self.description,
            'keywords': self.keywords,
            'text_representation': self.text_representation
        }


class SemanticClassification:
    DEFAULT_CONFIG_PATH = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'config.json'
    )

    def __init__(self, config: Optional[Dict[str, Any]] = None, config_path: Optional[str] = None):
        self.config = config or {}
        self.config_path = config_path or self.DEFAULT_CONFIG_PATH

        self.categories: List[SemanticCategory] = []
        self._embedding_model = None
        self._category_vectors: Dict[str, np.ndarray] = {}
        self._category_texts: Dict[str, str] = {}
        self._is_initialized = False

        self.classification_method = "similarity"
        self._llm_client = None
        self._llm_type = None
        self._category_names: List[str] = []
        self._category_descriptions: Dict[str, str] = {}

        self.vector_weight = 0.35
        self.bm25_weight = 0.25
        self.keyword_weight = 0.25
        self.time_weight = 0.08
        self.location_weight = 0.07

        # 类别文本拼接字段配置
        self.vector_fields = ["name", "description", "keywords"]  # 向量表示使用的字段
        self.bm25_fields = ["name", "description", "keywords"]     # BM25计算使用的字段

        self._load_config()
    
    def _load_config(self):
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    file_config = json.load(f)

                if 'classification' in file_config:
                    self.classification_method = file_config['classification'].get('method', 'similarity')

                # 读取类别文本字段配置
                if 'category_text_fields' in file_config:
                    text_fields = file_config['category_text_fields']
                    self.vector_fields = text_fields.get('vector', ["name", "description", "keywords"])
                    self.bm25_fields = text_fields.get('bm25', ["name", "description", "keywords"])
                    print(f"类别文本字段配置: 向量={self.vector_fields}, BM25={self.bm25_fields}")

                if 'categories' in file_config:
                    for cat_data in file_config['categories']:
                        self.categories.append(SemanticCategory(
                            name=cat_data['name'],
                            description=cat_data.get('description', ''),
                            keywords=cat_data.get('keywords', [])
                        ))
                        self._category_names.append(cat_data['name'])
                        self._category_descriptions[cat_data['name']] = cat_data.get('description', '')

                if 'similarity_weights' in file_config:
                    weights = file_config['similarity_weights']
                    self.vector_weight = weights.get('vector_weight', 0.35)
                    self.bm25_weight = weights.get('bm25_weight', 0.25)
                    self.keyword_weight = weights.get('keyword_weight', 0.25)
                    self.time_weight = weights.get('time_weight', 0.08)
                    self.location_weight = weights.get('location_weight', 0.07)

                # 使用配置的字段构建 _category_texts
                if 'categories' in file_config:
                    for cat_data in file_config['categories']:
                        text_rep = self._build_category_text(cat_data, self.bm25_fields)
                        self._category_texts[cat_data['name']] = text_rep

                print(f"已从配置文件加载 {len(self.categories)} 个类别，分类方法: {self.classification_method}")

            except Exception as e:
                print(f"加载配置文件失败: {e}")
                self._init_default_categories()
        else:
            print(f"配置文件不存在: {self.config_path}")
            self._init_default_categories()

        if self.config.get('categories'):
            self.categories = []
            self._category_names = []
            self._category_descriptions = {}
            for cat_data in self.config['categories']:
                self.categories.append(SemanticCategory(
                    name=cat_data['name'],
                    description=cat_data.get('description', ''),
                    keywords=cat_data.get('keywords', [])
                ))
                self._category_names.append(cat_data['name'])
                self._category_descriptions[cat_data['name']] = cat_data.get('description', '')

        if self.config.get('classification'):
            self.classification_method = self.config['classification'].get('method', self.classification_method)

        # 从传入的config中读取类别文本字段配置
        if self.config.get('category_text_fields'):
            text_fields = self.config['category_text_fields']
            self.vector_fields = text_fields.get('vector', self.vector_fields)
            self.bm25_fields = text_fields.get('bm25', self.bm25_fields)

        weights = self.config.get('similarity_weights', {})
        if weights:
            self.vector_weight = weights.get('vector_weight', self.vector_weight)
            self.bm25_weight = weights.get('bm25_weight', self.bm25_weight)
            self.keyword_weight = weights.get('keyword_weight', self.keyword_weight)
            self.time_weight = weights.get('time_weight', self.time_weight)
            self.location_weight = weights.get('location_weight', self.location_weight)

    def _build_category_text(self, category_data: Dict[str, Any], fields: List[str]) -> str:
        """根据配置的字段构建类别文本

        Args:
            category_data: 类别数据字典，包含 name, description, keywords
            fields: 要使用的字段列表，如 ["name", "description", "keywords"]

        Returns:
            拼接后的文本字符串
        """
        text_parts = []

        for field in fields:
            if field == "name":
                name = category_data.get("name", "")
                if name:
                    text_parts.append(name)
            elif field == "description":
                desc = category_data.get("description", "")
                if desc:
                    text_parts.append(desc)
            elif field == "keywords":
                keywords = category_data.get("keywords", [])
                if keywords:
                    text_parts.extend(keywords)

        return " ".join(text_parts)

    def _build_category_text_from_object(self, category: SemanticCategory, fields: List[str]) -> str:
        """根据配置的字段从 SemanticCategory 对象构建文本

        Args:
            category: SemanticCategory 对象
            fields: 要使用的字段列表

        Returns:
            拼接后的文本字符串
        """
        text_parts = []

        for field in fields:
            if field == "name" and category.name:
                text_parts.append(category.name)
            elif field == "description" and category.description:
                text_parts.append(category.description)
            elif field == "keywords" and category.keywords:
                text_parts.extend(category.keywords)

        return " ".join(text_parts)

    def _init_default_categories(self):
        default_categories = [
            SemanticCategory(
                name="技术文档",
                description="技术规范、API文档、技术手册等",
                keywords=["技术", "API", "接口", "开发", "代码", "系统", "架构", "配置", "部署", "服务器"]
            ),
            SemanticCategory(
                name="商业报告",
                description="商业计划、市场分析、财务报告等",
                keywords=["市场", "销售", "收入", "利润", "客户", "竞争", "战略", "投资", "商业", "业务"]
            ),
            SemanticCategory(
                name="学术论文",
                description="研究论文、学术文章、研究报告等",
                keywords=["研究", "实验", "方法", "结果", "分析", "理论", "模型", "数据", "论文", "引用"]
            ),
            SemanticCategory(
                name="会议演示",
                description="会议PPT、演讲稿、培训材料等",
                keywords=["会议", "演示", "培训", "演讲", "PPT", "展示", "介绍", "汇报", "方案", "计划"]
            ),
            SemanticCategory(
                name="合同协议",
                description="合同、协议、法律文件等",
                keywords=["合同", "协议", "条款", "甲方", "乙方", "法律", "责任", "义务", "权利", "签署"]
            ),
            SemanticCategory(
                name="产品说明",
                description="产品手册、使用指南、说明书等",
                keywords=["产品", "功能", "使用", "操作", "说明", "指南", "特性", "规格", "型号", "安装"]
            ),
            SemanticCategory(
                name="新闻资讯",
                description="新闻报道、新闻稿、媒体文章等",
                keywords=["新闻", "报道", "发布", "消息", "媒体", "记者", "事件", "宣布", "最新", "动态"]
            ),
            SemanticCategory(
                name="个人文档",
                description="简历、个人陈述、信函等",
                keywords=["个人", "简历", "经历", "教育", "技能", "自我", "介绍", "申请", "工作", "职位"]
            ),
        ]
        
        self.categories = default_categories
        self._category_names = [cat.name for cat in default_categories]
        self._category_descriptions = {cat.name: cat.description for cat in default_categories}

        # 使用配置的字段构建文本
        for cat in self.categories:
            text_rep = self._build_category_text_from_object(cat, self.bm25_fields)
            self._category_texts[cat.name] = text_rep
    
    def initialize(self, embedding_model=None):
        if self.classification_method == "llm":
            self._init_llm_client()
            self._is_initialized = True
            print(f"语义分类模块初始化完成(LLM模式)，共 {len(self.categories)} 个类别")
            return
        
        if embedding_model:
            self._embedding_model = embedding_model
        else:
            SentenceTransformerEmbedding = None
            
            try:
                from semantic_representation.semantic_representation import SentenceTransformerEmbedding
            except ImportError:
                try:
                    from ..semantic_representation import SentenceTransformerEmbedding
                except ImportError:
                    try:
                        import importlib.util
                        module_path = os.path.join(_base_dir, 'semantic_representation', 'semantic_representation.py')
                        if os.path.exists(module_path):
                            spec = importlib.util.spec_from_file_location('semantic_representation', module_path)
                            module = importlib.util.module_from_spec(spec)
                            spec.loader.exec_module(module)
                            SentenceTransformerEmbedding = module.SentenceTransformerEmbedding
                    except Exception as e:
                        raise ImportError(f"无法加载 SentenceTransformerEmbedding: {str(e)}")
            
            if SentenceTransformerEmbedding is not None:
                self._embedding_model = SentenceTransformerEmbedding()
            else:
                raise ImportError(
                    "sentence-transformers is required. "
                    "Install with: pip install sentence-transformers"
                )
        
        self._compute_category_vectors()
        self._is_initialized = True
        print(f"语义分类模块初始化完成，共 {len(self.categories)} 个类别")
    
    def _init_llm_client(self):
        """初始化LLM客户端（支持云侧模型和Ollama）"""
        try:
            from models.model_manager import get_llm_client, get_llm_type, is_llm_available

            self._llm_client = get_llm_client()
            self._llm_type = get_llm_type()

            if is_llm_available():
                print(f"[SemanticClassification] {self._llm_type} 服务可用")
            else:
                print(f"[SemanticClassification] WARNING: {self._llm_type} 服务不可用，LLM分类可能失败")
        except ImportError as e:
            print(f"[SemanticClassification] WARNING: 无法导入LLM客户端: {e}")
            self._llm_client = None
        except Exception as e:
            print(f"[SemanticClassification] WARNING: 初始化LLM客户端失败: {e}")
            self._llm_client = None
    
    def _compute_category_vectors(self):
        """计算类别向量，使用配置的字段拼接文本"""
        for category in self.categories:
            # 使用配置的 vector_fields 构建向量文本
            vector_text = self._build_category_text_from_object(category, self.vector_fields)

            if vector_text:
                vector = self._embedding_model.encode_single(vector_text)
                self._category_vectors[category.name] = vector

            # 使用配置的 bm25_fields 构建 BM25 文本（可能与向量文本不同）
            bm25_text = self._build_category_text_from_object(category, self.bm25_fields)
            self._category_texts[category.name] = bm25_text
    
    def classify(self, block) -> ClassificationResult:
        module_name = "SemanticClassification"
        
        from semantic_representation import SemanticBlock
        
        if not self._is_initialized:
            error = RuntimeError("Classification not initialized. Call initialize() first.")
            processing_logger.log_error(module_name, error)
            raise error
        
        if not isinstance(block, SemanticBlock):
            error = TypeError(f"Expected SemanticBlock, got {type(block)}")
            processing_logger.log_error(module_name, error)
            raise error
        
        if self.classification_method == "llm":
            return self._classify_with_llm(block)
        
        return self._classify_with_similarity(block)
    
    def _classify_with_llm(self, block) -> ClassificationResult:
        """使用LLM进行分类"""
        module_name = "SemanticClassification-LLM"
        
        from semantic_representation import SemanticBlock
        
        processing_logger.log_module_start(
            module_name=module_name,
            file_path="semantic_block",
            extra_info={
                "block_id": block.block_id,
                "has_image": hasattr(block, 'image_path') and block.image_path is not None,
                "has_text": bool(block.text_description)
            }
        )
        
        if self._llm_client is None:
            processing_logger.log_error(module_name, RuntimeError("LLM客户端未初始化"))
            result = ClassificationResult(
                block_id=block.block_id,
                category_name="其他",
                confidence=0.0,
                all_scores={"其他": 0.0}
            )
            return result

        image_path = getattr(block, 'image_path', None)
        text_description = block.text_description or ""

        try:
            if image_path and os.path.exists(image_path):
                processing_logger.log_step("LLM分类", f"使用图片分类: {image_path}")
                llm_result = self._llm_client.classify_image(
                    image_path=image_path,
                    categories=self._category_names
                )
            else:
                processing_logger.log_step("LLM分类", "使用文本分类")
                llm_result = self._llm_client.classify_text(
                    text=text_description,
                    categories=self._category_names,
                    category_descriptions=self._category_descriptions
                )
            
            category = llm_result.get("category", "其他")
            confidence = llm_result.get("confidence", 0.5)
            reasoning = llm_result.get("reasoning", "")
            
            if category not in self._category_names:
                category = "其他"
            
            all_scores = {cat: 0.0 for cat in self._category_names}
            all_scores[category] = confidence
            
            processing_logger.log_classification(category, confidence, all_scores)
            
            result = ClassificationResult(
                block_id=block.block_id,
                category_name=category,
                confidence=confidence,
                all_scores=all_scores
            )
            
            processing_logger.log_module_output(module_name, {
                "block_id": result.block_id,
                "category": result.category_name,
                "confidence": result.confidence,
                "reasoning": reasoning[:100] if reasoning else ""
            })
            processing_logger.log_module_end(module_name, success=True,
                                            message=f"LLM分类完成: {category} (置信度: {confidence:.4f})")
            
            return result
            
        except Exception as e:
            processing_logger.log_error(module_name, e, "LLM分类失败")
            result = ClassificationResult(
                block_id=block.block_id,
                category_name="其他",
                confidence=0.0,
                all_scores={"其他": 0.0}
            )
            return result
    
    def _classify_with_similarity(self, block) -> ClassificationResult:
        """使用语义相似度进行分类(原有方法)"""
        module_name = "SemanticClassification"
        
        processing_logger.log_module_start(
            module_name=module_name,
            file_path="semantic_block",
            extra_info={
                "block_id": block.block_id,
                "has_vector": block.semantic_vector is not None,
                "keywords_count": len(block.keywords) if block.keywords else 0
            }
        )
        
        query_vector = block.semantic_vector
        if query_vector is None and block.text_description:
            processing_logger.log_step("向量生成", "语义块无向量，使用嵌入模型生成")
            query_vector = self._embedding_model.encode_single(block.text_description)
            processing_logger.log_step("向量生成", f"生成向量维度: {len(query_vector)}")
        
        query_text = block.text_description or ""
        query_keywords = block.keywords or []
        
        processing_logger.log_step("分类计算", f"开始计算与 {len(self.categories)} 个类别的相似度")
        
        all_scores = {}
        
        for category in self.categories:
            score = self._compute_fused_similarity(
                query_vector=query_vector,
                query_text=query_text,
                query_keywords=query_keywords,
                category=category
            )
            all_scores[category.name] = score
        
        sorted_categories = sorted(all_scores.items(), key=lambda x: x[1], reverse=True)
        best_category = sorted_categories[0][0]
        best_score = sorted_categories[0][1]
        
        processing_logger.log_classification(best_category, best_score, all_scores)
        
        result = ClassificationResult(
            block_id=block.block_id,
            category_name=best_category,
            confidence=best_score,
            all_scores=all_scores
        )
        
        processing_logger.log_module_output(module_name, {
            "block_id": result.block_id,
            "category": result.category_name,
            "confidence": result.confidence
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"分类完成: {best_category} (置信度: {best_score:.4f})")
        
        return result
    
    def classify_batch(self, blocks: List, db_manager=None, file_id: int = None,
                       category_system_name: str = "默认类别体系") -> List[ClassificationResult]:
        """批量分类，如果提供db_manager则自动写入分类结果表

        Args:
            blocks: 语义块列表
            db_manager: 数据库管理器
            file_id: 文件ID
            category_system_name: 类别体系名称

        Returns:
            分类结果列表
        """
        module_name = "SemanticClassification-Batch"

        from semantic_representation import SemanticBlock

        if not self._is_initialized:
            error = RuntimeError("Classification not initialized. Call initialize() first.")
            processing_logger.log_error(module_name, error)
            raise error

        # 记录批量分类开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path="batch_processing",
            extra_info={
                "total_blocks": len(blocks),
                "db_manager": "已提供" if db_manager else "未提供",
                "file_id": file_id,
                "category_system_name": category_system_name
            }
        )

        results = []
        for i, block in enumerate(blocks):
            if not isinstance(block, SemanticBlock):
                error = TypeError(f"Expected SemanticBlock, got {type(block)}")
                processing_logger.log_error(module_name, error, f"Block index: {i}")
                raise error

            processing_logger.log_step("批量分类", f"处理第 {i+1}/{len(blocks)} 个语义块")
            result = self.classify(block)
            results.append(result)

            # 写入数据库
            if db_manager and file_id:
                try:
                    processing_logger.log_step("数据库写入", f"写入分类结果 {result.block_id}")
                    db_manager.add_classification_result(
                        file_id=file_id,
                        semantic_block_id=result.block_id,
                        category_name=result.category_name,
                        category_system_name=category_system_name,
                        confidence=result.confidence,
                        all_scores=result.all_scores
                    )

                    # 写入语义块metadata
                    metadata = {category_system_name: result.all_scores}
                    db_manager.update_semantic_block_metadata(result.block_id, metadata)

                    processing_logger.log_step("数据库写入", f"成功写入分类结果 {result.block_id}")
                except Exception as e:
                    processing_logger.log_error(module_name, e, f"写入分类结果失败 {result.block_id}")

        # 记录批量分类结束
        processing_logger.log_module_output(module_name, {
            "total_processed": len(results),
            "categories": list(set(r.category_name for r in results))
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"批量分类完成，共处理 {len(results)} 个语义块")

        return results
    
    def _compute_fused_similarity(
        self,
        query_vector: Optional[np.ndarray],
        query_text: str,
        query_keywords: List[str],
        category: SemanticCategory
    ) -> float:
        vector_sim = self._compute_vector_similarity(query_vector, category)
        bm25_score = self._compute_bm25_score(query_text, category)
        keyword_sim = self._compute_keyword_similarity(query_keywords, category)
        
        fused_score = (
            self.vector_weight * vector_sim +
            self.bm25_weight * bm25_score +
            self.keyword_weight * keyword_sim
        )
        
        return fused_score
    
    def _compute_vector_similarity(self, query_vector: Optional[np.ndarray], category: SemanticCategory) -> float:
        if query_vector is None:
            return 0.0
        
        category_vector = self._category_vectors.get(category.name)
        if category_vector is None:
            return 0.0
        
        query_vec = np.asarray(query_vector).flatten()
        cat_vec = np.asarray(category_vector).flatten()
        
        norm1 = np.linalg.norm(query_vec)
        norm2 = np.linalg.norm(cat_vec)
        
        if norm1 == 0 or norm2 == 0:
            return 0.0
        
        return float(np.dot(query_vec, cat_vec) / (norm1 * norm2))
    
    def _compute_bm25_score(self, query_text: str, category: SemanticCategory) -> float:
        if not query_text:
            return 0.0
        
        try:
            import jieba
            query_tokens = list(jieba.cut(query_text))
        except ImportError:
            query_tokens = query_text.split()
        
        category_text = self._category_texts.get(category.name, "")
        if not category_text:
            return 0.0
        
        try:
            import jieba
            cat_tokens = list(jieba.cut(category_text))
        except ImportError:
            cat_tokens = category_text.split()
        
        from collections import Counter
        import math
        
        cat_term_freq = Counter(cat_tokens)
        cat_len = len(cat_tokens)
        avgdl = cat_len
        
        k1 = 1.5
        b = 0.75
        
        score = 0.0
        for term in query_tokens:
            if term in cat_term_freq:
                tf = cat_term_freq[term]
                idf = math.log(1 + 1)
                numerator = tf * (k1 + 1)
                denominator = tf + k1 * (1 - b + b * cat_len / avgdl) if avgdl > 0 else tf + k1
                score += idf * numerator / denominator
        
        if score > 0:
            score = score / (1 + score)
        
        return min(score, 1.0)
    
    def _compute_keyword_similarity(self, query_keywords: List[str], category: SemanticCategory) -> float:
        if not query_keywords or not category.keywords:
            return 0.0
        
        set1 = set(query_keywords)
        set2 = set(category.keywords)
        
        intersection = len(set1 & set2)
        union = len(set1 | set2)
        
        if union == 0:
            return 0.0
        
        return intersection / union
    
    def get_category_by_name(self, name: str) -> Optional[SemanticCategory]:
        for cat in self.categories:
            if cat.name == name:
                return cat
        return None
    
    def get_config(self) -> Dict[str, Any]:
        return {
            'similarity_weights': {
                'vector_weight': self.vector_weight,
                'bm25_weight': self.bm25_weight,
                'keyword_weight': self.keyword_weight,
                'time_weight': self.time_weight,
                'location_weight': self.location_weight
            },
            'categories': [cat.to_dict() for cat in self.categories]
        }

    def set_categories(self, category_names: List[str], category_info: Dict[str, Dict[str, Any]] = None):
        """设置自定义类别列表

        用目录结构等自定义类别替换默认类别。

        Args:
            category_names: 类别名称列表
            category_info: 可选的类别信息字典，格式为 {类别名: {"description": "描述", "keywords": ["关键词"]}}
        """
        # 清空现有类别
        self.categories = []
        self._category_names = []
        self._category_descriptions = {}
        self._category_texts = {}
        self._category_vectors = {}

        # 创建新类别
        for name in category_names:
            # 获取类别的描述和关键词
            info = category_info.get(name, {}) if category_info else {}
            description = info.get("description", f"{name}相关文件")
            keywords = info.get("keywords", [])

            category = SemanticCategory(
                name=name,
                description=description,
                keywords=keywords
            )
            self.categories.append(category)
            self._category_names.append(name)
            self._category_descriptions[name] = description

            # 预先构建 BM25 文本（如果未初始化时需要）
            bm25_text = self._build_category_text_from_object(category, self.bm25_fields)
            self._category_texts[name] = bm25_text

        # 如果已初始化，重新计算类别向量（会同时更新向量文本和 BM25 文本）
        if self._is_initialized and self._embedding_model is not None:
            self._compute_category_vectors()
            print(f"[SemanticClassification] 已更新类别体系，共 {len(self.categories)} 个类别")
            print(f"[SemanticClassification] 向量字段: {self.vector_fields}, BM25字段: {self.bm25_fields}")
        else:
            print(f"[SemanticClassification] 已设置类别列表，共 {len(self.categories)} 个类别（初始化后生效）")
