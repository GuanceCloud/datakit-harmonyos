import { FTRUMConfig } from '../../Configs';
import { FTExceptionHandler } from '../../FTExceptionHandler';
import { FTNativeCrashHandler } from '../../FTNativeCrashHandler';
import { FTSDK } from '../../FTSDK';
import ftnativecrash from 'libftnativecrash.so';
import { FTExceptionHandlerRuntime } from '../runtime/FTExceptionHandlerRuntime';
import { FTNativeCrashHandlerRuntime } from '../runtime/FTNativeCrashHandlerRuntime';
import {
  FTSDKRuntime,
  resetFTSDKRuntimeInternal,
  setFTSDKRuntimeInternal
} from '../runtime/FTSDKRuntime';

export class SdkInternalTestAccess extends FTSDK {
  public static setRuntime(runtime: FTSDKRuntime): void {
    setFTSDKRuntimeInternal(runtime);
  }

  public static resetRuntime(): void {
    resetFTSDKRuntimeInternal();
  }

  public static resetState(): void {
    SdkInternalTestAccess.resetInternalState();
  }

  public static requiresUIFeatures(config: FTRUMConfig): boolean {
    return SdkInternalTestAccess.requiresUIFeaturesInternal(config);
  }

  public static setExceptionHandlerRuntime(runtime: FTExceptionHandlerRuntime): void {
    FTExceptionHandler.setRuntimeInternal(runtime);
  }

  public static resetExceptionHandlerRuntime(): void {
    FTExceptionHandler.resetRuntimeInternal();
  }

  public static setNativeCrashHandlerRuntime(runtime: FTNativeCrashHandlerRuntime): void {
    FTNativeCrashHandler.setRuntimeInternal(runtime);
  }

  public static resetNativeCrashHandlerRuntime(): void {
    FTNativeCrashHandler.resetRuntimeInternal();
  }

  public static clearNativeCrashLogsForTest(): boolean {
    try {
      return ftnativecrash.clearLogs();
    } catch (_) {
      return false;
    }
  }

  public static getCollectedNativeCrashLogsForTest(maxLines?: number): string {
    try {
      return ftnativecrash.getCollectedLogs(maxLines || 0);
    } catch (_) {
      return '';
    }
  }
}
