import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheSettings } from '../../../main/ets/components/db/FTCacheContext';
import { FTCacheFileStore, FTSqliteRunner } from '../../../main/ets/components/db/FTCacheFileStore';
import { FTCacheFiles, FTCacheMutation } from '../../../main/ets/components/db/FTCacheFiles';
import { FTCacheLedger } from '../../../main/ets/components/db/FTCacheLedger';
import { FTDBConfig } from '../../../main/ets/components/db/FTDBConfig';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse } from '../../../main/ets/components/db/FTDBTaskPoolExecutor';
import { SyncDataJSON } from '../../../main/ets/components/db/bean/SyncData';
import { ViewBeanJSON } from '../../../main/ets/components/db/bean/ViewBean';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { DATA_UPLOAD_TRANSPORT_TARGET_BYTES } from '../../../main/ets/components/thread/workers/DataUploadLimits';
import { DBAssert } from './helpers/DBAssert';

let testSequence: number = 0;

interface CacheRecoveryJournal {
  version: number;
  changes: FTCacheMutation[];
}

function removeTree(path: string): void {
  if (!FTCacheFiles.exists(path)) { return; }
  if (!fs.statSync(path).isDirectory()) {
    fs.unlinkSync(path);
    return;
  }
  for (const name of fs.listFileSync(path)) {
    removeTree(`${path}/${name}`);
  }
  fs.rmdirSync(path);
}

function cacheSettings(mode: string, capacity: number): FTCacheSettings {
  return { mode, limitEnabled: true, capacity, discard: 'discard', migrate: false, directUpload: true };
}

function logRow(uuid: string): SyncDataJSON {
  return {
    id: 0,
    uuid,
    dataType: DataType.LOG,
    customDataTypeString: 'log',
    dataString: `df_rum_harmonyos_log,sdk_data_id=${uuid} message="cache device test" 100`,
    time: 100
  };
}

function rumView(id: string): ViewBeanJSON {
  return { id, viewName: 'file-store-view', viewReferrer: '', startTime: 1, isClose: false, sessionId: 's',
    actionCount: 0, errorCount: 0, longTaskCount: 0, viewLoadTime: 0, timeSpent: 0,
    resourceCount: 0, pendingResource: 0, dataUpdateTime: 1, dataUploadTime: 0, viewUpdateTime: 0,
    extraAttr: {}, property: {}, tags: {} };
}

const SQLITE_SUCCESS: FTSqliteRunner = async (_request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> => {
  return { ok: true };
};

export default function ftCacheFileStoreDeviceTest() {
  describe('FTCacheFileStoreDeviceTest', () => {
    let context: Context;
    let testRoot: string;

    beforeEach(async () => {
      const appContext = await DBAssert.getAppContext();
      testRoot = `${appContext.filesDir}/ft_sdk_cache_device_test_${Date.now()}_${testSequence++}`;
      FTCacheFiles.mkdir(testRoot);
      context = new Object() as Context;
      context.filesDir = testRoot;
      context.databaseDir = `${testRoot}/database`;
    });

    afterEach(() => {
      removeTree(testRoot);
    });

    it('replaysAPendingJournalBeforeServingTheCache', 0, () => {
      const root = `${testRoot}/recovery`;
      const payloadPath = `${root}/sync/recovered.json`;
      const payload = JSON.stringify(logRow('recovered-journal-row'));
      const changes: FTCacheMutation[] = [];
      changes.push({ path: payloadPath, body: payload });
      const journal: CacheRecoveryJournal = { version: 1, changes };
      FTCacheFiles.mkdir(`${root}/sync`);
      FTCacheFiles.atomicWrite(`${root}/transaction.json`, JSON.stringify(journal));

      expect(FTCacheFiles.hasPendingJournal(root)).assertTrue();
      FTCacheFiles.recover(root);

      expect(FTCacheFiles.hasPendingJournal(root)).assertFalse();
      expect(FTCacheFiles.read(payloadPath)).assertEqual(payload);
    });

    it('rebuildsLedgerCountsFromPayloadWhenTheLedgerIsDamaged', 0, () => {
      const root = `${testRoot}/ledger`;
      const payloadPath = `${root}/sync/recovered-ledger.json`;
      FTCacheFiles.atomicWrite(payloadPath, JSON.stringify(logRow('recovered-ledger-row')));
      FTCacheFiles.atomicWrite(`${root}/meta/ledger`, 'not-json');

      const ledger = new FTCacheLedger(context, cacheSettings('file', 1024 * 1024), root);
      const counts = ledger.counts();

      expect(counts.log).assertEqual(1);
      expect(counts.rum).assertEqual(0);
    });

    it('governsOnlySyncAndRumAggregateFiles', 0, async () => {
      const primary = new FTCacheFileStore(context, cacheSettings('file', 1024 * 1024), SQLITE_SUCCESS);
      await primary.execute({ command: 'writeSyncData', records: [logRow('governed-payload')],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      FTCacheFiles.mkdir(context.databaseDir);
      FTCacheFiles.mkdir(`${context.filesDir}/ft_sdk_file_store`);
      FTCacheFiles.mkdir(`${context.filesDir}/ft_sdk_spool`);
      FTCacheFiles.atomicWrite(`${context.databaseDir}/${FTDBConfig.DATABASE_NAME}`, 'sqlite'.repeat(512));
      FTCacheFiles.atomicWrite(`${context.filesDir}/ft_sdk_file_store/legacy`, 'legacy'.repeat(512));
      FTCacheFiles.atomicWrite(`${context.filesDir}/ft_sdk_spool/pending`, 'spool'.repeat(512));

      const fileUsage = primary.status().usage;
      expect(fileUsage.governedBytes).assertEqual(fileUsage.payloadBytes);
      expect(fileUsage.totalBytes > fileUsage.governedBytes).assertTrue();

      const shadowLedger = new FTCacheLedger(context, cacheSettings('shadow', 1024 * 1024), `${testRoot}/ft_sdk_cache_v2`);
      const shadowUsage = shadowLedger.usage(true);
      expect(shadowUsage.governedBytes).assertEqual(shadowUsage.payloadBytes);
      expect(shadowUsage.totalBytes > shadowUsage.governedBytes).assertTrue();
    });

    it('keepsShadowMirroringDiagnosticWhenItsOwnCapacityIsExhausted', 0, async () => {
      const primary = new FTCacheFileStore(context, cacheSettings('file', 1), SQLITE_SUCCESS);
      const primaryWrite = await primary.execute({ command: 'writeSyncData', records: [logRow('primary-rejected')],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      expect(primaryWrite.write?.result.inserted).assertEqual(0);
      expect(primaryWrite.write?.result.dropped).assertEqual(1);
      expect(primary.list('sync').length).assertEqual(0);

      removeTree(`${testRoot}/ft_sdk_cache_v2`);
      const mirror = new FTCacheFileStore(context, cacheSettings('shadow', 1), SQLITE_SUCCESS, true);
      const mirrorWrite = await mirror.execute({ command: 'writeSyncData', records: [logRow('shadow-accepted')],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      expect(mirrorWrite.write?.result.inserted).assertEqual(1);
      expect(mirrorWrite.write?.result.dropped).assertEqual(0);
      expect(mirror.list('sync').length).assertEqual(1);
    });

    it('persistsLargeCrashRecordWithinConfiguredCacheCapacity', 0, async () => {
      const store = new FTCacheFileStore(context, cacheSettings('file', 2 * 1024 * 1024), SQLITE_SUCCESS);
      const row = logRow('large-native-crash-record');
      row.customDataTypeString = 'error';
      row.dataString = `df_rum_harmonyos_error,sdk_data_id=${row.uuid} error="${'m'.repeat(600 * 1024)}" 100`;

      const write = await store.execute({ command: 'writeSyncData', records: [row],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      const rows = (await store.execute({ command: 'querySyncData', limit: 1 })).rows || [];

      expect(write.write?.result.inserted).assertEqual(1);
      expect(write.write?.result.dropped).assertEqual(0);
      expect(rows.length).assertEqual(1);
      expect(rows[0].dataString.length).assertEqual(row.dataString.length);
    });

    it('returnsSingleRecordBeyondTransportTargetForUpload', 0, async () => {
      const store = new FTCacheFileStore(context, cacheSettings('file', 3 * 1024 * 1024), SQLITE_SUCCESS);
      const row = logRow('large-upload-record');
      row.dataType = DataType.RUM_APP;
      row.customDataTypeString = 'error';
      row.dataString = `df_rum_harmonyos_error,sdk_data_id=${row.uuid} error="${
        'm'.repeat(DATA_UPLOAD_TRANSPORT_TARGET_BYTES + 32 * 1024)}" 100`;
      const write = await store.execute({ command: 'writeSyncData', records: [row],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      const page = await store.execute({ command: 'queryUploadData', dataTypes: ['rum_app'], limit: 10,
        maxBytes: DATA_UPLOAD_TRANSPORT_TARGET_BYTES });

      expect(write.write?.result.inserted).assertEqual(1);
      expect(page.uploadRows?.length).assertEqual(1);
      expect((page.uploadRows || [])[0].uuid).assertEqual(row.uuid);
      expect((page.byteCount || 0) > DATA_UPLOAD_TRANSPORT_TARGET_BYTES).assertTrue();
      expect(page.byteLimitReached).assertTrue();
      expect(store.list('quarantine').length).assertEqual(0);
    });

    it('restoresPreviouslyQuarantinedOversizeRecordForUpload', 0, async () => {
      const store = new FTCacheFileStore(context, cacheSettings('file', 3 * 1024 * 1024), SQLITE_SUCCESS);
      const row = logRow('previously-quarantined-record');
      row.dataType = DataType.RUM_APP;
      row.customDataTypeString = 'error';
      row.dataString = `df_rum_harmonyos_error,sdk_data_id=${row.uuid} error="${
        'm'.repeat(DATA_UPLOAD_TRANSPORT_TARGET_BYTES + 32 * 1024)}" 100`;
      await store.execute({ command: 'writeSyncData', records: [row],
        options: { applyCachePolicy: false, reInsert: false, forceTransaction: true, updateOrInsertByUuid: true } });
      fs.renameSync(store.path('sync', row.uuid), `${store.root}/quarantine/oversize-100-${row.uuid}.json`);

      const recovered = new FTCacheFileStore(context, cacheSettings('file', 3 * 1024 * 1024), SQLITE_SUCCESS);
      await recovered.recover();
      const page = await recovered.execute({ command: 'queryUploadData', dataTypes: ['rum_app'], limit: 10,
        maxBytes: DATA_UPLOAD_TRANSPORT_TARGET_BYTES });

      expect(page.uploadRows?.length).assertEqual(1);
      expect((page.uploadRows || [])[0].uuid).assertEqual(row.uuid);
      expect(recovered.list('quarantine').length).assertEqual(0);
    });

    it('acknowledgesClosedViewsThroughTheFileStoreCommandRouter', 0, async () => {
      const store = new FTCacheFileStore(context, cacheSettings('file', 1024 * 1024), SQLITE_SUCCESS);
      const view = rumView('file-store-acknowledged-view');
      await store.execute({ command: 'upsertRumView', view });
      const stale = JSON.parse(JSON.stringify(view)) as ViewBeanJSON;
      await store.execute({ command: 'closeRumView', viewId: view.id, now: 100 });

      expect((await store.execute({ command: 'acknowledgeView', view: stale })).value).assertFalse();
      const current = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(current !== null && current !== undefined).assertTrue();
      expect((await store.execute({ command: 'acknowledgeView', view: current! })).value).assertTrue();
      expect((await store.execute({ command: 'queryRumViewById', viewId: view.id })).view).assertNull();
    });
  });
}
