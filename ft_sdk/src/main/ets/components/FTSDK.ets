import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from "./Configs";
import { Constants } from "./Constants";
import { UserData } from "./rum/bean/UserData";
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import { DefaultFTSDKRuntime, FTSDKAnrManager, FTSDKRuntime } from "./FTSDKRuntime";

const TAG = "FTSDK"

export class FTSDK {
  private static ftSdk: FTSDK | null;
  private static runtime: FTSDKRuntime = new DefaultFTSDKRuntime();
  private static anrDetectManager: FTSDKAnrManager | null = null;
  private static rumConfig: FTRUMConfig | null = null;
  private static uiFeaturesInitialized: boolean = false;
  private static pendingUIFeatureInit: boolean = false;
  private static uiFeatureInitRetryCount: number = 0;
  private static readonly UI_FEATURE_INIT_MAX_RETRY: number = 5;
  private static readonly UI_FEATURE_INIT_RETRY_DELAY_MS: number = 100;

  /**
   * Get RUM config (for testing purposes)
   */
  public static getRumConfig(): FTRUMConfig | null {
    return FTSDK.rumConfig;
  }

  public static setRuntimeForTest(runtime: FTSDKRuntime): void {
    FTSDK.runtime = runtime;
  }

  public static resetRuntimeForTest(): void {
    FTSDK.runtime = new DefaultFTSDKRuntime();
  }

  public static resetStateForTest(): void {
    FTSDK.ftSdk = null;
    FTSDK.anrDetectManager = null;
    FTSDK.rumConfig = null;
    FTSDK.uiFeaturesInitialized = false;
    FTSDK.pendingUIFeatureInit = false;
    FTSDK.uiFeatureInitRetryCount = 0;
    FTSDK.autoActionTrackingEnabled = true;
    FTSDK.cachedPACKAGE_UUID = null;
  }

  public static setAnrDetectManagerForTest(manager: FTSDKAnrManager | null): void {
    FTSDK.anrDetectManager = manager;
  }

  public static setUIFeatureStateForTest(
    pendingUIFeatureInit: boolean,
    uiFeaturesInitialized: boolean,
    uiFeatureInitRetryCount: number
  ): void {
    FTSDK.pendingUIFeatureInit = pendingUIFeatureInit;
    FTSDK.uiFeaturesInitialized = uiFeaturesInitialized;
    FTSDK.uiFeatureInitRetryCount = uiFeatureInitRetryCount;
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
        const packageName: string = FTSDK.runtime.getPackageName();
        const versionName: string = FTSDK.runtime.getAppVersionName();

        //FTInnerLogger.d(TAG, `Generating PACKAGE_UUID from package: ${packageName}, version: ${versionName}`);

        // Generate deterministic UUID using ApplicationUUIDGenerator
        FTSDK.cachedPACKAGE_UUID = FTSDK.runtime.generatePackageUUID(packageName, versionName);

        //FTInnerLogger.i(TAG, ` PACKAGE_UUID generated: ${FTSDK.cachedPACKAGE_UUID}`);
      } catch (error) {
        // Fallback: use fixed seed if package info not available
        FTSDK.cachedPACKAGE_UUID = FTSDK.runtime.generateFallbackPackageUUID();
        FTSDK.runtime.logError(TAG, ` PACKAGE_UUID (fallback): ${FTSDK.cachedPACKAGE_UUID}`);
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
        FTSDK.runtime.logError(TAG, "Parameter ftSDKConfig cannot be null");
        return;
      }

      // Initialize Utils with context (required for ApplicationContext access)
      if (context && (context as common.UIAbilityContext)) {
        FTSDK.runtime.initUtils(context as common.UIAbilityContext);
        FTSDK.runtime.logDebug(TAG, "Utils initialized with UIAbilityContext");
      } else {
        FTSDK.runtime.logWarn(TAG, "Context is not UIAbilityContext, Utils.init() skipped");
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
      FTSDK.runtime.logError(TAG, `FTSDK initialization failed:\n${e.stack || e.message}`);
    }
    FTSDK.runtime.logDebug(TAG, "FTSDK.install completed");
  }

   initFTConfig(config: FTSDKConfig): void {
    // Enable/disable FTInnerLogger debug logs based on FTSDKConfig.setDebug() setting
    FTSDK.runtime.setDebugEnabled(config.isDebugMode());

    // Start network monitoring
    // Monitor network state changes and update network type cache in real time
    FTSDK.runtime.monitorNetwork();

    // Get context from Utils (unified context management)
    const context = FTSDK.runtime.getAbilityContext();

    // Initialize sync task manager
    if (context) {
      FTSDK.runtime.logDebug(TAG, " Initializing SyncTaskManager...");
      FTSDK.runtime.initSyncTaskManager(config, context);
      FTSDK.runtime.initUserDataManager(context);
      FTSDK.runtime.initDeviceUUIDManager(context);

      //  TODO device monitor
      // Initialize device monitoring utilities
      // await BatteryUtils.getInstance().init();
      // await MemoryUtils.getInstance().init();
      // await CpuUtils.getInstance().init();

    } else {
      FTSDK.runtime.logWarn(TAG, " Context is null, skipping SyncTaskManager initialization");
    }

    // Add global context (after all managers are initialized)
     this.appendGlobalContext(config);

    // Initialize base configuration
    if (context) {
      FTSDK.runtime.initTrackBaseConfig(config, context);
      FTSDK.runtime.initRumContext(context);
    } else {
      FTSDK.runtime.logWarn(TAG, " Context is null, skipping FTTrackInner and FTRUMInnerManager initialization");
    }

    // Print debug log
    FTSDK.runtime.logDebug(TAG, "FTSDK.initFTConfig complete");
  }

  static installLogConfig(logConfig: FTLoggerConfig): void {
    try {
      // Initialize TrackLogManager
      FTSDK.runtime.setTrackLogConfig(logConfig);
      FTSDK.runtime.updateLogCacheLimitCount(logConfig.getLogCacheLimitCount());

      // Initialize FTTrackInner log configuration
      if (FTSDK.ftSdk) {
        FTSDK.runtime.initTrackLogConfig(logConfig);
        FTSDK.runtime.logDebug(TAG, `installLogConfig completed: samplingRate=${logConfig.getSamplingRate()}, enableCustomLog=${logConfig.isEnableCustomLog()}`);
      }else{
        FTSDK.runtime.logError(TAG, `installLogConfig failed: FTSDK.install not call`);
      }

    } catch (error) {
      FTSDK.runtime.logError(TAG, `installLogConfig failed: ${error}`);
    }
  }

  static installTraceConfig(traceConfig: FTTraceConfig): void {
    try {
      // 1. Set service name (from base configuration)
      if (FTSDK.ftSdk && FTSDK.ftSdk.ftSDKConfig) {
        traceConfig.setServiceName(FTSDK.ftSdk.ftSDKConfig.getServiceName());
      }

      // 2. Initialize Trace configuration manager
      FTSDK.runtime.initTraceConfig(traceConfig);

      FTSDK.runtime.logDebug(TAG, `installTraceConfig completed: samplingRate=${traceConfig.getSamplingRate()}, traceType=${traceConfig.getTraceType()}, enableAutoTrace=${traceConfig.isEnableAutoTrace()}`);

    } catch (error) {
      FTSDK.runtime.logError(TAG, `installTraceConfig failed: ${error}`);
    }
  }

  static installRUMConfig(rumConfig: FTRUMConfig): void {
    // Save rumConfig reference for later use (e.g., ActionTracker initialization)
    FTSDK.rumConfig = rumConfig;
    FTSDK.updateNativePackageInfo();
    FTSDK.pendingUIFeatureInit = FTSDK.requiresUIFeatures(rumConfig);
    FTSDK.uiFeaturesInitialized = false;
    FTSDK.uiFeatureInitRetryCount = 0;

    FTSDK.initRUMGlobalContext(rumConfig);
    FTSDK.runtime.initRumConfigManager(rumConfig);
    // Initialize RUM Inner Manager with config (aligned with Android: FTRUMInnerManager.initParams)
    FTSDK.runtime.initRumParams(rumConfig);

    // Initialize RUM Global Manager with config (aligned with Android: FTRUMConfigManager.initWithConfig -> FTRUMGlobalManager.initConfig)
    FTSDK.runtime.initRumGlobalConfig(rumConfig);

    // Initialize RUM config in FTTrackInner (aligned with Android: FTRUMConfigManager.initWithConfig -> FTTrackInner.initRUMConfig)
    // This initializes rumStaticFields (session_sample_rate, session_on_error_sample_rate) in SyncDataHelper
    if (FTSDK.ftSdk) {
      FTSDK.runtime.initTrackRumConfig(rumConfig);
    } else {
      FTSDK.runtime.logError(TAG, `installLogConfig failed: FTSDK.install not call`);
    }

    // Register UIAbility lifecycle listener when any UI-bound feature is enabled.
    // This allows SDK to automatically obtain WindowStage/MainWindow/UIContext later.
    if (FTSDK.requiresLifecycleListener(rumConfig)) {
      try {
        FTSDK.runtime.registerLifecycleListener();
        FTSDK.runtime.logInfo(TAG, "UIAbility lifecycle listener registered for automatic UI feature initialization");
      } catch (error) {
        FTSDK.runtime.logWarn(TAG, `Failed to register UIAbility lifecycle listener: ${String(error)}`);
      }
    }

    // Check and handle cold start if onWindowStageCreate was called before SDK initialization
    // This happens when SDK is initialized in onWindowStageCreate, but the lifecycle callback
    // was registered after onWindowStageCreate was already called
    if (rumConfig.isEnableTraceUserAction()) {
      try {
        const appStartCounter = FTSDK.runtime.getAppStartCounter();
        if (!appStartCounter.isInited()) {
          // onWindowStageCreate was likely called before SDK initialization
          // Manually trigger cold start calculation
          const endTime = FTSDK.runtime.getCurrentNanoTime();
          appStartCounter.coldStart(endTime);
          appStartCounter.coldStartUpload();
          appStartCounter.setInited(true);
          FTSDK.runtime.logDebug(TAG, "Cold start calculated and uploaded (manual trigger after SDK init)");
        }
      } catch (error) {
        FTSDK.runtime.logWarn(TAG, `Failed to calculate cold start: ${String(error)}`);
      }
    }

    // Initialize monitor manager
    FTSDK.runtime.initMonitorConfig(rumConfig);

    // Initialize ANR detect manager
    FTSDK.anrDetectManager = FTSDK.runtime.getAnrDetectManager();

    // Initialize exception handler for crash tracking
    // Aligned with Android: FTExceptionHandler.get().initConfig(config)
    if (rumConfig.isEnableTrackAppCrash()) {
      FTSDK.runtime.initExceptionHandler(rumConfig);
      FTSDK.runtime.logDebug(TAG, "FTExceptionHandler initialized for crash tracking");
    }

    // Initialize UI block detection
    // Aligned with Android: FTUIBlockManager.get().start(config)
    if (rumConfig.isEnableTrackAppUIBlock()) {
      FTSDK.runtime.startUIBlockManager(rumConfig);
      FTSDK.runtime.logDebug(TAG, "FTUIBlockManager initialized for UI block detection");
    }

    if (FTSDK.pendingUIFeatureInit) {
      FTSDK.runtime.setMainWindow();
      FTSDK.tryInitializeUIFeatures();
    }

    FTSDK.runtime.logDebug(TAG, "installRUMConfig completed");
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
    hashMap.set(Constants.KEY_DEVICE_DEVICE_BAND, new String(FTSDK.runtime.getDeviceBrand()));
    hashMap.set(Constants.KEY_DEVICE_DEVICE_MODEL, new String(FTSDK.runtime.getDeviceModel()));
    hashMap.set(Constants.KEY_DEVICE_DEVICE_ARCH, new String(FTSDK.runtime.getDeviceArch()));
    hashMap.set(Constants.KEY_DEVICE_DISPLAY, new String(FTSDK.runtime.getDisplay()));
    hashMap.set(Constants.KEY_SERVICE, new String(config.getServiceName()));

    hashMap.set(Constants.KEY_DEVICE_OS_VERSION, new String(FTSDK.runtime.getOSVersion()));
    hashMap.set(Constants.KEY_DEVICE_OS_VERSION_MAJOR, new String(FTSDK.runtime.getOSVersionMajor()));

  }

  /**
   * Bind RUM user data with User ID only
   * Bind RUM user data by ID
   * @param id User ID
   */
  static bindRumUserDataById(id: string): void {
    const userData = new UserData(id);
    FTSDK.runtime.bindUserData(userData)

    FTSDK.runtime.logDebug(TAG, `bindRumUserData completed with ID: ${id}`);
  }

  /**
   * Bind RUM user data with UserData object
   * Bind RUM user data with UserData object and persist to preferences
   * @param userData User data object
   */
  static bindRumUserData(userData: UserData): void {
    // Persist user data to preferences
    FTSDK.runtime.bindUserData(userData);
    FTSDK.runtime.logDebug(TAG, `bindRumUserData completed: ${userData.getSummary()}`);
  }


  /**
   * Unbind RUM user data
   * Unbind RUM user data and clear from preferences
   */
  static unbindRumUserData(): void {
    // Clear from preferences
    FTSDK.runtime.unbindUserData();
    FTSDK.runtime.logDebug(TAG, "unbindRumUserData completed");
  }


  static shutDown() {
    // Unregister UIAbility lifecycle listener
    try {
      FTSDK.runtime.unregisterLifecycleListener();
      FTSDK.runtime.logDebug(TAG, "UIAbility lifecycle listener unregistered");
    } catch (error) {
      FTSDK.runtime.logWarn(TAG, `Failed to unregister UIAbility lifecycle listener: ${String(error)}`);
    }

    // Release network listener (similar to Android)
    FTSDK.runtime.releaseNetwork();
    FTSDK.runtime.logDebug(TAG, "FTSDK shut down, network listener released");
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
      FTSDK.runtime.appendTrackGlobalContext(globalContext);
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
      FTSDK.runtime.appendTrackGlobalContextKeyValue(key, value);
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
      FTSDK.runtime.appendTrackRumGlobalContext(globalContext);
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
      FTSDK.runtime.appendTrackRumGlobalContextKeyValue(key, value);
    }
  }

  /**
   * Dynamically set log global tag
   * @param globalContext Log global context map
   */
  static appendLogGlobalContext(globalContext: Map<string, string>): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendLogGlobalContext() behavior
    if (FTSDK.ftSdk) {
      FTSDK.runtime.appendTrackLogGlobalContext(globalContext);
    }
  }

  /**
   * Dynamically set log global tag
   * @param key Tag key
   * @param value Tag value
   */
  static appendLogGlobalContextKeyValue(key: string, value: string): void {
    // Ensure trackInner exists, even if called before install completes
    // Aligned with Android: FTSdk.appendLogGlobalContextKeyValue() behavior
    if (FTSDK.ftSdk) {
      FTSDK.runtime.appendTrackLogGlobalContextKeyValue(key, value);
    }
  }


  private appendGlobalContext(config: FTSDKConfig): void {
    let hashMap: Map<string, object> = config.getGlobalContext();
    // Add basic app and SDK information (using direct string keys for better compatibility)
    hashMap.set(Constants.KEY_APP_VERSION_NAME, new String(FTSDK.runtime.getAppVersionName()));
    hashMap.set(Constants.KEY_SDK_NAME, new String(Constants.SDK_NAME));
    hashMap.set(Constants.KEY_ENV, new String(config.getEnv()));

    // Add device information (using ODID - Huawei recommended)
    const deviceUUID = FTSDK.runtime.getDeviceUUID(config.isAccessODIDEnabled());
    hashMap.set(Constants.KEY_DEVICE_UUID, new String(deviceUUID));
    hashMap.set(Constants.KEY_APPLICATION_UUID, new String(FTSDK.PACKAGE_UUID));

    let pkgJson = JSON.stringify(this.getInnerPkgInfoHashMap(config));
    pkgJson = pkgJson.replace(/","/g, '","');
    hashMap.set(Constants.KEY_SDK_PACKAGE_INFO, new String(pkgJson));
    hashMap.set(Constants.KEY_SDK_VERSION, new String(FTSDK.runtime.getHarVersion()));

  }

  private static getNativeCrashVersion(): string {
    try {
      return FTSDK.runtime.getNativeCrashVersion();
    } catch (e) {
      FTSDK.runtime.logError(TAG, `not ftnativecrash include`);
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
    FTSDK.runtime.appendTrackGlobalContextKeyValue(Constants.KEY_SDK_PACKAGE_INFO, pkgJson);
  }

  private getInnerPkgInfoHashMap(config: FTSDKConfig): Record<string,string> {
    const pkgInfo: Record<string, string> = {};
    //agent
    pkgInfo[Constants.KEY_SDK_PACKAGE_AGENT] = FTSDK.runtime.getHarVersion();
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
      FTSDK.runtime.logDebug(TAG, "UI features already initialized, skipping duplicate initialization");
      return;
    }

    try {
      const rumConfig = FTSDK.rumConfig;
      // Initialize action tracker only when explicitly enabled
      if (rumConfig) {
        if (FTSDK.autoActionTrackingEnabled) {
          FTSDK.runtime.initActionTracker(uiContext, rumConfig);
          FTSDK.runtime.logDebug(TAG, "Action tracker initialized successfully");
        } else {
          FTSDK.runtime.logInfo(TAG, "Auto action tracking is disabled; skipping FTActionTracker init");
        }
        // Initialize navigation tracker (automatic view start/stop from navigation/router events)
        // Only initialize if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks)
        FTSDK.runtime.initNavigationTracker(uiContext, rumConfig);
        FTSDK.runtime.logDebug(TAG, "Navigation tracker initialized successfully");
      } else {
        FTSDK.runtime.logWarn(TAG, "RUM config not available, skipping action tracker initialization");
        return;
      }

      // Initialize ANR monitoring
      if (!FTSDK.anrDetectManager) {
        FTSDK.runtime.logError(TAG, "ANR detect manager not initialized in installRUMConfig()");
        return;
      }

      const enableANRMonitoring = rumConfig.isEnableTrackAppANR();

      if (enableANRMonitoring) {
        FTSDK.anrDetectManager.initialize();
        FTSDK.anrDetectManager.startMonitoring();
        FTSDK.runtime.logInfo(TAG, `ANR monitoring initialized: anr=${enableANRMonitoring}`);
      } else {
        FTSDK.runtime.logDebug(TAG, "ANR monitoring skipped: ANR monitoring is disabled");
      }

      FTSDK.uiFeaturesInitialized = true;
      FTSDK.pendingUIFeatureInit = false;
      FTSDK.uiFeatureInitRetryCount = 0;
      FTSDK.runtime.logInfo(TAG, "UI features (action tracker and ANR monitor) initialized successfully");
    } catch (error) {
      FTSDK.runtime.logError(TAG, `Failed to initialize UI features: ${error}`);
    }
  }

  public static onWindowStageActive(mainWindow?: window.Window): void {
    FTSDK.uiFeatureInitRetryCount = 0;
    FTSDK.runtime.setMainWindow(mainWindow);
    FTSDK.tryInitializeUIFeatures();
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
      FTSDK.pendingUIFeatureInit = FTSDK.rumConfig ? FTSDK.requiresUIFeatures(FTSDK.rumConfig) : false;
      FTSDK.uiFeatureInitRetryCount = 0;

      // Clean up action tracker (releases UIContext and UIObserver references)
      FTSDK.runtime.destroyActionTracker();
      FTSDK.runtime.logDebug(TAG, "Action tracker destroyed and references released");
      // Clean up navigation tracker state
      try {
        FTSDK.runtime.destroyNavigationTracker();
      } catch (_) {}

      // Stop monitoring and clean up ANR detector
      if (FTSDK.anrDetectManager) {
        FTSDK.anrDetectManager.shutdown();
        FTSDK.runtime.logDebug(TAG, "ANR detect manager stopped");
      }

      FTSDK.runtime.logInfo(TAG, "UI features cleaned up successfully, all UIContext references released");
    } catch (error) {
      FTSDK.runtime.logError(TAG, `Failed to cleanup UI features: ${error}`);
    }
  }

  private static tryInitializeUIFeatures(): void {
    if (!FTSDK.pendingUIFeatureInit) {
      return;
    }

    if (FTSDK.uiFeaturesInitialized) {
      FTSDK.pendingUIFeatureInit = false;
      return;
    }

    if (!FTSDK.rumConfig) {
      FTSDK.runtime.logDebug(TAG, "RUM config not available yet, postpone UI feature initialization");
      return;
    }

    const uiContext = FTSDK.runtime.getUIContext();
    if (!uiContext) {
      if (FTSDK.uiFeatureInitRetryCount >= FTSDK.UI_FEATURE_INIT_MAX_RETRY) {
        FTSDK.runtime.logWarn(TAG, "UIContext is still unavailable after retries, skip automatic UI feature initialization");
        return;
      }

      FTSDK.uiFeatureInitRetryCount++;
      FTSDK.runtime.logDebug(TAG, `UIContext not ready, retry automatic UI feature initialization (${FTSDK.uiFeatureInitRetryCount}/${FTSDK.UI_FEATURE_INIT_MAX_RETRY})`);
      FTSDK.runtime.schedule(() => {
        FTSDK.tryInitializeUIFeatures();
      }, FTSDK.UI_FEATURE_INIT_RETRY_DELAY_MS);
      return;
    }

    FTSDK.initializeUIFeatures(uiContext);
  }

  public static tryInitializeUIFeaturesForTest(): void {
    FTSDK.tryInitializeUIFeatures();
  }

  private static requiresUIFeatures(rumConfig: FTRUMConfig): boolean {
    return rumConfig.isEnableTraceUserAction() ||
      rumConfig.isEnableTraceUserView() ||
      rumConfig.isEnableTrackAppCrash() ||
      rumConfig.isEnableTrackAppANR();
  }

  public static requiresUIFeaturesForTest(rumConfig: FTRUMConfig): boolean {
    return FTSDK.requiresUIFeatures(rumConfig);
  }

  private static requiresLifecycleListener(rumConfig: FTRUMConfig): boolean {
    return FTSDK.requiresUIFeatures(rumConfig);
  }

  public static requiresLifecycleListenerForTest(rumConfig: FTRUMConfig): boolean {
    return FTSDK.requiresLifecycleListener(rumConfig);
  }


  /**
   * Clear unreported cached data
   * Deletes all data from database (sync_data_flat, rum_view, rum_action tables)
   * Aligned with Android: FTSdk.clearAllData()
   */
  static async clearAllData(): Promise<void> {
    try {
      if (!FTSDK.ftSdk) {
        FTSDK.runtime.logWarn(TAG, "SDK not initialized, cannot clear data");
        return;
      }

      const context = FTSDK.runtime.getRumContext();
      if (!context) {
        FTSDK.runtime.logWarn(TAG, "Context not available, cannot clear data");
        return;
      }

      await FTSDK.runtime.deleteAllData(context);
      FTSDK.runtime.logDebug(TAG, "clearAllData completed");
    } catch (error) {
      FTSDK.runtime.logError(TAG, `clearAllData failed: ${error}`);
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
        FTSDK.runtime.logWarn(TAG, "SDK not initialized, cannot flush sync data");
        return;
      }

      FTSDK.runtime.executeSyncPoll(false);  // Don't wait, execute immediately (aligned with Android SDK)
      FTSDK.runtime.logDebug(TAG, "flushSyncData triggered");
    } catch (error) {
      FTSDK.runtime.logError(TAG, `flushSyncData failed: ${error}`);
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
