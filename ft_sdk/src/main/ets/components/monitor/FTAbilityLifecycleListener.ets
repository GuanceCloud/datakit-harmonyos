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
import { FTAppLaunchTracker } from './FTAppLaunchTracker';
import { FTAppStartCounter } from './FTAppStartCounter';
import { FTDBSpoolManager } from '../db/FTDBSpoolManager';
import { FTDBTaskPoolExecutor } from '../db/FTDBTaskPoolExecutor';
import { FTMonitorManager } from '../rum/FTMonitorManager';
import { FTUIBlockManager } from './FTUIBlockManager';

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

interface ApplicationStateChangeCallback {
  onApplicationForeground: () => void;
  onApplicationBackground: () => void;
}

interface ApplicationContextWithApplicationStateChange {
  on(type: 'applicationStateChange', callback: ApplicationStateChangeCallback): void;
  off(type: 'applicationStateChange', callback?: ApplicationStateChangeCallback): void;
}

export class FTAbilityLifecycleListener {
  private static instance: FTAbilityLifecycleListener | null = null;
  private isRegistered: boolean = false;
  private lifecycleCallback: AbilityLifecycleCallback | null = null;
  private lifecycleId: number = -1;
  private applicationStateCallback: ApplicationStateChangeCallback | null = null;
  private applicationStateRegistered: boolean = false;
  // Application state events are authoritative. Keep this set as a fallback
  // for platforms that only provide UIAbility lifecycle callbacks, so one of
  // several UIAbilities going background cannot classify the whole process.
  private foregroundAbilities: Set<UIAbility> = new Set();
  
  /**
   * Sleep delay time (10 seconds)
   * Similar to Android's LifeCircleTraceCallback.DELAY_SLEEP_MILLIS
   */
  private static readonly DELAY_SLEEP_MILLIS: number = 10000; // 10 seconds
  
  /**
   * Whether already in sleep state, here going to background for 10 seconds is considered as sleep
   * Similar to Android's LifeCircleTraceCallback.alreadySleep
   */
  private alreadySleep: boolean = false;
  
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
    if (this.isRegistered) {
      FTInnerLogger.w(TAG, "Lifecycle listener is already registered");
      return;
    }

    try {
      // First check if we can get AbilityContext
      const abilityContext = Utils.getAbilityContext();
      if (!abilityContext) {
        FTInnerLogger.w(TAG, "AbilityContext is not available, cannot get ApplicationContext");
        return;
      }
      
      // Then get ApplicationContext from AbilityContext
      const applicationContext = abilityContext.getApplicationContext();
      if (!applicationContext) {
        FTInnerLogger.w(TAG, "ApplicationContext is not available, cannot register lifecycle listener");
        return;
      }
      this.registerApplicationStateListener(applicationContext as Object);

      // Create lifecycle callback
      this.lifecycleCallback = {
        onAbilityCreate: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityCreate: UIAbility lifecycle event`);
          FTSDK.recordAppFirstUIAbilityCreate();
        },
        onWindowStageCreate: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageCreate: UIAbility lifecycle event`);
          this.registerLaunchWindowStateListener(windowStage);
        },
        onWindowStageActive: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageActive: UIAbility lifecycle event`);
          FTUIBlockManager.getInstance().setAppInForeground(true);
          try {
            const mainWindow = windowStage.getMainWindowSync();
            FTSDK.onWindowStageActive(mainWindow);
          } catch (error) {
            FTInnerLogger.w(TAG, `Failed to cache MainWindow on window stage active: ${String(error)}`);
            FTSDK.onWindowStageActive();
          }
        },
        onWindowStageDestroy: (ability: UIAbility, windowStage: window.WindowStage) => {
          FTInnerLogger.d(TAG, `onWindowStageDestroy: UIAbility lifecycle event`);
          FTMonitorManager.getInstance().setAppInForeground(false);
          FTUIBlockManager.getInstance().setAppInForeground(false);
          FTSDK.cleanupUIFeatures();
          // Stop view when window stage is destroyed
          this.flushDbLaneOnLifecycleChange("onWindowStageDestroy");
        },
        onAbilityForeground: (ability: UIAbility) => {
          this.foregroundAbilities.add(ability);
          FTMonitorManager.getInstance().setAppInForeground(true);
          FTUIBlockManager.getInstance().setAppInForeground(true);
          FTSDK.recordAppLaunchApplicationForeground();
          
          // Clear sleep check timer if app returns to foreground
          if (this.sleepCheckTimer !== null) {
            clearTimeout(this.sleepCheckTimer);
            this.sleepCheckTimer = null;
          }
          
          // Record start time for potential hot start
          // Similar to Android's LifeCircleTraceCallback.onPreStart()
          const appStartCounter = FTAppStartCounter.getInstance();
          const config = FTSDK.getRumConfig();
          const isHotStart: boolean = this.alreadySleep && appStartCounter.isInited();
          FTInnerLogger.d(TAG, `App foregrounded: slept=${this.alreadySleep}, hotStart=${isHotStart}`);

          if (isHotStart) {
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
            this.startClockTimeNano = FTAppLaunchTracker.getStartupUptimeNs();
            
            // Calculate hot start duration after a short delay to ensure UI is ready
            // Use setTimeout to delay the calculation, similar to waiting for onAbilityWindowStageCreate
            setTimeout(() => {
              if (this.startTimeNanoTime > 0 && this.startClockTimeNano > 0) {
                const endTime = FTAppLaunchTracker.getStartupUptimeNs();
                const hotStartDuration = endTime - this.startClockTimeNano;
                
                if (hotStartDuration > 0 && config && config.isEnableTraceUserAction()) {
                  // Upload hot start data //FIXME do not call in first cold launch
                  appStartCounter.hotStart(hotStartDuration, this.startTimeNanoTime);
                  FTInnerLogger.d(TAG, `Hot start recorded: durationMs=${hotStartDuration / 1000000}`);
                }
                
                // Reset start time after upload
                this.startTimeNanoTime = 0;
                this.startClockTimeNano = 0;
              } else {
                // Never retain a half-recorded hot-start boundary. In
                // particular, do not retry with a wall-clock duration if the
                // monotonic STARTUP clock is unavailable.
                this.startTimeNanoTime = 0;
                this.startClockTimeNano = 0;
              }
            }, 100); // 100ms delay to ensure UI is ready
          } else {
            // Reset alreadySleep if app returns to foreground before 10 seconds.
            this.alreadySleep = false;
          }
        },
        onAbilityBackground: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityBackground: UIAbility lifecycle event`);
          this.foregroundAbilities.delete(ability);
          FTMonitorManager.getInstance().setAppInForeground(false);
          FTUIBlockManager.getInstance().setAppInForeground(false);
          if (this.foregroundAbilities.size === 0) {
            FTSDK.recordAppLaunchApplicationBackground();
          }
          // Stop view when ability goes to background (aligned with Android onActivityPaused)
          this.flushDbLaneOnLifecycleChange("onAbilityBackground");
          
          // Schedule check for long time sleep (10 seconds)
          // Similar to Android's LifeCircleTraceCallback.onEnterBackground()
          this.scheduleSleepCheck();
        },
        onAbilityDestroy: (ability: UIAbility) => {
          FTInnerLogger.d(TAG, `onAbilityDestroy: UIAbility lifecycle event`);
          this.foregroundAbilities.delete(ability);
          FTMonitorManager.getInstance().setAppInForeground(false);
          FTUIBlockManager.getInstance().setAppInForeground(false);
          if (this.foregroundAbilities.size === 0) {
            FTSDK.recordAppLaunchApplicationBackground();
          }
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
      
      const appContext = applicationContext as ApplicationContextWithOn;
      if (appContext && typeof appContext.on === 'function') {
        this.lifecycleId = appContext.on('abilityLifecycle', this.lifecycleCallback);
        this.isRegistered = true;
        FTInnerLogger.d(TAG, `UIAbility lifecycle listener registered: lifecycleId=${this.lifecycleId}`);
      } else {
        FTInnerLogger.w(TAG,
          `ApplicationContext.on('abilityLifecycle') unavailable; lifecycle monitoring disabled: ` +
          `appContext=${appContext !== null && appContext !== undefined}, hasOn=${typeof appContext?.on === 'function'}`);
        return;
      }

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to register lifecycle listener: ${String(error)}`);
    }
  }

  /**
   * This listener is intentionally registerable from AbilityStage before RUM
   * installation, so a background-only process can be classified without an
   * appManager observer or extra permission.
   */
  public registerApplicationStateListener(applicationContext: Object): void {
    if (this.applicationStateRegistered || !applicationContext) {
      return;
    }
    try {
      const appContext = applicationContext as ApplicationContextWithApplicationStateChange;
      if (typeof appContext.on !== 'function') {
        return;
      }
      this.applicationStateCallback = {
        onApplicationForeground: (): void => {
          FTSDK.recordAppLaunchApplicationForeground();
        },
        onApplicationBackground: (): void => {
          FTSDK.recordAppLaunchApplicationBackground();
        }
      };
      appContext.on('applicationStateChange', this.applicationStateCallback);
      this.applicationStateRegistered = true;
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to register application-state listener: ${String(error)}`);
      this.applicationStateCallback = null;
    }
  }

  private registerLaunchWindowStateListener(windowStage: window.WindowStage): void {
    try {
      const callback = (event: window.WindowStageEventType): void => {
        if (event !== window.WindowStageEventType.SHOWN && event !== window.WindowStageEventType.ACTIVE) {
          return;
        }
        FTSDK.recordAppLaunchWindowForeground();
        try {
          windowStage.off('windowStageEvent', callback);
        } catch (error) {
          FTInnerLogger.w(TAG, `Unable to unregister launch WindowStage listener: ${String(error)}`);
        }
      };
      windowStage.on('windowStageEvent', callback);
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to observe launch WindowStage state: ${String(error)}`);
    }
  }

  /**
   * Unregister lifecycle callback
   */
  public unregister(): void {
    if (!this.isRegistered && !this.applicationStateRegistered) {
      FTInnerLogger.w(TAG, "Lifecycle listener is not registered");
      return;
    }

    try {
      FTMonitorManager.getInstance().setAppInForeground(false);
      FTUIBlockManager.getInstance().setAppInForeground(false);
      // Clear sleep check timer if exists
      if (this.sleepCheckTimer !== null) {
        clearTimeout(this.sleepCheckTimer);
        this.sleepCheckTimer = null;
        FTInnerLogger.d(TAG, "Cleared sleep check timer during unregister");
      }
      
      const applicationContext = Utils.getApplicationContext();
      if (!applicationContext) {
        FTInnerLogger.w(TAG, "ApplicationContext is not available, lifecycle callbacks cannot be unregistered");
      }

      if (this.lifecycleCallback && applicationContext) {
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
      }
      this.lifecycleCallback = null;

      if (this.applicationStateCallback && applicationContext) {
        try {
          const applicationStateContext = applicationContext as ApplicationContextWithApplicationStateChange;
          if (typeof applicationStateContext.off === 'function') {
            applicationStateContext.off('applicationStateChange', this.applicationStateCallback);
          }
        } catch (error) {
          FTInnerLogger.w(TAG, `Unable to unregister application-state listener: ${String(error)}`);
        }
      }
      this.applicationStateCallback = null;

      // Reset state
      this.isRegistered = false;
      this.applicationStateRegistered = false;
      this.lifecycleId = -1;
      this.alreadySleep = false; // Reset to default
      this.startTimeNanoTime = 0;
      this.startClockTimeNano = 0;
      this.foregroundAbilities.clear();
      
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
    
    FTInnerLogger.d(TAG, `Sleep check scheduled: delayMs=${FTAbilityLifecycleListener.DELAY_SLEEP_MILLIS}`);
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
    if (appStartCounter.isInited()) {
      // App was initialized, and we're here after 10 seconds delay
      // This means app has been in background for >10 seconds
      this.alreadySleep = true;
      FTInnerLogger.d(TAG, "App remained in background for >10s; sleep state enabled");
    }
  }
}
