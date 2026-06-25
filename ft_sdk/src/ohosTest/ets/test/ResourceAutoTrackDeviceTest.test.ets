import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import json from '@ohos.util.json';
import { rcp } from '@kit.RemoteCommunicationKit';
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
  createFTRCPTrackConfig,
  FTAxiosErrorTarget,
  FTAxiosRequestConfigTarget,
  FTAxiosResponseTarget,
  RCPResourceInterceptor,
  RCPTraceInterceptor
} from '../../../main/ets/components/network/FTHttpAutoTrack';
import {
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceRequestContext
} from '../../../main/ets/components/trace/FTTraceHeaderHandler';
import { FTTraceHandler } from '../../../main/ets/components/trace/FTTraceHandler';
import { FTTraceManager } from '../../../main/ets/components/trace/FTTraceManager';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';

class EmptyObject {
}

class RecordingDeviceTraceHeaderHandler implements FTTraceHeaderHandler {
  requestTraceId: string = '';
  requestSpanId: string = '';
  requestCount: number = 0;

  getTraceContext(request: FTTraceRequestContext): FTTraceContext {
    const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
    this.requestCount++;
    this.requestTraceId = traceContext.traceId;
    this.requestSpanId = traceContext.spanId;
    traceContext.headers['x-device-handler-trace-id'] = traceContext.traceId;
    return traceContext;
  }
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

class FakeAxiosError implements FTAxiosErrorTarget {
  config?: FTAxiosRequestConfigTarget;
  response?: FTAxiosResponseTarget;
  message?: string;
  stack?: string;

  constructor(config: FTAxiosRequestConfigTarget, message: string, stack: string) {
    this.config = config;
    this.message = message;
    this.stack = stack;
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

class ExtensionLooseResponse implements FTSDKExtensionResponseInput {
  url: string;
  method?: string;
  uniqueId?: string;
  requestHeaders?: Object | null;
  responseHeaders?: Object | null;
  statusCode: number;
  body?: string | Object | ArrayBuffer;
  errorMessage?: string;
  errorStack?: string;

  constructor(
    url: string,
    method: string,
    uniqueId: string | undefined,
    requestHeaders: Object | null,
    responseHeaders: Object | null,
    statusCode: number,
    body: string,
    errorMessage?: string,
    errorStack?: string
  ) {
    this.url = url;
    this.method = method;
    this.uniqueId = uniqueId;
    this.requestHeaders = requestHeaders;
    this.responseHeaders = responseHeaders;
    this.statusCode = statusCode;
    this.body = body;
    this.errorMessage = errorMessage;
    this.errorStack = errorStack;
  }
}

class ResourceFakeRcpRequestContext implements rcp.RequestContext {
  request: rcp.Request;
  session: rcp.Session;

  constructor(url: string, method: rcp.HttpMethod) {
    this.request = new rcp.Request(url, method, {});
    this.session = rcp.createSession();
  }
}

class ResourceFakeRcpTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 1;
  connectTimeMs: number = 2;
  tlsHandshakeTimeMs: number = 3;
  preTransferTimeMs: number = 4;
  startTransferTimeMs: number = 5;
  totalTimeMs: number = 8;
  redirectTimeMs: number = 0;
}

class ResourceFakeRcpResponse implements rcp.Response {
  readonly request: rcp.Request;
  readonly statusCode: number;
  readonly headers: rcp.ResponseHeaders;
  readonly timeInfo?: rcp.TimeInfo;
  private responseBody: string;

  constructor(request: rcp.Request, statusCode: number, body: string, contentType: string) {
    this.request = request;
    this.statusCode = statusCode;
    this.responseBody = body;
    this.timeInfo = new ResourceFakeRcpTimeInfo();
    this.headers = {};
    this.headers['content-type'] = contentType;
    this.headers['content-length'] = String(body.length);
  }

  toString(): string | null {
    return this.responseBody;
  }

  toJSON(): object | null;
  toJSON(_param: json.ParseOptions): object | null;
  toJSON(_param?: json.ParseOptions): object | null {
    return null;
  }
}

class ResourceFakeRcpTerminalHandler implements rcp.RequestHandler {
  async handle(context: rcp.RequestContext): Promise<rcp.Response> {
    return new ResourceFakeRcpResponse(context.request, 200, '{"ok":true}', 'application/json');
  }
}

class ResourceFakeRcpChainHandler implements rcp.RequestHandler {
  private interceptors: rcp.Interceptor[];
  private index: number;
  private terminal: rcp.RequestHandler;

  constructor(interceptors: rcp.Interceptor[], index: number, terminal: rcp.RequestHandler) {
    this.interceptors = interceptors;
    this.index = index;
    this.terminal = terminal;
  }

  async handle(context: rcp.RequestContext): Promise<rcp.Response> {
    if (this.index >= this.interceptors.length) {
      return await this.terminal.handle(context);
    }

    const next = new ResourceFakeRcpChainHandler(this.interceptors, this.index + 1, this.terminal);
    return await this.interceptors[this.index].intercept(context, next);
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

function assertNoTraceHeaders(headers: Object | undefined | null): void {
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.DD_TRACE_ORIGIN_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_TRACE_ID).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_SPAN_ID).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_SAMPLED).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_B3_HEADER).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.W3C_TRACEPARENT_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.JAEGER_KEY).length).assertEqual(0);
  expect(readHeader(headers, FTTraceHandler.SKYWALKING_V3_SW_8).length).assertEqual(0);
}

function assertZipkinSingleHeaders(headers: Object | undefined | null): string[] {
  const b3 = readHeader(headers, FTTraceHandler.ZIPKIN_B3_HEADER);
  const parts = b3.split('-');

  expect(/^[0-9a-f]{32}-[0-9a-f]{16}-1$/.test(b3)).assertTrue();
  expect(parts.length).assertEqual(3);
  expect(readHeader(headers, 'X-FT-Resource-ID').length > 0).assertTrue();
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_TRACE_ID).length === 0).assertTrue();
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_SPAN_ID).length === 0).assertTrue();
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_SAMPLED).length === 0).assertTrue();

  return [parts[0], parts[1]];
}

function assertZipkinMultiHeaders(headers: Object | undefined | null): string[] {
  const traceId = readHeader(headers, FTTraceHandler.ZIPKIN_TRACE_ID);
  const spanId = readHeader(headers, FTTraceHandler.ZIPKIN_SPAN_ID);
  const sampled = readHeader(headers, FTTraceHandler.ZIPKIN_SAMPLED);

  expect(/^[0-9a-f]{32}$/.test(traceId)).assertTrue();
  expect(/^[0-9a-f]{16}$/.test(spanId)).assertTrue();
  expect(sampled).assertEqual('1');
  expect(readHeader(headers, 'X-FT-Resource-ID').length > 0).assertTrue();
  expect(readHeader(headers, FTTraceHandler.ZIPKIN_B3_HEADER).length === 0).assertTrue();

  return [traceId, spanId];
}

function assertTraceparentHeaders(headers: Object | undefined | null): string[] {
  const traceparent = readHeader(headers, FTTraceHandler.W3C_TRACEPARENT_KEY);
  const parts = traceparent.split('-');

  expect(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/.test(traceparent)).assertTrue();
  expect(parts.length).assertEqual(4);
  expect(readHeader(headers, 'X-FT-Resource-ID').length > 0).assertTrue();

  return [parts[1], parts[2]];
}

function assertJaegerHeaders(headers: Object | undefined | null): string[] {
  const jaeger = readHeader(headers, FTTraceHandler.JAEGER_KEY);
  const parts = jaeger.split(':');

  expect(/^[0-9a-f]{32}:[0-9a-f]{16}:0:1$/.test(jaeger)).assertTrue();
  expect(parts.length).assertEqual(4);
  expect(readHeader(headers, 'X-FT-Resource-ID').length > 0).assertTrue();

  return [parts[0], parts[1]];
}

type TraceHeaderAssert = (headers: Object | undefined | null) => string[];

function installTraceType(traceType: TraceType): void {
  FTSDK.installTraceConfig(new FTTraceConfig()
    .setEnableAutoTrace(true)
    .setEnableLinkRUMData(true)
    .setTraceType(traceType));
}

async function runResourceRcpChain(
  interceptors: rcp.Interceptor[],
  context: ResourceFakeRcpRequestContext
): Promise<rcp.Response> {
  const terminal = new ResourceFakeRcpTerminalHandler();
  const handler = new ResourceFakeRcpChainHandler(interceptors, 0, terminal);
  return await handler.handle(context);
}

async function assertRcpTraceTypeResource(
  collector: MockCollector,
  traceType: TraceType,
  viewName: string,
  resourceUrl: string,
  assertTraceHeaders: TraceHeaderAssert
): Promise<void> {
  installTraceType(traceType);
  await FTRUMGlobalManager.getInstance().startView(viewName);

  const config = createFTRCPTrackConfig({
    enableTraceInterceptor: true,
    enableResourceInterceptor: true
  });
  const interceptors = config.interceptors ?? [];
  expect(interceptors.length >= 2).assertTrue();
  expect(interceptors[0] instanceof RCPTraceInterceptor).assertTrue();
  expect(interceptors[1] instanceof RCPResourceInterceptor).assertTrue();

  const context = new ResourceFakeRcpRequestContext(resourceUrl, 'GET');
  await runResourceRcpChain(interceptors, context);
  const traceIds = assertTraceHeaders(context.request.headers as Object);
  await WaitUtils.delay(5);

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
}

export default function resourceAutoTrackDeviceTest() {
  describe('ResourceAutoTrackDeviceTest', () => {
    let collector: MockCollector;

    beforeEach(async () => {
      await SdkTestLifecycle.resetRuntimeState();
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
      await SdkTestLifecycle.resetRuntimeState();
    });

    it('httpBridgeShouldUploadAndDelete', 0, async () => {
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

    it('httpBridgeShouldProcessHeaders', 0, async () => {
      const headerHandler = new RecordingDeviceTraceHeaderHandler();
      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.DDTRACE)
        .setTraceHeaderHandler(headerHandler));

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput =
        new ExtensionRequest('http://device.test/header-handler', 'GET', requestHeaders);
      const options = new ExtensionAutoTrackOptions(true, false);
      const prepared = FTSDKExtensionBridge.prepareHttpRequest(request, options);

      expect(prepared.traceEnabled).assertTrue();
      expect(headerHandler.requestCount).assertEqual(1);
      expect(headerHandler.requestTraceId.length > 0).assertTrue();
      expect(headerHandler.requestSpanId.length > 0).assertTrue();
      expect(prepared.headers['x-device-handler-trace-id']).assertEqual(headerHandler.requestTraceId);

      const responseHeaders: Record<string, Object> = {};
      responseHeaders['content-type'] = 'application/json' as Object;
      const response: FTSDKExtensionResponseInput =
        new ExtensionResponse(prepared, responseHeaders, 200, '{"ok":true}');

      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();
    });

    it('httpErrorShouldUseResourceFallback', 0, async () => {
      const viewName = 'http_extension_fallback_error_view';
      const resourceUrl = 'http://device.test/http-extension-fallback-error';
      const errorMessage = 'Bridge resource error fallback forced failure';
      const errorStack = 'Error: Bridge resource error fallback forced failure\n  at ResourceAutoTrackDeviceTest';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = new ExtensionRequest(resourceUrl, 'GET', requestHeaders);
      const prepared = FTSDKExtensionBridge.prepareHttpRequest(request, new ExtensionAutoTrackOptions(true, true));
      const traceIds = assertDDTraceHeaders(prepared.headers);

      const responseHeaders: Record<string, Object> = {};
      const response = new ExtensionLooseResponse(
        resourceUrl,
        'GET',
        prepared.uniqueId,
        prepared.headers,
        responseHeaders,
        0,
        '',
        errorMessage,
        errorStack
      );

      expect(FTSDKExtensionBridge.completeHttpError(response)).assertTrue();

      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const errorFragments = [
        'error',
        'error_type=network',
        'error_source=network',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        errorMessage,
        'ResourceAutoTrackDeviceTest'
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect((resourceRecord?.getDataString() ?? '').includes('resource_status=0')).assertFalse();
      expect(errorRecord !== null).assertTrue();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const resourceUploaded =
        await collector.waitForPayloadContaining(resourceFragments, 5000);
      const errorUploaded =
        await collector.waitForPayloadContaining(errorFragments, 5000);
      const resourceConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resourceRecord?.getUuid() ?? '', 5000);
      const errorConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(resourceUploaded.length > 0).assertTrue();
      expect(errorUploaded.length > 0).assertTrue();
      expect(resourceConsumed).assertTrue();
      expect(errorConsumed).assertTrue();
    });

    it('httpErrorShouldWriteResourceError', 0, async () => {
      const viewName = 'http_extension_error_view';
      const resourceUrl = 'http://device.test/http-extension-error';
      const errorMessage = 'Extension planned failure';
      const errorStack = 'Error: Extension planned failure\n  at ResourceAutoTrackDeviceTest';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const requestHeaders: Record<string, Object> = {};
      const request: FTSDKExtensionRequestInput = new ExtensionRequest(resourceUrl, 'GET', requestHeaders);
      const prepared = FTSDKExtensionBridge.prepareHttpRequest(request, new ExtensionAutoTrackOptions(true, true));
      const traceIds = assertDDTraceHeaders(prepared.headers);
      const responseHeaders: Record<string, Object> = {};
      const response = new ExtensionLooseResponse(
        resourceUrl,
        'GET',
        prepared.uniqueId,
        prepared.headers,
        responseHeaders,
        0,
        '',
        errorMessage,
        errorStack
      );

      expect(FTSDKExtensionBridge.completeHttpError(response)).assertTrue();

      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const errorFragments = [
        'error',
        'error_type=network',
        'error_source=network',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        errorMessage,
        'ResourceAutoTrackDeviceTest'
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect(errorRecord !== null).assertTrue();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const resourceUploaded =
        await collector.waitForPayloadContaining(resourceFragments, 5000);
      const errorUploaded =
        await collector.waitForPayloadContaining(errorFragments, 5000);
      const resourceConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resourceRecord?.getUuid() ?? '', 5000);
      const errorConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(resourceUploaded.length > 0).assertTrue();
      expect(errorUploaded.length > 0).assertTrue();
      expect(resourceConsumed).assertTrue();
      expect(errorConsumed).assertTrue();
    });

    it('httpMissingStateShouldWriteNothing', 0, async () => {
      const missingIdRequestHeaders: Record<string, Object> = {};
      const missingIdResponseHeaders: Record<string, Object> = {};
      const missingStateResponseHeaders: Record<string, Object> = {};
      const missingId = new ExtensionLooseResponse(
        'http://device.test/missing-id',
        'GET',
        undefined,
        missingIdRequestHeaders,
        missingIdResponseHeaders,
        200,
        ''
      );
      const orphanHeaders: Record<string, Object> = {};
      orphanHeaders['X-FT-Resource-ID'] = 'orphan-resource-id' as Object;
      const missingState = new ExtensionLooseResponse(
        'http://device.test/missing-state',
        'GET',
        undefined,
        orphanHeaders,
        missingStateResponseHeaders,
        200,
        ''
      );

      expect(FTSDKExtensionBridge.completeHttpResponse(missingId)).assertFalse();
      expect(FTSDKExtensionBridge.completeHttpResponse(missingState)).assertFalse();

      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.RUM_APP], 0, 1200);
      expect(stayedEmpty).assertTrue();
    });

    it('httpExistingTraceShouldBeKept', 0, async () => {
      const requestHeaders: Record<string, Object> = {};
      requestHeaders[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = '123456789' as Object;
      requestHeaders[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = '987654321' as Object;
      requestHeaders[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = '1' as Object;
      requestHeaders[FTTraceHandler.DD_TRACE_ORIGIN_KEY] = 'upstream' as Object;
      const request = new ExtensionRequest('http://device.test/existing-trace', 'GET', requestHeaders);

      const prepared = FTSDKExtensionBridge.prepareHttpRequest(request, new ExtensionAutoTrackOptions(true, false));

      expect(readHeader(prepared.headers, FTTraceHandler.DD_TRACE_TRACE_ID_KEY)).assertEqual('123456789');
      expect(readHeader(prepared.headers, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY)).assertEqual('987654321');
      expect(readHeader(prepared.headers, FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY)).assertEqual('1');
      expect(readHeader(prepared.headers, FTTraceHandler.DD_TRACE_ORIGIN_KEY)).assertEqual('upstream');
      expect(readHeader(prepared.headers, 'X-FT-Resource-ID').length > 0).assertTrue();

      const responseHeaders: Record<string, Object> = {};
      const response = new ExtensionLooseResponse(
        prepared.url,
        prepared.method,
        prepared.uniqueId,
        prepared.headers,
        responseHeaders,
        204,
        ''
      );
      expect(FTSDKExtensionBridge.completeHttpResponse(response)).assertTrue();

      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.RUM_APP], 0, 1200);
      expect(stayedEmpty).assertTrue();
    });

    it('axiosPrepareShouldStoreMethod', 0, async () => {
      const postHeaders: Record<string, Object> = {};
      postHeaders['Accept'] = 'application/json' as Object;
      const postPrepared = FTSDKExtensionBridge.prepareAxiosChainRequest(
        new ExtensionRequest('http://device.test/axios-chain-prepare-post', 'patch', postHeaders)
      );

      expect(postPrepared.method).assertEqual('PATCH');
      expect(postPrepared.traceEnabled).assertFalse();
      expect(postPrepared.resourceEnabled).assertFalse();
      expect(postPrepared.uniqueId.length > 0).assertTrue();
      expect(postPrepared.headers['X-FT-Resource-ID']).assertEqual(postPrepared.uniqueId);
      expect(postPrepared.headers['Accept']).assertEqual('application/json');
      expect(FTSDKExtensionBridge.resolveAxiosMethod(postPrepared.uniqueId)).assertEqual('PATCH');

      const defaultHeaders: Record<string, Object> = {};
      const defaultPrepared = FTSDKExtensionBridge.prepareAxiosChainRequest({
        url: 'http://device.test/axios-chain-prepare-default',
        headers: defaultHeaders
      });

      expect(defaultPrepared.method).assertEqual('GET');
      expect(defaultPrepared.uniqueId.length > 0).assertTrue();
      expect(defaultPrepared.headers['X-FT-Resource-ID']).assertEqual(defaultPrepared.uniqueId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(defaultPrepared.uniqueId)).assertEqual('GET');

      FTSDKExtensionBridge.clearAxiosMethod(postPrepared.uniqueId);
      FTSDKExtensionBridge.clearAxiosMethod(defaultPrepared.uniqueId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(postPrepared.uniqueId) === undefined).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(defaultPrepared.uniqueId) === undefined).assertTrue();
    });

    it('rcpTraceOffShouldWriteResource', 0, async () => {
      const viewName = 'rcp_auto_trace_disabled_view';
      const resourceUrl = 'http://device.test/rcp-auto-trace-disabled';
      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(false)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.DDTRACE));
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableResourceInterceptor: true
      });
      const interceptors = config.interceptors ?? [];
      expect(interceptors.length).assertEqual(1);
      expect(interceptors[0] instanceof RCPResourceInterceptor).assertTrue();

      const context = new ResourceFakeRcpRequestContext(resourceUrl, 'GET');
      await runResourceRcpChain(interceptors, context);
      assertNoTraceHeaders(context.request.headers as Object);
      expect(readHeader(context.request.headers as Object, 'X-FT-Resource-ID').length > 0).assertTrue();
      await WaitUtils.delay(5);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('trace_id=')).assertFalse();
      expect(line.includes('span_id=')).assertFalse();

      FTSDK.flushSyncData();
      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(uploaded.includes('trace_id=')).assertFalse();
      expect(uploaded.includes('span_id=')).assertFalse();
      expect(consumed).assertTrue();
    });

    it('rcpNoRumLinkShouldOmitTraceIds', 0, async () => {
      const viewName = 'rcp_trace_link_disabled_view';
      const resourceUrl = 'http://device.test/rcp-trace-link-disabled';
      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(false)
        .setTraceType(TraceType.DDTRACE));
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableResourceInterceptor: true
      });
      const interceptors = config.interceptors ?? [];
      expect(interceptors.length >= 2).assertTrue();
      expect(interceptors[0] instanceof RCPTraceInterceptor).assertTrue();
      expect(interceptors[1] instanceof RCPResourceInterceptor).assertTrue();

      const context = new ResourceFakeRcpRequestContext(resourceUrl, 'GET');
      await runResourceRcpChain(interceptors, context);
      assertDDTraceHeaders(context.request.headers as Object);
      await WaitUtils.delay(5);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('trace_id=')).assertFalse();
      expect(line.includes('span_id=')).assertFalse();

      FTSDK.flushSyncData();
      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(uploaded.includes('trace_id=')).assertFalse();
      expect(uploaded.includes('span_id=')).assertFalse();
      expect(consumed).assertTrue();
    });

    it('rcpExistingTraceShouldBeKept', 0, async () => {
      FTSDK.installTraceConfig(new FTTraceConfig()
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.DDTRACE));

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      });
      const interceptors = config.interceptors ?? [];
      expect(interceptors.length).assertEqual(1);
      expect(interceptors[0] instanceof RCPTraceInterceptor).assertTrue();

      const context = new ResourceFakeRcpRequestContext('http://device.test/rcp-existing-trace', 'GET');
      if (!context.request.headers) {
        context.request.headers = {};
      }
      context.request.headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] = '123456789';
      context.request.headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] = '987654321';
      context.request.headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] = '1';
      context.request.headers[FTTraceHandler.DD_TRACE_ORIGIN_KEY] = 'upstream';

      await runResourceRcpChain(interceptors, context);

      expect(readHeader(context.request.headers as Object, FTTraceHandler.DD_TRACE_TRACE_ID_KEY)).assertEqual('123456789');
      expect(readHeader(context.request.headers as Object, FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY)).assertEqual('987654321');
      expect(readHeader(context.request.headers as Object, FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY)).assertEqual('1');
      expect(readHeader(context.request.headers as Object, FTTraceHandler.DD_TRACE_ORIGIN_KEY)).assertEqual('upstream');
      expect(readHeader(context.request.headers as Object, 'X-FT-Resource-ID').length > 0).assertTrue();

      const stayedEmpty = await DBAssert.waitForSyncCount([DataType.RUM_APP], 0, 1200);
      expect(stayedEmpty).assertTrue();
    });

    it('rcpDDTraceShouldWriteResource', 0, async () => {
      await assertRcpTraceTypeResource(
        collector,
        TraceType.DDTRACE,
        'rcp_ddtrace_resource_view',
        'http://device.test/rcp-ddtrace-resource',
        assertDDTraceHeaders
      );
    });

    it('axiosResourceShouldUploadAndDelete', 0, async () => {
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

    it('axiosRejectShouldWriteResourceError', 0, async () => {
      const viewName = 'axios_rejected_resource_view';
      const resourceUrl = 'http://device.test/axios-rejected-resource';
      const errorMessage = 'Axios planned failure';
      const errorStack = 'Error: Axios planned failure\n  at ResourceAutoTrackDeviceTest';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: true,
        enableResourceInterceptor: true
      });

      const requestConfig = new FakeAxiosRequestConfig(resourceUrl, 'get');
      const preparedConfig =
        target.requestManager.fulfilled!(requestConfig) as FTAxiosRequestConfigTarget;
      const traceIds = assertDDTraceHeaders(preparedConfig.headers);
      const axiosError = new FakeAxiosError(preparedConfig, errorMessage, errorStack);
      let rejected = false;
      try {
        await target.responseManager.rejected!(axiosError as Object);
      } catch (_error) {
        rejected = true;
      }

      expect(rejected).assertTrue();

      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const errorFragments = [
        'error',
        'error_type=network',
        'error_source=network',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        errorMessage,
        'ResourceAutoTrackDeviceTest'
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect(errorRecord !== null).assertTrue();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const resourceUploaded =
        await collector.waitForPayloadContaining(resourceFragments, 5000);
      const errorUploaded =
        await collector.waitForPayloadContaining(errorFragments, 5000);
      const resourceConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resourceRecord?.getUuid() ?? '', 5000);
      const errorConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(resourceUploaded.length > 0).assertTrue();
      expect(errorUploaded.length > 0).assertTrue();
      expect(resourceConsumed).assertTrue();
      expect(errorConsumed).assertTrue();
    });

    it('rcpZipkinSingleShouldWriteResource', 0, async () => {
      await assertRcpTraceTypeResource(
        collector,
        TraceType.ZIPKIN_SINGLE_HEADER,
        'rcp_zipkin_single_resource_view',
        'http://device.test/rcp-zipkin-single-resource',
        assertZipkinSingleHeaders
      );
    });

    it('rcpZipkinMultiShouldWriteResource', 0, async () => {
      await assertRcpTraceTypeResource(
        collector,
        TraceType.ZIPKIN_MULTI_HEADER,
        'rcp_zipkin_multi_resource_view',
        'http://device.test/rcp-zipkin-multi-resource',
        assertZipkinMultiHeaders
      );
    });

    it('rcpTraceparentShouldWriteResource', 0, async () => {
      await assertRcpTraceTypeResource(
        collector,
        TraceType.TRACEPARENT,
        'rcp_traceparent_resource_view',
        'http://device.test/rcp-traceparent-resource',
        assertTraceparentHeaders
      );
    });

    it('rcpJaegerShouldWriteResource', 0, async () => {
      await assertRcpTraceTypeResource(
        collector,
        TraceType.JAEGER,
        'rcp_jaeger_resource_view',
        'http://device.test/rcp-jaeger-resource',
        assertJaegerHeaders
      );
    });
  });
}
