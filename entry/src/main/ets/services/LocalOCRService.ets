import { OCRResult, OCRTextBlock, createEmptyOCRResult, createTextBounds, mergeTextBlocks } from '../models/OCRResultModel';
import { image } from '@kit.ImageKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { PerformanceUtils } from '../utils/PerformanceUtils';
import { fileIo } from '@kit.CoreFileKit';

// 导出 OCRResult 供其他模块使用
export { OCRResult, OCRTextBlock } from '../models/OCRResultModel';

/**
 * OCR服务接口
 */
export interface OCRServiceInterface {
  /**
   * 执行OCR识别
   */
  recognize(pixelMap: image.PixelMap): Promise<OCRResult>;

  /**
   * 获取服务名称
   */
  getName(): string;

  /**
   * 检查服务是否可用
   */
  isAvailable(): Promise<boolean>;
}

/**
 * OCR服务工厂
 */
export class OCRServiceFactory {
  private static services: Map<string, OCRServiceInterface> = new Map();

  /**
   * 注册服务
   */
  static register(name: string, service: OCRServiceInterface): void {
    OCRServiceFactory.services.set(name, service);
  }

  /**
   * 获取服务
   */
  static get(name: string): OCRServiceInterface | undefined {
    return OCRServiceFactory.services.get(name);
  }

  /**
   * 获取所有服务名称
   */
  static getAllServiceNames(): string[] {
    return Array.from(OCRServiceFactory.services.keys());
  }
}

/**
 * 系统API OCR服务实现
 * 使用HarmonyOS CoreVisionKit的textRecognition API
 */
export class SystemOCRService implements OCRServiceInterface {
  private serviceName: 'system_api' = 'system_api';

  getName(): string {
    return this.serviceName;
  }

  async isAvailable(): Promise<boolean> {
    // 系统API始终可用
    return true;
  }

  async recognize(pixelMap: image.PixelMap): Promise<OCRResult> {
    const result = createEmptyOCRResult('system_api');
    const startTime = PerformanceUtils.startTimer();

    try {
      // 构建VisionInfo
      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: pixelMap
      };

      // 执行识别
      const recognitionResult = await textRecognition.recognizeText(visionInfo);

      // 解析结果
      if (recognitionResult) {
        // 获取完整文本
        result.fullText = recognitionResult.value || '';

        // 将完整文本作为单个block返回
        if (result.fullText.length > 0) {
          const singleBlock: OCRTextBlock = {
            text: result.fullText,
            bounds: createTextBounds(0, 0, 0, 0),
            confidence: undefined
          };
          result.textBlocks = [singleBlock];
        }

        result.success = true;
      }

    } catch (error) {
      console.error('SystemOCRService.recognize failed:', error);
      result.errorMessage = String(error);
      result.success = false;
    }

    result.elapsedTime = PerformanceUtils.endTimer(startTime);
    PerformanceUtils.recordMetric('ocr', 'system_api', result.elapsedTime, result.success);

    return result;
  }
}

/**
 * 初始化并注册系统OCR服务
 */
export function initSystemOCRService(): void {
  const service = new SystemOCRService();
  OCRServiceFactory.register(service.getName(), service);
}

/**
 * LocalOCRService - 本地OCR文字识别服务
 *
 * 使用鸿蒙原生CoreVisionKit OCR API进行文字识别
 */
export class LocalOCRService {
  private initialized: boolean = false;

  async initialize(): Promise<void> {
    try {
      // CoreVisionKit textRecognition 不需要显式初始化
      this.initialized = true;
      console.info('[LocalOCRService] OCR service initialized');
    } catch (err) {
      console.error('[LocalOCRService] Failed to initialize:', err);
      this.initialized = false;
    }
  }

  async recognizeImage(imagePath: string): Promise<OCRResult> {
    if (!this.initialized) {
      await this.initialize();
    }

    const startTime = PerformanceUtils.startTimer();
    const result = createEmptyOCRResult('system_api');

    try {
      // 1. 打开文件
      const file = await fileIo.open(imagePath, fileIo.OpenMode.READ_ONLY);

      // 2. 创建图像源并解码为PixelMap
      const imageSource = image.createImageSource(file.fd);
      const pixelMap = await imageSource.createPixelMap();

      // 3. 关闭文件
      await fileIo.close(file.fd);

      // 4. 执行OCR识别
      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: pixelMap
      };

      const recognitionResult = await textRecognition.recognizeText(visionInfo);

      // 5. 解析结果
      if (recognitionResult) {
        result.fullText = recognitionResult.value || '';

        if (result.fullText.length > 0) {
          const singleBlock: OCRTextBlock = {
            text: result.fullText,
            bounds: createTextBounds(0, 0, 0, 0),
            confidence: undefined
          };
          result.textBlocks = [singleBlock];
        }

        result.success = true;
      }

      // 6. 释放PixelMap
      pixelMap.release();

    } catch (err) {
      console.error('[LocalOCRService] Recognition failed:', err);
      result.errorMessage = String(err);
      result.success = false;
    }

    result.elapsedTime = PerformanceUtils.endTimer(startTime);
    PerformanceUtils.recordMetric('ocr', 'system_api', result.elapsedTime, result.success);

    return result;
  }

  async recognizeFromPixelMap(pixelMap: image.PixelMap): Promise<OCRResult> {
    if (!this.initialized) {
      await this.initialize();
    }

    const startTime = PerformanceUtils.startTimer();
    const result = createEmptyOCRResult('system_api');

    try {
      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: pixelMap
      };

      const recognitionResult = await textRecognition.recognizeText(visionInfo);

      if (recognitionResult) {
        result.fullText = recognitionResult.value || '';

        if (result.fullText.length > 0) {
          const singleBlock: OCRTextBlock = {
            text: result.fullText,
            bounds: createTextBounds(0, 0, 0, 0),
            confidence: undefined
          };
          result.textBlocks = [singleBlock];
        }

        result.success = true;
      }

    } catch (err) {
      console.error('[LocalOCRService] Recognition from PixelMap failed:', err);
      result.errorMessage = String(err);
      result.success = false;
    }

    result.elapsedTime = PerformanceUtils.endTimer(startTime);
    PerformanceUtils.recordMetric('ocr', 'system_api', result.elapsedTime, result.success);

    return result;
  }

  async recognizeImagePath(imagePath: string): Promise<string> {
    const result = await this.recognizeImage(imagePath);
    return result.fullText;
  }

  isAvailable(): boolean {
    return this.initialized;
  }

  async release(): Promise<void> {
    // CoreVisionKit textRecognition 不需要显式释放
    this.initialized = false;
    console.info('[LocalOCRService] OCR service released');
  }
}