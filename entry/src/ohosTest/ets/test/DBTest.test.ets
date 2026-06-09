import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import relationalStore from '@ohos.data.relationalStore';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { DataBaseCallBack } from '@guancecloud/ft_sdk/src/main/ets/components/db/base/DataBaseCallBack';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import * as FTSQL from '@guancecloud/ft_sdk/src/main/ets/components/db/FTSQL';
import { EntryDBAssert } from './helpers/EntryDBAssert';

const TEST_NOW_NS = 1700000000000;

function createLogSyncData(label: string, time: number = TEST_NOW_NS): SyncData {
  const syncData = new SyncData(DataType.LOG);
  syncData.setTime(time);
  syncData.setDataString(
    `df_rum_harmonyos_log,sdk_data_id=${syncData.getUuid()},service=entry_db_test message="${label}" ${time}`
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

export default function dbTest() {
  describe('EntrySDKDBTest', () => {
    let dbManager: FTDBManager;

    beforeEach(async () => {
      dbManager = await EntryDBAssert.getManager();
      await dbManager.resetDatabase();
    });

    afterEach(async () => {
      await dbManager.delete();
    });

    it('dbShouldCrudSingleRecord', 0, async () => {
      const syncData = createLogSyncData('entry-single-insert');

      const inserted = await dbManager.insertFtOperation(syncData);
      const countAfterInsert = await dbManager.queryTotalCount([DataType.LOG]);
      const queried = await dbManager.queryFtOperation([DataType.LOG], 10);
      await dbManager.deleteFtOperation(queried);
      const countAfterDelete = await dbManager.queryTotalCount([DataType.LOG]);

      expect(inserted).assertTrue();
      expect(countAfterInsert).assertEqual(1);
      expect(queried.length).assertEqual(1);
      expect(queried[0].getDataString().includes('entry-single-insert')).assertTrue();
      expect(countAfterDelete).assertEqual(0);
    });

    it('dbShouldBatchDeleteRecords', 0, async () => {
      const first = createLogSyncData('entry-batch-1', TEST_NOW_NS + 1);
      const second = createLogSyncData('entry-batch-2', TEST_NOW_NS + 2);
      const third = createRumSyncData('entry-rum-1', TEST_NOW_NS + 3);

      const inserted = await dbManager.insertFtOptList([first, second, third]);
      const queried = await dbManager.queryFtOperation([], 10);
      await dbManager.deleteFtOperation(queried);
      const countAfterDelete = await dbManager.queryTotalCount([]);

      expect(inserted).assertTrue();
      expect(queried.length).assertEqual(3);
      expect(countAfterDelete).assertEqual(0);
    });

    it('sdkDatabaseShouldDeleteOldestDataOnly', 0, async () => {
      await dbManager.insertFtOptList([
        createLogSyncData('entry-oldest', TEST_NOW_NS + 1),
        createLogSyncData('entry-middle', TEST_NOW_NS + 2),
        createLogSyncData('entry-newest', TEST_NOW_NS + 3)
      ]);

      await dbManager.deleteOldestData(DataType.LOG, 2);
      const remaining = await dbManager.queryFtOperation([DataType.LOG], 10);

      expect(remaining.length).assertEqual(1);
      expect(remaining[0].getDataString().includes('entry-newest')).assertTrue();
    });

    it('dbSchemaShouldExist', 0, async () => {
      const callback = new SchemaProbeCallback();

      await dbManager.executeWithDB(false, callback);

      expect(callback.hasViewMigrationColumns).assertTrue();
      expect(callback.hasSyncDataFlatTable).assertTrue();
    });
  });
}
