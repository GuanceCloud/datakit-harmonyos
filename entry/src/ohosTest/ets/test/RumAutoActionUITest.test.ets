import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
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

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['action', 'action_type=click', 'test-button-1', 'session_id='],
        [],
        8000
      );
      if (record === null) {
        throw new Error(
          `Expected serialized RUM action record after button click.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }

      await UiTestUtils.pressBack(driver);
    });
  });
}
