/**
 * 文本向量化结果数据模型
 */
export interface EmbeddingResult {
  // 输入文本
  inputText: string;
  // 向量数据(384维)
  vector: number[];
  // 向量维度
  dimension: number;
  // 推理耗时(毫秒)
  elapsedTime: number;
  // 使用的模型
  modelName: 'minilm-l6-v2' | 'minilm-l12-v2';
  // 内存占用(MB)
  memoryUsage?: number;
  // 是否成功
  success: boolean;
  // 错误信息
  errorMessage?: string;
}

/**
 * 创建空的Embedding结果
 */
export function createEmptyEmbeddingResult(modelName: 'minilm-l6-v2' | 'minilm-l12-v2'): EmbeddingResult {
  return {
    inputText: '',
    vector: [],
    dimension: 384,
    elapsedTime: 0,
    modelName: modelName,
    success: false
  };
}

/**
 * 计算两个向量的余弦相似度
 */
export function cosineSimilarity(vec1: number[], vec2: number[]): number {
  if (vec1.length !== vec2.length || vec1.length === 0) {
    return 0;
  }

  let dotProduct = 0;
  let norm1 = 0;
  let norm2 = 0;

  for (let i = 0; i < vec1.length; i++) {
    dotProduct += vec1[i] * vec2[i];
    norm1 += vec1[i] * vec1[i];
    norm2 += vec2[i] * vec2[i];
  }

  const denominator = Math.sqrt(norm1) * Math.sqrt(norm2);
  return denominator === 0 ? 0 : dotProduct / denominator;
}