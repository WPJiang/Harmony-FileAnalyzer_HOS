import os
import json
import hashlib
from typing import List, Dict, Type, Optional
from pathlib import Path
from .base_parser import BaseParser, DataBlock, ModalityType
from .pdf_parser import PDFParser
from .word_parser import WordParser
from .ppt_parser import PPTParser
from .excel_parser import ExcelParser
from .image_parser import ImageParser
from .audio_parser import AudioParser
from .txt_parser import TXTParser

import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from logger import processing_logger
from semantic_representation.semantic_representation import FilenameSemanticAnalyzer


class DataParser:
    """数据解析器

    支持两种解析模式:
    - 轻量解析 (mode=1): 每个文件仅产生一个文本类型数据块，文本内容使用文件名和内容拼接，并根据长度约束截断
    - 深度解析 (mode=2): 完整解析文件，产生多个数据块（如PDF的每页、图片的OCR结果等）

    数据块内容保存到cache目录下，通过addr字段引用。
    """

    def __init__(self, config: Optional[Dict] = None):
        self.config = config or {}
        self._parsers: Dict[str, BaseParser] = {}
        self._initialize_parsers()

    def _get_parsing_config(self) -> Dict:
        """获取解析配置"""
        return self.config.get('parsing', {
            'mode': 1,
            'light_mode_max_length': 256
        })

    def _initialize_parsers(self):
        """初始化所有解析器"""
        parser_config = self.config.get('parsers', {})

        self._parsers['pdf'] = PDFParser()
        self._parsers['docx'] = WordParser()
        self._parsers['doc'] = WordParser()
        self._parsers['pptx'] = PPTParser()
        self._parsers['ppt'] = PPTParser()
        self._parsers['xlsx'] = ExcelParser()
        self._parsers['xls'] = ExcelParser()
        self._parsers['txt'] = TXTParser()

        image_config = parser_config.get('image', {})
        self._parsers['image'] = ImageParser(
            use_ocr=image_config.get('use_ocr', True),
            ocr_engine=image_config.get('ocr_engine', 'auto')
        )

        audio_config = parser_config.get('audio', {})
        self._parsers['audio'] = AudioParser(
            use_transcription=audio_config.get('use_transcription', True),
            model_size=audio_config.get('model_size', 'base')
        )

    def _get_cache_path(self, file_path: str) -> str:
        """生成缓存目录路径"""
        file_hash = hashlib.md5(os.path.abspath(file_path).encode()).hexdigest()[:12]
        file_name = os.path.splitext(os.path.basename(file_path))[0]

        cache_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "cache/data_blocks",
            f"{file_name}_{file_hash}"
        )

        os.makedirs(cache_path, exist_ok=True)
        return cache_path

    def parse_file(self, file_path: str, db_manager=None, file_id: int = None,
                   parsing_mode: int = None) -> List[DataBlock]:
        """解析文件，如果提供db_manager和file_id则自动写入数据块表

        Args:
            file_path: 文件路径
            db_manager: 数据库管理器（可选）
            file_id: 文件ID（可选）
            parsing_mode: 解析模式，1=轻量解析，2=深度解析。为None时使用配置文件中的设置

        Returns:
            数据块列表
        """
        module_name = "DataParser"

        # 记录模块开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path=file_path,
            extra_info={
                "db_manager": "已提供" if db_manager else "未提供",
                "file_id": file_id,
                "parsing_mode": parsing_mode
            }
        )

        if not os.path.exists(file_path):
            error = FileNotFoundError(f"File not found: {file_path}")
            processing_logger.log_error(module_name, error)
            processing_logger.log_module_end(module_name, success=False, message="文件不存在")
            raise error

        # 获取解析配置
        parsing_config = self._get_parsing_config()
        if parsing_mode is None:
            parsing_mode = parsing_config.get('mode', 1)
        max_length = parsing_config.get('light_mode_max_length', 256)

        processing_logger.log_step("配置加载", "解析配置", {
            "parsing_mode": parsing_mode,
            "max_length": max_length
        })

        ext = Path(file_path).suffix.lower().lstrip('.')
        processing_logger.log_step("文件类型识别", f"扩展名: {ext}")

        parser = self._get_parser(ext)
        if parser is None:
            error = ValueError(f"No parser available for extension: {ext}")
            processing_logger.log_error(module_name, error)
            processing_logger.log_module_end(module_name, success=False, message=f"不支持的文件类型: {ext}")
            raise error

        # 判断文件类型
        is_image = ext in ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp']
        is_multipage = ext in ['pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx']
        is_text = ext in ['txt', 'md', 'log', 'csv']

        processing_logger.log_step("文件类型判断", f"is_image={is_image}, is_multipage={is_multipage}, is_text={is_text}")

        # 执行解析
        processing_logger.log_step("开始解析", f"使用解析器: {type(parser).__name__}")
        try:
            blocks = parser.parse(file_path)
            processing_logger.log_step("解析完成", f"原始数据块数量: {len(blocks)}")
        except Exception as e:
            import traceback
            error_detail = traceback.format_exc()
            processing_logger.log_error(module_name, e, f"解析失败: {file_path}")
            print(f"[DataParser] 解析失败 {file_path}: {e}\n{error_detail}")
            processing_logger.log_module_end(module_name, success=False, message=f"解析失败: {str(e)}")
            raise

        # 轻量解析模式
        if parsing_mode == 1 and blocks:
            processing_logger.log_step("轻量解析模式", "开始处理")
            filename = os.path.basename(file_path)

            # 图片类型：仅保留图片类型数据块
            if is_image:
                processing_logger.log_step("轻量解析", "处理图片类型")
                # 过滤出图片类型的数据块
                image_blocks = [b for b in blocks if hasattr(b, 'modality') and 'IMAGE' in str(b.modality)]
                if image_blocks:
                    # 只保留第一个图片块
                    image_block = image_blocks[0]
                    blocks = [image_block]
                    processing_logger.log_step("轻量解析", f"保留图片块 {image_block.block_id}")
                else:
                    blocks = []
                    processing_logger.log_step("轻量解析", "未找到图片数据块")

            # 多页文档类型：仅保留首页的数据块
            elif is_multipage:
                processing_logger.log_step("轻量解析", "处理多页文档类型 - 仅保留首页数据块")

                # 过滤出第一页的数据块
                first_page_blocks = []
                for block in blocks:
                    page_num = getattr(block, 'page_number', 1)
                    if page_num == 1:
                        first_page_blocks.append(block)

                processing_logger.log_step("首页过滤", f"原始数据块: {len(blocks)}, 首页数据块: {len(first_page_blocks)}")

                if first_page_blocks:
                    # 为每个首页数据块添加轻量模式标记
                    for block in first_page_blocks:
                        if hasattr(block, 'metadata') and block.metadata:
                            block.metadata['parsing_mode'] = 'light_first_page'
                        else:
                            block.metadata = {'parsing_mode': 'light_first_page'}

                    blocks = first_page_blocks
                    processing_logger.log_step("轻量解析", f"保留 {len(blocks)} 个首页数据块")
                else:
                    # 如果没有找到首页数据块，使用第一个数据块
                    if blocks:
                        blocks = [blocks[0]]
                        blocks[0].metadata = {'parsing_mode': 'light_first_page'}
                        processing_logger.log_step("轻量解析", "未找到首页数据块，使用第一个数据块")

            # 文本类型：保持原样
            elif is_text:
                processing_logger.log_step("轻量解析", "处理文本类型 - 保持原样")
                for block in blocks:
                    if hasattr(block, 'metadata') and block.metadata:
                        block.metadata['parsing_mode'] = 'light'
                    else:
                        block.metadata = {'parsing_mode': 'light'}

            # 其他类型
            else:
                processing_logger.log_step("轻量解析", "处理其他类型")
                # 合并所有addr指向的内容
                cache_path = self._get_cache_path(file_path)
                combined_text = f"文件名: {filename}\n"

                # 读取所有数据块的内容
                for block in blocks:
                    if hasattr(block, 'addr') and block.addr and os.path.exists(block.addr):
                        try:
                            with open(block.addr, 'r', encoding='utf-8') as f:
                                combined_text += f.read() + "\n"
                        except Exception:
                            pass

                # 截断到最大长度
                original_length = len(combined_text)
                if len(combined_text) > max_length:
                    combined_text = combined_text[:max_length] + "..."

                # 保存合并后的文本到缓存
                combined_cache_path = os.path.join(cache_path, "combined.txt")
                try:
                    with open(combined_cache_path, 'w', encoding='utf-8') as f:
                        f.write(combined_text)
                except Exception as e:
                    print(f"[DataParser] 保存合并文本缓存失败: {e}")
                    combined_cache_path = None

                # 创建单个数据块
                import uuid
                light_block = DataBlock(
                    block_id=f"light_{uuid.uuid4().hex[:8]}",
                    file_path=file_path,
                    modality=ModalityType.TEXT,
                    addr=combined_cache_path,
                    page_number=1,
                    metadata={
                        'parsing_mode': 'light',
                        'original_blocks_count': len(blocks),
                        'max_length': max_length
                    }
                )
                blocks = [light_block]
                processing_logger.log_step("轻量解析", f"创建合并数据块")

        # 提取语义文件名并更新数据库
        if db_manager and file_id:
            filename = os.path.basename(file_path)
            # 去除扩展名
            name_without_ext = os.path.splitext(filename)[0]

            # 使用FilenameSemanticAnalyzer提取有意义的部分
            semantic_analyzer = FilenameSemanticAnalyzer()
            semantic_filename = semantic_analyzer.get_meaningful_part(name_without_ext)

            processing_logger.log_step("语义文件名提取", f"原始: {name_without_ext}, 语义: {semantic_filename}")

            # 更新数据库中的semantic_filename字段
            if semantic_filename:
                try:
                    db_manager.update_file_semantic_filename(file_id, semantic_filename)
                    processing_logger.log_step("数据库更新", f"更新语义文件名: {semantic_filename}")
                except Exception as e:
                    processing_logger.log_error(module_name, e, f"更新语义文件名失败: {file_id}")

        # 写入数据库
        if db_manager and file_id and blocks:
            processing_logger.log_step("数据库写入", f"写入 {len(blocks)} 个数据块")
            for block in blocks:
                try:
                    position = json.dumps(block.position) if hasattr(block, 'position') and block.position else "{}"
                    metadata = json.dumps(block.metadata) if hasattr(block, 'metadata') and block.metadata else "{}"

                    db_manager.add_data_block(
                        block_id=block.block_id,
                        file_id=file_id,
                        modality=block.modality.value if hasattr(block.modality, 'value') else str(block.modality),
                        addr=block.addr if hasattr(block, 'addr') else None,
                        page_number=block.page_number if hasattr(block, 'page_number') else 1,
                        position=position,
                        metadata=metadata
                    )
                    processing_logger.log_step("数据库写入", f"成功写入数据块 {block.block_id}")
                except Exception as e:
                    processing_logger.log_error(module_name, e, f"写入数据块失败 {block.block_id}")

        # 记录模块输出和结束
        processing_logger.log_module_output(module_name, {
            "final_blocks_count": len(blocks),
            "parsing_mode": parsing_mode,
            "is_image": is_image,
            "is_multipage": is_multipage,
            "is_text": is_text
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"成功解析，生成 {len(blocks)} 个数据块")

        return blocks

    def parse_directory(
        self,
        directory: str,
        recursive: bool = True,
        extensions: Optional[List[str]] = None
    ) -> Dict[str, List[DataBlock]]:
        """解析目录下的所有文件"""
        if not os.path.isdir(directory):
            raise NotADirectoryError(f"Not a directory: {directory}")

        results = {}

        if recursive:
            for root, _, files in os.walk(directory):
                for file in files:
                    file_path = os.path.join(root, file)
                    ext = Path(file).suffix.lower().lstrip('.')

                    if extensions and ext not in extensions:
                        continue

                    if self._get_parser(ext):
                        try:
                            blocks = self.parse_file(file_path)
                            results[file_path] = blocks
                        except Exception as e:
                            print(f"Error parsing {file_path}: {str(e)}")
        else:
            for item in os.listdir(directory):
                file_path = os.path.join(directory, item)
                if os.path.isfile(file_path):
                    ext = Path(item).suffix.lower().lstrip('.')

                    if extensions and ext not in extensions:
                        continue

                    if self._get_parser(ext):
                        try:
                            blocks = self.parse_file(file_path)
                            results[file_path] = blocks
                        except Exception as e:
                            print(f"Error parsing {file_path}: {str(e)}")

        return results

    def _get_parser(self, extension: str) -> Optional[BaseParser]:
        """根据扩展名获取解析器"""
        ext = extension.lower()

        if ext in ['pdf']:
            return self._parsers.get('pdf')
        elif ext in ['docx', 'doc']:
            return self._parsers.get('docx')
        elif ext in ['pptx', 'ppt']:
            return self._parsers.get('pptx')
        elif ext in ['xlsx', 'xls']:
            return self._parsers.get('xlsx')
        elif ext in ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp']:
            return self._parsers.get('image')
        elif ext in ['wav', 'mp3', 'm4a', 'flac', 'ogg', 'aac']:
            return self._parsers.get('audio')
        elif ext in ['txt', 'md', 'log', 'csv']:
            return self._parsers.get('txt')

        return None

    def get_supported_extensions(self) -> List[str]:
        """获取支持的文件扩展名列表"""
        extensions = []
        extensions.extend(['pdf'])
        extensions.extend(['docx', 'doc'])
        extensions.extend(['pptx', 'ppt'])
        extensions.extend(['xlsx', 'xls'])
        extensions.extend(['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp'])
        extensions.extend(['wav', 'mp3', 'm4a', 'flac', 'ogg', 'aac'])
        extensions.extend(['txt', 'md', 'log', 'csv'])
        return extensions

    def register_parser(self, extension: str, parser: BaseParser):
        """注册自定义解析器"""
        self._parsers[extension] = parser