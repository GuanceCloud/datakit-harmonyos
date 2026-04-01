import { Utils } from '../utils/Utils';

/**
 * Line Protocol Bean - Base class at the bottom level
 * Line Protocol Bean implementation for HarmonyOS
 * Provides basic data structure for Line Protocol format
 */
export class LineProtocolBean {
  /**
   * Data index/measurement name
   */
  private readonly measurement: string;
  
  /**
   * Tag data
   */
  protected readonly tags: Record<string, object>;
  
  /**
   * Field data
   */
  protected readonly fields: Record<string, object>;
  
  /**
   * Generation time, unit nanoseconds
   */
  protected readonly timeNano: number;
  
  constructor(measurement: string, tags: Record<string, object>, fields: Record<string, object>, timeNano: number) {
    this.measurement = measurement || "";
    this.tags = tags || {};
    this.fields = fields || {};
    this.timeNano = timeNano || 0;
  }
  
  /**
   * Get measurement name
   */
  public getMeasurement(): string {
    return this.measurement;
  }
  
  /**
   * Get tag data
   */
  public getTags(): Record<string, object> {
    return this.tags;
  }
  
  /**
   * Get field data
   */
  public getFields(): Record<string, object> {
    return this.fields;
  }
  
  /**
   * Get nanosecond timestamp
   */
  public getTimeNano(): number {
    return this.timeNano;
  }
  
  /**
   * Get millisecond timestamp (converted from nanoseconds)
   */
  public getTimeMillis(): number {
    return Math.floor(this.timeNano / TimeUtils.MS_TO_NS);
  }
  
  /**
   * Check if there are tags
   */
  public hasTags(): boolean {
    return Object.keys(this.tags).length > 0;
  }
  
  /**
   * Check if there are fields
   */
  public hasFields(): boolean {
    return Object.keys(this.fields).length > 0;
  }
  
  /**
   * Get tag count
   */
  public getTagCount(): number {
    return Object.keys(this.tags).length;
  }
  
  /**
   * Get field count
   */
  public getFieldCount(): number {
    return Object.keys(this.fields).length;
  }
  
  /**
   * Convert to Line Protocol format string
   * Format: measurement,tag1=value1,tag2=value2 field1=value1,field2=value2 timestamp
   */
  public toLineProtocol(): string {
    let line = this.measurement;
    
    // Add tags
    if (this.hasTags()) {
      const tagPairs: string[] = [];
      const tagKeys = Object.keys(this.tags);
      for (let i = 0; i < tagKeys.length; i++) {
        const key = tagKeys[i];
        const value = this.tags[key];
        if (value !== undefined && value !== null) {
          tagPairs.push(`${key}=${this.escapeValue(String(value))}`);
        }
      }
      if (tagPairs.length > 0) {
        line += "," + tagPairs.join(",");
      }
    }
    
    // Add fields
    if (this.hasFields()) {
      line += " ";
      const fieldPairs: string[] = [];
      const fieldKeys = Object.keys(this.fields);
      for (let i = 0; i < fieldKeys.length; i++) {
        const key = fieldKeys[i];
        const value = this.fields[key];
        if (value !== undefined && value !== null) {
          const fieldValue = this.formatFieldValue(value);
          fieldPairs.push(`${key}=${fieldValue}`);
        }
      }
      if (fieldPairs.length > 0) {
        line += fieldPairs.join(",");
      }
    }
    
    // Add timestamp
    line += " " + this.timeNano;
    
    return line;
  }
  
  /**
   * Escape special characters in tag and field values
   */
  private escapeValue(value: string): string {
    return value
      .replace(/\\/g, "\\\\")  // Backslash
      .replace(/,/g, "\\,")    // Comma
      .replace(/=/g, "\\=")    // Equals
      .replace(/ /g, "\\ ");   // Space
  }
  
  /**
   * Format field value
   */
  private formatFieldValue(value: object): string {
    if (typeof value === "string") {
      return `"${this.escapeValue(value)}"`;
    } else if (typeof value === "number") {
      return String(value);
    } else if (typeof value === "boolean") {
      return value ? "true" : "false";
    } else {
      return `"${this.escapeValue(JSON.stringify(value))}"`;
    }
  }
  
  /**
   * Convert to JSON object
   */
  public toJSON(): LineProtocolBeanJSON {
    return {
      measurement: this.measurement,
      tags: this.tags,
      fields: this.fields,
      timeNano: this.timeNano
    };
  }
  
  /**
   * Create LineProtocolBean from JSON object
   */
  public static fromJSON(json: LineProtocolBeanJSON): LineProtocolBean {
    return new LineProtocolBean(
      json.measurement || "",
      json.tags || {},
      json.fields || {},
      json.timeNano || 0
    );
  }
  
  /**
   * Create a copy
   */
  public clone(): LineProtocolBean {
    const clonedTags: Record<string, object> = {};
    const clonedFields: Record<string, object> = {};
    
    // Deep copy tags
    const tagKeys = Object.keys(this.tags);
    for (let i = 0; i < tagKeys.length; i++) {
      const key = tagKeys[i];
      clonedTags[key] = this.tags[key];
    }
    
    // Deep copy fields
    const fieldKeys = Object.keys(this.fields);
    for (let i = 0; i < fieldKeys.length; i++) {
      const key = fieldKeys[i];
      clonedFields[key] = this.fields[key];
    }
    
    return new LineProtocolBean(this.measurement, clonedTags, clonedFields, this.timeNano);
  }
  
  /**
   * Validate data validity
   */
  public isValid(): boolean {
    return this.measurement.length > 0 && this.timeNano > 0;
  }
  
  /**
   * Get brief description
   */
  public getDescription(): string {
    return `[${this.measurement}] tags:${this.getTagCount()}, fields:${this.getFieldCount()}, time:${this.timeNano}`;
  }
}

/**
 * LineProtocolBean JSON interface
 */
export interface LineProtocolBeanJSON {
  measurement: string;
  tags: Record<string, object>;
  fields: Record<string, object>;
  timeNano: number;
}

/**
 * Time conversion utility functions
 */
export class TimeUtils {
  /**
   * Conversion factor: milliseconds to nanoseconds
   * 1 millisecond = 1,000,000 nanoseconds
   */
  public static readonly MS_TO_NS = 1000000;
  
  /**
   * Convert milliseconds to nanoseconds
   */
  public static millisToNanos(millis: number): number {
    return millis * TimeUtils.MS_TO_NS;
  }
  
  /**
   * Convert nanoseconds to milliseconds
   */
  public static nanosToMillis(nanos: number): number {
    return Math.floor(nanos / TimeUtils.MS_TO_NS);
  }
  
  /**
   * Get current time in nanoseconds
   * Uses Utils.getCurrentNanoTime() for nanosecond precision (API 12+)
   * Falls back to Date.now() * 1000000 for compatibility
   */
  public static currentTimeNanos(): number {
    return Utils.getCurrentNanoTime();
  }
  
  /**
   * Get current time in milliseconds
   */
  public static currentTimeMillis(): number {
    return Date.now();
  }
}
