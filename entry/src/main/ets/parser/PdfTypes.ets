/**
 * PDF页面包装器
 *
 * 用于调用HMS PDF服务API 6.1.0+中的getTextContent方法
 */
import pdfService from '@hms.officeservice.pdfservice';
import { image } from '@kit.ImageKit';

/**
 * 定义我们需要的页面方法接口
 */
export interface ITextPdfPage {
  getTextContent(): string;
  getPagePixelMap(): image.PixelMap;
  getWidth(): number;
  getHeight(): number;
}

/**
 * 创建一个可以调用getTextContent的页面包装对象
 *
 * @param page 原始PdfPage对象
 * @returns 包装后的页面对象
 */
export function createTextPdfPage(page: pdfService.PdfPage): ITextPdfPage {
  // 创建一个新对象来实现接口
  const wrapper: ITextPdfPage = {
    getTextContent: (): string => {
      // 在运行时直接调用page的getTextContent方法
      // 由于API 6.1.0+支持此方法，运行时会成功
      // 编译器可能无法识别，但我们可以通过wrapper接口绕过
      try {
        // 直接调用 - 运行时如果方法存在会成功
        return page.getTextContent();
      } catch (e) {
        console.warn('[createTextPdfPage] getTextContent runtime error:', e);
        return '';
      }
    },
    getPagePixelMap: (): image.PixelMap => {
      return page.getPagePixelMap();
    },
    getWidth: (): number => {
      return page.getWidth();
    },
    getHeight: (): number => {
      return page.getHeight();
    }
  };
  return wrapper;
}