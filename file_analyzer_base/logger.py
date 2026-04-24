"""
日志模块 - 记录文件处理流程的详细日志
"""
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional
import json


class ProcessingLogger:
    """处理流程日志记录器"""
    
    _instance = None
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance
    
    def __init__(self):
        if self._initialized:
            return
        
        self._initialized = True
        self.logger = None
        self.current_file = None
        self.log_dir = Path(__file__).parent / "logs"
        self.log_dir.mkdir(exist_ok=True)
        
    def start_session(self, session_name: Optional[str] = None) -> str:
        """
        开始一个新的日志会话
        
        Args:
            session_name: 会话名称，如果为None则使用当前时间
            
        Returns:
            日志文件路径
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        if session_name:
            log_filename = f"{session_name}_{timestamp}.log"
        else:
            log_filename = f"processing_{timestamp}.log"
        
        log_path = self.log_dir / log_filename
        
        # 创建logger
        self.logger = logging.getLogger(f"ProcessingLogger_{timestamp}")
        self.logger.setLevel(logging.DEBUG)
        
        # 清除旧的handlers
        self.logger.handlers.clear()
        
        # 文件处理器
        file_handler = logging.FileHandler(log_path, encoding='utf-8')
        file_handler.setLevel(logging.DEBUG)
        
        # 控制台处理器
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
        
        # 格式化器
        formatter = logging.Formatter(
            '[%(asctime)s] [%(levelname)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        file_handler.setFormatter(formatter)
        console_handler.setFormatter(formatter)
        
        self.logger.addHandler(file_handler)
        self.logger.addHandler(console_handler)
        
        self.log_path = str(log_path)
        self.logger.info("=" * 80)
        self.logger.info(f"日志会话开始: {timestamp}")
        self.logger.info(f"日志文件: {log_path}")
        self.logger.info("=" * 80)
        
        return self.log_path
    
    def log_module_start(self, module_name: str, file_path: str, 
                         extra_info: Optional[Dict[str, Any]] = None):
        """
        记录模块开始处理
        
        Args:
            module_name: 模块名称
            file_path: 处理的文件路径
            extra_info: 额外信息字典
        """
        if not self.logger:
            return
        
        self.current_file = file_path
        self.logger.info("")
        self.logger.info("-" * 80)
        self.logger.info(f"【模块开始】{module_name}")
        self.logger.info(f"  文件: {file_path}")
        
        if extra_info:
            for key, value in extra_info.items():
                self.logger.info(f"  {key}: {value}")
        
        self.logger.info("-" * 80)
    
    def log_module_input(self, module_name: str, input_data: Any):
        """
        记录模块输入
        
        Args:
            module_name: 模块名称
            input_data: 输入数据
        """
        if not self.logger:
            return
        
        self.logger.info(f"  [输入] {module_name}")
        self._log_data(input_data, level=1)
    
    def log_module_output(self, module_name: str, output_data: Any):
        """
        记录模块输出
        
        Args:
            module_name: 模块名称
            output_data: 输出数据
        """
        if not self.logger:
            return
        
        self.logger.info(f"  [输出] {module_name}")
        self._log_data(output_data, level=1)
    
    def log_module_end(self, module_name: str, success: bool = True, 
                       message: Optional[str] = None):
        """
        记录模块处理结束
        
        Args:
            module_name: 模块名称
            success: 是否成功
            message: 附加消息
        """
        if not self.logger:
            return
        
        status = "成功" if success else "失败"
        self.logger.info("-" * 80)
        self.logger.info(f"【模块结束】{module_name} - {status}")
        if message:
            self.logger.info(f"  消息: {message}")
        self.logger.info("-" * 80)
        self.logger.info("")
    
    def log_step(self, step_name: str, description: str, 
                 data: Optional[Any] = None):
        """
        记录处理步骤
        
        Args:
            step_name: 步骤名称
            description: 步骤描述
            data: 相关数据
        """
        if not self.logger:
            return
        
        self.logger.info(f"  [步骤] {step_name}: {description}")
        if data is not None:
            self._log_data(data, level=2)
    
    def log_data_block(self, block_type: str, block_id: str, 
                       content_preview: str, metadata: Optional[Dict] = None):
        """
        记录数据块信息
        
        Args:
            block_type: 数据块类型
            block_id: 数据块ID
            content_preview: 内容预览
            metadata: 元数据
        """
        if not self.logger:
            return
        
        self.logger.info(f"    [数据块] 类型={block_type}, ID={block_id}")
        preview = content_preview[:200] + "..." if len(content_preview) > 200 else content_preview
        self.logger.info(f"      内容预览: {preview}")
        
        if metadata:
            for key, value in metadata.items():
                self.logger.info(f"      {key}: {value}")
    
    def log_semantic_block(self, block_id: str, text_description: str,
                          keywords: list, vector_dim: int):
        """
        记录语义块信息
        
        Args:
            block_id: 语义块ID
            text_description: 文本描述
            keywords: 关键词列表
            vector_dim: 向量维度
        """
        if not self.logger:
            return
        
        self.logger.info(f"    [语义块] ID={block_id}")
        desc_preview = text_description[:150] + "..." if len(text_description) > 150 else text_description
        self.logger.info(f"      文本描述: {desc_preview}")
        self.logger.info(f"      关键词: {', '.join(keywords[:10])}")
        self.logger.info(f"      向量维度: {vector_dim}")
    
    def log_classification(self, category: str, confidence: float, 
                          all_scores: Optional[Dict[str, float]] = None):
        """
        记录分类结果
        
        Args:
            category: 分类类别
            confidence: 置信度
            all_scores: 所有类别的分数
        """
        if not self.logger:
            return
        
        self.logger.info(f"    [分类结果] 类别={category}, 置信度={confidence:.4f}")
        
        if all_scores:
            sorted_scores = sorted(all_scores.items(), key=lambda x: x[1], reverse=True)
            self.logger.info(f"      所有类别得分:")
            for cat, score in sorted_scores[:5]:  # 只显示前5个
                marker = " <-- 选中" if cat == category else ""
                self.logger.info(f"        {cat}: {score:.4f}{marker}")
    
    def log_error(self, module_name: str, error: Exception, 
                  context: Optional[str] = None):
        """
        记录错误信息
        
        Args:
            module_name: 模块名称
            error: 异常对象
            context: 错误上下文
        """
        if not self.logger:
            return
        
        self.logger.error("=" * 80)
        self.logger.error(f"【错误】{module_name}")
        if context:
            self.logger.error(f"  上下文: {context}")
        self.logger.error(f"  错误类型: {type(error).__name__}")
        self.logger.error(f"  错误信息: {str(error)}")
        self.logger.error("=" * 80)
    
    def log_summary(self, total_files: int, success_count: int, 
                    fail_count: int, duration_seconds: float):
        """
        记录处理摘要
        
        Args:
            total_files: 总文件数
            success_count: 成功数
            fail_count: 失败数
            duration_seconds: 耗时（秒）
        """
        if not self.logger:
            return
        
        self.logger.info("")
        self.logger.info("=" * 80)
        self.logger.info("【处理摘要】")
        self.logger.info(f"  总文件数: {total_files}")
        self.logger.info(f"  成功: {success_count}")
        self.logger.info(f"  失败: {fail_count}")
        self.logger.info(f"  总耗时: {duration_seconds:.2f}秒")
        if total_files > 0:
            avg_time = duration_seconds / total_files
            self.logger.info(f"  平均耗时: {avg_time:.2f}秒/文件")
        self.logger.info("=" * 80)
    
    def _log_data(self, data: Any, level: int = 0):
        """
        递归记录数据
        
        Args:
            data: 要记录的数据
            level: 缩进级别
        """
        indent = "  " * (level + 1)
        
        if isinstance(data, dict):
            for key, value in data.items():
                if isinstance(value, (dict, list)) and value:
                    self.logger.info(f"{indent}{key}:")
                    self._log_data(value, level + 1)
                else:
                    value_str = str(value)[:100]
                    if len(str(value)) > 100:
                        value_str += "..."
                    self.logger.info(f"{indent}{key}: {value_str}")
        elif isinstance(data, list):
            for i, item in enumerate(data[:10]):  # 只显示前10个
                self.logger.info(f"{indent}[{i}]:")
                self._log_data(item, level + 1)
            if len(data) > 10:
                self.logger.info(f"{indent}... 还有 {len(data) - 10} 项")
        else:
            data_str = str(data)[:200]
            if len(str(data)) > 200:
                data_str += "..."
            self.logger.info(f"{indent}{data_str}")
    
    def end_session(self):
        """结束日志会话"""
        if self.logger:
            self.logger.info("")
            self.logger.info("=" * 80)
            self.logger.info("日志会话结束")
            self.logger.info("=" * 80)
            self.logger = None
            self.current_file = None


# 全局日志实例
processing_logger = ProcessingLogger()
