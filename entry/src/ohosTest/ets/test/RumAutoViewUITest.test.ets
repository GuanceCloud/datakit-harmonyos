import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function rumAutoViewUITest() {
  describe('RumAutoViewUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('routeNavigationShouldCreateRumViewRecord', 0, async () => {
      await UiTestUtils.clickText(driver, 'RUM Unified Test');

      const view = await EntryDBAssert.waitForViewMatching(['RUMDataTestPage', 'RUM'], 6000);

      expect(view !== null).assertTrue();
      expect((view?.getViewName() ?? '').length > 0).assertTrue();
      expect((view?.getSessionId() ?? '').length > 0).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
