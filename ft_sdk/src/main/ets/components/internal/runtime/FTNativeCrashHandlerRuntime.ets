import ftnativecrash from 'libftnativecrash.so';
import { RunnerCompleteCallBack } from '../../rum/callback/RunnerCompleteCallBack';
import { AppState } from '../../rum/enum/RUMEnums';
import { FTRUMInnerManager } from '../../rum/FTRUMInnerManager';

export interface FTNativeCrashData {
  timestamp: number;
  crashType: string;
  foreground: boolean;
  bundleVersion: string;
  bundleName: string;
  pid: number;
  uid: number;
  uuid: string;
  exception: string;
  hilogSize: number;
  externalLog: string;
  logOverLimit: boolean;
  memoryNearRegisters: string;
  maps: string;
  hilog: string;
}

export type FTNativeCrashCallback = (crashData: FTNativeCrashData) => void | Promise<void>;

export interface FTNativeCrashModuleRuntime {
  initNativeCrashHandler(): boolean;
  setCrashCallback(callback: FTNativeCrashCallback): boolean;
  clearCrashCallback(): boolean;
  startWatching(): boolean;
  stopWatching(): boolean;
  addLog(level: string, tag: string, message: string): boolean;
  getCollectedLogs(maxLines?: number): string;
  clearLogs(): boolean;
  setMaxLogSize(maxSize: number): boolean;
  getVersion(): string;
}

export interface FTNativeCrashRumContext {
  viewId: string;
  viewName: string;
  viewReferrer: string;
  sessionId: string;
}

export interface FTNativeCrashRumManager {
  getSavedRumContext(): Promise<FTNativeCrashRumContext>;
  addErrorInternal(
    log: string,
    message: string,
    errorType: string,
    state: AppState,
    property?: Record<string, object> | null,
    dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): Promise<void>;
  clearSavedRumContext(): void;
}

class DefaultFTNativeCrashModuleRuntime implements FTNativeCrashModuleRuntime {
  initNativeCrashHandler(): boolean {
    return ftnativecrash.initNativeCrashHandler();
  }

  setCrashCallback(callback: FTNativeCrashCallback): boolean {
    return ftnativecrash.setCrashCallback(callback);
  }

  clearCrashCallback(): boolean {
    return ftnativecrash.clearCrashCallback();
  }

  startWatching(): boolean {
    return ftnativecrash.startWatching();
  }

  stopWatching(): boolean {
    return ftnativecrash.stopWatching();
  }

  addLog(level: string, tag: string, message: string): boolean {
    return ftnativecrash.addLog(level, tag, message);
  }

  getCollectedLogs(maxLines?: number): string {
    return ftnativecrash.getCollectedLogs(maxLines || 0);
  }

  clearLogs(): boolean {
    return ftnativecrash.clearLogs();
  }

  setMaxLogSize(maxSize: number): boolean {
    return ftnativecrash.setMaxLogSize(maxSize);
  }

  getVersion(): string {
    return ftnativecrash.getVersion();
  }
}

export interface FTNativeCrashHandlerRuntime {
  getNativeCrashModule(): FTNativeCrashModuleRuntime;
  getRumManager(): FTNativeCrashRumManager;
}

export class DefaultFTNativeCrashHandlerRuntime implements FTNativeCrashHandlerRuntime {
  private nativeModule: FTNativeCrashModuleRuntime = new DefaultFTNativeCrashModuleRuntime();

  getNativeCrashModule(): FTNativeCrashModuleRuntime {
    return this.nativeModule;
  }

  getRumManager(): FTNativeCrashRumManager {
    return FTRUMInnerManager.getInstance();
  }
}
