import os
import json
import math
import re
from typing import List, Optional, Dict, Any, Tuple
from dataclasses import dataclass
import numpy as np
from collections import Counter

try:
    import jieba
    JIEBA_AVAILABLE = True
except ImportError:
    JIEBA_AVAILABLE = False


@dataclass
class SimilarityResult:
    query_id: str
    target_id: str
    vector_similarity: float
    bm25_score: float
    keyword_similarity: float
    time_similarity: float
    location_similarity: float
    fused_score: float
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'query_id': self.query_id,
            'target_id': self.target_id,
            'vector_similarity': self.vector_similarity,
            'bm25_score': self.bm25_score,
            'keyword_similarity': self.keyword_similarity,
            'time_similarity': self.time_similarity,
            'location_similarity': self.location_similarity,
            'fused_score': self.fused_score
        }


class BM25:
    def __init__(
        self, 
        k1: float = 1.5, 
        b: float = 0.75,
        epsilon: float = 0.25
    ):
        self.k1 = k1
        self.b = b
        self.epsilon = epsilon
        self.doc_freqs: Dict[str, int] = {}
        self.doc_len: List[int] = []
        self.avgdl: float = 0
        self.doc_term_freqs: List[Dict[str, int]] = []
        self.n_docs: int = 0
        self.idf: Dict[str, float] = {}
    
    def fit(self, documents: List[List[str]]):
        self.n_docs = len(documents)
        self.doc_len = [len(doc) for doc in documents]
        self.avgdl = sum(self.doc_len) / self.n_docs if self.n_docs > 0 else 0
        
        self.doc_freqs = {}
        self.doc_term_freqs = []
        
        for doc in documents:
            term_freqs = Counter(doc)
            self.doc_term_freqs.append(dict(term_freqs))
            
            for term in term_freqs:
                if term not in self.doc_freqs:
                    self.doc_freqs[term] = 0
                self.doc_freqs[term] += 1
        
        self._calc_idf()
    
    def _calc_idf(self):
        self.idf = {}
        for term, freq in self.doc_freqs.items():
            idf = math.log((self.n_docs - freq + 0.5) / (freq + 0.5) + 1)
            self.idf[term] = idf
    
    def get_score(self, query: List[str], doc_idx: int) -> float:
        if doc_idx >= len(self.doc_term_freqs):
            return 0.0
        
        score = 0.0
        doc_term_freq = self.doc_term_freqs[doc_idx]
        doc_len = self.doc_len[doc_idx]
        
        for term in query:
            if term not in doc_term_freq:
                continue
            
            tf = doc_term_freq[term]
            idf = self.idf.get(term, 0)
            
            numerator = tf * (self.k1 + 1)
            denominator = tf + self.k1 * (1 - self.b + self.b * doc_len / self.avgdl)
            score += idf * numerator / denominator
        
        return score
    
    def get_scores(self, query: List[str]) -> np.ndarray:
        scores = np.zeros(self.n_docs)
        for i in range(self.n_docs):
            scores[i] = self.get_score(query, i)
        return scores


class VectorSimilarity:
    @staticmethod
    def cosine_similarity(vec1: np.ndarray, vec2: np.ndarray) -> float:
        if vec1 is None or vec2 is None:
            return 0.0
        
        vec1 = np.asarray(vec1).flatten()
        vec2 = np.asarray(vec2).flatten()
        
        if vec1.shape != vec2.shape:
            return 0.0
        
        norm1 = np.linalg.norm(vec1)
        norm2 = np.linalg.norm(vec2)
        
        if norm1 == 0 or norm2 == 0:
            return 0.0
        
        return float(np.dot(vec1, vec2) / (norm1 * norm2))
    
    @staticmethod
    def cosine_similarity_matrix(
        query_vectors: np.ndarray, 
        target_vectors: np.ndarray
    ) -> np.ndarray:
        if query_vectors is None or target_vectors is None:
            return np.zeros((len(query_vectors) if query_vectors is not None else 0,
                           len(target_vectors) if target_vectors is not None else 0))
        
        query_vectors = np.asarray(query_vectors)
        target_vectors = np.asarray(target_vectors)
        
        if query_vectors.ndim == 1:
            query_vectors = query_vectors.reshape(1, -1)
        if target_vectors.ndim == 1:
            target_vectors = target_vectors.reshape(1, -1)
        
        query_norms = np.linalg.norm(query_vectors, axis=1, keepdims=True)
        target_norms = np.linalg.norm(target_vectors, axis=1, keepdims=True)
        
        query_norms = np.where(query_norms == 0, 1, query_norms)
        target_norms = np.where(target_norms == 0, 1, target_norms)
        
        query_normalized = query_vectors / query_norms
        target_normalized = target_vectors / target_norms
        
        return np.dot(query_normalized, target_normalized.T)


class KeywordSimilarity:
    @staticmethod
    def jaccard_similarity(keywords1: List[str], keywords2: List[str]) -> float:
        if not keywords1 or not keywords2:
            return 0.0
        
        set1 = set(keywords1)
        set2 = set(keywords2)
        
        intersection = len(set1 & set2)
        union = len(set1 | set2)
        
        if union == 0:
            return 0.0
        
        return intersection / union
    
    @staticmethod
    def overlap_coefficient(keywords1: List[str], keywords2: List[str]) -> float:
        if not keywords1 or not keywords2:
            return 0.0
        
        set1 = set(keywords1)
        set2 = set(keywords2)
        
        intersection = len(set1 & set2)
        min_size = min(len(set1), len(set2))
        
        if min_size == 0:
            return 0.0
        
        return intersection / min_size


class TimeSimilarity:
    TIME_PATTERNS = [
        r'\d{4}-\d{2}-\d{2}',
        r'\d{4}/\d{2}/\d{2}',
        r'\d{4}年\d{1,2}月\d{1,2}日',
        r'\d{1,2}月\d{1,2}日',
        r'\d{4}年',
        r'\d{4}',
    ]
    
    @staticmethod
    def extract_times(text: str) -> List[str]:
        if not text:
            return []
        
        times = []
        for pattern in TimeSimilarity.TIME_PATTERNS:
            matches = re.findall(pattern, text)
            times.extend(matches)
        
        return times
    
    @staticmethod
    def _parse_year(time_str: str) -> Optional[int]:
        year_match = re.search(r'(\d{4})', time_str)
        if year_match:
            return int(year_match.group(1))
        return None
    
    @staticmethod
    def _parse_month(time_str: str) -> Optional[int]:
        month_match = re.search(r'(\d{1,2})月', time_str)
        if month_match:
            return int(month_match.group(1))
        
        if '-' in time_str or '/' in time_str:
            parts = re.split(r'[-/]', time_str)
            if len(parts) >= 2:
                try:
                    return int(parts[1])
                except:
                    pass
        return None
    
    @staticmethod
    def _parse_day(time_str: str) -> Optional[int]:
        day_match = re.search(r'(\d{1,2})日', time_str)
        if day_match:
            return int(day_match.group(1))
        
        if '-' in time_str or '/' in time_str:
            parts = re.split(r'[-/]', time_str)
            if len(parts) >= 3:
                try:
                    return int(parts[2])
                except:
                    pass
        return None
    
    @staticmethod
    def time_similarity(times1: List[str], times2: List[str]) -> float:
        if not times1 or not times2:
            return 0.0
        
        max_sim = 0.0
        for t1 in times1:
            for t2 in times2:
                sim = TimeSimilarity._compute_time_similarity(t1, t2)
                max_sim = max(max_sim, sim)
        
        return max_sim
    
    @staticmethod
    def _compute_time_similarity(time1: str, time2: str) -> float:
        year1 = TimeSimilarity._parse_year(time1)
        year2 = TimeSimilarity._parse_year(time2)
        
        if year1 is None or year2 is None:
            return 0.0
        
        year_diff = abs(year1 - year2)
        
        if year_diff == 0:
            month1 = TimeSimilarity._parse_month(time1)
            month2 = TimeSimilarity._parse_month(time2)
            
            if month1 is not None and month2 is not None:
                if month1 == month2:
                    day1 = TimeSimilarity._parse_day(time1)
                    day2 = TimeSimilarity._parse_day(time2)
                    
                    if day1 is not None and day2 is not None:
                        if day1 == day2:
                            return 1.0
                        else:
                            return 0.8
                    return 0.9
                else:
                    month_diff = abs(month1 - month2)
                    return max(0.0, 1.0 - month_diff / 12.0)
            return 0.9
        
        if year_diff <= 1:
            return max(0.0, 1.0 - year_diff * 0.3)
        elif year_diff <= 5:
            return max(0.0, 0.7 - (year_diff - 1) * 0.1)
        else:
            return max(0.0, 0.4 - (year_diff - 5) * 0.05)


class LocationSimilarity:
    LOCATION_PATTERNS = [
        r'[\u4e00-\u9fa5]+(省|市|区|县|州|省)',
        r'[\u4e00-\u9fa5]+市',
        r'[\u4e00-\u9fa5]+县',
        r'[\u4e00-\u9fa5]+区',
        r'(北京|上海|广州|深圳|杭州|南京|武汉|成都|重庆|西安|天津|苏州|长沙|郑州|济南|青岛|沈阳|大连|厦门|宁波)',
        r'[\u4e00-\u9fa5]+路',
        r'[\u4e00-\u9fa5]+街',
        r'[\u4e00-\u9fa5]+道',
    ]
    
    COMMON_LOCATIONS = {
        '北京': '北京',
        '上海': '上海',
        '广州': '广州',
        '深圳': '深圳',
        '杭州': '杭州',
        '南京': '南京',
        '武汉': '武汉',
        '成都': '成都',
        '重庆': '重庆',
        '西安': '西安',
    }
    
    @staticmethod
    def extract_locations(text: str) -> List[str]:
        if not text:
            return []
        
        locations = []
        for pattern in LocationSimilarity.LOCATION_PATTERNS:
            matches = re.findall(pattern, text)
            locations.extend(matches)
        
        normalized = []
        for loc in locations:
            loc = loc.strip()
            if loc in LocationSimilarity.COMMON_LOCATIONS:
                normalized.append(LocationSimilarity.COMMON_LOCATIONS[loc])
            else:
                normalized.append(loc)
        
        return list(set(normalized))
    
    @staticmethod
    def location_similarity(locations1: List[str], locations2: List[str]) -> float:
        if not locations1 or not locations2:
            return 0.0
        
        set1 = set(locations1)
        set2 = set(locations2)
        
        intersection = set1 & set2
        if not intersection:
            return 0.0
        
        max_sim = 0.0
        for loc1 in set1:
            for loc2 in set2:
                sim = LocationSimilarity._compute_location_similarity(loc1, loc2)
                max_sim = max(max_sim, sim)
        
        return max_sim
    
    @staticmethod
    def _compute_location_similarity(loc1: str, loc2: str) -> float:
        if loc1 == loc2:
            return 1.0
        
        loc1_clean = loc1.replace('市', '').replace('省', '').replace('区', '').replace('县', '')
        loc2_clean = loc2.replace('市', '').replace('省', '').replace('区', '').replace('县', '')
        
        if loc1_clean == loc2_clean:
            return 0.9
        
        if loc1 in LocationSimilarity.COMMON_LOCATIONS.values() and loc2 in LocationSimilarity.COMMON_LOCATIONS.values():
            common_cities = list(LocationSimilarity.COMMON_LOCATIONS.values())
            if loc1 in common_cities and loc2 in common_cities:
                idx1 = common_cities.index(loc1)
                idx2 = common_cities.index(loc2)
                diff = abs(idx1 - idx2)
                return max(0.3, 1.0 - diff * 0.15)
        
        return 0.0


class SemanticSimilarity:
    DEFAULT_CONFIG_PATH = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'config.json'
    )
    
    def __init__(self, config: Optional[Dict[str, Any]] = None, config_path: Optional[str] = None):
        self.config = config or {}
        self.config_path = config_path or self.DEFAULT_CONFIG_PATH
        
        self.vector_weight = 0.35
        self.bm25_weight = 0.25
        self.keyword_weight = 0.25
        self.time_weight = 0.08
        self.location_weight = 0.07
        
        self._load_config_weights()
        
        fusion_config = self.config.get('fusion', {})
        if fusion_config:
            self.vector_weight = fusion_config.get('vector_weight', self.vector_weight)
            self.bm25_weight = fusion_config.get('bm25_weight', self.bm25_weight)
            self.keyword_weight = fusion_config.get('keyword_weight', self.keyword_weight)
            self.time_weight = fusion_config.get('time_weight', self.time_weight)
            self.location_weight = fusion_config.get('location_weight', self.location_weight)
        
        bm25_config = self.config.get('bm25', {})
        self.bm25 = BM25(
            k1=bm25_config.get('k1', 1.5),
            b=bm25_config.get('b', 0.75)
        )
        
        self._is_fitted = False
        self._target_blocks = []
        self._target_vectors = None
        self._target_times: Dict[str, List[str]] = {}
        self._target_locations: Dict[str, List[str]] = {}
    
    def _load_config_weights(self):
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    file_config = json.load(f)
                
                if 'similarity_weights' in file_config:
                    weights = file_config['similarity_weights']
                    self.vector_weight = weights.get('vector_weight', self.vector_weight)
                    self.bm25_weight = weights.get('bm25_weight', self.bm25_weight)
                    self.keyword_weight = weights.get('keyword_weight', self.keyword_weight)
                    self.time_weight = weights.get('time_weight', self.time_weight)
                    self.location_weight = weights.get('location_weight', self.location_weight)
            except Exception as e:
                print(f"加载配置文件权重失败: {e}")
    
    def fit(self, target_blocks: List):
        from ..semantic_representation import SemanticBlock
        
        self._target_blocks = []
        documents = []
        vectors = []
        
        for block in target_blocks:
            if isinstance(block, SemanticBlock):
                self._target_blocks.append(block)

                # 使用bm25_text字段（如果存在），否则回退到text_description
                bm25_text = getattr(block, 'bm25_text', '') or block.text_description
                if JIEBA_AVAILABLE:
                    tokens = list(jieba.cut(bm25_text))
                else:
                    tokens = bm25_text.split()
                documents.append(tokens)

                if block.semantic_vector is not None:
                    vectors.append(block.semantic_vector)

                self._target_times[block.block_id] = TimeSimilarity.extract_times(block.text_description)
                self._target_locations[block.block_id] = LocationSimilarity.extract_locations(block.text_description)
        
        self.bm25.fit(documents)
        
        if vectors:
            self._target_vectors = np.array(vectors)
        else:
            self._target_vectors = None
        
        self._is_fitted = True
    
    def compute_similarity(
        self, 
        query_block, 
        target_block
    ) -> SimilarityResult:
        from ..semantic_representation import SemanticBlock
        
        if not isinstance(query_block, SemanticBlock) or not isinstance(target_block, SemanticBlock):
            raise TypeError("Both query and target must be SemanticBlock instances")
        
        vector_sim = VectorSimilarity.cosine_similarity(
            query_block.semantic_vector,
            target_block.semantic_vector
        )
        
        if JIEBA_AVAILABLE:
            query_bm25_text = getattr(query_block, 'bm25_text', '') or query_block.text_description
            target_bm25_text = getattr(target_block, 'bm25_text', '') or target_block.text_description
            query_tokens = list(jieba.cut(query_bm25_text))
            target_tokens = list(jieba.cut(target_bm25_text))
        else:
            query_bm25_text = getattr(query_block, 'bm25_text', '') or query_block.text_description
            target_bm25_text = getattr(target_block, 'bm25_text', '') or target_block.text_description
            query_tokens = query_bm25_text.split()
            target_tokens = target_bm25_text.split()
        
        bm25_scorer = BM25()
        bm25_scorer.fit([target_tokens])
        bm25_score = bm25_scorer.get_score(query_tokens, 0)
        
        keyword_sim = KeywordSimilarity.jaccard_similarity(
            query_block.keywords,
            target_block.keywords
        )
        
        query_times = TimeSimilarity.extract_times(query_block.text_description)
        target_times = TimeSimilarity.extract_times(target_block.text_description)
        time_sim = TimeSimilarity.time_similarity(query_times, target_times)
        
        query_locations = LocationSimilarity.extract_locations(query_block.text_description)
        target_locations = LocationSimilarity.extract_locations(target_block.text_description)
        location_sim = LocationSimilarity.location_similarity(query_locations, target_locations)
        
        fused_score = self._fuse_scores(vector_sim, bm25_score, keyword_sim, time_sim, location_sim)
        
        return SimilarityResult(
            query_id=query_block.block_id,
            target_id=target_block.block_id,
            vector_similarity=vector_sim,
            bm25_score=bm25_score,
            keyword_similarity=keyword_sim,
            time_similarity=time_sim,
            location_similarity=location_sim,
            fused_score=fused_score
        )
    
    def search(
        self, 
        query_block, 
        top_k: int = 10,
        min_score: float = 0.0
    ) -> List[SimilarityResult]:
        from ..semantic_representation import SemanticBlock
        
        if not self._is_fitted:
            raise RuntimeError("Model not fitted. Call fit() first.")
        
        if not isinstance(query_block, SemanticBlock):
            raise TypeError("Query must be a SemanticBlock instance")
        
        results = []

        # 使用bm25_text字段（如果存在），否则回退到text_description
        query_bm25_text = getattr(query_block, 'bm25_text', '') or query_block.text_description
        if JIEBA_AVAILABLE:
            query_tokens = list(jieba.cut(query_bm25_text))
        else:
            query_tokens = query_bm25_text.split()
        
        bm25_scores = self.bm25.get_scores(query_tokens)
        
        if self._target_vectors is not None and query_block.semantic_vector is not None:
            query_vec = np.array(query_block.semantic_vector).reshape(1, -1)
            vector_scores = VectorSimilarity.cosine_similarity_matrix(
                query_vec, 
                self._target_vectors
            )[0]
        else:
            vector_scores = np.zeros(len(self._target_blocks))
        
        query_times = TimeSimilarity.extract_times(query_block.text_description)
        query_locations = LocationSimilarity.extract_locations(query_block.text_description)
        
        for i, target_block in enumerate(self._target_blocks):
            keyword_sim = KeywordSimilarity.jaccard_similarity(
                query_block.keywords,
                target_block.keywords
            )
            
            target_times = self._target_times.get(target_block.block_id, [])
            time_sim = TimeSimilarity.time_similarity(query_times, target_times)
            
            target_locations = self._target_locations.get(target_block.block_id, [])
            location_sim = LocationSimilarity.location_similarity(query_locations, target_locations)
            
            bm25_normalized = self._normalize_bm25(bm25_scores[i])
            
            fused_score = self._fuse_scores(
                vector_scores[i],
                bm25_normalized,
                keyword_sim,
                time_sim,
                location_sim
            )
            
            if fused_score >= min_score:
                results.append(SimilarityResult(
                    query_id=query_block.block_id,
                    target_id=target_block.block_id,
                    vector_similarity=float(vector_scores[i]),
                    bm25_score=float(bm25_scores[i]),
                    keyword_similarity=keyword_sim,
                    time_similarity=time_sim,
                    location_similarity=location_sim,
                    fused_score=fused_score
                ))
        
        results.sort(key=lambda x: x.fused_score, reverse=True)
        
        return results[:top_k]
    
    def batch_search(
        self,
        query_blocks: List,
        top_k: int = 10,
        min_score: float = 0.0
    ) -> Dict[str, List[SimilarityResult]]:
        results = {}
        for query_block in query_blocks:
            results[query_block.block_id] = self.search(
                query_block, 
                top_k=top_k,
                min_score=min_score
            )
        return results
    
    def _fuse_scores(
        self, 
        vector_sim: float, 
        bm25_score: float, 
        keyword_sim: float,
        time_sim: float,
        location_sim: float
    ) -> float:
        return (
            self.vector_weight * vector_sim +
            self.bm25_weight * bm25_score +
            self.keyword_weight * keyword_sim +
            self.time_weight * time_sim +
            self.location_weight * location_sim
        )
    
    def _normalize_bm25(self, score: float) -> float:
        return 1 - math.exp(-score / 10)
    
    def compute_similarity_matrix(
        self,
        blocks1: List,
        blocks2: List
    ) -> np.ndarray:
        from ..semantic_representation import SemanticBlock
        
        vectors1 = []
        for block in blocks1:
            if isinstance(block, SemanticBlock) and block.semantic_vector is not None:
                vectors1.append(block.semantic_vector)
        
        vectors2 = []
        for block in blocks2:
            if isinstance(block, SemanticBlock) and block.semantic_vector is not None:
                vectors2.append(block.semantic_vector)
        
        if not vectors1 or not vectors2:
            return np.zeros((len(blocks1), len(blocks2)))
        
        return VectorSimilarity.cosine_similarity_matrix(
            np.array(vectors1),
            np.array(vectors2)
        )
