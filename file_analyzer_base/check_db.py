#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""检查数据库中文件状态"""
import sys
import os
import sqlite3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

db_path = 'd:\\jiangweipeng\\trae_code\\file_analyzer\\file_analyzer.db'
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# 检查语义块表结构
cursor.execute("PRAGMA table_info(semantic_blocks)")
columns = cursor.fetchall()
print('semantic_blocks表结构:')
for col in columns:
    print(f'  {col[1]}: {col[2]} (notnull: {col[3]}, default: {col[4]})')

conn.close()
