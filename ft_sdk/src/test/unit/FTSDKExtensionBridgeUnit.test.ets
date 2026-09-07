import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import {
  FTSDKExtensionAutoTrackOptions,
  FTSDKExtensionBridge,
  FTSDKExtensionRequestInput,
  FTSDKExtensionResponseInput
} from '../../main/ets/components/integration/FTSDKExtensionBridge';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceHandler } from '../../main/ets/components/trace/FTTraceHandler';
import {
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceRequestContext
} from '../../main/ets/components/trace/FTTraceHeaderHandler';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { TestReset } from '../helpers/TestReset';

class RecordingTraceHeaderHandler implements FTTraceHeaderHandler {
  public requestCount: number = 0;
  public requestTraceId: string = '';
  public requestSpanId: string = '';
  public requestMethod: string = '';
  public requestContentType: string = '';
  public requestBody: string = '';

  public getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    this.requestCount++;
    this.requestTraceId = traceContext.traceId;
    this.requestSpanId = traceContext.spanId;
    this.requestMethod = request.method;
    this.requestContentType = request.headers['Content-Type'] || '';
    this.requestBody = typeof request.body === 'string' ? request.body : '';
    traceContext.headers['X-Test-Trace-Id'] = traceContext.traceId;
    return traceContext;
  }
}

class FormBodyTraceHeaderHandler implements FTTraceHeaderHandler {
  public requestBody: string = '';

  public getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    this.requestBody = typeof request.body === 'string' ? request.body : '';
    const traceId = this.getFormValue(this.requestBody, 'trace_id');
    const spanId = this.getFormValue(this.requestBody, 'span_id');
    if (traceId.length > 0 && spanId.length > 0) {
      traceContext.traceId = traceId;
      traceContext.spanId = spanId;
      traceContext.headers[FTTraceHandler.W3C_TRACEPARENT_KEY] = `00-${traceId}-${spanId}-01`;
    }
    return traceContext;
  }

  private getFormValue(body: string, key: string): string {
    const pairs = body.split('&');
    for (let i = 0; i < pairs.length; i++) {
      const pair = pairs[i].split('=');
      if (pair.length === 2 && decodeURIComponent(pair[0]) === key) {
        return decodeURIComponent(pair[1]);
      }
    }
    return '';
  }
}

export default function ftSDKExtensionBridgeUnitTest() {
  describe('FTSDKExtensionBridgeUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('axiosPrepareShouldStoreMethod', 0, () => {
      const headers: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/path',
        method: 'post',
        headers: headers
      };
      const preparedRequest = FTSDKExtensionBridge.prepareAxiosChainRequest(request);

      expect(preparedRequest.uniqueId.length > 0).assertTrue();
      expect(preparedRequest.headers['X-FT-Resource-ID']).assertEqual(preparedRequest.uniqueId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(preparedRequest.uniqueId)).assertEqual('POST');

      FTSDKExtensionBridge.clearAxiosMethod(preparedRequest.uniqueId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(preparedRequest.uniqueId) === undefined).assertTrue();
    });

    it('httpPrepareShouldKeepHeadersDisabled', 0, () => {
      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Accept'] = 'application/json' as Object;
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/resource',
        headers: requestHeaders
      };
      const options: FTSDKExtensionAutoTrackOptions = {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      };
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);

      expect(preparedRequest.uniqueId.length > 0).assertTrue();
      expect(preparedRequest.headers['X-FT-Resource-ID']).assertEqual(preparedRequest.uniqueId);
      expect(preparedRequest.traceEnabled).assertFalse();
      expect(preparedRequest.resourceEnabled).assertFalse();

      const responseHeaders: Record<string, Object> = {};
      const response: FTSDKExtensionResponseInput = {
        url: 'http://example.com/resource',
        requestHeaders: preparedRequest.headers,
        responseHeaders: responseHeaders,
        statusCode: 200,
        body: ''
      };
      const completed = FTSDKExtensionBridge.completeHttpResponse(response);
      expect(completed).assertTrue();
    });

    it('httpPrepareShouldPassTraceIds', 0, () => {
      const headerHandler = new RecordingTraceHeaderHandler();
      const traceConfig = new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceHeaderHandler(headerHandler);
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Content-Type'] = 'application/json' as Object;
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/trace',
        method: 'GET',
        headers: requestHeaders,
        body: '{"hello":"world"}'
      };
      const options: FTSDKExtensionAutoTrackOptions = {
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      };
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);

      expect(headerHandler.requestCount).assertEqual(1);
      expect(headerHandler.requestTraceId.length > 0).assertTrue();
      expect(headerHandler.requestSpanId.length > 0).assertTrue();
      expect(headerHandler.requestMethod).assertEqual('GET');
      expect(headerHandler.requestContentType).assertEqual('application/json');
      expect(headerHandler.requestBody).assertEqual('{"hello":"world"}');
      expect(preparedRequest.headers['X-Test-Trace-Id']).assertEqual(headerHandler.requestTraceId);
      expect(preparedRequest.headers['X-FT-Resource-ID']).assertEqual(preparedRequest.uniqueId);

      const responseHeaders: Record<string, Object> = {};
      const response: FTSDKExtensionResponseInput = {
        url: 'http://example.com/trace',
        requestHeaders: preparedRequest.headers,
        responseHeaders: responseHeaders,
        statusCode: 200,
        body: ''
      };
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
    });

    it('httpPrepareAppliesTraceHeaderHandler', 0, () => {
      const headerHandler = new RecordingTraceHeaderHandler();
      const traceConfig = new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceHeaderHandler(headerHandler);
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/custom-trace',
        method: 'GET',
        headers: requestHeaders
      };
      const options: FTSDKExtensionAutoTrackOptions = {
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      };
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);

      expect(preparedRequest.headers['X-Test-Trace-Id']).assertEqual(headerHandler.requestTraceId);
      expect(preparedRequest.headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY]).assertEqual(headerHandler.requestTraceId);
      expect(preparedRequest.headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY]).assertEqual(headerHandler.requestSpanId);
    });

    it('formHandlerOverridesTraceContext', 0, () => {
      const traceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const spanId = 'bbbbbbbbbbbbbbbb';
      const headerHandler = new FormBodyTraceHeaderHandler();
      const traceConfig = new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setTraceType(TraceType.TRACEPARENT)
        .setEnableLinkRUMData(true)
        .setTraceHeaderHandler(headerHandler);
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      const requestHeaders: Record<string, Object> = {};
      requestHeaders['Content-Type'] = 'application/x-www-form-urlencoded' as Object;
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/form-trace',
        method: 'POST',
        headers: requestHeaders,
        body: `name=demo&trace_id=${traceId}&span_id=${spanId}`
      };
      const options: FTSDKExtensionAutoTrackOptions = {
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      };
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);
      const traceContext = FTTraceManager.getInstance().getTraceContext(preparedRequest.resourceId);

      expect(headerHandler.requestBody).assertEqual(`name=demo&trace_id=${traceId}&span_id=${spanId}`);
      expect(preparedRequest.headers[FTTraceHandler.W3C_TRACEPARENT_KEY]).assertEqual(`00-${traceId}-${spanId}-01`);
      expect(traceContext !== null).assertTrue();
      if (traceContext) {
        expect(traceContext.traceId).assertEqual(traceId);
        expect(traceContext.spanId).assertEqual(spanId);
      }
    });

  });
}
