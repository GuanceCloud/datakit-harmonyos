import { FTNetworkDisposable, FTNetworkLifecycle } from '../network/FTNetworkLifecycle';
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
  FTNetworkErrorContext,
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
  createHeaderInferredTransportMetrics,
  ensureHttpResourceId,
  extractContentLength,
  FTNetworkPerformanceTiming,
  FTResourceTransportMetricsInput,
  FTResourceTransportMetricsProvider,
  HttpAutoTrackCompletionStore,
  HttpAutoTrackState,
  HttpAutoTrackStateStore,
  normalizeObjectHeaders,
  mergeResourceTransportMetricsInput,
  PerformanceMetricValue,
  applyIntegrationTransportMetrics,
  applyHeaderInferredTransportMetrics,
  applyPlatformTransportMetrics,
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
  /**
   * Overrides FTRUMConfig's default handler for this interceptor chain. Pass
   * null to opt this chain out of the configured global default.
   */
  networkErrorHandler?: FTNetworkErrorHandler | null;
  /** Supplies integration-verified request transport values after headers are finalized. */
  resourceTransportMetricsProvider?: FTResourceTransportMetricsProvider;
}

export interface FTSDKExtensionResolvedAutoTrackOptions {
  enableTraceInterceptor: boolean;
  enableResourceInterceptor: boolean;
  /**
   * Preserve null until the request state is created so a chain-level opt-out
   * cannot be mistaken for an omitted option and fall back to the global
   * handler.
   */
  networkErrorHandler?: FTNetworkErrorHandler | null;
  resourceTransportMetricsProvider?: FTResourceTransportMetricsProvider;
}

export interface FTSDKExtensionRequestInput {
  url: string;
  method?: string;
  headers?: Object | null;
  body?: string | Object | ArrayBuffer;
  /** Explicit values for this request; they override the options provider. */
  transportMetrics?: FTResourceTransportMetricsInput;
}

export interface FTSDKExtensionCleanup {
  dispose(): void;
}

export interface FTSDKExtensionPreparedRequest {
  generation?: number;
  url: string;
  method: string;
  resourceId: string;
  uniqueId: string;
  headers: Record<string, string>;
  traceEnabled: boolean;
  resourceEnabled: boolean;
}

export interface FTSDKExtensionResponseInput {
  resourceId?: string;
  generation?: number;
  url: string;
  method?: string;
  uniqueId?: string;
  requestHeaders?: Object | null;
  responseHeaders?: Object | null;
  statusCode: number;
  body?: string | Object | ArrayBuffer;
  /** NetworkKit/axios cumulative wire timing; absent on unsupported adapters. */
  performanceTiming?: FTNetworkPerformanceTiming;
  /** Explicit integration values available only after request completion. */
  transportMetrics?: FTResourceTransportMetricsInput;
  /** Final values obtained from a platform transport API. */
  platformTransportMetrics?: FTResourceTransportMetricsInput;
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
  /** Bytes observed asynchronously from the NetworkKit HttpRequest instance. */
  platformTransportMetrics?: FTResourceTransportMetricsInput;
}

export class FTSDKExtensionBridge {
  public static captureNetworkGeneration(): number { return FTNetworkLifecycle.capture(); }
  public static isNetworkGenerationCurrent(generation: number): boolean {
    return FTNetworkLifecycle.isCurrent(generation);
  }
  public static registerNetworkCleanup(owner: FTSDKExtensionCleanup, uniqueId: string = ''): number {
    return FTNetworkLifecycle.register(owner as FTNetworkDisposable, uniqueId);
  }
  public static unregisterNetworkCleanup(id: number): void { FTNetworkLifecycle.unregister(id); }
  public static finishNetworkRequest(uniqueId: string): void {
    FTNetworkLifecycle.finishRequest(uniqueId);
    FTSDKExtensionBridge.clearAxiosMethod(uniqueId);
  }

  private static findResponseState(response: FTSDKExtensionResponseInput): FTSDKExtensionHttpState | undefined {
    if (response.generation !== undefined && !FTNetworkLifecycle.isCurrent(response.generation)) return undefined;
    let headers: Record<string, string> = {};
    try { headers = FTSDKExtensionBridge.normalizeHeaders(response.requestHeaders); } catch (error) {
      FTInnerLogger.w(TAG, `Invalid completion headers: ${error}`);
    }
    const uniqueId = FTSDKExtensionBridge.resolveUniqueId(response.uniqueId, headers);
    const store = HttpAutoTrackStateStore.getInstance();
    // The start identity survives redirects and platform method normalization.
    const state = (response.resourceId ? store.get(response.resourceId) : undefined) ||
      (uniqueId ? store.getByUniqueId(uniqueId) : undefined);
    if (!state || (state.generation !== undefined && !FTNetworkLifecycle.isCurrent(state.generation))) {
      if (uniqueId) FTSDKExtensionBridge.finishNetworkRequest(uniqueId);
      return undefined;
    }
    return state as FTSDKExtensionHttpState;
  }

  private static releaseResponseState(state: FTSDKExtensionHttpState): void {
    const uniqueId = state.uniqueId || FTSDKExtensionBridge.resolveUniqueId(undefined, state.requestHeaders);
    if (uniqueId) FTSDKExtensionBridge.finishNetworkRequest(uniqueId);
    HttpAutoTrackStateStore.getInstance().delete(state.resourceId);
    FTTraceManager.releaseAutoTrace(state.resourceId);
  }

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
      networkErrorHandler: options.networkErrorHandler !== undefined
        ? options.networkErrorHandler
        : FTRUMConfigManager.getInstance().getNetworkErrorHandler(),
      resourceTransportMetricsProvider: options.resourceTransportMetricsProvider
    };
  }

  public static normalizeHeaders(headers?: Object | null): Record<string, string> {
    return normalizeObjectHeaders(headers);
  }

  /**
   * Records a cumulative `HttpRequest.dataSendProgress.sendSize` value for
   * exactly one in-flight Resource. The HTTP callback is asynchronous, so the
   * initial interceptor has already created the Resource state when this runs.
   */
  public static recordPlatformRequestBodySize(resourceId: string, size: number): void {
    if (!resourceId || !Number.isFinite(size) || size < 0) {
      return;
    }
    const state = HttpAutoTrackStateStore.getInstance().get(resourceId) as FTSDKExtensionHttpState | undefined;
    if (!state) {
      return;
    }
    if (!state.platformTransportMetrics) {
      state.platformTransportMetrics = {};
    }
    const existing = state.platformTransportMetrics.requestBodySize;
    // NetworkKit sends cumulative progress. Keeping the maximum also tolerates
    // a platform callback sequence that repeats an earlier progress value.
    if (existing === undefined || size > existing) {
      state.platformTransportMetrics.requestBodySize = size;
    }
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
    const generation = FTNetworkLifecycle.capture();
    if (!FTNetworkLifecycle.isCurrent(generation)) {
      return { url: request.url, method: method, resourceId: resourceId, uniqueId: uniqueId,
        headers: headers, traceEnabled: false, resourceEnabled: false, generation: generation };
    }
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

      let providerMetrics: FTResourceTransportMetricsInput | undefined = undefined;
      if (resolvedOptions.resourceTransportMetricsProvider) {
        try {
          providerMetrics = resolvedOptions.resourceTransportMetricsProvider({
            url: request.url,
            method: method,
            headers: finalHeaders,
            body: request.body
          });
        } catch (error) {
          FTInnerLogger.w(TAG, `[HTTP-Initial] Ignored transport metrics provider error for resourceId=${resourceId}: ${error}`);
        }
      }
      const state: FTSDKExtensionHttpState = {
        resourceId: resourceId,
        uniqueId: uniqueId,
        generation: generation,
        url: request.url,
        method: method,
        startTime: Date.now(),
        requestHeaders: finalHeaders,
        actionId: actionId,
        traceEnabled: resolvedOptions.enableTraceInterceptor,
        resourceEnabled: resourceEnabled,
        networkErrorHandler: resolvedOptions.networkErrorHandler ?? undefined,
        transportMetrics: mergeResourceTransportMetricsInput(providerMetrics, request.transportMetrics),
        headerInferredTransportMetrics: createHeaderInferredTransportMetrics(
          request.headers,
          finalHeaders,
          request.body
        )
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
      generation: generation,
      headers: finalHeaders,
      traceEnabled: resolvedOptions.enableTraceInterceptor,
      resourceEnabled: resourceEnabled
    };
  }

  public static completeHttpResponse(response: FTSDKExtensionResponseInput): boolean {
    const state = FTSDKExtensionBridge.findResponseState(response);
    if (!state) return false;

    const resourceId = state.resourceId;
    let resourceCompletionClaimed = false;
    try {
      let responseHeaders: Record<string, string> = {};
      try {
        responseHeaders = FTSDKExtensionBridge.normalizeHeaders(response.responseHeaders);
      } catch (error) {
        // Response metadata is optional. A malformed platform header must not
        // turn an already-known HTTP response into a transport failure.
        FTInnerLogger.e(TAG, `[HTTP-Final] Failed to normalize response headers for ${resourceId}: ${error}`);
      }

      let responseBodyText: string | undefined = undefined;
      try {
        responseBodyText = tryGetOptionalResponseBodyText(response.body);
      } catch (error) {
        FTInnerLogger.e(TAG, `[HTTP-Final] Failed to read response body for ${resourceId}: ${error}`);
      }

      if (state.traceEnabled) {
        try {
          FTSDKExtensionBridge.completeTrace(state, response.statusCode, responseHeaders, responseBodyText);
        } catch (error) {
          FTInnerLogger.e(TAG, `[HTTP-Final] Failed to complete trace for ${resourceId}: ${error}`);
        }
      }

      if (state.resourceEnabled) {
        resourceCompletionClaimed = HttpAutoTrackCompletionStore.getInstance().tryClaim(resourceId);
      }
      if (resourceCompletionClaimed) {
        FTSDKExtensionBridge.completeResource(state, response, responseHeaders, responseBodyText);
        FTInnerLogger.d(
          TAG,
          `[HTTP-Final] Completed ${response.url}, resourceId=${resourceId}, status=${response.statusCode}, duration=${Date.now() - state.startTime}ms`
        );
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Final] Failed to complete response for ${resourceId}: ${error}`);
    } finally {
      FTSDKExtensionBridge.releaseResponseState(state);
    }

    return true;
  }

  public static completeHttpError(response: FTSDKExtensionResponseInput): boolean {
    const state = FTSDKExtensionBridge.findResponseState(response);
    if (!state) return false;

    let resourceCompletionClaimed = false;
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
        resourceCompletionClaimed = HttpAutoTrackCompletionStore.getInstance().tryClaim(state.resourceId);
      }
      if (resourceCompletionClaimed) {
        const errorContext = response.statusCode === 0 ? createFTNetworkErrorContext(
            state.url,
            state.method,
            FTNetworkErrorSource.HTTP_CHAIN,
            response.transportError,
            response.errorMessage || 'Unknown error',
            response.errorStack,
            response.errorCode
          ) : undefined;
        const handling = errorContext ? handleFTNetworkError(state.networkErrorHandler, errorContext) : undefined;
        FTSDKExtensionBridge.completeResourceError(
          state,
          response.url,
          response.errorMessage || 'Unknown error',
          response.errorStack,
          response.performanceTiming,
          response.transportMetrics,
          response.platformTransportMetrics,
          handling,
          errorContext
        );
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[HTTP-Error] Failed to complete error for ${state.resourceId}: ${error}`);
      if (state.resourceEnabled && (resourceCompletionClaimed ||
        HttpAutoTrackCompletionStore.getInstance().tryClaim(state.resourceId))) {
        FTSDKExtensionBridge.completeResourceError(state, response.url, String(error), undefined,
          response.performanceTiming);
      }
    } finally {
      FTSDKExtensionBridge.releaseResponseState(state);
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
    applyIntegrationTransportMetrics(
      resourceParams,
      mergeResourceTransportMetricsInput(state.transportMetrics, response.transportMetrics)
    );
    applyPlatformTransportMetrics(resourceParams, state.platformTransportMetrics);
    applyPlatformTransportMetrics(resourceParams, response.platformTransportMetrics);
    applyHeaderInferredTransportMetrics(resourceParams, state.headerInferredTransportMetrics);

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
    let resourceTiming = createFTResourceTimingFromNetworkPerformance(undefined, fallbackLoadNs);
    try {
      resourceTiming = createFTResourceTimingFromNetworkPerformance(response.performanceTiming, fallbackLoadNs);
    } catch (error) {
      // Timing is auxiliary to an HTTP response. Keep the response and use
      // local elapsed time when a platform timing object is invalid.
      FTInnerLogger.e(TAG, `[Extension-Resource] Failed to parse timing for ${state.resourceId}: ${error}`);
    }
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
    responseTransportMetrics?: FTResourceTransportMetricsInput,
    platformTransportMetrics?: FTResourceTransportMetricsInput,
    networkErrorHandling?: FTNetworkErrorHandlingResult,
    networkErrorContext?: FTNetworkErrorContext
  ): void {
    const resourceParams = new ResourceParams();
    resourceParams.setUrl(url);
    resourceParams.setResourceMethod(state.method);
    resourceParams.setRequestHeaderMap(buildRequestHeaderMap(state.requestHeaders));
    resourceParams.setRequestHeader(JSON.stringify(state.requestHeaders));
    resourceParams.setRequestErrorMsg(errorMessage);
    resourceParams.setRequestErrorStack(errorStack || errorMessage);
    resourceParams.setResourceStatus(0);
    applyIntegrationTransportMetrics(resourceParams, state.transportMetrics);
    applyIntegrationTransportMetrics(resourceParams, responseTransportMetrics);
    applyPlatformTransportMetrics(resourceParams, state.platformTransportMetrics);
    applyPlatformTransportMetrics(resourceParams, platformTransportMetrics);
    applyHeaderInferredTransportMetrics(resourceParams, state.headerInferredTransportMetrics);
    if (networkErrorContext) {
      resourceParams.addProperty('network_error_kind', new String(networkErrorContext.kind));
      resourceParams.addProperty('network_error_message', new String(networkErrorContext.message));
    }
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
