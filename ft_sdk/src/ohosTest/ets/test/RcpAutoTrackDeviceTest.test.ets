import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import json from '@ohos.util.json';
import { rcp } from '@kit.RemoteCommunicationKit';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig, FTTraceConfig, FTLoggerConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { FTTraceHandler } from '../../../main/ets/components/trace/FTTraceHandler';
import {
  createFTRCPTrackConfig,
  RCPResourceInterceptor,
  RCPTraceInterceptor
} from '../../../main/ets/components/network/FTHttpAutoTrack';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';

class FakeRcpRequestContext implements rcp.RequestContext {
  request: rcp.Request;
  session: rcp.Session;

  constructor(url: string, method: rcp.HttpMethod) {
    this.request = new rcp.Request(url, method, {});
    this.session = rcp.createSession();
  }
}

class FakeRcpTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 1;
  connectTimeMs: number = 2;
  tlsHandshakeTimeMs: number = 3;
  preTransferTimeMs: number = 4;
  startTransferTimeMs: number = 5;
  totalTimeMs: number = 8;
  redirectTimeMs: number = 0;
}

class FakeRcpRawTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 10;
  connectTimeMs: number = 30;
  tlsHandshakeTimeMs: number = 80;
  preTransferTimeMs: number = 100;
  startTransferTimeMs: number = 150;
  totalTimeMs: number = 180;
  redirectTimeMs: number = 0;
  dnsTime: number = 10000000;
  tcpTime: number = 20000000;
  ttfbTime: number = 50000000;
  responseTime: number = 100000000;
  downloadTime: number = 30000000;
  totalTime: number = 180000000;
}

class FakeRcpResponse implements rcp.Response {
  readonly request: rcp.Request;
  readonly statusCode: number;
  readonly headers: rcp.ResponseHeaders;
  readonly timeInfo?: rcp.TimeInfo;
  private responseBody: string;

  constructor(request: rcp.Request, statusCode: number, body: string, contentType: string,
    timeInfo: rcp.TimeInfo | null = new FakeRcpTimeInfo(),
    contentLength?: number) {
    this.request = request;
    this.statusCode = statusCode;
    this.responseBody = body;
    if (timeInfo !== null) {
      this.timeInfo = timeInfo;
    }
    this.headers = {};
    this.headers['content-type'] = contentType;
    this.headers['content-length'] = String(contentLength ?? body.length);
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

class FakeRcpTerminalHandler implements rcp.RequestHandler {
  private statusCode: number;
  private body: string;
  private contentType: string;
  private timeInfo: rcp.TimeInfo | null;
  private contentLength?: number;
  private delayMs: number;

  constructor(statusCode: number, body: string, contentType: string, timeInfo: rcp.TimeInfo | null = new FakeRcpTimeInfo(),
    contentLength?: number, delayMs: number = 0) {
    this.statusCode = statusCode;
    this.body = body;
    this.contentType = contentType;
    this.timeInfo = timeInfo;
    this.contentLength = contentLength;
    this.delayMs = delayMs;
  }

  async handle(_context: rcp.RequestContext): Promise<rcp.Response> {
    if (this.delayMs > 0) {
      await WaitUtils.delay(this.delayMs);
    }
    return new FakeRcpResponse(_context.request, this.statusCode, this.body, this.contentType, this.timeInfo,
      this.contentLength);
  }
}

class FakeRcpErrorTerminalHandler implements rcp.RequestHandler {
  private error: Error;

  constructor(message: string) {
    this.error = new Error(message);
  }

  async handle(_context: rcp.RequestContext): Promise<rcp.Response> {
    throw this.error;
  }
}

class FakeRcpChainHandler implements rcp.RequestHandler {
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

    const next = new FakeRcpChainHandler(this.interceptors, this.index + 1, this.terminal);
    return await this.interceptors[this.index].intercept(context, next);
  }
}

async function installRcpSdk(): Promise<void> {
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

async function runRcpChain(
  interceptors: rcp.Interceptor[],
  context: FakeRcpRequestContext,
  statusCode: number,
  body: string,
  contentType: string,
  timeInfo: rcp.TimeInfo | null = new FakeRcpTimeInfo(),
  contentLength?: number,
  delayMs: number = 0
): Promise<rcp.Response> {
  const terminal = new FakeRcpTerminalHandler(statusCode, body, contentType, timeInfo, contentLength, delayMs);
  const handler = new FakeRcpChainHandler(interceptors, 0, terminal);
  return await handler.handle(context);
}

async function runRcpErrorChain(
  interceptors: rcp.Interceptor[],
  context: FakeRcpRequestContext,
  message: string
): Promise<void> {
  const terminal = new FakeRcpErrorTerminalHandler(message);
  const handler = new FakeRcpChainHandler(interceptors, 0, terminal);
  await handler.handle(context);
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

async function flushAndAssertResourceAndErrorUploaded(
  collector: MockCollector,
  resourceFragments: string[],
  resourceUuid: string,
  errorFragments: string[],
  errorUuid: string
): Promise<void> {
  collector.clearRequests();
  FTSDK.flushSyncData();

  const uploaded = await WaitUtils.waitUntil(async () => {
    const requests = collector.getRequests();
    let hasResource = false;
    let hasError = false;
    for (const request of requests) {
      if (DBAssert.containsAll(request.bodyString, resourceFragments)) {
        hasResource = true;
      }
      if (DBAssert.containsAll(request.bodyString, errorFragments)) {
        hasError = true;
      }
      if (hasResource && hasError) {
        return true;
      }
    }
    return false;
  }, 5000);
  const resourceConsumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resourceUuid, 5000);
  const errorConsumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorUuid, 5000);

  expect(uploaded).assertTrue();
  expect(resourceConsumed).assertTrue();
  expect(errorConsumed).assertTrue();
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

export default function rcpAutoTrackDeviceTest() {
  describe('RcpAutoTrackDeviceTest', () => {
    let collector: MockCollector;

    beforeEach(async () => {
      collector = new MockCollector(200, '');
      collector.start();
      await installRcpSdk();
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      collector.stop();
      FTSDK.shutDown();
      await DBAssert.cleanupAll();
    });

    it('rcpConfigShouldUploadResource', 0, async () => {
      const viewName = 'rcp_config_resource_view';
      const resourceUrl = 'http://device.test/rcp-config-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: true
      });
      const interceptors = config.interceptors ?? [];
      expect(interceptors.length >= 2).assertTrue();
      expect(interceptors[0] instanceof RCPTraceInterceptor).assertTrue();
      expect(interceptors[1] instanceof RCPResourceInterceptor).assertTrue();

      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      await runRcpChain(interceptors, context, 202, '{"ok":true}', 'application/json');
      await WaitUtils.delay(5);

      const traceIds = assertDDTraceHeaders(context.request.headers as Object);
      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=202',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      await flushAndAssertUploaded(collector, fragments, record?.getUuid() ?? '');
    });

    it('rcpResourceShouldWritePerfFields', 0, async () => {
      const viewName = 'rcp_performance_resource_view';
      const resourceUrl = 'http://device.test/rcp-performance-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: true
      });
      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      await runRcpChain(config.interceptors ?? [], context, 200, '{"ok":true}', 'application/json',
        new FakeRcpRawTimeInfo(), 1024);
      await WaitUtils.delay(5);

      const traceIds = assertDDTraceHeaders(context.request.headers as Object);
      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        'resource_type=network',
        'resource_size=1024',
        'resource_dns=10000000',
        'resource_tcp=20000000',
        'resource_ssl=50000000',
        'resource_ttfb=50000000',
        'resource_first_byte=50000000',
        'resource_trans=100000000',
        'resource_download_time',
        '30000000',
        'duration=180000000',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      await flushAndAssertUploaded(collector, fragments, record?.getUuid() ?? '');
    });

    it('rcpNoTimeInfoShouldFallback', 0, async () => {
      const viewName = 'rcp_fallback_resource_view';
      const resourceUrl = 'http://device.test/rcp-fallback-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });
      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      await runRcpChain(config.interceptors ?? [], context, 204, '', 'text/plain', null, 0, 2);
      await WaitUtils.delay(5);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=204',
        'duration=',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      expect(record!.getDataString().includes('resource_dns=')).assertFalse();
      expect(record!.getDataString().includes('resource_tcp=')).assertFalse();
      expect(record!.getDataString().includes('resource_ttfb=')).assertFalse();
      await flushAndAssertUploaded(collector, fragments, record?.getUuid() ?? '');
    });

    it('rcpErrorShouldWriteResourceError', 0, async () => {
      const viewName = 'rcp_error_resource_view';
      const resourceUrl = 'http://device.test/rcp-error-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });
      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      let thrown = false;
      try {
        await runRcpErrorChain(config.interceptors ?? [], context, 'RCP planned failure');
      } catch (_error) {
        thrown = true;
      }
      await WaitUtils.delay(5);

      expect(thrown).assertTrue();
      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'duration=',
        `view_name=${viewName}`
      ];
      const errorFragments = [
        'error',
        'error_source=network',
        'error_type=network',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        `view_name=${viewName}`
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect(errorRecord !== null).assertTrue();
      await flushAndAssertResourceAndErrorUploaded(
        collector,
        resourceFragments,
        resourceRecord?.getUuid() ?? '',
        errorFragments,
        errorRecord?.getUuid() ?? ''
      );
    });

    it('manualRcpShouldInjectTrace', 0, async () => {
      const viewName = 'rcp_manual_resource_view';
      const resourceUrl = 'http://device.test/rcp-manual-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const interceptors: rcp.Interceptor[] = [
        new RCPTraceInterceptor(),
        new RCPResourceInterceptor()
      ];
      const context = new FakeRcpRequestContext(resourceUrl, 'POST');
      await runRcpChain(interceptors, context, 201, 'created', 'text/plain');
      await WaitUtils.delay(5);

      const traceIds = assertDDTraceHeaders(context.request.headers as Object);
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
