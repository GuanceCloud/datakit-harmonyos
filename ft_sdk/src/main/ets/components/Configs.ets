import { Constants } from "./Constants";
import { CacheDiscard, DataType, DBCacheDiscard, DetectFrequency, EnvType, LogCacheDiscard, RUMCacheDiscard, SDKLogLevel, SyncPageSize } from "./enum/Enums";
import { Status } from "./bean/Status";
import { FTDataFilter, FTDataFilterValue } from './FTDataFilter';
import { TraceType } from "./trace/TraceType";
import { SyncTaskManager } from "./SyncTaskManager";
import { FTInTakeUrlHandler } from "./http/FTInTakeUrlHandler";
import { FTTraceHeaderHandler } from "./trace/FTTraceHeaderHandler";
import { DataModifier, LineDataModifier } from "./DataModifier";
import { FTActionTrackingHandler } from "./rum/handler/FTActionTrackingHandler";
import { FTViewTrackingHandler } from "./rum/handler/FTViewTrackingHandler";
import { FTViewTrackingType } from "./rum/enum/FTViewTrackingType";
import { FTRemoteConfigFetchResult } from './remote/RemoteConfigTypes';
import { FTNetworkErrorHandler } from './network/FTNetworkErrorHandler';

export type LogGlobalContextValue = string | number | boolean | String | Number | Boolean | object | null | undefined;
export type LogGlobalContextDictionary = Map<string, LogGlobalContextValue> | Record<string, LogGlobalContextValue>;
/**
 * Local data-filter rules grouped by the supported categories: `logging` and `rum`.
 * A map is recommended for parity with Android's `setDataFilters(HashMap)` API.
 */
export type FTDataFilters = Map<string, Array<string>> | Record<string, Array<string>>;

/**
 * HTTP proxy settings for SDK upload requests.
 * `exclusionList` follows NetworkKit semantics and bypasses the proxy for matching hosts.
 */
export interface FTProxyConfig {
  host: string;
  port: number;
  exclusionList?: Array<string>;
  username?: string;
  password?: string;
}

/** Static credentials used when the configured upload proxy requires authentication. */
export interface FTProxyAuthenticator {
  username: string;
  password: string;
}

/**
 * Custom DNS settings for SDK upload requests.
 * NetworkKit accepts up to three DNS server addresses and an HTTPS DoH endpoint.
 */
export interface FTDnsConfig {
  servers?: Array<string>;
  overHttpsUrl?: string;
}

export interface FTInnerLogFileConfig {
  singleFileMaxSize?: number;
  totalFileMaxSize?: number;
  flushBatchSize?: number;
  flushIntervalMs?: number;
}

interface RuntimeUploadEndpoint {
  datakitUrl: string;
  datawayUrl: string;
  clientToken: string;
}

const runtimeUploadEndpointOverrides: Map<FTSDKConfig, RuntimeUploadEndpoint> = new Map();

function getRuntimeUploadEndpoint(config: FTSDKConfig): RuntimeUploadEndpoint | null {
  return runtimeUploadEndpointOverrides.get(config) ?? null;
}

/**
 * Converts the public percentage contract to the SDK's existing internal
 * probability contract. This is intentionally the only conversion performed
 * at the configuration boundary.
 */
function percentageToSamplingProbability(rate: number, name: string): number {
  if (!Number.isFinite(rate) || rate < 0 || rate > 100) {
    throw new RangeError(`${name} must be a finite number between 0 and 100`);
  }
  return rate / 100;
}

export class FTRUMConfig {
  // Property definitions
  private samplingRate: number = 1.0; // Sampling rate, range 0 to 1
  private sessionErrorSampleRate: number = 0.0; // Error sampling rate, range 0 to 1, default 0.0
  private sessionSamplingRate: number | null = null;
  private sessionOnErrorSamplingRate: number | null = null;
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
  private allowWebViewHost: Array<string> | null = null;
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
  // Default handler for automatically collected local network failures. A
  // client/session/chain-level handler takes precedence over this value.
  private networkErrorHandler: FTNetworkErrorHandler | null = null;
  private actionTrackingHandler: FTActionTrackingHandler | null = null;
  private viewRouterTrackingHandler: FTViewTrackingHandler | null = null;
  private viewNavigationTrackingHandler: FTViewTrackingHandler | null = null;
  private rumCacheLimitCount: number = Constants.DEFAULT_DB_RUM_CACHE_NUM;
  private rumCacheDiscardStrategy: RUMCacheDiscard = RUMCacheDiscard.DISCARD;

  // Method definitions
  /**
   * @deprecated Use getSessionSamplingRate(). This compatibility getter
   * returns the effective rate in the legacy [0,1] probability unit.
   */
  public getSamplingRate(): number {
    return this.sessionSamplingRate ?? this.samplingRate;
  }

  /**
   * @deprecated Use setSessionSamplingRate(). This compatibility setter
   * accepts the legacy [0,1] probability unit.
   */
  public setSamplingRate(samplingRate: number = 1.0): FTRUMConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /** Get the effective session sampling rate as a percentage in [0,100]. */
  public getSessionSamplingRate(): number {
    return this.getSamplingRate() * 100;
  }

  /**
   * Set the session sampling rate as a percentage in [0,100]. Decimals are
   * supported, so 0.1 represents 0.1% sampling.
   */
  public setSessionSamplingRate(samplingRate: number): FTRUMConfig {
    this.sessionSamplingRate = percentageToSamplingProbability(samplingRate, 'sessionSamplingRate');
    return this;
  }

  /**
   * Get error sampling rate
   */
  /**
   * @deprecated Use getSessionOnErrorSamplingRate(). This compatibility
   * getter returns the effective rate in the legacy [0,1] probability unit.
   */
  public getSessionErrorSampleRate(): number {
    return this.sessionOnErrorSamplingRate ?? this.sessionErrorSampleRate;
  }

  /**
   * Set error sampling rate
   * When the session is not sampled by setSamplingRate,
   * if an error occurs during the session, data within 1 minute before the error can be collected.
   * Range [0,1], 0 means no collection, 1 means full collection.
   * Default is 0.0, aligned with Android SDK.
   */
  /**
   * @deprecated Use setSessionOnErrorSamplingRate(). This compatibility
   * setter accepts the legacy [0,1] probability unit.
   */
  public setSessionErrorSampleRate(sessionErrorSampleRate: number = 0.0): FTRUMConfig {
    this.sessionErrorSampleRate = Math.min(1.0, Math.max(0, sessionErrorSampleRate));
    return this;
  }

  /** Get the effective error-session sampling rate as a percentage in [0,100]. */
  public getSessionOnErrorSamplingRate(): number {
    return this.getSessionErrorSampleRate() * 100;
  }

  /**
   * Set the error-session supplemental sampling rate as a percentage in
   * [0,100]. The default remains 0%, so unsampled sessions are not retained
   * after an error unless this is explicitly configured.
   */
  public setSessionOnErrorSamplingRate(samplingRate: number): FTRUMConfig {
    this.sessionOnErrorSamplingRate = percentageToSamplingProbability(
      samplingRate,
      'sessionOnErrorSamplingRate'
    );
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

  /** Limit the WebView bridge to the supplied host allow-list. Null allows all hosts. */
  public setAllowWebViewHost(allowWebViewHost: Array<string> | null): FTRUMConfig {
    this.allowWebViewHost = allowWebViewHost === null ? null : allowWebViewHost.slice();
    return this;
  }

  public getAllowWebViewHost(): Array<string> | null {
    return this.allowWebViewHost === null ? null : this.allowWebViewHost.slice();
  }

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
   * Customize automatic Router page and Navigation destination View collection.
   *
   * Requires setEnableTraceUserView(true). The target controls whether the
   * handler applies to Router pages, Navigation destinations, or both. When
   * the handler is null, the selected target keeps the default final-route-
   * segment View name.
   *
   * @param handler Handler used to rename, enrich, or filter automatic Views.
   * It receives a context containing the normalized View name, original route,
   * and source-specific transition details.
   * @param type Automatic View source to configure. Defaults to ALL.
   * @returns FTRUMConfig instance for method chaining.
   */
  public setViewTrackingHandler(
    handler: FTViewTrackingHandler | null,
    type: FTViewTrackingType = FTViewTrackingType.ALL
  ): FTRUMConfig {
    switch (type) {
      case FTViewTrackingType.ROUTER:
        this.viewRouterTrackingHandler = handler;
        break;
      case FTViewTrackingType.NAVIGATION:
        this.viewNavigationTrackingHandler = handler;
        break;
      case FTViewTrackingType.ALL:
        this.viewRouterTrackingHandler = handler;
        this.viewNavigationTrackingHandler = handler;
        break;
    }
    return this;
  }

  /**
   * Get the handler configured for an automatic View source.
   *
   * For ALL, returns the common handler only when Router and Navigation use
   * the same instance. It returns null when the two targets are configured
   * independently.
   */
  public getViewTrackingHandler(type: FTViewTrackingType): FTViewTrackingHandler | null {
    switch (type) {
      case FTViewTrackingType.ROUTER:
        return this.viewRouterTrackingHandler;
      case FTViewTrackingType.NAVIGATION:
        return this.viewNavigationTrackingHandler;
      case FTViewTrackingType.ALL:
        return this.viewRouterTrackingHandler === this.viewNavigationTrackingHandler
          ? this.viewRouterTrackingHandler
          : null;
    }
    return null;
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
   * Sets the default local Network Error handler for automatic RCP, NetworkKit
   * HTTP, and Axios Resource collection. It is used only when that individual
   * Session, client, or interceptor chain does not provide its own handler.
   * Pass null to clear the default.
   */
  public setNetworkErrorHandler(handler: FTNetworkErrorHandler | null): FTRUMConfig {
    this.networkErrorHandler = handler;
    return this;
  }

  /** Returns the global default local Network Error handler, if configured. */
  public getNetworkErrorHandler(): FTNetworkErrorHandler | null {
    return this.networkErrorHandler;
  }

  /**
   * Set device metrics collection types and optionally the sampling frequency.
   */
  public setDeviceMetricsMonitorType(
    deviceMetricsMonitorType: number,
    deviceMetricsDetectFrequency?: DetectFrequency
  ): FTRUMConfig {
    this.deviceMetricsMonitorType = deviceMetricsMonitorType;
    if (deviceMetricsDetectFrequency !== undefined) {
      this.deviceMetricsDetectFrequency = deviceMetricsDetectFrequency;
    }
    return this;
  }

  /**
   * Set the device metrics sampling frequency.
   *
   * Retained for source compatibility. New integrations should configure both
   * values with setDeviceMetricsMonitorType(deviceMetricsMonitorType, deviceMetricsDetectFrequency).
   */
  public setDeviceMetricsDetectFrequency(deviceMetricsDetectFrequency: DetectFrequency): FTRUMConfig {
    this.deviceMetricsDetectFrequency = deviceMetricsDetectFrequency;
    return this;
  }

  /**
   * Get device metrics detect frequency.
   */
  public getDeviceMetricsDetectFrequency(): DetectFrequency {
    return this.deviceMetricsDetectFrequency;
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
  private logSamplingRate: number | null = null;
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
   * Legacy console/HiLog capture prefix. A filter-rule value is compiled into
   * consoleLogFilter and evaluated before the log enters the worker mailbox.
   *
   * This is intentionally independent from FTLogger custom logs. It mirrors
   * Android's setEnableConsoleLog(enable, prefix) behavior.
   */
  private consoleLogPrefix: string = "";
  private consoleLogFilter: FTDataFilter | null = null;
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
   * @deprecated Use getLogSamplingRate(). This compatibility getter returns
   * the effective rate in the legacy [0,1] probability unit.
   */
  public getSamplingRate(): number {
    return this.logSamplingRate ?? this.samplingRate;
  }

  /**
   * @deprecated Use setLogSamplingRate(). This compatibility setter accepts
   * the legacy [0,1] probability unit.
   */
  public setSamplingRate(samplingRate: number = 1.0): FTLoggerConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /** Get the effective log sampling rate as a percentage in [0,100]. */
  public getLogSamplingRate(): number {
    return this.getSamplingRate() * 100;
  }

  /** Set the log sampling rate as a percentage in [0,100]. */
  public setLogSamplingRate(samplingRate: number): FTLoggerConfig {
    this.logSamplingRate = percentageToSamplingProbability(samplingRate, 'logSamplingRate');
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
   * Check whether a console/HiLog message matches the configured filter.
   *
   * A plain value keeps the legacy `startsWith` prefix behavior. A value whose
   * first non-whitespace character is `{` is interpreted as a
   * DataKit-compatible allow rule for auto-collected console/HiLog logs.
   * A matching rule keeps the log; a non-matching rule drops it before it is
   * queued. Consecutive rule blocks have OR semantics.
   */
  checkConsoleLogFilter(message: string, source: string = 'console', tag: string = '', domain: string = ''): boolean {
    if (this.consoleLogFilter === null) {
      return this.consoleLogPrefix === "" || message.startsWith(this.consoleLogPrefix);
    }

    const tags = new Map<string, FTDataFilterValue>();
    tags.set('log_source', source);
    if (tag.length > 0) {
      tags.set('tag', tag);
    }
    if (domain.length > 0) {
      tags.set('domain', domain);
    }
    const fields = new Map<string, FTDataFilterValue>();
    fields.set(Constants.KEY_MESSAGE, message);
    return this.consoleLogFilter.matches(DataType.LOG, Constants.FT_LOG_DEFAULT_MEASUREMENT, tags, fields);
  }

  /**
   * @deprecated Use checkConsoleLogFilter. This compatibility helper assumes
   * a console source because it has no HiLog metadata.
   */
  checkConsoleLogPrefix(message: string): boolean {
    return this.checkConsoleLogFilter(message);
  }

  /**
   * @deprecated Use checkConsoleLogPrefix. Kept for source compatibility.
   */
  checkPrefix(message: string): boolean {
    return this.checkConsoleLogPrefix(message);
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
   * @param prefix Optional console/HiLog capture filter. A plain string is a
   * legacy message prefix; a value beginning with `{` is a DataKit-compatible
   * allow rule. Supported rule keys are `message`, `log_source`, `tag`, and
   * `domain`. Log level remains controlled exclusively by
   * setLogLevelFilters(...). For example:
   *
   * ```ts
   * // Keep automatic console and HiLog logs whose message begins with [business].
   * new FTLoggerConfig().setEnableConsoleLog(true, '[business]');
   *
   * // Keep only HiLog records from the Network tag whose rendered message
   * // begins with HTTP. Other automatic logs are not queued.
   * new FTLoggerConfig().setEnableConsoleLog(true,
   *   "{ log_source = 'hilog' and tag = 'Network' and message match ['^HTTP'] }");
   * ```
   */
  setEnableConsoleLog(enableConsoleLog: boolean, prefix?: string): FTLoggerConfig {
    this.enableConsoleLog = enableConsoleLog;
    if (prefix !== undefined) {
      this.consoleLogPrefix = prefix;
      this.consoleLogFilter = this.compileConsoleLogFilter(prefix);
    }
    return this;
  }

  private compileConsoleLogFilter(prefix: string): FTDataFilter | null {
    if (!prefix.trim().startsWith('{')) {
      return null;
    }
    const filters = new Map<string, Array<string>>();
    filters.set(FTDataFilter.CATEGORY_LOGGING, [prefix]);
    return FTDataFilter.compile(filters);
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
  // Whether intake requests are sent with zlib-wrapped deflate compression.
  private compressIntakeRequests: boolean = true;
  // Optional network routing settings used only by SDK upload requests.
  private proxy: FTProxyConfig | null = null;
  private proxyAuthenticator: FTProxyAuthenticator | null = null;
  private dns: FTDnsConfig | null = null;
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
  // Local data filtering is enabled by default, matching Android SDK behavior.
  private enableDataFilter: boolean = true;
  private dataFilters: Map<string, Array<string>> = new Map();
  private enableAccessDeviceID: boolean = false;
  // Data integer compatible mode (using m_ prefix to avoid method name conflict)
  private mEnableDataIntegerCompatible: boolean = false;


  // SDK-wide telemetry cache limit configuration. The legacy `db*` API is
  // retained below as aliases so existing integrations keep their behavior.
  private cacheLimit: number = Constants.DEFAULT_CACHE_LIMIT_SIZE;
  private limitWithCacheSize: boolean = false;
  private cacheDiscard: string = CacheDiscard.DISCARD;
  // FileStore is opt-in. Shadow mode keeps SQLite as the read/upload index
  // while mirroring accepted telemetry to FileStore for migration validation.
  private fileDataStoreEnabled: boolean = false;
  private useFileDataStore: boolean = false;
  private fileDataStoreShadow: boolean = false;
  private logCacheDiscard: string = LogCacheDiscard.DISCARD;
  private enableInnerLogFile: boolean = false;
  private innerLogFileConfig: FTInnerLogFileConfig = {};
  // Remote configuration is opt-in, matching Android SDK defaults.
  private remoteConfiguration: boolean = false;
  private remoteConfigFetchResult: FTRemoteConfigFetchResult | null = null;
  private remoteConfigMiniUpdateInterval: number = 43200;

  // Constructor
  private constructor(datakitUrl: string = '', datawayUrl: string = '', clientToken: string = '') {
    this.datakitUrl = datakitUrl;
    this.datawayUrl = datawayUrl;
    this.clientToken = clientToken;
  }

  // Static method to create FTSDKConfig object
  static builder(): FTSDKConfig;
  static builder(datakitUrl: string): FTSDKConfig;
  static builder(datawayUrl: string, clientToken: string): FTSDKConfig;
  static builder(datakitUrlOrDatawayUrl?: string, clientToken?: string): FTSDKConfig {
    if (datakitUrlOrDatawayUrl === undefined) {
      return new FTSDKConfig();
    }
    if (clientToken !== undefined) {
      return new FTSDKConfig('', datakitUrlOrDatawayUrl, clientToken);
    } else {
      return new FTSDKConfig(datakitUrlOrDatawayUrl);
    }
  }


  // Getter and Setter methods
  getDatakitUrl(): string {
    return getRuntimeUploadEndpoint(this)?.datakitUrl ?? this.datakitUrl;
  }

  getDatawayUrl(): string {
    return getRuntimeUploadEndpoint(this)?.datawayUrl ?? this.datawayUrl;
  }

  getClientToken(): string {
    return getRuntimeUploadEndpoint(this)?.clientToken ?? this.clientToken;
  }

  /**
   * Replace the active intake endpoint with a DataKit endpoint.
   * DataKit and Dataway are mutually exclusive upload modes.
   */
  setDatakitUrl(datakitUrl: string): FTSDKConfig {
    this.datakitUrl = datakitUrl;
    this.datawayUrl = '';
    this.clientToken = '';
    return this;
  }

  /**
   * Replace the active intake endpoint with a Dataway endpoint and client token.
   * DataKit and Dataway are mutually exclusive upload modes.
   */
  setDatawayUrl(datawayUrl: string, clientToken: string): FTSDKConfig {
    this.datawayUrl = datawayUrl;
    this.clientToken = clientToken;
    this.datakitUrl = '';
    return this;
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

  /**
   * Enable or disable deflate compression for data intake requests.
   * Compression is enabled by default, matching the Android SDK behavior.
   */
  setCompressIntakeRequests(compressIntakeRequests: boolean): FTSDKConfig {
    this.compressIntakeRequests = compressIntakeRequests;
    return this;
  }

  isCompressIntakeRequests(): boolean {
    return this.compressIntakeRequests;
  }

  /**
   * Enable configuration updates fetched from DataKit or Dataway. The default
   * is disabled to preserve existing SDK initialization behaviour.
   */
  setRemoteConfiguration(remoteConfiguration: boolean): FTSDKConfig {
    this.remoteConfiguration = remoteConfiguration;
    return this;
  }

  isRemoteConfiguration(): boolean {
    return this.remoteConfiguration;
  }

  /** Set the callback invoked after a remote configuration fetch attempt. */
  setRemoteConfigurationCallBack(fetchResult: FTRemoteConfigFetchResult | null): FTSDKConfig {
    this.remoteConfigFetchResult = fetchResult;
    return this;
  }

  getRemoteConfigFetchResult(): FTRemoteConfigFetchResult | null {
    return this.remoteConfigFetchResult;
  }

  /**
   * Set the minimum interval between remote configuration fetches, in seconds.
   * Values below zero are normalized to zero so callers can intentionally force
   * an immediate refresh with a zero interval.
   */
  setRemoteConfigMiniUpdateInterval(intervalSeconds: number): FTSDKConfig {
    const normalized = intervalSeconds !== intervalSeconds ? 43200 : Math.floor(intervalSeconds);
    this.remoteConfigMiniUpdateInterval = Math.max(0, normalized);
    return this;
  }

  getRemoteConfigMiniUpdateInterval(): number {
    return this.remoteConfigMiniUpdateInterval;
  }

  /** Set the HTTP proxy used by SDK upload requests. */
  setProxy(proxy: FTProxyConfig | null): FTSDKConfig {
    this.proxy = proxy === null ? null : {
      host: proxy.host,
      port: proxy.port,
      exclusionList: proxy.exclusionList ? proxy.exclusionList.slice() : [],
      username: proxy.username,
      password: proxy.password
    };
    return this;
  }

  getProxy(): FTProxyConfig | null {
    if (this.proxy === null) {
      return null;
    }
    return {
      host: this.proxy.host,
      port: this.proxy.port,
      exclusionList: this.proxy.exclusionList ? this.proxy.exclusionList.slice() : [],
      username: this.proxy.username,
      password: this.proxy.password
    };
  }

  /**
   * Set static credentials for the configured upload proxy.
   * NetworkKit does not expose an OkHttp-style authentication callback, so credentials are supplied per request.
   */
  setProxyAuthenticator(authenticator: FTProxyAuthenticator | null): FTSDKConfig {
    this.proxyAuthenticator = authenticator === null ? null : {
      username: authenticator.username,
      password: authenticator.password
    };
    return this;
  }

  getProxyAuthenticator(): FTProxyAuthenticator | null {
    if (this.proxyAuthenticator === null) {
      return null;
    }
    return {
      username: this.proxyAuthenticator.username,
      password: this.proxyAuthenticator.password
    };
  }

  /**
   * Set the DNS servers or DNS-over-HTTPS endpoint used by SDK upload requests.
   * Empty server values are ignored and only the first three are passed to NetworkKit.
   */
  setDns(dns: FTDnsConfig | null): FTSDKConfig {
    if (dns === null) {
      this.dns = null;
      return this;
    }
    const servers: Array<string> = [];
    if (dns.servers) {
      for (let i = 0; i < dns.servers.length && servers.length < 3; i++) {
        const server = dns.servers[i].trim();
        if (server.length > 0) {
          servers.push(server);
        }
      }
    }
    this.dns = {
      servers,
      overHttpsUrl: dns.overHttpsUrl ? dns.overHttpsUrl.trim() : ''
    };
    return this;
  }

  getDns(): FTDnsConfig | null {
    if (this.dns === null) {
      return null;
    }
    return {
      servers: this.dns.servers ? this.dns.servers.slice() : [],
      overHttpsUrl: this.dns.overHttpsUrl
    };
  }

  /**
   * Set a predefined number of rows uploaded per request.
   * For a value other than 5, 10, or 50, use {@link setCustomSyncPageSize}.
   */
  setSyncPageSize(pageSize: SyncPageSize): FTSDKConfig {
    this.pageSize = pageSize;
    return this;
  }

  /**
   * Set a custom number of rows uploaded per request.
   * Values are rounded down and constrained to the supported range of 5 to 500 rows.
   */
  setCustomSyncPageSize(pageSize: number): FTSDKConfig {
    const normalized = pageSize !== pageSize ? SyncPageSize.MINI : Math.floor(pageSize);
    this.pageSize = Math.min(
      SyncTaskManager.MAX_PAGE_SIZE,
      Math.max(SyncPageSize.MINI, normalized)
    );
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
    const normalized = dataSyncRetryCount !== dataSyncRetryCount ? 0 : Math.floor(dataSyncRetryCount);
    this.dataSyncRetryCount = Math.max(0, Math.min(SyncTaskManager.MAX_ERROR_COUNT, normalized));
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
   * Enable or disable local data filtering. It is enabled by default.
   * Filtering is applied to RUM and logging data before it is written to the local cache.
   */
  setEnableDataFilter(enableDataFilter: boolean): FTSDKConfig {
    this.enableDataFilter = enableDataFilter;
    return this;
  }

  isEnableDataFilter(): boolean {
    return this.enableDataFilter;
  }

  /**
   * Set local data-filter rules. Supported categories are `logging` and `rum`.
   * Passing `null` clears all previously configured rules.
   */
  setDataFilters(dataFilters: FTDataFilters | null): FTSDKConfig {
    this.dataFilters.clear();
    if (dataFilters === null) {
      return this;
    }

    if (dataFilters instanceof Map) {
      dataFilters.forEach((rules: Array<string>, category: string) => {
        this.dataFilters.set(category, rules.slice());
      });
      return this;
    }

    const categories = Object.keys(dataFilters);
    for (let i = 0; i < categories.length; i++) {
      const category = categories[i];
      const rules = dataFilters[category];
      this.dataFilters.set(category, rules ? rules.slice() : []);
    }
    return this;
  }

  /**
   * Get a defensive copy of the configured local data-filter rules.
   */
  getDataFilters(): Map<string, Array<string>> {
    const copiedFilters = new Map<string, Array<string>>();
    this.dataFilters.forEach((rules: Array<string>, category: string) => {
      copiedFilters.set(category, rules.slice());
    });
    return copiedFilters;
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
   * Enable the SDK-wide telemetry cache byte limit.
   *
   * The default is 100MB and a custom value is clamped to 30MB. When this is
   * enabled, Log and RUM record-count limits are not used for admission.
   */
  enableLimitWithCacheSize(cacheSize?: number): FTSDKConfig {
    if (cacheSize !== undefined) {
      this.cacheLimit = Math.max(Constants.MINI_CACHE_LIMIT_SIZE, cacheSize);
    }
    this.limitWithCacheSize = true;
    return this;
  }

  /** Whether the SDK-wide telemetry cache byte limit is enabled. */
  isLimitWithCacheSize(): boolean {
    return this.limitWithCacheSize;
  }

  /** Get the SDK-wide telemetry cache byte limit. */
  getCacheLimit(): number {
    return this.cacheLimit;
  }

  /** Get the strategy applied when the SDK-wide cache limit is reached. */
  getCacheDiscard(): string {
    return this.cacheDiscard;
  }

  /**
   * Set the strategy applied when the SDK-wide cache limit is reached.
   * `DISCARD` rejects new telemetry and `DISCARD_OLDEST` makes room by
   * evicting the oldest pending telemetry first.
   */
  setCacheDiscard(strategy: string | CacheDiscard): FTSDKConfig {
    this.cacheDiscard = String(strategy) === CacheDiscard.DISCARD_OLDEST ?
      CacheDiscard.DISCARD_OLDEST : CacheDiscard.DISCARD;
    return this;
  }

  /**
   * Enable FileStore as the primary durable telemetry cache.
   * SQLite remains an upload index during the staged migration so existing
   * upload and filtering behavior remains compatible.
   */
  enableFileDataStore(): FTSDKConfig {
    this.fileDataStoreEnabled = true;
    this.useFileDataStore = true;
    return this;
  }

  /**
   * Select FileStore (`true`) or SQLite (`false`) as the durable cache mode
   * when shadow mode is disabled. If both switches are true, shadow takes
   * precedence so Android and HarmonyOS keep SQLite as the primary cache.
   */
  setUseFileDataStore(useFileDataStore: boolean): FTSDKConfig {
    this.fileDataStoreEnabled = this.fileDataStoreEnabled || useFileDataStore;
    this.useFileDataStore = useFileDataStore;
    return this;
  }

  /** Whether FileStore is enabled for primary or shadow persistence. */
  isFileDataStoreEnabled(): boolean {
    return this.fileDataStoreEnabled || this.fileDataStoreShadow;
  }

  /** Raw FileStore-primary switch; it is overridden when shadow is also enabled. */
  isUseFileDataStore(): boolean {
    return this.useFileDataStore;
  }

  /**
   * Mirror SQLite-accepted telemetry to FileStore without changing the
   * read/upload path. This is intended for a safe staged migration.
   */
  setFileDataStoreShadow(enabled: boolean): FTSDKConfig {
    this.fileDataStoreShadow = enabled;
    if (enabled) {
      this.fileDataStoreEnabled = true;
    }
    return this;
  }

  /** Whether SQLite writes are mirrored to FileStore. */
  isFileDataStoreShadow(): boolean {
    return this.fileDataStoreShadow;
  }

  /**
   * @deprecated Use enableLimitWithCacheSize(cacheSize).
   */
  enableLimitWithDbSize(dbSize?: number): FTSDKConfig {
    return this.enableLimitWithCacheSize(dbSize);
  }

  /**
   * @deprecated Use enableLimitWithCacheSize(cacheSize).
   */
  setDbCacheLimit(dbSize: number): FTSDKConfig {
    return this.enableLimitWithCacheSize(dbSize);
  }

  /**
   * @deprecated Use isLimitWithCacheSize().
   */
  isLimitWithDbSize(): boolean {
    return this.isLimitWithCacheSize();
  }

  /**
   * @deprecated Use getCacheLimit().
   */
  getDbCacheLimit(): number {
    return this.getCacheLimit();
  }

  /**
   * Get database cache discard strategy
   */
  getDBCacheDiscard(): string {
    return this.getCacheDiscard();
  }

  /**
   * @deprecated Use setCacheDiscard(strategy).
   */
  setDbCacheDiscard(strategy: string | DBCacheDiscard): FTSDKConfig {
    return this.setCacheDiscard(String(strategy));
  }
}

/** @internal Runtime-only endpoint update used by FTSDK.setDatakitUrl(...). */
export function setRuntimeDatakitUrlInternal(config: FTSDKConfig, datakitUrl: string): void {
  runtimeUploadEndpointOverrides.set(config, {
    datakitUrl: datakitUrl,
    datawayUrl: '',
    clientToken: ''
  });
}

/** @internal Runtime-only endpoint update used by FTSDK.setDatawayUrl(...). */
export function setRuntimeDatawayUrlInternal(config: FTSDKConfig, datawayUrl: string, clientToken: string): void {
  runtimeUploadEndpointOverrides.set(config, {
    datakitUrl: '',
    datawayUrl: datawayUrl,
    clientToken: clientToken
  });
}

/** @internal Release the endpoint override when an SDK instance is discarded. */
export function clearRuntimeUploadEndpointInternal(config: FTSDKConfig): void {
  runtimeUploadEndpointOverrides.delete(config);
}

export class FTTraceConfig {
  /**
   * Sampling rate, [0,1]
   */
  private samplingRate: number = 1;
  private traceSamplingRate: number | null = null;
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
   * @deprecated Use getTraceSamplingRate(). This compatibility getter returns
   * the effective rate in the legacy [0,1] probability unit.
   */
  public getSamplingRate(): number {
    return this.traceSamplingRate ?? this.samplingRate;
  }

  /**
   * @deprecated Use setTraceSamplingRate(). This compatibility setter accepts
   * the legacy [0,1] probability unit.
   */
  public setSamplingRate(samplingRate: number = 1.0): FTTraceConfig {
    this.samplingRate = Math.min(1.0, Math.max(0, samplingRate));
    return this;
  }

  /** Get the effective trace sampling rate as a percentage in [0,100]. */
  public getTraceSamplingRate(): number {
    return this.getSamplingRate() * 100;
  }

  /** Set the trace sampling rate as a percentage in [0,100]. */
  public setTraceSamplingRate(samplingRate: number): FTTraceConfig {
    this.traceSamplingRate = percentageToSamplingProbability(samplingRate, 'traceSamplingRate');
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
