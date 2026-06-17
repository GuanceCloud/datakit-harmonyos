import { Context } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import preferences from '@ohos.data.preferences';
import { Constants } from '../../Constants';
import { FTSDKConfig } from '../../Configs';
import { DataBaseCallBack } from '../../db/base/DataBaseCallBack';
import { SyncData } from '../../db/bean/SyncData';
import { FTDBCachePolicy } from '../../db/FTDBCachePolicy';
import { FTDBManager } from '../../db/FTDBManager';
import { DataType } from '../../enum/Enums';
import { HttpBuilder } from '../../http/HttpBuilder';
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

export interface SyncTaskDbManager {
  hasData(dataTypes: DataType[]): Promise<boolean>;
  updateDataType(dataType: string, errorTimeLine: number): Promise<number>;
  deleteExpireCache(dataType: string, now: number, duration: number): Promise<number>;
  init(): Promise<void>;
  queryFtOperation(dataTypes: DataType[], pageSize: number): Promise<SyncData[]>;
  deleteFtOperation(list: SyncData[]): Promise<void>;
  insertFtOptList(list: SyncData[]): Promise<boolean | void>;
  executeWithDB(isWrite: boolean, callback: DataBaseCallBack): Promise<void>;
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

export interface SyncTaskManagerRuntime {
  getDbManager(context: Context): SyncTaskDbManager | null;
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

export class DefaultSyncTaskManagerRuntime implements SyncTaskManagerRuntime {
  getDbManager(context: Context): SyncTaskDbManager | null {
    return FTDBManager.getInstance(context);
  }

  getCachePolicy(): SyncTaskCachePolicy {
    return FTDBCachePolicy.getInstance();
  }

  getPreferences(context: Context, name: string): SyncTaskPreferences {
    return preferences.getPreferencesSync(context, { name }) as SyncTaskPreferences;
  }

  async executeHttp(config: FTSDKConfig, model: string, body: string, pkgId: string): Promise<SyncTaskHttpResult> {
    const xPkgIdValue = Constants.SYNC_DATA_TRACE_HEADER_FORMAT.replace('%s', pkgId);
    return await HttpBuilder.Builder(config)
      .addHeadParam(Constants.SYNC_DATA_CONTENT_TYPE_HEADER, 'text/plain')
      .addHeadParam(Constants.SYNC_DATA_TRACE_HEADER, xPkgIdValue)
      .addHeadParam(Constants.SYNC_DATA_DEVICE_TIME, this.getCurrentTimeMs().toString())
      .setModel(model)
      .setMethod(http.RequestMethod.POST)
      .setBodyString(body)
      .executeSync();
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
