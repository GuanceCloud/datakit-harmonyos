/**
 * HarmonyOS SDK database helper class
 */
import relationalStore from '@ohos.data.relationalStore';
import { FTDBConfig } from '../FTDBConfig';
import * as FTSQL from '../FTSQL';
import { FTInnerLogger } from '../../log/FTLogger';

const TAG = "DatabaseHelper";

/**
 * Database helper class
 * Responsible for database creation, upgrade and table structure management
 */
export class DatabaseHelper {
  private static instance: DatabaseHelper | null = null;
  private rdbStore: relationalStore.RdbStore | null = null;
  private readonly context: Context;
  private initPromise: Promise<relationalStore.RdbStore> | null = null; // Lock for concurrent initialization

  private constructor(context: Context) {
    this.context = context;
  }

  /**
   * Get DatabaseHelper singleton
   * @param context Application context
   * @returns DatabaseHelper instance
   */
  public static getInstance(context: Context): DatabaseHelper {
    if (!DatabaseHelper.instance) {
      DatabaseHelper.instance = new DatabaseHelper(context);
    }
    return DatabaseHelper.instance;
  }

  /**
   * Initialize database
   * @returns Promise<relationalStore.RdbStore>
   */
  public async initDatabase(): Promise<relationalStore.RdbStore> {
    // Return existing store if already initialized
    if (this.rdbStore) {
      return this.rdbStore;
    }

    // If initialization is in progress, wait for it
    if (this.initPromise) {
      return await this.initPromise;
    }

    // Start initialization and store the promise to prevent concurrent initialization
    this.initPromise = this.doInitDatabase();
    return await this.initPromise;
  }

  /**
   * Internal method to perform database initialization
   * @returns Promise<relationalStore.RdbStore>
   */
  private async doInitDatabase(): Promise<relationalStore.RdbStore> {
    try {
      // Create database configuration
      const config: relationalStore.StoreConfig = {
        name: FTDBConfig.DATABASE_NAME,
        securityLevel: FTDBConfig.SECURITY_LEVEL as relationalStore.SecurityLevel,
        encrypt: FTDBConfig.ENCRYPT_MODE
      };

      // Get RDB store (HarmonyOS getRdbStore API: getRdbStore(context, config))
      // Note: HarmonyOS doesn't support RdbHelper for automatic version management like Android
      // We need to manually check version and handle upgrades
      this.rdbStore = await relationalStore.getRdbStore(this.context, config);
      
      // Always create tables first (CREATE TABLE IF NOT EXISTS is safe and idempotent)
      // This ensures tables exist even if checkTablesExist() has race conditions
      FTInnerLogger.i(TAG, "Ensuring tables exist (CREATE TABLE IF NOT EXISTS)");
      await this.createTables();
      await this.createIndexes();
      
      // After tables are created, check version and upgrade if needed
      FTInnerLogger.i(TAG, "Checking database version for upgrades");
      await this.checkAndUpgradeDatabase();
      
      FTInnerLogger.i(TAG, "Database initialized successfully");
      return this.rdbStore;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize database: ${error}`);
      // Clear the promise on error so retry is possible
      this.initPromise = null;
      throw new Error(`Database initialization failed: ${error}`);
    }
  }

  /**
   * Check if all required tables exist
   * Returns true if all tables exist, false otherwise
   */
  private async checkTablesExist(): Promise<boolean> {
    if (!this.rdbStore) {
      return false;
    }

    try {
      // Check if all three main tables exist
      const hasViewTable = await this.hasTable(FTSQL.FT_TABLE_VIEW);
      const hasActionTable = await this.hasTable(FTSQL.FT_TABLE_ACTION);
      const hasSyncTable = await this.hasTable(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
      
      // All tables must exist
      return hasViewTable && hasActionTable && hasSyncTable;
    } catch (error) {
      FTInnerLogger.w(TAG, `Error checking tables existence: ${error}`);
      return false;
    }
  }

  /**
   * Check database version and upgrade if needed
   */
  private async checkAndUpgradeDatabase(): Promise<void> {
    if (!this.rdbStore) {
      return;
    }

    try {
      // Check if version columns exist in rum_view table
      // If they don't exist, we need to upgrade from version 1 to 2
      const hasVersionColumns = await this.hasVersionColumns();
      
      if (!hasVersionColumns) {
        FTInnerLogger.i(TAG, "Database version 1 detected, upgrading to version 2");
        await this.update1to2();
      }

      // Check if sync_data_flat table exists
      // If it doesn't exist, we need to upgrade to version 3
      const hasSyncDataFlat = await this.hasTable(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
      
      if (!hasSyncDataFlat) {
        FTInnerLogger.i(TAG, "Upgrading to version 3: creating sync_data_flat table");
        await this.update2to3();
      }

      FTInnerLogger.i(TAG, "Database version check completed");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to check/upgrade database version: ${error}`);
      // Don't throw error, continue with existing database
    }
  }

  /**
   * Check if version columns exist in rum_view table
   */
  private async hasVersionColumns(): Promise<boolean> {
    if (!this.rdbStore) {
      return false;
    }

    try {
      // Try to query one of the version columns
      await this.rdbStore.querySql("SELECT " + FTSQL.RUM_DATA_UPLOAD_TIME + " FROM " + FTSQL.FT_TABLE_VIEW + " LIMIT 1");
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * Check if a table exists
   */
  private async hasTable(tableName: string): Promise<boolean> {
    if (!this.rdbStore) {
      return false;
    }

    try {
      await this.rdbStore.querySql("SELECT COUNT(*) FROM " + tableName + " LIMIT 1");
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * Create database tables (asynchronous version)
   */
  private async createTables(): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      // Create sync data table
      await this.rdbStore.executeSql(FTSQL.FT_TABLE_SYNC_CREATE);
      FTInnerLogger.d(TAG, "Created sync_data_flat table");

      // Create RUM view table
      await this.rdbStore.executeSql(FTSQL.FT_TABLE_VIEW_CREATE);
      FTInnerLogger.d(TAG, "Created rum_view table");

      // Create RUM action table
      await this.rdbStore.executeSql(FTSQL.FT_TABLE_ACTION_CREATE);
      FTInnerLogger.d(TAG, "Created rum_action table");

      FTInnerLogger.i(TAG, "All tables created successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to create tables: ${error}`);
      throw new Error(`Table creation failed: ${error}`);
    }
  }

  /**
   * Create database indexes (synchronous version for RdbOpenCallback callbacks)
   * Note: In RdbOpenCallback callbacks, executeSql is synchronous
   */
  private createIndexesSync(rdbStore: relationalStore.RdbStore): void {
    try {
      const indexSqls = FTSQL.CREATE_INDEXES;
      for (let i = 0; i < indexSqls.length; i++) {
        rdbStore.executeSql(indexSqls[i]);
      }
      FTInnerLogger.i(TAG, "All indexes created successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to create indexes: ${error}`);
      // Index creation failure does not affect main functionality, only log it
    }
  }

  /**
   * Create database indexes (asynchronous version)
   */
  private async createIndexes(): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      const indexSqls = FTSQL.CREATE_INDEXES;
      for (let i = 0; i < indexSqls.length; i++) {
        await this.rdbStore.executeSql(indexSqls[i]);
      }
      FTInnerLogger.i(TAG, "All indexes created successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to create indexes: ${error}`);
      // Index creation failure does not affect main functionality, only log it
    }
  }

  /**
   * Handle database upgrade (synchronous version for RdbOpenCallback callback)
   * Uses ALTER TABLE instead of recreating tables to preserve existing data
   * @param rdbStore RdbStore instance
   * @param oldVersion Old version number
   * @param newVersion New version number
   */
  private handleUpgradeSync(rdbStore: relationalStore.RdbStore, oldVersion: number, newVersion: number): void {
    try {
      FTInnerLogger.i(TAG, `Upgrading database from version ${oldVersion} to ${newVersion}`);

      // Handle version 1 to 2 upgrade
      if (oldVersion === 1 && newVersion === 2) {
        this.update1to2Sync(rdbStore);
      } 
      // Handle version 2 to 3 upgrade (or 1 to 3)
      else if (oldVersion < 3 && newVersion === 3) {
        this.update2to3Sync(rdbStore);
        if (oldVersion === 1) {
          this.update1to2Sync(rdbStore);
        }
      }
      // Handle direct upgrade from 1 to 3
      else if (oldVersion === 1 && newVersion === 3) {
        this.update1to2Sync(rdbStore);
        this.update2to3Sync(rdbStore);
      }

      FTInnerLogger.i(TAG, "Database upgrade completed successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Database upgrade failed: ${error}`);
      throw new Error(`Database upgrade failed: ${error}`);
    }
  }

  /**
   * Version 1 to version 2 upgrade (synchronous)
   * Uses ALTER TABLE to add new columns without losing existing data
   * Note: In RdbOpenCallback callbacks, executeSql is synchronous
   */
  private update1to2Sync(rdbStore: relationalStore.RdbStore): void {
    try {
      // Add new fields to rum_view table using ALTER TABLE (preserves existing data)
      rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_DATA_UPLOAD_TIME} BIGINT DEFAULT 0`
      );
      rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_DATA_UPDATE_TIME} BIGINT DEFAULT 0`
      );
      rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_VIEW_UPDATE_TIME} BIGINT DEFAULT 1`
      );

      FTInnerLogger.d(TAG, "Database upgraded from version 1 to 2 (using ALTER TABLE)");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to upgrade from version 1 to 2: ${error}`);
      throw new Error(`Database upgrade from version 1 to 2 failed: ${error}`);
    }
  }

  /**
   * Version 2 to version 3 upgrade (synchronous)
   * Creates new sync_data_flat table (IF NOT EXISTS, so safe if already exists)
   * Note: In RdbOpenCallback callbacks, executeSql is synchronous
   */
  private update2to3Sync(rdbStore: relationalStore.RdbStore): void {
    try {
      // Create new sync data table (IF NOT EXISTS, so safe if already exists)
      rdbStore.executeSql(FTSQL.FT_TABLE_SYNC_CREATE);
      FTInnerLogger.d(TAG, "Database upgraded from version 2 to 3");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to upgrade from version 2 to 3: ${error}`);
      throw new Error(`Database upgrade from version 2 to 3 failed: ${error}`);
    }
  }

  /**
   * Upgrade database (asynchronous version, kept for backward compatibility)
   * @param oldVersion Old version number
   * @param newVersion New version number
   */
  public async upgradeDatabase(oldVersion: number, newVersion: number): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      FTInnerLogger.i(TAG, `Upgrading database from version ${oldVersion} to ${newVersion}`);

      if (oldVersion === 1 && newVersion === 2) {
        await this.update1to2();
      } else if (oldVersion < 3 && newVersion === 3) {
        await this.update2to3();
        if (oldVersion === 1) {
          await this.update1to2();
        }
      }

      FTInnerLogger.i(TAG, "Database upgrade completed successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Database upgrade failed: ${error}`);
      throw new Error(`Database upgrade failed: ${error}`);
    }
  }

  /**
   * Version 1 to version 2 upgrade (asynchronous version)
   */
  private async update1to2(): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      // Add new fields to rum_view table
      await this.rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_DATA_UPLOAD_TIME} BIGINT DEFAULT 0`
      );
      await this.rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_DATA_UPDATE_TIME} BIGINT DEFAULT 0`
      );
      await this.rdbStore.executeSql(
        `ALTER TABLE ${FTSQL.FT_TABLE_VIEW} ADD COLUMN ${FTSQL.RUM_VIEW_UPDATE_TIME} BIGINT DEFAULT 1`
      );

      FTInnerLogger.d(TAG, "Database upgraded from version 1 to 2");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to upgrade from version 1 to 2: ${error}`);
      throw new Error(`Database upgrade from version 1 to 2 failed: ${error}`);
    }
  }

  /**
   * Version 2 to version 3 upgrade (asynchronous version)
   */
  private async update2to3(): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      // Create a new sync data table
      await this.rdbStore.executeSql(FTSQL.FT_TABLE_SYNC_CREATE);
      FTInnerLogger.d(TAG, "Database upgraded from version 2 to 3");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to upgrade from version 2 to 3: ${error}`);
      throw new Error(`Database upgrade from version 2 to 3 failed: ${error}`);
    }
  }

  /**
   * Downgrade the database
   * @param oldVersion previous version number
   * @param newVersion target version number
   */
  public async downgradeDatabase(oldVersion: number, newVersion: number): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      FTInnerLogger.i(TAG, `Downgrading database from version ${oldVersion} to ${newVersion}`);

      if (oldVersion === 3 && newVersion < 3) {
        // Recreate all tables
        await this.createTables();
      }

      FTInnerLogger.i(TAG, "Database downgrade completed successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Database downgrade failed: ${error}`);
      throw new Error(`Database downgrade failed: ${error}`);
    }
  }

  /**
   * Get the database object
   * @returns relationalStore.RdbStore
   */
  public getRdbStore(): relationalStore.RdbStore | null {
    return this.rdbStore;
  }

  /**
   * Check whether the database has been initialized
   * @returns boolean
   */
  public isInitialized(): boolean {
    return this.rdbStore !== null;
  }

  /**
   * Close the database
   */
  public async closeDatabase(): Promise<void> {
    if (this.rdbStore) {
      try {
        await this.rdbStore.close();
        this.rdbStore = null;
        FTInnerLogger.i(TAG, "Database closed successfully");
      } catch (error) {
        FTInnerLogger.e(TAG, `Failed to close database: ${error}`);
      }
    }
  }

  /**
   * Reset the database (for testing)
   */
  public async resetDatabase(): Promise<void> {
    if (!this.rdbStore) {
      throw new Error("Database not initialized");
    }

    try {
      // Drop all tables
      await this.rdbStore.executeSql(`DROP TABLE IF EXISTS ${FTSQL.FT_TABLE_ACTION}`);
      await this.rdbStore.executeSql(`DROP TABLE IF EXISTS ${FTSQL.FT_TABLE_VIEW}`);
      await this.rdbStore.executeSql(`DROP TABLE IF EXISTS ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}`);

      // Recreate tables
      await this.createTables();
      await this.createIndexes();

      FTInnerLogger.i(TAG, "Database reset completed successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to reset database: ${error}`);
      throw new Error(`Database reset failed: ${error}`);
    }
  }
}
