import { TrackLogManager } from './TrackLogManager';
import { LogBean } from '../bean/LogBean';
import { Status } from '../bean/Status';
import { Utils } from '../utils/Utils';
import { StringWrapper } from '../utils/StringWrapper';
import hilog from '@ohos.hilog';
import ftnativecrash from 'libftnativecrash.so';

/**
 * Log entry interface
 */
export interface LogEntry {
  tag: string;
  message: string;
  level: string;
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
  private static CRASH_LOG_COLLECTION_ENABLED: boolean = true;

  // Enable or disable all SDK logs at runtime (aligned with Android LogUtils.setDebug())
  // When disabled, all log levels (d, i, w, e) will be suppressed
  // Android: LogUtils.setDebug(false) disables all log levels
  static setDebugEnabled(enabled: boolean): void {
    FTInnerLogger.DEBUG_ENABLED = enabled;
  }

  // Enable or disable crash log collection
  static setCrashLogCollectionEnabled(enabled: boolean): void {
    FTInnerLogger.CRASH_LOG_COLLECTION_ENABLED = enabled;
  }

  // Helper method to add log to crash buffer
  private static addToCrashBuffer(level: string, tag: string, message: string): void {
    if (!FTInnerLogger.CRASH_LOG_COLLECTION_ENABLED) {
      return;
    }
    try {
      const fullTag = `${FTInnerLogger.TAG_PREFIX}_${tag}`;
      ftnativecrash.addLog(level, fullTag, message);
    } catch (error) {
      // Silently fail if native module is not available
    }
  }

  static d(tag: string, message: string): void {
    if (!FTInnerLogger.DEBUG_ENABLED) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.debug(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToCrashBuffer("D", tag, fullMessage);
  }

  static i(tag: string, message: string): void {
    // Aligned with Android: LogUtils.i() checks mDebug flag
    // Android: i(tag, message, currentLevel.ordinal() <= SDKLogLevel.I.ordinal() && mDebug)
    if (!FTInnerLogger.DEBUG_ENABLED) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.info(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToCrashBuffer("I", tag, fullMessage);
  }

  static w(tag: string, message: string): void {
    // Aligned with Android: LogUtils.w() checks mDebug flag
    // Android: w(tag, message, currentLevel.ordinal() <= SDKLogLevel.W.ordinal() && mDebug)
    if (!FTInnerLogger.DEBUG_ENABLED) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.warn(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToCrashBuffer("W", tag, fullMessage);
  }

  static e(tag: string, message: string): void {
    // Aligned with Android: LogUtils.e() checks mDebug flag
    // Android: e(tag, message, currentLevel.ordinal() <= SDKLogLevel.E.ordinal() && mDebug)
    if (!FTInnerLogger.DEBUG_ENABLED) {
      return;
    }
    const fullMessage = `${message}`;
    hilog.error(FTInnerLogger.DOMAIN, `${FTInnerLogger.TAG_PREFIX}${tag}`, fullMessage);
    FTInnerLogger.addToCrashBuffer("E", tag, fullMessage);
  }
}

/**
 * External log interface - log API called by users
 * FTLogger implementation for HarmonyOS
 */
const TAG = "FTLogger";

export class FTLogger {
  private static trackLogManager: TrackLogManager | null = null;
  
  /**
   * Initialize log manager
   */
  private static initTrackLogManager(): void {
    if (FTLogger.trackLogManager === null) {
      FTLogger.trackLogManager = TrackLogManager.getInstance();
    }
  }
  
  /**
   * Debug level log
   */
  static d(tag: string, message: string): void {
    FTLogger.initTrackLogManager();
    
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
    
    try {
      const logBeans: LogBean[] = [];
      
      for (const log of logs) {
        const logBean = new LogBean(log.message, Utils.getCurrentTimestamp());
        
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
        logBeans.push(logBean);
      }
      
      FTLogger.trackLogManager?.trackLogBatch(logBeans);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to enqueue batch logs: ${(error as Error).message}`);
    }
  }
  
  /**
   * Force flush log buffer
   */
  static flush(): void {
    FTLogger.initTrackLogManager();
    FTLogger.trackLogManager?.forceFlush();
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
      result.set('bufferSize', queueStatus.bufferSize || 0);
      result.set('isProcessing', queueStatus.isProcessing || false);
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
    if (logConfig.isPrintCustomLogToConsole()) {
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
