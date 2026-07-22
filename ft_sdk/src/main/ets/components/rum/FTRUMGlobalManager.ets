/**
 * HarmonyOS SDK RUM global manager
 * RUM Global Manager for HarmonyOS
 */
import { Context } from '@kit.AbilityKit';
import { FTRUMInnerManager } from './FTRUMInnerManager';
import { UserData } from './bean/UserData';
import { Utils } from '../utils/Utils';
import { ErrorType, ErrorSource, AppState } from './enum/RUMEnums';
import { ResourceParams } from './bean/ResourceParams';
import { NetStatusBean } from './bean/NetStatusBean';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RunnerCompleteCallBack } from './callback/RunnerCompleteCallBack';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMConfig } from '../Configs';

const TAG = "FTRUMGlobalManager";

/**
 * Custom data interface
 */
interface CustomData {
  timestamp: number;
  version: string;
}

/**
 * Property value types
 */
type PropertyValue = string | number | boolean | AppState | ErrorType | CustomData;

/**
 * Property wrapper interface
 */
interface PropertyWrapper {
  value: PropertyValue;
}

/**
 * Property wrapper class for ArkTS compatibility
 * ArkTS requires object literals to correspond to explicitly declared classes
 */
class PropertyWrapperImpl implements PropertyWrapper {
  value: PropertyValue;
  constructor(value: PropertyValue) {
    this.value = value;
  }
}

/**
 * Property class for error properties using Map
 */
class ErrorProperty {
  public properties: Map<string, PropertyValue> = new Map();

  set(key: string, value: PropertyValue): void {
    this.properties.set(key, value);
  }

  // Convert to object for compatibility with existing code
  toObject(): Record<string, object> {
    const result: Record<string, object> = {};
    this.properties.forEach((value, key) => {
      // Use class instead of interface literal for ArkTS compatibility
      const wrapper = new PropertyWrapperImpl(value);
      result[key] = wrapper as object;
    });
    return result;
  }

}

/**
 * RUM global manager
 * Provides simplified public API interface, encapsulates internal implementation details
 */
export class FTRUMGlobalManager {
  private static instance: FTRUMGlobalManager | null = null;
  private innerManager: FTRUMInnerManager | null = null;

  private constructor() {
    // Private constructor
  }

  /**
   * Get FTRUMGlobalManager singleton
   * @returns FTRUMGlobalManager instance
   */
  public static getInstance(): FTRUMGlobalManager {
    if (!FTRUMGlobalManager.instance) {
      FTRUMGlobalManager.instance = new FTRUMGlobalManager();
    }
    return FTRUMGlobalManager.instance;
  }

  public static resetStateInternal(): void {
    if (FTRUMGlobalManager.instance) {
      FTRUMGlobalManager.instance.innerManager = null;
    }
    FTRUMGlobalManager.instance = null;
    FTRUMInnerManager.resetStateInternal();
  }

  /**
   * Initialize RUM manager with config (aligned with Android: FTRUMGlobalManager.initConfig)
   * @param config RUM configuration
   */
  public initConfig(config: FTRUMConfig): void {
    // Aligned with Android: FTRUMGlobalManager.initConfig(FTRUMConfig config)
    // if (config.isRumEnable()) { innerManager = FTRUMInnerManager.get(); }
    if (this.isRumEnable(config)) {
      this.innerManager = FTRUMInnerManager.getInstance();
      FTInnerLogger.d(TAG, `initConfig: RUM enabled, innerManager initialized`);
    } else {
      this.innerManager = null;
      FTInnerLogger.d(TAG, `initConfig: RUM disabled, innerManager not initialized`);
    }
  }

  /**
   * Check if RUM is enabled (aligned with Android: FTRUMConfig.isRumEnable())
   * @param config RUM configuration
   * @returns true if RUM is enabled
   */
  private isRumEnable(config: FTRUMConfig): boolean {
    const rumAppId = config.getRumAppId();
    return rumAppId != null && rumAppId !== "";
  }

  /**
   * Start action.
   *
   * Includes duration calculation and association with nearby Resource, LongTask, and Error events.
   * The SDK controls the internal wait flag; callers only provide the action identity and optional properties.
   *
   * @param actionName Action name
   * @param actionType Action type
   * @param property Extended properties
   */
  public startAction(
    actionName: string,
    actionType: string,
    property: Record<string, object> = {}
  ): void {
    if (this.innerManager) {
      this.innerManager.startAction(actionName, actionType, false, property);
    }
  }

  /**
   * Add a directly completed action.
   *
   * This action is not associated with Error, Resource, or LongTask data. The SDK captures its
   * start time internally. The third argument supports the Android-style property-only overload;
   * pass a duration in nanoseconds followed by properties when both are required.
   *
   * @param actionName Action name
   * @param actionType Action type
   * @param durationOrProperty Duration in nanoseconds, or extended properties
   * @param property Extended properties when duration is provided
   */
  public addAction(
    actionName: string,
    actionType: string,
    durationOrProperty: number | Record<string, object> = 0,
    property: Record<string, object> = {}
  ): void {
    if (this.innerManager) {
      let duration = 0;
      let actionProperty = property;
      if (typeof durationOrProperty === 'number') {
        duration = durationOrProperty;
      } else {
        actionProperty = durationOrProperty;
      }
      const startTime = Utils.getCurrentNanoTime();
      this.innerManager.addAction(actionName, actionType, duration, startTime, actionProperty);
    }
  }


  /**
   * Start view
   * 
   * @param viewName View name
   * @param property View properties
   */
  public async startView(viewName: string, property: Record<string, object> = {}): Promise<void> {
    if (this.innerManager) {
      await this.innerManager.startView(viewName, property);
    } else {
      FTInnerLogger.e(TAG, " innerManager is null, cannot start view");
    }
  }

  /**
   * Stop view
   * 
   * @param property View properties
   */
  public async stopView(property: Record<string, object> = {}): Promise<void> {
    if (this.innerManager) {
      await this.innerManager.stopView(property);
    } else {
      FTInnerLogger.e(TAG, " innerManager is null, cannot stop view");
    }
  }

  /**
   * Create view - record page load time
   * Aligned with Android: FTRUMGlobalManager.onCreateView(String viewName, long loadTime)
   * 
   * @param viewName View name
   * @param loadTime Load time in nanoseconds
   */
  public onCreateView(viewName: string, loadTime: number): void {
    if (this.innerManager) {
      this.innerManager.onCreateView(viewName, loadTime);
    }
  }

  /**
   * Update load time
   * 
   * @param duration Load time duration
   */
  public updateLoadTime(duration: number): void {
    if (this.innerManager) {
      this.innerManager.updateLoadTime(duration);
    }
  }

  /**
   * Add error information
   * Compatible with multiple addError overloads
   * 
   * @param log       log
   * @param message   message
   * @param errorType error type (string or ErrorType enum)
   * @param state     program running state
   * @param property  additional attribute parameters (optional)
   * @param dateline  occurrence time, nanosecond (optional)
   * @param callBack  thread pool call back (optional)
   */
  public addError(
    log: string, 
    message: string, 
    errorType: string | ErrorType, 
    state: AppState,
    property?: Record<string, object> | null,
    dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): void {
    if (this.innerManager) {
      const errorTypeStr = typeof errorType === 'string' ? errorType : (errorType as ErrorType).toString();
      // Fire-and-forget: innerManager.addError is async, but we keep the API synchronous (aligned with Android)
      // The async operation will execute in the background
      this.innerManager.addError(log, message, errorTypeStr, state, property, dateline, callBack).catch((error: Error | string) => {
        const errorMsg = error instanceof Error ? error.message : String(error);
        FTInnerLogger.e(TAG, `addError failed: ${errorMsg}`);
      });
    }
  }

  /**
   * Add custom error implementation
   * 
   * @param errorMessage Error message
   * @param errorStack Error stack trace
   * @param property Additional properties
   */
  public addCustomError(errorMessage: string, errorStack: string = "", property: Record<string, object> = {}): void {
    if (!this.innerManager) {
      return;
    }

    const errorPropertyObj = new ErrorProperty();
    const keys = Object.keys(property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = property[key];
      try {
        const wrapper = value as PropertyWrapper;
        errorPropertyObj.set(key, wrapper.value);
      } catch {
        errorPropertyObj.set(key, value as PropertyValue);
      }
    }
    
    // Fire-and-forget: innerManager.addError is async, but we keep the API synchronous (aligned with Android)
    // The async operation will execute in the background
    this.innerManager.addError(
      errorStack,
      errorMessage,
      ErrorType.CUSTOM.toString(),
      AppState.RUN,
      errorPropertyObj.toObject()
    ).catch((error: Error | string) => {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `addCustomError failed: ${errorMsg}`);
    });
  }

  /**
   * Start resource
   * 
   * @param resourceId Resource ID
   */
  public startResource(resourceId: string): void {
    if (this.innerManager) {
      this.innerManager.startResource(resourceId);
    }
  }

  /**
   * Stop resource
   * 
   * @param resourceId Resource ID
   * @param statusCode Status code
   * @param contentLength Content length
   */
  public stopResource(resourceId: string, statusCode?: number, contentLength?: number): void {
    if (this.innerManager) {
      this.innerManager.stopResource(resourceId);
    }
  }

  /**
   * Add resource data
   * Add resource implementation
   * 
   * @param resourceId Resource ID
   * @param params Resource parameters
   * @param netStatusBean Network status Bean
   */
  public addResource(resourceId: string, params: ResourceParams, netStatusBean: NetStatusBean): void {
    if (this.innerManager) {
      this.innerManager.addResource(resourceId, params, netStatusBean);
    }
  }

  /**
   * Convert request headers Map to string
   */
  private convertHeadersToString(headerMap: Map<string, string[]>): string {
    if (!headerMap || headerMap.size === 0) {
      return "";
    }

    const lines: string[] = [];
    const headerKeys = Array.from(headerMap.keys());
    for (let i = 0; i < headerKeys.length; i++) {
      const key = headerKeys[i];
      const values = headerMap.get(key);
      if (values && values.length > 0) {
        lines.push(`${key}: ${values.join(', ')}`);
      }
    }
    return lines.join('\n');
  }

  /**
   * Add long task
   * 
   * @param log Long task log/stack trace
   * @param duration Duration (nanoseconds)
   * @param property Additional properties (optional)
   */
  public addLongTask(log: string, duration: number, property: Record<string, string | number | boolean> = {}): void {
    if (this.innerManager) {
      this.innerManager.addLongTask(log, duration, property);
    } else {
      FTInnerLogger.w(TAG, ` addLongTask failed: innerManager not available`);
    }
  }

  /**
   * Check if initialized
   * @returns Whether initialized
   */
  public isInitialized(): boolean {
    return this.innerManager !== null;
  }
}
