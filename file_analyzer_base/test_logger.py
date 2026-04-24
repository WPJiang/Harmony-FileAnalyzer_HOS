"""
测试日志模块功能
"""
import os
import sys
import time

# 导入日志模块
from logger import processing_logger

def test_logger():
    """测试日志记录功能"""
    
    # 开始日志会话
    log_path = processing_logger.start_session("test_session")
    print(f"日志文件路径: {log_path}")
    
    # 模拟目录扫描模块
    processing_logger.log_module_start(
        module_name="DirectoryScanner",
        file_path="D:\\Documents",
        extra_info={
            "recursive": True,
            "extensions": ["*.pdf", "*.docx"],
            "db_manager": "已提供"
        }
    )
    
    processing_logger.log_step("扫描目录", "开始扫描 D:\\Documents")
    processing_logger.log_step("文件发现", "找到 5 个文件")
    
    # 模拟发现文件
    test_files = [
        "D:\\Documents\\report.pdf",
        "D:\\Documents\\notes.docx",
        "D:\\Documents\\image.png",
        "D:\\Documents\\data.csv",
        "D:\\Documents\\presentation.pptx"
    ]
    
    for i, file_path in enumerate(test_files):
        processing_logger.log_step("文件处理", f"处理文件 {i+1}/{len(test_files)}", {"file": file_path})
    
    processing_logger.log_module_output("DirectoryScanner", {
        "scanned_files_count": len(test_files),
        "database_records_count": len(test_files)
    })
    processing_logger.log_module_end("DirectoryScanner", success=True, 
                                    message=f"成功扫描 {len(test_files)} 个文件")
    
    # 模拟数据解析模块
    for file_path in test_files[:2]:  # 只处理前2个文件作为示例
        processing_logger.log_module_start(
            module_name="DataParser",
            file_path=file_path,
            extra_info={
                "db_manager": "已提供",
                "file_id": 1,
                "parsing_mode": 1
            }
        )
        
        processing_logger.log_step("配置加载", "解析配置", {
            "parsing_mode": 1,
            "max_length": 256
        })
        
        ext = os.path.splitext(file_path)[1].lower().lstrip('.')
        processing_logger.log_step("文件类型识别", f"扩展名: {ext}")
        
        is_image = ext in ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp']
        is_multipage = ext in ['pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx']
        
        processing_logger.log_step("文件类型判断", f"is_image={is_image}, is_multipage={is_multipage}")
        
        if is_image:
            processing_logger.log_step("轻量解析", "处理图片类型")
            processing_logger.log_data_block("IMAGE", f"block_{hash(file_path) % 10000}",
                                            f"[Image file: {os.path.basename(file_path)}]",
                                            {"modality": "IMAGE"})
        elif is_multipage:
            processing_logger.log_step("轻量解析", "处理多页文档类型")
            processing_logger.log_data_block("TEXT", f"block_{hash(file_path) % 10000}",
                                            f"文件名: {os.path.basename(file_path)}\n\n首页内容:\n这是示例文本内容...",
                                            {"original_length": 500, "truncated": True})
        
        processing_logger.log_step("数据库写入", "写入 1 个数据块")
        processing_logger.log_step("数据库写入", f"成功写入数据块 block_{hash(file_path) % 10000}")
        
        processing_logger.log_module_output("DataParser", {
            "final_blocks_count": 1,
            "parsing_mode": 1,
            "is_image": is_image,
            "is_multipage": is_multipage
        })
        processing_logger.log_module_end("DataParser", success=True,
                                        message="成功解析，生成 1 个数据块")
    
    # 模拟语义表征模块
    processing_logger.log_module_start(
        module_name="SemanticRepresentation",
        file_path="D:\\Documents\\report.pdf",
        extra_info={
            "block_id": "block_12345",
            "modality": "TEXT",
            "db_manager": "已提供",
            "data_block_id": 1,
            "file_id": 1
        }
    )
    
    processing_logger.log_step("类型判断", "is_image=False, modality=TEXT")
    processing_logger.log_step("文本提取", "使用数据块原有文本内容")
    processing_logger.log_step("生成描述", "使用TextDescriptionGenerator")
    processing_logger.log_step("描述生成完成", "描述长度: 256")
    processing_logger.log_step("提取关键词", "使用KeywordExtractor")
    processing_logger.log_step("关键词提取完成", "关键词数量: 10", 
                              {"keywords": ["报告", "数据", "分析", "结果", "结论"]})
    processing_logger.log_step("生成向量", "使用嵌入模型: SentenceTransformerEmbedding")
    processing_logger.log_step("向量生成完成", "向量维度: 384")
    
    processing_logger.log_semantic_block(
        block_id="block_12345",
        text_description="这是一份关于数据分析的报告，包含详细的统计结果和结论...",
        keywords=["报告", "数据", "分析", "结果", "结论", "统计", "图表", "趋势", "预测", "建议"],
        vector_dim=384
    )
    
    processing_logger.log_step("数据库写入", "写入语义块 block_12345")
    processing_logger.log_step("数据库写入", "成功写入语义块 block_12345")
    
    processing_logger.log_module_output("SemanticRepresentation", {
        "semantic_block_id": "block_12345",
        "text_description_length": 256,
        "keywords_count": 10,
        "has_vector": True
    })
    processing_logger.log_module_end("SemanticRepresentation", success=True,
                                    message="成功生成语义表征")
    
    # 模拟语义分类模块
    processing_logger.log_module_start(
        module_name="SemanticClassification",
        file_path="semantic_block",
        extra_info={
            "block_id": "block_12345",
            "has_vector": True,
            "keywords_count": 10
        }
    )
    
    processing_logger.log_step("分类计算", "开始计算与 8 个类别的相似度")
    
    # 模拟分类结果
    all_scores = {
        "技术文档": 0.85,
        "商业报告": 0.75,
        "学术论文": 0.65,
        "会议演示": 0.45,
        "合同协议": 0.25,
        "产品说明": 0.35,
        "新闻资讯": 0.20,
        "个人文档": 0.15
    }
    
    processing_logger.log_classification("技术文档", 0.85, all_scores)
    
    processing_logger.log_module_output("SemanticClassification", {
        "block_id": "block_12345",
        "category": "技术文档",
        "confidence": 0.85
    })
    processing_logger.log_module_end("SemanticClassification", success=True,
                                    message="分类完成: 技术文档 (置信度: 0.8500)")
    
    # 记录处理摘要
    processing_logger.log_summary(
        total_files=5,
        success_count=5,
        fail_count=0,
        duration_seconds=12.5
    )
    
    # 结束日志会话
    processing_logger.end_session()
    
    print(f"\n测试完成！")
    print(f"日志文件已保存到: {log_path}")
    
    # 读取并显示日志内容
    print("\n" + "="*80)
    print("日志文件内容预览:")
    print("="*80)
    try:
        with open(log_path, 'r', encoding='utf-8') as f:
            content = f.read()
            # 显示前2000个字符
            print(content[:2000])
            if len(content) > 2000:
                print(f"\n... (还有 {len(content) - 2000} 个字符)")
    except Exception as e:
        print(f"读取日志文件失败: {e}")

if __name__ == "__main__":
    test_logger()