import os
from typing import List, Optional
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QTreeWidget, QTreeWidgetItem,
    QHeaderView, QLabel, QPushButton, QLineEdit, QMenu, QAction,
    QAbstractItemView, QMessageBox, QFileDialog
)
from PyQt5.QtCore import Qt, pyqtSignal, QSize
from PyQt5.QtGui import QIcon, QColor, QFont


class FileBrowser(QWidget):
    """文件浏览器组件"""
    
    file_selected = pyqtSignal(str)
    directory_double_clicked = pyqtSignal(str)
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.files = []
        self.directories = []
        self.current_directory = None
        self.show_directories = True
        self.current_sort_column = 0
        self.sort_ascending = True
        
        self.init_ui()
    
    def init_ui(self):
        """初始化UI"""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(5)
        
        # 工具栏
        toolbar = QWidget()
        toolbar_layout = QHBoxLayout(toolbar)
        toolbar_layout.setContentsMargins(5, 5, 5, 5)
        toolbar_layout.setSpacing(5)
        
        # 视图模式按钮
        self.list_btn = QPushButton("列表")
        self.list_btn.setCheckable(True)
        self.list_btn.setChecked(True)
        self.list_btn.clicked.connect(lambda: self.set_view_mode('list'))
        toolbar_layout.addWidget(self.list_btn)
        
        self.detail_btn = QPushButton("详细")
        self.detail_btn.setCheckable(True)
        self.detail_btn.clicked.connect(lambda: self.set_view_mode('detail'))
        toolbar_layout.addWidget(self.detail_btn)
        
        toolbar_layout.addStretch()
        
        # 筛选输入框
        self.filter_edit = QLineEdit()
        self.filter_edit.setPlaceholderText("筛选文件...")
        self.filter_edit.textChanged.connect(self.on_filter_changed)
        toolbar_layout.addWidget(self.filter_edit)
        
        layout.addWidget(toolbar)
        
        # 文件树
        self.tree = QTreeWidget()
        self.tree.setColumnCount(4)
        self.tree.setHeaderLabels(["名称", "大小", "类型", "修改时间"])
        self.tree.header().setSectionResizeMode(0, QHeaderView.Stretch)
        self.tree.header().setSectionResizeMode(1, QHeaderView.ResizeToContents)
        self.tree.header().setSectionResizeMode(2, QHeaderView.ResizeToContents)
        self.tree.header().setSectionResizeMode(3, QHeaderView.ResizeToContents)
        self.tree.setAlternatingRowColors(True)
        self.tree.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self.show_context_menu)
        self.tree.itemClicked.connect(self.on_item_clicked)
        self.tree.itemDoubleClicked.connect(self.on_item_double_clicked)
        self.tree.header().sectionClicked.connect(self.on_header_clicked)
        
        # 设置样式
        self.tree.setStyleSheet("""
            QTreeWidget {
                border: 1px solid #ddd;
                border-radius: 4px;
                background-color: white;
                alternate-background-color: #f9f9f9;
            }
            QTreeWidget::item {
                padding: 5px;
                border-bottom: 1px solid #eee;
            }
            QTreeWidget::item:selected {
                background-color: #2196F3;
                color: white;
            }
            QTreeWidget::item:hover {
                background-color: #e3f2fd;
            }
            QHeaderView::section {
                background-color: #f5f5f5;
                padding: 8px;
                border: none;
                border-bottom: 2px solid #ddd;
                font-weight: bold;
            }
        """)
        
        layout.addWidget(self.tree)
        
        # 状态标签
        self.status_label = QLabel("暂无文件")
        self.status_label.setStyleSheet("color: #666; padding: 5px;")
        layout.addWidget(self.status_label)
    
    def set_directory(self, directory: str):
        """设置当前目录并加载内容"""
        self.current_directory = directory
        self.load_directory_contents(directory)
    
    def load_directory_contents(self, directory: str):
        """加载目录内容（文件和子目录）"""
        self.files = []
        self.directories = []
        
        if not directory or not os.path.exists(directory):
            self.refresh_tree()
            return
        
        try:
            for item in os.listdir(directory):
                item_path = os.path.join(directory, item)
                if os.path.isdir(item_path):
                    self.directories.append(item_path)
                else:
                    self.files.append(item_path)
        except PermissionError:
            pass
        
        self.refresh_tree()
        total_items = len(self.files) + len(self.directories)
        self.status_label.setText(f"共 {total_items} 个项目 ({len(self.directories)} 个目录, {len(self.files)} 个文件)")
    
    def set_files(self, files: List[str]):
        """设置文件列表（用于搜索结果等）"""
        self.files = files
        self.directories = []
        self.current_directory = None
        self.refresh_tree()
        self.status_label.setText(f"共 {len(files)} 个文件")
    
    def refresh_tree(self):
        """刷新树形列表"""
        self.tree.clear()
        
        filter_text = self.filter_edit.text().lower()
        
        # 先添加目录
        if self.show_directories:
            for dir_path in self.directories:
                if not os.path.exists(dir_path):
                    continue
                
                # 应用筛选
                if filter_text and filter_text not in os.path.basename(dir_path).lower():
                    continue
                
                self.add_directory_item(dir_path)
        
        # 再添加文件
        for file_path in self.files:
            if not os.path.exists(file_path):
                continue
            
            # 应用筛选
            if filter_text and filter_text not in os.path.basename(file_path).lower():
                continue
            
            self.add_file_item(file_path)
        
        # 应用排序
        self.sort_items()
    
    def add_directory_item(self, dir_path: str):
        """添加目录项"""
        item = QTreeWidgetItem()
        
        dir_name = os.path.basename(dir_path)
        
        # 名称（带文件夹图标）
        item.setText(0, f"📁 {dir_name}")
        item.setData(0, Qt.UserRole, dir_path)
        
        # 大小（显示为"-"）
        item.setText(1, "-")
        item.setData(1, Qt.UserRole, 0)
        
        # 类型
        item.setText(2, "文件夹")
        item.setData(2, Qt.UserRole, "folder")
        
        # 修改时间
        try:
            import time
            mtime = os.path.getmtime(dir_path)
            time_str = time.strftime('%Y-%m-%d %H:%M', time.localtime(mtime))
            item.setText(3, time_str)
            item.setData(3, Qt.UserRole, mtime)
        except:
            item.setText(3, "-")
            item.setData(3, Qt.UserRole, 0)
        
        # 设置目录颜色
        item.setForeground(0, QColor("#2196F3"))
        item.setFont(0, QFont("Microsoft YaHei", 9, QFont.Bold))
        
        self.tree.addTopLevelItem(item)
    
    def add_file_item(self, file_path: str):
        """添加文件项"""
        item = QTreeWidgetItem()
        
        file_name = os.path.basename(file_path)
        file_ext = os.path.splitext(file_path)[1].lower()
        
        # 名称
        item.setText(0, file_name)
        item.setData(0, Qt.UserRole, file_path)
        
        # 大小
        try:
            size = os.path.getsize(file_path)
            item.setText(1, self.format_size(size))
            item.setData(1, Qt.UserRole, size)
        except:
            item.setText(1, "-")
            item.setData(1, Qt.UserRole, 0)
        
        # 类型
        type_name = self.get_file_type_name(file_ext)
        item.setText(2, type_name)
        item.setData(2, Qt.UserRole, type_name)
        
        # 修改时间
        try:
            import time
            mtime = os.path.getmtime(file_path)
            time_str = time.strftime('%Y-%m-%d %H:%M', time.localtime(mtime))
            item.setText(3, time_str)
            item.setData(3, Qt.UserRole, mtime)
        except:
            item.setText(3, "-")
            item.setData(3, Qt.UserRole, 0)
        
        # 设置图标颜色
        color = self.get_file_color(file_ext)
        if color:
            item.setForeground(0, QColor(color))
        
        self.tree.addTopLevelItem(item)
    
    def format_size(self, size: int) -> str:
        """格式化文件大小"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size < 1024.0:
                return f"{size:.1f} {unit}"
            size /= 1024.0
        return f"{size:.1f} PB"
    
    def get_file_type_name(self, ext: str) -> str:
        """获取文件类型名称"""
        type_map = {
            '.pdf': 'PDF 文档',
            '.doc': 'Word 文档',
            '.docx': 'Word 文档',
            '.ppt': 'PowerPoint',
            '.pptx': 'PowerPoint',
            '.xls': 'Excel',
            '.xlsx': 'Excel',
            '.txt': '文本文件',
            '.md': 'Markdown',
            '.jpg': 'JPEG 图片',
            '.jpeg': 'JPEG 图片',
            '.png': 'PNG 图片',
            '.gif': 'GIF 图片',
            '.bmp': 'BMP 图片',
            '.mp3': 'MP3 音频',
            '.wav': 'WAV 音频',
            '.mp4': 'MP4 视频',
            '.avi': 'AVI 视频',
            '.zip': '压缩文件',
            '.rar': '压缩文件',
            '.7z': '压缩文件',
            '.exe': '可执行文件',
            '.dll': '动态链接库',
        }
        return type_map.get(ext, f'{ext} 文件' if ext else '未知类型')
    
    def get_file_color(self, ext: str) -> Optional[str]:
        """获取文件类型对应的颜色"""
        color_map = {
            '.pdf': '#e74c3c',
            '.doc': '#2ecc71',
            '.docx': '#2ecc71',
            '.ppt': '#e67e22',
            '.pptx': '#e67e22',
            '.xls': '#27ae60',
            '.xlsx': '#27ae60',
            '.txt': '#95a5a6',
            '.jpg': '#9b59b6',
            '.jpeg': '#9b59b6',
            '.png': '#9b59b6',
            '.mp3': '#3498db',
            '.wav': '#3498db',
        }
        return color_map.get(ext)
    
    def on_item_clicked(self, item: QTreeWidgetItem, column: int):
        """项点击事件"""
        file_path = item.data(0, Qt.UserRole)
        if file_path:
            self.file_selected.emit(file_path)
    
    def on_item_double_clicked(self, item: QTreeWidgetItem, column: int):
        """项双击事件"""
        file_path = item.data(0, Qt.UserRole)
        if file_path:
            if os.path.isdir(file_path):
                self.directory_double_clicked.emit(file_path)
            else:
                self.open_file(file_path)
    
    def on_header_clicked(self, column: int):
        """表头点击事件（排序）"""
        if self.current_sort_column == column:
            self.sort_ascending = not self.sort_ascending
        else:
            self.current_sort_column = column
            self.sort_ascending = True
        
        self.sort_items()
    
    def sort_items(self):
        """排序项目"""
        self.tree.sortItems(self.current_sort_column, 
                           Qt.AscendingOrder if self.sort_ascending else Qt.DescendingOrder)
    
    def on_filter_changed(self, text: str):
        """筛选文本改变"""
        self.refresh_tree()
    
    def show_context_menu(self, position):
        """显示右键菜单"""
        item = self.tree.itemAt(position)
        if not item:
            return
        
        file_path = item.data(0, Qt.UserRole)
        if not file_path:
            return
        
        menu = QMenu()
        
        # 打开
        open_action = QAction("打开", self)
        open_action.triggered.connect(lambda: self.open_file(file_path))
        menu.addAction(open_action)
        
        # 打开所在文件夹
        open_folder_action = QAction("打开所在文件夹", self)
        open_folder_action.triggered.connect(lambda: self.open_containing_folder(file_path))
        menu.addAction(open_folder_action)
        
        menu.addSeparator()
        
        # 复制路径
        copy_path_action = QAction("复制路径", self)
        copy_path_action.triggered.connect(lambda: self.copy_path(file_path))
        menu.addAction(copy_path_action)
        
        # 属性
        properties_action = QAction("属性", self)
        properties_action.triggered.connect(lambda: self.show_properties(file_path))
        menu.addAction(properties_action)
        
        menu.exec_(self.tree.viewport().mapToGlobal(position))
    
    def open_file(self, file_path: str):
        """打开文件"""
        try:
            import subprocess
            if os.path.exists(file_path):
                os.startfile(file_path)
        except Exception as e:
            QMessageBox.warning(self, "错误", f"无法打开文件: {str(e)}")
    
    def open_containing_folder(self, file_path: str):
        """打开文件所在文件夹"""
        try:
            import subprocess
            folder = os.path.dirname(file_path)
            if os.path.exists(folder):
                os.startfile(folder)
        except Exception as e:
            QMessageBox.warning(self, "错误", f"无法打开文件夹: {str(e)}")
    
    def copy_path(self, file_path: str):
        """复制文件路径到剪贴板"""
        from PyQt5.QtWidgets import QApplication
        clipboard = QApplication.clipboard()
        clipboard.setText(file_path)
    
    def show_properties(self, file_path: str):
        """显示文件属性"""
        try:
            import subprocess
            subprocess.run(['explorer', '/select,', file_path])
        except:
            info = f"路径: {file_path}\n"
            try:
                info += f"大小: {self.format_size(os.path.getsize(file_path))}\n"
                info += f"创建时间: {os.path.getctime(file_path)}\n"
                info += f"修改时间: {os.path.getmtime(file_path)}\n"
            except:
                pass
            QMessageBox.information(self, "文件属性", info)
    
    def select_file(self, file_path: str):
        """选中指定文件"""
        for i in range(self.tree.topLevelItemCount()):
            item = self.tree.topLevelItem(i)
            if item.data(0, Qt.UserRole) == file_path:
                self.tree.setCurrentItem(item)
                self.tree.scrollToItem(item)
                break
    
    def set_view_mode(self, mode: str):
        """设置视图模式"""
        if mode == 'list':
            self.list_btn.setChecked(True)
            self.detail_btn.setChecked(False)
            self.tree.setColumnHidden(1, True)
            self.tree.setColumnHidden(2, True)
            self.tree.setColumnHidden(3, True)
        else:
            self.list_btn.setChecked(False)
            self.detail_btn.setChecked(True)
            self.tree.setColumnHidden(1, False)
            self.tree.setColumnHidden(2, False)
            self.tree.setColumnHidden(3, False)
    
    def get_selected_file(self) -> Optional[str]:
        """获取选中的文件路径"""
        item = self.tree.currentItem()
        if item:
            return item.data(0, Qt.UserRole)
        return None
