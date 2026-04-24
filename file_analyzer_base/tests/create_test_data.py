import os
import shutil
import glob

# 创建测试数据集目录
test_data_dir = os.path.join(os.path.dirname(__file__), 'test_data')
os.makedirs(test_data_dir, exist_ok=True)
print(f"创建测试数据集目录: {test_data_dir}")

# 首先检查D盘是否存在
if not os.path.exists('D:'):
    print("D盘不存在，创建示例文件...")


    
    # 创建示例文本文件
    sample_text = os.path.join(test_data_dir, 'sample.txt')
    with open(sample_text, 'w', encoding='utf-8') as f:
        f.write("这是一个示例文本文件。\n包含一些测试内容。")
    print(f"创建示例文本文件: {sample_text}")
    
    # 创建示例PDF文件（模拟）
    sample_pdf = os.path.join(test_data_dir, 'sample.pdf')
    with open(sample_pdf, 'w', encoding='utf-8') as f:
        f.write("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF")
    print(f"创建示例PDF文件: {sample_pdf}")
    
else:
    # 支持的文件格式
    file_formats = {
        'pdf': ['*.pdf'],
        'word': ['*.doc', '*.docx'],
        'ppt': ['*.ppt', '*.pptx'],
        'image': ['*.jpg', '*.jpeg', '*.png', '*.gif'],
        'audio': ['*.wav', '*.mp3', '*.m4a', '*.flac']
    }
    
    # 从D盘查找文件
    d_drive = 'D:\\'
    print(f"从 {d_drive} 盘查找文件...")
    
    copied_files = {}
    
    for format_name, extensions in file_formats.items():
        print(f"\n查找 {format_name} 文件...")
        found = False
        
        for ext in extensions:
            # 先在根目录搜索
            search_pattern = os.path.join(d_drive, ext)
            files = glob.glob(search_pattern)
            
            # 如果根目录没有，再递归搜索
            if not files:
                search_pattern = os.path.join(d_drive, '**', ext)
                files = glob.glob(search_pattern, recursive=True)
            
            print(f"  搜索 {search_pattern}，找到 {len(files)} 个文件")
            
            for file_path in files:
                try:
                    # 检查文件是否为空
                    if os.path.getsize(file_path) > 0:
                        # 复制到测试数据目录
                        dest_file = os.path.join(test_data_dir, os.path.basename(file_path))
                        shutil.copy2(file_path, dest_file)
                        copied_files[format_name] = dest_file
                        print(f"  复制 {file_path} -> {dest_file}")
                        found = True
                        break
                except Exception as e:
                    print(f"  复制文件时出错: {e}")
            
            if found:
                break
        
        if not found:
            print(f"  未找到 {format_name} 文件")
    
    # 如果没有找到任何文件，创建示例文件
    if not copied_files:
        print("\n未找到任何文件，创建示例文件...")
        
        # 创建示例文本文件
        sample_text = os.path.join(test_data_dir, 'sample.txt')
        with open(sample_text, 'w', encoding='utf-8') as f:
            f.write("这是一个示例文本文件。\n包含一些测试内容。")
        print(f"创建示例文本文件: {sample_text}")
        
        # 创建示例PDF文件（模拟）
        sample_pdf = os.path.join(test_data_dir, 'sample.pdf')
        with open(sample_pdf, 'w', encoding='utf-8') as f:
            f.write("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF")
        print(f"创建示例PDF文件: {sample_pdf}")

print("\n" + "=" * 50)
print("复制结果:")
print("=" * 50)

# 列出测试数据目录中的所有文件
all_files = os.listdir(test_data_dir)
for file_name in all_files:
    file_path = os.path.join(test_data_dir, file_name)
    file_size = os.path.getsize(file_path)
    print(f"{file_name}: {file_size} bytes")

print(f"\n测试数据集目录: {test_data_dir}")
print(f"共找到 {len(all_files)} 个文件")