import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';

/**
 * 并行任务模块
 * 提供可以被 TaskPool 执行的 @Concurrent 函数，以及普通的批量处理函数
 *
 * 注意：@Concurrent 函数有以下限制：
 * 1. 不能访问类实例或闭包变量
 * 2. 不能调用其他函数
 * 3. 参数必须是可序列化的基本类型
 */

/**
 * 文本块边界信息
 */
export interface TextBlockBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * OCR 文本块
 */
export interface OcrTextBlock {
  text: string;
  confidence: number;
  bounds: TextBlockBounds;
}

/**
 * 文件筛选项
 */
export interface FileFilterItem {
  name: string;
  type: string;
  status: string;
}

/**
 * MindSpore Embedding 任务参数
 */
export interface MindSporeEmbeddingTaskParams {
  modelBuffer: ArrayBuffer;
  text: string;
  vocabJson: string;
}

/**
 * MindSpore Embedding 任务结果
 */
export interface MindSporeEmbeddingTaskResult {
  vector: number[];
  success: boolean;
  errorMessage: string;
}

/**
 * 在 TaskPool 子线程执行 MindSpore embedding 推理
 * 避免 model.predict() 阻塞主线程
 *
 * 注意：此函数在子线程中执行，需要在每次调用时重新初始化 model
 */
@Concurrent
export async function mindSporeEmbeddingTask(params: MindSporeEmbeddingTaskParams): Promise<MindSporeEmbeddingTaskResult> {
  const result: MindSporeEmbeddingTaskResult = {
    vector: [],
    success: false,
    errorMessage: ''
  };

  try {
    // 1. 创建 MindSpore 上下文（子线程）
    const msContext: mindSporeLite.Context = {
      target: ['cpu'],
      cpu: {
        threadNum: 2,
        precisionMode: 'preferred_fp32'
      }
    };

    // 2. 从 buffer 加载 model
    const model = await mindSporeLite.loadModelFromBuffer(params.modelBuffer, msContext);
    if (!model) {
      result.errorMessage = 'Failed to load model from buffer';
      return result;
    }

    // 3. 解析 vocab JSON
    const vocab: Map<string, number> = new Map();
    try {
      const vocabEntries: [string, number][] = Object.entries(JSON.parse(params.vocabJson));
      for (const entry of vocabEntries) {
        const key: string = entry[0];
        const id: number = entry[1];
        vocab.set(key, id);
      }
    } catch (e) {
      // vocab 解析失败，使用简单的空格分词
    }

    // 简单分词：按空格分割，查找 vocab
    const words = params.text.toLowerCase().split(/\s+/);
    const tokenIds: number[] = [];
    const maxLen = 512;

    // 添加特殊 token [CLS]=101, [SEP]=102
    tokenIds.push(101);

    for (let i = 0; i < words.length; i++) {
      const word = words[i];
      if (tokenIds.length >= maxLen - 1) break;
      const id = vocab.get(word);
      if (id !== undefined) {
        tokenIds.push(id);
      } else {
        // 未找到的词用 [UNK]=100 替代
        tokenIds.push(100);
      }
    }
    tokenIds.push(102);

    // 4. 获取模型输入并设置数据
    const inputs = model.getInputs();
    if (!inputs || inputs.length === 0) {
      result.errorMessage = 'Model has no inputs';
      return result;
    }

    // 设置 input_ids (Int32)
    const inputIdsData = new Int32Array(tokenIds);
    inputs[0].setData(inputIdsData);

    // 设置 attention_mask (全1)
    if (inputs.length > 1) {
      const attentionMask = new Int32Array(tokenIds.length).fill(1);
      inputs[1].setData(attentionMask);
    }

    // 设置 token_type_ids (全0)
    if (inputs.length > 2) {
      const tokenTypeIds = new Int32Array(tokenIds.length).fill(0);
      inputs[2].setData(tokenTypeIds);
    }

    // 5. 执行推理（在子线程中）
    const outputs = await model.predict(inputs);
    if (!outputs || outputs.length === 0) {
      result.errorMessage = 'Model returned no outputs';
      return result;
    }

    // 6. 提取 embedding（取前384维作为 [CLS] embedding）
    const outputTensor = outputs[0];
    const outputBuffer = outputTensor.getData();
    const outputData = new Float32Array(outputBuffer);
    const embeddingDim = 384;

    for (let i = 0; i < embeddingDim && i < outputData.length; i++) {
      result.vector.push(outputData[i]);
    }

    result.success = true;
    return result;

  } catch (e) {
    result.errorMessage = String(e);
    return result;
  }
}

/**
 * 文本预处理任务
 * 在子线程进行文本清洗操作
 */
@Concurrent
export async function preprocessTextTask(text: string): Promise<string> {
  if (!text || text.length === 0) {
    return '';
  }

  try {
    let processed = text.trim();
    processed = processed.replace(/\s+/g, ' ');
    processed = processed.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '');

    if (processed.length > 10000) {
      processed = processed.substring(0, 10000);
    }

    return processed;
  } catch (e) {
    console.error(`preprocessTextTask failed: ${e}`);
    return text;
  }
}

/**
 * 批量文本预处理（同步处理，非 @Concurrent）
 * 普通函数，可以在主线程直接调用
 */
export async function batchPreprocessTextTask(texts: string[]): Promise<string[]> {
  const results: string[] = [];

  for (const text of texts) {
    // 直接内联处理逻辑，不调用其他函数
    let processed = '';
    if (text && text.length > 0) {
      processed = text.trim();
      processed = processed.replace(/\s+/g, ' ');
      processed = processed.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '');
      if (processed.length > 10000) {
        processed = processed.substring(0, 10000);
      }
    }
    results.push(processed);
  }

  return results;
}

/**
 * 关键词提取预处理
 */
@Concurrent
export async function extractKeywordCandidatesTask(text: string): Promise<string[]> {
  if (!text || text.length === 0) {
    return [];
  }

  try {
    const words = text.split(/\s+/);
    const wordFreq: Map<string, number> = new Map();

    for (const word of words) {
      if (word.length >= 2 && word.length <= 20) {
        const count = wordFreq.get(word) || 0;
        wordFreq.set(word, count + 1);
      }
    }

    const entries = Array.from(wordFreq.entries());
    entries.sort((a, b) => b[1] - a[1]);
    const topEntries = entries.slice(0, 20);
    const results: string[] = [];
    for (const entry of topEntries) {
      results.push(entry[0]);
    }

    return results;
  } catch (e) {
    console.error(`extractKeywordCandidatesTask failed: ${e}`);
    return [];
  }
}

/**
 * 批量处理进度汇报任务
 */
@Concurrent
export async function calculateProgressTask(current: number, total: number): Promise<number> {
  if (total <= 0) {
    return 0;
  }
  return Math.round(current / total * 100);
}

/**
 * 文件列表筛选任务
 */
@Concurrent
export async function filterFilesByTypeTask(
  files: FileFilterItem[],
  targetType: string
): Promise<FileFilterItem[]> {
  const results: FileFilterItem[] = [];

  for (const file of files) {
    if (file.status === targetType) {
      results.push(file);
    }
  }

  return results;
}

/**
 * 向量相似度计算任务
 */
@Concurrent
export async function calculateSimilarityTask(
  vector1: number[],
  vector2: number[]
): Promise<number> {
  if (!vector1 || !vector2 || vector1.length !== vector2.length) {
    return 0;
  }

  try {
    let dotProduct = 0;
    let norm1 = 0;
    let norm2 = 0;

    for (let i = 0; i < vector1.length; i++) {
      dotProduct += vector1[i] * vector2[i];
      norm1 += vector1[i] * vector1[i];
      norm2 += vector2[i] * vector2[i];
    }

    const denominator = Math.sqrt(norm1) * Math.sqrt(norm2);
    if (denominator === 0) {
      return 0;
    }

    return dotProduct / denominator;
  } catch (e) {
    console.error(`calculateSimilarityTask failed: ${e}`);
    return 0;
  }
}

/**
 * 批量向量相似度计算（同步处理，非 @Concurrent）
 * 普通函数，可以在主线程直接调用
 */
export async function batchCalculateSimilarityTask(
  queryVector: number[],
  vectors: number[][]
): Promise<number[]> {
  const results: number[] = [];

  for (const vec of vectors) {
    // 内联相似度计算逻辑
    let similarity = 0;
    if (queryVector && vec && queryVector.length === vec.length) {
      let dotProduct = 0;
      let norm1 = 0;
      let norm2 = 0;
      for (let i = 0; i < queryVector.length; i++) {
        dotProduct += queryVector[i] * vec[i];
        norm1 += queryVector[i] * queryVector[i];
        norm2 += vec[i] * vec[i];
      }
      const denominator = Math.sqrt(norm1) * Math.sqrt(norm2);
      if (denominator > 0) {
        similarity = dotProduct / denominator;
      }
    }
    results.push(similarity);
  }

  return results;
}