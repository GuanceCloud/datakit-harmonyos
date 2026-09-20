import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { errorManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTExceptionHandler } from '../../../main/ets/components/FTExceptionHandler';
import {
  FTExceptionHandlerRuntime,
  FTExceptionNativeCrashHandler,
  FTExceptionRumManager
} from '../../../main/ets/components/internal/runtime/FTExceptionHandlerRuntime';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { AppState, ErrorType } from '../../../main/ets/components/rum/enum/RUMEnums';
import { RunnerCompleteCallBack } from '../../../main/ets/components/rum/callback/RunnerCompleteCallBack';

function createCrashConfig(): FTRUMConfig {
  return new FTRUMConfig()
    .setRumAppId('rum-id')
    .setEnableTrackAppCrash(true);
}

async function flushPromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

class DeviceFakeNativeCrashHandler implements FTExceptionNativeCrashHandler {
  initializeCount: number = 0;
  shutdownCount: number = 0;

  initialize(): Promise<boolean> {
    this.initializeCount++;
    return Promise.resolve(false);
  }

  stopWatching(): void {
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class DeviceFakeTerminateContext {
  terminateCount: number = 0;

  terminateSelf(): Promise<void> {
    this.terminateCount++;
    return Promise.resolve();
  }
}

class DeviceFakeRumManager implements FTExceptionRumManager {
  stopViewCount: number = 0;
  addErrorCount: number = 0;
  context: DeviceFakeTerminateContext = new DeviceFakeTerminateContext();
  lastLog: string = '';
  lastMessage: string = '';
  lastErrorType: string = '';
  lastState: AppState = AppState.RUN;

  stopView(): Promise<void> {
    this.stopViewCount++;
    return Promise.resolve();
  }

  addErrorInternal(
    log: string,
    message: string,
    errorType: string,
    state: AppState,
    _property?: Record<string, object> | null,
    _dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): Promise<void> {
    this.addErrorCount++;
    this.lastLog = log;
    this.lastMessage = message;
    this.lastErrorType = errorType;
    this.lastState = state;
    if (callBack) {
      callBack.onComplete();
    }
    return Promise.resolve();
  }

  getContext(): object | null {
    return this.context;
  }
}

class DeviceFakeRuntime implements FTExceptionHandlerRuntime {
  nativeHandler: DeviceFakeNativeCrashHandler = new DeviceFakeNativeCrashHandler();
  rumManager: DeviceFakeRumManager = new DeviceFakeRumManager();
  observer: errorManager.ErrorObserver | null = null;
  registerCount: number = 0;
  unregisterCount: number = 0;
  flushCount: number = 0;
  scheduledCallbacks: Array<() => void> = [];

  createNativeCrashHandler(): FTExceptionNativeCrashHandler {
    return this.nativeHandler;
  }

  getRumManager(): FTExceptionRumManager {
    return this.rumManager;
  }

  registerErrorObserver(callback: errorManager.ErrorObserver): number {
    this.registerCount++;
    this.observer = callback;
    return 101;
  }

  unregisterErrorObserver(_id: number, callback: (err: BusinessError | null) => void): void {
    this.unregisterCount++;
    callback(null);
  }

  flushSyncData(): void {
    this.flushCount++;
  }

  schedule(callback: () => void, _delayMs: number): void {
    this.scheduledCallbacks.push(callback);
  }

  shouldRethrowException(): boolean {
    return false;
  }

  runScheduled(): void {
    while (this.scheduledCallbacks.length > 0) {
      const callback = this.scheduledCallbacks.shift();
      if (callback) {
        callback();
      }
    }
  }
}

export default function ftExceptionHandlerDeviceTest() {
  describe('FTExceptionHandlerDeviceTest', () => {
    let runtime: DeviceFakeRuntime;

    beforeEach(() => {
      runtime = new DeviceFakeRuntime();
      SdkInternalTestAccess.setExceptionHandlerRuntime(runtime);
    });

    afterEach(() => {
      FTExceptionHandler.release();
      SdkInternalTestAccess.resetExceptionHandlerRuntime();
    });

    it('appCrashShouldRegisterObserver', 0, async () => {
      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();

      expect(runtime.registerCount).assertEqual(1);
      expect(runtime.observer !== null).assertTrue();
      expect(runtime.nativeHandler.initializeCount).assertEqual(1);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();
    });

    it('jsErrorShouldCreateRumCrash', 0, async () => {
      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();

      const observer = runtime.observer;
      expect(observer !== null).assertTrue();
      if (observer && observer.onException) {
        const error = new Error('device js crash message');
        observer.onException(error);
      }

      await flushPromises();
      runtime.runScheduled();
      await flushPromises();
      runtime.runScheduled();

      expect(runtime.rumManager.addErrorCount).assertEqual(1);
      expect(runtime.rumManager.lastMessage).assertEqual('device js crash message');
      expect(runtime.rumManager.lastErrorType).assertEqual(ErrorType.JS_CRASH.toString());
      expect(runtime.rumManager.lastState).assertEqual(AppState.RUN);
      expect(runtime.rumManager.lastLog.includes('device js crash message')).assertTrue();
      // addErrorInternal owns the Crash persistence barrier, including the
      // current View finalization. Calling stopView again here would race or
      // duplicate the final View snapshot.
      expect(runtime.rumManager.stopViewCount).assertEqual(0);
      expect(runtime.flushCount).assertEqual(1);
      expect(runtime.unregisterCount).assertEqual(1);
      expect(runtime.rumManager.context.terminateCount).assertEqual(1);
    });
  });
}
