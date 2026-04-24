"""
PyInstaller runtime hook for PyTorch
修复 PyTorch DLL 加载问题
"""
import os
import sys

# 设置环境变量以确保 DLL 正确加载
if sys.platform == 'win32':
    # 添加 _internal 目录到 DLL 搜索路径
    if getattr(sys, 'frozen', False):
        base_path = os.path.dirname(sys.executable)
        internal_path = os.path.join(base_path, '_internal')

        # 添加到 PATH
        os.environ['PATH'] = internal_path + os.pathsep + os.environ.get('PATH', '')

        # 添加 torch lib 路径
        torch_lib_path = os.path.join(internal_path, 'torch', 'lib')
        if os.path.exists(torch_lib_path):
            os.environ['PATH'] = torch_lib_path + os.pathsep + os.environ.get('PATH', '')

        # 尝试使用 os.add_dll_directory (Python 3.8+)
        if hasattr(os, 'add_dll_directory'):
            try:
                os.add_dll_directory(internal_path)
                if os.path.exists(torch_lib_path):
                    os.add_dll_directory(torch_lib_path)
            except Exception as e:
                print(f"[Runtime Hook] add_dll_directory failed: {e}")