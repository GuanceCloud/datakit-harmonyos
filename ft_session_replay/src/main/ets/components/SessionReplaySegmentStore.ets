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

  private readonly root: string;
  private readonly maxBytes: number;
  private readonly maxRecordsPerSegment: number;
  private sequence: number = 0;

  constructor(filesDir: string, maxBytes: number, maxRecordsPerSegment: number) {
    if (filesDir.trim().length === 0) {
      throw new Error('Session Replay storage requires a non-empty filesDir');
    }
    this.root = `${filesDir}/ft_session_replay/segments`;
    this.maxBytes = Math.max(1024 * 1024, Math.floor(maxBytes));
    this.maxRecordsPerSegment = Math.max(1, Math.floor(maxRecordsPerSegment));
    this.ensureDirectory(this.root);
    this.recover();
  }

  public append(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean {
    if (records.length === 0) {
      return true;
    }
    try {
      for (let start = 0; start < records.length; start += this.maxRecordsPerSegment) {
        const segmentRecords = records.slice(start, start + this.maxRecordsPerSegment);
        const segment = this.createSegment(context, segmentRecords);
        const body = JSON.stringify(segment);
        if (!this.reserveBytes(this.byteLength(body))) {
          return false;
        }
        this.atomicWrite(`${this.root}/${segment.id}.json`, body);
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  /** Reopens valid segments after process restart and removes interrupted writes. */
  public list(): Array<SessionReplayStoredSegment> {
    const segments: Array<SessionReplayStoredSegment> = [];
    const names = this.segmentFileNames();
    for (let index = 0; index < names.length; index++) {
      const path = `${this.root}/${names[index]}`;
      try {
        const segment = JSON.parse(fs.readTextSync(path)) as SessionReplayStoredSegment;
        if (segment.version === SessionReplaySegmentStore.VERSION &&
          typeof segment.id === 'string' && Array.isArray(segment.records)) {
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
    const bytes = util.TextEncoder.create('utf-8').encodeInto(body);
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < bytes.length) {
        const remaining = bytes.slice(written).buffer as ArrayBuffer;
        const count = fs.writeSync(file.fd, remaining);
        if (count <= 0) {
          throw new Error('Session Replay storage short write');
        }
        written += count;
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
  }

  private ensureDirectory(path: string): void {
    try {
      fs.accessSync(path);
    } catch (_) {
      fs.mkdirSync(path, true);
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
}
