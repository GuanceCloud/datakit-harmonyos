import { http } from '@kit.NetworkKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';

type RequestOptions = http.HttpRequestOptions | AsyncCallback<http.HttpResponse>;
type StreamOptions = http.HttpRequestOptions | AsyncCallback<number>;
type Failure = Object | string | number | boolean | null | undefined;

/** Keep dynamic platform method adaptation outside the baseline ArkTS API. */
export function observeHttpChainApply(chain: http.HttpInterceptorChain,
  apply: (request: http.HttpRequest) => boolean, isCurrent: () => boolean): void {
  const original = chain.apply;
  chain.apply = (request: http.HttpRequest): boolean =>
    isCurrent() ? apply(request) : original.bind(chain)(request);
}

interface HttpRequestMethods {
  request(url: string, callback: AsyncCallback<http.HttpResponse>): void;
  request(url: string, options: http.HttpRequestOptions, callback: AsyncCallback<http.HttpResponse>): void;
  request(url: string, options?: http.HttpRequestOptions): Promise<http.HttpResponse>;
  requestInStream(url: string, callback: AsyncCallback<number>): void;
  requestInStream(url: string, options: http.HttpRequestOptions, callback: AsyncCallback<number>): void;
  requestInStream(url: string, options?: http.HttpRequestOptions): Promise<number>;
}

/** Observe the public completion API because FINAL_RESPONSE omits BusinessError. */
export class FTHttpRequestObserver {
  private target: WeakRef<http.HttpRequest>;
  private original: HttpRequestMethods;
  private requestWrapper = this.observeRequest.bind(this);
  private streamWrapper = this.observeStream.bind(this);

  constructor(target: http.HttpRequest, private onFailure: (error: Failure) => void,
    private onSettled: () => void,
    private onStart?: (url: string, options?: http.HttpRequestOptions) => void) {
    this.target = new WeakRef(target);
    this.original = { request: target.request, requestInStream: target.requestInStream };
    target.request = this.requestWrapper;
    target.requestInStream = this.streamWrapper;
  }

  private failed(error: Failure): void {
    // SDK processing must never escape into the application's callback/Promise.
    try { this.onFailure(error); } catch (_) {}
  }

  private settled(): void {
    try { this.onSettled(); } catch (_) {}
  }

  private started(url: string, options?: http.HttpRequestOptions): void {
    try { this.onStart?.(url, options); } catch (_) {}
  }

  private observeRequest(url: string, callback: AsyncCallback<http.HttpResponse>): void;
  private observeRequest(url: string, options: http.HttpRequestOptions, callback: AsyncCallback<http.HttpResponse>): void;
  private observeRequest(url: string, options?: http.HttpRequestOptions): Promise<http.HttpResponse>;
  private observeRequest(url: string, options?: RequestOptions,
    callback?: AsyncCallback<http.HttpResponse>): void | Promise<http.HttpResponse> {
    const target = this.target.deref()!;
    this.started(url, typeof options === 'function' ? undefined : options);
    const completion = typeof options === 'function' ? options : callback;
    if (completion) {
      const observer = (error: BusinessError, response: http.HttpResponse): void => {
        if (error) this.failed(error);
        this.settled();
        completion(error, response);
      };
      if (typeof options === 'function') {
        // Keep the platform overload and its original argument count.
        const request: (url: string, callback: AsyncCallback<http.HttpResponse>) => void = this.original.request;
        request.bind(target)(url, observer);
      } else {
        this.original.request.bind(target)(url, options!, observer);
      }
      return;
    }
    return this.original.request.bind(target)(url, options as http.HttpRequestOptions | undefined).then(response => {
      this.settled();
      return response;
    }, error => {
      this.failed(error);
      this.settled();
      return Promise.reject<http.HttpResponse>(error);
    });
  }

  private observeStream(url: string, callback: AsyncCallback<number>): void;
  private observeStream(url: string, options: http.HttpRequestOptions, callback: AsyncCallback<number>): void;
  private observeStream(url: string, options?: http.HttpRequestOptions): Promise<number>;
  private observeStream(url: string, options?: StreamOptions, callback?: AsyncCallback<number>): void | Promise<number> {
    const target = this.target.deref()!;
    this.started(url, typeof options === 'function' ? undefined : options);
    const completion = typeof options === 'function' ? options : callback;
    if (completion) {
      const observer = (error: BusinessError, status: number): void => {
        if (error) this.failed(error);
        this.settled();
        completion(error, status);
      };
      if (typeof options === 'function') {
        const request: (url: string, callback: AsyncCallback<number>) => void = this.original.requestInStream;
        request.bind(target)(url, observer);
      } else {
        this.original.requestInStream.bind(target)(url, options!, observer);
      }
      return;
    }
    return this.original.requestInStream.bind(target)(url, options as http.HttpRequestOptions | undefined).then(status => {
      this.settled();
      return status;
    }, error => {
      this.failed(error);
      this.settled();
      return Promise.reject<number>(error);
    });
  }

  public dispose(): void {
    const target = this.target.deref();
    if (target?.request === this.requestWrapper) target.request = this.original.request;
    if (target?.requestInStream === this.streamWrapper) target.requestInStream = this.original.requestInStream;
  }
}
