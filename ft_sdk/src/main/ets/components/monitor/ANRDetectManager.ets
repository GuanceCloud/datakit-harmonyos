import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import fs, { ReadOptions } from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { AppState, ErrorType } from '../rum/enum/RUMEnums';
import { Utils } from '../utils/Utils';

const TAG = 'ANRDetectManager';
const WATCHER_NAME = 'ft_sdk_anr_monitor';
const ANR_LANE_TRACE_PREFIX = '<FT-ANR-LANE>';

interface ErrorPropertyValue {
  value: string | number;
}

/**
 * Runtime ANR statistics.
 */
export interface ANRStats {
  anrEvents: number;
  startTime: number;
}

/**
 * Runtime ANR statistics with process uptime and monitor state.
 */
export interface ANRStatsWithUptime extends ANRStats {
  uptime: number;
  isMonitoring: boolean;
}

/**
 * ANR detection manager.
 *
 * Responsibility is intentionally narrow:
 * 1. Subscribe to HarmonyOS `APP_FREEZE` system events
 * 2. Merge freeze events from the same batch
 * 3. Convert HarmonyOS freeze payload into a RUM error event
 *
 * Crash, page lifecycle, click, scroll, and other monitoring concerns are
 * handled elsewhere and are intentionally excluded from this manager.
 */
export class ANRDetectManager {
  private static instance: ANRDetectManager | null = null;
  private static crashFileTaskSequence: number = 0;

  private isInitialized: boolean = false;
  private isMonitoring: boolean = false;
  private anrStats: ANRStats = {
    anrEvents: 0,
    startTime: 0
  };

  private constructor() {}

  /**
   * Get singleton instance.
   */
  public static getInstance(): ANRDetectManager {
    if (!ANRDetectManager.instance) {
      ANRDetectManager.instance = new ANRDetectManager();
    }
    return ANRDetectManager.instance;
  }

  /**
   * Initialize the ANR detector.
   */
  public initialize(): void {
    if (this.isInitialized) {
      FTInnerLogger.d(TAG, 'ANR detect manager already initialized, skipping');
      return;
    }

    this.anrStats.startTime = Date.now();
    this.isInitialized = true;
    FTInnerLogger.i(TAG, 'ANR detect manager initialized successfully');
  }

  /**
   * Start APP_FREEZE monitoring.
   */
  public startMonitoring(): void {
    if (!this.isInitialized) {
      FTInnerLogger.e(TAG, 'ANR detect manager not initialized');
      return;
    }

    if (this.isMonitoring) {
      FTInnerLogger.d(TAG, `Skip starting ANR monitoring, isMonitoring=${this.isMonitoring}`);
      return;
    }

    try {
      hiAppEvent.addWatcher({
        name: WATCHER_NAME,
        appEventFilters: [
          {
            domain: hiAppEvent.domain.OS,
            names: [hiAppEvent.event.APP_FREEZE]
          }
        ],
        onReceive: async (_domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          const freezeEvents: Array<hiAppEvent.AppEventInfo> = [];

          for (const group of appEventGroups) {
            for (const event of group.appEventInfos) {
              if (event.name === hiAppEvent.event.APP_FREEZE) {
                freezeEvents.push(event);
              }
            }
          }

          if (freezeEvents.length > 0) {
            FTInnerLogger.i(TAG, `ANR event received, freeze event count=${freezeEvents.length}`);
            this.anrStats.anrEvents++;
            this.recordMergedFreezeEvents(freezeEvents);
          }
        }
      });

      this.isMonitoring = true;
      FTInnerLogger.i(TAG, `ANR monitoring is now active, watcher=${WATCHER_NAME}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to start ANR monitoring: ${error}`);
    }
  }

  /**
   * Stop APP_FREEZE monitoring.
   */
  public stopMonitoring(): void {
    if (!this.isMonitoring) {
      FTInnerLogger.d(TAG, 'ANR monitoring is not running, skip stop');
      return;
    }

    try {
      hiAppEvent.removeWatcher({
        name: WATCHER_NAME
      });
      FTInnerLogger.i(TAG, `ANR monitoring stopped, watcher=${WATCHER_NAME}`);
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to remove ANR watcher: ${error}`);
    }

    this.isMonitoring = false;
  }

  /**
   * Reset the manager and release runtime state.
   */
  public shutdown(): void {
    this.stopMonitoring();
    this.isInitialized = false;
    this.anrStats = {
      anrEvents: 0,
      startTime: 0
    };
    FTInnerLogger.i(TAG, 'ANR detect manager shutdown completed');
  }

  /**
   * Get current ANR statistics.
   */
  public getStats(): ANRStatsWithUptime {
    return {
      anrEvents: this.anrStats.anrEvents,
      startTime: this.anrStats.startTime,
      uptime: Date.now() - this.anrStats.startTime,
      isMonitoring: this.isMonitoring
    };
  }

  /**
   * Merge a batch of APP_FREEZE events into a single RUM report.
   */
  private recordMergedFreezeEvents(events: Array<hiAppEvent.AppEventInfo>): void {
    if (events.length === 0) {
      return;
    }

    const primaryEvent = events[0];
    const mergedParams: Record<string, Object> = {};

    for (const event of events) {
      if (!event.params) {
        continue;
      }
      const params = event.params as Record<string, Object>;
      const paramKeys = Object.keys(params);
      for (let i = 0; i < paramKeys.length; i++) {
        const key = paramKeys[i];
        mergedParams[key] = params[key];
      }
    }

    const mergedEvent: hiAppEvent.AppEventInfo = {
      domain: primaryEvent.domain,
      name: primaryEvent.name,
      eventType: primaryEvent.eventType,
      params: mergedParams
    };

    this.recordANREventSafely('anr.freeze', mergedEvent);
  }

  /**
   * Convert a HarmonyOS APP_FREEZE event into a RUM error payload and upload it.
   */
  private async recordANREvent(event: hiAppEvent.AppEventInfo): Promise<void> {
    try {
      const rumManager = FTRUMInnerManager.getInstance();
      const dateline = Utils.getCurrentNanoTime();
      const anrMessage = 'harmony_anr';
      const params = event.params as Record<string, Object>;
      const allParamKeys = Object.keys(params);

      let stackTrace: string | null = null;
      const possibleStackFields = ['stack_trace', 'stack', 'trace', 'call_stack', 'backtrace', 'exception.stack'];

      if (params.threads) {
        if (typeof params.threads === 'string' && params.threads.length > 0) {
          stackTrace = params.threads as string;
        } else if (Array.isArray(params.threads)) {
          const threadsArray = params.threads as Array<Object>;
          let mainThreadIndex = -1;
          const processName = params.process_name ? String(params.process_name) : '';

          for (let i = 0; i < threadsArray.length; i++) {
            const thread = threadsArray[i] as Record<string, Object>;
            const threadName = thread.thread_name ? String(thread.thread_name).toLowerCase() : '';
            if (i === 0 || threadName.includes('main') || (processName && threadName.includes(processName.toLowerCase()))) {
              mainThreadIndex = i;
              break;
            }
          }

          if (mainThreadIndex === -1) {
            mainThreadIndex = 0;
          }

          const mainThread = threadsArray[mainThreadIndex] as Record<string, Object>;
          const threadName = mainThread.thread_name ? String(mainThread.thread_name) : `Thread ${mainThreadIndex}`;
          const threadId = mainThread.tid !== undefined ? String(mainThread.tid) : '';

          let threadStack = `Main Thread Stack Trace:\nTid:${threadId}, Name:${threadName}\n\n`;
          threadStack += 'Note: Stack trace shows current execution point, not the full call chain.\n';
          threadStack += 'For async operations (setTimeout, Promise), the caller may not appear in the stack.\n\n';

          if (mainThread.frames && Array.isArray(mainThread.frames)) {
            const frames = mainThread.frames as Array<Record<string, Object>>;
            for (let frameIndex = 0; frameIndex < frames.length; frameIndex++) {
              const frame = frames[frameIndex];
              const frameNum = `#${String(frameIndex).padStart(2, '0')}`;

              if (frame.pc && frame.symbol && frame.file) {
                const pc = String(frame.pc);
                const file = String(frame.file);
                const symbol = String(frame.symbol);
                const offset = frame.offset !== undefined ? `+${frame.offset}` : '';
                threadStack += `${frameNum} pc ${pc} ${file}(${symbol}${offset})\n`;
              } else if (frame.file && frame.line !== undefined) {
                const file = String(frame.file);
                const line = String(frame.line);
                const column = frame.column !== undefined ? `:${frame.column}` : '';
                const symbol = frame.symbol ? String(frame.symbol) : 'anonymous';
                threadStack += `${frameNum} at ${symbol} (${file}:${line}${column})\n`;
              } else {
                threadStack += `${frameNum} ${JSON.stringify(frame)}\n`;
              }
            }
          } else if (mainThread.stack && typeof mainThread.stack === 'string') {
            threadStack += mainThread.stack;
          } else if (mainThread.stack_trace && typeof mainThread.stack_trace === 'string') {
            threadStack += mainThread.stack_trace;
          } else if (mainThread.trace && typeof mainThread.trace === 'string') {
            threadStack += mainThread.trace;
          } else if (typeof mainThread === 'string') {
            threadStack += mainThread;
          } else {
            threadStack += JSON.stringify(mainThread, null, 2);
          }

          stackTrace = threadStack;
        } else if (typeof params.threads === 'object') {
          const threadObj = params.threads as Record<string, Object>;
          if (threadObj.stack && typeof threadObj.stack === 'string') {
            stackTrace = threadObj.stack as string;
          } else {
            stackTrace = JSON.stringify(threadObj, null, 2);
          }
        }
      }

      if (!stackTrace) {
        for (let i = 0; i < possibleStackFields.length; i++) {
          const fieldName = possibleStackFields[i];
          if (fieldName === 'exception.stack') {
            if (params.exception) {
              const exception = params.exception as Record<string, Object>;
              if (exception.stack && typeof exception.stack === 'string' && exception.stack.length > 0) {
                stackTrace = exception.stack;
                break;
              }
            }
          } else if (params[fieldName] && typeof params[fieldName] === 'string' && (params[fieldName] as string).length > 0) {
            stackTrace = params[fieldName] as string;
            break;
          }
        }
      }

      if (!stackTrace && params.event_handler) {
        if (typeof params.event_handler === 'string' && params.event_handler.length > 0) {
          stackTrace = `Event Handler:\n${params.event_handler}`;
        }
      }

      let anrStackTrace = `App freeze detected: ${event.name}\n\n`;

      if (params.freeze_type) {
        anrStackTrace += `Freeze Type: ${params.freeze_type}\n`;
      }

      if (params.exception) {
        const exception = params.exception as Record<string, Object>;
        anrStackTrace += 'Exception:\n';
        if (exception.type) {
          anrStackTrace += `  Type: ${exception.type}\n`;
        }
        if (exception.message) {
          anrStackTrace += `  Message: ${exception.message}\n`;
        }
      }

      if (params.hilog && Array.isArray(params.hilog)) {
        const hilogArray = params.hilog as string[];
        if (hilogArray.length > 0) {
          const maxLines = 50;
          const logLines = hilogArray.slice(0, maxLines);
          anrStackTrace += `\nRecent Logs (${hilogArray.length} total, showing first ${logLines.length}):\n`;
          anrStackTrace += logLines.join('\n');
          if (hilogArray.length > maxLines) {
            anrStackTrace += `\n... (${hilogArray.length - maxLines} more lines truncated)`;
          }
          anrStackTrace += '\n';
        }
      }

      if (params.event_handler) {
        let eventHandlerStr: string = '';
        if (typeof params.event_handler === 'string') {
          eventHandlerStr = params.event_handler as string;
        } else if (Array.isArray(params.event_handler)) {
          const eventHandlerArray = params.event_handler as Array<string>;
          eventHandlerStr = eventHandlerArray.join('\n');
        } else {
          eventHandlerStr = JSON.stringify(params.event_handler);
        }

        if (eventHandlerStr.length > 0) {
          anrStackTrace += `\nEvent Handler Information:\n${eventHandlerStr}\n`;
        }
      }

      if (stackTrace) {
        anrStackTrace += `\n${stackTrace}\n`;
      } else {
        anrStackTrace += '\nStack Trace: Not available (HarmonyOS system event does not provide stack trace)\n';
        FTInnerLogger.w(TAG, `Stack trace not found for ANR event, available fields: ${allParamKeys.join(', ')}`);
      }

      if (params.bundle_name) {
        anrStackTrace += `Bundle: ${params.bundle_name}`;
        if (params.bundle_version) {
          anrStackTrace += ` (${params.bundle_version})`;
        }
        anrStackTrace += '\n';
      }

      if (params.foreground !== undefined) {
        anrStackTrace += `Foreground: ${params.foreground}\n`;
      }

      if (params.external_log) {
        if (Array.isArray(params.external_log)) {
          const externalLogPaths = params.external_log as Array<string>;
          if (externalLogPaths.length > 0) {
            anrStackTrace += `\nSystem Log Files (${externalLogPaths.length} files):\n`;
            for (let i = 0; i < externalLogPaths.length; i++) {
              const filePath = externalLogPaths[i];
              try {
                const fileContent = this.readSystemLogFile(filePath);
                if (fileContent && fileContent.length > 0) {
                  anrStackTrace += `\n--- File ${i + 1}: ${filePath} ---\n`;
                  const maxFileSize = 50000;
                  if (fileContent.length > maxFileSize) {
                    anrStackTrace += fileContent.substring(0, maxFileSize);
                    anrStackTrace += `\n... (${fileContent.length - maxFileSize} more characters truncated)\n`;
                  } else {
                    anrStackTrace += fileContent;
                  }
                  anrStackTrace += `\n--- End of File ${i + 1} ---\n`;
                } else {
                  anrStackTrace += `\n--- File ${i + 1}: ${filePath} (empty or cannot read) ---\n`;
                }
              } catch (e) {
                const errorMsg = e instanceof Error ? e.message : String(e);
                anrStackTrace += `\n--- File ${i + 1}: ${filePath} (error: ${errorMsg}) ---\n`;
                FTInnerLogger.e(TAG, `Failed to read ANR log file ${filePath}: ${errorMsg}`);
              }
            }
          }
        } else if (typeof params.external_log === 'string' && params.external_log.length > 0) {
          try {
            const fileContent = this.readSystemLogFile(params.external_log as string);
            if (fileContent && fileContent.length > 0) {
              anrStackTrace += `\nSystem Log File: ${params.external_log}\n`;
              const maxFileSize = 50000;
              if (fileContent.length > maxFileSize) {
                anrStackTrace += fileContent.substring(0, maxFileSize);
                anrStackTrace += `\n... (${fileContent.length - maxFileSize} more characters truncated)\n`;
              } else {
                anrStackTrace += fileContent;
              }
            }
          } catch (e) {
            const errorMsg = e instanceof Error ? e.message : String(e);
            FTInnerLogger.e(TAG, `Failed to read ANR log file ${params.external_log}: ${errorMsg}`);
          }
        }
      }

      const systemLogDirs = [
        '/data/storage/el2/log/resourcelimit',
        '/data/storage/el2/log',
        '/data/log/faultlog/temp'
      ];

      for (let dirIndex = 0; dirIndex < systemLogDirs.length; dirIndex++) {
        const logDir = systemLogDirs[dirIndex];
        try {
          const logFiles = this.listLogFilesInDirectory(logDir, ['.log', '.txt']);
          if (logFiles.length > 0) {
            anrStackTrace += `\nSystem Log Directory: ${logDir} (${logFiles.length} files):\n`;
            for (let i = 0; i < logFiles.length && i < 5; i++) {
              const filePath = logFiles[i];
              try {
                const fileContent = this.readSystemLogFile(filePath);
                if (fileContent && fileContent.length > 0) {
                  anrStackTrace += `\n--- File: ${filePath} ---\n`;
                  const maxFileSize = 50000;
                  if (fileContent.length > maxFileSize) {
                    anrStackTrace += fileContent.substring(0, maxFileSize);
                    anrStackTrace += `\n... (${fileContent.length - maxFileSize} more characters truncated)\n`;
                  } else {
                    anrStackTrace += fileContent;
                  }
                  anrStackTrace += '\n--- End of File ---\n';
                }
              } catch (e) {
                FTInnerLogger.e(TAG, `Failed to read system log file ${filePath}: ${e}`);
              }
            }
            if (logFiles.length > 5) {
              anrStackTrace += `\n... (${logFiles.length - 5} more files in this directory)\n`;
            }
          }
        } catch (_) {}
      }

      if (params.event_handler_size_3s !== undefined) {
        anrStackTrace += `Event Handler Size (3s): ${params.event_handler_size_3s}\n`;
      }
      if (params.event_handler_size_6s !== undefined) {
        anrStackTrace += `Event Handler Size (6s): ${params.event_handler_size_6s}\n`;
      }

      anrStackTrace += '\n\nKey ANR Info:\n';
      if (params.freeze_type) {
        anrStackTrace += `  freeze_type: ${params.freeze_type}\n`;
      }
      if (params.pid !== undefined) {
        anrStackTrace += `  pid: ${params.pid}\n`;
      }
      if (params.uid !== undefined) {
        anrStackTrace += `  uid: ${params.uid}\n`;
      }
      if (params.time !== undefined) {
        anrStackTrace += `  time: ${params.time}\n`;
      }
      if (params.uuid) {
        anrStackTrace += `  uuid: ${params.uuid}\n`;
      }

      const anrProperty: Record<string, object> = {};
      if (params.freeze_type) {
        const freezeTypeValue: ErrorPropertyValue = { value: String(params.freeze_type) };
        anrProperty['freeze_type'] = freezeTypeValue;
      }
      if (params.bundle_name) {
        const bundleNameValue: ErrorPropertyValue = { value: String(params.bundle_name) };
        anrProperty['bundle_name'] = bundleNameValue;
      }
      if (params.bundle_version) {
        const bundleVersionValue: ErrorPropertyValue = { value: String(params.bundle_version) };
        anrProperty['bundle_version'] = bundleVersionValue;
      }
      if (params.foreground !== undefined) {
        const foregroundValue: ErrorPropertyValue = { value: String(params.foreground) };
        anrProperty['foreground'] = foregroundValue;
      }

      const appState = params.foreground === true ? AppState.RUN : AppState.BACKGROUND;
      await rumManager.addError(
        anrStackTrace,
        anrMessage,
        ErrorType.ANR_CRASH,
        appState,
        anrProperty,
        dateline
      );
      FTInnerLogger.i(TAG, `ANR event uploaded, freeze_type=${params.freeze_type ?? 'unknown'}, foreground=${params.foreground ?? 'unknown'}`);
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Error recording ANR event: ${errorMsg}`);
    }
  }

  private recordANREventSafely(name: string, event: hiAppEvent.AppEventInfo): void {
    const traceName = this.nextANRTaskName(name);
    this.traceANRLane(`[ENQUEUE] name=${traceName}`);
    const startTime = Date.now();
    this.recordANREvent(event)
      .then(() => {
        const costTime = Math.max(0, Date.now() - startTime);
        this.traceANRLane(`[CONSUMED] name=${traceName} result=success cost=${costTime}ms action=report-anr-error`);
      })
      .catch((error: Error) => {
        const costTime = Math.max(0, Date.now() - startTime);
        this.traceANRLane(`[CONSUMED] name=${traceName} result=failed error=${error.message} cost=${costTime}ms action=report-anr-error`);
        FTInnerLogger.e(TAG, `${ANR_LANE_TRACE_PREFIX} Failed to record ANR task: name=${traceName}, error=${error.message}`);
      });
  }

  private nextANRTaskName(name: string): string {
    ANRDetectManager.crashFileTaskSequence++;
    return `${name}#${ANRDetectManager.crashFileTaskSequence}`;
  }

  private traceANRLane(message: string): void {
    FTInnerLogger.i(TAG, `${ANR_LANE_TRACE_PREFIX} ${message}`);
  }

  /**
   * List log files in a directory for supplemental ANR diagnostics.
   */
  private listLogFilesInDirectory(dir: string, suffixes: string[]): string[] {
    const filePaths: string[] = [];
    try {
      if (!fs.accessSync(dir)) {
        return filePaths;
      }

      const stat = fs.statSync(dir);
      if (!stat.isDirectory()) {
        return filePaths;
      }

      const files = fs.listFileSync(dir);
      for (let i = 0; i < files.length; i++) {
        const fileName = files[i];
        const filePath = `${dir}/${fileName}`;
        let matches = false;

        for (let j = 0; j < suffixes.length; j++) {
          if (fileName.toLowerCase().endsWith(suffixes[j].toLowerCase())) {
            matches = true;
            break;
          }
        }

        if (!matches) {
          continue;
        }

        try {
          const fileStat = fs.statSync(filePath);
          if (fileStat.isFile()) {
            filePaths.push(filePath);
          }
        } catch (_) {}
      }
    } catch (_) {}

    return filePaths;
  }

  /**
   * Read a system log file referenced by the APP_FREEZE payload.
   */
  private readSystemLogFile(filePath: string): string {
    if (!filePath || filePath.length === 0) {
      return '';
    }

    try {
      if (!fs.accessSync(filePath)) {
        return '';
      }

      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      if (!file) {
        return '';
      }

      try {
        const stat = fs.statSync(filePath);
        const fileSize = stat.size;
        const chunkSize = 8192;
        let content = '';
        let offset = 0;

        while (offset < fileSize) {
          const remainingBytes = fileSize - offset;
          const readSize = remainingBytes > chunkSize ? chunkSize : remainingBytes;
          const arrayBuffer = new ArrayBuffer(readSize);
          const readOptions: ReadOptions = {
            offset: offset,
            length: readSize
          };

          const readLen = fs.readSync(file.fd, arrayBuffer, readOptions);
          if (readLen <= 0) {
            break;
          }

          const buf = buffer.from(arrayBuffer, 0, readLen);
          content += buf.toString('utf-8');
          offset += readLen;
        }

        fs.closeSync(file);
        return content;
      } catch (readError) {
        fs.closeSync(file);
        const errorMsg = readError instanceof Error ? readError.message : String(readError);
        FTInnerLogger.e(TAG, `Error reading file ${filePath}: ${errorMsg}`);
        return '';
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to read system log file ${filePath}: ${errorMsg}`);
      return '';
    }
  }
}
