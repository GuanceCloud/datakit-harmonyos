import {
  ResourceTransportMetricSource,
  ResourceTransportMetrics,
  ResourceTransportMetricsSnapshot
} from './ResourceTransportMetrics';

/**
 * JSON representation interface for ResourceParams
 */
interface ResourceParamsJSON {
  url: string;
  requestHeader: string;
  responseHeader: string;
  requestHeaderMap: Record<string, string[]>;
  responseHeaderMap: Record<string, string[]>;
  responseConnection: string;
  responseContentType: string;
  responseContentEncoding: string;
  responseContentLength: number;
  resourceMethod: string;
  responseBody: string;
  resourceStatus: number;
  resourceType: string;
  requestErrorStack: string;
  requestErrorMsg: string;
  suppressNetworkError: boolean;
  transportMetrics: ResourceTransportMetricsSnapshot;
  property: Record<string, object>;
}

/**
 * Resource request parameters class
 * Resource Parameters implementation for HarmonyOS
 */
export class ResourceParams {
  /**
   * HTTP request URL
   */
  public url: string = "";

  /**
   * HTTP request headers, if empty then read from requestHeaderMap
   */
  public requestHeader: string = "";

  /**
   * HTTP response headers, if empty then read from responseHeaderMap
   */
  public responseHeader: string = "";

  /**
   * HTTP request headers Map
   */
  public requestHeaderMap: Map<string, string[]> = new Map();

  /**
   * HTTP response headers Map
   */
  public responseHeaderMap: Map<string, string[]> = new Map();

  /**
   * HTTP header Connection
   */
  public responseConnection: string = "";

  /**
   * HTTP header Content-Type
   */
  public responseContentType: string = "";

  /**
   * HTTP header Content-Encoding
   */
  public responseContentEncoding: string = "";

  /**
   * Response content size
   */
  public responseContentLength: number = 0;

  /**
   * HTTP request method
   */
  public resourceMethod: string = "";

  /**
   * HTTP request body
   */
  public responseBody: string = "";

  /**
   * HTTP response code
   */
  public resourceStatus: number = 0;

  /**
   * Resource type (e.g., 'network', 'image', 'script', etc.)
   */
  public resourceType: string = "network";

  /**
   * Request error stack
   */
  public requestErrorStack: string = "";

  /**
   * Error message
   */
  public requestErrorMsg: string = "";

  /**
   * Internal auto-track marker. A true value retains this Resource but stops
   * the Worker from deriving a separate network_error for a local failure.
   */
  public suppressNetworkError: boolean = false;

  /**
   * Request transport metrics. They are deliberately separate from response
   * content length: RUM resource_size remains a response-size metric.
   */
  private readonly transportMetrics: ResourceTransportMetrics = new ResourceTransportMetrics();

  /**
   * Additional property parameters
   */
  public property: Map<string, object> = new Map();

  constructor() {
    // Constructor
  }

  /**
   * Set URL
   */
  public setUrl(url: string): void {
    this.url = url || "";
  }

  /**
   * Set request headers
   */
  public setRequestHeader(header: string): void {
    this.requestHeader = header || "";
  }

  /**
   * Set response headers
   */
  public setResponseHeader(header: string): void {
    this.responseHeader = header || "";
  }

  /**
   * Set request headers Map
   */
  public setRequestHeaderMap(headerMap: Map<string, string[]>): void {
    this.requestHeaderMap = headerMap || new Map();
  }

  /**
   * Set response headers Map
   */
  public setResponseHeaderMap(headerMap: Map<string, string[]>): void {
    this.responseHeaderMap = headerMap || new Map();
  }

  /**
   * Set response connection info
   */
  public setResponseConnection(connection: string): void {
    this.responseConnection = connection || "";
  }

  /**
   * Set response content type
   */
  public setResponseContentType(contentType: string): void {
    this.responseContentType = contentType || "";
  }

  /**
   * Set response content encoding
   */
  public setResponseContentEncoding(encoding: string): void {
    this.responseContentEncoding = encoding || "";
  }

  /**
   * Set response content length
   */
  public setResponseContentLength(length: number): void {
    this.responseContentLength = length || 0;
  }

  /**
   * Set resource method
   */
  public setResourceMethod(method: string): void {
    this.resourceMethod = method || "";
  }

  /**
   * Set response body
   */
  public setResponseBody(body: string): void {
    this.responseBody = body || "";
  }

  /**
   * Set resource status
   */
  public setResourceStatus(status: number): void {
    this.resourceStatus = status || 0;
  }

  /**
   * Set request error stack
   */
  public setRequestErrorStack(stack: string): void {
    this.requestErrorStack = stack || "";
  }

  /**
   * Set error message
   */
  public setRequestErrorMsg(msg: string): void {
    this.requestErrorMsg = msg || "";
  }

  /**
   * Suppress only the network Error derived from this completed Resource.
   * This does not discard Resource data.
   */
  public setSuppressNetworkError(suppressNetworkError: boolean): void {
    this.suppressNetworkError = suppressNetworkError === true;
  }

  /** Set an integration-verified request body byte count. Zero is valid. */
  public setRequestBodySize(size: number): void {
    this.transportMetrics.setRequestBodySize(size, 'integration');
  }

  /** Set an integration-verified request header byte count. Zero is valid. */
  public setRequestHeaderSize(size: number): void {
    this.transportMetrics.setRequestHeaderSize(size, 'integration');
  }

  /** Set an integration-verified total request byte count. */
  public setRequestSize(size: number): void {
    this.transportMetrics.setRequestSize(size, 'integration');
  }

  /** Set an integration-verified negotiated HTTP protocol. */
  public setHttpProtocol(protocol: string): void {
    this.transportMetrics.setHttpProtocol(protocol, 'integration');
  }

  /**
   * Set an integration-verified connection reuse result. Do not call this
   * when the transport cannot distinguish false from unknown.
   */
  public setConnectionReuse(connectionReuse: boolean): void {
    this.transportMetrics.setConnectionReuse(connectionReuse, 'integration');
  }

  /** Internal platform collector entry point. */
  public setPlatformRequestBodySize(size: number): void {
    this.transportMetrics.setRequestBodySize(size, 'platform');
  }

  /** Internal platform collector entry point. */
  public setPlatformRequestHeaderSize(size: number): void {
    this.transportMetrics.setRequestHeaderSize(size, 'platform');
  }

  /** Internal platform collector entry point. */
  public setPlatformRequestSize(size: number): void {
    this.transportMetrics.setRequestSize(size, 'platform');
  }

  /** Internal platform collector entry point. */
  public setPlatformHttpProtocol(protocol: string): void {
    this.transportMetrics.setHttpProtocol(protocol, 'platform');
  }

  /** Internal platform collector entry point. */
  public setPlatformConnectionReuse(connectionReuse: boolean): void {
    this.transportMetrics.setConnectionReuse(connectionReuse, 'platform');
  }

  /** Internal fallback collector entry point. */
  public setHeaderInferredRequestBodySize(size: number): void {
    this.transportMetrics.setRequestBodySize(size, 'header');
  }

  /** Internal fallback collector entry point. */
  public setHeaderInferredRequestHeaderSize(size: number): void {
    this.transportMetrics.setRequestHeaderSize(size, 'header');
  }

  /** Read-only serializable transport data for the RUM Worker. */
  public getTransportMetrics(): ResourceTransportMetricsSnapshot {
    return this.transportMetrics.snapshot();
  }

  /** Merge a deferred transport update without weakening a stronger value. */
  public mergeTransportMetrics(metrics?: ResourceTransportMetricsSnapshot): void {
    this.transportMetrics.merge(metrics);
  }

  /**
   * Set properties
   */
  public setProperty(property: Map<string, object>): void {
    this.property = property || new Map();
  }

  /**
   * Add property
   */
  public addProperty(key: string, value: object): void {
    this.property.set(key, value);
  }

  /**
   * Convert to JSON
   */
  public toJSON(): ResourceParamsJSON {
    // Convert Map to plain object
    const requestHeaderMap: Record<string, string[]> = {};
    this.requestHeaderMap.forEach((value, key) => {
      requestHeaderMap[key] = value;
    });
    
    const responseHeaderMap: Record<string, string[]> = {};
    this.responseHeaderMap.forEach((value, key) => {
      responseHeaderMap[key] = value;
    });
    
    const property: Record<string, object> = {};
    this.property.forEach((value, key) => {
      property[key] = value;
    });
    
    const result: ResourceParamsJSON = {
      url: this.url,
      requestHeader: this.requestHeader,
      responseHeader: this.responseHeader,
      requestHeaderMap: requestHeaderMap,
      responseHeaderMap: responseHeaderMap,
      responseConnection: this.responseConnection,
      responseContentType: this.responseContentType,
      responseContentEncoding: this.responseContentEncoding,
      responseContentLength: this.responseContentLength,
      resourceMethod: this.resourceMethod,
      responseBody: this.responseBody,
      resourceStatus: this.resourceStatus,
      resourceType: this.resourceType,
      requestErrorStack: this.requestErrorStack,
      requestErrorMsg: this.requestErrorMsg,
      suppressNetworkError: this.suppressNetworkError,
      transportMetrics: this.transportMetrics.snapshot(),
      property: property
    };
    
    return result;
  }
}
