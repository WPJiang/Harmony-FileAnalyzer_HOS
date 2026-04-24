import os
import gc
import hashlib
from typing import List, Optional
from io import BytesIO
from .base_parser import BaseParser, DataBlock, ModalityType


class ImageParser(BaseParser):
    """图片文件解析器

    将图片文件解析为数据块，addr指向图片文件路径。
    """
    def __init__(self, use_ocr: bool = True, ocr_engine: str = 'auto',
                 cache_dir: str = "cache/data_blocks"):
        super().__init__()
        self.supported_extensions = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp']
        self.use_ocr = use_ocr
        self.ocr_engine = ocr_engine
        self._ocr_instance = None
        self.cache_dir = cache_dir

    def _get_cache_path(self, file_path: str) -> str:
        """生成缓存目录路径"""
        file_hash = hashlib.md5(os.path.abspath(file_path).encode()).hexdigest()[:12]
        file_name = os.path.splitext(os.path.basename(file_path))[0]

        cache_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            self.cache_dir,
            f"{file_name}_{file_hash}"
        )

        os.makedirs(cache_path, exist_ok=True)
        return cache_path

    def parse(self, file_path: str) -> List[DataBlock]:
        """解析图片文件

        Args:
            file_path: 图片文件路径

        Returns:
            数据块列表
        """
        if not self.can_parse(file_path):
            raise ValueError(f"Unsupported file format: {file_path}")

        blocks = []
        img = None

        try:
            from PIL import Image
            img = Image.open(file_path)

            # 获取缓存目录
            cache_path = self._get_cache_path(file_path)

            # 图片数据块：addr指向原始图片路径
            basic_block = DataBlock(
                block_id=self._generate_block_id(file_path, 0),
                modality=ModalityType.IMAGE,
                addr=file_path,  # 直接指向原始图片文件
                file_path=file_path,
                metadata={
                    'source': 'image_parser',
                    'file_size': os.path.getsize(file_path),
                    'width': img.width,
                    'height': img.height,
                    'format': img.format,
                    'mode': img.mode
                }
            )

            blocks.append(basic_block)

            # 在OCR之前关闭图片对象释放内存
            img.close()
            img = None

            # OCR处理
            if self.use_ocr:
                ocr_text = self._perform_ocr(file_path)
                if ocr_text:
                    # 保存OCR结果到缓存
                    ocr_cache_path = os.path.join(cache_path, "ocr_0.txt")
                    try:
                        with open(ocr_cache_path, 'w', encoding='utf-8') as f:
                            f.write(ocr_text)
                    except Exception as e:
                        print(f"[ImageParser] 保存OCR结果失败: {e}")
                        ocr_cache_path = None

                    ocr_block = DataBlock(
                        block_id=self._generate_block_id(file_path, 1),
                        modality=ModalityType.TEXT,
                        addr=ocr_cache_path,
                        file_path=file_path,
                        metadata={
                            'source': 'ocr',
                            'ocr_engine': self.ocr_engine
                        }
                    )
                    blocks.append(ocr_block)

        except ImportError:
            pass
        except Exception as e:
            print(f"[ImageParser] 解析图片失败: {e}")
        finally:
            if img is not None:
                try:
                    img.close()
                except:
                    pass
            gc.collect()

        return blocks

    def _perform_ocr(self, file_path: str) -> Optional[str]:
        """执行OCR识别 - 使用全局ModelManager避免重复加载模型"""
        try:
            from models.model_manager import get_ocr_instance
            ocr_func = get_ocr_instance(self.use_ocr)

            if ocr_func is None:
                return None

            return ocr_func(file_path)
        except Exception as e:
            print(f"[ImageParser] OCR failed: {str(e)}")
            return None

    def _get_ocr_engine(self):
        """获取OCR引擎（保留用于兼容性）"""
        if self.ocr_engine == 'auto' or self.ocr_engine == 'tesseract':
            try:
                import pytesseract
                from PIL import Image

                def tesseract_ocr(image_bytes):
                    img = Image.open(BytesIO(image_bytes))
                    return pytesseract.image_to_string(img, lang='chi_sim+eng')

                return tesseract_ocr
            except ImportError:
                if self.ocr_engine == 'tesseract':
                    raise ImportError(
                        "pytesseract and tesseract are required for OCR. "
                        "Install with: pip install pytesseract, and install tesseract-ocr"
                    )

        if self.ocr_engine == 'auto' or self.ocr_engine == 'easyocr':
            try:
                import easyocr
                reader = easyocr.Reader(['ch_sim', 'en'], gpu=False)

                def easyocr_ocr(image_bytes):
                    import numpy as np
                    from PIL import Image

                    img = Image.open(BytesIO(image_bytes))
                    img_array = np.array(img)
                    results = reader.readtext(img_array)
                    texts = [result[1] for result in results]
                    return '\n'.join(texts)

                return easyocr_ocr
            except ImportError:
                if self.ocr_engine == 'easyocr':
                    raise ImportError(
                        "easyocr is required for OCR. "
                        "Install with: pip install easyocr"
                    )

        if self.ocr_engine == 'auto' or self.ocr_engine == 'paddleocr':
            try:
                from paddleocr import PaddleOCR
                ocr = PaddleOCR(use_angle_cls=True, lang='ch', use_gpu=False)

                def paddleocr_ocr(image_bytes):
                    import numpy as np
                    from PIL import Image

                    img = Image.open(BytesIO(image_bytes))
                    img_array = np.array(img)
                    result = ocr.ocr(img_array, cls=True)
                    texts = [line[1][0] for line in result[0]] if result[0] else []
                    return '\n'.join(texts)

                return paddleocr_ocr
            except ImportError:
                if self.ocr_engine == 'paddleocr':
                    raise ImportError(
                        "paddleocr is required for OCR. "
                        "Install with: pip install paddleocr"
                    )

        return None