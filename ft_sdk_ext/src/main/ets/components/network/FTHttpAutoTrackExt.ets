import { http } from '@kit.NetworkKit';
import { FTHttpRequestObserver, observeHttpChainApply } from './FTHttpRequestObserver';
import {
  FTSDKExtensionBridge,
  FTSDKExtensionCleanup,
  FTSDKExtensionPreparedRequest,
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
  onUploadProgress?: (progress: FTAxiosUploadProgressTarget) => void;
}

interface FTAxiosUploadProgressTarget {
  loaded?: number;
  total?: number;
}

interface FTAxiosInterceptorManager<T> {
  eject?(id: number): void;
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
  resourceId?: string;
  uniqueId?: string;
  generation?: number;
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

/**
 * The NetworkKit chain callback does not expose its HttpRequest instance, but
 * applyFTHttpTrack has it before the request starts. Bind its cumulative
 * platform upload event to the Resource ID produced by INITIAL_REQUEST.
 */
class NetworkKitRequestMetricCollector implements FTSDKExtensionCleanup {
  prepared?: FTSDKExtensionPreparedRequest;
  requestMethod?: string;
  enabled: boolean = true;
  generation: number = FTSDKExtensionBridge.captureNetworkGeneration();
  private httpRequest: WeakRef<http.HttpRequest>;
  private progressListener: (progress: http.DataSendProgressInfo) => void;
  private subscribed: boolean = false;
  private cleanupId: number;
  private observer: FTHttpRequestObserver;
  private pendingFailure?: FTSDKExtensionResponseInput;

  constructor(httpRequest: http.HttpRequest) {
    this.httpRequest = new WeakRef(httpRequest);
    this.progressListener = this.createListener();
    this.cleanupId = FTSDKExtensionBridge.registerNetworkCleanup(this);
    this.observer = new FTHttpRequestObserver(httpRequest, error => this.completeFailure(error), () => {
      // Some adapters resolve a status-0 result. Complete that fallback only
      // after the public result has had a chance to expose a real exception.
      if (this.pendingFailure) {
        FTSDKExtensionBridge.completeHttpError(this.pendingFailure);
      }
      this.dispose();
    }, (_url: string, options?: http.HttpRequestOptions): void => {
      this.requestMethod = options?.method;
    });
  }

  public deferFailure(input: FTSDKExtensionResponseInput): void {
    this.pendingFailure = input;
  }

  private completeFailure(error: Object | string | number | boolean | null | undefined): void {
    const prepared = this.prepared;
    if (!prepared || !this.enabled) return;
    const input: FTSDKExtensionResponseInput = this.pendingFailure || {
      url: prepared.url, resourceId: prepared.resourceId, uniqueId: prepared.uniqueId,
      generation: prepared.generation, statusCode: 0
    };
    input.transportError = error;
    FTSDKExtensionBridge.completeHttpError(input);
    this.pendingFailure = undefined;
  }

  private createListener(): (progress: http.DataSendProgressInfo) => void {
    return (progress: http.DataSendProgressInfo): void => {
      const prepared = this.prepared;
      if (prepared && progress && FTSDKExtensionBridge.isNetworkGenerationCurrent(prepared.generation!) &&
        Number.isFinite(progress.sendSize) && progress.sendSize >= 0) {
        FTSDKExtensionBridge.recordPlatformRequestBodySize(prepared.resourceId, progress.sendSize);
      }
    };
  }

  public bindResource(prepared: FTSDKExtensionPreparedRequest): void {
    this.prepared = prepared;
    if (!this.cleanupId) this.cleanupId = FTSDKExtensionBridge.registerNetworkCleanup(this);
    const request = this.httpRequest.deref();
    if (!prepared.resourceEnabled || !request || this.subscribed) return;
    try {
      request.on('dataSendProgress', this.progressListener);
      this.subscribed = true;
    } catch (error) {
      FTSDKExtensionBridge.logError(TAG, `Failed to subscribe upload progress: ${error}`);
    }
  }

  public dispose(): void {
    if (this.subscribed) {
      try { this.httpRequest.deref()?.off('dataSendProgress', this.progressListener); } catch (error) {
        FTSDKExtensionBridge.logError(TAG, `Failed to unsubscribe upload progress: ${error}`);
      }
    }
    this.subscribed = false;
    this.pendingFailure = undefined;
    this.prepared = undefined;
    this.requestMethod = undefined;
    FTSDKExtensionBridge.unregisterNetworkCleanup(this.cleanupId);
    this.cleanupId = 0;
  }

  public deactivate(canceled: boolean = false): void {
    this.enabled = false;
    this.observer.dispose();
    const prepared = this.prepared;
    try {
      if (prepared) FTSDKExtensionBridge.completeHttpError({
        url: prepared.url, resourceId: prepared.resourceId, uniqueId: prepared.uniqueId,
        generation: prepared.generation, statusCode: 0,
        errorMessage: canceled ? 'Request canceled before HTTP tracking completion' : 'HTTP tracking disposed before completion'
      });
    } finally { this.dispose(); }
  }
}

class NetworkKitTrackBinding {
  chain: http.HttpInterceptorChain;
  collector: NetworkKitRequestMetricCollector;
  applied: boolean = false;
  constructor(chain: http.HttpInterceptorChain, collector: NetworkKitRequestMetricCollector) {
    this.chain = chain;
    this.collector = collector;
  }
}
const httpTrackBindings: WeakMap<http.HttpRequest, NetworkKitTrackBinding> = new WeakMap();

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
export class HttpInitialRequestInterceptor implements http.HttpInterceptor, FTSDKExtensionCleanup {
  private generation: number = FTSDKExtensionBridge.captureNetworkGeneration();
  private cleanupId: number = FTSDKExtensionBridge.registerNetworkCleanup(this);
  private active: boolean = true;

  public dispose(): void {
    this.active = false;
    this.networkErrorHandler = undefined;
    this.resourceTransportMetricsProvider = undefined;
    FTSDKExtensionBridge.unregisterNetworkCleanup(this.cleanupId);
  }

  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  private readonly traceEnabled: boolean;
  private readonly resourceEnabled: boolean;
  private networkErrorHandler: FTNetworkErrorHandler | null | undefined;
  private resourceTransportMetricsProvider: FTResourceTransportMetricsProvider | undefined;
  private readonly platformMetricCollector?: WeakRef<NetworkKitRequestMetricCollector>;

  constructor(
    traceEnabled?: boolean,
    resourceEnabled?: boolean,
    networkErrorHandler?: FTNetworkErrorHandler | null,
    resourceTransportMetricsProvider?: FTResourceTransportMetricsProvider,
    platformMetricCollector?: NetworkKitRequestMetricCollector
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
    this.platformMetricCollector = platformMetricCollector ? new WeakRef(platformMetricCollector) : undefined;
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    const collector = this.platformMetricCollector?.deref();
    if (!this.active || !FTSDKExtensionBridge.isNetworkGenerationCurrent(this.generation) ||
      (this.platformMetricCollector && (!collector || !collector.enabled))) return true;
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
          method: collector ? collector.requestMethod : requestTarget.method,
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
      collector?.bindResource(preparedRequest);
      applyNormalizedHeadersToHttpContext(reqContext, preparedRequest.headers);
    } catch (error) {
      collector?.deactivate();
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
  private generation: number = FTSDKExtensionBridge.captureNetworkGeneration();
  private readonly platformMetricCollector?: WeakRef<NetworkKitRequestMetricCollector>;

  constructor(
    _traceEnabled?: boolean,
    _resourceEnabled?: boolean,
    platformMetricCollector?: NetworkKitRequestMetricCollector
  ) {
    this.platformMetricCollector = platformMetricCollector ? new WeakRef(platformMetricCollector) : undefined;
  }

  async interceptorHandle(reqContext: http.HttpRequestContext, rspContext: http.HttpResponse): Promise<boolean> {
    const collector = this.platformMetricCollector?.deref();
    if (!FTSDKExtensionBridge.isNetworkGenerationCurrent(this.generation) ||
      (this.platformMetricCollector && (!collector || !collector.enabled))) return true;
    const statusCode = rspContext.responseCode || 0;
    let deferred = false;
    try {
      const input = new NetworkKitResponseInput(reqContext, rspContext, statusCode);
      input.resourceId = collector?.prepared?.resourceId;
      input.uniqueId = collector?.prepared?.uniqueId;
      input.generation = this.generation;
      // console.info('ft-lizhao-http', JSON.stringify(rspContext.performanceTiming));
      // NetworkKit also invokes FINAL_RESPONSE for transport failures, with
      // responseCode=0. The normal response path has no error stack and would
      // produce a Resource without the corresponding network Error.
      if (!statusCode) {
        const error = new Error('Request failed without an HTTP response');
        input.errorMessage = error.message;
        input.errorStack = error.stack;
        if (collector) {
          collector.deferFailure(input);
          deferred = true;
          return true;
        }
        FTSDKExtensionBridge.completeHttpError(input);
        return true;
      }
      FTSDKExtensionBridge.completeHttpResponse(input);
    } catch (error) {
      // Once NetworkKit provides an HTTP status, a telemetry processing
      // failure must not reclassify that response as a status-0 transport
      // error. The bridge already makes response metadata best-effort.
      FTSDKExtensionBridge.logError(TAG,
        `[HTTP-Final] Failed to process response with status=${statusCode}: ${error}`);
    } finally {
      if (!deferred) collector?.dispose();
    }
    return true;
  }
}

function createFTHttpInterceptors(
  options: FTSDKExtensionResolvedAutoTrackOptions,
  platformMetricCollector?: NetworkKitRequestMetricCollector
): http.HttpInterceptor[] {
  const interceptors: http.HttpInterceptor[] = [];
  if (options.enableTraceInterceptor || options.enableResourceInterceptor) {
    interceptors.push(new HttpInitialRequestInterceptor(
      options.enableTraceInterceptor,
      options.enableResourceInterceptor,
      options.networkErrorHandler,
      options.resourceTransportMetricsProvider,
      platformMetricCollector
    ));
    interceptors.push(new HttpFinalResponseInterceptor(
      options.enableTraceInterceptor,
      options.enableResourceInterceptor,
      platformMetricCollector
    ));
  }
  return interceptors;
}

function createFTHttpInterceptorChainInternal(
  options: FTHttpInterceptorChainOptions,
  platformMetricCollector?: NetworkKitRequestMetricCollector
): http.HttpInterceptorChain {
  const chain = new http.HttpInterceptorChain();
  const resolvedOptions = FTSDKExtensionBridge.resolveAutoTrackOptions(options);
  const interceptors = createFTHttpInterceptors(resolvedOptions, platformMetricCollector);

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

class NetworkKitChainOptionsOwner implements FTSDKExtensionCleanup {
  options: FTSDKExtensionResolvedAutoTrackOptions;
  private cleanupId: number;
  constructor(options: FTSDKExtensionResolvedAutoTrackOptions) {
    this.options = options;
    this.cleanupId = FTSDKExtensionBridge.registerNetworkCleanup(this);
  }
  public dispose(): void {
    this.options.networkErrorHandler = undefined;
    this.options.resourceTransportMetricsProvider = undefined;
    FTSDKExtensionBridge.unregisterNetworkCleanup(this.cleanupId);
  }
}

export function createFTHttpInterceptorChain(
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const chain = createFTHttpInterceptorChainInternal(options);
  const generation = FTSDKExtensionBridge.captureNetworkGeneration();
  const owner = new NetworkKitChainOptionsOwner(FTSDKExtensionBridge.resolveAutoTrackOptions(options));
  // A chain may be shared by concurrent Axios/native requests. Bind a separate
  // collector when NetworkKit supplies the actual HttpRequest to apply().
  observeHttpChainApply(chain, (request: http.HttpRequest): boolean => {
    const customInterceptors: http.HttpInterceptor[] = [];
    for (const interceptor of chain.getChain()) {
      if (!(interceptor instanceof HttpInitialRequestInterceptor) &&
        !(interceptor instanceof HttpFinalResponseInterceptor)) customInterceptors.push(interceptor);
    }
    applyFTHttpTrack(request, {
      enableTraceInterceptor: owner.options.enableTraceInterceptor,
      enableResourceInterceptor: owner.options.enableResourceInterceptor,
      networkErrorHandler: owner.options.networkErrorHandler,
      resourceTransportMetricsProvider: owner.options.resourceTransportMetricsProvider,
      interceptors: customInterceptors
    });
    return httpTrackBindings.get(request)?.applied || false;
  }, (): boolean => FTSDKExtensionBridge.isNetworkGenerationCurrent(generation));
  return chain;
}

type AxiosUploadCallback = (progress: FTAxiosUploadProgressTarget) => void;

class AxiosChainProgressOwner implements FTSDKExtensionCleanup {
  private config?: WeakRef<FTAxiosRequestConfigTarget>;
  private original?: AxiosUploadCallback;
  private callback: AxiosUploadCallback;
  private resourceId?: string;
  private generation: number = FTSDKExtensionBridge.captureNetworkGeneration();
  private cleanupId: number;

  constructor(config: FTAxiosRequestConfigTarget, prepared: FTSDKExtensionPreparedRequest) {
    this.config = new WeakRef(config);
    this.original = config.onUploadProgress;
    this.resourceId = prepared.resourceId;
    this.callback = this.createCallback();
    this.cleanupId = FTSDKExtensionBridge.registerNetworkCleanup(this, prepared.uniqueId);
    config.onUploadProgress = this.callback;
  }
  private createCallback(): AxiosUploadCallback {
    const original = this.original;
    return (progress: FTAxiosUploadProgressTarget): void => {
      if (this.resourceId && FTSDKExtensionBridge.isNetworkGenerationCurrent(this.generation)) {
        const bytes = progress?.loaded;
        if (bytes !== undefined) FTSDKExtensionBridge.recordPlatformRequestBodySize(this.resourceId, bytes);
      }
      original?.(progress);
    };
  }
  public dispose(): void {
    const config = this.config?.deref();
    if (config && config.onUploadProgress === this.callback) config.onUploadProgress = this.original;
    this.resourceId = undefined;
    this.original = undefined;
    this.config = undefined;
    FTSDKExtensionBridge.unregisterNetworkCleanup(this.cleanupId);
  }
}

class AxiosChainBridgeOwner implements FTSDKExtensionCleanup {
  id: number = -1;
  active: boolean = true;
  generation: number = FTSDKExtensionBridge.captureNetworkGeneration();
  private target: WeakRef<FTAxiosInterceptorTarget>;
  private cleanupId: number;
  constructor(target: FTAxiosInterceptorTarget) {
    this.target = new WeakRef(target);
    this.cleanupId = FTSDKExtensionBridge.registerNetworkCleanup(this);
  }
  public dispose(): void {
    if (!this.active) return;
    this.active = false;
    const target = this.target.deref();
    try { target?.interceptors.request.eject?.(this.id); } catch (_) {}
    if (target && axiosChainBridges.get(target) === this) axiosChainBridges.delete(target);
    FTSDKExtensionBridge.unregisterNetworkCleanup(this.cleanupId);
  }
}
const axiosChainBridges: WeakMap<Object, AxiosChainBridgeOwner> = new WeakMap();
const axiosChainProgress: WeakMap<Object, AxiosChainProgressOwner> = new WeakMap();

export function removeFTAxiosChainMethodBridge(axiosTarget: Object): void {
  axiosChainBridges.get(axiosTarget)?.dispose();
}

export function applyFTAxiosChainMethodBridge(axiosTarget: Object): number {
  const existing = axiosChainBridges.get(axiosTarget);
  if (existing?.active && FTSDKExtensionBridge.isNetworkGenerationCurrent(existing.generation)) return existing.id;
  existing?.dispose();
  const target = axiosTarget as FTAxiosInterceptorTarget;
  const owner = new AxiosChainBridgeOwner(target);
  axiosChainBridges.set(axiosTarget, owner);
  owner.id = target.interceptors.request.use((config: FTAxiosRequestConfigTarget) => {
    if (!owner.active || !FTSDKExtensionBridge.isNetworkGenerationCurrent(owner.generation)) return config;
    axiosChainProgress.get(config)?.dispose();
    try {
      const preparedRequest = FTSDKExtensionBridge.prepareAxiosChainRequest({
        url: resolveAxiosFullUrl(config.url, config.baseURL), method: config.method,
        headers: config.headers, body: config.data
      });
      config.headers = preparedRequest.headers as Object;
      axiosChainProgress.set(config, new AxiosChainProgressOwner(config, preparedRequest));
    } catch (error) {
      FTSDKExtensionBridge.logError(TAG, `[Axios-Chain] Failed to prepare request: ${error}`);
    }
    return config;
  });
  return owner.id;
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

/** Call before cancelling/destroying a request if no FINAL_RESPONSE will arrive. */
export function disposeFTHttpTrack(httpRequest: http.HttpRequest): void {
  const binding = httpTrackBindings.get(httpRequest);
  binding?.collector.deactivate(true);
  httpTrackBindings.delete(httpRequest);
  if (binding) {
    for (const interceptor of binding.chain.getChain()) {
      if (interceptor instanceof HttpInitialRequestInterceptor) interceptor.dispose();
    }
  }
}

export function applyFTHttpTrack(
  httpRequest: http.HttpRequest,
  options: FTHttpInterceptorChainOptions = {}
): http.HttpInterceptorChain {
  const existing = httpTrackBindings.get(httpRequest);
  if (existing && existing.collector.enabled &&
    FTSDKExtensionBridge.isNetworkGenerationCurrent(existing.collector.generation)) return existing.chain;
  if (existing) disposeFTHttpTrack(httpRequest);
  const collector = new NetworkKitRequestMetricCollector(httpRequest);
  const chain = createFTHttpInterceptorChainInternal(options, collector);
  const binding = new NetworkKitTrackBinding(chain, collector);
  httpTrackBindings.set(httpRequest, binding);
  try {
    binding.applied = chain.apply(httpRequest);
    if (!binding.applied) collector.deactivate();
  } catch (error) {
    collector.deactivate();
    FTSDKExtensionBridge.logError(TAG, `[HTTP-Chain] Failed to apply interceptor chain: ${error}`);
  }
  return chain;
}
