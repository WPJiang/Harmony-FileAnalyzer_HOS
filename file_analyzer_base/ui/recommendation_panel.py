import os
from typing import List, Dict, Any, Optional
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QScrollArea,
    QFrame, QPushButton, QGridLayout, QSizePolicy, QToolButton,
    QMenu, QAction, QTreeWidget, QTreeWidgetItem, QHeaderView,
    QAbstractItemView
)
from PyQt5.QtCore import Qt, pyqtSignal, QSize
from PyQt5.QtGui import QIcon, QFont, QColor


class RecommendationItem(QFrame):
    """推荐项组件"""
    
    clicked = pyqtSignal(str)
    
    def __init__(self, file_path: str, parent=None):
        super().__init__(parent)
        self.file_path = file_path
        self.file_name = os.path.basename(file_path)
        self.file_ext = os.path.splitext(file_path)[1].lower()
        
        self.init_ui()
    
    def init_ui(self):
        """初始化UI"""
        self.setFrameStyle(QFrame.StyledPanel)
        self.setCursor(Qt.PointingHandCursor)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        
        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 8, 10, 8)
        layout.setSpacing(10)
        
        # 文件图标
        icon_label = QLabel(self.get_file_icon())
        icon_label.setStyleSheet(f"font-size: 24px; color: {self.get_icon_color()};")
        layout.addWidget(icon_label)
        
        # 文件信息
        info_layout = QVBoxLayout()
        info_layout.setSpacing(2)
        
        # 文件名
        name_label = QLabel(self.file_name)
        name_label.setStyleSheet("""
            font-weight: bold;
            color: #333;
            font-size: 12px;
        """)
        name_label.setWordWrap(True)
        name_label.setMaximumWidth(200)
        info_layout.addWidget(name_label)
        
        # 文件类型
        type_label = QLabel(self.get_file_type())
        type_label.setStyleSheet("color: #666; font-size: 10px;")
        info_layout.addWidget(type_label)
        
        layout.addLayout(info_layout, 1)
        
        # 设置样式
        self.setStyleSheet("""
            RecommendationItem {
                background-color: white;
                border: 1px solid #e0e0e0;
                border-radius: 6px;
            }
            RecommendationItem:hover {
                background-color: #f5f5f5;
                border-color: #2196F3;
            }
        """)
    
    def get_file_icon(self) -> str:
        """获取文件图标"""
        icon_map = {
            '.pdf': '📄',
            '.doc': '📝',
            '.docx': '📝',
            '.ppt': '📊',
            '.pptx': '📊',
            '.xls': '📈',
            '.xlsx': '📈',
            '.txt': '📃',
            '.md': '📑',
            '.jpg': '🖼️',
            '.jpeg': '🖼️',
            '.png': '🖼️',
            '.gif': '🎨',
            '.mp3': '🎵',
            '.wav': '🎵',
            '.mp4': '🎬',
            '.avi': '🎬',
            '.zip': '📦',
            '.rar': '📦',
            '.exe': '⚙️',
        }
        return icon_map.get(self.file_ext, '📎')
    
    def get_icon_color(self) -> str:
        """获取图标颜色"""
        color_map = {
            '.pdf': '#e74c3c',
            '.doc': '#2ecc71',
            '.docx': '#2ecc71',
            '.ppt': '#e67e22',
            '.pptx': '#e67e22',
            '.jpg': '#9b59b6',
            '.jpeg': '#9b59b6',
            '.png': '#9b59b6',
            '.mp3': '#3498db',
            '.wav': '#3498db',
        }
        return color_map.get(self.file_ext, '#95a5a6')
    
    def get_file_type(self) -> str:
        """获取文件类型"""
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
            '.mp3': 'MP3 音频',
            '.wav': 'WAV 音频',
            '.mp4': 'MP4 视频',
            '.zip': '压缩文件',
            '.rar': '压缩文件',
        }
        return type_map.get(self.file_ext, f'{self.file_ext} 文件' if self.file_ext else '未知类型')
    
    def mousePressEvent(self, event):
        """鼠标点击事件"""
        self.clicked.emit(self.file_path)


class RecommendationGroup(QFrame):
    """推荐组组件"""
    
    item_selected = pyqtSignal(str)
    
    def __init__(self, title: str, files: List[str], parent=None):
        super().__init__(parent)
        self.title = title
        self.files = files
        
        self.init_ui()
    
    def init_ui(self):
        """初始化UI"""
        self.setFrameStyle(QFrame.NoFrame)
        
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 10, 0, 10)
        layout.setSpacing(10)
        
        # 标题栏
        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(5, 0, 5, 0)
        
        title_label = QLabel(self.title)
        title_label.setStyleSheet("""
            font-size: 14px;
            font-weight: bold;
            color: #333;
        """)
        header_layout.addWidget(title_label)
        
        header_layout.addStretch()
        
        # 更多按钮
        more_btn = QToolButton()
        more_btn.setText("更多")
        more_btn.setStyleSheet("""
            QToolButton {
                color: #2196F3;
                border: none;
                font-size: 11px;
            }
            QToolButton:hover {
                color: #1976D2;
            }
        """)
        more_btn.clicked.connect(self.show_more)
        header_layout.addWidget(more_btn)
        
        layout.addWidget(header)
        
        # 文件列表
        self.items_widget = QWidget()
        self.items_layout = QVBoxLayout(self.items_widget)
        self.items_layout.setContentsMargins(0, 0, 0, 0)
        self.items_layout.setSpacing(5)
        
        # 只显示前5个
        for file_path in self.files[:5]:
            item = RecommendationItem(file_path)
            item.clicked.connect(self.on_item_clicked)
            self.items_layout.addWidget(item)
        
        self.items_layout.addStretch()
        layout.addWidget(self.items_widget)
    
    def on_item_clicked(self, file_path: str):
        """项点击事件"""
        self.item_selected.emit(file_path)
    
    def show_more(self):
        """显示更多"""
        # 可以扩展显示所有文件
        pass


class DirectoryTreeItem(QTreeWidgetItem):
    """目录树项"""
    
    def __init__(self, path: str, is_dir: bool = True, parent=None):
        super().__init__(parent)
        self.path = path
        self.is_dir = is_dir
        self.name = os.path.basename(path) if path else "根目录"
        
        # 设置显示文本
        self.setText(0, self.name)
        self.setToolTip(0, path)
        
        # 设置图标
        if is_dir:
            self.setText(0, f"📁 {self.name}")
            self.setForeground(0, QColor("#2196F3"))
            font = QFont()
            font.setBold(True)
            self.setFont(0, font)
        else:
            icon = self.get_file_icon()
            self.setText(0, f"{icon} {self.name}")
            self.setForeground(0, QColor("#333"))
    
    def get_file_icon(self) -> str:
        """获取文件图标"""
        ext = os.path.splitext(self.path)[1].lower()
        icon_map = {
            '.pdf': '📄', '.doc': '📝', '.docx': '📝',
            '.ppt': '📊', '.pptx': '📊', '.xls': '📈', '.xlsx': '📈',
            '.txt': '📃', '.md': '📑',
            '.jpg': '🖼️', '.jpeg': '🖼️', '.png': '🖼️', '.gif': '🎨',
            '.mp3': '🎵', '.wav': '🎵',
            '.mp4': '🎬', '.avi': '🎬',
            '.zip': '📦', '.rar': '📦',
            '.exe': '⚙️',
        }
        return icon_map.get(ext, '📎')


class RecommendationPanel(QWidget):
    """推荐窗口组件 - 包含目录树"""
    
    recommendation_selected = pyqtSignal(str)
    directory_selected = pyqtSignal(str)
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.recommendations = []
        self.directory_structure = {}
        self.show_files = False  # 默认不显示文件
        self.all_items = []  # 存储所有项目数据
        
        self.init_ui()
    
    def init_ui(self):
        """初始化UI"""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(10)
        
        # 标题
        title_layout = QHBoxLayout()
        
        title_label = QLabel("📂 目录结构")
        title_label.setStyleSheet("""
            font-size: 16px;
            font-weight: bold;
            color: #333;
            padding: 5px;
        """)
        title_layout.addWidget(title_label)
        
        title_layout.addStretch()
        
        # 展开/折叠按钮（可切换状态，默认展开）
        self.expand_collapse_btn = QPushButton("折叠全部")
        self.expand_collapse_btn.setCheckable(True)
        self.expand_collapse_btn.setChecked(False)  # 默认未选中，表示当前是展开状态
        self.expand_collapse_btn.setStyleSheet("""
            QPushButton {
                background-color: #2196F3;
                color: white;
                border: none;
                padding: 4px 12px;
                border-radius: 4px;
                font-size: 11px;
            }
            QPushButton:hover {
                background-color: #1976D2;
            }
            QPushButton:checked {
                background-color: #607D8B;
            }
            QPushButton:checked:hover {
                background-color: #455A64;
            }
        """)
        self.expand_collapse_btn.clicked.connect(self.toggle_expand_collapse)
        title_layout.addWidget(self.expand_collapse_btn)
        
        # 显示文件按钮
        self.show_files_btn = QPushButton("显示文件")
        self.show_files_btn.setCheckable(True)
        self.show_files_btn.setChecked(False)
        self.show_files_btn.setStyleSheet("""
            QPushButton {
                background-color: #FF9800;
                color: white;
                border: none;
                padding: 4px 12px;
                border-radius: 4px;
                font-size: 11px;
            }
            QPushButton:hover {
                background-color: #F57C00;
            }
            QPushButton:checked {
                background-color: #4CAF50;
            }
            QPushButton:checked:hover {
                background-color: #388E3C;
            }
        """)
        self.show_files_btn.clicked.connect(self.toggle_show_files)
        title_layout.addWidget(self.show_files_btn)
        
        # 刷新按钮
        refresh_btn = QPushButton("🔄")
        refresh_btn.setToolTip("刷新")
        refresh_btn.setStyleSheet("""
            QPushButton {
                background-color: transparent;
                border: none;
                font-size: 16px;
                padding: 5px;
            }
            QPushButton:hover {
                background-color: #f0f0f0;
                border-radius: 4px;
            }
        """)
        refresh_btn.clicked.connect(self.refresh_recommendations)
        title_layout.addWidget(refresh_btn)
        
        layout.addLayout(title_layout)
        
        # 目录树
        self.tree = QTreeWidget()
        self.tree.setHeaderHidden(True)
        self.tree.setColumnCount(1)
        self.tree.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree.setAlternatingRowColors(True)
        self.tree.itemClicked.connect(self.on_tree_item_clicked)
        self.tree.itemDoubleClicked.connect(self.on_tree_item_double_clicked)
        
        # 设置树样式
        self.tree.setStyleSheet("""
            QTreeWidget {
                border: 1px solid #ddd;
                border-radius: 6px;
                background-color: white;
                alternate-background-color: #f9f9f9;
            }
            QTreeWidget::item {
                padding: 5px;
                border-bottom: 1px solid #eee;
            }
            QTreeWidget::item:selected {
                background-color: #e3f2fd;
                color: #1976D2;
            }
            QTreeWidget::item:hover {
                background-color: #f5f5f5;
            }
            QTreeWidget::branch:has-children:!has-siblings:closed,
            QTreeWidget::branch:closed:has-children:has-siblings {
                image: none;
                border-image: none;
            }
            QTreeWidget::branch:open:has-children:!has-siblings,
            QTreeWidget::branch:open:has-children:has-siblings {
                image: none;
                border-image: none;
            }
        """)
        
        layout.addWidget(self.tree)
        
        # 设置样式
        self.setStyleSheet("""
            RecommendationPanel {
                background-color: white;
                border: 1px solid #ddd;
                border-radius: 8px;
            }
        """)
        
    def set_directory_structure(self, root_path: str, file_list: List[str]):
        """设置目录结构
        
        Args:
            root_path: 根目录路径
            file_list: 文件列表
        """
        self.tree.clear()
        self.directory_structure = {'root': root_path, 'files': file_list}
        
        if not root_path or not os.path.exists(root_path):
            return
        
        # 获取当前展开状态
        should_expand = not self.expand_collapse_btn.isChecked()
        
        # 创建根节点
        root_name = os.path.basename(root_path) or root_path
        root_item = DirectoryTreeItem(root_path, is_dir=True)
        root_item.setText(0, f"🖥️ {root_name}")
        self.tree.addTopLevelItem(root_item)
        
        # 构建目录树
        dir_dict = {}
        dir_dict[root_path] = root_item
        
        for file_path in file_list:
            if not os.path.exists(file_path):
                continue
            
            # 计算相对路径
            try:
                rel_path = os.path.relpath(file_path, root_path)
            except ValueError:
                continue
            
            parts = rel_path.split(os.sep)
            current_path = root_path
            parent_item = root_item
            
            # 逐级创建目录节点
            for i, part in enumerate(parts[:-1]):
                current_path = os.path.join(current_path, part)
                
                if current_path not in dir_dict:
                    dir_item = DirectoryTreeItem(current_path, is_dir=True)
                    parent_item.addChild(dir_item)
                    dir_dict[current_path] = dir_item
                
                parent_item = dir_dict[current_path]
            
            # 添加文件节点（仅在 show_files 为 True 时显示）
            if self.show_files:
                file_item = DirectoryTreeItem(file_path, is_dir=False)
                parent_item.addChild(file_item)
        
        # 根据当前状态展开或折叠
        root_item.setExpanded(should_expand)
        if should_expand:
            self.tree.expandAll()
        else:
            self.tree.collapseAll()
    
    def set_directory_structure_from_dict(self, root_path: str, dir_structure: Dict):
        """从字典设置目录结构（更高效的递归扫描结果展示）
        
        Args:
            root_path: 根目录路径
            dir_structure: 目录结构字典，包含 name, path, dirs, files
        """
        self.tree.clear()
        self.directory_structure = dir_structure
        
        if not root_path or not dir_structure:
            return
        
        # 获取当前展开状态
        should_expand = not self.expand_collapse_btn.isChecked()
        
        # 创建根节点
        root_name = dir_structure.get('name') or os.path.basename(root_path) or root_path
        root_item = DirectoryTreeItem(root_path, is_dir=True)
        root_item.setText(0, f"🖥️ {root_name}")
        self.tree.addTopLevelItem(root_item)
        
        # 递归构建树
        self._build_tree_recursive(root_item, dir_structure)
        
        # 根据当前状态展开或折叠
        root_item.setExpanded(should_expand)
        if should_expand:
            self.tree.expandAll()
        else:
            self.tree.collapseAll()
    
    def _build_tree_recursive(self, parent_item: DirectoryTreeItem, dir_data: Dict):
        """递归构建目录树
        
        Args:
            parent_item: 父节点
            dir_data: 目录数据字典
        """
        # 添加子目录
        subdirs = dir_data.get('dirs', {})
        for dir_name, dir_info in sorted(subdirs.items()):
            dir_path = dir_info.get('path', os.path.join(parent_item.path, dir_name))
            dir_item = DirectoryTreeItem(dir_path, is_dir=True)
            parent_item.addChild(dir_item)
            
            # 递归添加子目录的内容
            self._build_tree_recursive(dir_item, dir_info)
        
        # 添加文件（仅在 show_files 为 True 时显示）
        if self.show_files:
            files = dir_data.get('files', [])
            for file_path in sorted(files):
                if os.path.exists(file_path):
                    file_item = DirectoryTreeItem(file_path, is_dir=False)
                    parent_item.addChild(file_item)
    
    def on_tree_item_clicked(self, item: DirectoryTreeItem, column: int):
        """树节点点击事件 - 单击目录展开/折叠，单击文件选中"""
        if item.is_dir:
            # 单击目录节点，切换展开/折叠状态
            item.setExpanded(not item.isExpanded())
        else:
            # 单击文件节点，触发选中事件
            self.recommendation_selected.emit(item.path)
    
    def on_tree_item_double_clicked(self, item: DirectoryTreeItem, column: int):
        """树节点双击事件 - 双击文件打开/预览"""
        if not item.is_dir:
            # 双击文件节点，触发选中事件（可用于打开或预览）
            self.recommendation_selected.emit(item.path)
    
    def toggle_expand_collapse(self):
        """切换展开/折叠状态"""
        is_collapsed = self.expand_collapse_btn.isChecked()
        
        if is_collapsed:
            # 当前状态为折叠，执行折叠操作
            self.tree.collapseAll()
            self.expand_collapse_btn.setText("展开全部")
        else:
            # 当前状态为展开，执行展开操作
            self.tree.expandAll()
            self.expand_collapse_btn.setText("折叠全部")
    
    def expand_all(self):
        """展开所有节点"""
        self.tree.expandAll()
        self.expand_collapse_btn.setChecked(False)
        self.expand_collapse_btn.setText("折叠全部")
    
    def collapse_all(self):
        """折叠所有节点"""
        self.tree.collapseAll()
        self.expand_collapse_btn.setChecked(True)
        self.expand_collapse_btn.setText("展开全部")
    
    def toggle_show_files(self):
        """切换显示文件状态"""
        self.show_files = self.show_files_btn.isChecked()
        self.show_files_btn.setText("隐藏文件" if self.show_files else "显示文件")
        
        # 重新构建树以应用显示/隐藏文件
        if self.directory_structure:
            if isinstance(self.directory_structure, dict) and 'dirs' in self.directory_structure:
                # 从字典结构重建
                root_path = self.directory_structure.get('path', '')
                self.set_directory_structure_from_dict(root_path, self.directory_structure)
            else:
                # 从文件列表重建
                root_path = self.directory_structure.get('root', '')
                files = self.directory_structure.get('files', [])
                self.set_directory_structure(root_path, files)
    
    def set_recommendations(self, recommendations: List[Dict[str, Any]]):
        """设置推荐内容（兼容旧接口）"""
        self.recommendations = recommendations
        # 从推荐中提取文件列表构建目录树
        all_files = []
        for rec in recommendations:
            all_files.extend(rec.get('files', []))
        
        if all_files:
            # 使用第一个文件的目录作为根
            root = os.path.dirname(all_files[0]) if all_files[0] else ""
            self.set_directory_structure(root, all_files)
    
    def refresh_display(self):
        """刷新显示（兼容旧接口）"""
        if self.recommendations:
            self.set_recommendations(self.recommendations)
    
    def refresh_recommendations(self):
        """刷新推荐"""
        self.refresh_display()
    
    def add_recommendation(self, title: str, files: List[str], rec_type: str = 'general'):
        """添加推荐"""
        self.recommendations.append({
            'title': title,
            'files': files,
            'type': rec_type
        })
        self.set_recommendations(self.recommendations)
    
    def clear(self):
        """清除推荐"""
        self.recommendations = []
        self.refresh_display()
