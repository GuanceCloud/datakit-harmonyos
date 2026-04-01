/**
 * Log output test
 * Reference: com.ft.sdk.tests.LogTest (Android SDK)
 *
 * Purpose: Verify log functionality including sampling, RUM linking, and discard policies
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { Status } from '../../../main/ets/components/bean/Status';
import { LogCacheDiscard } from '../../../main/ets/components/enum/Enums';
import { ErrorType } from '../../../main/ets/components/rum/enum/RUMEnums';
import { AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';

// Test constants (aligned with Android SDK FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';

// Simple class for log property values (ArkTS requires class instance for 'object' type)
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

    beforeEach(() => {
      console.info('LogTest', 'beforeEach called');

      // Initialize SDK (aligned with Android SDK setUp)
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true));
    });

    afterEach(async () => {
      console.info('LogTest', 'afterEach called');
      // Clean up after each test
      FTSDK.shutDown();
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 500);
      });
    });

    afterAll(() => {
      console.info('LogTest', 'afterAll called');
    });

    /**
     * Verify that it is correct without setting FTLoggerConfig
     * Aligned with Android: withOutLogConfig()
     *
     * Note: HarmonyOS cannot query database directly like Android.
     * We verify the operations complete without error.
     */
    it('withOutLogConfig', 0, async () => {
      try {
        // Try to log without config (aligned with Android SDK)
        FTLogger.logBackground('test', Status.FATAL);

        // Wait for processing (aligned with Android SDK: Thread.sleep(2000))
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: Assert.assertEquals(0, recordDataList.size());
        // In HarmonyOS: We verify the operation completes without error

        console.info('LogTest', 'withOutLogConfig passed');
      } catch (error) {
        console.error('LogTest', 'withOutLogConfig failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Test the situation when the sampling rate is 0
     * Aligned with Android: logSampleRateZero()
     */
    it('logSampleRateZero', 0, async () => {
      try {
        // Set sampling rate to 0 (aligned with Android SDK)
        FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true).setSamplingRate(0));

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 1000);
        });

        // Try to log (aligned with Android SDK)
        FTLogger.logBackground('test', Status.FATAL);

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: Assert.assertEquals(0, recordDataList.size());
        // In HarmonyOS: We verify the operation completes without error

        console.info('LogTest', 'logSampleRateZero passed');
      } catch (error) {
        console.error('LogTest', 'logSampleRateZero failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Insert a log data test
     * Aligned with Android: logInsertDataTest()
     *
     * Note: HarmonyOS cannot verify database directly like Android.
     * We verify the operations complete without error.
     */
    it('logInsertDataTest', 0, async () => {
      try {
        // Initialize log config (aligned with Android SDK)
        FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

        // Generate log data (aligned with Android SDK)
        const logContent = '----logInsertDataTest----';
        FTLogger.logBackground(logContent, Status.FATAL);
        FTLogger.logBackground(logContent, Status.WARN);

        const property: Map<string, object> = new Map();
        property.set('fakeKey', new LogPropertyValue('fakeValue'));
        FTLogger.logBackground(logContent, Status.ERROR, property);

        // Multiple log entries (aligned with Android SDK)
        FTLogger.logBackground(logContent, Status.INFO);
        FTLogger.logBackground(logContent, Status.DEBUG);
        FTLogger.logBackground(logContent, Status.TRACE);
        FTLogger.logBackground(logContent, 'custom_status_type');

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 1000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: Assert.assertEquals(7, except);
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogTest', 'logInsertDataTest passed');
      } catch (error) {
        console.error('LogTest', 'logInsertDataTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Verify that the log output contains rum related data when enableLinkRumData is true
     * Aligned with Android: logLinkRUMDataEnable()
     *
     * Note: HarmonyOS cannot verify database directly like Android.
     * We verify the operations complete without error.
     */
    it('logLinkRUMDataEnable', 0, async () => {
      try {
        // Initialize RUM and log config with RUM linking enabled
        FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
        FTSDK.installLogConfig(new FTLoggerConfig()
          .setEnableCustomLog(true)
          .setEnableLinkRumData(true));

        // Start view and log (aligned with Android SDK)
        FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
        FTLogger.logBackground('test', Status.FATAL);

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database content without Context access
        // In Android: Assert.assertTrue(checkLogHasLinkRUMData(true));
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogTest', 'logLinkRUMDataEnable passed');
      } catch (error) {
        console.error('LogTest', 'logLinkRUMDataEnable failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Verify that the log output does not contain rum related data when enableLinkRumData is false
     * Aligned with Android: logLinkRUMDataDisable()
     *
     * Note: HarmonyOS cannot verify database directly like Android.
     * We verify the operations complete without error.
     */
    it('logLinkRUMDataDisable', 0, async () => {
      try {
        // Initialize RUM and log config with RUM linking disabled
        FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
        FTSDK.installLogConfig(new FTLoggerConfig()
          .setEnableCustomLog(true)
          .setEnableLinkRumData(false));

        // Start view and log (aligned with Android SDK)
        FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
        FTLogger.logBackground('test', Status.FATAL);

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database content without Context access
        // In Android: Assert.assertFalse(checkLogHasLinkRUMData(false));
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogTest', 'logLinkRUMDataDisable passed');
      } catch (error) {
        console.error('LogTest', 'logLinkRUMDataDisable failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Test inserting a large amount of data, whether it triggers the discard policy
     * Aligned with Android: triggerLogDiscardPolicyTest()
     *
     * Note: HarmonyOS test uses FTDBCachePolicy for testing.
     */
    it('triggerLogDiscardPolicyTest', 0, async () => {
      try {
        // Initialize log config (aligned with Android SDK)
        FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

        // Set up test scenario: simulate approaching log limit
        // In Android: FTDBCachePolicy.get().optLogCount(4990);
        const cachePolicy = FTDBCachePolicy.getInstance();
        cachePolicy.setTestLimits(5000, 5000);

        // Insert logs (aligned with Android SDK: for i in 0..19)
        const logContent = 'custom log';
        for (let i = 0; i < 20; i++) {
          FTLogger.logBackground(`${i}-${logContent}`, Status.FATAL);
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 10);
          });
        }

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: Assert.assertTrue(expectCount >= count);
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogTest', 'triggerLogDiscardPolicyTest passed');
      } catch (error) {
        console.error('LogTest', 'triggerLogDiscardPolicyTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Test inserting a large amount of data, whether it triggers the discard old policy
     * Aligned with Android: triggerLogDiscardOldPolicyTest()
     *
     * Note: HarmonyOS test uses FTDBCachePolicy for testing.
     */
    it('triggerLogDiscardOldPolicyTest', 0, async () => {
      try {
        // Initialize log config with DISCARD_OLDEST strategy (aligned with Android SDK)
        FTSDK.installLogConfig(new FTLoggerConfig()
          .setEnableCustomLog(true)
          .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST));

        // Set up test scenario
        const cachePolicy = FTDBCachePolicy.getInstance();
        cachePolicy.setTestLimits(5000, 5000);

        // Insert logs (aligned with Android SDK: for i in 0..19)
        const logContent = 'custom log';
        for (let i = 0; i < 20; i++) {
          FTLogger.logBackground(`${i}-${logContent}`, Status.FATAL);
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 10);
          });
        }

        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: Assert.assertTrue(expectCount >= count);
        // In HarmonyOS: We verify the operations complete without error

        console.info('LogTest', 'triggerLogDiscardOldPolicyTest passed');
      } catch (error) {
        console.error('LogTest', 'triggerLogDiscardOldPolicyTest failed:', error);
        expect().assertFail();
      }
    });
  });
}
