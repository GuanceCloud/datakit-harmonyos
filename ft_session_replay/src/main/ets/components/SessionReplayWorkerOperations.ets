import { ArkUIReplayCollector, ArkUIReplayLightSnapshot, CapturedReplayImageResource } from './ArkUIReplayCollector';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from './FTSessionReplayConfig';
import { SessionReplayResourceStore, sha256 } from './SessionReplayResourceStore';
import { ReplayResourceCleanupResult, replayResourceCleanup } from './ReplayResourceCleanup';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySegmentStore } from './SessionReplaySegmentStore';
import {
  ReplaySnapshotKind,
  ReplayViewport,
  ReplayWorkerCommit,
  ReplayWorkerCapture,
  ReplayWorkerOptions,
  ReplayWorkerResult
} from './SessionReplayWorkQueue';
import {
  ReplayImageWireframe, FullSnapshotData, ReplayRecordType, ReplayViewportData, ReplayViewportResizeData, serializeReplayEnvelope,
  SessionReplayContext, SessionReplayRecord
} from './SessionReplayProtocol';

export interface ReplayMaterializedSnapshot {
  record: SessionReplayRecord;
  resources: Array<CapturedReplayImageResource>;
}

/** State and filesystem work owned exclusively by the Replay ThreadWorker. */
export class SessionReplayWorkerOperations {
  private readonly collector: ArkUIReplayCollector;
  private readonly processor: ReplaySnapshotProcessor = new ReplaySnapshotProcessor();
  private readonly mainStore: SessionReplaySegmentStore | null;
  private readonly errorStore: SessionReplaySegmentStore | null;
  private readonly diagnosticsEnabled: boolean;
  private lastEffectiveKey: string = '';
  private lastEffectiveAt: number = 0;
  private readonly fullSnapshotIntervalMs: number;
  private readonly errorSampleWindowMs: number;
  private readonly mainResources: SessionReplayResourceStore | null;
  private readonly errorResources: SessionReplayResourceStore | null;
  private readonly imageHashes: Map<Uint8Array, string> = new Map();
  private cachedImageBytes: number = 0;
  private needsFullSnapshot: boolean = false;
  private baselineContextKey: string = '';
  private lastFullSnapshotAt: number = 0;
  private viewport: ReplayViewport | null = null;
  private readonly startedViews: Set<string> = new Set();
  private lastErrorPruneAt: number = 0;
  private lastPromotedResources: Array<string> = [];
  private lastWriteError: string = '';
  private lastWrittenRecords: Array<SessionReplayRecord> = [];

  constructor(options: ReplayWorkerOptions) {
    const config = new FTSessionReplayConfig()
      .setTextAndInputPrivacy(options.textPrivacy as TextAndInputPrivacy)
      .setCaptureVisiblePassword(options.captureVisiblePassword === true)
      .setImagePrivacy(options.imagePrivacy as ImagePrivacy)
      .setTouchPrivacy((options.touchPrivacy ?? TouchPrivacy.HIDE) as TouchPrivacy);
    this.collector = new ArkUIReplayCollector(options.maxNodes, config);
    this.diagnosticsEnabled = options.diagnosticsEnabled ?? false;
    this.fullSnapshotIntervalMs = options.fullSnapshotIntervalMs;
    this.errorSampleWindowMs = options.errorSampleWindowMs;
    this.mainStore = options.filesDir.length === 0 ? null :
      new SessionReplaySegmentStore(options.filesDir, options.maxBytes, options.maxRecordsPerSegment, 'segments', true, true);
    this.errorStore = options.filesDir.length === 0 ? null :
      new SessionReplaySegmentStore(options.filesDir, options.maxBytes, options.maxRecordsPerSegment, 'error_segments', true, true);
    this.mainResources = options.filesDir.length === 0 ? null :
      new SessionReplayResourceStore(options.filesDir, options.maxBytes, 'resources');
    this.errorResources = options.filesDir.length === 0 ? null :
      new SessionReplayResourceStore(options.filesDir, options.maxBytes, 'error_resources');
    this.restoreStartedViews();
  }

  public registerImageAsset(componentId: string, bytes: Uint8Array, mimeType: string): void {
    this.collector.registerImageAsset(componentId, bytes, mimeType);
  }

  public unregisterImageAsset(componentId: string): void {
    this.collector.unregisterImageAsset(componentId);
  }

  public materialize(snapshot: ArkUIReplayLightSnapshot): ReplayMaterializedSnapshot {
    const record = this.collector.materializeLightSnapshot(snapshot);
    const materialized: ReplayMaterializedSnapshot = {
      record,
      resources: this.collector.takeCapturedImageResources(false)
    };
    return materialized;
  }

  /** Detached nodes enter once; only emitted protocol records leave the Worker. */
  public capture(kind: ReplaySnapshotKind, light: ArkUIReplayLightSnapshot, capture: ReplayWorkerCapture): ReplayWorkerResult {
    const startedAt = this.diagnosticsEnabled ? Date.now() : 0;
    const materialized = this.materialize(light);
    const materializedAt = this.diagnosticsEnabled ? Date.now() : 0;
    const store = capture.storeKind === 'main' ? this.mainResources :
      (capture.storeKind === 'error' ? this.errorResources : null);
    const resources = new Map<string, string>();
    for (const resource of materialized.resources) {
      let hash = this.imageHashes.get(resource.bytes);
      if (hash === undefined) {
        hash = sha256(resource.bytes);
        if (this.cachedImageBytes + resource.bytes.byteLength > 8 * 1024 * 1024 || this.imageHashes.size >= 64) {
          this.imageHashes.clear();
          this.cachedImageBytes = 0;
        }
        this.imageHashes.set(resource.bytes, hash);
        this.cachedImageBytes += resource.bytes.byteLength;
      }
      // Revalidate files even on a hash hit: upload or sandbox reclaim may delete them.
      const name = store?.put(capture.context, resource.bytes, resource.mimeType, hash) ?? null;
      if (name !== null) resources.set(resource.token, name);
    }
    const data = materialized.record.data as FullSnapshotData;
    for (let index = 0; index < data.wireframes.length; index++) {
      const frame = data.wireframes[index];
      if (frame.type !== 'image' || frame.resourceId === undefined) continue;
      const name = resources.get(frame.resourceId);
      if (name !== undefined) frame.resourceId = name;
      else {
        const masked: ReplayImageWireframe = {
          id: frame.id, type: 'image', x: frame.x, y: frame.y,
          width: frame.width, height: frame.height, isEmpty: true
        };
        masked.shapeStyle = frame.shapeStyle;
        masked.border = frame.border;
        masked.clip = frame.clip;
        masked.zIndex = frame.zIndex;
        masked.permanentId = frame.permanentId;
        data.wireframes[index] = masked;
      }
    }
    const commit: ReplayWorkerCommit = {
      context: capture.context, snapshot: materialized.record, viewport: capture.viewport,
      previousViewport: capture.previousViewport, lastFullSnapshotAt: capture.lastFullSnapshotAt,
      storeKind: capture.storeKind, captureTriggers: capture.captureTriggers
    };
    const resourceDoneAt = this.diagnosticsEnabled ? Date.now() : 0;
    const result = this.process(kind, commit);
    if (result.timings !== undefined) {
      result.timings.startedAt = startedAt;
      result.timings.collectionMs = light.collectionDurationMs ?? 0;
      result.timings.materializeMs = Math.max(0, materializedAt - startedAt);
      result.timings.resourceMs = Math.max(0, resourceDoneAt - materializedAt);
      result.timings.workerMs = Math.max(0, Date.now() - startedAt);
    }
    result.resourceNames = Array.from(resources.values());
    return result;
  }

  public removeResources(ids: Array<string>): ReplayResourceCleanupResult {
    return this.mainResources?.removeAcknowledged(ids) ??
      replayResourceCleanup(0, 0, ids.length, 'Replay resource storage is unavailable.');
  }

  public process(kind: ReplaySnapshotKind, commit: ReplayWorkerCommit): ReplayWorkerResult {
    const processingAt = this.diagnosticsEnabled ? Date.now() : 0;
    const snapshot = commit.snapshot;
    const viewport = commit.viewport;
    const store = commit.storeKind === 'main' ? this.mainStore :
      (commit.storeKind === 'error' ? this.errorStore : null);
    const contextKey = `${commit.storeKind}|${this.viewKey(commit.context)}`;
    let records: Array<SessionReplayRecord> = [];
    let captureReason = 'unchanged';
    // An old View's accepted frames may finish after the UI has switched to
    // another View. Checkpoints and viewport belong to this ordered Worker
    // baseline, rather than the active page's completion callbacks.
    const sameContext = this.baselineContextKey === contextKey;
    let lastFullSnapshotAt = sameContext ? this.lastFullSnapshotAt : 0;
    const previousViewport = sameContext ? this.viewport : commit.previousViewport;
    if (kind === 'start') {
      captureReason = 'view_start';
      this.processor.reset();
      this.needsFullSnapshot = false;
      records = this.processor.createViewStartRecords(
        snapshot,
        viewport === null ? undefined : viewport.width,
        viewport === null ? undefined : viewport.height
      );
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (kind === 'full') {
      captureReason = 'forced_full';
      records = [snapshot];
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (this.viewportChanged(previousViewport, viewport)) {
      captureReason = 'viewport_change';
      const next = viewport as ReplayViewport;
      records = [this.processor.createViewportResizeRecord(next.width, next.height, snapshot.timestamp), snapshot];
      lastFullSnapshotAt = snapshot.timestamp;
    } else {
      const fullReason = !this.processor.hasBaseline() ? 'baseline_missing' :
        this.baselineContextKey !== contextKey ? 'context_change' :
        this.needsFullSnapshot ? 'write_recovery' :
        store?.requiresFullSnapshot(commit.context) ? 'storage_checkpoint' :
        lastFullSnapshotAt === 0 ? 'baseline_missing' : '';
      if (fullReason.length > 0) {
        captureReason = fullReason;
        records = [snapshot];
        lastFullSnapshotAt = snapshot.timestamp;
      } else {
        const mutation = this.processor.diffMutationRecord(snapshot);
        if (mutation !== null) {
          // Time alone is not a visual change. Idle frames never create periodic records.
          if (snapshot.timestamp - lastFullSnapshotAt >= this.fullSnapshotIntervalMs) {
            records = [snapshot];
            captureReason = 'periodic_full';
            lastFullSnapshotAt = snapshot.timestamp;
          } else {
            records = [mutation];
            captureReason = 'mutation';
          }
        }
      }
    }

    const diffDoneAt = this.diagnosticsEnabled ? Date.now() : 0;
    const data = snapshot.data as FullSnapshotData;
    let stored = store === null || records.length === 0 || store.append(commit.context, records);
    if (!stored && store !== null && records.length === 1 &&
      records[0].type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
      // Quota eviction can require a new checkpoint. Recover this same frame,
      // even if the page never draws again after the failed mutation write.
      records = [snapshot];
      captureReason = 'write_recovery';
      stored = store.append(commit.context, records);
      if (stored) {
        lastFullSnapshotAt = snapshot.timestamp;
      }
    }
    if (kind === 'settled' && stored && store !== null) stored = store.flush();
    const writeDoneAt = this.diagnosticsEnabled ? Date.now() : 0;
    const payload = records.length === 0 ? '' : serializeReplayEnvelope(commit.context, records);
    if (!stored) this.needsFullSnapshot = true;
    else {
      this.baselineContextKey = contextKey;
      this.lastFullSnapshotAt = lastFullSnapshotAt;
      this.viewport = viewport === null ? null : { width: viewport.width, height: viewport.height };
      if (records.length > 0) {
        this.processor.setFullSnapshotBaseline(snapshot);
        this.needsFullSnapshot = false;
      }
    }
    this.pruneErrorStore(store, stored && records.length > 0);
    if (stored && records.some((record: SessionReplayRecord): boolean =>
      record.type === ReplayRecordType.FULL_SNAPSHOT && record.slotId === undefined)) {
      this.startedViews.add(this.viewKey(commit.context));
    }
    const result: ReplayWorkerResult = {
      records,
      payload,
      wireframeCount: data.wireframes.length,
      stored,
      writeError: stored ? '' : (store?.getLastWriteError() ?? 'Session Replay batch write failed.'),
      lastFullSnapshotAt,
      viewport,
      storeKind: commit.storeKind,
      segmentIds: store === null || records.length === 0 ? [] : store.getLastAppendedIds()
    };
    if (this.diagnosticsEnabled) {
      result.captureTriggers = commit.captureTriggers;
      result.captureReason = captureReason;
      const effective = stored && records.length > 0;
      result.timings = {
        startedAt: processingAt, collectionMs: 0, materializeMs: 0, resourceMs: 0,
        diffMs: Math.max(0, diffDoneAt - processingAt), writeMs: Math.max(0, writeDoneAt - diffDoneAt),
        workerMs: Math.max(0, Date.now() - processingAt),
        effectiveIntervalMs: effective && this.lastEffectiveKey === contextKey ?
          Math.max(0, snapshot.timestamp - this.lastEffectiveAt) : 0
      };
      if (effective) { this.lastEffectiveKey = contextKey; this.lastEffectiveAt = snapshot.timestamp; }
    }
    return result;
  }

  public appendRecords(
    context: SessionReplayContext, records: Array<SessionReplayRecord>,
    storeKind: 'main' | 'error' | 'none', requiresStart: boolean = false,
    baselineSnapshot: SessionReplayRecord | null = null,
    baselineViewport: ReplayViewport | null = null
  ): boolean {
    this.lastWriteError = '';
    this.lastWrittenRecords = [];
    if (requiresStart && !this.startedViews.has(this.viewKey(context))) {
      this.lastWriteError = 'The native View Start snapshot was not saved; its later records were discarded.';
      return false;
    }
    const store = storeKind === 'main' ? this.mainStore : (storeKind === 'error' ? this.errorStore : null);
    let writtenRecords = records;
    let stored = store === null || store.append(context, writtenRecords);
    if (!stored && store !== null && baselineSnapshot !== null && records.length === 1 &&
      records[0].type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
      writtenRecords = [baselineSnapshot];
      stored = store.append(context, writtenRecords);
    }
    if (!stored) {
      this.needsFullSnapshot = true;
      this.lastWriteError = store?.getLastWriteError() ?? 'Session Replay batch write failed.';
      const partialIds = store?.getLastAppendedIds() ?? [];
      if (partialIds.length > 0 && !store?.remove(partialIds)) {
        this.lastWriteError += ' Partially saved segments could not be removed.';
      }
      return false;
    }
    // Manual native Full Snapshots and viewport resizes must advance the same
    // diff baseline used by automatic Worker snapshots. Web records have a slotId.
    this.lastWrittenRecords = writtenRecords.slice();
    const contextKey = `${storeKind}|${this.viewKey(context)}`;
    for (let index = 0; index < writtenRecords.length; index++) {
      if (writtenRecords[index].type === ReplayRecordType.FULL_SNAPSHOT && writtenRecords[index].slotId === undefined) {
        if (this.baselineContextKey !== contextKey) this.viewport = null;
        this.processor.setFullSnapshotBaseline(writtenRecords[index]);
        this.baselineContextKey = contextKey;
        this.lastFullSnapshotAt = writtenRecords[index].timestamp;
        this.viewport = this.snapshotViewport(writtenRecords[index]);
        this.needsFullSnapshot = false;
        this.startedViews.add(this.viewKey(context));
      }
    }
    if (baselineSnapshot !== null && baselineSnapshot.slotId === undefined) {
      if (this.baselineContextKey !== contextKey) {
        this.lastFullSnapshotAt = 0;
        this.viewport = null;
      }
      this.processor.setFullSnapshotBaseline(baselineSnapshot);
      this.baselineContextKey = contextKey;
      this.needsFullSnapshot = false;
    }
    if (this.baselineContextKey === contextKey) {
      if (baselineViewport !== null) {
        this.viewport = { width: baselineViewport.width, height: baselineViewport.height };
      }
      // Explicit viewport records take precedence over root dimensions when
      // the keyboard overlays the layout rather than resizing its root.
      for (const record of writtenRecords) {
        if (record.slotId !== undefined) continue;
        if (record.type === ReplayRecordType.VIEWPORT) {
          const data = record.data as ReplayViewportData;
          this.viewport = { width: data.width, height: data.height };
        } else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
          const data = record.data as ReplayViewportResizeData;
          if (data.source === 4) this.viewport = { width: data.width, height: data.height };
        }
      }
    }
    this.pruneErrorStore(store, records.length > 0);
    for (let index = 0; index < records.length; index++) {
      if (records[index].type === ReplayRecordType.VIEW_END) {
        this.startedViews.delete(this.viewKey(context));
        break;
      }
    }
    return true;
  }

  public flush(): boolean {
    const main = this.mainStore?.flush() ?? true;
    const error = this.errorStore?.flush() ?? true;
    if (!main || !error) this.lastWriteError = this.mainStore?.getLastWriteError() ??
      this.errorStore?.getLastWriteError() ?? 'Replay journal seal failed.';
    return main && error;
  }

  private pruneErrorStore(store: SessionReplaySegmentStore | null, changed: boolean): void {
    if (!changed || store === null || store !== this.errorStore || Date.now() - this.lastErrorPruneAt < 1000) return;
    this.lastErrorPruneAt = Date.now();
    const cutoff = Date.now() - this.errorSampleWindowMs;
    store.pruneBefore(cutoff);
    this.errorResources?.pruneBefore(cutoff, store.getReferencedResourceNames(cutoff));
  }

  public getLastWriteError(): string {
    return this.lastWriteError;
  }

  public getLastWrittenRecords(): Array<SessionReplayRecord> {
    return this.lastWrittenRecords.slice();
  }

  public promote(sessionId: string, timestamp: number): boolean {
    if (this.errorStore === null || this.mainStore === null) return false;
    const retained = this.errorStore.getReferencedResourceNames(timestamp - this.errorSampleWindowMs, sessionId);
    this.lastPromotedResources = Array.from(retained);
    if (this.errorResources !== null && this.mainResources !== null &&
      !this.errorResources.promoteSessionWindow(sessionId, timestamp, this.errorSampleWindowMs, this.mainResources, retained)) return false;
    return this.errorStore.promoteSessionWindow(sessionId, timestamp, this.errorSampleWindowMs, this.mainStore);
  }

  public getLastPromotedResources(): Array<string> { return this.lastPromotedResources.slice(); }

  public remove(storeKind: 'main' | 'error' | 'none', ids: Array<string>): boolean {
    const store = storeKind === 'main' ? this.mainStore : (storeKind === 'error' ? this.errorStore : null);
    return store !== null && store.remove(ids);
  }

  public listPendingIds(): Array<string> {
    return this.mainStore?.listIds() ?? [];
  }

  private viewportChanged(previous: ReplayViewport | null, next: ReplayViewport | null): boolean {
    return next !== null && (previous === null || previous.width !== next.width || previous.height !== next.height);
  }

  private snapshotViewport(snapshot: SessionReplayRecord): ReplayViewport | null {
    const root = (snapshot.data as FullSnapshotData).wireframes[0];
    if (root === undefined || !Number.isFinite(root.width) || !Number.isFinite(root.height) ||
      root.width <= 0 || root.height <= 0) return null;
    return { width: root.width, height: root.height };
  }

  private viewKey(context: SessionReplayContext): string {
    return `${context.applicationId}|${context.sessionId}|${context.viewId}`;
  }

  private restoreStartedViews(): void {
    const stores: Array<SessionReplaySegmentStore | null> = [this.mainStore, this.errorStore];
    for (let storeIndex = 0; storeIndex < stores.length; storeIndex++) {
      const segments = stores[storeIndex]?.list() ?? [];
      for (let index = 0; index < segments.length; index++) {
        const segment = segments[index];
        for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++) {
          const record = segment.records[recordIndex];
          if (record.slotId !== undefined) continue;
          if (record.type === ReplayRecordType.META) this.startedViews.add(this.viewKey(segment.context));
          else if (record.type === ReplayRecordType.VIEW_END) this.startedViews.delete(this.viewKey(segment.context));
        }
      }
    }
  }
}
