import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTCacheSettings } from './FTCacheContext';
import { FTCacheLedger, FTCacheLedgerCommit, FTCacheStatus } from './FTCacheLedger';
import { FTRumFileStore, FTRumStoreAccess } from './FTRumFileStore';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse, FTDBTaskPoolWriteResponse, FTDBTaskPoolDeleteAllResult } from './FTDBTaskPoolExecutor';
import { SyncDataJSON } from './bean/SyncData';
import { SDKUploadRowDTO } from '../thread/SDKWorkerProtocol';
import { DataType } from '../enum/Enums';
import { FTInnerLogger } from '../log/FTLogger';

export type FTSqliteRunner = (request: FTDBTaskPoolRequest) => Promise<FTDBTaskPoolResponse>;

interface FTCacheLease { digest: string; expires: number; }
interface FTCacheProjection { requests: FTDBTaskPoolRequest[]; }
interface FTCacheCounters { evicted: number; rejected: number; corrupt: number; }
interface FTUploadCandidate { uuid: string; id: number; time: number; bytes: number; }
interface FTCacheWriteTiming {
  recoverMs: number;
  reserveMs: number;
  journalMs: number;
  fsyncMs: number;
  evictionMs: number;
}
const TAG = 'FTCacheFileStore';

/** Authoritative file payloads and aggregates. Caller owns the directory lock. */
export class FTCacheFileStore implements FTRumStoreAccess {
  private static recoveredRoots: Set<string> = new Set<string>();
  readonly root: string;
  readonly ledger: FTCacheLedger;
  private evicted: number = 0;
  private protectedUuids: Set<string> = new Set<string>();
  private lastRecoveryMs: number = 0;

  readonly settings: FTCacheSettings;
  private sqlite: FTSqliteRunner;
  /**
   * A shadow is populated only from an already-committed SQLite result.  It
   * must not reject that result just because the two physical stores coexist
   * and temporarily consume more than one logical cache budget.
   */
  private readonly shadowMirror: boolean;
  constructor(context: Context, settings: FTCacheSettings, sqlite: FTSqliteRunner, shadowMirror: boolean = false) {
    this.settings = settings; this.sqlite = sqlite;
    this.shadowMirror = shadowMirror;
    this.root = `${context.filesDir}/ft_sdk_cache_v2`;
    this.ledger = new FTCacheLedger(context, settings, this.root);
    FTCacheFiles.mkdir(this.root);
    for (const kind of ['sync', 'view', 'action', 'lease', 'meta', 'quarantine']) {
      FTCacheFiles.mkdir(`${this.root}/${kind}`);
    }
  }

  path(kind: string, id: string): string {
    if (!id || FTCacheFiles.bytes(encodeURIComponent(id)) > 180) { throw new Error('CACHE_INVALID_ID'); }
    return `${this.root}/${kind}/${encodeURIComponent(id)}.json`;
  }

  list(kind: string): string[] {
    return FTCacheFiles.fileNames(`${this.root}/${kind}`).map((name: string) => decodeURIComponent(name.slice(0, -5)));
  }

  read(kind: string, id: string): string | null {
    const path = this.path(kind, id);
    try { return FTCacheFiles.read(path); }
    catch (error) {
      if (kind === 'meta') { throw new Error(String(error)); }
      // A bounded quarantine keeps evidence without making a bad record block later data.
      const quarantine = `${this.root}/quarantine`;
      while (FTCacheFiles.size(quarantine) > FTCacheFiles.MAX_QUARANTINE_BYTES) {
        const names = FTCacheFiles.fileNames(quarantine).sort();
        if (names.length === 0) { break; }
        FTCacheFiles.remove(`${quarantine}/${names[0]}`);
      }
      fs.renameSync(path, `${quarantine}/${Date.now()}-${kind}-${encodeURIComponent(id)}.json`);
      FTCacheFiles.syncDirectory(quarantine);
      FTCacheFiles.syncDirectory(`${this.root}/${kind}`);
      this.ledger.invalidate();
      this.increment('corrupt', 1);
      return null;
    }
  }

  async recover(): Promise<void> {
    // A journal is an O(1) durable dirty marker. Normal commands no longer
    // recursively walk every cache directory merely to prove that it is clean.
    if (FTCacheFileStore.recoveredRoots.has(this.root) && !FTCacheFiles.hasPendingJournal(this.root)) { return; }
    const startedAt = Date.now();
    FTCacheFiles.recover(this.root);
    await this.repairProjection();
    const expiredLeases: FTCacheMutation[] = [];
    for (const id of this.list('lease')) {
      const body = this.read('lease', id);
      const lease = body ? JSON.parse(body) as FTCacheLease : null;
      if (!lease || lease.expires <= Date.now() || !FTCacheFiles.exists(this.path('sync', id))) {
        expiredLeases.push({ path: this.path('lease', id), body: null });
      }
    }
    if (expiredLeases.length > 0) { this.commitDirect(expiredLeases); }
    FTCacheFileStore.recoveredRoots.add(this.root);
    this.lastRecoveryMs = Math.max(0, Date.now() - startedAt);
    FTInnerLogger.i(TAG, `Recovered FileStore cache: root=${this.root}, expiredLeases=${expiredLeases.length}, cost=${this.lastRecoveryMs}ms`);
  }

  status(): FTCacheStatus {
    const oldestUuids = this.query({ command: 'querySyncData', limit: 5 }).map((r: SyncDataJSON) => r.uuid);
    const counters = JSON.parse(this.read('meta', 'counters') || '{"evicted":0,"rejected":0,"corrupt":0}') as FTCacheCounters;
    return { mode: this.settings.mode, directUpload: this.settings.mode === 'file' && this.settings.directUpload,
      sqliteReleased: this.read('meta', 'sqliteReleased') === 'true',
      usage: this.ledger.usage(true), migration: this.read('meta', 'migration') || 'not-started',
      syncCount: this.list('sync').length, viewCount: this.list('view').length, actionCount: this.list('action').length,
      oldestUuids,
      evicted: counters.evicted, rejected: counters.rejected, corrupt: counters.corrupt,
      projectionPending: this.read('meta', 'projection') !== null,
      shadowHealthy: this.read('meta', 'shadowDirty') === null };
  }

  async repairProjection(): Promise<void> {
    const pending = this.read('meta', 'projection');
    if (pending === null) { return; }
    const projection = JSON.parse(pending) as FTCacheProjection;
    for (const request of projection.requests) {
      const response = await this.sqlite(request);
      if (!response.ok || (response.write && !response.write.result.success)) {
        throw new Error(response.errorMessage || response.write?.result.errorMessage || 'CACHE_INDEX_REPAIR_FAILED');
      }
    }
    // Projection completion changes accounted bytes too. Keep this removal in
    // the ledger protocol (direct FileStore writes never create this marker).
    this.commitDirect([{ path: this.path('meta', 'projection'), body: null }]);
  }

  async commit(changes: FTCacheMutation[], timing?: FTCacheWriteTiming): Promise<boolean> {
    if (this.shadowMirror) {
      this.commitDirect(changes, timing);
      return true;
    }
    if (changes.every((c: FTCacheMutation) => c.body === null)) {
      this.commitDirect(changes, timing); return true;
    }
    let prepared = this.ledger.prepareCommit(changes);
    const reserveStartedAt = Date.now();
    while (!this.ledger.canCommit(prepared)) {
      if (this.settings.mode === 'shadow' || this.settings.discard !== 'discard_oldest') {
        if (timing) { timing.reserveMs += Math.max(0, Date.now() - reserveStartedAt); }
        FTInnerLogger.w(TAG, `FileStore capacity rejected write: payload=${prepared.state.payloadBytes}, capacity=${this.settings.capacity}, ` +
          `mode=${this.settings.mode}, discard=${this.settings.discard}`);
        this.increment('rejected', 1); return false;
      }
      const evictionStartedAt = Date.now();
      // One capacity breach may need many old rows. Select and remove them in
      // one forward journal instead of doing a full oldest-record scan and an
      // fsync for every candidate.
      const evicted = await this.evictForReserve(prepared.state.payloadBytes);
      if (timing) { timing.evictionMs += Math.max(0, Date.now() - evictionStartedAt); }
      if (!evicted) {
        if (timing) { timing.reserveMs += Math.max(0, Date.now() - reserveStartedAt); }
        FTInnerLogger.w(TAG, `FileStore capacity rejected write: payload=${prepared.state.payloadBytes}, capacity=${this.settings.capacity}, no evictable records`);
        this.increment('rejected', 1); return false;
      }
      prepared = this.ledger.prepareCommit(changes);
    }
    if (timing) { timing.reserveMs += Math.max(0, Date.now() - reserveStartedAt); }
    this.commitPrepared(prepared.changes, prepared, timing);
    return true;
  }

  private commitDirect(changes: FTCacheMutation[], timing?: FTCacheWriteTiming): void {
    const prepared = this.ledger.prepareCommit(changes);
    this.commitPrepared(prepared.changes, prepared, timing);
  }

  private commitPrepared(changes: FTCacheMutation[], prepared: FTCacheLedgerCommit,
    timing?: FTCacheWriteTiming): void {
    const result = FTCacheFiles.commit(this.root, changes);
    this.ledger.markCommitted(prepared);
    if (timing) {
      timing.journalMs += result.journalMs;
      timing.fsyncMs += result.fsyncMs;
    }
  }

  private async evictOne(types: string[] = []): Promise<boolean> {
    let oldest: SyncDataJSON | null = null;
    for (const id of this.list('sync')) {
      const row = this.sync(id);
      if (!row || !this.matches(row, types) || this.protectedUuids.has(row.uuid) || this.leased(row)) { continue; }
      if (oldest === null || (this.type(row) === 'log' && this.type(oldest) !== 'log') ||
        ((this.type(row) === 'log') === (this.type(oldest) === 'log') && this.compare(row, oldest) < 0)) { oldest = row; }
    }
    if (oldest === null) { return false; }
    const changes: FTCacheMutation[] = [{ path: this.path('sync', oldest.uuid), body: null },
      { path: this.path('lease', oldest.uuid), body: null }];
    if (!this.settings.directUpload && this.settings.mode === 'file') {
      this.projection(changes, [{ command: 'deleteSyncUuids', ids: [oldest.uuid] }]);
    }
    // Deletion does not require a payload-sized temporary replacement.
    this.commitDirect(changes);
    await this.repairProjection();
    if (!this.settings.directUpload && this.settings.mode === 'file') {
      const compact = await this.sqlite({ command: 'compactCacheIndex' });
      if (!compact.ok) { throw new Error(compact.errorMessage || 'CACHE_INDEX_COMPACT'); }
    }
    this.evicted++; this.increment('evicted', 1);
    return true;
  }

  private async evictForReserve(targetPayloadBytes: number): Promise<boolean> {
    if (!this.settings.limitEnabled) { return true; }
    let bytesToFree = targetPayloadBytes - this.settings.capacity;
    if (bytesToFree <= 0) { return true; }
    const candidates: SyncDataJSON[] = [];
    for (const id of this.list('sync')) {
      const row = this.sync(id);
      if (row && !this.protectedUuids.has(row.uuid) && !this.leased(row)) { candidates.push(row); }
    }
    candidates.sort((a: SyncDataJSON, b: SyncDataJSON) => {
      const aLog = this.type(a) === 'log'; const bLog = this.type(b) === 'log';
      if (aLog !== bLog) { return aLog ? -1 : 1; }
      return this.compare(a, b);
    });
    const changes: FTCacheMutation[] = [];
    const ids: string[] = [];
    for (const row of candidates) {
      changes.push({ path: this.path('sync', row.uuid), body: null });
      changes.push({ path: this.path('lease', row.uuid), body: null });
      ids.push(row.uuid);
      bytesToFree -= FTCacheFiles.size(this.path('sync', row.uuid));
      if (bytesToFree <= 0) { break; }
    }
    if (bytesToFree > 0 || ids.length === 0) { return false; }
    if (!this.settings.directUpload && this.settings.mode === 'file') {
      this.projection(changes, [{ command: 'deleteSyncUuids', ids }]);
    }
    this.commitDirect(changes);
    await this.repairProjection();
    if (!this.settings.directUpload && this.settings.mode === 'file') {
      const compact = await this.sqlite({ command: 'compactCacheIndex' });
      if (!compact.ok) { throw new Error(compact.errorMessage || 'CACHE_INDEX_COMPACT'); }
    }
    this.evicted += ids.length;
    this.increment('evicted', ids.length);
    return true;
  }

  async enforceLimit(): Promise<void> {
    while (this.ledger.isOverLimit()) {
      if (this.settings.discard !== 'discard_oldest' || !await this.evictOne()) { break; }
    }
  }

  async execute(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    if (FTRumFileStore.handles(request.command)) { return await new FTRumFileStore(this).execute(request); }
    switch (request.command) {
      case 'init': await this.enforceLimit(); return { ok: true };
      case 'writeSyncData':
      case 'writeSyncDrafts': return { ok: true, write: await this.write(request) };
      case 'querySyncData': return { ok: true, rows: this.query(request) };
      case 'queryUploadData': return await this.uploadPage(request);
      case 'hasSyncData': return { ok: true, value: this.query({ command: 'querySyncData', dataTypes: request.dataTypes, limit: 1 }).length > 0 };
      case 'queryTotalCount': {
        let count = 0;
        for (const id of this.list('sync')) { const row = this.sync(id); if (row && this.matches(row, request.dataTypes || [])) { count++; } }
        return { ok: true, count };
      }
      case 'getDbSize': return { ok: true, count: this.ledger.usage().governedBytes };
      case 'getLastErrorTimeLine': return { ok: true, count: Number(this.read('meta', 'errorTimeLine') || '-1') };
      case 'updateLastErrorTimeLine':
        if (!await this.commit([{ path: this.path('meta', 'errorTimeLine'), body: String(request.errorTimeLine || -1) }])) {
          throw new Error('CACHE_TIMELINE_CAPACITY');
        }
        return { ok: true };
      case 'uploadCommit': return await this.uploadCommit(request);
      case 'deleteSyncRows':
      case 'deleteSyncRowIds':
      case 'deleteOldestSyncData':
      case 'deleteExpireCache':
      case 'updateDataType':
      case 'errorSampledMaintenance': return await this.maintain(request);
      case 'queryRelatedUUIDsByActionId': {
        const strings: string[] = [];
        for (const id of this.list('sync')) {
          const row = this.sync(id);
          if (row && this.type(row) === request.dataType && row.dataString.startsWith(`${request.measurementType},`) &&
            row.dataString.split(' ')[0].split(',').includes(`action_id=${request.actionId}`)) { strings.push(row.uuid); }
        }
        return { ok: true, strings };
      }
      case 'deleteAll': {
        const counts: FTDBTaskPoolDeleteAllResult = { sync: this.list('sync').length, view: this.list('view').length, action: this.list('action').length };
        // A durable clearing marker makes interruption resume deletion before any new reads/writes.
        FTCacheFiles.atomicWrite(this.path('meta', 'clearing'), 'true');
        this.finishClear();
        return { ok: true, deleteAll: counts };
      }
      default: throw new Error(`Unsupported file-store command: ${request.command}`);
    }
  }

  finishClear(): void {
    if (this.read('meta', 'clearing') === null) { return; }
    for (const kind of ['sync', 'view', 'action', 'lease', 'quarantine']) {
      for (const id of this.list(kind)) { FTCacheFiles.remove(this.path(kind, id)); }
    }
    FTCacheFiles.remove(this.path('meta', 'errorTimeLine'));
    FTCacheFiles.remove(this.path('meta', 'clearing'));
    this.ledger.invalidate();
  }

  private async write(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolWriteResponse> {
    const rows = request.records || this.draftRows(request);
    const response: FTDBTaskPoolWriteResponse = {
      result: { success: true, source: request.source || 'file.write', requested: rows.length, inserted: 0,
        updated: 0, dropped: 0, duplicateSkipped: 0, deletedOld: 0, acceptedUuids: [], errorMessage: '' },
      logCountDelta: 0, rumCountDelta: 0, currentDbSize: 0, dbLaneWaitMs: 0,
      computeMs: 0, executeMs: 0, insertMs: 0, sizeCheckMs: 0, cleanupMs: 0,
      recoverMs: this.lastRecoveryMs, reserveMs: 0, journalMs: 0, fsyncMs: 0, evictionMs: 0
    };
    const startedAt = Date.now();
    const beforeCounts = this.ledger.counts();
    const timing: FTCacheWriteTiming = { recoverMs: this.lastRecoveryMs, reserveMs: 0, journalMs: 0, fsyncMs: 0, evictionMs: 0 };
    const changes: FTCacheMutation[] = [];
    const pendingRows: SyncDataJSON[] = [];
    const plannedUuids = new Set<string>();
    let pendingLog = 0; let pendingRum = 0;
    let nextId = Number(this.read('meta', 'nextId') || '1');
    let needsNextId = false;
    let pendingTimeline = Number(this.read('meta', 'errorTimeLine') || '-1');
    for (const row of rows) { this.protectedUuids.add(row.uuid); }
    try {
      for (const row of rows) {
        if (!row.uuid || !row.dataString || !(row.time > 0)) { response.result.dropped++; continue; }
        // A duplicate in the same batch used to be observed after the first
        // per-row commit. Preserve that result without paying for a second journal.
        if (plannedUuids.has(row.uuid)) {
          response.result.duplicateSkipped++; response.result.acceptedUuids.push(row.uuid); continue;
        }
        const existing = this.sync(row.uuid);
        if (existing && this.digest(existing) === this.digest(row)) {
          response.result.duplicateSkipped++; response.result.acceptedUuids.push(row.uuid); continue;
        }
        if (existing && request.options?.updateOrInsertByUuid !== true) {
          response.result.duplicateSkipped++; response.result.acceptedUuids.push(row.uuid); continue;
        }
        if (!existing && !await this.admitCount(row, request, pendingLog, pendingRum)) { response.result.dropped++; continue; }
        row.id = existing ? existing.id : nextId;
        const body = JSON.stringify(row);
        if (FTCacheFiles.bytes(FTCacheFiles.encode(body)) > FTCacheFiles.MAX_RECORD_BYTES) {
          response.result.dropped++; this.increment('rejected', 1); continue;
        }
        if (!existing) { nextId++; needsNextId = true; }
        changes.push({ path: this.path('sync', row.uuid), body });
        pendingRows.push(row); plannedUuids.add(row.uuid);
        if (this.type(row) === 'log' && !existing) { pendingLog++; }
        else if (['rum_app', 'rum_webview'].includes(this.type(row)) && !existing) { pendingRum++; }
        if (existing) { response.result.updated++; } else { response.result.inserted++; }
        response.result.acceptedUuids.push(row.uuid);
      }
      if (needsNextId) { changes.push({ path: this.path('meta', 'nextId'), body: String(nextId) }); }
      if (request.options?.lastErrorTimeLine !== undefined && pendingRows.length > 0) {
        pendingTimeline = Math.max(pendingTimeline, request.options.lastErrorTimeLine);
        changes.push({ path: this.path('meta', 'errorTimeLine'), body: String(pendingTimeline) });
      }
      if (!this.settings.directUpload && this.settings.mode === 'file' && pendingRows.length > 0) {
        this.projection(changes, [{ command: 'writeSyncData', records: pendingRows, options: {
          applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true
        } }]);
      }
      response.computeMs = Math.max(0, Date.now() - startedAt);
      if (changes.length > 0 && !await this.commit(changes, timing)) {
        // A journal is all-or-nothing: report no speculative inserts as accepted.
        const committed = response.result.inserted + response.result.updated;
        response.result.dropped += committed;
        response.result.inserted = 0; response.result.updated = 0;
        response.result.acceptedUuids = response.result.acceptedUuids.filter((uuid: string) => !plannedUuids.has(uuid));
      } else if (pendingRows.length > 0) {
        await this.repairProjection();
      }
    } finally {
      this.protectedUuids.clear();
    }
    response.result.deletedOld = this.evicted;
    const afterCounts = this.ledger.counts();
    response.logCountDelta = afterCounts.log - beforeCounts.log;
    response.rumCountDelta = afterCounts.rum - beforeCounts.rum;
    response.currentDbSize = this.ledger.usage().governedBytes;
    // `insertMs` is the durable sub-phase of FileStore execution, so it is
    // deliberately contained by executeMs just like SQLite insert timing.
    response.executeMs = timing.journalMs;
    response.insertMs = timing.journalMs;
    response.sizeCheckMs = timing.reserveMs;
    response.cleanupMs = timing.recoverMs + timing.evictionMs;
    response.recoverMs = timing.recoverMs;
    response.reserveMs = timing.reserveMs;
    response.journalMs = timing.journalMs;
    response.fsyncMs = timing.fsyncMs;
    response.evictionMs = timing.evictionMs;
    return response;
  }

  private async admitCount(row: SyncDataJSON, request: FTDBTaskPoolRequest, pendingLog: number = 0,
    pendingRum: number = 0): Promise<boolean> {
    if (this.settings.limitEnabled || request.options?.applyCachePolicy !== true || !request.policy) { return true; }
    const log = this.type(row) === 'log';
    if (!log && !['rum_app', 'rum_webview'].includes(this.type(row))) { return true; }
    const limit = log ? request.policy.logLimitCount : request.policy.rumLimitCount;
    const counts = this.ledger.counts();
    if (limit <= 0 || (log ? counts.log + pendingLog : counts.rum + pendingRum) < limit) { return true; }
    const discard = log ? request.policy.logDiscardStrategy : request.policy.rumDiscardStrategy;
    if (discard !== 'discard_oldest') { return false; }
    return await this.evictOne(log ? ['log'] : ['rum_app', 'rum_webview']);
  }

  private query(request: FTDBTaskPoolRequest): SyncDataJSON[] {
    const limit = Math.max(1, request.limit || 50);
    const rows: SyncDataJSON[] = [];
    for (const id of this.list('sync')) {
      const row = this.sync(id);
      if (!row || !this.matches(row, request.dataTypes || []) ||
        (request.afterId !== undefined && row.id <= request.afterId)) { continue; }
      rows.push(row);
      rows.sort((a: SyncDataJSON, b: SyncDataJSON) => request.afterId !== undefined ? a.id - b.id :
        (request.newestFirst ? -1 : 1) * this.compare(a, b));
      if (rows.length > limit) { rows.pop(); }
    }
    return rows;
  }

  async leaseRows(rows: SyncDataJSON[]): Promise<void> {
    if (rows.length === 0) { return; }
    const changes: FTCacheMutation[] = [];
    for (const row of rows) {
      const lease: FTCacheLease = { digest: this.digest(row), expires: Date.now() + 15 * 60 * 1000 };
      changes.push({ path: this.path('lease', row.uuid), body: JSON.stringify(lease) });
    }
    this.commitDirect(changes);
  }

  private async uploadPage(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    const limit = Math.max(1, request.limit || 50);
    const maxBytes = Math.max(1024, request.maxBytes || 1024 * 1024);
    const candidates: FTUploadCandidate[] = [];
    let matching = 0;
    // Only page-sized metadata is retained. Payload memory is bounded by maxBytes + one record.
    for (const id of this.list('sync')) {
      const row = this.sync(id);
      if (!row || !this.matches(row, request.dataTypes || [])) { continue; }
      const bytes = this.uploadBytes(row);
      if (bytes + 1 > maxBytes) {
        if (!this.leased(row)) { this.quarantineOversized(row); }
        continue;
      }
      matching++;
      candidates.push({ uuid: row.uuid, id: row.id, time: row.time, bytes });
      candidates.sort((a: FTUploadCandidate, b: FTUploadCandidate) => a.time - b.time || a.id - b.id);
      if (candidates.length > limit + 1) { candidates.pop(); }
    }
    const uploadRows: SDKUploadRowDTO[] = [];
    const selected: SyncDataJSON[] = [];
    let bytes = 1; let clipped = false;
    for (const candidate of candidates) {
      if (uploadRows.length >= limit) { break; }
      if (bytes + candidate.bytes > maxBytes) { clipped = true; break; }
      const row = this.sync(candidate.uuid); if (!row) { continue; }
      uploadRows.push({ id: row.id, uuid: row.uuid, dataType: String(row.dataType), dataString: row.dataString,
        time: row.time, customDataType: row.customDataTypeString });
      selected.push(row); bytes += candidate.bytes;
    }
    await this.leaseRows(selected);
    return { ok: true, uploadRows, hasMore: matching > uploadRows.length,
      byteCount: uploadRows.length > 0 ? bytes : 0, byteLimitReached: clipped };
  }

  private uploadBytes(row: SyncDataJSON): number {
    const dto: SDKUploadRowDTO = { id: row.id, uuid: row.uuid, dataType: String(row.dataType),
      dataString: row.dataString, time: row.time, customDataType: row.customDataTypeString };
    // Include JSON escaping and the array separator; the page adds the remaining bracket byte.
    return FTCacheFiles.bytes(JSON.stringify(dto)) + 1;
  }

  private quarantineOversized(row: SyncDataJSON): void {
    const quarantine = `${this.root}/quarantine`;
    while (FTCacheFiles.size(quarantine) > FTCacheFiles.MAX_QUARANTINE_BYTES) {
      const names = FTCacheFiles.fileNames(quarantine).sort();
      if (names.length === 0) { break; }
      FTCacheFiles.remove(`${quarantine}/${names[0]}`);
    }
    fs.renameSync(this.path('sync', row.uuid), `${quarantine}/oversize-${Date.now()}-${encodeURIComponent(row.uuid)}.json`);
    FTCacheFiles.syncDirectory(quarantine); FTCacheFiles.syncDirectory(`${this.root}/sync`);
    this.ledger.invalidate();
    this.increment('rejected', 1);
  }

  private async uploadCommit(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    if (!['delete', 'reinsert'].includes(request.commitAction || '')) { throw new Error('CACHE_COMMIT_ACTION'); }
    const beforeLog = this.countCategory(true); const beforeRum = this.countCategory(false);
    const rows = request.records || [];
    const changes: FTCacheMutation[] = [];
    const deletedIds: string[] = [];
    const preservedIds = new Set<string>();
    for (const row of rows) {
      this.protectedUuids.add(row.uuid);
      const existing = this.sync(row.uuid);
      if (existing && this.digest(existing) === this.digest(row)) {
        changes.push({ path: this.path('sync', row.uuid), body: null }); deletedIds.push(row.uuid);
      } else if (existing) { preservedIds.add(row.uuid); }
      changes.push({ path: this.path('lease', row.uuid), body: null });
    }
    const replacements: SyncDataJSON[] = [];
    let nextId = Number(this.read('meta', 'nextId') || '1');
    for (const row of request.commitAction === 'reinsert' && deletedIds.length > 0 ? request.reInsertRecords || [] : []) {
      if (preservedIds.has(row.uuid)) { continue; }
      this.protectedUuids.add(row.uuid);
      row.id = this.sync(row.uuid)?.id || nextId++;
      const body = JSON.stringify(row);
      if (FTCacheFiles.bytes(FTCacheFiles.encode(body)) > FTCacheFiles.MAX_RECORD_BYTES) { throw new Error('CACHE_REINSERT_TOO_LARGE'); }
      const deletion = changes.find((c: FTCacheMutation) => c.path === this.path('sync', row.uuid));
      if (deletion) { deletion.body = body; } else { changes.push({ path: this.path('sync', row.uuid), body }); }
      replacements.push(row);
    }
    if (replacements.length > 0) { changes.push({ path: this.path('meta', 'nextId'), body: String(nextId) }); }
    if (!this.settings.directUpload && this.settings.mode === 'file') {
      const requests: FTDBTaskPoolRequest[] = [{ command: 'deleteSyncUuids', ids: deletedIds }];
      if (replacements.length > 0) { requests.push({ command: 'writeSyncData', records: replacements,
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } }); }
      this.projection(changes, requests);
    }
    // ACK/retry is one forward-recoverable transaction. Never delete before reserving retry space.
    if (replacements.length === 0) { this.commitDirect(changes); }
    else if (!await this.commit(changes)) { throw new Error('CACHE_REINSERT_CAPACITY'); }
    await this.repairProjection();
    this.protectedUuids.clear();
    // Stale/already-applied ACKs are successful no-ops; only physical count deltas are returned.
    const inserted = request.commitAction === 'reinsert' ? (request.reInsertRecords || []).length : 0;
    return { ok: true, uploadCommit: { deletedRows: rows.length, insertedRows: inserted,
      affectedRows: rows.length + inserted, logCountDelta: this.countCategory(true) - beforeLog,
      rumCountDelta: this.countCategory(false) - beforeRum, dbLaneWaitMs: 0 } };
  }

  private async deleteRows(rows: SyncDataJSON[]): Promise<number> {
    let deleted = 0;
    const changes: FTCacheMutation[] = [];
    const projectionIds: string[] = [];
    const seen = new Set<string>();
    for (const row of rows) {
      if (seen.has(row.uuid)) { continue; }
      seen.add(row.uuid);
      const existing = this.sync(row.uuid);
      // An old in-flight ACK must never delete a newer aggregate version of the same UUID.
      if (existing && this.digest(existing) === this.digest(row)) {
        changes.push({ path: this.path('sync', row.uuid), body: null }); deleted++;
        projectionIds.push(row.uuid);
      }
      changes.push({ path: this.path('lease', row.uuid), body: null });
    }
    if (!this.settings.directUpload && this.settings.mode === 'file' && projectionIds.length > 0) {
      this.projection(changes, [{ command: 'deleteSyncUuids', ids: projectionIds }]);
    }
    if (changes.length > 0) {
      this.commitDirect(changes);
      await this.repairProjection();
    }
    return deleted;
  }

  private async maintain(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    let deleted = 0; let updated = 0;
    if (request.command === 'deleteSyncRows') { deleted = await this.deleteRows(request.records || []); }
    else {
      const oldest = request.command === 'deleteOldestSyncData' ? this.query(request).map((r: SyncDataJSON) => r.uuid) : [];
      for (const id of this.list('sync')) {
        const row = this.sync(id); if (!row) { continue; }
        let remove = request.command === 'deleteSyncRowIds' && (request.rowIds || []).includes(row.id);
        remove = remove || (request.command === 'deleteOldestSyncData' && oldest.includes(row.uuid) && !this.leased(row));
        const maintenance = request.command === 'errorSampledMaintenance';
        if ((request.command === 'updateDataType' || maintenance) && this.type(row) === request.dataType &&
          this.type(row).endsWith('_error_sampled') && row.time <= (request.errorTimeLine || -1) && (request.errorTimeLine || -1) > 0) {
          row.customDataTypeString = this.type(row).replace('_error_sampled', '');
          const changes: FTCacheMutation[] = [{ path: this.path('sync', row.uuid), body: JSON.stringify(row) }];
          if (!this.settings.directUpload && this.settings.mode === 'file') {
            this.projection(changes, [{ command: 'writeSyncData', records: [row], options: {
              applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true
            } }]);
          }
          if (await this.commit(changes)) { updated++; await this.repairProjection(); }
        } else if ((request.command === 'deleteExpireCache' || maintenance) && this.type(row) === request.dataType &&
          row.time < (request.now || 0) - (request.duration || 0)) { remove = true; }
        if (remove) { deleted += await this.deleteRows([row]); }
      }
    }
    return request.command === 'errorSampledMaintenance' ?
      { ok: true, maintenance: { updatedRows: updated, deletedRows: deleted, dbLaneWaitMs: 0 } } :
      { ok: true, count: request.command === 'updateDataType' ? updated : deleted };
  }

  private sync(id: string): SyncDataJSON | null {
    const body = this.read('sync', id);
    return body === null ? null : JSON.parse(body) as SyncDataJSON;
  }

  private leased(row: SyncDataJSON): boolean {
    const body = this.read('lease', row.uuid);
    if (!body) { return false; }
    const lease = JSON.parse(body) as FTCacheLease;
    return lease.expires > Date.now() && lease.digest === this.digest(row);
  }

  private digest(row: SyncDataJSON): string {
    return FTCacheFiles.checksum(`${row.uuid}\n${this.type(row)}\n${row.time}\n${row.dataString}`);
  }

  private type(row: SyncDataJSON): string { return row.customDataTypeString || String(row.dataType); }
  private matches(row: SyncDataJSON, types: string[]): boolean { return types.length === 0 || types.includes(this.type(row)); }
  private compare(a: SyncDataJSON, b: SyncDataJSON): number { return a.time - b.time || a.id - b.id; }

  private countCategory(log: boolean): number {
    let count = 0;
    for (const id of this.list('sync')) {
      const row = this.sync(id);
      if (row && (log ? this.type(row) === 'log' : ['rum_app', 'rum_webview'].includes(this.type(row)))) { count++; }
    }
    return count;
  }

  private draftRows(request: FTDBTaskPoolRequest): SyncDataJSON[] {
    const rows: SyncDataJSON[] = [];
    for (const draft of request.drafts || []) {
      const type = draft.dataType || request.fallbackDataType || 'log';
      rows.push({ id: 0, uuid: draft.uuid, dataString: draft.dataString, time: draft.time,
        dataType: type === 'log' ? DataType.LOG : type === 'rum_webview' ? DataType.RUM_WEBVIEW : DataType.RUM_APP,
        customDataTypeString: draft.customDataType });
    }
    return rows;
  }

  private projection(changes: FTCacheMutation[], requests: FTDBTaskPoolRequest[]): void {
    const projection: FTCacheProjection = { requests };
    changes.push({ path: this.path('meta', 'projection'), body: JSON.stringify(projection) });
  }

  private increment(name: string, delta: number): void {
    const body = this.read('meta', 'counters');
    const counters: FTCacheCounters = body ? JSON.parse(body) as FTCacheCounters : { evicted: 0, rejected: 0, corrupt: 0 };
    if (name === 'evicted') { counters.evicted += delta; }
    else if (name === 'rejected') { counters.rejected += delta; }
    else { counters.corrupt += delta; }
    FTCacheFiles.atomicWrite(this.path('meta', 'counters'), JSON.stringify(counters));
  }
}
