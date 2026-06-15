import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig, LogGlobalContextDictionary, LogGlobalContextValue } from "./Configs";
import { Constants } from "./Constants";
import { UserData } from "./rum/bean/UserData";
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import ftnativecrash from 'libftnativecrash.so';
import BuildProfile from "../../../../BuildProfile";
import { FTSDKAnrManager, getFTSDKRuntime } from "./internal/runtime/FTSDKRuntime";
import FTTrackInner from "./FTTrackInner";
import { FTRUMInnerManager } from "./rum/FTRUMInnerManager";
import { FTTraceConfigManager } from "./trace/FTTraceConfigManager";
import { TrackLogManager } from "./log/TrackLogManager";
import { FTInnerLogger } from "./log/FTLogger";
import { UserDataManager } from "./rum/UserDataManager";
import { FTNetworkListener } from "./utils/FTNetworkListener";
import { SyncTaskManager } from "./SyncTaskManager";
import { FTDBCachePolicy } from "./db/FTDBCachePolicy";
import { FTDBManager } from "./db/FTDBManager";
import { FTRUMGlobalManager } from "./rum/FTRUMGlobalManager";
import { FTRUMConfigManager } from "./rum/FTRUMConfigManager";
import { FTMonitorManager } from "./rum/FTMonitorManager";
import { DeviceUtils } from "./utils/DeviceUtils";
import { DeviceUUIDManager } from "./utils/DeviceUUIDManager";
import { AppUtils } from "./utils/AppUtils";
import { ApplicationUUIDGenerator } from "./utils/ApplicationUUIDGenerator";
import { FTAbilityLifecycleListener } from "./monitor/FTAbilityLifecycleListener";
import { FTAppStartCounter } from "./monitor/FTAppStartCounter";
import { Utils } from "./utils/Utils";

const TAG = "FTSDK"

export class FTSDK {
  private static ftSdk: FTSDK | null;
  private static anrDetectManager: FTSDKAnrManager | null = null;
  private static rumConfig: FTRUMConfig | null = null;
  private static uiFeaturesInitialized: boolean = false;
  private static pendingUIFeatureInit: boolean = false;
  private static uiFeatureInitRetryCount: number = 0;
  private static readonly UI_FEATURE_INIT_MAX_RETRY: number = 5;
  private static readonly UI_FEATURE_INIT_RETRY_DELAY_MS: number = 100;

  /**
   * Get current RUM config
   */
  public static getRumConfig(): FTRUMConfig | null {
    return FTSDK.rumConfig;
  }

  protected static resetInternalState(): void {
    FTSDK.ftSdk = null;
    FTSDK.anrDetectManager = null;
    FTSDK.rumConfig = null;
    FTSDK.uiFeaturesInitialized = false;
    FTSDK.pendingUIFeatureInit = false;
    FTSDK.uiFeatureInitRetryCount = 0;
    FTSDK.autoActionTrackingEnabled = true;
    FTSDK.cachedPACKAGE_UUID = null;
  }

  protected static requiresUIFeaturesInternal(rumConfig: FTRUMConfig): boolean {
    return rumConfig.isEnableTraceUserAction() ||
      rumConfig.isEnableTraceUserView() ||
      rumConfig.isEnableTrackAppCrash() ||
      rumConfig.isEnableTrackAppANR();
  }

  protected static requiresLifecycleListenerInternal(rumConfig: FTRUMConfig): boolean {
    return FTSDK.requiresUIFeaturesInternal(rumConfig);
  }

  private static autoActionTrackingEnabled: boolean = true;
  private ftSDKConfig: FTSDKConfig | null;

  /**
   * Cached application UUID (lazy initialization)
   * Generated deterministically based on package name + version
   */
  private static cachedPACKAGE_UUID: string | null = null;

  /**
   * Application UUID - generated deterministically based on package name + version
   * One build will generate a fixed UUID, same for all installations of the same build
   * Aligned with Android: ft-plugin/src/main/java/com/ft/plugin/garble/Constants.java
   * PACKAGE_UUID = UUID.randomUUID().toString() (generated at compile time)
   *
   * Note: In HarmonyOS, we use package name + version as seed to generate deterministic UUID.
   * Same package name + version will always generate the same UUID, ensuring consistency across all installations.
   *
   * Uses lazy initialization to ensure AppUtils can access bundle info when called.
   */
  public static get PACKAGE_UUID(): string {
    if (FTSDK.cachedPACKAGE_UUID === null) {
      // Generate UUID on first access (lazy initialization)
      // This ensures AppUtils.getPackageName() can work properly
      try {
        const packageName: string = AppUtils.getPackageName();
        const versionName: string = AppUtils.getAppVersionName();

        //FTInnerLogger.d(TAG, `Generating PACKAGE_UUID from package: ${packageName}, version: ${versionName}`);

        // Generate deterministic UUID using ApplicationUUIDGenerator
        FTSDK.cachedPACKAGE_UUID = ApplicationUUIDGenerator.generateFromPackageInfo(packageName, versionName);

        //FTInnerLogger.i(TAG, ` PACKAGE_UUID generated: ${FTSDK.cachedPACKAGE_UUID}`);
      } catch (error) {
        // Fallback: use fixed seed if package info not available
        FTSDK.cachedPACKAGE_UUID = ApplicationUUIDGenerator.generateDeterministicUUID("harmonyos_fallback_seed");
        FTInnerLogger.e(TAG, ` PACKAGE_UUID (fallback): ${FTSDK.cachedPACKAGE_UUID}`);
      }
    }
    return FTSDK.cachedPACKAGE_UUID;
  }

  constructor(sdkConfig: FTSDKConfig) {
    this.ftSDKConfig = sdkConfig;
  }

  static install(sdkConfig: FTSDKConfig | null, context?: Context): void {

    try {
      if (sdkConfig == null) {
        FTInnerLogger.e(TAG, "Parameter ftSDKConfig cannot be null");
        return;
      }

      // Initialize Utils with context (required for ApplicationContext access)
      if (context && (context as common.UIAbilityContext)) {
        getFTSDKRuntime().initUtils(context as common.UIAbilityContext);
        FTInnerLogger.d(TAG, "Utils initialized with UIAbilityContext");
      } else {
        FTInnerLogger.w(TAG, "Context is not UIAbilityContext, Utils.init() skipped");
      }

      // if (ftSDKConfig.isOnlySupportMainProcess()) {
      //   const currentProcessName = Utils.getCurrentProcessName();
      //   const packageName = context.getPackageName();
      //
      //   if (packageName && packageName !== currentProcessName) {
      //     FTInnerLogger.e(
      //       "FTManager",
      //       `SDK can only run in main process, current process is ${currentProcessName}. To run in non-main process, call FTSDKConfig.setOnlySupportMainProcess(false)`
      //     );
      //     return;
      //   }
      // }

      FTSDK.ftSdk = new FTSDK(sdkConfig);
      FTSDK.ftSdk.initFTConfig(sdkConfig);
    } catch (e) {
      FTInnerLogger.e(TAG, `FTSDK initialization failed:\n${e.stack || e.message}`);
    }
    FTInnerLogger.d(TAG, "FTSDK.install completed");
  }

   initFTConfig(config: FTSDKConfig): void {
    // Enable/disable FTInnerLogger debug logs based on FTSDKConfig.setDebug() setting
    FTInnerLogger.setDebugEnabled(config.isDebugMode());

    // Start network monitoring
    // Monitor network state changes and update network type cache in real time
    FTNetworkListener.getInstance().monitor();

    // Get context from Utils (unified context management)
    const context = getFTSDKRuntime().getAbilityContext();

    // Initialize sync task manager
    if (context) {
      FTInnerLogger.d(TAG, " Initializing SyncTaskManager...");
      getFTSDKRuntime().initSyncTaskManager(config, context);
      UserDataManager.getInstance().init(context);
      DeviceUUIDManager.getInstance().init(context);

      //  TODO device monitor
      // Initialize device monitoring utilities
      // await BatteryUtils.getInstance().init();
      // await MemoryUtils.getInstance().init();
      // await CpuUtils.getInstance().init();

    } else {
      FTInnerLogger.w(TAG, " Context is null, skipping SyncTaskManager initialization");
    }

    // Add global context (after all managers are initialized)
     this.appendGlobalContext(config);

    // Initialize base configuration
    if (context) {
      FTTrackInner.getInstance().initBaseConfig(config, context);
      FTRUMInnerManager.getInstance().initContext(context);
    } else {
      FTInnerLogger.w(TAG, " Context is null, skipping FTTrackInner and FTRUMInnerManager initialization");
    }

    // Print debug log
    FTInnerLogger.d(TAG, "FTSDK.initFTConfig complete");
  }

  static installLogConfig(logConfig: FTLoggerConfig): void {
    try {
      // Initialize TrackLogManager
      TrackLogManager.getInstance().setLogConfig(logConfig);
      FTDBCachePolicy.getInstance().updateLogCacheLimitCount(logConfig.getLogCacheLimitCount());
      FTDBCachePolicy.getInstance().updateLogCacheDiscardStrategy(logConfig.getLogCacheDiscardStrategy());

      // Initialize FTTrackInner log configuration
      if (FTSDK.ftSdk) {
        FTTrackInner.getInstance().initLogConfig(logConfig);
        FTInnerLogger.d(TAG, `installLogConfig completed: samplingRate=${logConfig.getSamplingRate()}, enableCustomLog=${logConfig.isEnableCustomLog()}`);
      }else{
        FTInnerLogger.e(TAG, `installLogConfig failed: FTSDK.install not call`);
      }

    } catch (error) {
      FTInnerLogger.e(TAG, `installLogConfig failed: ${error}`);
    }
  }

  static installTraceConfig(traceConfig: FTTraceConfig): void {
    try {
      // 1. Set service name (from base configuration)
      if (FTSDK.ftSdk && FTSDK.ftSdk.ftSDKConfig) {
        traceConfig.setServiceName(FTSDK.ftSdk.ftSDKConfig.getServiceName());
      }

      // 2. Initialize Trace configuration manager
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      FTInnerLogger.d(TAG, `installTraceConfig completed: samplingRate=${traceConfig.getSamplingRate()}, traceType=${traceConfig.getTraceType()}, enableAutoTrace=${traceConfig.isEnableAutoTrace()}`);

    } catch (error) {
      FTInnerLogger.e(TAG, `installTraceConfig failed: ${error}`);
    }
  }

  static installRUMConfig(rumConfig: FTRUMConfig): void {
    // Save rumConfig reference for later use (e.g., ActionTracker initialization)
    FTSDK.rumConfig = rumConfig;
    FTSDK.updateNativePackageInfo();
    FTSDK.pendingUIFeatureInit = FTSDK.requiresUIFeaturesInternal(rumConfig);
    FTSDK.uiFeaturesInitialized = false;
    FTSDK.uiFeatureInitRetryCount = 0;

    FTSDK.initRUMGlobalContext(rumConfig);
    FTRUMConfigManager.getInstance().initWithConfig(rumConfig);
    FTDBCachePolicy.getInstance().updateRumCacheLimitCount(rumConfig.getRumCacheLimitCount());
    FTDBCachePolicy.getInstance().updateRumCacheDiscardStrategy(rumConfig.getRumCacheDiscardStrategy());
    // Initialize RUM Inner Manager with config (aligned with Android: FTRUMInnerManager.initParams)
    FTRUMInnerManager.getInstance().initParams(rumConfig);

    // Initialize RUM Global Manager with config (aligned with Android: FTRUMConfigManager.initWithConfig -> FTRUMGlobalManager.initConfig)
    FTRUMGlobalManager.getInstance().initConfig(rumConfig);

    // Initialize RUM config in FTTrackInner (aligned with Android: FTRUMConfigManager.initWithConfig -> FTTrackInner.initRUMConfig)
    // This initializes rumStaticFields (session_sample_rate, session_on_error_sample_rate) in SyncDataHelper
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().initRUMConfig(rumConfig);
    } else {
      FTInnerLogger.e(TAG, `installLogConfig failed: FTSDK.install not call`);
    }

    // Register UIAbility lifecycle listener when any UI-bound feature is enabled.
    // This allows SDK to automatically obtain WindowStage/MainWindow/UIContext later.
    if (FTSDK.requiresLifecycleListenerInternal(rumConfig)) {
      try {
        getFTSDKRuntime().registerLifecycleListener();
        FTInnerLogger.i(TAG, "UIAbility lifecycle listener registered for automatic UI feature initialization");
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to register UIAbility lifecycle listener: ${String(error)}`);
      }
    }

    // Check and handle cold start if onWindowStageCreate was called before SDK initialization
    // This happens when SDK is initialized in onWindowStageCreate, but the lifecycle callback
    // was registered after onWindowStageCreate was already called
    if (rumConfig.isEnableTraceUserAction()) {
      try {
        const appStartCounter = FTAppStartCounter.getInstance();
        if (!appStartCounter.isInited()) {
          // onWindowStageCreate was likely called before SDK initialization
          // Manually trigger cold start calculation
          const endTime = Utils.getCurrentNanoTime();
          appStartCounter.coldStart(endTime);
          appStartCounter.coldStartUpload();
          appStartCounter.setInited(true);
          FTInnerLogger.d(TAG, "Cold start calculated and uploaded (manual trigger after SDK init)");
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to calculate cold start: ${String(error)}`);
      }
    }

    // Initialize monitor manager
    FTMonitorManager.getInstance().initWithConfig(rumConfig);

    // Initialize ANR detect manager
    FTSDK.anrDetectManager = getFTSDKRuntime().getAnrDetectManager();

    // Initialize exception handler for crash tracking
    // Aligned with Android: FTExceptionHandler.get().initConfig(config)
    if (rumConfig.isEnableTrackAppCrash()) {
      getFTSDKRuntime().initExceptionHandler(rumConfig);
      FTInnerLogger.d(TAG, "FTExceptionHandler initialized for crash tracking");
    }

    // Initialize UI block detection
    // Aligned with Android: FTUIBlockManager.get().start(config)
    if (rumConfig.isEnableTrackAppUIBlock()) {
      getFTSDKRuntime().startUIBlockManager(rumConfig);
      FTInnerLogger.d(TAG, "FTUIBlockManager initialized for UI block detection");
    }

    if (FTSDK.pendingUIFeatureInit) {
      getFTSDKRuntime().setMainWindow();
      FTSDK.tryInitializeUIFeaturesInternal();
    }

    FTInnerLogger.d(TAG, "installRUMConfig completed");
  }

  private static  initRUMGlobalContext(config:FTRUMConfig):void{
    let hashMap: Map<string, object> = config.getGlobalContext();
    if (hashMap.size > 0) {
      // Add all hashmap keys as a JSON string array
      const keys = Array.from(hashMap.keys());
      hashMap.set(Constants.KEY_RUM_CUSTOM_KEYS, new String(JSON.stringify(keys)));
    }
    hashMap.set(Constants.KEY_RUM_APP_ID, new String(config.getRumAppId()))
    hashMap.set(Constants.KEY_RUM_SESSION_TYPE, new String('user'));
    hashMap.set(Constants.KEY_DEVICE_OS, new String("HarmonyOS"));
    hashMap.set(Constants.KEY_DEVICE_DEVICE_BAND, new String(DeviceUtils.getDeviceBrand()));
    hashMap.set(Constants.KEY_DEVICE_DEVICE_MODEL, new String(DeviceUtils.getDeviceModel()));
    hashMap.set(Constants.KEY_DEVICE_DEVICE_ARCH, new String(DeviceUtils.getDeviceArch()));
    hashMap.set(Constants.KEY_DEVICE_DISPLAY, new String(DeviceUtils.getDisplay()));
    hashMap.set(Constants.KEY_SERVICE, new String(config.getServiceName()));

    hashMap.set(Constants.KEY_DEVICE_OS_VERSION, new String(DeviceUtils.getOSVersion()));
    hashMap.set(Constants.KEY_DEVICE_OS_VERSION_MAJOR, new String(DeviceUtils.getOSVersionMajor()));

  }

  /**
   * Bind RUM user data with User ID only
   * Bind RUM user data by ID
   * @param id User ID
   */
  static bindRumUserDataById(id: string): void {
    const userData = new UserData(id);
    UserDataManager.getInstance().bindUserData(userData)

    FTInnerLogger.d(TAG, `bindRumUserData completed with ID: ${id}`);
  }

  /**
   * Bind RUM user data with UserData object
   * Bind RUM user data with UserData object and persist to preferences
   * @param userData User data object
   */
  static bindRumUserData(userData: UserData): void {
    // Persist user data to preferences
    UserDataManager.getInstance().bindUserData(userData);
    FTInnerLogger.d(TAG, `bindRumUserData completed: ${userData.getSummary()}`);
  }


  /**
   * Unbind RUM user data
   * Unbind RUM user data and clear from preferences
   */
  static unbindRumUserData(): void {
    // Clear from preferences
    UserDataManager.getInstance().unbindUserData();
    FTInnerLogger.d(TAG, "unbindRumUserData completed");
  }


  static shutDown() {
    // Unregister UIAbility lifecycle listener
    try {
      FTAbilityLifecycleListener.getInstance().unregister();
      FTInnerLogger.d(TAG, "UIAbility lifecycle listener unregistered");
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to unregister UIAbility lifecycle listener: ${String(error)}`);
    }

    // Release RUM manager state to avoid timers and context references surviving SDK shutdown.
    FTRUMInnerManager.shutdownInternal();

    // Release network listener (similar to Android)
    FTNetworkListener.release();
    FTInnerLogger.d(TAG, "FTSDK shut down, network listener released");
    //todo Clear device configuration
  }

  /**
   * Dynamically set global tag
   * @param globalContext Global context map
   */
  static appendGlobalContext(globalContext: Map<string, string>): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendGlobalContext() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendGlobalContext(globalContext);
    }
  }

  /**
   * Dynamically set global tag
   * @param key Tag key
   * @param value Tag value
   */
  static appendGlobalContextKeyValue(key: string, value: string): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendGlobalContextKeyValue() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendGlobalContextKeyValue(key, value);
    }
  }

  /**
   * Dynamically set RUM global tag
   * @param globalContext RUM global context map
   */
  static appendRUMGlobalContext(globalContext: Map<string, string>): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendRUMGlobalContext() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendRUMGlobalContext(globalContext);
    }
  }

  /**
   * Dynamically set RUM global tag
   * @param key Tag key
   * @param value Tag value
   */
  static appendRUMGlobalContextKeyValue(key: string, value: string): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendRUMGlobalContextKeyValue() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendRUMGlobalContextKeyValue(key, value);
    }
  }

  /**
   * Dynamically set log global tag
   * @param globalContext Log global context map
   */
  static appendLogGlobalContext(globalContext: LogGlobalContextDictionary): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendLogGlobalContext() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendLogGlobalContext(globalContext);
    }
  }

  /**
   * Dynamically set log global tag
   * @param key Tag key
   * @param value Tag value
   */
  static appendLogGlobalContextKeyValue(key: string, value: LogGlobalContextValue): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendLogGlobalContextKeyValue() behavior
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().appendLogGlobalContextKeyValue(key, value);
    }
  }


  private appendGlobalContext(config: FTSDKConfig): void {
    let hashMap: Map<string, object> = config.getGlobalContext();
    // Add basic app and SDK information (using direct string keys for better compatibility)
    hashMap.set(Constants.KEY_APP_VERSION_NAME, new String(AppUtils.getAppVersionName()));
    hashMap.set(Constants.KEY_SDK_NAME, new String(Constants.SDK_NAME));
    hashMap.set(Constants.KEY_ENV, new String(config.getEnv()));

    // Add device information (using ODID - Huawei recommended)
    const deviceUUID = DeviceUUIDManager.getInstance().getDeviceUUID(config.isAccessODIDEnabled());
    hashMap.set(Constants.KEY_DEVICE_UUID, new String(deviceUUID));
    hashMap.set(Constants.KEY_APPLICATION_UUID, new String(FTSDK.PACKAGE_UUID));

    let pkgJson = JSON.stringify(this.getInnerPkgInfoHashMap(config));
    pkgJson = pkgJson.replace(/","/g, '","');
    hashMap.set(Constants.KEY_SDK_PACKAGE_INFO, new String(pkgJson));
    hashMap.set(Constants.KEY_SDK_VERSION, new String(BuildProfile.HAR_VERSION));

  }

  private static getNativeCrashVersion(): string {
    try {
      return ftnativecrash.getVersion();
    } catch (e) {
      FTInnerLogger.e(TAG, `not ftnativecrash include`);
      return "";
    }
  }

  private static updateNativePackageInfo(): void {
    if (!FTSDK.ftSdk || !FTSDK.ftSdk.ftSDKConfig) {
      return;
    }
    const nativeVersion = FTSDK.getNativeCrashVersion();
    if (nativeVersion.length === 0) {
      return;
    }

    const pkgJson = JSON.stringify(FTSDK.ftSdk.getInnerPkgInfoHashMap(FTSDK.ftSdk.ftSDKConfig));
    FTSDK.ftSdk.ftSDKConfig.getGlobalContext().set(Constants.KEY_SDK_PACKAGE_INFO, new String(pkgJson));
    FTTrackInner.getInstance().appendGlobalContextKeyValue(Constants.KEY_SDK_PACKAGE_INFO, pkgJson);
  }

  private getInnerPkgInfoHashMap(config: FTSDKConfig): Record<string,string> {
    const pkgInfo: Record<string, string> = {};
    //agent
    pkgInfo[Constants.KEY_SDK_PACKAGE_AGENT] = BuildProfile.HAR_VERSION;
    const nativeVersion = FTSDK.getNativeCrashVersion();
    if (nativeVersion.length > 0) {
      pkgInfo[Constants.KEY_RUM_SDK_PACKAGE_NATIVE] = nativeVersion;
    }
    // Merge user-defined pkgInfo from config (similar to Android: pkgInfo.putAll(config.getPkgInfo()))
    const userPkgInfo = config.getPkgInfo();
    if (userPkgInfo && userPkgInfo.size > 0) {
      const userPkgInfoKeys = Array.from(userPkgInfo.keys());
      for (let i = 0; i < userPkgInfoKeys.length; i++) {
        const key = userPkgInfoKeys[i];
        const value = userPkgInfo.get(key);
        if (value && value !== "") {
          pkgInfo[key] = value;
        }
      }
    }
    return pkgInfo;
  }
  /**
   * Initialize UI-related features (action tracker and APM subscription)
   * Must be called after installRUMConfig, typically in onWindowStageCreate
   * @param uiContext UI context from window stage
   */
  public static initializeUIFeatures(uiContext: UIContext): void {
    if (FTSDK.uiFeaturesInitialized) {
      FTInnerLogger.d(TAG, "UI features already initialized, skipping duplicate initialization");
      return;
    }

    try {
      const rumConfig = FTSDK.rumConfig;
      // Initialize action tracker only when explicitly enabled
      if (rumConfig) {
        if (FTSDK.autoActionTrackingEnabled) {
          getFTSDKRuntime().initActionTracker(uiContext, rumConfig);
          FTInnerLogger.d(TAG, "Action tracker initialized successfully");
        } else {
          FTInnerLogger.i(TAG, "Auto action tracking is disabled; skipping FTActionTracker init");
        }
        // Initialize navigation tracker (automatic view start/stop from navigation/router events)
        // Only initialize if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks)
        getFTSDKRuntime().initNavigationTracker(uiContext, rumConfig);
        FTInnerLogger.d(TAG, "Navigation tracker initialized successfully");
      } else {
        FTInnerLogger.w(TAG, "RUM config not available, skipping action tracker initialization");
        return;
      }

      // Initialize ANR monitoring
      if (!FTSDK.anrDetectManager) {
        FTInnerLogger.e(TAG, "ANR detect manager not initialized in installRUMConfig()");
        return;
      }

      const enableANRMonitoring = rumConfig.isEnableTrackAppANR();

      if (enableANRMonitoring) {
        FTSDK.anrDetectManager.initialize();
        FTSDK.anrDetectManager.startMonitoring();
        FTInnerLogger.i(TAG, `ANR monitoring initialized: anr=${enableANRMonitoring}`);
      } else {
        FTInnerLogger.d(TAG, "ANR monitoring skipped: ANR monitoring is disabled");
      }

      FTSDK.uiFeaturesInitialized = true;
      FTSDK.pendingUIFeatureInit = false;
      FTSDK.uiFeatureInitRetryCount = 0;
      FTInnerLogger.i(TAG, "UI features (action tracker and ANR monitor) initialized successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize UI features: ${error}`);
    }
  }

  public static onWindowStageActive(mainWindow?: window.Window): void {
    FTSDK.uiFeatureInitRetryCount = 0;
    getFTSDKRuntime().setMainWindow(mainWindow);
    FTSDK.tryInitializeUIFeaturesInternal();
  }

  /**
   * Enable or disable automatic click tracking (FTActionTracker)
   */
  public static setAutoActionTrackingEnabled(enabled: boolean): void {
    FTSDK.autoActionTrackingEnabled = enabled;
  }

  /**
   * Clean up UI-related features and release references
   * Should be called in onWindowStageDestroy to prevent memory leaks
   */
  public static cleanupUIFeatures(): void {
    try {
      FTSDK.uiFeaturesInitialized = false;
      FTSDK.pendingUIFeatureInit = FTSDK.rumConfig ? FTSDK.requiresUIFeaturesInternal(FTSDK.rumConfig) : false;
      FTSDK.uiFeatureInitRetryCount = 0;

      // Clean up action tracker (releases UIContext and UIObserver references)
      getFTSDKRuntime().destroyActionTracker();
      FTInnerLogger.d(TAG, "Action tracker destroyed and references released");
      // Clean up navigation tracker state
      try {
        getFTSDKRuntime().destroyNavigationTracker();
      } catch (_) {}

      // Stop monitoring and clean up ANR detector
      if (FTSDK.anrDetectManager) {
        FTSDK.anrDetectManager.shutdown();
        FTInnerLogger.d(TAG, "ANR detect manager stopped");
      }

      FTInnerLogger.i(TAG, "UI features cleaned up successfully, all UIContext references released");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to cleanup UI features: ${error}`);
    }
  }

  protected static tryInitializeUIFeaturesInternal(): void {
    if (!FTSDK.pendingUIFeatureInit) {
      return;
    }

    if (FTSDK.uiFeaturesInitialized) {
      FTSDK.pendingUIFeatureInit = false;
      return;
    }

    if (!FTSDK.rumConfig) {
      FTInnerLogger.d(TAG, "RUM config not available yet, postpone UI feature initialization");
      return;
    }

    const uiContext = getFTSDKRuntime().getUIContext();
    if (!uiContext) {
      if (FTSDK.uiFeatureInitRetryCount >= FTSDK.UI_FEATURE_INIT_MAX_RETRY) {
        FTInnerLogger.w(TAG, "UIContext is still unavailable after retries, skip automatic UI feature initialization");
        return;
      }

      FTSDK.uiFeatureInitRetryCount++;
      FTInnerLogger.d(TAG, `UIContext not ready, retry automatic UI feature initialization (${FTSDK.uiFeatureInitRetryCount}/${FTSDK.UI_FEATURE_INIT_MAX_RETRY})`);
      setTimeout(() => {
        FTSDK.tryInitializeUIFeaturesInternal();
      }, FTSDK.UI_FEATURE_INIT_RETRY_DELAY_MS);
      return;
    }

    FTSDK.initializeUIFeatures(uiContext);
  }


  /**
   * Clear unreported cached data
   * Deletes all data from database (sync_data_flat, rum_view, rum_action tables)
   * Aligned with Android: FTSdk.clearAllData()
   */
  static async clearAllData(): Promise<void> {
    try {
      if (!FTSDK.ftSdk) {
        FTInnerLogger.w(TAG, "SDK not initialized, cannot clear data");
        return;
      }

      const context = FTRUMInnerManager.getInstance().getContext();
      if (!context) {
        FTInnerLogger.w(TAG, "Context not available, cannot clear data");
        return;
      }

      await FTDBManager.getInstance(context).delete();
      FTDBCachePolicy.getInstance().resetCounts();
      FTInnerLogger.d(TAG, "clearAllData completed");
    } catch (error) {
      FTInnerLogger.e(TAG, `clearAllData failed: ${error}`);
    }
  }

  /**
   * Actively sync data
   * Triggers immediate data synchronization to server
   * Aligned with Android: FTSdk.flushSyncData()
   */
  static flushSyncData(): void {
    try {
      if (!FTSDK.ftSdk) {
        FTInnerLogger.w(TAG, "SDK not initialized, cannot flush sync data");
        return;
      }

      SyncTaskManager.getInstance().executePoll(false);  // Don't wait, execute immediately (aligned with Android SDK)
      FTInnerLogger.d(TAG, "flushSyncData triggered");
    } catch (error) {
      FTInnerLogger.e(TAG, `flushSyncData failed: ${error}`);
    }
  }

  /**
   * Check if view tracking is enabled
   * Returns true if RUM is enabled and view tracking is enabled
   * Aligned with Android: FTRUMConfigManager.isRumEnable() && config.isEnableTraceUserView()
   */
  static isViewTrackingEnabled(): boolean {
    if (!FTSDK.rumConfig) {
      return false;
    }
    const rumAppId = FTSDK.rumConfig.getRumAppId();
    return rumAppId.length > 0 && FTSDK.rumConfig.isEnableTraceUserView();
  }
}
