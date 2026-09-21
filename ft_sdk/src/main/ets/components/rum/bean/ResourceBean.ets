import { Utils } from '../../utils/Utils';
import { FTInnerLogger } from '../../log/FTLogger';

/**
 * URL parsing result interface
 */
interface UrlParseResult {
  host: string;
  path: string;
  query: string;
}

/**
 * JSON representation interface for ResourceBean
 */
interface ResourceBeanJSON {
    // Basic information
    url: string;
    urlHost: string;
    urlPath: string;
    resourceType: string;
    resourceMethod: string;
    resourceUrlQuery: string;
    
    // Header information
    requestHeader: string;
    responseHeader: string;
    responseConnection: string;
    responseContentType: string;
    responseContentEncoding: string;
    
    // Link tracing
    traceId: string;
    spanId: string;
    
    // Error information
    errorStack: string;
    errorMsg: string;
    suppressNetworkError: boolean;
    
    // Status and performance
    resourceStatus: number;
    resourceStatusGroup: string;
    resourceSize: number;
    resourceLoad: number;
    
    // Network performance time
    resourceDNS: number;
    resourceDNSStart: number;
    resourceTCP: number;
    resourceTCPStart: number;
    resourceSSL: number;
    resourceSSLStart: number;
    resourceTTFB: number;
    resourceTTFBStart: number;
    resourceTrans: number;
    resourceTransStart: number;
    resourceDOM: number;
    resourceDOMStart: number;
    resourceRes: number;
    resourceResStart: number;
    
    // Performance metrics
    performanceMetrics: Record<string, number>;
    
    // Server information
    resourceHostIP: string;
    
    // Time information
    startTime: number;
    endTime: number;
    totalDuration: number;
    
    // RUM association
    sessionId: string;
    viewId: string;
    viewName: string;
    viewReferrer: string;
    actionId: string;
    actionName: string;
    
    // Session replay
    hasSessionReplay: boolean;
    
    // Other properties
    property: Record<string, object>;
    tags: Record<string, object>;
    
    // Status check
    isError: boolean;
    isNetworkError: boolean;
}

/**
 * Resource Bean - network resource monitoring data
 * Resource Bean implementation for HarmonyOS
 */
export class ResourceBean {
  // Basic information
  public url: string = "";
  public urlHost: string = "";
  public urlPath: string = "";
  public resourceType: string = "";
  public resourceMethod: string = "";
  public resourceUrlQuery: string = "";
  
  // Request and response header information
  public requestHeader: string = "";
  public responseHeader: string = "";
  public responseConnection: string = "";
  public responseContentType: string = "";
  public responseContentEncoding: string = "";
  
  // Link tracing information
  public traceId: string = "";
  public spanId: string = "";
  
  // Error information
  public errorStack: string = "";
  public errorMsg: string = "";
  /** Retains the Resource while suppressing its derived local network Error. */
  public suppressNetworkError: boolean = false;
  
  // Status and performance metrics
  public resourceStatus: number = 0;
  public resourceStatusGroup: string = "";
  public resourceSize: number = -1;
  public resourceLoad: number = -1;
  
  // Network performance time (nanoseconds)
  public resourceDNS: number = -1;
  public resourceDNSStart: number = -1;
  public resourceTCP: number = -1;
  public resourceTCPStart: number = -1;
  public resourceSSL: number = -1;
  public resourceSSLStart: number = -1;
  public resourceTTFB: number = -1;
  public resourceTTFBStart: number = -1;
  public resourceTrans: number = -1;
  public resourceTransStart: number = -1;
  public resourceDOM: number = -1;
  public resourceDOMStart: number = -1;
  public resourceRes: number = -1;
  public resourceResStart: number = -1;
  public resourceFirstByte: number = -1;
  public resourceFirstByteStart: number = -1;
  public resourceDownloadTime: number = -1;
  public resourceDownloadTimeStart: number = -1;
  
  // Server information
  public resourceHostIP: string = "";
  
  // Time information
  public startTime: number = Utils.getCurrentNanoTime();
  public endTime: number = -1;
  
  // RUM association information
  public sessionId: string = "";
  public viewId: string = "";
  public viewName: string = "";
  public viewReferrer: string = "";
  public actionId: string = "";
  public actionName: string = "";
  
  // Session replay related
  public hasSessionReplay: boolean = false;
  
  // Extended properties
  public property: Record<string, object> = {};
  public tags: Record<string, object> = {};
  
  // Status flags
  public contentSet: boolean = false;
  public netStateSet: boolean = false;
  public isProcessing: boolean = false; // Flag to prevent duplicate processing
  
  constructor() {
    // Can initialize in constructor
  }
  
  /**
   * Set URL and parse Host and Path
   */
  public setUrl(url: string): void {
    this.url = url || "";
    if (this.url) {
      try {
        // Parse URL to get host and path
        const urlParts = this.parseUrl(this.url);
        this.urlHost = urlParts.host;
        this.urlPath = urlParts.path;
        this.resourceUrlQuery = urlParts.query;
        FTInnerLogger.d("ResourceBean", `<FT-RESOURCE-BEAN> URL parsed: ${this.url} -> host=${this.urlHost}, path=${this.urlPath}, query=${this.resourceUrlQuery}`);
      } catch (error) {
        FTInnerLogger.e("ResourceBean", `<FT-RESOURCE-BEAN> URL parsing failed: ${this.url}, error: ${error}`);
        // URL parsing failed, keep original value
      }
    }
  }
  


  /**
   * Simple URL parsing
   */
  private parseUrl(url: string): UrlParseResult {
    try {
      const urlPattern = /^(https?:\/\/)?([^\/\?]+)(\/[^\?]*)?(\?.*)?$/;
      const match = url.match(urlPattern);
      
      if (match) {
        const host = match[2] || "";
        const path = match[3] || "/";
        const query = match[4] || "";
        return { host, path, query };
      }
    } catch (error) {
        // Parsing failed
    }
    
    return { host: "", path: "", query: "" };
  }
  
  /**
   * Set response status
   */
  public setResourceStatus(status: number): void {
    this.resourceStatus = status;
  }
  
  /**
   * Get status group (like 2xx, 4xx, etc.)
   */
  public getResourceStatusGroup(): string {
    if (this.resourceStatus > 0) {
      const statusGroupPrefix = Math.floor(this.resourceStatus / 100);
      return `${statusGroupPrefix}xx`;
    }
    return "";
  }
  
  /**
   * Set resource size
   */
  public setResourceSize(size: number): void {
    this.resourceSize = size;
  }
  
  /**
   * Set load time
   */
  public setResourceLoad(loadTime: number): void {
    this.resourceLoad = loadTime;
  }
  
  /**
   * Set DNS resolution time
   */
  public setDNSTime(dnsTime: number, dnsStart: number = -1): void {
    this.resourceDNS = dnsTime;
    this.resourceDNSStart = dnsStart;
  }
  
  /**
   * Set TCP connection time
   */
  public setTCPTime(tcpTime: number, tcpStart: number = -1): void {
    this.resourceTCP = tcpTime;
    this.resourceTCPStart = tcpStart;
  }
  
  /**
   * Set SSL handshake time
   */
  public setSSLTime(sslTime: number, sslStart: number = -1): void {
    this.resourceSSL = sslTime;
    this.resourceSSLStart = sslStart;
  }
  
  /**
   * Set TTFB time
   */
  public setTTFBTime(ttfbTime: number): void {
    this.resourceTTFB = ttfbTime;
  }
  
  /**
   * Set transmission time
   */
  public setTransTime(transTime: number): void {
    this.resourceTrans = transTime;
  }
  
  /**
   * Set first byte time
   */
  public setFirstByteTime(firstByteTime: number, firstByteStart: number = -1): void {
    this.resourceFirstByte = firstByteTime;
    this.resourceFirstByteStart = firstByteStart;
  }
  
  /**
   * Set download time
   */
  public setDownloadTime(downloadTime: number, downloadStart: number = -1): void {
    this.resourceDownloadTime = downloadTime;
    this.resourceDownloadTimeStart = downloadStart;
  }
  

  /**
   * Get total duration
   */
  public getTotalDuration(): number {
    if (this.endTime > 0 && this.startTime > 0) {
      return this.endTime - this.startTime;
    }
    return -1;
  }
  
  /**
   * Set error information
   */
  public setError(errorMsg: string, errorStack: string = ""): void {
    this.errorMsg = errorMsg || "";
    this.errorStack = errorStack || "";
  }
  
  /**
   * Set link tracing information
   */
  public setTracing(traceId: string, spanId: string): void {
    this.traceId = traceId || "";
    this.spanId = spanId || "";
  }
  

  /**
   * Add property
   */
  public addProperty(key: string, value: Object): void {
    this.property[key] = value;
  }
  
  /**
   * Set properties
   */
  public setProperty(property: Record<string, object>): void {
    this.property = property || {};
  }
  
  /**
   * Set end time
   */
  public setEndTime(endTime: number = -1): void {
    this.endTime = endTime > 0 ? endTime : Utils.getCurrentNanoTime();
  }

  /**
   * Set RUM association information
   */
  public setRUMContext(
    sessionId: string,
    viewId: string,
    viewName: string,
    viewReferrer: string,
    actionId: string,
    actionName: string
  ): void {
    this.sessionId = sessionId || "";
    this.viewId = viewId || "";
    this.viewName = viewName || "";
    this.viewReferrer = viewReferrer || "";
    this.actionId = actionId || "";
    this.actionName = actionName || "";
  }
  
  /**
   * Whether it is an error resource
   */
  public isError(): boolean {
    return this.resourceStatus >= 400 || 
           (this.resourceStatus === 0 && this.errorMsg.length > 0);
  }
  
  /**
   * Whether it is a network error
   */
  public isNetworkError(): boolean {
    return this.resourceStatus === 0 && this.errorMsg.length > 0;
  }
  
  /**
   * Get all performance metrics
   */
  public getPerformanceMetrics(): Record<string, number> {
    const metrics: Record<string, number> = {};
    
    if (this.resourceDNS > 0) metrics['dns'] = this.resourceDNS;
    if (this.resourceTCP > 0) metrics['tcp'] = this.resourceTCP;
    if (this.resourceSSL > 0) metrics['ssl'] = this.resourceSSL;
    if (this.resourceTTFB > 0) metrics['ttfb'] = this.resourceTTFB;
    if (this.resourceTrans > 0) metrics['trans'] = this.resourceTrans;
    if (this.resourceFirstByte > 0) metrics['firstByte'] = this.resourceFirstByte;
    if (this.resourceDownloadTime > 0) metrics['download'] = this.resourceDownloadTime;
    if (this.resourceLoad > 0) metrics['load'] = this.resourceLoad;
    if (this.resourceSize > 0) metrics['size'] = this.resourceSize;
    
    return metrics;
  }
  
  /**
   * Convert to JSON
   */
  public toJSON(): ResourceBeanJSON {
    const result: ResourceBeanJSON = {
      // Basic information
      url: this.url,
      urlHost: this.urlHost,
      urlPath: this.urlPath,
      resourceType: this.resourceType,
      resourceMethod: this.resourceMethod,
      resourceUrlQuery: this.resourceUrlQuery,
      
      // Header information
      requestHeader: this.requestHeader,
      responseHeader: this.responseHeader,
      responseConnection: this.responseConnection,
      responseContentType: this.responseContentType,
      responseContentEncoding: this.responseContentEncoding,
      
      // Link tracing
      traceId: this.traceId,
      spanId: this.spanId,
      
      // Error information
      errorStack: this.errorStack,
      errorMsg: this.errorMsg,
      
      // Status and performance
      resourceStatus: this.resourceStatus,
      resourceStatusGroup: this.getResourceStatusGroup(),
      resourceSize: this.resourceSize,
      resourceLoad: this.resourceLoad,
      
      // Network performance time
      resourceDNS: this.resourceDNS,
      resourceDNSStart: this.resourceDNSStart,
      resourceTCP: this.resourceTCP,
      resourceTCPStart: this.resourceTCPStart,
      resourceSSL: this.resourceSSL,
      resourceSSLStart: this.resourceSSLStart,
      resourceTTFB: this.resourceTTFB,
      resourceTTFBStart: this.resourceTTFBStart,
      resourceTrans: this.resourceTrans,
      resourceTransStart: this.resourceTransStart,
      resourceDOM: this.resourceDOM,
      resourceDOMStart: this.resourceDOMStart,
      resourceRes: this.resourceRes,
      resourceResStart: this.resourceResStart,
      
      // Performance time
      performanceMetrics: this.getPerformanceMetrics(),
      
      // Server information
      resourceHostIP: this.resourceHostIP,
      
      // Time information
      startTime: this.startTime,
      endTime: this.endTime,
      totalDuration: this.getTotalDuration(),
      
      // RUM association
      sessionId: this.sessionId,
      viewId: this.viewId,
      viewName: this.viewName,
      viewReferrer: this.viewReferrer,
      actionId: this.actionId,
      actionName: this.actionName,
      
      // Others
      hasSessionReplay: this.hasSessionReplay,
      suppressNetworkError: this.suppressNetworkError,
      property: this.property,
      tags: this.tags,
      
      // Status identifier
      isError: this.isError(),
      isNetworkError: this.isNetworkError()
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
