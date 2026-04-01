/**
 * RCP network interceptors and session configuration helpers.
 */

import { rcp } from '@kit.RemoteCommunicationKit';
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
    FTInnerLogger.d(TAG, `[RCP-Resource] ========== Interceptor called ==========`);
    FTInnerLogger.d(TAG, `[RCP-Resource] isEnabled: ${this.isEnabled}`);
    
    if (!this.isEnabled) {
      FTInnerLogger.w(TAG, `[RCP-Resource] Interceptor disabled, bypassing`);
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
        FTInnerLogger.d(TAG, `[RCP-Resource] Reusing resourceId UUID from header (set by trace interceptor): ${uniqueId}`);
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

    FTInnerLogger.d(TAG, `[RCP-Resource] ========== Intercepting request ==========`);
    FTInnerLogger.d(TAG, `[RCP-Resource] URL: ${url}`);
    FTInnerLogger.d(TAG, `[RCP-Resource] Method: ${method}`);
    FTInnerLogger.d(TAG, `[RCP-Resource] ResourceId: ${resourceId}`);
    
    // Log request headers (NOTE: These may contain stale trace_id from previous requests)
    // We will get the correct trace_id from handler and merge it below
    if (context.request.headers) {
      const headerStr = JSON.stringify(context.request.headers);
      FTInnerLogger.d(TAG, `[RCP-Resource] Headers (may contain stale trace_id): ${headerStr.substring(0, 200)}...`);
    }

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
    FTInnerLogger.d(TAG, `[RCP-Resource] Checking handler for resourceId=${resourceId}: handler=${handler ? 'exists' : 'null'}`);
    if (handler && handler.getTraceID && handler.getSpanID) {
      try {
        const traceId = handler.getTraceID();
        const spanId = handler.getSpanID();
        FTInnerLogger.d(TAG, `[RCP-Resource] Got traceId=${traceId}, spanId=${spanId} from handler`);
        if (traceId && spanId) {
          // Get trace type from config to build correct headers
          const traceConfigManager = FTTraceConfigManager.getInstance();
          const traceType = traceConfigManager.getTraceType();
          FTInnerLogger.d(TAG, `[RCP-Resource] Trace type: ${traceType}`);
          
          // Build trace headers based on trace type (aligned with FTTraceHandler.generateDataDogHeaders, etc.)
          if (traceType === 'ddtrace') {
            // DataDog trace headers
            savedRequestHeaders[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = traceId;
            savedRequestHeaders[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = spanId;
            savedRequestHeaders[FTTraceHandler.DD_TRACE_ORIGIN_KEY] = "rum";
            savedRequestHeaders[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = "2"; // Default to sampled
            FTInnerLogger.d(TAG, `[RCP-Resource] Merged DataDog trace headers from handler: traceId=${traceId}, spanId=${spanId}`);
          } else if (traceType === 'zipkin_single_header') {
            // Zipkin Single Header: only b3 header (format: traceId-spanId-sampled)
            const sampled = "1"; // Default to sampled
            savedRequestHeaders[FTTraceHandler.ZIPKIN_B3_HEADER] = `${traceId}-${spanId}-${sampled}`;
            FTInnerLogger.d(TAG, `[RCP-Resource] Merged Zipkin Single Header (b3) from handler: traceId=${traceId}, spanId=${spanId}`);
          } else if (traceType === 'zipkin' || traceType === 'zipkin_multi_header') {
            // Zipkin Multi Header: X-B3-* headers
            savedRequestHeaders[FTTraceHandler.ZIPKIN_TRACE_ID] = traceId;
            savedRequestHeaders[FTTraceHandler.ZIPKIN_SPAN_ID] = spanId;
            savedRequestHeaders[FTTraceHandler.ZIPKIN_SAMPLED] = "1"; // Default to sampled
            FTInnerLogger.d(TAG, `[RCP-Resource] Merged Zipkin Multi Header (X-B3-*) from handler: traceId=${traceId}, spanId=${spanId}`);
          } else if (traceType === 'traceparent') {
            // W3C Traceparent header
            const version = "00";
            const sampledStr = "01"; // Default to sampled
            savedRequestHeaders[FTTraceHandler.W3C_TRACEPARENT_KEY] = `${version}-${traceId}-${spanId}-${sampledStr}`;
            FTInnerLogger.d(TAG, `[RCP-Resource] Merged W3C traceparent header from handler: traceId=${traceId}, spanId=${spanId}`);
          } else if (traceType === 'jaeger') {
            // Jaeger trace headers
            const parentSpanID = "0";
            savedRequestHeaders[FTTraceHandler.JAEGER_KEY] = `${traceId}:${spanId}:${parentSpanID}:1`;
            FTInnerLogger.d(TAG, `[RCP-Resource] Merged Jaeger trace headers from handler: traceId=${traceId}, spanId=${spanId}`);
          }
        } else {
          FTInnerLogger.w(TAG, `[RCP-Resource] Handler exists but traceId or spanId is empty: traceId=${traceId}, spanId=${spanId}`);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Failed to get trace headers from handler: ${error}`);
      }
    } else {
      FTInnerLogger.d(TAG, `[RCP-Resource] Handler not found for resourceId=${resourceId}, using headers from context.request.headers`);
    }
    
    // Log final saved headers to confirm correct trace_id is used
    const finalHeaderStr = JSON.stringify(savedRequestHeaders);
    FTInnerLogger.d(TAG, `[RCP-Resource] Final saved request headers (after trace header merge): ${finalHeaderStr.substring(0, 200)}...`);
    FTInnerLogger.d(TAG, `[RCP-Resource] Saved request headers before next.handle(): ${Object.keys(savedRequestHeaders).length} headers`);

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
    // Log updated context.request.headers to confirm correct trace_id and span_id are set
    const updatedHeaderStr = JSON.stringify(context.request.headers);
    FTInnerLogger.d(TAG, `[RCP-Resource] Updated context.request.headers with correct trace headers: ${updatedHeaderStr.substring(0, 200)}...`);

    // Record request start
    FTInnerLogger.d(TAG, `[RCP-Resource] Starting resource tracking...`);
    FTRUMInnerManager.getInstance().startResource(resourceId);
    FTInnerLogger.d(TAG, `[RCP-Resource] Resource tracking started`);
    
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
      FTInnerLogger.d(TAG, `[RCP-Resource] Saved resourceId->actionId mapping: ${resourceId} -> ${actionId}`);
    }

    const startTime = Date.now();
    let response: rcp.Response | null = null;
    let error: Error | null = null;

    try {
      // Continue with the request (now context.request.headers contains the correct trace_id)
      FTInnerLogger.d(TAG, `[RCP-Resource] About to call next.handle() for resourceId=${resourceId}`);
      response = await next.handle(context);
      FTInnerLogger.d(TAG, `[RCP-Resource] next.handle() completed, response=${response ? 'exists' : 'null'}`);
      
      if (response) {
        FTInnerLogger.d(TAG, `[RCP-Resource] Response statusCode: ${response.statusCode || 'undefined'}`);
        FTInnerLogger.d(TAG, `[RCP-Resource] Response timeInfo: ${response.timeInfo ? 'exists' : 'null/undefined'}`);
        if (response.timeInfo) {
          FTInnerLogger.d(TAG, `[RCP-Resource] Response timeInfo type: ${typeof response.timeInfo}`);
        }
      } else {
        FTInnerLogger.w(TAG, `[RCP-Resource] ⚠️ Response is null after next.handle()`);
      }

      // Record response data
      const responseTime = Date.now() - startTime;
      FTInnerLogger.d(TAG, `[RCP-Resource] Calculated responseTime: ${responseTime}ms`);
      
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
        FTInnerLogger.d(TAG, `[RCP-Resource] TimeInfo available: ${JSON.stringify(response.timeInfo).substring(0, 200)}...`);
        
        // Extract performance metrics from timeInfo
        // timeInfo structure may vary, try to extract common metrics
        // Convert TimeInfo to TimeInfoStructure via object for type safety
        // (TimeInfo type doesn't overlap with TimeInfoStructure, so we use object as intermediate)
        const timeInfoObj = response.timeInfo as object as TimeInfoStructure;
        
        // Debug: Log all available TimeInfo fields to verify preTransferTimeMs availability
        FTInnerLogger.d(TAG, `[RCP-Resource-TimeInfo] nameLookupTimeMs=${timeInfoObj.nameLookupTimeMs}, connectTimeMs=${timeInfoObj.connectTimeMs}, tlsHandshakeTimeMs=${timeInfoObj.tlsHandshakeTimeMs}, preTransferTimeMs=${timeInfoObj.preTransferTimeMs}, startTransferTimeMs=${timeInfoObj.startTransferTimeMs}, totalTimeMs=${timeInfoObj.totalTimeMs}`);
        
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
        
        // Debug: Check if preTransferTimeMs is available
        const hasPreTransfer = timeInfoObj.preTransferTimeMs !== undefined;
        const hasStartTransfer = timeInfoObj.startTransferTimeMs !== undefined;
        const hasTlsHandshake = timeInfoObj.tlsHandshakeTimeMs !== undefined;
        FTInnerLogger.d(TAG, `[TTFB-CALC] Field availability check: preTransferTimeMs=${hasPreTransfer}, startTransferTimeMs=${hasStartTransfer}, tlsHandshakeTimeMs=${hasTlsHandshake}`);
        
        if (hasStartTransfer && hasPreTransfer) {
          // Preferred: use preTransferTimeMs to align with Android's headerStartTime
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const preTransfer = (typeof timeInfoObj.preTransferTimeMs === 'number' ? timeInfoObj.preTransferTimeMs : 0) * MS_TO_NS;
          FTInnerLogger.d(TAG, `[TTFB-CALC] ✅ Using preTransferTimeMs: startTransfer=${startTransfer / MS_TO_NS}ms, preTransfer=${preTransfer / MS_TO_NS}ms`);
          if (startTransfer > preTransfer) {
            ttfbValue = startTransfer - preTransfer;
            FTInnerLogger.d(TAG, `[TTFB-CALC] ✅ TTFB = ${ttfbValue / MS_TO_NS}ms (startTransfer - preTransfer)`);
          } else if (startTransfer > 0) {
            ttfbValue = startTransfer;
            FTInnerLogger.d(TAG, `[TTFB-CALC] ⚠️ TTFB = ${ttfbValue / MS_TO_NS}ms (startTransfer only, preTransfer invalid: ${preTransfer / MS_TO_NS}ms >= ${startTransfer / MS_TO_NS}ms)`);
          }
        } else if (hasStartTransfer && hasTlsHandshake) {
          // Fallback: if preTransferTimeMs not available, use tlsHandshakeTimeMs
          // This gives SSL completion to first byte (longer, but still valid)
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const tlsHandshake = (typeof timeInfoObj.tlsHandshakeTimeMs === 'number' ? timeInfoObj.tlsHandshakeTimeMs : 0) * MS_TO_NS;
          FTInnerLogger.d(TAG, `[TTFB-CALC] ⚠️ Fallback: preTransferTimeMs not available, using tlsHandshakeTimeMs: startTransfer=${startTransfer / MS_TO_NS}ms, tlsHandshake=${tlsHandshake / MS_TO_NS}ms`);
          if (startTransfer > tlsHandshake) {
            ttfbValue = startTransfer - tlsHandshake;
            FTInnerLogger.d(TAG, `[TTFB-CALC] ⚠️ TTFB = ${ttfbValue / MS_TO_NS}ms (startTransfer - tlsHandshake)`);
          } else if (startTransfer > 0) {
            ttfbValue = startTransfer;
            FTInnerLogger.d(TAG, `[TTFB-CALC] ⚠️ TTFB = ${ttfbValue / MS_TO_NS}ms (startTransfer only, tlsHandshake invalid)`);
          }
        } else if (timeInfoObj.ttfbTime !== undefined && typeof timeInfoObj.ttfbTime === 'number') {
          // Assume ttfbTime is already in nanoseconds if not from RCP
          ttfbValue = timeInfoObj.ttfbTime as number;
          FTInnerLogger.d(TAG, `[TTFB-CALC] Using ttfbTime directly: ${ttfbValue / MS_TO_NS}ms`);
        } else if (timeInfoObj.firstByteTime !== undefined && typeof timeInfoObj.firstByteTime === 'number') {
          // Assume firstByteTime is already in nanoseconds if not from RCP
          ttfbValue = timeInfoObj.firstByteTime as number;
          FTInnerLogger.d(TAG, `[TTFB-CALC] Using firstByteTime directly: ${ttfbValue / MS_TO_NS}ms`);
        } else {
          FTInnerLogger.w(TAG, `[TTFB-CALC] No TTFB calculation method available, TTFB will be missing`);
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
            // Log in both nanoseconds and milliseconds for debugging (value is in nanoseconds)
            const valueMs = value / 1000000;
            FTInnerLogger.d(TAG, `[RCP-Resource] Performance metric ${key}: ${value}ns (${valueMs.toFixed(2)}ms)`);
          }
        }
        
        // Note: Android does not store raw timeInfo in ResourceParams.property
        // All performance metrics are extracted and stored individually (aligned with Android)
        FTInnerLogger.d(TAG, `[RCP-Resource] Extracted ${perfKeys.length} performance metrics`);
      } else {
        // If no timeInfo, at least store the calculated responseTime
        // Convert from milliseconds to nanoseconds (aligned with Android)
        const MS_TO_NS = 1000000; // 1 millisecond = 1,000,000 nanoseconds
        const resourceLoadNs = responseTime * MS_TO_NS;
        // Wrap number in object to satisfy addProperty signature (object type)
        const metricValue: PerformanceMetricValue = { value: resourceLoadNs };
        resourceParams.addProperty('resourceLoad', metricValue);
        FTInnerLogger.d(TAG, `[RCP-Resource] No timeInfo available, using calculated responseTime: ${responseTime}ms (${resourceLoadNs}ns)`);
      }

      // If error response, try to capture response body
      if (resourceParams.resourceStatus >= 400) {
        // Note: response.body may be available depending on RCP API
        FTInnerLogger.d(TAG, `[RCP-Resource] Error response detected: ${resourceParams.resourceStatus}`);
      }

      FTInnerLogger.d(TAG, `[RCP-Resource] ========== Request completed ==========`);
      FTInnerLogger.d(TAG, `[RCP-Resource] URL: ${url}`);
      FTInnerLogger.d(TAG, `[RCP-Resource] Status: ${resourceParams.resourceStatus}`);
      FTInnerLogger.d(TAG, `[RCP-Resource] Response time: ${responseTime}ms`);
      FTInnerLogger.d(TAG, `[RCP-Resource] Content-Type: ${resourceParams.responseContentType}`);
      FTInnerLogger.d(TAG, `[RCP-Resource] Content-Length: ${resourceParams.responseContentLength}`);

      // Set resource data and stop resource
      FTInnerLogger.d(TAG, `[RCP-Resource] Setting resource data and stopping resource...`);
      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      // Get actionId from mapping for fallback (in case ResourceBean was deleted)
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      // Clean up mapping after use
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }
      FTInnerLogger.d(TAG, `[RCP-Resource] Resource data collected and uploaded`);

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

      FTInnerLogger.e(TAG, `[RCP-Resource] ========== Request failed ==========`);
      FTInnerLogger.e(TAG, `[RCP-Resource] URL: ${url}`);
      FTInnerLogger.e(TAG, `[RCP-Resource] Method: ${method}`);
      FTInnerLogger.e(TAG, `[RCP-Resource] Error message: ${error.message}`);
      FTInnerLogger.e(TAG, `[RCP-Resource] Error stack: ${error.stack || 'N/A'}`);
      FTInnerLogger.e(TAG, `[RCP-Resource] Response time: ${responseTime}ms`);

      // Set error resource data and stop resource
      FTInnerLogger.d(TAG, `[RCP-Resource] Setting error resource data and stopping resource...`);
      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      // Get actionId from mapping for fallback (in case ResourceBean was deleted)
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      // Clean up mapping after use
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }
      FTInnerLogger.d(TAG, `[RCP-Resource] Error resource data collected and uploaded`);

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
    // Log interceptor entry point (hook point for session.fetch())
    FTInnerLogger.d(TAG, `[RCP-Trace] ========== Interceptor triggered (session.fetch() hook) ==========`);
    FTInnerLogger.d(TAG, `[RCP-Trace] Interceptor entry: URL=${context.request.url.href}, Method=${context.request.method || 'GET'}`);
    
    if (!this.isEnabled || !this.traceInterceptor) {
      FTInnerLogger.d(TAG, `[RCP-Trace] Interceptor disabled or not initialized, bypassing trace header injection`);
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
          FTInnerLogger.d(TAG, `[RCP-Trace] Reusing resourceId UUID from header: ${uniqueId}`);
        }
      }
      
      // Generate new UUID (RCPTraceInterceptor executes first, so this is the source of truth)
      if (!uniqueId) {
        uniqueId = Utils.generateUUID();
        FTInnerLogger.d(TAG, `[RCP-Trace] Generated new resourceId UUID: ${uniqueId}`);
        
        // Store UUID in request headers so RCPResourceInterceptor can reuse it
        // This ensures both interceptors use the same resourceId
        if (!context.request.headers) {
          context.request.headers = {};
        }
        context.request.headers['X-FT-Resource-ID'] = uniqueId;
        FTInnerLogger.d(TAG, `[RCP-Trace] Stored resourceId UUID in header for resource interceptor: ${uniqueId}`);
      }
      
      // Format: "method_url_uuid" to maintain compatibility with existing trace handler logic
      const resourceId = `${method}_${url}_${uniqueId}`;
      
      FTInnerLogger.d(TAG, `[RCP-Trace] Generated resourceId: ${resourceId}`);
      
      // Get trace headers from FTTraceManager (this will create and store handler)
      // Aligned with Android: FTTraceManager.get().getTraceHeader(resourceId, url)
      const traceManager = FTTraceManager.getInstance();
      const traceHeaders = traceManager.getTraceHeader(resourceId, url);
      
      FTInnerLogger.d(TAG, `[RCP-Trace] Got trace headers from FTTraceManager: ${Object.keys(traceHeaders).length} headers`);
      
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

      FTInnerLogger.d(TAG, `[RCP-Trace] ========== Adding trace headers ==========`);
      FTInnerLogger.d(TAG, `[RCP-Trace] URL: ${url}`);
      FTInnerLogger.d(TAG, `[RCP-Trace] Method: ${method}`);
      
      // Log added trace headers
      const addedHeaders: string[] = [];
      // Reuse traceHeaderKeys from above (line 507)
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        addedHeaders.push(`${key}: ${traceHeaders[key]}`);
      }
      FTInnerLogger.d(TAG, `[RCP-Trace] Added trace headers (${addedHeaders.length}): ${addedHeaders.join(', ')}`);
      FTInnerLogger.d(TAG, `[RCP-Trace] Handler stored with resourceId: ${resourceId}`);

      // Continue with the request
      const response = await next.handle(context);

      // Intercept response (if needed)
      if (response) {
        FTInnerLogger.d(TAG, `[RCP-Trace] ========== Processing trace response ==========`);
        FTInnerLogger.d(TAG, `[RCP-Trace] URL: ${context.request.url.href}`);
        FTInnerLogger.d(TAG, `[RCP-Trace] Status: ${response.statusCode || 0}`);
        
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

        if (responseHeadersMap.size > 0) {
          // Convert Map to object manually (avoid Object.fromEntries)
          const headerObj: Record<string, string> = {};
          const headerEntries = Array.from(responseHeadersMap.entries());
          for (let i = 0; i < headerEntries.length; i++) {
            const entry = headerEntries[i];
            headerObj[entry[0]] = entry[1];
          }
          const respHeaderStr = JSON.stringify(headerObj);
          FTInnerLogger.d(TAG, `[RCP-Trace] Response headers: ${respHeaderStr.substring(0, 200)}...`);
        }

        this.traceInterceptor.interceptResponse(responseData);
        FTInnerLogger.d(TAG, `[RCP-Trace] Trace response processed`);
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
export function createDefaultFTInterceptors(
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
 * Create a default RCP session configuration that includes FT interceptors.
 * Users still own the session lifecycle and can override any configuration they need.
 */
export function createDefaultFTSessionConfiguration(
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

  const interceptors = createDefaultFTInterceptors(
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
