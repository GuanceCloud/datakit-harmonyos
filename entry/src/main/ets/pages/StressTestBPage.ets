import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import { StressTestManager } from '../utils/StressTestManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "StressTestBPage";

/**
 * Stress Test Page B
 */
@Entry
@Component
export struct StressTestBPage {
  @State elapsedSeconds: number = 0;
  @State remainingSeconds: number = -1;
  private updateTimerId: number | null = null;
  private autoNavigateTimerId: number | null = null;
  private stressTestManager: StressTestManager = StressTestManager.getInstance();
  private static readonly AUTO_NAVIGATE_DELAY: number = 1000; // 1 second delay before auto navigation

  aboutToAppear() {
    DemoLogger.i(TAG, "StressTestBPage initialized");
    this.startUpdateTimer();
    this.startAutoNavigate();
  }

  aboutToDisappear() {
    this.stopUpdateTimer();
    this.stopAutoNavigate();
  }

  private startUpdateTimer(): void {
    this.updateTimerId = setInterval((): void => {
      if (this.stressTestManager.isStressTestRunning()) {
        this.elapsedSeconds = this.stressTestManager.getElapsedSeconds();
        this.remainingSeconds = this.stressTestManager.getRemainingSeconds();
      } else {
        this.elapsedSeconds = 0;
        this.remainingSeconds = -1;
        // If stress test stopped, stop auto navigation and return to RealAppStressTestPage
        if (this.autoNavigateTimerId !== null) {
          DemoLogger.i(TAG, "Stress test stopped, stopping auto navigation and returning to RealAppStressTestPage");
          this.stopAutoNavigate();
          this.navigateBack();
        }
      }
    }, 1000); // Update every second
  }

  private stopUpdateTimer(): void {
    if (this.updateTimerId !== null) {
      clearInterval(this.updateTimerId);
      this.updateTimerId = null;
    }
  }

  private startAutoNavigate(): void {
    // Only auto navigate if stress test is running
    if (!this.stressTestManager.isStressTestRunning()) {
      DemoLogger.i(TAG, "Stress test not running, skipping auto navigation");
      return;
    }
    // Auto navigate to StressTestAPage after delay
    this.autoNavigateTimerId = setTimeout((): void => {
      // Check again before navigating (stress test might have stopped)
      if (this.stressTestManager.isStressTestRunning()) {
        DemoLogger.i(TAG, "Auto navigating to StressTestAPage");
        this.navigateToPageA();
      } else {
        DemoLogger.i(TAG, "Stress test stopped before auto navigation, returning to RealAppStressTestPage");
        this.navigateBack();
      }
    }, StressTestBPage.AUTO_NAVIGATE_DELAY);
  }

  private stopAutoNavigate(): void {
    if (this.autoNavigateTimerId !== null) {
      clearTimeout(this.autoNavigateTimerId);
      this.autoNavigateTimerId = null;
    }
  }

  private formatTime(seconds: number): string {
    if (seconds < 0) {
      return "∞";
    }
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    const secsStr = secs < 10 ? `0${secs}` : secs.toString();
    return `${mins}:${secsStr}`;
  }

  navigateToPageA(): void {
    // Check if stress test is still running before navigating
    if (!this.stressTestManager.isStressTestRunning()) {
      DemoLogger.i(TAG, "Stress test stopped, returning to RealAppStressTestPage instead of navigating to StressTestAPage");
      this.navigateBack();
      return;
    }
    try {
      // Use replaceUrl to replace current page instead of pushing to stack
      // This prevents page stack overflow when repeatedly navigating between pages
      router.replaceUrl({ url: 'pages/StressTestAPage' });
      DemoLogger.i(TAG, "Navigated to StressTestAPage (replaced)");
    } catch (error) {
      DemoLogger.e(TAG, `Failed to navigate to StressTestAPage: ${error}`);
      promptAction.showToast({
        message: `Navigation failed: ${error}`,
        duration: 2000
      });
    }
  }

  navigateBack(): void {
    // Stop auto navigation before navigating back
    this.stopAutoNavigate();
    DemoLogger.i(TAG, "Auto navigation stopped, navigating back to RealAppStressTestPage");
    try {
      router.pushUrl({ url: 'pages/RealAppStressTestPage' });
      DemoLogger.i(TAG, "Navigated to RealAppStressTestPage");
    } catch (error) {
      DemoLogger.e(TAG, `Failed to navigate to RealAppStressTestPage: ${error}`);
      promptAction.showToast({
        message: `Navigation failed: ${error}`,
        duration: 2000
      });
    }
  }

  triggerCrash(): void {
    DemoLogger.i(TAG, "Triggering crash...");
    promptAction.showToast({
      message: "Crash triggered - app will crash",
      duration: 1000
    });
    // Use setTimeout to throw exception asynchronously
    // This allows errorManager to catch it as an unhandled exception
    setTimeout((): void => {
      throw new Error('Intentional crash for stress testing');
    }, 100);
  }

  build() {
    Column({ space: 20 }) {
      TestPageHeader({
        title: 'Stress Test Page B',
        onBack: () => this.navigateBack()
      })

      // Content
      Column({ space: 20 }) {
        Text('This is Stress Test Page B')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 40 })

        // Stress test status
        if (this.stressTestManager.isStressTestRunning()) {
          Column({ space: 10 }) {
            Text('Stress Test Running')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#4CAF50')
              .margin({ top: 20 })

            Row({ space: 20 }) {
              Column({ space: 5 }) {
                Text('Elapsed')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Text(this.formatTime(this.elapsedSeconds))
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#007DFF')
              }

              Column({ space: 5 }) {
                Text('Remaining')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Text(this.remainingSeconds >= 0 ? this.formatTime(this.remainingSeconds) : '∞')
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.remainingSeconds > 10 ? '#FF9800' : '#FF5252')
              }
            }
            .margin({ top: 10 })
            .justifyContent(FlexAlign.SpaceEvenly)
            .width('100%')
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(10)
          .margin({ top: 20, bottom: 20 })
        }

        Button('Go to Page A')
          .onClick(() => this.navigateToPageA())
          .width('80%')
          .height(60)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#2196F3')
          .fontColor(Color.White)
          .margin({ top: 40 })

        Button('Crash')
          .onClick(() => this.triggerCrash())
          .width('80%')
          .height(60)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#FF5252')
          .fontColor(Color.White)
          .margin({ top: 20 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
