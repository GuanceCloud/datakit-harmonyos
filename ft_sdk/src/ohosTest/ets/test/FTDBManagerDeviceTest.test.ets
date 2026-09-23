import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import relationalStore from '@ohos.data.relationalStore';
import { FTDBManager } from '../../../main/ets/components/db/FTDBManager';
import {
  FTDBTaskPoolExecutor,
  FTDBTaskPoolCachePolicySnapshot,
  FTDBTaskPoolWriteOptions,
  FTDBTaskPoolPendingRumResourceDTO,
  FTDBTaskPoolRumCounterDeltaDTO
} from '../../../main/ets/components/db/FTDBTaskPoolExecutor';
import { ViewBean } from '../../../main/ets/components/db/bean/ViewBean';
import { ActionBean } from '../../../main/ets/components/db/bean/ActionBean';
import { DatabaseHelper } from '../../../main/ets/components/db/base/DatabaseHelper';
import { DataBaseCallBack } from '../../../main/ets/components/db/base/DataBaseCallBack';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { CacheDiscard, DataType } from '../../../main/ets/components/enum/Enums';
import * as FTSQL from '../../../main/ets/components/db/FTSQL';
import {
  SDKRumResourceContextDTO,
  SDKRumResourceNetworkSnapshotDTO,
  SDKStringRecord
} from '../../../main/ets/components/thread/SDKWorkerProtocol';
import { DBAssert } from './helpers/DBAssert';

const TEST_NOW_NS = 1700000000000;

function createLogSyncData(label: string, time: number = TEST_NOW_NS): SyncData {
  const syncData = new SyncData(DataType.LOG);
  syncData.setTime(time);
  syncData.setDataString(
    `df_rum_harmonyos_log,sdk_data_id=${syncData.getUuid()},service=device_db_test message="${label}" ${time}`
  );
  return syncData;
}

function createRumSyncData(label: string, time: number = TEST_NOW_NS): SyncData {
  const syncData = new SyncData(DataType.RUM_APP);
  syncData.setTime(time);
  syncData.setDataString(
    `action,action_id=${label},sdk_data_id=${syncData.getUuid()} action_name="${label}" ${time}`
  );
  return syncData;
}

class SchemaProbeCallback implements DataBaseCallBack {
  public hasViewMigrationColumns: boolean = false;
  public hasSyncDataFlatTable: boolean = false;
  public hasPendingResourceNetworkSnapshotColumn: boolean = false;

  async run(rdbStore: relationalStore.RdbStore): Promise<void> {
    const viewResult = await rdbStore.querySql(
      `SELECT ${FTSQL.RUM_DATA_UPLOAD_TIME}, ${FTSQL.RUM_DATA_UPDATE_TIME}, ${FTSQL.RUM_VIEW_UPDATE_TIME} ` +
      `FROM ${FTSQL.FT_TABLE_VIEW} LIMIT 1`
    );
    this.hasViewMigrationColumns = true;
    viewResult.close();

    const syncResult = await rdbStore.querySql(
      `SELECT COUNT(*) as count FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} LIMIT 1`
    );
    this.hasSyncDataFlatTable = syncResult.goToFirstRow();
    syncResult.close();

    const pendingResourceResult = await rdbStore.querySql(
      `SELECT ${FTSQL.PENDING_RESOURCE_COLUMN_NETWORK_SNAPSHOT} ` +
      `FROM ${FTSQL.FT_TABLE_PENDING_RUM_RESOURCE} LIMIT 1`
    );
    this.hasPendingResourceNetworkSnapshotColumn = true;
    pendingResourceResult.close();
  }
}

class PendingResourceContextFixture implements SDKRumResourceContextDTO {
  dynamicTags?: SDKStringRecord;
  networkSnapshot: SDKRumResourceNetworkSnapshotDTO = {
    available: true,
    validated: true,
    downlinkKbps: 1200,
    uplinkKbps: 600,
    signalStrength: 3
  };
  sessionId: string = 'pending-resource-session';
  viewId: string = '';
  viewName: string = '';
  viewReferrer: string = '';
  actionId: string;
  actionName: string = 'pending resource action';
  rumAppId?: string = 'pending-resource-rum';

  constructor(actionId: string) {
    this.actionId = actionId;
    const tags: SDKStringRecord = {};
    tags['network_type'] = 'wifi';
    this.dynamicTags = tags;
  }
}

class PendingRumResourceFixture implements FTDBTaskPoolPendingRumResourceDTO {
  resourceId: string;
  startTime: number = TEST_NOW_NS;
  context: SDKRumResourceContextDTO;
  draftUuid: string;
  errorDraftUuid: string;

  constructor(resourceId: string, actionId: string) {
    this.resourceId = resourceId;
    this.context = new PendingResourceContextFixture(actionId);
    this.draftUuid = `${resourceId}-draft`;
    this.errorDraftUuid = `${resourceId}-error-draft`;
  }
}

export default function ftDBManagerDeviceTest() {
  describe('FTDBManagerDeviceTest', () => {
    let dbManager: FTDBManager;

    beforeEach(async () => {
      dbManager = FTDBManager.getInstance(await DBAssert.getAppContext());
      await dbManager.init();
      await dbManager.resetDatabase();
    });

    afterEach(async () => {
      await dbManager.delete();
    });

    it('staleOpenAckKeepsClosedView', 0, async () => {
      const context = await DBAssert.getAppContext();
      const open = new ViewBean('delayed-open-view', 'delayed-open-view', TEST_NOW_NS);
      await FTDBTaskPoolExecutor.upsertRumView(context, open);
      const closed = ViewBean.fromJSON(open.toJSON());
      // Deliberately share the millisecond timestamp and counter: the state
      // check must still reject the earlier open snapshot's completion.
      closed.setIsClose(true);
      await FTDBTaskPoolExecutor.updateRumView(context, closed);
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, open)).assertFalse();
      const retained = await FTDBTaskPoolExecutor.queryRumViewById(context, open.getId());
      expect(retained !== null).assertTrue();
      expect(retained!.getIsClose()).assertTrue();
      expect(retained!.getDataUploadTime()).assertEqual(0);
      expect((await FTDBTaskPoolExecutor.querySumView(context, 20))
        .some(view => view.getId() === open.getId())).assertTrue();
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, retained!)).assertTrue();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, open.getId())).assertNull();
    });

    it('acknowledgedClosedViewDoesNotReappearAfterRestartClosure', 0, async () => {
      const context = await DBAssert.getAppContext();
      const closed = new ViewBean('acknowledged-closed-view', 'acknowledged-closed-view', TEST_NOW_NS);
      closed.setIsClose(true);
      await FTDBTaskPoolExecutor.upsertRumView(context, closed);

      // This is the same acknowledgement performed after the View row reaches
      // the durable sync queue. A later SDK initialization closes all retained
      // aggregates, so an acknowledged closed View must already be gone.
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, closed)).assertTrue();
      await FTDBTaskPoolExecutor.closeAllActionAndView(context);
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, closed.getId())).assertNull();
      expect((await FTDBTaskPoolExecutor.querySumView(context, 20))
        .some(view => view.getId() === closed.getId())).assertFalse();
    });

    it('recoveredClosedViewCanBeRefreshedAfterItsFirstDurableSnapshot', 0, async () => {
      const context = await DBAssert.getAppContext();
      const view = new ViewBean('recovered-crash-view', 'recovered-crash-view', TEST_NOW_NS);
      view.setIsClose(true);
      await FTDBTaskPoolExecutor.upsertRumView(context, view);

      // The first predecessor-process View record is durable, but recovery
      // must retain its aggregate row until the historical Error is counted.
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, view, true)).assertTrue();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId()) !== null).assertTrue();
      const delta: FTDBTaskPoolRumCounterDeltaDTO = {
        viewId: view.getId(), actionId: '', viewActionDelta: 0, viewErrorDelta: 1,
        viewLongTaskDelta: 0, viewResourceDelta: 0, viewPendingDelta: 0,
        viewUpdateTimeDelta: 1, actionErrorDelta: 0, actionLongTaskDelta: 0,
        actionResourceDelta: 0, actionPendingDelta: 0
      };
      expect(await FTDBTaskPoolExecutor.applyRumCounterDeltas(context, [delta])).assertEqual(1);
      const refreshed = await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId());
      expect(refreshed !== null).assertTrue();
      expect(refreshed!.getErrorCount()).assertEqual(1);
      expect((await FTDBTaskPoolExecutor.querySumView(context, 20))
        .some(item => item.getId() === view.getId())).assertTrue();
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, refreshed!)).assertTrue();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId())).assertNull();
    });

    it('viewAckKeepsNewerAndUnrelatedData', 0, async () => {
      const context = await DBAssert.getAppContext();
      const old = new ViewBean('delayed-counter-view', 'delayed-counter-view', TEST_NOW_NS);
      old.setIsClose(true);
      await FTDBTaskPoolExecutor.upsertRumView(context, old);
      const newer = ViewBean.fromJSON(old.toJSON());
      newer.setResourceCount(1);
      // Counter-only DB updates need not bump the timestamp or version.
      await FTDBTaskPoolExecutor.updateRumView(context, newer);
      const other = new ViewBean('unserialized-closed-view', 'unserialized-closed-view', TEST_NOW_NS);
      other.setIsClose(true);
      await FTDBTaskPoolExecutor.upsertRumView(context, other);
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, old)).assertFalse();
      const retained = await FTDBTaskPoolExecutor.queryRumViewById(context, old.getId());
      expect(retained!.getResourceCount()).assertEqual(1);
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, retained!)).assertTrue();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, old.getId())).assertNull();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, other.getId()) !== null).assertTrue();
    });

    it('pendingClosedViewSurvivesUntilPersisted', 0, async () => {
      const context = await DBAssert.getAppContext();
      const view = new ViewBean('pending-closed-view', 'pending-closed-view', TEST_NOW_NS);
      view.setIsClose(true);
      view.setPendingResource(1);
      await FTDBTaskPoolExecutor.upsertRumView(context, view);
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, view)).assertTrue();
      await FTDBTaskPoolExecutor.forceClearRumPendingResource(context, 'view', view.getId());
      const finalViews = await FTDBTaskPoolExecutor.querySumView(context, 20);
      const finalView = finalViews.find(item => item.getId() === view.getId());
      expect(finalView !== undefined).assertTrue();
      expect(finalView!.getPendingResource()).assertEqual(0);
      expect(await FTDBTaskPoolExecutor.acknowledgeView(context, finalView!)).assertTrue();
      expect(await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId())).assertNull();
    });

    it('insertsActionAndOwningViewCountInOneTransaction', 0, async () => {
      const context = await DBAssert.getAppContext();
      const view = new ViewBean('atomic-action-view', 'atomic-action-view', TEST_NOW_NS);
      await FTDBTaskPoolExecutor.upsertRumView(context, view);
      const action = new ActionBean('atomic-action', 'atomic action', 'click', TEST_NOW_NS);
      action.setViewInfo(view.getViewName(), view.getId(), '');

      expect(await FTDBTaskPoolExecutor.insertRumAction(context, action)).assertTrue();
      const persistedView = await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId());
      expect(persistedView !== null).assertTrue();
      expect(persistedView!.getActionCount()).assertEqual(1);
      expect(persistedView!.getViewUpdateTime()).assertEqual(view.getViewUpdateTime() + 1);
      const persistedAction = await FTDBTaskPoolExecutor.getActionInfo(context, action.getId());
      expect(persistedAction !== null).assertTrue();
      expect(persistedAction!.startTime).assertEqual(TEST_NOW_NS);

      // A View-qualified Action cannot be accepted alone. This prevents a
      // restart/retry from creating the mismatch this transaction fixes.
      const unavailableViewAction = new ActionBean('missing-view-action', 'missing view', 'click', TEST_NOW_NS);
      unavailableViewAction.setViewInfo('missing', 'missing-view', '');
      expect(await FTDBTaskPoolExecutor.insertRumAction(context, unavailableViewAction)).assertFalse();
      expect(await FTDBTaskPoolExecutor.getActionInfo(context, unavailableViewAction.getId())).assertNull();
    });

    it('pendingResourceAssociationPersistsAndReferenceCountsAction', 0, async () => {
      const context = await DBAssert.getAppContext();
      const actionId = 'pending-resource-action';
      const action = new ActionBean(actionId, 'pending resource action', 'click', TEST_NOW_NS);
      await FTDBTaskPoolExecutor.insertRumAction(context, action);

      const createPendingResource = (resourceId: string): FTDBTaskPoolPendingRumResourceDTO =>
        new PendingRumResourceFixture(resourceId, actionId);

      expect(await FTDBTaskPoolExecutor.registerPendingRumResource(
        context, createPendingResource('pending-resource-one')
      )).assertTrue();
      expect(await FTDBTaskPoolExecutor.registerPendingRumResource(
        context, createPendingResource('pending-resource-two')
      )).assertTrue();

      // The relation is read from RDB, not a Resource object retained in memory.
      const restored = await FTDBTaskPoolExecutor.getPendingRumResource(context, 'pending-resource-one');
      expect(restored !== null).assertTrue();
      expect(restored!.context.actionId).assertEqual(actionId);
      expect(restored!.draftUuid).assertEqual('pending-resource-one-draft');
      expect(restored!.context.networkSnapshot?.available).assertTrue();
      expect(restored!.context.networkSnapshot?.validated).assertTrue();
      expect(restored!.context.networkSnapshot?.downlinkKbps).assertEqual(1200);
      expect(restored!.context.networkSnapshot?.uplinkKbps).assertEqual(600);
      expect(restored!.context.networkSnapshot?.signalStrength).assertEqual(3);

      const waitingClose = await FTDBTaskPoolExecutor.closeRumAction(context, actionId, 100);
      expect(waitingClose.wasClosed).assertFalse();
      expect(waitingClose.hadPendingResource).assertTrue();

      expect(await FTDBTaskPoolExecutor.completePendingRumResources(
        context, ['pending-resource-one']
      )).assertEqual(1);
      const stillPending = await FTDBTaskPoolExecutor.queryPendingRumActions(context, 10);
      expect(stillPending.length).assertEqual(1);
      expect(stillPending[0].getPendingResource()).assertEqual(1);

      expect(await FTDBTaskPoolExecutor.completePendingRumResources(
        context, ['pending-resource-two']
      )).assertEqual(1);
      const finalClose = await FTDBTaskPoolExecutor.closeRumAction(context, actionId, 100);
      expect(finalClose.wasClosed).assertTrue();
      expect(finalClose.hadPendingResource).assertFalse();
      expect(await FTDBTaskPoolExecutor.getPendingRumResource(context, 'pending-resource-two')).assertNull();
    });

    it('dbShouldCrudSingleRecord', 0, async () => {
      const syncData = createLogSyncData('single-insert');

      const inserted = await dbManager.insertFtOperation(syncData);
      const countAfterInsert = await DBAssert.querySyncCount([DataType.LOG]);
      const queried = await DBAssert.querySyncData([DataType.LOG], 10);
      await DBAssert.deleteSyncData(queried);
      const countAfterDelete = await DBAssert.querySyncCount([DataType.LOG]);

      expect(inserted).assertTrue();
      expect(countAfterInsert).assertEqual(1);
      expect(queried.length).assertEqual(1);
      expect(queried[0].getDataString().includes('single-insert')).assertTrue();
      expect(countAfterDelete).assertEqual(0);
    });

    it('dbShouldBatchDeleteRecords', 0, async () => {
      const first = createLogSyncData('batch-1', TEST_NOW_NS + 1);
      const second = createLogSyncData('batch-2', TEST_NOW_NS + 2);
      const third = createLogSyncData('batch-3', TEST_NOW_NS + 3);

      const inserted = await DBAssert.insertSyncData([first, second, third]);
      const queried = await DBAssert.querySyncData([DataType.LOG], 10);
      await DBAssert.deleteSyncData(queried);
      const countAfterDelete = await DBAssert.querySyncCount([DataType.LOG]);

      expect(inserted).assertTrue();
      expect(queried.length).assertEqual(3);
      expect(countAfterDelete).assertEqual(0);
    });

    it('deleteOldestDataRemoveOldestRowsOnly', 0, async () => {
      await DBAssert.insertSyncData([
        createLogSyncData('oldest', TEST_NOW_NS + 1),
        createLogSyncData('middle', TEST_NOW_NS + 2),
        createLogSyncData('newest', TEST_NOW_NS + 3)
      ]);

      await DBAssert.deleteOldestSyncData([DataType.LOG], 2);
      const remaining = await DBAssert.querySyncData([DataType.LOG], 10);

      expect(remaining.length).assertEqual(1);
      expect(remaining[0].getDataString().includes('newest')).assertTrue();
    });

    it('cacheSizeDiscardOldestDeletesLogBeforeRum', 0, async () => {
      const context = await DBAssert.getAppContext();
      await DBAssert.insertSyncData([
        createLogSyncData('evict-log-first', TEST_NOW_NS + 1),
        createRumSyncData('preserve-rum', TEST_NOW_NS + 2)
      ]);
      // Supply the same full-cache signal used by the shadow path. The test
      // exercises SQLite cache-policy eviction without depending on a large
      // physical database allocation.
      const policy: FTDBTaskPoolCachePolicySnapshot = {
        enableLimitWithCacheSize: true,
        cacheLimitSize: 1,
        cacheDiscard: CacheDiscard.DISCARD_OLDEST,
        shadowMirrorBytes: 1,
        logLimitCount: 0,
        rumLimitCount: 0,
        logCount: 1,
        rumCount: 1,
        logDiscardStrategy: 'discard',
        rumDiscardStrategy: 'discard'
      };
      const options: FTDBTaskPoolWriteOptions = {
        applyCachePolicy: true,
        reInsert: false,
        forceTransaction: true,
        updateOrInsertByUuid: false
      };

      const response = await FTDBTaskPoolExecutor.writeSyncData(
        context,
        'device-cache-limit-log-priority',
        [createRumSyncData('new-rum', TEST_NOW_NS + 3)],
        options,
        (): FTDBTaskPoolCachePolicySnapshot => policy,
        (_response): void => {}
      );

      expect(response.result.success).assertTrue();
      expect(response.result.deletedOld).assertEqual(1);
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(2);
    });

    it('migrationSchemaShouldExist', 0, async () => {
      const callback = new SchemaProbeCallback();

      const store = await DatabaseHelper.getInstance(await DBAssert.getAppContext()).initDatabase();
      await callback.run(store);

      expect(callback.hasViewMigrationColumns).assertTrue();
      expect(callback.hasSyncDataFlatTable).assertTrue();
      expect(callback.hasPendingResourceNetworkSnapshotColumn).assertTrue();
    });

    it('errorSampledShouldMigrateExpire', 0, async () => {
      const oldSampled = createRumSyncData('old-sampled', TEST_NOW_NS - 120000000000);
      oldSampled.setCustomDataTypeString('rum_app_error_sampled');
      const expiredSampled = createRumSyncData('expired-sampled', TEST_NOW_NS - 90000000000);
      expiredSampled.setCustomDataTypeString('rum_app_error_sampled');
      const freshSampled = createRumSyncData('fresh-sampled', TEST_NOW_NS);
      freshSampled.setCustomDataTypeString('rum_app_error_sampled');

      await DBAssert.insertSyncData([oldSampled, expiredSampled, freshSampled], true);
      const updatedCount = await dbManager.updateDataType('rum_app_error_sampled', TEST_NOW_NS - 100000000000);
      const migratedRumCount = await DBAssert.querySyncCount([DataType.RUM_APP]);
      const deletedCount = await dbManager.deleteExpireCache('rum_app_error_sampled', TEST_NOW_NS, 60000000000);
      const remainingSampledCount = await DBAssert.queryRawSyncCount(['rum_app_error_sampled']);

      expect(updatedCount).assertEqual(1);
      expect(migratedRumCount).assertEqual(1);
      expect(deletedCount).assertEqual(1);
      expect(remainingSampledCount).assertEqual(1);
    });

    it('resetDbShouldKeepTablesUsable', 0, async () => {
      await DBAssert.insertSyncData([
        createLogSyncData('cleanup-log', TEST_NOW_NS + 1),
        createRumSyncData('cleanup-rum', TEST_NOW_NS + 2)
      ]);

      await dbManager.delete();
      const countAfterDelete = await DBAssert.querySyncCount([]);
      await dbManager.resetDatabase();
      const insertedAfterReset = await dbManager.insertFtOperation(createLogSyncData('after-reset', TEST_NOW_NS + 3));
      const countAfterResetInsert = await DBAssert.querySyncCount([DataType.LOG]);

      expect(countAfterDelete).assertEqual(0);
      expect(insertedAfterReset).assertTrue();
      expect(countAfterResetInsert).assertEqual(1);
    });
  });
}
