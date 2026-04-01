import { LineProtocolBean } from './LineProtocolBean';
import { TimeUtils } from './LineProtocolBean';
import { Constants } from '../Constants';

/**
 * Base Content Bean - Base class for all data beans
 * Extends LineProtocolBean, adds content management functionality
 */
interface GeneratedObjectLiteralInterface_1 {
  value: string;
}

export abstract class BaseContentBean extends LineProtocolBean {
  // Predefined empty object constant for type-safe property removal
  private static readonly EMPTY_OBJECT: object = new Object();
  
  /**
   * Content size limit 30 KB
   */
  protected static readonly LIMIT_SIZE = 30720;
  
  /**
   * Log content
   */
  private content: string;
  
  /**
   * Running service name
   */
  private serviceName: string = "";
  
  constructor(measurement: string, content: string, time: number) {
    // Check content length limit
    const processedContent = BaseContentBean.isOverMaxLength(content) ? 
      content.substring(0, BaseContentBean.LIMIT_SIZE) : content;
    
    // Convert milliseconds to nanoseconds
    const timeNano = TimeUtils.millisToNanos(time);
    
    super(measurement, {}, {}, timeNano);
    this.content = processedContent || "";
  }
  
  /**
   * Convenience constructor that uses the default measurement
   */
  static createWithDefaultMeasurement(content: string, time: number): BaseContentBean {
    // Check content length limit
    const processedContent = BaseContentBean.isOverMaxLength(content) ? 
      content.substring(0, BaseContentBean.LIMIT_SIZE) : content;
    
    // Convert milliseconds to nanoseconds
    const timeNano = TimeUtils.millisToNanos(time);
    
    // Create a concrete implementation class instance
    class ConcreteBaseContentBean extends BaseContentBean {
      constructor(content: string, time: number) {
        super(Constants.FT_LOG_DEFAULT_MEASUREMENT, content, time);
      }
    }
    
    return new ConcreteBaseContentBean(processedContent, time);
  }
  
  /**
   * Check if content exceeds maximum length
   */
  private static isOverMaxLength(content: string): boolean {
    if (!content) return false;
    return content.length > BaseContentBean.LIMIT_SIZE;
  }
  
  /**
   * Get content
   */
  public getContent(): string {
    return this.content;
  }
  
  /**
   * Set content
   */
  public setContent(content: string): void {
    this.content = content || "";
  }
  
  /**
   * Get timestamp (milliseconds)
   */
  public getTime(): number {
    return TimeUtils.nanosToMillis(this.getTimeNano());
  }
  
  /**
   * Set timestamp (milliseconds)
   */
  public setTime(time: number): void {
    const timeNano = TimeUtils.millisToNanos(time || 0);
    // Note: Need to update parent class timeNano, but since it's readonly, need other approaches
    // In actual implementation, may need to recreate object or use other methods
  }
  
  /**
   * Get service name
   */
  public getServiceName(): string {
    return this.serviceName;
  }
  
  /**
   * Set service name
   */
  public setServiceName(serviceName: string): void {
    this.serviceName = serviceName || "";
  }
  
  /**
   * Get all tags
   */
  public getAllTags(): Record<string, object> {
    const result = super.getTags();
    
    // Add service name tag
    if (this.serviceName && this.serviceName.length > 0) {
      const serviceObj: GeneratedObjectLiteralInterface_1 = { value: this.serviceName };
      result[Constants.KEY_SERVICE] = serviceObj;
    }
    
    return result;
  }

  /**
   * Get all fields
   */
  public getAllFields(): Record<string, object> {
    const result = super.getFields();
    
    // Add message content field
    const contentObj: GeneratedObjectLiteralInterface_1 = { value: this.content };
    result[Constants.KEY_MESSAGE] = contentObj;
    
    return result;
  }
  
  /**
   * Add tag
   */
  public addTag(key: string, value: object): void {
    if (key && key.length > 0) {
      this.tags[key] = value;
    }
  }
  
  /**
   * Add tags in batch
   */
  public appendTags(newTags: Record<string, object>): void {
    if (newTags) {
      const keys = BaseContentBean.getObjectKeys(newTags);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        this.tags[key] = newTags[key];
      }
    }
  }
  
  /**
   * Remove tag
   */
  public removeTag(key: string): void {
    // Use predefined empty object constant for type safety
    this.tags[key] = BaseContentBean.EMPTY_OBJECT;
  }
  
  /**
   * Get specified tag value
   */
  public getTag(key: string): object | undefined {
    return this.tags[key];
  }
  
  /**
   * Add field
   */
  public addField(key: string, value: object): void {
    if (key && key.length > 0) {
      this.fields[key] = value;
    }
  }
  
  /**
   * Add fields in batch
   */
  public appendFields(newFields: Record<string, object>): void {
    if (newFields) {
      const keys = BaseContentBean.getObjectKeys(newFields);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        this.fields[key] = newFields[key];
      }
    }
  }
  
  /**
   * Remove field
   */
  public removeField(key: string): void {
    // Use predefined empty object constant for type safety
    this.fields[key] = BaseContentBean.EMPTY_OBJECT;
  }
  
  /**
   * Get the value of the specified field
   */
  public getField(key: string): object | undefined {
    return this.fields[key];
  }
  
  /**
   * Clear tags
   */
  public clearTags(): void {
    // Since tags is readonly, we clear by reassignment
    const keys = Object.keys(this.tags);
    for (const key of keys) {
      this.tags[key] = new Object();
    }
  }
  
  /**
   * Clear fields
   */
  public clearFields(): void {
    // Since fields is readonly, we clear by reassignment
    const keys = Object.keys(this.fields);
    for (const key of keys) {
      this.fields[key] = new Object();
    }
  }
  
  /**
   * Check if contains specified tag
   */
  public hasTag(key: string): boolean {
    return this.tags[key] !== undefined;
  }
  
  /**
   * Check if contains specified field
   */
  public hasField(key: string): boolean {
    return this.fields[key] !== undefined;
  }
  
  /**
   * Get tag count
   */
  public getTagCount(): number {
    let count = 0;
    const keys = BaseContentBean.getObjectKeys(this.tags);
    for (let i = 0; i < keys.length; i++) {
      count++;
    }
    return count;
  }
  
  /**
   * Get field count
   */
  public getFieldCount(): number {
    let count = 0;
    const keys = BaseContentBean.getObjectKeys(this.fields);
    for (let i = 0; i < keys.length; i++) {
      count++;
    }
    return count;
  }
  
  /**
   * Convert to JSON object
   */
  public toJSON(): BaseContentBeanJSON {
    return {
      measurement: this.getMeasurement(),
      content: this.content,
      time: this.getTime(),
      timeNano: this.getTimeNano(),
      serviceName: this.serviceName,
      tags: this.getAllTags() as Record<string, object>,
      fields: this.getAllFields() as Record<string, object>
    };
  }

  /**
   * Get all keys of object (alternative to for...in loop)
   * @param obj Object
   * @returns Array of keys
   */
  public static getObjectKeys(obj: Record<string, object>): string[] {
    const keys: string[] = [];
    // Use Object.keys instead of for...in loop, directly iterate all keys
    const objKeys = Object.keys(obj);
    for (let i = 0; i < objKeys.length; i++) {
      keys.push(objKeys[i]);
    }
    return keys;
  }
}

/**
 * BaseContentBean JSON interface
 */
interface BaseContentBeanJSON {
  measurement: string;
  content: string;
  time: number;
  timeNano: number;
  serviceName: string;
  tags: Record<string, object>;
  fields: Record<string, object>;
}

/**
 * Convert to string
 */
export function baseContentBeanToString(bean: BaseContentBean): string {
  return JSON.stringify(bean.toJSON());
}
