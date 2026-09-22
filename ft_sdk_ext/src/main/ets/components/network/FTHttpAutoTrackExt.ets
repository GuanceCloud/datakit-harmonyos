import { http } from '@kit.NetworkKit';
import {
  FTSDKExtensionBridge,
  FTSDKExtensionAutoTrackOptions,
  FTSDKExtensionResolvedAutoTrackOptions,
  FTSDKExtensionResponseInput,
  FTNetworkErrorHandler,
  FTResourceTransportMetricsProvider
} from '@guancecloud/ft_sdk/Index';

const TAG = 'FTHttpAutoTrackExt';

interface FTAxiosRequestConfigTarget {
  url?: string;
  baseURL?: string;
  method?: string;
  headers?: Object;
  data?: Object | string | ArrayBuffer;
  context?: Object;
}

interface FTAxiosInterceptorManager<T> {
  use(
    onFulfilled?: (value: T) => T | Promise<T>,
    onRejected?: (error: Object) => Object | Promise<Object>
  ): number;
}

interface FTAxiosInterceptors {
  request: FTAxiosInterceptorManager<FTAxiosRequestConfigTarget>;
}

interface FTAxiosInterceptorTarget {
  interceptors: FTAxiosInterceptors;
}

export interface FTHttpInterceptorChainOptions extends FTSDKExtensionAutoTrackOptions {
  interceptors?: http.HttpInterceptor[];
}

/**
 * Compatibility shape reserved for HTTP clients that expose an interceptorChain slot.
 */
export interface FTHttpTrackConfigTarget {
  interceptorChain?: http.HttpInterceptorChain;
}

interface FTHttpRequestContextTarget {
  method?: string;
  body?: string | Object | ArrayBuffer;
  extraData?: string | Object | ArrayBuffer;
  options?: FTHttpRequestContextOptionsTarget;
}

interface FTHttpRequestContextOptionsTarget {
  extraData?: string | Object | ArrayBuffer;
}

class NetworkKitResponseInput implements FTSDKExtensionResponseInput {
  url: string;
  requestHeaders?: Object | null;
  responseHeaders?: Object | null;
  statusCode: number;
  body?: string | Object | ArrayBuffer;
  performanceTiming?: http.PerformanceTiming;
  errorMessage?: string;
  errorStack?: string;
  transportError?: Object | string | number | boolean | null;
  errorCode?: string | number;

  constructor(
    request: http.HttpRequestContext,
    response: http.HttpResponse,
    statusCode: number,
    errorMessage?: string,
    errorStack?: string,
    transportError?: Object | string | number | boolean | null,
    errorCode?: string | number
  ) {
    this.url = request.url;
    this.requestHeaders = request.header;
    this.responseHeaders = response.header;
    this.statusCode = statusCode;
    this.body = response.result;
    this.performanceTiming = response.performanceTiming;
    this.errorMessage = errorMessage;
    this.errorStack = errorStack;
    this.transportError = transportError;
    this.errorCode = errorCode;
  }
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

export function resolveAxiosFullUrl(url?: string, baseURL?: string): string {
  const requestUrl = url || '';
  if (requestUrl.startsWith('http://') || requestUrl.startsWith('https://')) {
    return requestUrl;
  }

  const resolvedBaseURL = baseURL || '';
  if (!resolvedBaseURL) {
    return requestUrl;
  }
  if (!requestUrl) {
    return resolvedBaseURL;
  }

  const baseEndsWithSlash = resolvedBaseURL.endsWith('/');
  const requestStartsWithSlash = requestUrl.startsWith('/');
  if (baseEndsWithSlash && requestStartsWithSlash) {
    return `${resolvedBaseURL}${requestUrl.slice(1)}`;
  }
  if (!baseEndsWithSlash && !requestStartsWithSlash) {
    return `${resolvedBaseURL}/${requestUrl}`;
  }
  return `${resolvedBaseURL}${requestUrl}`;
}

/**
 * HTTP INITIAL_REQUEST interceptor.
 * It injects trace headers and records the resource start point so it can be finished in FINAL_RESPONSE.
 */
export class HttpInitialRequestInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;
  private readonly networkErrorHandler: FTNetworkErrorHandler | null | undefined;
  private readonly resourceTransportMetricsProvider: FTResourceTransportMetricsProvider | undefined;

  constructor(
    traceEnabled?: boolean,
    resourceEnabled?: boolean,
    networkErrorHandler?: FTNetworkErrorHandler | null,
    resourceTransportMetricsProvider?: FTResourceTransportMetricsProvider
  ) {
    const resolvedOptions = FTSDKExtensionBridge.resolveAutoTrackOptions({
      enableTraceInterceptor: traceEnabled,
      enableResourceInterceptor: resourceEnabled,
      resourceTransportMetricsProvider: resourceTransportMetricsProvider
    });
    this.traceEnabled = resolvedOptions.enableTraceInterceptor;
    this.resourceEnabled = resolvedOptions.enableResourceInterceptor;
    this.networkErrorHandler = networkErrorHandler;
    this.resourceTransportMetricsProvider = resourceTransportMetricsProvider;
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    try {
      const requestTarget = reqContext as Object as FTHttpRequestContextTarget;
      let requestBody = requestTarget.body;
      if (requestBody === undefined && requestTarget.extraData !== undefined) {
        requestBody = requestTarget.extraData;
      }
      if (requestBody === undefined && requestTarget.options) {
        requestBody = requestTarget.options.extraData;
      }
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(
        {
          url: reqContext.url,
          method: requestTarget.method,
          headers: reqContext.header,
          body: requestBody
        },
        {
          enableTraceInterceptor: this.traceEnabled,
          enableResourceInterceptor: this.resourceEnabled,
          networkErrorHandler: this.networkErrorHandler,
          resourceTransportMetricsProvider: this.resourceTransportMetricsProvider
        }
      );
      applyNormalizedHeadersToHttpContext(reqContext, preparedRequest.headers);
    } catch (error) {
      FTSDKExtensionBridge.logError(TAG, `[HTTP-Initial] Failed to process interceptor: ${error}`);
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

  constructor(_traceEnabled?: boolean, _resourceEnabled?: boolean) {
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, rspContext: http.HttpResponse): Promise<boolean> {
    const statusCode = rspContext.responseCode || 0;
    try {
      // console.info('ft-lizhao-http', JSON.stringify(rspContext.performanceTiming));
      // NetworkKit also invokes FINAL_RESPONSE for transport failures, with
      // responseCode=0. The normal response path has no error stack and would
      // produce a Resource without the corresponding network Error.
      if (!statusCode) {
        const error = new Error('NetworkKit request failed without an HTTP response');
        FTSDKExtensionBridge.completeHttpError(
          new NetworkKitResponseInput(reqContext, rspContext, 0, error.message, error.stack, undefined, 0)
        );
        return true;
      }
      FTSDKExtensionBridge.completeHttpResponse(
        new NetworkKitResponseInput(reqContext, rspContext, statusCode)
      );
    } catch (error) {
      // Once NetworkKit provides an HTTP status, a telemetry processing
      // failure must not reclassify that response as a status-0 transport
      // error. The bridge already makes response metadata best-effort.
      FTSDKExtensionBridge.logError(TAG,
        `[HTTP-Final] Failed to process response with status=${statusCode}: ${error}`);
    }
    return true;
  }
}

function createFTHttpInterceptors(options: FTSDKExtensionResolvedAutoTrackOptions): http.HttpInterceptor[] {
  const interceptors: http.HttpInterceptor[] = [];
  if (options.enableTraceInterceptor || options.enableResourceInterceptor) {
    interceptors.push(new HttpInitialRequestInterceptor(
      options.enableTraceInterceptor,
      options.enableResourceInterceptor,
      options.networkErrorHandler,
      options.resourceTransportMetricsProvider
    ));
    interceptors.push(new HttpFinalResponseInterceptor(
      options.enableTraceInterceptor,
      options.enableResourceInterceptor
    ));
  }
  return interceptors;
}

export function createFTHttpInterceptorChain(
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = new http.HttpInterceptorChain();
  const resolvedOptions = FTSDKExtensionBridge.resolveAutoTrackOptions(options);
  const interceptors = createFTHttpInterceptors(resolvedOptions);

  if (options.interceptors && options.interceptors.length > 0) {
    for (let i = 0; i < options.interceptors.length; i++) {
      interceptors.push(options.interceptors[i]);
    }
  }

  if (interceptors.length > 0) {
    try {
      const added = chain.addChain(interceptors);
      if (!added) {
        FTSDKExtensionBridge.logError(TAG, '[HTTP-Chain] Failed to add interceptor chain.');
      }
    } catch (error) {
      FTSDKExtensionBridge.logError(TAG, `[HTTP-Chain] Failed to add interceptor chain: ${error}`);
    }
  }
  return chain;
}

export function applyFTAxiosChainMethodBridge(axiosTarget: Object): number {
  const target = axiosTarget as FTAxiosInterceptorTarget;
  return target.interceptors.request.use((config: FTAxiosRequestConfigTarget) => {
    try {
      const preparedRequest = FTSDKExtensionBridge.prepareAxiosChainRequest({
        url: resolveAxiosFullUrl(config.url, config.baseURL),
        method: config.method,
        headers: config.headers,
        body: config.data
      });
      config.headers = preparedRequest.headers as Object;
    } catch (error) {
      FTSDKExtensionBridge.logError(TAG, `[Axios-Chain] Failed to prepare request: ${error}`);
    }
    return config;
  });
}

export function applyFTHttpTrackToChain(
  chain: http.HttpInterceptorChain,
  httpRequest: http.HttpRequest
): http.HttpInterceptorChain {
  try {
    const applied = chain.apply(httpRequest);
    if (!applied) {
      FTSDKExtensionBridge.logError(TAG, '[HTTP-Chain] Failed to apply interceptor chain.');
    }
  } catch (error) {
    FTSDKExtensionBridge.logError(TAG, `[HTTP-Chain] Failed to apply interceptor chain: ${error}`);
  }
  return chain;
}

export function applyFTHttpTrack(
  httpRequest: http.HttpRequest,
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = createFTHttpInterceptorChain(options);
  return applyFTHttpTrackToChain(chain, httpRequest);
}
