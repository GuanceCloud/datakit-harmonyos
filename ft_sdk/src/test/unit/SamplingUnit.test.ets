import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
import { CollectType } from '../../main/ets/components/rum/enum/RUMEnums';
import { SamplingUtils } from '../../main/ets/components/utils/SamplingUtils';
import { ActiveViewBean } from '../../main/ets/components/rum/bean/ActiveViewBean';
import { ActiveActionBean } from '../../main/ets/components/rum/bean/ActiveActionBean';
import { ViewBean } from '../../main/ets/components/db/bean/ViewBean';
import { ActionBean } from '../../main/ets/components/db/bean/ActionBean';
import { Constants } from '../../main/ets/components/Constants';

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

    it('viewAndActionShouldKeepSamplingDecisionOutsideReportedAttributes', 0, () => {
      const view = new ActiveViewBean('Index', 'root', 0, 'previous-session');
      view.setCollectType(CollectType.SAMPLING);
      const storedView = view.convertToViewBean();
      expect(storedView.getCollectType()).assertEqual(CollectType.SAMPLING);
      const restoredView = new ViewBean('view', 'Index', 1);
      restoredView.setAttrJsonString(storedView.getAttrJsonString());
      expect(restoredView.getCollectType()).assertEqual(CollectType.SAMPLING);
      expect(Object.keys(restoredView.getProperty()).includes(Constants.KEY_RUM_COLLECT_TYPE)).assertFalse();

      const action = new ActiveActionBean('tap', 'click', 'previous-session', view.getId(), 'Index', 'root');
      action.setCollectType(CollectType.SAMPLING);
      const storedAction = action.convertToActionBean();
      expect(storedAction.getCollectType()).assertEqual(CollectType.SAMPLING);
      const restoredAction = new ActionBean('action', 'tap', 'click', 1);
      restoredAction.setAttrJsonString(storedAction.getAttrJsonString());
      expect(restoredAction.getCollectType()).assertEqual(CollectType.SAMPLING);
      expect(Object.keys(restoredAction.getProperty()).includes(Constants.KEY_RUM_COLLECT_TYPE)).assertFalse();
    });
  });
}
