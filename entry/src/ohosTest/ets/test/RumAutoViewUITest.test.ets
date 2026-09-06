import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

export default function rumAutoViewUITest() {
  describe('RumAutoViewUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('routeNavigationShouldCreateRumViewRecord', 0, async () => {
      await UiTestUtils.clickText(driver, 'RUM Unified Test');

      const view = await EntryDBAssert.waitForViewMatching(['RUMDataTestPage', 'RUM'], 6000);

      expect(view !== null).assertTrue();
      expect((view?.getViewName() ?? '').length > 0).assertTrue();
      expect((view?.getSessionId() ?? '').length > 0).assertTrue();

      await UiTestUtils.pressBack(driver);

      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['view', 'view_name=RUMDataTestPage', 'session_id='],
        [],
        8000
      );
      if (record === null) {
        throw new Error(
          `Expected serialized RUM view record after navigation.\nCurrent sync_data_flat records:\n${await EntryDBAssert.dumpSyncRecords()}`
        );
      }
    });
  });
}
