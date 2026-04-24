#!/usr/bin/env python3
"""调试测试"""
import sys
import os

sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

print("步骤1: 导入模块...")
from database import DatabaseManager, FileStatus
from directory_scanner import DirectoryScanner

print("步骤2: 初始化数据库...")
db_path = r'd:\jiangweipeng\trae_code\file_analyzer\debug.db'
if os.path.exists(db_path):
    os.remove(db_path)
db = DatabaseManager(db_path)
print(f"  数据库已初始化: {db_path}")

print("步骤3: 扫描目录...")
scanner = DirectoryScanner()
test_dir = r'D:\张美娜-公务员-2025'
files = scanner.scan_directory(test_dir, db_manager=db)
print(f"  扫描到 {len(files)} 个文件")

print("步骤4: 检查数据库中的文件...")
file_records = db.get_files_by_directory(test_dir)
print(f"  数据库中有 {len(file_records)} 个文件记录")

if file_records:
    for fr in file_records[:3]:
        print(f"    - {fr.file_name}, ID: {fr.id}, Status: {fr.analysis_status}")
else:
    print("  错误: 数据库中没有文件记录!")

print("步骤5: 测试获取文件ID...")
test_file = files[0] if files else None
if test_file:
    print(f"  测试文件: {test_file}")
    file_record = db.get_file_by_path(test_file)
    if file_record:
        print(f"  文件ID: {file_record.id}")
    else:
        print("  错误: 无法获取文件记录!")

db.close()
print("\n调试完成")
