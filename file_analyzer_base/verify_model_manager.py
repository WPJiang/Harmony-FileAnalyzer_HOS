import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from models.model_manager import ModelManager
mm = ModelManager()
config = mm._load_config()
llm_type = config.get('llm', {}).get('type', 'unknown')
print(f"LLM type from config: {llm_type}")
print("ModelManager OK")
