/**
 * Internal SDK task scheduler.
 *
 * Provides one submit entry while keeping execution isolated by task lane.
 */
import { FTInnerLogger } from '../log/FTLogger';

const TAG = "SDKTaskScheduler";
const EVENT_LANE_TRACE_PREFIX = "<FT-EVENT-LANE>";
const SCHEDULER_TRACE_PREFIX = "<FT-SDK-SCHEDULER>";

export enum SDKTaskType {
  EVENT = 'event',
  LOG = 'log',
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
  run: SDKTaskRunner;
}

export interface SDKLaneStatus {
  pending: number;
  running: number;
  maxConcurrency: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  averageWaitTime: number;
  averageCostTime: number;
  oldestWait: number;
  lastError: string | null;
}

export interface SDKTaskSchedulerStatus {
  isShutdown: boolean;
  activeSingleFlightTasks: number;
  rescheduledSingleFlightTasks: number;
  lanes: Record<string, SDKLaneStatus>;
}

interface ScheduledSDKTask extends SDKTask {
  id: string;
  resolve?: () => void;
  reject?: (error: Error) => void;
}

interface SDKLaneState {
  queue: ScheduledSDKTask[];
  running: number;
  maxConcurrency: number;
  runningSerialKeys: Set<string>;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  lastError: string | null;
}

export class SDKTaskScheduler {
  private static instance: SDKTaskScheduler | null = null;
  private lanes: Map<SDKTaskType, SDKLaneState> = new Map();
  private activeSingleFlightKeys: Set<string> = new Set();
  private rescheduledSingleFlightTasks: Map<string, ScheduledSDKTask> = new Map();
  private nextTaskId: number = 0;
  private isShutdown: boolean = false;
  private lastEventCompletedName: string = '';
  private lastEventCompletedAt: number = 0;

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

    return {
      isShutdown: this.isShutdown,
      activeSingleFlightTasks: this.activeSingleFlightKeys.size,
      rescheduledSingleFlightTasks: this.rescheduledSingleFlightTasks.size,
      lanes
    };
  }

  public shutdown(): void {
    this.isShutdown = true;
  }

  public shutdownNow(): void {
    this.shutdown();
    this.lanes.forEach((lane) => {
      for (const task of lane.queue) {
        if (task.reject) {
          task.reject(new Error('SDKTaskScheduler has been shut down'));
        }
      }
      lane.queue = [];
      lane.runningSerialKeys.clear();
    });

    this.rescheduledSingleFlightTasks.forEach((task) => {
      if (task.reject) {
        task.reject(new Error('SDKTaskScheduler has been shut down'));
      }
    });
    this.rescheduledSingleFlightTasks.clear();
    this.activeSingleFlightKeys.clear();
  }

  private initializeDefaultLanes(): void {
    const taskTypes = [
      SDKTaskType.EVENT,
      SDKTaskType.LOG,
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
      running: 0,
      maxConcurrency: Math.max(1, maxConcurrency),
      runningSerialKeys: new Set<string>(),
      submittedTasks: 0,
      completedTasks: 0,
      failedTasks: 0,
      totalWaitTime: 0,
      totalCostTime: 0,
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
    lane.queue.push(task);
    lane.submittedTasks++;
    const laneTrace =
      `[LANE] lane=${task.type} name=${task.name} pending=${lane.queue.length} active=${lane.running} max=${lane.maxConcurrency} priority=${task.priority} serial=${task.serialKey ?? 'none'}`;
    if (task.type === SDKTaskType.UPLOAD) {
      this.traceSchedulerLaneDebug(laneTrace);
    } else {
      this.traceSchedulerLane(laneTrace);
    }
    this.processLane(task.type);
  }

  private processLane(type: SDKTaskType): void {
    if (this.isShutdown) {
      return;
    }

    const lane = this.getLane(type);
    while (lane.running < lane.maxConcurrency) {
      const nextTaskIndex = this.getNextRunnableTaskIndex(lane);
      if (nextTaskIndex < 0) {
        return;
      }

      const task = lane.queue.splice(nextTaskIndex, 1)[0];
      lane.running++;
      if (task.serialKey) {
        lane.runningSerialKeys.add(task.serialKey);
      }

      this.executeTask(type, lane, task);
    }
  }

  private getNextRunnableTaskIndex(lane: SDKLaneState): number {
    let bestIndex = -1;
    let bestTask: ScheduledSDKTask | null = null;

    for (let i = 0; i < lane.queue.length; i++) {
      const task = lane.queue[i];
      if (task.serialKey && lane.runningSerialKeys.has(task.serialKey)) {
        continue;
      }

      if (!bestTask || this.compareTaskPriority(task, bestTask) < 0) {
        bestTask = task;
        bestIndex = i;
      }
    }

    return bestIndex;
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
      FTInnerLogger.e(TAG, `Task failed: ${task.id}, name=${task.name}, type=${task.type}, error=${normalizedError.message}`);
      if (task.reject) {
        task.reject(normalizedError);
      }
    } finally {
      const costTime = Math.max(0, Date.now() - startTime);
      lane.totalCostTime += costTime;

      lane.running = Math.max(0, lane.running - 1);
      if (task.serialKey) {
        lane.runningSerialKeys.delete(task.serialKey);
      }
      this.releaseSingleFlightTask(task);
      if (type === SDKTaskType.EVENT) {
        const errorPart = errorMessage.length > 0 ? ` error=${errorMessage}` : '';
        this.traceEventLane(
          `[CONSUMED] ${serialResult} ${this.formatEventTask(task)} result=${result}${errorPart} waited=${waitTime}ms cost=${costTime}ms previous=${previousEventName} gap=${serialGapTime}ms pending=${lane.queue.length} active=${lane.running} completed=${lane.completedTasks} failed=${lane.failedTasks}`
        );
        this.lastEventCompletedName = task.name;
        this.lastEventCompletedAt = Date.now();
      }
      this.processLane(type);
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

  private getLaneStatus(lane: SDKLaneState): SDKLaneStatus {
    const processedTasks = lane.completedTasks + lane.failedTasks;
    const averageWaitTime = processedTasks > 0 ? lane.totalWaitTime / processedTasks : 0;
    const averageCostTime = processedTasks > 0 ? lane.totalCostTime / processedTasks : 0;
    const oldestWait = this.getOldestWait(lane);

    return {
      pending: lane.queue.length,
      running: lane.running,
      maxConcurrency: lane.maxConcurrency,
      submittedTasks: lane.submittedTasks,
      completedTasks: lane.completedTasks,
      failedTasks: lane.failedTasks,
      averageWaitTime,
      averageCostTime,
      oldestWait,
      lastError: lane.lastError
    };
  }

  private getOldestWait(lane: SDKLaneState): number {
    if (lane.queue.length === 0) {
      return 0;
    }

    let oldestCreatedAt = lane.queue[0].createdAt;
    for (let i = 1; i < lane.queue.length; i++) {
      oldestCreatedAt = Math.min(oldestCreatedAt, lane.queue[i].createdAt);
    }
    return Math.max(0, Date.now() - oldestCreatedAt);
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
