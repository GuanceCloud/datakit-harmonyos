import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import {
  EnvType,
  ErrorMonitorType,
  FTLoggerConfig,
  FTRUMConfig,
  FTRUMGlobalManager,
  FTSDK,
  FTSDKConfig,
  FTSDKExtensionBridge,
  FTTraceConfig,
  TraceType
} from '@guancecloud/ft_sdk/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { FTTraceHandler } from '@guancecloud/ft_sdk/src/main/ets/components/trace/FTTraceHandler';
import { applyFTAxiosChainMethodBridge, applyFTHttpTrack } from '../../../../Index';
import { resolveAxiosFullUrl } from '../../../main/ets/components/network/FTHttpAutoTrackExt';
import { ExtDBAssert } from './helpers/ExtDBAssert';
import { ExtMockCollector, runTestCleanup } from './helpers/ExtMockCollector';
import { WaitUtils } from './helpers/WaitUtils';
import { SdkTestLifecycle } from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/SdkTestLifecycle';
import { RumAttributeAssert, RumAttributeExpectation } from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/RumAttributeAssert';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';

class ChainRequestContext implements http.HttpRequestContext {
  url: string;
  header: Object;
  body: Object;

  constructor(url: string, header: Object) {
    const emptyBody: Record<string, Object> = {};
    this.url = url;
    this.header = header;
    this.body = emptyBody;
  }
}

class ChainPerformanceTiming implements http.PerformanceTiming {
  dnsTiming: number = 0;
  tcpTiming: number = 0;
  tlsTiming: number = 0;
  firstSendTiming: number = 0;
  firstReceiveTiming: number = 0;
  totalFinishTiming: number = 0;
  redirectTiming: number = 0;
  responseHeaderTiming: number = 0;
  responseBodyTiming: number = 0;
  totalTiming: number = 0;
}

class ChainResponse implements http.HttpResponse {
  result: string | Object | ArrayBuffer;
  resultType: http.HttpDataType = http.HttpDataType.STRING;
  responseCode: http.ResponseCode | number;
  header: Object;
  cookies: string = '';
  performanceTiming: http.PerformanceTiming = new ChainPerformanceTiming();

  constructor(
    responseCode: number,
    header: Object,
    result: string,
    performanceTiming: http.PerformanceTiming = new ChainPerformanceTiming()
  ) {
    this.responseCode = responseCode;
    this.header = header;
    this.result = result;
    this.performanceTiming = performanceTiming;
  }
}

interface DeviceAxiosRequestConfigTarget {
  url?: string;
  baseURL?: string;
  method?: string;
  headers?: Object;
  data?: Object | string | ArrayBuffer;
  context?: Object;
}

type DeviceAxiosRequestFulfilled =
  (value: DeviceAxiosRequestConfigTarget) => DeviceAxiosRequestConfigTarget | Promise<DeviceAxiosRequestConfigTarget>;
type DeviceAxiosRejectedHandler = (error: Object) => Object | Promise<Object>;

class DeviceAxiosRequestInterceptorManager {
  private fulfilled?: DeviceAxiosRequestFulfilled;

  public use(onFulfilled?: DeviceAxiosRequestFulfilled, _onRejected?: DeviceAxiosRejectedHandler): number {
    this.fulfilled = onFulfilled;
    return 1;
  }

  public run(config: DeviceAxiosRequestConfigTarget): DeviceAxiosRequestConfigTarget {
    if (!this.fulfilled) {
      return config;
    }
    return this.fulfilled(config) as DeviceAxiosRequestConfigTarget;
  }
}

interface DeviceAxiosInterceptors {
  request: DeviceAxiosRequestInterceptorManager;
}

class DeviceAxiosTarget {
  public readonly requestManager: DeviceAxiosRequestInterceptorManager = new DeviceAxiosRequestInterceptorManager();
  public readonly interceptors: DeviceAxiosInterceptors;

  constructor() {
    this.interceptors = {
      request: this.requestManager
    };
  }
}

function readHeader(headers: Object | undefined | null, key: string): string {
  if (!headers) {
    return '';
  }
  const headerRecord = headers as Record<string, Object>;
  const value = headerRecord[key];
  if (value === undefined || value === null) {
    return '';
  }
  return String(value);
}

function assertTraceparentHeaders(headers: Object | undefined | null): string[] {
  const traceparent = readHeader(headers, FTTraceHandler.W3C_TRACEPARENT_KEY);
  const ddTraceId = readHeader(headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY);
  const ddSpanId = readHeader(headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY);
  const resourceId = readHeader(headers, 'X-FT-Resource-ID');
  const parts = traceparent.split('-');

  expect(parts.length).assertEqual(4);
  expect(parts[0]).assertEqual('00');
  expect(parts[1].length).assertEqual(32);
  expect(parts[2].length).assertEqual(16);
  expect(parts[3]).assertEqual('01');
  expect(ddTraceId.length).assertEqual(0);
  expect(ddSpanId.length).assertEqual(0);
  expect(resourceId.length > 0).assertTrue();

  return [parts[1], parts[2]];
}

function assertNoTraceHeaders(headers: Object | undefined | null): void {
  expect(readHeader(headers, FTTraceHandler.W3C_TRACEPARENT_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY).length).assertEqual(0);
}

async function installExtResourceSdk(): Promise<void> {
  const context = await ExtDBAssert.getAppContext();
  FTSDK.install(FTSDKConfig.builder(TEST_HOST)
    .setDebug(true)
    .setAutoSync(false)
    .setEnv(EnvType.GRAY), context);

  FTSDK.installRUMConfig(new FTRUMConfig()
    .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
    .setRumAppId(TEST_FAKE_RUM_ID)
    .setEnableTraceUserAction(true)
    .setEnableTraceUserView(true)
    .setEnableTraceUserResource(true));

  FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

  FTSDK.installTraceConfig(new FTTraceConfig()
    .setEnableAutoTrace(true)
    .setEnableLinkRUMData(true)
    .setTraceType(TraceType.TRACEPARENT));
}

async function flushAndAssertUploaded(
  collector: ExtMockCollector,
  fragments: string[],
  recordUuid: string
): Promise<string> {
  FTSDK.flushSyncData();

  const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
  const consumed = await ExtDBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, recordUuid, 5000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
  return uploaded;
}

export default function httpChainModeDeviceTest() {
  describe('HttpChainModeDeviceTest', () => {
    let collector: ExtMockCollector;

    beforeEach(async () => {
      await SdkTestLifecycle.resetRuntimeState();
      collector = new ExtMockCollector(200, '');
      collector.start();
      await installExtResourceSdk();
      await ExtDBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      await runTestCleanup([
        async () => { await collector.stop(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await ExtDBAssert.cleanupAll(); }
      ]);
    });

    it('httpChainShouldUploadAndDelete', 0, async () => {
      const viewName = 'http_chain_resource_view';
      const resourceUrl = 'http://device.test/http-chain-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const request = http.createHttp();
      try {
        const chain = applyFTHttpTrack(request, {
          enableTraceInterceptor: true,
          enableResourceInterceptor: true
        });

        const interceptors = chain.getChain();
        expect(interceptors.length).assertEqual(2);
        expect(interceptors[0].interceptorType).assertEqual(http.InterceptorType.INITIAL_REQUEST);
        expect(interceptors[1].interceptorType).assertEqual(http.InterceptorType.FINAL_RESPONSE);

        const requestHeaders: Record<string, Object> = {};
        requestHeaders['Accept'] = 'application/json' as Object;
        const requestContext = new ChainRequestContext(resourceUrl, requestHeaders);
        const emptyResponseHeaders: Record<string, Object> = {};
        await interceptors[0].interceptorHandle(requestContext, new ChainResponse(0, emptyResponseHeaders, ''));
        const traceIds = assertTraceparentHeaders(requestContext.header);
        await WaitUtils.delay(5);

        const responseHeaders: Record<string, Object> = {};
        responseHeaders['content-type'] = 'application/json' as Object;
        responseHeaders['content-length'] = '14' as Object;
        await interceptors[1].interceptorHandle(
          requestContext,
          new ChainResponse(202, responseHeaders, '{"chain":true}')
        );

        const fragments = [
          'resource',
          `resource_url=${resourceUrl}`,
          'resource_status=202',
          `view_name=${viewName}`,
          `trace_id=${traceIds[0]}`,
          `span_id=${traceIds[1]}`
        ];
        const record = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

        if (record === null) {
          throw new Error(
            `Expected stable chain resource record.\nCurrent sync records:\n${await ExtDBAssert.dumpSyncRecords()}`
          );
        }
        await flushAndAssertUploaded(collector, fragments, record.getUuid());
      } finally {
        request.destroy();
      }
    });

    it('httpChainShouldKeepNetworkKitPerformanceTiming', 0, async () => {
      const viewName = 'http_chain_performance_timing_view';
      const resourceUrl = 'https://device.test/http-chain-performance-timing';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const request = http.createHttp();
      try {
        const interceptors = applyFTHttpTrack(request, {
          enableTraceInterceptor: false,
          enableResourceInterceptor: true
        }).getChain();
        const requestHeaders: Record<string, Object> = {};
        const requestContext = new ChainRequestContext(resourceUrl, requestHeaders);
        const emptyResponseHeaders: Record<string, Object> = {};
        await interceptors[0].interceptorHandle(requestContext, new ChainResponse(0, emptyResponseHeaders, ''));

        const performanceTiming = new ChainPerformanceTiming();
        performanceTiming.dnsTiming = 10;
        performanceTiming.tcpTiming = 30;
        performanceTiming.tlsTiming = 80;
        performanceTiming.firstSendTiming = 100;
        performanceTiming.firstReceiveTiming = 150;
        performanceTiming.totalFinishTiming = 180;
        performanceTiming.redirectTiming = 40;
        performanceTiming.responseHeaderTiming = 155;
        performanceTiming.responseBodyTiming = 180;
        performanceTiming.totalTiming = 185;
        const responseHeaders: Record<string, Object> = {};
        responseHeaders['content-type'] = 'application/json' as Object;
        await interceptors[1].interceptorHandle(
          requestContext,
          new ChainResponse(200, responseHeaders, '{"ok":true}', performanceTiming)
        );

        const fragments = [
          'resource,',
          `resource_url=${resourceUrl}`,
          'resource_status=200',
          `view_name=${viewName}`,
          'resource_first_byte_time',
          'resource_download_time'
        ];
        const record = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
        const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID,
          viewName, resourceStatus: 200 };
        const point = RumAttributeAssert.record(record, attributes);
        const firstByteTiming = JSON.parse(String(point.fields.get('resource_first_byte_time'))) as Record<string, number>;
        const downloadTiming = JSON.parse(String(point.fields.get('resource_download_time'))) as Record<string, number>;

        expect(firstByteTiming['start']).assertEqual(100000000);
        expect(firstByteTiming['duration']).assertEqual(50000000);
        expect(downloadTiming['start']).assertEqual(150000000);
        expect(downloadTiming['duration']).assertEqual(30000000);
        expect(point.fields.get('resource_ttfb')).assertEqual(50000000);
        expect(point.fields.get('resource_trans')).assertEqual(100000000);
        expect(point.fields.get('duration')).assertEqual(180000000);

        await flushAndAssertUploaded(collector, fragments, record!.getUuid());
      } finally {
        request.destroy();
      }
    });

    it('traceOnlyShouldSkipResource', 0, async () => {
      const resourceUrl = 'http://device.test/http-chain-trace-only';
      const request = http.createHttp();
      try {
        const chain = applyFTHttpTrack(request, {
          enableTraceInterceptor: true,
          enableResourceInterceptor: false
        });

        const interceptors = chain.getChain();
        expect(interceptors.length).assertEqual(2);

        const requestHeaders: Record<string, Object> = {};
        requestHeaders['Accept'] = 'application/json' as Object;
        const requestContext = new ChainRequestContext(resourceUrl, requestHeaders);
        const emptyResponseHeaders: Record<string, Object> = {};
        await interceptors[0].interceptorHandle(requestContext, new ChainResponse(0, emptyResponseHeaders, ''));
        assertTraceparentHeaders(requestContext.header);

        const responseHeaders: Record<string, Object> = {};
        responseHeaders['content-type'] = 'application/json' as Object;
        await interceptors[1].interceptorHandle(
          requestContext,
          new ChainResponse(204, responseHeaders, '')
        );

        const stayedEmpty = await ExtDBAssert.waitForSyncCount([DataType.RUM_APP], 0, 1500);
        expect(stayedEmpty).assertTrue();
        expect(await ExtDBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
      } finally {
        request.destroy();
      }
    });

    it('resourceOnlyShouldUploadNoTraceIds', 0, async () => {
      const viewName = 'http_chain_resource_only_view';
      const resourceUrl = 'http://device.test/http-chain-resource-only';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const request = http.createHttp();
      try {
        const chain = applyFTHttpTrack(request, {
          enableTraceInterceptor: false,
          enableResourceInterceptor: true
        });

        const interceptors = chain.getChain();
        expect(interceptors.length).assertEqual(2);

        const requestHeaders: Record<string, Object> = {};
        requestHeaders['Accept'] = 'application/json' as Object;
        const requestContext = new ChainRequestContext(resourceUrl, requestHeaders);
        const emptyResponseHeaders: Record<string, Object> = {};
        await interceptors[0].interceptorHandle(requestContext, new ChainResponse(0, emptyResponseHeaders, ''));
        assertNoTraceHeaders(requestContext.header);
        expect(readHeader(requestContext.header, 'X-FT-Resource-ID').length > 0).assertTrue();
        await WaitUtils.delay(5);

        const responseHeaders: Record<string, Object> = {};
        responseHeaders['content-type'] = 'application/json' as Object;
        responseHeaders['content-length'] = '18' as Object;
        await interceptors[1].interceptorHandle(
          requestContext,
          new ChainResponse(201, responseHeaders, '{"resource":true}')
        );

        const fragments = [
          'resource',
          `resource_url=${resourceUrl}`,
          'resource_status=201',
          `view_name=${viewName}`
        ];
        const record = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

        if (record === null) {
          throw new Error(
            `Expected resource-only chain record.\nCurrent sync records:\n${await ExtDBAssert.dumpSyncRecords()}`
          );
        }
        const line = record.getDataString();
        expect(line.includes('trace_id=')).assertFalse();
        expect(line.includes('span_id=')).assertFalse();

        const uploaded = await flushAndAssertUploaded(collector, fragments, record.getUuid());
        expect(uploaded.includes('trace_id=')).assertFalse();
        expect(uploaded.includes('span_id=')).assertFalse();
      } finally {
        request.destroy();
      }
    });

    it('httpErrorStatusWriteUploadAndDelete', 0, async () => {
      const viewName = 'http_chain_error_resource_view';
      const resourceUrl = 'http://device.test/http-chain-error-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const request = http.createHttp();
      try {
        const chain = applyFTHttpTrack(request, {
          enableTraceInterceptor: true,
          enableResourceInterceptor: true
        });

        const interceptors = chain.getChain();
        expect(interceptors.length).assertEqual(2);

        const requestHeaders: Record<string, Object> = {};
        requestHeaders['Accept'] = 'application/json' as Object;
        const requestContext = new ChainRequestContext(resourceUrl, requestHeaders);
        const emptyResponseHeaders: Record<string, Object> = {};
        await interceptors[0].interceptorHandle(requestContext, new ChainResponse(0, emptyResponseHeaders, ''));
        const traceIds = assertTraceparentHeaders(requestContext.header);
        await WaitUtils.delay(5);

        const responseHeaders: Record<string, Object> = {};
        responseHeaders['content-type'] = 'text/plain' as Object;
        responseHeaders['content-length'] = '12' as Object;
        await interceptors[1].interceptorHandle(
          requestContext,
          new ChainResponse(503, responseHeaders, 'server-error')
        );

        const fragments = [
          'resource',
          `resource_url=${resourceUrl}`,
          'resource_status=503',
          'resource_status_group=5xx',
          `view_name=${viewName}`,
          `trace_id=${traceIds[0]}`,
          `span_id=${traceIds[1]}`
        ];
        const record = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

        if (record === null) {
          throw new Error(
            `Expected chain HTTP error resource record.\nCurrent sync records:\n${await ExtDBAssert.dumpSyncRecords()}`
          );
        }
        await flushAndAssertUploaded(collector, fragments, record.getUuid());
      } finally {
        request.destroy();
      }
    });

    it('zeroStatusShouldUploadResourceAndLinkedError', 0, async () => {
      const viewName = 'http_chain_transport_failure_view';
      const resourceUrl = 'http://device.test/connection-refused';
      await FTRUMGlobalManager.getInstance().startView(viewName);
      const request = http.createHttp();
      try {
        const interceptors = applyFTHttpTrack(request).getChain();
        const headers: Record<string, Object> = {};
        const context = new ChainRequestContext(resourceUrl, headers);
        const failedResponse = new ChainResponse(0, headers, '');
        await interceptors[0].interceptorHandle(context, failedResponse);
        const traceIds = assertTraceparentHeaders(context.header);
        expect(await interceptors[1].interceptorHandle(context, failedResponse)).assertTrue();

        const resourceFragments = ['resource,', `resource_url=${resourceUrl}`, `trace_id=${traceIds[0]}`];
        const resource = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments);
        const resourceAttributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID,
          viewName, resourceStatus: 0, requiredTags: ['trace_id', 'span_id'], requiredFields: ['request_header'] };
        const resourcePoint = RumAttributeAssert.record(resource, resourceAttributes);
        expect(resourcePoint.tags.has('resource_status')).assertFalse();
        expect(resourcePoint.tags.get('span_id')).assertEqual(traceIds[1]);

        const errorFragments = ['error,', 'error_source=network', `resource_id=${resource!.getUuid()}`];
        const error = await ExtDBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments);
        const errorAttributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID,
          viewName, requiredFields: ['error_stack'] };
        const errorPoint = RumAttributeAssert.record(error, errorAttributes);
        expect(errorPoint.tags.get('resource_status')).assertEqual('0');
        expect(errorPoint.tags.get('resource_url')).assertEqual(resourceUrl);
        expect(String(errorPoint.fields.get('error_message')).includes(
          'NetworkKit request failed without an HTTP response')).assertTrue();

        const uploadedResource = await flushAndAssertUploaded(collector, resourceFragments, resource!.getUuid());
        const uploadedError = await collector.waitForPayloadContaining(errorFragments, 5000);
        RumAttributeAssert.uploaded(uploadedResource, resource, resourceAttributes);
        RumAttributeAssert.uploaded(uploadedError, error, errorAttributes);
        expect(await ExtDBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, error!.getUuid(), 5000)).assertTrue();
      } finally {
        request.destroy();
      }
    });

    it('resolveAxiosFullUrlJoinBaseUrlOnDevice', 0, async () => {
      expect(resolveAxiosFullUrl('/users', 'https://device.example.com/api'))
        .assertEqual('https://device.example.com/api/users');
      expect(resolveAxiosFullUrl('users', 'https://device.example.com/api/'))
        .assertEqual('https://device.example.com/api/users');
      expect(resolveAxiosFullUrl('https://other.example.com/users', 'https://device.example.com/api'))
        .assertEqual('https://other.example.com/users');
      expect(resolveAxiosFullUrl('', 'https://device.example.com/api'))
        .assertEqual('https://device.example.com/api');
      expect(resolveAxiosFullUrl('/users', ''))
        .assertEqual('/users');
    });

    it('axiosBridgeShouldStoreMethod', 0, async () => {
      const target = new DeviceAxiosTarget();
      const interceptorId = applyFTAxiosChainMethodBridge(target);
      let resourceId = '';

      try {
        expect(interceptorId).assertEqual(1);

        const requestHeaders: Record<string, string> = {};
        requestHeaders['Accept'] = 'application/json';
        const config: DeviceAxiosRequestConfigTarget = {
          url: '/device-users',
          baseURL: 'https://device.example.com/api',
          method: 'post',
          headers: requestHeaders as Object,
          data: '{"bridge":true}'
        };

        const result = target.requestManager.run(config);
        const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);
        resourceId = normalizedHeaders['X-FT-Resource-ID'];

        expect(result.url).assertEqual('/device-users');
        expect(result.baseURL).assertEqual('https://device.example.com/api');
        expect(normalizedHeaders['Accept']).assertEqual('application/json');
        expect(resourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(resourceId)).assertEqual('POST');
      } finally {
        if (resourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceId);
        }
      }
    });
  });
}
