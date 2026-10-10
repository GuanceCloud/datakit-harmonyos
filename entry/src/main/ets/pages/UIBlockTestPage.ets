import { FTSDK, FTRUMGlobalManager } from '@guancecloud/ft_sdk/Index';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'UIBlockTestPage';

/**
 * UI Block Test Page
 * 
 * This page tests the UI Block detection functionality by simulating
 * different durations of main thread blocking operations.
 * 
 * Note: UI Block detection must be enabled in RUM config:
 *   FTRUMConfig.setEnableTrackAppUIBlock(true)
 *   or
 *   FTRUMConfig.setEnableTrackAppUIBlock(true, blockDurationMs)
 */
@Entry
@Component
export struct UIBlockTestPage {
  @State message: string = 'UI Block Test Page';
  @State isSDKInitialized: boolean = false;
  @State isUIBlockEnabled: boolean = false;
  @State blockDurationThreshold: number = 0;
  @State systemJankTestPolicyConfigured: boolean = false;
  @State testResults: string = 'Ready to test UI Block detection\n';
  @State isTesting: boolean = false;

  aboutToAppear() {
    this.checkSDKStatus();
    this.setupRUMContext();
  }

  /**
   * Check SDK initialization status
   */
  checkSDKStatus() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      this.isSDKInitialized = rumConfig !== null && rumConfig.getRumAppId().length > 0;

      // Check if UI Block detection is enabled
      if (rumConfig) {
        this.isUIBlockEnabled = rumConfig.isEnableTrackAppUIBlock();
        this.blockDurationThreshold = rumConfig.getBlockDurationMS();
      }
      this.testResults += `SDK Status: ${this.isSDKInitialized ? 'Initialized' : 'Not Initialized'}\n`;
      this.testResults += `UI Block Detection: ${this.isUIBlockEnabled ? 'Enabled' : 'Disabled'}\n`;
      if (this.isUIBlockEnabled && rumConfig) {
        const blockDuration = rumConfig.getBlockDurationMS();
        this.testResults += `Block Duration Threshold: ${blockDuration}ms\n`;
      }
      this.testResults += '\n';
      
      DemoLogger.i(TAG, `<FT-UI-BLOCK-TEST> SDK status: ${this.isSDKInitialized ? 'initialized' : 'not initialized'}`);
      DemoLogger.i(TAG, `<FT-UI-BLOCK-TEST> UI Block enabled: ${this.isUIBlockEnabled}`);
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to check SDK status:', error);
      this.isSDKInitialized = false;
    }
  }

  /**
   * Setup RUM context for testing
   */
  setupRUMContext() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      if (rumConfig !== null && rumConfig.getRumAppId().length > 0 && !rumConfig.isEnableTraceUserView()) {
        const rumGlobalManager = FTRUMGlobalManager.getInstance();
        // Automatic Router tracking owns this page when enabled. Starting a
        // manual View in aboutToAppear would create a second, very short View.
        rumGlobalManager.startView('UIBlockTestPage', {});
        DemoLogger.i(TAG, `<FT-UI-BLOCK-TEST> RUM view started: UIBlockTestPage`);
      }
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to setup RUM context:', error);
    }
  }

  /**
   * Simulate UI blocking by performing CPU-intensive work on main thread
   * @param durationMs Blocking duration in milliseconds
   * @param description Description of the blocking operation
   */
  private simulateUIBlock(durationMs: number, description: string): void {
    if (this.isTesting) {
      this.testResults += 'Previous test is still running, please wait...\n';
      return;
    }

    this.isTesting = true;
    this.runUIBlock(durationMs, description);
    this.isTesting = false;
  }

  /**
   * Runs a single synchronous main-thread block. The caller is responsible for
   * guarding concurrent tests so this method can also be reused by the
   * multi-block scenario.
   */
  private runUIBlock(durationMs: number, description: string): void {
    this.testResults += `\n[${this.getTimeString()}] Starting: ${description} (${durationMs}ms)\n`;
    
    const startTime = Date.now();
    
    // Perform CPU-intensive work on main thread to simulate blocking.
    // MAIN_THREAD_JANK is delivered asynchronously by the system after the
    // block ends.
    let iterations = 0;
    const targetTime = startTime + durationMs;
    
    // Use a busy loop to block the main thread
    while (Date.now() < targetTime) {
      // Perform some computation
      let sum = 0;
      for (let i = 0; i < 10000; i++) {
        sum += i;
      }
      iterations++;
    }
    
    const actualDuration = Date.now() - startTime;
    this.testResults += `[${this.getTimeString()}] Completed: ${description}\n`;
    this.testResults += `  Actual duration: ${actualDuration}ms, Iterations: ${iterations}\n`;
    this.testResults += `  Waiting for the system MAIN_THREAD_JANK callback...\n\n`;
    
    DemoLogger.i(TAG, `<FT-UI-BLOCK-TEST> Simulated UI block: ${description}, duration: ${actualDuration}ms`);
  }

  /**
   * Applies a low-threshold MAIN_THREAD_JANK policy to this demo process.
   *
   * This is deliberately a demo-only action. An SDK must not change the host
   * application's system-event policy because it changes the process-wide
   * sampling and report-rate behavior.
   */
  private async configureSystemJankTestPolicy(): Promise<boolean> {
    if (this.systemJankTestPolicyConfigured) {
      return true;
    }

    // `setEventConfig(MAIN_THREAD_JANK)` is the public ArkTS API that is
    // explicitly documented for this event. Use the documented stack-sampling
    // example values so the test does not depend on native-only V2 behavior.
    const params: Record<string, hiAppEvent.ParamType> = {
      'log_type': '1',
      'sample_interval': '100',
      'ignore_startup_time': '3',
      'sample_count': '21',
      'report_times_per_app': '3'
    };
    try {
      await hiAppEvent.setEventConfig(hiAppEvent.event.MAIN_THREAD_JANK, params);
      this.systemJankTestPolicyConfigured = true;
      this.testResults += 'System Jank V1 test policy configured: interval=100ms, sample-count=21, startup-ignore=3s, report-limit=3\n';
      DemoLogger.i(TAG, '<FT-UI-BLOCK-TEST> MAIN_THREAD_JANK V1 test policy configured');
      return true;
    } catch (error) {
      // API 22 offers a newer policy API. It is a compatibility fallback only:
      // the primary test path above remains the documented V1 event API.
      this.testResults += `MAIN_THREAD_JANK V1 config unavailable, trying API 22 policy: ${String(error)}\n`;
      const policy: hiAppEvent.EventPolicy = {
        mainThreadJankPolicy: {
          logType: 1,
          sampleInterval: 100,
          ignoreStartupTime: 3,
          sampleCount: 21,
          reportTimesPerApp: 3,
          autoStopSampling: true
        }
      };
      try {
        await hiAppEvent.configEventPolicy(policy);
        this.systemJankTestPolicyConfigured = true;
        this.testResults += 'System Jank API 22 fallback policy configured: interval=100ms, sample-count=21, startup-ignore=3s, report-limit=3\n';
        DemoLogger.i(TAG, '<FT-UI-BLOCK-TEST> MAIN_THREAD_JANK API 22 fallback policy configured');
        return true;
      } catch (fallbackError) {
        this.testResults += `Failed to configure System Jank test policy: ${String(fallbackError)}\n`;
        DemoLogger.e(TAG, 'Failed to configure MAIN_THREAD_JANK test policy:', fallbackError);
        return false;
      }
    }
  }

  /**
   * Prepares the documented jank policy. The three timeouts remain separate
   * button clicks because the platform sample relies on separately dispatched
   * click tasks, rather than timer callbacks queued by one click handler.
   */
  async testSystemJankCallback(): Promise<void> {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      return;
    }
    if (this.isTesting) {
      this.testResults += 'Previous test is still running, please wait...\n';
      return;
    }

    this.isTesting = true;
    try {
      const configured = await this.configureSystemJankTestPolicy();
      if (!configured) {
        return;
      }

      this.testResults += 'Waiting 3.2s for the system startup-ignore window before the MAIN_THREAD_JANK test...\n';
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 3200);
      });

      this.testResults += 'Policy ready. Quickly tap 350ms, 150ms, then 500ms below as three separate clicks.\n';
    } finally {
      this.isTesting = false;
    }
  }

  private runManualSystemJankTimeout(durationMs: number): void {
    if (!this.systemJankTestPolicyConfigured) {
      this.testResults += 'Prepare the System Jank policy first.\n';
      return;
    }
    this.simulateUIBlock(durationMs, `Manual System Jank Timeout (${durationMs}ms)`);
  }

  testSmallBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(500, 'Medium Block (500ms)');
  }

  /**
   * Test 1: Medium block (1500ms) - should trigger detection if threshold is 1000ms
   */
  testMediumBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(1500, 'Medium Block (1500ms)');
  }

  /**
   * Test 2: Long block (3000ms) - should definitely trigger detection
   */
  testLongBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(3000, 'Long Block (3000ms)');
  }

  /**
   * Test 3: Very long block (5000ms) - should definitely trigger detection
   */
  testVeryLongBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(5000, 'Very Long Block (5000ms)');
  }

  /**
   * Test 4: Multiple sequential blocks
   */
  async testMultipleBlocks() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }

    if (this.isTesting) {
      this.testResults += 'Previous test is still running, please wait...\n';
      return;
    }

    this.isTesting = true;
    this.testResults += `\n[${this.getTimeString()}] Starting: Multiple Sequential Blocks\n`;

    // Define block interface for ArkTS compatibility
    interface BlockItem {
      duration: number;
      desc: string;
    }

    const blocks: BlockItem[] = [
      { duration: 1200, desc: 'Block 1 (1200ms)' },
      { duration: 800, desc: 'Block 2 (800ms)' },
      { duration: 2000, desc: 'Block 3 (2000ms)' },
      { duration: 1500, desc: 'Block 4 (1500ms)' },
      { duration: 1000, desc: 'Block 5 (1000ms)' }
    ];

    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      this.testResults += `\n[${this.getTimeString()}] Executing: ${block.desc}\n`;
      this.runUIBlock(block.duration, block.desc);
      
      // Small delay between blocks
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 200);
      });
    }

    this.testResults += `\n[${this.getTimeString()}] Multiple blocks test completed\n`;
    this.isTesting = false;
  }

  /**
   * Test 5: Simulate database operation blocking
   */
  testDatabaseBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(1800, 'Database Operation Block (1800ms)');
  }

  /**
   * Test 6: Simulate file I/O operation blocking
   */
  testFileIOBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(2200, 'File I/O Operation Block (2200ms)');
  }

  /**
   * Test 7: Simulate network operation blocking (synchronous)
   */
  testNetworkBlock() {
    if (!this.isSDKInitialized) {
      this.testResults += 'Error: SDK not initialized\n';
      return;
    }
    if (!this.isUIBlockEnabled) {
      this.testResults += 'Warning: UI Block detection is not enabled in RUM config\n';
      this.testResults += 'Please enable it: FTRUMConfig.setEnableTrackAppUIBlock(true)\n';
      return;
    }
    this.simulateUIBlock(2500, 'Network Operation Block (2500ms)');
  }

  /**
   * Clear test results
   */
  clearResults() {
    this.testResults = 'Test results cleared\n';
    this.checkSDKStatus();
  }

  /**
   * Get current time string
   */
  private getTimeString(): string {
    const now = new Date();
    return `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}:${now.getSeconds().toString().padStart(2, '0')}`;
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

      Divider()

      // Status info
      Column() {
        Text(`SDK Status: ${this.isSDKInitialized ? '✅ Initialized' : '❌ Not Initialized'}`)
          .fontSize(14)
          .margin({ bottom: 5 })
        
        Text(`UI Block Detection: ${this.isUIBlockEnabled ? '✅ Enabled' : '❌ Disabled'}`)
          .fontSize(14)
          .margin({ bottom: 5 })

        if (this.isUIBlockEnabled && this.blockDurationThreshold > 0) {
          Text(`Threshold: ${this.blockDurationThreshold}ms`)
            .fontSize(14)
            .margin({ bottom: 5 })
        }
        
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#F5F5F5')
      .margin({ bottom: 10 })

      // Test buttons
      Scroll() {
        Column() {
          Text('System MAIN_THREAD_JANK Test')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 10, bottom: 10 })
            .width('100%')

          Text('1. Prepare policy. 2. Quickly tap 350ms → 150ms → 500ms as separate clicks.')
            .fontSize(12)
            .fontColor('#666666')
            .width('90%')
            .margin({ bottom: 10 })

          Button('1. Prepare System Jank Policy (about 4s)')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testSystemJankCallback();
            })

          Row() {
            Button('2. Timeout 350ms')
              .layoutWeight(1)
              .height(45)
              .margin({ right: 5 })
              .enabled(this.systemJankTestPolicyConfigured && !this.isTesting)
              .onClick(() => {
                this.runManualSystemJankTimeout(350);
              })

            Button('3. Timeout 150ms')
              .layoutWeight(1)
              .height(45)
              .margin({ left: 5, right: 5 })
              .enabled(this.systemJankTestPolicyConfigured && !this.isTesting)
              .onClick(() => {
                this.runManualSystemJankTimeout(150);
              })

            Button('4. Timeout 500ms')
              .layoutWeight(1)
              .height(45)
              .margin({ left: 5 })
              .enabled(this.systemJankTestPolicyConfigured && !this.isTesting)
              .onClick(() => {
                this.runManualSystemJankTimeout(500);
              })
          }
          .width('90%')
          .margin({ bottom: 10 })

          Divider()
            .margin({ top: 10, bottom: 10 })

          // Basic tests
          Text('Basic Tests')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 10, bottom: 10 })
            .width('100%')


          Button('Test 1: Medium Block (500ms)')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testSmallBlock();
            })

          Button('Test 1: Medium Block (1500ms)')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testMediumBlock();
            })

          Button('Test 2: Long Block (3000ms)')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testLongBlock();
            })

          Button('Test 3: Very Long Block (5000ms)')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testVeryLongBlock();
            })

          Divider()
            .margin({ top: 10, bottom: 10 })

          // Scenario tests
          Text('Scenario Tests')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 10 })
            .width('100%')

          Button('Test 4: Multiple Sequential Blocks')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testMultipleBlocks();
            })

          Button('Test 5: Database Operation Block')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testDatabaseBlock();
            })

          Button('Test 6: File I/O Operation Block')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testFileIOBlock();
            })

          Button('Test 7: Network Operation Block')
            .width('90%')
            .height(50)
            .margin({ bottom: 10 })
            .enabled(!this.isTesting)
            .onClick(() => {
              this.testNetworkBlock();
            })

          Divider()
            .margin({ top: 10, bottom: 10 })

          // Control buttons
          Row() {
            Button('Refresh Status')
              .width('90%')
              .height(40)
              .backgroundColor('#4CAF50')
              .onClick(() => {
                this.checkSDKStatus();
              })
          }
          .width('90%')
          .justifyContent(FlexAlign.SpaceBetween)
          .margin({ top: 10, bottom: 10 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
