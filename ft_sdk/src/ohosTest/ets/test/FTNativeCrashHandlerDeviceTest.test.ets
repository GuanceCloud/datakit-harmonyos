import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../../main/ets/components/Constants';
import { FTNativeCrashHandler, NativeCrashData } from '../../../main/ets/components/FTNativeCrashHandler';
import {
  FTNativeCrashCallback,
  FTNativeCrashHandlerRuntime,
  FTNativeCrashModuleRuntime,
  FTNativeCrashRumContext,
  FTNativeCrashRumManager
} from '../../../main/ets/components/internal/runtime/FTNativeCrashHandlerRuntime';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { AppState, ErrorType } from '../../../main/ets/components/rum/enum/RUMEnums';
import { RunnerCompleteCallBack } from '../../../main/ets/components/rum/callback/RunnerCompleteCallBack';
import { SDKDedicatedPoolManager } from '../../../main/ets/components/thread/SDKDedicatedPoolManager';

interface NativeTestValueWrapper {
  value: string | number | boolean;
}

interface NativeTestSignal {
  signo: number;
  code: number;
  address: string;
}

interface NativeTestFrame {
  symbol: string;
  file: string;
  pc: string;
}

interface NativeTestException {
  signal: NativeTestSignal;
  thread_name: string;
  tid: number;
  message: string;
  frames: NativeTestFrame[];
}

interface NativeTestMemory {
  rss: number;
  sys_total_mem: number;
  sys_free_mem: number;
  sys_avail_mem: number;
}

interface NativeTestExceptionPayload {
  exception: NativeTestException;
  memory: NativeTestMemory;
}

function createNativeCrashData(): NativeCrashData {
  const exceptionPayload: NativeTestExceptionPayload = {
    exception: {
      signal: {
        signo: 11,
        code: 1,
        address: '0xdeadbeef'
      },
      thread_name: 'native-main',
      tid: 99,
      message: 'segv at native first frame',
      frames: [
        {
          symbol: 'native_entry',
          file: '/data/storage/el1/bundle/libs/libnative_test.so',
          pc: '0000000000012345'
        },
        {
          symbol: 'native_second',
          file: '/data/storage/el1/bundle/libs/libnative_test.so',
          pc: '0000000000067890'
        }
      ]
    },
    memory: {
      rss: 2048,
      sys_total_mem: 4096,
      sys_free_mem: 1024,
      sys_avail_mem: 2048
    }
  };
  return {
    timestamp: 1710000000123,
    crashType: 'NativeCrash',
    foreground: true,
    bundleVersion: '1.2.3',
    bundleName: 'com.guance.native.test',
    pid: 1234,
    uid: 5678,
    uuid: 'native-crash-device-uuid',
    exception: JSON.stringify(exceptionPayload),
    hilogSize: 2,
    externalLog: JSON.stringify(['native-device.log']),
    logOverLimit: false,
    memoryNearRegisters: 'x0 0000000000000000\nx1 00000000deadbeef',
    maps: '00000000-00001000 r-xp /data/storage/el1/bundle/libs/libnative_test.so',
    hilog: 'native crash hilog first line\nnative crash hilog second line'
  };
}

function getWrappedValue(property: Record<string, object>, key: string): string {
  const wrapper = property[key] as NativeTestValueWrapper;
  if (!wrapper || wrapper.value === undefined || wrapper.value === null) {
    return '';
  }
  return String(wrapper.value);
}

class DeviceFakeNativeCrashModule implements FTNativeCrashModuleRuntime {
  initCount: number = 0;
  setCallbackCount: number = 0;
  clearCallbackCount: number = 0;
  startWatchingCount: number = 0;
  stopWatchingCount: number = 0;
  addedLogs: string[] = [];
  callback: FTNativeCrashCallback | null = null;

  initNativeCrashHandler(): boolean {
    this.initCount++;
    return true;
  }

  setCrashCallback(callback: FTNativeCrashCallback): boolean {
    this.setCallbackCount++;
    this.callback = callback;
    return true;
  }

  clearCrashCallback(): boolean {
    this.clearCallbackCount++;
    this.callback = null;
    return true;
  }

  startWatching(): boolean {
    this.startWatchingCount++;
    return true;
  }

  stopWatching(): boolean {
    this.stopWatchingCount++;
    return true;
  }

  addLog(_level: string, _tag: string, message: string): boolean {
    this.addedLogs.push(message);
    return true;
  }

  getCollectedLogs(_maxLines?: number): string {
    return this.addedLogs.join('\n');
  }

  clearLogs(): boolean {
    this.addedLogs = [];
    return true;
  }

  setMaxLogSize(_maxSize: number): boolean {
    return true;
  }

  getVersion(): string {
    return 'device-runtime-test';
  }

  async emitCrash(crashData: NativeCrashData): Promise<void> {
    if (this.callback) {
      const result = this.callback(crashData);
      if (result instanceof Promise) {
        await result;
      }
    }
  }
}

class DeviceFakeNativeCrashRumManager implements FTNativeCrashRumManager {
  addErrorCount: number = 0;
  clearSavedContextCount: number = 0;
  lastLog: string = '';
  lastMessage: string = '';
  lastErrorType: string = '';
  lastState: AppState = AppState.UNKNOWN;
  lastProperty: Record<string, object> | null = null;
  savedContext: FTNativeCrashRumContext = {
    viewId: 'native-view-id',
    viewName: 'native_crash_saved_view',
    viewReferrer: 'native-referrer',
    sessionId: 'native-session-id'
  };

  getSavedRumContext(): Promise<FTNativeCrashRumContext> {
    return Promise.resolve(this.savedContext);
  }

  addErrorInternal(
    log: string,
    message: string,
    errorType: string,
    state: AppState,
    property?: Record<string, object> | null,
    _dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): Promise<void> {
    this.addErrorCount++;
    this.lastLog = log;
    this.lastMessage = message;
    this.lastErrorType = errorType;
    this.lastState = state;
    this.lastProperty = property || null;
    if (callBack) {
      callBack.onComplete();
    }
    return Promise.resolve();
  }

  clearSavedRumContext(): void {
    this.clearSavedContextCount++;
  }
}

class DeviceFakeNativeCrashRuntime implements FTNativeCrashHandlerRuntime {
  nativeModule: DeviceFakeNativeCrashModule = new DeviceFakeNativeCrashModule();
  rumManager: DeviceFakeNativeCrashRumManager = new DeviceFakeNativeCrashRumManager();

  getNativeCrashModule(): FTNativeCrashModuleRuntime {
    return this.nativeModule;
  }

  getRumManager(): FTNativeCrashRumManager {
    return this.rumManager;
  }
}

export default function ftNativeCrashHandlerDeviceTest() {
  describe('FTNativeCrashHandlerDeviceTest', () => {
    let runtime: DeviceFakeNativeCrashRuntime;
    let handler: FTNativeCrashHandler;

    beforeEach(() => {
      SDKDedicatedPoolManager.resetInternal();
      runtime = new DeviceFakeNativeCrashRuntime();
      SdkInternalTestAccess.setNativeCrashHandlerRuntime(runtime);
      handler = new FTNativeCrashHandler();
    });

    afterEach(() => {
      handler.shutdown();
      SdkInternalTestAccess.resetNativeCrashHandlerRuntime();
      SDKDedicatedPoolManager.resetInternal();
    });

    it('nativeCrashShouldStartWatching', 0, async () => {
      const initialized = await handler.initialize();

      expect(initialized).assertTrue();
      expect(handler.isReady()).assertTrue();
      expect(runtime.nativeModule.initCount).assertEqual(1);
      expect(runtime.nativeModule.setCallbackCount).assertEqual(1);
      expect(runtime.nativeModule.callback !== null).assertTrue();
      expect(runtime.nativeModule.startWatchingCount).assertEqual(1);
    });

    it('nativeCrashCallbackShouldReportRum', 0, async () => {
      const initialized = await handler.initialize();
      expect(initialized).assertTrue();

      await runtime.nativeModule.emitCrash(createNativeCrashData());

      expect(runtime.rumManager.addErrorCount).assertEqual(1);
      expect(runtime.rumManager.lastMessage).assertEqual('Native Crash: NativeCrash');
      expect(runtime.rumManager.lastErrorType).assertEqual(ErrorType.NATIVE_CRASH.toString());
      expect(runtime.rumManager.lastState).assertEqual(AppState.RUN);
      expect(runtime.rumManager.lastLog.includes('Module name:com.guance.native.test')).assertTrue();
      expect(runtime.rumManager.lastLog.includes('Reason:Signal:SIGSEGV(1)@0xdeadbeef')).assertTrue();
      expect(runtime.rumManager.lastLog.includes('Fault thread info')).assertTrue();
      expect(runtime.rumManager.lastLog.includes('native_entry')).assertTrue();
      expect(runtime.rumManager.lastLog.includes('Memory near registers')).assertTrue();
      expect(runtime.rumManager.lastLog.includes('native crash hilog first line')).assertTrue();

      expect(runtime.rumManager.lastProperty !== null).assertTrue();
      if (runtime.rumManager.lastProperty) {
        const property = runtime.rumManager.lastProperty;
        expect(getWrappedValue(property, Constants.KEY_CRASH_TYPE)).assertEqual('NativeCrash');
        expect(getWrappedValue(property, Constants.KEY_NATIVE_CRASH)).assertEqual('true');
        expect(getWrappedValue(property, Constants.KEY_BUNDLE_NAME)).assertEqual('com.guance.native.test');
        expect(getWrappedValue(property, Constants.KEY_UUID)).assertEqual('native-crash-device-uuid');
        expect(getWrappedValue(property, Constants.KEY_RUM_VIEW_ID)).assertEqual('native-view-id');
        expect(getWrappedValue(property, Constants.KEY_RUM_VIEW_NAME)).assertEqual('native_crash_saved_view');
        expect(getWrappedValue(property, Constants.KEY_RUM_SESSION_ID)).assertEqual('native-session-id');
      }
      expect(runtime.rumManager.clearSavedContextCount).assertEqual(1);
    });
  });
}
