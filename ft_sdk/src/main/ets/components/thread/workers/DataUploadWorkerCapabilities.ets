import { DataType } from '../../enum/Enums';

/**
 * Serializable upload row used by DataUploadWorker.
 *
 * Keep this model free of SDK classes so the same executor can run through
 * the DATA_UPLOAD scheduler while DB I/O is delegated to DB TaskPool DTOs.
 */
export interface DataUploadRow {
  id: number;
  dataType: string;
  dataString: string;
  uuid: string;
  time: number;
  customDataType?: string;
}

export interface DataUploadHttpResult {
  code: number;
  message: string;
  errorCode: string;
  model?: string;
}

export interface DataUploadConsumeOptions {
  taskName: string;
  pageSize: number;
  syncSleepTime: number;
  errorTimeLine: number;
  stopped?: boolean;
}

export interface DataUploadConsumeResult {
  consumedRows: number;
  hasMoreData: boolean;
  errorCount: number;
  metrics?: DataUploadConsumeMetrics;
}

export interface DataUploadConsumeMetrics {
  totalMs: number;
  computeMs: number;
  dbMs: number;
  dbErrorSampledMs: number;
  dbHasDataMs: number;
  dbQueryMs: number;
  dbDeleteMs: number;
  dbInsertMs: number;
  dbWriteQueueWaitMs: number;
  httpMs: number;
  sleepMs: number;
  executeMs: number;
  unaccountedMs: number;
}

export interface DataUploadDbWriteResult {
  affectedRows: number;
  dbLaneWaitMs: number;
}

export interface DataUploadDbMaintenanceResult {
  updatedRows: number;
  deletedRows: number;
  dbLaneWaitMs: number;
}

export enum DataUploadDbCommitAction {
  DELETE = 'delete',
  REINSERT = 'reinsert'
}

/**
 * Worker-safe capability boundary for the real upload consumer.
 *
 * Implementations must not expose Context, RdbStore, FTSDKConfig, SyncData,
 * callbacks, or other non-serializable SDK objects to the executor.
 */
export interface DataUploadWorkerCapabilities {
  isStopped(): boolean;
  hasData(dataType: DataType): Promise<boolean>;
  queryRows(dataType: DataType, pageSize: number): Promise<DataUploadRow[]>;
  commitUpload(
    dataType: DataType,
    action: DataUploadDbCommitAction,
    rows: DataUploadRow[],
    reInsertRows: DataUploadRow[],
    reduceCount: number
  ): Promise<DataUploadDbWriteResult>;
  maintainErrorSampled(
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<DataUploadDbMaintenanceResult>;
  executeHttp(dataType: DataType, pkgId: string, body: string): Promise<DataUploadHttpResult>;
  shouldDiscardData(dataType: DataType): Promise<boolean>;
  getCurrentTimeMs(): number;
  getRandom(): number;
  generateUUID(): string;
  sleep(ms: number): Promise<void>;
}
