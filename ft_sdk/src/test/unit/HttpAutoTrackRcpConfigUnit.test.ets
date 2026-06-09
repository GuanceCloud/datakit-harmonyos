import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { rcp } from '@kit.RemoteCommunicationKit';
import {
  createFTRCPTrackConfig,
  RCPResourceInterceptor,
  RCPTraceInterceptor
} from '../../main/ets/components/network/FTHttpAutoTrack';
import { TestReset } from '../helpers/TestReset';

class CustomRcpInterceptor implements rcp.Interceptor {
  async intercept(context: rcp.RequestContext, next: rcp.RequestHandler): Promise<rcp.Response> {
    return await next.handle(context);
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
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('rcpConfigShouldCreateInterceptors', 0, () => {
      const both = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: true
      });
      expect((both.interceptors ?? []).length).assertEqual(2);
      expect((both.interceptors ?? [])[0] instanceof RCPTraceInterceptor).assertTrue();
      expect((both.interceptors ?? [])[1] instanceof RCPResourceInterceptor).assertTrue();

      const traceOnly = createFTRCPTrackConfig({
        enableTraceInterceptor: true,
        enableResourceInterceptor: false
      });
      expect((traceOnly.interceptors ?? []).length).assertEqual(1);
      expect((traceOnly.interceptors ?? [])[0] instanceof RCPTraceInterceptor).assertTrue();

      const resourceOnly = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });
      expect((resourceOnly.interceptors ?? []).length).assertEqual(1);
      expect((resourceOnly.interceptors ?? [])[0] instanceof RCPResourceInterceptor).assertTrue();

      const disabled = createFTRCPTrackConfig({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });
      expect((disabled.interceptors ?? []).length).assertEqual(0);
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
      expect(interceptors[0] instanceof RCPResourceInterceptor).assertTrue();
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
