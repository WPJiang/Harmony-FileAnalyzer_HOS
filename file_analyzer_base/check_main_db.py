#!/usr/bin/env python3
"""检查主数据库"""
import sys
sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

from database import DatabaseManager

db = DatabaseManager()
print(f"数据库路径: {db.db_path}")

# 获取所有文件 - 使用SQL查询
import sqlite3
conn = sqlite3.connect(db.db_path)
cursor = conn.cursor()
cursor.execute('SELECT * FROM files')
rows = cursor.fetchall()
print(f"\n数据库中的文件数量: {len(rows)}")
files = rows

for f in files[:5]:
    print(f"  - {f[2]} (ID: {f[0]}, Status: {f[8]})")
    # 检查数据块
    blocks = db.get_data_blocks_by_file(f[0])
    print(f"    数据块: {len(blocks)}")
    # 检查语义块
    semantic_blocks = db.get_semantic_blocks_by_file(f[0])
    print(f"    语义块: {len(semantic_blocks)}")

db.close()
