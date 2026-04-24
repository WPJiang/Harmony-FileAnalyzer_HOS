"""
测试日志系统是否正常工作
"""
import sys
import os

# 添加项目根目录到路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from logger import processing_logger

def test_logger():
    """测试日志系统"""
    print("开始测试日志系统...")
    
    # 开始会话
    log_path = processing_logger.start_session("test_log_system")
    print(f"日志文件路径: {log_path}")
    
    # 检查日志文件是否存在
    if os.path.exists(log_path):
        print(f"✓ 日志文件已成功创建")
    else:
        print(f"✗ 日志文件未创建")
        return
    
    # 记录一些测试日志
    processing_logger.log_module_start("TestModule", "test_file.txt", {"test": True})
    processing_logger.log_step("测试步骤", "这是一个测试步骤")
    processing_logger.log_module_end("TestModule", success=True)
    
    # 结束会话
    processing_logger.end_session()
    print("✓ 日志会话已结束")
    
    # 读取日志文件内容
    with open(log_path, 'r', encoding='utf-8') as f:
        content = f.read()
        print(f"\n日志文件内容预览:\n{content[:500]}...")
    
    print(f"\n✓ 日志系统测试完成")
    print(f"日志文件位置: {log_path}")

if __name__ == "__main__":
    test_logger()
