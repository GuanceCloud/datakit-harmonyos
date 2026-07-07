import {
  assertSDKWorkerRequestSerializable,
  SDKDedicatedPoolType,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerCommand,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from './SDKWorkerProtocol';
import {
  createSDKWorkerRuntimeState,
  handleSDKWorkerRequest,
  SDKWorkerRuntimeState
} from './SDKWorkerBusinessHandlers';
import {
  SDKWorkerPathInfo,
  SDKWorkerPathResolver
} from './SDKWorkerPathResolver';
import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';

const DEFAULT_WORKER_COMMAND_TIMEOUT_MS = 3000;

export type SDKDedicatedTaskRunner = () => void | Promise<void>;
export type SDKDedicatedCommandRunner = () => SDKWorkerPayload | Promise<SDKWorkerPayload>;

export interface SDKDedicatedPoolStatus {
  pool: string;
  backend: string;
  workerPath: string;
  workerCount: number;
  maxConcurrency: number;
  pending: number;
  running: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  averageWaitTime: number;
  averageCostTime: number;
  lastError: string;
  restartCount: number;
  isShutdown: boolean;
}

export interface SDKDataUploadPoolStatus {
  isScheduled: boolean;
  isRunning: boolean;
  needReschedule: boolean;
  scheduledDelay: number;
  scheduledAt: number;
  runningTaskId: string;
  rescheduleDelay: number;
}

export interface SDKDbWriteLaneStatus {
  pending: number;
  running: number;
  completedTasks: number;
  failedTasks: number;
  lastError: string;
}

export interface SDKDedicatedPoolManagerStatus {
  pools: Record<string, SDKDedicatedPoolStatus>;
  dataUpload: SDKDataUploadPoolStatus;
  dbWriteLane: SDKDbWriteLaneStatus;
}

interface SDKPoolConfig {
  pool: SDKDedicatedPoolType;
  workerCount: number;
  maxConcurrency: number;
  backend: string;
  workerInfo: SDKWorkerPathInfo;
}

interface SDKWorkerProbePayload {
  probe: boolean;
}

interface SDKThreadWorkerResponseMessage {
  data: SDKWorkerResponse;
}

interface SDKThreadWorkerPendingCommand {
  requestId: string;
  timeoutId: number;
  resolve: (response: SDKWorkerResponse) => void;
  reject: (error: Error) => void;
}

interface SDKThreadWorkerSlot {
  index: number;
  workerInstance: worker.ThreadWorker | null;
  scriptUrl: string;
  busy: boolean;
  pending: SDKThreadWorkerPendingCommand | null;
  restartCount: number;
}

interface QueuedPoolTask {
  id: string;
  name: string;
  priority: number;
  createdAt: number;
  run: SDKDedicatedTaskRunner;
  resolve: () => void;
  reject: (error: Error) => void;
  request?: SDKWorkerRequest;
}

interface DedicatedPoolState extends SDKPoolConfig {
  queue: QueuedPoolTask[];
  workerSlots: SDKThreadWorkerSlot[];
  workerInitAttempted: boolean;
  inlineState: SDKWorkerRuntimeState;
  running: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  lastError: string;
  restartCount: number;
  isShutdown: boolean;
}

interface UploadScheduleTask {
  id: string;
  name: string;
  run: SDKDedicatedTaskRunner;
}

/**
 * Internal manager for Android-aligned dedicated pools.
 *
 * Command tasks use long-lived ThreadWorker instances when the runtime can load
 * the worker scripts. The manager keeps queueing, serial/concurrent limits,
 * upload coalescing, DTO validation, restart-once handling, and inline fallback
 * behind the same producer-facing entry points.
 */
export class SDKDedicatedPoolManager {
  private static instance: SDKDedicatedPoolManager | null = null;
  private static workerCommandTimeoutMs: number = DEFAULT_WORKER_COMMAND_TIMEOUT_MS;
  private pools: Map<SDKDedicatedPoolType, DedicatedPoolState> = new Map();
  private activePoolStack: SDKDedicatedPoolType[] = [];
  private nextTaskId: number = 0;
  private uploadScheduled: boolean = false;
  private uploadRunning: boolean = false;
  private uploadNeedReschedule: boolean = false;
  private uploadScheduledDelay: number = 0;
  private uploadScheduledAt: number = 0;
  private uploadRescheduleDelay: number = 0;
  private uploadRunningTaskId: string = '';
  private uploadTimer: number = -1;
  private uploadTask: UploadScheduleTask | null = null;
  private dbWriteTail: Promise<void> = Promise.resolve();
  private dbWritePending: number = 0;
  private dbWriteRunning: number = 0;
  private dbWriteCompletedTasks: number = 0;
  private dbWriteFailedTasks: number = 0;
  private dbWriteLastError: string = '';

  private constructor() {
    this.initializePools();
  }

  public static getInstance(): SDKDedicatedPoolManager {
    if (!SDKDedicatedPoolManager.instance) {
      SDKDedicatedPoolManager.instance = new SDKDedicatedPoolManager();
    }
    return SDKDedicatedPoolManager.instance;
  }

  public static resetInternal(): void {
    if (SDKDedicatedPoolManager.instance) {
      SDKDedicatedPoolManager.instance.shutdownNow();
    }
    SDKDedicatedPoolManager.instance = null;
  }

  public static setWorkerCommandTimeoutMsInternal(timeoutMs: number): void {
    SDKDedicatedPoolManager.workerCommandTimeoutMs = Math.max(1, timeoutMs);
  }

  public static resetWorkerCommandTimeoutMsInternal(): void {
    SDKDedicatedPoolManager.workerCommandTimeoutMs = DEFAULT_WORKER_COMMAND_TIMEOUT_MS;
  }

  public executeTask(
    pool: SDKDedicatedPoolType,
    id: string,
    name: string,
    priority: number,
    runner: SDKDedicatedTaskRunner,
    request?: SDKWorkerRequest
  ): Promise<void> {
    const state = this.getPool(pool);
    if (state.isShutdown) {
      return Promise.reject(new Error(`SDK dedicated pool has been shut down: ${pool}`));
    }

    if (request) {
      assertSDKWorkerRequestSerializable(request);
    }

    return new Promise<void>((resolve, reject) => {
      const task: QueuedPoolTask = {
        id,
        name,
        priority,
        createdAt: Date.now(),
        run: runner,
        resolve,
        reject,
        request
      };

      state.submittedTasks++;
      state.queue.push(task);
      if (state.running > 0) {
        state.queuedTasks++;
      }
      this.processPool(state);
    });
  }

  public executeCommand(
    request: SDKWorkerRequest,
    runner?: SDKDedicatedCommandRunner
  ): Promise<SDKWorkerResponse> {
    assertSDKWorkerRequestSerializable(request);

    if (this.isExecutingPool(request.pool)) {
      return this.executeCommandInCurrentPool(request, runner);
    }

    return new Promise<SDKWorkerResponse>((resolve) => {
      this.executeTask(request.pool, request.id, request.command, request.priority, async () => {
        try {
          const response = await this.dispatchWorkerCommand(request, runner);
          resolve(response);
          if (!response.ok) {
            throw new Error(response.errorMessage || `Worker command failed: ${request.command}`);
          }
        } catch (error) {
          const errorDTO = toSDKWorkerErrorDTO(error);
          const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
          resolve({
            id: request.id,
            ok: false,
            errorMessage: errorDTO.message,
            payload: errorPayload
          });
        }
      }, request).catch((error: Error) => {
        const errorDTO = toSDKWorkerErrorDTO(error);
        const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
        resolve({
          id: request.id,
          ok: false,
          errorMessage: errorDTO.message,
          payload: errorPayload
        });
      });
    });
  }

  private async executeCommandInCurrentPool(
    request: SDKWorkerRequest,
    runner?: SDKDedicatedCommandRunner
  ): Promise<SDKWorkerResponse> {
    const state = this.getPool(request.pool);
    state.submittedTasks++;
    const startTime = Date.now();

    try {
      const response = await this.dispatchWorkerCommand(request, runner);
      if (response.ok) {
        state.completedTasks++;
      } else {
        state.failedTasks++;
        state.lastError = response.errorMessage || `Worker command failed: ${request.command}`;
      }
      return response;
    } catch (error) {
      const errorDTO = toSDKWorkerErrorDTO(error);
      const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
      state.failedTasks++;
      state.lastError = errorDTO.message;
      return {
        id: request.id,
        ok: false,
        errorMessage: errorDTO.message,
        payload: errorPayload
      };
    } finally {
      state.totalCostTime += Math.max(0, Date.now() - startTime);
    }
  }

  public probeDedicatedWorkers(): Promise<SDKWorkerResponse[]> {
    const pools: SDKDedicatedPoolType[] = [
      SDKDedicatedPoolType.EVENT_CONSUMER,
      SDKDedicatedPoolType.LOG_CONSUMER,
      SDKDedicatedPoolType.DATA_PROCESS,
      SDKDedicatedPoolType.DATA_UPLOAD
    ];
    const tasks: Promise<SDKWorkerResponse>[] = [];
    for (let i = 0; i < pools.length; i++) {
      const pool = pools[i];
      const payload: SDKWorkerProbePayload = {
        probe: true
      };
      tasks.push(this.executeCommand({
        id: this.nextInternalTaskId(pool, 'sdk.ping'),
        pool,
        command: SDKWorkerCommand.PING,
        priority: 5,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      }));
    }
    return Promise.all(tasks);
  }

  public executeEventReentrant(
    name: string,
    runner: SDKDedicatedTaskRunner
  ): Promise<void> {
    const pool = SDKDedicatedPoolType.EVENT_CONSUMER;
    const state = this.getPool(pool);
    const id = this.nextInternalTaskId(pool, name);
    state.submittedTasks++;

    if (this.isExecutingPool(pool)) {
      return this.runReentrantTask(state, id, name, runner);
    }

    return this.executeTask(pool, id, name, 7, runner);
  }

  public runDbWrite<T>(name: string, runner: () => T | Promise<T>): Promise<T> {
    this.dbWritePending++;
    const previousTail = this.dbWriteTail.catch(() => {});
    let releaseCurrent: () => void = () => {};
    const currentTail = new Promise<void>((resolve) => {
      releaseCurrent = resolve;
    });
    this.dbWriteTail = previousTail.then(() => currentTail);

    return new Promise<T>((resolve, reject) => {
      previousTail.then(async () => {
        this.dbWritePending = Math.max(0, this.dbWritePending - 1);
        this.dbWriteRunning++;
        try {
          const result = await Promise.resolve(runner());
          this.dbWriteCompletedTasks++;
          resolve(result);
        } catch (error) {
          const normalized = error instanceof Error ? error : new Error(String(error));
          this.dbWriteFailedTasks++;
          this.dbWriteLastError = `${name}: ${normalized.message}`;
          reject(normalized);
        } finally {
          this.dbWriteRunning = Math.max(0, this.dbWriteRunning - 1);
          releaseCurrent();
        }
      }).catch((error: Error) => {
        this.dbWritePending = Math.max(0, this.dbWritePending - 1);
        this.dbWriteFailedTasks++;
        this.dbWriteLastError = `${name}: ${error.message}`;
        releaseCurrent();
        reject(error);
      });
    });
  }

  public scheduleDataUpload(name: string, runner: SDKDedicatedTaskRunner, delay: number = 0): boolean {
    const normalizedDelay = Math.max(0, delay);
    if (this.uploadScheduled || this.uploadRunning) {
      this.uploadNeedReschedule = true;
      if (this.uploadRescheduleDelay > 0) {
        this.uploadRescheduleDelay = Math.min(this.uploadRescheduleDelay, normalizedDelay);
      } else {
        this.uploadRescheduleDelay = normalizedDelay;
      }
      return false;
    }

    this.uploadScheduled = true;
    this.uploadScheduledDelay = normalizedDelay;
    this.uploadScheduledAt = Date.now();
    this.uploadTask = {
      id: this.nextInternalTaskId(SDKDedicatedPoolType.DATA_UPLOAD, name),
      name,
      run: runner
    };

    if (normalizedDelay > 0) {
      this.clearUploadTimer();
      this.uploadTimer = setTimeout(() => {
        this.uploadTimer = -1;
        this.executeScheduledUpload();
      }, normalizedDelay);
    } else {
      this.executeScheduledUpload();
    }
    return true;
  }

  public cancelDataUploadSchedule(): void {
    this.clearUploadTimer();
    this.uploadScheduled = false;
    this.uploadRunning = false;
    this.uploadNeedReschedule = false;
    this.uploadScheduledDelay = 0;
    this.uploadScheduledAt = 0;
    this.uploadRescheduleDelay = 0;
    this.uploadRunningTaskId = '';
    this.uploadTask = null;
  }

  public getUploadStatus(): SDKDataUploadPoolStatus {
    return {
      isScheduled: this.uploadScheduled,
      isRunning: this.uploadRunning,
      needReschedule: this.uploadNeedReschedule,
      scheduledDelay: this.uploadScheduledDelay,
      scheduledAt: this.uploadScheduledAt,
      runningTaskId: this.uploadRunningTaskId,
      rescheduleDelay: this.uploadRescheduleDelay
    };
  }

  public getDataProcessWorkerCount(): number {
    return this.getPool(SDKDedicatedPoolType.DATA_PROCESS).workerCount;
  }

  public getStatus(): SDKDedicatedPoolManagerStatus {
    const pools: Record<string, SDKDedicatedPoolStatus> = {};
    this.pools.forEach((state, pool) => {
      pools[pool] = this.getPoolStatus(state);
    });

    return {
      pools,
      dataUpload: this.getUploadStatus(),
      dbWriteLane: {
        pending: this.dbWritePending,
        running: this.dbWriteRunning,
        completedTasks: this.dbWriteCompletedTasks,
        failedTasks: this.dbWriteFailedTasks,
        lastError: this.dbWriteLastError
      }
    };
  }

  public shutdownNow(): void {
    this.pools.forEach((state) => {
      state.isShutdown = true;
      for (const task of state.queue) {
        task.reject(new Error(`SDK dedicated pool has been shut down: ${state.pool}`));
      }
      state.queue = [];
      state.running = 0;
      for (let i = 0; i < state.workerSlots.length; i++) {
        this.terminateWorkerSlot(state.workerSlots[i]);
      }
    });
    this.clearUploadTimer();
    this.uploadScheduled = false;
    this.uploadRunning = false;
    this.uploadNeedReschedule = false;
    this.uploadScheduledDelay = 0;
    this.uploadScheduledAt = 0;
    this.uploadRescheduleDelay = 0;
    this.uploadRunningTaskId = '';
    this.uploadTask = null;
  }

  private initializePools(): void {
    this.pools.set(SDKDedicatedPoolType.EVENT_CONSUMER, this.createPool({
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      workerCount: 1,
      maxConcurrency: 1,
      backend: 'inline',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.EVENT_CONSUMER)
    }));
    this.pools.set(SDKDedicatedPoolType.LOG_CONSUMER, this.createPool({
      pool: SDKDedicatedPoolType.LOG_CONSUMER,
      workerCount: 1,
      maxConcurrency: 1,
      backend: 'inline',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.LOG_CONSUMER)
    }));
    const dataProcessWorkers = this.resolveDataProcessWorkerCount();
    this.pools.set(SDKDedicatedPoolType.DATA_PROCESS, this.createPool({
      pool: SDKDedicatedPoolType.DATA_PROCESS,
      workerCount: dataProcessWorkers,
      maxConcurrency: dataProcessWorkers,
      backend: 'inline',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.DATA_PROCESS)
    }));
    this.pools.set(SDKDedicatedPoolType.DATA_UPLOAD, this.createPool({
      pool: SDKDedicatedPoolType.DATA_UPLOAD,
      workerCount: 2,
      maxConcurrency: 1,
      backend: 'inline',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.DATA_UPLOAD)
    }));
  }

  private createPool(config: SDKPoolConfig): DedicatedPoolState {
    return {
      pool: config.pool,
      workerCount: Math.max(1, config.workerCount),
      maxConcurrency: Math.max(1, config.maxConcurrency),
      backend: config.backend,
      workerInfo: config.workerInfo,
      queue: [],
      workerSlots: [],
      workerInitAttempted: false,
      inlineState: createSDKWorkerRuntimeState(config.pool, `${config.workerInfo.workerName}InlineFallback`),
      running: 0,
      submittedTasks: 0,
      completedTasks: 0,
      failedTasks: 0,
      queuedTasks: 0,
      totalWaitTime: 0,
      totalCostTime: 0,
      lastError: '',
      restartCount: 0,
      isShutdown: false
    };
  }

  private getPool(pool: SDKDedicatedPoolType): DedicatedPoolState {
    let state = this.pools.get(pool);
    if (!state) {
      state = this.createPool({
        pool,
        workerCount: 1,
        maxConcurrency: 1,
        backend: 'inline',
        workerInfo: SDKWorkerPathResolver.getWorkerInfo(pool)
      });
      this.pools.set(pool, state);
    }
    return state;
  }

  private processPool(state: DedicatedPoolState): void {
    while (!state.isShutdown && state.running < state.maxConcurrency && state.queue.length > 0) {
      const task = this.pollNextTask(state);
      state.running++;
      this.runQueuedTask(state, task);
    }
  }

  private pollNextTask(state: DedicatedPoolState): QueuedPoolTask {
    let bestIndex = 0;
    let bestTask = state.queue[0];
    for (let i = 1; i < state.queue.length; i++) {
      const task = state.queue[i];
      if (task.priority > bestTask.priority || (task.priority === bestTask.priority && task.createdAt < bestTask.createdAt)) {
        bestTask = task;
        bestIndex = i;
      }
    }
    return state.queue.splice(bestIndex, 1)[0];
  }

  private async runQueuedTask(state: DedicatedPoolState, task: QueuedPoolTask): Promise<void> {
    const startTime = Date.now();
    const waitTime = Math.max(0, startTime - task.createdAt);
    state.totalWaitTime += waitTime;
    this.activePoolStack.push(state.pool);

    try {
      await Promise.resolve(task.run());
      state.completedTasks++;
      task.resolve();
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      state.failedTasks++;
      state.lastError = normalized.message;
      task.reject(normalized);
    } finally {
      this.activePoolStack.pop();
      state.totalCostTime += Math.max(0, Date.now() - startTime);
      state.running = Math.max(0, state.running - 1);
      this.processPool(state);
    }
  }

  private async dispatchWorkerCommand(
    request: SDKWorkerRequest,
    runner?: SDKDedicatedCommandRunner
  ): Promise<SDKWorkerResponse> {
    const state = this.getPool(request.pool);
    try {
      if (SDKDedicatedPoolManager.workerCommandTimeoutMs <= 1) {
        throw new Error(`ThreadWorker command disabled for ${state.pool}`);
      }
      return await this.dispatchThreadWorkerCommand(state, request);
    } catch (error) {
      const fallbackError = error instanceof Error ? error : new Error(String(error));
      state.backend = 'fallback';
      state.lastError = fallbackError.message;
      if (runner) {
        return await this.runInlineCommandRunner(request, runner);
      }
      return handleSDKWorkerRequest(request, state.inlineState);
    }
  }

  private async runInlineCommandRunner(
    request: SDKWorkerRequest,
    runner: SDKDedicatedCommandRunner
  ): Promise<SDKWorkerResponse> {
    try {
      const payload = await Promise.resolve(runner());
      assertSDKWorkerRequestSerializable({
        id: request.id,
        pool: request.pool,
        command: `${request.command}.response`,
        priority: request.priority,
        createdAt: Date.now(),
        payload
      });
      return {
        id: request.id,
        ok: true,
        payload
      };
    } catch (error) {
      const errorDTO = toSDKWorkerErrorDTO(error);
      const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
      return {
        id: request.id,
        ok: false,
        errorMessage: errorDTO.message,
        payload: errorPayload
      };
    }
  }

  private dispatchThreadWorkerCommand(
    state: DedicatedPoolState,
    request: SDKWorkerRequest
  ): Promise<SDKWorkerResponse> {
    this.ensureThreadWorkers(state);
    const slot = this.findAvailableWorkerSlot(state);
    if (!slot || !slot.workerInstance) {
      throw new Error(`No available ThreadWorker for ${state.pool}`);
    }

    slot.busy = true;
    return new Promise<SDKWorkerResponse>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        const pending = slot.pending;
        if (!pending || pending.requestId !== request.id) {
          return;
        }
        slot.busy = false;
        slot.pending = null;
        this.terminateWorkerSlot(slot);
        state.backend = 'fallback';
        reject(new Error(`ThreadWorker command timeout: ${state.pool}/${request.command}`));
      }, SDKDedicatedPoolManager.workerCommandTimeoutMs);
      slot.pending = {
        requestId: request.id,
        timeoutId,
        resolve,
        reject
      };
      try {
        slot.workerInstance!.postMessage(request);
      } catch (error) {
        clearTimeout(timeoutId);
        slot.busy = false;
        slot.pending = null;
        const normalized = error instanceof Error ? error : new Error(String(error));
        reject(normalized);
      }
    });
  }

  private ensureThreadWorkers(state: DedicatedPoolState): void {
    if (state.workerSlots.length > 0 && state.backend === 'thread-worker') {
      return;
    }
    if (state.workerInitAttempted && state.workerSlots.length === 0) {
      throw new Error(state.lastError || `ThreadWorker unavailable for ${state.pool}`);
    }

    state.workerInitAttempted = true;
    state.workerSlots = [];
    for (let i = 0; i < state.workerCount; i++) {
      const slot: SDKThreadWorkerSlot = {
        index: i,
        workerInstance: null,
        scriptUrl: '',
        busy: false,
        pending: null,
        restartCount: 0
      };
      this.createThreadWorkerForSlot(state, slot);
      if (slot.workerInstance) {
        state.workerSlots.push(slot);
      }
    }

    if (state.workerSlots.length === 0) {
      state.backend = 'fallback';
      throw new Error(state.lastError || `ThreadWorker initialization failed for ${state.pool}`);
    }
    state.backend = 'thread-worker';
  }

  private createThreadWorkerForSlot(state: DedicatedPoolState, slot: SDKThreadWorkerSlot): void {
    const candidates = state.workerInfo.scriptUrlCandidates;
    let lastError = '';
    for (let i = 0; i < candidates.length; i++) {
      const scriptUrl = candidates[i];
      try {
        const workerInstance = new worker.ThreadWorker(scriptUrl);
        workerInstance.onmessage = (event: MessageEvents) => {
          this.handleThreadWorkerMessage(state, slot, event);
        };
        workerInstance.onerror = (event: ErrorEvent) => {
          this.handleThreadWorkerFailure(state, slot, `Worker error: ${String(event)}`);
        };
        workerInstance.onexit = (code: number) => {
          if (code !== 0) {
            this.handleThreadWorkerFailure(state, slot, `Worker exited with code ${code}`);
          }
        };
        slot.workerInstance = workerInstance;
        slot.scriptUrl = scriptUrl;
        state.lastError = '';
        return;
      } catch (error) {
        const normalized = error instanceof Error ? error : new Error(String(error));
        lastError = `${scriptUrl}: ${normalized.message}`;
      }
    }
    state.lastError = lastError;
  }

  private handleThreadWorkerMessage(
    state: DedicatedPoolState,
    slot: SDKThreadWorkerSlot,
    event: MessageEvents
  ): void {
    const eventRecord = event as Object as SDKThreadWorkerResponseMessage;
    const response = eventRecord.data as SDKWorkerResponse;
    const pending = slot.pending;
    slot.busy = false;
    slot.pending = null;
    if (!pending) {
      return;
    }
    clearTimeout(pending.timeoutId);
    if (!response || response.id !== pending.requestId) {
      pending.reject(new Error(`Unexpected worker response for ${state.pool}`));
      return;
    }
    pending.resolve(response);
  }

  private handleThreadWorkerFailure(
    state: DedicatedPoolState,
    slot: SDKThreadWorkerSlot,
    message: string
  ): void {
    state.lastError = message;
    const pending = slot.pending;
    slot.busy = false;
    slot.pending = null;
    this.terminateWorkerSlot(slot);
    if (pending) {
      clearTimeout(pending.timeoutId);
      pending.reject(new Error(message));
    }
    if (slot.restartCount < 1 && !state.isShutdown) {
      slot.restartCount++;
      state.restartCount++;
      this.createThreadWorkerForSlot(state, slot);
    }
    if (!slot.workerInstance) {
      state.backend = 'fallback';
    }
  }

  private findAvailableWorkerSlot(state: DedicatedPoolState): SDKThreadWorkerSlot | null {
    for (let i = 0; i < state.workerSlots.length; i++) {
      const slot = state.workerSlots[i];
      if (!slot.busy && slot.workerInstance) {
        return slot;
      }
    }
    return null;
  }

  private terminateWorkerSlot(slot: SDKThreadWorkerSlot): void {
    if (slot.pending) {
      clearTimeout(slot.pending.timeoutId);
      slot.pending.reject(new Error('ThreadWorker terminated'));
      slot.pending = null;
    }
    slot.busy = false;
    if (slot.workerInstance) {
      try {
        slot.workerInstance.terminate();
      } catch (_) {
      }
      slot.workerInstance = null;
    }
  }

  private async runReentrantTask(
    state: DedicatedPoolState,
    id: string,
    name: string,
    runner: SDKDedicatedTaskRunner
  ): Promise<void> {
    const startTime = Date.now();
    this.activePoolStack.push(state.pool);
    try {
      await Promise.resolve(runner());
      state.completedTasks++;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      state.failedTasks++;
      state.lastError = `${name}(${id}): ${normalized.message}`;
      throw normalized;
    } finally {
      this.activePoolStack.pop();
      state.totalCostTime += Math.max(0, Date.now() - startTime);
    }
  }

  private executeScheduledUpload(): void {
    const task = this.uploadTask;
    if (!task) {
      this.uploadScheduled = false;
      this.uploadScheduledAt = 0;
      this.uploadScheduledDelay = 0;
      return;
    }

    this.uploadScheduled = false;
    this.uploadScheduledAt = 0;
    this.uploadScheduledDelay = 0;
    this.uploadRunning = true;
    this.uploadRunningTaskId = task.id;

    Promise.resolve(task.run()).catch((error: Error) => {
      const state = this.getPool(SDKDedicatedPoolType.DATA_UPLOAD);
      state.lastError = `${task.name}: ${error.message}`;
    }).finally(() => {
      this.uploadRunning = false;
      this.uploadRunningTaskId = '';
      this.uploadTask = null;
      if (this.uploadNeedReschedule) {
        const nextDelay = this.uploadRescheduleDelay;
        this.uploadNeedReschedule = false;
        this.uploadRescheduleDelay = 0;
        this.scheduleDataUpload(task.name, task.run, nextDelay);
      } else {
        this.uploadNeedReschedule = false;
        this.uploadRescheduleDelay = 0;
      }
    });
  }

  private clearUploadTimer(): void {
    if (this.uploadTimer >= 0) {
      clearTimeout(this.uploadTimer);
      this.uploadTimer = -1;
    }
  }

  private getPoolStatus(state: DedicatedPoolState): SDKDedicatedPoolStatus {
    const processed = state.completedTasks + state.failedTasks;
    return {
      pool: state.pool,
      backend: state.backend,
      workerPath: this.getActiveWorkerPath(state),
      workerCount: state.workerCount,
      maxConcurrency: state.maxConcurrency,
      pending: state.queue.length,
      running: state.running,
      submittedTasks: state.submittedTasks,
      completedTasks: state.completedTasks,
      failedTasks: state.failedTasks,
      queuedTasks: state.queuedTasks,
      totalWaitTime: state.totalWaitTime,
      totalCostTime: state.totalCostTime,
      averageWaitTime: processed > 0 ? state.totalWaitTime / processed : 0,
      averageCostTime: processed > 0 ? state.totalCostTime / processed : 0,
      lastError: state.lastError,
      restartCount: state.restartCount,
      isShutdown: state.isShutdown
    };
  }

  private getActiveWorkerPath(state: DedicatedPoolState): string {
    for (let i = 0; i < state.workerSlots.length; i++) {
      if (state.workerSlots[i].scriptUrl.length > 0) {
        return state.workerSlots[i].scriptUrl;
      }
    }
    return state.workerInfo.sourceOptionPath;
  }

  private isExecutingPool(pool: SDKDedicatedPoolType): boolean {
    return this.activePoolStack.length > 0 && this.activePoolStack[this.activePoolStack.length - 1] === pool;
  }

  private nextInternalTaskId(pool: SDKDedicatedPoolType, name: string): string {
    this.nextTaskId++;
    return `${pool}_${name}_${Date.now()}_${this.nextTaskId}`;
  }

  private resolveDataProcessWorkerCount(): number {
    // HarmonyOS ArkTS does not expose a stable CPU-count API across all target
    // versions used by this SDK. Keep the Android-aligned strategy centralized
    // here so a platform-specific CPU probe can replace this fallback later.
    return 2;
  }
}
