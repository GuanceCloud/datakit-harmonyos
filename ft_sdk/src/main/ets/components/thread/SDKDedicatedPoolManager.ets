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
import {
  isSDKWorkerInFlightReplaySafe,
  isSDKWorkerMailboxReplaySafe,
  SDK_WORKER_MAILBOX_REPLAY_CAPACITY,
  SDK_WORKER_MAX_MESSAGE_REPLAY_ATTEMPTS,
  SDK_WORKER_MAX_RESTART_ATTEMPTS
} from './SDKWorkerReplayPolicy';
import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';

const TAG = "SDKDedicatedPoolManager";
const DEFAULT_WORKER_COMMAND_TIMEOUT_MS = 3000;
const DATA_UPLOAD_WORKER_COMMAND_TIMEOUT_MS = 60000;
const DATA_UPLOAD_HTTP_HARD_TIMEOUT_MS = 135000;
const ANR_PARSE_COMMAND_TIMEOUT_MS = 15000;
const BACKGROUND_METRICS_COMMAND_TIMEOUT_MS = 5000;
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
  commandReplayCount: number;
  mailboxReplayCount: number;
  mailboxReplayPending: number;
  mailboxReplayDropped: number;
  isShutdown: boolean;
}

export interface SDKDedicatedPoolManagerStatus {
  pools: Record<string, SDKDedicatedPoolStatus>;
}

export type SDKMailboxResponseHandler = (response: SDKWorkerResponse) => void;
export type SDKWorkerRecoveryHandler = (restartCount: number) => void;

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

interface SDKMailboxReplayEntry {
  request: SDKWorkerRequest;
  replayCount: number;
  replaySafe: boolean;
  timeoutId: number;
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
  commandReplayCount: number;
  mailboxReplayCount: number;
  mailboxReplayDropped: number;
  mailboxReplayEntries: Map<string, SDKMailboxReplayEntry>;
  mailboxReplayOrder: string[];
  lineContextCheckpoint: SDKWorkerRequest | null;
  recoveryResponseIds: Map<string, boolean>;
  isShutdown: boolean;
}

/**
 * Internal manager for Android-aligned dedicated pools.
 *
 * Command tasks use long-lived ThreadWorker instances when the runtime can load
 * the worker scripts. The manager keeps queueing, serial/concurrent limits,
 * DTO validation, bounded restart/replay handling behind the same producer-facing
 * entry points. It never stores or executes business closures.
 */
export class SDKDedicatedPoolManager {
  private static instance: SDKDedicatedPoolManager | null = null;
  private static workerCommandTimeoutMs: number = DEFAULT_WORKER_COMMAND_TIMEOUT_MS;
  private pools: Map<SDKDedicatedPoolType, DedicatedPoolState> = new Map();
  private mailboxResponseHandlers: Map<SDKDedicatedPoolType, SDKMailboxResponseHandler> = new Map();
  private workerRecoveryHandlers: Map<SDKDedicatedPoolType, SDKWorkerRecoveryHandler> = new Map();
  private mailboxAwaiters: Map<string, SDKThreadWorkerMailboxAwaiter> = new Map();
  private nextTaskId: number = 0;
  private forcedMailboxPostFailureCount: number = 0;

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
      if (this.forcedMailboxPostFailureCount > 0) {
        this.forcedMailboxPostFailureCount--;
        state.failedTasks++;
        state.mailboxFailedTasks++;
        state.lastError = `Injected mailbox post failure: ${request.pool}/${request.command}`;
        return false;
      }
      if (state.isShutdown) {
        state.failedTasks++;
        state.mailboxFailedTasks++;
        state.lastError = `SDK dedicated pool has been shut down: ${request.pool}`;
        return false;
      }
      this.trackMailboxRequestForReplay(state, request);
      this.dispatchThreadWorkerMailboxCommand(state, request);
      if (request.command === SDKWorkerCommand.LINE_CONTEXT_UPDATE) {
        state.lineContextCheckpoint = request;
      }
      state.submittedTasks++;
      state.mailboxSubmittedTasks++;
      if (state.backend === 'thread-worker') {
        state.backend = 'thread-worker-mailbox';
      }
      return true;
    } catch (error) {
      const state = this.getPool(request.pool);
      this.removeMailboxReplayEntry(state, request.id);
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

  /**
   * Registers a Host-owned semantic recovery hook. The hook runs after line
   * context restoration and before unresolved mailbox messages are replayed.
   */
  public setWorkerRecoveryHandler(pool: SDKDedicatedPoolType, handler: SDKWorkerRecoveryHandler | null): void {
    if (handler) {
      this.workerRecoveryHandlers.set(pool, handler);
    } else {
      this.workerRecoveryHandlers.delete(pool);
    }
  }

  /** Internal deterministic seam for mailbox loss regression tests. */
  public failNextMailboxPostsInternal(count: number = 1): void {
    this.forcedMailboxPostFailureCount = Math.max(0, Math.floor(count));
  }

  /** Terminates one production Worker and exercises the normal replay path. */
  public restartWorkerInternal(pool: SDKDedicatedPoolType): boolean {
    const state = this.getPool(pool);
    const slot = this.findMailboxWorkerSlot(state);
    if (!slot || !slot.workerInstance || state.isShutdown) {
      return false;
    }
    this.handleThreadWorkerFailure(state, slot, `Injected Worker restart: ${pool}`);
    return slot.workerInstance !== null;
  }

  public probeDedicatedWorkers(): Promise<SDKWorkerResponse[]> {
    const pools: SDKDedicatedPoolType[] = [
      SDKDedicatedPoolType.EVENT_CONSUMER,
      SDKDedicatedPoolType.LOG_CONSUMER,
      SDKDedicatedPoolType.DATA_PROCESS,
      SDKDedicatedPoolType.ANR,
      SDKDedicatedPoolType.BACKGROUND,
      SDKDedicatedPoolType.NATIVE_CRASH_LOG,
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
    this.workerRecoveryHandlers.clear();
    this.pools.forEach((state) => {
      state.isShutdown = true;
      for (let i = state.queueHeadIndex; i < state.queue.length; i++) {
        state.queue[i].reject(new Error(`SDK dedicated pool has been shut down: ${state.pool}`));
      }
      state.queue = [];
      state.queueHeadIndex = 0;
      state.running = 0;
      state.mailboxReplayEntries.forEach((entry) => {
        clearTimeout(entry.timeoutId);
      });
      state.mailboxReplayEntries.clear();
      state.mailboxReplayOrder = [];
      state.lineContextCheckpoint = null;
      state.recoveryResponseIds.clear();
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
    this.pools.set(SDKDedicatedPoolType.NATIVE_CRASH_LOG, this.createPool({
      pool: SDKDedicatedPoolType.NATIVE_CRASH_LOG,
      workerCount: DEDICATED_LANE_WORKER_COUNT,
      maxConcurrency: DEDICATED_LANE_WORKER_COUNT,
      backend: 'thread-worker-pending',
      workerInfo: SDKWorkerPathResolver.getWorkerInfo(SDKDedicatedPoolType.NATIVE_CRASH_LOG)
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
      commandReplayCount: 0,
      mailboxReplayCount: 0,
      mailboxReplayDropped: 0,
      mailboxReplayEntries: new Map(),
      mailboxReplayOrder: [],
      lineContextCheckpoint: null,
      recoveryResponseIds: new Map(),
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
    if (SDKDedicatedPoolManager.workerCommandTimeoutMs <= 1) {
      throw new Error(`ThreadWorker command disabled for ${state.pool}`);
    }
    let replayAttempt = 0;
    while (true) {
      try {
        return await this.dispatchThreadWorkerCommand(state, request);
      } catch (error) {
        const normalized = error instanceof Error ? error : new Error(String(error));
        state.lastError = normalized.message;
        if (!isSDKWorkerInFlightReplaySafe(request.command) ||
          replayAttempt >= SDK_WORKER_MAX_MESSAGE_REPLAY_ATTEMPTS) {
          if (!this.hasActiveWorker(state)) {
            state.backend = 'thread-worker-error';
          }
          throw normalized;
        }
        replayAttempt++;
        state.commandReplayCount++;
      }
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
        this.handleThreadWorkerFailure(
          state,
          slot,
          `ThreadWorker command timeout: ${state.pool}/${request.command}`
        );
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
        const normalized = error instanceof Error ? error : new Error(String(error));
        this.handleThreadWorkerFailure(state, slot, normalized.message);
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

  private trackMailboxRequestForReplay(state: DedicatedPoolState, request: SDKWorkerRequest): void {
    if (state.mailboxReplayEntries.has(request.id)) {
      return;
    }
    if (state.mailboxReplayOrder.length >= SDK_WORKER_MAILBOX_REPLAY_CAPACITY) {
      state.mailboxReplayDropped++;
      throw new Error(`ThreadWorker mailbox replay capacity exceeded: ${state.pool}`);
    }
    state.mailboxReplayEntries.set(request.id, {
      request,
      replayCount: 0,
      replaySafe: isSDKWorkerMailboxReplaySafe(request.command),
      timeoutId: this.scheduleMailboxReplayTimeout(state, request.id, request)
    });
    state.mailboxReplayOrder.push(request.id);
  }

  private removeMailboxReplayEntry(
    state: DedicatedPoolState,
    requestId: string
  ): SDKMailboxReplayEntry | undefined {
    const entry = state.mailboxReplayEntries.get(requestId);
    if (!entry) {
      return undefined;
    }
    clearTimeout(entry.timeoutId);
    state.mailboxReplayEntries.delete(requestId);
    const compacted: string[] = [];
    for (let i = 0; i < state.mailboxReplayOrder.length; i++) {
      const currentId = state.mailboxReplayOrder[i];
      if (currentId !== requestId) {
        compacted.push(currentId);
      }
    }
    state.mailboxReplayOrder = compacted;
    return entry;
  }

  private replayMailboxRequestsAfterRestart(state: DedicatedPoolState, slot: SDKThreadWorkerSlot): void {
    const workerInstance = slot.workerInstance;
    if (!workerInstance) {
      return;
    }
    state.recoveryResponseIds.clear();
    // Snapshot before a semantic recovery hook posts new requests. Those new
    // requests have already been delivered and must not be replayed twice.
    const replayOrder = state.mailboxReplayOrder.slice();
    let pendingLineContextId = '';
    for (let i = 0; i < replayOrder.length; i++) {
      const pending = state.mailboxReplayEntries.get(replayOrder[i]);
      if (pending && pending.request.command === SDKWorkerCommand.LINE_CONTEXT_UPDATE) {
        pendingLineContextId = replayOrder[i];
        break;
      }
    }

    if (pendingLineContextId.length > 0) {
      const pending = state.mailboxReplayEntries.get(pendingLineContextId);
      if (pending) {
        try {
          workerInstance.postMessage(pending.request);
          pending.replayCount++;
          clearTimeout(pending.timeoutId);
          pending.timeoutId = this.scheduleMailboxReplayTimeout(state, pendingLineContextId, pending.request);
          state.mailboxReplayCount++;
        } catch (error) {
          state.lastError = error instanceof Error ? error.message : String(error);
        }
      }
    } else if (state.lineContextCheckpoint) {
      const checkpoint = state.lineContextCheckpoint;
      const recoveryId = this.nextInternalTaskId(state.pool, 'line-context-recovery');
      const recoveryRequest: SDKWorkerRequest = {
        id: recoveryId,
        pool: checkpoint.pool,
        command: checkpoint.command,
        priority: checkpoint.priority,
        createdAt: Date.now(),
        payload: checkpoint.payload
      };
      state.recoveryResponseIds.set(recoveryId, true);
      try {
        workerInstance.postMessage(recoveryRequest);
        state.mailboxReplayCount++;
      } catch (error) {
        state.recoveryResponseIds.delete(recoveryId);
        state.lastError = error instanceof Error ? error.message : String(error);
      }
    }

    const recoveryHandler = this.workerRecoveryHandlers.get(state.pool);
    if (recoveryHandler) {
      try {
        recoveryHandler(state.restartCount);
      } catch (error) {
        state.lastError = error instanceof Error ? error.message : String(error);
      }
    }

    const failedIds: string[] = [];
    for (let i = 0; i < replayOrder.length; i++) {
      const requestId = replayOrder[i];
      if (requestId === pendingLineContextId) {
        continue;
      }
      const entry = state.mailboxReplayEntries.get(requestId);
      if (!entry) {
        continue;
      }
      if (!entry.replaySafe || entry.replayCount >= SDK_WORKER_MAX_MESSAGE_REPLAY_ATTEMPTS) {
        failedIds.push(requestId);
        continue;
      }
      try {
        workerInstance.postMessage(entry.request);
        entry.replayCount++;
        clearTimeout(entry.timeoutId);
        entry.timeoutId = this.scheduleMailboxReplayTimeout(state, requestId, entry.request);
        state.mailboxReplayCount++;
      } catch (error) {
        state.lastError = error instanceof Error ? error.message : String(error);
        failedIds.push(requestId);
      }
    }
    for (let i = 0; i < failedIds.length; i++) {
      this.failMailboxReplayEntry(
        state,
        failedIds[i],
        `ThreadWorker mailbox message could not be safely replayed: ${state.pool}`
      );
    }
  }

  private failMailboxReplayEntries(state: DedicatedPoolState, message: string): void {
    const requestIds = state.mailboxReplayOrder.slice();
    for (let i = 0; i < requestIds.length; i++) {
      this.failMailboxReplayEntry(state, requestIds[i], message);
    }
  }

  private failMailboxReplayEntry(state: DedicatedPoolState, requestId: string, message: string): void {
    const entry = state.mailboxReplayEntries.get(requestId);
    if (!entry) {
      return;
    }
    const error = new Error(`${message}; command=${entry.request.command}, id=${requestId}`);
    const response = this.createCommandErrorResponse(entry.request, error, {
      poolWaitMs: 0,
      poolExecuteMs: 0
    });
    this.handleMailboxWorkerResponse(state, response);
  }

  private scheduleMailboxReplayTimeout(
    state: DedicatedPoolState,
    requestId: string,
    request: SDKWorkerRequest
  ): number {
    const timeoutMs = this.getWorkerCommandTimeoutMs(request);
    return setTimeout(() => {
      const current = state.mailboxReplayEntries.get(requestId);
      if (!current || current.request.id !== requestId || state.isShutdown) {
        return;
      }
      const slot = this.findMailboxWorkerSlot(state);
      if (!slot) {
        this.failMailboxReplayEntry(
          state,
          requestId,
          `ThreadWorker mailbox timeout without an active worker: ${state.pool}/${request.command}`
        );
        return;
      }
      this.handleThreadWorkerFailure(
        state,
        slot,
        `ThreadWorker mailbox command timeout: ${state.pool}/${request.command}`
      );
    }, timeoutMs) as number;
  }

  private hasActiveWorker(state: DedicatedPoolState): boolean {
    for (let i = 0; i < state.workerSlots.length; i++) {
      if (state.workerSlots[i].workerInstance) {
        return true;
      }
    }
    return false;
  }

  private getWorkerCommandTimeoutMs(request: SDKWorkerRequest): number {
    if (request.command === SDKWorkerCommand.ANR_PARSE_EVENT) {
      return Math.max(
        SDKDedicatedPoolManager.workerCommandTimeoutMs,
        ANR_PARSE_COMMAND_TIMEOUT_MS
      );
    }
    if (request.command === SDKWorkerCommand.BACKGROUND_COLLECT_METRICS) {
      return Math.max(
        SDKDedicatedPoolManager.workerCommandTimeoutMs,
        BACKGROUND_METRICS_COMMAND_TIMEOUT_MS
      );
    }
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
          if (slot.workerInstance === workerInstance) {
            this.handleThreadWorkerMessage(state, slot, event);
          }
        };
        workerInstance.onerror = (event: ErrorEvent) => {
          if (slot.workerInstance === workerInstance) {
            this.handleThreadWorkerFailure(state, slot, `Worker error: ${String(event)}`);
          }
        };
        workerInstance.onexit = (code: number) => {
          if (code !== 0 && slot.workerInstance === workerInstance) {
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
      this.resetWorkerRestartCountIfRecovered(state);
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

    if (state.recoveryResponseIds.has(response.id)) {
      state.recoveryResponseIds.delete(response.id);
      this.resetWorkerRestartCountIfRecovered(state);
      return;
    }

    const replayEntry = this.removeMailboxReplayEntry(state, response.id);
    if (response.ok && replayEntry && replayEntry.request.command === SDKWorkerCommand.RESET) {
      state.lineContextCheckpoint = null;
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
    this.resetWorkerRestartCountIfRecovered(state);
  }

  private resetWorkerRestartCountIfRecovered(state: DedicatedPoolState): void {
    if (state.mailboxReplayEntries.size > 0 || state.recoveryResponseIds.size > 0) {
      return;
    }
    for (let i = 0; i < state.workerSlots.length; i++) {
      state.workerSlots[i].restartCount = 0;
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
    if (slot.restartCount < SDK_WORKER_MAX_RESTART_ATTEMPTS && !state.isShutdown) {
      slot.restartCount++;
      state.restartCount++;
      this.createThreadWorkerForSlot(state, slot);
    }
    if (slot.workerInstance) {
      state.backend = state.mailboxReplayEntries.size > 0 ? 'thread-worker-mailbox' : 'thread-worker';
      this.replayMailboxRequestsAfterRestart(state, slot);
    } else {
      state.backend = 'thread-worker-error';
      this.failMailboxReplayEntries(state, message);
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
      commandReplayCount: state.commandReplayCount,
      mailboxReplayCount: state.mailboxReplayCount,
      mailboxReplayPending: state.mailboxReplayEntries.size,
      mailboxReplayDropped: state.mailboxReplayDropped,
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
