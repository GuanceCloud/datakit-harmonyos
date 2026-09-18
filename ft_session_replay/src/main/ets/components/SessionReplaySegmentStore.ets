import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SessionReplayContext, SessionReplayGlobalContext, SessionReplayRecord } from './SessionReplayProtocol';

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

  constructor(
    filesDir: string,
    maxBytes: number,
    maxRecordsPerSegment: number,
    directoryName: string = 'segments'
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
    this.recover();
  }

  public append(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean {
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
        if (!this.reserveBytes(this.byteLength(body))) {
          this.lastWriteError = `Replay segment exceeds the configured ${this.maxBytes}-byte local storage quota.`;
          return false;
        }
        this.atomicWrite(`${this.root}/${segment.id}.json`, body);
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

  /** Removes complete segments whose latest record is outside a rolling window. */
  public pruneBefore(timestamp: number): void {
    const segments = this.list();
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      if (this.latestRecordTimestamp(segment) < timestamp) {
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
    const segments = this.list();
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      if (segment.context.sessionId !== sessionId) {
        continue;
      }
      const records = segment.records.filter((record: SessionReplayRecord): boolean => record.timestamp >= cutoff);
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

  private createSegment(context: SessionReplayContext, records: Array<SessionReplayRecord>): SessionReplayStoredSegment {
    const createdAt = Date.now();
    const id = `${createdAt.toString().padStart(13, '0')}-${(++this.sequence).toString().padStart(6, '0')}`;
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

  private reserveBytes(incomingBytes: number): boolean {
    if (incomingBytes > this.maxBytes) {
      return false;
    }
    const names = this.segmentFileNames();
    let usedBytes = 0;
    for (let index = 0; index < names.length; index++) {
      usedBytes += fs.statSync(`${this.root}/${names[index]}`).size;
    }
    let candidateIndex = 0;
    while (usedBytes + incomingBytes > this.maxBytes && candidateIndex < names.length) {
      const path = `${this.root}/${names[candidateIndex]}`;
      usedBytes -= fs.statSync(path).size;
      fs.unlinkSync(path);
      candidateIndex++;
    }
    return usedBytes + incomingBytes <= this.maxBytes;
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
    return /^\d{13}-\d{6}$/.test(id);
  }

  private latestRecordTimestamp(segment: SessionReplayStoredSegment): number {
    let latest = segment.createdAt;
    for (let index = 0; index < segment.records.length; index++) {
      latest = Math.max(latest, segment.records[index].timestamp);
    }
    return latest;
  }
}
