import { describe, beforeEach, afterEach, it } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryRecordCapture } from './helpers/EntryRecordCapture';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function webViewTrackUITest() {
  describe('WebViewTrackUITest', () => {
    let driver: Driver;
    let capture: EntryRecordCapture;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      capture = new EntryRecordCapture();
      capture.start();
    });

    afterEach(async () => {
      if (capture) capture.stop();
      await EntryDBAssert.cleanupAll();
    });

    it('webViewPageShouldExposeRumState', 0, async () => {
      UiTestUtils.requireConfiguredPageUrl('webViewUrl');
      const marker = UiTestUtils.getWebViewExpectedMarker();
      await UiTestUtils.clickText(driver, 'WebView Test');

      const tracked = await capture.waitForRecord(DataType.RUM_WEBVIEW, [], 12000);
      if (!tracked) {
        throw new Error('No RUM_WEBVIEW record after opening WebView Test. Check that webViewUrl loads ' +
          'and the page emits RUM events through the SDK JavaScript bridge.\n' +
          `Current sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`);
      }
      const record = await capture.waitForRecord(
        DataType.RUM_WEBVIEW,
        [marker, 'is_web_view'],
        6000
      );

      if (record === null) {
        throw new Error(`WebView data exists but lacks marker "${marker}" or is_web_view. ` +
          'Set entryWebViewExpectedMarker to an event emitted by the configured page.\n' +
          `Current sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`);
      }

      await UiTestUtils.pressBack(driver);
    });
  });
}
