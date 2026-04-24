#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
OCR内存优化测试脚本

测试OCR多次调用过程中的内存使用情况，验证内存优化效果。
"""

import os
import sys
import gc
import time

# 添加项目路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from models.model_manager import get_model_manager, get_ocr_instance


def get_memory_usage():
    """获取当前内存使用（MB）"""
    try:
        import psutil
        process = psutil.Process(os.getpid())
        return process.memory_info().rss / 1024 / 1024
    except ImportError:
        return 0


def test_ocr_memory(test_image_path: str, iterations: int = 5):
    """测试OCR内存使用情况"""
    if not os.path.exists(test_image_path):
        print(f"测试图片不存在: {test_image_path}")
        return

    print("=" * 60)
    print("OCR内存优化测试")
    print("=" * 60)
    print(f"测试图片: {test_image_path}")
    print(f"测试次数: {iterations}")
    print()

    # 初始内存
    gc.collect()
    initial_memory = get_memory_usage()
    print(f"初始内存: {initial_memory:.2f} MB")
    print()

    # 获取OCR实例
    print("正在加载OCR模型...")
    ocr_func = get_ocr_instance(use_ocr=True)
    if ocr_func is None:
        print("OCR模型加载失败")
        return

    model_loaded_memory = get_memory_usage()
    print(f"模型加载后内存: {model_loaded_memory:.2f} MB (+{model_loaded_memory - initial_memory:.2f} MB)")
    print()

    # 多次执行OCR
    print("开始OCR测试...")
    print("-" * 60)

    memories = []
    for i in range(iterations):
        iter_start_mem = get_memory_usage()
        start_time = time.time()

        # 执行OCR
        result = ocr_func(test_image_path)

        elapsed = time.time() - start_time
        iter_end_mem = get_memory_usage()

        memories.append(iter_end_mem)

        print(f"迭代 {i+1}/{iterations}:")
        print(f"  耗时: {elapsed:.2f}s")
        print(f"  内存: {iter_end_mem:.2f} MB (本次+{iter_end_mem - iter_start_mem:.2f} MB)")
        print(f"  结果长度: {len(result) if result else 0} 字符")
        print()

    # 最终统计
    print("-" * 60)
    print("测试结果汇总:")
    print(f"  初始内存: {initial_memory:.2f} MB")
    print(f"  最终内存: {memories[-1]:.2f} MB")
    print(f"  内存增长: {memories[-1] - initial_memory:.2f} MB")
    print(f"  峰值内存: {max(memories):.2f} MB")
    print(f"  平均每次迭代内存: {sum(memories) / len(memories):.2f} MB")

    # 检查内存是否稳定
    memory_increases = [memories[i] - memories[i-1] for i in range(1, len(memories))]
    avg_increase = sum(memory_increases) / len(memory_increases)
    print(f"  平均每次迭代内存变化: {avg_increase:+.2f} MB")

    if avg_increase < 10:
        print("\n✓ 内存优化效果良好，内存增长控制在合理范围内")
    else:
        print("\n⚠ 内存仍有显著增长，可能需要进一步优化")

    print("=" * 60)


def test_image_parser_memory(test_image_dir: str):
    """测试ImageParser内存使用情况"""
    from data_parser.image_parser import ImageParser

    print("\n" + "=" * 60)
    print("ImageParser内存优化测试")
    print("=" * 60)

    # 查找测试图片
    test_images = []
    for ext in ['.jpg', '.jpeg', '.png']:
        for f in os.listdir(test_image_dir):
            if f.lower().endswith(ext):
                test_images.append(os.path.join(test_image_dir, f))
                if len(test_images) >= 3:
                    break
        if len(test_images) >= 3:
            break

    if not test_images:
        print(f"在 {test_image_dir} 中未找到测试图片")
        return

    print(f"找到 {len(test_images)} 张测试图片")
    print()

    # 初始内存
    gc.collect()
    initial_memory = get_memory_usage()
    print(f"初始内存: {initial_memory:.2f} MB")
    print()

    # 创建解析器
    parser = ImageParser(use_ocr=True, ocr_engine='paddleocr')

    print("开始解析测试...")
    print("-" * 60)

    memories = []
    for i, image_path in enumerate(test_images):
        iter_start_mem = get_memory_usage()
        start_time = time.time()

        # 解析图片
        blocks = parser.parse(image_path)

        elapsed = time.time() - start_time
        iter_end_mem = get_memory_usage()

        memories.append(iter_end_mem)

        print(f"图片 {i+1}/{len(test_images)}: {os.path.basename(image_path)}")
        print(f"  耗时: {elapsed:.2f}s")
        print(f"  内存: {iter_end_mem:.2f} MB (本次+{iter_end_mem - iter_start_mem:.2f} MB)")
        print(f"  生成数据块: {len(blocks)} 个")
        print()

    # 最终统计
    print("-" * 60)
    print("测试结果汇总:")
    print(f"  初始内存: {initial_memory:.2f} MB")
    print(f"  最终内存: {memories[-1]:.2f} MB")
    print(f"  内存增长: {memories[-1] - initial_memory:.2f} MB")
    print(f"  峰值内存: {max(memories):.2f} MB")

    print("=" * 60)


if __name__ == '__main__':
    # 查找测试目录
    test_dirs = [
        r'D:\张美娜-公务员-2025',
        os.path.expanduser('~/test_images'),
        os.path.dirname(os.path.abspath(__file__))
    ]

    test_dir = None
    for d in test_dirs:
        if os.path.exists(d):
            test_dir = d
            break

    if test_dir is None:
        print("未找到测试目录，请指定测试图片路径")
        sys.exit(1)

    print(f"使用测试目录: {test_dir}")
    print()

    # 查找测试图片
    test_image = None
    for ext in ['.jpg', '.jpeg', '.png']:
        for f in os.listdir(test_dir):
            if f.lower().endswith(ext):
                test_image = os.path.join(test_dir, f)
                break
        if test_image:
            break

    if test_image:
        # 测试OCR内存
        test_ocr_memory(test_image, iterations=5)

        # 测试ImageParser内存
        test_image_parser_memory(test_dir)
    else:
        print(f"在 {test_dir} 中未找到测试图片")
