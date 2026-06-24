import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import {
  createEmptyStressTestStats,
  StressTestManager,
  StressTestStats
} from '../utils/StressTestManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "StressTestAPage";

/**
 * Stress Test Page A
 */
@Entry
@Component
export struct StressTestAPage {
  @State elapsedSeconds: number = 0;
  @State remainingSeconds: number = -1;
  @State stats: StressTestStats = createEmptyStressTestStats();
  private updateTimerId: number | null = null;
  private autoNavigateTimerId: number | null = null;
  private stressTestManager: StressTestManager = StressTestManager.getInstance();
  private enteredStressRun: boolean = false;

  aboutToAppear() {
    DemoLogger.i(TAG, "StressTestAPage initialized");
    this.refreshNavigationStats();
    this.startUpdateTimer();
    this.startAutoNavigate();
  }

  aboutToDisappear() {
    this.stopUpdateTimer();
    this.stopAutoNavigate();
  }

  private startUpdateTimer(): void {
    this.updateTimerId = setInterval((): void => {
      const snapshot = this.refreshNavigationStats();
      if (!snapshot.isRunning) {
        // If stress test stopped, stop auto navigation and return to RealAppStressTestPage
        if (this.enteredStressRun || this.autoNavigateTimerId !== null) {
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
    // Only auto navigate if stress test is running and navigation scenario is enabled
    if (!this.stressTestManager.isNavigationScenarioEnabled()) {
      DemoLogger.i(TAG, "Stress navigation scenario disabled, skipping auto navigation");
      return;
    }
    const navigationIntervalMs = this.stressTestManager.getNavigationIntervalMs();
    // Auto navigate to StressTestBPage after delay
    this.autoNavigateTimerId = setTimeout((): void => {
      // Check again before navigating (stress test might have stopped)
      if (this.stressTestManager.isNavigationScenarioEnabled()) {
        DemoLogger.i(TAG, "Auto navigating to StressTestBPage");
        this.navigateToPageB();
      } else {
        DemoLogger.i(TAG, "Stress test stopped before auto navigation, returning to RealAppStressTestPage");
        this.navigateBack();
      }
    }, navigationIntervalMs);
  }

  private stopAutoNavigate(): void {
    if (this.autoNavigateTimerId !== null) {
      clearTimeout(this.autoNavigateTimerId);
      this.autoNavigateTimerId = null;
    }
  }

  private refreshNavigationStats(): StressTestStats {
    const snapshot = this.stressTestManager.getStatsSnapshot();
    this.stats = snapshot;
    this.elapsedSeconds = snapshot.elapsedSeconds;
    this.remainingSeconds = snapshot.remainingSeconds;
    if (snapshot.isRunning && snapshot.enableNavigation) {
      this.enteredStressRun = true;
    }
    return snapshot;
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

  navigateToPageB(): void {
    // Check if stress test is still running before navigating
    if (!this.stressTestManager.isStressTestRunning()) {
      DemoLogger.i(TAG, "Stress test stopped, returning to RealAppStressTestPage instead of navigating to StressTestBPage");
      this.navigateBack();
      return;
    }
    try {
      this.stressTestManager.recordNavigationSwitch();
      // Use replaceUrl to replace current page instead of pushing to stack
      // This prevents page stack overflow when repeatedly navigating between pages
      router.replaceUrl({ url: 'pages/StressTestBPage' });
      DemoLogger.i(TAG, "Navigated to StressTestBPage (replaced)");
    } catch (error) {
      DemoLogger.e(TAG, `Failed to navigate to StressTestBPage: ${error}`);
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
      router.replaceUrl({ url: 'pages/RealAppStressTestPage' });
      DemoLogger.i(TAG, "Navigated to RealAppStressTestPage (replaced)");
    } catch (error) {
      DemoLogger.e(TAG, `Failed to navigate to RealAppStressTestPage: ${error}`);
      promptAction.showToast({
        message: `Navigation failed: ${error}`,
        duration: 2000
      });
    }
  }

  build() {
    Column({ space: 20 }) {
      TestPageHeader({
        title: 'Stress Test Page A',
        onBack: () => this.navigateBack()
      })

      // Content
      Column({ space: 20 }) {
        Text('This is Stress Test Page A')
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

              Column({ space: 5 }) {
                Text('Switches')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Text(`${this.stats.navigationSwitches}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#4CAF50')
              }
            }
            .margin({ top: 10 })
            .justifyContent(FlexAlign.SpaceEvenly)
            .width('100%')

            Text(`Traffic: ${this.stats.trafficMode} | Source: ${this.stats.source}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
              .textAlign(TextAlign.Center)

            Text(`Navigation interval: ${this.stats.navigationIntervalMs}ms`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
              .textAlign(TextAlign.Center)

            Text(`Logs: ${this.stats.logsGenerated} (${this.stats.logBatchesGenerated} batches)`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
              .textAlign(TextAlign.Center)

            Text(`Actions: ${this.stats.actionsGenerated} | Resources: ${this.stats.resourcesGenerated} / OK ${this.stats.resourcesSucceeded} / Fail ${this.stats.resourcesFailed}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
              .textAlign(TextAlign.Center)

            Text(`Errors: ${this.stats.errorsGenerated} | LongTasks: ${this.stats.longTasksGenerated}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(10)
          .margin({ top: 20, bottom: 20 })
        }

        Button('Go to Page B')
          .onClick(() => this.navigateToPageB())
          .width('80%')
          .height(60)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#4CAF50')
          .fontColor(Color.White)
          .margin({ top: 40 })
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
