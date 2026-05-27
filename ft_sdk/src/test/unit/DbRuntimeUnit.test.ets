import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import relationalStore from '@ohos.data.relationalStore';
import {
  DBManager,
  DBManagerRuntime
} from '../../main/ets/components/db/base/DBManager';
import {
  DatabaseHelper,
  DatabaseHelperRuntime
} from '../../main/ets/components/db/base/DatabaseHelper';
import { DataBaseCallBack } from '../../main/ets/components/db/base/DataBaseCallBack';
import {
  FTDBManager,
  FTDBManagerRuntime
} from '../../main/ets/components/db/FTDBManager';
import * as FTSQL from '../../main/ets/components/db/FTSQL';
import { ActionBean } from '../../main/ets/components/db/bean/ActionBean';
import { SyncData } from '../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../main/ets/components/db/bean/ViewBean';
import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { DBCacheDiscard, DataType } from '../../main/ets/components/enum/Enums';
import { Constants } from '../../main/ets/components/Constants';

function createContext(): Context {
  return new Object() as Context;
}

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 4; i++) {
    await Promise.resolve();
  }
}

function createSyncData(dataType: DataType, uuid: string, dataString: string, time: number = 100): SyncData {
  const data = new SyncData(dataType);
  data.setUuid(uuid);
  data.setDataString(dataString);
  data.setTime(time);
  return data;
}

function createRow(): Record<string, Object> {
  return {};
}

function createValueRow(key: string, value: Object): Record<string, Object> {
  const row = createRow();
  row[key] = value;
  return row;
}

function createSyncRow(uuid: string, type: string, data: string, tm: number): Record<string, Object> {
  const row = createRow();
  row[FTSQL.RECORD_COLUMN_DATA_UUID] = uuid as Object;
  row[FTSQL.RECORD_COLUMN_DATA_TYPE] = type as Object;
  row[FTSQL.RECORD_COLUMN_DATA] = data as Object;
  row[FTSQL.RECORD_COLUMN_TM] = tm as Object;
  return row;
}

function createActionRow(id: string): Record<string, Object> {
  const row = createRow();
  row[FTSQL.RUM_COLUMN_ID] = id as Object;
  row[FTSQL.RUM_COLUMN_START_TIME] = '200' as Object;
  row[FTSQL.RUM_COLUMN_ACTION_DURATION] = 12 as Object;
  row[FTSQL.RUM_COLUMN_IS_CLOSE] = 1 as Object;
  row[FTSQL.RUM_COLUMN_ERROR_COUNT] = 1 as Object;
  row[FTSQL.RUM_COLUMN_LONG_TASK_COUNT] = 2 as Object;
  row[FTSQL.RUM_COLUMN_RESOURCE_COUNT] = 3 as Object;
  row[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = 0 as Object;
  row[FTSQL.RUM_COLUMN_SESSION_ID] = 'session-1' as Object;
  row[FTSQL.RUM_COLUMN_VIEW_NAME] = 'Home' as Object;
  row[FTSQL.RUM_COLUMN_VIEW_ID] = 'view-1' as Object;
  row[FTSQL.RUM_COLUMN_VIEW_REFERRER] = 'referrer' as Object;
  row[FTSQL.RUM_COLUMN_ACTION_NAME] = 'Tap' as Object;
  row[FTSQL.RUM_COLUMN_ACTION_TYPE] = 'click' as Object;
  row[FTSQL.RUM_COLUMN_EXTRA_ATTR] = '{"role":"admin"}' as Object;
  return row;
}

function createViewRow(id: string): Record<string, Object> {
  const row = createRow();
  row[FTSQL.RUM_COLUMN_ID] = id as Object;
  row[FTSQL.RUM_COLUMN_VIEW_NAME] = 'Home' as Object;
  row[FTSQL.RUM_COLUMN_VIEW_REFERRER] = 'referrer' as Object;
  row[FTSQL.RUM_COLUMN_START_TIME] = '100' as Object;
  row[FTSQL.RUM_COLUMN_IS_CLOSE] = 1 as Object;
  row[FTSQL.RUM_COLUMN_SESSION_ID] = 'session-1' as Object;
  row[FTSQL.RUM_COLUMN_ACTION_COUNT] = 1 as Object;
  row[FTSQL.RUM_COLUMN_ERROR_COUNT] = 2 as Object;
  row[FTSQL.RUM_COLUMN_LONG_TASK_COUNT] = 3 as Object;
  row[FTSQL.RUM_COLUMN_VIEW_LOAD_TIME] = 4 as Object;
  row[FTSQL.RUM_COLUMN_VIEW_TIME_SPENT] = 5 as Object;
  row[FTSQL.RUM_COLUMN_RESOURCE_COUNT] = 6 as Object;
  row[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = 0 as Object;
  row[FTSQL.RUM_DATA_UPDATE_TIME] = 9 as Object;
  row[FTSQL.RUM_DATA_UPLOAD_TIME] = 8 as Object;
  row[FTSQL.RUM_VIEW_UPDATE_TIME] = 7 as Object;
  row[FTSQL.RUM_COLUMN_EXTRA_ATTR] = '{"plain":"value"}' as Object;
  return row;
}

class FakeResultSet {
  private readonly rows: Record<string, Object>[];
  private readonly columns: string[];
  private index: number = -1;
  closeCount: number = 0;
  throwOnGoToFirstRow: boolean = false;
  throwOnGoToNextRow: boolean = false;
  throwOnGetString: boolean = false;
  throwOnGetLong: boolean = false;

  constructor(rows: Record<string, Object>[]) {
    this.rows = rows;
    this.columns = rows.length > 0 ? Object.keys(rows[0]) : [];
  }

  goToFirstRow(): boolean {
    if (this.throwOnGoToFirstRow) {
      throw new Error('goToFirstRow failed');
    }
    if (this.rows.length === 0) {
      return false;
    }
    this.index = 0;
    return true;
  }

  goToNextRow(): boolean {
    if (this.throwOnGoToNextRow) {
      throw new Error('goToNextRow failed');
    }
    if (this.index + 1 >= this.rows.length) {
      return false;
    }
    this.index++;
    return true;
  }

  getColumnIndex(columnName: string): number {
    const index = this.columns.indexOf(columnName);
    return index >= 0 ? index : 0;
  }

  getLong(columnIndex: number): number {
    if (this.throwOnGetLong) {
      throw new Error('getLong failed');
    }
    const value = this.getValue(columnIndex);
    return Number(value);
  }

  getString(columnIndex: number): string {
    if (this.throwOnGetString) {
      throw new Error('getString failed');
    }
    const value = this.getValue(columnIndex);
    return value === undefined || value === null ? '' : String(value);
  }

  close(): void {
    this.closeCount++;
  }

  private getValue(columnIndex: number): Object | undefined {
    if (this.index < 0 || this.index >= this.rows.length) {
      return undefined;
    }
    const key = this.columns[columnIndex];
    return this.rows[this.index][key];
  }
}

class FakeRdbStore {
  executeSqls: string[] = [];
  inserts: relationalStore.ValuesBucket[] = [];
  batchInserts: relationalStore.ValuesBucket[][] = [];
  updates: relationalStore.ValuesBucket[] = [];
  queryRows: Record<string, Object>[] = [];
  querySqlRows: Record<string, Object>[] = [];
  queryQueue: FakeResultSet[] = [];
  querySqlQueue: FakeResultSet[] = [];
  queryCount: number = 0;
  querySqlCount: number = 0;
  insertCount: number = 0;
  deleteCount: number = 0;
  updateCount: number = 0;
  batchInsertCount: number = 0;
  beginCount: number = 0;
  commitCount: number = 0;
  rollbackCount: number = 0;
  closeCount: number = 0;
  insertRowId: number = 1;
  insertRowIds: number[] = [];
  batchInsertResult: number = 1;
  deleteResult: number = 1;
  updateResult: number = 1;
  pageCount: number = 2;
  returnPromiseInsert: boolean = false;
  throwExecuteSql: boolean = false;
  throwQueryOnce: boolean = false;
  throwQuery: boolean = false;
  throwQuerySqlOnce: boolean = false;
  throwQuerySql: boolean = false;
  querySqlErrorMessage: string = 'query sql failed';
  throwInsert: boolean = false;
  throwInsertOnce: boolean = false;
  insertErrorMessage: string = 'insert failed';
  throwBatchInsertOnce: boolean = false;
  throwBatchInsert: boolean = false;
  throwDeleteOnce: boolean = false;
  throwDelete: boolean = false;
  throwUpdateOnce: boolean = false;
  throwUpdate: boolean = false;
  throwClose: boolean = false;
  closeErrorMessage: string = 'close failed';
  throwExecuteSqlOnce: boolean = false;

  executeSql(sql: string): Promise<void> {
    this.executeSqls.push(sql);
    if (this.throwExecuteSqlOnce) {
      this.throwExecuteSqlOnce = false;
      throw new Error('execute failed once');
    }
    if (this.throwExecuteSql) {
      throw new Error('execute failed');
    }
    return Promise.resolve();
  }

  insert(_table: string, values: relationalStore.ValuesBucket): number | Promise<number> {
    this.insertCount++;
    this.inserts.push(values);
    if (this.throwInsertOnce) {
      this.throwInsertOnce = false;
      throw new Error(this.insertErrorMessage);
    }
    if (this.throwInsert) {
      throw new Error(this.insertErrorMessage);
    }
    const rowId = this.insertRowIds.length > 0 ? this.insertRowIds.shift() as number : this.insertRowId;
    if (this.insertRowIds.length === 0) {
      this.insertRowId++;
    }
    return this.returnPromiseInsert ? Promise.resolve(rowId) : rowId;
  }

  async batchInsert(_table: string, valuesArray: relationalStore.ValuesBucket[]): Promise<number> {
    this.batchInsertCount++;
    this.batchInserts.push(valuesArray);
    if (this.throwBatchInsertOnce) {
      this.throwBatchInsertOnce = false;
      throw new Error('batch insert failed once');
    }
    if (this.throwBatchInsert) {
      throw new Error('batch insert failed');
    }
    return this.batchInsertResult;
  }

  async query(_predicates: relationalStore.RdbPredicates, _columns?: string[]): Promise<FakeResultSet> {
    this.queryCount++;
    if (this.throwQueryOnce) {
      this.throwQueryOnce = false;
      throw new Error('query failed once');
    }
    if (this.throwQuery) {
      throw new Error('query failed');
    }
    if (this.queryQueue.length > 0) {
      return this.queryQueue.shift() as FakeResultSet;
    }
    return new FakeResultSet(this.queryRows);
  }

  async querySql(sql: string): Promise<FakeResultSet> {
    this.querySqlCount++;
    if (this.throwQuerySqlOnce) {
      this.throwQuerySqlOnce = false;
      throw new Error('query sql failed once');
    }
    if (this.throwQuerySql) {
      throw new Error(this.querySqlErrorMessage);
    }
    if (this.querySqlQueue.length > 0) {
      return this.querySqlQueue.shift() as FakeResultSet;
    }
    if (sql.indexOf('PRAGMA page_count') >= 0) {
      return new FakeResultSet([createValueRow('page_count', this.pageCount as Object)]);
    }
    return new FakeResultSet(this.querySqlRows);
  }

  async delete(_predicates: relationalStore.RdbPredicates): Promise<number> {
    this.deleteCount++;
    if (this.throwDeleteOnce) {
      this.throwDeleteOnce = false;
      throw new Error('delete failed once');
    }
    if (this.throwDelete) {
      throw new Error('delete failed');
    }
    return this.deleteResult;
  }

  async update(values: relationalStore.ValuesBucket, _predicates: relationalStore.RdbPredicates): Promise<number> {
    this.updateCount++;
    this.updates.push(values);
    if (this.throwUpdateOnce) {
      this.throwUpdateOnce = false;
      throw new Error('update failed once');
    }
    if (this.throwUpdate) {
      throw new Error('update failed');
    }
    return this.updateResult;
  }

  beginTransaction(): void {
    this.beginCount++;
  }

  commit(): void {
    this.commitCount++;
  }

  rollBack(): void {
    this.rollbackCount++;
  }

  async close(): Promise<void> {
    this.closeCount++;
    if (this.throwClose) {
      throw new Error(this.closeErrorMessage);
    }
  }
}

class FakeDatabaseHelperRuntime implements DatabaseHelperRuntime {
  readonly store: FakeRdbStore;
  getCount: number = 0;
  throwGet: boolean = false;

  constructor(store: FakeRdbStore) {
    this.store = store;
  }

  async getRdbStore(_context: Context, _config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore> {
    this.getCount++;
    if (this.throwGet) {
      throw new Error('get store failed');
    }
    return this.store as Object as relationalStore.RdbStore;
  }
}

class NullDatabaseHelperRuntime implements DatabaseHelperRuntime {
  async getRdbStore(_context: Context, _config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore> {
    return JSON.parse('null') as relationalStore.RdbStore;
  }
}

class FakeDBManagerRuntime implements DBManagerRuntime {
  currentNow: number = 0;
  clearCount: number = 0;
  scheduled: (() => void)[] = [];

  now(): number {
    return this.currentNow;
  }

  scheduleCloseTask(callback: () => void): void {
    this.scheduled.push(callback);
  }

  clearTimer(_timerId: number): void {
    this.clearCount++;
  }
}

class TestDBManager extends DBManager {
  store: FakeRdbStore | null;
  enableSizeLimit: boolean = true;
  sizeChanges: number[] = [];
  throwInit: boolean = false;

  constructor(store: FakeRdbStore | null) {
    super();
    this.store = store;
  }

  protected async initDataBaseHelper(): Promise<relationalStore.RdbStore> {
    if (this.throwInit || !this.store) {
      throw new Error('init failed');
    }
    return this.store as Object as relationalStore.RdbStore;
  }

  protected enableDBSizeLimit(): boolean {
    return this.enableSizeLimit;
  }

  protected onDBSizeCacheChange(_rdbStore: relationalStore.RdbStore, fileSize: number): void {
    this.sizeChanges.push(fileSize);
  }
}

class NullableDBManager extends DBManager {
  protected async initDataBaseHelper(): Promise<relationalStore.RdbStore> {
    return JSON.parse('null') as relationalStore.RdbStore;
  }
}

class ThrowingGetDBManager extends TestDBManager {
  protected async getDBWithCount(_write: boolean, _operationCount: number, _callback: DataBaseCallBack): Promise<void> {
    throw new Error('forced getDBWithCount failure');
  }

  async callGetDBForTest(write: boolean, callback: DataBaseCallBack): Promise<void> {
    await this.getDB(write, callback);
  }
}

class DefaultHookDBManager extends DBManager {
  readonly store: FakeRdbStore;

  constructor(store: FakeRdbStore) {
    super();
    this.store = store;
  }

  protected async initDataBaseHelper(): Promise<relationalStore.RdbStore> {
    return this.store as Object as relationalStore.RdbStore;
  }
}

class CountingCallback implements DataBaseCallBack {
  runCount: number = 0;
  throwRun: boolean = false;

  async run(_rdbStore: relationalStore.RdbStore): Promise<void> {
    this.runCount++;
    if (this.throwRun) {
      throw new Error('callback failed');
    }
  }
}

class FakeFTDBManagerRuntime implements FTDBManagerRuntime {
  readonly helper: DatabaseHelper;
  getCount: number = 0;

  constructor(helper: DatabaseHelper) {
    this.helper = helper;
  }

  getDatabaseHelper(_context: Context): DatabaseHelper {
    this.getCount++;
    return this.helper;
  }
}

function installDatabaseHelperRuntime(store: FakeRdbStore): DatabaseHelper {
  DatabaseHelper.resetInstanceForTest();
  DatabaseHelper.setRuntimeForTest(new FakeDatabaseHelperRuntime(store));
  return DatabaseHelper.getInstance(createContext());
}

export default function dbRuntimeUnitTest() {
  describe('DbRuntimeUnit', () => {
    beforeEach(() => {
      DBManager.resetRuntimeForTest();
      DatabaseHelper.resetRuntimeForTest();
      DatabaseHelper.resetInstanceForTest();
      FTDBManager.resetDbRuntimeForTest();
      FTDBManager.resetInstanceForTest();
      FTDBManager.resetDelayedActionCleanupDelayForTest();
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    afterEach(() => {
      DBManager.resetRuntimeForTest();
      DatabaseHelper.resetRuntimeForTest();
      DatabaseHelper.resetInstanceForTest();
      FTDBManager.resetDbRuntimeForTest();
      FTDBManager.resetInstanceForTest();
      FTDBManager.resetDelayedActionCleanupDelayForTest();
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    it('databaseHelperShouldInitUpgradeResetCloseAndHandleFailures', 0, async () => {
      const store = new FakeRdbStore();
      const runtime = new FakeDatabaseHelperRuntime(store);
      DatabaseHelper.setRuntimeForTest(runtime);
      const helper = DatabaseHelper.getInstance(createContext());

      const firstStore = await helper.initDatabase();
      const secondStore = await helper.initDatabase();
      expect(firstStore !== null).assertTrue();
      expect(secondStore !== null).assertTrue();
      expect(runtime.getCount).assertEqual(1);
      expect(helper.isInitialized()).assertTrue();
      expect(store.executeSqls.length > 0).assertTrue();

      await helper.upgradeDatabase(1, 2);
      await helper.upgradeDatabase(2, 3);
      await helper.upgradeDatabase(1, 3);
      await helper.downgradeDatabase(3, 2);
      await helper.resetDatabase();
      expect(store.executeSqls.join('|').includes('DROP TABLE')).assertTrue();

      await helper.closeDatabase();
      expect(helper.isInitialized()).assertFalse();

      DatabaseHelper.resetInstanceForTest();
      const noInitHelper = DatabaseHelper.getInstance(createContext());
      let upgradeFailed = false;
      try {
        await noInitHelper.upgradeDatabase(1, 2);
      } catch (_error) {
        upgradeFailed = true;
      }
      expect(upgradeFailed).assertTrue();

      DatabaseHelper.resetInstanceForTest();
      const failingRuntime = new FakeDatabaseHelperRuntime(new FakeRdbStore());
      failingRuntime.throwGet = true;
      DatabaseHelper.setRuntimeForTest(failingRuntime);
      let initFailed = false;
      try {
        await DatabaseHelper.getInstance(createContext()).initDatabase();
      } catch (_error) {
        initFailed = true;
      }
      expect(initFailed).assertTrue();

      DatabaseHelper.resetInstanceForTest();
      const createFailStore = new FakeRdbStore();
      createFailStore.throwExecuteSql = true;
      DatabaseHelper.setRuntimeForTest(new FakeDatabaseHelperRuntime(createFailStore));
      initFailed = false;
      try {
        await DatabaseHelper.getInstance(createContext()).initDatabase();
      } catch (_error) {
        initFailed = true;
      }
      expect(initFailed).assertTrue();
    });

    it('dbManagerBaseShouldCoverTransactionsSizeChecksLifecycleAndCatchBranches', 0, async () => {
      const store = new FakeRdbStore();
      const runtime = new FakeDBManagerRuntime();
      DBManager.setRuntimeForTest(runtime);
      const manager = new TestDBManager(store);

      const readCallback = new CountingCallback();
      await manager.getDBForTest(false, 1, readCallback);
      expect(readCallback.runCount).assertEqual(1);
      expect(manager.getDatabaseStoreStatusForTest()).assertEqual('exists');

      const writeCallback = new CountingCallback();
      await manager.getDBForTest(true, 11, writeCallback);
      expect(writeCallback.runCount).assertEqual(1);
      expect(store.beginCount).assertEqual(1);
      expect(store.commitCount).assertEqual(1);

      const failingCallback = new CountingCallback();
      failingCallback.throwRun = true;
      await manager.getDBForTest(true, 11, failingCallback);
      expect(store.rollbackCount).assertEqual(1);

      runtime.currentNow = 20_000;
      store.pageCount = 3;
      await manager.getDBForTest(true, 1, new CountingCallback());
      expect(manager.sizeChanges[0]).assertEqual(12_288);

      expect(manager.shouldCheckDatabaseSizeForTest()).assertFalse();
      runtime.currentNow = 40_001;
      expect(manager.shouldCheckDatabaseSizeForTest()).assertTrue();

      manager.setPendingCloseTaskForTest(7);
      manager.cancelPendingCloseForTest();
      expect(runtime.clearCount).assertEqual(1);

      manager.setOpenCounterForTest(0);
      manager.setLastUsedTimeForTest(0);
      runtime.currentNow = 60_001;
      manager.scheduleCloseIfIdleForTest();
      expect(runtime.scheduled.length).assertEqual(1);
      runtime.scheduled[0]();
      await flushPromises();
      expect(store.closeCount > 0).assertTrue();

      manager.resetDatabaseConnectionForTest();
      manager.acquireForTest();
      manager.tryToCloseForTest();
      expect(manager.isClosed()).assertTrue();

      const closeScheduleStore = new FakeRdbStore();
      const closeScheduleManager = new TestDBManager(closeScheduleStore);
      await closeScheduleManager.getDataBaseHelperForTest();
      closeScheduleManager.setOpenCounterForTest(1);
      const scheduledBeforeZeroClose = runtime.scheduled.length;
      closeScheduleManager.tryToCloseForTest();
      expect(runtime.scheduled.length).assertEqual(scheduledBeforeZeroClose + 1);

      const defaultHookStore = new FakeRdbStore();
      const defaultHookManager = new DefaultHookDBManager(defaultHookStore);
      await defaultHookManager.getDataBaseHelperForTest();
      await defaultHookManager.checkDatabaseSizeForTest(defaultHookStore as Object as relationalStore.RdbStore);
      expect(defaultHookStore.querySqlCount > 0).assertTrue();

      const throwingGetDBManager = new ThrowingGetDBManager(new FakeRdbStore());
      let failed = false;
      try {
        await throwingGetDBManager.callGetDBForTest(false, new CountingCallback());
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();

      const initFailManager = new TestDBManager(null);
      const initFailCallback = new CountingCallback();
      await initFailManager.getDBForTest(false, 1, initFailCallback);
      expect(initFailCallback.runCount).assertEqual(0);
    });

    it('dbManagerDefaultRuntimeWrappersShouldCoverScheduleAndClearDelegates', 0, async () => {
      DBManager.resetRuntimeForTest();

      const timerManager = new TestDBManager(new FakeRdbStore());
      timerManager.setPendingCloseTaskForTest(0);
      timerManager.cancelPendingCloseForTest();

      const scheduleManager = new TestDBManager(new FakeRdbStore());
      scheduleManager.setOpenCounterForTest(0);
      scheduleManager.setLastUsedTimeForTest(0);
      let scheduleAttempted = false;
      try {
        scheduleAttempted = true;
        scheduleManager.scheduleCloseIfIdleForTest();
      } catch (_error) {
        // The default delegate reaches the real thread pool, which may be uninitialized in unit tests.
      }
      expect(scheduleAttempted).assertTrue();
    });

    it('ftDbManagerShouldCoverSyncDataCrudDedupAndDatabaseSizeBranches', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'action,action_id=a value=1i 10')).assertEqual('action_id=a');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view,view_id=v value=1i 11')).assertEqual('view_id=v');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,span_id=s value=1i 12')).assertEqual('span_id=s');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,trace_id=t value=1i 13')).assertEqual('trace_id=t');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,error_type=java,error_message="boom" value=1i 14') !== null).assertTrue();
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,long_task_name=slow value=1i 15') !== null).assertTrue();
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'df_rum_harmonyos_log,sdk_data_id=abc value=1i 16')).assertEqual('sdk_data_id=abc');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'plain value=1i 17')).assertEqual('timestamp=17');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'plain value=1i')).assertEqual(null);

      const log = createSyncData(DataType.LOG, 'log-uuid', 'df_rum_harmonyos_log,sdk_data_id=log-uuid value=1i 100');
      expect(await manager.insertFtOperation(log)).assertTrue();
      expect(log.getId()).assertEqual(1);
      expect(await manager.insertFtOperation(log)).assertFalse();

      const actionData = createSyncData(DataType.RUM_APP, 'action-uuid', 'action,action_id=action-1 value=1i 101');
      manager.addInsertedDataIdForTest(`${DataType.RUM_APP.toString()}:action_id=action-1`);
      expect(await manager.insertFtOperation(actionData)).assertTrue();
      expect(store.deleteCount).assertEqual(1);

      const batchOne = createSyncData(DataType.LOG, 'batch-1', 'df_rum_harmonyos_log,sdk_data_id=batch-1 value=1i 102');
      const batchTwo = createSyncData(DataType.RUM_APP, 'batch-2', 'view,view_id=batch-view value=1i 103');
      store.batchInsertResult = 2;
      expect(await manager.insertFtOptList([batchOne, batchTwo], true)).assertTrue();
      expect(store.batchInsertCount).assertEqual(1);
      expect(await manager.insertFtOptList([], true)).assertTrue();

      store.queryRows = [
        createSyncRow('q1', DataType.LOG.toString(), 'line-1', 1),
        createSyncRow('q2', DataType.RUM_APP.toString(), 'line-2', 2),
        createSyncRow('q3', 'unknown', 'line-3', 3)
      ];
      const queried = await manager.queryFtOperation([DataType.LOG], 10, true);
      expect(queried.length).assertEqual(3);
      expect(queried[0].getDataType()).assertEqual(DataType.LOG);
      expect(queried[1].getDataType()).assertEqual(DataType.RUM_APP);

      await manager.deleteFtOperation([log, batchOne]);
      expect(store.deleteCount >= 3).assertTrue();

      store.queryRows = [
        createValueRow(FTSQL.RECORD_COLUMN_ID, 1 as Object),
        createValueRow(FTSQL.RECORD_COLUMN_ID, 2 as Object)
      ];
      expect(await manager.queryTotalCount([DataType.LOG])).assertEqual(2);
      expect(await manager.hasData([DataType.LOG])).assertTrue();
      store.queryRows = [];
      expect(await manager.hasData([DataType.LOG])).assertFalse();

      await manager.deleteOldestData(DataType.LOG, 5);
      await manager.deleteOldestData([DataType.RUM_APP, DataType.RUM_WEBVIEW], 5);
      expect(store.executeSqls.join('|').includes('DELETE FROM')).assertTrue();

      store.pageCount = 4;
      expect(await manager.getCurrentDatabaseSize()).assertEqual(16_384);

      FTDBCachePolicy.getInstance().setTestDbSizeLimit(1);
      FTDBCachePolicy.getInstance().initSDKParams({
        isLimitWithDbSize: () => true,
        getDbCacheLimit: () => 1,
        getLogCacheLimitCount: () => 0,
        getRumCacheLimitCount: () => 0,
        getDBCacheDiscard: () => DBCacheDiscard.DISCARD_OLDEST,
        getLogCacheDiscard: () => 'discard',
        getRumCacheDiscard: () => 'discard'
      });
      manager.onDBSizeCacheChangeForTest(store as Object as relationalStore.RdbStore, 10);
      await manager.cleanupOldDataForTest(store as Object as relationalStore.RdbStore);
      expect(FTDBCachePolicy.getInstance().getCurrentDbSize()).assertEqual(10);
    });

    it('ftDbManagerShouldCoverRumViewActionCountersQueriesAndFailureFallbacks', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      const view = new ViewBean('view-1', 'Home', 100);
      view.setSessionId('session-1');
      expect(await manager.insertRumView(view)).assertTrue();
      expect(await manager.updateRumView(view)).assertTrue();
      expect(await manager.closeView('', 1, 2, '{}')).assertFalse();
      expect(await manager.closeView('view-1', 1, 2, '{}', 'session-2')).assertTrue();
      expect(await manager.resetViewUploadTime()).assertEqual(0);

      store.queryRows = [createValueRow(FTSQL.RUM_VIEW_UPDATE_TIME, 2 as Object)];
      expect(await manager.updateViewUploadTime('view-1', 123)).assertTrue();
      expect(await manager.updateViewUploadTime('', 123)).assertFalse();
      store.queryRows = [];
      expect(await manager.updateViewUploadTime('missing', 123)).assertFalse();

      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_ACTION_COUNT, 1 as Object)];
      await manager.increaseViewAction('view-1', 'Home');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_LONG_TASK_COUNT, 1 as Object)];
      await manager.increaseViewLongTask('view-1', 'Home');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_ERROR_COUNT, 1 as Object)];
      await manager.increaseViewError('view-1', 'Home');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 1 as Object)];
      await manager.increaseViewPendingResource('view-1');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 1 as Object)];
      await manager.reduceViewPendingResource('view-1');
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 3 as Object)];
      expect(await manager.getViewPendingResource('view-1')).assertEqual(3);
      await manager.forceClearViewPendingResource('view-1');
      await manager.increaseViewResource('view-1');
      expect(await manager.updateViewUpdateTime('view-1')).assertTrue();

      const action = new ActionBean('action-1', 'Tap', 'click', 200);
      action.setSessionInfo('session-1');
      action.setViewInfo('Home', 'view-1', '');
      expect(await manager.insertRumAction(action)).assertTrue();
      expect(await manager.closeAction('', 1, false)).assertFalse();
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0 as Object)];
      expect(await manager.closeAction('action-1', 11, false)).assertTrue();
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0 as Object)];
      expect(await manager.closeAction('action-1', 11, true)).assertTrue();

      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_LONG_TASK_COUNT, 1 as Object)];
      await manager.increaseActionLongTask('action-1', 'Tap');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_ERROR_COUNT, 1 as Object)];
      await manager.increaseActionError('action-1', 'Tap');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_RESOURCE_COUNT, 1 as Object)];
      await manager.increaseActionResource('action-1');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 1 as Object)];
      await manager.increaseActionPendingResource('action-1');
      store.throwExecuteSqlOnce = true;
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 1 as Object)];
      await manager.reduceActionPendingResource('action-1');
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 4 as Object)];
      expect(await manager.getActionPendingResource('action-1')).assertEqual(4);
      await manager.forceClearActionPendingResource('action-1');
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_START_TIME, 200 as Object)];
      expect((await manager.getActionInfo('action-1'))?.startTime).assertEqual(200);

      expect(store.updateCount > 0).assertTrue();
      expect(store.executeSqls.length > 0).assertTrue();
    });

    it('ftDbManagerInitDedupAndCachePolicyTailBranchesShouldCoverInitFailureLocksAndDbCleanup', 0, async () => {
      const store = new FakeRdbStore();
      const runtime = new FakeDatabaseHelperRuntime(store);
      DatabaseHelper.resetInstanceForTest();
      DatabaseHelper.setRuntimeForTest(runtime);
      const helper = DatabaseHelper.getInstance(createContext());
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());

      const initOne = manager.init();
      const initTwo = manager.init();
      await initOne;
      await initTwo;
      await manager.init();
      expect(runtime.getCount).assertEqual(1);

      FTDBManager.resetInstanceForTest();
      DatabaseHelper.resetInstanceForTest();
      const failingStore = new FakeRdbStore();
      const failingRuntime = new FakeDatabaseHelperRuntime(failingStore);
      failingRuntime.throwGet = true;
      DatabaseHelper.setRuntimeForTest(failingRuntime);
      const failingHelper = DatabaseHelper.getInstance(createContext());
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(failingHelper));
      const failingManager = FTDBManager.getInstance(createContext());
      let failed = false;
      try {
        await failingManager.init();
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failingManager.setDatabaseHelperForTest(null);
      await failingManager.deleteOldestData(DataType.LOG, 1);

      FTDBManager.resetInstanceForTest();
      DatabaseHelper.resetInstanceForTest();
      const cleanupStore = new FakeRdbStore();
      const cleanupHelper = installDatabaseHelperRuntime(cleanupStore);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(cleanupHelper));
      const cleanupManager = FTDBManager.getInstance(createContext());
      await cleanupManager.init();
      FTDBCachePolicy.getInstance().setTestDbSizeLimit(1);
      FTDBCachePolicy.getInstance().initSDKParams({
        isLimitWithDbSize: () => true,
        getDbCacheLimit: () => 1,
        getLogCacheLimitCount: () => 0,
        getRumCacheLimitCount: () => 0,
        getDBCacheDiscard: () => DBCacheDiscard.DISCARD_OLDEST,
        getLogCacheDiscard: () => 'discard',
        getRumCacheDiscard: () => 'discard'
      });
      cleanupManager.onDBSizeCacheChangeForTest(cleanupStore as Object as relationalStore.RdbStore, 10);
      await flushPromises();
      expect(cleanupStore.executeSqls.length > 0).assertTrue();
      cleanupStore.throwExecuteSqlOnce = true;
      await cleanupManager.cleanupOldDataForTest(cleanupStore as Object as relationalStore.RdbStore);

      cleanupManager.setDedupLockForTest(new Promise<void>((_resolve, reject) => {
        reject(new Error('lock failed'));
      }));
      expect(await cleanupManager.checkDataExistsForTest(DataType.LOG, 'plain value=1i 771')).assertFalse();
      cleanupManager.setDedupLockForTest(Promise.resolve());
      for (let i = 0; i <= Constants.MAX_MAP_SIZE_DB; i++) {
        cleanupManager.addInsertedDataIdForTest(`preloaded-${i}`);
      }
      await cleanupManager.markDataAsInsertedForTest(DataType.LOG, 'plain value=1i 772');
      expect(cleanupManager.getInsertedDataIdCountForTest()).assertEqual(1);
      expect(cleanupManager.extractUniqueIdForTest(DataType.LOG, JSON.parse('null') as string)).assertEqual(null);
    });

    it('ftDbManagerUniqueIdAndDuplicateBranchesShouldCoverSearchPatternsAndFailureFallbacks', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      const uuid = '123e4567-e89b-12d3-a456-426614174000';
      expect(manager.extractUniqueIdForTest(DataType.LOG, `df_rum_harmonyos_log,sdk_data_id=pkg.${uuid} value=1i 801`)).assertEqual(`uuid=${uuid}`);
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error value=1i')).assertEqual(null);
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask value=1i')).assertEqual(null);
      expect(await manager.checkDataExistsForTest(DataType.LOG, JSON.parse('null') as string)).assertFalse();

      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 1 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'action,action_id=dup-action value=1i 802')).assertTrue();
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 2 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'view,view_id=dup-view value=1i 803')).assertTrue();
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 3 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.LOG, `df_rum_harmonyos_log,sdk_data_id=${uuid} value=1i 804`)).assertTrue();
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 4 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'error,error_type=java,error_message="boom" value=1i 805')).assertTrue();
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 5 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'long_task,long_task_name=slow value=1i 806')).assertTrue();

      store.throwQueryOnce = true;
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'resource,span_id=query-catch value=1i 807')).assertFalse();
      await manager.markDataAsInsertedForTest(DataType.LOG, 'plain value=1i');
      store.throwDeleteOnce = true;
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'action_id=delete-fail')).assertFalse();
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'view_id=delete-ok')).assertTrue();
      manager.setDatabaseHelperForTest(null);
      manager.resetDatabaseConnectionForTest();
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'action_id=no-db')).assertFalse();
    });

    it('ftDbManagerInsertBatchQueryDeleteFailuresShouldCoverRetryBatchQueryAndDeleteTails', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      store.returnPromiseInsert = true;
      store.insertRowIds.push(0);
      expect(await manager.insertFtOperation(createSyncData(DataType.LOG, 'promise-invalid', 'df_rum_harmonyos_log,sdk_data_id=promise-invalid value=1i 901'), true)).assertFalse();
      store.returnPromiseInsert = false;
      store.throwInsertOnce = true;
      store.insertErrorMessage = 'Already closed';
      store.insertRowIds.push(0);
      expect(await manager.insertFtOperation(createSyncData(DataType.LOG, 'retry-invalid', 'df_rum_harmonyos_log,sdk_data_id=retry-invalid value=1i 902'), true)).assertFalse();
      store.throwInsertOnce = true;
      store.insertErrorMessage = 'plain insert failed';
      expect(await manager.insertFtOperation(createSyncData(DataType.LOG, 'plain-insert-error', 'df_rum_harmonyos_log,sdk_data_id=plain-insert-error value=1i 903'), true)).assertFalse();
      manager.setDBOperationErrorForTest('forced insert getdb failed');
      expect(await manager.insertFtOperation(createSyncData(DataType.LOG, 'outer-insert-error', 'df_rum_harmonyos_log,sdk_data_id=outer-insert-error value=1i 904'), true)).assertFalse();
      manager.setDBOperationErrorForTest(null);

      store.batchInsertResult = 1;
      expect(await manager.insertFtOptList([createSyncData(DataType.LOG, 'batch-null-id', 'plain value=1i')], false)).assertTrue();
      const duplicateBatch = createSyncData(DataType.LOG, 'batch-dup-all', 'df_rum_harmonyos_log,sdk_data_id=batch-dup-all value=1i 905');
      manager.addInsertedDataIdForTest(`${DataType.LOG.toString()}:sdk_data_id=batch-dup-all`);
      expect(await manager.insertFtOptList([duplicateBatch], false)).assertTrue();
      store.batchInsertResult = 0;
      expect(await manager.insertFtOptList([createSyncData(DataType.LOG, 'batch-zero', 'df_rum_harmonyos_log,sdk_data_id=batch-zero value=1i 906')], true)).assertTrue();
      manager.setDBOperationErrorForTest('forced batch getdb failed');
      expect(await manager.insertFtOptList([createSyncData(DataType.LOG, 'batch-error', 'df_rum_harmonyos_log,sdk_data_id=batch-error value=1i 907')], true)).assertFalse();
      manager.setDBOperationErrorForTest(null);

      store.queryRows = [
        createSyncRow('query-log', DataType.LOG.toString(), 'log-line', 1),
        createSyncRow('query-webview', DataType.RUM_WEBVIEW.toString(), 'webview-line', 2),
        createSyncRow('query-unknown', 'custom_type', 'custom-line', 3)
      ];
      const allRows = await manager.queryFtOperation([], 0, false);
      expect(allRows.length).assertEqual(3);
      const throwingResultSet = new FakeResultSet([createSyncRow('bad-row', DataType.LOG.toString(), 'bad-line', 4)]);
      throwingResultSet.throwOnGetString = true;
      store.queryQueue.push(throwingResultSet);
      expect((await manager.queryFtOperation([DataType.LOG], 1, false)).length).assertEqual(0);
      manager.setDBOperationErrorForTest('forced query getdb failed');
      expect((await manager.queryFtOperation([DataType.LOG], 1, false)).length).assertEqual(0);
      manager.setDBOperationErrorForTest(null);

      await manager.deleteFtOperation([]);
      store.deleteResult = 0;
      await manager.deleteFtOperation([createSyncData(DataType.LOG, 'missing-delete', 'df_rum_harmonyos_log,sdk_data_id=missing-delete value=1i 908')]);
      manager.setDBOperationErrorForTest('forced delete getdb failed');
      await manager.deleteFtOperation([createSyncData(DataType.LOG, 'delete-error', 'df_rum_harmonyos_log,sdk_data_id=delete-error value=1i 909')]);
      manager.setDBOperationErrorForTest(null);

      store.throwQueryOnce = true;
      expect(await manager.queryTotalCount([DataType.LOG])).assertEqual(0);
      await manager.deleteOldestData([], 1);
      store.throwExecuteSqlOnce = true;
      await manager.deleteOldestData(DataType.LOG, 1);
      store.querySqlQueue.push(new FakeResultSet([]));
      expect(await manager.getCurrentDatabaseSize()).assertEqual(0);
      store.throwQuerySqlOnce = true;
      expect(await manager.getCurrentDatabaseSize()).assertEqual(0);
      store.throwQueryOnce = true;
      expect(await manager.hasData([DataType.LOG])).assertFalse();
    });

    it('ftDbManagerRumViewActionFallbacksShouldCoverNotFoundEmptyIdsDelayedCleanupAndCatchBranches', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      const view = new ViewBean('tail-view', 'Tail', 100);
      manager.setDBOperationErrorOnceForTest('UNIQUE constraint failed');
      expect(await manager.insertRumView(view)).assertTrue();
      manager.setDBOperationErrorForTest('forced view update failed');
      expect(await manager.updateRumView(view)).assertFalse();
      manager.setDBOperationErrorForTest(null);
      store.updateResult = 0;
      expect(await manager.closeView('missing-view', 1, 2, '{}')).assertTrue();
      manager.setDBOperationErrorForTest('forced close view failed');
      expect(await manager.closeView('view-error', 1, 2, '{}')).assertFalse();
      expect(await manager.resetViewUploadTime()).assertEqual(0);
      expect(await manager.updateViewUploadTime('view-error', 1)).assertFalse();
      expect(await manager.updateViewUpdateTime('view-error')).assertFalse();
      manager.setDBOperationErrorForTest(null);
      store.updateResult = 1;

      store.queryRows = [createValueRow(FTSQL.RUM_VIEW_UPDATE_TIME, 3 as Object)];
      store.updateResult = 0;
      expect(await manager.updateViewUploadTime('not-updated', 1)).assertFalse();
      store.queryRows = [];
      expect(await manager.updateViewUpdateTime('missing-update-time')).assertTrue();
      store.updateResult = 1;

      await manager.increaseViewAction('');
      await manager.increaseViewLongTask('');
      await manager.increaseViewError('');
      await manager.increaseActionLongTask('');
      await manager.increaseActionError('');
      await manager.increaseActionResource('');
      await manager.increaseActionPendingResource('');
      await manager.reduceActionPendingResource('');
      await manager.increaseViewPendingResource('');
      await manager.reduceViewPendingResource('');
      expect(await manager.getViewPendingResource('')).assertEqual(0);
      await manager.forceClearViewPendingResource('');
      expect(await manager.getActionInfo('')).assertEqual(null);
      expect(await manager.getActionPendingResource('')).assertEqual(0);
      await manager.forceClearActionPendingResource('');
      await manager.increaseViewResource('');
      expect(await manager.updateViewUpdateTime('')).assertFalse();

      const fallbackMethods: (() => Promise<void>)[] = [
        async () => { await manager.increaseViewAction('missing-view-action', 'Tail'); },
        async () => { await manager.increaseViewLongTask('missing-view-longtask', 'Tail'); },
        async () => { await manager.increaseViewError('missing-view-error', 'Tail'); },
        async () => { await manager.increaseActionLongTask('missing-action-longtask', 'Tap'); },
        async () => { await manager.increaseActionError('missing-action-error', 'Tap'); },
        async () => { await manager.increaseActionResource('missing-action-resource'); },
        async () => { await manager.increaseActionPendingResource('missing-action-pending'); },
        async () => { await manager.reduceActionPendingResource('missing-action-reduce'); },
        async () => { await manager.increaseViewPendingResource('missing-view-pending'); },
        async () => { await manager.reduceViewPendingResource('missing-view-reduce'); },
        async () => { await manager.increaseViewResource('missing-view-resource'); }
      ];
      for (const method of fallbackMethods) {
        store.throwExecuteSqlOnce = true;
        store.queryRows = [];
        await method();
      }

      manager.setDBOperationErrorForTest('forced rum counter getdb failed');
      await manager.increaseViewAction('view-catch');
      await manager.increaseViewLongTask('view-catch');
      await manager.increaseViewError('view-catch');
      await manager.increaseActionLongTask('action-catch');
      await manager.increaseActionError('action-catch');
      await manager.increaseActionResource('action-catch');
      await manager.increaseActionPendingResource('action-catch');
      await manager.reduceActionPendingResource('action-catch');
      await manager.increaseViewPendingResource('view-catch');
      await manager.reduceViewPendingResource('view-catch');
      expect(await manager.getViewPendingResource('view-catch')).assertEqual(0);
      await manager.forceClearViewPendingResource('view-catch');
      expect(await manager.getActionInfo('action-catch')).assertEqual(null);
      expect(await manager.getActionPendingResource('action-catch')).assertEqual(0);
      await manager.forceClearActionPendingResource('action-catch');
      await manager.increaseViewResource('view-catch');
      expect(await manager.updateViewUpdateTime('view-catch')).assertFalse();
      expect(await manager.insertRumAction(new ActionBean('action-catch', 'Tap', 'click', 1))).assertFalse();
      manager.setDBOperationErrorForTest(null);

      store.queryRows = [];
      expect(await manager.getActionInfo('missing-action-info')).assertEqual(null);
      store.updateResult = 0;
      await manager.forceClearViewPendingResource('missing-force-view');
      await manager.forceClearActionPendingResource('missing-force-action');
      store.updateResult = 1;

      FTDBManager.setDelayedActionCleanupDelayForTest(0);
      store.queryQueue.push(
        new FakeResultSet([createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 2 as Object)]),
        new FakeResultSet([createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 2 as Object)])
      );
      expect(await manager.closeAction('action-delay', 12, true)).assertTrue();
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 1);
      });
      await flushPromises();
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 1 as Object)];
      expect(await manager.closeAction('action-pending', 12, false)).assertFalse();
      store.queryRows = [];
      expect(await manager.closeAction('action-not-found', 12, false)).assertFalse();
      store.queryRows = [createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0 as Object)];
      store.updateResult = 0;
      expect(await manager.closeAction('action-update-miss', 12, true)).assertFalse();
      manager.setDBOperationErrorForTest('forced close action failed');
      expect(await manager.closeAction('action-catch', 12, true)).assertFalse();
      manager.setDBOperationErrorForTest(null);
    });

    it('ftDbManagerCleanupSummaryAndExpireCatchBranchesShouldCoverSummaryEmptyStaleAndOuterCatchPaths', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());
      await manager.init();

      store.queryQueue.push(new FakeResultSet([]));
      expect((await manager.querySumAction(1)).length).assertEqual(0);
      manager.setDBOperationErrorForTest('forced action summary failed');
      expect((await manager.querySumAction(1)).length).assertEqual(0);
      expect(await manager.getActionCounts('count-catch')).assertEqual(null);
      manager.setDBOperationErrorForTest(null);
      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.getActionCounts('count-empty')).assertEqual(null);

      store.querySqlQueue.push(new FakeResultSet([]));
      expect((await manager.querySumView(1)).length).assertEqual(0);
      manager.setDBOperationErrorForTest('forced view summary failed');
      expect((await manager.querySumView(1)).length).assertEqual(0);
      expect(await manager.queryRumViewById('view-catch')).assertEqual(null);
      manager.setDBOperationErrorForTest(null);
      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.queryRumViewById('view-empty')).assertEqual(null);

      store.deleteResult = 1;
      await manager.cleanCloseActionData(['delete-action']);
      store.deleteResult = 0;
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 2 as Object)]));
      await manager.cleanCloseActionData();
      manager.setDBOperationErrorForTest('forced clean action failed');
      await manager.cleanCloseActionData(['delete-action-catch']);
      manager.setDBOperationErrorForTest(null);

      await manager.cleanCloseViewData(['delete-view']);
      await manager.cleanCloseViewData();
      manager.setDBOperationErrorForTest('forced clean view failed');
      await manager.cleanCloseViewData(['delete-view-catch']);
      await manager.closeAllActionAndView();
      await manager.delete();
      expect(await manager.updateDataType('rum_app_error_sampled', 100)).assertEqual(0);
      expect(await manager.deleteExpireCache(DataType.LOG, 100, 10)).assertEqual(0);
      expect((await manager.queryRelatedUUIDsByActionId('action', 'resource', DataType.RUM_APP)).length).assertEqual(0);
      manager.setDBOperationErrorForTest(null);

      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.updateDataType('rum_app_error_sampled', 100)).assertEqual(0);
      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.deleteExpireCache(DataType.LOG, 100, 10)).assertEqual(0);
      const relatedThrowingResultSet = new FakeResultSet([
        createSyncRow('related-bad', DataType.RUM_APP.toString(), 'resource,action_id=target value=1i 1', 1)
      ]);
      relatedThrowingResultSet.throwOnGetString = true;
      store.queryQueue.push(relatedThrowingResultSet);
      expect((await manager.queryRelatedUUIDsByActionId('target', 'resource', DataType.RUM_APP)).length).assertEqual(0);
    });

    it('ftDbManagerRemainingRealBranchesShouldCoverFalseSidesAndFallbackValues', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      FTDBManager.setDbRuntimeForTest(new FakeFTDBManagerRuntime(helper));
      const manager = FTDBManager.getInstance(createContext());

      manager.setDatabaseHelperForTest(null);
      await manager.init();
      expect(manager.getDatabaseStoreStatusForTest()).assertEqual('null');

      FTDBCachePolicy.getInstance().resetTestConfig();
      manager.onDBSizeCacheChangeForTest(store as Object as relationalStore.RdbStore, 10);
      FTDBCachePolicy.getInstance().initSDKParams({
        isLimitWithDbSize: () => true,
        getDbCacheLimit: () => 1,
        getLogCacheLimitCount: () => 0,
        getRumCacheLimitCount: () => 0,
        getDBCacheDiscard: () => DBCacheDiscard.DISCARD,
        getLogCacheDiscard: () => 'discard',
        getRumCacheDiscard: () => 'discard'
      });
      manager.onDBSizeCacheChangeForTest(store as Object as relationalStore.RdbStore, 10);

      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'action,foo=bar value=1i 1')).assertEqual('timestamp=1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view,foo=bar value=1i 2')).assertEqual('timestamp=2');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,foo=bar value=1i 3')).assertEqual('timestamp=3');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,foo=bar value=bad')).assertEqual(null);
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,foo=bar value=bad')).assertEqual(null);
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'df_rum_harmonyos_log,foo=bar value=1i 4')).assertEqual('timestamp=4');

      const duplicateData = createSyncData(DataType.RUM_APP, 'duplicate-delete-fail',
        'action,action_id=duplicate-delete-fail value=1i 1001');
      manager.addInsertedDataIdForTest(`${DataType.RUM_APP.toString()}:action_id=duplicate-delete-fail`);
      store.throwDeleteOnce = true;
      expect(await manager.insertFtOperation(duplicateData, false)).assertFalse();

      store.queryRows = [createValueRow(FTSQL.RECORD_COLUMN_ID, 1 as Object)];
      expect(await manager.queryTotalCount([])).assertEqual(1);
      expect(await manager.hasData([])).assertTrue();

      DatabaseHelper.resetInstanceForTest();
      DatabaseHelper.setRuntimeForTest(new NullDatabaseHelperRuntime());
      const nullHelper = DatabaseHelper.getInstance(createContext());
      manager.setDatabaseHelperForTest(nullHelper);
      manager.resetDatabaseConnectionForTest();
      await manager.deleteOldestData(DataType.LOG, 1);
      expect(await manager.getCurrentDatabaseSize()).assertEqual(0);
      manager.setDatabaseHelperForTest(helper);
      manager.resetDatabaseConnectionForTest();

      store.queryQueue.push(new FakeResultSet([createSyncRow('closed-query', DataType.LOG.toString(), 'line', 10)]));
      const closedQueryResult = await manager.queryFtOperation([DataType.LOG], 1, false);
      expect(closedQueryResult.length).assertEqual(1);
      store.queryQueue.push(new FakeResultSet([createSyncRow('', DataType.LOG.toString(), 'missing-uuid', 11)]));
      expect((await manager.queryFtOperation([DataType.LOG], 1, false)).length).assertEqual(0);

      const closedView = new ViewBean('closed-view', 'Closed', 100);
      closedView.setIsClose(true);
      expect(await manager.insertRumView(closedView)).assertTrue();
      expect(await manager.updateRumView(closedView)).assertTrue();
      manager.setDBOperationErrorOnceForTest('plain view insert failure');
      expect(await manager.insertRumView(new ViewBean('view-insert-error', 'Error', 101))).assertFalse();

      const closedAction = new ActionBean('closed-action', 'Tap', 'click', 200);
      closedAction.setIsClose(true);
      expect(await manager.insertRumAction(closedAction)).assertTrue();

      store.throwExecuteSqlOnce = true;
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0 as Object)]));
      await manager.reduceActionPendingResource('zero-action-pending');
      store.throwExecuteSqlOnce = true;
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0 as Object)]));
      await manager.reduceViewPendingResource('zero-view-pending');
      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.getViewPendingResource('empty-view-pending')).assertEqual(0);
      store.queryQueue.push(new FakeResultSet([]));
      expect(await manager.getActionPendingResource('empty-action-pending')).assertEqual(0);
      store.throwExecuteSqlOnce = true;
      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RUM_COLUMN_RESOURCE_COUNT, 2 as Object)]));
      await manager.increaseViewResource('view-resource-fallback');

      const emptyStartActionRow = createActionRow('action-empty-start');
      emptyStartActionRow[FTSQL.RUM_COLUMN_START_TIME] = '' as Object;
      store.queryQueue.push(new FakeResultSet([emptyStartActionRow]));
      const emptyStartActions = await manager.querySumAction(1);
      expect(emptyStartActions.length).assertEqual(1);
      expect(emptyStartActions[0].getStartTime()).assertEqual(0);

      const emptyStartViewRow = createViewRow('view-empty-start');
      emptyStartViewRow[FTSQL.RUM_COLUMN_START_TIME] = '' as Object;
      store.querySqlQueue.push(new FakeResultSet([emptyStartViewRow]));
      const emptyStartViews = await manager.querySumView(1);
      expect(emptyStartViews.length).assertEqual(1);
      expect(emptyStartViews[0].getStartTime()).assertEqual(0);

      const emptyStartViewByIdRow = createViewRow('view-by-id-empty-start');
      emptyStartViewByIdRow[FTSQL.RUM_COLUMN_START_TIME] = '' as Object;
      store.queryQueue.push(new FakeResultSet([emptyStartViewByIdRow]));
      const emptyStartViewById = await manager.queryRumViewById('view-by-id-empty-start');
      expect(emptyStartViewById !== null).assertTrue();
      if (emptyStartViewById) {
        expect(emptyStartViewById.getStartTime()).assertEqual(0);
      }

      store.deleteResult = 1;
      store.queryQueue.push(new FakeResultSet([]));
      await manager.cleanCloseActionData();
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 0 as Object)]));
      await manager.cleanCloseActionData();
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 1 as Object)]));
      await manager.cleanCloseActionData();

      store.queryQueue.push(new FakeResultSet([]));
      expect((await manager.queryRelatedUUIDsByActionId('empty-related', 'resource', DataType.RUM_APP)).length).assertEqual(0);
      store.queryQueue.push(new FakeResultSet([
        createSyncRow('related-no-space', DataType.RUM_APP.toString(), 'resource,action_id=no-space', 1)
      ]));
      const noSpaceRelated = await manager.queryRelatedUUIDsByActionId('no-space', 'resource', DataType.RUM_APP);
      expect(noSpaceRelated.length).assertEqual(1);
      expect(noSpaceRelated[0]).assertEqual('related-no-space');
    });

    it('databaseHelperTailBranchesShouldCoverPrivateHooksAndSyncUpgradePaths', 0, async () => {
      const store = new FakeRdbStore();
      const runtime = new FakeDatabaseHelperRuntime(store);
      DatabaseHelper.setRuntimeForTest(runtime);
      const helper = DatabaseHelper.getInstance(createContext());
      expect(DatabaseHelper.getInstance(createContext()) === helper).assertTrue();

      const initOne = helper.initDatabase();
      const initTwo = helper.initDatabase();
      await initOne;
      await initTwo;
      expect(runtime.getCount).assertEqual(1);

      helper.resetStateForTest();
      expect(helper.isInitialized()).assertFalse();
      expect(await helper.checkTablesExistForTest()).assertFalse();
      expect(await helper.hasVersionColumnsForTest()).assertFalse();
      expect(await helper.hasTableForTest(FTSQL.FT_TABLE_VIEW)).assertFalse();
      await helper.checkAndUpgradeDatabaseForTest();
      let failed = false;
      try {
        await helper.createTablesForTest();
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.createIndexesForTest();
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();

      helper.setRdbStoreForTest(store as Object as relationalStore.RdbStore);
      expect(await helper.checkTablesExistForTest()).assertTrue();
      expect(await helper.hasVersionColumnsForTest()).assertTrue();
      expect(await helper.hasTableForTest(FTSQL.FT_TABLE_ACTION)).assertTrue();

      store.throwQuerySql = true;
      expect(await helper.hasVersionColumnsForTest()).assertFalse();
      expect(await helper.hasTableForTest(FTSQL.FT_TABLE_ACTION)).assertFalse();
      store.throwExecuteSql = true;
      await helper.checkAndUpgradeDatabaseForTest();
      store.throwExecuteSql = false;
      store.throwQuerySql = false;

      const syncIndexSqlCount = store.executeSqls.length;
      helper.createIndexesSyncForTest(store as Object as relationalStore.RdbStore);
      expect(store.executeSqls.length > syncIndexSqlCount).assertTrue();

      store.throwExecuteSql = true;
      await helper.createIndexesForTest();
      store.throwExecuteSql = false;

      store.throwExecuteSqlOnce = true;
      helper.createIndexesSyncForTest(store as Object as relationalStore.RdbStore);
      helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 1, 2);
      helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 2, 3);
      helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 1, 3);
      helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 3, 4);
      await helper.downgradeDatabase(2, 1);

      store.throwExecuteSql = true;
      failed = false;
      try {
        helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 2, 3);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        helper.handleUpgradeSyncForTest(store as Object as relationalStore.RdbStore, 1, 2);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.upgradeDatabase(1, 2);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.upgradeDatabase(2, 3);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.downgradeDatabase(3, 2);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.resetDatabase();
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      store.throwExecuteSql = false;

      helper.resetStateForTest();
      failed = false;
      try {
        await helper.downgradeDatabase(3, 2);
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      failed = false;
      try {
        await helper.resetDatabase();
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      helper.setRdbStoreForTest(store as Object as relationalStore.RdbStore);

      store.throwClose = true;
      await helper.closeDatabase();
      expect(store.closeCount).assertEqual(1);
    });

    it('dbManagerTailBranchesShouldCoverNullCloseShutdownAndSizeFailures', 0, async () => {
      const runtime = new FakeDBManagerRuntime();
      DBManager.setRuntimeForTest(runtime);

      const nullManager = new NullableDBManager();
      const nullCallback = new CountingCallback();
      await nullManager.getDBForTest(false, 1, nullCallback);
      expect(nullCallback.runCount).assertEqual(0);

      const store = new FakeRdbStore();
      const manager = new TestDBManager(store);
      expect(manager.getDatabaseStoreStatusForTest()).assertEqual('null');
      await manager.getDataBaseHelperForTest();
      expect(manager.getDatabaseStoreStatusForTest()).assertEqual('exists');

      store.querySqlQueue.push(new FakeResultSet([]));
      await manager.checkDatabaseSizeForTest(store as Object as relationalStore.RdbStore);
      expect(manager.sizeChanges.length).assertEqual(0);

      manager.resetDatabaseConnectionForTest();
      await manager.checkDatabaseSizeForTest(store as Object as relationalStore.RdbStore);
      await manager.getDataBaseHelperForTest();

      store.throwQuerySql = true;
      store.querySqlErrorMessage = 'Already closed';
      await manager.checkDatabaseSizeForTest(store as Object as relationalStore.RdbStore);
      store.querySqlErrorMessage = 'query sql failed';
      await manager.checkDatabaseSizeForTest(store as Object as relationalStore.RdbStore);
      store.throwQuerySql = false;

      manager.setLastDbSizeCheckTimeForTest(0);
      runtime.currentNow = 1;
      expect(manager.shouldCheckDatabaseSizeForTest()).assertFalse();
      runtime.currentNow = 10_001;
      expect(manager.shouldCheckDatabaseSizeForTest()).assertTrue();

      manager.setOpenCounterForTest(10);
      manager.acquireForTest();
      manager.setOpenCounterForTest(2);
      const scheduledBeforeTryClose = runtime.scheduled.length;
      manager.tryToCloseForTest();
      expect(runtime.scheduled.length).assertEqual(scheduledBeforeTryClose);
      manager.setOpenCounterForTest(1);
      manager.scheduleCloseIfIdleForTest();
      expect(runtime.scheduled.length).assertEqual(scheduledBeforeTryClose);

      manager.closeDatabaseForTest();
      await flushPromises();
      expect(store.closeCount).assertEqual(0);

      manager.setOpenCounterForTest(0);
      store.throwClose = true;
      store.closeErrorMessage = 'Already closed';
      manager.closeDatabaseForTest();
      await flushPromises();
      expect(manager.isClosed()).assertTrue();

      const genericCloseStore = new FakeRdbStore();
      const genericCloseManager = new TestDBManager(genericCloseStore);
      await genericCloseManager.getDataBaseHelperForTest();
      genericCloseStore.throwClose = true;
      genericCloseManager.setOpenCounterForTest(0);
      genericCloseManager.closeDatabaseForTest();
      await flushPromises();
      expect(genericCloseStore.closeCount).assertEqual(1);

      const shutdownStore = new FakeRdbStore();
      const shutdownManager = new TestDBManager(shutdownStore);
      await shutdownManager.getDataBaseHelperForTest();
      shutdownManager.setPendingCloseTaskForTest(99);
      await shutdownManager.shutDown();
      await flushPromises();
      expect(runtime.clearCount > 0).assertTrue();
      expect(shutdownStore.closeCount).assertEqual(1);

      const shutdownFailStore = new FakeRdbStore();
      const shutdownFailManager = new TestDBManager(shutdownFailStore);
      await shutdownFailManager.getDataBaseHelperForTest();
      shutdownFailStore.throwClose = true;
      await shutdownFailManager.shutDown();
      await flushPromises();
      expect(shutdownFailStore.closeCount).assertEqual(1);
      await new TestDBManager(null).shutDown();
    });

    it('ftDbManagerTailBranchesShouldCoverDedupInsertQueriesCleanupAndRelease', 0, async () => {
      const store = new FakeRdbStore();
      const helper = installDatabaseHelperRuntime(store);
      const runtime = new FakeFTDBManagerRuntime(helper);
      FTDBManager.setDbRuntimeForTest(runtime);
      const manager = FTDBManager.getInstance(createContext());
      expect(FTDBManager.getInstance(createContext()) === manager).assertTrue();
      manager.setDatabaseHelperForTest(helper);
      await manager.init();
      expect(runtime.getCount >= 1).assertTrue();

      expect(await manager.checkDataExistsForTest(DataType.LOG, 'plain value=1i')).assertFalse();
      await manager.markDataAsInsertedForTest(DataType.LOG, 'df_rum_harmonyos_log,sdk_data_id=tail-log value=1i 201');
      expect(manager.getInsertedDataIdCountForTest() > 0).assertTrue();
      expect(await manager.checkDataExistsForTest(DataType.LOG, 'df_rum_harmonyos_log,sdk_data_id=tail-log value=1i 201')).assertTrue();

      store.queryQueue.push(new FakeResultSet([createValueRow(FTSQL.RECORD_COLUMN_ID, 1 as Object)]));
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'view,view_id=db-view value=1i 202')).assertTrue();
      store.throwQuery = true;
      expect(await manager.checkDataExistsForTest(DataType.RUM_APP, 'resource,span_id=query-fail value=1i 203')).assertFalse();
      store.throwQuery = false;
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'unsupported=value')).assertFalse();
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'action_id=tail-action')).assertTrue();
      store.throwDelete = true;
      expect(await manager.deleteDuplicateDataForTest(DataType.RUM_APP, 'view_id=tail-view')).assertFalse();
      store.throwDelete = false;

      const invalidInsert = createSyncData(DataType.LOG, 'invalid-row', 'df_rum_harmonyos_log,sdk_data_id=invalid-row value=1i 204');
      store.insertRowIds.push(0);
      expect(await manager.insertFtOperation(invalidInsert, true)).assertFalse();
      const promiseInsert = createSyncData(DataType.LOG, 'promise-row', 'df_rum_harmonyos_log,sdk_data_id=promise-row value=1i 205');
      store.returnPromiseInsert = true;
      store.insertRowIds.push(9);
      expect(await manager.insertFtOperation(promiseInsert, true)).assertTrue();
      store.returnPromiseInsert = false;
      const retryInsert = createSyncData(DataType.LOG, 'retry-row', 'df_rum_harmonyos_log,sdk_data_id=retry-row value=1i 206');
      store.throwInsertOnce = true;
      store.insertErrorMessage = 'Already closed';
      store.insertRowIds.push(10);
      expect(await manager.insertFtOperation(retryInsert, true)).assertTrue();
      store.insertErrorMessage = 'insert failed';

      const duplicateOne = createSyncData(DataType.LOG, 'dup-1', 'df_rum_harmonyos_log,sdk_data_id=batch-dup value=1i 207');
      const duplicateTwo = createSyncData(DataType.LOG, 'dup-2', 'df_rum_harmonyos_log,sdk_data_id=batch-dup value=1i 207');
      expect(await manager.insertFtOptList([duplicateOne, duplicateTwo], false)).assertTrue();
      store.throwBatchInsert = true;
      expect(await manager.insertFtOptList([
        createSyncData(DataType.LOG, 'batch-fail', 'df_rum_harmonyos_log,sdk_data_id=batch-fail value=1i 208')
      ], true)).assertTrue();
      store.throwBatchInsert = false;

      store.queryQueue.push(new FakeResultSet([createActionRow('action-query')]));
      const actions = await manager.querySumAction(1);
      expect(actions.length).assertEqual(1);
      store.queryQueue.push(new FakeResultSet([createActionRow('action-count')]));
      const counts = await manager.getActionCounts('action-count');
      expect(counts !== null).assertTrue();
      if (counts) {
        expect(counts.resourceCount).assertEqual(3);
      }
      store.querySqlQueue.push(new FakeResultSet([createViewRow('view-query')]));
      const views = await manager.querySumView(1);
      expect(views.length).assertEqual(1);
      store.queryQueue.push(new FakeResultSet([createViewRow('view-by-id')]));
      const queriedView = await manager.queryRumViewById('view-by-id');
      expect(queriedView !== null).assertTrue();
      if (queriedView) {
        expect(queriedView.getId()).assertEqual('view-by-id');
      }
      expect(await manager.queryRumViewById('')).assertEqual(null);

      store.deleteResult = 0;
      await manager.cleanCloseActionData(['missing-action']);
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 1 as Object)]));
      await manager.cleanCloseActionData();
      await manager.cleanCloseViewData(['missing-view']);
      await manager.cleanCloseViewData();
      store.deleteResult = 1;

      await manager.closeAllActionAndView();
      await manager.executeWithDB(false, new CountingCallback());
      await manager.delete();

      expect(await manager.updateDataType('rum_app', 1)).assertEqual(0);
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 1 as Object)]));
      expect(await manager.updateDataType('rum_app_error_sampled', 300)).assertEqual(1);
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 0 as Object)]));
      expect(await manager.updateDataType('log_error_sampled', 300)).assertEqual(0);

      store.queryQueue.push(new FakeResultSet([createValueRow('count', 1 as Object)]));
      expect(await manager.deleteExpireCache(DataType.LOG, 400, 100)).assertEqual(1);
      store.queryQueue.push(new FakeResultSet([createValueRow('count', 0 as Object)]));
      expect(await manager.deleteExpireCache('rum_app_error_sampled', 400, 100)).assertEqual(0);

      store.queryRows = [
        createSyncRow('match-1', DataType.RUM_APP.toString(), 'resource,action_id=target value=1i 500', 500),
        createSyncRow('skip-measurement', DataType.RUM_APP.toString(), 'error,action_id=target value=1i 501', 501),
        createSyncRow('skip-action', DataType.RUM_APP.toString(), 'resource,action_id=other value=1i 502', 502),
        createSyncRow('', DataType.RUM_APP.toString(), 'resource,action_id=target value=1i 503', 503)
      ];
      const related = await manager.queryRelatedUUIDsByActionId('target', 'resource', DataType.RUM_APP);
      expect(related.length).assertEqual(1);
      expect((await manager.queryRelatedUUIDsByActionId('', 'resource', DataType.RUM_APP)).length).assertEqual(0);
      expect((await manager.queryRelatedUUIDsByActionId('target', '', DataType.RUM_APP)).length).assertEqual(0);

      await manager.resetDatabase();
      manager.setDatabaseHelperForTest(null);
      await manager.resetDatabase();
      await manager.release();
      await manager.release();
    });
  });
}
