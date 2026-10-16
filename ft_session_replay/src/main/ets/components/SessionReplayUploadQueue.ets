import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';
import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { SessionReplayResourceUploadResult } from './SessionReplayResourceUploader';
import { SessionReplayUploadResult, SessionReplayUploadRoute } from './SessionReplayUploader';
import { ReplayResourceCleanupResult, replayResourceCleanup, replayResourceCleanupError } from './ReplayResourceCleanup';

export type ReplayUploadLane = 'record' | 'resource';

export interface ReplayUploadReady {
  segmentIds: Array<string> | null;
  route: SessionReplayUploadRoute;
  resourceTouchEpoch: number;
  networkAvailable: boolean | null;
  batteryHealthy: boolean;
}

export interface ReplayUploadSchedule { delayMs: number; retryCount: number; }

export interface ReplayUploadOutcome {
  success: boolean;
  retryable: boolean;
  endpointBlocked: boolean;
  /** Only newly acknowledged work should accelerate the next upload check. */
  madeProgress?: boolean;
}

export const REPLAY_INVALID_ENDPOINT_RECHECK_MS: number = 5_000;
export const REPLAY_RETRY_BASE_DELAY_MS: number = 2_500;
export const REPLAY_RETRY_MAX_DELAY_MS: number = 30_000;
export const REPLAY_NORMAL_MIN_DELAY_MS: number = 500;
export const REPLAY_NORMAL_MAX_DELAY_MS: number = 5_000;
const REPLAY_NORMAL_DECREASE_FACTOR: number = 0.90;
const REPLAY_NORMAL_INCREASE_FACTOR: number = 1.10;

/** Android executes the first scheduled upload immediately; zero disables scheduling. */
export function replayInitialUploadDelayMs(configuredDelayMs: number): number {
  return configuredDelayMs > 0 ? 0 : -1;
}

export function nextReplayUploadSchedule(
  currentDelayMs: number, retryCount: number, result: ReplayUploadOutcome | null
): ReplayUploadSchedule {
  const current = Number.isFinite(currentDelayMs) && currentDelayMs > 0
    ? currentDelayMs : REPLAY_RETRY_BASE_DELAY_MS;
  if (result?.endpointBlocked === true) {
    return { delayMs: REPLAY_INVALID_ENDPOINT_RECHECK_MS, retryCount: 0 };
  }
  // Remote acknowledgement can succeed while local cleanup still needs a retry.
  if (result?.retryable === true) {
    const nextCount = retryCount + 1;
    return {
      delayMs: Math.min(REPLAY_RETRY_MAX_DELAY_MS,
        REPLAY_RETRY_BASE_DELAY_MS * Math.pow(2, Math.max(0, nextCount - 1))),
      retryCount: nextCount
    };
  }
  if (result?.success === true && result.madeProgress !== false) {
    return {
      delayMs: Math.max(Math.floor(current * REPLAY_NORMAL_DECREASE_FACTOR), REPLAY_NORMAL_MIN_DELAY_MS),
      retryCount: 0
    };
  }
  return {
    delayMs: Math.min(Math.floor(current * REPLAY_NORMAL_INCREASE_FACTOR), REPLAY_NORMAL_MAX_DELAY_MS),
    retryCount: 0
  };
}

export interface ReplayUploadWorkerMessage {
  id: number;
  phase: string;
  lane?: ReplayUploadLane;
  filesDir?: string;
  maxBytes?: number;
  maxRecordsPerSegment?: number;
  intervalMs?: number;
  drainOnly?: boolean;
  scheduleVersion?: number;
  ready?: ReplayUploadReady;
  segmentId?: string;
  resourceIds?: Array<string>;
  resourceTouchEpoch?: number;
  deleted?: boolean;
  cleanup?: ReplayResourceCleanupResult;
  result?: SessionReplayUploadResult;
  resourceResult?: SessionReplayResourceUploadResult;
  pendingItems?: number;
  retryCount?: number;
  nextDelayMs?: number;
  error?: string;
}

interface ReplayUploadEvent { data: ReplayUploadWorkerMessage; }

interface PendingUpload {
  lane: ReplayUploadLane;
  resolveSegment?: (result: SessionReplayUploadResult) => void;
  resolveResource?: (result: SessionReplayResourceUploadResult) => void;
}

class ReplayUploadLaneState {
  public thread: worker.ThreadWorker | null = null;
  public retiringThread: worker.ThreadWorker | null = null;
  public intervalMs: number = 0;
  public drainOnly: boolean = false;
  public scheduleVersion: number = 0;
  public restartAttempts: number = 0;
  public unavailableReason: string = '';
}

/** Record and resource uploads own independent single-thread workers and retry state. */
export class SessionReplayUploadQueue {
  private readonly filesDir: string;
  private readonly maxBytes: number;
  private readonly maxRecordsPerSegment: number;
  private readonly prepare: (lane: ReplayUploadLane) => Promise<ReplayUploadReady>;
  private readonly removeAcknowledged: (id: string) => Promise<boolean>;
  private readonly removeResources: (ids: Array<string>, touchEpoch: number) => Promise<ReplayResourceCleanupResult>;
  private readonly pending: Map<number, PendingUpload> = new Map();
  private readonly recordLane: ReplayUploadLaneState = new ReplayUploadLaneState();
  private readonly resourceLane: ReplayUploadLaneState = new ReplayUploadLaneState();
  private nextId: number = 0;
  private closed: boolean = false;

  constructor(
    filesDir: string,
    maxBytes: number,
    maxRecordsPerSegment: number,
    prepare: (lane: ReplayUploadLane) => Promise<ReplayUploadReady>,
    removeAcknowledged: (id: string) => Promise<boolean>,
    removeResources: (ids: Array<string>, touchEpoch: number) => Promise<ReplayResourceCleanupResult>
  ) {
    this.filesDir = filesDir;
    this.maxBytes = maxBytes;
    this.maxRecordsPerSegment = maxRecordsPerSegment;
    this.prepare = prepare;
    this.removeAcknowledged = removeAcknowledged;
    this.removeResources = removeResources;
  }

  public schedule(intervalMs: number, drainOnly: boolean = false): void {
    this.scheduleLane('record', intervalMs, drainOnly);
    this.scheduleLane('resource', intervalMs, drainOnly);
  }

  /** Immediately rechecks both independent lanes after a blocked network becomes available. */
  public wake(): void {
    this.wakeLane('record');
    this.wakeLane('resource');
  }

  public flush(): Promise<SessionReplayUploadResult> {
    return new Promise<SessionReplayUploadResult>((resolve: (result: SessionReplayUploadResult) => void): void => {
      const thread = this.ensureThread('record');
      if (thread === null) {
        FTSessionReplayBridgeRegistry.logDiagnostic('Replay record upload Worker is unavailable; persisted segments are retained.', true);
        resolve(this.failedSegment('Session Replay record upload Worker is unavailable.'));
        return;
      }
      const id = ++this.nextId;
      this.pending.set(id, { lane: 'record', resolveSegment: resolve });
      this.post('record', thread, { id, phase: 'flush', lane: 'record' });
    });
  }

  public flushResources(): Promise<SessionReplayResourceUploadResult> {
    return new Promise<SessionReplayResourceUploadResult>((resolve: (result: SessionReplayResourceUploadResult) => void): void => {
      const thread = this.ensureThread('resource');
      if (thread === null) {
        FTSessionReplayBridgeRegistry.logDiagnostic('Replay resource upload Worker is unavailable; persisted resources are retained.', true);
        resolve(this.failedResource('Session Replay resource upload Worker is unavailable.'));
        return;
      }
      const id = ++this.nextId;
      this.pending.set(id, { lane: 'resource', resolveResource: resolve });
      this.post('resource', thread, { id, phase: 'flush', lane: 'resource' });
    });
  }

  public close(): void {
    this.closed = true;
    this.closeLane(this.recordLane);
    this.closeLane(this.resourceLane);
    this.failPending('record', 'Session Replay upload Worker was closed.');
    this.failPending('resource', 'Session Replay upload Worker was closed.');
  }

  private scheduleLane(lane: ReplayUploadLane, intervalMs: number, drainOnly: boolean): void {
    const state = this.state(lane);
    state.intervalMs = Math.max(0, intervalMs);
    state.drainOnly = drainOnly;
    state.scheduleVersion++;
    if (intervalMs <= 0 && state.thread === null) return;
    const thread = this.ensureThread(lane);
    if (thread === null) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay ${lane} upload Worker is unavailable; persisted data is retained. ${state.unavailableReason}`, true);
      return;
    }
    this.post(lane, thread, { id: 0, phase: 'schedule', lane, intervalMs: state.intervalMs,
      drainOnly, scheduleVersion: state.scheduleVersion });
  }

  private wakeLane(lane: ReplayUploadLane): void {
    const state = this.state(lane);
    if (this.closed || state.intervalMs <= 0) return;
    const thread = this.ensureThread(lane);
    if (thread === null) return;
    this.post(lane, thread, { id: 0, phase: 'wake', lane });
  }

  private ensureThread(lane: ReplayUploadLane): worker.ThreadWorker | null {
    const state = this.state(lane);
    if (this.closed || state.retiringThread !== null) return null;
    if (state.thread !== null) return state.thread;
    const candidates = [
      './workers/SessionReplayUploadWorker.ets',
      'ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      '@ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      '@guancecloud/ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      './src/main/ets/components/workers/SessionReplayUploadWorker.ets'
    ];
    for (const path of candidates) {
      let candidate: worker.ThreadWorker | null = null;
      try {
        const thread = new worker.ThreadWorker(path);
        candidate = thread;
        thread.onmessage = (event: MessageEvents): void => this.onMessage(lane, thread, event);
        thread.onmessageerror = (_event: MessageEvents): void => {
          if (state.thread === thread) this.failThread(lane, 'upload response could not be decoded', false);
        };
        thread.onerror = (event: ErrorEvent): void => {
          if (state.thread === thread) this.failThread(lane, `upload Worker failed: ${String(event)}`, false);
        };
        thread.onexit = (code: number): void => {
          if (state.retiringThread === thread) {
            state.retiringThread = null;
            this.restartSchedule(lane);
          } else if (state.thread === thread) {
            this.failThread(lane, `upload Worker exited: ${code}`, true);
          }
        };
        state.thread = thread;
        thread.postMessage({ id: 0, phase: 'init', lane, filesDir: this.filesDir,
          maxBytes: this.maxBytes, maxRecordsPerSegment: this.maxRecordsPerSegment } as ReplayUploadWorkerMessage);
        return thread;
      } catch (error) {
        state.unavailableReason = String(error);
        if (state.thread === candidate) state.thread = null;
        candidate?.terminate();
      }
    }
    return null;
  }

  private onMessage(lane: ReplayUploadLane, thread: worker.ThreadWorker, event: MessageEvents): void {
    const state = this.state(lane);
    if (state.thread !== thread) return;
    const message = (event as Object as ReplayUploadEvent).data;
    if (message.phase === 'fatal') {
      this.failThread(lane, message.error ?? 'initialization failed', false);
      return;
    }
    if (message.phase === 'prepare') {
      Promise.resolve().then((): Promise<ReplayUploadReady> => this.prepare(lane)).then((ready: ReplayUploadReady): void => {
        this.post(lane, thread, { id: message.id, phase: 'ready', lane, ready });
      }).catch((error: Error): void => {
        this.post(lane, thread, { id: message.id, phase: 'ready', lane, error: String(error) });
      });
      return;
    }
    if (message.phase === 'started') {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay ${lane} upload start: requestId=${message.id}, trigger=${message.id < 0 ? 'scheduled' : 'flush'}, ` +
        `pending=${message.pendingItems ?? 0}, retryCount=${message.retryCount ?? 0}`);
      return;
    }
    if (message.phase === 'delete' && message.segmentId !== undefined) {
      Promise.resolve().then((): Promise<boolean> => this.removeAcknowledged(message.segmentId!)).then((deleted: boolean): void => {
        this.post(lane, thread, { id: message.id, phase: 'deleted', lane, deleted });
      }).catch((): void => this.post(lane, thread, { id: message.id, phase: 'deleted', lane, deleted: false }));
      return;
    }
    if (message.phase === 'deleteResource' && message.resourceIds !== undefined) {
      Promise.resolve().then((): Promise<ReplayResourceCleanupResult> =>
        this.removeResources(message.resourceIds!, message.resourceTouchEpoch ?? -1))
        .then((cleanup: ReplayResourceCleanupResult): void =>
          this.post(lane, thread, { id: message.id, phase: 'deleted', lane, cleanup }))
        .catch((error: Error): void => this.post(lane, thread, { id: message.id, phase: 'deleted', lane,
          cleanup: replayResourceCleanup(0, 0, message.resourceIds!.length, replayResourceCleanupError(error)) }));
      return;
    }
    if (message.phase !== 'done') return;
    state.restartAttempts = 0;
    this.logResult(lane, message);
    if (state.drainOnly && message.scheduleVersion === state.scheduleVersion && this.isDrained(lane, message)) {
      state.intervalMs = 0;
    }
    const pending = this.pending.get(message.id);
    if (pending === undefined || pending.lane !== lane) return;
    this.pending.delete(message.id);
    if (lane === 'resource') pending.resolveResource?.(message.resourceResult ?? this.failedResource(message.error ?? 'Upload failed.'));
    else pending.resolveSegment?.(message.result ?? this.failedSegment(message.error ?? 'Upload failed.'));
  }

  private isDrained(lane: ReplayUploadLane, message: ReplayUploadWorkerMessage): boolean {
    if (lane === 'resource') return message.resourceResult?.success === true &&
      message.resourceResult.remainingResources === 0 && message.resourceResult.cleanup.failedResources === 0;
    return message.result?.success === true && message.result.remainingSegments === 0;
  }

  private failThread(lane: ReplayUploadLane, reason: string, exited: boolean): void {
    const state = this.state(lane);
    FTSessionReplayBridgeRegistry.logDiagnostic(`Replay ${lane} upload Worker stopped: ${reason}; persisted data is retained.`, true);
    const thread = state.thread;
    state.thread = null;
    this.failPending(lane, reason);
    if (exited) this.restartSchedule(lane);
    else if (thread !== null) {
      state.retiringThread = thread;
      thread.terminate();
    }
  }

  private restartSchedule(lane: ReplayUploadLane): void {
    const state = this.state(lane);
    if (this.closed || state.intervalMs <= 0 || state.restartAttempts >= 3) return;
    state.restartAttempts++;
    const thread = this.ensureThread(lane);
    if (thread !== null) this.post(lane, thread, { id: 0, phase: 'schedule', lane,
      intervalMs: state.intervalMs, drainOnly: state.drainOnly, scheduleVersion: state.scheduleVersion });
  }

  private post(lane: ReplayUploadLane, thread: worker.ThreadWorker, message: ReplayUploadWorkerMessage): void {
    if (this.state(lane).thread !== thread) return;
    try { thread.postMessage(message); }
    catch (error) { this.failThread(lane, `message failed: ${String(error)}`, false); }
  }

  private failPending(lane: ReplayUploadLane, reason: string): void {
    const ids: Array<number> = [];
    this.pending.forEach((request: PendingUpload, id: number): void => {
      if (request.lane !== lane) return;
      ids.push(id);
      if (lane === 'resource') request.resolveResource?.(this.failedResource(reason));
      else request.resolveSegment?.(this.failedSegment(reason));
    });
    for (const id of ids) this.pending.delete(id);
  }

  private logResult(lane: ReplayUploadLane, message: ReplayUploadWorkerMessage): void {
    const trigger = message.id < 0 ? 'scheduled' : 'flush';
    if (message.result !== undefined) {
      const result = message.result;
      if (result.success && result.attemptedSegments === 0 && result.uploadedSegments === 0 &&
        result.remainingSegments === 0 && !result.retryable && !result.endpointBlocked) return;
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay record upload result: requestId=${message.id}, trigger=${trigger}, success=${result.success}, ` +
        `code=${result.code}, attempted=${result.attemptedSegments}, uploaded=${result.uploadedSegments}, ` +
        `remaining=${result.remainingSegments}, retryable=${result.retryable}, endpointBlocked=${result.endpointBlocked}, ` +
        `retryCount=${message.retryCount ?? 0}, nextDelayMs=${message.nextDelayMs ?? 'none'}`, !result.success);
    }
    if (message.resourceResult !== undefined) {
      const result = message.resourceResult;
      if (result.success && result.attemptedResources === 0 && result.uploadedResources === 0 &&
        result.remainingResources === 0 && !result.retryable && !result.endpointBlocked) return;
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay resource upload result: requestId=${message.id}, trigger=${trigger}, success=${result.success}, ` +
        `code=${result.code}, attempted=${result.attemptedResources}, confirmed=${result.uploadedResources}, ` +
        `existing=${result.existingResources ?? 0}, transferred=${result.transferredResources ?? 0}, ` +
        `cached=${result.cachedResources ?? 0}, remaining=${result.remainingResources}, ` +
        `local=${result.localResources ?? result.remainingResources}, ` +
        `cleanupDeleted=${result.cleanup.deletedResources}, cleanupDeferred=${result.cleanup.deferredResources}, ` +
        `cleanupFailed=${result.cleanup.failedResources}, retryable=${result.retryable}, ` +
        `endpointBlocked=${result.endpointBlocked}, retryCount=${message.retryCount ?? 0}, ` +
        `nextDelayMs=${message.nextDelayMs ?? 'none'}, resourceSample=${result.resourceIdSample?.join('|') || 'none'}` +
        (result.cleanup.reason.length > 0 ? `, cleanupReason=${JSON.stringify(result.cleanup.reason)}` : '') +
        (!result.success ? `, message=${JSON.stringify(result.message)}` : ''),
        !result.success || result.cleanup.failedResources > 0);
    }
    if (message.error !== undefined) {
      FTSessionReplayBridgeRegistry.logDiagnostic(`Replay ${lane} upload failed: ${message.error}`, true);
    }
  }

  private state(lane: ReplayUploadLane): ReplayUploadLaneState {
    return lane === 'record' ? this.recordLane : this.resourceLane;
  }

  private closeLane(state: ReplayUploadLaneState): void {
    state.thread?.terminate();
    state.retiringThread?.terminate();
    state.thread = null;
    state.retiringThread = null;
  }

  private failedSegment(message: string): SessionReplayUploadResult {
    return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
      attemptedSegments: 0, uploadedSegments: 0, remainingSegments: 0 };
  }

  private failedResource(message: string): SessionReplayResourceUploadResult {
    return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
      attemptedResources: 0, uploadedResources: 0, remainingResources: 0, cleanup: replayResourceCleanup() };
  }
}
