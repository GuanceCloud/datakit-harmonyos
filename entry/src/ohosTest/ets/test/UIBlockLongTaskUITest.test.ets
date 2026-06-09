import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function uiBlockLongTaskUITest() {
  describe('UIBlockLongTaskUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      await UiTestUtils.clickText(driver, 'UI Block Detection Test');
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('uiBlockShouldCreateLongTask', 0, async () => {
      await UiTestUtils.clickText(driver, 'Test 2: Long Block (3000ms)');

      const record = await EntryDBAssert.waitForSyncRecordContaining(
        DataType.RUM_APP,
        ['long_task', 'UIBlock', 'duration'],
        12000
      );

      expect(record !== null).assertTrue();
    });
  });
}
