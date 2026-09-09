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
import { TestReset } from '../helpers/TestReset';

const FT_AXIOS_AUTOTRACK_CONTEXT_KEY = '__ftAxiosAutoTrackState';

class IgnoredAxiosResourceUrlHandler extends FTInTakeUrlHandler {
  public isInTakeUrl(url: string): boolean {
    return url.includes('/api');
  }
}

interface StoredAxiosAutoTrackState {
  resourceEnabled: boolean;
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

class FakeAxiosRequestConfig implements FTAxiosRequestConfigTarget {
  url?: string;
  method?: string;
  headers?: Object;
  context?: Object;

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
  });
}
