import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig } from '../../../main/ets/components/Configs';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';

const TEST_FAKE_URL = 'http://www.test.url';
const STATIC_KEY = 'custom_key';
const STATIC_VALUE = 'custom_value';
const DYNAMIC_KEY = 'dynamic_custom_key';
const DYNAMIC_VALUE = 'dynamic_custom_value';
const DYNAMIC_SINGLE_KEY = 'dynamic_single_custom_key';
const DYNAMIC_SINGLE_VALUE = 'dynamic_single_custom_value';

export default function logGlobalContextTest() {
  describe('LogGlobalContextTest', () => {
    let collector: MockCollector;

    beforeEach(async () => {
      collector = new MockCollector(200, '');
      collector.start();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false));
      FTSDK.installLogConfig(new FTLoggerConfig()
        .addGlobalContext(STATIC_KEY, STATIC_VALUE)
        .setEnableCustomLog(true));
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      await runTestCleanup([
        async () => { await collector.stop(); },
        () => { FTSDK.shutDown(); },
        async () => { await DBAssert.cleanupAll(); }
      ]);
    });

    it('logContextShouldPersistInPayload', 0, async () => {
      const dynamicContext: Map<string, string> = new Map();
      dynamicContext.set(DYNAMIC_KEY, DYNAMIC_VALUE);

      FTSDK.appendLogGlobalContext(dynamicContext);
      FTSDK.appendLogGlobalContextKeyValue(DYNAMIC_SINGLE_KEY, DYNAMIC_SINGLE_VALUE);
      FTLogger.logBackground('context log', Status.INFO);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [
        'message="context log"',
        `${STATIC_KEY}=${STATIC_VALUE}`,
        `${DYNAMIC_KEY}=${DYNAMIC_VALUE}`,
        `${DYNAMIC_SINGLE_KEY}=${DYNAMIC_SINGLE_VALUE}`
      ], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('status=info')).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'message="context log"',
        `${STATIC_KEY}=${STATIC_VALUE}`,
        `${DYNAMIC_KEY}=${DYNAMIC_VALUE}`,
        `${DYNAMIC_SINGLE_KEY}=${DYNAMIC_SINGLE_VALUE}`
      ], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });
  });
}
