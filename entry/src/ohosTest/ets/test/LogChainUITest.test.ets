import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function logChainUITest() {
  describe('LogChainUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      await UiTestUtils.clickText(driver, 'LogBackground Test');
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('logPageShouldCreateSdkLogs', 0, async () => {
      await UiTestUtils.clickText(driver, 'Test Basic logBackground');

      const record = await EntryDBAssert.waitForSyncRecordContaining(
        DataType.LOG,
        ['Basic test log with string status', 'status=info'],
        8000
      );

      expect(record !== null).assertTrue();
    });
  });
}
