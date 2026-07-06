/**
 * Internal SDK task scheduler.
 *
 * Provides one submit entry while keeping execution isolated by task lane.
 */
import { FTInnerLogger } from '../log/FTLogger';

const TAG = "SDKTaskScheduler";
const EVENT_LANE_TRACE_PREFIX = "<FT-EVENT-LANE>";
const SCHEDULER_TRACE_PREFIX = "<FT-SDK-SCHEDULER>";
const SCHEDULER_LANE_TRACE_INTERVAL_MS = 5000;
const EVENT_LANE_TRACE_INTERVAL_MS = 2000;
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

export interface SDKTask {
  type: SDKTaskType;
  name: string;
  priority: SDKTaskPriority;
  createdAt: number;
  retryCount: number;
  serialKey?: string;
  singleFlightKey?: string;
  costHint?: SDKTaskCostHint;
  silent?: boolean;
  run: SDKTaskRunner;
}

export interface SDKTaskOptions {
  type: SDKTaskType;
  name: string;
  priority?: SDKTaskPriority;
  retryCount?: number;
  serialKey?: string;
  singleFlightKey?: string;
  costHint?: SDKTaskCostHint;
  silent?: boolean;
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
}

export interface SDKTaskSchedulerStatus {
  isShutdown: boolean;
  activeSingleFlightTasks: number;
  rescheduledSingleFlightTasks: number;
  lanes: Record<string, SDKLaneStatus>;
  taskGroups: Record<string, SDKTaskGroupStatus>;
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

interface ScheduledSDKTask extends SDKTask {
  id: string;
  resolve?: () => void;
  reject?: (error: Error) => void;
}

interface SDKLaneState {
  queue: ScheduledSDKTask[];
  queueHeadIndex: number;
  pendingCount: number;
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
  totalDispatchTime: number;
  maxDispatchTime: number;
  lastDispatchTime: number;
  totalScanCount: number;
  maxScanCount: number;
  lastScanCount: number;
  lastError: string | null;
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
      run: options.run
    };
  }

  public submitTask(options: SDKTaskOptions): string {
    return this.submit(this.createTask(options));
  }

  public submit(task: SDKTask): string {
    this.checkNotShutdown();
    const scheduledTask = this.toScheduledTask(task);
    this.enqueueTask(scheduledTask);
    return scheduledTask.id;
  }

  public submitTaskAndWait(options: SDKTaskOptions): Promise<void> {
    return this.submitAndWait(this.createTask(options));
  }

  public submitAndWait(task: SDKTask): Promise<void> {
    this.checkNotShutdown();
    return new Promise<void>((resolve, reject) => {
      const scheduledTask = this.toScheduledTask(task, resolve, reject);
      this.enqueueTask(scheduledTask);
    });
  }

  public configureLane(type: SDKTaskType, maxConcurrency: number): void {
    const lane = this.getLane(type);
    lane.maxConcurrency = Math.max(1, maxConcurrency);
    this.processLane(type);
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
      taskGroups
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
      totalDispatchTime: 0,
      maxDispatchTime: 0,
      lastDispatchTime: 0,
      totalScanCount: 0,
      maxScanCount: 0,
      lastScanCount: 0,
      lastError: null
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
    switch (type) {
      case SDKTaskType.DATA_PROCESS:
        return 2;
      case SDKTaskType.CRASH_FILE:
      case SDKTaskType.INNER_LOG_FILE:
        return 1;
      case SDKTaskType.EVENT:
      case SDKTaskType.LOG:
      case SDKTaskType.UPLOAD:
      case SDKTaskType.ANR:
      case SDKTaskType.CUSTOM:
      default:
        return 1;
    }
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

  private toScheduledTask(task: SDKTask, resolve?: () => void, reject?: (error: Error) => void): ScheduledSDKTask {
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
      run: task.run,
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
    while (lane.running < lane.maxConcurrency) {
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
  }

  private getNextRunnableTaskSelection(type: SDKTaskType, lane: SDKLaneState): SDKTaskSelection {
    if (this.canUseEventFifoFastPath(type, lane)) {
      return this.getNextEventTaskFromQueue(lane);
    }
    return this.getNextRunnableTaskFromQueue(lane);
  }

  private canUseEventFifoFastPath(type: SDKTaskType, lane: SDKLaneState): boolean {
    return type === SDKTaskType.EVENT &&
      lane.maxConcurrency === 1 &&
      lane.runningSerialKeys.size === 0;
  }

  private getNextEventTaskFromQueue(lane: SDKLaneState): SDKTaskSelection {
    const task = this.pollQueueHead(lane);
    if (!task) {
      return { task: null, scanCount: 0 };
    }

    lane.pendingCount = Math.max(0, lane.pendingCount - 1);
    return { task, scanCount: 1 };
  }

  private getNextRunnableTaskFromQueue(lane: SDKLaneState): SDKTaskSelection {
    let bestIndex = -1;
    let bestTask: ScheduledSDKTask | null = null;
    let scanCount = 0;

    for (let i = lane.queueHeadIndex; i < lane.queue.length; i++) {
      scanCount++;
      const task = lane.queue[i];
      if (task.serialKey && lane.runningSerialKeys.has(task.serialKey)) {
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
    return { task: lane.queue.splice(bestIndex, 1)[0], scanCount };
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
      serialResult = lane.running <= 1 ? 'PASS' : 'FAIL';
      previousEventName = this.lastEventCompletedName.length > 0 ? this.lastEventCompletedName : 'none';
      serialGapTime = this.lastEventCompletedName.length > 0 ? Math.max(0, startTime - this.lastEventCompletedAt) : 0;
    }

    try {
      await Promise.resolve(task.run());
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
      lastError: lane.lastError
    };
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
    FTInnerLogger.i(TAG, `${EVENT_LANE_TRACE_PREFIX} ${message}`);
  }

  private traceSchedulerLaneIfNeeded(task: ScheduledSDKTask, lane: SDKLaneState): void {
    const skipped = this.skippedLaneTraceCount.get(task.type) ?? 0;
    if (!this.shouldTraceSchedulerLane(task.type)) {
      this.skippedLaneTraceCount.set(task.type, skipped + 1);
      return;
    }

    this.skippedLaneTraceCount.set(task.type, 0);
    const message =
      `[LANE] lane=${task.type} latest=${task.name} pending=${lane.pendingCount} active=${lane.running} max=${lane.maxConcurrency} submitted=${lane.submittedTasks} completed=${lane.completedTasks} failed=${lane.failedTasks} skipped=${skipped}`;
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
      `[DRAINED] lane=${type} latest=${latestTask.name} pending=${lane.pendingCount} active=${lane.running} max=${lane.maxConcurrency} submitted=${lane.submittedTasks} completed=${lane.completedTasks} failed=${lane.failedTasks} skipped=${skipped} processedSinceIdle=${processedSinceLastIdle}`;
    if (type === SDKTaskType.UPLOAD) {
      this.traceSchedulerLaneDebug(message);
    } else {
      this.traceSchedulerLane(message);
    }
  }

  private shouldTraceSchedulerLane(type: SDKTaskType): boolean {
    const now = Date.now();
    const lastTraceAt = this.lastLaneTraceAt.get(type) ?? 0;
    if (now - lastTraceAt < SCHEDULER_LANE_TRACE_INTERVAL_MS) {
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
    this.traceEventLane(
      `[CONSUMED] ${serialResult} ${this.formatEventTask(task)} result=${result}${errorPart} waited=${waitTime}ms cost=${costTime}ms dispatchCost=${lane.lastDispatchTime}ms scanCount=${lane.lastScanCount} previous=${previousEventName} gap=${serialGapTime}ms pending=${lane.pendingCount} active=${lane.running} completed=${lane.completedTasks} failed=${lane.failedTasks} skipped=${skipped}`
    );
  }

  private shouldTraceEventLane(): boolean {
    const now = Date.now();
    if (now - this.lastEventTraceAt < EVENT_LANE_TRACE_INTERVAL_MS) {
      return false;
    }

    this.lastEventTraceAt = now;
    return true;
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
