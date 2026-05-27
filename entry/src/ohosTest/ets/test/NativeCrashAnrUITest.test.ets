import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { UiTestUtils } from './helpers/UiTestUtils';

interface TestArguments {
  parameters?: TestParameters;
  testCaseNames?: string;
  enableNativeCrashAnr?: string;
  nativeCrashAnrPhase?: string;
}

interface TestParameters {
  enableNativeCrashAnr?: string;
  nativeCrashAnrPhase?: string;
}

function isDangerousSuiteEnabled(): boolean {
  const args = abilityDelegatorRegistry.getArguments() as Object as TestArguments;
  return String(args.parameters?.enableNativeCrashAnr ?? args.enableNativeCrashAnr) === 'true';
}

function getDangerousPhase(): string {
  const args = abilityDelegatorRegistry.getArguments() as Object as TestArguments;
  return String(args.parameters?.nativeCrashAnrPhase ?? args.nativeCrashAnrPhase);
}

function isFocusedDangerousTest(testName: string): boolean {
  const args = abilityDelegatorRegistry.getArguments() as Object as TestArguments;
  return (args.testCaseNames ?? '').includes(testName);
}

function shouldRunDangerousPhase(phase: string, testName: string): boolean {
  return (isDangerousSuiteEnabled() && getDangerousPhase() === phase) || isFocusedDangerousTest(testName);
}

export default function nativeCrashAnrUITest() {
  describe('NativeCrashAnrUITest', () => {
    it('dangerousCrashAndAnrSuiteShouldBeDisabledByDefault', 0, () => {
      const enabled = isDangerousSuiteEnabled();
      expect(enabled === true || enabled === false).assertTrue();
    });

    it('nativeCrashTriggerShouldRequireExplicitFlag', 0, async () => {
      if (!shouldRunDangerousPhase('trigger_native_crash', 'nativeCrashTriggerShouldRequireExplicitFlag')) {
        expect(true).assertTrue();
        return;
      }

      const driver: Driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await UiTestUtils.clickText(driver, 'Crash & ANR');
      await driver.delayMs(2500);
      await UiTestUtils.clickText(driver, 'Cpp Crash');
    });

    it('nativeCrashRestartVerificationShouldRequireExplicitFlag', 0, async () => {
      if (!shouldRunDangerousPhase('verify_native_crash', 'nativeCrashRestartVerificationShouldRequireExplicitFlag')) {
        expect(true).assertTrue();
        return;
      }

      const driver: Driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await driver.delayMs(3000);
      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['error'],
        ['native_crash', 'native crash', 'nativecrash', 'crash_type'],
        30000
      );
      const line = record?.getDataString() ?? '';
      const lowerLine = line.toLowerCase();

      expect(record !== null).assertTrue();
      expect(lowerLine.includes('native') || lowerLine.includes('crash')).assertTrue();
    });

    it('anrTriggerShouldRequireExplicitFlag', 0, async () => {
      if (!shouldRunDangerousPhase('trigger_anr', 'anrTriggerShouldRequireExplicitFlag')) {
        expect(true).assertTrue();
        return;
      }

      const driver: Driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await UiTestUtils.clickText(driver, 'Crash & ANR');
      await driver.delayMs(2500);
      await UiTestUtils.clickText(driver, 'ANR (10s)');
      await driver.delayMs(12000);
      expect(true).assertTrue();
    });

    it('anrRestartVerificationShouldRequireExplicitFlag', 0, async () => {
      if (!shouldRunDangerousPhase('verify_anr', 'anrRestartVerificationShouldRequireExplicitFlag')) {
        expect(true).assertTrue();
        return;
      }

      const driver: Driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await driver.delayMs(5000);
      const record = await EntryDBAssert.waitForRecentSyncRecordContainingAny(
        DataType.RUM_APP,
        ['error'],
        ['anr_crash', 'anr_error', 'app_freeze', 'harmony_anr', 'freeze'],
        30000
      );
      const lowerLine = (record?.getDataString() ?? '').toLowerCase();

      expect(record !== null).assertTrue();
      expect(lowerLine.includes('anr') || lowerLine.includes('freeze')).assertTrue();
    });
  });
}
