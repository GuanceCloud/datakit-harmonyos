import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@kit.AbilityKit';
import { FTDBManager } from '../../../main/ets/components/db/FTDBManager';
import { DataBaseCallBack } from '../../../main/ets/components/db/base/DataBaseCallBack';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { DataType } from '../../../main/ets/components/enum/Enums';
import * as FTSQL from '../../../main/ets/components/db/FTSQL';

const TEST_NOW_NS = 1700000000000;

function getAppContext(): Context {
  return AbilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
}

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

class CountTypeCallback implements DataBaseCallBack {
  public count: number = 0;
  private readonly typeValue: string;

  constructor(typeValue: string) {
    this.typeValue = typeValue;
  }

  async run(rdbStore: relationalStore.RdbStore): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.typeValue);
    const resultSet = await rdbStore.query(predicates, ['count(*) as count']);
    if (resultSet.goToFirstRow()) {
      this.count = resultSet.getLong(0);
    }
    resultSet.close();
  }
}

class SchemaProbeCallback implements DataBaseCallBack {
  public hasViewMigrationColumns: boolean = false;
  public hasSyncDataFlatTable: boolean = false;

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
  }
}

export default function ftDBManagerDeviceTest() {
  describe('FTDBManagerDeviceTest', () => {
    let dbManager: FTDBManager;

    beforeEach(async () => {
      dbManager = FTDBManager.getInstance(getAppContext());
      await dbManager.init();
      await dbManager.resetDatabase();
    });

    afterEach(async () => {
      await dbManager.delete();
    });

    it('realDatabaseShouldInsertQueryAndDeleteSingleSyncRecord', 0, async () => {
      const syncData = createLogSyncData('single-insert');

      const inserted = await dbManager.insertFtOperation(syncData);
      const countAfterInsert = await dbManager.queryTotalCount([DataType.LOG]);
      const queried = await dbManager.queryFtOperation([DataType.LOG], 10);
      await dbManager.deleteFtOperation(queried);
      const countAfterDelete = await dbManager.queryTotalCount([DataType.LOG]);

      expect(inserted).assertTrue();
      expect(countAfterInsert).assertEqual(1);
      expect(queried.length).assertEqual(1);
      expect(queried[0].getDataString().includes('single-insert')).assertTrue();
      expect(countAfterDelete).assertEqual(0);
    });

    it('realDatabaseShouldBatchInsertAndDeleteQueriedRecords', 0, async () => {
      const first = createLogSyncData('batch-1', TEST_NOW_NS + 1);
      const second = createLogSyncData('batch-2', TEST_NOW_NS + 2);
      const third = createLogSyncData('batch-3', TEST_NOW_NS + 3);

      const inserted = await dbManager.insertFtOptList([first, second, third]);
      const queried = await dbManager.queryFtOperation([DataType.LOG], 10);
      await dbManager.deleteFtOperation(queried);
      const countAfterDelete = await dbManager.queryTotalCount([DataType.LOG]);

      expect(inserted).assertTrue();
      expect(queried.length).assertEqual(3);
      expect(countAfterDelete).assertEqual(0);
    });

    it('deleteOldestDataShouldRemoveOldestRowsOnly', 0, async () => {
      await dbManager.insertFtOptList([
        createLogSyncData('oldest', TEST_NOW_NS + 1),
        createLogSyncData('middle', TEST_NOW_NS + 2),
        createLogSyncData('newest', TEST_NOW_NS + 3)
      ]);

      await dbManager.deleteOldestData(DataType.LOG, 2);
      const remaining = await dbManager.queryFtOperation([DataType.LOG], 10);

      expect(remaining.length).assertEqual(1);
      expect(remaining[0].getDataString().includes('newest')).assertTrue();
    });

    it('migrationSchemaShouldExistAfterRealDatabaseInitialization', 0, async () => {
      const callback = new SchemaProbeCallback();

      await dbManager.executeWithDB(false, callback);

      expect(callback.hasViewMigrationColumns).assertTrue();
      expect(callback.hasSyncDataFlatTable).assertTrue();
    });

    it('errorSampledRecordsShouldMigrateAndExpireThroughRealDatabase', 0, async () => {
      const oldSampled = createRumSyncData('old-sampled', TEST_NOW_NS - 120000000000);
      oldSampled.setCustomDataTypeString('rum_app_error_sampled');
      const expiredSampled = createRumSyncData('expired-sampled', TEST_NOW_NS - 90000000000);
      expiredSampled.setCustomDataTypeString('rum_app_error_sampled');
      const freshSampled = createRumSyncData('fresh-sampled', TEST_NOW_NS);
      freshSampled.setCustomDataTypeString('rum_app_error_sampled');

      await dbManager.insertFtOptList([oldSampled, expiredSampled, freshSampled], true);
      const updatedCount = await dbManager.updateDataType('rum_app_error_sampled', TEST_NOW_NS - 100000000000);
      const migratedRumCount = await dbManager.queryTotalCount([DataType.RUM_APP]);
      const deletedCount = await dbManager.deleteExpireCache('rum_app_error_sampled', TEST_NOW_NS, 60000000000);
      const callback = new CountTypeCallback('rum_app_error_sampled');
      await dbManager.executeWithDB(false, callback);

      expect(updatedCount).assertEqual(1);
      expect(migratedRumCount).assertEqual(1);
      expect(deletedCount).assertEqual(1);
      expect(callback.count).assertEqual(1);
    });

    it('deleteShouldCleanAllSyncRowsAndResetDatabaseShouldKeepTablesUsable', 0, async () => {
      await dbManager.insertFtOptList([
        createLogSyncData('cleanup-log', TEST_NOW_NS + 1),
        createRumSyncData('cleanup-rum', TEST_NOW_NS + 2)
      ]);

      await dbManager.delete();
      const countAfterDelete = await dbManager.queryTotalCount([]);
      await dbManager.resetDatabase();
      const insertedAfterReset = await dbManager.insertFtOperation(createLogSyncData('after-reset', TEST_NOW_NS + 3));
      const countAfterResetInsert = await dbManager.queryTotalCount([DataType.LOG]);

      expect(countAfterDelete).assertEqual(0);
      expect(insertedAfterReset).assertTrue();
      expect(countAfterResetInsert).assertEqual(1);
    });
  });
}
