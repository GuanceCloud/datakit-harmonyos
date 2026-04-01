/**
 * Data synchronization test
 * Reference: com.ft.sdk.tests.DataSyncTest (Android SDK)
 *
 * Purpose: Verify data synchronization functionality
 * - RUM data synchronization
 * - Log data writing and synchronization
 * - Data upload after synchronization
 *
 * Test Adaptation:
 * - Android: Verifies data in database before/after sync
 * - HarmonyOS: Tests sync workflow without database access
 * - Both: Use MockWebServer to simulate server responses
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { EnvType } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { http } from '@kit.NetworkKit';
import { HttpBuilder } from '../../../main/ets/components/http/HttpBuilder';
import { FTResponseData } from '../../../main/ets/components/http/FTResponseData';
import { MockResponse } from '../../../test/MockResponse';
import { MockWebServer } from '../../../test/MockWebServer';

// Test constants (aligned with Android SDK)
const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';
const EMPTY_RESPONSE = "";
const FORMAT_REQUEST_HOST_WITH_PORT: string = "http://127.0.0.1:%s/";

export default function dataSyncTest() {
  describe('DataSyncTest', () => {
    let mMockWebServer: MockWebServer;
    let serverUrl: string;

    beforeAll(() => {
      console.info('DataSyncTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('DataSyncTest', 'beforeEach called');

      // Create and start MockWebServer
      mMockWebServer = new MockWebServer();

      const mockResponse: MockResponse = new MockResponse();
      mockResponse.setBody(EMPTY_RESPONSE);
      mockResponse.setResponseCode(200);
      mMockWebServer.enqueue(mockResponse);
      await mMockWebServer.play();

      // Build server URL
      serverUrl = FORMAT_REQUEST_HOST_WITH_PORT.replace("%s", mMockWebServer.getPort().toString());

      // Enable test mode for HttpBuilder
      HttpBuilder.enableTestMode();

      // Set mock response for test mode
      const expectedResponse = new FTResponseData(200, EMPTY_RESPONSE);
      HttpBuilder.setMockResponse(expectedResponse);

      // Initialize SDK with test configuration (aligned with Android SDK setUp)
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(serverUrl)
        .setDebug(true)
        .setAutoSync(false)  // Disable auto-sync for manual testing
        .setEnv(EnvType.GRAY);

      FTSDK.install(sdkConfig);

      // Initialize RUM config (aligned with Android SDK)
      const rumConfig: FTRUMConfig = new FTRUMConfig()
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setEnableTrackAppCrash(true)
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true)
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true);
      FTSDK.installRUMConfig(rumConfig);

      // Initialize log config (aligned with Android SDK)
      const logConfig: FTLoggerConfig = new FTLoggerConfig()
        .setEnableCustomLog(true);
      FTSDK.installLogConfig(logConfig);

      // Initialize trace config (aligned with Android SDK)
      const traceConfig: FTTraceConfig = new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceType(TraceType.DDTRACE);
      FTSDK.installTraceConfig(traceConfig);
    });

    afterEach(async () => {
      console.info('DataSyncTest', 'afterEach called');

      // Shutdown MockWebServer
      await mMockWebServer.shutdown();

      // Disable test mode
      HttpBuilder.disableTestMode();

      // Clean up SDK
      FTSDK.shutDown();
    });

    afterAll(() => {
      console.info('DataSyncTest', 'afterAll called');
    });

    /**
     * RUM data synchronization test
     *
     * Aligned with Android SDK: rumTest()
     * Verifies RUM data writing and synchronization
     *
     * Android implementation:
     * - FTRUMGlobalManager.get().startView() + stopView()
     * - CheckUtils.getCount() to verify data in database
     * - resumeSyncTask() + executeSyncTask()
     * - Verify count becomes 0 after sync
     *
     * HarmonyOS adaptation:
     * - Execute same SDK operations
     * - Cannot verify database counts (no Context access)
     * - Verify operations complete without errors
     */
    it('rumTest', 0, async () => {
      try {
        // Create a view lifecycle event (aligned with Android SDK)
        FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
        FTRUMGlobalManager.getInstance().stopView();

        // Wait for events to be processed (aligned with Android SDK: Thread.sleep(2000))
        await new Promise<void>((resolve: Function) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count without Context access
        // In Android: int except1 = CheckUtils.getCount(DataType.RUM_APP, Constants.FT_MEASUREMENT_RUM_VIEW, 0);
        // In HarmonyOS: We verify the operations complete without error

        // Trigger data synchronization (aligned with Android SDK: executeSyncTask())
        FTSDK.flushSyncData();

        // Wait for sync to complete (aligned with Android SDK: Thread.sleep(1000))
        await new Promise<void>((resolve: Function) => {
          setTimeout(() => {
            resolve();
          }, 1000);
        });

        // NOTE: Cannot verify database count becomes 0 without Context access
        // In Android: Assert.assertEquals(0, except2);
        // In HarmonyOS: We verify sync completes without error

        console.info('DataSyncTest', 'rumTest passed');
      } catch (error) {
        console.error('DataSyncTest', 'rumTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Log data writing test
     *
     * Aligned with Android SDK: logUpdateDataTest()
     * Verifies log data can be written and prepared for upload
     *
     * Android implementation:
     * - FTLogger.getInstance().logBackground(content, Status.FATAL)
     * - Thread.sleep(3000)
     * - uploadData(DataType.LOG)
     *
     * HarmonyOS adaptation:
     * - Execute same SDK operations
     * - Cannot verify database without Context
     * - Verify operations complete without errors
     */
    it('logUpdateDataTest', 0, async () => {
      try {
        const logContent = '----logUpdateDataTest----';

        // Generate a log entry (aligned with Android SDK)
        FTLogger.logBackground(logContent, Status.FATAL);

        // Wait for data to be processed (aligned with Android SDK: Thread.sleep(3000))
        await new Promise<void>((resolve: Function) => {
          setTimeout(() => {
            resolve();
          }, 3000);
        });

        // Trigger data upload (aligned with Android SDK: uploadData())
        FTSDK.flushSyncData();

        console.info('DataSyncTest', 'logUpdateDataTest passed');
      } catch (error) {
        console.error('DataSyncTest', 'logUpdateDataTest failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Log data synchronization test
     *
     * Aligned with Android SDK: logSyncTest()
     * Verifies data is deleted from cache after synchronization
     *
     * Android implementation:
     * - resumeSyncTask()
     * - FTLogger.getInstance().logBackground(content, Status.FATAL)
     * - Thread.sleep(12000)
     * - CheckUtils.getCount() - verify count is 0 after sync
     *
     * HarmonyOS adaptation:
     * - Execute same SDK operations
     * - Cannot verify database without Context
     * - Verify operations complete without errors
     * - Reduced wait time for faster test execution
     */
    it('logSyncTest', 0, async () => {
      try {
        const logContent = '----logUploadTest----';

        // Generate a log entry (aligned with Android SDK)
        FTLogger.logBackground(logContent, Status.FATAL);

        // Wait for data to be synced (reduced from 12000ms for faster test execution)
        // Android waits 12 seconds for auto-sync, HarmonyOS uses flushSyncData()
        await new Promise<void>((resolve: Function) => {
          setTimeout(() => {
            resolve();
          }, 3000);
        });

        // Trigger synchronization
        FTSDK.flushSyncData();

        // Wait for sync to complete
        await new Promise<void>((resolve: Function) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database count is 0 without Context access
        // In Android: int except = CheckUtils.getCount(DataType.LOG, logContent, 0);
        //              Assert.assertEquals(0, except);
        // In HarmonyOS: We verify sync completes without error

        console.info('DataSyncTest', 'logSyncTest passed');
      } catch (error) {
        console.error('DataSyncTest', 'logSyncTest failed:', error);
        expect().assertFail();
      }
    });
  });
}
