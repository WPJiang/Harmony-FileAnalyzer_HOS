import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import pdfService from '@hms.officeservice.pdfservice';
import { CacheUtils } from '../utils/CacheUtils';
import { fileIo } from '@kit.CoreFileKit';

/**
 * HarmonyOS PDF解析器
 *
 * 使用HMS PDF服务加载PDF，通过getTextContent获取文本，getPagePixelMap获取图像
 *
 * 设计原则（与Python项目保持一致）：
 * - addr字段指向解析生成的缓存文件路径（txt文件或图片文件）
 * - 文本内容保存到cache/data_blocks目录下
 * - 对于PDF文件，每页生成文本数据块和可选的图像数据块
 *
 * API要求：
 * - getTextContent(): string - 获取页面文本内容（需要API 6.1.0(23)+）
 * - getPagePixelMap(): image.PixelMap - 获取页面图像
 */
export class PDFParser extends BaseParser {
  private extractImages: boolean = false;

  constructor(extractImages: boolean = false) {
    super();
    this.supportedExtensions = ['.pdf'];
    this.extractImages = extractImages;
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      throw new Error(`Unsupported file format: ${filePath}`);
    }

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    const decodedFileName = this.decodeFileName(fileName);
    const cacheUtils = CacheUtils.getInstance();

    // 获取缓存目录
    let cachePath = '';
    try {
      cachePath = await cacheUtils.getDataBlocksCachePath(filePath);
      console.info('[PDFParser] Cache path obtained:', cachePath);
    } catch (e) {
      console.error('[PDFParser] Failed to get cache path:', e);
      // 尝试手动获取缓存目录
      const baseDir = cacheUtils.getBaseCacheDir();
      if (baseDir) {
        const fileNameHash = cacheUtils.generateFileHash(filePath);
        const nameWithoutExt = decodedFileName.substring(0, decodedFileName.lastIndexOf('.')) || decodedFileName;
        cachePath = `${baseDir}/data_blocks/${nameWithoutExt}_${fileNameHash}`;
        console.info('[PDFParser] Using fallback cache path:', cachePath);
        // 确保目录存在
        try {
          await cacheUtils.ensureDir(cachePath);
        } catch (dirErr) {
          console.error('[PDFParser] Failed to create fallback dir:', dirErr);
          cachePath = '';
        }
      } else {
        console.error('[PDFParser] CacheUtils not initialized, baseCacheDir is empty');
      }
    }

    if (!cachePath) {
      console.warn('[PDFParser] No valid cache path available, PDF content will not be cached');
    }

    // HMS PDF服务需要文件在应用sandbox目录，不能直接使用picker URI
    // 需要先复制文件到sandbox temp目录
    let sandboxPath = filePath;
    let needsCleanup = false;

    try {
      // 尝试直接加载，如果失败则复制文件到sandbox
      const testDoc = new pdfService.PdfDocument();
      const testResult = testDoc.loadDocument(filePath);

      if (testResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        console.info('[PDFParser] Direct load failed, result:', testResult, 'copying to sandbox...');
        testDoc.releaseDocument();

        // 使用CacheUtils的缓存目录作为sandbox临时目录
        // CacheUtils在应用启动时已初始化
        const sandboxDir = cacheUtils.getBaseCacheDir();
        if (!sandboxDir) {
          console.error('[PDFParser] CacheUtils not initialized, cannot copy file');
          throw new Error('CacheUtils not initialized');
        }

        sandboxPath = `${sandboxDir}/${decodedFileName}`;
        console.info('[PDFParser] Sandbox path:', sandboxPath);

        // 复制文件到sandbox
        const sourceFile = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
        const stat = await fileIo.stat(sourceFile.fd);
        const fileSize = stat.size;
        console.info('[PDFParser] Source file size:', fileSize);

        const buffer = new ArrayBuffer(fileSize);
        await fileIo.read(sourceFile.fd, buffer);
        await fileIo.close(sourceFile.fd);

        const destFile = await fileIo.open(sandboxPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        await fileIo.write(destFile.fd, buffer);
        await fileIo.close(destFile.fd);

        needsCleanup = true;
        console.info('[PDFParser] File copied to sandbox:', sandboxPath);
      } else {
        console.info('[PDFParser] Direct load succeeded!');
        testDoc.releaseDocument();
      }
    } catch (copyErr) {
      console.error('[PDFParser] Failed to copy file to sandbox:', copyErr);
    }

    try {
      // 使用PDF服务加载文档（使用sandbox路径）
      const pdfDoc = new pdfService.PdfDocument();
      const loadResult = pdfDoc.loadDocument(sandboxPath);

      if (loadResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        console.warn('[PDFParser] PDF load result:', loadResult);

        // 加载失败时保存占位信息到缓存
        const placeholderContent = `[PDF文件加载失败: ${decodedFileName}]`;
        let placeholderAddr = filePath;
        if (cachePath) {
          const savedPath = await cacheUtils.saveTextToCache(placeholderContent, cachePath, 'placeholder.txt');
          if (savedPath) {
            placeholderAddr = savedPath;
          }
        }

        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TEXT);
        block.setContent(placeholderContent);
        block.setTextContent(placeholderContent);
        block.setFilePath(filePath);
        block.setAddr(placeholderAddr);
        block.setPageNumber(1);
        const meta: FileMetadata = {
          'source': 'pdf_load_failed',
          'loadResult': loadResult,
          'fileName': decodedFileName,
          'originalPath': filePath
        };
        block.setMetadata(meta);
        blocks.push(block);
        return blocks;
      }

      // 获取页面数量
      const pageCount = pdfDoc.getPageCount();
      console.info('[PDFParser] PDF loaded successfully, page count:', pageCount);

      // 遍历每一页，提取文本和图像
      for (let i = 0; i < pageCount; i++) {
        try {
          const page = pdfDoc.getPage(i);
          const pageNum = i + 1;

          // 1. 使用getTextContent获取页面文本内容（API 6.1.0+）
          const textContent = page.getTextContent();

          if (textContent && textContent.trim()) {
            // 保存文本到缓存文件
            const textCachePath = await cacheUtils.saveTextToCache(
              textContent,
              cachePath,
              `text_${pageNum}.txt`
            );

            // 创建文本数据块
            const textBlock = new DataBlock();
            textBlock.setBlockId(this.generateBlockId(filePath, pageNum, 'text'));
            textBlock.setModality(ModalityType.TEXT);
            textBlock.setContent(textContent);
            textBlock.setTextContent(textContent);
            textBlock.setFilePath(filePath);
            textBlock.setAddr(textCachePath);  // addr指向缓存文件路径
            textBlock.setPageNumber(pageNum);

            const textMeta: FileMetadata = {
              'source': 'pdf_text',
              'fileName': decodedFileName,
              'pageCount': pageCount,
              'pageWidth': page.getWidth(),
              'pageHeight': page.getHeight(),
              'cachePath': textCachePath,
              'textLength': textContent.length
            };
            textBlock.setMetadata(textMeta);
            blocks.push(textBlock);

            console.info(`[PDFParser] Page ${pageNum}: getTextContent extracted ${textContent.length} chars`);
          } else {
            // 没有提取到文本，创建占位块
            const emptyText = `[PDF页面 ${pageNum}: ${decodedFileName} - 无文本内容]`;
            const savedPath = await cacheUtils.saveTextToCache(emptyText, cachePath, `page_${pageNum}_empty.txt`);

            const emptyBlock = new DataBlock();
            emptyBlock.setBlockId(this.generateBlockId(filePath, pageNum, 'empty'));
            emptyBlock.setModality(ModalityType.TEXT);
            emptyBlock.setContent(emptyText);
            emptyBlock.setTextContent(emptyText);
            emptyBlock.setFilePath(filePath);
            emptyBlock.setAddr(savedPath || filePath);
            emptyBlock.setPageNumber(pageNum);

            const emptyMeta: FileMetadata = {
              'source': 'pdf_text_empty',
              'fileName': decodedFileName,
              'pageCount': pageCount,
              'pageWidth': page.getWidth(),
              'pageHeight': page.getHeight()
            };
            emptyBlock.setMetadata(emptyMeta);
            blocks.push(emptyBlock);
          }

          // 2. 如果需要提取图像，使用getPagePixelMap获取页面图像
          if (this.extractImages) {
            try {
              const pixelMap = page.getPagePixelMap();

              if (pixelMap) {
                // 保存图像到缓存目录
                const imageCachePath = await cacheUtils.savePixelMapToCache(
                  pixelMap,
                  cachePath,
                  `image_${pageNum}.png`
                );

                if (imageCachePath) {
                  // 创建图像数据块
                  const imageBlock = new DataBlock();
                  imageBlock.setBlockId(this.generateBlockId(filePath, pageNum, 'image'));
                  imageBlock.setModality(ModalityType.IMAGE);
                  imageBlock.setContent(`[PDF页面 ${pageNum} 图像]`);
                  imageBlock.setTextContent(`[PDF页面 ${pageNum} 图像]`);
                  imageBlock.setFilePath(filePath);
                  imageBlock.setAddr(imageCachePath);  // addr指向缓存图片路径
                  imageBlock.setPageNumber(pageNum);

                  const imageMeta: FileMetadata = {
                    'source': 'pdf_image',
                    'fileName': decodedFileName,
                    'pageCount': pageCount,
                    'pageWidth': page.getWidth(),
                    'pageHeight': page.getHeight(),
                    'cachePath': imageCachePath
                  };
                  imageBlock.setMetadata(imageMeta);
                  blocks.push(imageBlock);

                  console.info(`[PDFParser] Page ${pageNum}: getPagePixelMap extracted image`);
                }

                // 释放PixelMap
                pixelMap.release();
              }
            } catch (imgErr) {
              console.warn(`[PDFParser] getPagePixelMap failed for page ${pageNum}:`, imgErr);
            }
          }

        } catch (pageErr) {
          console.error(`[PDFParser] Failed to process page ${i + 1}:`, pageErr);

          // 页面处理失败，创建占位块并保存到缓存
          const errorText = `[PDF页面 ${i + 1} 处理失败: ${decodedFileName}]`;
          const savedPath = await cacheUtils.saveTextToCache(errorText, cachePath, `page_${i + 1}_error.txt`);

          const errorBlock = new DataBlock();
          errorBlock.setBlockId(this.generateBlockId(filePath, i + 1, 'error'));
          errorBlock.setModality(ModalityType.TEXT);
          errorBlock.setContent(errorText);
          errorBlock.setTextContent(errorText);
          errorBlock.setFilePath(filePath);
          errorBlock.setAddr(savedPath || filePath);
          errorBlock.setPageNumber(i + 1);

          const errorMeta: FileMetadata = {
            'source': 'pdf_page_error',
            'fileName': decodedFileName,
            'pageCount': pageCount,
            'error': String(pageErr),
            'originalPath': filePath
          };
          errorBlock.setMetadata(errorMeta);
          blocks.push(errorBlock);
        }
      }

      // 释放PDF文档
      pdfDoc.releaseDocument();

      // 如果没有任何成功提取的块，创建基本信息块
      if (blocks.length === 0) {
        const basicText = `PDF文档 - ${decodedFileName} (${pageCount}页)`;
        const savedPath = await cacheUtils.saveTextToCache(basicText, cachePath, 'basic.txt');

        const basicBlock = new DataBlock();
        basicBlock.setBlockId(this.generateBlockId(filePath, 0, 'basic'));
        basicBlock.setModality(ModalityType.TEXT);
        basicBlock.setContent(basicText);
        basicBlock.setTextContent(basicText);
        basicBlock.setFilePath(filePath);
        basicBlock.setAddr(savedPath || filePath);
        basicBlock.setPageNumber(1);

        const basicMeta: FileMetadata = {
          'source': 'pdf_basic',
          'fileName': decodedFileName,
          'pageCount': pageCount,
          'originalPath': filePath
        };
        basicBlock.setMetadata(basicMeta);
        blocks.push(basicBlock);
      }

    } catch (err) {
      console.error('[PDFParser] Failed to parse PDF:', err);

      if (blocks.length === 0) {
        const errorText = `[PDF解析错误: ${decodedFileName}]`;
        const savedPath = await cacheUtils.saveTextToCache(errorText, cachePath, 'error.txt');

        const block = new DataBlock();
        block.setBlockId(this.generateBlockId(filePath, 0));
        block.setModality(ModalityType.TEXT);
        block.setContent(errorText);
        block.setTextContent(errorText);
        block.setFilePath(filePath);
        block.setAddr(savedPath || filePath);
        block.setPageNumber(1);

        const meta: FileMetadata = {
          'source': 'pdf_parse_error',
          'fileName': decodedFileName,
          'error': String(err),
          'originalPath': filePath
        };
        block.setMetadata(meta);
        blocks.push(block);
      }
    }

    // 清理sandbox临时文件
    if (needsCleanup && sandboxPath !== filePath) {
      try {
        await fileIo.unlink(sandboxPath);
        console.info('[PDFParser] Sandbox temp file cleaned up:', sandboxPath);
      } catch (cleanupErr) {
        console.warn('[PDFParser] Failed to cleanup sandbox file:', cleanupErr);
      }
    }

    console.info(`[PDFParser] Parse complete: ${blocks.length} blocks, fileName: ${decodedFileName}`);
    return blocks;
  }
}