import { ReplayPerformanceDiagnostics } from './ReplayPerformanceDiagnostics';
import { replayValuesEqual } from './ReplayWireframeValues';
import worker, { ErrorEvent, MessageEvents } from '@ohos.worker';
import { ArkUIReplayLightSnapshot, CapturedReplayImageResource } from './ArkUIReplayCollector';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';

export type ReplaySnapshotKind = 'start' | 'full' | 'automatic' | 'transition' | 'settled';
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
  captureVisiblePassword?: boolean;
  imagePrivacy: string;
  diagnosticsEnabled?: boolean;
}

export const REPLAY_COALESCED_REASON = 'Session Replay pending sample was replaced by a newer state.';

export const REPLAY_STALE_QUEUE_REASON = 'Session Replay snapshot waited in the queue for more than 1 second.';

export function isReplaySnapshotExpired(
  queuedAt: number,
  now: number,
  kind: ReplaySnapshotKind = 'automatic'
): boolean {
  // Accepted default transition samples cover a bounded animation window.
  // Dropping them while a Worker is busy turns a smooth entry into a switch.
  return kind !== 'start' && kind !== 'transition' && kind !== 'settled' && now - queuedAt > 1000;
}

export interface ReplayWorkerCapture {
  context: SessionReplayContext;
  viewport: ReplayViewport | null;
  previousViewport: ReplayViewport | null;
  lastFullSnapshotAt: number;
  storeKind: ReplayStoreKind;
}

export interface ReplayWorkerCommit extends ReplayWorkerCapture {
  context: SessionReplayContext;
  snapshot: SessionReplayRecord;
  viewport: ReplayViewport | null;
  previousViewport: ReplayViewport | null;
  lastFullSnapshotAt: number;
  storeKind: ReplayStoreKind;
}

export interface ReplayWorkerTimings {
  startedAt: number;
  collectionMs: number;
  handoffMs?: number;
  materializeMs: number;
  resourceMs: number;
  diffMs: number;
  writeMs: number;
  workerMs: number;
  effectiveIntervalMs: number;
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
  resourceNames?: Array<string>;
  timings?: ReplayWorkerTimings;
}

export interface ReplayWorkerMessage {
  id: number;
  phase: string;
  kind?: ReplaySnapshotKind;
  snapshot?: ArkUIReplayLightSnapshot | SessionReplayRecord;
  resources?: Array<CapturedReplayImageResource>;
  resourceNames?: Array<string>;
  commit?: ReplayWorkerCommit;
  capture?: ReplayWorkerCapture;
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
  kind: ReplaySnapshotKind | 'records' | 'promote' | 'remove' | 'removeResources' | 'list' | 'flush' | 'barrier' | 'addImage' | 'removeImage';
  snapshot?: ArkUIReplayLightSnapshot;
  componentId?: string;
  bytes?: Uint8Array;
  mimeType?: string;
  queuedAt: number;
  handoffMs?: number;
  capture?: ReplayWorkerCapture;
  canRemove?: () => boolean;
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
  finish?: (success: boolean, error: string, records?: Array<SessionReplayRecord>, resourceNames?: Array<string>) => void;
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
  private readonly registeredImages: Map<string, ReplayImageCommand> = new Map();
  private thread: worker.ThreadWorker | null = null;
  private retiringThread: worker.ThreadWorker | null = null;
  private active: ReplayQueuedJob | null = null;
  private completing: boolean = false;
  private callbackInsertIndex: number = 0;
  private nextId: number = 0;
  private readonly diagnostics: ReplayPerformanceDiagnostics | null;
  private maxDepth: number = 0;
  private expired: number = 0;
  private failures: number = 0;
  private coalesced: number = 0;
  private deferred: number = 0;
  private unavailableReason: string = '';
  private closing: boolean = false;
  private ready: boolean = false;
  private closeFlushQueued: boolean = false;
  private lastFailure: string = '';
  private released: boolean = false;
  private readonly releaseOwner: () => void;
  private readonly closedPromise: Promise<void>;
  private closeResolve: () => void = (): void => {};

  constructor(options: ReplayWorkerOptions) {
    this.options = options;
    this.diagnostics = options.diagnosticsEnabled ? new ReplayPerformanceDiagnostics() : null;
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
    capture: ReplayWorkerCapture,
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
    // Only merge a trailing run; records, checkpoints and barriers split it.
    // Never alter the active frame or a different View/store/context.
    const pending = this.pendingSamples(capture.context, capture.storeKind, kind);
    const limit = kind === 'automatic' ? 2 : (kind === 'transition' ? 8 : 0);
    if (limit > 0 && pending.length >= limit) {
      let removeIndex = pending.length - 1;
      if (kind === 'transition') {
        let closest = Number.MAX_VALUE;
        for (let index = 1; index < pending.length - 1; index++) {
          const gap = pending[index + 1].queuedAt - pending[index - 1].queuedAt;
          if (gap < closest) { closest = gap; removeIndex = index; }
        }
      }
      const replaced = pending[removeIndex];
      this.jobs.splice(this.jobs.indexOf(replaced), 1);
      this.coalesced++;
      replaced.complete?.(null, REPLAY_COALESCED_REASON);
    }
    this.addJob({ id: ++this.nextId, kind, snapshot, queuedAt: Date.now(), capture, complete });
    this.dispatch();
  }

  /** Consult before traversing FrameNodes. Critical boundaries always pass. */
  public shouldCapture(context: SessionReplayContext, kind: ReplaySnapshotKind): boolean {
    if (kind !== 'automatic' && kind !== 'transition') return true;
    // Backpressure spans event boundaries; merging remains restricted to a
    // trailing run. Frequent pointer moves must not bypass the capture budget.
    const pending = this.jobs.filter((job: ReplayQueuedJob): boolean => {
      const capture = job.capture;
      return (job.kind === 'automatic' || job.kind === 'transition') && capture !== undefined &&
        capture.context.applicationId === context.applicationId && capture.context.sessionId === context.sessionId &&
        capture.context.viewId === context.viewId && replayValuesEqual(capture.context.globalContext, context.globalContext);
    });
    const limit = kind === 'transition' ? 8 : 2;
    const minimumGap = kind === 'transition' ? 64 : 128;
    const latest = pending[pending.length - 1];
    if (pending.length >= limit && latest !== undefined && Date.now() - latest.queuedAt < minimumGap) {
      this.deferred++;
      return false;
    }
    return true;
  }

  private pendingSamples(context: SessionReplayContext, storeKind: ReplayStoreKind | undefined,
    kind: ReplaySnapshotKind): Array<ReplayQueuedJob> {
    const pending: Array<ReplayQueuedJob> = [];
    for (let index = this.jobs.length - 1; index >= 0; index--) {
      const job = this.jobs[index];
      const capture = job.capture;
      if (job.kind !== kind || capture === undefined ||
        (storeKind !== undefined && capture.storeKind !== storeKind) ||
        capture.context.applicationId !== context.applicationId || capture.context.sessionId !== context.sessionId ||
        capture.context.viewId !== context.viewId ||
        !replayValuesEqual(capture.context.globalContext, context.globalContext)) break;
      pending.unshift(job);
    }
    return pending;
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

  public enqueuePromotion(sessionId: string, timestamp: number,
    finish: (success: boolean, error: string, resources?: Array<string>) => void): boolean {
    if (this.released) return false;
    let failedSynchronously = false;
    const complete = (success: boolean, error: string, _records?: Array<SessionReplayRecord>, resources?: Array<string>): void => {
      if (!success) failedSynchronously = true;
      finish(success, error, resources);
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

  public removeResources(ids: Array<string>, canRemove: () => boolean): Promise<boolean> {
    if (this.closing) return this.closedPromise.then((): boolean => false);
    return new Promise<boolean>((resolve: (success: boolean) => void): void => {
      this.addJob({ id: ++this.nextId, kind: 'removeResources', queuedAt: Date.now(),
        segmentIds: ids.slice(), canRemove, finish: (success: boolean): void => resolve(success) });
      this.dispatch();
    });
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
  public getLastFailure(): string { return this.lastFailure; }

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
      if (this.isSnapshot(this.jobs[index]) &&
        !(keepViewStart && (kind === 'start' || kind === 'transition' || kind === 'settled'))) {
        const dropped = this.jobs.splice(index, 1)[0];
        dropped.complete?.(null, REPLAY_COALESCED_REASON);
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
    this.addJob({ id: ++this.nextId, kind: 'addImage', queuedAt: Date.now(), componentId: key, bytes: copy, mimeType });
    this.dispatch();
  }

  public unregisterImageAsset(componentId: string): void {
    if (this.closing) return;
    const key = componentId.trim();
    this.registeredImages.delete(key);
    this.addJob({ id: ++this.nextId, kind: 'removeImage', queuedAt: Date.now(), componentId: key });
    this.dispatch();
  }

  /** Seal new captures, retaining every accepted frame and image until exit. */
  public close(): void {
    this.closing = true;
    this.dispatch();
  }

  private isSnapshot(job: ReplayQueuedJob): boolean {
    return job.kind === 'start' || job.kind === 'full' || job.kind === 'automatic' ||
      job.kind === 'transition' || job.kind === 'settled';
  }

  private addJob(job: ReplayQueuedJob): void {
    if (this.completing) this.jobs.splice(this.callbackInsertIndex++, 0, job);
    else this.jobs.push(job);
    this.maxDepth = Math.max(this.maxDepth, this.jobs.length + (this.active === null ? 0 : 1));
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
    if (this.jobs.length === 0) {
      if (this.closing) {
        if (!this.closeFlushQueued && this.thread !== null) {
          this.closeFlushQueued = true;
          this.addJob({ id: ++this.nextId, kind: 'flush', queuedAt: Date.now() });
          this.dispatch();
          return;
        }
        const thread = this.thread;
        this.thread = null;
        if (thread === null) {
          if (!this.released) {
            this.reportDiagnostics(true);
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
      const pending = this.jobs.splice(0, this.jobs.length);
      for (let index = 0; index < pending.length; index++) {
        try {
          this.failJob(pending[index], this.unavailableReason);
        } catch (_) { }
      }
      if (this.closing) this.dispatch();
      return;
    }
    // A stale job's completion callback may synchronously enqueue and dispatch
    // a replacement. Stop this drain once that callback has claimed the slot.
    while (this.active === null && this.jobs.length > 0) {
      const job = this.jobs.shift();
      if (job === undefined) break;
      if (!this.closing && this.isSnapshot(job) &&
        isReplaySnapshotExpired(job.queuedAt, Date.now(), job.kind as ReplaySnapshotKind)) {
        this.expired++;
        this.reportDiagnostics();
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
      if (job.kind === 'removeResources' && !job.canRemove?.()) {
        job.finish?.(false, 'Resource was reused after upload started.');
        continue;
      }
      this.active = job;
      try {
        if (this.isSnapshot(job)) {
          const handoffAt = this.diagnostics === null ? 0 : Date.now();
          this.thread?.postMessage({
            id: job.id, phase: 'capture', kind: job.kind, capture: job.capture,
            snapshot: job.snapshot, queuedAt: job.queuedAt, draining: this.closing
          } as ReplayWorkerMessage);
          job.handoffMs = this.diagnostics === null ? 0 : Math.max(0, Date.now() - handoffAt);
        } else {
          this.thread?.postMessage({
            id: job.id, phase: job.kind === 'barrier' ? 'flush' : job.kind, context: job.context, records: job.records,
            storeKind: job.storeKind, requiresStart: job.requiresStart, sessionId: job.sessionId,
            timestamp: job.timestamp, segmentIds: job.segmentIds, baselineSnapshot: job.baselineSnapshot,
            baselineViewport: job.baselineViewport, componentId: job.componentId, bytes: job.bytes, mimeType: job.mimeType
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
    if (message.phase === 'done') {
      this.finish(message.result ?? null, message.error ?? '', message.success ?? true, message.segmentIds ?? [],
        message.records, message.resourceNames);
    } else if (message.phase === 'error') {
      // Stop may race the Worker's age check for the already-dispatched frame.
      // Retry that immutable handoff once in drain mode; do not read the UI.
      if (this.closing && this.isSnapshot(job) && message.error === REPLAY_STALE_QUEUE_REASON) {
        try {
          this.thread?.postMessage({
            id: job.id, phase: 'capture', kind: job.kind, capture: job.capture,
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
    segmentIds: Array<string> = [], writtenRecords?: Array<SessionReplayRecord>, resourceNames?: Array<string>
  ): void {
    const job = this.active;
    this.active = null;
    this.completing = true;
    if (job !== null && this.isSnapshot(job)) {
      if (error === REPLAY_STALE_QUEUE_REASON) this.expired++;
      else if (result === null || !result.stored) this.failures++;
      if (result?.timings !== undefined) result.timings.handoffMs = job.handoffMs ?? 0;
      this.diagnostics?.record(result, job.queuedAt);
      this.reportDiagnostics(job.kind === 'settled');
    }
    try {
      if (job?.kind === 'barrier') {
        if (!success) job.reject?.(new Error(error));
        else {
          try { job.barrierAction?.(); job.resolve?.(); }
          catch (failure) { job.reject?.(new Error(String(failure))); }
        }
      } else if (job?.kind === 'flush') {
        if (!success) this.lastFailure = error;
      } else if (job?.kind === 'list') {
        if (success) job.listResolve?.(segmentIds);
        else job.listReject?.(new Error(error));
      } else if (job !== null && this.isSnapshot(job)) job.complete?.(result, error);
      else job?.finish?.(success, error, writtenRecords, resourceNames);
    } finally {
      this.completing = false;
      this.callbackInsertIndex = 0;
      this.dispatch();
    }
  }

  private reportDiagnostics(force: boolean = false): void {
    try {
      this.diagnostics?.report(this.jobs.length + (this.active === null ? 0 : 1), this.maxDepth,
        this.coalesced, this.deferred, this.expired, this.failures, force);
    } catch (_) { }
  }

  private failJob(job: ReplayQueuedJob | null, reason: string): void {
    if (job === null) return;
    if (job.kind === 'barrier') job.reject?.(new Error(reason));
    else if (job.kind === 'flush') this.lastFailure = reason;
    else if (job.kind === 'list') job.listReject?.(new Error(reason));
    else if (this.isSnapshot(job)) {
      this.failures++;
      job.complete?.(null, reason);
    }
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
