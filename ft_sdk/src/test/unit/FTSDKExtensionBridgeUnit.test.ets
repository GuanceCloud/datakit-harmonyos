import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import {
  FTSDKExtensionAutoTrackOptions,
  FTSDKExtensionBridge,
  FTSDKExtensionRequestInput,
  FTSDKExtensionResponseInput
} from '../../main/ets/components/integration/FTSDKExtensionBridge';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { HeaderHandler, TraceData } from '../../main/ets/components/trace/FTTraceInterceptor';
import { TestReset } from '../helpers/TestReset';

class RecordingTraceHeaderHandler implements HeaderHandler {
  public requestTraceId: string = '';
  public requestSpanId: string = '';

  public processRequestHeaders(headers: Map<string, string>, traceData: TraceData): Map<string, string> {
    this.requestTraceId = traceData.traceId;
    this.requestSpanId = traceData.spanId;
    headers.set('X-Test-Trace-Id', traceData.traceId);
    return headers;
  }

  public processResponseHeaders(headers: Map<string, string>, _traceData: TraceData): Map<string, string> {
    return headers;
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

    it('prepareAxiosChainRequestShouldStoreUppercaseMethod', 0, () => {
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

    it('prepareHttpRequestShouldReturnStableHeadersWhenDisabled', 0, () => {
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

    it('prepareHttpRequestShouldPassTraceIdsToCustomHeaderHandler', 0, () => {
      const headerHandler = new RecordingTraceHeaderHandler();
      const traceConfig = new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setOkHttpTraceHeaderHandler(headerHandler);
      FTTraceConfigManager.getInstance().initWithConfig(traceConfig);

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = {
        url: 'http://example.com/trace',
        method: 'GET',
        headers: requestHeaders
      };
      const options: FTSDKExtensionAutoTrackOptions = {
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      };
      const preparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);

      expect(headerHandler.requestTraceId.length > 0).assertTrue();
      expect(headerHandler.requestSpanId.length > 0).assertTrue();
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

  });
}
