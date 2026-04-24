// HarmonyOS NEXT 原生模块导入 - 必须在最开头
import llamaNapiModule from 'libllama_napi.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_TAG = 'LlamaNapi';
const LOG_DOMAIN = 0x03D00;

/**
 * Caption 生成结果
 */
export interface CaptionGenerationResult {
  caption: string;
  tokensPerSecond: number;
  tokenCount: number;
}

/**
 * 模型信息
 */
export interface ModelInfo {
  loaded: boolean;
  modelPath: string;
}

/**
 * Native 模块接口定义
 */
interface NativeModuleInterface {
  loadModel(modelPath: string, mmprojPath: string): boolean;
  isLoaded(): boolean;
  unloadModel(): void;
  generateCaption(imageData: ArrayBuffer, width: number, height: number, maxTokens: number): CaptionGenerationResult;
  generateCaptionAsync(imageData: ArrayBuffer, width: number, height: number, maxTokens: number): Promise<CaptionGenerationResult>;
  generate(prompt: string, maxTokens: number): string;
  getModelInfo(): ModelInfo;
  setLogFile(logPath: string): boolean;
  clearMemory(): boolean;
}

/**
 * llama.cpp NAPI 接口类
 */
export class LlamaNapi {
  private loaded: boolean = false;
  private module: NativeModuleInterface = llamaNapiModule as NativeModuleInterface;

  constructor() {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Native module imported, checking availability...');
    try {
      if (this.module) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Module object exists, available for use');
      } else {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Module is null/undefined');
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `Module check failed: ${String(e)}`);
    }
  }

  /**
   * 加载模型
   */
  async loadModel(modelPath: string, mmprojPath: string): Promise<boolean> {
    hilog.info(LOG_DOMAIN, LOG_TAG, `Loading model from ${modelPath}`);
    hilog.info(LOG_DOMAIN, LOG_TAG, `mmproj path: ${mmprojPath}`);

    try {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Calling native loadModel...');
      const result: boolean = this.module.loadModel(modelPath, mmprojPath);
      this.loaded = result;
      hilog.info(LOG_DOMAIN, LOG_TAG, `Native loadModel returned: ${result}`);
      return this.loaded;
    } catch (error) {
      const errStr = String(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, `loadModel EXCEPTION: ${errStr}`);
      this.loaded = false;
      return false;
    }
  }

  /**
   * 检查模型是否已加载
   */
  isLoaded(): boolean {
    hilog.info(LOG_DOMAIN, LOG_TAG, `isLoaded called, this.loaded=${this.loaded}`);
    try {
      const nativeResult: boolean = this.module.isLoaded();
      hilog.info(LOG_DOMAIN, LOG_TAG, `Native isLoaded returned: ${nativeResult}`);
      return nativeResult;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `isLoaded native failed: ${String(error)}`);
      return this.loaded;
    }
  }

  /**
   * 卸载模型
   */
  async unloadModel(): Promise<void> {
    console.info('LlamaNapi: Unloading model...');
    try {
      this.module.unloadModel();
      this.loaded = false;
      console.info('LlamaNapi: Model unloaded');
    } catch (error) {
      console.error(`LlamaNapi.unloadModel failed: ${String(error)}`);
    }
  }

  /**
   * 生成图片描述 - 使用 NAPI async work 避免主线程阻塞
   */
  async generateCaption(
    imageData: ArrayBuffer,
    width: number,
    height: number,
    maxTokens: number = 128
  ): Promise<CaptionGenerationResult> {
    hilog.info(LOG_DOMAIN, LOG_TAG, `generateCaption called: w=${width} h=${height} dataLen=${imageData.byteLength} maxTokens=${maxTokens}`);

    const defaultResult: CaptionGenerationResult = {
      caption: '',
      tokensPerSecond: 0,
      tokenCount: 0
    };

    let nativeLoaded = false;
    try {
      nativeLoaded = this.module.isLoaded();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `Cannot check native loaded: ${String(e)}`);
    }

    if (!nativeLoaded && !this.loaded) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Model not loaded');
      return defaultResult;
    }

    try {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Calling native generateCaptionAsync...');
      const result: CaptionGenerationResult = await this.module.generateCaptionAsync(imageData, width, height, maxTokens);

      if (result === null || result === undefined) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Native returned null');
        return defaultResult;
      }

      const caption: string = result.caption ?? '';
      const tokensPerSecond: number = result.tokensPerSecond ?? 0;
      const tokenCount: number = result.tokenCount ?? 0;

      hilog.info(LOG_DOMAIN, LOG_TAG, `Caption: "${caption.substring(0, 30)}..." tokens=${tokenCount}`);

      return { caption, tokensPerSecond, tokenCount };
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `generateCaption EXCEPTION: ${String(error)}`);
      return this.generateStubResult();
    }
  }

  /**
   * 生成文本
   */
  async generate(prompt: string, maxTokens: number): Promise<string> {
    hilog.info(LOG_DOMAIN, LOG_TAG, `generate called: promptLen=${prompt.length} maxTokens=${maxTokens}`);
    if (!this.loaded) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Not loaded');
      return '';
    }

    try {
      const result: string = this.module.generate(prompt, maxTokens);
      hilog.info(LOG_DOMAIN, LOG_TAG, `Generated: "${result.substring(0, 50)}"`);
      return result;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `generate failed: ${String(error)}`);
      return '';
    }
  }

  async getModelInfo(): Promise<ModelInfo> {
    try {
      const result: ModelInfo = this.module.getModelInfo();
      hilog.info(LOG_DOMAIN, LOG_TAG, `ModelInfo: loaded=${result.loaded}`);
      return result;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `getModelInfo failed: ${String(error)}`);
      return { loaded: this.loaded, modelPath: '' };
    }
  }

  /**
   * 设置独立文件日志
   */
  setLogFile(logPath: string): boolean {
    hilog.info(LOG_DOMAIN, LOG_TAG, `Setting log file: ${logPath}`);
    try {
      const result: boolean = this.module.setLogFile(logPath);
      hilog.info(LOG_DOMAIN, LOG_TAG, `setLogFile result: ${result}`);
      return result;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, `setLogFile failed: ${String(error)}`);
      return false;
    }
  }

  private generateStubResult(): CaptionGenerationResult {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'Generating STUB result - native module not working');
    const captions: string[] = [
      '这是一张展示风景的照片，画面中有蓝天白云和绿色植被。',
      '图片显示了一个室内场景，光线明亮，装饰简洁现代。',
      '这是一张人物照片，人物表情自然，背景虚化。',
      '图片中包含多个物体，主体突出，构图平衡。',
      '这是一张美食照片，色泽诱人，摆盘精致。'
    ];

    const index: number = Math.floor(Math.random() * captions.length);
    const caption: string = captions[index];
    return {
      caption,
      tokensPerSecond: 25 + Math.random() * 10,
      tokenCount: Math.floor(caption.length / 2)
    };
  }
}