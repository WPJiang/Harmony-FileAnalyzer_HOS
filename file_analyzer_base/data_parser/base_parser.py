from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any
from enum import Enum


class ModalityType(Enum):
    TEXT = "text"
    IMAGE = "image"
    TABLE = "table"
    AUDIO = "audio"
    VIDEO = "video"


@dataclass
class DataBlock:
    """数据块

    数据块是文件解析后的基本单元，内容保存到cache目录下，
    通过addr字段引用缓存文件路径。
    """
    block_id: str
    modality: ModalityType
    addr: Optional[str] = None  # 数据块文件路径（cache目录下）
    metadata: Dict[str, Any] = field(default_factory=dict)
    file_path: Optional[str] = None
    page_number: Optional[int] = None
    position: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            'block_id': self.block_id,
            'modality': self.modality.value,
            'addr': self.addr,
            'metadata': self.metadata,
            'file_path': self.file_path,
            'page_number': self.page_number,
            'position': self.position
        }


class BaseParser(ABC):
    def __init__(self):
        self.supported_extensions: List[str] = []

    @abstractmethod
    def parse(self, file_path: str) -> List[DataBlock]:
        pass

    def can_parse(self, file_path: str) -> bool:
        ext = file_path.lower().split('.')[-1]
        return ext in self.supported_extensions

    def _generate_block_id(self, file_path: str, index: int) -> str:
        import hashlib
        base = f"{file_path}_{index}"
        return hashlib.md5(base.encode()).hexdigest()[:12]

    def _extract_text_from_content(self, content: Any) -> Optional[str]:
        if isinstance(content, str):
            return content
        elif isinstance(content, dict):
            return content.get('text', None)
        elif isinstance(content, list):
            texts = []
            for item in content:
                if isinstance(item, str):
                    texts.append(item)
                elif isinstance(item, dict) and 'text' in item:
                    texts.append(item['text'])
            return ' '.join(texts) if texts else None
        return None
