"""
PDF Parser 独立测试文件

功能:
1. 解析 PDF 文件，提取文本块和图片
2. 文本块保存为 txt_block_id.txt 格式
3. 图片保存为 pic_block_id.{ext} 格式

使用方法:
    python tests/test_pdf_parser.py <pdf文件路径>
    
    或
    
    python tests/test_pdf_parser.py
    # 默认读取 data_test_debug 目录下的 test.pdf

输出目录:
    data_test_debug/pdf_output/<pdf文件名>/
    - txt_<block_id>.txt    # 文本块
    - pic_<block_id>.png    # 图片块
    - summary.txt           # 解析摘要
"""

import os
import sys
import json
from pathlib import Path
from datetime import datetime

# 添加项目根目录到路径
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from data_parser import PDFParser, DataBlock, ModalityType


# 测试数据目录
TEST_DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'data_test_debug')
OUTPUT_DIR = os.path.join(TEST_DATA_DIR, 'pdf_output')


def save_text_block(block: DataBlock, output_dir: str, index: int) -> str:
    """保存文本块到文件
    
    Args:
        block: 数据块
        output_dir: 输出目录
        index: 块索引
        
    Returns:
        保存的文件路径
    """
    # 生成文件名: txt_<block_id>.txt
    safe_block_id = str(block.block_id).replace('/', '_').replace('\\', '_').replace(':', '_')
    filename = f"txt_{safe_block_id}.txt"
    filepath = os.path.join(output_dir, filename)
    
    # 构建内容
    content_lines = [
        "=" * 60,
        f"Block ID: {block.block_id}",
        f"Type: {block.modality.value if hasattr(block.modality, 'value') else block.modality}",
        f"Page Number: {block.page_number}",
        f"File Path: {block.file_path}",
        f"Metadata: {json.dumps(block.metadata, ensure_ascii=False, indent=2)}",
        "=" * 60,
        "",
        "CONTENT:",
        "-" * 60,
        block.text_content if block.text_content else "",
        "",
        "=" * 60,
    ]
    
    # 写入文件
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write('\n'.join(content_lines))
    
    return filepath


def save_image_block(block: DataBlock, output_dir: str, index: int) -> str:
    """保存图片块到文件
    
    Args:
        block: 数据块
        output_dir: 输出目录
        index: 块索引
        
    Returns:
        保存的文件路径
    """
    # 从 metadata 获取图片扩展名
    ext = block.metadata.get('image_ext', 'png') if hasattr(block, 'metadata') else 'png'
    if ext == 'unknown' or not ext:
        ext = 'png'
    
    # 生成文件名: pic_<block_id>.<ext>
    safe_block_id = str(block.block_id).replace('/', '_').replace('\\', '_').replace(':', '_')
    filename = f"pic_{safe_block_id}.{ext}"
    filepath = os.path.join(output_dir, filename)
    
    # 写入图片二进制数据
    if hasattr(block, 'content') and block.content:
        if isinstance(block.content, bytes):
            with open(filepath, 'wb') as f:
                f.write(block.content)
        else:
            # 如果 content 不是 bytes，尝试转换
            with open(filepath, 'wb') as f:
                f.write(str(block.content).encode('utf-8'))
    
    # 同时保存图片信息文本文件
    info_filename = f"pic_{safe_block_id}_info.txt"
    info_filepath = os.path.join(output_dir, info_filename)
    
    info_lines = [
        "=" * 60,
        f"Block ID: {block.block_id}",
        f"Type: {block.modality.value if hasattr(block.modality, 'value') else block.modality}",
        f"Page Number: {block.page_number}",
        f"File Path: {block.file_path}",
        f"Text Content: {block.text_content}",
        f"Metadata: {json.dumps(block.metadata, ensure_ascii=False, indent=2)}",
        "=" * 60,
    ]
    
    with open(info_filepath, 'w', encoding='utf-8') as f:
        f.write('\n'.join(info_lines))
    
    return filepath


def save_table_block(block: DataBlock, output_dir: str, index: int) -> str:
    """保存表格块到文件
    
    Args:
        block: 数据块
        output_dir: 输出目录
        index: 块索引
        
    Returns:
        保存的文件路径
    """
    # 生成文件名: table_<block_id>.txt
    safe_block_id = str(block.block_id).replace('/', '_').replace('\\', '_').replace(':', '_')
    filename = f"table_{safe_block_id}.txt"
    filepath = os.path.join(output_dir, filename)
    
    # 构建内容
    content_lines = [
        "=" * 60,
        f"Block ID: {block.block_id}",
        f"Type: {block.modality.value if hasattr(block.modality, 'value') else block.modality}",
        f"Page Number: {block.page_number}",
        f"File Path: {block.file_path}",
        f"Metadata: {json.dumps(block.metadata, ensure_ascii=False, indent=2)}",
        "=" * 60,
        "",
        "TABLE CONTENT:",
        "-" * 60,
        block.text_content if block.text_content else "",
        "",
        "=" * 60,
    ]
    
    # 写入文件
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write('\n'.join(content_lines))
    
    return filepath


def save_summary(blocks: list, output_dir: str, pdf_path: str, parse_time: float) -> str:
    """保存解析摘要
    
    Args:
        blocks: 所有数据块
        output_dir: 输出目录
        pdf_path: PDF 文件路径
        parse_time: 解析耗时（秒）
        
    Returns:
        保存的文件路径
    """
    filepath = os.path.join(output_dir, "summary.txt")
    
    # 统计各类型块数量
    text_count = sum(1 for b in blocks if 'TEXT' in str(b.modality))
    image_count = sum(1 for b in blocks if 'IMAGE' in str(b.modality))
    table_count = sum(1 for b in blocks if 'TABLE' in str(b.modality))
    
    # 构建摘要内容
    summary_lines = [
        "=" * 60,
        "PDF 解析摘要",
        "=" * 60,
        f"解析时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"PDF 文件: {pdf_path}",
        f"解析耗时: {parse_time:.2f} 秒",
        "-" * 60,
        "统计信息:",
        f"  总块数: {len(blocks)}",
        f"  文本块: {text_count}",
        f"  图片块: {image_count}",
        f"  表格块: {table_count}",
        "-" * 60,
        "详细列表:",
    ]
    
    for i, block in enumerate(blocks):
        modality = block.modality.value if hasattr(block.modality, 'value') else str(block.modality)
        summary_lines.append(f"  [{i+1}] {modality:10} | Page {block.page_number:3} | ID: {block.block_id}")
    
    summary_lines.extend([
        "=" * 60,
    ])
    
    # 写入文件
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write('\n'.join(summary_lines))
    
    return filepath


def parse_pdf_and_save(pdf_path: str, output_base_dir: str = None) -> dict:
    """解析 PDF 并保存所有块到文件
    
    Args:
        pdf_path: PDF 文件路径
        output_base_dir: 输出基础目录，默认为 data_test_debug/pdf_output
        
    Returns:
        解析结果字典
    """
    import time
    
    # 检查文件
    if not os.path.exists(pdf_path):
        raise FileNotFoundError(f"PDF 文件不存在: {pdf_path}")
    
    # 确定输出目录
    if output_base_dir is None:
        output_base_dir = OUTPUT_DIR
    
    pdf_name = Path(pdf_path).stem
    output_dir = os.path.join(output_base_dir, pdf_name)
    
    # 创建输出目录
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"\n开始解析 PDF: {pdf_path}")
    print(f"输出目录: {output_dir}")
    print("-" * 60)
    
    # 解析 PDF
    parser = PDFParser()
    start_time = time.time()
    blocks = parser.parse(pdf_path)
    parse_time = time.time() - start_time
    
    print(f"解析完成，共 {len(blocks)} 个数据块")
    print("-" * 60)
    
    # 保存各类型块
    saved_files = {
        'text': [],
        'image': [],
        'table': [],
        'summary': None
    }
    
    for i, block in enumerate(blocks):
        modality_str = str(block.modality)
        
        if 'TEXT' in modality_str:
            filepath = save_text_block(block, output_dir, i)
            saved_files['text'].append(filepath)
            print(f"  [文本] {os.path.basename(filepath)}")
            
        elif 'IMAGE' in modality_str:
            filepath = save_image_block(block, output_dir, i)
            saved_files['image'].append(filepath)
            print(f"  [图片] {os.path.basename(filepath)}")
            
        elif 'TABLE' in modality_str:
            filepath = save_table_block(block, output_dir, i)
            saved_files['table'].append(filepath)
            print(f"  [表格] {os.path.basename(filepath)}")
    
    # 保存摘要
    summary_path = save_summary(blocks, output_dir, pdf_path, parse_time)
    saved_files['summary'] = summary_path
    print(f"  [摘要] {os.path.basename(summary_path)}")
    
    print("-" * 60)
    print(f"所有文件已保存到: {output_dir}")
    
    return {
        'pdf_path': pdf_path,
        'output_dir': output_dir,
        'blocks_count': len(blocks),
        'text_count': len(saved_files['text']),
        'image_count': len(saved_files['image']),
        'table_count': len(saved_files['table']),
        'saved_files': saved_files,
        'parse_time': parse_time
    }


def test_single_pdf(pdf_path: str = None):
    """测试单个 PDF 文件"""
    if pdf_path is None:
        # 默认测试文件
        pdf_path = os.path.join(TEST_DATA_DIR, 'test.pdf')
    
    if not os.path.exists(pdf_path):
        print(f"错误: 找不到 PDF 文件: {pdf_path}")
        print(f"请将 PDF 文件放入 {TEST_DATA_DIR} 目录")
        return False
    
    try:
        result = parse_pdf_and_save(pdf_path)
        
        print("\n" + "=" * 60)
        print("解析结果统计:")
        print(f"  文本块: {result['text_count']}")
        print(f"  图片块: {result['image_count']}")
        print(f"  表格块: {result['table_count']}")
        print(f"  解析耗时: {result['parse_time']:.2f} 秒")
        print("=" * 60)
        
        return True
        
    except Exception as e:
        print(f"解析失败: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_multiple_pdfs():
    """测试多个 PDF 文件"""
    # 查找测试目录中的所有 PDF 文件
    if not os.path.exists(TEST_DATA_DIR):
        print(f"错误: 测试目录不存在: {TEST_DATA_DIR}")
        return
    
    pdf_files = [
        f for f in os.listdir(TEST_DATA_DIR)
        if f.lower().endswith('.pdf')
    ]
    
    if not pdf_files:
        print(f"在 {TEST_DATA_DIR} 目录中没有找到 PDF 文件")
        return
    
    print(f"\n找到 {len(pdf_files)} 个 PDF 文件:")
    for f in pdf_files:
        print(f"  - {f}")
    print()
    
    # 逐个解析
    success_count = 0
    for pdf_name in pdf_files:
        pdf_path = os.path.join(TEST_DATA_DIR, pdf_name)
        print(f"\n{'='*60}")
        print(f"处理: {pdf_name}")
        print('='*60)
        
        if test_single_pdf(pdf_path):
            success_count += 1
    
    print(f"\n{'='*60}")
    print(f"测试完成: {success_count}/{len(pdf_files)} 个文件解析成功")
    print('='*60)


def main():
    """主函数"""
    print("=" * 60)
    print("PDF Parser 独立测试工具")
    print("=" * 60)
    
    # 解析命令行参数
    if len(sys.argv) > 1:
        pdf_path = sys.argv[1]
        if os.path.exists(pdf_path):
            test_single_pdf(pdf_path)
        else:
            print(f"错误: 文件不存在: {pdf_path}")
    else:
        # 没有参数，测试所有 PDF 文件
        test_multiple_pdfs()


if __name__ == '__main__':
    main()
