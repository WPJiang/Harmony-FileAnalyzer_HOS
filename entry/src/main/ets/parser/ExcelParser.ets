﻿/**
 * ExcelParser - Microsoft Excel (.xlsx) file parser for HarmonyOS
 *
 * Parses .xlsx files by:
 * 1. Reading the ZIP container
 * 2. Extracting xl/sharedStrings.xml and xl/worksheets/sheet*.xml
 * 3. Parsing XML to extract cell content
 * 4. Extracting media images from xl/media/
 */

import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ZipReader, ZipEntry } from './ZipReader';
import { CacheUtils } from '../utils/CacheUtils';

const SHARED_STRINGS_XML: string = 'xl/sharedStrings.xml';
const WORKSHEET_PATTERN: RegExp = /^xl\/worksheets\/sheet\d+\.xml$/;

export class ExcelParser extends BaseParser {
  private static readonly MEDIA_PATTERN = /^xl\/media\/(image\d+\.(png|jpg|jpeg|gif|svg|bmp|webp|emf|wmf))$/i;

  constructor() {
    super();
    this.supportedExtensions = ['.xlsx', '.xls'];
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      throw new Error(`Unsupported file format: ${filePath}`);
    }

    console.info(`[ExcelParser] ========== START PARSING: ${filePath} ==========`);

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    const decodedFileName = this.decodeFileName(fileName);
    console.info(`[ExcelParser] File name decoded: "${decodedFileName}"`);

    const cacheUtils = CacheUtils.getInstance();

    // Step 1: Get cache path
    let cachePath = '';
    try {
      cachePath = await cacheUtils.getDataBlocksCachePath(filePath);
      console.info(`[ExcelParser] Step 1 SUCCESS - Cache path: ${cachePath}`);
    } catch (cacheErr) {
      console.error(`[ExcelParser] Step 1 FAILED - Get cache path error:`, cacheErr);
      // Create placeholder block
      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TABLE);
      block.setContent(`[Excel缓存目录创建失败: ${decodedFileName}]`);
      block.setTextContent(`Excel - ${decodedFileName}`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);
      block.setMetadata({'source': 'excelparser', 'fileName': decodedFileName, 'format': 'xlsx', 'error': 'cache_path_failed', 'parsingMode': 'error'});
      blocks.push(block);
      return blocks;
    }

    try {
      // Step 2: Read ZIP file
      console.info(`[ExcelParser] Step 2 - Reading ZIP file...`);
      const entries = await ZipReader.readZipFile(filePath);
      console.info(`[ExcelParser] Step 2 SUCCESS - ZIP entries count: ${entries.size}`);

      // Step 3: Extract shared strings table
      console.info(`[ExcelParser] Step 3 - Extracting shared strings...`);
      const sharedStrings = await this.extractSharedStrings(entries);
      console.info(`[ExcelParser] Step 3 RESULT - Shared strings count: ${sharedStrings.length}`);

      // Step 4: Extract worksheets
      console.info(`[ExcelParser] Step 4 - Extracting worksheets...`);
      const worksheets = await this.extractWorksheets(entries);
      console.info(`[ExcelParser] Step 4 RESULT - Worksheets count: ${worksheets.size}`);

      // Step 5: Process each worksheet
      console.info(`[ExcelParser] Step 5 - Processing worksheets...`);
      let sheetIndex = 1;
      const sheetNames = Array.from(worksheets.keys());
      for (const name of sheetNames) {
        const sheetXml = worksheets.get(name)!;
        const sheetContent = this.parseWorksheet(sheetXml, sharedStrings, sheetIndex);

        if (sheetContent.trim()) {
          // 保存表格内容到缓存文件
          const tableCachePath = await cacheUtils.saveTextToCache(sheetContent, cachePath, `table_${sheetIndex}.txt`);
          console.info(`[ExcelParser] Sheet ${sheetIndex} saved to: ${tableCachePath}`);

          const block = new DataBlock();
          block.setBlockId(this.generateBlockId(filePath, sheetIndex, 'sheet'));
          block.setModality(ModalityType.TABLE);
          block.setContent(sheetContent);
          block.setTextContent(sheetContent);
          block.setFilePath(filePath);
          block.setAddr(tableCachePath);  // 表格块：addr = 缓存文件路径
          block.setPageNumber(sheetIndex);

          const meta: FileMetadata = {
            'source': 'excelparser',
            'fileName': decodedFileName,
            'format': 'xlsx',
            'sheetName': name,
            'sheetIndex': sheetIndex,
            'parsingMode': 'local',
            'cachePath': tableCachePath
          };
          block.setMetadata(meta);
          blocks.push(block);
        }

        sheetIndex++;
      }

      // Step 6: Extract media images
      console.info(`[ExcelParser] Step 6 - Extracting media images...`);
      const mediaBlocks = await this.extractMediaImages(entries, filePath, cachePath, decodedFileName);
      console.info(`[ExcelParser] Step 6 RESULT - Extracted ${mediaBlocks.length} media image blocks`);
      blocks.push(...mediaBlocks);

      // Step 7: Check if no content extracted
      console.info(`[ExcelParser] Step 7 - Total blocks: ${blocks.length}`);

      // If no content extracted, create placeholder
      if (blocks.length === 0) {
        console.warn(`[ExcelParser] Step 7 - No blocks created, creating placeholder`);
        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TABLE);
        block.setContent(`[Excel表格: ${decodedFileName}]`);
        block.setTextContent(`Excel表格 - ${decodedFileName}`);
        block.setFilePath(filePath);
        block.setAddr(filePath);  // 占位块使用原始文件路径
        block.setPageNumber(1);

        const meta: FileMetadata = {
          'source': 'excelparser',
          'fileName': decodedFileName,
          'format': 'xlsx',
          'parsingMode': 'placeholder'
        };
        block.setMetadata(meta);
        blocks.push(block);
      }

    } catch (err) {
      console.error(`[ExcelParser] ========== EXCEPTION ==========`);
      console.error(`[ExcelParser] Error message: ${(err as Error).message}`);
      console.error(`[ExcelParser] Error stack: ${(err as Error).stack}`);

      const block = new DataBlock();
      block.setBlockId(this.generateBlockId(filePath, 0));
      block.setModality(ModalityType.TABLE);
      block.setContent(`[Excel表格解析错误: ${decodedFileName}]`);
      block.setTextContent(`Excel表格 - ${decodedFileName} (解析错误)`);
      block.setFilePath(filePath);
      block.setAddr(filePath);
      block.setPageNumber(1);

      const meta: FileMetadata = {
        'source': 'excelparser',
        'fileName': decodedFileName,
        'format': 'xlsx',
        'error': (err as Error).message,
        'parsingMode': 'error'
      };
      block.setMetadata(meta);
      blocks.push(block);
    }

    console.info(`[ExcelParser] ========== END PARSING: returning ${blocks.length} blocks ==========`);
    return blocks;
  }

  /**
   * Extract shared strings table from ZIP entries
   */
  private async extractSharedStrings(entries: Map<string, ZipEntry>): Promise<string[]> {
    const strings: string[] = [];

    const entry = entries.get(SHARED_STRINGS_XML);
    if (entry && entry.data) {
      const xmlContent = this.decodeUtf8(entry.data);
      const parsed = this.parseSharedStringsXml(xmlContent);
      for (let i = 0; i < parsed.length; i++) {
        strings.push(parsed[i]);
      }
    }

    return strings;
  }

  /**
   * Parse sharedStrings.xml to extract string table
   */
  private parseSharedStringsXml(xmlContent: string): string[] {
    const strings: string[] = [];

    // Extract <si> (string item) elements
    const siPattern = /<si[^>]*>(.*?)<\/si>/gs;
    const matches = xmlContent.match(siPattern);

    if (matches) {
      for (let i = 0; i < matches.length; i++) {
        const text = this.extractTextFromSi(matches[i]);
        strings.push(text);
      }
    }

    return strings;
  }

  /**
   * Extract text from a shared string item
   */
  private extractTextFromSi(siContent: string): string {
    const texts: string[] = [];

    // Handle <t> (text) elements
    const tPattern = /<t[^>]*>([^<]*)<\/t>/g;
    let match: RegExpExecArray | null = null;

    while (true) {
      match = tPattern.exec(siContent);
      if (match === null) break;
      texts.push(this.unescapeXml(match[1]));
    }

    // Also handle inline rich text (<r> elements)
    const rPattern = /<r[^>]*>(.*?)<\/r>/gs;
    const rMatches = siContent.match(rPattern);

    if (rMatches) {
      for (let i = 0; i < rMatches.length; i++) {
        const rMatch = rMatches[i];
        const tInR = /<t[^>]*>([^<]*)<\/t>/;
        const textMatch = rMatch.match(tInR);
        if (textMatch) {
          texts.push(this.unescapeXml(textMatch[1]));
        }
      }
    }

    return texts.join('');
  }

  /**
   * Extract worksheets from ZIP entries
   */
  private async extractWorksheets(entries: Map<string, ZipEntry>): Promise<Map<string, string>> {
    const worksheets = new Map<string, string>();

    entries.forEach((entry: ZipEntry, name: string) => {
      if (WORKSHEET_PATTERN.test(name) && entry.data) {
        const xmlContent = this.decodeUtf8(entry.data);
        worksheets.set(name, xmlContent);
      }
    });

    return worksheets;
  }

  /**
   * Extract media images from ZIP entries
   * Images are stored in xl/media/ directory (e.g., image1.png, image2.jpg)
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
      if (ExcelParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;
        console.info(`[ExcelParser] Found media image: ${name}, size=${entry.data.length}, fileName=${imageFileName}`);
      }
    });

    if (imageIndex === 0) {
      console.info('[ExcelParser] No media images found in xl/media/');
      return mediaBlocks;
    }

    // Process each media image
    imageIndex = 0;
    const entryNames = Array.from(entries.keys());
    for (const name of entryNames) {
      const entry = entries.get(name)!;
      if (ExcelParser.MEDIA_PATTERN.test(name) && entry.data) {
        imageIndex++;
        const imageFileName = name.split('/').pop() || `image${imageIndex}`;

        try {
          // Save image to cache directory
          console.info(`[ExcelParser] Saving image ${imageIndex}: ${imageFileName} to cache...`);
          const imageCachePath = await cacheUtils.saveBinaryToCache(
            entry.data!.buffer.slice(entry.data!.byteOffset, entry.data!.byteOffset + entry.data!.length),
            cachePath,
            imageFileName
          );

          if (imageCachePath) {
            console.info(`[ExcelParser] Image saved to: ${imageCachePath}`);

            // Create DataBlock for image
            const block = new DataBlock();
            block.setBlockId(this.generateBlockId(filePath, imageIndex, 'media'));
            block.setModality(ModalityType.IMAGE);
            block.setContent(`[Excel图片: ${imageFileName}]`);
            block.setTextContent(`Excel图片 - ${decodedFileName} - ${imageFileName}`);
            block.setFilePath(filePath);
            block.setAddr(imageCachePath);  // 图片块：addr = 缓存图片路径
            block.setPageNumber(0);  // 媒体图片不属于特定工作表

            const meta: FileMetadata = {
              'source': 'excelparser',
              'fileName': decodedFileName,
              'format': 'xlsx',
              'mediaName': name,
              'mediaFileName': imageFileName,
              'mediaIndex': imageIndex,
              'parsingMode': 'local',
              'cachePath': imageCachePath
            };
            block.setMetadata(meta);
            mediaBlocks.push(block);
            console.info(`[ExcelParser] Media block created for image ${imageIndex}`);
          } else {
            console.warn(`[ExcelParser] Failed to save image ${imageFileName} to cache`);
          }
        } catch (saveErr) {
          console.error(`[ExcelParser] Error saving image ${imageFileName}:`, saveErr);
        }
      }
    }

    console.info(`[ExcelParser] Total media image blocks: ${mediaBlocks.length}`);
    return mediaBlocks;
  }

  /**
   * Parse worksheet XML to extract cell content
   */
  private parseWorksheet(xmlContent: string, sharedStrings: string[], sheetIndex: number): string {
    const texts: string[] = [];

    // Extract sheet data
    const sheetDataMatch = xmlContent.match(/<sheetData[^>]*>(.*?)<\/sheetData>/s);
    if (!sheetDataMatch) {
      return '';
    }

    const sheetData = sheetDataMatch[1];

    // Parse rows
    const rowPattern = /<row[^>]*r="(\d+)"[^>]*>(.*?)<\/row>/gs;
    let rowMatch: RegExpExecArray | null = null;

    while (true) {
      rowMatch = rowPattern.exec(sheetData);
      if (rowMatch === null) break;

      const rowNum = rowMatch[1];
      const rowContent = rowMatch[2];
      const cells = this.parseRowCells(rowContent, sharedStrings);

      if (cells.length > 0) {
        const rowText = cells.join('\t');
        texts.push(`行${rowNum}: ${rowText}`);
      }
    }

    // Also format as table-like content
    if (texts.length > 0) {
      const header = `=== 工作表 ${sheetIndex} ===\n`;
      return header + texts.join('\n');
    }

    return '';
  }

  /**
   * Parse cells in a row
   */
  private parseRowCells(rowContent: string, sharedStrings: string[]): string[] {
    const cells: string[] = [];

    // Parse cell elements <c r="A1" ...>
    const cellPattern = /<c[^>]*r="([A-Z]+\d+)"[^>]*>(.*?)<\/c>/gs;
    let cellMatch: RegExpExecArray | null = null;

    while (true) {
      cellMatch = cellPattern.exec(rowContent);
      if (cellMatch === null) break;

      const cellContent = cellMatch[2];
      const cellValue = this.extractCellValue(cellContent, sharedStrings);

      if (cellValue) {
        cells.push(cellValue);
      }
    }

    return cells;
  }

  /**
   * Extract cell value from cell content
   */
  private extractCellValue(cellContent: string, sharedStrings: string[]): string {
    // Extract <v> (value) element
    const vPattern = /<v[^>]*>([^<]*)<\/v>/;
    const vMatch = cellContent.match(vPattern);

    if (vMatch) {
      const value = vMatch[1];

      // Check if it's a shared string reference
      if (cellContent.includes('t="s"') || cellContent.includes('t="sharedStr"')) {
        const index = parseInt(value);
        if (index >= 0 && index < sharedStrings.length) {
          return sharedStrings[index];
        }
      }

      // Check for boolean
      if (cellContent.includes('t="b"')) {
        return value === '1' ? 'true' : 'false';
      }

      // Otherwise, it's a number or string
      return value;
    }

    // Check for inline string <is>
    const isPattern = /<is[^>]*>(.*?)<\/is>/s;
    const isMatch = cellContent.match(isPattern);

    if (isMatch) {
      return this.extractTextFromSi(isMatch[1]);
    }

    // Check for formula result <f>
    const fPattern = /<f[^>]*>([^<]*)<\/f>/;
    const fMatch = cellContent.match(fPattern);

    if (fMatch) {
      return `[公式: ${fMatch[1]}]`;
    }

    return '';
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