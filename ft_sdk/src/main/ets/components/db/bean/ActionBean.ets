/**
 * HarmonyOS SDK RUM action data model class
 */
import { StringUtils } from '../../utils/StringUtils';
import { Utils } from '../../utils/Utils';
import { Constants } from '../../Constants';
import { CollectType, parseCollectType } from '../../rum/enum/RUMEnums';

interface ReplayMarker {
  value: boolean;
  recordingId?: string;
}

export interface ActionBeanJSON {
  id: string;
  startTime: number;
  actionDuration: number;
  isClose: boolean;
  hasReplay?: boolean;
  replayRecordingId?: string;
  errorCount: number;
  longTaskCount: number;
  resourceCount: number;
  pendingResource: number;
  sessionId: string;
  viewName: string;
  viewId: string;
  viewReferrer: string;
  actionName: string;
  actionType: string;
  extraAttr: Record<string, object>;
  collectType?: CollectType | null;
}

/**
 * RUM action data model
 * Used to store detailed data of user actions
 */
export class ActionBean {
  /**
   * Action ID
   */
  private id: string = "";

  /**
   * Start time
   */
  private startTime: number = 0;

  /**
   * Action duration
   */
  private actionDuration: number = 0;

  /**
   * Whether closed
   */
  private isClose: boolean = false;

  /** Whether this Action is associated with a captured Session Replay record. */
  private hasReplay: boolean = false;
  /** Empty excludes this event; undefined is a legacy cached Action. */
  private replayRecordingId: string | undefined = undefined;

  /**
   * Error count
   */
  private errorCount: number = 0;

  /**
   * Long task count
   */
  private longTaskCount: number = 0;

  /**
   * Resource count
   */
  private resourceCount: number = 0;

  /**
   * Pending resources
   */
  private pendingResource: number = 0;

  /**
   * Session ID
   */
  private sessionId: string = "";

  /** Sampling decision captured when this Action was created. */
  private collectType: CollectType | null = null;

  /**
   * View name
   */
  private viewName: string = "";

  /**
   * View ID
   */
  private viewId: string = "";

  /**
   * View source
   */
  private viewReferrer: string = "";

  /**
   * Action name
   */
  private actionName: string = "";

  /**
   * Action type
   */
  private actionType: string = "";

  /**
   * Extended properties
   */
  private extraAttr: Map<string, object> = new Map();

  /**
   * Constructor
   * @param id Action ID
   * @param actionName Action name
   * @param actionType Action type
   * @param startTime Start time in nanoseconds (must be provided at creation time)
   * Note: startTime must be provided in constructor to ensure timestamp is set only once when action is created, and remains immutable.
   */
  constructor(id: string, actionName: string, actionType: string, startTime: number) {
    this.id = id;
    this.actionName = actionName;
    this.actionType = actionType;
    this.startTime = startTime;
  }

  // Getter and Setter methods
  public getId(): string { return this.id; }
  public setId(id: string): void { this.id = id; }

  public getStartTime(): number { return this.startTime; }

  public getActionDuration(): number { return this.actionDuration; }
  public setActionDuration(actionDuration: number): void { this.actionDuration = actionDuration; }

  public getIsClose(): boolean { return this.isClose; }
  public setIsClose(isClose: boolean): void { this.isClose = isClose; }

  public isHasReplay(): boolean { return this.hasReplay; }
  public setHasReplay(hasReplay: boolean): void { this.hasReplay = hasReplay; }
  public getReplayRecordingId(): string | undefined { return this.replayRecordingId; }
  public setReplayRecordingId(recordingId: string | undefined): void { this.replayRecordingId = recordingId; }

  public getErrorCount(): number { return this.errorCount; }
  public setErrorCount(errorCount: number): void { this.errorCount = errorCount; }

  public getLongTaskCount(): number { return this.longTaskCount; }
  public setLongTaskCount(longTaskCount: number): void { this.longTaskCount = longTaskCount; }

  public getResourceCount(): number { return this.resourceCount; }
  public setResourceCount(resourceCount: number): void { this.resourceCount = resourceCount; }

  public getPendingResource(): number { return this.pendingResource; }
  public setPendingResource(pendingResource: number): void { this.pendingResource = pendingResource; }

  public getSessionId(): string { return this.sessionId; }
  public setSessionId(sessionId: string): void { this.sessionId = sessionId; }

  public getCollectType(): CollectType | null { return this.collectType; }
  public setCollectType(collectType: CollectType | null): void { this.collectType = collectType; }

  public getViewName(): string { return this.viewName; }
  public setViewName(viewName: string): void { this.viewName = viewName; }

  public getViewId(): string { return this.viewId; }
  public setViewId(viewId: string): void { this.viewId = viewId; }

  public getViewReferrer(): string { return this.viewReferrer; }
  public setViewReferrer(viewReferrer: string): void { this.viewReferrer = viewReferrer; }

  public getActionName(): string { return this.actionName; }
  public setActionName(actionName: string): void { this.actionName = actionName; }

  public getActionType(): string { return this.actionType; }
  public setActionType(actionType: string): void { this.actionType = actionType; }

  /**
   * Get extended properties
   * @returns Map<string, any>
   */
  public getExtraAttr(): Map<string, object> {
    return this.extraAttr;
  }

  /**
   * Set extended properties
   * @param extraAttr Extended properties
   */
  public setExtraAttr(extraAttr: Map<string, object>): void {
    this.extraAttr = extraAttr;
  }

  /**
   * Add extended property
   * @param key Key
   * @param value Value
   */
  public addExtraAttr(key: string, value: object): void {
    this.extraAttr.set(key, value);
  }

  /**
   * Get extended properties JSON string
   * @returns string
   */
  public getAttrJsonString(): string {
    try {
      const extraAttrObj: Record<string, object | string> = {};
      this.extraAttr.forEach((value, key) => {
        extraAttrObj[key] = value;
      });
      const replayMarker: ReplayMarker = { value: this.hasReplay, recordingId: this.replayRecordingId };
      extraAttrObj[Constants.KEY_HAS_REPLAY] = replayMarker;
      if (this.collectType !== null) {
        extraAttrObj[Constants.KEY_RUM_COLLECT_TYPE] = this.collectType;
      }
      return JSON.stringify(extraAttrObj);
    } catch (error) {
      return "{}";
    }
  }

  /**
   * Set extended properties JSON string
   * @param jsonString JSON string
   */
  public setAttrJsonString(jsonString: string): void {
    try {
      if (StringUtils.isNotEmpty(jsonString)) {
        const obj = JSON.parse(jsonString) as Record<string, object>;
        this.extraAttr.clear();
        this.collectType = null;
        const keys = ActionBean.getObjectKeys(obj);
        for (let i = 0; i < keys.length; i++) {
          const key = keys[i];
          if (key === Constants.KEY_HAS_REPLAY) {
            const replayMarker = obj[key] as ReplayMarker;
            this.hasReplay = replayMarker.value === true;
            this.replayRecordingId = replayMarker.recordingId;
          } else if (key === Constants.KEY_RUM_COLLECT_TYPE) {
            this.collectType = parseCollectType(String(obj[key]));
          } else {
            this.extraAttr.set(key, obj[key] as object);
          }
        }
      }
    } catch (error) {
      // Keep original properties when parsing fails
    }
  }

  /**
   * Close action (nanoseconds) - aligned with Android
   */
  public close(): void {
    this.isClose = true;
    this.actionDuration = Utils.getCurrentNanoTime() - this.startTime;
  }

  /**
   * Increment error count
   */
  public incrementErrorCount(): void {
    this.errorCount++;
  }

  /**
   * Increment long task count
   */
  public incrementLongTaskCount(): void {
    this.longTaskCount++;
  }

  /**
   * Increment resource count
   */
  public incrementResourceCount(): void {
    this.resourceCount++;
  }

  /**
   * Increment pending resource count
   */
  public incrementPendingResource(): void {
    this.pendingResource++;
  }

  /**
   * Decrement pending resource count
   */
  public decrementPendingResource(): void {
    if (this.pendingResource > 0) {
      this.pendingResource--;
    }
  }

  /**
   * Calculate action duration (nanoseconds) - aligned with Android
   */
  public calculateDuration(): void {
    if (!this.isClose) {
      this.actionDuration = Utils.getCurrentNanoTime() - this.startTime;
    }
  }

  /**
   * Set view information
   * @param viewName View name
   * @param viewId View ID
   * @param viewReferrer View source
   */
  public setViewInfo(viewName: string, viewId: string, viewReferrer: string): void {
    this.viewName = viewName;
    this.viewId = viewId;
    this.viewReferrer = viewReferrer;
  }

  /**
   * Set session information
   * @param sessionId session ID
   */
  public setSessionInfo(sessionId: string): void {
    this.sessionId = sessionId;
  }

  /**
   * Validate data integrity
   * @returns boolean
   */
  public isValid(): boolean {
    return StringUtils.isNotEmpty(this.id) && 
           StringUtils.isNotEmpty(this.actionName) &&
           StringUtils.isNotEmpty(this.actionType) &&
           this.startTime > 0;
  }

  /**
   * Convert to a JSON object
   * @returns ActionBeanJSON
   */
  public toJSON(): ActionBeanJSON {
    const extraAttrObj: Record<string, object> = {};
    this.extraAttr.forEach((value, key) => {
      extraAttrObj[key] = value;
    });
    
    return {
      id: this.id,
      startTime: this.startTime,
      actionDuration: this.actionDuration,
      isClose: this.isClose,
      hasReplay: this.hasReplay,
      replayRecordingId: this.replayRecordingId,
      errorCount: this.errorCount,
      longTaskCount: this.longTaskCount,
      resourceCount: this.resourceCount,
      pendingResource: this.pendingResource,
      sessionId: this.sessionId,
      viewName: this.viewName,
      viewId: this.viewId,
      viewReferrer: this.viewReferrer,
      actionName: this.actionName,
      actionType: this.actionType,
      extraAttr: extraAttrObj,
      collectType: this.collectType
    };
  }

  /**
   * Create an ActionBean from a JSON object
   * @param json JSON object
   * @returns ActionBean
   */
  public static fromJSON(json: ActionBeanJSON): ActionBean {
    const actionBean = new ActionBean(json.id, json.actionName, json.actionType, json.startTime || Utils.getCurrentNanoTime());
    actionBean.actionDuration = json.actionDuration || 0;
    actionBean.isClose = json.isClose || false;
    actionBean.hasReplay = json.hasReplay === true;
    actionBean.replayRecordingId = json.replayRecordingId;
    actionBean.errorCount = json.errorCount || 0;
    actionBean.longTaskCount = json.longTaskCount || 0;
    actionBean.resourceCount = json.resourceCount || 0;
    actionBean.pendingResource = json.pendingResource || 0;
    actionBean.sessionId = json.sessionId || "";
    actionBean.collectType = json.collectType ? parseCollectType(json.collectType) : null;
    actionBean.viewName = json.viewName || "";
    actionBean.viewId = json.viewId || "";
    actionBean.viewReferrer = json.viewReferrer || "";
    
    if (json.extraAttr) {
      actionBean.extraAttr.clear();
      const keys = ActionBean.getObjectKeys(json.extraAttr);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        actionBean.extraAttr.set(key, json.extraAttr[key] as object);
      }
    }
    
    return actionBean;
  }

  /**
   * Clone the object
   * @returns ActionBean
   */
  public clone(): ActionBean {
    const cloned = new ActionBean(this.id, this.actionName, this.actionType, this.startTime);
    cloned.actionDuration = this.actionDuration;
    cloned.isClose = this.isClose;
    cloned.hasReplay = this.hasReplay;
    cloned.replayRecordingId = this.replayRecordingId;
    cloned.errorCount = this.errorCount;
    cloned.longTaskCount = this.longTaskCount;
    cloned.resourceCount = this.resourceCount;
    cloned.pendingResource = this.pendingResource;
    cloned.sessionId = this.sessionId;
    cloned.collectType = this.collectType;
    cloned.viewName = this.viewName;
    cloned.viewId = this.viewId;
    cloned.viewReferrer = this.viewReferrer;
    cloned.extraAttr = new Map(this.extraAttr);
    
    return cloned;
  }

  /**
   * Get tag data
   * @returns Record<string, string>
   */
  public getTags(): Record<string, string> {
    const tags: Record<string, string> = {};
    this.extraAttr.forEach((value, key) => {
      if (typeof value === 'string') {
        tags[key] = value;
      } else {
        tags[key] = String(value);
      }
    });
    return tags;
  }

  /**
   * Get property data
   * @returns Record<string, object>
   */
  public getProperty(): Record<string, object> {
    const property: Record<string, object> = {};
    this.extraAttr.forEach((value, key) => {
      property[key] = value;
    });
    return property;
  }

  /**
   * Get the duration
   * @returns number
   */
  public getDuration(): number {
    return this.actionDuration;
  }

  /**
   * Convert to a string
   * @returns string
   */
  public toString(): string {
    return `ActionBean{id='${this.id}', actionName='${this.actionName}', actionType='${this.actionType}', startTime=${this.startTime}, isClose=${this.isClose}}`;
  }

  /**
   * Get all keys of an object (replaces a for...in loop)
   * @param obj object
   * @returns array of keys
   */
  private static getObjectKeys(obj: Record<string, object>): string[] {
    const keys: string[] = [];
    // Use Object.keys instead of a for...in loop to iterate keys directly
    const objKeys = Object.keys(obj);
    for (let i = 0; i < objKeys.length; i++) {
      keys.push(objKeys[i]);
    }
    return keys;
  }
}
