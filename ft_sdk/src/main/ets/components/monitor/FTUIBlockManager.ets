import { FTRUMConfig } from '../Configs';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTInnerLogger } from '../log/FTLogger';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';

const TAG = 'FTUIBlockManager';
const MAIN_THREAD_JANK_EVENT = 'MAIN_THREAD_JANK';

export interface FTUIBlockManagerStatus {
  isRunning: boolean;
  isAppInForeground: boolean;
  usesPollingTimer: boolean;
}

/**
 * Detects foreground main-thread blocks and reports them as RUM LongTasks.
 *
 * Android attaches a Printer to the main Looper and receives exactly one start
 * and end callback for each dispatched main-thread message. HarmonyOS does not
 * expose that Looper API. MAIN_THREAD_JANK is the platform-provided equivalent:
 * it represents one measured main-thread stall and optionally includes its
 * heaviest stack. We intentionally do not add a polling timer because a timer
 * delayed by background scheduling is not a main-thread message duration and
 * can duplicate the platform event.
 */
export class FTUIBlockManager {
  public static readonly DEFAULT_TIME_BLOCK_MS = 1000;
  private static readonly MINI_TIME_BLOCK_NS = 100000000;
  private static instance: FTUIBlockManager | null = null;

  private blockDurationNS: number = FTUIBlockManager.DEFAULT_TIME_BLOCK_MS * 1000000;
  private isRunning: boolean = false;
  private isAppInForeground: boolean = false;
  private readonly appEventWatcherName: string = 'ft_sdk_main_thread_jank';

  private constructor() {
  }

  public static getInstance(): FTUIBlockManager {
    if (!FTUIBlockManager.instance) {
      FTUIBlockManager.instance = new FTUIBlockManager();
    }
    return FTUIBlockManager.instance;
  }

  /**
   * Starts the system main-thread-jank observer.
   * This has the same configuration gate as Android's FTUIBlockManager.start.
   */
  public start(config: FTRUMConfig): void {
    if (!config || config.getRumAppId().length === 0 || !config.isEnableTrackAppUIBlock()) {
      FTInnerLogger.d(TAG, 'UI block detection is disabled');
      return;
    }

    if (this.isRunning) {
      FTInnerLogger.d(TAG, 'UI block detection is already running');
      return;
    }

    const blockDurationMs = config.getBlockDurationMS() || FTUIBlockManager.DEFAULT_TIME_BLOCK_MS;
    this.blockDurationNS = Math.max(blockDurationMs * 1000000, FTUIBlockManager.MINI_TIME_BLOCK_NS);
    // Match Android's activity-count gate: do not collect until a foreground
    // lifecycle event has been received after SDK installation.
    this.isAppInForeground = false;
    this.isRunning = true;
    this.subscribeToMainThreadJankEvents();
    FTInnerLogger.i(TAG, `[FT-UI-BLOCK] UI block detection started with threshold: ${blockDurationMs}ms`);
  }

  /**
   * Updates the foreground gate used by Android's activity-count check.
   */
  public setAppInForeground(isInForeground: boolean): void {
    this.isAppInForeground = isInForeground;
  }

  /**
   * Internal status used by diagnostics and regression tests.
   */
  public getStatus(): FTUIBlockManagerStatus {
    return {
      isRunning: this.isRunning,
      isAppInForeground: this.isAppInForeground,
      usesPollingTimer: false
    };
  }

  /**
   * Stops the platform observer. This is the HarmonyOS equivalent of clearing
   * Android's Looper MessageLogging printer.
   */
  public release(): void {
    const wasRunning = this.isRunning;
    this.isRunning = false;
    this.isAppInForeground = false;
    if (wasRunning) {
      this.unsubscribeFromMainThreadJankEvents();
      FTInnerLogger.i(TAG, 'UI block detection stopped');
    }
  }

  private subscribeToMainThreadJankEvents(): void {
    try {
      hiAppEvent.addWatcher({
        name: this.appEventWatcherName,
        appEventFilters: [{
          domain: hiAppEvent.domain.OS,
          names: [MAIN_THREAD_JANK_EVENT]
        }],
        onReceive: (_domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          this.handleMainThreadJankEvents(appEventGroups);
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to subscribe to MAIN_THREAD_JANK events: ${String(error)}`);
    }
  }

  private unsubscribeFromMainThreadJankEvents(): void {
    try {
      hiAppEvent.removeWatcher({ name: this.appEventWatcherName });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to unsubscribe from MAIN_THREAD_JANK events: ${String(error)}`);
    }
  }

  private handleMainThreadJankEvents(appEventGroups: Array<hiAppEvent.AppEventGroup>): void {
    if (!this.isRunning || !this.isAppInForeground) {
      return;
    }

    try {
      appEventGroups.forEach((eventGroup: hiAppEvent.AppEventGroup) => {
        eventGroup.appEventInfos.forEach((eventInfo: hiAppEvent.AppEventInfo) => {
          if (eventInfo.name === MAIN_THREAD_JANK_EVENT) {
            this.reportMainThreadJank(eventInfo);
          }
        });
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Error handling MAIN_THREAD_JANK events: ${String(error)}`);
    }
  }

  private reportMainThreadJank(eventInfo: hiAppEvent.AppEventInfo): void {
    if (!this.isRunning || !this.isAppInForeground) {
      return;
    }

    try {
      const params = eventInfo.params as Record<string, Object>;
      const durationMs = this.getDurationMs(params);
      const durationNS = durationMs * 1000000;
      // Android reports only messages strictly over the configured threshold.
      if (durationNS <= this.blockDurationNS) {
        return;
      }

      FTRUMInnerManager.getInstance().addLongTask(
        this.getLongTaskMessage(params),
        durationNS,
        {}
      );
      FTInnerLogger.i(TAG, `[FT-UI-BLOCK] Reported foreground main-thread block: duration=${durationMs.toFixed(2)}ms`);
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to report MAIN_THREAD_JANK as long task: ${String(error)}`);
    }
  }

  private getDurationMs(params: Record<string, Object>): number {
    const candidates: Array<Object | undefined> = [
      params.duration,
      params.blockDuration,
      params.jankDuration
    ];
    for (let i = 0; i < candidates.length; i++) {
      const value = candidates[i];
      if (value === undefined) {
        continue;
      }
      const duration = Number(value);
      if (duration > 0) {
        return duration;
      }
    }
    return 0;
  }

  private getLongTaskMessage(params: Record<string, Object>): string {
    const method = typeof params.event_handler === 'string' && params.event_handler.length > 0
      ? params.event_handler
      : MAIN_THREAD_JANK_EVENT;
    const stackCandidates: Array<Object | undefined> = [
      params.heaviest_stack,
      params.exception,
      params.stackTrace,
      params.stack,
      params.trace
    ];
    for (let i = 0; i < stackCandidates.length; i++) {
      const value = stackCandidates[i];
      if (value === undefined) {
        continue;
      }
      const stack = typeof value === 'string' ? value : JSON.stringify(value);
      if (stack.length > 0) {
        return `${method}\n${stack}`;
      }
    }
    return method;
  }
}
