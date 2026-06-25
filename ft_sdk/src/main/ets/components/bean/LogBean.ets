import { BaseContentBean } from './BaseContentBean';
import { Status } from './Status';
import { Constants } from '../Constants';

/**
 * Status value interface
 */
interface StatusValue {
  value: string;
}

/**
 * Log object for internal SDK use
 */
export class LogBean extends BaseContentBean {
  /**
   * Log level/status
   */
  private status: string = Status.INFO.name;
  
  /**
   * Extended properties
   */
  private property: Record<string, object> = {};
  
  constructor(content: string, time: number) {
    super(Constants.FT_LOG_DEFAULT_MEASUREMENT, content, time);
  }
  
  /**
   * Get the log status
   */
  public getStatus(): string {
    return this.status;
  }
  
  /**
   * Set the log status
   */
  public setStatus(status: string): void {
    this.status = status;
  }
  
  /**
   * Get extended properties
   */
    public getProperty(): Record<string, object> {
    return this.property;
  }

  /**
   * Set extended properties
   */
  public setProperty(property: Record<string, object>): void {
    this.property = property || {};
  }

  /**
   * Add an extended property
   */
  public addProperty(key: string, value: object): void {
    this.property[key] = value;
  }
  
  /**
   * Remove an extended property
   */
  public removeProperty(key: string): void {
    this.property[key] = new Object();
  }
  
  /**
   * Get all field data in the log
   */
  public override getAllFields(): Record<string, object> {
    const fields = super.getAllFields();
    
    // Add extended properties to the field set
    const keys = BaseContentBean.getObjectKeys(this.property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      fields[key] = this.property[key] as object;
    }
    
    return fields;
  }
  
  /**
   * Get all tag data in the log
   */
  public override getAllTags(): Record<string, object> {
    const tags = super.getAllTags();
    
    // Add the status tag
    const statusValue: StatusValue = { value: this.status };
    tags[Constants.KEY_STATUS] = statusValue;
    
    return tags;
  }
  
  /**
   * Create a copy of the log
   */
  public clone(): LogBean {
    const cloned = new LogBean(this.getContent(), this.getTime());
    cloned.setStatus(this.status);
    const clonedProperty: Record<string, object> = {};
    const keys = BaseContentBean.getObjectKeys(this.property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      clonedProperty[key] = this.property[key];
    }
    cloned.setProperty(clonedProperty);
    
    // Copy tags and fields from the base class
    cloned.appendTags(this.getAllTags());
    cloned.appendFields(this.getAllFields());
    
    return cloned;
  }
  


  /**
   * Validate the log data
   */
  public isValid(): boolean {
    return this.getContent() !== null && 
           this.getContent() !== undefined && 
           this.getContent().length > 0 &&
           this.getTime() > 0;
  }
  
  /**
   * Get a brief description of the log
   */
  public getDescription(): string {
    const content = this.getContent();
    const maxLength = 100;
    const truncated = content.length > maxLength ? 
      content.substring(0, maxLength) + "..." : content;
    
    return `[${this.status}] ${truncated}`;
  }

}
