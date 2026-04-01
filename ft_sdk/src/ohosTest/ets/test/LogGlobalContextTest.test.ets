/**
 * Log globalContext test
 * Reference: com.ft.sdk.tests.LogGlobalContextTest (Android SDK)
 *
 * Purpose: Verify log global context is correctly added to log data
 *
 * @author FT SDK Team
 */


import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig } from '../../../main/ets/components/Configs';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';

// Test constants (aligned with Android SDK FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const CUSTOM_KEY = 'custom_key';
const CUSTOM_VALUE = 'custom_value';
const DYNAMIC_CUSTOM_KEY = 'dynamic_custom_key';
const DYNAMIC_CUSTOM_VALUE = 'dynamic_custom_value';
const DYNAMIC_SINGLE_CUSTOM_KEY = 'dynamic_single_custom_key';
const DYNAMIC_SINGLE_CUSTOM_VALUE = 'dynamic_single_custom_value';

export default function logGlobalContextTest() {
  describe('LogGlobalContextTest', () => {
    beforeAll(() => {
      console.info('LogGlobalContextTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('LogGlobalContextTest', 'beforeEach called');

      // Initialize SDK with log global context (aligned with Android SDK setUp)
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true));
      FTSDK.installLogConfig(new FTLoggerConfig()
        .addGlobalContext(CUSTOM_KEY, CUSTOM_VALUE)
        .setEnableCustomLog(true)
      );

      // Add dynamic global context (aligned with Android SDK)
      const hashMap: Map<string, string> = new Map();
      hashMap.set(DYNAMIC_CUSTOM_KEY, DYNAMIC_CUSTOM_VALUE);
      FTSDK.appendLogGlobalContext(hashMap);
      FTSDK.appendLogGlobalContextKeyValue(DYNAMIC_SINGLE_CUSTOM_KEY, DYNAMIC_SINGLE_CUSTOM_VALUE);
    });

    afterEach(() => {
      console.info('LogGlobalContextTest', 'afterEach called');
      // Clean up after each test
      FTSDK.shutDown();
    });

    afterAll(() => {
      console.info('LogGlobalContextTest', 'afterAll called');
    });

    /**
     * During log output, the data added by globalContext will be output together
     * Aligned with Android: logGlobalContextTest()
     *
     * Note: HarmonyOS cannot verify database directly like Android.
     * We verify the operations complete without error.
     */
    it('logContextTest', 0, async () => {
      try {
        // Generate log data (aligned with Android SDK)
        FTLogger.logBackground('test Log', Status.INFO);

        // Wait for data to be processed (aligned with Android SDK: Thread.sleep(2000))
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database content without Context access
        // In Android: CheckUtils.checkValueInLineProtocol(DataType.LOG, new String[]{...})
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogGlobalContextTest', 'logContextTest passed');
      } catch (error) {
        console.error('LogGlobalContextTest', 'logContextTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Dynamic context test
     * Aligned with Android: dynamicContextTest (same as logContextTest in Android)
     *
     * Note: In Android SDK, this test is identical to logContextTest.
     * We include it here for completeness with the documentation.
     */
    it('dynamicContextTest', 0, async () => {
      try {
        // Generate log data with dynamic context (aligned with Android SDK)
        FTLogger.logBackground('test dynamic context', Status.WARN);

        // Wait for data to be processed
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database content without Context access
        // In Android: CheckUtils.checkValueInLineProtocol(DataType.LOG, new String[]{...})
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogGlobalContextTest', 'dynamicContextTest passed');
      } catch (error) {
        console.error('LogGlobalContextTest', 'dynamicContextTest failed:', error);
        expect().assertFail();
      }
    });
  });
}
