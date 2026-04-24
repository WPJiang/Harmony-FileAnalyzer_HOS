import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from file_analyzer import DataParser, SemanticRepresentation, SemanticSimilarity, SemanticClustering, DirectoryScanner
from file_analyzer.data_parser import DataBlock, ModalityType


def create_sample_text_file():
    sample_dir = os.path.join(os.path.dirname(__file__), 'sample_files')
    os.makedirs(sample_dir, exist_ok=True)
    
    sample_file = os.path.join(sample_dir, 'sample.txt')
    with open(sample_file, 'w', encoding='utf-8') as f:
        f.write("""这是一个技术文档示例。
本文档介绍了API接口的设计规范。
系统架构采用微服务设计模式。
主要功能包括用户认证、数据处理和存储服务。
配置文件需要设置服务器地址和端口号。
""")
    
    return sample_file


def test_data_parser():
    print("=" * 50)
    print("测试数据解析模块")
    print("=" * 50)
    
    parser = DataParser()
    
    print(f"支持的文件格式: {parser.get_supported_extensions()}")
    
    sample_file = create_sample_text_file()
    print(f"\n创建示例文件: {sample_file}")
    
    print("\n数据解析模块初始化成功!")
    return True


def test_semantic_representation():
    print("\n" + "=" * 50)
    print("测试语义表征模块")
    print("=" * 50)
    
    config = {
        'embedding': {
            'type': 'sentence_transformer',
            'model_name': 'paraphrase-multilingual-MiniLM-L12-v2'
        },
        'keyword': {
            'method': 'jieba',
            'top_k': 5
        }
    }
    
    rep = SemanticRepresentation(config)
    
    test_block = DataBlock(
        block_id="test_001",
        modality=ModalityType.TEXT,
        content="这是一个关于机器学习和深度学习的技术文档。",
        text_content="这是一个关于机器学习和深度学习的技术文档。",
        metadata={'source': 'test'}
    )
    
    print(f"输入文本: {test_block.text_content}")
    
    keywords = rep.extract_keywords(test_block.text_content)
    print(f"提取关键词: {keywords}")
    
    description = rep.generate_description(test_block.text_content)
    print(f"生成描述: {description}")
    
    print("\n语义表征模块基础功能测试成功!")
    return True


def test_semantic_similarity():
    print("\n" + "=" * 50)
    print("测试语义相似度计算模块")
    print("=" * 50)
    
    from file_analyzer.semantic_representation import SemanticBlock
    import numpy as np
    
    similarity = SemanticSimilarity()
    
    block1 = SemanticBlock(
        block_id="query",
        text_description="机器学习算法研究",
        keywords=["机器学习", "算法", "研究"],
        semantic_vector=np.random.rand(384)
    )
    
    block2 = SemanticBlock(
        block_id="target1",
        text_description="深度学习神经网络",
        keywords=["深度学习", "神经网络"],
        semantic_vector=np.random.rand(384)
    )
    
    block3 = SemanticBlock(
        block_id="target2",
        text_description="机器学习模型训练",
        keywords=["机器学习", "模型", "训练"],
        semantic_vector=np.random.rand(384)
    )
    
    result = similarity.compute_similarity(block1, block2)
    print(f"相似度计算结果:")
    print(f"  - 向量相似度: {result.vector_similarity:.4f}")
    print(f"  - BM25分数: {result.bm25_score:.4f}")
    print(f"  - 关键词相似度: {result.keyword_similarity:.4f}")
    print(f"  - 融合分数: {result.fused_score:.4f}")
    
    print("\n语义相似度模块测试成功!")
    return True


def test_semantic_clustering():
    print("\n" + "=" * 50)
    print("测试语义聚类模块")
    print("=" * 50)
    
    from file_analyzer.semantic_representation import SemanticBlock
    import numpy as np
    
    clustering = SemanticClustering()
    
    print(f"预定义类别: {clustering.get_category_names()}")
    
    print("\n语义聚类模块初始化成功!")
    return True


def test_integration():
    print("\n" + "=" * 50)
    print("测试完整流程")
    print("=" * 50)
    
    parser = DataParser()
    
    rep = SemanticRepresentation({
        'keyword': {'method': 'jieba', 'top_k': 5}
    })
    
    similarity = SemanticSimilarity()
    
    clustering = SemanticClustering()
    
    test_blocks = [
        DataBlock(
            block_id="doc_001",
            modality=ModalityType.TEXT,
            content="本文档介绍了API接口的技术规范和开发指南。",
            text_content="本文档介绍了API接口的技术规范和开发指南。",
            metadata={'source': 'test'}
        ),
        DataBlock(
            block_id="doc_002",
            modality=ModalityType.TEXT,
            content="市场分析报告显示销售额增长了20%。",
            text_content="市场分析报告显示销售额增长了20%。",
            metadata={'source': 'test'}
        ),
    ]
    
    print("处理数据块...")
    for block in test_blocks:
        semantic_block = rep.represent(block)
        print(f"\n块ID: {semantic_block.block_id}")
        print(f"  描述: {semantic_block.text_description}")
        print(f"  关键词: {semantic_block.keywords}")
    
    print("\n完整流程测试成功!")
    return True


def test_directory_scanner():
    print("\n" + "=" * 50)
    print("测试目录扫描模块")
    print("=" * 50)
    
    scanner = DirectoryScanner()
    
    print("\n1. 获取扫描配置摘要:")
    summary = scanner.get_scan_summary()
    print(f"   配置文件路径: {summary['config_path']}")
    print(f"   默认目录配置: {summary['default_directories']}")
    print(f"   自定义目录: {summary['custom_directories']}")
    print(f"   包含文件类型: {summary['include_patterns'][:5]}...")
    print(f"   扫描深度: {summary['max_depth']}")
    
    print("\n2. 获取Windows特殊文件夹:")
    from file_analyzer.directory_scanner import DirectoryType
    desktop = scanner.get_windows_special_folder(DirectoryType.DESKTOP)
    downloads = scanner.get_windows_special_folder(DirectoryType.DOWNLOADS)
    documents = scanner.get_windows_special_folder(DirectoryType.DOCUMENTS)
    print(f"   桌面: {desktop}")
    print(f"   下载: {downloads}")
    print(f"   文档: {documents}")
    
    print("\n3. 获取默认扫描目录:")
    default_dirs = scanner.get_default_scan_directories()
    for i, dir_path in enumerate(default_dirs[:3], 1):
        print(f"   {i}. {dir_path}")
    
    print("\n4. 扫描示例目录:")
    sample_dir = os.path.dirname(create_sample_text_file())
    files = scanner.scan_directory(sample_dir, recursive=True)
    print(f"   扫描目录: {sample_dir}")
    print(f"   找到文件数: {len(files)}")
    for f in files[:3]:
        print(f"   - {os.path.basename(f)}")
    
    print("\n5. 添加自定义目录:")
    test_dir = os.path.join(os.path.dirname(__file__), 'test_dir')
    os.makedirs(test_dir, exist_ok=True)
    success = scanner.add_custom_directory(test_dir)
    print(f"   添加目录 {test_dir}: {'成功' if success else '失败'}")
    
    print("\n6. 启用/禁用默认目录:")
    scanner.enable_default_directory('videos', True)
    print("   已启用视频目录扫描")
    scanner.enable_default_directory('music', False)
    print("   已禁用音乐目录扫描")
    
    print("\n7. 检查系统目录过滤:")
    is_system = scanner.is_system_directory('C:\\Windows')
    print(f"   C:\\Windows 是系统目录: {is_system}")
    is_system = scanner.is_system_directory(sample_dir)
    print(f"   {sample_dir} 是系统目录: {is_system}")
    
    print("\n8. 保存配置:")
    success = scanner.save_config()
    print(f"   配置保存: {'成功' if success else '失败'}")
    
    print("\n目录扫描模块测试完成!")
    return True


def main():
    print("开始文件分析工程测试")
    print("=" * 50)
    
    tests = [
        ("数据解析模块", test_data_parser),
        ("目录扫描模块", test_directory_scanner),
        ("语义表征模块", test_semantic_representation),
        ("语义相似度模块", test_semantic_similarity),
        ("语义聚类模块", test_semantic_clustering),
        ("完整流程", test_integration),
    ]
    
    results = []
    for name, test_func in tests:
        try:
            success = test_func()
            results.append((name, "通过" if success else "失败"))
        except Exception as e:
            print(f"\n错误: {str(e)}")
            results.append((name, f"失败: {str(e)}"))
    
    print("\n" + "=" * 50)
    print("测试结果汇总")
    print("=" * 50)
    for name, result in results:
        print(f"{name}: {result}")


if __name__ == "__main__":
    main()
