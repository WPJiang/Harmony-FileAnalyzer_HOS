/**
 * 图片描述生成结果数据模型
 */
export interface CaptionResult {
  // 生成的描述文本
  caption: string;
  // 推理耗时(毫秒)
  elapsedTime: number;
  // 生成速度(tokens/秒)
  tokensPerSecond?: number;
  // 生成的token数量
  tokenCount?: number;
  // 使用的量化版本
  quantization: 'Q4' | 'Q8';
  // 内存占用(MB)
  memoryUsage?: number;
  // 是否成功
  success: boolean;
  // 错误信息
  errorMessage?: string;
}

/**
 * Caption生成模式
 */
export enum CaptionMode {
  // 本地端侧模型 (llama.cpp + Qwen)
  LOCAL = 'local',
  // 云端LLM API
  CLOUD = 'cloud'
}

/**
 * 创建空的Caption结果
 */
export function createEmptyCaptionResult(quantization: 'Q4' | 'Q8'): CaptionResult {
  return {
    caption: '',
    elapsedTime: 0,
    quantization: quantization,
    success: false
  };
}