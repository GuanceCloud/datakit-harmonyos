import { replayValuesEqual } from './ReplayWireframeValues';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  FullSnapshotData, isReplayFullSnapshot, ReplayMutationData, ReplayRecordType, SessionReplayContext, SessionReplayGlobalContext, SessionReplayRecord
} from './SessionReplayProtocol';

/** One durable batch of HarmonyOS-compatible records for a single RUM View. */
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
 * Checkpoints/events use atomic JSON files. The recording Worker optionally
 * appends adjacent native mutations to a checksummed, fsynced journal, then
 * seals it into the same JSON format consumed by existing uploaders.
 */
export class SessionReplaySegmentStore implements SessionReplayRecordStore {
  private static readonly VERSION: number = 1;
  private static readonly READY_SUFFIX: string = '.ready';
  private static readonly LEGACY_SUFFIX: string = '.json';
  private static readonly WRITING_SUFFIX: string = '.writing';

  private readonly replayRoot: string;
  private readonly root: string;
  private readonly maxBytes: number;
  private readonly appendMutations: boolean;
  private readonly maxRecordsPerSegment: number;
  private activeSegment: SessionReplayStoredSegment | null = null;
  private activeBytes: number = 0;
  private journalDamaged: boolean = false;
  private readonly sealedSizes: Map<string, number> = new Map();
  private sequence: number = 0;
  private lastWriteError: string = '';
  private lastAppendedIds: Array<string> = [];
  private readonly resyncStreams: Set<string> = new Set();

  constructor(
    filesDir: string,
    maxBytes: number,
    maxRecordsPerSegment: number,
    directoryName: string = 'segments',
    recoverOnInit: boolean = true,
    appendMutations: boolean = false
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
    this.appendMutations = appendMutations;
    this.maxRecordsPerSegment = Math.max(1, Math.floor(maxRecordsPerSegment));
    // `mkdirSync(path, true)` is only available from newer platform APIs.
    // Create each level explicitly so Replay works on the API 12 devices this
    // SDK supports as well as on newer runtimes.
    this.ensureDirectory(this.replayRoot);
    this.ensureDirectory(this.root);
    if (recoverOnInit) this.recover();
    this.refreshSizes();
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
      if (!this.exists(this.root)) this.sealedSizes.clear();
      this.ensureDirectory(this.replayRoot);
      this.ensureDirectory(this.root);
      for (let start = 0; start < records.length; start += this.maxRecordsPerSegment) {
        const segmentRecords = records.slice(start, start + this.maxRecordsPerSegment);
        if (this.appendMutations && segmentRecords.every((record: SessionReplayRecord): boolean =>
          this.isJournalRecord(record))) {
          if (!this.appendMutationBatch(context, segmentRecords)) return false;
          continue;
        }
        if (!this.flush()) return false;
        const segment = this.createSegment(context, segmentRecords);
        const body = JSON.stringify(segment);
        if (!this.reserveBytes(this.byteLength(body), context, segmentRecords)) {
          this.lastWriteError = `Replay storage needs a Full Snapshot or exceeds the configured ${this.maxBytes}-byte quota.`;
          return false;
        }
        this.atomicWrite(`${this.root}/${segment.id}${SessionReplaySegmentStore.READY_SUFFIX}`, body);
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

  /** Seal before uploads, event boundaries, stop and explicit flush. */
  public flush(): boolean {
    const segment = this.activeSegment;
    if (segment === null) return true;
    try {
      this.ensureDirectory(this.replayRoot);
      this.ensureDirectory(this.root);
      this.atomicWrite(`${this.root}/${segment.id}${SessionReplaySegmentStore.READY_SUFFIX}`, JSON.stringify(segment));
      // If unlink is interrupted, recovery prefers the complete sealed JSON.
      try { fs.unlinkSync(`${this.root}/${segment.id}.journal`); } catch (_) { }
      this.activeSegment = null;
      this.activeBytes = 0;
      this.journalDamaged = false;
      return true;
    } catch (error) {
      this.lastWriteError = `Unable to seal Replay journal: ${String(error)}`;
      return false;
    }
  }

  private appendMutationBatch(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean {
    const payload = JSON.stringify(records);
    const line = `${this.byteLength(payload)}:${this.checksum(payload)}:${payload}\n`;
    const previous = this.activeSegment;
    if (previous !== null && (this.journalDamaged || !this.exists(`${this.root}/${previous.id}.journal`) || !replayValuesEqual(previous.context, context) ||
      previous.records.length + records.length > this.maxRecordsPerSegment ||
      this.activeBytes + this.byteLength(line) > 256 * 1024 || Date.now() - previous.createdAt >= 1000)) {
      if (!this.flush()) return false;
    }
    let segment = this.activeSegment;
    let header = '';
    if (segment === null) {
      segment = this.createSegment(context, []);
      header = JSON.stringify(segment) + '\n';
    }
    const body = header + line;
    if (!this.reserveBytes(this.byteLength(body), context, records)) {
      this.lastWriteError = 'Replay mutation journal needs a Full Snapshot or exceeds its quota.';
      return false;
    }
    // Quota handling may have sealed the old journal. Start a fresh id then.
    if (header.length === 0 && this.activeSegment === null) {
      return this.appendMutationBatch(context, records);
    }
    const file = fs.openSync(`${this.root}/${segment.id}.journal`,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
    try {
      const written = fs.writeSync(file.fd, body);
      if (written !== this.byteLength(body)) throw new Error('Replay journal short write.');
      fs.fsyncSync(file.fd);
    } catch (error) {
      this.journalDamaged = true;
      throw new Error(String(error));
    } finally {
      fs.closeSync(file);
    }
    segment.records.push(...records);
    this.activeSegment = segment;
    this.activeBytes += this.byteLength(body);
    this.lastAppendedIds.push(segment.id);
    if (segment.records.length >= this.maxRecordsPerSegment || this.activeBytes >= 256 * 1024) return this.flush();
    return true;
  }

  private checksum(value: string): number {
    const bytes = util.TextEncoder.create('utf-8').encodeInto(value);
    let hash = 2166136261;
    for (let index = 0; index < bytes.length; index++) {
      hash = Math.imul(hash ^ bytes[index], 16777619) >>> 0;
    }
    return hash;
  }

  private refreshSizes(): void {
    this.sealedSizes.clear();
    for (const name of this.segmentFileNames()) {
      this.sealedSizes.set(this.segmentIdFromName(name), fs.statSync(`${this.root}/${name}`).size);
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
    if (!this.flush()) throw new Error(this.lastWriteError);
    return this.segmentFileNames().map((name: string): string => this.segmentIdFromName(name));
  }

  /** Reopens valid segments after process restart and removes interrupted writes. */
  public list(): Array<SessionReplayStoredSegment> {
    if (!this.flush()) throw new Error(this.lastWriteError);
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
    if (this.activeSegment !== null && ids.includes(this.activeSegment.id) && !this.flush()) return false;
    let completed = true;
    for (let index = 0; index < ids.length; index++) {
      const id = ids[index];
      if (!this.isSafeSegmentId(id)) {
        completed = false;
        continue;
      }
      try {
        const readyPath = `${this.root}/${id}${SessionReplaySegmentStore.READY_SUFFIX}`;
        const legacyPath = `${this.root}/${id}${SessionReplaySegmentStore.LEGACY_SUFFIX}`;
        if (this.exists(readyPath)) fs.unlinkSync(readyPath);
        if (this.exists(legacyPath)) fs.unlinkSync(legacyPath);
        this.sealedSizes.delete(id);
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
      if (!destination.append(segment.context, records) || !destination.flush()) {
        return false;
      }
      if (!this.remove([segment.id])) {
        return false;
      }
    }
    this.pruneBefore(cutoff);
    return true;
  }

  /** Resource dependencies include the checkpoint/prefix retained before cutoff. */
  public getReferencedResourceNames(timestamp: number, sessionId?: string): Set<string> {
    const segments = this.list().filter((segment: SessionReplayStoredSegment): boolean =>
      sessionId === undefined || segment.context.sessionId === sessionId);
    const selected = this.selectWindowRecords(segments, timestamp);
    const names = new Set<string>();
    let ordinal = 0;
    for (const segment of segments) {
      for (const record of segment.records) {
        if (!selected.has(ordinal++) || record.slotId !== undefined) continue;
        if (record.type === ReplayRecordType.FULL_SNAPSHOT) {
          for (const frame of (record.data as FullSnapshotData).wireframes) {
            if (frame.type === 'image' && frame.resourceId !== undefined) names.add(frame.resourceId);
          }
        } else if (this.isMutation(record)) {
          const mutation = record.data as ReplayMutationData;
          for (const add of mutation.adds) {
            if (add.wireframe.type === 'image' && add.wireframe.resourceId !== undefined) names.add(add.wireframe.resourceId);
          }
          for (const update of mutation.updates) {
            if (update.resourceId !== undefined) names.add(update.resourceId);
          }
        }
      }
    }
    return names;
  }

  public getRoot(): string {
    return this.root;
  }

  public getFilesDir(): string {
    return this.replayRoot.substring(0, this.replayRoot.length - '/ft_session_replay'.length);
  }

  public requiresFullSnapshot(context: SessionReplayContext): boolean {
    const key = `${context.applicationId}|${context.sessionId}|${context.viewId}|native`;
    if (!this.exists(this.root)) this.resyncStreams.add(key);
    return this.resyncStreams.has(key);
  }

  private streamKey(context: SessionReplayContext, record: SessionReplayRecord): string {
    return `${context.applicationId}|${context.sessionId}|${context.viewId}|${record.slotId ?? 'native'}`;
  }

  private isCheckpoint(record: SessionReplayRecord): boolean {
    return isReplayFullSnapshot(record);
  }

  private isJournalRecord(record: SessionReplayRecord): boolean {
    if (record.slotId !== undefined || record.type !== ReplayRecordType.INCREMENTAL_SNAPSHOT) return false;
    const source: number = (record.data as ReplayMutationData).source;
    return source === 0 || source === 9;
  }

  private isMutation(record: SessionReplayRecord): boolean {
    return (record.slotId === undefined ? record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT : (record.type as number) === 3) &&
      (record.data as ReplayMutationData).source === 0;
  }

  private selectWindowRecords(segments: Array<SessionReplayStoredSegment>, timestamp: number): Set<number> {
    const checkpoints = new Map<string, number>();
    const starts = new Map<string, number>();
    const initialization = new Map<string, Map<number, number>>();
    const streamViews = new Map<string, string>();
    const closedViews = new Set<string>();
    const selected = new Set<number>();
    let ordinal = 0;
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      for (let recordIndex = 0; recordIndex < segment.records.length; recordIndex++, ordinal++) {
        const record = segment.records[recordIndex];
        const key = this.streamKey(segment.context, record);
        const viewKey = `${segment.context.applicationId}|${segment.context.sessionId}|${segment.context.viewId}`;
        streamViews.set(key, viewKey);
        if (record.type === ReplayRecordType.VIEW_END && record.slotId === undefined) closedViews.add(viewKey);
        else if (record.type === ReplayRecordType.FULL_SNAPSHOT && record.slotId === undefined) closedViews.delete(viewKey);
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
    // An active static page has no heartbeat records inside the window. Keep
    // its latest checkpoint and dependent mutations so an Error still has a scene.
    checkpoints.forEach((checkpoint: number, key: string): void => {
      if (!starts.has(key) && !closedViews.has(streamViews.get(key) ?? '')) {
        starts.set(key, checkpoint);
        initialization.get(key)?.forEach((value: number): void => { selected.add(value); });
      }
    });
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
      if (names[index].endsWith('.tmp') || names[index].endsWith(SessionReplaySegmentStore.WRITING_SUFFIX)) {
        try { fs.unlinkSync(`${this.root}/${names[index]}`); } catch (_) { }
      }
    }
    for (const name of this.fileNames().filter((entry: string): boolean =>
      entry.endsWith(SessionReplaySegmentStore.LEGACY_SUFFIX)).sort()) {
      const id = this.segmentIdFromName(name);
      const legacyPath = `${this.root}/${name}`;
      const readyPath = `${this.root}/${id}${SessionReplaySegmentStore.READY_SUFFIX}`;
      try {
        const segment = JSON.parse(fs.readTextSync(legacyPath)) as SessionReplayStoredSegment;
        if (!this.isValidSegment(segment, name)) {
          fs.unlinkSync(legacyPath);
        } else if (this.exists(readyPath)) {
          fs.unlinkSync(legacyPath);
        } else {
          fs.renameSync(legacyPath, readyPath);
        }
      } catch (_) {
        try { fs.unlinkSync(legacyPath); } catch (_) { }
      }
    }
    for (const name of this.fileNames().filter((entry: string): boolean => entry.endsWith('.journal')).sort()) {
      const path = `${this.root}/${name}`;
      let body: string;
      try { body = fs.readTextSync(path); } catch (_) { continue; }
      const segment = this.readJournal(body, name);
      try {
        if (segment !== null) {
          const readyName = `${segment.id}${SessionReplaySegmentStore.READY_SUFFIX}`;
          const sealedPath = `${this.root}/${readyName}`;
          let sealed = false;
          try { sealed = this.isValidSegment(JSON.parse(fs.readTextSync(sealedPath)) as SessionReplayStoredSegment, readyName); }
          catch (_) { }
          if (!sealed) this.atomicWrite(sealedPath, JSON.stringify(segment));
        }
        fs.unlinkSync(path);
      } catch (_) {
        // Keep a journal on an I/O failure; retry recovery at the next startup.
      }
    }
    this.list();
  }

  private readJournal(body: string, name: string): SessionReplayStoredSegment | null {
    try {
      const lines = body.split('\n');
      const segment = JSON.parse(lines[0]) as SessionReplayStoredSegment;
      segment.records = [];
      for (let index = 1; index < lines.length - 1; index++) {
        const first = lines[index].indexOf(':');
        const second = lines[index].indexOf(':', first + 1);
        if (first < 1 || second < 0) break;
        const payload = lines[index].substring(second + 1);
        if (Number(lines[index].substring(0, first)) !== this.byteLength(payload) ||
          Number(lines[index].substring(first + 1, second)) !== this.checksum(payload)) break;
        try {
          const records = JSON.parse(payload) as Array<SessionReplayRecord>;
          if (!Array.isArray(records) || !records.every((record: SessionReplayRecord): boolean =>
            this.isJournalRecord(record))) break;
          segment.records.push(...records);
        } catch (_) { break; }
      }
      const jsonName = name.substring(0, name.length - '.journal'.length) + '.json';
      return this.isValidSegment(segment, jsonName) ? segment : null;
    } catch (_) { return null; }
  }

  private reserveBytes(
    incomingBytes: number, context: SessionReplayContext, records: Array<SessionReplayRecord>
  ): boolean {
    if (incomingBytes > this.maxBytes) {
      return false;
    }
    if (!this.appendMutations) this.refreshSizes();
    let usedBytes = this.activeBytes;
    this.sealedSizes.forEach((size: number): void => { usedBytes += size; });
    if (usedBytes + incomingBytes <= this.maxBytes && this.resyncStreams.size === 0) return true;
    if (!this.flush()) return false;
    usedBytes = 0;
    this.sealedSizes.forEach((size: number): void => { usedBytes += size; });
    const sizes = this.sealedSizes;
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
    const temp = `${path}${SessionReplaySegmentStore.WRITING_SUFFIX}`;
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
    const name = path.substring(path.lastIndexOf('/') + 1);
    this.sealedSizes.set(this.segmentIdFromName(name), this.byteLength(body));
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
    return this.fileNames().filter((name: string): boolean =>
      name.endsWith(SessionReplaySegmentStore.READY_SUFFIX) ||
      name.endsWith(SessionReplaySegmentStore.LEGACY_SUFFIX)).sort();
  }

  private isValidSegment(segment: SessionReplayStoredSegment, name: string): boolean {
    return segment.version === SessionReplaySegmentStore.VERSION &&
      typeof segment.id === 'string' && this.isSafeSegmentId(segment.id) &&
      (name === `${segment.id}${SessionReplaySegmentStore.READY_SUFFIX}` ||
        name === `${segment.id}${SessionReplaySegmentStore.LEGACY_SUFFIX}`) && segment.context !== undefined &&
      typeof segment.context.applicationId === 'string' && segment.context.applicationId.length > 0 &&
      typeof segment.context.sessionId === 'string' && segment.context.sessionId.length > 0 &&
      typeof segment.context.viewId === 'string' && segment.context.viewId.length > 0 &&
      Array.isArray(segment.records) && segment.records.length > 0;
  }

  private isSafeSegmentId(id: string): boolean {
    return /^\d{13}-\d{6}(?:-[0-9a-f]{8})?$/.test(id);
  }

  private segmentIdFromName(name: string): string {
    if (name.endsWith(SessionReplaySegmentStore.READY_SUFFIX)) {
      return name.substring(0, name.length - SessionReplaySegmentStore.READY_SUFFIX.length);
    }
    return name.substring(0, name.length - SessionReplaySegmentStore.LEGACY_SUFFIX.length);
  }

}
