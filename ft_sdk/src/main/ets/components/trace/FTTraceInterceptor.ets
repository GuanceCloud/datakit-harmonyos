/**
 * HarmonyOS SDK Trace Interceptor
 * Reference HarmonyOS SDK: FTTraceInterceptor
 */
import { TraceType } from './TraceType';
import { FTInnerLogger } from '../log/FTLogger';
import { FTTraceHandler } from './FTTraceHandler';

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
  body?: string;
  timestamp: number;
  traceId?: string;
  spanId?: string;
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
 * Header handler interface
 * Custom header processing for trace data
 */
export interface HeaderHandler {
  /**
   * Process request headers
   * @param headers Request headers
   * @param traceData Trace data
   * @returns Modified headers
   */
  processRequestHeaders(headers: Map<string, string>, traceData: TraceData): Map<string, string>;

  /**
   * Process response headers
   * @param headers Response headers
   * @param traceData Trace data
   * @returns Modified headers
   */
  processResponseHeaders(headers: Map<string, string>, traceData: TraceData): Map<string, string>;
}

/**
 * Trace data structure
 */
export interface TraceData {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  serviceName: string;
  operationName: string;
  startTime: number;
  tags: Map<string, string>;
  logs: TraceLog[];
}

/**
 * Trace log structure
 */
export interface TraceLog {
  timestamp: number;
  fields: Map<string, string>;
}

/**
 * Default trace interceptor implementation
 * Aligned with Android: Uses FTTraceHandler to generate trace headers with correct ID formats
 */
export class DefaultFTTraceInterceptor implements FTTraceInterceptor {
  private traceType: TraceType;
  private headerHandler: HeaderHandler | null = null;
  private traceHandler: FTTraceHandler | null = null;

  constructor(traceType: TraceType = TraceType.DDTRACE, headerHandler: HeaderHandler | null = null) {
    this.traceType = traceType;
    this.headerHandler = headerHandler;
    // Use FTTraceHandler to generate correct Trace ID formats (aligned with Android)
    this.traceHandler = new FTTraceHandler();
  }

  /**
   * Intercept HTTP request
   * Aligned with Android: Uses FTTraceHandler.getTraceHeader() to generate headers with correct ID formats
   * IMPORTANT: If trace headers already exist in request.headers, do NOT regenerate them to avoid duplicates
   */
  interceptRequest(request: HttpRequestData): HttpRequestData {
    try {
      // Check if trace headers already exist in request.headers
      // If they do, skip generation to avoid duplicate headers (especially for ZIPKIN_SINGLE_HEADER vs ZIPKIN_MULTI_HEADER)
      const hasTraceHeaders = this.hasTraceHeaders(request.headers);
      
      let modifiedHeaders = new Map(request.headers);
      let traceId = request.traceId || "";
      let spanId = request.spanId || "";
      
      if (!hasTraceHeaders) {
        // Use FTTraceHandler to generate trace headers (aligned with Android: FTTraceInterceptor.intercept())
        // This ensures Trace ID formats are correct (DDTRACE=numeric, ZIPKIN/JAEGER/TRACEPARENT=UUID)
        if (!this.traceHandler) {
          this.traceHandler = new FTTraceHandler();
        }
        
        // Generate trace headers using FTTraceHandler (aligned with Android)
        const traceHeaders = this.traceHandler.getTraceHeader(request.url);
        
        // Convert Record<string, string> to Map<string, string>
        const traceHeadersMap = new Map<string, string>();
        const headerKeys = Object.keys(traceHeaders);
        for (let i = 0; i < headerKeys.length; i++) {
          const key = headerKeys[i];
          traceHeadersMap.set(key, traceHeaders[key]);
        }
        
        // Merge trace headers with existing headers
        traceHeadersMap.forEach((value, key) => {
          modifiedHeaders.set(key, value);
        });
        
        // Extract trace ID and span ID from trace handler
        traceId = this.traceHandler.getTraceID();
        spanId = this.traceHandler.getSpanID();
      } else {
        // Trace headers already exist, extract trace ID and span ID from existing headers if available
        // This is a fallback, ideally traceId and spanId should be passed in request.traceId and request.spanId
        FTInnerLogger.d(TAG, `Trace headers already exist in request, skipping generation to avoid duplicates`);
      }
      
      const traceData: TraceData = {
        traceId: traceId,
        spanId: spanId,
        serviceName: 'harmonyos-app',
        operationName: `${request.method} ${this.extractPath(request.url)}`,
        startTime: request.timestamp,
        tags: new Map([
          ['http.method', request.method],
          ['http.url', request.url],
          ['span.kind', 'client']
        ]),
        logs: []
      };
      
      // Apply custom header handler if available
      if (this.headerHandler) {
        const processedHeaders = this.headerHandler.processRequestHeaders(modifiedHeaders, traceData);
        // Update modifiedHeaders with processed headers
        processedHeaders.forEach((value, key) => {
          modifiedHeaders.set(key, value);
        });
      }

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
      // Process response headers if custom handler is available
      let modifiedHeaders = response.headers;
      if (this.headerHandler && response.traceId) {
        const traceData: TraceData = {
          traceId: response.traceId,
          spanId: response.spanId || '',
          serviceName: 'harmonyos-app',
          operationName: 'http_request',
          startTime: response.timestamp - (response.duration || 0),
          tags: new Map(),
          logs: []
        };
        modifiedHeaders = this.headerHandler.processResponseHeaders(modifiedHeaders, traceData);
      }

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

  /**
   * Extract path from URL
   */
  private extractPath(url: string): string {
    try {
      // Simple URL path extraction for HarmonyOS
      const urlParts = url.split('/');
      if (urlParts.length > 3) {
        return '/' + urlParts.slice(3).join('/');
      }
      return '/';
    } catch {
      return url;
    }
  }
}