import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import {
  AxiosChainMethodStore,
  ensureHttpResourceId,
  extractContentLength,
  HttpAutoTrackCompletionStore,
  HttpAutoTrackStateStore,
  mergeResourceTransportMetricsInput,
  normalizeResourceHttpProtocol,
} from '../../main/ets/components/network/FTHttpAutoTrackShared';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { ResourceTransportMetrics } from '../../main/ets/components/rum/bean/ResourceTransportMetrics';
import { TestReset } from '../helpers/TestReset';

const RESOURCE_ID_HEADER = 'X-FT-Resource-ID';

export default function httpAutoTrackSharedUnitTest() {
  describe('HttpAutoTrackSharedUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('resourceIdShouldReuseHeader', 0, () => {
      const generatedHeaders: Record<string, string> = {};
      const generatedId = ensureHttpResourceId(generatedHeaders);

      expect(generatedId.length > 0).assertTrue();
      expect(generatedHeaders[RESOURCE_ID_HEADER]).assertEqual(generatedId);

      const existingHeaders: Record<string, string> = {};
      existingHeaders['x-ft-resource-id'] = 'existing-resource-id';
      const existingId = ensureHttpResourceId(existingHeaders);

      expect(existingId).assertEqual('existing-resource-id');
      expect(existingHeaders[RESOURCE_ID_HEADER]).assertEqual('existing-resource-id');
    });

    it('contentLengthShouldParseValidOnly', 0, () => {
      expect(extractContentLength({ 'content-length': '42' })).assertEqual(42);
      expect(extractContentLength({ 'Content-Length': '100' })).assertEqual(100);
      expect(extractContentLength({ 'content-length': '-1' })).assertEqual(0);
      expect(extractContentLength({ 'content-length': '42abc' })).assertEqual(0);
      expect(extractContentLength({ 'content-length': 'bad-value' })).assertEqual(0);
      expect(extractContentLength({})).assertEqual(0);
      expect(extractContentLength({ 'content-length': '3.5' })).assertEqual(0);
      expect(extractContentLength({ 'content-length': ' 42 ' })).assertEqual(0);
      expect(extractContentLength({ 'content-length': '-12' })).assertEqual(0);
    });

    it('storesShouldClearOverLimit', 0, () => {
      const stateStore = HttpAutoTrackStateStore.getInstance();
      const methodStore = AxiosChainMethodStore.getInstance();

      for (let i = 0; i < Constants.MAX_MAP_SIZE_RESOURCE + 2; i++) {
        const resourceId = `resource-${i}`;
        stateStore.put({
          resourceId: resourceId,
          url: `https://example.com/${i}`,
          method: 'GET',
          startTime: i,
          requestHeaders: {}
        });
        methodStore.put(resourceId, 'GET');
      }

      expect(stateStore.size()).assertEqual(1);
      expect(methodStore.size()).assertEqual(1);
      expect(stateStore.get(`resource-${Constants.MAX_MAP_SIZE_RESOURCE + 1}`) !== undefined).assertTrue();
      expect(methodStore.get(`resource-${Constants.MAX_MAP_SIZE_RESOURCE + 1}`)).assertEqual('GET');
    });

    it('testResetClearSharedStoresAndTraceState', 0, () => {
      const stateStore = HttpAutoTrackStateStore.getInstance();
      const methodStore = AxiosChainMethodStore.getInstance();
      const completionStore = HttpAutoTrackCompletionStore.getInstance();
      const resourceId = 'reset-resource';

      stateStore.put({
        resourceId: resourceId,
        url: 'https://example.com/reset',
        method: 'GET',
        startTime: 1,
        requestHeaders: {}
      });
      methodStore.put(resourceId, 'POST');
      expect(completionStore.tryClaim(resourceId)).assertTrue();
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig().setTraceType(TraceType.JAEGER));
      FTTraceManager.getInstance().getTraceHeader(resourceId, 'https://example.com/reset');

      TestReset.resetP0State();

      expect(stateStore.size()).assertEqual(0);
      expect(methodStore.size()).assertEqual(0);
      expect(completionStore.size()).assertEqual(0);
      expect(FTTraceConfigManager.getInstance().getConfig() === null).assertTrue();
      expect(FTTraceManager.getInstance().getHandlerCount()).assertEqual(0);
    });

    it('completionStoreShouldClaimOneTerminalOwner', 0, () => {
      const completionStore = HttpAutoTrackCompletionStore.getInstance();

      expect(completionStore.tryClaim('one-request')).assertTrue();
      expect(completionStore.tryClaim('one-request')).assertFalse();
      expect(completionStore.tryClaim('another-request')).assertTrue();
    });

    it('platformTransportMetricsShouldOutrankIntegrationAndKeepFalse', 0, () => {
      const metrics = new ResourceTransportMetrics();
      metrics.setRequestBodySize(12, 'integration');
      metrics.setRequestHeaderSize(8, 'integration');
      metrics.setHttpProtocol('http/1.1', 'integration');
      metrics.setConnectionReuse(false, 'integration');
      metrics.setRequestBodySize(16, 'platform');
      metrics.setHttpProtocol('h2', 'platform');

      const snapshot = metrics.snapshot();
      expect(snapshot.requestBodySize).assertEqual(16);
      expect(snapshot.requestHeaderSize).assertEqual(8);
      expect(snapshot.requestSize).assertEqual(24);
      expect(snapshot.httpProtocol).assertEqual('h2');
      expect(snapshot.connectionReuse === false).assertTrue();
    });

    it('integrationMetricMergeShouldPreserveKnownValuesAndFalse', 0, () => {
      const merged = mergeResourceTransportMetricsInput(
        { requestBodySize: 12, connectionReuse: false },
        { requestHeaderSize: 8, httpProtocol: '2' }
      );

      expect(merged !== undefined).assertTrue();
      expect(merged!.requestBodySize).assertEqual(12);
      expect(merged!.requestHeaderSize).assertEqual(8);
      expect(merged!.connectionReuse === false).assertTrue();
      expect(merged!.httpProtocol).assertEqual('2');
      expect(normalizeResourceHttpProtocol(merged!.httpProtocol)).assertEqual('h2');
      expect(normalizeResourceHttpProtocol('HTTP/1.1')).assertEqual('http/1.1');
      expect(normalizeResourceHttpProtocol('spdy')).assertEqual(undefined);
    });

  });
}
