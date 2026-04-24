import os
import json
import glob
from typing import List, Optional, Dict, Any
from dataclasses import dataclass, field, asdict
from pathlib import Path
from enum import Enum
from datetime import datetime

import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from logger import processing_logger


class DirectoryType(Enum):
    DESKTOP = "desktop"
    DOWNLOADS = "downloads"
    DOCUMENTS = "documents"
    PICTURES = "pictures"
    VIDEOS = "videos"
    MUSIC = "music"
    CUSTOM = "custom"


@dataclass
class ScanConfig:
    include_system_dirs: bool = False
    max_depth: int = 3
    follow_symlinks: bool = False
    exclude_patterns: List[str] = field(default_factory=list)
    include_patterns: List[str] = field(default_factory=lambda: [
        '*.pdf', '*.doc', '*.docx', '*.ppt', '*.pptx', 
        '*.txt', '*.md', '*.json', '*.xml', '*.csv',
        '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.tiff', '*.webp',
        '*.wav', '*.mp3', '*.m4a', '*.flac', '*.ogg', '*.aac'
    ])
    default_directories: Dict[str, bool] = field(default_factory=lambda: {
        'desktop': True,
        'downloads': True,
        'documents': True,
        'pictures': True,
        'videos': False,
        'music': False
    })
    custom_directories: List[str] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'ScanConfig':
        return cls(**data)


class DirectoryScanner:
    WINDOWS_SYSTEM_DIRS = [
        'C:\\Windows',
        'C:\\Program Files',
        'C:\\Program Files (x86)',
        'C:\\ProgramData',
        'C:\\$Recycle.Bin',
        'C:\\System Volume Information',
    ]
    
    def __init__(self, config_path: Optional[str] = None):
        self.config_path = config_path or self._get_default_config_path()
        self.config = self._load_config()
    
    def _get_default_config_path(self) -> str:
        home_dir = Path.home()
        config_dir = home_dir / '.file_analyzer'
        config_dir.mkdir(exist_ok=True)
        return str(config_dir / 'scanner_config.json')
    
    def _load_config(self) -> ScanConfig:
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                return ScanConfig.from_dict(data)
            except Exception as e:
                print(f"Failed to load config: {e}, using default config")
                return ScanConfig()
        return ScanConfig()
    
    def save_config(self):
        try:
            config_dir = os.path.dirname(self.config_path)
            if config_dir:
                os.makedirs(config_dir, exist_ok=True)
            
            with open(self.config_path, 'w', encoding='utf-8') as f:
                json.dump(self.config.to_dict(), f, indent=2, ensure_ascii=False)
            return True
        except Exception as e:
            print(f"Failed to save config: {e}")
            return False
    
    def get_windows_special_folder(self, folder_type: DirectoryType) -> Optional[str]:
        """获取 Windows 特殊文件夹路径"""
        try:
            import ctypes
            from ctypes import wintypes
            
            # 使用 KNOWNFOLDERID (更现代的方法，支持 Win7+)
            # 或者使用正确的 CSIDL 值
            knownfolderid_map = {
                DirectoryType.DESKTOP: '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}',
                DirectoryType.DOWNLOADS: '{374DE290-123F-4565-9164-39C4925E467B}',
                DirectoryType.DOCUMENTS: '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}',
                DirectoryType.PICTURES: '{33E28130-4E1E-4676-835A-98395C3BC3BB}',
                DirectoryType.VIDEOS: '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}',
                DirectoryType.MUSIC: '{4BD8D571-6D19-48D3-BE97-422220080E43}',
            }
            
            if folder_type in knownfolderid_map:
                guid = knownfolderid_map[folder_type]
                
                # 使用 SHGetKnownFolderPath
                class GUID(ctypes.Structure):
                    _fields_ = [
                        ("Data1", wintypes.DWORD),
                        ("Data2", wintypes.WORD),
                        ("Data3", wintypes.WORD),
                        ("Data4", wintypes.BYTE * 8)
                    ]
                
                # 解析 GUID 字符串
                import uuid
                g = uuid.UUID(guid)
                
                guid_struct = GUID()
                guid_struct.Data1 = g.time_low
                guid_struct.Data2 = g.time_mid
                guid_struct.Data3 = g.time_hi_version
                guid_struct.Data4 = (wintypes.BYTE * 8)(*g.bytes[8:16])
                
                ptr = ctypes.c_wchar_p()
                result = ctypes.windll.shell32.SHGetKnownFolderPath(
                    ctypes.byref(guid_struct),
                    0,
                    None,
                    ctypes.byref(ptr)
                )
                
                if result == 0 and ptr.value:
                    path = ptr.value
                    ctypes.windll.ole32.CoTaskMemFree(ptr)
                    if os.path.exists(path):
                        return path
                        
        except Exception as e:
            print(f"KNOWNFOLDERID 方法失败: {e}")
            pass
        
        # 回退到 CSIDL 方法
        try:
            import ctypes
            from ctypes import wintypes
            
            csidl_map = {
                DirectoryType.DESKTOP: 0x0010,      # CSIDL_DESKTOP
                DirectoryType.DOCUMENTS: 0x0005,     # CSIDL_PERSONAL
                DirectoryType.PICTURES: 0x0027,      # CSIDL_MYPICTURES
                DirectoryType.MUSIC: 0x000d,         # CSIDL_MYMUSIC
            }
            
            if folder_type in csidl_map:
                csidl = csidl_map[folder_type]
                
                buf = ctypes.create_unicode_buffer(wintypes.MAX_PATH)
                ctypes.windll.shell32.SHGetFolderPathW(None, csidl, None, 0, buf)
                
                path = buf.value
                if path and os.path.exists(path):
                    return path
                    
        except Exception as e:
            print(f"CSIDL 方法失败: {e}")
            pass
        
        # 最后回退到环境变量方法
        env_map = {
            DirectoryType.DESKTOP: 'USERPROFILE',
            DirectoryType.DOWNLOADS: 'USERPROFILE',
            DirectoryType.DOCUMENTS: 'USERPROFILE',
            DirectoryType.PICTURES: 'USERPROFILE',
            DirectoryType.VIDEOS: 'USERPROFILE',
            DirectoryType.MUSIC: 'USERPROFILE',
        }
        
        if folder_type in env_map:
            base_path = os.environ.get(env_map[folder_type])
            if base_path:
                folder_names = {
                    DirectoryType.DESKTOP: 'Desktop',
                    DirectoryType.DOWNLOADS: 'Downloads',
                    DirectoryType.DOCUMENTS: 'Documents',
                    DirectoryType.PICTURES: 'Pictures',
                    DirectoryType.VIDEOS: 'Videos',
                    DirectoryType.MUSIC: 'Music',
                }
                path = os.path.join(base_path, folder_names.get(folder_type, ''))
                if os.path.exists(path):
                    return path
        
        return None
    
    def get_default_scan_directories(self) -> List[str]:
        directories = []
        
        for dir_name, enabled in self.config.default_directories.items():
            if enabled:
                try:
                    dir_type = DirectoryType(dir_name)
                    path = self.get_windows_special_folder(dir_type)
                    if path and os.path.exists(path):
                        directories.append(path)
                except ValueError:
                    pass
        
        # Add custom directories
        for custom_dir in self.config.custom_directories:
            if os.path.exists(custom_dir):
                directories.append(custom_dir)
        
        return directories
    
    def is_system_directory(self, path: str) -> bool:
        path_lower = path.lower()
        
        for sys_dir in self.WINDOWS_SYSTEM_DIRS:
            if path_lower.startswith(sys_dir.lower()):
                return True
        
        if not self.config.include_system_dirs:
            # Check for hidden/system attributes on Windows
            try:
                import ctypes
                attrs = ctypes.windll.kernel32.GetFileAttributesW(path)
                if attrs != -1:
                    if attrs & 0x02 or attrs & 0x04:  # FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_SYSTEM
                        return True
            except:
                pass
        
        return False
    
    def scan_directory(
        self,
        directory: str,
        recursive: bool = True,
        extensions: Optional[List[str]] = None,
        db_manager = None
    ) -> List[str]:
        """扫描目录，如果提供db_manager则自动写入数据库"""
        module_name = "DirectoryScanner"
        
        # 记录模块开始
        processing_logger.log_module_start(
            module_name=module_name,
            file_path=directory,
            extra_info={
                "recursive": recursive,
                "extensions": extensions,
                "db_manager": "已提供" if db_manager else "未提供"
            }
        )
        
        if not os.path.exists(directory):
            processing_logger.log_error(module_name, Exception(f"目录不存在: {directory}"))
            processing_logger.log_module_end(module_name, success=False, message="目录不存在")
            return []
        
        if self.is_system_directory(directory) and not self.config.include_system_dirs:
            processing_logger.log_step("系统目录检查", "跳过系统目录", {"directory": directory})
            processing_logger.log_module_end(module_name, success=False, message="跳过系统目录")
            return []
        
        extensions = extensions or self.config.include_patterns
        files = []
        file_records = []
        
        try:
            if recursive:
                for root, dirs, filenames in os.walk(directory):
                    # Check depth
                    depth = root.count(os.sep) - directory.count(os.sep)
                    if depth > self.config.max_depth:
                        del dirs[:]
                        continue
                    
                    # Filter out system directories
                    if not self.config.include_system_dirs:
                        dirs[:] = [d for d in dirs if not self.is_system_directory(os.path.join(root, d))]
                    
                    for filename in filenames:
                        file_path = os.path.join(root, filename)
                        
                        # Check exclude patterns
                        if self._matches_patterns(filename, self.config.exclude_patterns):
                            continue
                        
                        # Check include patterns
                        if self._matches_patterns(filename, extensions):
                            files.append(file_path)
                            
                            # 准备数据库记录
                            if db_manager:
                                try:
                                    stat = os.stat(file_path)
                                    file_ext = os.path.splitext(filename)[1].lower()
                                    file_records.append({
                                        'file_path': file_path,
                                        'file_name': filename,
                                        'file_size': stat.st_size,
                                        'file_type': file_ext,
                                        'modified_time': datetime.fromtimestamp(stat.st_mtime),
                                        'created_time': datetime.fromtimestamp(stat.st_ctime),
                                        'directory_path': directory
                                    })
                                except Exception as e:
                                    print(f"获取文件信息失败 {file_path}: {e}")
            else:
                for pattern in extensions:
                    pattern_path = os.path.join(directory, pattern)
                    matched_files = glob.glob(pattern_path)
                    files.extend(matched_files)
                    
                    # 准备数据库记录
                    if db_manager:
                        for file_path in matched_files:
                            try:
                                filename = os.path.basename(file_path)
                                stat = os.stat(file_path)
                                file_ext = os.path.splitext(filename)[1].lower()
                                file_records.append({
                                    'file_path': file_path,
                                    'file_name': filename,
                                    'file_size': stat.st_size,
                                    'file_type': file_ext,
                                    'modified_time': datetime.fromtimestamp(stat.st_mtime),
                                    'created_time': datetime.fromtimestamp(stat.st_ctime),
                                    'directory_path': directory
                                })
                            except Exception as e:
                                print(f"获取文件信息失败 {file_path}: {e}")
            
            # 批量写入数据库
            if db_manager and file_records:
                count = db_manager.add_files_batch(file_records)
                processing_logger.log_step("数据库写入", f"批量写入 {count} 个文件记录")
        
        except Exception as e:
            processing_logger.log_error(module_name, e, f"扫描目录时出错: {directory}")
        
        # 记录模块输出和结束
        processing_logger.log_module_output(module_name, {
            "scanned_files_count": len(files),
            "database_records_count": len(file_records)
        })
        processing_logger.log_module_end(module_name, success=True,
                                        message=f"成功扫描 {len(files)} 个文件")

        print(f"[DEBUG] DirectoryScanner.scan_directory 即将返回 {len(files)} 个文件", flush=True)
        return files
    
    def _matches_patterns(self, filename: str, patterns: List[str]) -> bool:
        """检查文件名是否匹配给定的模式列表
        
        Args:
            filename: 文件名
            patterns: 模式列表
            
        Returns:
            如果匹配任一模式返回True，否则返回False
            如果patterns为空，返回False
        """
        if not patterns:
            return False
        
        import fnmatch
        for pattern in patterns:
            if fnmatch.fnmatch(filename.lower(), pattern.lower()):
                return True
        return False
    
    def scan_default_directories(self) -> Dict[str, List[str]]:
        results = {}
        directories = self.get_default_scan_directories()
        
        for directory in directories:
            dir_name = os.path.basename(directory) or directory
            files = self.scan_directory(directory)
            if files:
                results[dir_name] = files
        
        return results
    
    def scan_all(self) -> Dict[str, Any]:
        return {
            'default_directories': self.scan_default_directories(),
            'total_files': sum(len(files) for files in self.scan_default_directories().values()),
            'scanned_directories': self.get_default_scan_directories()
        }
    
    def add_custom_directory(self, directory: str) -> bool:
        if not os.path.exists(directory):
            return False
        
        abs_path = os.path.abspath(directory)
        if abs_path not in self.config.custom_directories:
            self.config.custom_directories.append(abs_path)
            return self.save_config()
        return True
    
    def remove_custom_directory(self, directory: str) -> bool:
        abs_path = os.path.abspath(directory)
        if abs_path in self.config.custom_directories:
            self.config.custom_directories.remove(abs_path)
            return self.save_config()
        return True
    
    def enable_default_directory(self, dir_type: str, enabled: bool = True) -> bool:
        if dir_type in self.config.default_directories:
            self.config.default_directories[dir_type] = enabled
            return self.save_config()
        return False
    
    def get_scan_summary(self) -> Dict[str, Any]:
        return {
            'config_path': self.config_path,
            'default_directories': self.config.default_directories,
            'custom_directories': self.config.custom_directories,
            'include_patterns': self.config.include_patterns,
            'exclude_patterns': self.config.exclude_patterns,
            'max_depth': self.config.max_depth,
            'include_system_dirs': self.config.include_system_dirs
        }
