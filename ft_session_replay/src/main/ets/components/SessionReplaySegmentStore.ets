import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  ReplayMutationData, ReplayRecordType, SessionReplayContext, SessionReplayGlobalContext, SessionReplayRecord
} from './SessionReplayProtocol';

/** One durable batch of Android-compatible records for a single RUM View. */
export interface SessionReplayStoredSegment {
  version: number;
  id: string;
  createdAt: number;
  context: SessionReplayContext;
  records: Array<SessionReplayRecord>;
}

/** Minimal boundary used by the recorder so storage can remain optional. */
export interface SessionReplayRecordStore {
  append(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean;
}

/**
 * Crash-safe private-file segment storage. Each capture batch is first written
 * to a temporary file, fsynced, then atomically renamed. The oldest segments
 * are evicted before a write when the configured quota would be exceeded.
 */
export class SessionReplaySegmentStore implements SessionReplayRecordStore {
  private static readonly VERSION: number = 1;

  private readonly replayRoot: string;
  private readonly root: string;
  private readonly maxBytes: number;
  private readonly maxRecordsPerSegment: number;
  private sequence: number = 0;
  private lastWriteError: string = '';
  private lastAppendedIds: Array<string> = [];
  private readonly resyncStreams: Set<string> = new Set();

  constructor(
    filesDir: string,
    maxBytes: number,
    maxRecordsPerSegment: number,
    directoryName: string = 'segments',
    recoverOnInit: boolean = true
  ) {
    if (filesDir.trim().length === 0) {
      throw new Error('Session Replay storage requires a non-empty filesDir');
    }
    if (!/^[a-z0-9_]+$/.test(directoryName)) {
      throw new Error('Session Replay storage directory name is invalid');
    }
    this.replayRoot = `${filesDir}/ft_session_replay`;
    this.root = `${this.replayRoot}/${directoryName}`;
    this.maxBytes = Math.max(1024 * 1024, Math.floor(maxBytes));
    this.maxRecordsPerSegment = Math.max(1, Math.floor(maxRecordsPerSegment));
    // `mkdirSync(path, true)` is only available from newer platform APIs.
    // Create each level explicitly so Replay works on the API 12 devices this
    // SDK supports as well as on newer runtimes.
    this.ensureDirectory(this.replayRoot);
    this.ensureDirectory(this.root);
    if (recoverOnInit) this.recover();
  }

  public append(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean {
    this.lastAppendedIds = [];
    if (records.length === 0) {
      return true;
    }
    this.lastWriteError = '';
    try {
      // App sandbox storage may be reclaimed between initialization and a
      // later RUM View. Recreate both levels immediately before the write.
      this.ensureDirectory(this.replayRoot);
      this.ensureDirectory(this.root);
      for (let start = 0; start < records.length; start += this.maxRecordsPerSegment) {
        const segmentRecords = records.slice(start, start + this.maxRecordsPerSegment);
        const segment = this.createSegment(context, segmentRecords);
        const body = JSON.stringify(segment);
        if (!this.reserveBytes(this.byteLength(body), context, segmentRecords)) {
          this.lastWriteError = `Replay storage needs a Full Snapshot or exceeds the configured ${this.maxBytes}-byte quota.`;
          return false;
        }
        this.atomicWrite(`${this.root}/${segment.id}.json`, body);
        this.lastAppendedIds.push(segment.id);
        for (let index = 0; index < segmentRecords.length; index++) {
          if (this.isCheckpoint(segmentRecords[index])) {
            this.resyncStreams.delete(this.streamKey(context, segmentRecords[index]));
          }
        }
      }
      return true;
    } catch (error) {
      this.lastWriteError = `Unable to write Replay segment in ${this.root}: ${String(error)}`;
      return false;
    }
  }

  /** Exposes the latest append failure without leaking application content. */
  public getLastWriteError(): string | null {
    return this.lastWriteError.length === 0 ? null : this.lastWriteError;
  }

  public getLastAppendedIds(): Array<string> {
    return this.lastAppendedIds.slice();
  }

  /** Enumerates candidate batches without parsing their contents. */
  public listIds(): Array<string> {
    return this.segmentFileNames().map((name: string): string => name.substring(0, name.length - '.json'.length));
  }

  /** Reopens valid segments after process restart and removes interrupted writes. */
  public list(): Array<SessionReplayStoredSegment> {
    const segments: Array<SessionReplayStoredSegment> = [];
    const names = this.segmentFileNames();
    for (let index = 0; index < names.length; index++) {
      const path = `${this.root}/${names[index]}`;
      try {
        const segment = JSON.parse(fs.readTextSync(path)) as SessionReplayStoredSegment;
        if (this.isValidSegment(segment, names[index])) {
          segments.push(segment);
        } else {
          fs.unlinkSync(path);
        }
      } catch (_error) {
        try { fs.unlinkSync(path); } catch (_) { }
      }
    }
    return segments;
  }

  /** Removes only successfully acknowledged segments from private storage. */
  public remove(ids: Array<string>): boolean {
    let completed = true;
    for (let index = 0; index < ids.length; index++) {
      const id = ids[index];
      if (!this.isSafeSegmentId(id)) {
        completed = false;
        continue;
      }
      try {
        fs.unlinkSync(`${this.root}/${id}.json`);
      } catch (_error) {
        completed = false;
      }
    }
    return completed;
  }

  /** Keeps the checkpoint and mutation prefix required by the retained window. */
  public pruneBefore(timestamp: number): void {
    const segments = this.list();
    const selected = this.selectWindowRecords(segments, timestamp);
    let ordinal = 0;
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      let keep = false;
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++) {
        if (selected.has(ordinal++)) keep = true;
      }
      if (!keep) {
        this.remove([segment.id]);
      }
    }
  }

  /**
   * Atomically enough at segment granularity for error sampling: copy the
   * surviving window to the normal store, then remove the source only after
   * that durable write succeeds. A failed write leaves source data retryable.
   */
  public promoteSessionWindow(
    sessionId: string,
    timestamp: number,
    windowMs: number,
    destination: SessionReplaySegmentStore
  ): boolean {
    const cutoff = timestamp - Math.max(0, windowMs);
    const segments = this.list().filter((segment: SessionReplayStoredSegment): boolean =>
      segment.context.sessionId === sessionId);
    const selected = this.selectWindowRecords(segments, cutoff);
    let ordinal = 0;
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      const records: Array<SessionReplayRecord> = [];
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++) {
        if (selected.has(ordinal++)) records.push(segment.records[recordIndex]);
      }
      if (records.length === 0) {
        if (!this.remove([segment.id])) {
          return false;
        }
        continue;
      }
      if (!destination.append(segment.context, records)) {
        return false;
      }
      if (!this.remove([segment.id])) {
        return false;
      }
    }
    this.pruneBefore(cutoff);
    return true;
  }

  public getRoot(): string {
    return this.root;
  }

  public getFilesDir(): string {
    return this.replayRoot.substring(0, this.replayRoot.length - '/ft_session_replay'.length);
  }

  public requiresFullSnapshot(context: SessionReplayContext): boolean {
    return this.resyncStreams.has(`${context.applicationId}|${context.sessionId}|${context.viewId}|native`);
  }

  private streamKey(context: SessionReplayContext, record: SessionReplayRecord): string {
    return `${context.applicationId}|${context.sessionId}|${context.viewId}|${record.slotId ?? 'native'}`;
  }

  private isCheckpoint(record: SessionReplayRecord): boolean {
    return record.slotId === undefined ? record.type === ReplayRecordType.FULL_SNAPSHOT : (record.type as number) === 2;
  }

  private isMutation(record: SessionReplayRecord): boolean {
    return (record.slotId === undefined ? record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT : (record.type as number) === 3) &&
      (record.data as ReplayMutationData).source === 0;
  }

  private selectWindowRecords(segments: Array<SessionReplayStoredSegment>, timestamp: number): Set<number> {
    const checkpoints = new Map<string, number>();
    const starts = new Map<string, number>();
    const initialization = new Map<string, Map<number, number>>();
    const selected = new Set<number>();
    let ordinal = 0;
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++, ordinal++) {
        const record = segment.records[recordIndex];
        const key = this.streamKey(segment.context, record);
        if (this.isCheckpoint(record)) checkpoints.set(key, ordinal);
        if (record.type === ReplayRecordType.META || record.type === ReplayRecordType.FOCUS ||
          record.type === ReplayRecordType.VIEWPORT) {
          const events = initialization.get(key) ?? new Map<number, number>();
          events.set(record.type, ordinal);
          initialization.set(key, events);
        }
        if (record.timestamp >= timestamp && !starts.has(key)) {
          starts.set(key, checkpoints.get(key) ?? ordinal);
          initialization.get(key)?.forEach((value: number): void => { selected.add(value); });
        }
      }
    }
    ordinal = 0;
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++, ordinal++) {
        const start = starts.get(this.streamKey(segment.context, segment.records[recordIndex]));
        if (start !== undefined && ordinal >= start) selected.add(ordinal);
      }
    }
    return selected;
  }

  private createSegment(context: SessionReplayContext, records: Array<SessionReplayRecord>): SessionReplayStoredSegment {
    const createdAt = Date.now();
    // More than one store instance can write this directory (UI and Replay
    // Worker). A per-instance random suffix prevents their counters colliding.
    const id = `${createdAt.toString().padStart(13, '0')}-${(++this.sequence).toString().padStart(6, '0')}-${Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0')}`;
    const storedContext: SessionReplayContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
    if (context.globalContext !== undefined) {
      const globalContext: SessionReplayGlobalContext = {};
      const keys = Object.keys(context.globalContext);
      for (let index = 0; index < keys.length; index++) {
        const key = keys[index];
        globalContext[key] = context.globalContext[key];
      }
      storedContext.globalContext = globalContext;
    }
    return {
      version: SessionReplaySegmentStore.VERSION,
      id,
      createdAt,
      context: storedContext,
      records: records.slice()
    };
  }

  private recover(): void {
    const names = this.fileNames();
    for (let index = 0; index < names.length; index++) {
      if (names[index].endsWith('.tmp')) {
        try { fs.unlinkSync(`${this.root}/${names[index]}`); } catch (_) { }
      }
    }
    this.list();
  }

  private reserveBytes(
    incomingBytes: number, context: SessionReplayContext, records: Array<SessionReplayRecord>
  ): boolean {
    if (incomingBytes > this.maxBytes) {
      return false;
    }
    const names = this.segmentFileNames();
    const sizes = new Map<string, number>();
    let usedBytes = 0;
    for (let index = 0; index < names.length; index++) {
      const size = fs.statSync(`${this.root}/${names[index]}`).size;
      sizes.set(names[index].substring(0, names[index].length - '.json'.length), size);
      usedBytes += size;
    }
    if (usedBytes + incomingBytes <= this.maxBytes && this.resyncStreams.size === 0) return true;
    const segments = this.list();
    const victims = new Set<string>();
    const blocked = new Set<string>();
    this.resyncStreams.forEach((key: string): void => { blocked.add(key); });
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      // Losing any structural record invalidates its later diffs until the
      // next checkpoint. Cascade across interleaved streams in whole files.
      const restored = new Set<string>();
      let dependent = false;
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++) {
        const record = segment.records[recordIndex];
        const key = this.streamKey(segment.context, record);
        if (this.isCheckpoint(record)) restored.add(key);
        else if (this.isMutation(record) && blocked.has(key) && !restored.has(key)) dependent = true;
      }
      if (usedBytes + incomingBytes > this.maxBytes || dependent) {
        victims.add(segment.id);
        usedBytes -= sizes.get(segment.id) ?? 0;
        for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++) {
          const record = segment.records[recordIndex];
          if (this.isCheckpoint(record) || this.isMutation(record)) {
            blocked.add(this.streamKey(segment.context, record));
          }
        }
      } else {
        restored.forEach((key: string): void => { blocked.delete(key); });
      }
    }
    const restored = new Set<string>();
    for (let index = 0; index < records.length; index++) {
      const key = this.streamKey(context, records[index]);
      if (this.isCheckpoint(records[index])) restored.add(key);
      else if (this.isMutation(records[index]) && blocked.has(key) && !restored.has(key)) return false;
    }
    if (usedBytes + incomingBytes > this.maxBytes) return false;
    if (!this.remove(Array.from(victims))) return false;
    this.resyncStreams.clear();
    blocked.forEach((key: string): void => { this.resyncStreams.add(key); });
    return true;
  }

  private atomicWrite(path: string, body: string): void {
    const temp = `${path}.tmp`;
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      // CoreFileKit's string overload is supported on the API levels used by
      // the demo. It avoids depending on an ArrayBuffer view's backing store
      // while preserving exact UTF-8 byte accounting for the durable payload.
      const written = fs.writeSync(file.fd, body);
      if (written !== this.byteLength(body)) {
        throw new Error(`Session Replay storage short write: ${written}/${this.byteLength(body)} bytes`);
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
  }

  private ensureDirectory(path: string): void {
    if (!this.exists(path)) {
      fs.mkdirSync(path);
      if (!this.exists(path)) {
        throw new Error(`Session Replay storage directory was not created: ${path}`);
      }
    }
  }

  private exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private byteLength(value: string): number {
    return util.TextEncoder.create('utf-8').encodeInto(value).byteLength;
  }

  private fileNames(): Array<string> {
    try {
      return fs.listFileSync(this.root);
    } catch (_error) {
      return [];
    }
  }

  private segmentFileNames(): Array<string> {
    return this.fileNames().filter((name: string) => name.endsWith('.json')).sort();
  }

  private isValidSegment(segment: SessionReplayStoredSegment, name: string): boolean {
    return segment.version === SessionReplaySegmentStore.VERSION &&
      typeof segment.id === 'string' && this.isSafeSegmentId(segment.id) &&
      name === `${segment.id}.json` && segment.context !== undefined &&
      typeof segment.context.applicationId === 'string' && segment.context.applicationId.length > 0 &&
      typeof segment.context.sessionId === 'string' && segment.context.sessionId.length > 0 &&
      typeof segment.context.viewId === 'string' && segment.context.viewId.length > 0 &&
      Array.isArray(segment.records) && segment.records.length > 0;
  }

  private isSafeSegmentId(id: string): boolean {
    return /^\d{13}-\d{6}(?:-[0-9a-f]{8})?$/.test(id);
  }

}
