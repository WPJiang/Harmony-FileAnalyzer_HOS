import os
import json
import hashlib
from typing import List, Optional
from .base_parser import BaseParser, DataBlock, ModalityType


class PDFParser(BaseParser):
    """PDF文件解析器

    将PDF文件解析为数据块，保存到cache目录下。
    """
    def __init__(self, cache_dir: str = "cache/data_blocks"):
        super().__init__()
        self.supported_extensions = ['pdf']
        self._config = None
        self._pdf_image_mode = 'embedded'
        self._pdf_image_output_dir = 'cache/pdf_images'
        self._parsing_mode = 1  # 1=轻量解析, 2=深度解析
        self._pdf_render_dpi = 100  # PDF渲染DPI
        self.cache_dir = cache_dir

    def _load_config(self):
        """加载配置文件"""
        if self._config is not None:
            return

        config_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'config.json')
        if os.path.exists(config_path):
            try:
                with open(config_path, 'r', encoding='utf-8') as f:
                    self._config = json.load(f)
                    parsing_config = self._config.get('parsing', {})
                    self._pdf_image_mode = parsing_config.get('pdf_image_mode', 'embedded')
                    self._pdf_image_output_dir = parsing_config.get('pdf_image_output_dir', 'cache/pdf_images')
                    self._parsing_mode = parsing_config.get('mode', 1)
                    self._pdf_render_dpi = parsing_config.get('pdf_render_dpi', 100)
            except Exception as e:
                print(f"[PDFParser] 加载配置文件失败: {e}")
                self._config = {}

    def _get_cache_path(self, file_path: str) -> str:
        """生成缓存目录路径

        Args:
            file_path: PDF文件路径

        Returns:
            缓存目录路径
        """
        file_hash = hashlib.md5(os.path.abspath(file_path).encode()).hexdigest()[:12]
        file_name = os.path.splitext(os.path.basename(file_path))[0]

        cache_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            self.cache_dir,
            f"{file_name}_{file_hash}"
        )

        os.makedirs(cache_path, exist_ok=True)
        return cache_path

    def _get_image_output_path(self, file_path: str, page_num: int) -> str:
        """生成图片输出路径

        Args:
            file_path: PDF文件路径
            page_num: 页码(从1开始)

        Returns:
            图片文件的绝对路径
        """
        file_hash = hashlib.md5(os.path.abspath(file_path).encode()).hexdigest()[:12]
        file_name = os.path.splitext(os.path.basename(file_path))[0]

        output_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            self._pdf_image_output_dir,
            f"{file_name}_{file_hash}"
        )

        os.makedirs(output_dir, exist_ok=True)

        return os.path.join(output_dir, f"page_{page_num:04d}.png")

    def _render_page_to_image(self, page, output_path: str, dpi: int = None) -> bool:
        """将PDF页面渲染为图片并保存

        Args:
            page: PyMuPDF页面对象
            output_path: 输出图片路径
            dpi: 渲染DPI，越高越清晰但文件越大，None时使用配置值

        Returns:
            是否成功保存
        """
        try:
            import fitz
            import gc
            actual_dpi = dpi if dpi is not None else self._pdf_render_dpi
            zoom = actual_dpi / 72.0
            mat = fitz.Matrix(zoom, zoom)

            pix = page.get_pixmap(matrix=mat)
            pix.save(output_path)

            del pix
            gc.collect()

            return True
        except Exception as e:
            print(f"[PDFParser] 渲染页面失败: {e}")
            return False

    def _sort_text_by_visual_order(self, page):
        """按视觉顺序排序文本"""
        text_dict = page.get_text("dict")
        blocks = text_dict["blocks"]
        text_blocks = [b for b in blocks if b["type"] == 0]
        text_blocks.sort(key=lambda b: (b["bbox"][1], b["bbox"][0]))
        result = []
        for block in text_blocks:
            for line in block["lines"]:
                for span in line["spans"]:
                    result.append(span["text"])
        return "".join(result)

    def parse(self, file_path: str) -> List[DataBlock]:
        """解析PDF文件"""
        self._load_config()

        if not self.can_parse(file_path):
            raise ValueError(f"Unsupported file format: {file_path}")

        blocks = []

        try:
            import fitz
            blocks = self._parse_with_pymupdf(file_path)
        except ImportError:
            try:
                import pdfplumber
                blocks = self._parse_with_pdfplumber(file_path)
            except ImportError:
                raise ImportError(
                    "No PDF parser available. Please install pymupdf or pdfplumber: "
                    "pip install pymupdf 或 pip install pdfplumber"
                )

        return blocks

    def _parse_with_pymupdf(self, file_path: str) -> List[DataBlock]:
        """使用PyMuPDF解析PDF"""
        import fitz
        blocks = []
        doc = fitz.open(file_path)

        # 获取缓存目录
        cache_path = self._get_cache_path(file_path)

        # 轻量模式(mode=1)只处理首页，深度模式(mode=2)处理所有页
        max_pages = 1 if self._parsing_mode == 1 else len(doc)

        for page_num in range(max_pages):
            page = doc[page_num]
            text = self._sort_text_by_visual_order(page)

            # 保存文本到缓存文件
            if text.strip():
                text_cache_path = os.path.join(cache_path, f"text_{page_num + 1}.txt")
                try:
                    with open(text_cache_path, 'w', encoding='utf-8') as f:
                        f.write(text)
                except Exception as e:
                    print(f"[PDFParser] 保存文本缓存失败: {e}")
                    text_cache_path = None

                block = DataBlock(
                    block_id=self._generate_block_id(file_path, len(blocks)),
                    modality=ModalityType.TEXT,
                    addr=text_cache_path,
                    file_path=file_path,
                    page_number=page_num + 1,
                    metadata={
                        'source': 'pymupdf',
                        'page_count': len(doc),
                        'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                    }
                )
                blocks.append(block)

            # 根据配置选择图片处理模式
            if self._pdf_image_mode == 'page_render':
                # 将整个页面渲染为图片保存到磁盘
                image_path = self._get_image_output_path(file_path, page_num + 1)

                if self._render_page_to_image(page, image_path):
                    block = DataBlock(
                        block_id=self._generate_block_id(file_path, len(blocks)),
                        modality=ModalityType.IMAGE,
                        addr=image_path,
                        file_path=file_path,
                        page_number=page_num + 1,
                        metadata={
                            'source': 'pymupdf_page_render',
                            'image_path': image_path,
                            'page_count': len(doc),
                            'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                        }
                    )
                    blocks.append(block)
            else:
                # 提取内嵌图片
                images = page.get_images()
                for img_idx, img in enumerate(images):
                    xref = img[0]
                    base_image = doc.extract_image(xref)
                    image_bytes = base_image["image"]

                    # 保存图片到缓存
                    image_ext = base_image.get('ext', 'png')
                    image_cache_path = os.path.join(cache_path, f"image_{page_num + 1}_{img_idx}.{image_ext}")
                    try:
                        with open(image_cache_path, 'wb') as f:
                            f.write(image_bytes)
                    except Exception as e:
                        print(f"[PDFParser] 保存图片缓存失败: {e}")
                        image_cache_path = None

                    block = DataBlock(
                        block_id=self._generate_block_id(file_path, len(blocks)),
                        modality=ModalityType.IMAGE,
                        addr=image_cache_path,
                        file_path=file_path,
                        page_number=page_num + 1,
                        metadata={
                            'source': 'pymupdf',
                            'image_index': img_idx,
                            'image_ext': image_ext,
                            'width': base_image.get('width'),
                            'height': base_image.get('height'),
                            'image_size': len(image_bytes),
                            'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                        }
                    )
                    blocks.append(block)

            # 提取表格
            tables = page.find_tables()
            for table_idx, table in enumerate(tables):
                table_data = table.extract()
                if table_data:
                    table_text = self._table_to_text(table_data)

                    # 保存表格到缓存
                    table_cache_path = os.path.join(cache_path, f"table_{page_num + 1}_{table_idx}.txt")
                    try:
                        with open(table_cache_path, 'w', encoding='utf-8') as f:
                            f.write(table_text)
                    except Exception as e:
                        print(f"[PDFParser] 保存表格缓存失败: {e}")
                        table_cache_path = None

                    block = DataBlock(
                        block_id=self._generate_block_id(file_path, len(blocks)),
                        modality=ModalityType.TABLE,
                        addr=table_cache_path,
                        file_path=file_path,
                        page_number=page_num + 1,
                        metadata={
                            'source': 'pymupdf',
                            'table_index': table_idx,
                            'rows': len(table_data),
                            'cols': len(table_data[0]) if table_data else 0,
                            'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                        }
                    )
                    blocks.append(block)

        doc.close()
        return blocks

    def _parse_with_pdfplumber(self, file_path: str) -> List[DataBlock]:
        """使用pdfplumber解析PDF"""
        import pdfplumber
        blocks = []

        # 获取缓存目录
        cache_path = self._get_cache_path(file_path)

        with pdfplumber.open(file_path) as pdf:
            # 轻量模式(mode=1)只处理首页，深度模式(mode=2)处理所有页
            max_pages = 1 if self._parsing_mode == 1 else len(pdf.pages)

            for page_num in range(max_pages):
                page = pdf.pages[page_num]
                text = page.extract_text()

                if text and text.strip():
                    # 保存文本到缓存
                    text_cache_path = os.path.join(cache_path, f"text_{page_num + 1}.txt")
                    try:
                        with open(text_cache_path, 'w', encoding='utf-8') as f:
                            f.write(text)
                    except Exception as e:
                        print(f"[PDFParser] 保存文本缓存失败: {e}")
                        text_cache_path = None

                    block = DataBlock(
                        block_id=self._generate_block_id(file_path, len(blocks)),
                        modality=ModalityType.TEXT,
                        addr=text_cache_path,
                        file_path=file_path,
                        page_number=page_num + 1,
                        metadata={
                            'source': 'pdfplumber',
                            'page_count': len(pdf.pages),
                            'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                        }
                    )
                    blocks.append(block)

                tables = page.extract_tables()
                for table_idx, table in enumerate(tables):
                    if table:
                        table_text = self._table_to_text(table)

                        # 保存表格到缓存
                        table_cache_path = os.path.join(cache_path, f"table_{page_num + 1}_{table_idx}.txt")
                        try:
                            with open(table_cache_path, 'w', encoding='utf-8') as f:
                                f.write(table_text)
                        except Exception as e:
                            print(f"[PDFParser] 保存表格缓存失败: {e}")
                            table_cache_path = None

                        block = DataBlock(
                            block_id=self._generate_block_id(file_path, len(blocks)),
                            modality=ModalityType.TABLE,
                            addr=table_cache_path,
                            file_path=file_path,
                            page_number=page_num + 1,
                            metadata={
                                'source': 'pdfplumber',
                                'table_index': table_idx,
                                'rows': len(table),
                                'cols': len(table[0]) if table else 0,
                                'parsing_mode': 'light_first_page' if self._parsing_mode == 1 else 'deep'
                            }
                        )
                        blocks.append(block)

        return blocks

    def _table_to_text(self, table_data: List[List]) -> str:
        """将表格转换为文本"""
        rows = []
        for row in table_data:
            row_text = ' | '.join(str(cell) if cell else '' for cell in row)
            rows.append(row_text)
        return '\n'.join(rows)