import { describe, beforeEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { UiTestUtils } from './helpers/UiTestUtils';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { preferences } from '@kit.ArkData';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { RUNTIME_CONFIG_PREFERENCES_NAME } from '../../../main/ets/entryability/EntryAbility';
import { ENTRY_RUNTIME_KEYS, entryLaunchParameters,
  resolveEntryRuntimeConfig } from '../../../main/ets/utils/EntryRuntimeConfig';

interface ConfigTestArguments {
  parameters?: Record<string, string>;
}

export default function abilityTest() {
  describe('EntryAbilityBusinessTest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
    });

    it('entryAbilityLaunchConfiguredSdkDemoHome', 0, async () => {
      const homeReady = await UiTestUtils.waitForText(driver, 'FT SDK HarmonyOS Test App', 6000);

      expect(homeReady).assertTrue();
    });

    it('entryLaunchUsesAndPersistsTheSharedConfiguration', 0, async () => {
      const ability = await AbilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
      const store = await preferences.getPreferences(ability.context, RUNTIME_CONFIG_PREFERENCES_NAME);
      const saved: Record<string, string> = {};
      for (const key of ENTRY_RUNTIME_KEYS) saved[key] = String(await store.get(key, ''));
      const args = AbilityDelegatorRegistry.getArguments() as Object as ConfigTestArguments;
      const expected = resolveEntryRuntimeConfig(entryLaunchParameters(args.parameters ?? {}), saved);
      expect(FTSDK.getRumConfig()?.getRumAppId() === expected.appId).assertTrue();
      // Compare credentials as booleans so a failure cannot print their values.
      for (const key of ENTRY_RUNTIME_KEYS) {
        expect(AppStorage.get<string>(key) === expected[key]).assertTrue();
        expect(saved[key] === expected[key]).assertTrue();
      }
    });

    it('entryShouldOpenRumPage', 0, async () => {
      await UiTestUtils.clickText(driver, 'RUM Unified Test');

      const pageReady = await UiTestUtils.waitForText(driver, 'RUM Unified Test Page', 6000);
      const sdkReady = await UiTestUtils.waitForText(driver, 'SDK Status: Initialized', 6000);

      expect(pageReady).assertTrue();
      expect(sdkReady).assertTrue();

      await UiTestUtils.pressBack(driver);
    });
  });
}
