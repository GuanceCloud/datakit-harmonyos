import { describe, beforeEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function abilityTest() {
  describe('EntryAbilityBusinessTest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
    });

    it('entryAbilityShouldLaunchConfiguredSdkDemoHome', 0, async () => {
      const homeReady = await UiTestUtils.waitForText(driver, 'FT SDK HarmonyOS Test App', 6000);

      expect(homeReady).assertTrue();
    });

    it('entryShouldOpenRumPage', 0, async () => {
      await UiTestUtils.clickText(driver, 'RUM Unified Test');

      const pageReady = await UiTestUtils.waitForText(driver, 'RUM Unified Test Page', 6000);
      const sdkReady = await UiTestUtils.waitForText(driver, 'SDK Status: Initialized', 6000);

      expect(pageReady).assertTrue();
      expect(sdkReady).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
