/**
 * 性能测试工具类
 */
export interface PerformanceMetrics {
  feature: 'ocr' | 'embedding' | 'caption';
  method: string;
  elapsedTime: number;
  peakMemory: number;
  successCount: number;
  totalCount: number;
  avgElapsedTime: number;
  successRate: number;
}

export function createInitialMetrics(feature: 'ocr' | 'embedding' | 'caption', method: string): PerformanceMetrics {
  return {
    feature: feature,
    method: method,
    elapsedTime: 0,
    peakMemory: 0,
    successCount: 0,
    totalCount: 0,
    avgElapsedTime: 0,
    successRate: 0
  };
}

export class PerformanceUtils {
  private static metricsHistory: Map<string, PerformanceMetrics[]> = new Map();

  /**
   * 记录性能数据
   */
  static recordMetric(
    feature: 'ocr' | 'embedding' | 'caption',
    method: string,
    elapsedTime: number,
    success: boolean
  ): void {
    const key = `${feature}_${method}`;
    let history = PerformanceUtils.metricsHistory.get(key) || [];

    const currentMetric: PerformanceMetrics = {
      feature: feature,
      method: method,
      elapsedTime: elapsedTime,
      peakMemory: PerformanceUtils.getPeakMemory(),
      successCount: success ? 1 : 0,
      totalCount: 1,
      avgElapsedTime: elapsedTime,
      successRate: success ? 100 : 0
    };

    history.push(currentMetric);
    PerformanceUtils.metricsHistory.set(key, history);
  }

  /**
   * 获取汇总性能指标
   */
  static getAggregatedMetrics(feature: 'ocr' | 'embedding' | 'caption', method: string): PerformanceMetrics {
    const key = `${feature}_${method}`;
    const history = PerformanceUtils.metricsHistory.get(key) || [];

    if (history.length === 0) {
      return createInitialMetrics(feature, method);
    }

    const totalSuccess = history.reduce((sum, m) => sum + m.successCount, 0);
    const totalTests = history.reduce((sum, m) => sum + m.totalCount, 0);
    const totalTime = history.reduce((sum, m) => sum + m.elapsedTime, 0);
    const peakMemory = Math.max(...history.map(m => m.peakMemory));

    return {
      feature: feature,
      method: method,
      elapsedTime: totalTime,
      peakMemory: peakMemory,
      successCount: totalSuccess,
      totalCount: totalTests,
      avgElapsedTime: totalTime / totalTests,
      successRate: totalTests > 0 ? (totalSuccess / totalTests) * 100 : 0
    };
  }

  /**
   * 获取当前进程内存峰值(MB)
   */
  static getPeakMemory(): number {
    // HarmonyOS暂无直接获取进程内存的API
    return 0;
  }

  /**
   * 开始计时
   */
  static startTimer(): number {
    return Date.now();
  }

  /**
   * 结束计时并返回耗时(毫秒)
   */
  static endTimer(startTime: number): number {
    return Date.now() - startTime;
  }

  /**
   * 清空历史数据
   */
  static clearHistory(): void {
    PerformanceUtils.metricsHistory.clear();
  }

  /**
   * 格式化性能报告
   */
  static formatReport(metrics: PerformanceMetrics): string {
    return `方法: ${metrics.method}\n` +
           `平均耗时: ${metrics.avgElapsedTime.toFixed(2)}ms\n` +
           `成功率: ${metrics.successRate.toFixed(1)}%\n` +
           `测试次数: ${metrics.totalCount}`;
  }
}