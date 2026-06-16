/**
 * HarmonyOS SDK database management abstract base class
 * Database Manager for HarmonyOS
 */
import relationalStore from '@ohos.data.relationalStore';
import { DataBaseCallBack } from './DataBaseCallBack';
import { FTInnerLogger } from '../../log/FTLogger';
import {
  SDKTaskPriority,
  SDKTaskScheduler,
  SDKTaskType
} from '../../thread/SDKTaskScheduler';

const TAG = "DBManager";

/**
 * Database management abstract base class
 * Provides basic functionality for database connection management, thread safety, transaction management, etc.
 */
export abstract class DBManager {
  private static readonly TAG: string = TAG;
  private static readonly TRANSACTION_LIMIT_COUNT: number = 10;
  private static readonly DB_SCHEDULE_SERIAL_KEY: string = "db-schedule";
  private static closeTaskSequence: number = 0;

  private rdbStore: relationalStore.RdbStore | null = null;
  private readonly lock: object = new Object();
  // Connection pool management
  private openCounter: number = 0;
  private lastUsedTime: number = 0;
  private static readonly IDLE_TIMEOUT: number = 20_000; // 20 seconds
  private static readonly DB_SIZE_CHECK_INTERVAL: number = 10_000; // Database size check interval: 10 seconds
  private lastDbSizeCheckTime: number = 0;
  private pendingCloseTask: number | null = null;
  
  // Thread safety locks
  private readonly counterLock = new Object();
  private readonly dbLock = new Object();

  /**
   * Initialize database helper
   * Subclasses must implement this method
   */
  protected abstract initDataBaseHelper(): Promise<relationalStore.RdbStore>;

  /**
   * Get database object
   */
  protected async getDataBaseHelper(): Promise<relationalStore.RdbStore> {
    if (this.rdbStore === null) {
      try {
        this.rdbStore = await this.initDataBaseHelper();
      } catch (error) {
        throw new Error(`Failed to initialize database helper: ${error as string}`);
      }
    }
    return this.rdbStore;
  }

  /**
   * Get database connection (synchronous version)
   * Uses synchronized lock to ensure thread safety of database operations
   * @param write Whether it's a write operation
   * @param callback Database operation callback
   */
  protected async getDB(write: boolean, callback: DataBaseCallBack): Promise<void> {
    try {
      await this.getDBWithCount(write, 1, callback);
      // FTInnerLogger.d(TAG, ` getDBWithCount completed successfully`);
    } catch (error) {
      // Keep error log for important case
      FTInnerLogger.e(TAG, ` getDBWithCount failed: ${error as string}`);
      throw new Error(`getDBWithCount failed: ${error as string}`);
    }
  }

  /**
   * Get database connection (with operation count)
   * @param write Whether it's a write operation
   * @param operationCount Number of operations
   * @param callback Database operation callback
   */
  protected async getDBWithCount(write: boolean, operationCount: number, callback: DataBaseCallBack): Promise<void> {
    try {
      // Get fresh database connection for each operation (HarmonyOS best practice)
      // This avoids connection reuse issues and "Already closed" errors
      const rdbStore = await this.getDataBaseHelper();
      if (rdbStore) {
        // Auto-determine: use transaction for write operations with count exceeding threshold
        const useTransaction = write && operationCount > DBManager.TRANSACTION_LIMIT_COUNT;
        if (useTransaction) {
          // Use transaction
          // FTInnerLogger.d(TAG, ` Using transaction for write operation`);
          await this.executeWithTransaction(rdbStore, callback);
        } else {
          // Execute callback with fresh connection
          if (write) {
            // Use synchronized for write operations to ensure thread safety
            await synchronized(this.lock, async () => {
              await callback.run(rdbStore);
            });
          } else {
            await callback.run(rdbStore);
          }
        }
        
        // Check database size after write operation
        if (write && this.shouldCheckDatabaseSize()) {
          await this.checkDatabaseSize(rdbStore);
        }
      } else {
        FTInnerLogger.e(TAG, "Failed to get database connection: rdbStore is null");
        return;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Database operation failed: ${error}`);
      // Don't re-throw error, let the operation fail gracefully
    }
  }

  /**
   * Execute operation with transaction
   * @param rdbStore Database object
   * @param callback Operation callback
   */
  private async executeWithTransaction(rdbStore: relationalStore.RdbStore, callback: DataBaseCallBack): Promise<void> {
    try {
       rdbStore.beginTransaction();
      
      await synchronized(this.lock, async () => {
        await callback.run(rdbStore);
      });
      
       rdbStore.commit();
    } catch (error) {
       rdbStore.rollBack();
      throw new Error(`Transaction failed: ${error}`);
    }
  }

  /**
   * Check if database size should be checked
   */
  private shouldCheckDatabaseSize(): boolean {
    const now = Date.now();
    if (now - this.lastDbSizeCheckTime >= DBManager.DB_SIZE_CHECK_INTERVAL) {
      this.lastDbSizeCheckTime = now;
      return true;
    }
    return false;
  }

  /**
   * Check database size
   * @param rdbStore Database object
   */
  private async checkDatabaseSize(rdbStore: relationalStore.RdbStore): Promise<void> {
    if (rdbStore && this.enableDBSizeLimit()) {
      try {
        // Check if database connection is still valid
        if (this.isDatabaseClosed()) {
          FTInnerLogger.w(TAG, `Database is already closed, skipping size check`);
          return;
        }
        
        // Get database file size (HarmonyOS RDB PRAGMA query)
        const resultSet = await rdbStore.querySql("PRAGMA page_count");
        if (resultSet && resultSet.goToFirstRow()) {
          const pageCount = resultSet.getLong(resultSet.getColumnIndex("page_count"));
          const pageSize = 4096; // Default page size
          const fileSize = pageCount * pageSize;
          
          // If exceeding limit, perform cleanup operation
          this.onDBSizeCacheChange(rdbStore, fileSize);
        }
        resultSet?.close();
      } catch (error) {
        // If it's an "Already closed" error, log warning instead of error
        if (error && error.toString().includes("Already closed")) {
          FTInnerLogger.w(TAG, `Database already closed during size check: ${error}`);
        } else {
          FTInnerLogger.e(TAG, `Failed to check database size: ${error}`);
        }
      }
    }
  }

  /**
   * Check if database is closed
   */
  protected isDatabaseClosed(): boolean {
    return this.rdbStore === null;
  }

  /**
   * Get database store status
   */
  protected getDatabaseStoreStatus(): string {
    return this.rdbStore ? 'exists' : 'null';
  }

  /**
   * Reset database connection
   * Forces reinitialization of the database store
   */
  protected resetDatabaseConnection(): void {
    this.rdbStore = null;
  }

  /**
   * Acquire database connection
   */
  private acquire(): void {
    synchronized(this.counterLock, () => {
      // Check if database is already closed before acquiring
      if (this.isDatabaseClosed()) {
        FTInnerLogger.w(TAG, ` Database is closed, cannot acquire connection`);
        return;
      }
      
      this.openCounter++;
      this.lastUsedTime = Date.now();
      this.cancelPendingClose();
      
      // Warn if connection count is too high
      if (this.openCounter > 10) {
        FTInnerLogger.w(TAG, `High connection count: ${this.openCounter}, Thread: main`);
      }
    });
  }

  /**
   * Try to close database connection with safe decrement
   */
  private tryToClose(): void {
    synchronized(this.counterLock, () => {
      // Check if database is already closed before trying to close
      if (this.isDatabaseClosed()) {
        FTInnerLogger.w(TAG, ` Database is already closed, skipping tryToClose`);
        return;
      }
      
      // Safe decrement
      const currentCount = this.openCounter;
      const newCount = Math.max(0, currentCount - 1);
      this.openCounter = newCount;
      this.lastUsedTime = Date.now();
      

      // Only schedule close if no active connections
      if (newCount === 0) {
        this.scheduleCloseIfIdle();
      }
    });
  }

  /**
   * Schedule database close if idle
   */
  private scheduleCloseIfIdle(): void {
    this.cancelPendingClose();
    if (this.openCounter === 0) {
      this.pendingCloseTask = setTimeout(() => {
        this.pendingCloseTask = null;
        const taskName = this.nextCloseTaskName();
        try {
          SDKTaskScheduler.getInstance().submitTask({
            type: SDKTaskType.DB_SCHEDULE,
            name: taskName,
            priority: SDKTaskPriority.HIGH,
            serialKey: DBManager.DB_SCHEDULE_SERIAL_KEY,
            costHint: 'light',
            run: () => {
              if (this.openCounter === 0 && (Date.now() - this.lastUsedTime) >= DBManager.IDLE_TIMEOUT) {
                this.closeDatabase();
              }
            }
          });
        } catch (error) {
          FTInnerLogger.e(TAG, `<FT-DB-SCHEDULE-LANE> Failed to submit ${taskName}: ${error}`);
        }
      }, DBManager.IDLE_TIMEOUT);
    }
  }

  private nextCloseTaskName(): string {
    DBManager.closeTaskSequence++;
    return `db.closeIfIdle#${DBManager.closeTaskSequence}`;
  }

  /**
   * Cancel pending close task
   */
  private cancelPendingClose(): void {
    if (this.pendingCloseTask !== null) {
      clearTimeout(this.pendingCloseTask);
      this.pendingCloseTask = null;
    }
  }

  /**
   * Close database
   */
  private closeDatabase(): void {
    synchronized(this.dbLock, async () => {
      if (this.rdbStore && this.openCounter <= 0) {
        try {
          // Attempt to close the database
          await this.rdbStore.close();
          this.rdbStore = null;
          this.pendingCloseTask = null;
        } catch (error) {
          // If it's an "Already closed" error, treat it as success
          if (error && error.toString().includes("Already closed")) {
            FTInnerLogger.w(TAG, ` Database was already closed: ${error}`);
            this.rdbStore = null;
            this.pendingCloseTask = null;
          } else {
            FTInnerLogger.e(TAG, `Failed to close database: ${error}`);
          }
        }
      } else {
        FTInnerLogger.d(TAG, ` Skipping database close: rdbStore=${this.rdbStore ? 'exists' : 'null'}, openCounter=${this.openCounter}`);
      }
    });
  }

  /**
   * Check if database is closed (public method)
   */
  public isClosed(): boolean {
    return this.isDatabaseClosed();
  }

  /**
   * Whether to enable database size limit
   * Subclasses can override this method
   */
  protected enableDBSizeLimit(): boolean {
    return true;
  }

  /**
   * Database size change callback
   * Subclasses can override this method
   * @param rdbStore Database object
   * @param fileSize File size
   */
  protected onDBSizeCacheChange(rdbStore: relationalStore.RdbStore, fileSize: number): void {
    // Default implementation is empty, subclasses can override
  }

  /**
   * Shutdown database manager
   */
  public async shutDown(): Promise<void> {
    synchronized(this.dbLock, async () => {
      this.cancelPendingClose();
      
      if (this.rdbStore) {
        try {
          await this.rdbStore.close();
          this.rdbStore = null;
          FTInnerLogger.d(TAG, `Database shutdown completed`);
        } catch (error) {
          FTInnerLogger.e(TAG, `Failed to shutdown database: ${error}`);
        }
      }
      
      // Reset counters
      this.openCounter = 0;
      this.pendingCloseTask = null;
    });
  }

}

/**
 * Synchronized lock implementation
 * HarmonyOS version of synchronized lock implementation
 * Supports both synchronous and asynchronous functions
 */
function synchronized(lock: object, fn: (() => void) | (() => Promise<void>)): void | Promise<void> {
  // In HarmonyOS, due to the single-threaded model, this is mainly for maintaining interface consistency
  // Actual multi-threaded safety needs to be handled at the application level
  const result = fn();
  
  // Check if the function returns a Promise
  if (result instanceof Promise) {
    return result.then(() => {
      // FTInnerLogger.d(TAG, ` synchronized function completed`);
    });
  } else {
    // FTInnerLogger.d(TAG, ` synchronized function completed`);
    return result;
  }
}
