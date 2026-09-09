import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { SyncDataHelper } from '@guancecloud/ft_sdk/src/main/ets/components/SyncDataHelper';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryRecordCapture } from './helpers/EntryRecordCapture';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function traceAutoTrackUITest() {
  describe('TraceAutoTrackUITest', () => {
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

    it('httpPageShouldCreateTraceResource', 0, async () => {
      const traceUrl = UiTestUtils.requireConfiguredPageUrl('traceUrl');
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      // The page label is intentionally generic because traceUrl is supplied
      // at launch. Use its stable ID instead of the removed sample endpoint.
      await UiTestUtils.clickId(driver, 'test-http-trace-btn');

      const record = await capture.waitForRecord(
        DataType.RUM_APP,
        [
          'resource',
          `resource_url=${SyncDataHelper.translateTagKeyValue(traceUrl)}`,
          'trace_id=',
          'span_id='
        ],
        // Native HTTP has no page-level timeout here. Leave enough room for a
        // slow first DNS/TLS connection and the SDK worker to persist it.
        30000
      );

      if (record === null) {
        throw new Error(
          `Expected RUM resource record with trace/span for the configured traceUrl. ` +
          `Check the page request result, trace sampling and resource filtering.\n` +
          `Current sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }
      expect(record !== null).assertTrue();

      await UiTestUtils.pressBack(driver);
    });

    it('axiosCompatSavesResourceAfterResponse', 0, async () => {
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      await UiTestUtils.clickText(driver, 'Compat');
      await UiTestUtils.clickId(driver, 'test-axios-get-btn');

      const record = await capture.waitForRecord(
        DataType.RUM_APP,
        [
          'resource',
          SyncDataHelper.translateTagKeyValue('ft_source=axios-compat'),
          'resource_method=GET',
          'resource_status=200',
          'duration='
        ],
        15000
      );

      if (record === null) {
        throw new Error(
          `Expected serialized Axios Compat resource record.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }

      await UiTestUtils.pressBack(driver);
    });

    it('axiosChainSerializeResourceAfterResponse', 0, async () => {
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      await UiTestUtils.clickText(driver, 'Chain');
      await UiTestUtils.clickId(driver, 'test-axios-get-btn');

      const record = await capture.waitForRecord(
        DataType.RUM_APP,
        [
          'resource',
          SyncDataHelper.translateTagKeyValue('ft_source=axios-chain'),
          'resource_method=GET',
          'resource_status=200',
          'duration='
        ],
        15000
      );

      if (record === null) {
        throw new Error(
          `Expected serialized Axios Chain resource record.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }

      await UiTestUtils.pressBack(driver);
    });
  });
}
