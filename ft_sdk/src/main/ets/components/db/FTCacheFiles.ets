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

interface FTCacheJournal {
  version: number;
  changes: FTCacheMutation[];
}

/** File primitives used only on TaskPool, while the cache directory lock is held. */
export class FTCacheFiles {
  static readonly MAX_RECORD_BYTES: number = 256 * 1024;
  static readonly CONTROL_RESERVE: number = 1024 * 1024;

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

  static syncDirectory(path: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  }

  static atomicWrite(path: string, body: string): void {
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
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(temp, path);
    FTCacheFiles.syncDirectory(parent);
  }

  static remove(path: string): void {
    if (!FTCacheFiles.exists(path)) { return; }
    fs.unlinkSync(path);
    FTCacheFiles.syncDirectory(path.substring(0, path.lastIndexOf('/')));
  }

  static fileNames(path: string): string[] {
    if (!FTCacheFiles.exists(path)) { return []; }
    return fs.listFileSync(path).filter((name: string) => name.endsWith('.json'));
  }

  /** A committed journal is replayed forward, including deletion, before serving any reads. */
  static commit(root: string, changes: FTCacheMutation[]): void {
    if (changes.length === 0) { return; }
    const journal: FTCacheJournal = { version: 1, changes };
    FTCacheFiles.atomicWrite(`${root}/transaction.json`, JSON.stringify(journal));
    FTCacheFiles.apply(root, journal);
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

  private static apply(root: string, journal: FTCacheJournal): void {
    for (let i = 0; i < journal.changes.length; i++) {
      const change = journal.changes[i];
      if (!change.path.startsWith(`${root}/`) || change.path.includes('/../') ||
        change.path === `${root}/transaction.json`) { throw new Error('CACHE_JOURNAL_PATH_INVALID'); }
      if (change.body === null) { FTCacheFiles.remove(change.path); }
      else { FTCacheFiles.atomicWrite(change.path, change.body); }
    }
    FTCacheFiles.remove(`${root}/transaction.json`);
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
