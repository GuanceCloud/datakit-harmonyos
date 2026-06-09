/**
 * Log output test
 * Reference: com.ft.sdk.tests.LogTest (Android SDK)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTLogger, LogEntry } from '../../../main/ets/components/log/FTLogger';
import { FTNativeCrashHandler } from '../../../main/ets/components/FTNativeCrashHandler';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { Status } from '../../../main/ets/components/bean/Status';
import { LogCacheDiscard, DataType } from '../../../main/ets/components/enum/Enums';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
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

class PublicLogEntry implements LogEntry {
  tag: string;
  message: string;
  level: string;

  constructor(tag: string, message: string, level: string) {
    this.tag = tag;
    this.message = message;
    this.level = level;
  }
}

export default function logTest() {
  describe('LogTest', () => {
    beforeAll(() => {
      console.info('LogTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('LogTest', 'beforeEach called');
      await SdkTestLifecycle.resetRuntimeState();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false));
      await DBAssert.resetAll();
    });

    afterEach(async () => {
      console.info('LogTest', 'afterEach called');
      FTDBCachePolicy.getInstance().resetTestConfig();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
      await WaitUtils.delay(300);
    });

    afterAll(() => {
      console.info('LogTest', 'afterAll called');
    });

    it('noLogConfigShouldDropLog', 0, async () => {
      FTLogger.logBackground('test', Status.FATAL);

      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.LOG], 0, 1200);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logSampleZeroShouldDrop', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true).setSamplingRate(0));

      FTLogger.logBackground('test', Status.FATAL);
      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.LOG], 0, 1500);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logCustomLogDisabledShouldNotWriteData', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(false));

      FTLogger.logBackground('custom_log_disabled_should_drop', Status.ERROR);
      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.LOG], 0, 1200);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logLevelFilterShouldDropInfoAndUploadError', 0, async () => {
      const collector = new MockCollector(200, '');
      collector.start();
      try {
        FTSDK.installLogConfig(new FTLoggerConfig()
          .setEnableCustomLog(true)
          .setLogLevelFilters(['ERROR']));

        FTLogger.logBackground('filter_drop_info_log', Status.INFO);
        FTLogger.logBackground('filter_keep_error_log', Status.ERROR);

        const inserted = await DBAssert.waitForSyncRecordContaining(
          DataType.LOG,
          ['filter_keep_error_log', 'status=error'],
          5000
        );
        const dropped = await DBAssert.waitForNoSyncRecordContaining(
          DataType.LOG,
          ['filter_drop_info_log', 'status=info'],
          1200
        );

        expect(inserted !== null).assertTrue();
        expect(dropped).assertTrue();
        expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

        FTSDK.flushSyncData();

        const uploaded = await collector.waitForPayloadContaining(['filter_keep_error_log', 'status=error'], 5000);
        const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);
        const payloads = collector.getRequests().map(request => request.bodyString).join('\n');

        expect(uploaded.length > 0).assertTrue();
        expect(payloads.includes('filter_drop_info_log')).assertFalse();
        expect(consumed).assertTrue();
      } finally {
        collector.stop();
      }
    });

    it('logInsertShouldUpload', 0, async () => {
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

    it('publicLoggerApisShouldWriteSingleAndBatchLogs', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

      FTLogger.d('public_debug_tag', 'public_debug_message');
      FTLogger.i('public_info_tag', 'public_info_message');
      FTLogger.w('public_warn_tag', 'public_warn_message');
      FTLogger.e('public_error_tag', 'public_error_message');

      const batchLogs: Array<LogEntry> = [
        new PublicLogEntry('batch_debug_tag', 'batch_debug_message', 'd'),
        new PublicLogEntry('batch_info_tag', 'batch_info_message', 'i'),
        new PublicLogEntry('batch_warn_tag', 'batch_warn_message', 'w'),
        new PublicLogEntry('batch_error_tag', 'batch_error_message', 'e'),
        new PublicLogEntry('batch_default_tag', 'batch_default_message', 'unknown')
      ];
      FTLogger.batchLog(batchLogs);
      FTLogger.flush();

      const inserted = await DBAssert.waitForSyncCount([DataType.LOG], 9, 5000);
      const records = await DBAssert.querySyncData([DataType.LOG], 20);
      const lines = records.map(record => record.getDataString()).join('\n');
      const status = FTLogger.getStatus();

      expect(inserted).assertTrue();
      expect(FTLogger.getInstance() !== null).assertTrue();
      expect(status.has('queueSize')).assertTrue();
      expect(status.has('bufferSize')).assertTrue();
      expect(status.has('isProcessing')).assertTrue();
      expect(lines.includes('public_debug_message')).assertTrue();
      expect(lines.includes('public_info_message')).assertTrue();
      expect(lines.includes('public_warn_message')).assertTrue();
      expect(lines.includes('public_error_message')).assertTrue();
      expect(lines.includes('tag=public_debug_tag')).assertTrue();
      expect(lines.includes('status=debug')).assertTrue();
      expect(lines.includes('status=info')).assertTrue();
      expect(lines.includes('status=warn')).assertTrue();
      expect(lines.includes('status=error')).assertTrue();
      expect(lines.includes('batch_default_message')).assertTrue();
    });

    it('printCustomLogShouldWriteOutput', 0, async () => {
      const nativeCrashHandler = new FTNativeCrashHandler();
      const canObserveInternalLogs = nativeCrashHandler.clearLogs();
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setPrintCustomLogToConsole(true));

      const logContent = '----printCustomLogToConsole----';
      FTLogger.logBackground(logContent, Status.INFO);

      const record = await DBAssert.waitForSyncRecordContaining(
        DataType.LOG,
        [`message="${logContent}"`, 'status=info'],
        5000
      );

      expect(record !== null).assertTrue();
      if (canObserveInternalLogs) {
        const collectedLogs = nativeCrashHandler.getCollectedLogs(20);
        expect(collectedLogs.includes(`[INFO]${logContent}`)).assertTrue();
      }
    });

    it('logRumLinkEnabled', 0, async () => {
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

    it('logRumLinkDisabled', 0, async () => {
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

    it('logDiscardShouldTriggerPolicy', 0, async () => {
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

    it('discardShouldDropNewest', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD));
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().setTestLimits(2, 5000);

      FTLogger.logBackground('discard_keep_first_log', Status.FATAL);
      const firstInserted = await DBAssert.waitForSyncRecordContaining(
        DataType.LOG,
        ['discard_keep_first_log'],
        5000
      );
      expect(firstInserted !== null).assertTrue();

      FTLogger.logBackground('discard_keep_second_log', Status.FATAL);
      const secondInserted = await DBAssert.waitForSyncCount([DataType.LOG], 2, 5000);
      expect(secondInserted).assertTrue();

      FTLogger.logBackground('discard_drop_newest_log', Status.FATAL);
      await WaitUtils.delay(600);

      const newestDropped = await DBAssert.waitForNoSyncRecordContaining(
        DataType.LOG,
        ['discard_drop_newest_log'],
        1500
      );
      const records = await DBAssert.querySyncData([DataType.LOG], 10);
      const lines = records.map(record => record.getDataString()).join('\n');

      expect(newestDropped).assertTrue();
      expect(records.length).assertEqual(2);
      expect(lines.includes('discard_keep_first_log')).assertTrue();
      expect(lines.includes('discard_keep_second_log')).assertTrue();
      expect(lines.includes('discard_drop_newest_log')).assertFalse();
    });

    it('logDiscardOldestShouldTrigger', 0, async () => {
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

    it('discardOldestShouldKeepNewest', 0, async () => {
      FTSDK.installLogConfig(new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST));
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().setTestLimits(2, 5000);

      FTLogger.logBackground('discard_oldest_first_log', Status.FATAL);
      const firstInserted = await DBAssert.waitForSyncRecordContaining(
        DataType.LOG,
        ['discard_oldest_first_log'],
        5000
      );
      expect(firstInserted !== null).assertTrue();

      FTLogger.logBackground('discard_oldest_second_log', Status.FATAL);
      const secondInserted = await DBAssert.waitForSyncCount([DataType.LOG], 2, 5000);
      expect(secondInserted).assertTrue();

      FTLogger.logBackground('discard_oldest_newest_log', Status.FATAL);

      const newestInserted = await DBAssert.waitForSyncRecordContaining(
        DataType.LOG,
        ['discard_oldest_newest_log'],
        5000
      );
      const oldestRemoved = await DBAssert.waitForNoSyncRecordContaining(
        DataType.LOG,
        ['discard_oldest_first_log'],
        5000
      );
      const records = await DBAssert.querySyncData([DataType.LOG], 10);
      const lines = records.map(record => record.getDataString()).join('\n');

      expect(newestInserted !== null).assertTrue();
      expect(oldestRemoved).assertTrue();
      expect(records.length).assertEqual(2);
      expect(lines.includes('discard_oldest_first_log')).assertFalse();
      expect(lines.includes('discard_oldest_second_log')).assertTrue();
      expect(lines.includes('discard_oldest_newest_log')).assertTrue();
    });
  });
}
