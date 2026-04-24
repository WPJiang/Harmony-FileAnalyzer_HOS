import os
import sys
import json
import gc  # 方案C：添加垃圾回收模块
from typing import Optional, List, Dict, Any
from PyQt5.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
    QSplitter, QStatusBar, QMenuBar, QMenu, QAction,
    QMessageBox, QFileDialog, QApplication, QToolBar,
    QLabel, QPushButton, QComboBox, QSizePolicy
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal, QSize
from PyQt5.QtGui import QIcon, QKeySequence

# 导入日志模块
try:
    from ..logger import processing_logger
except ImportError:
    try:
        from logger import processing_logger
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from logger import processing_logger

# 导入性能监控模块
try:
    from ..performance_monitor import get_performance_monitor
except ImportError:
    try:
        from performance_monitor import get_performance_monitor
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from performance_monitor import get_performance_monitor

# 处理相对导入
try:
    from .preview_panel import PreviewPanel
    from .recommendation_panel import RecommendationPanel
    from .search_panel import SearchPanel
    from .classification_panel import ClassificationPanel
    from ..directory_scanner import DirectoryScanner
except ImportError:
    try:
        from preview_panel import PreviewPanel
        from recommendation_panel import RecommendationPanel
        from search_panel import SearchPanel
        from classification_panel import ClassificationPanel
        from directory_scanner import DirectoryScanner
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from ui.preview_panel import PreviewPanel
        from ui.recommendation_panel import RecommendationPanel
        from ui.search_panel import SearchPanel
        from ui.classification_panel import ClassificationPanel
        from directory_scanner.directory_scanner import DirectoryScanner

# 导入模型管理器（用于内存优化）
try:
    from models.model_manager import aggressive_cleanup
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from models.model_manager import aggressive_cleanup


class AnalyzeWorker(QThread):
    """后台分析工作线程"""
    progress = pyqtSignal(str, int)
    finished = pyqtSignal(dict)
    error = pyqtSignal(str)
    
    def __init__(self, db_manager, classification_method: str = 'similarity'):
        super().__init__()
        self.db_manager = db_manager
        self._is_cancelled = False
        self.classification_method = classification_method
        self.pending_files = []
    
    def set_pending_files(self, files: List[str]):
        self.pending_files = files
    
    def cancel(self):
        self._is_cancelled = True
    
    def _load_config(self) -> dict:
        """加载配置文件 - 支持打包后的环境"""
        if getattr(sys, 'frozen', False):
            # 打包后的环境
            base_dir = os.path.dirname(sys.executable)
            # 首先尝试外部目录
            config_path = os.path.join(base_dir, 'config.json')
            if os.path.exists(config_path):
                try:
                    with open(config_path, 'r', encoding='utf-8') as f:
                        return json.load(f)
                except Exception as e:
                    print(f"[DEBUG] 加载配置文件失败: {e}")
            # 然后尝试_internal目录
            internal_path = os.path.join(base_dir, '_internal', 'config.json')
            if os.path.exists(internal_path):
                try:
                    with open(internal_path, 'r', encoding='utf-8') as f:
                        return json.load(f)
                except Exception as e:
                    print(f"[DEBUG] 加载_internal配置文件失败: {e}")
        else:
            # 开发环境
            base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            config_path = os.path.join(base_dir, 'config.json')
            
            if os.path.exists(config_path):
                try:
                    with open(config_path, 'r', encoding='utf-8') as f:
                        return json.load(f)
                except Exception as e:
                    print(f"[DEBUG] 加载配置文件失败: {e}")
        
        return {}
    
    def run(self):
        print("[DEBUG] AnalyzeWorker.run() 开始执行")
        from database import DatabaseManager, FileStatus

        DataParser = None
        SemanticRepresentation = None
        SemanticClustering = None
        SemanticClassification = None

        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if base_dir not in sys.path:
            sys.path.insert(0, base_dir)
        
        print(f"[DEBUG] base_dir: {base_dir}")
        print(f"[DEBUG] sys.path: {sys.path}")

        try:
            config = self._load_config()
            print(f"[DEBUG] 配置加载成功: {len(config)} 个配置项")
        except Exception as e:
            print(f"[DEBUG] 配置加载失败: {e}")
            import traceback
            traceback.print_exc()
            self.error.emit(f"配置加载失败: {str(e)}")
            return

        # 读取内存清理配置
        low_memory_config = config.get('low_memory_mode', {})
        memory_cleanup_config = low_memory_config.get('periodic_memory_cleanup', {})
        memory_cleanup_enabled = memory_cleanup_config.get('enabled', False)
        memory_cleanup_interval = memory_cleanup_config.get('file_interval', 5)
        if memory_cleanup_enabled:
            print(f"[Memory] 定期内存清理已启用，间隔: {memory_cleanup_interval} 个文件")

        # 初始化性能监控器
        perf_monitor = get_performance_monitor()
        perf_monitor.initialize(config)

        classification_method = config.get('classification', {}).get('method', self.classification_method)
        print(f"[DEBUG] 分类方法: {classification_method}")
        
        import_patterns = [
            ('data_parser', 'DataParser'),
            ('semantic_representation', 'SemanticRepresentation'),
            ('semantic_clustering', 'SemanticClustering'),
            ('semantic_classification', 'SemanticClassification'),
        ]
        
        print("[DEBUG] 开始导入模块...")
        for module_name, class_name in import_patterns:
            print(f"[DEBUG] 尝试导入 {module_name}.{class_name}")
            loaded = False
            try:
                module = __import__(module_name)
                DataParser = getattr(module, 'DataParser') if class_name == 'DataParser' else DataParser
                SemanticRepresentation = getattr(module, 'SemanticRepresentation') if class_name == 'SemanticRepresentation' else SemanticRepresentation
                SemanticClustering = getattr(module, 'SemanticClustering') if class_name == 'SemanticClustering' else SemanticClustering
                SemanticClassification = getattr(module, 'SemanticClassification') if class_name == 'SemanticClassification' else SemanticClassification
                loaded = True
                print(f"[DEBUG] 成功导入 {module_name}.{class_name} (方式1)")
            except ImportError as e:
                print(f"[DEBUG] 方式1导入失败 {module_name}: {e}")
            
            if not loaded:
                try:
                    module = __import__(f'file_analyzer.{module_name}', fromlist=[class_name])
                    DataParser = getattr(module, 'DataParser') if class_name == 'DataParser' else DataParser
                    SemanticRepresentation = getattr(module, 'SemanticRepresentation') if class_name == 'SemanticRepresentation' else SemanticRepresentation
                    SemanticClustering = getattr(module, 'SemanticClustering') if class_name == 'SemanticClustering' else SemanticClustering
                    SemanticClassification = getattr(module, 'SemanticClassification') if class_name == 'SemanticClassification' else SemanticClassification
                    loaded = True
                    print(f"[DEBUG] 成功导入 {module_name}.{class_name} (方式2)")
                except ImportError as e:
                    print(f"[DEBUG] 方式2导入失败 {module_name}: {e}")
            
            if not loaded:
                try:
                    import importlib.util
                    module_path = os.path.join(base_dir, module_name, '__init__.py')
                    print(f"[DEBUG] 尝试方式3，模块路径: {module_path}")
                    if os.path.exists(module_path):
                        spec = importlib.util.spec_from_file_location(module_name, module_path)
                        module = importlib.util.module_from_spec(spec)
                        sys.modules[module_name] = module
                        spec.loader.exec_module(module)
                        DataParser = getattr(module, 'DataParser') if class_name == 'DataParser' else DataParser
                        SemanticRepresentation = getattr(module, 'SemanticRepresentation') if class_name == 'SemanticRepresentation' else SemanticRepresentation
                        SemanticClustering = getattr(module, 'SemanticClustering') if class_name == 'SemanticClustering' else SemanticClustering
                        SemanticClassification = getattr(module, 'SemanticClassification') if class_name == 'SemanticClassification' else SemanticClassification
                        loaded = True
                        print(f"[DEBUG] 成功导入 {module_name}.{class_name} (方式3)")
                    else:
                        print(f"[DEBUG] 方式3失败，文件不存在: {module_path}")
                except Exception as e:
                    print(f"[DEBUG] 方式3导入失败 {module_name}: {e}")
                    self.error.emit(f"无法加载模块 {module_name}: {str(e)}")
                    return
            
            if not loaded and class_name in ['DataParser', 'SemanticRepresentation']:
                print(f"[DEBUG] 关键模块 {module_name} 导入失败")
                self.error.emit(f"无法加载模块 {module_name}")
                return
        
        print(f"[DEBUG] 模块导入完成: DataParser={DataParser is not None}, SemanticRepresentation={SemanticRepresentation is not None}")
        
        if DataParser is None or SemanticRepresentation is None:
            self.error.emit("无法加载必要的分析模块")
            return
        
        if classification_method == 'clustering' and SemanticClustering is None:
            self.error.emit("无法加载语义聚类模块")
            return
        
        if classification_method == 'similarity' and SemanticClassification is None:
            self.error.emit("无法加载语义分类模块")
            return
        
        try:
            self.progress.emit("初始化分析引擎...", 0)

            # 使用已加载的配置
            # perf_monitor 已在外部初始化

            # 初始化各模块（带性能追踪）
            with perf_monitor.track_module("DataParser.init"):
                data_parser = DataParser(config)
            with perf_monitor.track_module("SemanticRepresentation.init"):
                semantic_rep = SemanticRepresentation(config)

            classifier = None
            if classification_method == 'clustering':
                with perf_monitor.track_module("SemanticClustering.init"):
                    classifier = SemanticClustering()
                self.progress.emit("初始化聚类模型...", 5)
            else:
                with perf_monitor.track_module("SemanticClassification.init"):
                    classifier = SemanticClassification()
                self.progress.emit("初始化分类模型...", 5)

            with perf_monitor.track_module("Classifier.initialize"):
                classifier.initialize()
            
            results = {}
            
            # 获取待分析的文件列表
            files_to_analyze = self.pending_files if self.pending_files else []
            if not files_to_analyze and self.db_manager:
                # 从数据库获取待分析的文件
                pending_records = self.db_manager.get_files_by_status(FileStatus.PENDING)
                files_to_analyze = [r.file_path for r in pending_records]
            
            total = len(files_to_analyze)
            processed = 0
            
            print(f"[DEBUG] 开始分析 {total} 个文件，使用{classification_method}方法")
            
            for file_path in files_to_analyze:
                if self._is_cancelled:
                    self.error.emit("分析已取消")
                    perf_monitor.stop()
                    return

                try:
                    # 开始文件处理追踪
                    perf_monitor.start_file_processing(file_path)

                    self.progress.emit(f"解析: {os.path.basename(file_path)}", int(10 + 80 * processed / total))

                    # 获取文件ID
                    file_id = None
                    if self.db_manager:
                        file_record = self.db_manager.get_file_by_path(file_path)
                        if file_record:
                            file_id = file_record.id

                    # 解析文件并写入数据块表（带性能追踪）
                    with perf_monitor.track_module("DataParser.parse_file"):
                        blocks = data_parser.parse_file(file_path, self.db_manager, file_id)
                    print(f"[DEBUG] 文件 {os.path.basename(file_path)} 解析出 {len(blocks) if blocks else 0} 个块")
                    if not blocks:
                        perf_monitor.end_file_processing(success=True, error_message="无数据块")
                        processed += 1
                        continue

                    self.progress.emit(f"分析: {os.path.basename(file_path)}", int(10 + 80 * processed / total))

                    # 语义表征并写入语义块表
                    semantic_blocks = []

                    # 检查是否为轻量模式下的多页文档（首页数据块需要整合）
                    is_light_mode_first_page = False
                    if blocks and len(blocks) > 0:
                        # 检查第一个数据块的元数据
                        first_block = blocks[0]
                        if hasattr(first_block, 'metadata') and first_block.metadata:
                            if first_block.metadata.get('parsing_mode') == 'light_first_page':
                                is_light_mode_first_page = True

                    if is_light_mode_first_page and len(blocks) > 1:
                        # 轻量模式下的多页文档首页：整合所有首页数据块为一个语义块
                        print(f"[DEBUG] 轻量模式首页整合：{len(blocks)} 个数据块 -> 1 个语义块")
                        try:
                            # 获取最大长度配置
                            max_length = config.get('parsing', {}).get('light_mode_max_length', 256)

                            # 使用 represent_first_page_blocks 整合所有首页数据块（带性能追踪）
                            with perf_monitor.track_module("SemanticRepresentation.represent_first_page"):
                                sb = semantic_rep.represent_first_page_blocks(
                                    blocks=blocks,
                                    db_manager=self.db_manager,
                                    file_id=file_id,
                                    max_length=max_length
                                )
                            semantic_blocks.append(sb)
                            print(f"[DEBUG] 首页整合完成，生成 1 个语义块")
                        except Exception as e:
                            print(f"[DEBUG] 首页整合失败: {e}")
                            import traceback
                            traceback.print_exc()
                    else:
                        # 深度模式或其他类型：逐个处理数据块
                        # 优化：预先获取所有数据块，避免重复数据库查询
                        data_blocks_map = {}
                        if self.db_manager and file_id:
                            data_blocks = self.db_manager.get_data_blocks_by_file(file_id)
                            data_blocks_map = {db.block_id: db.id for db in data_blocks}

                        for block in blocks:
                            try:
                                # 获取数据块ID（从预加载的map中查找）
                                data_block_id = data_blocks_map.get(block.block_id)

                                # 语义表征（带性能追踪）
                                with perf_monitor.track_module("SemanticRepresentation.represent"):
                                    sb = semantic_rep.represent(block, self.db_manager, data_block_id, file_id)
                                semantic_blocks.append(sb)
                            except Exception as e:
                                print(f"[DEBUG] 语义表征失败: {e}")
                                pass

                    print(f"[DEBUG] 语义表征完成，{len(semantic_blocks)} 个语义块")

                    if semantic_blocks:
                        # 分类并写入分类结果表（带性能追踪）
                        with perf_monitor.track_module("Classifier.classify_batch"):
                            if classification_method == 'clustering':
                                class_results = classifier.cluster_batch(semantic_blocks)
                            else:
                                class_results = classifier.classify_batch(semantic_blocks, self.db_manager, file_id)
                        print(f"[DEBUG] 分类完成，{len(class_results)} 个结果")

                        file_categories = {}
                        total_confidence = 0.0

                        for block, result in zip(semantic_blocks, class_results):
                            if classification_method == 'clustering':
                                category = result.cluster_name
                            else:
                                category = result.category_name
                            conf = result.confidence
                            total_confidence += conf

                            if category not in file_categories:
                                file_categories[category] = {
                                    'confidence_sum': 0.0,
                                    'block_count': 0,
                                    'keywords': []
                                }

                            file_categories[category]['confidence_sum'] += conf
                            file_categories[category]['block_count'] += 1
                            if block.keywords:
                                file_categories[category]['keywords'].extend(block.keywords[:3])
                        
                        file_category_list = []
                        for cat, data in file_categories.items():
                            normalized_conf = data['confidence_sum'] / total_confidence if total_confidence > 0 else 0
                            file_category_list.append({
                                'category': cat,
                                'confidence': normalized_conf,
                                'block_count': data['block_count'],
                                'keywords': list(set(data['keywords']))[:5]
                            })
                        
                        file_category_list.sort(key=lambda x: x['confidence'], reverse=True)
                        
                        primary_category = file_category_list[0]['category'] if file_category_list else '未分类'
                        
                        # 更新文件表的语义类别和分析状态
                        if self.db_manager and file_id:
                            self.db_manager.update_file_semantic_categories(file_id, file_category_list)
                            self.db_manager.update_file_status(file_id, FileStatus.PRELIMINARY)
                        
                        if primary_category not in results:
                            results[primary_category] = []

                        results[primary_category].append({
                            'path': file_path,
                            'categories': file_category_list,
                            'primary_category': primary_category,
                            'primary_confidence': file_category_list[0]['confidence'] if file_category_list else 0,
                            'total_blocks': len(semantic_blocks)
                        })

                        # 结束文件处理追踪（成功）
                        perf_monitor.end_file_processing(success=True)

                        # 方案C：显式垃圾回收，释放内存
                        gc.collect()
                except Exception as e:
                    print(f"[DEBUG] 处理文件失败 {file_path}: {e}")
                    # 结束文件处理追踪（失败）
                    perf_monitor.end_file_processing(success=False, error_message=str(e))

                    # 方案C：即使失败也执行垃圾回收
                    gc.collect()

                processed += 1

                # 定期内存清理（根据配置）
                if memory_cleanup_enabled and processed % memory_cleanup_interval == 0:
                    try:
                        aggressive_cleanup()
                        print(f"[Memory] 已处理 {processed} 个文件，执行积极内存清理")
                    except Exception as e:
                        print(f"[Memory] 内存清理失败: {e}")

            # 所有文件处理完成后执行最终垃圾回收
            gc.collect()
            if memory_cleanup_enabled:
                aggressive_cleanup()  # 最终积极清理
            print("[Memory] 最终垃圾回收完成")

            # 生成性能报告
            perf_report_path = perf_monitor.generate_report()
            if perf_report_path:
                print(f"[PerformanceMonitor] 性能报告已生成: {perf_report_path}")

            print(f"[DEBUG] 分析完成，最终结果: {len(results)} 个分类")
            self.progress.emit("分析完成", 100)
            self.finished.emit(results)
            
        except Exception as e:
            import traceback
            error_detail = traceback.format_exc()
            print(f"[DEBUG] 分析失败: {e}\n{error_detail}")
            perf_monitor.stop()
            self.error.emit(f"分析失败: {str(e)}")


class ScanWorker(QThread):
    """后台扫描工作线程"""
    scan_finished = pyqtSignal(dict)
    scan_progress = pyqtSignal(str, int)
    
    def __init__(self, scanner: DirectoryScanner, scan_type: str = 'default'):
        super().__init__()
        self.scanner = scanner
        self.scan_type = scan_type
        self.directory = None
    
    def set_directory(self, directory: str):
        self.directory = directory
    
    def run(self):
        try:
            if self.scan_type == 'default':
                self.scan_progress.emit("正在扫描默认目录...", 0)
                # 扫描默认目录并收集目录结构
                results = self.scan_default_directories_with_structure()
                self.scan_finished.emit(results)
            elif self.scan_type == 'directory' and self.directory:
                self.scan_progress.emit(f"正在扫描: {self.directory}", 0)
                # 递归扫描目录，同时收集目录结构
                files, dir_structure = self.scan_directory_with_structure(self.directory)
                results = {
                    'default_directories': {os.path.basename(self.directory): files},
                    'total_files': len(files),
                    'scanned_directories': [self.directory],
                    'directory_structure': dir_structure,
                    'root_directory': self.directory
                }
                self.scan_finished.emit(results)
        except Exception as e:
            self.scan_finished.emit({'error': str(e)})
    
    def scan_default_directories_with_structure(self) -> Dict[str, Any]:
        """扫描默认目录并收集目录结构
        
        Returns:
            包含目录结构的结果字典
        """
        directories = self.scanner.get_default_scan_directories()
        all_files = []
        default_dirs = {}
        
        # 创建虚拟根目录结构
        root_structure = {
            'name': '默认目录',
            'path': '默认目录',
            'dirs': {},
            'files': []
        }
        
        for directory in directories:
            dir_name = os.path.basename(directory) or directory
            self.scan_progress.emit(f"正在扫描: {dir_name}", 0)
            
            # 扫描目录并收集结构
            files, dir_structure = self.scan_directory_with_structure(directory)
            
            if files:
                all_files.extend(files)
                default_dirs[dir_name] = files
                
                # 将每个默认目录作为虚拟根的子目录
                root_structure['dirs'][dir_name] = dir_structure
        
        return {
            'default_directories': default_dirs,
            'total_files': len(all_files),
            'scanned_directories': directories,
            'directory_structure': root_structure,
            'root_directory': '默认目录'
        }
    
    def scan_directory_with_structure(self, directory: str) -> tuple:
        """扫描目录并收集目录结构
        
        Returns:
            tuple: (文件列表, 目录结构字典)
        """
        files = []
        dir_structure = {'name': os.path.basename(directory), 'path': directory, 'dirs': {}, 'files': []}
        
        for root, dirs, filenames in os.walk(directory):
            # 计算相对路径
            rel_path = os.path.relpath(root, directory)
            
            # 获取当前目录在结构中的位置
            current = dir_structure
            if rel_path != '.':
                parts = rel_path.split(os.sep)
                for part in parts:
                    if part not in current['dirs']:
                        current['dirs'][part] = {
                            'name': part,
                            'path': os.path.join(current['path'], part),
                            'dirs': {},
                            'files': []
                        }
                    current = current['dirs'][part]
            
            # 添加文件
            for filename in filenames:
                file_path = os.path.join(root, filename)
                files.append(file_path)
                current['files'].append(file_path)
        
        return files, dir_structure


class MainWindow(QMainWindow):
    """主窗口类"""
    
    def _get_config_path(self):
        """获取配置文件路径 - 支持打包后的环境"""
        if getattr(sys, 'frozen', False):
            # 打包后的环境
            base_dir = os.path.dirname(sys.executable)
            # 首先尝试外部目录
            config_path = os.path.join(base_dir, 'config.json')
            if os.path.exists(config_path):
                return config_path
            # 然后尝试_internal目录
            internal_path = os.path.join(base_dir, '_internal', 'config.json')
            if os.path.exists(internal_path):
                return internal_path
            return config_path  # 返回默认路径
        else:
            # 开发环境
            return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'config.json')
    
    def __init__(self):
        super().__init__()
        
        self.scanner = DirectoryScanner()
        self.current_directory = None
        self.current_files = []
        self.scan_worker = None
        self.analyze_worker = None
        self.config = self._load_config()
        
        # 初始化日志会话（根据配置决定是否启用）
        self._init_logging()
        
        # 初始化数据库
        from database import DatabaseManager
        self.db_manager = DatabaseManager()
        
        self.init_ui()
        self.init_menu()
        self.init_toolbar()
        self.init_statusbar()
        
        self.load_default_directories()
    
    def _init_logging(self):
        """根据配置初始化日志"""
        logging_config = self.config.get('logging', {})
        enabled = logging_config.get('enabled', True)
        
        if enabled:
            try:
                log_path = processing_logger.start_session("file_analyzer")
                print(f"日志文件已创建: {log_path}")
            except Exception as e:
                print(f"初始化日志失败: {e}")
        else:
            print("日志记录已禁用（根据配置）")
    
    def _load_config(self) -> dict:
        """加载配置文件"""
        config_path = self._get_config_path()
        if os.path.exists(config_path):
            try:
                with open(config_path, 'r', encoding='utf-8') as f:
                    return json.load(f)
            except Exception as e:
                print(f"加载配置文件失败: {e}")
        
        return {}
    
    def _save_config(self):
        """保存配置文件"""
        if not self.config:
            return
        
        try:
            config_path = self._get_config_path()
            with open(config_path, 'w', encoding='utf-8') as f:
                json.dump(self.config, f, ensure_ascii=False, indent=4)
        except Exception as e:
            print(f"保存配置文件失败: {e}")
    
    def _save_initial_directory(self, directory: str):
        """保存初始目录到配置文件"""
        self.config['initial_directory'] = directory
        self._save_config()
    
    def init_ui(self):
        """初始化UI界面"""
        self.setWindowTitle("文件分析管理器")
        self.setGeometry(100, 100, 1400, 900)
        
        # 创建中央部件
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        
        # 主布局
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(10, 10, 10, 10)
        main_layout.setSpacing(10)
        
        # 主内容区域（使用分割器）- 设置拉伸因子，确保占用至少80%高度
        content_splitter = QSplitter(Qt.Horizontal)
        content_splitter.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        
        # 左侧：推荐窗口
        self.recommendation_panel = RecommendationPanel()
        self.recommendation_panel.recommendation_selected.connect(self.on_recommendation_selected)
        self.recommendation_panel.setMinimumHeight(400)
        content_splitter.addWidget(self.recommendation_panel)
        
        # 中间：预览窗口 - 设置最小高度
        self.preview_panel = PreviewPanel()
        self.preview_panel.setMinimumHeight(400)
        content_splitter.addWidget(self.preview_panel)
        
        # 右侧：分类结果窗口 - 设置最小高度
        self.classification_panel = ClassificationPanel()
        self.classification_panel.file_selected.connect(self.on_file_selected)
        self.classification_panel.setMinimumHeight(400)
        content_splitter.addWidget(self.classification_panel)
        
        # 设置分割器比例
        content_splitter.setSizes([350, 600, 350])
        
        # 将分割器添加到主布局，设置拉伸因子为1，确保占用主要空间
        main_layout.addWidget(content_splitter, 1)
        
        # 设置样式
        self.setStyleSheet("""
            QMainWindow {
                background-color: #f5f5f5;
            }
            QLabel {
                color: #333;
            }
            QPushButton {
                background-color: #2196F3;
                color: white;
                border: none;
                padding: 8px 16px;
                border-radius: 4px;
            }
            QPushButton:hover {
                background-color: #1976D2;
            }
            QPushButton:pressed {
                background-color: #0D47A1;
            }
            QComboBox {
                padding: 5px;
                border: 1px solid #ccc;
                border-radius: 4px;
                background-color: white;
            }
            QComboBox:hover {
                border-color: #2196F3;
            }
        """)
    
    def init_menu(self):
        """初始化菜单栏"""
        menubar = self.menuBar()
        
        # 文件菜单
        file_menu = menubar.addMenu("文件(&F)")
        
        # 打开目录
        open_dir_action = QAction("打开目录...", self)
        open_dir_action.setShortcut(QKeySequence.Open)
        open_dir_action.triggered.connect(self.open_directory)
        file_menu.addAction(open_dir_action)
        
        # 扫描默认目录
        scan_default_action = QAction("扫描默认目录", self)
        scan_default_action.setShortcut("Ctrl+D")
        scan_default_action.triggered.connect(self.scan_default_directories)
        file_menu.addAction(scan_default_action)
        
        file_menu.addSeparator()
        
        # 退出
        exit_action = QAction("退出", self)
        exit_action.setShortcut(QKeySequence.Quit)
        exit_action.triggered.connect(self.close)
        file_menu.addAction(exit_action)
        
        # 工具菜单
        tools_menu = menubar.addMenu("工具(&T)")
        
        # 设置
        settings_action = QAction("设置...", self)
        settings_action.triggered.connect(self.show_settings)
        tools_menu.addAction(settings_action)
        
        tools_menu.addSeparator()
        
        # 清空历史分析
        clear_history_action = QAction("清空历史分析", self)
        clear_history_action.triggered.connect(self.clear_analysis_history)
        tools_menu.addAction(clear_history_action)
        
        # 帮助菜单
        help_menu = menubar.addMenu("帮助(&H)")
        
        about_action = QAction("关于", self)
        about_action.triggered.connect(self.show_about)
        help_menu.addAction(about_action)
    
    def init_toolbar(self):
        """初始化工具栏"""
        # 搜索面板作为工具栏
        self.search_panel = SearchPanel()
        self.search_panel.search_requested.connect(self.on_search)
        self.search_panel.directory_changed.connect(self.on_directory_changed)
        self.search_panel.analyze_requested.connect(self.start_analyze)
        
        # 将搜索面板添加为工具栏
        toolbar = QToolBar()
        toolbar.setMovable(False)
        toolbar.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.addToolBar(toolbar)
        toolbar.addWidget(self.search_panel)
    
    def init_statusbar(self):
        """初始化状态栏"""
        self.statusbar = QStatusBar()
        self.setStatusBar(self.statusbar)
        
        self.statusbar.showMessage("就绪")
        
        # 文件计数标签
        self.file_count_label = QLabel("文件: 0")
        self.statusbar.addPermanentWidget(self.file_count_label)
        
        # 选中文件标签
        self.selected_label = QLabel("选中: 无")
        self.statusbar.addPermanentWidget(self.selected_label)
    
    def load_default_directories(self):
        """加载默认目录"""
        initial_dir = self.config.get('initial_directory', '')
        
        if initial_dir and os.path.exists(initial_dir):
            self.current_directory = initial_dir
            self.load_directory(self.current_directory)
        else:
            default_dirs = self.scanner.get_default_scan_directories()
            if default_dirs:
                self.current_directory = default_dirs[0]
                self.load_directory(self.current_directory)
    
    def load_directory(self, directory: str):
        """加载指定目录"""
        if not os.path.exists(directory):
            QMessageBox.warning(self, "错误", f"目录不存在: {directory}")
            return
        
        self.current_directory = directory
        self._save_initial_directory(directory)
        
        self.start_scan('directory', directory)
    
    def start_scan(self, scan_type: str, directory: str = None):
        """启动后台扫描"""
        if self.scan_worker and self.scan_worker.isRunning():
            self.scan_worker.wait()
        
        self.scan_worker = ScanWorker(self.scanner, scan_type)
        if directory:
            self.scan_worker.set_directory(directory)
        
        self.scan_worker.scan_progress.connect(self.on_scan_progress)
        self.scan_worker.scan_finished.connect(self.on_scan_finished)
        
        self.statusbar.showMessage("正在扫描...")
        self.scan_worker.start()
    
    def on_scan_progress(self, message: str, progress: int):
        """扫描进度回调"""
        self.statusbar.showMessage(message)
    
    def on_scan_finished(self, results: Dict[str, Any]):
        """扫描完成回调"""
        if 'error' in results:
            QMessageBox.critical(self, "扫描错误", f"扫描失败: {results['error']}")
            self.statusbar.showMessage("扫描失败")
            return
        
        # 收集所有文件
        all_files = []
        for dir_name, files in results.get('default_directories', {}).items():
            all_files.extend(files)
        
        self.current_files = all_files
        
        # 更新状态栏
        total_files = results.get('total_files', len(all_files))
        self.file_count_label.setText(f"文件: {total_files}")
        self.statusbar.showMessage(f"扫描完成，共 {total_files} 个文件")
        
        # 更新推荐面板（显示目录树）
        root_dir = results.get('root_directory', self.current_directory)
        dir_structure = results.get('directory_structure')
        
        if dir_structure:
            # 如果有目录结构字典，直接使用（支持虚拟根目录）
            self.recommendation_panel.set_directory_structure_from_dict(root_dir or '默认目录', dir_structure)
        elif root_dir and os.path.exists(root_dir):
            self.recommendation_panel.set_directory_structure(root_dir, all_files)
        else:
            self.generate_recommendations_legacy(all_files)
    
    def generate_recommendations_legacy(self, files: List[str]):
        """生成文件推荐（旧方式，用于兼容）"""
        # 按类型分组
        file_groups = {}
        for file_path in files:
            ext = os.path.splitext(file_path)[1].lower()
            if ext not in file_groups:
                file_groups[ext] = []
            file_groups[ext].append(file_path)
        
        # 生成推荐项
        recommendations = []
        
        # 最近修改的文件
        recent_files = sorted(files, 
                            key=lambda x: os.path.getmtime(x) if os.path.exists(x) else 0,
                            reverse=True)[:5]
        if recent_files:
            recommendations.append({
                'title': '最近修改',
                'files': recent_files,
                'type': 'recent'
            })
        
        # 按类型推荐
        for ext, ext_files in sorted(file_groups.items(), key=lambda x: len(x[1]), reverse=True)[:3]:
            type_names = {
                '.pdf': 'PDF文档',
                '.doc': 'Word文档',
                '.docx': 'Word文档',
                '.ppt': 'PPT演示',
                '.pptx': 'PPT演示',
                '.txt': '文本文件',
                '.jpg': '图片',
                '.jpeg': '图片',
                '.png': '图片',
                '.mp3': '音频',
                '.wav': '音频',
            }
            type_name = type_names.get(ext, f'{ext} 文件')
            recommendations.append({
                'title': type_name,
                'files': ext_files[:5],
                'type': 'category'
            })
        
        self.recommendation_panel.set_recommendations(recommendations)
    
    def on_file_selected(self, file_path: str):
        """文件选中回调"""
        self.selected_label.setText(f"选中: {os.path.basename(file_path)}")
        self.preview_panel.preview_file(file_path)
    
    def on_search(self, query: str):
        """搜索回调 - 使用语义搜索"""
        if not query:
            # 如果查询为空，切换回分类结果模式
            self.classification_panel.set_classification_mode()
            self.statusbar.showMessage("已返回分类结果")
            return
        
        # 执行语义搜索
        self.perform_semantic_search(query)
    
    def perform_semantic_search(self, query: str):
        """执行语义搜索
        
        Args:
            query: 搜索查询文本
        """
        try:
            self.statusbar.showMessage(f"正在执行语义搜索: '{query}'...")
            
            # 导入语义查询模块
            from semantic_query import SemanticQuery
            
            # 创建语义查询器
            semantic_query = SemanticQuery(
                db_manager=self.db_manager,
                config=self.config
            )
            
            # 从配置中获取top_k和top_m参数
            query_config = self.config.get('query', {})
            top_k = query_config.get('top_k', 10)
            top_m = query_config.get('top_m', 5)
            
            # 执行搜索
            search_result = semantic_query.search(query, top_k=top_k, top_m=top_m)
            
            # 在分类面板中显示搜索结果
            self.classification_panel.set_search_results(search_result)
            
            # 更新状态栏
            file_count = len(search_result.files)
            self.statusbar.showMessage(
                f"语义搜索 '{query}' 完成，找到 {file_count} 个相关文件"
            )
            
        except Exception as e:
            print(f"语义搜索失败: {e}")
            import traceback
            traceback.print_exc()
            self.statusbar.showMessage(f"语义搜索失败: {str(e)}")
            QMessageBox.warning(self, "搜索失败", f"语义搜索执行失败: {str(e)}")
    
    def on_directory_changed(self, directory: str):
        """目录改变回调"""
        self.load_directory(directory)
    
    def on_recommendation_selected(self, file_path: str):
        """推荐项选中回调"""
        self.on_file_selected(file_path)
    
    def start_analyze(self):
        """开始分析当前目录的文件

        流程：
        1. 扫描目录，将文件添加到数据库
        2. 检查每个文件的分析状态
        3. 已分析的文件直接从数据库读取分类结果
        4. 未分析的文件执行分析流程
        """
        print("[DEBUG] start_analyze 被调用", flush=True)
        from database import FileStatus

        if not self.current_directory:
            print("[DEBUG] 错误: 未选择目录", flush=True)
            QMessageBox.warning(self, "提示", "请先选择一个目录")
            return

        print(f"[DEBUG] 当前目录: {self.current_directory}", flush=True)

        # 先扫描目录并将文件添加到数据库
        print("[DEBUG] 开始扫描目录...", flush=True)
        files = []
        try:
            files = self.scanner.scan_directory(self.current_directory, db_manager=self.db_manager)
            print(f"[DEBUG] 扫描完成，找到 {len(files)} 个文件", flush=True)
        except Exception as e:
            print(f"[DEBUG] 扫描目录失败: {e}", flush=True)
            import traceback
            traceback.print_exc()
            QMessageBox.critical(self, "错误", f"扫描目录失败: {str(e)}")
            return
        
        if not files:
            print("[DEBUG] 目录中没有可分析的文件")
            QMessageBox.warning(self, "提示", "目录中没有可分析的文件")
            return
        
        self.current_files = files
        
        # 收集已分析和待分析的文件
        analyzed_results = {}  # 已分析文件的分类结果
        files_to_analyze = []  # 待分析的文件路径列表
        
        print("[DEBUG] 开始检查文件分析状态...")
        for file_path in files:
            try:
                file_record = self.db_manager.get_file_by_path(file_path)
                if file_record and file_record.analysis_status != FileStatus.PENDING:
                    # 已分析，从数据库读取分类结果
                    if file_record.semantic_categories:
                        primary_category = file_record.semantic_categories[0]['category']
                        
                        if primary_category not in analyzed_results:
                            analyzed_results[primary_category] = []
                        
                        analyzed_results[primary_category].append({
                            'path': file_path,
                            'categories': file_record.semantic_categories,
                            'primary_category': primary_category,
                            'primary_confidence': file_record.semantic_categories[0]['confidence'],
                            'total_blocks': 1,  # 简化处理
                            'from_cache': True  # 标记为从缓存读取
                        })
                else:
                    # 待分析
                    files_to_analyze.append(file_path)
            except Exception as e:
                print(f"[DEBUG] 检查文件状态失败 {file_path}: {e}")
        
        print(f"[DEBUG] 已分析文件: {len(analyzed_results)} 个分类, 待分析文件: {len(files_to_analyze)} 个")
        
        # 如果有已分析的文件，先展示结果
        if analyzed_results:
            print("[DEBUG] 显示已分析文件结果...")
            self.classification_panel.set_classification_results(analyzed_results)
            cached_count = sum(len(files) for files in analyzed_results.values())
            self.statusbar.showMessage(f"已加载 {cached_count} 个已分析文件的分类结果")
        
        # 如果有待分析的文件，启动分析线程
        if files_to_analyze:
            print("[DEBUG] 启动分析线程...")
            try:
                self.analyze_worker = AnalyzeWorker(self.db_manager)
                self.analyze_worker.set_pending_files(files_to_analyze)
                self.analyze_worker.progress.connect(self.on_analyze_progress)
                self.analyze_worker.finished.connect(
                    lambda results: self.on_analyze_finished(results, analyzed_results)
                )
                self.analyze_worker.error.connect(self.on_analyze_error)
                
                self.search_panel.show_progress(True)
                self.statusbar.showMessage(f"正在分析 {len(files_to_analyze)} 个新文件...")
                print("[DEBUG] 分析线程启动前...")
                self.analyze_worker.start()
                print("[DEBUG] 分析线程已启动")
            except Exception as e:
                print(f"[DEBUG] 启动分析线程失败: {e}")
                import traceback
                traceback.print_exc()
                QMessageBox.critical(self, "错误", f"启动分析失败: {str(e)}")
        else:
            # 所有文件都已分析
            print("[DEBUG] 所有文件都已分析")
            QMessageBox.information(self, "分析完成", "所有文件已完成分析，结果已从缓存加载")
    
    def on_analyze_progress(self, message: str, progress: int):
        """分析进度回调"""
        self.search_panel.set_progress(progress)
        self.statusbar.showMessage(message)
    
    def on_analyze_finished(self, results: Dict[str, List[Dict]], cached_results: Dict[str, List[Dict]] = None):
        """分析完成回调
        
        Args:
            results: 新分析的文件分类结果
            cached_results: 从缓存读取的已分析文件分类结果
        """
        self.search_panel.show_progress(False)
        
        print(f"[DEBUG] 分析完成，新结果: {results}")
        print(f"[DEBUG] 新分析分类数量: {len(results)}")
        for cat, files in results.items():
            print(f"[DEBUG]   {cat}: {len(files)} 个文件")
        
        # 合并新分析结果和缓存结果
        merged_results = {}
        
        # 先添加缓存结果
        if cached_results:
            for category, files in cached_results.items():
                merged_results[category] = files.copy()
        
        # 再添加新分析结果
        for category, files in results.items():
            if category not in merged_results:
                merged_results[category] = []
            merged_results[category].extend(files)
        
        total_new = sum(len(files) for files in results.values())
        total_cached = sum(len(files) for files in (cached_results or {}).values())
        total = total_new + total_cached
        
        self.statusbar.showMessage(f"分析完成，共 {total} 个文件（新分析 {total_new}，缓存 {total_cached}）")
        
        if merged_results:
            self.classification_panel.set_classification_results(merged_results)
            print(f"[DEBUG] 已调用 set_classification_results，合并后分类数: {len(merged_results)}")
        else:
            print(f"[DEBUG] 结果为空，未更新分类面板")
            QMessageBox.information(self, "分析结果", "未找到可分类的文件内容")
    
    def on_analyze_error(self, error_msg: str):
        """分析错误回调"""
        self.search_panel.show_progress(False)
        QMessageBox.critical(self, "分析错误", error_msg)
        self.statusbar.showMessage("分析失败")
    
    def open_directory(self):
        """打开目录对话框"""
        directory = QFileDialog.getExistingDirectory(self, "选择目录")
        if directory:
            self.load_directory(directory)
    
    def scan_default_directories(self):
        """扫描默认目录"""
        self.start_scan('default')
    
    def show_settings(self):
        """显示设置对话框"""
        QMessageBox.information(self, "设置", "设置功能待实现")
    
    def clear_analysis_history(self):
        """清空历史分析数据"""
        reply = QMessageBox.question(
            self,
            "确认清空",
            "确定要清空所有历史分析数据吗？\n这将删除所有文件记录、数据块、语义块和分类结果。",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No
        )
        
        if reply == QMessageBox.Yes:
            try:
                success = self.db_manager.clear_all_data()
                if success:
                    QMessageBox.information(self, "清空成功", "所有历史分析数据已清空")
                    self.statusbar.showMessage("历史数据已清空")
                    # 清空分类面板
                    self.classification_panel.set_classification_results({})
                else:
                    QMessageBox.warning(self, "清空失败", "清空历史数据时出错，请查看控制台日志")
            except Exception as e:
                QMessageBox.critical(self, "错误", f"清空历史数据失败: {str(e)}")
    
    def show_about(self):
        """显示关于对话框"""
        QMessageBox.about(self, "关于",
            "<h2>文件分析管理器</h2>"
            "<p>版本: 1.0.0</p>"
            "<p>基于文件分析引擎的本地文件管理工具</p>"
            "<p>支持多种文件格式的解析、预览和语义分析</p>"
        )
    
    def closeEvent(self, event):
        """关闭事件处理"""
        if self.scan_worker and self.scan_worker.isRunning():
            self.scan_worker.wait(1000)

        # 停止性能监控
        try:
            perf_monitor = get_performance_monitor()
            perf_monitor.stop()
        except Exception as e:
            print(f"停止性能监控失败: {e}")

        # 结束日志会话（如果日志已启用）
        logging_config = self.config.get('logging', {})
        if logging_config.get('enabled', True):
            try:
                processing_logger.end_session()
            except Exception as e:
                print(f"关闭日志失败: {e}")

        event.accept()


def main():
    """主入口函数"""
    app = QApplication(sys.argv)
    app.setApplicationName("文件分析管理器")
    app.setApplicationVersion("1.0.0")
    
    # 设置应用样式
    app.setStyle('Fusion')
    
    window = MainWindow()
    window.show()
    
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
