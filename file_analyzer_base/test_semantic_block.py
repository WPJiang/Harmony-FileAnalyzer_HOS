#!/usr/bin/env python3
"""测试语义块写入功能"""
import sys
sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

from database import DatabaseManager

# 初始化数据库
db = DatabaseManager(r'd:\jiangweipeng\trae_code\file_analyzer\test_file_analyzer.db')

# 测试添加语义块
try:
    result = db.add_semantic_block(
        semantic_block_id="test_block_001",
        data_block_ids=[1, 2, 3],
        file_id=1,
        text_description="测试语义块",
        keywords=["测试", "语义块"],
        semantic_vector=None
    )
    print(f"添加语义块结果: {result}")
    
    # 查询语义块
    blocks = db.get_semantic_blocks_by_file(1)
    print(f"查询到 {len(blocks)} 个语义块")
    for block in blocks:
        print(f"  - ID: {block.id}, semantic_block_id: {block.semantic_block_id}")
        print(f"    data_block_ids: {block.data_block_ids}")
        
except Exception as e:
    print(f"错误: {e}")
    import traceback
    traceback.print_exc()
finally:
    db.close()
    print("测试完成")
