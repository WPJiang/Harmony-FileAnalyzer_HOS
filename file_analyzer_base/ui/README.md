# 文件分析管理器 - UI模块说明文档

## 目录

1. [模块概述](#模块概述)
2. [功能特性](#功能特性)
3. [界面布局](#界面布局)
4. [组件说明](#组件说明)
5. [使用指南](#使用指南)
6. [API接口](#api接口)
7. [配置说明](#配置说明)
8. [常见问题](#常见问题)

---

## 模块概述

UI模块为文件分析工程提供Windows桌面应用程序界面，基于PyQt5框架开发，提供直观的文件管理、预览和语义分析功能。

### 技术栈

- **GUI框架**: PyQt5
- **设计语言**: Material Design风格
- **架构模式**: 组件化设计，信号槽机制
- **线程处理**: 后台扫描线程，避免UI阻塞

---

## 功能特性

### 核心功能

| 功能模块 | 描述 | 状态 |
|---------|------|------|
| 文件浏览 | 树形列表展示文件，支持排序和筛选 | ✓ |
| 文件预览 | 支持图片、文本、PDF、Word、音频预览 | ✓ |
| 智能推荐 | 基于文件类型和修改时间的智能推荐 | ✓ |
| 目录扫描 | 集成目录扫描模块，支持Windows特殊目录 | ✓ |
| 搜索功能 | 实时搜索，支持历史记录和自动完成 | ✓ |
| 快速导航 | 快速跳转到桌面、下载、文档等目录 | ✓ |

### 支持的文件格式

#### 预览支持

| 类型 | 格式 | 预览方式 |
|-----|------|---------|
| 图片 | JPG, JPEG, PNG, GIF, BMP | 直接显示 |
| 文本 | TXT, MD, PY, JSON, XML, HTML, CSS, JS | 文本显示 |
| PDF | PDF | 提示信息 |
| Word | DOC, DOCX | 提示信息 |
| 音频 | MP3, WAV, M4A, FLAC | 提示信息 |

#### 浏览支持

- 文档: PDF, DOC, DOCX, PPT, PPTX, XLS, XLSX, TXT, MD
- 图片: JPG, JPEG, PNG, GIF, BMP
- 音频: MP3, WAV, M4A, FLAC
- 视频: MP4, AVI
- 压缩: ZIP, RAR, 7Z
- 其他: EXE, DLL等

---

## 界面布局

### 主窗口布局

```
┌─────────────────────────────────────────────────────────────┐
│  菜单栏: 文件 | 视图 | 工具 | 帮助                          │
├─────────────────────────────────────────────────────────────┤
│  工具栏: [←后退] [主页] [刷新] [快速跳转 ▼]                 │
├─────────────────────────────────────────────────────────────┤
│  [搜索面板]                                                 │
│  📁 位置: [目录输入框____________] [浏览...] [快速目录 ▼]   │
│  🔍 搜索: [搜索输入框____________] [搜索] [清除]            │
│  文件类型: [全部类型 ▼]  搜索历史: [历史记录 ▼]             │
├──────────────────┬─────────────────────┬────────────────────┤
│                  │                     │                    │
│  [文件浏览器]    │   [预览窗口]        │  [推荐窗口]        │
│  ┌────────────┐  │   ┌─────────────┐   │  ┌─────────────┐  │
│  │ 📄文件1.pdf│  │   │             │   │  │ ⭐智能推荐  │  │
│  │ 🖼️图片.jpg │  │   │   预览内容   │   │  │ 最近修改    │  │
│  │ 🎵音乐.mp3 │  │   │             │   │  │ - file1.pdf │  │
│  │ ...        │  │   │             │   │  │ - file2.jpg │  │
│  └────────────┘  │   └─────────────┘   │  │             │  │
│                  │                     │  │ PDF文档     │  │
│  共 150 个文件   │                     │  │ - doc1.pdf  │  │
│                  │                     │  │ - doc2.pdf  │  │
│                  │                     │  │             │  │
├──────────────────┴─────────────────────┴────────────────────┤
│  状态栏: 就绪 | 文件: 150 | 选中: report.pdf                │
└─────────────────────────────────────────────────────────────┘
```

### 组件尺寸

| 组件 | 默认宽度 | 最小宽度 | 说明 |
|-----|---------|---------|------|
| 文件浏览器 | 400px | 250px | 左侧，可调整 |
| 预览窗口 | 500px | 350px | 中间，可调整 |
| 推荐窗口 | 400px | 250px | 右侧，可调整 |
| 主窗口 | 1400px | 1000px | 初始尺寸 |

---

## 组件说明

### 1. 主窗口 (MainWindow)

**文件**: `main_window.py`

**职责**:
- 窗口管理和布局协调
- 菜单栏和工具栏处理
- 组件间通信协调
- 后台扫描任务管理

**核心方法**:

| 方法 | 功能 |
|-----|------|
| `load_directory(directory)` | 加载指定目录 |
| `scan_default_directories()` | 扫描默认目录 |
| `refresh_current_view()` | 刷新当前视图 |
| `navigate_up()` | 返回上级目录 |
| `go_home()` | 返回主页 |

**信号连接**:

```python
# 文件浏览器信号
file_browser.file_selected.connect(on_file_selected)
file_browser.directory_double_clicked.connect(on_directory_double_clicked)

# 搜索面板信号
search_panel.search_requested.connect(on_search)
search_panel.directory_changed.connect(on_directory_changed)

# 推荐面板信号
recommendation_panel.recommendation_selected.connect(on_recommendation_selected)
```

---

### 2. 文件浏览器 (FileBrowser)

**文件**: `file_browser.py`

**职责**:
- 文件列表展示
- 文件排序和筛选
- 右键菜单处理
- 文件选择事件

**功能特性**:

- **视图模式**: 列表视图 / 详细视图
- **排序方式**: 名称、大小、类型、修改时间
- **筛选功能**: 实时文件名筛选
- **右键菜单**: 打开、打开所在文件夹、复制路径、属性
- **文件颜色**: 按类型显示不同颜色

**颜色标识**:

| 文件类型 | 颜色 |
|---------|------|
| PDF | 红色 (#e74c3c) |
| Word | 绿色 (#2ecc71) |
| PowerPoint | 橙色 (#e67e22) |
| 图片 | 紫色 (#9b59b6) |
| 音频 | 蓝色 (#3498db) |
| 其他 | 灰色 (#95a5a6) |

**核心方法**:

| 方法 | 功能 |
|-----|------|
| `set_files(files)` | 设置文件列表 |
| `refresh_tree()` | 刷新树形列表 |
| `select_file(file_path)` | 选中指定文件 |
| `set_view_mode(mode)` | 设置视图模式 |
| `get_selected_file()` | 获取选中文件 |

---

### 3. 预览窗口 (PreviewPanel)

**文件**: `preview_panel.py`

**职责**:
- 文件内容预览
- 预览类型切换
- 后台加载处理

**预览类型**:

| 类型 | 处理方式 | 说明 |
|-----|---------|------|
| 图片 | 直接显示 | 自动缩放适应窗口 |
| 文本 | 文本显示 | 限制10KB预览大小 |
| PDF | 完整预览 | 支持翻页、缩放、保留样式 |
| Word | 完整预览 | 保留样式、段落、表格 |
| Excel | 完整预览 | 支持多工作表切换 |
| PowerPoint | 完整预览 | 支持翻页、保留幻灯片结构 |
| 音频 | 提示页面 | 显示音频图标和播放按钮 |
| 其他 | 不支持页面 | 提示使用外部程序打开 |

**PDF预览功能**:
- 支持翻页（上一页/下一页按钮）
- 支持缩放（50%-300%，支持按钮和快捷键）
- 显示页码和页面尺寸信息
- 保留原始文档样式和布局

**Word预览功能**:
- 保留段落样式（标题、正文等）
- 支持文本格式（粗体、斜体、下划线）
- 支持表格显示
- 使用HTML渲染保留样式

**Excel预览功能**:
- 支持多工作表切换
- 表格形式显示数据
- 显示行列信息
- 自动调整列宽

**PowerPoint预览功能**:
- 支持翻页（上一页/下一页按钮）
- 显示幻灯片标题和内容
- 保留列表结构
- 使用HTML渲染保留样式

**核心方法**:

| 方法 | 功能 |
|-----|------|
| `preview_file(file_path)` | 预览指定文件 |
| `show_image_preview(pixmap)` | 显示图片预览 |
| `show_text_preview(content)` | 显示文本预览 |
| `show_pdf_preview()` | 显示PDF预览 |
| `show_word_preview()` | 显示Word预览 |
| `show_excel_preview()` | 显示Excel预览 |
| `show_ppt_preview()` | 显示PowerPoint预览 |
| `open_current_file()` | 使用默认程序打开 |
| `clear_preview()` | 清除预览 |

**依赖库**:
- `PyMuPDF` (fitz): PDF文档渲染
- `python-docx`: Word文档解析
- `python-pptx`: PowerPoint文档解析
- `openpyxl`: Excel文档解析

---

### 4. 推荐窗口 (RecommendationPanel)

**文件**: `recommendation_panel.py`

**职责**:
- 智能推荐展示
- 推荐分类管理
- 推荐项点击处理

**推荐类型**:

| 类型 | 说明 |
|-----|------|
| 最近修改 | 最近修改的5个文件 |
| 按类型分组 | PDF文档、图片、音频等分类 |

**核心方法**:

| 方法 | 功能 |
|-----|------|
| `set_recommendations(recommendations)` | 设置推荐内容 |
| `refresh_display()` | 刷新显示 |
| `add_recommendation(title, files, type)` | 添加推荐 |
| `clear()` | 清除推荐 |

---

### 5. 搜索面板 (SearchPanel)

**文件**: `search_panel.py`

**职责**:
- 目录选择和输入
- 搜索关键词输入
- 搜索历史管理
- 文件类型筛选

**功能特性**:

- **目录输入**: 手动输入或浏览选择
- **快速目录**: 桌面、下载、文档、图片、视频、音乐
- **搜索历史**: 自动保存最近10条搜索记录
- **自动完成**: 基于历史记录的自动完成
- **文件类型筛选**: 全部、文档、图片、音频、文本

**核心方法**:

| 方法 | 功能 |
|-----|------|
| `browse_directory()` | 浏览目录 |
| `set_quick_directory(dir_type)` | 设置快速目录 |
| `on_search()` | 执行搜索 |
| `add_to_history(query)` | 添加到历史 |
| `set_directory(directory)` | 设置当前目录 |
| `focus_search()` | 聚焦搜索框 |

---

## 使用指南

### 启动应用

#### 方式1: 使用启动器

```bash
cd d:\jiangweipeng\trae_code
python file_analyzer\ui\launcher.py
```

#### 方式2: 使用模块入口

```bash
python -c "from file_analyzer import launch_ui; launch_ui()"
```

#### 方式3: 直接运行主窗口

```bash
python file_analyzer\ui\main_window.py
```

### 基本操作流程

1. **选择目录**
   - 点击"浏览..."按钮选择目录
   - 或使用"快速目录"菜单选择常用目录
   - 直接在位置输入框输入路径

2. **浏览文件**
   - 在左侧文件浏览器查看文件列表
   - 点击表头进行排序
   - 使用筛选框过滤文件
   - 双击目录进入子目录

3. **预览文件**
   - 点击文件在预览窗口查看
   - 图片文件直接显示
   - 文本文件显示内容
   - 其他文件显示提示信息

4. **搜索文件**
   - 在搜索框输入关键词
   - 按Enter或点击搜索按钮
   - 使用文件类型筛选缩小范围

5. **查看推荐**
   - 在右侧推荐窗口查看智能推荐
   - 点击推荐项快速定位文件

### 快捷键

| 快捷键 | 功能 |
|-------|------|
| Ctrl+O | 打开目录 |
| Ctrl+D | 扫描默认目录 |
| F5 | 刷新 |
| Ctrl+Q | 退出 |

---

## API接口

### 主窗口接口

```python
from file_analyzer.ui import MainWindow

# 创建窗口
window = MainWindow()

# 加载目录
window.load_directory('C:\\Users\\User\\Documents')

# 扫描默认目录
window.scan_default_directories()

# 刷新视图
window.refresh_current_view()
```

### 文件浏览器接口

```python
from file_analyzer.ui import FileBrowser

# 创建浏览器
browser = FileBrowser()

# 设置文件列表
browser.set_files(['file1.pdf', 'file2.jpg'])

# 设置视图模式
browser.set_view_mode('list')  # 或 'detail'

# 获取选中文件
selected = browser.get_selected_file()
```

### 预览窗口接口

```python
from file_analyzer.ui import PreviewPanel

# 创建预览面板
preview = PreviewPanel()

# 预览文件
preview.preview_file('C:\\file.pdf')

# 清除预览
preview.clear()
```

### 搜索面板接口

```python
from file_analyzer.ui import SearchPanel

# 创建搜索面板
search = SearchPanel()

# 设置目录
search.set_directory('C:\\Users\\User')

# 获取搜索关键词
query = search.get_search_query()

# 聚焦搜索框
search.focus_search()
```

---

## 配置说明

### 配置文件位置

```
~/.file_analyzer/scanner_config.json
```

### UI相关配置项

```json
{
  "default_directories": {
    "desktop": true,
    "downloads": true,
    "documents": true,
    "pictures": true,
    "videos": false,
    "music": false
  },
  "custom_directories": [],
  "include_patterns": [
    "*.pdf", "*.doc", "*.docx", "*.ppt", "*.pptx",
    "*.txt", "*.md", "*.jpg", "*.jpeg", "*.png",
    "*.gif", "*.bmp", "*.mp3", "*.wav", "*.m4a"
  ],
  "exclude_patterns": [
    "*.tmp", "*.temp", "~$*", "*.log",
    "Thumbs.db", ".DS_Store"
  ],
  "max_depth": 3,
  "include_system_dirs": false
}
```

### 配置说明

| 配置项 | 类型 | 默认值 | 说明 |
|-------|------|-------|------|
| default_directories | dict | {...} | 默认目录开关 |
| custom_directories | list | [] | 自定义目录列表 |
| include_patterns | list | [...] | 包含的文件类型 |
| exclude_patterns | list | [...] | 排除的文件模式 |
| max_depth | int | 3 | 最大扫描深度 |
| include_system_dirs | bool | false | 是否包含系统目录 |

---

## 常见问题

### Q: 无法启动UI，提示缺少PyQt5

**A**: 安装PyQt5依赖：
```bash
pip install PyQt5
```

### Q: 预览PDF或Word文档时显示"需要额外的解析库"

**A**: 当前版本使用系统默认程序打开这些文件。如需内置预览，需要安装额外的解析库：
```bash
pip install PyMuPDF  # PDF解析
pip install python-docx  # Word解析
```

### Q: 如何添加自定义扫描目录？

**A**: 两种方式：
1. 在配置文件中添加 `custom_directories` 列表
2. 在代码中使用 `DirectoryScanner.add_custom_directory(path)`

### Q: 扫描大目录时UI卡顿

**A**: 扫描操作在后台线程执行，不会阻塞UI。如果仍感觉卡顿，可以：
1. 减小 `max_depth` 配置值
2. 使用 `exclude_patterns` 排除大文件
3. 分批扫描子目录

### Q: 如何修改界面主题颜色？

**A**: 修改各组件的 `setStyleSheet()` 方法中的颜色值。主色调定义在 `main_window.py` 中：
```python
# 主色调: #2196F3 (蓝色)
# 悬停色: #1976D2
# 按下色: #0D47A1
```

### Q: 支持哪些操作系统？

**A**: 当前主要支持Windows系统，使用Windows API获取特殊目录路径。Linux/Mac需要修改 `get_windows_special_folder()` 方法。

---

## 更新日志

### v1.0.0

- 初始版本发布
- 实现文件浏览器、预览窗口、推荐窗口、搜索面板
- 集成目录扫描模块
- 支持Windows特殊目录快速导航
- 实现后台扫描线程

---

## 开发计划

- [ ] 添加文件拖拽支持
- [ ] 实现PDF内置预览
- [ ] 实现Word内置预览
- [ ] 添加音频播放功能
- [ ] 支持缩略图显示
- [ ] 添加批量操作功能
- [ ] 实现主题切换
- [ ] 支持多语言

---

## 技术支持

如有问题或建议，请参考主项目文档或提交Issue。
