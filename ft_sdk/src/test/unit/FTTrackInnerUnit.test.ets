import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DataType } from '../../main/ets/components/enum/Enums';
import FTTrackInner from '../../main/ets/components/FTTrackInner';
import {
  FTTrackCachePolicy,
  FTTrackDataHelper,
  FTTrackDataProcessThreadPool,
  FTTrackDbManager,
  FTTrackHiLogInterceptor,
  FTTrackInnerRuntime,
  FTTrackLogCallback,
  FTTrackLogManager,
  FTTrackRumManager,
  FTTrackSyncTaskManager
} from '../../main/ets/components/FTTrackInnerRuntime';
import { BaseContentBean } from '../../main/ets/components/bean/BaseContentBean';
import { LogBean } from '../../main/ets/components/bean/LogBean';
import { QueueStatus } from '../../main/ets/components/log/TrackLogManager';
import { SyncData } from '../../main/ets/components/db/bean/SyncData';
import { CollectType } from '../../main/ets/components/rum/enum/RUMEnums';
import { RunnerCompleteCallBack } from '../../main/ets/components/rum/callback/RunnerCompleteCallBack';
import { NetCodeStatus } from '../../main/ets/components/http/HttpEngine';

const TEST_URL = 'http://localhost';

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    await Promise.resolve();
  }
}

function createContext(): Context {
  return new Object() as Context;
}

function mapOf(key: string, value: string): Map<string, string> {
  const map = new Map<string, string>();
  map.set(key, value);
  return map;
}

function unknownDataType(): DataType {
  return 'unknown' as DataType;
}

class TestValueObject {
  value: string;

  constructor(value: string) {
    this.value = value;
  }
}

class TestGetValueObject {
  private value: string;

  constructor(value: string) {
    this.value = value;
  }

  getValue(): string {
    return this.value;
  }
}

class TestThrowGetValueObject {
  getValue(): string {
    throw new Error('getValue failed');
  }
}

class TestPlainObject {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class TestObjectBean {
  content: string;

  constructor(content: string) {
    this.content = content;
  }
}

class TestThrowJsonObject {
  toJSON(): string {
    throw new Error('json failed');
  }
}

class EmptyMeasurementLogBean extends LogBean {
  constructor() {
    super('empty measurement', 1000);
  }

  public override getMeasurement(): string {
    return '';
  }
}

class TestCallback implements RunnerCompleteCallBack {
  completeCount: number = 0;

  onComplete(): void {
    this.completeCount++;
  }
}

class TestLogCallback implements FTTrackLogCallback {
  codes: number[];
  errors: string[];

  constructor(codes: number[], errors: string[]) {
    this.codes = codes;
    this.errors = errors;
  }

  onResponse(code: number, _message: string, errorCode: string): void {
    this.codes.push(code);
    this.errors.push(errorCode);
  }
}

class FakeDataHelper implements FTTrackDataHelper {
  initBaseConfigCount: number = 0;
  initLogConfigCount: number = 0;
  initRUMConfigCount: number = 0;
  appendGlobalCount: number = 0;
  appendGlobalKeyCount: number = 0;
  appendRumCount: number = 0;
  appendRumKeyCount: number = 0;
  appendLogCount: number = 0;
  appendLogKeyCount: number = 0;
  checkSessionResult: boolean = true;
  getBodyContentCount: number = 0;
  throwBodyContent: boolean = false;
  lastMeasurement: string = '';
  lastTags: Map<string, string> = new Map();
  lastFields: Map<string, string> = new Map();
  lastDataType: DataType = DataType.LOG;
  lastUuid: string = '';

  initBaseConfig(_config: FTSDKConfig): void {
    this.initBaseConfigCount++;
  }

  initLogConfig(_config: FTLoggerConfig): void {
    this.initLogConfigCount++;
  }

  initRUMConfig(_config: FTRUMConfig): void {
    this.initRUMConfigCount++;
  }

  appendGlobalContext(_globalContext: Map<string, string>): void {
    this.appendGlobalCount++;
  }

  appendGlobalContextByKeyValue(_key: string, _value: string): void {
    this.appendGlobalKeyCount++;
  }

  appendRUMGlobalContext(_globalContext: Map<string, string>): void {
    this.appendRumCount++;
  }

  appendRUMGlobalContextByKeyValue(_key: string, _value: string): void {
    this.appendRumKeyCount++;
  }

  appendLogGlobalContext(_globalContext: Map<string, string>): void {
    this.appendLogCount++;
  }

  appendLogGlobalContextByKeyValue(_key: string, _value: string): void {
    this.appendLogKeyCount++;
  }

  checkSessionWillCollect(_sessionId: string): boolean {
    return this.checkSessionResult;
  }

  getBodyContent(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    dataType: DataType,
    uuid: string
  ): string {
    if (this.throwBodyContent) {
      throw new Error('body failed');
    }
    this.getBodyContentCount++;
    this.lastMeasurement = measurement;
    this.lastTags = new Map(tags);
    this.lastFields = new Map(fields);
    this.lastDataType = dataType;
    this.lastUuid = uuid;
    return `${dataType}:${measurement}:${uuid}:${timeStamp}:${tags.size}:${fields.size}`;
  }
}

class FakeSyncTaskManager implements FTTrackSyncTaskManager {
  initCount: number = 0;
  syncPollCount: number = 0;
  stopCount: number = 0;
  throwShutdown: boolean = false;

  init(_config: FTSDKConfig, _context?: Context): void {
    this.initCount++;
  }

  executeSyncPoll(): void {
    this.syncPollCount++;
  }

  stop(): void {
    this.stopCount++;
    if (this.throwShutdown) {
      throw new Error('stop failed');
    }
  }
}

class FakeTrackLogManager implements FTTrackLogManager {
  setLogConfigCount: number = 0;
  trackLogCount: number = 0;
  trackLogBatchCount: number = 0;
  forceFlushCount: number = 0;
  shutdownCount: number = 0;
  throwTrackLog: boolean = false;
  throwTrackLogBatch: boolean = false;
  throwShutdown: boolean = false;
  lastSilence: boolean = false;
  queueStatus: QueueStatus = {
    queueSize: 2,
    bufferSize: 1,
    isProcessing: true
  };

  setLogConfig(_config: FTLoggerConfig): void {
    this.setLogConfigCount++;
  }

  trackLog(_logBean: LogBean, isSilence: boolean = false): void {
    this.trackLogCount++;
    this.lastSilence = isSilence;
    if (this.throwTrackLog) {
      throw new Error('track log failed');
    }
  }

  trackLogBatch(_logBeans: LogBean[], isSilence: boolean = false): void {
    this.trackLogBatchCount++;
    this.lastSilence = isSilence;
    if (this.throwTrackLogBatch) {
      throw new Error('track log batch failed');
    }
  }

  forceFlush(isSilence: boolean = false): void {
    this.forceFlushCount++;
    this.lastSilence = isSilence;
  }

  getQueueStatus(): QueueStatus {
    return this.queueStatus;
  }

  shutdown(): void {
    this.shutdownCount++;
    if (this.throwShutdown) {
      throw new Error('shutdown failed');
    }
  }
}

class FakeRumManager implements FTTrackRumManager {
  collectType: CollectType = CollectType.ALL;
  checkCount: number = 0;

  checkSessionWillCollect(_sessionId: string): CollectType {
    this.checkCount++;
    return this.collectType;
  }
}

class FakeCachePolicy implements FTTrackCachePolicy {
  rumStatus: number = 0;
  logStatus: number = 0;
  rumPolicyCount: number = 0;
  logPolicyCount: number = 0;
  rumCountDelta: number = 0;
  logCountDelta: number = 0;

  optRUMCachePolicy(_context: Context, _limit: number): Promise<number> {
    this.rumPolicyCount++;
    return Promise.resolve(this.rumStatus);
  }

  optLogCachePolicy(_context: Context, _limit: number): Promise<number> {
    this.logPolicyCount++;
    return Promise.resolve(this.logStatus);
  }

  optRumCount(delta: number): void {
    this.rumCountDelta += delta;
  }

  optLogCount(delta: number): void {
    this.logCountDelta += delta;
  }
}

class FakeDbManager implements FTTrackDbManager {
  initCount: number = 0;
  insertCount: number = 0;
  insertResult: boolean = true;
  throwInsert: boolean = false;
  lastData: SyncData | null = null;
  lastReInsert: boolean = false;

  init(): Promise<void> {
    this.initCount++;
    return Promise.resolve();
  }

  insertFtOperation(data: SyncData, reInsert: boolean = false): Promise<boolean> {
    this.insertCount++;
    this.lastData = data;
    this.lastReInsert = reInsert;
    if (this.throwInsert) {
      return Promise.reject(new Error('insert failed'));
    }
    return Promise.resolve(this.insertResult);
  }
}

class FakeDataProcessThreadPool implements FTTrackDataProcessThreadPool {
  executeCount: number = 0;
  throwExecute: boolean = false;

  execute(task: () => void): void {
    this.executeCount++;
    if (this.throwExecute) {
      throw new Error('execute failed');
    }
    task();
  }
}

class FakeHiLogInterceptor implements FTTrackHiLogInterceptor {
  initCount: number = 0;

  init(): void {
    this.initCount++;
  }
}

class FakeRuntime implements FTTrackInnerRuntime {
  dataHelper: FakeDataHelper = new FakeDataHelper();
  syncTaskManager: FakeSyncTaskManager = new FakeSyncTaskManager();
  trackLogManager: FakeTrackLogManager = new FakeTrackLogManager();
  rumManager: FakeRumManager = new FakeRumManager();
  cachePolicy: FakeCachePolicy = new FakeCachePolicy();
  dbManager: FakeDbManager | null = new FakeDbManager();
  threadPool: FakeDataProcessThreadPool = new FakeDataProcessThreadPool();
  hiLogInterceptor: FakeHiLogInterceptor = new FakeHiLogInterceptor();
  uuidIndex: number = 0;
  nanoTime: number = 987654321;
  millis: number = 1000;
  randomValue: number = 0.123;

  createDataHelper(): FTTrackDataHelper {
    return this.dataHelper;
  }

  getSyncTaskManager(): FTTrackSyncTaskManager {
    return this.syncTaskManager;
  }

  getTrackLogManager(): FTTrackLogManager {
    return this.trackLogManager;
  }

  getHiLogInterceptor(): FTTrackHiLogInterceptor {
    return this.hiLogInterceptor;
  }

  getRumManager(): FTTrackRumManager {
    return this.rumManager;
  }

  getCachePolicy(): FTTrackCachePolicy {
    return this.cachePolicy;
  }

  getDbManager(_context: Context): FTTrackDbManager | null {
    return this.dbManager;
  }

  getDataProcessThreadPool(): FTTrackDataProcessThreadPool {
    return this.threadPool;
  }

  generateUUID(): string {
    this.uuidIndex++;
    return `uuid-${this.uuidIndex}`;
  }

  getCurrentNanoTime(): number {
    return this.nanoTime;
  }

  nowMillis(): number {
    return this.millis;
  }

  random(): number {
    return this.randomValue;
  }
}

function createRichLogBean(): LogBean {
  const logBean = new LogBean('hello log', 1000);
  logBean.setServiceName('svc');
  logBean.addTag('direct_tag', 'direct-tag' as Object);
  logBean.addTag('value_tag', new TestValueObject('value-tag') as Object);
  logBean.addTag('get_tag', new TestGetValueObject('get-tag') as Object);
  logBean.addTag('throw_tag', new TestThrowGetValueObject() as Object);
  logBean.addTag('plain_tag', new TestPlainObject('plain-tag') as Object);
  logBean.addTag('number_tag', 7 as Object);
  logBean.addField('direct_field', 'direct-field' as Object);
  logBean.addField('value_field', new TestValueObject('value-field') as Object);
  logBean.addField('get_field', new TestGetValueObject('get-field') as Object);
  logBean.addField('throw_field', new TestThrowGetValueObject() as Object);
  logBean.addField('plain_field', new TestPlainObject('plain-field') as Object);
  logBean.addField('number_field', 42 as Object);
  return logBean;
}

function createObjectKeysRecord(): Record<string, object> {
  const record: Record<string, object> = {};
  record['one'] = new Object();
  record['two'] = new Object();
  return record;
}

function createLineTagsRecord(): Record<string, string> {
  const record: Record<string, string> = {};
  record['t1'] = 'v1';
  record['t2'] = 'v2';
  return record;
}

function createEmptyStringRecord(): Record<string, string> {
  const record: Record<string, string> = {};
  return record;
}

function createLineFieldsRecord(): Record<string, string> {
  const record: Record<string, string> = {};
  record['f1'] = '1';
  record['f2'] = '2';
  return record;
}

export default function ftTrackInnerUnitTest() {
  describe('FTTrackInnerUnit', () => {
    let runtime: FakeRuntime = new FakeRuntime();
    let trackInner: FTTrackInner;

    beforeEach(() => {
      runtime = new FakeRuntime();
      FTTrackInner.resetInstanceForTest();
      FTTrackInner.setRuntimeForTest(runtime);
      trackInner = FTTrackInner.getInstance();
    });

    afterEach(() => {
      FTTrackInner.resetInstanceForTest();
      FTTrackInner.resetRuntimeForTest();
    });

    it('singletonConfigAndContextMethodsShouldDelegateToRuntimeHelpers', 0, () => {
      expect(trackInner.isInitialized()).assertEqual(false);

      const config = FTSDKConfig.builder(TEST_URL);
      const context = createContext();
      trackInner.initBaseConfig(config, context);
      expect(trackInner.isInitialized()).assertEqual(true);
      expect(FTTrackInner.getInstance().isInitialized()).assertEqual(true);
      expect(runtime.dataHelper.initBaseConfigCount).assertEqual(1);
      expect(runtime.syncTaskManager.initCount).assertEqual(1);

      trackInner.initLogConfig(new FTLoggerConfig().setEnableConsoleLog(true));
      expect(runtime.dataHelper.initLogConfigCount).assertEqual(1);
      expect(runtime.trackLogManager.setLogConfigCount).assertEqual(1);
      expect(runtime.hiLogInterceptor.initCount).assertEqual(1);

      trackInner.initLogConfig(new FTLoggerConfig());
      expect(runtime.dataHelper.initLogConfigCount).assertEqual(2);
      expect(runtime.hiLogInterceptor.initCount).assertEqual(1);

      trackInner.initRUMConfig(new FTRUMConfig());
      expect(runtime.dataHelper.initRUMConfigCount).assertEqual(1);

      trackInner.appendGlobalContext(mapOf('base', 'value'));
      trackInner.appendGlobalContextKeyValue('base-key', 'base-value');
      trackInner.appendRUMGlobalContext(mapOf('rum', 'value'));
      trackInner.appendRUMGlobalContextKeyValue('rum-key', 'rum-value');
      trackInner.appendLogGlobalContext(mapOf('log', 'value'));
      trackInner.appendLogGlobalContextKeyValue('log-key', 'log-value');
      expect(runtime.dataHelper.appendGlobalCount).assertEqual(1);
      expect(runtime.dataHelper.appendGlobalKeyCount).assertEqual(1);
      expect(runtime.dataHelper.appendRumCount).assertEqual(1);
      expect(runtime.dataHelper.appendRumKeyCount).assertEqual(1);
      expect(runtime.dataHelper.appendLogCount).assertEqual(1);
      expect(runtime.dataHelper.appendLogKeyCount).assertEqual(1);

      trackInner.getDataHelper().appendGlobalContextByKeyValue('getter-key', 'getter-value');
      expect(runtime.dataHelper.appendGlobalKeyCount).assertEqual(2);
      trackInner.getSyncTaskManager().executeSyncPoll();
      expect(runtime.syncTaskManager.syncPollCount).assertEqual(1);
      trackInner.getTrackLogManager().forceFlush(true);
      expect(runtime.trackLogManager.forceFlushCount).assertEqual(1);
      expect(FTTrackInner.getObjectKeysForTest(createObjectKeysRecord()).length).assertEqual(2);
    });

    it('rumShouldStoreNoSessionAllAndSampledDataAndDropOthers', 0, async () => {
      const callback = new TestCallback();
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      trackInner.rum(100, 'view', new Map<string, string>(), mapOf('duration', '1'), callback);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(1);
      expect(runtime.syncTaskManager.syncPollCount).assertEqual(1);
      expect(callback.completeCount).assertEqual(1);

      const allTags = mapOf('session_id', 'sid-all');
      runtime.rumManager.collectType = CollectType.ALL;
      trackInner.rum(101, 'error', allTags, mapOf('error_message', 'boom'), callback);
      await flushPromises();
      expect(runtime.rumManager.checkCount).assertEqual(1);
      expect(runtime.dbManager?.insertCount).assertEqual(2);

      runtime.rumManager.collectType = CollectType.SAMPLING;
      trackInner.rum(102, 'resource', mapOf('session_id', 'sid-sampled'), mapOf('value', '2'), callback);
      await flushPromises();
      expect(runtime.dbManager?.lastData?.getCustomDataTypeString()).assertEqual('rum_app_error_sampled');
      expect(runtime.dbManager?.insertCount).assertEqual(3);

      runtime.rumManager.collectType = CollectType.DROP;
      trackInner.rum(103, 'rum_action', mapOf('session_id', 'sid-drop'), mapOf('value', '3'), callback);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(3);

      trackInner.rum(104, 'view', mapOf('session_id', 'sid-drop-view'), mapOf('value', '4'), callback);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(3);
    });

    it('rumWebViewShouldFormatAndGateBySessionCollection', 0, async () => {
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      const tags = new Map<string, string>();
      tags.set('session_id', 'sid');
      tags.set('quoted_tag', '"quoted"');
      const fields = new Map<string, string>();
      fields.set('quoted_field', '"quoted-field"');
      fields.set('plain_field', 'plain');

      runtime.dataHelper.checkSessionResult = true;
      trackInner.rumWebView(200, 'webview', tags, fields);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(1);
      expect(runtime.dataHelper.lastDataType).assertEqual(DataType.RUM_WEBVIEW);
      expect(runtime.dataHelper.lastTags.get('quoted_tag')).assertEqual('"quoted"');

      runtime.dataHelper.checkSessionResult = false;
      trackInner.rumWebView(201, 'webview', tags, fields);
      trackInner.rumWebView(202, 'webview', new Map<string, string>(), fields);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(1);
    });

    it('logEntrypointsShouldDelegateHandleInvalidBeanAndFlushStatus', 0, async () => {
      const logBean = new LogBean('message', 1000);
      const callbackCodes: number[] = [];
      const callbackErrors: string[] = [];
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      trackInner.trackLog(logBean, true);
      expect(runtime.trackLogManager.trackLogCount).assertEqual(1);
      expect(runtime.trackLogManager.lastSilence).assertTrue();

      runtime.trackLogManager.throwTrackLog = true;
      trackInner.trackLog(logBean);
      expect(runtime.trackLogManager.trackLogCount).assertEqual(2);

      trackInner.trackLogBatch([logBean], true);
      expect(runtime.trackLogManager.trackLogBatchCount).assertEqual(1);
      runtime.trackLogManager.throwTrackLogBatch = true;
      trackInner.trackLogBatch([logBean]);
      expect(runtime.trackLogManager.trackLogBatchCount).assertEqual(2);

      trackInner.forceFlushLogs(true);
      expect(runtime.trackLogManager.forceFlushCount).assertEqual(1);
      expect(trackInner.getLogQueueStatus().queueSize).assertEqual(2);
      expect(trackInner.getSdkConfig() !== null).assertTrue();

      trackInner.trackLogAsync(undefined, new TestLogCallback(callbackCodes, callbackErrors));
      expect(callbackCodes[0]).assertEqual(400);

      trackInner.trackLogAsync(new TestObjectBean('object-log'), new TestLogCallback(callbackCodes, callbackErrors));
      await flushPromises();
      expect(callbackCodes[1]).assertEqual(200);
      expect(runtime.cachePolicy.logCountDelta).assertEqual(1);
    });

    it('batchLogBeanSyncShouldIgnoreEmptyNonLogAndRespectSilence', 0, async () => {
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());
      trackInner.batchLogBeanSync([], false);
      expect(runtime.dbManager?.insertCount).assertEqual(0);

      const nonLog = BaseContentBean.createWithDefaultMeasurement('base', 1000);
      trackInner.batchLogBeanSync([nonLog], false);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(0);

      trackInner.batchLogBeanSync([createRichLogBean()], false);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(1);
      expect(runtime.syncTaskManager.syncPollCount).assertEqual(1);

      trackInner.batchLogBeanSync([createRichLogBean()], true);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(2);
      expect(runtime.syncTaskManager.syncPollCount).assertEqual(1);

      await trackInner.handleBatchLogPromisesForTest([Promise.reject(new Error('batch failed'))], 1, false);

      runtime.dbManager = null;
      trackInner.batchLogBeanSync([createRichLogBean()], false);
      await flushPromises();
      expect(runtime.syncTaskManager.syncPollCount).assertEqual(1);

      trackInner.batchLogBeanSync(new Object() as BaseContentBean[], false);
    });

    it('processLogBeanToDatabaseShouldCoverCacheDbAndErrorBranches', 0, async () => {
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      runtime.cachePolicy.logStatus = -1;
      let result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertFalse();

      runtime.cachePolicy.logStatus = 0;
      runtime.dbManager = null;
      result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertFalse();

      runtime.dbManager = new FakeDbManager();
      runtime.dbManager.insertResult = false;
      result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertFalse();

      runtime.dbManager.insertResult = true;
      result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertTrue();
      expect(runtime.cachePolicy.logCountDelta).assertEqual(1);

      runtime.dbManager.throwInsert = true;
      result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertFalse();

      FTTrackInner.resetInstanceForTest();
      trackInner = FTTrackInner.getInstance();
      result = await trackInner.processLogBeanToDatabaseForTest(createRichLogBean(), false);
      expect(result).assertFalse();
    });

    it('syncDataBackgroundShouldCoverRumLogDropFailureAndSchedulingBranches', 0, async () => {
      const callback = new TestCallback();
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      runtime.cachePolicy.rumStatus = -1;
      trackInner.syncDataBackgroundForTest(DataType.RUM_APP, 300, 'view', mapOf('tag', 'value'), mapOf('field', '1'),
        callback);
      await flushPromises();
      expect(runtime.dbManager?.insertCount).assertEqual(0);
      expect(callback.completeCount).assertEqual(0);

      runtime.cachePolicy.rumStatus = 0;
      runtime.dbManager = null;
      trackInner.syncDataBackgroundForTest(DataType.RUM_WEBVIEW, 301, 'webview', mapOf('tag', 'value'),
        mapOf('field', '1'), callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(0);

      runtime.dbManager = new FakeDbManager();
      runtime.dbManager.throwInsert = true;
      trackInner.syncDataBackgroundForTest(DataType.RUM_APP, 302, 'view', mapOf('tag', 'value'), mapOf('field', '1'),
        callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(0);

      runtime.dbManager.throwInsert = false;
      trackInner.syncDataBackgroundForTest(DataType.LOG, 303, 'log', mapOf('tag', 'value'), mapOf('field', '1'),
        callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(1);
      expect(runtime.cachePolicy.logCountDelta).assertEqual(1);

      trackInner.syncDataBackgroundForTest(unknownDataType(), 3031, 'other', mapOf('tag', 'value'), mapOf('field', '1'),
        null);
      await flushPromises();
      expect(runtime.dbManager.insertCount > 0).assertTrue();

      runtime.dataHelper.throwBodyContent = true;
      trackInner.syncDataBackgroundForTest(DataType.RUM_APP, 304, 'bad', mapOf('tag', 'value'), mapOf('field', '1'),
        callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(1);

      runtime.dataHelper.throwBodyContent = false;
      FTTrackInner.resetInstanceForTest();
      trackInner = FTTrackInner.getInstance();
      trackInner.syncDataBackgroundForTest(DataType.RUM_APP, 3041, 'no-context', mapOf('tag', 'value'),
        mapOf('field', '1'), null);
      await flushPromises();

      runtime.threadPool.throwExecute = true;
      trackInner.syncDataBackgroundForTest(DataType.RUM_APP, 305, 'schedule', mapOf('tag', 'value'),
        mapOf('field', '1'), callback);
      expect(runtime.threadPool.executeCount > 0).assertTrue();
    });

    it('syncDataBackgroundWithErrorSampledShouldCoverCountsCallbacksAndScheduleCatch', 0, async () => {
      const callback = new TestCallback();
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 400, 'error',
        mapOf('tag', 'value'), mapOf('field', '1'), callback);
      await flushPromises();
      expect(runtime.dbManager?.lastData?.getCustomDataTypeString()).assertEqual('rum_app_error_sampled');
      expect(runtime.cachePolicy.rumCountDelta).assertEqual(1);
      expect(callback.completeCount).assertEqual(1);

      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.LOG, 'log_error_sampled', 401, 'log',
        mapOf('tag', 'value'), mapOf('field', '1'), callback);
      await flushPromises();
      expect(runtime.cachePolicy.logCountDelta).assertEqual(1);
      expect(callback.completeCount).assertEqual(2);

      trackInner.syncDataBackgroundWithErrorSampledForTest(unknownDataType(), 'unknown_error_sampled', 4011, 'unknown',
        mapOf('tag', 'value'), mapOf('field', '1'), null);
      await flushPromises();

      runtime.cachePolicy.logStatus = -1;
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.LOG, 'log_error_sampled', 402, 'log',
        mapOf('tag', 'value'), mapOf('field', '1'), callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(3);

      runtime.cachePolicy.logStatus = 0;
      runtime.dbManager = null;
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.LOG, 'log_error_sampled', 4021, 'log-no-db',
        mapOf('tag', 'value'), mapOf('field', '1'), null);
      await flushPromises();
      runtime.dbManager = new FakeDbManager();

      runtime.dataHelper.throwBodyContent = true;
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 403, 'bad',
        mapOf('tag', 'value'), mapOf('field', '1'), callback);
      await flushPromises();
      expect(callback.completeCount).assertEqual(4);

      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 4031,
        'bad-no-callback', mapOf('tag', 'value'), mapOf('field', '1'), null);
      await flushPromises();

      FTTrackInner.resetInstanceForTest();
      trackInner = FTTrackInner.getInstance();
      runtime.dataHelper.throwBodyContent = false;
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 4032,
        'no-context', mapOf('tag', 'value'), mapOf('field', '1'), null);
      await flushPromises();

      runtime.threadPool.throwExecute = true;
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 404,
        'schedule-null-callback', mapOf('tag', 'value'), mapOf('field', '1'), null);
      trackInner.syncDataBackgroundWithErrorSampledForTest(DataType.RUM_APP, 'rum_app_error_sampled', 405, 'schedule',
        mapOf('tag', 'value'), mapOf('field', '1'), callback);
      expect(callback.completeCount).assertEqual(5);
    });

    it('syncDataBackgroundForLogShouldCoverUndefinedDropFailureAndExceptionCallbacks', 0, async () => {
      const codes: number[] = [];
      const errors: string[] = [];
      const logCallback = new TestLogCallback(codes, errors);
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      trackInner.syncDataBackgroundForLogForTest(undefined, logCallback);
      await flushPromises();
      expect(codes[0]).assertEqual(NetCodeStatus.UNKNOWN_EXCEPTION_CODE);

      runtime.cachePolicy.logStatus = -1;
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('drop'), logCallback);
      await flushPromises();
      expect(errors[1]).assertEqual('INSERT_ERROR');

      runtime.cachePolicy.logStatus = 0;
      runtime.dbManager = new FakeDbManager();
      runtime.dbManager.insertResult = false;
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('fail'), logCallback);
      await flushPromises();
      expect(errors[2]).assertEqual('INSERT_ERROR');

      runtime.dbManager = null;
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('no-db'), logCallback);
      await flushPromises();
      expect(errors[3]).assertEqual('INSERT_ERROR');

      runtime.dbManager = new FakeDbManager();
      runtime.dbManager.insertResult = true;
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('ok'), logCallback);
      await flushPromises();
      expect(codes[4]).assertEqual(200);

      runtime.dbManager.throwInsert = true;
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('throw'), logCallback);
      await flushPromises();
      expect(errors[5]).assertEqual('EXCEPTION');

      FTTrackInner.resetInstanceForTest();
      trackInner = FTTrackInner.getInstance();
      trackInner.syncDataBackgroundForLogForTest(new TestObjectBean('no-context'), logCallback);
      await flushPromises();
      expect(errors[6]).assertEqual('INSERT_ERROR');
    });

    it('syncDataCreatorsShouldCoverValueExtractionFallbacksIdsAndLineProtocol', 0, async () => {
      trackInner.initBaseConfig(FTSDKConfig.builder(TEST_URL), createContext());

      const logData = await trackInner.createSyncDataFromLogBeanForTest(createRichLogBean());
      expect(logData.getDataType()).assertEqual(DataType.LOG);
      expect(runtime.dataHelper.lastMeasurement).assertEqual(Constants.FT_LOG_DEFAULT_MEASUREMENT);
      expect(runtime.dataHelper.lastTags.get('direct_tag')).assertEqual('direct-tag');
      expect(runtime.dataHelper.lastTags.get('value_tag')).assertEqual('value-tag');
      expect(runtime.dataHelper.lastTags.get('get_tag')).assertEqual('get-tag');
      expect(runtime.dataHelper.lastTags.get('number_tag')).assertEqual('7');
      expect(runtime.dataHelper.lastFields.get('direct_field')).assertEqual('direct-field');
      expect(runtime.dataHelper.lastFields.get('value_field')).assertEqual('value-field');
      expect(runtime.dataHelper.lastFields.get('get_field')).assertEqual('get-field');
      expect(runtime.dataHelper.lastFields.get('number_field')).assertEqual('42');

      await trackInner.createSyncDataFromLogBeanForTest(new EmptyMeasurementLogBean());
      expect(runtime.dataHelper.lastMeasurement).assertEqual(Constants.FT_LOG_DEFAULT_MEASUREMENT);

      runtime.dataHelper.throwBodyContent = true;
      let logBeanError = '';
      try {
        await trackInner.createSyncDataFromLogBeanForTest(createRichLogBean());
      } catch (error) {
        logBeanError = `${error}`;
      }
      expect(logBeanError.indexOf('Operation failed') >= 0).assertTrue();

      let syncDataError = '';
      try {
        await trackInner.createSyncDataForTest(DataType.RUM_APP, 499, 'bad-view', mapOf('tag', 'value'),
          mapOf('field', '1'));
      } catch (error) {
        syncDataError = `${error}`;
      }
      expect(syncDataError.indexOf('Operation failed') >= 0).assertTrue();
      runtime.dataHelper.throwBodyContent = false;

      const syncData = await trackInner.createSyncDataForTest(DataType.RUM_APP, 500, 'view', mapOf('tag', 'value'),
        mapOf('field', '1'));
      expect(syncData.getId()).assertEqual(1123);
      expect(syncData.getUuid()).assertEqual('uuid-5');

      const objectData = await trackInner.createSyncDataFromObjectForTest(new TestObjectBean('object'));
      expect(objectData.getTime()).assertEqual(runtime.nanoTime);
      expect(objectData.getDataString().includes('object')).assertTrue();

      let objectError = '';
      try {
        await trackInner.createSyncDataFromObjectForTest(new TestThrowJsonObject());
      } catch (error) {
        objectError = `${error}`;
      }
      expect(objectError.indexOf('Operation failed') >= 0).assertTrue();

      expect(trackInner.generateIdForTest()).assertEqual(1123);
      expect(trackInner.generateLineProtocolForTest('m', createEmptyStringRecord(), createEmptyStringRecord(), 1))
        .assertEqual('m  1');
      expect(trackInner.generateLineProtocolForTest('m', createLineTagsRecord(), createLineFieldsRecord(), 2))
        .assertEqual('m,t1=v1,t2=v2 f1=1,f2=2 2');

      const fromLine = await trackInner.createSyncDataFromLineProtocolForTest('m', 'm f=1 3', 3, DataType.LOG);
      expect(fromLine.getDataString()).assertEqual('m f=1 3');
      expect(runtime.dbManager?.initCount).assertEqual(1);
      expect(runtime.dbManager?.insertCount).assertEqual(1);

      runtime.dbManager = null;
      const noDbLine = await trackInner.createSyncDataFromLineProtocolForTest('m', 'm f=1 31', 31, DataType.LOG);
      expect(noDbLine.getTime()).assertEqual(31);

      FTTrackInner.resetInstanceForTest();
      trackInner = FTTrackInner.getInstance();
      const noContextLine = await trackInner.createSyncDataFromLineProtocolForTest('m', 'm f=1 4', 4, DataType.LOG);
      expect(noContextLine.getTime()).assertEqual(4);
    });

    it('shutdownShouldStopManagersAndCatchManagerErrors', 0, async () => {
      await trackInner.shutdown();
      expect(runtime.trackLogManager.shutdownCount).assertEqual(1);
      expect(runtime.syncTaskManager.stopCount).assertEqual(1);

      runtime.trackLogManager.throwShutdown = true;
      await trackInner.shutdown();
      expect(runtime.trackLogManager.shutdownCount).assertEqual(2);
    });
  });
}
