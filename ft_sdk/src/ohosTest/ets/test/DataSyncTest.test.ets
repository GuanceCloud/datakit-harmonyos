/**
 * Data synchronization test
 * Reference: com.ft.sdk.tests.DataSyncTest (Android SDK)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';
const TEST_HOST = 'http://127.0.0.1:9529';

export default function dataSyncTest() {
  describe('DataSyncTest', () => {
    let collector: MockCollector;

    beforeAll(() => {
      console.info('DataSyncTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('DataSyncTest', 'beforeEach called');
      collector = new MockCollector(200, '');
      collector.start();

      FTSDK.install(FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.GRAY));

      FTSDK.installRUMConfig(new FTRUMConfig()
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setEnableTrackAppCrash(true)
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true)
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true));

      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceType(TraceType.DDTRACE));

      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      console.info('DataSyncTest', 'afterEach called');
      collector.stop();
      FTSDK.shutDown();
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

    it('logUpdateDataTest', 0, async () => {
      const logContent = '----logUpdateDataTest----';

      FTLogger.logBackground(logContent, Status.FATAL);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=fatal'], 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const payload = await collector.waitForPayloadContaining([logContent, 'status=fatal'], 5000);
      expect(payload.length > 0).assertTrue();
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
      await WaitUtils.delay(200);

      expect(uploaded.length > 0).assertTrue();
    });
  });
}
