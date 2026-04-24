"""
FastAPI HTTP API Server for File Analyzer.

Provides REST endpoints that the HarmonyOS frontend can call to access
file analysis functionality. Wraps the existing Python modules for
directory scanning, file parsing, semantic analysis, classification,
search, OCR, embedding, and LLM description generation.
"""

import os
import sys
import traceback
import subprocess
import base64
import json
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Path setup -- add base dir so package imports work
# ---------------------------------------------------------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)


# ===========================================================================
# Global state -- lazily initialised module instances
# ===========================================================================
_db_manager = None
_data_parser = None
_semantic_rep = None
_semantic_similarity = None
_semantic_clustering = None
_semantic_classification = None
_semantic_query = None
_directory_scanner = None

_models_loaded = False


def _get_db():
    """Return (and lazily create) the global DatabaseManager."""
    global _db_manager
    if _db_manager is None:
        from database.database import DatabaseManager
        db_path = os.path.join(BASE_DIR, "file_analyzer.db")
        _db_manager = DatabaseManager(db_path=db_path)
    return _db_manager


def _get_scanner():
    global _directory_scanner
    if _directory_scanner is None:
        from directory_scanner.directory_scanner import DirectoryScanner
        _directory_scanner = DirectoryScanner()
    return _directory_scanner


def _get_parser():
    global _data_parser
    if _data_parser is None:
        from data_parser.data_parser import DataParser
        _data_parser = DataParser()
    return _data_parser


def _get_semantic_rep():
    global _semantic_rep
    if _semantic_rep is None:
        from semantic_representation.semantic_representation import SemanticRepresentation
        _semantic_rep = SemanticRepresentation()
    return _semantic_rep


def _get_semantic_query():
    global _semantic_query
    if _semantic_query is None:
        from semantic_query.semantic_query import SemanticQuery
        _semantic_query = SemanticQuery(db_manager=_get_db())
    return _semantic_query


def _get_semantic_clustering():
    global _semantic_clustering
    if _semantic_clustering is None:
        from semantic_clustering.semantic_clustering import SemanticClustering
        _semantic_clustering = SemanticClustering(db_manager=_get_db())
    return _semantic_clustering


def _get_semantic_classification():
    global _semantic_classification
    if _semantic_classification is None:
        from semantic_classification.semantic_classification import SemanticClassification
        _semantic_classification = SemanticClassification()
    return _semantic_classification


# ===========================================================================
# Pydantic request / response models
# ===========================================================================

class ScanRequest(BaseModel):
    directory_path: str
    recursive: bool = True


class ParseRequest(BaseModel):
    file_path: str
    parsing_mode: Optional[int] = None


class AnalyzeRequest(BaseModel):
    file_path: str
    parsing_mode: Optional[int] = None


class ClassifyRequest(BaseModel):
    text: str
    method: Optional[str] = "similarity"


class SearchRequest(BaseModel):
    query: str
    top_k: Optional[int] = 10


class OcrRequest(BaseModel):
    image_path: str


class EmbedRequest(BaseModel):
    text: str


class LlmDescribeRequest(BaseModel):
    text: str
    prompt: Optional[str] = None


class SemanticRepresentRequest(BaseModel):
    file_id: int


class ClassifyFileRequest(BaseModel):
    file_id: int
    category_system_name: Optional[str] = None


class ImageMetadataRequest(BaseModel):
    file_id: Optional[int] = None
    file_path: Optional[str] = None


class ImageCaptionRequest(BaseModel):
    file_id: Optional[int] = None
    file_path: Optional[str] = None


class SyncDatabaseRequest(BaseModel):
    action: str
    timestamp: str
    database_size: int
    database_base64: str


class SyncTablesRequest(BaseModel):
    action: str
    timestamp: str
    tables: Dict[str, List[Dict[str, Any]]]


class LogRequest(BaseModel):
    action: str
    timestamp: str
    level: str
    message: str
    data: Dict[str, Any]


class SyncCacheFileRequest(BaseModel):
    """Request model for syncing a single cache file."""
    action: str
    timestamp: str
    relative_path: str  # Relative path under data_blocks, e.g., "高等数学_2162da2f/slide_1.txt"
    file_size: int
    content_base64: str


class SyncCacheCompleteRequest(BaseModel):
    """Request model for signaling cache sync completion."""
    action: str
    timestamp: str
    total_files: int
    total_size: int


# ===========================================================================
# HDC Port Forwarding Setup
# ===========================================================================

def setup_hdc_port_forwarding(port: int = 8765) -> bool:
    """Setup reverse port forwarding for device to connect to PC server."""
    # Try to find HDC tool in common locations
    hdc_paths = [
        r"D:\Program Files\Huawei\DevEco Studio6.1\sdk\default\openharmony\toolchains\hdc.exe",
        r"C:\Program Files\Huawei\DevEco Studio6.1\sdk\default\openharmony\toolchains\hdc.exe",
        r"D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
        r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
        os.path.expanduser("~/.Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc"),
    ]

    hdc_exe = None
    for path in hdc_paths:
        if os.path.exists(path):
            hdc_exe = path
            break

    if not hdc_exe:
        print("[API] Warning: HDC tool not found, port forwarding not set up")
        return False

    try:
        # Kill existing HDC server and restart
        subprocess.run([hdc_exe, "kill"], capture_output=True, timeout=5)
        subprocess.run([hdc_exe, "start"], capture_output=True, timeout=10)

        # Setup reverse port forwarding (device -> PC)
        result = subprocess.run(
            [hdc_exe, "rport", f"tcp:{port}", f"tcp:{port}"],
            capture_output=True,
            text=True,
            timeout=10
        )

        if "OK" in result.stdout or result.returncode == 0:
            print(f"[API] HDC reverse port forwarding set up: {port}")
            return True
        else:
            print(f"[API] HDC port forwarding failed: {result.stderr}")
            return False
    except Exception as e:
        print(f"[API] HDC port forwarding error: {e}")
        return False


# ===========================================================================
# Application lifespan -- startup / shutdown
# ===========================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialise heavy resources on startup, clean up on shutdown."""
    global _models_loaded
    try:
        # Setup HDC port forwarding for device connection
        port = int(os.environ.get("API_PORT", 8765))
        setup_hdc_port_forwarding(port)

        _get_db()
        _models_loaded = True
        print("[API] Database initialised.")
    except Exception as exc:
        _models_loaded = False
        print(f"[API] WARNING: Database init failed: {exc}")

    yield  # application runs

    # Shutdown cleanup
    global _db_manager, _data_parser, _semantic_rep
    global _semantic_similarity, _semantic_clustering
    global _semantic_classification, _semantic_query, _directory_scanner

    if _db_manager is not None:
        try:
            _db_manager.close()
        except Exception:
            pass

    _db_manager = None
    _data_parser = None
    _semantic_rep = None
    _semantic_similarity = None
    _semantic_clustering = None
    _semantic_classification = None
    _semantic_query = None
    _directory_scanner = None
    _models_loaded = False
    print("[API] Shutdown complete.")


# ===========================================================================
# FastAPI app
# ===========================================================================

app = FastAPI(
    title="File Analyzer API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ===========================================================================
# Helper utilities
# ===========================================================================

def _file_record_to_dict(rec) -> Dict[str, Any]:
    """Convert a database FileRecord dataclass to a JSON-safe dict."""
    return {
        "id": rec.id,
        "file_path": rec.file_path,
        "file_name": rec.file_name,
        "file_size": rec.file_size,
        "file_type": rec.file_type,
        "modified_time": str(rec.modified_time) if rec.modified_time else None,
        "created_time": str(rec.created_time) if rec.created_time else None,
        "analysis_status": rec.analysis_status.value if hasattr(rec.analysis_status, "value") else rec.analysis_status,
        "semantic_categories": rec.semantic_categories,
        "directory_path": rec.directory_path,
        "added_time": str(rec.added_time) if rec.added_time else None,
        "semantic_filename": rec.semantic_filename,
        "metadata": rec.metadata,
        "spatiotemporal_analysis_status": rec.spatiotemporal_analysis_status,
        "original_created_time": rec.original_created_time,
        "location": rec.location,
        "caption_analysis_status": rec.caption_analysis_status,
    }


# ===========================================================================
# API Endpoints
# ===========================================================================

# ---------------------------------------------------------------------------
# GET /api/health
# ---------------------------------------------------------------------------
@app.get("/api/health")
async def health_check() -> Dict[str, Any]:
    """Health check endpoint. Returns status and whether models are loaded."""
    try:
        db = _get_db()
        conn = db._get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM files")
        file_count = cursor.fetchone()[0]
        return {"status": "ok", "models_loaded": _models_loaded, "file_count": file_count}
    except Exception as exc:
        return {"status": "error", "models_loaded": False, "error": str(exc)}


# ---------------------------------------------------------------------------
# POST /api/scan
# ---------------------------------------------------------------------------
@app.post("/api/scan")
async def scan_directory(req: ScanRequest) -> Dict[str, Any]:
    """Scan a directory for supported files.

    The scanner registers found files in the database automatically.
    Returns a list of file paths that were found.
    """
    if not os.path.exists(req.directory_path):
        raise HTTPException(status_code=400, detail=f"Directory does not exist: {req.directory_path}")

    try:
        scanner = _get_scanner()
        db = _get_db()
        # DirectoryScanner.scan_directory(directory, recursive, extensions, db_manager)
        files = scanner.scan_directory(
            directory=req.directory_path,
            recursive=req.recursive,
            db_manager=db,
        )
        return {"files": files, "count": len(files)}
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/parse
# ---------------------------------------------------------------------------
@app.post("/api/parse")
async def parse_file(req: ParseRequest) -> Dict[str, Any]:
    """Parse a single file and return its data blocks.

    Does NOT write to the database (use /api/analyze for the full pipeline).
    """
    if not os.path.exists(req.file_path):
        raise HTTPException(status_code=404, detail=f"File not found: {req.file_path}")

    try:
        parser = _get_parser()
        # DataParser.parse_file(file_path, db_manager=None, file_id=None, parsing_mode=None)
        blocks = parser.parse_file(
            file_path=req.file_path,
            parsing_mode=req.parsing_mode,
        )

        blocks_data = []
        for block in blocks:
            block_dict = {
                "block_id": block.block_id,
                "modality": block.modality.value if hasattr(block.modality, "value") else str(block.modality),
                "addr": block.addr,
                "page_number": block.page_number,
                "metadata": block.metadata,
                "file_path": block.file_path,
            }
            blocks_data.append(block_dict)

            # Try to include the text content from the addr cache file
            if block.addr and os.path.exists(block.addr):
                try:
                    modality_str = str(block.modality)
                    if "IMAGE" not in modality_str:
                        with open(block.addr, "r", encoding="utf-8") as f:
                            block_dict["content"] = f.read()[:8192]
                except Exception:
                    pass

        return {"blocks": blocks_data, "count": len(blocks_data)}
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/analyze
# ---------------------------------------------------------------------------
@app.post("/api/analyze")
async def analyze_file(req: AnalyzeRequest) -> Dict[str, Any]:
    """Full analysis pipeline for a single file.

    Steps:
    1. Register file in DB (if not already present)
    2. Parse the file into data blocks (written to DB)
    3. Generate semantic representations (written to DB)
    4. Classify each semantic block (written to DB)
    """
    if not os.path.exists(req.file_path):
        raise HTTPException(status_code=404, detail=f"File not found: {req.file_path}")

    try:
        from database.database import FileStatus

        db = _get_db()
        parser = _get_parser()
        semantic_rep = _get_semantic_rep()

        # Step 1: Register file in DB
        file_name = os.path.basename(req.file_path)
        file_ext = os.path.splitext(file_name)[1].lower()
        stat = os.stat(req.file_path)

        file_id = db.add_file(
            file_path=req.file_path,
            file_name=file_name,
            file_size=stat.st_size,
            file_type=file_ext,
            modified_time=datetime.fromtimestamp(stat.st_mtime),
            created_time=datetime.fromtimestamp(stat.st_ctime),
            directory_path=os.path.dirname(req.file_path),
        )

        if file_id < 0:
            # File already exists in DB (INSERT OR IGNORE); look it up
            existing = db.get_file_by_path(req.file_path)
            if existing:
                file_id = existing.id
            else:
                raise HTTPException(status_code=500, detail="Failed to register file in database")

        # Step 2: Parse file -- DataParser handles DB writes for data blocks
        blocks = parser.parse_file(
            file_path=req.file_path,
            db_manager=db,
            file_id=file_id,
            parsing_mode=req.parsing_mode,
        )

        db.update_file_status(file_id, FileStatus.PARSED)

        # Step 3: Generate semantic representations
        semantic_blocks = []
        if blocks:
            # Determine whether we should use represent_first_page_blocks
            first_page_blocks = []
            for b in blocks:
                meta = b.metadata or {}
                pm = meta.get("parsing_mode", "")
                if pm in ("light_first_page",):
                    first_page_blocks.append(b)

            if first_page_blocks:
                # Combine first-page blocks into a single semantic block
                sb = semantic_rep.represent_first_page_blocks(
                    first_page_blocks,
                    db_manager=db,
                    file_id=file_id,
                )
                semantic_blocks.append(sb)
            else:
                # Process each block individually
                data_block_records = db.get_data_blocks_by_file(file_id)
                block_id_to_db_id = {dbr.block_id: dbr.id for dbr in data_block_records}

                for block in blocks:
                    db_block_id = block_id_to_db_id.get(block.block_id)
                    sb = semantic_rep.represent(
                        block,
                        db_manager=db,
                        data_block_id=db_block_id,
                        file_id=file_id,
                    )
                    semantic_blocks.append(sb)

        db.update_file_status(file_id, FileStatus.PRELIMINARY)

        # Step 4: Classify semantic blocks
        classification_results = []
        if semantic_blocks:
            try:
                classification = _get_semantic_classification()
                if not classification._is_initialized:
                    classification.initialize()
                results = classification.classify_batch(
                    semantic_blocks,
                    db_manager=db,
                    file_id=file_id,
                )
                for r in results:
                    classification_results.append({
                        "block_id": r.block_id,
                        "category_name": r.category_name,
                        "confidence": r.confidence,
                        "all_scores": r.all_scores,
                    })
            except Exception as cls_exc:
                print(f"[API] Classification step failed: {cls_exc}")
                traceback.print_exc()

        # Build response
        blocks_data = []
        for block in blocks:
            blocks_data.append({
                "block_id": block.block_id,
                "modality": block.modality.value if hasattr(block.modality, "value") else str(block.modality),
                "addr": block.addr,
                "page_number": block.page_number,
                "metadata": block.metadata,
            })

        sb_data = []
        for sb in semantic_blocks:
            sb_data.append({
                "block_id": sb.block_id,
                "text_description": sb.text_description,
                "keywords": sb.keywords,
                "has_vector": sb.semantic_vector is not None,
                "vector_dim": len(sb.semantic_vector) if sb.semantic_vector is not None else 0,
                "modality": sb.modality,
            })

        return {
            "file_id": file_id,
            "blocks": blocks_data,
            "semantic_blocks": sb_data,
            "categories": classification_results,
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/classify
# ---------------------------------------------------------------------------
@app.post("/api/classify")
async def classify_text(req: ClassifyRequest) -> Dict[str, Any]:
    """Classify a piece of text using the semantic classification module.

    Two methods:
    - "similarity" (default): vector / keyword similarity against categories
    - "llm": cloud LLM classification
    """
    if not req.text or not req.text.strip():
        raise HTTPException(status_code=400, detail="text must not be empty")

    try:
        semantic_rep = _get_semantic_rep()
        classification = _get_semantic_classification()

        if not classification._is_initialized:
            classification.initialize()

        # Create a temporary semantic block from the text
        # SemanticRepresentation.represent_text(text, modality, block_id) -> SemanticBlock
        text_block = semantic_rep.represent_text(req.text)

        if req.method == "llm":
            try:
                from models.model_manager import get_llm_client
                client = get_llm_client()
                if client is None:
                    raise HTTPException(status_code=503, detail="LLM client not available")
                result = client.classify_text(
                    text=req.text,
                    categories=classification._category_names,
                    category_descriptions=classification._category_descriptions,
                )
                return {
                    "categories": [
                        {
                            "category": result.get("category", "unknown"),
                            "confidence": result.get("confidence", 0.0),
                            "reasoning": result.get("reasoning", ""),
                        }
                    ]
                }
            except HTTPException:
                raise
            except Exception as exc:
                traceback.print_exc()
                raise HTTPException(status_code=500, detail=str(exc))
        else:
            # SemanticClassification.classify(block) -> ClassificationResult
            result = classification.classify(text_block)
            return {
                "categories": [
                    {
                        "category": result.category_name,
                        "confidence": result.confidence,
                        "all_scores": result.all_scores,
                    }
                ]
            }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/search
# ---------------------------------------------------------------------------
@app.post("/api/search")
async def semantic_search(req: SearchRequest) -> Dict[str, Any]:
    """Perform a semantic search across all indexed files."""
    if not req.query or not req.query.strip():
        raise HTTPException(status_code=400, detail="query must not be empty")

    try:
        # SemanticQuery.search(query_text, top_k, top_m) -> SearchResult
        # SearchResult has: query_text, top_k, top_m, semantic_blocks, files, search_time
        # files: List[FileResult] where FileResult has file_id, file_path, file_name,
        #        similarity_score, matched_blocks
        # semantic_blocks: List[SemanticBlockResult] with semantic_block_id, file_id,
        #                  text_description, keywords, similarity_score
        sq = _get_semantic_query()
        result = sq.search(query_text=req.query, top_k=req.top_k)

        files_data = []
        for fr in result.files:
            matched = []
            for mb in fr.matched_blocks:
                matched.append({
                    "semantic_block_id": mb.semantic_block_id,
                    "file_id": mb.file_id,
                    "text_description": mb.text_description,
                    "keywords": mb.keywords,
                    "similarity_score": mb.similarity_score,
                })
            files_data.append({
                "file_id": fr.file_id,
                "file_path": fr.file_path,
                "file_name": fr.file_name,
                "similarity_score": fr.similarity_score,
                "matched_blocks": matched,
            })

        blocks_data = []
        for sbr in result.semantic_blocks:
            blocks_data.append({
                "semantic_block_id": sbr.semantic_block_id,
                "file_id": sbr.file_id,
                "text_description": sbr.text_description,
                "keywords": sbr.keywords,
                "similarity_score": sbr.similarity_score,
            })

        return {
            "results": files_data,
            "semantic_blocks": blocks_data,
            "query": req.query,
            "total_files": len(files_data),
            "total_blocks": len(blocks_data),
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/ocr
# ---------------------------------------------------------------------------
@app.post("/api/ocr")
async def ocr_image(req: OcrRequest) -> Dict[str, Any]:
    """Run OCR on an image and return the recognised text."""
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=404, detail=f"Image not found: {req.image_path}")

    try:
        from models.model_manager import get_ocr_instance
        ocr_func = get_ocr_instance(use_ocr=True)

        if ocr_func is None:
            raise HTTPException(status_code=503, detail="OCR engine not available")

        text = ocr_func(req.image_path)

        # PaddleOCR does not expose per-image confidence in this wrapper;
        # use a simple heuristic.
        confidence = 0.9 if (text and len(text.strip()) > 0) else 0.0

        return {"text": text or "", "confidence": confidence}
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/embed
# ---------------------------------------------------------------------------
@app.post("/api/embed")
async def embed_text(req: EmbedRequest) -> Dict[str, Any]:
    """Generate an embedding vector for the given text."""
    if not req.text or not req.text.strip():
        raise HTTPException(status_code=400, detail="text must not be empty")

    try:
        semantic_rep = _get_semantic_rep()
        # SemanticRepresentation.encode_text(text) -> np.ndarray or None
        vector = semantic_rep.encode_text(req.text)

        if vector is None:
            raise HTTPException(status_code=503, detail="Embedding model not available")

        vector_list = vector.tolist()
        return {"vector": vector_list, "dimension": len(vector_list)}
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/llm/describe
# ---------------------------------------------------------------------------
@app.post("/api/llm/describe")
async def llm_describe(req: LlmDescribeRequest) -> Dict[str, Any]:
    """Use the cloud LLM to generate a description of the given text."""
    if not req.text or not req.text.strip():
        raise HTTPException(status_code=400, detail="text must not be empty")

    try:
        from models.model_manager import get_llm_client, is_llm_available

        if not is_llm_available():
            raise HTTPException(status_code=503, detail="LLM service not available")

        client = get_llm_client()

        # CloudLLMClient.classify_text(text, categories, category_descriptions)
        # Returns dict with "category", "confidence", "reasoning"
        categories = ["综合描述", "技术内容", "商务内容", "学术内容", "个人内容"]

        if req.prompt:
            categories = [req.prompt]

        result = client.classify_text(
            text=req.text,
            categories=categories,
            category_descriptions={c: c for c in categories},
        )

        reasoning = result.get("reasoning", "")
        description = reasoning if reasoning else result.get("category", "")

        return {"description": description}
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# GET /api/files
# ---------------------------------------------------------------------------
@app.get("/api/files")
async def list_files(
    directory: Optional[str] = None,
    file_type: Optional[str] = None,
    status: Optional[int] = None,
    limit: Optional[int] = None,
) -> Dict[str, Any]:
    """List all files from the database, with optional filters."""
    try:
        db = _get_db()
        records = []

        if file_type:
            records = db.get_files_by_type(file_type)
        elif directory:
            records = db.get_files_by_directory(directory)
        elif status is not None:
            from database.database import FileStatus
            records = db.get_files_by_status(FileStatus(status))
        else:
            # No filter -- fetch all files via direct SQL
            conn = db._get_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM files ORDER BY added_time DESC")
            rows = cursor.fetchall()
            records = [db._row_to_file_record(row) for row in rows]

        if limit is not None and limit > 0:
            records = records[:limit]

        return {"files": [_file_record_to_dict(r) for r in records], "count": len(records)}
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# GET /api/files/{file_id}
# ---------------------------------------------------------------------------
@app.get("/api/files/{file_id}")
async def get_file_details(file_id: int) -> Dict[str, Any]:
    """Get detailed information for a single file, including its data blocks,
    semantic blocks, and classification results."""
    try:
        db = _get_db()
        rec = db.get_file_by_id(file_id)
        if rec is None:
            raise HTTPException(status_code=404, detail=f"File not found: id={file_id}")

        data_blocks = db.get_data_blocks_by_file(file_id)
        semantic_blocks = db.get_semantic_blocks_by_file(file_id)
        classification_results = db.get_classification_results_by_file(file_id)

        return {
            "file": _file_record_to_dict(rec),
            "data_blocks": [
                {
                    "id": dbr.id,
                    "block_id": dbr.block_id,
                    "modality": dbr.modality,
                    "addr": dbr.addr,
                    "page_number": dbr.page_number,
                    "metadata": dbr.metadata,
                }
                for dbr in data_blocks
            ],
            "semantic_blocks": [
                {
                    "id": sb.id,
                    "semantic_block_id": sb.semantic_block_id,
                    "data_block_ids": sb.data_block_ids,
                    "file_id": sb.file_id,
                    "text_description": sb.text_description,
                    "keywords": sb.keywords,
                    "semantic_filename": sb.semantic_filename,
                    "metadata": sb.metadata,
                    "created_time": str(sb.created_time) if sb.created_time else None,
                }
                for sb in semantic_blocks
            ],
            "classification_results": [
                {
                    "id": cr.id,
                    "semantic_block_id": cr.semantic_block_id,
                    "category_name": cr.category_name,
                    "category_system_name": cr.category_system_name,
                    "confidence": cr.confidence,
                    "all_scores": cr.all_scores,
                    "created_time": str(cr.created_time) if cr.created_time else None,
                }
                for cr in classification_results
            ],
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# GET /api/categories
# ---------------------------------------------------------------------------
@app.get("/api/categories")
async def get_categories() -> Dict[str, Any]:
    """Get category statistics from the database, grouped by category system."""
    try:
        db = _get_db()
        all_categories = db.get_all_semantic_categories()

        systems: Dict[str, List[Dict[str, Any]]] = {}
        for cat in all_categories:
            sys_name = cat.category_system_name
            if sys_name not in systems:
                systems[sys_name] = []
            systems[sys_name].append({
                "id": cat.id,
                "category_name": cat.category_name,
                "description": cat.description,
                "keywords": cat.keywords,
                "category_source": cat.category_source,
                "created_time": str(cat.created_time) if cat.created_time else None,
            })

        return {
            "category_systems": systems,
            "total_categories": len(all_categories),
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/semantic-represent
# ---------------------------------------------------------------------------
@app.post("/api/semantic-represent")
async def semantic_represent_file(req: SemanticRepresentRequest) -> Dict[str, Any]:
    """Generate semantic representation for a file that has already been parsed."""
    try:
        db = _get_db()
        semantic_rep = _get_semantic_rep()

        # Get file record
        file_record = db.get_file_by_id(req.file_id)
        if not file_record:
            raise HTTPException(status_code=404, detail=f"File {req.file_id} not found")

        # Get data blocks for this file
        data_blocks = db.get_data_blocks_by_file(req.file_id)
        if not data_blocks:
            return {
                "file_id": req.file_id,
                "semantic_blocks_count": 0,
                "success": True,
                "message": "No data blocks found for this file"
            }

        # Generate semantic representation for each data block
        semantic_blocks_count = 0
        for block_record in data_blocks:
            try:
                from data_parser.data_parser import DataBlock, ModalityType
                block = DataBlock(
                    block_id=block_record.block_id,
                    modality=ModalityType(block_record.modality),
                    addr=block_record.addr,
                    file_path=file_record.file_path,
                    page_number=block_record.page_number,
                    metadata=block_record.metadata or {}
                )
                sb = semantic_rep.represent(block, db, block_record.id, req.file_id)
                if sb:
                    semantic_blocks_count += 1
            except Exception as e:
                print(f"[API] Error representing block {block_record.block_id}: {e}")

        # Update file status to PRELIMINARY
        from database.database import FileStatus
        db.update_file_status(req.file_id, FileStatus.PRELIMINARY)

        return {
            "file_id": req.file_id,
            "semantic_blocks_count": semantic_blocks_count,
            "success": True
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/classify-file/{file_id}
# ---------------------------------------------------------------------------
@app.post("/api/classify-file/{file_id}")
async def classify_file(file_id: int, req: ClassifyFileRequest = None) -> Dict[str, Any]:
    """Classify a file that already has semantic representation."""
    try:
        db = _get_db()
        classifier = _get_semantic_classification()
        classifier.initialize()

        # Get file record
        file_record = db.get_file_by_id(file_id)
        if not file_record:
            raise HTTPException(status_code=404, detail=f"File {file_id} not found")

        # Get semantic blocks for this file
        semantic_blocks = db.get_semantic_blocks_by_file(file_id)
        if not semantic_blocks:
            return {
                "file_id": file_id,
                "categories": [],
                "primary_category": "未分类",
                "confidence": 0,
                "success": False,
                "message": "No semantic blocks found for this file"
            }

        # Convert to SemanticBlock objects for classification
        from semantic_representation.semantic_block import SemanticBlock
        sb_objects = []
        for sb_record in semantic_blocks:
            sb = SemanticBlock(
                block_id=sb_record.block_id,
                text_description=sb_record.text_description,
                keywords=sb_record.keywords or [],
                summary=sb_record.summary
            )
            sb_objects.append(sb)

        # Classify each semantic block
        classification_results = classifier.classify_batch(sb_objects, db, file_id)

        # Aggregate results
        file_categories = {}
        total_confidence = 0.0
        for sb, result in zip(sb_objects, classification_results):
            category = result.category_name
            conf = result.confidence
            total_confidence += conf
            if category not in file_categories:
                file_categories[category] = {"confidence_sum": 0.0, "block_count": 0}
            file_categories[category]["confidence_sum"] += conf
            file_categories[category]["block_count"] += 1

        # Calculate normalized confidence
        file_category_list = []
        for cat, data in file_categories.items():
            normalized_conf = data["confidence_sum"] / total_confidence if total_confidence > 0 else 0
            file_category_list.append({
                "category": cat,
                "confidence": normalized_conf,
                "block_count": data["block_count"]
            })
        file_category_list.sort(key=lambda x: x["confidence"], reverse=True)

        # Update file semantic categories
        db.update_file_semantic_categories(file_id, file_category_list)

        primary_category = file_category_list[0]["category"] if file_category_list else "未分类"
        primary_confidence = file_category_list[0]["confidence"] if file_category_list else 0

        return {
            "file_id": file_id,
            "categories": file_category_list,
            "primary_category": primary_category,
            "confidence": primary_confidence,
            "success": True
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# DELETE /api/history
# ---------------------------------------------------------------------------
@app.delete("/api/history")
async def clear_history() -> Dict[str, Any]:
    """Clear all analysis history (files, blocks, semantic blocks, classification results)."""
    try:
        db = _get_db()

        # Clear all data
        success = db.clear_all_data()

        return {
            "deleted_files": 0,
            "deleted_blocks": 0,
            "success": success,
            "message": "All history cleared successfully" if success else "Clear failed"
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# DELETE /api/history/classification
# ---------------------------------------------------------------------------
@app.delete("/api/history/classification")
async def clear_classification_history() -> Dict[str, Any]:
    """Clear only classification results, keeping file records and semantic blocks."""
    try:
        db = _get_db()

        # Clear classification results
        db.clear_classification_results()

        # Clear semantic categories from file records
        from database.database import FileStatus
        files = db.get_files_by_status(FileStatus.PRELIMINARY)
        files.extend(db.get_files_by_status(FileStatus.DEEP))
        for f in files:
            db.update_file_semantic_categories(f.id, [])

        return {
            "success": True,
            "message": "Classification results cleared successfully"
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/image/metadata
# ---------------------------------------------------------------------------
@app.post("/api/image/metadata")
async def analyze_image_metadata(req: ImageMetadataRequest) -> Dict[str, Any]:
    """Extract metadata (EXIF, GPS, dimensions) from an image file."""
    try:
        db = _get_db()

        # Determine file path
        file_path = req.file_path
        file_id = req.file_id

        if file_id and not file_path:
            file_record = db.get_file_by_id(file_id)
            if not file_record:
                raise HTTPException(status_code=404, detail=f"File {file_id} not found")
            file_path = file_record.file_path
        elif not file_path and not file_id:
            raise HTTPException(status_code=400, detail="Either file_id or file_path must be provided")

        # Extract metadata
        from semantic_representation.image_metadata_extractor import ImageMetadataExtractor
        extractor = ImageMetadataExtractor()
        metadata = extractor.extract_metadata(file_path)

        # Update file metadata in database
        if file_id and metadata:
            metadata_dict = {}
            if metadata.get("capture_time"):
                metadata_dict["capture_time"] = str(metadata["capture_time"])
            if metadata.get("location"):
                metadata_dict["location"] = metadata["location"]
            if metadata.get("gps_coordinates"):
                metadata_dict["gps_coordinates"] = metadata["gps_coordinates"]
            if metadata.get("dimensions"):
                metadata_dict["dimensions"] = metadata["dimensions"]
            db.update_file_metadata(file_id, metadata_dict)

        return {
            "file_id": file_id,
            "capture_time": str(metadata.get("capture_time")) if metadata.get("capture_time") else None,
            "location": metadata.get("location"),
            "gps_coordinates": metadata.get("gps_coordinates"),
            "dimensions": metadata.get("dimensions"),
            "success": True
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/image/caption
# ---------------------------------------------------------------------------
@app.post("/api/image/caption")
async def generate_image_caption(req: ImageCaptionRequest) -> Dict[str, Any]:
    """Generate caption and tags for an image using LLM vision capability."""
    try:
        db = _get_db()

        # Determine file path
        file_path = req.file_path
        file_id = req.file_id

        if file_id and not file_path:
            file_record = db.get_file_by_id(file_id)
            if not file_record:
                raise HTTPException(status_code=404, detail=f"File {file_id} not found")
            file_path = file_record.file_path
        elif not file_path and not file_id:
            raise HTTPException(status_code=400, detail="Either file_id or file_path must be provided")

        # Generate caption and tags
        from semantic_representation.image_caption_tagger import ImageCaptionTagger
        tagger = ImageCaptionTagger()
        result = tagger.generate_caption_and_tags(file_path)

        # Update file metadata in database
        if file_id and result:
            metadata_dict = {}
            if result.get("caption"):
                metadata_dict["caption"] = result["caption"]
            if result.get("tags"):
                metadata_dict["tags"] = result["tags"]
            db.update_file_metadata(file_id, metadata_dict)

        return {
            "file_id": file_id,
            "caption": result.get("caption") if result else None,
            "tags": result.get("tags") if result else [],
            "success": True
        }
    except HTTPException:
        raise
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/debug/sync
# ---------------------------------------------------------------------------
@app.post("/api/debug/sync")
async def sync_database(req: SyncDatabaseRequest) -> Dict[str, Any]:
    """Receive database sync from HarmonyOS device.

    Saves the database file to a local backup location.
    """
    try:
        # Decode base64 database content
        db_content = base64.b64decode(req.database_base64)

        # Create backup directory
        backup_dir = os.path.join(BASE_DIR, "db_sync_backups")
        os.makedirs(backup_dir, exist_ok=True)

        # Generate backup filename with timestamp
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = os.path.join(backup_dir, f"FileAnalyzer_sync_{timestamp}.db")

        # Write database file
        with open(backup_path, "wb") as f:
            f.write(db_content)

        print(f"[API] Database synced from device: {req.database_size} bytes -> {backup_path}")

        return {
            "success": True,
            "message": "Database sync successful",
            "backup_path": backup_path,
            "size": req.database_size,
            "timestamp": req.timestamp
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/debug/sync_tables
# ---------------------------------------------------------------------------
@app.post("/api/debug/sync_tables")
async def sync_table_data(req: SyncTablesRequest) -> Dict[str, Any]:
    """Receive table data sync from HarmonyOS device."""
    try:
        # Create backup directory
        backup_dir = os.path.join(BASE_DIR, "db_sync_backups")
        os.makedirs(backup_dir, exist_ok=True)

        # Generate backup filename with timestamp
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = os.path.join(backup_dir, f"tables_sync_{timestamp}.json")

        # Save as JSON
        import json
        with open(backup_path, "w", encoding="utf-8") as f:
            json.dump(req.tables, f, ensure_ascii=False, indent=2)

        print(f"[API] Table data synced from device: {len(req.tables)} tables -> {backup_path}")

        return {
            "success": True,
            "message": "Table sync successful",
            "backup_path": backup_path,
            "tables_count": len(req.tables),
            "timestamp": req.timestamp
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/debug/sync_cache_file
# ---------------------------------------------------------------------------
@app.post("/api/debug/sync_cache_file")
async def sync_cache_file(req: SyncCacheFileRequest) -> Dict[str, Any]:
    """Receive a single cache file sync from HarmonyOS device.

    Saves cache files to a local debug_sync_data/cache_content directory.
    """
    try:
        # Decode base64 content
        file_content = base64.b64decode(req.content_base64)

        # Create cache content directory
        cache_dir = os.path.join(BASE_DIR, "debug_sync_data", "cache_content")
        os.makedirs(cache_dir, exist_ok=True)

        # Create subdirectories based on relative path
        file_path = os.path.join(cache_dir, req.relative_path)
        os.makedirs(os.path.dirname(file_path), exist_ok=True)

        # Write cache file
        with open(file_path, "wb") as f:
            f.write(file_content)

        print(f"[API] Cache file synced: {req.relative_path} ({req.file_size} bytes)")

        return {
            "success": True,
            "message": "Cache file sync successful",
            "path": req.relative_path,
            "size": req.file_size,
            "timestamp": req.timestamp
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/debug/sync_cache_complete
# ---------------------------------------------------------------------------
@app.post("/api/debug/sync_cache_complete")
async def sync_cache_complete(req: SyncCacheCompleteRequest) -> Dict[str, Any]:
    """Signal that all cache files have been synced.

    Creates a summary file of the sync operation.
    """
    try:
        # Create summary
        cache_dir = os.path.join(BASE_DIR, "debug_sync_data", "cache_content")

        summary_path = os.path.join(cache_dir, "_sync_summary.txt")
        with open(summary_path, "w", encoding="utf-8") as f:
            f.write(f"Cache Sync Summary\n")
            f.write(f"==================\n")
            f.write(f"Timestamp: {req.timestamp}\n")
            f.write(f"Total files: {req.total_files}\n")
            f.write(f"Total size: {req.total_size} bytes\n")

        print(f"[API] Cache sync complete: {req.total_files} files, {req.total_size} bytes")

        return {
            "success": True,
            "message": "Cache sync complete",
            "total_files": req.total_files,
            "total_size": req.total_size,
            "cache_dir": cache_dir,
            "timestamp": req.timestamp
        }
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# POST /api/debug/log
# ---------------------------------------------------------------------------
@app.post("/api/debug/log")
async def receive_debug_log(req: LogRequest) -> Dict[str, Any]:
    """Receive debug log from HarmonyOS device."""
    try:
        # Print to console
        print(f"[Device Log] [{req.level}] {req.message}")
        if req.data:
            print(f"[Device Log Data] {req.data}")

        # Save to log file
        log_dir = os.path.join(BASE_DIR, "device_logs")
        os.makedirs(log_dir, exist_ok=True)

        log_path = os.path.join(log_dir, "device.log")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"{req.timestamp} [{req.level}] {req.message}\n")
            if req.data:
                f.write(f"  Data: {json.dumps(req.data, ensure_ascii=False)}\n")

        return {"success": True}
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))


# ===========================================================================
# Entrypoint -- run with uvicorn
# ===========================================================================

def main():
    """Run the API server using uvicorn."""
    import uvicorn

    port = int(os.environ.get("API_PORT", 8765))
    host = os.environ.get("API_HOST", "0.0.0.0")

    print(f"[API] Starting File Analyzer API on {host}:{port}")
    uvicorn.run(
        "api_server:app",
        host=host,
        port=port,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
