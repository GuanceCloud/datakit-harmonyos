import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import preferences from '@ohos.data.preferences';
import window from '@ohos.window';
import { FTSDK } from 'shareLibrary/src/main/ets/components/FTSDK';
import { UserData } from 'shareLibrary/src/main/ets/components/rum/bean/UserData';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from 'shareLibrary/src/main/ets/components/Configs';
import { ErrorMonitorType } from 'shareLibrary/src/main/ets/components/rum/enum/ErrorMonitorType';
import { DeviceMetricsMonitorType } from 'shareLibrary/src/main/ets/components/rum/enum/DeviceMetricsMonitorType';
import { EnvType, SyncPageSize } from 'shareLibrary/src/main/ets/components/enum/Enums';
import { DBCacheDiscard } from 'shareLibrary/src/main/ets/components/enum/Enums';
import { Status } from 'shareLibrary/src/main/ets/components/bean/Status';
import { TraceType } from 'shareLibrary/src/main/ets/components/trace/TraceType';
import { DemoLogger } from '../utils/DemoLogger';

const LOG_TAG = "EntryAbility";
const PREFERENCES_NAME = "entry_ability_runtime_config";

export const KEY_WEB_VIEW_URL = "webViewUrl";
export const KEY_TRACE_URL = "traceUrl";

export const KEY_DATAKIT_URL = "datakitUrl";
export const KEY_DATAWAY_URL = "datawayUrl";
export const KEY_CLIENT_TOKEN = "clientToken";

export const KEY_APP_ID = "appId";

interface RuntimeConfig {
  datakitUrl: string;
  datawayUrl: string;
  webViewUrl: string;
  traceUrl: string;
  clientToken: string;
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
 * 6. Full example:
 * --ps datakitUrl http\://10.0.0.1\:9529 --ps datawayUrl https\://rum-openway.guance.com --ps clientToken your_client_token --ps webViewUrl http\://10.0.0.1\:8000 --ps traceUrl http\://10.0.0.1\:8000/api/user --ps appId your_app_id
 *
 * Behavior:
 * - Parameters passed in onCreate are persisted to preferences.
 * - If a parameter is empty or omitted, the persisted value is used instead.
 * - SDK, WebView, and trace test pages all read from the same persisted runtime config.
 */
export default class EntryAbility extends UIAbility {
  private runtimeConfig: RuntimeConfig = {
    datakitUrl: "",
    datawayUrl: "",
    webViewUrl: "",
    traceUrl: "",
    clientToken: "",
    appId: ""
  };

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    DemoLogger.e("log test", `onCreate `);
    console.log("log test,onCreate")

    try {
      this.runtimeConfig = await this.loadRuntimeConfig(want);
    } catch (error) {
      DemoLogger.e(LOG_TAG, `Failed to load runtime config: ${error}`);
    }
    this.initFTSDK();
  }

  onDestroy(): void {
    // Lifecycle monitoring is now handled automatically by SDK via applicationContext
    // No manual stopView() call needed - SDK's FTAbilityLifecycleListener handles this
  }

  private async loadRuntimeConfig(want: Want): Promise<RuntimeConfig> {
    const runtimeConfig: RuntimeConfig = {
      datakitUrl: (want.parameters?.[KEY_DATAKIT_URL] as string | null | undefined) ?? "",
      datawayUrl: (want.parameters?.[KEY_DATAWAY_URL] as string | null | undefined) ?? "",
      webViewUrl: (want.parameters?.[KEY_WEB_VIEW_URL] as string | null | undefined) ?? "",
      traceUrl: (want.parameters?.[KEY_TRACE_URL] as string | null | undefined) ?? "",
      clientToken: (want.parameters?.[KEY_CLIENT_TOKEN] as string | null | undefined) ?? "",
      appId: (want.parameters?.[KEY_APP_ID] as string | null | undefined) ?? ""
    };

    if (!this.hasMissingRuntimeConfig(runtimeConfig)) {
      this.updateRuntimeConfigStorage(runtimeConfig);
      this.persistRuntimeConfig(runtimeConfig).catch((error: Error) => {
        DemoLogger.w(LOG_TAG, `Failed to persist runtime config: ${JSON.stringify(error)}`);
      });

      DemoLogger.i(
        LOG_TAG,
        `Runtime config loaded from launch parameters datakitUrl=${runtimeConfig.datakitUrl}, datawayUrl=${runtimeConfig.datawayUrl}, webViewUrl=${runtimeConfig.webViewUrl}, traceUrl=${runtimeConfig.traceUrl}, appId=${runtimeConfig.appId}`);
      return runtimeConfig;
    }

    const preferencesStore = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    runtimeConfig.datakitUrl = await this.resolveRuntimeValue(preferencesStore, KEY_DATAKIT_URL, runtimeConfig.datakitUrl, "");
    runtimeConfig.datawayUrl = await this.resolveRuntimeValue(preferencesStore, KEY_DATAWAY_URL, runtimeConfig.datawayUrl, "");
    runtimeConfig.webViewUrl = await this.resolveRuntimeValue(preferencesStore, KEY_WEB_VIEW_URL, runtimeConfig.webViewUrl, "");
    runtimeConfig.traceUrl = await this.resolveRuntimeValue(preferencesStore, KEY_TRACE_URL, runtimeConfig.traceUrl, "");
    runtimeConfig.clientToken = await this.resolveRuntimeValue(preferencesStore, KEY_CLIENT_TOKEN, runtimeConfig.clientToken, "");
    runtimeConfig.appId = await this.resolveRuntimeValue(preferencesStore, KEY_APP_ID, runtimeConfig.appId, "");

    await this.persistResolvedRuntimeConfig(preferencesStore, runtimeConfig);
    this.updateRuntimeConfigStorage(runtimeConfig);

    DemoLogger.i(
      LOG_TAG,
      `Runtime config loaded datakitUrl=${runtimeConfig.datakitUrl}, datawayUrl=${runtimeConfig.datawayUrl}, webViewUrl=${runtimeConfig.webViewUrl}, traceUrl=${runtimeConfig.traceUrl}, appId=${runtimeConfig.appId}`);

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
    await preferencesStore.put(KEY_APP_ID, runtimeConfig.appId);
    await preferencesStore.flush();
  }

  private initFTSDK():void{
    try {
      // Get the Context - use this.context instead of getContext(this)
      const context = this.context;
      const datakitUrl = this.runtimeConfig.datakitUrl.trim();
      const datawayUrl = this.runtimeConfig.datawayUrl.trim();
      const clientToken = this.runtimeConfig.clientToken.trim();
      const appId = this.runtimeConfig.appId.trim();

      // Create SDK configuration
      let sdkConfig: FTSDKConfig;
      if (datawayUrl.length > 0) {
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
        .setEnv(EnvType.GRAY)
        .setServiceName('HarmonyOS-Test-App')
        .setAutoSync(true)
        .setSyncPageSize(100) // Increased from 30 to 100 for faster upload speed and better throughput
        // Set small dbCacheLimit for testing (1MB)
        .setDbCacheLimit(1 * 1024 * 1024) // 1MB
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
      // Initialize SDK
      FTSDK.install(sdkConfig, context);
      DemoLogger.i(LOG_TAG, "SDK install completed");

      // Initialize log configuration
      const logConfig = new FTLoggerConfig()
        .setSamplingRate(1.0)  // 100% sampling rate
        .setEnableCustomLog(true)
        .setEnableConsoleLog(true)
        .setLogCacheLimitCount(30000)
        .setPrintCustomLogToConsole(true)
        .setLogLevelFilters([Status.ERROR, Status.DEBUG, Status.INFO])
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
        .setEnableTrackAppCrash(true)  // JS crash monitoring (must be true for native crash monitoring to take effect)
        .setSamplingRate(1.0)          // Set the sampling rate to 100%
        .setSessionErrorSampleRate(1.0) // Set the error sampling rate to 100%
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTraceUserResource(true)
        .setEnableTrackAppANR(true)
        .setEnableTrackAppUIBlock(true)
        .setEnableTraceUserView(true)
        .addGlobalContext("custom_key",new String("custom_value"))
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.ALL)

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
