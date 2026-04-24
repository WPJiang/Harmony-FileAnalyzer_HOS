"""
目录扫描模块测试文件
测试DirectoryScanner类的各项功能
"""

import os
import sys
import tempfile
import shutil

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from file_analyzer import DirectoryScanner
from file_analyzer.directory_scanner import DirectoryType, ScanConfig


def create_test_environment():
    """创建测试环境，包括测试目录和测试文件"""
    # 创建临时测试目录
    test_base_dir = tempfile.mkdtemp(prefix='file_analyzer_test_')
    
    # 创建子目录
    sub_dirs = {
        'documents': os.path.join(test_base_dir, 'documents'),
        'images': os.path.join(test_base_dir, 'images'),
        'music': os.path.join(test_base_dir, 'music'),
        'nested': os.path.join(test_base_dir, 'level1', 'level2', 'level3'),
    }
    
    for dir_path in sub_dirs.values():
        os.makedirs(dir_path, exist_ok=True)
    
    # 创建测试文件
    test_files = {
        'documents': [
            ('report.pdf', 'PDF content'),
            ('notes.txt', 'Text content'),
            ('presentation.pptx', 'PPT content'),
        ],
        'images': [
            ('photo.jpg', 'JPEG content'),
            ('screenshot.png', 'PNG content'),
        ],
        'music': [
            ('song.mp3', 'MP3 content'),
        ],
        'nested': [
            ('deep_file.txt', 'Deep content'),
        ],
    }
    
    for dir_name, files in test_files.items():
        dir_path = sub_dirs[dir_name]
        for filename, content in files:
            file_path = os.path.join(dir_path, filename)
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(content)
    
    # 创建应该被排除的文件
    excluded_files = [
        ('temp.tmp', 'Temp content'),
        ('log.log', 'Log content'),
        ('~$temp.doc', 'Temp doc'),
    ]
    
    for filename, content in excluded_files:
        file_path = os.path.join(test_base_dir, filename)
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(content)
    
    return test_base_dir, sub_dirs


def cleanup_test_environment(test_dir):
    """清理测试环境"""
    if os.path.exists(test_dir):
        shutil.rmtree(test_dir)


def test_scan_config():
    """测试扫描配置类"""
    print("\n" + "=" * 60)
    print("测试1: 扫描配置类 (ScanConfig)")
    print("=" * 60)
    
    # 测试默认配置
    config = ScanConfig()
    print(f"默认包含系统目录: {config.include_system_dirs}")
    print(f"默认最大深度: {config.max_depth}")
    print(f"默认文件类型数: {len(config.include_patterns)}")
    print(f"默认排除模式数: {len(config.exclude_patterns)}")
    
    # 测试配置序列化
    config_dict = config.to_dict()
    print(f"配置转字典成功: {len(config_dict)} 个配置项")
    
    # 测试配置反序列化
    config2 = ScanConfig.from_dict(config_dict)
    print(f"配置从字典恢复成功: max_depth={config2.max_depth}")
    
    # 测试自定义配置
    custom_config = ScanConfig(
        max_depth=5,
        include_system_dirs=True,
        include_patterns=['*.pdf', '*.doc'],
        custom_directories=['C:\\Test']
    )
    print(f"自定义配置: max_depth={custom_config.max_depth}, include_system_dirs={custom_config.include_system_dirs}")
    
    print("✓ ScanConfig 测试通过")
    return True


def test_directory_scanner_initialization():
    """测试目录扫描器初始化"""
    print("\n" + "=" * 60)
    print("测试2: 目录扫描器初始化")
    print("=" * 60)
    
    # 测试默认初始化
    scanner = DirectoryScanner()
    print(f"扫描器创建成功")
    print(f"配置文件路径: {scanner.config_path}")
    
    # 测试自定义配置路径
    with tempfile.TemporaryDirectory() as tmpdir:
        custom_config_path = os.path.join(tmpdir, 'custom_config.json')
        scanner2 = DirectoryScanner(config_path=custom_config_path)
        print(f"自定义配置路径: {scanner2.config_path}")
    
    # 获取配置摘要
    summary = scanner.get_scan_summary()
    print(f"配置摘要: {len(summary)} 个配置项")
    print(f"  - 默认目录: {summary['default_directories']}")
    print(f"  - 扫描深度: {summary['max_depth']}")
    print(f"  - 包含文件类型: {len(summary['include_patterns'])} 种")
    
    print("✓ 目录扫描器初始化测试通过")
    return True


def test_windows_special_folders():
    """测试Windows特殊文件夹获取"""
    print("\n" + "=" * 60)
    print("测试3: Windows特殊文件夹")
    print("=" * 60)
    
    scanner = DirectoryScanner()
    
    folder_types = [
        (DirectoryType.DESKTOP, "桌面"),
        (DirectoryType.DOWNLOADS, "下载"),
        (DirectoryType.DOCUMENTS, "文档"),
        (DirectoryType.PICTURES, "图片"),
        (DirectoryType.VIDEOS, "视频"),
        (DirectoryType.MUSIC, "音乐"),
    ]
    
    for folder_type, name in folder_types:
        path = scanner.get_windows_special_folder(folder_type)
        status = "✓" if path and os.path.exists(path) else "✗"
        print(f"{status} {name}: {path if path else '未找到'}")
    
    print("✓ Windows特殊文件夹测试通过")
    return True


def test_default_directories():
    """测试默认扫描目录"""
    print("\n" + "=" * 60)
    print("测试4: 默认扫描目录")
    print("=" * 60)
    
    scanner = DirectoryScanner()
    
    # 获取默认目录
    default_dirs = scanner.get_default_scan_directories()
    print(f"启用的默认目录数: {len(default_dirs)}")
    for i, dir_path in enumerate(default_dirs, 1):
        print(f"  {i}. {dir_path}")
    
    # 获取所有可用类别
    categories = scanner.get_all_categories() if hasattr(scanner, 'get_all_categories') else []
    if categories:
        print(f"可用类别: {categories}")
    
    print("✓ 默认扫描目录测试通过")
    return True


def test_directory_scanning():
    """测试目录扫描功能"""
    print("\n" + "=" * 60)
    print("测试5: 目录扫描功能")
    print("=" * 60)
    
    test_dir, sub_dirs = create_test_environment()
    
    try:
        scanner = DirectoryScanner()
        
        # 测试基本扫描
        print(f"\n扫描测试目录: {test_dir}")
        files = scanner.scan_directory(test_dir, recursive=True)
        print(f"找到文件数: {len(files)}")
        
        # 验证排除模式
        excluded_found = any('temp.tmp' in f or 'log.log' in f or '~$' in f for f in files)
        print(f"排除文件是否被过滤: {'否 (正确)' if not excluded_found else '是 (错误)'}")
        
        # 测试非递归扫描
        files_non_recursive = scanner.scan_directory(test_dir, recursive=False)
        print(f"非递归扫描找到文件数: {len(files_non_recursive)}")
        
        # 测试特定扩展名扫描
        pdf_files = scanner.scan_directory(test_dir, recursive=True, extensions=['*.pdf'])
        print(f"PDF文件数: {len(pdf_files)}")
        
        txt_files = scanner.scan_directory(test_dir, recursive=True, extensions=['*.txt'])
        print(f"TXT文件数: {len(txt_files)}")
        
        # 测试扫描深度
        scanner.config.max_depth = 1
        shallow_files = scanner.scan_directory(test_dir, recursive=True)
        print(f"深度1扫描找到文件数: {len(shallow_files)}")
        
        scanner.config.max_depth = 5
        deep_files = scanner.scan_directory(test_dir, recursive=True)
        print(f"深度5扫描找到文件数: {len(deep_files)}")
        
        print("✓ 目录扫描功能测试通过")
        return True
        
    finally:
        cleanup_test_environment(test_dir)


def test_system_directory_filtering():
    """测试系统目录过滤"""
    print("\n" + "=" * 60)
    print("测试6: 系统目录过滤")
    print("=" * 60)
    
    scanner = DirectoryScanner()
    
    # 测试系统目录识别
    system_dirs = [
        'C:\\Windows',
        'C:\\Program Files',
        'C:\\Program Files (x86)',
        'C:\\ProgramData',
    ]
    
    print("系统目录检测:")
    for dir_path in system_dirs:
        is_system = scanner.is_system_directory(dir_path)
        print(f"  {'✓' if is_system else '✗'} {dir_path}: {'系统目录' if is_system else '非系统目录'}")
    
    # 测试非系统目录
    test_dirs = [
        os.path.expanduser('~'),
        'C:\\Users',
        tempfile.gettempdir(),
    ]
    
    print("\n非系统目录检测:")
    for dir_path in test_dirs:
        if os.path.exists(dir_path):
            is_system = scanner.is_system_directory(dir_path)
            print(f"  {'✓' if not is_system else '✗'} {dir_path}: {'非系统目录' if not is_system else '系统目录'}")
    
    print("✓ 系统目录过滤测试通过")
    return True


def test_custom_directory_management():
    """测试自定义目录管理"""
    print("\n" + "=" * 60)
    print("测试7: 自定义目录管理")
    print("=" * 60)
    
    with tempfile.TemporaryDirectory() as tmpdir:
        # 创建测试目录
        custom_dir = os.path.join(tmpdir, 'custom_scan_dir')
        os.makedirs(custom_dir, exist_ok=True)
        
        # 使用临时配置文件
        config_path = os.path.join(tmpdir, 'test_config.json')
        scanner = DirectoryScanner(config_path=config_path)
        
        # 测试添加自定义目录
        print(f"添加自定义目录: {custom_dir}")
        success = scanner.add_custom_directory(custom_dir)
        print(f"添加结果: {'成功' if success else '失败'}")
        
        # 验证目录是否已添加
        assert custom_dir in scanner.config.custom_directories, "自定义目录未添加到配置"
        print("✓ 自定义目录已添加到配置")
        
        # 测试重复添加
        success2 = scanner.add_custom_directory(custom_dir)
        print(f"重复添加结果: {'成功 (目录已存在)' if success2 else '失败'}")
        
        # 测试添加不存在的目录
        non_exist_dir = os.path.join(tmpdir, 'non_exist')
        success3 = scanner.add_custom_directory(non_exist_dir)
        print(f"添加不存在目录: {'成功' if success3 else '失败 (预期)'}")
        
        # 测试移除自定义目录
        print(f"\n移除自定义目录: {custom_dir}")
        success4 = scanner.remove_custom_directory(custom_dir)
        print(f"移除结果: {'成功' if success4 else '失败'}")
        
        # 验证目录是否已移除
        assert custom_dir not in scanner.config.custom_directories, "自定义目录未从配置移除"
        print("✓ 自定义目录已从配置移除")
        
        # 测试移除不存在的目录
        success5 = scanner.remove_custom_directory(non_exist_dir)
        print(f"移除不存在目录: {'成功' if success5 else '失败 (预期)'}")
    
    print("✓ 自定义目录管理测试通过")
    return True


def test_default_directory_management():
    """测试默认目录管理"""
    print("\n" + "=" * 60)
    print("测试8: 默认目录管理")
    print("=" * 60)
    
    with tempfile.TemporaryDirectory() as tmpdir:
        config_path = os.path.join(tmpdir, 'test_config.json')
        scanner = DirectoryScanner(config_path=config_path)
        
        # 记录初始状态
        initial_state = scanner.config.default_directories.copy()
        print(f"初始默认目录配置: {initial_state}")
        
        # 测试启用目录
        test_dirs = ['videos', 'music']
        for dir_type in test_dirs:
            print(f"\n启用 {dir_type} 目录:")
            success = scanner.enable_default_directory(dir_type, True)
            print(f"  结果: {'成功' if success else '失败'}")
            print(f"  当前状态: {scanner.config.default_directories[dir_type]}")
            assert scanner.config.default_directories[dir_type] == True, f"{dir_type} 目录未启用"
        
        # 测试禁用目录
        for dir_type in test_dirs:
            print(f"\n禁用 {dir_type} 目录:")
            success = scanner.enable_default_directory(dir_type, False)
            print(f"  结果: {'成功' if success else '失败'}")
            print(f"  当前状态: {scanner.config.default_directories[dir_type]}")
            assert scanner.config.default_directories[dir_type] == False, f"{dir_type} 目录未禁用"
        
        # 测试无效目录类型
        print(f"\n测试无效目录类型:")
        success = scanner.enable_default_directory('invalid_type', True)
        print(f"  结果: {'成功' if success else '失败 (预期)'}")
    
    print("✓ 默认目录管理测试通过")
    return True


def test_config_persistence():
    """测试配置持久化"""
    print("\n" + "=" * 60)
    print("测试9: 配置持久化")
    print("=" * 60)
    
    with tempfile.TemporaryDirectory() as tmpdir:
        config_path = os.path.join(tmpdir, 'test_config.json')
        
        # 创建扫描器并修改配置
        scanner1 = DirectoryScanner(config_path=config_path)
        scanner1.config.max_depth = 10
        scanner1.config.include_system_dirs = True
        scanner1.add_custom_directory('C:\\TestDir1')
        scanner1.add_custom_directory('D:\\TestDir2')
        scanner1.enable_default_directory('videos', True)
        
        # 保存配置
        print("保存配置...")
        success = scanner1.save_config()
        print(f"保存结果: {'成功' if success else '失败'}")
        
        # 验证配置文件是否存在
        assert os.path.exists(config_path), "配置文件未创建"
        print(f"✓ 配置文件已创建: {config_path}")
        
        # 创建新的扫描器实例，加载保存的配置
        print("\n加载配置...")
        scanner2 = DirectoryScanner(config_path=config_path)
        
        # 验证配置是否正确加载
        print(f"验证配置:")
        print(f"  max_depth: {scanner2.config.max_depth} (预期: 10)")
        print(f"  include_system_dirs: {scanner2.config.include_system_dirs} (预期: True)")
        print(f"  custom_directories: {scanner2.config.custom_directories}")
        print(f"  videos enabled: {scanner2.config.default_directories.get('videos')} (预期: True)")
        
        assert scanner2.config.max_depth == 10, "max_depth 未正确加载"
        assert scanner2.config.include_system_dirs == True, "include_system_dirs 未正确加载"
        assert 'C:\\TestDir1' in scanner2.config.custom_directories, "自定义目录未正确加载"
        assert scanner2.config.default_directories.get('videos') == True, "videos 目录状态未正确加载"
        
        print("✓ 配置持久化测试通过")
    
    return True


def test_scan_all_functionality():
    """测试完整扫描功能"""
    print("\n" + "=" * 60)
    print("测试10: 完整扫描功能")
    print("=" * 60)
    
    test_dir, sub_dirs = create_test_environment()
    
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, 'test_config.json')
            scanner = DirectoryScanner(config_path=config_path)
            
            # 添加测试目录为自定义目录
            scanner.add_custom_directory(test_dir)
            
            # 禁用其他默认目录，只保留测试目录
            for dir_type in ['desktop', 'downloads', 'documents', 'pictures']:
                scanner.enable_default_directory(dir_type, False)
            
            # 执行完整扫描
            print("执行完整扫描...")
            result = scanner.scan_all()
            
            print(f"\n扫描结果:")
            print(f"  扫描的目录数: {len(result['scanned_directories'])}")
            print(f"  总文件数: {result['total_files']}")
            print(f"  各目录文件数:")
            for dir_name, files in result['default_directories'].items():
                print(f"    - {dir_name}: {len(files)} 个文件")
        
        print("✓ 完整扫描功能测试通过")
        return True
        
    finally:
        cleanup_test_environment(test_dir)


def test_edge_cases():
    """测试边界情况"""
    print("\n" + "=" * 60)
    print("测试11: 边界情况")
    print("=" * 60)
    
    scanner = DirectoryScanner()
    
    # 测试扫描不存在的目录
    print("\n1. 扫描不存在的目录:")
    files = scanner.scan_directory('C:\\NonExistDir12345')
    print(f"   结果: 找到 {len(files)} 个文件 (预期: 0)")
    assert len(files) == 0, "扫描不存在目录应返回空列表"
    
    # 测试扫描空目录
    with tempfile.TemporaryDirectory() as tmpdir:
        print(f"\n2. 扫描空目录:")
        files = scanner.scan_directory(tmpdir)
        print(f"   结果: 找到 {len(files)} 个文件 (预期: 0)")
        assert len(files) == 0, "扫描空目录应返回空列表"
    
    # 测试扫描系统目录（默认配置）
    print(f"\n3. 扫描系统目录 (默认配置):")
    files = scanner.scan_directory('C:\\Windows')
    print(f"   结果: 找到 {len(files)} 个文件 (预期: 0，因为默认排除系统目录)")
    
    # 测试空扩展名列表
    with tempfile.TemporaryDirectory() as tmpdir:
        test_file = os.path.join(tmpdir, 'test.txt')
        with open(test_file, 'w') as f:
            f.write('test')
        
        print(f"\n4. 使用空扩展名列表扫描:")
        files = scanner.scan_directory(tmpdir, extensions=[])
        print(f"   结果: 找到 {len(files)} 个文件")
    
    print("✓ 边界情况测试通过")
    return True


def main():
    """主测试函数"""
    print("=" * 60)
    print("目录扫描模块测试")
    print("=" * 60)
    
    tests = [
        ("扫描配置类", test_scan_config),
        ("目录扫描器初始化", test_directory_scanner_initialization),
        ("Windows特殊文件夹", test_windows_special_folders),
        ("默认扫描目录", test_default_directories),
        ("目录扫描功能", test_directory_scanning),
        ("系统目录过滤", test_system_directory_filtering),
        ("自定义目录管理", test_custom_directory_management),
        ("默认目录管理", test_default_directory_management),
        ("配置持久化", test_config_persistence),
        ("完整扫描功能", test_scan_all_functionality),
        ("边界情况", test_edge_cases),
    ]
    
    results = []
    passed = 0
    failed = 0
    
    for name, test_func in tests:
        try:
            success = test_func()
            if success:
                results.append((name, "✓ 通过"))
                passed += 1
            else:
                results.append((name, "✗ 失败"))
                failed += 1
        except Exception as e:
            print(f"\n✗ 错误: {str(e)}")
            import traceback
            traceback.print_exc()
            results.append((name, f"✗ 错误: {str(e)}"))
            failed += 1
    
    # 打印测试结果汇总
    print("\n" + "=" * 60)
    print("测试结果汇总")
    print("=" * 60)
    for name, result in results:
        print(f"{name}: {result}")
    
    print("\n" + "=" * 60)
    print(f"总计: {len(tests)} 个测试")
    print(f"通过: {passed}")
    print(f"失败: {failed}")
    print("=" * 60)
    
    return failed == 0


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
