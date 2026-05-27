/**
 * Log output test
 * Reference: com.ft.sdk.tests.LogTest (Android SDK)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { Status } from '../../../main/ets/components/bean/Status';
import { LogCacheDiscard, DataType } from '../../../main/ets/components/enum/Enums';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';
import { DBAssert } from './helpers/DBAssert';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';

class LogPropertyValue {
  value: string = '';
  constructor(value: string) {
    this.value = value;
  }
}

export default function logTest() {
  describe('LogTest', () => {
    beforeAll(() => {
      console.info('LogTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('LogTest', 'beforeEach called');
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false));
      await DBAssert.resetAll();
    });

    afterEach(async () => {
      console.info('LogTest', 'afterEach called');
      FTDBCachePolicy.getInstance().resetTestConfig();
      FTSDK.shutDown();
      await DBAssert.cleanupAll();
      await WaitUtils.delay(300);
    });

    afterAll(() => {
      console.info('LogTest', 'afterAll called');
    });

    it('withOutLogConfig', 0, async () => {
      FTLogger.logBackground('test', Status.FATAL);

      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.LOG], 0, 1200);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logSampleRateZero', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true).setSamplingRate(0));

      FTLogger.logBackground('test', Status.FATAL);
      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.LOG], 0, 1500);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logInsertDataTest', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

      const logContent = '----logInsertDataTest----';
      FTLogger.logBackground(logContent, Status.FATAL);
      FTLogger.logBackground(logContent, Status.WARN);

      const property: Map<string, object> = new Map();
      property.set('fakeKey', new LogPropertyValue('fakeValue'));
      FTLogger.logBackground(logContent, Status.ERROR, property);

      FTLogger.logBackground(logContent, Status.INFO);
      FTLogger.logBackground(logContent, Status.DEBUG);
      FTLogger.logBackground(logContent, Status.TRACE);
      FTLogger.logBackground(logContent, 'custom_status_type');

      const inserted = await DBAssert.waitForSyncCount([DataType.LOG], 7, 5000);
      const records = await DBAssert.querySyncData([DataType.LOG], 20);
      const propertyRecord = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'fakeKey', 'fakeValue'], 1000);

      expect(inserted).assertTrue();
      expect(records.length).assertEqual(7);
      expect(propertyRecord !== null).assertTrue();
      expect(records.some(record => record.getDataString().includes('status=fatal'))).assertTrue();
      expect(records.some(record => record.getDataString().includes('status=warn'))).assertTrue();
      expect(records.some(record => record.getDataString().includes('custom_status_type'))).assertTrue();
    });

    it('logLinkRUMDataEnable', 0, async () => {
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setEnableLinkRumData(true));

      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      FTLogger.logBackground('test', Status.FATAL);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, ['message="test"', 'status=fatal'], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('session_id=') || line.includes('view_id=')).assertTrue();
    });

    it('logLinkRUMDataDisable', 0, async () => {
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setEnableLinkRumData(false));

      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      FTLogger.logBackground('test', Status.FATAL);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, ['message="test"', 'status=fatal'], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('session_id=')).assertFalse();
      expect(line.includes('view_id=')).assertFalse();
    });

    it('triggerLogDiscardPolicyTest', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));
      FTDBCachePolicy.getInstance().setTestLimits(5000, 5000);

      for (let i = 0; i < 20; i++) {
        FTLogger.logBackground(`${i}-custom log`, Status.FATAL);
      }

      const inserted = await WaitUtils.waitUntil(async () => {
        return await DBAssert.querySyncCount([DataType.LOG]) > 0;
      }, 5000);
      const records = await DBAssert.querySyncData([DataType.LOG], 30);

      expect(inserted).assertTrue();
      expect(records.length > 0).assertTrue();
      expect(records.length <= 20).assertTrue();
    });

    it('triggerLogDiscardOldPolicyTest', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST));
      FTDBCachePolicy.getInstance().setTestLimits(5000, 5000);

      for (let i = 0; i < 20; i++) {
        FTLogger.logBackground(`${i}-custom log`, Status.FATAL);
      }

      const inserted = await WaitUtils.waitUntil(async () => {
        return await DBAssert.querySyncCount([DataType.LOG]) > 0;
      }, 5000);
      const records = await DBAssert.querySyncData([DataType.LOG], 30);

      expect(inserted).assertTrue();
      expect(records.length > 0).assertTrue();
      expect(records.length <= 20).assertTrue();
    });
  });
}
