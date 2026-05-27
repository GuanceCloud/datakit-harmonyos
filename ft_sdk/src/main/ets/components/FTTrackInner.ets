import { FTLoggerConfig, FTRUMConfig, FTSDKConfig } from './Configs';
import { DataType } from './enum/Enums';
import { CollectType } from './rum/enum/RUMEnums';
import { FTInnerLogger } from './log/FTLogger';
import { SyncData } from './db/bean/SyncData';
import { QueueStatus } from './log/TrackLogManager';
import { LogBean } from './bean/LogBean';
import { BaseContentBean } from './bean/BaseContentBean';
import { Context } from '@kit.AbilityKit';
import { NetCodeStatus } from './http/HttpEngine';
import { RunnerCompleteCallBack } from './rum/callback/RunnerCompleteCallBack';
import { Constants } from './Constants';
import {
  DefaultFTTrackInnerRuntime,
  FTTrackDataHelper,
  FTTrackInnerRuntime,
  FTTrackLogCallback,
  FTTrackLogManager,
  FTTrackSyncTaskManager,
  FTTrackValueAccessor
} from './FTTrackInnerRuntime';
// SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
// import { FTSessionReplayManager, SessionReplayConfig } from '@ft/session-replay-harmonyos';

const TAG = "FTTrackInner";

/**
 * Sync Data Parameters Interface
 */
interface SyncDataParams {
  measurement: string;
  tags: Map<string, string>;
  fields: Map<string, string>;
  time: number;
}

/**
 * Data Tracking Core Class
 * Responsible for data collection, storage, and sync triggering
 */
class FTTrackInner {
  private static instance: FTTrackInner | null = null;
  private static runtime: FTTrackInnerRuntime = new DefaultFTTrackInnerRuntime();
  private dataHelper: FTTrackDataHelper;
  private syncTaskManager: FTTrackSyncTaskManager;
  private trackLogManager: FTTrackLogManager;
  // SessionReplay functionality has been migrated to independent library
  // private sessionReplayManager: FTSessionReplayManager;
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;

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
    this.dataHelper = FTTrackInner.runtime.createDataHelper();
    this.syncTaskManager = FTTrackInner.runtime.getSyncTaskManager();
    this.trackLogManager = FTTrackInner.runtime.getTrackLogManager();
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

  public static setRuntimeForTest(runtime: FTTrackInnerRuntime): void {
    FTTrackInner.runtime = runtime;
  }

  public static resetRuntimeForTest(): void {
    FTTrackInner.runtime = new DefaultFTTrackInnerRuntime();
  }

  public static resetInstanceForTest(): void {
    FTTrackInner.instance = null;
  }

  public static getObjectKeysForTest(obj: Record<string, object>): string[] {
    return FTTrackInner.getObjectKeys(obj);
  }

  /**
   * Check if already initialized
   */
  public isInitialized(): boolean {
    return this.context !== null;
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
      FTTrackInner.runtime.getHiLogInterceptor().init();
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
  getDataHelper(): FTTrackDataHelper {
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
  appendLogGlobalContext(globalContext: Map<string, string>): void {
    this.dataHelper.appendLogGlobalContext(globalContext);
  }

  /**
   * Add log global context key-value pair
   */
  appendLogGlobalContextKeyValue(key: string, value: string): void {
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
    collectTypeParam: CollectType = CollectType.ALL
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

    if (!sessionId) {
      // If no session ID, collect by default
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack);
      return;
    }

    // Check session collection type (aligned with Android)
    const collectType = FTTrackInner.runtime.getRumManager().checkSessionWillCollect(sessionId);

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
   * Log data tracking - single log
   */
  trackLogAsync(bean: object | undefined, callback: FTTrackLogCallback): void {
    if (bean) {
      this.syncDataBackgroundForLog(bean, callback);
    } else {
      callback.onResponse(400, "Invalid bean parameter", "INVALID_PARAM");
    }
  }

  /**
   * Log data tracking - processed through TrackLogManager
   */
  trackLog(logBean: LogBean, isSilence: boolean = false): void {
    try {
      this.trackLogManager.trackLog(logBean, isSilence);
      FTInnerLogger.d(TAG, `Log tracked successfully: ${logBean.getDescription()}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error tracking log: ${error}`);
    }
  }

  /**
   * Batch log data tracking
   */
  trackLogBatch(logBeans: LogBean[], isSilence: boolean = false): void {
    try {
      this.trackLogManager.trackLogBatch(logBeans, isSilence);
      FTInnerLogger.d(TAG, `Batch logs tracked: ${logBeans.length} logs`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error tracking log batch: ${error}`);
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
      // Convert LogBean to database format and batch process
      const promises: Promise<boolean>[] = [];

      for (const logBean of batchData) {
        if (logBean instanceof LogBean) {

          const promise = this.processLogBeanToDatabase(logBean, isSilence);
          promises.push(promise);
        }
      }


      this.handleBatchLogPromises(promises, batchData.length, isSilence);

    } catch (error) {
      FTInnerLogger.e(TAG, `Error in batchLogBeanSync: ${error}`);
    }
  }

  private async handleBatchLogPromises(promises: Promise<boolean>[], totalCount: number, isSilence: boolean): Promise<void> {
    try {
      const results = await Promise.all(promises);
      let successCount = 0;
      for (let i = 0; i < results.length; i++) {
        if (results[i]) {
          successCount++;
        }
      }
      FTInnerLogger.d(TAG, `Batch log processing completed: ${successCount}/${totalCount} successful`);

      if (successCount > 0 && !isSilence) {
        this.syncTaskManager.executeSyncPoll();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Batch log processing failed: ${error}`);
    }
  }

  /**
   * Process single LogBean to database
   */
  private async processLogBeanToDatabase(logBean: LogBean, isSilence: boolean): Promise<boolean> {
    try {
      // Create SyncData
      const recordData = await this.createSyncDataFromLogBean(logBean);

      // Check cache policy before inserting (aligned with Android: optLogCachePolicy)
      let result = false;

      if (this.context) {
        const cachePolicy = FTTrackInner.runtime.getCachePolicy();
        const status = await cachePolicy.optLogCachePolicy(this.context, 1);

        // Insert data based on cache policy result (aligned with Android)
        // -1: discard, 0: can insert, 1: delete old data and insert
        if (status >= 0) {
          const dbManager = FTTrackInner.runtime.getDbManager(this.context);
          if (dbManager) {
            // Ensure database manager is initialized

            await dbManager.init();

            result = await dbManager.insertFtOperation(recordData, false);

            // Update count after successful insert (aligned with Android)
            if (result) {
              cachePolicy.optLogCount(1);
            }
          } else {
            FTInnerLogger.e(TAG, `Database manager is null`);
          }
        } else {
          // Discard data (status < 0)
          FTInnerLogger.e(TAG, `processLogBeanToDatabase: drop by Cache limit (status=${status})`);
        }
      } else {
        FTInnerLogger.e(TAG, `Context is null`);
      }

      if (result) {
      } else {
        FTInnerLogger.w(TAG, `Failed to process LogBean: ${logBean.getDescription()}`);
      }

      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error processing LogBean to database: ${error}`);
      return false;
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
    // Use the same logic as syncDataBackground, but with custom dataTypeForStorage

    // Use DataProcessThreadPool instead of setTimeout
    try {
      FTTrackInner.runtime.getDataProcessThreadPool().execute(async () => {
        try {
          // Create sync data record using dataTypeForContent for getBodyContent
          const syncDataParams: SyncDataParams = {
            measurement,
            tags,
            fields,
            time
          };

          const recordData = await this.createSyncData(
            this.dataHelper,
            dataTypeForContent,
            syncDataParams
          );

          // Set custom dataType string for error_sampled type
          recordData.setCustomDataTypeString(dataTypeForStorage);

          // Check cache policy before inserting
          let result = false;
          let status = 0;
          if (this.context) {
            const cachePolicy = FTTrackInner.runtime.getCachePolicy();

            // Check cache policy for RUM data (use dataTypeForContent for policy check)
            if (dataTypeForContent === DataType.RUM_APP || dataTypeForContent === DataType.RUM_WEBVIEW) {
              status = await cachePolicy.optRUMCachePolicy(this.context, 1);
            } else if (dataTypeForContent === DataType.LOG) {
              status = await cachePolicy.optLogCachePolicy(this.context, 1);
            }

            // Insert data based on cache policy result
            if (status >= 0) {
              const dbManager = FTTrackInner.runtime.getDbManager(this.context);
              if (dbManager) {
                // Insert with custom dataType string (insertFtOperation will use getCustomDataTypeString if available)
                result = await dbManager.insertFtOperation(recordData);
              } else {
                FTInnerLogger.e(TAG, `Database manager is null`);
              }

              // Update count after successful insert
              if (result) {
                // Log successful insertion of error sampled data
                FTInnerLogger.d(TAG,
                  `[FT-ERROR-SAMPLING] Successfully stored data as ${dataTypeForStorage}: uuid=${recordData.getUuid()}, measurement=${measurement}, time=${time}`);

                if (dataTypeForContent === DataType.RUM_APP || dataTypeForContent === DataType.RUM_WEBVIEW) {
                  cachePolicy.optRumCount(1);
                } else if (dataTypeForContent === DataType.LOG) {
                  cachePolicy.optLogCount(1);
                }
              }
            } else {
              FTInnerLogger.e(TAG,
                `syncDataBackgroundWithErrorSampled: ${measurement} ${dataTypeForStorage}, uuid: ${recordData.getUuid()}, drop by Cache limit (status=${status})`);
            }
          } else {
            FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Context not available for cache policy check`);
          }

          // Trigger sync if needed
          if (result && this.syncTaskManager) {
            this.syncTaskManager.executeSyncPoll();
          }

          // Call callback if provided
          if (callBack) {
            callBack.onComplete();
          }
        } catch (error) {
          FTInnerLogger.e(TAG, `syncDataBackgroundWithErrorSampled failed: ${error}`);
          if (callBack) {
            callBack.onComplete();
          }
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling syncDataBackgroundWithErrorSampled task: ${error}`);
      if (callBack) {
        callBack.onComplete();
      }
    }
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

    // Use DataProcessThreadPool instead of setTimeout
    try {
      FTTrackInner.runtime.getDataProcessThreadPool().execute(async () => {
        try {
          // Create sync data record
          const syncDataParams: SyncDataParams = {
            measurement,
            tags,
            fields,
            time
          };

          const recordData = await this.createSyncData(
            this.dataHelper,
            dataType,
            syncDataParams
          );

          // const dataString = recordData.getDataString();
          // if (dataString && dataString.length > 0) {
          //   // Use unified format: SyncData DataString: for all RUM data types (action, view, resource)
          //   // This makes it easier to filter line protocol data from logs
          //   FTInnerLogger.d(TAG, `[FT-LOG-DEBUG] SyncData DataString: ${dataString}`);
          // }

          // Check cache policy before inserting (aligned with Android: optRUMCachePolicy)
          let result = false;
          let status = 0; // Initialize status outside if block
          if (this.context) {
            const cachePolicy = FTTrackInner.runtime.getCachePolicy();

            // Check cache policy for RUM data (aligned with Android)
            if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
              status = await cachePolicy.optRUMCachePolicy(this.context, 1);
            } else if (dataType === DataType.LOG) {
              status = await cachePolicy.optLogCachePolicy(this.context, 1);
            }

            // Insert data based on cache policy result (aligned with Android)
            // -1: discard, 0: can insert, 1: delete old data and insert
            if (status >= 0) {
              const dbManager = FTTrackInner.runtime.getDbManager(this.context);
              // Don't call init() here - insertFtOperation handles initialization internally
              // This avoids concurrent initialization conflicts when multiple actions occur rapidly
              try {
                if (dbManager) {
                  result = await dbManager.insertFtOperation(recordData);
                } else {
                  FTInnerLogger.e(TAG, `Database manager is null`);
                }

                // Update count after successful insert (aligned with Android)
                if (result) {
                  if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
                    cachePolicy.optRumCount(1);
                  } else if (dataType === DataType.LOG) {
                    cachePolicy.optLogCount(1);
                  }
                }
              } catch (error) {
                FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Database insert failed with error: ${error}`);
                result = false;
              }
            } else {
              // Discard data (status < 0)
              FTInnerLogger.e(TAG,
                `syncDataBackground: ${measurement} ${dataType}, uuid: ${recordData.getUuid()}, drop by Cache limit (status=${status})`);
            }
          } else {
            FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Context not available for cache policy check`);
          }

          if (result && callBack) {
            callBack.onComplete();
          }

          if (result) {
            this.syncTaskManager.executeSyncPoll();
          }

        } catch (error) {
          FTInnerLogger.e(TAG, `syncDataBackground failed: ${error}`);
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling syncDataBackground task: ${error}`);
    }
  }

  /**
   * Log data async processing (background)
   */
  private syncDataBackgroundForLog(bean: object | undefined,
    callback: FTTrackLogCallback): void {
    // Use DataProcessThreadPool instead of setTimeout
    FTTrackInner.runtime.getDataProcessThreadPool().execute(async () => {
      try {
        if (!bean) {
          callback.onResponse(NetCodeStatus.UNKNOWN_EXCEPTION_CODE, "Bean is undefined", "");
          return;
        }
        // Create sync data from log Bean
        const recordData = await this.createSyncDataFromObject(bean);

        // Check cache policy before inserting (aligned with Android: optLogCachePolicy)
        let result = false;
        if (this.context) {
          const cachePolicy = FTTrackInner.runtime.getCachePolicy();
          const status = await cachePolicy.optLogCachePolicy(this.context, 1);

          // Insert data based on cache policy result (aligned with Android)
          // -1: discard, 0: can insert, 1: delete old data and insert
          if (status >= 0) {
            const dbManager = FTTrackInner.runtime.getDbManager(this.context);
            if (dbManager) {
              await dbManager.init();
              result = await dbManager.insertFtOperation(recordData);
            } else {
              FTInnerLogger.e(TAG, `Database manager is null`);
            }

            // Update count after successful insert (aligned with Android)
            if (result) {
              cachePolicy.optLogCount(1);
            }
          } else {
            // Discard data (status < 0)
            FTInnerLogger.e(TAG, `syncDataBackgroundForLog: drop by Cache limit (status=${status})`);
          }
        }

        if (result) {
          // Trigger data sync
          this.syncTaskManager.executeSyncPoll();
          callback.onResponse(200, "Log data inserted successfully", "");
        } else {
          callback.onResponse(500, "Failed to insert log data", "INSERT_ERROR");
        }

      } catch (error) {
        FTInnerLogger.e(TAG, `syncDataBackgroundForLog failed: ${error}`);
        callback.onResponse(500, `Error: ${error.message}`, "EXCEPTION");
      }
    });
  }

  /**
   * Create sync data record from LogBean
   */
  private async createSyncDataFromLogBean(logBean: LogBean): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = FTTrackInner.runtime.generateUUID();

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

      const dataString = this.dataHelper.getBodyContent(
        finalMeasurement, // Use LogBean's measurement (e.g., Constants.FT_LOG_DEFAULT_MEASUREMENT)
        tags,
        fields,
        logBean.getTimeNano(), // Use nanoseconds for line protocol
        DataType.LOG,
        uuid
      );

      // Create SyncData
      const syncData = new SyncData(DataType.LOG);
      syncData.setUuid(uuid);
      syncData.setTime(logBean.getTimeNano()); // Use nanoseconds
      syncData.setDataString(dataString);


      return syncData;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error creating SyncData from LogBean: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Create sync data record
   */
  private async createSyncData(
    dataHelper: FTTrackDataHelper,
    dataType: DataType,
    data: SyncDataParams
  ): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = FTTrackInner.runtime.generateUUID();

      // Get data content
      const dataString = dataHelper.getBodyContent(
        data.measurement,
        data.tags,
        data.fields,
        data.time,
        dataType,
        uuid
      );

      // Create SyncData object
      const syncData = new SyncData(dataType);
      syncData.setId(this.generateId());
      syncData.setUuid(uuid);
      syncData.setDataString(dataString);
      syncData.setTime(data.time);

      return syncData;

    } catch (error) {
      FTInnerLogger.e(TAG, `createSyncData failed: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Create sync data from object (for backward compatibility)
   */
  private async createSyncDataFromObject(bean: object): Promise<SyncData> {
    try {
      // This should parse based on actual log Bean structure
      // Using simplified implementation for now
      const uuid = FTTrackInner.runtime.generateUUID();
      const dataString = JSON.stringify(bean);

      const syncData = new SyncData(DataType.LOG);
      syncData.setId(this.generateId());
      syncData.setUuid(uuid);
      syncData.setDataString(dataString);
      // Aligned with Android SDK: use nanoseconds (19 digits) for Line Protocol timestamp
      syncData.setTime(FTTrackInner.runtime.getCurrentNanoTime());

      return syncData;

    } catch (error) {
      FTInnerLogger.e(TAG, `createSyncDataFromObject failed: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Generate ID
   */
  private generateId(): number {
    return FTTrackInner.runtime.nowMillis() + Math.floor(FTTrackInner.runtime.random() * 1000);
  }

  async createSyncDataFromLogBeanForTest(logBean: LogBean): Promise<SyncData> {
    return await this.createSyncDataFromLogBean(logBean);
  }

  async createSyncDataForTest(
    dataType: DataType,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>
  ): Promise<SyncData> {
    return await this.createSyncData(this.dataHelper, dataType, {
      measurement,
      tags,
      fields,
      time
    });
  }

  async createSyncDataFromObjectForTest(bean: object): Promise<SyncData> {
    return await this.createSyncDataFromObject(bean);
  }

  generateIdForTest(): number {
    return this.generateId();
  }

  generateLineProtocolForTest(
    measurement: string,
    tags: Record<string, string>,
    fields: Record<string, string>,
    time: number
  ): string {
    return this.generateLineProtocol(measurement, tags, fields, time);
  }

  async createSyncDataFromLineProtocolForTest(
    measurement: string,
    lineProtocol: string,
    time: number,
    dataType: DataType
  ): Promise<SyncData> {
    return await this.createSyncDataFromLineProtocol(measurement, lineProtocol, time, dataType);
  }

  async processLogBeanToDatabaseForTest(logBean: LogBean, isSilence: boolean): Promise<boolean> {
    return await this.processLogBeanToDatabase(logBean, isSilence);
  }

  async handleBatchLogPromisesForTest(promises: Promise<boolean>[], totalCount: number, isSilence: boolean): Promise<void> {
    await this.handleBatchLogPromises(promises, totalCount, isSilence);
  }

  syncDataBackgroundForTest(
    dataType: DataType,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    this.syncDataBackground(dataType, time, measurement, tags, fields, callBack);
  }

  syncDataBackgroundWithErrorSampledForTest(
    dataTypeForContent: DataType,
    dataTypeForStorage: string,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    this.syncDataBackgroundWithErrorSampled(dataTypeForContent, dataTypeForStorage, time, measurement, tags, fields,
      callBack);
  }

  syncDataBackgroundForLogForTest(
    bean: object | undefined,
    callback: FTTrackLogCallback
  ): void {
    this.syncDataBackgroundForLog(bean, callback);
  }

  /**
   * Get sync task manager
   */
  getSyncTaskManager(): FTTrackSyncTaskManager {
    return this.syncTaskManager;
  }

  /**
   * Get log tracking manager
   */
  getTrackLogManager(): FTTrackLogManager {
    return this.trackLogManager;
  }

  /**
   * Get SDK configuration
   */
  getSdkConfig(): FTSDKConfig | null {
    return this.sdkConfig;
  }

  /**
   * Force refresh log buffer
   */
  forceFlushLogs(isSilence: boolean = false): void {
    this.trackLogManager.forceFlush(isSilence);
  }

  /**
   * Get log queue status
   */
  getLogQueueStatus(): QueueStatus {
    return this.trackLogManager.getQueueStatus();
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
   * Generate Line Protocol string
   */
  private generateLineProtocol(measurement: string, tags: Record<string, string>, fields: Record<string, string>,
    time: number): string {
    let line = measurement;

    // Add tags
    const tagKeys = Object.keys(tags);
    if (tagKeys.length > 0) {
      line += ",";
      for (let i = 0; i < tagKeys.length; i++) {
        const key = tagKeys[i];
        const value = tags[key];
        line += `${key}=${value}`;
        if (i < tagKeys.length - 1) {
          line += ",";
        }
      }
    }

    // Add space separator
    line += " ";

    // Add fields
    const fieldKeys = Object.keys(fields);
    if (fieldKeys.length > 0) {
      for (let i = 0; i < fieldKeys.length; i++) {
        const key = fieldKeys[i];
        const value = fields[key];
        line += `${key}=${value}`;
        if (i < fieldKeys.length - 1) {
          line += ",";
        }
      }
    }

    // Add timestamp
    line += ` ${time}`;

    return line;
  }

  /**
   * Create SyncData from Line Protocol string
   */
  private async createSyncDataFromLineProtocol(
    measurement: string,
    lineProtocol: string,
    time: number,
    dataType: DataType
  ): Promise<SyncData> {
    const syncData = new SyncData(dataType);
    syncData.setDataString(lineProtocol);
    syncData.setTime(time);
    syncData.setUuid(FTTrackInner.runtime.generateUUID());

    // Store in database
    if (this.context) {
      const dbManager = FTTrackInner.runtime.getDbManager(this.context);
      if (dbManager) {
        await dbManager.init();
        await dbManager.insertFtOperation(syncData);
      }
    }

    return syncData;
  }

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
