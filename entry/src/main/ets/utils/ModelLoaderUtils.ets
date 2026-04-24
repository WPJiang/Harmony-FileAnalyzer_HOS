import { common } from '@kit.AbilityKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';

/**
 * 模型加载工具类
 * 用于加载 MindSpore Lite 模型
 */
export class ModelLoaderUtils {
  /**
   * 从 rawfile 加载 MindSpore Lite 模型
   * @param context 应用上下文
   * @param modelPath rawfile 中的模型路径
   * @param config MindSpore Lite 上下文配置
   * @returns 加载的模型实例，失败返回 null
   */
  static async loadMsModel(
    context: common.Context,
    modelPath: string,
    config: mindSporeLite.Context
  ): Promise<mindSporeLite.Model | null> {
    try {
      // 获取资源管理器
      const resourceMgr = context.resourceManager;
      console.info(`ModelLoaderUtils: Getting rawfile content for ${modelPath}`);

      // 读取模型文件内容（getRawFileContent返回Uint8Array）
      const uint8Buffer = await resourceMgr.getRawFileContent(modelPath);

      if (!uint8Buffer || uint8Buffer.byteLength === 0) {
        console.error(`ModelLoaderUtils: Failed to read model file: ${modelPath}, buffer is empty`);
        return null;
      }

      console.info(`ModelLoaderUtils: Model buffer size: ${uint8Buffer.byteLength} bytes, type: ${uint8Buffer.constructor.name}`);

      // 将Uint8Array转换为ArrayBuffer（与AItest项目一致）
      // loadModelFromBuffer可能需要真正的ArrayBuffer而非Uint8Array
      const modelBuffer = uint8Buffer.buffer.slice(uint8Buffer.byteOffset, uint8Buffer.byteOffset + uint8Buffer.byteLength);
      console.info(`ModelLoaderUtils: Converted to ArrayBuffer, size: ${modelBuffer.byteLength} bytes`);

      // 从 buffer 加载模型
      console.info(`ModelLoaderUtils: Calling mindSporeLite.loadModelFromBuffer...`);
      const model = await mindSporeLite.loadModelFromBuffer(modelBuffer, config);

      if (model) {
        console.info(`ModelLoaderUtils: Model loaded successfully: ${modelPath}`);
      } else {
        console.error(`ModelLoaderUtils: loadModelFromBuffer returned null for ${modelPath}`);
      }

      return model;
    } catch (error) {
      console.error(`ModelLoaderUtils.loadMsModel failed for ${modelPath}: ${JSON.stringify(error)}`);
      return null;
    }
  }

  /**
   * 创建默认 CPU 上下文
   * @param threadNum 线程数，默认 4
   * @returns MindSpore Lite 上下文配置
   */
  static createCPUContext(threadNum: number = 4): mindSporeLite.Context {
    const context: mindSporeLite.Context = {
      target: ['cpu'],
      cpu: {
        threadNum: threadNum,
        threadAffinityMode: 1,
        precisionMode: 'enforce_fp32'
      }
    };

    return context;
  }

  /**
   * 创建 NPU 上下文 (NPU 优先, CPU 回退)
   * @param precisionMode 精度模式, 默认 'enforce_fp16'
   * @returns MindSpore Lite 上下文配置
   */
  static createNPUContext(precisionMode: 'enforce_fp16' | 'enforce_fp32' = 'enforce_fp16'): mindSporeLite.Context {
    const context: mindSporeLite.Context = {
      target: ['npu', 'cpu'],
      cpu: {
        threadNum: 4,
        threadAffinityMode: 1,
        precisionMode: precisionMode
      }
    };

    return context;
  }

  /**
   * 创建混合上下文 (NPU > GPU > CPU 回退链)
   * @param threadNum CPU 线程数
   * @returns MindSpore Lite 上下文配置
   */
  static createHybridContext(threadNum: number = 4): mindSporeLite.Context {
    const context: mindSporeLite.Context = {
      target: ['npu', 'gpu', 'cpu'],
      cpu: {
        threadNum: threadNum,
        threadAffinityMode: 1,
        precisionMode: 'enforce_fp32'
      }
    };

    return context;
  }

  /**
   * 检查 rawfile 中的模型是否存在
   * @param context 应用上下文
   * @param modelPath 模型路径
   * @returns 是否存在
   */
  static async checkModelExists(
    context: common.Context,
    modelPath: string
  ): Promise<boolean> {
    try {
      const resourceMgr = context.resourceManager;
      await resourceMgr.getRawFile(modelPath);
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * 获取模型文件大小
   * @param context 应用上下文
   * @param modelPath 模型路径
   * @returns 文件大小（字节），失败返回 0
   */
  static async getModelSize(
    context: common.Context,
    modelPath: string
  ): Promise<number> {
    try {
      const resourceMgr = context.resourceManager;
      const descriptor = await resourceMgr.getRawFile(modelPath);
      return descriptor.length;
    } catch (error) {
      return 0;
    }
  }
}