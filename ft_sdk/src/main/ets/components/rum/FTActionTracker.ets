import { UIContext, UIObserver, FrameNode } from '@kit.ArkUI';
import { FTRUMGlobalManager } from './FTRUMGlobalManager';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { FTRUMConfig } from '../Configs';
import { FTRUMInnerManager } from './FTRUMInnerManager';
import { ActionEventWrapper } from './bean/ActionEventWrapper';
import { ActionSourceType } from './enum/ActionSourceType';

const TAG = "FTActionTracker";

/**
 * Information about a processed click event
 */
interface ProcessedClickInfo {
  timestamp: number;
  nodeId: string;
  nodeType: string;
}

/**
 * Wrapper for primitive property values to satisfy Record<string, object> type
 */
interface PropertyValueWrapper {
  value: string | number | boolean;
}

/**
 * Action Tracker for HarmonyOS
 * Registers willClick listeners to automatically track UI component clicks
 */
export class FTActionTracker {
  private static instance: FTActionTracker | null = null;
  private isInitialized: boolean = false;
  private uiObserver: UIObserver | null = null;
  private rumConfig: FTRUMConfig | null = null;
  
  // Map to track processed click events to prevent duplicate actions
  // This prevents the same click event from being processed multiple times
  // (e.g., when both NetworkImage and its internal Image component trigger willClick)
  // Key: uniqueId, Value: ProcessedClickInfo
  private processedClickIds: Map<string, ProcessedClickInfo> = new Map();
  
  // Maximum size for Map collections to prevent memory leak (using Constants.MAX_MAP_SIZE_CLICK)

  private constructor() {}

  /**
   * Get singleton instance
   */
  public static getInstance(): FTActionTracker {
    if (FTActionTracker.instance === null) {
      FTActionTracker.instance = new FTActionTracker();
    }
    return FTActionTracker.instance;
  }

  /**
   * Initialize action tracker with UIContext and RUM config
   * @param uiContext UI context from window stage
   * @param rumConfig RUM configuration
   */
  public init(uiContext: UIContext, rumConfig: FTRUMConfig): void {
    if (this.isInitialized) {
      FTInnerLogger.w(TAG, "Action tracker already initialized");
      return;
    }

    this.rumConfig = rumConfig;

    // Check if action tracking is enabled
    if (!rumConfig.isEnableTraceUserAction()) {
      FTInnerLogger.d(TAG, "Action tracking is disabled in RUM config");
      return;
    }

    try {
      // Get UIObserver from UIContext
      this.uiObserver = uiContext.getUIObserver();
      if (this.uiObserver === null) {
        FTInnerLogger.e(TAG, "Failed to get UIObserver from UIContext");
        return;
      }

      // Register willClick listener
      // Removed high-frequency info log to reduce log output
      // FTInnerLogger.i(TAG, `[ACTION-TRACK] Registering willClick listener on UIObserver`);
      this.uiObserver.on('willClick', (event: Object, node?: FrameNode) => {
        this.handleClickEvent(node);
      });

      this.isInitialized = true;
      // Removed high-frequency info log to reduce log output
      // FTInnerLogger.i(TAG, `[ACTION-TRACK] ✅ Action tracker initialized successfully, willClick listener registered`);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize action tracker: ${error}`);
    }
  }

  /**
   * Handle click event from willClick callback
   * @param node FrameNode that was clicked
   */
  private handleClickEvent(node: FrameNode | undefined): void {
    try {
      
      // Check if RUM is enabled (aligned with Android: FTRUMConfigManager.isRumEnable())
      // Android: return config != null && config.getRumAppId() != null;
      if (!this.rumConfig) {
        return;
      }

      const rumAppId = this.rumConfig.getRumAppId();
      if (!rumAppId || rumAppId.length === 0) {
        return;
      }


      if (!node) {
        return;
      }

      // Get component type and ID
      let nodeType = node.getNodeType();
      const nodeId = node.getId();
      const uniqueIdRaw = node.getUniqueId();
      // Convert uniqueId to string to ensure type compatibility with Map key
      const uniqueId = String(uniqueIdRaw);

      // Prevent duplicate processing of the same click event
      // This can happen when:
      // 1. Both a custom component (like NetworkImage) and its internal component (Image) trigger willClick
      // 2. The same component is clicked multiple times quickly (e.g., Back button)
      // Strategy:
      // 1. If same uniqueId processed within 50ms, skip (same component clicked twice quickly)
      // 2. If same nodeId and nodeType processed within 50ms, skip (handles cases where uniqueId might differ)
      // 3. If nodeType is 'Image' and we recently processed a '__Common__' component with same nodeId within 50ms, skip
      //    (This handles NetworkImage -> Image case where parent and child both trigger willClick)
      const currentTime = Date.now();
      const existing = this.processedClickIds.get(uniqueId);
      
      if (existing !== undefined) {
        const timeDiff = currentTime - existing.timestamp;
        // If the same uniqueId was processed within 50ms, consider it a duplicate
        if (timeDiff < 50) {
          return;
        }
      }
      
      // Check if same nodeId and nodeType were processed recently (handles cases where uniqueId might differ)
      // This is important for components like Back button that might have different uniqueIds but same nodeId
      if (nodeId) {
        const entries = this.processedClickIds.entries();
        for (let i = 0; i < this.processedClickIds.size; i++) {
          const entry = entries.next();
          if (entry.done) {
            break;
          }
          const id = entry.value[0];
          const info = entry.value[1];
          const timeDiff = currentTime - info.timestamp;
          // If we processed the same nodeId and nodeType within 50ms, skip this click
          if (timeDiff < 50 && info.nodeId === nodeId && info.nodeType === nodeType) {
            return;
          }
        }
      }
      
      // Check if this is an Image component and we recently processed a __Common__ component with the same ID
      // This handles the case where NetworkImage (__Common__) and its internal Image both trigger willClick
      if (nodeType === 'Image' && nodeId) {
        const entries = this.processedClickIds.entries();
        for (let i = 0; i < this.processedClickIds.size; i++) {
          const entry = entries.next();
          if (entry.done) {
            break;
          }
          const id = entry.value[0];
          const info = entry.value[1];
          const timeDiff = currentTime - info.timestamp;
          // If we processed a __Common__ component with the same nodeId within 50ms, skip this Image click
          if (timeDiff < 50 && info.nodeType === '__Common__' && info.nodeId === nodeId) {
            return;
          }
        }
      }
      
      // Mark as processed with current timestamp and info
      const clickInfo: ProcessedClickInfo = {
        timestamp: currentTime,
        nodeId: nodeId || '',
        nodeType: nodeType
      };
      // Limit the size of processedClickIds to prevent memory leak
      if (this.processedClickIds.size > Constants.MAX_MAP_SIZE_CLICK) {
        FTInnerLogger.w(TAG, `processedClickIds size (${this.processedClickIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.processedClickIds.clear();
      }
      this.processedClickIds.set(uniqueId, clickInfo);
      
      // Limit the size of processedClickIds to prevent memory leak
      if (this.processedClickIds.size > Constants.MAX_MAP_SIZE_CLICK) {
        FTInnerLogger.w(TAG, `processedClickIds size (${this.processedClickIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.processedClickIds.clear();
      }
      
      // Clean up old entries to prevent memory leak (remove entries older than 1 second)
      if (this.processedClickIds.size > 100) {
        const oneSecondAgo = currentTime - 1000;
        const entries = this.processedClickIds.entries();
        const idsToDelete: string[] = [];
        for (let i = 0; i < this.processedClickIds.size; i++) {
          const entry = entries.next();
          if (entry.done) {
            break;
          }
          const id = entry.value[0];
          const info = entry.value[1];
          if (info.timestamp < oneSecondAgo) {
            idsToDelete.push(id);
          }
        }
        for (let i = 0; i < idsToDelete.length; i++) {
          this.processedClickIds.delete(idsToDelete[i]);
        }
      }

      // For custom components that return system components (like NetworkImage -> Image),
      // check if there's a __component_type__ customProperty to identify the actual component type
      if (nodeType === '__Common__') {
        try {
          interface CustomPropertyGetter { getCustomProperty(key: string): Object }
          const maybe: CustomPropertyGetter = node as CustomPropertyGetter;
          if (maybe && typeof maybe.getCustomProperty === 'function') {
            // FTInnerLogger.d(TAG, `[ACTION-TRACK] getCustomProperty function exists, trying to get __component_type__`);
            const componentType: Object = maybe.getCustomProperty('__component_type__');
            // FTInnerLogger.d(TAG, `[ACTION-TRACK] __component_type__ value: ${componentType}, type: ${typeof componentType}`);
            if (typeof componentType === 'string' && componentType.length > 0) {
              nodeType = componentType;
              // FTInnerLogger.d(TAG, `[ACTION-TRACK] ✅ Detected custom component type via __component_type__: ${nodeType}`);
            } else {
              // FTInnerLogger.d(TAG, `[ACTION-TRACK] __component_type__ is not a valid string, keeping __Common__`);
            }
          } else {
            // FTInnerLogger.d(TAG, `[ACTION-TRACK] getCustomProperty function not available`);
          }
        } catch (e) {
          FTInnerLogger.w(TAG, `[ACTION-TRACK] Error checking __component_type__: ${e}`);
        }
      }


      // Check whether this Action should be filtered.
      const handler = this.rumConfig.getActionTrackingHandler();
      if (handler) {
        const actionEventWrapper = new ActionEventWrapper(node, ActionSourceType.CLICK_VIEW, null);
        const handlerResult = handler.resolveHandlerAction(actionEventWrapper);

        // Only an explicit null filters the Action. Every other result uses the
        // original automatic collection flow below without a simplified path.
        if (handlerResult === null) {
          return;
        }
      }

      // No handler, or a non-matching handler result: use the original complete
      // automatic collection behavior.
      // willClick event is only triggered when component has onClick callback
      // So we can track all components that trigger willClick (aligned with user requirement)

      // Build action name (similar to Android's getViewDesc)
      const actionName = this.buildActionName(nodeType, nodeId, node);


      // Collect customProperty from node (aligned with Android: support for custom properties via customProperty)
      // Android: property is passed via FTActionTrackingHandler or extra parameter
      // HarmonyOS: collect from customProperty to support user-defined properties for click actions
      const property: Record<string, object> = {};
      try {
        interface CustomPropertyGetter { getCustomProperty(key: string): Object }
        const maybe: CustomPropertyGetter = node as CustomPropertyGetter;
        if (maybe && typeof maybe.getCustomProperty === 'function') {
          // Collect all customProperty keys that start with 'action_property_' prefix
          // This allows users to add custom properties by setting customProperty with key 'action_property_*'
          // Example: node.setCustomProperty('action_property_user_id', '12345')
          // Example: node.setCustomProperty('action_property_page_name', 'HomePage')
          // Also collect specific known keys for backward compatibility
          const knownKeys = ['action-count-test', '__component_type__'];
          
          // First, collect known keys
          for (let i = 0; i < knownKeys.length; i++) {
            try {
              const value = maybe.getCustomProperty(knownKeys[i]);
              if (value !== null && value !== undefined) {
                // Only add primitive types to avoid [object Object] issues
                // Wrap primitive types in an object to match Record<string, object> type requirement
                if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
                  // Wrap primitive value in an object to satisfy Record<string, object> type
                  const wrapper: PropertyValueWrapper = { value: value };
                  property[knownKeys[i]] = wrapper;
                  FTInnerLogger.d(TAG, `[ACTION-TRACK] Collected customProperty: ${knownKeys[i]}=${value}`);
                } else if (typeof value === 'object') {
                  property[knownKeys[i]] = value;
                  FTInnerLogger.d(TAG, `[ACTION-TRACK] Collected customProperty (object): ${knownKeys[i]}`);
                }
              }
            } catch (e) {
              // Ignore errors for individual keys
              FTInnerLogger.w(TAG, `[ACTION-TRACK] Error getting customProperty ${knownKeys[i]}: ${e}`);
            }
          }
          
          // Then, try to collect all customProperty keys with 'action_property_' prefix
          // Note: HarmonyOS API doesn't provide a way to enumerate all customProperty keys
          // So we can only collect known keys or keys with a specific prefix pattern
          // For now, we'll collect a common property key 'action_property' if it exists
          // Users can set a Record<string, object> as the value of 'action_property' customProperty
          try {
            const actionPropertyObj = maybe.getCustomProperty('action_property');
            if (actionPropertyObj !== null && actionPropertyObj !== undefined && typeof actionPropertyObj === 'object') {
              // If action_property is an object, merge its properties into property
              const actionProperty = actionPropertyObj as Record<string, object>;
              const actionPropertyKeys = Object.keys(actionProperty);
              for (let j = 0; j < actionPropertyKeys.length; j++) {
                const key = actionPropertyKeys[j];
                const value = actionProperty[key];
                if (value !== null && value !== undefined) {
                  property[key] = value;
                  FTInnerLogger.d(TAG, `[ACTION-TRACK] Collected action_property: ${key}`);
            }
              }
            }
          } catch (e) {
            // Ignore errors when getting action_property
            FTInnerLogger.w(TAG, `[ACTION-TRACK] Error getting action_property: ${e}`);
          }
        }
      } catch (e) {
        // Ignore errors when collecting customProperty
        FTInnerLogger.w(TAG, `[ACTION-TRACK] Error collecting customProperty: ${e}`);
      }

      // Track click action using startAction (same as Android implementation)
      // Click events use startAction, which stores to FT_TABLE_ACTION first
      // Action will be closed automatically by checkActionClose() after ACTION_NORMAL_TIME_OUT (100ms)
      // Then inserted into sync table for upload
      // Removed high-frequency info log to reduce log output
      // FTInnerLogger.i(TAG, `[ACTION-TRACK] ⭐ Tracking action: name=${actionName}, type=${nodeType}, id=${nodeId || '(no id)'}`);
      
      // Use startAction for click events (needWait=false, same as Android)
      // startAction stores to temporary table FT_TABLE_ACTION first
      // Then automatically closes and moves to sync table after timeout (100ms for non-wait actions)
      FTRUMGlobalManager.getInstance().startAction(actionName, Constants.EVENT_NAME_CLICK, property);
      
      // Removed high-frequency info log to reduce log output
      // FTInnerLogger.i(TAG, `[ACTION-TRACK] ✅ Action started: name=${actionName} (startAction - will auto-close after 100ms)`);

    } catch (error) {
      FTInnerLogger.e(TAG, `[ACTION-TRACK] ❌ Error handling click event: ${error}`);
      FTInnerLogger.e(TAG, `[ACTION-TRACK] Error stack: ${(error as Error)?.stack || 'No stack trace'}`);
    }
  }

  /**
   * Build the default automatic-action name using Android's component/text#id format.
   */
  private buildActionName(nodeType: string, nodeId: string | undefined, node?: FrameNode): string {
    const nodeText = this.resolveNodeText(node, nodeId);
    const resourceId = nodeId && nodeId.length > 0 ? `#${nodeId}` : '';
    return `${nodeType}/${nodeText}${resourceId}${this.resolvePositionSuffix(node)}`;
  }

  /**
   * Resolve a user-visible control label without changing the caller-provided value.
   * customProperty values are preferred so applications can supply a semantic name when
   * the platform does not expose a textual component attribute.
   */
  private resolveNodeText(node: FrameNode | undefined, nodeId: string | undefined): string {
    if (!node) {
      return '';
    }

    try {
      interface CustomPropertyGetter { getCustomProperty(key: string): Object | undefined }
      const customPropertyNode = node as CustomPropertyGetter;
      if (customPropertyNode && typeof customPropertyNode.getCustomProperty === 'function') {
        const keys: string[] = ['action-count-test'];
        if (nodeId && nodeId.length > 0) {
          keys.push(nodeId);
        }
        keys.push('action_name', 'action_text', 'text', 'label');
        for (let i = 0; i < keys.length; i++) {
          const text = this.asNonEmptyString(customPropertyNode.getCustomProperty(keys[i]));
          if (text.length > 0) {
            return text;
          }
        }
      }
    } catch (error) {
      FTInnerLogger.d(TAG, `[ACTION-TRACK] Cannot read custom action text: ${error}`);
    }

    // FrameNode does not offer a component-specific text getter. Inspector attributes are
    // available from API 12 and are consulted only after application-provided properties.
    try {
      const inspectorInfo = node.getInspectorInfo() as Record<string, Object>;
      const attributes = inspectorInfo['$attrs'];
      if (attributes && typeof attributes === 'object') {
        const attributeRecord = attributes as Record<string, Object>;
        const keys = ['text', 'label', 'content', 'value', 'title'];
        for (let i = 0; i < keys.length; i++) {
          const text = this.asNonEmptyString(attributeRecord[keys[i]]);
          if (text.length > 0) {
            return text;
          }
        }
      }
    } catch (error) {
      FTInnerLogger.d(TAG, `[ACTION-TRACK] Cannot read inspector action text: ${error}`);
    }

    return '';
  }

  private asNonEmptyString(value: Object | undefined): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }

  /**
   * Android appends positions for list and tab actions. The FrameNode hierarchy provides
   * the equivalent ListItem/TabContent sibling index on HarmonyOS.
   */
  private resolvePositionSuffix(node: FrameNode | undefined): string {
    const listItem = this.findAncestorByType(node, 'ListItem');
    if (listItem) {
      return `#position:${this.getSameTypeSiblingIndex(listItem, 'ListItem')}`;
    }

    const tabContent = this.findAncestorByType(node, 'TabContent');
    if (tabContent) {
      return `#position:${this.getSameTypeSiblingIndex(tabContent, 'TabContent')}`;
    }

    return '';
  }

  private findAncestorByType(node: FrameNode | undefined, targetType: string): FrameNode | null {
    let current = node || null;
    try {
      for (let depth = 0; current !== null && depth < 32; depth++) {
        if (current.getNodeType() === targetType) {
          return current;
        }
        current = current.getParent();
      }
    } catch (error) {
      FTInnerLogger.d(TAG, `[ACTION-TRACK] Cannot resolve ${targetType} position: ${error}`);
    }
    return null;
  }

  private getSameTypeSiblingIndex(node: FrameNode, nodeType: string): number {
    let index = 0;
    try {
      let sibling = node.getPreviousSibling();
      for (let inspected = 0; sibling !== null && inspected < 10000; inspected++) {
        if (sibling.getNodeType() === nodeType) {
          index++;
        }
        sibling = sibling.getPreviousSibling();
      }
    } catch (error) {
      FTInnerLogger.d(TAG, `[ACTION-TRACK] Cannot resolve ${nodeType} sibling index: ${error}`);
    }
    return index;
  }

  /**
   * Clean up and unregister listeners, release UIContext reference
   */
  public destroy(): void {
    try {
      // Clear UIObserver reference
      if (this.uiObserver) {
        // UIObserver doesn't have an explicit off method in HarmonyOS API
        // The listener will be automatically cleaned up when UI context is destroyed
        this.uiObserver = null;
      }

      // Clear UIContext reference (implicitly through rumConfig if needed)
      // Note: We don't directly store UIContext, but clearing uiObserver should be sufficient
      
      // Reset initialization state
      this.isInitialized = false;
      this.rumConfig = null;
      
      FTInnerLogger.d(TAG, "Action tracker destroyed, all references released");
    } catch (error) {
      FTInnerLogger.e(TAG, `Error destroying action tracker: ${error}`);
    }
  }
}
