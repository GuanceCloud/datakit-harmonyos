import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheSettings } from './FTCacheContext';
import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTCacheFileStore, FTSqliteRunner } from './FTCacheFileStore';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse, FTDBTaskPoolWriteOptions } from './FTDBTaskPoolExecutor';
import { FTRumFileStore } from './FTRumFileStore';
import { FTInnerLogger } from '../log/FTLogger';
import { SyncDataJSON } from './bean/SyncData';
import { runFTDBSpoolTaskPoolExecute } from './FTDBSpoolTaskPoolOperations';
import { FTDBSpoolTaskPoolRequest, FTDBSpoolTaskPoolResponse } from './FTDBSpoolTaskPoolExecutor';

interface FTCacheMigration { state: string; afterId: number; legacyDone: boolean; }
const TAG = 'FTCacheCoordinator';

/** One command boundary for sync payloads, aggregates, migration and recovery. */
export class FTCacheCoordinator {
  static async run(context: Context, request: FTDBTaskPoolRequest, sqlite: FTSqliteRunner): Promise<FTDBTaskPoolResponse> {
    const settings = request.cache;
    if (!settings || (settings.mode === 'sqlite' && request.command !== 'getCacheStatus')) { return await sqlite(request); }
    // `getDbSize` remains a physical SQLite diagnostic even though shadow
    // capacity is governed by its FileStore mirror.
    if (settings.mode === 'shadow' && request.command === 'getDbSize') { return await sqlite(request); }
    const lock = fs.openSync(`${context.filesDir}/ft_sdk_cache.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let locked = false;
    try {
      await lock.lock(true); locked = true;
      const store = new FTCacheFileStore(context, settings, sqlite);
      await store.recover();
      if (request.command === 'getCacheStatus') {
        const status = store.status();
        if (settings.mode === 'sqlite') {
          const primary = await FTCacheCoordinator.checked(sqlite, { command: 'getDbSize' });
          status.usage.governedBytes = Math.max(0, primary.count || 0);
          status.usage.governedScope = 'SQLite 主库页分配';
          status.usage.overLimit = settings.limitEnabled && status.usage.governedBytes >= status.usage.capacityBytes;
        }
        return { ok: true, strings: [JSON.stringify(status)] };
      }
      if (settings.mode === 'shadow') { return await FTCacheCoordinator.shadow(context, store, request, sqlite); }
      await FTCacheCoordinator.migrate(store, context, sqlite);
      if (settings.directUpload && store.read('meta', 'sqliteReleased') === null) {
        // Reclaim the old payload pages before opening the file-only lane; interruption safely retries.
        await FTCacheCoordinator.checked(sqlite, { command: 'deleteAll' });
        await FTCacheCoordinator.checked(sqlite, { command: 'compactCacheIndex' });
        FTCacheFiles.atomicWrite(store.path('meta', 'sqliteReleased'), 'true');
      }
      if (store.read('meta', 'clearing') !== null) {
        if (!settings.directUpload) { await FTCacheCoordinator.checked(sqlite, { command: 'deleteAll' }); }
        FTCacheCoordinator.clearSpool(context);
        store.finishClear();
      }
      if (request.command === 'deleteAll') {
        FTCacheFiles.atomicWrite(store.path('meta', 'clearing'), 'true');
        if (!settings.directUpload) { await FTCacheCoordinator.checked(sqlite, request); }
        FTCacheCoordinator.clearSpool(context);
      }
      // Compatibility mode retains SQLite's query index; file payloads and commits are authoritative.
      if (!settings.directUpload && ['querySyncData', 'queryUploadData', 'hasSyncData', 'queryTotalCount'].includes(request.command)) {
        const count = await FTCacheCoordinator.checked(sqlite, { command: 'queryTotalCount' });
        if (count.count !== store.list('sync').length) { await FTCacheCoordinator.rebuildProjection(store, sqlite); }
        const response = await FTCacheCoordinator.checked(sqlite, request);
        if (response.uploadRows) {
          const records: SyncDataJSON[] = response.uploadRows.map((r) => ({
            id: r.id, uuid: r.uuid, dataString: r.dataString, time: r.time,
            dataType: r.dataType, customDataTypeString: r.customDataType
          } as SyncDataJSON));
          await store.leaseRows(records);
        }
        return response;
      }
      return await store.execute(request);
    } finally {
      try { if (locked) { lock.unlock(); } } finally { fs.closeSync(lock); }
    }
  }

  private static async checked(sqlite: FTSqliteRunner, request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    const response = await sqlite(request);
    if (!response.ok || (response.write && !response.write.result.success)) {
      throw new Error(response.errorMessage || response.write?.result.errorMessage || 'CACHE_SQLITE_FAILED');
    }
    return response;
  }

  private static async rebuildProjection(store: FTCacheFileStore, sqlite: FTSqliteRunner): Promise<void> {
    await FTCacheCoordinator.checked(sqlite, { command: 'deleteAll' });
    for (const id of store.list('sync')) {
      const body = store.read('sync', id);
      if (body) { await FTCacheCoordinator.checked(sqlite, { command: 'writeSyncData', records: [JSON.parse(body) as SyncDataJSON],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } }); }
    }
  }

  private static async migrate(store: FTCacheFileStore, context: Context, sqlite: FTSqliteRunner): Promise<void> {
    const path = store.path('meta', 'migration');
    const saved = store.read('meta', 'migration');
    const state: FTCacheMigration = saved ? JSON.parse(saved) as FTCacheMigration :
      { state: 'copying', afterId: 0, legacyDone: false };
    if (state.state === 'completed') { return; }
    if (!saved) {
      const pending = await FTCacheCoordinator.checked(sqlite, { command: 'queryTotalCount' });
      if ((pending.count || 0) > 0 && !store.settings.migrate) {
        throw new Error('CACHE_MIGRATION_REQUIRES_OPT_IN: setNeedTransformOldCache(true)');
      }
      FTCacheFiles.atomicWrite(path, JSON.stringify(state));
    }
    // No eviction while copying: the source stays intact until the verified switch.
    const copySettings: FTCacheSettings = { mode: 'file', capacity: store.settings.capacity,
      discard: 'discard', limitEnabled: store.settings.limitEnabled, migrate: true, directUpload: true };
    const target = new FTCacheFileStore(context, copySettings, sqlite);
    if (state.state === 'copying') {
      if (!state.legacyDone) {
        // A shadow is never a migration source: SQLite may already have ACKed its stale records.
        if (store.read('meta', 'shadowSource') !== null || store.read('meta', 'shadowDirty') !== null) {
          for (const kind of ['sync', 'view', 'action', 'lease']) {
            for (const id of store.list(kind)) { FTCacheFiles.remove(store.path(kind, id)); }
          }
          FTCacheFiles.remove(store.path('meta', 'shadowSource'));
          FTCacheFiles.remove(store.path('meta', 'shadowDirty'));
        }
        await FTCacheCoordinator.copyLegacy(target, context);
        state.legacyDone = true; FTCacheFiles.atomicWrite(path, JSON.stringify(state));
      }
      while (true) {
        const page = await FTCacheCoordinator.checked(sqlite, { command: 'queryMigrationPage', afterId: state.afterId, limit: 128 });
        const rows = page.rows || [];
        if (rows.length === 0) { break; }
        await FTCacheCoordinator.copyRows(target, rows);
        state.afterId = rows[rows.length - 1].id;
        FTCacheFiles.atomicWrite(path, JSON.stringify(state));
      }
      const rum = await FTCacheCoordinator.checked(sqlite, { command: 'exportRumState' });
      for (const view of rum.views || []) {
        if (!await target.commit([{ path: target.path('view', view.id), body: JSON.stringify(view) }])) {
          throw new Error('CACHE_MIGRATION_CAPACITY');
        }
      }
      for (const action of rum.actions || []) {
        if (!await target.commit([{ path: target.path('action', action.id), body: JSON.stringify(action) }])) {
          throw new Error('CACHE_MIGRATION_CAPACITY');
        }
      }
      const timeline = await FTCacheCoordinator.checked(sqlite, { command: 'getLastErrorTimeLine' });
      await target.execute({ command: 'updateLastErrorTimeLine', errorTimeLine: timeline.count });
      await FTCacheCoordinator.verify(target, sqlite, rum);
      state.state = 'verified'; FTCacheFiles.atomicWrite(path, JSON.stringify(state));
    }
    if (state.state === 'verified') {
      state.state = 'switched'; FTCacheFiles.atomicWrite(path, JSON.stringify(state));
    }
    if (state.state === 'switched') {
      // Rebuild the temporary projection from the now-authoritative files (including legacy-only UUIDs).
      if (!store.settings.directUpload) {
        await FTCacheCoordinator.checked(sqlite, { command: 'deleteAll' });
        for (const id of store.list('sync')) {
          const body = store.read('sync', id);
          if (body) { await FTCacheCoordinator.checked(sqlite, { command: 'writeSyncData', records: [JSON.parse(body) as SyncDataJSON],
            options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } }); }
        }
      } else { await FTCacheCoordinator.checked(sqlite, { command: 'deleteAll' }); }
      await FTCacheCoordinator.clearLegacy(context);
      state.state = 'completed'; FTCacheFiles.atomicWrite(path, JSON.stringify(state));
    }
  }

  private static async copyRows(store: FTCacheFileStore, rows: SyncDataJSON[]): Promise<void> {
    const copies = rows.map((r: SyncDataJSON) => JSON.parse(JSON.stringify(r)) as SyncDataJSON);
    const response = await store.execute({ command: 'writeSyncData', records: copies,
      options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
    if (!response.write || response.write.result.acceptedUuids.length !== rows.length) { throw new Error('CACHE_MIGRATION_CAPACITY'); }
  }

  private static async verify(store: FTCacheFileStore, sqlite: FTSqliteRunner, rum: FTDBTaskPoolResponse): Promise<void> {
    let afterId = 0;
    while (true) {
      const page = await FTCacheCoordinator.checked(sqlite, { command: 'queryMigrationPage', afterId, limit: 128 });
      const rows = page.rows || [];
      if (rows.length === 0) { break; }
      for (const source of rows) {
        const body = store.read('sync', source.uuid);
        const row = body ? JSON.parse(body) as SyncDataJSON : null;
        if (!row || row.uuid !== source.uuid || row.time !== source.time || row.dataString !== source.dataString ||
          (row.customDataTypeString || row.dataType) !== (source.customDataTypeString || source.dataType)) {
          throw new Error('CACHE_MIGRATION_VERIFY_FAILED');
        }
      }
      afterId = rows[rows.length - 1].id;
    }
    for (const view of rum.views || []) {
      if (store.read('view', view.id) !== JSON.stringify(view)) { throw new Error('CACHE_VIEW_VERIFY_FAILED'); }
    }
    for (const action of rum.actions || []) {
      if (store.read('action', action.id) !== JSON.stringify(action)) { throw new Error('CACHE_ACTION_VERIFY_FAILED'); }
    }
  }

  private static async copyLegacy(store: FTCacheFileStore, context: Context): Promise<void> {
    const dir = `${context.filesDir}/ft_sdk_file_store`;
    for (const name of ['sync_data.ndjson', 'sync_data.inflight.ndjson', 'sync_data.active.ndjson']) {
      let offset = 0;
      while (FTCacheFiles.exists(`${dir}/${name}`)) {
        const page = await runFTDBSpoolTaskPoolExecute({ command: 'readPage', spoolDir: dir,
          activePath: `${dir}/sync_data.active.ndjson`, inflightPath: `${dir}/sync_data.inflight.ndjson`,
          legacyPath: `${dir}/sync_data.ndjson`, readPath: `${dir}/${name}`, byteOffset: offset, recordLimit: 128 } as FTDBSpoolTaskPoolRequest) as FTDBSpoolTaskPoolResponse;
        if (!page.ok || page.skippedRecords > 0) { throw new Error('CACHE_LEGACY_CORRUPT: source retained'); }
        await FTCacheCoordinator.copyRows(store, page.records.map((r) => r.data));
        if (!page.hasMoreRecords) { break; }
        if (page.nextByteOffset <= offset) { throw new Error('CACHE_LEGACY_CURSOR'); }
        offset = page.nextByteOffset;
      }
    }
  }

  private static async clearLegacy(context: Context): Promise<void> {
    const dir = `${context.filesDir}/ft_sdk_file_store`;
    for (const name of ['sync_data.ndjson', 'sync_data.inflight.ndjson', 'sync_data.active.ndjson']) {
      FTCacheFiles.remove(`${dir}/${name}`);
    }
  }

  private static clearSpool(context: Context): void {
    const root = `${context.filesDir}/ft_sdk_spool`;
    if (!FTCacheFiles.exists(root)) { return; }
    for (const name of fs.listFileSync(root)) {
      const path = `${root}/${name}`;
      if (!fs.statSync(path).isDirectory()) { FTCacheFiles.remove(path); }
    }
  }

  /**
   * SQLite remains authoritative in shadow mode.  A clean mirror is updated
   * from the just-committed command; a complete SQLite scan is reserved for
   * first use and recovery from a durable dirty marker.
   */
  private static async shadow(context: Context, store: FTCacheFileStore, request: FTDBTaskPoolRequest,
    sqlite: FTSqliteRunner): Promise<FTDBTaskPoolResponse> {
    if (store.read('meta', 'migration') !== null) {
      if (store.list('sync').length + store.list('view').length + store.list('action').length > 0) {
        throw new Error('CACHE_MODE_SWITCH_REQUIRES_DRAIN: file cache must be empty before shadow mode');
      }
      FTCacheFiles.remove(store.path('meta', 'migration'));
      FTCacheFiles.remove(store.path('meta', 'sqliteReleased'));
    }
    // A mirror is diagnostic storage.  It must never reject a successful
    // SQLite write merely because both physical representations coexist.
    const mirror = new FTCacheFileStore(context, store.settings, sqlite, true);
    const source = store.path('meta', 'shadowSource');
    const dirty = store.path('meta', 'shadowDirty');
    let mirrorReady = true;
    if (store.read('meta', 'shadowSource') === null || store.read('meta', 'shadowDirty') !== null) {
      FTInnerLogger.i(TAG, `Reconciling FileStore shadow: command=${request.command}`);
      await mirror.commit([{ path: source, body: 'true' }, { path: dirty, body: 'true' }]);
      try {
        await FTCacheCoordinator.reconcileShadow(mirror, sqlite);
        FTInnerLogger.i(TAG, 'FileStore shadow reconciliation completed');
      }
      catch (error) {
        mirrorReady = false;
        await FTCacheCoordinator.markShadowDirty(mirror, String(error));
        FTInnerLogger.w(TAG, `FileStore shadow reconciliation deferred: ${error}`);
      }
    }
    if (!FTCacheCoordinator.mirrorsCommand(request.command)) {
      return await FTCacheCoordinator.checked(sqlite, request);
    }
    // Mark before SQLite commits.  A process death between the two stores
    // therefore causes one recovery reconciliation, never a silent gap.
    await FTCacheCoordinator.markShadowDirty(mirror, 'true');
    if (request.policy?.enableLimitWithCacheSize) {
      // Android's shadow keeps SQLite authoritative but makes capacity
      // decisions from the FileStore mirror, not the duplicate SQLite pages.
      request.policy.shadowMirrorBytes = mirror.ledger.usage(false).governedBytes;
    }
    const response = await FTCacheCoordinator.checked(sqlite, request);
    if (!mirrorReady) { return response; }
    try {
      await FTCacheCoordinator.applyShadowMutation(mirror, request, response, sqlite);
      if (!await mirror.commit([{ path: dirty, body: null }])) { throw new Error('CACHE_SHADOW_DIRTY_CLEAR_FAILED'); }
    } catch (error) {
      await FTCacheCoordinator.markShadowDirty(mirror, String(error));
      FTInnerLogger.w(TAG, `FileStore shadow update deferred: command=${request.command}, error=${error}`);
    }
    return response;
  }

  private static async markShadowDirty(store: FTCacheFileStore, detail: string): Promise<void> {
    await store.commit([{ path: store.path('meta', 'shadowDirty'), body: detail }]);
  }

  /** Read-only commands do not need a FileStore mirror transaction. */
  private static mirrorsCommand(command: string): boolean {
    return !['init', 'hasSyncData', 'querySyncData', 'queryUploadData', 'queryTotalCount', 'getDbSize',
      'getLastErrorTimeLine', 'getActionInfo', 'getActionCounts', 'getRumPendingResource', 'getPendingRumResource',
      'queryPendingRumActions', 'querySumAction', 'querySumView', 'queryRumViewById', 'queryRelatedUUIDsByActionId',
      'exportRumState', 'queryMigrationPage', 'compactCacheIndex'].includes(command);
  }

  private static async applyShadowMutation(store: FTCacheFileStore, request: FTDBTaskPoolRequest,
    response: FTDBTaskPoolResponse, sqlite: FTSqliteRunner): Promise<void> {
    if (request.command === 'acknowledgeView') {
      await FTCacheCoordinator.mirrorAcknowledgedView(store, request, response);
      return;
    }
    if (['registerPendingRumResource', 'completePendingRumResources', 'markRumActionCloseRequested'].includes(request.command)) {
      // These commands own SQLite-only resource rows but also change their
      // View/Action aggregates.  Reconcile only those small aggregate sets;
      // never re-scan the sync payload queue.
      await FTCacheCoordinator.reconcileShadowAggregates(store, sqlite);
      return;
    }
    const mirrorRequest = FTCacheCoordinator.createShadowRequest(request, response);
    if (mirrorRequest === null) { return; }
    if (response.write && response.write.result.deletedOld > 0) {
      // Cache-size eviction may prefer Logs then fall back to other rows.
      // Reconcile the queue instead of guessing the deleted types from the
      // incoming batch, otherwise a valid SQLite eviction can corrupt shadow.
      await FTCacheCoordinator.reconcileShadowSyncQueue(store, sqlite);
    }
    const mirrorResponse = await store.execute(mirrorRequest);
    if (response.write) {
      const expected = response.write.result.acceptedUuids;
      const actual = mirrorResponse.write?.result.acceptedUuids || [];
      for (const uuid of expected) {
        if (!actual.includes(uuid)) { throw new Error(`CACHE_SHADOW_WRITE_MISMATCH:${uuid}`); }
      }
    }
    if (request.options?.lastErrorTimeLine !== undefined) {
      await store.execute({ command: 'updateLastErrorTimeLine', errorTimeLine: request.options.lastErrorTimeLine });
    }
  }

  private static createShadowRequest(request: FTDBTaskPoolRequest, response: FTDBTaskPoolResponse): FTDBTaskPoolRequest | null {
    if (request.command !== 'writeSyncData' && request.command !== 'writeSyncDrafts') { return request; }
    if (!response.write) { throw new Error('CACHE_SHADOW_WRITE_RESPONSE_MISSING'); }
    const accepted = new Set<string>(response.write.result.acceptedUuids);
    const options: FTDBTaskPoolWriteOptions | undefined = request.options ? {
      applyCachePolicy: false,
      reInsert: request.options.reInsert,
      forceTransaction: true,
      updateOrInsertByUuid: request.options.updateOrInsertByUuid
    } : undefined;
    if (request.records) {
      return {
        command: request.command, source: request.source,
        records: request.records.filter((row) => accepted.has(row.uuid)), options
      };
    }
    return {
      command: request.command, source: request.source,
      drafts: (request.drafts || []).filter((row) => accepted.has(row.uuid)),
      fallbackDataType: request.fallbackDataType, options
    };
  }

  private static async mirrorAcknowledgedView(store: FTCacheFileStore, request: FTDBTaskPoolRequest,
    response: FTDBTaskPoolResponse): Promise<void> {
    const view = request.view;
    if (!view || response.value !== true) { return; }
    await store.execute({ command: 'updateViewUploadTime', viewId: view.id,
      dateTime: view.isClose && view.pendingResource > 0 ? 0 : view.dataUpdateTime });
    // Recovery keeps the predecessor View after its first cached snapshot so
    // the historical Error counter can produce one newer View record.
    if (view.isClose && view.pendingResource <= 0 && request.keepClosedView !== true) {
      await store.execute({ command: 'cleanCloseViewData', ids: [view.id], now: Date.now() });
    }
  }

  private static async reconcileShadow(store: FTCacheFileStore, sqlite: FTSqliteRunner): Promise<void> {
    // Snapshot reconciliation mirrors every mutation, including close, counters and deletes.
    // The dirty marker is retained on failure; diagnostics never report an incomplete mirror as healthy.
    const dirty = store.path('meta', 'shadowDirty');
    await FTCacheCoordinator.reconcileShadowSyncQueue(store, sqlite);
    await FTCacheCoordinator.reconcileShadowAggregates(store, sqlite);
    if (!await store.commit([{ path: dirty, body: null }])) { throw new Error('CACHE_SHADOW_DIRTY_CLEAR_FAILED'); }
  }

  /** Reconciles the payload queue after recovery or an SQLite-side eviction. */
  private static async reconcileShadowSyncQueue(store: FTCacheFileStore, sqlite: FTSqliteRunner): Promise<void> {
    const syncIds = new Set<string>(); let afterId = 0;
    while (true) {
      const page = await FTCacheCoordinator.checked(sqlite, { command: 'querySyncData', afterId, limit: 128 });
      const rows = page.rows || []; if (rows.length === 0) { break; }
      await FTCacheCoordinator.copyRows(store, rows);
      for (const row of rows) { syncIds.add(row.uuid); }
      afterId = rows[rows.length - 1].id;
    }
    for (const id of store.list('sync')) {
      if (!syncIds.has(id) && !await store.commit([{ path: store.path('sync', id), body: null }])) {
        throw new Error('CACHE_SHADOW_CAPACITY');
      }
    }
  }

  /** Reconciles RUM's small aggregate state without touching sync payloads. */
  private static async reconcileShadowAggregates(store: FTCacheFileStore, sqlite: FTSqliteRunner): Promise<void> {
    const rum = await FTCacheCoordinator.checked(sqlite, { command: 'exportRumState' });
    for (const kind of ['view', 'action']) {
      const keep = new Set<string>();
      const changes: FTCacheMutation[] = [];
      if (kind === 'view') {
        for (const v of rum.views || []) { keep.add(v.id); changes.push({ path: store.path(kind, v.id), body: JSON.stringify(v) }); }
      } else {
        for (const a of rum.actions || []) { keep.add(a.id); changes.push({ path: store.path(kind, a.id), body: JSON.stringify(a) }); }
      }
      for (const id of store.list(kind)) { if (!keep.has(id)) { changes.push({ path: store.path(kind, id), body: null }); } }
      if (changes.length > 0 && !await store.commit(changes)) { throw new Error('CACHE_SHADOW_CAPACITY'); }
    }
  }
}
