import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import relationalStore from '@ohos.data.relationalStore';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DataBaseCallBack } from '../../main/ets/components/db/base/DataBaseCallBack';
import { SyncData } from '../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../main/ets/components/db/bean/ViewBean';
import { DataType, SyncPageSize } from '../../main/ets/components/enum/Enums';
import { NetCodeStatus } from '../../main/ets/components/http/HttpEngine';
import {
  SyncTaskManager,
  SyncTaskRequestCallback
} from '../../main/ets/components/SyncTaskManager';
import {
  SyncTaskCachePolicy,
  SyncTaskConfigRecord,
  SyncTaskDbManager,
  SyncTaskHttpResult,
  SyncTaskManagerRuntime,
  SyncTaskPreferences,
  SyncTaskUploadQueueStatus,
  SyncTaskUploadThreadPool
} from '../../main/ets/components/SyncTaskManagerRuntime';

const TEST_URL = 'http://localhost';

function createContext(): Context {
  return new Object() as Context;
}

function createConfig(): FTSDKConfig {
  return FTSDKConfig.builder(TEST_URL)
    .setAutoSync(true)
    .setSyncPageSize(SyncPageSize.MINI)
    .setDataSyncRetryCount(2)
    .setSyncSleepTime(1)
    .setLogCacheLimitCount(1000)
    .setRumCacheLimitCount(1000);
}

function createSyncData(dataType: DataType, uuid: string, dataString: string, time: number = 100): SyncData {
  const data = new SyncData(dataType);
  data.setUuid(uuid);
  data.setDataString(dataString);
  data.setTime(time);
  return data;
}

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 8; i++) {
    await Promise.resolve();
  }
}

class FakePreferences implements SyncTaskPreferences {
  value: number | string | boolean = -1;
  putCount: number = 0;
  flushCount: number = 0;
  throwPut: boolean = false;
  throwGet: boolean = false;

  async put(_key: string, value: number): Promise<void> {
    this.putCount++;
    if (this.throwPut) {
      throw new Error('put failed');
    }
    this.value = value;
  }

  async flush(): Promise<void> {
    this.flushCount++;
  }

  async get(_key: string, defaultValue: number): Promise<number | string | boolean> {
    if (this.throwGet) {
      throw new Error('get failed');
    }
    if (this.value === undefined) {
      return defaultValue;
    }
    return this.value;
  }
}

class FakeUploadThreadPool implements SyncTaskUploadThreadPool {
  runnable: (() => void) | null = null;
  scheduleDelays: number[] = [];
  shutdownCount: number = 0;
  setRunningValues: boolean[] = [];
  status: SyncTaskUploadQueueStatus = {
    queueSize: 0,
    isProcessing: false,
    isRunning: false,
    isScheduled: false,
    needReschedule: false,
    maxQueueSize: 1
  };

  initRunnable(runnable: () => void): void {
    this.runnable = runnable;
  }

  schedule(delay: number): void {
    this.scheduleDelays.push(delay);
  }

  shutdown(): void {
    this.shutdownCount++;
  }

  setRunning(running: boolean): void {
    this.setRunningValues.push(running);
    this.status.isRunning = running;
  }

  getUploadQueueStatus(): SyncTaskUploadQueueStatus {
    return this.status;
  }
}

class FakeCachePolicy implements SyncTaskCachePolicy {
  initCount: number = 0;
  discard: boolean = false;
  logLimit: number = 0;
  rumLimit: number = 0;
  logCount: number = 0;
  rumCount: number = 0;
  logDelta: number = 0;
  rumDelta: number = 0;
  lastRecord: SyncTaskConfigRecord | null = null;
  throwOptLogCount: boolean = false;
  throwOptRumCount: boolean = false;

  initSDKParams(configRecord: SyncTaskConfigRecord): void {
    this.initCount++;
    this.lastRecord = configRecord;
  }

  shouldDiscardData(_dataType: DataType): boolean {
    return this.discard;
  }

  optLogCount(delta: number): void {
    if (this.throwOptLogCount) {
      throw new Error('opt log failed');
    }
    this.logDelta += delta;
    this.logCount += delta;
  }

  optRumCount(delta: number): void {
    if (this.throwOptRumCount) {
      throw new Error('opt rum failed');
    }
    this.rumDelta += delta;
    this.rumCount += delta;
  }

  getLogLimitCount(): number {
    return this.logLimit;
  }

  getRumLimitCount(): number {
    return this.rumLimit;
  }

  getLogCount(): number {
    return this.logCount;
  }

  getRumCount(): number {
    return this.rumCount;
  }
}

class FakeResultSet {
  hasRow: boolean;
  count: number;
  closeCount: number = 0;

  constructor(hasRow: boolean, count: number) {
    this.hasRow = hasRow;
    this.count = count;
  }

  goToFirstRow(): boolean {
    return this.hasRow;
  }

  getLong(_columnIndex: number): number {
    return this.count;
  }

  close(): void {
    this.closeCount++;
  }
}

class FakeRdbStore {
  queryCount: number = 0;
  deleteCount: number = 0;
  hasRow: boolean = true;
  count: number = 2;
  throwQuery: boolean = false;
  throwDelete: boolean = false;

  async query(_predicates: relationalStore.RdbPredicates, _columns: string[]): Promise<FakeResultSet> {
    this.queryCount++;
    if (this.throwQuery) {
      throw new Error('query failed');
    }
    return new FakeResultSet(this.hasRow, this.count);
  }

  async delete(_predicates: relationalStore.RdbPredicates): Promise<number> {
    this.deleteCount++;
    if (this.throwDelete) {
      throw new Error('delete failed');
    }
    return this.count;
  }
}

class FakeDbManager implements SyncTaskDbManager {
  hasDataResult: boolean = false;
  hasDataQueue: boolean[] = [];
  queryQueue: SyncData[][] = [];
  rdbStore: FakeRdbStore = new FakeRdbStore();
  initCount: number = 0;
  queryCount: number = 0;
  deleteCount: number = 0;
  insertCount: number = 0;
  executeCount: number = 0;
  updateDataTypeCount: number = 0;
  deleteExpireCount: number = 0;
  updateDataTypeResult: number = 0;
  deleteExpireResult: number = 0;
  throwInit: boolean = false;
  throwQuery: boolean = false;
  throwDelete: boolean = false;
  throwInsert: boolean = false;
  throwExecute: boolean = false;
  throwHasData: boolean = false;
  throwUpdateDataType: boolean = false;
  throwDeleteExpire: boolean = false;
  lastQueryTypes: DataType[] = [];
  lastPageSize: number = 0;
  lastDeleted: SyncData[] = [];
  lastInserted: SyncData[] = [];

  async hasData(dataTypes: DataType[]): Promise<boolean> {
    this.lastQueryTypes = dataTypes;
    if (this.throwHasData) {
      throw new Error('hasData failed');
    }
    if (this.hasDataQueue.length > 0) {
      return this.hasDataQueue.shift() as boolean;
    }
    return this.hasDataResult;
  }

  async updateDataType(_dataType: string, _errorTimeLine: number): Promise<number> {
    this.updateDataTypeCount++;
    if (this.throwUpdateDataType) {
      throw new Error('update failed');
    }
    return this.updateDataTypeResult;
  }

  async deleteExpireCache(_dataType: string, _now: number, _duration: number): Promise<number> {
    this.deleteExpireCount++;
    if (this.throwDeleteExpire) {
      throw new Error('expire failed');
    }
    return this.deleteExpireResult;
  }

  async init(): Promise<void> {
    this.initCount++;
    if (this.throwInit) {
      throw new Error('init failed');
    }
  }

  async queryFtOperation(dataTypes: DataType[], pageSize: number): Promise<SyncData[]> {
    this.queryCount++;
    this.lastQueryTypes = dataTypes;
    this.lastPageSize = pageSize;
    if (this.throwQuery) {
      throw new Error('query failed');
    }
    if (this.queryQueue.length > 0) {
      return this.queryQueue.shift() as SyncData[];
    }
    return [];
  }

  async deleteFtOperation(list: SyncData[]): Promise<void> {
    this.deleteCount++;
    this.lastDeleted = list;
    if (this.throwDelete) {
      throw new Error('delete failed');
    }
  }

  async insertFtOptList(list: SyncData[]): Promise<boolean> {
    this.insertCount++;
    this.lastInserted = list;
    if (this.throwInsert) {
      throw new Error('insert failed');
    }
    return true;
  }

  async executeWithDB(_isWrite: boolean, callback: DataBaseCallBack): Promise<void> {
    this.executeCount++;
    if (this.throwExecute) {
      throw new Error('execute failed');
    }
    await callback.run(this.rdbStore as Object as relationalStore.RdbStore);
  }
}

class FakeHttpResult implements SyncTaskHttpResult {
  private code: number;
  private message: string;
  private errorCode: string;

  constructor(code: number, message: string = 'message', errorCode: string = '') {
    this.code = code;
    this.message = message;
    this.errorCode = errorCode;
  }

  getCode(): number {
    return this.code;
  }

  getMessage(): string {
    return this.message;
  }

  getErrorCode(): string {
    return this.errorCode;
  }
}

class FakeRuntime implements SyncTaskManagerRuntime {
  uploadThreadPool: FakeUploadThreadPool = new FakeUploadThreadPool();
  cachePolicy: FakeCachePolicy = new FakeCachePolicy();
  dbManager: FakeDbManager | null = new FakeDbManager();
  preferences: FakePreferences = new FakePreferences();
  httpResults: FakeHttpResult[] = [];
  randomValues: number[] = [];
  currentTimeMs: number = 1000;
  uuidIndex: number = 0;
  timerId: number = 0;
  timerCallbacks: Map<number, () => void> = new Map();
  sleepDurations: number[] = [];
  debugCount: number = 0;
  infoCount: number = 0;
  warnCount: number = 0;
  errorCount: number = 0;
  initThreadPoolCount: number = 0;
  getPreferencesCount: number = 0;
  executeHttpCount: number = 0;
  lastHttpModel: string = '';
  lastHttpBody: string = '';
  lastHttpPkgId: string = '';
  throwThreadPoolInit: boolean = false;
  throwPreferences: boolean = false;
  throwExecuteHttp: boolean = false;
  throwSleep: boolean = false;
  throwInfo: boolean = false;
  throwDebug: boolean = false;

  getUploadThreadPool(): SyncTaskUploadThreadPool {
    return this.uploadThreadPool;
  }

  initializeThreadPoolManager(): void {
    this.initThreadPoolCount++;
    if (this.throwThreadPoolInit) {
      throw new Error('thread pool failed');
    }
  }

  getDbManager(_context: Context): SyncTaskDbManager | null {
    return this.dbManager;
  }

  getCachePolicy(): SyncTaskCachePolicy {
    return this.cachePolicy;
  }

  getPreferences(_context: Context, _name: string): SyncTaskPreferences {
    this.getPreferencesCount++;
    if (this.throwPreferences) {
      throw new Error('preferences failed');
    }
    return this.preferences;
  }

  async executeHttp(_config: FTSDKConfig, model: string, body: string, pkgId: string): Promise<SyncTaskHttpResult> {
    this.executeHttpCount++;
    this.lastHttpModel = model;
    this.lastHttpBody = body;
    this.lastHttpPkgId = pkgId;
    if (this.throwExecuteHttp) {
      throw new Error('http failed');
    }
    if (this.httpResults.length > 0) {
      return this.httpResults.shift() as FakeHttpResult;
    }
    return new FakeHttpResult(200, 'ok', '');
  }

  getCurrentTimeMs(): number {
    return this.currentTimeMs;
  }

  getRandom(): number {
    if (this.randomValues.length > 0) {
      return this.randomValues.shift() as number;
    }
    return 0.1;
  }

  generateUUID(): string {
    this.uuidIndex++;
    return `runtime-uuid-${this.uuidIndex}`;
  }

  setTimer(callback: () => void, _interval: number): number {
    this.timerId++;
    this.timerCallbacks.set(this.timerId, callback);
    return this.timerId;
  }

  clearTimer(timerId: number): void {
    this.timerCallbacks.delete(timerId);
  }

  async sleep(ms: number): Promise<void> {
    if (this.throwSleep) {
      throw new Error('sleep failed');
    }
    this.sleepDurations.push(ms);
  }

  logDebug(_tag: string, _message: string): void {
    if (this.throwDebug) {
      throw new Error('debug failed');
    }
    this.debugCount++;
  }

  logInfo(_tag: string, _message: string): void {
    if (this.throwInfo) {
      throw new Error('info failed');
    }
    this.infoCount++;
  }

  logWarn(_tag: string, _message: string): void {
    this.warnCount++;
  }

  logError(_tag: string, _message: string): void {
    this.errorCount++;
  }
}

class CaptureCallback implements SyncTaskRequestCallback {
  codes: number[] = [];
  messages: string[] = [];
  errorCodes: string[] = [];

  onResponse(code: number, response: string, errorCode: string): void {
    this.codes.push(code);
    this.messages.push(response);
    this.errorCodes.push(errorCode);
  }
}

export default function syncTaskManagerUnitTest() {
  describe('SyncTaskManagerUnit', () => {
    let runtime: FakeRuntime;
    let manager: SyncTaskManager;

    beforeEach(() => {
      runtime = new FakeRuntime();
      SyncTaskManager.setRuntimeForTest(runtime);
      SyncTaskManager.resetStateForTest();
      manager = SyncTaskManager.getInstance();
    });

    afterEach(() => {
      manager.stop();
      SyncTaskManager.resetRuntimeForTest();
      SyncTaskManager.resetStateForTest();
    });

    it('uploadRunnableAndErrorSampledShouldCoverStopNoDbHasDataAndCatchBranches', 0, async () => {
      const config = createConfig();
      manager.init(config, createContext());

      manager.setStopForTest(true);
      await manager.runUploadRunnableForTest();
      expect(runtime.dbManager!.hasDataResult).assertFalse();

      manager.setStopForTest(false);
      runtime.dbManager = null;
      await manager.errorSampledConsumeForTest(DataType.RUM_APP);
      expect(runtime.warnCount > 0).assertTrue();

      runtime.dbManager = new FakeDbManager();
      runtime.dbManager.hasDataResult = false;
      await manager.runUploadRunnableForTest();
      expect(runtime.dbManager.hasDataQueue.length).assertEqual(0);

      runtime.dbManager.updateDataTypeResult = 1;
      runtime.dbManager.deleteExpireResult = 1;
      manager.setErrorTimeLineForTest(99);
      const updateCountBefore = runtime.dbManager.updateDataTypeCount;
      const deleteExpireCountBefore = runtime.dbManager.deleteExpireCount;
      await manager.errorSampledConsumeForTest(DataType.RUM_WEBVIEW);
      expect(runtime.dbManager.updateDataTypeCount).assertEqual(updateCountBefore + 1);
      expect(runtime.dbManager.deleteExpireCount).assertEqual(deleteExpireCountBefore + 1);

      runtime.dbManager.throwDeleteExpire = true;
      await manager.errorSampledConsumeForTest(DataType.RUM_WEBVIEW);
      expect(runtime.errorCount > 0).assertTrue();

      runtime.dbManager.throwHasData = true;
      await manager.runUploadRunnableForTest();
      expect(runtime.errorCount > 1).assertTrue();
    });

    it('errorTimelineShouldCoverPreferenceMemoryActiveViewAndFailureBranches', 0, async () => {
      manager.setPreferencesStoreForTest(runtime.preferences);
      const view = new ViewBean('view-id', 'view', 100);

      manager.setErrorTimeLine(10, view);
      await flushPromises();
      expect(view.getLastErrorTime()).assertEqual(10);
      expect(runtime.preferences.putCount).assertEqual(1);
      expect(runtime.preferences.flushCount).assertEqual(1);
      expect(await manager.getErrorTimeLine()).assertEqual(10);

      manager.setErrorTimeLine(5, view);
      expect(view.getLastErrorTime()).assertEqual(10);

      manager.setErrorTimeLineForTest(-1);
      runtime.preferences.value = 77;
      expect(await manager.getErrorTimeLine()).assertEqual(77);
      runtime.preferences.value = 'not-number';
      expect(await manager.getErrorTimeLine()).assertEqual(-1);
      runtime.preferences.throwGet = true;
      expect(await manager.getErrorTimeLine()).assertEqual(-1);
      runtime.preferences.throwGet = false;
      runtime.preferences.throwPut = true;
      manager.setErrorTimeLine(88, null);
      await flushPromises();
      expect(runtime.errorCount > 0).assertTrue();
    });

    it('dbAndFormattingHelpersShouldCoverQueryDeleteReinsertPackageAndCacheBranches', 0, async () => {
      manager.setContextForTest(null);
      expect((await manager.queryFromDataForTest(DataType.LOG)).length).assertEqual(0);
      await manager.deleteLastQueryForTest([]);
      await manager.deleteLastQueryForTest([createSyncData(DataType.LOG, 'u', 'line 1')]);
      expect(runtime.warnCount > 0).assertTrue();

      manager.setContextForTest(createContext());
      runtime.dbManager = null;
      expect((await manager.queryFromDataForTest(DataType.LOG)).length).assertEqual(0);

      const db = new FakeDbManager();
      runtime.dbManager = db;
      const data = createSyncData(DataType.LOG, 'log-uuid', 'df_rum_harmonyos_log,sdk_data_id=log-uuid value=1i 100');
      db.queryQueue.push([data]);
      expect((await manager.queryFromDataForTest(DataType.LOG)).length).assertEqual(1);
      expect(db.lastPageSize).assertEqual(manager.getPageSize());

      db.throwQuery = true;
      expect((await manager.queryFromDataForTest(DataType.LOG)).length).assertEqual(0);
      db.throwQuery = false;

      await manager.deleteLastQueryForTest([data]);
      expect(db.deleteCount).assertEqual(1);
      expect(runtime.sleepDurations.includes(30)).assertTrue();
      db.throwDelete = true;
      await manager.deleteLastQueryForTest([data]);
      expect(runtime.errorCount > 0).assertTrue();
      db.throwDelete = false;

      await manager.reInsertDataForTest([data]);
      expect(data.getUuid()).assertEqual('runtime-uuid-1');
      expect(db.insertCount).assertEqual(1);
      db.throwInsert = true;
      await manager.reInsertDataForTest([data]);
      expect(runtime.errorCount > 1).assertTrue();

      expect(manager.formatLineProtocolDataForTest([], 'pkg')).assertEqual('');
      const formatData =
        createSyncData(DataType.LOG, 'format-uuid', 'df_rum_harmonyos_log,sdk_data_id=format-uuid value=1i 100');
      const formatted = manager.formatLineProtocolDataForTest([formatData], 'pkg');
      expect(formatted.includes('pkg.format-uuid')).assertTrue();
      expect(manager.addPackageIdToLineForTest('line', 'pkg')).assertEqual('line');

      runtime.randomValues = [0, 0.5, 0.99, 0.1, 0.2, 0.3, 0.4, 0.6, 0.7, 0.8, 0.9, 0.01];
      expect(manager.generateNanoIdForTest().length).assertEqual(12);
      expect(manager.encodeBase62ForTest(0)).assertEqual('0');
      expect(manager.encodeBase62ForTest(62)).assertEqual('10');
      runtime.currentTimeMs = 12345;
      runtime.randomValues = [0.2];
      expect(manager.getProcessIdForTest()).assertEqual(manager.getProcessIdForTest());

      runtime.cachePolicy.logLimit = 10;
      runtime.cachePolicy.logCount = 5;
      expect(manager.reachHalfLimitForTest()).assertTrue();
      runtime.cachePolicy.logCount = 0;
      runtime.cachePolicy.rumLimit = 10;
      runtime.cachePolicy.rumCount = 5;
      expect(manager.reachHalfLimitForTest()).assertTrue();
      runtime.cachePolicy.rumCount = 1;
      expect(manager.reachHalfLimitForTest()).assertFalse();

      expect(manager.getSeqNumberForTest(DataType.LOG)).assertEqual('0');
      manager.nextGeneratorForTest(DataType.LOG);
      expect(manager.getSeqNumberForTest(DataType.LOG)).assertEqual('1');
      manager.setGeneratorCurrentValueForTest(DataType.RUM_APP, 35);
      expect(manager.generateIdForTest(DataType.RUM_APP)).assertEqual('z');
      manager.setGeneratorCurrentValueForTest(DataType.RUM_APP, Math.pow(36, 8) + 1);
      manager.nextGeneratorForTest(DataType.RUM_APP);
      expect(manager.getSeqNumberForTest(DataType.RUM_APP)).assertEqual('0');
      expect(manager.generatePackageIdForTest('1', 2).split('.').length).assertEqual(4);
      expect(manager.getCurrentNanoTimeForTest()).assertEqual(runtime.currentTimeMs * 1000000);
    });

    it('requestNetShouldCoverModelsSuccessNetworkExceptionAndThrowBranches', 0, async () => {
      const callback = new CaptureCallback();
      let noConfigThrown = false;
      try {
        await manager.requestNetForTest(DataType.LOG, 'pkg', 'body', callback);
      } catch (_error) {
        noConfigThrown = true;
      }
      expect(noConfigThrown).assertTrue();

      manager.setSdkConfigForTest(createConfig());
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));
      await manager.requestNetForTest(DataType.LOG, 'pkg-log', 'log-body', callback);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
      expect(callback.codes[0]).assertEqual(204);

      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.requestNetForTest(DataType.RUM_WEBVIEW, 'pkg-rum',
        `view,${Constants.KEY_RUM_VIEW_IS_WEB_VIEW}=true value=1i 100`, callback);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_RUM);
      expect(callback.codes[1]).assertEqual(200);

      runtime.httpResults.push(new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'network', 'net'));
      await manager.requestNetForTest(DataType.RUM_APP, 'pkg-rum', 'body', callback);
      expect(callback.codes[2]).assertEqual(NetCodeStatus.UNKNOWN_EXCEPTION_CODE);

      runtime.throwExecuteHttp = true;
      await manager.requestNetForTest(DataType.RUM_APP, 'pkg-rum', 'body', callback);
      expect(callback.codes[3]).assertEqual(NetCodeStatus.UNKNOWN_EXCEPTION_CODE);
    });

    it('handleSyncShouldCoverUploadSuccessFailureRetryDiscardAndCallbackBranches', 0, async () => {
      manager.setContextForTest(createContext());
      manager.setSdkConfigForTest(createConfig());
      manager.setPageSizeForTest(2);
      manager.setDataSyncMaxRetryCountForTest(1);
      manager.setSyncSleepTimeForTest(5);
      const db = new FakeDbManager();
      runtime.dbManager = db;

      db.hasDataResult = false;
      await manager.handleSyncOptForTest(DataType.LOG);
      expect(runtime.executeHttpCount).assertEqual(0);

      db.hasDataResult = true;
      runtime.cachePolicy.discard = true;
      db.queryQueue.push([
        createSyncData(DataType.LOG, 'discard-uuid', 'df_rum_harmonyos_log,sdk_data_id=discard-uuid value=1i 100')
      ], []);
      await manager.handleSyncOptForTest(DataType.LOG);
      expect(runtime.warnCount > 0).assertTrue();
      runtime.cachePolicy.discard = false;

      const logOne = createSyncData(DataType.LOG, 'log-1', 'df_rum_harmonyos_log,sdk_data_id=log-1 value=1i 100');
      db.queryQueue.push([logOne]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.handleSyncOptForTest(DataType.LOG);
      expect(db.deleteCount > 0).assertTrue();
      expect(runtime.cachePolicy.logDelta).assertEqual(-1);
      expect(manager.getSeqNumberForTest(DataType.LOG)).assertEqual('1');

      const rumError = createSyncData(DataType.RUM_APP, 'rum-1', 'error,error_type=js,error_message="boom" value=1i 100');
      db.queryQueue.push([rumError], [rumError], [rumError]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'), new FakeHttpResult(500, 'fail', 'server'));
      await manager.handleSyncOptForTest(DataType.RUM_APP);
      expect(runtime.sleepDurations.includes(500)).assertTrue();
      expect(runtime.errorCount > 0).assertTrue();

      db.queryQueue.push([rumError]);
      runtime.throwExecuteHttp = true;
      await manager.handleSyncOptForTest(DataType.RUM_APP);
      expect(runtime.errorCount > 1).assertTrue();

      SyncTaskManager.invokeRequestCallbackForTest(true);
      SyncTaskManager.invokeRequestCallbackForTest(true, true);
      SyncTaskManager.invokeRequestCallbackForTest(false);
    });

    it('rumCleanupShouldCoverTimerCleanupDeleteOldestAndDestroyBranches', 0, async () => {
      const context = createContext();
      SyncTaskManager.initRumCleanupForTest(context);
      expect(runtime.timerCallbacks.size).assertEqual(1);
      SyncTaskManager.initRumCleanupForTest(context);
      expect(runtime.timerCallbacks.size).assertEqual(1);

      runtime.dbManager = new FakeDbManager();
      await SyncTaskManager.performRumCleanupForTest();
      expect(runtime.dbManager.executeCount).assertEqual(2);
      runtime.dbManager.rdbStore.hasRow = false;
      await SyncTaskManager.performRumCleanupForTest();
      expect(runtime.dbManager.executeCount).assertEqual(4);

      runtime.dbManager.throwExecute = true;
      await SyncTaskManager.performRumCleanupForTest();
      expect(runtime.errorCount > 0).assertTrue();
      runtime.dbManager.throwExecute = false;

      SyncTaskManager.setRumCleanupContextForTest(null);
      await SyncTaskManager.performRumCleanupForTest();
      await SyncTaskManager.deleteOldestDataForTest(DataType.LOG, 1);
      expect(runtime.errorCount > 1).assertTrue();

      SyncTaskManager.setRumCleanupContextForTest(context);
      await SyncTaskManager.deleteOldestDataForTest(DataType.LOG, 2);
      await SyncTaskManager.deleteOldestDataForTest(DataType.RUM_APP, 3);
      expect(runtime.cachePolicy.logDelta < 0).assertTrue();
      expect(runtime.cachePolicy.rumDelta < 0).assertTrue();

      runtime.dbManager.rdbStore.throwDelete = true;
      await SyncTaskManager.deleteOldestDataForTest(DataType.RUM_WEBVIEW, 1);
      expect(runtime.errorCount > 2).assertTrue();

      SyncTaskManager.destroyRumCleanupForTest();
      expect(runtime.timerCallbacks.size).assertEqual(0);
      SyncTaskManager.destroyRumCleanupForTest();
    });
  });
}
