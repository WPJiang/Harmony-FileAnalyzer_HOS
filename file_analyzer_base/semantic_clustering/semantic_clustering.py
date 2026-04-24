from typing import List, Optional, Dict, Any, Tuple
from dataclasses import dataclass, field
import numpy as np
from enum import Enum
import sys
import os
import math
from sklearn.cluster import KMeans

_base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _base_dir not in sys.path:
    sys.path.insert(0, _base_dir)


@dataclass
class ClusterResult:
    block_id: str
    cluster_id: int
    cluster_name: str
    confidence: float
    distance_to_center: float
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'block_id': self.block_id,
            'cluster_id': self.cluster_id,
            'cluster_name': self.cluster_name,
            'confidence': self.confidence,
            'distance_to_center': self.distance_to_center
        }


@dataclass
class SemanticCategory:
    name: str
    description: str
    keywords: List[str]
    center_vector: Optional[np.ndarray] = None
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'name': self.name,
            'description': self.description,
            'keywords': self.keywords,
            'center_vector': self.center_vector.tolist() if self.center_vector is not None else None
        }


class DistanceMetric(Enum):
    EUCLIDEAN = "euclidean"
    COSINE = "cosine"
    MANHATTAN = "manhattan"


class CategorySource(Enum):
    PREDEFINED = "predefined"    # 预定义
    IMPORTED = "imported"        # 人工导入
    GENERATED = "generated"      # 随机生成


class SemanticClustering:
    DEFAULT_CATEGORIES = [
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
    
    def __init__(self, config: Optional[Dict[str, Any]] = None, db_manager=None):
        self.config = config or {}
        self.db_manager = db_manager  # 数据库管理器

        self.categories: List[SemanticCategory] = []
        self._category_vectors: List[np.ndarray] = []
        self._category_ids: List[int] = []  # 类别ID列表
        self._embedding_model = None
        self._is_initialized = False
        self._category_system_name: str = ''

        self.distance_metric = DistanceMetric(
            self.config.get('distance_metric', 'cosine')
        )

        # 增量聚类配置
        self.incremental_ratio = self.config.get('incremental_cluster_ratio', 0.1)
        self.max_incremental = self.config.get('max_incremental_clusters', 20)
        self.min_incremental = self.config.get('min_incremental_clusters', 1)

        self._init_categories()
    
    def _init_categories(self):
        custom_categories = self.config.get('categories', [])
        
        if custom_categories:
            for cat_data in custom_categories:
                self.categories.append(SemanticCategory(
                    name=cat_data['name'],
                    description=cat_data.get('description', ''),
                    keywords=cat_data.get('keywords', [])
                ))
        else:
            self.categories = self.DEFAULT_CATEGORIES.copy()
    
    def initialize(self, embedding_model=None, category_system_name: str = '默认类别体系',
               predefined_categories: List[Dict] = None):
        """初始化聚类器

        Args:
            embedding_model: 嵌入模型
            category_system_name: 类别体系名称
            predefined_categories: 预定义类别列表 [{'name': ..., 'description': ..., 'keywords': ...}]
        """
        if embedding_model:
            self._embedding_model = embedding_model
        else:
            # 复用现有的embedding model加载逻辑
            SentenceTransformerEmbedding = None

            try:
                from semantic_representation.semantic_representation import SentenceTransformerEmbedding
            except ImportError:
                try:
                    from ..semantic_representation import SentenceTransformerEmbedding
                except ImportError:
                    import importlib.util
                    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    module_path = os.path.join(base_dir, 'semantic_representation', 'semantic_representation.py')
                    if os.path.exists(module_path):
                        spec = importlib.util.spec_from_file_location('semantic_representation', module_path)
                        module = importlib.util.module_from_spec(spec)
                        spec.loader.exec_module(module)
                        SentenceTransformerEmbedding = module.SentenceTransformerEmbedding

            if SentenceTransformerEmbedding is not None:
                self._embedding_model = SentenceTransformerEmbedding()
            else:
                raise ImportError("sentence-transformers is required")

        self._category_system_name = category_system_name

        # 检查数据库是否有随机生成类别
        generated_cats = []
        if self.db_manager:
            generated_cats = self.db_manager.get_generated_categories_by_system(category_system_name)

        if generated_cats:
            # 已有随机生成类别，加载向量
            self._load_existing_categories(category_system_name, predefined_categories, generated_cats)
        else:
            # 无随机生成类别，创建增量类别
            self._create_incremental_categories(category_system_name, predefined_categories)

        self._is_initialized = True
    
    def _compute_category_centers(self):
        """计算类别中心向量（向后兼容方法）"""
        self._category_vectors = []

        for category in self.categories:
            texts = [category.description] + category.keywords
            vectors = self._embedding_model.encode(texts)
            center = np.mean(vectors, axis=0)
            category.center_vector = center
            self._category_vectors.append(center)

    def _load_existing_categories(self, category_system_name: str,
                                   predefined_categories: List[Dict],
                                   generated_categories):
        """加载已有类别（包括随机生成的）"""
        from database import SemanticCategoryRecord

        self.categories = []
        self._category_vectors = []
        self._category_ids = []

        # 加载预定义/人工导入类别
        if predefined_categories:
            for cat_data in predefined_categories:
                # 尝试从数据库加载向量
                db_cat = self._get_category_from_db(cat_data['name'], category_system_name)
                if db_cat and db_cat.semantic_vector:
                    vector = np.frombuffer(db_cat.semantic_vector, dtype=np.float32)
                    self._category_vectors.append(vector)
                    self._category_ids.append(db_cat.id)
                else:
                    # 计算向量
                    vector = self._compute_category_vector(cat_data)
                    self._category_vectors.append(vector)
                    # 存入数据库
                    if self.db_manager and db_cat:
                        self.db_manager.update_category_vector(db_cat.id, vector.astype(np.float32).tobytes())
                        self._category_ids.append(db_cat.id)
                    else:
                        self._category_ids.append(-1)

                self.categories.append(SemanticCategory(
                    name=cat_data['name'],
                    description=cat_data.get('description', ''),
                    keywords=cat_data.get('keywords', []),
                    center_vector=self._category_vectors[-1]
                ))

        # 加载随机生成类别
        for gen_cat in generated_categories:
            if gen_cat.semantic_vector:
                vector = np.frombuffer(gen_cat.semantic_vector, dtype=np.float32)
                self.categories.append(SemanticCategory(
                    name=gen_cat.category_name,
                    description=gen_cat.description or '',
                    keywords=gen_cat.keywords,
                    center_vector=vector
                ))
                self._category_vectors.append(vector)
                self._category_ids.append(gen_cat.id)

    def _create_incremental_categories(self, category_system_name: str,
                                        predefined_categories: List[Dict]):
        """创建增量类别"""
        k = len(predefined_categories) if predefined_categories else len(self.DEFAULT_CATEGORIES)

        # 计算增量簇数量 m = ceil(k * ratio), 限制在[min, max]
        m = max(self.min_incremental, min(self.max_incremental, math.ceil(k * self.incremental_ratio)))

        # 加载/计算预定义类别向量
        self.categories = []
        self._category_vectors = []
        self._category_ids = []

        cats_to_use = predefined_categories if predefined_categories else [
            {'name': c.name, 'description': c.description, 'keywords': c.keywords}
            for c in self.DEFAULT_CATEGORIES
        ]

        for cat_data in cats_to_use:
            db_cat = self._get_category_from_db(cat_data['name'], category_system_name)
            if db_cat and db_cat.semantic_vector:
                vector = np.frombuffer(db_cat.semantic_vector, dtype=np.float32)
            else:
                vector = self._compute_category_vector(cat_data)
                if self.db_manager and db_cat:
                    self.db_manager.update_category_vector(db_cat.id, vector.astype(np.float32).tobytes())

            self._category_vectors.append(vector)
            self._category_ids.append(db_cat.id if db_cat else -1)
            self.categories.append(SemanticCategory(
                name=cat_data['name'],
                description=cat_data.get('description', ''),
                keywords=cat_data.get('keywords', []),
                center_vector=vector
            ))

        # 创建m个随机增量类别
        vector_dim = self._category_vectors[0].shape[0] if self._category_vectors else 384
        for i in range(1, m + 1):
            gen_name = f"{category_system_name}_其他{i}"
            # 随机初始化向量
            random_vector = np.random.randn(vector_dim).astype(np.float32)
            random_vector = random_vector / np.linalg.norm(random_vector)  # 归一化

            # 写入数据库
            if self.db_manager:
                cat_id = self.db_manager.add_semantic_category(
                    category_name=gen_name,
                    description=f"增量类别{i}",
                    keywords=[],
                    category_system_name=category_system_name,
                    category_source='generated',
                    semantic_vector=random_vector.tobytes()
                )
                self._category_ids.append(cat_id)
            else:
                self._category_ids.append(-1)

            self.categories.append(SemanticCategory(
                name=gen_name,
                description=f"增量类别{i}",
                keywords=[],
                center_vector=random_vector
            ))
            self._category_vectors.append(random_vector)

    def _compute_category_vector(self, cat_data: Dict) -> np.ndarray:
        """计算类别中心向量"""
        texts = [cat_data.get('description', '')] + cat_data.get('keywords', [])
        vectors = self._embedding_model.encode(texts)
        center = np.mean(vectors, axis=0)
        return center.astype(np.float32)

    def _get_category_from_db(self, category_name: str, system_name: str):
        """从数据库获取类别记录"""
        if not self.db_manager:
            return None

        cats = self.db_manager.get_semantic_categories_by_system(system_name)
        for cat in cats:
            if cat.category_name == category_name:
                return cat
        return None

    def cluster_with_kmeans(self, blocks: List, update_centers: bool = False) -> List[ClusterResult]:
        """使用KMeans算法进行聚类

        Args:
            blocks: 语义块列表
            update_centers: 是否更新簇中心（可选，用于迭代优化）
        """
        from semantic_representation import SemanticBlock

        if not self._is_initialized:
            raise RuntimeError("Clustering not initialized. Call initialize() first.")

        # 收集所有向量
        vectors = []
        valid_blocks = []
        for block in blocks:
            if not isinstance(block, SemanticBlock):
                raise TypeError(f"Expected SemanticBlock, got {type(block)}")

            if block.semantic_vector is not None:
                vectors.append(block.semantic_vector)
                valid_blocks.append(block)
            elif block.text_description:
                vec = self._embedding_model.encode_single(block.text_description)
                vectors.append(vec)
                valid_blocks.append(block)

        if not vectors:
            return []

        X = np.array(vectors)
        n_clusters = len(self._category_vectors)

        # 如果样本数量小于聚类数量，使用距离匹配代替KMeans
        if len(vectors) < n_clusters:
            # 使用距离匹配
            results = []
            for block, vector in zip(valid_blocks, vectors):
                distances = []
                for j, center in enumerate(self._category_vectors):
                    dist = self._compute_distance(vector, center)
                    distances.append((j, dist))

                distances.sort(key=lambda x: x[1])
                best_idx, best_dist = distances[0]

                confidence = self._compute_confidence(distances)

                results.append(ClusterResult(
                    block_id=block.block_id,
                    cluster_id=best_idx,
                    cluster_name=self.categories[best_idx].name,
                    confidence=confidence,
                    distance_to_center=best_dist
                ))

                # 计算与所有类别的相似度并写入metadata
                if self.db_manager:
                    all_similarities = {}
                    category_names = self.get_category_names()
                    for j, (cat_name, center) in enumerate(zip(category_names, self._category_vectors)):
                        dist = self._compute_distance(vector, center)
                        # 余弦距离转换为相似度: similarity = 1 - distance
                        similarity = max(0.0, min(1.0, 1 - dist))
                        all_similarities[cat_name] = similarity

                    metadata = {self._category_system_name: all_similarities}
                    self.db_manager.update_semantic_block_metadata(block.block_id, metadata)

            # 处理无效块
            for block in blocks:
                if block not in valid_blocks:
                    results.append(ClusterResult(
                        block_id=block.block_id,
                        cluster_id=-1,
                        cluster_name="未分类",
                        confidence=0.0,
                        distance_to_center=float('inf')
                    ))

            return results

        # 初始化KMeans，使用已有类别中心作为初始中心
        initial_centers = np.array(self._category_vectors)

        kmeans = KMeans(
            n_clusters=n_clusters,
            init=initial_centers,
            n_init=1,
            max_iter=100,
            random_state=42
        )

        labels = kmeans.fit_predict(X)

        # 如果需要更新中心，将新中心写入数据库
        if update_centers and self.db_manager:
            new_centers = kmeans.cluster_centers_
            for i, center in enumerate(new_centers):
                if self._category_ids[i] > 0:
                    self.db_manager.update_category_vector(
                        self._category_ids[i],
                        center.astype(np.float32).tobytes()
                    )

        # 生成结果
        results = []
        for idx, (block, label) in enumerate(zip(valid_blocks, labels)):
            center = kmeans.cluster_centers_[label]
            vec = vectors[idx]
            dist = self._compute_distance(vec, center)
            confidence = self._compute_kmeans_confidence(X, labels, label, kmeans)

            results.append(ClusterResult(
                block_id=block.block_id,
                cluster_id=int(label),
                cluster_name=self.categories[label].name,
                confidence=confidence,
                distance_to_center=dist
            ))

            # 计算与所有类别的相似度并写入metadata
            if self.db_manager:
                all_similarities = {}
                category_names = self.get_category_names()
                for j, (cat_name, cat_center) in enumerate(zip(category_names, self._category_vectors)):
                    cat_dist = self._compute_distance(vec, cat_center)
                    similarity = max(0.0, min(1.0, 1 - cat_dist))
                    all_similarities[cat_name] = similarity

                metadata = {self._category_system_name: all_similarities}
                self.db_manager.update_semantic_block_metadata(block.block_id, metadata)

        # 处理无效块
        for block in blocks:
            if block not in valid_blocks:
                results.append(ClusterResult(
                    block_id=block.block_id,
                    cluster_id=-1,
                    cluster_name="未分类",
                    confidence=0.0,
                    distance_to_center=float('inf')
                ))

        return results

    def _compute_kmeans_confidence(self, X: np.ndarray, labels: np.ndarray,
                                    label: int, kmeans: KMeans) -> float:
        """计算KMeans聚类置信度"""
        cluster_center = kmeans.cluster_centers_[label]

        # 找到最近的其他簇中心
        other_centers = np.delete(kmeans.cluster_centers_, label, axis=0)
        if len(other_centers) == 0:
            return 1.0

        cluster_mask = labels == label
        cluster_points = X[cluster_mask]

        if len(cluster_points) == 0:
            return 0.5

        # 计算到其他簇中心的距离
        distances_to_other = np.linalg.norm(cluster_points[:, None] - other_centers[None, :], axis=2)
        min_other_dist = np.min(distances_to_other) if distances_to_other.size > 0 else float('inf')

        avg_intra_dist = np.mean(np.linalg.norm(cluster_points - cluster_center, axis=1))

        if min_other_dist == 0 or avg_intra_dist == 0:
            return 0.5

        # 置信度 = 1 - (avg_intra / min_other), 越小越好
        confidence = max(0.0, min(1.0, 1 - avg_intra_dist / min_other_dist))
        return float(confidence)
    
    def cluster(self, block) -> ClusterResult:
        from semantic_representation import SemanticBlock
        
        if not self._is_initialized:
            raise RuntimeError("Clustering not initialized. Call initialize() first.")
        
        if not isinstance(block, SemanticBlock):
            raise TypeError(f"Expected SemanticBlock, got {type(block)}")
        
        if block.semantic_vector is None:
            if block.text_description:
                vector = self._embedding_model.encode_single(block.text_description)
            else:
                raise ValueError("Block has no semantic vector or text description")
        else:
            vector = block.semantic_vector
        
        distances = []
        for i, center in enumerate(self._category_vectors):
            dist = self._compute_distance(vector, center)
            distances.append((i, dist))
        
        distances.sort(key=lambda x: x[1])
        best_idx, best_dist = distances[0]
        
        confidence = self._compute_confidence(distances)
        
        return ClusterResult(
            block_id=block.block_id,
            cluster_id=best_idx,
            cluster_name=self.categories[best_idx].name,
            confidence=confidence,
            distance_to_center=best_dist
        )
    
    def cluster_batch(self, blocks: List) -> List[ClusterResult]:
        from semantic_representation import SemanticBlock
        
        if not self._is_initialized:
            raise RuntimeError("Clustering not initialized. Call initialize() first.")
        
        results = []
        vectors = []
        
        for block in blocks:
            if not isinstance(block, SemanticBlock):
                raise TypeError(f"Expected SemanticBlock, got {type(block)}")
            
            if block.semantic_vector is not None:
                vectors.append(block.semantic_vector)
            elif block.text_description:
                vec = self._embedding_model.encode_single(block.text_description)
                vectors.append(vec)
            else:
                vectors.append(None)
        
        for i, (block, vector) in enumerate(zip(blocks, vectors)):
            if vector is None:
                results.append(ClusterResult(
                    block_id=block.block_id,
                    cluster_id=-1,
                    cluster_name="未分类",
                    confidence=0.0,
                    distance_to_center=float('inf')
                ))
                continue
            
            distances = []
            for j, center in enumerate(self._category_vectors):
                dist = self._compute_distance(vector, center)
                distances.append((j, dist))
            
            distances.sort(key=lambda x: x[1])
            best_idx, best_dist = distances[0]
            
            confidence = self._compute_confidence(distances)
            
            results.append(ClusterResult(
                block_id=block.block_id,
                cluster_id=best_idx,
                cluster_name=self.categories[best_idx].name,
                confidence=confidence,
                distance_to_center=best_dist
            ))
        
        return results
    
    def _compute_distance(self, vec1: np.ndarray, vec2: np.ndarray) -> float:
        if self.distance_metric == DistanceMetric.EUCLIDEAN:
            return float(np.linalg.norm(vec1 - vec2))
        elif self.distance_metric == DistanceMetric.COSINE:
            norm1 = np.linalg.norm(vec1)
            norm2 = np.linalg.norm(vec2)
            if norm1 == 0 or norm2 == 0:
                return 1.0
            return float(1 - np.dot(vec1, vec2) / (norm1 * norm2))
        elif self.distance_metric == DistanceMetric.MANHATTAN:
            return float(np.sum(np.abs(vec1 - vec2)))
        else:
            return float(np.linalg.norm(vec1 - vec2))
    
    def _compute_confidence(self, distances: List[Tuple[int, float]]) -> float:
        if len(distances) < 2:
            return 1.0
        
        best_dist = distances[0][1]
        second_dist = distances[1][1]
        
        if second_dist == 0:
            return 0.5
        
        ratio = best_dist / second_dist
        
        confidence = 1 - ratio
        confidence = max(0.0, min(1.0, confidence))
        
        return confidence
    
    def add_category(self, category: SemanticCategory, category_id: int = -1):
        if not self._is_initialized:
            self.categories.append(category)
            return

        if category.center_vector is None and self._embedding_model:
            texts = [category.description] + category.keywords
            vectors = self._embedding_model.encode(texts)
            category.center_vector = np.mean(vectors, axis=0)

        self.categories.append(category)
        if category.center_vector is not None:
            self._category_vectors.append(category.center_vector)
            self._category_ids.append(category_id)
    
    def remove_category(self, name: str) -> bool:
        for i, cat in enumerate(self.categories):
            if cat.name == name:
                self.categories.pop(i)
                if i < len(self._category_vectors):
                    self._category_vectors.pop(i)
                if i < len(self._category_ids):
                    self._category_ids.pop(i)
                return True
        return False
    
    def get_category_names(self) -> List[str]:
        return [cat.name for cat in self.categories]
    
    def get_category_by_name(self, name: str) -> Optional[SemanticCategory]:
        for cat in self.categories:
            if cat.name == name:
                return cat
        return None
    
    def get_cluster_distribution(self, results: List[ClusterResult]) -> Dict[str, int]:
        distribution = {}
        for result in results:
            name = result.cluster_name
            distribution[name] = distribution.get(name, 0) + 1
        return distribution
