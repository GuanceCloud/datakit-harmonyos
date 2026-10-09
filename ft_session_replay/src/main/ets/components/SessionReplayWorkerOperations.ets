import { ArkUIReplayCollector, ArkUIReplayLightSnapshot, CapturedReplayImageResource } from './ArkUIReplayCollector';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySegmentStore } from './SessionReplaySegmentStore';
import {
  ReplaySnapshotKind,
  ReplayViewport,
  ReplayWorkerCommit,
  ReplayWorkerOptions,
  ReplayWorkerResult
} from './SessionReplayWorkQueue';
import {
  FullSnapshotData, ReplayRecordType, ReplayViewportData, ReplayViewportResizeData, serializeReplayEnvelope,
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
  private readonly fullSnapshotIntervalMs: number;
  private readonly errorSampleWindowMs: number;
  private needsFullSnapshot: boolean = false;
  private baselineContextKey: string = '';
  private lastFullSnapshotAt: number = 0;
  private viewport: ReplayViewport | null = null;
  private readonly startedViews: Set<string> = new Set();
  private lastWriteError: string = '';
  private lastWrittenRecords: Array<SessionReplayRecord> = [];

  constructor(options: ReplayWorkerOptions) {
    const config = new FTSessionReplayConfig()
      .setTextAndInputPrivacy(options.textPrivacy as TextAndInputPrivacy)
      .setImagePrivacy(options.imagePrivacy as ImagePrivacy);
    this.collector = new ArkUIReplayCollector(options.maxNodes, config);
    this.fullSnapshotIntervalMs = options.fullSnapshotIntervalMs;
    this.errorSampleWindowMs = options.errorSampleWindowMs;
    this.mainStore = options.filesDir.length === 0 ? null :
      new SessionReplaySegmentStore(options.filesDir, options.maxBytes, options.maxRecordsPerSegment);
    this.errorStore = options.filesDir.length === 0 ? null :
      new SessionReplaySegmentStore(options.filesDir, options.maxBytes, options.maxRecordsPerSegment, 'error_segments');
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
      resources: this.collector.takeCapturedImageResources()
    };
    return materialized;
  }

  public process(kind: ReplaySnapshotKind, commit: ReplayWorkerCommit): ReplayWorkerResult {
    const snapshot = commit.snapshot;
    const viewport = commit.viewport;
    const store = commit.storeKind === 'main' ? this.mainStore :
      (commit.storeKind === 'error' ? this.errorStore : null);
    const contextKey = `${commit.storeKind}|${this.viewKey(commit.context)}`;
    let records: Array<SessionReplayRecord> = [];
    // An old View's accepted frames may finish after the UI has switched to
    // another View. Checkpoints and viewport belong to this ordered Worker
    // baseline, rather than the active page's completion callbacks.
    const sameContext = this.baselineContextKey === contextKey;
    let lastFullSnapshotAt = sameContext ? this.lastFullSnapshotAt : 0;
    const previousViewport = sameContext ? this.viewport : commit.previousViewport;
    if (kind === 'start') {
      this.processor.reset();
      this.needsFullSnapshot = false;
      records = this.processor.createViewStartRecords(
        snapshot,
        viewport === null ? undefined : viewport.width,
        viewport === null ? undefined : viewport.height
      );
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (kind === 'full') {
      this.processor.setFullSnapshotBaseline(snapshot);
      records = [snapshot];
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (this.viewportChanged(previousViewport, viewport)) {
      const next = viewport as ReplayViewport;
      records = [this.processor.createViewportResizeRecord(next.width, next.height, snapshot.timestamp), snapshot];
      this.processor.setFullSnapshotBaseline(snapshot);
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (!this.processor.hasBaseline() || this.baselineContextKey !== contextKey ||
      this.needsFullSnapshot || store?.requiresFullSnapshot(commit.context) || lastFullSnapshotAt === 0 ||
      snapshot.timestamp - lastFullSnapshotAt >= this.fullSnapshotIntervalMs) {
      records = [snapshot];
      this.processor.setFullSnapshotBaseline(snapshot);
      lastFullSnapshotAt = snapshot.timestamp;
    } else {
      const mutation = this.processor.createMutationRecord(snapshot);
      if (mutation !== null) records = [mutation];
    }

    const data = snapshot.data as FullSnapshotData;
    let stored = store === null || records.length === 0 || store.append(commit.context, records);
    if (!stored && store !== null && records.length === 1 &&
      records[0].type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
      // Quota eviction can require a new checkpoint. Recover this same frame,
      // even if the page never draws again after the failed mutation write.
      records = [snapshot];
      stored = store.append(commit.context, records);
      if (stored) {
        this.processor.setFullSnapshotBaseline(snapshot);
        lastFullSnapshotAt = snapshot.timestamp;
      }
    }
    const payload = records.length === 0 ? '' : serializeReplayEnvelope(commit.context, records);
    if (!stored) this.needsFullSnapshot = true;
    else {
      this.baselineContextKey = contextKey;
      this.lastFullSnapshotAt = lastFullSnapshotAt;
      this.viewport = viewport === null ? null : { width: viewport.width, height: viewport.height };
      if (records.length > 0) this.needsFullSnapshot = false;
    }
    if (stored && store === this.errorStore && records.length > 0) {
      this.errorStore?.pruneBefore(Date.now() - this.errorSampleWindowMs);
    }
    if (stored && records.some((record: SessionReplayRecord): boolean =>
      record.type === ReplayRecordType.FULL_SNAPSHOT && record.slotId === undefined)) {
      this.startedViews.add(this.viewKey(commit.context));
    }
    return {
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
    if (store === this.errorStore && records.length > 0) {
      this.errorStore?.pruneBefore(Date.now() - this.errorSampleWindowMs);
    }
    for (let index = 0; index < records.length; index++) {
      if (records[index].type === ReplayRecordType.VIEW_END) {
        this.startedViews.delete(this.viewKey(context));
        break;
      }
    }
    return true;
  }

  public getLastWriteError(): string {
    return this.lastWriteError;
  }

  public getLastWrittenRecords(): Array<SessionReplayRecord> {
    return this.lastWrittenRecords.slice();
  }

  public promote(sessionId: string, timestamp: number): boolean {
    if (this.errorStore === null || this.mainStore === null) return false;
    return this.errorStore.promoteSessionWindow(sessionId, timestamp, this.errorSampleWindowMs, this.mainStore);
  }

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
