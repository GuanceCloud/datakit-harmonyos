/**
 * HarmonyOS SDK database callback interface
 */
import relationalStore from '@ohos.data.relationalStore';

/**
 * Database operation callback interface
 * Used for callback handling of database read/write operations
 */
export interface DataBaseCallBack {
  /**
   * Execute database operation
   * @param rdbStore HarmonyOS RDB database object
   */
  run(rdbStore: relationalStore.RdbStore): void | Promise<void>;
}
