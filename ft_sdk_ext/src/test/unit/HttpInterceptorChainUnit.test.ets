import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import {
  FTSDKExtensionBridge,
  FTSDKExtensionRequestInput,
  FTSDKExtensionResponseInput
} from '@guancecloud/ft_sdk/Index';
import {
  applyFTHttpTrackToChain,
  createFTHttpInterceptorChain,
  HttpFinalResponseInterceptor,
  FTHttpInterceptorChainOptions,
  HttpInitialRequestInterceptor,
  resolveAxiosFullUrl
} from '../../main/ets/components/network/FTHttpAutoTrackExt';
import { TestReset } from '../helpers/TestReset';

class CustomInitialInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  async interceptorHandle(_reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class CustomFinalInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  async interceptorHandle(_reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class FakeApplyChain {
  private readonly result: boolean;
  private readonly shouldThrow: boolean;
  public applyCount: number = 0;

  constructor(result: boolean, shouldThrow: boolean = false) {
    this.result = result;
    this.shouldThrow = shouldThrow;
  }

  addChain(_interceptors: http.HttpInterceptor[]): boolean {
    return true;
  }

  getChain(): http.HttpInterceptor[] {
    return [];
  }

  apply(_request: http.HttpRequest): boolean {
    this.applyCount += 1;
    if (this.shouldThrow) {
      throw new Error('fake apply failure');
    }
    return this.result;
  }
}

class TestHttpInterceptorChainOptions implements FTHttpInterceptorChainOptions {
  public enableTraceInterceptor?: boolean;
  public enableResourceInterceptor?: boolean;
  public interceptors?: http.HttpInterceptor[];

  constructor(traceEnabled: boolean, resourceEnabled: boolean, interceptors?: http.HttpInterceptor[]) {
    this.enableTraceInterceptor = traceEnabled;
    this.enableResourceInterceptor = resourceEnabled;
    this.interceptors = interceptors;
  }
}

class TestPerformanceTiming implements http.PerformanceTiming {
  public dnsTiming: number = 0;
  public tcpTiming: number = 0;
  public tlsTiming: number = 0;
  public firstSendTiming: number = 0;
  public firstReceiveTiming: number = 0;
  public totalFinishTiming: number = 0;
  public redirectTiming: number = 0;
  public responseHeaderTiming: number = 0;
  public responseBodyTiming: number = 0;
  public totalTiming: number = 0;
}

class TestHttpRequestContext implements http.HttpRequestContext {
  public url: string;
  public header: Object;
  public body: Object;

  constructor(url: string, header: Object) {
    const body: Record<string, Object> = {};
    this.url = url;
    this.header = header;
    this.body = body;
  }
}

class TestHttpResponse implements http.HttpResponse {
  public result: string | Object | ArrayBuffer;
  public resultType: http.HttpDataType = http.HttpDataType.STRING;
  public responseCode: http.ResponseCode | number;
  public header: Object;
  public cookies: string = '';
  public performanceTiming: http.PerformanceTiming = new TestPerformanceTiming();

  constructor(responseCode: number, header: Object, result: string) {
    this.responseCode = responseCode;
    this.header = header;
    this.result = result;
  }
}

class TestExtensionResponse implements FTSDKExtensionResponseInput {
  public url: string;
  public requestHeaders?: Object;
  public responseHeaders?: Object;
  public statusCode: number;
  public method?: string;
  public uniqueId?: string;
  public body?: string | Object | ArrayBuffer;
  public errorMessage?: string;
  public errorStack?: string;

  constructor(
    url: string,
    requestHeaders: Object,
    responseHeaders: Object,
    statusCode: number,
    body: string | Object | ArrayBuffer
  ) {
    this.url = url;
    this.requestHeaders = requestHeaders;
    this.responseHeaders = responseHeaders;
    this.statusCode = statusCode;
    this.body = body;
  }
}

export default function httpInterceptorChainUnitTest() {
  describe('HttpInterceptorChainUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('when interceptors created should expose expected interceptor types', 0, () => {
      const initial = new HttpInitialRequestInterceptor(false, false);
      const finalResponse = new HttpFinalResponseInterceptor(false, false);

      expect(initial.interceptorType).assertEqual(http.InterceptorType.INITIAL_REQUEST);
      expect(finalResponse.interceptorType).assertEqual(http.InterceptorType.FINAL_RESPONSE);
    });

    it('when create chain with disabled options and empty interceptor list should return empty neutral chain', 0, () => {
      const options = new TestHttpInterceptorChainOptions(false, false, []);
      const chain = createFTHttpInterceptorChain(options);
      const chainInterceptors = chain.getChain();

      expect(chain !== null).assertTrue();
      expect(chainInterceptors.length).assertEqual(0);
    });

    it('resolveAxiosFullUrlShouldPassThroughAbsoluteUrlAndJoinBaseUrlParameters', 0, () => {
      expect(resolveAxiosFullUrl('https://example.com/full', 'https://base.example')).assertEqual(
        'https://example.com/full'
      );
      expect(resolveAxiosFullUrl('/v1/resource', 'https://base.example/api')).assertEqual(
        'https://base.example/api/v1/resource'
      );
      expect(resolveAxiosFullUrl('v1/resource', 'https://base.example/api/')).assertEqual(
        'https://base.example/api/v1/resource'
      );
      expect(resolveAxiosFullUrl('', 'https://base.example/api')).assertEqual('https://base.example/api');
    });

    it('when create chain called repeatedly should have independent chain content no shared internal append state', 0, () => {
      const reusableInterceptors: http.HttpInterceptor[] = [new CustomInitialInterceptor()];
      const options = new TestHttpInterceptorChainOptions(false, false, reusableInterceptors);

      const firstChain = createFTHttpInterceptorChain(options);
      const firstInterceptors = firstChain.getChain();
      reusableInterceptors.push(new CustomFinalInterceptor());
      const secondChain = createFTHttpInterceptorChain(options);
      const secondInterceptors = secondChain.getChain();

      expect(firstInterceptors.length).assertEqual(1);
      expect(secondInterceptors.length).assertEqual(2);
      expect(reusableInterceptors.length).assertEqual(2);
    });

    it('when custom interceptor list is duplicated across calls should not produce cross-call side effects', 0, () => {
      const duplicatedInterceptors: http.HttpInterceptor[] = [new CustomInitialInterceptor()];
      const options = new TestHttpInterceptorChainOptions(false, false, duplicatedInterceptors);
      const firstChain = createFTHttpInterceptorChain(options);
      const firstInterceptors = firstChain.getChain();

      duplicatedInterceptors[0] = new CustomFinalInterceptor();
      const secondChain = createFTHttpInterceptorChain(options);
      const secondInterceptors = secondChain.getChain();

      expect(firstInterceptors.length).assertEqual(1);
      expect(secondInterceptors.length).assertEqual(1);
      expect(firstInterceptors[0] === duplicatedInterceptors[0]).assertFalse();
      expect(secondInterceptors[0] === duplicatedInterceptors[0]).assertTrue();
      expect(duplicatedInterceptors.length).assertEqual(1);
    });

    it('when request headers already carry trace headers should keep existing values when trace is enabled', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(true, false);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['x-datadog-trace-id'] = 'trace-id-existing';
      requestHeaders['x-datadog-parent-id'] = 'parent-id-existing';
      requestHeaders['traceparent'] = 'existing-traceparent';
      const reqContext = new TestHttpRequestContext('https://example.com/trace', requestHeaders);
      const emptyResponseHeaders: Record<string, Object> = {};
      const rspContext = new TestHttpResponse(0, emptyResponseHeaders, '');

      const shouldContinue = await interceptor.interceptorHandle(reqContext, rspContext);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);

      expect(shouldContinue).assertTrue();
      expect(normalizedHeaders['x-datadog-trace-id']).assertEqual('trace-id-existing');
      expect(normalizedHeaders['x-datadog-parent-id']).assertEqual('parent-id-existing');
      expect(normalizedHeaders['traceparent']).assertEqual('existing-traceparent');
      const cleanupResponse = new TestExtensionResponse(reqContext.url, reqContext.header, emptyResponseHeaders, 200, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('when initial interceptor runs with trace/resource disabled should still inject resource id without trace headers', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(false, false);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Accept'] = 'application/json' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/resource', requestHeaders);
      const emptyResponseHeaders: Record<string, Object> = {};
      const rspContext = new TestHttpResponse(0, emptyResponseHeaders, '');

      const shouldContinue = await interceptor.interceptorHandle(reqContext, rspContext);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);

      expect(shouldContinue).assertTrue();
      expect(normalizedHeaders['Accept']).assertEqual('application/json');
      expect(normalizedHeaders['X-FT-Resource-ID'].length > 0).assertTrue();
      expect(normalizedHeaders['x-datadog-trace-id'] === undefined).assertTrue();
      expect(normalizedHeaders['traceparent'] === undefined).assertTrue();
      const responseHeaders: Record<string, Object> = {};
      const response = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 204, '');
      response.method = 'UNKNOWN';
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
    });

    it('when initial interceptor receives mixed header values should preserve pass-through headers and inject resource id', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(false, true);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Accept'] = 'application/json' as Object;
      requestHeaders['X-Request-Attempt'] = 2 as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/header-pass-through', requestHeaders);
      const responseHeaders: Record<string, Object> = {};
      const rspContext = new TestHttpResponse(0, responseHeaders, '');

      const shouldContinue = await interceptor.interceptorHandle(reqContext, rspContext);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);

      expect(shouldContinue).assertTrue();
      expect(normalizedHeaders['Accept']).assertEqual('application/json');
      expect(normalizedHeaders['X-Request-Attempt']).assertEqual('2');
      expect(normalizedHeaders['X-FT-Resource-ID'].length > 0).assertTrue();
      const response = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 200, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
    });

    it('when initial interceptor receives existing resource id should preserve header and complete lifecycle', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(false, true);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['X-FT-Resource-ID'] = 'resource-id-existing' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/resource-id-existing', requestHeaders);
      const responseHeaders: Record<string, Object> = {};
      const rspContext = new TestHttpResponse(0, responseHeaders, '');

      await interceptor.interceptorHandle(reqContext, rspContext);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);
      const response = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 200, '');

      expect(normalizedHeaders['X-FT-Resource-ID']).assertEqual('resource-id-existing');
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertFalse();
    });

    it('when final interceptor handles prepared response should complete and clear state', 0, async () => {
      const initial = new HttpInitialRequestInterceptor(false, false);
      const finalResponse = new HttpFinalResponseInterceptor(false, false);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Accept'] = 'application/json' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/complete', requestHeaders);
      const responseHeaders: Record<string, Object> = {};
      responseHeaders['content-type'] = 'application/json' as Object;
      responseHeaders['content-length'] = '13' as Object;
      const rspContext = new TestHttpResponse(200, responseHeaders, '{"ok":true}');

      const initialResponseHeaders: Record<string, Object> = {};
      await initial.interceptorHandle(reqContext, new TestHttpResponse(0, initialResponseHeaders, ''));
      const shouldContinue = await finalResponse.interceptorHandle(reqContext, rspContext);
      const response = new TestExtensionResponse(reqContext.url, reqContext.header, rspContext.header, 200, rspContext.result);

      expect(shouldContinue).assertTrue();
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertFalse();
    });

    it('when final interceptor receives missing initial state should return false and stay safe', 0, async () => {
      const finalResponse = new HttpFinalResponseInterceptor(false, false);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['X-FT-Resource-ID'] = 'missing-resource' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/missing', requestHeaders);
      const responseHeaders: Record<string, Object> = {};
      const rspContext = new TestHttpResponse(500, responseHeaders, 'server-error');

      const shouldContinue = await finalResponse.interceptorHandle(reqContext, rspContext);

      expect(shouldContinue).assertTrue();
      const response = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 500, rspContext.result);
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertFalse();
    });

    it('when custom interceptor order is provided should preserve order in chain', 0, () => {
      const initial = new CustomInitialInterceptor();
      const finalResponse = new CustomFinalInterceptor();
      const interceptors: http.HttpInterceptor[] = [];
      interceptors.push(initial);
      interceptors.push(finalResponse);

      const options = new TestHttpInterceptorChainOptions(false, false, interceptors);
      const chain = createFTHttpInterceptorChain(options);
      const actualInterceptors = chain.getChain();

      expect(actualInterceptors.length).assertEqual(2);
      expect(actualInterceptors[0] === initial).assertTrue();
      expect(actualInterceptors[1] === finalResponse).assertTrue();
    });

    it('when chain.apply returns false should keep original chain and continue', 0, () => {
      const fakeChain = new FakeApplyChain(false);
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/apply-false'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const chain = applyFTHttpTrackToChain(fakeChain as http.HttpInterceptorChain, request as Object as http.HttpRequest);

      expect((chain as Object) === (fakeChain as Object)).assertTrue();
      expect(fakeChain.applyCount).assertEqual(1);
      const responseHeaders: Record<string, Object> = {};
      const cleanupResponse = new TestExtensionResponse(request.url, request.headers, responseHeaders, 204, '');
      cleanupResponse.method = request.method;
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('when chain.apply throws should keep original chain and continue', 0, () => {
      const fakeChain = new FakeApplyChain(false, true);
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/apply-throw'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const chain = applyFTHttpTrackToChain(fakeChain as http.HttpInterceptorChain, request as Object as http.HttpRequest);

      expect((chain as Object) === (fakeChain as Object)).assertTrue();
      expect(fakeChain.applyCount).assertEqual(1);
      const responseHeaders: Record<string, Object> = {};
      const cleanupResponse = new TestExtensionResponse(request.url, request.headers, responseHeaders, 204, '');
      cleanupResponse.method = request.method;
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('when completeHttpResponse missing state should return false and clear transient method mapping', 0, () => {
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/complete-state'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const uniqueId = request.uniqueId;
      const emptyResponseHeaders: Record<string, Object> = {};
      const response = new TestExtensionResponse(
        'https://example.com/missing-state',
        request.headers,
        emptyResponseHeaders,
        200,
        ''
      );
      const result = FTSDKExtensionBridge.completeHttpResponse(response);

      expect(result).assertFalse();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(uniqueId)).assertEqual(undefined);
      const cleanupResponse = new TestExtensionResponse(
        request.url,
        request.headers,
        emptyResponseHeaders,
        204,
        ''
      );
      cleanupResponse.method = request.method;
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('when completeHttpResponse method is missing should fallback to stored method', 0, () => {
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/fallback-method',
        method: 'delete'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const uniqueId = request.uniqueId;
      const emptyResponseHeaders: Record<string, Object> = {};
      const response = new TestExtensionResponse(
        'https://example.com/fallback-method',
        request.headers,
        emptyResponseHeaders,
        200,
        ''
      );
      response.method = undefined;

      expect(FTSDKExtensionBridge.resolveAxiosMethod(uniqueId)).assertEqual('DELETE');
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(uniqueId)).assertEqual(undefined);
    });

    it('when completeHttpResponse receives missing method/body should clear lifecycle artifacts on error path', 0, () => {
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/error-path',
        method: 'post'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const uniqueId = request.uniqueId;
      const emptyResponseHeaders: Record<string, Object> = {};
      const errorResponse: FTSDKExtensionResponseInput = new TestExtensionResponse(
        'https://example.com/error-path',
        request.headers,
        emptyResponseHeaders,
        500,
        ''
      );
      errorResponse.errorMessage = 'timeout';

      expect(FTSDKExtensionBridge.completeHttpError(errorResponse)).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(uniqueId)).assertEqual(undefined);
    });
  });
}
