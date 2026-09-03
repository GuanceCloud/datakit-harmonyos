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

import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTSDK } from '../FTSDK';

const TAG = "FTAppStartCounter";

/**
 * Retains the existing hot-start Action behavior. Cold-start timing is owned
 * by FTAppLaunchTracker so all cold-launch boundaries use one startup-uptime clock.
 */
export class FTAppStartCounter {
  private static instance: FTAppStartCounter | null = null;
  
  /**
   * Whether app has been initialized (used to distinguish cold start from hot start)
   */
  private mInited: boolean = false;
  
  private constructor() {
    // Private constructor
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): FTAppStartCounter {
    if (!FTAppStartCounter.instance) {
      FTAppStartCounter.instance = new FTAppStartCounter();
    }
    return FTAppStartCounter.instance;
  }
  
  /**
   * Upload hot start time
   * Similar to Android's FTAppStartCounter.hotStart()
   * 
   * @param hotStartDuration Hot start duration (nanoseconds)
   * @param startTime Start time (nanoseconds)
   * 
   * Reference: Android's FTAutoTrack.putRUMLaunchPerformance(false, hotStartDuration, startTime)
   * Android calls: FTRUMInnerManager.get().addAction(actionName, actionType, duration, startTime, property)
   */
  public hotStart(hotStartDuration: number, startTime: number): void {
    // Get RUM config from FTSDK (aligned with Android: FTRUMConfigManager.get().getConfig())
    const config = FTSDK.getRumConfig();
    
    if (!config || !config.isEnableTraceUserAction()) {
      FTInnerLogger.w(TAG, "RUM or action tracking is disabled, skipping hot start upload");
      return;
    }
    
    // Upload hot start as an Action
    // Similar to Android's FTAutoTrack.putRUMLaunchPerformance(false, hotStartDuration, startTime)
    // Android: FTRUMInnerManager.get().addAction(actionName, actionType, duration, startTime, property)
    // Directly call FTRUMInnerManager.addAction with startTime parameter (matches Android implementation)
    const innerManager = FTRUMInnerManager.getInstance();
    if (innerManager) {
      // Directly call innerManager.addAction with startTime parameter
      // This matches Android's implementation: addAction(actionName, actionType, duration, startTime, property)
      innerManager.addAction(
        Constants.ACTION_NAME_LAUNCH_HOT,
        Constants.ACTION_TYPE_LAUNCH_HOT,
        hotStartDuration,
        startTime,  // Use provided startTime instead of currentTime
        {}
      );
    } else {
      FTInnerLogger.e(TAG, "FTRUMInnerManager is not available, cannot upload hot start data");
    }
  }
  
  /**
   * Set initialization status
   * Used to distinguish cold start from hot start
   * 
   * @param inited Whether app has been initialized
   */
  public setInited(inited: boolean): void {
    this.mInited = inited;
  }
  
  /**
   * Get initialization status
   * 
   * @returns Whether app has been initialized
   */
  public isInited(): boolean {
    return this.mInited;
  }
}
