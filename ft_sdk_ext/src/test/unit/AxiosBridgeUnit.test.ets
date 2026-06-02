import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTSDKExtensionBridge } from '@guancecloud/ft_sdk/Index';
import { applyFTAxiosChainMethodBridge, resolveAxiosFullUrl } from '../../main/ets/components/network/FTHttpAutoTrackExt';
import { FakeAxiosRequestConfigTarget, FakeAxiosTarget } from '../helpers/FakeAxiosTarget';
import { TestReset } from '../helpers/TestReset';

export default function axiosBridgeUnitTest() {
  describe('AxiosBridgeUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('axiosChainMethodShouldNormalizeMethodAndStoreResourceMapping', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceId = '';

      try {
        const requestHeaders: Record<string, string> = {};
        requestHeaders['Accept'] = 'application/json';
        const config: FakeAxiosRequestConfigTarget = {
          url: '/users',
          baseURL: 'https://example.com/api',
          method: 'post',
          headers: requestHeaders
        };
        const result = target.requestManager.run(config);
        const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);
        resourceId = normalizedHeaders['X-FT-Resource-ID'];

        expect(result.url).assertEqual('/users');
        expect(result.baseURL).assertEqual('https://example.com/api');
        expect(normalizedHeaders['Accept']).assertEqual('application/json');
        expect(resourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(resourceId)).assertEqual('POST');
      } finally {
        if (resourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceId);
        }
      }
    });

    it('resolveAxiosFullUrlShouldPassThroughAbsoluteUrlAndJoinBaseUrlParameters', 0, () => {
      expect(resolveAxiosFullUrl('/users', 'https://example.com/api')).assertEqual('https://example.com/api/users');
      expect(resolveAxiosFullUrl('users', 'https://example.com/api/')).assertEqual('https://example.com/api/users');
      expect(resolveAxiosFullUrl('https://other.example.com/users', 'https://example.com/api')).assertEqual(
        'https://other.example.com/users'
      );
      expect(resolveAxiosFullUrl('', 'https://example.com/api')).assertEqual('https://example.com/api');
    });

    it('axiosChainMethodShouldDefaultMethodAndHandleMissingHeaders', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceId = '';

      try {
        const emptyConfig: FakeAxiosRequestConfigTarget = {};
        const request = target.requestManager.run(emptyConfig);
        const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(request.headers);
        resourceId = normalizedHeaders['X-FT-Resource-ID'];

        expect(resourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(resourceId)).assertEqual('GET');
        expect(Object.keys(FTSDKExtensionBridge.normalizeHeaders(null)).length).assertEqual(0);
      } finally {
        if (resourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceId);
        }
      }
    });

    it('axiosChainMethodShouldPreserveExistingResourceIdAndCustomHeaders', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      const existingResourceId = 'existing-resource-id';
      const headers: Record<string, string> = {};
      headers['X-FT-Resource-ID'] = existingResourceId;
      headers['X-Custom-Header'] = 'custom';
      const existingResourceConfig: FakeAxiosRequestConfigTarget = {
        method: 'get',
        headers: headers
      };

      const result = target.requestManager.run(existingResourceConfig);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);

      expect(normalizedHeaders['X-FT-Resource-ID']).assertEqual(existingResourceId);
      expect(normalizedHeaders['X-Custom-Header']).assertEqual('custom');
      expect(FTSDKExtensionBridge.resolveAxiosMethod(existingResourceId)).assertEqual('GET');

      FTSDKExtensionBridge.clearAxiosMethod(existingResourceId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(existingResourceId) === undefined).assertTrue();
    });

    it('axiosChainMethodShouldKeepRequestLifecycleIsolated', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let firstId = '';
      let secondId = '';

      try {
        const firstConfig: FakeAxiosRequestConfigTarget = {
          method: 'post'
        };
        const firstResult = target.requestManager.run(firstConfig);
        const firstHeaders = FTSDKExtensionBridge.normalizeHeaders(firstResult.headers);
        firstId = firstHeaders['X-FT-Resource-ID'];

        const secondConfig: FakeAxiosRequestConfigTarget = {
          method: 'get'
        };
        const secondResult = target.requestManager.run(secondConfig);
        const secondHeaders = FTSDKExtensionBridge.normalizeHeaders(secondResult.headers);
        secondId = secondHeaders['X-FT-Resource-ID'];

        expect(firstId === secondId).assertFalse();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(firstId)).assertEqual('POST');
        expect(FTSDKExtensionBridge.resolveAxiosMethod(secondId)).assertEqual('GET');

        FTSDKExtensionBridge.clearAxiosMethod(firstId);
        expect(FTSDKExtensionBridge.resolveAxiosMethod(firstId) === undefined).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(secondId)).assertEqual('GET');
      } finally {
        if (firstId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(firstId);
        }
        if (secondId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(secondId);
        }
      }
    });
  });
}
