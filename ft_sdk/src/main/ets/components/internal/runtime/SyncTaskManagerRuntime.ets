import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { FTSDKConfig } from '../../Configs';
import { SyncData } from '../../db/bean/SyncData';
import { FTDBCachePolicy } from '../../db/FTDBCachePolicy';
import {
  FTDBTaskPoolExecutor,
  FTDBTaskPoolMaintenanceResponse,
  FTDBTaskPoolUploadCommitResponse
} from '../../db/FTDBTaskPoolExecutor';
import { DataType } from '../../enum/Enums';
import { FTUploadTaskPoolExecutor } from '../../http/FTUploadTaskPoolExecutor';
import { Utils } from '../../utils/Utils';

export interface SyncTaskConfigRecord {
  isLimitWithDbSize: () => boolean;
  getDbCacheLimit: () => number;
  getDBCacheDiscard: () => string;
  getLogCacheDiscard: () => string;
}

export interface SyncTaskPreferences {
  put(key: string, value: number): Promise<void>;
  flush(): Promise<void>;
  get(key: string, defaultValue: number): Promise<number | string | boolean>;
}

export interface SyncTaskDbTaskPool {
  hasSyncData(context: Context, dataTypes: string[]): Promise<boolean>;
  querySyncData(context: Context, dataTypes: string[], limit: number, newestFirst?: boolean): Promise<SyncData[]>;
  deleteSyncRows(context: Context, rows: SyncData[]): Promise<number>;
  uploadCommit(
    context: Context,
    dataType: string,
    action: string,
    records: SyncData[],
    reInsertRecords: SyncData[],
    reduceCount: number
  ): Promise<FTDBTaskPoolUploadCommitResponse>;
  maintainErrorSampled(
    context: Context,
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<FTDBTaskPoolMaintenanceResponse>;
  cleanupExpiredRumView(context: Context, cutoffTime: number): Promise<number>;
  cleanupExpiredRumAction(context: Context, cutoffTime: number): Promise<number>;
}

export interface SyncTaskCachePolicy {
  initSDKParams(configRecord: SyncTaskConfigRecord): void;
  shouldDiscardData(dataType: DataType): boolean;
  optLogCount(delta: number): void;
  optRumCount(delta: number): void;
  getLogLimitCount(): number;
  getRumLimitCount(): number;
  getLogCount(): number;
  getRumCount(): number;
}

export interface SyncTaskHttpResult {
  getCode(): number;
  getMessage(): string;
  getErrorCode(): string;
}

class TaskPoolSyncTaskHttpResult implements SyncTaskHttpResult {
  private readonly code: number;
  private readonly message: string;
  private readonly errorCode: string;

  constructor(code: number, message: string, errorCode: string) {
    this.code = code;
    this.message = message;
    this.errorCode = errorCode;
  }

  getCode(): number {
    return this.code;
  }

  getMessage(): string {
    return this.message;
  }

  getErrorCode(): string {
    return this.errorCode;
  }
}

export interface SyncTaskManagerRuntime {
  getDbTaskPool(): SyncTaskDbTaskPool;
  getCachePolicy(): SyncTaskCachePolicy;
  getPreferences(context: Context, name: string): SyncTaskPreferences;
  executeHttp(config: FTSDKConfig, model: string, body: string, pkgId: string): Promise<SyncTaskHttpResult>;
  getCurrentTimeMs(): number;
  getRandom(): number;
  generateUUID(): string;
  setTimer(callback: () => void, interval: number): number;
  clearTimer(timerId: number): void;
  sleep(ms: number): Promise<void>;
}

class DefaultSyncTaskDbTaskPool implements SyncTaskDbTaskPool {
  async hasSyncData(context: Context, dataTypes: string[]): Promise<boolean> {
    return await FTDBTaskPoolExecutor.hasSyncData(context, dataTypes);
  }

  async querySyncData(
    context: Context,
    dataTypes: string[],
    limit: number,
    newestFirst?: boolean
  ): Promise<SyncData[]> {
    return await FTDBTaskPoolExecutor.querySyncData(context, dataTypes, limit, newestFirst === true);
  }

  async deleteSyncRows(context: Context, rows: SyncData[]): Promise<number> {
    return await FTDBTaskPoolExecutor.deleteSyncRows(context, rows);
  }

  async uploadCommit(
    context: Context,
    dataType: string,
    action: string,
    records: SyncData[],
    reInsertRecords: SyncData[],
    reduceCount: number
  ): Promise<FTDBTaskPoolUploadCommitResponse> {
    return await FTDBTaskPoolExecutor.uploadCommit(context, dataType, action, records, reInsertRecords, reduceCount);
  }

  async maintainErrorSampled(
    context: Context,
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<FTDBTaskPoolMaintenanceResponse> {
    return await FTDBTaskPoolExecutor.maintainErrorSampled(context, dataType, errorTimeLine, now, duration);
  }

  async cleanupExpiredRumView(context: Context, cutoffTime: number): Promise<number> {
    return await FTDBTaskPoolExecutor.cleanupExpiredRumView(context, cutoffTime);
  }

  async cleanupExpiredRumAction(context: Context, cutoffTime: number): Promise<number> {
    return await FTDBTaskPoolExecutor.cleanupExpiredRumAction(context, cutoffTime);
  }
}

export class DefaultSyncTaskManagerRuntime implements SyncTaskManagerRuntime {
  private readonly dbTaskPool = new DefaultSyncTaskDbTaskPool();

  getDbTaskPool(): SyncTaskDbTaskPool {
    return this.dbTaskPool;
  }

  getCachePolicy(): SyncTaskCachePolicy {
    return FTDBCachePolicy.getInstance();
  }

  getPreferences(context: Context, name: string): SyncTaskPreferences {
    return preferences.getPreferencesSync(context, { name }) as SyncTaskPreferences;
  }

  async executeHttp(config: FTSDKConfig, model: string, body: string, pkgId: string): Promise<SyncTaskHttpResult> {
    const response = await FTUploadTaskPoolExecutor.execute({
      config: {
        datakitUrl: config.getDatakitUrl(),
        datawayUrl: config.getDatawayUrl(),
        clientToken: config.getClientToken()
      },
      model,
      body,
      pkgId,
      deviceTimeMs: this.getCurrentTimeMs()
    });
    return new TaskPoolSyncTaskHttpResult(response.code, response.message, response.errorCode);
  }

  getCurrentTimeMs(): number {
    return Date.now();
  }

  getRandom(): number {
    return Math.random();
  }

  generateUUID(): string {
    return Utils.generateUUID();
  }

  setTimer(callback: () => void, interval: number): number {
    return setInterval(callback, interval);
  }

  clearTimer(timerId: number): void {
    clearInterval(timerId);
  }

  sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
