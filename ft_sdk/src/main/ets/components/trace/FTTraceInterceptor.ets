/**
 * HarmonyOS SDK Trace Interceptor
 * Reference HarmonyOS SDK: FTTraceInterceptor
 */
import { TraceType } from './TraceType';
import { FTInnerLogger } from '../log/FTLogger';
import { FTTraceHandler } from './FTTraceHandler';
import { FTTraceContext, FTTraceHeaderHandler, FTTraceRequestContext } from './FTTraceHeaderHandler';

const TAG = "FTTraceInterceptor";

/**
 * Trace interceptor interface
 * Handles HTTP request/response tracing
 */
export interface FTTraceInterceptor {
  /**
   * Intercept HTTP request
   * @param request HTTP request data
   * @returns Modified request data
   */
  interceptRequest(request: HttpRequestData): HttpRequestData;

  /**
   * Intercept HTTP response
   * @param response HTTP response data
   * @returns Modified response data
   */
  interceptResponse(response: HttpResponseData): HttpResponseData;
}

/**
 * HTTP request data structure
 */
export interface HttpRequestData {
  url: string;
  method: string;
  headers: Map<string, string>;
  body?: string | Object | ArrayBuffer;
  timestamp: number;
  traceId?: string;
  spanId?: string;
  traceHeadersInjected?: boolean;
}

/**
 * HTTP response data structure
 */
export interface HttpResponseData {
  url: string;
  statusCode: number;
  headers: Map<string, string>;
  body?: string;
  timestamp: number;
  traceId?: string;
  spanId?: string;
  duration?: number;
}

/**
 * Trace Header handler interface.
 */
export interface HeaderHandler extends FTTraceHeaderHandler {}

/**
 * Default trace interceptor implementation
 * Aligned with Android: Uses FTTraceHandler to generate trace headers with correct ID formats
 */
export class DefaultFTTraceInterceptor implements FTTraceInterceptor {
  private traceType: TraceType;
  private headerHandler: FTTraceHeaderHandler | null = null;
  private defaultTraceHandler: FTTraceHandler | null = null;

  constructor(
    traceType: TraceType = TraceType.DDTRACE,
    headerHandler: FTTraceHeaderHandler | null = null
  ) {
    this.traceType = traceType;
    this.headerHandler = headerHandler;
    this.defaultTraceHandler = new FTTraceHandler();
  }

  /**
   * Intercept HTTP request
   * Aligned with Android: generates TraceContext with headers, trace ID, and span ID together.
   * IMPORTANT: If trace headers already exist in request.headers, do NOT regenerate them to avoid duplicates
   */
  interceptRequest(request: HttpRequestData): HttpRequestData {
    try {
      // Check if trace headers already exist in request.headers
      // If they do, skip generation to avoid duplicate headers (especially for ZIPKIN_SINGLE_HEADER vs ZIPKIN_MULTI_HEADER)
      const hasTraceHeaders = request.traceHeadersInjected === true || this.hasTraceHeaders(request.headers);
      
      const modifiedHeaders = new Map(request.headers);
      let traceId = request.traceId || "";
      let spanId = request.spanId || "";
      let traceHeaders: Record<string, string> = {};
      
      if (!hasTraceHeaders) {
        if (!this.defaultTraceHandler) {
          this.defaultTraceHandler = new FTTraceHandler();
        }
        
        const traceContext: FTTraceContext = this.defaultTraceHandler.getTraceContext(request.url);
        traceHeaders = traceContext.headers;
        traceId = traceContext.traceId || "";
        spanId = traceContext.spanId || "";
      } else {
        traceHeaders = this.extractTraceHeaders(modifiedHeaders);
        const traceContext = FTTraceHandler.createTraceContextFromHeaders(
          this.mapToRecord(modifiedHeaders),
          traceId,
          spanId
        );
        traceId = traceContext.traceId || "";
        spanId = traceContext.spanId || "";
        FTInnerLogger.d(TAG, `Trace headers already exist in request, skipping generation to avoid duplicates`);
      }

      // Apply custom header handler if available. Skip when FTTraceManager already injected processed headers.
      if (this.headerHandler && request.traceHeadersInjected !== true) {
        const processedContext = this.headerHandler.getTraceContext(this.createRequestContext(request, modifiedHeaders));
        const traceContext = FTTraceHandler.createTraceContextFromHeaders(
          processedContext.headers,
          processedContext.traceId,
          processedContext.spanId
        );
        traceHeaders = traceContext.headers;
        traceId = traceContext.traceId || "";
        spanId = traceContext.spanId || "";
      }

      this.mergeRecordToMap(modifiedHeaders, traceHeaders);

      return {
        url: request.url,
        method: request.method,
        headers: modifiedHeaders,
        body: request.body,
        timestamp: request.timestamp,
        traceId: traceId,
        spanId: spanId
      };

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to intercept request: ${error}`);
      return request;
    }
  }

  /**
   * Intercept HTTP response
   */
  interceptResponse(response: HttpResponseData): HttpResponseData {
    try {
      let modifiedHeaders = response.headers;

      return {
        url: response.url,
        statusCode: response.statusCode,
        headers: modifiedHeaders,
        body: response.body,
        timestamp: response.timestamp,
        traceId: response.traceId,
        spanId: response.spanId,
        duration: response.duration
      };

    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to intercept response: ${error}`);
      return response;
    }
  }


  /**
   * Check if trace headers already exist in the request headers
   * This prevents duplicate header generation (especially important for ZIPKIN_SINGLE_HEADER vs ZIPKIN_MULTI_HEADER)
   */
  private hasTraceHeaders(headers: Map<string, string>): boolean {
    // Check for common trace header keys
    const traceHeaderKeys = [
      FTTraceHandler.DD_TRACE_TRACE_ID_KEY,
      FTTraceHandler.ZIPKIN_TRACE_ID,
      FTTraceHandler.ZIPKIN_B3_HEADER,
      FTTraceHandler.W3C_TRACEPARENT_KEY,
      FTTraceHandler.JAEGER_KEY,
      FTTraceHandler.SKYWALKING_V3_SW_8
    ];
    
    for (let i = 0; i < traceHeaderKeys.length; i++) {
      if (headers.has(traceHeaderKeys[i])) {
        return true;
      }
    }
    
    return false;
  }

  private mapToRecord(headers: Map<string, string>): Record<string, string> {
    const headerRecord: Record<string, string> = {};
    headers.forEach((value, key) => {
      headerRecord[key] = value;
    });
    return headerRecord;
  }

  private createRequestContext(request: HttpRequestData, headers: Map<string, string>): FTTraceRequestContext {
    return {
      url: request.url,
      method: request.method,
      headers: this.mapToRecord(headers),
      body: request.body
    };
  }

  private extractTraceHeaders(headers: Map<string, string>): Record<string, string> {
    const traceHeaderKeys = [
      FTTraceHandler.DD_TRACE_TRACE_ID_KEY,
      FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY,
      FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY,
      FTTraceHandler.DD_TRACE_ORIGIN_KEY,
      FTTraceHandler.ZIPKIN_TRACE_ID,
      FTTraceHandler.ZIPKIN_SPAN_ID,
      FTTraceHandler.ZIPKIN_SAMPLED,
      FTTraceHandler.ZIPKIN_B3_HEADER,
      FTTraceHandler.W3C_TRACEPARENT_KEY,
      FTTraceHandler.JAEGER_KEY,
      FTTraceHandler.SKYWALKING_V3_SW_8
    ];
    const traceHeaders: Record<string, string> = {};
    for (let i = 0; i < traceHeaderKeys.length; i++) {
      const key = traceHeaderKeys[i];
      const value = headers.get(key);
      if (value !== undefined && value !== null) {
        traceHeaders[key] = value;
      }
    }
    return traceHeaders;
  }

  private mergeRecordToMap(target: Map<string, string>, headers: Record<string, string>): void {
    const headerKeys = Object.keys(headers);
    for (let i = 0; i < headerKeys.length; i++) {
      const key = headerKeys[i];
      target.set(key, headers[key]);
    }
  }
}
