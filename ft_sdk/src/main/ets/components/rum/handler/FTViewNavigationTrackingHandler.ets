import { HandlerView } from '../bean/HandlerView';

/**
 * Customizes automatic RUM View collection for Navigation destinations.
 *
 * Return a HandlerView to collect a destination with a custom name and
 * optional properties. Return null to skip automatic collection for that
 * destination.
 */
export interface FTViewNavigationTrackingHandler {
  /**
   * Resolves the automatic View for a Navigation destination.
   *
   * @param destinationName The normalized destination name (the final route segment).
   * @returns A custom HandlerView, or null to skip this destination.
   */
  resolveHandlerView(destinationName: string): HandlerView | null;
}
