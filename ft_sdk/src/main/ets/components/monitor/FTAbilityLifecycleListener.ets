/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMGlobalManager } from '../rum/FTRUMGlobalManager';
import { FTSDK } from '../FTSDK';
import { Utils } from '../utils/Utils';
import { FTAppStartCounter } from './FTAppStartCounter';
import { FTDBSpoolManager } from '../db/FTDBSpoolManager';
import { FTDBTaskPoolExecutor } from '../db/FTDBTaskPoolExecutor';

const TAG = "FTAbilityLifecycleListener";
const BACKGROUND_DB_FLUSH_TIMEOUT_MS = 2500;

/**
 * UIAbility lifecycle listener
 * Listens to UIAbility lifecycle changes via applicationContext
 * This allows SDK to automatically handle view lifecycle without requiring app code changes
 * Reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-context-stage#listening-for-uiability-lifecycle-changes
 */
/**
 * Ability lifecycle callback interface
 * Reference: HarmonyOS ApplicationContext API
 */
interface AbilityLifecycleCallback {
  onAbilityCreate?: (ability: UIAbility) => void;
  onWindowStageCreate?: (ability: UIAbility, windowStage: window.WindowStage) => void;
  onWindowStageActive?: (ability: UIAbility, windowStage: window.WindowStage) => void;
  onWindowStageDestroy?: (ability: UIAbility, windowStage: window.WindowStage) => void;
  onAbilityForeground?: (ability: UIAbility) => void;
  onAbilityBackground?: (ability: UIAbility) => void;
  onAbilityDestroy?: (ability: UIAbility) => void;
}

export class FTAbilityLifecycleListener {
  private static instance: FTAbilityLifecycleListener | null = null;
  private isRegistered: boolean = false;
  private lifecycleCallback: AbilityLifecycleCallback | null = null;
  private lifecycleId: number = -1;
  
  /**
   * Sleep delay time (10 seconds)
   * Similar to Android's LifeCircleTraceCallback.DELAY_SLEEP_MILLIS
   */
  private static readonly DELAY_SLEEP_MILLIS: number = 10000; // 10 seconds
  
  /**
   * Whether already in sleep state, here going to background for 10 seconds is considered as sleep
   * Similar to Android's LifeCircleTraceCallback.alreadySleep
   */
  private alreadySleep: boolean = true;
  
  /**
   * Hot start start time (nanoseconds)
   * Similar to Android's LifeCircleTraceCallback.startTimeNanoTime
   */
  private startTimeNanoTime: number = 0;
  
  /**
   * Hot start start clock time (nanoseconds, for duration calculation)
   * Similar to Android's LifeCircleTraceCallback.startClockTimeNano
   */
  private startClockTimeNano: number = 0;
  
  /**
   * Timer for checking long time sleep
   */
  private sleepCheckTimer: number | null = null;

  private constructor() {
    // Private constructor
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): FTAbilityLifecycleListener {
    if (!FTAbilityLifecycleListener.instance) {
      FTAbilityLifecycleListener.instance = new FTAbilityLifecycleListener();
    }
    return FTAbilityLifecycleListener.instance;
  }

  /**
   * Register lifecycle callback
   * This should be called during SDK initialization
   */
  public register(): void {
    FTInnerLogger.i(TAG, "register() called - starting registration process");
    if (this.isRegistered) {
      FTInnerLogger.w(TAG, "Lifecycle listener is already registered");
      return;
    }

    try {
      FTInnerLogger.d(TAG, "Getting ApplicationContext from Utils...");
      // First check if we can get AbilityContext
      const abilityContext = Utils.getAbilityContext();
      if (!abilityContext) {
        FTInnerLogger.w(TAG, "AbilityContext is not available, cannot get ApplicationContext");
        return;
      }
      FTInnerLogger.d(TAG, "AbilityContext obtained, getting ApplicationContext...");
      
      // Then get ApplicationContext from AbilityContext
      const applicationContext = abilityContext.getApplicationContext();
      if (!applicationContext) {
        FTInnerLogger.w(TAG, "ApplicationContext is not available, cannot register lifecycle listener");
        return;
      }
      FTInnerLogger.d(TAG, "ApplicationContext obtained successfully");

      // Create lifecycle callback
      this.lifecycleCallback = {
        onAbilityCreate: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityCreate: UIAbility lifecycle event`);
          // Record start time for cold start calculation
          // This is similar to Android's LifeCircleTraceCallback.onPreOnCreate()
          const appStartCounter = FTAppStartCounter.getInstance();
          if (!appStartCounter.isInited()) {
            // This is the first Ability creation, record as potential cold start
            FTInnerLogger.d(TAG, "First Ability created, potential cold start");
          }
        },
        onWindowStageCreate: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageCreate: UIAbility lifecycle event`);
          // Calculate cold start or hot start time when window stage is created
          // Similar to Android's LifeCircleTraceCallback.onPostResume()
          const appStartCounter = FTAppStartCounter.getInstance();
          const config = FTSDK.getRumConfig();
          
          if (!appStartCounter.isInited()) {
            // Cold start: from app process start to first window stage create
            const endTime = Utils.getCurrentNanoTime();
            appStartCounter.coldStart(endTime);
            
            // Get RUM config from FTSDK (aligned with Android: FTRUMConfigManager.get().getConfig())
            if (config && config.isEnableTraceUserAction()) {
              // Upload cold start data
              appStartCounter.coldStartUpload();
            }
            
            // Mark as initialized
            appStartCounter.setInited(true);
            FTInnerLogger.d(TAG, "Cold start calculated and uploaded");
          } else if (this.alreadySleep) {
            // Hot start: app returning from background (alreadySleep = true)
            // Note: In HarmonyOS, onAbilityWindowStageCreate may not be called again if WindowStage already exists
            // So hot start is now handled in onAbilityForeground instead
            // This branch is kept for compatibility, but should rarely be reached
            FTInnerLogger.d(TAG, `onWindowStageCreate: Hot start condition met but hot start should have been handled in onAbilityForeground. alreadySleep=${this.alreadySleep}, startTimeNanoTime=${this.startTimeNanoTime}`);
            if (config && config.isEnableTraceUserAction()) {
              if (this.startTimeNanoTime > 0) {
                // Calculate hot start duration
                // For HarmonyOS, we use getCurrentNanoTime() difference since we don't have elapsedRealtimeNanos
                // Duration is from onAbilityForeground to onAbilityWindowStageCreate
                const now = Utils.getCurrentNanoTime();
                const hotStartDuration = now - this.startClockTimeNano;
                
                // Upload hot start data
                appStartCounter.hotStart(hotStartDuration, this.startTimeNanoTime);
                FTInnerLogger.d(TAG, `Hot start calculated and uploaded from onWindowStageCreate: duration=${hotStartDuration}ns (${hotStartDuration / 1000000}ms)`);
                
                // Reset start time after upload
                this.startTimeNanoTime = 0;
                this.startClockTimeNano = 0;
              } else {
                FTInnerLogger.w(TAG, `Hot start condition met but startTimeNanoTime is 0, hot start not recorded. This may happen if onAbilityForeground was not called or conditions were not met.`);
              }
            } else {
              FTInnerLogger.d(TAG, `Hot start condition met but RUM or action tracking is disabled, skipping hot start upload`);
            }
            // Reset alreadySleep flag
            this.alreadySleep = false;
          } else {
            FTInnerLogger.d(TAG, `Not a hot start: alreadySleep=${this.alreadySleep}, isInited=${appStartCounter.isInited()}`);
          }
        },
        onWindowStageActive: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageActive: UIAbility lifecycle event`);
          try {
            const mainWindow = windowStage.getMainWindowSync();
            FTSDK.onWindowStageActive(mainWindow);
            FTInnerLogger.d(TAG, "MainWindow cached on window stage active for automatic UI feature initialization");
          } catch (error) {
            FTInnerLogger.w(TAG, `Failed to cache MainWindow on window stage active: ${String(error)}`);
            FTSDK.onWindowStageActive();
          }
        },
        onWindowStageDestroy: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageDestroy: UIAbility lifecycle event`);
          FTSDK.cleanupUIFeatures();
          // Stop view when window stage is destroyed
          this.flushDbLaneOnLifecycleChange("onWindowStageDestroy");
        },
        onAbilityForeground: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityForeground: UIAbility lifecycle event`);
          
          // Clear sleep check timer if app returns to foreground
          if (this.sleepCheckTimer !== null) {
            clearTimeout(this.sleepCheckTimer);
            this.sleepCheckTimer = null;
            FTInnerLogger.d(TAG, "Cleared sleep check timer - app returned to foreground");
          }
          
          // Record start time for potential hot start
          // Similar to Android's LifeCircleTraceCallback.onPreStart()
          const appStartCounter = FTAppStartCounter.getInstance();
          const config = FTSDK.getRumConfig();
          FTInnerLogger.d(TAG, `onAbilityForeground: alreadySleep=${this.alreadySleep}, isInited=${appStartCounter.isInited()}`);
          
          if (this.alreadySleep && appStartCounter.isInited()) {
            // Keep the Android hot-start refresh behaviour even when no UI
            // tracking feature is enabled and this listener exists solely for
            // remote configuration.
            FTSDK.updateRemoteConfig();
            // App has been initialized and was sleeping (in background for >10s)
            // This is a hot start
            // In HarmonyOS, onAbilityWindowStageCreate may not be called again if WindowStage already exists
            // So we calculate and upload hot start directly in onAbilityForeground
            const startTime = Utils.getCurrentNanoTime();
            this.startTimeNanoTime = startTime;
            this.startClockTimeNano = startTime;
            FTInnerLogger.d(TAG, `App returning from background, hot start detected - startTime=${this.startTimeNanoTime}`);
            
            // Calculate hot start duration after a short delay to ensure UI is ready
            // Use setTimeout to delay the calculation, similar to waiting for onAbilityWindowStageCreate
            setTimeout(() => {
              if (this.startTimeNanoTime > 0) {
                const endTime = Utils.getCurrentNanoTime();
                const hotStartDuration = endTime - this.startClockTimeNano;
                
                if (config && config.isEnableTraceUserAction()) {
                  // Upload hot start data //FIXME do not call in first cold launch
                  appStartCounter.hotStart(hotStartDuration, this.startTimeNanoTime);
                  FTInnerLogger.d(TAG, `Hot start calculated and uploaded from onAbilityForeground: duration=${hotStartDuration}ns (${hotStartDuration / 1000000}ms)`);
                } else {
                  FTInnerLogger.d(TAG, `Hot start detected but RUM or action tracking is disabled, skipping upload`);
                }
                
                // Reset start time after upload
                this.startTimeNanoTime = 0;
                this.startClockTimeNano = 0;
              }
            }, 100); // 100ms delay to ensure UI is ready
          } else {
            // Reset alreadySleep if app returns to foreground before 10 seconds
            if (this.alreadySleep) {
              FTInnerLogger.d(TAG, `alreadySleep was true but isInited is false, resetting alreadySleep`);
            } else {
              FTInnerLogger.d(TAG, `App returned to foreground before 10 seconds, resetting alreadySleep`);
            }
            this.alreadySleep = false;
          }
        },
        onAbilityBackground: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityBackground: UIAbility lifecycle event`);
          // Stop view when ability goes to background (aligned with Android onActivityPaused)
          this.flushDbLaneOnLifecycleChange("onAbilityBackground");
          
          // Schedule check for long time sleep (10 seconds)
          // Similar to Android's LifeCircleTraceCallback.onEnterBackground()
          FTInnerLogger.d(TAG, `onAbilityBackground: Scheduling sleep check after ${FTAbilityLifecycleListener.DELAY_SLEEP_MILLIS}ms`);
          this.scheduleSleepCheck();
        },
        onAbilityDestroy: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityDestroy: UIAbility lifecycle event`);
          // Stop view when ability is destroyed (aligned with Android onDestroy)
          this.flushDbLaneOnLifecycleChange("onAbilityDestroy");
        }
      };

      // Register callback using on('abilityLifecycle') event
      // Reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-context-stage#listening-for-uiability-lifecycle-changes
      // ApplicationContext uses event-based API: on('abilityLifecycle', callback)
      // Define interface for ApplicationContext with on method
      interface ApplicationContextWithOn {
        on(type: string, callback: AbilityLifecycleCallback): number;
      }
      
      FTInnerLogger.d(TAG, "Attempting to register lifecycle callback using on('abilityLifecycle')...");
      const appContext = applicationContext as ApplicationContextWithOn;
      FTInnerLogger.d(TAG, `appContext type check: ${typeof appContext}, has 'on' method: ${typeof appContext.on === 'function'}`);
      if (appContext && typeof appContext.on === 'function') {
        FTInnerLogger.d(TAG, "Calling appContext.on('abilityLifecycle', callback)...");
        this.lifecycleId = appContext.on('abilityLifecycle', this.lifecycleCallback);
        this.isRegistered = true;
        FTInnerLogger.i(TAG, `✅ Successfully registered lifecycle callback via on('abilityLifecycle'), lifecycleId=${this.lifecycleId}`);
      } else {
        FTInnerLogger.w(TAG, "❌ ApplicationContext.on('abilityLifecycle') API not available, lifecycle monitoring disabled");
        FTInnerLogger.w(TAG, `   appContext exists: ${appContext !== null && appContext !== undefined}, has 'on' method: ${typeof appContext?.on === 'function'}`);
        return;
      }

      FTInnerLogger.i(TAG, "UIAbility lifecycle listener registered successfully");

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to register lifecycle listener: ${String(error)}`);
    }
  }

  /**
   * Unregister lifecycle callback
   */
  public unregister(): void {
    if (!this.isRegistered) {
      FTInnerLogger.w(TAG, "Lifecycle listener is not registered");
      return;
    }

    try {
      // Clear sleep check timer if exists
      if (this.sleepCheckTimer !== null) {
        clearTimeout(this.sleepCheckTimer);
        this.sleepCheckTimer = null;
        FTInnerLogger.d(TAG, "Cleared sleep check timer during unregister");
      }
      
      const applicationContext = Utils.getApplicationContext();
      if (!applicationContext) {
        FTInnerLogger.w(TAG, "ApplicationContext is not available, cannot unregister lifecycle listener");
        return;
      }

      if (this.lifecycleCallback) {
        // Remove callback using off('abilityLifecycle') event
        // Define interface for ApplicationContext with off method
        interface ApplicationContextWithOff {
          off(type: string, id: number): Promise<void>;
        }
        
        const appContext = applicationContext as ApplicationContextWithOff;
        if (appContext && typeof appContext.off === 'function' && this.lifecycleId >= 0) {
          appContext.off('abilityLifecycle', this.lifecycleId).catch((error: Error) => {
            FTInnerLogger.e(TAG, `Failed to unregister abilityLifecycle listener: ${String(error)}`);
          });
        }
        this.lifecycleCallback = null;
      }

      // Reset state
      this.isRegistered = false;
      this.lifecycleId = -1;
      this.alreadySleep = true; // Reset to default
      this.startTimeNanoTime = 0;
      this.startClockTimeNano = 0;
      
      FTInnerLogger.i(TAG, "UIAbility lifecycle listener unregistered successfully");

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to unregister lifecycle listener: ${String(error)}`);
    }
  }

  /**
   * Stop current view when app lifecycle changes
   * Used in onBackground and onDestroy to ensure view data is processed
   * @param context Context string for logging (e.g., "onAbilityBackground", "onAbilityDestroy")
   */
  private async stopViewOnLifecycleChange(context: string): Promise<void> {
    try {
      if (FTSDK.isViewTrackingEnabled()) {
        const rumManager = FTRUMGlobalManager.getInstance();
        await rumManager.stopView();
        FTInnerLogger.d(TAG, `stopView called in ${context}`);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error calling stopView in ${context}: ${String(error)}`);
    }
  }

  private flushDbLaneOnLifecycleChange(context: string): void {
    this.flushDbLaneOnLifecycleChangeAsync(context).catch((error: Error) => {
      FTInnerLogger.e(TAG, `DB lane flush failed in ${context}: ${error.message}`);
    });
  }

  private async flushDbLaneOnLifecycleChangeAsync(context: string): Promise<void> {
    await this.stopViewOnLifecycleChange(context);
    await this.awaitDbLaneWithTimeout(context);

    const abilityContext = Utils.getAbilityContext();
    if (abilityContext) {
      await FTDBSpoolManager.getInstance().replay(abilityContext, context);
    }

    FTSDK.flushSyncData();
  }

  private async awaitDbLaneWithTimeout(context: string): Promise<void> {
    let timedOut = false;
    const abilityContext = Utils.getAbilityContext();
    await Promise.race([
      abilityContext ? FTDBTaskPoolExecutor.awaitIdle(abilityContext) : Promise.resolve(),
      new Promise<void>((resolve) => {
        setTimeout(() => {
          timedOut = true;
          resolve();
        }, BACKGROUND_DB_FLUSH_TIMEOUT_MS);
      })
    ]);
    if (timedOut) {
      FTInnerLogger.w(TAG, `DB lane flush timed out in ${context}`);
    }
  }
  
  /**
   * Schedule check for long time sleep
   * Similar to Android's LifeCircleTraceCallback.onEnterBackground()
   * After 10 seconds in background, mark as alreadySleep = true
   */
  private scheduleSleepCheck(): void {
    // Clear existing timer if any
    if (this.sleepCheckTimer !== null) {
      clearTimeout(this.sleepCheckTimer);
      this.sleepCheckTimer = null;
    }
    
    // Schedule check after 10 seconds
    // Similar to Android's handler.sendEmptyMessageDelayed(MSG_CHECK_SLEEP_STATUS, DELAY_SLEEP_MILLIS)
    this.sleepCheckTimer = setTimeout(() => {
      this.checkLongTimeSleep();
      this.sleepCheckTimer = null;
    }, FTAbilityLifecycleListener.DELAY_SLEEP_MILLIS);
    
    FTInnerLogger.d(TAG, `Scheduled sleep check after ${FTAbilityLifecycleListener.DELAY_SLEEP_MILLIS}ms`);
  }
  
  /**
   * Check if app is still in background after delay
   * Similar to Android's LifeCircleTraceCallback.checkLongTimeSleep()
   * If app is still in background, mark as alreadySleep = true
   * 
   * Note: This method is called after 10 seconds delay from onAbilityBackground
   * If the timer fires, it means app has been in background for at least 10 seconds
   */
  private checkLongTimeSleep(): void {
    const appStartCounter = FTAppStartCounter.getInstance();
    FTInnerLogger.d(TAG, `checkLongTimeSleep: isInited=${appStartCounter.isInited()}, sleepCheckTimer=${this.sleepCheckTimer}`);
    if (appStartCounter.isInited()) {
      // App was initialized, and we're here after 10 seconds delay
      // This means app has been in background for >10 seconds
      this.alreadySleep = true;
      FTInnerLogger.d(TAG, "App has been in background for >10s, marked as alreadySleep=true");
    } else {
      FTInnerLogger.d(TAG, "App not initialized yet, cannot mark as alreadySleep");
    }
  }
}
