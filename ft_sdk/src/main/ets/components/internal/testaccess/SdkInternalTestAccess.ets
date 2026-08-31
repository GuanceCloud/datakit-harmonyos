import { FTRUMConfig } from '../../Configs';
import { FTExceptionHandler } from '../../FTExceptionHandler';
import { FTNativeCrashHandler } from '../../FTNativeCrashHandler';
import { FTSDK } from '../../FTSDK';
import { FTAppLaunchTracker } from '../../monitor/FTAppLaunchTracker';
import { FTInnerLogger } from '../../log/FTLogger';
import ftnativecrash from 'libftnativecrash.so';
import {
  SDKDedicatedPoolManager,
  SDKDedicatedPoolManagerStatus
} from '../../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../../thread/SDKWorkerProtocol';
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
    FTAppLaunchTracker.resetInstanceInternal();
  }

  public static requiresUIFeatures(config: FTRUMConfig): boolean {
    return SdkInternalTestAccess.requiresUIFeaturesInternal(config);
  }

  public static getDedicatedPoolStatus(): SDKDedicatedPoolManagerStatus {
    return SDKDedicatedPoolManager.getInstance().getStatus();
  }

  public static probeDedicatedWorkers(): Promise<SDKWorkerResponse[]> {
    return SDKDedicatedPoolManager.getInstance().probeDedicatedWorkers();
  }

  public static executeDedicatedWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    return SDKDedicatedPoolManager.getInstance().executeCommand(request);
  }

  /** Internal device-test seam for unresolved mailbox replay verification. */
  public static postDedicatedWorkerCommandAndWait(
    request: SDKWorkerRequest,
    timeoutMs: number
  ): Promise<SDKWorkerResponse> {
    return SDKDedicatedPoolManager.getInstance().postCommandAndWait(request, timeoutMs);
  }

  public static failNextDedicatedMailboxPosts(count: number = 1): void {
    SDKDedicatedPoolManager.getInstance().failNextMailboxPostsInternal(count);
  }

  public static restartDedicatedWorker(pool: SDKDedicatedPoolType): boolean {
    return SDKDedicatedPoolManager.getInstance().restartWorkerInternal(pool);
  }

  public static configureDedicatedWorkerIdleTimeout(pool: SDKDedicatedPoolType, idleTimeoutMs: number): void {
    SDKDedicatedPoolManager.getInstance().configurePoolIdleTimeoutInternal(pool, idleTimeoutMs);
  }

  public static isNativeCrashLogCollectionEnabled(): boolean {
    return FTInnerLogger.isCrashLogCollectionEnabledInternal();
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
