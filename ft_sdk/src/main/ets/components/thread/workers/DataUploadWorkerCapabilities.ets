import { DataType } from '../../enum/Enums';
import {
  SDKUploadHttpConfigDTO,
  SDKUploadHttpResultDTO,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../SDKWorkerProtocol';

/**
 * Serializable upload row exchanged with DataUploadWorker.
 *
 * Keep this model free of SDK classes so CPU work can cross the DATA_UPLOAD
 * worker boundary while DB I/O remains delegated to DB TaskPool DTOs.
 */
export interface DataUploadRow {
  id: number;
  dataType: string;
  dataString: string;
  uuid: string;
  time: number;
  customDataType?: string;
}

export interface DataUploadQueryPage {
  rows: DataUploadRow[];
  hasMore: boolean;
  transportBytes: number;
  byteLimitReached: boolean;
}

export interface DataUploadConsumeOptions {
  taskName: string;
  pageSize: number;
  maxRetryCount: number;
  syncSleepTime: number;
  errorTimeLine: number;
  stopped?: boolean;
}

export interface DataUploadConsumeResult {
  consumedRows: number;
  hasMoreData: boolean;
  /** True only when a transient HTTP or DB failure requires another attempt. */
  retryableFailure: boolean;
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
 * Host orchestration boundary for the upload consumer.
 *
 * DB methods stay TaskPool-backed. HTTPS configuration crosses into the
 * DataUploadWorker only as serializable strings and timeout values.
 */
export interface DataUploadWorkerCapabilities {
  executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse>;
  isStopped(): boolean;
  hasData(dataType: DataType): Promise<boolean>;
  queryRows(dataType: DataType, pageSize: number): Promise<DataUploadQueryPage>;
  /**
   * Remote rules are evaluated by the Host before a cached page crosses into
   * the upload worker. Local rules intentionally do not participate here:
   * they only control newly produced data before it is cached.
   */
  getRemoteDataFilters?(): Map<string, Array<string>>;
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
  getHttpConfig(dataType: DataType): SDKUploadHttpConfigDTO;
  takeInjectedHttpResult?(): SDKUploadHttpResultDTO | undefined;
  getCurrentTimeMs(): number;
  getRandom(): number;
  generateUUID(): string;
  sleep(ms: number): Promise<void>;
}
