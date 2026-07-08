/**
 * Internal SDK task scheduler.
 *
 * Provides one submit entry while keeping execution isolated by task lane.
 */
import { FTInnerLogger } from '../log/FTLogger';
import {
  SDKDedicatedCommandRunner,
  SDKDedicatedPoolManager,
  SDKDedicatedPoolManagerStatus,
  SDKDedicatedPoolStatus,
  SDKWorkerBridgeHandler
} from './SDKDedicatedPoolManager';
import { SDKDedicatedPoolType, SDKWorkerRequest, SDKWorkerResponse, SDKWorkerTiming } from './SDKWorkerProtocol';

const TAG = "SDKTaskScheduler";
const EVENT_WORKER_POOL_TRACE_PREFIX = "<FT-EVENT-WORKER-POOL>";
const SCHEDULER_TRACE_PREFIX = "<FT-SDK-SCHEDULER>";
const SCHEDULER_WORKER_POOL_TRACE_INTERVAL_MS = 5000;
const EVENT_WORKER_POOL_TRACE_INTERVAL_MS = 2000;
const QUEUE_COMPACT_THRESHOLD = 64;

export enum SDKTaskType {
  EVENT = 'event',
  LOG = 'log',
  INNER_LOG_FILE = 'inner-log-file',
  DATA_PROCESS = 'data-process',
  CRASH_FILE = 'crash-file',
  UPLOAD = 'upload',
  ANR = 'anr',
  CUSTOM = 'custom'
}

export enum SDKTaskPriority {
  CRITICAL = 9,
  HIGH = 7,
  NORMAL = 5,
  LOW = 3,
  BACKGROUND = 1
}

export type SDKTaskCostHint = 'light' | 'normal' | 'heavy';
export type SDKTaskRunner = () => void | Promise<void>;
export type SDKTaskWorkerResponseHandler = (response: SDKWorkerResponse) => void | Promise<void>;

interface SDKTaskBaseOptions {
  type: SDKTaskType;
  name: string;
  priority?: SDKTaskPriority;
  retryCount?: number;
  serialKey?: string;
  singleFlightKey?: string;
  costHint?: SDKTaskCostHint;
  silent?: boolean;
}

interface SDKTaskRuntimeBase {
  type: SDKTaskType;
  name: string;
  priority: SDKTaskPriority;
  createdAt: number;
  retryCount: number;
  serialKey?: string;
  singleFlightKey?: string;
  costHint?: SDKTaskCostHint;
  silent?: boolean;
}

export interface SDKTask extends SDKTaskRuntimeBase {
  workerRequest: SDKWorkerRequest;
  workerFallbackRunner?: SDKDedicatedCommandRunner;
  workerBridgeHandler?: SDKWorkerBridgeHandler;
  workerResponseHandler?: SDKTaskWorkerResponseHandler;
}

export interface SDKTaskOptions extends SDKTaskBaseOptions {
  workerRequest: SDKWorkerRequest;
  workerFallbackRunner?: SDKDedicatedCommandRunner;
  workerBridgeHandler?: SDKWorkerBridgeHandler;
  workerResponseHandler?: SDKTaskWorkerResponseHandler;
}

export interface SDKRunnableTaskOptions extends SDKTaskBaseOptions {
  workerRequest?: SDKWorkerRequest;
  workerFallbackRunner?: SDKDedicatedCommandRunner;
  workerBridgeHandler?: SDKWorkerBridgeHandler;
  workerResponseHandler?: SDKTaskWorkerResponseHandler;
  run: SDKTaskRunner;
}

interface SDKRunnableTask extends SDKTaskRuntimeBase {
  workerRequest?: SDKWorkerRequest;
  workerFallbackRunner?: SDKDedicatedCommandRunner;
  workerBridgeHandler?: SDKWorkerBridgeHandler;
  workerResponseHandler?: SDKTaskWorkerResponseHandler;
  run: SDKTaskRunner;
}

export interface SDKLaneStatus {
  pending: number;
  running: number;
  maxConcurrency: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  dispatchCount: number;
  totalWaitTime: number;
  totalCostTime: number;
  averageWaitTime: number;
  averageCostTime: number;
  averageDispatchTime: number;
  maxDispatchTime: number;
  lastDispatchTime: number;
  averageScanCount: number;
  maxScanCount: number;
  lastScanCount: number;
  oldestWait: number;
  lastError: string | null;
  missingWorkerRequestTasks: number;
  lastMissingWorkerRequestTaskName: string | null;
  runnableFallbackTasks: number;
  lastRunnableFallbackTaskName: string | null;
}

export interface SDKTaskSchedulerStatus {
  isShutdown: boolean;
  activeSingleFlightTasks: number;
  rescheduledSingleFlightTasks: number;
  lanes: Record<string, SDKLaneStatus>;
  taskGroups: Record<string, SDKTaskGroupStatus>;
  dedicatedPools: SDKDedicatedPoolManagerStatus;
}

export interface SDKTaskGroupStatus {
  laneType: string;
  groupName: string;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  averageWaitTime: number;
  averageCostTime: number;
  maxWaitTime: number;
  maxCostTime: number;
  lastTaskName: string;
}

interface ScheduledSDKTask extends SDKTaskRuntimeBase {
  id: string;
  workerRequest?: SDKWorkerRequest;
  workerFallbackRunner?: SDKDedicatedCommandRunner;
  workerBridgeHandler?: SDKWorkerBridgeHandler;
  workerResponseHandler?: SDKTaskWorkerResponseHandler;
  run?: SDKTaskRunner;
  allowRunnableFallback: boolean;
  resolve?: () => void;
  reject?: (error: Error) => void;
}

interface SDKLaneState {
  queue: ScheduledSDKTask[];
  queueHeadIndex: number;
  pendingCount: number;
  pendingFifoPriority: SDKTaskPriority | null;
  pendingFifoSerialKey: string | null;
  pendingFifoHomogeneous: boolean;
  running: number;
  maxConcurrency: number;
  runningSerialKeys: Set<string>;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  dispatchCount: number;
  totalWaitTime: number;
  totalCostTime: number;
  lastWaitTime: number;
  lastCostTime: number;
  totalDispatchTime: number;
  maxDispatchTime: number;
  lastDispatchTime: number;
  totalScanCount: number;
  maxScanCount: number;
  lastScanCount: number;
  lastError: string | null;
  missingWorkerRequestTasks: number;
  lastMissingWorkerRequestTaskName: string | null;
  runnableFallbackTasks: number;
  lastRunnableFallbackTaskName: string | null;
}

interface SDKTaskSelection {
  task: ScheduledSDKTask | null;
  scanCount: number;
}

interface SDKTaskGroupState {
  laneType: string;
  groupName: string;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  maxWaitTime: number;
  maxCostTime: number;
  lastTaskName: string;
}

export class SDKTaskScheduler {
  private static instance: SDKTaskScheduler | null = null;
  private lanes: Map<SDKTaskType, SDKLaneState> = new Map();
  private taskGroups: Map<string, SDKTaskGroupState> = new Map();
  private activeSingleFlightKeys: Set<string> = new Set();
  private rescheduledSingleFlightTasks: Map<string, ScheduledSDKTask> = new Map();
  private nextTaskId: number = 0;
  private isShutdown: boolean = false;
  private lastEventCompletedName: string = '';
  private lastEventCompletedAt: number = 0;
  private lastLaneTraceAt: Map<SDKTaskType, number> = new Map();
  private skippedLaneTraceCount: Map<SDKTaskType, number> = new Map();
  private lastLaneIdleProcessedCount: Map<SDKTaskType, number> = new Map();
  private lastEventTraceAt: number = 0;
  private skippedEventTraceCount: number = 0;

  private constructor() {
    this.initializeDefaultLanes();
  }

  public static getInstance(): SDKTaskScheduler {
    if (!SDKTaskScheduler.instance) {
      SDKTaskScheduler.instance = new SDKTaskScheduler();
    }
    return SDKTaskScheduler.instance;
  }

  public static resetInternal(): void {
    if (SDKTaskScheduler.instance) {
      SDKTaskScheduler.instance.shutdownNow();
    }
    SDKTaskScheduler.instance = null;
  }

  public createTask(options: SDKTaskOptions): SDKTask {
    return {
      type: options.type,
      name: options.name,
      priority: options.priority ?? this.getDefaultPriority(options.type),
      createdAt: Date.now(),
      retryCount: options.retryCount ?? 0,
      serialKey: options.serialKey,
      singleFlightKey: options.singleFlightKey,
      costHint: options.costHint,
      silent: options.silent ?? false,
      workerRequest: options.workerRequest,
      workerFallbackRunner: options.workerFallbackRunner,
      workerBridgeHandler: options.workerBridgeHandler,
      workerResponseHandler: options.workerResponseHandler
    };
  }

  public submitTask(options: SDKTaskOptions): string {
    return this.submit(this.createTask(options));
  }

  public submit(task: SDKTask): string {
    this.checkNotShutdown();
    const scheduledTask = this.toScheduledTask(task, false);
    this.enqueueTask(scheduledTask);
    return scheduledTask.id;
  }

  public submitTaskAndWait(options: SDKTaskOptions): Promise<void> {
    return this.submitAndWait(this.createTask(options));
  }

  public submitAndWait(task: SDKTask): Promise<void> {
    this.checkNotShutdown();
    return new Promise<void>((resolve, reject) => {
      const scheduledTask = this.toScheduledTask(task, false, resolve, reject);
      this.enqueueTask(scheduledTask);
    });
  }

  public submitRunnableTask(options: SDKRunnableTaskOptions): string {
    this.checkNotShutdown();
    const scheduledTask = this.toScheduledTask(this.createRunnableTask(options), true);
    this.enqueueTask(scheduledTask);
    return scheduledTask.id;
  }

  public submitRunnableTaskAndWait(options: SDKRunnableTaskOptions): Promise<void> {
    this.checkNotShutdown();
    return new Promise<void>((resolve, reject) => {
      const scheduledTask = this.toScheduledTask(this.createRunnableTask(options), true, resolve, reject);
      this.enqueueTask(scheduledTask);
    });
  }

  public configureLane(type: SDKTaskType, maxConcurrency: number): void {
    const poolType = this.getDedicatedPoolType(type);
    SDKDedicatedPoolManager.getInstance().configurePoolMaxConcurrency(poolType, maxConcurrency);
    const normalizedMaxConcurrency = SDKDedicatedPoolManager.getInstance().getPoolMaxConcurrency(poolType);
    this.configureLanesForPool(poolType, normalizedMaxConcurrency);
    this.processLanesForPool(poolType);
  }

  public getStatus(): SDKTaskSchedulerStatus {
    const lanes: Record<string, SDKLaneStatus> = {};
    this.lanes.forEach((lane, type) => {
      lanes[type] = this.getLaneStatus(lane);
    });
    const taskGroups: Record<string, SDKTaskGroupStatus> = {};
    this.taskGroups.forEach((group, key) => {
      taskGroups[key] = this.getTaskGroupStatus(group);
    });

    return {
      isShutdown: this.isShutdown,
      activeSingleFlightTasks: this.activeSingleFlightKeys.size,
      rescheduledSingleFlightTasks: this.rescheduledSingleFlightTasks.size,
      lanes,
      taskGroups,
      dedicatedPools: SDKDedicatedPoolManager.getInstance().getStatus()
    };
  }

  public shutdown(): void {
    this.isShutdown = true;
  }

  public shutdownNow(): void {
    this.shutdown();
    this.lanes.forEach((lane) => {
      for (const task of this.getPendingTasks(lane)) {
        if (task.reject) {
          task.reject(new Error('SDKTaskScheduler has been shut down'));
        }
      }
      this.clearPendingTasks(lane);
      lane.runningSerialKeys.clear();
    });

    this.rescheduledSingleFlightTasks.forEach((task) => {
      if (task.reject) {
        task.reject(new Error('SDKTaskScheduler has been shut down'));
      }
    });
    this.rescheduledSingleFlightTasks.clear();
    this.activeSingleFlightKeys.clear();
    this.taskGroups.clear();
    SDKDedicatedPoolManager.resetInternal();
  }

  private initializeDefaultLanes(): void {
    const taskTypes = [
      SDKTaskType.EVENT,
      SDKTaskType.LOG,
      SDKTaskType.INNER_LOG_FILE,
      SDKTaskType.DATA_PROCESS,
      SDKTaskType.CRASH_FILE,
      SDKTaskType.UPLOAD,
      SDKTaskType.ANR,
      SDKTaskType.CUSTOM
    ];

    for (const type of taskTypes) {
      this.lanes.set(type, this.createLaneState(this.getDefaultMaxConcurrency(type)));
    }
  }

  private createLaneState(maxConcurrency: number): SDKLaneState {
    return {
      queue: [],
      queueHeadIndex: 0,
      pendingCount: 0,
      pendingFifoPriority: null,
      pendingFifoSerialKey: null,
      pendingFifoHomogeneous: true,
      running: 0,
      maxConcurrency: Math.max(1, maxConcurrency),
      runningSerialKeys: new Set<string>(),
      submittedTasks: 0,
      completedTasks: 0,
      failedTasks: 0,
      queuedTasks: 0,
      dispatchCount: 0,
      totalWaitTime: 0,
      totalCostTime: 0,
      lastWaitTime: 0,
      lastCostTime: 0,
      totalDispatchTime: 0,
      maxDispatchTime: 0,
      lastDispatchTime: 0,
      totalScanCount: 0,
      maxScanCount: 0,
      lastScanCount: 0,
      lastError: null,
      missingWorkerRequestTasks: 0,
      lastMissingWorkerRequestTaskName: null,
      runnableFallbackTasks: 0,
      lastRunnableFallbackTaskName: null
    };
  }

  private getLane(type: SDKTaskType): SDKLaneState {
    let lane = this.lanes.get(type);
    if (!lane) {
      lane = this.createLaneState(this.getDefaultMaxConcurrency(type));
      this.lanes.set(type, lane);
    }
    return lane;
  }

  private getDefaultMaxConcurrency(type: SDKTaskType): number {
    return SDKDedicatedPoolManager.getInstance().getPoolMaxConcurrency(this.getDedicatedPoolType(type));
  }

  private getDefaultPriority(type: SDKTaskType): SDKTaskPriority {
    switch (type) {
      case SDKTaskType.EVENT:
      case SDKTaskType.ANR:
        return SDKTaskPriority.HIGH;
      case SDKTaskType.LOG:
        return SDKTaskPriority.NORMAL;
      case SDKTaskType.INNER_LOG_FILE:
        return SDKTaskPriority.BACKGROUND;
      case SDKTaskType.UPLOAD:
      case SDKTaskType.DATA_PROCESS:
      case SDKTaskType.CRASH_FILE:
      case SDKTaskType.CUSTOM:
      default:
        return SDKTaskPriority.LOW;
    }
  }

  private configureLanesForPool(poolType: SDKDedicatedPoolType, maxConcurrency: number): void {
    this.lanes.forEach((lane, type) => {
      if (this.getDedicatedPoolType(type) === poolType) {
        lane.maxConcurrency = Math.max(1, maxConcurrency);
      }
    });
  }

  private processLanesForPool(poolType: SDKDedicatedPoolType): void {
    this.lanes.forEach((_lane, type) => {
      if (this.getDedicatedPoolType(type) === poolType) {
        this.processLane(type);
      }
    });
  }

  private createRunnableTask(options: SDKRunnableTaskOptions): SDKRunnableTask {
    return {
      type: options.type,
      name: options.name,
      priority: options.priority ?? this.getDefaultPriority(options.type),
      createdAt: Date.now(),
      retryCount: options.retryCount ?? 0,
      serialKey: options.serialKey,
      singleFlightKey: options.singleFlightKey,
      costHint: options.costHint,
      silent: options.silent ?? false,
      workerRequest: options.workerRequest,
      workerFallbackRunner: options.workerFallbackRunner,
      workerBridgeHandler: options.workerBridgeHandler,
      workerResponseHandler: options.workerResponseHandler,
      run: options.run
    };
  }

  private toScheduledTask(
    task: SDKTask | SDKRunnableTask,
    allowRunnableFallback: boolean,
    resolve?: () => void,
    reject?: (error: Error) => void
  ): ScheduledSDKTask {
    const runnableTask = task as SDKRunnableTask;
    return {
      id: this.generateTaskId(task.type, task.name),
      type: task.type,
      name: task.name,
      priority: task.priority,
      createdAt: task.createdAt,
      retryCount: task.retryCount,
      serialKey: task.serialKey,
      singleFlightKey: task.singleFlightKey,
      costHint: task.costHint,
      silent: task.silent ?? false,
      workerRequest: task.workerRequest,
      workerFallbackRunner: task.workerFallbackRunner,
      workerBridgeHandler: task.workerBridgeHandler,
      workerResponseHandler: task.workerResponseHandler,
      run: allowRunnableFallback ? runnableTask.run : undefined,
      allowRunnableFallback,
      resolve,
      reject
    };
  }

  private enqueueTask(task: ScheduledSDKTask): void {
    if (task.singleFlightKey && this.activeSingleFlightKeys.has(task.singleFlightKey)) {
      const previousTask = this.rescheduledSingleFlightTasks.get(task.singleFlightKey);
      if (previousTask && previousTask.reject) {
        previousTask.reject(new Error(`SDK task replaced by newer single-flight task: ${task.singleFlightKey}`));
      }
      this.rescheduledSingleFlightTasks.set(task.singleFlightKey, task);
      return;
    }

    if (task.singleFlightKey) {
      this.activeSingleFlightKeys.add(task.singleFlightKey);
    }

    const lane = this.getLane(task.type);
    this.recordMissingWorkerRequestIfNeeded(lane, task);
    this.enqueuePendingTask(lane, task);
    lane.submittedTasks++;
    this.recordTaskGroupSubmitted(task);
    if (!task.silent) {
      this.traceSchedulerLaneIfNeeded(task, lane);
    }
    this.processLane(task.type);
  }

  private processLane(type: SDKTaskType): void {
    if (this.isShutdown) {
      return;
    }

    const lane = this.getLane(type);
    while (true) {
      const dispatchStartTime = Date.now();
      const selection = this.getNextRunnableTaskSelection(type, lane);
      if (!selection.task) {
        this.recordDispatchStats(lane, Math.max(0, Date.now() - dispatchStartTime), selection.scanCount);
        return;
      }

      const task = selection.task;
      this.recordDispatchStats(lane, Math.max(0, Date.now() - dispatchStartTime), selection.scanCount);
      lane.running++;
      if (task.serialKey) {
        lane.runningSerialKeys.add(task.serialKey);
      }

      this.executeTask(type, lane, task);
    }
  }

  private enqueuePendingTask(lane: SDKLaneState, task: ScheduledSDKTask): void {
    lane.queue.push(task);
    lane.pendingCount++;
    this.updatePendingFifoStateOnEnqueue(lane, task);
  }

  private getNextRunnableTaskSelection(type: SDKTaskType, lane: SDKLaneState): SDKTaskSelection {
    if (this.canUseFifoFastPath(type, lane)) {
      return this.getNextFifoTaskFromQueue(lane);
    }
    return this.getNextRunnableTaskFromQueue(lane);
  }

  private canUseFifoFastPath(type: SDKTaskType, lane: SDKLaneState): boolean {
    if (this.canUseEventFifoFastPath(type, lane)) {
      return true;
    }
    if (this.canUseDataProcessFifoFastPath(type, lane)) {
      return true;
    }
    if (this.canUseLogFifoFastPath(type, lane)) {
      return true;
    }
    return false;
  }

  private canUseEventFifoFastPath(type: SDKTaskType, lane: SDKLaneState): boolean {
    return type === SDKTaskType.EVENT &&
      lane.maxConcurrency === 1 &&
      lane.runningSerialKeys.size === 0;
  }

  private canUseDataProcessFifoFastPath(type: SDKTaskType, lane: SDKLaneState): boolean {
    if (type !== SDKTaskType.DATA_PROCESS) {
      return false;
    }
    const head = this.peekQueueHead(lane);
    return !head || !this.isTaskBlockedBySerialKey(head, lane);
  }

  private canUseLogFifoFastPath(type: SDKTaskType, lane: SDKLaneState): boolean {
    if (type !== SDKTaskType.LOG) {
      return false;
    }
    const head = this.peekQueueHead(lane);
    if (!head) {
      return true;
    }
    return lane.pendingFifoHomogeneous &&
      lane.pendingFifoPriority === head.priority &&
      lane.pendingFifoSerialKey === this.getTaskSerialKey(head);
  }

  private getNextFifoTaskFromQueue(lane: SDKLaneState): SDKTaskSelection {
    const head = this.peekQueueHead(lane);
    if (head && this.isTaskBlockedBySerialKey(head, lane)) {
      return { task: null, scanCount: 1 };
    }
    const task = this.pollQueueHead(lane);
    if (!task) {
      return { task: null, scanCount: 0 };
    }

    lane.pendingCount = Math.max(0, lane.pendingCount - 1);
    this.resetPendingFifoStateIfEmpty(lane);
    return { task, scanCount: 1 };
  }

  private getNextRunnableTaskFromQueue(lane: SDKLaneState): SDKTaskSelection {
    let bestIndex = -1;
    let bestTask: ScheduledSDKTask | null = null;
    let scanCount = 0;

    for (let i = lane.queueHeadIndex; i < lane.queue.length; i++) {
      scanCount++;
      const task = lane.queue[i];
      if (this.isTaskBlockedBySerialKey(task, lane)) {
        continue;
      }

      if (!bestTask || this.compareTaskPriority(task, bestTask) < 0) {
        bestTask = task;
        bestIndex = i;
      }
    }

    if (bestIndex < 0) {
      this.compactPendingQueue(lane);
      return { task: null, scanCount };
    }

    lane.pendingCount = Math.max(0, lane.pendingCount - 1);
    const task = lane.queue.splice(bestIndex, 1)[0];
    this.resetPendingFifoStateIfEmpty(lane);
    return { task, scanCount };
  }

  private peekQueueHead(lane: SDKLaneState): ScheduledSDKTask | null {
    if (lane.queueHeadIndex >= lane.queue.length) {
      this.compactPendingQueue(lane);
      return null;
    }
    return lane.queue[lane.queueHeadIndex];
  }

  private isTaskBlockedBySerialKey(task: ScheduledSDKTask, lane: SDKLaneState): boolean {
    return !!task.serialKey && lane.runningSerialKeys.has(task.serialKey);
  }

  private getTaskSerialKey(task: ScheduledSDKTask): string | null {
    return task.serialKey ?? null;
  }

  private updatePendingFifoStateOnEnqueue(lane: SDKLaneState, task: ScheduledSDKTask): void {
    if (task.type !== SDKTaskType.LOG) {
      return;
    }
    const serialKey = this.getTaskSerialKey(task);
    if (lane.pendingCount === 1) {
      lane.pendingFifoPriority = task.priority;
      lane.pendingFifoSerialKey = serialKey;
      lane.pendingFifoHomogeneous = true;
      return;
    }
    if (!lane.pendingFifoHomogeneous) {
      return;
    }
    if (lane.pendingFifoPriority !== task.priority || lane.pendingFifoSerialKey !== serialKey) {
      lane.pendingFifoHomogeneous = false;
    }
  }

  private resetPendingFifoStateIfEmpty(lane: SDKLaneState): void {
    if (lane.pendingCount > 0) {
      return;
    }
    lane.pendingFifoPriority = null;
    lane.pendingFifoSerialKey = null;
    lane.pendingFifoHomogeneous = true;
  }

  private pollQueueHead(lane: SDKLaneState): ScheduledSDKTask | null {
    if (lane.queueHeadIndex >= lane.queue.length) {
      this.compactPendingQueue(lane);
      return null;
    }

    const task = lane.queue[lane.queueHeadIndex];
    lane.queueHeadIndex++;
    this.compactPendingQueue(lane);
    return task;
  }

  private compactPendingQueue(lane: SDKLaneState): void {
    if (lane.queueHeadIndex === 0) {
      return;
    }

    if (lane.queueHeadIndex >= lane.queue.length) {
      lane.queue = [];
      lane.queueHeadIndex = 0;
      return;
    }

    if (lane.queueHeadIndex >= QUEUE_COMPACT_THRESHOLD && lane.queueHeadIndex * 2 >= lane.queue.length) {
      lane.queue = lane.queue.slice(lane.queueHeadIndex);
      lane.queueHeadIndex = 0;
    }
  }

  private recordDispatchStats(lane: SDKLaneState, dispatchTime: number, scanCount: number): void {
    lane.dispatchCount++;
    lane.totalDispatchTime += dispatchTime;
    lane.maxDispatchTime = Math.max(lane.maxDispatchTime, dispatchTime);
    lane.lastDispatchTime = dispatchTime;
    lane.totalScanCount += scanCount;
    lane.maxScanCount = Math.max(lane.maxScanCount, scanCount);
    lane.lastScanCount = scanCount;
  }

  private compareTaskPriority(left: ScheduledSDKTask, right: ScheduledSDKTask): number {
    if (left.priority !== right.priority) {
      return right.priority - left.priority;
    }
    return left.createdAt - right.createdAt;
  }

  private async executeTask(type: SDKTaskType, lane: SDKLaneState, task: ScheduledSDKTask): Promise<void> {
    const startTime = Date.now();
    const waitTime = Math.max(0, startTime - task.createdAt);
    let result = 'success';
    let errorMessage = '';
    let serialResult = 'PASS';
    let previousEventName = 'none';
    let serialGapTime = 0;
    lane.totalWaitTime += waitTime;
    if (waitTime > 0) {
      lane.queuedTasks++;
    }

    if (type === SDKTaskType.EVENT) {
      serialResult = 'PASS';
      previousEventName = this.lastEventCompletedName.length > 0 ? this.lastEventCompletedName : 'none';
      serialGapTime = this.lastEventCompletedName.length > 0 ? Math.max(0, startTime - this.lastEventCompletedAt) : 0;
    }

    try {
      if (task.workerRequest) {
        let response = await SDKDedicatedPoolManager.getInstance().executeCommand(
          task.workerRequest,
          task.workerFallbackRunner || this.createFallbackRunnerFromTask(task),
          task.workerBridgeHandler
        );
        response = this.withSchedulerTiming(
          response,
          waitTime,
          lane.lastDispatchTime,
          Math.max(0, Date.now() - startTime)
        );
        if (task.workerResponseHandler) {
          await Promise.resolve(task.workerResponseHandler(response));
        }
        if (!response.ok) {
          throw new Error(response.errorMessage || `Worker command failed: ${task.workerRequest.command}`);
        }
      } else {
        if (!task.allowRunnableFallback || !task.run) {
          throw new Error(`SDK task has no workerRequest: ${task.name}`);
        }
        await SDKDedicatedPoolManager.getInstance().executeTask(
          this.getDedicatedPoolType(type),
          task.id,
          task.name,
          task.priority,
          task.run
        );
      }
      lane.completedTasks++;
      if (task.resolve) {
        task.resolve();
      }
    } catch (error) {
      const normalizedError = this.toError(error);
      result = 'failed';
      errorMessage = normalizedError.message;
      lane.failedTasks++;
      lane.lastError = normalizedError.message;
      if (!task.silent) {
        FTInnerLogger.e(TAG, `Task failed: ${task.id}, name=${task.name}, type=${task.type}, error=${normalizedError.message}`);
      }
      if (task.reject) {
        task.reject(normalizedError);
      }
    } finally {
      const costTime = Math.max(0, Date.now() - startTime);
      lane.totalCostTime += costTime;
      lane.lastWaitTime = waitTime;
      lane.lastCostTime = costTime;
      this.recordTaskGroupFinished(task, waitTime, costTime, result === 'failed');

      lane.running = Math.max(0, lane.running - 1);
      if (task.serialKey) {
        lane.runningSerialKeys.delete(task.serialKey);
      }
      this.releaseSingleFlightTask(task);
      if (type === SDKTaskType.EVENT) {
        this.traceEventLaneIfNeeded(
          task,
          lane,
          result,
          errorMessage,
          serialResult,
          waitTime,
          costTime,
          previousEventName,
          serialGapTime
        );
        this.lastEventCompletedName = task.name;
        this.lastEventCompletedAt = Date.now();
      }
      this.processLane(type);
      this.traceSchedulerLaneDrainedIfNeeded(type, lane, task);
    }
  }

  private createFallbackRunnerFromTask(task: ScheduledSDKTask): SDKDedicatedCommandRunner | undefined {
    if (!task.run) {
      return undefined;
    }
    return async () => {
      await Promise.resolve(task.run!());
      return null;
    };
  }

  private withSchedulerTiming(
    response: SDKWorkerResponse,
    waitTime: number,
    computeTime: number,
    executeTime: number
  ): SDKWorkerResponse {
    const metrics: SDKWorkerTiming = {};
    if (response.metrics) {
      metrics.poolWaitMs = response.metrics.poolWaitMs;
      metrics.poolExecuteMs = response.metrics.poolExecuteMs;
    }
    metrics.schedulerWaitMs = waitTime;
    metrics.schedulerComputeMs = computeTime;
    metrics.schedulerExecuteMs = executeTime;
    return {
      id: response.id,
      ok: response.ok,
      payload: response.payload,
      errorMessage: response.errorMessage,
      metrics
    };
  }

  private releaseSingleFlightTask(task: ScheduledSDKTask): void {
    if (!task.singleFlightKey) {
      return;
    }

    const singleFlightKey = task.singleFlightKey;
    this.activeSingleFlightKeys.delete(singleFlightKey);

    const rescheduledTask = this.rescheduledSingleFlightTasks.get(singleFlightKey);
    if (rescheduledTask) {
      this.rescheduledSingleFlightTasks.delete(singleFlightKey);
      this.enqueueTask(rescheduledTask);
    }
  }

  private recordTaskGroupSubmitted(task: ScheduledSDKTask): void {
    const key = this.getTaskGroupKey(task);
    const group = this.getOrCreateTaskGroup(key, task);
    group.submittedTasks++;
    group.lastTaskName = task.name;
  }

  private recordTaskGroupFinished(task: ScheduledSDKTask, waitTime: number, costTime: number, failed: boolean): void {
    const key = this.getTaskGroupKey(task);
    const group = this.getOrCreateTaskGroup(key, task);
    if (failed) {
      group.failedTasks++;
    } else {
      group.completedTasks++;
    }
    group.totalWaitTime += waitTime;
    group.totalCostTime += costTime;
    if (waitTime > 0) {
      group.queuedTasks++;
    }
    group.maxWaitTime = Math.max(group.maxWaitTime, waitTime);
    group.maxCostTime = Math.max(group.maxCostTime, costTime);
    group.lastTaskName = task.name;
  }

  private getOrCreateTaskGroup(key: string, task: ScheduledSDKTask): SDKTaskGroupState {
    let group = this.taskGroups.get(key);
    if (!group) {
      group = {
        laneType: task.type,
        groupName: this.getTaskGroupName(task.name),
        submittedTasks: 0,
        completedTasks: 0,
        failedTasks: 0,
        queuedTasks: 0,
        totalWaitTime: 0,
        totalCostTime: 0,
        maxWaitTime: 0,
        maxCostTime: 0,
        lastTaskName: ''
      };
      this.taskGroups.set(key, group);
    }
    return group;
  }

  private getTaskGroupStatus(group: SDKTaskGroupState): SDKTaskGroupStatus {
    const processedTasks = group.completedTasks + group.failedTasks;
    return {
      laneType: group.laneType,
      groupName: group.groupName,
      submittedTasks: group.submittedTasks,
      completedTasks: group.completedTasks,
      failedTasks: group.failedTasks,
      queuedTasks: group.queuedTasks,
      totalWaitTime: group.totalWaitTime,
      totalCostTime: group.totalCostTime,
      averageWaitTime: processedTasks > 0 ? group.totalWaitTime / processedTasks : 0,
      averageCostTime: processedTasks > 0 ? group.totalCostTime / processedTasks : 0,
      maxWaitTime: group.maxWaitTime,
      maxCostTime: group.maxCostTime,
      lastTaskName: group.lastTaskName
    };
  }

  private getTaskGroupKey(task: ScheduledSDKTask): string {
    return `${task.type}:${this.getTaskGroupName(task.name)}`;
  }

  private getTaskGroupName(taskName: string): string {
    let groupName = taskName;
    const sequenceIndex = groupName.indexOf('#');
    if (sequenceIndex >= 0) {
      groupName = groupName.substring(0, sequenceIndex);
    }
    if (groupName.indexOf('data.prepare:') === 0) {
      return groupName;
    }
    const detailIndex = groupName.indexOf(':');
    if (detailIndex > 0) {
      groupName = groupName.substring(0, detailIndex);
    }
    return groupName;
  }

  private getLaneStatus(lane: SDKLaneState): SDKLaneStatus {
    const processedTasks = lane.completedTasks + lane.failedTasks;
    const averageWaitTime = processedTasks > 0 ? lane.totalWaitTime / processedTasks : 0;
    const averageCostTime = processedTasks > 0 ? lane.totalCostTime / processedTasks : 0;
    const averageDispatchTime = lane.dispatchCount > 0 ? lane.totalDispatchTime / lane.dispatchCount : 0;
    const averageScanCount = lane.dispatchCount > 0 ? lane.totalScanCount / lane.dispatchCount : 0;
    const oldestWait = this.getOldestWait(lane);

    return {
      pending: lane.pendingCount,
      running: lane.running,
      maxConcurrency: lane.maxConcurrency,
      submittedTasks: lane.submittedTasks,
      completedTasks: lane.completedTasks,
      failedTasks: lane.failedTasks,
      queuedTasks: lane.queuedTasks,
      dispatchCount: lane.dispatchCount,
      totalWaitTime: lane.totalWaitTime,
      totalCostTime: lane.totalCostTime,
      averageWaitTime,
      averageCostTime,
      averageDispatchTime,
      maxDispatchTime: lane.maxDispatchTime,
      lastDispatchTime: lane.lastDispatchTime,
      averageScanCount,
      maxScanCount: lane.maxScanCount,
      lastScanCount: lane.lastScanCount,
      oldestWait,
      lastError: lane.lastError,
      missingWorkerRequestTasks: lane.missingWorkerRequestTasks,
      lastMissingWorkerRequestTaskName: lane.lastMissingWorkerRequestTaskName,
      runnableFallbackTasks: lane.runnableFallbackTasks,
      lastRunnableFallbackTaskName: lane.lastRunnableFallbackTaskName
    };
  }

  private recordMissingWorkerRequestIfNeeded(lane: SDKLaneState, task: ScheduledSDKTask): void {
    if (task.workerRequest) {
      return;
    }

    if (task.allowRunnableFallback) {
      lane.runnableFallbackTasks++;
      lane.lastRunnableFallbackTaskName = task.name;
      return;
    }

    lane.missingWorkerRequestTasks++;
    lane.lastMissingWorkerRequestTaskName = task.name;
    FTInnerLogger.w(
      TAG,
      `${SCHEDULER_TRACE_PREFIX} [WORKER_REQUEST_MISSING] logicalLane=${task.type} workerPool=${this.getDedicatedPoolType(task.type)} name=${task.name} submitted=${lane.submittedTasks + 1}`
    );
  }

  private getOldestWait(lane: SDKLaneState): number {
    if (lane.pendingCount === 0) {
      return 0;
    }

    if (lane.queueHeadIndex >= lane.queue.length) {
      return 0;
    }

    let oldestCreatedAt = lane.queue[lane.queueHeadIndex].createdAt;
    for (let i = lane.queueHeadIndex + 1; i < lane.queue.length; i++) {
      oldestCreatedAt = Math.min(oldestCreatedAt, lane.queue[i].createdAt);
    }
    return Math.max(0, Date.now() - oldestCreatedAt);
  }

  private getDedicatedPoolType(type: SDKTaskType): SDKDedicatedPoolType {
    switch (type) {
      case SDKTaskType.EVENT:
        return SDKDedicatedPoolType.EVENT_CONSUMER;
      case SDKTaskType.LOG:
        return SDKDedicatedPoolType.LOG_CONSUMER;
      case SDKTaskType.UPLOAD:
        return SDKDedicatedPoolType.DATA_UPLOAD;
      case SDKTaskType.DATA_PROCESS:
        return SDKDedicatedPoolType.DATA_PROCESS;
      case SDKTaskType.ANR:
        return SDKDedicatedPoolType.ANR;
      case SDKTaskType.CRASH_FILE:
        return SDKDedicatedPoolType.CRASH_FILE;
      case SDKTaskType.INNER_LOG_FILE:
      case SDKTaskType.CUSTOM:
      default:
        return SDKDedicatedPoolType.BACKGROUND;
    }
  }

  private getPendingTasks(lane: SDKLaneState): ScheduledSDKTask[] {
    const tasks: ScheduledSDKTask[] = [];
    for (let i = lane.queueHeadIndex; i < lane.queue.length; i++) {
      tasks.push(lane.queue[i]);
    }
    return tasks;
  }

  private clearPendingTasks(lane: SDKLaneState): void {
    lane.queue = [];
    lane.queueHeadIndex = 0;
    lane.pendingCount = 0;
    this.resetPendingFifoStateIfEmpty(lane);
  }

  private generateTaskId(type: SDKTaskType, name: string): string {
    this.nextTaskId++;
    return `${type}_${name}_${Date.now()}_${this.nextTaskId}`;
  }

  private toError(error: object | string | number | boolean | null | undefined): Error {
    if (error instanceof Error) {
      return error;
    }
    return new Error(String(error));
  }

  private formatEventTask(task: ScheduledSDKTask): string {
    return `${this.extractTraceNo(task.name)} name=${task.name}`;
  }

  private extractTraceNo(traceName: string): string {
    const separatorIndex = traceName.lastIndexOf('#');
    if (separatorIndex < 0 || separatorIndex === traceName.length - 1) {
      return traceName;
    }
    return `#${traceName.substring(separatorIndex + 1)}`;
  }

  private traceEventLane(message: string): void {
    FTInnerLogger.i(TAG, `${EVENT_WORKER_POOL_TRACE_PREFIX} ${message}`);
  }

  private traceSchedulerLaneIfNeeded(task: ScheduledSDKTask, lane: SDKLaneState): void {
    const skipped = this.skippedLaneTraceCount.get(task.type) ?? 0;
    if (!this.shouldTraceSchedulerLane(task.type)) {
      this.skippedLaneTraceCount.set(task.type, skipped + 1);
      return;
    }

    this.skippedLaneTraceCount.set(task.type, 0);
    const message =
      `[WORKER_POOL] logicalLane=${task.type} latest=${task.name} ${this.formatSchedulerTimingTrace(lane)} ${this.formatWorkerPoolTrace(task.type, lane)} skipped=${skipped}`;
    if (task.type === SDKTaskType.UPLOAD) {
      this.traceSchedulerLaneDebug(message);
    } else {
      this.traceSchedulerLane(message);
    }
  }

  private traceSchedulerLaneDrainedIfNeeded(
    type: SDKTaskType,
    lane: SDKLaneState,
    latestTask: ScheduledSDKTask
  ): void {
    if (lane.pendingCount > 0 || lane.running > 0) {
      return;
    }

    const processedTasks = lane.completedTasks + lane.failedTasks;
    const lastIdleProcessedCount = this.lastLaneIdleProcessedCount.get(type) ?? 0;
    const processedSinceLastIdle = Math.max(0, processedTasks - lastIdleProcessedCount);
    this.lastLaneIdleProcessedCount.set(type, processedTasks);

    if (latestTask.silent) {
      return;
    }

    const skipped = this.skippedLaneTraceCount.get(type) ?? 0;
    if (processedSinceLastIdle <= 1 && skipped <= 0) {
      return;
    }

    this.skippedLaneTraceCount.set(type, 0);
    const message =
      `[WORKER_POOL_DRAINED] logicalLane=${type} latest=${latestTask.name} ${this.formatSchedulerTimingTrace(lane)} ${this.formatWorkerPoolTrace(type, lane)} skipped=${skipped} processedSinceIdle=${processedSinceLastIdle}`;
    if (type === SDKTaskType.UPLOAD) {
      this.traceSchedulerLaneDebug(message);
    } else {
      this.traceSchedulerLane(message);
    }
  }

  private shouldTraceSchedulerLane(type: SDKTaskType): boolean {
    const now = Date.now();
    const lastTraceAt = this.lastLaneTraceAt.get(type) ?? 0;
    if (now - lastTraceAt < SCHEDULER_WORKER_POOL_TRACE_INTERVAL_MS) {
      return false;
    }

    this.lastLaneTraceAt.set(type, now);
    return true;
  }

  private traceEventLaneIfNeeded(
    task: ScheduledSDKTask,
    lane: SDKLaneState,
    result: string,
    errorMessage: string,
    serialResult: string,
    waitTime: number,
    costTime: number,
    previousEventName: string,
    serialGapTime: number
  ): void {
    const skipped = this.skippedEventTraceCount;
    const forceTrace = result !== 'success' || serialResult !== 'PASS';
    if (!forceTrace && !this.shouldTraceEventLane()) {
      this.skippedEventTraceCount++;
      return;
    }

    this.skippedEventTraceCount = 0;
    const errorPart = errorMessage.length > 0 ? ` error=${errorMessage}` : '';
    const computeTime = lane.lastDispatchTime;
    const totalTime = waitTime + computeTime + costTime;
    this.traceEventLane(
      `[WORKER_POOL_CONSUMED] ${serialResult} ${this.formatEventTask(task)} result=${result}${errorPart} wait=${waitTime}ms compute=${computeTime}ms execute=${costTime}ms total=${totalTime}ms cost=${costTime}ms dispatchCost=${computeTime}ms scanCount=${lane.lastScanCount} previous=${previousEventName} gap=${serialGapTime}ms ${this.formatWorkerPoolTrace(task.type, lane)} skipped=${skipped}`
    );
  }

  private shouldTraceEventLane(): boolean {
    const now = Date.now();
    if (now - this.lastEventTraceAt < EVENT_WORKER_POOL_TRACE_INTERVAL_MS) {
      return false;
    }

    this.lastEventTraceAt = now;
    return true;
  }

  private formatWorkerPoolTrace(type: SDKTaskType, lane: SDKLaneState): string {
    const poolType = this.getDedicatedPoolType(type);
    const poolStatus = this.getWorkerPoolStatus(poolType);
    if (!poolStatus) {
      return `workerPool=${poolType} logicalPending=${lane.pendingCount} logicalRunning=${lane.running} logicalMax=${lane.maxConcurrency} logicalSubmitted=${lane.submittedTasks} logicalCompleted=${lane.completedTasks} logicalFailed=${lane.failedTasks} poolStatus=unavailable`;
    }

    return `workerPool=${poolType} backend=${poolStatus.backend} workerCount=${poolStatus.workerCount} poolPending=${poolStatus.pending} poolRunning=${poolStatus.running} poolMax=${poolStatus.maxConcurrency} poolSubmitted=${poolStatus.submittedTasks} poolCompleted=${poolStatus.completedTasks} poolFailed=${poolStatus.failedTasks} logicalPending=${lane.pendingCount} logicalRunning=${lane.running} logicalSubmitted=${lane.submittedTasks} logicalCompleted=${lane.completedTasks} logicalFailed=${lane.failedTasks}`;
  }

  private formatSchedulerTimingTrace(lane: SDKLaneState): string {
    const processedTasks = lane.completedTasks + lane.failedTasks;
    const oldestWait = this.getOldestWait(lane);
    const waitTime = lane.pendingCount > 0 ? oldestWait : lane.lastWaitTime;
    const computeTime = lane.lastDispatchTime;
    const executeTime = lane.lastCostTime;
    const totalTime = waitTime + computeTime + executeTime;
    const averageWaitTime = processedTasks > 0 ? Math.round(lane.totalWaitTime / processedTasks) : 0;
    const averageCostTime = processedTasks > 0 ? Math.round(lane.totalCostTime / processedTasks) : 0;
    return `wait=${waitTime}ms compute=${computeTime}ms execute=${executeTime}ms total=${totalTime}ms cost=${executeTime}ms avgWait=${averageWaitTime}ms avgCost=${averageCostTime}ms totalWait=${lane.totalWaitTime}ms totalCost=${lane.totalCostTime}ms oldestWait=${oldestWait}ms dispatchCost=${computeTime}ms`;
  }

  private getWorkerPoolStatus(poolType: SDKDedicatedPoolType): SDKDedicatedPoolStatus | null {
    const pools = SDKDedicatedPoolManager.getInstance().getStatus().pools;
    const status = pools[poolType];
    if (!status) {
      return null;
    }
    return status;
  }

  private traceSchedulerLane(message: string): void {
    FTInnerLogger.i(TAG, `${SCHEDULER_TRACE_PREFIX} ${message}`);
  }

  private traceSchedulerLaneDebug(message: string): void {
    FTInnerLogger.d(TAG, `${SCHEDULER_TRACE_PREFIX} ${message}`);
  }

  private checkNotShutdown(): void {
    if (this.isShutdown) {
      throw new Error('SDKTaskScheduler has been shut down');
    }
  }

}
