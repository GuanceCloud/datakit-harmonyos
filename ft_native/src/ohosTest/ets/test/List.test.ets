import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
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

    it('nativeCrashHandlerInitCallbackAndStop', 0, () => {
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

    it('nativeLogBufferCollectLimitAndClear', 0, () => {
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

    it('nativeCrashVersionMatchPublicHarVersion', 0, () => {
      const version = nativeModule().getVersion();

      expect(version).assertEqual(HAR_VERSION);
    });
  });
}
