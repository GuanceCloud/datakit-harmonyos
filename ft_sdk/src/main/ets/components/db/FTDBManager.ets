/**
 * HarmonyOS SDK Database Manager Class
 * Database Manager for HarmonyOS
 */
import relationalStore from '@ohos.data.relationalStore';
import { DBManager } from './base/DBManager';
import { DataBaseCallBack } from './base/DataBaseCallBack';
import { DatabaseHelper } from './base/DatabaseHelper';
import * as FTSQL from './FTSQL';
import { SyncData } from './bean/SyncData';
import { ViewBean } from './bean/ViewBean';
import { ActionBean } from './bean/ActionBean';
import { DBCacheDiscard, DataType } from '../enum/Enums';
import { FTInnerLogger } from '../log/FTLogger';
import { FTDBCachePolicy } from './FTDBCachePolicy';
import { Constants } from '../Constants';
import { Utils } from '../utils/Utils';

const TAG = "FTDBManager";

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
}

export interface SyncDataWriteResult {
  success: boolean;
  source: string;
  requested: number;
  inserted: number;
  dropped: number;
  duplicateSkipped: number;
  deletedOld: number;
  errorMessage: string;
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

/**
 * HarmonyOS SDK Database Manager
 * Inherits from DBManager, implements specific business logic
 */
export class FTDBManager extends DBManager {
  private static instance: FTDBManager | null = null;
  private databaseHelper: DatabaseHelper | null = null;
  private readonly context: Context;
  private initPromise: Promise<void> | null = null;
  
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
    DatabaseHelper.resetInstanceInternal();
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
  protected onDBSizeCacheChange(rdbStore: relationalStore.RdbStore, fileSize: number): void {
    //FTInnerLogger.d(TAG, `Database size change: ${(fileSize / 1024).toFixed(2)}KB`);
    
    // Update cache policy with current size (aligned with Android: setCurrentDBSize)
    FTDBCachePolicy.getInstance().setCurrentDbSize(fileSize);
    
    const cachePolicy = FTDBCachePolicy.getInstance();
    if (cachePolicy.isReachDbLimit()) {
      if (cachePolicy.getDBCacheDiscard() === DBCacheDiscard.DISCARD_OLDEST) {
        FTInnerLogger.w(TAG, `DB cache size limit reached, cleaning oldest data`);
        this.cleanupOldData(rdbStore);
      }
    }
  }

  /**
   * Clean up old data
   * @param rdbStore Database object
   */
  private async cleanupOldData(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      // Delete oldest data, keep the latest
      const result = await rdbStore.executeSql(
        `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} 
         WHERE _id IN (
           SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} 
           ORDER BY tm ASC 
           LIMIT 100
         )`
      );
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
      dropped: 0,
      duplicateSkipped: 0,
      deletedOld: 0,
      errorMessage: ''
    };
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

  private getDedupKey(dataType: DataType, dataString: string): string | null {
    const uniqueId = this.extractUniqueId(dataType, dataString);
    if (!uniqueId) {
      return null;
    }
    return `${dataType.toString()}:${uniqueId}`;
  }

  private shouldQueryDbForDuplicate(uniqueId: string): boolean {
    return uniqueId.startsWith('action_id=') || uniqueId.startsWith('view_id=');
  }

  private getDuplicateSearchPattern(uniqueId: string): string {
    if (uniqueId.startsWith('action_id=')) {
      return `action_id=${uniqueId.substring(10)}`;
    }
    if (uniqueId.startsWith('view_id=')) {
      return `view_id=${uniqueId.substring(8)}`;
    }
    if (uniqueId.startsWith('uuid=')) {
      return uniqueId.substring(5);
    }
    if (uniqueId.startsWith('error_type=')) {
      return `error_type=${uniqueId.split(':')[0].substring(11)}`;
    }
    if (uniqueId.startsWith('long_task_name=')) {
      return `long_task_name=${uniqueId.split(':')[0].substring(15)}`;
    }
    return uniqueId;
  }

  private toSyncDataValuesBucket(data: SyncData): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
    values[FTSQL.RECORD_COLUMN_TM] = data.getTime();
    values[FTSQL.RECORD_COLUMN_DATA_UUID] = data.getUuid();
    values[FTSQL.RECORD_COLUMN_DATA] = data.getDataString();
    values[FTSQL.RECORD_COLUMN_DATA_TYPE] = this.getStoredDataTypeString(data);
    return values;
  }

  private async queryTotalCountLocked(rdbStore: relationalStore.RdbStore, types: DataType[]): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    if (types && types.length > 0) {
      const typeValues = types.map(type => type.toString());
      predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, typeValues);
    }

    const resultSet = await rdbStore.query(predicates, ['count(*) as count']);
    try {
      if (resultSet.goToFirstRow()) {
        return resultSet.getLong(0);
      }
      return 0;
    } finally {
      resultSet.close();
    }
  }

  private async getCurrentDatabaseSizeLocked(rdbStore: relationalStore.RdbStore): Promise<number> {
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
    limit: number
  ): Promise<number> {
    if (limit <= 0) {
      return 0;
    }
    const typeArray = Array.isArray(types) ? types : [types];
    const whereClause = this.buildDataTypeWhereClause(typeArray);
    const wherePart = whereClause ? ` WHERE ${whereClause}` : '';
    const countSql = `SELECT COUNT(*) as count FROM (
      SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
      ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
    )`;

    let deleteCount = 0;
    const resultSet = await rdbStore.querySql(countSql);
    try {
      if (resultSet.goToFirstRow()) {
        deleteCount = resultSet.getLong(0);
      }
    } finally {
      resultSet.close();
    }

    if (deleteCount <= 0) {
      return 0;
    }

    const deleteSql = `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} WHERE _id IN (
      SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
      ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
    )`;
    await rdbStore.executeSql(deleteSql);
    return deleteCount;
  }

  private async checkDataExistsLocked(
    rdbStore: relationalStore.RdbStore,
    dataType: DataType,
    dataString: string
  ): Promise<boolean> {
    const uniqueId = this.extractUniqueId(dataType, dataString);
    if (!uniqueId) {
      return false;
    }

    const key = `${dataType.toString()}:${uniqueId}`;
    if (this.insertedDataIds.has(key)) {
      return true;
    }

    const searchPattern = this.getDuplicateSearchPattern(uniqueId);
    const escapedPattern = searchPattern.replace(/%/g, '\\%').replace(/_/g, '\\_');
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType.toString());
    predicates.like(FTSQL.RECORD_COLUMN_DATA, `%${escapedPattern}%`);

    const resultSet = await rdbStore.query(predicates, ['_id']);
    try {
      const exists = resultSet.goToFirstRow();
      if (exists) {
        this.insertedDataIds.set(key, true);
      }
      return exists;
    } finally {
      resultSet.close();
    }
  }

  private async deleteDuplicateDataLocked(
    rdbStore: relationalStore.RdbStore,
    dataType: DataType,
    uniqueId: string,
    countDelta?: SyncDataCacheCountDelta
  ): Promise<number> {
    if (!uniqueId.startsWith('action_id=') && !uniqueId.startsWith('view_id=')) {
      return 0;
    }

    const searchPattern = this.getDuplicateSearchPattern(uniqueId);
    const escapedPattern = searchPattern.replace(/%/g, '\\%').replace(/_/g, '\\_');
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType.toString());
    predicates.like(FTSQL.RECORD_COLUMN_DATA, `%${escapedPattern}%`);

    const deletedRows = await rdbStore.delete(predicates);
    if (countDelta) {
      this.addCacheCountDelta(countDelta, this.getCacheCategory(dataType), -deletedRows);
    }
    const key = `${dataType.toString()}:${uniqueId}`;
    this.insertedDataIds.delete(key);
    return deletedRows;
  }

  private markDataAsInsertedLocked(dataType: DataType, dataString: string): void {
    const key = this.getDedupKey(dataType, dataString);
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
    countDelta: SyncDataCacheCountDelta
  ): Promise<number> {
    if (requested <= 0 || category === SyncDataCacheCategory.NONE) {
      return requested;
    }

    const cachePolicy = FTDBCachePolicy.getInstance();
    const types = category === SyncDataCacheCategory.LOG ? [DataType.LOG] : [DataType.RUM_APP, DataType.RUM_WEBVIEW];

    if (cachePolicy.isEnableLimitWithDbSize()) {
      const currentDbSize = await this.getCurrentDatabaseSizeLocked(rdbStore);
      cachePolicy.setCurrentDbSize(currentDbSize);
      if (!cachePolicy.isReachDbLimit()) {
        return requested;
      }

      if (String(cachePolicy.getDBCacheDiscard()) === DBCacheDiscard.DISCARD_OLDEST) {
        const deleted = await this.deleteOldestDataLocked(rdbStore, types, Constants.DB_OLD_CACHE_REMOVE_COUNT);
        result.deletedOld += deleted;
        this.addCacheCountDelta(countDelta, category, -deleted);
        return requested;
      }
      return 0;
    }

    const currentCount = await this.queryTotalCountLocked(rdbStore, types);
    if (category === SyncDataCacheCategory.LOG) {
      cachePolicy.syncCountsFromDbInternal(currentCount, undefined);
      const limit = cachePolicy.getLogLimitCount();
      if (limit <= 0 || currentCount + requested <= limit) {
        return requested;
      }

      const overflow = currentCount + requested - limit;
      if (String(cachePolicy.getDiscardStrategy(DataType.LOG)) === DBCacheDiscard.DISCARD_OLDEST) {
        const deleted = await this.deleteOldestDataLocked(rdbStore, DataType.LOG, overflow);
        result.deletedOld += deleted;
        this.addCacheCountDelta(countDelta, category, -deleted);
        return requested;
      }
      return Math.max(0, limit - currentCount);
    }

    cachePolicy.syncCountsFromDbInternal(undefined, currentCount);
    const limit = cachePolicy.getRumLimitCount();
    if (limit <= 0 || currentCount + requested <= limit) {
      return requested;
    }

    const overflow = currentCount + requested - limit;
    if (String(cachePolicy.getDiscardStrategy(DataType.RUM_APP)) === DBCacheDiscard.DISCARD_OLDEST) {
      const deleted = await this.deleteOldestDataLocked(rdbStore, types, overflow);
      result.deletedOld += deleted;
      this.addCacheCountDelta(countDelta, category, -deleted);
      return requested;
    }
    return Math.max(0, limit - currentCount);
  }

  private async applyCachePolicyLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta
  ): Promise<SyncData[]> {
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

    let allowedLogs = await this.resolveAllowedInsertCountLocked(
      rdbStore,
      SyncDataCacheCategory.LOG,
      logRequested,
      result,
      countDelta
    );
    let allowedRum = await this.resolveAllowedInsertCountLocked(
      rdbStore,
      SyncDataCacheCategory.RUM,
      rumRequested,
      result,
      countDelta
    );

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

    return allowedData;
  }

  private async filterDuplicatesLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    reInsert: boolean,
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta
  ): Promise<SyncData[]> {
    if (reInsert) {
      return dataList;
    }

    const filteredDataList: SyncData[] = [];
    const seenInBatch: Map<string, boolean> = new Map();

    for (const data of dataList) {
      const dataString = data.getDataString();
      const dataType = data.getDataType();
      const uniqueId = this.extractUniqueId(dataType, dataString);
      if (!uniqueId) {
        filteredDataList.push(data);
        continue;
      }

      const key = `${dataType.toString()}:${uniqueId}`;
      if (seenInBatch.has(key)) {
        result.duplicateSkipped++;
        continue;
      }

      if (!this.shouldQueryDbForDuplicate(uniqueId)) {
        if (this.insertedDataIds.has(key)) {
          result.duplicateSkipped++;
          continue;
        }
        seenInBatch.set(key, true);
        filteredDataList.push(data);
        continue;
      }

      const exists = await this.checkDataExistsLocked(rdbStore, dataType, dataString);
      if (!exists) {
        seenInBatch.set(key, true);
        filteredDataList.push(data);
        continue;
      }

      const deleted = await this.deleteDuplicateDataLocked(rdbStore, dataType, uniqueId, countDelta);
      result.deletedOld += deleted;
      seenInBatch.set(key, true);
      filteredDataList.push(data);
    }

    return filteredDataList;
  }

  private async insertPreparedDataLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    reInsert: boolean,
    result: SyncDataWriteResult,
    countDelta: SyncDataCacheCountDelta
  ): Promise<void> {
    if (!dataList || dataList.length === 0) {
      return;
    }

    if (dataList.length === 1) {
      const data = dataList[0];
      const rowId = await rdbStore.insert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, this.toSyncDataValuesBucket(data));
      const numericId = Number(rowId);
      if (numericId > 0) {
        data.setId(numericId);
        result.inserted++;
        this.addInsertedCacheCountDelta(countDelta, dataList, 1);
        if (!reInsert) {
          this.markDataAsInsertedLocked(data.getDataType(), data.getDataString());
        }
      } else {
        result.errorMessage = `Invalid rowId returned: ${rowId}`;
      }
      return;
    }

    const valuesArray: relationalStore.ValuesBucket[] = [];
    for (const data of dataList) {
      valuesArray.push(this.toSyncDataValuesBucket(data));
    }

    const insertedCount = await rdbStore.batchInsert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, valuesArray);
    const insertedRows = Math.max(0, insertedCount);
    result.inserted += insertedRows;
    this.addInsertedCacheCountDelta(countDelta, dataList, insertedRows);
    if (!reInsert && insertedRows > 0) {
      for (const data of dataList) {
        this.markDataAsInsertedLocked(data.getDataType(), data.getDataString());
      }
    }
  }

  private async writeSyncDataLocked(
    rdbStore: relationalStore.RdbStore,
    dataList: SyncData[],
    options: SyncDataWriteOptions,
    result: SyncDataWriteResult
  ): Promise<void> {
    const applyCachePolicy = options.applyCachePolicy === true;
    const reInsert = options.reInsert === true;
    let dataToWrite = dataList;
    const countDelta = this.createCacheCountDelta();

    try {
      if (applyCachePolicy) {
        dataToWrite = await this.applyCachePolicyLocked(rdbStore, dataToWrite, result, countDelta);
      }

      dataToWrite = await this.filterDuplicatesLocked(rdbStore, dataToWrite, reInsert, result, countDelta);
      await this.insertPreparedDataLocked(rdbStore, dataToWrite, reInsert, result, countDelta);
    } finally {
      if (applyCachePolicy) {
        this.applyCacheCountDelta(countDelta);
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

    const manager = this;
    const startTime = Date.now();
    class WriteSyncDataCallback implements DataBaseCallBack {
      async run(rdbStore: relationalStore.RdbStore): Promise<void> {
        try {
          await manager.writeSyncDataLocked(rdbStore, dataList, options, result);
        } catch (error) {
          result.success = false;
          result.errorMessage = String(error);
          throw new Error(result.errorMessage);
        }
      }
    }

    try {
      if (this.isDatabaseClosed()) {
        await this.init();
      }
      await this.getDB(true, new WriteSyncDataCallback());
    } catch (error) {
      result.success = false;
      result.errorMessage = String(error);
    } finally {
      const costTime = Math.max(0, Date.now() - startTime);
      const errorPart = result.errorMessage.length > 0 ? ` error=${result.errorMessage}` : '';
      FTInnerLogger.i(TAG,
        `[DB-WRITE] source=${source} rows=${result.requested} inserted=${result.inserted} dropped=${result.dropped} duplicate=${result.duplicateSkipped} deletedOld=${result.deletedOld} cost=${costTime}ms${errorPart}`);
    }

    return result;
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
    return result.inserted > 0;
  }

  /**
   * Batch insert sync data
   * @param dataList Data list
   * @param reInsert Whether to re-insert
   * @returns boolean
   */
  public async insertFtOptList(dataList: SyncData[], reInsert: boolean = false): Promise<boolean> {
    const result = await this.writeSyncDataAtomically('insertFtOptList', dataList, {
      applyCachePolicy: false,
      reInsert
    });
    return result.success;
  }

  /**
   * Query sync data
   * @param types Data type array
   * @param limit Limit count
   * @returns Promise<SyncData[]>
   */
  public async queryFtOperation(types: DataType[], limit: number = 100, newestFirst: boolean = false): Promise<SyncData[]> {
    const result: SyncData[] = [];

    try {
      class QueryCallback implements DataBaseCallBack {
        private result: SyncData[] = [];
        private maxLimit: number;
        
        constructor(maxLimit: number) {
          this.maxLimit = maxLimit;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
          
          if (types && types.length > 0) {
            const typeValues = types.map(type => type.toString());
            predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, typeValues);
          } else {
            // Removed test debug log to reduce log output
            // FTInnerLogger.d(TAG, ` Query predicate: table=${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}, all types`);
          }
          
          // Order by timestamp ascending by default (aligned with Android: ORDER by tm ASC).
          // Tests that assert the most recent crash/ANR data can opt into newest-first queries.
          if (newestFirst) {
            predicates.orderByDesc(FTSQL.RECORD_COLUMN_TM);
          } else {
            predicates.orderByAsc(FTSQL.RECORD_COLUMN_TM);
          }
          
          // Apply limit using limitAs (aligned with Android: LIMIT pageSize)
          // Note: limit <= 0 means no limit (query all), but we use a reasonable default
          if (this.maxLimit > 0) {
            predicates.limitAs(this.maxLimit);
          }
          
          const resultSet = await rdbStore.query(predicates);
          
          // Process query results
          try {
            // Iterate through result set (limit already applied by limitAs)
            while (resultSet.goToNextRow()) {
              // Read column data
              const uuid: string = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID));
              const dataType: string = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_TYPE));
              const data: string = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA));
              const timestamp: number = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_TM));
              
              
              
              if (uuid && dataType && data) {
                // Create correct SyncData object based on data type
                let syncData: SyncData;
                if (dataType === 'log') {
                  syncData = new SyncData(DataType.LOG);
                  
                } else if (dataType === 'rum_app') {
                  syncData = new SyncData(DataType.RUM_APP);
                  // Removed verbose debug log
                } else if (dataType === 'rum_webview') {
                  syncData = new SyncData(DataType.RUM_WEBVIEW);
                  // Removed verbose debug log
                } else {
                  // Default to LOG type
                  syncData = new SyncData(DataType.LOG);
                  // Removed verbose debug log
                }
                
                syncData.setUuid(uuid);
                syncData.setDataString(data);
                syncData.setTime(timestamp);
                
                this.result.push(syncData);
                // Removed individual record logging to reduce log noise
                // Summary log is available at line 440
              }
            }
            
            resultSet.close();
            // Removed test debug log to reduce log output
            // if (this.result.length > 0) {
            //   FTInnerLogger.d(TAG, ` Query completed, found ${this.result.length} records (limit=${this.maxLimit})`);
            // }
          } catch (error) {
            // Keep error log for important case
            FTInnerLogger.e(TAG, ` Error processing query result: ${error as string}`);
            resultSet.close();
          }
        }
        
        getResult(): SyncData[] {
          return this.result;
        }
      }
      
      const callback = new QueryCallback(limit);
      
      // Check if database is closed and reinitialize if needed
      const isClosed = this.isDatabaseClosed();
      if (isClosed) {
        FTInnerLogger.w(TAG, `DB closed during query, reinitializing`);
        await this.init();
      }
      
      await this.getDB(false, callback);
      
      const queryResult = callback.getResult();
      result.push(...queryResult);

      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to query sync data: ${error as string}`);
      return result;
    }
  }

  /**
   * Delete sync data
   * @param dataList Data list
   */
  public async deleteFtOperation(dataList: SyncData[]): Promise<void> {
    if (!dataList || dataList.length === 0) {
      return;
    }

    try {
      class DeleteCallback implements DataBaseCallBack {
        private dataList: SyncData[];
        private deletedCount: number = 0;
        
        constructor(dataList: SyncData[]) {
          this.dataList = dataList;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Delete each record using UUID (aligned with Android: uses batch delete for better performance)
          // Note: HarmonyOS doesn't support batch operations like Android's applyBatch,
          // so we delete one by one but ensure each deletion is awaited
          for (const data of this.dataList) {
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
            // Use UUID for deletion since UUID is unique
            predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_UUID, data.getUuid());
            const deleted = await rdbStore.delete(predicates);
            if (deleted > 0) {
              this.deletedCount++;
            }
          }
        }
        
        getDeletedCount(): number {
          return this.deletedCount;
        }
      }
      
      const callback = new DeleteCallback(dataList);
      await this.getDB(true, callback);
      
      const actualDeleted = callback.getDeletedCount();
      if (actualDeleted !== dataList.length) {
        FTInnerLogger.w(TAG, `Deleted ${actualDeleted} out of ${dataList.length} sync data items (some may not exist)`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to delete sync data: ${error as string}`);
    }
  }

  /**
   * Query total count
   * @param types Data type array
   * @returns Promise<number>
   */
  public async queryTotalCount(types: DataType[]): Promise<number> {
    try {
      const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
      
      if (types && types.length > 0) {
        const typeValues = types.map(type => type.toString());
        predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, typeValues);
      }

      // Use async query directly
      const rdbStore = await this.getDataBaseHelper();
      const resultSet = await rdbStore.query(predicates);
      
      // For quick existence check, only iterate if needed
      let count = 0;
      while (resultSet.goToNextRow()) {
        count++;
      }
      
      return count;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to query total count: ${error}`);
      return 0;
    }
  }

  /**
   * Delete oldest data (aligned with Android: deleteOldestData)
   * @param types Data type (single or array) - if single DataType, will be converted to array
   * @param limit Number of records to delete
   */
  public async deleteOldestData(types: DataType | DataType[], limit: number): Promise<void> {
    try {
      const manager = this;
      const typeArray = Array.isArray(types) ? types : [types];
      class DeleteOldestCallback implements DataBaseCallBack {
        deletedCount: number = 0;

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          this.deletedCount = await manager.deleteOldestDataLocked(rdbStore, typeArray, limit);
        }
      }

      const callback = new DeleteOldestCallback();
      await this.getDB(true, callback);
      const countDelta = this.createCacheCountDelta();
      this.addDeletedCacheCountDelta(countDelta, typeArray, callback.deletedCount);
      this.applyCacheCountDelta(countDelta);
      FTInnerLogger.i(TAG, `Oldest data deleted: types=${typeArray}, limit=${limit}, deleted=${callback.deletedCount}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to delete oldest data: ${error}`);
    }
  }

  /**
   * Get current database size (aligned with Android: checkDatabaseSize)
   * @returns Promise<number> Database size in bytes
   */
  public async getCurrentDatabaseSize(): Promise<number> {
    try {
      const rdbStore = await this.getDataBaseHelper();
      if (!rdbStore) {
        FTInnerLogger.w(TAG, "Failed to get database store for getCurrentDatabaseSize");
        return 0;
      }

      // Get database file size (HarmonyOS RDB PRAGMA query)
      const resultSet = await rdbStore.querySql("PRAGMA page_count");
      if (resultSet && resultSet.goToFirstRow()) {
        const pageCount = resultSet.getLong(resultSet.getColumnIndex("page_count"));
        const pageSize = 4096; // Default page size
        const fileSize = pageCount * pageSize;
        resultSet.close();
        return fileSize;
      }
      resultSet?.close();
      return 0;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get current database size: ${error}`);
      return 0;
    }
  }

  /**
   * Check if data exists (quick check, stops at first record)
   * @param types Data type array
   * @returns Promise<boolean>
   */
  public async hasData(types: DataType[]): Promise<boolean> {
    try {
      const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
      
      if (types && types.length > 0) {
        const typeValues = types.map(type => type.toString());
        predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, typeValues);
      }

      const rdbStore = await this.getDataBaseHelper();
      const resultSet = await rdbStore.query(predicates);
      
      // Only check if first row exists, much faster for empty database
      const hasData = resultSet.goToNextRow();
      resultSet.close();
      return hasData;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to check if data exists: ${error}`);
      return false;
    }
  }

  /**
   * Insert or update RUM view data
   * @param viewBean View data
   * @returns Promise<boolean>
   */
  public async insertRumView(viewBean: ViewBean): Promise<boolean> {
    try {
      // First try to insert
      const insertResult = await this.tryInsertRumView(viewBean);
      if (insertResult) {
        FTInnerLogger.d(TAG, `View not exists, insertRumView: ${viewBean.getId()}`);
        return true;
      }
      
      // If insert fails (possibly duplicate key), try to update
      FTInnerLogger.d(TAG, `View exists, switching to update: ${viewBean.getId()}`);
      return await this.updateRumView(viewBean);
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
    try {
      class InsertViewCallback implements DataBaseCallBack {
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Use ValuesBucket type
          const values: relationalStore.ValuesBucket = {
            id: viewBean.getId(),
            view_name: viewBean.getViewName(),
            view_referrer: viewBean.getViewReferrer(),
            start_time: viewBean.getStartTime(),
            is_close: viewBean.getIsClose() ? 1 : 0,
            session_id: viewBean.getSessionId(),
            action_count: viewBean.getActionCount(),
            error_count: viewBean.getErrorCount(),
            long_task_count: viewBean.getLongTaskCount(),
            view_load_time: viewBean.getViewLoadTime(),
            view_time_spent: viewBean.getTimeSpent(),
            resource_count: viewBean.getResourceCount(),
            pending_resource: viewBean.getPendingResource(),
            data_update_time: viewBean.getDataUpdateTime(),
            data_upload_time: viewBean.getDataUploadTime(),
            view_update_time: viewBean.getViewUpdateTime(),
            extra_attr: viewBean.getAttrJsonString()
          };

          await rdbStore.insert(FTSQL.FT_TABLE_VIEW, values);
        }
      }
      
      const callback: DataBaseCallBack = new InsertViewCallback();
      await this.getDB(true, callback);

      FTInnerLogger.d(TAG, `RUM view generated: ${viewBean.getId()}`);
      return true;
    } catch (error) {
      // Check if it's a duplicate key error
      if (error && error.toString().includes('UNIQUE constraint failed')) {
        return false;
      }
      throw new Error(`Insert view failed: ${error}`);
    }
  }

  /**
   * Update RUM view data
   * @param viewBean View data
   * @returns Promise<boolean>
   */
  public async updateRumView(viewBean: ViewBean): Promise<boolean> {
    try {
      class UpdateViewCallback implements DataBaseCallBack {
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const values: relationalStore.ValuesBucket = {
            view_name: viewBean.getViewName(),
            view_referrer: viewBean.getViewReferrer(),
            start_time: viewBean.getStartTime(),
            is_close: viewBean.getIsClose() ? 1 : 0,
            session_id: viewBean.getSessionId(),
            action_count: viewBean.getActionCount(),
            error_count: viewBean.getErrorCount(),
            long_task_count: viewBean.getLongTaskCount(),
            view_load_time: viewBean.getViewLoadTime(),
            view_time_spent: viewBean.getTimeSpent(),
            resource_count: viewBean.getResourceCount(),
            pending_resource: viewBean.getPendingResource(),
            data_update_time: viewBean.getDataUpdateTime(),
            data_upload_time: viewBean.getDataUploadTime(),
            view_update_time: viewBean.getViewUpdateTime(),
            extra_attr: viewBean.getAttrJsonString()
          };

          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, viewBean.getId());
          await rdbStore.update(values, predicates);
        }
      }
      
      const callback: DataBaseCallBack = new UpdateViewCallback();
      await this.getDB(true, callback);

      FTInnerLogger.d(TAG, `RUM view updated: ${viewBean.getId()}`);
      return true;
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
      class CloseViewCallback implements DataBaseCallBack {
        private viewId: string;
        private loadTime: number;
        private timeSpent: number;
        private attr: string;
        private newSessionId?: string;
        
        constructor(viewId: string, loadTime: number, timeSpent: number, attr: string, newSessionId?: string) {
          this.viewId = viewId;
          this.loadTime = loadTime;
          this.timeSpent = timeSpent;
          this.attr = attr;
          this.newSessionId = newSessionId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
          
          const values: relationalStore.ValuesBucket = {
            is_close: 1,
            view_load_time: this.loadTime,
            view_time_spent: this.timeSpent,
            extra_attr: this.attr,
            data_update_time: Date.now()
          };
          
          // Update session ID if provided (for session refresh scenario)
          if (this.newSessionId) {
            values.session_id = this.newSessionId;
          }
          
          const updateCount: number = await rdbStore.update(values, predicates);
          if (updateCount > 0) {
            FTInnerLogger.d(TAG, `View closed: ${this.viewId}`);
          } else {
            FTInnerLogger.w(TAG, `View not found for close: ${this.viewId}`);
          }
        }
      }
      
      const callback: DataBaseCallBack = new CloseViewCallback(viewId, loadTime, timeSpent, attr, newSessionId);
      await this.getDB(true, callback);
      
      return true;
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
      class UpdateViewUploadTimeCallback implements DataBaseCallBack {
        private viewId: string;
        private dateTime: number;
        private success: boolean = false;
        
        constructor(viewId: string, dateTime: number) {
          this.viewId = viewId;
          this.dateTime = dateTime;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const queryPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          queryPredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);

          const resultSet = await rdbStore.query(queryPredicates, [FTSQL.RUM_VIEW_UPDATE_TIME]);

          if (resultSet.goToFirstRow()) {
            const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME);
            const currentUpdateTime: number = resultSet.getLong(columnIndex);

            const values: relationalStore.ValuesBucket = {
              data_upload_time: this.dateTime,
              view_update_time: currentUpdateTime + 1
            };

            const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);

            const updateCount: number = await rdbStore.update(values, updatePredicates);
            if (updateCount > 0) {
              this.success = true;
              FTInnerLogger.d(TAG, `View upload state updated: ${this.viewId}`);
            } else {
              FTInnerLogger.w(TAG, `View not found for upload time update: ${this.viewId}`);
            }
          } else {
            FTInnerLogger.w(TAG, `View not found for upload time update: ${this.viewId}`);
          }

          resultSet.close();
        }

        isSuccess(): boolean {
          return this.success;
        }
      }
      
      const callback = new UpdateViewUploadTimeCallback(viewId, dateTime);
      await this.getDB(true, callback);
      return callback.isSuccess();
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
      class IncreaseViewActionCallback implements DataBaseCallBack {
        private viewId: string;
        private viewName: string;
        
        constructor(viewId: string, viewName: string) {
          this.viewId = viewId;
          this.viewName = viewName;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Use atomic SQL UPDATE to prevent race conditions (aligned with Android SDK)
          // Android SDK uses: UPDATE table SET column=column+1 WHERE id='...'
          // This ensures thread-safe increment even with concurrent calls
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_ACTION_COUNT} = ${FTSQL.RUM_COLUMN_ACTION_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase view action count failed: ${this.viewName} (${this.viewId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_ACTION_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                action_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `View not found when increasing action count: ${this.viewName} (${this.viewId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseViewActionCallback(viewId, viewNameStr);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view action count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseViewLongTask
   * @param viewId View ID
   * @param viewName Optional view name for logging
   */
  public async increaseViewLongTask(viewId: string, viewName?: string): Promise<void> {
    if (!viewId) {
      return;
    }
    const viewNameStr = viewName || 'unknown';
    try {
      class IncreaseViewLongTaskCallback implements DataBaseCallBack {
        private viewId: string;
        private viewName: string;
        constructor(viewId: string, viewName: string) {
          this.viewId = viewId;
          this.viewName = viewName;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_LONG_TASK_COUNT} = ${FTSQL.RUM_COLUMN_LONG_TASK_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase view long task count failed: ${this.viewName} (${this.viewId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_LONG_TASK_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                long_task_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `View not found when increasing long task count: ${this.viewName} (${this.viewId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseViewLongTaskCallback(viewId, viewNameStr);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view long task count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseActionLongTask
   * @param actionId Action ID
   * @param actionName Optional action name for logging
   */
  public async increaseActionLongTask(actionId: string, actionName?: string): Promise<void> {
    if (!actionId) {
      return;
    }
    const actionNameStr = actionName || 'unknown';
    try {
      class IncreaseActionLongTaskCallback implements DataBaseCallBack {
        private actionId: string;
        private actionName: string;
        constructor(actionId: string, actionName: string) {
          this.actionId = actionId;
          this.actionName = actionName;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${FTSQL.RUM_COLUMN_LONG_TASK_COUNT} = ${FTSQL.RUM_COLUMN_LONG_TASK_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase action long task count failed: ${this.actionName} (${this.actionId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_LONG_TASK_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                long_task_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `Action not found when increasing long task count: ${this.actionName} (${this.actionId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseActionLongTaskCallback(actionId, actionNameStr);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase action long task count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseViewError
   * @param viewId View ID
   * @param viewName Optional view name for logging
   */
  public async increaseViewError(viewId: string, viewName?: string): Promise<void> {
    if (!viewId) {
      return;
    }
    const viewNameStr = viewName || 'unknown';
    try {
      class IncreaseViewErrorCallback implements DataBaseCallBack {
        private viewId: string;
        private viewName: string;
        constructor(viewId: string, viewName: string) {
          this.viewId = viewId;
          this.viewName = viewName;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_ERROR_COUNT} = ${FTSQL.RUM_COLUMN_ERROR_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase view error count failed: ${this.viewName} (${this.viewId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_ERROR_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                error_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `View not found when increasing error count: ${this.viewName} (${this.viewId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseViewErrorCallback(viewId, viewNameStr);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view error count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseActionError
   * @param actionId Action ID
   * @param actionName Optional action name for logging
   */
  public async increaseActionError(actionId: string, actionName?: string): Promise<void> {
    if (!actionId) {
      return;
    }
    const actionNameStr = actionName || 'unknown';
    try {
      class IncreaseActionErrorCallback implements DataBaseCallBack {
        private actionId: string;
        private actionName: string;
        constructor(actionId: string, actionName: string) {
          this.actionId = actionId;
          this.actionName = actionName;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${FTSQL.RUM_COLUMN_ERROR_COUNT} = ${FTSQL.RUM_COLUMN_ERROR_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase action error count failed: ${this.actionName} (${this.actionId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_ERROR_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                error_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `Action not found when increasing error count: ${this.actionName} (${this.actionId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseActionErrorCallback(actionId, actionNameStr);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase action error count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseActionResource
   * @param actionId Action ID
   * @param actionName Optional action name for logging
   */
  public async increaseActionResource(actionId: string): Promise<void> {
    if (!actionId) {
      return;
    }
    try {
      class IncreaseActionResourceCallback implements DataBaseCallBack {
        private actionId: string;
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} = ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase action resource count failed:  (${this.actionId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_RESOURCE_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                resource_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `Action not found when increasing resource count: (${this.actionId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseActionResourceCallback(actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase action resource count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseActionPendingResource
   * @param actionId Action ID
   */
  public async increaseActionPendingResource(actionId: string): Promise<void> {
    if (!actionId) {
      return;
    }
    try {
      class IncreaseActionPendingResourceCallback implements DataBaseCallBack {
        private actionId: string;
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase action pending resource failed: ${this.actionId}, ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                pending_resource: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `Action not found when increasing pending resource: ${this.actionId}`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseActionPendingResourceCallback(actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase action pending resource count: ${error}`);
    }
  }

  /**
   * Aligned with Android: reduceActionPendingResource
   * @param actionId Action ID
   */
  public async reduceActionPendingResource(actionId: string): Promise<void> {
    if (!actionId) {
      return;
    }
    try {
      class ReduceActionPendingResourceCallback implements DataBaseCallBack {
        private actionId: string;
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} - 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}' AND ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} > 0`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Reduce action pending resource failed: ${this.actionId}, ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              if (currentCount > 0) {
                const values: relationalStore.ValuesBucket = {
                  pending_resource: currentCount - 1
                };
                
                const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
                updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
                await rdbStore.update(values, updatePredicates);
                
              }
            } else {
              FTInnerLogger.w(TAG, `Action not found when reducing pending resource: ${this.actionId}`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new ReduceActionPendingResourceCallback(actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to reduce action pending resource count: ${error}`);
    }
  }

  /**
   * Aligned with Android: increaseViewPendingResource
   * @param viewId View ID
   */
  public async increaseViewPendingResource(viewId: string): Promise<void> {
    if (!viewId) {
      return;
    }
    try {
      class IncreaseViewPendingResourceCallback implements DataBaseCallBack {
        private viewId: string;
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase view pending resource failed: ${this.viewId}, ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                pending_resource: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `View not found when increasing pending resource: ${this.viewId}`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseViewPendingResourceCallback(viewId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view pending resource count: ${error}`);
    }
  }

  /**
   * Aligned with Android: reduceViewPendingResource
   * @param viewId View ID
   */
  public async reduceViewPendingResource(viewId: string): Promise<void> {
    if (!viewId) {
      return;
    }
    try {
      class ReduceViewPendingResourceCallback implements DataBaseCallBack {
        private viewId: string;
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} - 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}' AND ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} > 0`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Reduce view pending resource failed: ${this.viewId}, ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              if (currentCount > 0) {
                const values: relationalStore.ValuesBucket = {
                  pending_resource: currentCount - 1
                };
                
                const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
                updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
                await rdbStore.update(values, updatePredicates);
                
              }
            } else {
              FTInnerLogger.w(TAG, `View not found when reducing pending resource: ${this.viewId}`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new ReduceViewPendingResourceCallback(viewId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Reduce view pending resource failed: ${error as string}`);
    }
  }

  /**
   * Increase resource pending counts for view/action with one DB write lock.
   */
  public async increaseResourcePending(viewId: string, actionId: string): Promise<void> {
    const hasViewId = viewId.length > 0;
    const hasActionId = actionId.length > 0;
    if (!hasViewId && !hasActionId) {
      return;
    }

    try {
      class IncreaseResourcePendingCallback implements DataBaseCallBack {
        private viewId: string;
        private actionId: string;

        constructor(viewId: string, actionId: string) {
          this.viewId = viewId;
          this.actionId = actionId;
        }

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          if (this.viewId && this.viewId.length > 0) {
            try {
              const viewSql =
                `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ` +
                  `${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} + 1 ` +
                `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
              await rdbStore.executeSql(viewSql);
            } catch (error) {
              FTInnerLogger.e(TAG, `Increase view resource pending failed: ${this.viewId}, ${error}`);
            }
          }

          if (this.actionId && this.actionId.length > 0) {
            try {
              const actionSql =
                `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ` +
                  `${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} + 1 ` +
                `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
              await rdbStore.executeSql(actionSql);
            } catch (error) {
              FTInnerLogger.e(TAG, `Increase action resource pending failed: ${this.actionId}, ${error}`);
            }
          }
        }
      }

      const callback: DataBaseCallBack = new IncreaseResourcePendingCallback(viewId, actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase resource pending counts: ${error}`);
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
      class GetViewPendingResourceCallback implements DataBaseCallBack {
        private viewId: string;
        private pendingResource: number = 0;
        
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
          
          const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
          
          if (resultSet.goToFirstRow()) {
            const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
            this.pendingResource = resultSet.getLong(columnIndex);
          }
          resultSet.close();
        }
        
        getPendingResource(): number {
          return this.pendingResource;
        }
      }
      
      const callback = new GetViewPendingResourceCallback(viewId);
      await this.getDB(false, callback);
      return callback.getPendingResource();
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
      class ForceClearViewPendingResourceCallback implements DataBaseCallBack {
        private viewId: string;
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
          
          const values: relationalStore.ValuesBucket = {
            pending_resource: 0
          };
          
          const updateCount = await rdbStore.update(values, predicates);
          if (updateCount > 0) {
            FTInnerLogger.w(TAG, `Force cleared view pending resource: ${this.viewId}`);
          } else {
            FTInnerLogger.w(TAG, `View not found when force clearing pending resource: ${this.viewId}`);
          }
        }
      }
      
      const callback: DataBaseCallBack = new ForceClearViewPendingResourceCallback(viewId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Force clear view pending resource failed: ${error as string}`);
    }
  }

  /**
   * Get action pending_resource count
   * @param actionId Action ID
   * @returns pending_resource count, or 0 if action not found
   */
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
      class GetActionInfoCallback implements DataBaseCallBack {
        private actionId: string;
        private startTime: number | null = null;
        
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
          
          const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_START_TIME]);
          
          if (resultSet.goToFirstRow()) {
            const startTimeCol = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME);
            this.startTime = resultSet.getLong(startTimeCol);
            resultSet.close();
          } else {
            resultSet.close();
          }
        }
        
        getStartTime(): number | null {
          return this.startTime;
        }
      }
      
      const callback = new GetActionInfoCallback(actionId);
      await this.getDB(true, callback);
      
      const startTime = callback.getStartTime();
      if (startTime !== null) {
        const actionInfo: ActionInfo = {
          startTime: startTime
        };
        return actionInfo;
      }
      return null;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get action info for ${actionId}: ${error}`);
      return null;
    }
  }

  public async getActionPendingResource(actionId: string): Promise<number> {
    if (!actionId) {
      return 0;
    }
    try {
      class GetActionPendingResourceCallback implements DataBaseCallBack {
        private actionId: string;
        private pendingResource: number = 0;
        
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
          
          const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
          
          if (resultSet.goToFirstRow()) {
            const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
            this.pendingResource = resultSet.getLong(columnIndex);
          }
          resultSet.close();
        }
        
        getPendingResource(): number {
          return this.pendingResource;
        }
      }
      
      const callback = new GetActionPendingResourceCallback(actionId);
      await this.getDB(false, callback);
      return callback.getPendingResource();
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
      class ForceClearActionPendingResourceCallback implements DataBaseCallBack {
        private actionId: string;
        constructor(actionId: string) {
          this.actionId = actionId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
          
          const values: relationalStore.ValuesBucket = {
            pending_resource: 0
          };
          
          const updateCount = await rdbStore.update(values, predicates);
          if (updateCount > 0) {
            FTInnerLogger.w(TAG, `Force cleared action pending resource: ${this.actionId}`);
          } else {
            FTInnerLogger.w(TAG, `Action not found when force clearing pending resource: ${this.actionId}`);
          }
        }
      }
      
      const callback: DataBaseCallBack = new ForceClearActionPendingResourceCallback(actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Force clear action pending resource failed: ${error as string}`);
    }
  }

  /**
   * Aligned with Android: increaseViewResource
   * @param viewId View ID
   * @param viewName Optional view name for logging
   */
  public async increaseViewResource(viewId: string): Promise<void> {
    if (!viewId) {
      return;
    }
    try {
      class IncreaseViewResourceCallback implements DataBaseCallBack {
        private viewId: string;
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            const updateSql = `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} = ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} + 1 WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
            await rdbStore.executeSql(updateSql);
          } catch (error) {
            FTInnerLogger.e(TAG, `Increase view resource count failed: (${this.viewId}), ${error}`);
            // Fallback to read-modify-write if atomic SQL fails
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            
            const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_RESOURCE_COUNT]);
            
            if (resultSet.goToFirstRow()) {
              const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT);
              const currentCount: number = resultSet.getLong(columnIndex);
              
              const values: relationalStore.ValuesBucket = {
                resource_count: currentCount + 1
              };
              
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
              await rdbStore.update(values, updatePredicates);
              
            } else {
              FTInnerLogger.w(TAG, `View not found when increasing resource count: (${this.viewId})`);
            }
            resultSet.close();
          }
        }
      }
      
      const callback: DataBaseCallBack = new IncreaseViewResourceCallback(viewId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to increase view resource count: ${error}`);
    }
  }

  /**
   * Complete a resource for the view with one atomic SQL write.
   *
   * This is used by stopResource to avoid queueing separate DB writes for
   * resource_count, pending_resource and view_update_time.
   */
  public async completeViewResource(viewId: string): Promise<void> {
    if (!viewId) {
      return;
    }
    try {
      class CompleteViewResourceCallback implements DataBaseCallBack {
        private viewId: string;
        constructor(viewId: string) {
          this.viewId = viewId;
        }

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const updateSql =
            `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ` +
              `${FTSQL.RUM_COLUMN_RESOURCE_COUNT} = ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} + 1, ` +
              `${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = CASE WHEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} > 0 ` +
                `THEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} - 1 ELSE 0 END, ` +
              `${FTSQL.RUM_VIEW_UPDATE_TIME} = ${FTSQL.RUM_VIEW_UPDATE_TIME} + 1, ` +
              `${FTSQL.RUM_DATA_UPDATE_TIME} = ${Date.now()} ` +
            `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
          await rdbStore.executeSql(updateSql);
        }
      }

      const callback: DataBaseCallBack = new CompleteViewResourceCallback(viewId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to complete view resource: ${error}`);
    }
  }

  /**
   * Complete a resource for view/action with one DB write lock.
   */
  public async completeResource(viewId: string, actionId: string): Promise<void> {
    const hasViewId = viewId.length > 0;
    const hasActionId = actionId.length > 0;
    if (!hasViewId && !hasActionId) {
      return;
    }

    try {
      class CompleteResourceCallback implements DataBaseCallBack {
        private viewId: string;
        private actionId: string;

        constructor(viewId: string, actionId: string) {
          this.viewId = viewId;
          this.actionId = actionId;
        }

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const now = Date.now();

          if (this.viewId && this.viewId.length > 0) {
            try {
              const viewSql =
                `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ` +
                  `${FTSQL.RUM_COLUMN_RESOURCE_COUNT} = ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} + 1, ` +
                  `${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = CASE WHEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} > 0 ` +
                    `THEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} - 1 ELSE 0 END, ` +
                  `${FTSQL.RUM_VIEW_UPDATE_TIME} = ${FTSQL.RUM_VIEW_UPDATE_TIME} + 1, ` +
                  `${FTSQL.RUM_DATA_UPDATE_TIME} = ${now} ` +
                `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
              await rdbStore.executeSql(viewSql);
            } catch (error) {
              FTInnerLogger.e(TAG, `Complete view resource failed: ${this.viewId}, ${error}`);
            }
          }

          if (this.actionId && this.actionId.length > 0) {
            try {
              const actionSql =
                `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ` +
                  `${FTSQL.RUM_COLUMN_RESOURCE_COUNT} = ${FTSQL.RUM_COLUMN_RESOURCE_COUNT} + 1, ` +
                  `${FTSQL.RUM_COLUMN_PENDING_RESOURCE} = CASE WHEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} > 0 ` +
                    `THEN ${FTSQL.RUM_COLUMN_PENDING_RESOURCE} - 1 ELSE 0 END ` +
                `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.actionId}'`;
              await rdbStore.executeSql(actionSql);
            } catch (error) {
              FTInnerLogger.e(TAG, `Complete action resource failed: ${this.actionId}, ${error}`);
            }
          }
        }
      }

      const callback: DataBaseCallBack = new CompleteResourceCallback(viewId, actionId);
      await this.getDB(true, callback);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to complete resource counts: ${error}`);
    }
  }

  public async updateViewUpdateTime(viewId: string): Promise<boolean> {
    if (!viewId) {
      return false;
    }

    try {
      class UpdateViewUpdateTimeCallback implements DataBaseCallBack {
        private viewId: string;
        
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const updateSql =
            `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ` +
              `${FTSQL.RUM_VIEW_UPDATE_TIME} = ${FTSQL.RUM_VIEW_UPDATE_TIME} + 1, ` +
              `${FTSQL.RUM_DATA_UPDATE_TIME} = ${Date.now()} ` +
            `WHERE ${FTSQL.RUM_COLUMN_ID} = '${this.viewId}'`;
          await rdbStore.executeSql(updateSql);
        }
      }
      
      const callback: DataBaseCallBack = new UpdateViewUpdateTimeCallback(viewId);
      await this.getDB(true, callback);
      
      return true;
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
      class InsertActionCallback implements DataBaseCallBack {
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Use ValuesBucket type
          const values: relationalStore.ValuesBucket = {
            id: actionBean.getId(),
            start_time: actionBean.getStartTime(),
            action_duration: actionBean.getActionDuration(),
            is_close: actionBean.getIsClose() ? 1 : 0,
            error_count: actionBean.getErrorCount(),
            long_task_count: actionBean.getLongTaskCount(),
            resource_count: actionBean.getResourceCount(),
            pending_resource: actionBean.getPendingResource(),
            session_id: actionBean.getSessionId(),
            view_name: actionBean.getViewName(),
            view_id: actionBean.getViewId(),
            view_referrer: actionBean.getViewReferrer(),
            action_name: actionBean.getActionName(),
            action_type: actionBean.getActionType(),
            extra_attr: actionBean.getAttrJsonString()
          };

          await rdbStore.insert(FTSQL.FT_TABLE_ACTION, values);
        }
      }
      
      const callback: DataBaseCallBack = new InsertActionCallback();
      await this.getDB(true, callback);

      FTInnerLogger.d(TAG, `RUM action generated: ${actionBean.getId()}`);
      return true;
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
      class CloseActionCallback implements DataBaseCallBack {
        private actionId: string;
        private duration: number;
        private force: boolean;
        private wasClosed: boolean = false;
        private hadPendingResource: boolean = false;
        
        constructor(actionId: string, duration: number, force: boolean) {
          this.actionId = actionId;
          this.duration = duration;
          this.force = force;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Aligned with Android: query action first to check if it exists and meets conditions
          const queryPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          queryPredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
          
          // If not force, only close actions with pending_resource <= 0
          // Note: RdbPredicates doesn't support <= directly, so we query all and filter in memory
          // or use a different approach - for now, we'll query and check
          const resultSet = await rdbStore.query(queryPredicates, [FTSQL.RUM_COLUMN_ID, FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
          
          if (resultSet.goToFirstRow()) {
            const pendingResourceCol = resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE);
            const pendingResource = resultSet.getLong(pendingResourceCol);
            
            // Check if action can be closed (force or pending_resource <= 0)
            if (this.force || pendingResource <= 0) {
              // Update action to closed
              const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);
              
              const values: relationalStore.ValuesBucket = {
                is_close: 1,
                action_duration: this.duration
              };
              
              const updateCount: number = await rdbStore.update(values, updatePredicates);
              if (updateCount > 0) {
                this.wasClosed = true;
                this.hadPendingResource = pendingResource > 0;
                FTInnerLogger.d(TAG, `Action closed: ${this.actionId}`);
              } else {
                FTInnerLogger.w(TAG, `Failed to update action for close: ${this.actionId}`);
              }
            } else {
              this.hadPendingResource = true;
            }
            resultSet.close();
          } else {
            FTInnerLogger.w(TAG, `Action not found for close: ${this.actionId}`);
            resultSet.close();
          }
        }
        
        getWasClosed(): boolean {
          return this.wasClosed;
        }
        
        getHadPendingResource(): boolean {
          return this.hadPendingResource;
        }
      }
      
      const callback = new CloseActionCallback(actionId, duration, force);
      await this.getDB(true, callback);
      
      // If action was closed and had pending_resource, schedule delayed cleanup
      if (callback.getWasClosed() && callback.getHadPendingResource()) {
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
      
      return callback.getWasClosed();
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
    if (this.databaseHelper) {
      await this.databaseHelper.resetDatabase();
    }
  }

  /**
   * Query closed Action data
   * @param limit Limit count
   * @returns Promise<ActionBean[]>
   */
  public async querySumAction(limit: number = 50): Promise<ActionBean[]> {
    try {
      class QueryActionCallback implements DataBaseCallBack {
        private result: ActionBean[] = [];
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          predicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
          predicates.orderByAsc(FTSQL.RUM_COLUMN_START_TIME);
          predicates.limitAs(limit);
          
          const resultSet = await rdbStore.query(predicates);
          if (resultSet.goToFirstRow()) {
            do {
              // Use getString() for start_time to handle large BIGINT values (19-digit nanosecond timestamps)
              // getLong() may lose precision for values exceeding Number.MAX_SAFE_INTEGER (2^53 - 1)
              const actionStartTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
              const actionStartTime = actionStartTimeStr ? Number.parseInt(actionStartTimeStr, 10) : 0;
              const actionBean = new ActionBean(
                resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ID)),
                resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_NAME)),
                resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_TYPE)),
                actionStartTime
              );
              actionBean.setActionDuration(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_DURATION)));
              actionBean.setIsClose(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_IS_CLOSE)) === 1);
              actionBean.setErrorCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)));
              actionBean.setLongTaskCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)));
              actionBean.setResourceCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT)));
              actionBean.setPendingResource(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE)));
              actionBean.setSessionId(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_SESSION_ID)));
              actionBean.setViewId(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_ID)));
              actionBean.setViewName(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_NAME)));
              actionBean.setViewReferrer(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_REFERRER)));
              actionBean.setActionName(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_NAME)));
              actionBean.setActionType(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_TYPE)));
              actionBean.setAttrJsonString(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_EXTRA_ATTR)));
              
              this.result.push(actionBean);
            } while (resultSet.goToNextRow());
          }
          resultSet.close();
        }
        
        getResult(): ActionBean[] {
          return this.result;
        }
      }
      
      const callback = new QueryActionCallback();
      await this.getDB(false, callback);
      return callback.getResult();
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
      class QueryActionCountsCallback implements DataBaseCallBack {
        private result: ActionCounts | null = null;
        private actionId: string;

        constructor(actionId: string) {
          this.actionId = actionId;
        }

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.actionId);

          const resultSet = await rdbStore.query(predicates);
          if (resultSet.goToFirstRow()) {
            const counts: ActionCounts = {
              errorCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)),
              longTaskCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)),
              resourceCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT))
            };
            this.result = counts;
          }
          resultSet.close();
        }

        getResult(): ActionCounts | null {
          return this.result;
        }
      }

      const callback = new QueryActionCountsCallback(actionId);
      await this.getDB(false, callback);
      return callback.getResult();
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
      class QueryViewCallback implements DataBaseCallBack {
        private result: ViewBean[] = [];
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const sql = `
            SELECT * FROM ${FTSQL.FT_TABLE_VIEW}
            WHERE (
              ${FTSQL.RUM_COLUMN_IS_CLOSE} = 0
              OR (
                ${FTSQL.RUM_COLUMN_IS_CLOSE} = 1 AND (
                  ${FTSQL.RUM_DATA_UPLOAD_TIME} = 0
                  OR ${FTSQL.RUM_DATA_UPLOAD_TIME} < ${FTSQL.RUM_DATA_UPDATE_TIME}
                )
              )
            )
            ORDER BY ${FTSQL.RUM_COLUMN_START_TIME} ASC
            LIMIT ${limit}
          `;

          const resultSet = await rdbStore.querySql(sql);
          if (resultSet.goToFirstRow()) {
            do {
              const isClose = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_IS_CLOSE)) === 1;
              const uploadTime = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPLOAD_TIME));
              const updateTime = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPDATE_TIME));

              // Use getString() for start_time to handle large BIGINT values (19-digit nanosecond timestamps)
              // getLong() may lose precision for values exceeding Number.MAX_SAFE_INTEGER (2^53 - 1)
              const startTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
              const startTime = startTimeStr ? Number.parseInt(startTimeStr, 10) : 0;
              const viewBean = new ViewBean(
                resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ID)),
                resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_NAME)),
                startTime
              );
              viewBean.setViewReferrer(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_REFERRER)));
              viewBean.setIsClose(isClose);
              viewBean.setSessionId(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_SESSION_ID)));
              viewBean.setActionCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_COUNT)));
              viewBean.setErrorCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)));
              viewBean.setLongTaskCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)));
              viewBean.setViewLoadTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_LOAD_TIME)));
              viewBean.setTimeSpent(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_TIME_SPENT)));
              viewBean.setResourceCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT)));
              viewBean.setPendingResource(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE)));
              viewBean.setDataUpdateTime(updateTime);
              viewBean.setDataUploadTime(uploadTime);
              viewBean.setViewUpdateTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME)));
              viewBean.setAttrJsonString(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_EXTRA_ATTR)));
              
              this.result.push(viewBean);
            } while (resultSet.goToNextRow());
          }
          resultSet.close();
        }
        
        getResult(): ViewBean[] {
          return this.result;
        }
      }
      
      const callback = new QueryViewCallback();
      await this.getDB(false, callback);
      return callback.getResult();
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
      class QueryViewByIdCallback implements DataBaseCallBack {
        private viewId: string;
        private result: ViewBean | null = null;
        
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
          
          const resultSet = await rdbStore.query(predicates);
          if (resultSet.goToFirstRow()) {
            // Use getString() for start_time to handle large BIGINT values (19-digit nanosecond timestamps)
            // getLong() may lose precision for values exceeding Number.MAX_SAFE_INTEGER (2^53 - 1)
            const viewStartTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
            const viewStartTime = viewStartTimeStr ? Number.parseInt(viewStartTimeStr, 10) : 0;
            const viewBean = new ViewBean(
              resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ID)),
              resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_NAME)),
              viewStartTime
            );
            viewBean.setViewReferrer(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_REFERRER)));
            viewBean.setIsClose(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_IS_CLOSE)) === 1);
            viewBean.setSessionId(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_SESSION_ID)));
            viewBean.setActionCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_COUNT)));
            viewBean.setErrorCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)));
            viewBean.setLongTaskCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)));
            viewBean.setViewLoadTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_LOAD_TIME)));
            viewBean.setTimeSpent(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_TIME_SPENT)));
            viewBean.setResourceCount(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT)));
            viewBean.setPendingResource(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE)));
            viewBean.setDataUpdateTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPDATE_TIME)));
            viewBean.setDataUploadTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPLOAD_TIME)));
            viewBean.setViewUpdateTime(resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME)));
            viewBean.setAttrJsonString(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_EXTRA_ATTR)));
            
            this.result = viewBean;
          }
          resultSet.close();
        }
        
        getResult(): ViewBean | null {
          return this.result;
        }
      }
      
      const callback = new QueryViewByIdCallback(viewId);
      await this.getDB(false, callback);
      return callback.getResult();
    } catch (error) {
      FTInnerLogger.e(TAG, `Query RUM view by ID failed: ${error as string}`);
      return null;
    }
  }

  /**
   * Delete closed Action data
   * Aligned with Android SDK: cleanCloseActionData(String[] ids)
   * Additionally, deletes stale unclosed actions (older than 30 seconds) even if pending_resource>0
   * This prevents data residue in stress test scenarios where resources may never complete
   * @param ids Action ID array (if provided and not empty, only deletes these specific actions)
   */
  public async cleanCloseActionData(ids?: string[]): Promise<void> {
    try {
      // If ids is provided and not empty, delete specific actions (aligned with Android SDK behavior)
      if (ids && ids.length > 0) {
        class DeleteActionCallback implements DataBaseCallBack {
          private ids: string[];
          private deletedCount: number = 0;
          
          constructor(ids: string[]) {
            this.ids = ids;
          }
          
          async run(rdbStore: relationalStore.RdbStore): Promise<void> {
            // Delete each action by ID (aligned with Android: uses batch delete for better performance)
            // Note: HarmonyOS doesn't support batch operations like Android's applyBatch,
            // so we delete one by one but ensure each deletion is awaited
            for (const id of this.ids) {
              const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              predicates.equalTo(FTSQL.RUM_COLUMN_ID, id);
              const deleted = await rdbStore.delete(predicates);
              if (deleted > 0) {
                this.deletedCount++;
              }
            }
          }
          
          getDeletedCount(): number {
            return this.deletedCount;
          }
        }
        
        const callback = new DeleteActionCallback(ids);
        await this.getDB(true, callback);
        
        const actualDeleted = callback.getDeletedCount();
        if (actualDeleted !== ids.length) {
          FTInnerLogger.w(TAG, `Clean close action data incomplete: ${actualDeleted}/${ids.length}`);
        }
      } else {
        // If ids is not provided or empty, delete all closed actions and stale unclosed actions
        // Aligned with Android SDK: DELETE FROM action WHERE is_close=1 (for closed actions)
        // Additionally, delete stale unclosed actions (is_close=0, pending_resource>0, start_time older than threshold)
        // Threshold: 30 seconds - gives resources time to complete after the 30-second delayed cleanup
        // This prevents data residue in stress test scenarios where resources may never complete
        const nowNanos = Utils.getCurrentNanoTime();
        const STALE_ACTION_THRESHOLD_MS = 30 * 1000; // 30 seconds: delete unclosed actions older than 30 seconds even if pending_resource>0
        const staleThresholdNanos = nowNanos - (STALE_ACTION_THRESHOLD_MS * 1000000); // Convert ms to nanoseconds
        
        class DeleteAllCloseActionCallback implements DataBaseCallBack {
          private staleThresholdNanos: number;
          
          constructor(staleThresholdNanos: number) {
            this.staleThresholdNanos = staleThresholdNanos;
          }
          
          async run(rdbStore: relationalStore.RdbStore): Promise<void> {
            // First, delete normal closed actions (is_close=1)
            const normalPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            normalPredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
            await rdbStore.delete(normalPredicates);
            
            // Then, delete stale unclosed actions (is_close=0, pending_resource>0, start_time older than threshold)
            // This prevents data residue in stress test scenarios
            // Note: We need to recreate predicates for deletion because query() may modify the predicates object
            const staleQueryPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
            staleQueryPredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 0);
            staleQueryPredicates.greaterThan(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
            staleQueryPredicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_START_TIME, this.staleThresholdNanos);
            
            // First query to count how many stale actions exist (for debugging)
            const countResult = await rdbStore.query(staleQueryPredicates, ['count(*) as count']);
            let staleCount = 0;
            if (countResult.goToFirstRow()) {
              staleCount = countResult.getLong(0);
            }
            countResult.close();
            
            if (staleCount > 0) {
              // Recreate predicates for deletion (RdbPredicates may be modified by query)
              const staleDeletePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
              staleDeletePredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 0);
              staleDeletePredicates.greaterThan(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
              staleDeletePredicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_START_TIME, this.staleThresholdNanos);
              const staleDeleted = await rdbStore.delete(staleDeletePredicates);
              if (staleDeleted <= 0) {
                FTInnerLogger.w(TAG, `Stale action cleanup skipped unexpectedly: count=${staleCount}`);
              }
            }
          }
        }
        
        const callback = new DeleteAllCloseActionCallback(staleThresholdNanos);
        await this.getDB(true, callback);
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
      const now = Date.now();
      const STALE_VIEW_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes: delete closed views older than 5 minutes even if pending_resource>0
      
      // If ids is provided and not empty, delete specific views
      if (ids && ids.length > 0) {
        class DeleteViewCallback implements DataBaseCallBack {
          private viewIds: string[];
          private now: number;
          private threshold: number;
          
          constructor(viewIds: string[], now: number, threshold: number) {
            this.viewIds = viewIds;
            this.now = now;
            this.threshold = threshold;
          }
          
          async run(rdbStore: relationalStore.RdbStore): Promise<void> {
            for (const id of this.viewIds) {
              const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
              predicates.equalTo(FTSQL.RUM_COLUMN_ID, id);
              predicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
              predicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
              // Aligned with Android: no data_upload_time check
              await rdbStore.delete(predicates);
            }
          }
        }
        
        const callback = new DeleteViewCallback(ids, now, STALE_VIEW_THRESHOLD_MS);
        await this.getDBWithCount(true, ids.length, callback);
      } else {
        // If ids is not provided or empty, delete all closed views
        // Aligned with Android SDK: DELETE FROM view WHERE is_close=1 AND pending_resource<=0
        // Additionally, delete stale closed views (closed for >5 minutes) even if pending_resource>0
        class DeleteAllCloseViewCallback implements DataBaseCallBack {
          private now: number;
          private threshold: number;
          
          constructor(now: number, threshold: number) {
            this.now = now;
            this.threshold = threshold;
          }
          
          async run(rdbStore: relationalStore.RdbStore): Promise<void> {
            // First, delete normal closed views (pending_resource<=0)
            const normalPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            normalPredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
            normalPredicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
            // Aligned with Android: no data_upload_time check
            await rdbStore.delete(normalPredicates);
            
            // Then, delete stale closed views (closed for >5 minutes) even if pending_resource>0
            // This prevents leftover data in stress test scenarios
            const stalePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            stalePredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
            stalePredicates.greaterThan(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
            stalePredicates.lessThanOrEqualTo(FTSQL.RUM_DATA_UPDATE_TIME, this.now - this.threshold);
            await rdbStore.delete(stalePredicates);
          }
        }
        
        const callback = new DeleteAllCloseViewCallback(now, STALE_VIEW_THRESHOLD_MS);
        await this.getDB(true, callback);
      }
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
      class CloseAllCallback implements DataBaseCallBack {
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Close all views: set is_close=1, pending_resource=0, data_update_time=current time
          const viewPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          const viewValues: relationalStore.ValuesBucket = {
            is_close: 1,
            pending_resource: 0,
            data_update_time: Date.now()
          };
          await rdbStore.update(viewValues, viewPredicates);
          
          // Close all actions: set is_close=1, pending_resource=0
          const actionPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          const actionValues: relationalStore.ValuesBucket = {
            is_close: 1,
            pending_resource: 0
          };
          await rdbStore.update(actionValues, actionPredicates);
        }
      }
      
      const callback = new CloseAllCallback();
      await this.getDB(true, callback);
      FTInnerLogger.i(TAG, "All actions and views closed");
    } catch (error) {
      FTInnerLogger.e(TAG, `closeAllActionAndView failed: ${error as string}`);
    }
  }

  /**
   * Execute database operation
   * @param write Whether it's a write operation
   * @param callback Database operation callback
   */
  public async executeWithDB(write: boolean, callback: DataBaseCallBack): Promise<void> {
    await this.getDB(write, callback);
  }

  /**
   * Delete all data from database (for testing/cleanup use)
   * Deletes all data from sync_data_flat, rum_view, and rum_action tables
   * Aligned with Android: FTDBManager.delete()
   */
  public async delete(): Promise<void> {
    try {
      class DeleteAllCallback implements DataBaseCallBack {
        deletedSync: number = 0;
        deletedView: number = 0;
        deletedAction: number = 0;

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Delete all sync data
          const syncPredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
          this.deletedSync = await rdbStore.delete(syncPredicates);

          // Delete all view data
          const viewPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          this.deletedView = await rdbStore.delete(viewPredicates);

          // Delete all action data
          const actionPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          this.deletedAction = await rdbStore.delete(actionPredicates);

        }
      }

      const callback = new DeleteAllCallback();
      await this.getDB(true, callback);
      FTInnerLogger.i(TAG, `All DB data deleted: sync=${callback.deletedSync}, view=${callback.deletedView}, action=${callback.deletedAction}`);
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
      class UpdateDataTypeCallback implements DataBaseCallBack {
        count: number = 0;
        private sourceType: string;
        private targetType: string;
        private timeLine: number;
        
        constructor(sourceType: string, targetType: string, timeLine: number) {
          this.sourceType = sourceType;
          this.targetType = targetType;
          this.timeLine = timeLine;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // First count records matching criteria
          const countPredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
          countPredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.sourceType);
          countPredicates.lessThanOrEqualTo(FTSQL.RECORD_COLUMN_TM, this.timeLine);
          
          const countResult = await rdbStore.query(countPredicates, ['count(*) as count']);
          if (countResult.goToFirstRow()) {
            this.count = countResult.getLong(0);
          }
          countResult.close();
          
          if (this.count > 0) {
            // Update data type
            const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
            updatePredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.sourceType);
            updatePredicates.lessThanOrEqualTo(FTSQL.RECORD_COLUMN_TM, this.timeLine);
            
            const values: relationalStore.ValuesBucket = {};
            values[FTSQL.RECORD_COLUMN_DATA_TYPE] = this.targetType;
            
            await rdbStore.update(values, updatePredicates);
          }
        }
      }
      
      const callback = new UpdateDataTypeCallback(dataTypeStr, targetDataType, errorTimeLine);
      await this.getDB(true, callback);
      updateCount = callback.count;
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
    const expireTimeline = now - expireDuration;
    let deleteCount = 0;
    
    const dataTypeStr: string = String(dataType);
    
    try {
      class DeleteExpireCallback implements DataBaseCallBack {
        count: number = 0;
        private typeStr: string;
        private expireTime: number;
        
        constructor(typeStr: string, expireTime: number) {
          this.typeStr = typeStr;
          this.expireTime = expireTime;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          const deletePredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
          deletePredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.typeStr);
          deletePredicates.lessThan(FTSQL.RECORD_COLUMN_TM, this.expireTime);
          
          // First count records to be deleted
          const countResult = await rdbStore.query(deletePredicates, ['count(*) as count']);
          if (countResult.goToFirstRow()) {
            this.count = countResult.getLong(0);
          }
          countResult.close();
          
          if (this.count > 0) {
            // Delete expired records
            await rdbStore.delete(deletePredicates);
          }
        }
      }
      
      const callback = new DeleteExpireCallback(dataTypeStr, expireTimeline);
      await this.getDB(true, callback);
      deleteCount = callback.count;
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
    
    const uuids: string[] = [];
    try {
      class QueryRelatedUUIDsCallback implements DataBaseCallBack {
        private actionId: string;
        private measurementType: string;
        private dataTypeStr: string;
        private result: string[] = [];
        
        constructor(actionId: string, measurementType: string, dataTypeStr: string) {
          this.actionId = actionId;
          this.measurementType = measurementType;
          this.dataTypeStr = dataTypeStr;
        }
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          try {
            // Query sync_data_flat table for records matching dataType
            const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
            predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.dataTypeStr);
            
            const columns = [FTSQL.RECORD_COLUMN_DATA, FTSQL.RECORD_COLUMN_DATA_UUID];
            const resultSet = await rdbStore.query(predicates, columns);
            
            if (resultSet.goToFirstRow()) {
              do {
                const dataStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA));
                const uuid = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID));
                
                if (dataStr && uuid) {
                  // Parse Line Protocol format: measurement,tags fields timestamp
                  // Format: measurement,tag1=value1,tag2=value2 field1=value1 field2=value2 timestamp
                  // Check if this record:
                  // 1. Starts with the measurement type (e.g., "error", "resource", "long_task")
                  // 2. Contains action_id=xxx in the tags section (before the first space)
                  const measurementMatch = dataStr.startsWith(this.measurementType + ',') || 
                                          dataStr.startsWith(this.measurementType + ' ');
                  if (measurementMatch) {
                    // Find the tags section (between measurement and first space)
                    const firstSpaceIndex = dataStr.indexOf(' ');
                    const tagsSection = firstSpaceIndex > 0 ? dataStr.substring(0, firstSpaceIndex) : dataStr;
                    // Check if action_id matches in tags section
                    // Use regex to match action_id=value (avoid partial matches)
                    // Escape special regex characters in actionId
                    const escapedActionId = this.actionId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                    const actionIdPattern = new RegExp(`(^|,)action_id=${escapedActionId}(,|$)`, 'g');
                    if (actionIdPattern.test(tagsSection)) {
                      this.result.push(uuid);
                    }
                  }
                }
              } while (resultSet.goToNextRow());
            }
            resultSet.close();
          } catch (error) {
            FTInnerLogger.e(TAG, `queryRelatedUUIDsByActionId failed: ${error}`);
          }
        }
        
        getResult(): string[] {
          return this.result;
        }
      }
      
      const dataTypeStr = String(dataType);
      const callback = new QueryRelatedUUIDsCallback(actionId, measurementType, dataTypeStr);
      await this.getDB(false, callback);
      return callback.getResult();
    } catch (error) {
      FTInnerLogger.e(TAG, `queryRelatedUUIDsByActionId failed: ${error as string}`);
      return [];
    }
  }
}
