"""
PyInstaller runtime hook for PyTorch
解决打包后 torch DLL 加载问题 - 特别是 OpenMP 库冲突
"""
import os
import sys

# 在程序启动时设置 torch DLL 路径
if sys.platform == 'win32':
    # 获取打包后的路径
    if getattr(sys, 'frozen', False):
        base_path = os.path.dirname(sys.executable)
        internal_path = os.path.join(base_path, '_internal')
        torch_lib_path = os.path.join(internal_path, 'torch', 'lib')
        sklearn_libs_path = os.path.join(internal_path, 'sklearn', '.libs')

        # 禁用 CUDA
        os.environ['CUDA_VISIBLE_DEVICES'] = ''
        os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'

        # 关键：将 torch/lib 放在最前面，确保 Intel OpenMP 优先加载
        path_parts = []
        if os.path.exists(torch_lib_path):
            path_parts.append(torch_lib_path)
        path_parts.append(internal_path)
        # sklearn 的 vcomp140.dll 放在后面，避免与 Intel OpenMP 冲突
        if os.path.exists(sklearn_libs_path):
            path_parts.append(sklearn_libs_path)

        current_path = os.environ.get('PATH', '')
        os.environ['PATH'] = os.pathsep.join(path_parts) + os.pathsep + current_path

        # Python 3.8+ 添加 DLL 目录
        if hasattr(os, 'add_dll_directory'):
            try:
                # 先添加 torch lib（最重要）
                if os.path.exists(torch_lib_path):
                    os.add_dll_directory(torch_lib_path)
                os.add_dll_directory(internal_path)
                # sklearn lib 后添加
                if os.path.exists(sklearn_libs_path):
                    os.add_dll_directory(sklearn_libs_path)
            except Exception as e:
                print(f"[Runtime Hook] add_dll_directory warning: {e}", flush=True)

        # 预加载 Intel OpenMP 库（必须在其他 DLL 之前）
        if os.path.exists(torch_lib_path):
            try:
                import ctypes
                libiomp_path = os.path.join(torch_lib_path, 'libiomp5md.dll')
                if os.path.exists(libiomp_path):
                    ctypes.WinDLL(libiomp_path)
                    print(f"[Runtime Hook] Preloaded libiomp5md.dll", flush=True)
            except Exception as e:
                print(f"[Runtime Hook] Failed to preload libiomp5md.dll: {e}", flush=True)