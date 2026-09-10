import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface FTCacheEnvelope {
  version: number;
  checksum: string;
  body: string;
}

export interface FTCacheMutation {
  path: string;
  body: string | null;
}

/** Durability timings returned by one forward journal commit. */
export interface FTCacheCommitTiming {
  journalMs: number;
  fsyncMs: number;
}

interface FTCacheJournal {
  version: number;
  changes: FTCacheMutation[];
}

/** File primitives used only on TaskPool, while the cache directory lock is held. */
export class FTCacheFiles {
  static readonly MAX_RECORD_BYTES: number = 256 * 1024;
  /**
   * Bounds retained corrupt-record evidence only. This is deliberately not a
   * capacity-admission reserve: normal writes may use the configured limit.
   */
  static readonly MAX_QUARANTINE_BYTES: number = FTCacheFiles.MAX_RECORD_BYTES * 2;

  static exists(path: string): boolean {
    try { return fs.accessSync(path); } catch (_) { return false; }
  }

  static mkdir(path: string): void {
    if (!FTCacheFiles.exists(path)) { fs.mkdirSync(path, true); }
  }

  static bytes(text: string): number {
    return util.TextEncoder.create('utf-8').encodeInto(text).byteLength;
  }

  static checksum(text: string): string {
    let hash = 2166136261;
    const bytes = util.TextEncoder.create('utf-8').encodeInto(text);
    for (let i = 0; i < bytes.length; i++) { hash = Math.imul(hash ^ bytes[i], 16777619); }
    return (hash >>> 0).toString(16);
  }

  static encode(body: string): string {
    const envelope: FTCacheEnvelope = { version: 1, checksum: FTCacheFiles.checksum(body), body };
    return JSON.stringify(envelope);
  }

  static read(path: string): string | null {
    if (!FTCacheFiles.exists(path)) { return null; }
    const envelope = JSON.parse(fs.readTextSync(path)) as FTCacheEnvelope;
    if (envelope.version !== 1 || typeof envelope.body !== 'string' ||
      FTCacheFiles.checksum(envelope.body) !== envelope.checksum) {
      throw new Error(`CACHE_CORRUPT:${path}`);
    }
    return envelope.body;
  }

  static size(path: string): number {
    if (!FTCacheFiles.exists(path)) { return 0; }
    const stat = fs.statSync(path);
    if (!stat.isDirectory()) { return stat.size; }
    let size = 0;
    const entries = fs.listFileSync(path);
    for (let i = 0; i < entries.length; i++) { size += FTCacheFiles.size(`${path}/${entries[i]}`); }
    return size;
  }

  static syncDirectory(path: string, timing?: FTCacheCommitTiming): void {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const startedAt = Date.now();
      fs.fsyncSync(file.fd);
      if (timing) { timing.fsyncMs += Math.max(0, Date.now() - startedAt); }
    } finally { fs.closeSync(file); }
  }

  static atomicWrite(path: string, body: string, timing?: FTCacheCommitTiming, syncParent: boolean = true): void {
    const parent = path.substring(0, path.lastIndexOf('/'));
    FTCacheFiles.mkdir(parent);
    const temp = `${path}.tmp`;
    const data = util.TextEncoder.create('utf-8').encodeInto(FTCacheFiles.encode(body));
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < data.length) {
        const remaining = data.slice(written).buffer as ArrayBuffer;
        const count = fs.writeSync(file.fd, remaining);
        if (count <= 0) { throw new Error('CACHE_SHORT_WRITE'); }
        written += count;
      }
      const startedAt = Date.now();
      fs.fsyncSync(file.fd);
      if (timing) { timing.fsyncMs += Math.max(0, Date.now() - startedAt); }
    } finally { fs.closeSync(file); }
    fs.renameSync(temp, path);
    if (syncParent) { FTCacheFiles.syncDirectory(parent, timing); }
  }

  static remove(path: string, timing?: FTCacheCommitTiming, syncParent: boolean = true): void {
    if (!FTCacheFiles.exists(path)) { return; }
    fs.unlinkSync(path);
    if (syncParent) { FTCacheFiles.syncDirectory(path.substring(0, path.lastIndexOf('/')), timing); }
  }

  static fileNames(path: string): string[] {
    if (!FTCacheFiles.exists(path)) { return []; }
    return fs.listFileSync(path).filter((name: string) => name.endsWith('.json'));
  }

  /** A committed journal is replayed forward, including deletion, before serving any reads. */
  static commit(root: string, changes: FTCacheMutation[]): FTCacheCommitTiming {
    const timing: FTCacheCommitTiming = { journalMs: 0, fsyncMs: 0 };
    if (changes.length === 0) { return timing; }
    const startedAt = Date.now();
    const journal: FTCacheJournal = { version: 1, changes };
    FTCacheFiles.atomicWrite(`${root}/transaction.json`, JSON.stringify(journal), timing);
    FTCacheFiles.apply(root, journal, timing);
    timing.journalMs = Math.max(0, Date.now() - startedAt);
    return timing;
  }

  /** O(1): the only durable marker needed to replay a partially applied commit. */
  static hasPendingJournal(root: string): boolean {
    return FTCacheFiles.exists(`${root}/transaction.json`);
  }

  static recover(root: string): void {
    const content = FTCacheFiles.read(`${root}/transaction.json`);
    if (content !== null) {
      const journal = JSON.parse(content) as FTCacheJournal;
      if (journal.version !== 1 || !Array.isArray(journal.changes)) { throw new Error('CACHE_JOURNAL_INVALID'); }
      FTCacheFiles.apply(root, journal);
    }
    FTCacheFiles.removeTemps(root);
  }

  private static apply(root: string, journal: FTCacheJournal, timing?: FTCacheCommitTiming): void {
    const changedParents = new Set<string>();
    for (let i = 0; i < journal.changes.length; i++) {
      const change = journal.changes[i];
      if (!change.path.startsWith(`${root}/`) || change.path.includes('/../') ||
        change.path === `${root}/transaction.json`) { throw new Error('CACHE_JOURNAL_PATH_INVALID'); }
      const parent = change.path.substring(0, change.path.lastIndexOf('/'));
      if (change.body === null) { FTCacheFiles.remove(change.path, timing, false); }
      else { FTCacheFiles.atomicWrite(change.path, change.body, timing, false); }
      changedParents.add(parent);
    }
    // The journal is durable before any mutation. Payload files may therefore
    // share one directory fsync per parent; only after those syncs succeed is
    // the journal removed. A crash before then simply replays the journal.
    for (const parent of changedParents) {
      FTCacheFiles.syncDirectory(parent, timing);
    }
    FTCacheFiles.remove(`${root}/transaction.json`, timing);
  }

  private static removeTemps(path: string): void {
    if (!FTCacheFiles.exists(path)) { return; }
    const names = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      const child = `${path}/${names[i]}`;
      if (fs.statSync(child).isDirectory()) { FTCacheFiles.removeTemps(child); }
      else if (names[i].endsWith('.tmp')) { FTCacheFiles.remove(child); }
    }
  }
}
