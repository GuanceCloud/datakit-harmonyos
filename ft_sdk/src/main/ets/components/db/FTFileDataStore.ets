import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../Configs';
import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { SyncDataJSON } from './bean/SyncData';
import { FTDBSpoolPaths, FTDBSpoolTaskPoolExecutor } from './FTDBSpoolTaskPoolExecutor';

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
