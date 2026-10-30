import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import FTTrackInner from '../FTTrackInner';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { FTInnerLogger } from '../log/FTLogger';
import { FTLogSeparator } from '../log/FTLogSeparator';
import { DataType } from '../enum/Enums';
import { CollectType } from '../rum/enum/RUMEnums';
import { JsReceiver } from './WebAppInterface';
import { Utils } from '../utils/Utils';
import { Constants } from '../Constants';
import { FTSessionReplayBridgeRegistry } from '../sessionreplay/FTSessionReplayBridge';
import { FTWebViewReplayBridge } from './FTWebViewReplayBridge';
import { FTWebViewHostPolicy, isWebViewHostAllowed, serializeWebViewHosts } from './FTWebViewHostPolicy';
import { TrackLogManager } from '../log/TrackLogManager';
import { mapWebViewLogEvent } from './FTWebViewLogEventMapper';

const TAG = "FTWebViewHandler";

interface WebReplayContainerTag { source: string; view_id: string; }

interface WebViewIgnoredEventLog {
  lastEmittedAt: number;
  suppressed: number;
  slotId: string;
}

interface WebReplayViewportResizeData {
  source: number;
  width: number;
  height: number;
}

interface WebReplayVisualViewportData {
  scale: number;
  offsetLeft: number;
  offsetTop: number;
  pageLeft: number;
  pageTop: number;
  width: number;
  height: number;
}

interface WebReplayViewportResizeRecord {
  timestamp: number;
  type: number;
  data: WebReplayViewportResizeData | WebReplayVisualViewportData;
}

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
  private readonly generation: number;

  constructor(handler: FTWebViewHandler) {
    this.handler = handler;
    this.generation = handler.getProxyGeneration();
  }

  /**
   * Send event to native without callback
   * Called directly from JavaScript via registered proxy
   */
  sendEvent(event: string): void {
    if (!this.handler.isCurrentProxy(this.generation)) return;
    this.handler.handleWebViewData(event);
  }

  /**
   * Send event to native with callback method
   * Called directly from JavaScript via registered proxy
   */
  sendEventWithCallback(event: string, callbackMethod: string): void {
    if (!this.handler.isCurrentProxy(this.generation)) return;
    this.handler.sendEventWithCallback(event, callbackMethod);
  }

  /**
   * Add event listener for Web events
   * Currently not used but required by interface
   */
  addEventListener(event: string, callbackMethod: string): void {
    // Not implemented yet
  }

  /**
   * Get allowed webview hosts
   * Required by browser-sdk to detect if bridge is available
   * Returns the configured host allow-list, or null when no restriction is configured.
   */
  getAllowedWebViewHosts(): string | null {
    if (!this.handler.isCurrentProxy(this.generation)) return '[]';
    return this.handler.getAllowedWebViewHosts();
  }

  /** Android-compatible Browser SDK privacy negotiation for Session Replay. */
  getPrivacyLevel(): string | null {
    if (!this.handler.isCurrentProxy(this.generation)) return null;
    return this.handler.getSessionReplayPrivacyLevel();
  }

  /** Android-compatible Browser SDK capability negotiation for Session Replay. */
  getCapabilities(): string | null {
    if (!this.handler.isCurrentProxy(this.generation)) return null;
    return this.handler.getSessionReplayCapabilities();
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

/** Browser SDK Session Replay record. */
export const WEB_JS_TYPE_SESSION_REPLAY = "session_replay";

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
  private static readonly SESSION_REPLAY_SNAPSHOT_INTERVAL_MS: number = 10_000;
  private static readonly IGNORED_EVENT_LOG_INTERVAL_MS: number = 5_000;
  private webController: webview.WebviewController | null = null;
  private nativeViewName: string = "";
  private messageReceiver: WebViewMessageReceiver | null = null;
  private readonly PROXY_OBJECT_NAME = "FTWebViewJavascriptBridge";
  private proxyGeneration: number = 0;
  private sessionReplayComponentId: string = '';
  private sessionReplayComponentRegistered: boolean = false;
  private sessionReplayBindingKey: string = '';
  private sessionReplayViewportKey: string = '';
  private sessionReplayBrowserViewId: string = '';
  private sessionReplayHasBrowserRecords: boolean = false;
  private sessionReplayVisualViewport: WebReplayVisualViewportData | null = null;
  private allowWebViewHost: string[] | null = null;
  private hostPolicyBound: boolean = false;
  private webViewId: string = '';
  private webReplayLinkContext: Record<string, string | number | boolean> = {};
  private readonly webReplayContexts: Map<string, Record<string, string | number | boolean>> = new Map();
  private sessionReplaySnapshotTimer: number = -1;
  private sessionReplaySlotActive: boolean = false;
  private lastWebSdkVersion: string = '';
  private readonly ignoredEventLogs: Map<string, WebViewIgnoredEventLog> = new Map();
  private readonly sessionReplaySlotListener: () => void;
  // Static Set to track processed webview action IDs to prevent duplicate processing across all instances
  // This ensures that even if the same action is received multiple times, it will only be processed once
  // Note: WebView view data deduplication is not needed - WebView may send duplicate views intentionally
  // HarmonyOS SDK should forward all view data from WebView as-is

  constructor() {
    // The core registry must not keep a stopped page alive through a rebind callback.
    const owner = new WeakRef<FTWebViewHandler>(this);
    this.sessionReplaySlotListener = (): void => {
      const handler = owner.deref();
      if (handler !== undefined) {
        handler.refreshSessionReplaySnapshotTimer();
        handler.notifySessionReplayWebContextChanged();
        handler.refreshSessionReplayBinding();
      }
    };
  }
  
  /**
   * Get allowed webview hosts
   * Returns null to allow all hosts (browser-sdk expects null or undefined to enable bridge)
   */
  public getAllowedWebViewHosts(): string | null {
    return serializeWebViewHosts(this.getBoundHosts(), this.getDocumentUrl());
  }

  private getBoundHosts(): string[] | null {
    if (this.hostPolicyBound) return this.allowWebViewHost;
    const legacy = FTRUMConfigManager.getInstance().getConfig()?.getAllowWebViewHost() ?? null;
    return FTWebViewHostPolicy.resolve(legacy);
  }

  private getDocumentUrl(): string {
    try { return this.webController?.getUrl() ?? ''; } catch (_) { return ''; }
  }

  /** All Browser channels use the same binding snapshot and controller URL. */
  private isBridgeHostAllowed(): boolean {
    return isWebViewHostAllowed(this.getBoundHosts(), this.getDocumentUrl());
  }

  /** Returns String(native wireframe.id), or empty before native collection. */
  public getSessionReplaySlotId(): string {
    return this.sessionReplayComponentRegistered
      ? FTSessionReplayBridgeRegistry.getWebReplaySlotId(this.sessionReplayComponentId) : '';
  }

  /** Proxy lifetime is independent of the observed native node identity. */
  public getProxyGeneration(): number { return this.proxyGeneration; }

  /** A detached document must never forward events into a replacement controller's slot. */
  public isCurrentProxy(generation: number): boolean { return generation === this.proxyGeneration; }

  /** Android checks the current installed RUM configuration again for every incoming event. */
  private isRumWebViewEnabled(): boolean {
    return this.getRumWebViewDisabledReason().length === 0 && this.isBridgeHostAllowed();
  }

  private getRumWebViewDisabledReason(): string {
    const manager = FTRUMConfigManager.getInstance();
    const config = manager.getConfig();
    if (!manager.isRumEnable() || config === null) return 'rum_not_initialized';
    return config.isEnableTraceWebView() ? '' : 'webview_tracing_disabled';
  }

  /** Browser SDK compatibility: null while WebView RUM or the optional Replay HAR is disabled. */
  public getSessionReplayPrivacyLevel(): string | null {
    if (!this.isRumWebViewEnabled() || !this.sessionReplayComponentRegistered) return null;
    const options = FTSessionReplayBridgeRegistry.getWebViewOptions();
    return options === null ? null : options.privacyLevel;
  }

  /** Browser SDK compatibility: records capability is exposed only with Replay. */
  public getSessionReplayCapabilities(): string | null {
    if (!this.isRumWebViewEnabled() || !this.sessionReplayComponentRegistered) return null;
    const options = FTSessionReplayBridgeRegistry.getWebViewOptions();
    return options === null ? null : JSON.stringify(options.capabilities);
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
   * Exposing this object does not bypass the current installed RUM collection switch.
   * @param webController WebView controller
   * @returns JavaScriptProxy object with object, name, methodList, and controller
   */
  public getJavaScriptProxy(webController: webview.WebviewController): JavaScriptProxy {
    this.prepareWebView(webController);
    // Get or create message receiver instance
    const receiver = this.getMessageReceiver();
    
    // Return JavaScriptProxy object (aligned with HarmonyOS WebView API)
    const proxy: JavaScriptProxy = {
      object: receiver,
      name: this.PROXY_OBJECT_NAME,
      methodList: ["sendEvent", "sendEventWithCallback", "getAllowedWebViewHosts", "getPrivacyLevel", "getCapabilities"],
      controller: webController
    };
    return proxy;
  }

  /** Install the Bridge using global RUM configuration and automatic controller/node association. */
  public setWebView(webController: webview.WebviewController): void {
    if (this.prepareWebView(webController)) this.registerJavaScriptProxy();
  }

  private prepareWebView(webController: webview.WebviewController): boolean {
    if (!webController) {
      FTInnerLogger.e(TAG, '[WEBVIEW-DEBUG] Bridge setup skipped: reason=controller_missing');
      return false;
    }

    if (this.webController && this.webController !== webController) this.clearWebController();
    if (!this.hostPolicyBound) {
      this.allowWebViewHost = this.getBoundHosts();
      this.hostPolicyBound = true;
    }
    this.webController = webController;
    
    const rumEnabled = this.getRumWebViewDisabledReason().length === 0;
    const logEnabled = TrackLogManager.getInstance().getLogConfig()?.isEnableWebViewLog() === true;
    if (!rumEnabled && !logEnabled) {
      this.stopSessionReplaySnapshotTimer();
      this.sessionReplayBindingKey = '';
      this.sessionReplayViewportKey = '';
      this.logIgnoredWebViewEvent('setup', this.getRumWebViewDisabledReason());
      return false;
    }
    
    // The compiler plugin writes this controller's token onto the actual Web node.
    const bindingId = FTWebViewReplayBridge.bindingId(webController);
    if (bindingId !== this.sessionReplayComponentId) {
      if (this.sessionReplayComponentRegistered) {
        FTSessionReplayBridgeRegistry.unregisterWebReplayComponent(this.sessionReplayComponentId);
      }
      this.sessionReplayComponentRegistered = false;
      this.sessionReplayBindingKey = '';
      this.sessionReplayComponentId = bindingId;
    }
    if (rumEnabled && this.sessionReplayComponentId.length > 0 && !this.sessionReplayComponentRegistered) {
      this.sessionReplayComponentRegistered =
        FTSessionReplayBridgeRegistry.registerWebReplayComponent(this.sessionReplayComponentId);
      if (!this.sessionReplayComponentRegistered) {
        FTInnerLogger.w(TAG, `[WEBVIEW-DEBUG] Replay registration rejected: component=${bindingId}, reason=duplicate_component_or_slot_limit`);
      }
    }
    if (this.sessionReplayComponentRegistered) {
      FTSessionReplayBridgeRegistry.setWebReplaySlotListener(this.sessionReplayComponentId, this.sessionReplaySlotListener);
    }
    
    this.webController = webController;
    this.sessionReplaySlotActive = true;
    
    this.refreshSessionReplaySnapshotTimer();
    return true;
  }

  /**
   * Clear WebController reference
   * Called when page is about to disappear or WebView is destroyed
   */
  public clearWebController(): void {
    const hadController = this.webController !== null || this.sessionReplayComponentRegistered;
    const componentId = this.sessionReplayComponentId;
    const slotId = this.getSessionReplaySlotId();
    
    // Unregister JavaScript proxy before clearing controller
    if (this.webController && this.messageReceiver) {
      try {
        this.webController.deleteJavaScriptRegister(this.PROXY_OBJECT_NAME);
      } catch (error) {
        this.logWebViewError('unregister_proxy', error as BusinessError, true);
      }
    }
    
    this.stopSessionReplaySnapshotTimer();
    this.sessionReplaySlotActive = false;
    if (slotId.length > 0) FTSessionReplayBridgeRegistry.notifyWebReplaySlotActive(slotId, false, Date.now());
    if (this.sessionReplayComponentRegistered) {
      FTSessionReplayBridgeRegistry.unregisterWebReplayComponent(this.sessionReplayComponentId);
    }
    this.sessionReplayComponentRegistered = false;
    this.sessionReplayComponentId = '';
    this.sessionReplayBindingKey = '';
    this.sessionReplayViewportKey = '';
    this.sessionReplayBrowserViewId = '';
    this.sessionReplayHasBrowserRecords = false;
    this.sessionReplayVisualViewport = null;
    this.webController = null;
    this.hostPolicyBound = false;
    this.allowWebViewHost = null;
    this.messageReceiver = null;
    this.webViewId = '';
    this.webReplayLinkContext = {};
    this.webReplayContexts.clear();
    this.lastWebSdkVersion = '';
    this.ignoredEventLogs.clear();
    this.proxyGeneration++;
    if (hadController) {
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Controller released: component=${componentId}, slot=${slotId || 'unbound'}`);
    }
  }

  /**
   * Register JavaScript proxy for direct method calls from Web to Native
   * Call after controller attachment and before page load.
   */
  private registerJavaScriptProxy(): void {
    if (!this.webController) {
      FTInnerLogger.e(TAG, '[WEBVIEW-DEBUG] Bridge registration failed: reason=controller_missing');
      return;
    }

    FTLogSeparator.data(TAG, 'WebView 通道注册');
    try {
      if (!this.messageReceiver) {
        this.messageReceiver = new WebViewMessageReceiver(this);
      }
      
      this.webController.registerJavaScriptProxy(
        this.messageReceiver,
        this.PROXY_OBJECT_NAME,
        ["sendEvent", "sendEventWithCallback", "getAllowedWebViewHosts", "getPrivacyLevel", "getCapabilities"],
        []
      );
      const hosts = this.allowWebViewHost;
      FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Bridge registration succeeded: component=${this.sessionReplayComponentId}, ` +
        `proxy=${this.PROXY_OBJECT_NAME}, hosts=${hosts === null ? 'all' : hosts.length === 0 ? 'none' : `allow_list(${hosts.length})`}, ` +
        'effective=next_page_load');
    } catch (error) {
      this.logWebViewError('register_proxy', error as BusinessError);
    }
  }

  /**
   * Send event from Web to Native
   */
  public sendEvent(event: string): void {
    this.sendEventWithCallback(event, null);
  }

  /**
   * datakit-js in webview called channel method, processing datakit business logic related
   */
  public sendEventWithCallback(event: string, callbackMethod: string | null): void {
    let eventObj: Record<string, string | Record<string, string | object>> | null = null;
    try {
      // Parse JSON event
      eventObj = JSON.parse(event) as Record<string, string | Record<string, string | object>>;
      
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

      if ((name === WEB_JS_TYPE_RUM || name === WEB_JS_TYPE_LOG || name === WEB_JS_TYPE_SESSION_REPLAY) &&
        !this.isBridgeHostAllowed()) {
        this.stopSessionReplaySnapshotTimer();
        this.logIgnoredWebViewEvent(name, 'host_not_allowed');
        return;
      }

      // Successful RUM processing is summarized by syncDataBackground:batch;
      // its final request body remains visible in UPLOAD BODY PREVIEW.
      if (name !== WEB_JS_TYPE_RUM) {
        // DOM Replay has a separate upload path, so retain its complete payload.
        this.logWebViewPayload('web_to_native', event);
      }

      // All receiver paths converge here, including declarative javaScriptProxy and legacy envelopes.
      // Do not acknowledge a rejected RUM/Replay event as successfully collected. Other channels
      // remain independent, as on Android (for example a separately enabled WebView Log channel).
      if ((name === WEB_JS_TYPE_RUM || name === WEB_JS_TYPE_SESSION_REPLAY) && !this.isRumWebViewEnabled()) {
        this.stopSessionReplaySnapshotTimer();
        this.sessionReplayBindingKey = '';
        this.logIgnoredWebViewEvent(name, this.getRumWebViewDisabledReason());
        return;
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
              if (currentKey === Constants.KEY_SDK_VERSION && cleanValue !== this.lastWebSdkVersion) {
                this.lastWebSdkVersion = cleanValue;
                FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Browser SDK version changed: component=${this.sessionReplayComponentId}, version=${cleanValue}`);
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

          // The Browser SDK View ID is the Replay envelope's view_id. It is
          // captured from the Browser RUM point before the matching Browser
          // Replay records arrive, as Android does in FTWebViewHandler.
          const browserViewId = tagsMap.get(Constants.KEY_RUM_VIEW_ID);
          if (browserViewId !== undefined && browserViewId.length > 0 && browserViewId !== this.webViewId &&
            (measurement === Constants.FT_MEASUREMENT_RUM_VIEW || this.webViewId.length === 0)) {
            FTSessionReplayBridgeRegistry.flushWebReplayData();
            this.webViewId = browserViewId;
            this.webReplayLinkContext = this.webReplayContexts.get(browserViewId) ?? {};
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

          const replayLinkContextChanged = this.updateSessionReplayWebLinkContext(tagsMap, fieldsMap, browserViewId ?? '');
          const container = FTSessionReplayBridgeRegistry.getWebReplaySlotBinding(this.getSessionReplaySlotId());
          const nativeViewId = container?.viewId || FTRUMInnerManager.getInstance().getActiveView()?.getId() || '';
          if (FTSessionReplayBridgeRegistry.getWebViewOptions() !== null && container !== null && nativeViewId.length > 0) {
            // Keep this source consistent with the SDK's current intake compatibility mode.
            const source = Constants.SDK_NAME.toString().indexOf('android') >= 0 ? 'android' : 'harmonyos';
            const containerTag: WebReplayContainerTag = { source, view_id: nativeViewId };
            tagsMap.set('container', JSON.stringify(containerTag));
          }
          if (replayLinkContextChanged) {
            this.notifySessionReplayWebContextChanged();
          }
          
          // Use measurement and timeValue extracted above
          // If timeValue is provided (from Web SDK), use it; otherwise use current nanosecond timestamp
          const time = timeValue !== undefined ? timeValue * 1000000 : Utils.getCurrentNanoTime();

          if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
            this.notifySessionReplayWebError();
          }

          // Get collect type
          const sessionIdValue = FTRUMInnerManager.getInstance().getSessionId();
          const collectType = sessionIdValue ? CollectType.ALL : CollectType.DROP;

          // Browser Resource and Error points arrive separately. Assign the
          // Resource UUID before crossing the Worker boundary so its
          // resource_id and the unprefixed Resource sdk_data_id UUID are the
          // same value. The first upload adds a package prefix only to
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

      } else if (name === WEB_JS_TYPE_SESSION_REPLAY) {
        const replayView = eventObj.view;
        const replayViewId = replayView !== undefined && typeof replayView === 'object' &&
          typeof replayView.id === 'string' ? replayView.id as string : '';
        this.handleSessionReplayWebEvent(dataJson, replayViewId);
      } else if (name === WEB_JS_TYPE_TRACK) {
        // Not used in current implementation
        this.logIgnoredWebViewEvent(WEB_JS_TYPE_TRACK, 'not_implemented');
      } else if (name === WEB_JS_TYPE_LOG) {
        const manager = TrackLogManager.getInstance();
        const loggerConfig = manager.getLogConfig();
        if (loggerConfig === null || !loggerConfig.isEnableWebViewLog()) {
          this.logIgnoredWebViewEvent(WEB_JS_TYPE_LOG, 'webview_log_disabled');
          return;
        }
        const log = dataJson === null ? null : mapWebViewLogEvent(dataJson, loggerConfig.isEnableLinkRumData());
        if (log === null) {
          this.logIgnoredWebViewEvent(WEB_JS_TYPE_LOG, 'invalid_log');
          return;
        }
        manager.trackWebViewLog(log);
      } else if (name === WEB_JS_TYPE_URL_VERIFY) {
        // Not used in current implementation
        this.logIgnoredWebViewEvent(WEB_JS_TYPE_URL_VERIFY, 'not_implemented');
      } else {
        // Unknown event type
        // The complete payload includes the unknown name; keep the rate-limit key bounded.
        this.logIgnoredWebViewEvent('unknown', 'unsupported_channel', true);
      }

      // Handle callback if needed
      if (callbackMethod && callbackMethod.length > 0) {
        // Create object with status property (can't use indexed access in ArkTS)
        // Define interface for callback return object
        interface CallbackReturnStatus {
          status: boolean;
        }
        const retObj: CallbackReturnStatus = { status: true };
        const retJson = JSON.stringify(retObj);
        this.callbackFromNative(tag, callbackMethod, retJson, "{}");
      }
    } catch (error) {
      // Direct proxy callers also need the original input when JSON decoding fails.
      if (eventObj === null) this.logWebViewPayload('web_to_native', event);
      this.logWebViewError('process_event', error as BusinessError);
    }
  }

  /**
   * Forwards one Browser SDK rrweb record into the optional Replay HAR. Core
   * supplies RUM identity and String(native wireframe.id); it never persists or
   * parses the replay payload itself.
   */
  private handleSessionReplayWebEvent(dataJson: Record<string, string | number | object> | null,
    browserViewId: string = ''): boolean {
    if (dataJson === null) {
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY, 'data_missing', true);
      return false;
    }
    if (!this.isRumWebViewEnabled()) {
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY, this.getRumWebViewDisabledReason());
      return false;
    }
    if (!this.sessionReplaySlotActive || this.webController === null) {
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY,
        this.webController === null ? 'controller_missing' : 'controller_inactive');
      return false;
    }
    const rumConfig = FTRUMConfigManager.getInstance().getConfig();
    if (rumConfig === null) return false;
    const applicationId = rumConfig.getRumAppId();
    const sessionId = FTRUMInnerManager.getInstance().getSessionId();
    // Current Browser SDK sends view.id with every rrweb message. It is authoritative,
    // including an initial Full Snapshot arriving before the first Browser RUM View.
    const viewId = browserViewId || this.webViewId;
    const slotId = this.getSessionReplaySlotId();
    const timestamp = Date.now();
    if (applicationId.length === 0 || sessionId.length === 0 || viewId.length === 0) {
      const reason = applicationId.length === 0 ? 'application_missing' :
        (sessionId.length === 0 ? 'session_missing' : 'browser_view_missing');
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY, reason, true);
      return false;
    }
    const rejection = FTSessionReplayBridgeRegistry.getWebReplayRejectionReason(slotId, applicationId, sessionId, timestamp);
    if (rejection.length > 0) {
      // Normal transitions (background, initial binding, inactive drain) are debug diagnostics.
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY, rejection,
        rejection === 'application_mismatch' || rejection === 'session_mismatch');
      return false;
    }
    const accepted = FTSessionReplayBridgeRegistry.notifyWebReplayData({
      applicationId,
      sessionId,
      viewId,
      slotId,
      linkContext: this.webReplayContexts.get(viewId) ?? (viewId === this.webViewId ? this.webReplayLinkContext : {}),
      payload: JSON.stringify(dataJson),
      timestamp: Date.now()
    });
    if (!accepted) {
      this.logIgnoredWebViewEvent(WEB_JS_TYPE_SESSION_REPLAY, 'recorder_rejected');
    } else {
      if (this.sessionReplayBrowserViewId !== viewId) this.sessionReplayVisualViewport = null;
      this.sessionReplayHasBrowserRecords = true;
      this.sessionReplayBrowserViewId = viewId;
      if (dataJson['type'] === 8) {
        const viewport = dataJson['data'] as WebReplayVisualViewportData;
        if (viewport !== null && typeof viewport === 'object' &&
          [viewport.scale, viewport.offsetLeft, viewport.offsetTop, viewport.pageLeft, viewport.pageTop,
            viewport.width, viewport.height].every((value: number): boolean => Number.isFinite(value)) &&
          viewport.scale > 0 && viewport.width > 0 && viewport.height > 0) {
          this.sessionReplayVisualViewport = {
            scale: viewport.scale, offsetLeft: viewport.offsetLeft, offsetTop: viewport.offsetTop,
            pageLeft: viewport.pageLeft, pageTop: viewport.pageTop, width: viewport.width, height: viewport.height
          };
        }
      }
    }
    this.refreshSessionReplaySnapshotTimer();
    return accepted;
  }

  /** Promotes the Browser Replay error window after Browser RUM reports an Error. */
  private notifySessionReplayWebError(): void {
    if (!this.isRumWebViewEnabled() || !this.sessionReplaySlotActive) {
      return;
    }
    const rumConfig = FTRUMConfigManager.getInstance().getConfig();
    const applicationId = rumConfig === null ? '' : rumConfig.getRumAppId();
    const sessionId = FTRUMInnerManager.getInstance().getSessionId();
    const activeView = FTRUMInnerManager.getInstance().getActiveView();
    const viewId = this.webViewId.length > 0
      ? this.webViewId
      : (activeView === null ? '' : activeView.getId());
    if (applicationId.length === 0 || sessionId.length === 0 || viewId.length === 0) {
      return;
    }
    FTSessionReplayBridgeRegistry.notifyWebReplayError({
      applicationId,
      sessionId,
      viewId,
      slotId: this.getSessionReplaySlotId(),
      linkContext: this.webReplayLinkContext,
      timestamp: Date.now()
    });
  }

  /**
   * Rebinds Browser association data to the native container View. This is
   * deliberately independent of Browser Replay record forwarding: a changed
   * configured key requires a native Full Snapshot before later mutations use
   * the new context.
   */
  private notifySessionReplayWebContextChanged(): void {
    if (!this.isRumWebViewEnabled() || !this.sessionReplaySlotActive) {
      return;
    }
    const activeView = FTRUMInnerManager.getInstance().getActiveView();
    const rumConfig = FTRUMConfigManager.getInstance().getConfig();
    const applicationId = rumConfig === null ? '' : rumConfig.getRumAppId();
    const sessionId = FTRUMInnerManager.getInstance().getSessionId();
    const binding = FTSessionReplayBridgeRegistry.getWebReplaySlotBinding(this.getSessionReplaySlotId());
    if (activeView === null || applicationId.length === 0 || sessionId.length === 0 ||
      activeView.getId().length === 0 || binding === null || binding.viewId !== activeView.getId() ||
      binding.sessionId !== sessionId || !FTSessionReplayBridgeRegistry.isWebReplaySlotActive(this.getSessionReplaySlotId())) {
      return;
    }
    FTRUMInnerManager.getInstance().updateWebReplayContainerContext(
      binding.viewId, sessionId, this.webReplayLinkContext);
    FTSessionReplayBridgeRegistry.notifyWebReplayContextChanged({
      applicationId,
      sessionId,
      viewId: activeView.getId(),
      viewName: activeView.getViewName(),
      viewReferrer: activeView.getViewReferrer(),
      linkContext: this.webReplayLinkContext,
      timestamp: Date.now(),
      browserViewId: this.webViewId,
      slotId: this.getSessionReplaySlotId()
    });
  }

  /** Extracts only explicitly configured RUM-link keys from Browser RUM data. */
  private updateSessionReplayWebLinkContext(tags: Map<string, string>, fields: Map<string, string>,
    eventViewId: string = ''): boolean {
    const contextViewId = eventViewId || this.webViewId;
    const previous = this.webReplayContexts.get(contextViewId) ??
      (contextViewId === this.webViewId ? this.webReplayLinkContext : {});
    const previousSignature = this.getSessionReplayLinkContextSignature(previous);
    const linkKeys = FTSessionReplayBridgeRegistry.getRUMLinkKeys();
    if (linkKeys.length === 0) {
      if (contextViewId === this.webViewId) this.webReplayLinkContext = {};
      this.webReplayContexts.delete(contextViewId);
      return previousSignature.length > 0;
    }
    const linkContext: Record<string, string | number | boolean> = {};
    for (let index = 0; index < linkKeys.length; index++) {
      const key = linkKeys[index];
      const tagValue = tags.get(key);
      if (tagValue !== undefined) {
        linkContext[key] = tagValue;
        continue;
      }
      const fieldValue = fields.get(key);
      if (fieldValue !== undefined) {
        linkContext[key] = fieldValue;
      }
    }
    // Browser Resource/Error points do not necessarily repeat custom context.
    // Retain the last complete association instead of treating an absent key
    // as a request to erase it and creating a spurious rebind snapshot.
    if (Object.keys(linkContext).length === 0) {
      return false;
    }
    if (contextViewId === this.webViewId) this.webReplayLinkContext = linkContext;
    if (contextViewId.length > 0) {
      if (this.webReplayContexts.size >= 20 && !this.webReplayContexts.has(contextViewId)) {
        this.webReplayContexts.delete(this.webReplayContexts.keys().next().value as string);
      }
      this.webReplayContexts.set(contextViewId, linkContext);
    }
    return contextViewId === this.webViewId && previousSignature !== this.getSessionReplayLinkContextSignature(linkContext);
  }

  private getSessionReplayLinkContextSignature(context: Record<string, string | number | boolean>): string {
    const keys = Object.keys(context).sort();
    const pairs: Array<string> = [];
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      pairs.push(`${key}=${String(context[key])}`);
    }
    return pairs.join('&');
  }

  /** Keeps Android's ten-second Browser full-snapshot cadence for error samples. */
  private refreshSessionReplaySnapshotTimer(): void {
    if (!this.isRumWebViewEnabled() || this.webController === null || !this.sessionReplaySlotActive ||
      !FTSessionReplayBridgeRegistry.isWebReplaySlotActive(this.getSessionReplaySlotId())) {
      this.stopSessionReplaySnapshotTimer();
      return;
    }
    const sessionId = FTRUMInnerManager.getInstance().getSessionId();
    if (!FTSessionReplayBridgeRegistry.isWebReplayErrorSampled(sessionId)) {
      this.stopSessionReplaySnapshotTimer();
      return;
    }
    if (this.sessionReplaySnapshotTimer !== -1) return;
    this.sessionReplaySnapshotTimer = setInterval((): void => {
      if (!this.isRumWebViewEnabled() || this.webController === null || !this.sessionReplaySlotActive ||
        !FTSessionReplayBridgeRegistry.isWebReplaySlotActive(this.getSessionReplaySlotId()) ||
        !FTSessionReplayBridgeRegistry.isWebReplayErrorSampled(FTRUMInnerManager.getInstance().getSessionId())) {
        this.stopSessionReplaySnapshotTimer();
        return;
      }
      this.requestSessionReplayFullSnapshot();
    }, FTWebViewHandler.SESSION_REPLAY_SNAPSHOT_INTERVAL_MS);
  }

  private stopSessionReplaySnapshotTimer(): void {
    if (this.sessionReplaySnapshotTimer !== -1) {
      clearInterval(this.sessionReplaySnapshotTimer);
      this.sessionReplaySnapshotTimer = -1;
    }
  }

  /** A new native container cannot be initialized from DOM mutations alone. */
  private refreshSessionReplayBinding(): void {
    const slotId = this.getSessionReplaySlotId();
    const binding = FTSessionReplayBridgeRegistry.getWebReplaySlotBinding(slotId);
    const config = FTRUMConfigManager.getInstance().getConfig();
    if (!this.isRumWebViewEnabled() || this.webController === null || !this.sessionReplaySlotActive ||
      config === null || binding === null ||
      binding.applicationId !== config.getRumAppId() ||
      binding.sessionId !== FTRUMInnerManager.getInstance().getSessionId() ||
      !FTSessionReplayBridgeRegistry.isWebReplaySlotActive(slotId)) {
      this.sessionReplayBindingKey = '';
      this.sessionReplayViewportKey = '';
      return;
    }
    const key = `${binding.applicationId}|${binding.sessionId}|${binding.viewId}|${slotId}`;
    const viewportKey = binding.width > 0 && binding.height > 0 ? `${slotId}|${binding.width}|${binding.height}` : '';
    if (key === this.sessionReplayBindingKey) {
      if (viewportKey.length > 0 && viewportKey !== this.sessionReplayViewportKey) {
        this.sessionReplayViewportKey = viewportKey;
        this.publishSessionReplayViewportResize(binding.width, binding.height);
      }
      return;
    }
    // Record before calling JS: the synchronous proxy can reenter this handler.
    this.sessionReplayBindingKey = key;
    this.sessionReplayViewportKey = viewportKey;
    this.requestSessionReplayFullSnapshot();
  }

  /** Keeps nested Browser Replay sized to the native Web wireframe after ArkUI relayout. */
  private publishSessionReplayViewportResize(width: number, height: number): void {
    if (!this.sessionReplayHasBrowserRecords || this.sessionReplayBrowserViewId.length === 0 ||
      !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return;
    const viewport = new Object() as WebReplayViewportResizeData;
    viewport.source = 4;
    viewport.width = width;
    viewport.height = height;
    const record = new Object() as WebReplayViewportResizeRecord;
    record.timestamp = Date.now();
    record.type = 3;
    record.data = viewport;
    this.handleSessionReplayWebEvent(
      record as Object as Record<string, string | number | object>, this.sessionReplayBrowserViewId);
    // A previous type-8 clip survives a source-4 resize in the Browser player.
    // Refresh both at the same boundary, retaining Browser zoom and scrolling.
    const previous = this.sessionReplayVisualViewport;
    if (previous === null) return;
    const visual: WebReplayVisualViewportData = {
      scale: previous.scale, offsetLeft: previous.offsetLeft, offsetTop: previous.offsetTop,
      pageLeft: previous.pageLeft, pageTop: previous.pageTop,
      width: width / previous.scale, height: height / previous.scale
    };
    const visualRecord: WebReplayViewportResizeRecord = { timestamp: record.timestamp, type: 8, data: visual };
    this.handleSessionReplayWebEvent(
      visualRecord as Object as Record<string, string | number | object>, this.sessionReplayBrowserViewId);
  }

  private requestSessionReplayFullSnapshot(): void {
    if (!this.isRumWebViewEnabled() || this.webController === null) return;
    try {
      this.webController.runJavaScript(
        'if (typeof DATAFLUX_RUM !== "undefined" && typeof DATAFLUX_RUM.takeSubsequentFullSnapshot === "function") { DATAFLUX_RUM.takeSubsequentFullSnapshot(); }',
        (error?: BusinessError<void>): void => {
          if (error !== undefined) {
            this.logWebViewError('request_full_snapshot', error, true);
          }
        }
      );
    } catch (error) {
      this.logWebViewError('request_full_snapshot', error as BusinessError, true);
    }
  }

  /**
   * Add event listener
   */
  public addEventListener(event: string, callbackMethod: string): void {
    try {
      const retJson = "{}";
      const errJson = "{}";
      const tag = Date.now().toString();
      
      this.callbackFromNative(tag, callbackMethod, retJson, errJson);
    } catch (error) {
      this.logWebViewError('add_event_listener', error as BusinessError);
    }
  }

  /**
   * Handle data from WebView
   * Called from WebViewPage via onReceiveData (legacy polling method)
   */
  public handleWebViewData(data: string): void {
    try {
      // Preserve legacy callback envelopes; regular events share the same receiver below.
      const parsedData = JSON.parse(data) as Record<string, string>;
      const callbackMethod = parsedData.callbackMethod;
      const eventData = parsedData.event;
      
      if (callbackMethod) {
        // Handle callback format
        if (eventData) {
          this.sendEventWithCallback(eventData, callbackMethod);
        } else {
          this.logWebViewPayload('web_to_native', data);
          FTInnerLogger.w(TAG, '[WEBVIEW-DEBUG] Legacy event ignored: reason=event_missing');
        }
      } else {
        // Handle regular event format
        this.sendEvent(data);
      }
    } catch (error) {
      this.logWebViewPayload('web_to_native', data);
      this.logWebViewError('parse_legacy_envelope', error as BusinessError);
    }
  }

  /**
   * Call webview page js method using runJavaScript
   * This is used for callback execution
   */
  private callbackFromNative(requestTag: string, callBackMethod: string, retJsonString: string, errJsonString: string): void {
    if (!this.webController) {
      FTInnerLogger.w(TAG, '[WEBVIEW-DEBUG] Callback skipped: reason=controller_missing');
      return;
    }

    const separator = retJsonString.length > 0 && errJsonString.length > 0 ? "," : "";
    const jsStr = `${callBackMethod}["${requestTag}"](${retJsonString}${separator}${errJsonString})`;
    
    this.webController.runJavaScript(jsStr, (err?: BusinessError<void>) => {
      if (err) {
        this.logWebViewError('execute_callback', err);
        
        // If error is about controller not associated, clear the controller
        const errorMsg = err.message || '';
        if (errorMsg.includes("associated") || errorMsg.includes("Init error")) {
          this.webController = null;
        }
      }
    });
  }

  /**
   * Send message from Native to Web using runJavaScript
   * HarmonyOS WebView may not support postMessage API with single parameter
   */
  public postMessageToWeb(message: string): void {
    this.logWebViewPayload('native_to_web', message);
    
    if (!this.webController) {
      FTInnerLogger.w(TAG, '[WEBVIEW-DEBUG] Native message skipped: reason=controller_missing');
      return;
    }

    try {
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
          this.logWebViewError('post_message', err);
        }
      });
    } catch (error) {
      this.logWebViewError('post_message', error as BusinessError);
    }
  }

  /** One original payload, without debug-only JSON parsing or per-field duplication. */
  private logWebViewPayload(direction: string, payload: string): void {
    FTInnerLogger.d(TAG, `[WEBVIEW-DEBUG] Payload: direction=${direction}, component=${this.sessionReplayComponentId}, ` +
      `slot=${this.getSessionReplaySlotId() || 'unbound'}, chars=${payload ? payload.length : 0}, payload=${payload}`);
  }

  /** Only summary diagnostics are limited; full payloads and actual operation errors are not. */
  private logIgnoredWebViewEvent(channel: string, reason: string, warning: boolean = false): void {
    const key = `${channel}|${reason}`;
    const slotId = this.getSessionReplaySlotId();
    const timestamp = Date.now();
    const previous = this.ignoredEventLogs.get(key);
    const elapsed = previous === undefined ? 0 : timestamp - previous.lastEmittedAt;
    if (previous !== undefined && previous.slotId === slotId && elapsed >= 0 &&
      elapsed < FTWebViewHandler.IGNORED_EVENT_LOG_INTERVAL_MS) {
      previous.suppressed++;
      return;
    }
    const suppressed = previous?.suppressed ?? 0;
    this.ignoredEventLogs.set(key, { lastEmittedAt: timestamp, suppressed: 0, slotId });
    const diagnostic = `[WEBVIEW-DEBUG] Event ignored: channel=${channel}, reason=${reason}, ` +
      `component=${this.sessionReplayComponentId}, slot=${slotId || 'unbound'}, suppressed=${suppressed}`;
    if (warning) FTInnerLogger.w(TAG, diagnostic);
    else FTInnerLogger.d(TAG, diagnostic);
  }

  private logWebViewError(stage: string, error: BusinessError, warning: boolean = false): void {
    const code = error?.code ?? 'unknown';
    const message = error?.message || String(error);
    const hint = stage === 'register_proxy' && (code === 17100001 || message.includes('associated'))
      ? ', hint=call_setWebView_in_onControllerAttached_before_page_load' : '';
    const diagnostic = `[WEBVIEW-DEBUG] Operation failed: stage=${stage}, component=${this.sessionReplayComponentId}, ` +
      `slot=${this.getSessionReplaySlotId() || 'unbound'}, code=${code}, message=${message}${hint}`;
    if (warning) FTInnerLogger.w(TAG, diagnostic);
    else FTInnerLogger.e(TAG, diagnostic);
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
