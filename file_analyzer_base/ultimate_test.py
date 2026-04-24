#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""最简单的启动脚本"""

import sys
from PyQt5.QtWidgets import QApplication, QMainWindow, QLabel
from PyQt5.QtGui import QFont

app = QApplication(sys.argv)
window = QMainWindow()
window.setWindowTitle("测试")
label = QLabel("超级简单的测试！", window)
label.setGeometry(50, 50, 300, 50)
window.resize(400, 150)
window.show()
sys.exit(app.exec_())
