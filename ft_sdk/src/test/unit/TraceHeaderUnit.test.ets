import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import { DefaultFTTraceInterceptor, HeaderHandler, TraceData } from '../../main/ets/components/trace/FTTraceInterceptor';
import { FTTraceHeaderHandler } from '../../main/ets/components/trace/FTTraceConfig';
import { FTTraceHandler } from '../../main/ets/components/trace/FTTraceHandler';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { TestReset } from '../helpers/TestReset';

const TEST_URL = 'https://example.com/path';

function buildHeaders(traceType: TraceType, samplingRate: number = 1): Record<string, string> {
  const config = new FTTraceConfig()
    .setTraceType(traceType)
    .setSamplingRate(samplingRate);
  FTTraceConfigManager.getInstance().initWithConfig(config);
  return FTTraceManager.getInstance().getTraceHeaderDirect(TEST_URL);
}

function isLowerHex(value: string, length: number): boolean {
  return new RegExp(`^[0-9a-f]{${length}}$`).test(value);
}

function isDecimal(value: string): boolean {
  return /^[0-9]+$/.test(value);
}

function interceptTraceHeadersWithExisting(type: TraceType, existing: Record<string, string>): Map<string, string> {
  const config = new FTTraceConfig().setTraceType(type);
  FTTraceConfigManager.getInstance().initWithConfig(config);
  const interceptor = new DefaultFTTraceInterceptor(type);
  const headers = new Map<string, string>();
  const keys = Object.keys(existing);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headers.set(key, existing[key]);
  }

  const intercepted = interceptor.interceptRequest({
    url: TEST_URL,
    method: 'GET',
    headers,
    timestamp: 1000,
    traceId: 'existing-trace',
    spanId: 'existing-span'
  });

  return intercepted.headers;
}

class FakeTraceHeaderHandler implements FTTraceHeaderHandler {
  private traceId: string;
  private spanId: string;

  constructor(traceId: string, spanId: string) {
    this.traceId = traceId;
    this.spanId = spanId;
  }

  getTraceHeader(_url: string): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['x-test-trace-id'] = this.traceId;
    return headers;
  }

  getTraceID(): string {
    return this.traceId;
  }

  getSpanID(): string {
    return this.spanId;
  }
}

class CustomHeaderHandler implements HeaderHandler {
  processRequestHeaders(headers: Map<string, string>, traceData: TraceData): Map<string, string> {
    headers.set('x-custom-operation', traceData.operationName);
    headers.set('x-custom-trace-id', traceData.traceId);
    return headers;
  }

  processResponseHeaders(headers: Map<string, string>, traceData: TraceData): Map<string, string> {
    headers.set('x-custom-response-trace-id', traceData.traceId);
    return headers;
  }
}

export default function traceHeaderUnitTest() {
  describe('TraceHeaderUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('ddTraceShouldUseNumericIdsAndSamplingPriority', 0, () => {
      const headers = buildHeaders(TraceType.DDTRACE);

      expect(isDecimal(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY])).assertTrue();
      expect(isDecimal(headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY])).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_ORIGIN_KEY]).assertEqual('rum');
      expect(headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY]).assertEqual('2');
    });

    it('zipkinMultiShouldUseB3Headers', 0, () => {
      const headers = buildHeaders(TraceType.ZIPKIN_MULTI_HEADER);

      expect(isLowerHex(headers[FTTraceHandler.ZIPKIN_TRACE_ID], 32)).assertTrue();
      expect(isLowerHex(headers[FTTraceHandler.ZIPKIN_SPAN_ID], 16)).assertTrue();
      expect(headers[FTTraceHandler.ZIPKIN_SAMPLED]).assertEqual('1');
      expect(headers[FTTraceHandler.ZIPKIN_B3_HEADER] === undefined).assertTrue();
    });

    it('zipkinSingleShouldOnlyUseB3Header', 0, () => {
      const headers = buildHeaders(TraceType.ZIPKIN_SINGLE_HEADER);
      const b3 = headers[FTTraceHandler.ZIPKIN_B3_HEADER];

      expect(/^[0-9a-f]{32}-[0-9a-f]{16}-1$/.test(b3)).assertTrue();
      expect(headers[FTTraceHandler.ZIPKIN_TRACE_ID] === undefined).assertTrue();
      expect(headers[FTTraceHandler.ZIPKIN_SPAN_ID] === undefined).assertTrue();
      expect(headers[FTTraceHandler.ZIPKIN_SAMPLED] === undefined).assertTrue();
    });

    it('jaegerShouldUseUberTraceIdHeader', 0, () => {
      const headers = buildHeaders(TraceType.JAEGER);

      expect(/^[0-9a-f]{32}:[0-9a-f]{16}:0:1$/.test(headers[FTTraceHandler.JAEGER_KEY])).assertTrue();
    });

    it('traceParentShouldUseW3CHeader', 0, () => {
      const headers = buildHeaders(TraceType.TRACEPARENT);

      expect(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/.test(headers[FTTraceHandler.W3C_TRACEPARENT_KEY])).assertTrue();
    });

    it('skyWalkingShouldUseSw8Header', 0, () => {
      const headers = buildHeaders(TraceType.SKYWALKING);
      const sw8 = headers[FTTraceHandler.SKYWALKING_V3_SW_8];

      expect(sw8.startsWith('1-')).assertTrue();
      expect(sw8.includes(`-${Constants.DEFAULT_SERVICE_NAME}-`)).assertTrue();
      expect(sw8.includes('-http-request-')).assertTrue();
    });

    it('when trace headers already exist for each TraceType should keep existing trace_id/parent_id and not duplicate', 0, () => {
      const ddExisting: Record<string, string> = {};
      ddExisting[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = 'trace-visible-1';
      ddExisting[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = 'parent\u200B-1';
      ddExisting[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = '99';
      const ddHeaders = interceptTraceHeadersWithExisting(TraceType.DDTRACE, ddExisting);
      expect(ddHeaders.get(FTTraceHandler.DD_TRACE_TRACE_ID_KEY)).assertEqual('trace-visible-1');
      expect(ddHeaders.get(FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY)).assertEqual('parent\u200B-1');

      const zipkinExisting: Record<string, string> = {};
      zipkinExisting[FTTraceHandler.ZIPKIN_TRACE_ID] = 'trace-visible-2';
      zipkinExisting[FTTraceHandler.ZIPKIN_SPAN_ID] = 'span-visible-2';
      zipkinExisting[FTTraceHandler.ZIPKIN_SAMPLED] = '0';
      const zipkinHeaders = interceptTraceHeadersWithExisting(TraceType.ZIPKIN_MULTI_HEADER, zipkinExisting);
      expect(zipkinHeaders.get(FTTraceHandler.ZIPKIN_TRACE_ID)).assertEqual('trace-visible-2');
      expect(zipkinHeaders.get(FTTraceHandler.ZIPKIN_SPAN_ID)).assertEqual('span-visible-2');

      const zipkinSingleExisting: Record<string, string> = {};
      zipkinSingleExisting[FTTraceHandler.ZIPKIN_B3_HEADER] = 'trace-visible-3-span-visible-3-0';
      const zipkinSingleHeaders = interceptTraceHeadersWithExisting(TraceType.ZIPKIN_SINGLE_HEADER, zipkinSingleExisting);
      expect(zipkinSingleHeaders.get(FTTraceHandler.ZIPKIN_B3_HEADER)).assertEqual('trace-visible-3-span-visible-3-0');

      const traceparentExisting: Record<string, string> = {};
      traceparentExisting[FTTraceHandler.W3C_TRACEPARENT_KEY] = '00-trace-visible-4-span-visible-4-00';
      const traceparentHeaders = interceptTraceHeadersWithExisting(TraceType.TRACEPARENT, traceparentExisting);
      expect(traceparentHeaders.get(FTTraceHandler.W3C_TRACEPARENT_KEY)).assertEqual('00-trace-visible-4-span-visible-4-00');

      const jaegerExisting: Record<string, string> = {};
      jaegerExisting[FTTraceHandler.JAEGER_KEY] = 'trace-visible-5:span-visible-5:0:0';
      const jaegerHeaders = interceptTraceHeadersWithExisting(TraceType.JAEGER, jaegerExisting);
      expect(jaegerHeaders.get(FTTraceHandler.JAEGER_KEY)).assertEqual('trace-visible-5:span-visible-5:0:0');

      const skyWalkingExisting: Record<string, string> = {};
      skyWalkingExisting[FTTraceHandler.SKYWALKING_V3_SW_8] = '1-visible-sky';
      const skyWalkingHeaders = interceptTraceHeadersWithExisting(TraceType.SKYWALKING, skyWalkingExisting);
      expect(skyWalkingHeaders.get(FTTraceHandler.SKYWALKING_V3_SW_8)).assertEqual('1-visible-sky');
    });

    it('when sampling=0 and sampling=1 should keep header format exact for each type', 0, () => {
      const zipkinMulti0 = buildHeaders(TraceType.ZIPKIN_MULTI_HEADER, 0);
      expect(zipkinMulti0[FTTraceHandler.ZIPKIN_TRACE_ID]).assertEqual(zipkinMulti0[FTTraceHandler.ZIPKIN_TRACE_ID]);
      expect(zipkinMulti0[FTTraceHandler.ZIPKIN_SAMPLED]).assertEqual('0');

      const zipkinMulti1 = buildHeaders(TraceType.ZIPKIN_MULTI_HEADER, 1);
      expect(zipkinMulti1[FTTraceHandler.ZIPKIN_SAMPLED]).assertEqual('1');

      const zipkinSingle0 = buildHeaders(TraceType.ZIPKIN_SINGLE_HEADER, 0);
      const zipkinSingle1 = buildHeaders(TraceType.ZIPKIN_SINGLE_HEADER, 1);
      expect(/^[0-9a-f]{32}-[0-9a-f]{16}-0$/.test(zipkinSingle0[FTTraceHandler.ZIPKIN_B3_HEADER])).assertTrue();
      expect(/^[0-9a-f]{32}-[0-9a-f]{16}-1$/.test(zipkinSingle1[FTTraceHandler.ZIPKIN_B3_HEADER])).assertTrue();

      const jaeger0 = buildHeaders(TraceType.JAEGER, 0);
      const jaeger1 = buildHeaders(TraceType.JAEGER, 1);
      expect(/^[0-9a-f]{32}:[0-9a-f]{16}:0:0$/.test(jaeger0[FTTraceHandler.JAEGER_KEY])).assertTrue();
      expect(/^[0-9a-f]{32}:[0-9a-f]{16}:0:1$/.test(jaeger1[FTTraceHandler.JAEGER_KEY])).assertTrue();

      const traceparent0 = buildHeaders(TraceType.TRACEPARENT, 0);
      const traceparent1 = buildHeaders(TraceType.TRACEPARENT, 1);
      expect(/^00-[0-9a-f]{32}-[0-9a-f]{16}-00$/.test(traceparent0[FTTraceHandler.W3C_TRACEPARENT_KEY])).assertTrue();
      expect(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/.test(traceparent1[FTTraceHandler.W3C_TRACEPARENT_KEY])).assertTrue();
    });

    it('samplingRateZeroShouldStillEmitUnsampledHeaders', 0, () => {
      const headers = buildHeaders(TraceType.DDTRACE, 0);

      expect(isDecimal(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY])).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY]).assertEqual('-1');
    });

    it('samplingRateZeroShouldEmitUnsampledHeadersForAllSupportedTypes', 0, () => {
      const zipkinMulti = buildHeaders(TraceType.ZIPKIN_MULTI_HEADER, 0);
      expect(zipkinMulti[FTTraceHandler.ZIPKIN_SAMPLED]).assertEqual('0');

      const zipkinSingle = buildHeaders(TraceType.ZIPKIN_SINGLE_HEADER, 0);
      expect(/^[0-9a-f]{32}-[0-9a-f]{16}-0$/.test(zipkinSingle[FTTraceHandler.ZIPKIN_B3_HEADER])).assertTrue();

      const jaeger = buildHeaders(TraceType.JAEGER, 0);
      expect(/^[0-9a-f]{32}:[0-9a-f]{16}:0:0$/.test(jaeger[FTTraceHandler.JAEGER_KEY])).assertTrue();

      const traceParent = buildHeaders(TraceType.TRACEPARENT, 0);
      expect(/^00-[0-9a-f]{32}-[0-9a-f]{16}-00$/.test(traceParent[FTTraceHandler.W3C_TRACEPARENT_KEY])).assertTrue();

      const skyWalking = buildHeaders(TraceType.SKYWALKING, 0);
      expect(skyWalking[FTTraceHandler.SKYWALKING_V3_SW_8].startsWith('1-')).assertTrue();
    });

    it('traceManagerShouldEvictOldestHandlerWhenOverLimit', 0, () => {
      const manager = FTTraceManager.getInstance();

      for (let i = 0; i < 1001; i++) {
        manager.putTraceHandler(`resource-${i}`, new FakeTraceHeaderHandler(`trace-${i}`, `span-${i}`));
      }

      expect(manager.getHandlerCount()).assertEqual(1000);
      expect(manager.hasHandler('resource-0')).assertFalse();
      expect(manager.hasHandler('resource-1000')).assertTrue();
    });

    it('customHeaderHandlerShouldProcessRequestAndResponseHeaders', 0, () => {
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig().setTraceType(TraceType.DDTRACE));
      const interceptor = new DefaultFTTraceInterceptor(TraceType.DDTRACE, new CustomHeaderHandler());
      const requestHeaders: Map<string, string> = new Map();
      requestHeaders.set('Accept', 'application/json');

      const request = interceptor.interceptRequest({
        url: TEST_URL,
        method: 'GET',
        headers: requestHeaders,
        timestamp: 1000
      });

      expect(request.headers.get('Accept')).assertEqual('application/json');
      expect(request.headers.get('x-custom-operation')).assertEqual('GET /path');
      expect(request.headers.get('x-custom-trace-id')!.length > 0).assertTrue();

      const response = interceptor.interceptResponse({
        url: TEST_URL,
        statusCode: 200,
        headers: new Map(),
        timestamp: 2000,
        traceId: request.traceId,
        spanId: request.spanId,
        duration: 100
      });

      expect(response.headers.get('x-custom-response-trace-id')).assertEqual(request.traceId);
    });

  });
}
