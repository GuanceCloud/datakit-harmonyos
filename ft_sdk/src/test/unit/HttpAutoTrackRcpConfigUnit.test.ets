import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { rcp } from '@kit.RemoteCommunicationKit';
import json from '@ohos.util.json';
import { FTTraceInterceptor, HttpRequestData, HttpResponseData } from '../../main/ets/components/trace/FTTraceInterceptor';
import {
  createFTRCPTrackConfig,
  RCPResourceInterceptor,
  RCPTraceInterceptor
} from '../../main/ets/components/network/FTHttpAutoTrack';
import { FTRUMConfig } from '../../main/ets/components/Configs';
import { FTInTakeUrlHandler } from '../../main/ets/components/http/FTInTakeUrlHandler';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { FTNetworkErrorContext, FTNetworkErrorHandler, FTNetworkResourceFields } from '../../main/ets/components/network/FTNetworkErrorHandler';
import { TestReset } from '../helpers/TestReset';

class IgnoredRcpResourceUrlHandler extends FTInTakeUrlHandler {
  public isInTakeUrl(url: string): boolean {
    return url.includes('/ignored-resource');
  }
}

class RcpGlobalNetworkErrorHandler implements FTNetworkErrorHandler {
  onExceptionWithFilter(_context: FTNetworkErrorContext, _resourceFields: FTNetworkResourceFields): boolean {
    return false;
  }
}

class RecordingRcpNetworkErrorHandler implements FTNetworkErrorHandler {
  callCount: number = 0;
  lastContext: FTNetworkErrorContext | undefined;
  private readonly suppressNetworkError: boolean;
  private readonly throwsError: boolean;

  constructor(suppressNetworkError: boolean, throwsError: boolean = false) {
    this.suppressNetworkError = suppressNetworkError;
    this.throwsError = throwsError;
  }

  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    this.callCount++;
    this.lastContext = context;
    resourceFields['test_rcp_network_error_handler'] = true;
    if (this.throwsError) {
      throw new Error('RCP network error handler failed');
    }
    return this.suppressNetworkError;
  }
}

interface RcpResourceInterceptorTestAccess {
  networkErrorHandler?: FTNetworkErrorHandler;
}

class CustomRcpInterceptor implements rcp.Interceptor {
  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    return await next.handle(context);
  }
}

interface RcpTraceTestAccess {
  isEnabled: boolean;
  traceInterceptor: FTTraceInterceptor;
}

class TestRcpUrl {
  href: string;

  constructor(href: string) {
    this.href = href;
  }
}

class TestRcpRequest {
  readonly id: string;
  url: TestRcpUrl;
  method: string;
  headers: rcp.RequestHeaders;

  constructor(url: string, method: string, headers: rcp.RequestHeaders = {}) {
    this.id = url;
    this.url = new TestRcpUrl(url);
    this.method = method;
    this.headers = headers;
  }
}

class TestRcpSession {
  close(): void {}
}

function createTestRcpRequest(url: string, method: string, headers: rcp.RequestHeaders = {}): rcp.Request {
  return new TestRcpRequest(url, method, headers) as Object as rcp.Request;
}

function createTestRcpSession(): rcp.Session {
  return new TestRcpSession() as Object as rcp.Session;
}

class ThrowingTraceInterceptor implements FTTraceInterceptor {
  requestCalls: number = 0;
  responseCalls: number = 0;
  private phase: string;
  constructor(phase: string) { this.phase = phase; }
  interceptRequest(request: HttpRequestData): HttpRequestData {
    this.requestCalls++;
    if (this.phase === 'request') throw new Error('trace request failed');
    return request;
  }
  interceptResponse(response: HttpResponseData): HttpResponseData {
    this.responseCalls++;
    if (this.phase === 'response') throw new Error('trace response failed');
    return response;
  }
}

class SingleDispatchResponse implements rcp.Response {
  readonly statusCode: number;
  readonly headers: rcp.ResponseHeaders = {};
  readonly request: rcp.Request;
  constructor(request: rcp.Request, statusCode: number = 201) {
    this.request = request;
    this.statusCode = statusCode;
  }
  toString(): string | null { return '{}'; }
  toJSON(): object | null;
  toJSON(options: json.ParseOptions): object | null;
  toJSON(_options?: json.ParseOptions): object | null { return null; }
}

class SingleDispatchHandler implements rcp.RequestHandler {
  calls: number = 0;
  readonly response: rcp.Response;
  readonly failure: Error | null;
  constructor(response: rcp.Response, failure: Error | null) {
    this.response = response;
    this.failure = failure;
  }
  async handle(_context: rcp.RequestContext): Promise<rcp.Response> {
    this.calls++;
    if (this.failure) throw this.failure;
    return this.response;
  }
}

interface PlainRcpFailure {
  code: number;
  message: string;
}

class RejectingRcpHandler implements rcp.RequestHandler {
  failure: PlainRcpFailure = { code: 1007900028, message: '请求失败' };
  handle(_context: rcp.RequestContext): Promise<rcp.Response> {
    return Promise.reject<rcp.Response>(this.failure);
  }
}

function getTracing(config: rcp.SessionConfiguration): rcp.TracingConfiguration {
  expect(config.requestConfiguration !== undefined).assertTrue();
  expect(config.requestConfiguration!.tracing !== undefined).assertTrue();
  return config.requestConfiguration!.tracing!;
}

function getInfoToCollect(config: rcp.SessionConfiguration): rcp.InfoToCollect {
  const tracing = getTracing(config);
  expect(tracing.infoToCollect !== undefined).assertTrue();
  return tracing.infoToCollect!;
}

export default function httpAutoTrackRcpConfigUnitTest() {
  describe('HttpAutoTrackRcpConfigUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
      FTRUMConfigManager.getInstance().release();
    });

    afterEach(() => {
      TestReset.resetP0State();
      FTRUMConfigManager.getInstance().release();
    });

    it('rcpShouldPreservePlainBusinessErrorRejection', 0, async () => {
      const handler = new RecordingRcpNetworkErrorHandler(true);
      const interceptor = new RCPResourceInterceptor(handler);
      const request = createTestRcpRequest('https://example.com/plain-error', 'GET');
      const context: rcp.RequestContext = { request, session: createTestRcpSession() };
      const next = new RejectingRcpHandler();
      let rejected = false;
      try {
        await interceptor.intercept(context, next);
      } catch (error) {
        rejected = true;
        expect(error === next.failure).assertTrue();
      }
      expect(rejected).assertTrue();
      expect(handler.callCount).assertEqual(1);
      expect(handler.lastContext!.exception === next.failure).assertTrue();
      expect(handler.lastContext!.errorCode).assertEqual(1007900028);
      expect(handler.lastContext!.kind).assertEqual('timeout');
    });

    it('rcpTraceShouldDispatchExactlyOnce', 0, async () => {
      for (const phase of ['success', 'transport', 'request', 'response']) {
        const trace = new ThrowingTraceInterceptor(phase);
        const interceptor = new RCPTraceInterceptor();
        const access = interceptor as Object as RcpTraceTestAccess;
        access.isEnabled = true;
        access.traceInterceptor = trace;
        const request = createTestRcpRequest('https://example.com/orders', 'POST', {
          'X-FT-Resource-ID': `dispatch-${phase}`,
          'x-datadog-trace-id': '123', 'x-datadog-parent-id': '456'
        });
        const session = createTestRcpSession();
        const context: rcp.RequestContext = { request, session };
        const response = new SingleDispatchResponse(request);
        const failure = phase === 'transport' ? new Error('Timeout was reached') : null;
        const next = new SingleDispatchHandler(response, failure);
        let caught: Object | null = null;
        try {
          const actual = await interceptor.intercept(context, next);
          expect(actual === response).assertTrue();
        } catch (error) {
          caught = error as Object;
        } finally {
          session.close();
        }
        expect(next.calls).assertEqual(1);
        expect(caught === failure).assertTrue();
        expect(trace.requestCalls).assertEqual(1);
        expect(trace.responseCalls).assertEqual(phase === 'transport' ? 0 : 1);
      }
    });

    it('rcpResourceShouldBypassFilteredUrl', 0, async () => {
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true)
        .setResourceUrlHandler(new IgnoredRcpResourceUrlHandler()));

      const interceptor = new RCPResourceInterceptor();
      const request = createTestRcpRequest('https://example.com/ignored-resource', 'GET');
      const session = createTestRcpSession();
      const context: rcp.RequestContext = { request, session };
      const response = new SingleDispatchResponse(request);
      const next = new SingleDispatchHandler(response, null);
      try {
        const actual = await interceptor.intercept(context, next);
        expect(actual === response).assertTrue();
        expect(next.calls).assertEqual(1);
      } finally {
        session.close();
      }
    });

    it('rcpStatusZeroResponseShouldInvokeHandlerAndPreserveResponse', 0, async () => {
      const handler = new RecordingRcpNetworkErrorHandler(true);
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true)
        .setNetworkErrorHandler(handler));
      const interceptors = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      }).interceptors ?? [];
      const interceptor = interceptors[0] as RCPResourceInterceptor;
      const request = createTestRcpRequest('https://example.com/status-zero', 'GET');
      const session = createTestRcpSession();
      const context: rcp.RequestContext = { request, session };
      const response = new SingleDispatchResponse(request, 0);
      const next = new SingleDispatchHandler(response, null);
      try {
        const actual = await interceptor.intercept(context, next);
        expect(actual === response).assertTrue();
        expect(next.calls).assertEqual(1);
        expect(handler.callCount).assertEqual(1);
        expect(handler.lastContext !== undefined).assertTrue();
        expect(handler.lastContext!.source).assertEqual('rcp');
        expect(handler.lastContext!.message.includes('without an HTTP response')).assertTrue();
      } finally {
        session.close();
      }
    });

    it('rcpStatusZeroResponseHandlerFailureShouldNotChangeResponse', 0, async () => {
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true));

      const handler = new RecordingRcpNetworkErrorHandler(false, true);
      const interceptor = new RCPResourceInterceptor(handler);
      const request = createTestRcpRequest('https://example.com/status-zero-handler-failure', 'GET');
      const session = createTestRcpSession();
      const context: rcp.RequestContext = { request, session };
      const response = new SingleDispatchResponse(request, 0);
      try {
        const actual = await interceptor.intercept(context, new SingleDispatchHandler(response, null));
        expect(actual === response).assertTrue();
        expect(handler.callCount).assertEqual(1);
      } finally {
        session.close();
      }
    });

    it('rcpHttpErrorResponsesShouldNotInvokeLocalNetworkErrorHandler', 0, async () => {
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true));

      const handler = new RecordingRcpNetworkErrorHandler(true);
      const interceptor = new RCPResourceInterceptor(handler);
      for (const statusCode of [404, 500]) {
        const request = createTestRcpRequest(`https://example.com/http-${statusCode}`, 'GET');
        const session = createTestRcpSession();
        const context: rcp.RequestContext = { request, session };
        const response = new SingleDispatchResponse(request, statusCode);
        try {
          const actual = await interceptor.intercept(context, new SingleDispatchHandler(response, null));
          expect(actual === response).assertTrue();
        } finally {
          session.close();
        }
      }
      expect(handler.callCount).assertEqual(0);
    });

    it('rcpConfigShouldCreateInterceptors', 0, () => {
      const networkErrorHandler = new RcpGlobalNetworkErrorHandler();
      const both = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: true,
        networkErrorHandler
      });
      const bothInterceptors = both.interceptors ?? [];
      expect(bothInterceptors.length).assertEqual(2);
      expect(bothInterceptors[0] !== bothInterceptors[1]).assertTrue();
      expect((bothInterceptors[1] as Object as RcpResourceInterceptorTestAccess).networkErrorHandler ===
        networkErrorHandler).assertTrue();

      const traceOnly = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      });
      expect((traceOnly.interceptors ?? []).length).assertEqual(1);

      const resourceOnly = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true,
        networkErrorHandler
      });
      const resourceInterceptors = resourceOnly.interceptors ?? [];
      expect(resourceInterceptors.length).assertEqual(1);
      expect((resourceInterceptors[0] as Object as RcpResourceInterceptorTestAccess).networkErrorHandler ===
        networkErrorHandler).assertTrue();

      const disabled = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });
      expect((disabled.interceptors ?? []).length).assertEqual(0);
    });

    it('rcpConfigShouldUseGlobalNetworkErrorHandlerUnlessOverridden', 0, () => {
      const globalHandler = new RcpGlobalNetworkErrorHandler();
      const explicitHandler = new RcpGlobalNetworkErrorHandler();
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setNetworkErrorHandler(globalHandler));

      const globalInterceptors = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      }).interceptors ?? [];
      const globalResource = globalInterceptors[0] as Object as RcpResourceInterceptorTestAccess;
      expect(globalResource.networkErrorHandler === globalHandler).assertTrue();

      const explicitInterceptors = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true,
        networkErrorHandler: explicitHandler
      }).interceptors ?? [];
      const explicitResource = explicitInterceptors[0] as Object as RcpResourceInterceptorTestAccess;
      expect(explicitResource.networkErrorHandler === explicitHandler).assertTrue();

      const disabledInterceptors = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true,
        networkErrorHandler: null
      }).interceptors ?? [];
      const disabledResource = disabledInterceptors[0] as Object as RcpResourceInterceptorTestAccess;
      expect(disabledResource.networkErrorHandler === undefined).assertTrue();
    });

    it('rcpConfigShouldAppendCustom', 0, () => {
      const customInterceptor = new CustomRcpInterceptor();
      const headers: Record<string, string> = {};
      headers['X-Test'] = 'keep';
      const config = createFTRCPTrackConfig({
        baseAddress: 'https://example.com',
        headers: headers,
        interceptors: [customInterceptor],
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });
      const interceptors = config.interceptors ?? [];

      expect(config.baseAddress).assertEqual('https://example.com');
      expect(config.headers!['X-Test']).assertEqual('keep');
      expect(interceptors.length).assertEqual(2);
      expect(interceptors[1] === customInterceptor).assertTrue();
    });

    it('rcpConfigShouldUseDefaultTracing', 0, () => {
      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });
      const tracing = getTracing(config);
      const infoToCollect = getInfoToCollect(config);

      expect(tracing.verbose).assertFalse();
      expect(tracing.collectTimeInfo).assertTrue();
      expect(infoToCollect.incomingHeader).assertTrue();
      expect(infoToCollect.outgoingHeader).assertTrue();
      expect(infoToCollect.incomingData).assertFalse();
      expect(infoToCollect.outgoingData).assertFalse();
    });

    it('rcpConfigShouldUseCustomTracing', 0, () => {
      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false,
        requestConfiguration: {
          tracing: {
            verbose: true,
            infoToCollect: {
              incomingHeader: false,
              outgoingHeader: false,
              incomingData: true,
              outgoingData: true
            },
            collectTimeInfo: false
          }
        }
      });
      const tracing = getTracing(config);
      const infoToCollect = getInfoToCollect(config);

      expect(tracing.verbose).assertTrue();
      expect(tracing.collectTimeInfo).assertFalse();
      expect(infoToCollect.incomingHeader).assertFalse();
      expect(infoToCollect.outgoingHeader).assertFalse();
      expect(infoToCollect.incomingData).assertTrue();
      expect(infoToCollect.outgoingData).assertTrue();
    });

    it('rcpConfigShouldFallbackCollectInfo', 0, () => {
      const config = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false,
        requestConfiguration: {
          tracing: {
            verbose: true,
            collectTimeInfo: false
          }
        }
      });
      const tracing = getTracing(config);
      const infoToCollect = getInfoToCollect(config);

      expect(tracing.verbose).assertTrue();
      expect(tracing.collectTimeInfo).assertFalse();
      expect(infoToCollect.incomingHeader).assertTrue();
      expect(infoToCollect.outgoingHeader).assertTrue();
      expect(infoToCollect.incomingData).assertFalse();
      expect(infoToCollect.outgoingData).assertFalse();
    });
  });
}
