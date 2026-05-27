/**
 * Thread pool benchmark-style tests.
 *
 * These tests provide a repeatable baseline for comparing thread pool changes.
 * They assert correctness only and print performance metrics for before/after
 * comparison on the same device and build configuration.
 */

import { describe, beforeAll, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import hilog from '@ohos.hilog';
import { DataProcessThreadPool } from '../main/ets/components/thread/DataProcessThreadPool';
import { DataUploadThreadPool } from '../main/ets/components/thread/DataUploadThreadPool';
import { ThreadPoolManager } from '../main/ets/components/thread/ThreadPoolManager';
import { UnifiedConsumerThreadPool } from '../main/ets/components/thread/UnifiedConsumerThreadPool';

const TAG = 'ThreadPoolBenchmarkTest';
const DOMAIN = 0x0000;
const DATA_PROCESS_TASK_COUNT = 1000;
const UPLOAD_QUEUE_TASK_COUNT = 9;
const POLL_INTERVAL_MS = 20;
const DATA_PROCESS_TIMEOUT_MS = 8000;
const UPLOAD_QUEUE_TIMEOUT_MS = 8000;

interface SmartQueueSizesRecord {
  highPriority: number;
  normalPriority: number;
  lowPriority: number;
}

interface SmartPoolStatusRecord {
  corePoolSize: number;
  currentPoolSize: number;
  maxPoolSize: number;
  activeThreads: number;
  totalTasks: number;
  completedTasks: number;
  failedTasks: number;
  averageTaskTime: number;
  queueSizes: SmartQueueSizesRecord;
}

interface ThreadPoolSnapshot {
  totalTasks: number;
  completedTasks: number;
  failedTasks: number;
  activeThreads: number;
  currentPoolSize: number;
  maxQueueDepth: number;
  averageTaskTime: number;
}

interface BenchmarkMetrics {
  scenario: string;
  taskCount: number;
  completed: number;
  elapsedMs: number;
  throughputPerSecond: number;
  p50WaitMs: number;
  p95WaitMs: number;
  p99WaitMs: number;
  maxWaitMs: number;
  averageExecutionMs: number;
  maxQueueDepth: number;
  submittedDelta: number;
  completedDelta: number;
  failedDelta: number;
  poolAverageTaskTime: number;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>(resolve => setTimeout(resolve, ms));
}

async function resetThreadPoolForBenchmark(): Promise<void> {
  ThreadPoolManager.getInstance().reset();
  DataUploadThreadPool.getInstance().clearUploadQueue();
  await delay(120);
}

function readThreadPoolSnapshot(): ThreadPoolSnapshot {
  const smartStatus = UnifiedConsumerThreadPool.getInstance().getStatus().smartPoolStatus as SmartPoolStatusRecord;
  const maxQueueDepth = smartStatus.queueSizes.highPriority +
    smartStatus.queueSizes.normalPriority +
    smartStatus.queueSizes.lowPriority;

  return {
    totalTasks: smartStatus.totalTasks,
    completedTasks: smartStatus.completedTasks,
    failedTasks: smartStatus.failedTasks,
    activeThreads: smartStatus.activeThreads,
    currentPoolSize: smartStatus.currentPoolSize,
    maxQueueDepth,
    averageTaskTime: smartStatus.averageTaskTime
  };
}

function percentile(values: number[], percentileValue: number): number {
  if (values.length === 0) {
    return 0;
  }

  const sorted = values.slice().sort((left, right) => left - right);
  const index = Math.min(sorted.length - 1, Math.floor((percentileValue / 100) * (sorted.length - 1)));
  return sorted[index];
}

function average(values: number[]): number {
  if (values.length === 0) {
    return 0;
  }

  let total = 0;
  for (let i = 0; i < values.length; i++) {
    total += values[i];
  }
  return total / values.length;
}

async function waitUntil(predicate: () => boolean, timeoutMs: number, onPoll?: () => void): Promise<boolean> {
  const startTime = Date.now();
  while (Date.now() - startTime <= timeoutMs) {
    if (onPoll) {
      onPoll();
    }
    if (predicate()) {
      return true;
    }
    await delay(POLL_INTERVAL_MS);
  }
  return predicate();
}

function createMetrics(
  scenario: string,
  taskCount: number,
  completed: number,
  elapsedMs: number,
  enqueueTimes: number[],
  startTimes: number[],
  endTimes: number[],
  before: ThreadPoolSnapshot,
  after: ThreadPoolSnapshot,
  sampledMaxQueueDepth: number
): BenchmarkMetrics {
  const waits: number[] = [];
  const executions: number[] = [];

  for (let i = 0; i < taskCount; i++) {
    if (startTimes[i] > 0 && enqueueTimes[i] > 0) {
      waits.push(Math.max(0, startTimes[i] - enqueueTimes[i]));
    }
    if (endTimes[i] > 0 && startTimes[i] > 0) {
      executions.push(Math.max(0, endTimes[i] - startTimes[i]));
    }
  }

  return {
    scenario,
    taskCount,
    completed,
    elapsedMs,
    throughputPerSecond: elapsedMs > 0 ? (completed * 1000) / elapsedMs : 0,
    p50WaitMs: percentile(waits, 50),
    p95WaitMs: percentile(waits, 95),
    p99WaitMs: percentile(waits, 99),
    maxWaitMs: waits.length > 0 ? Math.max(...waits) : 0,
    averageExecutionMs: average(executions),
    maxQueueDepth: Math.max(sampledMaxQueueDepth, after.maxQueueDepth),
    submittedDelta: after.totalTasks - before.totalTasks,
    completedDelta: after.completedTasks - before.completedTasks,
    failedDelta: after.failedTasks - before.failedTasks,
    poolAverageTaskTime: after.averageTaskTime
  };
}

function logMetrics(metrics: BenchmarkMetrics): void {
  const message = `${TAG} metrics=${JSON.stringify(metrics)}`;
  console.info(TAG, message);
  hilog.info(DOMAIN, TAG, '%{public}s', message);
}

export default function threadPoolBenchmarkTest() {
  describe('ThreadPoolBenchmarkTest', () => {
    beforeAll(async () => {
      console.info(TAG, 'beforeAll called');
      hilog.info(DOMAIN, TAG, '%{public}s', 'beforeAll called');
      await ThreadPoolManager.getInstance().initialize();
    });

    beforeEach(async () => {
      await resetThreadPoolForBenchmark();
    });

    afterEach(async () => {
      await resetThreadPoolForBenchmark();
    });

    it('dataProcessPoolShouldReportCurrentBaselineMetrics', 0, async () => {
      const pool = DataProcessThreadPool.getInstance();
      const enqueueTimes: number[] = [];
      const startTimes: number[] = [];
      const endTimes: number[] = [];
      let completed = 0;
      let guard = 0;
      let maxQueueDepth = 0;

      for (let i = 0; i < DATA_PROCESS_TASK_COUNT; i++) {
        enqueueTimes.push(0);
        startTimes.push(0);
        endTimes.push(0);
      }

      const before = readThreadPoolSnapshot();
      const benchmarkStart = Date.now();

      for (let i = 0; i < DATA_PROCESS_TASK_COUNT; i++) {
        enqueueTimes[i] = Date.now();
        pool.execute(() => {
          startTimes[i] = Date.now();
          for (let j = 0; j < 20; j++) {
            guard += i + j;
          }
          endTimes[i] = Date.now();
          completed++;
        });
      }

      maxQueueDepth = readThreadPoolSnapshot().maxQueueDepth;
      const drained = await waitUntil(() => completed === DATA_PROCESS_TASK_COUNT, DATA_PROCESS_TIMEOUT_MS, () => {
        maxQueueDepth = Math.max(maxQueueDepth, readThreadPoolSnapshot().maxQueueDepth);
      });
      const elapsedMs = Date.now() - benchmarkStart;
      const after = readThreadPoolSnapshot();
      const metrics = createMetrics(
        'data_process_low_priority',
        DATA_PROCESS_TASK_COUNT,
        completed,
        elapsedMs,
        enqueueTimes,
        startTimes,
        endTimes,
        before,
        after,
        maxQueueDepth
      );

      logMetrics(metrics);
      expect(drained).assertTrue();
      expect(completed).assertEqual(DATA_PROCESS_TASK_COUNT);
      expect(metrics.failedDelta).assertEqual(0);
      expect(guard > 0).assertTrue();
    });

    it('uploadQueueShouldReportCurrentDrainMetrics', 0, async () => {
      const uploadPool = DataUploadThreadPool.getInstance();
      const enqueueTimes: number[] = [];
      const startTimes: number[] = [];
      const endTimes: number[] = [];
      let completed = 0;
      let maxQueueDepth = 0;

      for (let i = 0; i < UPLOAD_QUEUE_TASK_COUNT; i++) {
        enqueueTimes.push(0);
        startTimes.push(0);
        endTimes.push(0);
      }

      const before = readThreadPoolSnapshot();
      const benchmarkStart = Date.now();

      for (let i = 0; i < UPLOAD_QUEUE_TASK_COUNT; i++) {
        enqueueTimes[i] = Date.now();
        uploadPool.addUploadTaskToQueue(() => {
          startTimes[i] = Date.now();
          endTimes[i] = Date.now();
          completed++;
        });
      }

      maxQueueDepth = uploadPool.getUploadQueueStatus().queueSize;
      const drained = await waitUntil(() => {
        const status = uploadPool.getUploadQueueStatus();
        return completed === UPLOAD_QUEUE_TASK_COUNT && status.queueSize === 0 && !status.isProcessing;
      }, UPLOAD_QUEUE_TIMEOUT_MS, () => {
        maxQueueDepth = Math.max(maxQueueDepth, uploadPool.getUploadQueueStatus().queueSize);
      });
      const elapsedMs = Date.now() - benchmarkStart;
      const after = readThreadPoolSnapshot();
      const metrics = createMetrics(
        'upload_queue_drain',
        UPLOAD_QUEUE_TASK_COUNT,
        completed,
        elapsedMs,
        enqueueTimes,
        startTimes,
        endTimes,
        before,
        after,
        maxQueueDepth
      );

      logMetrics(metrics);
      expect(drained).assertTrue();
      expect(completed).assertEqual(UPLOAD_QUEUE_TASK_COUNT);
      expect(uploadPool.getUploadQueueStatus().queueSize).assertEqual(0);
      expect(metrics.failedDelta).assertEqual(0);
    });
  });
}
