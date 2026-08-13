import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTUIBlockManager } from '../../../main/ets/components/monitor/FTUIBlockManager';

const TEST_FAKE_RUM_ID = 'rumId';

export default function uiBlockManagerDeviceTest() {
  describe('UIBlockManagerDeviceTest', () => {
    const manager = FTUIBlockManager.getInstance();

    beforeEach(() => {
      manager.release();
    });

    afterEach(() => {
      manager.release();
    });

    it('shouldUsePlatformObserverWithoutPollingTimer', 0, () => {
      manager.start(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 1000));

      const running = manager.getStatus();
      expect(running.isRunning).assertTrue();
      expect(running.isAppInForeground).assertFalse();
      expect(running.usesPollingTimer).assertFalse();

      manager.setAppInForeground(true);
      expect(manager.getStatus().isAppInForeground).assertTrue();
      manager.setAppInForeground(false);
      expect(manager.getStatus().isAppInForeground).assertFalse();

      manager.release();
      const released = manager.getStatus();
      expect(released.isRunning).assertFalse();
      expect(released.isAppInForeground).assertFalse();
    });
  });
}
