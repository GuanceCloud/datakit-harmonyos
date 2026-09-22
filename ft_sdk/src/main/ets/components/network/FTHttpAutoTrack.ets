/**
 * RCP network interceptors and session configuration helpers.
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { FTTraceInterceptor, DefaultFTTraceInterceptor, HttpRequestData, HttpResponseData } from '../trace/FTTraceInterceptor';
import { FTTraceConfigManager } from '../trace/FTTraceConfigManager';
import { FTTraceContext, FTTraceRequestContext } from '../trace/FTTraceHeaderHandler';
import { TraceType } from '../trace/TraceType';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { ResourceParams } from '../rum/bean/ResourceParams';
import { FTInnerLogger } from '../log/FTLogger';
import { FTTraceManager } from '../trace/FTTraceManager';
import { FTTraceHandler } from '../trace/FTTraceHandler';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import {
  createFTNetworkErrorContext,
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkErrorHandlingResult,
  FTNetworkErrorRaw,
  FTNetworkErrorSource,
  getFTNetworkErrorMessage,
  getFTNetworkErrorStack,
  handleFTNetworkError
} from './FTNetworkErrorHandler';
import {
  AxiosChainMethodStore,
  buildAutoTrackResourceId,
  buildRequestHeaderMap,
  buildResponseHeaderMap,
  ensureHttpResourceId,
  extractContentLength,
  FTAutoTrackOptions,
  FTNetworkPerformanceTiming,
  FTResourceTiming,
  HttpAutoTrackCompletionStore,
  HttpAutoTrackState,
  normalizeObjectHeaders,
  PerformanceMetricValue,
  createFallbackFTResourceTiming,
  createFTNetStatusBean,
  createFTResourceTimingFromCumulative,
  createFTResourceTimingFromNetworkPerformance,
  resolveAxiosChainMethod,
  summarizeHeaderKeys,
  summarizePerformanceMetrics,
  summarizeResponseHeaders,
  tryGetOptionalResponseBodyText
} from './FTHttpAutoTrackShared';

const TAG = "FTHttpAutoTrack";
const MS_TO_NS = 1000000;

/** Resolves a per-integration override before the RUM-level default. */
function resolveNetworkErrorHandler(
  handler: FTNetworkErrorHandler | null | undefined
): FTNetworkErrorHandler | undefined {
  if (handler !== undefined) {
    return handler ?? undefined;
  }
  return FTRUMConfigManager.getInstance().getNetworkErrorHandler();
}

function addNetworkErrorFields(
  resourceParams: ResourceParams,
  handling: FTNetworkErrorHandlingResult | undefined,
  context?: FTNetworkErrorContext
): void {
  if (context) {
    resourceParams.addProperty('network_error_kind', new String(context.kind));
    resourceParams.addProperty('network_error_message', new String(context.message));
  }
  if (!handling) {
    return;
  }
  const keys = Object.keys(handling.resourceFields);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    resourceParams.addProperty(key, handling.resourceFields[key] as object);
  }
  resourceParams.setSuppressNetworkError(handling.suppressNetworkError);
}

function createGeneratedResourceId(): string {
  const headers: Record<string, string> = {};
  return ensureHttpResourceId(headers);
}

function hasKnownTraceHeaders(headers: Record<string, string>): boolean {
  const traceHeaderKeys: string[] = [
    FTTraceHandler.DD_TRACE_TRACE_ID_KEY,
    FTTraceHandler.ZIPKIN_TRACE_ID,
    FTTraceHandler.ZIPKIN_B3_HEADER,
    FTTraceHandler.W3C_TRACEPARENT_KEY,
    FTTraceHandler.JAEGER_KEY,
    FTTraceHandler.SKYWALKING_V3_SW_8
  ];

  for (let i = 0; i < traceHeaderKeys.length; i++) {
    if (headers[traceHeaderKeys[i]] !== undefined) {
      return true;
    }
  }
  return false;
}

function hasKnownTraceHeaderMap(headers: Map<string, string>): boolean {
  const traceHeaderKeys: string[] = [
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
 * Interface for TimeInfo structure from RCP response
 * Represents possible timing data fields
 * Note: ArkTS does not support index signatures, so we only define explicit properties
 * RCP uses camelCase field names (e.g., nameLookupTimeMs, connectTimeMs)
 */
interface TimeInfoStructure {
  nameLookupTimeMs?: number;
  connectTimeMs?: number;
  tlsHandshakeTimeMs?: number;
  preTransferTimeMs?: number;
  startTransferTimeMs?: number;
  totalTimeMs?: number;
  redirectTimeMs?: number;
}

/**
 * RCP preTransfer means transfer-ready, while startTransfer is the received
 * first byte. The shared mapper retains those exact protocol time points.
 */
function createRCPResourceTiming(timeInfo: TimeInfoStructure, fallbackLoadNs: number): FTResourceTiming {
  return createFTResourceTimingFromCumulative({
    dnsEndTimeMs: timeInfo.nameLookupTimeMs,
    connectEndTimeMs: timeInfo.connectTimeMs,
    tlsEndTimeMs: timeInfo.tlsHandshakeTimeMs,
    firstByteWaitStartTimeMs: timeInfo.preTransferTimeMs,
    firstByteTimeMs: timeInfo.startTransferTimeMs,
    totalTimeMs: timeInfo.totalTimeMs
  }, fallbackLoadNs);
}

/**
 * RCP Resource Interceptor
 * Automatically intercepts HTTP requests and collects resource data
 */
export class RCPResourceInterceptor implements rcp.Interceptor {
  private isEnabled: boolean = true;
  private resourceActionMap: Map<string, string> = new Map();
  private readonly networkErrorHandler: FTNetworkErrorHandler | undefined;

  constructor(networkErrorHandler?: FTNetworkErrorHandler) {
    this.networkErrorHandler = networkErrorHandler;
  }

  /**
   * Completes the Resource for a transport failure before the SDK can create
   * its derived network Error. The caller's RCP result is intentionally not
   * handled here: a rejected request is rethrown by intercept(), while a
   * status-0 response is returned unchanged to the application.
   */
  private completeLocalFailure(
    resourceId: string,
    url: string,
    method: string,
    savedRequestHeaders: Record<string, string>,
    startTime: number,
    rawError: FTNetworkErrorRaw
  ): void {
    if (!HttpAutoTrackCompletionStore.getInstance().tryClaim(resourceId)) {
      FTInnerLogger.d(TAG, `[RCP-Resource] Duplicate failure completion ignored: ${resourceId}`);
      return;
    }

    const errorMessage = getFTNetworkErrorMessage(rawError);
    const errorStack = getFTNetworkErrorStack(rawError) || String(rawError);
    const errorContext = createFTNetworkErrorContext(
      url,
      method,
      FTNetworkErrorSource.RCP,
      rawError,
      errorMessage,
      errorStack
    );
    const handling = handleFTNetworkError(this.networkErrorHandler, errorContext);
    const responseTime = Date.now() - startTime;
    const fallbackLoadNs = Math.max(responseTime, 1) * MS_TO_NS;
    const resourceTiming = createFallbackFTResourceTiming(fallbackLoadNs);
    const netStatusBean = createFTNetStatusBean(resourceTiming);
    const resourceParams = new ResourceParams();
    resourceParams.setUrl(url);
    resourceParams.setResourceMethod(method);
    resourceParams.setRequestHeaderMap(buildRequestHeaderMap(savedRequestHeaders));
    resourceParams.setRequestHeader(JSON.stringify(savedRequestHeaders));
    resourceParams.setRequestErrorMsg(errorMessage);
    resourceParams.setRequestErrorStack(errorStack);
    resourceParams.setResourceStatus(0);
    addNetworkErrorFields(resourceParams, handling, errorContext);

    FTInnerLogger.e(
      TAG,
      `[RCP-Resource] Request failed ${method} ${url}, duration=${responseTime}ms, error=${errorMessage}, stack=${errorStack || 'N/A'}`
    );

    FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
    FTRUMInnerManager.getInstance().setNetState(resourceId, netStatusBean);
    const fallbackActionId = this.resourceActionMap.get(resourceId);
    FTRUMInnerManager.getInstance().stopResourceInternal(resourceId, fallbackActionId);
    if (fallbackActionId) {
      this.resourceActionMap.delete(resourceId);
    }
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

    const url = context.request.url.href;
    const method = context.request.method || 'GET';

    if (FTRUMConfigManager.getInstance().shouldFilterResourceUrl(url)) {
      FTInnerLogger.d(TAG, `[RCP-Resource] Filtered ${method} ${url}`);
      return await next.handle(context);
    }

    let uniqueId: string | undefined = undefined;
    if (context.request.headers && context.request.headers['X-FT-Resource-ID']) {
      const headerValue = context.request.headers['X-FT-Resource-ID'];
      if (typeof headerValue === 'string') {
        uniqueId = headerValue;
      }
    }

    if (!uniqueId) {
      uniqueId = createGeneratedResourceId();
      FTInnerLogger.w(TAG, `[RCP-Resource] UUID not found in header, generated new UUID: ${uniqueId}`);

      if (!context.request.headers) {
        context.request.headers = {};
      }
      context.request.headers['X-FT-Resource-ID'] = uniqueId;
    }

    const resourceId = `${method}_${url}_${uniqueId}`;

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

    const traceManager = FTTraceManager.getInstance();
    const traceContext = traceManager.getTraceContext(resourceId);
    if (traceContext) {
      try {
        const contextHeaders = traceContext.headers;
        const contextHeaderKeys = Object.keys(contextHeaders);
        for (let i = 0; i < contextHeaderKeys.length; i++) {
          const key = contextHeaderKeys[i];
          savedRequestHeaders[key] = contextHeaders[key];
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Failed to get trace headers from TraceContext: ${error}`);
      }
    }

    if (!context.request.headers) {
      context.request.headers = {};
    }
    const savedHeaderKeys = Object.keys(savedRequestHeaders);
    for (let i = 0; i < savedHeaderKeys.length; i++) {
      const key = savedHeaderKeys[i];
      context.request.headers[key] = savedRequestHeaders[key];
    }
    FTInnerLogger.d(TAG, `[RCP-Resource] Tracking request ${method} ${url}, resourceId=${resourceId}, ${summarizeHeaderKeys(savedRequestHeaders)}`);

    FTRUMInnerManager.getInstance().startResource(resourceId);

    const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
    if (activeAction && !activeAction.isActionClose()) {
      this.resourceActionMap.set(resourceId, activeAction.getId());
    }

    const startTime = Date.now();

    let response: rcp.Response;
    try {
      response = await next.handle(context);
    } catch (err) {
      try {
        this.completeLocalFailure(resourceId, url, method, savedRequestHeaders, startTime, err);
      } catch (trackingError) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Failed to record local failure for resourceId=${resourceId}: ${trackingError}`);
      }
      // ArkTS permits throwing Error values only. Preserve the native Error
      // object unchanged; primitive/non-Error adapter rejections retain the
      // SDK's existing compatibility wrapper.
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(String(err));
    }

    // A positive status is the only shape that represents a real HTTP
    // response. Should an RCP version resolve a status-0 Response for a local
    // failure, handle it before Error creation but preserve that Response for
    // the caller unchanged.
    if ((response.statusCode || 0) <= 0) {
      try {
        this.completeLocalFailure(
          resourceId,
          url,
          method,
          savedRequestHeaders,
          startTime,
          new Error('RCP request completed without an HTTP response (statusCode=0)')
        );
      } catch (trackingError) {
        FTInnerLogger.w(TAG, `[RCP-Resource] Failed to record status-zero response for resourceId=${resourceId}: ${trackingError}`);
      }
      return response;
    }

    const responseTime = Date.now() - startTime;
    const fallbackLoadNs = Math.max(responseTime, 1) * MS_TO_NS;
    let resourceTiming = createFallbackFTResourceTiming(fallbackLoadNs);
    let netStatusBean = createFTNetStatusBean(resourceTiming);

    const resourceParams = new ResourceParams();
    resourceParams.setUrl(url);
    resourceParams.setResourceMethod(method);
    resourceParams.setRequestHeaderMap(buildRequestHeaderMap(savedRequestHeaders));
    resourceParams.setRequestHeader(JSON.stringify(savedRequestHeaders));
    resourceParams.setResourceStatus(response.statusCode || 0);

    // A response has already been received. Header and timing collection are
    // best-effort only: a malformed platform value must not turn an HTTP
    // response (including 4xx/5xx) into a local network failure with status 0.
    try {
      if (response.headers) {
        const responseHeaders = normalizeObjectHeaders(response.headers as Object);
        const responseHeader = JSON.stringify(response.headers);
        resourceParams.setResponseHeaderMap(buildResponseHeaderMap(responseHeaders));
        resourceParams.setResponseHeader(responseHeader);

        const contentType = responseHeaders['content-type'] || responseHeaders['Content-Type'];
        const contentLength = responseHeaders['content-length'] || responseHeaders['Content-Length'];
        const contentEncoding = responseHeaders['content-encoding'] || responseHeaders['Content-Encoding'];
        const connection = responseHeaders['connection'] || responseHeaders['Connection'];

        if (contentType) {
          resourceParams.setResponseContentType(contentType);
        }
        if (contentLength) {
          const length = parseInt(contentLength, 10);
          if (!isNaN(length)) {
            resourceParams.setResponseContentLength(length);
          }
        }
        if (contentEncoding) {
          resourceParams.setResponseContentEncoding(contentEncoding);
        }
        if (connection) {
          resourceParams.setResponseConnection(connection);
        }
      }
    } catch (error) {
      FTInnerLogger.w(TAG, `[RCP-Resource] Ignored invalid response headers for resourceId=${resourceId}: ${error}`);
    }

    try {
      if (response.timeInfo) {
        const timeInfoObj = response.timeInfo as object as TimeInfoStructure;
        resourceTiming = createRCPResourceTiming(timeInfoObj, fallbackLoadNs);
        netStatusBean = createFTNetStatusBean(resourceTiming);
        FTInnerLogger.d(TAG, `[RCP-Resource] Performance metrics extracted for resourceId=${resourceId}: ${summarizePerformanceMetrics(resourceTiming.performanceMetrics)}`);
      }
    } catch (error) {
      FTInnerLogger.w(TAG, `[RCP-Resource] Ignored invalid timing data for resourceId=${resourceId}: ${error}`);
    }

    try {
      FTInnerLogger.d(
        TAG,
        `[RCP-Resource] Completed ${method} ${url}, status=${resourceParams.resourceStatus}, duration=${responseTime}ms, contentType=${resourceParams.responseContentType}, contentLength=${resourceParams.responseContentLength}`
      );

      if (!HttpAutoTrackCompletionStore.getInstance().tryClaim(resourceId)) {
        FTInnerLogger.d(TAG, `[RCP-Resource] Duplicate completion ignored: ${resourceId}`);
        return response;
      }
      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      FTRUMInnerManager.getInstance().setNetState(resourceId, netStatusBean);
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResourceInternal(resourceId, fallbackActionId);
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[RCP-Resource] Failed to record completed response for resourceId=${resourceId}: ${error}`);
    }
    return response;
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
        const enumTraceType: TraceType = traceConfigManager.getTraceTypeEnum();
        const traceHeaderHandler = traceConfigManager.getTraceHeaderHandler();
        this.traceInterceptor = new DefaultFTTraceInterceptor(enumTraceType, traceHeaderHandler);
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

    const url = context.request.url.href;
    const method = context.request.method || 'GET';
    let finalTraceId: string | undefined = undefined;
    let finalSpanId: string | undefined = undefined;
    try {
      let uniqueId: string | undefined = undefined;
      if (context.request.headers && context.request.headers['X-FT-Resource-ID']) {
        const headerValue = context.request.headers['X-FT-Resource-ID'];
        if (typeof headerValue === 'string') {
          uniqueId = headerValue;
        }
      }

      if (!uniqueId) {
        uniqueId = createGeneratedResourceId();
        if (!context.request.headers) {
          context.request.headers = {};
        }
        context.request.headers['X-FT-Resource-ID'] = uniqueId;
      }

      const resourceId = `${method}_${url}_${uniqueId}`;
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

      let traceHeaders: Record<string, string> = {};
      let traceId: string | undefined = undefined;
      let spanId: string | undefined = undefined;
      let traceHeadersInjected = false;
      if (!hasKnownTraceHeaderMap(headersMap)) {
        const requestContextHeaders: Record<string, string> = {};
        const requestHeaderEntries = Array.from(headersMap.entries());
        for (let i = 0; i < requestHeaderEntries.length; i++) {
          const entry = requestHeaderEntries[i];
          requestContextHeaders[entry[0]] = entry[1];
        }
        const requestContext: FTTraceRequestContext = {
          url: url,
          method: method,
          headers: requestContextHeaders
        };
        traceHeaders = FTTraceManager.getInstance().getTraceHeader(resourceId, url, method, requestContext);
        const traceContext = FTTraceManager.getInstance().getTraceContext(resourceId);
        traceId = traceContext ? traceContext.traceId : undefined;
        spanId = traceContext ? traceContext.spanId : undefined;
        traceHeadersInjected = true;

        const traceHeaderKeys = Object.keys(traceHeaders);
        for (let i = 0; i < traceHeaderKeys.length; i++) {
          const key = traceHeaderKeys[i];
          headersMap.set(key, traceHeaders[key]);
        }
      }

      const requestData: HttpRequestData = {
        url: url,
        method: method,
        headers: headersMap,
        body: undefined,
        timestamp: Date.now(),
        traceId: traceId,
        spanId: spanId,
        traceHeadersInjected: traceHeadersInjected
      };

      const interceptedRequest = this.traceInterceptor.interceptRequest(requestData);

      if (!context.request.headers) {
        context.request.headers = {};
      }
      const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
      const finalHeaders: Record<string, string> = {};
      for (let i = 0; i < interceptedHeaders.length; i++) {
        const entry = interceptedHeaders[i];
        context.request.headers[entry[0]] = entry[1];
        finalHeaders[entry[0]] = entry[1];
      }
      const finalTraceContext: FTTraceContext = FTTraceHandler.createTraceContextFromHeaders(
        finalHeaders,
        interceptedRequest.traceId || '',
        interceptedRequest.spanId || ''
      );
      FTTraceManager.getInstance().putTraceContext(resourceId, finalTraceContext);
      finalTraceId = finalTraceContext.traceId || traceId;
      finalSpanId = finalTraceContext.spanId || spanId;

      FTInnerLogger.d(TAG, `[RCP-Trace] Added trace headers for ${method} ${url}, resourceId=${resourceId}, ${summarizeHeaderKeys(traceHeaders)}`);
    } catch (error) {
      FTInnerLogger.e(TAG, `[RCP-Trace] Failed to prepare trace request: ${error}`);
    }

    // A transport failure belongs to the caller. Never retry the request from
    // an instrumentation catch block (especially for non-idempotent requests).
    const response = await next.handle(context);
    try {
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
          body: undefined,
          timestamp: Date.now(),
          traceId: finalTraceId,
          spanId: finalSpanId
        };
        this.traceInterceptor.interceptResponse(responseData);
        FTInnerLogger.d(
          TAG,
          `[RCP-Trace] Processed trace response for ${method} ${url}, status=${response.statusCode || 0}, ${summarizeResponseHeaders(response.headers ?? {})}`
        );
      }

    } catch (error) {
      FTInnerLogger.e(TAG, `[RCP-Trace] Failed to process trace response: ${error}`);
    }
    return response;
  }
}

/**
 * Options for building a session configuration with FT interceptors.
 */
export interface FTRCPSessionConfigurationOptions extends FTAutoTrackOptions {
  baseAddress?: string;
  headers?: Record<string, string>;
  interceptors?: rcp.Interceptor[];
  requestConfiguration?: FTRCPRequestConfiguration;
  connectionConfiguration?: FTRCPConnectionConfiguration;
}

export interface FTAxiosRequestConfigTarget {
  url?: string;
  baseURL?: string;
  method?: string;
  headers?: Object;
  data?: Object | string | ArrayBuffer;
  context?: Object;
}

export interface FTAxiosResponseTarget<T = Object | string | ArrayBuffer> {
  config: FTAxiosRequestConfigTarget;
  status: number;
  headers?: Object;
  data?: T;
  /** Optional because streaming and non-NetworkKit Axios adapters omit it. */
  performanceTiming?: FTNetworkPerformanceTiming;
}

export interface FTAxiosErrorTarget {
  config?: FTAxiosRequestConfigTarget;
  response?: FTAxiosResponseTarget;
  message?: string;
  stack?: string;
}

export interface FTAxiosInterceptorManager<T> {
  use(
    onFulfilled?: (value: T) => T | Promise<T>,
    onRejected?: (error: Object) => Object | Promise<Object>
  ): number;
}

export interface FTAxiosInterceptors {
  request: FTAxiosInterceptorManager<FTAxiosRequestConfigTarget>;
  response: FTAxiosInterceptorManager<FTAxiosResponseTarget>;
}

export interface FTAxiosInterceptorTarget {
  interceptors: FTAxiosInterceptors;
}

export interface FTAxiosTrackRegistration {
  requestInterceptorId: number;
  responseInterceptorId: number;
}

interface FTAxiosAutoTrackState extends HttpAutoTrackState {
  traceEnabled: boolean;
  resourceEnabled: boolean;
  networkErrorHandler?: FTNetworkErrorHandler;
}

interface FTAxiosResponseSnapshot {
  status: number;
  headers: Record<string, string>;
  body?: string;
  performanceTiming?: FTNetworkPerformanceTiming;
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

interface FTRCPTimeoutConfiguration {
  connectMs?: number;
  transferMs?: number;
  inactivityMs?: number;
}

interface FTRCPTransferConfiguration {
  autoRedirect?: boolean;
  maxAutoRedirects?: number;
  timeout?: FTRCPTimeoutConfiguration;
}

interface FTRCPRequestConfiguration {
  transfer?: FTRCPTransferConfiguration;
  tracing?: FTRCPTracingConfiguration;
}

interface FTRCPConnectionConfiguration {
  readonly maxConnectionsPerHost?: number;
  readonly maxTotalConnections?: number;
}

interface FTAxiosHeadersSerializable {
  toJSON?: () => Object;
}

const FT_AXIOS_AUTOTRACK_CONTEXT_KEY = '__ftAxiosAutoTrackState';

function resolveAxiosFullUrl(config: FTAxiosRequestConfigTarget): string {
  const requestUrl = config.url || '';
  if (requestUrl.startsWith('http://') || requestUrl.startsWith('https://')) {
    return requestUrl;
  }

  const baseURL = config.baseURL || '';
  if (!baseURL) {
    return requestUrl;
  }

  if (!requestUrl) {
    return baseURL;
  }

  const baseEndsWithSlash = baseURL.endsWith('/');
  const requestStartsWithSlash = requestUrl.startsWith('/');
  if (baseEndsWithSlash && requestStartsWithSlash) {
    return `${baseURL}${requestUrl.slice(1)}`;
  }
  if (!baseEndsWithSlash && !requestStartsWithSlash) {
    return `${baseURL}/${requestUrl}`;
  }
  return `${baseURL}${requestUrl}`;
}

function normalizeAxiosHeaders(headers?: Object | null): Record<string, string> {
  if (!headers) {
    return {};
  }

  const toJSONCandidate = headers as FTAxiosHeadersSerializable;
  if (typeof toJSONCandidate.toJSON === 'function') {
    return normalizeObjectHeaders(toJSONCandidate.toJSON());
  }

  return normalizeObjectHeaders(headers);
}

function captureAxiosResponseSnapshot(
  response: FTAxiosResponseTarget | undefined,
  resourceId: string
): FTAxiosResponseSnapshot {
  const snapshot: FTAxiosResponseSnapshot = {
    status: 0,
    headers: {}
  };
  if (!response) {
    return snapshot;
  }

  try {
    snapshot.status = response.status || 0;
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Resource] Ignored invalid response status for resourceId=${resourceId}: ${error}`);
  }
  try {
    snapshot.headers = normalizeAxiosHeaders(response.headers);
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Resource] Ignored invalid response headers for resourceId=${resourceId}: ${error}`);
  }
  try {
    snapshot.body = tryGetOptionalResponseBodyText(response.data);
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Resource] Ignored invalid response body for resourceId=${resourceId}: ${error}`);
  }
  try {
    snapshot.performanceTiming = response.performanceTiming;
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Resource] Ignored invalid performance timing for resourceId=${resourceId}: ${error}`);
  }
  return snapshot;
}

function ensureAxiosContext(config: FTAxiosRequestConfigTarget): Record<string, Object> {
  const existingContext = config.context as Record<string, Object> | undefined;
  if (existingContext) {
    return existingContext;
  }

  const context: Record<string, Object> = {};
  config.context = context;
  return context;
}

function getAxiosAutoTrackState(config?: FTAxiosRequestConfigTarget): FTAxiosAutoTrackState | undefined {
  if (!config || !config.context) {
    return undefined;
  }
  const context = config.context as Record<string, Object>;
  const rawState = context[FT_AXIOS_AUTOTRACK_CONTEXT_KEY];
  return rawState as FTAxiosAutoTrackState | undefined;
}

function setAxiosAutoTrackState(config: FTAxiosRequestConfigTarget, state: FTAxiosAutoTrackState): void {
  const context = ensureAxiosContext(config);
  context[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] = state as Object;
}

function clearAxiosAutoTrackState(config?: FTAxiosRequestConfigTarget): void {
  if (!config || !config.context) {
    return;
  }
  const context = config.context as Record<string, Object>;
  const cleanContext: Record<string, Object> = {};
  const contextKeys = Object.keys(context);
  for (let i = 0; i < contextKeys.length; i++) {
    const key = contextKeys[i];
    if (key !== FT_AXIOS_AUTOTRACK_CONTEXT_KEY) {
      cleanContext[key] = context[key];
    }
  }
  config.context = cleanContext;
}

function createAxiosTraceInterceptor(): FTTraceInterceptor | null {
  const traceConfigManager = FTTraceConfigManager.getInstance();
  return new DefaultFTTraceInterceptor(
    traceConfigManager.getTraceTypeEnum(),
    traceConfigManager.getTraceHeaderHandler()
  );
}

function buildAxiosAutoTrackState(
  config: FTAxiosRequestConfigTarget,
  traceEnabled: boolean,
  resourceEnabled: boolean,
  networkErrorHandler?: FTNetworkErrorHandler
): FTAxiosAutoTrackState {
  const url = resolveAxiosFullUrl(config);
  const method = (config.method || 'GET').toUpperCase();
  const headers = normalizeAxiosHeaders(config.headers);
  const uniqueId = ensureHttpResourceId(headers);
  AxiosChainMethodStore.getInstance().put(uniqueId, method);
  const resourceId = buildAutoTrackResourceId(method, url, uniqueId);

  let finalHeaders = headers;
  if (traceEnabled) {
    let traceId: string | undefined = undefined;
    let spanId: string | undefined = undefined;
    let traceHeadersInjected = false;
    const headersMap = new Map<string, string>();

    const headerKeys = Object.keys(headers);
    for (let i = 0; i < headerKeys.length; i++) {
      const key = headerKeys[i];
      headersMap.set(key, headers[key]);
    }

    if (!hasKnownTraceHeaders(headers)) {
      const requestContext: FTTraceRequestContext = {
        url: url,
        method: method,
        headers: headers,
        body: config.data
      };
      const traceHeaders = FTTraceManager.getInstance().getTraceHeader(resourceId, url, method, requestContext);
      const traceContext = FTTraceManager.getInstance().getTraceContext(resourceId);
      traceId = traceContext ? traceContext.traceId : undefined;
      spanId = traceContext ? traceContext.spanId : undefined;
      traceHeadersInjected = true;

      const traceHeaderKeys = Object.keys(traceHeaders);
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        headersMap.set(key, traceHeaders[key]);
      }
    }

    const traceInterceptor = createAxiosTraceInterceptor();
    if (traceInterceptor) {
      const interceptedRequest = traceInterceptor.interceptRequest({
        url: url,
        method: method,
        headers: headersMap,
        body: config.data,
        timestamp: Date.now(),
        traceId: traceId,
        spanId: spanId,
        traceHeadersInjected: traceHeadersInjected
      });

      finalHeaders = {};
      const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
      for (let i = 0; i < interceptedHeaders.length; i++) {
        const entry = interceptedHeaders[i];
        finalHeaders[entry[0]] = entry[1];
      }
      const finalTraceContext: FTTraceContext = FTTraceHandler.createTraceContextFromHeaders(
        finalHeaders,
        interceptedRequest.traceId || '',
        interceptedRequest.spanId || ''
      );
      FTTraceManager.getInstance().putTraceContext(resourceId, finalTraceContext);
    }
  }

  finalHeaders['X-FT-Resource-ID'] = uniqueId;

  return {
    resourceId: resourceId,
    url: url,
    method: method,
    startTime: Date.now(),
    requestHeaders: finalHeaders,
    traceEnabled: traceEnabled,
    resourceEnabled: resourceEnabled,
    networkErrorHandler: networkErrorHandler
  };
}

function completeAxiosTrace(state: FTAxiosAutoTrackState, status: number, headers: Record<string, string>, body?: string): void {
  if (!state.traceEnabled) {
    return;
  }

  const traceInterceptor = createAxiosTraceInterceptor();
  if (!traceInterceptor) {
    return;
  }

  const responseHeaderMap = new Map<string, string>();
  const responseHeaderKeys = Object.keys(headers);
  for (let i = 0; i < responseHeaderKeys.length; i++) {
    const key = responseHeaderKeys[i];
    responseHeaderMap.set(key, headers[key]);
  }

  const traceContext = FTTraceManager.getInstance().getTraceContext(state.resourceId);
  const traceId = traceContext ? traceContext.traceId : undefined;
  const spanId = traceContext ? traceContext.spanId : undefined;

  traceInterceptor.interceptResponse({
    url: state.url,
    statusCode: status,
    headers: responseHeaderMap,
    body: body,
    timestamp: Date.now(),
    traceId: traceId,
    spanId: spanId,
    duration: Date.now() - state.startTime
  });
}

function completeAxiosResource(
  state: FTAxiosAutoTrackState,
  status: number,
  headers: Record<string, string>,
  _responseBody?: string,
  errorMessage?: string,
  errorStack?: string,
  performanceTiming?: FTNetworkPerformanceTiming,
  networkErrorHandling?: FTNetworkErrorHandlingResult,
  networkErrorContext?: FTNetworkErrorContext
): void {
  if (!state.resourceEnabled) {
    return;
  }

  const resourceParams = new ResourceParams();
  resourceParams.setUrl(state.url);
  resourceParams.setResourceMethod(state.method);
  resourceParams.setRequestHeaderMap(buildRequestHeaderMap(state.requestHeaders));
  resourceParams.setRequestHeader(JSON.stringify(state.requestHeaders));
  resourceParams.setResourceStatus(status);
  resourceParams.setResponseHeaderMap(buildResponseHeaderMap(headers));
  resourceParams.setResponseHeader(JSON.stringify(headers));

  const contentType = headers['content-type'] || headers['Content-Type'];
  const contentEncoding = headers['content-encoding'] || headers['Content-Encoding'];
  const connection = headers['connection'] || headers['Connection'];
  if (contentType) {
    resourceParams.setResponseContentType(contentType);
  }
  if (contentEncoding) {
    resourceParams.setResponseContentEncoding(contentEncoding);
  }
  if (connection) {
    resourceParams.setResponseConnection(connection);
  }

  const contentLength = extractContentLength(headers);
  if (contentLength > 0) {
    resourceParams.setResponseContentLength(contentLength);
  }

  const fallbackLoadNs = Math.max(Date.now() - state.startTime, 1) * MS_TO_NS;
  const resourceTiming = createFTResourceTimingFromNetworkPerformance(performanceTiming, fallbackLoadNs);
  const metricValue: PerformanceMetricValue = { value: resourceTiming.loadTime };
  resourceParams.addProperty('resourceLoad', metricValue);

  if (errorMessage) {
    resourceParams.setRequestErrorMsg(errorMessage);
  }
  if (errorStack) {
    resourceParams.setRequestErrorStack(errorStack);
  }
  addNetworkErrorFields(resourceParams, networkErrorHandling, networkErrorContext);

  const netStatusBean = createFTNetStatusBean(resourceTiming);
  FTInnerLogger.d(TAG,
    `[Axios-Resource] Completed resourceId=${state.resourceId}, status=${status}, failed=${errorMessage ? 'true' : 'false'}, ${summarizePerformanceMetrics(resourceTiming.performanceMetrics)}`);
  FTRUMInnerManager.getInstance().setTransformContent(state.resourceId, resourceParams);
  FTRUMInnerManager.getInstance().setNetState(state.resourceId, netStatusBean);
  FTRUMInnerManager.getInstance().stopResourceInternal(state.resourceId, state.actionId);
}

function completeAxiosTraceSafely(
  state: FTAxiosAutoTrackState,
  snapshot: FTAxiosResponseSnapshot
): void {
  try {
    completeAxiosTrace(state, snapshot.status, snapshot.headers, snapshot.body);
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Trace] Failed to record response for resourceId=${state.resourceId}: ${error}`);
  }
}

function completeAxiosResourceSafely(
  state: FTAxiosAutoTrackState,
  snapshot: FTAxiosResponseSnapshot,
  errorMessage?: string,
  errorStack?: string,
  networkErrorHandling?: FTNetworkErrorHandlingResult,
  networkErrorContext?: FTNetworkErrorContext
): void {
  try {
    completeAxiosResource(
      state,
      snapshot.status,
      snapshot.headers,
      snapshot.body,
      errorMessage,
      errorStack,
      snapshot.performanceTiming,
      networkErrorHandling,
      networkErrorContext
    );
  } catch (error) {
    FTInnerLogger.w(TAG, `[Axios-Resource] Failed to record response for resourceId=${state.resourceId}: ${error}`);
  }
}

export function createFTRCPInterceptors(
  enableTraceInterceptor?: boolean,
  enableResourceInterceptor?: boolean,
  networkErrorHandler?: FTNetworkErrorHandler | null
): rcp.Interceptor[] {
  const traceEnabled = enableTraceInterceptor !== undefined
    ? enableTraceInterceptor
    : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
  const resourceEnabled = enableResourceInterceptor !== undefined
    ? enableResourceInterceptor
    : FTRUMConfigManager.getInstance().isResourceTraceEnable();
  const resolvedNetworkErrorHandler = resolveNetworkErrorHandler(networkErrorHandler);

  const interceptors: rcp.Interceptor[] = [];
  if (traceEnabled) {
    interceptors.push(new RCPTraceInterceptor());
  }
  if (resourceEnabled) {
    interceptors.push(new RCPResourceInterceptor(resolvedNetworkErrorHandler));
  }
  return interceptors;
}

/**
 * Attach FT auto-track to an Axios-like client by using request/response interceptors.
 * This path is intended for @ohos/axios versions that do not expose NetworkKit's
 * `interceptorChain` entry point.
 */
export function applyFTAxiosTrack(
  axiosTarget: Object,
  options: FTAutoTrackOptions = {}
): FTAxiosTrackRegistration {
  const target = axiosTarget as FTAxiosInterceptorTarget;
  const traceEnabled = options.enableTraceInterceptor !== undefined
    ? options.enableTraceInterceptor
    : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
  const resourceEnabled = options.enableResourceInterceptor !== undefined
    ? options.enableResourceInterceptor
    : FTRUMConfigManager.getInstance().isResourceTraceEnable();
  const networkErrorHandler = resolveNetworkErrorHandler(options.networkErrorHandler);

  const requestInterceptorId = target.interceptors.request.use((config: FTAxiosRequestConfigTarget) => {
    const state = buildAxiosAutoTrackState(config, traceEnabled, resourceEnabled, networkErrorHandler);
    config.headers = state.requestHeaders as Object;

    if (state.resourceEnabled && FTRUMConfigManager.getInstance().shouldFilterResourceUrl(state.url)) {
      state.resourceEnabled = false;
      FTInnerLogger.d(TAG, `[Axios-Resource] Filtered ${state.method} ${state.url}`);
    }

    if (state.resourceEnabled) {
      FTRUMInnerManager.getInstance().startResource(state.resourceId);
      const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
      if (activeAction && !activeAction.isActionClose()) {
        state.actionId = activeAction.getId();
      }
    }

    setAxiosAutoTrackState(config, state);
    FTInnerLogger.d(
      TAG,
      `[Axios-Request] Prepared ${state.method} ${state.url}, resourceId=${state.resourceId}, trace=${traceEnabled}, resource=${state.resourceEnabled}, ${summarizeHeaderKeys(state.requestHeaders)}`
    );
    return config;
  });

  const responseInterceptorId = target.interceptors.response.use(
    (response: FTAxiosResponseTarget) => {
      const state = getAxiosAutoTrackState(response.config);
      if (!state) {
        return response;
      }

      try {
        const snapshot = captureAxiosResponseSnapshot(response, state.resourceId);
        completeAxiosTraceSafely(state, snapshot);
        if (state.resourceEnabled && HttpAutoTrackCompletionStore.getInstance().tryClaim(state.resourceId)) {
          completeAxiosResourceSafely(state, snapshot);
        }
        FTInnerLogger.d(
          TAG,
          `[Axios-Response] Completed ${state.method} ${state.url}, resourceId=${state.resourceId}, status=${snapshot.status}, duration=${Date.now() - state.startTime}ms`
        );
      } catch (error) {
        FTInnerLogger.w(TAG, `[Axios-Response] Failed to record completed response for resourceId=${state.resourceId}: ${error}`);
      } finally {
        clearAxiosAutoTrackState(response.config);
      }
      return response;
    },
    (rawError: Object) => {
      const error = rawError as FTAxiosErrorTarget;
      const responseConfig = error.config || (error.response ? error.response.config : undefined);
      const state = getAxiosAutoTrackState(responseConfig);
      if (state) {
        try {
          const snapshot = captureAxiosResponseSnapshot(error.response, state.resourceId);
          completeAxiosTraceSafely(state, snapshot);
          const resourceCompletionClaimed = state.resourceEnabled &&
            HttpAutoTrackCompletionStore.getInstance().tryClaim(state.resourceId);
          // @ohos/axios may put the HttpRequest itself in `error.response`
          // for a local failure. Only a positive status represents an actual
          // HTTP response (normally 4xx/5xx).
          const hasHttpResponse = snapshot.status > 0;
          const errorContext = !resourceCompletionClaimed || hasHttpResponse ? undefined : createFTNetworkErrorContext(
              state.url,
              state.method,
              FTNetworkErrorSource.AXIOS,
              rawError,
              error.message || snapshot.body || 'Unknown error',
              error.stack
            );
          const handling = errorContext ? handleFTNetworkError(state.networkErrorHandler, errorContext) : undefined;
          if (resourceCompletionClaimed) {
            completeAxiosResourceSafely(
              state,
              snapshot,
              error.message || snapshot.body || 'Unknown error',
              error.stack,
              handling,
              errorContext
            );
          }

          FTInnerLogger.e(
            TAG,
            `[Axios-Response] Request failed ${state.method} ${state.url}, resourceId=${state.resourceId}, status=${snapshot.status}, error=${error.message || 'Unknown error'}`
          );
        } catch (trackingError) {
          FTInnerLogger.w(TAG, `[Axios-Response] Failed to record rejected response for resourceId=${state.resourceId}: ${trackingError}`);
        } finally {
          clearAxiosAutoTrackState(responseConfig);
        }
      }

      // Preserve the business error object. The fallback is required by
      // ArkTS, which rejects throws of arbitrary values.
      if (rawError instanceof Error) {
        throw rawError;
      }
      throw new Error(String(rawError));
    }
  );

  return {
    requestInterceptorId: requestInterceptorId,
    responseInterceptorId: responseInterceptorId
  };
}

/**
 * Create a default RCP session configuration that includes FT interceptors.
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
    options.enableResourceInterceptor,
    options.networkErrorHandler
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
      transfer: options.requestConfiguration.transfer,
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
    requestConfiguration: requestConfiguration,
    connectionConfiguration: options.connectionConfiguration
  };
}
