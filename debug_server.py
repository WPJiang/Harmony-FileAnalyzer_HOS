#!/usr/bin/env python3
"""
Debug Server for HarmonyOS FileAnalyzer
Receives database sync data from the phone app on port 8766.

Usage:
    python debug_server.py
"""

import json
import base64
import os
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

SYNC_DIR = os.path.join(os.path.dirname(__file__), 'debug_sync_data')


class DebugHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body.decode('utf-8'))
        except Exception as e:
            self.send_json({'error': f'Invalid JSON: {e}'}, 400)
            return

        action = data.get('action', '')
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {self.path} action={action}")

        if self.path == '/api/debug/sync':
            self.handle_sync_database(data)
        elif self.path == '/api/debug/sync_tables':
            self.handle_sync_tables(data)
        elif self.path == '/api/debug/log':
            self.handle_log(data)
        else:
            self.send_json({'error': 'Unknown endpoint'}, 404)

    def handle_sync_database(self, data):
        """Save synced database file"""
        os.makedirs(SYNC_DIR, exist_ok=True)

        db_b64 = data.get('database_base64', '')
        db_size = data.get('database_size', 0)
        timestamp = data.get('timestamp', datetime.now().isoformat())

        if not db_b64:
            self.send_json({'error': 'No database data'}, 400)
            return

        try:
            db_bytes = base64.b64decode(db_b64)
            ts_str = datetime.now().strftime('%Y%m%d_%H%M%S')
            db_path = os.path.join(SYNC_DIR, f'FileAnalyzer_{ts_str}.db')

            with open(db_path, 'wb') as f:
                f.write(db_bytes)

            print(f"  Database saved: {db_path} ({len(db_bytes)} bytes)")
            print(f"  Original size: {db_size} bytes")

            # Also save as latest
            latest_path = os.path.join(SYNC_DIR, 'FileAnalyzer_latest.db')
            with open(latest_path, 'wb') as f:
                f.write(db_bytes)

            self.send_json({
                'status': 'ok',
                'message': f'Database saved ({len(db_bytes)} bytes)',
                'path': db_path,
                'timestamp': timestamp
            })
        except Exception as e:
            print(f"  Error saving database: {e}")
            self.send_json({'error': str(e)}, 500)

    def handle_sync_tables(self, data):
        """Save synced table data as JSON"""
        os.makedirs(SYNC_DIR, exist_ok=True)

        tables = data.get('tables', {})
        timestamp = data.get('timestamp', datetime.now().isoformat())

        ts_str = datetime.now().strftime('%Y%m%d_%H%M%S')
        json_path = os.path.join(SYNC_DIR, f'tables_{ts_str}.json')

        try:
            with open(json_path, 'w', encoding='utf-8') as f:
                json.dump(tables, f, ensure_ascii=False, indent=2)

            total_rows = sum(len(rows) for rows in tables.values())
            print(f"  Tables saved: {json_path}")
            print(f"  Tables: {', '.join(f'{k}({len(v)})' for k, v in tables.items())}")

            self.send_json({
                'status': 'ok',
                'message': f'Tables saved ({total_rows} rows)',
                'path': json_path
            })
        except Exception as e:
            self.send_json({'error': str(e)}, 500)

    def handle_log(self, data):
        """Print log message from phone"""
        level = data.get('level', 'INFO')
        message = data.get('message', '')
        log_data = data.get('data', {})

        prefix = {'ERROR': '❌', 'WARN': '⚠️', 'INFO': 'ℹ️', 'DEBUG': '🔍'}.get(level, '')
        print(f"  {prefix} [{level}] {message}")
        if log_data:
            print(f"    Data: {json.dumps(log_data, ensure_ascii=False)}")

        self.send_json({'status': 'ok'})

    def do_GET(self):
        if self.path == '/api/debug/health':
            self.send_json({'status': 'ok', 'server': 'debug_sync', 'port': 8766})
        else:
            self.send_json({'error': 'Use POST for sync'}, 404)

    def send_json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # Suppress default request logging


def main():
    port = 8766
    server = HTTPServer(('0.0.0.0', port), DebugHandler)
    print(f"Debug sync server running on http://0.0.0.0:{port}")
    print(f"Sync data will be saved to: {os.path.abspath(SYNC_DIR)}")
    print(f"Waiting for phone connection... (Ctrl+C to stop)")
    print()

    # Setup port forwarding hint
    print("Make sure HDC reverse port forwarding is set up:")
    print(f'  hdc rport tcp:{port} tcp:{port}')
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
        server.server_close()


if __name__ == '__main__':
    main()
