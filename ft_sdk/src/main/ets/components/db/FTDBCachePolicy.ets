import { FTInnerLogger } from '../log/FTLogger';
import { DataType, LogCacheDiscard, RUMCacheDiscard, DBCacheDiscard } from '../enum/Enums';
import { ConfigRecord } from '../SyncTaskManager';
import { Context } from '@kit.AbilityKit';
import { Constants } from '../Constants';
import { FTDBTaskPoolExecutor } from './FTDBTaskPoolExecutor';

// Re-export enum types for external use
export { DBCacheDiscard, LogCacheDiscard, RUMCacheDiscard } from '../enum/Enums';

const TAG = "FTDBCachePolicy";

interface FTDBCachePolicyRuntime {
  queryTotalCount(context: Context, dataTypes: string[]): Promise<number>;
  deleteOldestSyncData(context: Context, dataTypes: string[], limit: number): Promise<number>;
  getCurrentDatabaseSize(context: Context): Promise<number>;
}

class DefaultFTDBCachePolicyRuntime implements FTDBCachePolicyRuntime {
  async queryTotalCount(context: Context, dataTypes: string[]): Promise<number> {
    return await FTDBTaskPoolExecutor.queryTotalCount(context, dataTypes);
  }

  async deleteOldestSyncData(context: Context, dataTypes: string[], limit: number): Promise<number> {
    return await FTDBTaskPoolExecutor.deleteOldestSyncData(context, dataTypes, limit);
  }

  async getCurrentDatabaseSize(context: Context): Promise<number> {
    return await FTDBTaskPoolExecutor.getCurrentDatabaseSize(context);
  }
}

let ftDBCachePolicyRuntime: FTDBCachePolicyRuntime = new DefaultFTDBCachePolicyRuntime();

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
  private countsInitialized: boolean = false;
  private countsInitPromise: Promise<void> | null = null;

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
    this.resetCountInitialization();
  }

  public static getInstance(): FTDBCachePolicy {
    if (!FTDBCachePolicy.instance) {
      FTDBCachePolicy.instance = new FTDBCachePolicy();
    }
    return FTDBCachePolicy.instance;
  }

  public static setRuntimeInternal(runtime: Object): void {
    ftDBCachePolicyRuntime = runtime as FTDBCachePolicyRuntime;
  }

  public static resetRuntimeInternal(): void {
    ftDBCachePolicyRuntime = new DefaultFTDBCachePolicyRuntime();
  }

  private resetCountInitialization(): void {
    this.logCount = 0;
    this.rumCount = 0;
    this.currentDbSize = 0;
    this.countsInitialized = false;
    this.countsInitPromise = null;
    FTInnerLogger.d(TAG, `Reset count initialization: logCount=${this.logCount}, rumCount=${this.rumCount}`);
  }

  /**
   * Hydrates the in-memory counters once after SDK startup. Subsequent cache
   * decisions use deltas from successful writes/deletes rather than COUNT(*).
   */
  public async ensureCountsInitialized(context: Context): Promise<void> {
    if (this.enableLimitWithDbSize || this.countsInitialized) {
      return;
    }
    if (this.countsInitPromise !== null) {
      await this.countsInitPromise;
      return;
    }

    this.countsInitPromise = this.loadCountsFromDb(context);
    try {
      await this.countsInitPromise;
    } finally {
      this.countsInitPromise = null;
    }
  }

  private async loadCountsFromDb(context: Context): Promise<void> {
    this.logCount = await ftDBCachePolicyRuntime.queryTotalCount(context, this.toDataTypeStrings([DataType.LOG]));
    this.rumCount = await ftDBCachePolicyRuntime.queryTotalCount(
      context,
      this.toDataTypeStrings([DataType.RUM_APP, DataType.RUM_WEBVIEW])
    );
    this.countsInitialized = true;
    FTInnerLogger.d(TAG, `Initialized counts from DB: logCount=${this.logCount}, rumCount=${this.rumCount}`);
  }

  private toDataTypeStrings(types: DataType | DataType[]): string[] {
    const source = Array.isArray(types) ? types : [types];
    const result: string[] = [];
    for (let i = 0; i < source.length; i++) {
      result.push(source[i].toString());
    }
    return result;
  }

  private async refreshDbSize(context: Context): Promise<void> {
    if (!this.enableLimitWithDbSize) {
      return;
    }
    this.currentDbSize = Math.max(0, await ftDBCachePolicyRuntime.getCurrentDatabaseSize(context));
  }

  /**
   * Initialize SDK parameters
   * 
   * @param config SDK configuration
   */
  public initSDKParams(config: ConfigRecord): void {
    this.enableLimitWithDbSize = config.isLimitWithDbSize();
    this.dbLimitSize = config.getDbCacheLimit();
    this.logLimitCount = Constants.DEFAULT_DB_LOG_CACHE_NUM;
    this.rumLimitCount = Constants.DEFAULT_DB_RUM_CACHE_NUM;
    // Convert string values to enum types
    const dbCacheDiscardStr = config.getDBCacheDiscard();
    const logCacheDiscardStr = config.getLogCacheDiscard();

    this.dbCacheDiscard = (dbCacheDiscardStr === "discard_oldest") ? DBCacheDiscard.DISCARD_OLDEST : DBCacheDiscard.DISCARD;
    this.logCacheDiscardStrategy =
      logCacheDiscardStr === LogCacheDiscard.DISCARD_OLDEST ? LogCacheDiscard.DISCARD_OLDEST : LogCacheDiscard.DISCARD;
    this.rumCacheDiscardStrategy = RUMCacheDiscard.DISCARD;
    this.resetCountInitialization();

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
      return false;
    }
    return this.currentDbSize >= this.dbLimitSize;
  }

  /**
   * Check if log count limit is reached
   */
  public isReachLogLimit(): boolean {
    if (this.enableLimitWithDbSize) {
      return false;
    }
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
    if (this.enableLimitWithDbSize) {
      return false;
    }
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
    // If DB size limit is enabled, count limits are ignored.
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
    // If DB size limit is enabled, count limits are ignored.
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
   * Get database cache limit size
   */
  public getDbLimitSize(): number {
    return this.dbLimitSize;
  }

  /**
   * Get database cache discard strategy.
   */
  public getDBCacheDiscard(): string {
    return this.dbCacheDiscard;
  }

  /**
   * Sync in-memory count cache from DB while the DB write lock is held.
   * This keeps write-side cache policy decisions atomic without exposing the
   * count fields as mutable public state.
   */
  public syncCountsFromDbInternal(logCount?: number, rumCount?: number): void {
    if (logCount !== undefined) {
      this.logCount = Math.max(0, logCount);
    }
    if (rumCount !== undefined) {
      this.rumCount = Math.max(0, rumCount);
    }
    if (logCount !== undefined && rumCount !== undefined) {
      this.countsInitialized = true;
    }
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
      await this.refreshDbSize(context);
      if (this.isReachDbLimit()) {
        FTInnerLogger.w(TAG, ` optRUMCachePolicy: DB limit reached! currentSize=${this.currentDbSize}, limitSize=${this.dbLimitSize}, discard=${this.dbCacheDiscard}`);
        switch (this.dbCacheDiscard) {
          case DBCacheDiscard.DISCARD:
            FTInnerLogger.w(TAG, ` optRUMCachePolicy: returning -1 (DB DISCARD)`);
            return -1;
          case DBCacheDiscard.DISCARD_OLDEST:
            const deleteCount = Constants.DB_OLD_CACHE_REMOVE_COUNT;
            const beforeLogCount = await ftDBCachePolicyRuntime.queryTotalCount(
              context,
              this.toDataTypeStrings([DataType.LOG])
            );
            if (beforeLogCount > 0) {
              FTInnerLogger.w(TAG, ` optRUMCachePolicy: deleting oldest ${deleteCount} log records first (DB size limit exceeded)`);
              await ftDBCachePolicyRuntime.deleteOldestSyncData(
                context,
                this.toDataTypeStrings(DataType.LOG),
                deleteCount
              );
              const logCount = await ftDBCachePolicyRuntime.queryTotalCount(
                context,
                this.toDataTypeStrings([DataType.LOG])
              );
              this.logCount = logCount;
              if (logCount < beforeLogCount) {
                return 1;
              }
            }

            FTInnerLogger.w(TAG, ` optRUMCachePolicy: deleting oldest ${deleteCount} RUM records (DB size limit exceeded)`);
            await ftDBCachePolicyRuntime.deleteOldestSyncData(
              context,
              this.toDataTypeStrings([DataType.RUM_APP, DataType.RUM_WEBVIEW]),
              deleteCount
            );
            const rumCount = await ftDBCachePolicyRuntime.queryTotalCount(
              context,
              this.toDataTypeStrings([DataType.RUM_APP, DataType.RUM_WEBVIEW])
            );
            this.rumCount = rumCount;
            return 1;
        }
      }
      // FTInnerLogger.d(TAG, ` optRUMCachePolicy: size limits not reached, returning 0`);
      return 0;
    }

    // Count-based limit logic
    await this.ensureCountsInitialized(context);
    let status = 0;
    const currentRUMCount = this.rumCount;
    if (currentRUMCount >= this.rumLimitCount) {
      if (this.rumCacheDiscardStrategy === RUMCacheDiscard.DISCARD) {
        status = -1;
      } else {
        await ftDBCachePolicyRuntime.deleteOldestSyncData(
          context,
          this.toDataTypeStrings([DataType.RUM_APP, DataType.RUM_WEBVIEW]),
          limit
        );
        const rumCount = await ftDBCachePolicyRuntime.queryTotalCount(
          context,
          this.toDataTypeStrings([DataType.RUM_APP, DataType.RUM_WEBVIEW])
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
      await this.refreshDbSize(context);
      if (this.isReachDbLimit()) {
        FTInnerLogger.w(TAG, ` optLogCachePolicy: DB limit reached! currentSize=${this.currentDbSize}, limitSize=${this.dbLimitSize}, discard=${this.dbCacheDiscard}`);
        switch (this.dbCacheDiscard) {
          case DBCacheDiscard.DISCARD:
            FTInnerLogger.w(TAG, ` optLogCachePolicy: returning -${limit} (DB DISCARD)`);
            return -limit;
          case DBCacheDiscard.DISCARD_OLDEST:
            const deleteCount = Constants.DB_OLD_CACHE_REMOVE_COUNT;
            FTInnerLogger.w(TAG, ` optLogCachePolicy: deleting oldest ${deleteCount} records (DB size limit exceeded)`);
            await ftDBCachePolicyRuntime.deleteOldestSyncData(
              context,
              this.toDataTypeStrings(DataType.LOG),
              deleteCount
            );
            const logCount = await ftDBCachePolicyRuntime.queryTotalCount(
              context,
              this.toDataTypeStrings([DataType.LOG])
            );
            this.logCount = logCount;
            return limit;
        }
      }
      //FTInnerLogger.d(TAG, ` optLogCachePolicy: size limits not reached, returning 0`);
      return 0;
    }

    // Count-based limit logic
    await this.ensureCountsInitialized(context);
    let status = 0;
    const currentLogCount = this.logCount;
    if (currentLogCount >= this.logLimitCount) {
      if (this.logCacheDiscardStrategy === LogCacheDiscard.DISCARD) {
        status = -limit;
      } else {
        await ftDBCachePolicyRuntime.deleteOldestSyncData(context, this.toDataTypeStrings(DataType.LOG), limit);
        const logCount = await ftDBCachePolicyRuntime.queryTotalCount(
          context,
          this.toDataTypeStrings([DataType.LOG])
        );
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
          await ftDBCachePolicyRuntime.deleteOldestSyncData(context, this.toDataTypeStrings(DataType.LOG), needRemove);
          const logCount = await ftDBCachePolicyRuntime.queryTotalCount(
            context,
            this.toDataTypeStrings([DataType.LOG])
          );
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
    
    if (this.enableLimitWithDbSize) {
      const dbLimitReached = this.isReachDbLimit();
      if (dbLimitReached) {
        if (this.dbCacheDiscard === DBCacheDiscard.DISCARD) {
          FTInnerLogger.d(TAG, `DB size limit reached with DISCARD strategy, should discard data`);
          return true;
        }
        FTInnerLogger.d(TAG, `DB size limit reached with DISCARD_OLDEST strategy, will clean old data`);
        return false;
      }
    }

    if (this.enableLimitWithDbSize) {
      return false;
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
   * Fast, side-effect-free admission check used before creating a DB task.
   * DISCARD_OLDEST deliberately returns false because it still needs the DB
   * transaction that evicts old rows and persists the newest draft.
   */
  public isCacheDiscardingAtLimit(dataType: DataType): boolean {
    if (this.enableLimitWithDbSize) {
      return this.currentDbSize >= this.dbLimitSize && this.dbCacheDiscard === DBCacheDiscard.DISCARD;
    }
    if (dataType === DataType.LOG) {
      return this.logLimitCount > 0 && this.logCount >= this.logLimitCount &&
        this.logCacheDiscardStrategy === LogCacheDiscard.DISCARD;
    }
    return this.rumLimitCount > 0 && this.rumCount >= this.rumLimitCount &&
      this.rumCacheDiscardStrategy === RUMCacheDiscard.DISCARD;
  }

  /** Compatibility helper for the EVENT RUM response path. */
  public isRumCacheDiscardingAtLimit(): boolean {
    return this.isCacheDiscardingAtLimit(DataType.RUM_APP);
  }

  /**
   * Reset all counts (for testing)
   */
  public resetCounts(): void {
    this.logCount = 0;
    this.rumCount = 0;
    this.currentDbSize = 0;
    this.countsInitialized = false;
    this.countsInitPromise = null;
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
    if (this.enableLimitWithDbSize) {
      FTInnerLogger.d(TAG, `Log cache limit count ignored because DB size limit is enabled`);
      return;
    }
    this.logLimitCount = logCacheLimitCount;
    FTInnerLogger.d(TAG, `Log cache limit count updated: ${this.logLimitCount}`);
  }

  /**
   * Update RUM cache limit count from FTRUMConfig.
   * Called by FTSDK.installRUMConfig() to update RUM cache policy.
   *
   * @param rumCacheLimitCount RUM cache entry count limit
   */
  public updateRumCacheLimitCount(rumCacheLimitCount: number): void {
    if (this.enableLimitWithDbSize) {
      FTInnerLogger.d(TAG, `RUM cache limit count ignored because DB size limit is enabled`);
      return;
    }
    this.rumLimitCount = rumCacheLimitCount;
    FTInnerLogger.d(TAG, `RUM cache limit count updated: ${this.rumLimitCount}`);
  }

  /**
   * Update log cache discard strategy from FTLoggerConfig.
   */
  public updateLogCacheDiscardStrategy(logCacheDiscardStrategy: LogCacheDiscard | string): void {
    this.logCacheDiscardStrategy =
      String(logCacheDiscardStrategy) === LogCacheDiscard.DISCARD_OLDEST ? LogCacheDiscard.DISCARD_OLDEST :
        LogCacheDiscard.DISCARD;
    FTInnerLogger.d(TAG, `Log cache discard strategy updated: ${this.logCacheDiscardStrategy}`);
  }

  /**
   * Update RUM cache discard strategy from FTRUMConfig.
   */
  public updateRumCacheDiscardStrategy(rumCacheDiscardStrategy: RUMCacheDiscard): void {
    this.rumCacheDiscardStrategy = rumCacheDiscardStrategy;
    FTInnerLogger.d(TAG, `RUM cache discard strategy updated: ${this.rumCacheDiscardStrategy}`);
  }

  /**
   * Set database cache size limit for testing purposes
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
    this.dbCacheDiscard = DBCacheDiscard.DISCARD;
    this.logCacheDiscardStrategy = LogCacheDiscard.DISCARD;
    this.rumCacheDiscardStrategy = RUMCacheDiscard.DISCARD;
    this.countsInitialized = false;
    this.countsInitPromise = null;
    FTInnerLogger.d(TAG, ` Test configuration reset to defaults`);
  }
}
