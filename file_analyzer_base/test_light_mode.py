"""
测试轻量分析模式 - 首页多数据块解析和整合
"""
import os
import sys

# 添加项目路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from logger import processing_logger
from data_parser.data_parser import DataParser
from semantic_representation.semantic_representation import SemanticRepresentation

def test_light_mode():
    """测试轻量模式"""
    
    # 开始日志会话
    log_path = processing_logger.start_session("light_mode_test")
    print(f"日志文件: {log_path}")
    
    # 创建解析器和语义表征器
    config = {
        'parsing': {
            'mode': 1,  # 轻量模式
            'light_mode_max_length': 256
        },
        'parsers': {
            'image': {
                'use_ocr': True,
                'ocr_engine': 'paddleocr'
            }
        }
    }
    
    data_parser = DataParser(config)
    semantic_repr = SemanticRepresentation(config)
    
    # 测试文件路径（使用项目中的测试文件）
    test_files = [
        "d:\\jiangweipeng\\trae_code\\file_analyzer\\test_data\\sample.pdf",
        "d:\\jiangweipeng\\trae_code\\file_analyzer\\data_test_debug\\教育部学籍在线验证报告_张美娜-学士.pdf",
    ]
    
    for file_path in test_files:
        print(f"\n检查文件: {file_path}")
        print(f"  存在: {os.path.exists(file_path)}")
        if not os.path.exists(file_path):
            print(f"  文件不存在，跳过")
            continue
        
        print(f"\n{'='*80}")
        print(f"测试文件: {file_path}")
        print(f"{'='*80}")
        
        try:
            # 1. 数据解析（轻量模式）
            print("\n[1] 数据解析（轻量模式）...")
            blocks = data_parser.parse_file(file_path, parsing_mode=1)
            print(f"    生成数据块数量: {len(blocks)}")
            
            for i, block in enumerate(blocks):
                modality = str(block.modality) if hasattr(block, 'modality') else 'UNKNOWN'
                print(f"    数据块 {i+1}: {block.block_id}, 类型: {modality}")
            
            # 2. 语义表征（整合首页所有数据块）
            if blocks:
                print("\n[2] 语义表征（整合首页数据块）...")
                semantic_block = semantic_repr.represent_first_page_blocks(
                    blocks=blocks,
                    db_manager=None,
                    file_id=None,
                    max_length=256
                )
                
                print(f"    语义块ID: {semantic_block.block_id}")
                print(f"    文本描述长度: {len(semantic_block.text_description)}")
                print(f"    关键词数量: {len(semantic_block.keywords)}")
                print(f"    关键词: {', '.join(semantic_block.keywords[:5])}")
                print(f"    是否有向量: {semantic_block.semantic_vector is not None}")
                if semantic_block.semantic_vector is not None:
                    print(f"    向量维度: {len(semantic_block.semantic_vector)}")
                
                print(f"\n    文本描述预览:")
                preview = semantic_block.text_description[:200]
                print(f"    {preview}...")
        
        except Exception as e:
            print(f"    错误: {e}")
            import traceback
            traceback.print_exc()
    
    # 结束日志会话
    processing_logger.end_session()
    print(f"\n测试完成！日志文件: {log_path}")

if __name__ == "__main__":
    test_light_mode()
