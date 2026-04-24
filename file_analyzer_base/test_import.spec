# -*- mode: python ; coding: utf-8 -*-
"""
简单测试打包配置
"""
import os
import sys
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

block_cipher = None

# 收集 torch 数据
torch_datas = []
try:
    torch_datas += collect_data_files('torch')
except:
    pass

# 收集 transformers 数据
transformers_datas = []
try:
    transformers_datas += collect_data_files('transformers')
except:
    pass

# 收集 sentence_transformers 数据
st_datas = []
st_imports = []
try:
    st_datas += collect_data_files('sentence_transformers')
    st_imports = collect_submodules('sentence_transformers')
except:
    pass

datas = []
datas.extend(torch_datas)
datas.extend(transformers_datas)
datas.extend(st_datas)

hiddenimports = [
    'torch',
    'torch.nn',
    'torch._C',
    'transformers',
    'sentence_transformers',
    'sklearn',
    'sklearn.cluster',
    'PyQt5',
    'PyQt5.QtCore',
    'PyQt5.QtGui',
    'PyQt5.QtWidgets',
]
hiddenimports.extend(st_imports)

a = Analysis(
    ['test_import.py'],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'pytest', 'test', 'tests'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='test_import',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='test_import',
)