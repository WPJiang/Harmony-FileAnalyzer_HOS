"""
UI启动入口 - 调试版本
捕获详细错误信息
"""

import os
import sys
import traceback


def setup_error_logging():
    """设置错误日志到文件"""
    if getattr(sys, 'frozen', False):
        log_dir = os.path.dirname(sys.executable)
    else:
        log_dir = os.path.dirname(os.path.abspath(__file__))
    
    log_path = os.path.join(log_dir, 'file_analyzer_error.log')
    
    try:
        with open(log_path, 'w', encoding='utf-8') as f:
            f.write(f"=== 程序启动日志 ===\n")
            f.write(f"工作目录: {os.getcwd()}\n")
            f.write(f"sys.path: {sys.path}\n")
            f.write(f"sys.executable: {sys.executable}\n")
            f.write(f"sys.frozen: {getattr(sys, 'frozen', False)}\n")
            f.write("\n")
    except Exception as e:
        print(f"无法创建日志文件: {e}")
    
    return log_path


def log_error(msg):
    """记录错误信息"""
    if getattr(sys, 'frozen', False):
        log_dir = os.path.dirname(sys.executable)
    else:
        log_dir = os.path.dirname(os.path.abspath(__file__))
    
    log_path = os.path.join(log_dir, 'file_analyzer_error.log')
    
    try:
        with open(log_path, 'a', encoding='utf-8') as f:
            f.write(f"{msg}\n")
    except:
        pass


def launch_ui():
    """启动UI界面"""
    log_path = setup_error_logging()
    
    try:
        log_error("开始设置路径...")
        
        if getattr(sys, 'frozen', False):
            base_path = os.path.dirname(sys.executable)
            internal_path = os.path.join(base_path, '_internal')
            if os.path.exists(internal_path):
                sys.path.insert(0, internal_path)
                log_error(f"添加_internal路径: {internal_path}")
            sys.path.insert(0, base_path)
            log_error(f"添加base路径: {base_path}")
        else:
            base_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            sys.path.insert(0, base_path)
            log_error(f"添加开发路径: {base_path}")
        
        log_error(f"sys.path: {sys.path}")
        
        log_error("导入PyQt5...")
        from PyQt5.QtWidgets import QApplication
        from PyQt5.QtGui import QFont
        log_error("PyQt5导入成功")
        
        log_error("导入MainWindow...")
        try:
            from ui.main_window import MainWindow
            log_error("从ui.main_window导入成功")
        except ImportError as e:
            log_error(f"从ui.main_window导入失败: {e}")
            try:
                from main_window import MainWindow
                log_error("从main_window导入成功")
            except ImportError as e2:
                log_error(f"从main_window导入也失败: {e2}")
                raise
        
        log_error("创建QApplication...")
        app = QApplication(sys.argv)
        app.setApplicationName("文件分析管理器")
        app.setApplicationVersion("1.0.0")
        app.setStyle('Fusion')
        log_error("QApplication创建成功")
        
        font = QFont("Microsoft YaHei", 9)
        app.setFont(font)
        
        log_error("创建MainWindow...")
        window = MainWindow()
        log_error("MainWindow创建成功")
        
        window.show()
        log_error("窗口显示成功，进入事件循环...")
        
        sys.exit(app.exec_())
        
    except Exception as e:
        error_msg = f"程序启动失败: {str(e)}\n"
        error_msg += f"详细错误:\n{traceback.format_exc()}"
        log_error(error_msg)
        
        try:
            from PyQt5.QtWidgets import QMessageBox, QApplication
            if not QApplication.instance():
                app = QApplication(sys.argv)
            msg = QMessageBox()
            msg.setIcon(QMessageBox.Critical)
            msg.setWindowTitle("启动错误")
            msg.setText(f"程序启动失败：\n{str(e)}\n\n详细错误已记录到:\n{log_path}")
            msg.exec_()
        except Exception as e2:
            log_error(f"显示错误对话框也失败: {e2}")
        
        sys.exit(1)


def main():
    """主函数"""
    launch_ui()


if __name__ == '__main__':
    main()
