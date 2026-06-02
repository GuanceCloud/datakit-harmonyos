import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DBCacheDiscard, EnvType, LogCacheDiscard, SyncPageSize } from '../../main/ets/components/enum/Enums';
import { Status as LogLevel } from '../../main/ets/components/bean/Status';
import { DeviceMetricsMonitorType } from '../../main/ets/components/rum/enum/DeviceMetricsMonitorType';
import { ErrorMonitorType } from '../../main/ets/components/rum/enum/ErrorMonitorType';
import { SyncTaskManager } from '../../main/ets/components/SyncTaskManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_CLIENT_TOKEN = 'fake_client_token';
const TEST_FAKE_RUM_ID = 'rumId';

export default function configUnitTest() {
  describe('ConfigUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('sdkConfigShouldPreserveUserFacingDefaultsAndDataTargets', 0, () => {
      const datakitConfig = FTSDKConfig.builder(TEST_FAKE_URL).setServiceName('').setEnv('');
      const datawayConfig = FTSDKConfig.builder(TEST_FAKE_URL, TEST_FAKE_CLIENT_TOKEN).setEnv(EnvType.GRAY);

      expect(datakitConfig.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      expect(datakitConfig.getEnv()).assertEqual(EnvType.PROD.toString());
      expect(datakitConfig.getDatakitUrl()).assertEqual(TEST_FAKE_URL);
      expect(datawayConfig.getEnv()).assertEqual(EnvType.GRAY.toString());
      expect(datawayConfig.getDatawayUrl()).assertEqual(TEST_FAKE_URL);
      expect(datawayConfig.getClientToken()).assertEqual(TEST_FAKE_CLIENT_TOKEN);
    });

    it('sdkConfigShouldClampSyncRetryAndCacheBoundaries', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(1)
        .setSyncSleepTime(10000)
        .setDataSyncRetryCount(100)
        .setDbCacheLimit(1)
        .setLogCacheLimitCount(0)
        .setRumCacheLimitCount(0)
        .setAutoSync(false);

      expect(config.getPageSize()).assertEqual(SyncPageSize.MINI);
      expect(config.getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MAX_TIME_MS);
      expect(config.getDataSyncRetryCount()).assertEqual(SyncTaskManager.MAX_ERROR_COUNT);
      expect(config.getDbCacheLimit()).assertEqual(31457280);
      expect(config.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(config.getRumCacheLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
      expect(config.isAutoSyncEnabled()).assertFalse();

      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncSleepTime(-1).getSyncSleepTime())
        .assertEqual(SyncTaskManager.SYNC_SLEEP_MINI_TIME_MS);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setDataSyncRetryCount(-1).getDataSyncRetryCount()).assertEqual(0);
    });

    it('sdkConfigShouldStoreDiscardStrategiesAndIntegerCompatibleFlag', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest')
        .enableLimitWithDbSize()
        .enableDataIntegerCompatible();

      expect(config.getDBCacheDiscard()).assertEqual('discard_oldest');
      expect(config.getLogCacheDiscard()).assertEqual('discard_oldest');
      expect(config.getRumCacheDiscard()).assertEqual('discard_oldest');
      expect(config.isLimitWithDbSize()).assertTrue();
      expect(config.isDataIntegerCompatible()).assertTrue();
    });

    it('samplingRatesShouldClampFiniteBoundsAndExposeNaNAsCurrentBehavior', 0, () => {
      expect(new FTRUMConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTRUMConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTRUMConfig().setSessionErrorSampleRate(-1).getSessionErrorSampleRate()).assertEqual(0);
      expect(new FTRUMConfig().setSessionErrorSampleRate(2).getSessionErrorSampleRate()).assertEqual(1);
      expect(new FTLoggerConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTLoggerConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTTraceConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTTraceConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(Number.isNaN(new FTLoggerConfig().setSamplingRate(Number.NaN).getSamplingRate())).assertTrue();
    });

    it('rumConfigShouldKeepPublicFeatureSwitchesAndMonitorSettings', 0, () => {
      const config = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 90)
        .setEnableTrackAppCrash(true)
        .setEnableTrackAppANR(true)
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTraceWebView(true)
        .setExtraMonitorTypeWithError(ErrorMonitorType.CPU)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY);

      expect(config.getRumAppId()).assertEqual(TEST_FAKE_RUM_ID);
      expect(config.getBlockDurationMS()).assertEqual(100);
      expect(config.isEnableTrackAppCrash()).assertTrue();
      expect(config.isEnableTrackAppANR()).assertTrue();
      expect(config.isEnableTraceUserAction()).assertTrue();
      expect(config.isEnableTraceUserView()).assertTrue();
      expect(config.isEnableTraceUserResource()).assertTrue();
      expect(config.isEnableTraceWebView()).assertTrue();
      expect(config.getExtraMonitorTypeWithError()).assertEqual(ErrorMonitorType.CPU);
      expect(config.getDeviceMetricsMonitorType()).assertEqual(DeviceMetricsMonitorType.MEMORY);
    });

    it('loggerAndTraceConfigsShouldKeepPublicUploadAndTraceOptions', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setEnableCustomLog(true)
        .setEnableConsoleLog(true, 'FT-')
        .setEnableLinkRumData(true)
        .setLogLevelFilters([LogLevel.ERROR, 'warn'])
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST)
        .setPrintCustomLogToConsole(true);
      const traceContext = new Map<string, object>();
      traceContext.set('trace_env', 'prod' as Object);
      const traceConfig = new FTTraceConfig()
        .setTraceType(TraceType.TRACEPARENT)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setEnableWebTrace(true)
        .setServiceName('trace-service')
        .setGlobalContext(traceContext);

      expect(loggerConfig.isEnableCustomLog()).assertTrue();
      expect(loggerConfig.isEnableConsoleLog()).assertTrue();
      expect(loggerConfig.isEnableLinkRumData()).assertTrue();
      expect(loggerConfig.checkPrefix('FT-message')).assertTrue();
      expect(loggerConfig.checkLogLevel(LogLevel.ERROR.name)).assertTrue();
      expect(loggerConfig.checkLogLevel('warn')).assertTrue();
      expect(loggerConfig.getLogCacheDiscardStrategy()).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(loggerConfig.isPrintCustomLogToConsole()).assertTrue();
      expect(traceConfig.getTraceType()).assertEqual(TraceType.TRACEPARENT);
      expect(traceConfig.isEnableAutoTrace()).assertTrue();
      expect(traceConfig.isEnableLinkRUMData()).assertTrue();
      expect(traceConfig.isEnableWebTrace()).assertTrue();
      expect(traceConfig.getServiceName()).assertEqual('trace-service');
      expect(traceConfig.getGlobalContext().get('trace_env')).assertEqual('prod');
    });
  });
}
