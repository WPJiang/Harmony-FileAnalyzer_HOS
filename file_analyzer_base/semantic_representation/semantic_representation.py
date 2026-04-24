import re
import os
import json
from typing import List, Optional, Dict, Any, Tuple
from dataclasses import dataclass, field
import numpy as np
from abc import ABC, abstractmethod

import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from logger import processing_logger

# 尝试导入依赖
try:
    import jieba
    import jieba.analyse
    JIEBA_AVAILABLE = True
except ImportError:
    JIEBA_AVAILABLE = False

try:
    from sentence_transformers import SentenceTransformer
    SENTENCE_TRANSFORMER_AVAILABLE = True
except ImportError:
    SENTENCE_TRANSFORMER_AVAILABLE = False


class FilenameSemanticAnalyzer:
    """文件名语义分析器

    判断文件名是否包含有效的语义内容，区分于：
    - 随机字母序列（如 abcdefgh, qwertyui）
    - 随机数字序列（如 12345678, 87654321）
    - 时间戳序列（如 20231215, 1702345678）
    - UUID或哈希值（如 a1b2c3d4e5f6, 550e8400e29b）
    - 混合随机序列（如 a1b2c3d4, x7y8z9w0）
    """

    # 常见的有意义的文件名模式（中文）
    CHINESE_PATTERN = re.compile(r'[\u4e00-\u9fff]+')

    # 常见的有意义的英文单词（部分示例，实际使用时可以扩展）
    MEANINGFUL_WORDS = {
        # 文档类型
        'report', 'document', 'file', 'data', 'info', 'doc', 'docx', 'pdf', 'txt',
        'manual', 'guide', 'handbook', 'specification', 'spec', 'proposal',
        # 商务相关
        'contract', 'agreement', 'invoice', 'receipt', 'order', 'payment',
        'meeting', 'presentation', 'slides', 'proposal', 'project', 'plan',
        # 学术相关
        'paper', 'thesis', 'dissertation', 'research', 'study', 'analysis',
        'experiment', 'result', 'conclusion', 'abstract', 'summary',
        # 技术相关
        'code', 'source', 'script', 'config', 'setting', 'log', 'backup',
        'api', 'interface', 'module', 'component', 'library', 'framework',
        # 个人相关
        'resume', 'cv', 'certificate', 'diploma', 'transcript', 'photo',
        'personal', 'profile', 'application', 'letter', 'form',
        # 中文拼音（常见）
        'baogao', 'wendang', 'hetong', 'fangan', 'jihua', 'zongjie',
        'huiyi', 'peixun', 'kaoshi', 'chengji', 'zhengshu', 'jianli',
        # 其他常见
        'test', 'demo', 'sample', 'example', 'template', 'draft', 'final',
        'version', 'copy', 'original', 'new', 'old', 'backup', 'archive'
    }

    # 常见的无意义模式
    RANDOM_PATTERNS = [
        re.compile(r'^[a-f0-9]{8,}$', re.IGNORECASE),  # 十六进制哈希
        re.compile(r'^[a-z]{10,}$'),  # 连续小写字母
        re.compile(r'^[0-9]{8,}$'),  # 连续数字
        re.compile(r'^[a-z]?[0-9]+[a-z]?[0-9]+[a-z]?[0-9]+', re.IGNORECASE),  # 交替数字字母
        re.compile(r'^[a-z]{2}[0-9]{6,}', re.IGNORECASE),  # 两字母+数字
        re.compile(r'^img[_-]?\d+', re.IGNORECASE),  # img + 数字
        re.compile(r'^image[_-]?\d+', re.IGNORECASE),  # image + 数字
        re.compile(r'^file[_-]?\d+', re.IGNORECASE),  # file + 数字
        re.compile(r'^doc[_-]?\d+', re.IGNORECASE),  # doc + 数字
        re.compile(r'^scan[_-]?\d+', re.IGNORECASE),  # scan + 数字
        re.compile(r'^untitled', re.IGNORECASE),  # untitled
        re.compile(r'^new\s*document', re.IGNORECASE),  # new document
        re.compile(r'^无标题', re.IGNORECASE),  # 无标题
        re.compile(r'^新建', re.IGNORECASE),  # 新建
    ]

    # 时间戳模式
    TIMESTAMP_PATTERNS = [
        re.compile(r'^[12]\d{3}[01]\d[0-3]\d'),  # YYYYMMDD
        re.compile(r'^[12]\d{3}[-_][01]\d[-_][0-3]\d'),  # YYYY-MM-DD or YYYY_MM_DD
        re.compile(r'^[12]\d{3}[01]\d[0-3]\d[0-2]\d[0-5]\d'),  # YYYYMMDDHHmmss
        re.compile(r'^[12]\d{9}'),  # Unix timestamp (10 digits)
        re.compile(r'^[12]\d{8,9}[0-9]{2,3}'),  # Unix timestamp with ms
    ]

    def __init__(self, config: Optional[Dict[str, Any]] = None):
        self.config = config or {}
        # 最小有效字符数
        self.min_meaningful_chars = self.config.get('min_meaningful_chars', 3)
        # 中文比例阈值（超过此比例认为有意义）
        self.chinese_ratio_threshold = self.config.get('chinese_ratio_threshold', 0.3)

    def analyze(self, filename: str) -> Tuple[bool, str]:
        """分析文件名是否有语义意义

        Args:
            filename: 文件名（不含扩展名）

        Returns:
            (是否有意义, 判断原因)
        """
        if not filename or not filename.strip():
            return False, "空文件名"

        # 去除扩展名
        name = os.path.splitext(filename)[0] if '.' in filename else filename
        name = name.strip()

        if not name:
            return False, "空文件名"

        # 1. 检查是否包含中文字符
        chinese_matches = self.CHINESE_PATTERN.findall(name)
        if chinese_matches:
            chinese_chars = ''.join(chinese_matches)
            # 计算中文字符比例
            chinese_ratio = len(chinese_chars) / len(name)
            if chinese_ratio >= self.chinese_ratio_threshold:
                return True, f"包含有意义的中文内容: {''.join(chinese_matches[:3])}..."
            # 即使比例较低，但有足够的中文也可以
            if len(chinese_chars) >= self.min_meaningful_chars:
                return True, f"包含中文关键词: {''.join(chinese_matches[:3])}..."

        # 2. 检查是否有意义的英文单词
        name_lower = name.lower()
        for word in self.MEANINGFUL_WORDS:
            if word in name_lower:
                return True, f"包含有意义词汇: {word}"

        # 3. 检查是否为已知的无意义模式
        for pattern in self.RANDOM_PATTERNS:
            if pattern.match(name):
                return False, f"匹配无意义模式: {pattern.pattern}"

        # 4. 检查是否为时间戳
        for pattern in self.TIMESTAMP_PATTERNS:
            if pattern.match(name):
                return False, "时间戳格式"

        # 5. 检查随机字符序列
        # 5.1 纯数字
        if name.isdigit():
            if len(name) >= 8:
                return False, "纯数字序列（可能是ID或时间戳）"
            return True, "短数字标识"

        # 5.2 检查字符分布的随机性
        if self._is_random_sequence(name):
            return False, "随机字符序列"

        # 5.3 检查键盘序列
        if self._is_keyboard_sequence(name):
            return False, "键盘输入序列"

        # 5.4 检查连续相同字符
        if self._is_repeated_chars(name):
            return False, "重复字符序列"

        # 6. 如果通过了以上检查，认为有一定意义
        # 但需要检查是否包含足够的独特字符
        unique_chars = len(set(name.lower()))
        if unique_chars < 3 and len(name) > 5:
            return False, "字符多样性过低"

        # 7. 检查是否有分隔符分隔的有意义部分
        parts = re.split(r'[-_\s]+', name)
        meaningful_parts = [p for p in parts if len(p) >= 2 and not self._is_random_sequence(p)]
        if meaningful_parts:
            return True, "包含有意义的内容片段"

        # 默认：如果长度适中且通过了随机检测，认为有一定意义
        if 2 <= len(name) <= 50 and unique_chars >= 3:
            return True, "常规命名格式"

        return False, "无法识别的命名模式"

    def _is_random_sequence(self, s: str) -> bool:
        """判断是否为随机字符序列"""
        if len(s) < 4:
            return False

        s_lower = s.lower()

        # 检查字母和数字的交替模式
        has_letter = any(c.isalpha() for c in s_lower)
        has_digit = any(c.isdigit() for c in s_lower)

        if has_letter and has_digit:
            # 检查交替模式如 a1b2c3d4
            alternation_count = 0
            for i in range(len(s_lower) - 1):
                curr_is_letter = s_lower[i].isalpha()
                next_is_letter = s_lower[i + 1].isalpha()
                if curr_is_letter != next_is_letter:
                    alternation_count += 1

            # 如果交替次数接近字符串长度，认为是随机序列
            if alternation_count >= len(s_lower) * 0.6:
                return True

        # 检查元音辅音分布（英文单词通常有元音）
        if s_lower.isalpha() and len(s_lower) >= 4:
            vowels = set('aeiou')
            vowel_count = sum(1 for c in s_lower if c in vowels)
            vowel_ratio = vowel_count / len(s_lower)

            # 英文单词通常有20-40%的元音
            if vowel_ratio < 0.1 or vowel_ratio > 0.6:
                # 可能是随机字母
                return True

        return False

    def _is_keyboard_sequence(self, s: str) -> bool:
        """检查是否为键盘连续输入序列"""
        s_lower = s.lower()

        # 常见键盘序列
        keyboard_sequences = [
            'qwerty', 'asdfgh', 'zxcvbn', 'qwertyuiop', 'asdfghjkl',
            '123456', '098765', 'abc123', '123abc'
        ]

        for seq in keyboard_sequences:
            if seq in s_lower or s_lower in seq:
                return True

        return False

    def _is_repeated_chars(self, s: str) -> bool:
        """检查是否为重复字符"""
        if len(s) < 4:
            return False

        s_lower = s.lower()

        # 检查连续相同字符
        for i in range(len(s_lower) - 3):
            if s_lower[i] == s_lower[i + 1] == s_lower[i + 2] == s_lower[i + 3]:
                return True

        # 检查整体重复模式
        unique_chars = set(s_lower)
        if len(unique_chars) == 1:
            return True

        return False

    def get_meaningful_part(self, filename: str) -> str:
        """提取文件名中有意义的部分

        Args:
            filename: 原始文件名

        Returns:
            有意义的部分，如果全部无意义则返回空字符串
        """
        is_meaningful, reason = self.analyze(filename)
        if is_meaningful:
            return filename

        # 尝试提取有意义的部分
        name = os.path.splitext(filename)[0]
        parts = re.split(r'[-_\s.]+', name)

        meaningful_parts = []
        for part in parts:
            if part:
                is_part_meaningful, _ = self.analyze(part)
                if is_part_meaningful:
                    meaningful_parts.append(part)

        return ' '.join(meaningful_parts) if meaningful_parts else ''


@dataclass
class SemanticBlock:
    block_id: str
    text_description: str
    keywords: List[str]
    semantic_vector: Optional[np.ndarray] = None
    modality: str = "text"
    original_metadata: Dict[str, Any] = field(default_factory=dict)
    bm25_text: str = ""  # 用于BM25计算的文本，可与text_description不同

    def to_dict(self) -> Dict[str, Any]:
        return {
            'block_id': self.block_id,
            'text_description': self.text_description,
            'keywords': self.keywords,
            'semantic_vector': self.semantic_vector.tolist() if self.semantic_vector is not None else None,
            'modality': self.modality,
            'original_metadata': self.original_metadata,
            'bm25_text': self.bm25_text
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'SemanticBlock':
        vector = data.get('semantic_vector')
        if vector is not None and not isinstance(vector, np.ndarray):
            vector = np.array(vector)
        return cls(
            block_id=data['block_id'],
            text_description=data['text_description'],
            keywords=data['keywords'],
            semantic_vector=vector,
            modality=data.get('modality', 'text'),
            original_metadata=data.get('original_metadata', {})
        )


class EmbeddingModel(ABC):
    @abstractmethod
    def encode(self, texts: List[str]) -> np.ndarray:
        pass
    
    @abstractmethod
    def encode_single(self, text: str) -> np.ndarray:
        pass


class SentenceTransformerEmbedding(EmbeddingModel):
    """SentenceTransformer embedding模型

    使用全局ModelManager避免重复加载模型。
    优化效果：模型只加载一次，节省约420MB内存和3-5秒加载时间。
    """
    def __init__(self, model_name: str = 'paraphrase-multilingual-MiniLM-L12-v2'):
        self.model_name = model_name
        self._local_model_path = self._find_local_model()
        # 使用全局模型管理器
        self._use_global_manager = True
        # 回退模式下的模型实例
        self._model = None

    def _find_local_model(self):
        """查找本地模型路径"""
        import sys

        possible_paths = []

        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        possible_paths.append(os.path.join(base_dir, 'models', self.model_name))

        if getattr(sys, 'frozen', False):
            exe_dir = os.path.dirname(sys.executable)
            possible_paths.append(os.path.join(exe_dir, 'models', self.model_name))
            possible_paths.append(os.path.join(exe_dir, '_internal', 'models', self.model_name))

        for path in possible_paths:
            if os.path.exists(path) and os.path.exists(os.path.join(path, 'config.json')):
                print(f"Found local model at: {path}")
                return path

        return None

    def _get_model(self):
        """获取模型实例 - 使用全局ModelManager"""
        try:
            from models.model_manager import get_embedding_model
            return get_embedding_model(self.model_name)
        except ImportError:
            # 回退到传统方式
            return self._load_model_legacy()

    def _load_model_legacy(self):
        """传统模型加载方式（回退）"""
        if self._model is None:
            try:
                from sentence_transformers import SentenceTransformer

                if self._local_model_path:
                    print(f"Loading model from local path: {self._local_model_path}")
                    self._model = SentenceTransformer(self._local_model_path)
                else:
                    print(f"Loading model from HuggingFace Hub: {self.model_name}")
                    print("Note: First download may take a few minutes...")
                    self._model = SentenceTransformer(self.model_name)
            except ImportError:
                raise ImportError(
                    "sentence-transformers is required. "
                    "Install with: pip install sentence-transformers"
                )
        return self._model

    def encode(self, texts: List[str]) -> np.ndarray:
        """批量编码文本 - 性能优化版本

        批量编码比逐个编码快5-10倍，推荐使用此方法。
        """
        model = self._get_model()
        return model.encode(texts, convert_to_numpy=True)

    def encode_single(self, text: str) -> np.ndarray:
        """编码单个文本"""
        return self.encode([text])[0]


class Text2VecEmbedding(EmbeddingModel):
    def __init__(self, model_name: str = 'shibing624/text2vec-base-chinese'):
        self.model_name = model_name
        self._model = None
    
    def _load_model(self):
        if self._model is None:
            try:
                from text2vec import SentenceModel
                self._model = SentenceModel(self.model_name)
            except ImportError:
                raise ImportError(
                    "text2vec is required. "
                    "Install with: pip install text2vec"
                )
    
    def encode(self, texts: List[str]) -> np.ndarray:
        self._load_model()
        return self._model.encode(texts)
    
    def encode_single(self, text: str) -> np.ndarray:
        return self.encode([text])[0]


class OpenAIEmbedding(EmbeddingModel):
    def __init__(self, model_name: str = 'text-embedding-ada-002', api_key: str = None):
        self.model_name = model_name
        self.api_key = api_key
        self._client = None
    
    def _load_client(self):
        if self._client is None:
            try:
                import openai
                self._client = openai.OpenAI(api_key=self.api_key)
            except ImportError:
                raise ImportError(
                    "openai is required. "
                    "Install with: pip install openai"
                )
    
    def encode(self, texts: List[str]) -> np.ndarray:
        self._load_client()
        response = self._client.embeddings.create(
            input=texts,
            model=self.model_name
        )
        embeddings = [item.embedding for item in response.data]
        return np.array(embeddings)
    
    def encode_single(self, text: str) -> np.ndarray:
        return self.encode([text])[0]


class KeywordExtractor:
    def __init__(self, method: str = 'jieba', top_k: int = 10):
        self.method = method
        self.top_k = top_k
    
    def extract(self, text: str) -> List[str]:
        if not text or not text.strip():
            return []
        
        text = self._clean_text(text)
        
        if JIEBA_AVAILABLE:
            if self.method == 'jieba':
                return self._extract_with_jieba(text)
            elif self.method == 'tfidf':
                return self._extract_with_tfidf(text)
            elif self.method == 'textrank':
                return self._extract_with_textrank(text)
            else:
                return self._extract_with_jieba(text)
        else:
            # 当jieba不可用时，使用简单的基于频率的关键词提取
            print("WARNING: jieba is not installed. Using simple keyword extraction.")
            return self._extract_with_frequency(text)
    
    def _clean_text(self, text: str) -> str:
        text = re.sub(r'[^\w\s\u4e00-\u9fff]', ' ', text)
        text = re.sub(r'\s+', ' ', text)
        return text.strip()
    
    def _extract_with_jieba(self, text: str) -> List[str]:
        keywords = jieba.analyse.extract_tags(text, topK=self.top_k)
        return keywords
    
    def _extract_with_tfidf(self, text: str) -> List[str]:
        keywords = jieba.analyse.extract_tags(
            text, 
            topK=self.top_k,
            withWeight=False
        )
        return keywords
    
    def _extract_with_textrank(self, text: str) -> List[str]:
        keywords = jieba.analyse.textrank(
            text, 
            topK=self.top_k,
            withWeight=False
        )
        return keywords
    
    def _extract_with_frequency(self, text: str) -> List[str]:
        # 简单的基于频率的关键词提取
        words = text.split()
        word_freq = {}
        for word in words:
            if len(word) > 1:  # 过滤单字
                word_freq[word] = word_freq.get(word, 0) + 1
        
        # 按频率排序并返回前top_k个
        sorted_words = sorted(word_freq.items(), key=lambda x: x[1], reverse=True)
        return [word for word, _ in sorted_words[:self.top_k]]


class TextDescriptionGenerator:
    def __init__(self, max_length: int = 512):
        self.max_length = max_length
    
    def generate(self, text: str, modality: str = 'text') -> str:
        if not text or not text.strip():
            return ""
        
        text = self._clean_text(text)
        
        if len(text) <= self.max_length:
            return text
        
        return self._summarize(text)
    
    def _clean_text(self, text: str) -> str:
        text = re.sub(r'\s+', ' ', text)
        text = text.strip()
        return text
    
    def _summarize(self, text: str) -> str:
        sentences = re.split(r'[。！？.!?]', text)
        sentences = [s.strip() for s in sentences if s.strip()]
        
        if not sentences:
            return text[:self.max_length]
        
        result = sentences[0]
        for sentence in sentences[1:]:
            if len(result) + len(sentence) + 1 <= self.max_length:
                result += '。' + sentence
            else:
                break
        
        return result


class ImageTextExtractor:
    """图片文本提取器 - 支持OCR和基础描述

    使用全局ModelManager避免重复加载OCR模型。
    优化效果：OCR模型只加载一次，节省约100-200MB内存和2-3秒加载时间。
    """

    def __init__(self, use_ocr: bool = True, ocr_model: str = 'paddleocr'):
        self.use_ocr = use_ocr
        self.ocr_model = ocr_model
        # 使用全局模型管理器，不再单独维护实例

    def extract(self, image_path: str, source_file_path: str = None) -> str:
        """提取图片文本

        格式: [文件名]\nOCR识别的文本内容

        Args:
            image_path: 图片文件路径
            source_file_path: 源文件路径（对于PDF渲染的图片，使用原始PDF文件名）

        Returns:
            提取的文本内容（包含文件标题和OCR文本）
        """
        # 优先使用源文件名（对于PDF渲染的图片），否则使用图片文件名
        if source_file_path:
            filename = os.path.basename(source_file_path)
        else:
            filename = os.path.basename(image_path)
        base_description = f"[{filename}]"

        print(f"[ImageTextExtractor] 处理图片: {filename}")
        print(f"[ImageTextExtractor] use_ocr: {self.use_ocr}")

        if not self.use_ocr:
            print(f"[ImageTextExtractor] OCR已禁用，返回基础描述")
            return base_description

        if not os.path.exists(image_path):
            print(f"[ImageTextExtractor] 图片文件不存在: {image_path}")
            return base_description

        # 检查文件类型，跳过非图片文件（如PDF中的图片引用）
        valid_image_extensions = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp'}
        file_ext = os.path.splitext(image_path.lower())[1]
        if file_ext not in valid_image_extensions:
            print(f"[ImageTextExtractor] 跳过非图片文件: {filename} (类型: {file_ext})")
            return base_description

        # 使用全局OCR实例
        print(f"[ImageTextExtractor] 开始OCR识别...")
        ocr_func = self._get_ocr_engine()

        if ocr_func is None:
            print(f"[ImageTextExtractor] OCR引擎不可用，返回基础描述")
            return base_description

        try:
            ocr_text = ocr_func(image_path)
            print(f"[ImageTextExtractor] OCR结果长度: {len(ocr_text) if ocr_text else 0}")

            if ocr_text and ocr_text.strip():
                # 拼接基础描述和OCR文本
                result = f"{ocr_text.strip()}"
                print(f"[ImageTextExtractor] OCR识别成功，返回纯OCR")
                return result
        except Exception as e:
            print(f"[ImageTextExtractor] OCR识别失败: {e}")

        # OCR未识别到文本或失败，返回基础描述
        print(f"[ImageTextExtractor] OCR未识别到文本，返回基础描述")
        return base_description

    def _get_ocr_engine(self):
        """获取OCR引擎 - 使用全局ModelManager单例模式

        内存优化：ModelManager会在每次OCR调用后自动清理内部张量，
        显著减少内存累积（约80%）。
        """
        from models.model_manager import get_ocr_instance
        return get_ocr_instance(self.use_ocr)


class SemanticRepresentation:
    def __init__(self, config: Optional[Dict[str, Any]] = None):
        self.config = config or {}

        embedding_config = self.config.get('embedding', {})
        self.embedding_model = self._init_embedding_model(embedding_config)

        keyword_config = self.config.get('keyword', {})
        self.keyword_extractor = KeywordExtractor(
            method=keyword_config.get('method', 'jieba'),
            top_k=keyword_config.get('top_k', 10)
        )

        description_config = self.config.get('description', {})
        self.description_generator = TextDescriptionGenerator(
            max_length=description_config.get('max_length', 512)
        )

        # 图片文本提取器配置
        image_config = self.config.get('image', {})
        self.image_extractor = ImageTextExtractor(
            use_ocr=image_config.get('use_ocr', True),
            ocr_model=image_config.get('ocr_model', 'paddleocr')
        )

        # 语义文本拼接字段配置
        semantic_text_fields = self.config.get('semantic_text_fields', {})
        self.vector_fields = semantic_text_fields.get('vector', ['semantic_filename', 'text_description'])
        self.bm25_fields = semantic_text_fields.get('bm25', ['semantic_filename', 'text_description'])

    def _build_text_from_fields(self, fields: List[str], semantic_filename: str = None,
                                 text_description: str = None, keywords: List[str] = None) -> str:
        """根据配置的字段列表拼接文本

        Args:
            fields: 要拼接的字段列表，如 ['semantic_filename', 'text_description', 'keywords']
            semantic_filename: 语义文件名
            text_description: 文本描述
            keywords: 关键词列表

        Returns:
            拼接后的文本
        """
        parts = []
        for field in fields:
            if field == 'semantic_filename' and semantic_filename:
                parts.append(semantic_filename)
            elif field == 'text_description' and text_description:
                parts.append(text_description)
            elif field == 'keywords' and keywords:
                # keywords展开为空格分隔的字符串
                parts.append(' '.join(keywords))
        return ' '.join(parts) if parts else ''

    def _get_semantic_filename(self, db_manager, file_id: int) -> str:
        """从数据库获取文件的语义文件名

        Args:
            db_manager: 数据库管理器
            file_id: 文件ID

        Returns:
            语义文件名，如果没有则返回空字符串
        """
        if not db_manager or not file_id:
            return ''

        try:
            file_record = db_manager.get_file_by_id(file_id)
            if file_record and hasattr(file_record, 'semantic_filename') and file_record.semantic_filename:
                return file_record.semantic_filename
        except Exception as e:
            print(f"[SemanticRepresentation] 获取语义文件名失败: {e}")

        return ''
    
    def _init_embedding_model(self, config: Dict[str, Any]) -> Optional[EmbeddingModel]:
        model_type = config.get('type', 'sentence_transformer')
        model_name = config.get('model_name')
        
        if model_type == 'sentence_transformer':
            if not SENTENCE_TRANSFORMER_AVAILABLE:
                print("WARNING: sentence-transformers is not installed. Semantic vectors will not be generated.")
                return None
            default_name = 'paraphrase-multilingual-MiniLM-L12-v2'
            return SentenceTransformerEmbedding(model_name or default_name)
        elif model_type == 'text2vec':
            try:
                from text2vec import SentenceModel
                default_name = 'shibing624/text2vec-base-chinese'
                return Text2VecEmbedding(model_name or default_name)
            except ImportError:
                print("WARNING: text2vec is not installed. Semantic vectors will not be generated.")
                return None
        elif model_type == 'openai':
            api_key = config.get('api_key')
            if not api_key:
                print("WARNING: OpenAI API key not provided. Semantic vectors will not be generated.")
                return None
            default_name = 'text-embedding-ada-002'
            return OpenAIEmbedding(
                model_name=model_name or default_name,
                api_key=api_key
            )
        
        return None

    def _read_block_content(self, block) -> str:
        """从数据块的addr读取内容

        Args:
            block: 数据块对象

        Returns:
            文本内容
        """
        # 检查是否有addr字段
        if not hasattr(block, 'addr') or not block.addr:
            return ""

        # 检查addr是否为有效的文件路径
        if not os.path.exists(block.addr):
            return ""

        try:
            # 根据模态类型读取内容
            modality = str(block.modality) if hasattr(block, 'modality') else 'text'

            if 'IMAGE' in modality:
                # 图片类型：addr指向图片文件，需要OCR处理
                # 图片处理在represent方法中单独处理
                return ""
            else:
                # 文本/表格类型：直接读取文本内容
                with open(block.addr, 'r', encoding='utf-8') as f:
                    return f.read()
        except Exception as e:
            print(f"[SemanticRepresentation] 读取数据块内容失败: {e}")
            return ""

    def represent(self, block, db_manager=None, data_block_id: int = None, file_id: int = None) -> SemanticBlock:
        """生成语义表征，如果提供db_manager则自动写入语义块表

        流程简化:
        1. 从数据块提取文本内容
        2. 生成text_description
        3. 提取关键词
        4. 从数据库获取semantic_filename
        5. 根据配置拼接向量文本和BM25文本
        6. 生成语义向量
        """
        module_name = "SemanticRepresentation"

        try:
            from data_parser import DataBlock
        except ImportError:
            from ..data_parser import DataBlock

        if not isinstance(block, DataBlock):
            error = TypeError(f"Expected DataBlock, got {type(block)}")
            processing_logger.log_error(module_name, error)
            raise error

        # 记录模块开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path=block.file_path if hasattr(block, 'file_path') else "unknown",
            extra_info={
                "block_id": block.block_id,
                "modality": str(block.modality),
                "db_manager": "已提供" if db_manager else "未提供",
                "data_block_id": data_block_id,
                "file_id": file_id
            }
        )

        # 判断是否为图片类型
        is_image = 'IMAGE' in str(block.modality)
        modality_str = str(block.modality)

        processing_logger.log_step("类型判断", f"is_image={is_image}, modality={modality_str}")

        # 判断图片来源：是否为图片文件（而非PDF/PPT/Word中的图片）
        is_image_file = False
        if is_image and hasattr(block, 'metadata') and block.metadata:
            # metadata 可能是字符串（JSON）或字典
            metadata = block.metadata
            if isinstance(metadata, str):
                try:
                    metadata = json.loads(metadata)
                except (json.JSONDecodeError, TypeError):
                    metadata = {}
            if isinstance(metadata, dict):
                source = metadata.get('source', '')
                is_image_file = source == 'image_parser'
                processing_logger.log_step("图片来源判断", f"source={source}, is_image_file={is_image_file}")

        # 获取图片文本提取方式配置
        image_extraction_method = self.config.get('image_processing', {}).get('image_text_extraction_method', 'caption')
        processing_logger.log_step("配置读取", f"image_text_extraction_method={image_extraction_method}")

        # 确定图片路径：使用addr字段（指向图片文件路径）
        image_path = None
        if is_image:
            # 检查addr字段是否为有效的图片文件路径
            if hasattr(block, 'addr') and block.addr and isinstance(block.addr, str):
                if os.path.exists(block.addr):
                    image_path = block.addr
                    processing_logger.log_step("图片路径", f"使用addr字段路径: {image_path}")
                else:
                    processing_logger.log_step("图片路径", f"addr字段路径不存在: {block.addr}")

            # 如果addr不是有效路径，检查file_path作为备选
            if image_path is None and block.file_path and os.path.exists(block.file_path):
                image_path = block.file_path
                processing_logger.log_step("图片路径", f"使用file_path字段路径作为备选: {image_path}")

        # 初始化caption结果
        caption_result = None

        # 第一步：提取文本内容
        if is_image and image_path:
            # 判断是否使用caption模式
            use_caption = is_image_file and image_extraction_method == 'caption'
            processing_logger.log_step("文本提取方式", f"use_caption={use_caption} (is_image_file={is_image_file}, method={image_extraction_method})")

            if use_caption:
                # 使用Caption模式：先检查metadata是否已有caption和tags
                existing_caption = None
                existing_tags = None

                if db_manager and file_id:
                    try:
                        file_record = db_manager.get_file_by_id(file_id)
                        if file_record and file_record.metadata:
                            # metadata是字典，从中读取caption和tags
                            existing_metadata = file_record.metadata
                            existing_caption = existing_metadata.get('caption')
                            existing_tags = existing_metadata.get('tags')
                            processing_logger.log_step("检查已有Caption", f"caption存在: {bool(existing_caption)}, tags存在: {bool(existing_tags)}")
                    except Exception as e:
                        processing_logger.log_step("检查已有Caption", f"查询失败: {e}")

                if existing_caption or existing_tags:
                    # 已有caption或tags，直接使用
                    caption_result = {
                        'caption': existing_caption or '',
                        'tags': existing_tags or []
                    }
                    text_content = caption_result['caption']
                    processing_logger.log_step("使用已有Caption", f"caption长度: {len(text_content)}, tags数量: {len(caption_result['tags'])}")
                else:
                    # 没有已有数据，调用模型生成
                    processing_logger.log_step("文本提取", "使用ImageCaptionTagger生成图片描述和标签")
                    try:
                        from semantic_representation.image_caption_tagger import ImageCaptionTagger
                        caption_tagger = ImageCaptionTagger()
                        caption_result = caption_tagger.generate_caption_and_tags(image_path)

                        if caption_result:
                            text_content = caption_result.get('caption', '')
                            tags = caption_result.get('tags', [])
                            processing_logger.log_step("Caption生成完成", f"caption长度: {len(text_content)}, tags数量: {len(tags)}")

                            # 保存到数据库metadata字段
                            if db_manager and file_id:
                                from database import CaptionAnalysisStatus
                                # 判断是否有有效信息
                                has_info = bool(text_content or tags)
                                status = CaptionAnalysisStatus.ANALYZED_HAS_INFO if has_info else CaptionAnalysisStatus.ANALYZED_FAILED

                                # 更新caption_analysis_status
                                db_manager.update_caption_status(file_id, status)

                                # 获取当前metadata并更新
                                current_file_record = db_manager.get_file_by_id(file_id)
                                existing_metadata = current_file_record.metadata if current_file_record and current_file_record.metadata else {}
                                existing_metadata['caption'] = text_content
                                existing_metadata['tags'] = tags
                                db_manager.update_file_metadata(file_id, existing_metadata)
                                processing_logger.log_step("保存Caption", f"已保存到metadata，状态: {status}")
                        else:
                            # caption失败，降级到OCR
                            processing_logger.log_step("Caption失败", "降级使用OCR")
                            text_content = self.image_extractor.extract(image_path, source_file_path=block.file_path)
                            caption_result = None
                    except Exception as e:
                        processing_logger.log_step("Caption异常", f"异常: {e}，降级使用OCR")
                        text_content = self.image_extractor.extract(image_path, source_file_path=block.file_path)
                        caption_result = None
            else:
                # 使用OCR模式（其他文件中的图片，或配置为OCR模式的图片文件）
                processing_logger.log_step("文本提取", "使用ImageTextExtractor提取图片文本(OCR)")
                text_content = self.image_extractor.extract(image_path, source_file_path=block.file_path)

            processing_logger.log_step("文本提取完成", f"提取文本长度: {len(text_content)}")
        else:
            # 其他类型：从addr读取文本内容
            processing_logger.log_step("文本提取", "从addr读取文本内容")
            text_content = self._read_block_content(block)
            processing_logger.log_step("文本提取完成", f"读取文本长度: {len(text_content)}")

        # 第二步：生成文本描述
        processing_logger.log_step("生成描述", "使用TextDescriptionGenerator")
        text_description = self.description_generator.generate(
            text_content,
            modality=block.modality.value
        )
        processing_logger.log_step("描述生成完成", f"描述长度: {len(text_description)}")

        # 第三步：提取关键词
        # 如果有caption结果且包含tags，优先使用tags作为关键词
        if caption_result and caption_result.get('tags'):
            keywords = caption_result['tags']
            processing_logger.log_step("关键词提取", "使用Caption生成的标签作为关键词")
        else:
            processing_logger.log_step("提取关键词", "使用KeywordExtractor")
            keywords = self.keyword_extractor.extract(text_description)
        processing_logger.log_step("关键词提取完成", f"关键词数量: {len(keywords)}", {"keywords": keywords[:10]})

        # 第四步：获取语义文件名
        semantic_filename = self._get_semantic_filename(db_manager, file_id)
        if semantic_filename:
            processing_logger.log_step("语义文件名", f"获取到: {semantic_filename}")
        else:
            processing_logger.log_step("语义文件名", "未获取到")

        # 第五步：根据配置拼接向量文本和BM25文本
        text_for_vector = self._build_text_from_fields(
            self.vector_fields,
            semantic_filename=semantic_filename,
            text_description=text_description,
            keywords=keywords
        )
        text_for_bm25 = self._build_text_from_fields(
            self.bm25_fields,
            semantic_filename=semantic_filename,
            text_description=text_description,
            keywords=keywords
        )

        processing_logger.log_step("文本拼接", f"向量文本长度: {len(text_for_vector)}, BM25文本长度: {len(text_for_bm25)}")

        # 第六步：生成语义向量
        semantic_vector = None
        if self.embedding_model and text_for_vector:
            try:
                processing_logger.log_step("生成向量", f"使用嵌入模型: {type(self.embedding_model).__name__}")
                semantic_vector = self.embedding_model.encode_single(text_for_vector)
                processing_logger.log_step("向量生成完成", f"向量维度: {len(semantic_vector)}")
            except Exception as e:
                processing_logger.log_error(module_name, e, "生成语义向量失败")
        else:
            processing_logger.log_step("生成向量", "跳过（无嵌入模型或文本）")

        semantic_block = SemanticBlock(
            block_id=block.block_id,
            text_description=text_description,
            keywords=keywords,
            semantic_vector=semantic_vector,
            modality=block.modality.value,
            original_metadata=block.metadata,
            bm25_text=text_for_bm25
        )

        # 记录语义块信息
        processing_logger.log_semantic_block(
            block_id=semantic_block.block_id,
            text_description=semantic_block.text_description,
            keywords=semantic_block.keywords,
            vector_dim=len(semantic_block.semantic_vector) if semantic_block.semantic_vector is not None else 0
        )

        # 写入数据库
        if db_manager and data_block_id and file_id:
            try:
                processing_logger.log_step("数据库写入", f"写入语义块 {semantic_block.block_id}")
                vector_bytes = semantic_vector.tobytes() if semantic_vector is not None else None
                # 单个数据块处理时，传入包含单个ID的列表
                db_manager.add_semantic_block(
                    semantic_block_id=semantic_block.block_id,
                    data_block_ids=[data_block_id],  # 传入列表
                    file_id=file_id,
                    text_description=semantic_block.text_description,
                    keywords=semantic_block.keywords,
                    semantic_vector=vector_bytes,
                    semantic_filename=semantic_filename
                )
                processing_logger.log_step("数据库写入", f"成功写入语义块 {semantic_block.block_id}")
            except Exception as e:
                processing_logger.log_error(module_name, e, f"写入语义块失败 {semantic_block.block_id}")

        # 记录模块输出和结束
        processing_logger.log_module_output(module_name, {
            "semantic_block_id": semantic_block.block_id,
            "text_description_length": len(semantic_block.text_description),
            "keywords_count": len(semantic_block.keywords),
            "has_vector": semantic_block.semantic_vector is not None,
            "semantic_filename": semantic_filename
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"成功生成语义表征")

        # 方案A：清理不再需要的二进制数据，释放内存
        # 对于IMAGE类型的数据块，OCR完成后不再需要原始图片二进制数据
        if is_image and hasattr(block, 'content') and block.content is not None:
            if isinstance(block.content, bytes):
                original_size = len(block.content)
                block.content = None
                processing_logger.log_step("内存优化", f"释放图片二进制数据，大小: {original_size} bytes")
            # 如果content是字符串路径（page_render模式），保留路径供后续使用

        return semantic_block
    
    def represent_batch(self, blocks: List, db_manager=None, file_id: int = None) -> List[SemanticBlock]:
        """批量生成语义表征 - 性能优化版本

        优化策略:
        1. 批量生成文本描述（避免循环中创建对象）
        2. 批量向量编码（比逐个编码快5-10倍）
        3. 批量数据库写入
        4. 使用semantic_filename替代实时文件名分析

        Args:
            blocks: 数据块列表
            db_manager: 数据库管理器（可选）
            file_id: 文件ID（可选）

        Returns:
            语义块列表
        """
        try:
            from data_parser import DataBlock
        except ImportError:
            from ..data_parser import DataBlock

        if not blocks:
            return []

        module_name = "SemanticRepresentation-Batch"

        # 记录批量处理开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path="batch_processing",
            extra_info={
                "total_blocks": len(blocks),
                "db_manager": "已提供" if db_manager else "未提供",
                "file_id": file_id
            }
        )

        semantic_blocks = []
        text_contents = []  # 原始文本内容
        valid_block_indices = []

        # 第一步：收集所有文本内容
        for i, block in enumerate(blocks):
            if not isinstance(block, DataBlock):
                processing_logger.log_error(module_name,
                    TypeError(f"Expected DataBlock, got {type(block)}"),
                    f"Block index: {i}")
                continue

            # 判断是否为图片类型
            is_image = 'IMAGE' in str(block.modality)

            # 确定图片路径：使用addr字段
            image_path = None
            if is_image:
                if hasattr(block, 'addr') and block.addr and isinstance(block.addr, str):
                    if os.path.exists(block.addr):
                        image_path = block.addr
                if image_path is None and block.file_path and os.path.exists(block.file_path):
                    image_path = block.file_path

            if is_image and image_path:
                text_content = self.image_extractor.extract(image_path, source_file_path=block.file_path)
                text_contents.append(text_content)
            else:
                # 其他类型：从addr读取文本内容
                text_content = self._read_block_content(block)
                text_contents.append(text_content)

            valid_block_indices.append(i)

        if not text_contents:
            return []

        # 第二步：批量生成文本描述
        processing_logger.log_step("批量描述生成", f"处理 {len(text_contents)} 个文本块")
        text_descriptions = [
            self.description_generator.generate(text, modality=blocks[idx].modality.value)
            for idx, text in zip(valid_block_indices, text_contents)
        ]

        # 第三步：批量提取关键词
        processing_logger.log_step("批量关键词提取", f"提取 {len(text_contents)} 个文本块的关键词")
        keywords_list = [
            self.keyword_extractor.extract(text)
            for text in text_descriptions
        ]

        # 第四步：获取语义文件名
        semantic_filename = self._get_semantic_filename(db_manager, file_id)
        if semantic_filename:
            processing_logger.log_step("语义文件名", f"获取到: {semantic_filename}")
        else:
            processing_logger.log_step("语义文件名", "未获取到")

        # 第五步：根据配置拼接向量文本和BM25文本
        texts_for_vector = []
        texts_for_bm25 = []
        for idx, text_desc, keywords in zip(valid_block_indices, text_descriptions, keywords_list):
            text_for_vector = self._build_text_from_fields(
                self.vector_fields,
                semantic_filename=semantic_filename,
                text_description=text_desc,
                keywords=keywords
            )
            text_for_bm25 = self._build_text_from_fields(
                self.bm25_fields,
                semantic_filename=semantic_filename,
                text_description=text_desc,
                keywords=keywords
            )
            texts_for_vector.append(text_for_vector)
            texts_for_bm25.append(text_for_bm25)

        processing_logger.log_step("文本拼接", f"向量文本数量: {len(texts_for_vector)}, BM25文本数量: {len(texts_for_bm25)}")

        # 第六步：批量生成语义向量（核心优化点）
        semantic_vectors = {}
        if self.embedding_model:
            valid_texts = [(idx, text) for idx, text in zip(valid_block_indices, texts_for_vector) if text]
            if valid_texts:
                try:
                    processing_logger.log_step("批量向量编码", f"编码 {len(valid_texts)} 个文本")
                    # 批量编码 - 比逐个编码快5-10倍
                    texts_to_encode = [t[1] for t in valid_texts]
                    vectors = self.embedding_model.encode(texts_to_encode)

                    for vec_idx, (block_idx, _) in enumerate(valid_texts):
                        semantic_vectors[block_idx] = vectors[vec_idx]

                    processing_logger.log_step("批量向量编码", f"完成，向量维度: {vectors.shape[1] if len(vectors) > 0 else 0}")
                except Exception as e:
                    processing_logger.log_error(module_name, e, "批量向量编码失败")

        # 第七步：创建语义块
        processing_logger.log_step("创建语义块", f"创建 {len(valid_block_indices)} 个语义块")
        for vec_idx, block_idx in enumerate(valid_block_indices):
            block = blocks[block_idx]
            vector = semantic_vectors.get(block_idx)

            semantic_blocks.append(SemanticBlock(
                block_id=block.block_id,
                text_description=text_descriptions[vec_idx],
                keywords=keywords_list[vec_idx],
                semantic_vector=vector,
                modality=block.modality.value,
                original_metadata=block.metadata,
                bm25_text=texts_for_bm25[vec_idx]
            ))

        # 第八步：批量写入数据库
        if db_manager and file_id and semantic_blocks:
            try:
                processing_logger.log_step("批量数据库写入", f"写入 {len(semantic_blocks)} 个语义块")
                # 收集所有语义块数据
                block_data_list = []
                for sb in semantic_blocks:
                    vector_bytes = sb.semantic_vector.tobytes() if sb.semantic_vector is not None else None
                    block_data_list.append({
                        'semantic_block_id': sb.block_id,
                        'data_block_ids': [],  # 需要从数据库获取
                        'file_id': file_id,
                        'text_description': sb.text_description,
                        'keywords': sb.keywords,
                        'semantic_vector': vector_bytes,
                        'semantic_filename': semantic_filename
                    })

                # 使用批量写入API（如果可用）
                if hasattr(db_manager, 'add_semantic_blocks_batch'):
                    db_manager.add_semantic_blocks_batch(block_data_list)
                else:
                    # 回退到逐个写入
                    for sb in semantic_blocks:
                        vector_bytes = sb.semantic_vector.tobytes() if sb.semantic_vector is not None else None
                        db_manager.add_semantic_block(
                            semantic_block_id=sb.block_id,
                            data_block_ids=[],
                            file_id=file_id,
                            text_description=sb.text_description,
                            keywords=sb.keywords,
                            semantic_vector=vector_bytes,
                            semantic_filename=semantic_filename
                        )

                processing_logger.log_step("批量数据库写入", "完成")
            except Exception as e:
                processing_logger.log_error(module_name, e, "批量数据库写入失败")

        # 记录处理完成
        processing_logger.log_module_output(module_name, {
            "total_processed": len(semantic_blocks),
            "has_vectors": len(semantic_vectors)
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"批量语义表征完成，处理 {len(semantic_blocks)} 个块")

        # 方案A：批量清理不再需要的二进制数据
        total_freed = 0
        for block in blocks:
            if hasattr(block, 'modality') and 'IMAGE' in str(block.modality):
                if hasattr(block, 'content') and block.content is not None:
                    if isinstance(block.content, bytes):
                        total_freed += len(block.content)
                        block.content = None
                    # 如果content是字符串路径（page_render模式），保留路径
        if total_freed > 0:
            processing_logger.log_step("内存优化", f"批量释放图片二进制数据，总计: {total_freed} bytes")

        return semantic_blocks
    
    def encode_text(self, text: str) -> Optional[np.ndarray]:
        if not self.embedding_model:
            return None
        return self.embedding_model.encode_single(text)
    
    def represent_text(self, text: str, modality: str = 'text', block_id: Optional[str] = None) -> SemanticBlock:
        import uuid
        
        if not block_id:
            block_id = str(uuid.uuid4())
        
        text_description = self.description_generator.generate(
            text,
            modality=modality
        )
        
        keywords = self.keyword_extractor.extract(text)
        
        semantic_vector = None
        if self.embedding_model and text_description:
            try:
                semantic_vector = self.embedding_model.encode_single(text_description)
            except Exception as e:
                print(f"Failed to generate embedding: {str(e)}")
        
        return SemanticBlock(
            block_id=block_id,
            text_description=text_description,
            keywords=keywords,
            semantic_vector=semantic_vector,
            modality=modality,
            original_metadata={},
            bm25_text=text_description  # 无文件名时，BM25使用相同文本
        )
    
    def encode_texts(self, texts: List[str]) -> Optional[np.ndarray]:
        if not self.embedding_model:
            return None
        return self.embedding_model.encode(texts)
    
    def extract_keywords(self, text: str) -> List[str]:
        return self.keyword_extractor.extract(text)
    
    def generate_description(self, text: str) -> str:
        return self.description_generator.generate(text)
    
    def represent_first_page_blocks(self, blocks: List, db_manager=None, file_id: int = None,
                                    max_length: int = 256) -> SemanticBlock:
        """将首页的多个数据块整合成一个语义块

        适用于轻量解析模式下的多页文档（PDF、PPT、Word等）首页处理。

        流程简化:
        1. 收集所有数据块的文本内容
        2. 生成text_description
        3. 提取关键词
        4. 从数据库获取semantic_filename
        5. 根据配置拼接向量文本和BM25文本
        6. 生成语义向量

        Args:
            blocks: 首页的数据块列表
            db_manager: 数据库管理器（可选）
            file_id: 文件ID（可选）
            max_length: 文本最大长度，默认256

        Returns:
            整合后的语义块
        """
        module_name = "SemanticRepresentation-FirstPage"

        try:
            from data_parser import DataBlock
        except ImportError:
            from ..data_parser import DataBlock

        if not blocks:
            raise ValueError("blocks list is empty")

        # 获取文件路径（从第一个数据块）
        file_path = blocks[0].file_path if hasattr(blocks[0], 'file_path') else "unknown"

        # 记录模块开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path=file_path,
            extra_info={
                "total_blocks": len(blocks),
                "db_manager": "已提供" if db_manager else "未提供",
                "file_id": file_id,
                "max_length": max_length
            }
        )

        # 第一步：收集所有数据块的文本内容
        all_texts = []
        processing_logger.log_step("文本收集", f"开始处理 {len(blocks)} 个数据块")

        for i, block in enumerate(blocks):
            if not isinstance(block, DataBlock):
                processing_logger.log_step("跳过", f"数据块 {i} 类型不正确: {type(block)}")
                continue

            block_modality = str(block.modality) if hasattr(block, 'modality') else 'UNKNOWN'
            processing_logger.log_step(f"处理数据块 {i+1}/{len(blocks)}", f"类型: {block_modality}")

            # 判断是否为图片类型
            is_image = 'IMAGE' in block_modality

            # 确定图片路径：使用addr字段
            image_path = None
            if is_image:
                if hasattr(block, 'addr') and block.addr and isinstance(block.addr, str):
                    if os.path.exists(block.addr):
                        image_path = block.addr
                        processing_logger.log_step("图片路径", f"使用addr字段路径: {image_path}")
                if image_path is None and block.file_path and os.path.exists(block.file_path):
                    image_path = block.file_path
                    processing_logger.log_step("图片路径", f"使用file_path字段路径: {image_path}")

            if is_image and image_path:
                # 图片类型：使用OCR提取文本
                processing_logger.log_step("OCR提取", f"对图片数据块进行OCR: {block.block_id}")
                ocr_text = self.image_extractor.extract(image_path, source_file_path=block.file_path)
                if ocr_text and ocr_text.strip():
                    all_texts.append(ocr_text.strip())
                    processing_logger.log_step("OCR完成", f"提取文本长度: {len(ocr_text)}")
                else:
                    processing_logger.log_step("OCR完成", "未提取到文本")
            else:
                # 其他类型：从addr读取文本内容
                text_content = self._read_block_content(block)
                if text_content:
                    all_texts.append(text_content.strip())
                    processing_logger.log_step("文本提取", f"文本长度: {len(text_content)}")

        # 第二步：拼接所有文本并截断
        processing_logger.log_step("文本拼接", f"合并 {len(all_texts)} 个文本片段")
        combined_text = "\n".join(all_texts)
        original_length = len(combined_text)

        # 按照最大长度截断
        if len(combined_text) > max_length:
            combined_text = combined_text[:max_length] + "..."
            processing_logger.log_step("文本截断", f"原始长度: {original_length}, 截断后: {len(combined_text)}")
        else:
            processing_logger.log_step("文本处理", f"总长度: {len(combined_text)} (未截断)")

        # 第三步：生成文本描述
        processing_logger.log_step("生成描述", "使用TextDescriptionGenerator")
        text_description = self.description_generator.generate(combined_text, modality='text')
        processing_logger.log_step("描述生成完成", f"描述长度: {len(text_description)}")

        # 第四步：提取关键词
        processing_logger.log_step("提取关键词", "使用KeywordExtractor")
        keywords = self.keyword_extractor.extract(text_description)
        processing_logger.log_step("关键词提取完成", f"关键词数量: {len(keywords)}", {"keywords": keywords[:10]})

        # 第五步：获取语义文件名
        semantic_filename = self._get_semantic_filename(db_manager, file_id)
        if semantic_filename:
            processing_logger.log_step("语义文件名", f"获取到: {semantic_filename}")
        else:
            processing_logger.log_step("语义文件名", "未获取到")

        # 第六步：根据配置拼接向量文本和BM25文本
        text_for_vector = self._build_text_from_fields(
            self.vector_fields,
            semantic_filename=semantic_filename,
            text_description=text_description,
            keywords=keywords
        )
        text_for_bm25 = self._build_text_from_fields(
            self.bm25_fields,
            semantic_filename=semantic_filename,
            text_description=text_description,
            keywords=keywords
        )

        processing_logger.log_step("文本拼接", f"向量文本长度: {len(text_for_vector)}, BM25文本长度: {len(text_for_bm25)}")

        # 第七步：生成语义向量
        semantic_vector = None
        if self.embedding_model and text_for_vector:
            try:
                processing_logger.log_step("生成向量", f"使用嵌入模型: {type(self.embedding_model).__name__}")
                semantic_vector = self.embedding_model.encode_single(text_for_vector)
                processing_logger.log_step("向量生成完成", f"向量维度: {len(semantic_vector)}")
            except Exception as e:
                processing_logger.log_error(module_name, e, "生成语义向量失败")
        else:
            processing_logger.log_step("生成向量", "跳过（无嵌入模型或文本）")

        # 创建语义块
        import uuid
        semantic_block = SemanticBlock(
            block_id=f"first_page_{uuid.uuid4().hex[:8]}",
            text_description=text_description,
            keywords=keywords,
            semantic_vector=semantic_vector,
            modality='text',
            original_metadata={
                'source_blocks_count': len(blocks),
                'combined_text_length': original_length,
                'max_length': max_length,
                'parsing_mode': 'light_first_page_combined'
            },
            bm25_text=text_for_bm25
        )

        # 记录语义块信息
        processing_logger.log_semantic_block(
            block_id=semantic_block.block_id,
            text_description=semantic_block.text_description,
            keywords=semantic_block.keywords,
            vector_dim=len(semantic_block.semantic_vector) if semantic_block.semantic_vector is not None else 0
        )

        # 写入数据库（如果需要）
        if db_manager and file_id:
            try:
                processing_logger.log_step("数据库写入", f"写入语义块 {semantic_block.block_id}")
                vector_bytes = semantic_vector.tobytes() if semantic_vector is not None else None

                # 收集所有数据块的数据库ID
                data_block_ids = []
                db_data_blocks = db_manager.get_data_blocks_by_file(file_id)
                block_id_to_db_id = {db.block_id: db.id for db in db_data_blocks}
                for block in blocks:
                    if isinstance(block, DataBlock) and block.block_id in block_id_to_db_id:
                        data_block_ids.append(block_id_to_db_id[block.block_id])

                processing_logger.log_step("数据块ID收集", f"找到 {len(data_block_ids)} 个数据块ID: {data_block_ids}")

                db_manager.add_semantic_block(
                    semantic_block_id=semantic_block.block_id,
                    data_block_ids=data_block_ids,  # 传入所有数据块ID的列表
                    file_id=file_id,
                    text_description=semantic_block.text_description,
                    keywords=semantic_block.keywords,
                    semantic_vector=vector_bytes,
                    semantic_filename=semantic_filename
                )
                processing_logger.log_step("数据库写入", f"成功写入语义块 {semantic_block.block_id}")
            except Exception as e:
                processing_logger.log_error(module_name, e, f"写入语义块失败 {semantic_block.block_id}")

        # 记录模块输出和结束
        processing_logger.log_module_output(module_name, {
            "semantic_block_id": semantic_block.block_id,
            "text_description_length": len(semantic_block.text_description),
            "keywords_count": len(semantic_block.keywords),
            "has_vector": semantic_block.semantic_vector is not None,
            "source_blocks_count": len(blocks),
            "semantic_filename": semantic_filename
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"成功整合 {len(blocks)} 个首页数据块")

        # 方案A：清理首页数据块中不再需要的二进制数据
        total_freed = 0
        for block in blocks:
            if hasattr(block, 'modality') and 'IMAGE' in str(block.modality):
                if hasattr(block, 'content') and block.content is not None:
                    if isinstance(block.content, bytes):
                        total_freed += len(block.content)
                        block.content = None
                    # 如果content是字符串路径（page_render模式），保留路径
        if total_freed > 0:
            processing_logger.log_step("内存优化", f"首页块处理，释放图片二进制数据，总计: {total_freed} bytes")

        return semantic_block
