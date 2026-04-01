import { RateLimitTestUtils } from '../utils/RateLimitTestUtils';
import router from '@ohos.router';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'RateLimitTestPage';

/**
 * Test case interface for session keep test
 */
interface TestCase {
  normal: number;
  error: number;
}

@Entry
@Component
export struct RateLimitTestPage {
  @State testResults: string = '';
  @State isRunning: boolean = false;
  private hasAutoRunStarted: boolean = false;

  aboutToAppear() {
    DemoLogger.i(TAG, 'Rate limit test page loaded');
    const params = router.getParams() as Record<string, string> | undefined;
    if (params?.mode === 'comprehensive' && !this.hasAutoRunStarted) {
      this.hasAutoRunStarted = true;
      this.runComprehensiveTest();
    }
  }

  build() {
    Column({ space: 20 }) {
      TestPageHeader({
        title: 'Rate Limiting Test Page'
      })

      Text('Test HarmonyOS SDK Rate Limiting Mechanisms')
        .fontSize(16)
        .fontColor(Color.Gray)
        .margin({ bottom: 20 })

      // Sampling rate test button
      Button('Test Sampling Rate Control')
        .width('90%')
        .height(50)
        .backgroundColor('#007DFF')
        .onClick(() => {
          this.runSamplingRateTest();
        })

      // Session keep test button
      Button('Test Session Keep')
        .width('90%')
        .height(50)
        .backgroundColor('#007DFF')
        .onClick(() => {
          this.runSessionKeepTest();
        })

      // Comprehensive test button
      Button('Run Comprehensive Test')
        .width('90%')
        .height(50)
        .backgroundColor('#FF6B35')
        .onClick(() => {
          this.runComprehensiveTest();
        })

      // Clear results button
      Button('Clear Results')
        .width('90%')
        .height(40)
        .backgroundColor('#FF4757')
        .onClick(() => {
          this.testResults = '';
        })

      // Test results display area
      Scroll() {
        Text(this.testResults)
          .fontSize(14)
          .fontFamily('monospace')
          .textAlign(TextAlign.Start)
          .width('100%')
          .padding(10)
      }
      .width('90%')
      .height(300)
      .border({ width: 1, color: Color.Gray })
      .borderRadius(8)
      .margin({ top: 20 })

      // Running status indicator
      if (this.isRunning) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
          Text('Test Running...')
            .fontSize(14)
            .margin({ left: 10 })
        }
        .justifyContent(FlexAlign.Center)
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  /**
   * Run sampling rate test
   */
  private async runSamplingRateTest() {
    this.isRunning = true;
    this.appendResult('=== Starting Sampling Rate Test ===\n');

    try {
      const testUtils = RateLimitTestUtils.getInstance();
      
      // Test different sampling rates
      const testRates: number[] = [0.1, 0.5, 0.8, 1.0];
      
      for (const rate of testRates) {
        this.appendResult(`\nTesting Sampling Rate: ${rate}\n`);
        const result = testUtils.testSamplingRateAccuracy(rate, 1000);
        this.appendResult(`Actual Rate: ${result.actualRate.toFixed(3)}\n`);
        this.appendResult(`Expected Rate: ${result.expectedRate.toFixed(3)}\n`);
        this.appendResult(`Deviation: ${result.deviation.toFixed(3)}\n`);
        this.appendResult(`Test Result: ${result.passed ? 'PASSED' : 'FAILED'}\n`);
        this.appendResult(`Details: ${result.details}\n`);
      }
      
      this.appendResult('\n=== Sampling Rate Test Completed ===\n');
    } catch (error) {
      this.appendResult(`Sampling Rate Test Failed: ${this.formatError(error)}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Run session keep test
   */
  private async runSessionKeepTest() {
    this.isRunning = true;
    this.appendResult('=== Starting Session Keep Test ===\n');

    try {
      const testUtils = RateLimitTestUtils.getInstance();
      
      // Test different sampling rate combinations
      const testCases: TestCase[] = [
        { normal: 0.5, error: 0.8 },
        { normal: 0.3, error: 0.6 },
        { normal: 0.8, error: 0.9 }
      ];
      
      for (const testCase of testCases) {
        this.appendResult(`\nTest Combination: Normal=${testCase.normal}, Error=${testCase.error}\n`);
        const result = testUtils.testSessionKeep(testCase.normal, testCase.error, 100);
        this.appendResult(`Session Collect: ${result.sessionCollectCount}/${100} (${result.sessionCollectRate.toFixed(3)})\n`);
        this.appendResult(`Error Collect: ${result.sessionErrorCollectCount}/${100} (${result.sessionErrorCollectRate.toFixed(3)})\n`);
        this.appendResult(`Details: ${result.details}\n`);
      }
      
      this.appendResult('\n=== Session Keep Test Completed ===\n');
    } catch (error) {
      this.appendResult(`Session Keep Test Failed: ${this.formatError(error)}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Run comprehensive test
   */
  private async runComprehensiveTest() {
    this.isRunning = true;
    this.appendResult('=== Starting Comprehensive Test ===\n');
    this.appendResult(`Test Time: ${new Date().toLocaleString()}\n\n`);

    try {
      // Run all rate limiting tests on this page
      await this.runSamplingRateTest();
      await this.runSessionKeepTest();
      
      this.appendResult('\n=== Comprehensive Test Completed ===\n');
      this.appendResult(`Completion Time: ${new Date().toLocaleString()}\n`);
    } catch (error) {
      this.appendResult(`Comprehensive Test Failed: ${this.formatError(error)}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Add test result
   */
  private appendResult(text: string) {
    this.testResults += text;
  }

  private formatError(error: Object): string {
    return `${error}`;
  }
}
