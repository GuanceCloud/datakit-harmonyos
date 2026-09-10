import { FTDBCachePolicy } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBCachePolicy';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { FTDBTaskPoolExecutor } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBTaskPoolExecutor';
import { FTCacheContext } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTCacheContext';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { Constants } from '@guancecloud/ft_sdk/src/main/ets/components/Constants';
import { DbInternalTestAccess } from '@guancecloud/ft_sdk/src/main/ets/components/internal/testaccess/DbInternalTestAccess';
import { FTInnerLogFileManager } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTInnerLogFileManager';
import { TrackLogManager } from '@guancecloud/ft_sdk/src/main/ets/components/log/TrackLogManager';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import {
  SDKDedicatedPoolManager,
  SDKDedicatedPoolStatus
} from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKWorkerProtocol';
import { DeviceUtils } from '@guancecloud/ft_sdk/src/main/ets/components/utils/DeviceUtils';
import {
  AppState,
  ErrorType,
  FTRUMGlobalManager,
  FTLogger,
  FTSDK,
  NetStatusBean,
  ResourceParams,
  RUMCacheDiscard,
  Status
} from '@guancecloud/ft_sdk/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
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
const PHYSICAL_LIMIT_PROBE_LOG_COUNT = 50;
const PHYSICAL_LIMIT_PROBE_RUM_COUNT = 20;
const PHYSICAL_LIMIT_PROBE_SETTLE_MS = 5000;
const LARGE_PHYSICAL_LIMIT_PROBE_LOG_COUNT = 1000;
const LARGE_PHYSICAL_LIMIT_PROBE_RUM_COUNT = 400;
const LARGE_PHYSICAL_LIMIT_PROBE_BATCH_SIZE = 50;
const LARGE_PHYSICAL_LIMIT_PROBE_BATCH_DELAY_MS = 0;
const LARGE_PHYSICAL_LIMIT_PROBE_SETTLE_MS = 15000;
const PHYSICAL_LIMIT_PROBE_POLL_MS = 500;
const SDK_LOG_FLUSH_BATCH_SIZE = 20;
const SDK_LOG_PROCESS_COALESCE_MS = 100;
const SDK_UPLOAD_MAX_PAGES_RUM_APP = 2;
const SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW = 1;
const SDK_UPLOAD_MAX_PAGES_LOG = 1;
const DEFAULT_EVENT_COST_MS = 50;
const DEFAULT_DATA_PROCESS_COST_MS = 50;
const DEFAULT_UPLOAD_COST_MS = 1000;
const DEFAULT_INNER_LOG_FILE_COST_MS = 50;
const SINGLE_LANE_BENCH_TASK_COUNT = 1000;
const SINGLE_LANE_BENCH_COST_TASK_COUNT = 300;
const SINGLE_LANE_BENCH_UPLOAD_TASK_COUNT = 200;
const DB_WRITE_CAPABILITY_BATCHES_PER_CASE = 100;
const DB_WRITE_CAPABILITY_BATCH_SIZES: number[] = [1, 10, 20, 50];
const DB_WRITE_CAPABILITY_SETTLE_MS = 200;
const PHASE_ONE_LOG_BATCH_COUNT = 64;
const PHASE_ONE_LOG_PAYLOAD_BYTES = 16 * 1024;
const PHASE_ONE_LOG_BATCH_BYTES = PHASE_ONE_LOG_BATCH_COUNT * PHASE_ONE_LOG_PAYLOAD_BYTES;
const PHASE_ONE_SETTLE_MS = 1500;

interface PhysicalProbeDrainResult {
  logMissing: string[];
  rumMissing: string[];
  elapsedMs: number;
  completed: boolean;
}

interface SingleLaneBenchmarkCase {
  label: string;
  poolType: SDKDedicatedPoolType;
  taskCount: number;
  taskCostMs: number;
}

interface SyntheticPoolPingPayload {
  syntheticCostMs: number;
}

interface UnifiedCacheUsageSnapshot {
  fileBytes: number;
  sqliteBytes: number;
  legacyFileBytes: number;
  spoolBytes: number;
  totalBytes: number;
  governedBytes: number;
  governedScope: string;
  capacityBytes: number;
  overLimit: boolean;
}

interface UnifiedCacheStatusSnapshot {
  mode: string;
  directUpload: boolean;
  sqliteReleased: boolean;
  usage: UnifiedCacheUsageSnapshot;
  migration: string;
  syncCount: number;
  viewCount: number;
  actionCount: number;
  oldestUuids: string[];
  evicted: number;
  rejected: number;
  corrupt: number;
  projectionPending: boolean;
  shadowHealthy: boolean;
}

interface PhaseOneSnapshot {
  label: string;
  capturedAt: number;
  status: UnifiedCacheStatusSnapshot;
  oldestSyncFilesPresent: boolean[];
}

/** Historical `ft_sdk_file_store/*.ndjson` payload shape. */
interface LegacyFileStoreSyncData {
  id: number;
  dataType: DataType;
  dataString: string;
  uuid: string;
  time: number;
  customDataTypeString: string;
}

interface LegacyFileStoreRecord {
  source: string;
  seq: number;
  createdAt: number;
  data: LegacyFileStoreSyncData;
}

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
  @State phaseOneSummary: string = 'No Phase 1 baseline saved.';
  @State phaseOnePreflightProgress: string = '';
  @State cacheClearProgress: string = '';
  @State phaseOneViewActive: boolean = false;
  /** Last mode confirmed by a unified-cache snapshot. */
  @State capacityUsageMode: string = '';
  private context: Context = getContext(this) as Context;
  private writeTimer: number = -1;
  private infoTimer: number = -1;
  private phaseOnePreflightWaitTimer: number = -1;
  private cacheClearWaitTimer: number = -1;
  private resultFlushTimer: number = -1;
  private resultLines: string[] = [];
  private dbMetricsRefreshing: boolean = false;
  private lastDbMetricsRefreshTime: number = 0;
  private limitReachedNoticeShown: boolean = false;
  private autoWriteDataType: DataType = DataType.LOG;
  private phaseOneBaseline: PhaseOneSnapshot | null = null;
  private phaseOneLastMarker: string = '';
  private phaseOneActiveViewName: string = '';

  aboutToAppear() {
    if (this.infoTimer !== -1) {
      clearInterval(this.infoTimer);
      this.infoTimer = -1;
    }
    this.stopPhaseOnePreflightProgress();
    this.stopCacheClearProgress();
    // this.applyPageLoadCacheConfig();
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
    this.stopPhaseOnePreflightProgress();
    this.stopCacheClearProgress();
    if (this.resultFlushTimer !== -1) {
      clearTimeout(this.resultFlushTimer);
      this.resultFlushTimer = -1;
    }
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        TestPageHeader({
          title: 'Database Cache Limit Test'
        })

        Column({ space: 10 }) {
          Text('当前生效的缓存策略')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text(`生效模式：${this.effectivePolicy}`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#007DFF')
            .width('100%')

          Text(`${this.getCapacityUsageLabel()}：${this.currentDbSize}`)
            .fontSize(15)
            .width('100%')

          Text(this.getCapacityUsageHint())
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')

          Divider()
            .width('100%')
            .margin({ top: 4, bottom: 4 })

          Text(`统一缓存容量管控：${this.dbCacheEnabled ? '已启用' : '未启用'} | 上限：${this.dbCacheLimit} | 已触达：${this.dbLimitReached ? '是' : '否'}`)
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

          Text(`主库记录数：Log=${this.actualLogDbCountText}, RUM=${this.actualRumDbCountText}`)
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
          Text('容量、聚合与持久化闭环')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text('正式配置为 30 MiB 容量与 discard_oldest。容量测试时请断网或暂停上传；FileStore、影子模式、ACK/强杀属于独立专项场景。')
            .fontSize(12)
            .fontColor('#666666')
            .width('100%')

          Text(this.phaseOneSummary)
            .fontSize(13)
            .fontColor('#0A5A2A')
            .width('100%')

          if (this.phaseOnePreflightProgress.length > 0) {
            Text(`预检状态：${this.phaseOnePreflightProgress}`)
              .fontSize(13)
              .fontColor(this.isRunning ? '#8A5A00' : '#0A5A2A')
              .width('100%')
          }

          Button('Preflight and Save Baseline')
            .width('100%')
            .height(44)
            .backgroundColor('#00695C')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.preparePhaseOneBaseline();
            })

          Button('Write ~1 MiB Tagged Logs')
            .width('100%')
            .height(44)
            .backgroundColor('#007DFF')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.writePhaseOneLogBatch();
            })

          Button('Compare Eviction / Rejection with Baseline')
            .width('100%')
            .height(44)
            .backgroundColor('#7B1FA2')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.comparePhaseOneBaseline();
            })

          Button('Force DB Failure and Check Spool')
            .width('100%')
            .height(44)
            .backgroundColor('#C62828')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.verifyPhaseOneSpoolFallback();
            })

          Button(this.phaseOneViewActive ? 'End Aggregation View' : 'Create View / Action / Resource')
            .width('100%')
            .height(44)
            .backgroundColor('#1565C0')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              if (this.phaseOneViewActive) {
                this.finishPhaseOneAggregation();
              } else {
                this.startPhaseOneAggregation();
              }
            })

          Button('Check Shadow Mode Status')
            .width('100%')
            .height(44)
            .backgroundColor('#5D4037')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.inspectPhaseOneShadowMode();
            })

          Button('Create 3 Legacy File-Cache Records and Verify Migration')
            .width('100%')
            .height(44)
            .backgroundColor('#8D6E63')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.createAndVerifyLegacyFileStoreFixture();
            })

          Button('Print Unified Cache Details')
            .width('100%')
            .height(44)
            .backgroundColor('#455A64')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.inspectUnifiedCache('手动检查');
            })
        }
        .padding(16)
        .backgroundColor('#E8F5E9')
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
                this.stopAutoWriteAndDrain();
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
                this.stopAutoWriteAndDrain();
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

          Button('Inspect Unified Cache')
            .width('100%')
            .height(44)
            .onClick(() => {
              this.inspectUnifiedCache('手动检查');
            })

          if (this.cacheClearProgress.length > 0) {
            Text(`清空状态：${this.cacheClearProgress}`)
              .fontSize(13)
              .fontColor(this.isRunning ? '#8A5A00' : '#0A5A2A')
              .width('100%')
          }

          Button('Clear All Cached Data')
            .width('100%')
            .height(44)
            .backgroundColor('#DC3545')
            .enabled(!this.isRunning)
            .onClick(() => {
              this.clearAllCacheData();
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

          Button('Test Unified Cache Capacity')
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

          Button('Measure Device/SDK Physical Ceiling')
            .width('100%')
            .height(48)
            .backgroundColor('#455A64')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSdkPhysicalLimitTest();
            })

          Button('Measure Device/SDK Physical Ceiling (Stress)')
            .width('100%')
            .height(48)
            .backgroundColor('#263238')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSdkPhysicalLimitTest(true);
            })

          Button('Benchmark DB Write Capability')
            .width('100%')
            .height(48)
            .backgroundColor('#00695C')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runDbWriteCapabilityBenchmark();
            })

          Button('Benchmark SDK Lanes')
            .width('100%')
            .height(48)
            .backgroundColor('#37474F')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSingleLaneBenchmarkSuite();
            })

          Button('Benchmark Event Lane')
            .width('100%')
            .height(44)
            .backgroundColor('#546E7A')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSingleLaneBenchmarkOnly({
                label: 'Event Lane No-op Serial',
                poolType: SDKDedicatedPoolType.EVENT_CONSUMER,
                taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
                taskCostMs: 0
              });
            })

          Button('Benchmark Data Lane')
            .width('100%')
            .height(44)
            .backgroundColor('#546E7A')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSingleLaneBenchmarkOnly({
                label: 'Data-Process Lane No-op Parallel',
                poolType: SDKDedicatedPoolType.DATA_PROCESS,
                taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
                taskCostMs: 0
              });
            })

          Button('Benchmark Data Lane (5ms)')
            .width('100%')
            .height(44)
            .backgroundColor('#546E7A')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSingleLaneBenchmarkOnly({
                label: 'Data-Process Lane 5ms Parallel',
                poolType: SDKDedicatedPoolType.DATA_PROCESS,
                taskCount: SINGLE_LANE_BENCH_COST_TASK_COUNT,
                taskCostMs: 5
              });
            })

          Button('Benchmark Upload Lane (10ms)')
            .width('100%')
            .height(44)
            .backgroundColor('#546E7A')
            .enabled(!this.autoWriteEnabled && !this.isRunning)
            .onClick(() => {
              this.runSingleLaneBenchmarkOnly({
                label: 'Upload Lane 10ms Serial',
                poolType: SDKDedicatedPoolType.DATA_UPLOAD,
                taskCount: SINGLE_LANE_BENCH_UPLOAD_TASK_COUNT,
                taskCostMs: 10
              });
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

  private async loadUnifiedCacheSnapshot(label: string): Promise<PhaseOneSnapshot> {
    const rawStatus = await DbInternalTestAccess.getCacheStatus(this.context);
    const status = JSON.parse(rawStatus) as UnifiedCacheStatusSnapshot;
    const oldestSyncFilesPresent: boolean[] = [];
    for (let i = 0; i < status.oldestUuids.length; i++) {
      oldestSyncFilesPresent.push(this.isFileStoreSyncPresent(status.oldestUuids[i]));
    }
    const snapshot: PhaseOneSnapshot = {
      label,
      capturedAt: Date.now(),
      status,
      oldestSyncFilesPresent
    };
    this.applyUnifiedCacheHeader(snapshot);
    return snapshot;
  }

  /** Keep the top capacity meter and its label on the same snapshot as details. */
  private applyUnifiedCacheHeader(snapshot: PhaseOneSnapshot): void {
    const usage = snapshot.status.usage;
    this.capacityUsageMode = snapshot.status.mode;
    // `updatePolicyInfo()` runs on a timer. Keep its in-memory policy value
    // aligned with this freshly queried snapshot so it cannot repaint a stale
    // size immediately after the user prints cache details.
    FTDBCachePolicy.getInstance().setCurrentDbSize(usage.governedBytes);
    this.currentDbSize = this.formatBytes(usage.governedBytes);
    this.dbCacheLimit = this.formatBytes(usage.capacityBytes);
    this.dbLimitReached = usage.overLimit;
  }

  private async inspectUnifiedCache(label: string): Promise<void> {
    try {
      const snapshot = await this.loadUnifiedCacheSnapshot(label);
      this.appendResult(`\n=== 统一缓存明细：${label} ===\n`);
      this.appendUnifiedCacheSnapshot(snapshot);
    } catch (error) {
      this.appendResult(`统一缓存检查失败：${error}\n`);
    }
  }

  /**
   * Creates data in the historical FileStore layout, rather than writing a
   * current cache record and merely relabelling it.  The migration reader uses
   * the same NDJSON envelope as the old DB-failure spool implementation.
   */
  private async createAndVerifyLegacyFileStoreFixture(): Promise<void> {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) { this.stopAutoWrite(); }
      const drained = await this.awaitCachePipelineDrained('旧文件缓存制造前排空');
      if (!drained) {
        this.appendResult('旧文件缓存制造已取消：日志邮箱尚未排空，避免与正在写入的数据交叉。\n');
        return;
      }
      const before = await this.loadUnifiedCacheSnapshot('制造旧文件缓存前');
      const legacyDir = `${this.context.filesDir}/ft_sdk_file_store`;
      const legacyPath = `${legacyDir}/sync_data.ndjson`;
      const now = Date.now();
      const fixtureUuids: string[] = [];
      const lines: string[] = [];
      for (let i = 0; i < 3; i++) {
        const uuid = `legacy-migration-fixture-${now}-${i + 1}`;
        fixtureUuids.push(uuid);
        const data: LegacyFileStoreSyncData = {
          id: now + i,
          dataType: DataType.LOG,
          dataString: `df_rum_harmonyos_log,source=legacy_migration_fixture message=\"legacy_migration_fixture_${now}_${i + 1}\" ${now + i}`,
          uuid,
          time: now + i,
          customDataTypeString: 'log'
        };
        const record: LegacyFileStoreRecord = {
          source: 'demo.legacy.migration.fixture', seq: i + 1, createdAt: now, data
        };
        lines.push(`${JSON.stringify(record)}\n`);
      }
      await this.appendLegacyNdjson(legacyDir, legacyPath, lines.join(''));
      this.appendResult(`\n=== 迁移专项：已制造旧文件缓存 ===\n路径：${legacyPath}\n记录数：3；UUID=${fixtureUuids.join(', ')}\n`);

      if (before.status.mode !== 'file') {
        this.appendResult('旧缓存已保留。当前不是 FileStore 主模式，不会自动迁移；请配置 enableFileDataStore().setNeedTransformOldCache(true) 并冷启动后验证。\n');
        return;
      }
      if (!FTCacheContext.settings.migrate) {
        this.appendResult('旧缓存已保留。当前未开启 setNeedTransformOldCache(true)，SDK 应拒绝迁移并保留该来源。\n');
        return;
      }

      // A completed migration is intentionally one-shot. Delete only its
      // checkpoint so this test source is handled exactly like a fresh upgrade.
      const migrationPath = `${this.context.filesDir}/ft_sdk_cache_v2/meta/migration.json`;
      try { fs.unlinkSync(migrationPath); } catch (_) { /* First migration has no checkpoint yet. */ }
      // Status inspection is read-only and deliberately does not start a
      // migration. Submit the FileStore init command through its normal lane
      // so this fixture follows the same path as a first FileStore launch.
      await FTDBTaskPoolExecutor.init(this.context);
      const after = await this.loadUnifiedCacheSnapshot('旧文件缓存迁移后');
      const allFixturesImported = fixtureUuids.every((uuid: string) => this.isFileStoreSyncPresent(uuid));
      const legacyCleared = after.status.usage.legacyFileBytes === 0;
      this.appendUnifiedCacheSnapshot(after);
      this.appendResult(`迁移结果：fixture 已导入=${allFixturesImported}，旧目录已清空=${legacyCleared}，migration=${after.status.migration}\n`);
      this.appendResult(allFixturesImported && legacyCleared && this.isMigrationCompleted(after.status)
        ? '迁移专项：通过。3 条旧 NDJSON 记录已进入 FileStore，且旧来源已在完成切换后删除。\n'
        : '迁移专项：未完全通过。旧来源已保留或记录未全部导入，请检查 migration 状态与错误日志。\n');
    } catch (error) {
      this.appendResult(`制造或迁移旧文件缓存失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async appendLegacyNdjson(directory: string, path: string, content: string): Promise<void> {
    let directoryExists = false;
    try {
      directoryExists = await fs.access(directory);
    } catch (_) {
      directoryExists = false;
    }
    if (!directoryExists) {
      try { await fs.mkdir(directory); }
      catch (error) {
        let created = false;
        try { created = await fs.access(directory); } catch (_) { created = false; }
        if (!created) {
          throw new Error(`LEGACY_FIXTURE_MKDIR_FAILED: ${directory}; ${String(error)}`);
        }
      }
    }
    let file: fs.File | null = null;
    try {
      file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      await fs.write(file.fd, content);
    } catch (error) {
      throw new Error(`LEGACY_FIXTURE_WRITE_FAILED: ${path}; ${String(error)}`);
    } finally {
      if (file !== null) { await fs.close(file); }
    }
  }

  private appendUnifiedCacheSnapshot(snapshot: PhaseOneSnapshot): void {
    const status = snapshot.status;
    const usage = status.usage;
    const summedBytes = usage.fileBytes + usage.sqliteBytes + usage.legacyFileBytes + usage.spoolBytes;
    const filesDir = this.context.filesDir || '(filesDir unavailable)';
    const databaseDir = this.context.databaseDir || '(databaseDir unavailable)';
    const modeDescription = status.mode === 'file'
      ? 'FileStore 主模式'
      : status.mode === 'shadow' ? 'SQLite 主库 + FileStore 影子模式' : 'SQLite 模式';

    this.appendResult(`快照：${snapshot.label}，时间=${new Date(snapshot.capturedAt).toISOString()}\n`);
    this.appendResult(`运行模式：${modeDescription}；migration=${status.migration}；projectionPending=${status.projectionPending}\n`);
    this.appendResult(`【FileStore】${filesDir}/ft_sdk_cache_v2，包含 sync / view / action / 元数据与事务 journal，共 ${this.formatBytes(usage.fileBytes)}\n`);
    this.appendResult(`【SQLite / WAL】${databaseDir} 下 SDK 数据库及同名前缀的 WAL / SHM，共 ${this.formatBytes(usage.sqliteBytes)}\n`);
    this.appendResult(`【旧文件缓存】${filesDir}/ft_sdk_file_store，共 ${this.formatBytes(usage.legacyFileBytes)}\n`);
    this.appendResult(`【失败 Spool】${filesDir}/ft_sdk_spool，DB 写失败后的待回放记录，共 ${this.formatBytes(usage.spoolBytes)}\n`);
    this.appendResult(`物理落盘总占用：total=${this.formatBytes(usage.totalBytes)}，分项求和=${this.formatBytes(summedBytes)}，${summedBytes === usage.totalBytes ? '一致' : '不一致'}\n`);
    this.appendResult(`容量策略计量：${usage.governedScope}=${this.formatBytes(usage.governedBytes)}，配置=${this.formatBytes(usage.capacityBytes)}，当前剩余=${this.formatBytes(Math.max(0, usage.capacityBytes - usage.governedBytes))}，overLimit=${usage.overLimit}\n`);
    if (status.mode === 'shadow') {
      this.appendResult('说明：影子模式会同时保留 SQLite 主库和 FileStore 镜像；物理落盘总占用包含两份数据，不能直接与 SQLite 的 30 MiB 主库上限比较。\n');
    }
    this.appendResult('写入预留：不再保留固定控制空间；每次提交仅按原子替换的最大临时文件、journal 和净增长预估所需空间。剩余容量仍不等于可直接写入的 payload 容量。\n');
    this.appendResult(`数据：sync=${status.syncCount}，view=${status.viewCount}，action=${status.actionCount}，evicted=${status.evicted}，rejected=${status.rejected}，corrupt=${status.corrupt}\n`);
    this.appendResult(`状态：directUpload=${status.directUpload}，sqliteReleased=${status.sqliteReleased}，shadowHealthy=${status.shadowHealthy}\n`);
    if (status.oldestUuids.length === 0) {
      this.appendResult('最早 sync UUID：无\n');
    } else {
      for (let i = 0; i < status.oldestUuids.length; i++) {
        this.appendResult(`最早 sync[${i}]：uuid=${status.oldestUuids[i]}，文件=${this.getFileStoreSyncPath(status.oldestUuids[i])}，存在=${snapshot.oldestSyncFilesPresent[i]}\n`);
      }
    }
  }

  private getFileStoreSyncPath(uuid: string): string {
    return `${this.context.filesDir}/ft_sdk_cache_v2/sync/${encodeURIComponent(uuid)}.json`;
  }

  private isFileStoreSyncPresent(uuid: string): boolean {
    try {
      return fs.accessSync(this.getFileStoreSyncPath(uuid));
    } catch (_) {
      return false;
    }
  }

  private isMigrationCompleted(status: UnifiedCacheStatusSnapshot): boolean {
    return status.migration.indexOf('"state":"completed"') >= 0;
  }

  private appendPhaseOnePreflight(snapshot: PhaseOneSnapshot): void {
    const status = snapshot.status;
    const policy = FTDBCachePolicy.getInstance();
    const capacityMatched = status.usage.capacityBytes === PAGE_DB_CACHE_LIMIT_SIZE;
    const discardOldest = String(policy.getDBCacheDiscard()) === 'discard_oldest';
    const autoSyncDisabled = !SyncTaskManager.getInstance().isAutoSyncEnabled();

    this.appendResult('\n[预检]\n');
    this.appendResult(`30 MiB 容量：${capacityMatched ? '通过' : `不通过（当前=${this.formatBytes(status.usage.capacityBytes)}）`}\n`);
    this.appendResult(`discard_oldest：${discardOldest ? '通过' : `不通过（当前=${policy.getDBCacheDiscard()}）`}\n`);
    this.appendResult(`当前持久化模式：${status.mode}；自动上传=${autoSyncDisabled ? '已关闭' : '已开启（做容量/Spool 精确验收时请断网或临时关闭）'}\n`);
    if (status.mode === 'file' || status.mode === 'shadow') {
      this.appendResult(`FileStore 迁移完成：${this.isMigrationCompleted(status) ? '通过' : `待确认（migration=${status.migration}）`}；Projection 无待修复=${!status.projectionPending}\n`);
    } else {
      this.appendResult('当前为 SQLite 正式模式：FileStore 迁移、sync 文件淘汰与影子镜像不作为本次正式配置的预检条件。\n');
    }
    this.appendResult('通过正式配置预检后，保存基线并重复写入带标记日志直至接近容量；停止写入后再执行比对。\n');
  }

  private startPhaseOnePreflightProgress(): void {
    this.stopPhaseOnePreflightProgress();
    const startedAt = Date.now();
    this.phaseOnePreflightProgress = '正在等待 DB 队列…';
    this.phaseOnePreflightWaitTimer = setInterval(() => {
      const elapsedSeconds = Math.max(1, Math.floor((Date.now() - startedAt) / 1000));
      this.phaseOnePreflightProgress = `正在等待 DB 队列（${elapsedSeconds} 秒）…后台写入、Spool 或影子对账完成后会自动继续`;
    }, 1000) as number;
  }

  private stopPhaseOnePreflightProgress(): void {
    if (this.phaseOnePreflightWaitTimer !== -1) {
      clearInterval(this.phaseOnePreflightWaitTimer);
      this.phaseOnePreflightWaitTimer = -1;
    }
  }

  private startCacheClearProgress(): void {
    this.stopCacheClearProgress();
    const startedAt = Date.now();
    this.cacheClearProgress = '正在等待 DB 队列，准备清空 Spool、SQLite 与 FileStore 数据…';
    this.cacheClearWaitTimer = setInterval(() => {
      const elapsedSeconds = Math.max(1, Math.floor((Date.now() - startedAt) / 1000));
      this.cacheClearProgress = `正在等待 DB 队列（${elapsedSeconds} 秒）…清空操作不可并发，请等待后台写入和影子对账结束`;
    }, 1000) as number;
  }

  private stopCacheClearProgress(): void {
    if (this.cacheClearWaitTimer !== -1) {
      clearInterval(this.cacheClearWaitTimer);
      this.cacheClearWaitTimer = -1;
    }
  }

  private async preparePhaseOneBaseline(): Promise<void> {
    this.isRunning = true;
    this.startPhaseOnePreflightProgress();
    try {
      this.phaseOnePreflightProgress = '正在等待日志邮箱与 DB 队列排空…';
      const drained = await this.awaitCachePipelineDrained('预检');
      if (!drained) {
        this.appendResult('预检：日志邮箱在 30 秒内未完全排空；已继续执行 DB 栅栏快照，请结合队列状态复查。\n');
      }
      const snapshot = await this.loadUnifiedCacheSnapshot('基线');
      this.stopPhaseOnePreflightProgress();
      this.phaseOnePreflightProgress = '正在整理统一缓存快照…';
      this.phaseOneBaseline = snapshot;
      this.phaseOneSummary = `已保存基线：sync=${snapshot.status.syncCount}，容量策略=${this.formatBytes(snapshot.status.usage.governedBytes)}，物理占用=${this.formatBytes(snapshot.status.usage.totalBytes)}，最早 UUID=${snapshot.status.oldestUuids.length}`;
      this.appendResult('\n=== 基线已保存 ===\n');
      this.appendUnifiedCacheSnapshot(snapshot);
      this.appendPhaseOnePreflight(snapshot);
      this.phaseOnePreflightProgress = '预检完成，已保存基线。';
    } catch (error) {
      this.appendResult(`保存基线失败：${error}\n`);
      this.phaseOnePreflightProgress = '预检失败，请查看下方测试结果。';
    } finally {
      this.stopPhaseOnePreflightProgress();
      this.isRunning = false;
    }
  }

  private createPhaseOneLogPayload(): string {
    const chunk = '0123456789abcdef';
    let payload = '';
    while (payload.length < PHASE_ONE_LOG_PAYLOAD_BYTES) {
      payload += chunk;
    }
    return payload.substring(0, PHASE_ONE_LOG_PAYLOAD_BYTES);
  }

  private async writePhaseOneLogBatch(): Promise<void> {
    this.isRunning = true;
    try {
      const before = await this.loadUnifiedCacheSnapshot('写入前');
      const marker = `phase1-capacity-${Date.now()}`;
      const payload = this.createPhaseOneLogPayload();
      this.appendResult(`\n=== 容量写入：${marker} ===\n`);
      this.appendResult(`提交 ${PHASE_ONE_LOG_BATCH_COUNT} 条日志，业务 payload 约 ${this.formatBytes(PHASE_ONE_LOG_BATCH_BYTES)}；请重复点击直到接近 30 MiB。\n`);
      for (let i = 0; i < PHASE_ONE_LOG_BATCH_COUNT; i++) {
        FTLogger.logBackground(`${marker}|index=${i}|${payload}`, Status.INFO, undefined, true);
        if ((i + 1) % 8 === 0) {
          await this.yieldToUi();
        }
      }
      FTLogger.flush();
      this.writeCount += PHASE_ONE_LOG_BATCH_COUNT;
      this.phaseOneLastMarker = marker;
      await this.waitForWriteSettled(PHASE_ONE_SETTLE_MS);
      const after = await this.loadUnifiedCacheSnapshot('写入后');
      const physicalGrowth = after.status.usage.totalBytes - before.status.usage.totalBytes;
      const governedGrowth = after.status.usage.governedBytes - before.status.usage.governedBytes;
      const markerData = await this.findPhaseOneMarker(this.phaseOneLastMarker);
      this.appendResult(`提交后容量策略增量：${this.formatBytes(Math.max(0, governedGrowth))}；物理落盘增量：${this.formatBytes(Math.max(0, physicalGrowth))}；evicted=${after.status.evicted}，rejected=${after.status.rejected}\n`);
      if (markerData) {
        this.appendResult(`ACK / 重试证据：marker=${marker}，uuid=${markerData.getUuid()}，sync 文件=${this.getFileStoreSyncPath(markerData.getUuid())}\n`);
      } else {
        this.appendResult(`ACK / 重试证据：marker=${marker} 尚未出现在最近 500 条日志中；请等待 worker 清空后重新检查。\n`);
      }
      this.appendUnifiedCacheSnapshot(after);
      this.phaseOneSummary = `最近 marker=${marker}，容量策略增量=${this.formatBytes(Math.max(0, governedGrowth))}，物理占用增量=${this.formatBytes(Math.max(0, physicalGrowth))}`;
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
    } catch (error) {
      this.appendResult(`容量写入失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async isPhaseOneMarkerPersisted(marker: string): Promise<boolean> {
    return (await this.findPhaseOneMarker(marker)) !== null;
  }

  private async findPhaseOneMarker(marker: string): Promise<SyncData | null> {
    if (marker.length === 0) {
      return null;
    }
    const recentLogs = await this.queryDbSamples([DataType.LOG], 500, true);
    for (let i = 0; i < recentLogs.length; i++) {
      if (recentLogs[i].getDataString().indexOf(marker) >= 0) {
        return recentLogs[i];
      }
    }
    return null;
  }

  private async comparePhaseOneBaseline(): Promise<void> {
    this.isRunning = true;
    try {
      if (this.phaseOneBaseline === null) {
        this.appendResult('请先点击“预检并保存基线”。\n');
        return;
      }
      const before = this.phaseOneBaseline;
      const after = await this.loadUnifiedCacheSnapshot('比对后');
      const policy = FTDBCachePolicy.getInstance();
      const status = after.status;
      const usage = status.usage;
      const summedBytes = usage.fileBytes + usage.sqliteBytes + usage.legacyFileBytes + usage.spoolBytes;
      const fileStorePrimary = status.mode === 'file';
      let removedOldest = 0;
      if (fileStorePrimary) {
        for (let i = 0; i < before.status.oldestUuids.length; i++) {
          if (!this.isFileStoreSyncPresent(before.status.oldestUuids[i])) {
            removedOldest++;
          }
        }
      }
      const evictedDelta = status.evicted - before.status.evicted;
      const rejectedDelta = status.rejected - before.status.rejected;
      const markerPersisted = await this.isPhaseOneMarkerPersisted(this.phaseOneLastMarker);

      this.appendResult('\n=== 容量策略比对 ===\n');
      this.appendUnifiedCacheSnapshot(after);
      this.appendResult(`账本分项求和：${summedBytes === usage.totalBytes ? '通过' : '失败'}（sum=${this.formatBytes(summedBytes)}，total=${this.formatBytes(usage.totalBytes)}）\n`);
      this.appendResult(`容量健康基线：${!usage.overLimit ? '通过' : '失败'}（${usage.governedScope}=${this.formatBytes(usage.governedBytes)}，capacity=${this.formatBytes(usage.capacityBytes)}）\n`);
      this.appendResult(fileStorePrimary
        ? `基线最早 UUID 的已消失 sync 文件数：${removedOldest}/${before.status.oldestUuids.length}\n`
        : '当前为 SQLite 正式模式：没有 FileStore sync 文件可用于“真实文件淘汰”判断；请以 DB 计数、marker 和容量结果验证当前配置。\n');
      this.appendResult(`计数增量：evicted=${evictedDelta}，rejected=${rejectedDelta}；最近 marker 持久化=${this.phaseOneLastMarker.length > 0 ? markerPersisted : '未写入'}\n`);

      const strategy = String(policy.getDBCacheDiscard());
      if (strategy === 'discard_oldest') {
        if (fileStorePrimary) {
          const passed = evictedDelta > 0 && removedOldest > 0 && markerPersisted;
          this.appendResult(passed
            ? 'FileStore 真实淘汰：通过。发生淘汰、基线旧文件已消失，且新 marker 仍可查询。\n'
            : 'FileStore 真实淘汰：尚不能下结论。请离线继续写满容量后再比对；只看到 DB 行减少而旧 sync 文件仍存在应判失败。\n');
        } else {
          this.appendResult(markerPersisted
            ? 'SQLite 正式配置：新 marker 已持久化。继续离线写满后，结合 DB 计数与总容量确认旧数据按 discard_oldest 被替换。\n'
            : 'SQLite 正式配置：最近 marker 尚未持久化；请等待 worker 清空或检查上传状态后重试。\n');
        }
      } else if (strategy === 'discard') {
        if (fileStorePrimary) {
          const passed = rejectedDelta > 0 && !markerPersisted && removedOldest === 0;
          this.appendResult(passed
            ? 'DISCARD：通过。旧文件保留、rejected 增长且新 marker 未持久化。\n'
            : 'DISCARD：尚不能下结论。写满容量后追加新 marker，再确认不会先删除旧文件。\n');
        } else {
          this.appendResult('SQLite 正式配置的 DISCARD 对比需在写满容量后结合 DB 计数和新 marker 进行；FileStore rejected 计数不适用。\n');
        }
      } else {
        this.appendResult(`当前策略=${strategy}，不属于 discard_oldest / discard 验收场景。\n`);
      }
      this.phaseOneSummary = `比对完成：模式=${status.mode}，evicted Δ=${evictedDelta}，rejected Δ=${rejectedDelta}`;
    } catch (error) {
      this.appendResult(`容量策略比对失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async verifyPhaseOneSpoolFallback(): Promise<void> {
    this.isRunning = true;
    try {
      const before = await this.loadUnifiedCacheSnapshot('Spool 回退前');
      const marker = `phase1-spool-${Date.now()}`;
      const data = new SyncData(DataType.LOG);
      const timeNano = Date.now() * 1000000;
      data.setUuid(marker);
      data.setTime(timeNano);
      data.setDataString(`df_rum_harmonyos_log,source=phase1_spool,sdk_data_id=${marker} message="${marker}" ${timeNano}`);

      const dbManager = FTDBManager.getInstance(this.context);
      await dbManager.init();
      DbInternalTestAccess.forceNextSyncDataWriteFailure();
      const result = await dbManager.writeSyncDataAtomically('phase1.spoolFallback', [data], {
        applyCachePolicy: true,
        forceTransaction: true
      });
      await this.waitForWriteSettled(PHASE_ONE_SETTLE_MS);
      const after = await this.loadUnifiedCacheSnapshot('Spool 回退后');
      const spoolGrowth = after.status.usage.spoolBytes - before.status.usage.spoolBytes;
      const ledgerConsistent = after.status.usage.totalBytes === after.status.usage.fileBytes + after.status.usage.sqliteBytes +
        after.status.usage.legacyFileBytes + after.status.usage.spoolBytes;

      this.appendResult('\n=== DB 失败 Spool 回退 ===\n');
      this.appendResult(`marker=${marker}，强制 DB 失败后 success=${result.success}，fallbackPersisted=${result.fallbackPersisted || 0}\n`);
      this.appendResult(`Spool 增量=${this.formatBytes(Math.max(0, spoolGrowth))}；统一账本一致=${ledgerConsistent}\n`);
      this.appendUnifiedCacheSnapshot(after);
      const passed = !result.success && result.fallbackPersisted === 1 && spoolGrowth > 0 && ledgerConsistent;
      this.appendResult(passed
        ? '单一账本 / Spool 回退：通过。失败记录已落入 spool，且其字节数计入总容量。\n'
        : '单一账本 / Spool 回退：尚不能下结论。确认自动上传关闭，检查 fallbackPersisted、spoolBytes 和总账本后重试。\n');
    } catch (error) {
      this.appendResult(`Spool 回退验证失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private createPhaseOneResourceParams(marker: string): ResourceParams {
    const params = new ResourceParams();
    params.setUrl(`https://phase-one.invalid/resource/${marker}`);
    params.setResourceMethod('GET');
    params.setResourceStatus(200);
    params.setResponseContentType('application/json');
    params.setResponseContentLength(128);
    return params;
  }

  private createPhaseOneNetStatus(): NetStatusBean {
    const start = Date.now();
    const status = new NetStatusBean();
    status.setDNSStartTime(start);
    status.setDNSTime(5);
    status.setConnectStartTime(start + 5);
    status.setTcpTime(10);
    status.setFirstByteStartTime(start + 15);
    status.setFirstByteTime(10);
    status.setDownloadTimeStart(start + 25);
    status.setDownloadTime(5);
    status.setHoleRequestTime(30);
    return status;
  }

  private async startPhaseOneAggregation(): Promise<void> {
    this.isRunning = true;
    try {
      const before = await this.loadUnifiedCacheSnapshot('聚合开始前');
      const marker = `phase1-aggregate-${Date.now()}`;
      const viewName = `Phase1View_${marker}`;
      const resourceId = `Phase1Resource_${marker}`;
      const rumManager = FTRUMGlobalManager.getInstance();
      await rumManager.startView(viewName);
      rumManager.addAction(`Phase1Action_${marker}`, 'click');
      rumManager.addError(`Phase1ErrorStack_${marker}`, `Phase1Error_${marker}`, ErrorType.CUSTOM, AppState.RUN);
      rumManager.startResource(resourceId);
      rumManager.stopResource(resourceId);
      rumManager.addResource(resourceId, this.createPhaseOneResourceParams(marker), this.createPhaseOneNetStatus());
      this.phaseOneActiveViewName = viewName;
      this.phaseOneViewActive = true;
      await this.waitForWriteSettled(PHASE_ONE_SETTLE_MS);
      const after = await this.loadUnifiedCacheSnapshot('聚合进行中');

      this.appendResult('\n=== 聚合生命周期已开始 ===\n');
      this.appendResult(`View=${viewName}；已发送 Action、Error 与 Resource。\n`);
      if (after.status.mode === 'file' || after.status.mode === 'shadow') {
        this.appendResult(`请先用“打印统一缓存明细”观察 view/ 与 action/，再点击“结束聚合 View”。计数：view ${before.status.viewCount} -> ${after.status.viewCount}，action ${before.status.actionCount} -> ${after.status.actionCount}\n`);
      } else {
        this.appendResult('当前为 SQLite 正式模式：聚合数据写入 SQLite，不应以 FileStore 的 view/action 计数为准。请在数据库中观察聚合状态后，再点击“结束聚合 View”。\n');
      }
      this.appendUnifiedCacheSnapshot(after);
      this.phaseOneSummary = `聚合 View 运行中：${viewName}`;
    } catch (error) {
      this.phaseOneViewActive = false;
      this.phaseOneActiveViewName = '';
      this.appendResult(`启动聚合生命周期失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async finishPhaseOneAggregation(): Promise<void> {
    this.isRunning = true;
    try {
      const before = await this.loadUnifiedCacheSnapshot('聚合结束前');
      await FTRUMGlobalManager.getInstance().stopView();
      const closedViewName = this.phaseOneActiveViewName;
      this.phaseOneActiveViewName = '';
      this.phaseOneViewActive = false;
      await this.waitForWriteSettled(PHASE_ONE_SETTLE_MS);
      const after = await this.loadUnifiedCacheSnapshot('聚合结束后');

      this.appendResult('\n=== 聚合生命周期已结束 ===\n');
      this.appendResult(`已结束 View=${closedViewName}；持久化模式=${after.status.mode}。\n`);
      if (after.status.mode === 'file' || after.status.mode === 'shadow') {
        this.appendResult(`聚合计数：view ${before.status.viewCount} -> ${after.status.viewCount}，action ${before.status.actionCount} -> ${after.status.actionCount}\n`);
      }
      this.appendResult('如需验证“草稿未落盘前不得提前清理”，请在结束前用调试器暂停同步草稿落盘，保存 view/ 与 action/ 文件证据后再继续。\n');
      this.appendUnifiedCacheSnapshot(after);
      this.phaseOneSummary = `聚合 View 已结束：${closedViewName}`;
    } catch (error) {
      this.appendResult(`结束聚合生命周期失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
  }

  private async inspectPhaseOneShadowMode(): Promise<void> {
    this.isRunning = true;
    try {
      const snapshot = await this.loadUnifiedCacheSnapshot('影子模式检查');
      this.appendResult('\n=== 影子模式检查 ===\n');
      this.appendUnifiedCacheSnapshot(snapshot);
      if (snapshot.status.mode !== 'shadow') {
        this.appendResult('当前不是影子模式。请在干净测试沙箱配置 setUseFileDataStore(false).setFileDataStoreShadow(true) 后冷启动，再重复创建、读取、关闭、清理与上传操作。\n');
      } else if (snapshot.status.shadowHealthy) {
        this.appendResult('shadowHealthy=true：当前镜像未报告错误。仍需按验收指南制造镜像写入失败，并确认其会变为不健康且恢复可写后收敛。\n');
      } else {
        this.appendResult('shadowHealthy=false：镜像存在未收敛错误，不应宣称影子校验通过；请保存此快照并完成恢复后的收敛操作。\n');
      }
    } catch (error) {
      this.appendResult(`影子模式检查失败：${error}\n`);
    } finally {
      this.isRunning = false;
    }
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

  private getCapacityUsageLabel(): string {
    const mode = this.capacityUsageMode || FTCacheContext.settings.mode;
    // FileStore primary uses one unified physical-byte ledger. Its value is
    // not merely the `ft_sdk_cache_v2` directory size.
    if (mode === 'file') { return '容量策略用量（统一物理缓存）'; }
    return '容量策略用量（SQLite 主库页分配）';
  }

  private getCapacityUsageHint(): string {
    const mode = this.capacityUsageMode || FTCacheContext.settings.mode;
    if (mode === 'shadow') {
      return '影子 FileStore 是额外的验证副本；完整物理落盘占用请使用“打印统一缓存明细”查看。';
    }
    if (mode === 'file') {
      return '此值包含 FileStore、SQLite/WAL、旧文件缓存与失败 Spool；各项明细请使用“打印统一缓存明细”。';
    }
    return '此值是 SQLite 的页分配容量计量；WAL、旧缓存与失败 Spool 的物理占用请使用“打印统一缓存明细”。';
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
      return '统一缓存容量';
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
    this.appendResult('\n=== 统一缓存容量策略 ===\n');
      this.appendDbCachePolicyResult();
    } catch (error) {
      this.appendResult(`统一缓存容量策略测试失败：${error}\n`);
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
    this.appendResult(`生效模式：${this.effectivePolicy}\n`);
    this.appendResult(`${this.getCapacityUsageLabel()}：${this.currentDbSize}\n`);
    this.appendResult(`统一缓存容量管控：${this.dbCacheEnabled ? '已启用' : '未启用'}，上限=${this.dbCacheLimit}，已触达=${this.dbLimitReached}\n`);
    this.appendResult(`Log Count: ${this.logCountText}, Limit=${this.logLimitText}\n`);
    this.appendResult(`RUM Count: ${this.rumCountText}, Limit=${this.rumLimitText}\n`);
    this.appendResult(`主库记录数：Log=${this.actualLogDbCountText}, RUM=${this.actualRumDbCountText}\n`);
    this.appendResult(`Discard Strategy: DB=${this.dbCacheDiscard}, RUM=${this.rumCacheDiscard}\n`);
    this.appendResult(`${this.countLimitNote}\n`);
  }

  private appendDbCachePolicyResult() {
    const cachePolicy = FTDBCachePolicy.getInstance();
    this.appendResult('\n[统一缓存容量]\n');
    this.appendResult(`Enabled: ${this.dbCacheEnabled}\n`);
    this.appendResult(`Capacity Usage: ${this.currentDbSize}\n`);
    this.appendResult(`容量上限：${this.dbCacheLimit}\n`);
    this.appendResult(`Reached: ${this.dbLimitReached}\n`);
    this.appendResult(`Discard Strategy: ${this.dbCacheDiscard}\n`);
    if (!this.dbCacheEnabled) {
      this.appendResult('统一缓存容量上限未启用。\n');
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

  private async runSdkPhysicalLimitTest(useLargeProbe: boolean = false): Promise<void> {
    this.isRunning = true;
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }

      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();

      this.appendResult('\n=== Device + SDK Physical Ceiling Probe ===\n');
      this.appendResult('Scope: physical device + SDK internal pipeline only. Business cache strategy and product quota are not used as conclusions.\n');
      this.appendCurrentMachineSnapshot();
      this.appendSdkLimitConstants();
      this.appendRuntimeLimitSnapshot();
      this.appendConsumeCapacitySummary();
      await this.appendPhysicalLimitProbe(useLargeProbe);
      this.appendResult('=== Device + SDK Physical Ceiling Probe Completed ===\n');
    } catch (error) {
      this.appendResult(`Device + SDK Physical Ceiling Probe failed: ${error}\n`);
    } finally {
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.isRunning = false;
    }
  }

  private async runDbWriteCapabilityBenchmark(): Promise<void> {
    this.isRunning = true;
    const syncTaskManager = SyncTaskManager.getInstance();
    const originalAutoSync = syncTaskManager.isAutoSyncEnabled();
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }
      if (originalAutoSync) {
        syncTaskManager.setAutoSync(false);
      }

      const dbManager = FTDBManager.getInstance(this.context);
      await dbManager.init();
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();

      const beforeDbSize = await this.queryCurrentDbSize();
      const beforeLogCount = await this.queryDbCount([DataType.LOG]);
      const beforeRumCount = await this.getRumDbCount();
      FTDBCachePolicy.getInstance().syncCountsFromDbInternal(beforeLogCount, beforeRumCount);

      this.appendResult('\n=== DB Write Capability Benchmark ===\n');
      this.appendResult('Scope: direct FTDBManager.writeSyncDataAtomically. This bypasses Log/RUM business APIs, scheduler lanes, and upload, while keeping DB write lock, duplicate filtering, and RDB insert/batchInsert behavior.\n');
      this.appendResult(`Auto Sync Paused During Benchmark: ${originalAutoSync}\n`);
      this.appendResult(`Batch Plan: ${DB_WRITE_CAPABILITY_BATCHES_PER_CASE} batches per case, batchSize=${DB_WRITE_CAPABILITY_BATCH_SIZES.join('/')}\n`);
      this.appendCurrentMachineSnapshot();
      this.appendResult(`Before: DB=${this.formatBytes(beforeDbSize)}, Log=${beforeLogCount}, RUM=${beforeRumCount}\n`);

      for (const batchSize of DB_WRITE_CAPABILITY_BATCH_SIZES) {
        await this.runDbWriteCapabilityCase(dbManager, batchSize);
        await this.waitForWriteSettled(DB_WRITE_CAPABILITY_SETTLE_MS);
      }

      const afterDbSize = await this.queryCurrentDbSize();
      const afterLogCount = await this.queryDbCount([DataType.LOG]);
      const afterRumCount = await this.getRumDbCount();
      FTDBCachePolicy.getInstance().syncCountsFromDbInternal(afterLogCount, afterRumCount);
      this.writeCount += Math.max(0, afterLogCount - beforeLogCount);
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();

      this.appendResult('\n[DB Write Capability Summary]\n');
      this.appendResult(`After: DB=${this.formatBytes(afterDbSize)}, Log=${afterLogCount}, RUM=${afterRumCount}\n`);
      this.appendResult(`Delta: DB=${this.formatBytes(Math.max(0, afterDbSize - beforeDbSize))}, Log=${Math.max(0, afterLogCount - beforeLogCount)}, RUM=${Math.max(0, afterRumCount - beforeRumCount)}\n`);
      this.appendResult('=== DB Write Capability Benchmark Completed ===\n');
    } catch (error) {
      this.appendResult(`DB Write Capability Benchmark failed: ${error}\n`);
    } finally {
      if (originalAutoSync) {
        syncTaskManager.setAutoSync(true);
      }
      this.isRunning = false;
    }
  }

  private async runDbWriteCapabilityCase(dbManager: FTDBManager, batchSize: number): Promise<void> {
    const runId = `DbWriteCapability_${Date.now()}_b${batchSize}`;
    const targetRows = batchSize * DB_WRITE_CAPABILITY_BATCHES_PER_CASE;
    const beforeDbSize = await this.queryCurrentDbSize();
    const beforeLogCount = await this.queryDbCount([DataType.LOG]);
    const batchCostsMs: number[] = [];
    let requested = 0;
    let inserted = 0;
    let dropped = 0;
    let duplicateSkipped = 0;
    let deletedOld = 0;
    let failedBatches = 0;
    let lastError = '';
    const startTime = Date.now();

    for (let batchIndex = 0; batchIndex < DB_WRITE_CAPABILITY_BATCHES_PER_CASE; batchIndex++) {
      const batchStartRow = batchIndex * batchSize;
      const records = this.buildDbWriteCapabilityBatch(runId, batchStartRow, batchSize);
      const batchStartTime = Date.now();
      const result = await dbManager.writeSyncDataAtomically(
        `db_write_capability_batch_${batchSize}`,
        records,
        {
          applyCachePolicy: false,
          reInsert: false
        }
      );
      batchCostsMs.push(Math.max(0, Date.now() - batchStartTime));
      requested += result.requested;
      inserted += result.inserted;
      dropped += result.dropped;
      duplicateSkipped += result.duplicateSkipped;
      deletedOld += result.deletedOld;
      if (!result.success) {
        failedBatches++;
        lastError = result.errorMessage;
      }
    }

    const elapsedMs = Math.max(1, Date.now() - startTime);
    const afterDbSize = await this.queryCurrentDbSize();
    const afterLogCount = await this.queryDbCount([DataType.LOG]);
    FTDBCachePolicy.getInstance().syncCountsFromDbInternal(afterLogCount, undefined);

    this.appendResult(`\n[DB Write Case] batchSize=${batchSize}, targetRows=${targetRows}\n`);
    this.appendResult(`Rows: requested=${requested}, inserted=${inserted}, dropped=${dropped}, duplicate=${duplicateSkipped}, deletedOld=${deletedOld}, failedBatches=${failedBatches}\n`);
    this.appendResult(`Elapsed: ${elapsedMs}ms, throughput~${this.formatRateValue((inserted * 1000) / elapsedMs)} row/s\n`);
    this.appendResult(`DB Delta: ${this.formatBytes(Math.max(0, afterDbSize - beforeDbSize))}, Log Delta=${Math.max(0, afterLogCount - beforeLogCount)}\n`);
    this.appendDbWriteCostStats(batchCostsMs);
    if (lastError.length > 0) {
      this.appendResult(`Last Error: ${lastError}\n`);
    }
  }

  private buildDbWriteCapabilityBatch(runId: string, startIndex: number, count: number): SyncData[] {
    const records: SyncData[] = [];
    for (let i = 0; i < count; i++) {
      const rowIndex = startIndex + i;
      records.push(this.createDbWriteCapabilityLogData(`${runId}_${rowIndex}`, rowIndex));
    }
    return records;
  }

  private createDbWriteCapabilityLogData(marker: string, rowIndex: number): SyncData {
    const data = new SyncData(DataType.LOG);
    const timeNano = Date.now() * 1000000 + rowIndex;
    data.setUuid(marker);
    data.setTime(timeNano);
    data.setDataString(`df_rum_harmonyos_log,source=db_write_capability,sdk_data_id=${marker} message="${marker}",status="info" ${timeNano}`);
    return data;
  }

  private appendDbWriteCostStats(costsMs: number[]): void {
    if (costsMs.length === 0) {
      this.appendResult('Batch Cost: no samples\n');
      return;
    }

    let total = 0;
    let max = 0;
    for (const cost of costsMs) {
      total += cost;
      if (cost > max) {
        max = cost;
      }
    }
    const avg = total / costsMs.length;
    this.appendResult(`Batch Cost: avg=${this.formatRateValue(avg)}ms, p50=${this.formatRateValue(this.getPercentileValue(costsMs, 50))}ms, p95=${this.formatRateValue(this.getPercentileValue(costsMs, 95))}ms, max=${this.formatRateValue(max)}ms\n`);
  }

  private getPercentileValue(values: number[], percentile: number): number {
    if (values.length === 0) {
      return 0;
    }
    const sorted = values.slice();
    sorted.sort((a: number, b: number) => a - b);
    const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((percentile * sorted.length) / 100) - 1));
    return sorted[index];
  }

  private async runSingleLaneBenchmarkSuite(): Promise<void> {
    const cases: SingleLaneBenchmarkCase[] = [
      {
        label: 'Event Lane No-op Serial',
        poolType: SDKDedicatedPoolType.EVENT_CONSUMER,
        taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
        taskCostMs: 0
      },
      {
        label: 'Log Lane No-op Serial',
        poolType: SDKDedicatedPoolType.LOG_CONSUMER,
        taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
        taskCostMs: 0
      },
      {
        label: 'Data-Process Lane No-op Parallel',
        poolType: SDKDedicatedPoolType.DATA_PROCESS,
        taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
        taskCostMs: 0
      },
      {
        label: 'Crash Lane No-op Serial',
        poolType: SDKDedicatedPoolType.CRASH,
        taskCount: SINGLE_LANE_BENCH_TASK_COUNT,
        taskCostMs: 0
      },
      {
        label: 'Data-Process Lane 5ms Parallel',
        poolType: SDKDedicatedPoolType.DATA_PROCESS,
        taskCount: SINGLE_LANE_BENCH_COST_TASK_COUNT,
        taskCostMs: 5
      },
      {
        label: 'Upload Lane 10ms Serial',
        poolType: SDKDedicatedPoolType.DATA_UPLOAD,
        taskCount: SINGLE_LANE_BENCH_UPLOAD_TASK_COUNT,
        taskCostMs: 10
      }
    ];
    await this.runSingleLaneBenchmarkCases('SDK Lane Benchmark Suite', cases);
  }

  private async runSingleLaneBenchmarkOnly(testCase: SingleLaneBenchmarkCase): Promise<void> {
    await this.runSingleLaneBenchmarkCases(testCase.label, [testCase]);
  }

  private async runSingleLaneBenchmarkCases(title: string, cases: SingleLaneBenchmarkCase[]): Promise<void> {
    this.isRunning = true;
    const syncTaskManager = SyncTaskManager.getInstance();
    const originalAutoSync = syncTaskManager.isAutoSyncEnabled();
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }
      if (originalAutoSync) {
        syncTaskManager.setAutoSync(false);
      }

      this.appendResult(`\n=== Synthetic Single Lane Benchmark: ${title} ===\n`);
      this.appendResult('Scope: dedicated pool only. This bypasses Log/RUM business APIs, DB serialization, and network payload building.\n');
      this.appendResult(`Auto Sync Paused During Benchmark: ${originalAutoSync}\n`);
      this.appendCurrentMachineSnapshot();
      this.appendResult('\n[Runtime Before Benchmark]\n');
      this.appendSchedulerLaneSnapshots();

      for (const testCase of cases) {
        await this.runSingleLaneBenchmarkCase(testCase);
      }

      this.appendResult('\n[Runtime After Benchmark]\n');
      this.appendSchedulerLaneSnapshots();
      this.appendResult(`=== Synthetic Single Lane Benchmark Completed: ${title} ===\n`);
    } catch (error) {
      this.appendResult(`Synthetic Single Lane Benchmark failed: ${error}\n`);
    } finally {
      if (originalAutoSync) {
        syncTaskManager.setAutoSync(true);
      }
      this.isRunning = false;
    }
  }

  private async runSingleLaneBenchmarkCase(testCase: SingleLaneBenchmarkCase): Promise<void> {
    const poolManager = SDKDedicatedPoolManager.getInstance();
    const beforeLane = poolManager.getStatus().pools[testCase.poolType];
    const beforeSubmitted = beforeLane ? beforeLane.submittedTasks : 0;
    const beforeCompleted = beforeLane ? beforeLane.completedTasks : 0;
    const beforeFailed = beforeLane ? beforeLane.failedTasks : 0;
    const tasks: Promise<SDKWorkerResponse>[] = [];
    const startTime = Date.now();

    for (let i = 0; i < testCase.taskCount; i++) {
      const taskName = `single-lane-benchmark-${testCase.poolType}-${i}`;
      const payload: SyntheticPoolPingPayload = {
        syntheticCostMs: testCase.taskCostMs
      };
      const request: SDKWorkerRequest = {
        id: taskName,
        pool: testCase.poolType,
        command: SDKWorkerCommand.PING,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      };
      tasks.push(poolManager.executeCommand(request));
    }

    const enqueueElapsedMs = Math.max(1, Date.now() - startTime);
    await Promise.all(tasks);
    const elapsedMs = Math.max(1, Date.now() - startTime);
    const afterLane = poolManager.getStatus().pools[testCase.poolType];
    const submittedDelta = afterLane ? afterLane.submittedTasks - beforeSubmitted : 0;
    const completedDelta = afterLane ? afterLane.completedTasks - beforeCompleted : 0;
    const failedDelta = afterLane ? afterLane.failedTasks - beforeFailed : 0;
    const throughput = (completedDelta * 1000) / elapsedMs;
    const enqueueRate = (testCase.taskCount * 1000) / enqueueElapsedMs;

    this.appendResult(`\n[Single Lane Benchmark] ${testCase.label}\n`);
    this.appendResult(`Pool: ${testCase.poolType}, commands=${testCase.taskCount}, syntheticCostHint=${testCase.taskCostMs}ms, max=${afterLane ? afterLane.maxConcurrency : 0}\n`);
    this.appendResult(`Before: ${this.formatLaneBenchmarkStatus(beforeLane)}\n`);
    this.appendResult(`Submit: elapsed=${enqueueElapsedMs}ms, rate~${this.formatRateValue(enqueueRate)} task/s\n`);
    this.appendResult(`Drain: elapsed=${elapsedMs}ms, throughput~${this.formatRateValue(throughput)} task/s\n`);
    this.appendResult(`Delta: submitted=${submittedDelta}, completed=${completedDelta}, failed=${failedDelta}\n`);
    this.appendResult(`After: ${this.formatLaneBenchmarkStatus(afterLane)}\n`);
    if (afterLane && (afterLane.pending > 0 || afterLane.running > 0)) {
      this.appendResult(`Pool Backlog Signal: pending=${afterLane.pending}, running=${afterLane.running}; pool is still busy after this case.\n`);
    } else {
      this.appendResult('Pool Backlog Signal: no backlog after this case.\n');
    }
  }

  private formatLaneBenchmarkStatus(lane: SDKDedicatedPoolStatus | undefined): string {
    if (!lane) {
      return 'unavailable';
    }
    return `pending=${lane.pending}, running=${lane.running}, max=${lane.maxConcurrency}, submitted=${lane.submittedTasks}, completed=${lane.completedTasks}, failed=${lane.failedTasks}, avgWait=${lane.averageWaitTime.toFixed(1)}ms, avgCost=${lane.averageCostTime.toFixed(1)}ms, backend=${lane.backend}`;
  }

  private appendCurrentMachineSnapshot(): void {
    this.appendResult('\n[Current Machine]\n');

    try {
      this.appendResult(`Device: type=${DeviceUtils.getDeviceType()}, brand=${DeviceUtils.getDeviceBrand()}, model=${DeviceUtils.getDeviceModel()}, arch=${DeviceUtils.getDeviceArch()}\n`);
      this.appendResult(`OS: version=${DeviceUtils.getOSVersion()}, major=${DeviceUtils.getOSVersionMajor()}\n`);
      this.appendResult(`Display: ${DeviceUtils.getDisplay()}, density=${DeviceUtils.getScreenDensity()}, dpi=${DeviceUtils.getScreenDPI()}\n`);
      this.appendResult(`Network: ${DeviceUtils.getNetworkTypeSync()}\n`);
    } catch (error) {
      this.appendResult(`Current machine snapshot unavailable: ${error}\n`);
    }
  }

  private appendSdkLimitConstants(): void {
    this.appendResult('\n[SDK Physical Guards]\n');
    this.appendResult(`Log Producer Queue Guard: MAX_QUEUE_SIZE_LOG=${Constants.MAX_QUEUE_SIZE_LOG}\n`);
    this.appendResult(`Generic SDK Queue Guard: MAX_QUEUE_SIZE=${Constants.MAX_QUEUE_SIZE}\n`);
    this.appendResult(`Upload Dedup Set Guard: MAX_SET_SIZE_UPLOAD=${Constants.MAX_SET_SIZE_UPLOAD}\n`);
    this.appendResult(`RUM Action Set Guard: MAX_SET_SIZE_ACTION=${Constants.MAX_SET_SIZE_ACTION}\n`);
    this.appendResult(`RUM View Set Guard: MAX_SET_SIZE_VIEW=${Constants.MAX_SET_SIZE_VIEW}\n`);
    this.appendResult(`RUM Resource Map Guard: MAX_MAP_SIZE_RESOURCE=${Constants.MAX_MAP_SIZE_RESOURCE}\n`);
    this.appendResult(`DB Insert Dedup Map Guard: MAX_MAP_SIZE_DB=${Constants.MAX_MAP_SIZE_DB}\n`);
    this.appendResult(`Click Dedup Map Guard: MAX_MAP_SIZE_CLICK=${Constants.MAX_MAP_SIZE_CLICK}\n`);
    this.appendResult(`Upload Page Shape: pageSize(runtime), RUM_APP<=${SDK_UPLOAD_MAX_PAGES_RUM_APP} pages/poll, RUM_WEBVIEW<=${SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW} page/poll, LOG<=${SDK_UPLOAD_MAX_PAGES_LOG} page/poll\n`);
    this.appendResult(`Inner Log File Guard: single file and total file limits are read from runtime status below\n`);
  }

  private appendRuntimeLimitSnapshot(): void {
    this.appendResult('\n[Runtime Snapshot]\n');

    try {
      const syncStatus = SyncTaskManager.getInstance().getStatus();
      const uploadConsumeCap =
        syncStatus.pageSize * (SDK_UPLOAD_MAX_PAGES_RUM_APP + SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW + SDK_UPLOAD_MAX_PAGES_LOG);
      this.appendResult(`Sync Page Size: ${syncStatus.pageSize}, Auto Sync: ${syncStatus.autoSync}, Retry Limit: ${syncStatus.dataSyncMaxRetryCount}, Sleep: ${syncStatus.syncSleepTime}ms\n`);
      this.appendResult(`Upload Consume Cap Per Poll: RUM_APP<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_RUM_APP}, RUM_WEBVIEW<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW}, LOG<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_LOG}, Total<=${uploadConsumeCap}\n`);
      this.appendResult(`Upload Lane: running=${syncStatus.uploadLaneStatus.isRunning}, scheduled=${syncStatus.uploadLaneStatus.isScheduled}, needReschedule=${syncStatus.uploadLaneStatus.needReschedule}\n`);
    } catch (error) {
      this.appendResult(`Sync status unavailable: ${error}\n`);
    }

    try {
      const loggerStatus = FTLogger.getStatus();
      this.appendResult(`Log Queue Status: queue=${loggerStatus.get('queueSize')}, buffer=${loggerStatus.get('bufferSize')}, processing=${loggerStatus.get('isProcessing')}\n`);
      this.appendResult(`Log Flush Shape: batch=${SDK_LOG_FLUSH_BATCH_SIZE}, coalesce=${SDK_LOG_PROCESS_COALESCE_MS}ms\n`);
    } catch (error) {
      this.appendResult(`Log queue status unavailable: ${error}\n`);
    }

    try {
      const innerLogStatus = FTInnerLogFileManager.getInstance().getStatus();
      this.appendResult(`Inner Log File: enabled=${innerLogStatus.enabled}, queue=${innerLogStatus.queueSize}, dropped=${innerLogStatus.droppedCount}\n`);
      this.appendResult(`Inner Log File Limits: single=${this.formatBytes(innerLogStatus.singleFileMaxSize)}, total=${this.formatBytes(innerLogStatus.totalFileMaxSize)}, flush=${innerLogStatus.flushBatchSize}/${innerLogStatus.flushIntervalMs}ms\n`);
    } catch (error) {
      this.appendResult(`Inner log file status unavailable: ${error}\n`);
    }

    this.appendSchedulerLaneSnapshots();
  }

  private appendSchedulerLaneSnapshots(): void {
    try {
      const poolStatus = SDKDedicatedPoolManager.getInstance().getStatus();
      const uploadCommandLane = poolStatus.pools[SDKDedicatedPoolType.DATA_UPLOAD];
      if (uploadCommandLane) {
        this.appendResult(`Dedicated Pool Upload Command: pending=${uploadCommandLane.pending}, running=${uploadCommandLane.running}, backend=${uploadCommandLane.backend}\n`);
      }

      const poolTypes: SDKDedicatedPoolType[] = [
        SDKDedicatedPoolType.LOG_CONSUMER,
        SDKDedicatedPoolType.EVENT_CONSUMER,
        SDKDedicatedPoolType.DATA_PROCESS,
        SDKDedicatedPoolType.CRASH,
        SDKDedicatedPoolType.ANR,
        SDKDedicatedPoolType.DATA_UPLOAD,
      ];
      for (const poolType of poolTypes) {
        const lane = poolStatus.pools[poolType];
        if (!lane) {
          continue;
        }
        this.appendResult(`Pool ${poolType}: pending=${lane.pending}, running=${lane.running}, max=${lane.maxConcurrency}, submitted=${lane.submittedTasks}, completed=${lane.completedTasks}, failed=${lane.failedTasks}, avgWait=${lane.averageWaitTime.toFixed(1)}ms, avgCost=${lane.averageCostTime.toFixed(1)}ms, backend=${lane.backend}\n`);
      }
    } catch (error) {
      this.appendResult(`Dedicated pool status unavailable: ${error}\n`);
    }
  }

  private appendConsumeCapacitySummary(): void {
    this.appendResult('\n[Physical Consume Capacity Estimate]\n');

    try {
      const syncStatus = SyncTaskManager.getInstance().getStatus();
      const poolStatus = SDKDedicatedPoolManager.getInstance().getStatus();
      const logLane = poolStatus.pools[SDKDedicatedPoolType.LOG_CONSUMER];
      const eventLane = poolStatus.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      const dataProcessLane = poolStatus.pools[SDKDedicatedPoolType.DATA_PROCESS];
      const uploadLane = poolStatus.pools[SDKDedicatedPoolType.DATA_UPLOAD];
      const logProcessRate = this.estimateLogProcessRate(logLane);
      const eventRate = this.estimateLaneRate(eventLane, 1, DEFAULT_EVENT_COST_MS);
      const dataProcessRate = this.estimateLaneRate(dataProcessLane, 2, DEFAULT_DATA_PROCESS_COST_MS);
      const rumEventRate = Math.min(eventRate, dataProcessRate);
      const uploadRowsPerPoll =
        syncStatus.pageSize * (SDK_UPLOAD_MAX_PAGES_RUM_APP + SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW + SDK_UPLOAD_MAX_PAGES_LOG);
      const uploadPollRate = this.estimateUploadPollRate(uploadLane);
      const uploadRowsPerSecond = uploadRowsPerPoll * uploadPollRate;
      const innerLogBatchRate = this.estimateInnerLogFileRate(undefined);

      this.appendResult(`Log Producer: queueGuard<=${Constants.MAX_QUEUE_SIZE_LOG}, flush=${SDK_LOG_FLUSH_BATCH_SIZE}/${SDK_LOG_PROCESS_COALESCE_MS}ms, theoreticalDrain~${this.formatRateValue(logProcessRate)} log/s before data-process bottleneck\n`);
      this.appendResult(`RUM Event Lane: maxRunning=${this.getLaneMaxConcurrency(eventLane, 1)}, eventAvg=${this.formatLaneCost(eventLane, DEFAULT_EVENT_COST_MS)}, theoreticalEvent~${this.formatRateValue(eventRate)} event/s\n`);
      this.appendResult(`Data Process Lane: maxRunning=${this.getLaneMaxConcurrency(dataProcessLane, 2)}, dataAvg=${this.formatLaneCost(dataProcessLane, DEFAULT_DATA_PROCESS_COST_MS)}, theoreticalProcess~${this.formatRateValue(dataProcessRate)} item/s\n`);
      this.appendResult(`RUM Combined Physical Estimate: min(event,data-process)~${this.formatRateValue(rumEventRate)} item/s\n`);
      this.appendResult(`RUM In-Memory Guards: actionSet<=${Constants.MAX_SET_SIZE_ACTION}, viewSet<=${Constants.MAX_SET_SIZE_VIEW}, resourceMap<=${Constants.MAX_MAP_SIZE_RESOURCE}\n`);
      this.appendResult(`Inner SDK Log File: queueGuard<=${Constants.MAX_QUEUE_SIZE}, theoreticalFileDrain~${this.formatRateValue(innerLogBatchRate)} line/s, fileTotal<=${this.getInnerLogTotalLimitText()}\n`);
      this.appendResult(`Upload RUM_APP: pageSize=${syncStatus.pageSize}, cap<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_RUM_APP}/poll, pollRate~${this.formatRateValue(uploadPollRate)}/s, rows~${this.formatRateValue(syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_RUM_APP * uploadPollRate)}/s\n`);
      this.appendResult(`Upload RUM_WEBVIEW: pageSize=${syncStatus.pageSize}, cap<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_RUM_WEBVIEW}/poll, shares upload lane\n`);
      this.appendResult(`Upload LOG: pageSize=${syncStatus.pageSize}, cap<=${syncStatus.pageSize * SDK_UPLOAD_MAX_PAGES_LOG}/poll, shares upload lane\n`);
      this.appendResult(`Upload Total: upload lane max=${this.getLaneMaxConcurrency(uploadLane, 1)}, cap<=${uploadRowsPerPoll}/poll, rows~${this.formatRateValue(uploadRowsPerSecond)}/s by observed upload lane cost, retry<=${syncStatus.dataSyncMaxRetryCount}, autoSync=${syncStatus.autoSync}, sleep=${syncStatus.syncSleepTime}ms\n`);
    } catch (error) {
      this.appendResult(`Consume capacity summary unavailable: ${error}\n`);
    }
  }

  private estimateLogProcessRate(logLane: SDKDedicatedPoolStatus | undefined): number {
    const concurrency = this.getLaneMaxConcurrency(logLane, 1);
    return (SDK_LOG_FLUSH_BATCH_SIZE * concurrency * 1000) / SDK_LOG_PROCESS_COALESCE_MS;
  }

  private estimateInnerLogFileRate(innerLogLane: SDKDedicatedPoolStatus | undefined): number {
    const innerLogStatus = FTInnerLogFileManager.getInstance().getStatus();
    const laneRate = this.estimateLaneRate(innerLogLane, 1, DEFAULT_INNER_LOG_FILE_COST_MS);
    return laneRate * Math.max(1, innerLogStatus.flushBatchSize);
  }

  private estimateUploadPollRate(uploadLane: SDKDedicatedPoolStatus | undefined): number {
    return this.estimateLaneRate(uploadLane, 1, DEFAULT_UPLOAD_COST_MS);
  }

  private estimateLaneRate(lane: SDKDedicatedPoolStatus | undefined, fallbackConcurrency: number, fallbackCostMs: number): number {
    const concurrency = this.getLaneMaxConcurrency(lane, fallbackConcurrency);
    const costMs = Math.max(1, this.getLaneAverageCostMs(lane, fallbackCostMs));
    return (concurrency * 1000) / costMs;
  }

  private getLaneMaxConcurrency(lane: SDKDedicatedPoolStatus | undefined, fallback: number): number {
    if (!lane) {
      return fallback;
    }
    return Math.max(1, lane.maxConcurrency);
  }

  private getLaneAverageCostMs(lane: SDKDedicatedPoolStatus | undefined, fallback: number): number {
    if (!lane || lane.averageCostTime <= 0) {
      return fallback;
    }
    return lane.averageCostTime;
  }

  private formatLaneCost(lane: SDKDedicatedPoolStatus | undefined, fallback: number): string {
    return `${this.formatRateValue(this.getLaneAverageCostMs(lane, fallback))}ms`;
  }

  private formatRateValue(value: number): string {
    if (!isFinite(value) || isNaN(value)) {
      return '0';
    }
    if (value >= 100) {
      return `${Math.round(value)}`;
    }
    if (value >= 10) {
      return value.toFixed(1);
    }
    return value.toFixed(2);
  }

  private getInnerLogTotalLimitText(): string {
    try {
      return this.formatBytes(FTInnerLogFileManager.getInstance().getStatus().totalFileMaxSize);
    } catch (error) {
      return 'unknown';
    }
  }

  private formatPercent(value: number, total: number): string {
    if (total <= 0) {
      return '0%';
    }
    return `${((value * 100) / total).toFixed(1)}%`;
  }

  private async appendPhysicalLimitProbe(useLargeProbe: boolean = false): Promise<void> {
    const runId = `PhysicalLimit_${Date.now()}`;
    const logCount = useLargeProbe ? LARGE_PHYSICAL_LIMIT_PROBE_LOG_COUNT : PHYSICAL_LIMIT_PROBE_LOG_COUNT;
    const rumCount = useLargeProbe ? LARGE_PHYSICAL_LIMIT_PROBE_RUM_COUNT : PHYSICAL_LIMIT_PROBE_RUM_COUNT;
    const batchSize = useLargeProbe ? LARGE_PHYSICAL_LIMIT_PROBE_BATCH_SIZE : PHYSICAL_LIMIT_PROBE_LOG_COUNT;
    const batchDelayMs = useLargeProbe ? LARGE_PHYSICAL_LIMIT_PROBE_BATCH_DELAY_MS : 0;
    const settleMs = useLargeProbe ? LARGE_PHYSICAL_LIMIT_PROBE_SETTLE_MS : PHYSICAL_LIMIT_PROBE_SETTLE_MS;
    const logMarkers = this.buildLogMarkers(`${runId}_log`, logCount);
    const rumMarkers = this.buildLogMarkers(`${runId}_rum`, rumCount);
    const syncTaskManager = SyncTaskManager.getInstance();
    const originalAutoSync = syncTaskManager.isAutoSyncEnabled();
    const beforeDbSize = await this.queryCurrentDbSize();
    const beforeLogCount = await this.queryDbCount([DataType.LOG]);
    const beforeRumCount = await this.getRumDbCount();

    this.appendResult('\n[Physical Probe Input]\n');
    this.appendResult(`Run ID: ${runId}\n`);
    this.appendResult(`Mode: ${useLargeProbe ? 'stress' : 'quick'}\n`);
    this.appendResult(`Business Policy: ignored for conclusion; only physical pipeline timing and marker persistence are measured\n`);
    this.appendResult(`Auto Sync Paused During Probe: ${originalAutoSync}\n`);
    this.appendResult(`Before: DB=${this.formatBytes(beforeDbSize)}, Log=${beforeLogCount}, RUM=${beforeRumCount}\n`);
    this.appendResult(`Target: ${logCount} logs + ${rumCount} RUM actions, batch=${batchSize}, interBatchDelay=${batchDelayMs}ms, maxDrainWait=${settleMs}ms\n`);

    const shouldPauseAutoSync = originalAutoSync;
    try {
      if (shouldPauseAutoSync) {
        syncTaskManager.setAutoSync(false);
      }

      const writeStartTime = Date.now();
      const logWriteStartTime = Date.now();
      await this.writePhysicalLimitProbeLogs(logMarkers, batchSize, batchDelayMs);
      const logWriteElapsedMs = Date.now() - logWriteStartTime;
      const rumWriteStartTime = Date.now();
      await this.writePhysicalLimitProbeRum(rumMarkers, batchSize, batchDelayMs);
      const rumWriteElapsedMs = Date.now() - rumWriteStartTime;
      FTLogger.flush();
      const writeElapsedMs = Date.now() - writeStartTime;
      const drainResult = await this.waitForPhysicalProbeDrain(logMarkers, rumMarkers, settleMs);

      const afterDbSize = await this.queryCurrentDbSize();
      const afterLogCount = await this.queryDbCount([DataType.LOG]);
      const afterRumCount = await this.getRumDbCount();
      const logMissing = drainResult.logMissing;
      const rumMissing = drainResult.rumMissing;
      const insertedLogCount = Math.max(0, afterLogCount - beforeLogCount);
      const insertedRumCount = Math.max(0, afterRumCount - beforeRumCount);
      const insertedTotal = insertedLogCount + insertedRumCount;
      const dbDelta = Math.max(0, afterDbSize - beforeDbSize);
      const averageBytes = insertedTotal > 0 ? dbDelta / insertedTotal : 0;
      const foundLogCount = logCount - logMissing.length;
      const foundRumCount = rumCount - rumMissing.length;
      const foundTotal = foundLogCount + foundRumCount;
      const producedTotal = logCount + rumCount;
      const totalObserveMs = Math.max(1, writeElapsedMs + drainResult.elapsedMs);

      this.appendResult('\n[Physical Probe Timing]\n');
      this.appendResult(`Producer Wall Time: total=${writeElapsedMs}ms, log=${logWriteElapsedMs}ms, rum=${rumWriteElapsedMs}ms\n`);
      this.appendResult(`Drain Wait: ${drainResult.elapsedMs}ms, completed=${drainResult.completed}\n`);
      this.appendResult(`Producer Submit Rate: ${this.formatRateValue((producedTotal * 1000) / Math.max(1, writeElapsedMs))} item/s\n`);
      this.appendResult(`Observed Durable Rate: ${this.formatRateValue((foundTotal * 1000) / totalObserveMs)} item/s, observeWindow=${totalObserveMs}ms\n`);

      this.appendResult('\n[Physical Probe Result]\n');
      this.appendResult(`After: DB=${this.formatBytes(afterDbSize)}, Log=${afterLogCount}, RUM=${afterRumCount}\n`);
      this.appendResult(`DB Delta: ${this.formatBytes(dbDelta)}, Inserted Delta: Log=${insertedLogCount}, RUM=${insertedRumCount}\n`);
      this.appendMarkerCheckResult('Probe Logs', logCount, logMissing);
      this.appendMarkerCheckResult('Probe RUM', rumCount, rumMissing);
      this.appendResult(`Acceptance: Log=${this.formatPercent(foundLogCount, logCount)}, RUM=${this.formatPercent(foundRumCount, rumCount)}, Total=${this.formatPercent(foundTotal, producedTotal)}\n`);

      if (averageBytes > 0) {
        this.appendResult(`Estimated Average DB Footprint: ${this.formatBytes(Math.round(averageBytes))} / record\n`);
      } else {
        this.appendResult('Estimated Average DB Footprint: unavailable; DB size did not grow. Check auto upload/network state and retry offline.\n');
      }

      this.appendPhysicalProbeReadout(
        logCount,
        rumCount,
        foundLogCount,
        foundRumCount,
        writeElapsedMs,
        totalObserveMs,
        averageBytes
      );
      this.appendResult('\n[Runtime After Probe]\n');
      this.appendSchedulerLaneSnapshots();
    } finally {
      if (shouldPauseAutoSync) {
        syncTaskManager.setAutoSync(true);
      }
    }
  }

  private async writePhysicalLimitProbeLogs(markers: string[], batchSize: number, delayMs: number): Promise<void> {
    for (let start = 0; start < markers.length; start += batchSize) {
      const end = Math.min(start + batchSize, markers.length);
      for (let i = start; i < end; i++) {
        FTLogger.logBackground(markers[i], Status.INFO, undefined, true);
      }
      FTLogger.flush();
      if (delayMs > 0) {
        await this.waitForWriteSettled(delayMs);
      } else {
        await this.yieldToUi();
      }
    }
    this.writeCount += markers.length;
  }

  private async writePhysicalLimitProbeRum(markers: string[], batchSize: number, delayMs: number): Promise<void> {
    const rumManager = FTRUMGlobalManager.getInstance();
    for (let start = 0; start < markers.length; start += batchSize) {
      const end = Math.min(start + batchSize, markers.length);
      for (let i = start; i < end; i++) {
        rumManager.addAction(markers[i], 'click');
      }
      if (delayMs > 0) {
        await this.waitForWriteSettled(delayMs);
      } else {
        await this.yieldToUi();
      }
    }
    this.writeCount += markers.length;
  }

  private async waitForPhysicalProbeDrain(
    logMarkers: string[],
    rumMarkers: string[],
    timeoutMs: number
  ): Promise<PhysicalProbeDrainResult> {
    const startTime = Date.now();
    let logMissing = logMarkers;
    let rumMissing = rumMarkers;
    const logQueryLimit = logMarkers.length + 200;
    const rumQueryLimit = rumMarkers.length + 200;

    while (Date.now() - startTime < timeoutMs) {
      const logSamples = await this.queryLogDbSamples(logQueryLimit, true);
      const rumSamples = await this.queryRumDbSamples(rumQueryLimit, true);
      logMissing = this.findMissingMarkers(logSamples, logMarkers);
      rumMissing = this.findMissingMarkers(rumSamples, rumMarkers);
      if (logMissing.length === 0 && rumMissing.length === 0) {
        return {
          logMissing,
          rumMissing,
          elapsedMs: Date.now() - startTime,
          completed: true
        };
      }
      await this.waitForWriteSettled(PHYSICAL_LIMIT_PROBE_POLL_MS);
    }

    const logSamples = await this.queryLogDbSamples(logQueryLimit, true);
    const rumSamples = await this.queryRumDbSamples(rumQueryLimit, true);
    logMissing = this.findMissingMarkers(logSamples, logMarkers);
    rumMissing = this.findMissingMarkers(rumSamples, rumMarkers);
    return {
      logMissing,
      rumMissing,
      elapsedMs: Date.now() - startTime,
      completed: logMissing.length === 0 && rumMissing.length === 0
    };
  }

  private appendPhysicalProbeReadout(
    logProduced: number,
    rumProduced: number,
    logFound: number,
    rumFound: number,
    writeElapsedMs: number,
    totalObserveMs: number,
    averageBytes: number
  ): void {
    const producedTotal = logProduced + rumProduced;
    const foundTotal = logFound + rumFound;
    const submitRate = (producedTotal * 1000) / Math.max(1, writeElapsedMs);
    const durableRate = (foundTotal * 1000) / Math.max(1, totalObserveMs);

    this.appendResult('\n[Physical Ceiling Readout]\n');
    this.appendResult(`Current Device Submit Ceiling In This Probe: ~${this.formatRateValue(submitRate)} item/s\n`);
    this.appendResult(`Current SDK Durable Consume Ceiling In This Probe: ~${this.formatRateValue(durableRate)} item/s\n`);
    this.appendResult(`Log Physical Acceptance: ${logFound}/${logProduced} (${this.formatPercent(logFound, logProduced)})\n`);
    this.appendResult(`RUM Physical Acceptance: ${rumFound}/${rumProduced} (${this.formatPercent(rumFound, rumProduced)})\n`);
    if (averageBytes > 0) {
      this.appendResult(`Physical DB Growth Per Persisted Record: ~${this.formatBytes(Math.round(averageBytes))}\n`);
    }

    if (logFound < logProduced || rumFound < rumProduced) {
      this.appendResult('Bottleneck Signal: SDK pipeline did not persist all probe markers inside the observe window. Check Runtime After Probe lane pending/running and missing preview.\n');
    } else {
      this.appendResult('Bottleneck Signal: no marker loss observed in this probe window. Increase probe size if you need to push the current device harder.\n');
    }
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
          this.appendResult(`已写入 ${this.writeCount} 条 SDK 日志，${this.getCapacityUsageLabel()}：${this.currentDbSize}\n`);
          const stopReason = this.getAutoStopReason(DataType.LOG);
          if (stopReason.length > 0) {
            this.stopAutoWriteAndDrain(stopReason);
          }
        }
      } catch (error) {
        this.appendResult(`Error writing logs: ${error}\n`);
        this.stopAutoWriteAndDrain();
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
        rumManager.addError(`Error stack trace ${count}`, `AutoError_${count}`, ErrorType.CUSTOM, AppState.RUN);
        
        count++;
        this.writeCount = count * 2; // Write 2 RUM items each time
        
        if (count % AUTO_RUM_STATUS_INTERVAL === 0) {
          this.updatePolicyInfo();
          this.refreshActualDbCounts(false);
          this.appendResult(`已写入 ${this.writeCount} 条 RUM 数据，${this.getCapacityUsageLabel()}：${this.currentDbSize}\n`);
          const stopReason = this.getAutoStopReason(DataType.RUM_APP);
          if (stopReason.length > 0) {
            this.stopAutoWriteAndDrain(stopReason);
          }
        }
      } catch (error) {
        this.appendResult(`Error writing RUM data: ${error}\n`);
        this.stopAutoWriteAndDrain();
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

  /** Stop the producer first, then make the mailbox and DB lane acknowledge a drain barrier. */
  private async stopAutoWriteAndDrain(reason: string = ''): Promise<void> {
    this.stopAutoWrite(reason);
    this.isRunning = true;
    this.phaseOnePreflightProgress = '自动写入已停止，正在等待日志邮箱与 DB 队列排空…';
    try {
      const drained = await this.awaitCachePipelineDrained('自动写入停止');
      this.appendResult(drained
        ? '自动写入排空完成：日志邮箱与此前 DB 写入均已越过栅栏。\n'
        : '自动写入排空超时：DB 栅栏已执行，但日志邮箱仍有待处理命令；请稍后再做预检或清空。\n');
    } finally {
      this.phaseOnePreflightProgress = '';
      this.isRunning = false;
    }
  }

  /**
   * Mailbox completion means drafts were handed back to the host. The ordered
   * DB barrier immediately afterwards includes those host-enqueued writes.
   */
  private async awaitCachePipelineDrained(label: string): Promise<boolean> {
    const mailboxDrained = await TrackLogManager.getInstance().flushAndWait(30000);
    await FTDBTaskPoolExecutor.awaitIdle(this.context);
    this.appendResult(`${label}：mailbox=${mailboxDrained ? '已排空' : '超时'}，DB 栅栏已完成。\n`);
    return mailboxDrained;
  }

  private async clearAllCacheData() {
    this.isRunning = true;
    this.cacheClearProgress = '正在停止自动写入…';
    try {
      if (this.autoWriteEnabled) {
        this.stopAutoWrite();
      }
      this.appendResult('\n=== 清空所有缓存数据（FTSDK.clearAllData）===\n');
      this.startCacheClearProgress();
      this.cacheClearProgress = '正在等待日志邮箱与 DB 队列排空，随后执行清空…';
      const drained = await this.awaitCachePipelineDrained('清空前排空');
      if (!drained) {
        this.appendResult('清空前日志邮箱排空超时；为避免遗漏，取消本次清空，请稍后重试。\n');
        this.cacheClearProgress = '日志邮箱仍在处理，未执行清空；请稍后重试。';
        return;
      }
      await FTSDK.clearAllData();
      this.stopCacheClearProgress();
      this.cacheClearProgress = '缓存删除已完成，正在刷新数据库计数…';
      this.writeCount = 0;
      this.limitReachedNoticeShown = false;
      await this.refreshActualDbCounts(true);
      this.updatePolicyInfo();
      this.appendResult(`已清空所有缓存数据。实际 DB 计数：Log=${this.actualLogDbCountText}，RUM=${this.actualRumDbCountText}\n`);
      this.cacheClearProgress = '正在校验清空后的统一缓存快照…';
      const snapshot = await this.loadUnifiedCacheSnapshot('clearAllData 后');
      this.appendUnifiedCacheSnapshot(snapshot);
      const cleared = snapshot.status.syncCount === 0 && snapshot.status.viewCount === 0 &&
        snapshot.status.actionCount === 0 && snapshot.status.usage.spoolBytes === 0;
      this.appendResult(cleared
        ? '清理：通过。sync / view / action / spool 均已清空；控制文件可保留。请冷启动后再次检查，确认旧数据不会恢复。\n'
        : '清理：尚不能下结论。请等待 worker 结束后再次刷新；sync / view / action / spool 必须全部为 0。\n');
      this.cacheClearProgress = cleared ? '清空完成，统一缓存校验通过。' : '清空已提交，统一缓存仍有待清理数据；请查看测试结果。';
    } catch (error) {
      this.appendResult(`清空所有缓存数据失败：${error}\n`);
      this.cacheClearProgress = '清空失败，请查看下方测试结果。';
    } finally {
      this.stopCacheClearProgress();
      this.isRunning = false;
    }
  }

  /**
   * Write logs in batch
   */
  private async writeLogsBatch(count: number): Promise<void> {
    this.isRunning = true;
    this.appendResult(`=== Writing ${count} Logs ===\n`);
    
    try {
      for (let i = 0; i < count; i++) {
        const logMessage = `Batch log ${i + 1} - ${new Date().toISOString()}`;
        FTLogger.logBackground(logMessage, Status.INFO, undefined, true);
        if ((i + 1) % 50 === 0) {
          await this.yieldToUi();
        }
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
  private async writeRUMBatch(count: number): Promise<void> {
    this.isRunning = true;
    this.appendResult(`=== Writing ${count} RUM Data ===\n`);
    
    try {
      const rumManager = FTRUMGlobalManager.getInstance();
      
      for (let i = 0; i < count; i++) {
        rumManager.addAction(`BatchAction_${i}`, 'click');
        rumManager.addError(`Error ${i}`, `BatchError_${i}`, ErrorType.CUSTOM, AppState.RUN);
        if ((i + 1) % 25 === 0) {
          await this.yieldToUi();
        }
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
      const actualDbSize = await this.queryCurrentDbSize();
      const logDbCount = await this.queryDbCount([DataType.LOG]);
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
    this.appendResult(`${stopReason}。${this.getCapacityUsageLabel()}：${this.currentDbSize}，RUM 数量：${this.rumCountText}，日志数量：${this.logCountText}\n`);
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

  private async queryCurrentDbSize(): Promise<number> {
    return await FTDBTaskPoolExecutor.getCurrentDatabaseSize(this.context);
  }

  private async queryDbCount(types: DataType[]): Promise<number> {
    return await FTDBTaskPoolExecutor.queryTotalCount(this.context, this.toDbDataTypeStrings(types));
  }

  private async queryDbSamples(types: DataType[], limit: number, newestFirst: boolean): Promise<SyncData[]> {
    return await FTDBTaskPoolExecutor.querySyncData(
      this.context,
      this.toDbDataTypeStrings(types),
      limit,
      newestFirst
    );
  }

  private toDbDataTypeStrings(types: DataType[]): string[] {
    const result: string[] = [];
    for (let i = 0; i < types.length; i++) {
      result.push(types[i].toString());
    }
    return result;
  }

  private async getRumDbCount(): Promise<number> {
    return await this.queryDbCount([DataType.RUM_APP, DataType.RUM_WEBVIEW]);
  }

  private async queryRumDbSamples(limit: number, newestFirst: boolean): Promise<SyncData[]> {
    return await this.queryDbSamples([DataType.RUM_APP, DataType.RUM_WEBVIEW], limit, newestFirst);
  }

  private async queryLogDbSamples(limit: number, newestFirst: boolean): Promise<SyncData[]> {
    return await this.queryDbSamples([DataType.LOG], limit, newestFirst);
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

  private yieldToUi(): Promise<void> {
    return this.waitForWriteSettled(0);
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
    this.appendResultToBuffer(text);
    this.scheduleResultFlush();

    const trimmed = text.trim();
    if (trimmed.length > 0) {
      DemoLogger.i(TAG, trimmed.length > 1000 ? `${trimmed.substring(0, 1000)}...` : trimmed);
    }
  }

  private appendResultToBuffer(text: string): void {
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      this.resultLines.push(lines[i]);
    }
    if (this.resultLines.length > MAX_RESULT_LINES) {
      this.resultLines.splice(0, this.resultLines.length - MAX_RESULT_LINES);
    }
  }

  private scheduleResultFlush(): void {
    if (this.resultFlushTimer !== -1) {
      return;
    }
    this.resultFlushTimer = setTimeout(() => {
      this.resultFlushTimer = -1;
      this.flushResultBuffer();
    }, 100) as number;
  }

  private flushResultBuffer(): void {
    this.testResults = this.resultLines.join('\n');
  }

  /**
   * Clear the visible test results.
   */
  private clearResults() {
    if (this.resultFlushTimer !== -1) {
      clearTimeout(this.resultFlushTimer);
      this.resultFlushTimer = -1;
    }
    this.resultLines = [];
    this.testResults = '';
    DemoLogger.i(TAG, 'Test results cleared');
  }
}
