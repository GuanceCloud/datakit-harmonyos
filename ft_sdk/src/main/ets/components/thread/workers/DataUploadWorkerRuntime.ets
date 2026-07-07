import { DataType } from '../../enum/Enums';

export const DATA_UPLOAD_WORKER_MAX_BATCH_LIMIT = 50;

/**
 * Serializable upload row used by DataUploadWorker.
 *
 * Keep this model free of SDK classes so the same executor can run in an
 * inline pool today and behind a ThreadWorker bridge later.
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
}

export enum DataUploadWorkerBridgeCommand {
  HAS_DATA = 'upload.bridge.hasData',
  QUERY_ROWS = 'upload.bridge.queryRows',
  DELETE_ROWS = 'upload.bridge.deleteRows',
  INSERT_ROWS = 'upload.bridge.insertRows',
  UPDATE_DATA_TYPE = 'upload.bridge.updateDataType',
  DELETE_EXPIRE_CACHE = 'upload.bridge.deleteExpireCache',
  EXECUTE_HTTP = 'upload.bridge.executeHttp',
  SHOULD_DISCARD_DATA = 'upload.bridge.shouldDiscardData',
  REDUCE_CACHE_COUNT = 'upload.bridge.reduceCacheCount'
}

export interface DataUploadBridgeDataTypePayload {
  dataType: string;
}

export interface DataUploadBridgeQueryRowsPayload {
  dataType: string;
  pageSize: number;
}

export interface DataUploadBridgeRowsPayload {
  rows: DataUploadRow[];
}

export interface DataUploadBridgeInsertRowsPayload {
  rows: DataUploadRow[];
  reInsert: boolean;
}

export interface DataUploadBridgeUpdateDataTypePayload {
  dataType: string;
  errorTimeLine: number;
}

export interface DataUploadBridgeDeleteExpireCachePayload {
  dataType: string;
  now: number;
  duration: number;
}

export interface DataUploadBridgeHttpPayload {
  dataType: string;
  pkgId: string;
  body: string;
}

export interface DataUploadBridgeReduceCachePayload {
  dataType: string;
  count: number;
}

export interface DataUploadBridgeValuePayload {
  value: boolean;
}

export interface DataUploadBridgeCountPayload {
  count: number;
}

/**
 * Worker-safe runtime boundary for the real upload consumer.
 *
 * Implementations must not expose Context, RdbStore, FTSDKConfig, SyncData,
 * callbacks, or other non-serializable SDK objects to the executor.
 */
export interface DataUploadWorkerRuntime {
  isStopped(): boolean;
  hasData(dataType: DataType): Promise<boolean>;
  queryRows(dataType: DataType, pageSize: number): Promise<DataUploadRow[]>;
  deleteRows(rows: DataUploadRow[]): Promise<void>;
  insertRows(rows: DataUploadRow[], reInsert: boolean): Promise<void>;
  updateDataType(dataType: string, errorTimeLine: number): Promise<number>;
  deleteExpireCache(dataType: string, now: number, duration: number): Promise<number>;
  executeHttp(dataType: DataType, pkgId: string, body: string): Promise<DataUploadHttpResult>;
  shouldDiscardData(dataType: DataType): Promise<boolean>;
  reduceCacheCount(dataType: DataType, count: number): Promise<void>;
  getCurrentTimeMs(): number;
  getRandom(): number;
  generateUUID(): string;
  sleep(ms: number): Promise<void>;
}
