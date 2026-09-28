import { ActionBean } from '../../db/bean/ActionBean';
import { Utils } from '../../utils/Utils';
import { CollectType } from '../enum/RUMEnums';

/**
 * JSON representation interface for ActiveActionBean
 */
interface ActiveActionBeanJSON {
    id: string;
    actionName: string;
    actionType: string;
    sessionId: string;
    viewId: string;
    viewName: string;
    viewReferrer: string;
    startTime: number;
    duration: number;
    isClose: boolean;
    needWaitAction: boolean;
    hasReplay: boolean;
    errorCount: number;
    resourceCount: number;
    longTaskCount: number;
    pendingResourceCount: number;
    property: Record<string, object>;
    tags: Record<string, string>;
    collectType: CollectType;
}

/**
 * Active Action Bean - manages the state of the currently active Action
 * Active Action Bean implementation for HarmonyOS
 */
export class ActiveActionBean {
  // Action timeout constants (nanoseconds) - aligned with Android
  public static readonly ACTION_NORMAL_TIME_OUT = 100000000; // 100ms (nanoseconds) - same as Android
  public static readonly ACTION_NEED_WAIT_TIME_OUT = 5000000000; // 5 seconds (nanoseconds) - same as Android
  
  private id: string;
  private actionName: string;
  private actionType: string;
  private sessionId: string;
  private viewId: string;
  private viewName: string;
  private viewReferrer: string;
  private startTime: number;
  private duration: number = -1;
  private isClose: boolean = false;
  private needWaitAction: boolean = false;
  private hasReplay: boolean = false;
  private property: Record<string, object> = {};
  private tags: Record<string, string> = {};
  private collectType: CollectType = CollectType.ALL;
  
  // RUM statistics counters
  private errorCount: number = 0;
  private resourceCount: number = 0;
  private longTaskCount: number = 0;
  private pendingResourceCount: number = 0;
  
  constructor(
    actionName: string,
    actionType: string,
    sessionId: string,
    viewId: string,
    viewName: string,
    viewReferrer: string,
    needWaitAction: boolean = false
  ) {
    this.id = Utils.generateUUID();
    this.actionName = actionName || "";
    this.actionType = actionType || "";
    this.sessionId = sessionId || "";
    this.viewId = viewId || "";
    this.viewName = viewName || "";
    this.viewReferrer = viewReferrer || "";
    this.startTime = Utils.getCurrentNanoTime(); // Nanosecond timestamp - aligned with Android
    this.needWaitAction = needWaitAction;
  }
  
  /**
   * Get action ID
   */
  public getId(): string {
    return this.id;
  }
  
  /**
   * Get action name
   */
  public getActionName(): string {
    return this.actionName;
  }
  
  /**
   * Set action name
   */
  public setActionName(actionName: string): void {
    this.actionName = actionName || "";
  }
  
  /**
   * Get action type
   */
  public getActionType(): string {
    return this.actionType;
  }
  
  /**
   * Set action type
   */
  public setActionType(actionType: string): void {
    this.actionType = actionType || "";
  }
  
  /**
   * Get session ID
   */
  public getSessionId(): string {
    return this.sessionId;
  }
  
  /**
   * Set session ID
   */
  public setSessionId(sessionId: string): void {
    this.sessionId = sessionId || "";
  }

  public getCollectType(): CollectType {
    return this.collectType;
  }

  public setCollectType(collectType: CollectType): void {
    this.collectType = collectType;
  }
  
  /**
   * Get view ID
   */
  public getViewId(): string {
    return this.viewId;
  }
  
  /**
   * Set view ID
   */
  public setViewId(viewId: string): void {
    this.viewId = viewId || "";
  }
  
  /**
   * Get view name
   */
  public getViewName(): string {
    return this.viewName;
  }
  
  /**
   * Set view name
   */
  public setViewName(viewName: string): void {
    this.viewName = viewName || "";
  }
  
  /**
   * Get view referrer
   */
  public getViewReferrer(): string {
    return this.viewReferrer;
  }
  
  /**
   * Set view referrer
   */
  public setViewReferrer(viewReferrer: string): void {
    this.viewReferrer = viewReferrer || "";
  }
  
  /**
   * Get start time
   */
  public getStartTime(): number {
    return this.startTime;
  }
  
  /**
   * Set start time
   */
  public setStartTime(startTime: number): void {
    this.startTime = startTime;
  }
  
  /**
   * Get duration (nanoseconds) - aligned with Android
   */
  public getDuration(): number {
    if (this.duration > 0) {
      return this.duration;
    } else if (this.isClose) {
      // Calculate actual duration
      return Utils.getCurrentNanoTime() - this.startTime;
    } else {
      // Return current duration when not closed
      return Utils.getCurrentNanoTime() - this.startTime;
    }
  }
  
  /**
   * Set duration
   */
  public setDuration(duration: number): void {
    this.duration = duration;
  }
  
  /**
   * Check if action is closed
   */
  public isActionClose(): boolean {
    return this.isClose;
  }
  
  /**
   * Close action (nanoseconds) - aligned with Android
   */
  public close(): void {
    this.isClose = true;
    if (this.duration <= 0) {
      this.duration = Utils.getCurrentNanoTime() - this.startTime;
    }
  }
  
  /**
   * Check if need to wait
   */
  public isNeedWaitAction(): boolean {
    return this.needWaitAction;
  }
  
  /**
   * Set if need to wait
   */
  public setNeedWaitAction(needWaitAction: boolean): void {
    this.needWaitAction = needWaitAction;
  }
  
  /**
   * Check if has replay
   */
  public isHasReplay(): boolean {
    return this.hasReplay;
  }
  
  /**
   * Set replay status
   */
  public setHasReplay(hasReplay: boolean): void {
    this.hasReplay = hasReplay;
  }
  
  /**
   * Get property
   */
  public getProperty(): Record<string, object> {
    return this.property;
  }
  
  /**
   * Set property
   * Aligned with Android: activeAction.getProperty().putAll(property)
   */
  public setProperty(property: Record<string, object>): void {
    if (!property) {
      return;
    }
    // Merge property into existing property (aligned with Android: putAll behavior)
    const propertyKeys = Object.keys(property);
    for (let i = 0; i < propertyKeys.length; i++) {
      const key = propertyKeys[i];
      this.property[key] = property[key];
    }
  }
  
  /**
   * Add property
   */
  public addProperty(key: string, value: object): void {
    this.property[key] = value;
  }
  
  /**
   * Get tags
   */
  public getTags(): Record<string, string> {
    return this.tags;
  }
  
  /**
   * Set tags
   */
  public setTags(tags: Record<string, string>): void {
    this.tags = tags || {};
  }
  
  /**
   * Add tag
   */
  public addTag(key: string, value: string): void {
    this.tags[key] = value;
  }
  
  // Statistics counter methods
  
  /**
   * Get error count
   */
  public getErrorCount(): number {
    return this.errorCount;
  }
  
  /**
   * Increase error count
   */
  public increaseErrorCount(): void {
    this.errorCount++;
  }
  
  /**
   * Get resource count
   */
  public getResourceCount(): number {
    return this.resourceCount;
  }
  
  /**
   * Increase resource count
   */
  public increaseResourceCount(): void {
    this.resourceCount++;
  }
  
  /**
   * Get long task count
   */
  public getLongTaskCount(): number {
    return this.longTaskCount;
  }
  
  /**
   * Increase long task count
   */
  public increaseLongTaskCount(): void {
    this.longTaskCount++;
  }
  
  /**
   * Get pending resource count
   */
  public getPendingResourceCount(): number {
    return this.pendingResourceCount;
  }
  
  /**
   * Increase pending resource count
   */
  public increasePendingResourceCount(): void {
    this.pendingResourceCount++;
  }
  
  /**
   * Decrease pending resource count
   */
  public decreasePendingResourceCount(): void {
    if (this.pendingResourceCount > 0) {
      this.pendingResourceCount--;
    }
  }
  
  /**
   * Check if timeout (nanoseconds) - aligned with Android
   */
  public isTimeout(): boolean {
    const now = Utils.getCurrentNanoTime();
    const elapsed = now - this.startTime;
    
    if (this.needWaitAction) {
      return elapsed > ActiveActionBean.ACTION_NEED_WAIT_TIME_OUT;
    } else {
      return elapsed > ActiveActionBean.ACTION_NORMAL_TIME_OUT;
    }
  }
  
  /**
   * Convert to ActionBean
   */
  public convertToActionBean(): ActionBean {
    const actionBean = new ActionBean(this.id, this.actionName, this.actionType, this.startTime);
    actionBean.setSessionId(this.sessionId);
    actionBean.setCollectType(this.collectType);
    actionBean.setViewId(this.viewId);
    actionBean.setViewName(this.viewName);
    actionBean.setViewReferrer(this.viewReferrer);
    actionBean.setIsClose(this.isClose);
    actionBean.setErrorCount(this.errorCount);
    actionBean.setResourceCount(this.resourceCount);
    actionBean.setLongTaskCount(this.longTaskCount);
    
    // Set duration
    actionBean.setActionDuration(this.getDuration());
    
    // Copy properties to ActionBean's extraAttr (aligned with Android: property is copied to ActionBean)
    if (this.property && Object.keys(this.property).length > 0) {
      const propertyKeys = Object.keys(this.property);
      for (let i = 0; i < propertyKeys.length; i++) {
        const key = propertyKeys[i];
        const value = this.property[key];
        actionBean.addExtraAttr(key, value);
      }
    }
    
    return actionBean;
  }
  
  /**
   * Convert to JSON
   */
  public toJSON(): ActiveActionBeanJSON {
    const result: ActiveActionBeanJSON = {
      id: this.id,
      actionName: this.actionName,
      actionType: this.actionType,
      sessionId: this.sessionId,
      viewId: this.viewId,
      viewName: this.viewName,
      viewReferrer: this.viewReferrer,
      startTime: this.startTime,
      duration: this.getDuration(),
      isClose: this.isClose,
      needWaitAction: this.needWaitAction,
      hasReplay: this.hasReplay,
      errorCount: this.errorCount,
      resourceCount: this.resourceCount,
      longTaskCount: this.longTaskCount,
      pendingResourceCount: this.pendingResourceCount,
      property: this.property,
      tags: this.tags,
      collectType: this.collectType
    };
    return result;
  }
  
  /**
   * Convert to string
   */
  public toString(): string {
    return JSON.stringify(this.toJSON());
  }
}
