import sys
print(f"Python: {sys.executable}")

try:
    from database.database import DatabaseManager
    print("Database OK")
except Exception as e:
    print(f"Database FAIL: {e}")

try:
    from data_parser.data_parser import DataParser
    print("DataParser OK")
except Exception as e:
    print(f"DataParser FAIL: {e}")

try:
    from semantic_representation.semantic_representation import SemanticRepresentation, FilenameSemanticAnalyzer
    print("SemanticRepresentation OK")
except Exception as e:
    print(f"SemanticRepresentation FAIL: {e}")

try:
    from semantic_similarity.semantic_similarity import SemanticSimilarity
    print("SemanticSimilarity OK")
except Exception as e:
    print(f"SemanticSimilarity FAIL: {e}")

try:
    from semantic_clustering.semantic_clustering import SemanticClustering
    print("SemanticClustering OK")
except Exception as e:
    print(f"SemanticClustering FAIL: {e}")

try:
    from semantic_classification.semantic_classification import SemanticClassification
    print("SemanticClassification OK")
except Exception as e:
    print(f"SemanticClassification FAIL: {e}")

try:
    from semantic_query.semantic_query import SemanticQuery
    print("SemanticQuery OK")
except Exception as e:
    print(f"SemanticQuery FAIL: {e}")

try:
    from models.model_manager import ModelManager
    print("ModelManager OK")
except Exception as e:
    print(f"ModelManager FAIL: {e}")

try:
    from models.cloud_llm_client import CloudLLMClient
    print("CloudLLMClient OK")
except Exception as e:
    print(f"CloudLLMClient FAIL: {e}")

try:
    from directory_scanner.directory_scanner import DirectoryScanner
    print("DirectoryScanner OK")
except Exception as e:
    print(f"DirectoryScanner FAIL: {e}")

print("DONE")
