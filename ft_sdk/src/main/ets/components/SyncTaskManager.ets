import { FTSDKConfig } from './Configs';
import { DataType } from './enum/Enums';
import { SyncData } from './db/bean/SyncData';
import { NetCodeStatus } from './http/HttpEngine';
import { Context } from '@kit.AbilityKit';
import { DataBaseCallBack } from './db/base/DataBaseCallBack';
import relationalStore from '@ohos.data.relationalStore';
import { FTSQL } from './db/FTSQL';
import { Constants } from './Constants';
import { ViewBean } from './db/bean/ViewBean';
import { FTInnerLogger } from './log/FTLogger';
import {
  DefaultSyncTaskManagerRuntime,
  SyncTaskCachePolicy,
  SyncTaskConfigRecord,
  SyncTaskDbManager,
  SyncTaskManagerRuntime,
  SyncTaskPreferences
} from './internal/runtime/SyncTaskManagerRuntime';
import { SDKTaskPriority, SDKTaskScheduler, SDKTaskType } from './thread/SDKTaskScheduler';

/**
 * Configuration record interface for FTDBCachePolicy
 */
export interface ConfigRecord extends SyncTaskConfigRecord {
}

/**
 * Configuration record implementation for FTDBCachePolicy
 */
class ConfigRecordImpl implements ConfigRecord {
  private config: FTSDKConfig;

  constructor(config: FTSDKConfig) {
    this.config = config;
  }

  isLimitWithDbSize(): boolean {
    return this.config.isLimitWithDbSize();
  }

  getDbCacheLimit(): number {
    return this.config.getDbCacheLimit();
  }

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }
}

const TAG = "SyncTaskManager";
let syncTaskRuntime: SyncTaskManagerRuntime = new DefaultSyncTaskManagerRuntime();

/**
 * Request callback interface
 */
export interface SyncTaskRequestCallback {
  onResponse(code: number, response: string, errorCode: string): void;
}

/**
 * Request callback implementation class
 */
class RequestCallbackImpl implements SyncTaskRequestCallback {
  private callback: (code: number, response: string, errorCode: string) => void | Promise<void>;

  constructor(callback: (code: number, response: string, errorCode: string) => void | Promise<void>) {
    this.callback = callback;
  }

  onResponse(code: number, response: string, errorCode: string): void {
    const result = this.callback(code, response, errorCode);
    // If callback returns a Promise, wait for it to complete
    if (result instanceof Promise) {
      result.catch((error: Error) => {
        // Error will be handled in the callback's try-catch
      });
    }
  }
}

enum UploadBatchResult {
  DELETE_NO_BACKOFF = 'delete-no-backoff',
  DELETE_WITH_IGNORED_BACKOFF = 'delete-with-ignored-backoff',
  RETRY_BACKOFF = 'retry-backoff'
}

/**
 * Data synchronization manager
 * Responsible for querying data from database and uploading to server
 */
export class SyncTaskManager {
  public static readonly SYNC_SLEEP_MAX_TIME_MS = 5000;
  public static readonly SYNC_SLEEP_MINI_TIME_MS = 0;
  public static readonly MAX_ERROR_COUNT = 5;
  private static instance: SyncTaskManager | null = null;
  private static SLEEP_TIME = 2000; // 2 seconds - upload interval (reduced from 3s to further improve upload speed)
  private static RETRY_DELAY_SLEEP_TIME = 500; // 500ms retry delay
  private static readonly IGNORED_CLIENT_ERROR_BACKOFF_MAX_MS = 8000;
  private static readonly UPLOAD_SINGLE_FLIGHT_KEY = 'upload-poll';
  private static readonly UPLOAD_MAX_PAGES_RUM_APP = 2;
  private static readonly UPLOAD_MAX_PAGES_RUM_WEBVIEW = 1;
  private static readonly UPLOAD_MAX_PAGES_LOG = 1;
  private static readonly ONE_MINUTE_DURATION_NS = 60_000_000_000; // 60 seconds in nanoseconds
  private static readonly PREFERENCES_NAME = 'ft_sdk_sync_task';
  private static readonly KEY_ERROR_TIMELINE = 'ft.rum.error.timeline';
  private static readonly ERROR_SAMPLED_SUFFIX = "_error_sampled";
  private errorCount = 0;
  private running = false;
  private uploadRunning = false;
  private uploadScheduled = false;
  private uploadNeedReschedule = false;
  private uploadRescheduleDelay = 0;
  private uploadScheduledDelay = 0;
  private uploadScheduledAt = 0;
  private uploadScheduleTimer = -1;
  private uploadTaskSequence = 0;
  private uploadCurrentPollRows = 0;
  private uploadCurrentTaskName = "";
  private uploadStartTraced = false;
  private isStop = false;
  private autoSync = false;
  private syncSleepTime = 0;
  private pageSize = 100; // Default page size (increased from 50 to improve upload throughput)
  private dataSyncMaxRetryCount = 3; // Maximum retry count
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;
  private errorTimeLine: number = -1; // Error time line in nanoseconds
  private preferencesStore: SyncTaskPreferences | null = null;
  private uploadRunnable: (() => Promise<void>) | null = null;
  private errorCountByType: Map<DataType, number> = new Map();
  private ignoredClientErrorCountByType: Map<DataType, number> = new Map();
  // Package ID generators
  private rumGenerator = new IDGenerator();
  private logGenerator = new IDGenerator();
  // Static process ID cache (process lifetime)
  private static cachedProcessId: number | undefined = undefined;
  // Synchronization data type mapping
  private readonly SYNC_MAP = [DataType.RUM_APP, DataType.RUM_WEBVIEW, DataType.LOG];
  private readonly ERROR_SAMPLED_SYNC_MAP = [DataType.RUM_APP, DataType.RUM_WEBVIEW];
  // Set to track uploaded data unique identifiers to prevent duplicate uploads
  // Key format: "dataType:uniqueId" (e.g., "RUM_APP:action_id=xxx", "RUM_APP:view_id=xxx", "LOG:uuid=xxx")
  private uploadedDataIds: Set<string> = new Set();
  // Set to track data IDs that are currently being uploaded (to prevent concurrent duplicate uploads)
  private uploadingDataIds: Set<string> = new Set();

  // Maximum size for Set collections to prevent memory leak (using Constants.MAX_SET_SIZE_UPLOAD)

  private constructor() {
  }

  public static setRuntimeInternal(runtime: SyncTaskManagerRuntime): void {
    syncTaskRuntime = runtime;
  }

  public static resetRuntimeInternal(): void {
    syncTaskRuntime = new DefaultSyncTaskManagerRuntime();
  }

  public static resetStateInternal(): void {
    SyncTaskManager.instance = null;
    SyncTaskManager.cachedProcessId = undefined;
    RUMDataCleanupManagerInternal.resetInternal();
  }

  public static getInstance(): SyncTaskManager {
    if (!SyncTaskManager.instance) {
      SyncTaskManager.instance = new SyncTaskManager();
    }
    return SyncTaskManager.instance;
  }

  /**
   * Initialize synchronization task manager
   * @param config SDK configuration
   * @param context Optional context for features that require it (preferences, cleanup manager)
   */
  public init(config: FTSDKConfig, context?: Context): void {
    this.sdkConfig = config;

    // Update configuration values (do not require context)
    this.dataSyncMaxRetryCount = config.getDataSyncRetryCount?.() || 3;
    this.pageSize = config.getPageSize?.() || 50;
    this.autoSync = config.isAutoSyncEnabled?.() || false;
    this.syncSleepTime = config.getSyncSleepTime?.() || 0;

    // Initialize database cache policy (does not require context)
    const configRecord = new ConfigRecordImpl(config);
    syncTaskRuntime.getCachePolicy().initSDKParams(configRecord);

    // Initialize upload lane (does not require context)
    this.initUploadLane();

    // Initialize components that require context
    if (context) {
      this.context = context;

      // Initialize preferences for errorTimeLine storage
      try {
        this.preferencesStore = syncTaskRuntime.getPreferences(context, SyncTaskManager.PREFERENCES_NAME);
        this.getErrorTimeLineFromFileCache().then((number) => {
          this.errorTimeLine = number;
        });

        FTInnerLogger.d(TAG, `Loaded errorTimeLine from cache: ${this.errorTimeLine}`);
      } catch (error) {
        FTInnerLogger.e(TAG, `Failed to initialize preferences: ${error as string}`);
        this.errorTimeLine = -1;
      }

      // Initialize RUM data cleanup manager
      RUMDataCleanupManagerInternal.getInstance().init(context);

      FTInnerLogger.i(TAG, `SyncTaskManager initialized with context: pageSize=${this.pageSize}, autoSync=${this.autoSync}`);
    } else {
      FTInnerLogger.w(TAG, `SyncTaskManager initialized without context (test mode): pageSize=${this.pageSize}, autoSync=${this.autoSync}`);
    }
  }

  /**
   * Initialize upload lane runnable.
   */
  private initUploadLane(): void {
    this.uploadRunnable = async () => {
      if (this.isStop) {
        return;
      }

      try {
        // Process error sampled data
        for (const dataType of this.ERROR_SAMPLED_SYNC_MAP) {
          await this.errorSampledConsume(dataType);
        }

        // Process normal sync data
        let hasMoreData = false;
        for (const dataType of this.SYNC_MAP) {
          hasMoreData = (await this.handleSyncOpt(dataType)) || hasMoreData;
        }

        if (hasMoreData && !this.isStop) {
          this.scheduleUpload(0);
        }
      } catch (e) {
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${e as string}`);
      } finally {
        this.running = false;
      }
    };
  }

  private scheduleUpload(delay: number = 0): void {
    if (!this.uploadRunnable) {
      FTInnerLogger.w(TAG, `<FT-UPLOAD-LANE> [SKIP] runnable=none`);
      return;
    }
    if (this.isStop) {
      return;
    }

    const normalizedDelay = Math.max(0, delay);
    if (this.uploadScheduled && !this.uploadRunning) {
      const elapsed = Math.max(0, syncTaskRuntime.getCurrentTimeMs() - this.uploadScheduledAt);
      const remainingDelay = Math.max(0, this.uploadScheduledDelay - elapsed);
      if (normalizedDelay < remainingDelay) {
        this.clearUploadScheduleTimer();
        this.uploadScheduled = false;
        this.uploadScheduledAt = 0;
        this.uploadScheduledDelay = 0;
        this.traceUploadLaneDebug(`[RESCHEDULE] replaceScheduled oldRemaining=${remainingDelay}ms newDelay=${normalizedDelay}ms`);
        this.scheduleUpload(normalizedDelay);
      }
      return;
    }

    if (this.uploadRunning || this.uploadScheduled) {
      if (this.uploadNeedReschedule) {
        this.uploadRescheduleDelay = Math.min(this.uploadRescheduleDelay, normalizedDelay);
      } else {
        this.uploadRescheduleDelay = normalizedDelay;
      }
      this.uploadNeedReschedule = true;
      this.traceUploadLaneDebug(
        `[RESCHEDULE] delay=${normalizedDelay}ms nextDelay=${this.uploadRescheduleDelay}ms running=${this.uploadRunning} scheduled=${this.uploadScheduled}`
      );
      return;
    }

    this.uploadScheduled = true;
    this.uploadScheduledDelay = normalizedDelay;
    this.uploadScheduledAt = syncTaskRuntime.getCurrentTimeMs();
    this.traceUploadLaneDebug(`[SCHEDULE] delay=${normalizedDelay}ms running=${this.uploadRunning} scheduled=${this.uploadScheduled}`);

    if (normalizedDelay > 0) {
      this.clearUploadScheduleTimer();
      this.uploadScheduleTimer = setTimeout(() => {
        this.uploadScheduleTimer = -1;
        this.executeScheduledUpload();
      }, normalizedDelay);
    } else {
      this.executeScheduledUpload();
    }
  }

  private executeScheduledUpload(): void {
    if (!this.uploadRunnable || this.isStop) {
      this.uploadScheduled = false;
      this.uploadScheduledAt = 0;
      this.uploadScheduledDelay = 0;
      return;
    }

    if (this.uploadRunning) {
      this.scheduleUpload(0);
      return;
    }

    this.uploadScheduled = false;
    this.uploadScheduledAt = 0;
    this.uploadScheduledDelay = 0;
    this.uploadRunning = true;
    this.running = true;

    const taskName = this.nextUploadTaskName();
    this.uploadCurrentPollRows = 0;
    this.uploadCurrentTaskName = taskName;
    this.uploadStartTraced = false;

    try {
      SDKTaskScheduler.getInstance().submitTask({
        type: SDKTaskType.UPLOAD,
        name: taskName,
        priority: SDKTaskPriority.LOW,
        singleFlightKey: SyncTaskManager.UPLOAD_SINGLE_FLIGHT_KEY,
        costHint: 'normal',
        run: async () => {
          const startTime = syncTaskRuntime.getCurrentTimeMs();
          let result = 'success';
          let errorMessage = '';
          try {
            await Promise.resolve(this.uploadRunnable!());
          } catch (error) {
            result = 'failed';
            errorMessage = String(error);
            throw new Error(errorMessage);
          } finally {
            const costTime = Math.max(0, syncTaskRuntime.getCurrentTimeMs() - startTime);
            const shouldReschedule = this.uploadNeedReschedule;
            const nextDelay = this.uploadRescheduleDelay;
            this.uploadRunning = false;
            this.running = false;
            this.uploadNeedReschedule = false;
            this.uploadRescheduleDelay = 0;
            const errorPart = errorMessage.length > 0 ? ` error=${errorMessage}` : '';
            const uploadedRows = this.uploadCurrentPollRows;
            this.uploadCurrentPollRows = 0;
            this.uploadCurrentTaskName = "";
            this.uploadStartTraced = false;
            if (result !== 'success' || uploadedRows > 0 || shouldReschedule) {
              this.traceUploadLaneDebug(
                `[CONSUMED] name=${taskName} result=${result}${errorPart} rows=${uploadedRows} cost=${costTime}ms needReschedule=${shouldReschedule} nextDelay=${nextDelay}ms`
              );
            }
            if (shouldReschedule && !this.isStop) {
              this.scheduleUpload(nextDelay);
            }
          }
        }
      });
    } catch (error) {
      this.uploadRunning = false;
      this.running = false;
      this.uploadScheduled = false;
      this.uploadCurrentPollRows = 0;
      this.uploadCurrentTaskName = "";
      this.uploadStartTraced = false;
      FTInnerLogger.e(TAG, `<FT-UPLOAD-LANE> [FAILED] schedule name=${taskName} error=${error as string}`);
    }
  }

  /**
   * Execute data synchronization polling
   * Ensures only one upload task runs at a time to prevent concurrent duplicate uploads
   */
  public executePoll(withSleep: boolean = false): void {
    if (this.isStop) {
      return;
    }

    this.scheduleUpload(withSleep ? SyncTaskManager.SLEEP_TIME : 0);
  }

  /**
   * Trigger polling synchronization
   * Auto sync only submits upload work when stored data is available.
   */
  public executeSyncPoll(): void {

    if (this.autoSync && !this.isStop) {
      this.executePollIfDataAvailable();
    }
  }

  private executePollIfDataAvailable(): void {
    this.hasUploadTriggerData().then((hasData: boolean) => {
      if (this.isStop || !this.autoSync) {
        return;
      }
      if (hasData) {
        this.executePoll(false);
      } else {
        this.traceUploadLaneDebug(`[SKIP] reason=no-data`);
      }
    }).catch((error: Error) => {
      FTInnerLogger.e(TAG, `<FT-UPLOAD-LANE> [SKIP] check data failed: ${error}`);
    });
  }

  private async hasUploadTriggerData(): Promise<boolean> {
    if (!this.context) {
      return false;
    }

    const dbManager = syncTaskRuntime.getDbManager(this.context);
    if (!dbManager) {
      return false;
    }

    const dataTypes = this.getUploadTriggerDataTypes();
    class HasUploadDataCallback implements DataBaseCallBack {
      hasData: boolean = false;
      private dataTypes: string[];

      constructor(dataTypes: string[]) {
        this.dataTypes = dataTypes;
      }

      async run(rdbStore: relationalStore.RdbStore): Promise<void> {
        const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
        predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, this.dataTypes);
        const resultSet = await rdbStore.query(predicates);
        try {
          this.hasData = resultSet.goToNextRow();
        } finally {
          resultSet.close();
        }
      }
    }

    const callback = new HasUploadDataCallback(dataTypes);
    await dbManager.executeWithDB(false, callback);
    return callback.hasData;
  }

  private getUploadTriggerDataTypes(): string[] {
    const dataTypes: string[] = [];
    for (const dataType of this.SYNC_MAP) {
      dataTypes.push(dataType.toString());
    }
    for (const dataType of this.ERROR_SAMPLED_SYNC_MAP) {
      dataTypes.push(dataType.toString() + SyncTaskManager.ERROR_SAMPLED_SUFFIX);
    }
    return dataTypes;
  }

  /**
   * Process error sampled data consumption
   * Matches Android SDK behavior: updates error sampled data type and deletes expired cache
   */
  private async errorSampledConsume(dataType: DataType): Promise<void> {
    try {
      if (!this.context) {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> errorSampledConsume: context not available, skipping`);
        return;
      }

      const dbManager = syncTaskRuntime.getDbManager(this.context);
      if (!dbManager) {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> errorSampledConsume: database manager not available, skipping`);
        return;
      }

      // Create error sampled data type string (e.g., "rum_app_error_sampled")
      // This matches Android's behavior where error sampled data is stored with _error_sampled suffix
      const errorSampledType = dataType.toString() + SyncTaskManager.ERROR_SAMPLED_SUFFIX;

      // Update data type if errorTimeLine is set
      if (this.errorTimeLine > 0) {
        // Convert error sampled data type back to normal type for records before errorTimeLine
        const updateCount = await dbManager.updateDataType(errorSampledType, this.errorTimeLine);
        if (updateCount > 0) {
          // Removed verbose debug log to reduce log output
        }
      }

      // Delete expired error sampled cache (older than 1 minute)
      const now = this.getCurrentNanoTime();
      const deleteCount =
        await dbManager.deleteExpireCache(errorSampledType, now, SyncTaskManager.ONE_MINUTE_DURATION_NS);
      if (deleteCount > 0) {
        // Removed verbose debug log to reduce log output
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> errorSampledConsume failed: ${dataType}, error: ${error as string}`);
    }
  }

  /**
   * Set error time line
   * Called when an error occurs to mark the timestamp
   * Aligned with Android: SyncTaskManager.setErrorTimeLine(long errorTimeLine, ViewBean activeView)
   * @param errorTimeLine Error time line in nanoseconds
   * @param activeView Active view bean (optional, for setting lastErrorTime)
   */
  public setErrorTimeLine(errorTimeLine: number, activeView?: ViewBean | null): void {
    if (errorTimeLine > this.errorTimeLine) {
      this.errorTimeLine = errorTimeLine;
      // Set lastErrorTime on activeView if provided - aligned with Android
      if (activeView != null) {
        activeView.setLastErrorTime(errorTimeLine);
      }
      this.saveErrorWithFileCache(errorTimeLine);
    }
  }

  /**
   * Save error time line to preferences
   * @param errorTimeLine Error time line in nanoseconds
   */
  private async saveErrorWithFileCache(errorTimeLine: number): Promise<void> {
    try {
      if (this.preferencesStore) {
        await this.preferencesStore.put(SyncTaskManager.KEY_ERROR_TIMELINE, errorTimeLine);
        await this.preferencesStore.flush();
        FTInnerLogger.d(TAG, `Saved errorTimeLine to cache: ${errorTimeLine}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to save errorTimeLine to cache: ${error as string}`);
    }
  }

  /**
   * Get error time line from preferences cache
   * @returns Error time line in nanoseconds, or -1 if not set
   */
  private async getErrorTimeLineFromFileCache(): Promise<number> {
    try {
      if (this.preferencesStore) {
        const value = await this.preferencesStore.get(SyncTaskManager.KEY_ERROR_TIMELINE, -1);
        return typeof value === 'number' ? value : -1;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get errorTimeLine from cache: ${error as string}`);
    }
    return -1;
  }

  /**
   * Get error time line (public method for testing)
   * Returns the current error time line in nanoseconds, or -1 if not set
   * @returns Error time line in nanoseconds, or -1 if not set
   */
  public async getErrorTimeLine(): Promise<number> {
    // First check in-memory value
    if (this.errorTimeLine > 0) {
      return this.errorTimeLine;
    }
    // Then check preferences cache
    return await this.getErrorTimeLineFromFileCache();
  }

  /**
   * Get current time in nanoseconds
   * HarmonyOS equivalent of Android's Utils.getCurrentNanoTime()
   * @returns Current time in nanoseconds
   */
  private getCurrentNanoTime(): number {
    // Use Date.now() which returns milliseconds since epoch
    // Convert to nanoseconds (multiply by 1,000,000)
    // Note: HarmonyOS ArkTS may not have performance.now(), so use Date.now() instead
    return syncTaskRuntime.getCurrentTimeMs() * 1_000_000;
  }

  /**
   * Process data synchronization operations
   */
  private async handleSyncOpt(dataType: DataType): Promise<boolean> {
    if (!this.context) {
      return false;
    }
    const dbManager = syncTaskRuntime.getDbManager(this.context);
    if (!dbManager) {
      return false;
    }
    const hasData = await dbManager.hasData([dataType]);
    if (!hasData) {
      return false;
    }

    const maxPages = this.getUploadMaxPages(dataType);
    let processedPages = 0;
    let lastQueryWasFull = false;
    let shouldReschedule = false;

    while (processedPages < maxPages) {
      const cacheDataList = await this.queryFromData(dataType);
      lastQueryWasFull = cacheDataList.length >= this.pageSize;

      const deduplicatedDataList = this.deduplicateData(dataType, cacheDataList);
      if (deduplicatedDataList.length === 0) {
        break;
      }

      if (deduplicatedDataList.length < cacheDataList.length) {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> Deduplication filtered out ${cacheDataList.length -
        deduplicatedDataList.length} duplicate record(s) for ${dataType}`);
      }

      const cachePolicy = syncTaskRuntime.getCachePolicy();
      if (cachePolicy.shouldDiscardData(dataType)) {
        FTInnerLogger.w(TAG, `<FT-UPLOAD-LANE> [SKIP] type=${dataType} reason=cache-limit`);
        break;
      }

      const seqNumber = this.getSeqNumber(dataType);
      const pkgId = this.generatePackageId(seqNumber, deduplicatedDataList.length);
      const body = this.formatLineProtocolData(deduplicatedDataList, pkgId);
      if (body.trim().length === 0) {
        await this.deleteLastQuery(deduplicatedDataList);
        this.reduceCacheCount(dataType, deduplicatedDataList.length);
        processedPages++;
        this.traceUploadLaneDebug(`[SKIP] type=${dataType} rows=${deduplicatedDataList.length} reason=empty-body`);
        if (cacheDataList.length < this.pageSize) {
          break;
        }
        continue;
      }

      this.traceUploadStartIfNeeded(dataType, deduplicatedDataList.length);
      this.uploadCurrentPollRows += deduplicatedDataList.length;
      this.markDataAsUploading(dataType, deduplicatedDataList);

      try {
        this.printUploadData(body);
        const result = await this.uploadBatch(dataType, pkgId, body, deduplicatedDataList);
        processedPages++;

        if (result === UploadBatchResult.RETRY_BACKOFF ||
          result === UploadBatchResult.DELETE_WITH_IGNORED_BACKOFF) {
          shouldReschedule = result === UploadBatchResult.RETRY_BACKOFF;
          break;
        }

        if (cacheDataList.length < this.pageSize) {
          break;
        }
        if (this.syncSleepTime > 0 && processedPages < maxPages) {
          await this.sleep(this.syncSleepTime);
        }
      } catch (error) {
        this.unmarkDataAsUploading(dataType, deduplicatedDataList);
        const retryCount = this.incrementErrorCount(dataType);
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${dataType}, error: ${error as string}`);

        const delayTime = this.getNormalBackoffMs(retryCount);
        await this.sleep(delayTime);
        break;
      }
    }

    if (processedPages >= maxPages && lastQueryWasFull) {
      return await dbManager.hasData([dataType]);
    }
    return shouldReschedule;
  }

  private async uploadBatch(
    dataType: DataType,
    pkgId: string,
    body: string,
    dataList: SyncData[]
  ): Promise<UploadBatchResult> {
    let batchResult = UploadBatchResult.RETRY_BACKOFF;
    await new Promise<void>((resolve, reject) => {
      this.requestNet(dataType, pkgId, body,
        new RequestCallbackImpl(async (code: number, response: string, errorCode: string) => {
          try {
            batchResult = await this.handleUploadResponse(dataType, pkgId, code, response, errorCode, dataList);
            resolve();
          } catch (error) {
            reject(error);
          }
        }));
    });
    return batchResult;
  }

  private async handleUploadResponse(
    dataType: DataType,
    pkgId: string,
    code: number,
    response: string,
    errorCode: string,
    dataList: SyncData[]
  ): Promise<UploadBatchResult> {
    if (this.isIgnoredClientError(code)) {
      this.markDataAsUploaded(dataType, dataList);
      await this.deleteLastQuery(dataList);
      this.reduceCacheCount(dataType, dataList.length);
      this.resetErrorCount(dataType);
      const ignoredCount = this.incrementIgnoredClientErrorCount(dataType);
      const delayTime = this.getIgnoredClientBackoffMs(ignoredCount);
      this.traceUploadLane(
        `[BATCH] type=${dataType} code=${code} rows=${dataList.length} action=delete ignoredBackoff=${delayTime}ms ignoredCount=${ignoredCount} pkg=${pkgId}`
      );
      await this.sleep(delayTime);
      return UploadBatchResult.DELETE_WITH_IGNORED_BACKOFF;
    }

    if (this.shouldDeleteWithoutBackoff(code)) {
      this.markDataAsUploaded(dataType, dataList);
      await this.deleteLastQuery(dataList);
      this.reduceCacheCount(dataType, dataList.length);
      this.resetErrorCount(dataType);
      this.resetIgnoredClientErrorCount(dataType);
      this.advancePackageGenerator(dataType, code);
      this.traceUploadLane(
        `[BATCH] type=${dataType} code=${code} rows=${dataList.length} action=delete backoff=0ms pkg=${pkgId}`
      );
      return UploadBatchResult.DELETE_NO_BACKOFF;
    }

    if (this.isRetryableUploadError(code)) {
      this.unmarkDataAsUploading(dataType, dataList);
      await this.reInsertData(dataList);
      this.resetIgnoredClientErrorCount(dataType);
      const retryCount = this.incrementErrorCount(dataType);
      const delayTime = this.getNormalBackoffMs(retryCount);
      FTInnerLogger.w(TAG,
        `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=reinsert retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
      await this.sleep(delayTime);
      return UploadBatchResult.RETRY_BACKOFF;
    }

    this.unmarkDataAsUploading(dataType, dataList);
    const retryCount = this.incrementErrorCount(dataType);
    const delayTime = this.getNormalBackoffMs(retryCount);
    FTInnerLogger.w(TAG,
      `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=retry retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
    await this.sleep(delayTime);
    return UploadBatchResult.RETRY_BACKOFF;
  }

  private getUploadMaxPages(dataType: DataType): number {
    switch (dataType) {
      case DataType.RUM_APP:
        return SyncTaskManager.UPLOAD_MAX_PAGES_RUM_APP;
      case DataType.RUM_WEBVIEW:
        return SyncTaskManager.UPLOAD_MAX_PAGES_RUM_WEBVIEW;
      case DataType.LOG:
      default:
        return SyncTaskManager.UPLOAD_MAX_PAGES_LOG;
    }
  }

  private isIgnoredClientError(code: number): boolean {
    return code === 403 || code === 429;
  }

  private shouldDeleteWithoutBackoff(code: number): boolean {
    return code >= 200 && code < 500 && !this.isIgnoredClientError(code);
  }

  private isRetryableUploadError(code: number): boolean {
    return code >= 500 ||
      code === NetCodeStatus.NETWORK_EXCEPTION_CODE ||
      code === NetCodeStatus.UNKNOWN_EXCEPTION_CODE;
  }

  private getNormalBackoffMs(errorCount: number): number {
    return Math.max(1, Math.pow(2, Math.max(0, errorCount - 1))) * SyncTaskManager.RETRY_DELAY_SLEEP_TIME;
  }

  private getIgnoredClientBackoffMs(errorCount: number): number {
    return Math.min(
      SyncTaskManager.IGNORED_CLIENT_ERROR_BACKOFF_MAX_MS,
      this.getNormalBackoffMs(errorCount)
    );
  }

  private getTypeErrorCount(dataType: DataType): number {
    return this.errorCountByType.get(dataType) || 0;
  }

  private getTypeIgnoredClientErrorCount(dataType: DataType): number {
    return this.ignoredClientErrorCountByType.get(dataType) || 0;
  }

  private incrementErrorCount(dataType: DataType): number {
    const count = this.getTypeErrorCount(dataType) + 1;
    this.errorCountByType.set(dataType, count);
    this.refreshAggregateErrorCount();
    return count;
  }

  private resetErrorCount(dataType: DataType): void {
    this.errorCountByType.set(dataType, 0);
    this.refreshAggregateErrorCount();
  }

  private incrementIgnoredClientErrorCount(dataType: DataType): number {
    const count = this.getTypeIgnoredClientErrorCount(dataType) + 1;
    this.ignoredClientErrorCountByType.set(dataType, count);
    return count;
  }

  private resetIgnoredClientErrorCount(dataType: DataType): void {
    this.ignoredClientErrorCountByType.set(dataType, 0);
  }

  private refreshAggregateErrorCount(): void {
    let maxErrorCount = 0;
    this.errorCountByType.forEach((count) => {
      maxErrorCount = Math.max(maxErrorCount, count);
    });
    this.errorCount = maxErrorCount;
  }

  private reduceCacheCount(dataType: DataType, count: number): void {
    if (dataType === DataType.LOG) {
      syncTaskRuntime.getCachePolicy().optLogCount(-count);
    } else if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      syncTaskRuntime.getCachePolicy().optRumCount(-count);
    }
  }

  private advancePackageGenerator(dataType: DataType, code: number): void {
    if (code !== 200) {
      return;
    }
    if (dataType === DataType.LOG) {
      this.logGenerator.next();
    } else {
      this.rumGenerator.next();
    }
  }

  /**
   * Extract unique identifier from line protocol data string
   * @param dataType Data type
   * @param dataString Line protocol data string
   * @returns Unique identifier string, or null if cannot extract
   */
  /**
   * Extract unique ID for upload deduplication
   * Strategy: Priority 1) Business ID (action_id, view_id, etc.), Priority 2) timestamp
   * This ensures the same business event (same action_id) is only uploaded once
   * @param dataType Data type
   * @param dataString Line protocol data string
   * @returns Unique ID string in format "field_name=value" or null if cannot extract
   */
  private extractUniqueId(dataType: DataType, dataString: string): string | null {
    try {
      // Priority 1: Use business ID for each data type

      // For action data: use action_id
      if (dataString.startsWith('action,')) {
        const actionIdMatch = dataString.match(/action_id=([^,\s]+)/);
        if (actionIdMatch && actionIdMatch[1]) {
          return `action_id=${actionIdMatch[1]}`;
        }
      }

      // For view data: use view_id + view_update_time to distinguish between active and closed views
      // This is critical because the same view_id can have multiple versions:
      // - view_update_time=1: is_active=true (when view is created)
      // - view_update_time=2: is_active=false (when view is closed)
      // Without view_update_time, the closed view would be incorrectly deduplicated as a duplicate
      if (dataString.startsWith('view,')) {
        const viewIdMatch = dataString.match(/view_id=([^,\s]+)/);
        const viewUpdateTimeMatch = dataString.match(/view_update_time=([^,\s]+)/);
        if (viewIdMatch && viewIdMatch[1]) {
          const viewId = viewIdMatch[1];
          if (viewUpdateTimeMatch && viewUpdateTimeMatch[1]) {
            // Use view_id + view_update_time as unique identifier
            return `view_id=${viewId}:view_update_time=${viewUpdateTimeMatch[1]}`;
          } else {
            // Fallback: use only view_id if view_update_time is not found
            return `view_id=${viewId}`;
          }
        }
      }

      // For resource data: use span_id or trace_id
      if (dataString.startsWith('resource,')) {
        const spanIdMatch = dataString.match(/span_id=([^,\s]+)/);
        if (spanIdMatch && spanIdMatch[1]) {
          return `span_id=${spanIdMatch[1]}`;
        }
        const traceIdMatch = dataString.match(/trace_id=([^,\s]+)/);
        if (traceIdMatch && traceIdMatch[1]) {
          return `trace_id=${traceIdMatch[1]}`;
        }
      }

      // For error data: use error_type + error_message + timestamp
      if (dataString.startsWith('error,')) {
        const errorTypeMatch = dataString.match(/error_type=([^,\s]+)/);
        const errorMessageMatch = dataString.match(/error_message="([^"]+)"/);
        const timestampMatch = dataString.match(/\s(\d+)$/);

        const errorType = errorTypeMatch ? errorTypeMatch[1] : '';
        const errorMessage = errorMessageMatch ? errorMessageMatch[1].substring(0, 100) : '';
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (errorType || errorMessage || timestamp) {
          return `error_type=${errorType}:error_message=${errorMessage}:timestamp=${timestamp}`;
        }
      }

      // For longtask data: use long_task_name + timestamp
      if (dataString.startsWith('longtask,') || dataString.startsWith('long_task,')) {
        const longTaskNameMatch = dataString.match(/long_task_name=([^,\s]+)/);
        const timestampMatch = dataString.match(/\s(\d+)$/);

        const longTaskName = longTaskNameMatch ? longTaskNameMatch[1] : '';
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (longTaskName || timestamp) {
          return `long_task_name=${longTaskName}:timestamp=${timestamp}`;
        }
      }

      // For log data: use uuid (extract from sdk_data_id)
      if (dataString.startsWith('df_rum_harmonyos_log,')) {
        const sdkDataIdMatch = dataString.match(/sdk_data_id=([^,\s]+)/);
        if (sdkDataIdMatch && sdkDataIdMatch[1]) {
          // Extract UUID from sdk_data_id (format: "xxx.uuid" or just "uuid")
          const uuidMatch = sdkDataIdMatch[1].match(/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i);
          if (uuidMatch && uuidMatch[1]) {
            return `uuid=${uuidMatch[1]}`;
          }
          // Fallback: use sdk_data_id as unique identifier
          return `sdk_data_id=${sdkDataIdMatch[1]}`;
        }
      }

      // Priority 2: Use timestamp as fallback for all data types
      // All line protocol data ends with timestamp, so this is a reliable fallback
      const timestampMatch = dataString.match(/\s(\d+)$/);
      if (timestampMatch && timestampMatch[1]) {
        return `timestamp=${timestampMatch[1]}`;
      }

      // Last resort: return null (should rarely happen)
      return null;
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Error extracting unique ID: ${error as string}`);
      return null;
    }
  }

  /**
   * Deduplicate data based on unique identifiers
   * @param dataType Data type
   * @param dataList List of data to deduplicate
   * @returns Deduplicated data list
   */
  private deduplicateData(dataType: DataType, dataList: SyncData[]): SyncData[] {
    if (!dataList || dataList.length === 0) {
      return dataList;
    }

    const uniqueDataMap: Map<string, SyncData> = new Map();
    const seenIds: Set<string> = new Set();

    for (const data of dataList) {
      const dataString = data.getDataString();
      const uniqueId = this.extractUniqueId(dataType, dataString);

      if (uniqueId) {
        const key = `${dataType}:${uniqueId}`;

        // Check if already uploaded
        if (this.uploadedDataIds.has(key)) {
          continue;
        }

        // Check if currently being uploaded (to prevent concurrent duplicate uploads)
        if (this.uploadingDataIds.has(key)) {
          continue;
        }

        // Check if duplicate in current batch
        if (seenIds.has(key)) {
          continue;
        }

        seenIds.add(key);
        uniqueDataMap.set(key, data);
      } else {
        // If cannot extract unique ID from data string, use uuid from SyncData as fallback
        const uuid = data.getUuid();
        if (uuid) {
          const key = `${dataType}:uuid=${uuid}`;

          if (this.uploadedDataIds.has(key)) {
            continue;
          }

          // Check if currently being uploaded (to prevent concurrent duplicate uploads)
          if (this.uploadingDataIds.has(key)) {
            continue;
          }

          if (seenIds.has(key)) {
            continue;
          }

          seenIds.add(key);
          uniqueDataMap.set(key, data);
        } else {
          // If even uuid is not available, use data string hash as last resort
          // This should rarely happen, but ensures we don't lose data
          FTInnerLogger.w(TAG,
            `<FT-BATCH-UPLOAD> [DEDUP] Warning: Cannot extract unique ID for data, using data string hash as fallback`);
          const dataHash = this.hashString(dataString);
          const key = `${dataType}:hash=${dataHash}`;

          if (this.uploadedDataIds.has(key)) {
            continue;
          }

          // Check if currently being uploaded (to prevent concurrent duplicate uploads)
          if (this.uploadingDataIds.has(key)) {
            continue;
          }

          if (seenIds.has(key)) {
            continue;
          }

          seenIds.add(key);
          uniqueDataMap.set(key, data);
        }
      }
    }

    return Array.from(uniqueDataMap.values());
  }

  /**
   * Simple hash function for string (used as last resort for deduplication)
   * @param str Input string
   * @returns Hash value as string
   */
  private hashString(str: string): string {
    let hash = 0;
    if (str.length === 0) {
      return '0';
    }
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash; // Convert to 32-bit integer
    }
    // Convert to positive number and return as hex string
    return Math.abs(hash).toString(16);
  }

  /**
   * Mark data as "uploading" before sending HTTP request to prevent concurrent duplicate uploads
   * @param dataType Data type
   * @param dataList List of data being uploaded
   */
  private markDataAsUploading(dataType: DataType, dataList: SyncData[]): void {
    for (const data of dataList) {
      const dataString = data.getDataString();
      const uniqueId = this.extractUniqueId(dataType, dataString);

      if (uniqueId) {
        const key = `${dataType}:${uniqueId}`;
        this.uploadingDataIds.add(key);
      } else {
        // Fallback: use uuid
        const uuid = data.getUuid();
        const key = `${dataType}:uuid=${uuid}`;
        this.uploadingDataIds.add(key);
      }
    }
  }

  /**
   * Unmark data as "uploading" (used when upload fails and needs retry)
   * @param dataType Data type
   * @param dataList List of data to unmark
   */
  private unmarkDataAsUploading(dataType: DataType, dataList: SyncData[]): void {
    for (const data of dataList) {
      const dataString = data.getDataString();
      const uniqueId = this.extractUniqueId(dataType, dataString);

      if (uniqueId) {
        const key = `${dataType}:${uniqueId}`;
        this.uploadingDataIds.delete(key);
      } else {
        // Fallback: use uuid
        const uuid = data.getUuid();
        const key = `${dataType}:uuid=${uuid}`;
        this.uploadingDataIds.delete(key);
      }
    }
  }

  /**
   * Mark data as uploaded to prevent duplicate uploads
   * Also removes from uploadingDataIds and adds to uploadedDataIds
   * @param dataType Data type
   * @param dataList List of uploaded data
   */
  private markDataAsUploaded(dataType: DataType, dataList: SyncData[]): void {
    for (const data of dataList) {
      const dataString = data.getDataString();
      const uniqueId = this.extractUniqueId(dataType, dataString);

      if (uniqueId) {
        const key = `${dataType}:${uniqueId}`;
        // Remove from uploading set and add to uploaded set
        this.uploadingDataIds.delete(key);
        this.uploadedDataIds.add(key);
      } else {
        // Fallback: use uuid
        const uuid = data.getUuid();
        const key = `${dataType}:uuid=${uuid}`;
        // Remove from uploading set and add to uploaded set
        this.uploadingDataIds.delete(key);
        this.uploadedDataIds.add(key);
      }
    }

    // Limit the size of uploadedDataIds to prevent memory issues
    // Keep only the most recent entries
    if (this.uploadedDataIds.size > Constants.MAX_SET_SIZE_UPLOAD) {
      const entries = Array.from(this.uploadedDataIds);
      this.uploadedDataIds.clear();
      // Keep the last 50% entries
      const keepCount = Math.floor(Constants.MAX_SET_SIZE_UPLOAD / 2);
      for (let i = entries.length - keepCount; i < entries.length; i++) {
        this.uploadedDataIds.add(entries[i]);
      }
      FTInnerLogger.w(TAG,
        `<FT-BATCH-UPLOAD> Trimmed uploadedDataIds from ${entries.length} to ${this.uploadedDataIds.size} entries to prevent memory leak`);
    }

    // Limit the size of uploadingDataIds to prevent memory issues
    // This Set should normally be small, but clear it if it grows too large (indicates stuck uploads)
    if (this.uploadingDataIds.size > Constants.MAX_SET_SIZE_UPLOAD) {
      FTInnerLogger.w(TAG,
        `<FT-BATCH-UPLOAD> uploadingDataIds size (${this.uploadingDataIds.size}) exceeds limit, clearing to prevent memory leak`);
      this.uploadingDataIds.clear();
    }
  }

  /**
   * Query data from database
   */
  private async queryFromData(dataType: DataType): Promise<SyncData[]> {
    try {
      if (!this.context) {
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Context is null, cannot query data`);
        return [];
      }

      // Query data from database
      const dbManager = syncTaskRuntime.getDbManager(this.context);
      if (!dbManager) {
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Database manager is null`);
        return [];
      }

      // Ensure database manager is initialized
      await dbManager.init();

      // Call database query method
      const dataList = await dbManager.queryFtOperation([dataType], this.pageSize);

      // Only log when data is found to reduce log noise
      if (dataList.length > 0) {
        // Removed verbose debug log to reduce log output
      }

      return dataList;
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Query data failed: ${dataType}, error: ${error as string}`);
      return [];
    }
  }

  /**
   * Print upload data details
   */
  private printUploadData(body: string): void {
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> ========== UPLOAD BODY PREVIEW ==========`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD>\n${body}`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> ========================================`);
  }

  /**
   * Delete uploaded data
   */
  private async deleteLastQuery(list: SyncData[]): Promise<void> {
    try {
      if (!list || list.length === 0) {
        return;
      }

      if (this.context) {
        const dbManager = syncTaskRuntime.getDbManager(this.context);
        if (dbManager) {
          await dbManager.deleteFtOperation(list);
        }
        // FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> [DELETE] Successfully deleted ${list.length} records`);
        // Small delay to ensure database deletion is fully committed before next query
        // This helps reduce duplicate filtering in the next batch
        await this.sleep(30);
      } else {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> Context is null, cannot delete uploaded data`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Delete uploaded data failed: ${error as string}`);
    }
  }

  /**
   * Re-insert data (for retry)
   */
  private async reInsertData(list: SyncData[]): Promise<void> {
    try {
      // Delete original data
      await this.deleteLastQuery(list);

      // Re-insert data with new UUID
      const oldUuids: string[] = [];
      const newUuids: string[] = [];
      for (const data of list) {
        oldUuids.push(data.getUuid());
        const newUuid = syncTaskRuntime.generateUUID();
        data.setUuid(newUuid);
        newUuids.push(newUuid);
      }

      // Removed verbose debug log to reduce log output

      if (this.context) {
        const dbManager = syncTaskRuntime.getDbManager(this.context);
        if (dbManager) {
          await dbManager.insertFtOptList(list, true);
        }
        // Removed verbose debug log to reduce log output
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Reinsert data failed: ${error as string}`);
    }
  }

  /**
   * Send network request
   */
  private async requestNet(dataType: DataType, pkgId: string, body: string, callback: SyncTaskRequestCallback): Promise<void> {
    if (!this.sdkConfig) {
      throw new Error("SDK config not initialized");
    }

    try {
      // Determine request model
      let model: string;
      switch (dataType) {
        case DataType.LOG:
          model = Constants.URL_MODEL_LOG;
          break;
        case DataType.RUM_APP:
        case DataType.RUM_WEBVIEW:
        default:
          model = Constants.URL_MODEL_RUM;
          break;
      }

      // Removed verbose debug log to reduce log output

      // Add WebView data detection and logging
      if (dataType === DataType.RUM_WEBVIEW) {
        FTInnerLogger.i(TAG,
          `<FT-BATCH-UPLOAD> [WEBVIEW-UPLOAD] ========== Uploading WebView data to server ==========`);
        FTInnerLogger.i(TAG,
          `<FT-BATCH-UPLOAD> [WEBVIEW-UPLOAD] Body length: ${body.length}, Record count: ${body.split('\n').length}`);
        FTInnerLogger.i(TAG, `<FT-BATCH-UPLOAD> [WEBVIEW-UPLOAD] Model: ${model}, pkgId: ${pkgId}`);
        if (body.includes(`${Constants.KEY_RUM_VIEW_IS_WEB_VIEW}=true`)) {
          FTInnerLogger.i(TAG, `<FT-BATCH-UPLOAD> [WEBVIEW-UPLOAD] ✅ WebView data confirmed in body`);
        }
      }

      const result = await syncTaskRuntime.executeHttp(this.sdkConfig, model, body, pkgId);

      // Handle response
      if (result.getCode() === NetCodeStatus.NETWORK_EXCEPTION_CODE) {
        FTInnerLogger.e(TAG, "Network not available");
        throw new Error("Network not available");
      }

      callback.onResponse(result.getCode(), result.getMessage(), result.getErrorCode());

    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Network request failed: ${error as string}`);
      callback.onResponse(NetCodeStatus.UNKNOWN_EXCEPTION_CODE, (error as Error).message || "", "");
    }
  }

  /**
   * Get sequence number
   */
  private getSeqNumber(dataType: DataType): string {
    if (dataType === DataType.LOG) {
      return this.logGenerator.getCurrentId();
    } else {
      return this.rumGenerator.getCurrentId();
    }
  }

  /**
   * Generate package ID
   */
  /**
   * Generate package ID matching Android SDK format
   * Format: {seqNumber}.{pid_base62}.{count}.{nanoId}
   * Where:
   * - seqNumber: Base36 encoded sequence ID (e.g., "1", "a", "z")
   * - pid_base62: Base62 encoded process ID (e.g., "abc")
   * - count: Data count in this batch (e.g., "5")
   * - nanoId: 12-digit random Base62 string (e.g., "xyz123ABCDEF")
   *
   * Example: "1.abc.5.xyz123ABCDEF"
   */
  private generatePackageId(seqNumber: string, dataCount: number): string {
    const pid = this.getProcessId();

    // Encode pid to Base62
    const pidEncoded = this.encodeBase62(pid);

    // Generate 12-digit random nanoId
    const nanoId = this.generateNanoId();

    const pkgId = `${seqNumber}.${pidEncoded}.${dataCount}.${nanoId}`;


    return pkgId;
  }

  /**
   * Generate 12-digit random Base62 string
   * Matches Android SDK's nanoId generation
   */
  private generateNanoId(): string {
    const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const NANO_DIGIT = 12;
    let result = "";

    for (let i = 0; i < NANO_DIGIT; i++) {
      const randomIndex = Math.floor(syncTaskRuntime.getRandom() * BASE62.length);
      result += BASE62.charAt(randomIndex);
    }

    return result;
  }

  /**
   * Encode number to Base62
   * Matches Android SDK's encodeBase62 method
   */
  private encodeBase62(value: number): string {
    const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    if (value === 0) {
      return "0";
    }

    let result = "";
    while (value > 0) {
      result = BASE62.charAt(value % 62) + result;
      value = Math.floor(value / 62);
    }

    return result;
  }


  /**
   * Get process ID
   */
  private getProcessId(): number {
    // HarmonyOS ArkTS lacks a direct PID API in standard kits; use a stable fallback
    // Derive a pseudo PID once per process lifetime based on time and random seed
    // This is only used for pkgId encoding and does not affect data semantics
    if (SyncTaskManager.cachedProcessId === undefined) {
      const seed = syncTaskRuntime.getCurrentTimeMs() ^ Math.floor(syncTaskRuntime.getRandom() * 1e6);
      SyncTaskManager.cachedProcessId = Math.abs(seed % 65535) + 1;
    }
    return SyncTaskManager.cachedProcessId;
  }

  /**
   * Check if half of cache limit is reached
   */
  private reachHalfLimit(): boolean {
    const policy = syncTaskRuntime.getCachePolicy();
    const logLimit = policy.getLogLimitCount();
    const rumLimit = policy.getRumLimitCount();
    const logCount = policy.getLogCount();
    const rumCount = policy.getRumCount();
    const logHit = logLimit > 0 && logCount >= Math.floor(logLimit / 2);
    const rumHit = rumLimit > 0 && rumCount >= Math.floor(rumLimit / 2);
    return logHit || rumHit;
  }

  /**
   * Sleep and wait
   */
  private sleep(ms: number): Promise<void> {
    return syncTaskRuntime.sleep(ms);
  }

  private nextUploadTaskName(): string {
    this.uploadTaskSequence++;
    return `upload.poll#${this.uploadTaskSequence}`;
  }

  private clearUploadScheduleTimer(): void {
    if (this.uploadScheduleTimer >= 0) {
      clearTimeout(this.uploadScheduleTimer);
      this.uploadScheduleTimer = -1;
    }
  }

  private getUploadLaneStatus(): UploadLaneStatus {
    return {
      isRunning: this.uploadRunning,
      isScheduled: this.uploadScheduled,
      needReschedule: this.uploadNeedReschedule,
      scheduledDelay: this.uploadScheduledDelay,
      scheduledAt: this.uploadScheduledAt,
      rescheduleDelay: this.uploadRescheduleDelay
    };
  }

  private traceUploadLane(message: string): void {
    FTInnerLogger.i(TAG, `<FT-UPLOAD-LANE> ${message}`);
  }

  private traceUploadLaneDebug(message: string): void {
    FTInnerLogger.d(TAG, `<FT-UPLOAD-LANE> ${message}`);
  }

  private traceUploadStartIfNeeded(dataType: DataType, rows: number): void {
    if (this.uploadStartTraced) {
      return;
    }
    this.uploadStartTraced = true;
    const taskName = this.uploadCurrentTaskName.length > 0 ? this.uploadCurrentTaskName : this.nextUploadTaskName();
    this.traceUploadLane(`[START] name=${taskName} firstType=${dataType} rows=${rows}`);
  }

  /**
   * Stop sync task
   */
  public stop(): void {
    this.isStop = true;
    this.running = false;
    this.uploadRunning = false;
    this.uploadScheduled = false;
    this.uploadNeedReschedule = false;
    this.uploadRescheduleDelay = 0;
    this.uploadScheduledDelay = 0;
    this.uploadScheduledAt = 0;
    this.clearUploadScheduleTimer();

    // Stop RUM cleanup timer
    RUMDataCleanupManagerInternal.getInstance().destroy();

    FTInnerLogger.i(TAG, "SyncTaskManager stopped (including cleanup timer)");
  }

  /**
   * Resume sync task
   */
  public resume(): void {
    this.isStop = false;
    FTInnerLogger.i(TAG, "SyncTaskManager resumed");
  }

  /**
   * Set running status
   */
  public setRunning(running: boolean): void {
    this.running = running;
    this.uploadRunning = running;
  }

  /**
   * Format data as Line Protocol
   */
  private formatLineProtocolData(dataList: SyncData[], pkgId: string): string {
    if (!dataList || dataList.length === 0) {
      return "";
    }

    const lines: string[] = [];

    for (const data of dataList) {
      // Get line protocol data with package ID embedded in sdk_data_id tag
      // This matches Android SDK behavior: replaces uuid in sdk_data_id with pkgId.uuid
      // For example: sdk_data_id=abc123 -> sdk_data_id=1.abc.5.xyz.abc123

      const originalData = data.getDataString();
      const dataString = data.getLineProtocolDataWithPkgId(pkgId);

      // Log sdk_data_id transformation
      if (originalData && originalData.trim().length > 0) {
        const sdkDataIdOriginal = originalData.match(/sdk_data_id=([^,]+)/);
        const sdkDataIdModified = dataString.match(/sdk_data_id=([^,]+)/);
        if (sdkDataIdOriginal && sdkDataIdModified) {
        }
      }

      if (dataString && dataString.trim().length > 0) {
        // Add package ID as a separate tag (pkg_id) for batch tracking
        // This allows the server to track which batch the data belongs to
        const lineWithPkgId = this.addPackageIdToLine(dataString, pkgId);
        lines.push(lineWithPkgId);
      }
    }

    return lines.join('\n');
  }

  /**
   * Add package ID to Line Protocol line
   */
  private addPackageIdToLine(line: string, pkgId: string): string {
    // pkg_id is NOT added as a tag in line protocol
    // It's only used in HTTP header (X-Pkg-Id) and embedded in sdk_data_id
    // Return the line as-is
    return line;
  }

  /**
   * Set auto sync enabled/disabled
   * Allows dynamic control of auto sync behavior
   * Aligned with Android: SyncTaskManager.setAutoSync()
   */
  public setAutoSync(enabled: boolean): void {
    this.autoSync = enabled;
    FTInnerLogger.i(TAG, `Auto sync ${enabled ? 'enabled' : 'disabled'}`);
  }

  /**
   * Get page size for data sync
   * Aligned with Android SDK testing
   * @returns Current page size
   */
  public getPageSize(): number {
    return this.pageSize;
  }

  /**
   * Get sync sleep time in milliseconds
   * Aligned with Android SDK testing
   * @returns Current sync sleep time
   */
  public getSyncSleepTime(): number {
    return this.syncSleepTime;
  }

  /**
   * Check if auto sync is enabled
   * Aligned with Android SDK testing
   * @returns true if auto sync is enabled
   */
  public isAutoSyncEnabled(): boolean {
    return this.autoSync;
  }

  /**
   * Get status information
   */
  public getStatus(): SyncTaskManagerStatus {
    return {
      isStop: this.isStop,
      running: this.running,
      autoSync: this.autoSync,
      errorCount: this.errorCount,
      pageSize: this.pageSize,
      dataSyncMaxRetryCount: this.dataSyncMaxRetryCount,
      syncSleepTime: this.syncSleepTime,
      uploadLaneStatus: this.getUploadLaneStatus()
    };
  }

}

/**
 * Sync task manager status interface
 */
export interface SyncTaskManagerStatus {
  isStop: boolean;
  running: boolean;
  autoSync: boolean;
  errorCount: number;
  pageSize: number;
  dataSyncMaxRetryCount: number;
  syncSleepTime: number;
  uploadLaneStatus: UploadLaneStatus;
}

export interface UploadLaneStatus {
  isRunning: boolean;
  isScheduled: boolean;
  needReschedule: boolean;
  scheduledDelay: number;
  scheduledAt: number;
  rescheduleDelay: number;
}

/**
 * ID generator class
 */
/**
 * ID Generator matching Android SDK's ID36Generator
 * Generates Base36 encoded sequential IDs
 * Format: 0-9, a-z (36 characters)
 * Example: "1", "a", "z", "10", "1a", etc.
 */
class IDGenerator {
  private static readonly BASE36_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz";
  private static readonly MAX_VALUE = Math.pow(36, 8); // Max value before reset
  private static readonly LENGTH = 8;
  private currentValue: number = 0;

  /**
   * Get current ID in Base36
   */
  getCurrentId(): string {
    return this.getBase36String(this.currentValue);
  }

  /**
   * Increment to next ID
   */
  next(): void {
    this.currentValue++;
    if (this.currentValue > IDGenerator.MAX_VALUE) {
      this.currentValue = 0;
    }
  }

  /**
   * Convert number to Base36 string
   */
  private getBase36String(value: number): string {
    if (value === 0) {
      return "0";
    }

    let result = "";
    while (value > 0) {
      result = IDGenerator.BASE36_CHARS.charAt(value % 36) + result;
      value = Math.floor(value / 36);
    }

    return result;
  }

  /**
   * Generate ID and increment
   */
  generateID(): string {
    const result = this.getCurrentId();
    this.next();
    return result;
  }

}

/**
 * RUM data cleanup manager
 */
class RUMDataCleanupManagerInternal {
  private static instance: RUMDataCleanupManagerInternal | null = null;
  private cleanupTimer: number | null = null;
  private context: Context | null = null;
  private readonly CLEANUP_INTERVAL = 5 * 60 * 1000; // Clean up every 5 minutes
  private readonly RETENTION_DAYS = 7; // Retain data for 7 days

  private constructor() {
  }

  public static resetInternal(): void {
    if (RUMDataCleanupManagerInternal.instance) {
      RUMDataCleanupManagerInternal.instance.destroy();
    }
    RUMDataCleanupManagerInternal.instance = null;
  }

  public static getInstance(): RUMDataCleanupManagerInternal {
    if (!RUMDataCleanupManagerInternal.instance) {
      RUMDataCleanupManagerInternal.instance = new RUMDataCleanupManagerInternal();
    }
    return RUMDataCleanupManagerInternal.instance;
  }

  public init(context: Context): void {
    this.context = context;
    this.startCleanupTimer();
    FTInnerLogger.d(TAG, `RUM data cleanup manager initialized`);
  }

  private startCleanupTimer(): void {
    if (this.cleanupTimer) {
      syncTaskRuntime.clearTimer(this.cleanupTimer);
    }

    this.cleanupTimer = syncTaskRuntime.setTimer(() => {
      this.performCleanup();
    }, this.CLEANUP_INTERVAL);

    FTInnerLogger.d(TAG, `RUM cleanup timer started, interval: ${this.CLEANUP_INTERVAL}ms`);
  }

  private async performCleanup(): Promise<void> {
    if (!this.context) {
      return;
    }

    try {
      FTInnerLogger.d(TAG, `Starting RUM data cleanup`);

      const cutoffTime = syncTaskRuntime.getCurrentTimeMs() - (this.RETENTION_DAYS * 24 * 60 * 60 * 1000);

      // Clean up expired rum_view data
      await this.cleanupExpiredRumView(cutoffTime);

      // Clean up expired rum_action data
      await this.cleanupExpiredRumAction(cutoffTime);

      FTInnerLogger.d(TAG, `RUM data cleanup completed`);
    } catch (error) {
      FTInnerLogger.e(TAG, `RUM data cleanup failed: ${error as string}`);
    }
  }

  private async cleanupExpiredRumView(cutoffTime: number): Promise<void> {
    try {
      class CleanupViewCallback implements DataBaseCallBack {
        deletedCount: number = 0;

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // First query the number of records to delete
          const countPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          countPredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
          const countResult = await rdbStore.query(countPredicates, ['count(*) as count']);
          if (countResult.goToFirstRow()) {
            this.deletedCount = countResult.getLong(0);
          }
          countResult.close();

          // Execute delete operation
          const deletePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
          deletePredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
          await rdbStore.delete(deletePredicates);
        }
      }

      const callback = new CleanupViewCallback();
      const dbManager = syncTaskRuntime.getDbManager(this.context!);
      if (dbManager) {
        await dbManager.executeWithDB(true, callback);
      }
      FTInnerLogger.d(TAG, `Cleaned up expired rum_view data: ${callback.deletedCount} records deleted`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Cleanup expired rum_view failed: ${error as string}`);
    }
  }

  private async cleanupExpiredRumAction(cutoffTime: number): Promise<void> {
    try {
      class CleanupActionCallback implements DataBaseCallBack {
        deletedCount: number = 0;

        async run(rdbStore: relationalStore.RdbStore): Promise<void> {
          // First query the number of records to delete
          const countPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          countPredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
          const countResult = await rdbStore.query(countPredicates, ['count(*) as count']);
          if (countResult.goToFirstRow()) {
            this.deletedCount = countResult.getLong(0);
          }
          countResult.close();

          // Execute delete operation
          const deletePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
          deletePredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
          await rdbStore.delete(deletePredicates);
        }
      }

      const callback = new CleanupActionCallback();
      const dbManager = syncTaskRuntime.getDbManager(this.context!);
      if (dbManager) {
        await dbManager.executeWithDB(true, callback);
      }
      FTInnerLogger.d(TAG, `Cleaned up expired rum_action data: ${callback.deletedCount} records deleted`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Cleanup expired rum_action failed: ${error as string}`);
    }
  }

  public destroy(): void {
    if (this.cleanupTimer) {
      syncTaskRuntime.clearTimer(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    this.context = null;
    FTInnerLogger.d(TAG, `RUM data cleanup manager destroyed`);
  }

}
