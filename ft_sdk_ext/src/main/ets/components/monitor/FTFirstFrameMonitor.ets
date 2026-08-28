import window from '@ohos.window';
import { systemDateTime } from '@kit.BasicServicesKit';
import { FTSDK } from '@guancecloud/ft_sdk/Index';

const TAG = 'FTFirstFrameMonitor';

/**
 * Registers an API 22 first-frame observer for the given WindowStage.
 *
 * Call this at the very beginning of UIAbility.onWindowStageCreate(), before
 * loadContent(). The callback itself is the authoritative first-frame signal;
 * its arrival time is recorded through ft_sdk's STARTUP uptime clock. We do
 * not consume vsyncTimestamp until API 22 device validation confirms it has
 * the same time origin as systemDateTime.getUptime(STARTUP, true).
 */
/**
 * `onFirstFrameRecorded` runs only after T3 has been handed to ft_sdk. It is
 * optional so existing integrations keep the original one-argument API.
 */
export function observeFTAppFirstFrame(
  windowStage: window.WindowStage,
  onFirstFrameRecorded?: () => void
): boolean {
  try {
    const mainWindow = windowStage.getMainWindowSync();
    let firstFrameMetricsObserved = false;
    const callback = (frameMetrics: window.FrameMetrics): void => {
      if (!firstFrameMetricsObserved) {
        firstFrameMetricsObserved = true;
        console.info(`${TAG}: first frameMetricsMeasured received, firstDrawFrame=${String(frameMetrics?.firstDrawFrame)}`);
      }
      if (!frameMetrics || !frameMetrics.firstDrawFrame) {
        return;
      }
      // Capture T3 at callback entry before any unregistration work. This is
      // intentionally the same STARTUP uptime source as T0-T2, not the API 22
      // vsync timestamp whose time origin still requires device validation.
      let callbackUptimeNs = 0;
      try {
        callbackUptimeNs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
      } catch (error) {
        console.warn(`${TAG}: failed to read STARTUP uptime: ${String(error)}`);
      }
      console.info(`${TAG}: firstDrawFrame=true; recording T3 uptimeNs=${callbackUptimeNs}`);
      try {
        mainWindow.off('frameMetricsMeasured', callback);
      } catch (error) {
        console.warn(`${TAG}: failed to remove first-frame listener: ${String(error)}`);
      }
      FTSDK.recordAppFirstFrame(callbackUptimeNs);
      console.info(`${TAG}: T3 submitted to ft_sdk`);
      try {
        onFirstFrameRecorded?.();
      } catch (error) {
        console.warn(`${TAG}: first-frame completion callback failed: ${String(error)}`);
      }
    };
    mainWindow.on('frameMetricsMeasured', callback);
    console.info(`${TAG}: frameMetricsMeasured listener registered`);
    return true;
  } catch (error) {
    console.warn(`${TAG}: first-frame observation unavailable: ${String(error)}`);
    return false;
  }
}
