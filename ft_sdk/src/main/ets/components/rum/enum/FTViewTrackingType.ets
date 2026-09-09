/**
 * Target of an automatic RUM View tracking handler.
 */
export enum FTViewTrackingType {
  /** Apply the handler only to Router page Views. */
  ROUTER = 'router',
  /** Apply the handler only to Navigation destination Views. */
  NAVIGATION = 'navigation',
  /** Apply the handler to both Router page and Navigation destination Views. */
  ALL = 'all'
}
