import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { FTSDK } from '../../main/ets/components/FTSDK';
import {
  FTSDKAnrManager,
  FTSDKAppStartCounterRuntime,
  FTSDKRuntime
} from '../../main/ets/components/FTSDKRuntime';
import { UserData } from '../../main/ets/components/rum/bean/UserData';

const TEST_URL = 'http://localhost';

function createContext(): common.UIAbilityContext {
  return new Object() as common.UIAbilityContext;
}

function createUIContext(): UIContext {
  return new Object() as UIContext;
}

function mapOf(key: string, value: string): Map<string, string> {
  const map = new Map<string, string>();
  map.set(key, value);
  return map;
}

class FakeAnrManager implements FTSDKAnrManager {
  initializeCount: number = 0;
  startCount: number = 0;
  shutdownCount: number = 0;
  throwInitialize: boolean = false;

  initialize(): void {
    this.initializeCount++;
    if (this.throwInitialize) {
      throw new Error('anr init failed');
    }
  }

  startMonitoring(): void {
    this.startCount++;
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class FakeAppStartCounter implements FTSDKAppStartCounterRuntime {
  inited: boolean = false;
  isInitedCount: number = 0;
  coldStartCount: number = 0;
  uploadCount: number = 0;
  setInitedCount: number = 0;
  throwIsInited: boolean = false;

  isInited(): boolean {
    this.isInitedCount++;
    if (this.throwIsInited) {
      throw new Error('cold start failed');
    }
    return this.inited;
  }

  coldStart(_endTime: number): void {
    this.coldStartCount++;
  }

  coldStartUpload(): void {
    this.uploadCount++;
  }

  setInited(inited: boolean): void {
    this.inited = inited;
    this.setInitedCount++;
  }
}

class FakeRuntime implements FTSDKRuntime {
  debugEnabled: boolean = false;
  debugCount: number = 0;
  infoCount: number = 0;
  warnCount: number = 0;
  errorCount: number = 0;
  initUtilsCount: number = 0;
  monitorCount: number = 0;
  releaseNetworkCount: number = 0;
  abilityContext: common.UIAbilityContext | null = null;
  rumContext: Context | null = null;
  initSyncCount: number = 0;
  executeSyncCount: number = 0;
  executeSyncWait: boolean = true;
  initUserDataCount: number = 0;
  bindUserDataCount: number = 0;
  unbindUserDataCount: number = 0;
  lastUserData: UserData | null = null;
  initDeviceUuidCount: number = 0;
  deviceUuid: string = 'device-id';
  packageName: string = 'pkg';
  appVersionName: string = '1.0.0';
  packageUuid: string = 'package-uuid';
  fallbackUuid: string = 'fallback-uuid';
  currentNanoTime: number = 123456789;
  initTrackBaseCount: number = 0;
  setTrackLogConfigCount: number = 0;
  initTrackLogCount: number = 0;
  initTrackRumCount: number = 0;
  appendGlobalCount: number = 0;
  appendGlobalKeyCount: number = 0;
  appendRumCount: number = 0;
  appendRumKeyCount: number = 0;
  appendLogCount: number = 0;
  appendLogKeyCount: number = 0;
  initRumContextCount: number = 0;
  initRumParamsCount: number = 0;
  initRumGlobalCount: number = 0;
  initRumConfigManagerCount: number = 0;
  initTraceCount: number = 0;
  initMonitorCount: number = 0;
  anrManager: FakeAnrManager | null = new FakeAnrManager();
  appStartCounter: FakeAppStartCounter = new FakeAppStartCounter();
  initExceptionCount: number = 0;
  startUIBlockCount: number = 0;
  registerLifecycleCount: number = 0;
  unregisterLifecycleCount: number = 0;
  setMainWindowCount: number = 0;
  setMainWindowWithWindowCount: number = 0;
  uiContext: UIContext | null = null;
  initActionCount: number = 0;
  destroyActionCount: number = 0;
  initNavigationCount: number = 0;
  destroyNavigationCount: number = 0;
  updateLogCacheCount: number = 0;
  deleteAllDataCount: number = 0;
  harVersion: string = 'har-1.0';
  nativeCrashVersion: string = '';
  lastAppendGlobalKey: string = '';
  lastAppendGlobalValue: string = '';
  scheduleCount: number = 0;
  throwPackageName: boolean = false;
  throwInitUtils: boolean = false;
  throwMonitor: boolean = false;
  throwSetTrackLogConfig: boolean = false;
  throwInitTrace: boolean = false;
  throwRegisterLifecycle: boolean = false;
  throwUnregisterLifecycle: boolean = false;
  throwActionInit: boolean = false;
  throwActionDestroy: boolean = false;
  throwNavigationDestroy: boolean = false;
  throwDeleteAllData: boolean = false;
  throwExecuteSync: boolean = false;
  throwNativeCrashVersion: boolean = false;

  setDebugEnabled(enabled: boolean): void {
    this.debugEnabled = enabled;
  }

  logDebug(_tag: string, _message: string): void {
    this.debugCount++;
  }

  logInfo(_tag: string, _message: string): void {
    this.infoCount++;
  }

  logWarn(_tag: string, _message: string): void {
    this.warnCount++;
  }

  logError(_tag: string, _message: string): void {
    this.errorCount++;
  }

  initUtils(_context: common.UIAbilityContext): void {
    this.initUtilsCount++;
    if (this.throwInitUtils) {
      throw new Error('utils failed');
    }
  }

  monitorNetwork(): void {
    this.monitorCount++;
    if (this.throwMonitor) {
      throw new Error('monitor failed');
    }
  }

  releaseNetwork(): void {
    this.releaseNetworkCount++;
  }

  getAbilityContext(): common.UIAbilityContext | null {
    return this.abilityContext;
  }

  initSyncTaskManager(_config: FTSDKConfig, _context: Context): void {
    this.initSyncCount++;
  }

  executeSyncPoll(wait: boolean): void {
    this.executeSyncCount++;
    this.executeSyncWait = wait;
    if (this.throwExecuteSync) {
      throw new Error('sync failed');
    }
  }

  initUserDataManager(_context: Context): void {
    this.initUserDataCount++;
  }

  bindUserData(userData: UserData): void {
    this.bindUserDataCount++;
    this.lastUserData = userData;
  }

  unbindUserData(): void {
    this.unbindUserDataCount++;
  }

  initDeviceUUIDManager(_context: common.UIAbilityContext): void {
    this.initDeviceUuidCount++;
  }

  getDeviceUUID(_accessODID: boolean): string {
    return this.deviceUuid;
  }

  getPackageName(): string {
    if (this.throwPackageName) {
      throw new Error('package failed');
    }
    return this.packageName;
  }

  getAppVersionName(): string {
    return this.appVersionName;
  }

  generatePackageUUID(packageName: string, versionName: string): string {
    return `${this.packageUuid}:${packageName}:${versionName}`;
  }

  generateFallbackPackageUUID(): string {
    return this.fallbackUuid;
  }

  getCurrentNanoTime(): number {
    return this.currentNanoTime;
  }

  initTrackBaseConfig(_config: FTSDKConfig, _context: Context): void {
    this.initTrackBaseCount++;
  }

  setTrackLogConfig(_config: FTLoggerConfig): void {
    this.setTrackLogConfigCount++;
    if (this.throwSetTrackLogConfig) {
      throw new Error('set log failed');
    }
  }

  initTrackLogConfig(_config: FTLoggerConfig): void {
    this.initTrackLogCount++;
  }

  initTrackRumConfig(_config: FTRUMConfig): void {
    this.initTrackRumCount++;
  }

  appendTrackGlobalContext(_globalContext: Map<string, string>): void {
    this.appendGlobalCount++;
  }

  appendTrackGlobalContextKeyValue(key: string, value: string): void {
    this.appendGlobalKeyCount++;
    this.lastAppendGlobalKey = key;
    this.lastAppendGlobalValue = value;
  }

  appendTrackRumGlobalContext(_globalContext: Map<string, string>): void {
    this.appendRumCount++;
  }

  appendTrackRumGlobalContextKeyValue(_key: string, _value: string): void {
    this.appendRumKeyCount++;
  }

  appendTrackLogGlobalContext(_globalContext: Map<string, string>): void {
    this.appendLogCount++;
  }

  appendTrackLogGlobalContextKeyValue(_key: string, _value: string): void {
    this.appendLogKeyCount++;
  }

  initRumContext(context: Context): void {
    this.initRumContextCount++;
    this.rumContext = context;
  }

  getRumContext(): Context | null {
    return this.rumContext;
  }

  initRumParams(_config: FTRUMConfig): void {
    this.initRumParamsCount++;
  }

  initRumGlobalConfig(_config: FTRUMConfig): void {
    this.initRumGlobalCount++;
  }

  initRumConfigManager(_config: FTRUMConfig): void {
    this.initRumConfigManagerCount++;
  }

  initTraceConfig(_config: FTTraceConfig): void {
    this.initTraceCount++;
    if (this.throwInitTrace) {
      throw new Error('trace failed');
    }
  }

  initMonitorConfig(_config: FTRUMConfig): void {
    this.initMonitorCount++;
  }

  getAnrDetectManager(): FTSDKAnrManager | null {
    return this.anrManager;
  }

  initExceptionHandler(_config: FTRUMConfig): void {
    this.initExceptionCount++;
  }

  startUIBlockManager(_config: FTRUMConfig): void {
    this.startUIBlockCount++;
  }

  registerLifecycleListener(): void {
    this.registerLifecycleCount++;
    if (this.throwRegisterLifecycle) {
      throw new Error('register failed');
    }
  }

  unregisterLifecycleListener(): void {
    this.unregisterLifecycleCount++;
    if (this.throwUnregisterLifecycle) {
      throw new Error('unregister failed');
    }
  }

  getAppStartCounter(): FTSDKAppStartCounterRuntime {
    return this.appStartCounter;
  }

  setMainWindow(mainWindow?: window.Window): void {
    this.setMainWindowCount++;
    if (mainWindow) {
      this.setMainWindowWithWindowCount++;
    }
  }

  getUIContext(): UIContext | null {
    return this.uiContext;
  }

  initActionTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.initActionCount++;
    if (this.throwActionInit) {
      throw new Error('action failed');
    }
  }

  destroyActionTracker(): void {
    this.destroyActionCount++;
    if (this.throwActionDestroy) {
      throw new Error('destroy action failed');
    }
  }

  initNavigationTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.initNavigationCount++;
  }

  destroyNavigationTracker(): void {
    this.destroyNavigationCount++;
    if (this.throwNavigationDestroy) {
      throw new Error('destroy navigation failed');
    }
  }

  updateLogCacheLimitCount(_limitCount: number): void {
    this.updateLogCacheCount++;
  }

  deleteAllData(_context: Context): Promise<void> {
    this.deleteAllDataCount++;
    if (this.throwDeleteAllData) {
      return Promise.reject(new Error('delete failed'));
    }
    return Promise.resolve();
  }

  getHarVersion(): string {
    return this.harVersion;
  }

  getNativeCrashVersion(): string {
    if (this.throwNativeCrashVersion) {
      throw new Error('native missing');
    }
    return this.nativeCrashVersion;
  }

  getDeviceBrand(): string {
    return 'brand';
  }

  getDeviceModel(): string {
    return 'model';
  }

  getDeviceArch(): string {
    return 'arch';
  }

  getDisplay(): string {
    return 'display';
  }

  getOSVersion(): string {
    return 'os';
  }

  getOSVersionMajor(): string {
    return 'major';
  }

  schedule(callback: () => void, _delayMs: number): void {
    this.scheduleCount++;
    callback();
  }
}

export default function ftSDKUnitTest() {
  describe('FTSDKUnit', () => {
    let runtime: FakeRuntime = new FakeRuntime();

    beforeEach(() => {
      runtime = new FakeRuntime();
      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
    });

    afterEach(() => {
      FTSDK.resetStateForTest();
      FTSDK.resetRuntimeForTest();
    });

    it('packageUuidInstallAndBaseConfigShouldCoverInitializationBranches', 0, () => {
      expect(FTSDK.getRumConfig() === null).assertTrue();

      const packageUuid = FTSDK.PACKAGE_UUID;
      expect(packageUuid).assertEqual('package-uuid:pkg:1.0.0');
      runtime.packageName = 'changed';
      expect(FTSDK.PACKAGE_UUID).assertEqual(packageUuid);

      FTSDK.resetStateForTest();
      runtime.throwPackageName = true;
      expect(FTSDK.PACKAGE_UUID).assertEqual('fallback-uuid');
      runtime.throwPackageName = false;

      const config = FTSDKConfig.builder(TEST_URL).setDebug(true).setServiceName('svc');
      runtime.abilityContext = createContext();
      const sdk = new FTSDK(config);
      sdk.initFTConfig(config);
      expect(runtime.debugEnabled).assertTrue();
      expect(runtime.monitorCount).assertEqual(1);
      expect(runtime.initSyncCount).assertEqual(1);
      expect(runtime.initUserDataCount).assertEqual(1);
      expect(runtime.initDeviceUuidCount).assertEqual(1);
      expect(runtime.initTrackBaseCount).assertEqual(1);
      expect(runtime.initRumContextCount).assertEqual(1);
      expect(config.getGlobalContext().has(Constants.KEY_APPLICATION_UUID)).assertTrue();

      runtime.abilityContext = null;
      sdk.initFTConfig(config);
      expect(runtime.monitorCount).assertEqual(2);
      expect(runtime.warnCount > 0).assertTrue();

      FTSDK.install(null);
      expect(runtime.errorCount > 0).assertTrue();

      runtime.throwMonitor = true;
      FTSDK.install(config, createContext());
      expect(runtime.initUtilsCount).assertEqual(1);
      expect(runtime.errorCount > 1).assertTrue();
    });

    it('configInstallersShouldCoverInstalledMissingAndErrorBranches', 0, () => {
      const logConfig = new FTLoggerConfig();
      FTSDK.installLogConfig(logConfig);
      expect(runtime.setTrackLogConfigCount).assertEqual(1);
      expect(runtime.updateLogCacheCount).assertEqual(1);
      expect(runtime.initTrackLogCount).assertEqual(0);

      runtime.abilityContext = createContext();
      const sdkConfig = FTSDKConfig.builder(TEST_URL).setServiceName('svc');
      FTSDK.install(sdkConfig);
      FTSDK.installLogConfig(logConfig);
      expect(runtime.initTrackLogCount).assertEqual(1);

      runtime.throwSetTrackLogConfig = true;
      FTSDK.installLogConfig(logConfig);
      expect(runtime.errorCount > 0).assertTrue();

      const traceWithoutInstall = new FTTraceConfig();
      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.installTraceConfig(traceWithoutInstall);
      expect(runtime.initTraceCount).assertEqual(1);

      runtime.abilityContext = createContext();
      FTSDK.install(sdkConfig);
      const traceWithInstall = new FTTraceConfig();
      FTSDK.installTraceConfig(traceWithInstall);
      expect(traceWithInstall.serviceName).assertEqual('svc');

      runtime.throwInitTrace = true;
      FTSDK.installTraceConfig(new FTTraceConfig());
      expect(runtime.errorCount > 1).assertTrue();
    });

    it('rumInstallerShouldCoverGlobalContextManagersAndFeatureBranches', 0, () => {
      const minimalRum = new FTRUMConfig().setRumAppId('rum-min');
      FTSDK.installRUMConfig(minimalRum);
      expect(FTSDK.getRumConfig() === minimalRum).assertTrue();
      expect(runtime.initRumConfigManagerCount).assertEqual(1);
      expect(runtime.initRumParamsCount).assertEqual(1);
      expect(runtime.initRumGlobalCount).assertEqual(1);
      expect(runtime.initTrackRumCount).assertEqual(0);
      expect(minimalRum.getGlobalContext().has(Constants.KEY_RUM_APP_ID)).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      runtime.abilityContext = createContext();
      FTSDK.install(FTSDKConfig.builder(TEST_URL));
      const fullRum = new FTRUMConfig()
        .setRumAppId('rum-full')
        .setEnableTraceUserAction(true)
        .setEnableTraceUserView(true)
        .setEnableTrackAppCrash(true)
        .setEnableTrackAppUIBlock(true, 300)
        .setEnableTrackAppANR(true)
        .addGlobalContext('custom', 'value' as Object);
      FTSDK.installRUMConfig(fullRum);
      expect(runtime.initTrackRumCount).assertEqual(1);
      expect(runtime.registerLifecycleCount).assertEqual(1);
      expect(runtime.appStartCounter.coldStartCount).assertEqual(1);
      expect(runtime.initMonitorCount > 0).assertTrue();
      expect(runtime.initExceptionCount).assertEqual(1);
      expect(runtime.startUIBlockCount).assertEqual(1);
      expect(runtime.setMainWindowCount > 0).assertTrue();
      expect(runtime.scheduleCount > 0).assertTrue();
      expect(FTSDK.isViewTrackingEnabled()).assertTrue();
      expect(fullRum.getGlobalContext().has(Constants.KEY_RUM_CUSTOM_KEYS)).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      runtime.throwRegisterLifecycle = true;
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTraceUserView(true));
      expect(runtime.warnCount > 0).assertTrue();

      runtime.throwRegisterLifecycle = false;
      runtime.appStartCounter.throwIsInited = true;
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTraceUserAction(true));
      expect(runtime.warnCount > 1).assertTrue();

      runtime.appStartCounter.throwIsInited = false;
      runtime.appStartCounter.inited = true;
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTraceUserAction(true));
      expect(runtime.appStartCounter.coldStartCount).assertEqual(1);
    });

    it('uiFeatureMethodsShouldCoverInitRetryCleanupAndTrackingBranches', 0, () => {
      const uiContext = createUIContext();
      FTSDK.initializeUIFeatures(uiContext);
      expect(runtime.warnCount).assertEqual(1);

      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum'));
      FTSDK.setAnrDetectManagerForTest(null);
      FTSDK.initializeUIFeatures(uiContext);
      expect(runtime.initActionCount).assertEqual(1);
      expect(runtime.initNavigationCount).assertEqual(1);

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTrackAppANR(true));
      FTSDK.setAutoActionTrackingEnabled(false);
      FTSDK.initializeUIFeatures(uiContext);
      expect(runtime.initActionCount).assertEqual(1);
      expect(runtime.initNavigationCount).assertEqual(2);
      expect(runtime.anrManager?.initializeCount).assertEqual(1);
      FTSDK.initializeUIFeatures(uiContext);
      expect(runtime.debugCount > 0).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum'));
      runtime.throwActionInit = true;
      FTSDK.initializeUIFeatures(uiContext);
      expect(runtime.errorCount > 0).assertTrue();
      runtime.throwActionInit = false;

      FTSDK.onWindowStageActive(new Object() as window.Window);
      FTSDK.onWindowStageActive();
      expect(runtime.setMainWindowWithWindowCount).assertEqual(1);

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.setUIFeatureStateForTest(true, false, 0);
      FTSDK.tryInitializeUIFeaturesForTest();
      expect(runtime.debugCount > 0).assertTrue();

      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTraceUserView(true));
      FTSDK.setUIFeatureStateForTest(true, true, 0);
      FTSDK.tryInitializeUIFeaturesForTest();
      FTSDK.setUIFeatureStateForTest(true, false, 5);
      FTSDK.tryInitializeUIFeaturesForTest();
      expect(runtime.warnCount > 0).assertTrue();

      runtime.uiContext = uiContext;
      FTSDK.setUIFeatureStateForTest(true, false, 0);
      FTSDK.tryInitializeUIFeaturesForTest();
      expect(runtime.initNavigationCount > 2).assertTrue();

      runtime.throwNavigationDestroy = true;
      FTSDK.cleanupUIFeatures();
      expect(runtime.destroyActionCount).assertEqual(1);
      expect(runtime.destroyNavigationCount).assertEqual(1);
      expect(runtime.anrManager?.shutdownCount).assertEqual(1);

      runtime.throwNavigationDestroy = false;
      runtime.throwActionDestroy = true;
      FTSDK.cleanupUIFeatures();
      expect(runtime.errorCount > 1).assertTrue();

      runtime.throwActionDestroy = false;
      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.cleanupUIFeatures();
      expect(runtime.destroyActionCount > 2).assertTrue();
    });

    it('userContextShutdownClearAndFlushShouldCoverPublicUtilityBranches', 0, async () => {
      FTSDK.bindRumUserDataById('user-id');
      expect(runtime.lastUserData?.getId()).assertEqual('user-id');
      FTSDK.bindRumUserData(new UserData('id', 'name', 'email'));
      expect(runtime.bindUserDataCount).assertEqual(2);
      FTSDK.unbindRumUserData();
      expect(runtime.unbindUserDataCount).assertEqual(1);

      FTSDK.appendGlobalContext(mapOf('base', 'value'));
      FTSDK.appendGlobalContextKeyValue('base-key', 'base-value');
      FTSDK.appendRUMGlobalContext(mapOf('rum', 'value'));
      FTSDK.appendRUMGlobalContextKeyValue('rum-key', 'rum-value');
      FTSDK.appendLogGlobalContext(mapOf('log', 'value'));
      FTSDK.appendLogGlobalContextKeyValue('log-key', 'log-value');
      expect(runtime.appendGlobalCount).assertEqual(0);

      runtime.abilityContext = createContext();
      FTSDK.install(FTSDKConfig.builder(TEST_URL));
      FTSDK.appendGlobalContext(mapOf('base', 'value'));
      FTSDK.appendGlobalContextKeyValue('base-key', 'base-value');
      FTSDK.appendRUMGlobalContext(mapOf('rum', 'value'));
      FTSDK.appendRUMGlobalContextKeyValue('rum-key', 'rum-value');
      FTSDK.appendLogGlobalContext(mapOf('log', 'value'));
      FTSDK.appendLogGlobalContextKeyValue('log-key', 'log-value');
      expect(runtime.appendGlobalCount).assertEqual(1);
      expect(runtime.appendGlobalKeyCount).assertEqual(1);
      expect(runtime.appendRumCount).assertEqual(1);
      expect(runtime.appendRumKeyCount).assertEqual(1);
      expect(runtime.appendLogCount).assertEqual(1);
      expect(runtime.appendLogKeyCount).assertEqual(1);

      FTSDK.shutDown();
      expect(runtime.unregisterLifecycleCount).assertEqual(1);
      expect(runtime.releaseNetworkCount).assertEqual(1);
      runtime.throwUnregisterLifecycle = true;
      FTSDK.shutDown();
      expect(runtime.warnCount > 0).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      await FTSDK.clearAllData();
      expect(runtime.deleteAllDataCount).assertEqual(0);

      runtime.abilityContext = createContext();
      FTSDK.install(FTSDKConfig.builder(TEST_URL));
      runtime.rumContext = null;
      await FTSDK.clearAllData();
      expect(runtime.deleteAllDataCount).assertEqual(0);

      runtime.rumContext = createContext();
      await FTSDK.clearAllData();
      expect(runtime.deleteAllDataCount).assertEqual(1);
      runtime.throwDeleteAllData = true;
      await FTSDK.clearAllData();
      expect(runtime.errorCount > 0).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      FTSDK.flushSyncData();
      expect(runtime.executeSyncCount).assertEqual(0);

      runtime.abilityContext = createContext();
      FTSDK.install(FTSDKConfig.builder(TEST_URL));
      FTSDK.flushSyncData();
      expect(runtime.executeSyncCount).assertEqual(1);
      expect(runtime.executeSyncWait).assertFalse();
      runtime.throwExecuteSync = true;
      FTSDK.flushSyncData();
      expect(runtime.errorCount > 1).assertTrue();
    });

    it('packageInfoViewTrackingAndFeaturePredicatesShouldCoverRemainingBranches', 0, () => {
      const config = FTSDKConfig.builder(TEST_URL)
        .addPkgInfo('custom', '1.0');
      config.getPkgInfo().set('ignored', '');
      runtime.abilityContext = createContext();
      FTSDK.install(config);
      const pkgInfo = `${config.getGlobalContext().get(Constants.KEY_SDK_PACKAGE_INFO)}`;
      expect(pkgInfo.indexOf('custom') >= 0).assertTrue();
      expect(pkgInfo.indexOf('ignored') < 0).assertTrue();
      expect(pkgInfo.indexOf(Constants.KEY_RUM_SDK_PACKAGE_NATIVE) < 0).assertTrue();

      runtime.throwNativeCrashVersion = true;
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId('rum-missing-native')
        .setEnableTrackAppCrash(true));
      const missingNativePkgInfo = `${config.getGlobalContext().get(Constants.KEY_SDK_PACKAGE_INFO)}`;
      expect(missingNativePkgInfo.indexOf(Constants.KEY_RUM_SDK_PACKAGE_NATIVE) < 0).assertTrue();
      expect(runtime.errorCount > 0).assertTrue();
      runtime.throwNativeCrashVersion = false;

      runtime.nativeCrashVersion = 'native-1.0';
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId('rum')
        .setEnableTrackAppCrash(true));
      const nativePkgInfo = `${config.getGlobalContext().get(Constants.KEY_SDK_PACKAGE_INFO)}`;
      expect(nativePkgInfo.indexOf(Constants.KEY_RUM_SDK_PACKAGE_NATIVE) >= 0).assertTrue();
      expect(nativePkgInfo.indexOf('native-1.0') >= 0).assertTrue();
      expect(runtime.lastAppendGlobalKey).assertEqual(Constants.KEY_SDK_PACKAGE_INFO);
      expect(runtime.lastAppendGlobalValue.indexOf('native-1.0') >= 0).assertTrue();

      expect(FTSDK.requiresUIFeaturesForTest(new FTRUMConfig())).assertFalse();
      expect(FTSDK.requiresUIFeaturesForTest(new FTRUMConfig().setEnableTraceUserAction(true))).assertTrue();
      expect(FTSDK.requiresUIFeaturesForTest(new FTRUMConfig().setEnableTraceUserView(true))).assertTrue();
      expect(FTSDK.requiresUIFeaturesForTest(new FTRUMConfig().setEnableTrackAppCrash(true))).assertTrue();
      expect(FTSDK.requiresLifecycleListenerForTest(new FTRUMConfig().setEnableTrackAppANR(true))).assertTrue();

      FTSDK.resetStateForTest();
      FTSDK.setRuntimeForTest(runtime);
      expect(FTSDK.isViewTrackingEnabled()).assertFalse();
      FTSDK.installRUMConfig(new FTRUMConfig().setEnableTraceUserView(true));
      expect(FTSDK.isViewTrackingEnabled()).assertFalse();
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum'));
      expect(FTSDK.isViewTrackingEnabled()).assertFalse();
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum').setEnableTraceUserView(true));
      expect(FTSDK.isViewTrackingEnabled()).assertTrue();
    });
  });
}
