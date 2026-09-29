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
  FullSnapshotData, ReplayRecordType, serializeReplayEnvelope,
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
  private readonly startedViews: Set<string> = new Set();
  private lastWriteError: string = '';

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
    let records: Array<SessionReplayRecord> = [];
    let lastFullSnapshotAt = commit.lastFullSnapshotAt;
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
    } else if (this.viewportChanged(commit.previousViewport, viewport)) {
      const next = viewport as ReplayViewport;
      records = [this.processor.createViewportResizeRecord(next.width, next.height, snapshot.timestamp), snapshot];
      this.processor.setFullSnapshotBaseline(snapshot);
      lastFullSnapshotAt = snapshot.timestamp;
    } else if (this.needsFullSnapshot || lastFullSnapshotAt === 0 ||
      snapshot.timestamp - lastFullSnapshotAt >= this.fullSnapshotIntervalMs) {
      records = [snapshot];
      this.processor.setFullSnapshotBaseline(snapshot);
      lastFullSnapshotAt = snapshot.timestamp;
    } else {
      const mutation = this.processor.createMutationRecord(snapshot);
      if (mutation !== null) records = [mutation];
    }

    const data = snapshot.data as FullSnapshotData;
    const payload = records.length === 0 ? '' : serializeReplayEnvelope(commit.context, records);
    const store = commit.storeKind === 'main' ? this.mainStore :
      (commit.storeKind === 'error' ? this.errorStore : null);
    const stored = store === null || records.length === 0 || store.append(commit.context, records);
    if (!stored) this.needsFullSnapshot = true;
    else if (records.length > 0) this.needsFullSnapshot = false;
    if (stored && store === this.errorStore && records.length > 0) {
      this.errorStore?.pruneBefore(Date.now() - this.errorSampleWindowMs);
    }
    if (kind === 'start' && stored && records.length > 0) {
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
    storeKind: 'main' | 'error' | 'none', requiresStart: boolean = false
  ): boolean {
    this.lastWriteError = '';
    if (requiresStart && !this.startedViews.has(this.viewKey(context))) {
      this.lastWriteError = 'The native View Start snapshot was not saved; its later records were discarded.';
      return false;
    }
    const store = storeKind === 'main' ? this.mainStore : (storeKind === 'error' ? this.errorStore : null);
    const stored = store === null || store.append(context, records);
    if (!stored) {
      this.lastWriteError = store?.getLastWriteError() ?? 'Session Replay batch write failed.';
      const partialIds = store?.getLastAppendedIds() ?? [];
      if (partialIds.length > 0 && !store?.remove(partialIds)) {
        this.lastWriteError += ' Partially saved segments could not be removed.';
      }
      return false;
    }
    // Manual native Full Snapshots and viewport resizes must advance the same
    // diff baseline used by automatic Worker snapshots. Web records have a slotId.
    for (let index = 0; index < records.length; index++) {
      if (records[index].type === ReplayRecordType.FULL_SNAPSHOT && records[index].slotId === undefined) {
        this.processor.setFullSnapshotBaseline(records[index]);
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
