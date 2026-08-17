import { HandlerView } from '../bean/HandlerView';

/**
 * Customizes automatic RUM View collection for Router pages.
 *
 * Return a HandlerView to collect a page with a custom name and optional
 * properties. Return null to skip automatic collection for that route.
 */
export interface FTViewRouterTrackingHandler {
  /**
   * Resolves the automatic View for a Router page.
   *
   * @param routeName The normalized Router page name (the final route segment).
   * @returns A custom HandlerView, or null to skip this Router page.
   */
  resolveHandlerView(routeName: string): HandlerView | null;
}
