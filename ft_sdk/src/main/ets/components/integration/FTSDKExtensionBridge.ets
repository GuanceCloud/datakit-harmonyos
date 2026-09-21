import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { ResourceParams } from '../rum/bean/ResourceParams';
import { FTTraceConfigManager } from '../trace/FTTraceConfigManager';
import { DefaultFTTraceInterceptor, FTTraceInterceptor } from '../trace/FTTraceInterceptor';
import { FTTraceContext, FTTraceRequestContext } from '../trace/FTTraceHeaderHandler';
import { FTTraceHandler } from '../trace/FTTraceHandler';
import { FTTraceManager } from '../trace/FTTraceManager';
import {
  createFTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkErrorHandlingResult,
  FTNetworkErrorRaw,
  FTNetworkErrorSource,
  handleFTNetworkError
} from '../network/FTNetworkErrorHandler';
import {
  AxiosChainMethodStore,
  buildAutoTrackResourceId,
  buildRequestHeaderMap,
  buildResponseHeaderMap,
  createFTNetStatusBean,
  createFTResourceTimingFromNetworkPerformance,
  ensureHttpResourceId,
  extractContentLength,
  FTNetworkPerformanceTiming,
  HttpAutoTrackState,
  HttpAutoTrackStateStore,
  normalizeObjectHeaders,
  PerformanceMetricValue,
  resolveAxiosChainMethod,
  summarizeHeaderKeys,
  tryGetOptionalResponseBodyText
} from '../network/FTHttpAutoTrackShared';

const TAG = 'FTSDKExtensionBridge';
const FT_RESOURCE_ID_HEADER = 'X-FT-Resource-ID';
const HTTP_METHOD_UNKNOWN = 'UNKNOWN';

export const FT_SDK_EXTENSION_CONTRACT_VERSION = 1;

export interface FTSDKExtensionAutoTrackOptions {
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;
  networkErrorHandler?: FTNetworkErrorHandler;
}

export interface FTSDKExtensionResolvedAutoTrackOptions {
  enableTraceInterceptor: boolean;
  enableResourceInterceptor: boolean;
  networkErrorHandler?: FTNetworkErrorHandler;
}

export interface FTSDKExtensionRequestInput {
  url: string;
  method?: string;
  headers?: Object | null;
  body?: string | Object | ArrayBuffer;
}

export interface FTSDKExtensionPreparedRequest {
  url: string;
  method: string;
  resourceId: string;
  uniqueId: string;
  headers: Record<string, string>;
  traceEnabled: boolean;
  resourceEnabled: boolean;
}

export interface FTSDKExtensionResponseInput {
  url: string;
  method?: string;
  uniqueId?: string;
  requestHeaders?: Object | null;
  responseHeaders?: Object | null;
  statusCode: number;
  body?: string | Object | ArrayBuffer;
  /** NetworkKit/axios cumulative wire timing; absent on unsupported adapters. */
  performanceTiming?: FTNetworkPerformanceTiming;
  errorMessage?: string;
  errorStack?: string;
  /** Native transport failure when NetworkKit or an adapter exposes it. */
  transportError?: FTNetworkErrorRaw;
  /** Raw platform status/error code when no exception object is available. */
  errorCode?: string | number;
}

interface FTSDKExtensionHttpState extends HttpAutoTrackState {
  traceEnabled: boolean;
  resourceEnabled: boolean;
  networkErrorHandler?: FTNetworkErrorHandler;
}

export class FTSDKExtensionBridge {
  public static resolveAutoTrackOptions(
    options: FTSDKExtensionAutoTrackOptions = {}
  ): FTSDKExtensionResolvedAutoTrackOptions {
    const traceEnabled = options.enableTraceInterceptor !== undefined
      ? options.enableTraceInterceptor
      : FTTraceConfigManager.getInstance().isAutoTraceEnabled();
    const resourceEnabled = options.enableResourceInterceptor !== undefined
      ? options.enableResourceInterceptor
      : FTRUMConfigManager.getInstance().isResourceTraceEnable();

    return {
      enableTraceInterceptor: traceEnabled,
      enableResourceInterceptor: resourceEnabled,
      networkErrorHandler: options.networkErrorHandler
    };
  }

  public static normalizeHeaders(headers?: Object | null): Record<string, string> {
    return normalizeObjectHeaders(headers);
  }

  public static prepareHttpRequest(
    request: FTSDKExtensionRequestInput,
    options: FTSDKExtensionAutoTrackOptions = {}
  ): FTSDKExtensionPreparedRequest {
    const resolvedOptions = FTSDKExtensionBridge.resolveAutoTrackOptions(options);
    const headers = FTSDKExtensionBridge.normalizeHeaders(request.headers);
    const uniqueId = ensureHttpResourceId(headers);
    const method = FTSDKExtensionBridge.resolveMethod(request.method, headers);
    const resourceId = buildAutoTrackResourceId(method, request.url, uniqueId);
    AxiosChainMethodStore.getInstance().put(uniqueId, method);

    let finalHeaders = headers;
    const resourceFiltered = resolvedOptions.enableResourceInterceptor &&
      FTRUMConfigManager.getInstance().shouldFilterResourceUrl(request.url);
    const resourceEnabled = resolvedOptions.enableResourceInterceptor && !resourceFiltered;
    if (resourceFiltered) {
      FTInnerLogger.d(TAG, `[HTTP-Resource] Filtered ${method} ${request.url}`);
    }
    try {
      if (resolvedOptions.enableTraceInterceptor) {
        finalHeaders = FTSDKExtensionBridge.applyTraceHeaders(resourceId, request, method, headers, uniqueId);
      }

      let actionId: string | undefined = undefined;
      if (resourceEnabled) {
        FTRUMInnerManager.getInstance().startResource(resourceId);
        const activeAction = FTRUMInnerManager.getInstance().getActiveAction();
        if (activeAction && !activeAction.isActionClose()) {
          actionId = activeAction.getId();
        }
      }

      const state: FTSDKExtensionHttpState = {
        resourceId: resourceId,
        url: request.url,
        method: method,
        startTime: Date.now(),
        requestHeaders: finalHeaders,
        actionId: actionId,
        traceEnabled: resolvedOptions.enableTraceInterceptor,
        resourceEnabled: resourceEnabled,
        networkErrorHandler: resolvedOptions.networkErrorHandler
      };
      HttpAutoTrackStateStore.getInstance().put(state);

      FTInnerLogger.d(
        TAG,
        `[HTTP-Initial] Prepared ${request.url}, resourceId=${resourceId}, trace=${resolvedOptions.enableTraceInterceptor}, resource=${resourceEnabled}, ${summarizeHeaderKeys(finalHeaders)}`
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Initial] Failed to prepare request: ${error}`);
    }

    return {
      url: request.url,
      method: method,
      resourceId: resourceId,
      uniqueId: uniqueId,
      headers: finalHeaders,
      traceEnabled: resolvedOptions.enableTraceInterceptor,
      resourceEnabled: resourceEnabled
    };
  }

  public static completeHttpResponse(response: FTSDKExtensionResponseInput): boolean {
    const requestHeaders = FTSDKExtensionBridge.normalizeHeaders(response.requestHeaders);
    const uniqueId = FTSDKExtensionBridge.resolveUniqueId(response.uniqueId, requestHeaders);
    if (!uniqueId) {
      FTInnerLogger.w(TAG, `[HTTP-Final] Missing resource id for ${response.url}`);
      return false;
    }

    const method = FTSDKExtensionBridge.resolveMethod(response.method, requestHeaders);
    const fallbackResourceId = buildAutoTrackResourceId(method, response.url, uniqueId);
    const state = HttpAutoTrackStateStore.getInstance().get(fallbackResourceId) as FTSDKExtensionHttpState | undefined;
    if (!state) {
      FTInnerLogger.w(TAG, `[HTTP-Final] Missing initial interceptor state for ${response.url}, uniqueId=${uniqueId}`);
      FTSDKExtensionBridge.clearAxiosMethod(uniqueId);
      return false;
    }

    const resourceId = state.resourceId;
    try {
      const responseHeaders = FTSDKExtensionBridge.normalizeHeaders(response.responseHeaders);
      const responseBodyText = tryGetOptionalResponseBodyText(response.body);

      if (state.traceEnabled) {
        FTSDKExtensionBridge.completeTrace(state, response.statusCode, responseHeaders, responseBodyText);
      }

      if (state.resourceEnabled) {
        FTSDKExtensionBridge.completeResource(state, response, responseHeaders, responseBodyText);
        FTInnerLogger.d(
          TAG,
          `[HTTP-Final] Completed ${response.url}, resourceId=${resourceId}, status=${response.statusCode}, duration=${Date.now() - state.startTime}ms`
        );
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Final] Failed to complete response for ${resourceId}: ${error}`);
      if (state.resourceEnabled) {
        FTSDKExtensionBridge.completeResourceError(state, response.url, String(error), undefined,
          response.performanceTiming);
      }
    } finally {
      FTSDKExtensionBridge.clearAxiosMethod(uniqueId);
      HttpAutoTrackStateStore.getInstance().delete(resourceId);
    }

    return true;
  }

  public static completeHttpError(response: FTSDKExtensionResponseInput): boolean {
    const requestHeaders = FTSDKExtensionBridge.normalizeHeaders(response.requestHeaders);
    const uniqueId = FTSDKExtensionBridge.resolveUniqueId(response.uniqueId, requestHeaders);
    if (!uniqueId) {
      FTInnerLogger.w(TAG, `[HTTP-Error] Missing resource id for ${response.url}`);
      return false;
    }

    const method = FTSDKExtensionBridge.resolveMethod(response.method, requestHeaders);
    const fallbackResourceId = buildAutoTrackResourceId(method, response.url, uniqueId);
    const state = HttpAutoTrackStateStore.getInstance().get(fallbackResourceId) as FTSDKExtensionHttpState | undefined;
    if (!state) {
      FTInnerLogger.w(TAG, `[HTTP-Error] Missing initial interceptor state for ${response.url}, uniqueId=${uniqueId}`);
      FTSDKExtensionBridge.clearAxiosMethod(uniqueId);
      return false;
    }

    try {
      if (state.traceEnabled) {
        try {
          const responseHeaders = FTSDKExtensionBridge.normalizeHeaders(response.responseHeaders);
          const responseBodyText = tryGetOptionalResponseBodyText(response.body);
          FTSDKExtensionBridge.completeTrace(state, response.statusCode || 0, responseHeaders, responseBodyText);
        } catch (traceError) {
          FTInnerLogger.e(TAG, `[HTTP-Error] Failed to complete trace for ${state.resourceId}: ${traceError}`);
        }
      }

      if (state.resourceEnabled) {
        const handling = response.statusCode === 0 ? handleFTNetworkError(state.networkErrorHandler,
          createFTNetworkErrorContext(
            state.url,
            state.method,
            FTNetworkErrorSource.HTTP_CHAIN,
            response.transportError,
            response.errorMessage || 'Unknown error',
            response.errorStack,
            response.errorCode
          )) : undefined;
        FTSDKExtensionBridge.completeResourceError(
          state,
          response.url,
          response.errorMessage || 'Unknown error',
          response.errorStack,
          response.performanceTiming,
          handling
        );
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Error] Failed to complete error for ${state.resourceId}: ${error}`);
      if (state.resourceEnabled) {
        FTSDKExtensionBridge.completeResourceError(state, response.url, String(error), undefined,
          response.performanceTiming);
      }
    } finally {
      FTSDKExtensionBridge.clearAxiosMethod(uniqueId);
      HttpAutoTrackStateStore.getInstance().delete(state.resourceId);
    }

    return true;
  }

  public static prepareAxiosChainRequest(request: FTSDKExtensionRequestInput): FTSDKExtensionPreparedRequest {
    const headers = FTSDKExtensionBridge.normalizeHeaders(request.headers);
    const uniqueId = ensureHttpResourceId(headers);
    const method = FTSDKExtensionBridge.normalizeMethod(request.method);
    AxiosChainMethodStore.getInstance().put(uniqueId, method);

    return {
      url: request.url,
      method: method,
      resourceId: buildAutoTrackResourceId(method, request.url, uniqueId),
      uniqueId: uniqueId,
      headers: headers,
      traceEnabled: false,
      resourceEnabled: false
    };
  }

  public static resolveAxiosMethod(uniqueId: string): string | undefined {
    return AxiosChainMethodStore.getInstance().get(uniqueId);
  }

  public static clearAxiosMethod(uniqueId: string): void {
    AxiosChainMethodStore.getInstance().delete(uniqueId);
  }

  public static logError(tag: string, message: string): void {
    FTInnerLogger.e(tag, message);
  }

  private static applyTraceHeaders(
    resourceId: string,
    request: FTSDKExtensionRequestInput,
    method: string,
    headers: Record<string, string>,
    uniqueId: string
  ): Record<string, string> {
    const traceInterceptor = FTSDKExtensionBridge.createTraceInterceptor();
    const traceManager = FTTraceManager.getInstance();
    let traceId: string | undefined = undefined;
    let spanId: string | undefined = undefined;
    let traceHeadersInjected = false;

    const headersMap = new Map<string, string>();
    const initialHeaderKeys = Object.keys(headers);
    for (let i = 0; i < initialHeaderKeys.length; i++) {
      const key = initialHeaderKeys[i];
      headersMap.set(key, headers[key]);
    }

    if (!FTSDKExtensionBridge.hasTraceHeaders(headers)) {
      const requestContext: FTTraceRequestContext = {
        url: request.url,
        method: method,
        headers: headers,
        body: request.body
      };
      const traceHeaders = traceManager.getTraceHeader(resourceId, request.url, method, requestContext);
      const traceContext = traceManager.getTraceContext(resourceId);
      traceId = traceContext ? traceContext.traceId : undefined;
      spanId = traceContext ? traceContext.spanId : undefined;
      traceHeadersInjected = true;
      const traceHeaderKeys = Object.keys(traceHeaders);
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        headersMap.set(key, traceHeaders[key]);
      }
    }

    const interceptedRequest = traceInterceptor.interceptRequest({
      url: request.url,
      method: method,
      headers: headersMap,
      body: request.body,
      timestamp: Date.now(),
      traceId: traceId,
      spanId: spanId,
      traceHeadersInjected: traceHeadersInjected
    });

    const finalHeaders: Record<string, string> = {};
    const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
    for (let i = 0; i < interceptedHeaders.length; i++) {
      const entry = interceptedHeaders[i];
      finalHeaders[entry[0]] = entry[1];
    }
    finalHeaders[FT_RESOURCE_ID_HEADER] = uniqueId;
    const finalTraceContext: FTTraceContext = FTTraceHandler.createTraceContextFromHeaders(
      finalHeaders,
      interceptedRequest.traceId || '',
      interceptedRequest.spanId || ''
    );
    traceManager.putTraceContext(resourceId, finalTraceContext);
    return finalHeaders;
  }

  private static hasTraceHeaders(headers: Record<string, string>): boolean {
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

  private static completeTrace(
    state: FTSDKExtensionHttpState,
    statusCode: number,
    responseHeaders: Record<string, string>,
    responseBodyText?: string
  ): void {
    const responseHeaderMap = new Map<string, string>();
    const responseHeaderKeys = Object.keys(responseHeaders);
    for (let i = 0; i < responseHeaderKeys.length; i++) {
      const key = responseHeaderKeys[i];
      responseHeaderMap.set(key, responseHeaders[key]);
    }

    const traceContext = FTTraceManager.getInstance().getTraceContext(state.resourceId);
    const traceId = traceContext ? traceContext.traceId : undefined;
    const spanId = traceContext ? traceContext.spanId : undefined;

    FTSDKExtensionBridge.createTraceInterceptor().interceptResponse({
      url: state.url,
      statusCode: statusCode,
      headers: responseHeaderMap,
      body: responseBodyText,
      timestamp: Date.now(),
      traceId: traceId,
      spanId: spanId,
      duration: Date.now() - state.startTime
    });
  }

  private static completeResource(
    state: FTSDKExtensionHttpState,
    response: FTSDKExtensionResponseInput,
    responseHeaders: Record<string, string>,
    responseBodyText?: string
  ): void {
    const resourceParams = new ResourceParams();
    resourceParams.setUrl(response.url);
    resourceParams.setResourceMethod(state.method);
    resourceParams.setRequestHeaderMap(buildRequestHeaderMap(state.requestHeaders));
    resourceParams.setRequestHeader(JSON.stringify(state.requestHeaders));
    resourceParams.setResourceStatus(response.statusCode || 0);
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

    const fallbackLoadNs = Math.max(Date.now() - state.startTime, 1) * 1000000;
    const resourceTiming = createFTResourceTimingFromNetworkPerformance(response.performanceTiming, fallbackLoadNs);
    const metricValue: PerformanceMetricValue = { value: resourceTiming.loadTime };
    resourceParams.addProperty('resourceLoad', metricValue);

    if (response.errorMessage) {
      resourceParams.setRequestErrorMsg(response.errorMessage);
    } else if ((response.statusCode || 0) >= 400 && responseBodyText) {
      resourceParams.setRequestErrorMsg(responseBodyText);
    }
    if (response.errorStack) {
      resourceParams.setRequestErrorStack(response.errorStack);
    }

    const netStatusBean = createFTNetStatusBean(resourceTiming);
    FTInnerLogger.d(TAG,
      `[Extension-Resource] Completed resourceId=${state.resourceId}, status=${response.statusCode || 0}, metrics=${Array.from(resourceTiming.performanceMetrics.keys()).join(',')}`);
    FTRUMInnerManager.getInstance().setTransformContent(state.resourceId, resourceParams);
    FTRUMInnerManager.getInstance().setNetState(state.resourceId, netStatusBean);
    FTRUMInnerManager.getInstance().stopResourceInternal(state.resourceId, state.actionId);
  }

  private static completeResourceError(
    state: FTSDKExtensionHttpState,
    url: string,
    errorMessage: string,
    errorStack?: string,
    performanceTiming?: FTNetworkPerformanceTiming,
    networkErrorHandling?: FTNetworkErrorHandlingResult
  ): void {
    const resourceParams = new ResourceParams();
    resourceParams.setUrl(url);
    resourceParams.setResourceMethod(state.method);
    resourceParams.setRequestHeaderMap(buildRequestHeaderMap(state.requestHeaders));
    resourceParams.setRequestHeader(JSON.stringify(state.requestHeaders));
    resourceParams.setRequestErrorMsg(errorMessage);
    resourceParams.setRequestErrorStack(errorStack || errorMessage);
    resourceParams.setResourceStatus(0);
    if (networkErrorHandling) {
      const propertyKeys = Object.keys(networkErrorHandling.resourceFields);
      for (let i = 0; i < propertyKeys.length; i++) {
        const key = propertyKeys[i];
        resourceParams.addProperty(key, networkErrorHandling.resourceFields[key] as object);
      }
      resourceParams.setSuppressNetworkError(networkErrorHandling.suppressNetworkError);
    }
    const fallbackLoadNs = Math.max(Date.now() - state.startTime, 1) * 1000000;
    const resourceTiming = createFTResourceTimingFromNetworkPerformance(performanceTiming, fallbackLoadNs);
    const metricValue: PerformanceMetricValue = { value: resourceTiming.loadTime };
    resourceParams.addProperty('resourceLoad', metricValue);
    const netStatusBean = createFTNetStatusBean(resourceTiming);
    FTInnerLogger.d(TAG,
      `[Extension-Resource] Failed resourceId=${state.resourceId}, metrics=${Array.from(resourceTiming.performanceMetrics.keys()).join(',')}`);
    FTRUMInnerManager.getInstance().setTransformContent(state.resourceId, resourceParams);
    FTRUMInnerManager.getInstance().setNetState(state.resourceId, netStatusBean);
    FTRUMInnerManager.getInstance().stopResourceInternal(state.resourceId, state.actionId);
  }

  private static createTraceInterceptor(): FTTraceInterceptor {
    const traceConfigManager = FTTraceConfigManager.getInstance();
    return new DefaultFTTraceInterceptor(
      traceConfigManager.getTraceTypeEnum(),
      traceConfigManager.getTraceHeaderHandler()
    );
  }

  private static resolveUniqueId(uniqueId: string | undefined, headers: Record<string, string>): string | undefined {
    if (uniqueId && uniqueId.length > 0) {
      return uniqueId;
    }
    return headers[FT_RESOURCE_ID_HEADER] || headers[FT_RESOURCE_ID_HEADER.toLowerCase()];
  }

  private static resolveMethod(method: string | undefined, headers: Record<string, string>): string {
    if (method && method.length > 0) {
      return method.toUpperCase();
    }
    return resolveAxiosChainMethod(headers);
  }

  private static normalizeMethod(method: string | undefined): string {
    if (!method || method.length === 0) {
      return 'GET';
    }
    const normalized = method.toUpperCase();
    return normalized.length > 0 ? normalized : HTTP_METHOD_UNKNOWN;
  }
}
