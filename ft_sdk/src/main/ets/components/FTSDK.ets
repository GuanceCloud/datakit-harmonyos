import {
  clearRuntimeUploadEndpointInternal,
  FTLoggerConfig,
  FTRUMConfig,
  FTSDKConfig,
  FTTraceConfig,
  LogGlobalContextDictionary,
  LogGlobalContextValue,
  setRuntimeDatakitUrlInternal,
  setRuntimeDatawayUrlInternal
} from "./Configs";
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
import { FTInnerLogger, FTLogger } from "./log/FTLogger";
import { FTInnerLogFileManager } from "./log/FTInnerLogFileManager";
import { UserDataManager } from "./rum/UserDataManager";
import { FTNetworkListener } from "./utils/FTNetworkListener";
import { SyncTaskManager } from "./SyncTaskManager";
import { FTDBCachePolicy } from "./db/FTDBCachePolicy";
import { FTDBManager } from "./db/FTDBManager";
import { FTDBSpoolManager } from "./db/FTDBSpoolManager";
import { FTRUMConfigManager } from "./rum/FTRUMConfigManager";
import { FTMonitorManager } from "./rum/FTMonitorManager";
import { DeviceUtils } from "./utils/DeviceUtils";
import { DeviceUUIDManager } from "./utils/DeviceUUIDManager";
import { AppUtils } from "./utils/AppUtils";
import { ApplicationUUIDGenerator } from "./utils/ApplicationUUIDGenerator";
import { FTAbilityLifecycleListener } from "./monitor/FTAbilityLifecycleListener";
import { FTAppLaunchTracker } from "./monitor/FTAppLaunchTracker";
import { FTAppStartCounter } from "./monitor/FTAppStartCounter";
import { FTUIBlockManager } from "./monitor/FTUIBlockManager";
import { Utils } from "./utils/Utils";
import { FTRemoteConfigManager } from './remote/FTRemoteConfigManager';
import { FTRemoteDataFilterManager } from './remote/FTRemoteDataFilterManager';
import { RemoteConfigBean } from './remote/RemoteConfigBean';
import { createRemoteConfigStorage } from './remote/RemoteConfigStorage';
import { FTRemoteConfigFetchResult } from './remote/RemoteConfigTypes';

const TAG = "FTSDK"

interface FTApplicationContextProvider {
  getApplicationContext(): Object;
}

interface FTRunningProcessInformation {
  state: number;
}

interface FTApplicationContextWithProcessInformation {
  getRunningProcessInformation(): Promise<Array<FTRunningProcessInformation>>;
}

// appManager.ProcessState numeric values are stable platform constants. Keep
// this local rather than importing appManager or registering its privileged
// RUNNING_STATE_OBSERVER interface.
const PROCESS_STATE_FOREGROUND = 1;
const PROCESS_STATE_ACTIVE = 2;
const PROCESS_STATE_BACKGROUND = 3;

export class FTSDK {
  private static ftSdk: FTSDK | null;
  private static anrDetectManager: FTSDKAnrManager | null = null;
  private static rumConfig: FTRUMConfig | null = null;
  private static uiFeaturesInitialized: boolean = false;
  private static pendingUIFeatureInit: boolean = false;
  private static uiFeatureInitRetryCount: number = 0;
  private static readonly UI_FEATURE_INIT_MAX_RETRY: number = 5;
  private static readonly UI_FEATURE_INIT_RETRY_DELAY_MS: number = 100;
  private static remoteConfigManager: FTRemoteConfigManager | null = null;
  private static remoteDataFilterManager: FTRemoteDataFilterManager | null = null;
  private static pendingRemoteConfigAppId: string | null = null;
  private static launchInitialVisibilityCaptureStarted: boolean = false;
  private static launchInitialLifecycleRoundOpen: boolean = false;
  private static launchInitialLifecycleBarrierScheduled: boolean = false;
  private static launchInitialLifecycleGeneration: number = 0;

  /**
   * Get current RUM config
   */
  public static getRumConfig(): FTRUMConfig | null {
    return FTSDK.rumConfig;
  }

  /**
   * Optionally inject the earliest application T0 captured by the host app.
   * The value must use systemDateTime.getUptime(TimeType.STARTUP, true).
   */
  public static setAppLaunchStartTime(uptimeNs: number): void {
    FTAppLaunchTracker.getInstance().setAppStartTime(uptimeNs);
  }

  /** T1 hook: call from AbilityStage.onCreate(). */
  public static recordAppApplicationInit(context?: Object): void {
    const tracker = FTAppLaunchTracker.getInstance();
    const firstApplicationInit = tracker.getSnapshot().applicationInitUptimeNs === 0;
    tracker.recordApplicationInit();
    FTSDK.registerAppLaunchStateListener(context);
    FTSDK.captureInitialAppVisibility(context);
    if (!firstApplicationInit) {
      return;
    }
    FTSDK.launchInitialLifecycleRoundOpen = true;
    FTSDK.launchInitialLifecycleGeneration++;
    FTSDK.scheduleInitialLifecycleBarrier();
  }

  /** T2 hook: call at the first UIAbility.onCreate() entry. */
  public static recordAppFirstUIAbilityCreate(): void {
    FTSDK.recordInitialLifecycleSignal('UIAbility.onCreate');
    FTAppLaunchTracker.getInstance().recordFirstUIAbilityCreated();
  }

  /**
   * T3 hook used by ft_sdk_ext after API 22 reports firstDrawFrame=true.
   * The extension deliberately reads the same STARTUP uptime clock at callback
   * arrival until device validation proves vsyncTimestamp has this same origin.
   */
  public static recordAppFirstFrame(uptimeNs?: number): void {
    FTAppLaunchTracker.getInstance().recordFirstFrame(uptimeNs);
  }

  /** Internal lifecycle bridge for application foreground/background state. */
  public static recordAppLaunchApplicationForeground(): void {
    FTSDK.recordInitialLifecycleSignal('application foreground');
    FTAppLaunchTracker.getInstance().recordApplicationForeground();
  }

  /** Internal lifecycle bridge for application foreground/background state. */
  public static recordAppLaunchApplicationBackground(): void {
    FTSDK.recordInitialLifecycleSignal('application background');
    FTAppLaunchTracker.getInstance().recordApplicationBackground();
  }

  /** Internal lifecycle bridge for WindowStage SHOWN/ACTIVE. */
  public static recordAppLaunchWindowForeground(): void {
    FTSDK.recordInitialLifecycleSignal('WindowStage shown/active');
    FTAppLaunchTracker.getInstance().recordWindowForeground();
  }

  protected static resetInternalState(): void {
    FTUIBlockManager.getInstance().release();
    const config = FTSDK.getInstalledConfig();
    if (config !== null) {
      clearRuntimeUploadEndpointInternal(config);
    }
    if (FTSDK.remoteConfigManager !== null) {
      FTSDK.remoteConfigManager.close();
      FTSDK.remoteConfigManager = null;
    }
    if (FTSDK.remoteDataFilterManager !== null) {
      FTSDK.remoteDataFilterManager.close();
      FTSDK.remoteDataFilterManager = null;
    }
    FTSDK.pendingRemoteConfigAppId = null;
    FTSDK.launchInitialVisibilityCaptureStarted = false;
    FTSDK.launchInitialLifecycleRoundOpen = false;
    FTSDK.launchInitialLifecycleBarrierScheduled = false;
    FTSDK.launchInitialLifecycleGeneration = 0;
    FTInnerLogFileManager.getInstance().shutdown(false);
    FTInnerLogger.setCrashLogCollectionEnabled(false);
    FTLogger.resetBatchStateInternal();
    FTSDK.ftSdk = null;
    FTSDK.anrDetectManager = null;
    FTSDK.rumConfig = null;
    FTSDK.uiFeaturesInitialized = false;
    FTSDK.pendingUIFeatureInit = false;
    FTSDK.uiFeatureInitRetryCount = 0;
    FTSDK.autoActionTrackingEnabled = true;
    FTSDK.cachedPACKAGE_UUID = null;
  }

  private static registerAppLaunchStateListener(context?: Object): void {
    if (!context) {
      return;
    }
    try {
      const provider = context as FTApplicationContextProvider;
      if (typeof provider.getApplicationContext !== 'function') {
        return;
      }
      const applicationContext = provider.getApplicationContext();
      FTAbilityLifecycleListener.getInstance().registerApplicationStateListener(applicationContext);
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to register early application-state listener: ${String(error)}`);
    }
  }

  /**
   * Samples current process visibility once at the earliest app entry point.
   * applicationStateChange only supplies subsequent transitions and therefore
   * cannot replace this snapshot.
   */
  private static captureInitialAppVisibility(context?: Object): void {
    if (FTSDK.launchInitialVisibilityCaptureStarted || !context ||
      FTAppLaunchTracker.getInstance().getSnapshot().initialVisibility !== 'unknown') {
      return;
    }
    FTSDK.launchInitialVisibilityCaptureStarted = true;
    try {
      const provider = context as FTApplicationContextProvider;
      if (typeof provider.getApplicationContext !== 'function') {
        FTInnerLogger.w(TAG, 'Initial application visibility unavailable: no ApplicationContext provider');
        FTAppLaunchTracker.getInstance().recordInitialVisibility('unknown');
        FTSDK.launchInitialVisibilityCaptureStarted = false;
        return;
      }
      const applicationContext = provider.getApplicationContext() as FTApplicationContextWithProcessInformation;
      if (typeof applicationContext.getRunningProcessInformation !== 'function') {
        FTInnerLogger.w(TAG, 'Initial application visibility unavailable: process-information API is absent');
        FTAppLaunchTracker.getInstance().recordInitialVisibility('unknown');
        FTSDK.launchInitialVisibilityCaptureStarted = false;
        return;
      }
      applicationContext.getRunningProcessInformation()
        .then((processes: Array<FTRunningProcessInformation>): void => {
          const visibility = FTSDK.resolveInitialVisibility(processes);
          FTAppLaunchTracker.getInstance().recordInitialVisibility(visibility);
          FTSDK.launchInitialVisibilityCaptureStarted = false;
        })
        .catch((error: Error): void => {
          FTInnerLogger.w(TAG, `Initial application visibility query failed: ${String(error)}`);
          FTAppLaunchTracker.getInstance().recordInitialVisibility('unknown');
          FTSDK.launchInitialVisibilityCaptureStarted = false;
        });
    } catch (error) {
      FTInnerLogger.w(TAG, `Initial application visibility query failed: ${String(error)}`);
      FTAppLaunchTracker.getInstance().recordInitialVisibility('unknown');
      FTSDK.launchInitialVisibilityCaptureStarted = false;
    }
  }

  private static resolveInitialVisibility(processes: Array<FTRunningProcessInformation>): 'foreground' | 'background' | 'unknown' {
    for (let index = 0; index < processes.length; index++) {
      const state = processes[index].state;
      if (state === PROCESS_STATE_FOREGROUND || state === PROCESS_STATE_ACTIVE) {
        FTInnerLogger.d(TAG, `Initial application visibility snapshot=foreground, processState=${state}`);
        return 'foreground';
      }
    }
    for (let index = 0; index < processes.length; index++) {
      if (processes[index].state === PROCESS_STATE_BACKGROUND) {
        FTInnerLogger.d(TAG, `Initial application visibility snapshot=background, processState=${PROCESS_STATE_BACKGROUND}`);
        return 'background';
      }
    }
    FTInnerLogger.w(TAG, 'Initial application visibility snapshot is indeterminate');
    return 'unknown';
  }

  /**
   * Resets a two-turn quiescence gate whenever an initial lifecycle signal is
   * observed. This is intentionally stronger than the previous one-shot
   * setTimeout(0): a UIAbility/Window callback queued after AbilityStage gets
   * two event-loop turns to arrive before a no-UI launch is settled.
   */
  private static recordInitialLifecycleSignal(source: string): void {
    if (!FTSDK.launchInitialLifecycleRoundOpen) {
      return;
    }
    FTSDK.launchInitialLifecycleGeneration++;
    FTInnerLogger.d(TAG, `Initial lifecycle signal received: ${source}, generation=${FTSDK.launchInitialLifecycleGeneration}`);
    FTSDK.scheduleInitialLifecycleBarrier();
  }

  private static scheduleInitialLifecycleBarrier(): void {
    if (!FTSDK.launchInitialLifecycleRoundOpen || FTSDK.launchInitialLifecycleBarrierScheduled) {
      return;
    }
    FTSDK.launchInitialLifecycleBarrierScheduled = true;
    const firstTurnGeneration = FTSDK.launchInitialLifecycleGeneration;
    setTimeout((): void => {
      if (!FTSDK.launchInitialLifecycleRoundOpen) {
        FTSDK.launchInitialLifecycleBarrierScheduled = false;
        return;
      }
      if (firstTurnGeneration !== FTSDK.launchInitialLifecycleGeneration) {
        FTSDK.launchInitialLifecycleBarrierScheduled = false;
        FTSDK.scheduleInitialLifecycleBarrier();
        return;
      }
      const secondTurnGeneration = FTSDK.launchInitialLifecycleGeneration;
      setTimeout((): void => {
        FTSDK.launchInitialLifecycleBarrierScheduled = false;
        if (!FTSDK.launchInitialLifecycleRoundOpen) {
          return;
        }
        if (secondTurnGeneration !== FTSDK.launchInitialLifecycleGeneration) {
          FTSDK.scheduleInitialLifecycleBarrier();
          return;
        }
        FTSDK.launchInitialLifecycleRoundOpen = false;
        FTAppLaunchTracker.getInstance().completeInitialLifecycleRound();
      }, 0);
    }, 0);
  }

  protected static requiresUIFeaturesInternal(rumConfig: FTRUMConfig): boolean {
    return rumConfig.isEnableTraceUserAction() ||
      rumConfig.isEnableTraceUserView() ||
      rumConfig.isEnableTrackAppCrash() ||
      rumConfig.isEnableTrackAppANR();
  }

  protected static requiresLifecycleListenerInternal(rumConfig: FTRUMConfig): boolean {
    return FTSDK.requiresUIFeaturesInternal(rumConfig) ||
      rumConfig.isEnableTrackAppUIBlock() ||
      (FTSDK.ftSdk !== null && FTSDK.ftSdk.ftSDKConfig !== null && FTSDK.ftSdk.ftSDKConfig.isRemoteConfiguration());
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
    FTInnerLogger.setSDKLogLevel(config.getSdkLogLevel());
    FTSDK.logServerUrl(config);

    // Get context from Utils (unified context management)
    const context = getFTSDKRuntime().getAbilityContext();

    // Android applies persisted remote configuration before the SDK's dependent
    // managers are initialized. Preferences has a synchronous HarmonyOS API,
    // which lets us preserve that startup ordering without changing FTSDK.install.
    if (config.isRemoteConfiguration()) {
      const storage = createRemoteConfigStorage(context);
      const manager = new FTRemoteConfigManager(
        config,
        config.getRemoteConfigMiniUpdateInterval(),
        storage,
        config.getRemoteConfigFetchResult()
      );
      manager.setConfigAppliedListener((bean: RemoteConfigBean) => {
        FTSDK.applyRemoteConfigHotUpdate(bean);
      });
      manager.initFromLocalCache();
      manager.mergeSDKConfigFromCache(config);
      FTSDK.remoteConfigManager = manager;
    }

    if (context && config.isEnableInnerLogFile()) {
      const innerLogFileConfig = config.getInnerLogFileConfig();
      FTInnerLogFileManager.getInstance().init(
        context,
        innerLogFileConfig.singleFileMaxSize,
        innerLogFileConfig.totalFileMaxSize,
        innerLogFileConfig.flushBatchSize,
        innerLogFileConfig.flushIntervalMs
      );
    } else {
      FTInnerLogFileManager.getInstance().shutdown(false);
    }

    // Start network monitoring
    // Monitor network state changes and update network type cache in real time
    FTNetworkListener.getInstance().monitor();

    // Initialize sync task manager
    if (context) {
      FTInnerLogger.d(TAG, " Initializing SyncTaskManager...");
      getFTSDKRuntime().initSyncTaskManager(config, context);
      const spoolManager = FTDBSpoolManager.getInstance();
      spoolManager.init(context);
      spoolManager.replay(context, "sdk.init").catch((error: Error) => {
        FTInnerLogger.e(TAG, `DB spool replay on init failed: ${error.message}`);
      });
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
      this.refreshRandomDeviceUUIDContext(config);
      FTSDK.initRemoteDataFilters(config);
    } else {
      FTInnerLogger.w(TAG, " Context is null, skipping FTTrackInner and FTRUMInnerManager initialization");
    }

    // Print debug log
    FTInnerLogger.d(TAG, "FTSDK.initFTConfig complete");
  }

  static installLogConfig(logConfig: FTLoggerConfig): void {
    try {
      if (FTSDK.ftSdk && FTSDK.ftSdk.ftSDKConfig) {
        logConfig.setServiceName(FTSDK.ftSdk.ftSDKConfig.getServiceName());
        FTSDK.remoteConfigManager?.mergeLogConfigFromCache(logConfig);
      }
      // Initialize TrackLogManager
      TrackLogManager.getInstance().setLogConfig(logConfig);
      FTDBCachePolicy.getInstance().updateLogCacheLimitCount(logConfig.getLogCacheLimitCount());
      FTDBCachePolicy.getInstance().updateLogCacheDiscardStrategy(logConfig.getLogCacheDiscardStrategy());

      // Initialize FTTrackInner log configuration
      if (FTSDK.ftSdk) {
        FTTrackInner.getInstance().initLogConfig(logConfig);
        FTInnerLogger.d(TAG,
          `installLogConfig completed: serviceName=${logConfig.getServiceName()}, samplingRate=${logConfig.getSamplingRate()}, ` +
          `enableCustomLog=${logConfig.isEnableCustomLog()}, enableLinkRumData=${logConfig.isEnableLinkRumData()}, ` +
          `enableConsoleLog=${logConfig.isEnableConsoleLog()}, printCustomLogToConsole=${logConfig.isPrintCustomLogToConsole()}, ` +
          `logLevelFilters=${logConfig.getLogLevelFilters().join('|')}, logCacheLimitCount=${logConfig.getLogCacheLimitCount()}, ` +
          `logCacheDiscardStrategy=${logConfig.getLogCacheDiscardStrategy()}`);
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
        FTSDK.remoteConfigManager?.mergeTraceConfigFromCache(traceConfig);
      }

      // 2. Initialize Trace configuration manager
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      FTInnerLogger.d(TAG,
        `installTraceConfig completed: serviceName=${traceConfig.getServiceName()}, samplingRate=${traceConfig.getSamplingRate()}, ` +
        `traceType=${traceConfig.getTraceType()}, enableAutoTrace=${traceConfig.isEnableAutoTrace()}, ` +
        `enableLinkRUMData=${traceConfig.isEnableLinkRUMData()}, enableWebTrace=${traceConfig.isEnableWebTrace()}, ` +
        `customTraceHeaderHandler=${traceConfig.getTraceHeaderHandler() !== null}`);

    } catch (error) {
      FTInnerLogger.e(TAG, `installTraceConfig failed: ${error}`);
    }
  }

  static installRUMConfig(rumConfig: FTRUMConfig): void {
    if (FTSDK.ftSdk && FTSDK.ftSdk.ftSDKConfig) {
      rumConfig.setServiceName(FTSDK.ftSdk.ftSDKConfig.getServiceName());
      FTSDK.remoteConfigManager?.mergeRUMConfigFromCache(rumConfig);
    }
    // Save rumConfig reference for later use (e.g., ActionTracker initialization)
    FTSDK.rumConfig = rumConfig;
    FTInnerLogger.setCrashLogCollectionEnabled(
      rumConfig.getRumAppId().length > 0 && rumConfig.isEnableTrackAppCrash()
    );
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

    // Initialize RUM config in FTTrackInner (aligned with Android: FTRUMConfigManager.initWithConfig -> FTTrackInner.initRUMConfig)
    // This initializes rumStaticFields (session_sample_rate, session_on_error_sample_rate) in SyncDataHelper
    if (FTSDK.ftSdk) {
      FTTrackInner.getInstance().initRUMConfig(rumConfig);
    } else {
      FTInnerLogger.e(TAG, `installRUMConfig failed: FTSDK.install not call`);
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

    // RUM readiness never completes a cold launch. The launch state machine
    // caches T0-T3 until it can report exactly once after both prerequisites
    // (RUM ready and a valid terminal boundary) are available.
    FTAppLaunchTracker.getInstance().markRumReady(rumConfig.isEnableTraceUserAction());
    FTAppStartCounter.getInstance().setInited(true);

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
    } else {
      FTUIBlockManager.getInstance().release();
    }

    if (FTSDK.pendingUIFeatureInit) {
      getFTSDKRuntime().setMainWindow();
      FTSDK.tryInitializeUIFeaturesInternal();
    }

    FTInnerLogger.d(TAG,
      `installRUMConfig completed: rumAppId=${rumConfig.getRumAppId()}, samplingRate=${rumConfig.getSamplingRate()}, ` +
      `sessionErrorSampleRate=${rumConfig.getSessionErrorSampleRate()}, enableTraceUserView=${rumConfig.isEnableTraceUserView()}, ` +
      `enableTraceUserAction=${rumConfig.isEnableTraceUserAction()}, enableTraceUserResource=${rumConfig.isEnableTraceUserResource()}, ` +
      `enableTraceWebView=${rumConfig.isEnableTraceWebView()}, enableTrackAppCrash=${rumConfig.isEnableTrackAppCrash()}, ` +
      `enableTrackAppANR=${rumConfig.isEnableTrackAppANR()}, enableTrackAppUIBlock=${rumConfig.isEnableTrackAppUIBlock()}, ` +
      `rumCacheLimitCount=${rumConfig.getRumCacheLimitCount()}, rumCacheDiscardStrategy=${rumConfig.getRumCacheDiscardStrategy()}`);

    FTSDK.startRemoteConfigIfPossible(rumConfig.getRumAppId());
  }

  private static logServerUrl(config: FTSDKConfig): void {
    if (config.getDatakitUrl().length > 0) {
      FTInnerLogger.d(TAG, `serverUrl ==>\nDatakit Url:${config.getDatakitUrl()}`);
      return;
    }

    FTInnerLogger.d(TAG,
      `serverUrl ==>\nDataway Url:${config.getDatawayUrl()},clientToken:${FTSDK.maskHalfCharacter(config.getClientToken())}`);
  }

  private static maskHalfCharacter(value: string): string {
    let maskedValue = '';
    for (let index = 0; index < value.length; index++) {
      maskedValue += index > value.length / 2 ? value.charAt(index) : '*';
    }
    return maskedValue;
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
    FTUIBlockManager.getInstance().release();
    FTInnerLogger.setCrashLogCollectionEnabled(false);
    if (FTSDK.remoteConfigManager !== null) {
      FTSDK.remoteConfigManager.close();
      FTSDK.remoteConfigManager = null;
    }
    if (FTSDK.remoteDataFilterManager !== null) {
      FTSDK.remoteDataFilterManager.close();
      FTSDK.remoteDataFilterManager = null;
    }
    FTSDK.pendingRemoteConfigAppId = null;
    // Unregister UIAbility lifecycle listener
    try {
      FTAbilityLifecycleListener.getInstance().unregister();
      FTInnerLogger.d(TAG, "UIAbility lifecycle listener unregistered");
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to unregister UIAbility lifecycle listener: ${String(error)}`);
    }

    // Release RUM manager state to avoid timers and context references surviving SDK shutdown.
    FTRUMInnerManager.shutdownInternal();
    FTLogger.resetBatchStateInternal();

    // Release network listener (similar to Android)
    FTNetworkListener.release();
    FTInnerLogFileManager.getInstance().shutdown(true);
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

  /**
   * Privacy-mode UUID is restored asynchronously. Refresh the dynamic tag once
   * it is available so data created after restoration uses the persisted value.
   */
  private refreshRandomDeviceUUIDContext(config: FTSDKConfig): void {
    if (config.isAccessODIDEnabled()) {
      return;
    }
    DeviceUUIDManager.getInstance().waitForPreferencesReady().then(() => {
      const deviceUUID = DeviceUUIDManager.getInstance().getDeviceUUID(false);
      config.getGlobalContext().set(Constants.KEY_DEVICE_UUID, new String(deviceUUID));
      FTTrackInner.getInstance().appendGlobalContextKeyValue(Constants.KEY_DEVICE_UUID, deviceUUID);
    }).catch((error: Error) => {
      FTInnerLogger.w(TAG, `Failed to refresh random device UUID context: ${error.message}`);
    });
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
    FTSDK.recordAppLaunchWindowForeground();
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
      await FTDBSpoolManager.getInstance().clear();
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

      FTInnerLogger.d(TAG, "flushSyncData requested");
      FTTrackInner.getInstance().flushPendingWorkerDataBeforeUpload().then(() => {
        FTInnerLogger.d(TAG, "flushSyncData worker queues drained, scheduling sync poll");
        SyncTaskManager.getInstance().executePoll(false);  // Don't wait, execute immediately (aligned with Android SDK)
      }).catch((error: Error) => {
        FTInnerLogger.e(TAG, `flushSyncData worker queue drain failed, scheduling sync poll: ${error.message}`);
        SyncTaskManager.getInstance().executePoll(false);
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `flushSyncData failed: ${error}`);
    }
  }

  /**
   * Enable or disable automatic upload of cached data after SDK initialization.
   * Manual calls to {@link flushSyncData} remain available while auto sync is disabled.
   * Aligned with Android: FTSdk.setAutoSync(boolean).
   */
  static setAutoSync(autoSync: boolean): void {
    try {
      if (!FTSDK.ftSdk || !FTSDK.ftSdk.ftSDKConfig) {
        FTInnerLogger.w(TAG, 'SDK not initialized, cannot set auto sync');
        return;
      }

      FTSDK.ftSdk.ftSDKConfig.setAutoSync(autoSync);
      SyncTaskManager.getInstance().setAutoSync(autoSync);
      FTInnerLogger.d(TAG, `setAutoSync completed: enabled=${autoSync}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `setAutoSync failed: ${error}`);
    }
  }

  /** Configure a DataKit endpoint after SDK installation and resume auto upload. */
  static setDatakitUrl(datakitUrl: string): void {
    const config = FTSDK.getInstalledConfig();
    if (config === null) {
      FTInnerLogger.w(TAG, 'SDK not initialized, cannot set DataKit URL');
      return;
    }
    setRuntimeDatakitUrlInternal(config, datakitUrl);
    FTSDK.logServerUrl(config);
    FTSDK.resumeUploadAfterEndpointUpdate();
    FTSDK.remoteConfigManager?.refreshForEndpointChange(FTSDK.isUploadEndpointAvailable(config));
    FTSDK.remoteDataFilterManager?.refreshForEndpointChange();
    FTSDK.triggerPendingRemoteConfigInit();
  }

  /** Configure a Dataway endpoint and token after SDK installation and resume auto upload. */
  static setDatawayUrl(datawayUrl: string, clientToken: string): void {
    const config = FTSDK.getInstalledConfig();
    if (config === null) {
      FTInnerLogger.w(TAG, 'SDK not initialized, cannot set Dataway URL');
      return;
    }
    setRuntimeDatawayUrlInternal(config, datawayUrl, clientToken);
    FTSDK.logServerUrl(config);
    FTSDK.resumeUploadAfterEndpointUpdate();
    FTSDK.remoteConfigManager?.refreshForEndpointChange(FTSDK.isUploadEndpointAvailable(config));
    FTSDK.remoteDataFilterManager?.refreshForEndpointChange();
    FTSDK.triggerPendingRemoteConfigInit();
  }

  /** Dynamically switch between a system device identifier and HarmonyOS privacy UUID. */
  static setEnableAccessDeviceID(enableAccessDeviceID: boolean): void {
    const config = FTSDK.getInstalledConfig();
    if (config === null) {
      FTInnerLogger.w(TAG, 'SDK not initialized, cannot update device ID access');
      return;
    }
    config.setEnableAccessDeviceID(enableAccessDeviceID);
    FTSDK.updateDeviceUUIDContext(config);
  }

  /** Apply only the Android-supported live remote-configuration fields. */
  private static applyRemoteConfigHotUpdate(bean: RemoteConfigBean): void {
    const sdk = FTSDK.ftSdk;
    const baseConfig = sdk === null ? null : sdk.ftSDKConfig;
    if (baseConfig === null) {
      return;
    }
    if (bean.getAutoSync() !== null) {
      baseConfig.setAutoSync(bean.getAutoSync()!);
    }
    if (bean.getCompressIntakeRequests() !== null) {
      baseConfig.setCompressIntakeRequests(bean.getCompressIntakeRequests()!);
    }
    if (bean.getSyncPageSize() !== null) {
      baseConfig.setCustomSyncPageSize(bean.getSyncPageSize()!);
    }
    if (bean.getSyncSleepTime() !== null) {
      baseConfig.setSyncSleepTime(bean.getSyncSleepTime()!);
    }
    SyncTaskManager.getInstance().hotUpdate(bean);

    const logConfig = TrackLogManager.getInstance().getLogConfig();
    if (logConfig !== null) {
      if (bean.getLogLevelFilters() !== null) {
        logConfig.setLogLevelFilters(bean.getLogLevelFilters()!);
      }
      if (bean.getLogEnableCustomLog() !== null) {
        logConfig.setEnableCustomLog(bean.getLogEnableCustomLog()!);
      }
      if (bean.getLogEnableConsoleLog() !== null) {
        logConfig.setEnableConsoleLog(bean.getLogEnableConsoleLog()!);
      }
      if (bean.getLogSampleRate() !== null) {
        logConfig.setSamplingRate(bean.getLogSampleRate()!);
      }
      FTTrackInner.getInstance().initLogConfig(logConfig);
    }

    const traceConfig = FTTraceConfigManager.getInstance().getConfig();
    if (traceConfig !== null && bean.getTraceSampleRate() !== null) {
      traceConfig.setSamplingRate(bean.getTraceSampleRate()!);
    }

    const rumConfig = FTRUMConfigManager.getInstance().getConfig();
    if (rumConfig !== null && rumConfig.getRumAppId().length > 0 &&
      (bean.getRumSampleRate() !== null || bean.getRumSessionOnErrorSampleRate() !== null)) {
      if (bean.getRumSampleRate() !== null) {
        rumConfig.setSamplingRate(bean.getRumSampleRate()!);
      }
      if (bean.getRumSessionOnErrorSampleRate() !== null) {
        rumConfig.setSessionErrorSampleRate(bean.getRumSessionOnErrorSampleRate()!);
      }
      FTRUMInnerManager.getInstance().setSamplingRates(
        rumConfig.getSamplingRate(),
        rumConfig.getSessionErrorSampleRate()
      );
      FTTrackInner.getInstance().initRUMConfig(rumConfig);
    }
  }

  private static getInstalledConfig(): FTSDKConfig | null {
    return FTSDK.ftSdk === null ? null : FTSDK.ftSdk.ftSDKConfig;
  }

  private static resumeUploadAfterEndpointUpdate(): void {
    SyncTaskManager.getInstance().executeSyncPoll();
  }

  private static initRemoteDataFilters(config: FTSDKConfig): void {
    if (!config.isEnableDataFilter()) {
      return;
    }
    const manager = new FTRemoteDataFilterManager(
      config,
      () => FTSDK.isUploadEndpointAvailable(config),
      (filters: Map<string, Array<string>>) => {
        FTTrackInner.getInstance().updateRemoteDataFilters(filters);
        SyncTaskManager.getInstance().updateRemoteDataFilters(filters);
      }
    );
    FTSDK.remoteDataFilterManager = manager;
    void manager.start();
  }

  private static startRemoteConfigIfPossible(appId: string): void {
    if (FTSDK.remoteConfigManager === null || appId.length === 0) {
      return;
    }
    const config = FTSDK.getInstalledConfig();
    if (config !== null && FTSDK.isUploadEndpointAvailable(config)) {
      FTSDK.pendingRemoteConfigAppId = null;
      void FTSDK.remoteConfigManager.initFromRemote(appId);
      return;
    }
    FTSDK.pendingRemoteConfigAppId = appId;
    FTInnerLogger.d(TAG, 'Remote config request deferred until an intake endpoint is configured');
  }

  private static triggerPendingRemoteConfigInit(): void {
    const appId = FTSDK.pendingRemoteConfigAppId;
    const config = FTSDK.getInstalledConfig();
    if (appId === null || config === null || !FTSDK.isUploadEndpointAvailable(config)) {
      return;
    }
    FTSDK.pendingRemoteConfigAppId = null;
    if (FTSDK.remoteConfigManager !== null) {
      void FTSDK.remoteConfigManager.initFromRemote(appId);
    }
  }

  private static isUploadEndpointAvailable(config: FTSDKConfig): boolean {
    const datakitUrl = config.getDatakitUrl().trim();
    if (FTSDK.isValidHttpUrl(datakitUrl)) {
      return true;
    }
    return FTSDK.isValidHttpUrl(config.getDatawayUrl().trim()) && config.getClientToken().trim().length > 0;
  }

  private static isValidHttpUrl(value: string): boolean {
    return /^https?:\/\/[^\s/?#]+(?:[/?#]|$)/i.test(value);
  }

  private static updateDeviceUUIDContext(config: FTSDKConfig): void {
    const deviceUUID = DeviceUUIDManager.getInstance().getDeviceUUID(config.isAccessODIDEnabled());
    config.getGlobalContext().set(Constants.KEY_DEVICE_UUID, new String(deviceUUID));
    FTTrackInner.getInstance().appendGlobalContextKeyValue(Constants.KEY_DEVICE_UUID, deviceUUID);
    if (!config.isAccessODIDEnabled()) {
      DeviceUUIDManager.getInstance().waitForPreferencesReady().then(() => {
        if (!config.isAccessODIDEnabled()) {
          const persistedUUID = DeviceUUIDManager.getInstance().getDeviceUUID(false);
          config.getGlobalContext().set(Constants.KEY_DEVICE_UUID, new String(persistedUUID));
          FTTrackInner.getInstance().appendGlobalContextKeyValue(Constants.KEY_DEVICE_UUID, persistedUUID);
        }
      }).catch((error: Error) => {
        FTInnerLogger.w(TAG, `Failed to refresh privacy device UUID: ${error.message}`);
      });
    }
  }

  /**
   * Fetch remote configuration using the interval configured on FTSDKConfig.
   * A valid RUM app id is supplied once RUM configuration is installed.
   */
  static updateRemoteConfig(): void;
  static updateRemoteConfig(intervalSeconds: number): void;
  static updateRemoteConfig(intervalSeconds: number, result: FTRemoteConfigFetchResult | null): void;
  static updateRemoteConfig(intervalSeconds?: number, result?: FTRemoteConfigFetchResult | null): void {
    const manager = FTSDK.remoteConfigManager;
    if (manager === null) {
      return;
    }
    if (intervalSeconds === undefined) {
      void manager.updateRemoteConfig();
      return;
    }
    void manager.updateRemoteConfig(intervalSeconds, result === undefined ? null : result);
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
