"""性能监控模块

提供全面的性能监控功能，包括：
1. 单文件处理时延
2. 平均单文件处理时延
3. 模块处理时延
4. 内存占用监控（平均、峰值、各模块）
5. 性能报告生成

配置方式：在config.json中设置performance.enabled为true开启
"""

import os
import sys
import json
import time
import threading
import traceback
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field, asdict
from datetime import datetime
from collections import defaultdict
from contextlib import contextmanager

# 添加父目录到路径
base_dir = os.path.dirname(os.path.abspath(__file__))
if base_dir not in sys.path:
    sys.path.insert(0, base_dir)

# 尝试导入psutil用于内存监控
try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    print("WARNING: psutil未安装，内存监控功能将受限。安装: pip install psutil")


@dataclass
class ModuleMetrics:
    """模块性能指标"""
    name: str
    call_count: int = 0
    total_time_ms: float = 0.0
    min_time_ms: float = float('inf')
    max_time_ms: float = 0.0
    avg_time_ms: float = 0.0
    memory_start_mb: float = 0.0
    memory_end_mb: float = 0.0
    memory_peak_mb: float = 0.0
    memory_delta_mb: float = 0.0

    def update(self, time_ms: float, mem_start: float, mem_end: float, mem_peak: float):
        self.call_count += 1
        self.total_time_ms += time_ms
        self.min_time_ms = min(self.min_time_ms, time_ms)
        self.max_time_ms = max(self.max_time_ms, time_ms)
        self.avg_time_ms = self.total_time_ms / self.call_count
        self.memory_peak_mb = max(self.memory_peak_mb, mem_peak)
        self.memory_delta_mb = mem_end - self.memory_start_mb

    def to_dict(self) -> Dict[str, Any]:
        return {
            'name': self.name,
            'call_count': self.call_count,
            'total_time_ms': round(self.total_time_ms, 2),
            'min_time_ms': round(self.min_time_ms, 2) if self.min_time_ms != float('inf') else 0,
            'max_time_ms': round(self.max_time_ms, 2),
            'avg_time_ms': round(self.avg_time_ms, 2),
            'memory_start_mb': round(self.memory_start_mb, 2),
            'memory_end_mb': round(self.memory_end_mb, 2),
            'memory_peak_mb': round(self.memory_peak_mb, 2),
            'memory_delta_mb': round(self.memory_delta_mb, 2)
        }


@dataclass
class FileProcessingMetrics:
    """文件处理性能指标"""
    file_path: str
    file_name: str
    start_time: datetime
    end_time: datetime
    total_time_ms: float
    module_times: Dict[str, float] = field(default_factory=dict)
    success: bool = True
    error_message: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            'file_path': self.file_path,
            'file_name': self.file_name,
            'start_time': self.start_time.isoformat(),
            'end_time': self.end_time.isoformat(),
            'total_time_ms': round(self.total_time_ms, 2),
            'module_times': {k: round(v, 2) for k, v in self.module_times.items()},
            'success': self.success,
            'error_message': self.error_message
        }


@dataclass
class MemorySnapshot:
    """内存快照"""
    timestamp: datetime
    memory_mb: float
    module_name: str = "global"


class PerformanceMonitor:
    """性能监控器 - 单例模式

    监控功能：
    1. 模块处理时延
    2. 文件处理时延
    3. 内存占用
    4. 生成性能报告
    """

    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return

        self._enabled = False
        self._config = {}

        # 模块指标
        self._module_metrics: Dict[str, ModuleMetrics] = {}

        # 文件处理指标
        self._file_metrics: List[FileProcessingMetrics] = []
        self._current_file_metrics: Optional[FileProcessingMetrics] = None

        # 内存监控
        self._memory_snapshots: List[MemorySnapshot] = []
        self._initial_memory_mb: float = 0.0
        self._peak_memory_mb: float = 0.0

        # 时间追踪
        self._start_time: Optional[datetime] = None
        self._module_start_times: Dict[str, float] = {}
        self._module_memory_start: Dict[str, float] = {}

        # 统计锁
        self._metrics_lock = threading.Lock()

        # 日志文件
        self._log_file: Optional[str] = None
        self._log_interval: int = 5
        self._last_log_time: float = 0

        # 后台监控线程
        self._monitor_thread: Optional[threading.Thread] = None
        self._stop_monitor = threading.Event()

        self._initialized = True

    def initialize(self, config: Dict[str, Any] = None):
        """初始化性能监控器

        Args:
            config: 配置字典，包含performance配置
        """
        # 防止重复初始化
        if self._enabled and self._start_time is not None:
            print("[PerformanceMonitor] 性能监控器已初始化，跳过重复初始化")
            return

        self._config = config or {}
        perf_config = self._config.get('performance', {})

        self._enabled = perf_config.get('enabled', False)
        self._log_file = perf_config.get('log_file', 'logs/performance.log')
        self._log_interval = perf_config.get('log_interval_seconds', 5)

        if not self._enabled:
            print("[PerformanceMonitor] 性能监控已禁用")
            return

        # 确保日志目录存在
        log_dir = os.path.dirname(self._log_file)
        if log_dir and not os.path.exists(log_dir):
            os.makedirs(log_dir, exist_ok=True)

        # 记录初始内存
        self._initial_memory_mb = self._get_current_memory_mb()
        self._peak_memory_mb = self._initial_memory_mb
        self._start_time = datetime.now()

        # 启动后台内存监控
        if perf_config.get('track_memory', True):
            self._start_memory_monitor()

        # 写入初始化日志
        self._write_log("=== 性能监控启动 ===")
        self._write_log(f"启动时间: {self._start_time.isoformat()}")
        self._write_log(f"初始内存: {self._initial_memory_mb:.2f} MB")

        print(f"[PerformanceMonitor] 性能监控已启动，日志文件: {self._log_file}")

    def _get_current_memory_mb(self) -> float:
        """获取当前进程内存占用（MB）"""
        if PSUTIL_AVAILABLE:
            try:
                process = psutil.Process(os.getpid())
                return process.memory_info().rss / 1024 / 1024
            except Exception:
                pass
        return 0.0

    def _start_memory_monitor(self):
        """启动后台内存监控线程"""
        self._stop_monitor.clear()
        self._monitor_thread = threading.Thread(target=self._memory_monitor_loop, daemon=True)
        self._monitor_thread.start()

    def _memory_monitor_loop(self):
        """内存监控循环"""
        while not self._stop_monitor.is_set():
            try:
                current_mem = self._get_current_memory_mb()
                self._peak_memory_mb = max(self._peak_memory_mb, current_mem)

                # 使用 try-lock 避免阻塞主线程
                if self._metrics_lock.acquire(timeout=0.1):
                    try:
                        self._memory_snapshots.append(MemorySnapshot(
                            timestamp=datetime.now(),
                            memory_mb=current_mem,
                            module_name="global"
                        ))
                        # 限制快照数量
                        if len(self._memory_snapshots) > 10000:
                            self._memory_snapshots = self._memory_snapshots[-5000:]
                    finally:
                        self._metrics_lock.release()

                # 每秒采样一次
                time.sleep(1)
            except Exception as e:
                print(f"[PerformanceMonitor] 内存监控错误: {e}")

    @contextmanager
    def track_module(self, module_name: str, extra_info: Dict[str, Any] = None):
        """追踪模块性能（上下文管理器）

        Args:
            module_name: 模块名称
            extra_info: 额外信息

        Usage:
            with performance_monitor.track_module("DataParser"):
                # 模块代码
                pass
        """
        if not self._enabled:
            yield
            return

        start_time = time.perf_counter()
        start_memory = self._get_current_memory_mb()
        peak_memory = start_memory

        # 更新模块开始时的内存
        if module_name not in self._module_metrics:
            self._module_metrics[module_name] = ModuleMetrics(name=module_name)
            self._module_metrics[module_name].memory_start_mb = start_memory

        self._module_memory_start[module_name] = start_memory

        try:
            yield
        finally:
            end_time = time.perf_counter()
            end_memory = self._get_current_memory_mb()

            # 计算耗时（毫秒）
            elapsed_ms = (end_time - start_time) * 1000

            # 更新峰值内存
            peak_memory = max(peak_memory, end_memory)
            self._peak_memory_mb = max(self._peak_memory_mb, peak_memory)

            # 使用非阻塞方式获取锁，避免死锁
            if self._metrics_lock.acquire(timeout=1.0):
                try:
                    if module_name in self._module_metrics:
                        self._module_metrics[module_name].update(
                            elapsed_ms, start_memory, end_memory, peak_memory
                        )
                        self._module_metrics[module_name].memory_end_mb = end_memory
                finally:
                    self._metrics_lock.release()

            # 记录到当前文件指标（不需要锁）
            if self._current_file_metrics:
                self._current_file_metrics.module_times[module_name] = \
                    self._current_file_metrics.module_times.get(module_name, 0) + elapsed_ms

    def start_file_processing(self, file_path: str):
        """开始文件处理追踪

        Args:
            file_path: 文件路径
        """
        if not self._enabled:
            return

        file_name = os.path.basename(file_path)
        self._current_file_metrics = FileProcessingMetrics(
            file_path=file_path,
            file_name=file_name,
            start_time=datetime.now(),
            end_time=datetime.now(),
            total_time_ms=0.0
        )

    def end_file_processing(self, success: bool = True, error_message: str = ""):
        """结束文件处理追踪

        Args:
            success: 是否成功
            error_message: 错误信息
        """
        if not self._enabled or self._current_file_metrics is None:
            return

        self._current_file_metrics.end_time = datetime.now()
        self._current_file_metrics.total_time_ms = (
            self._current_file_metrics.end_time - self._current_file_metrics.start_time
        ).total_seconds() * 1000
        self._current_file_metrics.success = success
        self._current_file_metrics.error_message = error_message

        # 使用非阻塞方式获取锁
        if self._metrics_lock.acquire(timeout=1.0):
            try:
                self._file_metrics.append(self._current_file_metrics)
            finally:
                self._metrics_lock.release()

        # 写入日志
        self._write_log(f"文件处理: {self._current_file_metrics.file_name}, "
                       f"耗时: {self._current_file_metrics.total_time_ms:.2f}ms, "
                       f"成功: {success}")

        self._current_file_metrics = None

    def record_custom_metric(self, metric_name: str, value: float, unit: str = ""):
        """记录自定义指标

        Args:
            metric_name: 指标名称
            value: 指标值
            unit: 单位
        """
        if not self._enabled:
            return

        self._write_log(f"自定义指标: {metric_name} = {value:.2f} {unit}")

    def _write_log(self, message: str):
        """写入日志文件"""
        if not self._log_file:
            return

        try:
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            log_line = f"[{timestamp}] {message}\n"

            with open(self._log_file, 'a', encoding='utf-8') as f:
                f.write(log_line)
        except Exception as e:
            print(f"[PerformanceMonitor] 写入日志失败: {e}")

    def get_module_metrics(self, module_name: str = None) -> Dict[str, Any]:
        """获取模块指标

        Args:
            module_name: 模块名称，为None时返回所有模块

        Returns:
            模块指标字典
        """
        if self._metrics_lock.acquire(timeout=1.0):
            try:
                if module_name:
                    if module_name in self._module_metrics:
                        return self._module_metrics[module_name].to_dict()
                    return {}

                return {name: metrics.to_dict()
                        for name, metrics in self._module_metrics.items()}
            finally:
                self._metrics_lock.release()
        return {}

    def get_file_metrics(self, limit: int = 100) -> List[Dict[str, Any]]:
        """获取文件处理指标

        Args:
            limit: 返回数量限制

        Returns:
            文件处理指标列表
        """
        if self._metrics_lock.acquire(timeout=1.0):
            try:
                return [m.to_dict() for m in self._file_metrics[-limit:]]
            finally:
                self._metrics_lock.release()
        return []

    def get_memory_stats(self) -> Dict[str, Any]:
        """获取内存统计

        Returns:
            内存统计字典
        """
        current_mem = self._get_current_memory_mb()

        return {
            'initial_memory_mb': round(self._initial_memory_mb, 2),
            'current_memory_mb': round(current_mem, 2),
            'peak_memory_mb': round(self._peak_memory_mb, 2),
            'memory_increase_mb': round(current_mem - self._initial_memory_mb, 2),
            'snapshot_count': len(self._memory_snapshots)
        }

    def get_summary(self) -> Dict[str, Any]:
        """获取性能摘要

        Returns:
            性能摘要字典
        """
        # 先获取需要的数据，避免嵌套锁
        file_metrics_copy = []
        if self._metrics_lock.acquire(timeout=1.0):
            try:
                file_metrics_copy = list(self._file_metrics)
            finally:
                self._metrics_lock.release()

        # 计算文件处理统计
        file_count = len(file_metrics_copy)
        success_count = sum(1 for m in file_metrics_copy if m.success)
        failed_count = file_count - success_count

        total_file_time = sum(m.total_time_ms for m in file_metrics_copy)
        avg_file_time = total_file_time / file_count if file_count > 0 else 0

        file_times = [m.total_time_ms for m in file_metrics_copy]
        min_file_time = min(file_times) if file_times else 0
        max_file_time = max(file_times) if file_times else 0

        return {
            'monitoring_enabled': self._enabled,
            'start_time': self._start_time.isoformat() if self._start_time else None,
            'uptime_seconds': (datetime.now() - self._start_time).total_seconds() if self._start_time else 0,
            'file_processing': {
                'total_files': file_count,
                'successful': success_count,
                'failed': failed_count,
                'total_time_ms': round(total_file_time, 2),
                'avg_time_ms': round(avg_file_time, 2),
                'min_time_ms': round(min_file_time, 2),
                'max_time_ms': round(max_file_time, 2)
            },
            'memory': self.get_memory_stats(),
            'modules': self.get_module_metrics()
        }

    def generate_report(self, output_file: str = None) -> str:
        """生成性能报告

        Args:
            output_file: 输出文件路径，为None时使用默认路径

        Returns:
            报告文件路径
        """
        if not output_file:
            output_file = self._log_file.replace('.log', '_report.json') if self._log_file else 'logs/performance_report.json'

        report = {
            'generated_at': datetime.now().isoformat(),
            'summary': self.get_summary(),
            'file_metrics': self.get_file_metrics(limit=1000),
            'detailed_module_metrics': {}
        }

        # 详细的模块指标
        for name, metrics in self._module_metrics.items():
            report['detailed_module_metrics'][name] = {
                **metrics.to_dict(),
                'time_percentage': round(metrics.total_time_ms /
                    sum(m.total_time_ms for m in self._module_metrics.values()) * 100, 2)
                    if self._module_metrics else 0
            }

        # 确保目录存在
        output_dir = os.path.dirname(output_file)
        if output_dir and not os.path.exists(output_dir):
            os.makedirs(output_dir, exist_ok=True)

        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                json.dump(report, f, ensure_ascii=False, indent=2)

            self._write_log(f"性能报告已生成: {output_file}")
            print(f"[PerformanceMonitor] 性能报告已生成: {output_file}")

            return output_file
        except Exception as e:
            print(f"[PerformanceMonitor] 生成报告失败: {e}")
            return ""

    def reset(self):
        """重置所有指标"""
        if self._metrics_lock.acquire(timeout=1.0):
            try:
                self._module_metrics.clear()
                self._file_metrics.clear()
                self._memory_snapshots.clear()
                self._initial_memory_mb = self._get_current_memory_mb()
                self._peak_memory_mb = self._initial_memory_mb
                self._start_time = datetime.now()
            finally:
                self._metrics_lock.release()

        self._write_log("=== 性能指标已重置 ===")

    def stop(self):
        """停止性能监控"""
        self._enabled = False
        self._stop_monitor.set()

        if self._monitor_thread and self._monitor_thread.is_alive():
            self._monitor_thread.join(timeout=2)

        # 生成最终报告
        if self._start_time:
            self.generate_report()

        self._write_log("=== 性能监控已停止 ===")


# 全局访问函数
def get_performance_monitor() -> PerformanceMonitor:
    """获取全局性能监控器实例"""
    return PerformanceMonitor()


# 便捷装饰器
def track_performance(module_name: str):
    """性能追踪装饰器

    Usage:
        @track_performance("DataParser.parse_file")
        def parse_file(self, file_path):
            ...
    """
    def decorator(func):
        def wrapper(*args, **kwargs):
            monitor = get_performance_monitor()
            with monitor.track_module(module_name):
                return func(*args, **kwargs)
        return wrapper
    return decorator