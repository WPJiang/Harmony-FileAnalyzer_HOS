import { taskpool } from '@kit.ArkTS';

/**
 * 后台任务执行器
 * 使用 TaskPool 将计算密集型任务移到子线程执行，避免阻塞主线程
 */

/**
 * 任务类型定义
 */
export type BackgroundTaskType =
  | 'parse'
  | 'semantic'
  | 'classify'
  | 'caption'
  | 'scan';

/**
 * 任务进度回调
 */
export interface TaskProgress {
  type: BackgroundTaskType;
  current: number;
  total: number;
  fileName: string;
  percent: number;
}

/**
 * 任务结果
 */
export interface TaskResult {
  success: boolean;
  data?: object;
  error?: string;
  elapsedMs: number;
}

/**
 * 进度回调函数类型
 */
export type ProgressCallback = (progress: TaskProgress) => void;

/**
 * 后台任务执行器类
 * 提供统一的子线程任务执行接口
 */
export class BackgroundTaskExecutor {
  private onProgress: ProgressCallback | null = null;
  private isRunning: boolean = false;

  /**
   * 设置进度回调
   */
  setProgressCallback(callback: ProgressCallback): void {
    this.onProgress = callback;
  }

  /**
   * 检查是否正在运行
   */
  isTaskRunning(): boolean {
    return this.isRunning;
  }

  /**
   * 报告进度（在主线程调用）
   */
  reportProgress(progress: TaskProgress): void {
    if (this.onProgress) {
      this.onProgress(progress);
    }
  }

  /**
   * 在子线程执行任务
   * 注意：传入的函数必须被 @Concurrent 装饰
   */
  async executeInBackground<T>(
    taskFunc: (...args: object[]) => T | Promise<T>,
    ...args: object[]
  ): Promise<T> {
    this.isRunning = true;
    try {
      // 使用 taskpool.execute 在子线程执行
      const result = await taskpool.execute(taskFunc, ...args) as T;
      return result;
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * 停止当前任务
   */
  stop(): void {
    this.isRunning = false;
    // TaskPool 没有直接的取消API，但可以通过状态标志来控制
  }
}

/**
 * 全单例实例
 */
export const backgroundExecutor = new BackgroundTaskExecutor();