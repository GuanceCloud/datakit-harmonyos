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
import { Utils } from '../utils/Utils';
import { Constants } from '../Constants';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTSDK } from '../FTSDK';

const TAG = "FTAppStartCounter";

/**
 * Application startup timing tracker
 * Similar to Android's FTAppStartCounter
 * 
 * Records cold start and hot start duration
 * Cold start: from app process start to first Ability's onWindowStageCreate
 * Hot start: from app returning from background to onWindowStageCreate
 * 
 * Reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-context-stage#listening-for-uiability-lifecycle-changes
 */
export class FTAppStartCounter {
  private static instance: FTAppStartCounter | null = null;
  
  /**
   * Application startup time (nanoseconds)
   * Recorded when SDK class is loaded (similar to Android's FTApplication.APP_START_TIME)
   */
  private static readonly APP_START_TIME: number = Utils.getCurrentNanoTime();
  
  /**
   * Cold start duration (nanoseconds)
   */
  private coldStartDuration: number = 0;
  
  /**
   * Cold start timeline (nanoseconds)
   */
  private coldStartTimeLine: number = 0;
  
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
   * Get application startup time
   * Similar to Android's Utils.getAppStartTimeNs()
   * 
   * For HarmonyOS, we use the time when SDK class is loaded
   * This is similar to Android's FTApplication.APP_START_TIME
   * 
   * @returns Application startup time in nanoseconds
   */
  public static getAppStartTimeNs(): number {
    return FTAppStartCounter.APP_START_TIME;
  }
  
  /**
   * Record cold start duration
   * Called when first Ability's onWindowStageCreate is completed
   * 
   * @param coldStartEndTimeLine End time of cold start (nanoseconds)
   */
  public coldStart(coldStartEndTimeLine: number): void {
    this.coldStartTimeLine = FTAppStartCounter.getAppStartTimeNs();
    this.coldStartDuration = coldStartEndTimeLine - this.coldStartTimeLine;
    FTInnerLogger.d(TAG, `coldStart: duration=${this.coldStartDuration}ns (${this.coldStartDuration / 1000000}ms)`);
  }
  
  /**
   * Upload cold start time
   * Similar to Android's FTAppStartCounter.coldStartUpload()
   * 
   * Reference: Android's FTAutoTrack.putRUMLaunchPerformance(true, coldStartDuration, coldStartTimeLine)
   * Android calls: FTRUMInnerManager.get().addAction(actionName, actionType, duration, startTime, property)
   */
  public coldStartUpload(): void {
    if (this.coldStartDuration <= 0 || this.coldStartTimeLine <= 0) {
      FTInnerLogger.w(TAG, "Cold start data is invalid, skipping upload");
      return;
    }
    
    // Get RUM config from FTSDK (aligned with Android: FTRUMConfigManager.get().getConfig())
    const config = FTSDK.getRumConfig();
    
    if (!config || !config.isEnableTraceUserAction()) {
      FTInnerLogger.d(TAG, "RUM or action tracking is disabled, skipping cold start upload");
      return;
    }
    
    // Upload cold start as an Action
    // Similar to Android's FTAutoTrack.putRUMLaunchPerformance(true, coldStartDuration, coldStartTimeLine)
    // Android: FTRUMInnerManager.get().addAction(actionName, actionType, duration, startTime, property)
    // Directly call FTRUMInnerManager.addAction with startTime parameter (matches Android implementation)
    const innerManager = FTRUMInnerManager.getInstance();
    if (innerManager) {
      // Directly call innerManager.addAction with startTime parameter
      // This matches Android's implementation: addAction(actionName, actionType, duration, startTime, property)
      innerManager.addAction(
        Constants.ACTION_NAME_LAUNCH_COLD,
        Constants.ACTION_TYPE_LAUNCH_COLD,
        this.coldStartDuration,
        this.coldStartTimeLine,  // Use startTime (coldStartTimeLine) instead of currentTime
        {}
      );
      FTInnerLogger.d(TAG, `Cold start uploaded: duration=${this.coldStartDuration}ns (${this.coldStartDuration / 1000000}ms), startTime=${this.coldStartTimeLine}`);
    } else {
      FTInnerLogger.e(TAG, "FTRUMInnerManager is not available, cannot upload cold start data");
    }
    
    // Reset after upload
    this.coldStartDuration = 0;
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
    FTInnerLogger.i(TAG, `hotStart() called: duration=${hotStartDuration}ns (${hotStartDuration / 1000000}ms), startTime=${startTime}`);
    
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
      FTInnerLogger.i(TAG, `Uploading hot start action: actionName=${Constants.ACTION_NAME_LAUNCH_HOT}, actionType=${Constants.ACTION_TYPE_LAUNCH_HOT}`);
      innerManager.addAction(
        Constants.ACTION_NAME_LAUNCH_HOT,
        Constants.ACTION_TYPE_LAUNCH_HOT,
        hotStartDuration,
        startTime,  // Use provided startTime instead of currentTime
        {}
      );
      FTInnerLogger.i(TAG, `✅ Hot start uploaded successfully: duration=${hotStartDuration}ns (${hotStartDuration / 1000000}ms), startTime=${startTime}`);
    } else {
      FTInnerLogger.e(TAG, "FTRUMInnerManager is not available, cannot upload hot start data");
    }
  }
  
  /**
   * Check for retransmission
   * Applied to lifecycle, in cases earlier than SDK install
   * Generally used for third-party frameworks, such as Flutter SDK, ReactNative SDK
   * Similar to Android's FTAppStartCounter.checkToReUpload()
   */
  public checkToReUpload(): void {
    if (this.coldStartDuration > 0) {
      this.coldStartUpload();
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
