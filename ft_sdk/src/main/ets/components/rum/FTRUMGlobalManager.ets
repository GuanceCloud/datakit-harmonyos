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
   * Start action
   * Includes duration calculation mechanism, attempts to associate nearby Resource, LongTask and Error events
   * Has 100ms frequency protection mechanism, recommended for user interaction type events
   * 
   * @param actionName Action name
   * @param actionType Action type
   */
  public startAction(actionName: string, actionType: string): void {
    if (this.innerManager) {
      this.innerManager.startAction(actionName, actionType);
    }
  }

  /**
   * Start action (with properties)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param property Extended properties
   */
  public startActionWithProperty(actionName: string, actionType: string, property: Record<string, object>): void {
    if (this.innerManager) {
      this.innerManager.startAction(actionName, actionType, false, property);
    }
  }

  /**
   * Start action (with wait flag)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param needWait Whether to wait
   */
  public startActionWithWait(actionName: string, actionType: string, needWait: boolean): void {
    if (this.innerManager) {
      this.innerManager.startAction(actionName, actionType, needWait);
    }
  }

  /**
   * Start action (full parameters)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param needWait Whether to wait
   * @param property Extended properties
   */
  public startActionFull(actionName: string, actionType: string, needWait: boolean, property: Record<string, object>): void {
    if (this.innerManager) {
      this.innerManager.startAction(actionName, actionType, needWait, property);
    }
  }

  /**
   * Add action (directly completed)
   * This type of data cannot be associated with Error, Resource, LongTask data
   * If you need to call actions frequently, use addAction instead of startAction
   * 
   * @param actionName Action name
   * @param actionType Action type
   */
  public addAction(actionName: string, actionType: string): void {
    if (this.innerManager) {
      const currentTime = Utils.getCurrentNanoTime();
      this.innerManager.addAction(actionName, actionType, 0, currentTime);
    }
  }

  /**
   * Add action (with duration)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param duration Duration (nanoseconds)
   */
  public addActionWithDuration(actionName: string, actionType: string, duration: number): void {
    if (this.innerManager) {
      const currentTime = Utils.getCurrentNanoTime();
      this.innerManager.addAction(actionName, actionType, duration, currentTime);
    }
  }

  /**
   * Add action (with properties)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param property Extended properties
   */
  public addActionWithProperty(actionName: string, actionType: string, property: Record<string, object>): void {
    if (this.innerManager) {
      const currentTime = Utils.getCurrentNanoTime();
      this.innerManager.addAction(actionName, actionType, 0, currentTime, property);
    }
  }

  /**
   * Add action (full parameters)
   * 
   * @param actionName Action name
   * @param actionType Action type
   * @param duration Duration (nanoseconds)
   * @param property Extended properties
   */
  public addActionFull(actionName: string, actionType: string, duration: number, property: Record<string, object>): void {
    if (this.innerManager) {
      const currentTime = Utils.getCurrentNanoTime();
      this.innerManager.addAction(actionName, actionType, duration, currentTime, property);
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
   * Stop action
   * 
   * Stop the currently active action
   */
  public stopAction(): void {
    FTInnerLogger.d(TAG, "<FT-ACTION-TEST> GlobalManager.stopAction called");
    if (this.innerManager) {
      this.innerManager.stopAction();
    } else {
      FTInnerLogger.e(TAG, "<FT-ACTION-TEST> innerManager is null, cannot stop action");
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

    FTInnerLogger.d(TAG, ` addCustomError called: message=${errorMessage}, hasStack=${!!errorStack}, hasProperty=${Object.keys(property).length > 0}`);
    
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
    FTInnerLogger.d(TAG, ` addCustomError completed: ${errorMessage}`);
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
  public stopResource(resourceId: string, statusCode: number, contentLength: number): void {
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
      // Create parameter copy to avoid modifying original object
      const resourceParams = new ResourceParams();
      resourceParams.setUrl(params.url);
      resourceParams.setRequestHeader(params.requestHeader);
      resourceParams.setResponseHeader(params.responseHeader);
      resourceParams.setRequestHeaderMap(params.requestHeaderMap);
      resourceParams.setResponseHeaderMap(params.responseHeaderMap);
      resourceParams.setResponseConnection(params.responseConnection);
      resourceParams.setResponseContentType(params.responseContentType);
      resourceParams.setResponseContentEncoding(params.responseContentEncoding);
      resourceParams.setResponseContentLength(params.responseContentLength);
      resourceParams.setResourceMethod(params.resourceMethod);
      resourceParams.setResponseBody(params.responseBody);
      resourceParams.setResourceStatus(params.resourceStatus);
      resourceParams.setRequestErrorStack(params.requestErrorStack);
      resourceParams.setRequestErrorMsg(params.requestErrorMsg);
      resourceParams.setProperty(params.property);
      
      // Process request headers
      if (!resourceParams.requestHeader && resourceParams.requestHeaderMap.size > 0) {
        resourceParams.requestHeader = this.convertHeadersToString(resourceParams.requestHeaderMap);
      }
      
      // Process response headers
      if (!resourceParams.responseHeader && resourceParams.responseHeaderMap.size > 0) {
        resourceParams.responseHeader = this.convertHeadersToString(resourceParams.responseHeaderMap);
      }
      
      // Process response content length
      if (resourceParams.responseContentLength <= 0) {
        if (resourceParams.responseBody) {
          resourceParams.responseContentLength = resourceParams.responseBody.length + resourceParams.responseHeader.length;
        } else {
          resourceParams.responseContentLength = resourceParams.responseHeader.length;
        }
      }
      
      this.innerManager.addResource(resourceId, resourceParams, netStatusBean);
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
      FTInnerLogger.d(TAG, ` addLongTask called: log=${log}, duration=${duration}ns, hasProperty=${Object.keys(property).length > 0}`);
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
