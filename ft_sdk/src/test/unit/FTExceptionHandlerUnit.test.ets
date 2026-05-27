import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { errorManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMConfig } from '../../main/ets/components/Configs';
import {
  FTExceptionNativeCrashHandler,
  FTExceptionHandlerRuntime,
  FTExceptionRumManager
} from '../../main/ets/components/FTExceptionHandlerRuntime';
import { FTExceptionHandler } from '../../main/ets/components/FTExceptionHandler';
import { AppState } from '../../main/ets/components/rum/enum/RUMEnums';
import { RunnerCompleteCallBack } from '../../main/ets/components/rum/callback/RunnerCompleteCallBack';

async function flushPromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function createCrashConfig(): FTRUMConfig {
  return new FTRUMConfig()
    .setRumAppId('rum-id')
    .setEnableTrackAppCrash(true);
}

class FakeBusinessError {
  code: number = 1001;
  message: string = 'off failed';
}

class FakeNativeCrashHandler implements FTExceptionNativeCrashHandler {
  initializeCount: number = 0;
  stopWatchingCount: number = 0;
  shutdownCount: number = 0;
  initializeResult: boolean = true;
  throwInitialize: boolean = false;
  rejectInitialize: boolean = false;
  delayedInitialize: boolean = false;
  delayedResolvers: Array<(value: boolean) => void> = [];

  initialize(): Promise<boolean> {
    this.initializeCount++;
    if (this.throwInitialize) {
      throw new Error('native initialize throw');
    }
    if (this.rejectInitialize) {
      return Promise.reject(new Error('native initialize failed'));
    }
    if (this.delayedInitialize) {
      return new Promise<boolean>((resolve: (value: boolean) => void): void => {
        this.delayedResolvers.push(resolve);
      });
    }
    return Promise.resolve(this.initializeResult);
  }

  resolveDelayedInitialize(value: boolean): void {
    const resolve = this.delayedResolvers.shift();
    if (resolve) {
      resolve(value);
    }
  }

  stopWatching(): void {
    this.stopWatchingCount++;
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class FakeTerminateContext {
  terminateCount: number = 0;
  rejectTerminate: boolean = false;

  terminateSelf(): Promise<void> {
    this.terminateCount++;
    if (this.rejectTerminate) {
      return Promise.reject(new Error('terminate failed'));
    }
    return Promise.resolve();
  }
}

class FakeRumManager implements FTExceptionRumManager {
  stopViewCount: number = 0;
  addErrorCount: number = 0;
  stopViewReject: boolean = false;
  addErrorReject: boolean = false;
  autoCompleteAddError: boolean = true;
  throwGetContext: boolean = false;
  context: object | null = new FakeTerminateContext();
  lastLog: string = '';
  lastMessage: string = '';
  lastErrorType: string = '';
  lastState: AppState = AppState.RUN;
  lastCallback: RunnerCompleteCallBack | null = null;

  stopView(): Promise<void> {
    this.stopViewCount++;
    if (this.stopViewReject) {
      return Promise.reject(new Error('stopView failed'));
    }
    return Promise.resolve();
  }

  addError(
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
    this.lastCallback = callBack !== undefined ? callBack : null;

    if (this.addErrorReject) {
      return Promise.reject(new Error('addError failed'));
    }
    if (this.autoCompleteAddError && callBack) {
      callBack.onComplete();
    }
    return Promise.resolve();
  }

  getContext(): object | null {
    if (this.throwGetContext) {
      throw new Error('context failed');
    }
    return this.context;
  }
}

class FakeRuntime implements FTExceptionHandlerRuntime {
  nativeHandler: FakeNativeCrashHandler = new FakeNativeCrashHandler();
  rumManager: FakeRumManager = new FakeRumManager();
  observer: errorManager.ErrorObserver | null = null;
  registerCount: number = 0;
  unregisterCount: number = 0;
  flushCount: number = 0;
  nextErrorManagerId: number = 100;
  registerThrows: boolean = false;
  unregisterThrows: boolean = false;
  throwGetRumManager: boolean = false;
  offCallbackErr: BusinessError | null = null;
  rethrowEnabled: boolean = false;
  scheduledCallbacks: Array<() => void> = [];
  scheduledDelays: number[] = [];
  scheduledDelayHistory: number[] = [];

  createNativeCrashHandler(): FTExceptionNativeCrashHandler {
    return this.nativeHandler;
  }

  getRumManager(): FTExceptionRumManager {
    if (this.throwGetRumManager) {
      throw new Error('getRumManager failed');
    }
    return this.rumManager;
  }

  registerErrorObserver(callback: errorManager.ErrorObserver): number {
    if (this.registerThrows) {
      throw new Error('register failed');
    }
    this.registerCount++;
    this.observer = callback;
    return this.nextErrorManagerId;
  }

  unregisterErrorObserver(_id: number, callback: (err: BusinessError | null) => void): void {
    if (this.unregisterThrows) {
      throw new Error('unregister failed');
    }
    this.unregisterCount++;
    callback(this.offCallbackErr);
  }

  flushSyncData(): void {
    this.flushCount++;
  }

  schedule(callback: () => void, delayMs: number): void {
    this.scheduledCallbacks.push(callback);
    this.scheduledDelays.push(delayMs);
    this.scheduledDelayHistory.push(delayMs);
  }

  shouldRethrowException(): boolean {
    return this.rethrowEnabled;
  }

  runScheduled(): void {
    while (this.scheduledCallbacks.length > 0) {
      const callback = this.scheduledCallbacks.shift();
      this.scheduledDelays.shift();
      if (callback) {
        callback();
      }
    }
  }

  runFirstScheduledByDelay(delayMs: number): void {
    const index = this.scheduledDelays.indexOf(delayMs);
    if (index < 0) {
      return;
    }
    const callbacks = this.scheduledCallbacks.splice(index, 1);
    this.scheduledDelays.splice(index, 1);
    if (callbacks.length > 0) {
      callbacks[0]();
    }
  }
}

function requireObserver(runtime: FakeRuntime): errorManager.ErrorObserver {
  expect(runtime.observer !== null).assertTrue();
  return runtime.observer as errorManager.ErrorObserver;
}

function emitObserverException(observer: errorManager.ErrorObserver, error: Error): void {
  if (observer.onException) {
    observer.onException(error);
  }
}

function emitObserverUnhandledException(observer: errorManager.ErrorObserver, message: string): void {
  if (observer.onUnhandledException) {
    observer.onUnhandledException(message);
  }
}

async function triggerCrashAndDrain(runtime: FakeRuntime, error: Error = new Error('boom')): Promise<void> {
  const observer = requireObserver(runtime);
  emitObserverException(observer, error);
  await flushPromises();
  runtime.runScheduled();
  await flushPromises();
  runtime.runScheduled();
}

export default function ftExceptionHandlerUnitTest() {
  describe('FTExceptionHandlerUnit', () => {
    let runtime: FakeRuntime = new FakeRuntime();

    beforeEach(() => {
      runtime = new FakeRuntime();
      FTExceptionHandler.setRuntimeForTest(runtime);
    });

    afterEach(() => {
      FTExceptionHandler.release();
      FTExceptionHandler.resetRuntimeForTest();
    });

    it('exceptionHandlerShouldCreateSingletonAndStayDisabledByDefault', 0, () => {
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertFalse();

      const first = FTExceptionHandler.getInstance();
      const second = FTExceptionHandler.getInstance();

      expect(first === second).assertTrue();
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertFalse();
    });

    it('initConfigShouldSkipRegistrationWithoutRumAppIdOrCrashSwitch', 0, async () => {
      const handler = FTExceptionHandler.getInstance();

      handler.initConfig(new FTRUMConfig());
      handler.initConfig(new FTRUMConfig().setRumAppId('rum-id'));
      await flushPromises();

      expect(runtime.registerCount).assertEqual(0);
      expect(runtime.nativeHandler.initializeCount).assertEqual(0);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertFalse();
    });

    it('initConfigShouldRegisterOnceAndInitializeNativeCrash', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      const config = createCrashConfig();

      handler.initConfig(config);
      await flushPromises();
      handler.initConfig(config);
      await flushPromises();

      expect(runtime.registerCount).assertEqual(1);
      expect(runtime.nativeHandler.initializeCount).assertEqual(2);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();
    });

    it('nativeCrashInitializeShouldCoverFalseAndRejectBranches', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.nativeHandler.initializeResult = false;

      handler.initConfig(createCrashConfig());
      await flushPromises();
      expect(runtime.nativeHandler.initializeCount).assertEqual(1);
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
      expect(runtime.registerCount).assertEqual(1);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      runtime.nativeHandler.rejectInitialize = true;
      FTExceptionHandler.setRuntimeForTest(runtime);

      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();

      expect(runtime.nativeHandler.initializeCount).assertEqual(1);
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
      expect(runtime.registerCount).assertEqual(1);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      runtime.nativeHandler.throwInitialize = true;
      FTExceptionHandler.setRuntimeForTest(runtime);

      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();

      expect(runtime.nativeHandler.initializeCount).assertEqual(1);
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
      expect(runtime.registerCount).assertEqual(1);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();
    });

    it('nativeCrashDelayedInitializeShouldIgnoreStaleResultForSameHandler', 0, async () => {
      const exceptionHandler = FTExceptionHandler.getInstance();
      const nativeHandler = runtime.nativeHandler;
      nativeHandler.delayedInitialize = true;
      const config = createCrashConfig();

      exceptionHandler.initConfig(config);
      exceptionHandler.initConfig(config);
      expect(nativeHandler.initializeCount).assertEqual(2);

      nativeHandler.resolveDelayedInitialize(true);
      await flushPromises();

      expect(nativeHandler.shutdownCount).assertEqual(0);

      nativeHandler.resolveDelayedInitialize(true);
      await flushPromises();

      expect(nativeHandler.shutdownCount).assertEqual(0);
    });

    it('nativeCrashDelayedInitializeShouldNotReattachSinkAfterRelease', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.nativeHandler.delayedInitialize = true;

      handler.initConfig(createCrashConfig());
      expect(runtime.nativeHandler.initializeCount).assertEqual(1);

      FTExceptionHandler.release();
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);

      runtime.nativeHandler.resolveDelayedInitialize(true);
      await flushPromises();

      expect(runtime.nativeHandler.shutdownCount).assertEqual(2);
    });

    it('stopAndReleaseShouldBeIdempotentAndCleanNativeHandler', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      handler.stop();
      expect(runtime.unregisterCount).assertEqual(1);
      expect(runtime.nativeHandler.stopWatchingCount).assertEqual(0);
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);

      FTExceptionHandler.release();
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertFalse();

      FTExceptionHandler.release();
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
    });

    it('stopErrorManagerShouldCoverOffCallbackErrorAndOffThrow', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.offCallbackErr = new FakeBusinessError() as BusinessError;

      handler.initConfig(createCrashConfig());
      await flushPromises();
      handler.stop();

      expect(runtime.unregisterCount).assertEqual(1);

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      FTExceptionHandler.setRuntimeForTest(runtime);
      const secondHandler = FTExceptionHandler.getInstance();
      secondHandler.initConfig(createCrashConfig());
      await flushPromises();

      runtime.unregisterThrows = true;
      secondHandler.stop();
      expect(runtime.unregisterCount).assertEqual(0);

      runtime.unregisterThrows = false;
    });

    it('initConfigShouldCatchRegisterFailure', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.registerThrows = true;

      handler.initConfig(createCrashConfig());
      await flushPromises();

      expect(runtime.registerCount).assertEqual(0);
      expect(runtime.observer === null).assertTrue();
      expect(FTExceptionHandler.isErrorManagerEnabled()).assertTrue();
    });

    it('stopAndReleaseShouldHandleMissingNativeHandler', 0, () => {
      const handler = FTExceptionHandler.getInstance();

      handler.stop();
      FTExceptionHandler.release();

      expect(runtime.nativeHandler.stopWatchingCount).assertEqual(0);
      expect(runtime.nativeHandler.shutdownCount).assertEqual(1);
    });

    it('observerCallbacksShouldCaptureUnhandledFirstCrashAndDuplicateCrash', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      const observer = requireObserver(runtime);
      emitObserverUnhandledException(observer, 'unhandled message');
      emitObserverException(observer, new Error('first crash'));
      emitObserverException(observer, new Error('duplicate crash'));
      await flushPromises();
      runtime.runScheduled();
      await flushPromises();
      runtime.runScheduled();

      expect(runtime.rumManager.addErrorCount).assertEqual(1);
      expect(runtime.rumManager.stopViewCount).assertEqual(1);
      expect(runtime.flushCount).assertEqual(1);
      expect(runtime.unregisterCount).assertEqual(1);
      expect(runtime.scheduledDelayHistory.includes(10)).assertTrue();
      expect(runtime.scheduledDelayHistory.includes(100)).assertTrue();
      expect(runtime.rumManager.lastMessage).assertEqual('first crash');
      expect(runtime.rumManager.lastState).assertEqual(AppState.RUN);
      expect(runtime.rumManager.lastLog.includes('first crash')).assertTrue();
      expect(runtime.rumManager.lastErrorType.length > 0).assertTrue();
    });

    it('observerCallbacksShouldCoverRethrowBranchesWhenRuntimeAllowsThrow', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      const observer = requireObserver(runtime);
      emitObserverException(observer, new Error('first crash'));
      emitObserverException(observer, new Error('duplicate crash'));
      await flushPromises();

      runtime.rethrowEnabled = true;
      let duplicateThrown = false;
      try {
        runtime.runFirstScheduledByDelay(10);
      } catch (_error) {
        duplicateThrown = true;
      }

      let normalThrown = false;
      try {
        runtime.runFirstScheduledByDelay(100);
      } catch (_error) {
        normalThrown = true;
      }

      expect(duplicateThrown).assertTrue();
      expect(normalThrown).assertTrue();
      expect(runtime.unregisterCount).assertEqual(1);
    });

    it('crashHandlingShouldFlushAndCloseWindowAfterAddErrorComplete', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      const context = runtime.rumManager.context as FakeTerminateContext;
      await triggerCrashAndDrain(runtime);

      expect(runtime.rumManager.addErrorCount).assertEqual(1);
      expect(runtime.rumManager.stopViewCount).assertEqual(1);
      expect(runtime.flushCount).assertEqual(1);
      expect(context.terminateCount).assertEqual(1);
    });

    it('crashHandlingShouldCoverStacklessErrorAndHandleCrashCatch', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      const stacklessError = new Error('stackless crash');
      stacklessError.stack = '';
      await triggerCrashAndDrain(runtime, stacklessError);

      expect(runtime.rumManager.lastLog.includes('stackless crash')).assertTrue();

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      runtime.throwGetRumManager = true;
      FTExceptionHandler.setRuntimeForTest(runtime);
      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();

      const observer = requireObserver(runtime);
      emitObserverException(observer, new Error('rum manager failed'));
      await flushPromises();
      runtime.runScheduled();

      expect(runtime.rumManager.addErrorCount).assertEqual(0);
    });

    it('crashHandlingShouldFlushAndCloseWindowWhenStopViewRejects', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.rumManager.stopViewReject = true;
      handler.initConfig(createCrashConfig());
      await flushPromises();

      const context = runtime.rumManager.context as FakeTerminateContext;
      await triggerCrashAndDrain(runtime);

      expect(runtime.rumManager.stopViewCount).assertEqual(1);
      expect(runtime.flushCount).assertEqual(1);
      expect(context.terminateCount).assertEqual(1);
    });

    it('crashHandlingShouldCatchAddErrorRejectWithoutFlushing', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      runtime.rumManager.addErrorReject = true;
      handler.initConfig(createCrashConfig());
      await flushPromises();

      await triggerCrashAndDrain(runtime);

      expect(runtime.rumManager.addErrorCount).assertEqual(1);
      expect(runtime.rumManager.stopViewCount).assertEqual(0);
      expect(runtime.flushCount).assertEqual(0);
    });

    it('closeWindowShouldHandleMissingRejectingAndThrowingContext', 0, async () => {
      const handler = FTExceptionHandler.getInstance();
      handler.initConfig(createCrashConfig());
      await flushPromises();

      runtime.rumManager.context = null;
      await triggerCrashAndDrain(runtime, new Error('context missing'));
      expect(runtime.flushCount).assertEqual(1);

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      FTExceptionHandler.setRuntimeForTest(runtime);
      const rejectingContext = runtime.rumManager.context as FakeTerminateContext;
      rejectingContext.rejectTerminate = true;
      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();
      await triggerCrashAndDrain(runtime, new Error('context reject'));
      expect(rejectingContext.terminateCount).assertEqual(1);

      FTExceptionHandler.release();
      runtime = new FakeRuntime();
      runtime.rumManager.throwGetContext = true;
      FTExceptionHandler.setRuntimeForTest(runtime);
      FTExceptionHandler.getInstance().initConfig(createCrashConfig());
      await flushPromises();
      await triggerCrashAndDrain(runtime, new Error('context throw'));
      expect(runtime.flushCount).assertEqual(1);
    });
  });
}
