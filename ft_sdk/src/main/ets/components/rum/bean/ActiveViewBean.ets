import { ViewBean } from '../../db/bean/ViewBean';
import { Utils } from '../../utils/Utils';
import { Constants } from '../../Constants';
import { CollectType } from '../enum/RUMEnums';

/**
 * JSON representation interface for ActiveViewBean
 */
interface ActiveViewBeanJSON {
    id: string;
    viewName: string;
    viewReferrer: string;
    sessionId: string;
    startTime: number;
    loadTime: number;
    isClose: boolean;
    hasReplay: boolean;
    duration: number;
    actionCount: number;
    errorCount: number;
    resourceCount: number;
    longTaskCount: number;
    pendingResourceCount: number;
    property: Record<string, object>;
    tags: Record<string, string>;
    collectType: CollectType;
}

/**
 * Active View Bean - manages the state of the currently active View
 * Active View Bean implementation for HarmonyOS
 */
export class ActiveViewBean {
  private id: string;
  private viewName: string;
  private viewReferrer: string;
  private sessionId: string;
  private startTime: number;
  private startTimeNanoForDuration: number;
  private loadTime: number;
  private isClosed: boolean = false;
  private hasReplay: boolean = false;
  private property: Record<string, object> = {};
  private tags: Record<string, string> = {};
  private extraAttr: Map<string, string | number | boolean> = new Map();
  private collectType: CollectType = CollectType.ALL;
  
  // RUM statistics counters
  private actionCount: number = 0;
  private errorCount: number = 0;
  private resourceCount: number = 0;
  private longTaskCount: number = 0;
  private pendingResourceCount: number = 0;
  
  // Last error time (nanoseconds) - aligned with Android
  private lastErrorTime: number = 0;
  
  // Time spent when view is closed (nanoseconds) - aligned with Android: timeSpent is calculated in close()
  private timeSpent: number = 0;
  
  constructor(viewName: string, viewReferrer: string, loadTime: number, sessionId: string) {
    this.id = Utils.generateUUID();
    this.viewName = viewName || "";
    this.viewReferrer = viewReferrer || Constants.VIEW_NAME_ROOT;
    this.sessionId = sessionId || "";
    this.startTime = Utils.getCurrentNanoTime(); // Nanosecond timestamp 
    this.startTimeNanoForDuration = Utils.getMonotonicNanoTime();
    this.loadTime = loadTime || -1;
  }
  
  /**
   * Get view ID
   */
  public getId(): string {
    return this.id;
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
    this.viewReferrer = viewReferrer || Constants.VIEW_NAME_ROOT;
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
    this.startTimeNanoForDuration += startTime - this.startTime;
    this.startTime = startTime;
  }
  
  /**
   * Get load time
   */
  public getLoadTime(): number {
    return this.loadTime;
  }
  
  /**
   * Set load time
   */
  public setLoadTime(loadTime: number): void {
    this.loadTime = loadTime;
  }
  
  /**
   * Check if view is closed
   */
  public isClose(): boolean {
    return this.isClosed;
  }
  
  /**
   * Close view
   * Aligned with Android: calculate timeSpent when closing
   */
  public close(): void {
    this.isClosed = true;
    this.timeSpent = this.getDuration();
  }

  /** Close a synthetic launch View using the measured launch duration. */
  public closeWithTimeSpent(duration: number): void {
    this.isClosed = true;
    this.timeSpent = Math.max(0, duration);
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
   * Get properties
   */
  public getProperty(): Record<string, object> {
    return this.property;
  }
  
  /**
   * Set properties
   */
  public setProperty(property: Record<string, object>): void {
    this.property = property || {};
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
  
  /**
   * Get collect type
   */
  public getCollectType(): CollectType {
    return this.collectType;
  }
  
  /**
   * Set collect type
   */
  public setCollectType(collectType: CollectType): void {
    this.collectType = collectType;
  }
  
  // Statistics counter methods
  
  /**
   * Get action count
   */
  public getActionCount(): number {
    return this.actionCount;
  }
  
  /**
   * Increment action count
   */
  public increaseActionCount(): void {
    this.actionCount++;
  }
  
  /**
   * Get error count
   */
  public getErrorCount(): number {
    return this.errorCount;
  }
  
  /**
   * Increment error count
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
   * Increment resource count
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
   * Increment long task count
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
   * Increment pending resource count
   */
  public increasePendingResourceCount(): void {
    this.pendingResourceCount++;
  }
  
  /**
   * Decrement pending resource count
   */
  public decreasePendingResourceCount(): void {
    if (this.pendingResourceCount > 0) {
      this.pendingResourceCount--;
    }
  }
  
  // Monitor data methods
  
  /**
   * Set battery current max
   */
  public setBatteryCurrentMax(value: number): void {
    this.extraAttr.set("battery_current_max", value);
  }
  
  /**
   * Set battery current average
   */
  public setBatteryCurrentAvg(value: number): void {
    this.extraAttr.set("battery_current_avg", value);
  }
  
  /**
   * Set CPU tick count
   */
  public setCpuTickCount(value: number): void {
    this.extraAttr.set("cpu_tick_count", value);
  }
  
  /**
   * Set CPU tick count per second
   */
  public setCpuTickCountPerSecond(value: number): void {
    this.extraAttr.set("cpu_tick_count_per_second", value);
  }
  
  /**
   * Set FPS minimum
   */
  public setFpsMini(value: number): void {
    this.extraAttr.set("fps_mini", value);
  }
  
  /**
   * Set FPS average
   */
  public setFpsAvg(value: number): void {
    this.extraAttr.set("fps_avg", value);
  }
  
  /**
   * Set memory maximum
   */
  public setMemoryMax(value: number): void {
    this.extraAttr.set("memory_max", value);
  }
  
  /**
   * Set memory average
   */
  public setMemoryAvg(value: number): void {
    this.extraAttr.set("memory_avg", value);
  }
  
  /**
   * Get view duration (nanoseconds)
   * Aligned with Android: returns duration in nanoseconds
   */
  public getDuration(): number {
    return Math.max(0, Utils.getMonotonicNanoTime() - this.startTimeNanoForDuration);
  }
  
  /**
   * Set last error time - aligned with Android: ActiveViewBean.lastErrorTime
   * @param lastErrorTime Last error time in nanoseconds
   */
  public setLastErrorTime(lastErrorTime: number): void {
    this.lastErrorTime = lastErrorTime;
  }

  /**
   * Get last error time - aligned with Android: ActiveViewBean.lastErrorTime
   * @returns Last error time in nanoseconds
   */
  public getLastErrorTime(): number {
    return this.lastErrorTime;
  }

  /**
   * Convert to ViewBean
   */
  public convertToViewBean(): ViewBean {
    const viewBean = new ViewBean(this.id, this.viewName, this.startTime);
    viewBean.setViewReferrer(this.viewReferrer);
    viewBean.setSessionId(this.sessionId);
    viewBean.setCollectType(this.collectType);
    viewBean.setMonotonicStartTime(this.startTimeNanoForDuration);
    viewBean.setViewLoadTime(this.loadTime);
    viewBean.setIsClose(this.isClosed);
    viewBean.setActionCount(this.actionCount);
    viewBean.setErrorCount(this.errorCount);
    viewBean.setResourceCount(this.resourceCount);
    viewBean.setLongTaskCount(this.longTaskCount);
    viewBean.setLastErrorTime(this.lastErrorTime); // Aligned with Android: bean.lastErrorTime = this.lastErrorTime;
    viewBean.setProperty(this.property);
    viewBean.setTags(this.tags);
    
    // Set monitor data from extraAttr
    const batteryCurrentMax = this.extraAttr.get("battery_current_max");
    if (typeof batteryCurrentMax === 'number') {
      viewBean.setBatteryCurrentMax(batteryCurrentMax);
    }
    
    const batteryCurrentAvg = this.extraAttr.get("battery_current_avg");
    if (typeof batteryCurrentAvg === 'number') {
      viewBean.setBatteryCurrentAvg(batteryCurrentAvg);
    }
    
    const cpuTickCount = this.extraAttr.get("cpu_tick_count");
    if (typeof cpuTickCount === 'number') {
      viewBean.setCpuTickCount(cpuTickCount);
    }
    
    const cpuTickCountPerSecond = this.extraAttr.get("cpu_tick_count_per_second");
    if (typeof cpuTickCountPerSecond === 'number') {
      viewBean.setCpuTickCountPerSecond(cpuTickCountPerSecond);
    }
    
    const fpsMini = this.extraAttr.get("fps_mini");
    if (typeof fpsMini === 'number') {
      viewBean.setFpsMini(fpsMini);
    }
    
    const fpsAvg = this.extraAttr.get("fps_avg");
    if (typeof fpsAvg === 'number') {
      viewBean.setFpsAvg(fpsAvg);
    }
    
    const memoryMax = this.extraAttr.get("memory_max");
    if (typeof memoryMax === 'number') {
      viewBean.setMemoryMax(memoryMax);
    }
    
    const memoryAvg = this.extraAttr.get("memory_avg");
    if (typeof memoryAvg === 'number') {
      viewBean.setMemoryAvg(memoryAvg);
    }
    
    // Set timeSpent: use stored value if closed, otherwise calculate current duration
    // Aligned with Android: if closed, use stored timeSpent; otherwise calculate on-the-fly
    if (this.isClosed) {
      viewBean.setTimeSpent(this.timeSpent);
    } else {
      // An open View uses its current duration.
      viewBean.setTimeSpent(this.getDuration());
    }
    
    return viewBean;
  }
  
  /**
   * Convert to JSON
   */
  public toJSON(): ActiveViewBeanJSON {
    const result: ActiveViewBeanJSON = {
      id: this.id,
      viewName: this.viewName,
      viewReferrer: this.viewReferrer,
      sessionId: this.sessionId,
      startTime: this.startTime,
      loadTime: this.loadTime,
      isClose: this.isClosed,
      hasReplay: this.hasReplay,
      duration: this.getDuration(),
      actionCount: this.actionCount,
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

  /**
   * Set property data to extra attributes
   * @param property Property data
   */
  public setPropertyToExtraAttr(property: Record<string, object>): void {
    const keys = Object.keys(property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = property[key];
      // Convert object to string representation for storage
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
        this.extraAttr.set(key, value);
      } else {
        this.extraAttr.set(key, JSON.stringify(value));
      }
    }
  }

  /**
   * Set tag data to extra attributes
   * @param tags Tag data
   */
  public setTagsToExtraAttr(tags: Record<string, string>): void {
    const keys = Object.keys(tags);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      this.extraAttr.set(key, tags[key]);
    }
  }

}
