import {
  createFTRCPTrackConfig,
  FTLogger,
  FTRUMGlobalManager,
  NetStatusBean,
  ResourceParams,
  StringWrapper
} from '@guancecloud/ft_sdk/Index';
import { LogEntry } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { rcp } from '@kit.RemoteCommunicationKit';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from './DemoLogger';

const TAG = "StressTestManager";
const STRESS_TEST_LOG_TAG = "stress_test";
export const DEFAULT_REAL_TRAFFIC_URL = "https://httpbin.org/get?from=real-app-stress";
const MS_TO_NS = 1000000;

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
  lastErrorMessage: string;
}

export interface StressTestReport {
  stopReason: StressStopReason;
  startedAtMs: number;
  endedAtMs: number;
  elapsedSeconds: number;
  durationSeconds: number;
  stats: StressTestStats;
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

  private isRunning: boolean = false;
  private startTime: number = 0;
  private durationSeconds: number = 0;
  private autoStopTimerId: number | null = null;

  private rumManager: FTRUMGlobalManager | null = null;
  private currentConfig: StressTestConfig = createDefaultStressTestConfig(0, false);
  private currentStats: StressTestStats = createEmptyStressTestStats();
  private lastReport: StressTestReport | null = null;

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

  private getTraceTestUrl(resourceIndex: number): string {
    const stressUrls = this.parseResourceUrls(this.currentConfig.realResourceUrl);
    if (stressUrls.length > 0) {
      return this.selectRoundRobinUrl(stressUrls, resourceIndex);
    }

    const configuredUrl = ((AppStorage.get(KEY_TRACE_URL) as string | undefined) ?? "").trim();
    const configuredUrls = this.parseResourceUrls(configuredUrl);
    if (configuredUrls.length > 0) {
      return this.selectRoundRobinUrl(configuredUrls, resourceIndex);
    }

    return DEFAULT_REAL_TRAFFIC_URL;
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

  private selectRoundRobinUrl(urls: string[], resourceIndex: number): string {
    const safeIndex = Math.max(0, Math.floor(resourceIndex));
    return urls[safeIndex % urls.length];
  }

  private formatResourceUrlSummary(rawUrls: string): string {
    const urlCount = this.parseResourceUrls(rawUrls).length;
    return urlCount > 0 ? `${urlCount} configured` : 'traceUrl/default';
  }

  private initRUM(): void {
    if (this.rumManager === null) {
      this.rumManager = FTRUMGlobalManager.getInstance();
      if (this.rumManager === null) {
        DemoLogger.e(TAG, "Failed to get FTRUMGlobalManager instance");
        return;
      }
      if (!this.rumManager.isInitialized()) {
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
    this.currentConfig = normalizedConfig;
    this.lastReport = null;
    this.logCounter = 0;
    this.actionCounter = 0;
    this.resourceCounter = 0;
    this.errorCounter = 0;
    this.longTaskCounter = 0;
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];
    this.exceptionIntervalIds = [];
    this.currentStats = this.createStatsForStart(normalizedConfig, this.startTime);

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
    return this.rumManager === null || !this.rumManager.isInitialized();
  }

  private hasRumDependentScenario(config: StressTestConfig): boolean {
    return config.enableActions ||
      config.enableResources ||
      config.enableErrors ||
      config.enableLongTasks;
  }

  private sendLogBatch(batchSize: number = 2, tag: string = STRESS_TEST_LOG_TAG): void {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const batchLogs: LogEntry[] = [];
    const batchTimestampMs = Date.now();

    for (let i = 0; i < normalizedBatchSize; i++) {
      const logIndex = this.logCounter++;
      batchLogs.push({
        tag,
        message: this.createBatchLogMessage(logIndex),
        level: 'i',
        timestampMs: batchTimestampMs + i
      });
    }

    try {
      FTLogger.batchLog(batchLogs);
      this.currentStats.logsGenerated += batchLogs.length;
      this.currentStats.logBatchesGenerated += 1;
      DemoLogger.i(TAG, `Submitted log batch: tag=${tag}, size=${batchLogs.length}, totalGenerated=${this.logCounter}`);
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
      DemoLogger.i(TAG,
        `Log timer ${threadIndex} started: interval=${config.logIntervalMs}ms, batchSize=${config.logBatchSize}, total=${config.logTotalCount > 0 ? config.logTotalCount : 'unlimited'}`);
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
      this.sendLogBatch(emitCount, STRESS_TEST_LOG_TAG);
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
      DemoLogger.i(TAG, `Action timer ${threadIndex} started: interval=${config.actionIntervalMs}ms`);
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
        this.sendResource(threadIndex).catch((error: Error) => {
          this.currentStats.resourcesFailed += 1;
          this.recordErrorMessage(`sendResource failed: ${error.message}`);
          DemoLogger.e(TAG, `Error in sendResource for timer ${threadIndex}: ${error}`);
        }).then((): void => {
          this.finishTotalCountStressIfComplete();
        });
      }, config.resourceIntervalMs);
      this.resourceIntervalIds.push(intervalId);
      DemoLogger.i(TAG, `Resource timer ${threadIndex} started: interval=${config.resourceIntervalMs}ms`);
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
      if (!this.rumManager.isInitialized()) {
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
      this.rumManager.addActionWithProperty(actionName, 'click', property);
      this.currentStats.actionsGenerated += 1;
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

    try {
      if (this.currentConfig.trafficMode === 'real') {
        await this.sendRealResource(threadIndex, resourceIndex);
      } else {
        this.sendFakeResource(threadIndex, resourceIndex);
      }
      this.currentStats.resourcesSucceeded += 1;
    } catch (error) {
      this.currentStats.resourcesFailed += 1;
      this.recordErrorMessage(`resource failed: ${error}`);
      DemoLogger.e(TAG, `Failed to send resource from timer ${threadIndex}: ${error}`);
    }
  }

  private async sendRealResource(threadIndex: number, resourceIndex: number): Promise<void> {
    const realApiUrl = this.getTraceTestUrl(resourceIndex);
    const separator = realApiUrl.indexOf('?') >= 0 ? '&' : '?';
    const url =
      `${realApiUrl}${separator}tag=${STRESS_TEST_LOG_TAG}&stress_thread=${threadIndex}&stress_resource=${resourceIndex}&ts=${Date.now()}`;
    const session = rcp.createSession(createFTRCPTrackConfig());
    const request = new rcp.Request(url, 'GET');
    const response = await session.fetch(request);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      DemoLogger.i(TAG, `Real resource from timer ${threadIndex}, index ${resourceIndex} successful: ${response.statusCode}`);
    } else {
      throw new Error(`real request returned status=${response.statusCode}`);
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
    this.rumManager?.stopResource(resourceId, params.resourceStatus || 200, params.responseContentLength || 0);
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
      if (this.rumManager === null || !this.rumManager.isInitialized()) {
        return;
      }
      const errorIndex = this.errorCounter++;
      const property: Record<string, object> = {
        "tag": new StringWrapper(STRESS_TEST_LOG_TAG),
        "error_index": new StringWrapper(errorIndex.toString()),
        "source": new StringWrapper(this.currentConfig.source)
      };
      this.rumManager.addCustomError(
        `Stress custom error ${errorIndex}`,
        `Error: Stress custom error ${errorIndex}\n  at StressTestManager.sendCustomError`,
        property
      );
      this.currentStats.errorsGenerated += 1;
    } catch (error) {
      this.recordErrorMessage(`custom error failed: ${error}`);
      DemoLogger.e(TAG, `Failed to add custom error: ${error}`);
    }
  }

  private sendCustomErrorBatch(batchSize: number): boolean {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const remaining = this.getRemainingScenarioTarget(this.currentStats.errorsGenerated, this.currentConfig);
    const emitCount = Math.min(normalizedBatchSize, remaining);
    if (emitCount <= 0) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    for (let i = 0; i < emitCount; i++) {
      this.sendCustomError();
    }
    this.finishTotalCountStressIfComplete();
    return !this.isScenarioTargetReached(this.currentStats.errorsGenerated, this.currentConfig);
  }

  private sendLongTask(): void {
    try {
      if (this.rumManager === null || !this.rumManager.isInitialized()) {
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
    } catch (error) {
      this.recordErrorMessage(`long task failed: ${error}`);
      DemoLogger.e(TAG, `Failed to add long task: ${error}`);
    }
  }

  private sendLongTaskBatch(batchSize: number): boolean {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const remaining = this.getRemainingScenarioTarget(this.currentStats.longTasksGenerated, this.currentConfig);
    const emitCount = Math.min(normalizedBatchSize, remaining);
    if (emitCount <= 0) {
      this.finishTotalCountStressIfComplete();
      return false;
    }

    for (let i = 0; i < emitCount; i++) {
      this.sendLongTask();
    }
    this.finishTotalCountStressIfComplete();
    return !this.isScenarioTargetReached(this.currentStats.longTasksGenerated, this.currentConfig);
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
    if (this.currentStats.enableLogs && this.currentStats.logsGenerated > 0) {
      FTLogger.flush();
    }

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
      stats: this.copyStats(this.currentStats)
    };

    DemoLogger.i(TAG, `Stress test stopped. ${this.formatReport(this.lastReport)}`);
    return this.lastReport;
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
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];
    this.exceptionIntervalIds = [];
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
    return [
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
    ].join('\n');
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
