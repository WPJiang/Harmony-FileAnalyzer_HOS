import sys
sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

print("测试开始")

from database import DatabaseManager
db = DatabaseManager()
print(f"DB: {db.db_path}")

# 测试添加语义块
result = db.add_semantic_block(
    semantic_block_id="test_debug_001",
    data_block_ids=[1, 2, 3],
    file_id=310,  # 使用已存在的文件ID
    text_description="测试描述",
    keywords=["测试"],
    semantic_vector=None
)
print(f"添加结果: {result}")

# 查询
import sqlite3
conn = sqlite3.connect(db.db_path)
cursor = conn.cursor()
cursor.execute('SELECT * FROM semantic_blocks WHERE file_id = 310')
rows = cursor.fetchall()
print(f"查询到 {len(rows)} 个语义块")
for r in rows:
    print(f"  ID: {r[0]}, semantic_block_id: {r[1]}, data_block_ids: {r[2]}")

conn.close()
db.close()
print("测试完成")
