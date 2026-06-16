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
import { SyncDataHelper } from './SyncDataHelper';
import { SyncTaskManager } from './SyncTaskManager';
import { FTHiLogInterceptor } from './log/FTHiLogInterceptor';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import {
  SDKTaskPriority,
  SDKTaskRunner,
  SDKTaskScheduler,
  SDKTaskType
} from './thread/SDKTaskScheduler';
import { Utils } from './utils/Utils';
import { FTDBCachePolicy } from './db/FTDBCachePolicy';
import { FTDBManager } from './db/FTDBManager';
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

interface FTTrackValueAccessor {
  getValue(): string;
}

/**
 * Data Tracking Core Class
 * Responsible for data collection, storage, and sync triggering
 */
class FTTrackInner {
  private static instance: FTTrackInner | null = null;
  private static dataProcessTaskSequence: number = 0;
  private dataHelper: SyncDataHelper;
  private syncTaskManager: SyncTaskManager;
  private trackLogManager: TrackLogManager;
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
    SDKTaskScheduler.getInstance().submitTask({
      type: SDKTaskType.DATA_PROCESS,
      name: traceName,
      priority: SDKTaskPriority.LOW,
      costHint: 'normal',
      run: async () => {
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
      }
    });
  }

  private nextDataProcessTaskName(name: string): string {
    FTTrackInner.dataProcessTaskSequence++;
    return `${name}#${FTTrackInner.dataProcessTaskSequence}`;
  }

  private traceDataLane(message: string): void {
    FTInnerLogger.i(TAG, `<FT-DATA-LANE> ${message}`);
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
        // Convert LogBean to database format and batch process
        const promises: Promise<boolean>[] = [];

        for (const logBean of batchData) {
          if (logBean instanceof LogBean) {
            const promise = this.processLogBeanToDatabase(logBean, isSilence);
            promises.push(promise);
          }
        }

        await this.handleBatchLogPromises(promises, batchData.length, isSilence);
      });

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
        const cachePolicy = FTDBCachePolicy.getInstance();
        const status = await cachePolicy.optLogCachePolicy(this.context, 1);

        // Insert data based on cache policy result (aligned with Android)
        // -1: discard, 0: can insert, 1: delete old data and insert
        if (status >= 0) {
          const dbManager = FTDBManager.getInstance(this.context);
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

    try {
      this.submitDataProcessTask('data.prepare.errorSampled', async () => {
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
            const cachePolicy = FTDBCachePolicy.getInstance();

            // Check cache policy for RUM data (use dataTypeForContent for policy check)
            if (dataTypeForContent === DataType.RUM_APP || dataTypeForContent === DataType.RUM_WEBVIEW) {
              status = await cachePolicy.optRUMCachePolicy(this.context, 1);
            } else if (dataTypeForContent === DataType.LOG) {
              status = await cachePolicy.optLogCachePolicy(this.context, 1);
            }

            // Insert data based on cache policy result
            if (status >= 0) {
              const dbManager = FTDBManager.getInstance(this.context);
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

    try {
      this.submitDataProcessTask('data.prepare', async () => {
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
            const cachePolicy = FTDBCachePolicy.getInstance();

            // Check cache policy for RUM data (aligned with Android)
            if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
              status = await cachePolicy.optRUMCachePolicy(this.context, 1);
            } else if (dataType === DataType.LOG) {
              status = await cachePolicy.optLogCachePolicy(this.context, 1);
            }

            // Insert data based on cache policy result (aligned with Android)
            // -1: discard, 0: can insert, 1: delete old data and insert
            if (status >= 0) {
              const dbManager = FTDBManager.getInstance(this.context);
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
    dataHelper: SyncDataHelper,
    dataType: DataType,
    data: SyncDataParams
  ): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = Utils.generateUUID();

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
   * Generate ID
   */
  private generateId(): number {
    return Date.now() + Math.floor(Math.random() * 1000);
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
