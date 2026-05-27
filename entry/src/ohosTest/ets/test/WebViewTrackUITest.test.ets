import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function webViewTrackUITest() {
  describe('WebViewTrackUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('webViewPageShouldSetHandlerAndCreateObservableRumState', 0, async () => {
      await UiTestUtils.clickText(driver, 'WebView Test');

      const tracked = await EntryDBAssert.waitForWebViewPayload(6000);

      expect(tracked).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
