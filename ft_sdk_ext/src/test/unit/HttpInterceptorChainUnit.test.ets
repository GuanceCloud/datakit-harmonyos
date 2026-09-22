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
  HttpInitialRequestInterceptor
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

class ThrowingHeaderValue {
  public toString(): string {
    throw new Error('response header cannot be stringified');
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

    it('createChainShouldAddFTInterceptors', 0, () => {
      const options = new TestHttpInterceptorChainOptions(true, true);
      const chain = createFTHttpInterceptorChain(options);
      const interceptors = chain.getChain();

      expect(interceptors.length).assertEqual(2);
      expect(interceptors[0].interceptorType).assertEqual(http.InterceptorType.INITIAL_REQUEST);
      expect(interceptors[1].interceptorType).assertEqual(http.InterceptorType.FINAL_RESPONSE);
    });

    it('createChainShouldReturnNeutral', 0, () => {
      const options = new TestHttpInterceptorChainOptions(false, false, []);
      const chain = createFTHttpInterceptorChain(options);

      expect(chain !== null).assertTrue();
      expect(chain.getChain().length).assertEqual(0);
    });

    it('createChainShouldIsolateCustomList', 0, () => {
      const reusableInterceptors: http.HttpInterceptor[] = [new CustomInitialInterceptor()];
      const options = new TestHttpInterceptorChainOptions(false, false, reusableInterceptors);

      const firstChain = createFTHttpInterceptorChain(options);
      reusableInterceptors.push(new CustomFinalInterceptor());
      const secondChain = createFTHttpInterceptorChain(options);

      expect(firstChain.getChain().length).assertEqual(1);
      expect(secondChain.getChain().length).assertEqual(2);
    });

    it('initialInterceptorShouldInjectHeaders', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(true, true);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Accept'] = 'application/json' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/resource', requestHeaders);
      const emptyResponseHeaders: Record<string, Object> = {};

      const shouldContinue = await interceptor.interceptorHandle(reqContext, new TestHttpResponse(0, emptyResponseHeaders, ''));
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);

      expect(shouldContinue).assertTrue();
      expect(normalizedHeaders['Accept']).assertEqual('application/json');
      expect(normalizedHeaders['X-FT-Resource-ID'].length > 0).assertTrue();
      expect(normalizedHeaders['x-datadog-trace-id'].length > 0).assertTrue();
      expect(normalizedHeaders['x-datadog-parent-id'].length > 0).assertTrue();

      const cleanupResponse = new TestExtensionResponse(reqContext.url, reqContext.header, emptyResponseHeaders, 204, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('initialInterceptorShouldPreserveHeaders', 0, async () => {
      const interceptor = new HttpInitialRequestInterceptor(true, true);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['X-FT-Resource-ID'] = 'resource-id-existing' as Object;
      requestHeaders['x-datadog-trace-id'] = 'trace-id-existing';
      requestHeaders['x-datadog-parent-id'] = 'parent-id-existing';
      const reqContext = new TestHttpRequestContext('https://example.com/trace', requestHeaders);
      const emptyResponseHeaders: Record<string, Object> = {};

      await interceptor.interceptorHandle(reqContext, new TestHttpResponse(0, emptyResponseHeaders, ''));
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(reqContext.header);

      expect(normalizedHeaders['X-FT-Resource-ID']).assertEqual('resource-id-existing');
      expect(normalizedHeaders['x-datadog-trace-id']).assertEqual('trace-id-existing');
      expect(normalizedHeaders['x-datadog-parent-id']).assertEqual('parent-id-existing');

      const cleanupResponse = new TestExtensionResponse(reqContext.url, reqContext.header, emptyResponseHeaders, 200, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupResponse)).assertTrue();
    });

    it('finalInterceptorShouldClearState', 0, async () => {
      const initial = new HttpInitialRequestInterceptor(true, true);
      const finalResponse = new HttpFinalResponseInterceptor(true, true);
      const requestHeaders: Record<string, Object> = {};
      const reqContext = new TestHttpRequestContext('https://example.com/complete', requestHeaders);
      const responseHeaders: Record<string, Object> = {};
      responseHeaders['content-type'] = 'application/json' as Object;
      responseHeaders['content-length'] = '13' as Object;
      const emptyInitialHeaders: Record<string, Object> = {};

      await initial.interceptorHandle(reqContext, new TestHttpResponse(0, emptyInitialHeaders, ''));
      const shouldContinue = await finalResponse.interceptorHandle(
        reqContext,
        new TestHttpResponse(200, responseHeaders, '{"ok":true}')
      );

      expect(shouldContinue).assertTrue();
      const duplicateResponse = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 200, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(duplicateResponse)).assertFalse();
    });

    it('finalInterceptorShouldKeepKnownStatusWhenResponseHeadersAreInvalid', 0, async () => {
      const initial = new HttpInitialRequestInterceptor(true, true);
      const finalResponse = new HttpFinalResponseInterceptor(true, true);
      const requestHeaders: Record<string, Object> = {};
      const reqContext = new TestHttpRequestContext('https://example.com/not-found', requestHeaders);
      const emptyInitialHeaders: Record<string, Object> = {};
      const invalidResponseHeaders: Record<string, Object> = {};
      invalidResponseHeaders['x-invalid'] = new ThrowingHeaderValue() as Object;

      await initial.interceptorHandle(reqContext, new TestHttpResponse(0, emptyInitialHeaders, ''));
      const shouldContinue = await finalResponse.interceptorHandle(
        reqContext,
        new TestHttpResponse(404, invalidResponseHeaders, 'not-found')
      );

      expect(shouldContinue).assertTrue();
      const duplicateResponse = new TestExtensionResponse(
        reqContext.url,
        reqContext.header,
        invalidResponseHeaders,
        404,
        ''
      );
      expect(FTSDKExtensionBridge.completeHttpResponse(duplicateResponse)).assertFalse();
    });

    it('finalInterceptorShouldHandleMissingState', 0, async () => {
      const finalResponse = new HttpFinalResponseInterceptor(true, true);
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['X-FT-Resource-ID'] = 'missing-resource' as Object;
      const reqContext = new TestHttpRequestContext('https://example.com/missing', requestHeaders);
      const responseHeaders: Record<string, Object> = {};

      const shouldContinue = await finalResponse.interceptorHandle(
        reqContext,
        new TestHttpResponse(500, responseHeaders, 'server-error')
      );

      expect(shouldContinue).assertTrue();
      const duplicateResponse = new TestExtensionResponse(reqContext.url, reqContext.header, responseHeaders, 500, '');
      expect(FTSDKExtensionBridge.completeHttpResponse(duplicateResponse)).assertFalse();
    });

    it('applyChainShouldSurviveFailure', 0, () => {
      const requestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/apply'
      };

      const preparedForFalse = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const falseChain = new FakeApplyChain(false);
      const returnedFalseChain =
        applyFTHttpTrackToChain(falseChain as http.HttpInterceptorChain, preparedForFalse as Object as http.HttpRequest);
      expect((returnedFalseChain as Object) === (falseChain as Object)).assertTrue();
      expect(falseChain.applyCount).assertEqual(1);
      const cleanupFalseHeaders: Record<string, Object> = {};
      const cleanupFalse = new TestExtensionResponse(
        preparedForFalse.url,
        preparedForFalse.headers,
        cleanupFalseHeaders,
        204,
        ''
      );
      cleanupFalse.method = preparedForFalse.method;
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupFalse)).assertTrue();

      const preparedForThrow = FTSDKExtensionBridge.prepareHttpRequest(requestInput);
      const throwingChain = new FakeApplyChain(false, true);
      const returnedThrowingChain =
        applyFTHttpTrackToChain(throwingChain as http.HttpInterceptorChain, preparedForThrow as Object as http.HttpRequest);
      expect((returnedThrowingChain as Object) === (throwingChain as Object)).assertTrue();
      expect(throwingChain.applyCount).assertEqual(1);
      const cleanupThrowHeaders: Record<string, Object> = {};
      const cleanupThrow = new TestExtensionResponse(
        preparedForThrow.url,
        preparedForThrow.headers,
        cleanupThrowHeaders,
        204,
        ''
      );
      cleanupThrow.method = preparedForThrow.method;
      expect(FTSDKExtensionBridge.completeHttpResponse(cleanupThrow)).assertTrue();
    });

    it('completeResponseShouldClearErrorState', 0, () => {
      const fallbackRequestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/fallback-method',
        method: 'delete'
      };
      const request = FTSDKExtensionBridge.prepareHttpRequest(fallbackRequestInput);
      const responseHeaders: Record<string, Object> = {};
      const response = new TestExtensionResponse(request.url, request.headers, responseHeaders, 200, '');
      response.method = undefined;

      expect(FTSDKExtensionBridge.resolveAxiosMethod(request.uniqueId)).assertEqual('DELETE');
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(request.uniqueId)).assertEqual(undefined);

      const errorRequestInput: FTSDKExtensionRequestInput = {
        url: 'https://example.com/error-path',
        method: 'post'
      };
      const errorRequest = FTSDKExtensionBridge.prepareHttpRequest(errorRequestInput);
      const errorHeaders: Record<string, Object> = {};
      const errorResponse = new TestExtensionResponse(errorRequest.url, errorRequest.headers, errorHeaders, 500, '');
      errorResponse.errorMessage = 'timeout';

      expect(FTSDKExtensionBridge.completeHttpError(errorResponse)).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(errorRequest.uniqueId)).assertEqual(undefined);
    });
  });
}
