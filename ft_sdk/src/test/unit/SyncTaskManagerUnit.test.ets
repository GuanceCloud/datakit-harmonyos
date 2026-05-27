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

    it('initStatusAndPollingShouldCoverConfigContextAndQueueBranches', 0, async () => {
      const sameManager = SyncTaskManager.getInstance();
      expect(sameManager === manager).assertTrue();

      const config = createConfig();
      manager.init(config);
      expect(runtime.cachePolicy.initCount).assertEqual(1);
      expect(runtime.uploadThreadPool.runnable !== null).assertTrue();
      expect(manager.getPageSize()).assertEqual(SyncPageSize.MINI);
      expect(manager.isAutoSyncEnabled()).assertTrue();

      const record = runtime.cachePolicy.lastRecord as SyncTaskConfigRecord;
      expect(record.getDbCacheLimit()).assertEqual(config.getDbCacheLimit());
      expect(record.getLogCacheLimitCount()).assertEqual(config.getLogCacheLimitCount());
      expect(record.getRumCacheLimitCount()).assertEqual(config.getRumCacheLimitCount());
      expect(record.getDBCacheDiscard()).assertEqual(config.getDBCacheDiscard());
      expect(record.getLogCacheDiscard()).assertEqual(config.getLogCacheDiscard());
      expect(record.getRumCacheDiscard()).assertEqual(config.getRumCacheDiscard());
      expect(record.isLimitWithDbSize()).assertFalse();

      runtime.throwThreadPoolInit = true;
      runtime.throwPreferences = true;
      manager.init(config, createContext());
      expect(runtime.errorCount > 0).assertTrue();

      runtime.uploadThreadPool.status.isRunning = true;
      manager.executePoll(false);
      expect(runtime.uploadThreadPool.scheduleDelays.length).assertEqual(0);
      runtime.uploadThreadPool.status.isRunning = false;
      runtime.uploadThreadPool.status.isScheduled = true;
      manager.executePoll(false);
      expect(runtime.uploadThreadPool.scheduleDelays.length).assertEqual(0);
      runtime.uploadThreadPool.status.isScheduled = false;

      manager.setStopForTest(true);
      manager.executePoll(false);
      expect(runtime.uploadThreadPool.scheduleDelays.length).assertEqual(0);

      manager.setStopForTest(false);
      manager.setRunningStateForTest(true, 1);
      runtime.currentTimeMs = 12000;
      manager.executePoll(true);
      expect(runtime.uploadThreadPool.scheduleDelays[0]).assertEqual(2000);

      manager.setRunning(false);
      manager.setAutoSync(false);
      manager.setAutoSync(true);
      manager.setAutoSync(false);
      manager.resume();
      const status = manager.getStatus();
      expect(status.autoSync).assertFalse();
      expect(manager.getSyncSleepTime()).assertEqual(config.getSyncSleepTime());
      expect(runtime.uploadThreadPool.setRunningValues.length).assertEqual(1);
      manager.triggerImmediateUpload();
      expect(runtime.uploadThreadPool.scheduleDelays[runtime.uploadThreadPool.scheduleDelays.length - 1]).assertEqual(0);
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

    it('dedupeAndIdHelpersShouldCoverBusinessIdsFallbacksAndSetLimits', 0, () => {
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'action,action_id=a1 value=1i 100'))
        .assertEqual('action_id=a1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view,view_id=v1,view_update_time=2 value=1i 100'))
        .assertEqual('view_id=v1:view_update_time=2');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view,view_id=v1 value=1i 100')).assertEqual('view_id=v1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,span_id=s1 value=1i 100')).assertEqual('span_id=s1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,trace_id=t1 value=1i 100')).assertEqual('trace_id=t1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,error_type=js,error_message="boom" value=1i 100'))
        .assertEqual('error_type=js:error_message=boom:timestamp=100');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,long_task_name=lt value=1i 100'))
        .assertEqual('long_task_name=lt:timestamp=100');
      expect(manager.extractUniqueIdForTest(DataType.LOG,
        'df_rum_harmonyos_log,sdk_data_id=abc.123e4567-e89b-12d3-a456-426614174000 value=1i 100'))
        .assertEqual('uuid=123e4567-e89b-12d3-a456-426614174000');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'df_rum_harmonyos_log,sdk_data_id=plain-id value=1i 100'))
        .assertEqual('sdk_data_id=plain-id');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'unknown value=1i 101')).assertEqual('timestamp=101');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'unknown value=1i')).assertNull();
      expect(manager.hashStringForTest('')).assertEqual('0');
      expect(manager.hashStringForTest('abc').length > 0).assertTrue();

      const one = createSyncData(DataType.RUM_APP, 'uuid-1', 'action,action_id=a1 value=1i 100');
      const duplicate = createSyncData(DataType.RUM_APP, 'uuid-2', 'action,action_id=a1 value=2i 101');
      const uuidOnly = createSyncData(DataType.RUM_APP, 'uuid-3', 'no_timestamp');
      const hashOnly = createSyncData(DataType.RUM_APP, '', 'no_timestamp');
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [one, duplicate, uuidOnly, hashOnly]).length).assertEqual(3);

      manager.markDataAsUploadingForTest(DataType.RUM_APP, [one]);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [one]).length).assertEqual(0);
      manager.unmarkDataAsUploadingForTest(DataType.RUM_APP, [one]);
      manager.markDataAsUploadedForTest(DataType.RUM_APP, [one]);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [one]).length).assertEqual(0);
      expect(manager.getUploadedDataIdCountForTest()).assertEqual(1);

      for (let i = 0; i <= Constants.MAX_SET_SIZE_UPLOAD; i++) {
        manager.addUploadedDataIdForTest(`log:uuid=${i}`);
        manager.addUploadingDataIdForTest(`log:uploading=${i}`);
      }
      manager.markDataAsUploadedForTest(DataType.LOG, [
        createSyncData(DataType.LOG, 'final', 'df_rum_harmonyos_log,sdk_data_id=final value=1i 200')
      ]);
      expect(manager.getUploadedDataIdCountForTest() <= Constants.MAX_SET_SIZE_UPLOAD).assertTrue();
      expect(manager.getUploadingDataIdCountForTest()).assertEqual(0);
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

    it('remainingBranchesShouldCoverAutoSyncRumSuccessFallbacksAndNoDbCleanup', 0, async () => {
      await manager.runUploadRunnableForTest();

      manager.setAutoSyncForTest(false);
      manager.executeSyncPoll();
      expect(runtime.uploadThreadPool.scheduleDelays.length).assertEqual(0);
      manager.setAutoSyncForTest(true);
      manager.executeSyncPoll();
      expect(runtime.uploadThreadPool.scheduleDelays.length).assertEqual(1);
      manager.setErrorCountForTest(3);
      expect(manager.getStatus().errorCount).assertEqual(3);

      manager.setContextForTest(null);
      await manager.errorSampledConsumeForTest(DataType.RUM_APP);

      manager.setPreferencesStoreForTest(null);
      manager.setErrorTimeLineForTest(-1);
      manager.setErrorTimeLine(1, null);
      expect(await manager.getErrorTimeLine()).assertEqual(1);
      manager.setErrorTimeLineForTest(-1);
      expect(await manager.getErrorTimeLine()).assertEqual(-1);

      await manager.handleSyncOptForTest(DataType.LOG);
      manager.setContextForTest(createContext());
      runtime.dbManager = null;
      await manager.handleSyncOptForTest(DataType.LOG);

      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'action value=1i 1')).assertEqual('timestamp=1');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view value=1i 2')).assertEqual('timestamp=2');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource value=1i 3')).assertEqual('timestamp=3');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error value=1i')).assertNull();
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask value=1i')).assertNull();
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'df_rum_harmonyos_log value=1i 4')).assertEqual('timestamp=4');

      const uuidFallback = createSyncData(DataType.RUM_APP, 'uuid-fallback', 'no_timestamp');
      manager.markDataAsUploadingForTest(DataType.RUM_APP, [uuidFallback]);
      manager.unmarkDataAsUploadingForTest(DataType.RUM_APP, [uuidFallback]);
      manager.markDataAsUploadedForTest(DataType.RUM_APP, [uuidFallback]);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [uuidFallback]).length).assertEqual(0);

      const uuidUploading = createSyncData(DataType.RUM_APP, 'uuid-uploading', 'no_timestamp');
      manager.markDataAsUploadingForTest(DataType.RUM_APP, [uuidUploading]);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [uuidUploading]).length).assertEqual(0);
      manager.unmarkDataAsUploadingForTest(DataType.RUM_APP, [uuidUploading]);
      const uuidDuplicateA = createSyncData(DataType.RUM_APP, 'uuid-duplicate', 'no_timestamp');
      const uuidDuplicateB = createSyncData(DataType.RUM_APP, 'uuid-duplicate', 'no_timestamp');
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [uuidDuplicateA, uuidDuplicateB]).length).assertEqual(1);

      const hashUploaded = createSyncData(DataType.RUM_APP, '', 'hash_no_time');
      manager.addUploadedDataIdForTest(`${DataType.RUM_APP}:hash=${manager.hashStringForTest('hash_no_time')}`);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [hashUploaded]).length).assertEqual(0);
      const hashUploading = createSyncData(DataType.RUM_APP, '', 'hash_uploading');
      manager.addUploadingDataIdForTest(`${DataType.RUM_APP}:hash=${manager.hashStringForTest('hash_uploading')}`);
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [hashUploading]).length).assertEqual(0);
      const hashDuplicateA = createSyncData(DataType.RUM_APP, '', 'hash_duplicate');
      const hashDuplicateB = createSyncData(DataType.RUM_APP, '', 'hash_duplicate');
      expect(manager.deduplicateDataForTest(DataType.RUM_APP, [hashDuplicateA, hashDuplicateB]).length).assertEqual(1);

      await manager.deleteLastQueryForTest([createSyncData(DataType.LOG, 'no-db', 'line 1')]);
      manager.setContextForTest(null);
      await manager.reInsertDataForTest([createSyncData(DataType.LOG, 'no-context', 'line 1')]);
      manager.setContextForTest(createContext());

      manager.setSdkConfigForTest(createConfig());
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      const webViewCallback = new CaptureCallback();
      await manager.requestNetForTest(DataType.RUM_WEBVIEW, 'pkg-web', 'view,value=1i 1', webViewCallback);
      expect(webViewCallback.codes[0]).assertEqual(200);

      runtime.dbManager = new FakeDbManager();
      const db = runtime.dbManager;
      manager.setPageSizeForTest(2);
      manager.setSyncSleepTimeForTest(7);
      const rumOne = createSyncData(DataType.RUM_APP, 'rum-view', 'view,view_id=rum-view value=1i 100');
      const rumTwo = createSyncData(DataType.RUM_APP, 'rum-action', 'action,action_id=rum-action value=1i 101');
      db.hasDataResult = true;
      db.queryQueue.push([rumOne, rumTwo], []);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.handleSyncOptForTest(DataType.RUM_APP);
      expect(runtime.cachePolicy.rumDelta).assertEqual(-2);
      expect(runtime.sleepDurations.includes(7)).assertTrue();
      expect(manager.getSeqNumberForTest(DataType.RUM_APP)).assertEqual('1');

      const rumThree = createSyncData(DataType.RUM_WEBVIEW, 'rum-web', 'view,view_id=rum-web value=1i 102');
      db.queryQueue.push([rumThree]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));
      await manager.handleSyncOptForTest(DataType.RUM_WEBVIEW);
      expect(manager.getSeqNumberForTest(DataType.RUM_WEBVIEW)).assertEqual('1');

      const retryData = createSyncData(DataType.RUM_APP, 'retry-error', 'error,error_type=js value=1i 200');
      db.queryQueue.push([retryData]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      runtime.throwSleep = true;
      await manager.handleSyncOptForTest(DataType.RUM_APP);
      runtime.throwSleep = false;
      expect(runtime.errorCount > 0).assertTrue();

      const outerCatchData = createSyncData(DataType.LOG, 'outer-catch', 'df_rum_harmonyos_log,sdk_data_id=outer-catch value=1i 300');
      db.queryQueue.push([outerCatchData]);
      manager.setErrorCountForTest(4);
      runtime.throwInfo = true;
      await manager.handleSyncOptForTest(DataType.LOG);
      runtime.throwInfo = false;
      expect(manager.getStatus().errorCount).assertEqual(5);

      manager.setGeneratorCurrentValueForTest(DataType.LOG, 2);
      expect(manager.generateIdForTest(DataType.LOG)).assertEqual('2');

      const blankData = createSyncData(DataType.LOG, 'blank', '');
      expect(manager.formatLineProtocolDataForTest([blankData], 'pkg')).assertEqual('');
      const noSdkData = createSyncData(DataType.LOG, 'not-in-line', 'plain value=1i 1');
      expect(manager.formatLineProtocolDataForTest([noSdkData], 'pkg')).assertEqual('plain value=1i 1');

      SyncTaskManager.initRumCleanupForTest(createContext());
      const callbacks = Array.from(runtime.timerCallbacks.values());
      expect(callbacks.length > 0).assertTrue();
      callbacks[0]();
      await flushPromises();

      runtime.dbManager = null;
      await SyncTaskManager.performRumCleanupForTest();
      await SyncTaskManager.deleteOldestDataForTest(DataType.RUM_WEBVIEW, 1);
    });

    it('tailBranchesShouldCoverRumSummaryFailureRetryAndExtractorFallbacks', 0, async () => {
      const config = createConfig();
      manager.init(config, createContext());
      manager.setSdkConfigForTest(config);
      manager.setPageSizeForTest(1);
      manager.setSyncSleepTimeForTest(0);
      manager.setDataSyncMaxRetryCountForTest(0);

      runtime.dbManager = new FakeDbManager();
      const db = runtime.dbManager;
      db.hasDataResult = true;

      const noSummaryRum = createSyncData(DataType.RUM_APP, 'rum-summary-empty', 'rum_measurement value=1i 501');
      db.queryQueue.push([noSummaryRum], []);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      const sleepCountBefore = runtime.sleepDurations.length;
      await manager.handleSyncOptForTest(DataType.RUM_APP);
      expect(runtime.sleepDurations.length).assertEqual(sleepCountBefore + 1);
      expect(runtime.sleepDurations[runtime.sleepDurations.length - 1]).assertEqual(30);

      const logFailure =
        createSyncData(DataType.LOG, 'tail-log-failure', 'df_rum_harmonyos_log,sdk_data_id=tail-log-failure value=1i 502');
      db.queryQueue.push([logFailure]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      manager.setErrorCountForTest(0);
      await manager.handleSyncOptForTest(DataType.LOG);

      const rumCleanFailure = createSyncData(DataType.RUM_APP, 'rum-clean', 'view,view_id=rum-clean value=1i 503');
      db.queryQueue.push([rumCleanFailure]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      manager.setErrorCountForTest(0);
      await manager.handleSyncOptForTest(DataType.RUM_APP);

      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,foo=bar value=1i')).assertNull();
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,foo=bar value=1i')).assertNull();
    });

    it('remainingEdgeBranchesShouldCoverRunnableCallbackIdsAndCleanupCatch', 0, async () => {
      const config = createConfig();
      manager.init(config, createContext());
      expect(runtime.uploadThreadPool.runnable !== null).assertTrue();

      manager.setStopForTest(true);
      const wrapper = runtime.uploadThreadPool.runnable as () => void;
      wrapper();
      await flushPromises();
      manager.setStopForTest(false);
      manager.clearUploadRunnableForTest();
      wrapper();
      await flushPromises();

      manager.init(config, createContext());
      manager.setAutoSyncForTest(false);
      manager.setContextForTest(null);
      await manager.runUploadRunnableForTest();

      manager.setContextForTest(createContext());
      runtime.dbManager = null;
      await manager.runUploadRunnableForTest();

      runtime.dbManager = new FakeDbManager();
      const db = runtime.dbManager;
      db.hasDataQueue = [false, true, false, false, false, false, false, false];
      await manager.runUploadRunnableForTest();

      const errorCountBeforeHasDataFailure = runtime.errorCount;
      db.throwHasData = true;
      await manager.runUploadRunnableForTest();
      db.throwHasData = false;
      expect(runtime.errorCount > errorCountBeforeHasDataFailure).assertTrue();

      db.updateDataTypeResult = 0;
      manager.setErrorTimeLineForTest(101);
      await manager.errorSampledConsumeForTest(DataType.RUM_APP);

      manager.setSdkConfigForTest(config);
      manager.setPageSizeForTest(10);
      db.hasDataQueue = [];
      db.hasDataResult = true;
      const duplicateA =
        createSyncData(DataType.LOG, 'dup-a', 'df_rum_harmonyos_log,sdk_data_id=dup-id value=1i 301');
      const duplicateB =
        createSyncData(DataType.LOG, 'dup-b', 'df_rum_harmonyos_log,sdk_data_id=dup-id value=2i 302');
      db.queryQueue.push([duplicateA, duplicateB]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      const warnCountBeforeDuplicate = runtime.warnCount;
      await manager.handleSyncOptForTest(DataType.LOG);
      expect(runtime.warnCount > warnCountBeforeDuplicate).assertTrue();

      manager.setPageSizeForTest(1);
      manager.setSyncSleepTimeForTest(0);
      const noSleepData =
        createSyncData(DataType.LOG, 'no-sleep', 'df_rum_harmonyos_log,sdk_data_id=no-sleep value=1i 303');
      db.queryQueue.push([noSleepData], []);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.handleSyncOptForTest(DataType.LOG);

      manager.setPageSizeForTest(10);
      const noSummaryRum = createSyncData(DataType.RUM_APP, 'rum-no-summary', 'rum_measurement value=1i 304');
      db.queryQueue.push([noSummaryRum]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.handleSyncOptForTest(DataType.RUM_APP);

      const callbackCatchData =
        createSyncData(DataType.LOG, 'callback-catch', 'df_rum_harmonyos_log,sdk_data_id=callback-catch value=1i 305');
      db.queryQueue.push([callbackCatchData], []);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      runtime.cachePolicy.throwOptLogCount = true;
      manager.setErrorCountForTest(0);
      const errorCountBeforeCallbackCatch = runtime.errorCount;
      await manager.handleSyncOptForTest(DataType.LOG);
      runtime.cachePolicy.throwOptLogCount = false;
      expect(runtime.errorCount > errorCountBeforeCallbackCatch).assertTrue();

      const unknownType = 'unknown' as Object as DataType;
      const unknownData = createSyncData(unknownType, 'unknown-uuid', 'unknown value=1i 306');
      db.queryQueue.push([unknownData]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));
      await manager.handleSyncOptForTest(unknownType);

      const rumNoErrorFailure = createSyncData(DataType.RUM_APP, 'rum-clean-old', 'view,view_id=rum-clean-old value=1i 307');
      db.queryQueue.push([rumNoErrorFailure]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      manager.setErrorCountForTest(0);
      manager.setDataSyncMaxRetryCountForTest(0);
      await manager.handleSyncOptForTest(DataType.RUM_APP);

      const logFailure =
        createSyncData(DataType.LOG, 'log-failure', 'df_rum_harmonyos_log,sdk_data_id=log-failure value=1i 308');
      db.queryQueue.push([logFailure]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      manager.setErrorCountForTest(0);
      await manager.handleSyncOptForTest(DataType.LOG);

      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'action,foo=bar value=1i 401')).assertEqual('timestamp=401');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'view,foo=bar value=1i 402')).assertEqual('timestamp=402');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'resource,foo=bar value=1i 403')).assertEqual('timestamp=403');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,error_message="boom" value=1i'))
        .assertEqual('error_type=:error_message=boom:timestamp=');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error,error_type=js value=1i'))
        .assertEqual('error_type=js:error_message=:timestamp=');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'error value=1i 404')).assertEqual('timestamp=404');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,foo=bar value=1i 405'))
        .assertEqual('long_task_name=:timestamp=405');
      expect(manager.extractUniqueIdForTest(DataType.RUM_APP, 'longtask,long_task_name=lt value=1i'))
        .assertEqual('long_task_name=lt:timestamp=');
      expect(manager.extractUniqueIdForTest(DataType.LOG, 'df_rum_harmonyos_log,foo=bar value=1i 406'))
        .assertEqual('timestamp=406');
      const badLine = new Object() as Object as string;
      expect(manager.extractUniqueIdForTest(DataType.LOG, badLine)).assertNull();

      runtime.dbManager = null;
      manager.setContextForTest(createContext());
      const noDbReinsert = createSyncData(DataType.LOG, 'no-db-reinsert', 'line value=1i 407');
      await manager.reInsertDataForTest([noDbReinsert]);
      expect(noDbReinsert.getUuid()).assertEqual('runtime-uuid-1');

      runtime.dbManager = new FakeDbManager();
      SyncTaskManager.initRumCleanupForTest(createContext());
      runtime.throwDebug = true;
      await SyncTaskManager.performRumCleanupForTest();
      runtime.throwDebug = false;
      await SyncTaskManager.deleteOldestDataForTest(unknownType, 1);
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
