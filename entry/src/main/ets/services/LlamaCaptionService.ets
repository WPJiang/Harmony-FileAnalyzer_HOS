import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { LlamaNapi, CaptionGenerationResult } from '../native/LlamaNapi';
import { CaptionResult, CaptionMode, createEmptyCaptionResult } from '../models/CaptionResultModel';
import { PerformanceUtils } from '../utils/PerformanceUtils';

/**
 * 本地Caption服务接口
 */
export interface CaptionServiceInterface {
  generateCaption(imagePath: string): Promise<CaptionResult>;
  getName(): string;
  isAvailable(): Promise<boolean>;
  loadModel(): Promise<boolean>;
}

/**
 * Caption服务工厂
 */
export class CaptionServiceFactory {
  private static services: Map<string, CaptionServiceInterface> = new Map();

  static register(name: string, service: CaptionServiceInterface): void {
    CaptionServiceFactory.services.set(name, service);
  }

  static get(name: string): CaptionServiceInterface | undefined {
    return CaptionServiceFactory.services.get(name);
  }

  static getAllServiceNames(): string[] {
    return Array.from(CaptionServiceFactory.services.keys());
  }
}

/**
 * Llama.cpp 本地Caption服务实现
 * 使用 llama.cpp 运行 Qwen3.5 0.8B 多模态模型
 */
export class LlamaCaptionService implements CaptionServiceInterface {
  private context: common.Context;
  private llamaNapi: LlamaNapi;
  private modelLoaded: boolean = false;
  private quantization: 'Q4' | 'Q8' = 'Q4';

  // 模型文件路径
  private modelFileName: string = 'caption/qwen_0.8b_q4.gguf';
  private mmprojFileName: string = 'caption/mmproj.gguf';

  constructor(context: common.Context) {
    this.context = context;
    this.llamaNapi = new LlamaNapi();
  }

  getName(): string {
    return `llama_qwen_${this.quantization.toLowerCase()}`;
  }

  async isAvailable(): Promise<boolean> {
    return this.modelLoaded;
  }

  /**
   * 加载模型
   * 优先从 filesDir 加载，如果不存在则从 rawfile 复制到 filesDir 后加载
   */
  async loadModel(): Promise<boolean> {
    if (this.modelLoaded) {
      return true;
    }

    const startTime = PerformanceUtils.startTimer();
    console.info('LlamaCaptionService: Starting to load model...');

    try {
      const filesDir = this.context.filesDir;
      const modelPath = `${filesDir}/qwen_0.8b_q4.gguf`;
      const mmprojPath = `${filesDir}/mmproj.gguf`;

      // 检查 filesDir 中是否已有模型文件
      let needCopy = false;
      try {
        const modelStat = fileIo.statSync(modelPath);
        const mmprojStat = fileIo.statSync(mmprojPath);
        if (modelStat.size > 0 && mmprojStat.size > 0) {
          console.info(`LlamaCaptionService: Model files exist in filesDir, model=${modelStat.size}, mmproj=${mmprojStat.size}`);
        } else {
          needCopy = true;
        }
      } catch (e) {
        console.info(`LlamaCaptionService: Model not in filesDir, will copy from rawfile`);
        needCopy = true;
      }

      // 从 rawfile 复制到 filesDir（分块写入，避免大文件OOM）
      if (needCopy) {
        console.info('LlamaCaptionService: Copying model files from rawfile to filesDir (chunked)...');
        try {
          const CHUNK_SIZE = 4 * 1024 * 1024; // 4MB chunks

          // 复制主模型（~530MB，分块处理）
          console.info(`LlamaCaptionService: Copying ${this.modelFileName}...`);
          await this.copyRawfileToFilesDir(this.modelFileName, modelPath, CHUNK_SIZE);

          // 复制 mmproj 模型（~205MB，分块处理）
          console.info(`LlamaCaptionService: Copying ${this.mmprojFileName}...`);
          await this.copyRawfileToFilesDir(this.mmprojFileName, mmprojPath, CHUNK_SIZE);
        } catch (copyErr) {
          console.error(`LlamaCaptionService: Failed to copy model files: ${JSON.stringify(copyErr)}`);
          return false;
        }
      }

      // 从 filesDir 加载模型
      console.info(`LlamaCaptionService: Loading model from filesDir...`);
      const loaded = await this.llamaNapi.loadModel(modelPath, mmprojPath);

      if (loaded) {
        this.modelLoaded = true;
        const loadTime = PerformanceUtils.endTimer(startTime);
        console.info(`LlamaCaptionService: Model loaded successfully in ${loadTime}ms`);
        return true;
      }

      console.error('LlamaCaptionService: Model loading failed');
      return false;
    } catch (error) {
      console.error('LlamaCaptionService.loadModel failed:', error);
      return false;
    }
  }

  /**
   * 生成图片描述
   */
  async generateCaption(imagePath: string): Promise<CaptionResult> {
    const result = createEmptyCaptionResult(this.quantization);
    const startTime = PerformanceUtils.startTimer();

    if (!this.modelLoaded) {
      result.errorMessage = 'Model not loaded';
      return result;
    }

    try {
      // 1. 打开图片文件
      const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(file.fd);
      const pixelMap = await imageSource.createPixelMap();
      await fileIo.close(file.fd);

      // 2. 获取图片数据
      const imageInfo = await imageSource.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;

      // 3. 获取 RGBA 数据
      // 需要将 PixelMap 转换为 ArrayBuffer
      const imageData = await this.getPixelMapData(pixelMap);

      // 4. 调用 llama.cpp 生成描述
      console.info(`LlamaCaptionService: Generating caption for ${width}x${height} image...`);
      const genResult: CaptionGenerationResult = await this.llamaNapi.generateCaption(
        imageData,
        width,
        height,
        128
      );

      // 5. 填充结果
      result.caption = genResult.caption;
      result.tokensPerSecond = genResult.tokensPerSecond;
      result.tokenCount = genResult.tokenCount;
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = genResult.caption.length > 0;

      // 释放 PixelMap
      pixelMap.release();

      console.info(`LlamaCaptionService: Caption generated: "${result.caption.substring(0, 50)}..."`);

      PerformanceUtils.recordMetric('caption', 'llama_local', result.elapsedTime, result.success);

      return result;
    } catch (error) {
      console.error('LlamaCaptionService.generateCaption failed:', error);
      result.errorMessage = String(error);
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = false;

      PerformanceUtils.recordMetric('caption', 'llama_local', result.elapsedTime, false);

      return result;
    }
  }

  /**
   * 将 rawfile 复制到 filesDir（使用 fd 分块读写，避免大文件 OOM）
   * 通过 resourceManager.getRawFd 获取 rawfile fd，使用 readSync 的 offset 参数定位
   */
  private async copyRawfileToFilesDir(
    rawfilePath: string,
    destPath: string,
    chunkSize: number
  ): Promise<void> {
    console.info(`LlamaCaptionService: Copying rawfile ${rawfilePath} to ${destPath} via fd...`);

    // 通过 resourceManager 获取 rawfile 的文件描述符（fd + offset + length）
    const rawFd = await this.context.resourceManager.getRawFd(rawfilePath);
    console.info(`LlamaCaptionService: RawFd: fd=${rawFd.fd}, offset=${rawFd.offset}, length=${rawFd.length}`);

    // 删除已有目标文件，创建新文件
    try { fileIo.unlinkSync(destPath); } catch (_) {}
    const destFile = fileIo.openSync(destPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);

    try {
      const totalSize = rawFd.length;
      let remaining = totalSize;
      let totalWritten = 0;

      while (remaining > 0) {
        const readSize = Math.min(chunkSize, remaining);
        const buffer = new ArrayBuffer(readSize);

        // 从 rawfile fd 读取，使用 offset 定位（rawFd.offset + 当前位置）
        const bytesRead = fileIo.readSync(rawFd.fd, buffer, {
          offset: rawFd.offset + totalWritten,
          length: readSize
        });

        if (bytesRead === 0) {
          console.warn(`LlamaCaptionService: Read 0 bytes, ${totalWritten}/${totalSize} written`);
          break;
        }

        // 写入目标文件
        fileIo.writeSync(destFile.fd, buffer, { length: bytesRead });

        totalWritten += bytesRead;
        remaining -= bytesRead;

        // 每 100MB 记录进度
        if (Math.floor(totalWritten / (100 * 1024 * 1024)) >
          Math.floor((totalWritten - bytesRead) / (100 * 1024 * 1024))) {
          console.info(`LlamaCaptionService: ${totalWritten}/${totalSize} (${Math.round(totalWritten * 100 / totalSize)}%)`);
        }
      }

      fileIo.closeSync(destFile.fd);
      await this.context.resourceManager.closeRawFd(rawfilePath);

      const destStat = fileIo.statSync(destPath);
      console.info(`LlamaCaptionService: Copied ${totalWritten}/${totalSize}, dest: ${destStat.size} bytes`);
    } catch (e) {
      const errMsg = `Copy failed: ${JSON.stringify(e)}`;
      console.error(`LlamaCaptionService: ${errMsg}`);
      try { fileIo.closeSync(destFile.fd); } catch (_) {}
      try { await this.context.resourceManager.closeRawFd(rawfilePath); } catch (_) {}
      throw new Error(errMsg);
    }
  }

  /**
   * 从 PixelMap 提取 RGBA 数据
   */
  private async getPixelMapData(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    try {
      const imageInfo = await pixelMap.getImageInfo();
      const bytesPerPixel = 4; // RGBA
      const bufferSize = imageInfo.size.width * imageInfo.size.height * bytesPerPixel;
      const buffer = new ArrayBuffer(bufferSize);

      // 使用 readPixelsToBuffer API
      await pixelMap.readPixelsToBuffer(buffer);
      return buffer;
    } catch (e) {
      console.error('LlamaCaptionService: Failed to get pixel map data:', e);
      // 返回空 buffer 作为后备
      return new ArrayBuffer(0);
    }
  }

  /**
   * 从 PixelMap 生成图片描述（已缩放的图片）
   * 由 LocalImageAnalysisService 调用，图片已经完成缩放处理
   */
  async generateCaptionFromPixelMap(pixelMap: image.PixelMap): Promise<CaptionResult> {
    const result = createEmptyCaptionResult(this.quantization);
    const startTime = PerformanceUtils.startTimer();

    if (!this.modelLoaded) {
      result.errorMessage = 'Model not loaded';
      return result;
    }

    try {
      // 1. 获取图片信息
      const imageInfo = await pixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;

      // 2. 获取 RGBA 数据
      const imageData = await this.getPixelMapData(pixelMap);

      // 3. 调用 llama.cpp 生成描述
      console.info(`LlamaCaptionService: Generating caption for ${width}x${height} image (from PixelMap)...`);
      const genResult: CaptionGenerationResult = await this.llamaNapi.generateCaption(
        imageData,
        width,
        height,
        128
      );

      // 4. 填充结果
      result.caption = genResult.caption;
      result.tokensPerSecond = genResult.tokensPerSecond;
      result.tokenCount = genResult.tokenCount;
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = genResult.caption.length > 0;

      console.info(`LlamaCaptionService: Caption generated: "${result.caption.substring(0, 50)}..."`);

      PerformanceUtils.recordMetric('caption', 'llama_local', result.elapsedTime, result.success);

      return result;
    } catch (error) {
      console.error('LlamaCaptionService.generateCaptionFromPixelMap failed:', error);
      result.errorMessage = String(error);
      result.elapsedTime = PerformanceUtils.endTimer(startTime);
      result.success = false;

      PerformanceUtils.recordMetric('caption', 'llama_local', result.elapsedTime, false);

      return result;
    }
  }

  /**
   * 释放模型资源
   */
  async unload(): Promise<void> {
    if (this.llamaNapi) {
      await this.llamaNapi.unloadModel();
      this.modelLoaded = false;
      console.info('LlamaCaptionService: Model unloaded');
    }
  }
}

/**
 * 初始化本地 Caption 服务
 */
export async function initLlamaCaptionService(context: common.Context): Promise<void> {
  const service = new LlamaCaptionService(context);
  CaptionServiceFactory.register(service.getName(), service);
  console.info('LlamaCaptionService: Service registered');
}