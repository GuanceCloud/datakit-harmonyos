import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { SyncData } from '../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../main/ets/components/db/bean/ViewBean';
import {
  FTDBTaskPoolMaintenanceResponse,
  FTDBTaskPoolUploadPage,
  FTDBTaskPoolUploadCommitResponse
} from '../../main/ets/components/db/FTDBTaskPoolExecutor';
import { DataType, SyncPageSize } from '../../main/ets/components/enum/Enums';
import { NetCodeStatus } from '../../main/ets/components/http/HttpEngine';
import { SyncTaskManager } from '../../main/ets/components/SyncTaskManager';
import {
  SyncTaskCachePolicy,
  SyncTaskConfigRecord,
  SyncTaskDbTaskPool,
  SyncTaskManagerRuntime,
  SyncTaskPreferences
} from '../../main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKDataUploadWorkerRequest,
  handleSDKWorkerRequest,
  SDKUploadWorkerHttpExecutor,
  SDKWorkerRuntimeState
} from '../../main/ets/components/thread/SDKWorkerBusinessHandlers';
import {
  SDKDedicatedPoolType,
  SDKUploadRowDTO,
  SDKUploadHttpRequestDTO,
  SDKUploadHttpResultDTO,
  SDKWorkerCommand,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../../main/ets/components/thread/SDKWorkerProtocol';
import { DATA_UPLOAD_TRANSPORT_TARGET_BYTES } from '../../main/ets/components/thread/workers/DataUploadLimits';
import {
  DataUploadPayloadCompressor,
  resetDataUploadPayloadCompressorInternal,
  setDataUploadPayloadCompressorInternal
} from '../../main/ets/components/thread/workers/DataUploadCompression';

const TEST_URL = 'http://localhost';

function createContext(): Context {
  return new Object() as Context;
}

class FixedPayloadCompressor implements DataUploadPayloadCompressor {
  async compress(_body: string): Promise<ArrayBuffer> {
    const payload = new ArrayBuffer(4);
    const bytes = new Uint8Array(payload);
    bytes[0] = 0x78;
    bytes[1] = 0x9c;
    bytes[2] = 0x01;
    bytes[3] = 0x00;
    return payload;
  }
}

function createConfig(autoSync: boolean = true): FTSDKConfig {
  return FTSDKConfig.builder(TEST_URL)
    .setAutoSync(autoSync)
    .setSyncPageSize(SyncPageSize.MINI)
    .setDataSyncRetryCount(2)
    .setSyncSleepTime(1);
}

function createSyncData(dataType: DataType, uuid: string, dataString: string, time: number = 100): SyncData {
  const data = new SyncData(dataType);
  data.setUuid(uuid);
  data.setDataString(dataString);
  data.setTime(time);
  return data;
}

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    await Promise.resolve();
  }
}

async function waitUntil(condition: () => boolean): Promise<void> {
  for (let i = 0; i < 100; i++) {
    await Promise.resolve();
    if (condition()) {
      return;
    }
  }
  throw new Error('Timed out waiting for the expected test state');
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

class FakeDbTaskPool implements SyncTaskDbTaskPool {
  errorTimeLine: number = -1;
  getErrorTimeLineCount: number = 0;
  updateErrorTimeLineCount: number = 0;
  hasDataResult: boolean = false;
  hasDataQueue: boolean[] = [];
  queryQueue: SyncData[][] = [];
  initCount: number = 0;
  queryCount: number = 0;
  deleteCount: number = 0;
  insertCount: number = 0;
  hasDataCount: number = 0;
  updateDataTypeCount: number = 0;
  deleteExpireCount: number = 0;
  updateDataTypeResult: number = 0;
  deleteExpireResult: number = 0;
  throwInit: boolean = false;
  throwQuery: boolean = false;
  throwDelete: boolean = false;
  deleteAffectedRowsOverride: number = -1;
  throwInsert: boolean = false;
  throwHasData: boolean = false;
  throwUpdateDataType: boolean = false;
  throwDeleteExpire: boolean = false;
  lastQueryTypes: string[] = [];
  lastPageSize: number = 0;
  lastUploadMaxBytes: number = 0;
  lastDeleted: SyncData[] = [];
  lastDeletedIds: number[] = [];
  deletedUuidBatches: string[][] = [];
  lastInserted: SyncData[] = [];
  insertReInsertFlags: boolean[] = [];

  async getLastErrorTimeLine(_context: Context): Promise<number> {
    this.getErrorTimeLineCount++;
    return this.errorTimeLine;
  }

  async updateLastErrorTimeLine(_context: Context, errorTimeLine: number): Promise<void> {
    this.updateErrorTimeLineCount++;
    this.errorTimeLine = Math.max(this.errorTimeLine, errorTimeLine);
  }

  async hasSyncData(_context: Context, dataTypes: string[]): Promise<boolean> {
    this.hasDataCount++;
    this.lastQueryTypes = dataTypes;
    if (this.throwHasData) {
      throw new Error('hasData failed');
    }
    if (this.hasDataQueue.length > 0) {
      return this.hasDataQueue.shift() as boolean;
    }
    return this.hasDataResult;
  }

  async simulateUpdateDataType(_dataType: string, _errorTimeLine: number): Promise<number> {
    this.updateDataTypeCount++;
    if (this.throwUpdateDataType) {
      throw new Error('update failed');
    }
    return this.updateDataTypeResult;
  }

  async simulateDeleteExpireCache(_dataType: string, _now: number, _duration: number): Promise<number> {
    this.deleteExpireCount++;
    if (this.throwDeleteExpire) {
      throw new Error('expire failed');
    }
    return this.deleteExpireResult;
  }

  async maintainErrorSampled(
    _context: Context,
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<FTDBTaskPoolMaintenanceResponse> {
    const updatedRows = await this.simulateUpdateDataType(dataType, errorTimeLine);
    const deletedRows = await this.simulateDeleteExpireCache(dataType, now, duration);
    return {
      updatedRows,
      deletedRows,
      dbLaneWaitMs: 0
    };
  }

  async init(): Promise<void> {
    this.initCount++;
    if (this.throwInit) {
      throw new Error('init failed');
    }
  }

  async querySyncData(
    _context: Context,
    dataTypes: string[],
    pageSize: number,
    _newestFirst?: boolean
  ): Promise<SyncData[]> {
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

  async queryUploadData(
    context: Context,
    dataTypes: string[],
    pageSize: number,
    maxBytes: number
  ): Promise<FTDBTaskPoolUploadPage> {
    this.lastUploadMaxBytes = maxBytes;
    const storedRows = await this.querySyncData(context, dataTypes, pageSize);
    const rows: SDKUploadRowDTO[] = [];
    let transportBytes = 0;
    let byteLimitReached = false;
    for (let i = 0; i < storedRows.length; i++) {
      const stored = storedRows[i];
      const row: SDKUploadRowDTO = {
        id: stored.getId(),
        dataType: stored.getDataType().toString(),
        dataString: stored.getDataString(),
        uuid: stored.getUuid(),
        time: stored.getTime()
      };
      const customDataType = stored.getCustomDataTypeString();
      if (customDataType && customDataType.length > 0) {
        row.customDataType = customDataType;
      }
      const rowBytes = this.estimateUploadTransportRowBytes(row);
      const exceedsBatchTarget = transportBytes + rowBytes > maxBytes;
      if (exceedsBatchTarget && rows.length > 0) {
        byteLimitReached = true;
        break;
      }
      rows.push(row);
      transportBytes += rowBytes;
      if (exceedsBatchTarget) {
        byteLimitReached = true;
        break;
      }
    }
    return {
      rows,
      hasMore: byteLimitReached || storedRows.length >= pageSize,
      transportBytes,
      byteLimitReached
    };
  }

  private estimateUploadTransportRowBytes(row: SDKUploadRowDTO): number {
    return this.getUtf8ByteLength(row.dataString || '') + this.getUtf8ByteLength(row.uuid || '') +
      this.getUtf8ByteLength(row.dataType || '') + this.getUtf8ByteLength(row.customDataType || '') + 64;
  }

  private getUtf8ByteLength(value: string): number {
    let bytes = 0;
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code <= 0x7f) {
        bytes++;
      } else if (code <= 0x7ff) {
        bytes += 2;
      } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
        const next = value.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          bytes += 4;
          i++;
        } else {
          bytes += 3;
        }
      } else {
        bytes += 3;
      }
    }
    return bytes;
  }

  async deleteSyncRows(_context: Context, list: SyncData[]): Promise<number> {
    this.deleteCount++;
    this.lastDeleted = list;
    this.deletedUuidBatches.push(list.map((row: SyncData) => row.getUuid()));
    if (this.throwDelete) {
      throw new Error('delete failed');
    }
    return this.deleteAffectedRowsOverride >= 0 ? this.deleteAffectedRowsOverride : list.length;
  }

  async insertSyncRows(list: SyncData[], reInsert?: boolean): Promise<boolean> {
    this.insertCount++;
    this.lastInserted = list;
    this.insertReInsertFlags.push(reInsert === true);
    if (this.throwInsert) {
      throw new Error('insert failed');
    }
    return true;
  }

  async uploadCommit(
    context: Context,
    dataType: string,
    action: string,
    records: SyncData[],
    reInsertRecords: SyncData[],
    reduceCount: number
  ): Promise<FTDBTaskPoolUploadCommitResponse> {
    let deletedRows = 0;
    let insertedRows = 0;
    if (records && records.length > 0) {
      deletedRows = await this.deleteSyncRows(context, records);
    }
    if (action === 'reinsert' && reInsertRecords && reInsertRecords.length > 0) {
      await this.insertSyncRows(reInsertRecords, true);
      insertedRows = reInsertRecords.length;
    }
    return {
      deletedRows,
      insertedRows,
      affectedRows: deletedRows + insertedRows,
      logCountDelta: dataType === DataType.LOG.toString() ? -reduceCount : 0,
      rumCountDelta: dataType === DataType.LOG.toString() ? 0 : -reduceCount,
      dbLaneWaitMs: 0
    };
  }

  async cleanupExpiredRumView(_context: Context, _cutoffTime: number): Promise<number> {
    return 0;
  }

  async cleanupExpiredRumAction(_context: Context, _cutoffTime: number): Promise<number> {
    return 0;
  }
}

class FakeHttpResult implements SDKUploadHttpResultDTO {
  code: number;
  message: string;
  errorCode: string;
  elapsedMs: number = 1;
  softTimedOut: boolean = false;

  constructor(code: number, message: string = 'message', errorCode: string = '') {
    this.code = code;
    this.message = message;
    this.errorCode = errorCode;
  }

}

class FakeRuntime implements SyncTaskManagerRuntime, SDKUploadWorkerHttpExecutor {
  cachePolicy: FakeCachePolicy = new FakeCachePolicy();
  dbTaskPool: FakeDbTaskPool = new FakeDbTaskPool();
  preferences: FakePreferences = new FakePreferences();
  httpResults: FakeHttpResult[] = [];
  randomValues: number[] = [];
  currentTimeMs: number = 1000;
  uuidIndex: number = 0;
  timerId: number = 0;
  timerCallbacks: Map<number, () => void> = new Map();
  sleepDurations: number[] = [];
  getPreferencesCount: number = 0;
  executeHttpCount: number = 0;
  httpModels: string[] = [];
  httpBodies: string[] = [];
  lastHttpModel: string = '';
  lastHttpBody: string = '';
  lastHttpPkgId: string = '';
  lastHttpDatakitUrl: string = '';
  lastHttpDatawayUrl: string = '';
  lastHttpClientToken: string = '';
  lastHttpCompressedBody: ArrayBuffer | undefined = undefined;
  lastHttpContentEncoding: string = '';
  httpBarrier: Promise<void> | null = null;
  throwPreferences: boolean = false;
  throwExecuteHttp: boolean = false;
  throwSleep: boolean = false;
  uploadWorkerCommands: string[] = [];
  uploadWorkerState: SDKWorkerRuntimeState = createSDKWorkerRuntimeStateWithBackend(
    SDKDedicatedPoolType.DATA_UPLOAD,
    'DataUploadUnitWorker',
    'unit-worker'
  );

  getDbTaskPool(): SyncTaskDbTaskPool {
    return this.dbTaskPool;
  }

  getCachePolicy(): SyncTaskCachePolicy {
    return this.cachePolicy;
  }

  async getPreferences(_context: Context, _name: string): Promise<SyncTaskPreferences> {
    this.getPreferencesCount++;
    if (this.throwPreferences) {
      throw new Error('preferences failed');
    }
    return this.preferences;
  }

  async execute(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO> {
    this.executeHttpCount++;
    this.httpModels.push(request.model);
    this.httpBodies.push(request.body);
    this.lastHttpModel = request.model;
    this.lastHttpBody = request.body;
    this.lastHttpPkgId = request.packageId;
    this.lastHttpDatakitUrl = request.datakitUrl;
    this.lastHttpDatawayUrl = request.datawayUrl;
    this.lastHttpClientToken = request.clientToken;
    this.lastHttpCompressedBody = request.compressedBody;
    this.lastHttpContentEncoding = request.contentEncoding ?? '';
    if (this.throwExecuteHttp) {
      throw new Error('http failed');
    }
    if (this.httpBarrier) {
      await this.httpBarrier;
    }
    if (this.httpResults.length > 0) {
      return this.httpResults.shift() as FakeHttpResult;
    }
    return new FakeHttpResult(200, 'ok', '');
  }

  async executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    this.uploadWorkerCommands.push(request.command);
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE) {
      return await handleSDKDataUploadWorkerRequest(request, this.uploadWorkerState, this);
    }
    return handleSDKWorkerRequest(request, this.uploadWorkerState);
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

  setTimer(callback: () => void, interval: number): number {
    this.timerId++;
    const id = this.timerId;
    this.timerCallbacks.set(id, callback);
    if (interval === 0) {
      Promise.resolve().then(() => {
        const scheduled = this.timerCallbacks.get(id);
        if (scheduled) {
          scheduled();
        }
      });
    }
    return id;
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
}

async function runScheduledUpload(runtime: FakeRuntime): Promise<void> {
  for (let i = 0; i < 100; i++) {
    // Let the complete Worker/DB Promise chain settle before observing the
    // lane. A fixed number of microtasks can return halfway through a commit.
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 0);
    });
    const uploadStatus = SyncTaskManager.getInstance().getStatus().uploadLaneStatus;
    if (uploadStatus.isScheduled && uploadStatus.scheduledDelay > 0) {
      // A running upload can schedule a delayed follow-up after this helper
      // starts. Advance that fake timer as well as the initial upload timer.
      const delayedUpload = runtime.timerCallbacks.get(runtime.timerId);
      if (!delayedUpload) {
        throw new Error('Scheduled upload has no fake timer callback');
      }
      delayedUpload();
      continue;
    }
    if (!uploadStatus.isScheduled && !uploadStatus.isRunning && !uploadStatus.needReschedule) {
      await flushPromises();
      const latestUploadStatus = SyncTaskManager.getInstance().getStatus().uploadLaneStatus;
      if (!latestUploadStatus.isScheduled && !latestUploadStatus.isRunning && !latestUploadStatus.needReschedule) {
        return;
      }
    }
  }
  throw new Error('Timed out waiting for the upload lane to become idle');
}

async function runCleanupTimer(runtime: FakeRuntime): Promise<void> {
  const callback = runtime.timerCallbacks.get(runtime.timerId);
  if (callback) {
    callback();
    await flushPromises();
  }
}

function createLineProtocolForType(dataType: DataType, uuid: string, time: number): string {
  if (dataType === DataType.LOG) {
    return `df_rum_harmonyos_log,sdk_data_id=${uuid} message="${uuid}",value=1i ${time}`;
  }
  if (dataType === DataType.RUM_WEBVIEW) {
    return `view,sdk_data_id=${uuid},view_id=${uuid},view_update_time=${time},is_webview=true value=1i ${time}`;
  }
  return `view,sdk_data_id=${uuid},view_id=${uuid},view_update_time=${time} value=1i ${time}`;
}

function createBatchSyncData(dataType: DataType, prefix: string, count: number, startTime: number = 100): SyncData[] {
  const list: SyncData[] = [];
  for (let i = 0; i < count; i++) {
    const uuid = `${prefix}-${i}`;
    list.push(createSyncData(dataType, uuid, createLineProtocolForType(dataType, uuid, startTime + i), startTime + i));
  }
  return list;
}

function queueUploadRowsForOnly(db: FakeDbTaskPool, dataType: DataType, rows: SyncData[]): void {
  if (dataType === DataType.RUM_APP) {
    db.queryQueue.push(rows, [], []);
    return;
  }
  if (dataType === DataType.RUM_WEBVIEW) {
    db.queryQueue.push([], rows, []);
    return;
  }
  db.queryQueue.push([], [], rows);
}

async function runSingleBatchUpload(
  manager: SyncTaskManager,
  runtime: FakeRuntime,
  db: FakeDbTaskPool,
  dataType: DataType,
  uuid: string,
  code: number
): Promise<void> {
  queueUploadRowsForOnly(db, dataType, [
    createSyncData(dataType, uuid, createLineProtocolForType(dataType, uuid, 100))
  ]);
  runtime.httpResults.push(new FakeHttpResult(code, `response-${code}`, `error-${code}`));

  manager.executePoll(false);
  await runScheduledUpload(runtime);
}

function getBackoffDurations(runtime: FakeRuntime): number[] {
  return runtime.sleepDurations.filter((duration: number) => duration >= 500);
}

export default function syncTaskManagerUnitTest() {
  describe('SyncTaskManagerUnit', () => {
    let runtime: FakeRuntime;
    let manager: SyncTaskManager;

    beforeEach(() => {
      runtime = new FakeRuntime();
      SyncInternalTestAccess.setRuntime(runtime);
      SyncInternalTestAccess.resetState();
      manager = SyncTaskManager.getInstance();
    });

    afterEach(() => {
      manager.stop();
      SyncInternalTestAccess.resetRuntime();
      SyncInternalTestAccess.resetState();
      resetDataUploadPayloadCompressorInternal();
    });

    it('executePollShouldRunUploadBranches', 0, async () => {
      manager.init(createConfig(), createContext());
      await flushPromises();
      const db = runtime.dbTaskPool as FakeDbTaskPool;
      db.hasDataResult = false;
      db.updateDataTypeResult = 1;
      db.deleteExpireResult = 1;

      manager.setErrorTimeLine(99, null);
      await flushPromises();
      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(manager.getStatus().uploadLaneStatus.isRunning).assertFalse();
      expect(db.updateDataTypeCount >= 2).assertTrue();
      expect(db.deleteExpireCount >= 2).assertTrue();
      expect(manager.getStatus().running).assertFalse();
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('emptyDbDelaysSyncPollTenSeconds', 0, async () => {
      manager.init(createConfig(), createContext());
      await flushPromises();
      const db = runtime.dbTaskPool as FakeDbTaskPool;
      db.hasDataResult = false;

      manager.executeSyncPoll();
      await flushPromises();

      const uploadStatus = manager.getStatus().uploadLaneStatus;
      expect(uploadStatus.isScheduled).assertTrue();
      expect(uploadStatus.scheduledDelay).assertEqual(SyncTaskManager.AUTO_SYNC_DELAY_MS);
    });

    it('networkLossDefersScheduledUploadUntilRecovery', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'network-recovery-log',
          'df_rum_harmonyos_log,sdk_data_id=network-recovery-log value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executeSyncPoll();
      expect(manager.getStatus().uploadLaneStatus.scheduledDelay)
        .assertEqual(SyncTaskManager.AUTO_SYNC_DELAY_MS);

      manager.updateNetworkAvailability(false);
      await flushPromises();
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
      expect(runtime.executeHttpCount).assertEqual(0);

      manager.updateNetworkAvailability(true, true);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertTrue();
      expect(manager.getStatus().uploadLaneStatus.scheduledDelay)
        .assertEqual(SyncTaskManager.NETWORK_RECOVERY_UPLOAD_DELAY_MS);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
    });

    it('networkLossPreventsInFlightFailureFromStartingRetry', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      db.hasDataResult = true;
      const row = createSyncData(DataType.RUM_APP, 'network-lost-in-flight',
        'action,sdk_data_id=network-lost-in-flight,action_id=network-lost value=1i 100');
      db.queryQueue.push([row], [], []);
      runtime.httpResults.push(new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'network lost', '2300007'));

      let releaseHttp: () => void = () => {
        // Resolver is assigned by the Promise executor below.
      };
      runtime.httpBarrier = new Promise<void>((resolve: () => void) => {
        releaseHttp = resolve;
      });

      manager.executePoll(false);
      await waitUntil(() => runtime.executeHttpCount === 1);
      manager.updateNetworkAvailability(false);
      releaseHttp();
      runtime.httpBarrier = null;
      await runScheduledUpload(runtime);

      // The request already in flight may fail, but netLost must prevent its
      // retry chain from starting another HTTP request.
      expect(runtime.executeHttpCount).assertEqual(1);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('syncPollRunUploadLaneWhenDbHasData', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-auto', 'df_rum_harmonyos_log,sdk_data_id=log-auto value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executeSyncPoll();
      expect(manager.getStatus().uploadLaneStatus.scheduledDelay)
        .assertEqual(SyncTaskManager.AUTO_SYNC_DELAY_MS);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
      expect(db.lastUploadMaxBytes).assertEqual(DATA_UPLOAD_TRANSPORT_TARGET_BYTES);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('syncPollResumesAfterEndpointFix', 0, async () => {
      const db = new FakeDbTaskPool();
      const config = FTSDKConfig.builder();
      runtime.dbTaskPool = db;
      manager.init(config, createContext());

      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-runtime-endpoint',
          'df_rum_harmonyos_log,sdk_data_id=log-runtime-endpoint value=1i 100')
      ]);

      manager.executeSyncPoll();
      await flushPromises();
      expect(runtime.executeHttpCount).assertEqual(0);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();

      config.setDatawayUrl('https://dataway.example.com', '');
      manager.executeSyncPoll();
      await flushPromises();
      expect(runtime.executeHttpCount).assertEqual(0);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();

      config.setDatakitUrl('not-an-http-url');
      manager.executeSyncPoll();
      await flushPromises();
      expect(runtime.executeHttpCount).assertEqual(0);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();

      config.setDatawayUrl('https://dataway.example.com', 'runtime-token');
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));
      manager.executeSyncPoll();
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
    });

    it('uploadUseLatestRuntimeEndpointConfig', 0, async () => {
      const db = new FakeDbTaskPool();
      const config = createConfig();
      runtime.dbTaskPool = db;
      manager.init(config, createContext());

      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-latest-endpoint',
          'df_rum_harmonyos_log,sdk_data_id=log-latest-endpoint value=1i 100')
      ]);
      config.setDatawayUrl('https://runtime-dataway.example.com', 'runtime-token');
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executeSyncPoll();
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpDatakitUrl).assertEqual('');
      expect(runtime.lastHttpDatawayUrl).assertEqual('https://runtime-dataway.example.com');
      expect(runtime.lastHttpClientToken).assertEqual('runtime-token');
    });

    it('syncPollCoalescesTriggersForTenSeconds', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-aggregate', 'df_rum_harmonyos_log,sdk_data_id=log-aggregate value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executeSyncPoll();
      manager.executeSyncPoll();
      manager.executeSyncPoll();

      const uploadStatus = manager.getStatus().uploadLaneStatus;
      expect(uploadStatus.isScheduled).assertTrue();
      expect(uploadStatus.scheduledDelay).assertEqual(SyncTaskManager.AUTO_SYNC_DELAY_MS);
      expect(uploadStatus.needReschedule).assertFalse();
      expect(runtime.timerCallbacks.size).assertEqual(2);

      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('syncPollCoalesceWhileUploadLaneIsRunning', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      await flushPromises();

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-running', 'df_rum_harmonyos_log,sdk_data_id=log-running value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      let releaseHttp: () => void = () => {
        // Resolver is assigned by the Promise executor below.
      };
      runtime.httpBarrier = new Promise<void>((resolve: () => void) => {
        releaseHttp = resolve;
      });

      manager.executePoll(false);
      await waitUntil(() => runtime.executeHttpCount === 1);
      expect(manager.getStatus().uploadLaneStatus.isRunning).assertTrue();

      const hasDataCountBefore = db.hasDataCount;
      manager.executeSyncPoll();
      manager.executeSyncPoll();
      manager.executeSyncPoll();
      await flushPromises();

      expect(db.hasDataCount).assertEqual(hasDataCountBefore);
      expect(manager.getStatus().uploadLaneStatus.needReschedule).assertTrue();
      expect(manager.getStatus().uploadLaneStatus.rescheduleDelay)
        .assertEqual(SyncTaskManager.AUTO_SYNC_DELAY_MS);

      releaseHttp();
      runtime.httpBarrier = null;
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('uploadSendsSingleRecordBeyondTransportTarget', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      const largePayload = 'x'.repeat(DATA_UPLOAD_TRANSPORT_TARGET_BYTES);
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'transport-limit-row',
          `df_rum_harmonyos_log,sdk_data_id=transport-limit-row message="${largePayload}" 100`)
      ]);

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpBody.includes('transport-limit-row')).assertTrue();
      expect(runtime.lastHttpBody.length > DATA_UPLOAD_TRANSPORT_TARGET_BYTES).assertTrue();
      expect(runtime.sleepDurations.length).assertEqual(0);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('uploadSendsFollowingRecordInNextBatchAfterLargeRecord', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      const largePayload = 'x'.repeat(DATA_UPLOAD_TRANSPORT_TARGET_BYTES);
      const largeRow = createSyncData(DataType.LOG, 'transport-limit-row',
        `df_rum_harmonyos_log,sdk_data_id=transport-limit-row message="${largePayload}" 100`);
      const followingRow = createSyncData(DataType.LOG, 'cold-launch-row',
        'df_rum_harmonyos_log,sdk_data_id=cold-launch-row value=1i 101');
      db.queryQueue.push([], [], [
        largeRow,
        followingRow
      ], [followingRow], []);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''), new FakeHttpResult(204, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(2);
      expect(runtime.httpBodies[0].includes('transport-limit-row')).assertTrue();
      expect(runtime.httpBodies[0].length > DATA_UPLOAD_TRANSPORT_TARGET_BYTES).assertTrue();
      expect(runtime.httpBodies[1].includes('cold-launch-row')).assertTrue();
    });

    it('syncPollUploadsCacheAfterInit', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-init', 'df_rum_harmonyos_log,sdk_data_id=log-init value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.init(createConfig(), createContext());
      manager.executeSyncPoll();
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('setAutoSyncTrueShouldTriggerCachedUpload', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(false), createContext());
      await flushPromises();
      expect(runtime.executeHttpCount).assertEqual(0);

      db.hasDataResult = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-autosync', 'df_rum_harmonyos_log,sdk_data_id=log-autosync value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.setAutoSync(true);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('errorTimelineReadsRdbOrLegacyPrefs', 0, async () => {
      manager.init(createConfig(), createContext());
      await flushPromises();
      const view = new ViewBean('view-id', 'view', 100);

      manager.setErrorTimeLine(10, view);
      await flushPromises();
      expect(view.getLastErrorTime()).assertEqual(10);
      expect(runtime.preferences.putCount).assertEqual(0);
      expect(runtime.preferences.flushCount).assertEqual(0);
      expect(await manager.getErrorTimeLine()).assertEqual(10);

      manager.setErrorTimeLine(5, view);
      expect(view.getLastErrorTime()).assertEqual(10);

      runtime.preferences.value = 77;
      SyncInternalTestAccess.resetState();
      manager = SyncTaskManager.getInstance();
      manager.init(createConfig(), createContext());
      await flushPromises();
      expect(await manager.getErrorTimeLine()).assertEqual(77);
      expect(runtime.dbTaskPool.errorTimeLine).assertEqual(77);
      expect(runtime.dbTaskPool.updateErrorTimeLineCount).assertEqual(1);

      runtime.dbTaskPool.errorTimeLine = -1;
      runtime.preferences.value = 'not-number';
      SyncInternalTestAccess.resetState();
      manager = SyncTaskManager.getInstance();
      manager.init(createConfig(), createContext());
      await flushPromises();
      expect(await manager.getErrorTimeLine()).assertEqual(-1);

      runtime.preferences.throwGet = true;
      SyncInternalTestAccess.resetState();
      manager = SyncTaskManager.getInstance();
      manager.init(createConfig(), createContext());
      await flushPromises();
      expect(await manager.getErrorTimeLine()).assertEqual(-1);
      runtime.preferences.throwGet = false;

      runtime.preferences.throwPut = true;
      manager.setErrorTimeLine(88, null);
      await flushPromises();
      expect(runtime.preferences.putCount).assertEqual(0);
      expect(runtime.preferences.flushCount).assertEqual(0);
    });

    it('uploadLaneShouldSyncRumWebviewBeforeLog', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      db.queryQueue.push(
        [createSyncData(DataType.RUM_APP, 'rum-app-1', 'view,view_id=app value=1i 100')],
        [createSyncData(DataType.RUM_WEBVIEW, 'rum-web-1', 'view,view_id=web,is_webview=true value=1i 101')],
        [createSyncData(DataType.LOG, 'log-1', 'df_rum_harmonyos_log,sdk_data_id=log-1 value=1i 102')]
      );
      runtime.httpResults.push(
        new FakeHttpResult(204, 'ok', ''),
        new FakeHttpResult(204, 'ok', ''),
        new FakeHttpResult(204, 'ok', '')
      );

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.httpModels.length).assertEqual(3);
      expect(runtime.httpModels[0]).assertEqual(Constants.URL_MODEL_RUM);
      expect(runtime.httpModels[1]).assertEqual(Constants.URL_MODEL_RUM);
      expect(runtime.httpModels[2]).assertEqual(Constants.URL_MODEL_LOG);
      expect(runtime.cachePolicy.rumDelta).assertEqual(-2);
      expect(runtime.cachePolicy.logDelta).assertEqual(-1);
    });

    it('uploadReusesPersistedRumPackage', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      queueUploadRowsForOnly(db, DataType.RUM_APP, [
        createSyncData(DataType.RUM_APP, 'cold-launch-rum-id',
          'action,sdk_data_id=cold-launch-rum-id,action_id=cold-launch value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_RUM);
      expect(runtime.lastHttpBody.includes(`${runtime.lastHttpPkgId}.cold-launch-rum-id`)).assertTrue();
      expect(runtime.cachePolicy.rumDelta).assertEqual(-1);
    });

    it('legacyRowsWithoutDataIdDoNotBlockLaunch', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      db.queryQueue.push(
        [
          createSyncData(DataType.RUM_APP, 'legacy-resource',
            'resource,resource_id=legacy-resource resource_size=1i 100'),
          createSyncData(DataType.RUM_APP, 'legacy-error',
            'error,resource_id=legacy-resource,error_type=network message="timeout" 101'),
          createSyncData(DataType.RUM_APP, 'cold-launch-rum-id',
            'action,sdk_data_id=cold-launch-rum-id,action_id=cold-launch value=1i 102')
        ],
        [],
        []
      );
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpBody.includes('resource_id=legacy-resource')).assertTrue();
      expect(runtime.lastHttpBody.includes(`${runtime.lastHttpPkgId}.cold-launch-rum-id`)).assertTrue();
      expect(runtime.cachePolicy.rumDelta).assertEqual(-3);
    });

    it('uploadRespectPerRoundPageBudget', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      const pageSize = manager.getPageSize();
      db.queryQueue.push(
        createBatchSyncData(DataType.RUM_APP, 'rum-app-budget-a', pageSize, 100),
        createBatchSyncData(DataType.RUM_APP, 'rum-app-budget-b', pageSize, 200),
        createBatchSyncData(DataType.RUM_WEBVIEW, 'rum-web-budget', pageSize, 300),
        createBatchSyncData(DataType.LOG, 'log-budget', pageSize, 400)
      );
      runtime.httpResults.push(
        new FakeHttpResult(204, 'ok', ''),
        new FakeHttpResult(204, 'ok', ''),
        new FakeHttpResult(204, 'ok', ''),
        new FakeHttpResult(204, 'ok', '')
      );

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.httpBodies.length).assertEqual(4);
      expect(runtime.httpBodies[0].includes('rum-app-budget-a')).assertTrue();
      expect(runtime.httpBodies[1].includes('rum-app-budget-b')).assertTrue();
      expect(runtime.httpBodies[2].includes('rum-web-budget')).assertTrue();
      expect(runtime.httpBodies[3].includes('log-budget')).assertTrue();
      expect(db.queryCount).assertEqual(7);
      expect(runtime.cachePolicy.rumDelta).assertEqual(-(pageSize * 3));
      expect(runtime.cachePolicy.logDelta).assertEqual(-pageSize);
    });

    it('uploadFormatBodyThroughUploadExecutor', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      setDataUploadPayloadCompressorInternal(new FixedPayloadCompressor());

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-local-format', 'df_rum_harmonyos_log,sdk_data_id=log-local-format value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpBody.includes('log-local-format')).assertTrue();
      expect(runtime.lastHttpContentEncoding).assertEqual('deflate');
      expect(runtime.lastHttpCompressedBody !== undefined).assertTrue();
      expect(runtime.uploadWorkerCommands.includes(SDKWorkerCommand.UPLOAD_CONSUME)).assertTrue();
      expect(runtime.uploadWorkerCommands.includes(SDKWorkerCommand.UPLOAD_PREPARE_PAGE)).assertTrue();
      expect(runtime.uploadWorkerCommands.includes(SDKWorkerCommand.UPLOAD_EXECUTE_PAGE)).assertTrue();
      expect(runtime.uploadWorkerCommands.includes(SDKWorkerCommand.UPLOAD_COMMIT_PAGE)).assertTrue();
      expect(runtime.uploadWorkerCommands.includes(SDKWorkerCommand.UPLOAD_CONSUME_FINISH)).assertTrue();
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('remoteFilterRemovesRowsBeforeUpload', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig().setEnableDataFilter(true), createContext());
      manager.updateRemoteDataFilters(new Map<string, Array<string>>([
        ['logging', ["{ message = 'blocked' }"]]
      ]));

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'remote-blocked',
          'df_rum_harmonyos_log,sdk_data_id=remote-blocked message="blocked",value=1i 100'),
        createSyncData(DataType.LOG, 'remote-allowed',
          'df_rum_harmonyos_log,sdk_data_id=remote-allowed message="allowed",value=1i 101')
      ]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(1);
      expect(runtime.lastHttpBody.includes('remote-blocked')).assertFalse();
      expect(runtime.lastHttpBody.includes('remote-allowed')).assertTrue();
      expect(db.deleteCount).assertEqual(3);
      expect(db.deletedUuidBatches[0][0]).assertEqual('remote-blocked');
      expect(db.deletedUuidBatches[1][0]).assertEqual('remote-allowed');
      expect(db.deletedUuidBatches[2][0]).assertEqual('remote-allowed');
      expect(runtime.cachePolicy.logDelta).assertEqual(-2);
    });

    it('remoteFilterDropsRowsWithoutUpload', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig().setEnableDataFilter(true), createContext());
      manager.updateRemoteDataFilters(new Map<string, Array<string>>([
        ['logging', ["{ message match ['blocked'] }"]]
      ]));

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'remote-filter-only',
          'df_rum_harmonyos_log,sdk_data_id=remote-filter-only message="blocked",value=1i 100')
      ]);

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(0);
      expect(db.deleteCount).assertEqual(1);
      expect(db.deletedUuidBatches[0][0]).assertEqual('remote-filter-only');
      expect(runtime.cachePolicy.logDelta).assertEqual(-1);
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
    });

    it('dbFailurePreservesWorkerCheckpoint', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      db.throwDelete = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-db-failure',
          'df_rum_harmonyos_log,sdk_data_id=log-db-failure value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      // Package persistence is atomic and precedes HTTP, so a failed cache
      // write must prevent the request from being sent.
      expect(runtime.executeHttpCount).assertEqual(0);
      expect(runtime.uploadWorkerState.uploadCheckpointVersion).assertEqual(0);
      expect(runtime.uploadWorkerState.uploadPendingPage === null).assertTrue();
      expect(runtime.cachePolicy.logDelta).assertEqual(0);
      expect(runtime.sleepDurations.includes(500)).assertTrue();
    });

    it('partialDbCommitDoesNotAck', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      db.deleteAffectedRowsOverride = 0;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-partial-db-commit',
          'df_rum_harmonyos_log,sdk_data_id=log-partial-db-commit value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(200, 'ok', ''));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(0);
      expect(runtime.uploadWorkerState.uploadCheckpointVersion).assertEqual(0);
      expect(runtime.uploadWorkerState.uploadPendingPage === null).assertTrue();
      expect(runtime.cachePolicy.logDelta).assertEqual(0);
      expect(runtime.sleepDurations.includes(500)).assertTrue();
    });

    it('uploadDelete2xxTo4xxWithoutRetryBackoff', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'log-200', 200);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'log-204', 204);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'log-400', 400);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'log-404', 404);

      expect(db.deleteCount).assertEqual(8);
      expect(db.insertCount).assertEqual(4);
      expect(runtime.cachePolicy.logDelta).assertEqual(-4);
      expect(getBackoffDurations(runtime).length).assertEqual(0);
      expect(manager.getStatus().errorCount).assertEqual(0);
    });

    it('ignoredClientErrorsDeleteAndBackoff', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-403', 'df_rum_harmonyos_log,sdk_data_id=log-403 value=1i 100')
      ]);
      runtime.httpResults.push(new FakeHttpResult(403, 'forbidden', '403'));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(db.deleteCount).assertEqual(2);
      expect(db.insertCount).assertEqual(1);
      expect(runtime.cachePolicy.logDelta).assertEqual(-1);
      expect(runtime.sleepDurations.includes(500)).assertTrue();

      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'log-429', 'df_rum_harmonyos_log,sdk_data_id=log-429 value=1i 101')
      ]);
      runtime.httpResults.push(new FakeHttpResult(429, 'rate limit', '429'));

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(db.deleteCount).assertEqual(4);
      expect(db.insertCount).assertEqual(2);
      expect(runtime.cachePolicy.logDelta).assertEqual(-2);
      expect(runtime.sleepDurations.includes(1000)).assertTrue();
    });

    it('clientBackoffIsBoundedAndIsolatedByType', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-1', 403);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-2', 429);
      await runSingleBatchUpload(manager, runtime, db, DataType.RUM_APP, 'ignored-rum-app-1', 429);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-3', 403);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-4', 403);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-5', 403);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'ignored-log-6', 403);

      const backoffs = getBackoffDurations(runtime);
      expect(backoffs[0]).assertEqual(500);
      expect(backoffs[1]).assertEqual(1000);
      expect(backoffs[2]).assertEqual(500);
      expect(backoffs[3]).assertEqual(2000);
      expect(backoffs[4]).assertEqual(4000);
      expect(backoffs[5]).assertEqual(8000);
      expect(backoffs[6]).assertEqual(8000);
      expect(db.deleteCount).assertEqual(14);
      expect(db.insertCount).assertEqual(7);
    });

    it('uploadIsolateRetryBackoffByDataType', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      await runSingleBatchUpload(manager, runtime, db, DataType.RUM_APP, 'retry-rum-1', 500);
      await runSingleBatchUpload(manager, runtime, db, DataType.RUM_APP, 'retry-rum-2', 500);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-1', 500);
      await runSingleBatchUpload(manager, runtime, db, DataType.RUM_APP, 'retry-rum-success', 204);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-2', 500);

      const backoffs = getBackoffDurations(runtime);
      expect(backoffs[0]).assertEqual(500);
      expect(backoffs[1]).assertEqual(1000);
      expect(backoffs[2]).assertEqual(500);
      expect(backoffs[3]).assertEqual(1000);
      expect(db.insertCount).assertEqual(5);
      expect(db.insertReInsertFlags[0]).assertTrue();
      expect(db.insertReInsertFlags[1]).assertTrue();
      expect(db.insertReInsertFlags[2]).assertTrue();
      expect(db.insertReInsertFlags[3]).assertTrue();
      expect(db.insertReInsertFlags[4]).assertTrue();
      expect(manager.getStatus().errorCount).assertEqual(2);
    });

    it('uploadFailuresKeepRowsAndBackoff', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-500', 500);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-502', 502);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-network',
        NetCodeStatus.NETWORK_EXCEPTION_CODE);
      await runSingleBatchUpload(manager, runtime, db, DataType.LOG, 'retry-log-unknown',
        NetCodeStatus.UNKNOWN_EXCEPTION_CODE);

      const backoffs = getBackoffDurations(runtime);
      expect(backoffs[0]).assertEqual(500);
      expect(backoffs[1]).assertEqual(1000);
      expect(backoffs.length).assertEqual(2);
      expect(db.deleteCount).assertEqual(4);
      expect(db.insertCount).assertEqual(4);
      expect(db.insertReInsertFlags[0]).assertTrue();
      expect(db.insertReInsertFlags[1]).assertTrue();
      expect(db.insertReInsertFlags[2]).assertTrue();
      expect(db.insertReInsertFlags[3]).assertTrue();
      expect(runtime.cachePolicy.logDelta).assertEqual(0);
    });

    it('offlineRetryLimitStopsScheduling', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());
      const offlineRow = createSyncData(DataType.RUM_APP, 'offline-cold-launch',
        'action,sdk_data_id=offline-cold-launch,action_id=cold-launch value=1i 100');
      // Three upload rounds: each round queries RUM, WebView, then Log. The
      // configured retry count is two, so the third failed request is final
      // for this scheduling chain.
      db.queryQueue.push(
        [offlineRow], [], [],
        [offlineRow], [], [],
        [offlineRow], [], []
      );
      runtime.httpResults.push(
        new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'offline', '11000'),
        new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'offline', '11000'),
        new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'offline', '11000')
      );

      manager.executePoll(false);
      await runScheduledUpload(runtime);

      expect(runtime.executeHttpCount).assertEqual(3);
      expect(getBackoffDurations(runtime).includes(500)).assertTrue();
      expect(getBackoffDurations(runtime).includes(1000)).assertTrue();
      expect(manager.getStatus().uploadLaneStatus.isScheduled).assertFalse();
      expect(manager.getStatus().uploadLaneStatus.isRunning).assertFalse();
      expect(runtime.cachePolicy.rumDelta).assertEqual(0);
    });

    it('executePollShouldUploadRetry', 0, async () => {
      const db = new FakeDbTaskPool();
      runtime.dbTaskPool = db;
      manager.init(createConfig(), createContext());

      db.hasDataResult = false;
      manager.executePoll(false);
      await runScheduledUpload(runtime);
      expect(runtime.executeHttpCount).assertEqual(0);

      db.hasDataResult = true;
      runtime.cachePolicy.discard = true;
      queueUploadRowsForOnly(db, DataType.LOG, [
        createSyncData(DataType.LOG, 'discard-uuid', 'df_rum_harmonyos_log,sdk_data_id=discard-uuid value=1i 100')
      ]);
      manager.executePoll(false);
      await runScheduledUpload(runtime);
      runtime.cachePolicy.discard = false;

      const logOne = createSyncData(DataType.LOG, 'log-1', 'df_rum_harmonyos_log,sdk_data_id=log-1 value=1i 100');
      queueUploadRowsForOnly(db, DataType.LOG, [logOne]);
      runtime.httpResults.push(new FakeHttpResult(204, 'ok', ''));
      manager.executePoll(false);
      await runScheduledUpload(runtime);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_LOG);
      expect(runtime.lastHttpPkgId.split('.').length).assertEqual(4);
      expect(runtime.lastHttpBody.includes(`${runtime.lastHttpPkgId}.log-1`)).assertTrue();
      expect(db.deleteCount > 0).assertTrue();
      // Both records were already persisted. Cache discard policy applies when
      // inserting data and must not suppress an existing upload row.
      expect(runtime.cachePolicy.logDelta).assertEqual(-2);

      const deleteCountAfterSuccess = db.deleteCount;
      const insertCountAfterSuccess = db.insertCount;
      const rumError = createSyncData(DataType.RUM_APP, 'rum-1',
        'error,sdk_data_id=rum-1,error_type=js,error_message="boom" value=1i 100');
      queueUploadRowsForOnly(db, DataType.RUM_APP, [rumError]);
      runtime.httpResults.push(new FakeHttpResult(500, 'fail', 'server'));
      manager.executePoll(false);
      await runScheduledUpload(runtime);
      expect(runtime.lastHttpModel).assertEqual(Constants.URL_MODEL_RUM);
      expect(db.deleteCount).assertEqual(deleteCountAfterSuccess + 1);
      expect(db.insertCount).assertEqual(insertCountAfterSuccess + 1);
      expect(runtime.sleepDurations.includes(500)).assertTrue();

      // A retry reads the package-prefixed record persisted before the first
      // request. It must reuse that record without another delete/reinsert.
      const persistedRumError = db.lastInserted[0];
      const firstRumBody = runtime.lastHttpBody;
      runtime.httpResults.push(new FakeHttpResult(NetCodeStatus.NETWORK_EXCEPTION_CODE, 'network', 'net'));
      queueUploadRowsForOnly(db, DataType.RUM_APP, [persistedRumError]);
      manager.executePoll(false);
      await runScheduledUpload(runtime);
      expect(db.insertCount).assertEqual(insertCountAfterSuccess + 1);
      expect(db.deleteCount).assertEqual(deleteCountAfterSuccess + 1);
      expect(runtime.lastHttpBody).assertEqual(firstRumBody);
      expect(db.insertReInsertFlags[0]).assertTrue();
      expect(db.insertReInsertFlags[1]).assertTrue();
    });

    it('rumCleanupShouldUseInitTimer', 0, async () => {
      const context = createContext();
      manager.init(createConfig(), context);
      expect(runtime.timerCallbacks.size).assertEqual(1);
      manager.init(createConfig(), context);
      expect(runtime.timerCallbacks.size).assertEqual(1);

      runtime.dbTaskPool = new FakeDbTaskPool();
      await runCleanupTimer(runtime);
      await runCleanupTimer(runtime);
      await runCleanupTimer(runtime);

      manager.stop();
      expect(runtime.timerCallbacks.size).assertEqual(0);
      manager.stop();
    });
  });
}
