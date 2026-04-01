import ftnativecrash from 'libftnativecrash.so';
import { FTInnerLogger } from './log/FTLogger';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import { ErrorType } from './rum/enum/RUMEnums';
import { AppState } from './rum/enum/RUMEnums';
import { Constants } from './Constants';


const TAG = "FTNativeCrashHandler";

/**
 * Native crash data interface from C++ layer
 */
export interface NativeCrashData {
  timestamp: number;
  crashType: string; // "JsError" or "NativeCrash"
  foreground: boolean;
  bundleVersion: string;
  bundleName: string;
  pid: number;
  uid: number;
  uuid: string;
  exception: string; // JSON string containing exception details
  hilogSize: number;
  externalLog: string; // JSON string containing external log paths
  logOverLimit: boolean;
  memoryNearRegisters: string; // Memory dump near registers
  maps: string; // Memory maps information
  hilog: string; // System log content
}

/**
 * Callback interface for receiving native crash events
 */
export type NativeCrashCallback = (crashData: NativeCrashData) => void;

interface CrashExceptionData {
  signal?: CrashSignalData;
  frames?: CrashFrameData[];
  thread_name?: string;
  tid?: number;
  message?: string;
}

interface CrashSignalData {
  signo?: number;
  code?: number;
  address?: string;
}

interface CrashFrameData {
  symbol?: string;
  file?: string;
  pc?: string;
  line?: number;
  column?: number;
}

interface CrashMemoryData {
  rss?: number;
  rss_kb?: number;
  sys_total_mem?: number;
  sys_free_mem?: number;
  sys_avail_mem?: number;
}

interface ParsedCrashException {
  exception?: CrashExceptionData;
  memory?: CrashMemoryData;
}

interface PrimitiveWrapper {
  value: string | number | boolean;
}

/**
 * FT Native Crash Handler
 * Handles native crash events from the native layer and reports them into RUM.
 *
 * Current flow:
 * 1. `initialize()` initializes the native module
 * 2. the native callback is bound to `handleNativeCrash()`
 * 3. watcher startup happens immediately after initialization
 * 4. `handleNativeCrash()` formats crash data and writes it through `FTRUMInnerManager`
 */
export class FTNativeCrashHandler {
  private isInitialized: boolean = false;
  private isWatching: boolean = false;

  constructor() {
    // No-op constructor for singleton-style lifecycle owned by FTExceptionHandler.
  }


  /**
   * Initialize the native crash handler
   * Initializes the native module, binds the crash callback, and starts watching.
   */
  public async initialize(): Promise<boolean> {

    if (this.isInitialized) {
      FTInnerLogger.w(TAG, "Already initialized");
      return true;
    }

    try {
      FTInnerLogger.i(TAG, "=== Native Crash Handler Initialization Start ===");

      // Initialize native handler
      const initResult: boolean = ftnativecrash.initNativeCrashHandler();
      FTInnerLogger.i(TAG, `initNativeCrashHandler result: ${initResult}`);

      if (!initResult) {
        FTInnerLogger.e(TAG, "Failed to initialize native crash handler");
        return false;
      }

      // Set internal crash callback
      ftnativecrash.setCrashCallback(this.handleNativeCrash.bind(this));

      this.isInitialized = true;
      const watchResult = this.startWatching();
      if (!watchResult) {
        FTInnerLogger.e(TAG, "Native crash handler initialized but failed to start watching");
        return false;
      }

      FTInnerLogger.i(TAG, "=== Native Crash Handler Initialized Successfully ===");
      return true;

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize native crash handler: ${error}`);
      return false;
    }
  }

  /**
   * Start watching for crash events
   */
  private startWatching(): boolean {

    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "Not initialized, call initialize first");
      return false;
    }

    if (this.isWatching) {
      FTInnerLogger.w(TAG, "Already watching");
      return true;
    }

    try {
      const result: boolean = ftnativecrash.startWatching();
      if (result) {
        this.isWatching = true;
        FTInnerLogger.i(TAG, "Started watching crash events");
      } else {
        FTInnerLogger.e(TAG, "Failed to start watching crash events");
      }
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error starting watcher: ${error}`);
      return false;
    }
  }

  /**
   * Stop watching for crash events
   */
  public stopWatching(): void {
    if (!this.isWatching) {
      return;
    }

    try {
      ftnativecrash.stopWatching();
      this.isWatching = false;
      FTInnerLogger.i(TAG, "Stopped watching crash events");
    } catch (error) {
      FTInnerLogger.e(TAG, `Error stopping watcher: ${error}`);
    }
  }

  /**
   * Handle native crash event from C++ layer
   * @param crashData Crash data from native layer
   */
  private async handleNativeCrash(crashData: NativeCrashData): Promise<void> {
    FTInnerLogger.i(TAG, "<FT-ARKTS-CALLBACK> *** ARKTS CALLBACK CALLED ***");
    FTInnerLogger.i(TAG, `<FT-ARKTS-CALLBACK> Crash data received: type=${crashData.crashType}`);

    try {
      const crashReport = this.formatCrashReport(crashData);
      const errorContext: Record<string, string | number | boolean | object> = {};

      errorContext[Constants.KEY_CRASH_TYPE] = crashData.crashType;
      errorContext[Constants.KEY_NATIVE_CRASH] = true;
      errorContext[Constants.KEY_BUNDLE_NAME] = crashData.bundleName;
      errorContext[Constants.KEY_BUNDLE_VERSION] = crashData.bundleVersion;
      errorContext[Constants.KEY_PID] = crashData.pid;
      errorContext[Constants.KEY_UID] = crashData.uid;
      errorContext[Constants.KEY_UUID] = crashData.uuid;
      errorContext[Constants.KEY_FOREGROUND] = crashData.foreground;
      errorContext[Constants.KEY_TIMESTAMP] = crashData.timestamp;
      errorContext[Constants.KEY_HILOG_SIZE] = crashData.hilogSize;
      errorContext[Constants.KEY_LOG_OVER_LIMIT] = crashData.logOverLimit;

      if (crashData.externalLog) {
        try {
          errorContext[Constants.KEY_EXTERNAL_LOG] = JSON.parse(crashData.externalLog) as object;
        } catch {
          errorContext[Constants.KEY_EXTERNAL_LOG] = crashData.externalLog;
        }
      }

      try {
        const rumManager = FTRUMInnerManager.getInstance();
        const savedContext = await rumManager.getSavedRumContext();

        if (savedContext.viewId && savedContext.viewId !== '') {
          errorContext[Constants.KEY_RUM_VIEW_ID] = this.wrapPrimitive(savedContext.viewId);
          errorContext[Constants.KEY_RUM_VIEW_NAME] = this.wrapPrimitive(savedContext.viewName);
          errorContext[Constants.KEY_RUM_VIEW_REFERRER] = this.wrapPrimitive(savedContext.viewReferrer);
          errorContext[Constants.KEY_RUM_SESSION_ID] = this.wrapPrimitive(savedContext.sessionId);
        } else {
          errorContext[Constants.KEY_RUM_VIEW_ID] = this.wrapPrimitive('unknown');
          errorContext[Constants.KEY_RUM_VIEW_NAME] = this.wrapPrimitive('unknown');
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `<FT-ARKTS-CALLBACK> Failed to get saved RUM context: ${error}`);
        errorContext[Constants.KEY_RUM_VIEW_ID] = this.wrapPrimitive('error');
        errorContext[Constants.KEY_RUM_VIEW_NAME] = this.wrapPrimitive('error');
      }

      const rumManager = FTRUMInnerManager.getInstance();
      await rumManager.addError(
        crashReport,
        `Native Crash: ${crashData.crashType}`,
        ErrorType.NATIVE_CRASH,
        AppState.RUN,
        this.convertToRecordStringObject(errorContext)
      );
      rumManager.clearSavedRumContext();
      FTInnerLogger.i(TAG, "<FT-ARKTS-CALLBACK> *** CRASH REPORTED TO RUM SUCCESSFULLY ***");
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-ARKTS-CALLBACK> *** CALLBACK ERROR ***: ${error}`);
    }
  }

  /**
   * Check if the handler is initialized
   */
  public isReady(): boolean {
    return this.isInitialized && this.isWatching;
  }

  /**
   * Shutdown the handler
   */
  public shutdown(): void {
    this.stopWatching();
    this.isInitialized = false;
    FTInnerLogger.i(TAG, "Native crash handler shutdown");
  }

  private formatCrashReport(crashData: NativeCrashData): string {
    let crashReport = '';
    crashReport += `Module name:${crashData.bundleName}\n`;
    crashReport += `Version:${crashData.bundleVersion}\n`;
    crashReport += `Foreground:${crashData.foreground ? 'Yes' : 'No'}\n`;
    crashReport += `Fingerprint:${crashData.uuid}\n`;

    const crashDate = new Date(crashData.timestamp);
    const timestampStr = crashDate.toISOString().replace('T', ' ').substring(0, 19) + '.' +
      crashDate.getMilliseconds().toString().padStart(3, '0');
    crashReport += `Timestamp:${timestampStr}\n`;
    crashReport += `Pid:${crashData.pid}\n`;
    crashReport += `Uid:${crashData.uid}\n`;
    crashReport += `Process name:${crashData.bundleName}\n`;

    try {
      const parsed: ParsedCrashException = JSON.parse(crashData.exception) as ParsedCrashException;
      if (parsed.exception) {
        crashReport += this.formatExceptionDetails(parsed.exception);
      }
      if (parsed.memory) {
        const mem = parsed.memory;
        const rss = mem.rss || mem.rss_kb || 0;
        crashReport += `Process Memory(kB): ${rss}(Rss)\n`;
        crashReport += `Device Memory(kB): Total ${mem.sys_total_mem || 0}, Free ${mem.sys_free_mem || 0}, Available ${mem.sys_avail_mem || 0}\n`;
      }
    } catch {
      // Keep raw crash data when exception JSON cannot be parsed.
    }

    if (crashData.externalLog) {
      try {
        const externalLogParsed: string[] = JSON.parse(crashData.externalLog) as string[];
        if (Array.isArray(externalLogParsed) && externalLogParsed.length > 0) {
          crashReport += `\nExternal Log Files (${externalLogParsed.length} files):\n`;
          for (let i = 0; i < externalLogParsed.length; i++) {
            crashReport += `  [${i + 1}] ${externalLogParsed[i]}\n`;
          }
        }
      } catch {
        crashReport += `\nExternal Log Files:\n  ${crashData.externalLog}\n`;
      }
    }

    if (crashData.memoryNearRegisters) {
      crashReport += `\nMemory near registers:\n${crashData.memoryNearRegisters}`;
      if (!crashData.memoryNearRegisters.endsWith('\n')) {
        crashReport += '\n';
      }
    }

    if (crashData.maps) {
      crashReport += `\nMaps:\n${crashData.maps}`;
      if (!crashData.maps.endsWith('\n')) {
        crashReport += '\n';
      }
    }

    if (crashData.hilog) {
      crashReport += `\nHilog:\n${crashData.hilog}`;
      if (!crashData.hilog.endsWith('\n')) {
        crashReport += '\n';
      }
    }

    return crashReport;
  }

  private formatExceptionDetails(exception: CrashExceptionData): string {
    let result = '';

    if (exception.signal) {
      const signo = exception.signal.signo ?? 0;
      const code = exception.signal.code ?? 0;
      const address = exception.signal.address ?? '0';
      let signalName = 'UNKNOWN';
      if (signo === 11) signalName = 'SIGSEGV';
      else if (signo === 6) signalName = 'SIGABRT';
      else if (signo === 8) signalName = 'SIGFPE';

      result += `Reason:Signal:${signalName}(${code})@${address}`;
      if (exception.message) {
        result += `  ${exception.message}`;
      }
      result += '\n';
    }

    if (exception.thread_name) {
      result += `Fault thread info:\n`;
      result += `Tid:${exception.tid || 'unknown'}, Name:${exception.thread_name}\n`;
      if (exception.frames && Array.isArray(exception.frames)) {
        for (let i = 0; i < exception.frames.length; i++) {
          const frame = exception.frames[i];
          const symbol = frame.symbol || '';
          const file = frame.file || '';
          const pc = frame.pc || '';
          if (file.includes('.ets') && frame.line) {
            result += `#${i.toString().padStart(2, '0')} at ${file}:${frame.line}:${frame.column || 0}\n`;
          } else if (symbol) {
            result += `#${i.toString().padStart(2, '0')} pc ${pc} ${file}(${symbol})\n`;
          } else {
            result += `#${i.toString().padStart(2, '0')} pc ${pc} ${file}\n`;
          }
        }
      }
    }

    return result;
  }

  private wrapPrimitive(value: string | number | boolean): PrimitiveWrapper {
    return { value: value };
  }

  private convertToRecordStringObject(
    input: Record<string, string | number | boolean | object>
  ): Record<string, object> {
    const result: Record<string, object> = {};
    const keys = Object.keys(input);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = input[key];
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
        result[key] = this.wrapPrimitive(value);
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  /**
   * Add a log entry to the runtime log buffer for crash reporting
   * @param level Log level (e.g., "D", "I", "W", "E")
   * @param tag Log tag
   * @param message Log message
   */
  public addLog(level: string, tag: string, message: string): boolean {
    try {
      return ftnativecrash.addLog(level, tag, message);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding log: ${error}`);
      return false;
    }
  }

  /**
   * Get collected runtime logs
   * @param maxLines Maximum number of lines to retrieve (0 for all)
   * @returns Collected logs as a string
   */
  public getCollectedLogs(maxLines?: number): string {
    try {
      return ftnativecrash.getCollectedLogs(maxLines || 0);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error getting collected logs: ${error}`);
      return "";
    }
  }

  /**
   * Clear the runtime log buffer
   */
  public clearLogs(): boolean {
    try {
      return ftnativecrash.clearLogs();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error clearing logs: ${error}`);
      return false;
    }
  }

  /**
   * Set the maximum log buffer size
   * @param maxSize Maximum number of log entries to keep
   */
  public setMaxLogSize(maxSize: number): boolean {
    try {
      return ftnativecrash.setMaxLogSize(maxSize);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error setting max log size: ${error}`);
      return false;
    }
  }
}

/**
 * Export the module
 */
export default FTNativeCrashHandler;
