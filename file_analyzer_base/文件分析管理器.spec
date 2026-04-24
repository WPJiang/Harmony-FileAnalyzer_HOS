# -*- mode: python ; coding: utf-8 -*-
"""
文件分析管理器 打包配置
使用 conda file_analyzer 环境
"""

import os
import sys
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# 获取 conda 环境路径
conda_env_path = os.path.dirname(os.path.dirname(sys.executable))

block_cipher = None

# 收集 PyTorch 相关数据
torch_datas = []
try:
    from PyInstaller.utils.hooks import collect_data_files as collect_torch_data
    torch_datas += collect_torch_data('torch')
except:
    pass

# 收集 transformers 数据
transformers_datas = []
try:
    from PyInstaller.utils.hooks import collect_data_files as collect_transformers_data
    transformers_datas += collect_transformers_data('transformers')
except:
    pass

# 收集 sentence-transformers 数据和子模块
sentence_transformers_datas = []
sentence_transformers_imports = []
try:
    from PyInstaller.utils.hooks import collect_data_files as collect_st_data
    from PyInstaller.utils.hooks import collect_submodules as collect_st_submodules
    sentence_transformers_datas += collect_st_data('sentence_transformers')
    sentence_transformers_imports = collect_st_submodules('sentence_transformers')
    print(f"[DEBUG] Collected {len(sentence_transformers_imports)} sentence_transformers submodules")
except Exception as e:
    print(f"[WARNING] Failed to collect sentence_transformers: {e}")

# 显式添加 sentence_transformers 包的所有 Python 文件
try:
    import sentence_transformers
    st_package_path = os.path.dirname(sentence_transformers.__file__)
    sentence_transformers_datas.append((st_package_path, 'sentence_transformers'))
    print(f"[DEBUG] Adding sentence_transformers package from: {st_package_path}")
except ImportError:
    print("[WARNING] sentence_transformers not installed")

# 显式添加 huggingface_hub 包
try:
    import huggingface_hub
    hf_package_path = os.path.dirname(huggingface_hub.__file__)
    sentence_transformers_datas.append((hf_package_path, 'huggingface_hub'))
    print(f"[DEBUG] Adding huggingface_hub package from: {hf_package_path}")
except ImportError:
    print("[WARNING] huggingface_hub not installed")

# 显式添加 safetensors 包
try:
    import safetensors
    sf_package_path = os.path.dirname(safetensors.__file__)
    sentence_transformers_datas.append((sf_package_path, 'safetensors'))
    print(f"[DEBUG] Adding safetensors package from: {sf_package_path}")
except ImportError:
    print("[WARNING] safetensors not installed")

# 收集其他必要的数据文件
datas = [
    ('ui', 'ui'),
    ('data_parser', 'data_parser'),
    ('directory_scanner', 'directory_scanner'),
    ('semantic_representation', 'semantic_representation'),
    ('semantic_query', 'semantic_query'),
    ('semantic_classification', 'semantic_classification'),
    ('semantic_clustering', 'semantic_clustering'),
    ('database', 'database'),
    ('models', 'models'),
    ('config.json', '.'),
    ('logger.py', '.'),
    ('performance_monitor.py', '.'),
]

# 合并所有数据
datas.extend(torch_datas)
datas.extend(transformers_datas)
datas.extend(sentence_transformers_datas)

# 隐式导入模块
hiddenimports = [
    # 标准库（PyInstaller 5.x 需要显式添加）
    'ipaddress',
    'urllib',
    'urllib.parse',
    'urllib.request',
    'email',
    'email.utils',
    'email.message',
    'http',
    'http.client',
    'html',
    'html.parser',
    'xml',
    'xml.etree',
    'xml.etree.ElementTree',
    'collections',
    'collections.abc',
    'functools',
    'itertools',
    'operator',
    'typing',
    'types',
    'weakref',
    'copy',
    're',
    'string',
    'io',
    'struct',
    'codecs',
    'unicodedata',

    # PyTorch
    'torch',
    'torch.nn',
    'torch.optim',
    'torch.nn.functional',
    'torch.utils',
    'torch.utils.data',
    'torch._C',
    'torch._dynamo',

    # Transformers
    'transformers',
    'transformers.models',
    'transformers.models.bert',
    'transformers.models.bert.modeling_bert',
    'transformers.models.bert.tokenization_bert',
    'transformers.tokenization_utils',
    'transformers.modeling_utils',
    'transformers.configuration_utils',
    'transformers.AutoTokenizer',
    'transformers.AutoConfig',
    'transformers.AutoModel',

    # Sentence Transformers - 核心模块
    'sentence_transformers',
    'sentence_transformers.SentenceTransformer',
    'sentence_transformers.models',
    'sentence_transformers.models.Transformer',
    'sentence_transformers.models.Pooling',
    'sentence_transformers.models.Normalize',
    'sentence_transformers.util',
    'sentence_transformers.losses',

    # PyQt5
    'PyQt5',
    'PyQt5.QtCore',
    'PyQt5.QtGui',
    'PyQt5.QtWidgets',
    'PyQt5.sip',

    # 其他依赖
    'numpy',
    'pandas',
    'sklearn',
    'sklearn.cluster',
    'sklearn.metrics',
    'sklearn.metrics.pairwise',
    'sqlite3',
    'json',
    'logging',
    'hashlib',
    'threading',
    'queue',
    'multiprocessing',
    'concurrent.futures',
    'huggingface_hub',
    'huggingface_hub.file_download',
    'huggingface_hub.snapshot_download',
    'huggingface_hub.hf_api',
    'safetensors',
    'safetensors.torch',

    # 本地模块
    'ui',
    'ui.main_window',
    'ui.file_list_widget',
    'ui.detail_panel',
    'ui.progress_dialog',
    'ui.search_dialog',
    'ui.thread_workers',
    'data_parser',
    'data_parser.file_parser',
    'data_parser.code_parser',
    'data_parser.doc_parser',
    'data_parser.image_parser',
    'directory_scanner',
    'directory_scanner.scanner',
    'semantic_representation',
    'semantic_representation.code_processor',
    'semantic_representation.doc_processor',
    'semantic_representation.image_processor',
    'semantic_representation.embedding_manager',
    'semantic_query',
    'semantic_query.query_engine',
    'semantic_classification',
    'semantic_classification.classifier',
    'semantic_clustering',
    'semantic_clustering.semantic_clustering',
    'database',
    'database.db_manager',
    'models',
    'models.embedding_models',
]

# 添加动态收集的 sentence_transformers 子模块
hiddenimports.extend(sentence_transformers_imports)

# 添加 Visual C++ 运行时 DLL（PyTorch 依赖）
import os
conda_env = os.path.dirname(os.path.dirname(sys.executable))
vc_dlls = [
    # VC++ 运行时 - 全部包含
    ('Library/bin/concrt140.dll', '.'),
    ('Library/bin/msvcp140.dll', '.'),
    ('Library/bin/msvcp140_1.dll', '.'),
    ('Library/bin/msvcp140_2.dll', '.'),
    ('Library/bin/msvcp140_atomic_wait.dll', '.'),
    ('Library/bin/msvcp140_codecvt_ids.dll', '.'),
    ('Library/bin/vcruntime140.dll', '.'),
    ('Library/bin/vcruntime140_1.dll', '.'),
    ('Library/bin/vcruntime140_threads.dll', '.'),
]

binaries = []
for dll_path, dest in vc_dlls:
    full_path = os.path.join(conda_env, dll_path)
    if os.path.exists(full_path):
        binaries.append((full_path, dest))
        print(f"[DEBUG] Adding VC++ DLL: {dll_path}")

a = Analysis(
    ['ui/launcher.py'],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=['hook_torch_dll.py'],  # PyTorch DLL 加载修复
    excludes=[
        'tkinter',
        'matplotlib',
        'IPython',
        'jupyter',
        'notebook',
        'pytest',
        'test',
        'tests',
        'testing',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

# 排除不需要的文件
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='文件分析管理器',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,  # 禁用控制台窗口
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
    upx=False,  # 禁用UPX压缩
    upx_exclude=[],
    name='文件分析管理器',
)