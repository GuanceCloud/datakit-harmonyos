import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { FTRUMConfig } from '../Configs';
import FTTrackInner from '../FTTrackInner';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { FTInnerLogger } from '../log/FTLogger';
import { DataType } from '../enum/Enums';
import { CollectType } from '../rum/enum/RUMEnums';
import { JsReceiver } from './WebAppInterface';
import { Utils } from '../utils/Utils';
import { Constants } from '../Constants';

const TAG = "FTWebViewHandler";

/**
 * JavaScriptProxy interface for HarmonyOS WebView
 * Used by .javaScriptProxy() decorator to register JavaScript-to-Native bridge
 */
interface JavaScriptProxy {
  object: object;
  name: string;
  methodList: string[];
  controller: webview.WebviewController;
}

/**
 * Used to receive application-level webview data indicators
 * Requires use of web js sdk
 * <a href="https://github.com/GuanceCloud/datakit-js">datakit-js</a>,
 * See Demo in entry/src/main/resources/rawfile/local_sample.html
 * 
 * Based on Android SDK's FTWebViewHandler.java
 * 
 * HarmonyOS Implementation:
 * Uses registerJavaScriptProxy() to register a message receiver class,
 * allowing JavaScript to directly call native methods without polling.
 */

/**
 * Class to receive messages from WebView JavaScript
 * Registered via registerJavaScriptProxy() for direct method calls
 */
class WebViewMessageReceiver implements JsReceiver {
  private handler: FTWebViewHandler;

  constructor(handler: FTWebViewHandler) {
    this.handler = handler;
  }

  /**
   * Send event to native without callback
   * Called directly from JavaScript via registered proxy
   */
  sendEvent(event: string): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== sendEvent() called via proxy ==========`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] 📥 Received data from WebView (via proxy)`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Event data length: ${event ? event.length : 0}`);
    // FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Event data (full): ${event}`);
    try {
      const parsed = JSON.parse(event) as Record<string, string | number | boolean | object | null>;
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Event data (parsed): ${JSON.stringify(parsed, null, 2)}`);
    } catch (e) {
      FTInnerLogger.w(TAG, `[WEBVIEW-DEBUG] Event data is not valid JSON, raw: ${event}`);
    }
    this.handler.handleWebViewData(event);
  }

  /**
   * Send event to native with callback method
   * Called directly from JavaScript via registered proxy
   */
  sendEventWithCallback(event: string, callbackMethod: string): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== sendEventWithCallback() called via proxy ==========`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Event data length: ${event ? event.length : 0}, callback: ${callbackMethod}`);
    this.handler.sendEventWithCallback(event, callbackMethod);
  }

  /**
   * Add event listener for Web events
   * Currently not used but required by interface
   */
  addEventListener(event: string, callbackMethod: string): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] addEventListener called: event=${event}, callback=${callbackMethod}`);
    // Not implemented yet
  }

  /**
   * Get allowed webview hosts
   * Required by browser-sdk to detect if bridge is available
   * Returns null to allow all hosts (browser-sdk expects null or undefined to enable bridge)
   */
  getAllowedWebViewHosts(): string | null {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] getAllowedWebViewHosts() called - returning null to allow all hosts`);
    return this.handler.getAllowedWebViewHosts();
  }
}

/**
 * Callback status, true is normal, false is abnormal
 */
export const WEB_JS_STATUS = "status";

/**
 * Used to mark the callback tag, the value is time ms
 */
export const WEB_JS_INNER_TAG = "_tag";

/**
 * RUM data
 */
export const WEB_JS_TYPE_RUM = "rum";

/**
 * Indicator type transmission
 */
export const WEB_JS_TYPE_TRACK = "track";

/**
 * Log type data
 */
export const WEB_JS_TYPE_LOG = "log";

/**
 * url verification, used to verify that the address belongs to the whitelist
 */
export const WEB_JS_TYPE_URL_VERIFY = "urlVerify";

/**
 * Pass method name
 */
export const WEB_JS_NAME = "name";

/**
 * Method parameters
 */
export const WEB_JS_DATA = "data";

export class FTWebViewHandler implements JsReceiver {
  private webController: webview.WebviewController | null = null;
  private nativeViewName: string = "";
  private messageReceiver: WebViewMessageReceiver | null = null;
  private readonly PROXY_OBJECT_NAME = "FTWebViewJavascriptBridge";
  private allowWebViewHost: string[] | null = null;
  // Static Set to track processed webview action IDs to prevent duplicate processing across all instances
  // This ensures that even if the same action is received multiple times, it will only be processed once
  // Note: WebView view data deduplication is not needed - WebView may send duplicate views intentionally
  // HarmonyOS SDK should forward all view data from WebView as-is

  constructor() {
    // Empty constructor
  }
  
  /**
   * Get allowed webview hosts
   * Returns null to allow all hosts (browser-sdk expects null or undefined to enable bridge)
   */
  public getAllowedWebViewHosts(): string | null {
    if (this.allowWebViewHost === null || this.allowWebViewHost.length === 0) {
      return null;
    }
    return JSON.stringify(this.allowWebViewHost);
  }
  
  /**
   * Get message receiver instance
   * Used for javaScriptProxy decorator if needed
   */
  public getMessageReceiver(): WebViewMessageReceiver {
    if (!this.messageReceiver) {
      this.messageReceiver = new WebViewMessageReceiver(this);
    }
    return this.messageReceiver;
  }

  /**
   * Get JavaScript proxy for WebView component
   * Used by WebViewPage to register proxy via .javaScriptProxy() decorator
   * @param webController WebView controller
   * @returns JavaScriptProxy object with object, name, methodList, and controller
   */
  public getJavaScriptProxy(webController: webview.WebviewController): JavaScriptProxy {
    // Initialize handler if not already done
    if (!this.webController) {
      this.webController = webController;
    }
    // Get or create message receiver instance
    const receiver = this.getMessageReceiver();
    
    // Return JavaScriptProxy object (aligned with HarmonyOS WebView API)
    const proxy: JavaScriptProxy = {
      object: receiver,
      name: this.PROXY_OBJECT_NAME,
      methodList: ["sendEvent", "sendEventWithCallback", "getAllowedWebViewHosts"],
      controller: webController
    };
    return proxy;
  }

  /**
   * Register JS method in web view
   */
  public setWebView(webController: webview.WebviewController, config: FTRUMConfig): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== setWebView() called ==========`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] WebController parameter: ${webController ? 'valid' : 'null'}`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Current webController: ${this.webController ? 'exists' : 'null'}`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Config enableTraceWebView: ${config ? 'configured' : 'null'}`);
    
    if (!webController) {
      FTInnerLogger.e(TAG, `[WEBVIEW-DEBUG] ❌ WebController parameter is null, cannot set`);
      return;
    }
    
    // Check if WebView tracking is enabled (aligned with Android: FTWebViewHandler.setWebView)
    // Android logic: if (config.isRumEnable() && config.isEnableTraceWebView())
    if (!config || !config.isEnableTraceWebView()) {
      FTInnerLogger.i(TAG, `[WEBVIEW-DEBUG] WebView tracking is disabled in RUM config, skip WebView setup`);
      return;
    }
    
    // If we already have a controller and it's different, clear the old one
    if (this.webController && this.webController !== webController) {
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Replacing existing WebController`);
    }
    
    this.webController = webController;
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] WebController assigned successfully`);
    
    // Keep the remote/local RUM allow-list available to the browser SDK bridge.
    this.allowWebViewHost = config.getAllowWebViewHost();
    
    // Register JavaScript proxy early (before page loads) so browser-sdk can detect it
    // This is similar to Android's addJavascriptInterface which is available immediately
    this.registerJavaScriptProxy();
    
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== setWebView() completed ==========`);
  }

  /**
   * Clear WebController reference
   * Called when page is about to disappear or WebView is destroyed
   */
  public clearWebController(): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== clearWebController() called ==========`);
    
    // Unregister JavaScript proxy before clearing controller
    if (this.webController && this.messageReceiver) {
      try {
        this.webController.deleteJavaScriptRegister(this.PROXY_OBJECT_NAME);
        FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] JavaScript proxy unregistered`);
      } catch (error) {
        FTInnerLogger.w(TAG, `[WEBVIEW-DEBUG] Error unregistering proxy: ${error}`);
      }
    }
    
    this.webController = null;
    this.messageReceiver = null;
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] WebController cleared`);
  }

  /**
   * Register JavaScript proxy for direct method calls from Web to Native
   * This should be called before page loads (similar to Android's addJavascriptInterface)
   */
  private registerJavaScriptProxy(): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== registerJavaScriptProxy() called ==========`);
    
    if (!this.webController) {
      FTInnerLogger.e(TAG, `[WEBVIEW-DEBUG] ❌ WebController is null, cannot register proxy`);
      return;
    }
    
    try {
      if (!this.messageReceiver) {
        this.messageReceiver = new WebViewMessageReceiver(this);
      }
      
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Registering JavaScript proxy: ${this.PROXY_OBJECT_NAME}`);
      this.webController.registerJavaScriptProxy(
        this.messageReceiver,
        this.PROXY_OBJECT_NAME,
        ["sendEvent", "sendEventWithCallback", "getAllowedWebViewHosts"],
        []
      );
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ✅ JavaScript proxy registered successfully`);
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Proxy will be available as window.${this.PROXY_OBJECT_NAME}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `[WEBVIEW-DEBUG] ❌ Error registering JavaScript proxy: ${error}`);
    }
    
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== registerJavaScriptProxy() completed ==========`);
  }

  /**
   * Send event from Web to Native
   */
  public sendEvent(event: string): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] sendEvent() called without callback`);
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Event string length: ${event ? event.length : 0}`);
    this.sendEventWithCallback(event, null);
  }

  /**
   * datakit-js in webview called channel method, processing datakit business logic related
   */
  public sendEventWithCallback(event: string, callbackMethod: string | null): void {
    try {
      // Parse JSON event
      const eventObj = JSON.parse(event) as Record<string, string | Record<string, string | object>>;
      
      // Get properties using safe access (ArkTS doesn't support indexed access)
      let name: string = "";
      let dataJson: Record<string, string | object> | null = null;
      let tag: string = "";
      
      // Access properties by iterating through keys
      // ArkTS doesn't support indexed access, so we need to use JSON.parse/stringify or direct property access
      // Since we know the expected structure, we can use type assertion and direct access
      const nameValue = eventObj.name;
      const dataValue = eventObj.data;
      const tagValue = eventObj._tag;
      
      if (nameValue && typeof nameValue === 'string') {
        name = nameValue;
      }
      if (dataValue && typeof dataValue === 'object') {
        dataJson = dataValue as Record<string, string | object>;
      }
      if (tagValue && typeof tagValue === 'string') {
        tag = tagValue;
      }

      if (name === WEB_JS_TYPE_RUM) {
        if (dataJson !== null && dataJson !== undefined) {
          // Extract tags and fields from data
          // ArkTS doesn't support indexed access, so we need to get properties differently
          let jsonTags: Record<string, string> = {};
          let jsonFields: Record<string, string | object> = {};
          let measurement: string = 'webview';
          let timeValue: number | undefined = undefined;
          
          // Get all properties from dataJson using direct property access (ArkTS doesn't support indexed access)
          const tagsValue = dataJson.tags;
          const fieldsValue = dataJson.fields;
          const measurementValue = dataJson.measurement;
          const timeValueFromData = dataJson.time;
          
          if (tagsValue && typeof tagsValue === 'object') {
            jsonTags = tagsValue as Record<string, string>;
          }
          if (fieldsValue && typeof fieldsValue === 'object') {
            jsonFields = fieldsValue as Record<string, string | object>;
          }
          if (measurementValue && typeof measurementValue === 'string') {
            measurement = measurementValue;
          }
          if (timeValueFromData && typeof timeValueFromData === 'number') {
            timeValue = timeValueFromData;
          }

          // Convert to Map
          const tagsMap = new Map<string, string>();
          const fieldsMap = new Map<string, string>();

          // Helper function to extract value from JSON string by key
          // This avoids indexed access by parsing JSON string manually
          const extractValueFromJson = (jsonStr: string, key: string): string | null => {
            const keyPattern = `"${key}"`;
            const keyIndex = jsonStr.indexOf(keyPattern);
            if (keyIndex < 0) {
              return null;
            }
            const colonIndex = jsonStr.indexOf(':', keyIndex);
            if (colonIndex < 0) {
              return null;
            }
            let valueStart = colonIndex + 1;
            // Skip whitespace
            while (valueStart < jsonStr.length && (jsonStr.charAt(valueStart) === ' ' || jsonStr.charAt(valueStart) === '\t')) {
              valueStart++;
            }
            // Find value end (comma or closing brace)
            let valueEnd = valueStart;
            if (jsonStr.charAt(valueStart) === '"') {
              // String value - find closing quote
              valueEnd = jsonStr.indexOf('"', valueStart + 1);
              if (valueEnd >= 0) {
                valueEnd++;
              }
            } else if (jsonStr.charAt(valueStart) === '{' || jsonStr.charAt(valueStart) === '[') {
              // Object or array - find matching closing brace/bracket
              let depth = 1;
              valueEnd = valueStart + 1;
              const openChar = jsonStr.charAt(valueStart);
              const closeChar = openChar === '{' ? '}' : ']';
              while (valueEnd < jsonStr.length && depth > 0) {
                if (jsonStr.charAt(valueEnd) === openChar) {
                  depth++;
                } else if (jsonStr.charAt(valueEnd) === closeChar) {
                  depth--;
                }
                valueEnd++;
              }
            } else {
              // Number, boolean, null - find comma or closing brace
              valueEnd = jsonStr.indexOf(',', valueStart);
              if (valueEnd < 0) {
                valueEnd = jsonStr.indexOf('}', valueStart);
              }
              if (valueEnd < 0) {
                valueEnd = jsonStr.length;
              }
            }
            if (valueEnd > valueStart) {
              return jsonStr.substring(valueStart, valueEnd);
            }
            return null;
          };

          // Convert jsonTags to Map using JSON string parsing
          const tagKeyList = Object.keys(jsonTags);
          const tagsJsonStr = JSON.stringify(jsonTags);
          for (let idx = 0; idx < tagKeyList.length; idx++) {
            const currentKey = tagKeyList[idx];
            const valueStr = extractValueFromJson(tagsJsonStr, currentKey);
            if (valueStr !== null) {
              // Remove quotes if present
              const cleanValue = valueStr.startsWith('"') && valueStr.endsWith('"') 
                ? valueStr.substring(1, valueStr.length - 1) 
                : valueStr;
              tagsMap.set(currentKey, cleanValue);
              // Debug: log sdk_version from webview
              if (currentKey === Constants.KEY_SDK_VERSION) {
                FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Web SDK version from webview tags: "${cleanValue}"`);
              }
            }
          }

          // Same for jsonFields - directly access values from object to properly handle escaped characters
          // Since jsonFields is already a parsed object, we can use JSON.stringify on individual values
          const fieldKeyList = Object.keys(jsonFields);
          for (let idx = 0; idx < fieldKeyList.length; idx++) {
            const currentKey = fieldKeyList[idx];
            // Use JSON.stringify on the entire object, then extract the value for this key
            // This properly handles escaped characters in nested objects
            const fieldsJsonStr = JSON.stringify(jsonFields);
            // Find the key in the JSON string and extract its value
            const keyPattern = `"${currentKey}"`;
            const keyIndex = fieldsJsonStr.indexOf(keyPattern);
            if (keyIndex >= 0) {
              const colonIndex = fieldsJsonStr.indexOf(':', keyIndex);
              if (colonIndex >= 0) {
                let valueStart = colonIndex + 1;
                // Skip whitespace
                while (valueStart < fieldsJsonStr.length && (fieldsJsonStr.charAt(valueStart) === ' ' || fieldsJsonStr.charAt(valueStart) === '\t')) {
                  valueStart++;
                }
                // Extract the value - handle objects, arrays, strings, numbers, booleans, null
                let valueStr: string | null = null;
                if (valueStart < fieldsJsonStr.length) {
                  const firstChar = fieldsJsonStr.charAt(valueStart);
                  if (firstChar === '"') {
                    // String value - find the closing quote, handling escaped quotes
                    let valueEnd = valueStart + 1;
                    while (valueEnd < fieldsJsonStr.length) {
                      if (fieldsJsonStr.charAt(valueEnd) === '"' && fieldsJsonStr.charAt(valueEnd - 1) !== '\\') {
                        valueEnd++;
                        break;
                      }
                      valueEnd++;
                    }
                    if (valueEnd > valueStart) {
                      valueStr = fieldsJsonStr.substring(valueStart, valueEnd);
                    }
                  } else if (firstChar === '{' || firstChar === '[') {
                    // Object or array - find matching closing brace/bracket
                    let depth = 1;
                    let valueEnd = valueStart + 1;
                    const openChar = firstChar;
                    const closeChar = openChar === '{' ? '}' : ']';
                    while (valueEnd < fieldsJsonStr.length && depth > 0) {
                      const char = fieldsJsonStr.charAt(valueEnd);
                      if (char === openChar) {
                        depth++;
                      } else if (char === closeChar) {
                        depth--;
                      }
                      valueEnd++;
                    }
                    if (valueEnd > valueStart) {
                      valueStr = fieldsJsonStr.substring(valueStart, valueEnd);
                    }
                  } else {
                    // Number, boolean, null - find comma or closing brace
                    let valueEnd = fieldsJsonStr.indexOf(',', valueStart);
                    if (valueEnd < 0) {
                      valueEnd = fieldsJsonStr.indexOf('}', valueStart);
                    }
                    if (valueEnd < 0) {
                      valueEnd = fieldsJsonStr.length;
                    }
                    if (valueEnd > valueStart) {
                      valueStr = fieldsJsonStr.substring(valueStart, valueEnd).trim();
                    }
                  }
                }
                if (valueStr !== null) {
                  fieldsMap.set(currentKey, valueStr);
                }
              }
            }
          }

          // Add session_id
          const sessionId = FTRUMInnerManager.getInstance().getSessionId();
          if (sessionId) {
            tagsMap.set('session_id', sessionId);
          }

          // Add webview flag (aligned with Android: KEY_RUM_VIEW_IS_WEB_VIEW = "is_web_view")
          tagsMap.set(Constants.KEY_RUM_VIEW_IS_WEB_VIEW, 'true');

          // Aligned with Android: set is_active=false for view measurement
          if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
            fieldsMap.set('is_active', 'false');
          }

          // Aligned with Android: add the native host view as referrer when the
          // Browser SDK has not provided one.
          const referrerValue = tagsMap.get(Constants.KEY_RUM_VIEW_REFERRER);
          if (!referrerValue || referrerValue.length === 0) {
            const nativeViewName = this.resolveNativeViewName();
            if (nativeViewName && nativeViewName.length > 0) {
              tagsMap.set(Constants.KEY_RUM_VIEW_REFERRER, nativeViewName);
            }
          }

          // Aligned with Android: merge all dynamic RUM tags at the bridge.
          // Do not reserve service or sdk_version here: Android applies an
          // identically named dynamic tag before the final native RUM tags are
          // added by SyncDataHelper.
          const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
          const dynamicTagKeys = Object.keys(dynamicTags);
          for (let i = 0; i < dynamicTagKeys.length; i++) {
            const key = dynamicTagKeys[i];
            const value = dynamicTags[key];
            if (value !== undefined && value !== null) {
              tagsMap.set(key, String(value));
            }
          }
          
          // Use measurement and timeValue extracted above
          // If timeValue is provided (from Web SDK), use it; otherwise use current nanosecond timestamp
          const time = timeValue !== undefined ? timeValue * 1000000 : Utils.getCurrentNanoTime();

          // Get collect type
          const sessionIdValue = FTRUMInnerManager.getInstance().getSessionId();
          const collectType = sessionIdValue ? CollectType.ALL : CollectType.DROP;

          // Browser Resource and Error points arrive separately. Assign the
          // Resource UUID before crossing the Worker boundary so its
          // resource_id and the unprefixed Resource sdk_data_id UUID are the
          // same value. The first upload adds the package prefix only to
          // sdk_data_id; retry keeps that established value unchanged.
          const resourceDraftUuid = measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE ?
            Utils.generateUUID() : undefined;
          if (resourceDraftUuid) {
            tagsMap.set(Constants.KEY_RUM_RESOURCE_ID, resourceDraftUuid);
          }

          // Action-ID de-duplication now runs in EVENT_CONSUMER. Browser view
          // records remain intentionally non-deduplicated to match Android.

          // Call FTTrackInner to sync RUM data
          FTTrackInner.getInstance().rumWebView(
            time,
            measurement,
            tagsMap,
            fieldsMap,
            collectType,
            resourceDraftUuid
          );
        }

      } else if (name === WEB_JS_TYPE_TRACK) {
        // Not used in current implementation
        FTInnerLogger.d(TAG, "TRACK data received from WebView");
      } else if (name === WEB_JS_TYPE_LOG) {
        // Not used in current implementation
        FTInnerLogger.d(TAG, "LOG data received from WebView");
      } else if (name === WEB_JS_TYPE_URL_VERIFY) {
        // Not used in current implementation
        FTInnerLogger.d(TAG, "URL_VERIFY received from WebView");
      } else {
        // Unknown event type
        FTInnerLogger.w(TAG, `[WEBVIEW-WARNING] ⚠️ Received unknown event type: ${name}`);
        FTInnerLogger.w(TAG, `[WEBVIEW-WARNING] Expected event types: "rum", "track", "log", "url_verify"`);
        FTInnerLogger.w(TAG, `[WEBVIEW-WARNING] This event will not be processed. Please check browser-sdk configuration.`);
      }

      // Handle callback if needed
      if (callbackMethod && callbackMethod.length > 0 && this.webController) {
        FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Executing callback to Web...`);
        FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Callback method: ${callbackMethod}, tag: ${tag}`);
        // Create object with status property (can't use indexed access in ArkTS)
        // Define interface for callback return object
        interface CallbackReturnStatus {
          status: boolean;
        }
        const retObj: CallbackReturnStatus = { status: true };
        const retJson = JSON.stringify(retObj);
        FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Callback return JSON: ${retJson}`);
        this.callbackFromNative(tag, callbackMethod, retJson, "{}");
      } else {
        FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] No callback needed or WebController unavailable`);
      }

      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] ========== sendEventWithCallback() END ==========`);

    } catch (error) {
      FTInnerLogger.e(TAG, `[WEBVIEW-DEBUG] ❌ Error handling WebView event: ${error}`);
      FTInnerLogger.e(TAG, `[WEBVIEW-DEBUG] Error details: ${JSON.stringify(error)}`);
      FTInnerLogger.e(TAG, `Error handling WebView event: ${error}`);
    }
  }

  /**
   * Add event listener
   */
  public addEventListener(event: string, callbackMethod: string): void {
    try {
      FTInnerLogger.d(TAG, `addEventListener: event=${event}, callback=${callbackMethod}`);
      
      const retJson = "{}";
      const errJson = "{}";
      const tag = Date.now().toString();
      
      this.callbackFromNative(tag, callbackMethod, retJson, errJson);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error handling event listener: ${error}`);
    }
  }

  /**
   * Handle data from WebView
   * Called from WebViewPage via onReceiveData (legacy polling method)
   */
  public handleWebViewData(data: string): void {
    FTInnerLogger.d(TAG, ` ========== handleWebViewData() called ==========`);
    FTInnerLogger.d(TAG, ` Data length: ${data ? data.length : 0},Raw data (full): ${data}`);
    try {
      FTInnerLogger.d(TAG, ` ========== Receiving data from WebView ==========`);
      FTInnerLogger.d(TAG, ` Raw data: ${data}`);
      
      // Parse and print detailed data structure
      const parsedData = JSON.parse(data) as Record<string, string>;
      const parsedKeys = Object.keys(parsedData);
      FTInnerLogger.d(TAG, ` 📋 Parsed data structure: Keys: ${parsedKeys.join(', ')}`);

      // Iterate through keys to access values (ArkTS doesn't support indexed access)
      let callbackMethod: string | null = null;
      let eventData: string | null = null;
      
      for (let i = 0; i < parsedKeys.length; i++) {
        const key = parsedKeys[i];
        const value = parsedData[key];
        if (value) {
          if (value.length > 200) {
            FTInnerLogger.d(TAG, `   ${key}: ${value.substring(0, 200)}... (length: ${value.length})`);
          } else {
            FTInnerLogger.d(TAG, `   ${key}: ${value}`);
          }
          
          if (key === "callbackMethod") {
            callbackMethod = value;
          } else if (key === "event") {
            eventData = value;
          }
        }
      }
      
      FTInnerLogger.d(TAG, ` Parsed data keys: ${parsedKeys.join(', ')}`);
      
      if (callbackMethod) {
        // Handle callback format
        FTInnerLogger.d(TAG, ` Callback method: ${callbackMethod}, Event data: ${eventData || 'null'}`);
        if (eventData) {
          this.sendEventWithCallback(eventData, callbackMethod);
        }
      } else {
        // Handle regular event format
        FTInnerLogger.d(TAG, ` Regular event format`);
        this.sendEvent(data);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, ` Error handling WebView data: ${error}`);
    }
  }

  /**
   * Call webview page js method using runJavaScript
   * This is used for callback execution
   */
  private callbackFromNative(requestTag: string, callBackMethod: string, retJsonString: string, errJsonString: string): void {
    FTInnerLogger.d(TAG, ` ========== callbackFromNative() called ==========`);
    FTInnerLogger.d(TAG, ` Callback method: ${callBackMethod}, Request tag: ${requestTag}`);

    if (!this.webController) {
      FTInnerLogger.w(TAG, ` ⚠️ WebController is null, cannot execute callback`);
      return;
    }

    const separator = retJsonString.length > 0 && errJsonString.length > 0 ? "," : "";
    const jsStr = `${callBackMethod}["${requestTag}"](${retJsonString}${separator}${errJsonString})`;
    
    FTInnerLogger.d(TAG, ` Executing JavaScript callback...`);

    this.webController.runJavaScript(jsStr, (err?: BusinessError<void>) => {
      if (err) {
        FTInnerLogger.e(TAG, ` ❌ Failed to execute callback: ${callBackMethod}, error: ${err.message}`);
        
        // If error is about controller not associated, clear the controller
        const errorMsg = err.message || '';
        if (errorMsg.includes("associated") || errorMsg.includes("Init error")) {
          FTInnerLogger.w(TAG, ` ⚠️ WebController not associated, clearing reference`);
          this.webController = null;
        }
      } else {
        FTInnerLogger.d(TAG, ` ✅ Callback executed successfully: ${callBackMethod}`);
      }
      FTInnerLogger.d(TAG, ` ========== callbackFromNative() completed ==========`);
    });
  }

  /**
   * Send message from Native to Web using runJavaScript
   * HarmonyOS WebView may not support postMessage API with single parameter
   */
  public postMessageToWeb(message: string): void {
    FTInnerLogger.d(TAG, ` ========== postMessageToWeb() called ==========`);
    FTInnerLogger.d(TAG, ` Message length: ${message ? message.length : 0}`);
    
    if (!this.webController) {
      FTInnerLogger.w(TAG, ` ❌ WebController is null, cannot post message`);
      return;
    }

    try {
      FTInnerLogger.d(TAG, ` Posting message to Web via runJavaScript...`);
      FTInnerLogger.d(TAG, ` Message content: ${message.substring(0, 200)}...`);
      
      // Use runJavaScript to send message to Web
      // Inject message into a global variable that Web can read
      const jsCode = `
        if (window.nativeMessageHandler && typeof window.nativeMessageHandler === 'function') {
          window.nativeMessageHandler(${JSON.stringify(message)});
        } else {
          // nativeMessageHandler not found - this is expected if WebView hasn't registered the handler yet
        }
      `;
      
      this.webController.runJavaScript(jsCode, (err?: BusinessError<void>) => {
        if (err) {
          FTInnerLogger.e(TAG, ` ❌ Error posting message to Web: ${err.message}`);
        } else {
          FTInnerLogger.d(TAG, ` ✅ Message posted to Web successfully`);
          FTInnerLogger.d(TAG, `Message posted to Web: ${message.substring(0, 100)}...`);
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, ` ❌ Error posting message to Web: ${error}`);
    }
    FTInnerLogger.d(TAG, ` ========== postMessageToWeb() completed ==========`);
  }

  /**
   * Get native view name for referrer
   */
  public getNativeViewName(): string {
    return this.nativeViewName;
  }

  /**
   * Android obtains the host Activity name when a WebView is bound. ArkUI does
   * not expose an Activity from WebviewController, so resolve the currently
   * tracked native View at event time. An explicit setNativeViewName() keeps
   * priority for applications that use a custom host name.
   */
  private resolveNativeViewName(): string {
    if (this.nativeViewName && this.nativeViewName.length > 0) {
      return this.nativeViewName;
    }
    const activeView = FTRUMInnerManager.getInstance().getActiveView();
    return activeView ? activeView.getViewName() : '';
  }

  /**
   * Set native view name
   */
  public setNativeViewName(viewName: string): void {
    this.nativeViewName = viewName;
  }
}
