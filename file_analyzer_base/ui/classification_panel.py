import os
import sys
from typing import Dict, List, Any, Optional
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QTreeWidget, QTreeWidgetItem,
    QLabel, QPushButton, QHeaderView, QMenu, QAction, QStackedWidget
)
from PyQt5.QtCore import Qt, pyqtSignal
from PyQt5.QtGui import QIcon, QColor


class ClassificationPanel(QWidget):
    """文件分类结果树形面板（支持分类结果和搜索结果切换显示）"""
    
    file_selected = pyqtSignal(str)
    
    CATEGORY_ICONS = {
        "技术文档": "📄",
        "商业报告": "📊",
        "学术论文": "📚",
        "会议演示": "📽",
        "合同协议": "📋",
        "产品说明": "📖",
        "新闻资讯": "📰",
        "个人文档": "👤",
        "未分类": "❓",
    }
    
    CATEGORY_COLORS = {
        "技术文档": "#2196F3",
        "商业报告": "#4CAF50",
        "学术论文": "#9C27B0",
        "会议演示": "#FF9800",
        "合同协议": "#F44336",
        "产品说明": "#00BCD4",
        "新闻资讯": "#795548",
        "个人文档": "#607D8B",
        "未分类": "#9E9E9E",
    }
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.classification_results = {}
        self.search_results = []
        self.current_mode = "classification"  # "classification" 或 "search"
        self.init_ui()
    
    def init_ui(self):
        """初始化UI"""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(5)
        
        # 头部区域（包含标题和模式切换按钮）
        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(5, 5, 5, 5)
        
        self.title_label = QLabel("📊 分类结果")
        self.title_label.setStyleSheet("font-weight: bold; font-size: 14px;")
        header_layout.addWidget(self.title_label)
        
        header_layout.addStretch()
        
        # 模式切换按钮
        self.mode_btn = QPushButton("🔍 切换到搜索")
        self.mode_btn.setStyleSheet("""
            QPushButton {
                background-color: #2196F3;
                color: white;
                border: none;
                border-radius: 4px;
                padding: 4px 12px;
                font-size: 12px;
            }
            QPushButton:hover {
                background-color: #1976D2;
            }
        """)
        self.mode_btn.clicked.connect(self.toggle_mode)
        header_layout.addWidget(self.mode_btn)
        
        header_layout.addSpacing(10)
        
        self.count_label = QLabel("共 0 个文件")
        self.count_label.setStyleSheet("color: #666; font-size: 12px;")
        header_layout.addWidget(self.count_label)
        
        self.expand_btn = QPushButton("展开全部")
        self.expand_btn.setStyleSheet("""
            QPushButton {
                background-color: transparent;
                color: #2196F3;
                border: none;
                font-size: 12px;
            }
            QPushButton:hover {
                text-decoration: underline;
            }
        """)
        self.expand_btn.clicked.connect(self.expand_all)
        header_layout.addWidget(self.expand_btn)
        
        self.collapse_btn = QPushButton("折叠全部")
        self.collapse_btn.setStyleSheet("""
            QPushButton {
                background-color: transparent;
                color: #2196F3;
                border: none;
                font-size: 12px;
            }
            QPushButton:hover {
                text-decoration: underline;
            }
        """)
        self.collapse_btn.clicked.connect(self.collapse_all)
        header_layout.addWidget(self.collapse_btn)
        
        layout.addWidget(header)
        
        # 创建堆叠窗口用于切换显示
        self.stacked_widget = QStackedWidget()
        
        # 分类结果树
        self.classification_tree = QTreeWidget()
        self.classification_tree.setHeaderLabels(["分类", "文件数"])
        self.classification_tree.setAnimated(True)
        self.classification_tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.classification_tree.customContextMenuRequested.connect(self.show_context_menu)
        self.classification_tree.itemDoubleClicked.connect(self.on_item_double_clicked)
        
        header = self.classification_tree.header()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        header.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        
        self.classification_tree.setStyleSheet("""
            QTreeWidget {
                border: 1px solid #ddd;
                border-radius: 4px;
                font-size: 12px;
            }
            QTreeWidget::item {
                padding: 5px;
            }
            QTreeWidget::item:hover {
                background-color: #f5f5f5;
            }
            QTreeWidget::item:selected {
                background-color: #e3f2fd;
                color: #1976D2;
            }
        """)
        
        # 搜索结果树
        self.search_tree = QTreeWidget()
        self.search_tree.setHeaderLabels(["文件", "相似度"])
        self.search_tree.setAnimated(True)
        self.search_tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.search_tree.customContextMenuRequested.connect(self.show_search_context_menu)
        self.search_tree.itemDoubleClicked.connect(self.on_search_item_double_clicked)
        
        header2 = self.search_tree.header()
        header2.setSectionResizeMode(0, QHeaderView.Stretch)
        header2.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        
        self.search_tree.setStyleSheet("""
            QTreeWidget {
                border: 1px solid #ddd;
                border-radius: 4px;
                font-size: 12px;
            }
            QTreeWidget::item {
                padding: 5px;
            }
            QTreeWidget::item:hover {
                background-color: #f5f5f5;
            }
            QTreeWidget::item:selected {
                background-color: #e3f2fd;
                color: #1976D2;
            }
        """)
        
        self.stacked_widget.addWidget(self.classification_tree)
        self.stacked_widget.addWidget(self.search_tree)
        
        layout.addWidget(self.stacked_widget)
        
        # 引用当前显示的树
        self.tree = self.classification_tree
        
        self.setStyleSheet("""
            ClassificationPanel {
                background-color: white;
                border: 1px solid #ddd;
                border-radius: 8px;
            }
        """)
    
    def set_classification_results(self, results: Dict[str, List[Dict[str, Any]]]):
        """设置分类结果"""
        self.classification_results = results
        self.update_tree()
    
    def update_tree(self):
        """更新树形显示"""
        self.tree.clear()
        
        total_files = sum(len(files) for files in self.classification_results.values())
        self.count_label.setText(f"共 {total_files} 个文件")
        
        sorted_categories = sorted(
            self.classification_results.items(),
            key=lambda x: len(x[1]),
            reverse=True
        )
        
        for category, files in sorted_categories:
            category_item = QTreeWidgetItem(self.tree)
            
            icon = self.CATEGORY_ICONS.get(category, "📁")
            color = self.CATEGORY_COLORS.get(category, "#666666")
            
            category_item.setText(0, f"{icon} {category}")
            category_item.setText(1, str(len(files)))
            category_item.setData(0, Qt.UserRole, "category")
            category_item.setData(0, Qt.UserRole + 1, category)
            
            category_item.setForeground(0, QColor(color))
            font = category_item.font(0)
            font.setBold(True)
            category_item.setFont(0, font)
            
            for file_info in files:
                file_item = QTreeWidgetItem(category_item)
                
                file_name = os.path.basename(file_info.get('path', '未知文件'))
                confidence = file_info.get('primary_confidence', 0)
                categories = file_info.get('categories', [])
                total_blocks = file_info.get('total_blocks', 0)
                
                file_item.setText(0, file_name)
                file_item.setText(1, f"{confidence:.0%}")
                file_item.setData(0, Qt.UserRole, "file")
                file_item.setData(0, Qt.UserRole + 1, file_info.get('path', ''))
                
                tooltip_parts = [file_info.get('path', '')]
                tooltip_parts.append(f"\n共 {total_blocks} 个语义块")
                tooltip_parts.append("\n类别分布:")
                for cat_info in categories:
                    tooltip_parts.append(f"  • {cat_info['category']}: {cat_info['confidence']:.1%} ({cat_info['block_count']}块)")
                file_item.setToolTip(0, '\n'.join(tooltip_parts))
                
                if confidence >= 0.8:
                    file_item.setForeground(1, QColor("#4CAF50"))
                elif confidence >= 0.5:
                    file_item.setForeground(1, QColor("#FF9800"))
                else:
                    file_item.setForeground(1, QColor("#F44336"))
        
        self.tree.expandAll()
    
    def expand_all(self):
        """展开所有节点"""
        self.tree.expandAll()
    
    def collapse_all(self):
        """折叠所有节点"""
        self.tree.collapseAll()
    
    def show_context_menu(self, pos):
        """显示右键菜单"""
        item = self.tree.itemAt(pos)
        if not item:
            return
        
        item_type = item.data(0, Qt.UserRole)
        
        menu = QMenu(self)
        
        if item_type == "file":
            file_path = item.data(0, Qt.UserRole + 1)
            
            open_action = QAction("打开文件", self)
            open_action.triggered.connect(lambda: self.open_file(file_path))
            menu.addAction(open_action)
            
            open_folder_action = QAction("打开所在文件夹", self)
            open_folder_action.triggered.connect(lambda: self.open_folder(file_path))
            menu.addAction(open_folder_action)
            
            menu.addSeparator()
            
            copy_action = QAction("复制路径", self)
            copy_action.triggered.connect(lambda: self.copy_path(file_path))
            menu.addAction(copy_action)
        
        elif item_type == "category":
            category = item.data(0, Qt.UserRole + 1)
            
            expand_action = QAction("展开", self)
            expand_action.triggered.connect(lambda: self.tree.expandItem(item))
            menu.addAction(expand_action)
            
            collapse_action = QAction("折叠", self)
            collapse_action.triggered.connect(lambda: self.tree.collapseItem(item))
            menu.addAction(collapse_action)
        
        menu.exec_(self.tree.mapToGlobal(pos))
    
    def on_item_double_clicked(self, item, column):
        """双击项目"""
        item_type = item.data(0, Qt.UserRole)
        
        if item_type == "file":
            file_path = item.data(0, Qt.UserRole + 1)
            self.file_selected.emit(file_path)
    
    def open_file(self, file_path: str):
        """打开文件"""
        if os.path.exists(file_path):
            os.startfile(file_path)
    
    def open_folder(self, file_path: str):
        """打开所在文件夹"""
        if os.path.exists(file_path):
            folder = os.path.dirname(file_path)
            os.startfile(folder)
    
    def copy_path(self, file_path: str):
        """复制路径"""
        from PyQt5.QtWidgets import QApplication
        QApplication.clipboard().setText(file_path)
    
    def get_files_by_category(self, category: str) -> List[str]:
        """获取指定分类的文件列表"""
        files = self.classification_results.get(category, [])
        return [f.get('path', '') for f in files]
    
    def get_all_files(self) -> List[str]:
        """获取所有文件列表"""
        all_files = []
        for files in self.classification_results.values():
            all_files.extend([f.get('path', '') for f in files])
        return all_files
    
    def clear_results(self):
        """清空结果"""
        self.classification_results = {}
        self.tree.clear()
        self.count_label.setText("共 0 个文件")
    
    # ==================== 模式切换和搜索结果显示 ====================
    
    def toggle_mode(self):
        """切换显示模式"""
        if self.current_mode == "classification":
            self.set_search_mode()
        else:
            self.set_classification_mode()
    
    def set_classification_mode(self):
        """切换到分类结果模式"""
        self.current_mode = "classification"
        self.title_label.setText("📊 分类结果")
        self.mode_btn.setText("🔍 切换到搜索")
        self.stacked_widget.setCurrentIndex(0)
        self.tree = self.classification_tree
        self.expand_btn.setVisible(True)
        self.collapse_btn.setVisible(True)
        self.update_tree()
    
    def set_search_mode(self):
        """切换到搜索结果模式"""
        self.current_mode = "search"
        self.title_label.setText("🔍 搜索结果")
        self.mode_btn.setText("📊 切换到分类")
        self.stacked_widget.setCurrentIndex(1)
        self.tree = self.search_tree
        self.expand_btn.setVisible(False)
        self.collapse_btn.setVisible(False)
        self.update_search_tree()
    
    def set_search_results(self, search_results):
        """设置搜索结果
        
        Args:
            search_results: SearchResult对象，包含搜索查询和文件结果
        """
        self.search_results = search_results
        if search_results and search_results.files:
            self.set_search_mode()
        else:
            self.update_search_tree()
    
    def update_search_tree(self):
        """更新搜索结果显示"""
        self.search_tree.clear()
        
        if not self.search_results or not self.search_results.files:
            self.count_label.setText("共 0 个文件")
            # 添加提示信息
            if self.current_mode == "search":
                item = QTreeWidgetItem(self.search_tree)
                item.setText(0, "请输入搜索内容或执行搜索")
                item.setForeground(0, QColor("#999"))
            return
        
        # 显示查询信息
        query_text = self.search_results.query_text
        total_files = len(self.search_results.files)
        self.count_label.setText(f"查询: '{query_text}' | 共 {total_files} 个文件")
        
        # 添加查询信息作为根节点
        query_item = QTreeWidgetItem(self.search_tree)
        query_item.setText(0, f"🔍 查询: {query_text}")
        query_item.setText(1, f"{total_files}个结果")
        font = query_item.font(0)
        font.setBold(True)
        query_item.setFont(0, font)
        query_item.setForeground(0, QColor("#2196F3"))
        
        # 添加文件结果
        for file_result in self.search_results.files:
            file_item = QTreeWidgetItem(query_item)
            
            file_name = os.path.basename(file_result.file_path)
            similarity = file_result.similarity_score
            
            file_item.setText(0, f"📄 {file_name}")
            file_item.setText(1, f"{similarity:.1%}")
            file_item.setData(0, Qt.UserRole, "search_file")
            file_item.setData(0, Qt.UserRole + 1, file_result.file_path)
            
            # 设置提示信息
            tooltip_parts = [file_result.file_path]
            tooltip_parts.append(f"\n相似度: {similarity:.2%}")
            if file_result.matched_blocks:
                tooltip_parts.append(f"\n匹配的语义块: {len(file_result.matched_blocks)}个")
                for block in file_result.matched_blocks[:3]:  # 只显示前3个
                    tooltip_parts.append(f"  • {block.text_description[:50]}...")
            file_item.setToolTip(0, '\n'.join(tooltip_parts))
            
            # 根据相似度设置颜色
            if similarity >= 0.8:
                file_item.setForeground(1, QColor("#4CAF50"))
            elif similarity >= 0.5:
                file_item.setForeground(1, QColor("#FF9800"))
            else:
                file_item.setForeground(1, QColor("#F44336"))
            
            # 添加匹配的语义块信息（可选，折叠状态）
            for block in file_result.matched_blocks[:3]:  # 只显示前3个
                block_item = QTreeWidgetItem(file_item)
                block_item.setText(0, f"📝 {block.text_description[:40]}...")
                block_item.setText(1, f"{block.similarity_score:.1%}")
                block_item.setForeground(0, QColor("#666"))
        
        self.search_tree.expandAll()
    
    def show_search_context_menu(self, pos):
        """显示搜索结果的右键菜单"""
        item = self.search_tree.itemAt(pos)
        if not item:
            return
        
        item_type = item.data(0, Qt.UserRole)
        
        menu = QMenu(self)
        
        if item_type == "search_file":
            file_path = item.data(0, Qt.UserRole + 1)
            
            open_action = QAction("打开文件", self)
            open_action.triggered.connect(lambda: self.open_file(file_path))
            menu.addAction(open_action)
            
            open_folder_action = QAction("打开所在文件夹", self)
            open_folder_action.triggered.connect(lambda: self.open_folder(file_path))
            menu.addAction(open_folder_action)
            
            menu.addSeparator()
            
            copy_action = QAction("复制路径", self)
            copy_action.triggered.connect(lambda: self.copy_path(file_path))
            menu.addAction(copy_action)
        
        menu.exec_(self.search_tree.mapToGlobal(pos))
    
    def on_search_item_double_clicked(self, item, column):
        """双击搜索结果项目"""
        item_type = item.data(0, Qt.UserRole)
        
        if item_type == "search_file":
            file_path = item.data(0, Qt.UserRole + 1)
            self.file_selected.emit(file_path)
