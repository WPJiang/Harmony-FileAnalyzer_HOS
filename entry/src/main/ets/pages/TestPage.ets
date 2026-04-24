/**
 * TestPage - 集成测试页面
 *
 * 用于运行功能一致性测试，验证HarmonyOS版本与Python版本的功能对比
 */

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { TestResult, TestReport } from '../testing/Index';
import { IntegrationTest } from '../testing/IntegrationTest';
import { ApiService } from '../services/Index';

@Entry
@Component
struct TestPage {
  @State isRunning: boolean = false;
  @State currentTest: string = '';
  @State testResults: TestResult[] = [];
  @State totalPassed: number = 0;
  @State totalFailed: number = 0;
  @State totalTime: number = 0;
  @State showDetails: boolean = false;
  @State selectedTest: TestResult | null = null;
  @State apiConnected: boolean = false;
  @State apiStatusText: string = '未连接';

  private context: common.Context | null = null;
  private integrationTest: IntegrationTest | null = null;
  private apiService: ApiService | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.Context;
    this.initializeTest();
  }

  private async initializeTest(): Promise<void> {
    this.integrationTest = new IntegrationTest(this.context!);
    await this.integrationTest.initialize();

    // Create API service with localhost (port forwarding should be set up)
    this.apiService = new ApiService('http://127.0.0.1:8765');
    this.integrationTest.setApiService(this.apiService);

    // Check connection
    await this.checkApiConnection();
  }

  private async checkApiConnection(): Promise<void> {
    if (!this.apiService) {
      this.apiConnected = false;
      this.apiStatusText = '未配置';
      return;
    }

    this.apiStatusText = '连接中...';
    try {
      const health = await this.apiService.checkHealth();
      this.apiConnected = health.status === 'ok';
      this.apiStatusText = this.apiConnected ? '已连接' : '服务异常';
    } catch (err) {
      this.apiConnected = false;
      this.apiStatusText = '连接失败';
      console.error('[TestPage] API connection failed:', err);
    }
  }

  setApiService(apiService: ApiService): void {
    this.apiService = apiService;
    if (this.integrationTest) {
      this.integrationTest.setApiService(apiService);
    }
  }

  /**
   * 运行所有测试
   */
  private async runAllTests(): Promise<void> {
    if (!this.integrationTest) return;

    this.isRunning = true;
    this.currentTest = '运行所有测试...';
    this.testResults = [];

    try {
      const report = await this.integrationTest.runAllTests();
      this.testResults = report.results;
      this.totalPassed = report.passed;
      this.totalFailed = report.failed;
      this.totalTime = report.totalTime;
    } catch (err) {
      console.error('[TestPage] Test failed:', err);
    }

    this.isRunning = false;
    this.currentTest = '';
  }

  /**
   * 运行Python对比测试
   */
  private async runPythonComparisonTests(): Promise<void> {
    if (!this.integrationTest) return;

    this.isRunning = true;
    this.currentTest = '运行Python对比测试...';

    try {
      const report = await this.integrationTest.runPythonComparisonTests();
      // Add to existing results
      for (const result of report.results) {
        this.testResults.push(result);
      }
      this.totalPassed += report.passed;
      this.totalFailed += report.failed;
      this.totalTime += report.totalTime;
    } catch (err) {
      console.error('[TestPage] Python comparison failed:', err);
    }

    this.isRunning = false;
    this.currentTest = '';
  }

  /**
   * 清除测试数据
   */
  private async clearTestData(): Promise<void> {
    if (!this.integrationTest) return;
    await this.integrationTest.cleanup();
    this.testResults = [];
    this.totalPassed = 0;
    this.totalFailed = 0;
    this.totalTime = 0;
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('←')
          .fontSize(24)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { router.back(); })

        Text('功能一致性测试')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.surface'))

      // API Status
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(this.apiConnected ? '#4CAF50' : '#9E9E9E')
        Text(this.apiStatusText)
          .fontSize(12)
          .fontColor(this.apiConnected ? '#4CAF50' : '#9E9E9E')
          .margin({ left: 4 })
        Text('重新连接')
          .fontSize(12)
          .fontColor('#2196F3')
          .margin({ left: 16 })
          .onClick(() => { this.checkApiConnection(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.surface'))

      // Summary
      Column() {
        Row() {
          Text(`通过: ${this.totalPassed}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#4CAF50')

          Text(`失败: ${this.totalFailed}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F44336')
            .margin({ left: 16 })

          Text(`耗时: ${this.totalTime}ms`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 16 })
        }
        .width('100%')
        .margin({ bottom: 8 })

        // Progress bar
        if (this.testResults.length > 0) {
          Row() {
            Row()
              .width(`${(this.totalPassed / this.testResults.length) * 100}%`)
              .height(8)
              .backgroundColor('#4CAF50')
              .borderRadius(4)

            Row()
              .width(`${(this.totalFailed / this.testResults.length) * 100}%`)
              .height(8)
              .backgroundColor('#F44336')
              .borderRadius(4)
          }
          .width('100%')
          .height(8)
          .backgroundColor('#E0E0E0')
          .borderRadius(4)
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.surface'))

      // Current test indicator
      if (this.isRunning) {
        Row() {
          LoadingProgress().width(20).height(20).color($r('app.color.primary'))
          Text(this.currentTest)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .margin({ left: 8 })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#E3F2FD')
      }

      // Test buttons
      Row() {
        Button('运行所有测试')
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .enabled(!this.isRunning)
          .onClick(() => { this.runAllTests(); })

        Button('Python对比测试')
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(!this.isRunning)
          .onClick(() => { this.runPythonComparisonTests(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      Row() {
        Button('清除测试数据')
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#F44336')
          .enabled(!this.isRunning)
          .onClick(() => { this.clearTestData(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      // Test results list
      List() {
        ForEach(this.testResults, (result: TestResult) => {
          ListItem() {
            this.TestResultItem(result);
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  TestResultItem(result: TestResult) {
    Column() {
      Row() {
        // Status icon
        Text(result.passed ? '✓' : '✗')
          .fontSize(18)
          .fontColor(result.passed ? '#4CAF50' : '#F44336')
          .width(32)

        Column() {
          Text(result.testName)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Text(result.message)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(`${result.duration}ms`)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(8)
      .onClick(() => {
        this.selectedTest = result;
        this.showDetails = true;
      })

      // Details (if expanded)
      if (this.selectedTest === result && this.showDetails) {
        Column() {
          if (result.expectedValue) {
            Row() {
              Text('期望值:')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(result.expectedValue)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 8 })
            }
            .margin({ top: 8 })
          }

          if (result.actualValue) {
            Row() {
              Text('实际值:')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(result.actualValue)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 8 })
            }
            .margin({ top: 4 })
          }
        }
        .width('100%')
        .padding({ left: 44, right: 12, bottom: 8 })
      }
    }
    .margin({ bottom: 6 })
  }
}