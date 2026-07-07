import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { ConfigRecord } from '../../main/ets/components/SyncTaskManager';
import { Status } from '../../main/ets/components/bean/Status';
import FTTrackInner from '../../main/ets/components/FTTrackInner';
import { FTLogger, FTInnerLogger } from '../../main/ets/components/log/FTLogger';
import { TrackLogManager } from '../../main/ets/components/log/TrackLogManager';
import { NetStatusBean } from '../../main/ets/components/rum/bean/NetStatusBean';
import { ResourceParams } from '../../main/ets/components/rum/bean/ResourceParams';
import { AppState, ErrorType } from '../../main/ets/components/rum/enum/RUMEnums';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { FTRUMGlobalManager } from '../../main/ets/components/rum/FTRUMGlobalManager';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
import {
  SDKTaskGroupStatus,
  SDKLaneStatus,
  SDKTaskPriority,
  SDKTaskScheduler,
  SDKTaskType
} from '../../main/ets/components/thread/SDKTaskScheduler';
import { SDKDedicatedPoolManager } from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import { CpuUtils } from '../../main/ets/components/utils/CpuUtils';
import { MemoryUtils } from '../../main/ets/components/utils/MemoryUtils';
import { TestReset } from '../helpers/TestReset';

const TAG = 'SDKThreadPoolCapability';
const TEST_URL = 'http://localhost';
const CAPABILITY_TASK_COUNT_PER_KIND = 100;
const MIXED_LOG_SUBMIT_COUNT = CAPABILITY_TASK_COUNT_PER_KIND;
const MIXED_RUM_CYCLE_COUNT = CAPABILITY_TASK_COUNT_PER_KIND;
const MIXED_RUM_EVENT_KIND_COUNT = 5;
const MIXED_VIEW_INTERVAL = 1;
const MIXED_BUSINESS_INPUT_TARGET = MIXED_LOG_SUBMIT_COUNT + MIXED_RUM_CYCLE_COUNT * MIXED_RUM_EVENT_KIND_COUNT;
const PURE_MIXED_DISPATCH_TASK_COUNT = MIXED_BUSINESS_INPUT_TARGET;
const MIXED_MARKER_INTERVAL = 20;
const STEP_PRESSURE_RUM_CYCLE_COUNT = 5000;
const STEP_PRESSURE_LOG_SUBMIT_COUNT = STEP_PRESSURE_RUM_CYCLE_COUNT;
const STEP_PRESSURE_TARGET_MIXED_INPUT = STEP_PRESSURE_RUM_CYCLE_COUNT * MIXED_RUM_EVENT_KIND_COUNT;
const STEP_PRESSURE_BATCH_CYCLES = 250;
const STEP_PRESSURE_BATCH_PAUSE_MS = 50;
const STEP_PRESSURE_FINAL_SAMPLE_FLUSH_ROUNDS = 20;
const VM_HEAP_FALLBACK_LIMIT_MB = 256;
const VM_HEAP_SAFE_WATERMARK = 0.80;
const BYTES_PER_KB = 1024;
const BYTES_PER_MB = 1024 * 1024;
const RUM_EVENT_SERIAL_KEY = 'rum-event-state';
const BUSINESS_EVENT_TYPES: string[] = [
  'view',
  'action',
  'resource',
  'longtask',
  'error',
  'log'
];
const PURE_MIXED_LANE_TYPES: SDKTaskType[] = [
  SDKTaskType.EVENT,
  SDKTaskType.LOG,
  SDKTaskType.INNER_LOG_FILE,
  SDKTaskType.DATA_PROCESS,
  SDKTaskType.CRASH_FILE,
  SDKTaskType.UPLOAD,
  SDKTaskType.ANR,
  SDKTaskType.CUSTOM
];
const MIXED_LANE_TYPES: SDKTaskType[] = [
  SDKTaskType.EVENT,
  SDKTaskType.LOG,
  SDKTaskType.DATA_PROCESS
];

interface ResourceSnapshot {
  cpuTicks: number;
  memoryBytes: number;
}

interface CapabilityReport {
  caseName: string;
  submitted: number;
  accepted: number;
  completed: number;
  failed: number;
  queuedTasks: number;
  dropped: number;
  dropRate: number;
  totalWaitMs: number;
  totalCostMs: number;
  submitMs: number;
  totalMs: number;
  submitQps: number;
  completedQps: number;
  p50LatencyMs: number;
  p95LatencyMs: number;
  p99LatencyMs: number;
  averageWaitMs: number;
  averageCostMs: number;
  averageDispatchMs: number;
  maxDispatchMs: number;
  pending: number;
  running: number;
  maxConcurrency: number;
  cpuTickDelta: number;
  memoryDeltaBytes: number;
  laneSummary: string;
}

interface MixedWorkloadStats {
  logSubmitted: number;
  logAccepted: number;
  rumSubmitted: number;
  viewSubmitted: number;
  totalSubmitted: number;
  totalAccepted: number;
}

interface BusinessEventProbeMetric {
  eventType: string;
  laneType: string;
  laneQueueMs: number;
  dataProcessQueueMs: number;
  totalMs: number;
}

interface QueueStatusSnapshot {
  queueSize: number;
  bufferSize: number;
  isProcessing: boolean;
  submittedCount: number;
  acceptedCount: number;
  droppedCount: number;
  filteredCount: number;
}

interface VmHeapSnapshot {
  heapUsedBytes: number;
  totalHeapBytes: number;
  allArrayBytes: number;
  source: string;
  available: boolean;
}

interface VmHeapLimitSnapshot {
  limitBytes: number;
  source: string;
  available: boolean;
}

interface StepPressureSample {
  elapsedMs: number;
  submittedInput: number;
  totalPending: number;
  eventPending: number;
  logPending: number;
  dataProcessPending: number;
  heapUsedBytes: number;
  heapSource: string;
}

interface QueueHeapRiskSummary {
  peakQueue: number;
  peakEventPending: number;
  peakLogPending: number;
  peakDataProcessPending: number;
  heapStartBytes: number;
  heapPeakBytes: number;
  heapEndBytes: number;
  heapDeltaBytes: number;
  avgQueuedTaskBytes: number;
  vmHeapLimitBytes: number;
  safeHeapBytes: number;
  estimatedSafeQueue: number;
  producerQps: number;
  completedQps: number;
  netBacklogQps: number;
  secondsToHighRisk: number;
  slowLane: string;
  slowLaneTotalWaitMs: number;
  slowLaneAvgWaitMs: number;
  slowLaneAvgProcessMs: number;
  heapSource: string;
  limitSource: string;
}

let pureDispatchBaselineReport: CapabilityReport | null = null;

class CapabilityConfigRecord implements ConfigRecord {
  private config: FTSDKConfig;

  constructor(config: FTSDKConfig) {
    this.config = config;
  }

  isLimitWithDbSize(): boolean {
    return this.config.isLimitWithDbSize();
  }

  getDbCacheLimit(): number {
    return this.config.getDbCacheLimit();
  }

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }
}

async function flushPromises(rounds: number = 20): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await Promise.resolve();
  }
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function qps(count: number, durationMs: number): number {
  return count * 1000 / Math.max(1, durationMs);
}

function percentile(values: number[], factor: number): number {
  if (values.length === 0) {
    return 0;
  }

  const sorted = values.slice().sort((left: number, right: number) => left - right);
  const index = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * factor));
  return sorted[index];
}

function roundMetric(value: number): number {
  return Math.round(value * 100) / 100;
}

function deltaValue(after: number, before: number): number {
  if (before < 0 || after < 0) {
    return -1;
  }
  return after - before;
}

function bytesToMb(bytes: number): number {
  if (bytes < 0) {
    return -1;
  }
  return bytes / BYTES_PER_MB;
}

function bytesToKb(bytes: number): number {
  if (bytes < 0) {
    return -1;
  }
  return bytes / BYTES_PER_KB;
}

function bigintKbToBytes(value: bigint): number {
  return Number(value) * BYTES_PER_KB;
}

function getLaneStatus(type: SDKTaskType): SDKLaneStatus {
  return SDKTaskScheduler.getInstance().getStatus().lanes[type];
}

async function captureResourceSnapshot(): Promise<ResourceSnapshot> {
  const cpuUtils = CpuUtils.getInstance();
  const memoryUtils = MemoryUtils.getInstance();

  await cpuUtils.init();
  await memoryUtils.init();

  cpuUtils.forceRefresh();
  memoryUtils.forceRefresh();

  const cpuTicks = await cpuUtils.getAppCpuTickCount();
  const memoryBytes = await memoryUtils.getAppMemoryUsage();

  return { cpuTicks, memoryBytes };
}

async function captureVmHeapSnapshot(): Promise<VmHeapSnapshot> {
  try {
    const vmMemory = hidebug.getAppVMMemoryInfo();
    return {
      heapUsedBytes: bigintKbToBytes(vmMemory.heapUsed),
      totalHeapBytes: bigintKbToBytes(vmMemory.totalHeap),
      allArrayBytes: bigintKbToBytes(vmMemory.allArraySize),
      source: 'hidebug.vm',
      available: true
    };
  } catch (error) {
    const memoryUtils = MemoryUtils.getInstance();
    await memoryUtils.init();
    memoryUtils.forceRefresh();
    const fallbackBytes = await memoryUtils.getAppMemoryUsage();
    return {
      heapUsedBytes: fallbackBytes,
      totalHeapBytes: fallbackBytes,
      allArrayBytes: -1,
      source: fallbackBytes > 0 ? 'rss-fallback' : 'unavailable',
      available: fallbackBytes > 0
    };
  }
}

function captureVmHeapLimitSnapshot(): VmHeapLimitSnapshot {
  try {
    const limit = hidebug.getAppMemoryLimit();
    const vmHeapLimitBytes = bigintKbToBytes(limit.vmHeapLimit);
    if (vmHeapLimitBytes > 0) {
      return {
        limitBytes: vmHeapLimitBytes,
        source: 'hidebug.vmHeapLimit',
        available: true
      };
    }

    const vmTotalHeapSizeBytes = bigintKbToBytes(limit.vmTotalHeapSize);
    if (vmTotalHeapSizeBytes > 0) {
      return {
        limitBytes: vmTotalHeapSizeBytes,
        source: 'hidebug.vmTotalHeapSize',
        available: true
      };
    }
  } catch (error) {
    // Fall back below when HiDebug memory limit is unavailable in the test runtime.
  }

  return {
    limitBytes: VM_HEAP_FALLBACK_LIMIT_MB * BYTES_PER_MB,
    source: 'fallback-256mb',
    available: false
  };
}

async function waitForSchedulerIdle(types: SDKTaskType[], timeoutMs: number = 5000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    await delay(10);
    await flushPromises(5);

    const schedulerStatus = SDKTaskScheduler.getInstance().getStatus();
    let idle = schedulerStatus.activeSingleFlightTasks === 0 && schedulerStatus.rescheduledSingleFlightTasks === 0;

    for (const type of types) {
      const laneStatus = schedulerStatus.lanes[type];
      idle = idle && laneStatus.pending === 0 && laneStatus.running === 0;
    }

    if (idle) {
      return true;
    }
  }
  return false;
}

function printReport(report: CapabilityReport): void {
  console.info(
    TAG,
    `case=${report.caseName}` +
      ` submitted=${report.submitted}` +
      ` accepted=${report.accepted}` +
      ` completed=${report.completed}` +
      ` failed=${report.failed}` +
      ` queuedTasks=${report.queuedTasks}` +
      ` dropped=${report.dropped}` +
      ` dropRate=${roundMetric(report.dropRate)}` +
      ` totalWaitMs=${roundMetric(report.totalWaitMs)}` +
      ` totalCostMs=${roundMetric(report.totalCostMs)}` +
      ` submitMs=${report.submitMs}` +
      ` totalMs=${report.totalMs}` +
      ` submitQps=${roundMetric(report.submitQps)}` +
      ` completedQps=${roundMetric(report.completedQps)}` +
      ` p50LatencyMs=${roundMetric(report.p50LatencyMs)}` +
      ` p95LatencyMs=${roundMetric(report.p95LatencyMs)}` +
      ` p99LatencyMs=${roundMetric(report.p99LatencyMs)}` +
      ` avgWaitMs=${roundMetric(report.averageWaitMs)}` +
      ` avgCostMs=${roundMetric(report.averageCostMs)}` +
      ` avgDispatchMs=${roundMetric(report.averageDispatchMs)}` +
      ` maxDispatchMs=${report.maxDispatchMs}` +
      ` pending=${report.pending}` +
      ` running=${report.running}` +
      ` maxConcurrency=${report.maxConcurrency}` +
      ` cpuTickDelta=${report.cpuTickDelta}` +
      ` memoryDeltaBytes=${report.memoryDeltaBytes}` +
      (report.laneSummary.length > 0 ? ` lanes=${report.laneSummary}` : '')
  );
}

function buildReport(
  caseName: string,
  submitted: number,
  accepted: number,
  completed: number,
  failed: number,
  submitMs: number,
  totalMs: number,
  latencies: number[],
  laneStatus: SDKLaneStatus,
  beforeResources: ResourceSnapshot,
  afterResources: ResourceSnapshot,
  laneSummary: string = ''
): CapabilityReport {
  const dropped = Math.max(0, submitted - accepted);
  return {
    caseName,
    submitted,
    accepted,
    completed,
    failed,
    queuedTasks: laneStatus.queuedTasks,
    dropped,
    dropRate: submitted > 0 ? dropped / submitted : 0,
    totalWaitMs: laneStatus.totalWaitTime,
    totalCostMs: laneStatus.totalCostTime,
    submitMs,
    totalMs,
    submitQps: qps(submitted, submitMs),
    completedQps: qps(completed, totalMs),
    p50LatencyMs: percentile(latencies, 0.50),
    p95LatencyMs: percentile(latencies, 0.95),
    p99LatencyMs: percentile(latencies, 0.99),
    averageWaitMs: laneStatus.averageWaitTime,
    averageCostMs: laneStatus.averageCostTime,
    averageDispatchMs: laneStatus.averageDispatchTime,
    maxDispatchMs: laneStatus.maxDispatchTime,
    pending: laneStatus.pending,
    running: laneStatus.running,
    maxConcurrency: laneStatus.maxConcurrency,
    cpuTickDelta: deltaValue(afterResources.cpuTicks, beforeResources.cpuTicks),
    memoryDeltaBytes: deltaValue(afterResources.memoryBytes, beforeResources.memoryBytes),
    laneSummary
  };
}

function aggregateLaneStatuses(types: SDKTaskType[]): SDKLaneStatus {
  let pending = 0;
  let running = 0;
  let maxConcurrency = 0;
  let submittedTasks = 0;
  let completedTasks = 0;
  let failedTasks = 0;
  let queuedTasks = 0;
  let dispatchCount = 0;
  let totalWaitTime = 0;
  let totalCostTime = 0;
  let totalDispatchTime = 0;
  let maxDispatchTime = 0;
  let lastDispatchTime = 0;
  let totalScanCount = 0;
  let maxScanCount = 0;
  let lastScanCount = 0;
  let oldestWait = 0;
  let lastError: string | null = null;

  for (const type of types) {
    const status = getLaneStatus(type);
    const processedTasks = status.completedTasks + status.failedTasks;
    pending += status.pending;
    running += status.running;
    maxConcurrency += status.maxConcurrency;
    submittedTasks += status.submittedTasks;
    completedTasks += status.completedTasks;
    failedTasks += status.failedTasks;
    queuedTasks += status.queuedTasks;
    dispatchCount += status.dispatchCount;
    totalWaitTime += status.totalWaitTime;
    totalCostTime += status.totalCostTime;
    totalDispatchTime += status.averageDispatchTime * status.dispatchCount;
    maxDispatchTime = Math.max(maxDispatchTime, status.maxDispatchTime);
    lastDispatchTime = Math.max(lastDispatchTime, status.lastDispatchTime);
    totalScanCount += status.averageScanCount * status.dispatchCount;
    maxScanCount = Math.max(maxScanCount, status.maxScanCount);
    lastScanCount = Math.max(lastScanCount, status.lastScanCount);
    oldestWait = Math.max(oldestWait, status.oldestWait);
    if (lastError === null && status.lastError !== null) {
      lastError = status.lastError;
    }
  }

  const processedTasks = completedTasks + failedTasks;
  return {
    pending,
    running,
    maxConcurrency,
    submittedTasks,
    completedTasks,
    failedTasks,
    queuedTasks,
    dispatchCount,
    totalWaitTime,
    totalCostTime,
    averageWaitTime: processedTasks > 0 ? totalWaitTime / processedTasks : 0,
    averageCostTime: processedTasks > 0 ? totalCostTime / processedTasks : 0,
    averageDispatchTime: dispatchCount > 0 ? totalDispatchTime / dispatchCount : 0,
    maxDispatchTime,
    lastDispatchTime,
    averageScanCount: dispatchCount > 0 ? totalScanCount / dispatchCount : 0,
    maxScanCount,
    lastScanCount,
    oldestWait,
    lastError
  };
}

function formatLaneSummary(types: SDKTaskType[]): string {
  const parts: string[] = [];
  for (const type of types) {
    const status = getLaneStatus(type);
    parts.push(
      `${type}:submitted=${status.submittedTasks},completed=${status.completedTasks},failed=${status.failedTasks},pending=${status.pending},running=${status.running}`
    );
  }
  return parts.join('|');
}

function average(values: number[]): number {
  if (values.length === 0) {
    return 0;
  }

  let total = 0;
  for (const value of values) {
    total += value;
  }
  return total / values.length;
}

function classifyWaitOrCost(waitMs: number, costMs: number): string {
  if (waitMs > costMs * 2 && waitMs > 1) {
    return 'queue';
  }
  if (costMs > waitMs * 2 && costMs > 1) {
    return 'process';
  }
  return 'balanced';
}

function classifyBusinessQueue(laneQueueMs: number, dataProcessQueueMs: number): string {
  if (laneQueueMs > dataProcessQueueMs * 1.5 && laneQueueMs > 1) {
    return 'upstream-lane-queue';
  }
  if (dataProcessQueueMs > laneQueueMs * 1.5 && dataProcessQueueMs > 1) {
    return 'data-process-queue';
  }
  return 'balanced';
}

function printLaneBreakdown(caseName: string, types: SDKTaskType[]): void {
  for (const type of types) {
    const status = getLaneStatus(type);
    console.info(
      TAG,
      `case=${caseName}` +
        ` breakdown=lane` +
        ` lane=${type}` +
        ` submitted=${status.submittedTasks}` +
        ` completed=${status.completedTasks}` +
        ` failed=${status.failedTasks}` +
        ` pending=${status.pending}` +
        ` running=${status.running}` +
        ` maxConcurrency=${status.maxConcurrency}` +
        ` avgWaitMs=${roundMetric(status.averageWaitTime)}` +
        ` avgCostMs=${roundMetric(status.averageCostTime)}` +
        ` maxDispatchMs=${status.maxDispatchTime}` +
        ` oldestWaitMs=${status.oldestWait}` +
        ` bottleneck=${classifyWaitOrCost(status.averageWaitTime, status.averageCostTime)}`
    );
  }
}

function printQueueCostSummary(caseName: string, scope: string, name: string, status: SDKLaneStatus): void {
  const processedTasks = status.completedTasks + status.failedTasks;
  const queuedRate = processedTasks > 0 ? status.queuedTasks / processedTasks : 0;
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=queue-cost` +
      ` scope=${scope}` +
      ` name=${name}` +
      ` submitted=${status.submittedTasks}` +
      ` completed=${status.completedTasks}` +
      ` failed=${status.failedTasks}` +
      ` queuedTasks=${status.queuedTasks}` +
      ` queuedRate=${roundMetric(queuedRate)}` +
      ` totalWaitMs=${roundMetric(status.totalWaitTime)}` +
      ` avgWaitMs=${roundMetric(status.averageWaitTime)}` +
      ` totalCostMs=${roundMetric(status.totalCostTime)}` +
      ` avgProcessMs=${roundMetric(status.averageCostTime)}` +
      ` bottleneck=${classifyWaitOrCost(status.averageWaitTime, status.averageCostTime)}`
  );
}

function printQueueCostSummaries(caseName: string, types: SDKTaskType[]): void {
  printQueueCostSummary(caseName, 'overall', 'mixed-lanes', aggregateLaneStatuses(types));
  for (const type of types) {
    printQueueCostSummary(caseName, 'lane', type, getLaneStatus(type));
  }
}

function printBusinessInputSummary(caseName: string, stats: MixedWorkloadStats): void {
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=business-input` +
      ` logSubmitted=${stats.logSubmitted}` +
      ` logAcceptedAtEntry=${stats.logAccepted}` +
      ` rumCycles=${MIXED_RUM_CYCLE_COUNT}` +
      ` viewSubmitted=${stats.viewSubmitted}` +
      ` actionSubmitted=${MIXED_RUM_CYCLE_COUNT}` +
      ` resourceSubmitted=${MIXED_RUM_CYCLE_COUNT}` +
      ` longtaskSubmitted=${MIXED_RUM_CYCLE_COUNT}` +
      ` errorSubmitted=${MIXED_RUM_CYCLE_COUNT}` +
      ` totalBusinessSubmitted=${stats.totalSubmitted}` +
      ` totalBusinessAccepted=${stats.totalAccepted}`
  );
}

function printStepPressureInputSummary(caseName: string, acceptedAtEntry: number, status: QueueStatusSnapshot): void {
  const viewContextSubmitted = Math.ceil(STEP_PRESSURE_RUM_CYCLE_COUNT / MIXED_VIEW_INTERVAL);
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=business-input` +
      ` targetMixedInput=${STEP_PRESSURE_TARGET_MIXED_INPUT}` +
      ` logSubmitted=${STEP_PRESSURE_LOG_SUBMIT_COUNT}` +
      ` logAcceptedAtEntry=${acceptedAtEntry}` +
      ` logEntryDropped=${Math.max(0, STEP_PRESSURE_LOG_SUBMIT_COUNT - acceptedAtEntry)}` +
      ` viewContextSubmitted=${viewContextSubmitted}` +
      ` actionSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` resourceSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` longtaskSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` errorSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` entrySubmittedCount=${status.submittedCount}` +
      ` entryAcceptedCount=${status.acceptedCount}` +
      ` entryDroppedCount=${status.droppedCount}` +
      ` entryFilteredCount=${status.filteredCount}`
  );
}

function printStepPressureReportInput(caseName: string, heapLimit: VmHeapLimitSnapshot): void {
  const viewContextSubmitted = Math.ceil(STEP_PRESSURE_RUM_CYCLE_COUNT / MIXED_VIEW_INTERVAL);
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=report-input` +
      ` mode=sampling` +
      ` targetMixedInput=${STEP_PRESSURE_TARGET_MIXED_INPUT}` +
      ` perBusinessEventCount=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` logSubmitted=${STEP_PRESSURE_LOG_SUBMIT_COUNT}` +
      ` actionSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` resourceSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` longtaskSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` errorSubmitted=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` viewContextSubmitted=${viewContextSubmitted}` +
      ` observedLanes=${MIXED_LANE_TYPES.join('|')}` +
      ` sampleEveryCycles=${STEP_PRESSURE_BATCH_CYCLES}` +
      ` samplePauseMs=${STEP_PRESSURE_BATCH_PAUSE_MS}` +
      ` finalSampleFlushRounds=${STEP_PRESSURE_FINAL_SAMPLE_FLUSH_ROUNDS}` +
      ` safeWatermarkPct=${roundMetric(VM_HEAP_SAFE_WATERMARK * 100)}` +
      ` vmHeapLimitMb=${roundMetric(bytesToMb(heapLimit.limitBytes))}` +
      ` limitSource=${heapLimit.source}`
  );
}

function ratioPercent(part: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  return part * 100 / total;
}

function safeMultiplier(value: number, baseline: number): number {
  if (baseline <= 0) {
    return 0;
  }
  return value / baseline;
}

function printCapacityGap(pureReport: CapabilityReport, realReport: CapabilityReport): void {
  const completedCapacityPct = ratioPercent(realReport.completedQps, pureReport.completedQps);
  const submitCapacityPct = ratioPercent(realReport.submitQps, pureReport.submitQps);
  console.info(
    TAG,
    `metric=capacity-gap` +
      ` pureCase=${pureReport.caseName}` +
      ` realCase=${realReport.caseName}` +
      ` pureCompletedQps=${roundMetric(pureReport.completedQps)}` +
      ` realCompletedQps=${roundMetric(realReport.completedQps)}` +
      ` realVsPureCompletedCapacityPct=${roundMetric(completedCapacityPct)}` +
      ` completedQpsGap=${roundMetric(pureReport.completedQps - realReport.completedQps)}` +
      ` pureSubmitQps=${roundMetric(pureReport.submitQps)}` +
      ` realSubmitQps=${roundMetric(realReport.submitQps)}` +
      ` realVsPureSubmitCapacityPct=${roundMetric(submitCapacityPct)}` +
      ` pureAvgWaitMs=${roundMetric(pureReport.averageWaitMs)}` +
      ` realAvgWaitMs=${roundMetric(realReport.averageWaitMs)}` +
      ` avgWaitMultiplier=${roundMetric(safeMultiplier(realReport.averageWaitMs, pureReport.averageWaitMs))}` +
      ` pureAvgProcessMs=${roundMetric(pureReport.averageCostMs)}` +
      ` realAvgProcessMs=${roundMetric(realReport.averageCostMs)}` +
      ` avgProcessMultiplier=${roundMetric(safeMultiplier(realReport.averageCostMs, pureReport.averageCostMs))}` +
      ` pureTotalWaitMs=${roundMetric(pureReport.totalWaitMs)}` +
      ` realTotalWaitMs=${roundMetric(realReport.totalWaitMs)}` +
      ` totalWaitMultiplier=${roundMetric(safeMultiplier(realReport.totalWaitMs, pureReport.totalWaitMs))}`
  );
}

function getPeakQueueSample(samples: StepPressureSample[]): StepPressureSample {
  let peak = samples[0];
  for (const sample of samples) {
    if (sample.totalPending > peak.totalPending) {
      peak = sample;
    }
  }
  return peak;
}

function getPeakHeapBytes(samples: StepPressureSample[], startHeapBytes: number, endHeapBytes: number): number {
  let peakHeapBytes = Math.max(startHeapBytes, endHeapBytes);
  for (const sample of samples) {
    if (sample.heapUsedBytes > peakHeapBytes) {
      peakHeapBytes = sample.heapUsedBytes;
    }
  }
  return peakHeapBytes;
}

function getSlowestQueueLane(types: SDKTaskType[]): SDKTaskType {
  let slowestType = types[0];
  let maxTotalWait = -1;
  for (const type of types) {
    const status = getLaneStatus(type);
    if (status.totalWaitTime > maxTotalWait) {
      maxTotalWait = status.totalWaitTime;
      slowestType = type;
    }
  }
  return slowestType;
}

async function captureStepPressureSample(startAt: number, submittedInput: number): Promise<StepPressureSample> {
  const heap = await captureVmHeapSnapshot();
  const eventStatus = getLaneStatus(SDKTaskType.EVENT);
  const logStatus = getLaneStatus(SDKTaskType.LOG);
  const dataProcessStatus = getLaneStatus(SDKTaskType.DATA_PROCESS);
  return {
    elapsedMs: Math.max(0, Date.now() - startAt),
    submittedInput,
    totalPending: eventStatus.pending + logStatus.pending + dataProcessStatus.pending,
    eventPending: eventStatus.pending,
    logPending: logStatus.pending,
    dataProcessPending: dataProcessStatus.pending,
    heapUsedBytes: heap.heapUsedBytes,
    heapSource: heap.source
  };
}

function printStepPressureSample(caseName: string, sample: StepPressureSample): void {
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=step-pressure-sample` +
      ` elapsedMs=${sample.elapsedMs}` +
      ` submittedInput=${sample.submittedInput}` +
      ` pending=${sample.totalPending}` +
      ` eventPending=${sample.eventPending}` +
      ` logPending=${sample.logPending}` +
      ` dataProcessPending=${sample.dataProcessPending}` +
      ` heapUsedMb=${roundMetric(bytesToMb(sample.heapUsedBytes))}` +
      ` heapSource=${sample.heapSource}`
  );
}

function buildQueueHeapRiskSummary(
  samples: StepPressureSample[],
  heapStart: VmHeapSnapshot,
  heapEnd: VmHeapSnapshot,
  heapLimit: VmHeapLimitSnapshot,
  submitMs: number,
  totalMs: number,
  completedTasks: number
): QueueHeapRiskSummary {
  const peakSample = getPeakQueueSample(samples);
  const heapPeakBytes = getPeakHeapBytes(samples, heapStart.heapUsedBytes, heapEnd.heapUsedBytes);
  const heapDeltaBytes = heapStart.available && heapPeakBytes > 0 ? Math.max(0, heapPeakBytes - heapStart.heapUsedBytes) : -1;
  const avgQueuedTaskBytes = heapDeltaBytes > 0 && peakSample.totalPending > 0 ? heapDeltaBytes / peakSample.totalPending : -1;
  const safeHeapBytes = heapLimit.limitBytes * VM_HEAP_SAFE_WATERMARK;
  const estimatedSafeQueue = avgQueuedTaskBytes > 0 && heapStart.heapUsedBytes > 0 ?
    Math.floor(Math.max(0, safeHeapBytes - heapStart.heapUsedBytes) / avgQueuedTaskBytes) : -1;
  const producerQps = qps(STEP_PRESSURE_TARGET_MIXED_INPUT, submitMs);
  const completedQps = qps(completedTasks, totalMs);
  const netBacklogQps = Math.max(0, producerQps - completedQps);
  let secondsToHighRisk = -1;
  if (estimatedSafeQueue >= 0 && netBacklogQps > 0) {
    secondsToHighRisk = Math.max(0, (estimatedSafeQueue - peakSample.totalPending) / netBacklogQps);
  }

  const slowLane = getSlowestQueueLane(MIXED_LANE_TYPES);
  const slowLaneStatus = getLaneStatus(slowLane);
  return {
    peakQueue: peakSample.totalPending,
    peakEventPending: peakSample.eventPending,
    peakLogPending: peakSample.logPending,
    peakDataProcessPending: peakSample.dataProcessPending,
    heapStartBytes: heapStart.heapUsedBytes,
    heapPeakBytes,
    heapEndBytes: heapEnd.heapUsedBytes,
    heapDeltaBytes,
    avgQueuedTaskBytes,
    vmHeapLimitBytes: heapLimit.limitBytes,
    safeHeapBytes,
    estimatedSafeQueue,
    producerQps,
    completedQps,
    netBacklogQps,
    secondsToHighRisk,
    slowLane,
    slowLaneTotalWaitMs: slowLaneStatus.totalWaitTime,
    slowLaneAvgWaitMs: slowLaneStatus.averageWaitTime,
    slowLaneAvgProcessMs: slowLaneStatus.averageCostTime,
    heapSource: heapStart.source,
    limitSource: heapLimit.source
  };
}

function printQueueHeapRiskSummary(caseName: string, summary: QueueHeapRiskSummary): void {
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=queue-heap-risk` +
      ` mode=sampling` +
      ` targetMixedInput=${STEP_PRESSURE_TARGET_MIXED_INPUT}` +
      ` rumCycles=${STEP_PRESSURE_RUM_CYCLE_COUNT}` +
      ` logSubmitted=${STEP_PRESSURE_LOG_SUBMIT_COUNT}` +
      ` peakQueue=${summary.peakQueue}` +
      ` peakEventPending=${summary.peakEventPending}` +
      ` peakLogPending=${summary.peakLogPending}` +
      ` peakDataProcessPending=${summary.peakDataProcessPending}` +
      ` heapStartMb=${roundMetric(bytesToMb(summary.heapStartBytes))}` +
      ` heapPeakMb=${roundMetric(bytesToMb(summary.heapPeakBytes))}` +
      ` heapEndMb=${roundMetric(bytesToMb(summary.heapEndBytes))}` +
      ` heapDeltaMb=${roundMetric(bytesToMb(summary.heapDeltaBytes))}` +
      ` avgQueuedTaskKb=${roundMetric(bytesToKb(summary.avgQueuedTaskBytes))}` +
      ` vmHeapLimitMb=${roundMetric(bytesToMb(summary.vmHeapLimitBytes))}` +
      ` safeWatermarkPct=${roundMetric(VM_HEAP_SAFE_WATERMARK * 100)}` +
      ` safeHeapMb=${roundMetric(bytesToMb(summary.safeHeapBytes))}` +
      ` estimatedSafeQueue=${summary.estimatedSafeQueue}` +
      ` producerQps=${roundMetric(summary.producerQps)}` +
      ` completedQps=${roundMetric(summary.completedQps)}` +
      ` netBacklogQps=${roundMetric(summary.netBacklogQps)}` +
      ` secondsToHighRisk=${roundMetric(summary.secondsToHighRisk)}` +
      ` slowLane=${summary.slowLane}` +
      ` slowLaneTotalWaitMs=${roundMetric(summary.slowLaneTotalWaitMs)}` +
      ` slowLaneAvgWaitMs=${roundMetric(summary.slowLaneAvgWaitMs)}` +
      ` slowLaneAvgProcessMs=${roundMetric(summary.slowLaneAvgProcessMs)}` +
      ` slowLaneBottleneck=${classifyWaitOrCost(summary.slowLaneAvgWaitMs, summary.slowLaneAvgProcessMs)}` +
      ` heapSource=${summary.heapSource}` +
      ` limitSource=${summary.limitSource}`
  );
}

function printStepPressureReportOutput(
  caseName: string,
  summary: QueueHeapRiskSummary,
  logAcceptedAtEntry: number,
  logStatusAfterSubmit: QueueStatusSnapshot,
  aggregateStatus: SDKLaneStatus
): void {
  const logEntryDropped = Math.max(0, STEP_PRESSURE_LOG_SUBMIT_COUNT - logAcceptedAtEntry);
  console.info(
    TAG,
    `case=${caseName}` +
      ` metric=report-output` +
      ` mode=sampling` +
      ` targetMixedInput=${STEP_PRESSURE_TARGET_MIXED_INPUT}` +
      ` acceptedMixedInput=${STEP_PRESSURE_TARGET_MIXED_INPUT + logAcceptedAtEntry}` +
      ` completedTasks=${aggregateStatus.completedTasks}` +
      ` failedTasks=${aggregateStatus.failedTasks}` +
      ` logAcceptedAtEntry=${logAcceptedAtEntry}` +
      ` logEntryDropped=${logEntryDropped}` +
      ` logEntryDroppedCount=${logStatusAfterSubmit.droppedCount}` +
      ` logEntryFilteredCount=${logStatusAfterSubmit.filteredCount}` +
      ` peakQueue=${summary.peakQueue}` +
      ` peakEventPending=${summary.peakEventPending}` +
      ` peakLogPending=${summary.peakLogPending}` +
      ` peakDataProcessPending=${summary.peakDataProcessPending}` +
      ` heapStartMb=${roundMetric(bytesToMb(summary.heapStartBytes))}` +
      ` heapPeakMb=${roundMetric(bytesToMb(summary.heapPeakBytes))}` +
      ` heapDeltaMb=${roundMetric(bytesToMb(summary.heapDeltaBytes))}` +
      ` avgQueuedTaskKb=${roundMetric(bytesToKb(summary.avgQueuedTaskBytes))}` +
      ` vmHeapLimitMb=${roundMetric(bytesToMb(summary.vmHeapLimitBytes))}` +
      ` safeHeapMb=${roundMetric(bytesToMb(summary.safeHeapBytes))}` +
      ` estimatedSafeQueue=${summary.estimatedSafeQueue}` +
      ` producerQps=${roundMetric(summary.producerQps)}` +
      ` completedQps=${roundMetric(summary.completedQps)}` +
      ` netBacklogQps=${roundMetric(summary.netBacklogQps)}` +
      ` secondsToHighRisk=${roundMetric(summary.secondsToHighRisk)}` +
      ` slowLane=${summary.slowLane}` +
      ` slowLaneAvgWaitMs=${roundMetric(summary.slowLaneAvgWaitMs)}` +
      ` slowLaneAvgProcessMs=${roundMetric(summary.slowLaneAvgProcessMs)}` +
      ` slowLaneBottleneck=${classifyWaitOrCost(summary.slowLaneAvgWaitMs, summary.slowLaneAvgProcessMs)}` +
      ` heapSource=${summary.heapSource}` +
      ` limitSource=${summary.limitSource}`
  );
}

function getBusinessTypeForTaskGroup(group: SDKTaskGroupStatus): string {
  const groupName = group.groupName;
  if (groupName.indexOf('log.') === 0 || groupName.indexOf('data.prepare.logBatch') === 0) {
    return 'log';
  }
  if (groupName.indexOf('data.prepare:view') === 0 ||
    groupName.indexOf('rum.initView') === 0 ||
    groupName.indexOf('rum.closeAllActionAndView') === 0) {
    return 'view';
  }
  if (groupName.indexOf('data.prepare:action') === 0 ||
    groupName.indexOf('rum.addAction') === 0 ||
    groupName.indexOf('rum.startAction') === 0 ||
    groupName.indexOf('rum.closeAction') === 0 ||
    groupName.indexOf('rum.increaseViewAction') === 0) {
    return 'action';
  }
  if (groupName.indexOf('data.prepare:resource') === 0 ||
    groupName.indexOf('rum.resourceCleanup') === 0 ||
    groupName.indexOf('rum.increaseResource') === 0 ||
    groupName.indexOf('rum.increasePendingResource') === 0 ||
    groupName.indexOf('rum.decreasePendingResource') === 0) {
    return 'resource';
  }
  if (groupName.indexOf('data.prepare:long_task') === 0 ||
    groupName.indexOf('rum.increaseLongTask') === 0 ||
    groupName.indexOf('rum.increaseViewLongTask') === 0 ||
    groupName.indexOf('rum.increaseActionLongTask') === 0) {
    return 'longtask';
  }
  if (groupName.indexOf('data.prepare:error') === 0 ||
    groupName.indexOf('data.prepare.errorSampled') === 0 ||
    groupName.indexOf('rum.addError') === 0 ||
    groupName.indexOf('rum.increaseError') === 0) {
    return 'error';
  }
  if (groupName.indexOf('rum.') === 0 || groupName.indexOf('data.prepare') === 0) {
    return 'rum-internal';
  }
  return 'other';
}

function isObservedTaskGroup(group: SDKTaskGroupStatus): boolean {
  const groupName = group.groupName;
  if (groupName.indexOf('pure-mixed-') === 0 ||
    groupName.indexOf('mixed-') === 0 ||
    groupName.indexOf('business-probe') === 0) {
    return false;
  }
  return groupName.indexOf('rum.') === 0 ||
    groupName.indexOf('log.') === 0 ||
    groupName.indexOf('data.prepare') === 0;
}

function printTaskGroupBreakdown(caseName: string): void {
  const taskGroups = SDKTaskScheduler.getInstance().getStatus().taskGroups;
  const keys = Object.keys(taskGroups).sort();
  for (const key of keys) {
    const group = taskGroups[key];
    if (!isObservedTaskGroup(group)) {
      continue;
    }
    console.info(
      TAG,
      `case=${caseName}` +
        ` breakdown=task-group` +
        ` group=${key}` +
        ` business=${getBusinessTypeForTaskGroup(group)}` +
        ` lane=${group.laneType}` +
        ` submitted=${group.submittedTasks}` +
        ` completed=${group.completedTasks}` +
        ` failed=${group.failedTasks}` +
        ` avgWaitMs=${roundMetric(group.averageWaitTime)}` +
        ` avgCostMs=${roundMetric(group.averageCostTime)}` +
        ` maxWaitMs=${group.maxWaitTime}` +
        ` maxCostMs=${group.maxCostTime}` +
        ` bottleneck=${classifyWaitOrCost(group.averageWaitTime, group.averageCostTime)}`
    );
  }
}

function submitBusinessProbe(
  eventType: string,
  laneType: SDKTaskType,
  serialKey: string | undefined,
  metrics: BusinessEventProbeMetric[],
  tasks: Promise<void>[]
): void {
  const scheduler = SDKTaskScheduler.getInstance();
  const createdAt = Date.now();
  const probeIndex = tasks.length;

  tasks.push(scheduler.submitTaskAndWait({
    type: laneType,
    name: `business-probe-${eventType}-${probeIndex}`,
    priority: SDKTaskPriority.HIGH,
    serialKey,
    silent: true,
    run: async () => {
      const laneStartAt = Date.now();
      if (laneType === SDKTaskType.DATA_PROCESS) {
        metrics.push({
          eventType,
          laneType,
          laneQueueMs: laneStartAt - createdAt,
          dataProcessQueueMs: 0,
          totalMs: laneStartAt - createdAt
        });
        return;
      }

      await scheduler.submitTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: `business-probe-data-${eventType}-${probeIndex}`,
        priority: SDKTaskPriority.LOW,
        silent: true,
        run: () => {
          const dataStartAt = Date.now();
          metrics.push({
            eventType,
            laneType,
            laneQueueMs: laneStartAt - createdAt,
            dataProcessQueueMs: dataStartAt - laneStartAt,
            totalMs: dataStartAt - createdAt
          });
        }
      });
    }
  }));
}

function collectBusinessProbeLatencies(metrics: BusinessEventProbeMetric[]): number[] {
  const latencies: number[] = [];
  for (const metric of metrics) {
    latencies.push(metric.totalMs);
  }
  return latencies;
}

function countBusinessProbeMetrics(eventType: string, metrics: BusinessEventProbeMetric[]): number {
  let count = 0;
  for (const metric of metrics) {
    if (metric.eventType === eventType) {
      count++;
    }
  }
  return count;
}

function printBusinessEventBreakdown(caseName: string, metrics: BusinessEventProbeMetric[]): void {
  for (const eventType of BUSINESS_EVENT_TYPES) {
    const laneQueueValues: number[] = [];
    const dataProcessQueueValues: number[] = [];
    const totalValues: number[] = [];
    let laneType = '';

    for (const metric of metrics) {
      if (metric.eventType !== eventType) {
        continue;
      }
      laneType = metric.laneType;
      laneQueueValues.push(metric.laneQueueMs);
      dataProcessQueueValues.push(metric.dataProcessQueueMs);
      totalValues.push(metric.totalMs);
    }

    if (totalValues.length === 0) {
      continue;
    }

    const avgLaneQueueMs = average(laneQueueValues);
    const avgDataProcessQueueMs = average(dataProcessQueueValues);
    console.info(
      TAG,
      `case=${caseName}` +
        ` breakdown=business-event` +
        ` event=${eventType}` +
        ` samples=${totalValues.length}` +
        ` upstreamLane=${laneType}` +
        ` avgLaneQueueMs=${roundMetric(avgLaneQueueMs)}` +
        ` avgDataProcessQueueMs=${roundMetric(avgDataProcessQueueMs)}` +
        ` avgTotalMs=${roundMetric(average(totalValues))}` +
        ` p50TotalMs=${roundMetric(percentile(totalValues, 0.50))}` +
        ` p95TotalMs=${roundMetric(percentile(totalValues, 0.95))}` +
        ` p99TotalMs=${roundMetric(percentile(totalValues, 0.99))}` +
        ` bottleneck=${classifyBusinessQueue(avgLaneQueueMs, avgDataProcessQueueMs)}`
    );
  }
}

function captureLogQueueStatus(): QueueStatusSnapshot {
  const status = TrackLogManager.getInstance().getQueueStatus();
  return {
    queueSize: status.queueSize,
    bufferSize: status.bufferSize,
    isProcessing: status.isProcessing,
    submittedCount: status.submittedCount,
    acceptedCount: status.acceptedCount,
    droppedCount: status.droppedCount,
    filteredCount: status.filteredCount
  };
}

function getLogEntryQueueLimit(): number {
  const configuredLimit = FTDBCachePolicy.getInstance().getLogLimitCount();
  if (configuredLimit <= 0) {
    return Constants.MAX_QUEUE_SIZE_LOG;
  }
  return Math.min(configuredLimit, Constants.MAX_QUEUE_SIZE_LOG);
}

function printLogDropBreakdown(
  caseName: string,
  submitted: number,
  acceptedAtEntry: number,
  afterSubmit: QueueStatusSnapshot,
  afterDrain: QueueStatusSnapshot
): void {
  const entryDropped = Math.max(0, submitted - acceptedAtEntry);
  const consumerBacklog = afterDrain.queueSize + afterDrain.bufferSize;
  const consumerFailedTasks = getLaneStatus(SDKTaskType.LOG).failedTasks + getLaneStatus(SDKTaskType.DATA_PROCESS).failedTasks;
  let rootCause = 'none';
  if (entryDropped > 0 && (consumerBacklog > 0 || consumerFailedTasks > 0)) {
    rootCause = 'entry-pressure+consumer-chain';
  } else if (entryDropped > 0) {
    rootCause = 'entry-pressure';
  } else if (consumerBacklog > 0 || consumerFailedTasks > 0) {
    rootCause = 'consumer-chain';
  }

  console.info(
    TAG,
    `case=${caseName}` +
      ` breakdown=log-drop` +
      ` submitted=${submitted}` +
      ` entryLimit=${getLogEntryQueueLimit()}` +
      ` acceptedAtEntry=${acceptedAtEntry}` +
      ` entryDropped=${entryDropped}` +
      ` entrySubmittedCount=${afterSubmit.submittedCount}` +
      ` entryAcceptedCount=${afterSubmit.acceptedCount}` +
      ` entryDroppedCount=${afterSubmit.droppedCount}` +
      ` entryFilteredCount=${afterSubmit.filteredCount}` +
      ` queueAfterSubmit=${afterSubmit.queueSize}` +
      ` bufferAfterSubmit=${afterSubmit.bufferSize}` +
      ` processingAfterSubmit=${afterSubmit.isProcessing}` +
      ` queueAfterDrain=${afterDrain.queueSize}` +
      ` bufferAfterDrain=${afterDrain.bufferSize}` +
      ` processingAfterDrain=${afterDrain.isProcessing}` +
      ` consumerBacklog=${consumerBacklog}` +
      ` consumerFailedTasks=${consumerFailedTasks}` +
      ` rootCause=${rootCause}`
  );
}

function getPureDispatchSerialKey(type: SDKTaskType): string | undefined {
  if (type === SDKTaskType.EVENT) {
    return RUM_EVENT_SERIAL_KEY;
  }
  if (type === SDKTaskType.LOG) {
    return 'pure-log-dispatch-state';
  }
  return undefined;
}

function getPureDispatchPriority(index: number): SDKTaskPriority {
  switch (index % 5) {
    case 0:
      return SDKTaskPriority.CRITICAL;
    case 1:
      return SDKTaskPriority.HIGH;
    case 2:
      return SDKTaskPriority.NORMAL;
    case 3:
      return SDKTaskPriority.LOW;
    default:
      return SDKTaskPriority.BACKGROUND;
  }
}

function configureLogPipeline(): void {
  const sdkConfig = FTSDKConfig.builder(TEST_URL)
    .setAutoSync(false);
  FTDBCachePolicy.getInstance().initSDKParams(new CapabilityConfigRecord(sdkConfig));

  const logConfig = new FTLoggerConfig()
    .setEnableCustomLog(true)
    .setEnableLinkRumData(false)
    .setSamplingRate(1.0)
    .setPrintCustomLogToConsole(false)
    .setLogCacheLimitCount(Constants.MAX_QUEUE_SIZE_LOG);
  logConfig.setServiceName('thread_pool_capability_test');
  FTDBCachePolicy.getInstance().updateLogCacheLimitCount(logConfig.getLogCacheLimitCount());
  FTDBCachePolicy.getInstance().updateLogCacheDiscardStrategy(logConfig.getLogCacheDiscardStrategy());

  FTTrackInner.getInstance().initLogConfig(logConfig);
}

function configureMixedConsumerPipeline(): void {
  configureLogPipeline();

  const rumConfig = new FTRUMConfig()
    .setRumAppId('thread_pool_capability_rum')
    .setSamplingRate(1.0)
    .setSessionErrorSampleRate(1.0);

  FTRUMConfigManager.getInstance().initWithConfig(rumConfig);
  FTRUMInnerManager.getInstance().initParams(rumConfig);
  FTRUMGlobalManager.getInstance().initConfig(rumConfig);
  FTTrackInner.getInstance().initRUMConfig(rumConfig);
}

function createResourceParams(index: number): ResourceParams {
  const params = new ResourceParams();
  params.setUrl(`${TEST_URL}/thread-pool/resource/${index}?page=${index % 7}`);
  params.setResourceMethod(index % 2 === 0 ? 'GET' : 'POST');
  params.setResourceStatus(index % 10 === 0 ? 500 : 200);
  params.setRequestHeader('x-sdk-capability: mixed');
  params.setResponseHeader('content-type: application/json');
  params.setResponseContentType('application/json');
  params.setResponseContentLength(256 + index);
  params.setResponseBody(`{"index":${index}}`);
  return params;
}

function createNetStatusBean(index: number): NetStatusBean {
  const netStatusBean = new NetStatusBean();
  netStatusBean.setDNSTime(1000 + index);
  netStatusBean.setTcpTime(2000 + index);
  netStatusBean.setSSLTime(3000 + index);
  netStatusBean.setTTFB(4000 + index);
  netStatusBean.setFirstByteTime(5000 + index);
  netStatusBean.setDownloadTime(6000 + index);
  netStatusBean.setResponseTime(7000 + index);
  netStatusBean.setHoleRequestTime(28000 + index);
  netStatusBean.setResourceHostIP('127.0.0.1');
  return netStatusBean;
}

function submitGeneratedViewPayload(index: number): void {
  const tags = new Map<string, string>();
  tags.set(Constants.KEY_RUM_VIEW_ID, `mixed-view-id-${index}`);
  tags.set(Constants.KEY_RUM_VIEW_NAME, `mixed-view-${index}`);
  tags.set(Constants.KEY_RUM_VIEW_REFERRER, index === 0 ? Constants.VIEW_NAME_ROOT : `mixed-view-${index - MIXED_VIEW_INTERVAL}`);

  const fields = new Map<string, string>();
  fields.set(Constants.KEY_RUM_VIEW_DURATION, String(1000000 + index));
  fields.set(Constants.KEY_RUM_VIEW_LOAD_TIME, String(10000 + index));
  fields.set(Constants.KEY_RUM_VIEW_ACTION_COUNT, String(MIXED_VIEW_INTERVAL));
  fields.set(Constants.KEY_RUM_VIEW_RESOURCE_COUNT, String(MIXED_VIEW_INTERVAL));
  fields.set(Constants.KEY_RUM_VIEW_LONG_TASK_COUNT, String(MIXED_VIEW_INTERVAL));
  fields.set(Constants.KEY_RUM_VIEW_ERROR_COUNT, String(Math.ceil(MIXED_VIEW_INTERVAL / 2)));

  FTTrackInner.getInstance().rum(
    Date.now() * 1000000,
    Constants.FT_MEASUREMENT_RUM_VIEW,
    tags,
    fields,
    null
  );
}

async function submitMixedRumCycle(index: number): Promise<void> {
  const rumManager = FTRUMGlobalManager.getInstance();

  if (index % MIXED_VIEW_INTERVAL === 0) {
    const viewName = `mixed-view-${index}`;
    rumManager.onCreateView(viewName, 1000000 + index);
    await rumManager.startView(viewName);
    submitGeneratedViewPayload(index);
  }

  rumManager.addAction(`mixed-action-${index}`, Constants.EVENT_NAME_CLICK);

  const resourceId = `mixed-resource-${index}`;
  rumManager.startResource(resourceId);
  rumManager.addResource(resourceId, createResourceParams(index), createNetStatusBean(index));
  rumManager.stopResource(resourceId);

  rumManager.addLongTask(`mixed-longtask-stack-${index}`, 50000000 + index);

  rumManager.addError(
    `Error: mixed stack ${index}`,
    `mixed error ${index}`,
    ErrorType.CUSTOM,
    AppState.RUN
  );
}

function buildMixedWorkloadStats(logAccepted: number): MixedWorkloadStats {
  const viewSubmitted = Math.ceil(MIXED_RUM_CYCLE_COUNT / MIXED_VIEW_INTERVAL);
  const rumSubmitted = viewSubmitted + MIXED_RUM_CYCLE_COUNT * 4;
  return {
    logSubmitted: MIXED_LOG_SUBMIT_COUNT,
    logAccepted,
    rumSubmitted,
    viewSubmitted,
    totalSubmitted: MIXED_LOG_SUBMIT_COUNT + rumSubmitted,
    totalAccepted: logAccepted + rumSubmitted
  };
}

export default function sdkThreadPoolCapabilityUnitTest() {
  describe('SDKThreadPoolCapabilityUnit', () => {
    beforeEach(() => {
      FTInnerLogger.setDebugEnabled(false);
      SDKTaskScheduler.resetInternal();
      TrackLogManager.resetStateInternal();
      FTRUMGlobalManager.resetStateInternal();
      FTRUMConfigManager.getInstance().release();
      FTTrackInner.resetInstanceInternal();
      SDKDedicatedPoolManager.setWorkerCommandTimeoutMsInternal(1);
      TestReset.resetP0State();
    });

    afterEach(async () => {
      TrackLogManager.resetStateInternal();
      FTRUMGlobalManager.resetStateInternal();
      FTRUMConfigManager.getInstance().release();
      FTTrackInner.resetInstanceInternal();
      SDKTaskScheduler.resetInternal();
      SDKDedicatedPoolManager.resetWorkerCommandTimeoutMsInternal();
      TestReset.resetP0State();
      await CpuUtils.getInstance().release();
      await MemoryUtils.getInstance().release();
      FTInnerLogger.setDebugEnabled(true);
    });

    it('pureMixedLaneDispatchShouldExposeSchedulerQpsAndLatency', 0, async () => {
      const scheduler = SDKTaskScheduler.getInstance();
      const beforeResources = await captureResourceSnapshot();
      const latencies: number[] = [];
      const tasks: Promise<void>[] = [];
      const submitStart = Date.now();
      for (let i = 0; i < PURE_MIXED_DISPATCH_TASK_COUNT; i++) {
        const type = PURE_MIXED_LANE_TYPES[i % PURE_MIXED_LANE_TYPES.length];
        const createdAt = Date.now();
        tasks.push(scheduler.submitTaskAndWait({
          type,
          name: `pure-mixed-${type}-${i}`,
          priority: getPureDispatchPriority(i),
          serialKey: getPureDispatchSerialKey(type),
          silent: true,
          run: () => {
            latencies.push(Date.now() - createdAt);
          }
        }));
      }
      const submitMs = Math.max(1, Date.now() - submitStart);
      const expectedSubmitted = PURE_MIXED_DISPATCH_TASK_COUNT;

      await Promise.all(tasks);
      const idle = await waitForSchedulerIdle(PURE_MIXED_LANE_TYPES, 10000);
      const totalMs = Math.max(1, Date.now() - submitStart);
      const afterResources = await captureResourceSnapshot();
      const aggregateStatus = aggregateLaneStatuses(PURE_MIXED_LANE_TYPES);

      const report = buildReport(
        'pure-mixed-lane-dispatch',
        expectedSubmitted,
        expectedSubmitted,
        latencies.length,
        aggregateStatus.failedTasks,
        submitMs,
        totalMs,
        latencies,
        aggregateStatus,
        beforeResources,
        afterResources,
        formatLaneSummary(PURE_MIXED_LANE_TYPES)
      );
      printReport(report);
      printQueueCostSummaries('pure-mixed-lane-dispatch', PURE_MIXED_LANE_TYPES);
      pureDispatchBaselineReport = report;

      expect(idle).assertTrue();
      expect(latencies.length).assertEqual(expectedSubmitted);
      expect(aggregateStatus.pending).assertEqual(0);
      expect(aggregateStatus.running).assertEqual(0);
      expect(aggregateStatus.failedTasks).assertEqual(0);
    });

    it('realMixedConsumerShouldExposeSchedulerWithAlignedInput', 0, async () => {
      configureMixedConsumerPipeline();

      const beforeResources = await captureResourceSnapshot();
      const submitStart = Date.now();

      for (let i = 0; i < MIXED_LOG_SUBMIT_COUNT; i++) {
        FTLogger.logBackground(
          `thread-pool-capability-mixed-log-${i}`,
          Status.INFO,
          undefined,
          true
        );

        if (i < MIXED_RUM_CYCLE_COUNT) {
          await submitMixedRumCycle(i);
        }
      }

      const submitMs = Math.max(1, Date.now() - submitStart);
      const logQueueAfterSubmit = captureLogQueueStatus();
      const queuedLogsAfterSubmit = logQueueAfterSubmit.queueSize;
      const logAccepted = Math.max(0, MIXED_LOG_SUBMIT_COUNT - logQueueAfterSubmit.droppedCount);
      const workloadStats = buildMixedWorkloadStats(logAccepted);

      await flushPromises(120);
      const idle = await waitForSchedulerIdle(MIXED_LANE_TYPES, 60000);
      const totalMs = Math.max(1, Date.now() - submitStart);
      const logQueueAfterDrain = captureLogQueueStatus();
      const afterResources = await captureResourceSnapshot();

      const aggregateStatus = aggregateLaneStatuses(MIXED_LANE_TYPES);
      const report = buildReport(
        'real-mixed-consumer',
        workloadStats.totalSubmitted,
        workloadStats.totalAccepted,
        workloadStats.totalAccepted,
        aggregateStatus.failedTasks,
        submitMs,
        totalMs,
        [],
        aggregateStatus,
        beforeResources,
        afterResources,
        formatLaneSummary(MIXED_LANE_TYPES)
      );
      printReport(report);
      printBusinessInputSummary('real-mixed-consumer', workloadStats);
      printQueueCostSummaries('real-mixed-consumer', MIXED_LANE_TYPES);
      printLogDropBreakdown(
        'real-mixed-consumer',
        MIXED_LOG_SUBMIT_COUNT,
        logAccepted,
        logQueueAfterSubmit,
        logQueueAfterDrain
      );
      if (pureDispatchBaselineReport !== null) {
        printCapacityGap(pureDispatchBaselineReport, report);
      }

      expect(idle).assertTrue();
      expect(queuedLogsAfterSubmit <= getLogEntryQueueLimit()).assertTrue();
      expect(workloadStats.logAccepted).assertEqual(logAccepted);
      expect(report.dropped).assertEqual(MIXED_LOG_SUBMIT_COUNT - logAccepted);
      expect(getLaneStatus(SDKTaskType.EVENT).failedTasks).assertEqual(0);
      expect(getLaneStatus(SDKTaskType.LOG).failedTasks).assertEqual(0);
      expect(getLaneStatus(SDKTaskType.DATA_PROCESS).failedTasks).assertEqual(0);
      expect(aggregateStatus.pending).assertEqual(0);
      expect(aggregateStatus.running).assertEqual(0);
    });
  });
}
