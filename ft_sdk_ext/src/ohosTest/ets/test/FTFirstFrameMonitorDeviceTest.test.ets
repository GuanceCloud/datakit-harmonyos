import { describe, expect, it } from '@ohos/hypium';
import window from '@ohos.window';
import { observeFTAppFirstFrame } from '../../../main/ets/components/monitor/FTFirstFrameMonitor';

type FrameMetricsCallback = (frameMetrics: window.FrameMetrics) => void;

/**
 * The test itself runs in the API 22 ohosTest target. The Window is a focused
 * callback double so it can deterministically verify the listener's one-shot
 * contract without relying on device rendering speed.
 */
class FirstFrameTestWindow {
  public onCalls: number = 0;
  public offCalls: number = 0;
  private callback: FrameMetricsCallback | null = null;

  public on(type: 'frameMetricsMeasured', callback: FrameMetricsCallback): void {
    this.onCalls++;
    this.callback = callback;
  }

  public off(type: 'frameMetricsMeasured', callback: FrameMetricsCallback): void {
    this.offCalls++;
    if (this.callback === callback) {
      this.callback = null;
    }
  }

  public emit(firstDrawFrame: boolean): void {
    const callback = this.callback;
    if (callback) {
      callback({ firstDrawFrame } as window.FrameMetrics);
    }
  }
}

class FirstFrameTestWindowStage {
  public readonly mainWindow: FirstFrameTestWindow = new FirstFrameTestWindow();

  public getMainWindowSync(): window.Window {
    return this.mainWindow as Object as window.Window;
  }
}

export default function ftFirstFrameMonitorDeviceTest() {
  describe('FTFirstFrameMonitorDeviceTest', () => {
    it('firstFrameRemovesListener', 0, () => {
      const windowStage = new FirstFrameTestWindowStage();

      const registered = observeFTAppFirstFrame(windowStage as Object as window.WindowStage);
      expect(registered).assertTrue();
      expect(windowStage.mainWindow.onCalls).assertEqual(1);

      windowStage.mainWindow.emit(false);
      expect(windowStage.mainWindow.offCalls).assertEqual(0);

      windowStage.mainWindow.emit(true);
      expect(windowStage.mainWindow.offCalls).assertEqual(1);

      // Emitting a later frame does nothing because the one-shot listener has
      // been removed, so the first-frame timestamp cannot be recorded a second time.
      windowStage.mainWindow.emit(true);
      expect(windowStage.mainWindow.offCalls).assertEqual(1);
    });
  });
}
