import { FTDBCachePolicy } from '../../db/FTDBCachePolicy';
import { FTDBManager } from '../../db/FTDBManager';

export class DbInternalTestAccess {
  public static setCachePolicyRuntime(runtime: Object): void {
    FTDBCachePolicy.setRuntimeInternal(runtime);
  }

  public static resetCachePolicyRuntime(): void {
    FTDBCachePolicy.resetRuntimeInternal();
  }

  public static resetDbManagerInstance(): void {
    FTDBManager.resetInstanceInternal();
  }

  public static forceNextSyncDataWriteFailure(): void {
    FTDBManager.forceNextSyncDataWriteFailureInternal();
  }

  public static async simulateNoLockDbShutdown(context: Context): Promise<void> {
    await FTDBManager.getInstance(context).simulateNoLockShutdownForTest();
  }

  public static clearNoLockDbShutdownSimulation(context: Context): void {
    FTDBManager.getInstance(context).clearNoLockShutdownSimulationForTest();
  }
}
