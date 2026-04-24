#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""调试启动脚本"""

import sys
import os

print("当前目录:", os.getcwd())
print("Python路径:", sys.path)
print()

try:
    print("正在导入PyQt5...")
    import PyQt5
    print("✓ PyQt5导入成功")
    
    print()
    print("正在尝试导入main_window...")
    
    try:
        from ui.main_window import MainWindow
        print("✓ ui.main_window.MainWindow导入成功")
    except ImportError as e:
        print("✗ ui.main_window.MainWindow导入失败:", e)
        
        try:
            from main_window import MainWindow
            print("✓ main_window.MainWindow导入成功")
        except ImportError as e2:
            print("✗ main_window.MainWindow导入失败:", e2)
            
            try:
                import sys
                sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
                from ui.main_window import MainWindow
                print("✓ 添加路径后 ui.main_window.MainWindow导入成功")
            except ImportError as e3:
                print("✗ 添加路径后 ui.main_window.MainWindow导入失败:", e3)
                import traceback
                traceback.print_exc()
    
    print()
    print("正在启动UI...")
    
    from PyQt5.QtWidgets import QApplication
    app = QApplication(sys.argv)
    app.setApplicationName("文件分析管理器")
    app.setApplicationVersion("1.0.0")
    app.setStyle('Fusion')
    
    from PyQt5.QtGui import QFont
    font = QFont("Microsoft YaHei", 9)
    app.setFont(font)
    
    window = MainWindow()
    window.show()
    
    print("✓ UI启动成功，正在运行...")
    sys.exit(app.exec_())
    
except Exception as e:
    print()
    print("="*60)
    print("发生错误:")
    print("="*60)
    print(e)
    import traceback
    traceback.print_exc()
    input("\n按回车键退出...")
