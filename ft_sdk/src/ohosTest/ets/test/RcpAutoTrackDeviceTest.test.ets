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
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkResourceFields
} from '../../../main/ets/components/network/FTNetworkErrorHandler';
import {
  createFTRCPTrackConfig,
  RCPResourceInterceptor,
  RCPTraceInterceptor
} from '../../../main/ets/components/network/FTHttpAutoTrack';
import { DBAssert } from './helpers/DBAssert';
import { RumAttributeAssert, RumAttributeExpectation } from './helpers/RumAttributeAssert';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';
import { WaitUtils } from './helpers/WaitUtils';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';

class RcpStatusZeroNetworkErrorHandler implements FTNetworkErrorHandler {
  callCount: number = 0;
  private readonly suppressNetworkError: boolean;
  private readonly throwsError: boolean;

  constructor(suppressNetworkError: boolean, throwsError: boolean = false) {
    this.suppressNetworkError = suppressNetworkError;
    this.throwsError = throwsError;
  }

  onExceptionWithFilter(_context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    this.callCount++;
    resourceFields['test_rcp_status_zero_handler'] = 'called';
    if (this.throwsError) {
      throw new Error('RCP status-zero test handler failed');
    }
    return this.suppressNetworkError;
  }
}

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
  redirectTimeMs: number = 40;
}

class FakeRcpHttpTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 10;
  connectTimeMs: number = 30;
  tlsHandshakeTimeMs: number = 0;
  preTransferTimeMs: number = 60;
  startTransferTimeMs: number = 80;
  totalTimeMs: number = 100;
  redirectTimeMs: number = 0;
}

class FakeRcpReusedConnectionTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 0;
  connectTimeMs: number = 0;
  tlsHandshakeTimeMs: number = 0;
  preTransferTimeMs: number = 40;
  startTransferTimeMs: number = 70;
  totalTimeMs: number = 100;
  redirectTimeMs: number = 0;
}

class FakeRcpEqualTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 10;
  connectTimeMs: number = 30;
  tlsHandshakeTimeMs: number = 30;
  preTransferTimeMs: number = 60;
  startTransferTimeMs: number = 60;
  totalTimeMs: number = 100;
  redirectTimeMs: number = 0;
}

class FakeRcpReversedTimeInfo implements rcp.TimeInfo {
  nameLookupTimeMs: number = 10;
  connectTimeMs: number = 30;
  tlsHandshakeTimeMs: number = 30;
  preTransferTimeMs: number = 80;
  startTransferTimeMs: number = 60;
  totalTimeMs: number = 100;
  redirectTimeMs: number = 0;
}

// The public RCP type requires this field, but a runtime value can still be
// absent when timing collection is partial or comes from an older platform.
class FakeRcpMissingPreTransferTimeInfo {
  nameLookupTimeMs: number = 10;
  connectTimeMs: number = 30;
  tlsHandshakeTimeMs: number = 80;
  startTransferTimeMs: number = 150;
  totalTimeMs: number = 180;
  redirectTimeMs: number = 0;
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

function assertResourceTimingField(
  record: SyncData | null,
  key: string,
  startTime: number,
  duration: number
): void {
  const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID };
  const point = RumAttributeAssert.record(record, attributes);
  const rawTiming = point.fields.get(key);
  if (typeof rawTiming !== 'string') {
    throw new Error(`Expected ${key} to be a JSON timing field`);
  }
  const timing = JSON.parse(rawTiming) as Record<string, number>;
  expect(timing['start']).assertEqual(startTime);
  expect(timing['duration']).assertEqual(duration);
}

function assertResourceFieldAbsent(record: SyncData | null, key: string): void {
  const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID };
  const point = RumAttributeAssert.record(record, attributes);
  expect(point.fields.has(key)).assertFalse();
}

async function flushAndAssertUploaded(
  collector: MockCollector,
  fragments: string[],
  record: SyncData | null
): Promise<void> {
  const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID };
  RumAttributeAssert.record(record, attributes);
  const recordUuid = record!.getUuid();
  FTSDK.flushSyncData();

  const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
  RumAttributeAssert.uploaded(uploaded, record, attributes);
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
      await SdkTestLifecycle.resetRuntimeState();
      collector = new MockCollector(200, '');
      collector.start();
      await installRcpSdk();
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      await runTestCleanup([
        async () => { await collector.stop(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await DBAssert.cleanupAll(); }
      ]);
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
      await flushAndAssertUploaded(collector, fragments, record);
    });

    it('rcpResourceShouldWritePerfFields', 0, async () => {
      const viewName = 'rcp_performance_resource_view';
      const resourceUrl = 'https://device.test/rcp-performance-resource';
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
      assertResourceTimingField(record, 'resource_dns_time', 0, 10000000);
      assertResourceTimingField(record, 'resource_connect_time', 10000000, 20000000);
      assertResourceTimingField(record, 'resource_ssl_time', 30000000, 50000000);
      // The redirect span is not a RUM phase. The TLS-to-preTransfer gap must
      // remain visible instead of shifting the following phases left.
      assertResourceTimingField(record, 'resource_first_byte_time', 100000000, 50000000);
      assertResourceTimingField(record, 'resource_download_time', 150000000, 30000000);
      await flushAndAssertUploaded(collector, fragments, record);
    });

    it('rcpHttpWithoutTlsShouldKeepTransferStartsAndOmitTlsBasedTrans', 0, async () => {
      const viewName = 'rcp_http_timing_resource_view';
      const resourceUrl = 'http://device.test/rcp-http-timing-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({ enableResourceInterceptor: true });
      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      await runRcpChain(config.interceptors ?? [], context, 200, 'ok', 'text/plain', new FakeRcpHttpTimeInfo());
      await WaitUtils.delay(5);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_ttfb=20000000',
        'resource_first_byte=20000000',
        'duration=100000000',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      assertResourceTimingField(record, 'resource_first_byte_time', 60000000, 20000000);
      assertResourceTimingField(record, 'resource_download_time', 80000000, 20000000);
      assertResourceFieldAbsent(record, 'resource_ssl');
      assertResourceFieldAbsent(record, 'resource_trans');
      await flushAndAssertUploaded(collector, fragments, record);
    });

    it('rcpReusedConnectionShouldNotInventZeroLengthConnectionPhases', 0, async () => {
      const viewName = 'rcp_reused_connection_resource_view';
      const resourceUrl = 'https://device.test/rcp-reused-connection-resource';
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({ enableResourceInterceptor: true });
      const context = new FakeRcpRequestContext(resourceUrl, 'GET');
      await runRcpChain(config.interceptors ?? [], context, 200, 'ok', 'text/plain', new FakeRcpReusedConnectionTimeInfo());
      await WaitUtils.delay(5);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_ttfb=30000000',
        'resource_first_byte=30000000',
        'duration=100000000',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();
      assertResourceTimingField(record, 'resource_first_byte_time', 40000000, 30000000);
      assertResourceTimingField(record, 'resource_download_time', 70000000, 30000000);
      assertResourceFieldAbsent(record, 'resource_dns');
      assertResourceFieldAbsent(record, 'resource_tcp');
      assertResourceFieldAbsent(record, 'resource_ssl');
      assertResourceFieldAbsent(record, 'resource_trans');
      await flushAndAssertUploaded(collector, fragments, record);
    });

    it('rcpEqualAndMissingPointsShouldNotFallbackToCumulativeEndpoints', 0, async () => {
      const viewName = 'rcp_partial_timing_resource_view';
      await FTRUMGlobalManager.getInstance().startView(viewName);
      const config = createFTRCPTrackConfig({ enableResourceInterceptor: true });

      const equalUrl = 'https://device.test/rcp-equal-timing-resource';
      await runRcpChain(config.interceptors ?? [], new FakeRcpRequestContext(equalUrl, 'GET'), 200, 'ok', 'text/plain',
        new FakeRcpEqualTimeInfo());
      const reversedUrl = 'https://device.test/rcp-reversed-timing-resource';
      await runRcpChain(config.interceptors ?? [], new FakeRcpRequestContext(reversedUrl, 'GET'), 200, 'ok', 'text/plain',
        new FakeRcpReversedTimeInfo());
      const missingUrl = 'https://device.test/rcp-missing-timing-resource';
      await runRcpChain(config.interceptors ?? [], new FakeRcpRequestContext(missingUrl, 'GET'), 200, 'ok', 'text/plain',
        new FakeRcpMissingPreTransferTimeInfo() as object as rcp.TimeInfo);
      await WaitUtils.delay(5);

      const equalRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource', `resource_url=${equalUrl}`, 'duration=100000000'], 5000);
      expect(equalRecord !== null).assertTrue();
      assertResourceTimingField(equalRecord, 'resource_download_time', 60000000, 40000000);
      assertResourceFieldAbsent(equalRecord, 'resource_ssl');
      assertResourceFieldAbsent(equalRecord, 'resource_ttfb');
      assertResourceFieldAbsent(equalRecord, 'resource_first_byte');
      assertResourceFieldAbsent(equalRecord, 'resource_first_byte_time');
      const equalAttributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID };
      const equalPoint = RumAttributeAssert.record(equalRecord, equalAttributes);
      expect(equalPoint.fields.get('resource_trans')).assertEqual(70000000);

      const reversedRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource', `resource_url=${reversedUrl}`, 'duration=100000000'], 5000);
      expect(reversedRecord !== null).assertTrue();
      assertResourceFieldAbsent(reversedRecord, 'resource_ttfb');
      assertResourceFieldAbsent(reversedRecord, 'resource_first_byte');
      assertResourceFieldAbsent(reversedRecord, 'resource_first_byte_time');
      assertResourceFieldAbsent(reversedRecord, 'resource_download_time');

      const missingRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource', `resource_url=${missingUrl}`, 'resource_trans=100000000', 'duration=180000000'], 5000);
      expect(missingRecord !== null).assertTrue();
      assertResourceFieldAbsent(missingRecord, 'resource_ttfb');
      assertResourceFieldAbsent(missingRecord, 'resource_first_byte');
      assertResourceFieldAbsent(missingRecord, 'resource_first_byte_time');
      assertResourceTimingField(missingRecord, 'resource_download_time', 150000000, 30000000);
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
      await flushAndAssertUploaded(collector, fragments, record);
    });

    it('rcpStatusZeroResponseShouldFilterOnlyDerivedNetworkError', 0, async () => {
      const viewName = 'rcp_status_zero_filtered_view';
      const resourceUrl = 'http://device.test/rcp-status-zero-filtered';
      const handler = new RcpStatusZeroNetworkErrorHandler(true);
      await FTRUMGlobalManager.getInstance().startView(viewName);

      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true,
        networkErrorHandler: handler
      });
      const response = await runRcpChain(
        config.interceptors ?? [],
        new FakeRcpRequestContext(resourceUrl, 'GET'),
        0,
        '',
        'text/plain'
      );
      await WaitUtils.delay(5);

      expect(response.statusCode).assertEqual(0);
      expect(handler.callCount).assertEqual(1);
      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=0',
        'test_rcp_status_zero_handler=called',
        `view_name=${viewName}`
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const hasNetworkError = await DBAssert.waitForNoSyncRecordContaining(DataType.RUM_APP, [
        'error_source=network',
        'error_type=network_error',
        `resource_url=${resourceUrl}`
      ], 1000);
      const records = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      let resourceCount = 0;
      for (const record of records) {
        if (record.getDataString().includes(`resource_url=${resourceUrl}`)) {
          resourceCount++;
        }
      }

      expect(resourceRecord !== null).assertTrue();
      expect(hasNetworkError).assertTrue();
      expect(resourceCount).assertEqual(1);
      await flushAndAssertUploaded(collector, resourceFragments, resourceRecord);
    });

    it('rcpStatusZeroResponseShouldKeepDefaultErrorForUnfilteredHandlers', 0, async () => {
      const viewName = 'rcp_status_zero_default_error_view';
      const handlers: (RcpStatusZeroNetworkErrorHandler | undefined)[] = [
        new RcpStatusZeroNetworkErrorHandler(false),
        new RcpStatusZeroNetworkErrorHandler(false, true),
        undefined
      ];
      await FTRUMGlobalManager.getInstance().startView(viewName);

      for (let i = 0; i < handlers.length; i++) {
        const resourceUrl = `http://device.test/rcp-status-zero-default-${i}`;
        const handler = handlers[i];
        const config = createFTRCPTrackConfig({
          enableTraceInterceptor: false,
          enableResourceInterceptor: true,
          networkErrorHandler: handler
        });
        const response = await runRcpChain(
          config.interceptors ?? [],
          new FakeRcpRequestContext(resourceUrl, 'GET'),
          0,
          '',
          'text/plain'
        );
        await WaitUtils.delay(5);

        expect(response.statusCode).assertEqual(0);
        if (handler) {
          expect(handler.callCount).assertEqual(1);
        }
        const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
          'resource',
          `resource_url=${resourceUrl}`,
          'resource_status=0',
          `view_name=${viewName}`
        ], 5000);
        const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
          'error',
          'error_source=network',
          'error_type=network_error',
          `resource_url=${resourceUrl}`,
          'resource_status=0',
          `view_name=${viewName}`
        ], 5000);
        expect(resourceRecord !== null).assertTrue();
        expect(errorRecord !== null).assertTrue();
      }
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
        'error_type=network_error',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        `view_name=${viewName}`
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect(errorRecord !== null).assertTrue();
      const resourceAttributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID, viewName };
      const errorAttributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, viewName, requiredFields: ['error_stack'] };
      RumAttributeAssert.record(resourceRecord, resourceAttributes);
      RumAttributeAssert.record(errorRecord, errorAttributes);
      await flushAndAssertResourceAndErrorUploaded(
        collector,
        resourceFragments,
        resourceRecord?.getUuid() ?? '',
        errorFragments,
        errorRecord?.getUuid() ?? ''
      );
      const resourcePayload = await collector.waitForPayloadContaining([resourceRecord!.getUuid()], 5000);
      const errorPayload = await collector.waitForPayloadContaining([errorRecord!.getUuid()], 5000);
      RumAttributeAssert.uploaded(resourcePayload, resourceRecord, resourceAttributes);
      RumAttributeAssert.uploaded(errorPayload, errorRecord, errorAttributes);
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
      await flushAndAssertUploaded(collector, fragments, record);
    });
  });
}
