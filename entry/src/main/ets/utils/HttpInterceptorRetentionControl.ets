import { http } from '@kit.NetworkKit';

export const HTTP_CHAIN_A_BATCH_SIZE: number = 100;
export const HTTP_CHAIN_B_BATCH_SIZE: number = 20;
export const HTTP_CHAIN_B_CONCURRENCY: number = 4;

export interface HttpChainAControlResult {
  addedChains: number;
  failedChains: number;
  lastError: string;
}

export interface HttpChainBControlResult {
  addedChains: number;
  appliedChains: number;
  httpResponses: number;
  requestFailures: number;
  setupFailures: number;
  destroyedRequests: number;
  destroyFailures: number;
  lastError: string;
}

// Dedicated constructor names keep this control separate from SDK interceptors
// and the long-lived pre-initialization clients in heap snapshots.
class HttpChainAInitialInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class HttpChainAFinalInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class HttpChainBInitialInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class HttpChainBFinalInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

function createAddOnlyChain(): boolean {
  const chain = new http.HttpInterceptorChain();
  const interceptors: http.HttpInterceptor[] = [
    new HttpChainAInitialInterceptor(),
    new HttpChainAFinalInterceptor()
  ];
  // All object references stay in this invocation. Deliberately do not apply
  // the chain, create an HttpRequest, or install SDK tracking.
  return chain.addChain(interceptors);
}

/** Returns primitive diagnostics only; callers cannot retain a tested chain. */
export function runHttpChainAControl(): HttpChainAControlResult {
  const result: HttpChainAControlResult = {
    addedChains: 0,
    failedChains: 0,
    lastError: ''
  };
  for (let index = 0; index < HTTP_CHAIN_A_BATCH_SIZE; index++) {
    try {
      if (createAddOnlyChain()) {
        result.addedChains++;
      } else {
        result.failedChains++;
        result.lastError = 'addChain returned false';
      }
    } catch (error) {
      result.failedChains++;
      result.lastError = String(error);
    }
  }
  return result;
}

function createBControlResult(): HttpChainBControlResult {
  const result: HttpChainBControlResult = {
    addedChains: 0,
    appliedChains: 0,
    httpResponses: 0,
    requestFailures: 0,
    setupFailures: 0,
    destroyedRequests: 0,
    destroyFailures: 0,
    lastError: ''
  };
  return result;
}

async function runAppliedChainRequest(url: string): Promise<HttpChainBControlResult> {
  const result = createBControlResult();
  let request: http.HttpRequest | undefined = undefined;
  try {
    request = http.createHttp();
    const chain = new http.HttpInterceptorChain();
    const interceptors: http.HttpInterceptor[] = [
      new HttpChainBInitialInterceptor(),
      new HttpChainBFinalInterceptor()
    ];
    if (!chain.addChain(interceptors)) {
      result.setupFailures++;
      result.lastError = 'addChain returned false';
      return result;
    }
    result.addedChains++;
    if (!chain.apply(request)) {
      result.setupFailures++;
      result.lastError = 'apply returned false';
      return result;
    }
    result.appliedChains++;
    try {
      // No SDK tracking, response retention, or application callbacks. The
      // chain and its empty interceptors stay local to this request invocation.
      await request.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      // Any resolved HTTP response counts, including 4xx/5xx.
      result.httpResponses++;
    } catch (error) {
      result.requestFailures++;
      result.lastError = String(error);
    }
  } catch (error) {
    result.setupFailures++;
    result.lastError = String(error);
  } finally {
    if (request) {
      try {
        request.destroy();
        result.destroyedRequests++;
      } catch (error) {
        result.destroyFailures++;
        result.lastError = String(error);
      }
      request = undefined;
    }
  }
  return result;
}

/** All requests settle and attempt destruction before the numeric summary returns. */
export async function runHttpChainBControl(
  url: string,
  onProgress?: (completed: number) => void
): Promise<HttpChainBControlResult> {
  const result = createBControlResult();
  let nextRequest = 0;
  let completed = 0;
  const runWorker = async (): Promise<void> => {
    while (nextRequest < HTTP_CHAIN_B_BATCH_SIZE) {
      nextRequest++;
      const item = await runAppliedChainRequest(url);
      result.addedChains += item.addedChains;
      result.appliedChains += item.appliedChains;
      result.httpResponses += item.httpResponses;
      result.requestFailures += item.requestFailures;
      result.setupFailures += item.setupFailures;
      result.destroyedRequests += item.destroyedRequests;
      result.destroyFailures += item.destroyFailures;
      if (item.lastError) result.lastError = item.lastError;
      completed++;
      onProgress?.(completed);
    }
  };
  const workers: Promise<void>[] = [];
  for (let index = 0; index < HTTP_CHAIN_B_CONCURRENCY; index++) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
  return result;
}
