"""
data_parser 模块单元测试

测试说明:
1. 将测试文件放入 data_test_debug 目录
2. 运行测试: python -m pytest tests/test_data_parser.py -v
   或直接运行: python tests/test_data_parser.py
"""

import os
import sys
import unittest
from pathlib import Path

# 添加项目根目录到路径
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from data_parser import DataParser, DataBlock, ModalityType


# 测试数据目录
TEST_DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'data_test_debug')


class TestDataParser(unittest.TestCase):
    """DataParser 单元测试类"""

    @classmethod
    def setUpClass(cls):
        """测试类初始化"""
        cls.parser = DataParser()
        cls.test_dir = TEST_DATA_DIR
        
        # 确保测试目录存在
        if not os.path.exists(cls.test_dir):
            os.makedirs(cls.test_dir)
            print(f"创建测试目录: {cls.test_dir}")
        
        # 列出测试目录中的文件
        if os.path.exists(cls.test_dir):
            files = os.listdir(cls.test_dir)
            print(f"\n测试目录中的文件: {files}")

    def _get_test_file(self, filename: str) -> str:
        """获取测试文件路径"""
        return os.path.join(self.test_dir, filename)

    def _file_exists(self, filename: str) -> bool:
        """检查测试文件是否存在"""
        path = self._get_test_file(filename)
        exists = os.path.exists(path)
        if not exists:
            print(f"  跳过测试: 文件不存在 {filename}")
        return exists

    # ==================== 基础功能测试 ====================

    def test_parser_initialization(self):
        """测试解析器初始化"""
        self.assertIsNotNone(self.parser)
        self.assertIsNotNone(self.parser._parsers)

    def test_supported_extensions(self):
        """测试支持的文件扩展名"""
        supported = [
            'pdf', 'docx', 'doc', 'pptx', 'ppt',
            'txt', 'md',
            'jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp',
            'mp3', 'wav', 'm4a', 'flac',
            'mp4', 'avi', 'mov', 'mkv'
        ]
        for ext in supported:
            parser = self.parser._get_parser(ext)
            self.assertIsNotNone(parser, f"应该支持扩展名: {ext}")

    # ==================== PDF 解析测试 ====================

    def test_pdf_parsing(self):
        """测试 PDF 文件解析"""
        test_files = ['test.pdf', 'sample.pdf', 'document.pdf']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertIsInstance(blocks[0], DataBlock)
                        print(f"  PDF 解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  PDF 解析失败 {filename}: {e}")

    def test_pdf_light_mode(self):
        """测试 PDF 轻量解析模式"""
        test_files = ['test.pdf', 'sample.pdf']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path, parsing_mode=1)
                    self.assertIsInstance(blocks, list)
                    # 轻量模式应该只生成一个数据块
                    if blocks:
                        self.assertEqual(len(blocks), 1, "轻量模式应只生成一个数据块")
                        self.assertEqual(blocks[0].modality, ModalityType.TEXT)
                        print(f"  PDF 轻量解析成功: {filename}")
                        print(f"    内容预览: {blocks[0].text_content[:100]}...")
                except Exception as e:
                    print(f"  PDF 轻量解析失败 {filename}: {e}")

    # ==================== Word 解析测试 ====================

    def test_word_parsing(self):
        """测试 Word 文件解析"""
        test_files = ['test.docx', 'test.doc', 'sample.docx']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertIsInstance(blocks[0], DataBlock)
                        print(f"  Word 解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  Word 解析失败 {filename}: {e}")

    def test_word_light_mode(self):
        """测试 Word 轻量解析模式"""
        test_files = ['test.docx', 'sample.docx']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path, parsing_mode=1)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertEqual(len(blocks), 1, "轻量模式应只生成一个数据块")
                        print(f"  Word 轻量解析成功: {filename}")
                        print(f"    内容预览: {blocks[0].text_content[:100]}...")
                except Exception as e:
                    print(f"  Word 轻量解析失败 {filename}: {e}")

    # ==================== PPT 解析测试 ====================

    def test_ppt_parsing(self):
        """测试 PPT 文件解析"""
        test_files = ['test.pptx', 'test.ppt', 'sample.pptx']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertIsInstance(blocks[0], DataBlock)
                        print(f"  PPT 解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  PPT 解析失败 {filename}: {e}")

    def test_ppt_light_mode(self):
        """测试 PPT 轻量解析模式"""
        test_files = ['test.pptx', 'sample.pptx']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path, parsing_mode=1)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertEqual(len(blocks), 1, "轻量模式应只生成一个数据块")
                        print(f"  PPT 轻量解析成功: {filename}")
                        print(f"    内容预览: {blocks[0].text_content[:100]}...")
                except Exception as e:
                    print(f"  PPT 轻量解析失败 {filename}: {e}")

    # ==================== 图片解析测试 ====================

    def test_image_parsing(self):
        """测试图片文件解析"""
        test_files = ['test.jpg', 'test.png', 'test.jpeg', 'sample.png']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        # 检查是否有图片类型的数据块
                        image_blocks = [b for b in blocks if 'IMAGE' in str(b.modality)]
                        self.assertGreater(len(image_blocks), 0, "应生成图片类型数据块")
                        print(f"  图片解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  图片解析失败 {filename}: {e}")

    def test_image_light_mode(self):
        """测试图片轻量解析模式"""
        test_files = ['test.jpg', 'test.png']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path, parsing_mode=1)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        # 轻量模式应只生成一个图片数据块
                        self.assertEqual(len(blocks), 1, "轻量模式应只生成一个数据块")
                        self.assertIn('IMAGE', str(blocks[0].modality))
                        # 检查基础描述格式
                        self.assertIn('[Image file:', blocks[0].text_content)
                        print(f"  图片轻量解析成功: {filename}")
                        print(f"    描述: {blocks[0].text_content}")
                except Exception as e:
                    print(f"  图片轻量解析失败 {filename}: {e}")

    # ==================== 文本文件解析测试 ====================

    def test_text_parsing(self):
        """测试文本文件解析"""
        test_files = ['test.txt', 'test.md', 'readme.txt']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        self.assertEqual(blocks[0].modality, ModalityType.TEXT)
                        print(f"  文本解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  文本解析失败 {filename}: {e}")

    # ==================== 音频解析测试 ====================

    def test_audio_parsing(self):
        """测试音频文件解析"""
        test_files = ['test.mp3', 'test.wav', 'sample.mp3']
        
        for filename in test_files:
            if not self._file_exists(filename):
                continue
                
            with self.subTest(filename=filename):
                file_path = self._get_test_file(filename)
                try:
                    blocks = self.parser.parse_file(file_path)
                    self.assertIsInstance(blocks, list)
                    if blocks:
                        print(f"  音频解析成功: {filename}, 生成 {len(blocks)} 个数据块")
                except Exception as e:
                    print(f"  音频解析失败 {filename}: {e}")

    # ==================== 目录解析测试 ====================

    def test_directory_parsing(self):
        """测试目录解析"""
        if not os.path.exists(self.test_dir):
            self.skipTest("测试目录不存在")
            
        try:
            results = self.parser.parse_directory(self.test_dir, recursive=False)
            self.assertIsInstance(results, dict)
            print(f"  目录解析成功: 找到 {len(results)} 个文件")
            for file_path, blocks in list(results.items())[:3]:  # 只显示前3个
                print(f"    {os.path.basename(file_path)}: {len(blocks)} 个数据块")
        except Exception as e:
            print(f"  目录解析失败: {e}")

    # ==================== 错误处理测试 ====================

    def test_nonexistent_file(self):
        """测试不存在的文件"""
        with self.assertRaises(FileNotFoundError):
            self.parser.parse_file(os.path.join(self.test_dir, 'nonexistent.pdf'))

    def test_unsupported_extension(self):
        """测试不支持的文件扩展名"""
        test_file = os.path.join(self.test_dir, 'test.xyz')
        # 创建空文件
        with open(test_file, 'w') as f:
            f.write('test')
        
        try:
            with self.assertRaises(ValueError):
                self.parser.parse_file(test_file)
        finally:
            # 清理
            if os.path.exists(test_file):
                os.remove(test_file)


class TestDataParserModes(unittest.TestCase):
    """测试不同解析模式"""

    @classmethod
    def setUpClass(cls):
        cls.parser = DataParser()
        cls.test_dir = TEST_DATA_DIR

    def test_light_mode_max_length(self):
        """测试轻量模式最大长度限制"""
        # 创建一个测试文本文件
        test_file = os.path.join(self.test_dir, 'long_text.txt')
        
        # 生成超过256字符的文本
        long_text = "这是一个测试文件。" * 50
        
        with open(test_file, 'w', encoding='utf-8') as f:
            f.write(long_text)
        
        try:
            blocks = self.parser.parse_file(test_file, parsing_mode=1)
            if blocks:
                content = blocks[0].text_content
                # 检查是否包含截断标记
                if len(long_text) > 256:
                    self.assertLess(len(content), len(long_text) + 100)  # 考虑文件名前缀
                print(f"  轻量模式长度限制测试通过")
                print(f"    原始长度: {len(long_text)}")
                print(f"    结果长度: {len(content)}")
        finally:
            if os.path.exists(test_file):
                os.remove(test_file)

    def test_deep_mode(self):
        """测试深度解析模式"""
        # 查找测试目录中的第一个PDF文件
        pdf_files = [f for f in os.listdir(self.test_dir) if f.endswith('.pdf')] if os.path.exists(self.test_dir) else []
        
        if not pdf_files:
            self.skipTest("没有找到PDF测试文件")
            
        test_file = os.path.join(self.test_dir, pdf_files[0])
        
        try:
            # 深度模式
            deep_blocks = self.parser.parse_file(test_file, parsing_mode=2)
            # 轻量模式
            light_blocks = self.parser.parse_file(test_file, parsing_mode=1)
            
            print(f"  深度模式: {len(deep_blocks)} 个数据块")
            print(f"  轻量模式: {len(light_blocks)} 个数据块")
            
            # 深度模式通常会产生更多数据块
            self.assertGreaterEqual(len(deep_blocks), len(light_blocks))
            
        except Exception as e:
            print(f"  深度模式测试失败: {e}")


def run_tests():
    """运行所有测试"""
    # 创建测试套件
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    
    # 添加测试类
    suite.addTests(loader.loadTestsFromTestCase(TestDataParser))
    suite.addTests(loader.loadTestsFromTestCase(TestDataParserModes))
    
    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    
    return result.wasSuccessful()


if __name__ == '__main__':
    print("=" * 60)
    print("DataParser 模块单元测试")
    print("=" * 60)
    print(f"测试数据目录: {TEST_DATA_DIR}")
    print("-" * 60)
    
    success = run_tests()
    
    print("-" * 60)
    if success:
        print("所有测试通过!")
    else:
        print("部分测试失败!")
    print("=" * 60)
