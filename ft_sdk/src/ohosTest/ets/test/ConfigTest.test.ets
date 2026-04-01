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
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { EnvType, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';

// Test constants (aligned with Android FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const TEST_FAKE_CLIENT_TOKEN = 'fake_client_token';

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
    it('emptyServiceName', 0, () => {
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
    it('normalServiceName', 0, () => {
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
    it('emptyEnv', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      // Default env is PROD when not set
      expect(sdkConfig.getEnv()).assertEqual(EnvType.PROD.toString());

      console.info('ConfigTest', 'emptyEnv passed');
    });

    /**
     * Validate env parameter
     */
    it('enumEnv', 0, () => {
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setEnv(EnvType.GRAY);
      expect(sdkConfig.getEnv()).assertEqual(EnvType.GRAY.toString());

      console.info('ConfigTest', 'enumEnv passed');
    });

    /**
     * Validate env parameter
     */
    it('customEnv', 0, () => {
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
    it('rumAppId', 0, () => {
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
     * Validate log cache entry count configuration
     * Adapted from Android: FTSdk.install() + FTSdk.initLogWithConfig()
     * Verifies FTDBCachePolicy.getLogLimitCount() (aligned with Android)
     */
    it('logCacheLimit', 0, () => {
      // Install SDK (without context for unit test)
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      FTSDK.install(sdkConfig);

      // Test default (aligned with Android: FTSdk.initLogWithConfig(new FTLoggerConfig()))
      FTSDK.installLogConfig(new FTLoggerConfig());
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.DEFAULT_DB_LOG_CACHE_NUM);

      // Test minimum value (aligned with Android)
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(0));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(Constants.MINI_DB_LOG_CACHE_NUM);

      // Test custom count
      const customCount = 10000;
      FTSDK.installLogConfig(new FTLoggerConfig().setLogCacheLimitCount(customCount));
      expect(FTDBCachePolicy.getInstance().getLogLimitCount()).assertEqual(customCount);

      console.info('ConfigTest', 'logCacheLimit passed');
    });

    /**
     * Validate FTSDKConfig pageSize configuration
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().getPageSize()
     */
    it('syncDataPageSize', 0, () => {
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
    it('customSyncDataPageSize', 0, () => {
      const syncTaskManager = SyncTaskManager.getInstance();

      // Custom page size
      const customPageSize = 1000;
      const config1: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(customPageSize);
      FTSDK.install(config1);
      expect(syncTaskManager.getPageSize()).assertEqual(customPageSize);

      // Minimum value should be SyncPageSize.MINI
      const config2: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setSyncPageSize(1);
      FTSDK.install(config2);
      expect(syncTaskManager.getPageSize()).assertEqual(SyncPageSize.MINI);

      console.info('ConfigTest', 'customSyncDataPageSize passed');
    });

    /**
     * Validate syncSleepTime configuration
     * Tests maximum, minimum, and custom values
     * Adapted from Android: FTSdk.install() + check SyncTaskManager.get().getSyncSleepTime()
     */
    it('syncSleepTime', 0, () => {
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
    it('autoSync', 0, () => {
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
    it('datakitUrl', 0, () => {
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);
      expect(config.getDatakitUrl()).assertEqual(TEST_FAKE_URL);

      console.info('ConfigTest', 'datakitUrl passed');
    });

    /**
     * Validate dataway configuration
     */
    it('datawayConfig', 0, () => {
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL, TEST_FAKE_CLIENT_TOKEN);
      expect(config.getDatawayUrl()).assertEqual(TEST_FAKE_URL);
      expect(config.getClientToken()).assertEqual(TEST_FAKE_CLIENT_TOKEN);

      console.info('ConfigTest', 'datawayConfig passed');
    });

    /**
     * Validate UIBlock parameter default value and custom values
     */
    it('rumUIBlockParamsTest', 0, () => {
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

    /**
     * Validate SyncTaskManager getter methods
     * Tests the newly added getPageSize(), getSyncSleepTime(), isAutoSyncEnabled() methods
     * Note: SyncTaskManager is a singleton, so previous tests may have modified its state.
     * We verify that the methods work correctly rather than checking specific default values.
     */
    it('syncTaskManagerGetters', 0, () => { 
      const syncTaskManager = SyncTaskManager.getInstance();

      // Test that getter methods exist and return valid values
      expect(syncTaskManager.getPageSize()).assertLarger(0); // Should be positive
      expect(syncTaskManager.getSyncSleepTime()).assertLarger(-1); // Should be >= 0
      expect(typeof syncTaskManager.isAutoSyncEnabled()).assertEqual('boolean');

      // Verify that values are valid types
      expect(typeof syncTaskManager.getPageSize()).assertEqual('number');
      expect(typeof syncTaskManager.getSyncSleepTime()).assertEqual('number');

      console.info('ConfigTest', 'syncTaskManagerGetters passed');
    });

    /**
     * Validate FTDBCachePolicy getter methods
     * Tests the getLogLimitCount() method
     * Note: In unit test without context, logLimitCount is 0 (not initialized)
     */
    it('ftdbCachePolicyGetters', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Test that getter method exists and is callable
      // Initial value is 0 (not initialized without context)
      expect(cachePolicy.getLogLimitCount()).assertEqual(0);

      // Test setTestLimits method
      const testLogLimit = 1000;
      const testRumLimit = 2000;
      cachePolicy.setTestLimits(testLogLimit, testRumLimit);
      expect(cachePolicy.getLogLimitCount()).assertEqual(testLogLimit);
      expect(cachePolicy.getRumLimitCount()).assertEqual(testRumLimit);

      console.info('ConfigTest', 'ftdbCachePolicyGetters passed');
    });
  });
}
