import { describe, expect, it } from '@ohos/hypium';
import {
  isKnownWifiSignalLevel,
  shouldApplyWifiSignalSnapshot
} from '../../main/ets/components/utils/FTNetworkListener';

export default function ftNetworkListenerUnitTest() {
  describe('FTNetworkListenerUnit', () => {
    it('wifiSignalCallbackShouldRequireTheCapturedNetworkRevision', 0, () => {
      expect(shouldApplyWifiSignalSnapshot(42, 7, true, 42, 7)).assertTrue();
      expect(shouldApplyWifiSignalSnapshot(43, 7, true, 42, 7)).assertFalse();
      // netId can theoretically be reused; the revision still rejects a
      // callback that started before a disconnect/reconnect cycle.
      expect(shouldApplyWifiSignalSnapshot(42, 8, true, 42, 7)).assertFalse();
      expect(shouldApplyWifiSignalSnapshot(42, 7, false, 42, 7)).assertFalse();
      expect(shouldApplyWifiSignalSnapshot(0, 7, true, 0, 7)).assertFalse();
    });

    it('wifiSignalLevelShouldKeepOnlyPlatformDefinedLevels', 0, () => {
      expect(isKnownWifiSignalLevel(0)).assertTrue();
      expect(isKnownWifiSignalLevel(4)).assertTrue();
      expect(isKnownWifiSignalLevel(-1)).assertFalse();
      expect(isKnownWifiSignalLevel(5)).assertFalse();
      expect(isKnownWifiSignalLevel(1.5)).assertFalse();
    });
  });
}
