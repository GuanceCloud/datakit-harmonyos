import { RateLimitTestUtils } from '../utils/RateLimitTestUtils';
import { FTDBCachePolicy } from 'shareLibrary/src/main/ets/components/db/FTDBCachePolicy';
import { FTRUMGlobalManager } from 'shareLibrary/src/main/ets/components/rum/FTRUMGlobalManager';
import { DataType, Status } from 'shareLibrary/src/main/ets/components/enum/Enums';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'DBCacheLimitTestPage';

@Entry
@Component
export struct DBCacheLimitTestPage {
  @State testResults: string = '';
  @State isRunning: boolean = false;
  @State currentDbSize: string = '0';
  @State dbLimit: string = '0';
  @State isLimitReached: boolean = false;
  @State writeCount: number = 0;
  @State autoWriteEnabled: boolean = false;
  private writeTimer: number = -1;

  aboutToAppear() {
    this.updateDbSizeInfo();
    // Periodically update the database size info
    setInterval(() => {
      this.updateDbSizeInfo();
    }, 1000);
  }

  aboutToDisappear() {
    // Stop auto writing
    if (this.writeTimer !== -1) {
      clearInterval(this.writeTimer);
      this.writeTimer = -1;
      this.autoWriteEnabled = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        TestPageHeader({
          title: 'Database Cache Limit Test'
        })

        // Show the current database status
        Column({ space: 10 }) {
          Text(`Current DB Size: ${this.currentDbSize} bytes`)
            .fontSize(16)
          Text(`DB Limit: ${this.dbLimit} bytes`)
            .fontSize(16)
          Text(`Limit Reached: ${this.isLimitReached ? 'YES ⚠️' : 'NO ✅'}`)
            .fontSize(16)
            .fontColor(this.isLimitReached ? Color.Red : Color.Green)
          Text(`Written Count: ${this.writeCount}`)
            .fontSize(14)
            .fontColor(Color.Gray)
          if (this.autoWriteEnabled) {
            Text('🔄 Auto Writing...')
              .fontSize(14)
              .fontColor(Color.Blue)
          }
        }
        .padding(20)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')

        // Test buttons
        Button(this.autoWriteEnabled ? 'Stop Auto Write' : 'Start Auto Write (Logs)')
          .width('90%')
          .height(50)
          .backgroundColor(this.autoWriteEnabled ? Color.Red : '#007DFF')
          .enabled(!this.isRunning)
          .onClick(() => {
            if (this.autoWriteEnabled) {
              this.stopAutoWrite();
            } else {
              this.startAutoWriteLogs();
            }
          })

        Button(this.autoWriteEnabled ? 'Stop Auto Write' : 'Start Auto Write (RUM)')
          .width('90%')
          .height(50)
          .backgroundColor(this.autoWriteEnabled ? Color.Red : '#007DFF')
          .enabled(!this.isRunning)
          .onClick(() => {
            if (this.autoWriteEnabled) {
              this.stopAutoWrite();
            } else {
              this.startAutoWriteRUM();
            }
          })

        Button('Write 100 Logs Once')
          .width('90%')
          .height(50)
          .backgroundColor('#28A745')
          .enabled(!this.autoWriteEnabled && !this.isRunning)
          .onClick(() => {
            this.writeLogsBatch(100);
          })

        Button('Write 100 RUM Data Once')
          .width('90%')
          .height(50)
          .backgroundColor('#28A745')
          .enabled(!this.autoWriteEnabled && !this.isRunning)
          .onClick(() => {
            this.writeRUMBatch(100);
          })

        Button('Refresh DB Size')
          .width('90%')
          .height(50)
          .backgroundColor('#FFC107')
          .onClick(() => {
            this.updateDbSizeInfo();
          })

        Button('Test Cache Policy')
          .width('90%')
          .height(50)
          .backgroundColor('#007DFF')
          .enabled(!this.autoWriteEnabled && !this.isRunning)
          .onClick(() => {
            this.runCachePolicyTest();
          })

      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  /**
   * Test cache policy limits
   */
  private runCachePolicyTest() {
    this.isRunning = true;
    this.appendResult('=== Starting Cache Policy Test ===\n');

    try {
      const testUtils = RateLimitTestUtils.getInstance();

      this.appendResult('\nTesting Log Cache Limit:\n');
      const logResult = testUtils.testCachePolicyLimits(DataType.LOG, 100);
      this.appendResult(`Initial Count: ${logResult.initialCount}\n`);
      this.appendResult(`Limit Reached: ${logResult.limitReached}\n`);
      this.appendResult(`Should Discard: ${logResult.shouldDiscard}\n`);
      this.appendResult(`Details: ${logResult.details}\n`);

      this.appendResult('\nTesting RUM Cache Limit:\n');
      const rumResult = testUtils.testCachePolicyLimits(DataType.RUM_APP, 50);
      this.appendResult(`Initial Count: ${rumResult.initialCount}\n`);
      this.appendResult(`Limit Reached: ${rumResult.limitReached}\n`);
      this.appendResult(`Should Discard: ${rumResult.shouldDiscard}\n`);
      this.appendResult(`Details: ${rumResult.details}\n`);

      this.appendResult('\n=== Cache Policy Test Completed ===\n');
    } catch (error) {
      this.appendResult(`❌ Cache Policy Test Failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Update database size info
   */
  private updateDbSizeInfo() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    const currentSize = cachePolicy.getCurrentDbSize();
    const limitSize = cachePolicy.getDbLimitSize();
    const reached = cachePolicy.isReachDbLimit();

    this.currentDbSize = this.formatBytes(currentSize);
    this.dbLimit = this.formatBytes(limitSize);
    this.isLimitReached = reached;

    // Log when the limit is reached while auto writing is enabled
    if (reached && this.autoWriteEnabled) {
      this.appendResult(`⚠️ Database limit reached! Size: ${this.formatBytes(currentSize)} / ${this.formatBytes(limitSize)}\n`);
    }
  }

  /**
   * Format byte size
   */
  private formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return (bytes / Math.pow(k, i)).toFixed(2) + ' ' + sizes[i];
  }

  /**
   * Start auto writing logs
   */
  private startAutoWriteLogs() {
    this.autoWriteEnabled = true;
    this.appendResult('=== Starting Auto Write (Logs) ===\n');
    this.appendResult('⚠️ Make sure your phone is disconnected from network!\n\n');

    let count = 0;
    this.writeTimer = setInterval(() => {
      try {
        // Write 10 logs each time
        for (let i = 0; i < 10; i++) {
          const logMessage = `Auto test log ${count * 10 + i + 1} - ${new Date().toISOString()}`;
          DemoLogger.i(TAG, logMessage);
        }
        count++;
        this.writeCount = count * 10;
        
        // Refresh the display every 10 iterations
        if (count % 10 === 0) {
          this.updateDbSizeInfo();
          this.appendResult(`Written ${this.writeCount} logs, DB Size: ${this.currentDbSize}\n`);
        }
      } catch (error) {
        this.appendResult(`❌ Error writing logs: ${error}\n`);
        this.stopAutoWrite();
      }
    }, 100); // Write once every 100 ms (10 logs each time)
  }

  /**
   * Start auto writing RUM data
   */
  private startAutoWriteRUM() {
    this.autoWriteEnabled = true;
    this.appendResult('=== Starting Auto Write (RUM) ===\n');
    this.appendResult('⚠️ Make sure your phone is disconnected from network!\n\n');

    let count = 0;
    this.writeTimer = setInterval(() => {
      try {
        const rumManager = FTRUMGlobalManager.getInstance();
        
        // Write an action
        rumManager.addAction(`AutoAction_${count}`, 'click');
        
        // Write an error
        rumManager.addCustomError(`AutoError_${count}`, `Error stack trace ${count}`);
        
        count++;
        this.writeCount = count * 2; // Write 2 RUM items each time
        
        // Refresh the display every 10 iterations
        if (count % 10 === 0) {
          this.updateDbSizeInfo();
          this.appendResult(`Written ${this.writeCount} RUM data, DB Size: ${this.currentDbSize}\n`);
        }
      } catch (error) {
        this.appendResult(`❌ Error writing RUM data: ${error}\n`);
        this.stopAutoWrite();
      }
    }, 200); // Write once every 200 ms (2 RUM items each time)
  }

  /**
   * Stop auto writing
   */
  private stopAutoWrite() {
    if (this.writeTimer !== -1) {
      clearInterval(this.writeTimer);
      this.writeTimer = -1;
    }
    this.autoWriteEnabled = false;
    this.appendResult(`\n=== Stopped Auto Write (Total: ${this.writeCount} items) ===\n`);
    this.updateDbSizeInfo();
  }

  /**
   * Write logs in batch
   */
  private writeLogsBatch(count: number) {
    this.isRunning = true;
    this.appendResult(`=== Writing ${count} Logs ===\n`);
    
    try {
      for (let i = 0; i < count; i++) {
        const logMessage = `Batch log ${i + 1} - ${new Date().toISOString()}`;
        DemoLogger.i(TAG, logMessage);
      }
      
      this.writeCount += count;
      this.appendResult(`✅ Written ${count} logs\n`);
      
      // Delay the database size update
      setTimeout(() => {
        this.updateDbSizeInfo();
        this.isRunning = false;
      }, 500);
      
    } catch (error) {
      this.appendResult(`❌ Failed to write logs: ${error}\n`);
      this.isRunning = false;
    }
  }

  /**
   * Write RUM data in batch
   */
  private writeRUMBatch(count: number) {
    this.isRunning = true;
    this.appendResult(`=== Writing ${count} RUM Data ===\n`);
    
    try {
      const rumManager = FTRUMGlobalManager.getInstance();
      
      for (let i = 0; i < count; i++) {
        rumManager.addAction(`BatchAction_${i}`, 'click');
        rumManager.addCustomError(`BatchError_${i}`, `Error ${i}`);
      }
      
      this.writeCount += count * 2;
      this.appendResult(`✅ Written ${count * 2} RUM data\n`);
      
      // Delay the database size update
      setTimeout(() => {
        this.updateDbSizeInfo();
        this.isRunning = false;
      }, 500);
      
    } catch (error) {
      this.appendResult(`❌ Failed to write RUM data: ${error}\n`);
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
}
