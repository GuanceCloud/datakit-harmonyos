import { FTLogger, FTSDK, FTRUMGlobalManager, Status, SyncPageSize } from '@guancecloud/ft_sdk/Index';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { CommonConstants } from '../constants/CommonConstants';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "BatchUploadTestPage";

@Entry
@Component
export struct BatchUploadTestPage {
  @State testResults: string[] = [];
  @State logCount: number = 0;
  @State actionCount: number = 0;
  @State viewCount: number = 0;
  @State errorCount: number = 0;

  aboutToAppear(): void {
    this.testResults = [];
    this.addTestResult("=== Batch Upload Test Page ===");
    this.addTestResult("This page tests the batch upload functionality");
    this.addTestResult("Check logs with: grep 'RUM-UPLOAD' or 'SyncTaskManager'");
  }

  private addTestResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    const nextResults = [...this.testResults, `[${timestamp}] ${message}`];
    this.testResults = nextResults.length > 60
      ? nextResults.slice(nextResults.length - 60)
      : nextResults;
    DemoLogger.i(TAG, message);
  }

  /**
   * Generate test data (logs, actions, views)
   * Data types:
   * - Log: Custom log records (Status.INFO level)
   * - Action: RUM action events (click type, auto-close after 100ms)
   * - View: RUM view events (page navigation)
   */
  private generateTestData(): void {
    this.addTestResult("=== Generating Test Data ===");
    this.addTestResult("📋 Data Types:");
    this.addTestResult("  - Log: Custom log records (INFO level)");
    this.addTestResult("  - Action: RUM click actions (auto-close 100ms)");
    this.addTestResult("  - View: RUM page views");
    
    this.logCount = 0;
    this.actionCount = 0;
    this.viewCount = 0;
    
    try {
      // Generate 100 logs asynchronously (simulating real-world scenario)
      // Logs are generated with small random delays to simulate real usage
      this.addTestResult("📤 Generating 100 logs asynchronously (simulating real scenario)...");
      const logDelay = 10; // 10ms between logs (more realistic than instant generation)
      
      for (let i = 0; i < 100; i++) {
        setTimeout(() => {
          FTLogger.logBackground(`Batch upload test log ${i + 1}`, Status.INFO);
          this.logCount++;
          if (this.logCount === 100) {
            this.addTestResult(`✅ Generated ${this.logCount} log records`);
            this.checkAllDataGenerated();
          }
        }, i * logDelay); // Stagger logs over ~1 second
      }

      // Generate actions asynchronously
      const rumManager = FTRUMGlobalManager.getInstance();
      const actionDelay = 50; // 50ms between actions
      
      for (let i = 0; i < 10; i++) {
        setTimeout(() => {
          rumManager.startAction(`Test Action ${i + 1}`, 'click');
          // Close action after 50ms
          setTimeout(() => {
            rumManager.stopAction();
          }, 50);
          this.actionCount++;
          if (this.actionCount === 10) {
            this.addTestResult(`✅ Generated ${this.actionCount} action records (will auto-close after 100ms)`);
            this.checkAllDataGenerated();
          }
        }, i * actionDelay);
      }

      // Generate views asynchronously
      const viewDelay = 100; // 100ms between views
      
      for (let i = 0; i < 5; i++) {
        setTimeout(() => {
          rumManager.startView(`TestView${i + 1}`);
          setTimeout(() => {
            rumManager.stopView({});
          }, 100);
          this.viewCount++;
          if (this.viewCount === 5) {
            this.addTestResult(`✅ Generated ${this.viewCount} view records`);
            this.checkAllDataGenerated();
          }
        }, i * viewDelay);
      }

      this.addTestResult("⏳ Generating data asynchronously...");
      this.addTestResult("💡 Wait a few seconds, then click 'Trigger Immediate Upload'");
    } catch (error) {
      this.addTestResult(`❌ Error generating test data: ${error}`);
    }
  }

  /**
   * Check if all data has been generated
   */
  private checkAllDataGenerated(): void {
    if (this.logCount === 100 && this.actionCount === 10 && this.viewCount === 5) {
      this.addTestResult(`📊 Total: ${this.logCount + this.actionCount + this.viewCount} records generated`);
      this.addTestResult("⚠️ Data is stored in database, waiting for sync...");
      this.addTestResult("💡 Click 'Trigger Immediate Upload' to force upload");
    }
  }

  /**
   * Trigger immediate upload through the SDK public flush API.
   */
  private flushSyncData(): void {
    this.addTestResult("=== Triggering Immediate Upload ===");
    
    try {
      this.addTestResult("✅ Calling FTSDK.flushSyncData() - immediate upload");
      FTSDK.flushSyncData();
      this.addTestResult("✅ Upload triggered, check logs for upload details");
      this.addTestResult("💡 Filter logs: grep 'RUM-UPLOAD' | grep 'Response Code'");
    } catch (error) {
      this.addTestResult(`❌ Error triggering upload: ${error}`);
    }
  }

  /**
   * Trigger scheduled upload (executeSyncPoll)
   */
  private triggerScheduledUpload(): void {
    this.addTestResult("=== Triggering Scheduled Upload ===");
    
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      if (!syncTaskManager) {
        this.addTestResult("❌ SyncTaskManager instance not found");
        return;
      }

      this.addTestResult("✅ Calling executeSyncPoll() - scheduled upload");
      syncTaskManager.executeSyncPoll();
      this.addTestResult("✅ Scheduled upload triggered");
      this.addTestResult("💡 Will upload after interval if autoSync is enabled");
    } catch (error) {
      this.addTestResult(`❌ Error triggering scheduled upload: ${error}`);
    }
  }

  /**
   * Check sync status
   */
  private checkSyncStatus(): void {
    this.addTestResult("=== Checking Sync Status ===");
    
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      if (!syncTaskManager) {
        this.addTestResult("❌ SyncTaskManager instance not found");
        return;
      }

      const status = syncTaskManager.getStatus();
      this.addTestResult(`✅ Auto Sync: ${status.autoSync}`);
      this.addTestResult(`✅ Running: ${status.running}`);
      this.addTestResult(`✅ Is Stop: ${status.isStop}`);
      this.addTestResult(`✅ Error Count: ${status.errorCount}`);
      this.addTestResult(`✅ Page Size: ${status.pageSize}`);
      this.addTestResult(`✅ Max Retry Count: ${status.dataSyncMaxRetryCount}`);
      this.addTestResult(`✅ Sync Sleep Time: ${status.syncSleepTime}ms`);
    } catch (error) {
      this.addTestResult(`❌ Error checking status: ${error}`);
    }
  }

  /**
   * Test batch upload with multiple data types
   */
  private async testBatchUpload(): Promise<void> {
    this.addTestResult("=== Batch Upload Test ===");
    
    try {
      // Step 1: Generate data
      this.generateTestData();
      
      // Step 2: Wait a bit for data to be written to DB
      await new Promise<void>(resolve => setTimeout(resolve, 500));
      
      // Step 3: Check status
      this.checkSyncStatus();
      
      // Step 4: Trigger upload
      this.flushSyncData();
      
      // Step 5: Wait and show results
      setTimeout(() => {
        this.addTestResult("=== Test Complete ===");
        this.addTestResult("📋 Check logs for upload details:");
        this.addTestResult("   - grep 'RUM-UPLOAD'");
        this.addTestResult("   - grep 'Response Code'");
        this.addTestResult("   - grep 'Package ID'");
        this.addTestResult("   - grep 'Body  ---->'");
      }, 2000);
    } catch (error) {
      this.addTestResult(`❌ Batch upload test failed: ${error}`);
    }
  }

  /**
   * Test error sampled consume
   */
  private testErrorSampled(): void {
    this.addTestResult("=== Testing Error Sampled Consume ===");
    
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      if (!syncTaskManager) {
        this.addTestResult("❌ SyncTaskManager instance not found");
        return;
      }

      // Set error time line
      const now = Date.now() * 1_000_000; // Convert to nanoseconds
      syncTaskManager.setErrorTimeLine(now);
      this.addTestResult(`✅ Set errorTimeLine: ${now}`);
      this.addTestResult("💡 errorSampledConsume will be called in next sync cycle");
      this.addTestResult("💡 Filter logs: grep 'errorSampledConsume'");
    } catch (error) {
      this.addTestResult(`❌ Error testing error sampled: ${error}`);
    }
  }

  /**
   * Test batch upload size consistency
   * This test verifies that batch upload size is fixed according to pageSize
   */
  private async testBatchUploadSize(): Promise<void> {
    this.addTestResult("=== Testing Batch Upload Size Consistency ===");
    
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      if (!syncTaskManager) {
        this.addTestResult("❌ SyncTaskManager instance not found");
        return;
      }

      // Get current pageSize
      const status = syncTaskManager.getStatus();
      const currentPageSize = status.pageSize;
      this.addTestResult(`📊 Current Page Size: ${currentPageSize}`);
      this.addTestResult(`   - MINI = ${SyncPageSize.MINI}`);
      this.addTestResult(`   - MEDIUM = ${SyncPageSize.MEDIUM}`);
      this.addTestResult(`   - LARGE = ${SyncPageSize.LARGE}`);

      // Generate 30 logs to test batch upload
      // With pageSize=10: should upload 10+10+10 (3 batches)
      // With pageSize=5: should upload 5+5+5+5+5+5 (6 batches)
      // With pageSize=50: should upload 30 (1 batch, all data)
      const testLogCount = 30;
      this.addTestResult(`📤 Generating ${testLogCount} test logs...`);
      
      this.logCount = 0;
      const logDelay = 10; // 10ms between logs
      
      for (let i = 0; i < testLogCount; i++) {
        setTimeout(() => {
          FTLogger.logBackground(`Batch size test log ${i + 1}/${testLogCount}`, Status.INFO);
          this.logCount++;
          if (this.logCount === testLogCount) {
            this.addTestResult(`✅ Generated ${this.logCount} log records`);
            this.addTestResult("⏳ Waiting 2 seconds for data to be written to database...");
          }
        }, i * logDelay);
      }

      // Wait for data to be written to database
      await new Promise<void>(resolve => setTimeout(resolve, 2000));

      // Trigger immediate upload
      this.addTestResult("🚀 Triggering immediate upload...");
      FTSDK.flushSyncData();

      // Calculate expected batch counts
      const expectedFullBatches = Math.floor(testLogCount / currentPageSize);
      const remainder = testLogCount % currentPageSize;
      const expectedTotalBatches = remainder > 0 ? expectedFullBatches + 1 : expectedFullBatches;

      this.addTestResult("📋 Expected Upload Pattern:");
      if (currentPageSize >= testLogCount) {
        this.addTestResult(`   - 1 batch with ${testLogCount} records (all data)`);
      } else {
        for (let i = 0; i < expectedFullBatches; i++) {
          this.addTestResult(`   - Batch ${i + 1}: ${currentPageSize} records`);
        }
        if (remainder > 0) {
          this.addTestResult(`   - Batch ${expectedTotalBatches}: ${remainder} records (last batch)`);
        }
      }
      this.addTestResult(`   - Total: ${expectedTotalBatches} batch(es)`);

      this.addTestResult("📝 Check logs for verification:");
      this.addTestResult("   grep 'Query result.*records for log' log.txt");
      this.addTestResult("   grep 'Record Count:' log.txt");
      this.addTestResult("   grep 'Data Count:' log.txt");
      this.addTestResult("");
      this.addTestResult("✅ Expected: Each batch should have exactly:");
      this.addTestResult(`   - ${currentPageSize} records (except last batch if remainder exists)`);
      this.addTestResult("");
      this.addTestResult("⚠️ If batch sizes are inconsistent, the fix may not be working correctly.");

    } catch (error) {
      this.addTestResult(`❌ Error testing batch upload size: ${error}`);
    }
  }

  build() {
    Column() {
      TestPageHeader({
        title: 'Batch Upload Test'
      })

      // Test buttons
      Scroll() {
        Column() {
          // Data generation
          Button('1. Generate Test Data')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.generateTestData();
            })

          // Immediate upload
          Button('2. Trigger Immediate Upload')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.flushSyncData();
            })

          // Scheduled upload
          Button('3. Trigger Scheduled Upload')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.triggerScheduledUpload();
            })

          // Check status
          Button('4. Check Sync Status')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.checkSyncStatus();
            })

          // Full test
          Button('5. Full Batch Upload Test')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.testBatchUpload();
            })

          // Error sampled test
          Button('6. Test Error Sampled')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.testErrorSampled();
            })

          // Batch upload size test
          Button('7. Test Batch Upload Size (Fixed)')
            .width('100%')
            .height(50)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.testBatchUploadSize();
            })

          Divider().margin({ top: 10, bottom: 10 })

          // Instructions
          Divider().margin({ top: 20, bottom: 10 })

          Text('📋 Test Instructions:')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 10 })

          Text('1. Click "Generate Test Data" to create test data')
            .fontSize(12)
            .margin({ bottom: 5 })
          Text('2. Click "Trigger Immediate Upload" to force upload')
            .fontSize(12)
            .margin({ bottom: 5 })
          Text('3. Check logs with grep commands below')
            .fontSize(12)
            .margin({ bottom: 10 })

          Text('📊 Log Filter Commands:')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 10, bottom: 10 })

          Text('grep "RUM-UPLOAD" log.txt')
            .fontSize(11)
            .fontColor(Color.Blue)
            .margin({ bottom: 3 })
          Text('grep "Response Code" log.txt')
            .fontSize(11)
            .fontColor(Color.Blue)
            .margin({ bottom: 3 })
          Text('grep "Package ID" log.txt')
            .fontSize(11)
            .fontColor(Color.Blue)
            .margin({ bottom: 3 })
          Text('grep "Body  ---->" log.txt')
            .fontSize(11)
            .fontColor(Color.Blue)
            .margin({ bottom: 3 })
        }
        .width('100%')
        .padding(20)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
