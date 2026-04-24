﻿import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { util } from '@kit.ArkTS';

export abstract class BaseParser {
  protected supportedExtensions: string[] = [];

  abstract parse(filePath: string): Promise<DataBlock[]>;

  canParse(filePath: string): boolean {
    const extRaw = filePath.toLowerCase().split('.').pop() || '';
    const ext = extRaw ? `.${extRaw}` : ''; // 带点前缀，与supportedExtensions格式一致
    return this.supportedExtensions.includes(ext);
  }

  protected generateBlockId(filePath: string, index: number, suffix?: string): string {
    const base = `${filePath}_${index}${suffix ? '_' + suffix : ''}_${Date.now()}`;
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(base);
    const hash = this.simpleHash(data);
    return hash.substring(0, 12);
  }

  protected simpleHash(data: Uint8Array): string {
    let hash = 0;
    for (let i = 0; i < data.length; i++) {
      const char = data[i];
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return Math.abs(hash).toString(16).padStart(8, '0');
  }

  protected extractTextFromContent(content: string | Record<string, Object> | Object[]): string {
    if (typeof content === 'string') {
      return content;
    } else if (Array.isArray(content)) {
      const texts: string[] = [];
      for (const item of content) {
        if (typeof item === 'string') {
          texts.push(item);
        } else if (typeof item === 'object' && item !== null) {
          const record = item as Record<string, string>;
          if (record['text'] !== undefined) {
            texts.push(record['text']);
          }
        }
      }
      return texts.join(' ');
    } else if (typeof content === 'object' && content !== null) {
      const record = content as Record<string, string>;
      if (record['text'] !== undefined) {
        return record['text'];
      }
    }
    return '';
  }

  /**
   * 解码URL编码的文件名
   */
  protected decodeFileName(name: string): string {
    try {
      if (name.includes('%')) {
        return decodeURIComponent(name);
      }
      return name;
    } catch (e) {
      // 如果解码失败，手动替换常见编码
      return name.replace(/%20/g, ' ')
        .replace(/%25/g, '%')
        .replace(/%2B/g, '+')
        .replace(/%2F/g, '/')
        .replace(/%3A/g, ':')
        .replace(/%40/g, '@')
        .replace(/%E5/g, '') // 常见中文字符前缀
        .replace(/%E6/g, '')
        .replace(/%E7/g, '')
        .replace(/%E8/g, '')
        .replace(/%E9/g, '');
    }
  }
}
