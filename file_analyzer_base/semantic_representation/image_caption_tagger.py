"""图片Caption和标签生成模块

使用LLM对图片进行描述(caption)和标签分类。
"""

import os
import base64
import json
import io
import requests
from typing import Dict, Any, List, Optional, Tuple
from PIL import Image


# 图片标签分类体系 - 从配置文件加载
IMAGE_TAG_CATEGORIES = {}

# 支持的图片格式（llama.cpp支持的格式）
SUPPORTED_IMAGE_FORMATS = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tiff', '.tif'}

# 图片大小限制（云侧API限制约6MB）
MAX_IMAGE_SIZE = 5 * 1024 * 1024  # 5MB，留一些余量

# 图片缩放最大尺寸（默认值，从配置文件加载）
MAX_IMAGE_DIMENSION = 448


def _load_config():
    """从配置文件加载图片处理配置"""
    global MAX_IMAGE_DIMENSION, IMAGE_TAG_CATEGORIES

    try:
        config_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'config.json')
        if os.path.exists(config_path):
            with open(config_path, 'r', encoding='utf-8') as f:
                config = json.load(f)

                # 加载图片缩放尺寸
                image_config = config.get('image_processing', {})
                MAX_IMAGE_DIMENSION = image_config.get('max_dimension', 448)

                # 加载图片标签分类体系
                image_tag_config = config.get('image_tag_categories', {})
                IMAGE_TAG_CATEGORIES = image_tag_config.get('categories', {})

    except Exception as e:
        print(f"[ImageCaptionTagger] 加载配置失败: {e}")


# 模块加载时读取配置
_load_config()

# 扁平化的所有标签列表
ALL_IMAGE_TAGS = []
for category, tags in IMAGE_TAG_CATEGORIES.items():
    ALL_IMAGE_TAGS.extend(tags)


class ImageCaptionTagger:
    """图片Caption和标签生成器"""

    def __init__(self, llm_client=None):
        """初始化

        Args:
            llm_client: LLM客户端实例，如果为None则使用全局客户端
        """
        self.llm_client = llm_client

    def _get_llm_client(self):
        """获取LLM客户端"""
        if self.llm_client is not None:
            return self.llm_client

        from models.model_manager import get_llm_client
        return get_llm_client()

    def _resize_image_if_needed(self, image_path: str, max_dimension: int = MAX_IMAGE_DIMENSION) -> Tuple[bytes, str]:
        """缩放图片到指定最大尺寸（保持长宽比）

        Args:
            image_path: 图片文件路径
            max_dimension: 最大边长

        Returns:
            (图片字节数据, 图片格式) 元组
        """
        with Image.open(image_path) as img:
            original_width, original_height = img.size
            img_format = img.format or 'JPEG'

            # 如果图片尺寸在限制内，直接返回原图数据
            if original_width <= max_dimension and original_height <= max_dimension:
                with open(image_path, 'rb') as f:
                    return f.read(), img_format

            # 计算缩放比例
            ratio = min(max_dimension / original_width, max_dimension / original_height)
            new_width = int(original_width * ratio)
            new_height = int(original_height * ratio)

            # 缩放图片
            img_resized = img.resize((new_width, new_height), Image.Resampling.LANCZOS)

            # 转换为字节
            output = io.BytesIO()

            # 处理不同格式的保存
            if img_format.upper() == 'GIF':
                # GIF可能有多帧，只保存第一帧
                if hasattr(img_resized, 'n_frames') and img_resized.n_frames > 1:
                    img_resized.save(output, format='PNG')
                    img_format = 'PNG'
                else:
                    img_resized.save(output, format='GIF')
            elif img_format.upper() in ('PNG', 'WEBP'):
                img_resized.save(output, format=img_format)
            else:
                # JPEG等格式，确保是RGB模式
                if img_resized.mode in ('RGBA', 'P', 'LA'):
                    img_resized = img_resized.convert('RGB')
                img_resized.save(output, format='JPEG')
                img_format = 'JPEG'

            return output.getvalue(), img_format

    def _encode_image_to_base64(self, image_path: str) -> str:
        """将图片编码为base64 data URI格式（先缩放到合适大小）

        Returns:
            data URI格式字符串，如 "data:image/jpeg;base64,xxx"
        """
        image_data, img_format = self._resize_image_if_needed(image_path)

        # 确定MIME类型
        mime_types = {
            'JPEG': 'image/jpeg',
            'JPG': 'image/jpeg',
            'PNG': 'image/png',
            'GIF': 'image/gif',
            'WEBP': 'image/webp',
            'BMP': 'image/bmp',
            'TIFF': 'image/tiff',
        }
        mime_type = mime_types.get(img_format.upper(), 'image/jpeg')

        base64_data = base64.b64encode(image_data).decode('utf-8')
        return f"data:{mime_type};base64,{base64_data}"

    def generate_caption_and_tags(self, image_path: str) -> Dict[str, Any]:
        """生成图片的Caption和标签

        Args:
            image_path: 图片文件路径

        Returns:
            包含caption和tags的字典:
            {
                'caption': '30字以内的描述',
                'tags': ['标签1', '标签2', ...],
                'success': True/False,
                'error': '错误信息(如果失败)'
            }
        """
        result = {
            'caption': None,
            'tags': [],
            'success': False,
            'error': None
        }

        if not os.path.exists(image_path):
            result['error'] = f'图片文件不存在: {image_path}'
            return result

        # 检查图片格式是否支持
        ext = os.path.splitext(image_path)[1].lower()
        if ext not in SUPPORTED_IMAGE_FORMATS:
            result['error'] = f'不支持的图片格式: {ext}（支持: {", ".join(SUPPORTED_IMAGE_FORMATS)}）'
            return result

        try:
            client = self._get_llm_client()
            if client is None:
                result['error'] = 'LLM服务不可用'
                return result

            # 编码图片（会自动缩放到合适大小）
            image_base64 = self._encode_image_to_base64(image_path)

            # 构建prompt - 针对Qwen3.5思考链模式优化
            user_message = "请用一句话简洁描述这张图片的内容（不超过30字），然后列出3-5个描述图片的关键词。格式：描述：xxx 关键词：xxx, xxx, xxx"

            # 调用LLM
            response = self._call_llm_with_image(client, "", user_message, image_base64)

            if response:
                # 解析响应
                caption, tags = self._parse_caption_tags(response)
                if caption or tags:
                    result['caption'] = caption
                    result['tags'] = tags
                    result['success'] = True
                else:
                    result['error'] = '无法解析图片描述'
            else:
                result['error'] = 'LLM未返回有效响应'

        except Exception as e:
            result['error'] = str(e)

        return result

    def _parse_caption_tags(self, response: str) -> Tuple[str, List[str]]:
        """从响应中解析caption和tags

        Args:
            response: LLM响应文本

        Returns:
            (caption, tags) 元组
        """
        caption = ""
        tags = []

        # 尝试解析JSON格式
        try:
            json_start = response.find('{')
            json_end = response.rfind('}') + 1
            if json_start != -1 and json_end > json_start:
                json_str = response[json_start:json_end]
                parsed = json.loads(json_str)
                return parsed.get('caption', ''), parsed.get('tags', [])
        except (json.JSONDecodeError, ValueError):
            pass

        # 尝试解析"描述：xxx 关键词：xxx"格式
        import re

        # 提取描述 - 使用re.DOTALL让.匹配换行符
        # Qwen3.5思考链模式可能会重复输出，找最后一个匹配
        desc_matches = list(re.finditer(r'描述[：:]\s*(.+?)(?=关键词|$)', response, re.DOTALL))
        if desc_matches:
            # 取最后一个匹配（通常是最终答案）
            caption = desc_matches[-1].group(1).strip()
            # 移除末尾的句号
            caption = caption.rstrip('。')
            # 限制长度
            if len(caption) > 35:
                caption = caption[:32] + '...'

        # 提取关键词 - 同样找最后一个匹配
        tags_matches = list(re.finditer(r'关键词[：:]\s*(.+?)(?=\n|$)', response))
        if tags_matches:
            tags_str = tags_matches[-1].group(1).strip()
            # 移除末尾的句号
            tags_str = tags_str.rstrip('。')
            # 按逗号、顿号或空格分割
            tags = [t.strip() for t in re.split(r'[,，、\s]+', tags_str) if t.strip()]
            tags = tags[:5]  # 最多5个标签

        # 如果没有匹配到格式，尝试从推理内容中提取关键信息
        if not caption:
            # 尝试从"主体"、"主要人物"等描述中提取
            subject_match = re.search(r'(?:主体|主要人物|主要元素)[：:]\s*(.+?)(?=\n|\.|\*|$)', response)
            if subject_match:
                caption = subject_match.group(1).strip()[:35]
            else:
                # 尝试提取图片的主要内容描述
                lines = response.strip().split('\n')
                for line in lines:
                    line = line.strip()
                    # 跳过空行和星号开头的行
                    if line and not line.startswith('*') and not line.startswith('-'):
                        # 如果是描述性语句，作为caption
                        if len(line) > 5 and len(line) < 100 and '：' not in line and ':' not in line:
                            caption = line[:35]
                            break

        # 从内容中提取可能的标签（中文词汇）
        if not tags:
            # 常见图 片相关词汇
            keywords = re.findall(r'[\u4e00-\u9fa5]{2,6}', response)
            # 过滤常见的非标签词
            stop_words = ['图片', '这是', '一个', '可以看到', '看起来', '背景', '环境', '内容', '元素', '外貌', '动作', '状态', '穿着', '玩具', '其他', '细节']
            tags = [k for k in keywords[:15] if k not in stop_words and len(k) >= 2][:5]

        return caption, tags

    def _call_llm_with_image(self, client, system_prompt: str, user_message: str, image_base64: str) -> Optional[str]:
        """调用LLM处理图片

        Args:
            client: LLM客户端
            system_prompt: 系统提示词
            user_message: 用户消息
            image_base64: base64编码的图片

        Returns:
            LLM响应文本
        """
        try:
            # 尝试使用支持图片的方法
            if hasattr(client, '_call_chat_api'):
                # LocalLlamaClient
                result = client._call_chat_api(system_prompt, user_message, images=[image_base64])
                return result.get('response', '')
            elif hasattr(client, 'generate_image_description'):
                # 使用现有的图片描述方法，但我们需要自定义prompt
                # 这种方法可能不太理想，但作为备选
                return self._call_with_custom_prompt(client, system_prompt, user_message, image_base64)
            else:
                return None
        except Exception as e:
            error_msg = str(e)
            # 检查是否是图片不支持的错误
            if 'image input is not supported' in error_msg or 'mmproj' in error_msg:
                raise RuntimeError(
                    "当前LLM服务不支持图片输入。\n\n"
                    "请使用支持视觉的模型，例如：\n"
                    "• Ollama + llava 模型\n"
                    "• llama.cpp 带 mmproj 支持\n"
                    "• 云侧API（如GPT-4V）"
                )
            print(f"[ImageCaptionTagger] LLM调用失败: {e}")
            return None

    def _call_with_custom_prompt(self, client, system_prompt: str, user_message: str, image_base64: str) -> Optional[str]:
        """使用自定义prompt调用LLM"""
        # 对于OpenAI兼容API
        try:
            if hasattr(client, 'base_url'):
                url = f"{client.base_url}/chat/completions"
                headers = {"Content-Type": "application/json"}

                messages = [
                    {"role": "system", "content": system_prompt},
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": user_message},
                            {"type": "image_url", "image_url": {"url": image_base64}}
                        ]
                    }
                ]

                payload = {
                    "model": getattr(client, 'model', 'default'),
                    "messages": messages,
                    "max_tokens": getattr(client, 'max_tokens', 500),
                    "temperature": getattr(client, 'temperature', 0.7)
                }

                response = requests.post(
                    url,
                    headers=headers,
                    json=payload,
                    timeout=getattr(client, 'timeout', 60)
                )
                response.raise_for_status()

                result = response.json()
                if "choices" in result and len(result["choices"]) > 0:
                    return result["choices"][0].get("message", {}).get("content", "")
            return None
        except Exception as e:
            print(f"[ImageCaptionTagger] API调用失败: {e}")
            return None

    def _parse_response(self, response: str) -> Optional[Dict]:
        """解析LLM响应"""
        try:
            # 尝试提取JSON
            json_start = response.find('{')
            json_end = response.rfind('}') + 1

            if json_start != -1 and json_end > json_start:
                json_str = response[json_start:json_end]
                parsed = json.loads(json_str)

                # 验证字段
                caption = parsed.get('caption', '')
                tags = parsed.get('tags', [])

                # 清理标签
                if isinstance(tags, list):
                    tags = [str(t) for t in tags if t]

                # 限制caption长度
                if len(caption) > 50:
                    caption = caption[:47] + '...'

                return {
                    'caption': caption,
                    'tags': tags[:5]  # 最多5个标签
                }
        except json.JSONDecodeError as e:
            print(f"[ImageCaptionTagger] JSON解析失败: {e}")
        except Exception as e:
            print(f"[ImageCaptionTagger] 响应解析失败: {e}")

        return None

    def batch_generate(self, image_paths: List[str], progress_callback=None) -> List[Dict[str, Any]]:
        """批量生成Caption和标签

        Args:
            image_paths: 图片路径列表
            progress_callback: 进度回调函数 (current, total, message)

        Returns:
            结果列表
        """
        results = []
        total = len(image_paths)

        for i, image_path in enumerate(image_paths):
            if progress_callback:
                progress_callback(i + 1, total, f"处理: {os.path.basename(image_path)}")

            result = self.generate_caption_and_tags(image_path)
            result['file_path'] = image_path
            results.append(result)

        return results


def generate_image_caption_and_tags(image_path: str, llm_client=None) -> Dict[str, Any]:
    """便捷函数：生成图片Caption和标签

    Args:
        image_path: 图片文件路径
        llm_client: 可选的LLM客户端

    Returns:
        包含caption和tags的字典
    """
    tagger = ImageCaptionTagger(llm_client)
    return tagger.generate_caption_and_tags(image_path)


def is_image_format_supported(image_path: str) -> bool:
    """检查图片格式是否支持Caption生成

    Args:
        image_path: 图片文件路径

    Returns:
        是否支持该格式
    """
    ext = os.path.splitext(image_path)[1].lower()
    return ext in SUPPORTED_IMAGE_FORMATS


def is_image_processable(image_path: str) -> Tuple[bool, str]:
    """检查图片是否可以处理（格式检查，大图会自动缩放）

    Args:
        image_path: 图片文件路径

    Returns:
        (是否可处理, 错误信息)
    """
    if not os.path.exists(image_path):
        return False, f'图片文件不存在'

    ext = os.path.splitext(image_path)[1].lower()
    if ext not in SUPPORTED_IMAGE_FORMATS:
        return False, f'不支持的图片格式: {ext}'

    return True, ''


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding='utf-8')

    # 测试
    test_image = "D:/jiangweipeng/trae_code/个人文件/图片sample/IMG_20250308_163304.jpg"

    if os.path.exists(test_image):
        print(f"测试图片: {test_image}")
        result = generate_image_caption_and_tags(test_image)
        print(f"Caption: {result.get('caption')}")
        print(f"Tags: {result.get('tags')}")
        print(f"Success: {result.get('success')}")
        if result.get('error'):
            print(f"Error: {result.get('error')}")
    else:
        print(f"测试图片不存在: {test_image}")