import { ThreadWorkerGlobalScope } from '@ohos.worker';
import { DataType } from '../../enum/Enums';
import {
  SDKWorkerBridgeRequest,
  SDKWorkerBridgeResponse,
  SDKWorkerPayload
} from '../SDKWorkerProtocol';
import {
  DataUploadBridgeCountPayload,
  DataUploadBridgeDataTypePayload,
  DataUploadBridgeDbWritePayload,
  DataUploadBridgeDeleteAndReducePayload,
  DataUploadBridgeDeleteExpireCachePayload,
  DataUploadBridgeHttpPayload,
  DataUploadBridgeInsertRowsPayload,
  DataUploadBridgeQueryRowsPayload,
  DataUploadBridgeReduceCachePayload,
  DataUploadBridgeRowIdsPayload,
  DataUploadBridgeRowsPayload,
  DataUploadBridgeUpdateDataTypePayload,
  DataUploadBridgeValuePayload,
  DataUploadDbWriteResult,
  DataUploadHttpResult,
  DataUploadRow,
  DataUploadWorkerBridgeCommand,
  DataUploadWorkerRuntime
} from './DataUploadWorkerRuntime';

type BridgePayloadRecord = Record<string, object | string | number | boolean | null | undefined>;

interface PendingBridgeRequest {
  id: string;
  sourceRequestId: string;
  resolve: (payload: SDKWorkerPayload | undefined) => void;
  reject: (error: Error) => void;
}

/**
 * ThreadWorker-side runtime for DataUploadWorkerExecutor.
 *
 * It intentionally allows only one in-flight bridge request. The executor is
 * sequential today, but keeping this guard here prevents accidental parallel
 * bridge pressure if future code changes.
 */
export class DataUploadWorkerBridgeRuntime implements DataUploadWorkerRuntime {
  private readonly workerPort: ThreadWorkerGlobalScope;
  private sourceRequestId: string = '';
  private bridgeSequence: number = 0;
  private pending: PendingBridgeRequest | null = null;
  private stopped: boolean = false;

  constructor(workerPort: ThreadWorkerGlobalScope) {
    this.workerPort = workerPort;
  }

  public beginRequest(sourceRequestId: string, stopped: boolean): void {
    this.sourceRequestId = sourceRequestId;
    this.stopped = stopped;
    this.bridgeSequence = 0;
  }

  public endRequest(sourceRequestId: string): void {
    if (this.sourceRequestId !== sourceRequestId) {
      return;
    }
    if (this.pending) {
      this.pending.reject(new Error('DataUploadWorker bridge request was interrupted'));
      this.pending = null;
    }
    this.sourceRequestId = '';
    this.stopped = false;
  }

  public handleBridgeResponse(message: object | string | number | boolean | null | undefined): boolean {
    if (!this.isBridgeResponse(message)) {
      return false;
    }
    const response = message as Object as SDKWorkerBridgeResponse;
    const pending = this.pending;
    if (!pending || response.id !== pending.id || response.sourceRequestId !== pending.sourceRequestId) {
      return true;
    }

    this.pending = null;
    if (response.ok) {
      pending.resolve(response.payload);
    } else {
      pending.reject(new Error(response.errorMessage || 'DataUploadWorker bridge request failed'));
    }
    return true;
  }

  isStopped(): boolean {
    return this.stopped;
  }

  async hasData(dataType: DataType): Promise<boolean> {
    const requestPayload: DataUploadBridgeDataTypePayload = {
      dataType: dataType.toString()
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.HAS_DATA,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readBooleanValue(payload);
  }

  async queryRows(dataType: DataType, pageSize: number): Promise<DataUploadRow[]> {
    const requestPayload: DataUploadBridgeQueryRowsPayload = {
      dataType: dataType.toString(),
      pageSize: Math.max(1, Math.floor(pageSize))
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.QUERY_ROWS,
      requestPayload as Object as SDKWorkerPayload
    );
    const record = this.toRecord(payload);
    const rowsValue = record['rows'];
    if (!Array.isArray(rowsValue)) {
      return [];
    }
    return rowsValue as Object as DataUploadRow[];
  }

  async deleteRows(rows: DataUploadRow[]): Promise<DataUploadDbWriteResult> {
    const rowIds = this.toRowIds(rows);
    if (rowIds.length !== rows.length) {
      const fallbackPayload: DataUploadBridgeRowsPayload = {
        rows: this.toDeleteRows(rows)
      };
      const fallbackResponse = await this.sendBridgeRequest(
        DataUploadWorkerBridgeCommand.DELETE_ROWS,
        fallbackPayload as Object as SDKWorkerPayload
      );
      return this.readDbWriteResult(fallbackResponse);
    }

    const requestPayload: DataUploadBridgeRowIdsPayload = {
      ids: rowIds
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.DELETE_ROW_IDS,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readDbWriteResult(payload);
  }

  async deleteRowIdsAndReduceCache(
    dataType: DataType,
    rowIds: number[],
    count: number
  ): Promise<DataUploadDbWriteResult> {
    const requestPayload: DataUploadBridgeDeleteAndReducePayload = {
      dataType: dataType.toString(),
      ids: rowIds,
      count
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.DELETE_ROW_IDS_AND_REDUCE_CACHE,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readDbWriteResult(payload);
  }

  async insertRows(rows: DataUploadRow[], reInsert: boolean): Promise<DataUploadDbWriteResult> {
    const requestPayload: DataUploadBridgeInsertRowsPayload = {
      rows,
      reInsert
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.INSERT_ROWS,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readDbWriteResult(payload);
  }

  async updateDataType(dataType: string, errorTimeLine: number): Promise<number> {
    const requestPayload: DataUploadBridgeUpdateDataTypePayload = {
      dataType,
      errorTimeLine
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.UPDATE_DATA_TYPE,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readCount(payload);
  }

  async deleteExpireCache(dataType: string, now: number, duration: number): Promise<number> {
    const requestPayload: DataUploadBridgeDeleteExpireCachePayload = {
      dataType,
      now,
      duration
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.DELETE_EXPIRE_CACHE,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readCount(payload);
  }

  async executeHttp(dataType: DataType, pkgId: string, body: string): Promise<DataUploadHttpResult> {
    const requestPayload: DataUploadBridgeHttpPayload = {
      dataType: dataType.toString(),
      pkgId,
      body
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.EXECUTE_HTTP,
      requestPayload as Object as SDKWorkerPayload
    );
    const record = this.toRecord(payload);
    return {
      code: typeof record['code'] === 'number' ? record['code'] as number : -1,
      message: typeof record['message'] === 'string' ? record['message'] as string : '',
      errorCode: typeof record['errorCode'] === 'string' ? record['errorCode'] as string : ''
    };
  }

  async shouldDiscardData(dataType: DataType): Promise<boolean> {
    const requestPayload: DataUploadBridgeDataTypePayload = {
      dataType: dataType.toString()
    };
    const payload = await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.SHOULD_DISCARD_DATA,
      requestPayload as Object as SDKWorkerPayload
    );
    return this.readBooleanValue(payload);
  }

  async reduceCacheCount(dataType: DataType, count: number): Promise<void> {
    const requestPayload: DataUploadBridgeReduceCachePayload = {
      dataType: dataType.toString(),
      count
    };
    await this.sendBridgeRequest(
      DataUploadWorkerBridgeCommand.REDUCE_CACHE_COUNT,
      requestPayload as Object as SDKWorkerPayload
    );
  }

  getCurrentTimeMs(): number {
    return Date.now();
  }

  getRandom(): number {
    return Math.random();
  }

  generateUUID(): string {
    const hex = "0123456789abcdef";
    let uuid = "";
    for (let i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        uuid += "-";
      } else if (i === 14) {
        uuid += "4";
      } else if (i === 19) {
        uuid += hex.charAt((Math.floor(this.getRandom() * 16) & 0x3) | 0x8);
      } else {
        uuid += hex.charAt(Math.floor(this.getRandom() * 16));
      }
    }
    return uuid;
  }

  async sleep(ms: number): Promise<void> {
    const delay = Math.max(0, ms);
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), delay);
    });
  }

  private sendBridgeRequest(
    command: DataUploadWorkerBridgeCommand,
    payload?: SDKWorkerPayload
  ): Promise<SDKWorkerPayload | undefined> {
    if (!this.sourceRequestId || this.sourceRequestId.length === 0) {
      return Promise.reject(new Error('DataUploadWorker bridge request has no source request'));
    }
    if (this.pending) {
      return Promise.reject(new Error('DataUploadWorker bridge already has a pending request'));
    }

    this.bridgeSequence++;
    const request: SDKWorkerBridgeRequest = {
      id: `${this.sourceRequestId}:bridge:${this.bridgeSequence}`,
      sourceRequestId: this.sourceRequestId,
      command,
      payload
    };

    return new Promise<SDKWorkerPayload | undefined>((resolve, reject) => {
      this.pending = {
        id: request.id,
        sourceRequestId: request.sourceRequestId,
        resolve,
        reject
      };
      try {
        this.workerPort.postMessage(request);
      } catch (error) {
        this.pending = null;
        const normalized = error instanceof Error ? error : new Error(String(error));
        reject(normalized);
      }
    });
  }

  private toRowIds(rows: DataUploadRow[]): number[] {
    const rowIds: number[] = [];
    const seenIds: Set<number> = new Set();
    for (const row of rows) {
      const id = Math.floor(row.id);
      if (id <= 0 || seenIds.has(id)) {
        continue;
      }
      seenIds.add(id);
      rowIds.push(id);
    }
    return rowIds;
  }

  private toDeleteRows(rows: DataUploadRow[]): DataUploadRow[] {
    const deleteRows: DataUploadRow[] = [];
    for (const row of rows) {
      const deleteRow: DataUploadRow = {
        id: row.id,
        dataType: row.dataType,
        dataString: "",
        uuid: row.uuid,
        time: row.time
      };
      if (row.customDataType && row.customDataType.length > 0) {
        deleteRow.customDataType = row.customDataType;
      }
      deleteRows.push(deleteRow);
    }
    return deleteRows;
  }

  private readBooleanValue(payload: SDKWorkerPayload | undefined): boolean {
    const valuePayload = this.toRecord(payload) as Object as DataUploadBridgeValuePayload;
    return valuePayload.value === true;
  }

  private readCount(payload: SDKWorkerPayload | undefined): number {
    const countPayload = this.toRecord(payload) as Object as DataUploadBridgeCountPayload;
    return typeof countPayload.count === 'number' ? countPayload.count : 0;
  }

  private readDbWriteResult(payload: SDKWorkerPayload | undefined): DataUploadDbWriteResult {
    const resultPayload = this.toRecord(payload) as Object as DataUploadBridgeDbWritePayload;
    return {
      affectedRows: typeof resultPayload.affectedRows === 'number' ? resultPayload.affectedRows : 0,
      dbLaneWaitMs: typeof resultPayload.dbLaneWaitMs === 'number' ? resultPayload.dbLaneWaitMs : 0
    };
  }

  private toRecord(payload: SDKWorkerPayload | undefined): BridgePayloadRecord {
    if (payload && typeof payload === 'object') {
      return payload as Object as BridgePayloadRecord;
    }
    return new Object() as BridgePayloadRecord;
  }

  private isBridgeResponse(message: object | string | number | boolean | null | undefined): boolean {
    if (!message || typeof message !== 'object') {
      return false;
    }
    const record = message as Object as BridgePayloadRecord;
    return typeof record['id'] === 'string' &&
      typeof record['sourceRequestId'] === 'string' &&
      typeof record['ok'] === 'boolean';
  }
}
