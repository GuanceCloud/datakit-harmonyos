import { systemDateTime } from '@kit.BasicServicesKit';
import { FTSDK } from '../FTSDK';
import { FTConsoleLogBridge } from '../log/FTConsoleLogBridge';
import { FTInnerLogger } from '../log/FTLogger';
import { FTAppLaunchTracker } from './FTAppLaunchTracker';

const TAG = 'FTColdLaunchBridge';

interface FTColdLaunchFrameMetrics {
  firstDrawFrame?: boolean;
}

interface FTColdLaunchMainWindow {
  on(event: string, callback: (frameMetrics: FTColdLaunchFrameMetrics) => void): void;
  off(event: string, callback: (frameMetrics: FTColdLaunchFrameMetrics) => void): void;
}

interface FTColdLaunchWindowStage {
  getMainWindowSync(): FTColdLaunchMainWindow;
}

interface FTColdLaunchIntentContext {
  instanceId?: number | string;
}

/**
 * Runtime contract for the Hvigor compiler plugin.
 *
 * Cold-launch lifecycle boundaries are injected into application Ability
 * sources at build time. This bridge is intentionally not an integration API.
 */
export class FTColdLaunchBridge {
  private static firstFrameListeners: Array<() => void> = [];
  private static observedWindowStages: Object[] = [];

  public static recordApplicationInit(context?: Object, pluginVersion?: string): void {
    if (pluginVersion && pluginVersion.trim().length > 0) {
      FTSDK.registerHvigorPluginVersion(pluginVersion);
    }
    // Cold-launch instrumentation is loaded by the same Hvigor tool package
    // as console/HiLog instrumentation. Mark it before application code
    // installs the log configuration, even if this source has no console call
    // for the console transform to rewrite.
    FTConsoleLogBridge.markCompilerPluginInstalled();
    FTSDK.recordAppApplicationInit(context);
  }

  public static recordFirstUIAbilityCreate(launchParam?: Object, want?: Object, ability?: Object): void {
    FTSDK.recordAppFirstUIAbilityCreate(launchParam, want, ability);
  }

  /** Compiler hook for real InsightIntent execution, not a host override of launch type. */
  public static recordInsightIntentExecute(executeMode: number, intentName: string = '', context?: Object,
    abilityName: string = ''): void {
    // instanceId is optional on older systems. Structural typing keeps the
    // core HAR independent of the API 23 InsightIntentContext declaration.
    const instanceId = (context as FTColdLaunchIntentContext | undefined)?.instanceId;
    const intentId = typeof instanceId === 'string' ? instanceId.trim() :
      (typeof instanceId === 'number' && Number.isSafeInteger(instanceId) && instanceId > 0 ? String(instanceId) : '');
    FTAppLaunchTracker.getInstance().recordInsightIntentExecute(executeMode, intentName, intentId, abilityName);
  }

  public static recordUIAbilityForeground(ability: Object): void {
    FTAppLaunchTracker.getInstance().recordUIAbilityForeground(ability);
  }

  public static recordUIAbilityNewWant(ability: Object): void {
    FTAppLaunchTracker.getInstance().recordUIAbilityNewWant(ability);
  }

  public static recordUIAbilityBackground(ability: Object): void {
    FTAppLaunchTracker.getInstance().recordUIAbilityBackground(ability);
  }

  /** Internal callback hook for instrumented and SDK-owned launch flows. */
  public static onFirstFrameRecorded(listener: () => void): void {
    FTColdLaunchBridge.firstFrameListeners.push(listener);
  }

  /**
   * Internal diagnostic hook for the repository demo. It reports the SDK's
   * real no-UI background-launch classification without fabricating a
   * UIAbility or first-frame boundary. Classification is not submission:
   * the Action still waits for a real first frame in this process.
   */
  public static onBackgroundLaunchDetected(listener: () => void): () => void {
    return FTAppLaunchTracker.getInstance().onBackgroundLaunchDetected(listener);
  }

  /** Internal demo hook: accepted by the RUM pipeline, not a server acknowledgement. */
  public static onColdLaunchReported(
    listener: (launchType: 'foreground' | 'background') => void
  ): () => void {
    const tracker = FTAppLaunchTracker.getInstance();
    return tracker.onReportSubmitted((): void => {
      const launchType = tracker.getSnapshot().launchType;
      if (launchType !== null) {
        listener(launchType);
      }
    });
  }

  /**
   * Observes the first drawn frame when the platform supports frame metrics.
   * The structural interfaces keep the core HAR compatible with applications
   * built against API levels where frame-metrics types are unavailable.
   */
  public static observeFirstFrame(windowStage: Object): boolean {
    if (FTColdLaunchBridge.hasObservedWindowStage(windowStage)) {
      return true;
    }
    try {
      const mainWindow = (windowStage as FTColdLaunchWindowStage).getMainWindowSync();
      const callback = (frameMetrics: FTColdLaunchFrameMetrics): void => {
        if (!frameMetrics || !frameMetrics.firstDrawFrame) {
          return;
        }
        let uptimeNs = 0;
        try {
          uptimeNs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
        } catch (error) {
          FTInnerLogger.d(TAG, `Unable to read first-frame startup uptime: ${String(error)}`);
        }
        try {
          mainWindow.off('frameMetricsMeasured', callback);
        } catch (error) {
          FTInnerLogger.d(TAG, `Unable to remove first-frame listener: ${String(error)}`);
        }
        FTSDK.recordAppFirstFrame(uptimeNs);
        FTColdLaunchBridge.notifyFirstFrameRecorded();
      };
      mainWindow.on('frameMetricsMeasured', callback);
      FTColdLaunchBridge.observedWindowStages.push(windowStage);
      return true;
    } catch (error) {
      // Frame metrics are not available on every compatible API level. The
      // remaining cold-launch boundaries are still collected in that case.
      FTInnerLogger.d(TAG, `First-frame observation is unavailable: ${String(error)}`);
      return false;
    }
  }

  private static hasObservedWindowStage(windowStage: Object): boolean {
    return FTColdLaunchBridge.observedWindowStages.some((observedWindowStage: Object) =>
      observedWindowStage === windowStage);
  }

  private static notifyFirstFrameRecorded(): void {
    const listeners = FTColdLaunchBridge.firstFrameListeners.slice();
    FTColdLaunchBridge.firstFrameListeners = [];
    for (let index = 0; index < listeners.length; index++) {
      try {
        listeners[index]();
      } catch (error) {
        FTInnerLogger.d(TAG, `First-frame callback failed: ${String(error)}`);
      }
    }
  }
}
