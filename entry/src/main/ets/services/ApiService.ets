/**
 * ApiService - HTTP client for the FileAnalyzer Python backend
 *
 * Provides async methods for all backend API endpoints.
 * Uses HarmonyOS @kit.NetworkKit for HTTP requests.
 */

import { http } from '@kit.NetworkKit';
import {
  ScanRequest, ScanResponse,
  ParseRequest, ParseResponse,
  AnalyzeRequest, AnalyzeResponse,
  ClassifyRequest, ClassifyResponse,
  SearchRequest, SearchResponse,
  OcrRequest, OcrResponse,
  EmbedRequest, EmbedResponse,
  LlmDescribeRequest, LlmDescribeResponse,
  HealthResponse,
  FileListResponse, FileDetailResponse,
  CategoriesResponse,
  ApiError,
  SemanticRepresentRequest, SemanticRepresentResponse,
  ClassifyFileRequest, ClassifyFileResponse,
  ImageMetadataRequest, ImageMetadataResponse,
  ImageCaptionRequest, ImageCaptionResponse,
  ClearHistoryResponse, ClearClassificationResponse
} from '../models/ApiModels';

const DEFAULT_BASE_URL = 'http://localhost:8765';
const DEFAULT_TIMEOUT = 30000;
const LONG_TIMEOUT = 120000;

export class ApiService {
  private baseUrl: string = DEFAULT_BASE_URL;
  private connected: boolean = false;

  constructor(baseUrl?: string) {
    if (baseUrl) {
      this.baseUrl = baseUrl;
    }
  }

  setBaseUrl(url: string): void {
    this.baseUrl = url;
    this.connected = false;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  isConnected(): boolean {
    return this.connected;
  }

  // ============ Health ============

  async checkHealth(): Promise<HealthResponse> {
    const response = await this.get<HealthResponse>('/api/health');
    this.connected = (response.status === 'ok');
    return response;
  }

  // ============ Scan ============

  async scanDirectory(directoryPath: string, recursive: boolean = true): Promise<ScanResponse> {
    const req: ScanRequest = {
      directory_path: directoryPath,
      recursive: recursive
    };
    return await this.post<ScanResponse>('/api/scan', req);
  }

  // ============ Parse ============

  async parseFile(filePath: string, parsingMode?: number): Promise<ParseResponse> {
    const req: ParseRequest = {
      file_path: filePath,
      parsing_mode: parsingMode
    };
    return await this.post<ParseResponse>('/api/parse', req);
  }

  // ============ Analyze (full pipeline) ============

  async analyzeFile(filePath: string, parsingMode?: number): Promise<AnalyzeResponse> {
    const req: AnalyzeRequest = {
      file_path: filePath,
      parsing_mode: parsingMode
    };
    return await this.post<AnalyzeResponse>('/api/analyze', req, LONG_TIMEOUT);
  }

  // ============ Classify ============

  async classifyText(text: string, method: string = 'similarity'): Promise<ClassifyResponse> {
    const req: ClassifyRequest = {
      text: text,
      method: method
    };
    return await this.post<ClassifyResponse>('/api/classify', req);
  }

  // ============ Search ============

  async search(query: string, topK: number = 10): Promise<SearchResponse> {
    const req: SearchRequest = {
      query: query,
      top_k: topK
    };
    return await this.post<SearchResponse>('/api/search', req);
  }

  // ============ OCR ============

  async ocrImage(imagePath: string): Promise<OcrResponse> {
    const req: OcrRequest = {
      image_path: imagePath
    };
    return await this.post<OcrResponse>('/api/ocr', req, LONG_TIMEOUT);
  }

  // ============ Embed ============

  async embedText(text: string): Promise<EmbedResponse> {
    const req: EmbedRequest = {
      text: text
    };
    return await this.post<EmbedResponse>('/api/embed', req, LONG_TIMEOUT);
  }

  // ============ LLM Describe ============

  async llmDescribe(text: string, prompt?: string): Promise<LlmDescribeResponse> {
    const req: LlmDescribeRequest = {
      text: text,
      prompt: prompt
    };
    return await this.post<LlmDescribeResponse>('/api/llm/describe', req, LONG_TIMEOUT);
  }

  // ============ Files ============

  async listFiles(directory?: string, fileType?: string, status?: number,
    limit?: number): Promise<FileListResponse> {
    let url = '/api/files';
    const params: string[] = [];
    if (directory) params.push(`directory=${encodeURIComponent(directory)}`);
    if (fileType) params.push(`file_type=${encodeURIComponent(fileType)}`);
    if (status !== undefined) params.push(`status=${status}`);
    if (limit !== undefined) params.push(`limit=${limit}`);
    if (params.length > 0) url += '?' + params.join('&');
    return await this.get<FileListResponse>(url);
  }

  async getFileDetails(fileId: number): Promise<FileDetailResponse> {
    return await this.get<FileDetailResponse>(`/api/files/${fileId}`);
  }

  // ============ Categories ============

  async getCategories(): Promise<CategoriesResponse> {
    return await this.get<CategoriesResponse>('/api/categories');
  }

  // ============ Semantic Represent ============

  async semanticRepresent(fileId: number): Promise<SemanticRepresentResponse> {
    const req: SemanticRepresentRequest = {
      file_id: fileId
    };
    return await this.post<SemanticRepresentResponse>('/api/semantic-represent', req, LONG_TIMEOUT);
  }

  // ============ Classify File ============

  async classifyFile(fileId: number, categorySystemName?: string): Promise<ClassifyFileResponse> {
    const req: ClassifyFileRequest = {
      file_id: fileId,
      category_system_name: categorySystemName
    };
    return await this.post<ClassifyFileResponse>(`/api/classify-file/${fileId}`, req);
  }

  // ============ Clear History ============

  async clearHistory(): Promise<ClearHistoryResponse> {
    return await this.delete<ClearHistoryResponse>('/api/history');
  }

  async clearClassificationResults(): Promise<ClearClassificationResponse> {
    return await this.delete<ClearClassificationResponse>('/api/history/classification');
  }

  // ============ Image Analysis ============

  async analyzeImageMetadata(fileId?: number, filePath?: string): Promise<ImageMetadataResponse> {
    const req: ImageMetadataRequest = {
      file_id: fileId,
      file_path: filePath
    };
    return await this.post<ImageMetadataResponse>('/api/image/metadata', req, LONG_TIMEOUT);
  }

  async generateImageCaption(fileId?: number, filePath?: string): Promise<ImageCaptionResponse> {
    const req: ImageCaptionRequest = {
      file_id: fileId,
      file_path: filePath
    };
    return await this.post<ImageCaptionResponse>('/api/image/caption', req, LONG_TIMEOUT);
  }

  // ============ Generic HTTP Methods ============

  private async get<T>(path: string, timeout: number = DEFAULT_TIMEOUT): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    console.info(`[ApiService] GET request to: ${url}`);
    try {
      const httpRequest = http.createHttp();
      console.info(`[ApiService] Created HTTP client, making request...`);
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING
      });
      console.info(`[ApiService] Response received: code=${response.responseCode}`);
      if (response.responseCode === 200 || response.responseCode === 201) {
        const result = JSON.parse(response.result.toString()) as T;
        console.info(`[ApiService] GET success: ${url}`);
        return result;
      } else {
        console.error(`[ApiService] HTTP error: ${response.responseCode}, result: ${response.result}`);
        throw new Error(`HTTP ${response.responseCode}: ${response.result}`);
      }
    } catch (err) {
      this.connected = false;
      const errorMsg = err instanceof Error ? err.message : String(err);
      console.error(`[ApiService] GET failed: ${url}, error: ${errorMsg}`);
      throw new Error(`API request failed: ${errorMsg}`);
    }
  }

  private async post<T>(path: string, body: Object, timeout: number = DEFAULT_TIMEOUT): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    try {
      const response = await http.createHttp().request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body),
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode === 200 || response.responseCode === 201) {
        const result = JSON.parse(response.result.toString()) as T;
        return result;
      } else {
        const errorData = response.result.toString();
        let errorMsg = `HTTP ${response.responseCode}`;
        try {
          const parsed = JSON.parse(errorData) as ApiError;
          errorMsg += `: ${parsed.detail}`;
        } catch (e) {
          errorMsg += `: ${errorData}`;
        }
        throw new Error(errorMsg);
      }
    } catch (err) {
      this.connected = false;
      throw new Error(`API request failed: ${err}`);
    }
  }

  private async delete<T>(path: string, timeout: number = DEFAULT_TIMEOUT): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    try {
      const response = await http.createHttp().request(url, {
        method: http.RequestMethod.DELETE,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode === 200 || response.responseCode === 204) {
        if (response.result) {
          const result = JSON.parse(response.result.toString()) as T;
          return result;
        }
        return null as T;
      } else {
        const errorData = response.result ? response.result.toString() : '';
        let errorMsg = `HTTP ${response.responseCode}`;
        try {
          const parsed = JSON.parse(errorData) as ApiError;
          errorMsg += `: ${parsed.detail}`;
        } catch (e) {
          errorMsg += `: ${errorData}`;
        }
        throw new Error(errorMsg);
      }
    } catch (err) {
      this.connected = false;
      throw new Error(`API request failed: ${err}`);
    }
  }
}
