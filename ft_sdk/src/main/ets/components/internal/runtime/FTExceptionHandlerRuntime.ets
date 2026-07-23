import { errorManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMInnerManager } from '../../rum/FTRUMInnerManager';
import { AppState } from '../../rum/enum/RUMEnums';
import { FTSDK } from '../../FTSDK';
import { RunnerCompleteCallBack } from '../../rum/callback/RunnerCompleteCallBack';
import { FTNativeCrashHandler } from '../../FTNativeCrashHandler';

export interface FTExceptionRumManager {
  stopView(): Promise<void>;
  addErrorInternal(
    log: string,
    message: string,
    errorType: string,
    state: AppState,
    property?: Record<string, object> | null,
    dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): Promise<void>;
  getContext(): object | null;
}

export interface FTExceptionHandlerRuntime {
  createNativeCrashHandler(): FTExceptionNativeCrashHandler;
  getRumManager(): FTExceptionRumManager;
  registerErrorObserver(callback: errorManager.ErrorObserver): number;
  unregisterErrorObserver(id: number, callback: (err: BusinessError | null) => void): void;
  flushSyncData(): void;
  schedule(callback: () => void, delayMs: number): void;
  shouldRethrowException(): boolean;
}

export interface FTExceptionNativeCrashHandler {
  initialize(): Promise<boolean>;
  stopWatching(): void;
  shutdown(): void;
}

export class DefaultFTExceptionHandlerRuntime implements FTExceptionHandlerRuntime {
  createNativeCrashHandler(): FTExceptionNativeCrashHandler {
    return new FTNativeCrashHandler();
  }

  getRumManager(): FTExceptionRumManager {
    return FTRUMInnerManager.getInstance();
  }

  registerErrorObserver(callback: errorManager.ErrorObserver): number {
    return errorManager.on("error", callback);
  }

  unregisterErrorObserver(id: number, callback: (err: BusinessError | null) => void): void {
    errorManager.off("error", id, callback);
  }

  flushSyncData(): void {
    FTSDK.flushSyncData();
  }

  schedule(callback: () => void, delayMs: number): void {
    setTimeout(callback, delayMs);
  }

  shouldRethrowException(): boolean {
    return true;
  }
}
