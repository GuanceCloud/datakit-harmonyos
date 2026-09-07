import { ENTRY_RUNTIME_KEYS, resolveEntryRuntimeConfig } from '../utils/EntryRuntimeConfig';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import preferences from '@ohos.data.preferences';
import window from '@ohos.window';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import {
  DetectFrequency,
  DeviceMetricsMonitorType,
  EnvType,
  ErrorMonitorType,
  ActionEventWrapper,
  FTActionTrackingHandler,
  FTLoggerConfig,
  FTRemoteConfigFetchResult,
  FTRUMConfig,
  FTSDK,
  FTSDKConfig,
  FTTraceConfig,
  FTViewNavigationTrackingHandler,
  FTViewRouterTrackingHandler,
  HandlerView,
  LogCacheDiscard,
  Status,
  SyncPageSize,
  TraceType,
  UserData,
  RemoteConfigBean
} from '@guancecloud/ft_sdk/Index';
import { FTColdLaunchBridge } from '@guancecloud/ft_sdk/Index';
import { DemoLogger } from '../utils/DemoLogger';
import { DemoDataModifier, DemoLineDataModifier } from '../utils/DataModifierDemo';

const LOG_TAG = "EntryAbility";
const PREFERENCES_NAME = "entry_ability_runtime_config";
export const RUNTIME_CONFIG_PREFERENCES_NAME = PREFERENCES_NAME;
// Endpoints used by the optional upload proxy / custom DNS demo.
const NETWORK_ROUTE_TEST_UPLOAD_PORT = 9529;
const NETWORK_ROUTE_TEST_PROXY_PORT = 8080;
const NETWORK_ROUTE_TEST_DNS_HOSTNAME = 'ft-upload.sdk-test.invalid';
// Routes and Navigation destinations whose final name starts with this prefix
// are deliberately excluded from automatic RUM View collection. Keep the
// prefix-based rule in the demo so page filtering can be verified without
// changing collection for its existing test pages.
const IGNORED_AUTOMATIC_VIEW_PREFIX = 'IgnoreViewTracking';
// User-configurable automatic Action filters. Names are matched by prefix;
// component IDs are matched exactly. Add application-specific IDs here when
// their automatic Actions should not be reported.
const FILTERED_AUTOMATIC_ACTION_NAME_PREFIXES: Array<string> = [
  '__Common__/'
];
const FILTERED_AUTOMATIC_ACTION_IDS: Array<string> = [];

export const KEY_WEB_VIEW_URL = "webViewUrl";
export const KEY_TRACE_URL = "traceUrl";

export const KEY_DATAKIT_URL = "datakitUrl";
export const KEY_DATAWAY_URL = "datawayUrl";
export const KEY_CLIENT_TOKEN = "clientToken";
/** GET endpoint shared by the HTTP demo page and test launch configuration. */
export const KEY_RESOURCE_TEST_URL = "resourceTestUrl";
export const KEY_LOCAL_DATA_FILTER_ENABLED = "localDataFilterEnabled";
export const KEY_LOCAL_DATA_FILTER_LOG_RULE = "localDataFilterLogRule";
export const KEY_LOCAL_DATA_FILTER_RUM_RULE = "localDataFilterRumRule";

export const KEY_APP_ID = "appId";
/** Demo-only launch parameter; delays first content loading to exercise first-frame timing. */
export const KEY_COLD_START_DELAY_MS = "coldStartDelayMs";
/** Demo-only parameter for switching between the two test UIAbilities after the source first frame. */
export const KEY_COLD_LAUNCH_NEXT_UI_ABILITY = "coldLaunchNextUIAbility";
const MAX_COLD_START_DELAY_MS = 30_000;


class RemoteConfigTestFetchResult implements FTRemoteConfigFetchResult {
  onConfigSuccessFetched(configBean: RemoteConfigBean, jsonConfig: string): RemoteConfigBean | null {
    DemoLogger.i(LOG_TAG, `Remote config fetched: md5=${configBean.getMd5()}, content=${jsonConfig}`);
    return null;
  }

  onResult(success: boolean): void {
    DemoLogger.i(LOG_TAG, `Remote config fetch result: success=${success}`);
  }
}

class DemoRouterViewTrackingHandler implements FTViewRouterTrackingHandler {
  resolveHandlerView(routeName: string): HandlerView | null {
    const normalizedRouteName = routeName.trim();
    if (normalizedRouteName.length === 0 || /^\d+$/.test(normalizedRouteName) ||
      normalizedRouteName.startsWith(IGNORED_AUTOMATIC_VIEW_PREFIX)) {
      DemoLogger.i(LOG_TAG, `Router View filtered: ${routeName}`);
      return null;
    }
    return new HandlerView(routeName);
  }
}

class DemoNavigationViewTrackingHandler implements FTViewNavigationTrackingHandler {
  resolveHandlerView(destinationName: string): HandlerView | null {
    const normalizedDestinationName = destinationName.trim();
    if (normalizedDestinationName.length === 0 || /^\d+$/.test(normalizedDestinationName) ||
      normalizedDestinationName.startsWith(IGNORED_AUTOMATIC_VIEW_PREFIX)) {
      DemoLogger.i(LOG_TAG, `Navigation View filtered: ${destinationName}`);
      return null;
    }
    return new HandlerView(destinationName);
  }
}

/**
 * Example of automatic Action filtering. Returning null skips a matching
 * Action; returning undefined continues through the original automatic Action
 * collection path.
 */
class DemoActionTrackingHandler implements FTActionTrackingHandler {
  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): null | undefined {
    const source = actionEventWrapper.getSource();
    const nodeId = source?.getId() ?? '';
    const nodeType = source?.getNodeType() ?? 'UnknownComponent';
    const actionName = nodeId.length > 0 ? `${nodeType}/${nodeId}` : nodeType;
    if (this.shouldFilterAction(actionName, nodeId)) {
      DemoLogger.i(LOG_TAG, `Automatic Action filtered: name=${actionName}, id=${nodeId}`);
      return null;
    }

    return undefined;
  }

  private shouldFilterAction(actionName: string, nodeId: string): boolean {
    for (let index = 0; index < FILTERED_AUTOMATIC_ACTION_NAME_PREFIXES.length; index++) {
      if (actionName.startsWith(FILTERED_AUTOMATIC_ACTION_NAME_PREFIXES[index])) {
        return true;
      }
    }
    for (let index = 0; index < FILTERED_AUTOMATIC_ACTION_IDS.length; index++) {
      if (nodeId === FILTERED_AUTOMATIC_ACTION_IDS[index]) {
        return true;
      }
    }
    return false;
  }
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
 * --ps networkRouteTestEnabled true --ps networkRouteTestMode proxy --ps networkRouteTestHost your_route_test_host
 *
 * 7. Enable the local custom DNS route test:
 * --ps networkRouteTestEnabled true --ps networkRouteTestMode dns --ps networkRouteTestHost your_dns_server
 *
 * 8. Enable remote-configuration verification (fetches on every cold start):
 * --ps remoteConfigTestEnabled true
 *
 * 9. Configure local filter rules:
 * --ps localDataFilterLogRule "{ message match ['.*password.*'] }"
 *
 * 10. Full example:
 * --ps datawayUrl https\://rum-openway.guance.com --ps clientToken your_client_token --ps webViewUrl http\://10.0.0.1\:8000 --ps traceUrl http\://10.0.0.1\:8000/api/user --ps appId your_app_id --ps remoteConfigTestEnabled true
 *
 * Behavior:
 * - Parameters passed in onCreate are persisted to preferences.
 * - Omitted parameters use saved values; explicit empty string parameters clear saved strings.
 * - Demo and UI tests use the same names, defaults, validation and persistence.
 * - An explicit upload URL selects DataKit or Dataway and clears the other mode.
 * - SDK, WebView, and trace test pages all read from the same persisted runtime config.
 */
export default class EntryAbility extends UIAbility {
  private coldStartDelayMs: number = 0;
  private coldLaunchTestWant: Want | null = null;
  private secondaryLaunchStarted: boolean = false;
  private runtimeConfig: Record<string, string> = resolveEntryRuntimeConfig({}, {});

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    this.coldLaunchTestWant = want;
    this.coldStartDelayMs = this.resolveColdStartDelayMs(want);
    this.logAppMemoryLimitOnMainThread();
    try {
      this.runtimeConfig = await this.loadRuntimeConfig(want);
      this.initFTSDK();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      DemoLogger.e(LOG_TAG, `Runtime configuration failed: ${message}`);
    }
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

  private resolveColdStartDelayMs(want: Want): number {
    const value = want.parameters?.[KEY_COLD_START_DELAY_MS];
    const delayMs = Number(value);
    if (!Number.isFinite(delayMs) || delayMs <= 0) {
      return 0;
    }
    return Math.min(MAX_COLD_START_DELAY_MS, Math.floor(delayMs));
  }

  private readWantString(want: Want, key: string, defaultValue: string): string {
    const value = want.parameters?.[key];
    return value === null || value === undefined ? defaultValue : String(value);
  }

  /**
   * A-to-B half of the multi-UIAbility cold-launch acceptance test. The
   * parameter is forwarded to B, but B accepts only EntryAbility as a target,
   * which prevents a launch loop.
   */
  private async startSecondaryLaunchAbilityIfRequested(): Promise<void> {
    const want = this.coldLaunchTestWant;
    if (want === null) {
      return;
    }
    const nextAbility = this.readWantString(want, KEY_COLD_LAUNCH_NEXT_UI_ABILITY, '');
    if (nextAbility !== 'SecondaryLaunchAbility') {
      return;
    }
    if (this.secondaryLaunchStarted) {
      return;
    }
    this.secondaryLaunchStarted = true;

    // The test starts its target only after the source first-frame callback. Force the
    // test Action through the normal worker/cache drain now; normal launches
    // retain their regular 10-second automatic upload aggregation window.
    FTSDK.flushSyncData();
    DemoLogger.i(LOG_TAG, 'Cold-launch test parameter requests EntryAbility -> SecondaryLaunchAbility after first frame');

    const targetWant: Want = {
      bundleName: this.context.abilityInfo.bundleName,
      moduleName: this.context.abilityInfo.moduleName,
      abilityName: nextAbility,
      parameters: want.parameters
    };
    try {
      await this.context.startAbility(targetWant);
      DemoLogger.i(LOG_TAG, 'Cold-launch test parameter started SecondaryLaunchAbility');
    } catch (error) {
      this.secondaryLaunchStarted = false;
      DemoLogger.e(LOG_TAG, `Cold-launch test parameter failed to start SecondaryLaunchAbility: ${error}`);
    }
  }

  onDestroy(): void {
    // Lifecycle monitoring is now handled automatically by SDK via applicationContext
    // No manual stopView() call needed - SDK's FTAbilityLifecycleListener handles this
  }

  private async loadRuntimeConfig(want: Want): Promise<Record<string, string>> {
    const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    const saved: Record<string, string> = {};
    const incoming: Record<string, string> = {};
    for (const key of ENTRY_RUNTIME_KEYS) {
      saved[key] = String(await store.get(key, ''));
      const value = want.parameters?.[key];
      if (value !== undefined && value !== null) incoming[key] = String(value);
    }
    const config = resolveEntryRuntimeConfig(incoming, saved);
    const sources: string[] = [];
    let changed = false;
    for (const key of ENTRY_RUNTIME_KEYS) {
      sources.push(`${key}:${incoming[key] !== undefined ? 'argument' : (saved[key].length > 0 ? 'preferences' : 'default')}`);
      if (saved[key] !== config[key]) {
        await store.put(key, config[key]);
        changed = true;
      }
      AppStorage.setOrCreate(key, config[key]);
    }
    if (changed) await store.flush();
    DemoLogger.i(LOG_TAG, `Runtime config sources: ${sources.join(', ')}`);
    DemoLogger.i(LOG_TAG, this.formatRuntimeConfigLog(config));
    return config;
  }

  /**
   * This startup-only diagnostic runs before installLogConfig: it remains in
   * local HiLog but is not automatically uploaded. Print only the final
   * resolved configuration, with clientToken masked.
   */
  private formatRuntimeConfigLog(runtimeConfig: Record<string, string>): string {
    const resolvedValues: string[] = [];
    for (const key of ENTRY_RUNTIME_KEYS) {
      const value = key === KEY_CLIENT_TOKEN ? this.maskClientToken(runtimeConfig[key]) : runtimeConfig[key];
      resolvedValues.push(`${key}=${value}`);
    }
    return `Runtime config loaded resolved={${resolvedValues.join(', ')}}`;
  }

  private maskClientToken(token: string): string {
    return token.length === 0 ? '<empty>' : `<masked:length=${token.length}>`;
  }

  private applyLocalDataFilterConfig(sdkConfig: FTSDKConfig): FTSDKConfig {
    const filters = new Map<string, Array<string>>();
    const logRule = this.runtimeConfig.localDataFilterLogRule.trim();
    const rumRule = this.runtimeConfig.localDataFilterRumRule.trim();
    if (logRule.length > 0) {
      filters.set('logging', [logRule]);
    }
    if (rumRule.length > 0) {
      filters.set('rum', [rumRule]);
    }
    const enabled = this.runtimeConfig.localDataFilterEnabled === 'true';

    return sdkConfig.setEnableDataFilter(enabled).setDataFilters(filters);
  }

  private initFTSDK():void{
    try {
      // Get the Context - use this.context instead of getContext(this)
      const context = this.context;
      const datakitUrl = this.runtimeConfig.datakitUrl.trim();
      const datawayUrl = this.runtimeConfig.datawayUrl.trim();
      const clientToken = this.runtimeConfig.clientToken.trim();
      const appId = this.runtimeConfig.appId.trim();
      let networkRouteTestEnabled = this.runtimeConfig.networkRouteTestEnabled === 'true';
      const networkRouteTestMode = this.runtimeConfig.networkRouteTestMode;
      const networkRouteTestHost = this.runtimeConfig.networkRouteTestHost.trim();
      const remoteConfigTestEnabled = this.runtimeConfig.remoteConfigTestEnabled === 'true';
      const remoteConfigFetchResult: FTRemoteConfigFetchResult | null = remoteConfigTestEnabled
        ? new RemoteConfigTestFetchResult()
        : null;

      if (networkRouteTestEnabled && networkRouteTestHost.length === 0) {
        DemoLogger.w(LOG_TAG, "Network route test disabled: networkRouteTestHost is required");
        networkRouteTestEnabled = false;
      }

      // Create SDK configuration
      let sdkConfig: FTSDKConfig;
      if (networkRouteTestEnabled) {
        const uploadUrl = networkRouteTestMode === 'dns'
          ? `http://${NETWORK_ROUTE_TEST_DNS_HOSTNAME}:${NETWORK_ROUTE_TEST_UPLOAD_PORT}`
          : `http://${networkRouteTestHost}:${NETWORK_ROUTE_TEST_UPLOAD_PORT}`;
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
        // The SDK can collect and cache data before an intake endpoint is
        // configured. A later FTSDK.setDatakitUrl/setDatawayUrl call enables
        // upload without requiring the application to reinstall the SDK.
        sdkConfig = FTSDKConfig.builder();
        DemoLogger.w(LOG_TAG, 'No DataKit or Dataway URL configured; installing SDK without an upload endpoint');
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
        .setAutoSync(networkRouteTestEnabled ? false : this.runtimeConfig.autoSync === 'true')
        // .setSyncPageSize(SyncPageSize.MEDIUM) // Default: 10 records per upload request
        .setCustomSyncPageSize(20)
        .setDataSyncRetryCount(2) // Default: retry failed uploads up to 5 times
        .setSyncSleepTime(100) // Default: no extra delay between upload requests
        .setCompressIntakeRequests(false) // Disable only so manual tests can read the marker
        .setRemoteConfiguration(remoteConfigTestEnabled)
        .setRemoteConfigMiniUpdateInterval(remoteConfigTestEnabled ? 0 : 43200)
        .setRemoteConfigurationCallBack(remoteConfigFetchResult)
        // The callbacks target only demo_sensitive_* fields. See the Data
        // Modifier Test page for a reproducible masking verification flow.
        .setDataModifier(new DemoDataModifier())
        .setLineDataModifier(new DemoLineDataModifier());

      sdkConfig = this.applyLocalDataFilterConfig(sdkConfig);
      if (networkRouteTestEnabled && networkRouteTestMode === 'proxy') {
        sdkConfig = sdkConfig.setProxy({
          host: networkRouteTestHost,
          port: NETWORK_ROUTE_TEST_PROXY_PORT
        });
      } else if (networkRouteTestEnabled && networkRouteTestMode === 'dns') {
        sdkConfig = sdkConfig.setDns({
          servers: [networkRouteTestHost]
        });
      }
      // Initialize SDK
      FTSDK.install(sdkConfig, context);

      // Initialize log configuration
      const logConfig = new FTLoggerConfig()
        .setSamplingRate(Number(this.runtimeConfig.logSamplingRate))  // Shared persisted sampling configuration
        .setEnableCustomLog(true)
        .setEnableConsoleLog(true)
        // .setLogCacheLimitCount(20000)
        .setPrintCustomLogToConsole(true)
        .setLogLevelFilters([Status.ERROR, Status.DEBUG, Status.INFO])
        .setLogCacheDiscardStrategy(LogCacheDiscard.DISCARD_OLDEST)
        .setEnableLinkRumData(true);
      FTSDK.installLogConfig(logConfig);

      // Test log sampling rate
      DemoLogger.i(LOG_TAG, "Log config completed");

      // Initialize RUM configuration
      if (appId.length === 0) {
        DemoLogger.w(LOG_TAG, "SDK initialization skipped: appId is empty");
        return;
      }
      const rumConfig = new FTRUMConfig()
        .setRumAppId(appId)
        .setEnableTrackAppCrash(true)  // JS and native crash monitoring
        .setSamplingRate(Number(this.runtimeConfig.rumSamplingRate))
        .setSessionErrorSampleRate(Number(this.runtimeConfig.errorSamplingRate))
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTrackAppANR(true)
        .setEnableTrackAppUIBlock(true,300)
        .setViewRouterTrackingHandler(new DemoRouterViewTrackingHandler())
        .setViewNavigationTrackingHandler(new DemoNavigationViewTrackingHandler())
        .setActionTrackingHandler(new DemoActionTrackingHandler())
        .addGlobalContext("custom_key",new String("custom_value"))
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.ALL, DetectFrequency.DEFAULT)
        // .setRumCacheLimitCount(60000)

      FTSDK.installRUMConfig(rumConfig);

      // Bind user data using new UserData class with persistence
      const userData = new UserData();
      userData.setId("harmonyos.guance.userid");
      userData.setName("harmonyos_user_guance_test");
      userData.setEmail("harmonyos@guance.com");
      userData.addExt("ft_key", "ft_value");

      FTSDK.bindRumUserData(userData);

      // Initialize trace configuration
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(Number(this.runtimeConfig.traceSamplingRate))
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.DDTRACE);
      FTSDK.installTraceConfig(traceConfig);

    } catch (error) {
      DemoLogger.e(LOG_TAG, `SDK initialization failed: ${error}`);
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const startSecondaryAfterFirstFrame = (): void => {
      void this.startSecondaryLaunchAbilityIfRequested();
    };
    FTColdLaunchBridge.onFirstFrameRecorded(startSecondaryAfterFirstFrame);
    if (this.coldStartDelayMs > 0) {
      DemoLogger.i(LOG_TAG, `Demo cold-start delay enabled: ${this.coldStartDelayMs}ms before loadContent`);
      setTimeout(() => {
        this.loadEntryContent(windowStage);
      }, this.coldStartDelayMs);
      return;
    }
    this.loadEntryContent(windowStage);
  }

  private loadEntryContent(
    windowStage: window.WindowStage
  ): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        DemoLogger.e(LOG_TAG, `loadContent failed: ${err.code}`);
        return;
      }
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
