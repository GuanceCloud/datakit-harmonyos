import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../Configs';
import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { SyncDataJSON } from './bean/SyncData';
import { FTDBSpoolPaths, FTDBSpoolTaskPoolExecutor } from './FTDBSpoolTaskPoolExecutor';
import { FTDBTaskPoolExecutor } from './FTDBTaskPoolExecutor';

export type FTFileDataStoreMode = 'sqlite' | 'shadow' | 'file';

export interface FTFileDataStoreStatus {
  initialized: boolean;
  mode: FTFileDataStoreMode;
  storePath: string;
  pendingRecords: number;
  pendingBytes: number;
  capacityBytes: number;
  rejectedRecords: number;
  lastError: string;
}

export interface FTFileDataStoreProjectionPage {
  records: SyncDataJSON[];
  hasMore: boolean;
  nextByteOffset: number;
}

const TAG = 'FTFileDataStore';

/**
 * Durable NDJSON-backed telemetry store used for FileStore migration.
 *
 * In file mode it is written before the SQLite upload index. In shadow mode
 * it is written only after SQLite accepted the batch. Upload commits remove
 * the same UUIDs from both stores, so the mirror remains bounded and can be
 * compared safely during rollout.
 */
export class FTFileDataStore {
  private static instance: FTFileDataStore | null = null;
  private static readonly STORE_DIR_NAME = 'ft_sdk_file_store';
  private static readonly ACTIVE_FILE_NAME = 'sync_data.active.ndjson';
  private static readonly INFLIGHT_FILE_NAME = 'sync_data.inflight.ndjson';
  private static readonly LEGACY_FILE_NAME = 'sync_data.ndjson';

  private initialized: boolean = false;
  private enabled: boolean = false;
  private primary: boolean = false;
  private shadow: boolean = false;
  private capacityBytes: number = Constants.DEFAULT_CACHE_LIMIT_SIZE;
  private migrationMarkerPath: string = '';
  private paths: FTDBSpoolPaths = {
    spoolDir: '',
    activePath: '',
    inflightPath: '',
    legacyPath: ''
  };
  private initPromise: Promise<void> | null = null;
  private nextSequence: number = 0;
  private pendingRecords: number = 0;
  private pendingBytes: number = 0;
  private rejectedRecords: number = 0;
  private lastError: string = '';

  private constructor() {
  }

  public static getInstance(): FTFileDataStore {
    if (FTFileDataStore.instance === null) {
      FTFileDataStore.instance = new FTFileDataStore();
    }
    return FTFileDataStore.instance;
  }

  public init(context: Context, config: FTSDKConfig): void {
    this.enabled = config.isFileDataStoreEnabled();
    this.primary = this.enabled && config.isUseFileDataStore();
    this.shadow = this.enabled && config.isFileDataStoreShadow();
    this.capacityBytes = config.isLimitWithCacheSize() ?
      config.getCacheLimit() : Constants.DEFAULT_CACHE_LIMIT_SIZE;

    if (!this.enabled) {
      return;
    }

    const storeDir = this.joinPath(context.filesDir, FTFileDataStore.STORE_DIR_NAME);
    if (this.initialized && this.paths.spoolDir === storeDir) {
      return;
    }
    this.paths = {
      spoolDir: storeDir,
      activePath: this.joinPath(storeDir, FTFileDataStore.ACTIVE_FILE_NAME),
      inflightPath: this.joinPath(storeDir, FTFileDataStore.INFLIGHT_FILE_NAME),
      legacyPath: this.joinPath(storeDir, FTFileDataStore.LEGACY_FILE_NAME)
    };
    this.migrationMarkerPath = this.joinPath(storeDir, 'sqlite_migration_v1.complete');
    this.initialized = true;
    this.lastError = '';
    this.initPromise = this.initializeState();
  }

  public isEnabled(): boolean {
    return this.enabled && this.initialized;
  }

  public isPrimary(): boolean {
    return this.isEnabled() && this.primary;
  }

  public isShadow(): boolean {
    return this.isEnabled() && this.shadow;
  }

  public shouldMirrorSqliteWrites(): boolean {
    return this.isEnabled() && (this.primary || this.shadow);
  }

  public async appendSyncDataJSON(source: string, records: SyncDataJSON[]): Promise<number> {
    if (!this.shouldMirrorSqliteWrites() || !records || records.length === 0) {
      return 0;
    }
    await this.awaitInitialized();
    const validRows: SyncDataJSON[] = [];
    for (let i = 0; i < records.length; i++) {
      const record = records[i];
      if (record && record.dataString && record.uuid && record.time > 0) {
        validRows.push(record);
      }
    }
    if (validRows.length === 0) {
      return 0;
    }

    const sequenceStart = this.nextSequence;
    this.nextSequence += validRows.length;
    try {
      const response = await FTDBSpoolTaskPoolExecutor.append(
        this.paths,
        source,
        sequenceStart,
        validRows,
        this.capacityBytes
      );
      this.pendingRecords = response.pendingRecordsKnown ? response.pendingRecords :
        this.pendingRecords + response.appendedRecords;
      this.pendingBytes = response.pendingBytes;
      this.rejectedRecords += response.rejectedRecords;
      if (response.rejectedRecords > 0) {
        this.recordError(`FileStore capacity rejected ${response.rejectedRecords} record(s) from ${source}`);
      }
      return response.appendedRecords;
    } catch (error) {
      this.recordError(`FileStore append failed: ${this.toErrorMessage(error)}`);
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  public async removeByUuids(uuids: string[]): Promise<number> {
    if (!this.isEnabled() || !uuids || uuids.length === 0) {
      return 0;
    }
    await this.awaitInitialized();
    try {
      const response = await FTDBSpoolTaskPoolExecutor.removeByUuids(this.paths, uuids, this.capacityBytes);
      this.pendingRecords = response.pendingRecords;
      this.pendingBytes = response.pendingBytes;
      return response.removedRecords;
    } catch (error) {
      this.recordError(`FileStore remove failed: ${this.toErrorMessage(error)}`);
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  public async clear(): Promise<void> {
    if (!this.initialized || this.paths.spoolDir.length === 0) {
      return;
    }
    await this.awaitInitialized();
    const response = await FTDBSpoolTaskPoolExecutor.clear(this.paths);
    this.pendingRecords = response.pendingRecords;
    this.pendingBytes = response.pendingBytes;
    this.nextSequence = 0;
    this.rejectedRecords = 0;
    this.lastError = '';
  }

  /**
   * Copy the legacy SQLite pending queue to FileStore once. This is opt-in via
   * FTSDKConfig.setNeedTransformOldCache(true) so existing applications retain
   * their current SQLite behavior until they choose a migration.
   */
  public async migrateLegacySqlite(context: Context): Promise<number> {
    if (!this.isPrimary()) {
      return 0;
    }
    await this.awaitInitialized();
    if (this.migrationMarkerPath && await FTDBSpoolTaskPoolExecutor.hasMarker(this.paths, this.migrationMarkerPath)) {
      return 0;
    }

    const pageSize = 256;
    let afterId = 0;
    let migrated = 0;
    while (true) {
      const rows = await FTDBTaskPoolExecutor.querySyncDataAfterId(context, afterId, pageSize);
      if (rows.length === 0) {
        break;
      }
      const records: SyncDataJSON[] = [];
      for (let i = 0; i < rows.length; i++) {
        records.push(rows[i].toJSON());
      }
      const appended = await this.appendSyncDataJSON('sqlite.migration', records);
      if (appended !== records.length) {
        throw new Error(`FileStore migration persisted ${appended}/${records.length} records`);
      }
      migrated += appended;
      afterId = rows[rows.length - 1].getId();
      if (rows.length < pageSize) {
        break;
      }
    }
    if (this.migrationMarkerPath) {
      await FTDBSpoolTaskPoolExecutor.writeMarker(this.paths, this.migrationMarkerPath);
    }
    FTInnerLogger.i(TAG, `Migrated ${migrated} SQLite cache record(s) to FileStore`);
    return migrated;
  }

  /**
   * Replay durable FileStore rows into the SQLite upload index after startup.
   * The supplied projector must use UUID upsert semantics; source files are
   * intentionally retained until the normal upload commit removes them.
   */
  public async projectToSqlite(projector: (records: SyncDataJSON[]) => Promise<void>): Promise<number> {
    if (!this.isPrimary()) {
      return 0;
    }
    await this.awaitInitialized();
    const paths = [this.paths.legacyPath, this.paths.inflightPath, this.paths.activePath];
    let projected = 0;
    for (let pathIndex = 0; pathIndex < paths.length; pathIndex++) {
      let byteOffset = 0;
      while (true) {
        const page = await this.readProjectionPage(paths[pathIndex], byteOffset);
        if (page.records.length > 0) {
          await projector(page.records);
          projected += page.records.length;
        }
        if (!page.hasMore) {
          break;
        }
        if (page.nextByteOffset <= byteOffset) {
          throw new Error(`FileStore projection cursor did not advance: path=${paths[pathIndex]}, offset=${byteOffset}`);
        }
        byteOffset = page.nextByteOffset;
      }
    }
    return projected;
  }

  public getStatus(): FTFileDataStoreStatus {
    return {
      initialized: this.initialized,
      mode: this.primary ? 'file' : (this.shadow ? 'shadow' : 'sqlite'),
      storePath: this.paths.activePath,
      pendingRecords: this.pendingRecords,
      pendingBytes: this.pendingBytes,
      capacityBytes: this.capacityBytes,
      rejectedRecords: this.rejectedRecords,
      lastError: this.lastError
    };
  }

  private async initializeState(): Promise<void> {
    try {
      const response = await FTDBSpoolTaskPoolExecutor.init(this.paths);
      this.pendingRecords = response.pendingRecords;
      this.pendingBytes = response.pendingBytes;
      this.nextSequence = Math.max(this.nextSequence, response.pendingRecords);
    } catch (error) {
      this.recordError(`FileStore init failed: ${this.toErrorMessage(error)}`);
    }
  }

  private async readProjectionPage(path: string, byteOffset: number): Promise<FTFileDataStoreProjectionPage> {
    if (!path) {
      return { records: [], hasMore: false, nextByteOffset: byteOffset };
    }
    const response = await FTDBSpoolTaskPoolExecutor.readPage(this.paths, path, byteOffset, 256);
    const records: SyncDataJSON[] = [];
    for (let i = 0; i < response.records.length; i++) {
      records.push(response.records[i].data);
    }
    return {
      records,
      hasMore: response.hasMoreRecords,
      nextByteOffset: response.nextByteOffset
    };
  }

  private async awaitInitialized(): Promise<void> {
    if (this.initPromise !== null) {
      await this.initPromise;
    }
  }

  private joinPath(parent: string, child: string): string {
    return parent.endsWith('/') ? `${parent}${child}` : `${parent}/${child}`;
  }

  private toErrorMessage(error: object | string | number | boolean | null | undefined): string {
    return error instanceof Error ? error.message : String(error);
  }

  private recordError(message: string): void {
    this.lastError = message;
    FTInnerLogger.e(TAG, message);
  }
}
