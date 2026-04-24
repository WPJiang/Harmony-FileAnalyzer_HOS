import psutil
import os
import time

def test_memory():
    # 初始内存
    init_mem = get_memory_usage()
    print(f"初始内存：{init_mem:.2f} MB")
    
    # 优化前调用10次
    ocr = PaddleOCR(use_angle_cls=True, lang='ch')
    for i in range(10):
        ocr.ocr("test.jpg")
    print(f"优化前10次调用后：{get_memory_usage():.2f} MB")
    
    # 重置环境
    del ocr
    clear_paddle_cache()
    time.sleep(2)
    
    # 优化后调用10次（单例+清理）
    for i in range(10):
        ocr_process("test.jpg")
    print(f"优化后10次调用后：{get_memory_usage():.2f} MB")

test_memory()