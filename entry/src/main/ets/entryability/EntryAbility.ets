import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import preferences from '@ohos.data.preferences';
import window from '@ohos.window';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import {
  DBCacheDiscard,
  DeviceMetricsMonitorType,
  EnvType,
  ErrorMonitorType,
  FTLoggerConfig,
  FTRUMConfig,
  FTSDK,
  FTSDKConfig,
  FTTraceConfig,
  LogCacheDiscard,
  Status,
  SyncPageSize,
  TraceType,
  UserData
} from '@guancecloud/ft_sdk/Index';
import { DemoLogger } from '../utils/DemoLogger';
import { DemoDataModifier, DemoLineDataModifier } from '../utils/DataModifierDemo';
import {
  runPreInitAxiosSmokeTestsWithMode,
  PreInitAxiosSmokeExecutionMode,
  PreInitAxiosSmokeUrls,
  preInitControlChainClientInfo,
  preInitChainClientInfo,
  preInitCompatClientInfo
} from '../utils/PreInitAxiosClients';

const LOG_TAG = "EntryAbility";
const PREFERENCES_NAME = "entry_ability_runtime_config";
const PRE_INIT_SMOKE_EXECUTION_MODE: PreInitAxiosSmokeExecutionMode = 'sequential';
// Local-only defaults for manually validating SDK upload proxy and custom DNS.
// They can be overridden through launch parameters. Keep the test disabled by
// default so a normal Demo launch always uses its configured DataKit/DataWay URL.
const DEFAULT_NETWORK_ROUTE_TEST_ENABLED = false;
const DEFAULT_NETWORK_ROUTE_TEST_MODE: 'proxy' | 'dns' = 'proxy';
const NETWORK_ROUTE_TEST_HOST = '10.100.64.213';
const NETWORK_ROUTE_TEST_UPLOAD_PORT = 9529;
const NETWORK_ROUTE_TEST_PROXY_PORT = 8080;
const NETWORK_ROUTE_TEST_DNS_HOSTNAME = 'ft-upload.sdk-test.invalid';

export const KEY_WEB_VIEW_URL = "webViewUrl";
export const KEY_TRACE_URL = "traceUrl";

export const KEY_DATAKIT_URL = "datakitUrl";
export const KEY_DATAWAY_URL = "datawayUrl";
export const KEY_CLIENT_TOKEN = "clientToken";
export const KEY_AUTO_SYNC = "autoSync";
export const KEY_NETWORK_ROUTE_TEST_ENABLED = "networkRouteTestEnabled";
export const KEY_NETWORK_ROUTE_TEST_MODE = "networkRouteTestMode";

export const KEY_APP_ID = "appId";

interface RuntimeConfig {
  datakitUrl: string;
  datawayUrl: string;
  webViewUrl: string;
  traceUrl: string;
  clientToken: string;
  autoSync: string;
  networkRouteTestEnabled: string;
  networkRouteTestMode: string;
  appId: string;
}

/**
 * Launch parameter examples:
 *
 * 1. Set local Datakit:
 * --ps datakitUrl http\://10.0.0.1\:9529
 *
 * 2. Set public DataWay:
 * --ps datawayUrl https\://rum-openway.guance.com --ps clientToken your_client_token
 *
 * 3. Set in-app WebView target:
 * --ps webViewUrl http\://10.0.0.1\:8000
 *
 * 4. Set RUM appId:
 * --ps appId your_app_id
 *
 * 5. Set trace test request URL:
 * --ps traceUrl http\://10.0.0.1\:8000/api/user
 *
 * 6. Enable the local proxy route test:
 * --ps networkRouteTestEnabled true --ps networkRouteTestMode proxy
 *
 * 7. Enable the local custom DNS route test:
 * --ps networkRouteTestEnabled true --ps networkRouteTestMode dns
 *
 * 8. Full example:
 * --ps datakitUrl http\://10.0.0.1\:9529 --ps datawayUrl https\://rum-openway.guance.com --ps clientToken your_client_token --ps webViewUrl http\://10.0.0.1\:8000 --ps traceUrl http\://10.0.0.1\:8000/api/user --ps appId your_app_id
 *
 * Behavior:
 * - Parameters passed in onCreate are persisted to preferences.
 * - If a parameter is empty or omitted, the persisted value is used instead.
 * - SDK upload uses DataKit when datakitUrl is configured; DataWay is used only as fallback.
 * - SDK, WebView, and trace test pages all read from the same persisted runtime config.
 */
export default class EntryAbility extends UIAbility {
  private runtimeConfig: RuntimeConfig = {
    datakitUrl: "",
    datawayUrl: "",
    webViewUrl: "",
    traceUrl: "",
    clientToken: "",
    autoSync: "",
    networkRouteTestEnabled: "",
    networkRouteTestMode: "",
    appId: ""
  };

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    DemoLogger.e("log test", `onCreate `);
    console.log("log test,onCreate")
    this.logAppMemoryLimitOnMainThread();

    try {
      this.runtimeConfig = await this.loadRuntimeConfig(want);
    } catch (error) {
      DemoLogger.e(LOG_TAG, `Failed to load runtime config: ${error}`);
    }
    this.verifyPreInitAxiosClients();
    this.initFTSDK();
  }

  private logAppMemoryLimitOnMainThread(): void {
    try {
      const limit = hidebug.getAppMemoryLimit();
      console.info(`JS-vmHeapLimit=${limit.vmHeapLimit} KB`);
      console.info(`JS-vmTotalHeapSize=${limit.vmTotalHeapSize} KB`);
    } catch (error) {
      DemoLogger.e(LOG_TAG, `Failed to get app memory limit on main thread: ${error}`);
    }

    try {
      const vmMemory = hidebug.getAppVMMemoryInfo();
      console.info(`JS-heapUsed=${vmMemory.heapUsed} KB`);
      console.info(`JS-totalHeap=${vmMemory.totalHeap} KB`);
    } catch (error) {
      DemoLogger.e(LOG_TAG, `Failed to get app VM memory info on main thread: ${error}`);
    }
  }

  onDestroy(): void {
    // Lifecycle monitoring is now handled automatically by SDK via applicationContext
    // No manual stopView() call needed - SDK's FTAbilityLifecycleListener handles this
  }

  private async loadRuntimeConfig(want: Want): Promise<RuntimeConfig> {
    const autoSyncParam = want.parameters?.[KEY_AUTO_SYNC];
    const networkRouteTestEnabledParam = want.parameters?.[KEY_NETWORK_ROUTE_TEST_ENABLED];
    const networkRouteTestModeParam = want.parameters?.[KEY_NETWORK_ROUTE_TEST_MODE];
    const runtimeConfig: RuntimeConfig = {
      datakitUrl: (want.parameters?.[KEY_DATAKIT_URL] as string | null | undefined) ?? "",
      datawayUrl: (want.parameters?.[KEY_DATAWAY_URL] as string | null | undefined) ?? "",
      webViewUrl: (want.parameters?.[KEY_WEB_VIEW_URL] as string | null | undefined) ?? "",
      traceUrl: (want.parameters?.[KEY_TRACE_URL] as string | null | undefined) ?? "",
      clientToken: (want.parameters?.[KEY_CLIENT_TOKEN] as string | null | undefined) ?? "",
      autoSync: autoSyncParam === undefined || autoSyncParam === null ? "" : String(autoSyncParam),
      networkRouteTestEnabled: networkRouteTestEnabledParam === undefined || networkRouteTestEnabledParam === null
        ? ""
        : String(networkRouteTestEnabledParam),
      networkRouteTestMode: networkRouteTestModeParam === undefined || networkRouteTestModeParam === null
        ? ""
        : String(networkRouteTestModeParam),
      appId: (want.parameters?.[KEY_APP_ID] as string | null | undefined) ?? ""
    };

    if (!this.hasMissingRuntimeConfig(runtimeConfig)) {
      this.updateRuntimeConfigStorage(runtimeConfig);
      this.persistRuntimeConfig(runtimeConfig).catch((error: Error) => {
        DemoLogger.w(LOG_TAG, `Failed to persist runtime config: ${JSON.stringify(error)}`);
      });

      DemoLogger.i(
        LOG_TAG,
        `Runtime config loaded from launch parameters datakitUrl=${runtimeConfig.datakitUrl}, datawayUrl=${runtimeConfig.datawayUrl}, webViewUrl=${runtimeConfig.webViewUrl}, traceUrl=${runtimeConfig.traceUrl}, appId=${runtimeConfig.appId}, networkRouteTestEnabled=${runtimeConfig.networkRouteTestEnabled}, networkRouteTestMode=${runtimeConfig.networkRouteTestMode}`);
      return runtimeConfig;
    }

    const preferencesStore = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    runtimeConfig.datakitUrl = await this.resolveRuntimeValue(preferencesStore, KEY_DATAKIT_URL, runtimeConfig.datakitUrl, "");
    runtimeConfig.datawayUrl = await this.resolveRuntimeValue(preferencesStore, KEY_DATAWAY_URL, runtimeConfig.datawayUrl, "");
    runtimeConfig.webViewUrl = await this.resolveRuntimeValue(preferencesStore, KEY_WEB_VIEW_URL, runtimeConfig.webViewUrl, "");
    runtimeConfig.traceUrl = await this.resolveRuntimeValue(preferencesStore, KEY_TRACE_URL, runtimeConfig.traceUrl, "");
    runtimeConfig.clientToken = await this.resolveRuntimeValue(preferencesStore, KEY_CLIENT_TOKEN, runtimeConfig.clientToken, "");
    runtimeConfig.networkRouteTestEnabled = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_NETWORK_ROUTE_TEST_ENABLED,
      runtimeConfig.networkRouteTestEnabled,
      ""
    );
    runtimeConfig.networkRouteTestMode = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_NETWORK_ROUTE_TEST_MODE,
      runtimeConfig.networkRouteTestMode,
      ""
    );
    runtimeConfig.appId = await this.resolveRuntimeValue(preferencesStore, KEY_APP_ID, runtimeConfig.appId, "");

    await this.persistResolvedRuntimeConfig(preferencesStore, runtimeConfig);
    this.updateRuntimeConfigStorage(runtimeConfig);

    DemoLogger.i(
      LOG_TAG,
      `Runtime config loaded datakitUrl=${runtimeConfig.datakitUrl}, datawayUrl=${runtimeConfig.datawayUrl}, webViewUrl=${runtimeConfig.webViewUrl}, traceUrl=${runtimeConfig.traceUrl}, appId=${runtimeConfig.appId}, networkRouteTestEnabled=${runtimeConfig.networkRouteTestEnabled}, networkRouteTestMode=${runtimeConfig.networkRouteTestMode}`);

    return runtimeConfig;
  }

  private async resolveRuntimeValue(
    preferencesStore: preferences.Preferences,
    key: string,
    incomingValue: string | null | undefined,
    defaultValue: string
  ): Promise<string> {
    if (incomingValue != null && incomingValue.length > 0) {
      return incomingValue;
    }
    const storedValue = await preferencesStore.get(key, defaultValue) as string;
    return storedValue ?? defaultValue;
  }

  private hasMissingRuntimeConfig(runtimeConfig: RuntimeConfig): boolean {
    return runtimeConfig.datakitUrl.length === 0 ||
      runtimeConfig.datawayUrl.length === 0 ||
      runtimeConfig.webViewUrl.length === 0 ||
      runtimeConfig.traceUrl.length === 0 ||
      runtimeConfig.clientToken.length === 0 ||
      runtimeConfig.appId.length === 0;
  }

  private updateRuntimeConfigStorage(runtimeConfig: RuntimeConfig): void {
    AppStorage.setOrCreate(KEY_DATAKIT_URL, runtimeConfig.datakitUrl);
    AppStorage.setOrCreate(KEY_DATAWAY_URL, runtimeConfig.datawayUrl);
    AppStorage.setOrCreate(KEY_WEB_VIEW_URL, runtimeConfig.webViewUrl);
    AppStorage.setOrCreate(KEY_TRACE_URL, runtimeConfig.traceUrl);
    AppStorage.setOrCreate(KEY_CLIENT_TOKEN, runtimeConfig.clientToken);
    AppStorage.setOrCreate(KEY_NETWORK_ROUTE_TEST_ENABLED, runtimeConfig.networkRouteTestEnabled);
    AppStorage.setOrCreate(KEY_NETWORK_ROUTE_TEST_MODE, runtimeConfig.networkRouteTestMode);
    AppStorage.setOrCreate(KEY_APP_ID, runtimeConfig.appId);
  }

  private async persistRuntimeConfig(runtimeConfig: RuntimeConfig): Promise<void> {
    const preferencesStore = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    await this.persistResolvedRuntimeConfig(preferencesStore, runtimeConfig);
  }

  private async persistResolvedRuntimeConfig(
    preferencesStore: preferences.Preferences,
    runtimeConfig: RuntimeConfig
  ): Promise<void> {
    await preferencesStore.put(KEY_DATAKIT_URL, runtimeConfig.datakitUrl);
    await preferencesStore.put(KEY_DATAWAY_URL, runtimeConfig.datawayUrl);
    await preferencesStore.put(KEY_WEB_VIEW_URL, runtimeConfig.webViewUrl);
    await preferencesStore.put(KEY_TRACE_URL, runtimeConfig.traceUrl);
    await preferencesStore.put(KEY_CLIENT_TOKEN, runtimeConfig.clientToken);
    await preferencesStore.put(KEY_NETWORK_ROUTE_TEST_ENABLED, runtimeConfig.networkRouteTestEnabled);
    await preferencesStore.put(KEY_NETWORK_ROUTE_TEST_MODE, runtimeConfig.networkRouteTestMode);
    await preferencesStore.put(KEY_APP_ID, runtimeConfig.appId);
    await preferencesStore.flush();
  }

  private resolveAutoSyncEnabled(): boolean {
    const value = this.runtimeConfig.autoSync.trim().toLowerCase();
    return value !== 'false' && value !== '0' && value !== 'off';
  }

  private isNetworkRouteTestEnabled(): boolean {
    const value = this.runtimeConfig.networkRouteTestEnabled.trim().toLowerCase();
    if (value.length === 0) {
      return DEFAULT_NETWORK_ROUTE_TEST_ENABLED;
    }
    return value === 'true' || value === '1' || value === 'on';
  }

  private resolveNetworkRouteTestMode(): 'proxy' | 'dns' {
    const value = this.runtimeConfig.networkRouteTestMode.trim().toLowerCase();
    return value === 'dns' || value === 'proxy' ? value : DEFAULT_NETWORK_ROUTE_TEST_MODE;
  }

  /**
   * Verify the axios/http clients that were created at module-load time before FTSDK.initFTSDK().
   * This smoke test is intentionally executed before SDK install so we can compare:
   * 1. compat axios interceptor mode
   * 2. axios + NetworkKit interceptorChain mode
   * 3. the plain control chain created without FT interceptors
   *
   * The requests use distinct query markers so the resulting resource/trace logs can be
   * mapped back to the exact pre-init path that produced them.
   */
  private async verifyPreInitAxiosClients(): Promise<void> {
    const compatSmokeTestUrl = this.resolvePreInitCompatSmokeTestUrl();
    const chainSmokeTestUrl = this.resolvePreInitChainSmokeTestUrl();
    DemoLogger.i(
      LOG_TAG,
      `Pre-init axios clients already created before SDK init: compatAt=${preInitCompatClientInfo.createdAt}, chainAt=${preInitChainClientInfo.createdAt}`
    );
    DemoLogger.i(
      LOG_TAG,
      `Running pre-init axios smoke tests before FTSDK.install: executionMode=${PRE_INIT_SMOKE_EXECUTION_MODE}, compatUrl=${compatSmokeTestUrl}, chainUrl=${chainSmokeTestUrl}, compatAt=${preInitCompatClientInfo.createdAt}, chainAt=${preInitChainClientInfo.createdAt}, chainControlAt=${preInitControlChainClientInfo.createdAt}`
    );

    try {
      const smokeUrls: PreInitAxiosSmokeUrls = {
        compatUrl: compatSmokeTestUrl,
        chainUrl: chainSmokeTestUrl
      };
      // Keep execution order stable so startup logs are easier to compare across modes.
      const results = await runPreInitAxiosSmokeTestsWithMode(smokeUrls, "parallel");
      const summary = results.map((result) =>
        result.success
          ? `${result.mode}=ok(status=${result.statusCode},body=${result.bodyLength})`
          : `${result.mode}=fail(error=${result.errorMessage})`
      ).join(', ');
      DemoLogger.i(LOG_TAG, `Pre-init axios smoke test finished before SDK init: ${summary}`);
    } catch (error) {
      DemoLogger.e(LOG_TAG, `Pre-init axios smoke test crashed unexpectedly before SDK init: ${error}`);
    }
  }

  private resolvePreInitCompatSmokeTestUrl(): string {
    return this.buildPreInitSmokeTestUrl('compat');
  }

  private resolvePreInitChainSmokeTestUrl(): string {
    return this.buildPreInitSmokeTestUrl('chain');
  }

  private buildPreInitSmokeTestUrl(mode: 'compat' | 'chain'): string {
    const traceUrl = this.runtimeConfig.traceUrl.trim();
    if (traceUrl.length > 0) {
      const smokeSource = mode === 'compat' ? 'entry-preinit-compat' : 'entry-preinit-chain';
      return `${traceUrl}${traceUrl.includes('?') ? '&' : '?'}from=${smokeSource}`;
    }

    if (mode === 'compat') {
      return 'https://httpbin.org/get?from=entry-preinit-compat';
    }
    return 'https://httpbin.org/get?from=entry-preinit-chain';
  }

  private initFTSDK():void{
    try {
      // Get the Context - use this.context instead of getContext(this)
      const context = this.context;
      const datakitUrl = this.runtimeConfig.datakitUrl.trim();
      const datawayUrl = this.runtimeConfig.datawayUrl.trim();
      const clientToken = this.runtimeConfig.clientToken.trim();
      const appId = this.runtimeConfig.appId.trim();
      const networkRouteTestEnabled = this.isNetworkRouteTestEnabled();
      const networkRouteTestMode = this.resolveNetworkRouteTestMode();

      // Create SDK configuration
      let sdkConfig: FTSDKConfig;
      if (networkRouteTestEnabled) {
        const uploadUrl = networkRouteTestMode === 'dns'
          ? `http://${NETWORK_ROUTE_TEST_DNS_HOSTNAME}:${NETWORK_ROUTE_TEST_UPLOAD_PORT}`
          : `http://${NETWORK_ROUTE_TEST_HOST}:${NETWORK_ROUTE_TEST_UPLOAD_PORT}`;
        sdkConfig = FTSDKConfig.builder(uploadUrl);
        DemoLogger.i(LOG_TAG, `Network route test enabled: mode=${networkRouteTestMode}, uploadUrl=${uploadUrl}`);
      } else if (datawayUrl.length > 0) {
        if (clientToken.length === 0) {
          DemoLogger.w(LOG_TAG, "SDK initialization skipped: clientToken is required when datawayUrl is set");
          return;
        }
        sdkConfig = FTSDKConfig.builder(datawayUrl, clientToken);
      } else if (datakitUrl.length > 0) {
        sdkConfig = FTSDKConfig.builder(datakitUrl);
      } else {
        DemoLogger.w(LOG_TAG, "SDK initialization skipped: datakitUrl and datawayUrl are both empty");
        return;
      }

      sdkConfig = sdkConfig
        .setDebug(true)
        .setEnableInnerLogFile(true, {
          singleFileMaxSize: 5 * 1024 * 1024,
          totalFileMaxSize: 100 * 1024 * 1024,
          flushBatchSize: 20,
          flushIntervalMs: 200
        })
        .setEnv(EnvType.GRAY)
        .setServiceName('HarmonyOS-Test-App')
        // Upload defaults are explicit in the demo so the active SDK behavior
        // can be read directly here. `autoSync` remains launch-configurable.
        .setAutoSync(networkRouteTestEnabled ? false : this.resolveAutoSyncEnabled())
        // .setSyncPageSize(SyncPageSize.MEDIUM) // Default: 10 records per upload request
        .setCustomSyncPageSize(20)
        .setDataSyncRetryCount(2) // Default: retry failed uploads up to 5 times
        .setSyncSleepTime(100) // Default: no extra delay between upload requests
        .setCompressIntakeRequests(false) // Disable only so manual tests can read the marker
        // The callbacks target only demo_sensitive_* fields. See the Data
        // Modifier Test page for a reproducible masking verification flow.
        .setDataModifier(new DemoDataModifier())
        .setLineDataModifier(new DemoLineDataModifier())
      if (networkRouteTestEnabled && networkRouteTestMode === 'proxy') {
        sdkConfig = sdkConfig.setProxy({
          host: NETWORK_ROUTE_TEST_HOST,
          port: NETWORK_ROUTE_TEST_PROXY_PORT
        });
      } else if (networkRouteTestEnabled && networkRouteTestMode === 'dns') {
        sdkConfig = sdkConfig.setDns({
          servers: [NETWORK_ROUTE_TEST_HOST]
        });
      }
      // Initialize SDK
      FTSDK.install(sdkConfig, context);
      DemoLogger.i(LOG_TAG, "SDK install completed");

      // Initialize log configuration
      const logConfig = new FTLoggerConfig()
        .setSamplingRate(1.0)  // 100% sampling rate
        .setEnableCustomLog(true)
        .setEnableConsoleLog(true)
        // .setLogCacheLimitCount(20000)
        .setPrintCustomLogToConsole(true)
        .setLogLevelFilters([Status.ERROR, Status.DEBUG, Status.INFO])
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST)
        .setEnableLinkRumData(true);
      FTSDK.installLogConfig(logConfig);

      // Test log sampling rate
      DemoLogger.i(LOG_TAG, "Testing log sampling rate 1.0 (100%)");

      // Initialize RUM configuration
      if (appId.length === 0) {
        DemoLogger.w(LOG_TAG, "SDK initialization skipped: appId is empty");
        return;
      }
      const rumConfig = new FTRUMConfig()
        .setRumAppId(appId)
        .setEnableTrackAppCrash(true)  // JS and native crash monitoring
        .setSamplingRate(1.0)          // Set the sampling rate to 100%
        .setSessionErrorSampleRate(1.0) // Set the error sampling rate to 100%
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTrackAppANR(true)
        .setEnableTrackAppUIBlock(false)
        .setEnableTraceUserView(true)
        .addGlobalContext("custom_key",new String("custom_value"))
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.ALL)
        // .setRumCacheLimitCount(60000)

      FTSDK.installRUMConfig(rumConfig);

      // Bind user data using new UserData class with persistence
      const userData = new UserData();
      userData.setId("harmonyos.guance.userid");
      userData.setName("harmonyos_user_guance_test");
      userData.setEmail("harmonyos@guance.com");
      userData.addExt("ft_key", "ft_value");

      FTSDK.bindRumUserData(userData);
      DemoLogger.i(LOG_TAG, "User data bound successfully with persistence");

      // Initialize trace configuration
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.DDTRACE);
      FTSDK.installTraceConfig(traceConfig);

      DemoLogger.i(LOG_TAG, "SDK initialized successfully - BEFORE loadContent");

    } catch (error) {
      DemoLogger.e(LOG_TAG, `SDK initialization failed: ${error}`);
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {

    windowStage.loadContent('pages/Index', (err) => {
      DemoLogger.i(LOG_TAG, "loadContent callback called");
      if (err.code) {
        DemoLogger.e(LOG_TAG, `loadContent failed: ${err.code}`);
        return;
      }
      DemoLogger.i(LOG_TAG, "Content loaded successfully");
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
    // App enters foreground
    // Similar to Android's onActivityResumed(), but HarmonyOS doesn't auto-start view here
    // View will be started by FTNavigationTracker when page loads
  }

  onBackground(): void {
    // Lifecycle monitoring is now handled automatically by SDK via applicationContext
    // No manual stopView() call needed - SDK's FTAbilityLifecycleListener handles this
  }
}
