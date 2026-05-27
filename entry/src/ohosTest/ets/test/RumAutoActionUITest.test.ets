import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function rumAutoActionUITest() {
  describe('RumAutoActionUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('buttonClickShouldCreateRumActionRecord', 0, async () => {
      await UiTestUtils.clickText(driver, 'Button Click Auto-Tracking Test');
      await UiTestUtils.clickText(driver, 'Test Button 1 - Basic Click');

      const action = await EntryDBAssert.waitForActionMatching(['Test Button 1 - Basic Click', 'test-button-1'], 6000);

      expect(action !== null).assertTrue();
      expect(action?.getActionType() ?? '').assertEqual('click');
      expect((action?.getSessionId() ?? '').length > 0).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
