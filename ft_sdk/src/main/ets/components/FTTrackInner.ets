import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, LogGlobalContextDictionary, LogGlobalContextValue } from './Configs';
import { DataType } from './enum/Enums';
import { CollectType } from './rum/enum/RUMEnums';
import { FTInnerLogger } from './log/FTLogger';
import { SyncData } from './db/bean/SyncData';
import { TrackLogManager } from './log/TrackLogManager';
import { LogBean } from './bean/LogBean';
import { BaseContentBean } from './bean/BaseContentBean';
import { Context } from '@kit.AbilityKit';
import { RunnerCompleteCallBack } from './rum/callback/RunnerCompleteCallBack';
import { Constants } from './Constants';
import { PreparedLineProtocolContent, SyncDataHelper } from './SyncDataHelper';
import { SyncTaskManager } from './SyncTaskManager';
import { FTHiLogInterceptor } from './log/FTHiLogInterceptor';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import {
  SDKTaskPriority,
  SDKTaskRunner,
  SDKTaskScheduler,
  SDKTaskType
} from './thread/SDKTaskScheduler';
import {
  createSDKWorkerTaskBridgeHandler,
  createSDKWorkerTaskFallbackRunner,
  createSDKWorkerTaskRequest
} from './thread/SDKWorkerTaskBridge';
import { SDKDedicatedPoolManager } from './thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolInputDTO,
  SDKLogDTO,
  SDKRumEventDTO,
  SDKStringRecord,
  SDKSyncDataDraftDTO,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from './thread/SDKWorkerProtocol';
import { Utils } from './utils/Utils';
import { FTDBManager, SyncDataWriteResult } from './db/FTDBManager';
import { FTDBCachePolicy } from './db/FTDBCachePolicy';
// SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
// import { FTSessionReplayManager, SessionReplayConfig } from '@ft/session-replay-harmonyos';

const TAG = "FTTrackInner";
const RUM_DETAIL_DB_BATCH_FLUSH_DELAY_MS = 50;
const RUM_DETAIL_DB_BATCH_MAX_RECORDS = 64;

enum WriteCacheCategory {
  LOG = 'log',
  RUM = 'rum',
  NONE = 'none',
  MIXED = 'mixed'
}

/**
 * Sync Data Parameters Interface
 */
interface SyncDataParams {
  measurement: string;
  tags: Map<string, string>;
  fields: Map<string, string>;
  time: number;
}

interface FTTrackValueAccessor {
  getValue(): string;
}

interface SDKLineProtocolDraftsResponsePayload {
  drafts: SDKSyncDataDraftDTO[];
}

interface SDKRumCommandResponsePayload {
  syncDrafts: SDKSyncDataDraftDTO[];
}

interface SDKLineProtocolRecordsRequestPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SyncDataCachePolicyDecision {
  records: SyncData[];
  dropped: number;
  deletedOld: number;
  reservedLog: number;
  reservedRum: number;
  useDatabaseCachePolicy: boolean;
}

interface SyncDataCacheCountSummary {
  log: number;
  rum: number;
}

interface RumDetailDbWriteBatchEntry {
  source: string;
  requested: number;
  decision: SyncDataCachePolicyDecision;
  resolve: (result: SyncDataWriteResult | null) => void;
  reject: (error: Error) => void;
}

/**
 * Data Tracking Core Class
 * Responsible for data collection, storage, and sync triggering
 */
class FTTrackInner {
  private static instance: FTTrackInner | null = null;
  private static dataProcessTaskSequence: number = 0;
  private static rumWorkerTaskSequence: number = 0;
  private dataHelper: SyncDataHelper;
  private syncTaskManager: SyncTaskManager;
  private trackLogManager: TrackLogManager;
  // SessionReplay functionality has been migrated to independent library
  // private sessionReplayManager: FTSessionReplayManager;
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;
  private logCachePolicyTail: Promise<void> = Promise.resolve();
  private rumCachePolicyTail: Promise<void> = Promise.resolve();
  private rumDetailDbWriteBatch: RumDetailDbWriteBatchEntry[] = [];
  private rumDetailDbWriteBatchTimer: number = -1;
  private rumDetailDbWriteBatchFlushing: boolean = false;

  /**
   * Get all keys of an object (alternative to for...in loop)
   * @param obj Object
   * @returns Array of keys
   */
  private static getObjectKeys(obj: Record<string, object>): string[] {
    const keys: string[] = [];
    // Use Object.keys instead of for...in loop, directly iterate through all keys
    const objKeys = Object.keys(obj);
    for (let i = 0; i < objKeys.length; i++) {
      keys.push(objKeys[i]);
    }
    return keys;
  }

  private constructor() {
    this.dataHelper = new SyncDataHelper();
    this.syncTaskManager = SyncTaskManager.getInstance();
    this.trackLogManager = TrackLogManager.getInstance();
    // SessionReplay functionality has been migrated to independent library
    // this.sessionReplayManager = FTSessionReplayManager.getInstance();

    // Debug log for SyncTaskManager initialization
  }

  public static getInstance(): FTTrackInner {
    if (FTTrackInner.instance === null) {
      FTTrackInner.instance = new FTTrackInner();
      FTInnerLogger.d(TAG, `FTTrackInner new instance created`);
    }
    return FTTrackInner.instance;
  }

  public static resetInstanceInternal(): void {
    FTTrackInner.instance = null;
  }

  private submitDataProcessTask(name: string, task: SDKTaskRunner): void {
    const traceName = this.nextDataProcessTaskName(name);
    const command = SDKWorkerCommand.DATA_RUN;
    const runTask = async () => {
      const startTime = Date.now();
      let result = 'success';
      let errorMessage = '';
      try {
        await Promise.resolve(task());
      } catch (error) {
        result = 'failed';
        errorMessage = String(error);
        throw new Error(errorMessage);
      } finally {
        const costTime = Math.max(0, Date.now() - startTime);
        const errorPart = errorMessage.length > 0 ? ` error=${errorMessage}` : '';
        this.traceDataLane(`[CONSUMED] name=${traceName} result=${result}${errorPart} cost=${costTime}ms`);
      }
    };
    SDKTaskScheduler.getInstance().submitTask({
      type: SDKTaskType.DATA_PROCESS,
      name: traceName,
      priority: SDKTaskPriority.LOW,
      costHint: 'normal',
      workerRequest: createSDKWorkerTaskRequest(
        SDKDedicatedPoolType.DATA_PROCESS,
        command,
        traceName,
        SDKTaskPriority.LOW
      ),
      workerFallbackRunner: createSDKWorkerTaskFallbackRunner(traceName, command, runTask),
      workerBridgeHandler: createSDKWorkerTaskBridgeHandler(traceName, command, runTask)
    });
  }

  private submitRumWorkerDraftTask(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): void {
    try {
      const traceName = this.nextRumWorkerTaskName(source);
      const uuid = Utils.generateUUID();
      const prepared = this.dataHelper.prepareLineProtocolContent(measurement, tags, fields, time, dataType, uuid);
      const rumEvent = this.createRumWorkerEventDTO(dataType, customDataType, measurement, prepared, uuid);
      const workerRequest: SDKWorkerRequest = {
        id: `${SDKWorkerCommand.EVENT_RUM_COMMAND}:${traceName}:${Date.now()}`,
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: SDKTaskPriority.HIGH,
        createdAt: Date.now(),
        payload: rumEvent as Object as SDKWorkerPayload
      };

      SDKTaskScheduler.getInstance().submitTask({
        type: SDKTaskType.EVENT,
        name: traceName,
        priority: SDKTaskPriority.HIGH,
        serialKey: 'rum-worker-draft',
        costHint: 'normal',
        workerRequest,
        workerResponseHandler: async (response: SDKWorkerResponse) => {
          try {
            await this.handleRumWorkerDraftResponse(
              source,
              dataType,
              customDataType,
              measurement,
              response,
              callBack,
              callbackOnFinish
            );
          } catch (error) {
            FTInnerLogger.e(TAG, `RUM worker draft task failed: source=${source}, measurement=${measurement}, error=${error}`);
            if (callbackOnFinish && callBack) {
              callBack.onComplete();
            }
            throw error instanceof Error ? error : new Error(String(error));
          }
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling RUM worker draft task: ${error}`);
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
    }
  }

  private submitRumDraftWriteTask(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    drafts: SDKSyncDataDraftDTO[],
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): void {
    try {
      const traceName = this.nextDataProcessTaskName(source);
      const payload: SDKLineProtocolDraftsResponsePayload = {
        drafts
      };
      const workerRequest: SDKWorkerRequest = {
        id: `${SDKWorkerCommand.DATA_PASS_THROUGH_DRAFTS}:${traceName}:${Date.now()}`,
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.DATA_PASS_THROUGH_DRAFTS,
        priority: SDKTaskPriority.LOW,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      };

      SDKTaskScheduler.getInstance().submitTask({
        type: SDKTaskType.DATA_PROCESS,
        name: traceName,
        priority: SDKTaskPriority.LOW,
        costHint: 'normal',
        workerRequest,
        workerResponseHandler: async (response: SDKWorkerResponse) => {
          try {
            await this.handleRumDraftWriteResponse(
              source,
              dataType,
              customDataType,
              measurement,
              response,
              callBack,
              callbackOnFinish
            );
          } catch (error) {
            FTInnerLogger.e(TAG, `RUM draft write task failed: source=${source}, measurement=${measurement}, error=${error}`);
            if (callbackOnFinish && callBack) {
              callBack.onComplete();
            }
            throw error instanceof Error ? error : new Error(String(error));
          }
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling RUM draft write task: ${error}`);
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
    }
  }

  private nextDataProcessTaskName(name: string): string {
    FTTrackInner.dataProcessTaskSequence++;
    return `${name}#${FTTrackInner.dataProcessTaskSequence}`;
  }

  private nextRumWorkerTaskName(name: string): string {
    FTTrackInner.rumWorkerTaskSequence++;
    return `${name}#${FTTrackInner.rumWorkerTaskSequence}`;
  }

  private traceDataLane(message: string): void {
    FTInnerLogger.i(TAG, `<FT-DATA-LANE> ${message}`);
  }

  private createRumWorkerEventDTO(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    prepared: PreparedLineProtocolContent,
    uuid: string
  ): SDKRumEventDTO {
    const tags = prepared.tags as SDKStringRecord;
    const fields = prepared.fields as SDKStringRecord;
    return {
      eventType: this.resolveRumWorkerEventType(measurement, fields),
      name: this.resolveRumWorkerEventName(measurement, tags, fields),
      time: prepared.time,
      dataType: dataType.toString(),
      customDataType,
      measurement: prepared.measurement,
      uuid,
      integerCompatible: prepared.integerCompatible,
      viewId: this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_ID),
      viewName: this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_NAME),
      actionId: this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_ID),
      actionName: this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_NAME),
      resourceId: this.resolveRumWorkerResourceId(tags),
      sessionId: this.readStringRecordValue(tags, Constants.KEY_RUM_SESSION_ID),
      tags,
      fields
    };
  }

  private async handleRumWorkerDraftResponse(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    response: SDKWorkerResponse,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): Promise<void> {
    if (!response.ok) {
      throw new Error(response.errorMessage || `RUM worker command failed: ${measurement}`);
    }
    if (!response.payload) {
      throw new Error(`RUM worker command returned empty payload: ${measurement}`);
    }

    const payload = response.payload as Object as SDKRumCommandResponsePayload;
    const drafts = payload.syncDrafts || [];
    if (drafts.length === 0) {
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
      return;
    }

    this.submitRumDraftWriteTask(source, dataType, customDataType, measurement, drafts, callBack, callbackOnFinish);
  }

  private async handleRumDraftWriteResponse(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    response: SDKWorkerResponse,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): Promise<void> {
    if (!response.ok) {
      throw new Error(response.errorMessage || `RUM draft write command failed: ${measurement}`);
    }
    if (!response.payload) {
      throw new Error(`RUM draft write command returned empty payload: ${measurement}`);
    }

    const payload = response.payload as Object as SDKLineProtocolDraftsResponsePayload;
    const records = this.createSyncDataRecordsFromRumDrafts(payload.drafts || [], dataType);
    if (records.length === 0) {
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
      return;
    }

    const writeResult = await this.writePreparedSyncData(source, records);
    const result = writeResult !== null && writeResult.inserted > 0;
    const syncPollDeferredToBatch = this.isRumDetailBatchSource(source);
    const firstUuid = records[0].getUuid();

    if (result && customDataType && customDataType.length > 0) {
      FTInnerLogger.d(TAG,
        `[FT-ERROR-SAMPLING] Successfully stored data as ${customDataType}: uuid=${firstUuid}, measurement=${measurement}`);
    } else if (!result && writeResult !== null && writeResult.dropped > 0) {
      FTInnerLogger.e(TAG,
        `RUM worker draft write: ${measurement} ${customDataType || dataType.toString()}, uuid: ${firstUuid}, drop by Cache limit`);
    }

    if (result && callBack) {
      callBack.onComplete();
    } else if (!result && callbackOnFinish && callBack) {
      callBack.onComplete();
    }

    if (result && !syncPollDeferredToBatch) {
      this.syncTaskManager.executeSyncPoll();
    }
  }

  private createSyncDataRecordsFromRumDrafts(
    drafts: SDKSyncDataDraftDTO[],
    fallbackDataType: DataType
  ): SyncData[] {
    const records: SyncData[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i];
      const dataType = this.dataTypeFromWorkerString(draft.dataType, fallbackDataType);
      records.push(this.createSyncDataFromDraft(draft, dataType));
    }
    return records;
  }

  private dataTypeFromWorkerString(value: string | undefined, fallback: DataType): DataType {
    if (value === DataType.RUM_APP.toString()) {
      return DataType.RUM_APP;
    }
    if (value === DataType.RUM_WEBVIEW.toString()) {
      return DataType.RUM_WEBVIEW;
    }
    if (value === DataType.LOG.toString()) {
      return DataType.LOG;
    }
    return fallback;
  }

  private resolveRumWorkerEventType(measurement: string, fields: SDKStringRecord): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      const isActive = this.readStringRecordValue(fields, Constants.KEY_RUM_VIEW_IS_ACTIVE);
      return isActive === 'false' ? 'view.stop' : 'view.start';
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
      return 'action.add';
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
      return 'resource.complete';
    }
    return measurement || '';
  }

  private resolveRumWorkerEventName(
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord
  ): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_NAME) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_NAME) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_ERROR_TYPE) ||
        this.readStringRecordValue(fields, Constants.KEY_RUM_ERROR_MESSAGE) ||
        measurement;
    }
    return measurement || '';
  }

  private resolveRumWorkerResourceId(tags: SDKStringRecord): string | undefined {
    const method = this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_METHOD);
    const url = this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL);
    if (method && url) {
      return `${method}:${url}`;
    }
    return url ||
      this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_TRACE_ID) ||
      this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL_PATH);
  }

  private readStringRecordValue(record: SDKStringRecord, key: string): string | undefined {
    if (!record) {
      return undefined;
    }
    const value = record[key];
    if (value !== undefined && value !== null && value.length > 0) {
      return value;
    }
    return undefined;
  }

  /**
   * Initialize basic configuration
   */
  initBaseConfig(config: FTSDKConfig, context: Context): void {

    this.sdkConfig = config;
    this.context = context;
    this.dataHelper.initBaseConfig(config);

    // Debug log for SyncTaskManager initialization
    this.syncTaskManager.init(config, context);

    FTInnerLogger.i(TAG, "FTTrackInner base config initialized");
  }

  /**
   * Initialize log configuration
   */
  initLogConfig(config: FTLoggerConfig): void {
    this.dataHelper.initLogConfig(config);

    // Also set to TrackLogManager
    this.trackLogManager.setLogConfig(config);

    // Initialize hilog interceptor if console log capture is enabled
    if (config.isEnableConsoleLog()) {
      FTHiLogInterceptor.getInstance().init();
    }

    FTInnerLogger.i(TAG, "FTTrackInner log config initialized");
  }

  /**
   * Initialize RUM configuration
   */
  initRUMConfig(config: FTRUMConfig): void {
    this.dataHelper.initRUMConfig(config);
    FTInnerLogger.i(TAG, "FTTrackInner RUM config initialized");
  }

  /**
   * Add global context
   */
  appendGlobalContext(globalContext: Map<string, string>): void {
    this.dataHelper.appendGlobalContext(globalContext);
  }

  /**
   * Get data helper instance for RUM data consistency
   * @returns SyncDataHelper instance
   */
  getDataHelper(): SyncDataHelper {
    return this.dataHelper;
  }

  /**
   * Add global context key-value pair
   */
  appendGlobalContextKeyValue(key: string, value: string): void {
    this.dataHelper.appendGlobalContextByKeyValue(key, value);
  }

  /**
   * Add RUM global context
   */
  appendRUMGlobalContext(globalContext: Map<string, string>): void {
    this.dataHelper.appendRUMGlobalContext(globalContext);
  }

  /**
   * Add RUM global context key-value pair
   */
  appendRUMGlobalContextKeyValue(key: string, value: string): void {
    this.dataHelper.appendRUMGlobalContextByKeyValue(key, value);
  }

  /**
   * Add log global context
   */
  appendLogGlobalContext(globalContext: LogGlobalContextDictionary): void {
    this.dataHelper.appendLogGlobalContext(globalContext);
  }

  /**
   * Add log global context key-value pair
   */
  appendLogGlobalContextKeyValue(key: string, value: LogGlobalContextValue): void {
    this.dataHelper.appendLogGlobalContextByKeyValue(key, value);
  }

  /**
   * RUM data tracking
   */
  rum(
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null,
    collectTypeParam: CollectType | null = null
  ): void {

    // Debug log - use more obvious tags
    // FTInnerLogger.d(TAG, `<FT-VIEW-TEST> FTTrackInner.rum called: measurement=${measurement}`);
    // FTInnerLogger.d(TAG, ` FTTrackInner context status: ${this.context ? 'available' : 'null'}`);

    // If it's error data, add special logs
    if (measurement === 'error') {
      const errorMessage = fields.get('error_message') || 'unknown';
      const errorType = tags.get('error_type') || 'unknown';
      FTInnerLogger.d(TAG,
        ` FTTrackInner.rum processing error: message=${errorMessage}, type=${errorType}`);
    }

    // Removed high-frequency action debug logs to reduce log output
    // if (measurement === 'rum_action') {
    //   const actionName = tags.get('action_name') || 'unknown';
    //   const actionType = tags.get('action_type') || 'unknown';
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== ACTION DATA PROCESSING ==========`);
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action name: ${actionName}, type: ${actionType}`);
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action tags (${tags.size}):`);
    //   tags.forEach((value, key) => {
    //     FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG]   ${key}=${value}`);
    //   });
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action fields (${fields.size}):`);
    //   fields.forEach((value, key) => {
    //     FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG]   ${key}=${value}`);
    //   });
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== ACTION DATA PROCESSING END ==========`);
    // }

    // Removed verbose long_task and resource debug logs to reduce log output

    // Check if session should be collected
    const sessionId = tags.get('session_id');

    if (!sessionId && (collectTypeParam === null || collectTypeParam === undefined)) {
      // If no session ID, collect by default
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack);
      return;
    }

    // Check session collection type (aligned with Android)
    const collectType = collectTypeParam !== null && collectTypeParam !== undefined
      ? collectTypeParam
      : FTRUMInnerManager.getInstance().checkSessionWillCollect(sessionId);

    if (collectType === CollectType.ALL) {
      // Normal collection - store as RUM_APP
      // if (measurement === 'rum_action') {
      //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== STAGE 4: syncDataBackground START ==========`);
      // }
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack);
    } else if (collectType === CollectType.SAMPLING) {
      // Error sampling collection - store as rum_app_error_sampled
      // if (measurement === 'rum_action') {
      //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== STAGE 4: syncDataBackground (error_sampled) START ==========`);
      // }
      // Store as error_sampled type by using string concatenation (aligned with database implementation)
      // Use DataType.RUM_APP for getBodyContent, but store as "rum_app_error_sampled" in database
      this.syncDataBackgroundWithErrorSampled(DataType.RUM_APP, "rum_app_error_sampled", time, measurement, tags,
        fields, callBack);
    } else {
      // CollectType.DROP - do not collect
      FTInnerLogger.w(TAG,
        `[FT-ACTION-DEBUG] Session will not collect: sessionId=${sessionId}, collectType=${collectType}`);
      if (measurement === 'rum_action') {
        FTInnerLogger.w(TAG, `[FT-ACTION-DEBUG] Action data will NOT be processed due to session collection check`);
      }
    }

  }

  /**
   * WebView RUM data tracking
   */
  rumWebView(
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    collectType: CollectType = CollectType.ALL
  ): void {
    FTInnerLogger.d(TAG, `TAG ========== rumWebView() called ==========`);
    FTInnerLogger.d(TAG, `TAG Measurement: ${measurement},Time: ${time}, Collect type: ${collectType}`);

    const formattedTags = new Map<string, string>();
    tags.forEach((value, key) => {
      // Convert number values that might be JSON strings
      if (typeof value === 'string' && value.startsWith('"') && value.endsWith('"')) {
        formattedTags.set(key, value); // Already a JSON string
      } else {
        formattedTags.set(key, value);
      }
    });

    const formattedFields = new Map<string, string>();
    fields.forEach((value, key) => {
      // Convert number values that might be JSON strings
      if (typeof value === 'string' && value.startsWith('"') && value.endsWith('"')) {
        formattedFields.set(key, value); // Already a JSON string
      } else {
        formattedFields.set(key, value);
      }
    });

    // Check if session should be collected (aligned with rum() method)
    const sessionId = formattedTags.get('session_id');
    FTInnerLogger.d(TAG, `TAG Session ID: ${sessionId}`);

    if (sessionId && this.dataHelper.checkSessionWillCollect(sessionId)) {
      FTInnerLogger.d(TAG, `TAG Session will collect, calling syncDataBackground`);
      // Call syncDataBackground with RUM_WEBVIEW data type
      this.syncDataBackground(DataType.RUM_WEBVIEW, time, measurement, formattedTags, formattedFields, null);
    } else {
      const willCollect = sessionId ? this.dataHelper.checkSessionWillCollect(sessionId) : false;
      FTInnerLogger.w(TAG,
        `TAG Session will not collect: sessionId=${sessionId}, willCollect=${willCollect}`);
    }
  }

  /**
   * Batch LogBean sync processing - called by TrackLogManager
   */
  batchLogBeanSync(batchData: BaseContentBean[], isSilence: boolean): void {
    FTInnerLogger.d(TAG, `FTTrackInner.batchLogBeanSync entry: size=${batchData?.length || 0}, isSilence=${isSilence}`);

    if (!batchData || batchData.length === 0) {
      return;
    }

    try {
      this.submitDataProcessTask(`data.prepare.logBatch:${batchData.length}`, async () => {
        const createTasks: Promise<SyncData | null>[] = [];

        for (const logBean of batchData) {
          if (logBean instanceof LogBean) {
            createTasks.push(this.createSyncDataFromLogBean(logBean).catch((error: Error) => {
              FTInnerLogger.e(TAG, `Error creating SyncData from LogBean: ${error}`);
              return null;
            }));
          }
        }

        const createdRecords = await Promise.all(createTasks);
        const records: SyncData[] = [];
        for (const record of createdRecords) {
          if (record !== null) {
            records.push(record);
          }
        }

        const writeResult = await this.writePreparedSyncData('data.prepare.logBatch', records);
        const successCount = writeResult ? writeResult.inserted : 0;
        const droppedCount = writeResult ? writeResult.dropped : 0;
        const duplicateCount = writeResult ? writeResult.duplicateSkipped : 0;
        FTInnerLogger.d(TAG,
          `Batch log processing completed: inserted=${successCount}/${batchData.length}, dropped=${droppedCount}, duplicate=${duplicateCount}`);

        if (successCount > 0 && !isSilence) {
          this.syncTaskManager.executeSyncPoll();
        }
      });

    } catch (error) {
      FTInnerLogger.e(TAG, `Error in batchLogBeanSync: ${error}`);
    }
  }

  batchLogDTOSync(batchData: SDKLogDTO[], isSilence: boolean): void {
    FTInnerLogger.d(TAG, `FTTrackInner.batchLogDTOSync entry: size=${batchData?.length || 0}, isSilence=${isSilence}`);

    if (!batchData || batchData.length === 0) {
      return;
    }

    try {
      this.submitDataProcessTask(`data.prepare.logDTOBatch:${batchData.length}`, async () => {
        const records = await this.createSyncDataFromLogDTOs(batchData);
        const writeResult = await this.writePreparedSyncData('data.prepare.logDTOBatch', records);
        const successCount = writeResult ? writeResult.inserted : 0;
        const droppedCount = writeResult ? writeResult.dropped : 0;
        const duplicateCount = writeResult ? writeResult.duplicateSkipped : 0;
        FTInnerLogger.d(TAG,
          `Batch log DTO processing completed: inserted=${successCount}/${batchData.length}, dropped=${droppedCount}, duplicate=${duplicateCount}`);

        if (successCount > 0 && !isSilence) {
          this.syncTaskManager.executeSyncPoll();
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in batchLogDTOSync: ${error}`);
    }
  }

  private getWriteCacheCategory(dataType: DataType): WriteCacheCategory {
    if (dataType === DataType.LOG) {
      return WriteCacheCategory.LOG;
    }
    if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      return WriteCacheCategory.RUM;
    }
    return WriteCacheCategory.NONE;
  }

  private getWriteCacheCategoryForRecords(records: SyncData[]): WriteCacheCategory {
    let result = WriteCacheCategory.NONE;
    for (const record of records) {
      const category = this.getWriteCacheCategory(record.getDataType());
      if (category === WriteCacheCategory.NONE) {
        continue;
      }
      if (result === WriteCacheCategory.NONE) {
        result = category;
        continue;
      }
      if (result !== category) {
        return WriteCacheCategory.MIXED;
      }
    }
    return result;
  }

  private createCachePolicyDecision(
    records: SyncData[],
    dropped: number,
    deletedOld: number,
    reservedLog: number,
    reservedRum: number,
    useDatabaseCachePolicy: boolean
  ): SyncDataCachePolicyDecision {
    return {
      records,
      dropped,
      deletedOld,
      reservedLog,
      reservedRum,
      useDatabaseCachePolicy
    };
  }

  private createPassthroughCachePolicyDecision(records: SyncData[]): SyncDataCachePolicyDecision {
    return this.createCachePolicyDecision(records, 0, 0, 0, 0, false);
  }

  private createPolicyOnlyWriteResult(
    source: string,
    requested: number,
    dropped: number,
    deletedOld: number
  ): SyncDataWriteResult {
    return {
      success: true,
      source,
      requested,
      inserted: 0,
      dropped,
      duplicateSkipped: 0,
      deletedOld,
      errorMessage: ''
    };
  }

  private async runCachePolicyLocked(
    category: WriteCacheCategory,
    runner: () => Promise<SyncDataCachePolicyDecision>
  ): Promise<SyncDataCachePolicyDecision> {
    const previousTail = category === WriteCacheCategory.LOG ? this.logCachePolicyTail : this.rumCachePolicyTail;
    let releaseTail: () => void = () => {};
    const currentTail = new Promise<void>((resolve) => {
      releaseTail = () => {
        resolve();
      };
    });
    const chainedTail = previousTail.catch(() => {}).then(() => currentTail);
    if (category === WriteCacheCategory.LOG) {
      this.logCachePolicyTail = chainedTail;
    } else {
      this.rumCachePolicyTail = chainedTail;
    }

    await previousTail.catch(() => {});
    try {
      return await runner();
    } finally {
      releaseTail();
    }
  }

  private async applySingleCategoryCachePolicy(
    category: WriteCacheCategory,
    records: SyncData[]
  ): Promise<SyncDataCachePolicyDecision> {
    if (!this.context) {
      return this.createPassthroughCachePolicyDecision(records);
    }

    const cachePolicy = FTDBCachePolicy.getInstance();
    if (category === WriteCacheCategory.LOG) {
      const status = await cachePolicy.optLogCachePolicy(this.context, records.length);
      const deletedOld = status > 0 ? status : 0;
      if (status < 0) {
        const dropCount = Math.min(records.length, Math.abs(status));
        const allowedCount = Math.max(0, records.length - dropCount);
        const allowedRecords = records.slice(0, allowedCount);
        if (allowedCount > 0) {
          cachePolicy.optLogCount(allowedCount);
        }
        return this.createCachePolicyDecision(allowedRecords, dropCount, 0, allowedCount, 0, false);
      }

      cachePolicy.optLogCount(records.length);
      return this.createCachePolicyDecision(records, 0, deletedOld, records.length, 0, false);
    }

    if (category === WriteCacheCategory.RUM) {
      const status = await cachePolicy.optRUMCachePolicy(this.context, records.length);
      const deletedOld = status > 0 ? status : 0;
      if (status < 0) {
        return this.createCachePolicyDecision([], records.length, 0, 0, 0, false);
      }

      cachePolicy.optRumCount(records.length);
      return this.createCachePolicyDecision(records, 0, deletedOld, 0, records.length, false);
    }

    return this.createPassthroughCachePolicyDecision(records);
  }

  private async applyWriteCachePolicy(records: SyncData[]): Promise<SyncDataCachePolicyDecision> {
    const category = this.getWriteCacheCategoryForRecords(records);
    if (category === WriteCacheCategory.LOG || category === WriteCacheCategory.RUM) {
      return await this.runCachePolicyLocked(category, async () => {
        return await this.applySingleCategoryCachePolicy(category, records);
      });
    }

    if (category === WriteCacheCategory.MIXED) {
      FTInnerLogger.w(TAG, `Mixed cache categories in one write batch, fallback to DB-side cache policy`);
      return this.createCachePolicyDecision(records, 0, 0, 0, 0, true);
    }

    return this.createPassthroughCachePolicyDecision(records);
  }

  private countInsertedCacheRecords(records: SyncData[], inserted: number): SyncDataCacheCountSummary {
    const summary: SyncDataCacheCountSummary = {
      log: 0,
      rum: 0
    };
    const insertedLimit = Math.min(records.length, Math.max(0, inserted));
    for (let i = 0; i < insertedLimit; i++) {
      const category = this.getWriteCacheCategory(records[i].getDataType());
      if (category === WriteCacheCategory.LOG) {
        summary.log++;
      } else if (category === WriteCacheCategory.RUM) {
        summary.rum++;
      }
    }
    return summary;
  }

  private rollbackReservedCacheCounts(
    decision: SyncDataCachePolicyDecision,
    inserted: number,
    dbDeletedOld: number
  ): void {
    if (decision.useDatabaseCachePolicy) {
      return;
    }

    const insertedCounts = this.countInsertedCacheRecords(decision.records, inserted);
    const cachePolicy = FTDBCachePolicy.getInstance();
    const logDbDeletes = decision.reservedLog > 0 ? dbDeletedOld : 0;
    const rumDbDeletes = decision.reservedRum > 0 ? dbDeletedOld : 0;
    const logRollback = Math.max(0, decision.reservedLog + logDbDeletes - insertedCounts.log);
    const rumRollback = Math.max(0, decision.reservedRum + rumDbDeletes - insertedCounts.rum);
    if (logRollback > 0) {
      cachePolicy.optLogCount(-logRollback);
    }
    if (rumRollback > 0) {
      cachePolicy.optRumCount(-rumRollback);
    }
  }

  private mergeCachePolicyDecision(
    result: SyncDataWriteResult,
    requested: number,
    decision: SyncDataCachePolicyDecision
  ): SyncDataWriteResult {
    result.requested = requested;
    result.dropped += decision.dropped;
    result.deletedOld += decision.deletedOld;
    return result;
  }

  private isRumDetailBatchSource(source: string): boolean {
    return source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_RESOURCE}` ||
      source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_ERROR}` ||
      source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_LONG_TASK}`;
  }

  private shouldCoalesceRumDetailDbWrite(
    source: string,
    requestedRecords: SyncData[],
    decision: SyncDataCachePolicyDecision
  ): boolean {
    return this.isRumDetailBatchSource(source) &&
      requestedRecords.length === 1 &&
      decision.records.length > 0 &&
      !decision.useDatabaseCachePolicy;
  }

  private getRumDetailDbBatchRecordCount(): number {
    let count = 0;
    for (const entry of this.rumDetailDbWriteBatch) {
      count += entry.decision.records.length;
    }
    return count;
  }

  private clearRumDetailDbBatchTimer(): void {
    if (this.rumDetailDbWriteBatchTimer >= 0) {
      clearTimeout(this.rumDetailDbWriteBatchTimer);
      this.rumDetailDbWriteBatchTimer = -1;
    }
  }

  private scheduleRumDetailDbBatchFlush(delayMs: number = RUM_DETAIL_DB_BATCH_FLUSH_DELAY_MS): void {
    if (this.rumDetailDbWriteBatchTimer >= 0 || this.rumDetailDbWriteBatchFlushing) {
      return;
    }
    this.rumDetailDbWriteBatchTimer = setTimeout(() => {
      this.rumDetailDbWriteBatchTimer = -1;
      this.flushRumDetailDbBatch().catch((error: Error) => {
        FTInnerLogger.e(TAG, `RUM detail DB batch flush failed: ${error}`);
      });
    }, delayMs) as number;
  }

  private createRumDetailBatchSource(entries: RumDetailDbWriteBatchEntry[]): string {
    let resourceCount = 0;
    let errorCount = 0;
    let longTaskCount = 0;
    for (const entry of entries) {
      const count = entry.decision.records.length;
      if (entry.source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_RESOURCE}`) {
        resourceCount += count;
      } else if (entry.source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_ERROR}`) {
        errorCount += count;
      } else if (entry.source === `data.prepare:${Constants.FT_MEASUREMENT_RUM_LONG_TASK}`) {
        longTaskCount += count;
      }
    }
    return `data.prepare.batch:resource=${resourceCount}:error=${errorCount}:long_task=${longTaskCount}`;
  }

  private createBatchEntryWriteResult(
    source: string,
    requested: number,
    success: boolean,
    inserted: number,
    duplicateSkipped: number,
    dbDeletedOld: number,
    errorMessage: string
  ): SyncDataWriteResult {
    return {
      success,
      source,
      requested,
      inserted,
      dropped: 0,
      duplicateSkipped,
      deletedOld: dbDeletedOld,
      errorMessage
    };
  }

  private resolveRumDetailDbBatchEntries(
    entries: RumDetailDbWriteBatchEntry[],
    writeResult: SyncDataWriteResult
  ): void {
    let remainingInserted = writeResult.success ? Math.max(0, writeResult.inserted) : 0;
    let remainingDuplicate = writeResult.success ? Math.max(0, writeResult.duplicateSkipped) : 0;
    let remainingDbDeletedOld = writeResult.success ? Math.max(0, writeResult.deletedOld) : 0;

    for (const entry of entries) {
      const eligibleCount = entry.decision.records.length;
      const inserted = Math.min(eligibleCount, remainingInserted);
      remainingInserted = Math.max(0, remainingInserted - inserted);
      const duplicateSkipped = Math.min(Math.max(0, eligibleCount - inserted), remainingDuplicate);
      remainingDuplicate = Math.max(0, remainingDuplicate - duplicateSkipped);
      const dbDeletedOld = Math.min(eligibleCount, remainingDbDeletedOld);
      remainingDbDeletedOld = Math.max(0, remainingDbDeletedOld - dbDeletedOld);

      this.rollbackReservedCacheCounts(entry.decision, inserted, dbDeletedOld);
      const entryResult = this.createBatchEntryWriteResult(
        entry.source,
        entry.requested,
        writeResult.success,
        inserted,
        duplicateSkipped,
        dbDeletedOld,
        writeResult.errorMessage
      );
      entry.resolve(this.mergeCachePolicyDecision(entryResult, entry.requested, entry.decision));
    }
  }

  private async writeRecordsToDb(
    source: string,
    records: SyncData[],
    useDatabaseCachePolicy: boolean,
    forceTransaction: boolean = false
  ): Promise<SyncDataWriteResult> {
    if (!this.context) {
      throw new Error('Context is null');
    }
    const dbManager = FTDBManager.getInstance(this.context);
    return await SDKDedicatedPoolManager.getInstance().runDbWrite(source, async (dbLaneWaitMs?: number) => {
      return await dbManager.writeSyncDataAtomically(source, records, {
        applyCachePolicy: useDatabaseCachePolicy,
        reInsert: false,
        dbLaneWaitMs: dbLaneWaitMs || 0,
        forceTransaction
      });
    });
  }

  private takeRumDetailDbBatchChunk(maxRecords: number): RumDetailDbWriteBatchEntry[] {
    const entries: RumDetailDbWriteBatchEntry[] = [];
    let recordCount = 0;

    while (this.rumDetailDbWriteBatch.length > 0) {
      const entry = this.rumDetailDbWriteBatch[0];
      const entryRecordCount = entry.decision.records.length;
      if (entries.length > 0 && recordCount + entryRecordCount > maxRecords) {
        break;
      }
      entries.push(entry);
      this.rumDetailDbWriteBatch.splice(0, 1);
      recordCount += entryRecordCount;
      if (recordCount >= maxRecords) {
        break;
      }
    }

    return entries;
  }

  private async flushRumDetailDbBatch(): Promise<void> {
    if (this.rumDetailDbWriteBatchFlushing) {
      return;
    }
    this.clearRumDetailDbBatchTimer();
    if (this.rumDetailDbWriteBatch.length === 0) {
      return;
    }

    this.rumDetailDbWriteBatchFlushing = true;
    const entries = this.takeRumDetailDbBatchChunk(RUM_DETAIL_DB_BATCH_MAX_RECORDS);
    const records: SyncData[] = [];
    for (const entry of entries) {
      for (const record of entry.decision.records) {
        records.push(record);
      }
    }

    try {
      const batchSource = this.createRumDetailBatchSource(entries);
      const writeResult = await this.writeRecordsToDb(batchSource, records, false, records.length > 1);
      this.resolveRumDetailDbBatchEntries(entries, writeResult);
      if (writeResult.success && writeResult.inserted > 0) {
        this.syncTaskManager.executeSyncPoll();
      }
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      for (const entry of entries) {
        this.rollbackReservedCacheCounts(entry.decision, 0, 0);
        entry.reject(normalized);
      }
    } finally {
      this.rumDetailDbWriteBatchFlushing = false;
      if (this.rumDetailDbWriteBatch.length > 0) {
        if (this.getRumDetailDbBatchRecordCount() >= RUM_DETAIL_DB_BATCH_MAX_RECORDS) {
          this.scheduleRumDetailDbBatchFlush(0);
        } else {
          this.scheduleRumDetailDbBatchFlush();
        }
      }
    }
  }

  private enqueueRumDetailDbWrite(
    source: string,
    requested: number,
    decision: SyncDataCachePolicyDecision
  ): Promise<SyncDataWriteResult | null> {
    return new Promise<SyncDataWriteResult | null>((resolve, reject) => {
      const entry: RumDetailDbWriteBatchEntry = {
        source,
        requested,
        decision,
        resolve,
        reject
      };
      this.rumDetailDbWriteBatch.push(entry);
      if (this.getRumDetailDbBatchRecordCount() >= RUM_DETAIL_DB_BATCH_MAX_RECORDS) {
        this.clearRumDetailDbBatchTimer();
        this.scheduleRumDetailDbBatchFlush(0);
      } else {
        this.scheduleRumDetailDbBatchFlush();
      }
    });
  }

  private async writePreparedSyncData(source: string, records: SyncData[]): Promise<SyncDataWriteResult | null> {
    if (!records || records.length === 0) {
      return null;
    }
    if (!this.context) {
      FTInnerLogger.e(TAG, `Context is null`);
      return null;
    }

    const cacheDecision = await this.applyWriteCachePolicy(records);
    if (cacheDecision.records.length === 0) {
      return this.createPolicyOnlyWriteResult(source, records.length, cacheDecision.dropped, cacheDecision.deletedOld);
    }

    if (this.shouldCoalesceRumDetailDbWrite(source, records, cacheDecision)) {
      return await this.enqueueRumDetailDbWrite(source, records.length, cacheDecision);
    }

    try {
      const writeResult = await this.writeRecordsToDb(
        source,
        cacheDecision.records,
        cacheDecision.useDatabaseCachePolicy,
        cacheDecision.records.length > 1
      );
      const dbDeletedOld = writeResult.deletedOld;
      this.rollbackReservedCacheCounts(cacheDecision, writeResult.inserted, dbDeletedOld);
      return this.mergeCachePolicyDecision(writeResult, records.length, cacheDecision);
    } catch (error) {
      this.rollbackReservedCacheCounts(cacheDecision, 0, 0);
      const normalized = error instanceof Error ? error : new Error(String(error));
      throw normalized;
    }
  }

  /**
   * Track data async processing (background) with error sampled type
   * This method is used when session is collected by error sampling
   * @param dataTypeForContent DataType enum for getBodyContent (e.g., DataType.RUM_APP)
   * @param dataTypeForStorage String data type for database storage (e.g., "rum_app_error_sampled")
   */
  private syncDataBackgroundWithErrorSampled(
    dataTypeForContent: DataType,
    dataTypeForStorage: string,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    this.submitRumWorkerDraftTask(
      'data.prepare.errorSampled',
      dataTypeForContent,
      dataTypeForStorage,
      time,
      measurement,
      tags,
      fields,
      callBack,
      true
    );
  }

  /**
   * Track data async processing (background)
   */
  private syncDataBackground(
    dataType: DataType,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    // Reduced logging - only log key information

    const taskName = `data.prepare:${measurement}`;
    this.submitRumWorkerDraftTask(taskName, dataType, undefined, time, measurement, tags, fields, callBack, false);
  }

  /**
   * Create sync data record from LogBean
   */
  private async createSyncDataFromLogBean(logBean: LogBean): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = Utils.generateUUID();

      // Convert LogBean to Map format - let SyncDataHelper handle global context merging
      const tags = new Map<string, string>();
      const fields = new Map<string, string>();

      // Add LogBean tags and fields
      const logTags = logBean.getAllTags();
      const logFields = logBean.getAllFields();


      const tagKeys = FTTrackInner.getObjectKeys(logTags);
      // FTInnerLogger.d(TAG, `[FT-LOG-DEBUG] LogBean tag keys: ${tagKeys.join(',')}`);
      for (let i = 0; i < tagKeys.length; i++) {
        const key = tagKeys[i];
        const value: object | string = logTags[key];
        // Extract string value from object (handles StringWrapper and {value: string} objects)
        let stringValue: string;
        if (typeof value === 'string') {
          stringValue = value;
        } else if (typeof value === 'object' && value !== null) {
          // Check if it's a StringWrapper or object with 'value' property
          const valueObj = value as Record<string, object>;
          if (valueObj['value'] !== undefined && typeof valueObj['value'] === 'string') {
            stringValue = valueObj['value'] as string;
          } else if (typeof valueObj['getValue'] === 'function') {
            // StringWrapper with getValue method
            try {
              stringValue = (value as FTTrackValueAccessor).getValue();
            } catch (error) {
              stringValue = JSON.stringify(value);
            }
          } else {
            stringValue = JSON.stringify(value);
          }
        } else {
          stringValue = String(value);
        }
        tags.set(key, stringValue);
      }

      const fieldKeys = FTTrackInner.getObjectKeys(logFields);
      for (let i = 0; i < fieldKeys.length; i++) {
        const key = fieldKeys[i];
        const value = logFields[key];
        // Extract string value from object (handles StringWrapper and {value: string} objects)
        let stringValue: string;
        if (typeof value === 'string') {
          stringValue = value;
        } else if (typeof value === 'object' && value !== null) {
          // Check if it's a StringWrapper or object with 'value' property
          const valueObj = value as Record<string, object>;
          if (valueObj['value'] !== undefined && typeof valueObj['value'] === 'string') {
            stringValue = valueObj['value'] as string;
          } else if (typeof valueObj['getValue'] === 'function') {
            // StringWrapper with getValue method
            try {
              stringValue = (value as FTTrackValueAccessor).getValue();
            } catch (error) {
              stringValue = JSON.stringify(value);
            }
          } else {
            stringValue = JSON.stringify(value);
          }
        } else {
          stringValue = String(value);
        }
        fields.set(key, stringValue);
      }

      // Add content field
      fields.set('message', logBean.getContent());

      // Get measurement name from LogBean
      const measurement = logBean.getMeasurement();

      // Verify measurement is correct
      if (!measurement || measurement.length === 0) {
        FTInnerLogger.e(TAG, `LogBean measurement is empty! Using default: ${Constants.FT_LOG_DEFAULT_MEASUREMENT}`);
      }

      // Get data content - SyncDataHelper will merge global context automatically
      // Use logBean.getMeasurement() to get the measurement name (e.g., "df_rum_harmonyos_log")
      const finalMeasurement = measurement || Constants.FT_LOG_DEFAULT_MEASUREMENT;

      return await this.createSyncDataWithWorker(
        DataType.LOG,
        finalMeasurement,
        tags,
        fields,
        logBean.getTimeNano(),
        uuid
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error creating SyncData from LogBean: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Create sync data record
   */
  private async createSyncData(
    dataHelper: SyncDataHelper,
    dataType: DataType,
    data: SyncDataParams
  ): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = Utils.generateUUID();

      return await this.createSyncDataWithWorker(
        dataType,
        data.measurement,
        data.tags,
        data.fields,
        data.time,
        uuid,
        dataHelper
      );

    } catch (error) {
      FTInnerLogger.e(TAG, `createSyncData failed: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Generate ID
   */
  private generateId(): number {
    return Date.now() + Math.floor(Math.random() * 1000);
  }

  private async createSyncDataFromLogDTOs(logDTOs: SDKLogDTO[]): Promise<SyncData[]> {
    const inputs: SDKLineProtocolInputDTO[] = [];
    const dataTypes: DataType[] = [];

    for (let i = 0; i < logDTOs.length; i++) {
      const logDTO = logDTOs[i];
      const uuid = Utils.generateUUID();
      const tags = SyncDataHelper.recordToStringMap(logDTO.tags || {});
      const fields = SyncDataHelper.recordToStringMap(logDTO.fields || {});
      if (!fields.has(Constants.KEY_MESSAGE)) {
        fields.set(Constants.KEY_MESSAGE, logDTO.content || '');
      }
      const measurement = logDTO.measurement && logDTO.measurement.length > 0 ?
        logDTO.measurement : Constants.FT_LOG_DEFAULT_MEASUREMENT;
      const prepared = this.dataHelper.prepareLineProtocolContent(
        measurement,
        tags,
        fields,
        logDTO.timeNano,
        DataType.LOG,
        uuid
      );
      inputs.push(this.toLineProtocolInput(DataType.LOG, uuid, prepared));
      dataTypes.push(DataType.LOG);
    }

    return await this.createSyncDataFromLineInputs(inputs, dataTypes);
  }

  private async createSyncDataWithWorker(
    dataType: DataType,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    time: number,
    uuid: string,
    dataHelper: SyncDataHelper = this.dataHelper
  ): Promise<SyncData> {
    const prepared = dataHelper.prepareLineProtocolContent(measurement, tags, fields, time, dataType, uuid);
    const input = this.toLineProtocolInput(dataType, uuid, prepared);
    const records = await this.createSyncDataFromLineInputs([input], [dataType]);
    if (records.length > 0) {
      return records[0];
    }

    const fallbackDataString = dataHelper.getBodyContent(measurement, tags, fields, time, dataType, uuid);
    return this.createSyncDataFromDraft({
      dataType: dataType.toString(),
      dataString: fallbackDataString,
      uuid,
      time
    }, dataType);
  }

  private toLineProtocolInput(
    dataType: DataType,
    uuid: string,
    prepared: PreparedLineProtocolContent
  ): SDKLineProtocolInputDTO {
    return {
      dataType: dataType.toString(),
      measurement: prepared.measurement,
      tags: prepared.tags as SDKStringRecord,
      fields: prepared.fields as SDKStringRecord,
      time: prepared.time,
      uuid,
      integerCompatible: prepared.integerCompatible
    };
  }

  private async createSyncDataFromLineInputs(
    inputs: SDKLineProtocolInputDTO[],
    dataTypes: DataType[]
  ): Promise<SyncData[]> {
    if (inputs.length === 0) {
      return [];
    }

    try {
      const requestPayload: SDKLineProtocolRecordsRequestPayload = {
        records: inputs
      };

      const response = await SDKDedicatedPoolManager.getInstance().executeCommand({
        id: `data.createLineProtocol.${Date.now()}.${Math.floor(Math.random() * 100000)}`,
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: requestPayload as Object as SDKWorkerPayload
      });

      if (response.ok && response.payload) {
        const payload = response.payload as Object as SDKLineProtocolDraftsResponsePayload;
        const drafts = payload.drafts || [];
        const records: SyncData[] = [];
        for (let i = 0; i < drafts.length; i++) {
          const dataType = i < dataTypes.length ? dataTypes[i] : DataType.LOG;
          records.push(this.createSyncDataFromDraft(drafts[i], dataType));
        }
        return records;
      }

      FTInnerLogger.w(TAG, `DataProcessWorker line protocol failed: ${response.errorMessage || 'empty response'}`);
    } catch (error) {
      FTInnerLogger.w(TAG, `DataProcessWorker line protocol error: ${error}`);
    }

    const fallbackRecords: SyncData[] = [];
    for (let i = 0; i < inputs.length; i++) {
      const input = inputs[i];
      const dataType = i < dataTypes.length ? dataTypes[i] : DataType.LOG;
      const tags = SyncDataHelper.recordToStringMap(input.tags);
      const fields = SyncDataHelper.recordToStringMap(input.fields);
      const dataString = SyncDataHelper.convertToLineProtocolLine(
        input.measurement,
        tags,
        fields,
        input.time,
        input.integerCompatible === true
      );
      fallbackRecords.push(this.createSyncDataFromDraft({
        dataType: input.dataType,
        customDataType: input.customDataType,
        dataString,
        uuid: input.uuid,
        time: input.time
      }, dataType));
    }
    return fallbackRecords;
  }

  private createSyncDataFromDraft(draft: SDKSyncDataDraftDTO, dataType: DataType): SyncData {
    const syncData = new SyncData(dataType);
    syncData.setId(this.generateId());
    syncData.setUuid(draft.uuid);
    syncData.setDataString(draft.dataString);
    syncData.setTime(draft.time);
    if (draft.customDataType && draft.customDataType.length > 0) {
      syncData.setCustomDataTypeString(draft.customDataType);
    }
    return syncData;
  }

  /*
   * SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
   * 
   * To use SessionReplay functionality, please:
   * 1. Install independent library: ohpm install @ft/session-replay-harmonyos
   * 2. Import library: import { FTSessionReplayManager } from '@ft/session-replay-harmonyos'
   * 3. Refer to independent library documentation for integration
   */

  // /**
  //  * Initialize SessionReplay
  //  */
  // async initSessionReplay(config: SessionReplayConfig): Promise<boolean> {
  //   try {
  //     const result = await this.sessionReplayManager.initSessionReplay(config);
  //     FTInnerLogger.i(TAG, `SessionReplay initialization ${result ? 'succeeded' : 'failed'}`);
  //     return result;
  //   } catch (error) {
  //     FTInnerLogger.e(TAG, `Failed to initialize SessionReplay: ${error}`);
  //     return false;
  //   }
  // }

  /**
   * Close all managers
   */
  async shutdown(): Promise<void> {
    FTInnerLogger.i(TAG, "Shutting down FTTrackInner");

    try {
      this.trackLogManager.shutdown();
      this.syncTaskManager.stop();
      // SessionReplay functionality has been migrated to independent library
      // await this.sessionReplayManager.shutdown();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error during shutdown: ${error}`);
    }
  }
}

export default FTTrackInner;
