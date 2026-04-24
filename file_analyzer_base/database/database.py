import os
import sqlite3
import json
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime
from enum import IntEnum


class FileStatus(IntEnum):
    """文件分析状态"""
    PENDING = 0  # 待处理（刚扫描入库）
    PARSED = 1  # 已解析（数据块已生成，保存到cache）
    PRELIMINARY = 2  # 初步分析（语义表征已生成）
    DEEP = 3  # 深入分析（全文文本索引）


class SpatiotemporalAnalysisStatus:
    """时空分析状态"""
    EMPTY = ""  # 非图片文件，默认为空
    PENDING = "待分析"  # 图片文件，初始化为待分析
    NOT_SUPPORTED = "不支持"  # 不支持的图片格式
    ANALYZED_NO_INFO = "已分析无信息"  # 支持但无信息
    ANALYZED_HAS_INFO = "已分析有信息"  # 提取到至少一个信息


class CaptionAnalysisStatus:
    """Caption打标状态"""
    EMPTY = ""  # 非图片文件，默认为空
    PENDING = "待分析"  # 图片文件，初始化为待分析
    NOT_SUPPORTED = "不支持"  # 不支持的图片格式
    ANALYZED_FAILED = "已分析不成功"  # caption和标签都没生成
    ANALYZED_HAS_INFO = "已分析有信息"  # 提取到至少一个


@dataclass
class FileRecord:
    """文件表记录"""
    id: int
    file_path: str
    file_name: str
    file_size: int
    file_type: str
    modified_time: datetime
    created_time: datetime
    analysis_status: FileStatus
    semantic_categories: List[Dict[str, Any]]  # [{"category": "技术文档", "confidence": 0.85}, ...]
    directory_path: str
    added_time: datetime
    semantic_filename: Optional[str] = None  # 语义文件名（用于搜索）
    metadata: Optional[Dict[str, Any]] = None  # 文件元数据（拍摄时间、地点、caption、tags等）
    spatiotemporal_analysis_status: str = ""  # 时空分析状态
    original_created_time: Optional[str] = None  # 原文件创建时间
    location: Optional[str] = None  # 地点
    caption_analysis_status: str = ""  # Caption打标状态


@dataclass
class DataBlockRecord:
    """数据块表记录"""
    id: int
    block_id: str
    file_id: int
    modality: str
    addr: Optional[str] = None  # 数据块文件路径（cache目录下）
    page_number: int = 1
    position: str = ""
    metadata: Dict[str, Any] = None
    created_time: datetime = None


@dataclass
class SemanticBlockRecord:
    """语义块表记录"""
    id: int
    semantic_block_id: str
    data_block_ids: List[int]  # 支持一个语义块关联多个数据块
    file_id: int
    text_description: str
    keywords: List[str]
    semantic_vector: bytes  # numpy array bytes
    created_time: datetime
    semantic_filename: Optional[str] = None  # 语义文件名
    metadata: Optional[Dict[str, Dict[str, float]]] = None  # {类别体系名: {类别名: 相似度}}


@dataclass
class SemanticCategoryRecord:
    """语义类别表记录"""
    id: int
    category_name: str
    description: str
    keywords: List[str]
    category_system_name: str  # 所属类别体系名称
    category_source: str  # 类别来源: 'predefined'(预定义), 'imported'(人工导入), 'generated'(随机生成)
    semantic_vector: Optional[bytes]  # 语义向量(numpy array bytes)
    created_time: datetime


@dataclass
class ClassificationResultRecord:
    """分类结果表记录"""
    id: int
    file_id: int
    semantic_block_id: str
    category_name: str
    category_system_name: str  # 使用的类别体系名称
    confidence: float
    all_scores: Dict[str, float]
    created_time: datetime


@dataclass
class UserQueryRecord:
    """用户查询表记录"""
    id: int
    query_text: str
    query_vector: Optional[bytes]
    keywords: List[str]
    top_k: int
    top_m: int
    result_count: int
    created_time: datetime


class DatabaseManager:
    """数据库管理器"""
    
    DEFAULT_DB_PATH = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'file_analyzer.db'
    )
    
    def __init__(self, db_path: Optional[str] = None):
        self.db_path = db_path or self.DEFAULT_DB_PATH
        self._conn: Optional[sqlite3.Connection] = None
        self._init_database()
    
    def _get_connection(self) -> sqlite3.Connection:
        """获取数据库连接"""
        if self._conn is None:
            self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
            self._conn.row_factory = sqlite3.Row
        return self._conn
    
    def _init_database(self):
        """初始化数据库表结构"""
        conn = self._get_connection()
        cursor = conn.cursor()

        # 文件表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_path TEXT UNIQUE NOT NULL,
                file_name TEXT NOT NULL,
                file_size INTEGER DEFAULT 0,
                file_type TEXT,
                modified_time TIMESTAMP,
                created_time TIMESTAMP,
                analysis_status INTEGER DEFAULT 0,
                semantic_categories TEXT,  -- JSON格式存储
                directory_path TEXT NOT NULL,
                added_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                semantic_filename TEXT,  -- 语义文件名（用于搜索）
                metadata TEXT,  -- 文件元数据（JSON格式，包含拍摄时间、地点、caption、tags等）
                spatiotemporal_analysis_status TEXT DEFAULT '',  -- 时空分析状态
                original_created_time TEXT,  -- 原文件创建时间
                location TEXT,  -- 地点
                caption_analysis_status TEXT DEFAULT ''  -- Caption打标状态
            )
        ''')
        
        # 数据块表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS data_blocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                block_id TEXT UNIQUE NOT NULL,
                file_id INTEGER NOT NULL,
                modality TEXT NOT NULL,
                addr TEXT,  -- 数据块文件路径（cache目录下）
                page_number INTEGER DEFAULT 1,
                position TEXT,
                metadata TEXT,  -- JSON格式存储
                created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
            )
        ''')
        
        # 语义块表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS semantic_blocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                semantic_block_id TEXT UNIQUE NOT NULL,
                data_block_ids TEXT,  -- JSON格式存储，支持一个语义块关联多个数据块
                file_id INTEGER NOT NULL,
                text_description TEXT,
                keywords TEXT,  -- JSON格式存储
                semantic_vector BLOB,  -- numpy array bytes
                created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                semantic_filename TEXT,  -- 语义文件名
                metadata TEXT,  -- JSON格式，存储类别相似度 {类别体系名: {类别名: 相似度}}
                FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
            )
        ''')
        
        # 语义类别表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS semantic_categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category_name TEXT NOT NULL,
                description TEXT,
                keywords TEXT,  -- JSON格式存储
                category_system_name TEXT DEFAULT '默认类别体系',
                category_source TEXT DEFAULT 'predefined',  -- 类别来源: predefined/imported/generated
                semantic_vector BLOB,  -- numpy array bytes，存储类别中心向量
                created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(category_name, category_system_name)
            )
        ''')

        # 分类结果表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS classification_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id INTEGER NOT NULL,
                semantic_block_id TEXT NOT NULL,
                category_name TEXT NOT NULL,
                category_system_name TEXT DEFAULT '默认类别体系',  -- 使用的类别体系名称
                confidence REAL DEFAULT 0.0,
                all_scores TEXT,  -- JSON格式存储
                created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
            )
        ''')
        
        # 用户查询表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS user_queries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query_text TEXT NOT NULL,
                query_vector BLOB,  -- numpy数组字节
                keywords TEXT,  -- JSON格式存储
                top_k INTEGER DEFAULT 10,
                top_m INTEGER DEFAULT 5,
                result_count INTEGER DEFAULT 0,
                created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # 创建索引
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_files_path ON files(file_path)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_files_status ON files(analysis_status)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_files_directory ON files(directory_path)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_data_blocks_file ON data_blocks(file_id)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_semantic_blocks_file ON semantic_blocks(file_id)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_classification_file ON classification_results(file_id)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_user_queries_time ON user_queries(created_time)')

        # 数据库迁移：添加缺失的列
        self._run_migrations(cursor)

        conn.commit()
        print(f"数据库初始化完成: {self.db_path}")

    def _run_migrations(self, cursor):
        """运行数据库迁移"""
        # 迁移1：semantic_categories表添加category_system_name、category_source和semantic_vector列
        try:
            cursor.execute("PRAGMA table_info(semantic_categories)")
            columns = [col[1] for col in cursor.fetchall()]

            if 'category_system_name' not in columns:
                cursor.execute("ALTER TABLE semantic_categories ADD COLUMN category_system_name TEXT DEFAULT '默认类别体系'")
                print("数据库迁移：添加semantic_categories.category_system_name列")

            if 'category_source' not in columns:
                cursor.execute("ALTER TABLE semantic_categories ADD COLUMN category_source TEXT DEFAULT 'predefined'")
                print("数据库迁移：添加semantic_categories.category_source列")

            if 'semantic_vector' not in columns:
                cursor.execute("ALTER TABLE semantic_categories ADD COLUMN semantic_vector BLOB")
                print("数据库迁移：添加semantic_categories.semantic_vector列")
        except Exception as e:
            print(f"数据库迁移警告: {e}")

    # ==================== 文件表操作 ====================
    
    def add_file(self, file_path: str, file_name: str, file_size: int = 0,
                 file_type: str = "", modified_time: Optional[datetime] = None,
                 created_time: Optional[datetime] = None, directory_path: str = "") -> int:
        """添加文件记录"""
        conn = self._get_connection()
        cursor = conn.cursor()

        # 判断是否是图片文件
        is_image = file_type.lower() in self.FILE_TYPE_EXTENSIONS.get('image', set())

        # 初始化时空分析和caption状态
        spatiotemporal_status = SpatiotemporalAnalysisStatus.PENDING if is_image else SpatiotemporalAnalysisStatus.EMPTY
        caption_status = CaptionAnalysisStatus.PENDING if is_image else CaptionAnalysisStatus.EMPTY

        try:
            cursor.execute('''
                INSERT OR IGNORE INTO files
                (file_path, file_name, file_size, file_type, modified_time, created_time,
                 analysis_status, semantic_categories, directory_path,
                 spatiotemporal_analysis_status, caption_analysis_status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                file_path, file_name, file_size, file_type,
                modified_time, created_time,
                FileStatus.PENDING.value, json.dumps([]), directory_path,
                spatiotemporal_status, caption_status
            ))
            conn.commit()

            cursor.execute('SELECT id FROM files WHERE file_path = ?', (file_path,))
            row = cursor.fetchone()
            return row['id'] if row else -1
        except Exception as e:
            print(f"添加文件失败: {e}")
            return -1
    
    def add_files_batch(self, files: List[Dict[str, Any]]) -> int:
        """批量添加文件"""
        conn = self._get_connection()
        cursor = conn.cursor()

        count = 0
        for file_info in files:
            try:
                file_type = file_info.get('file_type', '')
                # 判断是否是图片文件
                is_image = file_type.lower() in self.FILE_TYPE_EXTENSIONS.get('image', set())

                # 初始化时空分析和caption状态
                spatiotemporal_status = SpatiotemporalAnalysisStatus.PENDING if is_image else SpatiotemporalAnalysisStatus.EMPTY
                caption_status = CaptionAnalysisStatus.PENDING if is_image else CaptionAnalysisStatus.EMPTY

                cursor.execute('''
                    INSERT OR IGNORE INTO files
                    (file_path, file_name, file_size, file_type, modified_time, created_time,
                     analysis_status, semantic_categories, directory_path,
                     spatiotemporal_analysis_status, caption_analysis_status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    file_info['file_path'],
                    file_info['file_name'],
                    file_info.get('file_size', 0),
                    file_type,
                    file_info.get('modified_time'),
                    file_info.get('created_time'),
                    FileStatus.PENDING.value,
                    json.dumps([]),
                    file_info.get('directory_path', ''),
                    spatiotemporal_status,
                    caption_status
                ))
                count += 1
            except Exception as e:
                print(f"添加文件失败 {file_info.get('file_path')}: {e}")

        conn.commit()
        return count
    
    def get_file_by_path(self, file_path: str) -> Optional[FileRecord]:
        """根据路径获取文件"""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute('SELECT * FROM files WHERE file_path = ?', (file_path,))
        row = cursor.fetchone()
        
        if row:
            return self._row_to_file_record(row)
        return None
    
    def get_file_by_id(self, file_id: int) -> Optional[FileRecord]:
        """根据ID获取文件"""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute('SELECT * FROM files WHERE id = ?', (file_id,))
        row = cursor.fetchone()
        
        if row:
            return self._row_to_file_record(row)
        return None
    
    def get_files_by_status(self, status: FileStatus, directory_path: Optional[str] = None) -> List[FileRecord]:
        """根据状态获取文件列表"""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        if directory_path:
            cursor.execute('''
                SELECT * FROM files 
                WHERE analysis_status = ? AND directory_path = ?
                ORDER BY added_time
            ''', (status.value, directory_path))
        else:
            cursor.execute('''
                SELECT * FROM files 
                WHERE analysis_status = ?
                ORDER BY added_time
            ''', (status.value,))
        
        rows = cursor.fetchall()
        return [self._row_to_file_record(row) for row in rows]
    
    def get_files_by_directory(self, directory_path: str) -> List[FileRecord]:
        """获取目录下的所有文件"""
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM files
            WHERE directory_path = ?
            ORDER BY added_time
        ''', (directory_path,))

        rows = cursor.fetchall()
        return [self._row_to_file_record(row) for row in rows]

    # 文件类型到扩展名的映射
    FILE_TYPE_EXTENSIONS = {
        'image': {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.livp', '.ico', '.svg'},
        'video': {'.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.mpeg', '.mpg'},
        'audio': {'.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a', '.ape', '.opus'},
        'pdf': {'.pdf'},
        'document': {'.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.rtf', '.odt', '.ods', '.odp'},
        'archive': {'.zip', '.rar', '.7z', '.tar', '.gz', '.bz2'},
        'code': {'.py', '.js', '.java', '.c', '.cpp', '.h', '.cs', '.go', '.rs', '.ts', '.jsx', '.tsx', '.vue'},
    }

    def get_files_by_type(self, file_type: str) -> List[FileRecord]:
        """根据文件类型获取文件列表

        Args:
            file_type: 文件类型，如 'image', 'pdf', 'document' 等，或者直接使用扩展名如 '.jpg'

        Returns:
            文件记录列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        # 获取对应的扩展名列表
        extensions = self.FILE_TYPE_EXTENSIONS.get(file_type)

        if extensions:
            # 使用 IN 查询匹配多个扩展名
            placeholders = ','.join(['?' for _ in extensions])
            cursor.execute(f'''
                SELECT * FROM files
                WHERE file_type IN ({placeholders})
                ORDER BY added_time
            ''', list(extensions))
        else:
            # 如果不是预定义类型，尝试作为扩展名匹配
            # 确保扩展名以点开头
            ext = file_type if file_type.startswith('.') else f'.{file_type}'
            cursor.execute('''
                SELECT * FROM files
                WHERE file_type = ?
                ORDER BY added_time
            ''', (ext.lower(),))

        rows = cursor.fetchall()
        return [self._row_to_file_record(row) for row in rows]

    def update_file_status(self, file_id: int, status: FileStatus) -> bool:
        """更新文件分析状态"""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        try:
            cursor.execute('''
                UPDATE files SET analysis_status = ? WHERE id = ?
            ''', (status.value, file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新文件状态失败: {e}")
            return False
    
    def update_file_semantic_categories(self, file_id: int,
                                        categories: List[Dict[str, Any]]) -> bool:
        """更新文件语义类别"""
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE files SET semantic_categories = ? WHERE id = ?
            ''', (json.dumps(categories, ensure_ascii=False), file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新文件语义类别失败: {e}")
            return False

    def update_file_semantic_filename(self, file_id: int, semantic_filename: str) -> bool:
        """更新文件的语义文件名

        Args:
            file_id: 文件ID
            semantic_filename: 语义文件名

        Returns:
            是否更新成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE files SET semantic_filename = ? WHERE id = ?
            ''', (semantic_filename, file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新文件语义文件名失败: {e}")
            return False

    def update_file_metadata(self, file_id: int, metadata: Dict[str, Any]) -> bool:
        """更新文件元数据

        Args:
            file_id: 文件ID
            metadata: 元数据字典

        Returns:
            是否更新成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE files SET metadata = ? WHERE id = ?
            ''', (json.dumps(metadata, ensure_ascii=False), file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新文件元数据失败: {e}")
            return False

    def update_file_metadata_batch(self, updates: List[Tuple[int, Dict[str, Any]]]) -> int:
        """批量更新文件元数据

        Args:
            updates: [(file_id, metadata), ...] 列表

        Returns:
            更新成功的数量
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        count = 0

        try:
            for file_id, metadata in updates:
                cursor.execute('''
                    UPDATE files SET metadata = ? WHERE id = ?
                ''', (json.dumps(metadata, ensure_ascii=False), file_id))
                if cursor.rowcount > 0:
                    count += 1
            conn.commit()
        except Exception as e:
            print(f"批量更新文件元数据失败: {e}")
            conn.rollback()

        return count

    def update_spatiotemporal_status(self, file_id: int, status: str,
                                      original_created_time: Optional[str] = None,
                                      location: Optional[str] = None) -> bool:
        """更新时空分析状态及相关字段

        Args:
            file_id: 文件ID
            status: 状态值
            original_created_time: 原文件创建时间（可选）
            location: 地点（可选）

        Returns:
            是否更新成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE files
                SET spatiotemporal_analysis_status = ?,
                    original_created_time = COALESCE(?, original_created_time),
                    location = COALESCE(?, location)
                WHERE id = ?
            ''', (status, original_created_time, location, file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新时空分析状态失败: {e}")
            return False

    def update_caption_status(self, file_id: int, status: str) -> bool:
        """更新Caption分析状态

        Args:
            file_id: 文件ID
            status: 状态值

        Returns:
            是否更新成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE files SET caption_analysis_status = ? WHERE id = ?
            ''', (status, file_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新Caption分析状态失败: {e}")
            return False

    def get_files_by_spatiotemporal_status(self, status: str) -> List[FileRecord]:
        """根据时空分析状态获取文件列表

        Args:
            status: 状态值

        Returns:
            文件记录列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM files
            WHERE spatiotemporal_analysis_status = ?
            ORDER BY added_time
        ''', (status,))

        rows = cursor.fetchall()
        return [self._row_to_file_record(row) for row in rows]

    def get_files_by_caption_status(self, status: str) -> List[FileRecord]:
        """根据Caption分析状态获取文件列表

        Args:
            status: 状态值

        Returns:
            文件记录列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM files
            WHERE caption_analysis_status = ?
            ORDER BY added_time
        ''', (status,))

        rows = cursor.fetchall()
        return [self._row_to_file_record(row) for row in rows]

    def _row_to_file_record(self, row: sqlite3.Row) -> FileRecord:
        """将数据库行转换为FileRecord"""
        # 获取semantic_filename，如果列不存在则返回None
        try:
            semantic_filename = row['semantic_filename'] if 'semantic_filename' in row.keys() else None
        except (KeyError, IndexError):
            semantic_filename = None

        # 获取metadata，如果列不存在则返回None
        try:
            metadata_str = row['metadata'] if 'metadata' in row.keys() else None
            metadata = json.loads(metadata_str) if metadata_str else None
        except (KeyError, IndexError, json.JSONDecodeError):
            metadata = None

        # 获取新增字段
        try:
            spatiotemporal_analysis_status = row['spatiotemporal_analysis_status'] if 'spatiotemporal_analysis_status' in row.keys() else ''
        except (KeyError, IndexError):
            spatiotemporal_analysis_status = ''

        try:
            original_created_time = row['original_created_time'] if 'original_created_time' in row.keys() else None
        except (KeyError, IndexError):
            original_created_time = None

        try:
            location = row['location'] if 'location' in row.keys() else None
        except (KeyError, IndexError):
            location = None

        try:
            caption_analysis_status = row['caption_analysis_status'] if 'caption_analysis_status' in row.keys() else ''
        except (KeyError, IndexError):
            caption_analysis_status = ''

        return FileRecord(
            id=row['id'],
            file_path=row['file_path'],
            file_name=row['file_name'],
            file_size=row['file_size'],
            file_type=row['file_type'],
            modified_time=row['modified_time'],
            created_time=row['created_time'],
            analysis_status=FileStatus(row['analysis_status']),
            semantic_categories=json.loads(row['semantic_categories'] or '[]'),
            directory_path=row['directory_path'],
            added_time=row['added_time'],
            semantic_filename=semantic_filename,
            metadata=metadata,
            spatiotemporal_analysis_status=spatiotemporal_analysis_status,
            original_created_time=original_created_time,
            location=location,
            caption_analysis_status=caption_analysis_status
        )
    
    # ==================== 数据块表操作 ====================

    def add_data_block(self, block_id: str, file_id: int, modality: str,
                       addr: str = None, page_number: int = 1, position: str = "",
                       metadata: Optional[Dict[str, Any]] = None) -> int:
        """添加数据块

        Args:
            block_id: 数据块ID
            file_id: 文件ID
            modality: 模态类型
            addr: 数据块文件路径（cache目录下）
            page_number: 页码
            position: 位置信息（JSON字符串）
            metadata: 元数据

        Returns:
            插入记录的ID，失败返回-1
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                INSERT INTO data_blocks
                (block_id, file_id, modality, addr, page_number, position, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ''', (block_id, file_id, modality, addr,
                  page_number, position, json.dumps(metadata or {}, ensure_ascii=False)))
            conn.commit()
            return cursor.lastrowid
        except Exception as e:
            print(f"添加数据块失败: {e}")
            return -1

    def get_data_blocks_by_file(self, file_id: int) -> List[DataBlockRecord]:
        """获取文件的所有数据块"""
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM data_blocks WHERE file_id = ? ORDER BY page_number, id
        ''', (file_id,))

        rows = cursor.fetchall()
        return [self._row_to_data_block_record(row) for row in rows]

    def _row_to_data_block_record(self, row: sqlite3.Row) -> DataBlockRecord:
        """将数据库行转换为DataBlockRecord"""
        # 获取addr，如果列不存在则返回None
        try:
            addr = row['addr'] if 'addr' in row.keys() else None
        except (KeyError, IndexError):
            addr = None

        return DataBlockRecord(
            id=row['id'],
            block_id=row['block_id'],
            file_id=row['file_id'],
            modality=row['modality'],
            addr=addr,
            page_number=row['page_number'],
            position=row['position'],
            metadata=json.loads(row['metadata'] or '{}'),
            created_time=row['created_time']
        )
    
    # ==================== 语义块表操作 ====================
    
    def add_semantic_block(self, semantic_block_id: str, data_block_ids: List[int],
                           file_id: int, text_description: str = "",
                           keywords: Optional[List[str]] = None,
                           semantic_vector: Optional[bytes] = None,
                           semantic_filename: Optional[str] = None,
                           metadata: Optional[Dict[str, Dict[str, float]]] = None) -> int:
        """添加语义块

        Args:
            semantic_block_id: 语义块ID
            data_block_ids: 数据块ID列表，支持一个语义块关联多个数据块
            file_id: 文件ID
            text_description: 文本描述
            keywords: 关键词列表
            semantic_vector: 语义向量
            semantic_filename: 语义文件名
            metadata: 元数据，存储类别相似度 {类别体系名: {类别名: 相似度}}

        Returns:
            插入记录的ID，失败返回-1
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                INSERT INTO semantic_blocks
                (semantic_block_id, data_block_ids, file_id, text_description, keywords, semantic_vector, semantic_filename, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''', (semantic_block_id,
                  json.dumps(data_block_ids or [], ensure_ascii=False),
                  file_id, text_description,
                  json.dumps(keywords or [], ensure_ascii=False), semantic_vector, semantic_filename,
                  json.dumps(metadata, ensure_ascii=False) if metadata else None))
            conn.commit()
            return cursor.lastrowid
        except Exception as e:
            print(f"添加语义块失败: {e}")
            import traceback
            traceback.print_exc()
            return -1
    
    def get_semantic_blocks_by_file(self, file_id: int) -> List[SemanticBlockRecord]:
        """获取文件的所有语义块"""
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM semantic_blocks WHERE file_id = ? ORDER BY id
        ''', (file_id,))

        rows = cursor.fetchall()
        return [self._row_to_semantic_block_record(row) for row in rows]

    def update_semantic_block_metadata(self, semantic_block_id: str,
                                        metadata: Dict[str, Dict[str, float]]) -> bool:
        """更新语义块元数据

        Args:
            semantic_block_id: 语义块ID
            metadata: 元数据，存储类别相似度 {类别体系名: {类别名: 相似度}}

        Returns:
            成功返回True，失败返回False
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            metadata_json = json.dumps(metadata, ensure_ascii=False)
            cursor.execute('''
                UPDATE semantic_blocks SET metadata = ? WHERE semantic_block_id = ?
            ''', (metadata_json, semantic_block_id))
            conn.commit()
            return True
        except Exception as e:
            print(f"更新语义块元数据失败: {e}")
            import traceback
            traceback.print_exc()
            return False

    def add_data_blocks_batch(self, blocks: List[Dict[str, Any]]) -> int:
        """批量添加数据块 - 性能优化版本

        使用executemany和单次事务提交，比逐条插入快约50倍。

        Args:
            blocks: 数据块字典列表，每个字典包含:
                - block_id: 数据块ID
                - file_id: 文件ID
                - modality: 模态类型
                - addr: 数据块文件路径（cache目录下）
                - page_number: 页码
                - position: 位置信息(JSON字符串)
                - metadata: 元数据(JSON字符串)

        Returns:
            成功插入的记录数
        """
        if not blocks:
            return 0

        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            # 准备批量插入数据
            values = [
                (
                    b['block_id'],
                    b['file_id'],
                    b.get('modality', 'text'),
                    b.get('addr'),
                    b.get('page_number', 1),
                    b.get('position', '{}'),
                    b.get('metadata', '{}')
                )
                for b in blocks
            ]

            cursor.executemany('''
                INSERT INTO data_blocks
                (block_id, file_id, modality, addr, page_number, position, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ''', values)

            conn.commit()  # 只提交一次
            return cursor.rowcount
        except Exception as e:
            print(f"批量添加数据块失败: {e}")
            conn.rollback()
            return 0

    def add_semantic_blocks_batch(self, blocks: List[Dict[str, Any]]) -> int:
        """批量添加语义块 - 性能优化版本

        使用executemany和单次事务提交，比逐条插入快约50倍。

        Args:
            blocks: 语义块字典列表，每个字典包含:
                - semantic_block_id: 语义块ID
                - data_block_ids: 数据块ID列表
                - file_id: 文件ID
                - text_description: 文本描述
                - keywords: 关键词列表
                - semantic_vector: 语义向量(bytes)
                - semantic_filename: 语义文件名

        Returns:
            成功插入的记录数
        """
        if not blocks:
            return 0

        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            # 准备批量插入数据
            values = [
                (
                    b['semantic_block_id'],
                    json.dumps(b.get('data_block_ids', []), ensure_ascii=False),
                    b['file_id'],
                    b.get('text_description', ''),
                    json.dumps(b.get('keywords', []), ensure_ascii=False),
                    b.get('semantic_vector'),
                    b.get('semantic_filename')
                )
                for b in blocks
            ]

            cursor.executemany('''
                INSERT INTO semantic_blocks
                (semantic_block_id, data_block_ids, file_id, text_description, keywords, semantic_vector, semantic_filename)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ''', values)

            conn.commit()  # 只提交一次
            return cursor.rowcount
        except Exception as e:
            print(f"批量添加语义块失败: {e}")
            conn.rollback()
            return 0

    def add_classification_results_batch(self, results: List[Dict[str, Any]]) -> int:
        """批量添加分类结果 - 性能优化版本

        Args:
            results: 分类结果字典列表，每个字典包含:
                - file_id: 文件ID
                - semantic_block_id: 语义块ID
                - category_name: 类别名称
                - confidence: 置信度
                - all_scores: 所有分数字典

        Returns:
            成功插入的记录数
        """
        if not results:
            return 0

        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            values = [
                (
                    r['file_id'],
                    r['semantic_block_id'],
                    r['category_name'],
                    r.get('confidence', 0.0),
                    json.dumps(r.get('all_scores', {}), ensure_ascii=False)
                )
                for r in results
            ]

            cursor.executemany('''
                INSERT INTO classification_results
                (file_id, semantic_block_id, category_name, confidence, all_scores)
                VALUES (?, ?, ?, ?, ?)
            ''', values)

            conn.commit()
            return cursor.rowcount
        except Exception as e:
            print(f"批量添加分类结果失败: {e}")
            conn.rollback()
            return 0
    
    def _row_to_semantic_block_record(self, row: sqlite3.Row) -> SemanticBlockRecord:
        """将数据库行转换为SemanticBlockRecord"""
        # 解析data_block_ids（JSON格式）
        data_block_ids = json.loads(row['data_block_ids'] or '[]')

        # 获取semantic_filename，如果列不存在则返回None
        try:
            semantic_filename = row['semantic_filename'] if 'semantic_filename' in row.keys() else None
        except (KeyError, IndexError):
            semantic_filename = None

        # 解析metadata（JSON格式）
        metadata = None
        try:
            metadata_str = row['metadata'] if 'metadata' in row.keys() else None
            if metadata_str:
                metadata = json.loads(metadata_str)
        except (KeyError, IndexError, json.JSONDecodeError):
            metadata = None

        return SemanticBlockRecord(
            id=row['id'],
            semantic_block_id=row['semantic_block_id'],
            data_block_ids=data_block_ids,
            file_id=row['file_id'],
            text_description=row['text_description'],
            keywords=json.loads(row['keywords'] or '[]'),
            semantic_vector=row['semantic_vector'],
            created_time=row['created_time'],
            semantic_filename=semantic_filename,
            metadata=metadata
        )
    
    # ==================== 语义类别表操作 ====================
    
    def add_semantic_category(self, category_name: str, description: str = "",
                              keywords: Optional[List[str]] = None,
                              category_system_name: str = "默认类别体系",
                              category_source: str = "predefined",
                              semantic_vector: Optional[bytes] = None) -> int:
        """添加语义类别

        Args:
            category_name: 类别名称
            description: 类别描述
            keywords: 关键词列表
            category_system_name: 所属类别体系名称
            category_source: 类别来源 - 'predefined'(预定义), 'imported'(人工导入), 'generated'(随机生成)
            semantic_vector: 类别中心向量(numpy array bytes)

        Returns:
            类别ID
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                INSERT OR IGNORE INTO semantic_categories
                (category_name, description, keywords, category_system_name, category_source, semantic_vector)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (category_name, description, json.dumps(keywords or [], ensure_ascii=False),
                  category_system_name, category_source, semantic_vector))
            conn.commit()

            cursor.execute('SELECT id FROM semantic_categories WHERE category_name = ? AND category_system_name = ?',
                          (category_name, category_system_name))
            row = cursor.fetchone()
            return row['id'] if row else -1
        except Exception as e:
            print(f"添加语义类别失败: {e}")
            return -1
    
    def get_all_semantic_categories(self) -> List[SemanticCategoryRecord]:
        """获取所有语义类别"""
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT id, category_name, description, keywords, category_system_name,
                   category_source, semantic_vector, created_time
            FROM semantic_categories ORDER BY category_name
        ''')
        rows = cursor.fetchall()
        return [self._row_to_semantic_category_record(row) for row in rows]

    def get_semantic_categories_by_system(self, category_system_name: str) -> List[SemanticCategoryRecord]:
        """获取指定类别体系的语义类别

        Args:
            category_system_name: 类别体系名称

        Returns:
            该类别体系下的所有类别
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT id, category_name, description, keywords, category_system_name,
                   category_source, semantic_vector, created_time
            FROM semantic_categories
            WHERE category_system_name = ?
            ORDER BY category_name
        ''', (category_system_name,))
        rows = cursor.fetchall()
        return [self._row_to_semantic_category_record(row) for row in rows]

    def get_generated_categories_by_system(self, category_system_name: str) -> List[SemanticCategoryRecord]:
        """获取指定类别体系的随机生成类别

        Args:
            category_system_name: 类别体系名称

        Returns:
            该类别体系下的所有随机生成类别
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT id, category_name, description, keywords, category_system_name,
                   category_source, semantic_vector, created_time
            FROM semantic_categories
            WHERE category_system_name = ? AND category_source = 'generated'
            ORDER BY id
        ''', (category_system_name,))

        records = []
        for row in cursor.fetchall():
            records.append(SemanticCategoryRecord(
                id=row[0],
                category_name=row[1],
                description=row[2],
                keywords=json.loads(row[3]) if row[3] else [],
                category_system_name=row[4],
                category_source=row[5] or 'predefined',
                semantic_vector=row[6],
                created_time=datetime.fromisoformat(row[7]) if row[7] else datetime.now()
            ))
        return records

    def update_category_vector(self, category_id: int, semantic_vector: bytes) -> bool:
        """更新类别语义向量

        Args:
            category_id: 类别ID
            semantic_vector: 语义向量(numpy array bytes)

        Returns:
            是否更新成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                UPDATE semantic_categories SET semantic_vector = ? WHERE id = ?
            ''', (semantic_vector, category_id))
            conn.commit()
            return cursor.rowcount > 0
        except Exception as e:
            print(f"更新类别语义向量失败: {e}")
            return False

    def get_all_category_systems(self) -> Dict[str, List[SemanticCategoryRecord]]:
        """获取所有类别体系及其类别

        Returns:
            类别体系名称 -> 类别列表 的字典
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        # 获取所有不重复的类别体系名称
        cursor.execute('''
            SELECT DISTINCT category_system_name FROM semantic_categories
            ORDER BY category_system_name
        ''')
        system_names = [row['category_system_name'] for row in cursor.fetchall()]

        # 获取每个类别体系的类别
        result = {}
        for system_name in system_names:
            result[system_name] = self.get_semantic_categories_by_system(system_name)

        return result

    def delete_category_system(self, category_system_name: str) -> bool:
        """删除指定的类别体系

        Args:
            category_system_name: 类别体系名称

        Returns:
            是否删除成功
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            # 删除该类别体系下的所有类别
            cursor.execute('DELETE FROM semantic_categories WHERE category_system_name = ?',
                          (category_system_name,))
            deleted_count = cursor.rowcount
            conn.commit()
            print(f"已删除类别体系 '{category_system_name}'，共删除 {deleted_count} 个类别")
            return True
        except Exception as e:
            print(f"删除类别体系失败: {e}")
            conn.rollback()
            return False

    def _row_to_semantic_category_record(self, row: sqlite3.Row) -> SemanticCategoryRecord:
        """将数据库行转换为SemanticCategoryRecord"""
        # 兼容处理：如果列不存在则使用默认值
        try:
            category_source = row['category_source'] if 'category_source' in row.keys() else 'predefined'
        except (KeyError, IndexError):
            category_source = 'predefined'

        try:
            semantic_vector = row['semantic_vector'] if 'semantic_vector' in row.keys() else None
        except (KeyError, IndexError):
            semantic_vector = None

        return SemanticCategoryRecord(
            id=row['id'],
            category_name=row['category_name'],
            description=row['description'],
            keywords=json.loads(row['keywords'] or '[]'),
            category_system_name=row['category_system_name'] or '默认类别体系',
            category_source=category_source or 'predefined',
            semantic_vector=semantic_vector,
            created_time=row['created_time']
        )
    
    # ==================== 分类结果表操作 ====================
    
    def add_classification_result(self, file_id: int, semantic_block_id: str,
                                  category_name: str, confidence: float = 0.0,
                                  all_scores: Optional[Dict[str, float]] = None,
                                  category_system_name: str = "默认类别体系") -> int:
        """添加分类结果

        Args:
            file_id: 文件ID
            semantic_block_id: 语义块ID
            category_name: 类别名称
            confidence: 置信度
            all_scores: 所有类别得分
            category_system_name: 使用的类别体系名称

        Returns:
            分类结果ID
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('''
                INSERT INTO classification_results
                (file_id, semantic_block_id, category_name, category_system_name, confidence, all_scores)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (file_id, semantic_block_id, category_name, category_system_name, confidence,
                  json.dumps(all_scores or {}, ensure_ascii=False)))
            conn.commit()
            return cursor.lastrowid
        except Exception as e:
            print(f"添加分类结果失败: {e}")
            return -1
    
    def get_classification_results_by_file(self, file_id: int,
                                           category_system_name: str = None) -> List[ClassificationResultRecord]:
        """获取文件的分类结果

        Args:
            file_id: 文件ID
            category_system_name: 可选，按类别体系筛选

        Returns:
            分类结果列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        if category_system_name:
            cursor.execute('''
                SELECT * FROM classification_results
                WHERE file_id = ? AND category_system_name = ?
                ORDER BY confidence DESC
            ''', (file_id, category_system_name))
        else:
            cursor.execute('''
                SELECT * FROM classification_results WHERE file_id = ? ORDER BY confidence DESC
            ''', (file_id,))

        rows = cursor.fetchall()
        return [self._row_to_classification_result_record(row) for row in rows]

    def get_classification_results_by_system(self, category_system_name: str) -> List[ClassificationResultRecord]:
        """获取指定类别体系的所有分类结果

        Args:
            category_system_name: 类别体系名称

        Returns:
            分类结果列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        cursor.execute('''
            SELECT * FROM classification_results
            WHERE category_system_name = ?
            ORDER BY created_time DESC
        ''', (category_system_name,))

        rows = cursor.fetchall()
        return [self._row_to_classification_result_record(row) for row in rows]
    
    def _row_to_classification_result_record(self, row: sqlite3.Row) -> ClassificationResultRecord:
        """将数据库行转换为ClassificationResultRecord"""
        return ClassificationResultRecord(
            id=row['id'],
            file_id=row['file_id'],
            semantic_block_id=row['semantic_block_id'],
            category_name=row['category_name'],
            category_system_name=row['category_system_name'] or '默认类别体系',
            confidence=row['confidence'],
            all_scores=json.loads(row['all_scores'] or '{}'),
            created_time=row['created_time']
        )
    
    # ==================== 其他操作 ====================
    
    def clear_directory_files(self, directory_path: str) -> int:
        """清空目录下的所有文件记录（级联删除相关数据）"""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        try:
            cursor.execute('DELETE FROM files WHERE directory_path = ?', (directory_path,))
            conn.commit()
            return cursor.rowcount
        except Exception as e:
            print(f"清空目录文件失败: {e}")
            return 0
    
    def clear_all_data(self) -> bool:
        """清空所有数据表（保留表结构）
        
        Returns:
            是否成功清空
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        
        try:
            # 清空所有数据表（按照外键依赖顺序）
            tables = [
                'user_queries',
                'classification_results',
                'semantic_blocks',
                'data_blocks',
                'files',
                'semantic_categories'
            ]
            
            for table in tables:
                cursor.execute(f'DELETE FROM {table}')
                print(f"已清空表: {table}")
            
            conn.commit()
            print("所有数据表已清空")
            return True
        except Exception as e:
            print(f"清空数据表失败: {e}")
            conn.rollback()
            return False

    def clear_classification_results(self) -> bool:
        """清空分类结果表

        Returns:
            是否成功清空
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute('DELETE FROM classification_results')
            deleted_count = cursor.rowcount
            conn.commit()
            print(f"已清空分类结果表，删除 {deleted_count} 条记录")
            return True
        except Exception as e:
            print(f"清空分类结果表失败: {e}")
            conn.rollback()
            return False

    def clear_all_data_except_categories(self) -> bool:
        """清空除类别表外的所有数据表（保留类别体系）

        Returns:
            是否成功清空
        """
        conn = self._get_connection()
        cursor = conn.cursor()

        try:
            # 清空数据表（按照外键依赖顺序，保留semantic_categories）
            tables = [
                'user_queries',
                'classification_results',
                'semantic_blocks',
                'data_blocks',
                'files',
            ]

            for table in tables:
                cursor.execute(f'DELETE FROM {table}')
                print(f"已清空表: {table}")

            conn.commit()
            print("已清空除类别表外的所有数据表")
            return True
        except Exception as e:
            print(f"清空数据表失败: {e}")
            conn.rollback()
            return False

    # ==================== 用户查询表操作 ====================
    
    def add_user_query(self, query_text: str, query_vector: Optional[bytes] = None,
                       keywords: Optional[List[str]] = None, top_k: int = 10,
                       top_m: int = 5, result_count: int = 0) -> int:
        """添加用户查询记录
        
        Args:
            query_text: 查询文本
            query_vector: 查询向量
            keywords: 关键词列表
            top_k: 检索的语义块数量
            top_m: 返回的文件数量
            result_count: 实际返回结果数量
            
        Returns:
            插入记录的ID
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        
        try:
            cursor.execute('''
                INSERT INTO user_queries 
                (query_text, query_vector, keywords, top_k, top_m, result_count)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (query_text, query_vector, json.dumps(keywords or [], ensure_ascii=False),
                  top_k, top_m, result_count))
            conn.commit()
            return cursor.lastrowid
        except Exception as e:
            print(f"添加用户查询记录失败: {e}")
            return -1
    
    def get_user_queries(self, limit: int = 100) -> List[UserQueryRecord]:
        """获取用户查询历史
        
        Args:
            limit: 返回记录数量限制
            
        Returns:
            用户查询记录列表
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT * FROM user_queries 
            ORDER BY created_time DESC
            LIMIT ?
        ''', (limit,))
        
        rows = cursor.fetchall()
        return [self._row_to_user_query_record(row) for row in rows]
    
    def _row_to_user_query_record(self, row: sqlite3.Row) -> UserQueryRecord:
        """将数据库行转换为UserQueryRecord"""
        return UserQueryRecord(
            id=row['id'],
            query_text=row['query_text'],
            query_vector=row['query_vector'],
            keywords=json.loads(row['keywords'] or '[]'),
            top_k=row['top_k'],
            top_m=row['top_m'],
            result_count=row['result_count'],
            created_time=row['created_time']
        )
    
    def close(self):
        """关闭数据库连接"""
        if self._conn:
            self._conn.close()
            self._conn = None
    
    def __enter__(self):
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
