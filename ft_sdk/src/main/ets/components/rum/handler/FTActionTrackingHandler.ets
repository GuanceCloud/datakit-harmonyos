import { ActionEventWrapper } from '../bean/ActionEventWrapper';
import { HandlerAction } from '../bean/HandlerAction';

/**
 * Action tracking handler interface
 * Allows you to customize or filter automatically tracked user actions in RUM data.
 * Aligned with Android SDK: FTActionTrackingHandler
 * 
 * Called for automatic clicks and cold/hot launch Actions. Return a HandlerAction
 * to replace the name and add properties, null to filter the Action, or
 * undefined to keep the SDK's original automatic collection behavior.
 * 
 * @example
 * ```typescript
 * FTSdk.initRUMWithConfig(new FTRUMConfig()
 *   .setActionTrackingHandler({
 *     resolveHandlerAction: (actionEventWrapper: ActionEventWrapper): HandlerAction | null | undefined => {
 *       const nodeType = actionEventWrapper.getSource()?.getNodeType();
 *       if (nodeType === 'CustomComponent') {
 *         return null; // Skip tracking
 *       }
 *       if (nodeType === 'Button') {
 *         return new HandlerAction('custom_button');
 *       }
 *       return undefined; // Continue through the original automatic Action path
 *     }
 *   })
 * );
 * ```
 */
export interface FTActionTrackingHandler {
  /**
   * Customize, filter, or retain an automatically collected Action.
   * 
   * @param actionEventWrapper The action event wrapper containing information about the action
   * @returns HandlerAction to customize, null to skip, or undefined to continue
   *          through the SDK's original automatic Action collection behavior.
   */
  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): HandlerAction | null | undefined;
}
