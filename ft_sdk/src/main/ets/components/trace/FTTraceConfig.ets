import { TraceType } from './TraceType';
import { Constants } from '../Constants';
import { HashMap } from '@kit.ArkTS';

/**
 * Trace configuration class
 */
export class FTTraceConfig {
  /**
   * Sampling rate, [0,1]
   */
  private samplingRate: number = 1;
  
  /**
   * Trace type chain
   */
  private traceType: TraceType = TraceType.DDTRACE;
  
  /**
   * Whether to enable WebView trace
   */
  private enableWebTrace: boolean = false;
  
  /**
   * Whether to enable automatic HTTP trace
   */
  private enableAutoTrace: boolean = false;
  
  /**
   * Whether to link RUM data
   */
  private enableLinkRUMData: boolean = false;
  
  /**
   * Service name, defaults to Constants.DEFAULT_SERVICE_NAME
   */
  private serviceName: string = Constants.DEFAULT_SERVICE_NAME;
  
  /**
   * Custom Header handler
   */
  private headerHandler: FTTraceHeaderHandler | null = null;
  
  /**
   * Global tags
   */
  private globalContext: Record<string, object> = {};
  
  /**
   * Supported trace content types
   */
  private traceContentType: string[] = [
    "application/json",
    "application/javascript", 
    "application/xml",
    "application/x-www-form-urlencoded",
    "text/html",
    "text/xml",
    "text/plain",
    "multipart/form-data"
  ];
  
  /**
   * Get sampling rate
   */
  public getSamplingRate(): number {
    return this.samplingRate;
  }
  
  /**
   * Set sampling rate
   * @param samplingRate Sampling rate, range [0,1]
   */
  public setSamplingRate(samplingRate: number): FTTraceConfig {
    this.samplingRate = Math.max(0, Math.min(1, samplingRate));
    return this;
  }
  
  /**
   * Get Trace type
   */
  public getTraceType(): TraceType {
    return this.traceType;
  }
  
  /**
   * Set Trace type
   * @param traceType Trace type
   */
  public setTraceType(traceType: TraceType): FTTraceConfig {
    this.traceType = traceType;
    return this;
  }
  
  /**
   * Whether WebView trace is enabled
   * @deprecated Deprecated
   */
  public isEnableWebTrace(): boolean {
    return this.enableWebTrace;
  }
  
  /**
   * Set whether to enable WebView trace
   * @param enableWebTrace Whether to enable
   * @deprecated Deprecated
   */
  public setEnableWebTrace(enableWebTrace: boolean): FTTraceConfig {
    this.enableWebTrace = enableWebTrace;
    return this;
  }
  
  /**
   * Whether automatic trace is enabled
   */
  public isEnableAutoTrace(): boolean {
    return this.enableAutoTrace;
  }
  
  /**
   * Set whether to enable automatic trace
   * @param enableAutoTrace Whether to enable
   */
  public setEnableAutoTrace(enableAutoTrace: boolean): FTTraceConfig {
    this.enableAutoTrace = enableAutoTrace;
    return this;
  }
  
  /**
   * Whether to link RUM data
   */
  public isEnableLinkRUMData(): boolean {
    return this.enableLinkRUMData;
  }
  
  /**
   * Set whether to link RUM data
   * @param enableLinkRUMData Whether to link
   */
  public setEnableLinkRUMData(enableLinkRUMData: boolean): FTTraceConfig {
    this.enableLinkRUMData = enableLinkRUMData;
    return this;
  }
  
  /**
   * Get service name
   */
  public getServiceName(): string {
    return this.serviceName;
  }
  
  /**
   * Set service name
   * @param serviceName Service name
   */
  public setServiceName(serviceName: string): FTTraceConfig {
    this.serviceName = serviceName || Constants.DEFAULT_SERVICE_NAME;
    return this;
  }
  
  /**
   * Get Header handler
   */
  public getHeaderHandler(): FTTraceHeaderHandler | null {
    return this.headerHandler;
  }
  
  /**
   * Set Header handler
   * @param headerHandler Header handler
   */
  public setHeaderHandler(headerHandler: FTTraceHeaderHandler | null): FTTraceConfig {
    this.headerHandler = headerHandler;
    return this;
  }
  
  /**
   * Get global tags
   */
  public getGlobalContext(): Record<string, object> {
    return this.globalContext;
  }
  
  /**
   * Set global tags
   * @param globalContext Global tags
   */
  public setGlobalContext(globalContext: Record<string, object>): FTTraceConfig {
    this.globalContext = globalContext || {};
    return this;
  }
  
  /**
   * Add global tag
   * @param key Key
   * @param value Value
   */
  public addGlobalContext(key: string, value: object): FTTraceConfig {
    if (key && value !== undefined && value !== null) {
      this.globalContext[key] = value;
    }
    return this;
  }
  
  /**
   * Get supported trace content types
   */
  public getTraceContentType(): string[] {
    return [...this.traceContentType];
  }
  
  /**
   * Set supported trace content types
   * @param traceContentType Content type list
   */
  public setTraceContentType(traceContentType: string[]): FTTraceConfig {
    if (traceContentType && traceContentType.length > 0) {
      this.traceContentType = [...traceContentType];
    }
    return this;
  }
  
  /**
   * Check if specified content type is supported
   * @param contentType Content type
   * @returns Whether supported
   */
  public isSupportedContentType(contentType: string): boolean {
    if (!contentType) return false;
    
    return this.traceContentType.some(type => 
      contentType.toLowerCase().includes(type.toLowerCase())
    );
  }
  
  /**
   * Validate configuration validity
   * @returns Whether valid
   */
  public isValid(): boolean {
    return this.samplingRate >= 0 && 
           this.samplingRate <= 1 && 
           this.serviceName.length > 0;
  }
  
  /**
   * Create configuration copy
   * @returns Configuration copy
   */
  public clone(): FTTraceConfig {
    const cloned = new FTTraceConfig();
    cloned.samplingRate = this.samplingRate;
    cloned.traceType = this.traceType;
    cloned.enableWebTrace = this.enableWebTrace;
    cloned.enableAutoTrace = this.enableAutoTrace;
    cloned.enableLinkRUMData = this.enableLinkRUMData;
    cloned.serviceName = this.serviceName;
    cloned.headerHandler = this.headerHandler;
    cloned.globalContext = {};
    const entries = Object.entries(this.globalContext);
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const key: string = entry[0];
      const value: object = entry[1];
      cloned.globalContext[key] = value;
    }
    cloned.traceContentType = this.traceContentType.slice();
    return cloned;
  }
  
  /**
   * Convert to JSON object
   * @returns JSON object
   */
  public toJSON(): FTTraceConfigJSON {
    return {
      samplingRate: this.samplingRate,
      traceType: this.traceType,
      enableWebTrace: this.enableWebTrace,
      enableAutoTrace: this.enableAutoTrace,
      enableLinkRUMData: this.enableLinkRUMData,
      serviceName: this.serviceName,
      globalContext: this.globalContext,
      traceContentType: this.traceContentType
    };
  }
  
  /**
   * Create configuration from JSON object
   * @param json JSON object
   * @returns Configuration instance
   */
  public static fromJSON(json: FTTraceConfigJSON): FTTraceConfig {
    const config = new FTTraceConfig();
    config.samplingRate = json.samplingRate || 1;
    config.traceType = json.traceType || TraceType.DDTRACE;
    config.enableWebTrace = json.enableWebTrace || false;
    config.enableAutoTrace = json.enableAutoTrace || false;
    config.enableLinkRUMData = json.enableLinkRUMData || false;
    config.serviceName = json.serviceName || Constants.DEFAULT_SERVICE_NAME;
    config.globalContext = json.globalContext || {};
    config.traceContentType = json.traceContentType || [];
    return config;
  }
  
  /**
   * Convert to string
   * @returns String representation
   */
  public toString(): string {
    return `FTTraceConfig{samplingRate=${this.samplingRate}, traceType=${this.traceType}, enableWebTrace=${this.enableWebTrace}, enableAutoTrace=${this.enableAutoTrace}, enableLinkRUMData=${this.enableLinkRUMData}, serviceName='${this.serviceName}', globalContext=${JSON.stringify(this.globalContext)}}`;
  }
}

/**
 * Trace Header handler interface
 */
export interface FTTraceHeaderHandler {
  /**
   * Get Trace Header
   * @param url URL address
   * @returns Header key-value pairs
   */
  getTraceHeader(url: string): Record<string, string>;
  
  /**
   * Get Trace ID (optional, for RUM data linking)
   * @returns Trace ID
   */
  getTraceID?(): string;
  
  /**
   * Get Span ID (optional, for RUM data linking)
   * @returns Span ID
   */
  getSpanID?(): string;
}

/**
 * FTTraceConfig JSON interface
 */
interface FTTraceConfigJSON {
  samplingRate?: number;
  traceType?: TraceType;
  enableWebTrace?: boolean;
  enableAutoTrace?: boolean;
  enableLinkRUMData?: boolean;
  serviceName?: string;
  globalContext?: Record<string, object>;
  traceContentType?: string[];
}
