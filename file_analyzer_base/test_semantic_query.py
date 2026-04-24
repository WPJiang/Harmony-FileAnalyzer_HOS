"""语义查询模块测试脚本"""

import os
import sys

# 添加项目目录到路径
base_dir = os.path.dirname(os.path.abspath(__file__))
if base_dir not in sys.path:
    sys.path.insert(0, base_dir)

from database import DatabaseManager
from semantic_query import SemanticQuery


def test_semantic_query():
    """测试语义查询功能"""
    print("=" * 60)
    print("语义查询模块测试")
    print("=" * 60)
    
    # 初始化数据库
    db_manager = DatabaseManager()
    
    # 检查数据库中是否有语义块
    try:
        import sqlite3
        conn = sqlite3.connect(db_manager.db_path)
        cursor = conn.cursor()
        
        cursor.execute("SELECT COUNT(*) FROM semantic_blocks")
        block_count = cursor.fetchone()[0]
        print(f"\n数据库中语义块数量: {block_count}")
        
        if block_count == 0:
            print("警告: 数据库中没有语义块，无法进行搜索测试")
            print("请先运行文件分析流程生成语义块")
            conn.close()
            return
        
        # 显示一些示例语义块
        cursor.execute("SELECT semantic_block_id, text_description FROM semantic_blocks LIMIT 3")
        rows = cursor.fetchall()
        print("\n示例语义块:")
        for row in rows:
            print(f"  - {row[0]}: {row[1][:50]}...")
        
        conn.close()
        
    except Exception as e:
        print(f"检查数据库失败: {e}")
        return
    
    # 创建语义查询器
    print("\n初始化语义查询器...")
    semantic_query = SemanticQuery(db_manager=db_manager)
    
    # 执行测试查询
    test_queries = [
        "公务员报名材料",
        "学历验证报告",
        "个人简历",
    ]
    
    for query in test_queries:
        print("\n" + "-" * 60)
        print(f"测试查询: '{query}'")
        print("-" * 60)
        
        try:
            result = semantic_query.search(query, top_k=5, top_m=3)
            
            print(f"查询文本: {result.query_text}")
            print(f"找到 {len(result.files)} 个相关文件:")
            
            for i, file_result in enumerate(result.files, 1):
                print(f"\n  {i}. {file_result.file_name}")
                print(f"     路径: {file_result.file_path}")
                print(f"     相似度: {file_result.similarity_score:.2%}")
                print(f"     匹配语义块: {len(file_result.matched_blocks)}个")
            
        except Exception as e:
            print(f"查询失败: {e}")
            import traceback
            traceback.print_exc()
    
    # 检查用户查询表
    print("\n" + "=" * 60)
    print("检查用户查询记录")
    print("=" * 60)
    
    try:
        queries = db_manager.get_user_queries(limit=10)
        print(f"\n用户查询历史 ({len(queries)} 条):")
        for q in queries:
            print(f"  - {q.query_text} (K={q.top_k}, M={q.top_m}, 结果={q.result_count})")
    except Exception as e:
        print(f"获取查询历史失败: {e}")
    
    print("\n" + "=" * 60)
    print("测试完成")
    print("=" * 60)


if __name__ == "__main__":
    test_semantic_query()
