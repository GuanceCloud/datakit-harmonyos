/**
 * Remote configuration test
 * Reference: com.ft.sdk.tests.RemoteConfigTest (Android SDK)
 *
 * Purpose: Verify remote configuration parsing and application
 *
 * @author FT SDK Team
 */



import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';

// Test constants (aligned with Android SDK)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';

// Define interfaces for remote config data
interface RemoteConfigContent {
  serviceName: string | number;
  env: string | number;
  autoSync: boolean | string;
  compressIntakeRequests: boolean | number;
  syncPageSize: number | string;
  syncSleepTime: number | string;
  rumSampleRate: number | string;
  rumSessionOnErrorSampleRate: number | string;
  rumEnableTraceUserAction: boolean | number;
  rumEnableTraceUserView: boolean | number;
  rumEnableTraceUserResource: boolean | number;
  rumEnableResourceHostIP: boolean | number;
  rumEnableTrackAppUIBlock: boolean | number;
  rumBlockDurationMs: number | string;
  rumEnableTrackAppCrash: boolean | number;
  rumEnableTrackAppANR: boolean | number;
  rumEnableTraceWebView: boolean | number;
  rumAllowWebViewHost: string[] | number;
  logSampleRate: number | string;
  logLevelFilters: string[] | number;
  logEnableCustomLog: boolean | number;
  logEnableConsoleLog: boolean | number;
  traceSampleRate: number | string;
  traceEnableAutoTrace: boolean | number;
  traceType: string | number;
}

interface RemoteConfigData {
  md5: string | number;
  content: RemoteConfigContent;
}

// Test values (aligned with Android SDK)
const VALUE_MD5 = 'xxx';
const VALUE_SERVICE_NAME = 'testService';
const VALUE_ENV = 'prod';
const VALUE_AUTO_SYNC = true;
const VALUE_COMPRESS_INTAKE_REQUESTS = true;
const VALUE_SYNC_PAGE_SIZE = 100;
const VALUE_SYNC_SLEEP_TIME = 5000;
const VALUE_RUM_SAMPLE_RATE = 0.8;
const VALUE_RUM_SESSION_ON_ERROR_SAMPLE_RATE = 0.9;
const VALUE_RUM_ENABLE_TRACE_USER_ACTION = true;
const VALUE_RUM_ENABLE_TRACE_USER_VIEW = true;
const VALUE_RUM_ENABLE_RESOURCE_HOST_IP = true;
const VALUE_RUM_ENABLE_TRACE_USER_RESOURCE = true;
const VALUE_RUM_ENABLE_TRACK_APP_UIBLOCK = true;
const VALUE_RUM_BLOCK_DURATION_MS = 3000;
const VALUE_RUM_ENABLE_TRACK_APP_CRASH = true;
const VALUE_RUM_ENABLE_TRACK_APP_ANR = true;
const VALUE_RUM_ENABLE_TRACE_WEB_VIEW = true;
const VALUE_RUM_ALLOW_WEB_VIEW_HOST = ['example.com', 'api.example.com'];
const VALUE_LOG_SAMPLE_RATE = 0.5;
const VALUE_LOG_LEVEL_FILTERS = ['error', 'warn', 'info'];
const VALUE_LOG_ENABLE_CUSTOM_LOG = true;
const VALUE_LOG_ENABLE_CONSOLE_LOG = true;
const VALUE_TRACE_SAMPLE_RATE = 0.7;
const VALUE_TRACE_ENABLE_AUTO_TRACE = true;
const VALUE_TRACE_TYPE = 'zipkin_single_header';

// Normal config JSON (aligned with Android SDK)
const NORMAL_JSON_STRING = `{
  "md5": "${VALUE_MD5}",
  "content": {
    "serviceName": "${VALUE_SERVICE_NAME}",
    "env": "${VALUE_ENV}",
    "autoSync": ${VALUE_AUTO_SYNC},
    "compressIntakeRequests": ${VALUE_COMPRESS_INTAKE_REQUESTS},
    "syncPageSize": ${VALUE_SYNC_PAGE_SIZE},
    "syncSleepTime": ${VALUE_SYNC_SLEEP_TIME},
    "rumSampleRate": ${VALUE_RUM_SAMPLE_RATE},
    "rumSessionOnErrorSampleRate": ${VALUE_RUM_SESSION_ON_ERROR_SAMPLE_RATE},
    "rumEnableTraceUserAction": ${VALUE_RUM_ENABLE_TRACE_USER_ACTION},
    "rumEnableTraceUserView": ${VALUE_RUM_ENABLE_TRACE_USER_VIEW},
    "rumEnableTraceUserResource": ${VALUE_RUM_ENABLE_TRACE_USER_RESOURCE},
    "rumEnableResourceHostIP": ${VALUE_RUM_ENABLE_RESOURCE_HOST_IP},
    "rumEnableTrackAppUIBlock": ${VALUE_RUM_ENABLE_TRACK_APP_UIBLOCK},
    "rumBlockDurationMs": ${VALUE_RUM_BLOCK_DURATION_MS},
    "rumEnableTrackAppCrash": ${VALUE_RUM_ENABLE_TRACK_APP_CRASH},
    "rumEnableTrackAppANR": ${VALUE_RUM_ENABLE_TRACK_APP_ANR},
    "rumEnableTraceWebView": ${VALUE_RUM_ENABLE_TRACE_WEB_VIEW},
    "rumAllowWebViewHost": ${JSON.stringify(VALUE_RUM_ALLOW_WEB_VIEW_HOST)},
    "logSampleRate": ${VALUE_LOG_SAMPLE_RATE},
    "logLevelFilters": ${JSON.stringify(VALUE_LOG_LEVEL_FILTERS)},
    "logEnableCustomLog": ${VALUE_LOG_ENABLE_CUSTOM_LOG},
    "logEnableConsoleLog": ${VALUE_LOG_ENABLE_CONSOLE_LOG},
    "traceSampleRate": ${VALUE_TRACE_SAMPLE_RATE},
    "traceEnableAutoTrace": ${VALUE_TRACE_ENABLE_AUTO_TRACE},
    "traceType": "${VALUE_TRACE_TYPE}"
  }
}`;

// Invalid config JSON (aligned with Android SDK)
const INVALID_JSON_STRING = `{
  "md5": -1,
  "content": {
    "serviceName": -1,
    "env": -1,
    "autoSync": "error_value",
    "compressIntakeRequests": -1,
    "syncPageSize": "error_value",
    "syncSleepTime": "error_value",
    "rumSampleRate": "error_value",
    "rumSessionOnErrorSampleRate": "error_value",
    "rumEnableTraceUserAction": -1,
    "rumEnableTraceUserView": -1,
    "rumEnableTraceUserResource": -1,
    "rumEnableResourceHostIP": -1,
    "rumEnableTrackAppUIBlock": -1,
    "rumBlockDurationMs": "error_value",
    "rumEnableTrackAppCrash": -1,
    "rumEnableTrackAppANR": -1,
    "rumEnableTraceWebView": -1,
    "rumAllowWebViewHost": -1,
    "logSampleRate": "error_value",
    "logLevelFilters": -1,
    "logEnableCustomLog": -1,
    "logEnableConsoleLog": -1,
    "traceSampleRate": "error_value",
    "traceEnableAutoTrace": -1,
    "traceType": -1
  }
}`;

export default function remoteConfigTest() {
  describe('RemoteConfigTest', () => {
    beforeAll(() => {
      console.info('RemoteConfigTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('RemoteConfigTest', 'beforeEach called');
    });

    afterEach(() => {
      console.info('RemoteConfigTest', 'afterEach called');
      // Clean up after each test
      FTSDK.shutDown();
    });

    afterAll(() => {
      console.info('RemoteConfigTest', 'afterAll called');
    });

    /**
     * Test normal configuration parsing
     * Aligned with Android: normalConfig()
     *
     * Note: HarmonyOS SDK doesn't have RemoteConfigBean class like Android.
     * We test the config values directly through FTSDKConfig.
     */
    it('normalConfig', 0, () => {
      try {
        const configData: RemoteConfigData = JSON.parse(NORMAL_JSON_STRING) as RemoteConfigData;
        const content: RemoteConfigContent = configData.content;

        // Verify service name and env
        expect(content.serviceName).assertEqual(VALUE_SERVICE_NAME);
        expect(content.env).assertEqual(VALUE_ENV);
        expect(content.autoSync).assertEqual(VALUE_AUTO_SYNC);
        expect(content.compressIntakeRequests).assertEqual(VALUE_COMPRESS_INTAKE_REQUESTS);
        expect(content.syncPageSize).assertEqual(VALUE_SYNC_PAGE_SIZE);
        expect(content.syncSleepTime).assertEqual(VALUE_SYNC_SLEEP_TIME);
        expect(content.rumSampleRate).assertEqual(VALUE_RUM_SAMPLE_RATE);
        expect(content.rumSessionOnErrorSampleRate).assertEqual(VALUE_RUM_SESSION_ON_ERROR_SAMPLE_RATE);
        expect(content.rumEnableTraceUserAction).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_ACTION);
        expect(content.rumEnableTraceUserView).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_VIEW);
        expect(content.rumEnableTraceUserResource).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_RESOURCE);
        expect(content.rumEnableResourceHostIP).assertEqual(VALUE_RUM_ENABLE_RESOURCE_HOST_IP);
        expect(content.rumEnableTrackAppUIBlock).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_UIBLOCK);
        expect(content.rumBlockDurationMs).assertEqual(VALUE_RUM_BLOCK_DURATION_MS);
        expect(content.rumEnableTrackAppCrash).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_CRASH);
        expect(content.rumEnableTrackAppANR).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_ANR);
        expect(content.rumEnableTraceWebView).assertEqual(VALUE_RUM_ENABLE_TRACE_WEB_VIEW);
        expect(JSON.stringify(content.rumAllowWebViewHost)).assertEqual(JSON.stringify(VALUE_RUM_ALLOW_WEB_VIEW_HOST));
        expect(content.logSampleRate).assertEqual(VALUE_LOG_SAMPLE_RATE);
        expect(JSON.stringify(content.logLevelFilters)).assertEqual(JSON.stringify(VALUE_LOG_LEVEL_FILTERS));
        expect(content.logEnableCustomLog).assertEqual(VALUE_LOG_ENABLE_CUSTOM_LOG);
        expect(content.logEnableConsoleLog).assertEqual(VALUE_LOG_ENABLE_CONSOLE_LOG);
        expect(content.traceSampleRate).assertEqual(VALUE_TRACE_SAMPLE_RATE);
        expect(content.traceEnableAutoTrace).assertEqual(VALUE_TRACE_ENABLE_AUTO_TRACE);
        expect(content.traceType).assertEqual(VALUE_TRACE_TYPE);

        console.info('RemoteConfigTest', 'normalConfig passed');
      } catch (error) {
        console.error('RemoteConfigTest', 'normalConfig failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Test invalid configuration handling
     * Aligned with Android: invalidConfig()
     *
     * Note: HarmonyOS SDK handles invalid values differently.
     * We test that JSON parsing doesn't crash.
     */
    it('invalidConfig', 0, () => {
      try {
        // Parse the invalid JSON (it's actually valid JSON with invalid values)
        const configData: RemoteConfigData = JSON.parse(INVALID_JSON_STRING) as RemoteConfigData;
        const content: RemoteConfigContent = configData.content;

        // Verify that invalid values are preserved as-is
        // In HarmonyOS, we don't do type validation at parse time
        expect(content.serviceName).assertEqual(-1);
        expect(content.autoSync).assertEqual('error_value'); // Strings are preserved

        console.info('RemoteConfigTest', 'invalidConfig passed');
      } catch (error) {
        console.error('RemoteConfigTest', 'invalidConfig failed:', error);
        expect().assertFail();
      }
    });

    /**
     * Test local cache configuration
     * Aligned with Android: localCacheTest()
     *
     * Note: HarmonyOS doesn't have SharedPreferences like Android.
     * We test the config values directly.
     */
    it('localCacheTest', 0, () => {
      try {
        // Parse the normal config
        const configData: RemoteConfigData = JSON.parse(NORMAL_JSON_STRING) as RemoteConfigData;
        const content: RemoteConfigContent = configData.content;

        // Create SDK config with remote values
        const sdkConfig = FTSDKConfig.builder(TEST_FAKE_URL)
          .setServiceName(content.serviceName as string)
          .setEnv(content.env as string)
          .setAutoSync(content.autoSync as boolean)
          .setSyncPageSize(content.syncPageSize as number)
          .setSyncSleepTime(content.syncSleepTime as number);

        FTSDK.install(sdkConfig);

        // Create RUM config with remote values
        const rumConfig = new FTRUMConfig()
          .setRumAppId(TEST_FAKE_RUM_ID)
          .setSamplingRate(content.rumSampleRate as number)
          .setSessionErrorSampleRate(content.rumSessionOnErrorSampleRate as number)
          .setEnableTraceUserAction(content.rumEnableTraceUserAction as boolean)
          .setEnableTraceUserView(content.rumEnableTraceUserView as boolean)
          .setEnableTraceUserResource(content.rumEnableTraceUserResource as boolean)
          .setEnableResourceHostIP(content.rumEnableResourceHostIP as boolean)
          .setEnableTrackAppUIBlock(content.rumEnableTrackAppUIBlock as boolean, content.rumBlockDurationMs as number)
          .setEnableTrackAppCrash(content.rumEnableTrackAppCrash as boolean)
          .setEnableTrackAppANR(content.rumEnableTrackAppANR as boolean)
          .setEnableTraceWebView(content.rumEnableTraceWebView as boolean);

        // Note: HarmonyOS doesn't have setAllowWebViewHost method yet
        // FTSDK.installRUMConfig(rumConfig);

        // Create log config with remote values
        const logConfig = new FTLoggerConfig()
          .setSamplingRate(content.logSampleRate as number)
          .setEnableCustomLog(content.logEnableCustomLog as boolean)
          .setEnableConsoleLog(content.logEnableConsoleLog as boolean);

        // FTSDK.installLogConfig(logConfig);

        // Create trace config with remote values
        // Note: HarmonyOS uses TraceType enum, not string
        // const traceConfig = new FTTraceConfig()
        //   .setSamplingRate(content.traceSampleRate)
        //   .setEnableAutoTrace(content.traceEnableAutoTrace);
        // FTSDK.installTraceConfig(traceConfig);

        // Verify the SDK config values
        expect(sdkConfig.getServiceName()).assertEqual(VALUE_SERVICE_NAME);
        expect(sdkConfig.getEnv()).assertEqual(VALUE_ENV);
        expect(sdkConfig.isAutoSyncEnabled()).assertEqual(VALUE_AUTO_SYNC);
        expect(sdkConfig.getPageSize()).assertEqual(VALUE_SYNC_PAGE_SIZE);
        expect(sdkConfig.getSyncSleepTime()).assertEqual(VALUE_SYNC_SLEEP_TIME);

        // Verify the RUM config values
        expect(rumConfig.getSamplingRate()).assertEqual(VALUE_RUM_SAMPLE_RATE);
        expect(rumConfig.getSessionErrorSampleRate()).assertEqual(VALUE_RUM_SESSION_ON_ERROR_SAMPLE_RATE);
        expect(rumConfig.isEnableTraceUserAction()).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_ACTION);
        expect(rumConfig.isEnableTraceUserView()).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_VIEW);
        expect(rumConfig.isEnableTraceUserResource()).assertEqual(VALUE_RUM_ENABLE_TRACE_USER_RESOURCE);
        expect(rumConfig.isEnableResourceHostIP()).assertEqual(VALUE_RUM_ENABLE_RESOURCE_HOST_IP);
        expect(rumConfig.isEnableTrackAppUIBlock()).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_UIBLOCK);
        expect(rumConfig.getBlockDurationMS()).assertEqual(VALUE_RUM_BLOCK_DURATION_MS);
        expect(rumConfig.isEnableTrackAppCrash()).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_CRASH);
        expect(rumConfig.isEnableTrackAppANR()).assertEqual(VALUE_RUM_ENABLE_TRACK_APP_ANR);
        expect(rumConfig.isEnableTraceWebView()).assertEqual(VALUE_RUM_ENABLE_TRACE_WEB_VIEW);

        // Verify the log config values
        expect(logConfig.getSamplingRate()).assertEqual(VALUE_LOG_SAMPLE_RATE);
        expect(logConfig.isEnableCustomLog()).assertEqual(VALUE_LOG_ENABLE_CUSTOM_LOG);
        expect(logConfig.isEnableConsoleLog()).assertEqual(VALUE_LOG_ENABLE_CONSOLE_LOG);

        console.info('RemoteConfigTest', 'localCacheTest passed');
      } catch (error) {
        console.error('RemoteConfigTest', 'localCacheTest failed:', error);
        expect().assertFail();
      }
    });
  });
}
