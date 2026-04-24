import os
import sys

os.chdir(r'd:\jiangweipeng\trae_code')
sys.path.insert(0, r'd:\jiangweipeng\trae_code')

print("=" * 60)
print("File Analyzer Test")
print("=" * 60)

print("\n[1/5] Testing imports...")
try:
    from file_analyzer import DataParser, SemanticRepresentation, SemanticSimilarity, SemanticClustering
    print("SUCCESS: All modules imported")
except ImportError as e:
    print(f"FAILED: Import error - {e}")
    sys.exit(1)

print("\n[2/5] Testing DataParser...")
try:
    parser = DataParser()
    exts = parser.get_supported_extensions()
    print(f"SUCCESS: Supported formats: {exts}")
except Exception as e:
    print(f"FAILED: {e}")

print("\n[3/5] Testing SemanticRepresentation...")
try:
    from file_analyzer.data_parser import DataBlock, ModalityType
    rep = SemanticRepresentation({'keyword': {'method': 'jieba', 'top_k': 5}})
    test_text = "这是一个机器学习技术文档"
    keywords = rep.extract_keywords(test_text)
    print(f"SUCCESS: Keywords extracted: {keywords}")
except Exception as e:
    print(f"FAILED: {e}")

print("\n[4/5] Testing SemanticSimilarity...")
try:
    from file_analyzer.semantic_representation import SemanticBlock
    import numpy as np
    sim = SemanticSimilarity()
    b1 = SemanticBlock("q", "机器学习", ["机器学习"], np.random.rand(384))
    b2 = SemanticBlock("t", "深度学习", ["深度学习"], np.random.rand(384))
    result = sim.compute_similarity(b1, b2)
    print(f"SUCCESS: Fused score = {result.fused_score:.4f}")
except Exception as e:
    print(f"FAILED: {e}")

print("\n[5/5] Testing SemanticClustering...")
try:
    cluster = SemanticClustering()
    cats = cluster.get_category_names()
    print(f"SUCCESS: Categories: {cats[:3]}...")
except Exception as e:
    print(f"FAILED: {e}")

print("\n" + "=" * 60)
print("ALL TESTS COMPLETED!")
print("=" * 60)
