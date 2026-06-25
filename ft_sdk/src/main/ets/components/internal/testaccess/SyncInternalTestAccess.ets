import { SyncTaskManager } from '../../SyncTaskManager';
import { SyncTaskManagerRuntime } from '../runtime/SyncTaskManagerRuntime';

export class SyncInternalTestAccess {
  public static setRuntime(runtime: SyncTaskManagerRuntime): void {
    SyncTaskManager.setRuntimeInternal(runtime);
  }

  public static resetRuntime(): void {
    SyncTaskManager.resetRuntimeInternal();
  }

  public static resetState(): void {
    SyncTaskManager.resetStateInternal();
  }
}
