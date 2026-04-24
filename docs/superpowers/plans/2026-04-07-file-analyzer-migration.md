# File Analyzer HarmonyOS Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the complete functionality of the Python file_analyzer project into the HarmonyOS project, using an HTTP API architecture with cloud-only LLM mode.

**Architecture:** Python backend (FastAPI) serves as the processing engine handling OCR (PaddleOCR), embeddings (sentence-transformers), LLM calls (cloud API), and file parsing. The ArkTS HarmonyOS frontend provides the UI and communicates with the backend via HTTP REST API. The backend runs as a local server during development and can be deployed as a companion service.

**Tech Stack:** Python/FastAPI (backend), ArkTS/ETS (frontend), SQLite (both sides), PaddleOCR (OCR), sentence-transformers (embedding), Dashscope/OpenAI (cloud LLM)

---

## File Structure

### Python Backend (`file_analyzer_base/`)
```
file_analyzer_base/
├── api_server.py              # NEW: FastAPI HTTP server with REST endpoints
├── config.json                # UPDATE: Configuration (cloud LLM only)
├── api_config.json            # NEW: API credentials
├── requirements.txt           # UPDATE: Add FastAPI dependencies
├── database/
│   └── database.py            # UPDATE: From source project
├── data_parser/
│   ├── data_parser.py         # UPDATE: From source project
│   ├── base_parser.py         # UPDATE: From source project
│   ├── pdf_parser.py          # UPDATE: From source project
│   ├── word_parser.py         # NEW: From source project
│   ├── ppt_parser.py          # UPDATE: From source project
│   ├── excel_parser.py        # NEW: From source project
│   ├── image_parser.py        # UPDATE: From source project
│   └── txt_parser.py          # NEW: From source project
├── semantic_representation/
│   └── semantic_representation.py  # UPDATE: From source project
├── semantic_similarity/
│   └── semantic_similarity.py      # UPDATE: From source project
├── semantic_clustering/
│   └── semantic_clustering.py      # UPDATE: From source project
├── semantic_classification/
│   └── semantic_classification.py  # UPDATE: From source project
├── semantic_query/
│   └── semantic_query.py           # UPDATE: From source project
├── models/
│   ├── model_manager.py       # UPDATE: Cloud mode only
│   └── cloud_llm_client.py    # UPDATE: From source project
├── directory_scanner/
│   └── directory_scanner.py   # UPDATE: From source project
├── tests/
│   ├── test_api.py            # NEW: API endpoint tests
│   ├── test_ocr.py            # NEW: OCR verification test
│   └── test_embedding.py      # NEW: Embedding verification test
└── simple_launch.py           # UPDATE: Launch API server
```

### ArkTS Frontend (`entry/src/main/ets/`)
```
entry/src/main/ets/
├── services/
│   ├── ApiService.ets         # NEW: HTTP client for backend API
│   ├── FileAnalysisService.ets # UPDATE: Use ApiService
│   └── OCRService.ets         # UPDATE: Use backend OCR via API
├── semantic/
│   ├── EmbeddingService.ets   # UPDATE: Use backend embedding via API
│   └── CloudLLMService.ets    # NEW: Cloud LLM client for direct calls
├── parser/
│   ├── WordParser.ets         # NEW: Word document parser (basic)
│   ├── PptParser.ets          # NEW: PowerPoint parser (basic)
│   └── ExcelParser.ets        # NEW: Excel parser (basic)
├── models/
│   ├── ApiModels.ets          # NEW: API request/response models
│   └── (existing models)      # UPDATE: Add new fields
└── pages/
    └── Index.ets              # UPDATE: Enhanced UI with settings
```

---

### Task 1: Update Python Backend Core Modules

**Files:**
- Update: `file_analyzer_base/database/database.py`
- Update: `file_analyzer_base/data_parser/base_parser.py`
- Update: `file_analyzer_base/data_parser/data_parser.py`
- Update: `file_analyzer_base/data_parser/pdf_parser.py`
- Update: `file_analyzer_base/data_parser/image_parser.py`
- Create: `file_analyzer_base/data_parser/word_parser.py`
- Create: `file_analyzer_base/data_parser/ppt_parser.py`
- Create: `file_analyzer_base/data_parser/excel_parser.py`
- Create: `file_analyzer_base/data_parser/txt_parser.py`

- [ ] **Step 1: Copy core database module from source**

Copy `database.py` from source project at `D:\jiangweipeng\trae_code\file_analyzer\database\database.py` to `file_analyzer_base/database/database.py`, replacing the existing file.

- [ ] **Step 2: Copy all data parser modules from source**

Copy all parser files from source project:
- `data_parser.py`, `base_parser.py`, `pdf_parser.py`, `image_parser.py`
- New parsers: `word_parser.py`, `ppt_parser.py`, `excel_parser.py`, `txt_parser.py`

- [ ] **Step 3: Verify parsers import correctly**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python -c "from data_parser.data_parser import DataParser; print('OK')"`

---

### Task 2: Update Semantic Modules (Cloud LLM Only)

**Files:**
- Update: `file_analyzer_base/semantic_representation/semantic_representation.py`
- Update: `file_analyzer_base/semantic_similarity/semantic_similarity.py`
- Update: `file_analyzer_base/semantic_clustering/semantic_clustering.py`
- Update: `file_analyzer_base/semantic_classification/semantic_classification.py`
- Update: `file_analyzer_base/semantic_query/semantic_query.py`

- [ ] **Step 1: Copy semantic modules from source**

Copy all semantic modules from source project, replacing existing files in `file_analyzer_base/`:
- `semantic_representation/semantic_representation.py`
- `semantic_representation/image_metadata_extractor.py`
- `semantic_representation/image_caption_tagger.py`
- `semantic_similarity/semantic_similarity.py`
- `semantic_clustering/semantic_clustering.py`
- `semantic_classification/semantic_classification.py`
- `semantic_query/semantic_query.py`

- [ ] **Step 2: Copy directory scanner from source**

Copy `directory_scanner/directory_scanner.py` from source project.

- [ ] **Step 3: Verify semantic modules import correctly**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python -c "from semantic_representation.semantic_representation import SemanticRepresentation; print('OK')"`

---

### Task 3: Update Model Manager (Cloud Mode Only)

**Files:**
- Update: `file_analyzer_base/models/model_manager.py`
- Update: `file_analyzer_base/models/cloud_llm_client.py`
- Update: `file_analyzer_base/config.json`
- Create: `file_analyzer_base/api_config.json`
- Delete: `file_analyzer_base/models/local_llama_client.py` (if exists)
- Delete: `file_analyzer_base/models/ollama_client.py` (if exists)

- [ ] **Step 1: Copy cloud LLM client from source**

Copy `models/cloud_llm_client.py` from source project.

- [ ] **Step 2: Copy model manager and strip local modes**

Copy `models/model_manager.py` from source and modify:
- Remove `local_llama` and `ollama` imports/references
- Keep only `cloud` mode
- Set `llm.type` default to `cloud`

- [ ] **Step 3: Update config.json**

Copy `config.json` from source project, change:
- `"llm": { "type": "cloud" }` (remove local_llama/ollama sections)
- Copy `api_config_example.json` as `api_config.json` template

- [ ] **Step 4: Verify model manager works in cloud mode**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python -c "from models.model_manager import ModelManager; mm = ModelManager(); print('Cloud mode:', mm.llm_type)"`

---

### Task 4: Create FastAPI HTTP Server

**Files:**
- Create: `file_analyzer_base/api_server.py`
- Update: `file_analyzer_base/requirements.txt`
- Update: `file_analyzer_base/simple_launch.py`

- [ ] **Step 1: Create API server with core endpoints**

Create `api_server.py` with FastAPI endpoints:
```
POST /api/scan         - Scan directory for files
POST /api/parse        - Parse a file to data blocks
POST /api/analyze      - Full analysis (parse + semantic + classify)
POST /api/classify     - Classify file content
POST /api/search       - Semantic search
POST /api/ocr          - OCR on an image
POST /api/embed        - Generate embedding vector
POST /api/llm/describe - Generate text description via cloud LLM
GET  /api/files        - List all analyzed files
GET  /api/files/{id}   - Get file details
GET  /api/categories   - Get category statistics
GET  /api/health       - Health check
```

- [ ] **Step 2: Update requirements.txt**

Add FastAPI, uvicorn, python-multipart to requirements.

- [ ] **Step 3: Update simple_launch.py to start API server**

Modify launch script to start FastAPI server on a configurable port (default 8765).

- [ ] **Step 4: Test API server starts**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python api_server.py`
Expected: Server starts on port 8765, health check returns OK.

---

### Task 5: Test OCR Functionality

**Files:**
- Create: `file_analyzer_base/tests/test_ocr.py`

- [ ] **Step 1: Write OCR test script**

Create a test script that:
1. Creates a test image with Chinese and English text
2. Runs OCR via PaddleOCR
3. Verifies text extraction works
4. Prints results for verification

- [ ] **Step 2: Run OCR test**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python tests/test_ocr.py`
Expected: OCR extracts text from test image, prints recognized text.

- [ ] **Step 3: Test OCR via API endpoint**

Run: `curl -X POST http://localhost:8765/api/ocr -F "file=@test_image.png"`
Expected: Returns JSON with recognized text and confidence.

---

### Task 6: Test Embedding Functionality

**Files:**
- Create: `file_analyzer_base/tests/test_embedding.py`

- [ ] **Step 1: Write embedding test script**

Create a test script that:
1. Loads sentence-transformers model
2. Encodes sample Chinese and English text
3. Verifies vector dimensions (384-dim)
4. Computes similarity between related texts
5. Prints results for verification

- [ ] **Step 2: Run embedding test**

Run: `cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS\file_analyzer_base && python tests/test_embedding.py`
Expected: Embeddings are 384-dimensional, similar texts have high cosine similarity.

- [ ] **Step 3: Test embedding via API endpoint**

Run: `curl -X POST http://localhost:8765/api/embed -H "Content-Type: application/json" -d '{"text": "测试文本"}'`
Expected: Returns JSON with 384-dimensional vector.

---

### Task 7: Create ArkTS API Service

**Files:**
- Create: `entry/src/main/ets/services/ApiService.ets`
- Create: `entry/src/main/ets/models/ApiModels.ets`
- Update: `entry/src/main/ets/services/Index.ets`

- [ ] **Step 1: Create API models**

Create `ApiModels.ets` with request/response interfaces matching the Python API:
- `ScanRequest`, `ScanResponse`
- `AnalyzeRequest`, `AnalyzeResponse`
- `SearchRequest`, `SearchResponse`
- `OcrResponse`, `EmbedResponse`
- `FileListResponse`, `CategoryResponse`

- [ ] **Step 2: Create API service**

Create `ApiService.ets` with HTTP client using HarmonyOS `@kit.NetworkKit`:
- Configurable server URL (default: `http://localhost:8765`)
- All API methods as async functions
- Error handling with timeout
- JSON serialization/deserialization

- [ ] **Step 3: Update services Index.ets**

Export new ApiService and ApiModels.

---

### Task 8: Update ArkTS Frontend to Use API

**Files:**
- Update: `entry/src/main/ets/services/FileAnalysisService.ets`
- Update: `entry/src/main/ets/services/OCRService.ets`
- Update: `entry/src/main/ets/semantic/EmbeddingService.ets`
- Update: `entry/src/main/ets/semantic/SemanticRepresentation.ets`
- Update: `entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: Update FileAnalysisService to use API**

Modify `FileAnalysisService.ets`:
- Use `ApiService` for scan, analyze, search operations
- Keep local database for caching
- Add offline fallback logic

- [ ] **Step 2: Update OCRService to use backend API**

Modify `OCRService.ets`:
- Call `/api/ocr` endpoint for OCR
- Keep native fallback for basic image info

- [ ] **Step 3: Update EmbeddingService to use backend API**

Modify `EmbeddingService.ets`:
- Call `/api/embed` endpoint for embeddings
- Cache vectors locally

- [ ] **Step 4: Update SemanticRepresentation to use backend**

Modify `SemanticRepresentation.ets`:
- Use API-based OCR and embedding
- Call `/api/llm/describe` for text description generation
- Keep local keyword extraction

- [ ] **Step 5: Update Index.ets main page**

Add:
- Settings button to configure API server URL
- Connection status indicator
- Error handling for API failures
- Enhanced progress reporting

---

### Task 9: End-to-End Integration Test

**Files:**
- Create: `file_analyzer_base/tests/test_e2e.py`

- [ ] **Step 1: Start API server**

Start the Python backend API server.

- [ ] **Step 2: Run full pipeline test**

Test the complete flow:
1. Scan a test directory
2. Parse files (PDF, image, text)
3. Run OCR on images
4. Generate embeddings
5. Classify files
6. Search files
7. Verify all results

- [ ] **Step 3: Verify results meet expectations**

Check:
- OCR extracts meaningful text from images
- Embeddings produce 384-dim vectors with meaningful similarities
- Classification assigns correct categories
- Search returns relevant results

---

## Summary

| Task | Description | Key Changes |
|------|-------------|-------------|
| 1 | Update backend core modules | Copy parsers + database from source |
| 2 | Update semantic modules | Copy all semantic modules from source |
| 3 | Update model manager | Cloud LLM only, remove local modes |
| 4 | Create API server | FastAPI REST endpoints |
| 5 | Test OCR | Verify PaddleOCR works |
| 6 | Test embedding | Verify sentence-transformers works |
| 7 | ArkTS API service | HTTP client for backend |
| 8 | Update frontend | Use API for all operations |
| 9 | E2E test | Full pipeline verification |
