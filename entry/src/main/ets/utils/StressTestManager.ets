import {
  AppState,
  applyFTAxiosTrack,
  createFTRCPTrackConfig,
  ErrorType,
  FTLogger,
  FTSDK,
  FTRUMGlobalManager,
  NetStatusBean,
  ResourceParams,
  StringWrapper
} from '@guancecloud/ft_sdk/Index';
import { LogEntry } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { TrackLogManager } from '@guancecloud/ft_sdk/src/main/ets/components/log/TrackLogManager';
import {
  SDKDedicatedPoolManager,
  SDKDedicatedPoolStatus
} from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKDedicatedPoolManager';
import { SDKDedicatedPoolType } from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKWorkerProtocol';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import { applyFTHttpTrack, disposeFTHttpTrack } from '@guancecloud/ft_sdk_ext/Index';
import axios, { AbortController, AxiosInstance, AxiosRequestConfig, AxiosResponse } from '@ohos/axios';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from './DemoLogger';
import { StressLogTimestampSequencer } from './StressLogTimestampSequencer';
import {
  buildStressResourceUrl,
  createStressResourceRequestPlan,
  normalizeStressResourceClient,
  normalizeStressResourceScenario,
  StressResourceClient,
  StressResourceRequestPlan,
  StressResourceScenario
} from './StressResourceScenarios';

const TAG = "StressTestManager";
const STRESS_TEST_LOG_TAG = "stress_test";
export const DEFAULT_REAL_TRAFFIC_URL = "https://httpbin.org/get?from=real-app-stress";
const MS_TO_NS = 1000000;
const REAL_RESOURCE_CONNECT_TIMEOUT_MS = 60 * 1000;
const REAL_RESOURCE_TRANSFER_TIMEOUT_MS = 5 * 60 * 1000;
const REAL_RESOURCE_INACTIVITY_TIMEOUT_MS = 60 * 1000;
const REAL_RESOURCE_MAX_CONNECTIONS_PER_HOST = 256;
const REAL_RESOURCE_MAX_TOTAL_CONNECTIONS = 512;
const CAPABILITY_CASE_NAME = "real-mixed-consumer-manual";
const CAPABILITY_SAMPLE_INTERVAL_MS = 500;
const CAPABILITY_UI_TICK_INTERVAL_MS = 50;
const CAPABILITY_UI_LIGHT_JANK_MS = 16;
const CAPABILITY_UI_MODERATE_JANK_MS = 50;
const CAPABILITY_UI_STRONG_JANK_MS = 100;
const FINAL_UPLOAD_FLUSH_DELAY_MS = 0;
const CAPABILITY_VM_HEAP_FALLBACK_LIMIT_MB = 256;
const CAPABILITY_VM_HEAP_SAFE_WATERMARK = 0.80;
const CAPABILITY_RESERVED_HEAP_MB = 25;
const BYTES_PER_KB = 1024;
const BYTES_PER_MB = 1024 * 1024;
const CAPABILITY_TEMPERATURE_UNAVAILABLE_C = -1000;
const CAPABILITY_TEMPERATURE_ZONE_COUNT = 16;
const STRESS_PRODUCTION_CHUNK_SIZE = 20;
const STRESS_PRODUCTION_SLICE_DELAY_MS = 0;
const CAPABILITY_LANE_TYPES: SDKDedicatedPoolType[] = [
  SDKDedicatedPoolType.EVENT_CONSUMER,
  SDKDedicatedPoolType.LOG_CONSUMER,
  SDKDedicatedPoolType.DATA_PROCESS,
  SDKDedicatedPoolType.DATA_UPLOAD
];
const CAPABILITY_CPU_TEMPERATURE_TYPE_KEYWORDS: string[] = [
  'cpu',
  'soc',
  'ap',
  'cluster',
  'tsens',
  'mtktscpu'
];
const CAPABILITY_BATTERY_TEMPERATURE_PATHS: string[] = [
  '/sys/class/power_supply/battery/temp',
  '/sys/class/power_supply/battery/batt_temp'
];

export type StressStopReason = 'manual' | 'duration' | 'completed' | 'service-stop' | 'service-destroyed' | 'error';
export type StressTrafficMode = 'fake' | 'real';
export type StressRunSource = 'foreground' | 'background-service';
export type StressRunMode = 'duration' | 'total';

export interface StressTestConfig {
  durationSeconds: number;
  runMode: StressRunMode;
  totalTargetCount: number;
  trafficMode: StressTrafficMode;
  source: StressRunSource;
  enableLogs: boolean;
  enableActions: boolean;
  enableResources: boolean;
  enableNavigation: boolean;
  enableErrors: boolean;
  enableLongTasks: boolean;
  logThreadCount: number;
  logTotalCount: number;
  logBatchSize: number;
  logIntervalMs: number;
  actionThreadCount: number;
  actionIntervalMs: number;
  resourceThreadCount: number;
  resourceIntervalMs: number;
  realResourceUrl: string;
  realResourceClient: StressResourceClient;
  realResourceScenario: StressResourceScenario;
  navigationIntervalMs: number;
  errorBatchSize: number;
  errorIntervalMs: number;
  longTaskBatchSize: number;
  longTaskIntervalMs: number;
}

export interface StressTestStats {
  isRunning: boolean;
  startedAtMs: number;
  endedAtMs: number;
  durationSeconds: number;
  runMode: StressRunMode;
  totalTargetCount: number;
  elapsedSeconds: number;
  remainingSeconds: number;
  trafficMode: StressTrafficMode;
  source: StressRunSource;
  enableLogs: boolean;
  enableActions: boolean;
  enableResources: boolean;
  enableNavigation: boolean;
  enableErrors: boolean;
  enableLongTasks: boolean;
  logsGenerated: number;
  logBatchesGenerated: number;
  actionsGenerated: number;
  resourcesGenerated: number;
  resourcesSucceeded: number;
  resourcesFailed: number;
  navigationSwitches: number;
  navigationIntervalMs: number;
  errorsGenerated: number;
  longTasksGenerated: number;
  uiJankSamples: number;
  uiJankMaxDriftMs: number;
  uiJankAvgDriftMs: number;
  uiJankOver16Count: number;
  uiJankOver50Count: number;
  uiJankOver100Count: number;
  lastErrorMessage: string;
}

export interface StressCapabilityLaneMetric {
  laneName: string;
  backend: string;
  lastError: string;
  submitted: number;
  completed: number;
  failed: number;
  pending: number;
  mailboxPending: number;
  running: number;
  queuedTasks: number;
  avgWaitMs: number;
  avgCostMs: number;
  oldestWaitMs: number;
  bottleneck: string;
}

export interface StressCapabilityBusinessMetric {
  eventType: string;
  taskGroup: string;
  laneName: string;
  submitted: number;
  completed: number;
  failed: number;
  queuedTasks: number;
  avgWaitMs: number;
  avgCostMs: number;
  maxWaitMs: number;
  maxCostMs: number;
  bottleneck: string;
}

export interface StressCapabilityReport {
  caseName: string;
  inputMixedTasks: number;
  enabledFeatureCount: number;
  sampleCount: number;
  peakQueue: number;
  peakSchedulerQueue: number;
  peakLogQueue: number;
  peakQueueElapsedMs: number;
  heapStartMb: number;
  heapPeakMb: number;
  heapEndMb: number;
  heapDeltaMb: number;
  peakHeapDeltaMb: number;
  avgQueuedTaskKb: number;
  vmHeapLimitMb: number;
  vmHeapLimitSource: string;
  safeWatermark: number;
  reservedHeapMb: number;
  safeQueueEstimate: number;
  productionQps: number;
  completionQps: number;
  backlogGrowthPerSecond: number;
  secondsToHighRisk: number;
  slowLane: string;
  slowLaneAvgWaitMs: number;
  slowLaneAvgCostMs: number;
  slowLaneBottleneck: string;
  slowBusinessEvent: string;
  slowBusinessTaskGroup: string;
  slowBusinessLane: string;
  slowBusinessAvgWaitMs: number;
  slowBusinessAvgCostMs: number;
  logSubmitted: number;
  logAccepted: number;
  logDropped: number;
  logDropRate: number;
  logDropCause: string;
  uiJankSamples: number;
  uiJankMaxDriftMs: number;
  uiJankAvgDriftMs: number;
  uiJankOver16Count: number;
  uiJankOver50Count: number;
  uiJankOver100Count: number;
  temperatureAvailable: boolean;
  temperatureKind: string;
  temperatureSource: string;
  temperatureStartC: number;
  temperaturePeakC: number;
  temperatureEndC: number;
  temperatureDeltaC: number;
  lanes: StressCapabilityLaneMetric[];
  businessEvents: StressCapabilityBusinessMetric[];
}

interface StressCapabilitySample {
  label: string;
  elapsedMs: number;
  schedulerQueue: number;
  logQueue: number;
  queueTotal: number;
  runningTotal: number;
  completedTotal: number;
  failedTotal: number;
  heapUsedBytes: number;
  temperatureAvailable: boolean;
  temperatureC: number;
}

interface VmHeapSnapshot {
  usedBytes: number;
  limitBytes: number;
  available: boolean;
}

interface VmHeapLimitSnapshot {
  limitBytes: number;
  source: string;
}

interface TemperatureProbe {
  tempPath: string;
  kind: string;
  source: string;
}

interface TemperatureSnapshot {
  available: boolean;
  celsius: number;
  kind: string;
  source: string;
}

export interface StressTestReport {
  stopReason: StressStopReason;
  startedAtMs: number;
  endedAtMs: number;
  elapsedSeconds: number;
  durationSeconds: number;
  stats: StressTestStats;
  capabilityReport: StressCapabilityReport | null;
}

export function createDefaultStressTestConfig(
  durationSeconds: number = 0,
  useRealData: boolean = false,
  source: StressRunSource = 'foreground'
): StressTestConfig {
  return {
    durationSeconds,
    runMode: 'duration',
    totalTargetCount: 0,
    trafficMode: useRealData ? 'real' : 'fake',
    source,
    enableLogs: true,
    enableActions: true,
    enableResources: true,
    enableNavigation: true,
    enableErrors: false,
    enableLongTasks: false,
    logThreadCount: 4,
    logTotalCount: 0,
    logBatchSize: 1,
    logIntervalMs: 20,
    actionThreadCount: 2,
    actionIntervalMs: 20,
    resourceThreadCount: 2,
    resourceIntervalMs: 200,
    realResourceUrl: "",
    realResourceClient: 'mixed',
    realResourceScenario: 'custom',
    navigationIntervalMs: 1000,
    errorBatchSize: 1,
    errorIntervalMs: 1000,
    longTaskBatchSize: 1,
    longTaskIntervalMs: 1500
  };
}

export function createEmptyStressTestStats(): StressTestStats {
  return {
    isRunning: false,
    startedAtMs: 0,
    endedAtMs: 0,
    durationSeconds: 0,
    runMode: 'duration',
    totalTargetCount: 0,
    elapsedSeconds: 0,
    remainingSeconds: -1,
    trafficMode: 'fake',
    source: 'foreground',
    enableLogs: false,
    enableActions: false,
    enableResources: false,
    enableNavigation: false,
    enableErrors: false,
    enableLongTasks: false,
    logsGenerated: 0,
    logBatchesGenerated: 0,
    actionsGenerated: 0,
    resourcesGenerated: 0,
    resourcesSucceeded: 0,
    resourcesFailed: 0,
    navigationSwitches: 0,
    navigationIntervalMs: 1000,
    errorsGenerated: 0,
    longTasksGenerated: 0,
    uiJankSamples: 0,
    uiJankMaxDriftMs: 0,
    uiJankAvgDriftMs: 0,
    uiJankOver16Count: 0,
    uiJankOver50Count: 0,
    uiJankOver100Count: 0,
    lastErrorMessage: ""
  };
}

/**
 * Stress Test Manager - Singleton class for managing stress test timers, counters, and reports.
 */
export class StressTestManager {
  private static instance: StressTestManager | null = null;

  private logIntervalIds: number[] = [];
  private actionIntervalIds: number[] = [];
  private resourceIntervalIds: number[] = [];
  private exceptionIntervalIds: number[] = [];
  private finalUploadFlushTimerId: number | null = null;
  private productionSliceTimerIds: number[] = [];

  private isRunning: boolean = false;
  private startTime: number = 0;
  private durationSeconds: number = 0;
  private autoStopTimerId: number | null = null;

  private rumManager: FTRUMGlobalManager | null = null;
  private realResourceSession: rcp.Session | null = null;
  private realResourceAxiosClient: AxiosInstance | null = null;
  private activeHttpRequests: http.HttpRequest[] = [];
  private activeAxiosControllers: AbortController[] = [];
  private currentConfig: StressTestConfig = createDefaultStressTestConfig(0, false);
  private currentStats: StressTestStats = createEmptyStressTestStats();
  private lastReport: StressTestReport | null = null;
  private capabilitySamples: StressCapabilitySample[] = [];
  private capabilitySampleTimerId: number | null = null;
  private capabilityUiTickTimerId: number | null = null;
  private capabilityStartedAtMs: number = 0;
  private capabilityLastSampleAtMs: number = 0;
  private capabilityUiLastTickAtMs: number = 0;
  private capabilityUiJankSamples: number = 0;
  private capabilityUiJankTotalDriftMs: number = 0;
  private capabilityUiJankMaxDriftMs: number = 0;
  private capabilityUiJankOver16Count: number = 0;
  private capabilityUiJankOver50Count: number = 0;
  private capabilityUiJankOver100Count: number = 0;
  private capabilityHeapStartBytes: number = 0;
  private capabilityHeapLimit: VmHeapLimitSnapshot = {
    limitBytes: CAPABILITY_VM_HEAP_FALLBACK_LIMIT_MB * BYTES_PER_MB,
    source: 'fallback'
  };
  private capabilityTemperatureProbe: TemperatureProbe | null = null;
  private logBatchRunning: boolean = false;
  private errorBatchRunning: boolean = false;
  private longTaskBatchRunning: boolean = false;
  private readonly logTimestampSequencer: StressLogTimestampSequencer = new StressLogTimestampSequencer();

  private logCounter: number = 0;
  private actionCounter: number = 0;
  private resourceCounter: number = 0;
  private errorCounter: number = 0;
  private longTaskCounter: number = 0;

  private constructor() {
  }

  public static getInstance(): StressTestManager {
    if (StressTestManager.instance === null) {
      StressTestManager.instance = new StressTestManager();
    }
    return StressTestManager.instance;
  }

  private getTraceTestUrls(): string[] {
    const stressUrls = this.parseResourceUrls(this.currentConfig.realResourceUrl);
    if (stressUrls.length > 0) {
      return stressUrls;
    }

    const configuredUrl = ((AppStorage.get(KEY_TRACE_URL) as string | undefined) ?? "").trim();
    const configuredUrls = this.parseResourceUrls(configuredUrl);
    if (configuredUrls.length > 0) {
      return configuredUrls;
    }

    return [DEFAULT_REAL_TRAFFIC_URL];
  }

  private parseResourceUrls(rawUrls: string): string[] {
    const urls: string[] = [];
    let url = "";
    for (let i = 0; i < rawUrls.length; i++) {
      const char = rawUrls.charAt(i);
      if (char === '\n' || char === '\r') {
        this.appendResourceUrl(urls, url);
        url = "";
      } else {
        url += char;
      }
    }
    this.appendResourceUrl(urls, url);
    return urls;
  }

  private appendResourceUrl(urls: string[], rawUrl: string): void {
    const trimmedUrl = rawUrl.trim();
    if (trimmedUrl.length > 0) {
      urls.push(trimmedUrl);
    }
  }

  private formatResourceUrlSummary(rawUrls: string): string {
    const urlCount = this.parseResourceUrls(rawUrls).length;
    return urlCount > 0 ? `${urlCount} configured` : 'traceUrl/default';
  }

  private isRumEnabled(): boolean {
    const rumConfig = FTSDK.getRumConfig();
    return rumConfig !== null && rumConfig.getRumAppId().length > 0;
  }

  private initRUM(): void {
    if (this.rumManager === null) {
      this.rumManager = FTRUMGlobalManager.getInstance();
      if (this.rumManager === null) {
        DemoLogger.e(TAG, "Failed to get FTRUMGlobalManager instance");
        return;
      }
      if (!this.isRumEnabled()) {
        DemoLogger.w(TAG, "RUM Manager not initialized, stress test may not work correctly");
      } else {
        DemoLogger.i(TAG, "RUM Manager initialized successfully");
      }
    }
  }

  public createConfig(
    durationSeconds: number,
    useRealData: boolean,
    enableLogs: boolean,
    enableActions: boolean,
    enableResources: boolean,
    enableNavigation: boolean,
    enableErrors: boolean,
    enableLongTasks: boolean,
    source: StressRunSource = 'foreground'
  ): StressTestConfig {
    const config = createDefaultStressTestConfig(durationSeconds, useRealData, source);
    config.enableLogs = enableLogs;
    config.enableActions = enableActions;
    config.enableResources = enableResources;
    config.enableNavigation = enableNavigation;
    config.enableErrors = enableErrors;
    config.enableLongTasks = enableLongTasks;
    return this.normalizeConfig(config);
  }

  /**
   * Backward-compatible start API.
   */
  public run(durationSeconds: number = 0, useRealData: boolean = true): void {
    this.runWithConfig(createDefaultStressTestConfig(durationSeconds, useRealData));
  }

  /**
   * Start a configurable stress test.
   */
  public runWithConfig(config: StressTestConfig): void {
    if (this.isRunning) {
      DemoLogger.w(TAG, "Stress test is already running");
      return;
    }

    const normalizedConfig = this.normalizeConfig(config);
    this.initRUM();
    this.isRunning = true;
    this.startTime = Date.now();
    this.durationSeconds = normalizedConfig.durationSeconds;
    this.closeRealResourceClients();
    this.clearFinalUploadFlushTimer();
    this.currentConfig = normalizedConfig;
    this.lastReport = null;
    this.logCounter = 0;
    this.logTimestampSequencer.reset();
    this.actionCounter = 0;
    this.resourceCounter = 0;
    this.errorCounter = 0;
    this.longTaskCounter = 0;
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];
    this.exceptionIntervalIds = [];
    this.productionSliceTimerIds = [];
    this.logBatchRunning = false;
    this.errorBatchRunning = false;
    this.longTaskBatchRunning = false;
    this.currentStats = this.createStatsForStart(normalizedConfig, this.startTime);
    this.startCapabilitySampling();

    if (this.shouldFailTotalCountStartForRum(normalizedConfig)) {
      const message = "RUM is not initialized; total-count mode cannot run RUM-dependent scenarios";
      this.recordErrorMessage(message);
      DemoLogger.e(TAG, message);
      this.stop('error');
      return;
    }

    DemoLogger.i(TAG,
      `Starting stress test: mode=${normalizedConfig.runMode}, duration=${this.formatDurationForLog(normalizedConfig.durationSeconds)}, totalTarget=${normalizedConfig.totalTargetCount > 0 ? normalizedConfig.totalTargetCount : 'none'}, traffic=${normalizedConfig.trafficMode}, source=${normalizedConfig.source}, logs=${normalizedConfig.enableLogs}, logTotal=${normalizedConfig.logTotalCount}, logBatchSize=${normalizedConfig.logBatchSize}, logInterval=${normalizedConfig.logIntervalMs}, actions=${normalizedConfig.enableActions}, resources=${normalizedConfig.enableResources}, resourceUrls=${this.formatResourceUrlSummary(normalizedConfig.realResourceUrl)}, navigation=${normalizedConfig.enableNavigation}, navigationInterval=${normalizedConfig.navigationIntervalMs}, errors=${normalizedConfig.enableErrors}, errorBatchSize=${normalizedConfig.errorBatchSize}, errorInterval=${normalizedConfig.errorIntervalMs}, longTasks=${normalizedConfig.enableLongTasks}, longTaskBatchSize=${normalizedConfig.longTaskBatchSize}, longTaskInterval=${normalizedConfig.longTaskIntervalMs}`);

    if (normalizedConfig.enableLogs) {
      this.startLogTimers(normalizedConfig);
    }
    if (normalizedConfig.enableActions) {
      this.startActionTimers(normalizedConfig);
    }
    if (normalizedConfig.enableResources) {
      this.startResourceTimers(normalizedConfig);
    }
    if (normalizedConfig.enableErrors) {
      this.startCustomErrorTimer(normalizedConfig);
    }
    if (normalizedConfig.enableLongTasks) {
      this.startLongTaskTimer(normalizedConfig);
    }
    if (normalizedConfig.runMode === 'duration' && normalizedConfig.durationSeconds > 0) {
      this.startAutoStopTimer(normalizedConfig);
    }
  }

  private shouldFailTotalCountStartForRum(config: StressTestConfig): boolean {
    if (!this.isTotalCountMode(config)) {
      return false;
    }
    if (!this.hasRumDependentScenario(config)) {
      return false;
    }
    return this.rumManager === null || !this.isRumEnabled();
  }

  private hasRumDependentScenario(config: StressTestConfig): boolean {
    return config.enableActions ||
      config.enableResources ||
      config.enableErrors ||
      config.enableLongTasks;
  }

  private scheduleLogBatch(batchSize: number = 2, tag: string = STRESS_TEST_LOG_TAG): void {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    if (normalizedBatchSize <= 0 || this.logBatchRunning) {
      return;
    }
    this.logBatchRunning = true;
    this.drainLogBatch(normalizedBatchSize, tag);
  }

  private drainLogBatch(remainingCount: number, tag: string): void {
    if (!this.isRunning || remainingCount <= 0) {
      this.logBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    const chunkSize = Math.min(STRESS_PRODUCTION_CHUNK_SIZE, remainingCount);
    this.sendLogBatchChunk(chunkSize, tag);
    const nextRemaining = remainingCount - chunkSize;
    this.finishTotalCountStressIfComplete();
    if (nextRemaining <= 0 || this.isScenarioTargetReached(this.currentStats.logsGenerated, this.currentConfig)) {
      this.logBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    this.scheduleProductionSlice((): void => {
      this.drainLogBatch(nextRemaining, tag);
    });
  }

  private sendLogBatchChunk(batchSize: number, tag: string): void {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const batchLogs: LogEntry[] = [];
    const chunkTimestampMs = Date.now();

    for (let i = 0; i < normalizedBatchSize; i++) {
      const logIndex = this.logCounter++;
      batchLogs.push({
        tag,
        message: this.createBatchLogMessage(logIndex),
        level: 'i',
        timestampMs: this.logTimestampSequencer.next(chunkTimestampMs)
      });
    }

    try {
      FTLogger.batchLog(batchLogs);
      this.currentStats.logsGenerated += batchLogs.length;
      this.currentStats.logBatchesGenerated += 1;
      this.sampleCapabilityIfDue('log-batch');
    } catch (error) {
      this.recordErrorMessage(`batchLog failed: ${error}`);
      DemoLogger.e(TAG, `Failed to submit log batch: ${error}`);
    }
  }

  private createBatchLogMessage(logIndex: number): string {
    const displayIndex = logIndex + 1;
    return `Stress test log ${displayIndex}`;
  }

  private normalizeConfig(config: StressTestConfig): StressTestConfig {
    const runMode: StressRunMode = config.runMode === 'total' ? 'total' : 'duration';
    const normalizedTotalTarget = Math.max(0, Math.floor(config.totalTargetCount));
    return {
      durationSeconds: runMode === 'duration' ? Math.max(0, Math.floor(config.durationSeconds)) : 0,
      runMode,
      totalTargetCount: runMode === 'total' ? Math.max(1, normalizedTotalTarget) : normalizedTotalTarget,
      trafficMode: config.trafficMode === 'real' ? 'real' : 'fake',
      source: config.source === 'background-service' ? 'background-service' : 'foreground',
      enableLogs: config.enableLogs,
      enableActions: config.enableActions,
      enableResources: config.enableResources,
      enableNavigation: config.enableNavigation,
      enableErrors: config.enableErrors,
      enableLongTasks: config.enableLongTasks,
      logThreadCount: Math.max(0, Math.floor(config.logThreadCount)),
      logTotalCount: Math.max(0, Math.floor(config.logTotalCount)),
      logBatchSize: Math.max(1, Math.floor(config.logBatchSize)),
      logIntervalMs: Math.max(16, Math.floor(config.logIntervalMs)),
      actionThreadCount: Math.max(0, Math.floor(config.actionThreadCount)),
      actionIntervalMs: Math.max(16, Math.floor(config.actionIntervalMs)),
      resourceThreadCount: Math.max(0, Math.floor(config.resourceThreadCount)),
      resourceIntervalMs: Math.max(50, Math.floor(config.resourceIntervalMs)),
      realResourceUrl: (config.realResourceUrl ?? "").trim(),
      realResourceClient: normalizeStressResourceClient(config.realResourceClient ?? 'mixed'),
      realResourceScenario: normalizeStressResourceScenario(config.realResourceScenario ?? 'custom'),
      navigationIntervalMs: Math.max(250, Math.floor(config.navigationIntervalMs)),
      errorBatchSize: Math.max(1, Math.floor(config.errorBatchSize)),
      errorIntervalMs: Math.max(250, Math.floor(config.errorIntervalMs)),
      longTaskBatchSize: Math.max(1, Math.floor(config.longTaskBatchSize)),
      longTaskIntervalMs: Math.max(250, Math.floor(config.longTaskIntervalMs))
    };
  }

  private createStatsForStart(config: StressTestConfig, startedAtMs: number): StressTestStats {
    const stats = createEmptyStressTestStats();
    stats.isRunning = true;
    stats.startedAtMs = startedAtMs;
    stats.durationSeconds = config.durationSeconds;
    stats.runMode = config.runMode;
    stats.totalTargetCount = config.totalTargetCount;
    stats.remainingSeconds = config.durationSeconds > 0 ? config.durationSeconds : -1;
    stats.trafficMode = config.trafficMode;
    stats.source = config.source;
    stats.enableLogs = config.enableLogs;
    stats.enableActions = config.enableActions;
    stats.enableResources = config.enableResources;
    stats.enableNavigation = config.enableNavigation;
    stats.navigationIntervalMs = config.navigationIntervalMs;
    stats.enableErrors = config.enableErrors;
    stats.enableLongTasks = config.enableLongTasks;
    return stats;
  }

  private startLogTimers(config: StressTestConfig): void {
    for (let i = 0; i < config.logThreadCount; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        if (!this.emitConfiguredLogs(threadIndex, config)) {
          clearInterval(intervalId);
        }
      }, config.logIntervalMs);
      this.logIntervalIds.push(intervalId);
    }
    if (config.logThreadCount > 0) {
      DemoLogger.i(TAG,
        `Log timers started: count=${config.logThreadCount}, interval=${config.logIntervalMs}ms, batchSize=${config.logBatchSize}, total=${config.logTotalCount > 0 ? config.logTotalCount : 'unlimited'}`);
    }
  }

  private startAutoStopTimer(config: StressTestConfig): void {
    const stopDelayMs = config.durationSeconds * 1000 + this.getAutoStopGraceMs(config);
    this.autoStopTimerId = setTimeout((): void => {
      const actualElapsed = this.getElapsedSeconds();
      DemoLogger.i(TAG, `Stress test duration reached, auto-stopping. elapsed=${actualElapsed}s`);
      this.autoStopTimerId = setTimeout((): void => {
        this.stop('duration');
      }, 0);
    }, stopDelayMs);
  }

  private getAutoStopGraceMs(config: StressTestConfig): number {
    let minIntervalMs = Number.MAX_SAFE_INTEGER;
    if (config.enableLogs && config.logThreadCount > 0) {
      minIntervalMs = Math.min(minIntervalMs, config.logIntervalMs);
    }
    if (config.enableActions && config.actionThreadCount > 0) {
      minIntervalMs = Math.min(minIntervalMs, config.actionIntervalMs);
    }
    if (config.enableResources && config.resourceThreadCount > 0) {
      minIntervalMs = Math.min(minIntervalMs, config.resourceIntervalMs);
    }
    if (config.enableNavigation) {
      minIntervalMs = Math.min(minIntervalMs, config.navigationIntervalMs);
    }
    if (config.enableErrors) {
      minIntervalMs = Math.min(minIntervalMs, config.errorIntervalMs);
    }
    if (config.enableLongTasks) {
      minIntervalMs = Math.min(minIntervalMs, config.longTaskIntervalMs);
    }
    if (minIntervalMs === Number.MAX_SAFE_INTEGER || minIntervalMs <= 1) {
      return 0;
    }
    return Math.min(100, minIntervalMs - 1);
  }

  private isTotalCountMode(config: StressTestConfig): boolean {
    return config.runMode === 'total' && config.totalTargetCount > 0;
  }

  private getLogTargetCount(config: StressTestConfig): number {
    if (config.logTotalCount > 0) {
      return config.logTotalCount;
    }
    return this.isTotalCountMode(config) ? config.totalTargetCount : 0;
  }

  private isScenarioTargetReached(generatedCount: number, config: StressTestConfig): boolean {
    return this.isTotalCountMode(config) && generatedCount >= config.totalTargetCount;
  }

  private getRemainingScenarioTarget(generatedCount: number, config: StressTestConfig): number {
    if (!this.isTotalCountMode(config)) {
      return Number.MAX_SAFE_INTEGER;
    }
    return Math.max(0, config.totalTargetCount - generatedCount);
  }

  private getCompletedResourceCount(): number {
    return this.currentStats.resourcesSucceeded + this.currentStats.resourcesFailed;
  }

  private finishTotalCountStressIfComplete(): void {
    if (!this.isRunning || !this.isTotalCountMode(this.currentConfig)) {
      return;
    }

    const targetCount = this.currentConfig.totalTargetCount;
    if (this.currentConfig.enableLogs && this.currentStats.logsGenerated < targetCount) {
      return;
    }
    if (this.currentConfig.enableActions && this.currentStats.actionsGenerated < targetCount) {
      return;
    }
    if (this.currentConfig.enableResources && this.getCompletedResourceCount() < targetCount) {
      return;
    }
    if (this.currentConfig.enableNavigation && this.currentStats.navigationSwitches < targetCount) {
      return;
    }
    if (this.currentConfig.enableErrors && this.currentStats.errorsGenerated < targetCount) {
      return;
    }
    if (this.currentConfig.enableLongTasks && this.currentStats.longTasksGenerated < targetCount) {
      return;
    }

    DemoLogger.i(TAG, `Total-count stress test completed: target=${targetCount}`);
    this.stop('completed');
  }

  private emitConfiguredLogs(threadIndex: number, config: StressTestConfig): boolean {
    const targetCount = this.getLogTargetCount(config);
    if (targetCount > 0 && this.currentStats.logsGenerated >= targetCount) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    const remaining = targetCount > 0 ? targetCount - this.currentStats.logsGenerated : config.logBatchSize;
    const emitCount = Math.min(config.logBatchSize, remaining);
    if (emitCount <= 0) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    if (emitCount === 1) {
      this.sendLog(threadIndex);
    } else {
      this.scheduleLogBatch(emitCount, STRESS_TEST_LOG_TAG);
    }
    this.finishTotalCountStressIfComplete();
    return !(targetCount > 0 && this.currentStats.logsGenerated >= targetCount);
  }

  private startActionTimers(config: StressTestConfig): void {
    for (let i = 0; i < config.actionThreadCount; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        if (!this.emitConfiguredAction(threadIndex, config)) {
          clearInterval(intervalId);
        }
      }, config.actionIntervalMs);
      this.actionIntervalIds.push(intervalId);
    }
    if (config.actionThreadCount > 0) {
      DemoLogger.i(TAG,
        `Action timers started: count=${config.actionThreadCount}, interval=${config.actionIntervalMs}ms`);
    }
  }

  private emitConfiguredAction(threadIndex: number, config: StressTestConfig): boolean {
    if (this.isScenarioTargetReached(this.currentStats.actionsGenerated, config)) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    this.sendAction(threadIndex);
    this.finishTotalCountStressIfComplete();
    return !this.isScenarioTargetReached(this.currentStats.actionsGenerated, config);
  }

  private startResourceTimers(config: StressTestConfig): void {
    for (let i = 0; i < config.resourceThreadCount; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        if (this.isScenarioTargetReached(this.currentStats.resourcesGenerated, config)) {
          this.finishTotalCountStressIfComplete();
          clearInterval(intervalId);
          return;
        }
        const runStats = this.currentStats;
        this.sendResource(threadIndex).catch((error: Error) => {
          if (!this.isRunning || this.currentStats !== runStats) {
            return;
          }
          this.currentStats.resourcesFailed += 1;
          this.recordErrorMessage(`sendResource failed: ${error.message}`);
          DemoLogger.e(TAG, `Error in sendResource for timer ${threadIndex}: ${error}`);
        }).then((): void => {
          if (this.isRunning && this.currentStats === runStats) {
            this.finishTotalCountStressIfComplete();
          }
        });
      }, config.resourceIntervalMs);
      this.resourceIntervalIds.push(intervalId);
    }
    if (config.resourceThreadCount > 0) {
      DemoLogger.i(TAG,
        `Resource timers started: count=${config.resourceThreadCount}, interval=${config.resourceIntervalMs}ms`);
    }
  }

  private startCustomErrorTimer(config: StressTestConfig): void {
    const intervalId = setInterval((): void => {
      if (!this.isRunning) {
        clearInterval(intervalId);
        return;
      }
      if (!this.sendCustomErrorBatch(config.errorBatchSize)) {
        clearInterval(intervalId);
      }
    }, config.errorIntervalMs);
    this.exceptionIntervalIds.push(intervalId);
  }

  private startLongTaskTimer(config: StressTestConfig): void {
    const intervalId = setInterval((): void => {
      if (!this.isRunning) {
        clearInterval(intervalId);
        return;
      }
      if (!this.sendLongTaskBatch(config.longTaskBatchSize)) {
        clearInterval(intervalId);
      }
    }, config.longTaskIntervalMs);
    this.exceptionIntervalIds.push(intervalId);
  }

  private sendLog(threadIndex: number): void {
    try {
      const logIndex = this.logCounter++;
      const logMessage = `Stress test log from timer ${threadIndex}, index ${logIndex}`;
      FTLogger.batchLog([{
        tag: STRESS_TEST_LOG_TAG,
        message: logMessage,
        level: 'i',
        timestampMs: Date.now()
      }]);
      this.currentStats.logsGenerated += 1;
      this.sampleCapabilityIfDue('log');
    } catch (error) {
      this.recordErrorMessage(`log failed: ${error}`);
      DemoLogger.e(TAG, `Failed to send log from timer ${threadIndex}: ${error}`);
    }
  }

  private sendAction(threadIndex: number): void {
    try {
      if (this.rumManager === null) {
        DemoLogger.w(TAG, `rumManager is null, cannot send action from timer ${threadIndex}`);
        return;
      }
      if (!this.isRumEnabled()) {
        DemoLogger.w(TAG, `rumManager is not initialized, cannot send action from timer ${threadIndex}`);
        return;
      }
      const actionIndex = this.actionCounter++;
      const actionName = `stress_action_timer${threadIndex}_${actionIndex}`;
      const property: Record<string, object> = {
        "tag": new StringWrapper(STRESS_TEST_LOG_TAG),
        "thread_index": new StringWrapper(threadIndex.toString()),
        "action_index": new StringWrapper(actionIndex.toString()),
        "traffic_mode": new StringWrapper(this.currentConfig.trafficMode),
        "source": new StringWrapper(this.currentConfig.source)
      };
      this.rumManager.addAction(actionName, 'click', property);
      this.currentStats.actionsGenerated += 1;
      this.sampleCapabilityIfDue('action');
    } catch (error) {
      this.recordErrorMessage(`action failed: ${error}`);
      DemoLogger.e(TAG, `Failed to send action from timer ${threadIndex}: ${error}`);
    }
  }

  private async sendResource(threadIndex: number): Promise<void> {
    if (!this.currentConfig.enableResources) {
      DemoLogger.w(TAG, `Resource scenario disabled, skip resource from timer ${threadIndex}`);
      return;
    }
    if (this.rumManager === null) {
      this.currentStats.resourcesFailed += 1;
      this.recordErrorMessage("rumManager is null, cannot send resource");
      return;
    }

    const resourceIndex = this.resourceCounter++;
    this.currentStats.resourcesGenerated += 1;
    const runStats = this.currentStats;

    try {
      if (this.currentConfig.trafficMode === 'real') {
        await this.sendRealResource(threadIndex, resourceIndex);
      } else {
        this.sendFakeResource(threadIndex, resourceIndex);
      }
      if (!this.isRunning || this.currentStats !== runStats) {
        return;
      }
      runStats.resourcesSucceeded += 1;
    } catch (error) {
      if (!this.isRunning || this.currentStats !== runStats) {
        return;
      }
      runStats.resourcesFailed += 1;
      this.recordErrorMessage(`resource failed: ${error}`);
      DemoLogger.e(TAG, `Failed to send resource from timer ${threadIndex}: ${error}`);
    }
    this.sampleCapabilityIfDue('resource');
  }

  private async sendRealResource(threadIndex: number, resourceIndex: number): Promise<void> {
    const plan = createStressResourceRequestPlan(
      this.currentConfig.realResourceClient,
      this.currentConfig.realResourceScenario,
      resourceIndex,
      this.getTraceTestUrls()
    );
    const url = buildStressResourceUrl(plan, threadIndex, resourceIndex, Date.now());
    let statusCode: number;
    switch (plan.client) {
      case 'http':
        statusCode = await this.sendRealHttpResource(url, plan.timeoutMs);
        break;
      case 'axios':
        statusCode = await this.sendRealAxiosResource(url, plan.timeoutMs);
        break;
      default:
        statusCode = await this.sendRealRcpResource(url, plan);
        break;
    }
    if (statusCode < 200 || statusCode >= 400) {
      throw new Error(`${plan.client}/${plan.scenario}: HTTP ${statusCode}, url=${url}`);
    }
  }

  private async sendRealRcpResource(url: string, plan: StressResourceRequestPlan): Promise<number> {
    const session = this.getRealResourceSession();
    const request = new rcp.Request(url, 'GET');
    request.configuration = {
      transfer: {
        timeout: {
          connectMs: Math.min(REAL_RESOURCE_CONNECT_TIMEOUT_MS, plan.timeoutMs),
          transferMs: plan.timeoutMs,
          inactivityMs: Math.min(REAL_RESOURCE_INACTIVITY_TIMEOUT_MS, plan.timeoutMs)
        }
      }
    };
    const response = await session.fetch(request);
    return response.statusCode;
  }

  private async sendRealHttpResource(url: string, timeoutMs: number): Promise<number> {
    const request = http.createHttp();
    this.activeHttpRequests.push(request);
    try {
      applyFTHttpTrack(request);
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: Math.min(REAL_RESOURCE_CONNECT_TIMEOUT_MS, timeoutMs),
        readTimeout: timeoutMs,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      return response.responseCode;
    } finally {
      const index = this.activeHttpRequests.indexOf(request);
      if (index >= 0) {
        this.activeHttpRequests.splice(index, 1);
        try {
          disposeFTHttpTrack(request);
        } catch (error) {
          DemoLogger.w(TAG, `Failed to dispose real HTTP tracking: ${error}`);
        } finally {
          request.destroy();
        }
      }
    }
  }

  private async sendRealAxiosResource(url: string, timeoutMs: number): Promise<number> {
    if (this.realResourceAxiosClient === null) {
      this.realResourceAxiosClient = axios.create();
      applyFTAxiosTrack(this.realResourceAxiosClient);
    }
    const controller = new AbortController();
    this.activeAxiosControllers.push(controller);
    try {
      const options: AxiosRequestConfig<Object> = {
        timeout: timeoutMs,
        connectTimeout: Math.min(REAL_RESOURCE_CONNECT_TIMEOUT_MS, timeoutMs),
        readTimeout: timeoutMs,
        responseType: 'string',
        signal: controller.signal,
        // Classify HTTP errors consistently across all three clients.
        validateStatus: (_status: number): boolean => true
      };
      const response = await this.realResourceAxiosClient.get<string, AxiosResponse<string, Object>, Object>(url, options);
      return response.status;
    } finally {
      const index = this.activeAxiosControllers.indexOf(controller);
      if (index >= 0) {
        this.activeAxiosControllers.splice(index, 1);
      }
    }
  }

  private closeRealResourceClients(): void {
    this.closeRealResourceSession();
    for (let i = 0; i < this.activeHttpRequests.length; i++) {
      try {
        disposeFTHttpTrack(this.activeHttpRequests[i]);
      } catch (error) {
        DemoLogger.w(TAG, `Failed to dispose real HTTP tracking while stopping: ${error}`);
      }
      try {
        this.activeHttpRequests[i].destroy();
      } catch (error) {
        DemoLogger.w(TAG, `Failed to destroy real HTTP request: ${error}`);
      }
    }
    this.activeHttpRequests = [];
    for (let i = 0; i < this.activeAxiosControllers.length; i++) {
      try {
        this.activeAxiosControllers[i].abort();
      } catch (error) {
        DemoLogger.w(TAG, `Failed to abort real Axios request: ${error}`);
      }
    }
    this.activeAxiosControllers = [];
    this.realResourceAxiosClient = null;
  }

  private getRealResourceSession(): rcp.Session {
    if (this.realResourceSession === null) {
      this.realResourceSession = rcp.createSession(createFTRCPTrackConfig({
        requestConfiguration: {
          transfer: {
            timeout: {
              connectMs: REAL_RESOURCE_CONNECT_TIMEOUT_MS,
              transferMs: REAL_RESOURCE_TRANSFER_TIMEOUT_MS,
              inactivityMs: REAL_RESOURCE_INACTIVITY_TIMEOUT_MS
            }
          }
        },
        connectionConfiguration: {
          maxConnectionsPerHost: REAL_RESOURCE_MAX_CONNECTIONS_PER_HOST,
          maxTotalConnections: REAL_RESOURCE_MAX_TOTAL_CONNECTIONS
        }
      }));
      DemoLogger.i(TAG, "Created reusable real resource RCP session");
    }
    return this.realResourceSession;
  }

  private closeRealResourceSession(): void {
    if (this.realResourceSession === null) {
      return;
    }
    try {
      this.realResourceSession.close();
      DemoLogger.i(TAG, "Closed reusable real resource RCP session");
    } catch (error) {
      DemoLogger.w(TAG, `Failed to close real resource RCP session: ${error}`);
    } finally {
      this.realResourceSession = null;
    }
  }

  private sendFakeResource(threadIndex: number, resourceIndex: number): void {
    const resourceId = `stress_resource_timer${threadIndex}_${resourceIndex}_${Date.now()}`;
    const url = `https://api.example.com/stress/resource/timer${threadIndex}/${resourceIndex}`;

    const params: ResourceParams = new ResourceParams();
    params.url = url;
    params.resourceMethod = 'GET';
    params.resourceStatus = 200;
    params.resourceType = 'network';
    params.requestHeader = 'Content-Type: application/json';
    params.responseHeader = 'Content-Type: application/json; charset=utf-8';
    params.responseBody =
      `{"status":"success","thread_index":${threadIndex},"resource_index":${resourceIndex},"timestamp":${Date.now()}}`;
    params.responseContentLength = params.responseBody.length;
    params.responseContentType = 'application/json';
    params.responseConnection = 'keep-alive';

    const propertyMap: Map<string, object> = new Map();
    propertyMap.set("tag", new StringWrapper(STRESS_TEST_LOG_TAG));
    propertyMap.set("thread_index", new StringWrapper(threadIndex.toString()));
    propertyMap.set("resource_index", new StringWrapper(resourceIndex.toString()));
    propertyMap.set("traffic_mode", new StringWrapper(this.currentConfig.trafficMode));
    propertyMap.set("source", new StringWrapper(this.currentConfig.source));
    params.setProperty(propertyMap);

    const netStatusBean: NetStatusBean = this.createSyntheticNetStatus();
    this.rumManager?.startResource(resourceId);
    this.rumManager?.stopResource(resourceId);
    this.rumManager?.addResource(resourceId, params, netStatusBean);
  }

  private createSyntheticNetStatus(): NetStatusBean {
    const dnsDuration = 10 * MS_TO_NS;
    const tcpDuration = 20 * MS_TO_NS;
    const sslDuration = 30 * MS_TO_NS;
    const ttfbDuration = 100 * MS_TO_NS;
    const downloadDuration = 50 * MS_TO_NS;

    const netStatusBean: NetStatusBean = new NetStatusBean();
    netStatusBean.setDNSStartTime(0);
    netStatusBean.setDNSTime(dnsDuration);
    netStatusBean.setConnectStartTime(dnsDuration);
    netStatusBean.setTcpTime(tcpDuration);
    netStatusBean.setSslStartTime(dnsDuration + tcpDuration);
    netStatusBean.setSSLTime(sslDuration);
    netStatusBean.setFirstByteStartTime(dnsDuration + tcpDuration + sslDuration);
    netStatusBean.setFirstByteTime(ttfbDuration);
    netStatusBean.setDownloadTimeStart(dnsDuration + tcpDuration + sslDuration + ttfbDuration);
    netStatusBean.setDownloadTime(downloadDuration);
    netStatusBean.setHoleRequestTime(dnsDuration + tcpDuration + sslDuration + ttfbDuration + downloadDuration);
    return netStatusBean;
  }

  private sendCustomError(): void {
    try {
      if (this.rumManager === null || !this.isRumEnabled()) {
        return;
      }
      const errorIndex = this.errorCounter++;
      const property: Record<string, object> = {
        "tag": new StringWrapper(STRESS_TEST_LOG_TAG),
        "error_index": new StringWrapper(errorIndex.toString()),
        "source": new StringWrapper(this.currentConfig.source)
      };
      this.rumManager.addError(
        `Error: Stress custom error ${errorIndex}\n  at StressTestManager.sendCustomError`,
        `Stress custom error ${errorIndex}`,
        ErrorType.CUSTOM,
        AppState.RUN,
        property
      );
      this.currentStats.errorsGenerated += 1;
      this.sampleCapabilityIfDue('error');
    } catch (error) {
      this.recordErrorMessage(`custom error failed: ${error}`);
      DemoLogger.e(TAG, `Failed to add custom error: ${error}`);
    }
  }

  private sendCustomErrorBatch(batchSize: number): boolean {
    if (this.errorBatchRunning) {
      return true;
    }
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const remaining = this.getRemainingScenarioTarget(this.currentStats.errorsGenerated, this.currentConfig);
    const emitCount = Math.min(normalizedBatchSize, remaining);
    if (emitCount <= 0) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    this.errorBatchRunning = true;
    this.drainCustomErrorBatch(emitCount);
    return true;
  }

  private drainCustomErrorBatch(remainingCount: number): void {
    if (!this.isRunning || remainingCount <= 0) {
      this.errorBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    const chunkSize = Math.min(STRESS_PRODUCTION_CHUNK_SIZE, remainingCount);
    for (let i = 0; i < chunkSize; i++) {
      this.sendCustomError();
    }
    this.finishTotalCountStressIfComplete();
    const nextRemaining = remainingCount - chunkSize;
    if (nextRemaining <= 0 || this.isScenarioTargetReached(this.currentStats.errorsGenerated, this.currentConfig)) {
      this.errorBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    this.scheduleProductionSlice((): void => {
      this.drainCustomErrorBatch(nextRemaining);
    });
  }

  private sendLongTask(): void {
    try {
      if (this.rumManager === null || !this.isRumEnabled()) {
        return;
      }
      const longTaskIndex = this.longTaskCounter++;
      const durationNs = 350 * MS_TO_NS;
      this.rumManager.addLongTask(`Stress long task ${longTaskIndex}`, durationNs, {
        "tag": STRESS_TEST_LOG_TAG,
        "long_task_index": longTaskIndex,
        "source": this.currentConfig.source
      });
      this.currentStats.longTasksGenerated += 1;
      this.sampleCapabilityIfDue('long-task');
    } catch (error) {
      this.recordErrorMessage(`long task failed: ${error}`);
      DemoLogger.e(TAG, `Failed to add long task: ${error}`);
    }
  }

  private sendLongTaskBatch(batchSize: number): boolean {
    if (this.longTaskBatchRunning) {
      return true;
    }
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const remaining = this.getRemainingScenarioTarget(this.currentStats.longTasksGenerated, this.currentConfig);
    const emitCount = Math.min(normalizedBatchSize, remaining);
    if (emitCount <= 0) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    this.longTaskBatchRunning = true;
    this.drainLongTaskBatch(emitCount);
    return true;
  }

  private drainLongTaskBatch(remainingCount: number): void {
    if (!this.isRunning || remainingCount <= 0) {
      this.longTaskBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    const chunkSize = Math.min(STRESS_PRODUCTION_CHUNK_SIZE, remainingCount);
    for (let i = 0; i < chunkSize; i++) {
      this.sendLongTask();
    }
    this.finishTotalCountStressIfComplete();
    const nextRemaining = remainingCount - chunkSize;
    if (nextRemaining <= 0 || this.isScenarioTargetReached(this.currentStats.longTasksGenerated, this.currentConfig)) {
      this.longTaskBatchRunning = false;
      this.finishTotalCountStressIfComplete();
      return;
    }

    this.scheduleProductionSlice((): void => {
      this.drainLongTaskBatch(nextRemaining);
    });
  }

  private startCapabilitySampling(): void {
    this.clearCapabilitySampleTimer();
    this.clearCapabilityUiTickTimer();
    this.capabilitySamples = [];
    this.capabilityStartedAtMs = Date.now();
    this.capabilityLastSampleAtMs = 0;
    this.resetUiJankStats();
    this.startCapabilityUiTickTimer();
    this.capabilityHeapLimit = this.captureVmHeapLimitSnapshot();
    this.capabilityTemperatureProbe = this.findTemperatureProbe();
    const heapStart = this.captureVmHeapSnapshot(this.capabilityHeapLimit.limitBytes);
    this.capabilityHeapStartBytes = heapStart.usedBytes;
    this.captureCapabilitySample('start');
    this.capabilitySampleTimerId = setInterval((): void => {
      if (!this.isRunning) {
        return;
      }
      this.captureCapabilitySample('timer');
    }, CAPABILITY_SAMPLE_INTERVAL_MS);
  }

  private stopCapabilitySampling(): StressCapabilityReport | null {
    if (this.capabilityStartedAtMs <= 0) {
      return null;
    }
    this.clearCapabilitySampleTimer();
    this.recordUiJankTick(Date.now());
    this.clearCapabilityUiTickTimer();
    this.captureCapabilitySample('stop');
    const report = this.buildCapabilityReport();
    this.logCapabilityReport(report);
    this.capabilityStartedAtMs = 0;
    return report;
  }

  private clearCapabilitySampleTimer(): void {
    if (this.capabilitySampleTimerId !== null) {
      clearInterval(this.capabilitySampleTimerId);
      this.capabilitySampleTimerId = null;
    }
  }

  private startCapabilityUiTickTimer(): void {
    this.capabilityUiLastTickAtMs = Date.now();
    this.capabilityUiTickTimerId = setInterval((): void => {
      this.recordUiJankTick(Date.now());
    }, CAPABILITY_UI_TICK_INTERVAL_MS);
  }

  private clearCapabilityUiTickTimer(): void {
    if (this.capabilityUiTickTimerId !== null) {
      clearInterval(this.capabilityUiTickTimerId);
      this.capabilityUiTickTimerId = null;
    }
  }

  private resetUiJankStats(): void {
    this.capabilityUiLastTickAtMs = 0;
    this.capabilityUiJankSamples = 0;
    this.capabilityUiJankTotalDriftMs = 0;
    this.capabilityUiJankMaxDriftMs = 0;
    this.capabilityUiJankOver16Count = 0;
    this.capabilityUiJankOver50Count = 0;
    this.capabilityUiJankOver100Count = 0;
    this.updateCurrentUiJankStats();
  }

  private recordUiJankTick(now: number): void {
    if (this.capabilityUiLastTickAtMs <= 0) {
      this.capabilityUiLastTickAtMs = now;
      return;
    }

    const driftMs = Math.max(0, now - this.capabilityUiLastTickAtMs - CAPABILITY_UI_TICK_INTERVAL_MS);
    this.capabilityUiLastTickAtMs = now;
    this.capabilityUiJankSamples += 1;
    this.capabilityUiJankTotalDriftMs += driftMs;
    this.capabilityUiJankMaxDriftMs = Math.max(this.capabilityUiJankMaxDriftMs, driftMs);
    if (driftMs >= CAPABILITY_UI_LIGHT_JANK_MS) {
      this.capabilityUiJankOver16Count += 1;
    }
    if (driftMs >= CAPABILITY_UI_MODERATE_JANK_MS) {
      this.capabilityUiJankOver50Count += 1;
    }
    if (driftMs >= CAPABILITY_UI_STRONG_JANK_MS) {
      this.capabilityUiJankOver100Count += 1;
    }
    this.updateCurrentUiJankStats();
  }

  private updateCurrentUiJankStats(): void {
    this.currentStats.uiJankSamples = this.capabilityUiJankSamples;
    this.currentStats.uiJankMaxDriftMs = this.roundMetric(this.capabilityUiJankMaxDriftMs, 2);
    this.currentStats.uiJankAvgDriftMs = this.capabilityUiJankSamples > 0 ?
      this.roundMetric(this.capabilityUiJankTotalDriftMs / this.capabilityUiJankSamples, 2) : 0;
    this.currentStats.uiJankOver16Count = this.capabilityUiJankOver16Count;
    this.currentStats.uiJankOver50Count = this.capabilityUiJankOver50Count;
    this.currentStats.uiJankOver100Count = this.capabilityUiJankOver100Count;
  }

  private sampleCapabilityIfDue(label: string): void {
    if (!this.isRunning || this.capabilityStartedAtMs <= 0) {
      return;
    }
    const now = Date.now();
    if (now - this.capabilityLastSampleAtMs >= CAPABILITY_SAMPLE_INTERVAL_MS) {
      this.captureCapabilitySample(label);
    }
  }

  private captureCapabilitySample(label: string): StressCapabilitySample {
    const now = Date.now();
    const dedicatedPoolStatus = SDKDedicatedPoolManager.getInstance().getStatus();
    let schedulerQueue = 0;
    let runningTotal = 0;
    let completedTotal = 0;
    let failedTotal = 0;

    CAPABILITY_LANE_TYPES.forEach((type: SDKDedicatedPoolType) => {
      const pool = dedicatedPoolStatus.pools[type];
      if (pool !== undefined) {
        schedulerQueue += pool.pending;
        runningTotal += pool.running;
        completedTotal += pool.completedTasks;
        failedTotal += pool.failedTasks;
      }
    });

    const logStatus = TrackLogManager.getInstance().getQueueStatus();
    const logQueue = logStatus.queueSize;
    const heap = this.captureVmHeapSnapshot(this.capabilityHeapLimit.limitBytes);
    const temperature = this.captureTemperatureSnapshot();
    const sample: StressCapabilitySample = {
      label,
      elapsedMs: Math.max(0, now - this.capabilityStartedAtMs),
      schedulerQueue,
      logQueue,
      queueTotal: schedulerQueue + logQueue,
      runningTotal,
      completedTotal,
      failedTotal,
      heapUsedBytes: heap.usedBytes,
      temperatureAvailable: temperature.available,
      temperatureC: temperature.celsius
    };

    this.capabilitySamples.push(sample);
    this.capabilityLastSampleAtMs = now;
    return sample;
  }

  private buildCapabilityReport(): StressCapabilityReport {
    const samples = this.capabilitySamples.length > 0 ? this.capabilitySamples : [this.captureCapabilitySample('final')];
    const peakQueueSample = this.getPeakQueueSample(samples);
    const heapEnd = this.captureVmHeapSnapshot(this.capabilityHeapLimit.limitBytes);
    const heapPeakBytes = this.getPeakHeapBytes(samples, this.capabilityHeapStartBytes, heapEnd.usedBytes);
    const peakHeapDeltaBytes = this.capabilityHeapStartBytes > 0 ? Math.max(0, heapPeakBytes - this.capabilityHeapStartBytes) : 0;
    const temperatureEnd = this.captureTemperatureSnapshot();
    const temperatureAvailable = this.hasAvailableTemperature(samples) || temperatureEnd.available;
    const temperatureStartC = this.getStartTemperatureC(samples, temperatureEnd);
    const temperaturePeakC = this.getPeakTemperatureC(samples, temperatureEnd);
    const temperatureEndC = this.getEndTemperatureC(samples, temperatureEnd);
    const temperatureDeltaC = temperatureAvailable &&
      temperatureStartC !== CAPABILITY_TEMPERATURE_UNAVAILABLE_C &&
      temperatureEndC !== CAPABILITY_TEMPERATURE_UNAVAILABLE_C ?
      this.roundMetric(temperatureEndC - temperatureStartC, 2) : CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
    const avgQueuedTaskBytes = peakQueueSample.queueTotal > 0 && peakHeapDeltaBytes > 0 ?
      peakHeapDeltaBytes / peakQueueSample.queueTotal : 0;
    const safeHeapBytes = Math.max(
      0,
      this.capabilityHeapLimit.limitBytes * CAPABILITY_VM_HEAP_SAFE_WATERMARK -
        CAPABILITY_RESERVED_HEAP_MB * BYTES_PER_MB
    );
    const safeQueueEstimate = avgQueuedTaskBytes > 0 && this.capabilityHeapStartBytes > 0 ?
      Math.floor(Math.max(0, safeHeapBytes - this.capabilityHeapStartBytes) / avgQueuedTaskBytes) : 0;
    const elapsedMs = Math.max(1, Date.now() - this.capabilityStartedAtMs);
    const inputMixedTasks = this.countInputMixedTasks(this.currentStats);
    const laneMetrics = this.buildCapabilityLaneMetrics();
    const businessMetrics = this.buildCapabilityBusinessMetrics();
    const slowLane = this.getSlowestLane(laneMetrics);
    const slowBusiness = this.getSlowestBusinessEvent(businessMetrics);
    const completionTotal = this.sumCompletedTasks(laneMetrics);
    const productionQps = this.roundMetric(inputMixedTasks * 1000 / elapsedMs, 2);
    const completionQps = this.roundMetric(completionTotal * 1000 / elapsedMs, 2);
    const observedBacklogGrowthPerSecond = peakQueueSample.elapsedMs > 0 ?
      this.roundMetric(peakQueueSample.queueTotal * 1000 / peakQueueSample.elapsedMs, 2) :
      this.roundMetric(Math.max(0, productionQps - completionQps), 2);
    const secondsToHighRisk = observedBacklogGrowthPerSecond > 0 && safeQueueEstimate > peakQueueSample.queueTotal ?
      this.roundMetric((safeQueueEstimate - peakQueueSample.queueTotal) / observedBacklogGrowthPerSecond, 2) : 0;
    const logStatus = TrackLogManager.getInstance().getQueueStatus();
    const logDropRate = logStatus.submittedCount > 0 ? this.roundMetric(logStatus.droppedCount / logStatus.submittedCount, 4) : 0;
    this.updateCurrentUiJankStats();

    return {
      caseName: CAPABILITY_CASE_NAME,
      inputMixedTasks,
      enabledFeatureCount: this.countEnabledFeatures(this.currentStats),
      sampleCount: samples.length,
      peakQueue: peakQueueSample.queueTotal,
      peakSchedulerQueue: peakQueueSample.schedulerQueue,
      peakLogQueue: peakQueueSample.logQueue,
      peakQueueElapsedMs: peakQueueSample.elapsedMs,
      heapStartMb: this.bytesToMb(this.capabilityHeapStartBytes),
      heapPeakMb: this.bytesToMb(heapPeakBytes),
      heapEndMb: this.bytesToMb(heapEnd.usedBytes),
      heapDeltaMb: this.bytesToMb(heapEnd.usedBytes > 0 && this.capabilityHeapStartBytes > 0 ?
        heapEnd.usedBytes - this.capabilityHeapStartBytes : 0),
      peakHeapDeltaMb: this.bytesToMb(peakHeapDeltaBytes),
      avgQueuedTaskKb: this.bytesToKb(avgQueuedTaskBytes),
      vmHeapLimitMb: this.bytesToMb(this.capabilityHeapLimit.limitBytes),
      vmHeapLimitSource: this.capabilityHeapLimit.source,
      safeWatermark: CAPABILITY_VM_HEAP_SAFE_WATERMARK,
      reservedHeapMb: CAPABILITY_RESERVED_HEAP_MB,
      safeQueueEstimate,
      productionQps,
      completionQps,
      backlogGrowthPerSecond: observedBacklogGrowthPerSecond,
      secondsToHighRisk,
      slowLane: slowLane.laneName,
      slowLaneAvgWaitMs: slowLane.avgWaitMs,
      slowLaneAvgCostMs: slowLane.avgCostMs,
      slowLaneBottleneck: slowLane.bottleneck,
      slowBusinessEvent: slowBusiness.eventType,
      slowBusinessTaskGroup: slowBusiness.taskGroup,
      slowBusinessLane: slowBusiness.laneName,
      slowBusinessAvgWaitMs: slowBusiness.avgWaitMs,
      slowBusinessAvgCostMs: slowBusiness.avgCostMs,
      logSubmitted: logStatus.submittedCount,
      logAccepted: logStatus.acceptedCount,
      logDropped: logStatus.droppedCount,
      logDropRate,
      logDropCause: this.classifyLogDropCause(logStatus.droppedCount, peakQueueSample.logQueue, peakQueueSample.schedulerQueue),
      uiJankSamples: this.currentStats.uiJankSamples,
      uiJankMaxDriftMs: this.currentStats.uiJankMaxDriftMs,
      uiJankAvgDriftMs: this.currentStats.uiJankAvgDriftMs,
      uiJankOver16Count: this.currentStats.uiJankOver16Count,
      uiJankOver50Count: this.currentStats.uiJankOver50Count,
      uiJankOver100Count: this.currentStats.uiJankOver100Count,
      temperatureAvailable,
      temperatureKind: this.getTemperatureKind(),
      temperatureSource: this.getTemperatureSource(),
      temperatureStartC,
      temperaturePeakC,
      temperatureEndC,
      temperatureDeltaC,
      lanes: laneMetrics,
      businessEvents: businessMetrics
    };
  }

  private captureVmHeapSnapshot(limitBytes: number): VmHeapSnapshot {
    try {
      const memoryInfo = hidebug.getAppVMMemoryInfo();
      const usedBytes = this.kbToBytes(memoryInfo.totalHeap);
      return {
        usedBytes,
        limitBytes,
        available: usedBytes > 0
      };
    } catch (error) {
      DemoLogger.w(TAG, `Failed to capture VM heap info: ${error}`);
      return {
        usedBytes: 0,
        limitBytes,
        available: false
      };
    }
  }

  private captureVmHeapLimitSnapshot(): VmHeapLimitSnapshot {
    try {
      const memoryLimit = hidebug.getAppMemoryLimit();
      const vmHeapLimitBytes = this.kbToBytes(memoryLimit.vmHeapLimit);
      if (vmHeapLimitBytes > 0) {
        return {
          limitBytes: vmHeapLimitBytes,
          source: 'hidebug.vmHeapLimit'
        };
      }
      const vmTotalHeapSizeBytes = this.kbToBytes(memoryLimit.vmTotalHeapSize);
      if (vmTotalHeapSizeBytes > 0) {
        return {
          limitBytes: vmTotalHeapSizeBytes,
          source: 'hidebug.vmTotalHeapSize'
        };
      }
    } catch (error) {
      DemoLogger.w(TAG, `Failed to capture VM heap limit: ${error}`);
    }

    return {
      limitBytes: CAPABILITY_VM_HEAP_FALLBACK_LIMIT_MB * BYTES_PER_MB,
      source: 'fallback'
    };
  }

  private findTemperatureProbe(): TemperatureProbe | null {
    const preferredCpuProbe = this.findThermalZoneProbe(true);
    if (preferredCpuProbe !== null) {
      return preferredCpuProbe;
    }

    const genericThermalProbe = this.findThermalZoneProbe(false);
    if (genericThermalProbe !== null) {
      return genericThermalProbe;
    }

    return this.findBatteryTemperatureProbe();
  }

  private findThermalZoneProbe(cpuOnly: boolean): TemperatureProbe | null {
    for (let index = 0; index < CAPABILITY_TEMPERATURE_ZONE_COUNT; index++) {
      const basePath = `/sys/class/thermal/thermal_zone${index}`;
      const tempPath = `${basePath}/temp`;
      const rawType = this.readSystemTextFile(`${basePath}/type`, 64);
      const zoneType = rawType.length > 0 ? rawType : `thermal_zone${index}`;
      const isCpuLike = this.isCpuTemperatureType(zoneType);
      if (cpuOnly && !isCpuLike) {
        continue;
      }
      const celsius = this.readTemperatureCelsius(tempPath);
      if (celsius === CAPABILITY_TEMPERATURE_UNAVAILABLE_C) {
        continue;
      }
      return {
        tempPath,
        kind: isCpuLike ? 'cpu' : 'thermal',
        source: `${zoneType}:${tempPath}`
      };
    }
    return null;
  }

  private findBatteryTemperatureProbe(): TemperatureProbe | null {
    for (let index = 0; index < CAPABILITY_BATTERY_TEMPERATURE_PATHS.length; index++) {
      const tempPath = CAPABILITY_BATTERY_TEMPERATURE_PATHS[index];
      const celsius = this.readTemperatureCelsius(tempPath);
      if (celsius !== CAPABILITY_TEMPERATURE_UNAVAILABLE_C) {
        return {
          tempPath,
          kind: 'battery',
          source: `battery:${tempPath}`
        };
      }
    }
    return null;
  }

  private captureTemperatureSnapshot(): TemperatureSnapshot {
    if (this.capabilityTemperatureProbe === null) {
      return this.createUnavailableTemperatureSnapshot();
    }

    const celsius = this.readTemperatureCelsius(this.capabilityTemperatureProbe.tempPath);
    if (celsius === CAPABILITY_TEMPERATURE_UNAVAILABLE_C) {
      return this.createUnavailableTemperatureSnapshot();
    }

    return {
      available: true,
      celsius,
      kind: this.capabilityTemperatureProbe.kind,
      source: this.capabilityTemperatureProbe.source
    };
  }

  private createUnavailableTemperatureSnapshot(): TemperatureSnapshot {
    return {
      available: false,
      celsius: CAPABILITY_TEMPERATURE_UNAVAILABLE_C,
      kind: 'unavailable',
      source: 'unavailable'
    };
  }

  private readTemperatureCelsius(path: string): number {
    const rawText = this.readSystemTextFile(path, 32);
    if (rawText.length === 0) {
      return CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
    }

    const rawValue = parseFloat(rawText);
    if (isNaN(rawValue)) {
      return CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
    }

    const celsius = this.normalizeTemperatureCelsius(rawValue);
    if (!this.isValidTemperatureCelsius(celsius)) {
      return CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
    }
    return this.roundMetric(celsius, 2);
  }

  private readSystemTextFile(path: string, maxBytes: number): string {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(maxBytes);
        const readLen: number = fileIo.readSync(file.fd, buffer);
        fileIo.closeSync(file);
        if (readLen <= 0) {
          return '';
        }
        const bufferSlice = buffer.slice(0, readLen);
        const uint8Array = new Uint8Array(bufferSlice);
        const textDecoder = util.TextDecoder.create('utf-8');
        return textDecoder.decodeWithStream(uint8Array, { stream: false }).trim();
      } catch (readError) {
        fileIo.closeSync(file);
        return '';
      }
    } catch (openError) {
      return '';
    }
  }

  private normalizeTemperatureCelsius(rawValue: number): number {
    const absValue = Math.abs(rawValue);
    if (absValue > 1000) {
      return rawValue / 1000;
    }
    if (absValue > 150) {
      return rawValue / 10;
    }
    return rawValue;
  }

  private isValidTemperatureCelsius(value: number): boolean {
    return value >= -30 && value <= 150;
  }

  private isCpuTemperatureType(typeName: string): boolean {
    const normalizedType = typeName.toLowerCase();
    for (let index = 0; index < CAPABILITY_CPU_TEMPERATURE_TYPE_KEYWORDS.length; index++) {
      if (normalizedType.indexOf(CAPABILITY_CPU_TEMPERATURE_TYPE_KEYWORDS[index]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private hasAvailableTemperature(samples: StressCapabilitySample[]): boolean {
    for (let index = 0; index < samples.length; index++) {
      if (samples[index].temperatureAvailable) {
        return true;
      }
    }
    return false;
  }

  private getStartTemperatureC(samples: StressCapabilitySample[], fallback: TemperatureSnapshot): number {
    for (let index = 0; index < samples.length; index++) {
      const sample = samples[index];
      if (sample.temperatureAvailable) {
        return sample.temperatureC;
      }
    }
    return fallback.available ? fallback.celsius : CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
  }

  private getEndTemperatureC(samples: StressCapabilitySample[], fallback: TemperatureSnapshot): number {
    if (fallback.available) {
      return fallback.celsius;
    }
    for (let index = samples.length - 1; index >= 0; index--) {
      const sample = samples[index];
      if (sample.temperatureAvailable) {
        return sample.temperatureC;
      }
    }
    return CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
  }

  private getPeakTemperatureC(samples: StressCapabilitySample[], fallback: TemperatureSnapshot): number {
    let peak = fallback.available ? fallback.celsius : CAPABILITY_TEMPERATURE_UNAVAILABLE_C;
    samples.forEach((sample: StressCapabilitySample) => {
      if (sample.temperatureAvailable && sample.temperatureC > peak) {
        peak = sample.temperatureC;
      }
    });
    return peak;
  }

  private getTemperatureKind(): string {
    return this.capabilityTemperatureProbe !== null ? this.capabilityTemperatureProbe.kind : 'unavailable';
  }

  private getTemperatureSource(): string {
    return this.capabilityTemperatureProbe !== null ? this.capabilityTemperatureProbe.source : 'unavailable';
  }

  private kbToBytes(value: bigint | number | undefined): number {
    if (value === undefined) {
      return 0;
    }
    return Number(value) * BYTES_PER_KB;
  }

  private getPeakQueueSample(samples: StressCapabilitySample[]): StressCapabilitySample {
    let peak = samples[0];
    samples.forEach((sample: StressCapabilitySample) => {
      if (sample.queueTotal > peak.queueTotal) {
        peak = sample;
      }
    });
    return peak;
  }

  private getPeakHeapBytes(samples: StressCapabilitySample[], startHeapBytes: number, endHeapBytes: number): number {
    let peakHeapBytes = Math.max(startHeapBytes, endHeapBytes);
    samples.forEach((sample: StressCapabilitySample) => {
      peakHeapBytes = Math.max(peakHeapBytes, sample.heapUsedBytes);
    });
    return peakHeapBytes;
  }

  private buildCapabilityLaneMetrics(): StressCapabilityLaneMetric[] {
    const dedicatedPoolStatus = SDKDedicatedPoolManager.getInstance().getStatus();
    const metrics: StressCapabilityLaneMetric[] = [];
    CAPABILITY_LANE_TYPES.forEach((type: SDKDedicatedPoolType) => {
      const pool = dedicatedPoolStatus.pools[type];
      if (pool !== undefined) {
        metrics.push(this.toLaneMetric(type, pool));
      }
    });
    return metrics;
  }

  private toLaneMetric(type: SDKDedicatedPoolType, pool: SDKDedicatedPoolStatus): StressCapabilityLaneMetric {
    const avgWaitMs = this.roundMetric(pool.averageWaitTime, 2);
    const avgCostMs = this.roundMetric(pool.averageCostTime, 2);
    return {
      laneName: `${type}`,
      backend: pool.backend,
      lastError: pool.lastError,
      submitted: pool.submittedTasks,
      completed: pool.completedTasks,
      failed: pool.failedTasks,
      pending: pool.pending,
      mailboxPending: pool.mailboxPending || 0,
      running: pool.running,
      queuedTasks: pool.queuedTasks,
      avgWaitMs,
      avgCostMs,
      oldestWaitMs: 0,
      bottleneck: this.classifyBottleneck(avgWaitMs, avgCostMs)
    };
  }

  private buildCapabilityBusinessMetrics(): StressCapabilityBusinessMetric[] {
    return [];
  }

  private classifyBusinessEventType(groupName: string): string {
    if (groupName.indexOf('data.prepare:view') === 0 || groupName === 'rum.initView') {
      return 'view';
    }
    if (groupName.indexOf('data.prepare:action') === 0 ||
      groupName === 'rum.addAction' ||
      groupName === 'rum.startAction' ||
      groupName === 'rum.closeAction' ||
      groupName === 'rum.increaseViewAction') {
      return 'action';
    }
    if (groupName.indexOf('data.prepare:resource') === 0 ||
      groupName === 'rum.resourceCleanup' ||
      groupName === 'rum.increaseResource' ||
      groupName === 'rum.increasePendingResource' ||
      groupName === 'rum.decreasePendingResource') {
      return 'resource';
    }
    if (groupName.indexOf('data.prepare:error') === 0 ||
      groupName === 'rum.addError' ||
      groupName === 'rum.increaseError') {
      return 'error';
    }
    if (groupName.indexOf('data.prepare:long_task') === 0 ||
      groupName === 'rum.increaseLongTaskFromTags' ||
      groupName === 'rum.increaseViewLongTask' ||
      groupName === 'rum.increaseActionLongTask') {
      return 'longtask';
    }
    if (groupName.indexOf('data.prepare:df_rum_harmonyos_log') === 0 || groupName === 'log.process' ||
      groupName === 'log.forceFlush') {
      return 'log';
    }
    return '';
  }

  private getSlowestLane(metrics: StressCapabilityLaneMetric[]): StressCapabilityLaneMetric {
    if (metrics.length === 0) {
      return this.createEmptyLaneMetric();
    }
    let slowest = metrics[0];
    metrics.forEach((metric: StressCapabilityLaneMetric) => {
      if (metric.avgWaitMs > slowest.avgWaitMs) {
        slowest = metric;
      }
    });
    return slowest;
  }

  private createEmptyLaneMetric(): StressCapabilityLaneMetric {
    return {
      laneName: 'none',
      backend: 'none',
      lastError: '',
      submitted: 0,
      completed: 0,
      failed: 0,
      pending: 0,
      mailboxPending: 0,
      running: 0,
      queuedTasks: 0,
      avgWaitMs: 0,
      avgCostMs: 0,
      oldestWaitMs: 0,
      bottleneck: 'none'
    };
  }

  private getSlowestBusinessEvent(metrics: StressCapabilityBusinessMetric[]): StressCapabilityBusinessMetric {
    if (metrics.length === 0) {
      return this.createEmptyBusinessMetric();
    }
    return metrics[0];
  }

  private createEmptyBusinessMetric(): StressCapabilityBusinessMetric {
    return {
      eventType: 'none',
      taskGroup: 'none',
      laneName: 'none',
      submitted: 0,
      completed: 0,
      failed: 0,
      queuedTasks: 0,
      avgWaitMs: 0,
      avgCostMs: 0,
      maxWaitMs: 0,
      maxCostMs: 0,
      bottleneck: 'none'
    };
  }

  private countInputMixedTasks(stats: StressTestStats): number {
    let count = 0;
    if (stats.enableLogs) {
      count += stats.logsGenerated;
    }
    if (stats.enableActions) {
      count += stats.actionsGenerated;
    }
    if (stats.enableResources) {
      count += stats.resourcesGenerated;
    }
    if (stats.enableNavigation) {
      count += stats.navigationSwitches;
    }
    if (stats.enableErrors) {
      count += stats.errorsGenerated;
    }
    if (stats.enableLongTasks) {
      count += stats.longTasksGenerated;
    }
    return count;
  }

  private countEnabledFeatures(stats: StressTestStats): number {
    let count = 0;
    if (stats.enableLogs) {
      count++;
    }
    if (stats.enableActions) {
      count++;
    }
    if (stats.enableResources) {
      count++;
    }
    if (stats.enableNavigation) {
      count++;
    }
    if (stats.enableErrors) {
      count++;
    }
    if (stats.enableLongTasks) {
      count++;
    }
    return count;
  }

  private sumCompletedTasks(metrics: StressCapabilityLaneMetric[]): number {
    let completed = 0;
    metrics.forEach((metric: StressCapabilityLaneMetric) => {
      completed += metric.completed;
    });
    return completed;
  }

  private classifyBottleneck(avgWaitMs: number, avgCostMs: number): string {
    if (avgWaitMs <= 0 && avgCostMs <= 0) {
      return 'none';
    }
    return avgWaitMs >= avgCostMs ? 'queue-wait' : 'processing-cost';
  }

  private classifyLogDropCause(dropped: number, logQueue: number, schedulerQueue: number): string {
    if (dropped > 0) {
      return 'entrance-pressure';
    }
    if (logQueue > 0 || schedulerQueue > 0) {
      return 'consumer-backlog';
    }
    return 'none';
  }

  private bytesToMb(bytes: number): number {
    return this.roundMetric(bytes / BYTES_PER_MB, 2);
  }

  private bytesToKb(bytes: number): number {
    return this.roundMetric(bytes / BYTES_PER_KB, 2);
  }

  private roundMetric(value: number, digits: number = 2): number {
    const factor = Math.pow(10, digits);
    return Math.round(value * factor) / factor;
  }

  private logCapabilityReport(report: StressCapabilityReport): void {
    DemoLogger.i(
      TAG,
      `RealAppStressCapability case=${report.caseName} inputMixedTasks=${report.inputMixedTasks} ` +
        `peakQueue=${report.peakQueue} peakSchedulerQueue=${report.peakSchedulerQueue} peakLogQueue=${report.peakLogQueue} ` +
        `heapStartMb=${report.heapStartMb} heapPeakMb=${report.heapPeakMb} heapEndMb=${report.heapEndMb} ` +
        `avgQueuedTaskKb=${report.avgQueuedTaskKb} vmHeapLimitMb=${report.vmHeapLimitMb} safeQueueEstimate=${report.safeQueueEstimate} ` +
        `secondsToHighRisk=${report.secondsToHighRisk} slowLane=${report.slowLane} slowBusinessEvent=${report.slowBusinessEvent} ` +
        `logDropped=${report.logDropped} logDropCause=${report.logDropCause} ` +
        `uiJankMaxDriftMs=${report.uiJankMaxDriftMs} uiJankAvgDriftMs=${report.uiJankAvgDriftMs} ` +
        `uiJankOver50=${report.uiJankOver50Count} uiJankOver100=${report.uiJankOver100Count} ` +
        `temperatureKind=${report.temperatureKind} temperatureSource=${report.temperatureSource} ` +
        `temperatureStartC=${report.temperatureStartC} temperaturePeakC=${report.temperaturePeakC} ` +
        `temperatureEndC=${report.temperatureEndC} temperatureDeltaC=${report.temperatureDeltaC}`
    );
  }

  public stop(stopReason: StressStopReason = 'manual'): StressTestReport | null {
    if (!this.isRunning) {
      DemoLogger.w(TAG, "Stress test is not running");
      return this.lastReport;
    }

    DemoLogger.i(TAG, `Stopping stress test. reason=${stopReason}`);

    if (this.autoStopTimerId !== null) {
      clearTimeout(this.autoStopTimerId);
      this.autoStopTimerId = null;
    }

    const elapsedSeconds = this.getElapsedSeconds();
    this.isRunning = false;
    this.clearAllTimers();
    this.closeRealResourceClients();
    if (this.currentStats.enableLogs && this.currentStats.logsGenerated > 0) {
      FTLogger.flush();
    }
    this.scheduleFinalUploadFlush(stopReason);
    const capabilityReport = this.stopCapabilitySampling();

    this.currentStats.isRunning = false;
    this.currentStats.endedAtMs = Date.now();
    this.currentStats.elapsedSeconds = elapsedSeconds;
    this.currentStats.remainingSeconds = 0;

    this.lastReport = {
      stopReason,
      startedAtMs: this.currentStats.startedAtMs,
      endedAtMs: this.currentStats.endedAtMs,
      elapsedSeconds,
      durationSeconds: this.durationSeconds,
      stats: this.copyStats(this.currentStats),
      capabilityReport
    };

    DemoLogger.i(TAG, `Stress test stopped. ${this.formatReport(this.lastReport)}`);
    return this.lastReport;
  }

  private scheduleFinalUploadFlush(stopReason: StressStopReason): void {
    this.clearFinalUploadFlushTimer();
    const status = SyncTaskManager.getInstance().getStatus();
    if (status.autoSync) {
      DemoLogger.i(TAG,
        `<FT-STRESS-UPLOAD-FLUSH> skipped reason=${stopReason} autoSync=true ` +
          `running=${status.running} uploadRunning=${status.uploadLaneStatus.isRunning} ` +
          `uploadScheduled=${status.uploadLaneStatus.isScheduled} needReschedule=${status.uploadLaneStatus.needReschedule}`);
      return;
    }
    this.finalUploadFlushTimerId = setTimeout((): void => {
      this.finalUploadFlushTimerId = null;
      this.triggerFinalUploadFlush(stopReason, FINAL_UPLOAD_FLUSH_DELAY_MS);
    }, FINAL_UPLOAD_FLUSH_DELAY_MS);
  }

  private triggerFinalUploadFlush(stopReason: StressStopReason, delayMs: number): void {
    try {
      FTSDK.flushSyncData();
      const status = SyncTaskManager.getInstance().getStatus();
      DemoLogger.i(TAG,
        `<FT-STRESS-UPLOAD-FLUSH> reason=${stopReason} delayMs=${delayMs} autoSync=${status.autoSync} ` +
          `running=${status.running} uploadRunning=${status.uploadLaneStatus.isRunning} ` +
          `uploadScheduled=${status.uploadLaneStatus.isScheduled} needReschedule=${status.uploadLaneStatus.needReschedule}`);
    } catch (error) {
      this.recordErrorMessage(`final upload flush failed: ${error}`);
      DemoLogger.e(TAG, `<FT-STRESS-UPLOAD-FLUSH> failed reason=${stopReason} delayMs=${delayMs} error=${error}`);
    }
  }

  private clearFinalUploadFlushTimer(): void {
    if (this.finalUploadFlushTimerId !== null) {
      clearTimeout(this.finalUploadFlushTimerId);
      this.finalUploadFlushTimerId = null;
    }
  }

  private scheduleProductionSlice(callback: () => void): void {
    const timerId = setTimeout((): void => {
      this.removeProductionSliceTimer(timerId);
      callback();
    }, STRESS_PRODUCTION_SLICE_DELAY_MS);
    this.productionSliceTimerIds.push(timerId);
  }

  private removeProductionSliceTimer(timerId: number): void {
    const nextTimers: number[] = [];
    for (let i = 0; i < this.productionSliceTimerIds.length; i++) {
      if (this.productionSliceTimerIds[i] !== timerId) {
        nextTimers.push(this.productionSliceTimerIds[i]);
      }
    }
    this.productionSliceTimerIds = nextTimers;
  }

  private clearAllTimers(): void {
    for (let i = 0; i < this.logIntervalIds.length; i++) {
      clearInterval(this.logIntervalIds[i]);
    }
    for (let i = 0; i < this.actionIntervalIds.length; i++) {
      clearInterval(this.actionIntervalIds[i]);
    }
    for (let i = 0; i < this.resourceIntervalIds.length; i++) {
      clearInterval(this.resourceIntervalIds[i]);
    }
    for (let i = 0; i < this.exceptionIntervalIds.length; i++) {
      clearInterval(this.exceptionIntervalIds[i]);
    }
    for (let i = 0; i < this.productionSliceTimerIds.length; i++) {
      clearTimeout(this.productionSliceTimerIds[i]);
    }
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];
    this.exceptionIntervalIds = [];
    this.productionSliceTimerIds = [];
    this.logBatchRunning = false;
    this.errorBatchRunning = false;
    this.longTaskBatchRunning = false;
  }

  public getElapsedSeconds(): number {
    if (this.startTime === 0) {
      return 0;
    }
    const elapsedMs = Date.now() - this.startTime;
    return Math.floor(elapsedMs / 1000);
  }

  public getRemainingSeconds(): number {
    if (this.durationSeconds <= 0) {
      return -1;
    }
    if (this.startTime === 0) {
      return this.durationSeconds;
    }
    const remaining = this.durationSeconds - this.getElapsedSeconds();
    return remaining > 0 ? remaining : 0;
  }

  public isStressTestRunning(): boolean {
    return this.isRunning;
  }

  public isNavigationScenarioEnabled(): boolean {
    return this.isRunning &&
      this.currentConfig.enableNavigation &&
      !this.isScenarioTargetReached(this.currentStats.navigationSwitches, this.currentConfig);
  }

  public getNavigationIntervalMs(): number {
    return this.currentConfig.navigationIntervalMs;
  }

  public recordNavigationSwitch(): void {
    if (!this.isRunning || !this.currentConfig.enableNavigation) {
      return;
    }
    if (this.isScenarioTargetReached(this.currentStats.navigationSwitches, this.currentConfig)) {
      this.finishTotalCountStressIfComplete();
      return;
    }
    this.currentStats.navigationSwitches += 1;
    this.sampleCapabilityIfDue('navigation');
    this.finishTotalCountStressIfComplete();
  }

  public getStatsSnapshot(): StressTestStats {
    const stats = this.copyStats(this.currentStats);
    stats.isRunning = this.isRunning;
    if (this.isRunning) {
      stats.elapsedSeconds = this.getElapsedSeconds();
      stats.remainingSeconds = this.getRemainingSeconds();
    } else if (this.lastReport !== null) {
      stats.elapsedSeconds = this.lastReport.elapsedSeconds;
      stats.remainingSeconds = 0;
    }
    if (!this.isRunning && stats.endedAtMs === 0 && this.lastReport !== null) {
      stats.endedAtMs = this.lastReport.endedAtMs;
    }
    return stats;
  }

  public getLastReport(): StressTestReport | null {
    return this.lastReport;
  }

  public formatReport(report: StressTestReport | null): string {
    if (report === null) {
      return "";
    }

    const stats = report.stats;
    const resourceTotal = stats.resourcesSucceeded + stats.resourcesFailed;
    const successRate = resourceTotal > 0 ? Math.round((stats.resourcesSucceeded * 10000) / resourceTotal) / 100 : 0;
    const lines: string[] = [
      `Reason: ${report.stopReason}`,
      `Mode: ${stats.runMode}${stats.runMode === 'total' ? `, Target: ${stats.totalTargetCount}` : ''}`,
      `Elapsed: ${report.elapsedSeconds}s / ${report.durationSeconds > 0 ? `${report.durationSeconds}s` : 'indefinite'}`,
      `Traffic: ${stats.trafficMode}, Source: ${stats.source}`,
      `Logs: ${stats.logsGenerated} (${stats.logBatchesGenerated} batches)`,
      `Actions: ${stats.actionsGenerated}`,
      `Resources: ${stats.resourcesGenerated}, OK: ${stats.resourcesSucceeded}, Failed: ${stats.resourcesFailed}, Success: ${successRate}%`,
      `Navigation Switches: ${stats.navigationSwitches}, Interval: ${stats.navigationIntervalMs}ms`,
      `Errors: ${stats.errorsGenerated}, LongTasks: ${stats.longTasksGenerated}`,
      stats.lastErrorMessage.length > 0 ? `Last Error: ${stats.lastErrorMessage}` : "Last Error: none"
    ];

    if (report.capabilityReport !== null) {
      lines.push('');
      this.appendCapabilityReport(lines, report.capabilityReport);
    }
    return lines.join('\n');
  }

  private appendCapabilityReport(lines: string[], report: StressCapabilityReport): void {
    lines.push(`Capability Case: ${report.caseName}`);
    lines.push(
      `Input: ${report.inputMixedTasks} mixed tasks, enabled features=${report.enabledFeatureCount}, samples=${report.sampleCount}`
    );
    lines.push(
      `Queue: peak=${report.peakQueue} (dedicatedPool=${report.peakSchedulerQueue}, logEntry=${report.peakLogQueue}) ` +
        `at ${this.roundMetric(report.peakQueueElapsedMs / 1000, 2)}s`
    );
    lines.push(
      `JS/VM Heap: ${report.heapStartMb}MB -> ${report.heapPeakMb}MB -> ${report.heapEndMb}MB, ` +
        `peakDelta=${report.peakHeapDeltaMb}MB, avgQueuedTask=${report.avgQueuedTaskKb}KB`
    );
    lines.push(
      `Temperature: kind=${report.temperatureKind}, source=${report.temperatureSource}, ` +
        `${this.formatTemperatureC(report.temperatureStartC)} -> ${this.formatTemperatureC(report.temperaturePeakC)} -> ` +
        `${this.formatTemperatureC(report.temperatureEndC)}, delta=${this.formatTemperatureDeltaC(report)}`
    );
    lines.push(
      `Risk: vmLimit=${report.vmHeapLimitMb}MB(${report.vmHeapLimitSource}), safe=${this.roundMetric(report.safeWatermark * 100, 0)}%, ` +
        `reserved=${report.reservedHeapMb}MB, safeQueue~${report.safeQueueEstimate}, highRiskIn~${report.secondsToHighRisk}s`
    );
    lines.push(
      `Throughput: production=${report.productionQps}/s, completed=${report.completionQps}/s, backlogGrowth=${report.backlogGrowthPerSecond}/s`
    );
    lines.push(
      `Slow Lane: ${report.slowLane}, wait=${report.slowLaneAvgWaitMs}ms, cost=${report.slowLaneAvgCostMs}ms, bottleneck=${report.slowLaneBottleneck}`
    );
    lines.push(
      `Slow Business: ${report.slowBusinessEvent} (${report.slowBusinessTaskGroup}/${report.slowBusinessLane}), ` +
        `wait=${report.slowBusinessAvgWaitMs}ms, cost=${report.slowBusinessAvgCostMs}ms`
    );
    lines.push(
      `Log Drop: submitted=${report.logSubmitted}, accepted=${report.logAccepted}, dropped=${report.logDropped}, ` +
        `dropRate=${report.logDropRate}, cause=${report.logDropCause}`
    );
    lines.push(
      `UI Drift: tick=${CAPABILITY_UI_TICK_INTERVAL_MS}ms, max=${report.uiJankMaxDriftMs}ms, ` +
        `avg=${report.uiJankAvgDriftMs}ms, >=16ms=${report.uiJankOver16Count}, ` +
        `>=50ms=${report.uiJankOver50Count}, >=100ms=${report.uiJankOver100Count}, ` +
        `signal=${this.formatUiJankSignal(report.uiJankMaxDriftMs, report.uiJankOver50Count, report.uiJankOver100Count)}`
    );
    lines.push(`Lane Detail: ${this.formatLaneMetricSummary(report.lanes)}`);
    lines.push(`Business Detail: ${this.formatBusinessMetricSummary(report.businessEvents)}`);
  }

  public formatUiJankSignal(maxDriftMs: number, over50Count: number, over100Count: number): string {
    if (over100Count > 0 || maxDriftMs >= CAPABILITY_UI_STRONG_JANK_MS) {
      return 'strong-main-thread-block';
    }
    if (over50Count > 0 || maxDriftMs >= CAPABILITY_UI_MODERATE_JANK_MS) {
      return 'moderate-main-thread-block';
    }
    if (maxDriftMs >= CAPABILITY_UI_LIGHT_JANK_MS) {
      return 'light-frame-drop';
    }
    return 'normal';
  }

  private formatLaneMetricSummary(metrics: StressCapabilityLaneMetric[]): string {
    if (metrics.length === 0) {
      return 'none';
    }
    const parts: string[] = [];
    metrics.forEach((metric: StressCapabilityLaneMetric) => {
      const errorPart = metric.lastError.length > 0 ? `,lastError=${metric.lastError}` : '';
      const mailboxPart = metric.mailboxPending > 0 ? `,mailbox=${metric.mailboxPending}` : '';
      parts.push(
        `${metric.laneName}(sub=${metric.submitted},done=${metric.completed},fail=${metric.failed},pending=${metric.pending},` +
          `wait=${metric.avgWaitMs}ms,cost=${metric.avgCostMs}ms,backend=${metric.backend},bottleneck=${metric.bottleneck}${mailboxPart}${errorPart})`
      );
    });
    return parts.join(' | ');
  }

  private formatBusinessMetricSummary(metrics: StressCapabilityBusinessMetric[]): string {
    if (metrics.length === 0) {
      return 'none';
    }
    const parts: string[] = [];
    const count = Math.min(5, metrics.length);
    for (let index = 0; index < count; index++) {
      const metric = metrics[index];
      parts.push(
        `${metric.eventType}/${metric.taskGroup}/${metric.laneName}(sub=${metric.submitted},done=${metric.completed},` +
          `wait=${metric.avgWaitMs}ms,cost=${metric.avgCostMs}ms,bottleneck=${metric.bottleneck})`
      );
    }
    return parts.join(' | ');
  }

  private formatTemperatureC(value: number): string {
    if (value === CAPABILITY_TEMPERATURE_UNAVAILABLE_C) {
      return 'unavailable';
    }
    return `${value}C`;
  }

  private formatTemperatureDeltaC(report: StressCapabilityReport): string {
    if (!report.temperatureAvailable || report.temperatureDeltaC === CAPABILITY_TEMPERATURE_UNAVAILABLE_C) {
      return 'unavailable';
    }
    return `${report.temperatureDeltaC}C`;
  }

  private copyStats(stats: StressTestStats): StressTestStats {
    return {
      isRunning: stats.isRunning,
      startedAtMs: stats.startedAtMs,
      endedAtMs: stats.endedAtMs,
      durationSeconds: stats.durationSeconds,
      runMode: stats.runMode,
      totalTargetCount: stats.totalTargetCount,
      elapsedSeconds: stats.elapsedSeconds,
      remainingSeconds: stats.remainingSeconds,
      trafficMode: stats.trafficMode,
      source: stats.source,
      enableLogs: stats.enableLogs,
      enableActions: stats.enableActions,
      enableResources: stats.enableResources,
      enableNavigation: stats.enableNavigation,
      enableErrors: stats.enableErrors,
      enableLongTasks: stats.enableLongTasks,
      logsGenerated: stats.logsGenerated,
      logBatchesGenerated: stats.logBatchesGenerated,
      actionsGenerated: stats.actionsGenerated,
      resourcesGenerated: stats.resourcesGenerated,
      resourcesSucceeded: stats.resourcesSucceeded,
      resourcesFailed: stats.resourcesFailed,
      navigationSwitches: stats.navigationSwitches,
      navigationIntervalMs: stats.navigationIntervalMs,
      errorsGenerated: stats.errorsGenerated,
      longTasksGenerated: stats.longTasksGenerated,
      uiJankSamples: stats.uiJankSamples,
      uiJankMaxDriftMs: stats.uiJankMaxDriftMs,
      uiJankAvgDriftMs: stats.uiJankAvgDriftMs,
      uiJankOver16Count: stats.uiJankOver16Count,
      uiJankOver50Count: stats.uiJankOver50Count,
      uiJankOver100Count: stats.uiJankOver100Count,
      lastErrorMessage: stats.lastErrorMessage
    };
  }

  private recordErrorMessage(message: string): void {
    this.currentStats.lastErrorMessage = message;
  }

  private formatDurationForLog(durationSeconds: number): string {
    if (durationSeconds <= 0) {
      return 'indefinite';
    }
    const durationMinutes = Math.floor(durationSeconds / 60);
    const durationRemainingSeconds = durationSeconds % 60;
    return `${durationSeconds}s (${durationMinutes}m ${durationRemainingSeconds}s)`;
  }
}
