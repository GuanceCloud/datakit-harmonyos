import { Context, common } from '@kit.AbilityKit';
import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import { StressTestManager } from '../utils/StressTestManager';
import preferences from '@ohos.data.preferences';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "RealAppStressTestPage";
const PREFERENCES_NAME = 'real_app_stress_test_settings';
const KEY_TEST_MINUTES = 'test_minutes';
const KEY_TEST_SECONDS = 'test_seconds';

/**
 * Real App Stress Test Page
 * Simulates real user behavior patterns for stress testing
 */
@Entry
@Component
export struct RealAppStressTestPage {
  @State abilityContext: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  @State testDuration: number = 60; // Duration in seconds (default 1 minute)
  @State testMinutes: number = 1; // Test duration in minutes (default 1 minute)
  @State testSeconds: number = 0; // Test duration in seconds (default 0 seconds)
  @State isTestRunning: boolean = false;
  @State elapsedSeconds: number = 0;
  
  private stressTestManager: StressTestManager = StressTestManager.getInstance();
  private updateTimer: number | null = null;
  private preferencesStore: preferences.Preferences | null = null;

  async aboutToAppear() {
    DemoLogger.i(TAG, "RealAppStressTestPage initialized");
    // Load saved settings
    await this.loadTimeSettings();
    // Check if stress test is already running
    this.isTestRunning = this.stressTestManager.isStressTestRunning();
    if (this.isTestRunning) {
      // Update elapsed seconds immediately to get current value
      this.elapsedSeconds = this.stressTestManager.getElapsedSeconds();
      DemoLogger.i(TAG, `Resuming stress test monitoring: elapsed=${this.elapsedSeconds}s, duration=${this.testDuration}s`);
      
      // Check if test should have already stopped (but StressTestManager's setTimeout hasn't fired yet)
      // Don't stop here - let StressTestManager's setTimeout handle it to avoid race conditions
      if (this.elapsedSeconds >= this.testDuration) {
        DemoLogger.w(TAG, `Test duration (${this.testDuration}s) already exceeded (elapsed: ${this.elapsedSeconds}s), but StressTestManager is still running. Waiting for StressTestManager's auto-stop...`);
      }
      
      this.startUpdateTimer();
    }
  }

  async aboutToDisappear() {
    this.stopUpdateTimer();
    // Save current settings
    await this.saveTimeSettings();
  }

  /**
   * Start update timer to refresh elapsed seconds
   * Note: Auto-stop is handled by StressTestManager's setTimeout, not here
   * This timer only updates the UI display
   */
  private startUpdateTimer(): void {
    this.stopUpdateTimer();
    this.updateTimer = setInterval((): void => {
      // Check if StressTestManager is still running (it might have been stopped by its own setTimeout)
      if (!this.stressTestManager.isStressTestRunning()) {
        DemoLogger.i(TAG, "StressTestManager stopped (auto-stop or manual stop), stopping update timer");
        this.isTestRunning = false;
        this.stopUpdateTimer();
        // Show completion message if it was auto-stop
        const finalElapsed = this.stressTestManager.getElapsedSeconds();
        if (finalElapsed > 0) {
          promptAction.showToast({
            message: `Test completed (${finalElapsed}s)`,
            duration: 3000
          });
        }
        return;
      }
      
      // Only update elapsed seconds for UI display
      // StressTestManager handles the actual auto-stop via setTimeout
      this.elapsedSeconds = this.stressTestManager.getElapsedSeconds();
    }, 1000); // Update every second
  }

  /**
   * Stop update timer
   */
  private stopUpdateTimer(): void {
    if (this.updateTimer !== null) {
      clearInterval(this.updateTimer);
      this.updateTimer = null;
    }
  }

  /**
   * Start stress test by running StressTestManager
   */
  startStressTest(): void {
    if (this.isTestRunning) {
      promptAction.showToast({
        message: "Test is already running",
        duration: 2000
      });
      return;
    }

    try {
      // Ensure testDuration is up to date
      this.updateTestDuration();
      DemoLogger.i(TAG, `Starting stress test with StressTestManager (duration: ${this.testDuration}s = ${this.testMinutes} minutes ${this.testSeconds} seconds, useRealData: false)`);
      // Pass test duration to StressTestManager for auto-stop, use fake data by default
      this.stressTestManager.run(this.testDuration, false);
      this.isTestRunning = true;
      this.elapsedSeconds = 0;
      this.startUpdateTimer();
      
      DemoLogger.i(TAG, `Stress test started successfully (duration: ${this.testDuration}s = ${this.testMinutes} minutes ${this.testSeconds} seconds)`);
      promptAction.showToast({
        message: `Stress test started (${this.testDuration}s)`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, `Failed to start stress test: ${error}`);
      promptAction.showToast({
        message: `Failed to start: ${error}`,
        duration: 3000
      });
      this.isTestRunning = false;
    }
  }

  /**
   * Stop stress test by stopping StressTestManager
   */
  stopStressTest(): void {
    if (!this.isTestRunning) {
      promptAction.showToast({
        message: "Test is not running",
        duration: 2000
      });
      return;
    }

    try {
      DemoLogger.i(TAG, "Stopping stress test");
      this.stressTestManager.stop();
      this.isTestRunning = false;
      this.stopUpdateTimer();
      const finalSeconds = this.elapsedSeconds;
      this.elapsedSeconds = 0;
      
      DemoLogger.i(TAG, `Stress test stopped successfully. Total runtime: ${finalSeconds} seconds`);
      promptAction.showToast({
        message: `Stress test stopped (ran for ${finalSeconds}s)`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, `Failed to stop stress test: ${error}`);
      promptAction.showToast({
        message: `Failed to stop: ${error}`,
        duration: 3000
      });
      // Reset state even if stop failed
      this.isTestRunning = false;
      this.stopUpdateTimer();
    }
  }

  /**
   * Load time settings from preferences
   */
  private async loadTimeSettings(): Promise<void> {
    try {
      this.preferencesStore = await preferences.getPreferences(this.abilityContext, PREFERENCES_NAME);
      if (this.preferencesStore) {
        const savedMinutes = await this.preferencesStore.get(KEY_TEST_MINUTES, 1) as number;
        const savedSeconds = await this.preferencesStore.get(KEY_TEST_SECONDS, 0) as number;
        
        // Validate loaded values
        if (savedMinutes >= 0 && savedMinutes <= 30 && savedSeconds >= 0 && savedSeconds < 60) {
          this.testMinutes = savedMinutes;
          this.testSeconds = savedSeconds;
          this.updateTestDuration();
          DemoLogger.i(TAG, `Loaded time settings: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        } else {
          DemoLogger.w(TAG, `Invalid saved time settings, using defaults: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        }
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to load time settings: ${error}`);
    }
  }

  /**
   * Save current time settings to preferences
   */
  private async saveTimeSettings(): Promise<void> {
    try {
      if (!this.preferencesStore) {
        this.preferencesStore = await preferences.getPreferences(this.abilityContext, PREFERENCES_NAME);
      }
      if (this.preferencesStore) {
        await this.preferencesStore.put(KEY_TEST_MINUTES, this.testMinutes);
        await this.preferencesStore.put(KEY_TEST_SECONDS, this.testSeconds);
        await this.preferencesStore.flush();
        DemoLogger.i(TAG, `Saved time settings: ${this.testMinutes} minutes, ${this.testSeconds} seconds`);
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to save time settings: ${error}`);
    }
  }

  /**
   * Update test duration from minutes and seconds
   */
  updateTestDuration(): void {
    const newDuration = this.testMinutes * 60 + this.testSeconds;
    if (newDuration !== this.testDuration) {
      DemoLogger.i(TAG, `Test duration updated: ${this.testDuration}s -> ${newDuration}s (${this.testMinutes} minutes ${this.testSeconds} seconds)`);
      this.testDuration = newDuration;
    }
  }

  /**
   * Adjust test minutes
   */
  adjustMinutes(delta: number): void {
    const newMinutes = this.testMinutes + delta;
    if (newMinutes >= 0 && newMinutes <= 30) { // 0 to 30 minutes
      this.testMinutes = newMinutes;
      this.updateTestDuration();
      // Save immediately after change
      this.saveTimeSettings();
    }
  }

  /**
   * Adjust test seconds
   */
  adjustSeconds(delta: number): void {
    const newSeconds = this.testSeconds + delta;
    if (newSeconds >= 0 && newSeconds < 60) {
      this.testSeconds = newSeconds;
      this.updateTestDuration();
      // Save immediately after change
      this.saveTimeSettings();
    } else if (newSeconds >= 60 && this.testMinutes < 30) {
      // If seconds >= 60, convert to minutes
      this.testMinutes += 1;
      this.testSeconds = newSeconds - 60;
      this.updateTestDuration();
      // Save immediately after change
      this.saveTimeSettings();
    } else if (newSeconds < 0 && this.testMinutes > 0) {
      // If seconds < 0, borrow from minutes
      this.testMinutes -= 1;
      this.testSeconds = 60 + newSeconds;
      this.updateTestDuration();
      // Save immediately after change
      this.saveTimeSettings();
    }
  }

  /**
   * Format elapsed time as minutes and seconds
   */
  formatElapsedTime(seconds: number): string {
    if (seconds <= 0) {
      return "0s";
    }
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;
    
    if (minutes > 0 && remainingSeconds > 0) {
      return `${minutes} min ${remainingSeconds} s`;
    } else if (minutes > 0) {
      return `${minutes} min`;
    } else {
      return `${remainingSeconds} s`;
    }
  }

  build() {
    Column() {
      TestPageHeader({
        title: 'Real App Stress Test'
      })

      // Scrollable content
      Scroll() {
        Column({ space: 20 }) {
          // Test duration control
      Column({ space: 10 }) {
        Text('Test Duration')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 10 })

        // Minutes control
        Column({ space: 5 }) {
          Text('Minutes')
            .fontSize(14)
            .fontColor(Color.Gray)
          Row({ space: 20 }) {
            Button('-')
              .onClick(() => this.adjustMinutes(-1))
              .width(60)
              .height(50)
              .enabled(!this.isTestRunning && this.testMinutes > 0)

            Text(`${this.testMinutes}`)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .width(80)
              .textAlign(TextAlign.Center)

            Button('+')
              .onClick(() => this.adjustMinutes(1))
              .width(60)
              .height(50)
              .enabled(!this.isTestRunning && this.testMinutes < 30)
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
        }
        .width('100%')

        // Seconds control
        Column({ space: 5 }) {
          Text('Seconds')
            .fontSize(14)
            .fontColor(Color.Gray)
          Row({ space: 20 }) {
            Button('-')
              .onClick(() => this.adjustSeconds(-1))
              .width(60)
              .height(50)
              .enabled(!this.isTestRunning && (this.testSeconds > 0 || this.testMinutes > 0))

            Text(`${this.testSeconds}`)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .width(80)
              .textAlign(TextAlign.Center)

            Button('+')
              .onClick(() => this.adjustSeconds(1))
              .width(60)
              .height(50)
              .enabled(!this.isTestRunning && (this.testSeconds < 59 || this.testMinutes < 30))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
        }
        .width('100%')
        .margin({ top: 10 })

        // Total duration display
        Text(`Total: ${this.formatElapsedTime(this.testDuration)}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#007DFF')
          .margin({ top: 10 })
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#F5F5F5')
      .borderRadius(10)
      .margin({ bottom: 20 })

      // Start/Stop test buttons
      if (this.isTestRunning) {
        // Stop test button (shown when test is running)
        Button('Stop Stress Test')
          .onClick(() => this.stopStressTest())
          .width('100%')
          .height(60)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#FF5252')
          .fontColor(Color.White)
          .margin({ top: 20 })

        // Status text with elapsed time (minutes and seconds)
        Text(`Test running: ${this.formatElapsedTime(this.elapsedSeconds)}`)
          .fontSize(14)
          .fontColor(Color.Gray)
          .margin({ top: 20 })
          .textAlign(TextAlign.Center)
      } else {
        // Start test button (shown when test is not running)
        Button('Start Stress Test')
          .onClick(() => this.startStressTest())
          .width('100%')
          .height(60)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#4CAF50')
          .fontColor(Color.White)
          .margin({ top: 20 })
      }

          // Navigation to StressTestAPage
          Button('Go to Stress Test Page A')
            .onClick(async () => {
              try {
                // Ensure time settings are saved before navigation
                await this.saveTimeSettings();
                router.pushUrl({ url: 'pages/StressTestAPage' });
                DemoLogger.i(TAG, "Navigated to StressTestAPage");
              } catch (error) {
                DemoLogger.e(TAG, `Failed to navigate to StressTestAPage: ${error}`);
                promptAction.showToast({
                  message: `Navigation failed: ${error}`,
                  duration: 2000
                });
              }
            })
            .width('100%')
            .height(60)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#007DFF')
            .fontColor(Color.White)
            .margin({ top: 20, bottom: 20 })

        }
        .width('100%')
        .padding(20)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .scrollBarColor(Color.Gray)
      .scrollBarWidth(4)
      .edgeEffect(EdgeEffect.Spring)

    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
