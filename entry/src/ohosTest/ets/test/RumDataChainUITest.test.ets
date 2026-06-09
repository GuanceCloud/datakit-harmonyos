import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function rumDataChainUITest() {
  describe('RumDataChainUITest', () => {
    let driver: Driver;
    let previousAutoSync: boolean = false;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      await UiTestUtils.clickText(driver, 'RUM Unified Test');
      const sdkReady = await UiTestUtils.waitForText(driver, 'SDK Status: Initialized', 5000);
      expect(sdkReady).assertTrue();
      const syncTaskManager = SyncTaskManager.getInstance();
      previousAutoSync = syncTaskManager.getStatus().autoSync;
      syncTaskManager.setAutoSync(false);
    });

    afterEach(async () => {
      SyncTaskManager.getInstance().setAutoSync(previousAutoSync);
      await UiTestUtils.pressBack(driver);
    });

    it('manualLongTaskShouldCreateRumLongTaskRecord', 0, async () => {
      await UiTestUtils.clickId(driver, 'rum-basic-add-long-task');

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['long_task', 'Basic long task test', 'duration'],
        ['session_id=', 'view_name='],
        8000
      );

      if (record === null) {
        throw new Error(
          `Expected RUM long_task record from Basic addLongTask.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }
      expect(record !== null).assertTrue();
    });

    it('manualErrorShouldCreateRumErrorRecord', 0, async () => {
      await UiTestUtils.clickId(driver, 'rum-basic-add-error');

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['error_type=custom', 'Basic error message', 'error_stack'],
        ['session_id=', 'view_name='],
        8000
      );

      if (record === null) {
        throw new Error(
          `Expected RUM error record from Basic addError.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }
      expect(record !== null).assertTrue();
    });
  });
}
