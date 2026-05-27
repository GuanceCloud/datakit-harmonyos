import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTTraceConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import {
  AxiosChainMethodStore,
  buildAutoTrackResourceId,
  ensureHttpResourceId,
  extractContentLength,
  HttpAutoTrackStateStore,
  normalizeObjectHeaders,
  resolveAxiosChainMethod
} from '../../main/ets/components/network/FTHttpAutoTrackShared';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';
import { TestReset } from '../helpers/TestReset';

const RESOURCE_ID_HEADER = 'X-FT-Resource-ID';

class ObjectHeaderValue {
  public name: string;

  constructor(name: string) {
    this.name = name;
  }
}

export default function httpAutoTrackSharedUnitTest() {
  describe('HttpAutoTrackSharedUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('normalizeObjectHeadersShouldKeepSupportedValues', 0, () => {
      const rawHeaders: Record<string, Object | null> = {};
      rawHeaders['String-Header'] = 'value' as Object;
      rawHeaders['Array-Header'] = ['first', 'second'] as Object;
      rawHeaders['Number-Header'] = 100 as Object;
      rawHeaders['Object-Header'] = new ObjectHeaderValue('value') as Object;
      rawHeaders['Null-Header'] = null;

      const headers = normalizeObjectHeaders(rawHeaders);

      expect(headers['String-Header']).assertEqual('value');
      expect(headers['Array-Header']).assertEqual('first');
      expect(headers['Number-Header']).assertEqual('100');
      expect(headers['Object-Header']).assertEqual('[object Object]');
      expect(headers['Null-Header'] === undefined).assertTrue();
    });

    it('ensureHttpResourceIdShouldGenerateAndReuseCanonicalHeader', 0, () => {
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

    it('extractContentLengthShouldParseOnlyValidHeaderValues', 0, () => {
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

    it('axiosMethodStoreShouldResolveMethodFromResourceHeader', 0, () => {
      const store = AxiosChainMethodStore.getInstance();
      const uniqueId = 'resource-id';
      const headers: Record<string, string> = {};
      headers[RESOURCE_ID_HEADER] = uniqueId;

      store.put(uniqueId, 'POST');
      expect(resolveAxiosChainMethod(headers)).assertEqual('POST');

      store.delete(uniqueId);
      expect(resolveAxiosChainMethod(headers)).assertEqual('UNKNOWN');
    });

    it('httpAutoTrackStateStoreShouldPutGetDeleteAndClearState', 0, () => {
      const store = HttpAutoTrackStateStore.getInstance();
      const resourceId = buildAutoTrackResourceId('GET', 'https://example.com', 'id-1');

      store.put({
        resourceId: resourceId,
        url: 'https://example.com',
        method: 'GET',
        startTime: 1,
        requestHeaders: {}
      });

      expect(store.size()).assertEqual(1);
      expect(store.get(resourceId)!.method).assertEqual('GET');

      store.delete(resourceId);
      expect(store.get(resourceId) === undefined).assertTrue();

      store.put({
        resourceId: resourceId,
        url: 'https://example.com',
        method: 'GET',
        startTime: 1,
        requestHeaders: {}
      });
      store.clear();
      expect(store.size()).assertEqual(0);
    });

    it('storesShouldClearWhenResourceMapLimitIsExceeded', 0, () => {
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

    it('testResetShouldClearSharedStoresAndTraceState', 0, () => {
      const stateStore = HttpAutoTrackStateStore.getInstance();
      const methodStore = AxiosChainMethodStore.getInstance();
      const resourceId = 'reset-resource';

      stateStore.put({
        resourceId: resourceId,
        url: 'https://example.com/reset',
        method: 'GET',
        startTime: 1,
        requestHeaders: {}
      });
      methodStore.put(resourceId, 'POST');
      FTTraceConfigManager.getInstance().initWithConfig(new FTTraceConfig().setTraceType(TraceType.JAEGER));
      FTTraceManager.getInstance().getTraceHeader(resourceId, 'https://example.com/reset');

      TestReset.resetP0State();

      expect(stateStore.size()).assertEqual(0);
      expect(methodStore.size()).assertEqual(0);
      expect(FTTraceConfigManager.getInstance().getConfig() === null).assertTrue();
      expect(FTTraceManager.getInstance().getHandlerCount()).assertEqual(0);
    });

    it('normalizeObjectHeadersShouldConvertNonStringValuesDeterministically', 0, () => {
      const rawHeaders: Record<string, Object | null> = {};
      rawHeaders['x-number'] = 123 as Object;
      rawHeaders['x-bool'] = false as Object;
      rawHeaders['x-array'] = ['first', 'second'] as Object;
      rawHeaders['x-object'] = new ObjectHeaderValue('value') as Object;
      rawHeaders['x-null'] = null;
      const headers = normalizeObjectHeaders(rawHeaders);

      expect(headers['x-number']).assertEqual('123');
      expect(headers['x-bool']).assertEqual('false');
      expect(headers['x-array']).assertEqual('first');
      expect(headers['x-object']).assertEqual('[object Object]');
      expect(headers['x-null'] === undefined).assertTrue();
    });

    it('when state/method stores are intentionally reused should clear on explicit reset', 0, () => {
      const stateStore = HttpAutoTrackStateStore.getInstance();
      const methodStore = AxiosChainMethodStore.getInstance();
      const reusedResourceId = 'reused-id';

      stateStore.put({
        resourceId: 'resource-reused',
        url: 'https://example.com/reused',
        method: 'GET',
        startTime: 1,
        requestHeaders: {
          'X-FT-Resource-ID': reusedResourceId
        }
      });
      stateStore.put({
        resourceId: 'resource-reused',
        url: 'https://example.com/reused',
        method: 'POST',
        startTime: 2,
        requestHeaders: {
          'X-FT-Resource-ID': reusedResourceId
        }
      });
      methodStore.put(reusedResourceId, 'POST');

      expect(stateStore.size()).assertEqual(1);
      expect(methodStore.get(reusedResourceId)).assertEqual('POST');

      TestReset.resetP0State();

      expect(stateStore.size()).assertEqual(0);
      expect(methodStore.size()).assertEqual(0);
      expect(methodStore.get(reusedResourceId) === undefined).assertTrue();
    });
  });
}
