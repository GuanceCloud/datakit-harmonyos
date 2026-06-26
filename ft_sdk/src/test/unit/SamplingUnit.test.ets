import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
import { CollectType } from '../../main/ets/components/rum/enum/RUMEnums';
import { SamplingUtils } from '../../main/ets/components/utils/SamplingUtils';

export default function samplingUnitTest() {
  describe('SamplingUnit', () => {
    beforeEach(() => {
      FTRUMInnerManager.getInstance().setSamplingRates(1, 0);
    });

    afterEach(() => {
      FTRUMInnerManager.getInstance().setSamplingRates(1, 0);
    });

    it('traceSamplingShouldBeDeterministic', 0, () => {
      expect(SamplingUtils.enableTraceSamplingRate(0)).assertFalse();
      expect(SamplingUtils.enableTraceSamplingRate(-1)).assertFalse();
      expect(SamplingUtils.enableTraceSamplingRate(1)).assertTrue();
      expect(SamplingUtils.enableTraceSamplingRate(2)).assertTrue();
    });

    it('sessionKeepShouldUseErrorSampling', 0, () => {
      const normal = SamplingUtils.checkSessionKeep('session-normal', 1, 0);
      expect(normal.sessionCollect).assertTrue();
      expect(normal.sessionErrorCollect).assertFalse();

      const errorSampled = SamplingUtils.checkSessionKeep('session-error', 0, 1);
      expect(errorSampled.sessionCollect).assertFalse();
      expect(errorSampled.sessionErrorCollect).assertTrue();

      const dropped = SamplingUtils.checkSessionKeep('session-drop', 0, 0);
      expect(dropped.sessionCollect).assertFalse();
      expect(dropped.sessionErrorCollect).assertFalse();
    });

    it('rumManagerShouldExposeCollectType', 0, () => {
      const manager = FTRUMInnerManager.getInstance();
      const sessionId = manager.getSessionId();

      manager.setSamplingRates(1, 0);
      expect(manager.checkSessionWillCollect(sessionId)).assertEqual(CollectType.ALL);

      manager.setSamplingRates(0, 1);
      expect(manager.checkSessionWillCollect(sessionId)).assertEqual(CollectType.SAMPLING);

      manager.setSamplingRates(0, 0);
      expect(manager.checkSessionWillCollect(sessionId)).assertEqual(CollectType.DROP);

      manager.setSamplingRates(1, 0);
      expect(manager.checkSessionWillCollect(sessionId)).assertEqual(CollectType.ALL);
    });
  });
}
