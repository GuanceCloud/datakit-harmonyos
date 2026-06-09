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
}
