import { FTInnerLogger } from './FTLogger';
import { TrackLogManager } from './TrackLogManager';
import { LogBean } from '../bean/LogBean';
import { Status } from '../bean/Status';
import { Utils } from '../utils/Utils';
import { StringWrapper } from '../utils/StringWrapper';

const TAG = "FTHiLogInterceptor";

/**
 * HiLog Interceptor using HarmonyOS AOP
 * Intercepts hilog calls and uploads logs to server when enableConsoleLog is enabled
 * 
 * This implementation uses HarmonyOS AOP (Aspect Oriented Programming) to intercept
 * hilog method calls, similar to Android SDK's console log interception.
 * 
 * Usage:
 * 1. Enable console log capture in FTLoggerConfig:
 *    logConfig.setEnableConsoleLog(true);
 *    // or with prefix filter:
 *    logConfig.setEnableConsoleLog(true, "MyApp");
 * 
 * 2. Initialize the interceptor:
 *    FTHiLogInterceptor.getInstance().init();
 * 
 * Note: This should be called early in application lifecycle, before any hilog calls.
 * //TODO to implement
 */
export class FTHiLogInterceptor {
  private static instance: FTHiLogInterceptor | null = null;
  private isInitialized: boolean = false;

  private constructor() {}

  /**
   * Get singleton instance
   */
  public static getInstance(): FTHiLogInterceptor {
    if (FTHiLogInterceptor.instance === null) {
      FTHiLogInterceptor.instance = new FTHiLogInterceptor();
    }
    return FTHiLogInterceptor.instance;
  }

  /**
   * Initialize hilog interceptor using AOP
   * This should be called after FTLoggerConfig is set up
   */
  public init(): void {
    if (this.isInitialized) {
      FTInnerLogger.w(TAG, "HiLog interceptor already initialized");
      return;
    }

    try {
      // Check if console log is enabled
      const trackLogManager = TrackLogManager.getInstance();
      const config = trackLogManager.getLogConfig();
      if (!config || !config.isEnableConsoleLog()) {
        FTInnerLogger.d(TAG, "Console log capture is disabled, skipping hilog interceptor initialization");
        return;
      }

      FTInnerLogger.i(TAG, "Initializing hilog interceptor using AOP");

      // Note: HarmonyOS AOP does not support intercepting namespace methods directly
      // Since hilog is a namespace, we cannot use AOP to intercept it
      // This feature is currently disabled and will be implemented using an alternative approach
      // TODO: Implement hilog interception using a wrapper class or other mechanism
      
      FTInnerLogger.w(TAG, "HiLog AOP interception is not supported for namespace methods. This feature is disabled.");
      
      // AOP interception code is commented out due to ArkTS restrictions:
      // 1. Namespaces cannot be used as objects (arkts-no-ns-as-obj)
      // 2. ArkTS does not support 'unknown' type for rest parameters
      // 
      // Alternative approaches to consider:
      // 1. Create a wrapper class that wraps hilog methods
      // 2. Use a different interception mechanism if available
      // 3. Require developers to use a custom logging utility instead of hilog directly
      
      /*
      // Intercept hilog.debug
      util.Aspect.addBefore(hilogObj, "debug", true,
        (targetClass: object, domain: number, tag: string, format: string, ...args: string[]): void => {
          this.handleHiLog("debug", domain, tag, format, args);
        }
      );
      */

      this.isInitialized = true;
      FTInnerLogger.w(TAG, "HiLog interceptor initialization completed, but AOP interception is disabled due to ArkTS limitations");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize hilog interceptor: ${error}`);
    }
  }

  /**
   * Handle intercepted hilog call
   * @param level Log level (debug, info, warn, error, fatal)
   * @param domain Log domain
   * @param tag Log tag
   * @param format Log format string
   * @param args Log arguments (converted to strings)
   */
  private handleHiLog(level: string, domain: number, tag: string, format: string, args: string[]): void {
    try {
      // Check if console log is still enabled
      const trackLogManager = TrackLogManager.getInstance();
      const config = trackLogManager.getLogConfig();
      if (!config || !config.isEnableConsoleLog()) {
        return;
      }

      // Format log message (similar to hilog's formatting)
      let message: string;
      try {
        // Simple formatting: replace %s, %d, etc. with args
        // Note: This is a simplified version, hilog has more complex formatting
        message = this.formatLogMessage(format, args);
      } catch (e) {
        // If formatting fails, use format string as-is
        message = format;
      }

      // Check prefix filter using checkPrefix method
      if (!config.checkPrefix(message)) {
        // Log doesn't match prefix filter, skip
        return;
      }

      // Convert hilog level to Status
      const status = this.convertHiLogLevelToStatus(level);

      // Check log level filter
      if (!config.checkLogLevel(status)) {
        return;
      }

      // Create LogBean
      const logBean = new LogBean(message, Utils.getCurrentTimestamp());
      logBean.setStatus(status);
      logBean.setServiceName(config.getServiceName());
      logBean.addTag("tag", new StringWrapper(tag));
      logBean.addTag("domain", new StringWrapper(String(domain)));

      // Add RUM context if enabled
      if (config.isEnableLinkRumData()) {
        // Link with RUM data (view_id, session_id, etc.)
        // This will be handled by TrackLogManager
      }

      // Send to TrackLogManager
      trackLogManager.trackLog(logBean, false);

      FTInnerLogger.d(TAG, `[HILOG-INTERCEPT] Captured ${level} log: tag=${tag}, message=${message.substring(0, 50)}...`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error handling hilog interception: ${error}`);
    }
  }

  /**
   * Format log message with arguments
   * Simplified version of hilog's formatting
   * @param format Log format string
   * @param args Log arguments (already converted to strings)
   */
  private formatLogMessage(format: string, args: string[]): string {
    if (!args || args.length === 0) {
      return format;
    }

    let result = format;
    let argIndex = 0;

    // Simple placeholder replacement
    // Note: This is a simplified version, hilog has more complex formatting rules
    result = result.replace(/%[sdj%]/g, (match: string): string => {
      if (match === '%%') {
        return '%';
      }
      if (argIndex < args.length) {
        const arg = args[argIndex++];
        if (match === '%j') {
          // For %j, try to parse as JSON if possible, otherwise use as-is
          try {
            const parsed: ESObject = JSON.parse(arg);
            return JSON.stringify(parsed);
          } catch {
            return arg;
          }
        }
        return arg;
      }
      return match;
    });

    // Append remaining args if any
    if (argIndex < args.length) {
      const remainingArgs = args.slice(argIndex).join(' ');
      result += ' ' + remainingArgs;
    }

    return result;
  }

  /**
   * Convert hilog level to Status
   * Mapping:
   * - debug -> DEBUG
   * - info -> INFO
   * - warn -> WARN
   * - error -> ERROR
   * - fatal -> FATAL
   */
  private convertHiLogLevelToStatus(level: string): string {
    switch (level.toLowerCase()) {
      case 'debug':
        return Status.DEBUG.name;
      case 'info':
        return Status.INFO.name;
      case 'warn':
        return Status.WARN.name;
      case 'error':
        return Status.ERROR.name;
      case 'fatal':
        return Status.FATAL.name;
      default:
        return Status.INFO.name;
    }
  }

  /**
   * Clean up interceptor
   * Note: HarmonyOS AOP doesn't provide a way to remove interceptors
   * They will be cleaned up when the application is destroyed
   */
  public destroy(): void {
    this.isInitialized = false;
    FTInnerLogger.d(TAG, "HiLog interceptor destroyed");
  }
}

