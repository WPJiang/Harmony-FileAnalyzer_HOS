/**
 * OCR识别结果数据模型
 */

/**
 * 文本块边界信息
 */
export interface TextBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/**
 * OCR文本块
 */
export interface OCRTextBlock {
  // 文本内容
  text: string;
  // 位置信息
  bounds: TextBounds;
  // 置信度
  confidence?: number;
}

/**
 * OCR识别结果
 */
export interface OCRResult {
  // 识别出的所有文本块
  textBlocks: OCRTextBlock[];
  // 合并后的完整文本
  fullText: string;
  // 识别耗时(毫秒)
  elapsedTime: number;
  // 使用的识别方式
  method: 'system_api' | 'model_inference';
  // 内存占用(MB)
  memoryUsage?: number;
  // 是否成功
  success: boolean;
  // 错误信息
  errorMessage?: string;
}

/**
 * 创建空的OCR结果
 */
export function createEmptyOCRResult(method: 'system_api' | 'model_inference'): OCRResult {
  const result: OCRResult = {
    textBlocks: [],
    fullText: '',
    elapsedTime: 0,
    method: method,
    success: false
  };
  return result;
}

/**
 * 创建文本边界
 */
export function createTextBounds(left: number, top: number, right: number, bottom: number): TextBounds {
  const bounds: TextBounds = {
    left: left,
    top: top,
    right: right,
    bottom: bottom
  };
  return bounds;
}

/**
 * 合并文本块为完整文本
 */
export function mergeTextBlocks(blocks: OCRTextBlock[]): string {
  let result = '';
  for (let i = 0; i < blocks.length; i++) {
    if (i > 0) {
      result += '\n';
    }
    result += blocks[i].text;
  }
  return result;
}