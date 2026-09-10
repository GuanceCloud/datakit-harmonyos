import { uiObserver } from '@kit.ArkUI';
import { FTViewTrackingType } from '../enum/FTViewTrackingType';

/**
 * Context supplied when the SDK resolves an automatically tracked View.
 *
 * `viewName` is the normalized final route segment. Use `trackingType` to
 * select the matching event object and filter directly from ArkUI's Router
 * or Navigation callback parameters.
 */
export type FTViewTrackingContext = FTViewRouterTrackingContext | FTViewNavigationTrackingContext;

/** Context for an automatic Router View. */
export interface FTViewRouterTrackingContext {
  /** Indicates that `routerPageInfo` is available. */
  trackingType: FTViewTrackingType.ROUTER;
  /** Original ArkUI Router callback parameters. Use its name, path, index, or state to filter. */
  routerPageInfo: uiObserver.RouterPageInfo;
  /** Original Router route or Navigation destination name from ArkUI. */
  originalViewName: string;
  /** Normalized final route segment. */
  viewName: string;
  /** Empty because Router callbacks have no source destination. */
  originalFromViewName: string;
  /** Empty because Router callbacks have no source destination. */
  fromViewName: string;
  /** Router lifecycle state that caused resolution; equal to `routerPageInfo.state`. */
  routerPageState: number;
}

/** Context for an automatic Navigation View. */
export interface FTViewNavigationTrackingContext {
  /** Indicates that `navigationInfo` is available. */
  trackingType: FTViewTrackingType.NAVIGATION;
  /** Original ArkUI Navigation callback parameters. Use from, to, operation, and destination params to filter. */
  navigationInfo: uiObserver.NavDestinationSwitchInfo;
  /** Original Navigation destination name from ArkUI. */
  originalViewName: string;
  /** Normalized final destination segment. */
  viewName: string;
  /** Original Navigation source name from ArkUI. */
  originalFromViewName: string;
  /** Normalized Navigation source name. */
  fromViewName: string;
}
