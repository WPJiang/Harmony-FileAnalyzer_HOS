/**
 * Caption Worker
 * 在独立 Worker 线程中运行 llama.cpp 图片描述生成
 * 避免 generateCaption() 阻塞主线程
 *
 * Worker 保持模型加载状态，无需每次重新加载
 */

import { worker } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { LlamaNapi, CaptionGenerationResult } from '../native/LlamaNapi';

// Worker 消息类型
interface WorkerMessage {
  type: 'init' | 'generateCaption' | 'release';
  requestId?: string;
  data: InitData | CaptionData;
}

interface InitData {
  modelPath: string;
  mmprojPath: string;
}

interface CaptionData {
  imagePath: string;
  maxTokens?: number;
}

interface WorkerResponse {
  type: 'initResult' | 'captionResult' | 'error';
  requestId?: string;
  success: boolean;
  data: CaptionResultData | null;
  message: string;
}

interface CaptionResultData {
  caption: string;
  tokensPerSecond: number;
  tokenCount: number;
}

// 图片数据类型
interface ImageDataResult {
  data: ArrayBuffer;
  width: number;
  height: number;
}

// 全局状态（在 Worker 线程中保持）
let llamaNapi: LlamaNapi | null = null;
let modelLoaded: boolean = false;

// Worker 端口
const workerPort = worker.workerPort;

// 消息事件类型
interface WorkerMessageEvent {
  data: WorkerMessage;
}

/**
 * 加载模型
 */
async function loadModel(modelPath: string, mmprojPath: string): Promise<boolean> {
  try {
    // 检查模型文件是否存在
    try {
      const modelStat = await fileIo.stat(modelPath);
      const mmprojStat = await fileIo.stat(mmprojPath);
      console.info('[CaptionWorker] Model files exist, model:', modelStat.size, 'mmproj:', mmprojStat.size);
    } catch (e) {
      console.error('[CaptionWorker] Model files not found:', e);
      return false;
    }

    // 创建 LlamaNapi 实例并加载模型
    llamaNapi = new LlamaNapi();
    const loaded = await llamaNapi.loadModel(modelPath, mmprojPath);

    if (loaded) {
      modelLoaded = true;
      console.info('[CaptionWorker] Model loaded successfully in Worker thread');
      return true;
    } else {
      console.error('[CaptionWorker] Model loading failed');
      return false;
    }
  } catch (e) {
    console.error('[CaptionWorker] Model load failed:', e);
    return false;
  }
}

/**
 * 从图片文件提取 RGBA 数据
 */
async function getImageData(imagePath: string): Promise<ImageDataResult | null> {
  try {
    const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);
    const imageSource = image.createImageSource(file.fd);
    const pixelMap = await imageSource.createPixelMap();
    const imageInfo = await imageSource.getImageInfo();

    // 获取 RGBA 数据
    const width = imageInfo.size.width;
    const height = imageInfo.size.height;
    const bufferSize = width * height * 4;
    const buffer = new ArrayBuffer(bufferSize);

    await pixelMap.readPixelsToBuffer(buffer);
    await fileIo.close(file.fd);
    pixelMap.release();

    return { data: buffer, width, height };
  } catch (e) {
    console.error('[CaptionWorker] Failed to get image data:', e);
    return null;
  }
}

/**
 * 生成图片描述
 */
async function generateCaptionInWorker(imagePath: string, maxTokens: number): Promise<CaptionResultData | null> {
  if (!modelLoaded || !llamaNapi) {
    console.error('[CaptionWorker] Model not loaded');
    return null;
  }

  try {
    // 1. 提取图片数据
    const imageData = await getImageData(imagePath);
    if (!imageData) {
      console.error('[CaptionWorker] Failed to extract image data');
      return null;
    }

    console.info('[CaptionWorker] Image data extracted:', imageData.width, 'x', imageData.height);

    // 2. 调用 llamaNapi 生成描述（在 Worker 线程中执行）
    const result: CaptionGenerationResult = await llamaNapi.generateCaption(
      imageData.data,
      imageData.width,
      imageData.height,
      maxTokens
    );

    console.info('[CaptionWorker] Caption generated:', result.caption.substring(0, 50));

    return {
      caption: result.caption,
      tokensPerSecond: result.tokensPerSecond,
      tokenCount: result.tokenCount
    };
  } catch (e) {
    console.error('[CaptionWorker] Caption generation failed:', e);
    return null;
  }
}

/**
 * Worker 消息处理
 */
workerPort.onmessage = async (e: WorkerMessageEvent) => {
  const msg = e.data as WorkerMessage;
  console.info('[CaptionWorker] Received message:', msg.type, 'requestId:', msg.requestId);

  try {
    if (msg.type === 'init') {
      const initData = msg.data as InitData;
      console.info('[CaptionWorker] Initializing with model:', initData.modelPath);

      const loaded = await loadModel(initData.modelPath, initData.mmprojPath);

      workerPort.postMessage({
        type: 'initResult',
        requestId: msg.requestId,
        success: loaded,
        data: null,
        message: loaded ? 'Model loaded in Worker' : 'Model initialization failed'
      } as WorkerResponse);
    }
    else if (msg.type === 'generateCaption') {
      const captionData = msg.data as CaptionData;
      const maxTokens = captionData.maxTokens || 128;

      const result = await generateCaptionInWorker(captionData.imagePath, maxTokens);

      if (result) {
        workerPort.postMessage({
          type: 'captionResult',
          requestId: msg.requestId,
          success: true,
          data: result,
          message: 'Caption generated successfully'
        } as WorkerResponse);
      } else {
        workerPort.postMessage({
          type: 'captionResult',
          requestId: msg.requestId,
          success: false,
          data: null,
          message: 'Caption generation failed'
        } as WorkerResponse);
      }
    }
    else if (msg.type === 'release') {
      if (llamaNapi) {
        await llamaNapi.unloadModel();
        llamaNapi = null;
      }
      modelLoaded = false;

      workerPort.postMessage({
        type: 'initResult',
        requestId: msg.requestId,
        success: true,
        data: null,
        message: 'Worker released'
      } as WorkerResponse);
    }
  } catch (e) {
    workerPort.postMessage({
      type: 'error',
      requestId: msg.requestId,
      success: false,
      data: null,
      message: String(e)
    } as WorkerResponse);
  }
};