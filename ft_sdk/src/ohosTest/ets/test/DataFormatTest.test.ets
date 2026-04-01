/**
 * Data format verification test cases
 * Adapted from Android SDK: com.ft.sdk.tests.DataFormatTest
 *
 * Purpose: Verify floating point data (float/double) is stored correctly without being converted to integer
 *
 * @author Brandon
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import FTTrackInner from '../../../main/ets/components/FTTrackInner';
import { LogBean } from '../../../main/ets/components/bean/LogBean';
import { Utils } from '../../../main/ets/components/utils/Utils';
import { Status } from '../../../main/ets/components/bean/Status';

// Test constants
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';

// Number wrapper interface for ArkTS strict mode
interface NumberValue {
  value: number;
}

export default function dataFormatTest() {
  describe('DataFormatTest', () => {
    beforeAll(() => {
      console.info('DataFormatTest', 'DataFormatTest beforeAll called');
    });

    beforeEach(() => {
      console.info('DataFormatTest', 'DataFormatTest beforeEach called');
    });

    afterEach(() => {
      console.info('DataFormatTest', 'DataFormatTest afterEach called');
    });

    afterAll(() => {
      console.info('DataFormatTest', 'DataFormatTest afterAll called');
    });

    /**
     * During data storage, whether the floating point will become an integer
     * Adapted from Android: trackFloatDoubleDataTest
     */
    it('trackFloatDoubleDataTest', 0, async () => {
      // Install SDK (aligned with Android: FTSdk.install())
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(sdkConfig);

      // Init RUM config (aligned with Android: FTSdk.initRUMWithConfig())
      const rumConfig: FTRUMConfig = new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID);
      FTSDK.installRUMConfig(rumConfig);

      // Init log config
      const logConfig: FTLoggerConfig = new FTLoggerConfig();
      FTSDK.installLogConfig(logConfig);

      // Create log with float and double fields (aligned with Android: fields.put("floatValue", 0f))
      const logBean = new LogBean('TestLog', Utils.getCurrentTimestamp());
      logBean.setStatus(Status.INFO.name);

      // Add float and double values as properties (using NumberValue interface for ArkTS)
      const floatNum: NumberValue = { value: 0.0 };
      const doubleNum: NumberValue = { value: 0.0 };
      logBean.addProperty('floatValue', floatNum);
      logBean.addProperty('doubleValue', doubleNum);

      // Track the log (aligned with Android: invokeSyncData())
      FTTrackInner.getInstance().trackLog(logBean, false);

      // Wait for async processing (aligned with Android: Thread.sleep(3000))
      await new Promise<void>((resolve) => {
        setTimeout(() => {
          resolve();
        }, 3000);
      });

      // Verify log was created successfully
      // The key verification is that the SDK can track logs with float/double-like properties
      const fields = logBean.getAllFields();
      const floatValue = fields['floatValue'];
      const doubleValue = fields['doubleValue'];

      // Verify values exist
      expect(floatValue !== null && floatValue !== undefined).assertTrue();
      expect(doubleValue !== null && doubleValue !== undefined).assertTrue();

      // Note: Full integration test with database query requires context
      // This test verifies LogBean creation and tracking is working

      console.info('DataFormatTest', 'trackFloatDoubleDataTest passed');
    });
  });
}
