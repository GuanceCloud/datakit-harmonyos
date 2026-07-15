/**
 * HarmonyOS SDK Database Manager Class
 * Database Manager for HarmonyOS
 */
import relationalStore from '@ohos.data.relationalStore';
import { DBManager, DBOperationTiming } from './base/DBManager';
import { DatabaseHelper } from './base/DatabaseHelper';
import {
  FTDBTaskPoolCachePolicySnapshot,
  FTDBTaskPoolExecutor,
  FTDBTaskPoolSyncDraftDTO,
  FTDBTaskPoolWriteOptions,
  FTDBTaskPoolWriteResponse
} from './FTDBTaskPoolExecutor';
import * as FTSQL from './FTSQL';
import { SyncData, SyncDataJSON } from './bean/SyncData';
import { ViewBean } from './bean/ViewBean';
import { ActionBean } from './bean/ActionBean';
import { DBCacheDiscard, DataType } from '../enum/Enums';
import { FTInnerLogger } from '../log/FTLogger';
import { FTDBCachePolicy } from './FTDBCachePolicy';
import { Constants } from '../Constants';
import { Utils } from '../utils/Utils';

const TAG = "FTDBManager";
const DELETE_BATCH_CHUNK_SIZE: number = 500;
const DB_WRITE_SLOW_COST_MS: number = 100;
const DB_WRITE_SLOW_QUEUE_WAIT_MS: number = 50;

/**
 * Action counts interface
 */
interface ActionCounts {
  errorCount: number;
  longTaskCount: number;
  resourceCount: number;
}

/**
 * Action info interface
 */
interface ActionInfo {
  startTime: number;
}

export interface SyncDataWriteOptions {
  applyCachePolicy?: boolean;
  reInsert?: boolean;
  dbLaneWaitMs?: number;
  forceTransaction?: boolean;
  updateOrInsertByUuid?: boolean;
  /** Persisted inside the RUM batch transaction when the batch carries errors. */
  lastErrorTimeLine?: number;
  /** Replay must not recursively spool the same inflight batch on DB failure. */
  skipFailureFallback?: boolean;
}

export interface SyncDataWriteFailureFallback {
  appendSyncDataJSON(source: string, records: SyncDataJSON[]): Promise<number>;
}

export interface SyncDataWriteResult {
  success: boolean;
  source: string;
  requested: number;
  inserted: number;
  updated: number;
  dropped: number;
  duplicateSkipped: number;
  deletedOld: number;
  errorMessage: string;
  /** Number of rows durably accepted by the active/inflight fallback spool. */
  fallbackPersisted?: number;
}

enum SyncDataCacheCategory {
  LOG = 'log',
  RUM = 'rum',
  NONE = 'none'
}

interface SyncDataCacheCountDelta {
  log: number;
  rum: number;
}

interface SyncDataWriteTiming extends DBOperationTiming {
  computeMs: number;
  executeMs: number;
  insertMs: number;
}

export class RUMCounterDelta {
  viewId: string = "";
  actionId: string = "";
  viewErrorDelta: number = 0;
  actionErrorDelta: number = 0;
  viewLongTaskDelta: number = 0;
  actionLongTaskDelta: number = 0;
  viewResourceDelta: number = 0;
  actionResourceDelta: number = 0;
  viewPendingDelta: number = 0;
  actionPendingDelta: number = 0;
  viewActionDelta: number = 0;
  viewUpdateTimeDelta: number = 0;
}

/**
 * HarmonyOS SDK Database Manager
 * Inherits from DBManager, implements specific business logic
 */
export class FTDBManager extends DBManager {
  private static instance: FTDBManager | null = null;
  private static forcedSyncDataWriteFailureCount: number = 0;
  private databaseHelper: DatabaseHelper | null = null;
  private readonly context: Context;
  private initPromise: Promise<void> | null = null;
  private syncDataWriteFailureFallback: SyncDataWriteFailureFallback | null = null;

  // Deduplication cache, updated only from the DB write section.
  // Key format: "dataType:uniqueId" (e.g., "rum_app:action_id=xxx" or "log:uuid=xxx")
  private insertedDataIds: Map<string, boolean> = new Map();

  // Maximum size for Map collections to prevent memory leak (using Constants.MAX_MAP_SIZE_DB)

  private constructor(context: Context) {
    super();
    this.context = context;
  }

  public static resetInstanceInternal(): void {
    FTDBManager.instance = null;
    FTDBManager.forcedSyncDataWriteFailureCount = 0;
    DatabaseHelper.resetInstanceInternal();
  }

  public static forceNextSyncDataWriteFailureInternal(): void {
    FTDBManager.forcedSyncDataWriteFailureCount++;
  }

  /**
   * Get FTDBManager singleton instance
   * @param context Application context
   * @returns FTDBManager instance
   */
  public static getInstance(context: Context): FTDBManager {
    if (!FTDBManager.instance) {
      FTDBManager.instance = new FTDBManager(context);
      // Initialize database helper immediately
      FTDBManager.instance.databaseHelper = DatabaseHelper.getInstance(context);
    }
    return FTDBManager.instance;
  }

  public setSyncDataWriteFailureFallback(fallback: SyncDataWriteFailureFallback | null): void {
    this.syncDataWriteFailureFallback = fallback;
  }

  /**
   * Initialize database manager
   * Uses a promise-based lock to prevent concurrent initialization
   */
  public async init(): Promise<void> {
    // If already initializing, wait for the existing init to complete
    if (this.initPromise) {
      return await this.initPromise;
    }

    // If already initialized (database helper has rdbStore), return immediately
    if (this.databaseHelper) {
      const rdbStore = this.databaseHelper.getRdbStore();
      if (rdbStore) {
        return;
      }
    }

    // Start initialization
    this.initPromise = (async () => {
      try {
        this.databaseHelper = DatabaseHelper.getInstance(this.context);
        await this.databaseHelper.initDatabase();
        FTInnerLogger.i(TAG, "FTDBManager initialized successfully");
      } catch (error) {
        FTInnerLogger.e(TAG, `Failed to initialize FTDBManager: ${error}`);
        throw new Error(`FTDBManager initialization failed: ${error}`);
      }
    })();

    try {
      await this.initPromise;
    } finally {
      // Clear the promise after initialization completes (success or failure)
      this.initPromise = null;
    }
  }

  /**
   * Initialize database helper
   * @returns Promise<relationalStore.RdbStore>
   */
  protected async initDataBaseHelper(): Promise<relationalStore.RdbStore> {
    if (!this.databaseHelper) {
      throw new Error("DatabaseHelper not initialized");
    }
    return await this.databaseHelper.initDatabase();
  }

  protected resetDatabaseConnection(): void {
    super.resetDatabaseConnection();
    if (!this.isNoLockShutdownSimulationForTest()) {
      this.databaseHelper?.resetConnection();
    }
    this.initPromise = null;
  }

  /**
   * Whether database size limit is enabled
   * @returns boolean
   */
  protected enableDBSizeLimit(): boolean {
    const cachePolicy = FTDBCachePolicy.getInstance();
    return cachePolicy.isEnableLimitWithDbSize();
  }

  /**
   * Database size change callback
   * @param rdbStore Database object
   * @param fileSize File size
   */
  protected async onDBSizeCacheChange(
    rdbStore: relationalStore.RdbStore,
    fileSize: number,
    timing?: DBOperationTiming
  ): Promise<void> {
    //FTInnerLogger.d(TAG, `Database size change: ${(fileSize / 1024).toFixed(2)}KB`);

    // Update cache policy with current size (aligned with Android: setCurrentDBSize)
    FTDBCachePolicy.getInstance().setCurrentDbSize(fileSize);

    const cachePolicy = FTDBCachePolicy.getInstance();
    if (cachePolicy.isReachDbLimit()) {
      if (cachePolicy.getDBCacheDiscard() === DBCacheDiscard.DISCARD_OLDEST) {
        FTInnerLogger.w(TAG, `DB cache size limit reached, cleaning oldest data`);
        await this.cleanupOldData(rdbStore, timing);
      }
    }
  }

  /**
   * Clean up old data
   * @param rdbStore Database object
   */
  private async cleanupOldData(rdbStore: relationalStore.RdbStore, timing?: DBOperationTiming): Promise<void> {
    try {
      // Delete oldest data, keep the latest
      const cleanupStartTime = Date.now();
      const result = await rdbStore.executeSql(
        `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}
         WHERE _id IN (
           SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}
           ORDER BY tm ASC
           LIMIT 100
         )`
      );
      if (timing) {
        timing.cleanupMs += Math.max(0, Date.now() - cleanupStartTime);
      }
      FTInnerLogger.i(TAG, `Old data cleaned, affected rows: ${result}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to cleanup old data: ${error}`);
    }
  }

  /**
   * Extract unique identifier from line protocol data string for deduplication
   * @param dataType Data type
   * @param dataString Line protocol data string
   * @returns Unique identifier string, or null if cannot extract
   */
  /**
   * Extract unique identifier from line protocol data string for deduplication
   * Strategy: Priority 1) Business ID (action_id, view_id, etc.), Priority 2) timestamp
   * @param dataType Data type
   * @param dataString Line protocol data string
   * @returns Unique identifier string, or null if cannot extract
   */
  private extractUniqueId(dataType: DataType, dataString: string): string | null {
    try {
      // For action data: extract action_id (priority 1)
      if (dataString.startsWith('action,')) {
        const actionIdMatch = dataString.match(/action_id=([^,\s]+)/);
        if (actionIdMatch && actionIdMatch[1]) {
          return `action_id=${actionIdMatch[1]}`;
        }
      }

      // For view data: extract view_id (priority 1)
      if (dataString.startsWith('view,')) {
        const viewIdMatch = dataString.match(/view_id=([^,\s]+)/);
        if (viewIdMatch && viewIdMatch[1]) {
          return `view_id=${viewIdMatch[1]}`;
        }
      }

      // For resource data: extract span_id or trace_id (priority 1)
      if (dataString.startsWith('resource,')) {
        const spanIdMatch = dataString.match(/span_id=([^,\s]+)/);
        if (spanIdMatch && spanIdMatch[1]) {
          return `span_id=${spanIdMatch[1]}`;
        }
        const traceIdMatch = dataString.match(/trace_id=([^,\s]+)/);
        if (traceIdMatch && traceIdMatch[1]) {
          return `trace_id=${traceIdMatch[1]}`;
        }
      }

      // For error data: extract error_type + error_message + timestamp (priority 1)
      if (dataString.startsWith('error,')) {
        const errorTypeMatch = dataString.match(/error_type=([^,\s]+)/);
        const errorMessageMatch = dataString.match(/error_message="([^"]+)"/);
        const timestampMatch = dataString.match(/\s(\d+)$/); // Last field is timestamp

        const errorType = errorTypeMatch ? errorTypeMatch[1] : '';
        const errorMessage = errorMessageMatch ? errorMessageMatch[1].substring(0, 100) : ''; // Limit length
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (errorType || errorMessage || timestamp) {
          return `error_type=${errorType}:error_message=${errorMessage}:timestamp=${timestamp}`;
        }
      }

      // For longtask data: extract long_task_name + timestamp (priority 1)
      if (dataString.startsWith('longtask,') || dataString.startsWith('long_task,')) {
        const longTaskNameMatch = dataString.match(/long_task_name=([^,\s]+)/);
        const timestampMatch = dataString.match(/\s(\d+)$/); // Last field is timestamp

        const longTaskName = longTaskNameMatch ? longTaskNameMatch[1] : '';
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (longTaskName || timestamp) {
          return `long_task_name=${longTaskName}:timestamp=${timestamp}`;
        }
      }

      // For log data: use uuid (extract from sdk_data_id) (priority 1)
      if (dataString.startsWith('df_rum_harmonyos_log,')) {
        const sdkDataIdMatch = dataString.match(/sdk_data_id=([^,\s]+)/);
        if (sdkDataIdMatch && sdkDataIdMatch[1]) {
          // Extract UUID from sdk_data_id (format: "xxx.uuid" or just "uuid")
          const uuidMatch = sdkDataIdMatch[1].match(/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i);
          if (uuidMatch && uuidMatch[1]) {
            return `uuid=${uuidMatch[1]}`;
          }
          // Fallback: use sdk_data_id as unique identifier
          return `sdk_data_id=${sdkDataIdMatch[1]}`;
        }
      }

      // Priority 2: Use timestamp as fallback for all data types
      // All line protocol data ends with timestamp, so this is a reliable fallback
      const timestampMatch = dataString.match(/\s(\d+)$/);
      if (timestampMatch && timestampMatch[1]) {
        return `timestamp=${timestampMatch[1]}`;
      }

      // Last resort: return null (should rarely happen)
      return null;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error extracting unique ID: ${error as string}`);
      return null;
    }
  }

  private createSyncDataWriteResult(source: string, requested: number): SyncDataWriteResult {
    return {
      success: true,
      source,
      requested,
      inserted: 0,
      updated: 0,
      dropped: 0,
      duplicateSkipped: 0,
      deletedOld: 0,
      errorMessage: ''
    };
  }

  private createSyncDataWriteTiming(): SyncDataWriteTiming {
    return {
      computeMs: 0,
      executeMs: 0,
      insertMs: 0,
      lockWaitMs: 0,
      sizeCheckMs: 0,
      cleanupMs: 0
    };
  }

  private addWriteComputeTime(timing: SyncDataWriteTiming | undefined, startTime: number): void {
    if (!timing) {
      return;
    }
    timing.computeMs += Math.max(0, Date.now() - startTime);
  }

  private addWriteExecuteTime(timing: SyncDataWriteTiming | undefined, startTime: number): void {
    if (!timing) {
      return;
    }
    timing.executeMs += Math.max(0, Date.now() - startTime);
  }

  private addWriteInsertTime(timing: SyncDataWriteTiming | undefined, startTime: number): void {
    if (!timing) {
      return;
    }
    timing.insertMs += Math.max(0, Date.now() - startTime);
  }

  private getCacheCategory(dataType: DataType): SyncDataCacheCategory {
    if (dataType === DataType.LOG) {
      return SyncDataCacheCategory.LOG;
    }
    if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      return SyncDataCacheCategory.RUM;
    }
    return SyncDataCacheCategory.NONE;
  }

  private getStoredCacheCategory(dataTypeString: string): SyncDataCacheCategory {
    if (dataTypeString === DataType.LOG.toString()) {
      return SyncDataCacheCategory.LOG;
    }
    if (dataTypeString === DataType.RUM_APP.toString() || dataTypeString === DataType.RUM_WEBVIEW.toString()) {
      return SyncDataCacheCategory.RUM;
    }
    return SyncDataCacheCategory.NONE;
  }

  private createCacheCountDelta(): SyncDataCacheCountDelta {
    return {
      log: 0,
      rum: 0
    };
  }

  private addCacheCountDelta(
    countDelta: SyncDataCacheCountDelta,
    category: SyncDataCacheCategory,
    delta: number
  ): void {
    if (delta === 0) {
      return;
    }
    if (category === SyncDataCacheCategory.LOG) {
      countDelta.log += delta;
    } else if (category === SyncDataCacheCategory.RUM) {
      countDelta.rum += delta;
    }
  }

  private addDeletedCacheCountDelta(
    countDelta: SyncDataCacheCountDelta,
    types: DataType[],
    deletedCount: number
  ): void {
    if (deletedCount <= 0 || !types || types.length === 0) {
      return;
    }

    let hasLog = false;
    let hasRum = false;
    for (const type of types) {
      const category = this.getCacheCategory(type);
      if (category === SyncDataCacheCategory.LOG) {
        hasLog = true;
      } else if (category === SyncDataCacheCategory.RUM) {
        hasRum = true;
      }
    }

    if (hasLog && !hasRum) {
      countDelta.log -= deletedCount;
    } else if (hasRum && !hasLog) {
      countDelta.rum -= deletedCount;
    }
  }

  private addInsertedCacheCountDelta(
    countDelta: SyncDataCacheCountDelta,
    dataList: SyncData[],
    insertedCount: number
  ): void {
    if (insertedCount <= 0) {
      return;
    }
    const count = Math.min(insertedCount, dataList.length);
    for (let i = 0; i < count; i++) {
      const category = this.getStoredCacheCategory(this.getStoredDataTypeString(dataList[i]));
      this.addCacheCountDelta(countDelta, category, 1);
    }
  }

  private applyCacheCountDelta(countDelta: SyncDataCacheCountDelta): void {
    const cachePolicy = FTDBCachePolicy.getInstance();
    if (countDelta.log !== 0) {
      cachePolicy.optLogCount(countDelta.log);
    }
    if (countDelta.rum !== 0) {
      cachePolicy.optRumCount(countDelta.rum);
    }
  }

  private applyCacheCountDeltaForStoredType(dataTypeString: string, delta: number): void {
    const countDelta = this.createCacheCountDelta();
    this.addCacheCountDelta(countDelta, this.getStoredCacheCategory(dataTypeString), delta);
    this.applyCacheCountDelta(countDelta);
  }

  private getStoredDataTypeString(data: SyncData): string {
    const customDataType = data.getCustomDataTypeString();
    return customDataType || data.getDataType().toString();
  }

  private getDedupKeyForData(data: SyncData): string | null {
    const uniqueId = this.extractUniqueId(data.getDataType(), data.getDataString());
    if (!uniqueId) {
      return null;
    }
    return `${this.getStoredDataTypeString(data)}:${uniqueId}`;
  }

  private toDataTypeStrings(types: DataType[]): string[] {
    const result: string[] = [];
    if (!types) {
      return result;
    }
    for (let i = 0; i < types.length; i++) {
      result.push(types[i].toString());
    }
    return result;
  }

  private createTaskPoolCachePolicySnapshot(): FTDBTaskPoolCachePolicySnapshot {
    const cachePolicy = FTDBCachePolicy.getInstance();
    return {
      enableLimitWithDbSize: cachePolicy.isEnableLimitWithDbSize(),
      dbLimitSize: cachePolicy.getDbLimitSize(),
      dbCacheDiscard: cachePolicy.getDBCacheDiscard(),
      logLimitCount: cachePolicy.getLogLimitCount(),
      rumLimitCount: cachePolicy.getRumLimitCount(),
      logDiscardStrategy: String(cachePolicy.getDiscardStrategy(DataType.LOG)),
      rumDiscardStrategy: String(cachePolicy.getDiscardStrategy(DataType.RUM_APP))
    };
  }

  private applyTaskPoolCountDelta(response: FTDBTaskPoolWriteResponse): void {
    this.applyCacheCountDelta({
      log: response.logCountDelta,
      rum: response.rumCountDelta
    });
    if (response.currentDbSize > 0) {
      FTDBCachePolicy.getInstance().setCurrentDbSize(response.currentDbSize);
    }
  }

  private filterTaskPoolDuplicates(
    dataList: SyncData[],
    reInsert: boolean,
    updateOrInsertByUuid: boolean,
    result: SyncDataWriteResult
  ): SyncData[] {
    if (reInsert || updateOrInsertByUuid) {
      return dataList;
    }

    const filtered: SyncData[] = [];
    const seenInBatch: Map<string, boolean> = new Map();
    for (let i = 0; i < dataList.length; i++) {
      const data = dataList[i];
      const key = this.getDedupKeyForData(data);
      if (!key) {
        filtered.push(data);
        continue;
      }
      if (seenInBatch.has(key) || this.insertedDataIds.has(key)) {
        result.duplicateSkipped++;
        continue;
      }
      seenInBatch.set(key, true);
      filtered.push(data);
    }
    return filtered;
  }

  private markTaskPoolDataAsInserted(dataList: SyncData[], reInsert: boolean): void {
    if (reInsert) {
      return;
    }
    for (let i = 0; i < dataList.length; i++) {
      this.markDataAsInsertedLocked(dataList[i]);
    }
  }

  private toSyncDataValuesBucket(data: SyncData): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
    values[FTSQL.RECORD_COLUMN_TM] = data.getTime();
    values[FTSQL.RECORD_COLUMN_DATA_UUID] = data.getUuid();
    values[FTSQL.RECORD_COLUMN_DATA] = data.getDataString();
    values[FTSQL.RECORD_COLUMN_DATA_TYPE] = this.getStoredDataTypeString(data);
    return values;
  }

  private async queryTotalCountLocked(
    rdbStore: relationalStore.RdbStore,
    types: DataType[],
    timing?: SyncDataWriteTiming
  ): Promise<number> {
    const computeStartTime = Date.now();
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    if (types && types.length > 0) {
      const typeValues = types.map(type => type.toString());
      predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, typeValues);
    }
    this.addWriteComputeTime(timing, computeStartTime);

    const executeStartTime = Date.now();
    const resultSet = await rdbStore.query(predicates, ['count(*) as count']);
    try {
      if (resultSet.goToFirstRow()) {
        return resultSet.getLong(0);
      }
      return 0;
    } finally {
      resultSet.close();
      this.addWriteExecuteTime(timing, executeStartTime);
    }
  }

  private async getCurrentDatabaseSizeLocked(
    rdbStore: relationalStore.RdbStore,
    timing?: SyncDataWriteTiming
  ): Promise<number> {
    const executeStartTime = Date.now();
    const resultSet = await rdbStore.querySql("PRAGMA page_count");
    try {
      if (resultSet && resultSet.goToFirstRow()) {
        const pageCount = resultSet.getLong(resultSet.getColumnIndex("page_count"));
        const pageSize = 4096;
        return pageCount * pageSize;
      }
      return 0;
    } finally {
      resultSet?.close();
      this.addWriteExecuteTime(timing, executeStartTime);
    }
  }

  private buildDataTypeWhereClause(types: DataType[]): string {
    if (!types || types.length === 0) {
      return '';
    }
    const typeValues = types.map(type => `'${type.toString()}'`).join(',');
    return `${FTSQL.RECORD_COLUMN_DATA_TYPE} IN (${typeValues})`;
  }

  private async deleteOldestDataLocked(
    rdbStore: relationalStore.RdbStore,
    types: DataType | DataType[],
    limit: number,
    timing?: SyncDataWriteTiming
  ): Promise<number> {
    if (limit <= 0) {
      return 0;
    }
    const computeStartTime = Date.now();
    const typeArray = Array.isArray(types) ? types : [types];
    const whereClause = this.buildDataTypeWhereClause(typeArray);
    const wherePart = whereClause ? ` WHERE ${whereClause}` : '';
    const countSql = `SELECT COUNT(*) as count FROM (
      SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
      ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
    )`;
    this.addWriteComputeTime(timing, computeStartTime);

    let deleteCount = 0;
    let executeStartTime = Date.now();
    const resultSet = await rdbStore.querySql(countSql);
    try {
      if (resultSet.goToFirstRow()) {
        deleteCount = resultSet.getLong(0);
      }
    } finally {
      resultSet.close();
      this.addWriteExecuteTime(timing, executeStartTime);
    }

    if (deleteCount <= 0) {
      return 0;
    }

    const deleteSqlStartTime = Date.now();
    const deleteSql = `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} WHERE _id IN (
      SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
      ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
    )`;
    this.addWriteComputeTime(timing, deleteSqlStartTime);
    executeStartTime = Date.now();
    await rdbStore.executeSql(deleteSql);
    this.addWriteExecuteTime(timing, executeStartTime);
    return deleteCount;
  }

  private markDataAsInsertedLocked(data: SyncData): void {
    const key = this.getDedupKeyForData(data);
    if (!key) {
      return;
    }
    if (!this.insertedDataIds.has(key) && this.insertedDataIds.size >= Constants.MAX_MAP_SIZE_DB) {
      const firstKey = this.insertedDataIds.keys().next().value as string | undefined;
      if (firstKey !== undefined) {
        this.insertedDataIds.delete(firstKey);
      }
    }
    this.insertedDataIds.set(key, true);
  }

  private async resolveAllowedInsertCountLocked(
    rdbStore: relationalStore.RdbStore,
    category: SyncDataCacheCategory,
    requested: number,
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta,
    timing?: SyncDataWriteTiming
  ): Promise<number> {
    const computeStartTime = Date.now();
    if (requested <= 0 || category === SyncDataCacheCategory.NONE) {
      this.addWriteComputeTime(timing, computeStartTime);
      return requested;
    }

    const cachePolicy = FTDBCachePolicy.getInstance();
    const types = category === SyncDataCacheCategory.LOG ? [DataType.LOG] : [DataType.RUM_APP, DataType.RUM_WEBVIEW];
    this.addWriteComputeTime(timing, computeStartTime);

    if (cachePolicy.isEnableLimitWithDbSize()) {
      const currentDbSize = await this.getCurrentDatabaseSizeLocked(rdbStore, timing);
      const sizePolicyStartTime = Date.now();
      cachePolicy.setCurrentDbSize(currentDbSize);
      if (!cachePolicy.isReachDbLimit()) {
        this.addWriteComputeTime(timing, sizePolicyStartTime);
        return requested;
      }

      if (String(cachePolicy.getDBCacheDiscard()) === DBCacheDiscard.DISCARD_OLDEST) {
        this.addWriteComputeTime(timing, sizePolicyStartTime);
        const deleted = await this.deleteOldestDataLocked(rdbStore, types, Constants.DB_OLD_CACHE_REMOVE_COUNT, timing);
        const deletedPolicyStartTime = Date.now();
        result.deletedOld += deleted;
        this.addCacheCountDelta(countDelta, category, -deleted);
        this.addWriteComputeTime(timing, deletedPolicyStartTime);
        return requested;
      }
      this.addWriteComputeTime(timing, sizePolicyStartTime);
      return 0;
    }

    const currentCount = await this.queryTotalCountLocked(rdbStore, types, timing);
    const countPolicyStartTime = Date.now();
    if (category === SyncDataCacheCategory.LOG) {
      cachePolicy.syncCountsFromDbInternal(currentCount, undefined);
      const limit = cachePolicy.getLogLimitCount();
      if (limit <= 0 || currentCount + requested <= limit) {
        this.addWriteComputeTime(timing, countPolicyStartTime);
        return requested;
      }

      const overflow = currentCount + requested - limit;
      if (String(cachePolicy.getDiscardStrategy(DataType.LOG)) === DBCacheDiscard.DISCARD_OLDEST) {
        this.addWriteComputeTime(timing, countPolicyStartTime);
        const deleted = await this.deleteOldestDataLocked(rdbStore, DataType.LOG, overflow, timing);
        const deletedPolicyStartTime = Date.now();
        result.deletedOld += deleted;
        this.addCacheCountDelta(countDelta, category, -deleted);
        this.addWriteComputeTime(timing, deletedPolicyStartTime);
        return requested;
      }
      this.addWriteComputeTime(timing, countPolicyStartTime);
      return Math.max(0, limit - currentCount);
    }

    cachePolicy.syncCountsFromDbInternal(undefined, currentCount);
    const limit = cachePolicy.getRumLimitCount();
    if (limit <= 0 || currentCount + requested <= limit) {
      this.addWriteComputeTime(timing, countPolicyStartTime);
      return requested;
    }

    const overflow = currentCount + requested - limit;
    if (String(cachePolicy.getDiscardStrategy(DataType.RUM_APP)) === DBCacheDiscard.DISCARD_OLDEST) {
      this.addWriteComputeTime(timing, countPolicyStartTime);
      const deleted = await this.deleteOldestDataLocked(rdbStore, types, overflow, timing);
      const deletedPolicyStartTime = Date.now();
      result.deletedOld += deleted;
      this.addCacheCountDelta(countDelta, category, -deleted);
      this.addWriteComputeTime(timing, deletedPolicyStartTime);
      return requested;
    }
    this.addWriteComputeTime(timing, countPolicyStartTime);
    return Math.max(0, limit - currentCount);
  }

  private async applyCachePolicyLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta,
    timing?: SyncDataWriteTiming
  ): Promise<SyncData[]> {
    let computeStartTime = Date.now();
    let logRequested = 0;
    let rumRequested = 0;
    for (const data of dataList) {
      const category = this.getCacheCategory(data.getDataType());
      if (category === SyncDataCacheCategory.LOG) {
        logRequested++;
      } else if (category === SyncDataCacheCategory.RUM) {
        rumRequested++;
      }
    }
    this.addWriteComputeTime(timing, computeStartTime);

    let allowedLogs = await this.resolveAllowedInsertCountLocked(
      rdbStore,
      SyncDataCacheCategory.LOG,
      logRequested,
      result,
      countDelta,
      timing
    );
    let allowedRum = await this.resolveAllowedInsertCountLocked(
      rdbStore,
      SyncDataCacheCategory.RUM,
      rumRequested,
      result,
      countDelta,
      timing
    );

    computeStartTime = Date.now();
    const allowedData: SyncData[] = [];
    for (const data of dataList) {
      const category = this.getCacheCategory(data.getDataType());
      if (category === SyncDataCacheCategory.LOG) {
        if (allowedLogs > 0) {
          allowedLogs--;
          allowedData.push(data);
        } else {
          result.dropped++;
        }
      } else if (category === SyncDataCacheCategory.RUM) {
        if (allowedRum > 0) {
          allowedRum--;
          allowedData.push(data);
        } else {
          result.dropped++;
        }
      } else {
        allowedData.push(data);
      }
    }

    this.addWriteComputeTime(timing, computeStartTime);
    return allowedData;
  }

  private async filterDuplicatesLocked(
    dataList: SyncData[],
    reInsert: boolean,
    result: SyncDataWriteResult,
    timing?: SyncDataWriteTiming
  ): Promise<SyncData[]> {
    if (reInsert) {
      return dataList;
    }

    const filteredDataList: SyncData[] = [];
    const seenInBatch: Map<string, boolean> = new Map();

    for (const data of dataList) {
      const computeStartTime = Date.now();
      const key = this.getDedupKeyForData(data);
      if (!key) {
        filteredDataList.push(data);
        this.addWriteComputeTime(timing, computeStartTime);
        continue;
      }

      if (seenInBatch.has(key) || this.insertedDataIds.has(key)) {
        result.duplicateSkipped++;
        this.addWriteComputeTime(timing, computeStartTime);
        continue;
      }

      seenInBatch.set(key, true);
      filteredDataList.push(data);
      this.addWriteComputeTime(timing, computeStartTime);
    }

    return filteredDataList;
  }

  private async insertPreparedDataLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    reInsert: boolean,
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta,
    timing?: SyncDataWriteTiming
  ): Promise<void> {
    if (!dataList || dataList.length === 0) {
      return;
    }

    if (dataList.length === 1) {
      const data = dataList[0];
      let computeStartTime = Date.now();
      const values = this.toSyncDataValuesBucket(data);
      this.addWriteComputeTime(timing, computeStartTime);
      const executeStartTime = Date.now();
      const rowId = await rdbStore.insert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, values);
      this.addWriteExecuteTime(timing, executeStartTime);
      this.addWriteInsertTime(timing, executeStartTime);
      const numericId = Number(rowId);
      computeStartTime = Date.now();
      if (numericId > 0) {
        data.setId(numericId);
        result.inserted++;
        this.addInsertedCacheCountDelta(countDelta, dataList, 1);
        if (!reInsert) {
          this.markDataAsInsertedLocked(data);
        }
      } else {
        result.errorMessage = `Invalid rowId returned: ${rowId}`;
      }
      this.addWriteComputeTime(timing, computeStartTime);
      return;
    }

    let computeStartTime = Date.now();
    const valuesArray: relationalStore.ValuesBucket[] = [];
    for (const data of dataList) {
      valuesArray.push(this.toSyncDataValuesBucket(data));
    }
    this.addWriteComputeTime(timing, computeStartTime);

    const executeStartTime = Date.now();
    const insertedCount = await rdbStore.batchInsert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, valuesArray);
    this.addWriteExecuteTime(timing, executeStartTime);
    this.addWriteInsertTime(timing, executeStartTime);
    const insertedRows = Math.max(0, insertedCount);
    computeStartTime = Date.now();
    result.inserted += insertedRows;
    this.addInsertedCacheCountDelta(countDelta, dataList, insertedRows);
    if (!reInsert && insertedRows > 0) {
      for (const data of dataList) {
        this.markDataAsInsertedLocked(data);
      }
    }
    this.addWriteComputeTime(timing, computeStartTime);
  }

  private async updatePreparedDataByUuidLocked(
    rdbStore: relationalStore.RdbStore,
    data: SyncData,
    timing?: SyncDataWriteTiming
  ): Promise<number> {
    const computeStartTime = Date.now();
    const uuid = data.getUuid();
    if (!uuid || uuid.length === 0) {
      this.addWriteComputeTime(timing, computeStartTime);
      return 0;
    }

    const values = this.toSyncDataValuesBucket(data);
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_UUID, uuid);
    this.addWriteComputeTime(timing, computeStartTime);

    const executeStartTime = Date.now();
    const updatedRows = await rdbStore.update(values, predicates);
    this.addWriteExecuteTime(timing, executeStartTime);
    return Math.max(0, updatedRows);
  }

  private async updateOrInsertPreparedDataByUuidLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    reInsert: boolean,
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta,
    timing?: SyncDataWriteTiming
  ): Promise<void> {
    if (!dataList || dataList.length === 0) {
      return;
    }

    for (const data of dataList) {
      const updatedRows = await this.updatePreparedDataByUuidLocked(rdbStore, data, timing);
      if (updatedRows > 0) {
        result.updated += updatedRows;
        if (!reInsert) {
          this.markDataAsInsertedLocked(data);
        }
        continue;
      }

      await this.insertPreparedDataLocked(rdbStore, [data], reInsert, result, countDelta, timing);
    }
  }

  private async writeSyncDataLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    options: SyncDataWriteOptions,
    result: SyncDataWriteResult,
    timing?: SyncDataWriteTiming
  ): Promise<void> {
    const initComputeStartTime = Date.now();
    const applyCachePolicy = options.applyCachePolicy === true;
    const reInsert = options.reInsert === true;
    let dataToWrite = dataList;
    const countDelta = this.createCacheCountDelta();
    this.addWriteComputeTime(timing, initComputeStartTime);

    try {
      if (applyCachePolicy) {
        dataToWrite = await this.applyCachePolicyLocked(rdbStore, dataToWrite, result, countDelta, timing);
      }

      if (options.updateOrInsertByUuid === true) {
        await this.updateOrInsertPreparedDataByUuidLocked(rdbStore, dataToWrite, reInsert, result, countDelta, timing);
        return;
      }

      dataToWrite = await this.filterDuplicatesLocked(dataToWrite, reInsert, result, timing);
      await this.insertPreparedDataLocked(rdbStore, dataToWrite, reInsert, result, countDelta, timing);
    } finally {
      if (applyCachePolicy) {
        const applyDeltaStartTime = Date.now();
        this.applyCacheCountDelta(countDelta);
        this.addWriteComputeTime(timing, applyDeltaStartTime);
      }
    }
  }

  public async writeSyncDataAtomically(
    source: string,
    dataList: SyncData[],
    options: SyncDataWriteOptions = {}
  ): Promise<SyncDataWriteResult> {
    const requested = dataList ? dataList.length : 0;
    const result = this.createSyncDataWriteResult(source, requested);
    if (!dataList || dataList.length === 0) {
      return result;
    }

    const startTime = Date.now();
    let dbLaneWaitTime = Math.max(0, options.dbLaneWaitMs || 0);
    const reInsert = options.reInsert === true;
    const updateOrInsertByUuid = options.updateOrInsertByUuid === true;
    const dataToWrite = this.filterTaskPoolDuplicates(dataList, reInsert, updateOrInsertByUuid, result);
    if (FTDBManager.consumeForcedSyncDataWriteFailure()) {
      result.success = false;
      result.errorMessage = 'Forced sync-data DB write failure';
      await this.persistFailedSyncData(source, this.toSyncDataJSONList(dataToWrite), options, result);
      return result;
    }
    let taskPoolResponse: FTDBTaskPoolWriteResponse | null = null;

    try {
      if (dataToWrite.length > 0) {
        const taskPoolOptions: FTDBTaskPoolWriteOptions = {
          applyCachePolicy: options.applyCachePolicy === true,
          reInsert,
          forceTransaction: options.forceTransaction === true || dataToWrite.length > 1,
          updateOrInsertByUuid,
          lastErrorTimeLine: options.lastErrorTimeLine
        };
        taskPoolResponse = await FTDBTaskPoolExecutor.writeSyncData(
          this.context,
          source,
          dataToWrite,
          taskPoolOptions,
          this.createTaskPoolCachePolicySnapshot()
        );
        dbLaneWaitTime = Math.max(dbLaneWaitTime, taskPoolResponse.dbLaneWaitMs || 0);
        const taskPoolResult = taskPoolResponse.result;
        result.success = taskPoolResult.success;
        result.inserted = taskPoolResult.inserted;
        result.updated = taskPoolResult.updated;
        result.dropped += taskPoolResult.dropped;
        result.deletedOld += taskPoolResult.deletedOld;
        result.duplicateSkipped += taskPoolResult.duplicateSkipped;
        result.errorMessage = taskPoolResult.errorMessage;
        if (result.success) {
          this.applyTaskPoolCountDelta(taskPoolResponse);
        }
        if (result.success && result.inserted + result.updated > 0) {
          this.markTaskPoolDataAsInserted(dataToWrite, reInsert);
        }
      }
    } catch (error) {
      result.success = false;
      result.errorMessage = String(error);
    } finally {
      const dbManagerCostTime = Math.max(0, Date.now() - startTime);
      const costTime = dbManagerCostTime + dbLaneWaitTime;
      let computeTime = Math.max(0, taskPoolResponse ? taskPoolResponse.computeMs : 0);
      let executeTime = Math.max(0, taskPoolResponse ? taskPoolResponse.executeMs : 0);
      let insertTime = Math.max(0, taskPoolResponse ? taskPoolResponse.insertMs : 0);
      const lockWaitTime = 0;
      const sizeCheckTime = Math.max(0, taskPoolResponse ? taskPoolResponse.sizeCheckMs : 0);
      const cleanupTime = Math.max(0, taskPoolResponse ? taskPoolResponse.cleanupMs : 0);
      const accountedTime = dbLaneWaitTime + lockWaitTime + computeTime + executeTime + sizeCheckTime + cleanupTime;
      if (accountedTime > costTime && accountedTime > 0) {
        const scalableTime = computeTime + executeTime;
        const fixedTime = dbLaneWaitTime + lockWaitTime + sizeCheckTime + cleanupTime;
        const scale = scalableTime > 0 ? Math.max(0, costTime - fixedTime) / scalableTime : 0;
        computeTime = Math.round(computeTime * scale);
        executeTime = Math.max(0, costTime - fixedTime - computeTime);
      }
      insertTime = Math.min(insertTime, executeTime);
      const waitTime = Math.max(0,
        costTime - dbLaneWaitTime - lockWaitTime - computeTime - executeTime - sizeCheckTime - cleanupTime);
      this.traceSyncDataWriteIfNeeded(
        'DB-WRITE',
        source,
        result,
        dbLaneWaitTime,
        lockWaitTime,
        waitTime,
        computeTime,
        executeTime,
        insertTime,
        sizeCheckTime,
        cleanupTime,
        costTime
      );
    }

    if (!result.success) {
      await this.persistFailedSyncData(source, this.toSyncDataJSONList(dataToWrite), options, result);
    }

    return result;
  }

  public async writeSyncDraftsAtomically(
    source: string,
    drafts: FTDBTaskPoolSyncDraftDTO[],
    fallbackDataType: DataType,
    options: SyncDataWriteOptions = {}
  ): Promise<SyncDataWriteResult> {
    const requested = drafts ? drafts.length : 0;
    const result = this.createSyncDataWriteResult(source, requested);
    if (!drafts || drafts.length === 0) {
      return result;
    }
    if (FTDBManager.consumeForcedSyncDataWriteFailure()) {
      result.success = false;
      result.errorMessage = 'Forced sync-data draft DB write failure';
      await this.persistFailedSyncData(
        source,
        this.syncDraftsToSyncDataJSON(drafts, fallbackDataType),
        options,
        result
      );
      return result;
    }

    const startTime = Date.now();
    let dbLaneWaitTime = Math.max(0, options.dbLaneWaitMs || 0);
    const reInsert = options.reInsert === true;
    const updateOrInsertByUuid = options.updateOrInsertByUuid === true;
    let taskPoolResponse: FTDBTaskPoolWriteResponse | null = null;

    try {
      const taskPoolOptions: FTDBTaskPoolWriteOptions = {
        applyCachePolicy: options.applyCachePolicy === true,
        reInsert,
        forceTransaction: options.forceTransaction === true || drafts.length > 1,
        updateOrInsertByUuid,
        lastErrorTimeLine: options.lastErrorTimeLine
      };
      taskPoolResponse = await FTDBTaskPoolExecutor.writeSyncDrafts(
        this.context,
        source,
        drafts,
        fallbackDataType.toString(),
        taskPoolOptions,
        this.createTaskPoolCachePolicySnapshot()
      );
      dbLaneWaitTime = Math.max(dbLaneWaitTime, taskPoolResponse.dbLaneWaitMs || 0);
      const taskPoolResult = taskPoolResponse.result;
      result.success = taskPoolResult.success;
      result.inserted = taskPoolResult.inserted;
      result.updated = taskPoolResult.updated;
      result.dropped += taskPoolResult.dropped;
      result.deletedOld += taskPoolResult.deletedOld;
      result.duplicateSkipped += taskPoolResult.duplicateSkipped;
      result.errorMessage = taskPoolResult.errorMessage;
      if (result.success) {
        this.applyTaskPoolCountDelta(taskPoolResponse);
      }
    } catch (error) {
      result.success = false;
      result.errorMessage = String(error);
    } finally {
      const dbManagerCostTime = Math.max(0, Date.now() - startTime);
      const costTime = dbManagerCostTime + dbLaneWaitTime;
      const computeTime = Math.max(0, taskPoolResponse ? taskPoolResponse.computeMs : 0);
      const executeTime = Math.max(0, taskPoolResponse ? taskPoolResponse.executeMs : 0);
      const insertTime = Math.max(0, taskPoolResponse ? taskPoolResponse.insertMs : 0);
      const sizeCheckTime = Math.max(0, taskPoolResponse ? taskPoolResponse.sizeCheckMs : 0);
      const cleanupTime = Math.max(0, taskPoolResponse ? taskPoolResponse.cleanupMs : 0);
      this.traceSyncDataWriteIfNeeded(
        'DB-WRITE-DRAFTS',
        source,
        result,
        dbLaneWaitTime,
        0,
        0,
        computeTime,
        executeTime,
        insertTime,
        sizeCheckTime,
        cleanupTime,
        costTime
      );
    }

    if (!result.success) {
      await this.persistFailedSyncData(
        source,
        this.syncDraftsToSyncDataJSON(drafts, fallbackDataType),
        options,
        result
      );
    }

    return result;
  }

  private async persistFailedSyncData(
    source: string,
    records: SyncDataJSON[],
    options: SyncDataWriteOptions,
    result: SyncDataWriteResult
  ): Promise<void> {
    if (options.skipFailureFallback === true || records.length === 0) {
      return;
    }
    if (!this.syncDataWriteFailureFallback) {
      const message = `${result.errorMessage || 'DB write failed'}; sync-data fallback is not initialized`;
      result.errorMessage = message;
      FTInnerLogger.e(TAG, message);
      return;
    }
    try {
      const spooled = await this.syncDataWriteFailureFallback.appendSyncDataJSON(source, records);
      result.fallbackPersisted = spooled;
      if (spooled !== records.length) {
        result.errorMessage = `${result.errorMessage || 'DB write failed'}; fallback persisted ${spooled}/${records.length}`;
        FTInnerLogger.e(TAG, result.errorMessage);
        return;
      }
      result.errorMessage = `${result.errorMessage || 'DB write failed'}; spooled ${spooled} record(s)`;
    } catch (error) {
      result.errorMessage = `${result.errorMessage || 'DB write failed'}; fallback failed: ${String(error)}`;
      FTInnerLogger.e(TAG, result.errorMessage);
    }
  }

  private toSyncDataJSONList(records: SyncData[]): SyncDataJSON[] {
    const rows: SyncDataJSON[] = [];
    for (let i = 0; i < records.length; i++) {
      const record = records[i];
      if (record && record.isValid()) {
        rows.push(record.toJSON());
      }
    }
    return rows;
  }

  private syncDraftsToSyncDataJSON(
    drafts: FTDBTaskPoolSyncDraftDTO[],
    fallbackDataType: DataType
  ): SyncDataJSON[] {
    const rows: SyncDataJSON[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i];
      if (!draft || !draft.dataString || !draft.uuid || draft.time <= 0) {
        continue;
      }
      const row: SyncDataJSON = {
        id: 0,
        dataType: this.toDataType(draft.dataType, fallbackDataType),
        dataString: draft.dataString,
        uuid: draft.uuid,
        time: draft.time
      };
      if (draft.customDataType && draft.customDataType.length > 0) {
        row.customDataTypeString = draft.customDataType;
      }
      rows.push(row);
    }
    return rows;
  }

  private toDataType(value: string, fallback: DataType): DataType {
    if (value === DataType.RUM_APP.toString()) {
      return DataType.RUM_APP;
    }
    if (value === DataType.RUM_WEBVIEW.toString()) {
      return DataType.RUM_WEBVIEW;
    }
    if (value === DataType.LOG.toString()) {
      return DataType.LOG;
    }
    return fallback;
  }

  private static consumeForcedSyncDataWriteFailure(): boolean {
    if (FTDBManager.forcedSyncDataWriteFailureCount <= 0) {
      return false;
    }
    FTDBManager.forcedSyncDataWriteFailureCount--;
    return true;
  }

  private traceSyncDataWriteIfNeeded(
    label: string,
    source: string,
    result: SyncDataWriteResult,
    dbLaneWaitTime: number,
    lockWaitTime: number,
    waitTime: number,
    computeTime: number,
    executeTime: number,
    insertTime: number,
    sizeCheckTime: number,
    cleanupTime: number,
    costTime: number
  ): void {
    const hasRisk = !result.success || result.dropped > 0 || result.deletedOld > 0 ||
      result.duplicateSkipped > 0 || result.errorMessage.length > 0;
    const shouldTraceSlow = label !== 'DB-WRITE-DRAFTS';
    const isSlow = shouldTraceSlow &&
      (costTime >= DB_WRITE_SLOW_COST_MS || dbLaneWaitTime >= DB_WRITE_SLOW_QUEUE_WAIT_MS);
    if (!hasRisk && !isSlow) {
      return;
    }

    const errorPart = result.errorMessage.length > 0 ? ` error=${result.errorMessage}` : '';
    const message =
      `[${label}] source=${source} rows=${result.requested} inserted=${result.inserted} updated=${result.updated} ` +
        `dropped=${result.dropped} duplicate=${result.duplicateSkipped} deletedOld=${result.deletedOld} ` +
        `dbLaneWait=${dbLaneWaitTime}ms lockWait=${lockWaitTime}ms wait=${waitTime}ms compute=${computeTime}ms ` +
        `execute=${executeTime}ms insert=${insertTime}ms sizeCheck=${sizeCheckTime}ms cleanup=${cleanupTime}ms ` +
        `total=${costTime}ms cost=${costTime}ms${errorPart}`;
    if (hasRisk) {
      FTInnerLogger.w(TAG, message);
      return;
    }
    FTInnerLogger.d(TAG, message);
  }

  /**
   * Insert sync data
   * @param data Sync data
   * @param reInsert Whether to re-insert
   * @returns boolean
   */
  public async insertFtOperation(data: SyncData, reInsert: boolean = false): Promise<boolean> {
    const result = await this.writeSyncDataAtomically('insertFtOperation', [data], {
      applyCachePolicy: false,
      reInsert
    });
    return result.inserted + result.updated > 0;
  }

  /**
   * Update existing sync data by uuid, or insert it if no row exists.
   * This is mainly used by RUM view data so repeated view summaries update the same upload row.
   */
  public async updateOrInsertSyncData(data: SyncData): Promise<boolean> {
    const result = await this.writeSyncDataAtomically('updateOrInsertSyncData', [data], {
      applyCachePolicy: false,
      reInsert: false,
      forceTransaction: true,
      updateOrInsertByUuid: true
    });
    return result.inserted + result.updated > 0;
  }

  /**
   * Insert or update RUM view data
   * @param viewBean View data
   * @returns Promise<boolean>
   */
  public async insertRumView(viewBean: ViewBean): Promise<boolean> {
    try {
      const result = await FTDBTaskPoolExecutor.upsertRumView(this.context, viewBean);
      if (result) {
        FTInnerLogger.d(TAG, `RUM view upserted: ${viewBean.getId()}`);
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to insert/update RUM view: ${error}`);
      return false;
    }
  }

  /**
   * Try to insert RUM view data
   * @param viewBean View data
   * @returns Promise<boolean>
   */
  private async tryInsertRumView(viewBean: ViewBean): Promise<boolean> {
    return await FTDBTaskPoolExecutor.upsertRumView(this.context, viewBean);
  }

  /**
   * Update RUM view data
   * @param viewBean View data
   * @returns Promise<boolean>
   */
  public async updateRumView(viewBean: ViewBean): Promise<boolean> {
    try {
      const result = await FTDBTaskPoolExecutor.updateRumView(this.context, viewBean);
      if (result) {
        FTInnerLogger.d(TAG, `RUM view updated: ${viewBean.getId()}`);
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to update RUM view: ${error}`);
      return false;
    }
  }

  /**
   * Close view - update view close status in database
   * Aligned with Android implementation
   * @param viewId View ID
   * @param loadTime View load time
   * @param timeSpent View time spent
   * @param attr Extra attributes JSON string
   * @returns Promise<boolean>
   */
  public async closeView(viewId: string, loadTime: number, timeSpent: number, attr: string, newSessionId?: string): Promise<boolean> {
    if (!viewId) {
      return false;
    }

    try {
      const result = await FTDBTaskPoolExecutor.closeRumView(this.context, viewId, loadTime, timeSpent, attr, newSessionId);
      if (result) {
        FTInnerLogger.d(TAG, `View closed: ${viewId}`);
      } else {
        FTInnerLogger.w(TAG, `View not found for close: ${viewId}`);
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to close view: ${error}`);
      return false;
    }
  }

  /**
   * Update View upload time, used to mark when view data was uploaded
   * Aligned with Android: updateViewUploadTime
   * @param viewId View ID
   * @param dateTime Upload time (milliseconds)
   * @returns Promise<boolean>
   */
  public async updateViewUploadTime(viewId: string, dateTime: number): Promise<boolean> {
    if (!viewId) {
      return false;
    }

    try {
      const result = await FTDBTaskPoolExecutor.updateViewUploadTime(this.context, viewId, dateTime);
      if (result) {
        FTInnerLogger.d(TAG, `View upload state updated: ${viewId}`);
      } else {
        FTInnerLogger.w(TAG, `View not found for upload time update: ${viewId}`);
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Update view upload time failed: ${error as string}`);
      return false;
    }
  }

  /**
   * Increase view action count in database
   * Aligned with Android: increaseViewAction
   * @param viewId View ID
   */
  public async increaseViewAction(viewId: string, viewName?: string): Promise<void> {
    if (!viewId) {
      return;
    }

    const viewNameStr = viewName || 'unknown';

    try {
      await FTDBTaskPoolExecutor.increaseViewAction(this.context, viewId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view action count: ${viewNameStr} (${viewId}), ${error}`);
    }
  }

  /**
   * Get view pending_resource count
   * @param viewId View ID
   * @returns pending_resource count, or 0 if view not found
   */
  public async getViewPendingResource(viewId: string): Promise<number> {
    if (!viewId) {
      return 0;
    }
    try {
      return await FTDBTaskPoolExecutor.getRumPendingResource(this.context, 'view', viewId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Get view pending resource failed: ${error as string}`);
      return 0;
    }
  }

  /**
   * Force clear view pending_resource to 0
   * Used when view is closed and resources haven't completed after a timeout period
   * @param viewId View ID
   */
  public async forceClearViewPendingResource(viewId: string): Promise<void> {
    if (!viewId) {
      return;
    }
    try {
      const updateCount = await FTDBTaskPoolExecutor.forceClearRumPendingResource(this.context, 'view', viewId);
      if (updateCount > 0) {
        FTInnerLogger.w(TAG, `Force cleared view pending resource: ${viewId}`);
      } else {
        FTInnerLogger.w(TAG, `View not found when force clearing pending resource: ${viewId}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Force clear view pending resource failed: ${error as string}`);
    }
  }

  /**
   * Get action info (start_time) for calculating duration
   * @param actionId Action ID
   * @returns Action info with startTime, or null if not found
   */
  public async getActionInfo(actionId: string): Promise<ActionInfo | null> {
    if (!actionId) {
      return null;
    }

    try {
      const taskPoolActionInfo = await FTDBTaskPoolExecutor.getActionInfo(this.context, actionId);
      if (taskPoolActionInfo !== null) {
        const actionInfo: ActionInfo = {
          startTime: taskPoolActionInfo.startTime
        };
        return actionInfo;
      }
      return null;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get action info for ${actionId}: ${error}`);
      return null;
    }
  }

  /**
   * Get action pending_resource count
   * @param actionId Action ID
   * @returns pending_resource count, or 0 if action not found
   */
  public async getActionPendingResource(actionId: string): Promise<number> {
    if (!actionId) {
      return 0;
    }
    try {
      return await FTDBTaskPoolExecutor.getRumPendingResource(this.context, 'action', actionId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Get action pending resource failed: ${error as string}`);
      return 0;
    }
  }

  /**
   * Force clear action pending_resource to 0
   * Used when action is closed and resources haven't completed after a timeout period
   * @param actionId Action ID
   */
  public async forceClearActionPendingResource(actionId: string): Promise<void> {
    if (!actionId) {
      return;
    }
    try {
      const updateCount = await FTDBTaskPoolExecutor.forceClearRumPendingResource(this.context, 'action', actionId);
      if (updateCount > 0) {
        FTInnerLogger.w(TAG, `Force cleared action pending resource: ${actionId}`);
      } else {
        FTInnerLogger.w(TAG, `Action not found when force clearing pending resource: ${actionId}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Force clear action pending resource failed: ${error as string}`);
    }
  }

  public async applyRumCounterDeltas(deltas: RUMCounterDelta[]): Promise<void> {
    if (!deltas || deltas.length === 0) {
      return;
    }

    try {
      await FTDBTaskPoolExecutor.applyRumCounterDeltas(this.context, deltas);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to apply RUM counter deltas: ${error}`);
    }
  }

  public async updateViewUpdateTime(viewId: string): Promise<boolean> {
    if (!viewId) {
      return false;
    }

    try {
      return await FTDBTaskPoolExecutor.updateViewUpdateTime(this.context, viewId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to update view update time: ${error}`);
      return false;
    }
  }

  /**
   * Insert RUM action data
   * @param actionBean Action data
   * @returns Promise<boolean>
   */
  public async insertRumAction(actionBean: ActionBean): Promise<boolean> {
    try {
      const result = await FTDBTaskPoolExecutor.insertRumAction(this.context, actionBean);
      if (result) {
        FTInnerLogger.d(TAG, `RUM action generated: ${actionBean.getId()}`);
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to insert RUM action: ${error}`);
      return false;
    }
  }

  /**
   * Close action - update action close status in database
   * Aligned with Android implementation
   * @param actionId Action ID
   * @param duration Action duration
   * @param force Force close (ignore pending resources)
   * @returns Promise<boolean>
   */
  public async closeAction(actionId: string, duration: number, force: boolean): Promise<boolean> {
    if (!actionId) {
      return false;
    }

    try {
      const closeResult = await FTDBTaskPoolExecutor.closeRumAction(this.context, actionId, duration, force);
      if (closeResult.wasClosed) {
        FTInnerLogger.d(TAG, `Action closed: ${actionId}`);
      }

      // If action was closed and had pending_resource, schedule delayed cleanup
      if (closeResult.wasClosed && closeResult.hadPendingResource) {
        // Schedule a delayed task to force clear pending_resource if it's still > 0 after 30 seconds
        // This handles cases where resources never complete (e.g., network failures, timeouts)
        // After action is closed, wait 30 seconds for resources to complete, then force clear pending_resource
        // This allows cleanCloseActionData to delete the action data
        setTimeout(() => {
          (async () => {
            try {
              // Check if action still has pending_resource > 0
              const actionPendingResource = await this.getActionPendingResource(actionId);
              if (actionPendingResource > 0) {
                FTInnerLogger.w(TAG, `Action pending resource timeout, forcing clear: ${actionId}`);
                // Force clear pending_resource to allow cleanCloseActionData to delete the action
                await this.forceClearActionPendingResource(actionId);
              }
            } catch (error) {
              FTInnerLogger.e(TAG, `Delayed action pending resource cleanup failed: ${error}`);
            }
          })();
        }, 30 * 1000);
      }

      return closeResult.wasClosed;
    } catch (error) {
      FTInnerLogger.e(TAG, `Close action failed: ${error as string}`);
      return false;
    }
  }

  /**
   * Close database manager
   */
  public async release(): Promise<void> {
    const instance = FTDBManager.instance;
    if (instance) {
      await instance.shutDown();
      FTDBManager.instance = null;
    }
  }


  /**
   * Reset database (for testing)
   */
  public async resetDatabase(): Promise<void> {
    await this.delete();
  }

  /**
   * Query closed Action data
   * @param limit Limit count
   * @returns Promise<ActionBean[]>
   */
  public async querySumAction(limit: number = 50): Promise<ActionBean[]> {
    try {
      return await FTDBTaskPoolExecutor.querySumAction(this.context, limit);
    } catch (error) {
      FTInnerLogger.e(TAG, `Query sum action failed: ${error as string}`);
      return [];
    }
  }

  /**
   * Query action counts from database by action ID
   * @param actionId Action ID
   * @returns Promise with counts or null if not found
   */
  public async getActionCounts(actionId: string): Promise<ActionCounts | null> {
    try {
      const counts = await FTDBTaskPoolExecutor.getActionCounts(this.context, actionId);
      return counts ? {
        errorCount: counts.errorCount,
        longTaskCount: counts.longTaskCount,
        resourceCount: counts.resourceCount
      } : null;
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to query action counts from database for ${actionId}: ${error}`);
      return null;
    }
  }

  /**
   * Query closed View data
   * @param limit Limit count
   * @returns Promise<ViewBean[]>
   */
  public async querySumView(limit: number = 50): Promise<ViewBean[]> {
    try {
      return await FTDBTaskPoolExecutor.querySumView(this.context, limit);
    } catch (error) {
      FTInnerLogger.e(TAG, `Query sum view failed: ${error as string}`);
      return [];
    }
  }

  /**
   * Query a single view by viewId from database
   * Used to get the latest action_count and error_count after async updates
   * @param viewId View ID
   * @returns Promise<ViewBean | null>
   */
  public async queryRumViewById(viewId: string): Promise<ViewBean | null> {
    if (!viewId) {
      return null;
    }

    try {
      return await FTDBTaskPoolExecutor.queryRumViewById(this.context, viewId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Query RUM view by ID failed: ${error as string}`);
      return null;
    }
  }

  /**
   * Delete processed Action data.
   * Aligned with Android SDK: cleanCloseActionData(String[] ids)
   * @param ids Action ID array. Empty input is ignored.
   */
  public async cleanCloseActionData(ids?: string[]): Promise<void> {
    if (!ids || ids.length === 0) {
      return;
    }

    try {
      const actualDeleted = await FTDBTaskPoolExecutor.cleanCloseActionData(this.context, ids);
      if (actualDeleted !== ids.length) {
        FTInnerLogger.w(TAG, `Clean close action data incomplete: ${actualDeleted}/${ids.length}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Clean close action data failed: ${error as string}`);
    }
  }

  /**
   * Clean up closed View data (aligned with Android: cleanCloseViewData)
   * Aligned with Android SDK: deletes all views where is_close=1 AND pending_resource<=0
   * Additionally, deletes views that have been closed for a long time (5 minutes) even if pending_resource>0
   * This prevents leftover data in stress test scenarios where resources may never complete
   * Android SDK does not check data_upload_time, so we align with that behavior
   * This is called at the end of generateViewSum to clean up all closed views
   * @param ids Optional array of view IDs to delete. If not provided, deletes all closed views
   */
  public async cleanCloseViewData(ids?: string[]): Promise<void> {
    try {
      await FTDBTaskPoolExecutor.cleanCloseViewData(this.context, ids || []);
    } catch (error) {
      FTInnerLogger.e(TAG, `Clean close view data failed: ${error as string}`);
    }
  }

  /**
   * Close all Action and View data (aligned with Android: FTDBManager.closeAllActionAndView)
   * Updates all actions and views to set is_close=1 and pending_resource=0
   */
  public async closeAllActionAndView(): Promise<void> {
    try {
      await FTDBTaskPoolExecutor.closeAllActionAndView(this.context);
      FTInnerLogger.i(TAG, "All actions and views closed");
    } catch (error) {
      FTInnerLogger.e(TAG, `closeAllActionAndView failed: ${error as string}`);
    }
  }

  /**
   * Delete all data from database (for testing/cleanup use)
   * Deletes all data from sync_data_flat, rum_view, and rum_action tables
   * Aligned with Android: FTDBManager.delete()
   */
  public async delete(): Promise<void> {
    try {
      const result = await FTDBTaskPoolExecutor.deleteAll(this.context);
      FTInnerLogger.i(TAG, `All DB data deleted: sync=${result.sync}, view=${result.view}, action=${result.action}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `delete failed: ${error as string}`);
    }
  }

  /**
   * Update data type for error sampled data
   * Changes data type from {type}_error_sampled to {type} for records before errorTimeLine
   * @param errorSampledDataType Original data type string with ERROR_SAMPLED_SUFFIX (e.g., "rum_app_error_sampled")
   * @param errorTimeLine Error time line in nanoseconds
   * @returns Number of records updated
   */
  public async updateDataType(errorSampledDataType: string, errorTimeLine: number): Promise<number> {
    const ERROR_SAMPLED_SUFFIX = "_error_sampled";
    const dataTypeStr = errorSampledDataType;

    // Check if this is an error sampled type
    if (!dataTypeStr.endsWith(ERROR_SAMPLED_SUFFIX)) {
      return 0;
    }

    // Remove suffix to get target type
    const targetDataType = dataTypeStr.replace(ERROR_SAMPLED_SUFFIX, "");

    let updateCount = 0;
    try {
      updateCount = await FTDBTaskPoolExecutor.updateDataType(this.context, dataTypeStr, errorTimeLine);
      this.applyCacheCountDeltaForStoredType(targetDataType, updateCount);
    } catch (error) {
      FTInnerLogger.e(TAG, `updateDataType failed: ${error as string}`);
    }

    return updateCount;
  }

  /**
   * Delete expired cache data
   * Deletes records older than (now - expireDuration)
   * @param dataType Data type string to delete (can be DataType enum or error sampled type string)
   * @param now Current time in nanoseconds
   * @param expireDuration Expiration duration in nanoseconds
   * @returns Number of records deleted
   */
  public async deleteExpireCache(dataType: DataType | string, now: number, expireDuration: number): Promise<number> {
    let deleteCount = 0;

    const dataTypeStr: string = String(dataType);

    try {
      deleteCount = await FTDBTaskPoolExecutor.deleteExpireCache(this.context, dataTypeStr, now, expireDuration);
      this.applyCacheCountDeltaForStoredType(dataTypeStr, -deleteCount);
    } catch (error) {
      FTInnerLogger.e(TAG, `deleteExpireCache failed: ${error as string}`);
    }

    return deleteCount;
  }

  /**
   * Query UUIDs of error/resource/longtask data associated with a specific action_id
   * @param actionId Action ID to search for
   * @param measurementType Measurement type: "error", "resource", or "long_task"
   * @param dataType DataType enum value (e.g., DataType.RUM_APP)
   * @returns Array of UUIDs
   */
  public async queryRelatedUUIDsByActionId(actionId: string, measurementType: string, dataType: DataType): Promise<string[]> {
    if (!actionId || !measurementType) {
      return [];
    }

    try {
      return await FTDBTaskPoolExecutor.queryRelatedUUIDsByActionId(
        this.context,
        actionId,
        measurementType,
        String(dataType)
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `queryRelatedUUIDsByActionId failed: ${error as string}`);
      return [];
    }
  }
}
