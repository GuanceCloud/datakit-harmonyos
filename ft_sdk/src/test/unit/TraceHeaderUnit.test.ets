import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import { DefaultFTTraceInterceptor } from '../../main/ets/components/trace/FTTraceInterceptor';
import {
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceRequestContext
} from '../../main/ets/components/trace/FTTraceHeaderHandler';
import { FTTraceHandler } from '../../main/ets/components/trace/FTTraceHandler';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType, TraceTypeUtils } from '../../main/ets/components/trace/TraceType';
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
  public callCount: number = 0;

  constructor(traceId: string, spanId: string) {
    this.traceId = traceId;
    this.spanId = spanId;
  }

  getTraceContext(_request: FTTraceRequestContext): FTTraceContext {
    this.callCount++;
    const headers: Record<string, string> = {};
    headers['x-test-trace-id'] = this.traceId;
    return {
      headers: headers,
      traceId: this.traceId,
      spanId: this.spanId
    };
  }
}

class CustomHeaderHandler implements FTTraceHeaderHandler {
  getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    traceContext.headers['x-custom-trace-id'] = traceContext.traceId;
    return traceContext;
  }
}

class OverrideW3CHeaderHandler implements FTTraceHeaderHandler {
  getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    traceContext.headers[FTTraceHandler.W3C_TRACEPARENT_KEY] =
      '00-11111111111111111111111111111111-2222222222222222-01';
    return traceContext;
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

    it('traceTypesShouldMapAndClassify', 0, () => {
      expect(TraceTypeUtils.toString(TraceType.DDTRACE)).assertEqual('ddtrace');
      expect(TraceTypeUtils.toString(TraceType.ZIPKIN_MULTI_HEADER)).assertEqual('zipkin');
      expect(TraceTypeUtils.toString(TraceType.ZIPKIN_SINGLE_HEADER)).assertEqual('zipkin');
      expect(TraceTypeUtils.toString(TraceType.TRACEPARENT)).assertEqual('traceparent');
      expect(TraceTypeUtils.toString(TraceType.SKYWALKING)).assertEqual('skywalking');
      expect(TraceTypeUtils.toString(TraceType.JAEGER)).assertEqual('jaeger');

      expect(TraceTypeUtils.value(TraceType.ZIPKIN_MULTI_HEADER)).assertEqual('zipkin_multi_header');
      expect(TraceTypeUtils.value(TraceType.ZIPKIN_SINGLE_HEADER)).assertEqual('zipkin_single_header');
      expect(TraceTypeUtils.value(TraceType.TRACEPARENT)).assertEqual('traceparent');

      expect(TraceTypeUtils.isZipkin(TraceType.ZIPKIN_MULTI_HEADER)).assertTrue();
      expect(TraceTypeUtils.isZipkin(TraceType.ZIPKIN_SINGLE_HEADER)).assertTrue();
      expect(TraceTypeUtils.isZipkin(TraceType.DDTRACE)).assertFalse();
      expect(TraceTypeUtils.isDataDog(TraceType.DDTRACE)).assertTrue();
      expect(TraceTypeUtils.isDataDog(TraceType.JAEGER)).assertFalse();
      expect(TraceTypeUtils.isW3C(TraceType.TRACEPARENT)).assertTrue();
      expect(TraceTypeUtils.isW3C(TraceType.DDTRACE)).assertFalse();
      expect(TraceTypeUtils.isSkyWalking(TraceType.SKYWALKING)).assertTrue();
      expect(TraceTypeUtils.isSkyWalking(TraceType.TRACEPARENT)).assertFalse();
      expect(TraceTypeUtils.isJaeger(TraceType.JAEGER)).assertTrue();
      expect(TraceTypeUtils.isJaeger(TraceType.SKYWALKING)).assertFalse();
    });

    it('existingTraceHeadersShouldBeKept', 0, () => {
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

    it('samplingShouldKeepHeaderFormat', 0, () => {
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

    it('samplingZeroShouldEmitUnsampled', 0, () => {
      const headers = buildHeaders(TraceType.DDTRACE, 0);

      expect(isDecimal(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY])).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY]).assertEqual('-1');
    });

    it('samplingZeroShouldCoverAllTypes', 0, () => {
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

    it('traceManagerShouldEvictOldest', 0, () => {
      const manager = FTTraceManager.getInstance();

      for (let i = 0; i < 1001; i++) {
        manager.putTraceHandler(`resource-${i}`, new FakeTraceHeaderHandler(`trace-${i}`, `span-${i}`));
      }

      expect(manager.getHandlerCount()).assertEqual(1000);
      expect(manager.hasHandler('resource-0')).assertFalse();
      expect(manager.hasHandler('resource-1000')).assertTrue();
    });

    it('directTraceContextShouldBypassConfiguredHeaderHandler', 0, () => {
      const traceHeaderHandler = new FakeTraceHeaderHandler('custom-trace', 'custom-span');
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig()
        .setTraceType(TraceType.DDTRACE)
        .setTraceHeaderHandler(traceHeaderHandler));

      const traceContext = FTTraceManager.getInstance().getTraceContextDirect(TEST_URL);
      const headers = FTTraceManager.getInstance().getTraceHeaderDirect(TEST_URL);

      expect(traceHeaderHandler.callCount).assertEqual(0);
      expect(traceContext.headers['x-test-trace-id'] === undefined).assertTrue();
      expect(headers['x-test-trace-id'] === undefined).assertTrue();
      expect(traceContext.traceId.length > 0).assertTrue();
      expect(traceContext.spanId.length > 0).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY].length > 0).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY].length > 0).assertTrue();
    });

    it('traceHeaderHandlerShouldProcessDefaultHeaders', 0, () => {
      const traceHeaderHandler = new CustomHeaderHandler();
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig()
        .setTraceType(TraceType.DDTRACE)
        .setTraceHeaderHandler(traceHeaderHandler));

      const headers = FTTraceManager.getInstance().getTraceHeader('custom-resource', TEST_URL);
      const traceContext = FTTraceManager.getInstance().getTraceContext('custom-resource');

      expect(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY].length > 0).assertTrue();
      expect(headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY].length > 0).assertTrue();
      expect(headers['x-custom-trace-id']).assertEqual(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY]);
      expect(traceContext !== null).assertTrue();
      expect(traceContext!.headers['x-custom-trace-id']).assertEqual(traceContext!.traceId);
      expect(traceContext!.traceId).assertEqual(headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY]);
      expect(traceContext!.spanId).assertEqual(headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY]);
    });

    it('traceHeaderHandlerShouldUpdateContextFromProcessedHeaders', 0, () => {
      const traceHeaderHandler = new OverrideW3CHeaderHandler();
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig()
        .setTraceType(TraceType.TRACEPARENT)
        .setTraceHeaderHandler(traceHeaderHandler));

      const interceptor = new DefaultFTTraceInterceptor(
        TraceType.TRACEPARENT,
        FTTraceConfigManager.getInstance().getTraceHeaderHandler()
      );
      const request = interceptor.interceptRequest({
        url: TEST_URL,
        method: 'GET',
        headers: new Map<string, string>(),
        timestamp: 1000
      });

      expect(request.headers.get(FTTraceHandler.W3C_TRACEPARENT_KEY)).assertEqual('00-11111111111111111111111111111111-2222222222222222-01');
      expect(request.traceId).assertEqual('11111111111111111111111111111111');
      expect(request.spanId).assertEqual('2222222222222222');
    });

    it('customHandlerShouldProcessHeaders', 0, () => {
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

      expect(response.headers.get('x-custom-response-trace-id') === undefined).assertTrue();
    });

  });
}
