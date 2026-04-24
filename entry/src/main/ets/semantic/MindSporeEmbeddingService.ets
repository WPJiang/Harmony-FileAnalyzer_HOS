import { EmbeddingResult, createEmptyEmbeddingResult, cosineSimilarity } from '../models/EmbeddingResult';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { common } from '@kit.AbilityKit';
import { ModelLoaderUtils } from '../utils/ModelLoaderUtils';
import { BPETokenizer } from '../tokenizers/BPETokenizer';
import { PerformanceUtils } from '../utils/PerformanceUtils';
import { fileIo } from '@kit.CoreFileKit';

/**
 * Embedding服务接口
 */
export interface EmbeddingServiceInterface {
  embed(text: string): Promise<EmbeddingResult>;
  getName(): string;
  isModelLoaded(): Promise<boolean>;
  loadModel(): Promise<boolean>;
}

/**
 * Embedding服务工厂
 */
export class EmbeddingServiceFactory {
  private static services: Map<string, EmbeddingServiceInterface> = new Map();

  static register(name: string, service: EmbeddingServiceInterface): void {
    EmbeddingServiceFactory.services.set(name, service);
  }

  static get(name: string): EmbeddingServiceInterface | undefined {
    return EmbeddingServiceFactory.services.get(name);
  }

  static getAllServiceNames(): string[] {
    return Array.from(EmbeddingServiceFactory.services.keys());
  }
}

/**
 * MindSpore Lite 真实 Embedding 服务实现
 * 使用 MindSpore Lite 运行 MiniLM 模型
 */
export class MindSporeEmbeddingService implements EmbeddingServiceInterface {
  private modelName: 'minilm-l6-v2' | 'minilm-l12-v2';
  private modelPath: string;
  private vocabPath: string;
  private model: mindSporeLite.Model | null = null;
  private tokenizer: BPETokenizer | null = null;
  private modelLoaded: boolean = false;
  private context: common.Context;

  constructor(modelName: 'minilm-l6-v2' | 'minilm-l12-v2', context: common.Context) {
    this.modelName = modelName;
    // 使用 INT32 输入类型的模型文件
    this.modelPath = `embedding/minilm_l6_v2_int32.ms`;
    // 使用 BERT 格式词汇表 (每行一个 token, 行号 = ID)
    this.vocabPath = 'embedding/vocab_full.json';
    this.context = context;
  }

  getName(): string {
    return `mindspore_${this.modelName}`;
  }

  async isModelLoaded(): Promise<boolean> {
    return this.modelLoaded;
  }

  async loadModel(): Promise<boolean> {
    if (this.modelLoaded) {
      return true;
    }

    const startTime = PerformanceUtils.startTimer();
    console.info(`MindSporeEmbeddingService: Starting to load model ${this.modelName}`);

    try {
      // 1. 初始化 BPE 分词器
      console.info('MindSporeEmbeddingService: Initializing tokenizer...');
      this.tokenizer = new BPETokenizer();
      const vocabLoaded = await this.tokenizer.load(this.context, this.vocabPath);
      if (!vocabLoaded) {
        console.warn('MindSporeEmbeddingService: Tokenizer vocabulary not found');
      } else {
        console.info('MindSporeEmbeddingService: Tokenizer loaded successfully');
      }

      // 2. 检查模型文件 (优先 filesDir，其次 rawfile)
      const filesDir = this.context.filesDir;
      console.info(`MindSporeEmbeddingService: context.filesDir = ${filesDir}`);

      const modelFilePath = `${filesDir}/minilm_l6_v2_int32.ms`;
      console.info(`MindSporeEmbeddingService: Checking model at ${modelFilePath}`);

      // 检查 filesDir 中是否存在模型（使用异步API避免阻塞主线程）
      let modelBuffer: ArrayBuffer | null = null;
      try {
        const stat = await fileIo.stat(modelFilePath);
        console.info(`MindSporeEmbeddingService: Model file exists in filesDir, size: ${stat.size}`);
        const file = await fileIo.open(modelFilePath, fileIo.OpenMode.READ_ONLY);
        modelBuffer = new ArrayBuffer(stat.size);
        await fileIo.read(file.fd, modelBuffer);
        await fileIo.close(file.fd);
        console.info(`MindSporeEmbeddingService: Loaded model from filesDir, buffer size: ${modelBuffer.byteLength}`);
      } catch (e) {
        console.error(`MindSporeEmbeddingService: Failed to load from filesDir: ${JSON.stringify(e)}`);
        // filesDir 中不存在，尝试从 rawfile 加载
        console.info('MindSporeEmbeddingService: Trying to load from rawfile...');
        const modelExists = await ModelLoaderUtils.checkModelExists(this.context, this.modelPath);
        console.info(`MindSporeEmbeddingService: Rawfile model exists: ${modelExists}`);
        if (!modelExists) {
          console.error(`MindSporeEmbeddingService: Model file not found at rawfile path: ${this.modelPath}`);
          return false;
        }
      }

      // 3. 创建 MindSpore Lite 上下文
      console.info('MindSporeEmbeddingService: Creating MindSpore Lite context...');
      const msContext = ModelLoaderUtils.createCPUContext(4);
      console.info(`MindSporeEmbeddingService: Context created, target: ${JSON.stringify(msContext.target)}`);

      // 4. 加载模型
      console.info('MindSporeEmbeddingService: Loading model into MindSpore Lite...');
      if (modelBuffer) {
        // 从文件系统加载
        console.info(`MindSporeEmbeddingService: Calling loadModelFromBuffer with buffer size ${modelBuffer.byteLength}`);
        this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, msContext);
        console.info(`MindSporeEmbeddingService: loadModelFromBuffer returned: ${this.model ? 'model object' : 'null'}`);
      } else {
        // 从 rawfile 加载
        console.info(`MindSporeEmbeddingService: Loading from rawfile: ${this.modelPath}`);
        this.model = await ModelLoaderUtils.loadMsModel(
          this.context,
          this.modelPath,
          msContext
        );
        console.info(`MindSporeEmbeddingService: loadMsModel returned: ${this.model ? 'model object' : 'null'}`);
      }

      if (this.model) {
        this.modelLoaded = true;
        const loadTime = PerformanceUtils.endTimer(startTime);
        console.info(`MindSporeEmbeddingService: Model ${this.modelName} loaded successfully in ${loadTime}ms`);
        return true;
      }

      // 5. 如果rawfile加载失败，尝试将模型复制到filesDir后重新加载（与AItest一致）
      console.warn('MindSporeEmbeddingService: Rawfile loading returned null, trying copy-to-filesDir approach...');
      try {
        const resourceMgr = this.context.resourceManager;
        const uint8Buffer = await resourceMgr.getRawFileContent(this.modelPath);
        if (uint8Buffer && uint8Buffer.byteLength > 0) {
          // 写入filesDir（使用异步API避免阻塞主线程）
          const destPath = `${this.context.filesDir}/minilm_l6_v2_int32.ms`;
          const destFile = await fileIo.open(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
          await fileIo.write(destFile.fd, uint8Buffer);
          await fileIo.close(destFile.fd);
          console.info(`MindSporeEmbeddingService: Copied model to filesDir: ${destPath}`);

          // 从filesDir读取为ArrayBuffer（使用异步API）
          const stat = await fileIo.stat(destPath);
          const file = await fileIo.open(destPath, fileIo.OpenMode.READ_ONLY);
          const arrayBuffer = new ArrayBuffer(stat.size);
          await fileIo.read(file.fd, arrayBuffer);
          await fileIo.close(file.fd);
          console.info(`MindSporeEmbeddingService: Read from filesDir, buffer size: ${arrayBuffer.byteLength}`);

          // 用ArrayBuffer加载模型
          this.model = await mindSporeLite.loadModelFromBuffer(arrayBuffer, msContext);
          console.info(`MindSporeEmbeddingService: filesDir loadModelFromBuffer returned: ${this.model ? 'model object' : 'null'}`);

          if (this.model) {
            this.modelLoaded = true;
            const loadTime = PerformanceUtils.endTimer(startTime);
            console.info(`MindSporeEmbeddingService: Model loaded via filesDir copy in ${loadTime}ms`);
            return true;
          }
        }
      } catch (copyErr) {
        console.error(`MindSporeEmbeddingService: Copy-to-filesDir approach also failed: ${JSON.stringify(copyErr)}`);
      }

      console.error('MindSporeEmbeddingService: All model loading approaches failed');
      return false;
    } catch (error) {
      console.error('MindSporeEmbeddingService.loadModel failed:', error);
      return false;
    }
  }

  async embed(text: string): Promise<EmbeddingResult> {
    const result = createEmptyEmbeddingResult(this.modelName);
    const startTime = PerformanceUtils.startTimer();

    if (!this.modelLoaded || !this.model || !this.tokenizer) {
      result.errorMessage = 'Model not loaded';
      return result;
    }

    try {
      // 1. 使用 BPE 分词器处理文本
      const tokenIds = this.tokenizer.tokenize(text);

      console.info(`MindSporeEmbeddingService: Input text: "${text}"`);
      console.info(`MindSporeEmbeddingService: Token IDs length: ${tokenIds.length}`);

      // 2. 获取模型输入
      const inputs = this.model.getInputs();

      if (!inputs || inputs.length === 0) {
        result.errorMessage = 'Model has no inputs';
        return result;
      }

      // 3. 填充输入到模型预期形状 [1, 512]
      // BERT/MiniLM 格式: PAD_TOKEN = 0 ([PAD])
      const expectedSeqLen = 512; // 模型转换时的max_seq_len
      const PAD_TOKEN = 0; // [PAD] token ID (BERT标准)

      console.info(`MindSporeEmbeddingService: Padding inputs to seq_len: ${expectedSeqLen}, real tokens: ${tokenIds.length}`);

      // 填充 input_ids 到预期长度
      const paddedInputIds = new Int32Array(expectedSeqLen);
      for (let i = 0; i < expectedSeqLen; i++) {
        paddedInputIds[i] = i < tokenIds.length ? tokenIds[i] : PAD_TOKEN;
      }
      inputs[0].setData(paddedInputIds);
      console.info(`MindSporeEmbeddingService: input_ids set: ${tokenIds.length} real tokens + ${expectedSeqLen - tokenIds.length} padding`);

      // 输入 1: attention_mask (1 for real tokens, 0 for padding)
      if (inputs.length > 1) {
        const paddedAttentionMask = new Int32Array(expectedSeqLen);
        for (let i = 0; i < expectedSeqLen; i++) {
          paddedAttentionMask[i] = i < tokenIds.length ? 1 : 0;
        }
        inputs[1].setData(paddedAttentionMask);
        console.info(`MindSporeEmbeddingService: attention_mask set: ${tokenIds.length} ones + ${expectedSeqLen - tokenIds.length} zeros`);
      }

      // 输入 2: token_type_ids (全部为0)
      if (inputs.length > 2) {
        const paddedTokenTypeIds = new Int32Array(expectedSeqLen).fill(0);
        inputs[2].setData(paddedTokenTypeIds);
      }

      // 4. 运行推理
      console.info('MindSporeEmbeddingService: Running predict...');

      const outputs = await this.model.predict(inputs);

      if (!outputs || outputs.length === 0) {
        result.errorMessage = 'Model returned no outputs';
        return result;
      }

      // 5. 提取 embedding 向量
      const outputTensor = outputs[0];
      const outputBuffer = outputTensor.getData();
      const outputData = new Float32Array(outputBuffer);

      console.info(`MindSporeEmbeddingService: Output data length: ${outputData.length}`);

      // MiniLM 输出形状: [1, 512, 384] -> [batch_size, sequence_length, hidden_dim]
      // [CLS] token embedding 在位置 [0, 0, :] (前 384 个值)
      const embeddingDimension = 384;
      const embeddingVector: number[] = [];

      // 取前 384 维作为 [CLS] embedding
      for (let i = 0; i < embeddingDimension && i < outputData.length; i++) {
        embeddingVector.push(outputData[i]);
      }

      // 6. 填充结果
      result.inputText = text;
      result.vector = embeddingVector;
      result.dimension = embeddingVector.length;
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = true;

      console.info(`MindSporeEmbeddingService: Embedding success, dimension: ${result.dimension}, time: ${result.elapsedTime}ms`);

      PerformanceUtils.recordMetric('embedding', this.getName(), result.elapsedTime, true);

      return result;
    } catch (error) {
      console.error('MindSporeEmbeddingService.embed failed:', error);
      result.errorMessage = String(error);
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = false;

      PerformanceUtils.recordMetric('embedding', this.getName(), result.elapsedTime, false);

      return result;
    }
  }

  /**
   * 释放模型资源
   */
  async unload(): Promise<void> {
    if (this.model) {
      this.model = null;
      this.modelLoaded = false;
      console.info('MindSporeEmbeddingService: Model unloaded');
    }
  }
}

/**
 * 初始化 MindSpore Embedding 服务
 */
export async function initMindSporeEmbeddingServices(context: common.Context): Promise<void> {
  const l6Service = new MindSporeEmbeddingService('minilm-l6-v2', context);
  const l12Service = new MindSporeEmbeddingService('minilm-l12-v2', context);

  // 注册服务
  EmbeddingServiceFactory.register(l6Service.getName(), l6Service);
  EmbeddingServiceFactory.register(l12Service.getName(), l12Service);

  console.info('MindSporeEmbeddingService: Services registered');
}