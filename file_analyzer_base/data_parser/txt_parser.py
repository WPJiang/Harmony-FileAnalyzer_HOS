import os
import shutil
import hashlib
from typing import List
from .base_parser import BaseParser, DataBlock, ModalityType


class TXTParser(BaseParser):
    """文本文件解析器

    支持解析txt、md、log、csv等纯文本文件。
    将文件内容复制到cache目录下，返回TEXT类型数据块。
    """

    def __init__(self, cache_dir: str = "cache/data_blocks"):
        super().__init__()
        self.supported_extensions = ['txt', 'md', 'log', 'csv']
        self.cache_dir = cache_dir

    def _get_cache_path(self, file_path: str) -> str:
        """生成缓存文件路径

        Args:
            file_path: 原始文件路径

        Returns:
            缓存目录路径
        """
        # 使用文件路径的哈希值作为子目录名
        file_hash = hashlib.md5(os.path.abspath(file_path).encode()).hexdigest()[:12]
        file_name = os.path.splitext(os.path.basename(file_path))[0]

        # 构建缓存目录路径
        cache_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            self.cache_dir,
            f"{file_name}_{file_hash}"
        )

        return cache_path

    def parse(self, file_path: str) -> List[DataBlock]:
        """解析文本文件

        将文件内容复制到cache目录下，返回TEXT类型数据块。

        Args:
            file_path: 文件路径

        Returns:
            数据块列表
        """
        if not self.can_parse(file_path):
            raise ValueError(f"Unsupported file format: {file_path}")

        blocks = []

        # 获取缓存目录路径
        cache_path = self._get_cache_path(file_path)
        os.makedirs(cache_path, exist_ok=True)

        # 复制文件到缓存目录
        file_name = os.path.basename(file_path)
        cached_file_path = os.path.join(cache_path, f"text_0.txt")

        try:
            shutil.copy2(file_path, cached_file_path)
        except Exception as e:
            print(f"[TXTParser] 复制文件到缓存失败: {e}")
            # 如果复制失败，使用原始文件路径
            cached_file_path = file_path

        # 创建数据块
        block = DataBlock(
            block_id=self._generate_block_id(file_path, 0),
            modality=ModalityType.TEXT,
            addr=cached_file_path,
            file_path=file_path,
            page_number=1,
            metadata={
                'source': 'txt_parser',
                'original_file_name': file_name,
                'cache_dir': cache_path
            }
        )
        blocks.append(block)

        return blocks