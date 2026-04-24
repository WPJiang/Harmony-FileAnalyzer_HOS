#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""重现问题"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from data_parser.data_parser import DataParser
from semantic_representation.semantic_representation import SemanticRepresentation

# 测试文件
test_file = 'D:/张美娜-公务员-2025/教育部学籍在线验证报告_张美娜-学士.pdf'

print(f'测试文件: {test_file}')
print(f'文件存在: {os.path.exists(test_file)}')

# 配置
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

# 创建解析器和语义表征器
data_parser = DataParser(config)
semantic_rep = SemanticRepresentation(config)

# 解析文件
print('\n[1] 解析文件...')
blocks = data_parser.parse_file(test_file, parsing_mode=1)
print(f'生成数据块数量: {len(blocks)}')

for i, block in enumerate(blocks):
    modality = str(block.modality) if hasattr(block, 'modality') else 'UNKNOWN'
    metadata = block.metadata if hasattr(block, 'metadata') else {}
    print(f'  块{i+1}: {block.block_id}, 类型: {modality}')
    print(f'    元数据: {metadata}')

# 检查是否为轻量模式首页
is_light_mode_first_page = False
if blocks and len(blocks) > 0:
    first_block = blocks[0]
    if hasattr(first_block, 'metadata') and first_block.metadata:
        if first_block.metadata.get('parsing_mode') == 'light_first_page':
            is_light_mode_first_page = True

print(f'\n[2] 检查轻量模式首页标记: {is_light_mode_first_page}')
print(f'    数据块数量: {len(blocks)}')

# 语义表征
if is_light_mode_first_page and len(blocks) > 1:
    print('\n[3] 使用 represent_first_page_blocks 整合...')
    try:
        max_length = config.get('parsing', {}).get('light_mode_max_length', 256)
        sb = semantic_rep.represent_first_page_blocks(
            blocks=blocks,
            db_manager=None,
            file_id=None,
            max_length=max_length
        )
        print(f'成功生成语义块: {sb.block_id}')
        print(f'文本描述长度: {len(sb.text_description)}')
        print(f'关键词: {sb.keywords}')
    except Exception as e:
        print(f'错误: {e}')
        import traceback
        traceback.print_exc()
else:
    print('\n[3] 逐个处理数据块...')
    for block in blocks:
        try:
            sb = semantic_rep.represent(block, None, None, None)
            print(f'  语义块: {sb.block_id}')
        except Exception as e:
            print(f'  错误: {e}')
