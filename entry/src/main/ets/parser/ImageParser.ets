﻿import { DataBlock, ModalityType, FileMetadata } from '../models/Index';
import { BaseParser } from './BaseParser';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { LocalOCRService, OCRResult } from '../services/LocalOCRService';
import { CacheUtils } from '../utils/CacheUtils';

interface ImageSize {
  width: number;
  height: number;
}

export class ImageParser extends BaseParser {
  private ocrService: LocalOCRService;
  private useOcr: boolean = true;

  constructor(useOcr: boolean = true) {
    super();
    this.supportedExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.tif', '.livp', '.ico', '.svg'];
    this.useOcr = useOcr;
    this.ocrService = new LocalOCRService();
  }

  async parse(filePath: string): Promise<DataBlock[]> {
    if (!this.canParse(filePath)) {
      const error = new Error(`Unsupported file format: ${filePath}`);
      throw error;
    }

    const blocks: DataBlock[] = [];
    const fileName = filePath.split('/').pop() || '';
    // 解码URL编码的文件名
    const decodedFileName = this.decodeFileName(fileName);
    const cacheUtils = CacheUtils.getInstance();

    try {
      // 获取图像尺寸
      const imageSize = await this.getImageSize(filePath);

      // 创建图像数据块
      // 注意：addr = filePath，图片文件直接使用原始路径，与Python项目一致
      const imageBlock = new DataBlock();
      imageBlock.setBlockId(this.generateBlockId(filePath, 0, 'image'));
      imageBlock.setModality(ModalityType.IMAGE);
      imageBlock.setContent(`[图片文件: ${decodedFileName}, 尺寸: ${imageSize.width}x${imageSize.height}]`);
      imageBlock.setTextContent(`[图片文件: ${decodedFileName}, 尺寸: ${imageSize.width}x${imageSize.height}]`);
      imageBlock.setFilePath(filePath);
      imageBlock.setAddr(filePath);  // 图片块：addr = 原始文件路径，与Python一致
      imageBlock.setPageNumber(1);
      const meta: FileMetadata = {
        'source': 'image_parser',  // 标识为原始图片文件，与Python一致
        'width': imageSize.width,
        'height': imageSize.height,
        'fileName': decodedFileName,
        'useOcr': this.useOcr ? 'true' : 'false'
      };
      imageBlock.setMetadata(meta);
      blocks.push(imageBlock);

      // 如果启用OCR，进行文字识别
      if (this.useOcr) {
        try {
          await this.ocrService.initialize();
          const ocrResult = await this.ocrService.recognizeImage(filePath);

          if (ocrResult.fullText && ocrResult.fullText.trim()) {
            // 获取缓存目录（异步）
            const cachePath = await cacheUtils.getDataBlocksCachePath(filePath);

            // 保存OCR结果到缓存文件（异步），addr = cache_path，与Python一致
            const ocrCachePath = await cacheUtils.saveTextToCache(ocrResult.fullText, cachePath, 'ocr_0.txt');

            // 创建OCR文本数据块
            const ocrBlock = new DataBlock();
            ocrBlock.setBlockId(this.generateBlockId(filePath, 0, 'ocr'));
            ocrBlock.setModality(ModalityType.TEXT);
            ocrBlock.setContent(ocrResult.fullText);
            ocrBlock.setTextContent(ocrResult.fullText);
            ocrBlock.setFilePath(filePath);
            ocrBlock.setAddr(ocrCachePath);  // OCR块：addr = 缓存文件路径，与Python一致
            ocrBlock.setPageNumber(1);
            // 计算平均置信度
            let avgConfidence = 0;
            if (ocrResult.textBlocks.length > 0) {
              for (const block of ocrResult.textBlocks) {
                avgConfidence += block.confidence || 0;
              }
              avgConfidence = avgConfidence / ocrResult.textBlocks.length;
            }
            const ocrMeta: FileMetadata = {
              'source': 'ocr',  // 标识为OCR结果，与Python一致
              'confidence': avgConfidence,
              'blockCount': ocrResult.textBlocks.length,
              'originalImage': decodedFileName,
              'cachePath': ocrCachePath
            };
            ocrBlock.setMetadata(ocrMeta);
            blocks.push(ocrBlock);

            console.info('[ImageParser] OCR extracted text length:', ocrResult.fullText.length);
          } else {
            console.info('[ImageParser] No text detected in image');
          }
        } catch (ocrErr) {
          console.warn('[ImageParser] OCR failed:', ocrErr);
          // OCR失败不影响图像块的处理
        }
      }

    } catch (err) {
      console.error('[ImageParser] Failed to parse image:', err);
    }

    return blocks;
  }

  /**
   * 获取图像尺寸信息
   */
  private async getImageSize(filePath: string): Promise<ImageSize> {
    try {
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(file.fd);
      const imageInfo = await imageSource.getImageInfo();
      await fileIo.close(file.fd);

      const result: ImageSize = {
        width: imageInfo.size.width,
        height: imageInfo.size.height
      };
      return result;
    } catch (err) {
      console.error('[ImageParser] Failed to get image size:', err);
      const defaultSize: ImageSize = { width: 0, height: 0 };
      return defaultSize;
    }
  }

  /**
   * 获取图像EXIF信息（时空数据）
   */
  async getExifInfo(filePath: string): Promise<Record<string, Object>> {
    const exifInfo: Record<string, Object> = {};

    try {
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(file.fd);

      // 尝试获取EXIF信息
      try {
        const orientation: string = await imageSource.getImageProperty('Orientation');
        const orientationNum: number = parseInt(orientation);
        if (!isNaN(orientationNum)) {
          exifInfo['orientation'] = orientationNum;
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const gpsLatitude: string = await imageSource.getImageProperty('GPSLatitude');
        const gpsLatitudeRef: string = await imageSource.getImageProperty('GPSLatitudeRef');
        if (gpsLatitude) {
          exifInfo['gpsLatitude'] = this.parseGpsCoordinate(gpsLatitude, gpsLatitudeRef);
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const gpsLongitude: string = await imageSource.getImageProperty('GPSLongitude');
        const gpsLongitudeRef: string = await imageSource.getImageProperty('GPSLongitudeRef');
        if (gpsLongitude) {
          exifInfo['gpsLongitude'] = this.parseGpsCoordinate(gpsLongitude, gpsLongitudeRef);
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const dateTime: string = await imageSource.getImageProperty('DateTime');
        if (dateTime) {
          // 格式化时间: "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD HH:MM:SS"
          const parts = dateTime.split(' ');
          if (parts.length === 2) {
            const datePart = parts[0].replace(/:/g, '-');
            const formatted = datePart + ' ' + parts[1];
            exifInfo['dateTime'] = formatted;
          } else {
            exifInfo['dateTime'] = dateTime;
          }
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const dateTimeOriginal: string = await imageSource.getImageProperty('DateTimeOriginal');
        if (dateTimeOriginal) {
          const parts = dateTimeOriginal.split(' ');
          if (parts.length === 2) {
            const datePart = parts[0].replace(/:/g, '-');
            const formatted = datePart + ' ' + parts[1];
            exifInfo['dateTime'] = formatted;
          } else {
            exifInfo['dateTime'] = dateTimeOriginal;
          }
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const make: string = await imageSource.getImageProperty('Make');
        if (make) {
          exifInfo['make'] = make.trim();
        }
      } catch {
        // 忽略不支持属性
      }

      try {
        const model: string = await imageSource.getImageProperty('Model');
        if (model) {
          exifInfo['model'] = model.trim();
        }
      } catch {
        // 忽略不支持属性
      }

      await fileIo.close(file.fd);
      console.info('[ImageParser] EXIF extracted:', JSON.stringify(exifInfo));
      return exifInfo;
    } catch (err) {
      console.error('[ImageParser] Failed to get EXIF info:', err);
      return exifInfo;
    }
  }

  /**
   * 解析GPS坐标
   */
  private parseGpsCoordinate(coordStr: string, ref?: string): number {
    try {
      // 格式: "deg, min, sec" 或 "deg min sec"
      const parts = coordStr.replace(/,/g, ' ').split(/\s+/).filter(s => s);
      if (parts.length >= 3) {
        const deg = parseFloat(parts[0]);
        const min = parseFloat(parts[1]);
        const sec = parseFloat(parts[2]);
        let decimal = deg + min / 60 + sec / 3600;
        if (ref === 'S' || ref === 'W') {
          decimal = -decimal;
        }
        return decimal;
      }
    } catch (e) {
      console.warn('[ImageParser] GPS parse error:', e);
    }
    return 0;
  }

  /**
   * 解码URL编码的文件名
   */
  async release(): Promise<void> {
    await this.ocrService.release();
  }
}