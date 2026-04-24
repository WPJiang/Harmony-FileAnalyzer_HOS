import sys
sys.path.insert(0, r'd:\jiangweipeng\trae_code\file_analyzer')

print("开始测试...")

from database import DatabaseManager
print("导入 DatabaseManager 成功")

db = DatabaseManager(r'd:\jiangweipeng\trae_code\file_analyzer\test_simple.db')
print("数据库初始化成功")

# 测试添加语义块
result = db.add_semantic_block(
    semantic_block_id="test_001",
    data_block_ids=[1, 2],
    file_id=1,
    text_description="测试",
    keywords=["测试"],
    semantic_vector=None
)
print(f"添加语义块结果: {result}")

# 查询
blocks = db.get_semantic_blocks_by_file(1)
print(f"查询到 {len(blocks)} 个语义块")

db.close()
print("测试完成")
