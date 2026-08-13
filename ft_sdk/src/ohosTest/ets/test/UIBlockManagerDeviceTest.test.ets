import { describe, beforeEach, afterEach, it } from '@ohos/hypium';
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

    it('shouldStartAndReleasePlatformObserver', 0, () => {
      manager.start(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTrackAppUIBlock(true, 1000));
      manager.setAppInForeground(true);
      manager.setAppInForeground(false);
      manager.release();
    });
  });
}
