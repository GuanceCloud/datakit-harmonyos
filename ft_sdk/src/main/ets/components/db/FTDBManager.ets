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

/**
 * HarmonyOS SDK Database Manager
 * Inherits from DBManager, implements specific business logic
 */
export class FTDBManager extends DBManager {
  private static instance: FTDBManager | null = null;
  private databaseHelper: DatabaseHelper | null = null;
  private readonly context: Context;
  private initPromise: Promise<void> | null = null;
  
  // Thread-safe Set for deduplication (using Map for thread-safety in async operations)
  // Key format: "dataType:uniqueId" (e.g., "rum_app:action_id=xxx" or "log:uuid=xxx")
  private insertedDataIds: Map<string, boolean> = new Map();
  private dedupLock: Promise<void> = Promise.resolve(); // Promise-based lock for async operations
  
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

  /**
   * Check if data already exists using in-memory Set (thread-safe)
   * @param dataType Data type
   * @param dataString Line protocol data string
   * @returns Promise<boolean> True if data exists, false otherwise
   */
  private async checkDataExists(dataType: DataType, dataString: string): Promise<boolean> {
    try {
      const uniqueId = this.extractUniqueId(dataType, dataString);
      if (!uniqueId) {
        // Cannot extract unique ID, skip deduplication check
        return false;
      }

      // Build key: "dataType:uniqueId"
      const key = `${dataType.toString()}:${uniqueId}`;
      
      // Use Promise-based lock to ensure thread-safety in async operations
      return await new Promise<boolean>((resolve) => {
        this.dedupLock = this.dedupLock.then(async () => {
          // Check in-memory Set first (fast path)
          if (this.insertedDataIds.has(key)) {
            resolve(true);
            return;
          }
          
          // Also check database (in case data was inserted before app restart)
          try {
            const rdbStore = await this.getDataBaseHelper();
            if (rdbStore) {
              const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
              predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType.toString());
              
              // Build search pattern based on unique identifier
              let searchPattern: string = '';
              if (uniqueId.startsWith('action_id=')) {
                const actionId = uniqueId.substring(10);
                searchPattern = `action_id=${actionId}`;
              } else if (uniqueId.startsWith('view_id=')) {
                const viewId = uniqueId.substring(8);
                searchPattern = `view_id=${viewId}`;
              } else if (uniqueId.startsWith('uuid=')) {
                const uuid = uniqueId.substring(5);
                searchPattern = uuid;
              } else if (uniqueId.startsWith('error_type=')) {
                const errorType = uniqueId.split(':')[0].substring(11);
                searchPattern = `error_type=${errorType}`;
              } else if (uniqueId.startsWith('long_task_name=')) {
                const longTaskName = uniqueId.split(':')[0].substring(15);
                searchPattern = `long_task_name=${longTaskName}`;
              } else {
                searchPattern = uniqueId;
              }

              const escapedPattern = searchPattern.replace(/%/g, '\\%').replace(/_/g, '\\_');
              predicates.like(FTSQL.RECORD_COLUMN_DATA, `%${escapedPattern}%`);

              const resultSet = await rdbStore.query(predicates, ['_id']);
              const exists = resultSet.goToFirstRow();
              resultSet.close();
              
              if (exists) {
                // Add to memory Set for future checks
                this.insertedDataIds.set(key, true);
                resolve(true);
                return;
              }
            }
          } catch (error) {
            FTInnerLogger.e(TAG, `Error checking database for duplicate: ${error as string}`);
          }
          
          resolve(false);
        }).catch(() => {
          FTInnerLogger.e(TAG, `Error in dedup lock`);
          resolve(false); // On error, allow insert (fail-safe)
        });
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error checking data existence: ${error as string}`);
      // On error, allow insert (fail-safe)
      return false;
    }
  }

  /**
   * Delete duplicate data from database based on unique identifier
   * Used to ensure only one record exists per action_id/view_id
   * @param dataType Data type
   * @param uniqueId Unique identifier (e.g., "action_id=xxx", "view_id=xxx")
   * @returns Promise<boolean> True if deletion was successful or no record found, false on error
   */
  private async deleteDuplicateData(dataType: DataType, uniqueId: string): Promise<boolean> {
    try {
      const rdbStore = await this.getDataBaseHelper();
      if (!rdbStore) {
        FTInnerLogger.e(TAG, `Duplicate cleanup failed: database unavailable`);
        return false;
      }

      // Build search pattern based on unique identifier
      let searchPattern: string = '';
      if (uniqueId.startsWith('action_id=')) {
        const actionId = uniqueId.substring(10);
        searchPattern = `action_id=${actionId}`;
      } else if (uniqueId.startsWith('view_id=')) {
        const viewId = uniqueId.substring(8);
        searchPattern = `view_id=${viewId}`;
      } else {
        FTInnerLogger.w(TAG, `Duplicate cleanup skipped: unsupported uniqueId ${uniqueId}`);
        return false;
      }

      const escapedPattern = searchPattern.replace(/%/g, '\\%').replace(/_/g, '\\_');
      
      // Delete records matching the pattern
      const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
      predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType.toString());
      predicates.like(FTSQL.RECORD_COLUMN_DATA, `%${escapedPattern}%`);

      const deletedRows = await rdbStore.delete(predicates);
      
      // Remove from memory Set as well
      const key = `${dataType.toString()}:${uniqueId}`;
      this.insertedDataIds.delete(key);
      
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `Duplicate cleanup failed: ${error as string}`);
      return false;
    }
  }

  /**
   * Mark data as inserted (add to in-memory Set)
   * Thread-safe: uses Promise-based lock for async operations
   * @param dataType Data type
   * @param dataString Line protocol data string
   */
  private async markDataAsInserted(dataType: DataType, dataString: string): Promise<void> {
    try {
      const uniqueId = this.extractUniqueId(dataType, dataString);
      if (!uniqueId) {
        return;
      }

      const key = `${dataType.toString()}:${uniqueId}`;
      
      // Use Promise-based lock to ensure thread-safety in async operations
      this.dedupLock = this.dedupLock.then(async () => {
        // Limit the size of insertedDataIds to prevent memory leak
        if (this.insertedDataIds.size > Constants.MAX_MAP_SIZE_DB) {
          FTInnerLogger.w(TAG, `Dedup cache exceeded limit, clearing memory cache`);
          this.insertedDataIds.clear();
        }
        this.insertedDataIds.set(key, true);
      }).catch(() => {
        FTInnerLogger.e(TAG, `Error marking data as inserted`);
      });
      
      // Wait for the lock to complete
      await this.dedupLock;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error marking data as inserted: ${error as string}`);
    }
  }

  /**
   * Insert sync data
   * @param data Sync data
   * @param reInsert Whether to re-insert
   * @returns boolean
   */
  public async insertFtOperation(data: SyncData, reInsert: boolean = false): Promise<boolean> {
    try {
      // Note: Database size limit check is done in FTTrackInner before calling insertFtOperation
      // (aligned with Android: optRUMCachePolicy/optLogCachePolicy are called in FTTrackInner)
      
      // Check for duplicate data before insert
      if (!reInsert) {
        const dataString = data.getDataString();
        const dataType = data.getDataType();
        const exists = await this.checkDataExists(dataType, dataString);
        if (exists) {
          // For action and view data, delete old record and insert new one to ensure only one record per action_id/view_id
          const uniqueId = this.extractUniqueId(dataType, dataString);
          if (uniqueId && (uniqueId.startsWith('action_id=') || uniqueId.startsWith('view_id='))) {
            const deleted = await this.deleteDuplicateData(dataType, uniqueId);
            if (!deleted) {
              // Keep warning log for failed delete operation
              FTInnerLogger.w(TAG, `Duplicate data skipped: uuid=${data.getUuid()}, type=${dataType}`);
              return false; // Failed to delete old record, skip insert
            }
          } else {
            return false; // Data already exists, skip insert
          }
        }
      }
      
      class InsertCallback implements DataBaseCallBack {
        private insertSuccess: boolean = false;
        private rowId: number = -1;
        private errorMessage: string = "";
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Use ValuesBucket type
          const values: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
          values[FTSQL.RECORD_COLUMN_TM] = data.getTime();
          values[FTSQL.RECORD_COLUMN_DATA_UUID] = data.getUuid();
          values[FTSQL.RECORD_COLUMN_DATA] = data.getDataString();
          // Use custom dataType string if available (for error_sampled types), otherwise use enum toString
          const customDataType = data.getCustomDataTypeString();
          values[FTSQL.RECORD_COLUMN_DATA_TYPE] = customDataType || data.getDataType().toString();

          // Log the actual stored type (customDataTypeString if available, otherwise enum toString)
          //const actualStoredType = customDataType || data.getDataType().toString();
          //FTInnerLogger.d(TAG, `Inserting data: uuid=${data.getUuid()}, type=${actualStoredType}, time=${data.getTime()}`);
          
          try {
            const rowId = rdbStore.insert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, values);
            if (rowId instanceof Promise) {
              const id = await rowId;
              const numericId = Number(id);
              if (numericId > 0) {
                data.setId(numericId);
                this.insertSuccess = true;
                this.rowId = numericId;
                // FTInnerLogger.d(TAG, `Insert completed with rowId: ${id}`);
              } else {
                this.insertSuccess = false;
                this.errorMessage = `Invalid rowId returned: ${id}`;
                // FTInnerLogger.e(TAG, `Insert failed: invalid rowId ${id}`);
              }
            } else {
              const numericId = Number(rowId);
              if (numericId > 0) {
                data.setId(numericId);
                this.insertSuccess = true;
                this.rowId = numericId;
              } else {
                this.insertSuccess = false;
                this.errorMessage = `Invalid rowId returned: ${rowId}`;
                FTInnerLogger.e(TAG, `Insert failed: invalid rowId ${rowId}`);
              }
            }
          } catch (error) {
            this.insertSuccess = false;
            this.errorMessage = error?.toString() || "Unknown error";
            FTInnerLogger.e(TAG, `Insert failed: ${error}`);
            
            // Re-throw "Already closed" errors to trigger reconnection logic
            if (error && error.toString().includes("Already closed")) {
              throw new Error(`Database already closed: ${error}`);
            }
          }
        }
        
        getInsertSuccess(): boolean {
          return this.insertSuccess;
        }
        
        getRowId(): number {
          return this.rowId;
        }
        
        getErrorMessage(): string {
          return this.errorMessage;
        }
      }
      
      const callback: InsertCallback = new InsertCallback();
      
      // Removed test debug logs to reduce log output
      // FTInnerLogger.d(TAG, ` About to call getDBAsync for insert: uuid=${data.getUuid()}`);
      
      // Check if database is closed and reinitialize if needed
      const isClosed = this.isDatabaseClosed();
      // Removed test debug log to reduce log output
      // FTInnerLogger.d(TAG, ` Database closed check: ${isClosed}, rdbStore=${this.getDatabaseStoreStatus()}`);
      
      if (isClosed) {
        FTInnerLogger.w(TAG, `DB closed during insert, reinitializing`);
        await this.init();
        // Removed test debug log to reduce log output
        // FTInnerLogger.d(TAG, ` Database reinitialized, rdbStore=${this.getDatabaseStoreStatus()}`);
      }
      
      try {
        await this.getDB(true, callback);
        // Removed test debug log to reduce log output
        // FTInnerLogger.d(TAG, ` getDBAsync call completed: uuid=${data.getUuid()}`);
        
        const insertSuccess = callback.getInsertSuccess();
        const rowId = callback.getRowId();
        const errorMessage = callback.getErrorMessage();
        
        // FTInnerLogger.d(TAG, `Insert result: success=${insertSuccess}, rowId=${rowId}, uuid=${data.getUuid()}`);
        
        if (insertSuccess && rowId > 0) {
          data.setId(rowId);
          FTInnerLogger.d(TAG, `Sync data generated: type=${data.getDataType()}, uuid=${data.getUuid()}`);
          
          // Mark data as inserted in memory Set (for future deduplication)
          if (!reInsert) {
            const dataString = data.getDataString();
            const dataType = data.getDataType();
            await this.markDataAsInserted(dataType, dataString);
          }
          
          return true;
        } else {
          // Check if it's an "Already closed" error and retry once
          if (errorMessage && errorMessage.includes("Already closed")) {
            // Keep warning log for important case
            FTInnerLogger.w(TAG, `DB closed during insert, retrying once`);
            
            // Force reinitialize database
            this.resetDatabaseConnection();
            await this.init();
            
            // Retry the insert operation with a fresh callback
            const retryCallback: InsertCallback = new InsertCallback();
            
            // Use getDBAsync for retry operation but with a fresh callback
            // This will trigger the retry logic in getDBAsync
            try {
              await this.getDB(true, retryCallback);
              
              const retrySuccess = retryCallback.getInsertSuccess();
              const retryRowId = retryCallback.getRowId();
              const retryErrorMessage = retryCallback.getErrorMessage();
              
              if (retrySuccess && retryRowId > 0) {
                data.setId(retryRowId);
                FTInnerLogger.d(TAG, `Sync data generated after retry: type=${data.getDataType()}, uuid=${data.getUuid()}`);
                return true;
              } else {
                FTInnerLogger.e(TAG, `Retry insert failed: uuid=${data.getUuid()}, error=${retryErrorMessage}`);
                return false;
              }
            } catch (retryError) {
              // Keep error log for important case
              FTInnerLogger.e(TAG, `Retry insert failed: ${retryError}`);
              return false;
            }
          } else {
            FTInnerLogger.e(TAG, `Insert failed: uuid=${data.getUuid()}, error=${errorMessage}`);
            return false;
          }
        }
      } catch (dbError) {
        throw new Error(`Database insert failed: ${dbError}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Insert sync data failed: ${error as string}`);
      return false;
    }
  }

  /**
   * Batch insert sync data
   * @param dataList Data list
   * @param reInsert Whether to re-insert
   * @returns boolean
   */
  public async insertFtOptList(dataList: SyncData[], reInsert: boolean = false): Promise<boolean> {
    if (!dataList || dataList.length === 0) {
      return true;
    }

    try {
      // Filter out duplicate data before insert (using in-memory Set for fast lookup)
      const filteredDataList: SyncData[] = [];
      const seenInBatch: Map<string, boolean> = new Map(); // For batch-internal deduplication
      
      if (!reInsert) {
        for (const data of dataList) {
          const dataString = data.getDataString();
          const dataType = data.getDataType();
          const uniqueId = this.extractUniqueId(dataType, dataString);
          
          if (!uniqueId) {
            // Cannot extract unique ID, allow insert
            filteredDataList.push(data);
            continue;
          }
          
          const key = `${dataType.toString()}:${uniqueId}`;
          
          // Check batch-internal duplicates first (fast path)
          if (seenInBatch.has(key)) {
            continue;
          }
          
          // Check memory Set and database
          const exists = await this.checkDataExists(dataType, dataString);
          if (!exists) {
            seenInBatch.set(key, true);
            filteredDataList.push(data);
          }
        }
        
        if (filteredDataList.length === 0) {
          // Keep info log for important case (all duplicates)
          FTInnerLogger.i(TAG, `Batch insert skipped: all ${dataList.length} items are duplicates`);
          return true; // All data are duplicates, nothing to insert
        }
        
      } else {
        // For reInsert, don't filter
        filteredDataList.push(...dataList);
      }

      // Use batchInsert for better performance (HarmonyOS RdbStore supports true batch insert)
      let insertedCount: number = 0;
      class BatchInsertCallback implements DataBaseCallBack {
        public insertedCount: number = 0;
        
        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // Prepare ValuesBucket array for batch insert
          const valuesArray: relationalStore.ValuesBucket[] = [];
          for (const data of filteredDataList) {
            const values: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
            values[FTSQL.RECORD_COLUMN_TM] = data.getTime();
            values[FTSQL.RECORD_COLUMN_DATA_UUID] = data.getUuid();
            values[FTSQL.RECORD_COLUMN_DATA] = data.getDataString();
            // Use custom dataType string if available (for error_sampled types), otherwise use enum toString
            const customDataType = data.getCustomDataTypeString();
            values[FTSQL.RECORD_COLUMN_DATA_TYPE] = customDataType || data.getDataType().toString();
            valuesArray.push(values);
          }
          
          // Execute batch insert (batchInsert uses transaction internally for better performance)
          this.insertedCount = await rdbStore.batchInsert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, valuesArray);
          
          // batchInsert returns the number of inserted rows
          if (this.insertedCount > 0) {
            FTInnerLogger.d(TAG, `Batch data generated: ${this.insertedCount} items`);
            // Note: batchInsert doesn't return individual rowIds, so we can't set IDs for each data item
            // This is acceptable as IDs are mainly used for deletion, which can be done by UUID
          } else {
            FTInnerLogger.e(TAG, `Batch insert failed: inserted ${this.insertedCount}, expected ${filteredDataList.length}`);
          }
        }
      }
      
      const callback = new BatchInsertCallback();
      
      await this.getDB(true, callback);
      
      insertedCount = callback.insertedCount;

      // Mark all successfully inserted data in memory Set (after insert completes)
      // Since batchInsert doesn't return individual rowIds, we mark all data as inserted if count matches
      if (!reInsert && insertedCount > 0) {
        // Mark all data as inserted (batchInsert succeeded)
        for (const data of filteredDataList) {
          const dataString = data.getDataString();
          const dataType = data.getDataType();
          await this.markDataAsInserted(dataType, dataString);
        }
      }
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to insert sync data list: ${error as string}`);
      return false;
    }
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
    // Convert single type to array if needed
    const typeArray = Array.isArray(types) ? types : [types];
    try {
      const rdbStore = await this.getDataBaseHelper();
      if (!rdbStore) {
        FTInnerLogger.e(TAG, "Failed to get database store for deleteOldestData");
        return;
      }

      // Build WHERE clause for data types
      let whereClause = "";
      if (typeArray && typeArray.length > 0) {
        const typeValues = typeArray.map(type => `'${type.toString()}'`).join(',');
        whereClause = `${FTSQL.RECORD_COLUMN_DATA_TYPE} IN (${typeValues})`;
      }

      // Build SQL: DELETE FROM table WHERE _id IN (SELECT _id FROM table WHERE ... ORDER BY tm ASC LIMIT limit)
      let sql = `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} WHERE _id IN (
        SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}`;
      
      if (whereClause) {
        sql += ` WHERE ${whereClause}`;
      }
      
      sql += ` ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit})`;

      await rdbStore.executeSql(sql);
      FTInnerLogger.i(TAG, `Oldest data deleted: types=${typeArray}, limit=${limit}`);
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
          // First, get current view_update_time value
          const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          predicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
          
          const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_VIEW_UPDATE_TIME]);
          
          if (resultSet.goToFirstRow()) {
            const columnIndex: number = resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME);
            const currentUpdateTime: number = resultSet.getLong(columnIndex);
            
            // Update with incremented counter and current timestamp for data_update_time
            const values: relationalStore.ValuesBucket = {
              view_update_time: currentUpdateTime + 1, // Increment counter - aligned with Android
              data_update_time: Date.now() // Update data update time
            };
            
            const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
            updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, this.viewId);
            await rdbStore.update(values, updatePredicates);
            
          } else {
            FTInnerLogger.w(TAG, `View not found for update: ${this.viewId}`);
          }
          resultSet.close();
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
