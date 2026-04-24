import sqlite3
import json
import os

def analyze_db(db_path, label):
    if not os.path.exists(db_path):
        print(f'{label}: File not found: {db_path}')
        return
    
    db = sqlite3.connect(db_path)
    cursor = db.cursor()
    
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    tables = [row[0] for row in cursor.fetchall()]
    print(f'\n{"="*60}')
    print(f'{label} Tables: {tables}')
    print(f'{"="*60}')
    
    for table in tables:
        if table.startswith('sqlite_'):
            continue
        cursor.execute(f'PRAGMA table_info({table})')
        columns = cursor.fetchall()
        print(f'\n--- {label}: {table} schema ---')
        for col in columns:
            print(f'  {col[1]:40s} {col[2]:10s} default={str(col[4]):20s} notnull={col[3]}')
        
        cursor.execute(f'SELECT COUNT(*) FROM {table}')
        count = cursor.fetchone()[0]
        print(f'  Row count: {count}')
        
        if count > 0:
            cursor.execute(f'SELECT * FROM {table} LIMIT 2')
            rows = cursor.fetchall()
            col_names = [c[1] for c in columns]
            for i, row in enumerate(rows):
                print(f'  --- Row {i} ---')
                for j, val in enumerate(row):
                    val_str = str(val)[:300] if val is not None else 'NULL'
                    print(f'    {col_names[j]}: {val_str}')
    
    db.close()

# Python database
analyze_db(r'D:\jiangweipeng\trae_code\file_analyzer\file_analyzer.db', 'Python-Windows')

# HarmonyOS database (latest)
sync_dir = r'D:\jiangweipeng\Harmony\FileAnalyzer_HOS\debug_sync_data'
if os.path.exists(sync_dir):
    files = [f for f in os.listdir(sync_dir) if f.endswith('.db')]
    print(f'\nSync DB files: {files}')
    latest = os.path.join(sync_dir, 'FileAnalyzer_latest.db')
    if os.path.exists(latest):
        analyze_db(latest, 'HarmonyOS-Latest')
