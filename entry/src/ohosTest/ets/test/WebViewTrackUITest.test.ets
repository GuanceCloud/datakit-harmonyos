import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
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

    it('webViewPageShouldExposeRumState', 0, async () => {
      await UiTestUtils.clickText(driver, 'WebView Test');

      const tracked = await EntryDBAssert.waitForWebViewPayload(6000);
      const record = await EntryDBAssert.waitForSyncRecordContaining(
        DataType.RUM_WEBVIEW,
        ['WebViewBridgeSmoke', 'is_web_view'],
        6000
      );

      expect(tracked).assertTrue();
      expect(record !== null).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
