import { ActionEventWrapper } from '../bean/ActionEventWrapper';
import { HandlerAction } from '../bean/HandlerAction';
import { ActionSourceType } from '../enum/ActionSourceType';
import { FTInnerLogger } from '../../log/FTLogger';
import { FTActionTrackingHandler } from './FTActionTrackingHandler';

/** Invoke the public handler consistently for automatic click and launch Actions. */
export function resolveAutomaticActionHandler(
  handler: FTActionTrackingHandler | null,
  event: ActionEventWrapper
): HandlerAction | null | undefined {
  if (handler === null) {
    return undefined;
  }
  try {
    const result = handler.resolveHandlerAction(event);
    if (result === null || result instanceof HandlerAction) {
      return result;
    }
  } catch (error) {
    FTInnerLogger.w('FTAutomaticActionHandler', `Action handler failed; using default Action: ${String(error)}`);
  }
  return undefined;
}

export interface FTAutomaticLaunchAction {
  name: string;
  properties: Record<string, object>;
}

/** Preserve SDK-owned launch fields while allowing a handler to name and enrich the Action. */
export function resolveAutomaticLaunchAction(
  handler: FTActionTrackingHandler | null,
  sourceType: ActionSourceType,
  defaultName: string,
  sdkProperties: Record<string, object>
): FTAutomaticLaunchAction | null {
  const result = resolveAutomaticActionHandler(handler, new ActionEventWrapper(null, sourceType, null));
  if (result === null) {
    return null;
  }
  if (!(result instanceof HandlerAction)) {
    return { name: defaultName, properties: sdkProperties };
  }

  const properties: Record<string, object> = {};
  const customProperties = result.getProperty();
  if (customProperties !== null) {
    const customKeys = Object.keys(customProperties);
    for (let index = 0; index < customKeys.length; index++) {
      const key = customKeys[index];
      properties[key] = customProperties[key];
    }
  }
  const sdkKeys = Object.keys(sdkProperties);
  for (let index = 0; index < sdkKeys.length; index++) {
    const key = sdkKeys[index];
    properties[key] = sdkProperties[key];
  }
  return { name: result.getActionName(), properties };
}
