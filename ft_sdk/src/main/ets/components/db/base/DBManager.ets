/**
 * HarmonyOS SDK database management abstract base class
 * Database Manager for HarmonyOS
 */
import relationalStore from '@ohos.data.relationalStore';
import { DataBaseCallBack } from './DataBaseCallBack';
import { FTInnerLogger } from '../../log/FTLogger';

const TAG = "DBManager";
const LOCK_TAILS: Map<object, Promise<void>> = new Map();

export interface DBOperationTiming {
  lockWaitMs: number;
  sizeCheckMs: number;
  cleanupMs: number;
}

/**
 * Database management abstract base class
 * Provides basic functionality for database connection management, thread safety, transaction management, etc.
 */
export abstract class DBManager {
  private static readonly TAG: string = TAG;
  private static readonly TRANSACTION_LIMIT_COUNT: number = 10;

  private rdbStore: relationalStore.RdbStore | null = null;
  private readonly lock: object = new Object();
  private static readonly DB_SIZE_CHECK_INTERVAL: number = 10_000; // Database size check interval: 10 seconds
  private lastDbSizeCheckTime: number = 0;
  private noLockShutdownSimulationForTest: boolean = false;

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
  protected async getDBWithCount(
    write: boolean,
    operationCount: number,
    callback: DataBaseCallBack,
    timing?: DBOperationTiming,
    forceTransaction: boolean = false
  ): Promise<void> {
    const runOperation = async (): Promise<void> => {
      const rdbStore = await this.getDataBaseHelper();
      if (!rdbStore) {
        FTInnerLogger.e(TAG, "Failed to get database connection: rdbStore is null");
        return;
      }

      // Auto-determine: use transaction for write operations with count exceeding threshold
      const useTransaction = write && (forceTransaction || operationCount > DBManager.TRANSACTION_LIMIT_COUNT);
      if (useTransaction) {
        // Use transaction
        // FTInnerLogger.d(TAG, ` Using transaction for write operation`);
        await this.executeWithTransaction(rdbStore, callback);
      } else {
        await callback.run(rdbStore);
      }

      // Check database size after write operation
      if (write && this.shouldCheckDatabaseSize()) {
        await this.checkDatabaseSize(rdbStore, timing);
      }
    };

    try {
      if (write) {
        await synchronized(this.lock, runOperation, (lockWaitMs: number) => {
          if (timing) {
            timing.lockWaitMs += lockWaitMs;
          }
        });
      } else {
        await runOperation();
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
      await callback.run(rdbStore);
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
  private async checkDatabaseSize(rdbStore: relationalStore.RdbStore, timing?: DBOperationTiming): Promise<void> {
    if (rdbStore && this.enableDBSizeLimit()) {
      try {
        // Check if database connection is still valid
        if (this.isDatabaseClosed()) {
          FTInnerLogger.w(TAG, `Database is already closed, skipping size check`);
          return;
        }
        
        // Get database file size (HarmonyOS RDB PRAGMA query)
        const sizeCheckStartTime = Date.now();
        const resultSet = await rdbStore.querySql("PRAGMA page_count");
        if (resultSet && resultSet.goToFirstRow()) {
          const pageCount = resultSet.getLong(resultSet.getColumnIndex("page_count"));
          const pageSize = 4096; // Default page size
          const fileSize = pageCount * pageSize;
          if (timing) {
            timing.sizeCheckMs += Math.max(0, Date.now() - sizeCheckStartTime);
          }
          
          // If exceeding limit, perform cleanup operation
          await this.onDBSizeCacheChange(rdbStore, fileSize, timing);
        } else if (timing) {
          timing.sizeCheckMs += Math.max(0, Date.now() - sizeCheckStartTime);
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

  public async simulateNoLockShutdownForTest(): Promise<void> {
    this.noLockShutdownSimulationForTest = true;
    const rdbStore = this.rdbStore;
    this.rdbStore = null;
    if (rdbStore) {
      try {
        await rdbStore.close();
        FTInnerLogger.d(TAG, `No-lock DB shutdown simulation completed`);
      } catch (error) {
        FTInnerLogger.w(TAG, `No-lock DB shutdown simulation failed: ${error}`);
      }
    }
  }

  public clearNoLockShutdownSimulationForTest(): void {
    this.noLockShutdownSimulationForTest = false;
  }

  protected isNoLockShutdownSimulationForTest(): boolean {
    return this.noLockShutdownSimulationForTest;
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
  protected onDBSizeCacheChange(
    rdbStore: relationalStore.RdbStore,
    fileSize: number,
    timing?: DBOperationTiming
  ): Promise<void> | void {
    // Default implementation is empty, subclasses can override
  }

  /**
   * Shutdown database manager
   */
  public async shutDown(): Promise<void> {
    await synchronized(this.lock, async () => {
      if (this.rdbStore) {
        try {
          await this.rdbStore.close();
          this.resetDatabaseConnection();
          FTInnerLogger.d(TAG, `Database shutdown completed`);
        } catch (error) {
          if (error && error.toString().includes("Already closed")) {
            FTInnerLogger.w(TAG, `Database was already closed during shutdown: ${error}`);
            this.resetDatabaseConnection();
          } else {
            FTInnerLogger.e(TAG, `Failed to shutdown database: ${error}`);
          }
        }
      } else {
        this.resetDatabaseConnection();
      }
    });
  }

}

/**
 * Synchronized lock implementation
 * HarmonyOS version of synchronized lock implementation
 * Supports both synchronous and asynchronous functions
 */
async function synchronized(
  lock: object,
  fn: (() => void) | (() => Promise<void>),
  onStart?: (waitTime: number) => void
): Promise<void> {
  const previousTail = LOCK_TAILS.get(lock) ?? Promise.resolve();
  const waitStartTime = Date.now();
  let releaseCurrent: () => void = () => {};
  const currentTail = new Promise<void>((resolve) => {
    releaseCurrent = resolve;
  });
  const nextTail = previousTail.catch(() => {}).then(() => currentTail);
  LOCK_TAILS.set(lock, nextTail);

  await previousTail.catch(() => {});
  if (onStart) {
    onStart(Math.max(0, Date.now() - waitStartTime));
  }
  try {
    await Promise.resolve(fn());
  } finally {
    releaseCurrent();
    if (LOCK_TAILS.get(lock) === nextTail) {
      LOCK_TAILS.delete(lock);
    }
  }
}
