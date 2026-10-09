import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';
import { ArkUIReplayLightSnapshot, CapturedReplayImageResource } from './ArkUIReplayCollector';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';

export type ReplaySnapshotKind = 'start' | 'full' | 'automatic' | 'settled';
export type ReplayStoreKind = 'main' | 'error' | 'none';

export interface ReplayViewport {
  width: number;
  height: number;
}

export interface ReplayWorkerOptions {
  filesDir: string;
  maxNodes: number;
  maxBytes: number;
  maxRecordsPerSegment: number;
  fullSnapshotIntervalMs: number;
  errorSampleWindowMs: number;
  textPrivacy: string;
  imagePrivacy: string;
}

export const REPLAY_STALE_QUEUE_REASON = 'Session Replay snapshot waited in the queue for more than 1 second.';

export function isReplaySnapshotExpired(
  queuedAt: number,
  now: number,
  kind: ReplaySnapshotKind = 'automatic'
): boolean {
  // View Starts and settled scene removals are immutable lifecycle boundaries.
  // Dropping a removal could leave the preceding transition frame on screen.
  return kind !== 'start' && kind !== 'settled' && now - queuedAt > 1000;
}

export interface ReplayWorkerCommit {
  context: SessionReplayContext;
  snapshot: SessionReplayRecord;
  viewport: ReplayViewport | null;
  previousViewport: ReplayViewport | null;
  lastFullSnapshotAt: number;
  storeKind: ReplayStoreKind;
}

export interface ReplayWorkerResult {
  records: Array<SessionReplayRecord>;
  payload: string;
  wireframeCount: number;
  stored: boolean;
  writeError: string;
  lastFullSnapshotAt: number;
  viewport: ReplayViewport | null;
  storeKind: ReplayStoreKind;
  segmentIds: Array<string>;
}

export interface ReplayWorkerMessage {
  id: number;
  phase: string;
  kind?: ReplaySnapshotKind;
  snapshot?: ArkUIReplayLightSnapshot | SessionReplayRecord;
  resources?: Array<CapturedReplayImageResource>;
  commit?: ReplayWorkerCommit;
  result?: ReplayWorkerResult;
  queuedAt?: number;
  draining?: boolean;
  componentId?: string;
  bytes?: Uint8Array;
  mimeType?: string;
  error?: string;
  options?: ReplayWorkerOptions;
  context?: SessionReplayContext;
  records?: Array<SessionReplayRecord>;
  storeKind?: ReplayStoreKind;
  sessionId?: string;
  timestamp?: number;
  segmentIds?: Array<string>;
  success?: boolean;
  requiresStart?: boolean;
  baselineSnapshot?: SessionReplayRecord;
  baselineViewport?: ReplayViewport;
}

interface ReplayWorkerEvent {
  data: ReplayWorkerMessage;
}

interface ReplayQueuedJob {
  id: number;
  kind: ReplaySnapshotKind | 'records' | 'promote' | 'remove' | 'list' | 'barrier';
  snapshot?: ArkUIReplayLightSnapshot;
  queuedAt: number;
  prepare?: (snapshot: SessionReplayRecord, resources: Array<CapturedReplayImageResource>) => ReplayWorkerCommit | null;
  complete?: (result: ReplayWorkerResult | null, error: string) => void;
  context?: SessionReplayContext;
  records?: Array<SessionReplayRecord>;
  storeKind?: ReplayStoreKind;
  requiresStart?: boolean;
  baselineSnapshot?: SessionReplayRecord;
  baselineViewport?: ReplayViewport;
  sessionId?: string;
  timestamp?: number;
  segmentIds?: Array<string>;
  finish?: (success: boolean, error: string, records?: Array<SessionReplayRecord>) => void;
  resolve?: () => void;
  reject?: (reason: Error) => void;
  barrierAction?: () => void;
  listResolve?: (ids: Array<string>) => void;
  listReject?: (reason: Error) => void;
}

interface ReplayImageCommand {
  componentId: string;
  bytes: Uint8Array | null;
  mimeType: string;
}

/** One long-lived ThreadWorker executes Replay snapshots in FIFO order. */
export class SessionReplayWorkQueue {
  // A replacement recorder must wait for the previous Worker to exit before
  // touching the same segment directories.
  private static readonly ownerTails: Map<string, Promise<void>> = new Map();
  private readonly options: ReplayWorkerOptions;
  private readonly jobs: Array<ReplayQueuedJob> = [];
  private readonly imageCommands: Array<ReplayImageCommand> = [];
  private readonly registeredImages: Map<string, ReplayImageCommand> = new Map();
  private thread: worker.ThreadWorker | null = null;
  private retiringThread: worker.ThreadWorker | null = null;
  private active: ReplayQueuedJob | null = null;
  private completing: boolean = false;
  private callbackInsertIndex: number = 0;
  private nextId: number = 0;
  private unavailableReason: string = '';
  private closing: boolean = false;
  private ready: boolean = false;
  private released: boolean = false;
  private readonly releaseOwner: () => void;
  private readonly closedPromise: Promise<void>;
  private closeResolve: () => void = (): void => {};

  constructor(options: ReplayWorkerOptions) {
    this.options = options;
    this.closedPromise = new Promise<void>((resolve: () => void): void => {
      this.closeResolve = resolve;
    });
    if (options.filesDir.length === 0) {
      this.releaseOwner = (): void => {};
      this.ready = true;
      return;
    }
    const previousOwner = SessionReplayWorkQueue.ownerTails.get(options.filesDir) ?? Promise.resolve();
    let release: () => void = (): void => {};
    const owner = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    SessionReplayWorkQueue.ownerTails.set(options.filesDir, owner);
    this.releaseOwner = release;
    previousOwner.then((): void => {
      this.ready = true;
      this.dispatch();
    });
  }

  public enqueue(
    kind: ReplaySnapshotKind,
    snapshot: ArkUIReplayLightSnapshot,
    prepare: (snapshot: SessionReplayRecord, resources: Array<CapturedReplayImageResource>) => ReplayWorkerCommit | null,
    complete: (result: ReplayWorkerResult | null, error: string) => void
  ): void {
    if (this.closing) {
      complete(null, 'Session Replay Worker is closing.');
      return;
    }
    if (this.retiringThread !== null) {
      complete(null, this.unavailableReason);
      return;
    }
    this.addJob({ id: ++this.nextId, kind, snapshot, queuedAt: Date.now(), prepare, complete });
    this.dispatch();
  }

  /** All segment mutations share the same FIFO as detached snapshots. */
  public enqueueRecords(
    context: SessionReplayContext,
    records: Array<SessionReplayRecord>,
    storeKind: ReplayStoreKind,
    finish: (success: boolean, error: string, records?: Array<SessionReplayRecord>) => void,
    requiresStart: boolean = false,
    baselineSnapshot: SessionReplayRecord | null = null,
    baselineViewport: ReplayViewport | null = null
  ): boolean {
    if (this.closing) return false;
    if (records.length === 0) {
      finish(true, '');
      return true;
    }
    let failedSynchronously = false;
    const complete = (success: boolean, error: string, writtenRecords?: Array<SessionReplayRecord>): void => {
      if (!success) failedSynchronously = true;
      finish(success, error, writtenRecords);
    };
    this.addJob({
      id: ++this.nextId, kind: 'records', queuedAt: Date.now(), context,
      records: records.slice(), storeKind, finish: complete, requiresStart,
      baselineSnapshot: baselineSnapshot ?? undefined,
      baselineViewport: baselineViewport === null ? undefined :
        { width: baselineViewport.width, height: baselineViewport.height }
    });
    this.dispatch();
    return !failedSynchronously;
  }

  public enqueuePromotion(sessionId: string, timestamp: number, finish: (success: boolean, error: string) => void): boolean {
    if (this.released) return false;
    let failedSynchronously = false;
    const complete = (success: boolean, error: string): void => {
      if (!success) failedSynchronously = true;
      finish(success, error);
    };
    this.addJob({ id: ++this.nextId, kind: 'promote', queuedAt: Date.now(), sessionId, timestamp, finish: complete });
    this.dispatch();
    return !failedSynchronously;
  }

  public enqueueRemove(storeKind: ReplayStoreKind, segmentIds: Array<string>, finish?: (success: boolean, error: string) => void): boolean {
    if (this.released) return false;
    if (segmentIds.length === 0) {
      finish?.(true, '');
      return true;
    }
    this.addJob({ id: ++this.nextId, kind: 'remove', queuedAt: Date.now(), storeKind,
      segmentIds: segmentIds.slice(), finish });
    this.dispatch();
    return true;
  }

  public listPendingIds(): Promise<Array<string>> {
    if (this.closing) return this.closedPromise.then((): Array<string> => []);
    return new Promise<Array<string>>((resolve: (ids: Array<string>) => void,
      reject: (reason: Error) => void): void => {
      this.addJob({ id: ++this.nextId, kind: 'list', queuedAt: Date.now(), listResolve: resolve, listReject: reject });
      this.dispatch();
    });
  }

  /** Synchronous captures use a checkpoint when the committed baseline is uncertain. */
  public hasPendingWork(): boolean {
    return !this.ready || this.closing || this.active !== null || this.jobs.length > 0 || this.retiringThread !== null;
  }

  /** A FIFO barrier for flush and for orderly Worker shutdown. */
  public drain(barrierAction?: () => void): Promise<void> {
    if (this.closing) return this.closedPromise.then((): void => { barrierAction?.(); });
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      this.addJob({ id: ++this.nextId, kind: 'barrier', queuedAt: Date.now(), resolve, reject, barrierAction });
      this.dispatch();
    });
  }

  /** Drops superseded samples while retaining accepted lifecycle boundaries. */
  public clear(keepViewStart: boolean = true): void {
    for (let index = this.jobs.length - 1; index >= 0; index--) {
      const kind = this.jobs[index].kind;
      if (this.isSnapshot(this.jobs[index]) && !(keepViewStart && (kind === 'start' || kind === 'settled'))) {
        this.jobs.splice(index, 1);
      }
    }
  }

  public registerImageAsset(componentId: string, bytes: Uint8Array, mimeType: string): void {
    if (this.closing) return;
    const key = componentId.trim();
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    const command: ReplayImageCommand = { componentId: key, bytes: copy, mimeType };
    this.registeredImages.set(key, command);
    this.imageCommands.push(command);
    this.dispatch();
  }

  public unregisterImageAsset(componentId: string): void {
    if (this.closing) return;
    const key = componentId.trim();
    this.registeredImages.delete(key);
    this.imageCommands.push({ componentId: key, bytes: null, mimeType: '' });
    this.dispatch();
  }

  /** Seal new captures, retaining every accepted frame and image until exit. */
  public close(): void {
    this.closing = true;
    this.dispatch();
  }

  private isSnapshot(job: ReplayQueuedJob): boolean {
    return job.kind === 'start' || job.kind === 'full' || job.kind === 'automatic' || job.kind === 'settled';
  }

  private addJob(job: ReplayQueuedJob): void {
    if (this.completing) this.jobs.splice(this.callbackInsertIndex++, 0, job);
    else this.jobs.push(job);
  }

  private ensureThread(): boolean {
    if (this.thread !== null) return true;
    const candidates = [
      './workers/SessionReplayWorker.ets',
      'ft_session_replay/ets/components/workers/SessionReplayWorker.ets',
      '@ft_session_replay/ets/components/workers/SessionReplayWorker.ets',
      '@guancecloud/ft_session_replay/ets/components/workers/SessionReplayWorker.ets',
      './src/main/ets/components/workers/SessionReplayWorker.ets'
    ];
    for (let index = 0; index < candidates.length; index++) {
      let candidate: worker.ThreadWorker | null = null;
      try {
        const thread = new worker.ThreadWorker(candidates[index]);
        candidate = thread;
        thread.onmessage = (event: MessageEvents): void => this.onMessage(event);
        thread.onmessageerror = (_event: MessageEvents): void => {
          if (this.thread === thread) this.fail('Session Replay Worker response could not be decoded.');
        };
        thread.onerror = (event: ErrorEvent): void => {
          if (this.thread === thread) this.fail(`Session Replay Worker failed: ${String(event)}`);
        };
        thread.onexit = (code: number): void => {
          if (this.retiringThread === thread) {
            this.retiringThread = null;
            this.dispatch();
          } else if (this.thread === thread) {
            this.thread = null;
            const job = this.active;
            this.active = null;
            try {
              this.failJob(job, `Session Replay Worker exited: ${code}`);
            } finally {
              this.dispatch();
            }
          }
        };
        this.thread = thread;
        this.unavailableReason = '';
        thread.postMessage({ id: 0, phase: 'init', options: this.options } as ReplayWorkerMessage);
        this.registeredImages.forEach((command: ReplayImageCommand): void => {
          thread.postMessage({
            id: 0,
            phase: 'addImage',
            componentId: command.componentId,
            bytes: command.bytes,
            mimeType: command.mimeType
          } as ReplayWorkerMessage);
        });
        this.imageCommands.splice(0, this.imageCommands.length);
        return true;
      } catch (error) {
        this.unavailableReason = String(error);
        if (this.thread === candidate) this.thread = null;
        candidate?.terminate();
      }
    }
    return false;
  }

  private dispatch(): void {
    if (!this.ready) return;
    if (this.completing) return;
    if (this.active !== null) return;
    if (this.retiringThread !== null) return;
    if (this.jobs.length === 0 && this.imageCommands.length === 0) {
      if (this.closing) {
        const thread = this.thread;
        this.thread = null;
        if (thread === null) {
          if (!this.released) {
            this.released = true;
            this.releaseOwner();
            this.closeResolve();
          }
        } else {
          this.retiringThread = thread;
          thread.terminate();
        }
      }
      return;
    }
    if (!this.ensureThread()) {
      this.imageCommands.splice(0, this.imageCommands.length);
      const pending = this.jobs.splice(0, this.jobs.length);
      for (let index = 0; index < pending.length; index++) {
        try {
          this.failJob(pending[index], this.unavailableReason);
        } catch (_) { }
      }
      if (this.closing) this.dispatch();
      return;
    }
    while (this.imageCommands.length > 0) {
      const command = this.imageCommands.shift();
      if (command !== undefined) {
        this.thread?.postMessage({
          id: 0,
          phase: command.bytes === null ? 'removeImage' : 'addImage',
          componentId: command.componentId,
          bytes: command.bytes === null ? undefined : command.bytes,
          mimeType: command.mimeType
        } as ReplayWorkerMessage);
      }
    }
    // A stale job's completion callback may synchronously enqueue and dispatch
    // a replacement. Stop this drain once that callback has claimed the slot.
    while (this.active === null && this.jobs.length > 0) {
      const job = this.jobs.shift();
      if (job === undefined) break;
      if (job.kind === 'barrier') {
        try {
          job.barrierAction?.();
          job.resolve?.();
        } catch (error) {
          job.reject?.(new Error(String(error)));
        }
        continue;
      }
      if (!this.closing && this.isSnapshot(job) &&
        isReplaySnapshotExpired(job.queuedAt, Date.now(), job.kind as ReplaySnapshotKind)) {
        this.completing = true;
        try {
          job.complete?.(null, REPLAY_STALE_QUEUE_REASON);
        } catch (_) { }
        finally {
          this.completing = false;
          this.callbackInsertIndex = 0;
        }
        continue;
      }
      this.active = job;
      try {
        if (this.isSnapshot(job)) {
          this.thread?.postMessage({
            id: job.id, phase: 'materialize', kind: job.kind,
            snapshot: job.snapshot, queuedAt: job.queuedAt, draining: this.closing
          } as ReplayWorkerMessage);
        } else {
          this.thread?.postMessage({
            id: job.id, phase: job.kind, context: job.context, records: job.records,
            storeKind: job.storeKind, requiresStart: job.requiresStart, sessionId: job.sessionId,
            timestamp: job.timestamp, segmentIds: job.segmentIds, baselineSnapshot: job.baselineSnapshot,
            baselineViewport: job.baselineViewport
          } as ReplayWorkerMessage);
        }
      } catch (error) {
        this.finish(null, String(error));
      }
      return;
    }
    // Barriers can be the last queued job; finish closing after resolving them.
    if (this.closing) this.dispatch();
  }

  private onMessage(event: MessageEvents): void {
    const message = (event as Object as ReplayWorkerEvent).data;
    const job = this.active;
    if (job === null || message.id !== job.id) return;
    if (message.phase === 'materialized' && this.isSnapshot(job)) {
      try {
        const commit = job.prepare?.(message.snapshot as SessionReplayRecord, message.resources ?? []) ?? null;
        if (commit === null) {
          this.finish(null, 'Session Replay snapshot was invalidated before processing.');
          return;
        }
        this.thread?.postMessage({ id: job.id, phase: 'process', kind: job.kind, commit } as ReplayWorkerMessage);
      } catch (error) {
        this.finish(null, String(error));
      }
      return;
    }
    if (message.phase === 'done') {
      this.finish(message.result ?? null, message.error ?? '', message.success ?? true, message.segmentIds ?? [],
        message.records);
    } else if (message.phase === 'error') {
      // Stop may race the Worker's age check for the already-dispatched frame.
      // Retry that immutable handoff once in drain mode; do not read the UI.
      if (this.closing && this.isSnapshot(job) && message.error === REPLAY_STALE_QUEUE_REASON) {
        try {
          this.thread?.postMessage({
            id: job.id, phase: 'materialize', kind: job.kind,
            snapshot: job.snapshot, queuedAt: job.queuedAt, draining: true
          } as ReplayWorkerMessage);
        } catch (error) {
          this.finish(null, String(error));
        }
        return;
      }
      this.finish(null, message.error ?? 'Session Replay Worker failed.', false);
    }
  }

  private finish(
    result: ReplayWorkerResult | null, error: string, success: boolean = false,
    segmentIds: Array<string> = [], writtenRecords?: Array<SessionReplayRecord>
  ): void {
    const job = this.active;
    this.active = null;
    this.completing = true;
    try {
      if (job?.kind === 'list') {
        if (success) job.listResolve?.(segmentIds);
        else job.listReject?.(new Error(error));
      } else if (job !== null && this.isSnapshot(job)) job.complete?.(result, error);
      else job?.finish?.(success, error, writtenRecords);
    } finally {
      this.completing = false;
      this.callbackInsertIndex = 0;
      this.dispatch();
    }
  }

  private failJob(job: ReplayQueuedJob | null, reason: string): void {
    if (job === null) return;
    if (job.kind === 'barrier') job.resolve?.();
    else if (job.kind === 'list') job.listReject?.(new Error(reason));
    else if (this.isSnapshot(job)) job.complete?.(null, reason);
    else job.finish?.(false, reason);
  }

  private fail(reason: string): void {
    const thread = this.thread;
    this.thread = null;
    this.retiringThread = thread;
    this.unavailableReason = reason;
    thread?.terminate();
    const job = this.active;
    this.active = null;
    try {
      this.failJob(job, reason);
    } finally {
      const pending = this.jobs.splice(0, this.jobs.length);
      for (let index = 0; index < pending.length; index++) {
        try {
          this.failJob(pending[index], reason);
        } catch (_) { }
      }
    }
  }
}
