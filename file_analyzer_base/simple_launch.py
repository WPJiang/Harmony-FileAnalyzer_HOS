#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""简化版启动脚本"""

import sys
import os

if getattr(sys, 'frozen', False):
    base_path = os.path.dirname(sys.executable)
    internal_path = os.path.join(base_path, '_internal')
    if os.path.exists(internal_path):
        sys.path.insert(0, internal_path)
    sys.path.insert(0, base_path)
else:
    base_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, base_path)

from PyQt5.QtWidgets import QApplication, QMainWindow, QLabel
from PyQt5.QtGui import QFont

app = QApplication(sys.argv)
app.setApplicationName("文件分析管理器")
app.setStyle('Fusion')
font = QFont("Microsoft YaHei", 9)
app.setFont(font)

try:
    from ui.main_window import MainWindow
    window = MainWindow()
except Exception as e:
    window = QMainWindow()
    window.setWindowTitle("测试")
    label = QLabel(f"测试成功！\n错误: {str(e)}", window)
    label.setGeometry(50, 50, 400, 100)
    window.resize(500, 200)

window.show()
sys.exit(app.exec_())
