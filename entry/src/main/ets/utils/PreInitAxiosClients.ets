import {
  applyFTAxiosTrack,
  createFTRCPTrackConfig
} from '@guancecloud/ft_sdk/Index';
import {
  applyFTAxiosChainMethodBridge,
  applyFTHttpTrack,
  createFTHttpInterceptorChain
} from '@guancecloud/ft_sdk_ext/Index';
import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import axios, { AxiosHeaders, AxiosInstance, AxiosRequestConfig, AxiosResponse } from '@ohos/axios';
import { DemoLogger } from './DemoLogger';

const TAG = 'PreInitAxiosClients';
const DEFAULT_CHAIN_SMOKE_TEST_URL = 'https://httpbin.org/get?from=entry-preinit-chain';

export type PreInitAxiosSmokeExecutionMode = 'sequential' | 'parallel';

export interface PreInitAxiosClientInfo {
  mode: 'compat' | 'chain';
  createdAt: number;
  forcedTrace: boolean;
  forcedResource: boolean;
}

export interface PreInitAxiosSmokeTestResult {
  mode: 'compat' | 'chain' | 'chain-control' | 'http-chain' | 'rcp-chain';
  success: boolean;
  statusCode?: number;
  bodyLength?: number;
  errorMessage?: string;
}

export interface PreInitAxiosSmokeUrls {
  compatUrl: string;
  chainUrl: string;
}

interface AxiosSmokeRequestConfig {
  url: string;
  method: 'get' | 'post';
  data?: Object;
  responseType: 'string';
  headers: AxiosHeaders;
}

interface ErrorLikeShape {
  code?: number;
  message?: string;
  name?: string;
  stack?: string;
}

class NoOpInitialRequestInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.INITIAL_REQUEST;

  async interceptorHandle(_reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

class NoOpFinalResponseInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;

  async interceptorHandle(_reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<boolean> {
    return true;
  }
}

function createDefaultHeaders(): AxiosHeaders {
  const headers = new AxiosHeaders();
  headers.setAccept('application/json');
  headers.setContentType('application/json');
  return headers;
}

function formatSmokeTestError(error: Object): string {
  if (error instanceof Error) {
    return error.message;
  }

  const errorLike = error as ErrorLikeShape;
  if (errorLike.message && errorLike.code !== undefined) {
    return `code=${errorLike.code}, message=${errorLike.message}`;
  }
  if (errorLike.message) {
    return errorLike.message;
  }

  try {
    return JSON.stringify(error);
  } catch (_jsonError) {
    return String(error);
  }
}

function createCompatClient(): AxiosInstance {
  const client = axios.create({
    timeout: 10000,
    headers: createDefaultHeaders()
  });
  applyFTAxiosTrack(client, {
    enableTraceInterceptor: true,
    enableResourceInterceptor: true
  });
  return client;
}

function createChainClient(): AxiosInstance {
  const interceptorChain: http.HttpInterceptorChain = createFTHttpInterceptorChain({
    enableTraceInterceptor: true,
    enableResourceInterceptor: true
  });
  const client = axios.create({
    timeout: 10000,
    headers: createDefaultHeaders(),
    interceptorChain: interceptorChain
  });
  applyFTAxiosChainMethodBridge(client);
  return client;
}

function createControlChainClient(): AxiosInstance {
  const interceptorChain: http.HttpInterceptorChain = new http.HttpInterceptorChain();
  interceptorChain.addChain([
    new NoOpInitialRequestInterceptor(),
    new NoOpFinalResponseInterceptor()
  ]);
  return axios.create({
    timeout: 10000,
    headers: createDefaultHeaders(),
    interceptorChain: interceptorChain
  });
}

const compatCreatedAt = Date.now();

export const preInitCompatClient: AxiosInstance = createCompatClient();

export const preInitCompatClientInfo: PreInitAxiosClientInfo = {
  mode: 'compat',
  createdAt: compatCreatedAt,
  forcedTrace: true,
  forcedResource: true
};

const chainCreatedAt = Date.now();

export const preInitChainClient: AxiosInstance = createChainClient();

export const preInitChainClientInfo: PreInitAxiosClientInfo = {
  mode: 'chain',
  createdAt: chainCreatedAt,
  forcedTrace: true,
  forcedResource: true
};

const controlChainCreatedAt = Date.now();

export const preInitControlChainClient: AxiosInstance = createControlChainClient();

export const preInitControlChainClientInfo: PreInitAxiosClientInfo = {
  mode: 'chain',
  createdAt: controlChainCreatedAt,
  forcedTrace: false,
  forcedResource: false
};

async function executeSmokeRequest(client: AxiosInstance, url: string,
  mode: 'compat' | 'chain' | 'chain-control'): Promise<PreInitAxiosSmokeTestResult> {
  try {
    const requestHeaders = createDefaultHeaders();
    const requestConfig: AxiosSmokeRequestConfig = {
      url: url,
      method: 'get',
      responseType: 'string',
      headers: requestHeaders
    };
    const response: AxiosResponse<string | Object, Object> = await client.request<string | Object,
    AxiosResponse<string | Object, Object>,
    Object>(requestConfig as AxiosRequestConfig<Object>);
    const responseData = response.data;
    const bodyLength = typeof responseData === 'string' ? responseData.length : 0;
    const result: PreInitAxiosSmokeTestResult = {
      mode: mode,
      success: true,
      statusCode: response.status,
      bodyLength: bodyLength
    };
    DemoLogger.i(
      TAG,
      `Pre-init smoke request succeeded: mode=${mode}, status=${response.status}, bodyLength=${bodyLength}, url=${url}`
    );
    return result;
  } catch (error) {
    const errorMessage = formatSmokeTestError(error as Object);
    const result: PreInitAxiosSmokeTestResult = {
      mode: mode,
      success: false,
      errorMessage: errorMessage
    };
    DemoLogger.w(
      TAG,
      `Pre-init smoke request failed: mode=${mode}, error=${errorMessage}, url=${url}`
    );
    return result;
  }
}

async function executeHttpChainSmokeRequest(url: string): Promise<PreInitAxiosSmokeTestResult> {
  const request = http.createHttp();
  try {
    applyFTHttpTrack(request, {
      enableTraceInterceptor: true,
      enableResourceInterceptor: true
    });
    const requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
    };
    const response = await request.request(url, requestOptions);
    const result: PreInitAxiosSmokeTestResult = {
      mode: 'http-chain',
      success: true,
      statusCode: response.responseCode,
      bodyLength: response.result ? String(response.result).length : 0
    };
    DemoLogger.i(
      TAG,
      `Pre-init smoke request succeeded: mode=http-chain, status=${response.responseCode}, bodyLength=${result.bodyLength}, url=${url}`
    );
    return result;
  } catch (error) {
    const errorMessage = formatSmokeTestError(error as Object);
    const result: PreInitAxiosSmokeTestResult = {
      mode: 'http-chain',
      success: false,
      errorMessage: errorMessage
    };
    DemoLogger.w(
      TAG,
      `Pre-init smoke request failed: mode=http-chain, error=${errorMessage}, url=${url}`
    );
    return result;
  } finally {
    request.destroy();
  }
}

async function executeRcpChainSmokeRequest(url: string): Promise<PreInitAxiosSmokeTestResult> {
  let session: rcp.Session | null = null;
  try {
    session =
      rcp.createSession(createFTRCPTrackConfig({ enableTraceInterceptor: true, enableResourceInterceptor: true }));
    const request = new rcp.Request(url, 'GET');
    const response = await session.fetch(request);
    const responseBody = response.body;
    const bodyLength = responseBody ? String(responseBody).length : 0;
    const result: PreInitAxiosSmokeTestResult = {
      mode: 'rcp-chain',
      success: true,
      statusCode: response.statusCode,
      bodyLength: bodyLength
    };
    DemoLogger.i(
      TAG,
      `Pre-init smoke request succeeded: mode=rcp-chain, status=${response.statusCode}, bodyLength=${bodyLength}, url=${url}`
    );
    return result;
  } catch (error) {
    const errorMessage = formatSmokeTestError(error as Object);
    const result: PreInitAxiosSmokeTestResult = {
      mode: 'rcp-chain',
      success: false,
      errorMessage: errorMessage
    };
    DemoLogger.w(
      TAG,
      `Pre-init smoke request failed: mode=rcp-chain, error=${errorMessage}, url=${url}`
    );
    return result;
  } finally {
    if (session) {
      session.close();
    }
  }
}

function appendSmokeMode(url: string, mode: string): string {
  return `${url}${url.includes('?') ? '&' : '?'}preinit_mode=${mode}`;
}

export async function runPreInitSingleSmokeTest(
  mode: 'compat' | 'chain' | 'chain-control' | 'http-chain' | 'rcp-chain',
  urls: PreInitAxiosSmokeUrls
): Promise<PreInitAxiosSmokeTestResult> {
  switch (mode) {
    case 'compat':
      return await executeSmokeRequest(preInitCompatClient, appendSmokeMode(urls.compatUrl, 'compat'), 'compat');
    case 'chain':
      return await executeSmokeRequest(preInitChainClient, appendSmokeMode(urls.chainUrl, 'chain'), 'chain');
    case 'chain-control':
      return await executeSmokeRequest(preInitControlChainClient, appendSmokeMode(urls.chainUrl, 'chain_control'),
        'chain-control');
    case 'http-chain':
      return await executeHttpChainSmokeRequest(appendSmokeMode(urls.chainUrl, 'http_chain'));
    case 'rcp-chain':
      return await executeRcpChainSmokeRequest(appendSmokeMode(urls.chainUrl, 'rcp_chain'));
  }
}

export async function runPreInitAxiosSmokeTests(compatUrl: string,
  chainUrl: string = DEFAULT_CHAIN_SMOKE_TEST_URL): Promise<PreInitAxiosSmokeTestResult[]> {
  const urls: PreInitAxiosSmokeUrls = {
    compatUrl: compatUrl,
    chainUrl: chainUrl
  };
  return await runPreInitAxiosSmokeTestsWithMode(urls, 'sequential');
}

export async function runPreInitAxiosSmokeTestsWithMode(
  urls: PreInitAxiosSmokeUrls,
  executionMode: PreInitAxiosSmokeExecutionMode
): Promise<PreInitAxiosSmokeTestResult[]> {
  const modes: Array<'compat' | 'chain' | 'chain-control' | 'http-chain' | 'rcp-chain'> = [
    'chain',
    'compat',
    'chain-control',
    'http-chain',
    'rcp-chain'
  ];

  if (executionMode === 'parallel') {
    DemoLogger.i(TAG, `Running smoke tests in parallel: total=${modes.length}`);
    const tasks: Array<Promise<PreInitAxiosSmokeTestResult>> = [];
    for (let i = 0; i < modes.length; i++) {
      const mode = modes[i];
      DemoLogger.i(TAG, `Queueing smoke test step ${i + 1}/${modes.length}: mode=${mode}`);
      tasks.push(runPreInitSingleSmokeTest(mode, urls));
    }
    const parallelResults = await Promise.all(tasks);
    const parallelSuccessCount = parallelResults.filter((result: PreInitAxiosSmokeTestResult) => result.success).length;
    DemoLogger.i(
      TAG,
      `Pre-init smoke tests completed in parallel: success=${parallelSuccessCount}/${parallelResults.length}, compatUrl=${urls.compatUrl}, chainUrl=${urls.chainUrl}`
    );
    return parallelResults;
  }

  const results: PreInitAxiosSmokeTestResult[] = [];
  for (let i = 0; i < modes.length; i++) {
    const mode = modes[i];
    DemoLogger.i(TAG, `Running smoke test step ${i + 1}/${modes.length}: mode=${mode}`);
    results.push(await runPreInitSingleSmokeTest(mode, urls));
  }

  const successCount = results.filter((result: PreInitAxiosSmokeTestResult) => result.success).length;
  DemoLogger.i(
    TAG,
    `Pre-init smoke tests completed sequentially: success=${successCount}/${results.length}, compatUrl=${urls.compatUrl}, chainUrl=${urls.chainUrl}`
  );
  return results;
}
