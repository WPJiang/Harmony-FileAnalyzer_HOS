"""
UI启动入口
提供命令行启动和快捷方式创建功能
"""

import os
import sys

# ===== 关键：在所有其他导入之前设置 DLL 搜索路径 =====
if sys.platform == 'win32' and getattr(sys, 'frozen', False):
    base_path = os.path.dirname(sys.executable)
    internal_path = os.path.join(base_path, '_internal')

    # 禁用 CUDA，避免加载不存在的 CUDA DLL
    os.environ['CUDA_VISIBLE_DEVICES'] = ''
    os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'

    # 关键：先设置 torch lib 路径，确保 Intel OpenMP 优先加载
    torch_lib_path = os.path.join(internal_path, 'torch', 'lib')
    sklearn_lib_path = os.path.join(internal_path, 'sklearn', '.libs')

    # 构建新的 PATH，torch/lib 放在最前面
    new_path_parts = []
    if os.path.exists(torch_lib_path):
        new_path_parts.append(torch_lib_path)
    new_path_parts.append(internal_path)
    if os.path.exists(sklearn_lib_path):
        new_path_parts.append(sklearn_lib_path)

    current_path = os.environ.get('PATH', '')
    os.environ['PATH'] = os.pathsep.join(new_path_parts) + os.pathsep + current_path

    # Python 3.8+ 使用 os.add_dll_directory
    if hasattr(os, 'add_dll_directory'):
        try:
            # 先添加 torch lib
            if os.path.exists(torch_lib_path):
                os.add_dll_directory(torch_lib_path)
            os.add_dll_directory(internal_path)
            if os.path.exists(sklearn_lib_path):
                os.add_dll_directory(sklearn_lib_path)
        except Exception as e:
            print(f"[Launcher] add_dll_directory warning: {e}", flush=True)

    # 使用 ctypes 和 Windows API 设置 DLL 加载
    try:
        import ctypes
        from ctypes import wintypes

        # 加载 kernel32.dll
        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

        # 设置 DLL 搜索目录（使用 SetDllDirectoryW）
        if hasattr(kernel32, 'SetDllDirectoryW'):
            kernel32.SetDllDirectoryW(internal_path)
            print(f"[Launcher] SetDllDirectory: {internal_path}", flush=True)

        # 预加载关键 DLL
        # 预加载关键 DLL - 必须按正确顺序加载以避免 OpenMP 冲突
        dlls_to_preload = [
            # 1. 首先加载 Intel OpenMP（必须在所有其他 DLL 之前）
            os.path.join(torch_lib_path, 'libiompstubs5md.dll'),
            os.path.join(torch_lib_path, 'libiomp5md.dll'),
            # 2. VC++ 运行时
            os.path.join(internal_path, 'vcruntime140.dll'),
            os.path.join(internal_path, 'vcruntime140_1.dll'),
            os.path.join(internal_path, 'msvcp140.dll'),
            # 3. torch_global_deps（包含额外依赖）
            os.path.join(torch_lib_path, 'torch_global_deps.dll'),
            # 4. shm 和 uv
            os.path.join(torch_lib_path, 'shm.dll'),
            os.path.join(torch_lib_path, 'uv.dll'),
            # 5. PyTorch 核心（最后加载）
            os.path.join(torch_lib_path, 'c10.dll'),
            os.path.join(torch_lib_path, 'torch_cpu.dll'),
            os.path.join(torch_lib_path, 'torch.dll'),
        ]

        for dll_path in dlls_to_preload:
            if os.path.exists(dll_path):
                try:
                    # 使用 LOAD_WITH_ALTERED_SEARCH_PATH 标志
                    ctypes.WinDLL(dll_path, mode=ctypes.RTLD_GLOBAL)
                    print(f"[Launcher] Preloaded: {os.path.basename(dll_path)}", flush=True)
                except Exception as e:
                    print(f"[Launcher] Failed to preload {os.path.basename(dll_path)}: {e}", flush=True)
    except Exception as e:
        print(f"[Launcher] DLL preload warning: {e}", flush=True)
# ===== DLL 路径设置结束 =====

import argparse
import traceback


def setup_error_logging():
    """设置错误日志到文件"""
    if getattr(sys, 'frozen', False):
        log_dir = os.path.dirname(sys.executable)
    else:
        log_dir = os.path.dirname(os.path.abspath(__file__))
    
    log_path = os.path.join(log_dir, 'file_analyzer_error.log')
    
    try:
        if getattr(sys, 'frozen', False):
            log_file = open(log_path, 'a', encoding='utf-8')
            sys.stderr = log_file
            sys.stdout = log_file
            print(f"=== 程序启动日志 ===", flush=True)
            print(f"工作目录: {os.getcwd()}", flush=True)
            print(f"sys.path: {sys.path}", flush=True)
            print(f"sys.executable: {sys.executable}", flush=True)
            print(f"sys.frozen: {getattr(sys, 'frozen', False)}", flush=True)
            print("", flush=True)
    except Exception as e:
        print(f"无法创建日志文件: {e}", flush=True)
    
    return log_path


def check_all_imports():
    """检查所有必要的模块导入，并打印详细日志"""
    print("\n" + "="*60, flush=True)
    print("[Import Check] 开始检查所有模块导入...", flush=True)
    print("="*60, flush=True)

    # 打印 torch 包路径信息（用于调试）
    print("\n[DEBUG] 检查 torch 包路径...", flush=True)
    try:
        import importlib.util
        spec = importlib.util.find_spec('torch')
        if spec:
            print(f"  torch spec.origin: {spec.origin}", flush=True)
            print(f"  torch spec.submodule_search_locations: {spec.submodule_search_locations}", flush=True)
    except Exception as e:
        print(f"  无法获取 torch spec: {e}", flush=True)

    # 定义需要检查的模块列表
    modules_to_check = [
        # 标准库
        ('os', '标准库'),
        ('sys', '标准库'),
        ('json', '标准库'),
        ('sqlite3', '标准库'),
        ('logging', '标准库'),
        ('threading', '标准库'),
        ('multiprocessing', '标准库'),
        ('concurrent.futures', '标准库'),
        ('hashlib', '标准库'),
        ('queue', '标准库'),

        # 第三方核心库
        ('numpy', '第三方库'),
        ('pandas', '第三方库'),

        # PyQt5
        ('PyQt5', 'UI框架'),
        ('PyQt5.QtCore', 'UI框架'),
        ('PyQt5.QtGui', 'UI框架'),
        ('PyQt5.QtWidgets', 'UI框架'),

        # PyTorch
        ('torch', '深度学习框架'),

        # Transformers
        ('transformers', 'NLP模型库'),

        # Sentence Transformers
        ('sentence_transformers', '句子嵌入库'),
        ('sentence_transformers.SentenceTransformer', '句子嵌入模型'),

        # HuggingFace
        ('huggingface_hub', 'HuggingFace Hub'),

        # Safetensors
        ('safetensors', '模型序列化'),

        # Sklearn
        ('sklearn', '机器学习库'),
        ('sklearn.cluster', '聚类模块'),
        ('sklearn.metrics', '评估指标'),

        # 本地模块
        ('data_parser', '本地模块'),
        ('data_parser.file_parser', '本地模块'),
        ('data_parser.code_parser', '本地模块'),
        ('data_parser.doc_parser', '本地模块'),
        ('data_parser.image_parser', '本地模块'),
        ('directory_scanner', '本地模块'),
        ('directory_scanner.scanner', '本地模块'),
        ('semantic_representation', '本地模块'),
        ('semantic_representation.semantic_representation', '本地模块'),
        ('semantic_query', '本地模块'),
        ('semantic_query.query_engine', '本地模块'),
        ('semantic_classification', '本地模块'),
        ('semantic_classification.semantic_classification', '本地模块'),
        ('semantic_clustering', '本地模块'),
        ('semantic_clustering.semantic_clustering', '本地模块'),
        ('database', '本地模块'),
        ('database.db_manager', '本地模块'),
        ('models', '本地模块'),
        ('models.model_manager', '本地模块'),
        ('logger', '本地模块'),
        ('performance_monitor', '本地模块'),
    ]

    success_count = 0
    failed_count = 0
    failed_modules = []

    for module_name, category in modules_to_check:
        try:
            # 尝试导入模块
            parts = module_name.split('.')
            if len(parts) > 1 and parts[0] in ['data_parser', 'directory_scanner', 'semantic_representation',
                                                'semantic_query', 'semantic_classification', 'semantic_clustering',
                                                'database', 'models', 'logger', 'performance_monitor']:
                # 本地模块使用特殊处理
                module = __import__(module_name)
                for part in parts[1:]:
                    module = getattr(module, part, None)
                    if module is None:
                        raise ImportError(f"Cannot import {module_name}")
            else:
                __import__(module_name)

            # 获取版本信息（如果可用）
            version = ""
            try:
                mod = __import__(module_name)
                if hasattr(mod, '__version__'):
                    version = f" v{mod.__version__}"
            except:
                pass

            print(f"  [OK] {module_name}{version} ({category})", flush=True)
            success_count += 1
        except ImportError as e:
            print(f"  [FAIL] {module_name} ({category}): {e}", flush=True)
            failed_count += 1
            failed_modules.append(module_name)
        except Exception as e:
            print(f"  [ERROR] {module_name} ({category}): {type(e).__name__}: {e}", flush=True)
            failed_count += 1
            failed_modules.append(module_name)

    print("\n" + "-"*60, flush=True)
    print(f"[Import Check] 检查完成: 成功 {success_count}, 失败 {failed_count}", flush=True)

    if failed_modules:
        print(f"[Import Check] 失败的模块: {', '.join(failed_modules)}", flush=True)
    print("="*60 + "\n", flush=True)

    return failed_count == 0


def check_dependencies():
    """检查依赖是否安装"""
    missing = []

    try:
        import PyQt5
    except ImportError:
        missing.append('PyQt5')

    if missing:
        print("缺少以下依赖包:")
        for pkg in missing:
            print(f"  - {pkg}")
        print("\n请安装依赖:")
        print(f"  pip install {' '.join(missing)}")
        return False

    return True


def launch_ui():
    """启动UI界面"""
    try:
        if getattr(sys, 'frozen', False):
            base_path = os.path.dirname(sys.executable)
            internal_path = os.path.join(base_path, '_internal')
            if os.path.exists(internal_path):
                sys.path.insert(0, internal_path)
            sys.path.insert(0, base_path)
            print(f"[Launcher] 打包模式，base_path: {base_path}", flush=True)
            print(f"[Launcher] _internal路径: {internal_path}", flush=True)
        else:
            base_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            sys.path.insert(0, base_path)

        # 检查所有模块导入
        print("[Launcher] 开始检查所有模块导入...", flush=True)
        all_imports_ok = check_all_imports()
        if not all_imports_ok:
            print("[Launcher] 警告: 部分模块导入失败，程序可能无法正常工作", flush=True)

        print("[Launcher] 导入PyQt5...", flush=True)
        from PyQt5.QtWidgets import QApplication
        from PyQt5.QtGui import QFont

        print("[Launcher] 导入MainWindow...", flush=True)
        try:
            from ui.main_window import MainWindow
        except ImportError:
            try:
                from main_window import MainWindow
            except ImportError:
                raise

        print("[Launcher] 创建QApplication...", flush=True)
        app = QApplication(sys.argv)
        app.setApplicationName("文件分析管理器")
        app.setApplicationVersion("1.0.0")
        app.setStyle('Fusion')

        font = QFont("Microsoft YaHei", 9)
        app.setFont(font)

        print("[Launcher] 创建MainWindow...", flush=True)
        window = MainWindow()
        window.show()

        print("[Launcher] 启动事件循环...", flush=True)
        sys.exit(app.exec_())

    except Exception as e:
        error_msg = f"程序启动失败：{str(e)}\n\n{traceback.format_exc()}"
        print(f"[Launcher] ERROR: {error_msg}", flush=True)
        try:
            from PyQt5.QtWidgets import QMessageBox, QApplication
            if not QApplication.instance():
                app = QApplication(sys.argv)
            msg = QMessageBox()
            msg.setIcon(QMessageBox.Critical)
            msg.setWindowTitle("启动错误")
            msg.setText(f"程序启动失败：\n{str(e)}")
            msg.setDetailedText(traceback.format_exc())
            msg.exec_()
        except:
            pass

        sys.exit(1)


def create_shortcut():
    """创建桌面快捷方式（Windows）"""
    if sys.platform != 'win32':
        print("快捷方式创建仅支持Windows系统")
        return False
    
    try:
        import winshell
        from win32com.client import Dispatch
        
        # 获取桌面路径
        desktop = winshell.desktop()
        
        # 快捷方式路径
        shortcut_path = os.path.join(desktop, "文件分析管理器.lnk")
        
        # 目标路径
        target = sys.executable
        script_path = os.path.abspath(__file__)
        
        # 创建快捷方式
        shell = Dispatch('WScript.Shell')
        shortcut = shell.CreateShortCut(shortcut_path)
        shortcut.Targetpath = target
        shortcut.Arguments = f'"{script_path}"'
        shortcut.WorkingDirectory = os.path.dirname(script_path)
        shortcut.IconLocation = target
        shortcut.save()
        
        print(f"快捷方式已创建: {shortcut_path}")
        return True
        
    except ImportError:
        print("缺少依赖包: pywin32, winshell")
        print("请安装: pip install pywin32 winshell")
        return False
    except Exception as e:
        print(f"创建快捷方式失败: {e}")
        return False


def main():
    """主函数"""
    # 打包模式下启用错误日志
    if getattr(sys, 'frozen', False):
        log_path = setup_error_logging()
        print(f"[Launcher] 错误日志路径: {log_path}", flush=True)
        try:
            launch_ui()
        except Exception as e:
            print(f"[Launcher] 启动失败: {e}", flush=True)
            traceback.print_exc()
            sys.exit(1)
        return

    parser = argparse.ArgumentParser(
        description='文件分析管理器 - UI启动工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  python launcher.py              # 启动UI界面
  python launcher.py --shortcut   # 创建桌面快捷方式
  python launcher.py --check      # 检查依赖
        """
    )
    
    parser.add_argument(
        '--shortcut',
        action='store_true',
        help='创建桌面快捷方式'
    )
    
    parser.add_argument(
        '--check',
        action='store_true',
        help='检查依赖安装情况'
    )
    
    args = parser.parse_args()
    
    if args.check:
        if check_dependencies():
            print("✓ 所有依赖已安装")
            sys.exit(0)
        else:
            sys.exit(1)
    
    if args.shortcut:
        create_shortcut()
        sys.exit(0)
    
    # 默认启动UI
    launch_ui()


if __name__ == '__main__':
    main()
