import { TraceType } from './TraceType';
import { FTTraceConfig } from '../Configs';
import { FTTraceContext, FTTraceHeaderHandler, FTTraceRequestContext } from './FTTraceHeaderHandler';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { Utils } from '../utils/Utils';
import { FTTraceConfigManager } from './FTTraceConfigManager';
import { SamplingUtils } from '../utils/SamplingUtils';
//import { util } from '@kit.ArkTS';

const TAG = Constants.LOG_TAG_PREFIX + "FTTraceHandler";

/**
 * Trace Handler
 * Responsible for generating Trace Headers and processing Trace data
 */
export class FTTraceHandler implements FTTraceHeaderHandler {
  // Trace Header constants
  public static readonly ZIPKIN_TRACE_ID = "X-B3-TraceId";
  public static readonly ZIPKIN_SPAN_ID = "X-B3-SpanId";
  public static readonly ZIPKIN_SAMPLED = "X-B3-Sampled";
  public static readonly ZIPKIN_B3_HEADER = "b3";
  public static readonly W3C_TRACEPARENT_KEY = "traceparent";
  public static readonly JAEGER_KEY = "uber-trace-id";
  public static readonly SKYWALKING_V3_SW_8 = "sw8";
  public static readonly DD_TRACE_TRACE_ID_KEY = "x-datadog-trace-id";
  public static readonly DD_TRACE_PARENT_SPAN_ID_KEY = "x-datadog-parent-id";
  public static readonly DD_TRACE_SAMPLING_PRIORITY_KEY = "x-datadog-sampling-priority";
  public static readonly DD_TRACE_ORIGIN_KEY = "x-datadog-origin";
  
  private enableTrace: boolean;
  private requestTime: number;
  private traceID: string = "";
  private spanID: string = "";
  private config: FTTraceConfig;
  
  constructor() {
    // Aligned with Android: FTTraceHandler() checks sampling rate from config
    const traceConfigManager = FTTraceConfigManager.getInstance();
    const config = traceConfigManager.getConfig();
    if (config !== null) {
      this.config = config;
    } else {
      this.config = new FTTraceConfig();
    }
    this.enableTrace = SamplingUtils.enableTraceSamplingRate(this.config.getSamplingRate());
    this.requestTime = Utils.getCurrentNanoTime();
    // Note: Trace ID and Span ID are generated in getTraceHeader() based on Trace type (aligned with Android)
    
    FTInnerLogger.d(TAG, `FTTraceHandler initialized: enableTrace=${this.enableTrace}, samplingRate=${this.config.getSamplingRate()}`);
  }
  
  /**
   * Get Trace ID
   */
  public getTraceID(): string {
    return this.traceID;
  }
  
  /**
   * Get Span ID
   */
  public getSpanID(): string {
    return this.spanID;
  }

  /**
   * Generate Trace Headers and IDs together.
   */
  public getTraceContext(request: string | FTTraceRequestContext): FTTraceContext {
    const urlString = typeof request === 'string' ? request : request.url;
    const headers = this.getTraceHeader(urlString);
    return {
      headers: headers,
      traceId: this.traceID,
      spanId: this.spanID
    };
  }

  /**
   * Build TraceContext from final headers, similar to Android TraceContext.Simple.fromTraceType(headers).
   */
  public static createTraceContextFromHeaders(
    headers: Record<string, string>,
    fallbackTraceId: string = "",
    fallbackSpanId: string = ""
  ): FTTraceContext {
    let traceId = fallbackTraceId;
    let spanId = fallbackSpanId;

    const ddTraceId = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY);
    const ddSpanId = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY);
    if (ddTraceId && ddSpanId) {
      traceId = ddTraceId;
      spanId = ddSpanId;
      return { headers: headers, traceId: traceId, spanId: spanId };
    }

    const zipkinTraceId = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.ZIPKIN_TRACE_ID);
    const zipkinSpanId = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.ZIPKIN_SPAN_ID);
    if (zipkinTraceId && zipkinSpanId) {
      traceId = zipkinTraceId;
      spanId = zipkinSpanId;
      return { headers: headers, traceId: traceId, spanId: spanId };
    }

    const traceParent = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.W3C_TRACEPARENT_KEY);
    const traceParentParts = traceParent.split("-");
    if (traceParentParts.length >= 4 && traceParentParts[1] && traceParentParts[2]) {
      traceId = traceParentParts[1];
      spanId = traceParentParts[2];
      return { headers: headers, traceId: traceId, spanId: spanId };
    }

    const b3 = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.ZIPKIN_B3_HEADER);
    const b3Parts = b3.split("-");
    if (b3Parts.length >= 2 && b3Parts[0] && b3Parts[1]) {
      traceId = b3Parts[0];
      spanId = b3Parts[1];
      return { headers: headers, traceId: traceId, spanId: spanId };
    }

    const jaeger = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.JAEGER_KEY);
    const jaegerParts = jaeger.split(":");
    if (jaegerParts.length >= 2 && jaegerParts[0] && jaegerParts[1]) {
      traceId = jaegerParts[0];
      spanId = jaegerParts[1];
      return { headers: headers, traceId: traceId, spanId: spanId };
    }

    const sw8 = FTTraceHandler.getHeaderValue(headers, FTTraceHandler.SKYWALKING_V3_SW_8);
    const sw8Parts = sw8.split("-");
    if (sw8Parts.length >= 3 && sw8Parts[1] && sw8Parts[2]) {
      traceId = sw8Parts[1];
      spanId = sw8Parts[2];
    }

    return { headers: headers, traceId: traceId, spanId: spanId };
  }

  private static getHeaderValue(headers: Record<string, string>, key: string): string {
    const exactValue = headers[key];
    if (exactValue !== undefined && exactValue !== null) {
      return exactValue;
    }

    const lowerKey = key.toLowerCase();
    const headerKeys = Object.keys(headers);
    for (let i = 0; i < headerKeys.length; i++) {
      const headerKey = headerKeys[i];
      if (headerKey.toLowerCase() === lowerKey) {
        return headers[headerKey];
      }
    }
    return "";
  }
  
  /**
   * Generate Trace Header
   * Aligned with Android: FTTraceHandler.getTraceHeader(URL) generates IDs based on Trace type
   * @param urlString URL address
   * @returns Header key-value pairs
   */
  public getTraceHeader(urlString: string): Record<string, string> {
    const headers: Record<string, string> = {};
    
    if (!this.config) {
      return headers;
    }
    
    // Aligned with Android SDK: Even when enableTrace = false (samplingRate = 0),
    // we still generate trace headers with sampled = "0" to allow downstream services
    // to decide whether to process the trace. Android logic: always generate headers,
    // but set sampled based on enableTrace flag.
    
    try {
      const traceType = this.config.getTraceType();
      
      // Aligned with Android: Generate Trace ID and Span ID based on Trace type
      // Android logic: 
      // - ZIPKIN/JAEGER/TRACEPARENT: traceID = UUID.toLowerCase(), spanID = GUID_16
      // - DDTRACE: traceID = getDDtraceNewId(), spanID = getDDtraceNewId()
      // - SKYWALKING: uses SkyWalkingUtils
      // Note: Android generates IDs even when enableTrace = false
      if (traceType === TraceType.ZIPKIN_MULTI_HEADER
          || traceType === TraceType.ZIPKIN_SINGLE_HEADER
          || traceType === TraceType.JAEGER
          || traceType === TraceType.TRACEPARENT) {
        this.traceID = Utils.generateUUID();
        this.spanID = this.generateGUID16();
      } else if (traceType === TraceType.DDTRACE) {
        this.traceID = this.generateDDTraceID();
        this.spanID = this.generateDDTraceID();
      } else if (traceType === TraceType.SKYWALKING) {
        // SkyWalking uses special logic, will be handled in generateSkyWalkingHeaders
        // For now, generate basic IDs
        this.traceID = Utils.generateUUID();
        this.spanID = this.generateGUID16();
      }
      
      // Generate headers based on Trace type
      // Aligned with Android: Headers are generated regardless of enableTrace value
      switch (traceType) {
        case TraceType.DDTRACE:
          // Aligned with Android: DDTRACE regenerates IDs in getTraceHeader (line 115-116)
          this.traceID = this.generateDDTraceID();
          this.spanID = this.generateDDTraceID();
          this.generateDataDogHeaders(headers);
          break;
        case TraceType.ZIPKIN_MULTI_HEADER:
          this.generateZipkinMultiHeaders(headers);
          break;
        case TraceType.ZIPKIN_SINGLE_HEADER:
          this.generateZipkinSingleHeader(headers);
          break;
        case TraceType.TRACEPARENT:
          this.generateW3CHeaders(headers);
          break;
        case TraceType.SKYWALKING:
          this.generateSkyWalkingHeaders(headers);
          break;
        case TraceType.JAEGER:
          this.generateJaegerHeaders(headers);
          break;
        default:
          FTInnerLogger.w(TAG, `Unsupported trace type: ${traceType}`);
      }
      
      // Add sampling priority
      // Aligned with Android: Sampling headers are set based on enableTrace flag
      // When enableTrace = false, sampled = "0" (not sampled)
      this.addSamplingHeaders(headers);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error generating trace headers: ${error}`);
    }
    
    return headers;
  }
  
  /**
   * Generate DataDog Headers
   * Note: Sampling priority will be set in addSamplingHeaders()
   */
  private generateDataDogHeaders(headers: Record<string, string>): void {
    headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = this.traceID;
    headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = this.spanID;
    headers[FTTraceHandler.DD_TRACE_ORIGIN_KEY] = "rum";
    // Sampling priority will be set in addSamplingHeaders() based on sampling rate
  }
  
  /**
   * Generate Zipkin Multi Headers
   * Note: Sampled value will be set in addSamplingHeaders()
   */
  private generateZipkinMultiHeaders(headers: Record<string, string>): void {
    headers[FTTraceHandler.ZIPKIN_TRACE_ID] = this.traceID;
    headers[FTTraceHandler.ZIPKIN_SPAN_ID] = this.spanID;
    // Sampled value will be set in addSamplingHeaders() based on sampling rate
  }
  
  /**
   * Generate Zipkin Single Header
   * Aligned with Android: b3 format: traceId-spanId-sampled
   */
  private generateZipkinSingleHeader(headers: Record<string, string>): void {
    // Aligned with Android: sampled = "1" if enableTrace, "0" otherwise
    const sampled = this.enableTrace ? "1" : "0";
    const b3Value = `${this.traceID}-${this.spanID}-${sampled}`;
    headers[FTTraceHandler.ZIPKIN_B3_HEADER] = b3Value;
  }
  
  /**
   * Generate W3C Headers
   * Aligned with Android: traceparent format: version-traceId-parentId-flags
   */
  private generateW3CHeaders(headers: Record<string, string>): void {
    // Aligned with Android: sampled = "1" if enableTrace, "0" otherwise
    const sampled = this.enableTrace ? "1" : "0";
    const version = "00";
    const sampledStr = "0" + sampled; // "01" or "00"
    const parentID = this.spanID;
    const traceparent = `${version}-${this.traceID}-${parentID}-${sampledStr}`;
    headers[FTTraceHandler.W3C_TRACEPARENT_KEY] = traceparent;
  }
  
  /**
   * Generate SkyWalking Headers
   */
  private generateSkyWalkingHeaders(headers: Record<string, string>): void {
    // SkyWalking requires special encoding format
    const sw8Value = this.generateSkyWalkingSW8();
    headers[FTTraceHandler.SKYWALKING_V3_SW_8] = sw8Value;
    // Note: SkyWalking uses different sampling mechanism, keep as is for now
  }
  
  /**
   * Generate Jaeger Headers
   * Aligned with Android: uber-trace-id format: traceId:spanId:parentSpanId:sampled
   */
  private generateJaegerHeaders(headers: Record<string, string>): void {
    // Aligned with Android: sampled = "1" if enableTrace, "0" otherwise
    const sampled = this.enableTrace ? "1" : "0";
    const parentSpanID = "0";
    const jaegerValue = `${this.traceID}:${this.spanID}:${parentSpanID}:${sampled}`;
    headers[FTTraceHandler.JAEGER_KEY] = jaegerValue;
  }
  
  /**
   * Generate SkyWalking SW8 Header value
   */
  private generateSkyWalkingSW8(): string {
    // Simplified SkyWalking SW8 format
    const serviceName = this.config.getServiceName();
    const operationName = "http-request";
    const peer = "127.0.0.1:8080";
    
    // Basic format: 1-{traceId}-{segmentId}-{spanId}-{parentService}-{parentServiceInstance}-{parentEndpoint}-{peer}
    return `1-${this.traceID}-${this.spanID}-${this.spanID}-${serviceName}-default-${operationName}-${peer}`;
  }
  
  /**
   * Add sampling related Headers
   * Aligned with Android: FTTraceHandler.getTraceHeader() sets sampled value based on enableTrace
   * IMPORTANT: For ZIPKIN_SINGLE_HEADER, do NOT add any X-B3-* headers here, only b3 header should be generated
   */
  private addSamplingHeaders(headers: Record<string, string>): void {
    // Aligned with Android: sampled = "1" if enableTrace, "0" otherwise
    const sampled = this.enableTrace ? "1" : "0";
    
    // Add sampling information based on different Trace types
    const traceType = this.config.getTraceType();
    
    // IMPORTANT: Only add sampling headers for trace types that need them
    // ZIPKIN_SINGLE_HEADER already includes sampled in the b3 header value, so skip it here
    if (traceType === TraceType.DDTRACE) {
      // Aligned with Android: x-datadog-sampling-priority = "2" if enableTrace, "-1" if not
      headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = this.enableTrace ? "2" : "-1";
    } else if (traceType === TraceType.ZIPKIN_MULTI_HEADER) {
      // Aligned with Android: x-b3-sampled = "1" if enableTrace, "0" if not
      // Only add X-B3-Sampled for ZIPKIN_MULTI_HEADER, NOT for ZIPKIN_SINGLE_HEADER
      headers[FTTraceHandler.ZIPKIN_SAMPLED] = sampled;
    }
    // Note: ZIPKIN_SINGLE_HEADER, JAEGER, TRACEPARENT are handled in their respective generate methods
    // ZIPKIN_SINGLE_HEADER should ONLY have b3 header, no X-B3-* headers
  }
  
  /**
   * Generate DataDog Trace ID (64-bit number)
   * Aligned with Android: Utils.getDDtraceNewId() returns BigInteger(64, new SecureRandom())
   * @returns 64-bit number as string (decimal format)
   */
  private generateDDTraceID(): string {
    // Generate 64-bit random number (equivalent to BigInteger(64, new SecureRandom()))
    // Range: 0 to 2^64 - 1
    // Since JavaScript Number can only safely represent integers up to 2^53 - 1,
    // we generate the number as a string by combining random digits
    // This ensures we can represent the full 64-bit range (up to 2^64 - 1 = 18446744073709551615)
    
    // Generate 19 random digits (2^64 - 1 has 20 digits, but we use 19 to avoid overflow)
    // This gives us a range of 0 to 9999999999999999999 (sufficient for practical purposes)
    let result = '';
    for (let i = 0; i < 19; i++) {
      result += Math.floor(Math.random() * 10).toString();
    }
    
    // Remove leading zeros (but keep at least one digit)
    result = result.replace(/^0+/, '') || '0';
    
    return result;
  }
  

  /**
   * Generate GUID 16 (first 16 characters of UUID)
   * Aligned with Android: Utils.getGUID_16() returns randomUUID().substring(0, 16)
   * @returns First 16 characters of UUID
   */
  private generateGUID16(): string {
    const uuid = Utils.generateUUID();
    return uuid.substring(0, 16);
  }
  
  /**
   * Set the configuration
   * @param config trace configuration
   */
  public setConfig(config: FTTraceConfig): void {
    this.config = config;
  }
  
  /**
   * Set Trace ID
   * @param traceID Trace ID
   */
  public setTraceID(traceID: string): void {
    this.traceID = traceID || Utils.generateUUID();
  }
  
  /**
   * Set Span ID
   * @param spanID Span ID
   */
  public setSpanID(spanID: string): void {
    this.spanID = spanID || this.generateGUID16();
  }
  
  /**
   * Get the request time
   * @returns request time
   */
  public getRequestTime(): number {
    return this.requestTime;
  }
  
  /**
   * Check whether Trace is enabled
   * @returns whether it is enabled
   */
  public isTraceEnabled(): boolean {
    return this.enableTrace;
  }
  
  /**
   * Set whether Trace is enabled
   * @param enabled whether Trace is enabled
   */
  public setTraceEnabled(enabled: boolean): void {
    this.enableTrace = enabled;
  }
  
  /**
   * Get the configuration
   * @returns trace configuration
   */
  public getConfig(): FTTraceConfig {
    return this.config;
  }
  
  /**
   * Create a copy of the TraceHandler
   * @returns copy
   */
  public clone(): FTTraceHandler {
    const cloned = new FTTraceHandler();
    cloned.setTraceID(this.traceID);
    cloned.setSpanID(this.spanID);
    cloned.setConfig(this.config);
    cloned.setTraceEnabled(this.enableTrace);
    return cloned;
  }
  
  /**
   * Convert to a JSON object
   * @returns JSON object
   */
  public toJSON(): FTTraceHandlerJSON {
    const result: FTTraceHandlerJSON = {
      traceID: this.traceID,
      spanID: this.spanID,
      requestTime: this.requestTime,
      enableTrace: this.enableTrace,
      config: this.config
    };
    return result;
  }
}

/**
 * FTTraceHandler JSON interface
 */
interface FTTraceHandlerJSON {
  traceID: string;
  spanID: string;
  requestTime: number;
  enableTrace: boolean;
  config: FTTraceConfig | null;
}
