﻿/**
 * WordParser - Microsoft Word (.docx) file parser for HarmonyOS
 *
 * Parses .docx files by:
 * 1. Reading the ZIP container
 * 2. Extracting word/document.xml
 * 3. Parsing XML to extract text content
 * 4. Extracting media images from word/media/
 */

import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ZipReader, ZipEntry } from './ZipReader';
import { CacheUtils } from '../utils/CacheUtils';

const DOCUMENT_XML: string = 'word/document.xml';

export class WordParser extends BaseParser {
  private static readonly MEDIA_PATTERN = /^word\/media\/(image\d+\.(png|jpg|jpeg|gif|svg|bmp|webp|emf|wmf))$/i;

  constructor() {
    super();
    this.supportedExtensions = ['.docx', '.doc'];
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      throw new Error(`Unsupported file format: ${filePath}`);
    }

    console.info(`[WordParser] ========== START PARSING: ${filePath} ==========`);

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    const decodedFileName = this.decodeFileName(fileName);
    console.info(`[WordParser] File name decoded: "${decodedFileName}"`);

    const cacheUtils = CacheUtils.getInstance();

    // Step 1: Get cache path
    let cachePath = '';
    try {
      cachePath = await cacheUtils.getDataBlocksCachePath(filePath);
      console.info(`[WordParser] Step 1 SUCCESS - Cache path: ${cachePath}`);
    } catch (cacheErr) {
      console.error(`[WordParser] Step 1 FAILED - Get cache path error:`, cacheErr);
      // Create placeholder block
      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TEXT);
      block.setContent(`[Word缓存目录创建失败: ${decodedFileName}]`);
      block.setTextContent(`Word - ${decodedFileName}`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);
      block.setMetadata({'source': 'wordparser', 'fileName': decodedFileName, 'format': 'docx', 'error': 'cache_path_failed', 'parsingMode': 'error'});
      blocks.push(block);
      return blocks;
    }

    try {
      // Step 2: Read ZIP file
      console.info(`[WordParser] Step 2 - Reading ZIP file...`);
      const entries = await ZipReader.readZipFile(filePath);
      console.info(`[WordParser] Step 2 SUCCESS - ZIP entries count: ${entries.size}`);

      // Step 3: Extract document.xml
      console.info(`[WordParser] Step 3 - Extracting document.xml...`);
      const xmlContent = await this.extractDocumentXml(entries);
      console.info(`[WordParser] Step 3 RESULT - document.xml length: ${xmlContent?.length || 0}`);

      if (xmlContent) {
        // Step 4: Parse XML to extract text
        console.info(`[WordParser] Step 4 - Parsing document XML...`);
        const textContent = this.parseDocumentXml(xmlContent);
        console.info(`[WordParser] Step 4 RESULT - Text content length: ${textContent.length}`);

        if (textContent.trim()) {
          // Step 5: Save to cache
          console.info(`[WordParser] Step 5 - Saving text to cache...`);
          const textCachePath = await cacheUtils.saveTextToCache(textContent, cachePath, 'text_1.txt');
          console.info(`[WordParser] Step 5 RESULT - Cache path: ${textCachePath}`);

          const block = new DataBlock();
          block.setBlockId(this.generateBlockId(filePath, 0));
          block.setModality(ModalityType.TEXT);
          block.setContent(textContent);
          block.setTextContent(textContent);
          block.setFilePath(filePath);
          block.setAddr(textCachePath);  // 文本块：addr = 缓存文件路径
          block.setPageNumber(1);

          const meta: FileMetadata = {
            'source': 'wordparser',
            'fileName': decodedFileName,
            'format': 'docx',
            'parsingMode': 'local',
            'cachePath': textCachePath
          };
          block.setMetadata(meta);
          blocks.push(block);
          console.info(`[WordParser] Text block created`);
        }
      }

      // Step 6: Extract media images
      console.info(`[WordParser] Step 6 - Extracting media images...`);
      const mediaBlocks = await this.extractMediaImages(entries, filePath, cachePath, decodedFileName);
      console.info(`[WordParser] Step 6 RESULT - Extracted ${mediaBlocks.length} media image blocks`);
      blocks.push(...mediaBlocks);

      // Step 7: Check if no content extracted
      console.info(`[WordParser] Step 7 - Total blocks: ${blocks.length}`);

      // If no content extracted, create placeholder
      if (blocks.length === 0) {
        console.warn(`[WordParser] Step 7 - No blocks created, creating placeholder`);
        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TEXT);
        block.setContent(`[Word文档: ${decodedFileName}]`);
        block.setTextContent(`Word文档 - ${decodedFileName}`);
        block.setFilePath(filePath);
        block.setAddr(filePath);  // 占位块使用原始文件路径
        block.setPageNumber(1);

        const meta: FileMetadata = {
          'source': 'wordparser',
          'fileName': decodedFileName,
          'format': 'docx',
          'parsingMode': 'placeholder'
        };
        block.setMetadata(meta);
        blocks.push(block);
      }

    } catch (err) {
      console.error(`[WordParser] ========== EXCEPTION ==========`);
      console.error(`[WordParser] Error message: ${(err as Error).message}`);
      console.error(`[WordParser] Error stack: ${(err as Error).stack}`);

      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TEXT);
      block.setContent(`[Word文档解析错误: ${decodedFileName}]`);
      block.setTextContent(`Word文档 - ${decodedFileName} (解析错误)`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);

      const meta: FileMetadata = {
        'source': 'wordparser',
        'fileName': decodedFileName,
        'format': 'docx',
        'error': (err as Error).message,
        'parsingMode': 'error'
      };
      block.setMetadata(meta);
      blocks.push(block);
    }

    console.info(`[WordParser] ========== END PARSING: returning ${blocks.length} blocks ==========`);
    return blocks;
  }

  /**
   * Extract document.xml content from ZIP entries
   */
  private async extractDocumentXml(entries: Map<string, ZipEntry>): Promise<string | null> {
    try {
      const entry = entries.get(DOCUMENT_XML);

      if (entry && entry.data) {
        return this.decodeUtf8(entry.data);
      }

      // Try alternative paths - use forEach instead of destructuring
      let foundContent: string | null = null;
      entries.forEach((entryData: ZipEntry, entryName: string) => {
        if (entryName.includes('document.xml') && entryData.data && foundContent === null) {
          foundContent = this.decodeUtf8(entryData.data);
        }
      });

      return foundContent;
    } catch (err) {
      console.error('[WordParser] Failed to extract document.xml:', err);
      return null;
    }
  }

  /**
   * Extract media images from ZIP entries
   * Images are stored in word/media/ directory (e.g., image1.png, image2.jpg)
   */
  private async extractMediaImages(
    entries: Map<string, ZipEntry>,
    filePath: string,
    cachePath: string,
    decodedFileName: string
  ): Promise<DataBlock[]> {
    const cacheUtils = CacheUtils.getInstance();
    const mediaBlocks: DataBlock[] = [];
    let imageIndex = 0;

    // First, count media images
    entries.forEach((entry, name) => {
      if (WordParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;
        console.info(`[WordParser] Found media image: ${name}, size=${entry.data.length}, fileName=${imageFileName}`);
      }
    });

    if (imageIndex === 0) {
      console.info('[WordParser] No media images found in word/media/');
      return mediaBlocks;
    }

    // Process each media image
    imageIndex = 0;
    const entryNames = Array.from(entries.keys());
    for (const name of entryNames) {
      const entry = entries.get(name)!;
      if (WordParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;

        try {
          // Save image to cache directory
          console.info(`[WordParser] Saving image ${imageIndex}: ${imageFileName} to cache...`);
          const imageCachePath = await cacheUtils.saveBinaryToCache(
            entry.data!.buffer.slice(entry.data!.byteOffset, entry.data!.byteOffset + entry.data!.length),
            cachePath,
            imageFileName
          );

          if (imageCachePath) {
            console.info(`[WordParser] Image saved to: ${imageCachePath}`);

            // Create DataBlock for image
            const block = new DataBlock();
            block.setBlockId(this.generateBlockId(filePath, imageIndex, 'media'));
            block.setModality(ModalityType.IMAGE);
            block.setContent(`[Word图片: ${imageFileName}]`);
            block.setTextContent(`Word图片 - ${decodedFileName} - ${imageFileName}`);
            block.setFilePath(filePath);
            block.setAddr(imageCachePath);  // 图片块：addr = 缓存图片路径
            block.setPageNumber(0);  // 媒体图片不属于特定段落

            const meta: FileMetadata = {
              'source': 'wordparser',
              'fileName': decodedFileName,
              'format': 'docx',
              'mediaName': name,
              'mediaFileName': imageFileName,
              'mediaIndex': imageIndex,
              'parsingMode': 'local',
              'cachePath': imageCachePath
            };
            block.setMetadata(meta);
            mediaBlocks.push(block);
            console.info(`[WordParser] Media block created for image ${imageIndex}`);
          } else {
            console.warn(`[WordParser] Failed to save image ${imageFileName} to cache`);
          }
        } catch (saveErr) {
          console.error(`[WordParser] Error saving image ${imageFileName}:`, saveErr);
        }
      }
    }

    console.info(`[WordParser] Total media image blocks: ${mediaBlocks.length}`);
    return mediaBlocks;
  }

  /**
   * Parse document.xml to extract text content
   */
  private parseDocumentXml(xmlContent: string): string {
    const textMatches = this.extractTagContent(xmlContent, 'w:t');

    // Build texts array without spread operator
    const texts: string[] = [];
    for (let i = 0; i < textMatches.length; i++) {
      texts.push(textMatches[i]);
    }

    // Process paragraphs - split by <w:p> tags
    const paragraphs = this.extractParagraphs(xmlContent);

    // Join paragraphs with newlines
    return paragraphs.join('\n\n');
  }

  /**
   * Extract paragraphs from document XML
   */
  private extractParagraphs(xmlContent: string): string[] {
    const paragraphs: string[] = [];

    // Split by paragraph tags
    const pPattern = /<w:p[^>]*>(.*?)<\/w:p>/gs;
    const matches = xmlContent.match(pPattern);

    if (matches) {
      for (let i = 0; i < matches.length; i++) {
        const text = this.extractTextFromParagraph(matches[i]);
        if (text.trim()) {
          paragraphs.push(text.trim());
        }
      }
    }

    return paragraphs;
  }

  /**
   * Extract text content from a single paragraph
   */
  private extractTextFromParagraph(paragraphXml: string): string {
    const texts: string[] = [];

    // Also handle self-closing and attributes
    const tPattern2 = /<w:t[^>]*>(.*?)<\/w:t>/gs;

    // Get all text elements
    const textElements = paragraphXml.match(tPattern2);
    if (textElements) {
      for (let i = 0; i < textElements.length; i++) {
        const element = textElements[i];
        // Extract the content between tags
        const content = element.replace(/<w:t[^>]*>/, '').replace(/<\/w:t>/, '');
        texts.push(this.unescapeXml(content));
      }
    }

    return texts.join('');
  }

  /**
   * Extract content from XML tags
   */
  private extractTagContent(xmlContent: string, tagName: string): string[] {
    const results: string[] = [];
    const pattern = new RegExp(`<${tagName}[^>]*>([^<]*)</${tagName}>`, 'g');
    let match: RegExpExecArray | null = null;

    while (true) {
      match = pattern.exec(xmlContent);
      if (match === null) break;

      const content = this.unescapeXml(match[1]);
      if (content.trim()) {
        results.push(content);
      }
    }

    return results;
  }

  /**
   * Decode UTF-8 bytes to string
   */
  private decodeUtf8(bytes: Uint8Array): string {
    try {
      const decoder = new util.TextDecoder('utf-8');
      return decoder.decodeToString(bytes);
    } catch {
      // Fallback for basic ASCII
      let result = '';
      for (let i = 0; i < bytes.length; i++) {
        const byte = bytes[i];
        if (byte === 0) break;
        if (byte < 128) {
          result += String.fromCharCode(byte);
        } else {
          // Handle multi-byte UTF-8
          if ((byte & 0xE0) === 0xC0 && i + 1 < bytes.length) {
            const codePoint = ((byte & 0x1F) << 6) | (bytes[i + 1] & 0x3F);
            result += String.fromCharCode(codePoint);
            i++;
          } else if ((byte & 0xF0) === 0xE0 && i + 2 < bytes.length) {
            const codePoint = ((byte & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
            result += String.fromCharCode(codePoint);
            i += 2;
          } else {
            result += String.fromCharCode(byte);
          }
        }
      }
      return result;
    }
  }

  /**
   * Unescape XML entities
   */
  private unescapeXml(text: string): string {
    return text
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'");
  }
}