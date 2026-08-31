import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import preferences from '@ohos.data.preferences';
import window from '@ohos.window';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import {
  DBCacheDiscard,
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
import { observeFTAppFirstFrame } from '@guancecloud/ft_sdk_ext/Index';
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
export const RUNTIME_CONFIG_PREFERENCES_NAME = PREFERENCES_NAME;
const PRE_INIT_SMOKE_EXECUTION_MODE: PreInitAxiosSmokeExecutionMode = 'sequential';
// Local-only defaults for manually validating SDK upload proxy and custom DNS.
// They can be overridden through launch parameters. Keep the test disabled by
// default so a normal Demo launch always uses its configured DataKit/DataWay URL.
const DEFAULT_NETWORK_ROUTE_TEST_ENABLED = false;
const DEFAULT_NETWORK_ROUTE_TEST_MODE: 'proxy' | 'dns' = 'proxy';
const DEFAULT_REMOTE_CONFIG_TEST_ENABLED = false;
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
export const KEY_AUTO_SYNC = "autoSync";
export const KEY_NETWORK_ROUTE_TEST_ENABLED = "networkRouteTestEnabled";
export const KEY_NETWORK_ROUTE_TEST_MODE = "networkRouteTestMode";
export const KEY_NETWORK_ROUTE_TEST_HOST = "networkRouteTestHost";
export const KEY_REMOTE_CONFIG_TEST_ENABLED = "remoteConfigTestEnabled";
export const KEY_LOCAL_DATA_FILTER_ENABLED = "localDataFilterEnabled";
export const KEY_LOCAL_DATA_FILTER_LOG_RULE = "localDataFilterLogRule";
export const KEY_LOCAL_DATA_FILTER_RUM_RULE = "localDataFilterRumRule";

export const KEY_APP_ID = "appId";
/** Demo-only launch parameter; delays first content loading to exercise first-frame timing. */
export const KEY_COLD_START_DELAY_MS = "coldStartDelayMs";
/** Demo-only parameter for switching between the two test UIAbilities after the source first frame. */
export const KEY_COLD_LAUNCH_NEXT_UI_ABILITY = "coldLaunchNextUIAbility";
const MAX_COLD_START_DELAY_MS = 30_000;

interface RuntimeConfig {
  datakitUrl: string;
  datawayUrl: string;
  webViewUrl: string;
  traceUrl: string;
  clientToken: string;
  autoSync: string;
  networkRouteTestEnabled: string;
  networkRouteTestMode: string;
  networkRouteTestHost: string;
  remoteConfigTestEnabled: string;
  localDataFilterEnabled: string;
  localDataFilterLogRule: string;
  localDataFilterRumRule: string;
  appId: string;
}

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
 * --ps datakitUrl http\://10.0.0.1\:9529 --ps datawayUrl https\://rum-openway.guance.com --ps clientToken your_client_token --ps webViewUrl http\://10.0.0.1\:8000 --ps traceUrl http\://10.0.0.1\:8000/api/user --ps appId your_app_id --ps remoteConfigTestEnabled true
 *
 * Behavior:
 * - Parameters passed in onCreate are persisted to preferences.
 * - If a parameter is empty or omitted, the persisted value is used instead.
 * - SDK upload uses DataKit when datakitUrl is configured; DataWay is used only as fallback.
 * - SDK, WebView, and trace test pages all read from the same persisted runtime config.
 */
export default class EntryAbility extends UIAbility {
  private coldStartDelayMs: number = 0;
  private coldLaunchTestWant: Want | null = null;
  private secondaryLaunchStarted: boolean = false;
  private runtimeConfig: RuntimeConfig = {
    datakitUrl: "",
    datawayUrl: "",
    webViewUrl: "",
    traceUrl: "",
    clientToken: "",
    autoSync: "",
    networkRouteTestEnabled: "",
    networkRouteTestMode: "",
    networkRouteTestHost: "",
    remoteConfigTestEnabled: "",
    localDataFilterEnabled: "",
    localDataFilterLogRule: "",
    localDataFilterRumRule: "",
    appId: ""
  };

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    FTSDK.recordAppFirstUIAbilityCreate();
    this.coldLaunchTestWant = want;
    this.coldStartDelayMs = this.resolveColdStartDelayMs(want);
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

  private async loadRuntimeConfig(want: Want): Promise<RuntimeConfig> {
    const autoSyncParam = want.parameters?.[KEY_AUTO_SYNC];
    const networkRouteTestEnabledParam = want.parameters?.[KEY_NETWORK_ROUTE_TEST_ENABLED];
    const networkRouteTestModeParam = want.parameters?.[KEY_NETWORK_ROUTE_TEST_MODE];
    const networkRouteTestHostParam = want.parameters?.[KEY_NETWORK_ROUTE_TEST_HOST];
    const remoteConfigTestEnabledParam = want.parameters?.[KEY_REMOTE_CONFIG_TEST_ENABLED];
    const localDataFilterEnabledParam = want.parameters?.[KEY_LOCAL_DATA_FILTER_ENABLED];
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
      networkRouteTestHost: networkRouteTestHostParam === undefined || networkRouteTestHostParam === null
        ? ""
        : String(networkRouteTestHostParam),
      remoteConfigTestEnabled: remoteConfigTestEnabledParam === undefined || remoteConfigTestEnabledParam === null
        ? ""
        : String(remoteConfigTestEnabledParam),
      localDataFilterEnabled: localDataFilterEnabledParam === undefined || localDataFilterEnabledParam === null
        ? ""
        : String(localDataFilterEnabledParam),
      localDataFilterLogRule: (want.parameters?.[KEY_LOCAL_DATA_FILTER_LOG_RULE] as string | null | undefined) ?? "",
      localDataFilterRumRule: (want.parameters?.[KEY_LOCAL_DATA_FILTER_RUM_RULE] as string | null | undefined) ?? "",
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
    runtimeConfig.networkRouteTestHost = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_NETWORK_ROUTE_TEST_HOST,
      runtimeConfig.networkRouteTestHost,
      ""
    );
    runtimeConfig.remoteConfigTestEnabled = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_REMOTE_CONFIG_TEST_ENABLED,
      runtimeConfig.remoteConfigTestEnabled,
      ""
    );
    runtimeConfig.localDataFilterEnabled = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_LOCAL_DATA_FILTER_ENABLED,
      runtimeConfig.localDataFilterEnabled,
      "true"
    );
    runtimeConfig.localDataFilterLogRule = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_LOCAL_DATA_FILTER_LOG_RULE,
      runtimeConfig.localDataFilterLogRule,
      ""
    );
    runtimeConfig.localDataFilterRumRule = await this.resolveRuntimeValue(
      preferencesStore,
      KEY_LOCAL_DATA_FILTER_RUM_RULE,
      runtimeConfig.localDataFilterRumRule,
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
    AppStorage.setOrCreate(KEY_NETWORK_ROUTE_TEST_HOST, runtimeConfig.networkRouteTestHost);
    AppStorage.setOrCreate(KEY_REMOTE_CONFIG_TEST_ENABLED, runtimeConfig.remoteConfigTestEnabled);
    AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_ENABLED, runtimeConfig.localDataFilterEnabled);
    AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_LOG_RULE, runtimeConfig.localDataFilterLogRule);
    AppStorage.setOrCreate(KEY_LOCAL_DATA_FILTER_RUM_RULE, runtimeConfig.localDataFilterRumRule);
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
    await preferencesStore.put(KEY_NETWORK_ROUTE_TEST_HOST, runtimeConfig.networkRouteTestHost);
    await preferencesStore.put(KEY_REMOTE_CONFIG_TEST_ENABLED, runtimeConfig.remoteConfigTestEnabled);
    await preferencesStore.put(KEY_LOCAL_DATA_FILTER_ENABLED, runtimeConfig.localDataFilterEnabled);
    await preferencesStore.put(KEY_LOCAL_DATA_FILTER_LOG_RULE, runtimeConfig.localDataFilterLogRule);
    await preferencesStore.put(KEY_LOCAL_DATA_FILTER_RUM_RULE, runtimeConfig.localDataFilterRumRule);
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

  private isRemoteConfigTestEnabled(): boolean {
    const value = this.runtimeConfig.remoteConfigTestEnabled.trim().toLowerCase();
    if (value.length === 0) {
      return DEFAULT_REMOTE_CONFIG_TEST_ENABLED;
    }
    return value === 'true' || value === '1' || value === 'on';
  }

  private isLocalDataFilterEnabled(): boolean {
    const value = this.runtimeConfig.localDataFilterEnabled.trim().toLowerCase();
    return value !== 'false' && value !== '0' && value !== 'off';
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
    const enabled = this.isLocalDataFilterEnabled();
    DemoLogger.i(LOG_TAG,
      `Local data filter startup config: enabled=${enabled}, loggingRules=${logRule.length > 0 ? 1 : 0}, rumRules=${rumRule.length > 0 ? 1 : 0}`);
    return sdkConfig.setEnableDataFilter(enabled).setDataFilters(filters);
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
      let networkRouteTestEnabled = this.isNetworkRouteTestEnabled();
      const networkRouteTestMode = this.resolveNetworkRouteTestMode();
      const networkRouteTestHost = this.runtimeConfig.networkRouteTestHost.trim();
      const remoteConfigTestEnabled = this.isRemoteConfigTestEnabled();
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
        .setAutoSync(networkRouteTestEnabled ? false : this.resolveAutoSyncEnabled())
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
      if (remoteConfigTestEnabled) {
        DemoLogger.i(LOG_TAG, 'Remote configuration test enabled: refresh interval=0 seconds');
      }
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
    const startSecondaryAfterFirstFrame = (): void => {
      void this.startSecondaryLaunchAbilityIfRequested();
    };
    const firstFrameListenerRegistered = observeFTAppFirstFrame(windowStage, startSecondaryAfterFirstFrame);
    if (this.coldStartDelayMs > 0) {
      DemoLogger.i(LOG_TAG, `Demo cold-start delay enabled: ${this.coldStartDelayMs}ms before loadContent`);
      setTimeout(() => {
        this.loadEntryContent(windowStage, firstFrameListenerRegistered, startSecondaryAfterFirstFrame);
      }, this.coldStartDelayMs);
      return;
    }
    this.loadEntryContent(windowStage, firstFrameListenerRegistered, startSecondaryAfterFirstFrame);
  }

  private loadEntryContent(
    windowStage: window.WindowStage,
    firstFrameListenerRegistered: boolean,
    startSecondaryAfterFirstFrame: () => void
  ): void {
    windowStage.loadContent('pages/Index', (err) => {
      DemoLogger.i(LOG_TAG, "loadContent callback called");
      if (err.code) {
        DemoLogger.e(LOG_TAG, `loadContent failed: ${err.code}`);
        return;
      }
      if (!firstFrameListenerRegistered) {
        DemoLogger.i(LOG_TAG, "Registering first-frame listener from successful loadContent callback");
        observeFTAppFirstFrame(windowStage, startSecondaryAfterFirstFrame);
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
