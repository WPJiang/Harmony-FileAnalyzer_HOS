/**
 * MindSpore Embedding Worker
 * 在独立 Worker 线程中运行 MindSpore Lite 推理
 * 避免 model.predict() 阻塞主线程
 *
 * Worker 保持模型加载状态，无需每次重新加载
 *
 * 重要修复：添加消息队列机制，确保 encode 请求顺序处理
 * 防止并发访问导致模型输出缓冲区被重用
 */

import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { worker } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// 接口定义必须在前面
interface InitData {
  modelPath: string;
  vocabPath: string;
}

interface EncodeData {
  text: string;
}

interface EncodeBatchData {
  texts: string[];
}

interface WorkerMessage {
  type: 'init' | 'encode' | 'encodeBatch' | 'release';
  requestId?: string;
  data: InitData | EncodeData | EncodeBatchData;
}

interface WorkerResponse {
  type: 'initResult' | 'encodeResult' | 'encodeBatchResult' | 'error';
  requestId?: string;
  success: boolean;
  data: number[] | number[][] | null;
  message: string;
}

interface WorkerMessageEvent {
  data: WorkerMessage;
}

// 全局模型和分词器实例（在 Worker 线程中保持）
let model: mindSporeLite.Model | null = null;
let vocab: Map<string, number> = new Map();
let modelLoaded: boolean = false;

// 消息队列，确保顺序处理
let messageQueue: WorkerMessage[] = [];
let isProcessing: boolean = false;

// 特殊 token ID (BERT/MiniLM 标准格式)
const CLS_TOKEN = 101;  // [CLS] - 句子开始
const SEP_TOKEN = 102;  // [SEP] - 句子结束
const PAD_TOKEN = 0;    // [PAD] - 填充
const UNK_TOKEN = 100;  // [UNK] - 未知词
const MAX_SEQ_LEN = 512;

// Worker 端口
const workerPort = worker.workerPort;

/**
 * 文本标准化
 */
function normalizeText(text: string): string {
  let normalized = text.toLowerCase();
  normalized = normalized.replace(/\s+/g, ' ').trim();
  normalized = normalized.replace(/[""]/g, '"');
  normalized = normalized.replace(/['']/g, "'");
  return normalized;
}

/**
 * BPE 编码 - 处理不在词汇表中的词
 */
function bpeEncode(word: string): string[] {
  if (vocab.has(word)) {
    return [word];
  }

  const chars = word.split('');
  const tokens: string[] = [];

  let i = 0;
  while (i < chars.length) {
    let found = false;

    for (let len = Math.min(chars.length - i, 10); len >= 1; len--) {
      const subWord = chars.slice(i, i + len).join('');

      if (vocab.has(subWord)) {
        tokens.push(subWord);
        i += len;
        found = true;
        break;
      }

      const prefixedSubWord = '##' + subWord;
      if (i > 0 && vocab.has(prefixedSubWord)) {
        tokens.push(prefixedSubWord);
        i += len;
        found = true;
        break;
      }
    }

    if (!found) {
      tokens.push(chars[i]);
      i++;
    }
  }

  return tokens;
}

/**
 * 文本分词实现
 */
function tokenizeText(text: string): string[] {
  const tokens: string[] = [];
  const pattern = /\w+|[^\w\s]|\s+/g;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(text)) !== null) {
    const word = match[0];

    if (vocab.has(word)) {
      tokens.push(word);
    } else {
      const subTokens = bpeEncode(word);
      tokens.push(...subTokens);
    }
  }

  return tokens;
}

/**
 * 完整分词函数 - 固定padding到MAX_SEQ_LEN
 */
function tokenize(text: string): number[] {
  const normalizedText = normalizeText(text);
  const tokens = tokenizeText(normalizedText);
  const tokenIds: number[] = [CLS_TOKEN];

  for (const token of tokens) {
    const id = vocab.get(token);
    tokenIds.push(id !== undefined ? id : UNK_TOKEN);

    if (tokenIds.length >= MAX_SEQ_LEN - 1) {
      break;
    }
  }

  tokenIds.push(SEP_TOKEN);

  // 填充到固定长度 MAX_SEQ_LEN（与AItest的BPETokenizer一致）
  while (tokenIds.length < MAX_SEQ_LEN) {
    tokenIds.push(PAD_TOKEN);
  }

  return tokenIds.slice(0, MAX_SEQ_LEN);
}

/**
 * 执行单次 embedding 推理
 */
async function runEmbedding(text: string): Promise<number[] | null> {
  if (!modelLoaded || !model) {
    console.error('[MindSporeWorker] Model not loaded');
    return null;
  }

  try {
    // 等待模型内部状态稳定
    await new Promise<void>(resolve => setTimeout(resolve, 50));

    const inputs = model.getInputs();
    if (!inputs || inputs.length === 0) {
      console.error('[MindSporeWorker] No inputs');
      return null;
    }

    const tokenIds = tokenize(text);
    const seqLen = tokenIds.length;

    // 打印输入tensor信息
    try {
      const inputShape = inputs[0].shape;
      console.info(`[MindSporeWorker] Input tensor shape: ${JSON.stringify(inputShape)}`);
    } catch (e) {
      console.info('[MindSporeWorker] Input shape not available');
    }

    // 创建全新的ArrayBuffer
    const inputIdsBuffer = new ArrayBuffer(seqLen * 4);
    const inputIdsView = new Int32Array(inputIdsBuffer);
    for (let i = 0; i < seqLen; i++) {
      inputIdsView[i] = tokenIds[i];
    }
    inputs[0].setData(inputIdsView);

    // 打印输入数据样本
    const inputSample: number[] = [];
    for (let i = 0; i < Math.min(20, seqLen); i++) {
      inputSample.push(inputIdsView[i]);
    }
    console.info(`[MindSporeWorker] Input sample: [${inputSample.join(', ')}...]`);

    if (inputs.length > 1) {
      const attentionMaskBuffer = new ArrayBuffer(seqLen * 4);
      const attentionMaskView = new Int32Array(attentionMaskBuffer);
      for (let i = 0; i < seqLen; i++) {
        attentionMaskView[i] = tokenIds[i] !== PAD_TOKEN ? 1 : 0;
      }
      inputs[1].setData(attentionMaskView);
    }

    if (inputs.length > 2) {
      const tokenTypeIdsBuffer = new ArrayBuffer(seqLen * 4);
      const tokenTypeIdsView = new Int32Array(tokenTypeIdsBuffer);
      for (let i = 0; i < seqLen; i++) {
        tokenTypeIdsView[i] = 0;
      }
      inputs[2].setData(tokenTypeIdsView);
    }

    // 运行推理
    const outputs = await model.predict(inputs);
    if (!outputs || outputs.length === 0) {
      console.error('[MindSporeWorker] No outputs');
      return null;
    }

    // 打印输出tensor信息
    const outputTensor = outputs[0];
    try {
      const outShape = outputTensor.shape;
      console.info(`[MindSporeWorker] Output tensor shape: ${JSON.stringify(outShape)}`);
    } catch (e) {
      console.info('[MindSporeWorker] Output shape not available');
    }

    const outputBuffer = outputTensor.getData();
    console.info(`[MindSporeWorker] Output buffer size: ${outputBuffer.byteLength}`);

    const outputData = new Float32Array(outputBuffer);

    // 详细检查输出数据
    let validCount = 0;
    let zeroCount = 0;
    let nanCount = 0;
    for (let i = 0; i < outputData.length; i++) {
      if (isNaN(outputData[i])) nanCount++;
      else if (outputData[i] === 0) zeroCount++;
      else validCount++;
    }
    console.info(`[MindSporeWorker] Output stats: valid=${validCount}, zero=${zeroCount}, nan=${nanCount}`);

    // 深拷贝output buffer
    const copyBuffer = new ArrayBuffer(outputBuffer.byteLength);
    const srcBytes = new Uint8Array(outputBuffer);
    const dstBytes = new Uint8Array(copyBuffer);
    for (let i = 0; i < srcBytes.length; i++) {
      dstBytes[i] = srcBytes[i];
    }

    const copiedData = new Float32Array(copyBuffer);

    // 取前384维
    const embeddingDim = 384;
    const vector: number[] = [];
    for (let i = 0; i < embeddingDim && i < copiedData.length; i++) {
      const val = copiedData[i];
      if (!isNaN(val) && isFinite(val)) {
        vector.push(val);
      } else {
        vector.push(0);
      }
    }

    console.info(`[MindSporeWorker] Vector: len=${vector.length}, sample=[${vector.slice(0, 5).map(v => v.toFixed(4)).join(', ')}]`);
    return vector;
  } catch (e) {
    console.error('[MindSporeWorker] Embedding failed:', e);
    return null;
  }
}

function createZeroVector(dim: number): number[] {
  const vec: number[] = [];
  for (let i = 0; i < dim; i++) {
    vec.push(0);
  }
  return vec;
}

/**
 * 处理下一个消息
 */
async function processNextMessage(): Promise<void> {
  if (isProcessing || messageQueue.length === 0) {
    return;
  }

  isProcessing = true;
  const msg = messageQueue.shift()!;

  console.info('[MindSporeWorker] Processing message:', msg.type, 'requestId:', msg.requestId);

  try {
    if (msg.type === 'init') {
      const initData = msg.data as InitData;
      console.info('[MindSporeWorker] Initializing with model:', initData.modelPath);

      try {
        const vocabFile = await fileIo.open(initData.vocabPath, fileIo.OpenMode.READ_ONLY);
        const stat: fileIo.Stat = await fileIo.stat(initData.vocabPath);
        const buffer = new ArrayBuffer(stat.size);
        await fileIo.read(vocabFile.fd, buffer);
        await fileIo.close(vocabFile.fd);

        const decoder = util.TextDecoder.create('utf-8');
        const vocabText = decoder.decodeToString(new Uint8Array(buffer));

        const trimmed = vocabText.trim();

        if (trimmed.startsWith('{"version"') || trimmed.includes('"vocab":')) {
          interface TokenizerModelType {
            vocab: Array<[string, number]>;
          }

          interface AddedTokenType {
            id: number;
            content: string;
            special: boolean;
          }

          interface TokenizerJsonType {
            model: TokenizerModelType;
            added_tokens: AddedTokenType[];
          }

          try {
            const tokenizerJson: TokenizerJsonType = JSON.parse(vocabText);

            if (tokenizerJson.model && tokenizerJson.model.vocab) {
              const vocabArray = tokenizerJson.model.vocab;
              for (let i = 0; i < vocabArray.length; i++) {
                const item = vocabArray[i];
                const token = item[0];
                vocab.set(token, i);
              }
              console.info('[MindSporeWorker] Vocab loaded from tokenizer.json vocab array:', vocab.size, 'tokens');
            }

            if (tokenizerJson.added_tokens) {
              const addedTokens = tokenizerJson.added_tokens;
              for (const item of addedTokens) {
                vocab.set(item.content, item.id);
              }
              console.info('[MindSporeWorker] Added_tokens loaded:', addedTokens.length, 'special tokens');
            }
          } catch (jsonErr) {
            console.error('[MindSporeWorker] tokenizer.json parse failed:', jsonErr);
          }
        } else if (trimmed.startsWith('{')) {
          try {
            const vocabEntries: [string, number][] = Object.entries(JSON.parse(vocabText));
            for (const entry of vocabEntries) {
              vocab.set(entry[0], entry[1]);
            }
            console.info('[MindSporeWorker] Vocab loaded (JSON token->id format):', vocab.size, 'tokens');
          } catch (jsonErr) {
            console.warn('[MindSporeWorker] JSON parse failed, fallback to text format');
            const lines: string[] = vocabText.split('\n');
            for (let i = 0; i < lines.length; i++) {
              const token: string = lines[i].trim();
              if (token.length > 0) {
                vocab.set(token, i);
              }
            }
            console.info('[MindSporeWorker] Vocab loaded (text format):', vocab.size, 'tokens');
          }
        } else {
          const lines = vocabText.split('\n');
          for (let i = 0; i < lines.length; i++) {
            const token = lines[i].trim();
            if (token.length > 0) {
              vocab.set(token, i);
            }
          }
          console.info('[MindSporeWorker] Vocab loaded (text format):', vocab.size, 'tokens');
        }
      } catch (vocabErr) {
        console.error('[MindSporeWorker] Vocab load failed:', vocabErr);
      }

      const msContext: mindSporeLite.Context = {
        target: ['cpu'],
        cpu: {
          threadNum: 2,
          precisionMode: 'preferred_fp32'
        }
      };

      try {
        const stat = await fileIo.stat(initData.modelPath);
        const file = await fileIo.open(initData.modelPath, fileIo.OpenMode.READ_ONLY);
        const modelBuffer = new ArrayBuffer(stat.size);
        await fileIo.read(file.fd, modelBuffer);
        await fileIo.close(file.fd);

        model = await mindSporeLite.loadModelFromBuffer(modelBuffer, msContext);
        if (model) {
          modelLoaded = true;
          console.info('[MindSporeWorker] Model loaded successfully');
          workerPort.postMessage({
            type: 'initResult',
            requestId: msg.requestId,
            success: true,
            data: null,
            message: 'Model initialized'
          } as WorkerResponse);
        } else {
          workerPort.postMessage({
            type: 'initResult',
            requestId: msg.requestId,
            success: false,
            data: null,
            message: 'Model loading failed'
          } as WorkerResponse);
        }
      } catch (modelErr) {
        console.error('[MindSporeWorker] Model load failed:', modelErr);
        workerPort.postMessage({
          type: 'initResult',
          requestId: msg.requestId,
          success: false,
          data: null,
          message: String(modelErr)
        } as WorkerResponse);
      }
    }
    else if (msg.type === 'encode') {
      if (vocab.size === 0) {
        console.warn('[MindSporeWorker] Vocab not loaded yet, waiting...');
        workerPort.postMessage({
          type: 'encodeResult',
          requestId: msg.requestId,
          success: false,
          data: null,
          message: 'Vocab not loaded, please retry'
        } as WorkerResponse);
      } else {
        const encodeData = msg.data as EncodeData;
        const vector = await runEmbedding(encodeData.text);

        workerPort.postMessage({
          type: 'encodeResult',
          requestId: msg.requestId,
          success: vector !== null,
          data: vector,
          message: vector ? 'Success' : 'Encoding failed'
        } as WorkerResponse);
      }
    }
    else if (msg.type === 'encodeBatch') {
      if (vocab.size === 0) {
        console.warn('[MindSporeWorker] Vocab not loaded yet for batch encode');
        workerPort.postMessage({
          type: 'encodeBatchResult',
          requestId: msg.requestId,
          success: false,
          data: null,
          message: 'Vocab not loaded, please retry'
        } as WorkerResponse);
      } else {
        const batchData = msg.data as EncodeBatchData;
        const vectors: number[][] = [];

        for (const text of batchData.texts) {
          const vector = await runEmbedding(text);
          vectors.push(vector || createZeroVector(384));
        }

        workerPort.postMessage({
          type: 'encodeBatchResult',
          requestId: msg.requestId,
          success: true,
          data: vectors,
          message: 'Batch encoding completed'
        } as WorkerResponse);
      }
    }
    else if (msg.type === 'release') {
      if (model) {
        model = null;
        modelLoaded = false;
      }
      vocab.clear();
      workerPort.postMessage({
        type: 'initResult',
        requestId: msg.requestId,
        success: true,
        data: null,
        message: 'Worker released'
      } as WorkerResponse);
    }
  } catch (e) {
    console.error('[MindSporeWorker] Message handling failed:', e);
    workerPort.postMessage({
      type: 'error',
      requestId: msg.requestId,
      success: false,
      data: null,
      message: String(e)
    } as WorkerResponse);
  }

  isProcessing = false;

  // 处理下一个消息
  if (messageQueue.length > 0) {
    await processNextMessage();
  }
}

/**
 * Worker 消息处理 - 使用队列确保顺序处理
 */
workerPort.onmessage = async (e: WorkerMessageEvent) => {
  const msg = e.data as WorkerMessage;
  console.info('[MindSporeWorker] Queueing message:', msg.type, 'requestId:', msg.requestId);

  messageQueue.push(msg);
  await processNextMessage();
};