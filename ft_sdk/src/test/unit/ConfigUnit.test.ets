import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DBCacheDiscard, DetectFrequency, EnvType, LogCacheDiscard, SyncPageSize } from '../../main/ets/components/enum/Enums';
import { Status as LogLevel } from '../../main/ets/components/bean/Status';
import { FTInTakeUrlHandler } from '../../main/ets/components/http/FTInTakeUrlHandler';
import { ActionEventWrapper } from '../../main/ets/components/rum/bean/ActionEventWrapper';
import { HandlerAction } from '../../main/ets/components/rum/bean/HandlerAction';
import { DeviceMetricsMonitorType } from '../../main/ets/components/rum/enum/DeviceMetricsMonitorType';
import { ErrorMonitorType } from '../../main/ets/components/rum/enum/ErrorMonitorType';
import { FTActionTrackingHandler } from '../../main/ets/components/rum/handler/FTActionTrackingHandler';
import { SyncTaskManager } from '../../main/ets/components/SyncTaskManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_CLIENT_TOKEN = 'fake_client_token';
const TEST_FAKE_RUM_ID = 'rumId';

function nullableTestValue<T>(value: T | null): T {
  return value as T;
}

class NamedLogStatus {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class EmptyLogStatus {
}

class TestActionTrackingHandler implements FTActionTrackingHandler {
  resolveHandlerAction(_actionEventWrapper: ActionEventWrapper): HandlerAction | null {
    return null;
  }
}

export default function configUnitTest() {
  describe('ConfigUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('sdkConfigShouldKeepDefaultServiceNameWhenEmpty', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setServiceName('');

      expect(config.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
    });

    it('sdkConfigShouldStoreEnvironmentValues', 0, () => {
      expect(FTSDKConfig.builder(TEST_FAKE_URL).getEnv()).assertEqual(EnvType.PROD.toString());
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setEnv(EnvType.GRAY).getEnv()).assertEqual(EnvType.GRAY.toString());
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setEnv('custom_env').getEnv()).assertEqual('custom_env');
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setEnv('').getEnv()).assertEqual(EnvType.PROD.toString());
    });

    it('sdkConfigShouldSupportDatakitAndDatawayBuilders', 0, () => {
      const datakitConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      expect(datakitConfig.getDatakitUrl()).assertEqual(TEST_FAKE_URL);

      const datawayConfig = FTSDKConfig.builder(TEST_FAKE_URL, TEST_FAKE_CLIENT_TOKEN);
      expect(datawayConfig.getDatawayUrl()).assertEqual(TEST_FAKE_URL);
      expect(datawayConfig.getClientToken()).assertEqual(TEST_FAKE_CLIENT_TOKEN);
    });

    it('sdkConfigShouldClampSyncOptions', 0, () => {
      expect(FTSDKConfig.builder(TEST_FAKE_URL).getPageSize()).assertEqual(SyncPageSize.MEDIUM);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncPageSize(SyncPageSize.MINI).getPageSize()).assertEqual(SyncPageSize.MINI);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncPageSize(1).getPageSize()).assertEqual(SyncPageSize.MINI);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncSleepTime(10000).getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MAX_TIME_MS);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setSyncSleepTime(-1).getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MINI_TIME_MS);
    });

    it('when sampleRate is NaN/negative/large should preserve NaN and clamp finite bounds', 0, () => {
      expect(Number.isNaN(new FTTraceConfig().setSamplingRate(Number.NaN).getSamplingRate())).assertTrue();
      expect(new FTRUMConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTTraceConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTRUMConfig().setSamplingRate(1.8).getSamplingRate()).assertEqual(1);

      expect(Number.isNaN(new FTLoggerConfig().setSamplingRate(Number.NaN).getSamplingRate())).assertTrue();
      expect(new FTLoggerConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTLoggerConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
    });

    it('when db/log/rum cache limit is 0/-1/overflow should fallback predictably', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(0)
        .setLogCacheLimitCount(-1)
        .setRumCacheLimitCount(-1);

      expect(config.getDbCacheLimit()).assertEqual(31457280);
      expect(config.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(config.getRumCacheLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);

      const overflowConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(9_999_999_999)
        .setLogCacheLimitCount(99_999)
        .setRumCacheLimitCount(88_888);

      expect(overflowConfig.getDbCacheLimit()).assertEqual(9_999_999_999);
      expect(overflowConfig.getLogCacheLimitCount()).assertEqual(99_999);
      expect(overflowConfig.getRumCacheLimitCount()).assertEqual(88_888);
    });

    it('when config objects are chained should keep last-wins policy deterministically', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(1)
        .setDbCacheLimit(2_000)
        .setDbCacheLimit(9_999_999_999)
        .setLogCacheLimitCount(-1)
        .setLogCacheLimitCount(12)
        .setRumCacheLimitCount(5)
        .setRumCacheLimitCount(-1);

      expect(config.getDbCacheLimit()).assertEqual(9_999_999_999);
      expect(config.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(config.getRumCacheLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
    });

    it('when cache size boundary crosses zero/upper bound should remain deterministic', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(-100)
        .setDbCacheLimit(0)
        .setDbCacheLimit(9_999_999_999);

      expect(config.getDbCacheLimit()).assertEqual(9_999_999_999);

      config.setDbCacheLimit(-1);
      expect(config.getDbCacheLimit()).assertEqual(31457280);
    });

    it('sdkConfigShouldStoreAutoSyncAndRetryOptions', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false).setDataSyncRetryCount(100);

      expect(config.isAutoSyncEnabled()).assertFalse();
      expect(config.getDataSyncRetryCount()).assertEqual(SyncTaskManager.MAX_ERROR_COUNT);

      expect(FTSDKConfig.builder(TEST_FAKE_URL).setDataSyncRetryCount(-1).getDataSyncRetryCount()).assertEqual(0);
      expect(FTSDKConfig.builder(TEST_FAKE_URL).setDataSyncRetryCount(0).getDataSyncRetryCount()).assertEqual(0);
    });

    it('rumConfigShouldClampUIBlockDuration', 0, () => {
      const defaultConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true);
      expect(defaultConfig.getBlockDurationMS()).assertEqual(1000);

      const customConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 1500);
      expect(customConfig.getBlockDurationMS()).assertEqual(1500);

      const minConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 90);
      expect(minConfig.getBlockDurationMS()).assertEqual(100);
    });

    it('rumConfigShouldCoverServiceRumAppIdAndUIBlockGetters', 0, () => {
      const rumConfig = new FTRUMConfig();

      expect(rumConfig.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      expect(rumConfig.getRumAppId()).assertEqual('');
      expect(rumConfig.isEnableTrackAppUIBlock()).assertFalse();

      rumConfig.setServiceName('rum-service');
      rumConfig
        .setRumAppId('rum-id')
        .setEnableTrackAppUIBlock(true, 500);

      expect(rumConfig.getServiceName()).assertEqual('rum-service');
      expect(rumConfig.getRumAppId()).assertEqual('rum-id');
      expect(rumConfig.isEnableTrackAppUIBlock()).assertTrue();
      expect(rumConfig.getBlockDurationMS()).assertEqual(500);
    });

    it('rumConfigShouldStoreOptionalHandlersAndMonitorSettings', 0, () => {
      const rumConfig = new FTRUMConfig();
      const resourceUrlHandler = new FTInTakeUrlHandler();
      const actionTrackingHandler = new TestActionTrackingHandler();

      rumConfig
        .setResourceUrlHandler(resourceUrlHandler)
        .setActionTrackingHandler(actionTrackingHandler)
        .setExtraMonitorTypeWithError(ErrorMonitorType.CPU)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)
        .setDeviceMetricsDetectFrequency(DetectFrequency.FREQUENT);

      expect(rumConfig.getResourceUrlHandler() === resourceUrlHandler).assertTrue();
      expect(rumConfig.getActionTrackingHandler() === actionTrackingHandler).assertTrue();
      expect(rumConfig.getExtraMonitorTypeWithError()).assertEqual(ErrorMonitorType.CPU);
      expect(rumConfig.getDeviceMetricsMonitorType()).assertEqual(DeviceMetricsMonitorType.MEMORY);
      expect(rumConfig.getDeviceMetricsDetectFrequency()).assertEqual(DetectFrequency.FREQUENT);

      rumConfig.setActionTrackingHandler(null);
      expect(rumConfig.getActionTrackingHandler() === null).assertTrue();
    });

    it('loggerConfigShouldClampCacheLimitAndSamplingRate', 0, () => {
      const config = new FTLoggerConfig().setLogCacheLimitCount(0).setSamplingRate(2);

      expect(config.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(config.getSamplingRate()).assertEqual(1);
      expect(new FTLoggerConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
    });

    it('rumConfigShouldClampSamplingRatesAndStoreSwitches', 0, () => {
      const rumConfig = new FTRUMConfig()
        .setSamplingRate(-1)
        .setSessionErrorSampleRate(2)
        .setEnableTrackAppCrash(true)
        .setEnableTrackAppANR(true)
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTraceWebView(true)
        .setEnableResourceHostIP(true);

      expect(rumConfig.getSamplingRate()).assertEqual(0);
      expect(rumConfig.getSessionErrorSampleRate()).assertEqual(1);
      expect(rumConfig.isEnableTrackAppCrash()).assertTrue();
      expect(rumConfig.isEnableTrackAppANR()).assertTrue();
      expect(rumConfig.isEnableTraceUserAction()).assertTrue();
      expect(rumConfig.isEnableTraceUserView()).assertTrue();
      expect(rumConfig.isEnableTraceUserResource()).assertTrue();
      expect(rumConfig.isEnableTraceWebView()).assertTrue();
      expect(rumConfig.isEnableResourceHostIP()).assertTrue();

      expect(new FTRUMConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTRUMConfig().setSessionErrorSampleRate(-1).getSessionErrorSampleRate()).assertEqual(0);
    });

    it('traceConfigShouldClampAndStoreOptions', 0, () => {
      const context = new Map<string, object>();
      context.set('trace_env', 'prod' as Object);
      const config = new FTTraceConfig()
        .setSamplingRate(2)
        .setTraceType(TraceType.TRACEPARENT)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setEnableWebTrace(true)
        .setServiceName('trace-service')
        .setGlobalContext(context)
        .setTraceContentType(['application/grpc']);

      expect(config.getSamplingRate()).assertEqual(1);
      expect(new FTTraceConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(config.getTraceType()).assertEqual(TraceType.TRACEPARENT);
      expect(config.isEnableAutoTrace()).assertTrue();
      expect(config.isEnableLinkRUMData()).assertTrue();
      expect(config.isEnableWebTrace()).assertTrue();
      expect(config.getServiceName()).assertEqual('trace-service');
      expect(config.getGlobalContext().get('trace_env')).assertEqual('prod');
      expect(config.getTraceContentType()[0]).assertEqual('application/grpc');
    });

    it('traceConfigShouldAddSingleGlobalContextItem', 0, () => {
      const config = new FTTraceConfig().addGlobalContext('trace_key', 'trace_value' as Object);

      expect(config.getGlobalContext().get('trace_key')).assertEqual('trace_value');
    });

    it('sdkConfigShouldClampCacheOptions', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(1)
        .setLogCacheLimitCount(1)
        .setRumCacheLimitCount(1)
        .setNeedTransformOldCache(true)
        .setEnableAccessDeviceID(true)
        .setOnlySupportMainProcess(false);

      expect(config.getDbCacheLimit()).assertEqual(31457280);
      expect(config.getLogCacheLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(config.getRumCacheLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
      expect(config.isNeedTransformOldCache()).assertTrue();
      expect(config.isAccessODIDEnabled()).assertTrue();
      expect(config.isOnlySupportMainProcess()).assertFalse();
    });

    it('sdkConfigShouldStoreDiscardStrategies', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');

      expect(config.getDBCacheDiscard()).assertEqual('discard_oldest');
      expect(config.getLogCacheDiscard()).assertEqual('discard_oldest');
      expect(config.getRumCacheDiscard()).assertEqual('discard_oldest');
    });

    it('sdkConfigShouldEnableDbSizeLimitExplicitly', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL);
      const defaultDbCacheLimit = config.getDbCacheLimit();

      expect(config.isLimitWithDbSize()).assertFalse();
      config.enableLimitWithDbSize();

      expect(config.isLimitWithDbSize()).assertTrue();
      expect(config.getDbCacheLimit()).assertEqual(defaultDbCacheLimit);
    });

    it('sdkConfigShouldIgnoreEmptyPackageInfo', 0, () => {
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .addPkgInfo('', 'ignored')
        .addPkgInfo('native', '')
        .addPkgInfo('web', '1.2.3');

      expect(config.getPkgInfo().size).assertEqual(1);
      expect(config.getPkgInfo().get('web')).assertEqual('1.2.3');
    });

    it('loggerConfigShouldStoreConsoleFiltersAndDiscardStrategy', 0, () => {
      const config = new FTLoggerConfig()
        .setEnableConsoleLog(true, 'FT-')
        .setEnableCustomLog(true)
        .setEnableLinkRumData(true)
        .setLogLevelFilters([LogLevel.ERROR, 'warn', new NamedLogStatus('info')])
        .setPrintCustomLogToConsole(true)
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST)
        .addGlobalContext('logger_env', 'prod');

      expect(config.isEnableConsoleLog()).assertTrue();
      expect(config.isEnableCustomLog()).assertTrue();
      expect(config.isEnableLinkRumData()).assertTrue();
      expect(config.checkPrefix('FT-message')).assertTrue();
      expect(config.checkPrefix('message')).assertFalse();
      expect(config.checkLogLevel(LogLevel.ERROR.name)).assertTrue();
      expect(config.checkLogLevel('warn')).assertTrue();
      expect(config.checkLogLevel('debug')).assertFalse();
      expect(config.isPrintCustomLogToConsole()).assertTrue();
      expect(config.getLogCacheDiscardStrategy()).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(String(config.getGlobalContext().get('logger_env'))).assertEqual('prod');

      const noPrefixConfig = new FTLoggerConfig().setEnableConsoleLog(true);
      expect(noPrefixConfig.isEnableConsoleLog()).assertTrue();
      expect(noPrefixConfig.checkPrefix('message')).assertTrue();
    });

    it('loggerConfigShouldCoverServiceAndLogLevelGetter', 0, () => {
      const config = new FTLoggerConfig();

      expect(config.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      config.setServiceName('logger-service');
      config.setLogLevelFilters([
        LogLevel.INFO,
        LogLevel.ERROR,
        new EmptyLogStatus(),
        nullableTestValue<EmptyLogStatus>(null)
      ]);

      const logLevelFilters = config.getLogLevelFilters();
      expect(config.getServiceName()).assertEqual('logger-service');
      expect(logLevelFilters.length).assertEqual(4);
      expect(logLevelFilters[0]).assertEqual(LogLevel.INFO.name);
      expect(logLevelFilters[1]).assertEqual(LogLevel.ERROR.name);
      expect(logLevelFilters[2]).assertEqual('[object Object]');
      expect(logLevelFilters[3]).assertEqual('null');
    });
  });
}
