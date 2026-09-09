import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheSettings } from './FTCacheContext';
import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTCacheFileStore, FTSqliteRunner } from './FTCacheFileStore';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse } from './FTDBTaskPoolExecutor';
import { FTRumFileStore } from './FTRumFileStore';
import { SyncDataJSON } from './bean/SyncData';
import { runFTDBSpoolTaskPoolExecute } from './FTDBSpoolTaskPoolOperations';
import { FTDBSpoolTaskPoolRequest, FTDBSpoolTaskPoolResponse } from './FTDBSpoolTaskPoolExecutor';

interface FTCacheMigration { state: string; afterId: number; legacyDone: boolean; }

/** One command boundary for sync payloads, aggregates, migration and recovery. */
export class FTCacheCoordinator {
  static async run(context: Context, request: FTDBTaskPoolRequest, sqlite: FTSqliteRunner): Promise<FTDBTaskPoolResponse> {
    const settings = request.cache;
    if (!settings || (settings.mode === 'sqlite' && request.command !== 'getCacheStatus')) { return await sqlite(request); }
    const lock = fs.openSync(`${context.filesDir}/ft_sdk_cache.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let locked = false;
    try {
      await lock.lock(true); locked = true;
      const store = new FTCacheFileStore(context, settings, sqlite);
      await store.recover();
      if (request.command === 'getCacheStatus') { return { ok: true, strings: [JSON.stringify(store.status())] }; }
      if (settings.mode === 'shadow') { return await FTCacheCoordinator.shadow(store, request, sqlite); }
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

  private static async shadow(store: FTCacheFileStore, request: FTDBTaskPoolRequest,
    sqlite: FTSqliteRunner): Promise<FTDBTaskPoolResponse> {
    if (store.read('meta', 'migration') !== null) {
      if (store.list('sync').length + store.list('view').length + store.list('action').length > 0) {
        throw new Error('CACHE_MODE_SWITCH_REQUIRES_DRAIN: file cache must be empty before shadow mode');
      }
      FTCacheFiles.remove(store.path('meta', 'migration'));
      FTCacheFiles.remove(store.path('meta', 'sqliteReleased'));
    }
    FTCacheFiles.atomicWrite(store.path('meta', 'shadowSource'), 'true');
    const dirty = store.path('meta', 'shadowDirty');
    FTCacheFiles.atomicWrite(dirty, 'true');
    const response = await FTCacheCoordinator.checked(sqlite, request);
    try { await FTCacheCoordinator.reconcileShadow(store, sqlite); }
    catch (error) { FTCacheFiles.atomicWrite(dirty, String(error)); }
    return response;
  }

  private static async reconcileShadow(store: FTCacheFileStore, sqlite: FTSqliteRunner): Promise<void> {
    // Snapshot reconciliation mirrors every mutation, including close, counters and deletes.
    // The dirty marker is retained on failure; diagnostics never report an incomplete mirror as healthy.
    const dirty = store.path('meta', 'shadowDirty');
    const rum = await FTCacheCoordinator.checked(sqlite, { command: 'exportRumState' });
    const syncIds = new Set<string>(); let afterId = 0;
    while (true) {
      const page = await FTCacheCoordinator.checked(sqlite, { command: 'querySyncData', afterId, limit: 128 });
      const rows = page.rows || []; if (rows.length === 0) { break; }
      await FTCacheCoordinator.copyRows(store, rows);
      for (const row of rows) { syncIds.add(row.uuid); }
      afterId = rows[rows.length - 1].id;
    }
    for (const id of store.list('sync')) {
      if (!syncIds.has(id)) { FTCacheFiles.commit(store.root, [{ path: store.path('sync', id), body: null }]); }
    }
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
    FTCacheFiles.remove(dirty);
  }
}
