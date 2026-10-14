import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';
import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { SessionReplayResourceUploadResult } from './SessionReplayResourceUploader';
import { SessionReplayUploadResult, SessionReplayUploadRoute } from './SessionReplayUploader';
import { ReplayResourceCleanupResult, replayResourceCleanup, replayResourceCleanupError } from './ReplayResourceCleanup';

export interface ReplayUploadReady {
  segmentIds: Array<string> | null;
  route: SessionReplayUploadRoute;
  resourceTouchEpoch: number;
}

export interface ReplayUploadSchedule {
  delayMs: number;
  retryCount: number;
}

export function nextReplayUploadSchedule(
  intervalMs: number, retryCount: number, result: SessionReplayUploadResult | null
): ReplayUploadSchedule {
  if (result === null || result.success) return { delayMs: intervalMs, retryCount: 0 };
  if (result.endpointBlocked) return { delayMs: 60_000, retryCount: 0 };
  if (!result.retryable) return { delayMs: intervalMs, retryCount: 0 };
  const nextCount = retryCount + 1;
  return {
    delayMs: Math.min(60_000, intervalMs * Math.pow(2, Math.max(0, nextCount - 1))),
    retryCount: nextCount
  };
}

export interface ReplayUploadWorkerMessage {
  id: number;
  phase: string;
  filesDir?: string;
  maxBytes?: number;
  maxRecordsPerSegment?: number;
  intervalMs?: number;
  drainOnly?: boolean;
  scheduleVersion?: number;
  resourceOnly?: boolean;
  ready?: ReplayUploadReady;
  segmentId?: string;
  resourceIds?: Array<string>;
  resourceTouchEpoch?: number;
  deleted?: boolean;
  cleanup?: ReplayResourceCleanupResult;
  result?: SessionReplayUploadResult;
  resourceResult?: SessionReplayResourceUploadResult;
  error?: string;
}

interface ReplayUploadEvent {
  data: ReplayUploadWorkerMessage;
}

interface PendingUpload {
  resourceOnly: boolean;
  resolveSegment?: (result: SessionReplayUploadResult) => void;
  resolveResource?: (result: SessionReplayResourceUploadResult) => void;
}

/** One independent scheduled upload ThreadWorker; the recorder Worker never waits for HTTP. */
export class SessionReplayUploadQueue {
  private readonly filesDir: string;
  private readonly maxBytes: number;
  private readonly maxRecordsPerSegment: number;
  private readonly prepare: () => Promise<ReplayUploadReady>;
  private readonly removeAcknowledged: (id: string) => Promise<boolean>;
  private readonly removeResources: (ids: Array<string>, touchEpoch: number) => Promise<ReplayResourceCleanupResult>;
  private readonly pending: Map<number, PendingUpload> = new Map();
  private thread: worker.ThreadWorker | null = null;
  private retiringThread: worker.ThreadWorker | null = null;
  private nextId: number = 0;
  private closed: boolean = false;
  private intervalMs: number = 0;
  private drainOnly: boolean = false;
  private scheduleVersion: number = 0;
  private restartAttempts: number = 0;
  private unavailableReason: string = '';

  constructor(
    filesDir: string,
    maxBytes: number,
    maxRecordsPerSegment: number,
    prepare: () => Promise<ReplayUploadReady>,
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

  /** Drain mode keeps retrying persisted data after collection stops, then idles. */
  public schedule(intervalMs: number, drainOnly: boolean = false): void {
    this.intervalMs = Math.max(0, intervalMs);
    this.drainOnly = drainOnly;
    this.scheduleVersion++;
    if (intervalMs <= 0 && this.thread === null) return;
    if (!this.ensureThread()) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay automatic upload Worker is unavailable; persisted data is retained. ${this.unavailableReason}`, true);
      return;
    }
    const thread = this.thread;
    if (thread !== null) this.sendReply(thread,
      { id: 0, phase: 'schedule', intervalMs: this.intervalMs, drainOnly,
        scheduleVersion: this.scheduleVersion } as ReplayUploadWorkerMessage);
  }

  public flush(): Promise<SessionReplayUploadResult> {
    return new Promise<SessionReplayUploadResult>((resolve: (result: SessionReplayUploadResult) => void): void => {
      if (!this.ensureThread()) {
        FTSessionReplayBridgeRegistry.logDiagnostic('Replay upload Worker is unavailable; persisted segments are retained.', true);
        resolve(this.failedSegment('Session Replay upload Worker is unavailable.'));
        return;
      }
      const id = ++this.nextId;
      this.pending.set(id, { resourceOnly: false, resolveSegment: resolve });
      try {
        this.thread?.postMessage({ id, phase: 'flush', resourceOnly: false } as ReplayUploadWorkerMessage);
      } catch (error) {
        this.failThread(`Session Replay upload request failed: ${String(error)}`, false);
      }
    });
  }

  public flushResources(): Promise<SessionReplayResourceUploadResult> {
    return new Promise<SessionReplayResourceUploadResult>((resolve: (result: SessionReplayResourceUploadResult) => void): void => {
      if (!this.ensureThread()) {
        FTSessionReplayBridgeRegistry.logDiagnostic('Replay resource upload Worker is unavailable; persisted resources are retained.', true);
        resolve(this.failedResource('Session Replay upload Worker is unavailable.'));
        return;
      }
      const id = ++this.nextId;
      this.pending.set(id, { resourceOnly: true, resolveResource: resolve });
      try {
        this.thread?.postMessage({ id, phase: 'flush', resourceOnly: true } as ReplayUploadWorkerMessage);
      } catch (error) {
        this.failThread(`Session Replay resource upload request failed: ${String(error)}`, false);
      }
    });
  }

  public close(): void {
    this.closed = true;
    this.thread?.terminate();
    this.retiringThread?.terminate();
    this.thread = null;
    this.retiringThread = null;
    this.failPending('Session Replay upload Worker was closed.');
  }

  private ensureThread(): boolean {
    if (this.closed || this.retiringThread !== null) return false;
    if (this.thread !== null) return true;
    const candidates = [
      './workers/SessionReplayUploadWorker.ets',
      'ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      '@ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      '@guancecloud/ft_session_replay/ets/components/workers/SessionReplayUploadWorker.ets',
      './src/main/ets/components/workers/SessionReplayUploadWorker.ets'
    ];
    for (let index = 0; index < candidates.length; index++) {
      let candidate: worker.ThreadWorker | null = null;
      try {
        const thread = new worker.ThreadWorker(candidates[index]);
        candidate = thread;
        thread.onmessage = (event: MessageEvents): void => this.onMessage(thread, event);
        thread.onmessageerror = (_event: MessageEvents): void => {
          if (this.thread === thread) this.failThread('Session Replay upload response could not be decoded.', false);
        };
        thread.onerror = (event: ErrorEvent): void => {
          if (this.thread === thread) this.failThread(`Session Replay upload Worker failed: ${String(event)}`, false);
        };
        thread.onexit = (code: number): void => {
          if (this.retiringThread === thread) {
            this.retiringThread = null;
            this.restartSchedule();
          } else if (this.thread === thread) {
            this.failThread(`Session Replay upload Worker exited: ${code}`, true);
          }
        };
        this.thread = thread;
        thread.postMessage({
          id: 0, phase: 'init', filesDir: this.filesDir,
          maxBytes: this.maxBytes, maxRecordsPerSegment: this.maxRecordsPerSegment
        } as ReplayUploadWorkerMessage);
        return true;
      } catch (error) {
        this.unavailableReason = String(error);
        if (this.thread === candidate) this.thread = null;
        candidate?.terminate();
      }
    }
    return false;
  }

  private onMessage(thread: worker.ThreadWorker, event: MessageEvents): void {
    if (this.thread !== thread) return;
    const message = (event as Object as ReplayUploadEvent).data;
    if (message.phase === 'fatal') {
      this.failThread(message.error ?? 'Session Replay upload Worker initialization failed.', false);
      return;
    }
    if (message.phase === 'prepare') {
      Promise.resolve().then((): Promise<ReplayUploadReady> => this.prepare()).then((ready: ReplayUploadReady): void => {
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay upload start: requestId=${message.id}, trigger=${message.id < 0 ? 'scheduled' : 'flush'}, ` +
          `pendingSegments=${ready.segmentIds === null ? 'disk' : ready.segmentIds.length}`);
        this.sendReply(thread, { id: message.id, phase: 'ready', ready } as ReplayUploadWorkerMessage);
      }).catch((error: Error): void => {
        this.sendReply(thread, { id: message.id, phase: 'ready', error: String(error) } as ReplayUploadWorkerMessage);
      });
      return;
    }
    if (message.phase === 'delete' && message.segmentId !== undefined) {
      Promise.resolve().then((): Promise<boolean> => this.removeAcknowledged(message.segmentId!)).then((deleted: boolean): void => {
        this.sendReply(thread, { id: message.id, phase: 'deleted', deleted } as ReplayUploadWorkerMessage);
      }).catch((): void => {
        this.sendReply(thread, { id: message.id, phase: 'deleted', deleted: false } as ReplayUploadWorkerMessage);
      });
      return;
    }
    if (message.phase === 'deleteResource' && message.resourceIds !== undefined) {
      Promise.resolve().then((): Promise<ReplayResourceCleanupResult> => this.removeResources(
        message.resourceIds!, message.resourceTouchEpoch ?? -1)).then((cleanup: ReplayResourceCleanupResult): void => {
        this.sendReply(thread, { id: message.id, phase: 'deleted', cleanup } as ReplayUploadWorkerMessage);
      }).catch((error: Error): void => {
        this.sendReply(thread, { id: message.id, phase: 'deleted',
          cleanup: replayResourceCleanup(0, 0, message.resourceIds!.length,
            replayResourceCleanupError(error)) } as ReplayUploadWorkerMessage);
      });
      return;
    }
    if (message.phase !== 'done') return;
    this.restartAttempts = 0;
    this.logResult(message);
    if (this.drainOnly && message.scheduleVersion === this.scheduleVersion &&
      message.result?.success === true && message.result.remainingSegments === 0 &&
      message.resourceResult?.success === true && message.resourceResult.remainingResources === 0) {
      this.intervalMs = 0;
    }
    const pending = this.pending.get(message.id);
    if (pending === undefined) return;
    this.pending.delete(message.id);
    if (pending.resourceOnly) pending.resolveResource?.(message.resourceResult ?? this.failedResource(message.error ?? 'Upload failed.'));
    else pending.resolveSegment?.(message.result ?? this.failedSegment(message.error ?? 'Upload failed.'));
  }

  private failThread(reason: string, exited: boolean): void {
    FTSessionReplayBridgeRegistry.logDiagnostic(`Replay upload Worker stopped: ${reason}; persisted data is retained.`, true);
    const thread = this.thread;
    this.thread = null;
    this.failPending(reason);
    if (exited) this.restartSchedule();
    else if (thread !== null) {
      this.retiringThread = thread;
      thread.terminate();
    }
  }

  private restartSchedule(): void {
    if (this.closed || this.intervalMs <= 0 || this.restartAttempts >= 3) return;
    this.restartAttempts++;
    if (this.ensureThread()) {
      const thread = this.thread;
      if (thread !== null) this.sendReply(thread,
        { id: 0, phase: 'schedule', intervalMs: this.intervalMs, drainOnly: this.drainOnly,
          scheduleVersion: this.scheduleVersion } as ReplayUploadWorkerMessage);
    }
  }

  private sendReply(thread: worker.ThreadWorker, message: ReplayUploadWorkerMessage): void {
    if (this.thread !== thread) return;
    try {
      thread.postMessage(message);
    } catch (error) {
      this.failThread(`Session Replay upload Worker message failed: ${String(error)}`, false);
    }
  }

  private failPending(reason: string): void {
    this.pending.forEach((request: PendingUpload): void => {
      if (request.resourceOnly) request.resolveResource?.(this.failedResource(reason));
      else request.resolveSegment?.(this.failedSegment(reason));
    });
    this.pending.clear();
  }

  private logResult(message: ReplayUploadWorkerMessage): void {
    const trigger = message.id < 0 ? 'scheduled' : 'flush';
    const result = message.result;
    if (result !== undefined) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay upload result: requestId=${message.id}, trigger=${trigger}, success=${result.success}, ` +
        `code=${result.code}, attemptedSegments=${result.attemptedSegments}, uploadedSegments=${result.uploadedSegments}, ` +
        `remainingSegments=${result.remainingSegments}, retryable=${result.retryable}, ` +
        `endpointBlocked=${result.endpointBlocked}, message=${result.message}`, !result.success);
    }
    const resources = message.resourceResult;
    if (resources !== undefined && (resources.attemptedResources > 0 || !resources.success)) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay resource upload result: requestId=${message.id}, trigger=${trigger}, success=${resources.success}, ` +
        `code=${resources.code}, attemptedResources=${resources.attemptedResources}, ` +
        `uploadedResources=${resources.uploadedResources}, remainingResources=${resources.remainingResources}, ` +
        `cleanupDeletedResources=${resources.cleanup.deletedResources}, ` +
        `cleanupDeferredResources=${resources.cleanup.deferredResources}, cleanupFailedResources=${resources.cleanup.failedResources}, ` +
        `cleanupReason=${resources.cleanup.reason}, retryable=${resources.retryable}, message=${resources.message}`,
        !resources.success || resources.cleanup.failedResources > 0);
    }
    if (message.error !== undefined) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay upload failed: requestId=${message.id}, trigger=${trigger}, message=${message.error}`, true);
    }
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
