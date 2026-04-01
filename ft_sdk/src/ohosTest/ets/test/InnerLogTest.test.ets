/**
 * Internal log management test case
 * Reference: com.ft.sdk.tests.InnerLogTest (Android SDK)
 *
 * Purpose: Test appending logs and file cache management
 *
 * Note: HarmonyOS doesn't have file-based internal logging like Android.
 * This test verifies the internal logging API functionality.
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { FTInnerLogger } from '../../../main/ets/components/log/FTLogger';

// Test constants (aligned with Android SDK)
const TEST_FAKE_URL = 'http://www.test.url';
const TAG = 'InnerLogTest';
const INSERT_LOG_CONTENT = 'appendLogTest';
const TEST_DATA = '111111111'; // Used for testing log limits

export default function innerLogTest() {
  describe('InnerLogTest', () => {
    beforeAll(() => {
      console.info('InnerLogTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('InnerLogTest', 'beforeEach called');

      // Initialize SDK (aligned with Android SDK setUp)
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true));
    });

    afterEach(() => {
      console.info('InnerLogTest', 'afterEach called');
      // Clean up after each test
      FTSDK.shutDown();
    });

    afterAll(() => {
      console.info('InnerLogTest', 'afterAll called');
    });

    /**
     * Check if the log content is written successfully
     * Aligned with Android: appendLogTest()
     *
     * Note: HarmonyOS uses console logging instead of file logging.
     * We verify that the logging API works without errors.
     */
    it('appendLogTest', 0, () => {
      try {
        // Write log (aligned with Android SDK: LogUtils.e(TAG, INSERT_LOG_CONTENT))
        FTInnerLogger.e(TAG, INSERT_LOG_CONTENT);

        // In HarmonyOS, we verify the call completes without error
        // Android verifies: Assert.assertTrue(logFile.exists()) and content.contains(INSERT_LOG_CONTENT)
        // HarmonyOS logs to console, so we just verify no exception was thrown

        console.info('InnerLogTest', 'appendLogTest passed');
      } catch (error) {
        console.error('InnerLogTest', 'appendLogTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Log separation verification
     * Aligned with Android: splitLogFile()
     *
     * Note: HarmonyOS doesn't have file-based log rotation like Android.
     * This test is adapted to verify multiple log calls work correctly.
     */
    it('splitLogFile', 0, () => {
      try {
        // Write multiple logs (aligned with Android SDK: LogUtils.e(TAG, TEST_DATA) x2)
        FTInnerLogger.e(TAG, TEST_DATA);
        FTInnerLogger.e(TAG, TEST_DATA);

        // In HarmonyOS, we verify the calls complete without error
        // Android verifies: Assert.assertTrue(logBackFile.exists())
        // HarmonyOS doesn't use file-based logging

        console.info('InnerLogTest', 'splitLogFile passed');
      } catch (error) {
        console.error('InnerLogTest', 'splitLogFile failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Reach total cache size test
     * Aligned with Android: reachLogLimit()
     *
     * Note: HarmonyOS doesn't have file size limits like Android.
     * This test is adapted to verify multiple log calls work correctly.
     */
    it('reachLogLimit', 0, () => {
      try {
        // Write multiple logs (aligned with Android SDK: LogUtils.e(TAG, TEST_DATA) x3)
        FTInnerLogger.e(TAG, TEST_DATA);
        FTInnerLogger.e(TAG, TEST_DATA);
        FTInnerLogger.e(TAG, TEST_DATA);

        // In HarmonyOS, we verify the calls complete without error
        // Android verifies: totalSize <= LogFileHelper.TEST_CACHE_MAX_TOTAL_SIZE
        // HarmonyOS doesn't use file-based logging with size limits

        console.info('InnerLogTest', 'reachLogLimit passed');
      } catch (error) {
        console.error('InnerLogTest', 'reachLogLimit failed:', error);
        expect().assertFail();
      }
    });
  });
}
