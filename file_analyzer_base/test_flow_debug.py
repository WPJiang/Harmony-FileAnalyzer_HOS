#!/usr/bin/env python3
"""模拟完整分析流程"""
import sys
import os

sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

from database import DatabaseManager, FileStatus
from data_parser import DataParser
from semantic_representation import SemanticRepresentation

# 使用主数据库
db = DatabaseManager()
print(f"数据库路径: {db.db_path}")

# 获取一个已分析的文件
import sqlite3
conn = sqlite3.connect(db.db_path)
cursor = conn.cursor()
cursor.execute('SELECT * FROM files LIMIT 1')
row = cursor.fetchone()
if row:
    file_path = row[1]  # file_path
    file_id = row[0]    # id
    print(f"测试文件: {file_path}")
    print(f"文件ID: {file_id}")
else:
    print("没有找到文件")
    exit()

# 检查数据块
cursor.execute('SELECT * FROM data_blocks WHERE file_id = ?', (file_id,))
data_blocks = cursor.fetchall()
print(f"数据块数量: {len(data_blocks)}")
for db_block in data_blocks[:3]:
    print(f"  - block_id: {db_block[1]}, id: {db_block[0]}")

# 检查语义块
cursor.execute('SELECT * FROM semantic_blocks WHERE file_id = ?', (file_id,))
semantic_blocks = cursor.fetchall()
print(f"语义块数量: {len(semantic_blocks)}")

# 模拟语义表征流程
print("\n开始模拟语义表征...")

# 解析文件
parser = DataParser()
blocks = parser.parse_file(file_path, db, file_id)
print(f"解析出 {len(blocks)} 个数据块")

if blocks:
    # 检查是否为轻量模式
    first_block = blocks[0]
    print(f"第一个数据块 metadata: {getattr(first_block, 'metadata', None)}")
    
    is_light_mode_first_page = False
    if hasattr(first_block, 'metadata') and first_block.metadata:
        if first_block.metadata.get('parsing_mode') == 'light_first_page':
            is_light_mode_first_page = True
    
    print(f"is_light_mode_first_page: {is_light_mode_first_page}")
    print(f"len(blocks) > 1: {len(blocks) > 1}")
    
    # 语义表征
    semantic_rep = SemanticRepresentation()
    
    if is_light_mode_first_page and len(blocks) > 1:
        print("使用 represent_first_page_blocks...")
        try:
            sb = semantic_rep.represent_first_page_blocks(
                blocks=blocks,
                db_manager=db,
                file_id=file_id,
                max_length=256
            )
            print(f"生成语义块: {sb.block_id}")
        except Exception as e:
            print(f"错误: {e}")
            import traceback
            traceback.print_exc()
    else:
        print("使用 represent...")
        for block in blocks[:1]:  # 只测试第一个
            # 获取数据块ID
            db_blocks = db.get_data_blocks_by_file(file_id)
            data_block_id = None
            for db_block in db_blocks:
                if db_block.block_id == block.block_id:
                    data_block_id = db_block.id
                    break
            
            print(f"数据块ID: {data_block_id}")
            
            try:
                sb = semantic_rep.represent(block, db, data_block_id, file_id)
                print(f"生成语义块: {sb.block_id}")
            except Exception as e:
                print(f"错误: {e}")
                import traceback
                traceback.print_exc()

# 再次检查语义块
cursor.execute('SELECT * FROM semantic_blocks WHERE file_id = ?', (file_id,))
semantic_blocks = cursor.fetchall()
print(f"\n最终语义块数量: {len(semantic_blocks)}")
for sb in semantic_blocks:
    print(f"  - semantic_block_id: {sb[1]}, data_block_ids: {sb[2]}")

conn.close()
db.close()
