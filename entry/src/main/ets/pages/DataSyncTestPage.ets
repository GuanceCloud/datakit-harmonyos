import { FTLogger, FTSDK, FTRUMGlobalManager, Status } from '@guancecloud/ft_sdk/Index';
import { FTDBCachePolicy } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBCachePolicy';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'DataSyncTestPage';

@Entry
@Component
export struct DataSyncTestPage {
  @State testResults: string = '';
  @State isRunning: boolean = false;
  @State dbSize: string = '0 B';
  @State autoSyncEnabled: boolean = true;
  @State uploadLaneSummary: string = 'Unknown';
  private updateTimer: number = -1;

  aboutToAppear() {
    // Initialize the database size display
    this.dbSize = '0 B';
    // Get the current autoSync status
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      const status = syncTaskManager.getStatus();
      this.autoSyncEnabled = status.autoSync;
    } catch (error) {
      DemoLogger.e(TAG, `Failed to get autoSync status: ${error}`);
    }
    // Update data info immediately (keep behavior consistent with DBCacheLimitTestPage)
    try {
      this.updateDataInfo();
    } catch (error) {
      DemoLogger.e(TAG, `aboutToAppear error: ${error}`);
      this.dbSize = '0 B';
    }
  }

  aboutToDisappear() {
    // Clean up the timer
    this.stopAutoUpdate();
  }

  /**
   * Start auto update
   */
  private startAutoUpdate() {
    this.stopAutoUpdate(); // Make sure there is no duplicate timer
    try {
      // setInterval returns a timer ID (number type in HarmonyOS)
      this.updateTimer = setInterval(() => {
        this.updateDataInfo();
      }, 2000) as number;
    } catch (error) {
      DemoLogger.e(TAG, `Failed to start auto update: ${error}`);
    }
  }

  /**
   * Stop auto update
   */
  private stopAutoUpdate() {
    if (this.updateTimer !== -1) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        TestPageHeader({
          title: 'Data Sync & Clear Test'
        })

        // Show the current data status
        Column({ space: 10 }) {
          Text(`Database Size: ${this.dbSize}`)
            .fontSize(16)
          Text(`Data Count: ${this.dbSize !== '0 B' ? 'Has Data' : 'No Data'}`)
            .fontSize(14)
            .fontColor(this.dbSize !== '0 B' ? Color.Green : Color.Gray)
          Text(`Auto Sync: ${this.autoSyncEnabled ? 'Enabled ✅' : 'Disabled ❌'}`)
            .fontSize(14)
            .fontColor(this.autoSyncEnabled ? Color.Green : Color.Orange)
            .margin({ top: 5 })
          Text(`Upload Lane: ${this.uploadLaneSummary}`)
            .fontSize(14)
            .fontColor(Color.Gray)
            .margin({ top: 5 })
        }
        .padding(20)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .margin({ top: 10 })

        // Generate test data buttons
        Button('Generate Test Data (10 Logs + 10 Actions)')
          .width('90%')
          .height(50)
          .backgroundColor('#007DFF')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.generateTestData();
          })

        Button('Generate More Test Data (100 Logs + 100 Actions)')
          .width('90%')
          .height(50)
          .backgroundColor('#28A745')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.generateMoreTestData();
          })

        Divider()
          .width('90%')
          .margin({ top: 10, bottom: 10 })

        // Data sync test
        Text('Data Sync Test')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('90%')
          .textAlign(TextAlign.Start)

        Button(this.autoSyncEnabled ? 'Disable Auto Sync' : 'Enable Auto Sync')
          .width('90%')
          .height(50)
          .backgroundColor(this.autoSyncEnabled ? '#FF9800' : '#4CAF50')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.toggleAutoSync();
          })

        Button('Flush Sync Data (Manual Sync)')
          .width('90%')
          .height(50)
          .backgroundColor('#FFC107')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.testFlushSyncData();
          })

        Button('Test Proxy / DNS Upload (One Log)')
          .width('90%')
          .height(50)
          .backgroundColor('#673AB7')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.testNetworkRouteUpload();
          })

        Text('Note: When autoSync is disabled, use flushSyncData() to manually trigger data synchronization')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('90%')
          .textAlign(TextAlign.Start)
          .margin({ top: 5, bottom: 10 })

        Divider()
          .width('90%')
          .margin({ top: 10, bottom: 10 })

        // Clear data test
        Text('Clear Data Test')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('90%')
          .textAlign(TextAlign.Start)

        Button('Clear All Data')
          .width('90%')
          .height(50)
          .backgroundColor('#DC3545')
          .enabled(!this.isRunning)
          .onClick(() => {
            this.testClearAllData();
          })

        Text('Warning: This will delete ALL cached data (sync_data_flat, rum_view, rum_action)')
          .fontSize(12)
          .fontColor(Color.Red)
          .width('90%')
          .textAlign(TextAlign.Start)
          .margin({ top: 5, bottom: 10 })

        Button('Refresh Data Info')
          .width('90%')
          .height(40)
          .backgroundColor('#6C757D')
          .onClick(() => {
            this.updateDataInfo();
            if (this.updateTimer === -1) {
              this.startAutoUpdate();
            }
          })

        Text('Result Output')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('90%')
          .textAlign(TextAlign.Start)
          .margin({ top: 10 })

        Button('Clear Result Output')
          .width('90%')
          .height(40)
          .backgroundColor('#6C757D')
          .onClick(() => {
            this.clearResultOutput();
          })

        Column() {
          Text(this.testResults.length > 0 ? this.testResults : 'No output yet')
            .fontSize(12)
            .fontColor('#333333')
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .padding(12)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .margin({ bottom: 10 })

      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  /**
   * Update data info
   */
  private updateDataInfo() {
    try {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const currentSize = cachePolicy.getCurrentDbSize();
      this.dbSize = this.formatBytes(currentSize);
      this.updateUploadLaneSummary();
    } catch (error) {
      DemoLogger.e(TAG, `updateDataInfo error: ${error}`);
      this.dbSize = '0 B';
    }
  }

  private updateUploadLaneSummary(): void {
    try {
      const status = SyncTaskManager.getInstance().getStatus().uploadLaneStatus;
      if (status.isRunning) {
        this.uploadLaneSummary = `Running, needReschedule=${status.needReschedule}, next=${status.rescheduleDelay}ms`;
      } else if (status.isScheduled) {
        this.uploadLaneSummary = `Scheduled, delay=${status.scheduledDelay}ms`;
      } else {
        this.uploadLaneSummary = 'Idle';
      }
    } catch (error) {
      this.uploadLaneSummary = 'Unavailable';
      DemoLogger.e(TAG, `updateUploadLaneSummary error: ${error}`);
    }
  }

  /**
   * Format byte size
   */
  private formatBytes(bytes: number): string {
    try {
      // Handle invalid input
      if (bytes < 0 || isNaN(bytes) || !isFinite(bytes)) {
        return '0 B';
      }
      if (bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      // Ensure the index stays within the valid range
      if (i < 0 || i >= sizes.length) {
        return '0 B';
      }
      return (bytes / Math.pow(k, i)).toFixed(2) + ' ' + sizes[i];
    } catch (error) {
      DemoLogger.e(TAG, `formatBytes error: ${error}`);
      return '0 B';
    }
  }

  /**
   * Generate test data
   */
  private generateTestData() {
    this.isRunning = true;
    this.appendResult('=== Generating Test Data ===\n');
    
    try {
      // Generate 10 SDK logs
      for (let i = 0; i < 10; i++) {
        FTLogger.logBackground(`DataSync test log ${i + 1} - ${new Date().toISOString()}`, Status.INFO);
      }
      
      // Generate 10 actions
      const rumManager = FTRUMGlobalManager.getInstance();
      for (let i = 0; i < 10; i++) {
        rumManager.addAction(`TestAction_${i}`, 'click');
      }
      
      this.appendResult('✅ Generated 10 logs + 10 actions\n');
      this.appendResult('Expected upload: type=rum_app rows=10 and type=log rows=10\n');
      this.appendResult('Filter logs: Sync Data Count and Sync Success / Sync Fail\n');
      
      // Delay the data info update
      Promise.resolve().then(() => {
        return new Promise<void>((resolve) => {
          setTimeout(() => {
            this.updateDataInfo();
            this.isRunning = false;
            resolve();
          }, 1000);
        });
      });
      
    } catch (error) {
      this.appendResult(`❌ Failed to generate test data: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Generate more test data
   */
  private generateMoreTestData() {
    this.isRunning = true;
    this.appendResult('=== Generating More Test Data (100 logs + 100 actions) ===\n');
    
    try {
      // Generate 100 SDK logs
      for (let i = 0; i < 100; i++) {
        FTLogger.logBackground(`DataSync batch log ${i + 1} - ${new Date().toISOString()}`, Status.INFO);
      }
      
      // Generate 100 actions
      const rumManager = FTRUMGlobalManager.getInstance();
      for (let i = 0; i < 100; i++) {
        rumManager.addAction(`BatchAction_${i}`, 'click');
      }
      
      this.appendResult('✅ Generated 100 logs + 100 actions\n');
      this.appendResult('Expected upload: type=rum_app and type=log batches; larger data may upload across multiple polls\n');
      this.appendResult('Filter logs: Sync Poll, Sync Data Count, and Sync Success / Sync Fail\n');
      
      // Delay the data info update
      Promise.resolve().then(() => {
        return new Promise<void>((resolve) => {
          setTimeout(() => {
            this.updateDataInfo();
            this.isRunning = false;
            resolve();
          }, 2000);
        });
      });
      
    } catch (error) {
      this.appendResult(`❌ Failed to generate test data: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Toggle the Auto Sync state
   */
  private toggleAutoSync() {
    try {
      const syncTaskManager = SyncTaskManager.getInstance();
      const newState = !this.autoSyncEnabled;
      syncTaskManager.setAutoSync(newState);
      this.autoSyncEnabled = newState;
      this.updateUploadLaneSummary();
      this.appendResult(`=== Auto Sync ${newState ? 'Enabled' : 'Disabled'} ===\n`);
      this.appendResult(`Auto sync is now ${newState ? 'ON' : 'OFF'}\n`);
      if (!newState) {
        this.appendResult('💡 Use flushSyncData() to manually trigger data synchronization\n\n');
      } else {
        this.appendResult('💡 Data will be automatically synchronized after collection\n\n');
      }
    } catch (error) {
      this.appendResult(`❌ Failed to toggle auto sync: ${error}\n`);
    }
  }

  /**
   * Write one traceable log and immediately flush it for manual proxy/DNS verification.
   * Auto sync must be disabled first so the 10-second aggregation window does not
   * make the route test timing ambiguous.
   */
  private testNetworkRouteUpload(): void {
    if (this.autoSyncEnabled) {
      this.appendResult('⚠️ Disable Auto Sync before running the Proxy / DNS upload test.\n\n');
      return;
    }

    this.isRunning = true;
    const marker = `network-route-${Date.now()}`;
    this.appendResult('=== Proxy / DNS Upload Test ===\n');
    this.appendResult(`Marker: ${marker}\n`);

    try {
      FTLogger.logBackground(marker, Status.INFO);
      FTSDK.flushSyncData();
      this.appendResult('✅ One log written and flushSyncData() triggered\n');
      this.appendResult(`Check HiLog and the mock server for marker: ${marker}\n\n`);

      Promise.resolve().then(() => {
        return new Promise<void>((resolve) => {
          setTimeout(() => {
            this.updateDataInfo();
            this.appendResult(`After test - DB Size: ${this.dbSize}\n`);
            this.appendResult(`Upload Lane: ${this.uploadLaneSummary}\n`);
            this.isRunning = false;
            resolve();
          }, 2000);
        });
      });
    } catch (error) {
      this.appendResult(`❌ Proxy / DNS upload test failed: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Test flushSyncData
   */
  private testFlushSyncData() {
    this.isRunning = true;
    this.appendResult('=== Testing flushSyncData() ===\n');
    this.appendResult(`Auto Sync Status: ${this.autoSyncEnabled ? 'Enabled' : 'Disabled'}\n`);
    this.appendResult(`Before sync - DB Size: ${this.dbSize}\n`);
    
    try {
      // Call flushSyncData
      FTSDK.flushSyncData();
      
      this.appendResult('✅ flushSyncData() called successfully\n');
      this.appendResult('📤 Data synchronization triggered\n');
      if (!this.autoSyncEnabled) {
        this.appendResult('💡 Auto sync is disabled, this manual sync is necessary\n');
      }
      this.appendResult('Check logs: Sync Poll Running / Sync Poll Finish\n');
      this.appendResult('Check logs: Sync Data Count and pkg_id:... Sync Success / Sync Fail\n\n');
      
      // Delay the data info update
      Promise.resolve().then(() => {
        return new Promise<void>((resolve) => {
          setTimeout(() => {
            this.updateDataInfo();
            this.appendResult(`After sync - DB Size: ${this.dbSize}\n`);
            this.appendResult(`Upload Lane: ${this.uploadLaneSummary}\n`);
            this.appendResult('=== Test Complete ===\n\n');
            this.isRunning = false;
            resolve();
          }, 2000);
        });
      });
      
    } catch (error) {
      this.appendResult(`❌ flushSyncData() failed: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Test clearAllData
   */
  private async testClearAllData() {
    this.isRunning = true;
    this.appendResult('=== Testing clearAllData() ===\n');
    this.appendResult(`Before clear - DB Size: ${this.dbSize}\n`);
    this.appendResult('⚠️ WARNING: This will delete ALL cached data!\n');
    
    try {
      // Call clearAllData
      await FTSDK.clearAllData();
      this.updateUploadLaneSummary();
      
      this.appendResult('✅ clearAllData() called successfully\n');
      this.appendResult('🗑️ All cached data deleted\n');
      
      // Delay the data info update
      Promise.resolve().then(() => {
        return new Promise<void>((resolve) => {
          setTimeout(() => {
            this.updateDataInfo();
            this.appendResult(`After clear - DB Size: ${this.dbSize}\n`);
            this.appendResult('=== Test Complete ===\n\n');
            this.isRunning = false;
            resolve();
          }, 1000);
        });
      });
      
    } catch (error) {
      this.appendResult(`❌ clearAllData() failed: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Append a test result
   */
  private appendResult(text: string) {
    this.testResults += text;
    const lines = this.testResults.split('\n');
    if (lines.length > 80) {
      this.testResults = lines.slice(lines.length - 80).join('\n');
    }
    DemoLogger.i(TAG, text.trim());
  }

  private clearResultOutput(): void {
    this.testResults = '';
  }
}
