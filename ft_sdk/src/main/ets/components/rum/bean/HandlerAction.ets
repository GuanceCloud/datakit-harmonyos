/**
 * Handler action
 * Represents an action to be tracked with custom name and properties
 * Aligned with Android SDK: HandlerAction
 */
export class HandlerAction {
  private actionName: string;
  private property: Record<string, object> | null;

  constructor(actionName: string, property: Record<string, object> | null = null) {
    this.actionName = actionName;
    this.property = property;
  }

  public getActionName(): string {
    return this.actionName;
  }

  public getProperty(): Record<string, object> | null {
    return this.property;
  }
}

