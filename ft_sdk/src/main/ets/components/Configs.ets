import { Constants } from "./Constants";
import { DBCacheDiscard, DetectFrequency, EnvType, LogCacheDiscard, RUMCacheDiscard, SDKLogLevel, SyncPageSize } from "./enum/Enums";
import { Status } from "./bean/Status";
import { TraceType } from "./trace/TraceType";
import { SyncTaskManager } from "./SyncTaskManager";
import { FTInTakeUrlHandler } from "./http/FTInTakeUrlHandler";
import { FTTraceHeaderHandler } from "./trace/FTTraceHeaderHandler";
import { DataModifier, LineDataModifier } from "./DataModifier";
import { FTActionTrackingHandler } from "./rum/handler/FTActionTrackingHandler";

export type LogGlobalContextValue = string | number | boolean | String | Number | Boolean | object | null | undefined;
export type LogGlobalContextDictionary = Map<string, LogGlobalContextValue> | Record<string, LogGlobalContextValue>;

export interface FTInnerLogFileConfig {
  singleFileMaxSize?: number;
  totalFileMaxSize?: number;
  flushBatchSize?: number;
  flushIntervalMs?: number;
}

export class FTRUMConfig {
  // Property definitions
  private samplingRate: number = 1.0; // Sampling rate, range 0 to 1
  private sessionErrorSampleRate: number = 0.0; // Error sampling rate, range 0 to 1, default 0.0
  private rumAppId: string = "";
  private enableTrackAppCrash: boolean = false;
  private enableTrackAppUIBlock: boolean = false;
  private blockDurationMS: number = 1000; // Default: 1000ms (1 second)
  private enableTrackAppANR: boolean = false;
  private enableTraceUserAction: boolean = false;
  private enableTraceUserView: boolean = false;
  private enableTraceUserResource: boolean = false;
  private enableTraceWebView: boolean = false;
  private enableResourceHostIP: boolean = false;
  // Monitor data
  private extraMonitorTypeWithError: number = 0; // ERROR_MONITOR_NO_SET
  private deviceMetricsMonitorType: number = 0; // DEVICE_METRICS_MONITOR_NO_SET
  private deviceMetricsDetectFrequency: DetectFrequency = DetectFrequency.DEFAULT;
  private globalContext: Map<string, object> = new Map();
  private serviceName: string = Constants.DEFAULT_SERVICE_NAME;
  // TODO: Thread current stack
  // private extraLogCatWithJavaCrash: ExtraLogCatSetting | null = null;
  // private extraLogCatWithNativeCrash: ExtraLogCatSetting | null = null;
  // private extraLogCatWithANR: ExtraLogCatSetting | null = null;
  private intTakeUrlHandler: FTInTakeUrlHandler | null = null;
  private actionTrackingHandler: FTActionTrackingHandler | null = null;
  private rumCacheLimitCount: number = Constants.DEFAULT_DB_RUM_CACHE_NUM;
  private rumCacheDiscardStrategy: RUMCacheDiscard = RUMCacheDiscard.DISCARD;

  // Method definitions
  public getSamplingRate(): number {
    return this.samplingRate;
  }

  public setSamplingRate(samplingRate: number = 1.0): FTRUMConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /**
   * Get error sampling rate
   */
  public getSessionErrorSampleRate(): number {
    return this.sessionErrorSampleRate;
  }

  /**
   * Set error sampling rate
   * When the session is not sampled by setSamplingRate,
   * if an error occurs during the session, data within 1 minute before the error can be collected.
   * Range [0,1], 0 means no collection, 1 means full collection.
   * Default is 0.0, aligned with Android SDK.
   */
  public setSessionErrorSampleRate(sessionErrorSampleRate: number = 0.0): FTRUMConfig {
    this.sessionErrorSampleRate = Math.min(1.0, Math.max(0, sessionErrorSampleRate));
    return this;
  }

  public getServiceName(): string {
    return this.serviceName;
  }

  public setServiceName(serviceName: string): void {
    this.serviceName = serviceName;
  }

  public getRumAppId(): string {
    return this.rumAppId;
  }

  public setRumAppId(rumAppId: string): FTRUMConfig {
    this.rumAppId = rumAppId;
    return this;
  }

  /**
   * Set maximum RUM entry count, minimum not less than 10000.
   * Moved from FTSDKConfig to FTRUMConfig.
   * When FTRUMConfig.setRumCacheLimitCount() is enabled, this count limit is ignored.
   */
  public setRumCacheLimitCount(limitCount: number): FTRUMConfig {
    this.rumCacheLimitCount = Math.max(Constants.MINI_DB_RUM_CACHE_NUM, limitCount);
    return this;
  }

  /**
   * Get maximum RUM entry count limit.
   */
  public getRumCacheLimitCount(): number {
    return this.rumCacheLimitCount;
  }

  /**
   * Set RUM cache discard strategy.
   */
  public setRumCacheDiscardStrategy(strategy: RUMCacheDiscard | string): FTRUMConfig {
    this.rumCacheDiscardStrategy =
      String(strategy) === RUMCacheDiscard.DISCARD_OLDEST ? RUMCacheDiscard.DISCARD_OLDEST : RUMCacheDiscard.DISCARD;
    return this;
  }

  /**
   * Get RUM cache discard strategy.
   */
  public getRumCacheDiscardStrategy(): RUMCacheDiscard {
    return this.rumCacheDiscardStrategy;
  }

  public isEnableTrackAppCrash(): boolean {
    return this.enableTrackAppCrash;
  }

  public setEnableTrackAppCrash(enableTrackAppCrash: boolean): FTRUMConfig {
    this.enableTrackAppCrash = enableTrackAppCrash;
    return this;
  }


  public isEnableTrackAppUIBlock(): boolean {
    return this.enableTrackAppUIBlock;
  }

  /**
   * Set UI block detection
   * @param enableTrackAppUIBlock Whether to enable UI block detection
   * @param blockDurationMs Optional block duration threshold in milliseconds, range [100, ), default 1000ms
   * @returns FTRUMConfig instance for method chaining
   */
  public setEnableTrackAppUIBlock(enableTrackAppUIBlock: boolean, blockDurationMs?: number): FTRUMConfig {
    this.enableTrackAppUIBlock = enableTrackAppUIBlock;
    // If blockDurationMs is provided, set it (ensure it's at least 100ms)
    if (blockDurationMs !== undefined) {
      this.blockDurationMS = Math.max(100, blockDurationMs);
    }
    return this;
  }

  /**
   * Get block duration in milliseconds
   * @returns Block duration in milliseconds
   */
  public getBlockDurationMS(): number {
    return this.blockDurationMS;
  }

  public isEnableTrackAppANR(): boolean {
    return this.enableTrackAppANR;
  }

  public setEnableTrackAppANR(enableTrackAppANR: boolean): FTRUMConfig {
    this.enableTrackAppANR = enableTrackAppANR;
    return this;
  }

  // public setEnableTrackAppANRWithLogSetting(
  //   enableTrackAppANR: boolean,
  //   extraLogCatWithANR: ExtraLogCatSetting
  // ): FTRUMConfig {
  //   this.enableTrackAppANR = enableTrackAppANR;
  //   this.extraLogCatWithANR = extraLogCatWithANR;
  //   return this;
  // }

  public isEnableTraceUserAction(): boolean {
    return this.enableTraceUserAction;
  }

  public setEnableTraceUserAction(enableTraceUserAction: boolean): FTRUMConfig {
    this.enableTraceUserAction = enableTraceUserAction;
    return this;
  }

  public isEnableTraceUserView(): boolean {
    return this.enableTraceUserView;
  }

  public setEnableTraceUserView(enableTraceUserView: boolean): FTRUMConfig {
    this.enableTraceUserView = enableTraceUserView;
    return this;
  }

  public isEnableTraceUserResource(): boolean {
    return this.enableTraceUserResource;
  }

  public setEnableTraceUserResource(enableTraceUserResource: boolean): FTRUMConfig {
    this.enableTraceUserResource = enableTraceUserResource;
    return this;
  }

  public isEnableTraceWebView(): boolean {
    return this.enableTraceWebView;
  }

  public setEnableTraceWebView(enableTraceWebView: boolean): FTRUMConfig {
    this.enableTraceWebView = enableTraceWebView;
    return this;
  }

  // public getExtraMonitorTypeWithError(): number {
  //   return this.extraMonitorTypeWithError;
  // }
  //
  // public setExtraMonitorTypeWithError(extraMonitorTypeWithError: number): FTRUMConfig {
  //   this.extraMonitorTypeWithError = extraMonitorTypeWithError;
  //   return this;
  // }
  //
  // public getDeviceMetricsMonitorType(): number {
  //   return this.deviceMetricsMonitorType;
  // }
  //
  // public setDeviceMetricsMonitorType(deviceMetricsMonitorType: number): FTRUMConfig {
  //   this.deviceMetricsMonitorType = deviceMetricsMonitorType;
  //   return this;
  // }
  //
  // public setDeviceMetricsMonitorTypeWithFrequency(
  //   deviceMetricsMonitorType: number,
  //   frequency: DetectFrequency
  // ): FTRUMConfig {
  //   this.deviceMetricsMonitorType = deviceMetricsMonitorType;
  //   this.deviceMetricsDetectFrequency = frequency;
  //   return this;
  // }

  public addGlobalContext(key: string, value: object): FTRUMConfig {
    this.globalContext.set(key, value);
    return this;
  }

  public getGlobalContext(): Map<string, object> {
    return this.globalContext;
  }

  /**
   * Get action tracking handler
   * Aligned with Android SDK: FTRUMConfig.getActionTrackingHandler()
   */
  public getActionTrackingHandler(): FTActionTrackingHandler | null {
    return this.actionTrackingHandler;
  }

  /**
   * Set action tracking handler
   * Allows customization of which actions should be tracked and how
   * Aligned with Android SDK: FTRUMConfig.setActionTrackingHandler(FTActionTrackingHandler)
   * 
   * @param handler Action tracking handler, or null to use default behavior
   * @returns FTRUMConfig instance for method chaining
   */
  public setActionTrackingHandler(handler: FTActionTrackingHandler | null): FTRUMConfig {
    this.actionTrackingHandler = handler;
    return this;
  }

  /**
   * Get extra monitor type with error
   */
  public getExtraMonitorTypeWithError(): number {
    return this.extraMonitorTypeWithError;
  }

  /**
   * Set extra monitor type with error
   */
  public setExtraMonitorTypeWithError(extraMonitorTypeWithError: number): FTRUMConfig {
    this.extraMonitorTypeWithError = extraMonitorTypeWithError;
    return this;
  }

  /**
   * Get device metrics monitor type
   */
  public getDeviceMetricsMonitorType(): number {
    return this.deviceMetricsMonitorType;
  }

  public isEnableResourceHostIP(): boolean {
    return this.enableResourceHostIP;
  }

  public setEnableResourceHostIP(enableResourceHostIP: boolean): FTRUMConfig {
    this.enableResourceHostIP = enableResourceHostIP;
    return this;
  }

  public setResourceUrlHandler(handler: FTInTakeUrlHandler): FTRUMConfig {
    this.intTakeUrlHandler = handler;
    return this;
  }

  public getResourceUrlHandler(): FTInTakeUrlHandler | null {
    return this.intTakeUrlHandler;
  }

  /**
   * Set device metrics monitor type
   */
  public setDeviceMetricsMonitorType(deviceMetricsMonitorType: number): FTRUMConfig {
    this.deviceMetricsMonitorType = deviceMetricsMonitorType;
    return this;
  }

  /**
   * Get device metrics detect frequency
   */
  public getDeviceMetricsDetectFrequency(): DetectFrequency {
    return this.deviceMetricsDetectFrequency;
  }

  /**
   * Set device metrics detect frequency
   */
  public setDeviceMetricsDetectFrequency(deviceMetricsDetectFrequency: DetectFrequency): FTRUMConfig {
    this.deviceMetricsDetectFrequency = deviceMetricsDetectFrequency;
    return this;
  }

  // public getExtraLogCatWithJavaCrash(): ExtraLogCatSetting | null {
  //   return this.extraLogCatWithJavaCrash;
  // }
  //
  // public getExtraLogCatWithNativeCrash(): ExtraLogCatSetting | null {
  //   return this.extraLogCatWithNativeCrash;
  // }
  //
  // public getExtraLogCatWithANR(): ExtraLogCatSetting | null {
  //   return this.extraLogCatWithANR;
  // }
}

/**
 * Interface for Status class instance (from bean/Status.ets)
 * Used for type checking in setLogLevelFilters
 */
interface StatusWithName {
  name?: string;
}

export class FTLoggerConfig {
  /**
   * Sampling rate, [0,1]
   */
  private samplingRate: number = 1;
  /**
   * Whether to link with RUM data
   */
  private enableLinkRumData: boolean = false;
  /**
   * Whether to enable console log output
   */
  private enableConsoleLog: boolean = false;
  /**
   * Whether to enable custom log
   */
  private enableCustomLog: boolean = false;
  /**
   * Service name {@link Constants#KEY_SERVICE }, defaults to {@link Constants#DEFAULT_SERVICE_NAME}
   */
  private serviceName: string = Constants.DEFAULT_SERVICE_NAME;
  /**
   * Log filter prefix
   */
  private logPrefix: string = "";
  private logCacheLimitCount: number = Constants.DEFAULT_DB_LOG_CACHE_NUM;
  /**
   * Log level filters
   */
  private logLevelFilters: Array<string> = [];
  /**
   * Global context tags
   */
  private globalContext: Map<string, LogGlobalContextValue> = new Map();
  /**
   * Log data database storage strategy
   */
  private logCacheDiscardStrategy: LogCacheDiscard = LogCacheDiscard.DISCARD;
  /**
   * Custom log print configuration
   */
  private printCustomLogToConsole: boolean = false;

  /**
   * Get sampling rate
   */
  public getSamplingRate(): number {
    return this.samplingRate;
  }

  /**
   * Set sampling rate
   */
  setSamplingRate(samplingRate: number = 1.0): FTLoggerConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /**
   * Check if RUM data linking is enabled
   */
  isEnableLinkRumData(): boolean {
    return this.enableLinkRumData;
  }

  /**
   * Set whether to enable RUM data linking
   */
  setEnableLinkRumData(enableLinkRumData: boolean): FTLoggerConfig {
    this.enableLinkRumData = enableLinkRumData;
    return this;
  }

  /**
   * Check if custom log is enabled
   */
  isEnableCustomLog(): boolean {
    return this.enableCustomLog;
  }

  setEnableCustomLog(enableCustomLog: boolean): FTLoggerConfig {
    this.enableCustomLog = enableCustomLog;
    return this;
  }

  /**
   * Get service name
   */
  getServiceName(): string {
    return this.serviceName;
  }

  setServiceName(serviceName: string): void {
    this.serviceName = serviceName;
  }

  /**
   * Get log cache strategy
   */
  getLogCacheDiscardStrategy(): LogCacheDiscard {
    return this.logCacheDiscardStrategy;
  }

  /**
   * Set database data storage strategy
   */
  setLogCacheDiscardStrategy(strategy: LogCacheDiscard | string): FTLoggerConfig {
    this.logCacheDiscardStrategy =
      String(strategy) === LogCacheDiscard.DISCARD_OLDEST ? LogCacheDiscard.DISCARD_OLDEST : LogCacheDiscard.DISCARD;
    return this;
  }

  /**
   * Set log level filters
   * Aligned with Android: setLogLevelFilters(Status[]) and setLogLevelFilters(String[])
   * @param logLevelFilters Array of Status class instances, named status-like objects, or string values
   */
  setLogLevelFilters(logLevelFilters: Array<Status | string | StatusWithName>): FTLoggerConfig {
    const array: Array<string> = [];
    for (let i = 0; i < logLevelFilters.length; i++) {
      const item: Status | string | StatusWithName = logLevelFilters[i];
      if (typeof item === 'string') {
        const status = Status.fromName(item);
        array.push(status ? status.name : (item as string));
      } else if (item && typeof item === 'object') {
        // Check if it's a Status class instance (has .name property)
        // Use type assertion to access .name property
        const statusObj: StatusWithName = item as StatusWithName;
        if (statusObj.name !== undefined && typeof statusObj.name === 'string') {
          array.push(statusObj.name);
        } else {
          array.push(String(item));
        }
      } else {
        const statusValue: string = String(item);
        array.push(statusValue);
      }
    }
    this.logLevelFilters = array;
    return this;
  }

  /**
   * Get log level filters
   * Aligned with Android: getLogLevelFilters()
   */
  getLogLevelFilters(): Array<string> {
    return this.logLevelFilters;
  }

  /**
   * Check if custom log printing is enabled
   * Aligned with Android: isPrintCustomLogToConsole() - returns !TrackLog.isSetInnerLogHandler() && printCustomLogToConsole
   * Note: HarmonyOS doesn't have inner log handler mechanism, so returns printCustomLogToConsole directly
   */
  isPrintCustomLogToConsole(): boolean {
    // Android: return !TrackLog.isSetInnerLogHandler() && printCustomLogToConsole;
    // HarmonyOS: no inner log handler, return directly
    return this.printCustomLogToConsole;
  }

  /**
   * Set whether to print custom logs to console
   */
  setPrintCustomLogToConsole(printCustomLogToConsole: boolean): FTLoggerConfig {
    this.printCustomLogToConsole = printCustomLogToConsole;
    return this;
  }

  /**
   * Set maximum log entry count, minimum not less than 1000.
   * Moved from FTSDKConfig to FTLoggerConfig.
   * When FTLoggerConfig.setLogCacheLimitCount() is enabled, this count limit is ignored.
   */
  setLogCacheLimitCount(count: number): FTLoggerConfig {
    this.logCacheLimitCount = Math.max(Constants.MINI_DB_LOG_CACHE_NUM, count);
    return this;
  }

  /**
   * Get maximum log entry count limit
   */
  getLogCacheLimitCount(): number {
    return this.logCacheLimitCount;
  }

  /**
   * Check if contains prefix setting
   */
  checkPrefix(message: string): boolean {
    return this.logPrefix === "" || message.startsWith(this.logPrefix);
  }

  /**
   * Check if contains log level setting
   */
  checkLogLevel(status: string): boolean {
    return !this.logLevelFilters || this.logLevelFilters.length === 0 || this.logLevelFilters.includes(status);
  }

  /**
   * Add log global context.
   * Aligned with Android: addGlobalContext(Map<String, Object>) and addGlobalContext(String, Object).
   */
  addGlobalContext(globalContext: LogGlobalContextDictionary): FTLoggerConfig;
  addGlobalContext(key: string, value: LogGlobalContextValue): FTLoggerConfig;
  addGlobalContext(keyOrContext: string | LogGlobalContextDictionary,
    value?: LogGlobalContextValue): FTLoggerConfig {
    if (typeof keyOrContext === 'string') {
      this.putGlobalContextValue(keyOrContext, value);
      return this;
    }

    if (keyOrContext instanceof Map) {
      keyOrContext.forEach((contextValue: LogGlobalContextValue, contextKey: string) => {
        this.putGlobalContextValue(contextKey, contextValue);
      });
      return this;
    }

    const contextRecord = keyOrContext as Record<string, LogGlobalContextValue>;
    const keys = Object.keys(contextRecord);
    for (let i = 0; i < keys.length; i++) {
      const contextKey = keys[i];
      this.putGlobalContextValue(contextKey, contextRecord[contextKey]);
    }
    return this;
  }

  private putGlobalContextValue(key: string, value: LogGlobalContextValue): void {
    if (!key || value === null || value === undefined) {
      return;
    }
    this.globalContext.set(key, value);
  }

  getGlobalContext(): Map<string, LogGlobalContextValue> {
    return this.globalContext;
  }

  /**
   * Check if console log capture is enabled
   */
  isEnableConsoleLog(): boolean {
    return this.enableConsoleLog;
  }

  /**
   * Set whether to enable console log capture
   * Aligned with Android: setEnableConsoleLog(boolean) and setEnableConsoleLog(boolean, String)
   * @param enableConsoleLog Whether to enable console log capture
   * @param prefix Optioal log filter prefix
   */
  setEnableConsoleLog(enableConsoleLog: boolean, prefix?: string): FTLoggerConfig {
    this.enableConsoleLog = enableConsoleLog;
    if (prefix !== undefined) {
      this.logPrefix = prefix;
    }
    return this;
  }
}

export class FTSDKConfig {
  // DataKit data write address
  private datakitUrl: string;
  // DataWay data write address
  private datawayUrl: string;
  // Client token
  private clientToken: string;
  // Whether to enable Debug
  private isDebug: boolean = false;
  // SDK internal log threshold, aligned with Android SDKLogLevel.
  private sdkLogLevel: SDKLogLevel = SDKLogLevel.V;
  // Whether to access device ID
  private : boolean = true;
  // Whether to perform auto sync
  private autoSync: boolean = true;
  // Data sync page size
  private pageSize: number = SyncPageSize.MEDIUM;
  // Data sync sleep time
  private syncSleepTime: number = 0;
  // Service name
  private serviceName: string = Constants.DEFAULT_SERVICE_NAME;
  // Data sync max retry count
  private dataSyncRetryCount: number = SyncTaskManager.MAX_ERROR_COUNT;
  // Data upload environment
  private env: string = EnvType.PROD.toString();
  // Whether to only support main process initialization
  private onlySupportMainProcess: boolean = true;
  // Whether to migrate old data
  private needTransformOldCache: boolean = false;
  // Global parameters
  private globalContext: Map<string, object> = new Map();
  // SDK package info (for sdk_pkg_info)
  private pkgInfo: Map<string, string> = new Map();
  // Data modifiers
  private dataModifier: DataModifier | null = null;
  private lineDataModifier: LineDataModifier | null = null;
  private enableAccessDeviceID: boolean = false;
  // Data integer compatible mode (using m_ prefix to avoid method name conflict)
  private mEnableDataIntegerCompatible: boolean = false;


  // Cache limit configurations
  private dbCacheLimit: number = Constants.DEFAULT_CACHE_LIMIT_SIZE;
  private limitWithDbSize: boolean = false;
  private dbCacheDiscard: string = DBCacheDiscard.DISCARD;
  private logCacheDiscard: string = LogCacheDiscard.DISCARD;
  private enableInnerLogFile: boolean = false;
  private innerLogFileConfig: FTInnerLogFileConfig = {};

  // Constructor
  private constructor(datakitUrl: string = '', datawayUrl: string = '', clientToken: string = '') {
    this.datakitUrl = datakitUrl;
    this.datawayUrl = datawayUrl;
    this.clientToken = clientToken;
  }

  // Static method to create FTSDKConfig object
  static builder(datakitUrl: string): FTSDKConfig;
  static builder(datawayUrl: string, clientToken: string): FTSDKConfig;
  static builder(datakitUrlOrDatawayUrl: string, clientToken?: string): FTSDKConfig {
    if (clientToken !== undefined) {
      return new FTSDKConfig('', datakitUrlOrDatawayUrl, clientToken);
    } else {
      return new FTSDKConfig(datakitUrlOrDatawayUrl);
    }
  }


  // Getter and Setter methods
  getDatakitUrl(): string {
    return this.datakitUrl;
  }

  getDatawayUrl(): string {
    return this.datawayUrl;
  }

  getClientToken(): string {
    return this.clientToken;
  }

  isDebugMode(): boolean {
    return this.isDebug;
  }

  setDebug(debug: boolean): FTSDKConfig {
    this.isDebug = debug;
    return this;
  }

  /**
   * Set the SDK internal log threshold. This only takes effect when debug mode is enabled.
   */
  setSdkLogLevel(logLevel: SDKLogLevel): FTSDKConfig {
    this.sdkLogLevel = logLevel;
    return this;
  }

  getSdkLogLevel(): SDKLogLevel {
    return this.sdkLogLevel;
  }

  setEnableInnerLogFile(enable: boolean, config?: FTInnerLogFileConfig): FTSDKConfig {
    this.enableInnerLogFile = enable;
    if (config !== undefined) {
      this.innerLogFileConfig = {
        singleFileMaxSize: config.singleFileMaxSize,
        totalFileMaxSize: config.totalFileMaxSize,
        flushBatchSize: config.flushBatchSize,
        flushIntervalMs: config.flushIntervalMs
      };
    }
    return this;
  }

  isEnableInnerLogFile(): boolean {
    return this.enableInnerLogFile;
  }

  getInnerLogFileConfig(): FTInnerLogFileConfig {
    return {
      singleFileMaxSize: this.innerLogFileConfig.singleFileMaxSize,
      totalFileMaxSize: this.innerLogFileConfig.totalFileMaxSize,
      flushBatchSize: this.innerLogFileConfig.flushBatchSize,
      flushIntervalMs: this.innerLogFileConfig.flushIntervalMs
    };
  }

  getEnv(): string {
    return this.env;
  }

  setEnv(env: EnvType | string): FTSDKConfig {
    if (env) {
      // EnvType is a string enum, so its values are already strings
      // Convert to string to handle both enum and string types
      this.env = String(env);
    }
    return this;
  }

  setAutoSync(autoSync: boolean): FTSDKConfig {
    this.autoSync = autoSync;
    return this;
  }

  isAutoSyncEnabled(): boolean {
    return this.autoSync;
  }

  setSyncPageSize(pageSize: SyncPageSize | number): FTSDKConfig {
    this.pageSize = Math.max(SyncPageSize.MINI, pageSize);
    return this;
  }

  getPageSize(): number {
    return this.pageSize;
  }

  addGlobalContext(key: string, value: object): FTSDKConfig {
    this.globalContext.set(key, value);
    return this;
  }

  getGlobalContext(): Map<string, object> {
    return this.globalContext;
  }

  getServiceName(): string {
    return this.serviceName;
  }

  setServiceName(serviceName: string): FTSDKConfig {
    if (serviceName) {
      this.serviceName = serviceName;
    }
    return this;
  }

  getDataSyncRetryCount(): number {
    return this.dataSyncRetryCount;
  }

  setDataSyncRetryCount(dataSyncRetryCount: number): FTSDKConfig {
    this.dataSyncRetryCount = Math.max(0, Math.min(SyncTaskManager.MAX_ERROR_COUNT, dataSyncRetryCount));
    return this;
  }

  setSyncSleepTime(sleepTimeMs: number): FTSDKConfig {
    this.syncSleepTime =
      Math.max(SyncTaskManager.SYNC_SLEEP_MINI_TIME_MS, Math.min(sleepTimeMs, SyncTaskManager.SYNC_SLEEP_MAX_TIME_MS));
    return this;
  }

  getSyncSleepTime(): number {
    return this.syncSleepTime;
  }

  /**
   * Get line data modifier
   */
  getLineDataModifier(): LineDataModifier | null {
    return this.lineDataModifier;
  }

  /**
   * Set line data modifier
   */
  setLineDataModifier(lineDataModifier: LineDataModifier | null): FTSDKConfig {
    this.lineDataModifier = lineDataModifier;
    return this;
  }

  /**
   * Enable data integer compatible mode
   * When enabled, integer values are output without "i" suffix in Line Protocol
   * Aligned with Android: enableDataIntegerCompatible()
   * @returns FTSDKConfig instance for chaining
   */
  enableDataIntegerCompatible(): FTSDKConfig {
    this.mEnableDataIntegerCompatible = true;
    return this;
  }

  /**
   * Check if data integer compatible mode is enabled
   * Aligned with Android: isDataIntegerCompatible()
   * @returns true if integer compatible mode is enabled
   */
  isDataIntegerCompatible(): boolean {
    return this.mEnableDataIntegerCompatible;
  }

  // Cache limit methods
  /**
   * Set log cache discard strategy
   */
  setLogCacheDiscard(strategy: string | LogCacheDiscard): FTSDKConfig {
    this.logCacheDiscard = String(strategy);
    return this;
  }

  /**
   * Get log cache discard strategy
   */
  getLogCacheDiscard(): string {
    return this.logCacheDiscard;
  }

  setEnableAccessDeviceID(enableAccessDeviceID: boolean): FTSDKConfig {
    this.enableAccessDeviceID = enableAccessDeviceID;
    return this;
  }

  isAccessODIDEnabled(): boolean {
    return this.enableAccessDeviceID;
  }

  setOnlySupportMainProcess(onlySupportMainProcess: boolean): FTSDKConfig {
    this.onlySupportMainProcess = onlySupportMainProcess;
    return this;
  }

  isOnlySupportMainProcess(): boolean {
    return this.onlySupportMainProcess;
  }

  /**
   * Add SDK package info (for sdk_pkg_info field)
   * Similar to Android's addPkgInfo method
   * @param key Package info key (e.g., "agent", "track", "native", "web")
   * @param value Package version value
   * @returns FTSDKConfig instance for chaining
   */
  addPkgInfo(key: string, value: string): FTSDKConfig {
    if (key && value) {
      this.pkgInfo.set(key, value);
    }
    return this;
  }

  /**
   * Get SDK package info
   * Similar to Android's getPkgInfo method
   * @returns Map containing package info
   */
  getPkgInfo(): Map<string, string> {
    return this.pkgInfo;
  }

  setNeedTransformOldCache(needTransformOldCache: boolean): FTSDKConfig {
    this.needTransformOldCache = needTransformOldCache;
    return this;
  }

  isNeedTransformOldCache(): boolean {
    return this.needTransformOldCache;
  }

  /**
   * Get data modifier
   */
  getDataModifier(): DataModifier | null {
    return this.dataModifier;
  }

  /**
   * Set data modifier
   */
  setDataModifier(dataModifier: DataModifier | null): FTSDKConfig {
    this.dataModifier = dataModifier;
    return this;
  }

  /**
   * Enable database size limit.
   * Default limit is 100MB. When dbSize is provided, the minimum is 30MB.
   * When enabled, the database size policy takes priority over the log/RUM count limits
   * configured by FTLoggerConfig.setLogCacheLimitCount(...) and FTRUMConfig.setRumCacheLimitCount(...).
   */
  enableLimitWithDbSize(dbSize?: number): FTSDKConfig {
    if (dbSize !== undefined) {
      this.dbCacheLimit = Math.max(Constants.MINI_CACHE_LIMIT_SIZE, dbSize);
    }
    this.limitWithDbSize = true;
    return this;
  }

  /**
   * Set database cache limit with custom size.
   */
  setDbCacheLimit(dbSize: number): FTSDKConfig {
    return this.enableLimitWithDbSize(dbSize);
  }

  /**
   * Check if database size limit is enabled.
   * @deprecated Kept for old DB cache compatibility.
   */
  isLimitWithDbSize(): boolean {
    return this.limitWithDbSize;
  }

  /**
   * Get database cache limit in bytes.
   * @deprecated Kept for old DB cache compatibility.
   */
  getDbCacheLimit(): number {
    return this.dbCacheLimit;
  }

  /**
   * Get database cache discard strategy
   */
  getDBCacheDiscard(): string {
    return this.dbCacheDiscard;
  }

  /**
   * Set database cache discard strategy
   */
  setDbCacheDiscard(strategy: string | DBCacheDiscard): FTSDKConfig {
    this.dbCacheDiscard = String(strategy);
    return this;
  }
}

export class FTTraceConfig {
  /**
   * Sampling rate, [0,1]
   */
  private samplingRate: number = 1;
  /**
   * Trace type for link tracking
   */
  private traceType: TraceType = TraceType.DDTRACE;
  /**
   * Whether to enable auto HTTP trace
   */
  private enableAutoTrace: boolean = false;
  /**
   * Whether to link with RUM data
   */
  private enableLinkRUMData: boolean = false;
  /**
   * Whether to enable WebView trace
   */
  private enableWebTrace: boolean = false;
  /**
   * Service name, defaults to Constants.DEFAULT_SERVICE_NAME
   */
  serviceName: string = Constants.DEFAULT_SERVICE_NAME;
  /**
   * Custom Trace Header handler
   */
  private traceHeaderHandler: FTTraceHeaderHandler | null = null;
  /**
   * Global context tags
   */
  private globalContext: Map<string, object> = new Map();
  /**
   * Supported content types for trace
   */
  private traceContentType: string[] = [
    "application/json",
    "application/javascript",
    "application/xml",
    "application/x-www-form-urlencoded",
    "text/html",
    "text/xml",
    "text/plain",
    "multipart/form-data"
  ];

  /**
   * Get sampling rate
   */
  getSamplingRate(): number {
    return this.samplingRate;
  }

  /**
   * Set sampling rate
   */
  setSamplingRate(samplingRate: number = 1.0): FTTraceConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /**
   * Get trace type
   */
  getTraceType(): TraceType {
    return this.traceType;
  }

  /**
   * Set trace type
   */
  setTraceType(traceType: TraceType): FTTraceConfig {
    this.traceType = traceType;
    return this;
  }

  /**
   * Check if RUM data linking is enabled
   */
  isEnableLinkRUMData(): boolean {
    return this.enableLinkRUMData;
  }

  /**
   * Set whether to enable RUM data linking
   */
  setEnableLinkRUMData(enableLinkRUMData: boolean): FTTraceConfig {
    this.enableLinkRUMData = enableLinkRUMData;
    return this;
  }

  /**
   * Set service name
   */
  setServiceName(serviceName: string): FTTraceConfig {
    this.serviceName = serviceName;
    return this;
  }

  /**
   * Check if auto trace is enabled
   */
  isEnableAutoTrace(): boolean {
    return this.enableAutoTrace;
  }

  /**
   * Set whether to enable auto HTTP trace
   */
  setEnableAutoTrace(enableAutoTrace: boolean): FTTraceConfig {
    this.enableAutoTrace = enableAutoTrace;
    return this;
  }

  /**
   * Get custom Trace Header handler
   */
  getTraceHeaderHandler(): FTTraceHeaderHandler | null {
    return this.traceHeaderHandler;
  }

  /**
   * Set custom Trace Header handler
   */
  setTraceHeaderHandler(traceHeaderHandler: FTTraceHeaderHandler | null): FTTraceConfig {
    this.traceHeaderHandler = traceHeaderHandler;
    return this;
  }

  /**
   * Get service name
   */
  getServiceName(): string {
    return this.serviceName;
  }

  /**
   * Get supported content types for trace
   */
  getTraceContentType(): string[] {
    return this.traceContentType;
  }

  /**
   * Get global context
   */
  getGlobalContext(): Map<string, object> {
    return this.globalContext;
  }

  /**
   * Check if WebView trace is enabled
   */
  isEnableWebTrace(): boolean {
    return this.enableWebTrace;
  }

  /**
   * Set whether to enable WebView trace
   */
  setEnableWebTrace(enableWebTrace: boolean): FTTraceConfig {
    this.enableWebTrace = enableWebTrace;
    return this;
  }

  /**
   * Set global context
   */
  setGlobalContext(globalContext: Map<string, object>): FTTraceConfig {
    this.globalContext = globalContext;
    return this;
  }

  /**
   * Add global context item
   */
  addGlobalContext(key: string, value: object): FTTraceConfig {
    this.globalContext.set(key, value);
    return this;
  }

  /**
   * Set supported content types
   */
  setTraceContentType(contentTypes: string[]): FTTraceConfig {
    this.traceContentType = contentTypes;
    return this;
  }
}
