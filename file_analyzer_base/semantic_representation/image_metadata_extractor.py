"""图片元数据提取模块

从图片文件中提取时空元数据，包括：
1. 拍摄时间（数据提取）- 从EXIF等元数据提取
2. 拍摄时间（文件名分析）- 从文件名解析时间
3. 地点信息 - 从GPS坐标反查语义位置
"""

import os
import re
import json
from typing import Dict, Any, Optional, Tuple
from datetime import datetime


class ImageMetadataExtractor:
    """图片元数据提取器"""

    # 图片文件扩展名
    IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.livp'}

    # 时间格式正则表达式（用于文件名解析）
    TIME_PATTERNS = [
        # 格式: 2020-11-07 135806 或 2020-11-07_135806
        (r'(\d{4})[-_](\d{2})[-_](\d{2})[\s_]?(\d{2})(\d{2})(\d{2})', '%Y-%m-%d %H%M%S'),
        # 格式: 20201107_135806 或 20201107135806
        (r'(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})', '%Y%m%d %H%M%S'),
        # 格式: 2020-11-07
        (r'(\d{4})[-_](\d{2})[-_](\d{2})', '%Y-%m-%d'),
        # 格式: IMG_20201107_135806
        (r'IMG[_]?(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})', '%Y%m%d %H%M%S'),
        # 格式: VID_20201107_135806
        (r'VID[_]?(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})', '%Y%m%d %H%M%S'),
        # 格式: WX20201107-135806
        (r'WX(\d{4})(\d{2})(\d{2})[-_]?(\d{2})(\d{2})(\d{2})', '%Y%m%d %H%M%S'),
    ]

    def __init__(self, use_gps_reverse: bool = True):
        """初始化提取器

        Args:
            use_gps_reverse: 是否启用GPS反查（需要网络）
        """
        self.use_gps_reverse = use_gps_reverse
        self._pil_support = self._check_pil_support()
        self._heic_support = self._check_heic_support()

    def _check_pil_support(self) -> bool:
        """检查PIL支持"""
        try:
            from PIL import Image
            from PIL.ExifTags import TAGS, GPSTAGS
            return True
        except ImportError:
            return False

    def _check_heic_support(self) -> bool:
        """检查HEIC支持并注册"""
        try:
            from pillow_heif import register_heif_opener
            register_heif_opener()  # 注册HEIC支持
            return True
        except ImportError:
            return False

    def is_image_file(self, file_path: str) -> bool:
        """检查是否为图片文件"""
        ext = os.path.splitext(file_path)[1].lower()
        return ext in self.IMAGE_EXTENSIONS

    def extract_metadata(self, file_path: str) -> Dict[str, Any]:
        """提取图片元数据

        Args:
            file_path: 图片文件路径

        Returns:
            元数据字典，包含：
            - file_type: 文件类型
            - capture_time_extracted: 拍摄时间（数据提取）
            - capture_time_from_filename: 拍摄时间（文件名分析）
            - location_info: 地点信息
            - gps_coordinates: GPS坐标（原始）
            - image_width: 图片宽度
            - image_height: 图片高度
        """
        metadata = {
            'file_type': 'image',
            'capture_time_extracted': None,
            'capture_time_from_filename': None,
            'location_info': None,
            'gps_coordinates': None,
            'image_width': None,
            'image_height': None,
        }

        if not os.path.exists(file_path):
            return metadata

        ext = os.path.splitext(file_path)[1].lower()

        # 处理 livp 格式（需要先解压）
        if ext == '.livp':
            return self._extract_livp_metadata(file_path, metadata)

        # 从文件名解析时间
        metadata['capture_time_from_filename'] = self._parse_time_from_filename(file_path)

        # 从文件元数据提取信息
        if self._pil_support:
            try:
                if ext in {'.heic', '.heif'} and self._heic_support:
                    return self._extract_heic_metadata(file_path, metadata)
                else:
                    return self._extract_standard_metadata(file_path, metadata)
            except Exception as e:
                print(f"[ImageMetadataExtractor] 提取元数据失败: {file_path}, 错误: {e}")

        return metadata

    def _extract_standard_metadata(self, file_path: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
        """提取标准图片格式的元数据"""
        from PIL import Image
        from PIL.ExifTags import TAGS, GPSTAGS

        try:
            with Image.open(file_path) as img:
                # 图片尺寸
                metadata['image_width'] = img.width
                metadata['image_height'] = img.height

                # 获取EXIF数据（使用 _getexif 获取完整数据包括GPS字典）
                if hasattr(img, '_getexif'):
                    exif_data = img._getexif()
                    if exif_data:
                        # 解析EXIF标签
                        exif = {}
                        for tag_id, value in exif_data.items():
                            tag = TAGS.get(tag_id, tag_id)
                            exif[tag] = value

                        # 提取拍摄时间
                        if 'DateTimeOriginal' in exif:
                            metadata['capture_time_extracted'] = self._parse_exif_time(exif['DateTimeOriginal'])
                        elif 'DateTime' in exif:
                            metadata['capture_time_extracted'] = self._parse_exif_time(exif['DateTime'])

                        # 提取GPS信息（_getexif返回的GPSInfo是字典）
                        if 'GPSInfo' in exif and isinstance(exif['GPSInfo'], dict):
                            gps_info = {}
                            for key in exif['GPSInfo'].keys():
                                name = GPSTAGS.get(key, key)
                                gps_info[name] = exif['GPSInfo'][key]

                            lat, lon = self._get_gps_coordinates(gps_info)
                            if lat and lon:
                                metadata['gps_coordinates'] = {'latitude': lat, 'longitude': lon}
                                if self.use_gps_reverse:
                                    metadata['location_info'] = self._reverse_geocode(lat, lon)

        except AttributeError:
            # 某些格式不支持EXIF，正常情况，不输出错误
            pass
        except Exception as e:
            # 其他异常才输出错误
            print(f"[ImageMetadataExtractor] EXIF解析失败: {e}")

        return metadata

    def _extract_heic_metadata(self, file_path: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
        """提取HEIC格式元数据"""
        from PIL import Image
        from PIL.ExifTags import TAGS, GPSTAGS

        try:
            with Image.open(file_path) as img:
                # 图片尺寸
                metadata['image_width'] = img.width
                metadata['image_height'] = img.height

                # HEIC使用 getexif() 方法
                exif_obj = img.getexif()
                if exif_obj:
                    # 提取拍摄时间
                    date_time = exif_obj.get(306)  # DateTime
                    date_time_original = exif_obj.get(36867)  # DateTimeOriginal
                    if date_time_original:
                        metadata['capture_time_extracted'] = self._parse_exif_time(date_time_original)
                    elif date_time:
                        metadata['capture_time_extracted'] = self._parse_exif_time(date_time)

                    # 提取GPS信息（使用 get_ifd 获取 GPS IFD）
                    try:
                        gps_ifd = exif_obj.get_ifd(34853)  # GPSInfo tag id
                        if gps_ifd and isinstance(gps_ifd, dict):
                            gps_info = {}
                            for key in gps_ifd.keys():
                                name = GPSTAGS.get(key, key)
                                gps_info[name] = gps_ifd[key]

                            lat, lon = self._get_gps_coordinates(gps_info)
                            if lat and lon:
                                metadata['gps_coordinates'] = {'latitude': lat, 'longitude': lon}
                                if self.use_gps_reverse:
                                    metadata['location_info'] = self._reverse_geocode(lat, lon)
                    except Exception as e:
                        print(f"[ImageMetadataExtractor] HEIC GPS解析失败: {e}")

        except Exception as e:
            print(f"[ImageMetadataExtractor] HEIC打开失败: {e}")

        except Exception as e:
            print(f"[ImageMetadataExtractor] HEIC打开失败: {e}")

        return metadata

    def _extract_livp_metadata(self, file_path: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
        """提取livp格式元数据"""
        import zipfile
        import tempfile

        metadata['file_type'] = 'live_photo'
        tmp_path = None

        try:
            if not zipfile.is_zipfile(file_path):
                return metadata

            with zipfile.ZipFile(file_path, 'r') as zf:
                # 查找图片文件
                for f in zf.namelist():
                    ext = os.path.splitext(f)[1].lower()
                    if ext in {'.heic', '.heif', '.jpg', '.jpeg'}:
                        # 提取到临时文件
                        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
                            tmp.write(zf.read(f))
                            tmp_path = tmp.name

                        try:
                            # 提取内部图片的元数据
                            if ext in {'.heic', '.heif'}:
                                inner_metadata = self._extract_heic_metadata(tmp_path, metadata.copy())
                            else:
                                inner_metadata = self._extract_standard_metadata(tmp_path, metadata.copy())

                            # 合并元数据
                            for key in ['capture_time_extracted', 'gps_coordinates', 'location_info', 'image_width', 'image_height']:
                                if inner_metadata.get(key):
                                    metadata[key] = inner_metadata[key]
                        finally:
                            # 延迟删除临时文件
                            if tmp_path and os.path.exists(tmp_path):
                                try:
                                    # 先关闭可能打开的文件句柄
                                    import gc
                                    gc.collect()
                                    os.unlink(tmp_path)
                                except Exception:
                                    pass
                        break

        except Exception as e:
            print(f"[ImageMetadataExtractor] LIVP解析失败: {e}")

        # 从文件名解析时间
        if not metadata.get('capture_time_from_filename'):
            metadata['capture_time_from_filename'] = self._parse_time_from_filename(file_path)

        return metadata

    def _parse_time_from_filename(self, file_path: str) -> Optional[str]:
        """从文件名解析时间"""
        filename = os.path.basename(file_path)
        name_without_ext = os.path.splitext(filename)[0]

        for pattern, time_format in self.TIME_PATTERNS:
            match = re.search(pattern, name_without_ext)
            if match:
                try:
                    groups = match.groups()
                    if len(groups) == 6:
                        # 包含时分秒
                        time_str = f"{groups[0]}-{groups[1]}-{groups[2]} {groups[3]}:{groups[4]}:{groups[5]}"
                        dt = datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S')
                    elif len(groups) == 3:
                        # 仅日期
                        time_str = f"{groups[0]}-{groups[1]}-{groups[2]}"
                        dt = datetime.strptime(time_str, '%Y-%m-%d')
                    else:
                        continue

                    return dt.strftime('%Y-%m-%d %H:%M:%S')
                except ValueError:
                    continue

        return None

    def _parse_exif_time(self, time_str: str) -> Optional[str]:
        """解析EXIF时间字符串"""
        if not time_str:
            return None

        try:
            # EXIF时间格式: "2020:11:07 13:58:06"
            if ':' in time_str[:10]:
                time_str = time_str.replace(':', '-', 2)
            dt = datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S')
            return dt.strftime('%Y-%m-%d %H:%M:%S')
        except ValueError:
            try:
                dt = datetime.strptime(time_str, '%Y:%m:%d %H:%M:%S')
                return dt.strftime('%Y-%m-%d %H:%M:%S')
            except ValueError:
                return None

    def _get_gps_coordinates(self, gps_info: Dict) -> Tuple[Optional[float], Optional[float]]:
        """从GPS信息提取经纬度"""
        try:
            lat = None
            lon = None

            # 纬度
            if 'GPSLatitude' in gps_info and 'GPSLatitudeRef' in gps_info:
                lat = self._convert_to_degrees(gps_info['GPSLatitude'])
                if gps_info['GPSLatitudeRef'] == 'S':
                    lat = -lat

            # 经度
            if 'GPSLongitude' in gps_info and 'GPSLongitudeRef' in gps_info:
                lon = self._convert_to_degrees(gps_info['GPSLongitude'])
                if gps_info['GPSLongitudeRef'] == 'W':
                    lon = -lon

            return lat, lon
        except Exception:
            return None, None

    def _convert_to_degrees(self, value) -> float:
        """将GPS坐标转换为度数"""
        if isinstance(value, tuple) and len(value) == 3:
            d, m, s = value
            if isinstance(d, tuple):
                d = d[0] / d[1] if len(d) == 2 and d[1] != 0 else 0
            if isinstance(m, tuple):
                m = m[0] / m[1] if len(m) == 2 and m[1] != 0 else 0
            if isinstance(s, tuple):
                s = s[0] / s[1] if len(s) == 2 and s[1] != 0 else 0
            return float(d) + float(m) / 60.0 + float(s) / 3600.0
        return 0.0

    def _reverse_geocode(self, lat: float, lon: float) -> Optional[str]:
        """反查GPS坐标为语义位置

        使用免费地理编码服务
        """
        try:
            import requests

            # 使用 Nominatim (OpenStreetMap) 免费 API
            url = f"https://nominatim.openstreetmap.org/reverse"
            params = {
                'lat': lat,
                'lon': lon,
                'format': 'json',
                'zoom': 18,
                'addressdetails': 1,
                'accept-language': 'zh'
            }
            headers = {
                'User-Agent': 'FileAnalyzer/1.0'
            }

            response = requests.get(url, params=params, headers=headers, timeout=10)
            if response.status_code == 200:
                data = response.json()
                # 提取有意义的地点信息
                address = data.get('address', {})

                # 优先级：景点 > 商店/餐厅 > 道路 > 区域
                location_parts = []

                # 景点/POI名称
                if 'tourism' in address:
                    location_parts.append(address['tourism'])
                if 'amenity' in address:
                    location_parts.append(address['amenity'])
                if 'shop' in address:
                    location_parts.append(address['shop'])
                if 'building' in address:
                    location_parts.append(address['building'])

                # 道路名称
                if 'road' in address:
                    location_parts.append(address['road'])

                # 区域信息
                if 'suburb' in address:
                    location_parts.append(address['suburb'])
                elif 'city_district' in address:
                    location_parts.append(address['city_district'])

                # 城市名
                if 'city' in address:
                    location_parts.append(address['city'])
                elif 'town' in address:
                    location_parts.append(address['town'])
                elif 'county' in address:
                    location_parts.append(address['county'])

                if location_parts:
                    return ', '.join(location_parts[:3])  # 最多返回3个层级

                # 如果没有详细地址，返回显示名称
                return data.get('display_name', '').split(',')[0]

        except Exception as e:
            print(f"[ImageMetadataExtractor] GPS反查失败: {e}")

        return None


def extract_image_metadata(file_path: str, use_gps_reverse: bool = True) -> Dict[str, Any]:
    """便捷函数：提取图片元数据

    Args:
        file_path: 图片文件路径
        use_gps_reverse: 是否启用GPS反查

    Returns:
        元数据字典
    """
    extractor = ImageMetadataExtractor(use_gps_reverse=use_gps_reverse)
    return extractor.extract_metadata(file_path)


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding='utf-8')

    # 测试
    extractor = ImageMetadataExtractor(use_gps_reverse=False)

    test_dir = "D:/jiangweipeng/trae_code/个人文件/图片sample"
    if os.path.exists(test_dir):
        for f in os.listdir(test_dir)[:5]:
            file_path = os.path.join(test_dir, f)
            print(f"\n文件: {f}")
            metadata = extractor.extract_metadata(file_path)
            for key, value in metadata.items():
                if value:
                    print(f"  {key}: {value}")