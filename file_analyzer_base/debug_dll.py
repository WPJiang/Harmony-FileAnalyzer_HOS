"""
DLL 诊断工具 - 检查 c10.dll 依赖
"""
import os
import sys
import ctypes
from ctypes import wintypes

# 获取 Windows 错误消息
def get_last_error_message():
    error_code = ctypes.get_last_error()
    if error_code == 0:
        return "No error"

    # 使用 FormatMessageW 获取错误消息
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

    buffer = ctypes.create_unicode_buffer(512)
    format_message = kernel32.FormatMessageW
    format_message.argtypes = [
        wintypes.DWORD,  # dwFlags
        wintypes.LPCVOID,  # lpSource
        wintypes.DWORD,  # dwMessageId
        wintypes.DWORD,  # dwLanguageId
        wintypes.LPWSTR,  # lpBuffer
        wintypes.DWORD,  # nSize
        wintypes.LPVOID   # Arguments
    ]
    format_message.restype = wintypes.DWORD

    result = format_message(
        0x1000,  # FORMAT_MESSAGE_FROM_SYSTEM
        None,
        error_code,
        0,  # LANG_NEUTRAL
        buffer,
        512,
        None
    )

    if result:
        return buffer.value.strip()
    return f"Unknown error: {error_code}"

# 设置路径
base_path = r"D:\jiangweipeng\trae_code\file_analyzer\dist\文件分析管理器"
internal_path = os.path.join(base_path, '_internal')
torch_lib_path = os.path.join(internal_path, 'torch', 'lib')

print("=" * 70)
print("DLL 诊断工具")
print("=" * 70)
print(f"torch_lib_path: {torch_lib_path}")
print(f"存在: {os.path.exists(torch_lib_path)}")
print()

# 设置 DLL 搜索路径
os.environ['PATH'] = torch_lib_path + os.pathsep + internal_path + os.pathsep + os.environ.get('PATH', '')
os.environ['CUDA_VISIBLE_DEVICES'] = ''
os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'

if hasattr(os, 'add_dll_directory'):
    os.add_dll_directory(torch_lib_path)
    os.add_dll_directory(internal_path)

# 使用 SetDllDirectory
try:
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.SetDllDirectoryW.argtypes = [wintypes.LPCWSTR]
    kernel32.SetDllDirectoryW.restype = wintypes.BOOL
    result = kernel32.SetDllDirectoryW(internal_path)
    print(f"SetDllDirectory({internal_path}): {result}")
except Exception as e:
    print(f"SetDllDirectory failed: {e}")

print()
print("=" * 70)
print("逐步加载 DLL")
print("=" * 70)

dlls = [
    ('libiompstubs5md.dll', torch_lib_path),
    ('libiomp5md.dll', torch_lib_path),
    ('torch_global_deps.dll', torch_lib_path),
    ('shm.dll', torch_lib_path),
    ('uv.dll', torch_lib_path),
    ('c10.dll', torch_lib_path),
    ('torch_cpu.dll', torch_lib_path),
    ('torch.dll', torch_lib_path),
]

loaded_dlls = {}

for dll_name, dll_dir in dlls:
    dll_path = os.path.join(dll_dir, dll_name)
    print(f"\n加载 {dll_name}...")
    print(f"  路径: {dll_path}")
    print(f"  存在: {os.path.exists(dll_path)}")

    if not os.path.exists(dll_path):
        print(f"  跳过 (文件不存在)")
        continue

    try:
        # 尝试使用 LOAD_WITH_ALTERED_SEARCH_PATH
        handle = ctypes.WinDLL(dll_path, mode=0x8)  # LOAD_WITH_ALTERED_SEARCH_PATH
        loaded_dlls[dll_name] = handle
        print(f"  成功! Handle: {handle}")
    except Exception as e:
        error_msg = get_last_error_message()
        print(f"  失败: {type(e).__name__}: {e}")
        print(f"  Windows 错误: {error_msg}")

        # 尝试使用 cdll
        try:
            handle = ctypes.CDLL(dll_path)
            loaded_dlls[dll_name] = handle
            print(f"  使用 CDLL 成功! Handle: {handle}")
        except Exception as e2:
            print(f"  CDLL 也失败: {e2}")

print()
print("=" * 70)
print("尝试导入 torch")
print("=" * 70)

try:
    import torch
    print(f"成功! torch version: {torch.__version__}")
except Exception as e:
    print(f"失败: {type(e).__name__}: {e}")
    import traceback
    traceback.print_exc()

print()
input("按回车键退出...")