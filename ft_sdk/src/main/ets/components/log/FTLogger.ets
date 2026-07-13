import { TrackLogManager } from './TrackLogManager';
import { LogBean } from '../bean/LogBean';
import { Status } from '../bean/Status';
import { Utils } from '../utils/Utils';
import { StringWrapper } from '../utils/StringWrapper';
import { FTInnerLogFileManager } from './FTInnerLogFileManager';
import { SDKLogLevel } from '../enum/Enums';
import hilog from '@ohos.hilog';
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKNativeCrashLogBatchDTO,
  SDKNativeCrashLogDTO,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerResponse
} from '../thread/SDKWorkerProtocol';

/**
 * Log entry interface
 */
export interface LogEntry {
  tag: string;
  message: string;
  level: string;
  timestampMs?: number;
}

/**
 * Internal logger class - for SDK internal log output
 * Uses hilog instead of console.log, conforms to HarmonyOS development standards
 * Internal class only, not exported to external users via index (aligned with Android design)
 * External users should use FTLogger instead
 * Exported for internal SDK use only
 *
 * Automatically collects logs for crash reporting via native crash handler
 */
export class FTInnerLogger {
  private static readonly TAG_PREFIX = "[FT-SDK]";
  private static readonly DOMAIN = 0x0001; // Log domain ID, can be adjusted as needed
  private static DEBUG_ENABLED: boolean = true;
  private static sdkLogLevel: SDKLogLevel = SDKLogLevel.V;
  private static CRASH_LOG_COLLECTION_ENABLED: boolean = true;
  private static readonly CRASH_LOG_BATCH_SIZE = 32;
  private static readonly CRASH_LOG_MAX_PENDING = 256;
  private static readonly CRASH_LOG_DRAIN_DELAY_MS = 16;
  private static pendingCrashLogs: SDKNativeCrashLogDTO[] = [];
  private static crashLogDrainTimer: number | null = null;
  private static crashLogCommandSequence: number = 0;
  private static crashLogResponseHandlerRegistered: boolean = false;

  // Enable or disable all SDK logs at runtime (aligned with Android LogUtils.setDebug())
  // When disabled, all log levels (d, i, w, e) will be suppressed
  // Android: LogUtils.setDebug(false) disables all log levels
  static setDebugEnabled(enabled: boolean): void {
    FTInnerLogger.DEBUG_ENABLED = enabled;
  }

  static setSDKLogLevel(logLevel: SDKLogLevel): void {
    FTInnerLogger.sdkLogLevel = logLevel;
  }

  // Enable or disable crash log collection
  static setCrashLogCollectionEnabled(enabled: boolean): void {
    FTInnerLogger.CRASH_LOG_COLLECTION_ENABLED = enabled;
    if (!enabled) {
      FTInnerLogger.pendingCrashLogs = [];
      if (FTInnerLogger.crashLogDrainTimer !== null) {
        clearTimeout(FTInnerLogger.crashLogDrainTimer);
        FTInnerLogger.crashLogDrainTimer = null;
      }
    }
  }

  // A diagnostic crash context must never synchronously cross NAPI on the caller.
  // Keep only the newest bounded records while the dedicated worker is unavailable.
  private static addToCrashBuffer(level: string, tag: string, message: string): void {
    if (!FTInnerLogger.CRASH_LOG_COLLECTION_ENABLED) {
      return;
    }
    if (FTInnerLogger.pendingCrashLogs.length >= FTInnerLogger.CRASH_LOG_MAX_PENDING) {
      FTInnerLogger.pendingCrashLogs.shift();
    }
    FTInnerLogger.pendingCrashLogs.push({
      level,
      tag: `${FTInnerLogger.TAG_PREFIX}_${tag}`,
      message
    });
    FTInnerLogger.scheduleCrashLogDrain();
  }

  private static scheduleCrashLogDrain(): void {
    if (FTInnerLogger.crashLogDrainTimer !== null || FTInnerLogger.pendingCrashLogs.length === 0) {
      return;
    }
    FTInnerLogger.crashLogDrainTimer = setTimeout(() => {
      FTInnerLogger.crashLogDrainTimer = null;
      FTInnerLogger.drainCrashLogBatch();
    }, FTInnerLogger.CRASH_LOG_DRAIN_DELAY_MS) as number;
  }

  private static drainCrashLogBatch(): void {
    if (FTInnerLogger.pendingCrashLogs.length === 0 || !FTInnerLogger.CRASH_LOG_COLLECTION_ENABLED) {
      return;
    }
    const logs = FTInnerLogger.pendingCrashLogs.splice(0, FTInnerLogger.CRASH_LOG_BATCH_SIZE);
    FTInnerLogger.ensureCrashLogResponseHandler();
    FTInnerLogger.crashLogCommandSequence++;
    const payload: SDKNativeCrashLogBatchDTO = { logs };
    const posted = SDKDedicatedPoolManager.getInstance().postCommand({
      id: `nativeCrashLog.append.${FTInnerLogger.crashLogCommandSequence}.${Date.now()}`,
      pool: SDKDedicatedPoolType.NATIVE_CRASH_LOG,
      command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
      priority: SDKTaskPriority.LOW,
      createdAt: Date.now(),
      payload: payload as Object
    });
    if (!posted) {
      FTInnerLogger.pendingCrashLogs = logs.concat(FTInnerLogger.pendingCrashLogs);
      while (FTInnerLogger.pendingCrashLogs.length > FTInnerLogger.CRASH_LOG_MAX_PENDING) {
        FTInnerLogger.pendingCrashLogs.pop();
      }
    }
    FTInnerLogger.scheduleCrashLogDrain();
  }

  private static ensureCrashLogResponseHandler(): void {
    if (FTInnerLogger.crashLogResponseHandlerRegistered) {
      return;
    }
    SDKDedicatedPoolManager.getInstance().setMailboxResponseHandler(
      SDKDedicatedPoolType.NATIVE_CRASH_LOG,
      (_response: SDKWorkerResponse) => {
        // Worker restart/replay is managed by SDKDedicatedPoolManager. Do not log
        // failures here because that would recursively enqueue crash diagnostics.
      }
    );
    FTInnerLogger.crashLogResponseHandlerRegistered = true;
  }

  private static addToLogFile(level: string, tag: string, message: string): void {
    try {
      const fullTag = `${FTInnerLogger.TAG_PREFIX}${tag}`;
      FTInnerLogFileManager.getInstance().append(level, fullTag, message);
    } catch (error) {
      // Keep internal logging best-effort and avoid recursive log failures.
    }
  }

  private static isLogEnabled(logLevel: SDKLogLevel): boolean {
    return FTInnerLogger.DEBUG_ENABLED &&
      FTInnerLogger.getLogLevelPriority(FTInnerLogger.sdkLogLevel) <=
      FTInnerLogger.getLogLevelPriority(logLevel);
  }

  private static getLogLevelPriority(logLevel: SDKLogLevel): number {
    switch (logLevel) {
      case SDKLogLevel.V:
        return 0;
      case SDKLogLevel.D:
        return 1;
      case SDKLogLevel.I:
        return 2;
      case SDKLogLevel.W:
        return 3;
      case SDKLogLevel.E:
        return 4;
      default:
        return 0;
    }
  }

  static d(tag: string, message: string): void {
    if (!FTInnerLogger.isLogEnabled(SDKLogLevel.D)) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.debug(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToLogFile("D", tag, fullMessage);
    FTInnerLogger.addToCrashBuffer("D", tag, fullMessage);
  }

  static i(tag: string, message: string): void {
    if (!FTInnerLogger.isLogEnabled(SDKLogLevel.I)) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.info(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToLogFile("I", tag, fullMessage);
    FTInnerLogger.addToCrashBuffer("I", tag, fullMessage);
  }

  static w(tag: string, message: string): void {
    if (!FTInnerLogger.isLogEnabled(SDKLogLevel.W)) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.warn(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToLogFile("W", tag, fullMessage);
    FTInnerLogger.addToCrashBuffer("W", tag, fullMessage);
  }

  static e(tag: string, message: string): void {
    if (!FTInnerLogger.isLogEnabled(SDKLogLevel.E)) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.error(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToLogFile("E", tag, fullMessage);
    FTInnerLogger.addToCrashBuffer("E", tag, fullMessage);
  }
}

/**
 * External log interface - log API called by users
 * FTLogger implementation for HarmonyOS
 */
const TAG = "FTLogger";

interface PendingPublicLogBatch {
  logs: ReadonlyArray<LogEntry>;
  cursor: number;
}

export class FTLogger {
  private static trackLogManager: TrackLogManager | null = null;
  private static readonly PUBLIC_BATCH_SLICE_SIZE = 64;
  private static readonly PUBLIC_BATCH_SLICE_DELAY_MS = 16;
  private static pendingPublicLogBatches: PendingPublicLogBatch[] = [];
  private static publicBatchDrainTimer: number | null = null;
  private static publicBatchFlushRequested: boolean = false;
  
  /**
   * Initialize log manager
   */
  private static initTrackLogManager(): void {
    if (FTLogger.trackLogManager === null) {
      FTLogger.trackLogManager = TrackLogManager.getInstance();
    }
  }

  public static resetBatchStateInternal(): void {
    if (FTLogger.publicBatchDrainTimer !== null) {
      clearTimeout(FTLogger.publicBatchDrainTimer);
      FTLogger.publicBatchDrainTimer = null;
    }
    FTLogger.pendingPublicLogBatches = [];
    FTLogger.publicBatchFlushRequested = false;
  }

  private static enqueueBehindPendingBatch(tag: string, message: string, level: string): boolean {
    if (FTLogger.pendingPublicLogBatches.length === 0) {
      return false;
    }
    FTLogger.pendingPublicLogBatches.push({
      logs: [{ tag, message, level, timestampMs: Utils.getCurrentTimestamp() }],
      cursor: 0
    });
    FTLogger.schedulePublicBatchDrain();
    return true;
  }
  
  /**
   * Debug level log
   */
  static d(tag: string, message: string): void {
    FTLogger.initTrackLogManager();
    if (FTLogger.enqueueBehindPendingBatch(tag, message, 'd')) {
      return;
    }
    
    try {
      const logBean = new LogBean(message, Utils.getCurrentTimestamp());
      logBean.setStatus(Status.DEBUG.name);
      logBean.addTag("tag", new StringWrapper(tag));
      
      FTLogger.trackLogManager?.trackLog(logBean);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue debug log: ${(error as Error).message}`);
    }
  }
  
  /**
   * Info level log
   */
  static i(tag: string, message: string): void {
    FTLogger.initTrackLogManager();
    if (FTLogger.enqueueBehindPendingBatch(tag, message, 'i')) {
      return;
    }
    
    try {
      const logBean = new LogBean(message, Utils.getCurrentTimestamp());
      logBean.setStatus(Status.INFO.name);
      logBean.addTag("tag", new StringWrapper(tag));
      
      FTLogger.trackLogManager?.trackLog(logBean);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue info log: ${(error as Error).message}`);
    }
  }
  
  /**
   * Warning level log
   */
  static w(tag: string, message: string): void {
    FTLogger.initTrackLogManager();
    if (FTLogger.enqueueBehindPendingBatch(tag, message, 'w')) {
      return;
    }
    
    try {
      const logBean = new LogBean(message, Utils.getCurrentTimestamp());
      logBean.setStatus(Status.WARN.name);
      logBean.addTag("tag", new StringWrapper(tag));
      
      FTLogger.trackLogManager?.trackLog(logBean);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue warning log: ${(error as Error).message}`);
    }
  }
  
  /**
   * Error level log
   */
  static e(tag: string, message: string): void {
    FTLogger.initTrackLogManager();
    if (FTLogger.enqueueBehindPendingBatch(tag, message, 'e')) {
      return;
    }
    
    try {
      const logBean = new LogBean(message, Utils.getCurrentTimestamp());
      logBean.setStatus(Status.ERROR.name);
      logBean.addTag("tag", new StringWrapper(tag));
      
      FTLogger.trackLogManager?.trackLog(logBean);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue error log: ${(error as Error).message}`);
    }
  }
  
  /**
   * Batch record logs
   */
  static batchLog(logs: Array<LogEntry>): void {
    FTLogger.initTrackLogManager();
    if (!logs || logs.length === 0) {
      return;
    }
    // Keep only a source reference and a cursor. Copying a huge input array on
    // the caller thread is itself an O(N) ANR vector; conversion remains sliced.
    FTLogger.pendingPublicLogBatches.push({ logs, cursor: 0 });
    FTLogger.schedulePublicBatchDrain();
  }

  private static schedulePublicBatchDrain(): void {
    if (FTLogger.publicBatchDrainTimer !== null) {
      return;
    }
    FTLogger.publicBatchDrainTimer = setTimeout(() => {
      FTLogger.publicBatchDrainTimer = null;
      FTLogger.drainPublicBatchSlice();
    }, FTLogger.PUBLIC_BATCH_SLICE_DELAY_MS) as number;
  }

  private static drainPublicBatchSlice(): void {
    const pending = FTLogger.pendingPublicLogBatches[0];
    if (!pending) {
      if (FTLogger.publicBatchFlushRequested) {
        FTLogger.publicBatchFlushRequested = false;
        FTLogger.trackLogManager?.forceFlush();
      }
      return;
    }
    try {
      const logBeans: LogBean[] = [];
      const end = Math.min(pending.logs.length, pending.cursor + FTLogger.PUBLIC_BATCH_SLICE_SIZE);
      for (let i = pending.cursor; i < end; i++) {
        logBeans.push(FTLogger.createPublicLogBean(pending.logs[i]));
      }
      pending.cursor = end;
      if (logBeans.length > 0) {
        FTLogger.trackLogManager?.trackLogBatch(logBeans);
      }
      if (pending.cursor >= pending.logs.length) {
        FTLogger.pendingPublicLogBatches.shift();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue batch logs: ${error instanceof Error ? error.message : String(error)}`);
      FTLogger.pendingPublicLogBatches.shift();
    }
    if (FTLogger.pendingPublicLogBatches.length > 0) {
      FTLogger.schedulePublicBatchDrain();
    } else if (FTLogger.publicBatchFlushRequested) {
      FTLogger.publicBatchFlushRequested = false;
      FTLogger.trackLogManager?.forceFlush();
    }
  }

  private static createPublicLogBean(log: LogEntry): LogBean {
    const timestampMs = log.timestampMs === undefined ? Utils.getCurrentTimestamp() : log.timestampMs;
    const logBean = new LogBean(log.message, timestampMs);
    switch (log.level.toLowerCase()) {
      case 'd':
        logBean.setStatus(Status.DEBUG.name);
        break;
      case 'i':
        logBean.setStatus(Status.INFO.name);
        break;
      case 'w':
        logBean.setStatus(Status.WARN.name);
        break;
      case 'e':
        logBean.setStatus(Status.ERROR.name);
        break;
      default:
        logBean.setStatus(Status.INFO.name);
    }
    logBean.addTag("tag", new StringWrapper(log.tag));
    return logBean;
  }

  private static getPendingPublicLogCount(): number {
    let count = 0;
    for (let i = 0; i < FTLogger.pendingPublicLogBatches.length; i++) {
      const pending = FTLogger.pendingPublicLogBatches[i];
      count += Math.max(0, pending.logs.length - pending.cursor);
    }
    return count;
  }
  
  /**
   * Force flush log buffer
   */
  static flush(): void {
    FTLogger.initTrackLogManager();
    if (FTLogger.pendingPublicLogBatches.length > 0) {
      FTLogger.publicBatchFlushRequested = true;
      FTLogger.schedulePublicBatchDrain();
    } else {
      FTLogger.trackLogManager?.forceFlush();
    }
  }
  
  /**
   * Get log manager status
   */
  static getStatus(): Map<string, number | boolean> {
    FTLogger.initTrackLogManager();
    
    const defaultStatus = new Map<string, number | boolean>();
    defaultStatus.set('queueSize', 0);
    defaultStatus.set('bufferSize', 0);
    defaultStatus.set('isProcessing', false);
    
    const queueStatus = FTLogger.trackLogManager?.getQueueStatus();
    
    if (queueStatus) {
      const result = new Map<string, number | boolean>();
      result.set('queueSize', queueStatus.queueSize || 0);
      const publicPending = FTLogger.getPendingPublicLogCount();
      result.set('bufferSize', (queueStatus.bufferSize || 0) + publicPending);
      result.set('isProcessing', (queueStatus.isProcessing || false) || publicPending > 0);
      return result;
    }
    
    return defaultStatus;
  }

  /**
   * Get FTLogger instance (singleton pattern)
   */
  static getInstance(): FTLogger {
    return FTLogger;
  }

  /**
   * Check whether configuration is initialized
   * @return true if initialized, false otherwise
   */
  private static checkConfig(): boolean {
    if (FTLogger.trackLogManager === null) {
      FTInnerLogger.e(TAG, "Use FTLogger, need to initialize FTSdk.initLogWithConfig(FTLoggerConfig ftSdkConfig))");
      return false;
    }
    return true;
  }

  /**
   * Log background message
   * @param content Log content
   * @param status Log status
   * @param property Additional properties (optional)
   * @param isSilence Whether silent (optional)
   */
  static logBackground(content: string, status: string, property?: Map<string, object>, isSilence?: boolean): void;
  static logBackground(content: string, status: Status, property?: Map<string, object>, isSilence?: boolean): void;
  static logBackground(content: string, status: string | Status, property?: Map<string, object>, isSilence?: boolean): void {
    
    // Initialize TrackLogManager first
    FTLogger.initTrackLogManager();
    
    // Check configuration after initialization
    if (!FTLogger.checkConfig()) {
      return;
    }
    
    
    // Get log configuration
    const logConfig = FTLogger.trackLogManager?.getLogConfig();
    if (!logConfig) {
      FTInnerLogger.w(TAG, "Log config not available, discarding custom log");
      return;
    }
    
    // Check if custom log is enabled
    if (!logConfig.isEnableCustomLog()) {
      return;
    }
    
    
    // Convert Status to string if needed
    const statusString = typeof status === 'string' ? status : status.name;
    
      // Console output
    if (logConfig && logConfig.isPrintCustomLogToConsole()) {
      const propertyString = property ? "," + JSON.stringify(Array.from(property.entries())) : "";
      const message = `[${statusString.toUpperCase()}]${content}${propertyString}`;
      
      // Output to console based on status level
      const statusObj = typeof status === 'string' ? Status.fromName(status) : status;
      if (statusObj) {
        switch (statusObj) {
          case Status.INFO:
            FTInnerLogger.i(TAG, message);
            break;
          case Status.WARN:
            FTInnerLogger.w(TAG, message);
            break;
          case Status.ERROR:
          case Status.FATAL:
            FTInnerLogger.e(TAG, message);
            break;
          case Status.DEBUG:
            FTInnerLogger.d(TAG, message);
            break;
          case Status.TRACE:
            FTInnerLogger.d(TAG, message);
            break;
        }
      } else {
        FTInnerLogger.i(TAG, message);
      }
    }
    
    try {
      
      const logBean = new LogBean(content, Utils.getCurrentTimestamp());
      logBean.setStatus(statusString);
      
      // Set service name
      logBean.setServiceName(logConfig.getServiceName());
      
      // Add additional properties - optimized to use direct merge
      if (property) {
        const propertyRecord: Record<string, object> = {};
        property.forEach((value, key) => {
          propertyRecord[key] = value;
        });
        logBean.appendFields(propertyRecord);
      } else {
      }
      
      // Check log level before sending
      if (logConfig.checkLogLevel(statusString)) {
        FTLogger.trackLogManager?.trackLog(logBean, isSilence || false);
        
      } else {
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue background log: ${(error as Error).message}`);
    }
  }

}
