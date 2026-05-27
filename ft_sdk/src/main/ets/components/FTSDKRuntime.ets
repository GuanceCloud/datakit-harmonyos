import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import ftnativecrash from 'libftnativecrash.so';
import BuildProfile from "../../../../BuildProfile";
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from './Configs';
import FTTrackInner from './FTTrackInner';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import { FTRUMGlobalManager } from './rum/FTRUMGlobalManager';
import { FTRUMConfigManager } from './rum/FTRUMConfigManager';
import { FTInnerLogger } from './log/FTLogger';
import { SyncTaskManager } from './SyncTaskManager';
import { AppUtils } from './utils/AppUtils';
import { DeviceUtils } from './utils/DeviceUtils';
import { DeviceUUIDManager } from './utils/DeviceUUIDManager';
import { ApplicationUUIDGenerator } from './utils/ApplicationUUIDGenerator';
import { FTTraceConfigManager } from './trace/FTTraceConfigManager';
import { FTMonitorManager } from './rum/FTMonitorManager';
import { TrackLogManager } from './log/TrackLogManager';
import { ANRDetectManager } from './monitor/ANRDetectManager';
import { UserData } from './rum/bean/UserData';
import { UserDataManager } from './rum/UserDataManager';
import { FTNetworkListener } from './utils/FTNetworkListener';
import { FTActionTracker } from './rum/FTActionTracker';
import { FTNavigationTracker } from './rum/FTNavigationTracker';
import { FTDBManager } from './db/FTDBManager';
import { FTDBCachePolicy } from './db/FTDBCachePolicy';
import { FTExceptionHandler } from './FTExceptionHandler';
import { FTUIBlockManager } from './monitor/FTUIBlockManager';
import { FTAbilityLifecycleListener } from './monitor/FTAbilityLifecycleListener';
import { FTAppStartCounter } from './monitor/FTAppStartCounter';
import { Utils } from './utils/Utils';

export interface FTSDKAnrManager {
  initialize(): void;
  startMonitoring(): void;
  shutdown(): void;
}

export interface FTSDKAppStartCounterRuntime {
  isInited(): boolean;
  coldStart(endTime: number): void;
  coldStartUpload(): void;
  setInited(inited: boolean): void;
}

export interface FTSDKRuntime {
  setDebugEnabled(enabled: boolean): void;
  logDebug(tag: string, message: string): void;
  logInfo(tag: string, message: string): void;
  logWarn(tag: string, message: string): void;
  logError(tag: string, message: string): void;
  initUtils(context: common.UIAbilityContext): void;
  monitorNetwork(): void;
  releaseNetwork(): void;
  getAbilityContext(): common.UIAbilityContext | null;
  initSyncTaskManager(config: FTSDKConfig, context: Context): void;
  executeSyncPoll(wait: boolean): void;
  initUserDataManager(context: Context): void;
  bindUserData(userData: UserData): void;
  unbindUserData(): void;
  initDeviceUUIDManager(context: common.UIAbilityContext): void;
  getDeviceUUID(accessODID: boolean): string;
  getPackageName(): string;
  getAppVersionName(): string;
  generatePackageUUID(packageName: string, versionName: string): string;
  generateFallbackPackageUUID(): string;
  getCurrentNanoTime(): number;
  initTrackBaseConfig(config: FTSDKConfig, context: Context): void;
  setTrackLogConfig(config: FTLoggerConfig): void;
  initTrackLogConfig(config: FTLoggerConfig): void;
  initTrackRumConfig(config: FTRUMConfig): void;
  appendTrackGlobalContext(globalContext: Map<string, string>): void;
  appendTrackGlobalContextKeyValue(key: string, value: string): void;
  appendTrackRumGlobalContext(globalContext: Map<string, string>): void;
  appendTrackRumGlobalContextKeyValue(key: string, value: string): void;
  appendTrackLogGlobalContext(globalContext: Map<string, string>): void;
  appendTrackLogGlobalContextKeyValue(key: string, value: string): void;
  initRumContext(context: Context): void;
  getRumContext(): Context | null;
  initRumParams(config: FTRUMConfig): void;
  initRumGlobalConfig(config: FTRUMConfig): void;
  initRumConfigManager(config: FTRUMConfig): void;
  initTraceConfig(config: FTTraceConfig): void;
  initMonitorConfig(config: FTRUMConfig): void;
  getAnrDetectManager(): FTSDKAnrManager | null;
  initExceptionHandler(config: FTRUMConfig): void;
  startUIBlockManager(config: FTRUMConfig): void;
  registerLifecycleListener(): void;
  unregisterLifecycleListener(): void;
  getAppStartCounter(): FTSDKAppStartCounterRuntime;
  setMainWindow(mainWindow?: window.Window): void;
  getUIContext(): UIContext | null;
  initActionTracker(uiContext: UIContext, config: FTRUMConfig): void;
  destroyActionTracker(): void;
  initNavigationTracker(uiContext: UIContext, config: FTRUMConfig): void;
  destroyNavigationTracker(): void;
  updateLogCacheLimitCount(limitCount: number): void;
  deleteAllData(context: Context): Promise<void>;
  getHarVersion(): string;
  getNativeCrashVersion(): string;
  getDeviceBrand(): string;
  getDeviceModel(): string;
  getDeviceArch(): string;
  getDisplay(): string;
  getOSVersion(): string;
  getOSVersionMajor(): string;
  schedule(callback: () => void, delayMs: number): void;
}

export class DefaultFTSDKRuntime implements FTSDKRuntime {
  setDebugEnabled(enabled: boolean): void {
    FTInnerLogger.setDebugEnabled(enabled);
  }

  logDebug(tag: string, message: string): void {
    FTInnerLogger.d(tag, message);
  }

  logInfo(tag: string, message: string): void {
    FTInnerLogger.i(tag, message);
  }

  logWarn(tag: string, message: string): void {
    FTInnerLogger.w(tag, message);
  }

  logError(tag: string, message: string): void {
    FTInnerLogger.e(tag, message);
  }

  initUtils(context: common.UIAbilityContext): void {
    Utils.init(context);
  }

  monitorNetwork(): void {
    FTNetworkListener.getInstance().monitor();
  }

  releaseNetwork(): void {
    FTNetworkListener.release();
  }

  getAbilityContext(): common.UIAbilityContext | null {
    return Utils.getAbilityContext();
  }

  initSyncTaskManager(config: FTSDKConfig, context: Context): void {
    SyncTaskManager.getInstance().init(config, context);
  }

  executeSyncPoll(wait: boolean): void {
    SyncTaskManager.getInstance().executePoll(wait);
  }

  initUserDataManager(context: Context): void {
    UserDataManager.getInstance().init(context);
  }

  bindUserData(userData: UserData): void {
    UserDataManager.getInstance().bindUserData(userData);
  }

  unbindUserData(): void {
    UserDataManager.getInstance().unbindUserData();
  }

  initDeviceUUIDManager(context: common.UIAbilityContext): void {
    DeviceUUIDManager.getInstance().init(context);
  }

  getDeviceUUID(accessODID: boolean): string {
    return DeviceUUIDManager.getInstance().getDeviceUUID(accessODID);
  }

  getPackageName(): string {
    return AppUtils.getPackageName();
  }

  getAppVersionName(): string {
    return AppUtils.getAppVersionName();
  }

  generatePackageUUID(packageName: string, versionName: string): string {
    return ApplicationUUIDGenerator.generateFromPackageInfo(packageName, versionName);
  }

  generateFallbackPackageUUID(): string {
    return ApplicationUUIDGenerator.generateDeterministicUUID("harmonyos_fallback_seed");
  }

  getCurrentNanoTime(): number {
    return Utils.getCurrentNanoTime();
  }

  initTrackBaseConfig(config: FTSDKConfig, context: Context): void {
    FTTrackInner.getInstance().initBaseConfig(config, context);
  }

  setTrackLogConfig(config: FTLoggerConfig): void {
    TrackLogManager.getInstance().setLogConfig(config);
  }

  initTrackLogConfig(config: FTLoggerConfig): void {
    FTTrackInner.getInstance().initLogConfig(config);
  }

  initTrackRumConfig(config: FTRUMConfig): void {
    FTTrackInner.getInstance().initRUMConfig(config);
  }

  appendTrackGlobalContext(globalContext: Map<string, string>): void {
    FTTrackInner.getInstance().appendGlobalContext(globalContext);
  }

  appendTrackGlobalContextKeyValue(key: string, value: string): void {
    FTTrackInner.getInstance().appendGlobalContextKeyValue(key, value);
  }

  appendTrackRumGlobalContext(globalContext: Map<string, string>): void {
    FTTrackInner.getInstance().appendRUMGlobalContext(globalContext);
  }

  appendTrackRumGlobalContextKeyValue(key: string, value: string): void {
    FTTrackInner.getInstance().appendRUMGlobalContextKeyValue(key, value);
  }

  appendTrackLogGlobalContext(globalContext: Map<string, string>): void {
    FTTrackInner.getInstance().appendLogGlobalContext(globalContext);
  }

  appendTrackLogGlobalContextKeyValue(key: string, value: string): void {
    FTTrackInner.getInstance().appendLogGlobalContextKeyValue(key, value);
  }

  initRumContext(context: Context): void {
    FTRUMInnerManager.getInstance().initContext(context);
  }

  getRumContext(): Context | null {
    return FTRUMInnerManager.getInstance().getContext();
  }

  initRumParams(config: FTRUMConfig): void {
    FTRUMInnerManager.getInstance().initParams(config);
  }

  initRumGlobalConfig(config: FTRUMConfig): void {
    FTRUMGlobalManager.getInstance().initConfig(config);
  }

  initRumConfigManager(config: FTRUMConfig): void {
    FTRUMConfigManager.getInstance().initWithConfig(config);
  }

  initTraceConfig(config: FTTraceConfig): void {
    FTTraceConfigManager.getInstance().initWithConfig(config);
  }

  initMonitorConfig(config: FTRUMConfig): void {
    FTMonitorManager.getInstance().initWithConfig(config);
  }

  getAnrDetectManager(): FTSDKAnrManager | null {
    return ANRDetectManager.getInstance();
  }

  initExceptionHandler(config: FTRUMConfig): void {
    FTExceptionHandler.getInstance().initConfig(config);
  }

  startUIBlockManager(config: FTRUMConfig): void {
    FTUIBlockManager.getInstance().start(config);
  }

  registerLifecycleListener(): void {
    FTAbilityLifecycleListener.getInstance().register();
  }

  unregisterLifecycleListener(): void {
    FTAbilityLifecycleListener.getInstance().unregister();
  }

  getAppStartCounter(): FTSDKAppStartCounterRuntime {
    return FTAppStartCounter.getInstance();
  }

  setMainWindow(mainWindow?: window.Window): void {
    if (mainWindow) {
      Utils.setMainWindow(mainWindow);
    } else {
      Utils.setMainWindow();
    }
  }

  getUIContext(): UIContext | null {
    return Utils.getUIContext() || null;
  }

  initActionTracker(uiContext: UIContext, config: FTRUMConfig): void {
    FTActionTracker.getInstance().init(uiContext, config);
  }

  destroyActionTracker(): void {
    FTActionTracker.getInstance().destroy();
  }

  initNavigationTracker(uiContext: UIContext, config: FTRUMConfig): void {
    FTNavigationTracker.getInstance().init(uiContext, config);
  }

  destroyNavigationTracker(): void {
    FTNavigationTracker.getInstance().destroy();
  }

  updateLogCacheLimitCount(limitCount: number): void {
    FTDBCachePolicy.getInstance().updateLogCacheLimitCount(limitCount);
  }

  async deleteAllData(context: Context): Promise<void> {
    await FTDBManager.getInstance(context).delete();
  }

  getHarVersion(): string {
    return BuildProfile.HAR_VERSION;
  }

  getNativeCrashVersion(): string {
    return ftnativecrash.getVersion();
  }

  getDeviceBrand(): string {
    return DeviceUtils.getDeviceBrand();
  }

  getDeviceModel(): string {
    return DeviceUtils.getDeviceModel();
  }

  getDeviceArch(): string {
    return DeviceUtils.getDeviceArch();
  }

  getDisplay(): string {
    return DeviceUtils.getDisplay();
  }

  getOSVersion(): string {
    return DeviceUtils.getOSVersion();
  }

  getOSVersionMajor(): string {
    return DeviceUtils.getOSVersionMajor();
  }

  schedule(callback: () => void, delayMs: number): void {
    setTimeout(callback, delayMs);
  }
}
