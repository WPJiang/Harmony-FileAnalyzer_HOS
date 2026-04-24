import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CacheUtils } from '../utils/CacheUtils';

export class TextParser extends BaseParser {
  constructor() {
    super();
    this.supportedExtensions = ['.txt', '.md', '.json', '.xml', '.html', '.csv'];
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      const error = new Error(`Unsupported file format: ${filePath}`);
      throw error;
    }

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    const decodedFileName = this.decodeFileName(fileName);
    const cacheUtils = CacheUtils.getInstance();
    const cachePath = await cacheUtils.getDataBlocksCachePath(filePath);

    try {
      const content = await this.readFileContent(filePath);

      if (content.trim()) {
        // 保存文本内容到缓存文件（异步）
        const textCachePath = await cacheUtils.saveTextToCache(content, cachePath, 'text_1.txt');

        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TEXT);
        block.setContent(content);
        block.setTextContent(content);
        block.setFilePath(filePath);
        block.setAddr(textCachePath);  // 文本块：addr = 缓存文件路径
        block.setPageNumber(1);
        const meta: FileMetadata = {
          'source': 'textparser',
          'fileName': decodedFileName,
          'cachePath': textCachePath
        };
        block.setMetadata(meta);
        blocks.push(block);
      }
    } catch (err) {
      console.error('[TextParser] Failed to parse text file:', err);
    }

    return blocks;
  }

  private async readFileContent(filePath: string): Promise<string> {
    try {
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const bufferSize = Math.min(stat.size, 1024 * 1024); // 限制1MB
      const buffer = new ArrayBuffer(bufferSize);

      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);

      return this.decodeBuffer(buffer);
    } catch (err) {
      console.error('[TextParser] Failed to read file:', err);
      return '';
    }
  }

  private decodeBuffer(buffer: ArrayBuffer): string {
    const bytes = new Uint8Array(buffer);

    // 尝试检测编码并解码
    try {
      // 优先尝试UTF-8解码
      const decoder = new util.TextDecoder('utf-8');
      return decoder.decodeToString(bytes);
    } catch {
      // 回退到简单的字符解码
      let result = '';
      for (let i = 0; i < bytes.length; i++) {
        const byte = bytes[i];
        if (byte === 0) break;
        if (byte < 128) {
          result += String.fromCharCode(byte);
        } else {
          result += String.fromCharCode(byte);
        }
      }
      return result;
    }
  }
}
