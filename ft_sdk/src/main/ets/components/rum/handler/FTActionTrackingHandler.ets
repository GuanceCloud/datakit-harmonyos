import { ActionEventWrapper } from '../bean/ActionEventWrapper';

/**
 * Action tracking handler interface
 * Allows you to filter automatically tracked user actions in RUM data
 * Aligned with Android SDK: FTActionTrackingHandler
 * 
 * When a user action occurs (click, touch, etc.), this handler will be called to determine
 * whether the action should be filtered. Return `undefined` to continue through the
 * SDK's original automatic Action collection path.
 * 
 * @example
 * ```typescript
 * FTSdk.initRUMWithConfig(new FTRUMConfig()
 *   .setActionTrackingHandler({
 *     resolveHandlerAction: (actionEventWrapper: ActionEventWrapper): null | undefined => {
 *       const nodeType = actionEventWrapper.getSource()?.getNodeType();
 *       if (nodeType === 'CustomComponent') {
 *         return null; // Skip tracking
 *       }
 *       return undefined; // Continue through the original automatic Action path
 *     }
 *   })
 * );
 * ```
 */
export interface FTActionTrackingHandler {
  /**
   * Determine whether a user action should be filtered
   * 
   * @param actionEventWrapper The action event wrapper containing information about the action
   * @returns null to skip collection, or undefined to continue through the SDK's original
   *          automatic Action collection behavior.
   */
  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): null | undefined;
}
