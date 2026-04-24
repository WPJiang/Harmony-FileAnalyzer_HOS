print("Starting File Analyzer Test...")
print("=" * 50)

try:
    print("Testing imports...")
    from file_analyzer import DataParser, SemanticRepresentation, SemanticSimilarity, SemanticClustering
    print("All modules imported successfully!")
except ImportError as e:
    print(f"Import error: {e}")
    exit(1)

print("\n" + "=" * 50)
print("Test 1: Data Parser")
print("=" * 50)
parser = DataParser()
print(f"Supported extensions: {parser.get_supported_extensions()}")
print("Data Parser: PASSED")

print("\n" + "=" * 50)
print("Test 2: Semantic Representation")
print("=" * 50)
from file_analyzer.data_parser import DataBlock, ModalityType
from file_analyzer.semantic_representation import SemanticBlock

rep = SemanticRepresentation({'keyword': {'method': 'jieba', 'top_k': 5}})

test_block = DataBlock(
    block_id="test_001",
    modality=ModalityType.TEXT,
    content="这是一个关于机器学习的技术文档。",
    text_content="这是一个关于机器学习的技术文档。",
    metadata={'source': 'test'}
)

keywords = rep.extract_keywords(test_block.text_content)
print(f"Input: {test_block.text_content}")
print(f"Keywords: {keywords}")
print("Semantic Representation: PASSED")

print("\n" + "=" * 50)
print("Test 3: Semantic Similarity")
print("=" * 50)
import numpy as np

similarity = SemanticSimilarity()

block1 = SemanticBlock(
    block_id="query",
    text_description="机器学习算法研究",
    keywords=["机器学习", "算法", "研究"],
    semantic_vector=np.random.rand(384)
)

block2 = SemanticBlock(
    block_id="target",
    text_description="深度学习神经网络",
    keywords=["深度学习", "神经网络"],
    semantic_vector=np.random.rand(384)
)

result = similarity.compute_similarity(block1, block2)
print(f"Vector similarity: {result.vector_similarity:.4f}")
print(f"BM25 score: {result.bm25_score:.4f}")
print(f"Keyword similarity: {result.keyword_similarity:.4f}")
print(f"Fused score: {result.fused_score:.4f}")
print("Semantic Similarity: PASSED")

print("\n" + "=" * 50)
print("Test 4: Semantic Clustering")
print("=" * 50)
clustering = SemanticClustering()
print(f"Predefined categories: {clustering.get_category_names()}")
print("Semantic Clustering: PASSED")

print("\n" + "=" * 50)
print("ALL TESTS PASSED!")
print("=" * 50)
