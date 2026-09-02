import { HandlerView } from '../bean/HandlerView';

/**
 * Customizes automatic RUM View collection for Router pages and Navigation
 * destinations.
 *
 * Return a HandlerView to collect a View with a custom name and optional
 * properties. Return null to skip automatic collection for that View.
 */
export interface FTViewTrackingHandler {
  /**
   * Resolves an automatic View from its normalized final route segment.
   *
   * @param viewName The normalized Router page or Navigation destination name.
   * @returns A custom HandlerView, or null to skip this View.
   */
  resolveHandlerView(viewName: string): HandlerView | null;
}
