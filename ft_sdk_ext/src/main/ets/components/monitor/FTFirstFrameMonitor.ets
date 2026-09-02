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
 * `onFirstFrameRecorded` runs only after the first-frame timestamp has been handed to ft_sdk. It is
 * optional so existing integrations keep the original one-argument API.
 */
export function observeFTAppFirstFrame(
  windowStage: window.WindowStage,
  onFirstFrameRecorded?: () => void
): boolean {
  try {
    const mainWindow = windowStage.getMainWindowSync();
    const callback = (frameMetrics: window.FrameMetrics): void => {
      if (!frameMetrics || !frameMetrics.firstDrawFrame) {
        return;
      }
      // Capture the first-frame timestamp at callback entry before any unregistration work. This is
      // intentionally the same STARTUP uptime source as application initialization and UIAbility creation, not the API 22
      // vsync timestamp whose time origin still requires device validation.
      let callbackUptimeNs = 0;
      try {
        callbackUptimeNs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
      } catch (error) {
        console.warn(`${TAG}: failed to read STARTUP uptime: ${String(error)}`);
      }
      try {
        mainWindow.off('frameMetricsMeasured', callback);
      } catch (error) {
        console.warn(`${TAG}: failed to remove first-frame listener: ${String(error)}`);
      }
      FTSDK.recordAppFirstFrame(callbackUptimeNs);
      try {
        onFirstFrameRecorded?.();
      } catch (error) {
        console.warn(`${TAG}: first-frame completion callback failed: ${String(error)}`);
      }
    };
    mainWindow.on('frameMetricsMeasured', callback);
    return true;
  } catch (error) {
    console.warn(`${TAG}: first-frame observation unavailable: ${String(error)}`);
    return false;
  }
}
