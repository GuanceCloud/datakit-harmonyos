import { Constants } from './Constants';
import { FTInnerLogger } from './log/FTLogger';
import { AppState, ErrorType } from './rum/enum/RUMEnums';
import {
  DefaultFTNativeCrashHandlerRuntime,
  FTNativeCrashCallback,
  FTNativeCrashData,
  FTNativeCrashHandlerRuntime
} from './internal/runtime/FTNativeCrashHandlerRuntime';
import { SDKTaskPriority, SDKTaskRunner, SDKTaskScheduler, SDKTaskType } from './thread/SDKTaskScheduler';
import {
  createSDKWorkerTaskBridgeHandler,
  createSDKWorkerTaskFallbackRunner,
  createSDKWorkerTaskRequest
} from './thread/SDKWorkerTaskBridge';
import {
  SDKDedicatedPoolType,
  SDKWorkerCommand
} from './thread/SDKWorkerProtocol';

const TAG = "FTNativeCrashHandler";
const CRASH_FILE_TRACE_PREFIX = "<FT-CRASH-FILE-LANE>";
const NATIVE_CRASH_FILE_SERIAL_KEY = "native-crash-file";

export interface NativeCrashData extends FTNativeCrashData {
}

export type NativeCrashCallback = FTNativeCrashCallback;

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

export class FTNativeCrashHandler {
  private static runtime: FTNativeCrashHandlerRuntime = new DefaultFTNativeCrashHandlerRuntime();
  private static crashFileTaskSequence: number = 0;
  private isInitialized: boolean = false;
  private isWatching: boolean = false;

  public static setRuntimeInternal(runtime: FTNativeCrashHandlerRuntime): void {
    FTNativeCrashHandler.runtime = runtime;
  }

  public static resetRuntimeInternal(): void {
    FTNativeCrashHandler.runtime = new DefaultFTNativeCrashHandlerRuntime();
  }

  public async initialize(): Promise<boolean> {
    if (this.isInitialized) {
      FTInnerLogger.w(TAG, "Already initialized");
      return this.isWatching || this.startWatching();
    }

    try {
      FTInnerLogger.i(TAG, "=== Native Crash Handler Initialization Start ===");
      const nativeModule = FTNativeCrashHandler.runtime.getNativeCrashModule();
      const initResult: boolean = nativeModule.initNativeCrashHandler();
      FTInnerLogger.i(TAG, `initNativeCrashHandler result: ${initResult}`);
      if (!initResult) {
        FTInnerLogger.e(TAG, "Failed to initialize native crash handler");
        return false;
      }

      const callback: NativeCrashCallback = (crashData: FTNativeCrashData): Promise<void> => {
        return this.handleNativeCrash(crashData as NativeCrashData).catch((error: Error) => {
          FTInnerLogger.e(TAG, `<FT-ARKTS-CALLBACK> Failed to schedule native crash: ${error.message}`);
        });
      };
      const callbackResult: boolean = nativeModule.setCrashCallback(callback);
      FTInnerLogger.i(TAG, `setCrashCallback result: ${callbackResult}`);
      if (!callbackResult) {
        FTInnerLogger.e(TAG, "Failed to bind native crash callback");
        this.clearCrashCallbackSafely();
        return false;
      }

      this.isInitialized = true;
      const watchResult = this.startWatching();
      if (!watchResult) {
        FTInnerLogger.e(TAG, "Native crash handler initialized but failed to start watching");
        this.clearCrashCallbackSafely();
        this.isInitialized = false;
        return false;
      }

      FTInnerLogger.i(TAG, "=== Native Crash Handler Initialized Successfully ===");
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize native crash handler: ${error}`);
      this.clearCrashCallbackSafely();
      this.isInitialized = false;
      this.isWatching = false;
      return false;
    }
  }

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
      const result: boolean = FTNativeCrashHandler.runtime.getNativeCrashModule().startWatching();
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

  private clearCrashCallbackSafely(): void {
    try {
      FTNativeCrashHandler.runtime.getNativeCrashModule().clearCrashCallback();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error clearing native crash callback: ${error}`);
    }
  }

  public stopWatching(): void {
    if (!this.isWatching) {
      return;
    }

    try {
      FTNativeCrashHandler.runtime.getNativeCrashModule().stopWatching();
      this.isWatching = false;
      FTInnerLogger.i(TAG, "Stopped watching crash events");
    } catch (error) {
      FTInnerLogger.e(TAG, `Error stopping watcher: ${error}`);
    }
  }

  public shutdown(): void {
    this.stopWatching();
    this.clearCrashCallbackSafely();
    this.isInitialized = false;
    this.isWatching = false;
    FTInnerLogger.i(TAG, "Native crash handler shutdown");
  }

  public isReady(): boolean {
    return this.isInitialized && this.isWatching;
  }

  private async handleNativeCrash(crashData: NativeCrashData): Promise<void> {
    FTInnerLogger.i(TAG, "<FT-ARKTS-CALLBACK> *** ARKTS CALLBACK CALLED ***");
    FTInnerLogger.i(TAG, `<FT-ARKTS-CALLBACK> Crash data received: type=${crashData.crashType}`);
    const crashSnapshot = this.snapshotCrashData(crashData);
    await this.submitCrashFileTask(`crash.native:${crashSnapshot.crashType || 'unknown'}`, async () => {
      await this.processNativeCrash(crashSnapshot);
    }, crashSnapshot);
  }

  private async processNativeCrash(crashData: NativeCrashData): Promise<void> {
    const rumManager = FTNativeCrashHandler.runtime.getRumManager();
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

      try {
        await rumManager.addError(
          crashReport,
          `Native Crash: ${crashData.crashType}`,
          ErrorType.NATIVE_CRASH,
          AppState.RUN,
          this.convertToRecordStringObject(errorContext)
        );
      } finally {
        rumManager.clearSavedRumContext();
      }
      FTInnerLogger.i(TAG, "<FT-ARKTS-CALLBACK> *** CRASH REPORTED TO RUM SUCCESSFULLY ***");
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-ARKTS-CALLBACK> *** CALLBACK ERROR ***: ${error}`);
    }
  }

  private async submitCrashFileTask(name: string, task: SDKTaskRunner, crashData: NativeCrashData): Promise<void> {
    const traceName = this.nextCrashFileTaskName(name);
    const command = SDKWorkerCommand.CRASH_FILE_RUN;
    this.traceCrashFileLane(
      `[ENQUEUE] name=${traceName} type=${crashData.crashType || 'unknown'} memory=${this.getTextSize(crashData.memoryNearRegisters)} maps=${this.getTextSize(crashData.maps)} hilog=${this.getTextSize(crashData.hilog)} external=${this.getTextSize(crashData.externalLog)}`
    );

    const runTask = async () => {
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
        this.traceCrashFileLane(
          `[CONSUMED] name=${traceName} result=${result}${errorPart} cost=${costTime}ms action=report-rum-error`
        );
      }
    };

    await SDKTaskScheduler.getInstance().submitTaskAndWait({
      type: SDKTaskType.CRASH_FILE,
      name: traceName,
      priority: SDKTaskPriority.HIGH,
      serialKey: NATIVE_CRASH_FILE_SERIAL_KEY,
      costHint: 'heavy',
      workerRequest: createSDKWorkerTaskRequest(
        SDKDedicatedPoolType.DATA_PROCESS,
        command,
        traceName,
        SDKTaskPriority.HIGH
      ),
      workerFallbackRunner: createSDKWorkerTaskFallbackRunner(traceName, command, runTask),
      workerBridgeHandler: createSDKWorkerTaskBridgeHandler(traceName, command, runTask)
    });
  }

  private nextCrashFileTaskName(name: string): string {
    FTNativeCrashHandler.crashFileTaskSequence++;
    return `${name}#${FTNativeCrashHandler.crashFileTaskSequence}`;
  }

  private traceCrashFileLane(message: string): void {
    FTInnerLogger.i(TAG, `${CRASH_FILE_TRACE_PREFIX} ${message}`);
  }

  private getTextSize(value: string | null | undefined): number {
    return value ? value.length : 0;
  }

  private snapshotCrashData(crashData: NativeCrashData): NativeCrashData {
    return {
      timestamp: crashData.timestamp || Date.now(),
      crashType: crashData.crashType || 'Unknown',
      foreground: !!crashData.foreground,
      bundleVersion: crashData.bundleVersion || '',
      bundleName: crashData.bundleName || '',
      pid: crashData.pid || 0,
      uid: crashData.uid || 0,
      uuid: crashData.uuid || '',
      exception: crashData.exception || '',
      hilogSize: crashData.hilogSize || 0,
      externalLog: crashData.externalLog || '',
      logOverLimit: !!crashData.logOverLimit,
      memoryNearRegisters: crashData.memoryNearRegisters || '',
      maps: crashData.maps || '',
      hilog: crashData.hilog || ''
    };
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
      if (signo === 11) {
        signalName = 'SIGSEGV';
      } else if (signo === 6) {
        signalName = 'SIGABRT';
      } else if (signo === 8) {
        signalName = 'SIGFPE';
      }

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

  public addLog(level: string, tag: string, message: string): boolean {
    try {
      return FTNativeCrashHandler.runtime.getNativeCrashModule().addLog(level, tag, message);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding log: ${error}`);
      return false;
    }
  }

  public getVersion(): string {
    try {
      return FTNativeCrashHandler.runtime.getNativeCrashModule().getVersion();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error getting native crash version: ${error}`);
      return "";
    }
  }
}

export default FTNativeCrashHandler;
