import {
  assertSDKWorkerRequestSerializable,
  SDKDedicatedPoolType,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerCommand,
  SDKWorkerRequest,
  SDKWorkerResponse,
  SDKWorkerTiming,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from './SDKWorkerProtocol';
import {
  SDKWorkerPathInfo,
  SDKWorkerPathResolver
} from './SDKWorkerPathResolver';
import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';

const TAG = "SDKDedicatedPoolManager";
const DEFAULT_WORKER_COMMAND_TIMEOUT_MS = 3000;
const DATA_UPLOAD_WORKER_COMMAND_TIMEOUT_MS = 60000;
const DATA_UPLOAD_HTTP_HARD_TIMEOUT_MS = 135000;
const DEDICATED_LANE_WORKER_COUNT = 1;
const POOL_QUEUE_COMPACT_THRESHOLD = 64;

export interface SDKDedicatedPoolStatus {
  pool: string;
  backend: string;
  workerPath: string;
  workerCount: number;
  maxConcurrency: number;
  pending: number;
  hostQueuePending: number;
  mailboxPending: number;
  running: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  mailboxSubmittedTasks: number;
  mailboxCompletedTasks: number;
  mailboxFailedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  averageWaitTime: number;
  averageCostTime: number;
  lastError: string;
  restartCount: number;
  isShutdown: boolean;
}

export interface SDKDedicatedPoolManagerStatus {
  pools: Record<string, SDKDedicatedPoolStatus>;
}

export type SDKMailboxResponseHandler = (response: SDKWorkerResponse) => void;

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

interface SDKThreadWorkerMessage {
  data: object | string | number | boolean | null | undefined;
}

interface SDKThreadWorkerPendingCommand {
  requestId: string;
  timeoutId: number;
  resolve: (response: SDKWorkerResponse) => void;
  reject: (error: Error) => void;
}

interface SDKThreadWorkerMailboxAwaiter {
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
  createdAt: number;
  request: SDKWorkerRequest;
  resolve: (response: SDKWorkerResponse) => void;
  reject: (error: Error) => void;
}

interface DedicatedPoolState extends SDKPoolConfig {
  queue: QueuedPoolTask[];
  queueHeadIndex: number;
  workerSlots: SDKThreadWorkerSlot[];
  workerInitAttempted: boolean;
  running: number;
  submittedTasks: number;
  completedTasks: number;
  failedTasks: number;
  queuedTasks: number;
  mailboxSubmittedTasks: number;
  mailboxCompletedTasks: number;
  mailboxFailedTasks: number;
  totalWaitTime: number;
  totalCostTime: number;
  lastError: string;
  restartCount: number;
  isShutdown: boolean;
}

/**
 * Internal manager for Android-aligned dedicated pools.
 *
 * Command tasks use long-lived ThreadWorker instances when the runtime can load
 * the worker scripts. The manager keeps queueing, serial/concurrent limits,
 * DTO validation, and restart-once handling behind the same producer-facing
 * entry points. It never stores or executes business closures.
 */
export class SDKDedicatedPoolManager {
  private static instance: SDKDedicatedPoolManager | null = null;
  private static workerCommandTimeoutMs: number = DEFAULT_WORKER_COMMAND_TIMEOUT_MS;
  private pools: Map<SDKDedicatedPoolType, DedicatedPoolState> = new Map();
  private mailboxResponseHandlers: Map<SDKDedicatedPoolType, SDKMailboxResponseHandler> = new Map();
  private mailboxAwaiters: Map<string, SDKThreadWorkerMailboxAwaiter> = new Map();
  private nextTaskId: number = 0;

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

  private enqueueWorkerRequest(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const state = this.getPool(request.pool);
    if (state.isShutdown) {
      return Promise.reject(new Error(`SDK dedicated pool has been shut down: ${request.pool}`));
    }
    assertSDKWorkerRequestSerializable(request);

    return new Promise<SDKWorkerResponse>((resolve, reject) => {
      const task: QueuedPoolTask = {
        createdAt: Date.now(),
        request,
        resolve,
        reject
      };

      state.submittedTasks++;
      state.queue.push(task);
      if (state.running > 0) {
        state.queuedTasks++;
      }
      this.processPool(state);
    });
  }

  public executeCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    assertSDKWorkerRequestSerializable(request);

    return this.enqueueWorkerRequest(request).catch((error: Error) => {
      return this.createCommandErrorResponse(request, error, {
        poolWaitMs: 0,
        poolExecuteMs: 0
      });
    });
  }

  public postCommand(request: SDKWorkerRequest): boolean {
    try {
      this.assertMailboxRequestEnvelope(request);
      const state = this.getPool(request.pool);
      if (state.isShutdown) {
        state.failedTasks++;
        state.mailboxFailedTasks++;
        state.lastError = `SDK dedicated pool has been shut down: ${request.pool}`;
        return false;
      }
      this.dispatchThreadWorkerMailboxCommand(state, request);
      state.submittedTasks++;
      state.mailboxSubmittedTasks++;
      if (state.backend === 'thread-worker') {
        state.backend = 'thread-worker-mailbox';
      }
      return true;
    } catch (error) {
      const state = this.getPool(request.pool);
      const normalized = error instanceof Error ? error : new Error(String(error));
      state.failedTasks++;
      state.mailboxFailedTasks++;
      state.lastError = normalized.message;
      return false;
    }
  }

  public postCommandAndWait(request: SDKWorkerRequest, timeoutMs: number): Promise<SDKWorkerResponse> {
    assertSDKWorkerRequestSerializable(request);
    const normalizedTimeout = Math.max(1, timeoutMs);
    return new Promise<SDKWorkerResponse>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        this.mailboxAwaiters.delete(request.id);
        reject(new Error(`ThreadWorker mailbox command timeout: ${request.pool}/${request.command}`));
      }, normalizedTimeout);
      this.mailboxAwaiters.set(request.id, {
        timeoutId,
        resolve,
        reject
      });

      const posted = this.postCommand(request);
      if (!posted) {
        clearTimeout(timeoutId);
        this.mailboxAwaiters.delete(request.id);
        const state = this.getPool(request.pool);
        reject(new Error(state.lastError || `ThreadWorker mailbox post failed: ${request.pool}/${request.command}`));
      }
    });
  }

  private assertMailboxRequestEnvelope(request: SDKWorkerRequest): void {
    if (!request || !request.id || !request.pool || !request.command) {
      throw new Error('SDK worker mailbox request is missing id, pool, or command');
    }
  }

  public setMailboxResponseHandler(pool: SDKDedicatedPoolType, handler: SDKMailboxResponseHandler | null): void {
    if (handler) {
      this.mailboxResponseHandlers.set(pool, handler);
    } else {
      this.mailboxResponseHandlers.delete(pool);
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

  public getDataProcessWorkerCount(): number {
    return this.getCoreWorkerCount();
  }

  public getCoreWorkerCount(): number {
    return this.getPool(SDKDedicatedPoolType.DATA_PROCESS).workerCount;
  }

  public getPoolMaxConcurrency(pool: SDKDedicatedPoolType): number {
    return this.getPool(pool).maxConcurrency;
  }

  public getPoolRestartCount(pool: SDKDedicatedPoolType): number {
    return this.getPool(pool).restartCount;
  }

  public configurePoolMaxConcurrency(pool: SDKDedicatedPoolType, maxConcurrency: number): void {
    const state = this.getPool(pool);
    state.maxConcurrency = this.normalizePoolMaxConcurrency(state, maxConcurrency);
    this.processPool(state);
  }

  public getStatus(): SDKDedicatedPoolManagerStatus {
    const pools: Record<string, SDKDedicatedPoolStatus> = {};
    this.pools.forEach((state, pool) => {
      pools[pool] = this.getPoolStatus(state);
    });

    return {
      pools
    };
  }

  public shutdownNow(): void {
    this.mailboxAwaiters.forEach((awaiter) => {
      clearTimeout(awaiter.timeoutId);
      awaiter.reject(new Error('SDK dedicated pool has been shut down'));
    });
    this.mailboxAwaiters.clear();
    this.pools.forEach((state) => {
      state.isShutdown = true;
      for (let i = state.queueHeadIndex; i < state.queue.length; i++) {
        state.queue[i].reject(new Error(`SDK dedicated pool has been shut down: ${state.pool}`));
      }
      state.queue = [];
      state.queueHeadIndex = 0;
      state.running = 0;
      for (let i = 0; i < state.workerSlots.length; i++) {
        this.terminateWorkerSlot(state.workerSlots[i]);
      }
    });
  }

  private initializePools(): void {
    const coreWorkers = this.resolveCoreWorkerCount();
    this.pools.set(SDKDedicatedPoolType.EVENT_CONSUMER, this.createPool({
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.EVENT_CONSUMER)
    }));
    this.pools.set(SDKDedicatedPoolType.LOG_CONSUMER, this.createPool({
      pool: SDKDedicatedPoolType.LOG_CONSUMER,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.LOG_CONSUMER)
    }));
    this.pools.set(SDKDedicatedPoolType.DATA_PROCESS, this.createPool({
      pool: SDKDedicatedPoolType.DATA_PROCESS,
      workerCount: coreWorkers,
      maxConcurrency: coreWorkers,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.DATA_PROCESS)
    }));
    this.pools.set(SDKDedicatedPoolType.CRASH_FILE, this.createPool({
      pool: SDKDedicatedPoolType.CRASH_FILE,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.CRASH_FILE)
    }));
    this.pools.set(SDKDedicatedPoolType.ANR, this.createPool({
      pool: SDKDedicatedPoolType.ANR,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.ANR)
    }));
    this.pools.set(SDKDedicatedPoolType.BACKGROUND, this.createPool({
      pool: SDKDedicatedPoolType.BACKGROUND,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.BACKGROUND)
    }));
    this.pools.set(SDKDedicatedPoolType.DATA_UPLOAD, this.createPool({
      pool: SDKDedicatedPoolType.DATA_UPLOAD,
      // Upload round/checkpoint state is intentionally single-owner. Keeping
      // one Worker slot also guarantees that start/execute/commit/finish for a
      // round cannot be dispatched to different runtime states.
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.DATA_UPLOAD)
    }));
  }

  private createPool(config: SDKPoolConfig): DedicatedPoolState {
    return {
      pool: config.pool,
      workerCount: Math.max(1, config.workerCount),
      maxConcurrency: this.normalizePoolMaxConcurrency(config, config.maxConcurrency),
      backend: config.backend,
      workerInfo: config.workerInfo,
      queue: [],
      queueHeadIndex: 0,
      workerSlots: [],
      workerInitAttempted: false,
      running: 0,
      submittedTasks: 0,
      completedTasks: 0,
      failedTasks: 0,
      queuedTasks: 0,
      mailboxSubmittedTasks: 0,
      mailboxCompletedTasks: 0,
      mailboxFailedTasks: 0,
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
        backend: 'thread-worker-pending',
        workerInfo: SDKWorkerPathResolver.getWorkerInfo(pool)
      });
      this.pools.set(pool, state);
    }
    return state;
  }

  private processPool(state: DedicatedPoolState): void {
    while (!state.isShutdown && state.running < state.maxConcurrency && this.getPendingQueueLength(state) > 0) {
      const task = this.pollNextTask(state);
      state.running++;
      this.runQueuedTask(state, task);
    }
  }

  private pollNextTask(state: DedicatedPoolState): QueuedPoolTask {
    const task = state.queue[state.queueHeadIndex];
    state.queueHeadIndex++;
    this.compactPoolQueue(state);
    return task;
  }

  private getPendingQueueLength(state: DedicatedPoolState): number {
    return Math.max(0, state.queue.length - state.queueHeadIndex);
  }

  private compactPoolQueue(state: DedicatedPoolState): void {
    if (state.queueHeadIndex === 0) {
      return;
    }
    if (state.queueHeadIndex >= state.queue.length) {
      state.queue = [];
      state.queueHeadIndex = 0;
      return;
    }
    if (state.queueHeadIndex >= POOL_QUEUE_COMPACT_THRESHOLD && state.queueHeadIndex * 2 >= state.queue.length) {
      state.queue = state.queue.slice(state.queueHeadIndex);
      state.queueHeadIndex = 0;
    }
  }

  private async runQueuedTask(state: DedicatedPoolState, task: QueuedPoolTask): Promise<void> {
    const startTime = Date.now();
    const waitTime = Math.max(0, startTime - task.createdAt);
    state.totalWaitTime += waitTime;

    try {
      const response = await this.dispatchWorkerCommand(task.request);
      const timedResponse = this.withWorkerTiming(response, {
        poolWaitMs: waitTime,
        poolExecuteMs: Math.max(0, Date.now() - startTime)
      });
      if (response.ok) {
        state.completedTasks++;
      } else {
        state.failedTasks++;
        state.lastError = response.errorMessage || `Worker command failed: ${task.request.command}`;
      }
      task.resolve(timedResponse);
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      state.failedTasks++;
      state.lastError = normalized.message;
      task.resolve(this.createCommandErrorResponse(task.request, normalized, {
        poolWaitMs: waitTime,
        poolExecuteMs: Math.max(0, Date.now() - startTime)
      }));
    } finally {
      state.totalCostTime += Math.max(0, Date.now() - startTime);
      state.running = Math.max(0, state.running - 1);
      this.processPool(state);
    }
  }

  private createCommandErrorResponse(
    request: SDKWorkerRequest,
    error: Error,
    timing: SDKWorkerTiming
  ): SDKWorkerResponse {
    const errorDTO = toSDKWorkerErrorDTO(error);
    const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
    return this.withWorkerTiming({
      id: request.id,
      ok: false,
      errorMessage: errorDTO.message,
      payload: errorPayload
    }, timing);
  }

  private async dispatchWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const state = this.getPool(request.pool);
    try {
      if (SDKDedicatedPoolManager.workerCommandTimeoutMs <= 1) {
        throw new Error(`ThreadWorker command disabled for ${state.pool}`);
      }
      return await this.dispatchThreadWorkerCommand(state, request);
    } catch (error) {
      const fallbackError = error instanceof Error ? error : new Error(String(error));
      state.backend = 'thread-worker-error';
      state.lastError = fallbackError.message;
      throw fallbackError;
    }
  }

  private withWorkerTiming(response: SDKWorkerResponse, timing: SDKWorkerTiming): SDKWorkerResponse {
    return {
      id: response.id,
      ok: response.ok,
      payload: response.payload,
      errorMessage: response.errorMessage,
      metrics: this.mergeWorkerTiming(response.metrics, timing)
    };
  }

  private mergeWorkerTiming(
    current: SDKWorkerTiming | undefined,
    next: SDKWorkerTiming
  ): SDKWorkerTiming {
    const merged: SDKWorkerTiming = {};
    if (current) {
      merged.schedulerWaitMs = current.schedulerWaitMs;
      merged.schedulerComputeMs = current.schedulerComputeMs;
      merged.schedulerExecuteMs = current.schedulerExecuteMs;
      merged.poolWaitMs = current.poolWaitMs;
      merged.poolExecuteMs = current.poolExecuteMs;
    }
    if (next.schedulerWaitMs !== undefined) {
      merged.schedulerWaitMs = next.schedulerWaitMs;
    }
    if (next.schedulerComputeMs !== undefined) {
      merged.schedulerComputeMs = next.schedulerComputeMs;
    }
    if (next.schedulerExecuteMs !== undefined) {
      merged.schedulerExecuteMs = next.schedulerExecuteMs;
    }
    if (next.poolWaitMs !== undefined) {
      merged.poolWaitMs = next.poolWaitMs;
    }
    if (next.poolExecuteMs !== undefined) {
      merged.poolExecuteMs = next.poolExecuteMs;
    }
    return merged;
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
      const commandTimeoutMs = this.getWorkerCommandTimeoutMs(request);
      const timeoutId = setTimeout(() => {
        const pending = slot.pending;
        if (!pending || pending.requestId !== request.id) {
          return;
        }
        slot.busy = false;
        slot.pending = null;
        this.terminateWorkerSlot(slot);
        state.backend = 'thread-worker-error';
        reject(new Error(`ThreadWorker command timeout: ${state.pool}/${request.command}`));
      }, commandTimeoutMs);
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

  private dispatchThreadWorkerMailboxCommand(state: DedicatedPoolState, request: SDKWorkerRequest): void {
    this.ensureThreadWorkers(state);
    const slot = this.findMailboxWorkerSlot(state);
    if (!slot || !slot.workerInstance) {
      throw new Error(`No available ThreadWorker mailbox for ${state.pool}`);
    }

    try {
      slot.workerInstance.postMessage(request);
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      throw normalized;
    }
  }

  private getWorkerCommandTimeoutMs(request: SDKWorkerRequest): number {
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE) {
      return Math.max(
        SDKDedicatedPoolManager.workerCommandTimeoutMs,
        DATA_UPLOAD_HTTP_HARD_TIMEOUT_MS
      );
    }
    if (request.command === SDKWorkerCommand.UPLOAD_CONSUME) {
      return Math.max(
        SDKDedicatedPoolManager.workerCommandTimeoutMs,
        DATA_UPLOAD_WORKER_COMMAND_TIMEOUT_MS
      );
    }
    return SDKDedicatedPoolManager.workerCommandTimeoutMs;
  }

  private ensureThreadWorkers(state: DedicatedPoolState): void {
    if (state.workerSlots.length > 0 && this.isActiveThreadWorkerBackend(state.backend)) {
      return;
    }
    if (state.workerInitAttempted && state.workerSlots.length === 0) {
      throw new Error(state.lastError || `ThreadWorker unavailable for ${state.pool}`);
    }

    state.workerInitAttempted = true;
    state.workerSlots = [];
    const targetWorkerCount = Math.min(state.workerCount, state.maxConcurrency);
    for (let i = 0; i < targetWorkerCount; i++) {
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
      state.backend = 'thread-worker-error';
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
    const eventRecord = event as Object as SDKThreadWorkerMessage;
    const response = eventRecord.data as Object as SDKWorkerResponse;
    const pending = slot.pending;
    if (pending && response && response.id === pending.requestId) {
      slot.busy = false;
      slot.pending = null;
      clearTimeout(pending.timeoutId);
      pending.resolve(response);
      return;
    }

    this.handleMailboxWorkerResponse(state, response);
  }

  private handleMailboxWorkerResponse(state: DedicatedPoolState, response: SDKWorkerResponse): void {
    if (!response) {
      state.failedTasks++;
      state.mailboxFailedTasks++;
      state.lastError = `Empty worker mailbox response for ${state.pool}`;
      return;
    }

    if (response.ok) {
      state.completedTasks++;
      state.mailboxCompletedTasks++;
    } else {
      state.failedTasks++;
      state.mailboxFailedTasks++;
      state.lastError = response.errorMessage || `Worker mailbox command failed: ${response.id}`;
    }

    const handler = this.mailboxResponseHandlers.get(state.pool);
    if (handler) {
      handler(response);
    }

    const awaiter = this.mailboxAwaiters.get(response.id);
    if (awaiter) {
      clearTimeout(awaiter.timeoutId);
      this.mailboxAwaiters.delete(response.id);
      awaiter.resolve(response);
    }
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
      state.backend = 'thread-worker-error';
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

  private isActiveThreadWorkerBackend(backend: string): boolean {
    return backend === 'thread-worker' || backend === 'thread-worker-mailbox';
  }

  private findMailboxWorkerSlot(state: DedicatedPoolState): SDKThreadWorkerSlot | null {
    for (let i = 0; i < state.workerSlots.length; i++) {
      const slot = state.workerSlots[i];
      if (slot.workerInstance) {
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

  private getPoolStatus(state: DedicatedPoolState): SDKDedicatedPoolStatus {
    const processed = state.completedTasks + state.failedTasks;
    const hostQueuePending = this.getPendingQueueLength(state);
    const mailboxPending = Math.max(
      0,
      state.mailboxSubmittedTasks - state.mailboxCompletedTasks - state.mailboxFailedTasks
    );
    return {
      pool: state.pool,
      backend: state.backend,
      workerPath: this.getActiveWorkerPath(state),
      workerCount: state.workerCount,
      maxConcurrency: state.maxConcurrency,
      pending: hostQueuePending,
      hostQueuePending,
      mailboxPending,
      running: state.running,
      submittedTasks: state.submittedTasks,
      completedTasks: state.completedTasks,
      failedTasks: state.failedTasks,
      queuedTasks: state.queuedTasks,
      mailboxSubmittedTasks: state.mailboxSubmittedTasks,
      mailboxCompletedTasks: state.mailboxCompletedTasks,
      mailboxFailedTasks: state.mailboxFailedTasks,
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

  private nextInternalTaskId(pool: SDKDedicatedPoolType, name: string): string {
    this.nextTaskId++;
    return `${pool}_${name}_${Date.now()}_${this.nextTaskId}`;
  }

  private resolveCoreWorkerCount(): number {
    return DEDICATED_LANE_WORKER_COUNT;
  }

  private normalizePoolMaxConcurrency(config: SDKPoolConfig, maxConcurrency: number): number {
    const workerCount = Math.max(1, config.workerCount);
    return Math.max(1, Math.min(workerCount, maxConcurrency));
  }
}
