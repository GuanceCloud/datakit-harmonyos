import { http } from '@kit.NetworkKit';
import { FTInnerLogger } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { FTRUMConfigManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMInnerManager';
import { ResourceParams } from '@guancecloud/ft_sdk/src/main/ets/components/rum/bean/ResourceParams';
import { FTTraceConfigManager } from '@guancecloud/ft_sdk/src/main/ets/components/trace/FTTraceConfigManager';
import { FTTraceInterceptor, DefaultFTTraceInterceptor } from '@guancecloud/ft_sdk/src/main/ets/components/trace/FTTraceInterceptor';
import { FTTraceManager } from '@guancecloud/ft_sdk/src/main/ets/components/trace/FTTraceManager';
import {
  AxiosChainMethodStore,
  buildAutoTrackResourceId,
  buildRequestHeaderMap,
  buildResponseHeaderMap,
  ensureHttpResourceId,
  extractContentLength,
  FTAutoTrackOptions,
  HttpAutoTrackStateStore,
  normalizeObjectHeaders,
  PerformanceMetricValue,
  resolveAxiosChainMethod,
  summarizeHeaderKeys,
  tryGetResponseBodyText
} from '@guancecloud/ft_sdk/src/main/ets/components/network/FTHttpAutoTrackShared';
import { FTAxiosInterceptorTarget, FTAxiosRequestConfigTarget } from '@guancecloud/ft_sdk/src/main/ets/components/network/FTHttpAutoTrack';

const TAG = 'FTHttpAutoTrackExt';

export interface FTHttpInterceptorChainOptions extends FTAutoTrackOptions {
  interceptors?: http.HttpInterceptor[];
}

export interface FTHttpTrackConfigTarget {
  interceptorChain?: http.HttpInterceptorChain;
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

/**
 * HTTP INITIAL_REQUEST interceptor.
 * It injects trace headers and records the resource start point so it can be finished in FINAL_RESPONSE.
 */
export class HttpInitialRequestInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  private traceInterceptor: FTTraceInterceptor | null = null;
  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;

  constructor(traceEnabled?: boolean, resourceEnabled?: boolean) {
    this.traceEnabled = traceEnabled !== undefined ? traceEnabled : true;
    this.resourceEnabled = resourceEnabled !== undefined ? resourceEnabled : true;

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
      const headers = normalizeObjectHeaders(reqContext.header);
      const uniqueId = ensureHttpResourceId(headers);
      const method = resolveAxiosChainMethod(headers);
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
        const interceptedHeaders = Array.from(interceptedRequest.headers.entries());
        for (let i = 0; i < interceptedHeaders.length; i++) {
          const entry = interceptedHeaders[i];
          finalHeaders[entry[0]] = entry[1];
        }
        finalHeaders['X-FT-Resource-ID'] = uniqueId;
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
 */
export class HttpFinalResponseInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  private traceInterceptor: FTTraceInterceptor | null = null;
  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;

  constructor(traceEnabled?: boolean, resourceEnabled?: boolean) {
    this.traceEnabled = traceEnabled !== undefined ? traceEnabled : true;
    this.resourceEnabled = resourceEnabled !== undefined ? resourceEnabled : true;

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
    const uniqueId = requestHeaders['X-FT-Resource-ID'] || requestHeaders['x-ft-resource-id'];
    const url = reqContext.url;
    const method = resolveAxiosChainMethod(requestHeaders);
    const fallbackResourceId = uniqueId
      ? buildAutoTrackResourceId(method, url, uniqueId)
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
      if (uniqueId) {
        AxiosChainMethodStore.getInstance().delete(uniqueId);
      }
      HttpAutoTrackStateStore.getInstance().delete(resourceId);
    }

    return true;
  }
}

function createFTHttpInterceptors(
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

export function applyFTAxiosChainMethodBridge(axiosTarget: Object): number {
  const target = axiosTarget as FTAxiosInterceptorTarget;
  return target.interceptors.request.use((config: FTAxiosRequestConfigTarget) => {
    const method = (config.method || 'GET').toUpperCase();
    const headers = normalizeObjectHeaders(config.headers);
    const uniqueId = ensureHttpResourceId(headers);
    AxiosChainMethodStore.getInstance().put(uniqueId, method);
    config.headers = headers as Object;
    return config;
  });
}

export function applyFTHttpTrack(
  httpRequest: http.HttpRequest,
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = createFTHttpInterceptorChain(options);
  chain.apply(httpRequest);
  return chain;
}
