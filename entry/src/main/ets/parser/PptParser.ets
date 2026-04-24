﻿/**
 * PptParser - Microsoft PowerPoint (.pptx) file parser for HarmonyOS
 *
 * Parses .pptx files by:
 * 1. Reading the ZIP container
 * 2. Extracting ppt/slides/slide*.xml (slide content)
 * 3. Parsing XML to extract text from each slide
 * 4. Extracting media images from ppt/media/
 *
 * PPTX structure:
 * - ppt/slides/slide1.xml, slide2.xml, etc.: Slide content
 * - ppt/presentation.xml: Presentation metadata
 * - ppt/slideLayouts/: Slide layout templates
 * - ppt/media/: Embedded images (image1.png, image2.jpg, etc.)
 */

import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ZipReader, ZipEntry } from './ZipReader';
import { CacheUtils } from '../utils/CacheUtils';

export class PptParser extends BaseParser {
  private static readonly SLIDE_PATTERN = /^ppt\/slides\/slide\d+\.xml$/;
  private static readonly MEDIA_PATTERN = /^ppt\/media\/(image\d+\.(png|jpg|jpeg|gif|svg|bmp|webp|emf|wmf))$/i;

  constructor() {
    super();
    this.supportedExtensions = ['.pptx'];
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      throw new Error(`Unsupported file format: ${filePath}`);
    }

    console.info(`[PptParser] ========== START PARSING: ${filePath} ==========`);

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    const decodedFileName = this.decodeFileName(fileName);
    console.info(`[PptParser] File name decoded: "${decodedFileName}"`);

    const cacheUtils = CacheUtils.getInstance();

    // Step 1: Get cache path
    let cachePath = '';
    try {
      cachePath = await cacheUtils.getDataBlocksCachePath(filePath);
      console.info(`[PptParser] Step 1 SUCCESS - Cache path: ${cachePath}`);
    } catch (cacheErr) {
      console.error(`[PptParser] Step 1 FAILED - Get cache path error:`, cacheErr);
      // Create placeholder block
      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TEXT);
      block.setContent(`[PPT缓存目录创建失败: ${decodedFileName}]`);
      block.setTextContent(`PPT - ${decodedFileName}`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);
      block.setMetadata({'source': 'pptparser', 'fileName': decodedFileName, 'format': 'pptx', 'error': 'cache_path_failed', 'parsingMode': 'error'});
      blocks.push(block);
      return blocks;
    }

    try {
      // Step 2: Read ZIP file
      console.info(`[PptParser] Step 2 - Reading ZIP file...`);
      const entries = await ZipReader.readZipFile(filePath);
      console.info(`[PptParser] Step 2 SUCCESS - ZIP entries count: ${entries.size}`);

      if (entries.size === 0) {
        console.error(`[PptParser] Step 2 WARNING - ZIP has 0 entries, file may not be valid PPTX`);
      }

      // Step 3: Extract slides
      console.info(`[PptParser] Step 3 - Extracting slides from entries...`);
      const slides = await this.extractSlides(entries);
      console.info(`[PptParser] Step 3 RESULT - Extracted ${slides.size} slides`);

      // Step 4: Process each slide
      const slideNames = Array.from(slides.keys());
      console.info(`[PptParser] Step 4 - Processing ${slideNames.length} slides...`);

      for (const name of slideNames) {
        const slideXml = slides.get(name)!;
        const slideNum = this.extractSlideNumber(name);
        console.info(`[PptParser] Step 4.1 - Slide "${name}" (num=${slideNum}), XML length=${slideXml.length}`);

        const slideContent = this.parseSlideXml(slideXml);
        console.info(`[PptParser] Step 4.2 - Slide ${slideNum} parsed content length=${slideContent.length}, preview="${slideContent.substring(0, 50)}..."`);

        if (slideContent.trim()) {
          // Step 5: Save to cache
          console.info(`[PptParser] Step 5 - Saving slide ${slideNum} to cache...`);
          const slideCachePath = await cacheUtils.saveTextToCache(slideContent, cachePath, `slide_${slideNum}.txt`);
          console.info(`[PptParser] Step 5 RESULT - Cache path returned: "${slideCachePath}"`);

          if (!slideCachePath) {
            console.error(`[PptParser] Step 5 FAILED - saveTextToCache returned empty string!`);
          }

          const block = new DataBlock();
          block.setBlockId(this.generateBlockId(filePath, slideNum, 'slide'));
          block.setModality(ModalityType.TEXT);
          block.setContent(slideContent);
          block.setTextContent(slideContent);
          block.setFilePath(filePath);
          block.setAddr(slideCachePath);  // 幻灯片块：addr = 缓存文件路径
          block.setPageNumber(slideNum);

          const meta: FileMetadata = {
            'source': 'pptparser',
            'fileName': decodedFileName,
            'format': 'pptx',
            'slideName': name,
            'slideNumber': slideNum,
            'parsingMode': 'local',
            'cachePath': slideCachePath
          };
          block.setMetadata(meta);
          blocks.push(block);
          console.info(`[PptParser] Step 6 - Block created for slide ${slideNum}, addr="${slideCachePath.substring(0, 80)}"`);
        } else {
          console.warn(`[PptParser] Step 4 WARNING - Slide ${slideNum} has empty content, skipped`);
        }
      }

      // Step 7: Extract media images
      console.info(`[PptParser] Step 7 - Extracting media images...`);
      const mediaBlocks = await this.extractMediaImages(entries, filePath, cachePath, decodedFileName);
      console.info(`[PptParser] Step 7 RESULT - Extracted ${mediaBlocks.length} media image blocks`);
      blocks.push(...mediaBlocks);

      // Sort blocks by slide number (text blocks have pageNumber, image blocks have pageNumber 0)
      blocks.sort((a, b) => a.pageNumber - b.pageNumber);
      console.info(`[PptParser] Step 8 - Sorted ${blocks.length} blocks (slides + images)`);

      // If no content extracted, create placeholder
      if (blocks.length === 0) {
        console.warn(`[PptParser] Step 9 - No blocks created, creating placeholder`);
        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TEXT);
        block.setContent(`[PPT演示文稿: ${decodedFileName}]`);
        block.setTextContent(`PPT演示文稿 - ${decodedFileName}`);
        block.setFilePath(filePath);
        block.setAddr(filePath);  // 占位块使用原始文件路径
        block.setPageNumber(1);

        const meta: FileMetadata = {
          'source': 'pptparser',
          'fileName': decodedFileName,
          'format': 'pptx',
          'parsingMode': 'placeholder'
        };
        block.setMetadata(meta);
        blocks.push(block);
      }

    } catch (err) {
      console.error(`[PptParser] ========== EXCEPTION ==========`);
      console.error(`[PptParser] Error message: ${(err as Error).message}`);
      console.error(`[PptParser] Error stack: ${(err as Error).stack}`);

      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TEXT);
      block.setContent(`[PPT演示文稿解析错误: ${decodedFileName}]`);
      block.setTextContent(`PPT演示文稿 - ${decodedFileName} (解析错误)`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);

      const meta: FileMetadata = {
        'source': 'pptparser',
        'fileName': decodedFileName,
        'format': 'pptx',
        'error': (err as Error).message,
        'parsingMode': 'error'
      };
      block.setMetadata(meta);
      blocks.push(block);
    }

    console.info(`[PptParser] ========== END PARSING: returning ${blocks.length} blocks ==========`);
    return blocks;
  }

  /**
   * Extract slides from ZIP entries
   */
  private async extractSlides(entries: Map<string, ZipEntry>): Promise<Map<string, string>> {
    const slides = new Map<string, string>();

    console.info('[PptParser] Total ZIP entries:', entries.size);

    entries.forEach((entry, name) => {
      console.info('[PptParser] Checking entry:', name, 'pattern test:', PptParser.SLIDE_PATTERN.test(name));
      if (PptParser.SLIDE_PATTERN.test(name) && entry.data) {
        const xmlContent = this.decodeUtf8(entry.data);
        console.info('[PptParser] Slide:', name, 'XML length:', xmlContent.length, 'preview:', xmlContent.substring(0, 100));
        slides.set(name, xmlContent);
      } else if (PptParser.SLIDE_PATTERN.test(name)) {
        console.warn('[PptParser] Slide matched but no data:', name);
      }
    });

    console.info('[PptParser] Extracted slides:', slides.size);
    return slides;
  }

  /**
   * Extract media images from ZIP entries
   * Images are stored in ppt/media/ directory (e.g., image1.png, image2.jpg)
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

    entries.forEach((entry, name) => {
      if (PptParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;
        console.info(`[PptParser] Found media image: ${name}, size=${entry.data.length}, fileName=${imageFileName}`);
      }
    });

    if (imageIndex === 0) {
      console.info('[PptParser] No media images found in ppt/media/');
      return mediaBlocks;
    }

    // Process each media image
    imageIndex = 0;
    const entryNames = Array.from(entries.keys());
    for (const name of entryNames) {
      const entry = entries.get(name)!;
      if (PptParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;

        try {
          // Save image to cache directory
          console.info(`[PptParser] Saving image ${imageIndex}: ${imageFileName} to cache...`);
          const imageCachePath = await cacheUtils.saveBinaryToCache(
            entry.data!.buffer.slice(entry.data!.byteOffset, entry.data!.byteOffset + entry.data!.length),
            cachePath,
            imageFileName
          );

          if (imageCachePath) {
            console.info(`[PptParser] Image saved to: ${imageCachePath}`);

            // Create DataBlock for image
            const block = new DataBlock();
            block.setBlockId(this.generateBlockId(filePath, imageIndex, 'media'));
            block.setModality(ModalityType.IMAGE);
            block.setContent(`[PPT图片: ${imageFileName}]`);
            block.setTextContent(`PPT图片 - ${decodedFileName} - ${imageFileName}`);
            block.setFilePath(filePath);
            block.setAddr(imageCachePath);  // 图片块：addr = 缓存图片路径
            block.setPageNumber(0);  // 媒体图片不属于特定幻灯片

            const meta: FileMetadata = {
              'source': 'pptparser',
              'fileName': decodedFileName,
              'format': 'pptx',
              'mediaName': name,
              'mediaFileName': imageFileName,
              'mediaIndex': imageIndex,
              'parsingMode': 'local',
              'cachePath': imageCachePath
            };
            block.setMetadata(meta);
            mediaBlocks.push(block);
            console.info(`[PptParser] Media block created for image ${imageIndex}`);
          } else {
            console.warn(`[PptParser] Failed to save image ${imageFileName} to cache`);
          }
        } catch (saveErr) {
          console.error(`[PptParser] Error saving image ${imageFileName}:`, saveErr);
        }
      }
    }

    console.info(`[PptParser] Total media image blocks: ${mediaBlocks.length}`);
    return mediaBlocks;
  }

  /**
   * Extract slide number from slide name
   */
  private extractSlideNumber(slideName: string): number {
    const match = slideName.match(/slide(\d+)\.xml$/);
    if (match) {
      return parseInt(match[1]);
    }
    return 1;
  }

  /**
   * Parse slide XML to extract text content
   */
  private parseSlideXml(xmlContent: string): string {
    const texts: string[] = [];

    console.info('[PptParser] Parsing slide XML, length:', xmlContent.length);
    console.info('[PptParser] XML preview (first 500 chars):', xmlContent.substring(0, 500));

    // PowerPoint uses <a:t> (DrawingML text) elements for text
    // These are nested inside <p:sp> (shape) elements

    // Extract text from <a:t> tags
    const aTPattern = /<a:t[^>]*>([^<]*)<\/a:t>/g;
    let match: RegExpExecArray | null = null;

    while (true) {
      match = aTPattern.exec(xmlContent);
      if (match === null) break;
      const text = this.unescapeXml(match[1]);
      if (text.trim()) {
        texts.push(text.trim());
      }
    }

    console.info('[PptParser] Found', texts.length, 'text elements via <a:t>');

    // Also extract text from shape bodies
    const spPattern = /<p:sp[^>]*>(.*?)<\/p:sp>/gs;
    const spMatches = xmlContent.match(spPattern);

    if (spMatches) {
      for (const spMatch of spMatches) {
        const shapeText = this.extractTextFromShape(spMatch);
        if (shapeText.trim() && !texts.includes(shapeText.trim())) {
          texts.push(shapeText.trim());
        }
      }
    }

    // Format as slide content
    if (texts.length > 0) {
      return texts.join('\n');
    }

    return '';
  }

  /**
   * Extract text from a shape element
   */
  private extractTextFromShape(shapeXml: string): string {
    const texts: string[] = [];

    // Extract text body <p:txBody>
    const txBodyPattern = /<p:txBody[^>]*>(.*?)<\/p:txBody>/gs;
    const txBodyMatches = shapeXml.match(txBodyPattern);

    if (txBodyMatches) {
      for (const txBodyMatch of txBodyMatches) {
        // Extract paragraphs <a:p>
        const pPattern = /<a:p[^>]*>(.*?)<\/a:p>/gs;
        const pMatches = txBodyMatch.match(pPattern);

        if (pMatches) {
          for (const pMatch of pMatches) {
            // Extract runs <a:r>
            const rPattern = /<a:r[^>]*>(.*?)<\/a:r>/gs;
            const rMatches = pMatch.match(rPattern);

            if (rMatches) {
              for (const rMatch of rMatches) {
                // Extract text <a:t>
                const tPattern = /<a:t[^>]*>([^<]*)<\/a:t>/;
                const tMatch = rMatch.match(tPattern);

                if (tMatch) {
                  texts.push(this.unescapeXml(tMatch[1]));
                }
              }
            }
          }
        }
      }
    }

    return texts.join('');
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