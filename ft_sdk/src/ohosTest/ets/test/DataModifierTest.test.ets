import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { LineDataModifier } from '../../../main/ets/components/DataModifier';
import { Constants } from '../../../main/ets/components/Constants';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const MASK = 'xxx';
const ORIGINAL_LOG_MESSAGE = 'sensitive-log-message';
const ORIGINAL_ACTION_NAME = 'sensitive_action';

class PublicApiLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result: Map<string, string> = new Map();
    tags.forEach((value: string, key: string) => result.set(key, value));
    fields.forEach((value: string, key: string) => result.set(key, value));

    if (result.get('message') === ORIGINAL_LOG_MESSAGE) {
      result.set('message', MASK);
    }
    if (result.get(Constants.KEY_RUM_ACTION_NAME) === ORIGINAL_ACTION_NAME) {
      result.set(Constants.KEY_RUM_ACTION_NAME, MASK);
    }
    return result;
  }
}

export default function dataModifierTest() {
  describe('DataModifierTest', () => {
    let collector: MockCollector;

    beforeEach(async () => {
      collector = new MockCollector(200, '');
      collector.start();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL)
        .setAutoSync(false)
        .setLineDataModifier(new PublicApiLineDataModifier()));
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      collector.stop();
      FTSDK.shutDown();
      await DBAssert.cleanupAll();
    });

    it('logModifierShouldChangeLineProtocol', 0, async () => {
      FTLogger.logBackground(ORIGINAL_LOG_MESSAGE, Status.INFO);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, ['message="xxx"', 'status=info'], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes(ORIGINAL_LOG_MESSAGE)).assertFalse();
      expect(line.includes(MASK)).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(['message="xxx"', 'status=info'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(uploaded.includes(ORIGINAL_LOG_MESSAGE)).assertFalse();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('rumModifierShouldChangeLineProtocol', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView('modifier_view');
      FTRUMGlobalManager.getInstance().addAction(ORIGINAL_ACTION_NAME, 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        `${Constants.KEY_RUM_ACTION_NAME}=${MASK}`,
        'action_type=click'
      ], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes(ORIGINAL_ACTION_NAME)).assertFalse();
      expect(line.includes(MASK)).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        `${Constants.KEY_RUM_ACTION_NAME}=${MASK}`,
        'action_type=click'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(uploaded.includes(ORIGINAL_ACTION_NAME)).assertFalse();
      expect(consumed).assertTrue();
    });
  });
}
