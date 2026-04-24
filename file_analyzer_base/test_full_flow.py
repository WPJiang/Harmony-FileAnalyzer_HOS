#!/usr/bin/env python3
"""测试完整流程：扫描->解析->语义表征"""
import sys
import os

sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

from database import DatabaseManager, FileStatus
from directory_scanner import DirectoryScanner
from data_parser import DataParser
from semantic_representation import SemanticRepresentation

# 测试目录
test_dir = r'D:\张美娜-公务员-2025'
db_path = r'd:\jiangweipeng\trae_code\file_analyzer\test_flow.db'

# 删除旧数据库
if os.path.exists(db_path):
    os.remove(db_path)
    print(f"删除旧数据库: {db_path}")

# 初始化组件
db = DatabaseManager(db_path)
scanner = DirectoryScanner()
parser = DataParser()
semantic_rep = SemanticRepresentation()

print("=" * 60)
print("步骤1: 扫描目录")
print("=" * 60)
files = scanner.scan_directory(test_dir, db_manager=db)
print(f"扫描到 {len(files)} 个文件")

# 检查数据库中的文件
file_records = db.get_files_by_directory(test_dir)
print(f"数据库中有 {len(file_records)} 个文件记录")

print("\n" + "=" * 60)
print("步骤2: 解析文件并生成语义块")
print("=" * 60)

# 只测试前2个PDF文件
pdf_files = [f for f in files if f.lower().endswith('.pdf')][:2]
print(f"测试文件: {pdf_files}")

for file_path in pdf_files:
    print(f"\n--- 处理文件: {os.path.basename(file_path)} ---")
    
    # 获取文件ID
    file_record = db.get_file_by_path(file_path)
    if not file_record:
        print(f"  错误: 文件未在数据库中找到")
        continue
    
    file_id = file_record.id
    print(f"  文件ID: {file_id}")
    
    # 解析文件
    try:
        blocks = parser.parse_file(file_path, db, file_id)
        print(f"  解析出 {len(blocks)} 个数据块")
        
        # 检查数据块是否写入数据库
        db_blocks = db.get_data_blocks_by_file(file_id)
        print(f"  数据库中有 {len(db_blocks)} 个数据块记录")
        
        if not blocks:
            print(f"  警告: 没有数据块，跳过语义表征")
            continue
        
        # 语义表征
        print(f"  开始语义表征...")
        
        # 检查是否为轻量模式首页
        is_light_mode_first_page = False
        if blocks and len(blocks) > 0:
            first_block = blocks[0]
            if hasattr(first_block, 'metadata') and first_block.metadata:
                if first_block.metadata.get('parsing_mode') == 'light_first_page':
                    is_light_mode_first_page = True
                    print(f"  检测到轻量模式首页，需要整合 {len(blocks)} 个数据块")
        
        if is_light_mode_first_page and len(blocks) > 1:
            # 轻量模式首页整合
            try:
                sb = semantic_rep.represent_first_page_blocks(
                    blocks=blocks,
                    db_manager=db,
                    file_id=file_id,
                    max_length=256
                )
                print(f"  首页整合完成，生成语义块: {sb.block_id}")
            except Exception as e:
                print(f"  首页整合失败: {e}")
                import traceback
                traceback.print_exc()
        else:
            # 逐个处理
            for block in blocks:
                try:
                    # 获取数据块ID
                    data_block_id = None
                    db_blocks = db.get_data_blocks_by_file(file_id)
                    for db_block in db_blocks:
                        if db_block.block_id == block.block_id:
                            data_block_id = db_block.id
                            break
                    
                    sb = semantic_rep.represent(block, db, data_block_id, file_id)
                    print(f"  生成语义块: {sb.block_id}")
                except Exception as e:
                    print(f"  语义表征失败: {e}")
        
        # 检查语义块是否写入数据库
        db_semantic_blocks = db.get_semantic_blocks_by_file(file_id)
        print(f"  数据库中有 {len(db_semantic_blocks)} 个语义块记录")
        for sb in db_semantic_blocks:
            print(f"    - {sb.semantic_block_id}, data_block_ids: {sb.data_block_ids}")
        
    except Exception as e:
        print(f"  处理失败: {e}")
        import traceback
        traceback.print_exc()

print("\n" + "=" * 60)
print("最终统计")
print("=" * 60)
all_files = db.get_files_by_directory(test_dir)
print(f"总文件数: {len(all_files)}")

for file_record in all_files[:3]:
    file_id = file_record.id
    blocks = db.get_data_blocks_by_file(file_id)
    semantic_blocks = db.get_semantic_blocks_by_file(file_id)
    print(f"  {file_record.file_name}: {len(blocks)} 数据块, {len(semantic_blocks)} 语义块")

db.close()
print("\n测试完成")
