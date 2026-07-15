/**
 * HarmonyOS SDK RUM view data model class
 * ViewBean implementation for HarmonyOS
 */
import { StringUtils } from '../../utils/StringUtils';
import { Utils } from '../../utils/Utils';
import { Constants } from '../../Constants';

/**
 * ViewBean JSON interface
 */
export interface ViewBeanJSON {
  id: string;
  viewName: string;
  viewReferrer: string;
  startTime: number;
  isClose: boolean;
  sessionId: string;
  actionCount: number;
  errorCount: number;
  longTaskCount: number;
  viewLoadTime: number;
  timeSpent: number;
  resourceCount: number;
  pendingResource: number;
  dataUpdateTime: number;
  dataUploadTime: number;
  viewUpdateTime: number;
  extraAttr: Record<string, object>;
  property?: Record<string, object>;
  tags?: Record<string, string>;
}

/**
 * Monitor data value object interface
 */
interface MonitorValue {
  value: string;
}

/**
 * RUM view data model
 * Used to store detailed data of page views
 */
export class ViewBean {
  /**
   * View ID
   */
  private id: string = "";

  /**
   * View name
   */
  private viewName: string = "";

  /**
   * View source
   */
  private viewReferrer: string = "";

  /**
   * Start time
   */
  private startTime: number = 0;

  /**
   * Whether closed
   */
  private isClose: boolean = false;

  /**
   * Session ID
   */
  private sessionId: string = "";

  /**
   * Action count
   */
  private actionCount: number = 0;

  /**
   * Error count
   */
  private errorCount: number = 0;

  /**
   * Long task count
   */
  private longTaskCount: number = 0;

  /**
   * View load time
   */
  private viewLoadTime: number = 0;

  /**
   * View stay time
   */
  private timeSpent: number = 0;

  /**
   * Resource count
   */
  private resourceCount: number = 0;

  /**
   * Pending resources
   */
  private pendingResource: number = 0;

  /**
   * Data update time
   */
  private dataUpdateTime: number = 0;

  /**
   * Data upload time
   */
  private dataUploadTime: number = 0;

  /**
   * View update count (counter) - aligned with Android
   * Used to mark delayed Resource data
   */
  private viewUpdateTime: number = 1;

  /**
   * Last error time (nanoseconds) - aligned with Android
   * Used to mark when the last error occurred in this view
   */
  private lastErrorTime: number = 0;

  /**
   * Extended properties
   */
  private extraAttr: Map<string, object> = new Map();

  /**
   * View custom properties
   */
  private property: Record<string, object> = {};

  /**
   * View dynamic tags
   */
  private tags: Record<string, string> = {};

  /**
   * Constructor
   * @param id View ID
   * @param viewName View name
   * @param startTime Start time in nanoseconds (must be provided at creation time)
   * Note: startTime must be provided in constructor to ensure timestamp is set only once when view is created, and remains immutable.
   */
  constructor(id: string, viewName: string, startTime: number) {
    this.id = id;
    this.viewName = viewName;
    this.startTime = startTime;
    this.dataUpdateTime = Date.now();
    this.viewUpdateTime = 1; // Counter starts at 1 - aligned with Android
  }

  // Getter and Setter methods
  public getId(): string { return this.id; }
  public setId(id: string): void { this.id = id; }

  public getViewName(): string { return this.viewName; }
  public setViewName(viewName: string): void { this.viewName = viewName; }

  public getViewReferrer(): string { return this.viewReferrer; }
  public setViewReferrer(viewReferrer: string): void { this.viewReferrer = viewReferrer; }

  public getStartTime(): number { return this.startTime; }

  public getIsClose(): boolean { return this.isClose; }
  public setIsClose(isClose: boolean): void { this.isClose = isClose; }

  public getSessionId(): string { return this.sessionId; }
  public setSessionId(sessionId: string): void { this.sessionId = sessionId; }

  public getActionCount(): number { return this.actionCount; }
  public setActionCount(actionCount: number): void { this.actionCount = actionCount; }

  public getErrorCount(): number { return this.errorCount; }
  public setErrorCount(errorCount: number): void { this.errorCount = errorCount; }

  public getLongTaskCount(): number { return this.longTaskCount; }
  public setLongTaskCount(longTaskCount: number): void { this.longTaskCount = longTaskCount; }

  public getViewLoadTime(): number { return this.viewLoadTime; }
  public setViewLoadTime(viewLoadTime: number): void { this.viewLoadTime = viewLoadTime; }

  public getTimeSpent(): number { return this.timeSpent; }
  public setTimeSpent(timeSpent: number): void { this.timeSpent = timeSpent; }

  public getResourceCount(): number { return this.resourceCount; }
  public setResourceCount(resourceCount: number): void { this.resourceCount = resourceCount; }

  public getPendingResource(): number { return this.pendingResource; }
  public setPendingResource(pendingResource: number): void { this.pendingResource = pendingResource; }

  public getDataUpdateTime(): number { return this.dataUpdateTime; }
  public setDataUpdateTime(dataUpdateTime: number): void { this.dataUpdateTime = dataUpdateTime; }

  public getDataUploadTime(): number { return this.dataUploadTime; }
  public setDataUploadTime(dataUploadTime: number): void { this.dataUploadTime = dataUploadTime; }

  public getViewUpdateTime(): number { return this.viewUpdateTime; }
  public setViewUpdateTime(viewUpdateTime: number): void { this.viewUpdateTime = viewUpdateTime; }

  /**
   * Get extended properties
   * @returns Map<string, object>
   */
  public getExtraAttr(): Map<string, object> {
    return this.extraAttr;
  }

  /**
   * Set extended properties
   * @param extraAttr extended properties
   */
  public setExtraAttr(extraAttr: Map<string, object>): void {
    this.extraAttr = extraAttr;
  }

  /**
   * Add an extended property
   * @param key key
   * @param value value
   */
  public addExtraAttr(key: string, value: object): void {
    this.extraAttr.set(key, value);
  }
  
  // Monitor data methods
  
  /**
   * Set battery current max
   */
  public setBatteryCurrentMax(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("battery_current_max", monitorValue);
  }
  
  /**
   * Set battery current average
   */
  public setBatteryCurrentAvg(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("battery_current_avg", monitorValue);
  }
  
  /**
   * Set CPU tick count
   */
  public setCpuTickCount(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("cpu_tick_count", monitorValue);
  }
  
  /**
   * Set CPU tick count per second
   */
  public setCpuTickCountPerSecond(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("cpu_tick_count_per_second", monitorValue);
  }
  
  /**
   * Set FPS minimum
   */
  public setFpsMini(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("fps_mini", monitorValue);
  }
  
  /**
   * Set FPS average
   */
  public setFpsAvg(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("fps_avg", monitorValue);
  }
  
  /**
   * Set memory maximum
   */
  public setMemoryMax(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("memory_max", monitorValue);
  }
  
  /**
   * Set memory average
   */
  public setMemoryAvg(value: number): void {
    const monitorValue: MonitorValue = { value: String(value) };
    this.extraAttr.set("memory_avg", monitorValue);
  }

  /**
   * Get the extended properties JSON string
   * @returns string
   */
  public getAttrJsonString(): string {
    try {
      const obj: Record<string, object> = {};
      this.extraAttr.forEach((value, key) => {
        obj[key] = value;
      });
      obj[Constants.KEY_RUM_PROPERTY] = this.property;
      obj[Constants.KEY_RUM_TAGS] = this.tags;
      return JSON.stringify(obj);
    } catch (error) {
      return "{}";
    }
  }

  /**
   * Set the extended properties JSON string
   * @param jsonString JSON string
   */
  public setAttrJsonString(jsonString: string): void {
    try {
      if (StringUtils.isNotEmpty(jsonString)) {
        const obj = JSON.parse(jsonString) as Record<string, object>;
        this.extraAttr.clear();
        this.property = {};
        this.tags = {};
        const keys = ViewBean.getObjectKeys(obj);
        for (let i = 0; i < keys.length; i++) {
          const key = keys[i];
          const value = obj[key] as object;
          if (key === Constants.KEY_RUM_PROPERTY && value && typeof value === 'object') {
            this.property = value as Record<string, object>;
          } else if (key === Constants.KEY_RUM_TAGS && value && typeof value === 'object') {
            const tagsObj = value as Record<string, object>;
            const tagKeys = ViewBean.getObjectKeys(tagsObj);
            for (let j = 0; j < tagKeys.length; j++) {
              const tagKey = tagKeys[j];
              this.tags[tagKey] = String(tagsObj[tagKey]);
            }
          } else {
            this.extraAttr.set(key, value);
          }
        }
      }
    } catch (error) {
      // Keep the original properties if parsing fails
    }
  }

  /**
   * Close the view
   */
  public close(): void {
    this.isClose = true;
    // Aligned with Android: timeSpent uses nanoseconds
    this.timeSpent = Utils.getCurrentNanoTime() - this.startTime;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment the action count
   */
  public incrementActionCount(): void {
    this.actionCount++;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment the error count
   */
  public incrementErrorCount(): void {
    this.errorCount++;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment the long task count
   */
  public incrementLongTaskCount(): void {
    this.longTaskCount++;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment the resource count
   */
  public incrementResourceCount(): void {
    this.resourceCount++;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment the pending resource count
   */
  public incrementPendingResource(): void {
    this.pendingResource++;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Decrement the pending resource count
   */
  public decrementPendingResource(): void {
    if (this.pendingResource > 0) {
      this.pendingResource--;
      this.dataUpdateTime = Date.now();
    }
  }

  /**
   * Calculate the view load time
   * Aligned with Android: loadTime uses nanoseconds
   */
  public calculateLoadTime(): void {
    // Aligned with Android: viewLoadTime uses nanoseconds
    this.viewLoadTime = Utils.getCurrentNanoTime() - this.startTime;
    this.dataUpdateTime = Date.now();
  }

  /**
   * Calculate the time spent on the view
   * Aligned with Android: timeSpent uses nanoseconds
   */
  public calculateTimeSpent(): void {
    if (!this.isClose) {
      // Aligned with Android: timeSpent uses nanoseconds
      this.timeSpent = Utils.getCurrentNanoTime() - this.startTime;
      this.dataUpdateTime = Date.now();
    }
  }

  /**
   * Mark the data as uploaded
   */
  public markAsUploaded(): void {
    this.dataUploadTime = Date.now();
    this.dataUpdateTime = Date.now();
  }

  /**
   * Increment view update count - aligned with Android
   * Used to mark delayed Resource data
   */
  public updateView(): void {
    this.viewUpdateTime = this.viewUpdateTime + 1; // Increment counter - aligned with Android
    this.dataUpdateTime = Date.now();
  }

  /**
   * Set last error time - aligned with Android: ViewBean.setLastErrorTime(long lastErrorTime)
   * @param lastErrorTime Last error time in nanoseconds
   */
  public setLastErrorTime(lastErrorTime: number): void {
    this.lastErrorTime = lastErrorTime;
  }

  /**
   * Get last error time - aligned with Android: ViewBean.getLastErrorTime()
   * @returns Last error time in nanoseconds
   */
  public getLastErrorTime(): number {
    return this.lastErrorTime;
  }

  /**
   * Validate data integrity
   * @returns boolean
   */
  public isValid(): boolean {
    return StringUtils.isNotEmpty(this.id) && 
           StringUtils.isNotEmpty(this.viewName) &&
           this.startTime > 0;
  }

  /**
   * Convert to a JSON object
   * @returns ViewBeanJSON
   */
  public toJSON(): ViewBeanJSON {
    const extraAttrObj: Record<string, object> = {};
    this.extraAttr.forEach((value, key) => {
      extraAttrObj[key] = value;
    });
    
    return {
      id: this.id,
      viewName: this.viewName,
      viewReferrer: this.viewReferrer,
      startTime: this.startTime,
      isClose: this.isClose,
      sessionId: this.sessionId,
      actionCount: this.actionCount,
      errorCount: this.errorCount,
      longTaskCount: this.longTaskCount,
      viewLoadTime: this.viewLoadTime,
      timeSpent: this.timeSpent,
      resourceCount: this.resourceCount,
      pendingResource: this.pendingResource,
      dataUpdateTime: this.dataUpdateTime,
      dataUploadTime: this.dataUploadTime,
      viewUpdateTime: this.viewUpdateTime,
      extraAttr: extraAttrObj,
      property: this.property,
      tags: this.tags
    };
  }

  /**
   * Create a ViewBean from a JSON object
   * @param json JSON object
   * @returns ViewBean
   */
  public static fromJSON(json: ViewBeanJSON): ViewBean {
    const viewBean = new ViewBean(json.id, json.viewName, json.startTime || Utils.getCurrentNanoTime());
    viewBean.viewReferrer = json.viewReferrer || "";
    viewBean.isClose = json.isClose || false;
    viewBean.sessionId = json.sessionId || "";
    viewBean.actionCount = json.actionCount || 0;
    viewBean.errorCount = json.errorCount || 0;
    viewBean.longTaskCount = json.longTaskCount || 0;
    viewBean.viewLoadTime = json.viewLoadTime || 0;
    viewBean.timeSpent = json.timeSpent || 0;
    viewBean.resourceCount = json.resourceCount || 0;
    viewBean.pendingResource = json.pendingResource || 0;
    viewBean.dataUpdateTime = json.dataUpdateTime || Date.now();
    viewBean.dataUploadTime = json.dataUploadTime || 0;
    viewBean.viewUpdateTime = json.viewUpdateTime || 1;
    
    if (json.extraAttr) {
      viewBean.extraAttr.clear();
      const keys = ViewBean.getObjectKeys(json.extraAttr);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        viewBean.extraAttr.set(key, json.extraAttr[key] as object);
      }
    }
    if (json.property) {
      viewBean.property = json.property;
    }
    if (json.tags) {
      viewBean.tags = json.tags;
    }
    
    return viewBean;
  }

  /**
   * Clone the object
   * @returns ViewBean
   */
  public clone(): ViewBean {
    const cloned = new ViewBean(this.id, this.viewName, this.startTime);
    cloned.viewReferrer = this.viewReferrer;
    cloned.isClose = this.isClose;
    cloned.sessionId = this.sessionId;
    cloned.actionCount = this.actionCount;
    cloned.errorCount = this.errorCount;
    cloned.longTaskCount = this.longTaskCount;
    cloned.viewLoadTime = this.viewLoadTime;
    cloned.timeSpent = this.timeSpent;
    cloned.resourceCount = this.resourceCount;
    cloned.pendingResource = this.pendingResource;
    cloned.dataUpdateTime = this.dataUpdateTime;
    cloned.dataUploadTime = this.dataUploadTime;
    cloned.viewUpdateTime = this.viewUpdateTime;
    cloned.extraAttr = new Map(this.extraAttr);
    cloned.property = this.property;
    cloned.tags = this.tags;
    
    return cloned;
  }

  /**
   * Get tag data
   * @returns Record<string, string>
   */
  public getTags(): Record<string, string> {
    const tags: Record<string, string> = {};
    const keys = Object.keys(this.tags);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      tags[key] = this.tags[key];
    }
    return tags;
  }

  /**
   * Set tag data
   * @param tags tag data
   */
  public setTags(tags: Record<string, string>): void {
    this.tags = tags || {};
  }

  /**
   * Get property data
   * @returns Record<string, object>
   */
  public getProperty(): Record<string, object> {
    const property: Record<string, object> = {};
    const keys = Object.keys(this.property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      property[key] = this.property[key];
    }
    return property;
  }

  /**
   * Set property data
   * @param property property data
   */
  public setProperty(property: Record<string, object>): void {
    this.property = property || {};
  }

  /**
   * Convert to a string
   * @returns string
   */
  public toString(): string {
    return `ViewBean{id='${this.id}', viewName='${this.viewName}', startTime=${this.startTime}, isClose=${this.isClose}}`;
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
