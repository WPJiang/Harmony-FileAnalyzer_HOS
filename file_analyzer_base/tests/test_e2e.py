"""
End-to-End Integration Test for FileAnalyzer API

Tests the complete pipeline:
1. Health check
2. Directory scanning
3. File parsing
4. OCR
5. Embedding
6. Classification
7. Analysis
8. Search
"""

import os
import sys
import time
import json
import requests
from pathlib import Path

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE_DIR)

BASE_URL = "http://localhost:8765"


def test_health():
    """Test health check endpoint"""
    print("\n=== Testing Health Check ===")
    response = requests.get(f"{BASE_URL}/api/health")
    assert response.status_code == 200, f"Health check failed: {response.text}"
    data = response.json()
    print(f"Status: {data['status']}")
    print(f"Models loaded: {data['models_loaded']}")
    print(f"File count: {data['file_count']}")
    assert data['status'] == 'ok', "Status should be ok"
    print("✓ Health check PASSED")
    return data


def test_scan():
    """Test directory scanning"""
    print("\n=== Testing Directory Scan ===")
    test_dir = os.path.join(BASE_DIR, "tests", "test_data")
    os.makedirs(test_dir, exist_ok=True)

    # Create test files
    test_files = []
    for i, (name, content) in enumerate([
        ("test1.txt", "This is a technical document about machine learning and AI systems."),
        ("test2.txt", "Business report for Q4 2024 with revenue projections."),
        ("test3.txt", "Research paper on neural network architectures."),
    ]):
        path = os.path.join(test_dir, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        test_files.append(path)

    response = requests.post(
        f"{BASE_URL}/api/scan",
        json={"directory_path": test_dir, "recursive": False}
    )
    assert response.status_code == 200, f"Scan failed: {response.text}"
    data = response.json()
    print(f"Found {data['total']} files")
    for f in data['files'][:5]:
        print(f"  - {f['name']}")
    print("✓ Scan PASSED")
    return test_files


def test_parse(file_path: str):
    """Test file parsing"""
    print(f"\n=== Testing Parse: {os.path.basename(file_path)} ===")
    response = requests.post(
        f"{BASE_URL}/api/parse",
        json={"file_path": file_path}
    )
    assert response.status_code == 200, f"Parse failed: {response.text}"
    data = response.json()
    print(f"Parsed {data['count']} blocks")
    for block in data['blocks'][:3]:
        print(f"  - Block: {block['block_id'][:12]}... ({block['modality']})")
    print("✓ Parse PASSED")
    return data


def test_ocr():
    """Test OCR functionality"""
    print("\n=== Testing OCR ===")
    try:
        from PIL import Image, ImageDraw

        # Create test image
        img_path = os.path.join(BASE_DIR, "tests", "test_ocr.png")
        img = Image.new('RGB', (400, 100), 'white')
        draw = ImageDraw.Draw(img)
        draw.text((20, 30), "Hello OCR Test 123", fill='black')
        img.save(img_path)

        response = requests.post(
            f"{BASE_URL}/api/ocr",
            json={"image_path": img_path}
        )
        assert response.status_code == 200, f"OCR failed: {response.text}"
        data = response.json()
        print(f"OCR text: {data['text'][:50]}...")
        print(f"Confidence: {data['confidence']}")
        print("✓ OCR PASSED")
        return data
    except ImportError:
        print("⚠ OCR test skipped (PIL not available)")
        return None


def test_embed():
    """Test embedding generation"""
    print("\n=== Testing Embedding ===")
    response = requests.post(
        f"{BASE_URL}/api/embed",
        json={"text": "This is a test document about machine learning"}
    )
    assert response.status_code == 200, f"Embed failed: {response.text}"
    data = response.json()
    print(f"Vector dimension: {data['dimension']}")
    print(f"First 5 values: {data['vector'][:5]}")
    assert data['dimension'] == 384, f"Expected 384, got {data['dimension']}"
    print("✓ Embedding PASSED")
    return data


def test_classify():
    """Test text classification"""
    print("\n=== Testing Classification ===")
    test_texts = [
        "This document describes the API endpoints and system architecture.",
        "Q4 revenue increased by 15% compared to last year.",
        "The neural network model achieved 95% accuracy on the test set.",
    ]

    for text in test_texts:
        response = requests.post(
            f"{BASE_URL}/api/classify",
            json={"text": text, "method": "similarity"}
        )
        assert response.status_code == 200, f"Classify failed: {response.text}"
        data = response.json()
        if data['categories']:
            cat = data['categories'][0]
            print(f"  '{text[:40]}...' -> {cat['category']} ({cat['confidence']:.2f})")

    print("✓ Classification PASSED")


def test_analyze(file_path: str):
    """Test full analysis pipeline"""
    print(f"\n=== Testing Analyze: {os.path.basename(file_path)} ===")
    response = requests.post(
        f"{BASE_URL}/api/analyze",
        json={"file_path": file_path}
    )
    assert response.status_code == 200, f"Analyze failed: {response.text}"
    data = response.json()
    print(f"File ID: {data['file_id']}")
    print(f"Blocks: {data['blocks_count']}")
    print(f"Semantic blocks: {data['semantic_blocks_count']}")
    print("Categories:")
    for cat in data['categories'][:3]:
        print(f"  - {cat['category']}: {cat['confidence']:.2f}")
    print("✓ Analyze PASSED")
    return data


def test_search():
    """Test semantic search"""
    print("\n=== Testing Search ===")
    response = requests.post(
        f"{BASE_URL}/api/search",
        json={"query": "machine learning technology", "top_k": 5}
    )
    assert response.status_code == 200, f"Search failed: {response.text}"
    data = response.json()
    print(f"Found {data['total_files']} files")
    for result in data['results'][:3]:
        print(f"  - {result['file_name']}: {result['similarity_score']:.3f}")
    print("✓ Search PASSED")


def test_files():
    """Test file listing"""
    print("\n=== Testing File List ===")
    response = requests.get(f"{BASE_URL}/api/files")
    assert response.status_code == 200, f"File list failed: {response.text}"
    data = response.json()
    print(f"Total files: {data['count']}")
    for f in data['files'][:5]:
        print(f"  - {f['file_name']} ({f['file_type']})")
    print("✓ File list PASSED")


def test_categories():
    """Test category statistics"""
    print("\n=== Testing Categories ===")
    response = requests.get(f"{BASE_URL}/api/categories")
    assert response.status_code == 200, f"Categories failed: {response.text}"
    data = response.json()
    print(f"Total categories: {data['total_categories']}")
    for system_name, categories in data['category_systems'].items():
        print(f"  System: {system_name}")
        for cat in categories[:3]:
            print(f"    - {cat['category_name']}")
    print("✓ Categories PASSED")


def main():
    """Run all tests"""
    print("=" * 60)
    print("FileAnalyzer API End-to-End Test")
    print("=" * 60)

    # Start the server first
    print("\nMake sure the API server is running:")
    print(f"  cd {BASE_DIR}")
    print("  python api_server.py")
    print()

    try:
        # Run tests in order
        health = test_health()

        if not health.get('models_loaded'):
            print("\n⚠ Warning: Models not fully loaded, some tests may fail")

        test_files = test_scan()

        if test_files:
            test_parse(test_files[0])
            analyze_result = test_analyze(test_files[0])

        test_ocr()
        test_embed()
        test_classify()
        test_files()
        test_categories()
        test_search()

        print("\n" + "=" * 60)
        print("✓ ALL TESTS PASSED")
        print("=" * 60)

    except requests.exceptions.ConnectionError:
        print("\n✗ ERROR: Cannot connect to API server")
        print(f"  Make sure the server is running on {BASE_URL}")
        return 1
    except AssertionError as e:
        print(f"\n✗ TEST FAILED: {e}")
        return 1
    except Exception as e:
        print(f"\n✗ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return 1

    return 0


if __name__ == "__main__":
    exit(main())