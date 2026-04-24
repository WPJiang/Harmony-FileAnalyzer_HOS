/**
 * LocalImageAnalysisService - 本地图片分析服务
 *
 * 功能：
 * 1. 图片时空分析 - 提取EXIF元数据（拍摄时间、GPS位置、设备信息等）
 * 2. 图片Caption生成 - 支持端侧(llama.cpp)和云端(LLM API)两种模式
 */

import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { ZipReader, ZipEntry } from '../parser/ZipReader';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { worker } from '@kit.ArkTS';
import common from '@ohos.app.ability.common';
import { CaptionMode } from '../models/CaptionResultModel';
import { LlamaCaptionService, CaptionServiceFactory, initLlamaCaptionService } from './LlamaCaptionService';
import { EnhancedGeocoder, getEnhancedGeocoder, reverseGeocode, reverseGeocodeSync } from '../utils/OfflineGeocoder';

export interface ImageMetadata {
  fileName: string;
  fileSize: number;
  width: number;
  height: number;
  format: string;
  // EXIF信息
  dateTime?: string;           // 拍摄时间
  make?: string;               // 设备制造商
  model?: string;              // 设备型号
  orientation?: number;        // 方向
  gpsLatitude?: number;        // GPS纬度
  gpsLongitude?: number;       // GPS经度
  gpsAltitude?: number;        // GPS海拔
  exposureTime?: string;       // 曝光时间
  fNumber?: number;            // 光圈值
  iso?: number;                // ISO感光度
  focalLength?: number;        // 焦距
  flash?: number;              // 闪光灯
  whiteBalance?: number;       // 白平衡
}

export interface SpatiotemporalResult {
  fileId: number;
  fileName: string;
  metadata: ImageMetadata;
  originalCreatedTime: string;
  location: string;
  analysisStatus: string;
}

/**
 * 云端Caption生成结果（用于向后兼容）
 */
export interface CaptionResult {
  fileId: number;
  fileName: string;
  caption: string;
  confidence: number;
  tags: string[];
}

/**
 * Caption服务模式
 */
export type CaptionServiceMode = CaptionMode.LOCAL | CaptionMode.CLOUD;

interface LLMProviderConfig {
  endpoint: string;
  model: string;
}

interface LLMResponse {
  description: string;
  confidence: number;
  tags: string[];
}

interface ImageDataItem {
  path: string;
  id: number;
}

// Caption Worker 数据类型
interface CaptionWorkerData {
  caption: string;
  tokensPerSecond: number;
  tokenCount: number;
}

// Caption Worker 响应类型
interface CaptionWorkerResponse {
  type: 'initResult' | 'captionResult' | 'error';
  requestId?: string;
  success: boolean;
  data: CaptionWorkerData | null;
  message: string;
}

// Worker 消息事件类型
interface WorkerMessageEvent {
  data: CaptionWorkerResponse;
}

// Worker 错误事件类型
interface WorkerErrorEvent {
  message: string;
}

// Caption pending request callback 类型
interface CaptionPendingCallback {
  resolve: (data: CaptionWorkerData) => void;
  reject: (err: Error) => void;
}

export class LocalImageAnalysisService {
  private context: common.Context | null = null;
  private apiKey: string = '';
  private apiEndpoint: string = 'https://api.openai.com/v1/chat/completions';
  private modelName: string = 'gpt-4o';
  private timeout: number = 60;
  private maxTokens: number = 4096;
  private temperature: number = 0.7;

  // Caption模式：LOCAL(端侧llama.cpp) 或 CLOUD(云端LLM API)
  private captionMode: CaptionMode = CaptionMode.CLOUD;
  private localCaptionService: LlamaCaptionService | null = null;
  private localCaptionLoaded: boolean = false;

  // 图片缩放最大尺寸（与AItest项目一致，默认512）
  private maxDimension: number = 512;

  // 增强地理编码器（与Python EnhancedGeocoder一致）
  private enhancedGeocoder: EnhancedGeocoder = getEnhancedGeocoder();

  // Caption Worker（用于非阻塞推理）
  private captionWorker: worker.ThreadWorker | null = null;
  private captionWorkerReady: boolean = false;
  private captionPendingRequests: Map<string, CaptionPendingCallback> = new Map();
  private captionRequestId: number = 0;

  // 支持的LLM提供商
  private llmProviders: Map<string, LLMProviderConfig> = new Map<string, LLMProviderConfig>();

  constructor() {
    // 初始化提供商配置
    this.llmProviders.set('openai', { endpoint: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' });
    this.llmProviders.set('deepseek', { endpoint: 'https://api.deepseek.com/v1/chat/completions', model: 'deepseek-chat' });
    this.llmProviders.set('qwen', { endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen3-vl-32b-thinking' });
    this.llmProviders.set('custom', { endpoint: '', model: '' });
  }

  private currentProvider: string = 'openai';

  setContext(context: common.Context): void {
    this.context = context;
    // 初始化本地Caption服务
    if (context) {
      this.localCaptionService = new LlamaCaptionService(context);
      // 注意：Caption Worker 暂时禁用 - llama.cpp NAPI 在 Worker 线程存在内存安全问题
      // 使用主线程异步模式代替
      // this.initCaptionWorker();
    }
  }

  /**
   * 初始化 Caption Worker（暂时禁用）
   * 注意：llama.cpp NAPI 在 Worker 线程存在内存管理问题（double free）
   * 暂时使用主线程异步模式
   */
  private async initCaptionWorker(): Promise<void> {
    if (!this.context) return;

    try {
      // 创建 Worker
      this.captionWorker = new worker.ThreadWorker('entry/ets/workers/CaptionWorker.ets');

      // 设置消息处理回调
      this.captionWorker.onmessage = (e: WorkerMessageEvent) => {
        const response = e.data as CaptionWorkerResponse;
        const requestId = response.requestId || '';

        if (requestId && this.captionPendingRequests.has(requestId)) {
          const callback = this.captionPendingRequests.get(requestId);
          this.captionPendingRequests.delete(requestId);

          if (response.success && response.data) {
            callback?.resolve(response.data);
          } else {
            callback?.reject(new Error(response.message));
          }
        } else if (response.type === 'initResult') {
          this.captionWorkerReady = response.success;
          console.info('[LocalImageAnalysis] CaptionWorker init result:', response.success);
        }
      };

      // 设置错误处理
      this.captionWorker.onerror = (e: WorkerErrorEvent) => {
        console.error('[LocalImageAnalysis] CaptionWorker error:', e.message);
        this.captionPendingRequests.forEach((callback, id) => {
          callback.reject(new Error('CaptionWorker error: ' + e.message));
        });
        this.captionPendingRequests.clear();
      };

      // 发送初始化消息
      const filesDir = this.context.filesDir;
      const modelPath = `${filesDir}/qwen_0.8b_q4.gguf`;
      const mmprojPath = `${filesDir}/mmproj.gguf`;

      this.captionWorker.postMessage({
        type: 'init',
        requestId: 'init',
        data: {
          modelPath: modelPath,
          mmprojPath: mmprojPath
        }
      });

      // 等待初始化完成（最多30秒）
      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error('CaptionWorker init timeout'));
        }, 30000);

        const checkReady = () => {
          if (this.captionWorkerReady) {
            clearTimeout(timeout);
            resolve();
          } else {
            setTimeout(checkReady, 100);
          }
        };
        checkReady();
      });

      console.info('[LocalImageAnalysis] CaptionWorker initialized');
    } catch (err) {
      console.error('[LocalImageAnalysis] CaptionWorker init failed:', err);
      this.captionWorkerReady = false;
    }
  }

  getContext(): common.Context | null {
    return this.context;
  }

  /**
   * 设置Caption生成模式
   */
  setCaptionMode(mode: CaptionMode): void {
    this.captionMode = mode;
    console.info(`[LocalImageAnalysisService] Caption mode set to: ${mode}`);
  }

  /**
   * 获取当前Caption模式
   */
  getCaptionMode(): CaptionMode {
    return this.captionMode;
  }

  /**
   * 设置图片缩放最大尺寸（与AItest项目一致）
   * 默认值512，推荐值: 256(快速), 512(平衡), 768(高质量)
   */
  setMaxDimension(dimension: number): void {
    this.maxDimension = dimension > 0 ? dimension : 512;
    console.info(`[LocalImageAnalysisService] Max dimension set to: ${this.maxDimension}`);
  }

  /**
   * 获取当前图片缩放最大尺寸
   */
  getMaxDimension(): number {
    return this.maxDimension;
  }

  /**
   * 缩放图片到指定最大尺寸（保持长宽比，与Python _resize_image_if_needed一致）
   * @param pixelMap 原始图片
   * @returns 缩放后的PixelMap
   */
  private async resizeImageIfNeeded(pixelMap: image.PixelMap): Promise<image.PixelMap> {
    const imageInfo = await pixelMap.getImageInfo();
    const originalWidth = imageInfo.size.width;
    const originalHeight = imageInfo.size.height;

    // 如果图片尺寸在限制内，直接返回原图
    if (originalWidth <= this.maxDimension && originalHeight <= this.maxDimension) {
      console.info(`[LocalImageAnalysis] Image size ${originalWidth}x${originalHeight} within limit, no resize needed`);
      return pixelMap;
    }

    // 计算缩放比例（与Python一致：ratio = min(max_dimension / width, max_dimension / height)）
    const ratio = Math.min(this.maxDimension / originalWidth, this.maxDimension / originalHeight);
    const newWidth = Math.floor(originalWidth * ratio);
    const newHeight = Math.floor(originalHeight * ratio);

    console.info(`[LocalImageAnalysis] Resizing image from ${originalWidth}x${originalHeight} to ${newWidth}x${newHeight} (ratio=${ratio.toFixed(3)})`);

    // 使用PixelMap的scale方法进行缩放
    await pixelMap.scale(ratio, ratio);

    return pixelMap;
  }

  /**
   * 加载本地Caption模型
   */
  async loadLocalCaptionModel(): Promise<boolean> {
    if (!this.localCaptionService) {
      console.error('[LocalImageAnalysisService] Context not set, cannot load model');
      return false;
    }
    this.localCaptionLoaded = await this.localCaptionService.loadModel();
    return this.localCaptionLoaded;
  }

  /**
   * 检查本地Caption服务是否可用
   */
  isLocalCaptionAvailable(): boolean {
    return this.localCaptionLoaded && this.localCaptionService !== null;
  }

  setApiKey(apiKey: string): void {
    this.apiKey = apiKey;
  }

  setTimeout(timeout: number): void {
    this.timeout = timeout;
  }

  setMaxTokens(maxTokens: number): void {
    this.maxTokens = maxTokens;
  }

  setTemperature(temperature: number): void {
    this.temperature = temperature;
  }

  setProvider(provider: string, endpoint?: string, model?: string): void {
    this.currentProvider = provider;
    if (endpoint) {
      this.apiEndpoint = endpoint;
    } else if (this.llmProviders.has(provider)) {
      this.apiEndpoint = this.llmProviders.get(provider)!.endpoint;
    }
    if (model) {
      this.modelName = model;
    } else if (this.llmProviders.has(provider)) {
      this.modelName = this.llmProviders.get(provider)!.model;
    }
  }

  /**
   * 提取图片元数据（时空分析）
   */
  async extractImageMetadata(imagePath: string): Promise<ImageMetadata> {
    try {
      console.info('[LocalImageAnalysis] Extracting metadata from:', imagePath);

      // 检查是否是 livp 格式（Live Photo）
      const ext = imagePath.toLowerCase().split('.').pop() || '';
      if (ext === 'livp') {
        return await this.extractLivpMetadata(imagePath);
      }

      // 打开文件
      const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);

      // 创建图像源
      const imageSource = image.createImageSource(file.fd);

      // 获取图片信息
      const imageInfo = await imageSource.getImageInfo();
      const frameCount = await imageSource.getFrameCount();

      // 尝试获取EXIF数据
      let exifData: Record<string, string> = {};
      try {
        exifData = await this.extractExifData(imageSource);
      } catch (e) {
        console.warn('[LocalImageAnalysis] EXIF extraction failed:', e);
      }

      // 关闭文件
      await fileIo.close(file.fd);

      // 提取文件名
      const fileName = imagePath.split('/').pop() || 'unknown';

      // 构建元数据对象
      const metadata: ImageMetadata = {
        fileName: fileName,
        fileSize: stat.size,
        width: imageInfo.size.width,
        height: imageInfo.size.height,
        format: imageInfo.mimeType || 'unknown'
      };

      // 填充EXIF数据
      // 拍摄时间：优先EXIF，其次从文件名解析
      if (exifData['DateTimeOriginal']) {
        metadata.dateTime = this.formatExifTime(exifData['DateTimeOriginal']);
      } else if (exifData['DateTime']) {
        metadata.dateTime = this.formatExifTime(exifData['DateTime']);
      } else {
        // EXIF中没有时间，尝试从文件名解析
        const filenameTime = this.parseTimeFromFilename(imagePath);
        if (filenameTime) {
          metadata.dateTime = filenameTime;
          console.info('[LocalImageAnalysis] Time parsed from filename:', filenameTime);
        }
      }
      if (exifData['Make']) {
        metadata.make = exifData['Make'];
      }
      if (exifData['Model']) {
        metadata.model = exifData['Model'];
      }
      if (exifData['Orientation']) {
        metadata.orientation = parseInt(exifData['Orientation']);
      }
      if (exifData['GPSLatitude']) {
        metadata.gpsLatitude = this.parseGpsCoordinate(exifData['GPSLatitude'], exifData['GPSLatitudeRef']);
      }
      if (exifData['GPSLongitude']) {
        metadata.gpsLongitude = this.parseGpsCoordinate(exifData['GPSLongitude'], exifData['GPSLongitudeRef']);
      }
      if (exifData['GPSAltitude']) {
        metadata.gpsAltitude = parseFloat(exifData['GPSAltitude']);
      }
      if (exifData['ExposureTime']) {
        metadata.exposureTime = exifData['ExposureTime'];
      }
      if (exifData['FNumber']) {
        metadata.fNumber = this.parseRational(exifData['FNumber']);
      }
      if (exifData['ISOSpeedRatings'] || exifData['ISO']) {
        metadata.iso = parseInt(exifData['ISOSpeedRatings'] || exifData['ISO']);
      }
      if (exifData['FocalLength']) {
        metadata.focalLength = this.parseRational(exifData['FocalLength']);
      }

      console.info('[LocalImageAnalysis] Metadata extracted:', JSON.stringify(metadata));
      return metadata;

    } catch (err) {
      console.error('[LocalImageAnalysis] Failed to extract metadata:', err);
      throw new Error('Failed to extract image metadata: ' + (err as Error).message);
    }
  }

  /**
   * 提取 Live Photo (.livp) 格式的元数据
   * livp 是 Apple Live Photo 格式，包含静态图片和视频的 ZIP 文件
   */
  private async extractLivpMetadata(livpPath: string): Promise<ImageMetadata> {
    console.info('[LocalImageAnalysis] Extracting livp metadata from:', livpPath);

    // 提取文件名
    const fileName = livpPath.split('/').pop() || 'unknown';

    // 获取文件大小
    let fileSize = 0;
    try {
      const file = await fileIo.open(livpPath, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      fileSize = stat.size;
      await fileIo.close(file.fd);
    } catch (e) {
      console.warn('[LocalImageAnalysis] Failed to get livp file size:', e);
    }

    const metadata: ImageMetadata = {
      fileName: fileName,
      fileSize: fileSize,
      width: 0,
      height: 0,
      format: 'live_photo'
    };

    try {
      // 使用 ZipReader 解压 livp 文件
      const entries = await ZipReader.readZipFile(livpPath);
      const entryNames = Array.from(entries.keys());
      console.info('[LocalImageAnalysis] livp entries:', entryNames);

      // 查找图片文件（通常是 HEIC 或 JPEG）
      const imageExtensions = ['.heic', '.heif', '.jpg', '.jpeg'];
      let imageFileName = '';

      for (const name of entryNames) {
        const entryExt = '.' + (name.split('.').pop()?.toLowerCase() || '');
        if (imageExtensions.includes(entryExt)) {
          imageFileName = name;
          break;
        }
      }

      if (!imageFileName) {
        console.warn('[LocalImageAnalysis] No image found in livp');
        // 至少可以从文件名解析时间
        const filenameTime = this.parseTimeFromFilename(livpPath);
        if (filenameTime) {
          metadata.dateTime = filenameTime;
          console.info('[LocalImageAnalysis] Time parsed from livp filename:', filenameTime);
        }
        return metadata;
      }

      const imageEntry = entries.get(imageFileName);
      if (!imageEntry || !imageEntry.data) {
        console.warn('[LocalImageAnalysis] Image entry has no data');
        const filenameTime = this.parseTimeFromFilename(livpPath);
        if (filenameTime) {
          metadata.dateTime = filenameTime;
        }
        return metadata;
      }

      const imageData = imageEntry.data;
      console.info('[LocalImageAnalysis] Found image in livp:', imageFileName, 'size:', imageData.length);

      // 创建临时文件来提取内部图片的元数据
      const context = this.getContext();
      if (!context) {
        console.warn('[LocalImageAnalysis] No context available for temp file');
        const filenameTime = this.parseTimeFromFilename(livpPath);
        if (filenameTime) {
          metadata.dateTime = filenameTime;
        }
        return metadata;
      }

      const tempDir = context.cacheDir || '/data/storage/el2/base/cache';
      const imageExt = imageFileName.split('.').pop() || 'jpg';
      const tempImagePath = `${tempDir}/livp_meta_${Date.now()}.${imageExt}`;
      console.info('[LocalImageAnalysis] Writing temp image to:', tempImagePath);

      // 写入临时文件
      const tempFile = await fileIo.open(tempImagePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      const buffer = new ArrayBuffer(imageData.length);
      const view = new Uint8Array(buffer);
      for (let i = 0; i < imageData.length; i++) {
        view[i] = imageData[i];
      }
      await fileIo.write(tempFile.fd, buffer);
      await fileIo.close(tempFile.fd);

      // 提取内部图片的元数据
      try {
        const innerFile = await fileIo.open(tempImagePath, fileIo.OpenMode.READ_ONLY);
        const innerStat = await fileIo.stat(innerFile.fd);
        const imageSource = image.createImageSource(innerFile.fd);
        const imageInfo = await imageSource.getImageInfo();

        metadata.width = imageInfo.size.width;
        metadata.height = imageInfo.size.height;
        metadata.format = imageInfo.mimeType || 'image/' + imageExt;

        // 尝试提取 EXIF 数据
        let exifData: Record<string, string> = {};
        try {
          exifData = await this.extractExifData(imageSource);
        } catch (e) {
          console.warn('[LocalImageAnalysis] EXIF extraction from inner image failed:', e);
        }

        await fileIo.close(innerFile.fd);

        // 填充 EXIF 数据
        if (exifData['DateTimeOriginal']) {
          metadata.dateTime = this.formatExifTime(exifData['DateTimeOriginal']);
        } else if (exifData['DateTime']) {
          metadata.dateTime = this.formatExifTime(exifData['DateTime']);
        } else {
          // EXIF中没有时间，尝试从文件名解析
          const filenameTime = this.parseTimeFromFilename(livpPath);
          if (filenameTime) {
            metadata.dateTime = filenameTime;
            console.info('[LocalImageAnalysis] Time parsed from filename:', filenameTime);
          }
        }

        if (exifData['Make']) {
          metadata.make = exifData['Make'];
        }
        if (exifData['Model']) {
          metadata.model = exifData['Model'];
        }
        if (exifData['GPSLatitude']) {
          metadata.gpsLatitude = this.parseGpsCoordinate(exifData['GPSLatitude'], exifData['GPSLatitudeRef']);
        }
        if (exifData['GPSLongitude']) {
          metadata.gpsLongitude = this.parseGpsCoordinate(exifData['GPSLongitude'], exifData['GPSLongitudeRef']);
        }

        console.info('[LocalImageAnalysis] livp metadata extracted from inner image:', JSON.stringify(metadata));

      } catch (innerErr) {
        console.warn('[LocalImageAnalysis] Failed to extract inner image metadata:', innerErr);
        // 至少从文件名解析时间
        const filenameTime = this.parseTimeFromFilename(livpPath);
        if (filenameTime) {
          metadata.dateTime = filenameTime;
        }
      }

      // 清理临时文件
      try {
        await fileIo.unlink(tempImagePath);
      } catch (e) {
        console.warn('[LocalImageAnalysis] Failed to cleanup temp file:', e);
      }

    } catch (err) {
      console.error('[LocalImageAnalysis] Failed to extract livp metadata:', err);
      // 至少从文件名解析时间
      const filenameTime = this.parseTimeFromFilename(livpPath);
      if (filenameTime) {
        metadata.dateTime = filenameTime;
      }
    }

    return metadata;
  }

  /**
   * 提取EXIF数据
   */
  private async extractExifData(imageSource: image.ImageSource): Promise<Record<string, string>> {
    const exifData: Record<string, string> = {};

    try {
      // 尝试获取所有EXIF标签
      const exifTags = [
        'DateTime', 'DateTimeOriginal', 'Make', 'Model', 'Orientation',
        'GPSLatitude', 'GPSLatitudeRef', 'GPSLongitude', 'GPSLongitudeRef',
        'GPSAltitude', 'ExposureTime', 'FNumber', 'ISOSpeedRatings', 'ISO',
        'FocalLength', 'Flash', 'WhiteBalance', 'Software'
      ];

      for (const tag of exifTags) {
        try {
          const value = await imageSource.getImageProperty(tag);
          if (value && value !== 'undefined') {
            exifData[tag] = value;
          }
        } catch (e) {
          // 标签不存在，跳过
        }
      }
    } catch (e) {
      console.warn('[LocalImageAnalysis] EXIF extraction error:', e);
    }

    return exifData;
  }

  /**
   * 解析GPS坐标
   */
  private parseGpsCoordinate(coordStr: string, ref?: string): number {
    try {
      // 格式: "deg, min, sec" 或 "deg min sec"
      const parts = coordStr.replace(/,/g, ' ').split(/\s+/).filter(s => s);
      if (parts.length >= 3) {
        const deg = parseFloat(parts[0]);
        const min = parseFloat(parts[1]);
        const sec = parseFloat(parts[2]);
        let decimal = deg + min / 60 + sec / 3600;
        if (ref === 'S' || ref === 'W') {
          decimal = -decimal;
        }
        return decimal;
      }
    } catch (e) {
      console.warn('[LocalImageAnalysis] GPS parse error:', e);
    }
    return 0;
  }

  /**
   * 解析分数格式的数值
   */
  private parseRational(value: string): number {
    try {
      if (value.includes('/')) {
        const parts = value.split('/');
        return parseFloat(parts[0]) / parseFloat(parts[1]);
      }
      return parseFloat(value);
    } catch (e) {
      return 0;
    }
  }

  /**
   * 从文件名解析时间
   * 支持多种格式：IMG_20201107_135806, VID_..., WX..., 2020-11-07, etc.
   */
  private parseTimeFromFilename(filePath: string): string {
    // 获取文件名（可能包含URL编码）
    let fileName = filePath.split('/').pop() || '';
    // 手动解码常见的URL编码字符
    fileName = fileName.replace(/%20/g, ' ');
    fileName = fileName.replace(/%25/g, '%');
    fileName = fileName.replace(/%2B/g, '+');
    fileName = fileName.replace(/%2F/g, '/');
    fileName = fileName.replace(/%3A/g, ':');
    fileName = fileName.replace(/%40/g, '@');
    const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.')) || fileName;

    // 使用简单的字符串匹配代替正则表达式对象
    // 格式1: 2020-11-07 135806 或 2020-11-07_135806
    const pattern1 = nameWithoutExt.match(/(\d{4})[-_](\d{2})[-_](\d{2})[\s_]?(\d{2})(\d{2})(\d{2})/);
    if (pattern1 && pattern1.length >= 7) {
      return `${pattern1[1]}-${pattern1[2]}-${pattern1[3]} ${pattern1[4]}:${pattern1[5]}:${pattern1[6]}`;
    }

    // 格式2: 20201107_135806 或 20201107135806
    const pattern2 = nameWithoutExt.match(/(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})/);
    if (pattern2 && pattern2.length >= 7) {
      return `${pattern2[1]}-${pattern2[2]}-${pattern2[3]} ${pattern2[4]}:${pattern2[5]}:${pattern2[6]}`;
    }

    // 格式3: IMG_20201107_135806
    const pattern3 = nameWithoutExt.match(/IMG[_]?(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})/);
    if (pattern3 && pattern3.length >= 7) {
      return `${pattern3[1]}-${pattern3[2]}-${pattern3[3]} ${pattern3[4]}:${pattern3[5]}:${pattern3[6]}`;
    }

    // 格式4: VID_20201107_135806
    const pattern4 = nameWithoutExt.match(/VID[_]?(\d{4})(\d{2})(\d{2})[_]?(\d{2})(\d{2})(\d{2})/);
    if (pattern4 && pattern4.length >= 7) {
      return `${pattern4[1]}-${pattern4[2]}-${pattern4[3]} ${pattern4[4]}:${pattern4[5]}:${pattern4[6]}`;
    }

    // 格式5: WX20201107-135806
    const pattern5 = nameWithoutExt.match(/WX(\d{4})(\d{2})(\d{2})[-_]?(\d{2})(\d{2})(\d{2})/);
    if (pattern5 && pattern5.length >= 7) {
      return `${pattern5[1]}-${pattern5[2]}-${pattern5[3]} ${pattern5[4]}:${pattern5[5]}:${pattern5[6]}`;
    }

    // 格式6: 2020-11-07（仅日期）
    const pattern6 = nameWithoutExt.match(/(\d{4})[-_](\d{2})[-_](\d{2})/);
    if (pattern6 && pattern6.length >= 4) {
      return `${pattern6[1]}-${pattern6[2]}-${pattern6[3]}`;
    }

    return '';
  }

  /**
   * 格式化位置信息 - 同步版本（仅使用离线fallback）
   * 用于UI展示等需要同步结果的场景
   */
  formatLocation(metadata: ImageMetadata): string {
    if (metadata.gpsLatitude && metadata.gpsLongitude) {
      // 使用同步离线编码器（与Python方案4一致）
      const locationName = reverseGeocodeSync(metadata.gpsLatitude, metadata.gpsLongitude);
      if (locationName) {
        return locationName;
      }
      // 如果反查失败，返回坐标格式
      const latDir = metadata.gpsLatitude >= 0 ? 'N' : 'S';
      const lonDir = metadata.gpsLongitude >= 0 ? 'E' : 'W';
      const lat = Math.abs(metadata.gpsLatitude).toFixed(4);
      const lon = Math.abs(metadata.gpsLongitude).toFixed(4);
      return `${lat}°${latDir}, ${lon}°${lonDir}`;
    }
    return '';
  }

  /**
   * 格式化位置信息 - 异步版本（完整Python逻辑）
   * 按优先级：Nominatim API -> 离线 fallback
   * 用于时空分析等需要精确地名的场景
   */
  async formatLocationAsync(metadata: ImageMetadata): Promise<string> {
    if (metadata.gpsLatitude && metadata.gpsLongitude) {
      try {
        // 使用完整流程（与Python reverse_geocode一致）
        const locationName = await reverseGeocode(metadata.gpsLatitude, metadata.gpsLongitude);
        if (locationName) {
          return locationName;
        }
      } catch (e) {
        console.warn('[LocalImageAnalysis] formatLocationAsync failed:', e);
      }
      // 如果反查失败，返回坐标格式
      const latDir = metadata.gpsLatitude >= 0 ? 'N' : 'S';
      const lonDir = metadata.gpsLongitude >= 0 ? 'E' : 'W';
      const lat = Math.abs(metadata.gpsLatitude).toFixed(4);
      const lon = Math.abs(metadata.gpsLongitude).toFixed(4);
      return `${lat}°${latDir}, ${lon}°${lonDir}`;
    }
    return '';
  }

  /**
   * 格式化EXIF时间字符串
   * EXIF格式: "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD HH:MM:SS"
   */
  private formatExifTime(timeStr: string): string {
    if (!timeStr) return '';

    const parts = timeStr.split(' ');
    if (parts.length === 2) {
      const datePart = parts[0].replace(/:/g, '-');
      return datePart + ' ' + parts[1];
    }
    return timeStr.replace(/:/g, '-');
  }

  /**
   * 格式化时间信息
   */
  formatDateTime(metadata: ImageMetadata): string {
    if (metadata.dateTime) {
      // EXIF时间格式: "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD HH:MM:SS"
      const parts = metadata.dateTime.split(' ');
      if (parts.length === 2) {
        const datePart = parts[0].replace(/:/g, '-');
        return datePart + ' ' + parts[1];
      }
      return metadata.dateTime.replace(/:/g, '-');
    }
    return '';
  }

  /**
   * 生成图片描述（Caption）
   * 支持端侧(llama.cpp)和云端(LLM API)两种模式
   */
  async generateCaption(
    imagePath: string,
    fileId: number
  ): Promise<CaptionResult> {
    const fileName = imagePath.split('/').pop() || '';

    console.info('[LocalImageAnalysis] generateCaption called, captionMode:', this.captionMode, 'apiKey:', this.apiKey ? 'set' : 'not set');

    // 根据CaptionMode选择生成方式
    if (this.captionMode === CaptionMode.LOCAL) {
      // 端侧模式：使用 llama.cpp + Qwen3.5 0.8B
      return this.generateCaptionLocal(imagePath, fileId, fileName);
    } else {
      // 云端模式：使用 LLM API
      return this.generateCaptionCloud(imagePath, fileId, fileName);
    }
  }

  /**
   * 端侧Caption生成（Worker 暂时禁用，使用主线程异步模式）
   */
  private async generateCaptionLocal(
    imagePath: string,
    fileId: number,
    fileName: string
  ): Promise<CaptionResult> {
    // Caption Worker 暂时禁用（llama.cpp NAPI 线程安全问题）
    // 直接使用主线程异步模式
    return this.generateCaptionMain(imagePath, fileId, fileName);
  }

  /**
   * 主线程执行 Caption 生成（备选方案）
   */
  private async generateCaptionMain(
    imagePath: string,
    fileId: number,
    fileName: string
  ): Promise<CaptionResult> {
    if (!this.localCaptionLoaded || !this.localCaptionService) {
      // 尝试加载模型
      const loaded = await this.loadLocalCaptionModel();
      if (!loaded) {
        console.warn('[LocalImageAnalysis] Local model not available, falling back to cloud');
        return this.generateCaptionCloud(imagePath, fileId, fileName);
      }
    }

    try {
      console.info('[LocalImageAnalysis] Generating caption on main thread...');

      // 1. 打开图片并进行缩放处理
      const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(file.fd);
      const decodingOptions: image.DecodingOptions = {
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      let pixelMap = await imageSource.createPixelMap(decodingOptions);
      await fileIo.close(file.fd);

      // 2. 缩放图片到maxDimension
      pixelMap = await this.resizeImageIfNeeded(pixelMap);

      // 3. 获取缩放后的图片数据
      const imageInfo = await pixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      const imageData = await this.getPixelMapData(pixelMap);

      console.info(`[LocalImageAnalysis] Image prepared after resize: ${width}x${height}`);

      // 4. 调用本地模型生成caption
      const localResult = await this.localCaptionService!.generateCaptionFromPixelMap(pixelMap);

      // 释放PixelMap
      pixelMap.release();

      return {
        fileId: fileId,
        fileName: fileName,
        caption: localResult.caption,
        confidence: localResult.success ? 0.9 : 0.0,
        tags: []
      };
    } catch (err) {
      console.error('[LocalImageAnalysis] Main thread caption failed:', err);
      // 失败时回退到云端模式（如果有API Key）
      if (this.apiKey) {
        console.info('[LocalImageAnalysis] Falling back to cloud caption...');
        return this.generateCaptionCloud(imagePath, fileId, fileName);
      }
      throw new Error('端侧Caption生成失败: ' + (err as Error).message);
    }
  }

  /**
   * 云端Caption生成（LLM API）
   */
  private async generateCaptionCloud(
    imagePath: string,
    fileId: number,
    fileName: string
  ): Promise<CaptionResult> {
    if (!this.apiKey) {
      throw new Error('请先在设置中配置LLM API密钥');
    }

    try {
      console.info('[LocalImageAnalysis] Generating caption via cloud LLM...');
      console.info('[LocalImageAnalysis] API endpoint:', this.apiEndpoint, 'model:', this.modelName);

      // 1. 打开图片并创建PixelMap
      const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(file.fd);
      const decodingOptions: image.DecodingOptions = {
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      let pixelMap = await imageSource.createPixelMap(decodingOptions);
      await fileIo.close(file.fd);

      // 2. 缩放图片到maxDimension（与Python config image_processing.max_dimension一致）
      pixelMap = await this.resizeImageIfNeeded(pixelMap);
      const imageInfo = await pixelMap.getImageInfo();
      console.info(`[LocalImageAnalysis] Image resized to ${imageInfo.size.width}x${imageInfo.size.height} for cloud caption`);

      // 3. 获取缩放后图片的JPEG数据并转换为base64
      const jpegBuffer = await this.pixelMapToJpegBuffer(pixelMap);
      const base64Helper = new util.Base64Helper();
      const base64 = base64Helper.encodeToStringSync(new Uint8Array(jpegBuffer));

      // 释放PixelMap
      pixelMap.release();

      // 4. 调用LLM API
      const mimeType = 'image/jpeg';
      const caption = await this.callLLMForCaption(base64, mimeType);

      return {
        fileId: fileId,
        fileName: fileName,
        caption: caption.description,
        confidence: caption.confidence,
        tags: caption.tags
      };

    } catch (err) {
      console.error('[LocalImageAnalysis] Cloud caption generation failed:', err);
      throw new Error('云端Caption生成失败: ' + (err as Error).message);
    }
  }

  /**
   * 将PixelMap转换为JPEG格式的ArrayBuffer
   */
  private async pixelMapToJpegBuffer(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    try {
      const imagePackerApi = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 90
      };
      const buffer = await imagePackerApi.packing(pixelMap, packOpts);
      imagePackerApi.release();
      return buffer;
    } catch (e) {
      console.error('[LocalImageAnalysis] Failed to pack PixelMap to JPEG:', e);
      throw new Error('图片打包失败: ' + (e as Error).message);
    }
  }

  /**
   * 从 PixelMap 提取 RGBA 数据（用于本地模型）
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
      console.error('[LocalImageAnalysis] Failed to get pixel map data:', e);
      return new ArrayBuffer(0);
    }
  }

  /**
   * 获取MIME类型
   */
  private getMimeType(ext: string): string {
    const mimeTypes: Record<string, string> = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp'
    };
    return mimeTypes[ext] || 'image/jpeg';
  }

  /**
   * 调用LLM API生成图片描述
   */
  private async callLLMForCaption(
    imageBase64: string,
    mimeType: string
  ): Promise<LLMResponse> {
    return new Promise<LLMResponse>((resolve, reject) => {
      const httpRequest = http.createHttp();

      // 与Python完全一致的请求体格式
      const systemPrompt = '';
      const userMessage = '请用一句话简洁描述这张图片的内容（不超过30字），然后列出3-5个描述图片的关键词。格式：描述：xxx 关键词：xxx, xxx, xxx';
      const imageUrl = `data:${mimeType};base64,${imageBase64}`;

      // 构造请求体JSON字符串（与Python一致，包含system message）
      const requestJson = `{"model":"${this.modelName}","messages":[{"role":"system","content":""},{"role":"user","content":[{"type":"text","text":"${userMessage}"},{"type":"image_url","image_url":{"url":"${imageUrl}"}}]}],"max_tokens":${this.maxTokens},"temperature":${this.temperature}}`;

      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.apiKey}`
      };

      const timeoutMs = this.timeout * 1000;
      // 与Python一致：base_url + /chat/completions
      const requestUrl = this.apiEndpoint.endsWith('/chat/completions')
        ? this.apiEndpoint
        : `${this.apiEndpoint}/chat/completions`;
      console.info('[LocalImageAnalysis] Request URL:', requestUrl);
      httpRequest.request(
        requestUrl,
        {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: requestJson,
          connectTimeout: timeoutMs,
          readTimeout: timeoutMs
        },
        (err, response) => {
          if (err) {
            reject(new Error(`API请求失败: ${err.message}`));
            return;
          }

          try {
            const responseStr = response.result as string;
            console.info(`[LocalImageAnalysis] LLM response length: ${responseStr?.length || 0}, code: ${response.responseCode}`);
            if (!responseStr || responseStr.length === 0) {
              reject(new Error('API返回空响应'));
              return;
            }
            const result: Record<string, Object> = JSON.parse(responseStr) as Record<string, Object>;

            const errorObj = result['error'] as Record<string, Object> | undefined;
            if (errorObj) {
              const errorMsg = errorObj['message'] as string || '未知错误';
              reject(new Error(`API错误: ${errorMsg}`));
              return;
            }

            const choices = result['choices'] as Object[] | undefined;
            let content = '';
            if (choices && choices.length > 0) {
              const choice = choices[0] as Record<string, Object>;
              const message = choice['message'] as Record<string, Object>;
              content = message['content'] as string || '';
            }

            // 尝试解析JSON响应
            try {
              // 提取JSON部分
              const regex = /\{[\s\S]*\}/;
              const matchResult = regex.exec(content);
              if (matchResult && matchResult.length > 0) {
                const parsedStr = matchResult[0];
                const parsedObj: Record<string, Object> = JSON.parse(parsedStr) as Record<string, Object>;
                const llmResp: LLMResponse = {
                  description: (parsedObj['description'] as string) || content,
                  confidence: 0.85,
                  tags: (parsedObj['tags'] as string[]) || []
                };
                resolve(llmResp);
              } else {
                const llmResp: LLMResponse = {
                  description: content,
                  confidence: 0.8,
                  tags: []
                };
                resolve(llmResp);
              }
            } catch (parseErr) {
              const llmResp: LLMResponse = {
                description: content,
                confidence: 0.8,
                tags: []
              };
              resolve(llmResp);
            }
          } catch (parseErr) {
            console.error(`[LocalImageAnalysis] Response parse error: ${JSON.stringify(parseErr)}, response: ${(response.result as string)?.substring(0, 200)}`);
            reject(new Error('响应解析失败: ' + (parseErr as Error).message));
          }
        }
      );
    });
  }

  /**
   * 批量时空分析
   */
  async batchSpatiotemporalAnalysis(
    imagePaths: string[],
    onProgress?: (current: number, total: number) => void
  ): Promise<SpatiotemporalResult[]> {
    const results: SpatiotemporalResult[] = [];

    for (let i = 0; i < imagePaths.length; i++) {
      try {
        const metadata = await this.extractImageMetadata(imagePaths[i]);

        results.push({
          fileId: 0, // 由调用方填充
          fileName: metadata.fileName,
          metadata: metadata,
          originalCreatedTime: this.formatDateTime(metadata),
          location: await this.formatLocationAsync(metadata),  // 使用异步版本获取精确地名
          analysisStatus: 'completed'
        });

        if (onProgress) {
          onProgress(i + 1, imagePaths.length);
        }
      } catch (err) {
        console.error(`[LocalImageAnalysis] Failed for ${imagePaths[i]}:`, err);
      }
    }

    return results;
  }

  /**
   * 批量生成Caption
   */
  async batchGenerateCaptions(
    imageData: ImageDataItem[],
    onProgress?: (current: number, total: number) => void
  ): Promise<CaptionResult[]> {
    const results: CaptionResult[] = [];

    for (let i = 0; i < imageData.length; i++) {
      try {
        const result = await this.generateCaption(imageData[i].path, imageData[i].id);
        results.push(result);

        if (onProgress) {
          onProgress(i + 1, imageData.length);
        }
      } catch (err) {
        console.error(`[LocalImageAnalysis] Caption failed for ${imageData[i].path}:`, err);
      }
    }

    return results;
  }

  /**
   * 释放资源
   */
  async release(): Promise<void> {
    // 释放 Caption Worker
    if (this.captionWorker) {
      this.captionWorker.postMessage({
        type: 'release',
        requestId: 'release',
        data: {}
      });

      await new Promise<void>((resolve) => setTimeout(() => resolve(), 100));

      this.captionWorker.terminate();
      this.captionWorker = null;
      this.captionWorkerReady = false;
    }

    // 释放本地 Caption 服务
    if (this.localCaptionService) {
      await this.localCaptionService.unload();
      this.localCaptionService = null;
      this.localCaptionLoaded = false;
    }

    this.captionPendingRequests.clear();
    console.info('[LocalImageAnalysis] Service released');
  }
}