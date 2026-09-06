import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function traceAutoTrackUITest() {
  describe('TraceAutoTrackUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('httpPageShouldCreateTraceResource', 0, async () => {
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      await UiTestUtils.clickText(driver, 'Test Trace ID in /api/user');

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        [
          'resource',
          '/api/user',
          'trace_id=',
          'span_id='
        ],
        [],
        12000
      );

      if (record === null) {
        throw new Error(
          `Expected RUM resource record with trace/span for /api/user.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }
      expect(record !== null).assertTrue();

      await UiTestUtils.pressBack(driver);
    });

    it('axiosCompatShouldSerializeResourceAfterResponse', 0, async () => {
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      await UiTestUtils.clickText(driver, 'Test Axios GET (Compat)');

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        [
          'resource',
          'resource_url=https://httpbin.org/get?from',
          'resource_method=GET',
          'resource_status=200',
          'duration='
        ],
        [],
        15000
      );

      if (record === null) {
        throw new Error(
          `Expected serialized Axios Compat resource record.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }

      await UiTestUtils.pressBack(driver);
    });

    it('axiosChainShouldSerializeResourceAfterResponse', 0, async () => {
      await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
      const interceptorReady = await UiTestUtils.waitForText(driver, 'Interceptor Helper: ✅ Available', 5000);
      expect(interceptorReady).assertTrue();
      await UiTestUtils.clickText(driver, 'Test Axios GET (Chain)');

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        [
          'resource',
          'resource_url=https://httpbin.org/get?from',
          'resource_method=GET',
          'resource_status=200',
          'duration='
        ],
        [],
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
