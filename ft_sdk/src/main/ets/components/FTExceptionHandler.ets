import { errorManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { FTInnerLogger } from './log/FTLogger';
import { FTRUMConfig } from './Configs';
import { ErrorType } from './rum/enum/RUMEnums';
import { AppState } from './rum/enum/RUMEnums';
import { RunnerCompleteCallBack } from './rum/callback/RunnerCompleteCallBack';
import {
  DefaultFTExceptionHandlerRuntime,
  FTExceptionNativeCrashHandler,
  FTExceptionHandlerRuntime
} from './FTExceptionHandlerRuntime';

const TAG = "FTExceptionHandler";

/**
 * Whether it is data from a previous crash
 * Aligned with Android: FTExceptionHandler.IS_PRE_CRASH
 */
export const IS_PRE_CRASH = "is_pre_crash";

/**
 * Exception handler for HarmonyOS
 * Aligned with Android: FTExceptionHandler
 * 
 * Uses HarmonyOS errorManager to catch unhandled exceptions
 * Reference: ft-sdk-android/exception-handling/entry/src/main/ets/entryability/EntryAbility.ets
 */
export class FTExceptionHandler {
  private static instance: FTExceptionHandler | null = null;
  private static runtime: FTExceptionHandlerRuntime = new DefaultFTExceptionHandlerRuntime();
  private errorManagerId: number = -1;
  private registerHandled: boolean = false;
  private isHandlingCrash: boolean = false;  // Flag to prevent infinite loop when rethrowing exception
  private nativeCrashAdapter: FTExceptionNativeCrashHandler | null = null;
  private nativeCrashGeneration: number = 0;

  private constructor() {
    this.nativeCrashAdapter = FTExceptionHandler.runtime.createNativeCrashHandler();
  }

  public static getInstance(): FTExceptionHandler {
    if (FTExceptionHandler.instance === null) {
      FTExceptionHandler.instance = new FTExceptionHandler();
    }
    return FTExceptionHandler.instance;
  }

  public static setRuntimeForTest(runtime: FTExceptionHandlerRuntime): void {
    FTExceptionHandler.release();
    FTExceptionHandler.runtime = runtime;
  }

  public static resetRuntimeForTest(): void {
    FTExceptionHandler.release();
    FTExceptionHandler.runtime = new DefaultFTExceptionHandlerRuntime();
  }

  /**
   * Initialize exception handler with RUM config
   * Aligned with Android: FTExceptionHandler.initConfig(FTRUMConfig config)
   *
   * @param config RUM configuration
   */
  public initConfig(config: FTRUMConfig): void {
    // Initialize JS crash handler (errorManager)
    // Check if RUM is enabled (rumAppId is set) and crash tracking is enabled
    // Aligned with Android: config.isRumEnable() && config.isEnableTrackAppCrash()
    if (config.getRumAppId().length > 0 &&
        config.isEnableTrackAppCrash() &&
        !this.registerHandled) {
      this.startErrorManager();
      this.registerHandled = true;
    }

    // Initialize Native (C++) crash handler through the implicit native module.
    if (config.getRumAppId().length > 0 &&
        config.isEnableTrackAppCrash()) {
      if (!this.nativeCrashAdapter) {
        this.nativeCrashAdapter = FTExceptionHandler.runtime.createNativeCrashHandler();
      }
      const nativeCrashHandler = this.nativeCrashAdapter;
      this.nativeCrashGeneration++;
      const nativeCrashGeneration = this.nativeCrashGeneration;

      let initializePromise: Promise<boolean>;
      try {
        initializePromise = nativeCrashHandler.initialize();
      } catch (error) {
        if (this.nativeCrashGeneration === nativeCrashGeneration &&
            this.nativeCrashAdapter === nativeCrashHandler) {
          this.shutdownNativeCrashAdapter();
        }
        FTInnerLogger.e(TAG, `Failed to initialize native crash adapter: ${error}`);
        return;
      }

      initializePromise.then((enabled: boolean) => {
        if (this.nativeCrashGeneration !== nativeCrashGeneration ||
            this.nativeCrashAdapter !== nativeCrashHandler) {
          if (this.nativeCrashAdapter !== nativeCrashHandler) {
            nativeCrashHandler.shutdown();
          }
          return;
        }

        if (enabled) {
          FTInnerLogger.i(TAG, "Native crash handler initialized and started");
        } else {
          this.shutdownNativeCrashAdapter();
          FTInnerLogger.i(TAG, "Native crash monitoring not available (native module initialization returned false)");
        }
      }).catch((error: Error) => {
        if (this.nativeCrashGeneration === nativeCrashGeneration &&
            this.nativeCrashAdapter === nativeCrashHandler) {
          this.shutdownNativeCrashAdapter();
        }
        FTInnerLogger.e(TAG, `Failed to initialize native crash adapter: ${error}`);
      });
    } else {
      this.shutdownNativeCrashAdapter();
    }
  }

  private shutdownNativeCrashAdapter(): void {
    this.nativeCrashGeneration++;
    const nativeCrashAdapter = this.nativeCrashAdapter;
    this.nativeCrashAdapter = null;

    if (nativeCrashAdapter) {
      nativeCrashAdapter.shutdown();
    }
  }

  /**
   * Start listening to unhandled exceptions using errorManager
   * Aligned with HarmonyOS errorManager example: exception-handling/entry/src/main/ets/entryability/EntryAbility.ets
   */
  private startErrorManager(): void {
    try {
      const callback: errorManager.ErrorObserver = {
        onUnhandledException: (errMsg: string) => {
          FTInnerLogger.i(TAG, `errorManager onUnhandledException, errMsg:${errMsg}`);
        },
        onException: (errObject: Error) => {
          // Prevent infinite loop: if we're already handling a crash, don't handle it again
          // This happens because rethrowing the exception causes errorManager to catch it again
          if (this.isHandlingCrash) {
            FTInnerLogger.w(TAG, "Already handling crash, skipping duplicate exception handling to prevent infinite loop");
            // Still rethrow to ensure app terminates
            FTExceptionHandler.runtime.schedule((): void => {
              if (FTExceptionHandler.runtime.shouldRethrowException()) {
                throw errObject;
              }
            }, 10);
            return;
          }
          
          FTInnerLogger.e(TAG, `errorManager onException, errName:${errObject.name}, errMessage:${errObject.message}, errStack:${errObject.stack}`);
          
          // Set flag to prevent infinite loop
          this.isHandlingCrash = true;
          
          // Collect crash information and upload
          // Aligned with Android: handle crash first, then rethrow exception
          this.handleCrash(errObject);
          
          // Rethrow exception after handling (aligned with Android SDK behavior)
          // Use setTimeout to rethrow asynchronously, allowing errorManager to complete processing
          // Android SDK calls mDefaultExceptionHandler.uncaughtException(t, e) to rethrow
          // Note: This will trigger onException again, but the isHandlingCrash flag will prevent infinite loop
          FTExceptionHandler.runtime.schedule((): void => {
            FTInnerLogger.i(TAG, "Rethrowing exception after crash handling (aligned with Android SDK)");
            // Stop errorManager to prevent it from catching the rethrown exception again
            // This ensures the app terminates properly
            this.stopErrorManager();
            if (FTExceptionHandler.runtime.shouldRethrowException()) {
              throw errObject;
            }
          }, 100);
        }
      };
      
      this.errorManagerId = FTExceptionHandler.runtime.registerErrorObserver(callback);
      FTInnerLogger.i(TAG, `errorManager.on("error") errorManagerId:${this.errorManagerId}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to start errorManager: ${error}`);
    }
  }

  /**
   * Stop listening to unhandled exceptions
   */
  private stopErrorManager(): void {
    if (this.errorManagerId > -1) {
      try {
        FTExceptionHandler.runtime.unregisterErrorObserver(this.errorManagerId, (err: BusinessError | null) => {
          if (err) {
            FTInnerLogger.d(TAG, `errorManager.off("error") errorManagerId:${this.errorManagerId}, errCode:${err.code}, errMessage:${err.message}`);
          } else {
            FTInnerLogger.d(TAG, `errorManager.off("error") errorManagerId:${this.errorManagerId}, err is null`);
          }
        });
        this.errorManagerId = -1;
      } catch (error) {
        FTInnerLogger.e(TAG, `Failed to stop errorManager: ${error}`);
      }
    }
  }

  /**
   * Public method to stop error manager (for memory leak debugging)
   */
  public stop(): void {
    this.stopErrorManager();

    // Stop native crash adapter
    this.shutdownNativeCrashAdapter();

    FTInnerLogger.i(TAG, "FTExceptionHandler stopped");
  }

  /**
   * Handle crash exception
   * Aligned with Android: FTExceptionHandler.uncaughtException(Thread t, Throwable e)
   * 
   * @param error Error object from errorManager
   */
  private handleCrash(error: Error): void {
    try {
      // Build crash stack trace
      // Aligned with Android: StringWriter + PrintWriter to build stack trace
      let crashStack = `${error.name}: ${error.message}\n`;
      if (error.stack) {
        crashStack += error.stack;
      }
      
      // Add all thread stack (if available)
      // Note: HarmonyOS doesn't have direct equivalent to Android's Utils.getAllThreadStack()
      // We can add thread information if needed in the future
      
      // Get app state
      // Aligned with Android: FTActivityManager.get().getAppState()
      const appState = AppState.RUN; // Default to RUN, can be enhanced later
      
      // Upload crash log with callback
      // Aligned with Android: uploadCrashLog(writer.toString(), e.getMessage(), state, callBack)
      const crashMessage = error.message || error.name || "Unknown error";
      
      // Create callback to ensure RUM data is generated and uploaded after crash
      const exceptionHandler = this; // Capture reference to FTExceptionHandler instance
      class CrashCallback implements RunnerCompleteCallBack {
        onComplete(): void {
          FTInnerLogger.i(TAG, "Crash error uploaded, now stopping view, writing to DB, and closing window");
          
          // Step 1: Stop current view to generate RUM data
          // Aligned with Android: stopView(null, callBack) in addError callback
          const rumManager = FTExceptionHandler.runtime.getRumManager();
          rumManager.stopView().then(() => {
            FTInnerLogger.i(TAG, "View stopped after crash");
            
            // Step 2: Wait a bit for data to be written to database
            // This ensures all pending data operations complete before closing
            FTExceptionHandler.runtime.schedule((): void => {
              FTInnerLogger.i(TAG, "Ensuring data is written to database");
              
              // Step 3: Flush sync data to ensure data is written to database
              // This triggers immediate database write and upload
              FTExceptionHandler.runtime.flushSyncData();
              
              // Step 4: Wait a bit more for database write to complete
              FTExceptionHandler.runtime.schedule((): void => {
                FTInnerLogger.i(TAG, "Data written to database, now closing window");
                
                // Step 5: Close current window
                exceptionHandler.closeCurrentWindow();
                
                // Step 6: Wait a bit before rethrowing exception to ensure window closes
                FTExceptionHandler.runtime.schedule((): void => {
                  FTInnerLogger.i(TAG, "Window closed, app will crash");
                }, 100);
              }, 200); // Wait 200ms for database write
            }, 100); // Wait 100ms for view stop to complete
          }).catch((err: Error) => {
            FTInnerLogger.e(TAG, `Failed to stop view after crash: ${err}`);
            // Still try to flush data and close window even if stopView fails
            FTExceptionHandler.runtime.flushSyncData();
            FTExceptionHandler.runtime.schedule((): void => {
              exceptionHandler.closeCurrentWindow();
            }, 200);
          });
        }
      }
      
      const callback = new CrashCallback();
      
      // Upload crash log
      // Aligned with Android: uploadCrashLog(crash, message, state, callBack)
      // Note: HarmonyOS uses ErrorType.CRASH instead of ErrorType.JAVA (Android uses ErrorType.JAVA for Java exceptions)
      const rumManager = FTExceptionHandler.runtime.getRumManager();
      rumManager.addError(
        crashStack,
        crashMessage,
        ErrorType.JS_CRASH.toString(),
        appState,
        null,
        undefined,
        callback
      ).catch((err: Error) => {
        FTInnerLogger.e(TAG, `Failed to upload crash log: ${err}`);
      });
      
      // Wait for upload to complete (similar to Android's CountDownLatch.await(800ms))
      // Note: In HarmonyOS, we rely on async/await and callbacks
      // The callback will handle stopView and flushSyncData
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error handling crash: ${error}`);
    }
  }

  /**
   * Close current window
   * Attempts to close the current window stage if available
   */
  private closeCurrentWindow(): void {
    try {
      // Try to get context from RUM manager
      const rumManager = FTExceptionHandler.runtime.getRumManager();
      const context = rumManager.getContext();
      
      if (context && (context as common.UIAbilityContext).terminateSelf) {
        FTInnerLogger.i(TAG, "Closing window via UIAbilityContext.terminateSelf()");
        (context as common.UIAbilityContext).terminateSelf().then(() => {
          FTInnerLogger.i(TAG, "Window closed successfully");
        }).catch((err: Error) => {
          FTInnerLogger.e(TAG, `Failed to close window: ${err}`);
        });
      } else {
        FTInnerLogger.w(TAG, "Context not available or not UIAbilityContext, cannot close window");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error closing window: ${error}`);
    }
  }

  /**
   * Check if errorManager is registered (enabled)
   * Used by crash monitors to determine if errorManager crash handling is already active
   * @returns true if errorManager is registered and active
   */
  public static isErrorManagerEnabled(): boolean {
    return FTExceptionHandler.instance !== null && FTExceptionHandler.instance.registerHandled;
  }

  /**
   * Release exception handler
   * Aligned with Android: FTExceptionHandler.release()
   */
  public static release(): void {
    if (FTExceptionHandler.instance !== null) {
      FTExceptionHandler.instance.stopErrorManager();

      // Shutdown native crash adapter
      FTExceptionHandler.instance.shutdownNativeCrashAdapter();

      FTExceptionHandler.instance = null;
    }
  }
}
