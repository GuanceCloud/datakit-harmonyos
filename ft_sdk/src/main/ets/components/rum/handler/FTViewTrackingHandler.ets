import { HandlerView } from '../bean/HandlerView';
import { FTViewTrackingContext } from './FTViewTrackingContext';

/**
 * Customizes automatic RUM View collection for Router pages and Navigation
 * destinations.
 *
 * Return a HandlerView to collect a View with a custom name and optional
 * properties. Return null to skip automatic collection for that View.
 */
export interface FTViewTrackingHandler {
  /**
   * Resolves an automatic View from its source-specific context.
   *
   * @param context For a Router View, exposes `routerPageInfo`; for a
   * Navigation View, exposes `navigationInfo` (`NavDestinationSwitchInfo`).
   * Both variants include `viewName`, the normalized final route segment.
   * @returns A custom HandlerView, or null to skip this View.
   */
  resolveHandlerView(context: FTViewTrackingContext): HandlerView | null;
}
