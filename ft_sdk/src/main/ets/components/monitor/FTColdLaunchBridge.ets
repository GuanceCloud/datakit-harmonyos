import { systemDateTime } from '@kit.BasicServicesKit';
import { FTSDK } from '../FTSDK';
import { FTInnerLogger } from '../log/FTLogger';

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

/**
 * Runtime contract for the Hvigor compiler plugin.
 *
 * Cold-launch lifecycle boundaries are injected into application Ability
 * sources at build time. This bridge is intentionally not an integration API.
 */
export class FTColdLaunchBridge {
  private static firstFrameListeners: Array<() => void> = [];

  public static recordApplicationInit(context?: Object): void {
    FTSDK.recordAppApplicationInit(context);
  }

  public static recordFirstUIAbilityCreate(): void {
    FTSDK.recordAppFirstUIAbilityCreate();
  }

  /** Internal callback hook for instrumented and SDK-owned launch flows. */
  public static onFirstFrameRecorded(listener: () => void): void {
    FTColdLaunchBridge.firstFrameListeners.push(listener);
  }

  /**
   * Observes the first drawn frame when the platform supports frame metrics.
   * The structural interfaces keep the core HAR compatible with applications
   * built against API levels where frame-metrics types are unavailable.
   */
  public static observeFirstFrame(windowStage: Object): void {
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
    } catch (error) {
      // Frame metrics are not available on every compatible API level. The
      // remaining cold-launch boundaries are still collected in that case.
      FTInnerLogger.d(TAG, `First-frame observation is unavailable: ${String(error)}`);
    }
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
