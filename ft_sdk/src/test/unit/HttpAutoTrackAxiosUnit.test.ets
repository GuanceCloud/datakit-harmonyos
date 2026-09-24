import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  applyFTAxiosTrack,
  FTAxiosErrorTarget,
  FTAxiosRequestConfigTarget,
  FTAxiosResponseTarget
} from '../../main/ets/components/network/FTHttpAutoTrack';
import { FTRUMConfig } from '../../main/ets/components/Configs';
import { FTInTakeUrlHandler } from '../../main/ets/components/http/FTInTakeUrlHandler';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { FTNetworkErrorContext, FTNetworkErrorHandler, FTNetworkResourceFields } from '../../main/ets/components/network/FTNetworkErrorHandler';
import { FTResourceTransportMetricsInput } from '../../main/ets/components/network/FTHttpAutoTrackShared';
import { TestReset } from '../helpers/TestReset';

const FT_AXIOS_AUTOTRACK_CONTEXT_KEY = '__ftAxiosAutoTrackState';

class IgnoredAxiosResourceUrlHandler extends FTInTakeUrlHandler {
  public isInTakeUrl(url: string): boolean {
    return url.includes('/api');
  }
}

interface StoredAxiosAutoTrackState {
  resourceEnabled: boolean;
  networkErrorHandler?: FTNetworkErrorHandler;
  platformTransportMetrics?: FTResourceTransportMetricsInput;
  headerInferredTransportMetrics?: FTResourceTransportMetricsInput;
}

interface FakeAxiosUploadProgress {
  loaded?: number;
  total?: number;
}

class AxiosGlobalNetworkErrorHandler implements FTNetworkErrorHandler {
  onExceptionWithFilter(_context: FTNetworkErrorContext, _resourceFields: FTNetworkResourceFields): boolean {
    return false;
  }
}

class CountingAxiosNetworkErrorHandler implements FTNetworkErrorHandler {
  callCount: number = 0;

  onExceptionWithFilter(_context: FTNetworkErrorContext, _resourceFields: FTNetworkResourceFields): boolean {
    this.callCount++;
    return true;
  }
}

type AxiosRequestFulfilled = (value: FTAxiosRequestConfigTarget) => FTAxiosRequestConfigTarget | Promise<FTAxiosRequestConfigTarget>;
type AxiosResponseFulfilled = (value: FTAxiosResponseTarget) => FTAxiosResponseTarget | Promise<FTAxiosResponseTarget>;
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

class FakeAxiosHeaders {
}

class FakeAxiosThrowingHeaders {
  toJSON(): Object {
    throw new Error('Axios response headers cannot be serialized');
  }
}

class FakeAxiosRequestConfig implements FTAxiosRequestConfigTarget {
  url?: string;
  method?: string;
  headers?: Object;
  context?: Object;
  onUploadProgress?: (progress: FakeAxiosUploadProgress) => void;

  constructor(context: Record<string, Object>) {
    this.url = 'https://example.com/api';
    this.method = 'get';
    this.headers = new FakeAxiosHeaders();
    this.context = context;
  }
}

class FakeAxiosResponse implements FTAxiosResponseTarget<string> {
  config: FTAxiosRequestConfigTarget;
  status: number;
  headers?: Object;
  data?: string;

  constructor(config: FTAxiosRequestConfigTarget) {
    this.config = config;
    this.status = 200;
    this.headers = new FakeAxiosHeaders();
    this.data = 'ok';
  }
}

function createPreparedConfig(target: FakeAxiosTarget): FTAxiosRequestConfigTarget {
  const context: Record<string, Object> = {};
  context['existing'] = 'keep-me' as Object;
  const config = new FakeAxiosRequestConfig(context);

  return target.requestManager.fulfilled!(config) as FTAxiosRequestConfigTarget;
}

function getContext(config: FTAxiosRequestConfigTarget): Record<string, Object> {
  return config.context as Record<string, Object>;
}

export default function httpAutoTrackAxiosUnitTest() {
  describe('HttpAutoTrackAxiosUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
      FTRUMConfigManager.getInstance().release();
    });

    afterEach(() => {
      TestReset.resetP0State();
      FTRUMConfigManager.getInstance().release();
    });

    it('axiosSuccessShouldClearState', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });

      const preparedConfig = createPreparedConfig(target);
      const contextBeforeResponse = getContext(preparedConfig);
      expect(contextBeforeResponse[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] !== undefined).assertTrue();

      const response = new FakeAxiosResponse(preparedConfig);
      target.responseManager.fulfilled!(response);

      const contextAfterResponse = getContext(preparedConfig);
      expect(contextAfterResponse[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] === undefined).assertTrue();
      expect(contextAfterResponse['existing']).assertEqual('keep-me');
    });

    it('axiosFailureShouldClearState', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });

      const preparedConfig = createPreparedConfig(target);
      const contextBeforeResponse = getContext(preparedConfig);
      expect(contextBeforeResponse[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] !== undefined).assertTrue();

      const rawError = new Error('axios failed') as FTAxiosErrorTarget;
      rawError.config = preparedConfig;

      let thrown = false;
      try {
        target.responseManager.rejected!(rawError as Object);
      } catch (error) {
        thrown = true;
      }

      expect(thrown).assertTrue();
      const contextAfterResponse = getContext(preparedConfig);
      expect(contextAfterResponse[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] === undefined).assertTrue();
      expect(contextAfterResponse['existing']).assertEqual('keep-me');
    });

    it('axiosHttpErrorWithInvalidMetadataShouldPreserveBusinessErrorAndClearState', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });

      const preparedConfig = createPreparedConfig(target);
      const rawError = new Error('Request failed with status code 404') as FTAxiosErrorTarget;
      rawError.config = preparedConfig;
      const response = new FakeAxiosResponse(preparedConfig);
      response.status = 404;
      response.headers = new FakeAxiosThrowingHeaders();
      rawError.response = response;

      let thrownError: Object | null = null;
      try {
        target.responseManager.rejected!(rawError as Object);
      } catch (error) {
        thrownError = error;
      }

      expect(thrownError === rawError).assertTrue();
      const contextAfterResponse = getContext(preparedConfig);
      expect(contextAfterResponse[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] === undefined).assertTrue();
      expect(contextAfterResponse['existing']).assertEqual('keep-me');
    });

    it('axiosStatusZeroResponsePlaceholderShouldInvokeGlobalNetworkErrorHandler', 0, () => {
      const globalHandler = new CountingAxiosNetworkErrorHandler();
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true)
        .setNetworkErrorHandler(globalHandler));

      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });

      const preparedConfig = createPreparedConfig(target);
      const rawError = new Error('Failed to connect to the server') as FTAxiosErrorTarget;
      rawError.config = preparedConfig;
      const responsePlaceholder = new FakeAxiosResponse(preparedConfig);
      responsePlaceholder.status = 0;
      rawError.response = responsePlaceholder;

      try {
        target.responseManager.rejected!(rawError as Object);
      } catch (_error) {
        // Axios must continue to throw the original business error.
      }

      expect(globalHandler.callCount).assertEqual(1);
    });

    it('axiosShouldSkipFilteredResource', 0, () => {
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setEnableTraceUserResource(true)
        .setResourceUrlHandler(new IgnoredAxiosResourceUrlHandler()));

      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });

      const preparedConfig = createPreparedConfig(target);
      const state = getContext(preparedConfig)[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;
      expect(state.resourceEnabled).assertFalse();

      target.responseManager.fulfilled!(new FakeAxiosResponse(preparedConfig));
      expect(getContext(preparedConfig)[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] === undefined).assertTrue();
    });

    it('axiosEmptyBodyShouldKeepHeaderBytesForFinalResource', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: true
      });

      const preparedConfig = createPreparedConfig(target);
      const state = getContext(preparedConfig)[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;

      expect(state.headerInferredTransportMetrics !== undefined).assertTrue();
      expect(state.headerInferredTransportMetrics!.requestHeaderSize! > 0).assertTrue();
      expect(state.headerInferredTransportMetrics!.requestBodySize).assertEqual(0);
    });

    it('axiosUploadProgressShouldKeepThePlatformMaximumAndPreserveTheApplicationCallback', 0, () => {
      const target = new FakeAxiosTarget();
      applyFTAxiosTrack(target as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: true,
        resourceTransportMetricsProvider: (_request) => ({
          requestBodySize: 20,
          requestHeaderSize: 20,
          requestSize: 40
        })
      });

      const context: Record<string, Object> = {};
      const config = new FakeAxiosRequestConfig(context);
      let applicationUploadedBytes = -1;
      config.onUploadProgress = (progress: FakeAxiosUploadProgress): void => {
        applicationUploadedBytes = progress.loaded || 0;
      };
      const preparedConfig = target.requestManager.fulfilled!(config) as FTAxiosRequestConfigTarget;
      const state = getContext(preparedConfig)[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;

      preparedConfig.onUploadProgress!({ loaded: 30 });
      preparedConfig.onUploadProgress!({ loaded: 10 });

      expect(state.platformTransportMetrics!.requestBodySize).assertEqual(30);
      expect(applicationUploadedBytes).assertEqual(10);
    });

    it('axiosShouldUseGlobalNetworkErrorHandlerUnlessOverridden', 0, () => {
      const globalHandler = new AxiosGlobalNetworkErrorHandler();
      const explicitHandler = new AxiosGlobalNetworkErrorHandler();
      FTRUMConfigManager.getInstance().initWithConfig(new FTRUMConfig()
        .setNetworkErrorHandler(globalHandler));

      const globalTarget = new FakeAxiosTarget();
      applyFTAxiosTrack(globalTarget as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });
      const globalState =
        getContext(createPreparedConfig(globalTarget))[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;
      expect(globalState.networkErrorHandler === globalHandler).assertTrue();

      const explicitTarget = new FakeAxiosTarget();
      applyFTAxiosTrack(explicitTarget as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false,
        networkErrorHandler: explicitHandler
      });
      const explicitState =
        getContext(createPreparedConfig(explicitTarget))[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;
      expect(explicitState.networkErrorHandler === explicitHandler).assertTrue();

      const disabledTarget = new FakeAxiosTarget();
      applyFTAxiosTrack(disabledTarget as Object, {
        enableTraceInterceptor: false,
        enableResourceInterceptor: false,
        networkErrorHandler: null
      });
      const disabledState =
        getContext(createPreparedConfig(disabledTarget))[FT_AXIOS_AUTOTRACK_CONTEXT_KEY] as StoredAxiosAutoTrackState;
      expect(disabledState.networkErrorHandler === undefined).assertTrue();
    });
  });
}
