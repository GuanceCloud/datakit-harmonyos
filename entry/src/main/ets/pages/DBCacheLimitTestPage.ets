import { FTDBCachePolicy } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBCachePolicy';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { DbInternalTestAccess } from '@guancecloud/ft_sdk/src/main/ets/components/internal/testaccess/DbInternalTestAccess';
import { FTRUMGlobalManager, FTLogger, FTSDK, RUMCacheDiscard, Status } from '@guancecloud/ft_sdk/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { Context } from '@kit.AbilityKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'DBCacheLimitTestPage';
const PAGE_DB_CACHE_LIMIT_SIZE = 30 * 1024 * 1024;
const PAGE_LOG_CACHE_LIMIT_COUNT = 30000;
const PAGE_RUM_CACHE_LIMIT_COUNT = 12345;
const DB_METRICS_REFRESH_INTERVAL_MS = 3000;
const AUTO_LOG_STATUS_INTERVAL = 10;
const AUTO_RUM_STATUS_INTERVAL = 5;
const MAX_RESULT_LINES = 30000;
const DATA_LOSS_VERIFY_TIMEOUT_MS = 10000;
const NO_LOCK_DB_RACE_BASELINE_COUNT = 20;
const NO_LOCK_DB_RACE_LOG_COUNT = 200;
const NO_LOCK_DB_RACE_BEFORE_SHUTDOWN_COUNT = 60;
const DB_SHUTDOWN_RACE_BASELINE_COUNT = 50;
const DB_SHUTDOWN_RACE_LOG_COUNT = 200;
const DB_SHUTDOWN_RACE_RECOVERY_COUNT = 50;
const DB_SHUTDOWN_RACE_BATCH_SIZE = 10;
const DB_SHUTDOWN_RACE_ATTEMPTS = 3;
const DB_SHUTDOWN_RACE_INTERVAL_MS = 150;
const DB_SHUTDOWN_RACE_RECOVERY_DELAY_MS = 800;
const LOG_QUEUE_LOSS_BASELINE_COUNT = 50;
const LOG_QUEUE_LOSS_LOG_COUNT = 1500;
const LOG_QUEUE_LOSS_EXPECTED_QUEUE_CAPACITY = 1000;
const LOG_QUEUE_LOSS_RECOVERY_COUNT = 50;
const LOG_QUEUE_LOSS_TIMEOUT_MS = 20000;

@Entry
@Component
export struct DBCacheLimitTestPage {
  @State testResults: string = '';
  @State isRunning: boolean = false;
  @State currentDbSize: string = '0 B';
  @State dbCacheLimit: string = '0 B';
  @State dbCacheEnabled: boolean = false;
  @State dbLimitReached: boolean = false;
  @State effectivePolicy: string = 'Unknown';
  @State logCountText: string = '0';
  @State logLimitText: string = '0';
  @State rumCountText: string = '0';
  @State rumLimitText: string = '0';
  @State dbCacheDiscard: string = 'discard';
  @State rumCacheDiscard: string = 'discard';
  @State actualLogDbCountText: string = '-';
  @State actualRumDbCountText: string = '-';
  @State countLimitNote: string = 'Log/RUM count limits are active.';
  @State writeCount: number = 0;
  @State autoWriteEnabled: boolean = false;
  @State context: Context = getContext(this) as Context;
  private writeTimer: number = -1;
  private infoTimer: number = -1;
  private dbMetricsRefreshing: boolean = false;
  private lastDbMetricsRefreshTime: number = 0;
  private limitReachedNoticeShown: boolean = false;
  private autoWriteDataType: DataType = DataType.LOG;

  aboutToAppear() {
    if (this.infoTimer !== -1) {
      clearInterval(this.infoTimer);
      this.infoTimer = -1;
    }
    this.applyPageLoadCacheConfig();
    this.updatePolicyInfo();
    this.refreshActualDbCounts(true);
    this.infoTimer = setInterval(() => {
      this.updatePolicyInfo();
    }, 1000) as number;
  }

  aboutToDisappear() {
    if (this.writeTimer !== -1) {
      clearInterval(this.writeTimer);
      this.writeTimer = -1;
      this.autoWriteEnabled = false;
    }
    if (this.infoTimer !== -1) {
      clearInterval(this.infoTimer);
      this.infoTimer = -1;
    }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        TestPageHeader({
          title: 'Database Cache Limit Test'
        })

        Column({ space: 10 }) {
          Text('Current Effective Policy')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text(`Effective Mode: ${this.effectivePolicy}`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#007DFF')
            .width('100%')

          Text(`DB Size: ${this.currentDbSize}`)
            .fontSize(15)
            .width('100%')

          Divider()
            .width('100%')
            .margin({ top: 4, bottom: 4 })

          Text(`DB Cache: ${this.dbCacheEnabled ? 'Enabled' : 'Disabled'} | Limit: ${this.dbCacheLimit} | Reached: ${this.dbLimitReached ? 'YES' : 'NO'}`)
            .fontSize(14)
            .fontColor(this.dbLimitReached ? Color.Red : Color.Green)
            .width('100%')

          Text(`Log Cache: ${this.logCountText} / ${this.logLimitText}`)
            .fontSize(14)
            .fontColor(this.dbCacheEnabled ? '#888888' : '#222222')
            .width('100%')

          Text(`RUM Cache: ${this.rumCountText} / ${this.rumLimitText}`)
            .fontSize(14)
            .fontColor(this.dbCacheEnabled ? '#888888' : '#222222')
            .width('100%')

          Text(`Actual DB Count: Log=${this.actualLogDbCountText}, RUM=${this.actualRumDbCountText}`)
            .fontSize(14)
            .fontColor('#555555')
            .width('100%')

          Text(`Discard Strategy: DB=${this.dbCacheDiscard}, RUM=${this.rumCacheDiscard}`)
            .fontSize(14)
            .fontColor(Color.Gray)
            .width('100%')

          Text(this.countLimitNote)
            .fontSize(12)
            .fontColor(this.dbCacheEnabled ? '#FF9800' : '#666666')
            .width('100%')
        }
        .padding(16)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('Data Generator')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text(`Written Count: ${this.writeCount}`)
            .fontSize(14)
            .fontColor(Color.Gray)
            .width('100%')

          if (this.autoWriteEnabled) {
            Text('Auto Writing...')
              .fontSize(14)
              .fontColor(Color.Blue)
              .width('100%')
          }

          Button(this.autoWriteEnabled ? 'Stop Auto Write' : 'Start Auto Write (Logs)')
            .width('100%')
            .height(48)
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
            .width('100%')
            .height(48)
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
            .width('100%')
            .height(48)
            .backgroundColor('#28A745')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.writeLogsBatch(100);
            })

          Button('Verify No-Lock DB Race')
            .width('100%')
            .height(48)
            .backgroundColor('#FF9800')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyNoLockDbRace();
            })

          Button('Verify DB Shutdown Race (Logs)')
            .width('100%')
            .height(48)
            .backgroundColor('#E65100')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyLogDataLossWithDbShutdown();
            })

          Button('Verify Log Queue Overflow Loss')
            .width('100%')
            .height(48)
            .backgroundColor('#B00020')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyLogQueueOverflowLoss();
            })

          Button('Write 100 RUM Data Once')
            .width('100%')
            .height(48)
            .backgroundColor('#28A745')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.writeRUMBatch(100);
            })

          Button('Refresh Policy Status')
            .width('100%')
            .height(44)
            .backgroundColor('#6C757D')
            .onClick(() => {
              this.refreshPolicyStatus();
            })

          Button('Clear Cached DB')
            .width('100%')
            .height(44)
            .backgroundColor('#DC3545')
            .enabled(!this.isRunning)
            .onClick(() => {
              this.clearCachedDb();
            })
        }
        .padding(16)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('Policy Tests')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Button('Test DB Cache')
            .width('100%')
            .height(44)
            .backgroundColor('#007DFF')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runDbCachePolicyTest();
            })

          Button('Test Log Count')
            .width('100%')
            .height(44)
            .backgroundColor('#007DFF')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runLogCachePolicyTest();
            })

          Button('Test RUM Count')
            .width('100%')
            .height(44)
            .backgroundColor('#007DFF')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runRumCachePolicyTest();
            })

          Button('Verify RUM DISCARD')
            .width('100%')
            .height(44)
            .backgroundColor('#795548')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyRumDiscardAtLimit();
            })

          Button('Verify RUM DISCARD_OLDEST')
            .width('100%')
            .height(44)
            .backgroundColor('#795548')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyRumDiscardOldestAtLimit();
            })

          Button('Test All Policies')
            .width('100%')
            .height(48)
            .backgroundColor('#FF6B35')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runCachePolicyTest();
            })
        }
        .padding(16)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Row() {
            Text('Test Results')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)

            Button('Clear Results')
              .height(36)
              .enabled(this.testResults.length > 0)
              .onClick(() => {
                this.clearResults();
              })
          }
          .width('100%')

          if (this.testResults.length === 0) {
            Text('No test results yet.')
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')
          } else {
            Text(this.testResults)
              .fontSize(12)
              .fontColor('#222222')
              .width('100%')
              .padding(12)
              .backgroundColor('#FFFFFF')
              .borderRadius(6)
          }
        }
        .padding(16)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .width('90%')
        .alignItems(HorizontalAlign.Start)

      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  /**
   * Test all cache policy areas.
   */
  private runCachePolicyTest() {
    this.isRunning = true;
    this.appendResult('\n=== Starting Cache Policy Test ===\n');

    try {
      this.updatePolicyInfo();
      this.appendPolicyOverview();
      this.appendDbCachePolicyResult();
      this.appendLogCachePolicyResult();
      this.appendRumCachePolicyResult();
      this.appendResult('\n=== Cache Policy Test Completed ===\n');
    } catch (error) {
      this.appendResult(`Cache Policy Test Failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Update policy status shown on the page.
   */
  private updatePolicyInfo(refreshDbCounts: boolean = false) {
    const cachePolicy = FTDBCachePolicy.getInstance();
    const currentSize = cachePolicy.getCurrentDbSize();
    const logLimit = cachePolicy.getLogLimitCount();
    const rumLimit = cachePolicy.getRumLimitCount();
    const dbEnabled = cachePolicy.isEnableLimitWithDbSize();
    const isSizeBasedLimitEnabled = dbEnabled;

    this.currentDbSize = this.formatBytes(currentSize);
    this.dbCacheLimit = this.formatBytes(cachePolicy.getDbLimitSize());
    this.dbCacheEnabled = dbEnabled;
    this.dbLimitReached = cachePolicy.isReachDbLimit();
    this.effectivePolicy = this.resolveEffectivePolicy(dbEnabled);
    this.logCountText = `${cachePolicy.getLogCount()}`;
    this.rumCountText = `${cachePolicy.getRumCount()}`;
    this.logLimitText = isSizeBasedLimitEnabled ? `Ignored (${logLimit})` : `${logLimit}`;
    this.rumLimitText = isSizeBasedLimitEnabled ? `Ignored (${rumLimit})` : `${rumLimit}`;
    this.dbCacheDiscard = this.formatStrategy(cachePolicy.getDBCacheDiscard());
    this.rumCacheDiscard = this.formatStrategy(String(cachePolicy.getDiscardStrategy(DataType.RUM_APP)));
    this.countLimitNote = isSizeBasedLimitEnabled
      ? 'Size-based limit is enabled. Log/RUM count limits are ignored.'
      : 'Log/RUM count limits are active.';

    if (refreshDbCounts) {
      this.refreshActualDbCounts(false);
    }

    this.appendLimitReachedNotice();
  }

  private async refreshPolicyStatus(): Promise<void> {
    this.isRunning = true;
    try {
      this.updatePolicyInfo();
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendPolicyOverview();
    } catch (error) {
      this.appendResult(`Refresh policy status failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private applyPageLoadCacheConfig() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    cachePolicy.setTestLimits(PAGE_LOG_CACHE_LIMIT_COUNT, PAGE_RUM_CACHE_LIMIT_COUNT);
    // cachePolicy.setTestDbSizeLimit(PAGE_DB_CACHE_LIMIT_SIZE);
  }

  private resolveEffectivePolicy(dbEnabled: boolean): string {
    if (dbEnabled) {
      return 'DB Cache Size';
    }
    return 'Log/RUM Count';
  }

  private formatStrategy(strategy: string): string {
    if (strategy === 'discard_oldest') {
      return 'DISCARD_OLDEST';
    }
    if (strategy === 'discard') {
      return 'DISCARD';
    }
    return strategy;
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

  private runDbCachePolicyTest() {
    this.isRunning = true;
    try {
      this.updatePolicyInfo();
      this.appendResult('\n=== DB Cache Policy ===\n');
      this.appendDbCachePolicyResult();
    } catch (error) {
      this.appendResult(`DB Cache Policy Test Failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private runLogCachePolicyTest() {
    this.isRunning = true;
    try {
      this.updatePolicyInfo();
      this.appendResult('\n=== Log Count Policy ===\n');
      this.appendLogCachePolicyResult();
    } catch (error) {
      this.appendResult(`Log Count Policy Test Failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private runRumCachePolicyTest() {
    this.isRunning = true;
    try {
      this.updatePolicyInfo();
      this.appendResult('\n=== RUM Count Policy ===\n');
      this.appendRumCachePolicyResult();
    } catch (error) {
      this.appendResult(`RUM Count Policy Test Failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private appendPolicyOverview() {
    this.appendResult('\n[Overview]\n');
    this.appendResult(`Effective Mode: ${this.effectivePolicy}\n`);
    this.appendResult(`DB Size: ${this.currentDbSize}\n`);
    this.appendResult(`DB Cache: ${this.dbCacheEnabled ? 'Enabled' : 'Disabled'}, Limit=${this.dbCacheLimit}, Reached=${this.dbLimitReached}\n`);
    this.appendResult(`Log Count: ${this.logCountText}, Limit=${this.logLimitText}\n`);
    this.appendResult(`RUM Count: ${this.rumCountText}, Limit=${this.rumLimitText}\n`);
    this.appendResult(`Actual DB Count: Log=${this.actualLogDbCountText}, RUM=${this.actualRumDbCountText}\n`);
    this.appendResult(`Discard Strategy: DB=${this.dbCacheDiscard}, RUM=${this.rumCacheDiscard}\n`);
    this.appendResult(`${this.countLimitNote}\n`);
  }

  private appendDbCachePolicyResult() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    this.appendResult('\n[DB Cache]\n');
    this.appendResult(`Enabled: ${this.dbCacheEnabled}\n`);
    this.appendResult(`Current Size: ${this.currentDbSize}\n`);
    this.appendResult(`Limit Size: ${this.dbCacheLimit}\n`);
    this.appendResult(`Reached: ${this.dbLimitReached}\n`);
    this.appendResult(`Discard Strategy: ${this.dbCacheDiscard}\n`);
    if (!this.dbCacheEnabled) {
      this.appendResult('DB cache size limit is disabled.\n');
      return;
    }
    this.appendResult(`Log should discard by current effective policy: ${cachePolicy.shouldDiscardData(DataType.LOG)}\n`);
    this.appendResult(`RUM should discard by current effective policy: ${cachePolicy.shouldDiscardData(DataType.RUM_APP)}\n`);
  }

  private appendLogCachePolicyResult() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    this.appendResult('\n[Log Count]\n');
    this.appendResult(`Current Count: ${cachePolicy.getLogCount()}\n`);
    this.appendResult(`Limit Count: ${cachePolicy.getLogLimitCount()}\n`);
    if (this.dbCacheEnabled) {
      this.appendResult('Inactive: size-based limit is enabled, so Log count limit is ignored.\n');
      return;
    }
    this.appendResult(`Reached: ${cachePolicy.isReachLogLimit()}\n`);
    this.appendResult(`Should Discard: ${cachePolicy.shouldDiscardData(DataType.LOG)}\n`);
  }

  private appendRumCachePolicyResult() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    this.appendResult('\n[RUM Count]\n');
    this.appendResult(`Current Count: ${cachePolicy.getRumCount()}\n`);
    this.appendResult(`Limit Count: ${cachePolicy.getRumLimitCount()}\n`);
    this.appendResult(`Actual DB Count: ${this.actualRumDbCountText}\n`);
    this.appendResult(`Discard Strategy: ${this.formatStrategy(String(cachePolicy.getDiscardStrategy(DataType.RUM_APP)))}\n`);
    if (this.dbCacheEnabled) {
      this.appendResult('Inactive: size-based limit is enabled, so RUM count limit is ignored.\n');
      return;
    }
    this.appendResult(`Reached: ${cachePolicy.isReachRumLimit()}\n`);
    this.appendResult(`Should Discard: ${cachePolicy.shouldDiscardData(DataType.RUM_APP)}\n`);
  }

  /**
   * Start auto writing logs
   */
  private startAutoWriteLogs() {
    this.autoWriteEnabled = true;
    this.limitReachedNoticeShown = false;
    this.autoWriteDataType = DataType.LOG;
    this.appendResult('=== Starting Auto Write (Logs) ===\n');
    this.appendResult('Make sure your phone is disconnected from network.\n\n');

    let count = 0;
    this.writeTimer = setInterval(() => {
      try {
        // Write 10 logs each time
        for (let i = 0; i < 10; i++) {
          const logMessage = `Auto test log ${count * 10 + i + 1} - ${new Date().toISOString()}`;
          FTLogger.logBackground(logMessage, Status.INFO, undefined, true);
        }
        count++;
        this.writeCount = count * 10;
        
        if (count % AUTO_LOG_STATUS_INTERVAL === 0) {
          this.updatePolicyInfo();
          this.refreshActualDbCounts(false);
          this.appendResult(`Written ${this.writeCount} SDK logs, DB Size: ${this.currentDbSize}\n`);
          const stopReason = this.getAutoStopReason(DataType.LOG);
          if (stopReason.length > 0) {
            this.stopAutoWrite(stopReason);
          }
        }
      } catch (error) {
        this.appendResult(`Error writing logs: ${error}\n`);
        this.stopAutoWrite();
      }
    }, 100); // Write once every 100 ms (10 logs each time)
  }

  /**
   * Start auto writing RUM data
   */
  private startAutoWriteRUM() {
    this.autoWriteEnabled = true;
    this.limitReachedNoticeShown = false;
    this.autoWriteDataType = DataType.RUM_APP;
    this.appendResult('=== Starting Auto Write (RUM) ===\n');
    this.appendResult('Make sure your phone is disconnected from network.\n\n');

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
        
        if (count % AUTO_RUM_STATUS_INTERVAL === 0) {
          this.updatePolicyInfo();
          this.refreshActualDbCounts(false);
          this.appendResult(`Written ${this.writeCount} RUM data, DB Size: ${this.currentDbSize}\n`);
          const stopReason = this.getAutoStopReason(DataType.RUM_APP);
          if (stopReason.length > 0) {
            this.stopAutoWrite(stopReason);
          }
        }
      } catch (error) {
        this.appendResult(`Error writing RUM data: ${error}\n`);
        this.stopAutoWrite();
      }
    }, 200); // Write once every 200 ms (2 RUM items each time)
  }

  /**
   * Stop auto writing
   */
  private stopAutoWrite(reason: string = '') {
    if (this.writeTimer !== -1) {
      clearInterval(this.writeTimer);
      this.writeTimer = -1;
    }
    this.autoWriteEnabled = false;
    if (reason.length > 0) {
      this.appendResult(`\n=== Auto Write Stopped: ${reason} (Total: ${this.writeCount} items) ===\n`);
    } else {
      this.appendResult(`\n=== Stopped Auto Write (Total: ${this.writeCount} items) ===\n`);
    }
    this.updatePolicyInfo();
  }

  private async clearCachedDb() {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }
      this.appendResult('\n=== Clearing Cached DB ===\n');
      await FTSDK.clearAllData();
      this.writeCount = 0;
      this.limitReachedNoticeShown = false;
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`Cleared cached DB. Actual DB Count: Log=${this.actualLogDbCountText}, RUM=${this.actualRumDbCountText}\n`);
    } catch (error) {
      this.appendResult(`Clear cached DB failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
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
        FTLogger.logBackground(logMessage, Status.INFO, undefined, true);
      }
      
      this.writeCount += count;
      this.appendResult(`Written ${count} logs\n`);
      
      // Delay the database size update
      setTimeout(async () => {
        await this.refreshActualDbCounts(true);
        this.updatePolicyInfo();
        this.isRunning = false;
      }, 500);
      
    } catch (error) {
      this.appendResult(`Failed to write logs: ${error}\n`);
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
      this.appendResult(`Written ${count * 2} RUM data\n`);
      
      // Delay the database size update
      setTimeout(async () => {
        await this.refreshActualDbCounts(true);
        this.updatePolicyInfo();
        this.isRunning = false;
      }, 500);
      
    } catch (error) {
      this.appendResult(`Failed to write RUM data: ${error}\n`);
      this.isRunning = false;
    }
  }

  private async refreshActualDbCounts(force: boolean = false): Promise<void> {
    const now = Date.now();
    if (this.dbMetricsRefreshing) {
      return;
    }
    if (!force && now - this.lastDbMetricsRefreshTime < DB_METRICS_REFRESH_INTERVAL_MS) {
      return;
    }
    this.dbMetricsRefreshing = true;
    this.lastDbMetricsRefreshTime = now;
    try {
      const dbManager = FTDBManager.getInstance(this.context);
      const actualDbSize = await dbManager.getCurrentDatabaseSize();
      const logDbCount = await dbManager.queryTotalCount([DataType.LOG]);
      const rumDbCount = await this.getRumDbCount();
      FTDBCachePolicy.getInstance().setCurrentDbSize(actualDbSize);
      this.currentDbSize = this.formatBytes(actualDbSize);
      this.dbLimitReached = FTDBCachePolicy.getInstance().isReachDbLimit();
      this.actualLogDbCountText = `${logDbCount}`;
      this.actualRumDbCountText = `${rumDbCount}`;
    } catch (error) {
      this.actualLogDbCountText = 'error';
      this.actualRumDbCountText = 'error';
      DemoLogger.e(TAG, `refreshActualDbCounts failed: ${error}`);
    } finally {
      this.dbMetricsRefreshing = false;
    }
  }

  private appendLimitReachedNotice(): void {
    if (!this.autoWriteEnabled) {
      return;
    }
    const stopReason = this.getAutoStopReason(this.autoWriteDataType);
    if (stopReason.length === 0) {
      this.limitReachedNoticeShown = false;
      return;
    }
    if (this.limitReachedNoticeShown) {
      return;
    }
    this.limitReachedNoticeShown = true;
    this.appendResult(`${stopReason}. Current DB Size: ${this.currentDbSize}, RUM Count: ${this.rumCountText}, Log Count: ${this.logCountText}\n`);
  }

  private getAutoStopReason(dataType: DataType): string {
    const cachePolicy = FTDBCachePolicy.getInstance();
    if (cachePolicy.isEnableLimitWithDbSize()) {
      if (cachePolicy.isReachDbLimit() && cachePolicy.getDBCacheDiscard() === 'discard') {
        return 'DB size limit reached with DISCARD strategy';
      }
      return '';
    }

    if (dataType === DataType.LOG &&
      cachePolicy.isReachLogLimit() &&
      String(cachePolicy.getDiscardStrategy(DataType.LOG)) === 'discard') {
      return 'Log count limit reached with DISCARD strategy';
    }

    if ((dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) &&
      cachePolicy.isReachRumLimit() &&
      String(cachePolicy.getDiscardStrategy(DataType.RUM_APP)) === 'discard') {
      return 'RUM count limit reached with DISCARD strategy';
    }

    return '';
  }

  private async getRumDbCount(): Promise<number> {
    const dbManager = FTDBManager.getInstance(this.context);
    return await dbManager.queryTotalCount([DataType.RUM_APP, DataType.RUM_WEBVIEW]);
  }

  private async queryRumDbSamples(limit: number, newestFirst: boolean): Promise<SyncData[]> {
    const dbManager = FTDBManager.getInstance(this.context);
    return await dbManager.queryFtOperation([DataType.RUM_APP, DataType.RUM_WEBVIEW], limit, newestFirst);
  }

  private async queryLogDbSamples(limit: number, newestFirst: boolean): Promise<SyncData[]> {
    const dbManager = FTDBManager.getInstance(this.context);
    return await dbManager.queryFtOperation([DataType.LOG], limit, newestFirst);
  }

  private containsMarker(dataList: SyncData[], marker: string): boolean {
    for (const data of dataList) {
      if (data.getDataString().indexOf(marker) >= 0) {
        return true;
      }
    }
    return false;
  }

  private getDataSummary(data: SyncData | undefined): string {
    if (!data) {
      return 'empty';
    }
    const dataString = data.getDataString();
    const snippet = dataString.length > 120 ? `${dataString.substring(0, 120)}...` : dataString;
    return `uuid=${data.getUuid()}, time=${data.getTime()}, data=${snippet}`;
  }

  private waitForWriteSettled(delayMs: number = 800): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, delayMs);
    });
  }

  private findMissingMarkers(dataList: SyncData[], markers: string[]): string[] {
    const missing: string[] = [];
    for (const marker of markers) {
      if (!this.containsMarker(dataList, marker)) {
        missing.push(marker);
      }
    }
    return missing;
  }

  private async waitForLogMarkers(markers: string[], timeoutMs: number): Promise<string[]> {
    const startTime = Date.now();
    let missing = markers;
    const queryLimit = markers.length + 200;

    while (Date.now() - startTime < timeoutMs) {
      const samples = await this.queryLogDbSamples(queryLimit, true);
      missing = this.findMissingMarkers(samples, markers);
      if (missing.length === 0) {
        return missing;
      }
      await this.waitForWriteSettled(500);
    }

    const samples = await this.queryLogDbSamples(queryLimit, true);
    return this.findMissingMarkers(samples, markers);
  }

  private buildLogMarkers(prefix: string, count: number): string[] {
    const markers: string[] = [];
    for (let i = 0; i < count; i++) {
      markers.push(`${prefix}_${i}`);
    }
    return markers;
  }

  private appendMarkerCheckResult(label: string, producedCount: number, missing: string[]): void {
    const foundCount = producedCount - missing.length;
    this.appendResult(`${label} Produced: ${producedCount}\n`);
    this.appendResult(`${label} Found In DB: ${foundCount}\n`);
    this.appendResult(`${label} Missing: ${missing.length}\n`);
    if (missing.length > 0) {
      const preview = missing.slice(0, 20).join(', ');
      this.appendResult(`${label} Missing Preview: ${preview}${missing.length > 20 ? ', ...' : ''}\n`);
    }
  }

  private createDirectLogData(marker: string): SyncData {
    const data = new SyncData(DataType.LOG);
    data.setUuid(marker);
    data.setTime(Date.now());
    data.setDataString(`no_lock_db_race,source=demo,sdk_data_id=${marker} message="${marker}"`);
    return data;
  }

  private async insertDirectLogMarkers(markers: string[]): Promise<number> {
    const dbManager = FTDBManager.getInstance(this.context);
    let successCount = 0;
    for (const marker of markers) {
      const success = await dbManager.insertFtOperation(this.createDirectLogData(marker), true);
      if (success) {
        successCount++;
      }
    }
    this.writeCount += successCount;
    return successCount;
  }

  private async findDirectLogMissing(markers: string[]): Promise<string[]> {
    const samples = await this.queryLogDbSamples(markers.length + 200, true);
    return this.findMissingMarkers(samples, markers);
  }

  private async verifyNoLockDbRace(): Promise<void> {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }

      const runId = `NoLockRace_${Date.now()}`;
      const baselineMarkers = this.buildLogMarkers(`${runId}_baseline`, NO_LOCK_DB_RACE_BASELINE_COUNT);
      const raceMarkers = this.buildLogMarkers(`${runId}_race`, NO_LOCK_DB_RACE_LOG_COUNT);
      const beforeShutdownMarkers = raceMarkers.slice(0, NO_LOCK_DB_RACE_BEFORE_SHUTDOWN_COUNT);
      const afterShutdownMarkers = raceMarkers.slice(NO_LOCK_DB_RACE_BEFORE_SHUTDOWN_COUNT);

      this.appendResult(`\n=== Verify No-Lock DB Race ===\n`);
      this.appendResult(`Run ID: ${runId}\n`);
      this.appendResult('This simulates the old no-lock DB shutdown path: close the DB without the write lock and keep the stale helper connection.\n');
      this.appendResult(`Baseline: direct-writing ${NO_LOCK_DB_RACE_BASELINE_COUNT} markers before unsafe shutdown...\n`);

      await FTSDK.clearAllData();
      DbInternalTestAccess.resetDbManagerInstance();
      await this.waitForWriteSettled();
      const baselineSuccess = await this.insertDirectLogMarkers(baselineMarkers);
      const baselineMissing = await this.findDirectLogMissing(baselineMarkers);
      this.appendResult(`Baseline Insert Success: ${baselineSuccess}/${NO_LOCK_DB_RACE_BASELINE_COUNT}\n`);
      this.appendMarkerCheckResult('Baseline', NO_LOCK_DB_RACE_BASELINE_COUNT, baselineMissing);
      if (baselineMissing.length > 0) {
        await this.refreshActualDbCounts(true);
        this.updatePolicyInfo();
        this.appendResult('Result: FAIL. Baseline direct insert already missed data, so no-lock race verification is not reliable.\n');
        return;
      }

      this.appendResult(`Race: writing ${beforeShutdownMarkers.length} markers, then simulating unsafe no-lock shutdown, then writing ${afterShutdownMarkers.length} more markers...\n`);
      await FTSDK.clearAllData();
      DbInternalTestAccess.resetDbManagerInstance();
      await this.waitForWriteSettled();
      const beforeSuccess = await this.insertDirectLogMarkers(beforeShutdownMarkers);
      await DbInternalTestAccess.simulateNoLockDbShutdown(this.context);
      const afterSuccess = await this.insertDirectLogMarkers(afterShutdownMarkers);

      DbInternalTestAccess.clearNoLockDbShutdownSimulation(this.context);
      DbInternalTestAccess.resetDbManagerInstance();
      await this.waitForWriteSettled();
      const raceMissing = await this.findDirectLogMissing(raceMarkers);
      const raceFoundCount = NO_LOCK_DB_RACE_LOG_COUNT - raceMissing.length;

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`Before Unsafe Shutdown Insert Success: ${beforeSuccess}/${beforeShutdownMarkers.length}\n`);
      this.appendResult(`After Unsafe Shutdown Insert Success: ${afterSuccess}/${afterShutdownMarkers.length}\n`);
      this.appendResult(`Produced: ${NO_LOCK_DB_RACE_LOG_COUNT}\n`);
      this.appendResult(`Found In DB: ${raceFoundCount}\n`);
      this.appendResult(`Missing: ${raceMissing.length}\n`);
      if (raceMissing.length > 0) {
        const preview = raceMissing.slice(0, 20).join(', ');
        this.appendResult(`Missing Preview: ${preview}${raceMissing.length > 20 ? ', ...' : ''}\n`);
      }
      if (raceFoundCount > 0 && raceMissing.length > 0) {
        this.appendResult('Result: PASS. Reproduced the old partial-loss shape: some records persisted before unsafe shutdown, later records were lost by stale closed DB connection.\n');
      } else if (raceMissing.length === 0) {
        this.appendResult('Result: CHECK. No missing records were reproduced; retry or increase marker count.\n');
      } else {
        this.appendResult('Result: CHECK. All race markers are missing, which is not the expected partial-loss shape.\n');
      }
    } catch (error) {
      this.appendResult(`Verify No-Lock DB Race failed: ${error}\n`);
    } finally {
      DbInternalTestAccess.clearNoLockDbShutdownSimulation(this.context);
      DbInternalTestAccess.resetDbManagerInstance();
      this.isRunning = false;
    }
  }

  private async writeLogMarkersInBatches(markers: string[], batchSize: number, delayMs: number): Promise<void> {
    for (let start = 0; start < markers.length; start += batchSize) {
      const end = Math.min(markers.length, start + batchSize);
      for (let i = start; i < end; i++) {
        FTLogger.logBackground(markers[i], Status.INFO, undefined, true);
      }
      FTLogger.flush();
      await this.waitForWriteSettled(delayMs);
    }
  }

  private async runDbShutdownRace(attempts: number, intervalMs: number): Promise<number> {
    const dbManager = FTDBManager.getInstance(this.context);
    let completedCount = 0;
    for (let i = 0; i < attempts; i++) {
      await this.waitForWriteSettled(intervalMs);
      try {
        await dbManager.shutDown();
        completedCount++;
      } catch (error) {
        this.appendResult(`DB shutdown attempt ${i + 1} failed: ${error}\n`);
      }
    }
    return completedCount;
  }

  private async verifyLogDataLossWithDbShutdown(): Promise<void> {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }

      const runId = `ShutdownRace_${Date.now()}`;
      const baselineMarkers = this.buildLogMarkers(`${runId}_baseline`, DB_SHUTDOWN_RACE_BASELINE_COUNT);
      const raceMarkers = this.buildLogMarkers(`${runId}_race`, DB_SHUTDOWN_RACE_LOG_COUNT);
      const recoveryMarkers = this.buildLogMarkers(`${runId}_recovery`, DB_SHUTDOWN_RACE_RECOVERY_COUNT);

      this.appendResult(`\n=== Verify DB Shutdown Race (Logs) ===\n`);
      this.appendResult(`Run ID: ${runId}\n`);
      this.appendResult(`Baseline: writing ${DB_SHUTDOWN_RACE_BASELINE_COUNT} markers without DB shutdown...\n`);

      await this.writeLogMarkersInBatches(baselineMarkers, DB_SHUTDOWN_RACE_BATCH_SIZE, DB_SHUTDOWN_RACE_INTERVAL_MS);
      this.writeCount += DB_SHUTDOWN_RACE_BASELINE_COUNT;
      FTLogger.flush();
      const baselineMissing = await this.waitForLogMarkers(baselineMarkers, DATA_LOSS_VERIFY_TIMEOUT_MS);
      this.appendMarkerCheckResult('Baseline', DB_SHUTDOWN_RACE_BASELINE_COUNT, baselineMissing);
      if (baselineMissing.length > 0) {
        await this.refreshActualDbCounts(true);
        this.updatePolicyInfo();
        this.appendResult('Result: FAIL. Baseline write already missed data, so shutdown race verification is not reliable.\n');
        return;
      }

      this.appendResult(`Race: writing ${DB_SHUTDOWN_RACE_LOG_COUNT} markers while calling DB shutDown ${DB_SHUTDOWN_RACE_ATTEMPTS} times...\n`);
      const shutdownTask = this.runDbShutdownRace(DB_SHUTDOWN_RACE_ATTEMPTS, DB_SHUTDOWN_RACE_INTERVAL_MS);
      await this.writeLogMarkersInBatches(raceMarkers, DB_SHUTDOWN_RACE_BATCH_SIZE, DB_SHUTDOWN_RACE_INTERVAL_MS);
      const shutdownCompleted = await shutdownTask;
      this.writeCount += DB_SHUTDOWN_RACE_LOG_COUNT;
      FTLogger.flush();
      const raceMissing = await this.waitForLogMarkers(raceMarkers, DATA_LOSS_VERIFY_TIMEOUT_MS);

      this.appendResult(`Recovery: waiting ${DB_SHUTDOWN_RACE_RECOVERY_DELAY_MS}ms, then writing ${DB_SHUTDOWN_RACE_RECOVERY_COUNT} markers after shutdown race...\n`);
      await this.waitForWriteSettled(DB_SHUTDOWN_RACE_RECOVERY_DELAY_MS);
      await this.writeLogMarkersInBatches(recoveryMarkers, DB_SHUTDOWN_RACE_BATCH_SIZE, DB_SHUTDOWN_RACE_INTERVAL_MS);
      this.writeCount += DB_SHUTDOWN_RACE_RECOVERY_COUNT;
      FTLogger.flush();
      const recoveryMissing = await this.waitForLogMarkers(recoveryMarkers, DATA_LOSS_VERIFY_TIMEOUT_MS);

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`DB Shutdown Completed: ${shutdownCompleted}/${DB_SHUTDOWN_RACE_ATTEMPTS}\n`);
      this.appendMarkerCheckResult('Race', DB_SHUTDOWN_RACE_LOG_COUNT, raceMissing);
      this.appendMarkerCheckResult('Recovery', DB_SHUTDOWN_RACE_RECOVERY_COUNT, recoveryMissing);
      if (raceMissing.length === 0 && recoveryMissing.length === 0) {
        this.appendResult('Result: PASS. Race and recovery markers were found in DB.\n');
      } else if (raceMissing.length > 0 && recoveryMissing.length === 0) {
        this.appendResult('Result: FAIL. Concurrent DB shutdown reproduced missing race markers, and later writes recovered.\n');
      } else {
        this.appendResult('Result: CHECK. DB did not fully recover after shutdown race; review Recovery Missing output.\n');
      }
    } catch (error) {
      this.appendResult(`Verify DB Shutdown Race failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async verifyLogQueueOverflowLoss(): Promise<void> {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }

      const runId = `QueueOverflowLoss_${Date.now()}`;
      const baselineMarkers = this.buildLogMarkers(`${runId}_baseline`, LOG_QUEUE_LOSS_BASELINE_COUNT);
      const lossMarkers = this.buildLogMarkers(`${runId}_loss`, LOG_QUEUE_LOSS_LOG_COUNT);
      const recoveryMarkers = this.buildLogMarkers(`${runId}_recovery`, LOG_QUEUE_LOSS_RECOVERY_COUNT);

      this.appendResult(`\n=== Verify Log Queue Overflow Loss ===\n`);
      this.appendResult(`Run ID: ${runId}\n`);
      this.appendResult(`Baseline: writing ${LOG_QUEUE_LOSS_BASELINE_COUNT} markers before loss scenario...\n`);
      await this.writeLogMarkersInBatches(baselineMarkers, DB_SHUTDOWN_RACE_BATCH_SIZE, DB_SHUTDOWN_RACE_INTERVAL_MS);
      this.writeCount += LOG_QUEUE_LOSS_BASELINE_COUNT;
      FTLogger.flush();

      const baselineMissing = await this.waitForLogMarkers(baselineMarkers, DATA_LOSS_VERIFY_TIMEOUT_MS);
      this.appendMarkerCheckResult('Baseline', LOG_QUEUE_LOSS_BASELINE_COUNT, baselineMissing);
      if (baselineMissing.length > 0) {
        await this.refreshActualDbCounts(true);
        this.updatePolicyInfo();
        this.appendResult('Result: FAIL. Baseline write already missed data, so loss scenario verification is not reliable.\n');
        return;
      }

      this.appendResult(`Overflow Scenario: writing ${LOG_QUEUE_LOSS_LOG_COUNT} markers without waiting.\n`);
      this.appendResult(`Expected queue capacity is about ${LOG_QUEUE_LOSS_EXPECTED_QUEUE_CAPACITY}, so this should reproduce partial loss instead of all loss.\n`);
      for (const marker of lossMarkers) {
        FTLogger.logBackground(marker, Status.INFO, undefined, true);
      }
      this.writeCount += LOG_QUEUE_LOSS_LOG_COUNT;
      FTLogger.flush();

      const lossMissing = await this.waitForLogMarkers(lossMarkers, LOG_QUEUE_LOSS_TIMEOUT_MS);
      this.appendMarkerCheckResult('Overflow Scenario', LOG_QUEUE_LOSS_LOG_COUNT, lossMissing);

      this.appendResult(`Recovery: writing ${LOG_QUEUE_LOSS_RECOVERY_COUNT} markers after overflow scenario...\n`);
      await this.writeLogMarkersInBatches(recoveryMarkers, DB_SHUTDOWN_RACE_BATCH_SIZE, DB_SHUTDOWN_RACE_INTERVAL_MS);
      this.writeCount += LOG_QUEUE_LOSS_RECOVERY_COUNT;
      FTLogger.flush();
      const recoveryMissing = await this.waitForLogMarkers(recoveryMarkers, DATA_LOSS_VERIFY_TIMEOUT_MS);

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendMarkerCheckResult('Recovery', LOG_QUEUE_LOSS_RECOVERY_COUNT, recoveryMissing);
      if (lossMissing.length > 0 && lossMissing.length < LOG_QUEUE_LOSS_LOG_COUNT && recoveryMissing.length === 0) {
        this.appendResult('Result: PASS. Expected partial queue overflow loss was reproduced, and later writes recovered.\n');
      } else if (lossMissing.length === 0 && recoveryMissing.length === 0) {
        this.appendResult('Result: CHECK. Queue overflow loss was not reproduced; increase produced count or reduce queue capacity.\n');
      } else if (lossMissing.length === LOG_QUEUE_LOSS_LOG_COUNT) {
        this.appendResult('Result: FAIL. All overflow markers are missing, which is not the expected partial-loss shape.\n');
      } else {
        this.appendResult('Result: FAIL. Recovery markers are missing after overflow scenario.\n');
      }
    } catch (error) {
      this.appendResult(`Verify Log Queue Overflow Loss failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private writeRumMarker(marker: string): void {
    FTRUMGlobalManager.getInstance().addAction(marker, 'click');
    this.writeCount += 1;
  }

  private async verifyRumDiscardAtLimit(): Promise<void> {
    this.isRunning = true;
    try {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD);
      this.updatePolicyInfo();
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();

      const beforeCount = await this.getRumDbCount();
      const limitCount = cachePolicy.getRumLimitCount();
      this.appendResult('\n=== Verify RUM DISCARD ===\n');
      this.appendResult(`Before DB Count: ${beforeCount}, Limit: ${limitCount}\n`);

      if (beforeCount < limitCount) {
        this.appendResult('RUM count has not reached limit yet. Generate RUM data until the limit is reached, then run this verification again.\n');
        return;
      }

      const marker = `RumDiscard_${Date.now()}`;
      this.writeRumMarker(marker);
      await this.waitForWriteSettled();

      const afterCount = await this.getRumDbCount();
      const latestSamples = await this.queryRumDbSamples(20, true);
      const markerExists = this.containsMarker(latestSamples, marker);

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`After DB Count: ${afterCount}\n`);
      this.appendResult(`New Marker: ${marker}\n`);
      this.appendResult(`Marker Exists In Latest DB Samples: ${markerExists}\n`);
      this.appendResult(afterCount === beforeCount && !markerExists
        ? 'Result: PASS. DISCARD dropped the new RUM data and DB count did not grow.\n'
        : 'Result: CHECK. DB count or latest samples changed; confirm upload/network state and retry while offline.\n');
    } catch (error) {
      this.appendResult(`Verify RUM DISCARD failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async verifyRumDiscardOldestAtLimit(): Promise<void> {
    this.isRunning = true;
    try {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST);
      this.updatePolicyInfo();
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();

      const beforeCount = await this.getRumDbCount();
      const limitCount = cachePolicy.getRumLimitCount();
      const oldestBefore = (await this.queryRumDbSamples(1, false))[0];
      this.appendResult('\n=== Verify RUM DISCARD_OLDEST ===\n');
      this.appendResult(`Before DB Count: ${beforeCount}, Limit: ${limitCount}\n`);
      this.appendResult(`Oldest Before: ${this.getDataSummary(oldestBefore)}\n`);

      if (beforeCount < limitCount) {
        this.appendResult('RUM count has not reached limit yet. Generate RUM data until the limit is reached, then run this verification again.\n');
        return;
      }

      const marker = `RumOldest_${Date.now()}`;
      this.writeRumMarker(marker);
      await this.waitForWriteSettled();

      const afterCount = await this.getRumDbCount();
      const oldestAfter = (await this.queryRumDbSamples(1, false))[0];
      const latestSamples = await this.queryRumDbSamples(20, true);
      const markerExists = this.containsMarker(latestSamples, marker);
      const oldestChanged = !!oldestBefore && !!oldestAfter && oldestBefore.getUuid() !== oldestAfter.getUuid();

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`After DB Count: ${afterCount}\n`);
      this.appendResult(`Oldest After: ${this.getDataSummary(oldestAfter)}\n`);
      this.appendResult(`New Marker: ${marker}\n`);
      this.appendResult(`Marker Exists In Latest DB Samples: ${markerExists}\n`);
      this.appendResult(`Oldest Record Changed: ${oldestChanged}\n`);
      this.appendResult(markerExists && oldestChanged
        ? 'Result: PASS. DISCARD_OLDEST kept the new RUM data and removed the previous oldest cache record.\n'
        : 'Result: CHECK. Expected newest marker and oldest record replacement; confirm upload/network state and retry while offline.\n');
    } catch (error) {
      this.appendResult(`Verify RUM DISCARD_OLDEST failed: ${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  /**
   * Append a test result
   */
  private appendResult(text: string) {
    this.testResults += text;
    const lines = this.testResults.split('\n');
    if (lines.length > MAX_RESULT_LINES) {
      this.testResults = lines.slice(lines.length - MAX_RESULT_LINES).join('\n');
    }
    if (text.trim().length > 0) {
      DemoLogger.i(TAG, text.trim());
    }
  }

  /**
   * Clear the visible test results.
   */
  private clearResults() {
    this.testResults = '';
    DemoLogger.i(TAG, 'Test results cleared');
  }
}
