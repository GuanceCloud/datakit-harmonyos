/**
 * Configuration parameter debugging test cases
 * Adapted from Android SDK: com.ft.sdk.tests.ConfigTest
 *
 * Purpose: Avoid low-level code errors causing configuration bugs
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DataType, DBCacheDiscard, EnvType, LogCacheDiscard, RUMCacheDiscard, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { ConfigRecord, SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';
import { FTRUMConfigManager } from '../../../main/ets/components/rum/FTRUMConfigManager';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { SyncDataHelper } from '../../../main/ets/components/SyncDataHelper';
import { FTTraceConfigManager } from '../../../main/ets/components/trace/FTTraceConfigManager';

// Test constants (aligned with Android FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const TEST_FAKE_CLIENT_TOKEN = 'fake_client_token';

class TestConfigRecord implements ConfigRecord {
  private config: FTSDKConfig;

  constructor(config: FTSDKConfig) {
    this.config = config;
  }

  isLimitWithDbSize(): boolean {
    return this.config.isLimitWithDbSize();
  }

  getDbCacheLimit(): number {
    return this.config.getDbCacheLimit();
  }

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }
}

export default function configTest() {
  describe('ConfigTest', () => {
    beforeAll(() => {
      console.info('ConfigTest', 'ConfigTest beforeAll called');
    });

    beforeEach(() => {
      console.info('ConfigTest', 'ConfigTest beforeEach called');
      // Reset FTDBCachePolicy state before each test to avoid interference
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    afterEach(() => {
      console.info('ConfigTest', 'ConfigTest afterEach called');
      // Clean up after each test
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    afterAll(() => {
      console.info('ConfigTest', 'ConfigTest afterAll called');
    });

    /**
     * Validate default value for empty service name parameter
     * Adapted from Android: uses FTSDK.install()
     */
    it('emptyServiceNameShouldFallback', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setServiceName('');
      FTSDK.install(sdkConfig);
      expect(sdkConfig.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);

      console.info('ConfigTest', 'emptyServiceName passed');
    });

    /**
     * Normal service name parameter
     * Adapted from Android: uses FTSDK.install()
     */
    it('serviceNameShouldUseCustomValue', 0, () => {
      const testName = 'Test';
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setServiceName(testName);
      FTSDK.install(sdkConfig);
      expect(sdkConfig.getServiceName()).assertEqual(testName);

      console.info('ConfigTest', 'normalServiceName passed');
    });

    /**
     * Validate default value for env
     */
    it('emptyEnvShouldFallback', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      // Default env is PROD when not set
      expect(sdkConfig.getEnv()).assertEqual(EnvType.PROD.toString());

      console.info('ConfigTest', 'emptyEnv passed');
    });

    /**
     * Validate env parameter
     */
    it('enumEnvShouldApply', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setEnv(EnvType.GRAY);
      expect(sdkConfig.getEnv()).assertEqual(EnvType.GRAY.toString());

      console.info('ConfigTest', 'enumEnv passed');
    });

    /**
     * Validate env parameter
     */
    it('customEnvShouldApply', 0, () => {
      const customEnv = 'custom_env';
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setEnv(customEnv);
      expect(sdkConfig.getEnv()).assertEqual(customEnv);

      console.info('ConfigTest', 'customEnv passed');
    });

    /**
     * Validate appId setting
     * Adapted from Android: FTSdk.install() + FTSdk.initRUMWithConfig()
     * Note: HarmonyOS test doesn't have context, so we call FTSDK.install() without context
     */
    it('rumAppIdShouldApply', 0, () => {
      // Install SDK (without context for unit test)
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(sdkConfig);

      // Init RUM config (aligned with Android: FTSdk.initRUMWithConfig())
      const appId = 'appIdxxxxxx';
      const rumConfig: FTRUMConfig = new FTRUMConfig().setRumAppId(appId);
      FTSDK.installRUMConfig(rumConfig);

      // Verify rumAppId is set correctly (aligned with Android: FTRUMConfigManager.get().getConfig().getRumAppId())
      // HarmonyOS uses: FTSDK.getRumConfig()
      const installedRumConfig = FTSDK.getRumConfig();
      expect(installedRumConfig !== null).assertTrue();
      expect(installedRumConfig!.getRumAppId()).assertEqual(appId);

      // Verify RUM is enabled when rumAppId is set (aligned with Android: FTRUMConfigManager.get().isRumEnable())
      // Android: isRumEnable() returns config.getRumAppId() != null
      // HarmonyOS: RUM is enabled when rumAppId.length > 0
      const isRumEnable = installedRumConfig!.getRumAppId().length > 0;
      expect(isRumEnable).assertTrue();

      console.info('ConfigTest', 'rumAppId passed');
    });

    /**
     * Validate RUM sampling rate defaults, setters and finite boundary clamping.
     */
    it('rumSamplingRateShouldClamp', 0, () => {
      const defaultConfig: FTRUMConfig = new FTRUMConfig();
      expect(defaultConfig.getSamplingRate()).assertEqual(1.0);
      expect(defaultConfig.getSessionErrorSampleRate()).assertEqual(0.0);

      const customConfig: FTRUMConfig = new FTRUMConfig()
        .setSamplingRate(0.25)
        .setSessionErrorSampleRate(0.5);
      expect(customConfig.getSamplingRate()).assertEqual(0.25);
      expect(customConfig.getSessionErrorSampleRate()).assertEqual(0.5);

      expect(new FTRUMConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTRUMConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);
      expect(new FTRUMConfig().setSessionErrorSampleRate().getSessionErrorSampleRate()).assertEqual(0.0);
      expect(new FTRUMConfig().setSessionErrorSampleRate(-1).getSessionErrorSampleRate()).assertEqual(0);
      expect(new FTRUMConfig().setSessionErrorSampleRate(2).getSessionErrorSampleRate()).assertEqual(1);

      console.info('ConfigTest', 'rumSamplingRate passed');
    });

    /**
     * Validate installed RUM config keeps sampling rates in SDK and config manager state.
     */
    it('installedRumSamplingShouldApply', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(sdkConfig);

      const rumConfig: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setSamplingRate(0.25)
        .setSessionErrorSampleRate(0.5);
      FTSDK.installRUMConfig(rumConfig);

      const installedRumConfig = FTSDK.getRumConfig();
      expect(installedRumConfig !== null).assertTrue();
      expect(installedRumConfig!.getSamplingRate()).assertEqual(0.25);
      expect(installedRumConfig!.getSessionErrorSampleRate()).assertEqual(0.5);

      const managedRumConfig = FTRUMConfigManager.getInstance().getConfig();
      expect(managedRumConfig !== null).assertTrue();
      expect(managedRumConfig!.getSamplingRate()).assertEqual(0.25);
      expect(managedRumConfig!.getSessionErrorSampleRate()).assertEqual(0.5);

      console.info('ConfigTest', 'rumSamplingRateInstallConfig passed');
    });

    /**
     * Validate RUM feature switch defaults, setters and installed config state.
     */
    it('rumAnrSwitchShouldApply', 0, () => {
      const defaultConfig: FTRUMConfig = new FTRUMConfig();
      expect(defaultConfig.isEnableTrackAppANR()).assertFalse();
      expect(defaultConfig.isEnableTraceWebView()).assertFalse();
      expect(defaultConfig.isEnableTraceUserResource()).assertFalse();

      const enabledConfig: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppANR(true)
        .setEnableTraceWebView(true)
        .setEnableTraceUserResource(true);
      expect(enabledConfig.isEnableTrackAppANR()).assertTrue();
      expect(enabledConfig.isEnableTraceWebView()).assertTrue();
      expect(enabledConfig.isEnableTraceUserResource()).assertTrue();

      const disabledConfig: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppANR(false)
        .setEnableTraceWebView(false)
        .setEnableTraceUserResource(false);
      expect(disabledConfig.isEnableTrackAppANR()).assertFalse();
      expect(disabledConfig.isEnableTraceWebView()).assertFalse();
      expect(disabledConfig.isEnableTraceUserResource()).assertFalse();

      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL));
      FTSDK.installRUMConfig(enabledConfig);

      const installedRumConfig = FTSDK.getRumConfig();
      expect(installedRumConfig !== null).assertTrue();
      expect(installedRumConfig!.isEnableTrackAppANR()).assertTrue();
      expect(installedRumConfig!.isEnableTraceWebView()).assertTrue();
      expect(installedRumConfig!.isEnableTraceUserResource()).assertTrue();

      const managedRumConfig = FTRUMConfigManager.getInstance().getConfig();
      expect(managedRumConfig !== null).assertTrue();
      expect(managedRumConfig!.isEnableTrackAppANR()).assertTrue();
      expect(managedRumConfig!.isEnableTraceWebView()).assertTrue();
      expect(managedRumConfig!.isEnableTraceUserResource()).assertTrue();

      FTSDK.installRUMConfig(disabledConfig);
      expect(FTSDK.getRumConfig()!.isEnableTrackAppANR()).assertFalse();
      expect(FTSDK.getRumConfig()!.isEnableTraceWebView()).assertFalse();
      expect(FTSDK.getRumConfig()!.isEnableTraceUserResource()).assertFalse();
      expect(FTRUMConfigManager.getInstance().getConfig()!.isEnableTrackAppANR()).assertFalse();
      expect(FTRUMConfigManager.getInstance().getConfig()!.isEnableTraceWebView()).assertFalse();
      expect(FTRUMConfigManager.getInstance().getConfig()!.isEnableTraceUserResource()).assertFalse();

      console.info('ConfigTest', 'rumTrackAppANR passed');
    });

    /**
     * Validate RUM global manager initialization state follows RUM app id.
     */
    it('rumGlobalManagerInitializedState', 0, () => {
      FTRUMGlobalManager.resetStateInternal();
      expect(FTRUMGlobalManager.getInstance().isInitialized()).assertFalse();

      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL));
      FTSDK.installRUMConfig(new FTRUMConfig());
      expect(FTRUMGlobalManager.getInstance().isInitialized()).assertFalse();

      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      expect(FTRUMGlobalManager.getInstance().isInitialized()).assertTrue();

      FTSDK.installRUMConfig(new FTRUMConfig());
      expect(FTRUMGlobalManager.getInstance().isInitialized()).assertFalse();

      FTRUMGlobalManager.resetStateInternal();
      expect(FTRUMGlobalManager.getInstance().isInitialized()).assertFalse();

      console.info('ConfigTest', 'rumGlobalManagerInitializedState passed');
    });

    /**
     * Validate log cache entry count configuration
     * Adapted from Android: FTSdk.install() + FTSdk.initLogWithConfig()
     * Verifies FTDBCachePolicy.getLogLimitCount() (aligned with Android)
     */
    it('logCacheLimitShouldApply', 0, () => {
      // Install SDK (without context for unit test)
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(sdkConfig);

      // Test default (aligned with Android: FTSdk.initLogWithConfig(new FTLoggerConfig()))
      FTSDK.installLogConfig(new FTLoggerConfig());
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.DEFAULT_DB_LOG_CACHE_NUM);

      // Test minimum value (aligned with Android)
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(0));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);
      expect(new FTLoggerConfig().setLogCacheLimitCount(0).getLogCacheLimitCount())
        .assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);

      // Test custom count
      const customCount = 10000;
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(customCount));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(customCount);
      expect(new FTLoggerConfig().setLogCacheLimitCount(customCount).getLogCacheLimitCount())
        .assertEqual(customCount);
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheDiscardStrategy('discard_oldest'));
      expect(FTDBCachePolicy.getInstance().getDiscardStrategy(DataType.LOG))
        .assertEqual(LogCacheDiscard.DISCARD_OLDEST);

      console.info('ConfigTest', 'logCacheLimit passed');
    });

    /**
     * Validate RUM cache entry count configuration.
     */
    it('rumCacheLimitShouldApply', 0, () => {
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL));

      FTSDK.installRUMConfig(new FTRUMConfig());
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(Constants.DEFAULT_DB_RUM_CACHE_NUM);

      FTSDK.installRUMConfig(new FTRUMConfig().setRumCacheLimitCount(0));
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);
      expect(new FTRUMConfig().setRumCacheLimitCount(0).getRumCacheLimitCount())
        .assertEqual(Constants.MINI_DB_RUM_CACHE_NUM);

      const customCount = 10000;
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumCacheLimitCount(customCount)
        .setRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST));
      expect(FTDBCachePolicy.getInstance().getRumLimitCount()).assertEqual(customCount);
      expect(new FTRUMConfig().setRumCacheLimitCount(customCount).getRumCacheLimitCount())
        .assertEqual(customCount);
      expect(FTDBCachePolicy.getInstance().getDiscardStrategy(DataType.RUM_APP))
        .assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
      expect(new FTRUMConfig().setRumCacheDiscardStrategy('discard_oldest').getRumCacheDiscardStrategy())
        .assertEqual(RUMCacheDiscard.DISCARD_OLDEST);

      console.info('ConfigTest', 'rumCacheLimit passed');
    });

    /**
     * Validate log level filter string configuration
     */
    it('logLevelFiltersShouldApply', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setLogLevelFilters(['ERROR', 'WARNING', 'INFO', 'DEBUG']);

      expect(loggerConfig.getLogLevelFilters().length).assertEqual(4);
      expect(loggerConfig.getLogLevelFilters()[0]).assertEqual('error');
      expect(loggerConfig.getLogLevelFilters()[1]).assertEqual('warn');
      expect(loggerConfig.getLogLevelFilters()[2]).assertEqual('info');
      expect(loggerConfig.getLogLevelFilters()[3]).assertEqual('debug');
      expect(loggerConfig.checkLogLevel('error')).assertTrue();
      expect(loggerConfig.checkLogLevel('warn')).assertTrue();
      expect(loggerConfig.checkLogLevel('info')).assertTrue();
      expect(loggerConfig.checkLogLevel('debug')).assertTrue();
      expect(loggerConfig.checkLogLevel('trace')).assertFalse();

      console.info('ConfigTest', 'logLevelFilters passed');
    });

    /**
     * Validate log level filter object configuration
     */
    it('logLevelObjectFiltersShouldApply', 0, () => {
      const loggerConfig = new FTLoggerConfig()
        .setLogLevelFilters([
          { name: 'error' },
          { name: 'warn' },
          { name: 'custom_level' }
        ]);

      expect(loggerConfig.getLogLevelFilters().length).assertEqual(3);
      expect(loggerConfig.getLogLevelFilters()[0]).assertEqual('error');
      expect(loggerConfig.getLogLevelFilters()[1]).assertEqual('warn');
      expect(loggerConfig.getLogLevelFilters()[2]).assertEqual('custom_level');
      expect(loggerConfig.checkLogLevel('error')).assertTrue();
      expect(loggerConfig.checkLogLevel('warn')).assertTrue();
      expect(loggerConfig.checkLogLevel('custom_level')).assertTrue();
      expect(loggerConfig.checkLogLevel('info')).assertFalse();

      console.info('ConfigTest', 'logLevelObjectFilters passed');
    });

    /**
     * Validate Trace sampling rate configuration.
     */
    it('traceSamplingRateShouldApply', 0, () => {
      const defaultTraceConfig = new FTTraceConfig();
      const customTraceConfig = new FTTraceConfig()
        .setSamplingRate(0.25);

      expect(defaultTraceConfig.getSamplingRate()).assertEqual(1.0);
      expect(customTraceConfig.getSamplingRate()).assertEqual(0.25);
      expect(new FTTraceConfig().setSamplingRate(-1).getSamplingRate()).assertEqual(0);
      expect(new FTTraceConfig().setSamplingRate(2).getSamplingRate()).assertEqual(1);

      FTTraceConfigManager.getInstance().initWithConfig(customTraceConfig);
      expect(FTTraceConfigManager.getInstance().getSamplingRate()).assertEqual(0.25);

      console.info('ConfigTest', 'traceSamplingRate passed');
    });

    /**
     * Validate Trace service name configuration.
     */
    it('traceServiceNameShouldApply', 0, () => {
      const serviceName = 'trace-test-service';
      const defaultTraceConfig = new FTTraceConfig();
      const customTraceConfig = new FTTraceConfig()
        .setServiceName(serviceName);

      expect(defaultTraceConfig.getServiceName()).assertEqual(Constants.DEFAULT_SERVICE_NAME);
      expect(customTraceConfig.getServiceName()).assertEqual(serviceName);

      FTTraceConfigManager.getInstance().initWithConfig(customTraceConfig);
      expect(FTTraceConfigManager.getInstance().getServiceName()).assertEqual(serviceName);

      console.info('ConfigTest', 'traceServiceName passed');
    });

    /**
     * Validate SDK cache policy and integer-compatible line protocol configuration.
     */
    it('sdkCachePolicyShouldApply', 0, () => {
      const dbLimit = 67108864;
      const logLimit = 2345;
      const sdkConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(dbLimit)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .enableDataIntegerCompatible();
      const cachePolicy = FTDBCachePolicy.getInstance();

      cachePolicy.initSDKParams(new TestConfigRecord(sdkConfig));

      expect(sdkConfig.getDbCacheLimit()).assertEqual(dbLimit);
      expect(sdkConfig.getDBCacheDiscard()).assertEqual('discard_oldest');
      expect(sdkConfig.getLogCacheDiscard()).assertEqual('discard_oldest');
      expect(sdkConfig.isDataIntegerCompatible()).assertTrue();
      expect(cachePolicy.isEnableLimitWithDbSize()).assertTrue();
      expect(cachePolicy.getDbLimitSize()).assertEqual(dbLimit);
      cachePolicy.updateLogCacheLimitCount(logLimit);
      cachePolicy.updateRumCacheLimitCount(34567);
      expect(cachePolicy.getLogLimitCount()).assertEqual(Constants.DEFAULT_DB_LOG_CACHE_NUM);
      expect(cachePolicy.getRumLimitCount()).assertEqual(Constants.DEFAULT_DB_RUM_CACHE_NUM);
      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD);

      const helper = new SyncDataHelper();
      const fields: Map<string, string> = new Map();
      fields.set('integer_value', '12');
      fields.set('float_value', '3.14');
      helper.initBaseConfig(sdkConfig);
      const lineProtocol =
        helper.getBodyContent('df_rum_harmonyos_log', new Map(), fields, 123456789, DataType.LOG, 'uuid-integer');

      expect(lineProtocol.includes('integer_value=12i')).assertFalse();
      expect(lineProtocol.includes('integer_value=12')).assertTrue();
      expect(lineProtocol.includes('float_value=3.14')).assertTrue();

      console.info('ConfigTest', 'sdkCachePolicyAndIntegerCompatible passed');
    });

    /**
     * Validate FTSDKConfig pageSize configuration
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().getPageSize()
     */
    it('syncPageSizeShouldUseDefault', 0, () => {
      const syncTaskManager = SyncTaskManager.getInstance();

      // Default should be MEDIUM (aligned with Android: SyncPageSize.MEDIUM)
      const config1: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(config1);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncPageSize.MEDIUM);

      // MINI
      const config2: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(SyncPageSize.MINI);
      FTSDK.install(config2);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncPageSize.MINI);

      // LARGE
      const config3: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(SyncPageSize.LARGE);
      FTSDK.install(config3);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncPageSize.LARGE);

      console.info('ConfigTest', 'syncDataPageSize passed');
    });

    /**
     * Validate custom FTSDKConfig pageSize configuration
     * Also validates minimum value
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().getPageSize()
     */
    it('syncPageSizeShouldUseCustom', 0, () => {
      const syncTaskManager = SyncTaskManager.getInstance();

      // Custom page size
      const customPageSize = 100;
      const config1: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setCustomSyncPageSize(customPageSize);
      FTSDK.install(config1);
      expect(syncTaskManager.getPageSize()).assertEqual(customPageSize);

      // Minimum value should be SyncPageSize.MINI
      const config2: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setCustomSyncPageSize(1);
      FTSDK.install(config2);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncPageSize.MINI);

      const config3: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setCustomSyncPageSize(SyncTaskManager.MAX_PAGE_SIZE + 1000);
      FTSDK.install(config3);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncTaskManager.MAX_PAGE_SIZE);

      console.info('ConfigTest', 'customSyncDataPageSize passed');
    });

    /**
     * Validate syncSleepTime configuration
     * Tests maximum, minimum, and custom values
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().getSyncSleepTime()
     */
    it('syncSleepTimeShouldApply', 0, () => {
      const syncTaskManager = SyncTaskManager.getInstance();

      // Maximum value should be capped
      const config1: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncSleepTime(10000);
      FTSDK.install(config1);
      expect(syncTaskManager.getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MAX_TIME_MS);

      // Custom value within range
      const config2: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncSleepTime(50);
      FTSDK.install(config2);
      expect(syncTaskManager.getSyncSleepTime()).assertEqual(50);

      // Minimum value should be SYNC_SLEEP_MINI_TIME_MS
      const config3: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncSleepTime(-1);
      FTSDK.install(config3);
      expect(syncTaskManager.getSyncSleepTime()).assertEqual(SyncTaskManager.SYNC_SLEEP_MINI_TIME_MS);

      console.info('ConfigTest', 'syncSleepTime passed');
    });

    /**
     * Validate autoSync configuration
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().isAutoSyncEnabled()
     */
    it('autoSyncShouldApply', 0, () => {
      const syncTaskManager = SyncTaskManager.getInstance();

      // Default should be true
      const config1: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(config1);
      expect(syncTaskManager.isAutoSyncEnabled()).assertTrue();

      // Set to false
      const config2: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setAutoSync(false);
      FTSDK.install(config2);
      expect(syncTaskManager.isAutoSyncEnabled()).assertFalse();

      console.info('ConfigTest', 'autoSync passed');
    });

    /**
     * Validate Datakit configuration
     */
    it('datakitUrlShouldApply', 0, () => {
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      expect(config.getDatakitUrl()).assertEqual(TEST_FAKE_URL);

      console.info('ConfigTest', 'datakitUrl passed');
    });

    /**
     * Validate dataway configuration
     */
    it('datawayConfigShouldApply', 0, () => {
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL, TEST_FAKE_CLIENT_TOKEN);
      expect(config.getDatawayUrl()).assertEqual(TEST_FAKE_URL);
      expect(config.getClientToken()).assertEqual(TEST_FAKE_CLIENT_TOKEN);

      console.info('ConfigTest', 'datawayConfig passed');
    });

    /**
     * Validate UIBlock parameter default value and custom values
     */
    it('rumUiBlockParamsShouldApply', 0, () => {
      // Default value (1000ms when enabled without duration)
      const config1: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true);
      expect(config1.getBlockDurationMS()).assertEqual(1000);

      // Set custom duration greater than 100ms
      const customDuration = 1000;
      const config2: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, customDuration);
      expect(config2.getBlockDurationMS()).assertEqual(customDuration);

      // Validate minimum setting (90ms should become 100ms)
      const minDuration = 90;
      const config3: FTRUMConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, minDuration);
      expect(config3.getBlockDurationMS()).assertEqual(100);

      console.info('ConfigTest', 'rumUIBlockParamsTest passed');
    });

  });
}
