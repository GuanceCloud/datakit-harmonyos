/**
 * Result returned by an automatic View tracking handler.
 *
 * A non-null result starts collection with the supplied View name and optional
 * custom properties. Returning null from a handler skips the automatic View.
 * This mirrors Android's HandlerView contract for HarmonyOS Router and
 * Navigation destinations.
 */
export class HandlerView {
  private viewName: string;
  private property: Record<string, object> | null;

  constructor(viewName: string, property: Record<string, object> | null = null) {
    this.viewName = viewName;
    this.property = property;
  }

  public getViewName(): string {
    return this.viewName;
  }

  public getProperty(): Record<string, object> | null {
    return this.property;
  }
}
