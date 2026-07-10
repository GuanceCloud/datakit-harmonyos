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
    const mergedParams: Record<string, Object> = {};
    for (const event of events) {
      if (!event.params) {
        continue;
      }
      const params = event.params as Record<string, Object>;
      const keys = Object.keys(params);
      for (let i = 0; i < keys.length; i++) {
        mergedParams[keys[i]] = params[keys[i]];
      }
    }
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
