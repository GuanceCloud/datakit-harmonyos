import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
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

class FakeRcpUrl {
  href: string;

  constructor(href: string) {
    this.href = href;
  }
}

class FakeRcpRequest {
  url: FakeRcpUrl;
  method: string;
  headers: Record<string, Object>;

  constructor(url: string, method: string) {
    this.url = new FakeRcpUrl(url);
    this.method = method;
    this.headers = {};
  }
}

class FakeRcpRequestContext {
  request: FakeRcpRequest;

  constructor(url: string, method: string) {
    this.request = new FakeRcpRequest(url, method);
  }
}

class FakeRcpTimeInfo {
  nameLookupTimeMs: number = 1;
  connectTimeMs: number = 2;
  tlsHandshakeTimeMs: number = 3;
  startTransferTimeMs: number = 5;
  totalTimeMs: number = 8;
}

class FakeRcpResponse {
  statusCode: number;
  headers: Record<string, Object>;
  body: string;
  timeInfo: FakeRcpTimeInfo;

  constructor(statusCode: number, body: string, contentType: string) {
    this.statusCode = statusCode;
    this.body = body;
    this.timeInfo = new FakeRcpTimeInfo();
    this.headers = {};
    this.headers['content-type'] = contentType as Object;
    this.headers['content-length'] = String(body.length) as Object;
  }
}

class FakeRcpTerminalHandler implements rcp.RequestHandler {
  private statusCode: number;
  private body: string;
  private contentType: string;

  constructor(statusCode: number, body: string, contentType: string) {
    this.statusCode = statusCode;
    this.body = body;
    this.contentType = contentType;
  }

  async handle(_context: rcp.RequestContext): Promise<rcp.Response> {
    return new FakeRcpResponse(this.statusCode, this.body, this.contentType) as Object as rcp.Response;
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
  contentType: string
): Promise<rcp.Response> {
  const terminal = new FakeRcpTerminalHandler(statusCode, body, contentType);
  const handler = new FakeRcpChainHandler(interceptors, 0, terminal);
  return await handler.handle(context as Object as rcp.RequestContext);
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

    it('createFTRCPTrackConfigShouldWriteUploadAndDeleteResource', 0, async () => {
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

    it('manualRCPInterceptorsShouldInjectTraceAndWriteResource', 0, async () => {
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
