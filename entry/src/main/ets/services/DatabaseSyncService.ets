/**
 * DatabaseSyncService - 数据库同步服务
 *
 * 用于调试模式下，将手机端数据库和缓存文件同步到PC端调试服务器
 */

import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import common from '@ohos.app.ability.common';
import { CacheUtils } from '../utils/CacheUtils';

export interface SyncResult {
  success: boolean;
  message: string;
  timestamp: string;
  cacheFilesCount?: number;
  cacheTotalSize?: number;
}

interface SyncDatabaseRequest {
  action: string;
  timestamp: string;
  database_size: number;
  database_base64: string;
}

interface SyncTablesRequest {
  action: string;
  timestamp: string;
  tables: Record<string, Object[]>;
}

interface SyncCacheFileRequest {
  action: string;
  timestamp: string;
  relative_path: string;
  file_size: number;
  content_base64: string;
}

interface SyncCacheCompleteRequest {
  action: string;
  timestamp: string;
  total_files: number;
  total_size: number;
}

interface LogRequest {
  action: string;
  timestamp: string;
  level: string;
  message: string;
  data: Record<string, Object>;
}

// 缓存同步结果
interface CacheSyncResult {
  filesCount: number;
  totalSize: number;
}

// 缓存文件信息
interface CacheFileInfo {
  path: string;
  relativePath: string;
  size: number;
}

export class DatabaseSyncService {
  private context: common.Context | null = null;
  private syncServerUrl: string = '';
  private isSyncing: boolean = false;

  setContext(context: common.Context): void {
    this.context = context;
  }

  setServerUrl(url: string): void {
    this.syncServerUrl = url.replace(/\/$/, ''); // 移除末尾斜杠
  }

  /**
   * 同步数据库到服务端
   */
  async syncDatabase(): Promise<SyncResult> {
    if (this.isSyncing) {
      return {
        success: false,
        message: '同步进行中...',
        timestamp: new Date().toISOString()
      };
    }

    if (!this.syncServerUrl) {
      return {
        success: false,
        message: '未配置同步服务器地址',
        timestamp: new Date().toISOString()
      };
    }

    this.isSyncing = true;

    try {
      // 使用context获取数据库路径
      let dbPath = '';
      if (this.context) {
        const dbDir = this.context.databaseDir;
        dbPath = `${dbDir}/rdb/FileAnalyzer.db`;
      } else {
        dbPath = '/data/app/el2/100/database/com.example.fileanalyzer_hos/rdb/FileAnalyzer.db';
      }
      console.info('[DatabaseSync] Starting sync, db path:', dbPath);

      // 读取数据库文件
      const file = await fileIo.open(dbPath, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const fileSize = stat.size;

      // 读取文件内容为Base64
      const buffer = new ArrayBuffer(fileSize);
      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);

      // 转换为Base64
      const uint8Array = new Uint8Array(buffer);
      const base64Helper = new util.Base64Helper();
      const base64Content = base64Helper.encodeToStringSync(uint8Array);

      // 发送到服务器
      const httpRequest = http.createHttp();
      const requestBody: SyncDatabaseRequest = {
        action: 'sync_database',
        timestamp: new Date().toISOString(),
        database_size: fileSize,
        database_base64: base64Content
      };

      const response = await new Promise<http.HttpResponse>((resolve, reject) => {
        httpRequest.request(
          `${this.syncServerUrl}/api/debug/sync`,
          {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json'
            },
            extraData: JSON.stringify(requestBody),
            connectTimeout: 30000,
            readTimeout: 60000
          },
          (err, response) => {
            if (err) {
              reject(new Error(`同步请求失败: ${err.message}`));
            } else {
              resolve(response);
            }
          }
        );
      });

      httpRequest.destroy();

      if (response.responseCode === 200) {
        const result = JSON.parse(response.result as string) as Record<string, Object>;
        console.info('[DatabaseSync] Database sync successful, starting cache sync...');

        // 同步缓存目录
        const cacheResult = await this.syncCacheDirectory();

        this.isSyncing = false;
        return {
          success: true,
          message: `同步成功 (数据库 + ${cacheResult.filesCount}个缓存文件)`,
          timestamp: new Date().toISOString(),
          cacheFilesCount: cacheResult.filesCount,
          cacheTotalSize: cacheResult.totalSize
        };
      } else {
        this.isSyncing = false;
        return {
          success: false,
          message: `服务器返回错误: ${response.responseCode}`,
          timestamp: new Date().toISOString()
        };
      }
    } catch (err) {
      this.isSyncing = false;
      console.error('[DatabaseSync] Sync failed:', err);
      return {
        success: false,
        message: `同步失败: ${(err as Error).message}`,
        timestamp: new Date().toISOString()
      };
    }
  }

  /**
   * 同步缓存目录（data_blocks）到服务器
   * @returns 同步的文件数和总大小
   */
  private async syncCacheDirectory(): Promise<CacheSyncResult> {
    const cacheUtils = CacheUtils.getInstance();
    const dataBlocksDir = cacheUtils.getBaseCacheDir() + '/data_blocks';

    let filesCount = 0;
    let totalSize = 0;

    try {
      // 检查目录是否存在
      try {
        await fileIo.stat(dataBlocksDir);
      } catch {
        console.info('[DatabaseSync] data_blocks directory not found, skip cache sync');
        const emptyResult: CacheSyncResult = { filesCount: 0, totalSize: 0 };
        return emptyResult;
      }

      // 遍历目录，收集所有文件
      const filesToSync = await this.collectCacheFiles(dataBlocksDir);
      console.info(`[DatabaseSync] Found ${filesToSync.length} cache files to sync`);

      // 同步每个文件
      for (const fileInfo of filesToSync) {
        try {
          await this.syncSingleCacheFile(fileInfo.path, fileInfo.relativePath, fileInfo.size);
          filesCount++;
          totalSize += fileInfo.size;
        } catch (err) {
          console.warn(`[DatabaseSync] Failed to sync cache file: ${fileInfo.relativePath}`, err);
        }
      }

      // 发送完成通知
      if (filesCount > 0) {
        await this.sendCacheSyncComplete(filesCount, totalSize);
      }

      console.info(`[DatabaseSync] Cache sync complete: ${filesCount} files, ${totalSize} bytes`);
      const result: CacheSyncResult = { filesCount, totalSize };
      return result;
    } catch (err) {
      console.error('[DatabaseSync] Cache sync error:', err);
      const partialResult: CacheSyncResult = { filesCount, totalSize };
      return partialResult;
    }
  }

  /**
   * 收集缓存目录下的所有文件
   */
  private async collectCacheFiles(dirPath: string): Promise<CacheFileInfo[]> {
    const files: CacheFileInfo[] = [];
    const baseDir = CacheUtils.getInstance().getBaseCacheDir() + '/data_blocks';

    try {
      // 使用listFile遍历目录（递归）
      const entries = await fileIo.listFile(dirPath);
      for (const entry of entries) {
        const fullPath = `${dirPath}/${entry}`;

        try {
          const stat = await fileIo.stat(fullPath);
          if (stat.isDirectory()) {
            // 递归处理子目录
            const subFiles = await this.collectCacheFiles(fullPath);
            files.push(...subFiles);
          } else {
            // 添加文件
            const relativePath = fullPath.substring(baseDir.length + 1);
            const fileInfo: CacheFileInfo = {
              path: fullPath,
              relativePath: relativePath,
              size: stat.size
            };
            files.push(fileInfo);
          }
        } catch {
          // 忽略无法访问的文件
        }
      }
    } catch (err) {
      console.error('[DatabaseSync] Failed to list directory:', dirPath, err);
    }

    return files;
  }

  /**
   * 同步单个缓存文件
   */
  private async syncSingleCacheFile(fullPath: string, relativePath: string, size: number): Promise<void> {
    try {
      // 读取文件内容
      const file = await fileIo.open(fullPath, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(size);
      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);

      // 转换为Base64
      const uint8Array = new Uint8Array(buffer);
      const base64Helper = new util.Base64Helper();
      const base64Content = base64Helper.encodeToStringSync(uint8Array);

      // 发送到服务器
      const httpRequest = http.createHttp();
      const requestBody: SyncCacheFileRequest = {
        action: 'sync_cache_file',
        timestamp: new Date().toISOString(),
        relative_path: relativePath,
        file_size: size,
        content_base64: base64Content
      };

      await new Promise<void>((resolve, reject) => {
        httpRequest.request(
          `${this.syncServerUrl}/api/debug/sync_cache_file`,
          {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json'
            },
            extraData: JSON.stringify(requestBody),
            connectTimeout: 10000,
            readTimeout: 30000
          },
          (err, response) => {
            httpRequest.destroy();
            if (err) {
              reject(new Error(`缓存文件同步失败: ${err.message}`));
            } else if (response.responseCode !== 200) {
              reject(new Error(`服务器返回错误: ${response.responseCode}`));
            } else {
              resolve();
            }
          }
        );
      });
    } catch (err) {
      throw new Error(`同步缓存文件失败: ${(err as Error).message}`);
    }
  }

  /**
   * 发送缓存同步完成通知
   */
  private async sendCacheSyncComplete(totalFiles: number, totalSize: number): Promise<void> {
    try {
      const httpRequest = http.createHttp();
      const requestBody: SyncCacheCompleteRequest = {
        action: 'sync_cache_complete',
        timestamp: new Date().toISOString(),
        total_files: totalFiles,
        total_size: totalSize
      };

      await new Promise<void>((resolve, reject) => {
        httpRequest.request(
          `${this.syncServerUrl}/api/debug/sync_cache_complete`,
          {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json'
            },
            extraData: JSON.stringify(requestBody),
            connectTimeout: 5000,
            readTimeout: 5000
          },
          (err, response) => {
            httpRequest.destroy();
            if (err) {
              console.warn('[DatabaseSync] Cache complete notification failed:', err);
            }
            resolve(); // 不抛出错误，完成通知失败不影响整体同步
          }
        );
      });
    } catch (err) {
      console.warn('[DatabaseSync] Cache complete notification failed:', err);
    }
  }

  /**
   * 同步数据表数据（JSON格式，更高效）
   */
  async syncTableData(tableData: Record<string, Object[]>): Promise<SyncResult> {
    if (!this.syncServerUrl) {
      return {
        success: false,
        message: '未配置同步服务器地址',
        timestamp: new Date().toISOString()
      };
    }

    try {
      const httpRequest = http.createHttp();
      const requestBody: SyncTablesRequest = {
        action: 'sync_tables',
        timestamp: new Date().toISOString(),
        tables: tableData
      };

      const response = await new Promise<http.HttpResponse>((resolve, reject) => {
        httpRequest.request(
          `${this.syncServerUrl}/api/debug/sync_tables`,
          {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json'
            },
            extraData: JSON.stringify(requestBody),
            connectTimeout: 30000,
            readTimeout: 60000
          },
          (err, response) => {
            if (err) {
              reject(new Error(`同步请求失败: ${err.message}`));
            } else {
              resolve(response);
            }
          }
        );
      });

      httpRequest.destroy();

      if (response.responseCode === 200) {
        return {
          success: true,
          message: '表数据同步成功',
          timestamp: new Date().toISOString()
        };
      } else {
        return {
          success: false,
          message: `服务器返回错误: ${response.responseCode}`,
          timestamp: new Date().toISOString()
        };
      }
    } catch (err) {
      return {
        success: false,
        message: `同步失败: ${(err as Error).message}`,
        timestamp: new Date().toISOString()
      };
    }
  }

  /**
   * 发送日志到服务器
   */
  async sendLog(logLevel: string, message: string, data?: Record<string, Object>): Promise<void> {
    if (!this.syncServerUrl) return;

    try {
      const httpRequest = http.createHttp();
      const requestBody: LogRequest = {
        action: 'log',
        timestamp: new Date().toISOString(),
        level: logLevel,
        message: message,
        data: data || {}
      };

      httpRequest.request(
        `${this.syncServerUrl}/api/debug/log`,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json'
          },
          extraData: JSON.stringify(requestBody),
          connectTimeout: 5000,
          readTimeout: 5000
        },
        () => {
          httpRequest.destroy();
        }
      );
    } catch (err) {
      console.warn('[DatabaseSync] Send log failed:', err);
    }
  }

  isSyncInProgress(): boolean {
    return this.isSyncing;
  }
}

// 单例
let _syncService: DatabaseSyncService | null = null;

export function getDatabaseSyncService(): DatabaseSyncService {
  if (!_syncService) {
    _syncService = new DatabaseSyncService();
  }
  return _syncService;
}