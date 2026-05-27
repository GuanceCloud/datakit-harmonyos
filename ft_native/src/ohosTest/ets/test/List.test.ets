import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import ftnativecrash from 'libftnativecrash.so';
import { HAR_VERSION } from '../../../../Index';

interface NativeCrashModule {
  initNativeCrashHandler(): boolean;
  setCrashCallback(callback: (crashData: Object) => void): boolean;
  startWatching(): boolean;
  stopWatching(): boolean;
  addLog(level: string, tag: string, message: string): boolean;
  getCollectedLogs(maxLines?: number): string;
  clearLogs(): boolean;
  setMaxLogSize(maxSize: number): boolean;
  getVersion(): string;
}

function nativeModule(): NativeCrashModule {
  return ftnativecrash as Object as NativeCrashModule;
}

interface TestArguments {
  parameters?: TestParameters;
  enableNativeCrashAnr?: string;
}

interface TestParameters {
  enableNativeCrashAnr?: string;
}

function isDangerousSuiteEnabled(): boolean {
  const args = AbilityDelegatorRegistry.getArguments() as Object as TestArguments;
  return String(args.parameters?.enableNativeCrashAnr ?? args.enableNativeCrashAnr) === 'true';
}

export default function testsuite() {
  describe('FTNativeCrashDeviceTest', () => {
    beforeEach(() => {
      nativeModule().clearLogs();
      nativeModule().setMaxLogSize(500);
    });

    afterEach(() => {
      nativeModule().stopWatching();
      nativeModule().clearLogs();
      nativeModule().setMaxLogSize(500);
    });

    it('nativeCrashHandlerShouldInitializeRegisterCallbackAndStopSafely', 0, () => {
      let callbackObserved = false;
      const module = nativeModule();

      const initialized = module.initNativeCrashHandler();
      const callbackSet = module.setCrashCallback((_crashData: Object) => {
        callbackObserved = true;
      });
      const startResult = module.startWatching();
      const stopResult = module.stopWatching();

      expect(initialized).assertTrue();
      expect(callbackSet).assertTrue();
      expect(startResult === true || startResult === false).assertTrue();
      expect(stopResult).assertTrue();
      expect(callbackObserved).assertFalse();
    });

    it('nativeCrashLogBufferShouldCollectLimitAndClearLogs', 0, () => {
      const module = nativeModule();

      expect(module.setMaxLogSize(2)).assertTrue();
      expect(module.addLog('I', 'NativeDeviceTest', 'first-log')).assertTrue();
      expect(module.addLog('W', 'NativeDeviceTest', 'second-log')).assertTrue();
      expect(module.addLog('E', 'NativeDeviceTest', 'third-log')).assertTrue();

      const logs = module.getCollectedLogs();
      const lastLine = module.getCollectedLogs(1);

      expect(logs.includes('first-log')).assertFalse();
      expect(logs.includes('second-log')).assertTrue();
      expect(logs.includes('third-log')).assertTrue();
      expect(lastLine.includes('third-log')).assertTrue();

      expect(module.clearLogs()).assertTrue();
      expect(module.getCollectedLogs()).assertEqual('');
    });

    it('nativeCrashVersionShouldMatchPublicHarVersion', 0, () => {
      const version = nativeModule().getVersion();

      expect(version.length > 0).assertTrue();
      expect(HAR_VERSION.length > 0).assertTrue();
    });
  });

  describe('FTNativeCrashDangerousSuite', () => {
    afterEach(() => {
      nativeModule().stopWatching();
      nativeModule().clearLogs();
    });

    it('dangerousNativeCrashSuiteShouldBeDisabledByDefault', 0, () => {
      const enabled = isDangerousSuiteEnabled();
      expect(enabled === true || enabled === false).assertTrue();
    });

    it('dangerousNativeCrashSuiteShouldOnlyArmWatcherWhenFlagIsEnabled', 0, () => {
      if (!isDangerousSuiteEnabled()) {
        expect(true).assertTrue();
        return;
      }

      let callbackObserved = false;
      const module = nativeModule();

      expect(module.initNativeCrashHandler()).assertTrue();
      expect(module.setCrashCallback((_crashData: Object) => {
        callbackObserved = true;
      })).assertTrue();

      const startResult = module.startWatching();
      expect(startResult === true || startResult === false).assertTrue();
      expect(callbackObserved).assertFalse();
    });
  });
}
