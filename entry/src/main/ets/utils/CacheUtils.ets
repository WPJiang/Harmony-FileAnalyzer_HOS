import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';

/**
 * 缓存文件管理工具
 *
 * 与Python项目保持一致的设计：
 * - 数据块内容保存到cache目录下
 * - addr字段指向缓存文件路径
 * - 图片文件直接使用原始路径，不缓存
 *
 * 重要：所有文件操作使用异步API，避免阻塞主线程
 */
export class CacheUtils {
  private static instance: CacheUtils | null = null;
  private baseCacheDir: string = '';
  private dataBlocksCacheDir: string = '';
  private pdfImagesCacheDir: string = '';

  private constructor() {}

  static getInstance(): CacheUtils {
    if (!CacheUtils.instance) {
      CacheUtils.instance = new CacheUtils();
    }
    return CacheUtils.instance;
  }

  /**
   * 初始化缓存目录
   * @param context 应用上下文
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.baseCacheDir = context.cacheDir;
    this.dataBlocksCacheDir = `${this.baseCacheDir}/data_blocks`;
    this.pdfImagesCacheDir = `${this.baseCacheDir}/pdf_images`;

    // 创建缓存目录（异步）
    await this.ensureDir(this.dataBlocksCacheDir);
    await this.ensureDir(this.pdfImagesCacheDir);

    console.info('[CacheUtils] Cache directories initialized:');
    console.info(`[CacheUtils] - dataBlocks: ${this.dataBlocksCacheDir}`);
    console.info(`[CacheUtils] - pdfImages: ${this.pdfImagesCacheDir}`);
  }

  /**
   * 获取基础缓存目录
   * @returns 缓存目录路径，未初始化时返回空字符串
   */
  getBaseCacheDir(): string {
    return this.baseCacheDir;
  }

  /**
   * 确保目录存在（异步）
   * 递归创建父目录
   */
  async ensureDir(dirPath: string): Promise<void> {
    try {
      // 检查目录是否已存在
      try {
        await fileIo.stat(dirPath);
        console.info(`[CacheUtils] Directory already exists: ${dirPath}`);
        return;
      } catch {
        // 目录不存在，继续创建
      }

      // 尝试创建目录（非递归方式可能失败）
      try {
        await fileIo.mkdir(dirPath);
        console.info(`[CacheUtils] Created directory: ${dirPath}`);
        return;
      } catch (mkdirErr) {
        // 如果创建失败，尝试先创建父目录
        const parentPath = dirPath.substring(0, dirPath.lastIndexOf('/'));
        if (parentPath && parentPath !== this.baseCacheDir) {
          await this.ensureDir(parentPath);
          // 再次尝试创建
          try {
            await fileIo.mkdir(dirPath);
            console.info(`[CacheUtils] Created directory (after parent): ${dirPath}`);
          } catch (finalErr) {
            console.error(`[CacheUtils] Failed to create directory: ${dirPath}`, finalErr);
          }
        } else {
          console.error(`[CacheUtils] Failed to create directory: ${dirPath}`, mkdirErr);
        }
      }
    } catch (err) {
      console.error(`[CacheUtils] ensureDir error: ${dirPath}`, err);
    }
  }

  /**
   * 生成文件哈希（用于缓存目录命名）
   * 只使用纯ASCII哈希值，避免中文字符导致文件操作失败
   * @param filePath 原始文件路径
   * @returns 12位十六进制哈希字符串
   */
  generateFileHash(filePath: string): string {
    // 使用完整路径生成哈希，确保唯一性
    const pathStr = filePath.toLowerCase();
    let hash = 0;
    for (let i = 0; i < pathStr.length; i++) {
      const char = pathStr.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash; // 转为32位整数
    }
    // 生成12位纯ASCII十六进制字符串
    const hashStr = Math.abs(hash).toString(16).padStart(8, '0');
    // 添加随机后缀增加唯一性（避免哈希冲突）
    const randomSuffix = Math.floor(Math.random() * 0xFFFF).toString(16).padStart(4, '0');
    return `${hashStr}_${randomSuffix}`;
  }

  /**
   * 获取数据块缓存目录
   * @param filePath 原始文件路径
   * @returns 缓存目录路径
   */
  async getDataBlocksCachePath(filePath: string): Promise<string> {
    // 检查是否已初始化
    if (!this.dataBlocksCacheDir) {
      console.error('[CacheUtils] getDataBlocksCachePath called before init! dataBlocksCacheDir is empty');
      throw new Error('CacheUtils not initialized');
    }

    // 解码文件名并去掉扩展名
    const fileNameRaw = filePath.split('/').pop() || '';
    const fileName = this.decodeFileName(fileNameRaw);
    const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.')) || fileName;

    // 清理文件名中的特殊字符（可能导致文件系统操作失败）
    // 替换中文冒号、英文冒号等特殊字符为下划线
    let cleanedName = nameWithoutExt;
    cleanedName = cleanedName.replace(/[：:]/g, '_');  // 中文冒号和英文冒号
    cleanedName = cleanedName.replace(/[＋+]/g, '_');  // 中文加号和英文加号
    cleanedName = cleanedName.replace(/[？?]/g, '_');  // 中文问号和英文问号
    cleanedName = cleanedName.replace(/[＊*]/g, '_');  // 中文星号和英文星号
    cleanedName = cleanedName.replace(/[｜|]/g, '_');  // 中文竖线和英文竖线
    cleanedName = cleanedName.replace(/[＜<]/g, '_');  // 中文小于号和英文小于号
    cleanedName = cleanedName.replace(/[＞>]/g, '_');  // 中文大于号和英文大于号
    cleanedName = cleanedName.replace(/[＂"]/g, '_');  // 中文引号和英文引号
    cleanedName = cleanedName.replace(/[\[\]【】]/g, '_');  // 各类括号
    cleanedName = cleanedName.replace(/[\/\\]/g, '_');  // 斜杠

    // 使用清理后的文件名+哈希作为目录名，哈希确保唯一性
    const fileHash = this.generateFileHash(filePath);
    const cachePath = `${this.dataBlocksCacheDir}/${cleanedName}_${fileHash}`;
    await this.ensureDir(cachePath);
    console.info(`[CacheUtils] Cache path for ${filePath}: ${cachePath}`);
    return cachePath;
  }

  /**
   * 解码URL编码的文件名
   */
  private decodeFileName(fileName: string): string {
    try {
      // 解码常见的URL编码字符
      let decoded = fileName;
      decoded = decoded.replace(/%20/g, ' ');
      decoded = decoded.replace(/%25/g, '%');
      decoded = decoded.replace(/%2B/g, '+');
      decoded = decoded.replace(/%2F/g, '/');
      decoded = decoded.replace(/%3A/g, ':');
      decoded = decoded.replace(/%3D/g, '=');
      decoded = decoded.replace(/%3F/g, '?');
      decoded = decoded.replace(/%40/g, '@');
      decoded = decoded.replace(/%5B/g, '[');
      decoded = decoded.replace(/%5D/g, ']');
      decoded = decoded.replace(/%E5/g, 'å');  // 中文编码处理
      // 使用util.TextDecoder处理完整的URL编码
      if (decoded.includes('%')) {
        try {
          const encoder = new util.TextEncoder();
          const bytes = encoder.encodeInto(decoded);
          const decoder = new util.TextDecoder('utf-8');
          decoded = decoder.decodeToString(new Uint8Array(bytes));
        } catch {
          // 解码失败，保持原样
        }
      }
      return decoded;
    } catch {
      return fileName;
    }
  }

  /**
   * 获取PDF图片缓存目录
   * @param filePath PDF文件路径
   * @returns 缓存目录路径
   */
  async getPdfImagesCachePath(filePath: string): Promise<string> {
    const fileName = filePath.split('/').pop() || '';
    const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.')) || fileName;
    const fileHash = this.generateFileHash(filePath);
    const cachePath = `${this.pdfImagesCacheDir}/${nameWithoutExt}_${fileHash}`;
    await this.ensureDir(cachePath);
    return cachePath;
  }

  /**
   * 保存文本内容到缓存文件（异步）
   * @param content 文本内容
   * @param cachePath 缓存目录路径
   * @param fileName 缓存文件名
   * @returns 缓存文件完整路径，失败返回空字符串
   */
  async saveTextToCache(content: string, cachePath: string, fileName: string): Promise<string> {
    console.info(`[CacheUtils] ========== saveTextToCache START ==========`);
    console.info(`[CacheUtils] cachePath: "${cachePath}"`);
    console.info(`[CacheUtils] fileName: "${fileName}"`);
    console.info(`[CacheUtils] content length: ${content.length}`);

    // 检查cachePath是否有效
    if (!cachePath) {
      console.error('[CacheUtils] saveTextToCache FAILED: cachePath is empty, cannot save');
      return '';
    }

    const fullPath = `${cachePath}/${fileName}`;
    console.info(`[CacheUtils] fullPath: "${fullPath}"`);

    try {
      // Step 1: 确保目录存在
      console.info(`[CacheUtils] Step 1 - Ensuring directory exists: "${cachePath}"`);
      await this.ensureDir(cachePath);
      console.info(`[CacheUtils] Step 1 SUCCESS - Directory ensured`);

      // Step 2: 打开文件
      console.info(`[CacheUtils] Step 2 - Opening file: "${fullPath}"`);
      const file = await fileIo.open(fullPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      console.info(`[CacheUtils] Step 2 SUCCESS - File opened, fd: ${file.fd}`);

      // Step 3: 编码内容
      console.info(`[CacheUtils] Step 3 - Encoding content to bytes...`);
      const encoder = new util.TextEncoder();
      const bytes = encoder.encodeInto(content);
      console.info(`[CacheUtils] Step 3 SUCCESS - Encoded ${bytes.length} bytes`);

      // Step 4: 写入文件
      console.info(`[CacheUtils] Step 4 - Writing to file...`);
      await fileIo.write(file.fd, bytes.buffer);
      console.info(`[CacheUtils] Step 4 SUCCESS - Written ${bytes.length} bytes`);

      // Step 5: 关闭文件
      console.info(`[CacheUtils] Step 5 - Closing file...`);
      await fileIo.close(file.fd);
      console.info(`[CacheUtils] Step 5 SUCCESS - File closed`);

      console.info(`[CacheUtils] ========== saveTextToCache COMPLETE ==========`);
      console.info(`[CacheUtils] Saved: ${fullPath}, size: ${bytes.length} bytes`);
      return fullPath;
    } catch (err) {
      console.error(`[CacheUtils] ========== saveTextToCache EXCEPTION ==========`);
      console.error(`[CacheUtils] fullPath: "${fullPath}"`);
      console.error(`[CacheUtils] Error message: ${(err as Error).message}`);
      console.error(`[CacheUtils] Error code: ${(err as Error).name}`);
      console.error(`[CacheUtils] Error stack: ${(err as Error).stack}`);
      return '';
    }
  }

  /**
   * 从缓存文件读取文本内容（异步）
   * @param cachePath 缓存文件路径
   * @returns 文本内容，失败返回空字符串
   */
  async readTextFromCache(cachePath: string): Promise<string> {
    try {
      const file = await fileIo.open(cachePath, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (err) {
      console.error(`[CacheUtils] Failed to read text cache: ${cachePath}`, err);
      return '';
    }
  }

  /**
   * 保存二进制数据到缓存文件（异步）
   * @param data 二进制数据
   * @param cachePath 缓存目录路径
   * @param fileName 缓存文件名
   * @returns 缓存文件完整路径
   */
  async saveBinaryToCache(data: ArrayBuffer, cachePath: string, fileName: string): Promise<string> {
    const fullPath = `${cachePath}/${fileName}`;
    try {
      const file = await fileIo.open(fullPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      await fileIo.write(file.fd, data);
      await fileIo.close(file.fd);
      console.info(`[CacheUtils] Saved binary to cache: ${fullPath}, size: ${data.byteLength}`);
      return fullPath;
    } catch (err) {
      console.error(`[CacheUtils] Failed to save binary cache: ${fullPath}`, err);
      return '';
    }
  }

  /**
   * 保存PixelMap到缓存文件（异步）
   * @param pixelMap PixelMap图像对象
   * @param cachePath 缓存目录路径
   * @param fileName 缓存文件名（PNG格式）
   * @returns 缓存文件完整路径
   */
  async savePixelMapToCache(pixelMap: image.PixelMap, cachePath: string, fileName: string): Promise<string> {
    const fullPath = `${cachePath}/${fileName}`;
    try {
      // 创建ImagePacker用于打包图像
      const imagePackerApi = image.createImagePacker();

      // 设置打包选项（PNG格式）
      const packOptions: image.PackingOption = {
        format: 'image/png',
        quality: 100
      };

      // 打包PixelMap为ArrayBuffer
      const packData = await imagePackerApi.packing(pixelMap, packOptions);

      // 写入文件
      const file = await fileIo.open(fullPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      await fileIo.write(file.fd, packData);
      await fileIo.close(file.fd);

      // 释放ImagePacker
      imagePackerApi.release();

      console.info(`[CacheUtils] Saved PixelMap to cache: ${fullPath}`);
      return fullPath;
    } catch (err) {
      console.error(`[CacheUtils] Failed to save PixelMap cache: ${fullPath}`, err);
      return '';
    }
  }

  /**
   * 检查缓存文件是否存在
   */
  cacheExists(cachePath: string): boolean {
    try {
      fileIo.accessSync(cachePath);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * 删除缓存文件
   */
  deleteCache(cachePath: string): boolean {
    try {
      fileIo.unlinkSync(cachePath);
      console.info(`[CacheUtils] Deleted cache: ${cachePath}`);
      return true;
    } catch (err) {
      console.warn(`[CacheUtils] Failed to delete cache: ${cachePath}`, err);
      return false;
    }
  }

  /**
   * 清理指定文件的所有缓存
   * @param filePath 原始文件路径
   */
  async clearFileCache(filePath: string): Promise<void> {
    const dataBlocksPath = await this.getDataBlocksCachePath(filePath);
    const pdfImagesPath = await this.getPdfImagesCachePath(filePath);

    try {
      await fileIo.rmdir(dataBlocksPath);
      console.info(`[CacheUtils] Cleared data_blocks cache: ${dataBlocksPath}`);
    } catch {
      // 忽略
    }

    try {
      await fileIo.rmdir(pdfImagesPath);
      console.info(`[CacheUtils] Cleared pdf_images cache: ${pdfImagesPath}`);
    } catch {
      // 忽略
    }
  }

  /**
   * 获取缓存目录大小
   */
  getCacheSize(): number {
    // 简化实现，返回估算值
    return 0;
  }

  /**
   * 清理所有缓存（异步）
   */
  async clearAllCache(): Promise<void> {
    try {
      await fileIo.rmdir(this.dataBlocksCacheDir);
      await fileIo.rmdir(this.pdfImagesCacheDir);
      await this.ensureDir(this.dataBlocksCacheDir);
      await this.ensureDir(this.pdfImagesCacheDir);
      console.info('[CacheUtils] All cache cleared');
    } catch (err) {
      console.warn('[CacheUtils] Failed to clear all cache:', err);
    }
  }
}