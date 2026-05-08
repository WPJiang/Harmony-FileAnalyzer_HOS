# 后台初始化优化实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将应用启动时的阻塞初始化改为后台异步处理，实现立即显示主UI界面

**Architecture:** 修改Index.ets的aboutToAppear()不再阻塞等待，改为后台执行initializeServicesAsync()。新增状态变量跟踪初始化进度，UI底部显示进度条。

**Tech Stack:** HarmonyOS ArkTS, @State装饰器, async/await

---

## 文件结构

| 文件 | 操作 | 说明 |
|------|------|------|
| `entry/src/main/ets/pages/Index.ets` | 修改 | 添加状态变量、重构初始化流程、修改UI布局 |

---

## Task 1: 添加初始化状态变量

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:162-180` (UI State区域)

- [ ] **Step 1: 在UI State区域添加初始化状态变量**

在 `@State isLoading: boolean = false;` 后添加以下代码：

```typescript
  // Initialization State (后台初始化进度)
  @State isInitializing: boolean = false;      // 是否正在后台初始化
  @State initProgress: string = '';            // 当前初始化步骤描述
  @State initPercent: number = 0;              // 初始化进度百分比
  @State servicesReady: boolean = false;       // 核心服务是否全部就绪
```

- [ ] **Step 2: 添加savedApiUrl变量**

在Services区域添加以下代码（用于存储加载的API URL）：

```typescript
  // Saved settings
  private savedApiUrl: string = 'http://127.0.0.1:8765';
```

---

## Task 2: 修改aboutToAppear方法

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:310-313`

- [ ] **Step 1: 修改aboutToAppear不再阻塞等待**

将原有的 `aboutToAppear()` 方法替换为：

```typescript
  aboutToAppear(): void {
    this.context = getContext(this) as common.Context;
    this.isInitializing = true;
    this.initProgress = '正在初始化...';
    this.initPercent = 0;
    // 不等待，立即返回让UI显示
    this.initializeServicesAsync();
  }
```

---

## Task 3: 提取loadSavedSettings方法

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:317-494` (initializeServices方法内)

- [ ] **Step 1: 在initializeServices方法前添加loadSavedSettings方法**

在 `// ============ Initialization ============` 注释后，`initializeServices` 方法前添加：

```typescript
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
```

---

## Task 4: 创建initializeServicesAsync方法

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:317-494` (替换原有的initializeServices)

- [ ] **Step 1: 将initializeServices替换为initializeServicesAsync**

将原有的 `private async initializeServices(): Promise<void>` 方法替换为以下内容：

```typescript
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
```

---

## Task 5: 修改build方法添加初始化状态栏

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:2525-2575` (build方法)

- [ ] **Step 1: 修改build方法显示主UI而非加载界面**

将原有的build方法中的条件判断部分替换。原代码：

```typescript
        if (this.isLoading) {
          this.LoadingView();
        } else {
          this.TitleBar();
          this.WorkflowBar();
          this.TabContent();
          this.BottomTabs();
        }
```

替换为：

```typescript
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
```

---

## Task 6: 添加功能可用性检查

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets` (多个功能方法)

- [ ] **Step 1: 在scanFiles方法开头添加检查**

找到 `scanFiles` 方法（文件扫描功能），在开头添加：

```typescript
    // 检查服务是否就绪
    if (!this.servicesReady || !this.dbManager) {
      this.scanProgress = '等待服务初始化完成...';
      return;
    }
```

- [ ] **Step 2: 在processSelectedFiles方法开头添加检查**

找到文件处理相关的方法，在开头添加类似的检查：

```typescript
    // 检查服务是否就绪
    if (!this.servicesReady) {
      this.processProgress = '等待服务初始化完成...';
      return;
    }
```

---

## Task 7: 编译验证

- [ ] **Step 1: 运行hvigor编译检查语法错误**

运行:
```bash
cd D:/jiangweipeng/Harmony/FileAnalyzer_HOS && hvigorw assembleHap --mode module -p product=default -p module=entry@default --analyze=normal --parallel --incremental
```

Expected: 编译成功，无语法错误

- [ ] **Step 2: 检查编译输出**

如果编译失败，根据错误信息修复代码问题。常见问题可能包括：
- 类型不匹配
- 缺少必要的import
- 方法签名错误

---

## Task 8: 提交更改

- [ ] **Step 1: 提交修改到git**

```bash
git add entry/src/main/ets/pages/Index.ets docs/superpowers/specs/2026-05-08-background-initialization-design.md docs/superpowers/plans/2026-05-08-background-initialization.md
git commit -m "feat: 后台初始化优化 - 立即显示主UI，后台加载服务

- 添加 isInitializing/initProgress/initPercent/servicesReady 状态变量
- 修改 aboutToAppear 不再阻塞等待初始化
- 新增 initializeServicesAsync 分阶段后台初始化
- 提取 loadSavedSettings 方法
- 修改 build() 显示主UI + 底部进度条
- 添加功能可用性检查

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## 验收清单

- [ ] 启动后立即显示主UI界面（无10秒阻塞）
- [ ] 底部显示初始化进度条和当前步骤
- [ ] 文件列表在约3秒内显示
- [ ] 语义搜索功能在初始化完成后可用
- [ ] 编译无错误