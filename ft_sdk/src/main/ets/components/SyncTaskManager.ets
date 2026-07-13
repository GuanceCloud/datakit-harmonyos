import { FTSDKConfig } from './Configs';
import { DataType } from './enum/Enums';
import { SyncData } from './db/bean/SyncData';
import { Context } from '@kit.AbilityKit';
import { Constants } from './Constants';
import { ViewBean } from './db/bean/ViewBean';
import { FTInnerLogger } from './log/FTLogger';
import {
  DefaultSyncTaskManagerRuntime,
  SyncTaskCachePolicy,
  SyncTaskConfigRecord,
  SyncTaskDbTaskPool,
  SyncTaskManagerRuntime,
  SyncTaskPreferences
} from './internal/runtime/SyncTaskManagerRuntime';
import { DataUploadWorkerExecutor } from './thread/workers/DataUploadWorkerExecutor';
import {
  DataUploadConsumeOptions,
  DataUploadConsumeResult,
  DataUploadDbCommitAction,
  DataUploadDbMaintenanceResult,
  DataUploadDbWriteResult,
  DataUploadQueryPage,
  DataUploadRow,
  DataUploadWorkerCapabilities
} from './thread/workers/DataUploadWorkerCapabilities';
import {
  SDKUploadHttpConfigDTO,
  SDKUploadHttpResultDTO,
  SDKWorkerRequest,
  SDKWorkerResponse
} from './thread/SDKWorkerProtocol';
import {
  DATA_UPLOAD_MAX_BODY_BYTES,
  DATA_UPLOAD_MAX_DB_PAGE_BYTES,
  DATA_UPLOAD_MAX_PAGE_SIZE,
  DATA_UPLOAD_MAX_RETRY_COUNT,
  DATA_UPLOAD_MAX_TRANSPORT_BYTES
} from './thread/workers/DataUploadLimits';

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

function normalizeUploadPageSize(pageSize: number): number {
  if (pageSize !== pageSize || pageSize <= 0) {
    return 1;
  }
  return Math.min(DATA_UPLOAD_MAX_PAGE_SIZE, Math.max(1, Math.floor(pageSize)));
}

function normalizeUploadRetryCount(retryCount: number): number {
  if (retryCount !== retryCount || retryCount <= 0) {
    return 0;
  }
  return Math.min(DATA_UPLOAD_MAX_RETRY_COUNT, Math.floor(retryCount));
}

class SyncTaskDataUploadCapabilities implements DataUploadWorkerCapabilities {
  private readonly configProvider: () => FTSDKConfig | null;
  private readonly contextProvider: () => Context | null;
  private readonly dbTaskPoolProvider: () => SyncTaskDbTaskPool;
  private readonly stopProvider: () => boolean;

  constructor(
    configProvider: () => FTSDKConfig | null,
    contextProvider: () => Context | null,
    dbTaskPoolProvider: () => SyncTaskDbTaskPool,
    stopProvider: () => boolean
  ) {
    this.configProvider = configProvider;
    this.contextProvider = contextProvider;
    this.dbTaskPoolProvider = dbTaskPoolProvider;
    this.stopProvider = stopProvider;
  }

  isStopped(): boolean {
    return this.stopProvider();
  }

  executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const fault = syncTaskRuntime.consumeUploadWorkerCommandFailure?.(request) || '';
    if (fault.length > 0) {
      const response: SDKWorkerResponse = {
        id: request.id,
        ok: false,
        errorMessage: fault
      };
      return Promise.resolve(response);
    }
    return syncTaskRuntime.executeUploadWorkerCommand(request);
  }

  async hasData(dataType: DataType): Promise<boolean> {
    const context = this.contextProvider();
    if (!context) {
      return false;
    }
    return await this.dbTaskPoolProvider().hasSyncData(context, [dataType.toString()]);
  }

  async queryRows(dataType: DataType, pageSize: number): Promise<DataUploadQueryPage> {
    const context = this.contextProvider();
    if (!context) {
      return this.emptyUploadQueryPage();
    }
    const dbTaskPool = this.dbTaskPoolProvider();
    const normalizedPageSize = normalizeUploadPageSize(pageSize);
    let rows: SyncData[] = [];
    let hasMore = false;
    let byteLimitReached = false;
    if (dbTaskPool.queryUploadData) {
      const page = await dbTaskPool.queryUploadData(
        context,
        [dataType.toString()],
        normalizedPageSize,
        DATA_UPLOAD_MAX_DB_PAGE_BYTES
      );
      rows = page.rows;
      hasMore = page.hasMore;
      byteLimitReached = page.byteLimitReached;
    } else {
      // Unit/custom runtimes retain compatibility while the production DB path
      // uses the byte-capped TaskPool query above.
      rows = await dbTaskPool.querySyncData(context, [dataType.toString()], normalizedPageSize);
      hasMore = rows.length >= normalizedPageSize;
    }
    const result: DataUploadRow[] = [];
    let transportBytes = 0;
    for (let i = 0; i < rows.length; i++) {
      const uploadRow = this.toUploadRow(rows[i]);
      const rowBytes = this.estimateUploadTransportRowBytes(uploadRow);
      if (transportBytes + rowBytes > DATA_UPLOAD_MAX_TRANSPORT_BYTES) {
        hasMore = true;
        byteLimitReached = true;
        break;
      }
      result.push(uploadRow);
      transportBytes += rowBytes;
    }
    return {
      rows: result,
      hasMore,
      transportBytes,
      byteLimitReached
    };
  }

  private emptyUploadQueryPage(): DataUploadQueryPage {
    return {
      rows: [],
      hasMore: false,
      transportBytes: 0,
      byteLimitReached: false
    };
  }

  private estimateUploadTransportRowBytes(row: DataUploadRow): number {
    return this.getUtf8ByteLength(row.dataString || '') + this.getUtf8ByteLength(row.uuid || '') +
      this.getUtf8ByteLength(row.dataType || '') + this.getUtf8ByteLength(row.customDataType || '') + 64;
  }

  private getUtf8ByteLength(value: string): number {
    let bytes = 0;
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code <= 0x7f) {
        bytes++;
      } else if (code <= 0x7ff) {
        bytes += 2;
      } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
        const next = value.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          bytes += 4;
          i++;
        } else {
          bytes += 3;
        }
      } else {
        bytes += 3;
      }
    }
    return bytes;
  }

  async commitUpload(
    dataType: DataType,
    action: DataUploadDbCommitAction,
    rows: DataUploadRow[],
    reInsertRows: DataUploadRow[],
    reduceCount: number
  ): Promise<DataUploadDbWriteResult> {
    const fault = syncTaskRuntime.consumeUploadDbCommitFailure?.() || '';
    if (fault.length > 0) {
      throw new Error(fault);
    }
    const context = this.contextProvider();
    if (!context || (!rows || rows.length === 0)) {
      return this.createDbWriteResult(0, 0);
    }
    const response = await this.dbTaskPoolProvider().uploadCommit(
      context,
      dataType.toString(),
      action,
      this.toSyncDataList(rows),
      this.toSyncDataList(reInsertRows || []),
      reduceCount
    );
    const expectedAffectedRows = action === DataUploadDbCommitAction.REINSERT ?
      rows.length + (reInsertRows || []).length : rows.length;
    if (response.affectedRows < expectedAffectedRows) {
      throw new Error(`Upload DB commit affected ${response.affectedRows}/${expectedAffectedRows} expected row operations`);
    }
    this.applyCacheCountDelta(response.logCountDelta, response.rumCountDelta);
    return this.createDbWriteResult(response.affectedRows, response.dbLaneWaitMs);
  }

  async maintainErrorSampled(
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<DataUploadDbMaintenanceResult> {
    const context = this.contextProvider();
    if (!context) {
      return {
        updatedRows: 0,
        deletedRows: 0,
        dbLaneWaitMs: 0
      };
    }
    const response = await this.dbTaskPoolProvider().maintainErrorSampled(
      context,
      dataType,
      errorTimeLine,
      now,
      duration
    );
    return {
      updatedRows: response.updatedRows,
      deletedRows: response.deletedRows,
      dbLaneWaitMs: response.dbLaneWaitMs
    };
  }

  getHttpConfig(dataType: DataType): SDKUploadHttpConfigDTO {
    const config = this.configProvider();
    if (!config) {
      throw new Error("SDK config not initialized");
    }

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

    return {
      datakitUrl: config.getDatakitUrl(),
      datawayUrl: config.getDatawayUrl(),
      clientToken: config.getClientToken(),
      model,
      deviceTimeMs: this.getCurrentTimeMs(),
      connectTimeoutMs: 60000,
      readTimeoutMs: 60000,
      softTimeoutMs: 125000
    };
  }

  takeInjectedHttpResult(): SDKUploadHttpResultDTO | undefined {
    return syncTaskRuntime.takeInjectedUploadHttpResult?.();
  }

  getCurrentTimeMs(): number {
    return syncTaskRuntime.getCurrentTimeMs();
  }

  getRandom(): number {
    return syncTaskRuntime.getRandom();
  }

  generateUUID(): string {
    return syncTaskRuntime.generateUUID();
  }

  sleep(ms: number): Promise<void> {
    return syncTaskRuntime.sleep(ms);
  }

  private createDbWriteResult(affectedRows: number, dbLaneWaitMs: number): DataUploadDbWriteResult {
    return {
      affectedRows: Math.max(0, affectedRows),
      dbLaneWaitMs: Math.max(0, dbLaneWaitMs)
    };
  }

  private toUploadRow(data: SyncData): DataUploadRow {
    const row: DataUploadRow = {
      id: data.getId(),
      dataType: data.getDataType().toString(),
      dataString: data.getDataString(),
      uuid: data.getUuid(),
      time: data.getTime()
    };
    const customDataType = data.getCustomDataTypeString();
    if (customDataType && customDataType.length > 0) {
      row.customDataType = customDataType;
    }
    return row;
  }

  private toSyncDataList(rows: DataUploadRow[]): SyncData[] {
    const result: SyncData[] = [];
    for (const row of rows) {
      result.push(this.toSyncData(row));
    }
    return result;
  }

  private toSyncData(row: DataUploadRow): SyncData {
    const data = new SyncData(this.toDataType(row.dataType));
    data.setId(row.id);
    data.setDataString(row.dataString);
    data.setUuid(row.uuid);
    data.setTime(row.time);
    if (row.customDataType && row.customDataType.length > 0) {
      data.setCustomDataTypeString(row.customDataType);
    }
    return data;
  }

  private toDataType(dataType: string): DataType {
    if (dataType === DataType.RUM_APP.toString()) {
      return DataType.RUM_APP;
    }
    if (dataType === DataType.RUM_WEBVIEW.toString()) {
      return DataType.RUM_WEBVIEW;
    }
    return DataType.LOG;
  }

  private applyCacheCountDelta(logDelta: number, rumDelta: number): void {
    if (logDelta !== 0) {
      syncTaskRuntime.getCachePolicy().optLogCount(logDelta);
    }
    if (rumDelta !== 0) {
      syncTaskRuntime.getCachePolicy().optRumCount(rumDelta);
    }
  }
}

/**
 * Data synchronization manager
 * Responsible for querying data from database and uploading to server
 */
export class SyncTaskManager {
  public static readonly SYNC_SLEEP_MAX_TIME_MS = 5000;
  public static readonly SYNC_SLEEP_MINI_TIME_MS = 0;
  public static readonly MAX_ERROR_COUNT = DATA_UPLOAD_MAX_RETRY_COUNT;
  public static readonly MAX_PAGE_SIZE = DATA_UPLOAD_MAX_PAGE_SIZE;
  public static readonly MAX_BODY_BYTES = DATA_UPLOAD_MAX_BODY_BYTES;
  private static instance: SyncTaskManager | null = null;
  private static SLEEP_TIME = 2000; // 2 seconds - upload interval (reduced from 3s to further improve upload speed)
  private static readonly PREFERENCES_NAME = 'ft_sdk_sync_task';
  private static readonly KEY_ERROR_TIMELINE = 'ft.rum.error.timeline';
  private errorCount = 0;
  private running = false;
  private uploadRunning = false;
  private uploadScheduled = false;
  private uploadNeedReschedule = false;
  private uploadScheduledDelay = 0;
  private uploadScheduledAt = 0;
  private uploadRescheduleDelay = 0;
  private uploadTimer = -1;
  private uploadTaskSequence = 0;
  private isStop = false;
  private autoSync = false;
  private syncSleepTime = 0;
  private pageSize = 100; // Default page size (increased from 50 to improve upload throughput)
  private dataSyncMaxRetryCount = 3; // Maximum retry count
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;
  private errorTimeLine: number = -1; // Error time line in nanoseconds
  private preferencesStore: SyncTaskPreferences | null = null;
  private uploadWorkerExecutor = new DataUploadWorkerExecutor();
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
    DataUploadWorkerExecutor.resetStaticStateInternal();
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
    this.dataSyncMaxRetryCount = normalizeUploadRetryCount(config.getDataSyncRetryCount());
    this.pageSize = normalizeUploadPageSize(config.getPageSize());
    this.autoSync = config.isAutoSyncEnabled?.() || false;
    this.syncSleepTime = config.getSyncSleepTime?.() || 0;

    // Initialize database cache policy (does not require context)
    const configRecord = new ConfigRecordImpl(config);
    syncTaskRuntime.getCachePolicy().initSDKParams(configRecord);

    // Initialize components that require context
    if (context) {
      this.context = context;

      // Initialize preferences for errorTimeLine storage
      try {
        this.preferencesStore = syncTaskRuntime.getPreferences(context, SyncTaskManager.PREFERENCES_NAME);
        this.loadErrorTimeLineFromFileCache();

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
    FTInnerLogger.d(TAG, "******************* Sync Poll Ready *******************>>>");
  }

  private scheduleUpload(delay: number = 0): void {
    if (this.isStop) {
      return;
    }

    const normalizedDelay = Math.max(0, delay);
    const taskName = this.nextUploadTaskName();
    if (this.uploadScheduled || this.uploadRunning) {
      this.uploadNeedReschedule = true;
      if (this.uploadRescheduleDelay > 0) {
        this.uploadRescheduleDelay = Math.min(this.uploadRescheduleDelay, normalizedDelay);
      } else {
        this.uploadRescheduleDelay = normalizedDelay;
      }
      return;
    }

    this.uploadScheduled = true;
    this.uploadScheduledDelay = normalizedDelay;
    this.uploadScheduledAt = syncTaskRuntime.getCurrentTimeMs();

    this.clearUploadTimer();
    this.uploadTimer = syncTaskRuntime.setTimer(() => {
      this.clearUploadTimer();
      this.executeScheduledUpload(taskName);
    }, normalizedDelay);

    if (normalizedDelay > 0) {
      FTInnerLogger.d(TAG, "******************* Sync Poll Waiting *******************>>>");
    }
  }

  private clearUploadTimer(): void {
    if (this.uploadTimer >= 0) {
      syncTaskRuntime.clearTimer(this.uploadTimer);
      this.uploadTimer = -1;
    }
  }

  private cancelUploadSchedule(): void {
    this.clearUploadTimer();
    this.uploadScheduled = false;
    this.uploadRunning = false;
    this.uploadNeedReschedule = false;
    this.uploadScheduledDelay = 0;
    this.uploadScheduledAt = 0;
    this.uploadRescheduleDelay = 0;
  }

  private async executeScheduledUpload(taskName: string): Promise<void> {
    this.uploadScheduled = false;
    this.uploadScheduledAt = 0;
    this.uploadScheduledDelay = 0;

    if (this.isStop) {
      return;
    }

    FTInnerLogger.d(TAG, "******************* Sync Poll Running *******************>>>");
    this.uploadRunning = true;
    this.running = true;

    try {
      const consumeResult = await this.executeDataUploadWorkerConsume(taskName);
      this.errorCount = consumeResult.errorCount;
      if (consumeResult.hasMoreData && !this.isStop) {
        this.scheduleUpload(0);
      }
    } catch (error) {
      this.uploadRunning = false;
      this.running = false;
      FTInnerLogger.e(TAG, `Sync Poll Failed: name=${taskName}, error=${error as string}`);
    } finally {
      const shouldReschedule = this.uploadNeedReschedule;
      const nextDelay = this.uploadRescheduleDelay;
      this.uploadRunning = false;
      this.running = false;
      FTInnerLogger.d(TAG, "******************* Sync Poll Finish *******************>>>");
      this.uploadNeedReschedule = false;
      this.uploadRescheduleDelay = 0;
      if (shouldReschedule && !this.isStop) {
        this.scheduleUpload(nextDelay);
      }
    }
  }

  private async executeDataUploadWorkerConsume(taskName: string): Promise<DataUploadConsumeResult> {
    const options = this.createDataUploadConsumeOptions(taskName);
    const capabilities = this.createDataUploadCapabilities();
    return await this.uploadWorkerExecutor.consume(capabilities, options);
  }

  private createDataUploadConsumeOptions(taskName: string): DataUploadConsumeOptions {
    return {
      taskName: taskName && taskName.length > 0 ? taskName : 'upload.poll',
      pageSize: normalizeUploadPageSize(this.pageSize),
      maxRetryCount: this.dataSyncMaxRetryCount,
      syncSleepTime: Math.max(0, this.syncSleepTime),
      errorTimeLine: this.errorTimeLine,
      stopped: this.isStop
    };
  }

  private createDataUploadCapabilities(): DataUploadWorkerCapabilities {
    return new SyncTaskDataUploadCapabilities(
      () => this.sdkConfig,
      () => this.context,
      () => syncTaskRuntime.getDbTaskPool(),
      () => this.isStop
    );
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
    if (!this.autoSync || this.isStop) {
      return;
    }

    this.scheduleUpload(0);
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

  private async loadErrorTimeLineFromFileCache(): Promise<void> {
    this.errorTimeLine = await this.getErrorTimeLineFromFileCache();
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

  private nextUploadTaskName(): string {
    this.uploadTaskSequence++;
    return `upload.poll#${this.uploadTaskSequence}`;
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

  /**
   * Stop sync task
   */
  public stop(): void {
    this.isStop = true;
    this.running = false;
    this.cancelUploadSchedule();

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
   * Set auto sync enabled/disabled
   * Allows dynamic control of auto sync behavior
   * Aligned with Android: SyncTaskManager.setAutoSync()
   */
  public setAutoSync(enabled: boolean): void {
    const wasAutoSync = this.autoSync;
    this.autoSync = enabled;
    FTInnerLogger.i(TAG, `Auto sync ${enabled ? 'enabled' : 'disabled'}`);

    if (!wasAutoSync && enabled) {
      this.executeSyncPoll();
    }
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
      const deletedCount = await syncTaskRuntime.getDbTaskPool().cleanupExpiredRumView(this.context!, cutoffTime);
      FTInnerLogger.d(TAG, `Cleaned up expired rum_view data: ${deletedCount} records deleted`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Cleanup expired rum_view failed: ${error as string}`);
    }
  }

  private async cleanupExpiredRumAction(cutoffTime: number): Promise<void> {
    try {
      const deletedCount = await syncTaskRuntime.getDbTaskPool().cleanupExpiredRumAction(this.context!, cutoffTime);
      FTInnerLogger.d(TAG, `Cleaned up expired rum_action data: ${deletedCount} records deleted`);
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
