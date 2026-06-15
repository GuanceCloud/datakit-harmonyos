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
  AxiosChainMethodStore,
  buildAutoTrackResourceId,
  buildRequestHeaderMap,
  buildResponseHeaderMap,
  ensureHttpResourceId,
  extractContentLength,
  FTAutoTrackOptions,
  HttpAutoTrackState,
  normalizeObjectHeaders,
  PerformanceMetricValue,
  resolveAxiosChainMethod,
  summarizeHeaderKeys,
  summarizePerformanceMetrics,
  summarizeResponseHeaders,
  tryGetOptionalResponseBodyText
} from './FTHttpAutoTrackShared';

const TAG = "FTHttpAutoTrack";

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
 * RCP Resource Interceptor
 * Automatically intercepts HTTP requests and collects resource data
 */
export class RCPResourceInterceptor implements rcp.Interceptor {
  private isEnabled: boolean = true;
  private resourceActionMap: Map<string, string> = new Map();

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

    try {
      const response = await next.handle(context);
      const responseTime = Date.now() - startTime;

      const resourceParams = new ResourceParams();
      resourceParams.setUrl(url);
      resourceParams.setResourceMethod(method);
      resourceParams.setRequestHeaderMap(buildRequestHeaderMap(savedRequestHeaders));
      resourceParams.setRequestHeader(JSON.stringify(savedRequestHeaders));
      resourceParams.setResourceStatus(response.statusCode || 0);

      if (response.headers) {
        const responseHeaders = normalizeObjectHeaders(response.headers as Object);
        resourceParams.setResponseHeaderMap(buildResponseHeaderMap(responseHeaders));
        resourceParams.setResponseHeader(JSON.stringify(response.headers));

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

      if (response.timeInfo) {
        const timeInfoObj = response.timeInfo as object as TimeInfoStructure;
        const performanceMetrics: Map<string, number> = new Map();
        const MS_TO_NS = 1000000;

        if (timeInfoObj.nameLookupTimeMs !== undefined && typeof timeInfoObj.nameLookupTimeMs === 'number') {
          performanceMetrics.set('resourceDNS', timeInfoObj.nameLookupTimeMs * MS_TO_NS);
        } else if (timeInfoObj.dnsTime !== undefined && typeof timeInfoObj.dnsTime === 'number') {
          performanceMetrics.set('resourceDNS', timeInfoObj.dnsTime);
        } else if (timeInfoObj.dnsEndTime !== undefined && timeInfoObj.dnsStartTime !== undefined) {
          const dnsStart = typeof timeInfoObj.dnsStartTime === 'number' ? timeInfoObj.dnsStartTime : 0;
          const dnsEnd = typeof timeInfoObj.dnsEndTime === 'number' ? timeInfoObj.dnsEndTime : 0;
          if (dnsEnd > dnsStart) {
            performanceMetrics.set('resourceDNS', dnsEnd - dnsStart);
          }
        }

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
          performanceMetrics.set('resourceTCP', timeInfoObj.tcpTime);
        } else if (timeInfoObj.tcpEndTime !== undefined && timeInfoObj.tcpStartTime !== undefined) {
          const tcpStart = typeof timeInfoObj.tcpStartTime === 'number' ? timeInfoObj.tcpStartTime : 0;
          const tcpEnd = typeof timeInfoObj.tcpEndTime === 'number' ? timeInfoObj.tcpEndTime : 0;
          if (tcpEnd > tcpStart) {
            performanceMetrics.set('resourceTCP', tcpEnd - tcpStart);
          }
        }

        if (timeInfoObj.tlsHandshakeTimeMs !== undefined && typeof timeInfoObj.tlsHandshakeTimeMs === 'number') {
          const tlsHandshakeTime = timeInfoObj.tlsHandshakeTimeMs * MS_TO_NS;
          const connectTime = timeInfoObj.connectTimeMs !== undefined && typeof timeInfoObj.connectTimeMs === 'number'
            ? timeInfoObj.connectTimeMs * MS_TO_NS
            : 0;
          const sslTime = tlsHandshakeTime > connectTime ? tlsHandshakeTime - connectTime : tlsHandshakeTime;
          if (sslTime > 0) {
            performanceMetrics.set('resourceSSL', sslTime);
          }
        } else if (timeInfoObj.sslTime !== undefined && typeof timeInfoObj.sslTime === 'number') {
          performanceMetrics.set('resourceSSL', timeInfoObj.sslTime);
        } else if (timeInfoObj.sslEndTime !== undefined && timeInfoObj.sslStartTime !== undefined) {
          const sslStart = typeof timeInfoObj.sslStartTime === 'number' ? timeInfoObj.sslStartTime : 0;
          const sslEnd = typeof timeInfoObj.sslEndTime === 'number' ? timeInfoObj.sslEndTime : 0;
          if (sslEnd > sslStart) {
            performanceMetrics.set('resourceSSL', sslEnd - sslStart);
          }
        }

        let ttfbValue: number | undefined = undefined;
        if (timeInfoObj.startTransferTimeMs !== undefined && timeInfoObj.preTransferTimeMs !== undefined) {
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const preTransfer = (typeof timeInfoObj.preTransferTimeMs === 'number' ? timeInfoObj.preTransferTimeMs : 0) * MS_TO_NS;
          ttfbValue = startTransfer > preTransfer ? startTransfer - preTransfer : startTransfer;
        } else if (timeInfoObj.startTransferTimeMs !== undefined && timeInfoObj.tlsHandshakeTimeMs !== undefined) {
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          const tlsHandshake = (typeof timeInfoObj.tlsHandshakeTimeMs === 'number' ? timeInfoObj.tlsHandshakeTimeMs : 0) * MS_TO_NS;
          ttfbValue = startTransfer > tlsHandshake ? startTransfer - tlsHandshake : startTransfer;
        } else if (timeInfoObj.ttfbTime !== undefined && typeof timeInfoObj.ttfbTime === 'number') {
          ttfbValue = timeInfoObj.ttfbTime;
        } else if (timeInfoObj.firstByteTime !== undefined && typeof timeInfoObj.firstByteTime === 'number') {
          ttfbValue = timeInfoObj.firstByteTime;
        }

        if (ttfbValue !== undefined && ttfbValue > 0) {
          performanceMetrics.set('resourceTTFB', ttfbValue);
          performanceMetrics.set('resourceFirstByte', ttfbValue);
        }

        if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.tlsHandshakeTimeMs !== undefined) {
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const tlsHandshake = (typeof timeInfoObj.tlsHandshakeTimeMs === 'number' ? timeInfoObj.tlsHandshakeTimeMs : 0) * MS_TO_NS;
          if (totalTime > tlsHandshake) {
            performanceMetrics.set('resourceTrans', totalTime - tlsHandshake);
          }
        } else if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.startTransferTimeMs !== undefined) {
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          if (totalTime > startTransfer) {
            performanceMetrics.set('resourceTrans', totalTime - startTransfer + (ttfbValue !== undefined ? ttfbValue : 0));
          }
        } else if (timeInfoObj.transTime !== undefined && typeof timeInfoObj.transTime === 'number') {
          performanceMetrics.set('resourceTrans', timeInfoObj.transTime);
        } else if (timeInfoObj.responseTime !== undefined && typeof timeInfoObj.responseTime === 'number') {
          performanceMetrics.set('resourceTrans', timeInfoObj.responseTime);
        }

        if (timeInfoObj.totalTimeMs !== undefined && timeInfoObj.startTransferTimeMs !== undefined) {
          const totalTime = (typeof timeInfoObj.totalTimeMs === 'number' ? timeInfoObj.totalTimeMs : 0) * MS_TO_NS;
          const startTransfer = (typeof timeInfoObj.startTransferTimeMs === 'number' ? timeInfoObj.startTransferTimeMs : 0) * MS_TO_NS;
          if (totalTime > startTransfer) {
            performanceMetrics.set('resourceDownloadTime', totalTime - startTransfer);
          }
        } else if (timeInfoObj.downloadTime !== undefined && typeof timeInfoObj.downloadTime === 'number') {
          performanceMetrics.set('resourceDownloadTime', timeInfoObj.downloadTime);
        } else if (timeInfoObj.bodyEndTime !== undefined && timeInfoObj.bodyStartTime !== undefined) {
          const bodyStart = typeof timeInfoObj.bodyStartTime === 'number' ? timeInfoObj.bodyStartTime : 0;
          const bodyEnd = typeof timeInfoObj.bodyEndTime === 'number' ? timeInfoObj.bodyEndTime : 0;
          if (bodyEnd > bodyStart) {
            performanceMetrics.set('resourceDownloadTime', bodyEnd - bodyStart);
          }
        }

        if (timeInfoObj.totalTimeMs !== undefined && typeof timeInfoObj.totalTimeMs === 'number') {
          performanceMetrics.set('resourceLoad', timeInfoObj.totalTimeMs * MS_TO_NS);
        } else if (timeInfoObj.totalTime !== undefined && typeof timeInfoObj.totalTime === 'number') {
          performanceMetrics.set('resourceLoad', timeInfoObj.totalTime);
        } else {
          performanceMetrics.set('resourceLoad', responseTime * MS_TO_NS);
        }

        const perfKeys = Array.from(performanceMetrics.keys());
        for (let i = 0; i < perfKeys.length; i++) {
          const key = perfKeys[i];
          const value = performanceMetrics.get(key);
          if (value !== undefined) {
            const metricValue: PerformanceMetricValue = { value: value };
            resourceParams.addProperty(key, metricValue);
          }
        }
        FTInnerLogger.d(TAG, `[RCP-Resource] Performance metrics extracted for resourceId=${resourceId}: ${summarizePerformanceMetrics(performanceMetrics)}`);
      } else {
        const metricValue: PerformanceMetricValue = { value: responseTime * 1000000 };
        resourceParams.addProperty('resourceLoad', metricValue);
      }

      FTInnerLogger.d(
        TAG,
        `[RCP-Resource] Completed ${method} ${url}, status=${resourceParams.resourceStatus}, duration=${responseTime}ms, contentType=${resourceParams.responseContentType}, contentLength=${resourceParams.responseContentLength}`
      );

      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }

      return response;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      const responseTime = Date.now() - startTime;
      const resourceParams = new ResourceParams();
      resourceParams.setUrl(url);
      resourceParams.setResourceMethod(method);
      resourceParams.setRequestHeaderMap(buildRequestHeaderMap(savedRequestHeaders));
      resourceParams.setRequestHeader(JSON.stringify(savedRequestHeaders));
      resourceParams.setRequestErrorMsg(error.message || 'Unknown error');
      resourceParams.setRequestErrorStack((error.stack && error.stack.length > 0) ? error.stack : String(error));
      resourceParams.setResourceStatus(0);
      const metricValue: PerformanceMetricValue = { value: Math.max(responseTime, 1) * 1000000 };
      resourceParams.addProperty('resourceLoad', metricValue);

      FTInnerLogger.e(
        TAG,
        `[RCP-Resource] Request failed ${method} ${url}, duration=${responseTime}ms, error=${error.message}, stack=${error.stack || 'N/A'}`
      );

      FTRUMInnerManager.getInstance().setTransformContent(resourceId, resourceParams);
      const fallbackActionId = this.resourceActionMap.get(resourceId);
      FTRUMInnerManager.getInstance().stopResource(resourceId, fallbackActionId);
      if (fallbackActionId) {
        this.resourceActionMap.delete(resourceId);
      }
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

    try {
      const url = context.request.url.href;
      const method = context.request.method || 'GET';

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
      let finalTraceId: string | undefined = undefined;
      let finalSpanId: string | undefined = undefined;
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

      const response = await next.handle(context);
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

      return response;
    } catch (error) {
      FTInnerLogger.e(TAG, `[RCP-Trace] Error in trace interceptor: ${error}`);
      return await next.handle(context);
    }
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
  resourceEnabled: boolean
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
    resourceEnabled: resourceEnabled
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
  errorStack?: string
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

  const metricValue: PerformanceMetricValue = { value: (Date.now() - state.startTime) * 1000000 };
  resourceParams.addProperty('resourceLoad', metricValue);

  if (errorMessage) {
    resourceParams.setRequestErrorMsg(errorMessage);
  }
  if (errorStack) {
    resourceParams.setRequestErrorStack(errorStack);
  }

  FTRUMInnerManager.getInstance().setTransformContent(state.resourceId, resourceParams);
  FTRUMInnerManager.getInstance().stopResource(state.resourceId, state.actionId);
}

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

  const requestInterceptorId = target.interceptors.request.use((config: FTAxiosRequestConfigTarget) => {
    const state = buildAxiosAutoTrackState(config, traceEnabled, resourceEnabled);
    config.headers = state.requestHeaders as Object;

    if (resourceEnabled) {
      FTRUMInnerManager.getInstance().startResource(state.resourceId);
      const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
      if (activeAction && !activeAction.isActionClose()) {
        state.actionId = activeAction.getId();
      }
    }

    setAxiosAutoTrackState(config, state);
    FTInnerLogger.d(
      TAG,
      `[Axios-Request] Prepared ${state.method} ${state.url}, resourceId=${state.resourceId}, trace=${traceEnabled}, resource=${resourceEnabled}, ${summarizeHeaderKeys(state.requestHeaders)}`
    );
    return config;
  });

  const responseInterceptorId = target.interceptors.response.use(
    (response: FTAxiosResponseTarget) => {
      const state = getAxiosAutoTrackState(response.config);
      if (!state) {
        return response;
      }

      const responseHeaders = normalizeAxiosHeaders(response.headers);
      const responseBodyText = tryGetOptionalResponseBodyText(response.data);

      completeAxiosTrace(state, response.status || 0, responseHeaders, responseBodyText);
      completeAxiosResource(state, response.status || 0, responseHeaders, undefined);

      FTInnerLogger.d(
        TAG,
        `[Axios-Response] Completed ${state.method} ${state.url}, resourceId=${state.resourceId}, status=${response.status || 0}, duration=${Date.now() - state.startTime}ms`
      );
      clearAxiosAutoTrackState(response.config);
      return response;
    },
    (rawError: Object) => {
      const error = rawError as FTAxiosErrorTarget;
      const responseConfig = error.config || (error.response ? error.response.config : undefined);
      const state = getAxiosAutoTrackState(responseConfig);
      if (state) {
        const responseHeaders = normalizeAxiosHeaders(error.response ? error.response.headers : undefined);
        const responseBodyText = error.response ? tryGetOptionalResponseBodyText(error.response.data) : undefined;
        const status = error.response ? error.response.status || 0 : 0;

        completeAxiosTrace(state, status, responseHeaders, responseBodyText);
        completeAxiosResource(
          state,
          status,
          responseHeaders,
          responseBodyText,
          error.message || responseBodyText || 'Unknown error',
          error.stack
        );

        FTInnerLogger.e(
          TAG,
          `[Axios-Response] Request failed ${state.method} ${state.url}, resourceId=${state.resourceId}, status=${status}, error=${error.message || 'Unknown error'}`
        );
        clearAxiosAutoTrackState(responseConfig);
      }

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
