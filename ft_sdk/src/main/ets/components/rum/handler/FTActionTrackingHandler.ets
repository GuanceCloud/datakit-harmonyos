import { ActionEventWrapper } from '../bean/ActionEventWrapper';
import { HandlerAction } from '../bean/HandlerAction';

/**
 * Action tracking handler interface
 * Allows you to customize how user actions are tracked in RUM data
 * Aligned with Android SDK: FTActionTrackingHandler
 * 
 * When a user action occurs (click, touch, etc.), this handler will be called to determine
 * how the action should be tracked.
 * 
 * @example
 * ```typescript
 * FTSdk.initRUMWithConfig(new FTRUMConfig()
 *   .setActionTrackingHandler({
 *     resolveHandlerAction: (actionEventWrapper: ActionEventWrapper): HandlerAction | null => {
 *       const nodeType = actionEventWrapper.getSource()?.getNodeType();
 *       if (nodeType === 'CustomComponent') {
 *         return new HandlerAction('CustomAction', { customProp: 'value' });
 *       }
 *       return null; // Skip tracking
 *     }
 *   })
 * );
 * ```
 */
export interface FTActionTrackingHandler {
  /**
   * Determine how a user action should be tracked
   * 
   * @param actionEventWrapper The action event wrapper containing information about the action
   * @returns HandlerAction with custom action name and properties, or null to skip tracking
   */
  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): HandlerAction | null;
}

