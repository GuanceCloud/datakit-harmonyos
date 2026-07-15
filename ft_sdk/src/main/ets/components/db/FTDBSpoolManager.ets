import { Context } from '@kit.AbilityKit';
import { FTInnerLogger } from '../log/FTLogger';
import { FTDBManager, SyncDataWriteFailureFallback } from './FTDBManager';
import {
  FTDBSpoolPaths,
  FTDBSpoolRecordDTO,
  FTDBSpoolTaskPoolExecutor
} from './FTDBSpoolTaskPoolExecutor';
import {
  FT_DB_SPOOL_MAX_BYTES,
  FT_DB_SPOOL_REPLAY_PAGE_RECORDS
} from './FTDBSpoolLimits';
import { SyncData, SyncDataJSON } from './bean/SyncData';

export interface FTDBSpoolStatus {
  initialized: boolean;
  spoolPath: string;
  activePath: string;
  inflightPath: string;
  pendingRecords: number;
  pendingBytes: number;
  capacityBytes: number;
  rejectedRecords: number;
  lastError: string;
}

const TAG = 'FTDBSpoolManager';

/**
 * Durable fallback for sync rows that could not be committed to the DB.
 *
 * New failures are appended to active. Replay atomically promotes active (or
 * the legacy file) to inflight. The inflight file remains immutable until an
 * idempotent DB upsert succeeds and the matching batch token is acknowledged.
 * All file access and NDJSON parsing run on the Spool TaskPool lane.
 */
export class FTDBSpoolManager implements SyncDataWriteFailureFallback {
  private static instance: FTDBSpoolManager | null = null;
  private static readonly SPOOL_DIR_NAME = 'ft_sdk_spool';
  private static readonly ACTIVE_FILE_NAME = 'sync_data_spool.active.ndjson';
  private static readonly INFLIGHT_FILE_NAME = 'sync_data_spool.inflight.ndjson';
  private static readonly LEGACY_FILE_NAME = 'sync_data_spool.ndjson';
  private static readonly MAX_REPLAY_BATCHES_PER_CALL = 3;

  private initialized: boolean = false;
  private paths: FTDBSpoolPaths = {
    spoolDir: '',
    activePath: '',
    inflightPath: '',
    legacyPath: ''
  };
  private initPromise: Promise<void> | null = null;
  private replayTail: Promise<void> = Promise.resolve();
  private nextSeq: number = 0;
  private pendingRecords: number = 0;
  private pendingBytes: number = 0;
  private rejectedRecords: number = 0;
  private lastError: string = '';

  private constructor() {
  }

  public static getInstance(): FTDBSpoolManager {
    if (FTDBSpoolManager.instance === null) {
      FTDBSpoolManager.instance = new FTDBSpoolManager();
    }
    return FTDBSpoolManager.instance;
  }

  public init(context: Context): void {
    const spoolDir = this.joinPath(context.filesDir, FTDBSpoolManager.SPOOL_DIR_NAME);
    FTDBManager.getInstance(context).setSyncDataWriteFailureFallback(this);
    if (this.initialized && this.paths.spoolDir === spoolDir) {
      return;
    }
    this.paths = {
      spoolDir,
      activePath: this.joinPath(spoolDir, FTDBSpoolManager.ACTIVE_FILE_NAME),
      inflightPath: this.joinPath(spoolDir, FTDBSpoolManager.INFLIGHT_FILE_NAME),
      legacyPath: this.joinPath(spoolDir, FTDBSpoolManager.LEGACY_FILE_NAME)
    };
    this.initialized = true;
    this.lastError = '';
    this.initPromise = this.initializeTaskPoolState();
  }

  public async appendSyncData(source: string, dataList: SyncData[]): Promise<number> {
    const rows: SyncDataJSON[] = [];
    if (dataList) {
      for (let i = 0; i < dataList.length; i++) {
        const data = dataList[i];
        if (data && data.isValid()) {
          rows.push(data.toJSON());
        }
      }
    }
    return await this.appendSyncDataJSON(source, rows);
  }

  public async appendSyncDataJSON(source: string, records: SyncDataJSON[]): Promise<number> {
    if (!this.initialized || this.paths.activePath.length === 0 || !records || records.length === 0) {
      return 0;
    }
    await this.awaitInitialized();
    const seqStart = this.nextSeq;
    this.nextSeq += records.length;
    try {
      const response = await FTDBSpoolTaskPoolExecutor.append(
        this.paths,
        source,
        seqStart,
        records,
        FT_DB_SPOOL_MAX_BYTES
      );
      if (response.pendingRecordsKnown) {
        this.pendingRecords = response.pendingRecords;
      } else {
        this.pendingRecords += response.appendedRecords;
      }
      this.pendingBytes = response.pendingBytes;
      this.rejectedRecords += response.rejectedRecords;
      if (response.appendedRecords > 0) {
        FTInnerLogger.w(TAG,
          `Spooled ${response.appendedRecords} sync record(s) from ${source}; pending=${this.pendingRecords}, ` +
            `bytes=${this.pendingBytes}/${FT_DB_SPOOL_MAX_BYTES}`);
      }
      if (response.rejectedRecords > 0) {
        this.recordError(
          `Spool capacity rejected ${response.rejectedRecords} record(s) from ${source}; ` +
            `bytes=${this.pendingBytes}/${FT_DB_SPOOL_MAX_BYTES}`
        );
      }
      return response.appendedRecords;
    } catch (error) {
      this.recordError(`spool.append failed: ${this.toErrorMessage(error)}`);
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  public async replay(context: Context, reason: string = 'manual'): Promise<number> {
    if (!this.initialized) {
      this.init(context);
    }
    return await this.enqueueReplayOperation(async () => await this.replayLocked(context, reason));
  }

  public async clear(): Promise<void> {
    if (!this.initialized || this.paths.spoolDir.length === 0) {
      return;
    }
    await this.enqueueReplayOperation(async () => {
      await this.awaitInitialized();
      try {
        const response = await FTDBSpoolTaskPoolExecutor.clear(this.paths);
        this.pendingRecords = response.pendingRecords;
        this.pendingBytes = response.pendingBytes;
        this.nextSeq = 0;
        this.rejectedRecords = 0;
        this.lastError = '';
      } catch (error) {
        this.recordError(`spool.clear failed: ${this.toErrorMessage(error)}`);
        throw error instanceof Error ? error : new Error(String(error));
      }
    });
  }

  public getStatus(): FTDBSpoolStatus {
    return {
      initialized: this.initialized,
      spoolPath: this.paths.activePath,
      activePath: this.paths.activePath,
      inflightPath: this.paths.inflightPath,
      pendingRecords: this.pendingRecords,
      pendingBytes: this.pendingBytes,
      capacityBytes: FT_DB_SPOOL_MAX_BYTES,
      rejectedRecords: this.rejectedRecords,
      lastError: this.lastError
    };
  }

  private async initializeTaskPoolState(): Promise<void> {
    try {
      const response = await FTDBSpoolTaskPoolExecutor.init(this.paths);
      this.pendingRecords = response.pendingRecords;
      this.pendingBytes = response.pendingBytes;
      this.nextSeq = Math.max(this.nextSeq, response.pendingRecords);
    } catch (error) {
      this.recordError(`spool.init failed: ${this.toErrorMessage(error)}`);
    }
  }

  private async awaitInitialized(): Promise<void> {
    if (this.initPromise) {
      await this.initPromise;
    }
  }

  private async enqueueReplayOperation<T>(operation: () => Promise<T>): Promise<T> {
    const previousTail = this.replayTail.catch(() => {});
    let releaseCurrent: () => void = () => {};
    const currentTail = new Promise<void>((resolve: () => void) => {
      releaseCurrent = resolve;
    });
    this.replayTail = previousTail.then(() => currentTail);
    await previousTail;
    try {
      return await operation();
    } finally {
      releaseCurrent();
    }
  }

  private async replayLocked(context: Context, reason: string): Promise<number> {
    await this.awaitInitialized();
    let replayedRecords = 0;
    for (let batchIndex = 0; batchIndex < FTDBSpoolManager.MAX_REPLAY_BATCHES_PER_CALL; batchIndex++) {
      let byteOffset = 0;
      let batchToken = '';
      let batchFinished = false;
      while (!batchFinished) {
        const prepared = await FTDBSpoolTaskPoolExecutor.prepareReplay(
          this.paths,
          byteOffset,
          FT_DB_SPOOL_REPLAY_PAGE_RECORDS
        );
        if (prepared.pendingRecordsKnown) {
          this.pendingRecords = prepared.pendingRecords;
        }
        this.pendingBytes = prepared.pendingBytes;
        if (!prepared.batchToken) {
          return replayedRecords;
        }
        if (batchToken.length > 0 && batchToken !== prepared.batchToken) {
          this.recordError(`spool inflight changed during replay: expected=${batchToken}, actual=${prepared.batchToken}`);
          return replayedRecords;
        }
        batchToken = prepared.batchToken;
        if (prepared.skippedRecords > 0) {
          this.recordError(`spool replay skipped ${prepared.skippedRecords} corrupt record(s)`);
        }

        const rows = this.toSyncDataList(prepared.records);
        if (rows.length > 0) {
          const result = await FTDBManager.getInstance(context).writeSyncDataAtomically(
            `spool.replay:${reason}`,
            rows,
            {
              applyCachePolicy: true,
              reInsert: false,
              forceTransaction: true,
              updateOrInsertByUuid: true,
              skipFailureFallback: true
            }
          );
          if (!result.success) {
            this.recordError(`spool replay DB write failed: ${result.errorMessage}`);
            return replayedRecords;
          }
          replayedRecords += rows.length;
          FTInnerLogger.i(TAG,
            `Replayed Spool page rows=${rows.length}, inserted=${result.inserted}, updated=${result.updated}, ` +
              `dropped=${result.dropped}, byteRange=${byteOffset}-${prepared.nextByteOffset}`);
        }

        if (prepared.hasMoreRecords) {
          if (prepared.nextByteOffset <= byteOffset) {
            this.recordError(`spool replay byte cursor did not advance: offset=${byteOffset}`);
            return replayedRecords;
          }
          byteOffset = prepared.nextByteOffset;
          continue;
        }

        const acknowledged = await FTDBSpoolTaskPoolExecutor.ackReplay(this.paths, batchToken);
        this.pendingRecords = acknowledged.pendingRecords;
        this.pendingBytes = acknowledged.pendingBytes;
        batchFinished = true;
      }
    }
    return replayedRecords;
  }

  private toSyncDataList(records: FTDBSpoolRecordDTO[]): SyncData[] {
    const rows: SyncData[] = [];
    for (let i = 0; i < records.length; i++) {
      const row = SyncData.fromJSON(records[i].data);
      if (row.isValid()) {
        rows.push(row);
      }
    }
    return rows;
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
