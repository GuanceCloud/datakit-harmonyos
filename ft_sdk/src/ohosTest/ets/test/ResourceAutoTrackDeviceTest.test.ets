import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig, FTTraceConfig, FTLoggerConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import {
  FTSDKExtensionAutoTrackOptions,
  FTSDKExtensionBridge,
  FTSDKExtensionPreparedRequest,
  FTSDKExtensionRequestInput,
  FTSDKExtensionResponseInput
} from '../../../main/ets/components/integration/FTSDKExtensionBridge';
import {
  applyFTAxiosTrack,
  FTAxiosRequestConfigTarget,
  FTAxiosResponseTarget
} from '../../../main/ets/components/network/FTHttpAutoTrack';
import { FTTraceHandler } from '../../../main/ets/components/trace/FTTraceHandler';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';

class EmptyObject {
}

type AxiosRequestFulfilled =
  (value: FTAxiosRequestConfigTarget) => FTAxiosRequestConfigTarget | Promise<FTAxiosRequestConfigTarget>;
type AxiosResponseFulfilled =
  (value: FTAxiosResponseTarget) => FTAxiosResponseTarget | Promise<FTAxiosResponseTarget>;
type AxiosRejected = (error: Object) => Object | Promise<Object>;

class FakeAxiosRequestInterceptorManager {
  fulfilled: AxiosRequestFulfilled | null = null;

  use(onFulfilled?: AxiosRequestFulfilled, _onRejected?: AxiosRejected): number {
    this.fulfilled = onFulfilled || null;
    return 1;
  }
}

class FakeAxiosResponseInterceptorManager {
  fulfilled: AxiosResponseFulfilled | null = null;
  rejected: AxiosRejected | null = null;

  use(onFulfilled?: AxiosResponseFulfilled, onRejected?: AxiosRejected): number {
    this.fulfilled = onFulfilled || null;
    this.rejected = onRejected || null;
    return 2;
  }
}

interface FakeAxiosInterceptors {
  request: FakeAxiosRequestInterceptorManager;
  response: FakeAxiosResponseInterceptorManager;
}

class FakeAxiosTarget {
  requestManager: FakeAxiosRequestInterceptorManager = new FakeAxiosRequestInterceptorManager();
  responseManager: FakeAxiosResponseInterceptorManager = new FakeAxiosResponseInterceptorManager();
  interceptors: FakeAxiosInterceptors = {
    request: this.requestManager,
    response: this.responseManager
  };
}

class FakeAxiosRequestConfig implements FTAxiosRequestConfigTarget {
  url?: string;
  method?: string;
  headers?: Object;
  context?: Object;

  constructor(url: string, method: string) {
    const headers: Record<string, Object> = {};
    headers['Accept'] = 'application/json' as Object;
    this.url = url;
    this.method = method;
    this.headers = headers;
    this.context = new EmptyObject();
  }
}

class FakeAxiosResponse implements FTAxiosResponseTarget<string> {
  config: FTAxiosRequestConfigTarget;
  status: number;
  headers?: Object;
  data?: string;

  constructor(config: FTAxiosRequestConfigTarget, status: number, body: string) {
    const headers: Record<string, Object> = {};
    headers['content-type'] = 'text/plain' as Object;
    headers['content-length'] = String(body.length) as Object;
    this.config = config;
    this.status = status;
    this.headers = headers;
    this.data = body;
  }
}

class ExtensionAutoTrackOptions implements FTSDKExtensionAutoTrackOptions {
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;

  constructor(traceEnabled: boolean, resourceEnabled: boolean) {
    this.enableTraceInterceptor = traceEnabled;
    this.enableResourceInterceptor = resourceEnabled;
  }
}

class ExtensionRequest implements FTSDKExtensionRequestInput {
  url: string;
  method?: string;
  headers?: Object | null;
  body?: string | Object | ArrayBuffer;

  constructor(url: string, method: string, headers: Object) {
    this.url = url;
    this.method = method;
    this.headers = headers;
  }
}

class ExtensionResponse implements FTSDKExtensionResponseInput {
  url: string;
  method?: string;
  uniqueId?: string;
  requestHeaders?: Object | null;
  responseHeaders?: Object | null;
  statusCode: number;
  body?: string | Object | ArrayBuffer;
  errorMessage?: string;
  errorStack?: string;

  constructor(prepared: FTSDKExtensionPreparedRequest, responseHeaders: Object, statusCode: number, body: string) {
    this.url = prepared.url;
    this.method = prepared.method;
    this.uniqueId = prepared.uniqueId;
    this.requestHeaders = prepared.headers;
    this.responseHeaders = responseHeaders;
    this.statusCode = statusCode;
    this.body = body;
  }
}

async function installResourceSdk(): Promise<void> {
  const context = await DBAssert.getAppContext();
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
    .setTraceType(TraceType.DDTRACE));
}

async function flushAndAssertUploaded(
  collector: MockCollector,
  fragments: string[],
  recordUuid: string
): Promise<void> {
  FTSDK.flushSyncData();

  const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
  const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, recordUuid, 5000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
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

function assertDDTraceHeaders(headers: Object | undefined | null): string[] {
  const traceId = readHeader(headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY);
  const spanId = readHeader(headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY);
  const sampled = readHeader(headers, FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY);
  const origin = readHeader(headers, FTTraceHandler.DD_TRACE_ORIGIN_KEY);
  const resourceId = readHeader(headers, 'X-FT-Resource-ID');

  expect(traceId.length > 0).assertTrue();
  expect(spanId.length > 0).assertTrue();
  expect(sampled).assertEqual('2');
  expect(origin).assertEqual('rum');
  expect(resourceId.length > 0).assertTrue();

  return [traceId, spanId];
}

export default function resourceAutoTrackDeviceTest() {
  describe('ResourceAutoTrackDeviceTest', () => {
    let collector: MockCollector;

    beforeEach(async () => {
      collector = new MockCollector(200, '');
      collector.start();
      await installResourceSdk();
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      collector.stop();
      FTSDK.shutDown();
      await DBAssert.cleanupAll();
    });

    it('httpExtensionBridgeCompatibilityShouldWriteUploadAndDelete', 0, async () => {
      const viewName = 'http_resource_view';
      const resourceUrl = 'http://device.test/http-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = new ExtensionRequest(resourceUrl, 'GET', requestHeaders);
      const options = new ExtensionAutoTrackOptions(true, true);
      const prepared: FTSDKExtensionPreparedRequest = FTSDKExtensionBridge.prepareHttpRequest(request, options);
      await WaitUtils.delay(5);

      const responseHeaders: Record<string, Object> = {};
      responseHeaders['content-type'] = 'application/json' as Object;
      responseHeaders['content-length'] = '11' as Object;
      const response: FTSDKExtensionResponseInput =
        new ExtensionResponse(prepared, responseHeaders, 200, '{"ok":true}');

      expect(prepared.resourceEnabled).assertTrue();
      expect(prepared.traceEnabled).assertTrue();
      const traceIds = assertDDTraceHeaders(prepared.headers);
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      await flushAndAssertUploaded(collector, fragments, record?.getUuid() ?? '');
    });

    it('axiosAutoTrackResourceShouldWriteUploadAndDelete', 0, async () => {
      const viewName = 'axios_resource_view';
      const resourceUrl = 'http://device.test/axios-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: true,
        enableResourceInterceptor: true
      });

      const requestConfig = new FakeAxiosRequestConfig(resourceUrl, 'post');
      const preparedConfig =
        target.requestManager.fulfilled!(requestConfig) as FTAxiosRequestConfigTarget;
      const traceIds = assertDDTraceHeaders(preparedConfig.headers);
      await WaitUtils.delay(5);
      const response = new FakeAxiosResponse(preparedConfig, 201, 'created');
      target.responseManager.fulfilled!(response);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=POST',
        'resource_status=201',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      await flushAndAssertUploaded(collector, fragments, record?.getUuid() ?? '');
    });
  });
}
