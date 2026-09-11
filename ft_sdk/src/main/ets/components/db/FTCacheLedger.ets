import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTCacheSettings } from './FTCacheContext';
import { FTDBConfig } from './FTDBConfig';
import { SyncDataJSON } from './bean/SyncData';
import { FTInnerLogger } from '../log/FTLogger';

export interface FTCacheUsage {
  /** All physical files in the v2 FileStore root, including metadata and leases. */
  fileBytes: number;
  /** Sync payloads plus View/Action RUM aggregate files. This is the FileStore capacity meter. */
  payloadBytes: number;
  sqliteBytes: number;
  legacyFileBytes: number;
  spoolBytes: number;
  /** Physical on-disk total. It can include both primary and shadow copies. */
  totalBytes: number;
  /** Bytes compared with `capacityBytes` by the active primary-store policy. */
  governedBytes: number;
  /** Human-readable scope for `governedBytes`, intended for diagnostics UI. */
  governedScope: string;
  capacityBytes: number;
  overLimit: boolean;
}

export interface FTCacheStatus {
  mode: string;
  directUpload: boolean;
  sqliteReleased: boolean;
  usage: FTCacheUsage;
  migration: string;
  syncCount: number;
  viewCount: number;
  actionCount: number;
  oldestUuids: string[];
  evicted: number;
  rejected: number;
  corrupt: number;
  projectionPending: boolean;
  shadowHealthy: boolean;
}

interface FTCacheLedgerState {
  version: number;
  /** All cache-root bytes except this small ledger file. */
  cacheBytes: number;
  /** Bytes in sync payloads and View/Action RUM aggregate files only. */
  payloadBytes: number;
  logCount: number;
  rumCount: number;
  oldestUuid: string;
  oldestTime: number;
  oldestId: number;
  oldestDirty: boolean;
}

export interface FTCacheLedgerCommit {
  changes: FTCacheMutation[];
  state: FTCacheLedgerState;
}

export interface FTCacheLedgerCounts {
  log: number;
  rum: number;
}
const TAG = 'FTCacheLedger';

/**
 * Persistent incremental cache accounting.
 *
 * The ledger is part of the same journal transaction as the payload changes.
 * Therefore normal writes only stat the files being replaced; a full directory
 * walk is reserved for first use, recovery after a direct filesystem repair and
 * explicit diagnostics (`usage(true)`).
 */
export class FTCacheLedger {
  private context: Context;
  private settings: FTCacheSettings;
  private root: string;
  private state: FTCacheLedgerState | null = null;
  private readonly ledgerPath: string;

  constructor(context: Context, settings: FTCacheSettings, root: string) {
    this.context = context; this.settings = settings; this.root = root;
    this.ledgerPath = `${root}/meta/ledger`;
  }

  usage(exact: boolean = false): FTCacheUsage {
    const state = this.load();
    // The persisted ledger is intentionally excluded from cacheBytes so its
    // changing JSON length never feeds back into the value it stores.
    const fileBytes = exact ? FTCacheFiles.size(this.root) :
      state.cacheBytes + FTCacheFiles.size(this.ledgerPath);
    const payloadBytes = exact ? this.payloadBytesOnDisk() : state.payloadBytes;
    const sqliteBytes = this.databaseBytes(this.context.databaseDir);
    const legacyFileBytes = FTCacheFiles.size(`${this.context.filesDir}/ft_sdk_file_store`);
    const spoolBytes = FTCacheFiles.size(`${this.context.filesDir}/ft_sdk_spool`);
    const totalBytes = fileBytes + sqliteBytes + legacyFileBytes + spoolBytes;
    // Cache-size governance follows the active store's logical footprint.
    // SQLite pages, migration remnants and the upload spool remain diagnostic
    // physical usage; they do not consume FileStore's configured cache budget.
    const fileStoreMeter = this.settings.mode === 'file' || this.settings.mode === 'shadow';
    const governedBytes = fileStoreMeter ? payloadBytes : sqliteBytes;
    const governedScope = fileStoreMeter ? 'FileStore 同步数据与 RUM 聚合' : 'SQLite 数据库物理文件';
    return {
      fileBytes, payloadBytes, sqliteBytes, legacyFileBytes, spoolBytes, totalBytes, governedBytes, governedScope,
      capacityBytes: this.settings.capacity,
      overLimit: this.settings.limitEnabled && governedBytes >= this.settings.capacity
    };
  }

  counts(): FTCacheLedgerCounts {
    const state = this.load();
    return { log: state.logCount, rum: state.rumCount };
  }

  /**
   * Adds the ledger mutation to an already assembled journal. The returned
   * snapshot is published only after the journal has been applied.
   */
  prepareCommit(changes: FTCacheMutation[]): FTCacheLedgerCommit {
    const next = this.copy(this.load());
    const prepared: FTCacheMutation[] = [];
    const currentBodies = new Map<string, string | null>();
    const currentBytes = new Map<string, number>();
    for (const change of changes) {
      if (change.path === this.ledgerPath) { continue; }
      const oldBody = currentBodies.has(change.path) ? currentBodies.get(change.path)! : this.readBody(change.path);
      const oldBytes = currentBytes.has(change.path) ? currentBytes.get(change.path)! : FTCacheFiles.size(change.path);
      const nextBytes = change.body === null ? 0 : FTCacheFiles.bytes(FTCacheFiles.encode(change.body));
      next.cacheBytes = Math.max(0, next.cacheBytes + nextBytes - oldBytes);
      if (this.isPayloadPath(change.path)) {
        next.payloadBytes = Math.max(0, next.payloadBytes + nextBytes - oldBytes);
      }
      if (this.isSyncPath(change.path)) {
        this.applyRow(next, this.parseRow(oldBody), -1);
        this.applyRow(next, this.parseRow(change.body), 1);
      }
      currentBodies.set(change.path, change.body);
      currentBytes.set(change.path, nextBytes);
      prepared.push(change);
    }
    prepared.push({ path: this.ledgerPath, body: JSON.stringify(next) });
    return { changes: prepared, state: next };
  }

  markCommitted(commit: FTCacheLedgerCommit): void {
    this.state = commit.state;
  }

  /** Forget a ledger after a direct move/remove; next access safely scans once. */
  invalidate(): void {
    this.state = null;
    FTCacheFiles.remove(this.ledgerPath);
    FTInnerLogger.d(TAG, `Invalidated FileStore ledger: path=${this.ledgerPath}`);
  }

  canCommit(commit: FTCacheLedgerCommit): boolean {
    return !this.settings.limitEnabled || commit.state.payloadBytes <= this.settings.capacity;
  }

  isOverLimit(): boolean {
    return this.settings.limitEnabled && this.load().payloadBytes >= this.settings.capacity;
  }

  private load(): FTCacheLedgerState {
    if (this.state !== null) { return this.state; }
    let invalidLedger = false;
    try {
      const body = FTCacheFiles.read(this.ledgerPath);
      if (body !== null) {
        const parsed = JSON.parse(body) as FTCacheLedgerState;
        if (parsed.version === 2 && parsed.cacheBytes >= 0 && parsed.payloadBytes >= 0 &&
          parsed.logCount >= 0 && parsed.rumCount >= 0) {
          this.state = parsed;
          return parsed;
        }
        invalidLedger = true;
      }
    } catch (_) {
      // A damaged optimization index must never prevent a safe full rebuild.
      invalidLedger = true;
    }
    this.state = this.rebuild();
    if (invalidLedger) {
      FTInnerLogger.w(TAG, `Rebuilt invalid FileStore ledger: path=${this.ledgerPath}`);
    } else {
      FTInnerLogger.i(TAG, `Created FileStore ledger: path=${this.ledgerPath}`);
    }
    return this.state;
  }

  private rebuild(): FTCacheLedgerState {
    const state: FTCacheLedgerState = {
      version: 2,
      cacheBytes: Math.max(0, FTCacheFiles.size(this.root) - FTCacheFiles.size(this.ledgerPath)),
      payloadBytes: this.payloadBytesOnDisk(),
      logCount: 0,
      rumCount: 0,
      oldestUuid: '',
      oldestTime: 0,
      oldestId: 0,
      oldestDirty: false
    };
    const syncDir = `${this.root}/sync`;
    for (const name of FTCacheFiles.fileNames(syncDir)) {
      const path = `${syncDir}/${name}`;
      this.applyRow(state, this.parseRow(this.readBody(path)), 1);
    }
    return state;
  }

  private copy(value: FTCacheLedgerState): FTCacheLedgerState {
    return {
      version: 2,
      cacheBytes: value.cacheBytes,
      payloadBytes: value.payloadBytes,
      logCount: value.logCount,
      rumCount: value.rumCount,
      oldestUuid: value.oldestUuid,
      oldestTime: value.oldestTime,
      oldestId: value.oldestId,
      oldestDirty: value.oldestDirty
    };
  }

  private readBody(path: string): string | null {
    try { return FTCacheFiles.read(path); } catch (_) { return null; }
  }

  private parseRow(body: string | null): SyncDataJSON | null {
    if (!body) { return null; }
    try {
      const row = JSON.parse(body) as SyncDataJSON;
      return row && typeof row.uuid === 'string' && typeof row.time === 'number' ? row : null;
    } catch (_) { return null; }
  }

  private isSyncPath(path: string): boolean {
    return path.startsWith(`${this.root}/sync/`) && path.endsWith('.json');
  }

  private isPayloadPath(path: string): boolean {
    return (path.startsWith(`${this.root}/sync/`) || path.startsWith(`${this.root}/view/`) ||
      path.startsWith(`${this.root}/action/`)) && path.endsWith('.json');
  }

  private payloadBytesOnDisk(): number {
    return FTCacheFiles.size(`${this.root}/sync`) + FTCacheFiles.size(`${this.root}/view`) +
      FTCacheFiles.size(`${this.root}/action`);
  }

  private applyRow(state: FTCacheLedgerState, row: SyncDataJSON | null, delta: number): void {
    if (!row) { return; }
    const type = row.customDataTypeString || String(row.dataType);
    if (type === 'log') { state.logCount = Math.max(0, state.logCount + delta); }
    else if (type === 'rum_app' || type === 'rum_webview') { state.rumCount = Math.max(0, state.rumCount + delta); }
    if (delta < 0 && state.oldestUuid === row.uuid) { state.oldestDirty = true; }
    if (delta > 0 && (state.oldestUuid.length === 0 || row.time < state.oldestTime ||
      (row.time === state.oldestTime && row.id < state.oldestId))) {
      state.oldestUuid = row.uuid;
      state.oldestTime = row.time;
      state.oldestId = row.id;
      state.oldestDirty = false;
    }
  }

  private databaseBytes(path: string): number {
    if (!path || !FTCacheFiles.exists(path)) { return 0; }
    let total = 0;
    const names = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      const child = `${path}/${names[i]}`;
      if (fs.statSync(child).isDirectory()) { total += this.databaseBytes(child); }
      else if (names[i].startsWith(FTDBConfig.DATABASE_NAME)) { total += fs.statSync(child).size; }
    }
    return total;
  }
}
