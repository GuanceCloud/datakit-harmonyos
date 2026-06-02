/**
 * Data synchronization test
 * Reference: com.ft.sdk.tests.DataSyncTest (Android SDK)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType, EnvType, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { ErrorType, AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';
const TEST_HOST = 'http://127.0.0.1:9529';
const TEST_DATAWAY_TOKEN = 'payload_token';

function buildDefaultSdkConfig(): FTSDKConfig {
  return FTSDKConfig.builder(TEST_HOST)
    .setDebug(true)
    .setAutoSync(false)
    .setEnv(EnvType.GRAY);
}

function buildDefaultRumConfig(): FTRUMConfig {
  return new FTRUMConfig()
    .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
    .setEnableTrackAppCrash(true)
    .setRumAppId(TEST_FAKE_RUM_ID)
    .setEnableTrackAppUIBlock(true)
    .setEnableTraceUserAction(true)
    .setEnableTraceUserView(true)
    .setEnableTraceUserResource(true);
}

function buildDefaultLogConfig(): FTLoggerConfig {
  return new FTLoggerConfig().setEnableCustomLog(true);
}

function buildDefaultTraceConfig(): FTTraceConfig {
  return new FTTraceConfig()
    .setEnableAutoTrace(true)
    .setTraceType(TraceType.DDTRACE);
}

function installTestSdk(
  context: Context,
  sdkConfig: FTSDKConfig = buildDefaultSdkConfig(),
  rumConfig: FTRUMConfig = buildDefaultRumConfig(),
  logConfig: FTLoggerConfig = buildDefaultLogConfig(),
  traceConfig: FTTraceConfig = buildDefaultTraceConfig()
): void {
  FTSDK.install(sdkConfig, context);
  FTSDK.installRUMConfig(rumConfig);
  FTSDK.installLogConfig(logConfig);
  FTSDK.installTraceConfig(traceConfig);
}

export default function dataSyncTest() {
  describe('DataSyncTest', () => {
    let collector: MockCollector;
    let context: Context;

    beforeAll(() => {
      console.info('DataSyncTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('DataSyncTest', 'beforeEach called');
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      collector = new MockCollector(200, '');
      collector.start();

      installTestSdk(context);

      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      console.info('DataSyncTest', 'afterEach called');
      collector.stop();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
    });

    afterAll(() => {
      console.info('DataSyncTest', 'afterAll called');
    });

    it('rumTest', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      await FTRUMGlobalManager.getInstance().stopView();

      const view = await DBAssert.waitForViewNamed(ANY_VIEW, 5000);
      expect(view !== null).assertTrue();
      expect((view?.getSessionId() ?? '').length > 0).assertTrue();
      // RUM view records are persisted into rum_view first. Upload conversion is
      // covered by sync/upload chain cases where payload capture is stable.
    });

    it('rumViewShouldWriteUploadPayloadAndDeleteSyncRows', 0, async () => {
      const viewName = 'upload_delete_view';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const viewRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(viewRecord !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'view',
        `view_name=${viewName}`
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, viewRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('logUpdateDataTest', 0, async () => {
      const logContent = '----logUpdateDataTest----';

      FTLogger.logBackground(logContent, Status.FATAL);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=fatal'], 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const payload = await collector.waitForPayloadContaining([logContent, 'status=fatal'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(payload.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logSyncTest', 0, async () => {
      const logContent = '----logUploadTest----';

      FTLogger.logBackground(logContent, Status.FATAL);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('rumActionShouldWriteToSyncDataAndUploadPayload', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      FTRUMGlobalManager.getInstance().addAction('sync_action', 'click');

      const actionRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, ['action', 'sync_action'], 5000);
      expect(actionRecord !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(['action', 'sync_action'], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, actionRecord?.getUuid() ?? '', 5000);
      await WaitUtils.delay(200);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('jsErrorShouldWriteUploadPayloadAndDeleteSyncRows', 0, async () => {
      const errorMessage = 'real_collected_js_error';
      const errorStack = 'Error: real_collected_js_error\n  at DataSyncTest';

      await FTRUMGlobalManager.getInstance().startView('error_sync_view');
      FTRUMGlobalManager.getInstance().addError(errorStack, errorMessage, ErrorType.JS, AppState.RUN);

      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'error',
        'error_type=js',
        errorMessage,
        'DataSyncTest'
      ], 5000);
      expect(errorRecord !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'error',
        'error_type=js',
        errorMessage,
        'DataSyncTest'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('anrErrorShouldWriteUploadPayloadAndDeleteSyncRows', 0, async () => {
      const errorMessage = 'real_collected_anr_error';
      const errorStack = 'ANR: real_collected_anr_error\n  at DataSyncTest';

      await FTRUMGlobalManager.getInstance().startView('anr_error_sync_view');
      FTRUMGlobalManager.getInstance().addError(errorStack, errorMessage, ErrorType.ANR_ERROR, AppState.RUN);

      const fragments = [
        'error',
        'error_type=anr_error',
        errorMessage,
        'DataSyncTest'
      ];
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(errorRecord !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('rumLongTaskShouldWriteUploadPayloadAndDeleteSyncRows', 0, async () => {
      const longTaskLog = 'real_collected_long_task';

      await FTRUMGlobalManager.getInstance().startView('long_task_sync_view');
      FTRUMGlobalManager.getInstance().addLongTask(longTaskLog, 123456789);

      const longTaskRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'long_task',
        longTaskLog,
        'duration'
      ], 5000);
      expect(longTaskRecord !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'long_task',
        longTaskLog,
        'duration'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, longTaskRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('configShouldAffectFinalPayloadAndUploadTarget', 0, async () => {
      const logPrefix = 'config_payload_log';
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST, TEST_DATAWAY_TOKEN)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.PRE)
        .setSyncPageSize(SyncPageSize.MINI)
        .addGlobalContext('config_payload_tag', new String('config_payload_value'));
      const logConfig = buildDefaultLogConfig();
      logConfig.setServiceName('config_payload_service');
      logConfig.addGlobalContext('log_payload_tag', 'log_payload_value');
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), logConfig, buildDefaultTraceConfig());

      for (let i = 0; i < 6; i++) {
        FTLogger.logBackground(`${logPrefix}_${i}`, Status.INFO);
      }

      const inserted = await DBAssert.waitForSyncCount([DataType.LOG], 6, 5000);
      expect(inserted).assertTrue();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [
        `${logPrefix}_0`,
        'service=config_payload_service',
        'env=pre',
        'config_payload_tag=config_payload_value',
        'log_payload_tag=log_payload_value'
      ], 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        `${logPrefix}_0`,
        'service=config_payload_service',
        'env=pre',
        'config_payload_tag=config_payload_value',
        'log_payload_tag=log_payload_value'
      ], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);
      const logRequests = collector.getRequests().filter(request => request.url.includes('/v1/write/logging'));

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(logRequests.length >= 2).assertTrue();
      expect(logRequests[0].url.includes(`token=${TEST_DATAWAY_TOKEN}`)).assertTrue();
      expect(logRequests[0].url.includes('to_headless=true')).assertTrue();
      expect(logRequests[0].url.includes('precision=ns')).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('rumConfigShouldAffectRumPayload', 0, async () => {
      const serviceName = 'config_rum_service';
      const appId = 'config_rum_app_id';
      const viewName = 'config_rum_payload_view';
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.PRE);
      const rumConfig = buildDefaultRumConfig()
        .setRumAppId(appId)
        .addGlobalContext('rum_payload_tag', new String('rum_payload_value'));
      rumConfig.setServiceName(serviceName);
      installTestSdk(context, sdkConfig, rumConfig, buildDefaultLogConfig(), buildDefaultTraceConfig());

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const fragments = [
        'view',
        `view_name=${viewName}`,
        `service=${serviceName}`,
        'env=pre',
        `app_id=${appId}`,
        'rum_payload_tag=rum_payload_value'
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('datakitUploadTargetShouldUseDatakitWriteUrl', 0, async () => {
      const logContent = 'datakit_target_log';
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false);
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), buildDefaultLogConfig(), buildDefaultTraceConfig());

      FTLogger.logBackground(logContent, Status.INFO);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent], 5000);
      const logRequests = collector.getRequests().filter(request => request.bodyString.includes(logContent));
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(logRequests.length > 0).assertTrue();
      expect(logRequests[0].url.includes('/v1/write/logging?precision=ns')).assertTrue();
      expect(logRequests[0].url.includes('token=')).assertFalse();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('autoSyncAndPageSizeShouldUploadInMiniBatchesWithoutManualFlush', 0, async () => {
      const logPrefix = 'auto_page_log';
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(true)
        .setSyncPageSize(SyncPageSize.MINI);
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), buildDefaultLogConfig(), buildDefaultTraceConfig());

      for (let i = 0; i < 6; i++) {
        FTLogger.logBackground(`${logPrefix}_${i}`, Status.INFO);
      }

      const uploadedAll = await WaitUtils.waitUntil(async () => {
        const logRequests = collector.getRequests()
          .filter(request => request.url.includes('/v1/write/logging') && request.bodyString.includes(logPrefix));
        const payloads = logRequests.map(request => request.bodyString).join('\n');
        return logRequests.length >= 2 &&
          payloads.includes(`${logPrefix}_0`) &&
          payloads.includes(`${logPrefix}_5`);
      }, 7000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploadedAll).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('realLogFailedUploadShouldPreserveAndRecoverAfterSuccessfulFlush', 0, async () => {
      const logContent = 'real_retry_log';

      collector.setResponse(500, 'server-error');
      FTLogger.logBackground(logContent, Status.ERROR);

      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=error'], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const failedPayload = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      await WaitUtils.delay(800);

      expect(failedPayload.length > 0).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

      collector.setResponse(200, '');
      collector.clearRequests();
      FTSDK.flushSyncData();

      const recoveredPayload = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(recoveredPayload.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('historicalRowsShouldFlushAfterSdkReinstall', 0, async () => {
      const logContent = 'restart_flush_log';

      FTLogger.logBackground(logContent, Status.ERROR);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.shutDown();
      collector.clearRequests();
      await SdkTestLifecycle.resetRuntimeState();
      installTestSdk(context);

      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('historicalRumRowsShouldFlushAfterSdkReinstall', 0, async () => {
      const viewName = 'restart_flush_view';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.shutDown();
      collector.clearRequests();
      await SdkTestLifecycle.resetRuntimeState();
      installTestSdk(context);

      const historical = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(historical !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'view',
        `view_name=${viewName}`
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, historical?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });
  });
}
