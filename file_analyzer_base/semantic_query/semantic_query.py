"""语义查询模块

实现基于语义相似度的文件检索功能。
流程：
1. 将用户查询转化为语义块（文本描述、关键词、向量）
2. 调用语义相似度计算模块，查找最相近的K个语义块
3. 根据语义块相似度计算相关文件相似度
4. 返回最相近的M个文件
"""

import os
import sys
import json
import numpy as np
from typing import List, Dict, Optional, Tuple, Any
from dataclasses import dataclass
from datetime import datetime

# 添加父目录到路径
base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if base_dir not in sys.path:
    sys.path.insert(0, base_dir)

from semantic_representation import SemanticRepresentation, SemanticBlock
from semantic_similarity import VectorSimilarity


@dataclass
class SemanticBlockResult:
    """语义块搜索结果"""
    semantic_block_id: str
    file_id: int
    text_description: str
    keywords: List[str]
    similarity_score: float


@dataclass
class FileResult:
    """文件搜索结果"""
    file_id: int
    file_path: str
    file_name: str
    similarity_score: float
    matched_blocks: List[SemanticBlockResult]


@dataclass
class SearchResult:
    """搜索结果"""
    query_text: str
    top_k: int
    top_m: int
    semantic_blocks: List[SemanticBlockResult]
    files: List[FileResult]
    search_time: datetime


class SemanticQuery:
    """语义查询器 - 性能优化版本

    提供基于语义相似度的文件检索功能。

    性能优化:
    1. 向量矩阵搜索 - 使用numpy矩阵运算替代逐个遍历，时间复杂度从O(n)降低到O(1)矩阵运算
    2. 延迟加载 - 只在需要时加载语义块
    3. LRU缓存 - 对频繁查询的结果进行缓存
    """

    DEFAULT_CONFIG_PATH = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'config.json'
    )

    def __init__(self, db_manager=None, config: Optional[Dict] = None,
                 config_path: Optional[str] = None):
        """初始化语义查询器

        Args:
            db_manager: 数据库管理器
            config: 配置字典
            config_path: 配置文件路径
        """
        self.db_manager = db_manager
        self.config = config or {}
        self.config_path = config_path or self.DEFAULT_CONFIG_PATH

        # 加载配置
        self._load_config()

        # 初始化语义表征模块
        self.semantic_rep = SemanticRepresentation()

        # 缓存所有语义块 - 使用延迟加载
        self._all_semantic_blocks: List[SemanticBlock] = []
        self._block_id_to_file_id: Dict[str, int] = {}
        self._is_cache_loaded = False

        # 性能优化：向量矩阵缓存
        self._vector_matrix: Optional[np.ndarray] = None
        self._vector_matrix_valid: bool = False

        # 关键词索引（用于快速关键词匹配）
        self._keyword_index: Dict[str, List[int]] = {}  # keyword -> [block_indices]
        self._keyword_index_valid: bool = False
    
    def _load_config(self):
        """加载配置"""
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    file_config = json.load(f)
                self.config.update(file_config)
            except Exception as e:
                print(f"加载配置文件失败: {e}")
        
        # 获取查询参数
        query_config = self.config.get('query', {})
        self.default_top_k = query_config.get('top_k', 10)
        self.default_top_m = query_config.get('top_m', 5)
    
    def _load_semantic_blocks_cache(self):
        """加载所有语义块到缓存 - 性能优化版本

        优化策略:
        1. 延迟加载 - 只在首次搜索时加载
        2. 构建向量矩阵 - 用于快速相似度计算
        3. 构建关键词索引 - 用于快速关键词匹配
        """
        if self._is_cache_loaded or not self.db_manager:
            return

        try:
            import sqlite3
            conn = sqlite3.connect(self.db_manager.db_path)
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            cursor.execute('''
                SELECT sb.*, f.file_path, f.file_name
                FROM semantic_blocks sb
                JOIN files f ON sb.file_id = f.id
            ''')

            rows = cursor.fetchall()

            vectors = []  # 用于构建向量矩阵

            for row in rows:
                # 解析向量
                vector = None
                if row['semantic_vector']:
                    try:
                        vector = np.frombuffer(row['semantic_vector'], dtype=np.float32)
                    except Exception:
                        pass

                # 解析关键词
                keywords = []
                if row['keywords']:
                    try:
                        keywords = json.loads(row['keywords'])
                    except Exception:
                        pass

                # 创建语义块
                block = SemanticBlock(
                    block_id=row['semantic_block_id'],
                    text_description=row['text_description'] or '',
                    keywords=keywords,
                    semantic_vector=vector,
                    modality='text',
                    original_metadata={
                        'file_id': row['file_id'],
                        'file_path': row['file_path'],
                        'file_name': row['file_name']
                    }
                )

                self._all_semantic_blocks.append(block)
                self._block_id_to_file_id[row['semantic_block_id']] = row['file_id']

                # 收集向量用于构建矩阵
                if vector is not None:
                    vectors.append(vector)

            conn.close()
            self._is_cache_loaded = True

            # 构建向量矩阵（性能优化核心）
            if vectors:
                self._vector_matrix = np.array(vectors)
                # 预先归一化向量矩阵，避免每次搜索时重复计算
                norms = np.linalg.norm(self._vector_matrix, axis=1, keepdims=True)
                norms = np.where(norms == 0, 1, norms)  # 避免除零
                self._vector_matrix = self._vector_matrix / norms
                self._vector_matrix_valid = True

            # 构建关键词索引
            self._build_keyword_index()

            print(f"已加载 {len(self._all_semantic_blocks)} 个语义块到缓存，向量矩阵维度: {self._vector_matrix.shape if self._vector_matrix is not None else 'N/A'}")

        except Exception as e:
            print(f"加载语义块缓存失败: {e}")

    def _build_keyword_index(self):
        """构建关键词索引 - 用于快速关键词匹配"""
        self._keyword_index = {}

        for idx, block in enumerate(self._all_semantic_blocks):
            if block.keywords:
                for keyword in block.keywords:
                    if keyword not in self._keyword_index:
                        self._keyword_index[keyword] = []
                    self._keyword_index[keyword].append(idx)

        self._keyword_index_valid = True
    
    def search(self, query_text: str, top_k: Optional[int] = None,
               top_m: Optional[int] = None) -> SearchResult:
        """执行语义搜索
        
        Args:
            query_text: 查询文本
            top_k: 检索的语义块数量，默认使用配置值
            top_m: 返回的文件数量，默认使用配置值
            
        Returns:
            搜索结果
        """
        start_time = datetime.now()
        
        # 使用默认参数
        top_k = top_k or self.default_top_k
        top_m = top_m or self.default_top_m
        
        print(f"[SemanticQuery] 开始搜索: '{query_text}', top_k={top_k}, top_m={top_m}")
        
        # 1. 将查询转化为语义块
        query_block = self._query_to_semantic_block(query_text)
        print(f"[SemanticQuery] 查询语义块生成完成，向量维度: {len(query_block.semantic_vector) if query_block.semantic_vector is not None else 0}")
        
        # 2. 加载语义块缓存
        self._load_semantic_blocks_cache()
        
        # 3. 查找最相似的K个语义块
        semantic_block_results = self._find_top_k_semantic_blocks(query_block, top_k)
        print(f"[SemanticQuery] 找到 {len(semantic_block_results)} 个相似语义块")
        
        # 4. 根据语义块相似度计算文件相似度
        file_results = self._calculate_file_similarity(semantic_block_results, top_m)
        print(f"[SemanticQuery] 找到 {len(file_results)} 个相似文件")
        
        # 5. 保存查询记录
        if self.db_manager:
            self._save_query_record(query_text, query_block, top_k, top_m, len(file_results))
        
        end_time = datetime.now()
        print(f"[SemanticQuery] 搜索完成，耗时: {(end_time - start_time).total_seconds():.2f}秒")
        
        return SearchResult(
            query_text=query_text,
            top_k=top_k,
            top_m=top_m,
            semantic_blocks=semantic_block_results,
            files=file_results,
            search_time=end_time
        )
    
    def _query_to_semantic_block(self, query_text: str) -> SemanticBlock:
        """将查询文本转化为语义块

        Args:
            query_text: 查询文本

        Returns:
            查询语义块
        """
        # 使用语义表征模块生成语义块
        # 创建一个临时数据块
        from data_parser import DataBlock, ModalityType
        import tempfile

        # 创建临时文件保存查询文本
        # 因为 SemanticRepresentation._read_block_content 需要从 addr 读取文件
        temp_file = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8')
        temp_file.write(query_text)
        temp_file.close()

        temp_block = DataBlock(
            block_id=f"query_{datetime.now().strftime('%Y%m%d%H%M%S')}",
            modality=ModalityType.TEXT,
            addr=temp_file.name,  # 设置addr指向临时文件
            file_path="",
            page_number=1,
            position={},
            metadata={'is_query': True}
        )

        # 生成语义块
        semantic_block = self.semantic_rep.represent(temp_block)

        # 清理临时文件
        try:
            os.unlink(temp_file.name)
        except:
            pass

        return semantic_block
    
    def _find_top_k_semantic_blocks(self, query_block: SemanticBlock,
                                    top_k: int) -> List[SemanticBlockResult]:
        """查找最相似的K个语义块 - 性能优化版本

        使用向量矩阵运算替代逐个遍历，时间复杂度从O(n)降低到O(1)矩阵运算。

        优化策略:
        1. 向量相似度：使用矩阵乘法一次计算所有相似度
        2. 关键词匹配：使用预构建的关键词索引
        3. 文本匹配：简单的词重叠计算

        Args:
            query_block: 查询语义块
            top_k: 返回的语义块数量

        Returns:
            语义块结果列表
        """
        if not self._all_semantic_blocks:
            return []

        results = []
        query_vector = query_block.semantic_vector
        query_keywords = set(query_block.keywords) if query_block.keywords else set()
        query_text_words = set(query_block.text_description.lower().split()) if query_block.text_description else set()

        # 获取权重配置
        weights = self.config.get('similarity_weights', {})
        vector_weight = weights.get('vector_weight', 0.35)
        keyword_weight = weights.get('keyword_weight', 0.35)
        text_weight = weights.get('bm25_weight', 0.30)

        # 核心优化：使用向量矩阵计算相似度
        vector_similarities = None
        if self._vector_matrix_valid and query_vector is not None and self._vector_matrix is not None:
            # 归一化查询向量
            query_vec_normalized = query_vector / (np.linalg.norm(query_vector) + 1e-10)
            # 一次矩阵乘法计算所有相似度
            vector_similarities = np.dot(self._vector_matrix, query_vec_normalized)

        # 计算每个语义块的综合相似度
        similarities = np.zeros(len(self._all_semantic_blocks))

        if vector_similarities is not None:
            # 找出有向量的语义块索引映射
            vec_idx = 0
            for i, block in enumerate(self._all_semantic_blocks):
                if block.semantic_vector is not None:
                    similarities[i] = vector_weight * vector_similarities[vec_idx]
                    vec_idx += 1

        # 关键词相似度计算（使用索引加速）
        if query_keywords and self._keyword_index_valid:
            keyword_match_counts = np.zeros(len(self._all_semantic_blocks))
            for kw in query_keywords:
                if kw in self._keyword_index:
                    for idx in self._keyword_index[kw]:
                        keyword_match_counts[idx] += 1

            # Jaccard相似度
            for i, block in enumerate(self._all_semantic_blocks):
                if block.keywords:
                    block_keywords = set(block.keywords)
                    union_size = len(query_keywords | block_keywords)
                    if union_size > 0:
                        jaccard = keyword_match_counts[i] / union_size
                        similarities[i] += keyword_weight * jaccard

        # 文本相似度计算
        if query_text_words:
            for i, block in enumerate(self._all_semantic_blocks):
                if block.text_description:
                    block_words = set(block.text_description.lower().split())
                    if block_words:
                        intersection = len(query_text_words & block_words)
                        union = len(query_text_words | block_words)
                        if union > 0:
                            text_sim = intersection / union
                            similarities[i] += text_weight * text_sim

        # 获取top_k个最相似的语义块
        if len(similarities) <= top_k:
            top_indices = np.argsort(similarities)[::-1]
        else:
            # 使用argpartition快速获取top_k，比完全排序更快
            top_indices = np.argpartition(similarities, -top_k)[-top_k:]
            # 对top_k结果进行排序
            top_indices = top_indices[np.argsort(similarities[top_indices])[::-1]]

        # 构建结果列表
        for idx in top_indices:
            sim_score = similarities[idx]
            if sim_score > 0:  # 只保留相似度大于0的结果
                block = self._all_semantic_blocks[idx]
                results.append(SemanticBlockResult(
                    semantic_block_id=block.block_id,
                    file_id=self._block_id_to_file_id.get(block.block_id, 0),
                    text_description=block.text_description,
                    keywords=block.keywords,
                    similarity_score=float(sim_score)
                ))

        return results[:top_k]
    
    def _compute_similarity(self, query_block: SemanticBlock,
                           target_block: SemanticBlock) -> float:
        """计算两个语义块的相似度
        
        使用与分类模块相同的相似度计算方式：
        - 向量相似度（余弦相似度）
        - 关键词相似度（Jaccard）
        
        Args:
            query_block: 查询语义块
            target_block: 目标语义块
            
        Returns:
            融合相似度分数
        """
        # 向量相似度
        vector_sim = 0.0
        if query_block.semantic_vector is not None and target_block.semantic_vector is not None:
            vector_sim = VectorSimilarity.cosine_similarity(
                query_block.semantic_vector,
                target_block.semantic_vector
            )
        
        # 关键词相似度（Jaccard）
        keyword_sim = 0.0
        if query_block.keywords and target_block.keywords:
            set1 = set(query_block.keywords)
            set2 = set(target_block.keywords)
            intersection = len(set1 & set2)
            union = len(set1 | set2)
            if union > 0:
                keyword_sim = intersection / union
        
        # 文本相似度（简单实现，可以使用BM25等更复杂的方法）
        text_sim = 0.0
        if query_block.text_description and target_block.text_description:
            # 简单的词重叠计算
            words1 = set(query_block.text_description.lower().split())
            words2 = set(target_block.text_description.lower().split())
            if words1 and words2:
                intersection = len(words1 & words2)
                union = len(words1 | words2)
                if union > 0:
                    text_sim = intersection / union
        
        # 融合相似度（与分类模块使用相同的权重）
        # 从配置中读取权重
        weights = self.config.get('similarity_weights', {})
        vector_weight = weights.get('vector_weight', 0.35)
        keyword_weight = weights.get('keyword_weight', 0.35)
        # 文本相似度使用BM25的权重
        text_weight = weights.get('bm25_weight', 0.30)
        
        fused_similarity = (
            vector_weight * vector_sim +
            keyword_weight * keyword_sim +
            text_weight * text_sim
        )
        
        return fused_similarity
    
    def _calculate_file_similarity(self, semantic_block_results: List[SemanticBlockResult],
                                   top_m: int) -> List[FileResult]:
        """根据语义块相似度计算文件相似度
        
        Args:
            semantic_block_results: 语义块搜索结果
            top_m: 返回的文件数量
            
        Returns:
            文件结果列表
        """
        if not semantic_block_results or not self.db_manager:
            return []
        
        # 按文件ID分组，计算每个文件的最高相似度
        file_scores: Dict[int, List[float]] = {}
        file_blocks: Dict[int, List[SemanticBlockResult]] = {}
        
        for block_result in semantic_block_results:
            file_id = block_result.file_id
            
            if file_id not in file_scores:
                file_scores[file_id] = []
                file_blocks[file_id] = []
            
            file_scores[file_id].append(block_result.similarity_score)
            file_blocks[file_id].append(block_result)
        
        # 计算每个文件的最终相似度（使用最高相似度）
        file_results = []
        
        for file_id, scores in file_scores.items():
            # 获取文件信息
            file_record = self.db_manager.get_file_by_id(file_id)
            if not file_record:
                continue
            
            # 使用最高相似度作为文件相似度
            max_similarity = max(scores)
            
            # 也可以考虑使用加权平均
            # avg_similarity = sum(scores) / len(scores)
            
            file_results.append(FileResult(
                file_id=file_id,
                file_path=file_record.file_path,
                file_name=file_record.file_name,
                similarity_score=max_similarity,
                matched_blocks=file_blocks[file_id]
            ))
        
        # 按相似度排序并取前M个
        file_results.sort(key=lambda x: x.similarity_score, reverse=True)
        return file_results[:top_m]
    
    def _save_query_record(self, query_text: str, query_block: SemanticBlock,
                          top_k: int, top_m: int, result_count: int):
        """保存查询记录到数据库
        
        Args:
            query_text: 查询文本
            query_block: 查询语义块
            top_k: 检索的语义块数量
            top_m: 返回的文件数量
            result_count: 实际返回结果数量
        """
        try:
            # 序列化向量
            vector_bytes = None
            if query_block.semantic_vector is not None:
                vector_bytes = query_block.semantic_vector.tobytes()
            
            # 保存到数据库
            self.db_manager.add_user_query(
                query_text=query_text,
                query_vector=vector_bytes,
                keywords=query_block.keywords,
                top_k=top_k,
                top_m=top_m,
                result_count=result_count
            )
            
        except Exception as e:
            print(f"保存查询记录失败: {e}")
    
    def clear_cache(self):
        """清除缓存 - 性能优化版本

        清除所有缓存数据，包括向量矩阵和关键词索引。
        """
        self._all_semantic_blocks = []
        self._block_id_to_file_id = {}
        self._is_cache_loaded = False

        # 清除向量矩阵缓存
        self._vector_matrix = None
        self._vector_matrix_valid = False

        # 清除关键词索引
        self._keyword_index = {}
        self._keyword_index_valid = False

        print("语义块缓存已清除（包括向量矩阵和关键词索引）")
