import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { AppState, ErrorType } from '../rum/enum/RUMEnums';
import { Utils } from '../utils/Utils';
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKANRParseRequestDTO,
  SDKANRParseResultDTO,
  SDKDedicatedPoolType,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest
} from '../thread/SDKWorkerProtocol';

const TAG = 'ANRDetectManager';
const WATCHER_NAME = 'ft_sdk_anr_monitor';
const ANR_MAX_MERGED_EVENTS = 8;
const ANR_MAX_SCALAR_LENGTH = 4096;
const ANR_MAX_STACK_LENGTH = 64 * 1024;
const ANR_MAX_EVENT_HANDLER_LENGTH = 32 * 1024;
const ANR_MAX_HILOG_LINES = 50;
const ANR_MAX_HILOG_LINE_LENGTH = 2048;
const ANR_MAX_EXTERNAL_LOGS = 10;
const ANR_MAX_PATH_LENGTH = 1024;
const ANR_MAX_THREADS = 16;
const ANR_MAX_FRAMES_PER_THREAD = 128;
const ANR_PARAM_KEYS: string[] = [
  'freeze_type', 'exception', 'hilog', 'event_handler', 'threads', 'process_name',
  'stack_trace', 'stack', 'trace', 'call_stack', 'backtrace', 'bundle_name',
  'bundle_version', 'foreground', 'external_log', 'event_handler_size_3s',
  'event_handler_size_6s', 'pid', 'uid', 'time', 'uuid'
];
const ANR_THREAD_KEYS: string[] = [
  'thread_name', 'tid', 'stack', 'stack_trace', 'trace', 'frames'
];
const ANR_FRAME_KEYS: string[] = [
  'pc', 'symbol', 'file', 'offset', 'line', 'column'
];

interface ErrorPropertyValue {
  value: string | number;
}

export interface ANRStats {
  anrEvents: number;
  startTime: number;
}

export interface ANRStatsWithUptime extends ANRStats {
  uptime: number;
  isMonitoring: boolean;
}

/**
 * Copies only fields consumed by ANRWorker and applies a deterministic size
 * bound before crossing the ThreadWorker mailbox. Later APP_FREEZE envelopes
 * retain the existing overwrite semantics without retaining their source
 * objects on Host.
 */
export function normalizeANRParamsForWorker(
  sources: Array<Record<string, Object>>
): Record<string, Object> {
  const result: Record<string, Object> = {};
  const sourceStart = Math.max(0, sources.length - ANR_MAX_MERGED_EVENTS);
  // Later envelopes win. Resolve each whitelist key once so large arrays from
  // superseded events are never traversed on Host.
  for (let keyIndex = 0; keyIndex < ANR_PARAM_KEYS.length; keyIndex++) {
    const key = ANR_PARAM_KEYS[keyIndex];
    for (let sourceIndex = sources.length - 1; sourceIndex >= sourceStart; sourceIndex--) {
      const value = sources[sourceIndex][key];
      if (value === undefined || value === null) {
        continue;
      }
      const normalized = normalizeANRParamValue(key, value);
      if (normalized !== undefined) {
        result[key] = normalized;
      }
      break;
    }
  }
  return result;
}

function normalizeANRParamValue(key: string, value: Object | undefined): Object | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (key === 'exception') {
    return normalizeANRException(value);
  }
  if (key === 'hilog') {
    return normalizeANRStringArray(value, ANR_MAX_HILOG_LINES, ANR_MAX_HILOG_LINE_LENGTH);
  }
  if (key === 'external_log') {
    return normalizeANRStringArray(value, ANR_MAX_EXTERNAL_LOGS, ANR_MAX_PATH_LENGTH);
  }
  if (key === 'event_handler') {
    return normalizeANREventHandler(value);
  }
  if (key === 'threads') {
    return normalizeANRThreads(value);
  }
  if (key === 'stack_trace' || key === 'stack' || key === 'trace' ||
    key === 'call_stack' || key === 'backtrace') {
    return truncateANRString(value, ANR_MAX_STACK_LENGTH);
  }
  return normalizeANRScalar(value, ANR_MAX_SCALAR_LENGTH);
}

function normalizeANRException(value: Object): Object | undefined {
  if (typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const source = value as Record<string, Object>;
  const exception: Record<string, Object> = {};
  const type = normalizeANRScalar(source['type'], ANR_MAX_SCALAR_LENGTH);
  const message = normalizeANRScalar(source['message'], ANR_MAX_SCALAR_LENGTH);
  const stack = truncateANRString(source['stack'], ANR_MAX_STACK_LENGTH);
  if (type !== undefined) {
    exception['type'] = type;
  }
  if (message !== undefined) {
    exception['message'] = message;
  }
  if (stack !== undefined) {
    exception['stack'] = stack;
  }
  return exception;
}

function normalizeANREventHandler(value: Object): Object | undefined {
  if (typeof value === 'string') {
    return truncateString(value, ANR_MAX_EVENT_HANDLER_LENGTH);
  }
  if (!Array.isArray(value)) {
    return undefined;
  }
  const result: string[] = [];
  let remaining = ANR_MAX_EVENT_HANDLER_LENGTH;
  for (let i = 0; i < value.length && remaining > 0; i++) {
    const item = truncateString(String(value[i]), Math.min(ANR_MAX_HILOG_LINE_LENGTH, remaining));
    result.push(item);
    remaining -= item.length + 1;
  }
  return result;
}

function normalizeANRThreads(value: Object): Object | undefined {
  if (typeof value === 'string') {
    return truncateString(value, ANR_MAX_STACK_LENGTH);
  }
  if (Array.isArray(value)) {
    const threads: Object[] = [];
    const count = Math.min(value.length, ANR_MAX_THREADS);
    for (let i = 0; i < count; i++) {
      const thread = normalizeANRThread(value[i]);
      if (thread !== undefined) {
        threads.push(thread);
      }
    }
    return threads;
  }
  return normalizeANRThread(value);
}

function normalizeANRThread(value: Object): Object | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const source = value as Record<string, Object>;
  const thread: Record<string, Object> = {};
  for (let keyIndex = 0; keyIndex < ANR_THREAD_KEYS.length; keyIndex++) {
    const key = ANR_THREAD_KEYS[keyIndex];
    const rawValue = source[key];
    if (key === 'frames') {
      const frames = normalizeANRFrames(rawValue);
      if (frames !== undefined) {
        thread[key] = frames;
      }
      continue;
    }
    const limit = key === 'stack' || key === 'stack_trace' || key === 'trace' ?
      ANR_MAX_STACK_LENGTH : ANR_MAX_SCALAR_LENGTH;
    const normalized = normalizeANRScalar(rawValue, limit);
    if (normalized !== undefined) {
      thread[key] = normalized;
    }
  }
  return thread;
}

function normalizeANRFrames(value: Object | undefined): Object | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const sourceFrames = value as Object[];
  const result: Object[] = [];
  const count = Math.min(sourceFrames.length, ANR_MAX_FRAMES_PER_THREAD);
  for (let i = 0; i < count; i++) {
    const rawFrame: Object = sourceFrames[i];
    if (rawFrame === null || typeof rawFrame !== 'object' || Array.isArray(rawFrame)) {
      continue;
    }
    const source = rawFrame as Record<string, Object>;
    const frame: Record<string, Object> = {};
    for (let keyIndex = 0; keyIndex < ANR_FRAME_KEYS.length; keyIndex++) {
      const key = ANR_FRAME_KEYS[keyIndex];
      const normalized = normalizeANRScalar(source[key], ANR_MAX_SCALAR_LENGTH);
      if (normalized !== undefined) {
        frame[key] = normalized;
      }
    }
    result.push(frame);
  }
  return result;
}

function normalizeANRStringArray(value: Object, maxItems: number, maxLength: number): Object | undefined {
  if (typeof value === 'string') {
    return [truncateString(value, maxLength)];
  }
  if (!Array.isArray(value)) {
    return undefined;
  }
  const result: string[] = [];
  const count = Math.min(value.length, maxItems);
  for (let i = 0; i < count; i++) {
    result.push(truncateString(String(value[i]), maxLength));
  }
  return result;
}

function normalizeANRScalar(value: Object | undefined, maxLength: number): Object | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'string') {
    return truncateString(value, maxLength);
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  return undefined;
}

function truncateANRString(value: Object | undefined, limit: number): Object | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  return truncateString(String(value), limit);
}

function truncateString(value: string, limit: number): string {
  return value.length <= limit ? value : value.substring(0, limit);
}

/**
 * APP_FREEZE host adapter. The Host only merges event envelopes and reports the
 * final RUM error. Stack formatting, directory scans and file reads run in the
 * dedicated ANR ThreadWorker.
 */
export class ANRDetectManager {
  private static instance: ANRDetectManager | null = null;
  private static anrTaskSequence: number = 0;

  private isInitialized: boolean = false;
  private isMonitoring: boolean = false;
  private anrStats: ANRStats = {
    anrEvents: 0,
    startTime: 0
  };

  private constructor() {}

  public static getInstance(): ANRDetectManager {
    if (!ANRDetectManager.instance) {
      ANRDetectManager.instance = new ANRDetectManager();
    }
    return ANRDetectManager.instance;
  }

  public initialize(): void {
    if (this.isInitialized) {
      FTInnerLogger.d(TAG, 'ANR detect manager already initialized, skipping');
      return;
    }
    this.anrStats.startTime = Date.now();
    this.isInitialized = true;
    FTInnerLogger.i(TAG, 'ANR detect manager initialized successfully');
  }

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
      FTInnerLogger.e(TAG, `Failed to start ANR monitoring: ${String(error)}`);
    }
  }

  public stopMonitoring(): void {
    if (!this.isMonitoring) {
      FTInnerLogger.d(TAG, 'ANR monitoring is not running, skip stop');
      return;
    }
    try {
      hiAppEvent.removeWatcher({ name: WATCHER_NAME });
      FTInnerLogger.i(TAG, `ANR monitoring stopped, watcher=${WATCHER_NAME}`);
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to remove ANR watcher: ${String(error)}`);
    }
    this.isMonitoring = false;
  }

  public shutdown(): void {
    this.stopMonitoring();
    this.isInitialized = false;
    this.anrStats = {
      anrEvents: 0,
      startTime: 0
    };
    FTInnerLogger.i(TAG, 'ANR detect manager shutdown completed');
  }

  public getStats(): ANRStatsWithUptime {
    return {
      anrEvents: this.anrStats.anrEvents,
      startTime: this.anrStats.startTime,
      uptime: Date.now() - this.anrStats.startTime,
      isMonitoring: this.isMonitoring
    };
  }

  private recordMergedFreezeEvents(events: Array<hiAppEvent.AppEventInfo>): void {
    if (events.length === 0) {
      return;
    }
    const primaryEvent = events[0];
    const paramSources: Array<Record<string, Object>> = [];
    const start = Math.max(0, events.length - ANR_MAX_MERGED_EVENTS);
    for (let eventIndex = start; eventIndex < events.length; eventIndex++) {
      const event = events[eventIndex];
      if (!event.params) {
        continue;
      }
      paramSources.push(event.params as Record<string, Object>);
    }
    const mergedParams = normalizeANRParamsForWorker(paramSources);
    this.recordANREventSafely('anr.freeze', primaryEvent.name, mergedParams);
  }

  private recordANREventSafely(name: string, eventName: string, params: Record<string, Object>): void {
    const traceName = this.nextANRTaskName(name);
    this.traceANRLane(`[ENQUEUE] name=${traceName}`);
    const startedAt = Date.now();
    const payload: SDKANRParseRequestDTO = {
      eventName,
      params,
      dateline: Utils.getCurrentNanoTime()
    };
    const request: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.ANR_PARSE_EVENT}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.ANR,
      command: SDKWorkerCommand.ANR_PARSE_EVENT,
      priority: SDKTaskPriority.CRITICAL,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    SDKDedicatedPoolManager.getInstance().executeCommand(request)
      .then(async (response) => {
        if (!response.ok || !response.payload) {
          throw new Error(response.errorMessage || 'ANRWorker returned an empty response');
        }
        const parsed = response.payload as Object as SDKANRParseResultDTO;
        await this.reportParsedANR(parsed);
        const costTime = Math.max(0, Date.now() - startedAt);
        this.traceANRLane(
          `[CONSUMED] name=${traceName} result=success cost=${costTime}ms files=${parsed.filesRead} truncated=${
            parsed.truncatedFiles} action=report-anr-error`
        );
      })
      .catch((error: Error) => {
        const costTime = Math.max(0, Date.now() - startedAt);
        this.traceANRLane(
          `[CONSUMED] name=${traceName} result=failed error=${error.message} cost=${costTime}ms action=report-anr-error`
        );
        FTInnerLogger.e(TAG, `Failed to record ANR task: name=${traceName}, error=${error.message}`);
      });
  }

  private async reportParsedANR(parsed: SDKANRParseResultDTO): Promise<void> {
    if (parsed.missingStack) {
      FTInnerLogger.w(TAG, 'Stack trace not found for ANR event');
    }
    const properties: Record<string, object> = {};
    const keys = Object.keys(parsed.properties);
    for (let i = 0; i < keys.length; i++) {
      const value: ErrorPropertyValue = { value: parsed.properties[keys[i]] };
      properties[keys[i]] = value;
    }
    await FTRUMInnerManager.getInstance().addError(
      parsed.stackTrace,
      parsed.message,
      ErrorType.ANR_CRASH,
      parsed.foreground ? AppState.RUN : AppState.BACKGROUND,
      properties,
      parsed.dateline
    );
    FTInnerLogger.i(TAG,
      `ANR event uploaded, freeze_type=${parsed.freezeType || 'unknown'}, foreground=${parsed.foreground}`);
  }

  private nextANRTaskName(name: string): string {
    ANRDetectManager.anrTaskSequence++;
    return `${name}#${ANRDetectManager.anrTaskSequence}`;
  }

  private traceANRLane(message: string): void {
    FTInnerLogger.d(TAG, `ANR task diagnostics: ${message}`);
  }
}
