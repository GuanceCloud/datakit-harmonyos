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

    it('when method is valid should normalize to uppercase and keep resource id', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceId = '';

      try {
        const requestHeaders: Record<string, string> = {};
        const config: FakeAxiosRequestConfigTarget = {
          method: 'post',
          headers: requestHeaders
        };
        const result = target.requestManager.run(config);
        const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);
        resourceId = normalizedHeaders['X-FT-Resource-ID'];

        expect(resourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(resourceId)).assertEqual('POST');
      } finally {
        if (resourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceId);
        }
      }

    });

    it('when method is missing should default to GET and uppercase valid method input should be normalized', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let noMethodResourceId = '';
      let lowerMethodResourceId = '';
      let emptyMethodResourceId = '';

      try {
        const withoutMethodConfig: FakeAxiosRequestConfigTarget = {};
        const requestWithoutMethod = target.requestManager.run(withoutMethodConfig);
        const normalizedWithoutMethod = FTSDKExtensionBridge.normalizeHeaders(requestWithoutMethod.headers);
        noMethodResourceId = normalizedWithoutMethod['X-FT-Resource-ID'];
        expect(noMethodResourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(noMethodResourceId)).assertEqual('GET');

        const lowerHeaders: Record<string, string> = {};
        const lowerMethodConfig: FakeAxiosRequestConfigTarget = {
          method: 'post',
          headers: lowerHeaders
        };
        const requestWithLowerMethod = target.requestManager.run(lowerMethodConfig);
        const normalizedWithLowerMethod = FTSDKExtensionBridge.normalizeHeaders(requestWithLowerMethod.headers);
        lowerMethodResourceId = normalizedWithLowerMethod['X-FT-Resource-ID'];
        expect(lowerMethodResourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(lowerMethodResourceId)).assertEqual('POST');

        const emptyHeaders: Record<string, string> = {};
        const emptyMethodConfig: FakeAxiosRequestConfigTarget = {
          method: '',
          headers: emptyHeaders
        };
        const requestWithEmptyMethod = target.requestManager.run(emptyMethodConfig);
        const normalizedWithEmptyMethod = FTSDKExtensionBridge.normalizeHeaders(requestWithEmptyMethod.headers);
        emptyMethodResourceId = normalizedWithEmptyMethod['X-FT-Resource-ID'];
        expect(emptyMethodResourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(emptyMethodResourceId)).assertEqual('GET');
      } finally {
        if (noMethodResourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(noMethodResourceId);
        }
        if (lowerMethodResourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(lowerMethodResourceId);
        }
        if (emptyMethodResourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(emptyMethodResourceId);
        }
      }
    });

    it('when resolveAxiosFullUrl receives url/baseURL variations should return stable resolution', 0, () => {
      expect(resolveAxiosFullUrl('/users', 'https://example.com/api')).assertEqual('https://example.com/api/users');
      expect(resolveAxiosFullUrl('users', 'https://example.com/api/')).assertEqual('https://example.com/api/users');
      expect(resolveAxiosFullUrl('https://other.example.com/users', 'https://example.com/api')).assertEqual('https://other.example.com/users');
      expect(resolveAxiosFullUrl('', 'https://example.com/api')).assertEqual('https://example.com/api');
    });

    it('when config headers is undefined should not throw and bridge null normalization should stay safe', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceIdFromUndefined = '';

      try {
        const undefinedHeadersConfig: FakeAxiosRequestConfigTarget = {
          method: 'GET',
          headers: undefined
        };
        const undefinedHeadersRequest = target.requestManager.run(undefinedHeadersConfig);
        const undefinedNormalized = FTSDKExtensionBridge.normalizeHeaders(undefinedHeadersRequest.headers);
        resourceIdFromUndefined = undefinedNormalized['X-FT-Resource-ID'];
        expect(resourceIdFromUndefined.length > 0).assertTrue();

        const nullNormalized = FTSDKExtensionBridge.normalizeHeaders(null);
        expect(Object.keys(nullNormalized).length).assertEqual(0);
      } finally {
        if (resourceIdFromUndefined.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceIdFromUndefined);
        }
      }
    });

    it('when request carries baseURL and url should preserve custom headers and default method to GET', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceId = '';

      try {
        const requestHeadersWithAccept: Record<string, string> = {};
        requestHeadersWithAccept['Accept'] = 'application/json';
        const config: FakeAxiosRequestConfigTarget = {
          baseURL: 'https://example.com/api',
          url: '/users',
          headers: requestHeadersWithAccept
        };
        const result = target.requestManager.run(config);
        const normalizedHeadersWithAccept = FTSDKExtensionBridge.normalizeHeaders(result.headers);
        resourceId = normalizedHeadersWithAccept['X-FT-Resource-ID'];

        expect(result.baseURL).assertEqual('https://example.com/api');
        expect(result.url).assertEqual('/users');
        expect(normalizedHeadersWithAccept['Accept']).assertEqual('application/json');
        expect(resourceId.length > 0).assertTrue();
        expect(FTSDKExtensionBridge.resolveAxiosMethod(resourceId)).assertEqual('GET');
      } finally {
        if (resourceId.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceId);
        }
      }
    });

    it('when existing X-FT-Resource-ID present should preserve it and allow cleanup', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      const existingResourceId = 'existing-resource-id';
      const existingRequestHeaders: Record<string, string> = {};
      existingRequestHeaders['X-FT-Resource-ID'] = existingResourceId;
      existingRequestHeaders['X-Custom-Header'] = 'custom';
      const config: FakeAxiosRequestConfigTarget = {
        method: 'get',
        headers: existingRequestHeaders
      };

      const result = target.requestManager.run(config);
      const normalizedExistingHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);

      expect(normalizedExistingHeaders['X-FT-Resource-ID']).assertEqual(existingResourceId);
      expect(normalizedExistingHeaders['X-Custom-Header']).assertEqual('custom');
      expect(FTSDKExtensionBridge.resolveAxiosMethod(existingResourceId)).assertEqual('GET');

      FTSDKExtensionBridge.clearAxiosMethod(existingResourceId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(existingResourceId) === undefined).assertTrue();
    });

    it('when existing x-ft-resource-id is lowercase should preserve id and not replace', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      const lowerCaseResourceId = 'lowercase-preserve-id';
      const headers: Record<string, string> = {};
      headers['x-ft-resource-id'] = lowerCaseResourceId;
      const requestConfig: FakeAxiosRequestConfigTarget = {
        method: 'post',
        headers: headers
      };

      const result = target.requestManager.run(requestConfig);
      const normalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(result.headers);

      expect(normalizedHeaders['X-FT-Resource-ID']).assertEqual(lowerCaseResourceId);
      expect(normalizedHeaders['x-ft-resource-id'] === lowerCaseResourceId).assertTrue();
      expect(FTSDKExtensionBridge.resolveAxiosMethod(lowerCaseResourceId)).assertEqual('POST');

      FTSDKExtensionBridge.clearAxiosMethod(lowerCaseResourceId);
      expect(FTSDKExtensionBridge.resolveAxiosMethod(lowerCaseResourceId) === undefined).assertTrue();
    });

    it('when same target reuses interceptor id should keep lifecycle isolated and clearable', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let firstId = '';
      let secondId = '';

      try {
        const firstConfig: FakeAxiosRequestConfigTarget = {
          method: 'post'
        };
        const firstResult = target.requestManager.run(firstConfig);
        const firstNormalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(firstResult.headers);
        firstId = firstNormalizedHeaders['X-FT-Resource-ID'];
        expect(FTSDKExtensionBridge.resolveAxiosMethod(firstId)).assertEqual('POST');

        const secondConfig: FakeAxiosRequestConfigTarget = {
          method: 'get'
        };
        const secondResult = target.requestManager.run(secondConfig);
        const secondNormalizedHeaders = FTSDKExtensionBridge.normalizeHeaders(secondResult.headers);
        secondId = secondNormalizedHeaders['X-FT-Resource-ID'];
        expect(FTSDKExtensionBridge.resolveAxiosMethod(secondId)).assertEqual('GET');

        expect(firstId === secondId).assertFalse();
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

    it('when url/baseURL missing should fallback by resolver and avoid malformed request url', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosChainMethodBridge(target);
      let resourceIdFromMissingUrl = '';
      let resourceIdFromMissingBaseUrl = '';
      let resourceIdFromBothMissing = '';

      try {
        const bothMissingConfig: FakeAxiosRequestConfigTarget = {};
        const bothMissingRequest = target.requestManager.run(bothMissingConfig);
        const bothMissingNormalized = FTSDKExtensionBridge.normalizeHeaders(bothMissingRequest.headers);
        resourceIdFromBothMissing = bothMissingNormalized['X-FT-Resource-ID'];
        expect(bothMissingRequest.url === undefined).assertTrue();
        expect(resolveAxiosFullUrl(bothMissingRequest.url, bothMissingRequest.baseURL)).assertEqual('');
        expect(resourceIdFromBothMissing.length > 0).assertTrue();

        const baseUrlMissingConfig: FakeAxiosRequestConfigTarget = {
          url: '/users'
        };
        const baseUrlMissing = target.requestManager.run(baseUrlMissingConfig);
        expect(baseUrlMissing.url).assertEqual('/users');
        const baseNormalized = FTSDKExtensionBridge.normalizeHeaders(baseUrlMissing.headers);
        resourceIdFromMissingBaseUrl = baseNormalized['X-FT-Resource-ID'];
        expect(resourceIdFromMissingBaseUrl.length > 0).assertTrue();

        const bothProvidedConfig: FakeAxiosRequestConfigTarget = {
          url: '/users',
          baseURL: 'https://example.com/api'
        };
        const bothProvided = target.requestManager.run(bothProvidedConfig);
        expect(bothProvided.url).assertEqual('/users');
        expect(resolveAxiosFullUrl(bothProvided.url, bothProvided.baseURL)).assertEqual('https://example.com/api/users');
        const providedNormalized = FTSDKExtensionBridge.normalizeHeaders(bothProvided.headers);
        resourceIdFromMissingUrl = providedNormalized['X-FT-Resource-ID'];
        expect(resourceIdFromMissingUrl.length > 0).assertTrue();
      } finally {
        if (resourceIdFromBothMissing.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceIdFromBothMissing);
        }
        if (resourceIdFromMissingBaseUrl.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceIdFromMissingBaseUrl);
        }
        if (resourceIdFromMissingUrl.length > 0) {
          FTSDKExtensionBridge.clearAxiosMethod(resourceIdFromMissingUrl);
        }
      }
    });
  });
}
