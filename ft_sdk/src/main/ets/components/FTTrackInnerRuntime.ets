import { Context } from '@kit.AbilityKit';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig } from './Configs';
import { DataType } from './enum/Enums';
import { CollectType } from './rum/enum/RUMEnums';
import { SyncDataHelper } from './SyncDataHelper';
import { SyncTaskManager } from './SyncTaskManager';
import { TrackLogManager, QueueStatus } from './log/TrackLogManager';
import { LogBean } from './bean/LogBean';
import { SyncData } from './db/bean/SyncData';
import { FTDBCachePolicy } from './db/FTDBCachePolicy';
import { FTDBManager } from './db/FTDBManager';
import { DataProcessThreadPool } from './thread/DataProcessThreadPool';
import { FTHiLogInterceptor } from './log/FTHiLogInterceptor';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import { Utils } from './utils/Utils';

export interface FTTrackDataHelper {
  initBaseConfig(config: FTSDKConfig): void;
  initLogConfig(config: FTLoggerConfig): void;
  initRUMConfig(config: FTRUMConfig): void;
  appendGlobalContext(globalContext: Map<string, string>): void;
  appendGlobalContextByKeyValue(key: string, value: string): void;
  appendRUMGlobalContext(globalContext: Map<string, string>): void;
  appendRUMGlobalContextByKeyValue(key: string, value: string): void;
  appendLogGlobalContext(globalContext: Map<string, string>): void;
  appendLogGlobalContextByKeyValue(key: string, value: string): void;
  checkSessionWillCollect(sessionId: string): boolean;
  getBodyContent(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    dataType: DataType,
    uuid: string
  ): string;
}

export interface FTTrackSyncTaskManager {
  init(config: FTSDKConfig, context?: Context): void;
  executeSyncPoll(): void;
  stop(): void;
}

export interface FTTrackLogManager {
  setLogConfig(config: FTLoggerConfig): void;
  trackLog(logBean: LogBean, isSilence?: boolean): void;
  trackLogBatch(logBeans: LogBean[], isSilence?: boolean): void;
  forceFlush(isSilence?: boolean): void;
  getQueueStatus(): QueueStatus;
  shutdown(): void;
}

export interface FTTrackRumManager {
  checkSessionWillCollect(sessionId: string): CollectType;
}

export interface FTTrackCachePolicy {
  optRUMCachePolicy(context: Context, limit: number): Promise<number>;
  optLogCachePolicy(context: Context, limit: number): Promise<number>;
  optRumCount(delta: number): void;
  optLogCount(delta: number): void;
}

export interface FTTrackDbManager {
  init(): Promise<void>;
  insertFtOperation(data: SyncData, reInsert?: boolean): Promise<boolean>;
}

export interface FTTrackDataProcessThreadPool {
  execute(task: () => void): void;
}

export interface FTTrackHiLogInterceptor {
  init(): void;
}

export interface FTTrackLogCallback {
  onResponse(code: number, message: string, errorCode: string): void;
}

export interface FTTrackValueAccessor {
  getValue(): string;
}

export interface FTTrackInnerRuntime {
  createDataHelper(): FTTrackDataHelper;
  getSyncTaskManager(): FTTrackSyncTaskManager;
  getTrackLogManager(): FTTrackLogManager;
  getHiLogInterceptor(): FTTrackHiLogInterceptor;
  getRumManager(): FTTrackRumManager;
  getCachePolicy(): FTTrackCachePolicy;
  getDbManager(context: Context): FTTrackDbManager | null;
  getDataProcessThreadPool(): FTTrackDataProcessThreadPool;
  generateUUID(): string;
  getCurrentNanoTime(): number;
  nowMillis(): number;
  random(): number;
}

export class DefaultFTTrackInnerRuntime implements FTTrackInnerRuntime {
  createDataHelper(): FTTrackDataHelper {
    return new SyncDataHelper();
  }

  getSyncTaskManager(): FTTrackSyncTaskManager {
    return SyncTaskManager.getInstance();
  }

  getTrackLogManager(): FTTrackLogManager {
    return TrackLogManager.getInstance();
  }

  getHiLogInterceptor(): FTTrackHiLogInterceptor {
    return FTHiLogInterceptor.getInstance();
  }

  getRumManager(): FTTrackRumManager {
    return FTRUMInnerManager.getInstance();
  }

  getCachePolicy(): FTTrackCachePolicy {
    return FTDBCachePolicy.getInstance();
  }

  getDbManager(context: Context): FTTrackDbManager | null {
    return FTDBManager.getInstance(context);
  }

  getDataProcessThreadPool(): FTTrackDataProcessThreadPool {
    return DataProcessThreadPool.getInstance();
  }

  generateUUID(): string {
    return Utils.generateUUID();
  }

  getCurrentNanoTime(): number {
    return Utils.getCurrentNanoTime();
  }

  nowMillis(): number {
    return Date.now();
  }

  random(): number {
    return Math.random();
  }
}
