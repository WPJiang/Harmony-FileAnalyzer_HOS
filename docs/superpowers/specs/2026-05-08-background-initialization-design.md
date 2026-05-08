---
name: 后台初始化优化设计
description: 将应用启动时的阻塞初始化改为后台异步处理，实现立即显示主UI
type: project
---

# 后台初始化优化设计

## 问题背景

当前应用启动时显示"正在加载"状态约10秒，阻塞用户进入主UI界面。主要阻塞点：

1. **MindSpore模型加载** - 从rawfile复制30MB模型文件，初始化Worker线程
2. **SemanticRepresentation初始化** - OCR服务、分词器、嵌入服务
3. **DatabaseManager初始化** - 数据库连接
4. **本地Caption模型预加载** - LOCAL模式下额外加载
5. **loadFiles()** - 从数据库加载所有文件记录

**影响：** 用户启动应用后需要等待10秒才能看到主界面，体验不佳。

## 目标

- 应用启动后立即显示主UI界面
- 后台异步初始化所有服务
- UI显示初始化进度状态
- 用户可以立即浏览界面，部分功能在初始化完成前显示"加载中"

## 设计方案

### 架构变更

**原流程：**
```
aboutToAppear() -> initializeServices() [阻塞等待] -> UI显示
```

**新流程：**
```
aboutToAppear() -> initializeServicesAsync() [后台执行] -> 立即显示UI
                    ↓
                 状态更新 -> UI显示进度
                    ↓
                 初始化完成 -> 功能就绪
```

### 状态管理

新增状态变量：

```typescript
@State isInitializing: boolean = false;      // 是否正在后台初始化
@State initProgress: string = '';            // 当前初始化步骤描述
@State initPercent: number = 0;              // 初始化进度百分比
@State servicesReady: boolean = false;       // 核心服务是否全部就绪
```

移除阻塞等待：
```typescript
// 移除 isLoading 在初始化时的使用
// isLoading 仅用于文件扫描、处理等操作
```

### 分阶段初始化策略

| 阶段 | 服务 | 优先级 | 预估时间 | UI状态 |
|------|------|--------|----------|--------|
| 1 | DatabaseManager + CacheUtils | 高 | 1-2秒 | 显示"初始化数据库" |
| 2 | loadFiles() | 高 | 1秒 | 显示"加载文件列表" |
| 3 | SemanticRepresentation + EmbeddingService | 中 | 3-8秒 | 显示"加载语义模型" |
| 4 | ImageAnalysisService | 低 | 1-2秒 | 显示"初始化图片分析" |
| 5 | OfficeConversionService | 低 | <1秒 | 显示"初始化转换服务" |

**策略说明：**
- 阶段1、2完成后，用户可以浏览文件列表
- 阶段3完成后，用户可以进行语义搜索和分类
- 阶段4完成后，用户可以进行图片分析
- MindSpore模型已在Worker线程加载，不阻塞主线程

### 代码修改

#### 1. aboutToAppear 修改

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

#### 2. 新增 initializeServicesAsync

```typescript
private async initializeServicesAsync(): Promise<void> {
  try {
    // === 阶段1：数据库（优先，约20%进度） ===
    this.initProgress = '正在初始化数据库...';
    this.initPercent = 10;

    // 加载保存的设置（同步，快速）
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
    await this.semanticRep.initialize();  // 这里包含EmbeddingService初始化

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

    // 设置到semanticRep
    this.semanticRep.setImageAnalysisService(this.imageAnalysisService);

    // LOCAL模式下预加载模型（可选，不阻塞）
    if (this.captionMode === CaptionMode.LOCAL) {
      this.initProgress = '正在加载本地Caption模型...';
      const loaded = await this.imageAnalysisService.loadLocalCaptionModel();
      console.info('[Index] Local caption model loaded:', loaded);
    }
    this.initPercent = 80;

    // === 阶段5：其他服务（约90%进度） ===
    this.initProgress = '正在初始化转换服务...';
    this.officeConversionService = new OfficeConversionService();
    this.initPercent = 90;

    // === API连接（如果启用） ===
    if (this.useServer) {
      this.initProgress = '正在连接服务器...';
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

#### 3. 提取设置加载方法

```typescript
private savedApiUrl: string = 'http://127.0.0.1:8765';

private async loadSavedSettings(): Promise<void> {
  try {
    const pref = await preferences.getPreferences(this.context!, 'app_settings');
    // 加载所有设置到状态变量
    this.savedApiUrl = pref.getSync('api_url', '') as string || 'http://127.0.0.1:8765';
    this.useServer = pref.getSync('use_server', false) as boolean;
    // ... 其他设置加载代码保持不变
  } catch (e) {
    console.warn('[Index] Load settings failed:', e);
  }
}
```

#### 4. UI状态显示

在主UI底部添加初始化状态栏：

```typescript
// 在 build() 方法中，Tabs 组件下方添加
if (this.isInitializing) {
  Row() {
    Progress({ value: this.initPercent, total: 100, type: ProgressType.Linear })
      .width('60%')
    Text(this.initProgress)
      .fontSize(12)
      .margin({ left: 8 })
  }
  .width('100%')
  .height(24)
  .backgroundColor('#F0F0F0')
  .padding({ left: 16, right: 16 })
}
```

### 功能可用性检查

在需要依赖初始化服务的操作中添加检查：

```typescript
// 示例：文件扫描
private async scanFiles(): Promise<void> {
  if (!this.servicesReady) {
    // 显示提示或等待初始化完成
    this.scanProgress = '等待服务初始化完成...';
    return;
  }
  // 正常扫描逻辑
}

// 示例：语义搜索
private async semanticSearch(): Promise<void> {
  if (!this.semanticRep || !this.servicesReady) {
    // 使用简单文本搜索作为降级方案
    await this.simpleTextSearch();
    return;
  }
  // 正常语义搜索逻辑
}
```

### MindSpore Worker 注意事项

MindSpore模型加载已在Worker线程执行，不会阻塞主线程。关键代码在 `EmbeddingService.ets` 的 `MindSporeEmbeddingService.initialize()`：

```typescript
// Worker初始化是异步的，不阻塞主线程
const initPromise = new Promise<boolean>((resolve) => {
  this.initResolve = resolve;
  this.initWorkerAsync();  // 在setTimeout中启动
});
```

因此，EmbeddingService.initialize() 可以在后台任务中调用，不会阻塞UI渲染。

## 实施计划

1. **修改 aboutToAppear()** - 移除阻塞等待
2. **重构 initializeServicesAsync()** - 分阶段后台执行
3. **添加初始化状态UI** - 底部进度条
4. **添加功能可用性检查** - 降级处理
5. **测试验证** - 启动时间、功能完整性

## 验收标准

- 启动后立即显示主UI（<1秒）
- 状态栏显示初始化进度
- 文件列表在3秒内显示
- 语义搜索在模型加载完成后可用
- 无功能丢失或降级