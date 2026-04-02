/**
 * RCP network interceptors and session configuration helpers.
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import { FTTraceInterceptor, DefaultFTTraceInterceptor, HttpRequestData, HttpResponseData } from '../trace/FTTraceInterceptor';
import { FTTraceConfigManager } from '../trace/FTTraceConfigManager';
import { TraceType } from '../trace/TraceType';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { ResourceParams } from '../rum/bean/ResourceParams';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';
import { FTTraceManager } from '../trace/FTTraceManager';
import { FTTraceHandler } from '../trace/FTTraceHandler';
import { Constants } from '../Constants';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';

const TAG = "FTHttpAutoTrack";
const FT_RESOURCE_ID_HEADER = 'X-FT-Resource-ID';
const HTTP_METHOD_UNKNOWN = 'UNKNOWN';

function summarizeHeaderKeys(headers: Record<string, string>): string {
  const keys = Object.keys(headers);
  if (keys.length === 0) {
    return '0 headers';
  }
  const preview = keys.slice(0, 5).join(', ');
  return keys.length > 5 ? `${keys.length} headers (${preview}, ...)` : `${keys.length} headers (${preview})`;
}

function summarizeResponseHeaders(headers: Record<string, string | string[] | undefined>): string {
  const keys = Object.keys(headers);
  if (keys.length === 0) {
    return '0 headers';
  }
  const preview = keys.slice(0, 5).join(', ');
  return keys.length > 5 ? `${keys.length} headers (${preview}, ...)` : `${keys.length} headers (${preview})`;
}

function summarizePerformanceMetrics(metrics: Map<string, number>): string {
  const keys = Array.from(metrics.keys());
  if (keys.length === 0) {
    return '0 metrics';
  }
  const summary: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = metrics.get(key);
    if (value !== undefined) {
      summary.push(`${key}=${(value / 1000000).toFixed(2)}ms`);
    }
  }
  return summary.join(', ');
}

/**
 * Interface for TimeInfo structure from RCP response
 * Represents possible timing data fields
 * Note: ArkTS does not support index signatures, so we only define explicit properties
 * RCP uses camelCase field names (e.g., nameLookupTimeMs, connectTimeMs)
 */
interface TimeInfoStructure {
  // RCP native fields (camelCase with "Ms" suffix)
  // According to HarmonyOS RCP TimeInfo interface:
  // - nameLookupTimeMs: DNS resolution time (from start until host name resolved)
  // - connectTimeMs: Connection time (from start until connection completed, includes DNS)
  // - tlsHandshakeTimeMs: TLS handshake time (from start until TLS handshake completed, includes DNS + TCP)
  // - preTransferTimeMs: Pre-transfer time (from start until transfer is just about to begin) - corresponds to Android headerStartTime
  // - startTransferTimeMs: First byte time (from start until first byte is received) - corresponds to Android headerEndTime
  // - totalTimeMs: Total time (from start until transfer completed, includes DNS, TCP, etc.)
  // - redirectTimeMs: Redirect time (from start until all redirect steps completed)
  nameLookupTimeMs?: number;
  connectTimeMs?: number;
  tlsHandshakeTimeMs?: number;
  preTransferTimeMs?: number;
  startTransferTimeMs?: number;
  totalTimeMs?: number;
  redirectTimeMs?: number;
  
  // Alternative field names (for compatibility)
  dnsTime?: number;
  dnsStartTime?: number;
  dnsEndTime?: number;
  tcpTime?: number;
  tcpStartTime?: number;
  tcpEndTime?: number;
  sslTime?: number;
  sslStartTime?: number;
  sslEndTime?: number;
  ttfbTime?: number;
  firstByteTime?: number;
  headerStartTime?: number;
  headerEndTime?: number;
  transTime?: number;
  responseTime?: number;
  downloadTime?: number;
  bodyStartTime?: number;
  bodyEndTime?: number;
  totalTime?: number;
}

/**
 * Interface for wrapping performance metric values
 * Used to satisfy addProperty's object type requirement
 */
interface PerformanceMetricValue {
  value: number;
}

interface HttpAutoTrackState {
  resourceId: string;
  url: string;
  method: string;
  startTime: number;
  requestHeaders: Record<string, string>;
  actionId?: string;
}

class HttpAutoTrackStateStore {
  private static instance: HttpAutoTrackStateStore | null = null;
  // INITIAL_REQUEST and FINAL_RESPONSE run in different callbacks, so we keep
  // the request context here until the final response interceptor completes.
  private readonly stateMap: Map<string, HttpAutoTrackState> = new Map();

  public static getInstance(): HttpAutoTrackStateStore {
    if (HttpAutoTrackStateStore.instance === null) {
      HttpAutoTrackStateStore.instance = new HttpAutoTrackStateStore();
    }
    return HttpAutoTrackStateStore.instance;
  }

  public put(state: HttpAutoTrackState): void {
    if (this.stateMap.size > Constants.MAX_MAP_SIZE_RESOURCE) {
      FTInnerLogger.w(TAG, `[HTTP-AutoTrack] stateMap size (${this.stateMap.size}) exceeds limit, clearing stale states`);
      this.stateMap.clear();
    }
    this.stateMap.set(state.resourceId, state);
  }

  public get(resourceId: string): HttpAutoTrackState | undefined {
    return this.stateMap.get(resourceId);
  }

  public delete(resourceId: string): void {
    this.stateMap.delete(resourceId);
  }
}

function normalizeObjectHeaders(headers?: Object | null): Record<string, string> {
  const normalized: Record<string, string> = {};
  if (!headers) {
    return normalized;
  }

  // Harmony http interceptor headers are exposed as Object, so normalize them
  // before we reuse the existing trace/resource helpers.
  const rawHeaders = headers as Record<string, Object>;
  const keys = Object.keys(rawHeaders);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = rawHeaders[key];
    if (typeof value === 'string') {
      normalized[key] = value;
    } else if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string') {
      normalized[key] = value[0] as string;
    } else if (value !== undefined && value !== null) {
      normalized[key] = String(value);
    }
  }
  return normalized;
}

function applyNormalizedHeadersToHttpContext(context: http.HttpRequestContext, headers: Record<string, string>): void {
  const mutableHeaders: Record<string, string> = {};
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    mutableHeaders[key] = headers[key];
  }
  context.header = mutableHeaders as Object;
}

function buildRequestHeaderMap(headers: Record<string, string>): Map<string, string[]> {
  const headerMap = new Map<string, string[]>();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headerMap.set(key, [headers[key]]);
  }
  return headerMap;
}

function buildResponseHeaderMap(headers: Record<string, string>): Map<string, string[]> {
  const headerMap = new Map<string, string[]>();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headerMap.set(key, [headers[key]]);
  }
  return headerMap;
}

function ensureHttpResourceId(headers: Record<string, string>): string {
  const existingId = headers[FT_RESOURCE_ID_HEADER];
  if (existingId && existingId.length > 0) {
    return existingId;
  }
  const generatedId = Utils.generateUUID();
  headers[FT_RESOURCE_ID_HEADER] = generatedId;
  return generatedId;
}

function buildAutoTrackResourceId(method: string, url: string, uniqueId: string): string {
  return `${method}_${url}_${uniqueId}`;
}

function extractContentLength(headers: Record<string, string>): number {
  const contentLength = headers['content-length'] || headers['Content-Length'];
  if (!contentLength) {
    return 0;
  }

  const parsedValue = parseInt(contentLength, 10);
  return isNaN(parsedValue) ? 0 : parsedValue;
}

function tryGetResponseBodyText(result: string | Object | ArrayBuffer): string | undefined {
  if (typeof result === 'string') {
    return result;
  }
  return undefined;
}

/**
 * RCP Resource Interceptor
 * Automatically intercepts HTTP requests and collects resource data
 */
export class RCPResourceInterceptor implements rcp.Interceptor {
  // private resourceInterceptor: FTResourceInterceptor;
  private isEnabled: boolean = true;
  // Map to store resourceId -> actionId mapping for fallback when ResourceBean is deleted
  private resourceActionMap: Map<string, string> = new Map();

  constructor() {
    // this.resourceInterceptor = FTResourceInterceptor.getInstance();
  }

  public enable(): void {
    this.isEnabled = true;
    FTInnerLogger.d(TAG, "RCP Resource Interceptor enabled");
  }

  public disable(): void {
    this.isEnabled = false;
    FTInnerLogger.d(TAG, "RCP Resource Interceptor disabled");
  }

  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    if (!this.isEnabled) {
      return await next.handle(context);
    }

    // Generate resource ID (aligned with Android: Utils.identifyRequest)
    // Android: Uses ResourceID tag UUID if available, otherwise method + "_" + url
    // In HarmonyOS RCP, we cannot add tags to requests like Android, so we generate a unique UUID for each request
    // RCPResourceInterceptor executes after RCPTraceInterceptor, so we reuse the UUID from header
    const url = context.request.url.href;
    const method = context.request.method || 'GET';
    
    // Reuse UUID from header (set by RCPTraceInterceptor which executes first)
    let uniqueId: string | undefined = undefined;
    if (context.request.headers && context.request.headers['X-FT-Resource-ID']) {
      const headerValue = context.request.headers['X-FT-Resource-ID'];
      if (typeof headerValue === 'string') {
        uniqueId = headerValue;
      }
    }
    
    // If not found in header (shouldn't happen, but defensive check), generate new UUID
    if (!uniqueId) {
      uniqueId = Utils.generateUUID();
      FTInnerLogger.w(TAG, `[RCP-Resource] UUID not found in header, generated new UUID: ${uniqueId}`);
      
      // Store in header for consistency
      if (!context.request.headers) {
        context.request.headers = {};
      }
      context.request.headers['X-FT-Resource-ID'] = uniqueId;
    }
    
    // Format: "method_url_uuid" to maintain compatibility with existing trace handler logic
    const resourceId = `${method}_${url}_${uniqueId}`;

    // IMPORTANT: Get trace headers from FTTraceManager handler to ensure we get the correct trace_id
    // In RCP, interceptors may execute in reverse order (last-in-first-out), so trace interceptor may execute after resource interceptor
    // We need to get trace headers from the handler that was created by trace interceptor (if it has already executed)
    // or wait for trace interceptor to execute and then get the headers
    // Aligned with Android: FTResourceInterceptor reads request.headers() before chain.proceed() (line 150)
    // But in HarmonyOS, we need to handle the case where trace interceptor hasn't executed yet
    const savedRequestHeaders: Record<string, string> = {};
    if (context.request.headers) {
      const headerKeys = Object.keys(context.request.headers);
      for (let i = 0; i < headerKeys.length; i++) {
        const key = headerKeys[i];
        const value = context.request.headers[key];
        if (typeof value === 'string') {
          savedRequestHeaders[key] = value;
        } else if (Array.isArray(value) && value.length > 0) {
          savedRequestHeaders[key] = value[0] as string;
        }
      }
    }
    
    // Try to get trace headers from FTTraceManager handler (if trace interceptor has already executed)
    // IMPORTANT: Do NOT call handler.getTraceHeader(url) as it will generate NEW trace_id!
    // Instead, get trace_id and span_id from handler.getTraceID() and handler.getSpanID(), then build headers manually
    // This ensures we get the correct trace_id that was already generated by trace interceptor
    // Note: In RCP, interceptors may execute in reverse order (last-in-first-out), so trace interceptor may execute after resource interceptor
    // If handler doesn't exist yet, we'll use the headers from context.request.headers (which may be from a previous request)
    // The correct trace_id will be set in setTransformContent() from handler.getTraceID()/getSpanID()
    const traceManager = FTTraceManager.getInstance();
    const handler = traceManager.getHandler(resourceId);
    if (handler && handler.getTraceID && handler.getSpanID) {
      try {
        const traceId = handler.getTraceID();
        const spanId = handler.getSpanID();
        if (traceId && spanId) {
          // Get trace type from config to build correct headers
          const traceConfigManager = FTTraceConfigManager.getInstance();
          const traceType = traceConfigManager.getTraceType();
          
          // Build trace headers based on trace type (aligned with FTTraceHandler.generateDataDogHeaders, etc.)
          if (traceType === 'ddtrace') {
            // DataDog trace headers
            savedRequestHeaders[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = traceId;
            savedRequestHeaders[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = spanId;
            savedRequestHeaders[FTTraceHandler.DD_TRACE_ORIGIN_KEY] = "rum";
            savedRequestHeaders[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = "2"; // Default to sampled
          } else if (traceType === 'zipkin_single_header') {
            // Zipkin Single Header: only b3 header (format: traceId-spanId-sampled)
            const sampled = "1"; // Default to sampled
            savedRequestHeaders[FTTraceHandler.ZIPKIN_B3_HEADER] = `${traceId}-${spanId}-${sampled}`;
          } else if (traceType === 'zipkin' || traceType === 'zipkin_multi_header') {
            // Zipkin Multi Header: X-B3-* headers
            savedRequestHeaders[FTTraceHandler.ZIPKIN_TRACE_ID] = traceId;
            savedRequestHeaders[FTTraceHandler.ZIPKIN_SPAN_ID] = spanId;
            savedRequestHeaders[FTTraceHandler.ZIPKIN_SAMPLED] = "1"; // Default to sampled
          } else if (traceType === 'traceparent') {
            // W3C Traceparent header
            const version = "00";
            const sampledStr = "01"; // Default to sampled
            savedRequestHeaders[FTTraceHandler.W3C_TRACEPARENT_KEY] = `${version}-${traceId}-${spanId}-${sampledStr}`;
          } else if (traceType === 'jaeger') {
            // Jaeger trace headers
            const parentSpanID = "0";
            savedRequestHeaders[FTTraceHandler.JAEGER_KEY] = `${traceId}:${spanId}:${parentSpanID}:1`;
          }
        } else {
          FTInnerLogger.w(TAG, `[RCP-Resource] Trace handler is missing trace identifiers, resourceId=${resourceId}`);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Failed to get trace headers from handler: ${error}`);
      }
    }

    // IMPORTANT: Update context.request.headers with correct trace headers to ensure the actual request sent to server uses the correct trace_id
    // This is critical because next.handle(context) will use context.request.headers, not savedRequestHeaders
    if (!context.request.headers) {
      context.request.headers = {};
    }
    // Update trace headers in context.request.headers with the correct values from handler
    const savedHeaderKeys = Object.keys(savedRequestHeaders);
    for (let i = 0; i < savedHeaderKeys.length; i++) {
      const key = savedHeaderKeys[i];
      context.request.headers[key] = savedRequestHeaders[key];
    }
    FTInnerLogger.d(TAG, `[RCP-Resource] Tracking request ${method} ${url}, resourceId=${resourceId}, ${summarizeHeaderKeys(savedRequestHeaders)}`);

    // Record request start
    FTRUMInnerManager.getInstance().startResource(resourceId);
    
    // Clean up resourceActionMap if it exceeds limit (aligned with resourceBeanMap cleanup)
    if (this.resourceActionMap.size > Constants.MAX_MAP_SIZE_RESOURCE) {
      FTInnerLogger.w(TAG, `[RCP-Resource] resourceActionMap size (${this.resourceActionMap.size}) exceeds limit, clearing to prevent memory leak`);
      this.resourceActionMap.clear();
    }
    
    // Save resourceId -> actionId mapping for fallback when ResourceBean is deleted
    // This is needed because if user clicks a new button quickly, activeAction may change
    // and we won't be able to get the correct actionId from activeAction in stopResource fallback
    const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
    if (activeAction && !activeAction.isActionClose()) {
      const actionId = activeAction.getId();
      this.resourceActionMap.set(resourceId, actionId);
    }

    const startTime = Date.now();
    let response: rcp.Response | null = null;
    let error: Error | null = null;

    try {
      // Continue with the request (now context.request.headers contains the correct trace_id)
      response = await next.handle(context);
      if (!response) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Response is null after next.handle(), resourceId=${resourceId}`);
      }

      // Record response data
      const responseTime = Date.now() - startTime;
      
      // Build ResourceParams for RUM
      const resourceParams = new ResourceParams();
      resourceParams.setUrl(url);
      resourceParams.setResourceMethod(method);
      
      // Set request headers using saved headers (preserved before next.handle())
      // This ensures we capture the trace headers added by trace interceptor
      const requestHeaderMap = new Map<string, string[]>();
      const savedHeaderKeys = Object.keys(savedRequestHeaders);
      for (let i = 0; i < savedHeaderKeys.length; i++) {
        const key = savedHeaderKeys[i];
        requestHeaderMap.set(key, [savedRequestHeaders[key]]);
      }
      
      // Note: The handler.getTraceID() and handler.getSpanID() will be used in setTransformContent() to set trace_id and span_id to ResourceBean.
      // This aligns with Android: FTResourceInterceptor uses request.headers() directly (line 150)
      // and FTRUMInnerManager.setTransformContent() gets trace_id/span_id from handler.getTraceID()/getSpanID() (line 1000-1001)
      
      resourceParams.setRequestHeaderMap(requestHeaderMap);
      resourceParams.setRequestHeader(JSON.stringify(savedRequestHeaders));

      // Set response data
      resourceParams.setResourceStatus(response.statusCode || 0);
      
      // Extract response headers
      if (response.headers) {
        const responseHeaderMap = new Map<string, string[]>();
        const respHeaderKeys = Object.keys(response.headers);
        for (let i = 0; i < respHeaderKeys.length; i++) {
          const key = respHeaderKeys[i];
          const value = response.headers[key];
          if (typeof value === 'string') {
            responseHeaderMap.set(key, [value]);
          } else if (Array.isArray(value)) {
            responseHeaderMap.set(key, value as string[]);
          }
        }
        resourceParams.setResponseHeaderMap(responseHeaderMap);
        resourceParams.setResponseHeader(JSON.stringify(response.headers));
        
        // Extract specific headers
        const contentType = response.headers['content-type'] || response.headers['Content-Type'];
        const contentLength = response.headers['content-length'] || response.headers['Content-Length'];
        const contentEncoding = response.headers['content-encoding'] || response.headers['Content-Encoding'];
        const connection = response.headers['connection'] || response.headers['Connection'];
        
        if (typeof contentType === 'string') {
          resourceParams.setResponseContentType(contentType);
        }
        if (typeof contentLength === 'string') {
          const length = parseInt(contentLength, 10);
          if (!isNaN(length)) {
            resourceParams.setResponseContentLength(length);
          }
        }
        if (typeof contentEncoding === 'string') {
          resourceParams.setResponseContentEncoding(contentEncoding);
        }
        if (typeof connection === 'string') {
          resourceParams.setResponseConnection(connection);
        }
      }

      // Extract time info if available and store performance metrics
      if (response.timeInfo) {
        // Extract performance metrics from timeInfo
        // timeInfo structure may vary, try to extract common metrics
        // Convert TimeInfo to TimeInfoStructure via object for type safety
        // (TimeInfo type doesn't overlap with TimeInfoStructure, so we use object as intermediate)
        const timeInfoObj = response.timeInfo as object as TimeInfoStructure;
        
        // Performance metrics to extract (similar to Android NetStatusBean)
        // Use Map instead of Record to avoid indexed access
        const performanceMetrics: Map<string, number> = new Map();
        
        // Extract timing data from RCP TimeInfo
        // RCP provides: nameLookupTimeMs, connectTimeMs, tlsHandshakeTimeMs, 
        //              preTransferTimeMs, startTransferTimeMs, totalTimeMs, redirectTimeMs
        // 
        // Field mapping to resource metrics:
        // - nameLookupTimeMs: DNS resolution time (from start until host name resolved) -> resourceDNS
        // - connectTimeMs: Connection time (from start until connection completed, includes DNS) -> resourceTCP (calculated as connectTimeMs - nameLookupTimeMs)
        // - tlsHandshakeTimeMs: TLS handshake time (from start until TLS handshake completed, includes DNS + TCP) -> resourceSSL (calculated as tlsHandshakeTimeMs - connectTimeMs)
        // - preTransferTimeMs: Pre-transfer time (from start until ready to receive response headers, includes DNS + TCP + SSL + wait time) -> used for TTFB calculation
        // - startTransferTimeMs: First byte time (from start until first byte received, includes DNS + TCP + SSL + wait + TTFB) -> used for TTFB and Download calculation
        // - totalTimeMs: Total request time (from start until transfer completed) -> resourceLoad, resourceTrans, resourceDownloadTime
        // - redirectTimeMs: Redirect time (from start until all redirect steps completed, before final transaction) -> not stored separately (included in totalTimeMs)
        //
        // TTFB calculation (aligned with Android: getTTFB() = headerEndTime - headerStartTime):
        // - Android: headerStartTime = responseHeadersStart() (starts receiving response headers after SSL completes)
        //           headerEndTime = responseHeadersEnd() (response header reception completed)
        // - RCP TimeInfo interface:
        //   * preTransferTimeMs: "The time in milliseconds, it took from the start until the transfer is just about to begin"
        //     This corresponds to Android's headerStartTime (ready to receive response headers)
        //   * startTransferTimeMs: "The time in milliseconds, it took from the start until the first byte is received"
        //     This corresponds to Android's headerEndTime (first byte received, response headers completed)
        // - TTFB = startTransferTimeMs - preTransferTimeMs (response header receiving time, short like Android)
        //
        // Time phases:
        // DNS = nameLookupTimeMs
        // TCP = connectTimeMs - nameLookupTimeMs
        // SSL = tlsHandshakeTimeMs - connectTimeMs
        // Wait = preTransferTimeMs - tlsHandshakeTimeMs (server processing time, may appear as "Unknown" on server)
        // TTFB = startTransferTimeMs - preTransferTimeMs (response header receiving time)
        // Download = totalTimeMs - startTransferTimeMs
        // Note: DNS + TCP + SSL + Wait + TTFB + Download = totalTimeMs
        //
        // Note: All RCP time fields are in milliseconds, we convert to nanoseconds to align with Android
        // Android uses System.nanoTime() which returns nanoseconds
        
        // Convert milliseconds to nanoseconds (aligned with Android: all time fields are in nanoseconds)
        // Android uses System.nanoTime() which returns nanoseconds
        const MS_TO_NS = 1000000; // 1 millisecond = 1,000,000 nanoseconds
        
        // DNS time (nameLookupTimeMs in RCP - convert from ms to ns)
        if (timeInfoObj.nameLookupTimeMs !== undefined && typeof timeInfoObj.nameLookupTimeMs === 'number') {
          performanceMetrics.set('resourceDNS', timeInfoObj.nameLookupTimeMs * MS_TO_NS);
        } else if (timeInfoObj.dnsTime !== undefined && typeof timeInfoObj.dnsTime === 'number') {
          // Assume dnsTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceDNS', timeInfoObj.dnsTime as number);
        } else if (timeInfoObj.dnsEndTime !== undefined && timeInfoObj.dnsStartTime !== undefined) {
          const dnsStart = typeof timeInfoObj.dnsStartTime === 'number' ? timeInfoObj.dnsStartTime : 0;
          const dnsEnd = typeof timeInfoObj.dnsEndTime === 'number' ? timeInfoObj.dnsEndTime : 0;
          if (dnsEnd > dnsStart) {
            performanceMetrics.set('resourceDNS', dnsEnd - dnsStart);
          }
        }
        
        // TCP time (connectTimeMs - nameLookupTimeMs in RCP - convert from ms to ns)
        // According to RCP documentation: connectTimeMs is "the time from the start until the connection to the remote host (or proxy) was completed"
        // Since DNS resolution happens before connection, connectTimeMs includes nameLookupTimeMs
        // So we calculate pure TCP time by subtracting DNS: TCP = connectTimeMs - nameLookupTimeMs
        if (timeInfoObj.connectTimeMs !== undefined && typeof timeInfoObj.connectTimeMs === 'number') {
          const connectTime = timeInfoObj.connectTimeMs * MS_TO_NS;
          const dnsTime = timeInfoObj.nameLookupTimeMs !== undefined && typeof timeInfoObj.nameLookupTimeMs === 'number' 
            ? timeInfoObj.nameLookupTimeMs * MS_TO_NS
            : 0;
          const tcpTime = connectTime > dnsTime ? connectTime - dnsTime : connectTime;
          if (tcpTime > 0) {
            performanceMetrics.set('resourceTCP', tcpTime);
          }
        } else if (timeInfoObj.tcpTime !== undefined && typeof timeInfoObj.tcpTime === 'number') {
          // Assume tcpTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceTCP', timeInfoObj.tcpTime as number);
        } else if (timeInfoObj.tcpEndTime !== undefined && timeInfoObj.tcpStartTime !== undefined) {
          const tcpStart = typeof timeInfoObj.tcpStartTime === 'number' ? timeInfoObj.tcpStartTime : 0;
          const tcpEnd = typeof timeInfoObj.tcpEndTime === 'number' ? timeInfoObj.tcpEndTime : 0;
          if (tcpEnd > tcpStart) {
            performanceMetrics.set('resourceTCP', tcpEnd - tcpStart);
          }
        }
        
        // SSL/TLS time - calculate pure SSL handshake time
        // Android: getSSLTime() = sslEndTime - sslStartTime (pure SSL handshake duration)
        // RCP: tlsHandshakeTimeMs is from start until TLS handshake completed (includes DNS + TCP)
        // So we need to subtract connectTimeMs to get pure SSL time: SSL = tlsHandshakeTimeMs - connectTimeMs
        if (timeInfoObj.tlsHandshakeTimeMs !== undefined && typeof timeInfoObj.tlsHandshakeTimeMs === 'number') {
          const tlsHandshakeTime = timeInfoObj.tlsHandshakeTimeMs * MS_TO_NS;
          const connectTime = timeInfoObj.connectTimeMs !== undefined && typeof timeInfoObj.connectTimeMs === 'number'
            ? timeInfoObj.connectTimeMs * MS_TO_NS
            : 0;
          // Pure SSL time = TLS handshake time - connection time (which includes DNS + TCP)
          const sslTime = tlsHandshakeTime > connectTime ? tlsHandshakeTime - connectTime : tlsHandshakeTime;
          if (sslTime > 0) {
            performanceMetrics.set('resourceSSL', sslTime);
          }
        } else if (timeInfoObj.sslTime !== undefined && typeof timeInfoObj.sslTime === 'number') {
          // Assume sslTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceSSL', timeInfoObj.sslTime as number);
        } else if (timeInfoObj.sslEndTime !== undefined && timeInfoObj.sslStartTime !== undefined) {
          const sslStart = typeof timeInfoObj.sslStartTime === 'number' ? timeInfoObj.sslStartTime : 0;
          const sslEnd = typeof timeInfoObj.sslEndTime === 'number' ? timeInfoObj.sslEndTime : 0;
          if (sslEnd > sslStart) {
            performanceMetrics.set('resourceSSL', sslEnd - sslStart);
          }
        }
        
        // TTFB (Time To First Byte) calculation
        // 
        // HarmonyOS RCP TimeInfo timeline:
        //   0 -> nameLookupTimeMs (DNS) -> connectTimeMs (TCP) -> tlsHandshakeTimeMs (SSL) 
        //   -> preTransferTimeMs (time when request payload data is sent to the server)
        //   -> startTransferTimeMs (time when the first packet is received from the server)
        //
        // Android timeline:
        //   callStartTime -> DNS -> TCP -> SSL -> headerStartTime (response headers begin)
        //   -> headerEndTime (response headers completed) -> bodyStartTime -> bodyEndTime
        //
        // Key difference:
        // - Android TTFB = headerEndTime - headerStartTime (only response header receiving time, very short ~0.006ms)
        // - HarmonyOS TTFB = startTransferTimeMs - preTransferTimeMs (includes server processing + network + header receiving, longer ~262ms)
        //
        // Note: HarmonyOS cannot get pure "response header receiving time" like Android because RCP only provides
        // the total time from request sent to first byte received, which includes server processing time.
        // So HarmonyOS TTFB will be larger than Android TTFB, and this is expected behavior.
        let ttfbValue: number | undefined = undefined;
        
        const hasPreTransfer = timeInfoObj.preTransferTimeMs !== undefined;
        const hasStartTransfer = timeInfoObj.startTransferTimeMs !== undefined;
        const hasTlsHandshake = timeInfoObj.tlsHandshakeTimeMs !== undefined;
        
        if (hasStartTransfer && hasPreTransfer) {
          // Preferred: use preTransferTimeMs to align with Android's headerStartTime
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const preTransfer = (typeof timeInfoObj.preTransferTimeMs === 'number' ? timeInfoObj.preTransferTimeMs : 0) * MS_TO_NS;
          if (startTransfer > preTransfer) {
            ttfbValue = startTransfer - preTransfer;
          } else if (startTransfer > 0) {
            ttfbValue = startTransfer;
            FTInnerLogger.w(TAG, `[RCP-Resource] Invalid preTransferTimeMs for TTFB, fallback to startTransferTimeMs, resourceId=${resourceId}`);
          }
        } else if (hasStartTransfer && hasTlsHandshake) {
          // Fallback: if preTransferTimeMs not available, use tlsHandshakeTimeMs
          // This gives SSL completion to first byte (longer, but still valid)
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const tlsHandshake = (typeof timeInfoObj.tlsHandshakeTimeMs === 'number' ? timeInfoObj.tlsHandshakeTimeMs : 0) * MS_TO_NS;
          if (startTransfer > tlsHandshake) {
            ttfbValue = startTransfer - tlsHandshake;
          } else if (startTransfer > 0) {
            ttfbValue = startTransfer;
          }
        } else if (timeInfoObj.ttfbTime !== undefined && typeof timeInfoObj.ttfbTime === 'number') {
          // Assume ttfbTime is already in nanoseconds if not from RCP
          ttfbValue = timeInfoObj.ttfbTime as number;
        } else if (timeInfoObj.firstByteTime !== undefined && typeof timeInfoObj.firstByteTime === 'number') {
          // Assume firstByteTime is already in nanoseconds if not from RCP
          ttfbValue = timeInfoObj.firstByteTime as number;
        } else {
          FTInnerLogger.w(TAG, `[RCP-Resource] No TTFB calculation method available, resourceId=${resourceId}`);
        }
        
        // Set both resourceTTFB and resourceFirstByte (aligned with Android: getFirstByteTime() returns getTTFB())
        if (ttfbValue !== undefined && ttfbValue > 0) {
          performanceMetrics.set('resourceTTFB', ttfbValue);
          performanceMetrics.set('resourceFirstByte', ttfbValue);
        }
        
        // Transmission time (response time) - convert from ms to ns
        // Android: getResponseTime() = bodyEndTime - headerStartTime = TTFB + Download
        // RCP: totalTimeMs = bodyEndTime (from start), tlsHandshakeTimeMs = headerStartTime (from start, SSL end)
        // So resourceTrans = totalTimeMs - tlsHandshakeTimeMs = TTFB + Download
        // This ensures resourceTrans includes both TTFB and Download phases (aligned with Android)
        if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.tlsHandshakeTimeMs !== undefined) {
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const tlsHandshake = (typeof timeInfoObj.tlsHandshakeTimeMs === 'number' ? timeInfoObj.tlsHandshakeTimeMs : 0) * MS_TO_NS;
          if (totalTime > tlsHandshake) {
            performanceMetrics.set('resourceTrans', totalTime - tlsHandshake);
          }
        } else if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.startTransferTimeMs !== undefined) {
          // Fallback: if tlsHandshakeTimeMs not available, calculate from totalTimeMs - startTransferTimeMs
          // This gives only Download time, but we can add TTFB if available
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          if (totalTime > startTransfer) {
            const downloadTime = totalTime - startTransfer;
            // Try to add TTFB if available (use ttfbValue calculated above)
            if (ttfbValue !== undefined && ttfbValue > 0) {
              performanceMetrics.set('resourceTrans', downloadTime + ttfbValue);
            } else {
              performanceMetrics.set('resourceTrans', downloadTime);
            }
          }
        } else if (timeInfoObj.transTime !== undefined && typeof timeInfoObj.transTime === 'number') {
          // Assume transTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceTrans', timeInfoObj.transTime as number);
        } else if (timeInfoObj.responseTime !== undefined && typeof timeInfoObj.responseTime === 'number') {
          // Assume responseTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceTrans', timeInfoObj.responseTime as number);
        }
        
        // Download time (totalTimeMs - startTransferTimeMs) - convert from ms to ns
        // Similar to transmission time
        if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.startTransferTimeMs !== undefined) {
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          if (totalTime > startTransfer) {
            performanceMetrics.set('resourceDownloadTime', totalTime - startTransfer);
          }
        } else if (timeInfoObj.downloadTime !== undefined && typeof timeInfoObj.downloadTime === 'number') {
          // Assume downloadTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceDownloadTime', timeInfoObj.downloadTime as number);
        } else if (timeInfoObj.bodyEndTime !== undefined && timeInfoObj.bodyStartTime !== undefined) {
          const bodyStart = typeof timeInfoObj.bodyStartTime === 'number' ? timeInfoObj.bodyStartTime : 0;
          const bodyEnd = typeof timeInfoObj.bodyEndTime === 'number' ? timeInfoObj.bodyEndTime : 0;
          if (bodyEnd > bodyStart) {
            performanceMetrics.set('resourceDownloadTime', bodyEnd - bodyStart);
          }
        }
        
        // Total load time (totalTimeMs in RCP - convert from ms to ns)
        // Aligned with Android: resourceLoad is in nanoseconds
        if (timeInfoObj.totalTimeMs !== undefined && typeof timeInfoObj.totalTimeMs === 'number') {
          performanceMetrics.set('resourceLoad', timeInfoObj.totalTimeMs * MS_TO_NS);
        } else if (timeInfoObj.totalTime !== undefined && typeof timeInfoObj.totalTime === 'number') {
          // Assume totalTime is already in nanoseconds if not from RCP
          performanceMetrics.set('resourceLoad', timeInfoObj.totalTime as number);
        } else {
          // Use calculated responseTime as fallback (convert from ms to ns)
          performanceMetrics.set('resourceLoad', responseTime * MS_TO_NS);
        }
        
        // Store all performance metrics in property Map
        // Note: addProperty expects object type, so we wrap number values
        const perfKeys = Array.from(performanceMetrics.keys());
        for (let i = 0; i < perfKeys.length; i++) {
          const key = perfKeys[i];
          const value = performanceMetrics.get(key);
          if (value !== undefined) {
            // Wrap number in object to satisfy addProperty signature (object type)
            // The value will be stored and can be extracted as a number later
            const metricValue: PerformanceMetricValue = { value: value };
            resourceParams.addProperty(key, metricValue);
          }
        }
        
        // Note: Android does not store raw timeInfo in ResourceParams.property
        // All performance metrics are extracted and stored individually (aligned with Android)
        FTInnerLogger.d(TAG, `[RCP-Resource] Performance metrics extracted for resourceId=${resourceId}: ${summarizePerformanceMetrics(performanceMetrics)}`);
      } else {
        // If no timeInfo, at least store the calculated responseTime
        // Convert from milliseconds to nanoseconds (aligned with Android)
        const MS_TO_NS = 1000000; // 1 millisecond = 1,000,000 nanoseconds
        const resourceLoadNs = responseTime * MS_TO_NS;
        // Wrap number in object to satisfy addProperty signature (object type)
        const metricValue: PerformanceMetricValue = { value: resourceLoadNs };
        resourceParams.addProperty('resourceLoad', metricValue);
        FTInnerLogger.d(TAG, `[RCP-Resource] No timeInfo available, fallback resourceLoad=${responseTime}ms, resourceId=${resourceId}`);
      }

      // If error response, try to capture response body
      if (resourceParams.resourceStatus >= 400) {
        // Note: response.body may be available depending on RCP API
        FTInnerLogger.w(TAG, `[RCP-Resource] Error response detected: status=${resourceParams.resourceStatus}, url=${url}`);
      }

      FTInnerLogger.d(
        TAG,
        `[RCP-Resource] Completed ${method} ${url}, status=${resourceParams.resourceStatus}, duration=${responseTime}ms, contentType=${resourceParams.responseContentType}, contentLength=${resourceParams.responseContentLength}`
      );

      // Set resource data and stop resource
      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      // Get actionId from mapping for fallback (in case ResourceBean was deleted)
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      // Clean up mapping after use
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }

      return response;

    } catch (err) {
      error = err instanceof Error ? err : new Error(String(err));
      const responseTime = Date.now() - startTime;

      // Build error ResourceParams
      const resourceParams = new ResourceParams();
      resourceParams.setUrl(url);
      resourceParams.setResourceMethod(method);
      resourceParams.setRequestErrorMsg(error.message || 'Unknown error');
      resourceParams.setRequestErrorStack(error.stack || '');
      resourceParams.setResourceStatus(0);

      FTInnerLogger.e(
        TAG,
        `[RCP-Resource] Request failed ${method} ${url}, duration=${responseTime}ms, error=${error.message}, stack=${error.stack || 'N/A'}`
      );

      // Set error resource data and stop resource
      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      // Get actionId from mapping for fallback (in case ResourceBean was deleted)
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      // Clean up mapping after use
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }

      // Re-throw the error
      throw error;
    }
  }
}

/**
 * RCP Trace Interceptor
 * Automatically adds trace headers to HTTP requests
 */
export class RCPTraceInterceptor implements rcp.Interceptor {
  private traceInterceptor: FTTraceInterceptor | null = null;
  private isEnabled: boolean = false;

  constructor() {
    this.initialize();
  }

  private initialize(): void {
    try {
      const traceConfigManager = FTTraceConfigManager.getInstance();
      if (traceConfigManager.isAutoTraceEnabled()) {
        // Get trace type as enum directly (more accurate than string conversion)
        const enumTraceType: TraceType = traceConfigManager.getTraceTypeEnum();
        const headerHandler = traceConfigManager.getOverrideHeaderHandler();

        this.traceInterceptor = new DefaultFTTraceInterceptor(enumTraceType, headerHandler);
        this.isEnabled = true;

        FTInnerLogger.d(TAG, `RCP Trace Interceptor initialized: traceType=${enumTraceType.toString()}`);
      } else {
        this.traceInterceptor = null;
        this.isEnabled = false;
        FTInnerLogger.d(TAG, "RCP Trace Interceptor disabled");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize RCP Trace Interceptor: ${error}`);
      this.traceInterceptor = null;
      this.isEnabled = false;
    }
  }

  public enable(): void {
    this.initialize();
  }

  public disable(): void {
    this.isEnabled = false;
    this.traceInterceptor = null;
    FTInnerLogger.d(TAG, "RCP Trace Interceptor disabled");
  }

  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    if (!this.isEnabled || !this.traceInterceptor) {
      return await next.handle(context);
    }

    try {
      // Generate resourceId (aligned with Android: Utils.identifyRequest)
      // Android: Uses ResourceID tag UUID if available, otherwise method + "_" + url
      // In HarmonyOS RCP, we cannot add tags to requests like Android, so we generate a unique UUID for each request
      // RCPTraceInterceptor executes first, so we generate UUID here and store it in header for RCPResourceInterceptor
      const url = context.request.url.href;
      const method = context.request.method || 'GET';
      
      // Check if UUID was already set (shouldn't happen, but defensive check)
      let uniqueId: string | undefined = undefined;
      if (context.request.headers && context.request.headers['X-FT-Resource-ID']) {
        const headerValue = context.request.headers['X-FT-Resource-ID'];
        if (typeof headerValue === 'string') {
          uniqueId = headerValue;
        }
      }
      
      // Generate new UUID (RCPTraceInterceptor executes first, so this is the source of truth)
      if (!uniqueId) {
        uniqueId = Utils.generateUUID();
        
        // Store UUID in request headers so RCPResourceInterceptor can reuse it
        // This ensures both interceptors use the same resourceId
        if (!context.request.headers) {
          context.request.headers = {};
        }
        context.request.headers['X-FT-Resource-ID'] = uniqueId;
      }
      
      // Format: "method_url_uuid" to maintain compatibility with existing trace handler logic
      const resourceId = `${method}_${url}_${uniqueId}`;
      
      // Get trace headers from FTTraceManager (this will create and store handler)
      // Aligned with Android: FTTraceManager.get().getTraceHeader(resourceId, url)
      const traceManager = FTTraceManager.getInstance();
      const traceHeaders = traceManager.getTraceHeader(resourceId, url);
      
      // Build request data for trace interceptor
      const headersMap = new Map<string, string>();
      if (context.request.headers) {
        const headerKeys = Object.keys(context.request.headers);
        for (let i = 0; i < headerKeys.length; i++) {
          const key = headerKeys[i];
          const value = context.request.headers[key];
          if (typeof value === 'string') {
            headersMap.set(key, value);
          } else if (Array.isArray(value) && value.length > 0) {
            headersMap.set(key, value[0] as string);
          }
        }
      }
      
      // Add trace headers to headersMap
      const traceHeaderKeys = Object.keys(traceHeaders);
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        headersMap.set(key, traceHeaders[key]);
      }

      const requestData: HttpRequestData = {
        url: url,
        method: method,
        headers: headersMap,
        body: undefined, // RCP Request body access depends on API
        timestamp: Date.now()
      };

      // Intercept request (this will use the headers we already added)
      const interceptedRequest = this.traceInterceptor.interceptRequest(requestData);

      // Update context request headers with trace headers
      if (!context.request.headers) {
        context.request.headers = {};
      }

      // Add trace headers to context (from interceptedRequest or directly from traceHeaders)
      const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
      for (let i = 0; i < interceptedHeaders.length; i++) {
        const entry = interceptedHeaders[i];
        context.request.headers[entry[0]] = entry[1];
      }

      FTInnerLogger.d(TAG, `[RCP-Trace] Added trace headers for ${method} ${url}, resourceId=${resourceId}, ${summarizeHeaderKeys(traceHeaders)}`);

      // Continue with the request
      const response = await next.handle(context);

      // Intercept response (if needed)
      if (response) {
        const responseHeadersMap = new Map<string, string>();
        if (response.headers) {
          const respHeaderKeys = Object.keys(response.headers);
          for (let i = 0; i < respHeaderKeys.length; i++) {
            const key = respHeaderKeys[i];
            const value = response.headers[key];
            if (typeof value === 'string') {
              responseHeadersMap.set(key, value);
            } else if (Array.isArray(value) && value.length > 0) {
              responseHeadersMap.set(key, value[0] as string);
            }
          }
        }
        
        const responseData: HttpResponseData = {
          url: context.request.url.href,
          statusCode: response.statusCode || 0,
          headers: responseHeadersMap,
          body: undefined, // Response body access depends on API
          timestamp: Date.now()
        };

        this.traceInterceptor.interceptResponse(responseData);
        FTInnerLogger.d(
          TAG,
          `[RCP-Trace] Processed trace response for ${method} ${url}, status=${response.statusCode || 0}, ${summarizeResponseHeaders(response.headers ?? {})}`
        );
      }

      return response;

    } catch (error) {
      FTInnerLogger.e(TAG, `[RCP-Trace] Error in trace interceptor: ${error}`);
      // Continue without trace headers if error occurs
      return await next.handle(context);
    }
  }
}

/**
 * HTTP INITIAL_REQUEST interceptor.
 * It injects trace headers and records the resource start point so it can be finished in FINAL_RESPONSE.
 * @syscap SystemCapability.Communication.NetStack
 * @atomicservice
 * @since 22
 */
export class HttpInitialRequestInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  private traceInterceptor: FTTraceInterceptor | null = null;
  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;

  constructor(traceEnabled?: boolean, resourceEnabled?: boolean) {
    this.traceEnabled = traceEnabled !== undefined
      ? traceEnabled
      : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
    this.resourceEnabled = resourceEnabled !== undefined
      ? resourceEnabled
      : FTRUMConfigManager.getInstance().isResourceTraceEnable();

    if (this.traceEnabled) {
      const traceConfigManager = FTTraceConfigManager.getInstance();
      this.traceInterceptor = new DefaultFTTraceInterceptor(
        traceConfigManager.getTraceTypeEnum(),
        traceConfigManager.getOverrideHeaderHandler()
      );
    }
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    try {
      const url = reqContext.url;
      // HttpRequestContext does not currently expose the request method, so we
      // keep a stable placeholder to preserve the resourceId contract.
      const method = HTTP_METHOD_UNKNOWN;
      const headers = normalizeObjectHeaders(reqContext.header);
      const uniqueId = ensureHttpResourceId(headers);
      const resourceId = buildAutoTrackResourceId(method, url, uniqueId);

      let finalHeaders = headers;
      if (this.traceEnabled && this.traceInterceptor) {
        const traceHeaders = FTTraceManager.getInstance().getTraceHeader(resourceId, url);

        const headersMap = new Map<string, string>();
        const initialHeaderKeys = Object.keys(headers);
        for (let i = 0; i < initialHeaderKeys.length; i++) {
          const key = initialHeaderKeys[i];
          headersMap.set(key, headers[key]);
        }
        const traceHeaderKeys = Object.keys(traceHeaders);
        for (let i = 0; i < traceHeaderKeys.length; i++) {
          const key = traceHeaderKeys[i];
          headersMap.set(key, traceHeaders[key]);
        }

        const interceptedRequest = this.traceInterceptor.interceptRequest({
          url: url,
          method: method,
          headers: headersMap,
          body: undefined,
          timestamp: Date.now()
        });

        finalHeaders = {};
        // Rebuild a plain object here because HttpRequestContext.header expects
        // an Object instead of a Map-like structure.
        const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
        for (let i = 0; i < interceptedHeaders.length; i++) {
          const entry = interceptedHeaders[i];
          finalHeaders[entry[0]] = entry[1];
        }
        finalHeaders[FT_RESOURCE_ID_HEADER] = uniqueId;
      }

      applyNormalizedHeadersToHttpContext(reqContext, finalHeaders);

      let actionId: string | undefined = undefined;
      if (this.resourceEnabled) {
        FTRUMInnerManager.getInstance().startResource(resourceId);
        const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
        if (activeAction && !activeAction.isActionClose()) {
          actionId = activeAction.getId();
        }
      }

      HttpAutoTrackStateStore.getInstance().put({
        resourceId: resourceId,
        url: url,
        method: method,
        startTime: Date.now(),
        requestHeaders: finalHeaders,
        actionId: actionId
      });

      FTInnerLogger.d(
        TAG,
        `[HTTP-Initial] Prepared ${url}, resourceId=${resourceId}, trace=${this.traceEnabled}, resource=${this.resourceEnabled}, ${summarizeHeaderKeys(finalHeaders)}`
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Initial] Failed to process interceptor: ${error}`);
    }
    return true;
  }
}

/**
 * HTTP FINAL_RESPONSE interceptor.
 * It complements the INITIAL_REQUEST interceptor by transforming the final response into the existing resource model.
 * @syscap SystemCapability.Communication.NetStack
 * @atomicservice
 * @since 22
 */
export class HttpFinalResponseInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  private traceInterceptor: FTTraceInterceptor | null = null;
  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;

  constructor(traceEnabled?: boolean, resourceEnabled?: boolean) {
    this.traceEnabled = traceEnabled !== undefined
      ? traceEnabled
      : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
    this.resourceEnabled = resourceEnabled !== undefined
      ? resourceEnabled
      : FTRUMConfigManager.getInstance().isResourceTraceEnable();

    if (this.traceEnabled) {
      const traceConfigManager = FTTraceConfigManager.getInstance();
      this.traceInterceptor = new DefaultFTTraceInterceptor(
        traceConfigManager.getTraceTypeEnum(),
        traceConfigManager.getOverrideHeaderHandler()
      );
    }
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, rspContext: http.HttpResponse): Promise<boolean> {
    const requestHeaders = normalizeObjectHeaders(reqContext.header);
    const uniqueId = requestHeaders[FT_RESOURCE_ID_HEADER];
    const url = reqContext.url;
    const fallbackResourceId = uniqueId
      ? buildAutoTrackResourceId(HTTP_METHOD_UNKNOWN, url, uniqueId)
      : undefined;
    const state = fallbackResourceId ? HttpAutoTrackStateStore.getInstance().get(fallbackResourceId) : undefined;

    if (!state) {
      FTInnerLogger.w(TAG, `[HTTP-Final] Missing initial interceptor state for ${url}, uniqueId=${uniqueId ?? 'N/A'}`);
      return true;
    }

    const resourceId = state.resourceId;
    try {
      if (this.traceEnabled && this.traceInterceptor) {
        const responseHeaders = normalizeObjectHeaders(rspContext.header);
        const responseHeaderMap = new Map<string, string>();
        const responseHeaderKeys = Object.keys(responseHeaders);
        for (let i = 0; i < responseHeaderKeys.length; i++) {
          const key = responseHeaderKeys[i];
          responseHeaderMap.set(key, responseHeaders[key]);
        }

        const traceHandler = FTTraceManager.getInstance().getHandler(resourceId);
        const traceId = traceHandler && traceHandler.getTraceID ? traceHandler.getTraceID() : undefined;
        const spanId = traceHandler && traceHandler.getSpanID ? traceHandler.getSpanID() : undefined;
        this.traceInterceptor.interceptResponse({
          url: url,
          statusCode: rspContext.responseCode || 0,
          headers: responseHeaderMap,
          body: tryGetResponseBodyText(rspContext.result),
          timestamp: Date.now(),
          traceId: traceId,
          spanId: spanId,
          duration: Date.now() - state.startTime
        });
      }

      if (this.resourceEnabled) {
        const resourceParams = new ResourceParams();
        resourceParams.setUrl(url);
        resourceParams.setResourceMethod(state.method);
        resourceParams.setRequestHeaderMap(buildRequestHeaderMap(state.requestHeaders));
        resourceParams.setRequestHeader(JSON.stringify(state.requestHeaders));
        resourceParams.setResourceStatus(rspContext.responseCode || 0);

        const responseHeaders = normalizeObjectHeaders(rspContext.header);
        resourceParams.setResponseHeaderMap(buildResponseHeaderMap(responseHeaders));
        resourceParams.setResponseHeader(JSON.stringify(responseHeaders));

        const contentType = responseHeaders['content-type'] || responseHeaders['Content-Type'];
        const contentEncoding = responseHeaders['content-encoding'] || responseHeaders['Content-Encoding'];
        const connection = responseHeaders['connection'] || responseHeaders['Connection'];
        if (contentType) {
          resourceParams.setResponseContentType(contentType);
        }
        if (contentEncoding) {
          resourceParams.setResponseContentEncoding(contentEncoding);
        }
        if (connection) {
          resourceParams.setResponseConnection(connection);
        }

        const contentLength = extractContentLength(responseHeaders);
        if (contentLength > 0) {
          resourceParams.setResponseContentLength(contentLength);
        }

        // NetworkKit's interceptor API does not expose the detailed timing
        // breakdown available in RCP timeInfo, so we only provide total load.
        const durationNs = (Date.now() - state.startTime) * 1000000;
        const metricValue: PerformanceMetricValue = { value: durationNs };
        resourceParams.addProperty('resourceLoad', metricValue);

        if ((rspContext.responseCode || 0) >= 400) {
          const responseBodyText = tryGetResponseBodyText(rspContext.result);
          if (responseBodyText) {
            resourceParams.setRequestErrorMsg(responseBodyText);
          }
        }

        FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
        FTRUMInnerManager.getInstance().stopResource(resourceId, state.actionId);

        FTInnerLogger.d(
          TAG,
          `[HTTP-Final] Completed ${url}, resourceId=${resourceId}, status=${rspContext.responseCode || 0}, duration=${Date.now() - state.startTime}ms`
        );
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Final] Failed to process interceptor for ${resourceId}: ${error}`);
      if (this.resourceEnabled) {
        const resourceParams = new ResourceParams();
        resourceParams.setUrl(url);
        resourceParams.setResourceMethod(state.method);
        resourceParams.setRequestErrorMsg(String(error));
        resourceParams.setResourceStatus(0);
        FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
        FTRUMInnerManager.getInstance().stopResource(resourceId, state.actionId);
      }
    } finally {
      HttpAutoTrackStateStore.getInstance().delete(resourceId);
    }

    return true;
  }
}

/**
 * Options for building a session configuration with FT interceptors.
 */
export interface FTRCPSessionConfigurationOptions {
  baseAddress?: string;
  headers?: Record<string, string>;
  interceptors?: rcp.Interceptor[];
  requestConfiguration?: FTRCPRequestConfiguration;
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;
}

export interface FTHttpInterceptorChainOptions {
  interceptors?: http.HttpInterceptor[];
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;
}

export interface FTHttpTrackConfigTarget {
  interceptorChain?: http.HttpInterceptorChain;
}

interface FTRCPInfoToCollectConfiguration {
  incomingHeader: boolean;
  outgoingHeader: boolean;
  incomingData: boolean;
  outgoingData: boolean;
}

interface FTRCPTracingConfiguration {
  verbose?: boolean;
  infoToCollect?: FTRCPInfoToCollectConfiguration;
  collectTimeInfo?: boolean;
}

interface FTRCPRequestConfiguration {
  tracing?: FTRCPTracingConfiguration;
}

/**
 * Build the default FT interceptor list for an RCP session.
 */
export function createFTRCPInterceptors(
  enableTraceInterceptor?: boolean,
  enableResourceInterceptor?: boolean
): rcp.Interceptor[] {
  const traceEnabled = enableTraceInterceptor !== undefined
    ? enableTraceInterceptor
    : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
  const resourceEnabled = enableResourceInterceptor !== undefined
    ? enableResourceInterceptor
    : FTRUMConfigManager.getInstance().isResourceTraceEnable();

  const interceptors: rcp.Interceptor[] = [];
  if (traceEnabled) {
    interceptors.push(new RCPTraceInterceptor());
  }
  if (resourceEnabled) {
    interceptors.push(new RCPResourceInterceptor());
  }
  return interceptors;
}

/**
 * Build the default FT interceptor list for @kit.NetworkKit http requests.
 * @returns { http.HttpInterceptor[] } The FT interceptor list for Harmony HTTP requests.
 * @syscap SystemCapability.Communication.NetStack
 * @atomicservice
 * @since 22
 */
export function createFTHttpInterceptors(
  enableTraceInterceptor?: boolean,
  enableResourceInterceptor?: boolean
): http.HttpInterceptor[] {
  const traceEnabled = enableTraceInterceptor !== undefined
    ? enableTraceInterceptor
    : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
  const resourceEnabled = enableResourceInterceptor !== undefined
    ? enableResourceInterceptor
    : FTRUMConfigManager.getInstance().isResourceTraceEnable();

  const interceptors: http.HttpInterceptor[] = [];
  if (traceEnabled || resourceEnabled) {
    interceptors.push(new HttpInitialRequestInterceptor(traceEnabled, resourceEnabled));
    interceptors.push(new HttpFinalResponseInterceptor(traceEnabled, resourceEnabled));
  }
  return interceptors;
}

/**
 * Create an HTTP interceptor chain that can be attached to a specific HttpRequest instance.
 * @param { FTHttpInterceptorChainOptions } options - The FT HTTP interceptor chain options.
 * @returns { http.HttpInterceptorChain } The FT HTTP interceptor chain.
 * @syscap SystemCapability.Communication.NetStack
 * @atomicservice
 * @since 22
 */
export function createFTHttpInterceptorChain(
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = new http.HttpInterceptorChain();
  const interceptors = createFTHttpInterceptors(
    options.enableTraceInterceptor,
    options.enableResourceInterceptor
  );

  if (options.interceptors && options.interceptors.length > 0) {
    for (let i = 0; i < options.interceptors.length; i++) {
      interceptors.push(options.interceptors[i]);
    }
  }

  if (interceptors.length > 0) {
    chain.addChain(interceptors);
  }
  return chain;
}

/**
 * Attach the default FT http interceptor chain to a specific HttpRequest.
 * Only one chain can be attached to a given request.
 * @param { http.HttpRequest } httpRequest - Initiates an HTTP request to a given URL.
 * @param { FTHttpInterceptorChainOptions } options - The FT HTTP interceptor chain options.
 * @returns { http.HttpInterceptorChain } The applied FT HTTP interceptor chain.
 * @throws { BusinessError } 2300801 - Parameter type not supported by the interceptor.
 * @throws { BusinessError } 2300999 - Internal error.
 * @syscap SystemCapability.Communication.NetStack
 * @atomicservice
 * @since 22
 */
export function applyFTHttpTrack(
  httpRequest: http.HttpRequest,
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = createFTHttpInterceptorChain(options);
  chain.apply(httpRequest);
  return chain;
}

/**
 * Create a default RCP session configuration that includes FT interceptors.
 * Users still own the session lifecycle and can override any configuration they need.
 */
export function createFTRCPTrackConfig(
  options: FTRCPSessionConfigurationOptions = {}
): rcp.SessionConfiguration {
  const defaultInfoToCollect: FTRCPInfoToCollectConfiguration = {
    incomingHeader: true,
    outgoingHeader: true,
    incomingData: false,
    outgoingData: false
  };

  const tracingConfig: FTRCPTracingConfiguration = {
    verbose: false,
    infoToCollect: defaultInfoToCollect,
    collectTimeInfo: true
  };

  const interceptors = createFTRCPInterceptors(
    options.enableTraceInterceptor,
    options.enableResourceInterceptor
  );

  if (options.interceptors && options.interceptors.length > 0) {
    const customInterceptors = options.interceptors;
    for (let i = 0; i < customInterceptors.length; i++) {
      interceptors.push(customInterceptors[i]);
    }
  }

  let mergedTracingConfig: FTRCPTracingConfiguration = {
    verbose: false,
    infoToCollect: {
      incomingHeader: defaultInfoToCollect.incomingHeader,
      outgoingHeader: defaultInfoToCollect.outgoingHeader,
      incomingData: defaultInfoToCollect.incomingData,
      outgoingData: defaultInfoToCollect.outgoingData
    },
    collectTimeInfo: true
  };

  if (options.requestConfiguration && options.requestConfiguration.tracing) {
    const customTracing = options.requestConfiguration.tracing;
    const customInfoToCollect = customTracing.infoToCollect;
    mergedTracingConfig = {
      verbose: customTracing.verbose !== undefined ? customTracing.verbose : false,
      infoToCollect: {
        incomingHeader: customInfoToCollect && customInfoToCollect.incomingHeader !== undefined
          ? customInfoToCollect.incomingHeader
          : defaultInfoToCollect.incomingHeader,
        outgoingHeader: customInfoToCollect && customInfoToCollect.outgoingHeader !== undefined
          ? customInfoToCollect.outgoingHeader
          : defaultInfoToCollect.outgoingHeader,
        incomingData: customInfoToCollect && customInfoToCollect.incomingData !== undefined
          ? customInfoToCollect.incomingData
          : defaultInfoToCollect.incomingData,
        outgoingData: customInfoToCollect && customInfoToCollect.outgoingData !== undefined
          ? customInfoToCollect.outgoingData
          : defaultInfoToCollect.outgoingData
      },
      collectTimeInfo: customTracing.collectTimeInfo !== undefined
        ? customTracing.collectTimeInfo
        : true
    };
  }

  let requestConfiguration: FTRCPRequestConfiguration;
  if (options.requestConfiguration) {
    requestConfiguration = {
      tracing: mergedTracingConfig
    };
  } else {
    requestConfiguration = {
      tracing: tracingConfig
    };
  }

  return {
    baseAddress: options.baseAddress,
    headers: options.headers,
    interceptors: interceptors,
    requestConfiguration: requestConfiguration
  };
}
