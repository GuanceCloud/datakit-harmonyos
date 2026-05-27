import { FTInnerLogger } from '../log/FTLogger';
import { DataType, LogCacheDiscard, RUMCacheDiscard, DBCacheDiscard } from '../enum/Enums';
import { FTDBManager } from './FTDBManager';
import { ConfigRecord } from '../SyncTaskManager';
import { Context } from '@kit.AbilityKit';
import { Constants } from '../Constants';

// Re-export enum types for external use
export { DBCacheDiscard, LogCacheDiscard, RUMCacheDiscard } from '../enum/Enums';

const TAG = "FTDBCachePolicy";

class DefaultFTDBCachePolicyRuntime {
  getDbManager(context: Context): FTDBManager {
    return FTDBManager.getInstance(context);
  }
}

let ftDBCachePolicyRuntime: Object = new DefaultFTDBCachePolicyRuntime();

/**
 * Database cache discard policy for HarmonyOS SDK
 * Database cache policy for HarmonyOS SDK
 */
export class FTDBCachePolicy {
  private static instance: FTDBCachePolicy | null = null;

  // Current data counts
  private logCount: number = 0;
  private rumCount: number = 0;
  private currentDbSize: number = 0;

  // Limit configurations
  private logLimitCount: number = 0;
  private rumLimitCount: number = 0;
  private enableLimitWithDbSize: boolean = false;
  private dbLimitSize: number = 0;

  // Cache discard strategies
  private dbCacheDiscard: DBCacheDiscard = DBCacheDiscard.DISCARD;
  private logCacheDiscardStrategy: LogCacheDiscard = LogCacheDiscard.DISCARD;
  private rumCacheDiscardStrategy: RUMCacheDiscard = RUMCacheDiscard.DISCARD;

  // Locks for thread safety
  private rumLock: Record<string, boolean> = {};
  private logLock: Record<string, boolean> = {};

  private constructor() {
    // Initialize counts from database
    this.initializeCounts();
  }

  public static getInstance(): FTDBCachePolicy {
    if (!FTDBCachePolicy.instance) {
      FTDBCachePolicy.instance = new FTDBCachePolicy();
    }
    return FTDBCachePolicy.instance;
  }

  public static setRuntimeForTest(runtime: Object): void {
    ftDBCachePolicyRuntime = runtime;
  }

  public static resetRuntimeForTest(): void {
    ftDBCachePolicyRuntime = new DefaultFTDBCachePolicyRuntime();
  }

  public static getDbManagerForTest(context: Context): Object {
    return (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
  }

  /**
   * Initialize data counts from database
   */
  private async initializeCounts(): Promise<void> {
    // Initialize counts to 0 since we don't have context here.
    // The actual counts will be updated when data is added/removed.
    this.logCount = 0;
    this.rumCount = 0;
    FTInnerLogger.d(TAG, `Initialized counts: logCount=${this.logCount}, rumCount=${this.rumCount}`);
  }

  /**
   * Initialize SDK parameters
   * 
   * @param config SDK configuration
   */
  public initSDKParams(config: ConfigRecord): void {
    this.enableLimitWithDbSize = config.isLimitWithDbSize();
    this.dbLimitSize = config.getDbCacheLimit();
    this.logLimitCount = config.getLogCacheLimitCount();
    this.rumLimitCount = config.getRumCacheLimitCount();
    // Convert string values to enum types
    const dbCacheDiscardStr = config.getDBCacheDiscard();
    const logCacheDiscardStr = config.getLogCacheDiscard();
    const rumCacheDiscardStr = config.getRumCacheDiscard();
    
    this.dbCacheDiscard = (dbCacheDiscardStr === "discard_oldest") ? DBCacheDiscard.DISCARD_OLDEST : DBCacheDiscard.DISCARD;
    this.logCacheDiscardStrategy = (logCacheDiscardStr === "discard_oldest") ? LogCacheDiscard.DISCARD_OLDEST : LogCacheDiscard.DISCARD;
    this.rumCacheDiscardStrategy = (rumCacheDiscardStr === "discard_oldest") ? RUMCacheDiscard.DISCARD_OLDEST : RUMCacheDiscard.DISCARD;

    FTInnerLogger.d(TAG, `SDK params initialized: enableLimitWithDbSize=${this.enableLimitWithDbSize}, dbLimitSize=${this.dbLimitSize}, logLimitCount=${this.logLimitCount}, rumLimitCount=${this.rumLimitCount}`);
  }

  /**
   * Check if database size limit is enabled
   */
  public isEnableLimitWithDbSize(): boolean {
    return this.enableLimitWithDbSize;
  }

  /**
   * Check if database size limit is reached
   */
  public isReachDbLimit(): boolean {
    if (!this.enableLimitWithDbSize) {
      // FTInnerLogger.d(TAG, ` DB size limit check: disabled, currentSize=${this.currentDbSize}, limitSize=${this.dbLimitSize}`);
      return false;
    }
    const reached = this.currentDbSize >= this.dbLimitSize;
    // FTInnerLogger.d(TAG, ` DB size limit check: currentSize=${this.currentDbSize}, limitSize=${this.dbLimitSize}, reached=${reached}`);
    return reached;
  }

  /**
   * Check if log count limit is reached
   */
  public isReachLogLimit(): boolean {
    if (this.logLimitCount <= 0) {
      FTInnerLogger.d(TAG, `Log count limit check: disabled, currentCount=${this.logCount}, limitCount=${this.logLimitCount}`);
      return false;
    }
    const reached = this.logCount >= this.logLimitCount;
    FTInnerLogger.d(TAG, `Log count limit check: currentCount=${this.logCount}, limitCount=${this.logLimitCount}, reached=${reached}`);
    return reached;
  }

  /**
   * Check if RUM count limit is reached
   */
  public isReachRumLimit(): boolean {
    if (this.rumLimitCount <= 0) {
      FTInnerLogger.d(TAG, `RUM count limit check: disabled, currentCount=${this.rumCount}, limitCount=${this.rumLimitCount}`);
      return false;
    }
    const reached = this.rumCount >= this.rumLimitCount;
    FTInnerLogger.d(TAG, `RUM count limit check: currentCount=${this.rumCount}, limitCount=${this.rumLimitCount}, reached=${reached}`);
    return reached;
  }

  /**
   * Update log count (aligned with Android: optLogCount)
   * 
   * @param delta Change in log count (positive or negative)
   */
  public optLogCount(delta: number): void {
    // If database size limit is enabled, don't update count (aligned with Android)
    if (this.enableLimitWithDbSize) {
      return;
    }
    this.logCount = Math.max(0, this.logCount + delta);
  }

  /**
   * Update RUM count (aligned with Android: optRUMCount)
   * 
   * @param delta Change in RUM count (positive or negative)
   */
  public optRumCount(delta: number): void {
    // If database size limit is enabled, don't update count (aligned with Android)
    if (this.enableLimitWithDbSize) {
      return;
    }
    const oldCount = this.rumCount;
    this.rumCount = Math.max(0, this.rumCount + delta);
   // FTInnerLogger.d(TAG, ` RUM count updated: delta=${delta}, oldCount=${oldCount}, newCount=${this.rumCount}`);
  }

  /**
   * Set current database size (aligned with Android: setCurrentDBSize)
   * 
   * @param currentDbSize Current database size in bytes
   */
  public setCurrentDbSize(currentDbSize: number): void {
    const oldSize = this.currentDbSize;
    this.currentDbSize = Math.max(0, currentDbSize);
   // FTInnerLogger.d(TAG, ` DB size set: oldSize=${oldSize}, newSize=${this.currentDbSize}`);
  }

  /**
   * Update database size
   * 
   * @param delta Change in database size (positive or negative)
   */
  public optDbSize(delta: number): void {
    const oldSize = this.currentDbSize;
    this.currentDbSize = Math.max(0, this.currentDbSize + delta);
    //FTInnerLogger.d(TAG, ` DB size updated: delta=${delta}, oldSize=${oldSize}, newSize=${this.currentDbSize}`);
  }

  /**
   * Get current log count
   */
  public getLogCount(): number {
    return this.logCount;
  }

  /**
   * Get current RUM count
   */
  public getRumCount(): number {
    return this.rumCount;
  }

  /**
   * Get current database size
   */
  public getCurrentDbSize(): number {
    return this.currentDbSize;
  }

  /**
   * Get log limit count
   */
  public getLogLimitCount(): number {
    return this.logLimitCount;
  }

  /**
   * Get RUM limit count
   */
  public getRumLimitCount(): number {
    return this.rumLimitCount;
  }

  /**
   * Get database limit size
   */
  public getDbLimitSize(): number {
    return this.dbLimitSize;
  }

  /**
   * Get database cache discard strategy
   */
  public getDBCacheDiscard(): string {
    return this.dbCacheDiscard;
  }

  /**
   * Get RUM lock for thread safety
   */
  public getRumLock(): object {
    return this.rumLock;
  }

  /**
   * Get log lock for thread safety
   */
  public getLogLock(): object {
    return this.logLock;
  }

  /**
   * Execute RUM cache policy (aligned with Android: optRUMCachePolicy)
   * 
   * @param context Context for accessing FTDBManager
   * @param limit Number of records to process
   * @returns -1: discard, 0: can insert, 1: delete old data and insert
   */
  public async optRUMCachePolicy(context: Context, limit: number): Promise<number> {
    if (this.enableLimitWithDbSize) {
      // Get current database size before checking limit (aligned with Android)
      const dbManager = (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
      const currentDbSize = await dbManager.getCurrentDatabaseSize();
      this.setCurrentDbSize(currentDbSize);
      //FTInnerLogger.d(TAG, ` optRUMCachePolicy: got currentDbSize=${currentDbSize}, limitSize=${this.dbLimitSize}`);
      
      if (this.isReachDbLimit()) {
        FTInnerLogger.w(TAG, ` optRUMCachePolicy: DB limit reached! currentSize=${currentDbSize}, limitSize=${this.dbLimitSize}, discard=${this.dbCacheDiscard}`);
        switch (this.dbCacheDiscard) {
          case DBCacheDiscard.DISCARD:
            FTInnerLogger.w(TAG, ` optRUMCachePolicy: returning -1 (DISCARD)`);
            return -1;
          case DBCacheDiscard.DISCARD_OLDEST:
            // Delete old data before inserting (aligned with Android: DB_OLD_CACHE_REMOVE_COUNT = 100)
            // Delete more records to ensure database size decreases
            const deleteCount = Constants.DB_OLD_CACHE_REMOVE_COUNT;
            FTInnerLogger.w(TAG, ` optRUMCachePolicy: deleting oldest ${deleteCount} records (DB size limit exceeded)`);
            await dbManager.deleteOldestData(
              [DataType.RUM_APP, DataType.RUM_WEBVIEW],
              deleteCount
            );
            // Update RUM count after deletion
            const rumCount = await dbManager.queryTotalCount(
              [DataType.RUM_APP, DataType.RUM_WEBVIEW]
            );
            this.rumCount = rumCount;
            FTInnerLogger.w(TAG, ` optRUMCachePolicy: deleted ${deleteCount} old records, returning 1`);
            return 1;
        }
      }
      // FTInnerLogger.d(TAG, ` optRUMCachePolicy: DB limit not reached, returning 0`);
      return 0;
    }

    // Count-based limit logic
    let status = 0;
    const currentRUMCount = this.rumCount;
    if (currentRUMCount >= this.rumLimitCount) {
      if (this.rumCacheDiscardStrategy === RUMCacheDiscard.DISCARD) {
        status = -1;
      } else {
        const dbManager = (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
        await dbManager.deleteOldestData(
          [DataType.RUM_APP, DataType.RUM_WEBVIEW],
          limit
        );
        const rumCount = await dbManager.queryTotalCount(
          [DataType.RUM_APP, DataType.RUM_WEBVIEW]
        );
        this.rumCount = rumCount;
        status = 1;
      }
    } else {
      status = 0;
    }
    return status;
  }

  /**
   * Execute log cache policy (aligned with Android: optLogCachePolicy)
   * 
   * @param context Context for accessing FTDBManager
   * @param limit Number of records to process
   * @returns 0: can insert, n: delete n old records, -n: discard n new records
   */
  public async optLogCachePolicy(context: Context, limit: number): Promise<number> {
    if (this.enableLimitWithDbSize) {
      // Get current database size before checking limit (aligned with Android)
      const dbManager = (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
      const currentDbSize = await dbManager.getCurrentDatabaseSize();
      this.setCurrentDbSize(currentDbSize);
      // FTInnerLogger.d(TAG, ` optLogCachePolicy: got currentDbSize=${currentDbSize}, limitSize=${this.dbLimitSize}`);
      
      if (this.isReachDbLimit()) {
        FTInnerLogger.w(TAG, ` optLogCachePolicy: DB limit reached! currentSize=${currentDbSize}, limitSize=${this.dbLimitSize}, discard=${this.dbCacheDiscard}`);
        switch (this.dbCacheDiscard) {
          case DBCacheDiscard.DISCARD:
            FTInnerLogger.w(TAG, ` optLogCachePolicy: returning -${limit} (DISCARD)`);
            return -limit;
          case DBCacheDiscard.DISCARD_OLDEST:
            // Delete old data before inserting (aligned with Android: DB_OLD_CACHE_REMOVE_COUNT = 100)
            // Delete more records to ensure database size decreases
            const deleteCount = Constants.DB_OLD_CACHE_REMOVE_COUNT;
            FTInnerLogger.w(TAG, ` optLogCachePolicy: deleting oldest ${deleteCount} records (DB size limit exceeded)`);
            await dbManager.deleteOldestData(DataType.LOG, deleteCount);
            // Update log count after deletion
            const logCount = await dbManager.queryTotalCount([DataType.LOG]);
            this.logCount = logCount;
            FTInnerLogger.w(TAG, ` optLogCachePolicy: deleted ${deleteCount} old records, returning ${limit}`);
            return limit;
        }
      }
      //FTInnerLogger.d(TAG, ` optLogCachePolicy: DB limit not reached, returning 0`);
      return 0;
    }

    // Count-based limit logic
    let status = 0;
    const currentLogCount = this.logCount;
    if (currentLogCount >= this.logLimitCount) {
      if (this.logCacheDiscardStrategy === LogCacheDiscard.DISCARD) {
        status = -limit;
      } else {
        const dbManager = (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
        await dbManager.deleteOldestData(DataType.LOG, limit);
        const logCount = await dbManager.queryTotalCount([DataType.LOG]);
        this.logCount = logCount;
        status = limit;
      }
    } else {
      if (currentLogCount + limit >= this.logLimitCount) {
        const needInsert = this.logLimitCount - currentLogCount;
        const needRemove = limit - needInsert;
        if (this.logCacheDiscardStrategy === LogCacheDiscard.DISCARD) {
          status = -needRemove;
        } else {
          const dbManager = (ftDBCachePolicyRuntime as DefaultFTDBCachePolicyRuntime).getDbManager(context);
          await dbManager.deleteOldestData(DataType.LOG, needRemove);
          const logCount = await dbManager.queryTotalCount([DataType.LOG]);
          this.logCount = logCount;
          status = needRemove;
        }
      }
    }
    return status;
  }

  /**
   * Check if data should be discarded based on limits
   * 
   * @param dataType Type of data
   * @returns true if data should be discarded
   */
  public shouldDiscardData(dataType: DataType): boolean {
    FTInnerLogger.d(TAG, `Data discard check started: dataType=${dataType}`);
    
    // If database size limit is enabled, check database size limit first
    if (this.enableLimitWithDbSize) {
      const dbLimitReached = this.isReachDbLimit();
      if (dbLimitReached) {
        // If discard strategy is DISCARD, should discard data
        if (this.dbCacheDiscard === DBCacheDiscard.DISCARD) {
          FTInnerLogger.d(TAG, `DB size limit reached with DISCARD strategy, should discard data`);
          return true;
        }
        // If discard strategy is DISCARD_OLDEST, should not discard (will clean old data)
        FTInnerLogger.d(TAG, `DB size limit reached with DISCARD_OLDEST strategy, will clean old data`);
        return false;
      }
    }
    
    let shouldDiscard = false;
    if (dataType === DataType.LOG) {
      shouldDiscard = this.isReachLogLimit();
    } else if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      shouldDiscard = this.isReachRumLimit();
    }
    
    FTInnerLogger.d(TAG, `Data discard check result: dataType=${dataType}, shouldDiscard=${shouldDiscard}`);
    return shouldDiscard;
  }

  /**
   * Get discard strategy for data type
   * 
   * @param dataType Type of data
   * @returns Discard strategy
   */
  public getDiscardStrategy(dataType: DataType): DBCacheDiscard | LogCacheDiscard | RUMCacheDiscard {
    if (dataType === DataType.LOG) {
      return this.logCacheDiscardStrategy;
    } else if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      return this.rumCacheDiscardStrategy;
    }
    return this.dbCacheDiscard;
  }

  /**
   * Reset all counts (for testing)
   */
  public resetCounts(): void {
    this.logCount = 0;
    this.rumCount = 0;
    this.currentDbSize = 0;
    FTInnerLogger.d(TAG, "All counts reset to 0");
  }

  /**
   * Set test limits for testing purposes
   *
   * @param logLimit Log count limit
   * @param rumLimit RUM count limit
   */
  public setTestLimits(logLimit: number, rumLimit: number): void {
    this.logLimitCount = logLimit;
    this.rumLimitCount = rumLimit;
    FTInnerLogger.d(TAG, ` Test limits set: logLimit=${logLimit}, rumLimit=${rumLimit}`);
  }

  /**
   * Update log cache limit count from FTLoggerConfig
   * Called by FTSDK.installLogConfig() to update log cache policy
   * Aligned with Android SDK behavior
   *
   * @param logCacheLimitCount Log cache entry count limit
   */
  public updateLogCacheLimitCount(logCacheLimitCount: number): void {
    this.logLimitCount = logCacheLimitCount;
    FTInnerLogger.d(TAG, `Log cache limit count updated: ${this.logLimitCount}`);
  }

  /**
   * Set database size limit for testing purposes
   *
   * @param dbSizeLimit Database size limit in bytes
   */
  public setTestDbSizeLimit(dbSizeLimit: number): void {
    this.enableLimitWithDbSize = true;
    this.dbLimitSize = dbSizeLimit;
    FTInnerLogger.d(TAG, ` Test DB size limit set: ${dbSizeLimit} bytes`);
  }

  /**
   * Reset test configuration to default values
   */
  public resetTestConfig(): void {
    this.logLimitCount = 0;
    this.rumLimitCount = 0;
    this.enableLimitWithDbSize = false;
    this.dbLimitSize = 0;
    FTInnerLogger.d(TAG, ` Test configuration reset to defaults`);
  }
}
