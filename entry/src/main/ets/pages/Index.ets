
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { taskpool } from '@kit.ArkTS';
import pdfService from '@hms.officeservice.pdfservice';
import document from '@ohos.document';
import webview from '@ohos.web.webview';
import { FileRecord, FileStatus, CategoryScore, DataBlock, ModalityType, FileMetadata, SpatiotemporalAnalysisStatus, CaptionAnalysisStatus, SemanticBlock, SemanticCategoryRecord } from '../models/Index';
import { DatabaseManager } from '../database/Index';
import { DataParser, ParseConfig } from '../parser/Index';
import { SemanticRepresentation, SemanticClustering } from '../semantic/Index';
import { FileViewModel, FileItem } from '../viewmodel/Index';
import { ApiService, LocalImageAnalysisService, LocalClassificationService, ClassificationResult } from '../services/Index';
import { getDatabaseSyncService } from '../services/Index';
import { RootDataReader, SYSTEM_DB_PATHS, HDC_COMMANDS } from '../services/Index';
import { EmbeddingMethodType, EmbeddingServiceFactory } from '../services/Index';
import { OfficeConversionService, BatchConversionResult } from '../services/Index';
import { DataBlockDetail, SemanticBlockDetail } from '../models/ApiModels';
import { ZipReader, ZipEntry } from '../parser/ZipReader';
import { CaptionMode } from '../models/CaptionResultModel';
import { CacheUtils } from '../utils/CacheUtils';
import {
  preprocessTextTask,
  batchPreprocessTextTask,
  extractKeywordCandidatesTask,
  calculateProgressTask
} from '../workers/ParallelTasks';

// ============ 后台任务辅助函数 ============

/**
 * 延迟执行函数 - 让主线程有机会处理UI事件
 * 每处理一定数量的文件后调用，避免长时间阻塞
 */
function yieldMainThread(): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, 10); // 10ms延迟，足够让UI线程响应
  });
}

/**
 * 在子线程执行文本预处理
 */
async function runPreprocessTextInTaskPool(text: string): Promise<string> {
  try {
    const result = await taskpool.execute(preprocessTextTask, text) as string;
    return result;
  } catch (e) {
    console.warn(`[TaskPool] preprocessText failed, fallback to main thread: ${e}`);
    return text.trim().replace(/\s+/g, ' ');
  }
}

/**
 * 在子线程执行关键词提取
 */
async function runExtractKeywordsInTaskPool(text: string): Promise<string[]> {
  try {
    const result = await taskpool.execute(extractKeywordCandidatesTask, text) as string[];
    return result;
  } catch (e) {
    console.warn(`[TaskPool] extractKeywords failed: ${e}`);
    return [];
  }
}

/**
 * 分批处理配置
 */
const BATCH_SIZE = 5; // 每批处理5个文件
const YIELD_INTERVAL = 1; // 每处理1个文件yield一次（避免语义表征阻塞）

// ============ Helper Functions ============

function decodeFileName(name: string): string {
  try {
    // Handle URL-encoded file names (e.g., %E4%B8%AD%E5%9B%BD -> 中国)
    if (name.includes('%')) {
      // Try to decode the whole string first
      try {
        return decodeURIComponent(name);
      } catch (e) {
        // If that fails, try to decode segments
        // For mixed content like "文件名: %E4%B8%AD%E5%9B%BD"
        // We need to find and decode each URL-encoded segment
        const result: string[] = [];
        let i = 0;
        while (i < name.length) {
          if (name[i] === '%' && i + 2 < name.length) {
            // Find the end of the encoded sequence
            let end = i;
            while (end < name.length && name[end] === '%' && end + 2 < name.length) {
              const hex = name.substring(end + 1, end + 3);
              if (/^[0-9A-Fa-f]{2}$/.test(hex)) {
                end += 3;
              } else {
                break;
              }
            }
            if (end > i) {
              try {
                result.push(decodeURIComponent(name.substring(i, end)));
                i = end;
              } catch (e2) {
                result.push(name[i]);
                i++;
              }
            } else {
              result.push(name[i]);
              i++;
            }
          } else {
            result.push(name[i]);
            i++;
          }
        }
        return result.join('');
      }
    }
    return name;
  } catch (e) {
    return name;
  }
}

// ============ Data Interfaces ============

interface CategoryInfo {
  name: string;
  count: number;
  color: string;
}

interface FileDataBlock {
  blockId: string;
  modality: string;
  content: string;
  textContent: string;
  pageNumber: number;
}

interface FileSemanticBlock {
  blockId: string;
  textDescription: string;
  keywords: string[];
  category: string;
  confidence: number;
}

// ============ Main Page ============

@Entry
@Component
struct Index {
  // UI State
  @State currentTab: number = 0; // 0=Files, 1=Preview, 2=Categories, 3=Search, 4=Settings
  @State isLoading: boolean = false;

  // Initialization State (后台初始化进度)
  @State isInitializing: boolean = false;      // 是否正在后台初始化
  @State initProgress: string = '';            // 当前初始化步骤描述
  @State initPercent: number = 0;              // 初始化进度百分比
  @State servicesReady: boolean = false;       // 核心服务是否全部就绪
  @State apiConnected: boolean = false;
  @State apiStatusText: string = '未连接';
  @State isScanning: boolean = false;
  @State isProcessing: boolean = false;
  @State scanProgress: string = '';
  @State processProgress: string = '';
  @State processStep: string = '';
  @State showDrawer: boolean = false;
  @State showAboutDialog: boolean = false;
  @State showConfirmDialog: boolean = false;
  @State confirmAction: string = '';
  @State dialogMessage: string = '';
  @State showResetDbDialog: boolean = false;
  @State resetDbStatus: string = '';
  @State isResettingDb: boolean = false;

  // System Data Access
  @State showSystemDataPage: boolean = false;
  @State systemDataTab: number = 0; // 0=contacts, 1=callLog, 2=sms, 3=calendar
  @State systemContactsData: string[][] = [];
  @State systemCallLogData: string[][] = [];
  @State systemSmsData: string[][] = [];
  @State systemCalendarData: string[][] = [];
  @State isLoadingSystemData: boolean = false;
  @State systemDataError: string = '';

  // Office Format Conversion
  @State showOfficeConvertDialog: boolean = false;
  @State isConvertingOffice: boolean = false;
  @State officeConversionPercent: number = 0;
  @State convertibleFiles: string[] = [];
  @State officeConversionResult: string = '';
  @State officeConversionError: string = '';
  @State convertedOutputFiles: string[] = [];  // 存储转换后的文件路径

  // Workflow step progress
  @State parseProgress: string = '';
  @State semanticProgress: string = '';
  @State classifyProgress: string = '';
  @State imageMetaProgress: string = '';
  @State imageCaptionProgress: string = '';

  // Progress bar state
  @State progressPercent: number = 0;
  @State progressLabel: string = '';
  @State currentProcessingFile: string = '';

  // Encoder status
  @State encoderStatus: string = '初始化中...';
  @State isOfflineMode: boolean = false;
  @State useServer: boolean = false; // 是否使用服务器，默认不使用

  // Data State
  @State fileViewModel: FileViewModel = new FileViewModel();
  @State categories: CategoryInfo[] = [];
  @State selectedFile: FileItem | null = null;
  @State previewContent: string = '';
  @State previewBlocks: FileDataBlock[] = [];
  @State semanticBlocks: FileSemanticBlock[] = [];
  @State searchQuery: string = '';
  @State searchResults: FileItem[] = [];
  @State searchFilter: string = 'all';
  @State classificationResults: Record<string, FileItem[]> = {};

  // Preview State
  @State previewPageNumber: number = 1;
  @State pdfPageCount: number = 0;
  @State pdfPixelMap: image.PixelMap | null = null;
  @State isLoadingPreview: boolean = false;
  @State previewTextContent: string = '';
  @State imagePixelMap: image.PixelMap | null = null;
  // 时空分析和Caption信息
  @State previewDateTime: string = '';
  @State previewLocation: string = '';
  @State previewDevice: string = '';
  @State previewCaption: string = '';
  @State previewTags: string[] = [];
  @State previewCaptionConfidence: number = 0;

  // Office Web Preview State
  @State officeFileContentBase64: string = '';
  @State officeWebReady: boolean = false;
  @State officePreviewError: string = '';
  private webController: webview.WebviewController = new webview.WebviewController();

  // Markdown Web Preview State
  @State markdownFileContentBase64: string = '';
  @State markdownWebReady: boolean = false;
  @State markdownPreviewError: string = '';
  private markdownWebController: webview.WebviewController = new webview.WebviewController();

  // Services
  // Saved settings
  private savedApiUrl: string = 'http://127.0.0.1:8765';
  private context: common.Context | null = null;
  private dbManager: DatabaseManager | null = null;
  private dataParser: DataParser | null = null;
  private semanticRep: SemanticRepresentation | null = null;
  private semanticClustering: SemanticClustering | null = null;
  private apiService: ApiService | null = null;
  private pdfDoc: pdfService.PdfDocument | null = null;
  private imageAnalysisService: LocalImageAnalysisService | null = null;
  private officeConversionService: OfficeConversionService | null = null;
  // 默认使用原项目的LLM配置
  @State llmApiKey: string = 'sk-bdc36890140440739a0ae936deba9413';
  @State llmProvider: string = 'qwen';
  @State llmEndpoint: string = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
  @State llmModel: string = 'qwen3-vl-32b-thinking';
  @State llmTimeout: number = 60;
  @State llmMaxTokens: number = 32768;
  @State llmTemperature: number = 0.7;
  // 嵌入模型最大文本长度（用于语义向量生成）
  @State embeddingMaxTextLength: number = 128;
  // 嵌入方法：'mindspore' | 'native' | 'local' | 'api'
  @State embeddingMethod: EmbeddingMethodType = 'mindspore';
  // 解析模式: 1=轻量解析, 2=深度解析（与Python一致）
  @State parseMode: number = 1;
  // 轻量解析最大文本长度（与Python light_mode_max_length=256一致）
  @State lightModeMaxLength: number = 256;
  // 文本描述最大长度（与Python description.max_length=512一致）
  @State descriptionMaxLength: number = 512;
  @State debugMode: boolean = false;
  @State debugServerUrl: string = 'http://127.0.0.1:8765';
  @State syncStatus: string = '未同步';
  // 图片文件文本提取方式：'ocr' 或 'caption'，与Python一致
  // 原始图片文件（jpg/png等），默认caption
  @State imageFileTextMethod: string = 'caption';
  // 解析得到的图片（PDF/PPT中的图片），默认ocr
  @State parsedImageTextMethod: string = 'ocr';
  // 图片缩放最大尺寸（与AItest项目一致，默认512）
  @State maxDimension: number = 512;
  @State showApiKey: boolean = false;
  @State connectionStatus: string = '未测试';
  @State isTestingConnection: boolean = false;
  @State testSuccess: boolean = false;
  @State captionMode: CaptionMode = CaptionMode.CLOUD;
  // 分类方法配置（与Python一致）：similarity/cluster/llm
  @State classificationMethod: string = 'similarity';
  // 分类配置面板状态
  @State showClassifyPanel: boolean = false;
  @State categorySystems: string[] = [];  // 类别体系列表
  @State selectedCategorySystem: string = '默认类别体系';  // 选中的类别体系
  @State expandedCategorySystem: string = '';  // 当前展开的类别体系
  @State categorySystemCategories: Record<string, SemanticCategoryRecord[]> = {};  // 类别体系对应的类别
  @State isClassifying: boolean = false;  // 分类执行中
  @State toClassifyFileCount: number = 0;  // 待分类文件数量

  aboutToAppear(): void {
    this.context = getContext(this) as common.Context;
    this.isInitializing = true;
    this.initProgress = '正在初始化...';
    this.initPercent = 0;
    // 不等待，立即返回让UI显示
    this.initializeServicesAsync();
  }

  // ============ Initialization ============

  private async loadSavedSettings(): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context!, 'app_settings');
      // 加载所有设置到状态变量
      const savedUrl = pref.getSync('api_url', '') as string;
      this.savedApiUrl = savedUrl || 'http://127.0.0.1:8765';

      const savedUseServer = pref.getSync('use_server', false) as boolean;
      this.useServer = savedUseServer;

      // 加载LLM配置 - 如果未保存则使用默认值
      const savedApiKey = pref.getSync('llm_api_key', '') as string;
      if (savedApiKey) this.llmApiKey = savedApiKey;

      const savedProvider = pref.getSync('llm_provider', '') as string;
      if (savedProvider) this.llmProvider = savedProvider;

      const savedEndpoint = pref.getSync('llm_endpoint', '') as string;
      if (savedEndpoint) this.llmEndpoint = savedEndpoint;

      const savedModel = pref.getSync('llm_model', '') as string;
      if (savedModel) this.llmModel = savedModel;

      // 加载LLM高级参数
      const savedTimeout = pref.getSync('llm_timeout', 0) as number;
      if (savedTimeout > 0) this.llmTimeout = savedTimeout;

      const savedMaxTokens = pref.getSync('llm_max_tokens', 0) as number;
      if (savedMaxTokens > 0) this.llmMaxTokens = savedMaxTokens;

      const savedTemperature = pref.getSync('llm_temperature', -1) as number;
      if (savedTemperature >= 0) this.llmTemperature = savedTemperature;

      // 加载调试模式配置
      const savedDebugMode = pref.getSync('debug_mode', false) as boolean;
      this.debugMode = savedDebugMode;

      const savedDebugUrl = pref.getSync('debug_server_url', '') as string;
      if (savedDebugUrl) this.debugServerUrl = savedDebugUrl;

      // 加载图片文件文本提取方式配置
      const savedImageTextMethod = pref.getSync('image_file_text_method', 'caption') as string;
      this.imageFileTextMethod = savedImageTextMethod;

      const savedParsedImageMethod = pref.getSync('parsed_image_text_method', 'ocr') as string;
      this.parsedImageTextMethod = savedParsedImageMethod;

      // 加载嵌入模型最大文本长度配置
      const savedEmbeddingMaxLen = pref.getSync('embedding_max_text_length', 128) as number;
      if (savedEmbeddingMaxLen > 0) this.embeddingMaxTextLength = savedEmbeddingMaxLen;

      // 加载嵌入方法配置
      const savedEmbeddingMethod = pref.getSync('embedding_method', 'mindspore') as string;
      if (savedEmbeddingMethod === 'mindspore' || savedEmbeddingMethod === 'native' ||
          savedEmbeddingMethod === 'local' || savedEmbeddingMethod === 'api') {
        this.embeddingMethod = savedEmbeddingMethod as EmbeddingMethodType;
      }

      // 加载解析模式配置
      const savedParseMode = pref.getSync('parse_mode', 1) as number;
      if (savedParseMode === 1 || savedParseMode === 2) this.parseMode = savedParseMode;

      const savedLightModeMaxLen = pref.getSync('light_mode_max_length', 256) as number;
      if (savedLightModeMaxLen > 0) this.lightModeMaxLength = savedLightModeMaxLen;

      const savedDescMaxLen = pref.getSync('description_max_length', 512) as number;
      if (savedDescMaxLen > 0) this.descriptionMaxLength = savedDescMaxLen;

      // 加载Caption生成模式配置
      const savedCaptionMode = pref.getSync('caption_mode', '') as string;
      if (savedCaptionMode === CaptionMode.LOCAL || savedCaptionMode === CaptionMode.CLOUD) {
        this.captionMode = savedCaptionMode as CaptionMode;
      }

      // 加载图片缩放最大尺寸配置
      const savedMaxDimension = pref.getSync('max_dimension', 512) as number;
      if (savedMaxDimension > 0) this.maxDimension = savedMaxDimension;

      // 加载分类方法配置
      const savedClassificationMethod = pref.getSync('classification_method', 'similarity') as string;
      if (savedClassificationMethod) this.classificationMethod = savedClassificationMethod;

      console.info('[Index] Loaded settings - useServer:', this.useServer, 'llmProvider:', this.llmProvider, 'debugMode:', this.debugMode, 'embeddingMethod:', this.embeddingMethod, 'imageFileTextMethod:', this.imageFileTextMethod, 'captionMode:', this.captionMode, 'maxDimension:', this.maxDimension, 'classificationMethod:', this.classificationMethod);
    } catch (e) {
      console.warn('[Index] Load settings failed:', e);
    }
  }

  private async initializeServicesAsync(): Promise<void> {
    try {
      // === 阶段1：数据库（优先，约20%进度） ===
      this.initProgress = '正在初始化数据库...';
      this.initPercent = 10;

      // 加载保存的设置
      await this.loadSavedSettings();

      // 初始化数据库
      this.dbManager = new DatabaseManager(this.context!);
      await this.dbManager.initialize();
      this.initPercent = 20;

      // 初始化缓存
      await CacheUtils.getInstance().init(this.context! as common.UIAbilityContext);

      // === 阶段2：加载文件列表（约30%进度） ===
      this.initProgress = '正在加载文件列表...';
      this.initPercent = 25;
      await this.loadFiles();
      this.initPercent = 30;

      // === 阶段3：语义模型（中优先级，约60%进度） ===
      this.initProgress = '正在加载语义模型...';
      this.initPercent = 35;

      // DataParser
      this.dataParser = new DataParser(new ParseConfig(this.parseMode, this.lightModeMaxLength));

      // SemanticRepresentation
      this.semanticRep = new SemanticRepresentation();
      this.semanticRep.setContext(this.context!);
      this.semanticRep.setImageFileTextMethod(this.imageFileTextMethod);
      this.semanticRep.setParsedImageTextMethod(this.parsedImageTextMethod);
      this.semanticRep.setEmbeddingMaxTextLength(this.embeddingMaxTextLength);
      this.semanticRep.setEmbeddingMethod(this.embeddingMethod);
      this.semanticRep.setDescriptionMaxLength(this.descriptionMaxLength);
      await this.semanticRep.initialize();

      // SemanticClustering
      this.semanticClustering = new SemanticClustering();
      this.semanticClustering.initialize();
      this.initPercent = 60;

      // 检测编码器状态
      this.encoderStatus = this.semanticRep.getEncoderInfo();
      this.isOfflineMode = this.semanticRep.isMindSporeAvailable();

      // === 阶段4：图片分析服务（低优先级，约80%进度） ===
      this.initProgress = '正在初始化图片分析...';
      this.initPercent = 65;

      this.imageAnalysisService = new LocalImageAnalysisService();
      this.imageAnalysisService.setContext(this.context!);
      this.imageAnalysisService.setCaptionMode(this.captionMode);
      this.imageAnalysisService.setApiKey(this.llmApiKey);
      this.imageAnalysisService.setProvider(this.llmProvider, this.llmEndpoint, this.llmModel);
      this.imageAnalysisService.setTimeout(this.llmTimeout);
      this.imageAnalysisService.setMaxTokens(this.llmMaxTokens);
      this.imageAnalysisService.setTemperature(this.llmTemperature);
      this.imageAnalysisService.setMaxDimension(this.maxDimension);
      console.info('[Index] ImageAnalysisService initialized with maxDimension:', this.maxDimension);

      // 设置到semanticRep
      this.semanticRep.setImageAnalysisService(this.imageAnalysisService);

      // LOCAL模式下预加载模型
      if (this.captionMode === CaptionMode.LOCAL) {
        this.initProgress = '正在加载本地Caption模型...';
        const loaded = await this.imageAnalysisService.loadLocalCaptionModel();
        console.info('[Index] Local caption model loaded:', loaded);
      }
      this.initPercent = 80;

      // === 阶段5：其他服务（约90%进度） ===
      this.initProgress = '正在初始化转换服务...';
      this.officeConversionService = new OfficeConversionService();
      console.info('[Index] OfficeConversionService initialized');
      this.initPercent = 90;

      // === API连接（如果启用） ===
      if (this.useServer) {
        this.initProgress = '正在连接服务器...';
        this.apiStatusText = '连接中...';
        this.apiService = new ApiService(this.savedApiUrl);
        this.semanticRep.setApiService(this.apiService);
        await this.checkApiConnection();
      } else {
        this.apiService = null;
        this.apiConnected = false;
        this.apiStatusText = '本地模式';
      }

      // === 完成 ===
      this.initPercent = 100;
      this.initProgress = '就绪';
      this.isInitializing = false;
      this.servicesReady = true;

      console.info('[Index] All services initialized successfully');

    } catch (err) {
      console.error('[Index] Background initialization failed:', err);
      this.isInitializing = false;
      this.servicesReady = false;
      this.initProgress = '初始化失败';
      this.apiStatusText = '本地模式';
      this.encoderStatus = '本地模式';
      this.isOfflineMode = true;
    }
  }

  private async testApiConnection(): Promise<void> {
    if (!this.useServer) {
      this.connectionStatus = '请先启用服务器连接';
      return;
    }

    this.isTestingConnection = true;
    this.connectionStatus = '测试中...';

    try {
      // Get saved URL from preferences
      let apiUrl = 'http://127.0.0.1:8765';
      try {
        const pref = await preferences.getPreferences(this.context!, 'app_settings');
        const savedUrl = pref.getSync('api_url', '') as string;
        if (savedUrl) apiUrl = savedUrl;
      } catch (e) {}

      const service = new ApiService(apiUrl);
      const health = await service.checkHealth();

      if (health.status === 'ok') {
        this.testSuccess = true;
        this.connectionStatus = `连接成功 (文件数: ${health.file_count})`;
        // Update main apiService if connected
        this.apiService = service;
        this.apiConnected = true;
        this.apiStatusText = '已连接';
      } else {
        this.testSuccess = false;
        this.connectionStatus = '连接失败: 服务异常';
      }
    } catch (err) {
      this.testSuccess = false;
      this.connectionStatus = `连接失败: ${err}`;
    }

    this.isTestingConnection = false;
  }

  private async syncDatabase(): Promise<void> {
    this.syncStatus = '同步中...';
    try {
      const syncService = getDatabaseSyncService();
      syncService.setContext(this.context!);
      syncService.setServerUrl(this.debugServerUrl);

      const result = await syncService.syncDatabase();

      if (result.success) {
        this.syncStatus = `同步成功 ${result.timestamp}`;
      } else {
        this.syncStatus = `同步失败: ${result.message}`;
      }
    } catch (err) {
      this.syncStatus = `同步失败: ${err}`;
      console.error('[Index] Sync failed:', err);
    }
  }

  private async saveAllSettings(): Promise<void> {
    if (!this.context) return;
    try {
      const pref = await preferences.getPreferences(this.context, 'app_settings');
      await pref.put('api_url', this.apiService ? this.apiService.getBaseUrl() : 'http://127.0.0.1:8765');
      await pref.put('use_server', this.useServer);
      await pref.put('llm_api_key', this.llmApiKey);
      await pref.put('llm_provider', this.llmProvider);
      await pref.put('llm_endpoint', this.llmEndpoint);
      await pref.put('llm_model', this.llmModel);
      await pref.put('llm_timeout', this.llmTimeout);
      await pref.put('llm_max_tokens', this.llmMaxTokens);
      await pref.put('llm_temperature', this.llmTemperature);
      await pref.put('debug_mode', this.debugMode);
      await pref.put('debug_server_url', this.debugServerUrl);
      await pref.put('caption_mode', this.captionMode);
      await pref.put('embedding_max_text_length', this.embeddingMaxTextLength);
      await pref.put('embedding_method', this.embeddingMethod);
      // 保存解析模式配置（与Python一致）
      await pref.put('parse_mode', this.parseMode);
      await pref.put('light_mode_max_length', this.lightModeMaxLength);
      await pref.put('description_max_length', this.descriptionMaxLength);
      // 保存图片文字提取方式配置（两个独立设置）
      await pref.put('image_file_text_method', this.imageFileTextMethod);
      await pref.put('parsed_image_text_method', this.parsedImageTextMethod);
      // 保存图片缩放最大尺寸配置（与AItest项目MAX_SIZE=512一致）
      await pref.put('max_dimension', this.maxDimension);
      // 保存分类方法配置（与Python一致）
      await pref.put('classification_method', this.classificationMethod);
      await pref.flush();
      console.info('[Index] Settings saved - useServer:', this.useServer, 'captionMode:', this.captionMode, 'parseMode:', this.parseMode, 'imageFileTextMethod:', this.imageFileTextMethod, 'parsedImageTextMethod:', this.parsedImageTextMethod, 'maxDimension:', this.maxDimension, 'classificationMethod:', this.classificationMethod);
    } catch (err) {
      console.error('[Index] Save settings failed:', err);
    }
  }

  /**
   * 重置数据库 - 删除旧数据库文件并重新创建
   */
  private async resetDatabase(): Promise<void> {
    this.isResettingDb = true;
    this.resetDbStatus = '正在重置...';

    try {
      if (!this.context) {
        this.resetDbStatus = '✗ 上下文未初始化';
        return;
      }

      // 1. 删除数据库文件
      console.info('[Index] Deleting database...');
      try {
        await relationalStore.deleteRdbStore(this.context, 'FileAnalyzer.db');
        console.info('[Index] Database deleted successfully');
      } catch (delErr) {
        console.warn('[Index] Delete database warning:', delErr);
      }

      // 2. 删除版本文件
      try {
        const versionFilePath = `${this.context.cacheDir}/db_version.txt`;
        await fileIo.unlink(versionFilePath);
        console.info('[Index] Version file deleted');
      } catch (verErr) {
        console.warn('[Index] Version file warning:', verErr);
      }

      // 3. 清空缓存目录
      try {
        const cacheDir = this.context.cacheDir;
        const dataBlocksDir = `${cacheDir}/data_blocks`;
        try {
          await fileIo.rmdirSync(dataBlocksDir);
          console.info('[Index] data_blocks cache cleared');
        } catch {}
        const pdfImagesDir = `${cacheDir}/pdf_images`;
        try {
          await fileIo.rmdirSync(pdfImagesDir);
          console.info('[Index] pdf_images cache cleared');
        } catch {}
      } catch (cacheErr) {
        console.warn('[Index] Cache clear warning:', cacheErr);
      }

      // 4. 重新初始化数据库
      if (this.dbManager) {
        await this.dbManager.initialize();
        console.info('[Index] Database re-initialized');
      }

      this.resetDbStatus = '✓ 数据库已重置，请重启应用';
      this.showResetDbDialog = false;

      // 5. 刷新文件列表
      await this.loadFiles();

    } catch (err) {
      this.resetDbStatus = `✗ 重置失败: ${err}`;
      console.error('[Index] Reset database failed:', err);
    }

    this.isResettingDb = false;
  }

  private async checkApiConnection(): Promise<void> {
    if (!this.useServer || !this.apiService) {
      this.apiConnected = false;
      this.apiStatusText = '本地模式';
      return;
    }
    try {
      const health = await this.apiService.checkHealth();
      this.apiConnected = health.status === 'ok';
      this.apiStatusText = this.apiConnected ? '已连接' : '服务异常';
    } catch (err) {
      this.apiConnected = false;
      this.apiStatusText = '连接失败';
    }
  }

  // ============ Data Loading ============

  /**
   * 格式化 Unix 时间戳为 YYYY-MM-DD HH:MM:SS 格式
   */
  private formatTimestampToDateTime(timestamp: number): string {
    const date = new Date(timestamp * 1000); // Unix 时间戳是秒，需要乘 1000
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    const second = String(date.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  }

  /**
   * 格式化当前时间为 YYYY-MM-DD HH:MM:SS 格式
   */
  private formatCurrentDateTime(): string {
    const date = new Date();
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    const second = String(date.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  }

  private async loadFiles(): Promise<void> {
    if (!this.dbManager) return;
    try {
      const files = await this.dbManager.getAllFiles();
      const items: FileItem[] = [];
      for (const f of files) {
        items.push(this.toFileItem(f));
      }
      this.fileViewModel.setFiles(items);
      this.updateCategories();
      this.updateClassificationResults();
    } catch (err) {
      console.error('[Index] Load files failed:', err);
    }
  }

  private toFileItem(record: FileRecord): FileItem {
    const cat = record.semanticCategories.length > 0 ? record.semanticCategories[0].category : '未分类';
    const conf = record.semanticCategories.length > 0 ? record.semanticCategories[0].confidence : 0;
    return {
      id: record.id, name: record.fileName, path: record.filePath,
      size: record.fileSize, type: record.fileType, modifiedTime: record.modifiedTime,
      status: record.analysisStatus, category: cat, confidence: conf
    };
  }

  private getCategoryColor(name: string): string {
    const colors: Record<string, string> = {
      '技术文档': '#2196F3', '商业报告': '#4CAF50', '学术论文': '#9C27B0',
      '会议演示': '#FF9800', '合同协议': '#F44336', '产品说明': '#00BCD4',
      '新闻资讯': '#795548', '个人文档': '#607D8B', '未分类': '#9E9E9E'
    };
    return colors[name] || '#9E9E9E';
  }

  private updateCategories(): void {
    const map = new Map<string, number>();
    for (const file of this.fileViewModel.files) {
      const cat = file.category || '未分类';
      map.set(cat, (map.get(cat) || 0) + 1);
    }
    this.categories = Array.from(map.entries()).map((entry: [string, number]) => {
      const name: string = entry[0];
      const count: number = entry[1];
      const info: CategoryInfo = {
        name: name,
        count: count,
        color: this.getCategoryColor(name)
      };
      return info;
    });
  }

  private updateClassificationResults(): void {
    const results: Record<string, FileItem[]> = {};
    for (const file of this.fileViewModel.files) {
      const cat = file.category || '未分类';
      if (!results[cat]) results[cat] = [];
      results[cat].push(file);
    }
    this.classificationResults = results;
  }

  // ============ File Operations ============

  private async pickFiles(): Promise<void> {
    // 检查服务是否就绪
    if (!this.servicesReady || !this.dbManager) {
      this.scanProgress = '等待服务初始化完成...';
      return;
    }
    try {
      this.isScanning = true;
      this.scanProgress = '选择文件...';
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 100;
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(options);
      if (uris && uris.length > 0) {
        await this.processSelectedFiles(uris);
      }
      this.isScanning = false;
      this.scanProgress = '';
    } catch (err) {
      console.error('[Index] Pick failed:', err);
      this.isScanning = false;
      this.scanProgress = '';
    }
  }

  private async processSelectedFiles(uris: string[]): Promise<void> {
    // 检查服务是否就绪
    if (!this.servicesReady || !this.dbManager) {
      this.processProgress = '等待服务初始化完成...';
      return;
    }
    let ok = 0, fail = 0;
    for (let i = 0; i < uris.length; i++) {
      this.scanProgress = `入库 ${i + 1}/${uris.length}`;
      try {
        // 从URI中提取文件名并解码URL编码
        let name = uris[i].split('/').pop() || '';
        name = decodeFileName(name); // 解码URL编码的文件名
        const extRaw = name.split('.').pop()?.toLowerCase() || '';
        const ext = extRaw ? `.${extRaw}` : ''; // 带点前缀，与Python项目一致

        if (this.dbManager) {
          // Check if file already exists
          const existing = await this.dbManager.getFileByPath(uris[i]);
          if (existing) {
            ok++;
            continue;
          }

          // Get file size and modification time
          let fileSize = 0;
          let modifiedTimeStr = '';
          let createdTimeStr = '';
          try {
            const file = await fileIo.open(uris[i], fileIo.OpenMode.READ_ONLY);
            const stat = await fileIo.stat(file.fd);
            fileSize = stat.size;
            // 获取文件修改时间（stat.mtime 是 Unix 时间戳秒）
            if (stat.mtime) {
              modifiedTimeStr = this.formatTimestampToDateTime(stat.mtime);
            } else {
              modifiedTimeStr = this.formatCurrentDateTime();
            }
            // 文件创建时间通常等于修改时间（HarmonyOS 可能不支持获取 ctime）
            createdTimeStr = modifiedTimeStr;
            await fileIo.close(file.fd);
          } catch (e) {
            console.warn('[Index] Failed to get file info:', e);
            modifiedTimeStr = this.formatCurrentDateTime();
            createdTimeStr = modifiedTimeStr;
          }

          // Add file to local database with PENDING status
          const fileId = await this.dbManager.addFile(
            uris[i], name, fileSize, ext, modifiedTimeStr, createdTimeStr, 'selected'
          );
          if (fileId > 0) {
            ok++;
            console.log(`[Index] File added: ${name}, size=${fileSize}, id=${fileId}`);
          } else {
            fail++;
          }
        } else {
          console.error('[Index] dbManager not initialized');
          fail++;
        }

        // 每处理YIELD_INTERVAL个文件，让主线程休息一下
        if ((i + 1) % YIELD_INTERVAL === 0) {
          await yieldMainThread();
        }
      } catch (err) {
        console.error(`[Index] Process failed: ${err}`);
        fail++;
      }
    }
    await this.loadFiles();
    this.scanProgress = `入库完成: ${ok}成功, ${fail}失败`;
    setTimeout(() => { this.scanProgress = ''; }, 3000);
  }

  // ============ Workflow Operations (Parse → Semantic → Classify) ============

  private async startParse(): Promise<void> {
    const pending = this.fileViewModel.files.filter(f => f.status === FileStatus.PENDING);
    console.info(`[Index] startParse: ${pending.length} files pending`);
    if (pending.length === 0) {
      this.parseProgress = '无待解析文件';
      setTimeout(() => { this.parseProgress = ''; }, 2000);
      return;
    }

    this.isProcessing = true;
    this.progressLabel = '解析';
    this.progressPercent = 0;
    this.currentProcessingFile = '';
    this.parseProgress = `解析 0/${pending.length}`;
    let done = 0;

    for (const f of pending) {
      this.currentProcessingFile = f.name;
      this.progressPercent = Math.round(done / pending.length * 100);
      console.info(`[Index] Parsing ${f.name} (${f.type}), path: ${f.path.substring(0, 60)}`);
      try {
        // Use local parser (API server cannot access phone files)
        if (this.dataParser && this.dbManager) {
          const blocks = await this.dataParser.parseFile(f.path);
          console.info(`[Index] Parsed ${f.name}: ${blocks.length} blocks`);
          if (blocks.length > 0) {
            // Save data blocks to local database
            for (const block of blocks) {
              const addrValue = block.addr || '';
              if (!addrValue) {
                console.warn(`[Index] Block ${block.blockId} has empty addr, cache save may have failed`);
              }
              console.info(`[Index] Block: id=${block.blockId}, modality=${block.modality}, addr=${addrValue.substring(0, 50)}`);
              await this.dbManager.addDataBlock(
                block.blockId,
                f.id,
                block.modality.toString(),
                addrValue,  // 使用block.addr，不fallback到filePath
                block.pageNumber,
                JSON.stringify(block.position || {}),
                JSON.stringify(block.metadata || {})
              );
            }
            // Update file status to PARSED
            await this.dbManager.updateFileStatus(f.id, FileStatus.PARSED);
            console.info(`[Index] Updated file ${f.id} status to PARSED`);
          } else {
            console.warn(`[Index] No blocks returned for ${f.name}`);
          }
        }
        done++;
        this.progressPercent = Math.round(done / pending.length * 100);
        this.parseProgress = `解析 ${done}/${pending.length}`;

        // 每处理YIELD_INTERVAL个文件，让主线程休息一下
        if (done % YIELD_INTERVAL === 0) {
          await yieldMainThread();
        }
      } catch (e) {
        console.error(`[Index] Parse failed for ${f.name}:`, e);
        done++;
      }
    }

    await this.loadFiles();
    this.parseProgress = `解析完成: ${done}/${pending.length}`;
    this.progressPercent = 100;
    this.progressLabel = '';
    this.currentProcessingFile = '';
    console.info(`[Index] Parse completed: ${done}/${pending.length}`);
    setTimeout(() => { this.parseProgress = ''; this.progressPercent = 0; }, 3000);
    this.isProcessing = false;
  }

  private async startSemanticRepresent(): Promise<void> {
    const parsed = this.fileViewModel.files.filter(f => f.status === FileStatus.PARSED);
    console.info(`[Index] startSemanticRepresent: ${parsed.length} files parsed, imageFileTextMethod=${this.imageFileTextMethod}`);
    if (parsed.length === 0) {
      this.semanticProgress = '无待处理文件（请先解析）';
      setTimeout(() => { this.semanticProgress = ''; }, 2000);
      return;
    }

    this.isProcessing = true;
    this.progressLabel = '语义表征';
    this.progressPercent = 0;
    this.currentProcessingFile = '';
    this.semanticProgress = `语义表征 0/${parsed.length}`;
    let done = 0;

    // 使用已初始化的 semanticRep 实例，避免创建多个 Worker
    // 修复：使用 this.semanticRep 而非创建新实例
    if (!this.semanticRep) {
      this.semanticRep = new SemanticRepresentation();
      this.semanticRep.setContext(this.context as common.Context);
      if (this.dbManager) {
        this.semanticRep.setDatabaseManager(this.dbManager);
      }
      this.semanticRep.setImageFileTextMethod(this.imageFileTextMethod);
      this.semanticRep.setParsedImageTextMethod(this.parsedImageTextMethod);
      // 如果有 imageAnalysisService，设置到 semanticRep
      if (this.imageAnalysisService) {
        this.semanticRep.setImageAnalysisService(this.imageAnalysisService);
      }
      await this.semanticRep.initialize();
      console.info('[Index] SemanticRep initialized (new instance)');
    }

    const semanticRep = this.semanticRep;  // 使用现有实例

    // 创建分类服务用于语义表征阶段的默认分类（使用默认类别体系）
    const classificationService = new LocalClassificationService();
    classificationService.setClassificationMethod('similarity');
    classificationService.setDbManager(this.dbManager!);

    // 从数据库加载默认类别体系的类别
    if (this.dbManager) {
      const defaultCategories = await this.dbManager.getSemanticCategoriesBySystem('默认类别体系');
      if (defaultCategories.length > 0) {
        classificationService.setCategoriesFromDatabase(defaultCategories);
      }
    }

    // 初始化分类服务（需要embedding服务计算类别向量）
    if (this.semanticRep) {
      const embeddingService = this.semanticRep.getEmbeddingService();
      await classificationService.initialize(embeddingService);
    } else {
      await classificationService.initialize();
    }
    console.info('[Index] Classification service initialized for semantic representation phase');

    for (const f of parsed) {
      this.currentProcessingFile = f.name;
      this.progressPercent = Math.round(done / parsed.length * 100);
      console.info(`[Index] Processing semantic for ${f.name} (${f.type})`);
      try {
        if (this.dbManager) {
          const dbDataBlocks = await this.dbManager.getDataBlocksByFile(f.id);
          console.info(`[Index] Found ${dbDataBlocks.length} data blocks for file ${f.id}`);
          const blockIdToDbId: Map<string, number> = new Map();
          for (const db of dbDataBlocks) {
            blockIdToDbId.set(db.blockId, db.id);
            console.info(`[Index] DataBlock: id=${db.id}, blockId=${db.blockId}, modality=${db.modality}, addr=${db.addr?.substring(0, 50)}`);
          }

          const dataBlocks: DataBlock[] = [];
          for (const db of dbDataBlocks) {
            const block = new DataBlock();
            block.blockId = db.blockId;
            block.modality = db.modality === 'image' ? ModalityType.IMAGE :
              db.modality === 'table' ? ModalityType.TABLE : ModalityType.TEXT;
            block.filePath = f.path;  // 原始文件路径
            block.addr = db.addr;     // 数据块缓存路径，与Python一致
            block.pageNumber = db.pageNumber;
            block.metadata = db.metadata;  // 传递metadata，包含source字段
            dataBlocks.push(block);
          }

          const fileRecord = await this.dbManager.getFileById(f.id);

          // 在处理前yield，确保主线程有机会处理UI事件
          await yieldMainThread();

          const semanticBlocks = await semanticRep.representBatch(dataBlocks, fileRecord || undefined);
          console.info(`[Index] Generated ${semanticBlocks.length} semantic blocks for ${f.name}`);

          const semanticFilename = semanticRep.getMeaningfulFilenamePart(f.name);
          if (semanticFilename) {
            await this.dbManager.updateFileSemanticFilename(f.id, semanticFilename);
          }

          // 批量插入语义块后yield
          for (const semanticBlock of semanticBlocks) {
            const dataBlockIds: number[] = [];
            for (const dbBlock of dbDataBlocks) {
              dataBlockIds.push(dbBlock.id);
            }

            const vectorBytes = semanticBlock.semanticVector && semanticBlock.semanticVector.length > 0
              ? new Uint8Array(new Float32Array(semanticBlock.semanticVector).buffer)
              : new Uint8Array(0);

            await this.dbManager.addSemanticBlock(
              semanticBlock.blockId,
              dataBlockIds,
              f.id,
              semanticBlock.textDescription,
              semanticBlock.keywords,
              vectorBytes,
              semanticFilename,
              {}
            );
          }

          // 数据库批量操作后yield
          await yieldMainThread();

          const categories: CategoryScore[] = [];
          const isImage = this.isImageFileType(f.type);

          for (const semanticBlock of semanticBlocks) {
            const defaultResult = classificationService.classifyBySemanticBlock(semanticBlock);

            await this.dbManager.addClassificationResult(
              f.id,
              semanticBlock.blockId,
              defaultResult.categoryName,
              defaultResult.confidence,
              defaultResult.allScores,
              '默认类别体系'
            );

            const blockMetadata: Record<string, Record<string, number>> = {};
            blockMetadata['默认类别体系'] = defaultResult.allScores;

            if (isImage) {
              const imageResult = classificationService.classifyBySemanticBlock(semanticBlock);
              await this.dbManager.addClassificationResult(
                f.id,
                semanticBlock.blockId,
                imageResult.categoryName,
                imageResult.confidence,
                imageResult.allScores,
                '图片数据默认分类'
              );
              blockMetadata['图片数据默认分类'] = imageResult.allScores;
            }

            await this.dbManager.updateSemanticBlockMetadata(semanticBlock.blockId, blockMetadata);

            const existingCat = categories.find(c => c.category === defaultResult.categoryName);
            if (!existingCat) {
              const cat = new CategoryScore();
              cat.category = defaultResult.categoryName;
              cat.confidence = defaultResult.confidence;
              categories.push(cat);
            }
          }

          await this.dbManager.updateFileSemanticCategories(f.id, categories);
          await this.dbManager.updateFileStatus(f.id, FileStatus.PRELIMINARY);

          if (isImage) {
            try {
              const imageService = new LocalImageAnalysisService();
              imageService.setContext(this.context as common.Context);
              const metadata = await imageService.extractImageMetadata(f.path);
              const existingMetadata: FileMetadata = fileRecord?.metadata || {} as FileMetadata;
              existingMetadata['width'] = metadata.width;
              existingMetadata['height'] = metadata.height;
              existingMetadata['format'] = metadata.format;
              if (metadata.dateTime) {
                existingMetadata['dateTime'] = metadata.dateTime;
              }
              if (metadata.make) {
                existingMetadata['make'] = metadata.make;
              }
              if (metadata.model) {
                existingMetadata['model'] = metadata.model;
              }
              if (metadata.gpsLatitude && metadata.gpsLongitude) {
                existingMetadata['gpsLatitude'] = metadata.gpsLatitude;
                existingMetadata['gpsLongitude'] = metadata.gpsLongitude;
              }
              await this.dbManager.updateFileMetadata(f.id, existingMetadata);

              const originalCreatedTime = imageService.formatDateTime(metadata);
              const location = imageService.formatLocation(metadata);
              const hasInfo = !!(originalCreatedTime || location || metadata.make || metadata.model);
              const status = hasInfo ? SpatiotemporalAnalysisStatus.ANALYZED_HAS_INFO : SpatiotemporalAnalysisStatus.ANALYZED_NO_INFO;
              await this.dbManager.updateSpatiotemporalStatus(f.id, status, originalCreatedTime, location);
            } catch (imgErr) {
              console.warn(`[Index] Image metadata extraction failed for ${f.name}:`, imgErr);
            }
          }

          console.log(`[Index] Semantic representation completed for ${f.name}`);
        }
        done++;
        this.progressPercent = Math.round(done / parsed.length * 100);
        this.semanticProgress = `语义表征 ${done}/${parsed.length}`;

        // 每处理完一个文件后yield，确保UI可以更新
        if (done % YIELD_INTERVAL === 0) {
          await yieldMainThread();
        }
      } catch (e) {
        console.error(`[Index] Semantic represent failed for ${f.name}:`, e);
        done++;
      }
    }

    try {
      await semanticRep.release();
    } catch (e) {
      // ignore
    }

    await this.loadFiles();
    this.semanticProgress = `语义表征完成: ${done}/${parsed.length}`;
    this.progressPercent = 100;
    this.progressLabel = '';
    this.currentProcessingFile = '';
    setTimeout(() => { this.semanticProgress = ''; this.progressPercent = 0; }, 3000);
    this.isProcessing = false;
  }

  private isImageFileType(fileType: string): boolean {
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.livp', '.ico', '.svg'];
    return imageExtensions.some(ext => fileType.toLowerCase() === ext);
  }

  /**
   * 打开分类配置面板
   */
  private async openClassifyPanel(): Promise<void> {
    // 检查是否有待分类文件
    const toClassify = this.fileViewModel.files.filter(f => f.status === FileStatus.PRELIMINARY);
    if (toClassify.length === 0) {
      this.classifyProgress = '无待分类文件（请先语义表征）';
      setTimeout(() => { this.classifyProgress = ''; }, 2000);
      return;
    }

    // 加载类别体系列表
    await this.loadCategorySystems();

    // 打开面板
    this.showClassifyPanel = true;
  }

  /**
   * 加载类别体系列表
   */
  private async loadCategorySystems(): Promise<void> {
    if (!this.dbManager) return;

    try {
      // 获取所有类别体系名称
      const systems = await this.dbManager.getCategorySystemNames();
      this.categorySystems = systems;

      // 如果数据库中没有类别体系，初始化默认类别
      if (systems.length === 0) {
        console.info('[Index] No category systems in database, initializing defaults...');
        await this.dbManager.initCategorySystemsIfNeeded();
        // 重新获取
        const newSystems = await this.dbManager.getCategorySystemNames();
        if (newSystems.length > 0) {
          this.categorySystems = newSystems;
        } else {
          this.categorySystems = ['默认类别体系', '图片数据默认分类'];
        }
      }

      // 默认选中第一个
      if (this.selectedCategorySystem === '' || !this.categorySystems.includes(this.selectedCategorySystem)) {
        this.selectedCategorySystem = this.categorySystems[0];
      }

      // 预加载每个体系的类别
      this.categorySystemCategories = {};
      for (const system of this.categorySystems) {
        const categories = await this.dbManager.getSemanticCategoriesBySystem(system);
        if (categories.length > 0) {
          this.categorySystemCategories[system] = categories;
        }
      }

      console.info(`[Index] Loaded ${this.categorySystems.length} category systems, selected: ${this.selectedCategorySystem}`);
      for (const sys of this.categorySystems) {
        const catCount = this.categorySystemCategories[sys] ? this.categorySystemCategories[sys].length : 0;
        console.info(`[Index] System: ${sys}, categories: ${catCount}`);
      }
    } catch (e) {
      console.error(`[Index] Failed to load category systems: ${e}`);
      this.categorySystems = ['默认类别体系'];
      this.selectedCategorySystem = '默认类别体系';
    }
  }

  /**
   * 展开/折叠类别体系
   */
  private toggleCategorySystemExpand(systemName: string): void {
    if (this.expandedCategorySystem === systemName) {
      this.expandedCategorySystem = '';
    } else {
      this.expandedCategorySystem = systemName;
    }
  }

  /**
   * 选择类别体系
   */
  private selectCategorySystem(systemName: string): void {
    this.selectedCategorySystem = systemName;
  }

  /**
   * 确认并执行分类
   */
  private async confirmAndStartClassify(): Promise<void> {
    this.showClassifyPanel = false;
    await this.startClassify();
  }

  private async startClassify(): Promise<void> {
    // Get files that have semantic representation (status = PRELIMINARY)
    const toClassify = this.fileViewModel.files.filter(f =>
      f.status === FileStatus.PRELIMINARY);
    if (toClassify.length === 0) {
      this.classifyProgress = '无待分类文件（请先语义表征）';
      setTimeout(() => { this.classifyProgress = ''; }, 2000);
      return;
    }

    this.isProcessing = true;
    this.progressLabel = '分类';
    this.progressPercent = 0;
    this.currentProcessingFile = '';
    this.classifyProgress = `分类 0/${toClassify.length}`;
    let done = 0;

    // 创建分类服务并配置
    const classificationService = new LocalClassificationService();
    classificationService.setClassificationMethod(this.classificationMethod);
    classificationService.setContext(this.context!);

    // 设置数据库管理器（用于存储类别向量）
    if (this.dbManager) {
      classificationService.setDbManager(this.dbManager);
    }

    // 从数据库加载选中类别体系的类别配置
    if (this.dbManager) {
      const categoryRecords = await this.dbManager.getSemanticCategoriesBySystem(this.selectedCategorySystem);
      console.info(`[Index] Loaded ${categoryRecords.length} categories for system: ${this.selectedCategorySystem}`);
      classificationService.setCategoriesFromDatabase(categoryRecords);
    }

    // 初始化分类服务
    if (this.classificationMethod === 'similarity' || this.classificationMethod === 'cluster') {
      // 相似度和聚类方法需要embedding服务来计算类别向量
      if (this.semanticRep) {
        const embeddingService = this.semanticRep.getEmbeddingService();
        await classificationService.initialize(embeddingService);
      } else {
        await classificationService.initialize();
      }
    } else {
      // LLM分类只需要初始化LLM客户端
      await classificationService.initialize();
    }

    console.info(`[Index] Classification service initialized with method: ${this.classificationMethod}`);

    for (const f of toClassify) {
      this.currentProcessingFile = f.name;
      this.progressPercent = Math.round(done / toClassify.length * 100);
      try {
        if (this.dbManager) {
          // 获取文件的语义块进行分类
          const semanticBlockRecords = await this.dbManager.getSemanticBlocksByFile(f.id);
          console.info(`[Index] File ${f.name} has ${semanticBlockRecords.length} semantic blocks`);

          const categories: CategoryScore[] = [];
          const categoryCount: Record<string, number> = {};

          for (const blockRecord of semanticBlockRecords) {
            // 构建SemanticBlock用于分类
            const semanticBlock = new SemanticBlock();
            semanticBlock.blockId = blockRecord.semanticBlockId;
            semanticBlock.textDescription = blockRecord.textDescription;
            semanticBlock.keywords = blockRecord.keywords;
            // 从Uint8Array转换为Float32Array再转换为number[]
            if (blockRecord.semanticVector && blockRecord.semanticVector.length > 0) {
              const float32Array = new Float32Array(blockRecord.semanticVector.buffer);
              semanticBlock.semanticVector = Array.from(float32Array);
            }

            // 根据分类方法执行分类
            let result: ClassificationResult;
            if (this.classificationMethod === 'llm') {
              // LLM分类是异步的
              result = await classificationService.classifyWithLLMAsync(semanticBlock);
            } else {
              // 相似度和聚类分类
              result = classificationService.classifyBySemanticBlock(semanticBlock);
            }

            // 写入分类结果到数据库，使用选中的类别体系
            await this.dbManager.addClassificationResult(
              f.id,
              blockRecord.semanticBlockId,
              result.categoryName,
              result.confidence,
              result.allScores,
              this.selectedCategorySystem
            );

            // 更新语义块的metadata
            const blockMetadata: Record<string, Record<string, number>> = {};
            blockMetadata[this.selectedCategorySystem] = result.allScores;
            await this.dbManager.updateSemanticBlockMetadata(blockRecord.semanticBlockId, blockMetadata);

            // 统计类别
            if (!categoryCount[result.categoryName]) {
              categoryCount[result.categoryName] = 0;
            }
            categoryCount[result.categoryName]++;
          }

          // 根据语义块分类结果确定文件级别分类
          // 取出现次数最多的类别作为文件分类
          let bestCategory = '其他';
          let maxCount = 0;
          const categoryEntries = Object.keys(categoryCount);
          for (const cat of categoryEntries) {
            const count = categoryCount[cat];
            if (count > maxCount) {
              maxCount = count;
              bestCategory = cat;
            }
          }

          // 构建CategoryScore列表
          const categoryKeys = Object.keys(categoryCount);
          for (const cat of categoryKeys) {
            const count = categoryCount[cat];
            const confidence = count / semanticBlockRecords.length;
            const catScore = new CategoryScore();
            catScore.category = cat;
            catScore.confidence = confidence;
            categories.push(catScore);
          }

          await this.dbManager.updateFileSemanticCategories(f.id, categories);
          await this.dbManager.updateFileStatus(f.id, FileStatus.DEEP);
          console.log(`[Index] Classified ${f.name}: ${bestCategory} (${maxCount}/${semanticBlockRecords.length} blocks)`);
        }
        done++;
        this.progressPercent = Math.round(done / toClassify.length * 100);
        this.classifyProgress = `分类 ${done}/${toClassify.length}`;

        // 每处理YIELD_INTERVAL个文件，让主线程休息一下
        if (done % YIELD_INTERVAL === 0) {
          await yieldMainThread();
        }
      } catch (e) {
        console.error(`[Index] Classify failed for ${f.name}:`, e);
        done++;
      }
    }

    await this.loadFiles();
    this.classifyProgress = `分类完成: ${done}/${toClassify.length}`;
    this.progressPercent = 100;
    this.progressLabel = '';
    this.currentProcessingFile = '';
    setTimeout(() => { this.classifyProgress = ''; this.progressPercent = 0; }, 3000);
    this.isProcessing = false;
  }

  private guessCategoryFromType(type: string): string {
    const typeMap: Record<string, string> = {
      'pdf': '技术文档',
      'doc': '技术文档',
      'docx': '技术文档',
      'txt': '个人文档',
      'md': '技术文档',
      'xls': '商业报告',
      'xlsx': '商业报告',
      'csv': '商业报告',
      'ppt': '会议演示',
      'pptx': '会议演示',
      'jpg': '个人文档',
      'jpeg': '个人文档',
      'png': '个人文档',
      'gif': '个人文档'
    };
    return typeMap[type.toLowerCase()] || '未分类';
  }

  private async runParseAll(): Promise<void> {
    const pending = this.fileViewModel.files.filter(f => f.status === FileStatus.PENDING);
    if (pending.length === 0) return;
    this.isProcessing = true;
    this.processStep = '解析文件';
    let done = 0;
    for (const f of pending) {
      this.processProgress = `${++done}/${pending.length}`;
      try {
        if (this.apiConnected && this.apiService) {
          await this.apiService.analyzeFile(f.path);
        }
      } catch (e) { /* fallback */ }
    }
    await this.loadFiles();
    this.isProcessing = false;
  }

  // ============ Menu Actions ============

  private async analyzeImageMetadata(): Promise<void> {
    const images = this.fileViewModel.files.filter(f =>
      ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.tif', '.livp', '.ico', '.svg'].includes(f.type.toLowerCase()));

    if (images.length === 0) {
      this.dialogMessage = '没有图片文件';
      this.showConfirmDialog = true;
      return;
    }

    if (!this.imageAnalysisService) {
      this.imageAnalysisService = new LocalImageAnalysisService();
      this.imageAnalysisService.setContext(this.context!);
    }

    this.isProcessing = true;
    this.progressLabel = '时空分析';
    this.progressPercent = 0;
    this.currentProcessingFile = '';
    this.imageMetaProgress = `时空分析 0/${images.length}`;
    let done = 0;
    for (const img of images) {
      this.currentProcessingFile = img.name;
      this.progressPercent = Math.round(done / images.length * 100);
      try {
        // 本地提取图片元数据
        const metadata = await this.imageAnalysisService.extractImageMetadata(img.path);

        // 更新数据库 - 仅更新文件表
        if (this.dbManager) {
          const location = await this.imageAnalysisService.formatLocationAsync(metadata);  // 使用异步版本获取精确地名
          const createdTime = this.imageAnalysisService.formatDateTime(metadata);

          // 根据是否提取到信息设置正确的状态
          const hasInfo = !!(createdTime || location || metadata.make || metadata.model);
          const status = hasInfo ? SpatiotemporalAnalysisStatus.ANALYZED_HAS_INFO : SpatiotemporalAnalysisStatus.ANALYZED_NO_INFO;

          await this.dbManager.updateSpatiotemporalStatus(
            img.id,
            status,
            createdTime,
            location
          );

          // 更新文件表metadata（时空信息属于文件属性）
          const metaData: FileMetadata = {
            'width': metadata.width,
            'height': metadata.height,
            'make': metadata.make || '',
            'model': metadata.model || '',
            'dateTime': metadata.dateTime || '',
            'gpsLatitude': metadata.gpsLatitude || 0,
            'gpsLongitude': metadata.gpsLongitude || 0
          };
          await this.dbManager.updateFileMetadata(img.id, metaData);
        }
        done++;
        this.progressPercent = Math.round(done / images.length * 100);
        this.imageMetaProgress = `时空分析 ${done}/${images.length}`;
      } catch (e) {
        console.error(`[Index] Image metadata failed:`, e);
        done++;
      }
    }

    await this.loadFiles();
    this.isProcessing = false;
    this.imageMetaProgress = `时空分析完成: ${done}/${images.length}`;
    this.progressPercent = 100;
    this.progressLabel = '';
    this.currentProcessingFile = '';
    setTimeout(() => { this.imageMetaProgress = ''; this.progressPercent = 0; }, 3000);
    this.dialogMessage = `图片时空分析完成: ${done}/${images.length}`;
    this.showConfirmDialog = true;
  }

  private async analyzeImageCaption(): Promise<void> {
    const images = this.fileViewModel.files.filter(f =>
      ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.tif', '.livp', '.ico', '.svg'].includes(f.type.toLowerCase()));

    if (images.length === 0) {
      this.dialogMessage = '没有图片文件';
      this.showConfirmDialog = true;
      return;
    }

    // 端侧模式不需要API密钥，云端模式需要
    if (this.captionMode === CaptionMode.CLOUD && !this.llmApiKey) {
      this.dialogMessage = '请先在设置中配置LLM API密钥';
      this.showConfirmDialog = true;
      return;
    }

    if (!this.imageAnalysisService) {
      this.imageAnalysisService = new LocalImageAnalysisService();
      this.imageAnalysisService.setContext(this.context!);
      this.imageAnalysisService.setCaptionMode(this.captionMode);
      this.imageAnalysisService.setApiKey(this.llmApiKey);
      this.imageAnalysisService.setProvider(this.llmProvider, this.llmEndpoint, this.llmModel);
      this.imageAnalysisService.setTimeout(this.llmTimeout);
      this.imageAnalysisService.setMaxTokens(this.llmMaxTokens);
      this.imageAnalysisService.setTemperature(this.llmTemperature);
      // 如果是端侧模式，加载模型
      if (this.captionMode === CaptionMode.LOCAL) {
        await this.imageAnalysisService.loadLocalCaptionModel();
      }
    } else {
      // 已存在，确保设置正确的模式
      this.imageAnalysisService.setCaptionMode(this.captionMode);
      if (this.captionMode === CaptionMode.LOCAL && !this.imageAnalysisService.isLocalCaptionAvailable()) {
        await this.imageAnalysisService.loadLocalCaptionModel();
      }
    }

    this.isProcessing = true;
    this.progressLabel = 'Caption生成';
    this.progressPercent = 0;
    this.currentProcessingFile = '';
    this.imageCaptionProgress = `Caption 0/${images.length}`;
    let done = 0;
    for (const img of images) {
      this.currentProcessingFile = img.name;
      this.progressPercent = Math.round(done / images.length * 100);
      try {
        // 本地调用LLM生成Caption
        const result = await this.imageAnalysisService.generateCaption(img.path, img.id);

        // 更新数据库 - 使用正确的状态值
        if (this.dbManager) {
          // 判断是否有有效信息（caption或tags不为空）
          const hasInfo = result.caption && result.caption.trim() || result.tags && result.tags.length > 0;
          const status = hasInfo ? CaptionAnalysisStatus.ANALYZED_HAS_INFO : CaptionAnalysisStatus.ANALYZED_FAILED;
          await this.dbManager.updateCaptionStatus(img.id, status);

          // 更新元数据中的caption
          if (result.caption || result.tags) {
            const metaData: Record<string, string | number | string[]> = {
              'caption': result.caption || '',
              'captionTags': result.tags || [],
              'captionConfidence': result.confidence || 0
            };
            await this.dbManager.updateFileMetadata(img.id, metaData);
          }
        }
        done++;
        this.progressPercent = Math.round(done / images.length * 100);
        this.imageCaptionProgress = `Caption ${done}/${images.length}`;

        // 每处理完一个图片caption后yield，因为caption生成非常耗时
        await yieldMainThread();
      } catch (e) {
        console.error(`[Index] Image caption failed:`, e);
        // 失败时更新状态为 ANALYZED_FAILED
        if (this.dbManager) {
          await this.dbManager.updateCaptionStatus(img.id, CaptionAnalysisStatus.ANALYZED_FAILED);
        }
        done++;
      }
    }

    await this.loadFiles();
    this.isProcessing = false;
    this.imageCaptionProgress = `Caption完成: ${done}/${images.length}`;
    this.progressPercent = 100;
    this.progressLabel = '';
    this.currentProcessingFile = '';
    setTimeout(() => { this.imageCaptionProgress = ''; this.progressPercent = 0; }, 3000);
    this.dialogMessage = `图片Caption生成完成: ${done}/${images.length}`;
    this.showConfirmDialog = true;
  }

  // ============ System Data Access ============

  /**
   * 扫描可转换的Office文件
   */
  private async scanConvertibleFiles(): Promise<void> {
    console.info('[Index] Scanning for convertible Office files...');
    this.convertibleFiles = [];
    this.officeConversionResult = '';
    this.officeConversionError = '';
    this.officeConversionPercent = 0;

    try {
      // Scan from fileViewModel (already loaded files)
      for (const file of this.fileViewModel.files) {
        const filePath: string = file.path;
        const ext: string = filePath.substring(filePath.lastIndexOf('.')).toLowerCase();

        if (ext === '.xls' || ext === '.doc' || ext === '.ppt') {
          this.convertibleFiles.push(filePath);
          console.info(`[Index] Found convertible file: ${filePath}`);
        }
      }

      // Also scan filesDir for any additional files
      const filesDir: string = this.context!.filesDir;
      try {
        const dirs: string[] = await fileIo.listFile(filesDir);
        for (const fileName of dirs) {
          const filePath: string = `${filesDir}/${fileName}`;
          const ext: string = filePath.substring(filePath.lastIndexOf('.')).toLowerCase();

          if (ext === '.xls' || ext === '.doc' || ext === '.ppt') {
            // Check if not already added
            if (!this.convertibleFiles.includes(filePath)) {
              this.convertibleFiles.push(filePath);
              console.info(`[Index] Found convertible file in filesDir: ${filePath}`);
            }
          }
        }
      } catch (e) {
        console.warn(`[Index] Failed to list filesDir: ${String(e)}`);
      }

      console.info(`[Index] Found ${this.convertibleFiles.length} convertible files`);
    } catch (error) {
      this.officeConversionError = `扫描失败: ${String(error)}`;
      console.error(`[Index] Scan failed: ${String(error)}`);
    }
  }

  /**
   * 开始Office格式转换
   */
  private async startOfficeConversion(): Promise<void> {
    console.info('[Index] Starting Office conversion...');
    this.isConvertingOffice = true;
    this.officeConversionPercent = 0;
    this.officeConversionResult = '';
    this.officeConversionError = '';
    this.convertedOutputFiles = [];

    if (!this.officeConversionService) {
      this.officeConversionService = new OfficeConversionService();
    }

    // Set output directory to cache directory (for sync)
    this.officeConversionService.setOutputDirectory(this.context!.cacheDir);

    const totalFiles = this.convertibleFiles.length;
    let successCount = 0;
    let failedCount = 0;

    for (let i = 0; i < this.convertibleFiles.length; i++) {
      const filePath = this.convertibleFiles[i];
      console.info(`[Index] Converting: ${filePath}`);

      try {
        const result = await this.officeConversionService.convertOfficeFile(filePath);

        if (result.success) {
          successCount++;
          this.convertedOutputFiles.push(result.outputPath);
          console.info(`[Index] Conversion success: ${result.outputPath}`);
        } else {
          failedCount++;
          console.error(`[Index] Conversion failed: ${filePath}`);
        }
      } catch (error) {
        failedCount++;
        console.error(`[Index] Conversion error: ${String(error)}`);
      }

      this.officeConversionPercent = Math.round((i + 1) / totalFiles * 100);
    }

    this.isConvertingOffice = false;

    // 构建结果消息，包含输出文件路径
    let resultMsg = `转换完成: ${successCount} 成功, ${failedCount} 失败`;
    if (this.convertedOutputFiles.length > 0) {
      resultMsg += `\n\n转换后的文件:\n`;
      for (const outputPath of this.convertedOutputFiles) {
        const fileName = outputPath.substring(outputPath.lastIndexOf('/') + 1);
        resultMsg += `• ${fileName}\n`;
      }
      resultMsg += `\n文件保存在缓存目录的 converted 子目录\n可通过"设置页同步"上传到服务端`;
    }
    this.officeConversionResult = resultMsg;
    console.info(`[Index] Conversion completed: ${successCount} success, ${failedCount} failed`);
  }

  /**
   * 加载系统数据
   * 注意：需要在root设备上执行，且需要先设置 SELinux 为 Permissive
   */
  private async loadSystemData(dataType: string): Promise<void> {
    this.isLoadingSystemData = true;
    this.systemDataError = '';
    console.info(`[Index] Loading system data: ${dataType}`);

    try {
      const reader = new RootDataReader(this.context!);

      if (dataType === 'contacts') {
        const contacts = await reader.readContacts(50);
        if (contacts.length === 0) {
          this.systemContactsData = [
            ['提示', '无数据或无法访问'],
            ['原因', '需要root权限且设置SELinux为Permissive'],
            ['命令', 'hdc shell "setenforce 0"']
          ];
          this.systemDataError = '联系人数据为空或无法访问\n请确保:\n1. 设备已root\n2. SELinux已设置为Permissive\n\n执行命令: hdc shell "setenforce 0"';
        } else {
          this.systemContactsData = [
            ['ID', '姓名', '电话']
          ];
          for (const c of contacts) {
            this.systemContactsData.push([
              String(c.id),
              c.displayName,
              c.phoneNumber || '(无)'
            ]);
          }
        }
        this.systemDataTab = 0;
      } else if (dataType === 'callLog') {
        const callLogs = await reader.readCallLog(50);
        if (callLogs.length === 0) {
          this.systemCallLogData = [
            ['提示', '无数据或无法访问'],
            ['数据库', SYSTEM_DB_PATHS.callLog]
          ];
          this.systemDataError = '通话记录为空或无法访问';
        } else {
          this.systemCallLogData = [
            ['ID', '号码', '时间', '时长(秒)', '类型', '姓名']
          ];
          for (const c of callLogs) {
            const typeStr = c.type === 1 ? '来电' : c.type === 2 ? '去电' : c.type === 3 ? '未接' : '未知';
            this.systemCallLogData.push([
              String(c.id),
              c.number,
              new Date(c.date).toLocaleString(),
              String(c.duration),
              typeStr,
              c.name || '(无)'
            ]);
          }
        }
        this.systemDataTab = 1;
      } else if (dataType === 'sms') {
        const smsList = await reader.readSms(50);
        if (smsList.length === 0) {
          this.systemSmsData = [
            ['提示', '无数据或无法访问'],
            ['数据库', SYSTEM_DB_PATHS.sms]
          ];
          this.systemDataError = '短信数据为空或无法访问';
        } else {
          this.systemSmsData = [
            ['ID', '内容']
          ];
          for (const s of smsList) {
            this.systemSmsData.push([
              String(s.id),
              '(数据解析待完善)'
            ]);
          }
        }
        this.systemDataTab = 2;
      } else if (dataType === 'calendar') {
        const events = await reader.readCalendarEvents(50);
        if (events.length === 0) {
          this.systemCalendarData = [
            ['提示', '无数据或无法访问'],
            ['数据库', SYSTEM_DB_PATHS.calendar]
          ];
          this.systemDataError = '日历数据为空或无法访问';
        } else {
          this.systemCalendarData = [
            ['ID', '标题', '开始时间', '结束时间', '地点']
          ];
          for (const e of events) {
            this.systemCalendarData.push([
              String(e.id),
              e.title || '(无)',
              e.dtstart ? new Date(e.dtstart).toLocaleString() : '(无)',
              e.dtend ? new Date(e.dtend).toLocaleString() : '(无)',
              e.eventLocation || '(无)'
            ]);
          }
        }
        this.systemDataTab = 3;
      }

    } catch (e) {
      console.error(`[Index] loadSystemData failed:`, e);
      this.systemDataError = `加载失败: ${(e as Error).message}\n\n请确保:\n1. 设备已root\n2. SELinux已设置为Permissive\n\n执行命令: hdc shell "setenforce 0"`;
    }

    this.isLoadingSystemData = false;
  }

  private confirmClearHistory(): void {
    this.confirmAction = 'clearHistory';
    this.dialogMessage = '确定要清空所有历史数据吗？';
    this.showConfirmDialog = true;
  }

  private confirmClearClassification(): void {
    this.confirmAction = 'clearClassification';
    this.dialogMessage = '确定要清空分类结果吗？';
    this.showConfirmDialog = true;
  }

  private async executeConfirmAction(): Promise<void> {
    // 使用本地数据库操作，不再依赖服务器
    if (this.confirmAction === 'clearHistory') {
      try {
        if (this.dbManager) {
          const success = await this.dbManager.clearAllData();
          if (success) {
            // 同时清空所有缓存文件
            await CacheUtils.getInstance().clearAllCache();
            await this.loadFiles();
            this.dialogMessage = '历史数据和缓存已清空';
          } else {
            this.dialogMessage = '清空失败';
          }
        } else {
          this.dialogMessage = '数据库未初始化';
        }
      } catch (e) {
        this.dialogMessage = '清空失败: ' + e;
      }
    } else if (this.confirmAction === 'clearClassification') {
      try {
        if (this.dbManager) {
          // 清空分类结果和语义数据，保留文件记录
          const success = await this.dbManager.clearClassificationData();
          if (success) {
            await this.loadFiles();
            this.dialogMessage = '分类结果已清空';
          } else {
            this.dialogMessage = '清空失败';
          }
        } else {
          this.dialogMessage = '数据库未初始化';
        }
      } catch (e) {
        this.dialogMessage = '清空失败: ' + e;
      }
    }

    this.confirmAction = '';
  }

  private showAbout(): void {
    this.showAboutDialog = true;
  }

  // ============ File Preview ============

  private async selectFile(file: FileItem): Promise<void> {
    console.info('[Index] selectFile called for:', file.name, 'type:', file.type);
    this.selectedFile = file;
    this.currentTab = 1; // Switch to preview tab
    this.previewContent = '';
    this.previewBlocks = [];
    this.semanticBlocks = [];
    this.previewPageNumber = 1;
    this.pdfPageCount = 0;
    this.pdfPixelMap = null;
    this.previewTextContent = '';
    this.imagePixelMap = null;
    this.isLoadingPreview = true;
    // 重置时空分析和caption信息
    this.previewDateTime = '';
    this.previewLocation = '';
    this.previewDevice = '';
    this.previewCaption = '';
    this.previewTags = [];
    this.previewCaptionConfidence = 0;
    // 重置Office Web预览状态
    this.officeFileContentBase64 = '';
    this.officeWebReady = false;
    this.officePreviewError = '';

    // Release previous PDF document
    if (this.pdfDoc) {
      try {
        this.pdfDoc.releaseDocument();
      } catch (e) {}
      this.pdfDoc = null;
    }

    const ext = file.type.toLowerCase();
    console.info('[Index] File extension:', ext);

    // 从数据库加载时空分析和caption信息
    if (this.dbManager) {
      try {
        const record = await this.dbManager.getFileById(file.id);
        if (record) {
          // 时空分析信息
          this.previewDateTime = record.originalCreatedTime || '';
          this.previewLocation = record.location || '';

          // 从metadata中提取信息
          const metadata = record.metadata;
          if (metadata) {
            const makeVal = metadata['make'];
            const modelVal = metadata['model'];
            const make = typeof makeVal === 'string' ? makeVal : '';
            const model = typeof modelVal === 'string' ? modelVal : '';
            this.previewDevice = make && model ? `${make} ${model}` : make || model || '';

            const captionVal = metadata['caption'];
            this.previewCaption = typeof captionVal === 'string' ? captionVal : '';
            const tagsVal = metadata['captionTags'];
            this.previewTags = Array.isArray(tagsVal) ? tagsVal as string[] : [];
            const confVal = metadata['captionConfidence'];
            this.previewCaptionConfidence = typeof confVal === 'number' ? confVal : 0;
          }
        }
      } catch (e) {
        console.warn('[Index] Failed to load metadata:', e);
      }
    }

    // Load preview data based on file type
    try {
      if (this.isImageFile(ext)) {
        // For images, decode to PixelMap for display
        console.info('[Index] Loading image preview...');
        await this.loadImagePreview(file.path);
      } else if (ext === '.pdf') {
        // Load PDF and render first page
        console.info('[Index] Loading PDF preview...');
        await this.loadPdfPreview(file.path);
      } else if (this.isMarkdownFile(ext)) {
        // Markdown files - use Web preview
        console.info('[Index] Loading Markdown preview...');
        await this.loadMarkdownPreview(file.path);
      } else if (this.isTextFile(ext)) {
        // Load text file content
        console.info('[Index] Loading text preview...');
        await this.loadTextPreview(file.path);
      } else if (this.isOfficeFile(ext)) {
        // Office files - extract text content via parser
        console.info('[Index] Office file detected:', ext);
        await this.loadOfficePreview(file);
      } else {
        this.previewContent = `文件: ${decodeFileName(file.name)}\n类型: ${ext.toUpperCase()}\n大小: ${this.fileViewModel.formatFileSize(file.size)}\n分类: ${file.category}\n置信度: ${(file.confidence * 100).toFixed(1)}%`;
      }

      // Load semantic blocks from API if connected
      if (this.apiConnected && this.apiService) {
        try {
          const resp = await this.apiService.getFileDetails(file.id);
          if (resp.semantic_blocks) {
            this.semanticBlocks = resp.semantic_blocks.map((sb: SemanticBlockDetail) => {
              const block: FileSemanticBlock = {
                blockId: sb.semantic_block_id,
                textDescription: sb.text_description,
                keywords: sb.keywords || [],
                category: '',
                confidence: 0
              };
              return block;
            });
          }
        } catch (e) { /* fallback */ }
      }
    } catch (e) {
      console.error('[Index] Preview load failed:', e);
      this.previewContent = `预览加载失败: ${decodeFileName(file.name)}`;
    }

    this.isLoadingPreview = false;
    console.info('[Index] Preview loaded - imagePixelMap:', this.imagePixelMap ? 'set' : 'null', 'textContent:', this.previewTextContent ? this.previewTextContent.length : 0);
  }

  private isTextFile(ext: string): boolean {
    const textExts = ['.txt', '.json', '.xml', '.html', '.csv', '.py', '.js', '.css', '.log'];
    return textExts.includes(ext.toLowerCase());
  }

  private isMarkdownFile(ext: string): boolean {
    const markdownExts = ['.md', '.markdown'];
    return markdownExts.includes(ext.toLowerCase());
  }

  private isOfficeFile(ext: string): boolean {
    const officeExts = ['.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx'];
    return officeExts.includes(ext.toLowerCase());
  }

  private getOfficeFileInfo(file: FileItem): string {
    const ext = file.type.toLowerCase();
    let typeName = '';
    if (ext === '.doc' || ext === '.docx') {
      typeName = 'Word文档';
    } else if (ext === '.xls' || ext === '.xlsx') {
      typeName = 'Excel表格';
    } else if (ext === '.ppt' || ext === '.pptx') {
      typeName = 'PowerPoint演示文稿';
    } else {
      typeName = 'Office文档';
    }

    return `文件: ${decodeFileName(file.name)}\n类型: ${typeName} (${ext.toUpperCase()})\n大小: ${this.fileViewModel.formatFileSize(file.size)}\n分类: ${file.category}\n置信度: ${(file.confidence * 100).toFixed(1)}%\n\n提示: Office文档暂不支持内容预览`;
  }

  private async loadOfficePreview(file: FileItem): Promise<void> {
    const ext = file.type.toLowerCase();
    let typeName = '';
    if (ext === '.doc' || ext === '.docx') {
      typeName = 'Word文档';
    } else if (ext === '.xls' || ext === '.xlsx') {
      typeName = 'Excel表格';
    } else if (ext === '.ppt' || ext === '.pptx') {
      typeName = 'PowerPoint演示文稿';
    } else {
      typeName = 'Office文档';
    }

    const decodedName = decodeFileName(file.name);

    // Only PPTX files can use Web preview
    if (ext === '.pptx') {
      try {
        console.info('[Index] Loading PPTX for Web preview:', file.path);

        // Open file and read content
        const sourceFile = await fileIo.open(file.path, fileIo.OpenMode.READ_ONLY);
        const stat = await fileIo.stat(sourceFile.fd);
        const fileSize = stat.size;
        console.info('[Index] PPTX file size:', fileSize);

        // Limit file size for performance (max 50MB)
        const maxSize = 50 * 1024 * 1024;
        if (fileSize > maxSize) {
          console.info('[Index] PPTX file too large:', fileSize, '> ', maxSize);
          this.officePreviewError = '文件过大，建议使用系统应用打开';
          this.previewContent = `文件: ${decodedName}\n类型: ${typeName} (${ext.toUpperCase()})\n大小: ${this.fileViewModel.formatFileSize(file.size)}\n\n${this.officePreviewError}`;
          await fileIo.close(sourceFile.fd);
          return;
        }

        // Read file content
        const buffer = new ArrayBuffer(fileSize);
        await fileIo.read(sourceFile.fd, buffer);
        await fileIo.close(sourceFile.fd);

        // Convert to Base64
        const uint8Array = new Uint8Array(buffer);
        const base64Helper = new util.Base64Helper();
        this.officeFileContentBase64 = base64Helper.encodeToStringSync(uint8Array);
        console.info('[Index] PPTX Base64 length:', this.officeFileContentBase64.length);

        // Set preview content
        this.previewContent = `文件: ${decodedName}\n类型: ${typeName} (${ext.toUpperCase()})\n大小: ${this.fileViewModel.formatFileSize(file.size)}`;
        this.officePreviewError = '';

        // Send content to Web component when ready
        if (this.officeWebReady && this.officeFileContentBase64) {
          this.sendOfficeFileToWeb();
        }
      } catch (err) {
        console.error('[Index] Failed to load PPTX content:', err);
        this.officePreviewError = `加载失败: ${(err as Error).message}`;
        this.previewContent = `文件: ${decodedName}\n类型: ${typeName} (${ext.toUpperCase()})\n大小: ${this.fileViewModel.formatFileSize(file.size)}\n\n${this.officePreviewError}\n\n提示: 点击下方按钮用系统应用打开查看`;
      }
    } else {
      // Other Office files (docx, xlsx, etc.) - show info only
      this.previewContent = `文件: ${decodedName}\n类型: ${typeName} (${ext.toUpperCase()})\n大小: ${this.fileViewModel.formatFileSize(file.size)}\n分类: ${file.category}\n置信度: ${(file.confidence * 100).toFixed(1)}%\n\n提示: 点击下方按钮用系统应用打开查看`;
    }
  }

  private sendOfficeFileToWeb(): void {
    if (!this.officeFileContentBase64 || !this.selectedFile) return;

    interface FileInfoObj {
      name: string;
      type: string;
      size: string;
    }
    const fileInfo: FileInfoObj = {
      name: decodeFileName(this.selectedFile.name),
      type: this.selectedFile.type.toUpperCase(),
      size: this.fileViewModel.formatFileSize(this.selectedFile.size)
    };

    // Send message to Web component via JavaScript injection
    try {
      const fileInfoJson = JSON.stringify(fileInfo);
      // Use setPPTXContent function for better handling of large data
      this.webController.runJavaScript(
        `window.setPPTXContent('${this.officeFileContentBase64}', ${fileInfoJson});`
      );
      console.info('[Index] Office file content sent to Web via setPPTXContent');
    } catch (err) {
      console.error('[Index] Failed to send to Web:', err);
      this.officePreviewError = '预览加载失败';
    }
  }

  private async openDocumentWithSystem(file: FileItem): Promise<void> {
    try {
      console.info('[Index] Opening document with system app:', file.path);

      // Get MIME type based on file extension
      const ext = file.type.toLowerCase();
      let mimeType = 'application/octet-stream';
      if (ext === '.doc') {
        mimeType = 'application/msword';
      } else if (ext === '.docx') {
        mimeType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      } else if (ext === '.xls') {
        mimeType = 'application/vnd.ms-excel';
      } else if (ext === '.xlsx') {
        mimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      } else if (ext === '.ppt') {
        mimeType = 'application/vnd.ms-powerpoint';
      } else if (ext === '.pptx') {
        mimeType = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      }

      // Use document.show to open the file with system app
      await document.show(file.path, mimeType);
      console.info('[Index] Document opened successfully');
    } catch (err) {
      console.error('[Index] Failed to open document:', err);
      // Show error message to user
      this.previewContent = `打开文档失败: ${(err as Error).message}\n\n请确保已安装支持此文档类型的应用`;
    }
  }

  private async loadImagePreview(filePath: string): Promise<void> {
    try {
      // Release previous image
      if (this.imagePixelMap) {
        this.imagePixelMap.release();
        this.imagePixelMap = null;
      }

      // 检查是否是 livp 格式（Live Photo）
      const ext = filePath.toLowerCase().split('.').pop() || '';
      if (ext === 'livp') {
        await this.loadLivpPreview(filePath);
        return;
      }

      console.info('[Index] Opening image file:', filePath);
      // Open file and create ImageSource
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      console.info('[Index] File opened, fd:', file.fd);

      const imageSource = image.createImageSource(file.fd);
      console.info('[Index] ImageSource created');

      // Decode to PixelMap
      this.imagePixelMap = await imageSource.createPixelMap();
      console.info('[Index] PixelMap created successfully');

      await fileIo.close(file.fd);
      this.previewContent = `图片预览: ${this.selectedFile?.name || ''}`;
    } catch (e) {
      console.error('[Index] Image preview failed:', JSON.stringify(e));
      this.previewContent = `图片预览失败: ${this.selectedFile?.name || ''}\n\n错误: ${JSON.stringify(e)}`;
    }
  }

  /**
   * 加载 Live Photo (.livp) 预览
   * livp 是 Apple Live Photo 格式，包含静态图片和视频的 ZIP 文件
   */
  private async loadLivpPreview(filePath: string): Promise<void> {
    try {
      console.info('[Index] Loading Live Photo (livp):', filePath);
      this.previewContent = `Live Photo 文件: ${this.selectedFile?.name || ''}\n正在提取静态图片...`;

      // 使用 ZipReader 解压 livp 文件
      const entries = await ZipReader.readZipFile(filePath);
      const entryNames = Array.from(entries.keys());
      console.info('[Index] livp entries:', entryNames);

      // 查找图片文件（通常是 HEIC 或 JPEG）
      const imageExtensions = ['.heic', '.heif', '.jpg', '.jpeg', '.png'];
      let imageFileName = '';

      // 查找第一个图片文件
      for (const name of entryNames) {
        const entryExt = '.' + (name.split('.').pop()?.toLowerCase() || '');
        if (imageExtensions.includes(entryExt)) {
          imageFileName = name;
          break;
        }
      }

      if (!imageFileName) {
        this.previewContent = `Live Photo 文件: ${this.selectedFile?.name || ''}\n\n格式说明: Live Photo (.livp) 是 Apple 的动态照片格式。\n\n提示: 未找到可预览的静态图片，可能需要其他应用查看。`;
        console.warn('[Index] No image found in livp');
        return;
      }

      const imageEntry = entries.get(imageFileName);
      if (!imageEntry || !imageEntry.data) {
        this.previewContent = `Live Photo 文件: ${this.selectedFile?.name || ''}\n\n提示: 图片数据无效，可能需要其他应用查看。`;
        console.warn('[Index] Image entry has no data');
        return;
      }

      const imageData = imageEntry.data;
      console.info('[Index] Found image in livp:', imageFileName, 'size:', imageData.length);

      // 将提取的图片数据写入临时文件进行预览
      const context = getContext(this) as common.Context;
      const tempDir = context.cacheDir || '/data/storage/el2/base/cache';
      const imageExt = imageFileName.split('.').pop() || 'jpg';
      const tempImagePath = `${tempDir}/livp_preview_${Date.now()}.${imageExt}`;
      console.info('[Index] Writing temp image to:', tempImagePath);

      // 写入临时文件
      const tempFile = await fileIo.open(tempImagePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      const buffer = new ArrayBuffer(imageData.length);
      const view = new Uint8Array(buffer);
      for (let i = 0; i < imageData.length; i++) {
        view[i] = imageData[i];
      }
      await fileIo.write(tempFile.fd, buffer);
      await fileIo.close(tempFile.fd);

      // 使用 ImageSource 加载临时图片
      const imageFile = await fileIo.open(tempImagePath, fileIo.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(imageFile.fd);
      this.imagePixelMap = await imageSource.createPixelMap();
      await fileIo.close(imageFile.fd);

      // 清理临时文件
      try {
        await fileIo.unlink(tempImagePath);
      } catch (e) {
        console.warn('[Index] Failed to cleanup temp file:', e);
      }

      this.previewContent = `Live Photo 预览: ${this.selectedFile?.name || ''}\n(已提取静态图片: ${imageFileName})`;
      console.info('[Index] livp preview successful');
    } catch (e) {
      console.error('[Index] livp preview failed:', JSON.stringify(e));
      this.previewContent = `Live Photo 预览失败: ${this.selectedFile?.name || ''}\n\n错误: ${JSON.stringify(e)}`;
    }
  }

  private async loadPdfPreview(filePath: string): Promise<void> {
    try {
      console.info('[Index] Loading PDF preview for:', filePath);

      // PDF service needs file in app sandbox, not picker URI
      // Step 1: Open file from picker URI
      const sourceFile = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      console.info('[Index] PDF source file opened, fd:', sourceFile.fd);

      // Step 2: Copy to sandbox temp directory
      const context = getContext(this) as common.Context;
      const tempDir = context.cacheDir || '/data/storage/el2/base/cache';
      const fileName = filePath.split('/').pop() || 'temp.pdf';
      const tempPath = `${tempDir}/${fileName}`;
      console.info('[Index] Copying PDF to:', tempPath);

      // Read source file content
      const stat = await fileIo.stat(sourceFile.fd);
      const fileSize = stat.size;
      console.info('[Index] PDF file size:', fileSize);

      const buffer = new ArrayBuffer(fileSize);
      await fileIo.read(sourceFile.fd, buffer);
      await fileIo.close(sourceFile.fd);

      // Write to sandbox temp file
      const destFile = await fileIo.open(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      await fileIo.write(destFile.fd, buffer);
      await fileIo.close(destFile.fd);
      console.info('[Index] PDF copied to sandbox');

      // Step 3: Load PDF from sandbox path
      this.pdfDoc = new pdfService.PdfDocument();
      console.info('[Index] PdfDocument created');

      const loadResult = this.pdfDoc.loadDocument(tempPath);
      console.info('[Index] PDF load result:', loadResult);

      if (loadResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        console.error('[Index] PDF load failed with result:', loadResult);
        this.previewContent = `PDF加载失败: ${this.selectedFile?.name || ''} (错误码: ${loadResult})`;
        return;
      }

      this.pdfPageCount = this.pdfDoc.getPageCount();
      console.info('[Index] PDF page count:', this.pdfPageCount);

      await this.renderPdfPage(1);
      console.info('[Index] PDF page 1 rendered, pdfPixelMap:', this.pdfPixelMap ? 'created' : 'null');

      this.previewContent = `PDF预览: ${this.selectedFile?.name || ''} (共${this.pdfPageCount}页)`;

      // Clean up temp file after preview
      try {
        await fileIo.unlink(tempPath);
        console.info('[Index] Temp PDF file cleaned up');
      } catch (e) {
        console.warn('[Index] Temp file cleanup failed:', e);
      }
    } catch (e) {
      console.error('[Index] PDF preview failed:', JSON.stringify(e));
      this.previewContent = `PDF预览失败: ${this.selectedFile?.name || ''}`;
    }
  }

  private async renderPdfPage(pageNum: number): Promise<void> {
    if (!this.pdfDoc || pageNum < 1 || pageNum > this.pdfPageCount) return;

    try {
      // Release previous pixel map
      if (this.pdfPixelMap) {
        this.pdfPixelMap.release();
        this.pdfPixelMap = null;
      }

      console.info('[Index] Getting page:', pageNum - 1);
      const page = this.pdfDoc.getPage(pageNum - 1);
      console.info('[Index] Page obtained, getting pixel map...');

      this.pdfPixelMap = page.getPagePixelMap();
      console.info('[Index] PixelMap obtained:', this.pdfPixelMap ? 'success' : 'failed');

      this.previewPageNumber = pageNum;
    } catch (e) {
      console.error('[Index] Render PDF page failed:', JSON.stringify(e));
    }
  }

  private async loadTextPreview(filePath: string): Promise<void> {
    try {
      console.info('[Index] Opening text file:', filePath);
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      console.info('[Index] Text file opened, fd:', file.fd);

      const stat = await fileIo.stat(file.fd);
      console.info('[Index] File size:', stat.size);

      const maxReadSize = Math.min(stat.size, 10000);
      const buffer = new ArrayBuffer(maxReadSize);

      await fileIo.read(file.fd, buffer);
      console.info('[Index] File read completed');

      await fileIo.close(file.fd);

      const textDecoder = new util.TextDecoder('utf-8');
      this.previewTextContent = textDecoder.decodeToString(new Uint8Array(buffer));

      if (stat.size > maxReadSize) {
        this.previewTextContent += '\n... (文件较长，仅显示前10000字节)';
      }
      console.info('[Index] Text preview loaded, length:', this.previewTextContent.length);
    } catch (e) {
      console.error('[Index] Text preview failed:', JSON.stringify(e));
      this.previewContent = `文本预览失败: ${this.selectedFile?.name || ''}`;
    }
  }

  private async loadMarkdownPreview(filePath: string): Promise<void> {
    try {
      console.info('[Index] Opening Markdown file:', filePath);
      this.markdownPreviewError = '';
      this.markdownWebReady = false;
      this.markdownFileContentBase64 = '';

      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      console.info('[Index] Markdown file opened, fd:', file.fd);

      const stat = await fileIo.stat(file.fd);
      console.info('[Index] Markdown file size:', stat.size);

      const maxReadSize = Math.min(stat.size, 100000); // Limit to 100KB for markdown
      const buffer = new ArrayBuffer(maxReadSize);

      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);

      // Convert to Base64 for Web component
      const bytes = new Uint8Array(buffer);
      const base64Helper = new util.Base64Helper();
      this.markdownFileContentBase64 = base64Helper.encodeToStringSync(bytes);

      // Set preview content info
      this.previewContent = `文件: ${decodeFileName(this.selectedFile?.name || '')}\n类型: Markdown文档\n大小: ${this.fileViewModel.formatFileSize(stat.size)}`;

      if (stat.size > maxReadSize) {
        this.previewContent += '\n(文件较长，仅显示前100KB)';
      }

      console.info('[Index] Markdown content prepared for Web preview, base64 length:', this.markdownFileContentBase64.length);
    } catch (e) {
      console.error('[Index] Markdown preview failed:', JSON.stringify(e));
      this.markdownPreviewError = '加载Markdown文件失败';
      this.previewContent = `Markdown预览失败: ${this.selectedFile?.name || ''}`;
    }
  }

  private sendMarkdownFileToWeb(): void {
    if (this.markdownFileContentBase64 && this.markdownWebReady) {
      const jsCode = `window.setMarkdownContent("${this.markdownFileContentBase64}")`;
      console.info('[Index] Sending Markdown content to Web, length:', jsCode.length);
      this.markdownWebController.runJavaScript(jsCode)
        .then(() => console.info('[Index] Markdown content sent successfully'))
        .catch((err: Error) => {
          console.error('[Index] Failed to send Markdown content:', err);
          this.markdownPreviewError = '渲染失败';
        });
    }
  }

  private prevPage(): void {
    if (this.previewPageNumber > 1) {
      this.renderPdfPage(this.previewPageNumber - 1);
    }
  }

  private nextPage(): void {
    if (this.previewPageNumber < this.pdfPageCount) {
      this.renderPdfPage(this.previewPageNumber + 1);
    }
  }

  // ============ Search ============

  private async doSearch(): Promise<void> {
    if (!this.searchQuery.trim()) return;

    // API search
    if (this.apiConnected && this.apiService) {
      try {
        const resp = await this.apiService.search(this.searchQuery, 20);
        this.searchResults = [];
        if (resp.results) {
          for (const r of resp.results) {
            const local = this.fileViewModel.files.find(f => f.id === r.file_id);
            if (local) this.searchResults.push(local);
          }
        }
        return;
      } catch (e) { /* fallback */ }
    }

    // Local fallback
    const q = this.searchQuery.toLowerCase();
    this.searchResults = this.fileViewModel.files.filter(f =>
      f.name.toLowerCase().includes(q) || f.category.toLowerCase().includes(q));
  }

  // ============ Build UI ============

  build() {
    Stack() {
      Column() {
        // 主UI立即显示
        this.TitleBar();
        this.WorkflowBar();
        this.TabContent();
        this.BottomTabs();

        // 后台初始化进度条（底部）
        if (this.isInitializing) {
          Row() {
            Progress({ value: this.initPercent, total: 100, type: ProgressType.Linear })
              .width('60%')
              .color($r('app.color.primary'))
            Text(this.initProgress)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .height(28)
          .backgroundColor('#F0F0F0')
          .padding({ left: 16, right: 16 })
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))

      // Drawer Menu
      if (this.showDrawer) {
        this.DrawerMenu();
      }

      // System Data Page
      if (this.showSystemDataPage) {
        this.SystemDataPage();
      }

      // Office Conversion Dialog
      if (this.showOfficeConvertDialog) {
        this.OfficeConvertDialog();
      }

      // About Dialog
      if (this.showAboutDialog) {
        this.AboutDialogBuilder();
      }

      // Confirm Dialog
      if (this.showConfirmDialog) {
        this.ConfirmDialogBuilder();
      }

      // Reset Database Dialog
      if (this.showResetDbDialog) {
        this.ResetDbDialogBuilder();
      }

      // Classification Config Panel
      if (this.showClassifyPanel) {
        this.ClassifyConfigPanelBuilder();
      }
    }
    .width('100%')
    .height('100%')
  }

  // ----------- Drawer Menu -----------
  @Builder
  DrawerMenu() {
    Row() {
      Column() {
        Text('菜单')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 20, bottom: 16 })

        Divider().color('#E0E0E0')

        this.MenuItem('功能一致性测试', () => {
          this.showDrawer = false;
          router.pushUrl({ url: 'pages/TestPage' });
        })

        Divider().margin({ top: 8, bottom: 8 }).color('#E0E0E0')

        this.MenuItem('图片时空分析', () => {
          this.showDrawer = false;
          this.analyzeImageMetadata();
        })

        this.MenuItem('图片Caption生成', () => {
          this.showDrawer = false;
          this.analyzeImageCaption();
        })

        Divider().margin({ top: 8, bottom: 8 }).color('#E0E0E0')

        this.MenuItem('系统数据获取', () => {
          this.showDrawer = false;
          this.showSystemDataPage = true;
          this.loadSystemData('contacts');
        })

        this.MenuItem('Office格式升级', () => {
          this.showDrawer = false;
          this.showOfficeConvertDialog = true;
          this.scanConvertibleFiles();
        })

        Divider().margin({ top: 8, bottom: 8 }).color('#E0E0E0')

        this.MenuItem('清空历史数据', () => {
          this.showDrawer = false;
          this.confirmClearHistory();
        })

        this.MenuItem('清空分类结果', () => {
          this.showDrawer = false;
          this.confirmClearClassification();
        })

        Divider().margin({ top: 8, bottom: 8 }).color('#E0E0E0')

        this.MenuItem('关于', () => {
          this.showDrawer = false;
          this.showAbout();
        })

        Blank()

        Text('关闭')
          .fontSize(14)
          .fontColor('#666666')
          .padding(12)
          .onClick(() => { this.showDrawer = false; })
      }
      .width(220)
      .height('100%')
      .padding(16)
      .backgroundColor(Color.White)

      Blank()
        .layoutWeight(1)
        .backgroundColor('#80000000')
        .onClick(() => { this.showDrawer = false; })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MenuItem(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(action)
  }

  // ----------- Office Conversion Dialog -----------
  @Builder
  OfficeConvertDialog() {
    Column() {
      // Header
      Row() {
        Text('Office格式升级')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)

        Blank()

        Text('×')
          .fontSize(24)
          .fontColor('#666666')
          .onClick(() => { this.showOfficeConvertDialog = false; })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Color.White)

      Divider().color('#E0E0E0')

      // Content
      Column() {
        if (this.convertibleFiles.length === 0) {
          Text('未找到可转换的Office文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(16)
        } else {
          Text(`发现 ${this.convertibleFiles.length} 个可转换文件`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8, bottom: 8 })

          // File list
          Scroll() {
            Column() {
              ForEach(this.convertibleFiles, (filePath: string, index: number) => {
                Row() {
                  Text(filePath.substring(filePath.lastIndexOf('/') + 1))
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                }
                .width('100%')
                .padding(8)
                .backgroundColor(index % 2 === 0 ? Color.White : '#F5F5F5')
              })
            }
          }
          .width('100%')
          .height(200)
          .margin({ top: 8, bottom: 8 })

          // Progress
          if (this.isConvertingOffice) {
            Row() {
              Text('转换进度:')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))

              Text(`${this.officeConversionPercent}%`)
                .fontSize(14)
                .fontColor('#2196F3')
            }
            .width('100%')
            .padding(8)

            Progress({ value: this.officeConversionPercent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .margin({ top: 4 })
          }

          // Result
          if (this.officeConversionResult) {
            Text(this.officeConversionResult)
              .fontSize(14)
              .fontColor('#4CAF50')
              .margin({ top: 8 })
          }

          if (this.officeConversionError) {
            Text(this.officeConversionError)
              .fontSize(12)
              .fontColor('#F44336')
              .margin({ top: 8 })
          }
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.page_background'))

      Divider().color('#E0E0E0')

      // Buttons
      Row() {
        Button('取消')
          .fontSize(14)
          .backgroundColor('#E0E0E0')
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.showOfficeConvertDialog = false; })

        Button('开始转换')
          .fontSize(14)
          .backgroundColor('#2196F3')
          .fontColor(Color.White)
          .enabled(!this.isConvertingOffice && this.convertibleFiles.length > 0)
          .onClick(() => { this.startOfficeConversion(); })
      }
      .width('100%')
      .padding(16)
      .justifyContent(FlexAlign.End)
      .backgroundColor(Color.White)
    }
    .width(320)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  // ----------- System Data Page -----------
  @Builder
  SystemDataPage() {
    Column() {
      // Header
      Row() {
        Text('←')
          .fontSize(24)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.showSystemDataPage = false; })

        Text('系统数据获取')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })

        Blank()
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Color.White)

      // Tabs
      Row() {
        Button('联系人')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.systemDataTab === 0 ? '#2196F3' : '#E0E0E0')
          .fontColor(this.systemDataTab === 0 ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            this.systemDataTab = 0;
            this.loadSystemData('contacts');
          })

        Button('通话记录')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.systemDataTab === 1 ? '#2196F3' : '#E0E0E0')
          .fontColor(this.systemDataTab === 1 ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            this.systemDataTab = 1;
            this.loadSystemData('callLog');
          })

        Button('短信')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.systemDataTab === 2 ? '#2196F3' : '#E0E0E0')
          .fontColor(this.systemDataTab === 2 ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            this.systemDataTab = 2;
            this.loadSystemData('sms');
          })

        Button('日历')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.systemDataTab === 3 ? '#2196F3' : '#E0E0E0')
          .fontColor(this.systemDataTab === 3 ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            this.systemDataTab = 3;
            this.loadSystemData('calendar');
          })
      }
      .width('100%')
      .padding(8)
      .justifyContent(FlexAlign.SpaceAround)
      .backgroundColor(Color.White)

      Divider().color('#E0E0E0')

      // Content
      Column() {
        if (this.isLoadingSystemData) {
          LoadingProgress()
            .width(50)
            .height(50)
            .color('#2196F3')
        } else if (this.systemDataError) {
          Text(this.systemDataError)
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .padding(16)
            .textAlign(TextAlign.Start)
        } else {
          // Data table
          this.SystemDataTable();
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor($r('app.color.page_background'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  SystemDataTable() {
    Scroll() {
      Column() {
        // Get current data based on tab
        if (this.systemDataTab === 0 && this.systemContactsData.length > 0) {
          ForEach(this.systemContactsData, (row: string[], rowIndex: number) => {
            Row() {
              ForEach(row, (cell: string, colIndex: number) => {
                Text(cell)
                  .fontSize(rowIndex === 0 ? 13 : 12)
                  .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(rowIndex === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                  .padding(8)
                  .borderWidth(1)
                  .borderColor('#E0E0E0')
                  .flexGrow(colIndex === 0 ? 0 : 1)
                  .width(colIndex === 0 ? 80 : 'auto')
              })
            }
            .width('100%')
            .backgroundColor(rowIndex === 0 ? '#F5F5F5' : Color.White)
          })
        } else if (this.systemDataTab === 1 && this.systemCallLogData.length > 0) {
          ForEach(this.systemCallLogData, (row: string[], rowIndex: number) => {
            Row() {
              ForEach(row, (cell: string, colIndex: number) => {
                Text(cell)
                  .fontSize(rowIndex === 0 ? 13 : 12)
                  .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(rowIndex === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                  .padding(8)
                  .borderWidth(1)
                  .borderColor('#E0E0E0')
                  .flexGrow(1)
              })
            }
            .width('100%')
            .backgroundColor(rowIndex === 0 ? '#F5F5F5' : Color.White)
          })
        } else if (this.systemDataTab === 2 && this.systemSmsData.length > 0) {
          ForEach(this.systemSmsData, (row: string[], rowIndex: number) => {
            Row() {
              ForEach(row, (cell: string, colIndex: number) => {
                Text(cell)
                  .fontSize(rowIndex === 0 ? 13 : 12)
                  .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(rowIndex === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                  .padding(8)
                  .borderWidth(1)
                  .borderColor('#E0E0E0')
                  .flexGrow(1)
              })
            }
            .width('100%')
            .backgroundColor(rowIndex === 0 ? '#F5F5F5' : Color.White)
          })
        } else if (this.systemDataTab === 3 && this.systemCalendarData.length > 0) {
          ForEach(this.systemCalendarData, (row: string[], rowIndex: number) => {
            Row() {
              ForEach(row, (cell: string, colIndex: number) => {
                Text(cell)
                  .fontSize(rowIndex === 0 ? 13 : 12)
                  .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(rowIndex === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                  .padding(8)
                  .borderWidth(1)
                  .borderColor('#E0E0E0')
                  .flexGrow(1)
              })
            }
            .width('100%')
            .backgroundColor(rowIndex === 0 ? '#F5F5F5' : Color.White)
          })
        } else {
          Text('无数据')
            .fontSize(14)
            .fontColor($r('app.color.text_hint'))
            .padding(16)
        }
      }
      .width('100%')
      .padding(8)
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ----------- About Dialog -----------
  @Builder
  AboutDialogBuilder() {
    Column() {
      Column() {
        Text('文件分析管理器')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 12 })

        Text('版本: 1.0.0')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ bottom: 8 })

        Text('基于文件分析引擎的本地文件管理工具')
          .fontSize(13)
          .fontColor($r('app.color.text_hint'))
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        Text('支持多种文件格式的解析、预览和语义分析')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .textAlign(TextAlign.Center)

        Button('确定')
          .width(100)
          .margin({ top: 20 })
          .onClick(() => { this.showAboutDialog = false; })
      }
      .width(280)
      .padding(24)
      .backgroundColor(Color.White)
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
  }

  // ----------- Reset Database Dialog -----------
  @Builder
  ResetDbDialogBuilder() {
    Column() {
      Column() {
        Text('确认重置数据库')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ bottom: 16 })

        Text('此操作将删除所有数据并重新创建数据库，包括：')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ bottom: 8 })

        Text('• 所有文件记录\n• 所有数据块\n• 所有语义块\n• 所有分类结果\n• 所有缓存数据')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ bottom: 16 })

        Text('此操作不可撤销！')
          .fontSize(14)
          .fontColor('#F44336')
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 24 })

        if (this.resetDbStatus) {
          Text(this.resetDbStatus)
            .fontSize(14)
            .fontColor(this.resetDbStatus.includes('✓') ? '#4CAF50' : '#F44336')
            .margin({ bottom: 16 })
        }

        Row() {
          Button('取消')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor('#E0E0E0')
            .borderRadius(8)
            .onClick(() => {
              this.showResetDbDialog = false;
              this.resetDbStatus = '';
            })

          Button('确认重置')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor('#F44336')
            .borderRadius(8)
            .enabled(!this.isResettingDb)
            .onClick(() => {
              this.resetDatabase();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('85%')
      .padding(24)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .justifyContent(FlexAlign.Center)
  }

  // ----------- Classification Config Panel -----------
  @Builder
  ClassifyConfigPanelBuilder() {
    Column() {
      Column() {
        // 标题
        Row() {
          Text('分类配置')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Blank()

          Text('✕')
            .fontSize(24)
            .fontColor($r('app.color.text_secondary'))
            .onClick(() => { this.showClassifyPanel = false; })
        }
        .width('100%')
        .margin({ bottom: 16 })

        // 分类方法选择
        Text('分类方法')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .margin({ bottom: 12 })

        Row() {
          // 相似度分类
          Column() {
            Text('相似度')
              .fontSize(14)
              .fontWeight(this.classificationMethod === 'similarity' ? FontWeight.Bold : FontWeight.Normal)
            Text('向量融合')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .padding(10)
          .borderRadius(8)
          .backgroundColor(this.classificationMethod === 'similarity' ? '#E3F2FD' : '#F5F5F5')
          .borderWidth(this.classificationMethod === 'similarity' ? 2 : 0)
          .borderColor($r('app.color.primary'))
          .onClick(() => { this.classificationMethod = 'similarity'; })
          .margin({ right: 8 })

          // 聚类分类
          Column() {
            Text('聚类')
              .fontSize(14)
              .fontWeight(this.classificationMethod === 'cluster' ? FontWeight.Bold : FontWeight.Normal)
            Text('向量聚类')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .padding(10)
          .borderRadius(8)
          .backgroundColor(this.classificationMethod === 'cluster' ? '#E3F2FD' : '#F5F5F5')
          .borderWidth(this.classificationMethod === 'cluster' ? 2 : 0)
          .borderColor($r('app.color.primary'))
          .onClick(() => { this.classificationMethod = 'cluster'; })
          .margin({ right: 8 })

          // LLM分类
          Column() {
            Text('LLM')
              .fontSize(14)
              .fontWeight(this.classificationMethod === 'llm' ? FontWeight.Bold : FontWeight.Normal)
            Text('模型分类')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .padding(10)
          .borderRadius(8)
          .backgroundColor(this.classificationMethod === 'llm' ? '#E3F2FD' : '#F5F5F5')
          .borderWidth(this.classificationMethod === 'llm' ? 2 : 0)
          .borderColor($r('app.color.primary'))
          .onClick(() => { this.classificationMethod = 'llm'; })
        }
        .width('100%')
        .margin({ bottom: 16 })

        Divider().color('#E0E0E0').margin({ bottom: 16 })

        // 类别体系选择
        Text('选择类别体系')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .margin({ bottom: 12 })

        // 类别体系列表（可展开）
        Column() {
          ForEach(this.categorySystems, (systemName: string) => {
            Column() {
              // 类别体系标题行
              Row() {
                // 选择指示器
                Radio({ value: systemName, group: 'categorySystem' })
                  .checked(this.selectedCategorySystem === systemName)
                  .onChange((isChecked: boolean) => {
                    if (isChecked) {
                      this.selectCategorySystem(systemName);
                    }
                  })
                  .margin({ right: 8 })

                Text(systemName)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                // 类别数量
                Text(`${this.categorySystemCategories[systemName] ? this.categorySystemCategories[systemName].length : 0}个类别`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ right: 8 })

                // 展开/折叠按钮
                Text(this.expandedCategorySystem === systemName ? '▼' : '▶')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                  .onClick(() => { this.toggleCategorySystemExpand(systemName); })
              }
              .width('100%')
              .padding(12)
              .backgroundColor(this.selectedCategorySystem === systemName ? '#E8F5E9' : '#F5F5F5')
              .borderRadius(8)
              .onClick(() => {
                this.selectCategorySystem(systemName);
              })

              // 展开的类别列表
              if (this.expandedCategorySystem === systemName && this.categorySystemCategories[systemName]) {
                Column() {
                  ForEach(this.categorySystemCategories[systemName], (category: SemanticCategoryRecord) => {
                    Row() {
                      Text('•')
                        .fontSize(14)
                        .fontColor($r('app.color.text_secondary'))
                        .margin({ right: 8 })

                      Text(category.categoryName)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)

                      if (category.description) {
                        Text(category.description.substring(0, 20) + '...')
                          .fontSize(12)
                          .fontColor($r('app.color.text_hint'))
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, top: 6, bottom: 6 })
                  })
                }
                .width('100%')
                .padding({ left: 8, top: 4, bottom: 4 })
                .backgroundColor('#FAFAFA')
                .borderRadius(4)
                .margin({ top: 4, left: 12, right: 12 })
              }
            }
            .width('100%')
            .margin({ bottom: 8 })
          })
        }
        .width('100%')
        .margin({ bottom: 16 })

        Divider().color('#E0E0E0').margin({ bottom: 16 })

        // 待分类文件数量提示
        Row() {
          Text(`待分类文件: ${this.fileViewModel.files.filter(f => f.status === FileStatus.PRELIMINARY).length}个`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .margin({ bottom: 16 })

        // 操作按钮
        Row() {
          Button('取消')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor('#E0E0E0')
            .borderRadius(8)
            .onClick(() => { this.showClassifyPanel = false; })

          Button('开始分类')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor('#9C27B0')
            .borderRadius(8)
            .onClick(() => { this.confirmAndStartClassify(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('85%')
      .constraintSize({ maxHeight: '80%' })
      .padding(20)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .justifyContent(FlexAlign.Center)
  }

  // ----------- Confirm Dialog -----------
  @Builder
  ConfirmDialogBuilder() {
    Column() {
      Column() {
        Text(this.dialogMessage)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .margin({ bottom: 20 })

        Row() {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor('#F5F5F5')
            .fontColor('#666666')
            .onClick(() => {
              this.showConfirmDialog = false;
              this.confirmAction = '';
            })

          if (this.confirmAction) {
            Button('确定')
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(async () => {
                await this.executeConfirmAction();
              })
          } else {
            Button('确定')
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => { this.showConfirmDialog = false; })
          }
        }
        .width('100%')
      }
      .width(280)
      .padding(24)
      .backgroundColor(Color.White)
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
  }

  // ----------- Title Bar -----------
  @Builder
  TitleBar() {
    Column() {
      Row() {
        // Menu button
        Text('☰')
          .fontSize(24)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.showDrawer = true; })

        Text('文件分析管理器')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()

        // Encoder status badge
        Row() {
          Text(this.encoderStatus)
            .fontSize(10)
            .fontColor(this.isOfflineMode ? '#4CAF50' : '#2196F3')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor(this.isOfflineMode ? '#E8F5E9' : '#E3F2FD')
        }
        .margin({ right: 8 })

        // Status indicator
        Row() {
          Circle({ width: 8, height: 8 })
            .fill(this.useServer ? (this.apiConnected ? '#4CAF50' : '#F44336') : '#2196F3')
          Text(this.apiStatusText)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.surface'))
    }
  }

  // ----------- Workflow Toolbar (Parse → Semantic → Classify) -----------
  @Builder
  WorkflowBar() {
    Column() {
      Row() {
        Button('扫描')
          .fontSize(12)
          .height(32)
          .layoutWeight(1)
          .backgroundColor('#2196F3')
          .enabled(!this.isScanning && !this.isProcessing)
          .onClick(() => { this.pickFiles(); })

        Button('解析')
          .fontSize(12)
          .height(32)
          .layoutWeight(1)
          .margin({ left: 4 })
          .backgroundColor('#00BCD4')
          .enabled(!this.isScanning && !this.isProcessing)
          .onClick(() => { this.startParse(); })

        Button(this.getSemanticButtonLabel())
          .fontSize(12)
          .height(32)
          .layoutWeight(1)
          .margin({ left: 4 })
          .backgroundColor('#FF9800')
          .enabled(!this.isScanning && !this.isProcessing)
          .onClick(() => { this.startSemanticRepresent(); })

        Button('分类')
          .fontSize(12)
          .height(32)
          .layoutWeight(1)
          .margin({ left: 4 })
          .backgroundColor('#9C27B0')
          .enabled(!this.isScanning && !this.isProcessing)
          .onClick(() => { this.openClassifyPanel(); })
      }
      .width('100%')

      // Progress bar
      if (this.isProcessing && this.progressLabel) {
        Column() {
          Row() {
            Text(`${this.progressLabel}: ${this.progressPercent}%`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.currentProcessingFile)
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '50%' })
          }
          .width('100%')

          Progress({ value: this.progressPercent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
            .color('#2196F3')
            .backgroundColor('#E0E0E0')
            .margin({ top: 4 })
        }
        .width('100%')
        .margin({ top: 6 })
      }

      // Progress text indicators
      if (!this.isProcessing) {
        Row() {
          if (this.scanProgress) {
            Text(this.scanProgress)
              .fontSize(11)
              .fontColor('#2196F3')
              .margin({ right: 8 })
          }
          if (this.parseProgress) {
            Text(this.parseProgress)
              .fontSize(11)
              .fontColor('#00BCD4')
              .margin({ right: 8 })
          }
          if (this.semanticProgress) {
            Text(this.semanticProgress)
              .fontSize(11)
              .fontColor('#FF9800')
              .margin({ right: 8 })
          }
          if (this.classifyProgress) {
            Text(this.classifyProgress)
              .fontSize(11)
              .fontColor('#9C27B0')
              .margin({ right: 8 })
          }
          if (this.imageMetaProgress) {
            Text(this.imageMetaProgress)
              .fontSize(11)
              .fontColor('#4CAF50')
              .margin({ right: 8 })
          }
          if (this.imageCaptionProgress) {
            Text(this.imageCaptionProgress)
              .fontSize(11)
              .fontColor('#E91E63')
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }

      // Offline mode indicator
      if (this.isOfflineMode && !this.apiConnected) {
        Row() {
          Text('离线模式')
            .fontSize(11)
            .fontColor('#4CAF50')
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.surface'))
  }

  private getSemanticButtonLabel(): string {
    const parsed = this.fileViewModel.files.filter(f => f.status === FileStatus.PARSED);
    const prelim = this.fileViewModel.files.filter(f => f.status === FileStatus.PRELIMINARY);
    if (parsed.length > 0) {
      return `表征(${parsed.length})`;
    }
    if (prelim.length > 0) {
      return '已表征';
    }
    return '未表征';
  }

  // ----------- Tab Content -----------
  @Builder
  TabContent() {
    if (this.currentTab === 0) {
      this.FilesTab();
    } else if (this.currentTab === 1) {
      this.PreviewTab();
    } else if (this.currentTab === 2) {
      this.CategoriesTab();
    } else if (this.currentTab === 3) {
      this.SearchTab();
    } else {
      this.SettingsQuickView();
    }
  }

  // ----------- Files Tab -----------
  @Builder
  FilesTab() {
    Column() {
      // Processing overlay
      if (this.isScanning) {
        Row() {
          LoadingProgress().width(20).height(20).color($r('app.color.primary'))
          Text(this.scanProgress)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .margin({ left: 8 })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#E3F2FD')
      }

      // File type filter
      Row() {
        Text('全部')
          .fontSize(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor(this.searchFilter === 'all' ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.searchFilter === 'all' ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => { this.searchFilter = 'all'; })
        Text('文档')
          .fontSize(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor(['pdf', 'doc', 'docx', 'txt'].some(e => this.searchFilter === e) ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.searchFilter === 'doc' ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => { this.searchFilter = 'doc'; })
        Text('图片')
          .fontSize(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor(this.searchFilter === 'img' ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.searchFilter === 'img' ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => { this.searchFilter = 'img'; })
        Text('表格')
          .fontSize(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor(this.searchFilter === 'xls' ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.searchFilter === 'xls' ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => { this.searchFilter = 'xls'; })
        Text('演示')
          .fontSize(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor(this.searchFilter === 'ppt' ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.searchFilter === 'ppt' ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => { this.searchFilter = 'ppt'; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })

      // File list
      List() {
        ForEach(this.getFilteredFiles(), (file: FileItem) => {
          ListItem() {
            this.FileItemBuilder(file);
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  private getFilteredFiles(): FileItem[] {
    let files = this.fileViewModel.files;
    if (this.searchFilter === 'doc') {
      files = files.filter(f => ['.pdf', '.doc', '.docx', '.txt', '.md'].includes(f.type.toLowerCase()));
    } else if (this.searchFilter === 'img') {
      files = files.filter(f => ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.tif', '.livp', '.ico', '.svg'].includes(f.type.toLowerCase()));
    } else if (this.searchFilter === 'xls') {
      files = files.filter(f => ['.xls', '.xlsx', '.csv'].includes(f.type.toLowerCase()));
    } else if (this.searchFilter === 'ppt') {
      files = files.filter(f => ['.ppt', '.pptx'].includes(f.type.toLowerCase()));
    }
    return files;
  }

  @Builder
  FileItemBuilder(file: FileItem) {
    Row() {
      // File type icon
      Text(this.getFileIcon(file.type))
        .fontSize(28)
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor('#F5F5F5')

      // File info
      Column() {
        Text(decodeFileName(file.name))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          Text(this.fileViewModel.formatFileSize(file.size))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Text(' · ')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Text(file.type.toUpperCase())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .margin({ top: 2 })

        // Category tag
        Row() {
          Text(file.category)
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor(this.getCategoryColor(file.category))

          Text(`${(file.confidence * 100).toFixed(0)}%`)
            .fontSize(11)
            .fontColor(file.confidence >= 0.8 ? '#4CAF50' : file.confidence >= 0.5 ? '#FF9800' : '#F44336')
            .margin({ left: 6 })
        }
        .margin({ top: 4 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      // Status
      Text(this.fileViewModel.getStatusText(file.status))
        .fontSize(11)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .fontColor(this.fileViewModel.getStatusColor(file.status))
        .backgroundColor(this.fileViewModel.getStatusColor(file.status) + '20')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(10)
    .margin({ bottom: 6 })
    .onClick(() => { this.selectFile(file); })
  }

  private getFileIcon(type: string): string {
    const icons: Record<string, string> = {
      '.pdf': '📄', '.doc': '📝', '.docx': '📝', '.txt': '📃', '.md': '📃',
      '.xls': '📊', '.xlsx': '📊', '.csv': '📊',
      '.ppt': '📋', '.pptx': '📋',
      '.jpg': '🖼', '.jpeg': '🖼', '.png': '🖼', '.gif': '🖼', '.bmp': '🖼', '.webp': '🖼', '.heic': '🖼', '.heif': '🖼', '.tiff': '🖼', '.tif': '🖼', '.livp': '🖼',
      '.mp3': '🎵', '.wav': '🎵', '.mp4': '🎬',
      '.json': '📋', '.xml': '📋', '.html': '🌐'
    };
    return icons[type.toLowerCase()] || '📎';
  }

  // ----------- Preview Tab -----------
  @Builder
  PreviewTab() {
    Scroll() {
      Column() {
        if (this.selectedFile) {
          // File header
          Row() {
            Text(this.getFileIcon(this.selectedFile.type))
              .fontSize(36)
            Column() {
              Text(decodeFileName(this.selectedFile.name))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text(`${this.selectedFile.type.toUpperCase()} · ${this.fileViewModel.formatFileSize(this.selectedFile.size)}`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
            }
            .margin({ left: 12 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)

          // Classification result
          Row() {
            Text('分类: ')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Text(this.selectedFile.category)
              .fontSize(14)
              .fontColor(Color.White)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(6)
              .backgroundColor(this.getCategoryColor(this.selectedFile.category))
            Text(`  置信度: ${(this.selectedFile.confidence * 100).toFixed(1)}%`)
              .fontSize(14)
              .fontColor(this.selectedFile.confidence >= 0.8 ? '#4CAF50' : '#FF9800')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
          .margin({ top: 8 })

          // 时空分析信息（仅图片文件显示）
          if (this.isImageFile(this.selectedFile.type) && (this.previewDateTime || this.previewLocation || this.previewDevice)) {
            Column() {
              Text('时空分析')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .width('100%')

              if (this.previewDateTime) {
                Row() {
                  Text('📅 拍摄时间:')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.previewDateTime)
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .margin({ top: 8 })
              }

              if (this.previewLocation) {
                Row() {
                  Text('📍 拍摄位置:')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.previewLocation)
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .margin({ top: 4 })
              }

              if (this.previewDevice) {
                Row() {
                  Text('📷 拍摄设备:')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.previewDevice)
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .margin({ top: 4 })
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .margin({ top: 8 })
          }

          // Caption信息（仅图片文件显示）
          if (this.isImageFile(this.selectedFile.type) && this.previewCaption) {
            Column() {
              Row() {
                Text('AI描述')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))

                if (this.previewCaptionConfidence > 0) {
                  Text(` (${(this.previewCaptionConfidence * 100).toFixed(0)}%)`)
                    .fontSize(12)
                    .fontColor('#4CAF50')
                }
              }
              .width('100%')

              Text(this.previewCaption)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ top: 8 })

              if (this.previewTags.length > 0) {
                Row() {
                  ForEach(this.previewTags.slice(0, 6), (tag: string) => {
                    Text(tag)
                      .fontSize(11)
                      .fontColor('#2196F3')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(4)
                      .backgroundColor('#E3F2FD')
                      .margin({ right: 4, top: 4 })
                  })
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .margin({ top: 8 })
          }

          // Loading indicator
          if (this.isLoadingPreview) {
            Column() {
              LoadingProgress().width(32).height(32).color($r('app.color.primary'))
              Text('加载预览...')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 8 })
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .margin({ top: 8 })
          }

          // Actual Preview Content
          if (!this.isLoadingPreview) {
            this.PreviewContentArea()
          }

          // Semantic blocks
          if (this.semanticBlocks.length > 0) {
            Text('语义分析')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 16, bottom: 8 })

            ForEach(this.semanticBlocks, (sb: FileSemanticBlock) => {
              Column() {
                Text(sb.textDescription || '无描述')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(5)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                if (sb.keywords.length > 0) {
                  Row() {
                    ForEach(sb.keywords.slice(0, 8), (kw: string) => {
                      Text(kw)
                        .fontSize(12)
                        .fontColor($r('app.color.primary'))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(4)
                        .backgroundColor('#E3F2FD')
                        .margin({ right: 4, bottom: 4 })
                    })
                  }
                  .margin({ top: 8 })
                }
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .margin({ bottom: 6 })
            })
          }

          // Action buttons
          Row() {
            Button('重新分析')
              .fontSize(14)
              .height(40)
              .layoutWeight(1)
              .onClick(async () => {
                if (this.selectedFile && this.apiConnected && this.apiService) {
                  this.isProcessing = true;
                  try {
                    await this.apiService.analyzeFile(this.selectedFile.path);
                    await this.loadFiles();
                    const updated = this.fileViewModel.files.find(f => f.id === this.selectedFile!.id);
                    if (updated) {
                      this.selectedFile = updated;
                      await this.selectFile(updated);
                    }
                  } catch (e) { console.error('Re-analyze failed:', e); }
                  this.isProcessing = false;
                }
              })
          }
          .width('100%')
          .margin({ top: 16 })
        } else {
          Column() {
            Text('请选择一个文件查看详情')
              .fontSize(16)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .padding(100)
        }
      }
      .padding(16)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  // ----------- Preview Content Area Builder -----------
  @Builder
  PreviewContentArea() {
    Column() {
      Text('内容预览')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 8, bottom: 8 })

      if (this.selectedFile && this.isImageFile(this.selectedFile.type) && this.imagePixelMap) {
        // Image preview
        Column() {
          Image(this.imagePixelMap)
            .width('100%')
            .objectFit(ImageFit.Contain)
            .borderRadius(8)
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .padding(8)
      } else if (this.selectedFile && this.selectedFile.type.toLowerCase() === '.pdf') {
        // PDF preview with pagination
        Column() {
          if (this.pdfPixelMap) {
            // PDF page image
            Image(this.pdfPixelMap)
              .width('100%')
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
          } else {
            // PDF loading or error
            Column() {
              Text(this.previewContent || 'PDF加载中...')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
          }

          // Page navigation controls
          if (this.pdfPageCount > 0) {
            Row() {
              Button('上一页')
                .fontSize(12)
                .height(32)
                .enabled(this.previewPageNumber > 1)
                .onClick(() => { this.prevPage(); })

              Text(`${this.previewPageNumber} / ${this.pdfPageCount}`)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 16, right: 16 })

              Button('下一页')
                .fontSize(12)
                .height(32)
                .enabled(this.previewPageNumber < this.pdfPageCount)
                .onClick(() => { this.nextPage(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 12 })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .padding(8)
      } else if (this.selectedFile && this.isMarkdownFile(this.selectedFile.type) && this.markdownFileContentBase64) {
        // Markdown file preview - use Web component
        Column() {
          Text(this.previewContent || 'Markdown文档')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Start)
            .width('100%')

          if (this.markdownPreviewError) {
            Text(this.markdownPreviewError)
              .fontSize(13)
              .fontColor('#F44336')
              .margin({ top: 8 })
          }

          // Web component for Markdown preview
          Web({ src: $rawfile('markdown_preview.html'), controller: this.markdownWebController })
            .width('100%')
            .height(400)
            .backgroundColor(Color.White)
            .borderRadius(8)
            .margin({ top: 12 })
            .onPageEnd(() => {
              console.info('[Index] Markdown Web page loaded, ready to send content');
              this.markdownWebReady = true;
              // Send file content after Web is ready
              if (this.markdownFileContentBase64) {
                setTimeout(() => {
                  this.sendMarkdownFileToWeb();
                }, 100);
              }
            })
            .javaScriptAccess(true)
            .domStorageAccess(true)

          // Button to open with system app
          Button('用系统应用打开')
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.primary'))
            .borderRadius(8)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .margin({ top: 16 })
            .onClick(() => {
              if (this.selectedFile) {
                this.openDocumentWithSystem(this.selectedFile);
              }
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .padding(16)
      } else if (this.selectedFile && this.isTextFile(this.selectedFile.type) && this.previewTextContent) {
        // Text file preview
        Column() {
          Text(this.previewTextContent)
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .padding(16)
        .height(300)
      } else if (this.selectedFile && this.isOfficeFile(this.selectedFile.type)) {
        // Office file preview - use Web for PPTX, others show info
        Column() {
          Text(this.previewContent || 'Office文档')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Start)
            .width('100%')

          if (this.officePreviewError) {
            Text(this.officePreviewError)
              .fontSize(13)
              .fontColor('#F44336')
              .margin({ top: 8 })
          }

          // Web component for PPTX preview
          if (this.selectedFile.type.toLowerCase() === '.pptx' && this.officeFileContentBase64) {
            Web({ src: $rawfile('office_preview.html'), controller: this.webController })
              .width('100%')
              .height(400)
              .backgroundColor(Color.White)
              .borderRadius(8)
              .margin({ top: 12 })
              .onPageEnd(() => {
                console.info('[Index] Web page loaded, ready to send content');
                this.officeWebReady = true;
                // Send file content after Web is ready
                if (this.officeFileContentBase64) {
                  setTimeout(() => {
                    this.sendOfficeFileToWeb();
                  }, 100);
                }
              })
              .javaScriptAccess(true)
              .domStorageAccess(true)
          }

          // Button to open with system app (fallback or for non-PPTX)
          Button('用系统应用打开')
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.primary'))
            .borderRadius(8)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .margin({ top: 16 })
            .onClick(() => {
              if (this.selectedFile) {
                this.openDocumentWithSystem(this.selectedFile);
              }
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .padding(16)
      } else {
        // Fallback info
        Column() {
          Text(this.previewContent || '无法预览此文件类型')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(150)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  private isImageFile(type: string): boolean {
    const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.tif', '.livp', '.ico', '.svg'];
    return imageExts.includes(type.toLowerCase());
  }

  // ----------- Categories Tab -----------
  @Builder
  CategoriesTab() {
    Scroll() {
      Column() {
        // Category summary
        Row() {
          Text(`共 ${this.fileViewModel.files.length} 个文件, ${this.categories.length} 个分类`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .margin({ bottom: 12 })

        // Category cards
        ForEach(this.categories, (cat: CategoryInfo) => {
          Column() {
            Row() {
              // Color indicator
              Column() {
                Text(cat.count.toString())
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
              }
              .width(60)
              .height(60)
              .borderRadius(12)
              .backgroundColor(cat.color)
              .justifyContent(FlexAlign.Center)

              Column() {
                Text(cat.name)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))

                Text(`${cat.count} 个文件`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 4 })
              }
              .margin({ left: 12 })
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('>')
                .fontSize(20)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
            .padding(12)
            .onClick(() => {
              // Show files in this category
              this.searchFilter = 'all';
              this.currentTab = 3;
              this.searchQuery = cat.name;
              this.searchResults = this.classificationResults[cat.name] || [];
            })

            // Show files in category (first 3)
            if ((this.classificationResults[cat.name] || []).length > 0) {
              Column() {
                ForEach((this.classificationResults[cat.name] || []).slice(0, 3), (f: FileItem) => {
                  Row() {
                    Text(this.getFileIcon(f.type))
                      .fontSize(16)
                    Text(decodeFileName(f.name))
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ left: 8 })
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(`${(f.confidence * 100).toFixed(0)}%`)
                      .fontSize(12)
                      .fontColor(f.confidence >= 0.8 ? '#4CAF50' : '#FF9800')
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
                })
                if ((this.classificationResults[cat.name] || []).length > 3) {
                  Text(`还有 ${(this.classificationResults[cat.name] || []).length - 3} 个文件...`)
                    .fontSize(12)
                    .fontColor($r('app.color.primary'))
                    .margin({ top: 4 })
                }
              }
              .width('100%')
              .padding({ left: 12, right: 12, bottom: 8 })
            }
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
          .margin({ bottom: 8 })
        })
      }
      .padding(16)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  // ----------- Search Tab -----------
  @Builder
  SearchTab() {
    Column() {
      // Search input
      Row() {
        TextInput({ text: this.searchQuery, placeholder: '搜索文件名、分类或语义内容...' })
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor('#F5F5F5')
          .onChange((v: string) => { this.searchQuery = v; })
          .onSubmit(() => { this.doSearch(); })

        Button('搜索')
          .height(44)
          .margin({ left: 8 })
          .onClick(() => { this.doSearch(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      // Results
      if (this.searchResults.length > 0) {
        Text(`找到 ${this.searchResults.length} 个结果`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 16, top: 8 })

        List() {
          ForEach(this.searchResults, (file: FileItem) => {
            ListItem() {
              this.FileItemBuilder(file);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
      } else if (this.searchQuery) {
        Column() {
          Text('未找到匹配文件')
            .fontSize(14)
            .fontColor($r('app.color.text_hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Text('输入关键词搜索文件')
            .fontSize(14)
            .fontColor($r('app.color.text_hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ----------- Quick Settings -----------
  @Builder
  SettingsQuickView() {
    Scroll() {
      Column() {
        // 运行模式设置
        this.SettingsSectionHeader('运行模式')

        Column() {
          Row() {
            Column() {
              Text('连接后端服务器')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('启用后将连接电脑端服务器进行文件分析')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.useServer })
              .onChange((isOn: boolean) => {
                this.useServer = isOn;
                this.saveAllSettings();
                if (!isOn) {
                  this.connectionStatus = '本地模式';
                  this.testSuccess = false;
                  this.apiConnected = false;
                  this.apiStatusText = '本地模式';
                } else {
                  this.connectionStatus = '未测试';
                }
              })
          }
          .width('100%')

          Row() {
            Text(this.useServer ? '🌐 服务器模式 - 需要电脑端运行服务器' : '📱 本地模式 - 所有功能在手机本地运行')
              .fontSize(13)
              .fontColor(this.useServer ? '#2196F3' : '#4CAF50')
              .margin({ top: 12 })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)

        // API Server Settings (仅当启用服务器连接时显示)
        if (this.useServer) {
          this.SettingsSectionHeader('服务器配置')

          Column() {
            Text('服务器地址')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 8 })

            TextInput({ text: this.apiService ? this.apiService.getBaseUrl() : 'http://127.0.0.1:8765', placeholder: 'http://IP:PORT' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .onChange((value: string) => {
                // Save new URL
                if (this.context) {
                  preferences.getPreferences(this.context, 'app_settings').then(pref => {
                    pref.put('api_url', value);
                    pref.flush();
                    this.apiService = new ApiService(value);
                  });
                }
              })

            Text('请输入电脑的局域网IP地址，如 http://192.168.1.100:8765')
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 8 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)

          Row() {
            Text('连接状态:')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))

            Text(this.connectionStatus)
              .fontSize(14)
              .fontColor(this.testSuccess ? '#4CAF50' : '#F44336')
              .margin({ left: 8 })
              .layoutWeight(1)

            Button('测试连接')
              .height(36)
              .fontSize(14)
              .enabled(!this.isTestingConnection)
              .onClick(() => {
                this.testApiConnection();
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
          .margin({ top: 8 })
        }

        // 解析模式设置（与Python一致）
        this.SettingsSectionHeader('解析模式设置')

        Column() {
          Row() {
            Column() {
              Text('解析模式')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('1=轻量解析(快速), 2=深度解析(完整)')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            Column() {
              Text('轻量解析')
                .fontSize(14)
                .fontWeight(this.parseMode === 1 ? FontWeight.Bold : FontWeight.Normal)
              Text('快速处理，截断长文本')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.parseMode === 1 ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.parseMode === 1 ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.parseMode = 1;
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            Column() {
              Text('深度解析')
                .fontSize(14)
                .fontWeight(this.parseMode === 2 ? FontWeight.Bold : FontWeight.Normal)
              Text('完整处理，保留全部内容')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.parseMode === 2 ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.parseMode === 2 ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.parseMode = 2;
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.parseMode === 1) {
            Row() {
              Column() {
                Text('轻量解析最大长度')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                Text('默认256，与Python一致')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              TextInput({ text: this.lightModeMaxLength.toString(), placeholder: '256' })
                .width(100)
                .height(36)
                .borderRadius(6)
                .onChange((value: string) => {
                  const parsed = parseInt(value) || 256;
                  this.lightModeMaxLength = parsed > 0 ? parsed : 256;
                  this.saveAllSettings();
                })
            }
            .width('100%')
            .margin({ top: 12 })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 语义表征设置（与Python一致）
        this.SettingsSectionHeader('语义表征设置')

        Column() {
          Row() {
            Column() {
              Text('文本描述最大长度')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('生成语义描述的最大长度（Python默认512）')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            TextInput({ text: this.descriptionMaxLength.toString(), placeholder: '512' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .margin({ top: 12 })
              .onChange((value: string) => {
                const parsed = parseInt(value) || 512;
                this.descriptionMaxLength = parsed > 0 ? parsed : 512;
                this.saveAllSettings();
              })
          }
          .width('100%')

          Text('默认值512，与Python description.max_length一致')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 嵌入模型设置
        this.SettingsSectionHeader('嵌入模型设置')

        Column() {
          Row() {
            Column() {
              Text('最大文本长度')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('嵌入模型处理文本的最大长度，超过将截断')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            TextInput({ text: this.embeddingMaxTextLength.toString(), placeholder: '128' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .margin({ top: 12 })
              .onChange((value: string) => {
                const parsed = parseInt(value) || 128;
                this.embeddingMaxTextLength = parsed > 0 ? parsed : 128;
                this.saveAllSettings();
              })
          }
          .width('100%')

          Text('默认值128，较大的值可能增加处理时间但保留更多语义信息')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8 })

          // 嵌入方法选择
          Row() {
            Column() {
              Text('向量化方法')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('选择文本向量化的实现方式')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            Column() {
              Text('MindSpore')
                .fontSize(14)
                .fontWeight(this.embeddingMethod === 'mindspore' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.embeddingMethod === 'mindspore' ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Row() {
                Text('端侧模型推理')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                if (this.isOfflineMode) {
                  Circle({ width: 6, height: 6 })
                    .fill('#4CAF50')
                    .margin({ left: 4 })
                  Text('可用')
                    .fontSize(10)
                    .fontColor('#4CAF50')
                }
              }
              .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.embeddingMethod === 'mindspore' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.embeddingMethod === 'mindspore' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.embeddingMethod = 'mindspore';
              if (this.semanticRep) {
                this.semanticRep.setEmbeddingMethod('mindspore');
              }
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            Column() {
              Text('原生API')
                .fontSize(14)
                .fontWeight(this.embeddingMethod === 'native' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.embeddingMethod === 'native' ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Text('AIP嵌入接口')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.embeddingMethod === 'native' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.embeddingMethod === 'native' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.embeddingMethod = 'native';
              if (this.semanticRep) {
                this.semanticRep.setEmbeddingMethod('native');
              }
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            Column() {
              Text('本地哈希')
                .fontSize(14)
                .fontWeight(this.embeddingMethod === 'local' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.embeddingMethod === 'local' ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Text('快速但精度低')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.embeddingMethod === 'local' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.embeddingMethod === 'local' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.embeddingMethod = 'local';
              if (this.semanticRep) {
                this.semanticRep.setEmbeddingMethod('local');
              }
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            Column() {
              Text('后端API')
                .fontSize(14)
                .fontWeight(this.embeddingMethod === 'api' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.embeddingMethod === 'api' ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Row() {
                Text('需服务端支持')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                if (this.useServer && this.connectionStatus === '连接正常') {
                  Circle({ width: 6, height: 6 })
                    .fill('#4CAF50')
                    .margin({ left: 4 })
                  Text('已连接')
                    .fontSize(10)
                    .fontColor('#4CAF50')
                }
              }
              .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.embeddingMethod === 'api' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.embeddingMethod === 'api' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.embeddingMethod = 'api';
              if (this.semanticRep) {
                this.semanticRep.setEmbeddingMethod('api');
              }
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.embeddingMethod === 'native') {
            Text('原生API：使用HarmonyOS NEXT的AIP嵌入接口（API 15+，仅2in1设备）')
              .fontSize(12)
              .fontColor('#4CAF50')
              .margin({ top: 8 })
          } else if (this.embeddingMethod === 'mindspore') {
            Text('MindSpore：使用端侧模型进行向量推理')
              .fontSize(12)
              .fontColor('#4CAF50')
              .margin({ top: 8 })
          } else if (this.embeddingMethod === 'local') {
            Text('本地哈希：基于文本特征的快速哈希向量化，精度较低')
              .fontSize(12)
              .fontColor('#FF9800')
              .margin({ top: 8 })
          } else {
            Text('后端API：需要后端服务提供向量化接口')
              .fontSize(12)
              .fontColor('#2196F3')
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // Caption模式设置
        this.SettingsSectionHeader('Caption生成模式')

        Column() {
          Row() {
            Column() {
              Text('图片描述生成方式')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('选择本地端侧模型或云端LLM API')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            Column() {
              Text('端侧模型')
                .fontSize(14)
                .fontWeight(this.captionMode === CaptionMode.LOCAL ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.captionMode === CaptionMode.LOCAL ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Text('llama.cpp + Qwen3.5')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.captionMode === CaptionMode.LOCAL ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.captionMode === CaptionMode.LOCAL ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.captionMode = CaptionMode.LOCAL;
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            Column() {
              Text('云端LLM')
                .fontSize(14)
                .fontWeight(this.captionMode === CaptionMode.CLOUD ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.captionMode === CaptionMode.CLOUD ? $r('app.color.primary') : $r('app.color.text_secondary'))
              Text('需配置API密钥')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.captionMode === CaptionMode.CLOUD ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.captionMode === CaptionMode.CLOUD ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.captionMode = CaptionMode.CLOUD;
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.captionMode === CaptionMode.LOCAL) {
            Text('端侧模式：使用llama.cpp运行Qwen3.5 0.8B多模态模型，无需联网')
              .fontSize(12)
              .fontColor('#4CAF50')
              .margin({ top: 8 })
          } else {
            Text('云端模式：需要配置下方LLM API密钥')
              .fontSize(12)
              .fontColor('#2196F3')
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 图片缩放设置（与AItest项目MAX_SIZE=512一致）
        this.SettingsSectionHeader('图片处理设置')

        Column() {
          Row() {
            Column() {
              Text('图片缩放最大尺寸')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('Caption生成前缩放图片，与AItest项目MAX_SIZE一致')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            TextInput({ text: this.maxDimension.toString(), placeholder: '512' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .margin({ top: 12 })
              .onChange((value: string) => {
                const parsed = parseInt(value) || 512;
                this.maxDimension = parsed > 0 ? parsed : 512;
                // 更新服务设置
                if (this.imageAnalysisService) {
                  this.imageAnalysisService.setMaxDimension(this.maxDimension);
                }
                this.saveAllSettings();
              })
          }
          .width('100%')

          Text('默认值512，推荐值: 256(快速), 512(平衡), 768(高质量)')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8 })

          Text('图片将保持长宽比缩放到不超过此尺寸')
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 图片文字提取设置（两个独立配置）
        this.SettingsSectionHeader('图片文字提取设置')

        Column() {
          // 原始图片文件配置
          Row() {
            Column() {
              Text('原始图片文件')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('jpg/png/gif等图片文件的文字提取方式')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            // OCR选项
            Column() {
              Text('OCR')
                .fontSize(14)
                .fontWeight(this.imageFileTextMethod === 'ocr' ? FontWeight.Bold : FontWeight.Normal)
              Text('识别图片中文字')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.imageFileTextMethod === 'ocr' ? '#E3F2FD' : '#F5F5F5')
            .onClick(() => {
              this.imageFileTextMethod = 'ocr';
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            // Caption选项（默认）
            Column() {
              Text('Caption')
                .fontSize(14)
                .fontWeight(this.imageFileTextMethod === 'caption' ? FontWeight.Bold : FontWeight.Normal)
              Text('LLM生成描述')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.imageFileTextMethod === 'caption' ? '#E3F2FD' : '#F5F5F5')
            .onClick(() => {
              this.imageFileTextMethod = 'caption';
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          // 解析得到的图片配置
          Row() {
            Column() {
              Text('解析得到的图片')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('PDF/PPT/Word中提取的图片')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 16 })

          Row() {
            // OCR选项（默认推荐）
            Column() {
              Text('OCR')
                .fontSize(14)
                .fontWeight(this.parsedImageTextMethod === 'ocr' ? FontWeight.Bold : FontWeight.Normal)
              Text('识别图片中文字（推荐）')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.parsedImageTextMethod === 'ocr' ? '#E3F2FD' : '#F5F5F5')
            .onClick(() => {
              this.parsedImageTextMethod = 'ocr';
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            // Caption选项
            Column() {
              Text('Caption')
                .fontSize(14)
                .fontWeight(this.parsedImageTextMethod === 'caption' ? FontWeight.Bold : FontWeight.Normal)
              Text('LLM生成描述')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.parsedImageTextMethod === 'caption' ? '#E3F2FD' : '#F5F5F5')
            .onClick(() => {
              this.parsedImageTextMethod = 'caption';
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          Text('注：解析得到的图片通常是文档截图或内嵌图片，OCR能更好提取文字内容')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 分类方法设置（与Python一致）
        this.SettingsSectionHeader('分类方法设置')

        Column() {
          Row() {
            Column() {
              Text('分类方法')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('语义分类算法，与Python config.json中的classification.method一致')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            // 相似度分类（默认推荐）
            Column() {
              Text('相似度分类')
                .fontSize(14)
                .fontWeight(this.classificationMethod === 'similarity' ? FontWeight.Bold : FontWeight.Normal)
              Text('向量+BM25+关键词融合')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.classificationMethod === 'similarity' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.classificationMethod === 'similarity' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.classificationMethod = 'similarity';
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            // 聚类分类
            Column() {
              Text('聚类分类')
                .fontSize(14)
                .fontWeight(this.classificationMethod === 'cluster' ? FontWeight.Bold : FontWeight.Normal)
              Text('向量聚类匹配')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.classificationMethod === 'cluster' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.classificationMethod === 'cluster' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.classificationMethod = 'cluster';
              this.saveAllSettings();
            })
            .margin({ right: 8 })

            // LLM分类
            Column() {
              Text('LLM分类')
                .fontSize(14)
                .fontWeight(this.classificationMethod === 'llm' ? FontWeight.Bold : FontWeight.Normal)
              Text('LLM模型分类')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.classificationMethod === 'llm' ? '#E3F2FD' : '#F5F5F5')
            .borderWidth(this.classificationMethod === 'llm' ? 2 : 0)
            .borderColor($r('app.color.primary'))
            .onClick(() => {
              this.classificationMethod = 'llm';
              this.saveAllSettings();
            })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.classificationMethod === 'similarity') {
            Text('相似度分类：融合向量相似度(35%)、BM25(25%)、关键词(25%)、时间(8%)、地点(7%)')
              .fontSize(12)
              .fontColor('#4CAF50')
              .margin({ top: 8 })
          } else if (this.classificationMethod === 'cluster') {
            Text('聚类分类：使用语义向量聚类，基于预定义类别中心向量')
              .fontSize(12)
              .fontColor('#2196F3')
              .margin({ top: 8 })
          } else {
            Text('LLM分类：使用端侧或云端LLM进行分类，需要加载模型或配置API')
              .fontSize(12)
              .fontColor('#FF9800')
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // LLM配置
        this.SettingsSectionHeader('LLM配置 (图片Caption)')

        Column() {
          Text('LLM提供商')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 8 })

          Row() {
            ForEach(['openai', 'deepseek', 'qwen', 'custom'], (provider: string) => {
              Text(provider === 'custom' ? '自定义' : provider.toUpperCase())
                .fontSize(12)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(4)
                .backgroundColor(this.llmProvider === provider ? $r('app.color.primary') : '#E0E0E0')
                .fontColor(this.llmProvider === provider ? Color.White : '#666666')
                .margin({ right: 4 })
                .onClick(() => {
                  this.llmProvider = provider;
                  if (provider === 'openai') {
                    this.llmEndpoint = 'https://api.openai.com/v1/chat/completions';
                    this.llmModel = 'gpt-4o';
                    this.llmMaxTokens = 4096;
                    this.llmTemperature = 0.7;
                  } else if (provider === 'deepseek') {
                    this.llmEndpoint = 'https://api.deepseek.com/v1/chat/completions';
                    this.llmModel = 'deepseek-chat';
                    this.llmMaxTokens = 4096;
                    this.llmTemperature = 0.7;
                  } else if (provider === 'qwen') {
                    this.llmEndpoint = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
                    this.llmModel = 'qwen3-vl-32b-thinking';
                    this.llmMaxTokens = 32768;
                    this.llmTemperature = 0.7;
                  }
                  this.saveAllSettings();
                })
            })
          }
          .width('100%')
          .margin({ bottom: 12 })

          Text('API密钥')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 4 })

          Row() {
            TextInput({ text: this.llmApiKey, placeholder: 'sk-...' })
              .layoutWeight(1)
              .height(44)
              .borderRadius(8)
              .type(this.showApiKey ? InputType.Normal : InputType.Password)
              .onChange((value: string) => {
                this.llmApiKey = value;
                this.saveAllSettings();
              })

            Text(this.showApiKey ? '👁' : '👁‍🗨')
              .fontSize(20)
              .padding(8)
              .onClick(() => {
                this.showApiKey = !this.showApiKey;
              })
          }
          .width('100%')

          if (this.llmProvider === 'custom') {
            Text('API端点')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 12, bottom: 4 })

            TextInput({ text: this.llmEndpoint, placeholder: 'https://api.example.com/v1/chat/completions' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .onChange((value: string) => {
                this.llmEndpoint = value;
                this.saveAllSettings();
              })

            Text('模型名称')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 12, bottom: 4 })

            TextInput({ text: this.llmModel, placeholder: 'gpt-4o' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .onChange((value: string) => {
                this.llmModel = value;
                this.saveAllSettings();
              })
          }

          Text('高级参数')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 12, bottom: 4 })

          Row() {
            Column() {
              Text('超时(秒)')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
              TextInput({ text: this.llmTimeout.toString(), placeholder: '60' })
                .width('100%')
                .height(36)
                .borderRadius(6)
                .margin({ top: 4 })
                .onChange((value: string) => {
                  this.llmTimeout = parseInt(value) || 60;
                  this.saveAllSettings();
                })
            }
            .width('30%')

            Column() {
              Text('最大Token')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
              TextInput({ text: this.llmMaxTokens.toString(), placeholder: '4096' })
                .width('100%')
                .height(36)
                .borderRadius(6)
                .margin({ top: 4 })
                .onChange((value: string) => {
                  this.llmMaxTokens = parseInt(value) || 4096;
                  this.saveAllSettings();
                })
            }
            .width('35%')
            .margin({ left: 8 })

            Column() {
              Text('Temperature')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
              TextInput({ text: this.llmTemperature.toString(), placeholder: '0.7' })
                .width('100%')
                .height(36)
                .borderRadius(6)
                .margin({ top: 4 })
                .onChange((value: string) => {
                  this.llmTemperature = parseFloat(value) || 0.7;
                  this.saveAllSettings();
                })
            }
            .width('35%')
            .margin({ left: 8 })
          }
          .width('100%')

          Text('配置API密钥后，可使用图片Caption生成功能')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 调试模式
        this.SettingsSectionHeader('调试模式')

        Column() {
          Row() {
            Column() {
              Text('启用调试模式')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('开启后将实时同步数据库到PC端')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.debugMode })
              .onChange((isOn: boolean) => {
                this.debugMode = isOn;
                this.saveAllSettings();
                if (!isOn) {
                  this.syncStatus = '未同步';
                }
              })
          }
          .width('100%')

          if (this.debugMode) {
            Text('调试服务器地址')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 12 })

            TextInput({ text: this.debugServerUrl, placeholder: 'http://127.0.0.1:8765' })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .margin({ top: 4 })
              .onChange((value: string) => {
                this.debugServerUrl = value;
                this.saveAllSettings();
              })

            Text('需要在PC端启动调试服务器接收数据')
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 4 })

            Row() {
              Text('同步状态:')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))

              Text(this.syncStatus)
                .fontSize(14)
                .fontColor(this.syncStatus.includes('成功') ? '#4CAF50' : '#F44336')
                .margin({ left: 8 })
                .layoutWeight(1)

              Button('立即同步')
                .height(36)
                .fontSize(14)
                .onClick(() => {
                  this.syncDatabase();
                })
            }
            .width('100%')
            .margin({ top: 12 })

            Text('数据库路径:')
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 8 })

            Text('/data/app/el2/100/database/com.example.fileanalyzer_hos/rdb/FileAnalyzer.db')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 统计信息
        this.SettingsSectionHeader('统计信息')

        Column() {
          Row() {
            this.StatItem('总文件', `${this.fileViewModel.files.length}`)
            this.StatItem('分类数', `${this.categories.length}`)
          }
          Row() {
            this.StatItem('已分析', `${this.fileViewModel.files.filter(f => f.status !== FileStatus.PENDING).length}`)
            this.StatItem('待处理', `${this.fileViewModel.files.filter(f => f.status === FileStatus.PENDING).length}`)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 使用说明
        this.SettingsSectionHeader('使用说明')

        Column() {
          if (this.useServer) {
            this.SettingsHelpItem('服务器模式说明:')
            this.SettingsHelpItem('1. 在电脑上启动后端服务: python api_server.py')
            this.SettingsHelpItem('2. 查看电脑IP: ipconfig (Windows)')
            this.SettingsHelpItem('3. 在上方输入 http://电脑IP:8765')
            this.SettingsHelpItem('4. 点击测试连接确认可用')
            this.SettingsHelpItem('5. 手机需与电脑在同一局域网')
          } else {
            this.SettingsHelpItem('本地模式说明:')
            this.SettingsHelpItem('• 所有文件分析功能在手机本地运行')
            this.SettingsHelpItem('• 图片、文本、PDF等文件可直接预览')
            this.SettingsHelpItem('• 无需电脑端服务器')
            this.SettingsHelpItem('• 语义分析使用本地编码器')
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 功能说明
        this.SettingsSectionHeader('本地功能支持')

        Column() {
          this.SettingsFeatureItem('📄 PDF预览', '支持PDF文档浏览和翻页', true)
          this.SettingsFeatureItem('🖼 图片预览', '支持常见图片格式显示', true)
          this.SettingsFeatureItem('📝 文本预览', '支持txt、json、md等文本文件', true)
          this.SettingsFeatureItem('📊 Office文档', '显示文档基本信息', true)
          this.SettingsFeatureItem('🔍 文件扫描', '扫描并管理手机文件', true)
          this.SettingsFeatureItem('🧠 本地语义分析', '使用MindSpore进行本地分析', true)
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 数据存储信息
        this.SettingsSectionHeader('数据存储')

        Column() {
          Text('数据库文件')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('/data/app/el2/100/database/com.example.fileanalyzer_hos/rdb/FileAnalyzer.db')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 4 })

          Text('数据表')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ top: 12 })

          Text('files - 文件记录\ndata_blocks - 数据块\nsemantic_blocks - 语义块\nclassification_results - 分类结果\nsemantic_categories - 语义类别\nuser_queries - 查询记录')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 4 })

          Text('缓存目录')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ top: 12 })

          Text('/data/storage/el2/base/cache/')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })

        // 数据库管理
        this.SettingsSectionHeader('数据库管理')

        Column() {
          Text('重置数据库')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('删除旧数据库文件并重新创建。适用于表结构变更后数据库不兼容的情况。')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 8 })

          Text('⚠️ 注意：此操作将清除所有数据')
            .fontSize(12)
            .fontColor('#F44336')
            .width('100%')
            .margin({ top: 8 })

          Button('重置数据库')
            .width('100%')
            .height(44)
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor('#F44336')
            .borderRadius(8)
            .margin({ top: 16 })
            .onClick(() => {
              this.showResetDbDialog = true;
            })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ top: 8 })
      }
      .padding(16)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  SettingsSectionHeader(title: string) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .margin({ top: 16, bottom: 8 })
  }

  @Builder
  SettingsHelpItem(text: string) {
    Row() {
      Text(text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  SettingsFeatureItem(title: string, desc: string, supported: boolean) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(supported ? '✓' : '✗')
        .fontSize(14)
        .fontColor(supported ? '#4CAF50' : '#F44336')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })

    Text(desc)
      .fontSize(12)
      .fontColor($r('app.color.text_hint'))
      .width('100%')
      .margin({ bottom: 8 })
  }

  @Builder
  StatItem(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .padding(12)
    .alignItems(HorizontalAlign.Center)
  }

  // ----------- Bottom Tabs -----------
  @Builder
  BottomTabs() {
    Row() {
      this.TabButton('📄', '文件', 0)
      this.TabButton('👁', '预览', 1)
      this.TabButton('📊', '分类', 2)
      this.TabButton('🔍', '搜索', 3)
      this.TabButton('⚙', '设置', 4)
    }
    .width('100%')
    .height(56)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 2, color: '#10000000', offsetY: -1 })
  }

  @Builder
  TabButton(icon: string, label: string, index: number) {
    Column() {
      Text(icon)
        .fontSize(22)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.currentTab = index; })
  }

  // ----------- Loading View -----------
  @Builder
  LoadingView() {
    Column() {
      LoadingProgress().width(48).height(48).color($r('app.color.primary'))
      Text('正在加载...')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}