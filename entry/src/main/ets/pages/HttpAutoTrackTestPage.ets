/**
 * HTTP Interceptor Test Page
 * Test RCP HTTP Axios
 */
import {
  applyFTAxiosTrack,
  createFTRCPTrackConfig,
  FTNetworkErrorHandler,
  FTSDK,
  FTTraceConfigManager,
} from '@guancecloud/ft_sdk/Index';
import {
  applyFTAxiosChainMethodBridge,
  applyFTHttpTrack,
  createFTHttpInterceptorChain
} from '@guancecloud/ft_sdk_ext/Index';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import axios, {
  AxiosHeaders, AxiosInstance, AxiosRequestConfig, AxiosResponse
} from '@ohos/axios';
import { BusinessError } from '@kit.BasicServicesKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import {
  KEY_RESOURCE_TEST_URL,
  KEY_TRACE_URL,
  RESOURCE_FILTER_TEST_URL_PREFIX
} from '../entryability/EntryAbility';
import { ENTRY_UI_TEST_ACTIVE } from '../utils/EntryTestConfig';
import { DemoLogger } from '../utils/DemoLogger';
import {
  preInitChainClientInfo,
  preInitCompatClientInfo,
  preInitControlChainClientInfo,
  PreInitAxiosSmokeExecutionMode,
  PreInitAxiosSmokeUrls,
  runPreInitAxiosSmokeTestsWithMode
} from '../utils/PreInitAxiosClients';

const TAG = "HttpAutoTrackTestPage";

interface AxiosStyleRequestData {
  source: string;
  method: string;
  message: string;
  timestamp: number;
}

interface AxiosPageCreateConfig {
  timeout: number;
  headers: AxiosHeaders;
  interceptorChain?: http.HttpInterceptorChain;
}

interface AxiosPageRequestConfig {
  url: string;
  method: AxiosHttpMethod;
  data?: Object;
  responseType: 'string';
  headers: AxiosHeaders;
}

type AxiosAutoTrackMode = 'chain' | 'compat';
type AxiosHttpMethod = 'get' | 'post';

interface AxiosErrorResponse {
  status?: number;
}

interface AxiosErrorTarget {
  message?: string;
  response?: AxiosErrorResponse;
}

/**
 * HTTP Interceptor Test Page Component
 */
@Entry
@Component
export struct HttpAutoTrackTestPage {
  @State message: string = 'HTTP Interceptor Test Page';
  @State testResults: string[] = [];
  @State isAutoTrackEnabled: boolean = false;
  @State requestCount: number = 0;
  @State successCount: number = 0;
  @State errorCount: number = 0;
  @State axiosMode: AxiosAutoTrackMode = 'compat';
  @State localNetworkErrorFilterEnabled: boolean = true;
  @StorageLink(KEY_TRACE_URL) storedTraceUrl: string = "";
  @StorageLink(KEY_RESOURCE_TEST_URL) resourceTestUrl: string = "";
  @StorageProp(ENTRY_UI_TEST_ACTIVE) isUITest: boolean = false;

  aboutToAppear() {
    this.checkAutoTrackStatus();
  }

  private createRCPSession(baseAddress?: string): rcp.Session {
    return rcp.createSession(createFTRCPTrackConfig({
      baseAddress: baseAddress,
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 10000 } } },
      networkErrorHandler: this.createNetworkErrorHandler()
    }));
  }

  private createNetworkErrorHandler(): FTNetworkErrorHandler | null | undefined {
    // Enabled defers to the FTRUMConfig default; disabled explicitly opts this
    // request path out so the global default remains installed for other code.
    return this.localNetworkErrorFilterEnabled ? undefined : null;
  }

  private getLocalFailureUrl(source: string): string {
    return `http://127.0.0.1:1/ft-local-network-failure?source=${source}&time=${Date.now()}`;
  }

  private async executeHttpRequest(
    url: string,
    options: http.HttpRequestOptions = {}
  ): Promise<http.HttpResponse> {
    const request = http.createHttp();
    applyFTHttpTrack(request, { networkErrorHandler: this.createNetworkErrorHandler() });
    try {
      return await request.request(url, options);
    } finally {
      request.destroy();
    }
  }

  private async executeAxiosRequest(
    url: string,
    method: AxiosHttpMethod,
    data?: Object,
    mode: AxiosAutoTrackMode = 'compat'
  ): Promise<string> {
    const response = await this.executeAxiosRequestResponse(url, method, data, mode);
    return typeof response.data === 'string'
      ? response.data
      : JSON.stringify(response.data);
  }

  private async executeAxiosRequestResponse(
    url: string,
    method: AxiosHttpMethod,
    data?: Object,
    mode: AxiosAutoTrackMode = 'compat'
  ): Promise<AxiosResponse<string | Object, Object>> {
    const client = this.createAxiosInstance(mode);
    return await this.executeAxiosRequestWithClientResponse(client, url, method, data);
  }

  private async executeAxiosRequestWithClient(
    client: AxiosInstance,
    url: string,
    method: AxiosHttpMethod,
    data?: Object
  ): Promise<string> {
    const response = await this.executeAxiosRequestWithClientResponse(client, url, method, data);
    return typeof response.data === 'string'
      ? response.data
      : JSON.stringify(response.data);
  }

  private async executeAxiosRequestWithClientResponse(
    client: AxiosInstance,
    url: string,
    method: AxiosHttpMethod,
    data?: Object
  ): Promise<AxiosResponse<string | Object, Object>> {
    const requestHeaders = new AxiosHeaders();
    requestHeaders.setAccept('application/json');
    requestHeaders.setContentType('application/json');
    const requestConfig: AxiosPageRequestConfig = {
      url: url,
      method: method,
      data: data,
      responseType: 'string',
      headers: requestHeaders
    };
    const response: AxiosResponse<string | Object, Object> = await client.request<string | Object,
    AxiosResponse<string | Object, Object>,
    Object>(requestConfig as AxiosRequestConfig<Object>);
    return response;
  }

  private createAxiosInstance(mode: AxiosAutoTrackMode = 'compat'): AxiosInstance {
    const defaultHeaders = new AxiosHeaders();
    defaultHeaders.setAccept('application/json');
    defaultHeaders.setContentType('application/json');
    const axiosConfig: AxiosPageCreateConfig = {
      timeout: 10000,
      headers: defaultHeaders
    };

    if (mode === 'chain') {
      // Keep the interceptorChain path for newer @ohos/axios versions that
      // support wiring NetworkKit interceptors directly through request config.
      axiosConfig.interceptorChain = createFTHttpInterceptorChain({
        networkErrorHandler: this.createNetworkErrorHandler()
      });
    }

    const client = axios.create(axiosConfig);
    if (mode === 'compat') {
      applyFTAxiosTrack(client, { networkErrorHandler: this.createNetworkErrorHandler() });
    } else if (mode === 'chain') {
      applyFTAxiosChainMethodBridge(client);
    }
    return client;
  }

  /**
   * Check interceptor helper status
   */
  checkAutoTrackStatus() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      const rumEnabled = rumConfig !== null && rumConfig.getRumAppId().length > 0;
      this.isAutoTrackEnabled = rumEnabled;
      this.addTestResult(`RCP interceptor session helper: ${this.isAutoTrackEnabled ? '✅ Available' :
        '❌ Unavailable'}`);
    } catch (error) {
      this.addTestResult(`❌ Failed to check interceptor helper status: ${error}`);
    }
  }

  /**
   * Add test result
   */
  addTestResult(result: string) {
    const nextResults = [...this.testResults, `[${new Date().toLocaleTimeString()}] ${result}`];
    this.testResults = nextResults.length > 60
      ? nextResults.slice(nextResults.length - 60)
      : nextResults;
    DemoLogger.i(TAG, result);
  }

  private getTraceTestUrl(): string {
    return this.storedTraceUrl.trim();
  }

  private getResourceTestUrl(source: string, fallback: string): string {
    // UI instrumentation always configures traceUrl for the Trace case. Reuse
    // that known device-reachable endpoint when no separate resource endpoint
    // was supplied, instead of silently depending on the public httpbin
    // fallback. Production/demo calls retain their existing fallback.
    const configuredResourceUrl = this.resourceTestUrl.trim();
    const uiTestTraceUrl = this.isUITest ? this.getTraceTestUrl() : '';
    const url = configuredResourceUrl || uiTestTraceUrl || fallback;
    if (!this.isUITest) {
      return url;
    }
    const baseUrl = url.split('#')[0];
    return `${baseUrl}${baseUrl.includes('?') ? '&' : '?'}ft_source=${source}`;
  }

  private getAxiosRequestUrl(method: AxiosHttpMethod, mode: AxiosAutoTrackMode): string {
    const from = mode === 'chain' ? 'axios-chain' : 'axios-adapter';
    if (method === 'get') {
      return this.getResourceTestUrl(`axios-${mode}`, `https://httpbin.org/get?from=${from}`);
    }
    return `https://httpbin.org/${method}`;
  }

  private getResourceFilterTestUrl(): string {
    return `${RESOURCE_FILTER_TEST_URL_PREFIX}${Date.now()}`;
  }

  private createAxiosRequestData(method: AxiosHttpMethod, mode: AxiosAutoTrackMode): AxiosStyleRequestData {
    const methodName = method.toUpperCase();
    return {
      source: mode === 'chain' ? 'axios-chain' : 'axios',
      method: methodName,
      message: `Testing FT axios ${mode === 'chain' ? 'interceptorChain' : 'auto track'} ${methodName} request`,
      timestamp: Date.now()
    };
  }

  private async testAxiosMethodRequest(mode: AxiosAutoTrackMode, method: AxiosHttpMethod) {
    const modeName = mode === 'chain' ? 'chain' : 'compat';
    const methodName = method.toUpperCase();
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult(`⚠️ Auto Track not enabled, skipping axios ${modeName} ${methodName} test`);
        return;
      }

      const requestData = method === 'get'
        ? undefined
        : this.createAxiosRequestData(method, mode);
      const responseText = await this.executeAxiosRequest(
        this.getAxiosRequestUrl(method, mode),
        method,
        requestData,
        mode
      );
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios ${modeName} ${methodName} request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Axios ${modeName} ${methodName} request failed: ${errorMsg}`);
    }
  }

  private getAxiosModeName(): string {
    return this.axiosMode === 'chain' ? 'Chain' : 'Compat';
  }

  private async testAxiosErrorRequest(mode: AxiosAutoTrackMode) {
    const modeName = mode === 'chain' ? 'Chain' : 'Compat';
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult(`⚠️ Auto Track not enabled, skipping Axios ${modeName} error test`);
        return;
      }

      const response = await this.executeAxiosRequestResponse(
        'https://httpbin.org/status/404',
        'get',
        undefined,
        mode
      );
      this.requestCount++;
      if (response.status === 404) {
        this.successCount++;
        this.addTestResult(`✅ Axios ${modeName} error request returned expected status=404`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Axios ${modeName} error request returned unexpected status=${response.status}`);
      }
    } catch (error) {
      this.requestCount++;
      const axiosError = error as AxiosErrorTarget;
      const status = axiosError.response ? axiosError.response.status || 0 : 0;
      if (status === 404) {
        this.successCount++;
        this.addTestResult(`✅ Axios ${modeName} error request returned expected status=404`);
      } else {
        this.errorCount++;
        this.addTestResult(`❌ Axios ${modeName} error request failed: ${axiosError.message || String(error)}`);
      }
    }
  }

  private async testAxiosTraceRequest(mode: AxiosAutoTrackMode) {
    const modeName = mode === 'chain' ? 'Chain' : 'Compat';
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult(`⚠️ traceUrl not configured, skipping Axios ${modeName} Trace request`);
        return;
      }
      if (!this.isAutoTrackEnabled || !FTTraceConfigManager.getInstance().isAutoTraceEnabled()) {
        this.addTestResult(`⚠️ Trace is not enabled, skipping Axios ${modeName} Trace request`);
        return;
      }

      const responseText = await this.executeAxiosRequest(testUrl, 'get', undefined, mode);
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios ${modeName} Trace request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Axios ${modeName} Trace request failed: ${err.message || String(error)}`);
    }
  }

  private async testAxiosConcurrentRequests(mode: AxiosAutoTrackMode) {
    const modeName = mode === 'chain' ? 'Chain' : 'Compat';
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult(`⚠️ Auto Track not enabled, skipping 5 concurrent Axios ${modeName} GET requests`);
        return;
      }

      const client = this.createAxiosInstance(mode);
      const baseUrl = this.getAxiosRequestUrl('get', mode);
      const requests: Promise<string>[] = [];
      for (let index = 0; index < 5; index++) {
        const separator = baseUrl.includes('?') ? '&' : '?';
        requests.push(this.executeAxiosRequestWithClient(client, `${baseUrl}${separator}request=${index}`, 'get'));
      }

      const responses = await Promise.all(requests);
      for (let index = 0; index < responses.length; index++) {
        this.requestCount++;
        this.successCount++;
      }
      this.addTestResult(`✅ 5 concurrent Axios ${modeName} GET requests completed`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Concurrent Axios ${modeName} GET requests failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Test GET request with RCP
   */
  async testRCPGetRequest() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createRCPSession();

      // createFTRCPTrackConfig() attaches the FT interceptors. A Session using
      // baseAddress with a relative URL follows this same interceptor path.
      const request = new rcp.Request(this.getResourceTestUrl('rcp', 'https://httpbin.org/get'), 'GET');
      let response: rcp.Response;
      try {
        response = await session.fetch(request);
      } finally {
        session.close();
      }

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ GET request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ GET request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ GET request failed: ${errorMsg}`);
    }
  }

  /**
   * Sends an RCP request whose URL matches DemoResourceUrlHandler. The request
   * must still succeed, while the SDK must not create an automatic Resource.
   */
  async testResourceUrlFilter() {
    const testUrl = this.getResourceFilterTestUrl();
    const resourceUrlHandler = FTSDK.getRumConfig()?.getResourceUrlHandler() ?? null;
    if (resourceUrlHandler === null || !resourceUrlHandler.isInTakeUrl(testUrl)) {
      this.addTestResult(`❌ Resource URL filter is not configured for: ${testUrl}`);
      return;
    }

    try {
      const session = this.createRCPSession();
      let response: rcp.Response;
      try {
        response = await session.fetch(new rcp.Request(testUrl, 'GET'));
      } finally {
        session.close();
      }

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Filtered Resource request succeeded: status=${response.statusCode}. ` +
          'Verify no matching RUM Resource is uploaded.');
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Filtered Resource request returned status=${response.statusCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Filtered Resource request failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Verifies filtering through the Native HTTP interceptor chain.
   */
  async testHttpResourceUrlFilter() {
    const testUrl = this.getResourceFilterTestUrl();
    const resourceUrlHandler = FTSDK.getRumConfig()?.getResourceUrlHandler() ?? null;
    if (resourceUrlHandler === null || !resourceUrlHandler.isInTakeUrl(testUrl)) {
      this.addTestResult(`❌ HTTP Resource URL filter is not configured for: ${testUrl}`);
      return;
    }

    try {
      const response = await this.executeHttpRequest(testUrl, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' }
      });
      this.requestCount++;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Filtered HTTP Resource request succeeded: status=${response.responseCode}. ` +
          'Verify no matching RUM Resource is uploaded.');
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Filtered HTTP Resource request returned status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Filtered HTTP Resource request failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Verifies filtering through the selected Axios auto-track integration.
   */
  async testAxiosResourceUrlFilter(mode: AxiosAutoTrackMode) {
    const testUrl = this.getResourceFilterTestUrl();
    const resourceUrlHandler = FTSDK.getRumConfig()?.getResourceUrlHandler() ?? null;
    if (resourceUrlHandler === null || !resourceUrlHandler.isInTakeUrl(testUrl)) {
      this.addTestResult(`❌ Axios Resource URL filter is not configured for: ${testUrl}`);
      return;
    }

    const modeName = mode === 'chain' ? 'Chain' : 'Compat';
    try {
      const responseText = await this.executeAxiosRequest(testUrl, 'get', undefined, mode);
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Filtered Axios ${modeName} Resource request succeeded: bodyLength=${responseText.length}. ` +
        'Verify no matching RUM Resource is uploaded.');
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Filtered Axios ${modeName} Resource request failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Test POST request with RCP helper
   */
  async testRCPPostRequest() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createRCPSession();

      // Define post data interface
      interface PostData {
        name: string;
        message: string;
        timestamp: number;
      }

      const postData: PostData = {
        name: 'HarmonyOS Test',
        message: 'Testing FT interceptors',
        timestamp: Date.now()
      };

      // Send POST request (should be automatically intercepted)
      const headers: rcp.RequestHeaders = {
        'Content-Type': 'application/json'
      };
      const request = new rcp.Request('https://httpbin.org/post', 'POST', headers, postData);
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ POST request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ POST request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ POST request failed: ${errorMsg}`);
    }
  }

  /**
   * Test error request (404)
   */
  async testRCPErrorRequest() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createRCPSession();

      // Send GET request to non-existent endpoint (should return 404)
      const request = new rcp.Request('https://httpbin.org/status/404', 'GET');
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode === 404) {
        this.addTestResult(`✅ Error request handled as expected: status=404`);
        // 404 is expected, so we don't count it as an error
        this.successCount++;
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Error request returned unexpected status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Error request test failed: ${errorMsg}`);
    }
  }

  private recordExpectedLocalFailure(source: string, error: Object): void {
    this.requestCount++;
    this.successCount++;
    const message = (error as BusinessError).message || String(error);
    const filterState = this.localNetworkErrorFilterEnabled ? 'enabled' : 'disabled';
    this.addTestResult(`✅ ${source} local failure reached caller (${message}); filter=${filterState}. ` +
      'Verify one status=0 Resource. With filter enabled, it has demo_network_error_* fields and no linked Error.');
  }

  /** Requests an unused loopback port so no HTTP response exists. */
  async testRCPLocalNetworkErrorFilter() {
    if (!this.isAutoTrackEnabled) {
      this.addTestResult('⚠️ Auto Track not enabled, skipping RCP local failure test');
      return;
    }
    const session = this.createRCPSession();
    try {
      await session.fetch(new rcp.Request(this.getLocalFailureUrl('rcp'), 'GET'));
      this.requestCount++;
      this.errorCount++;
      this.addTestResult('❌ RCP local failure test unexpectedly received an HTTP response');
    } catch (error) {
      this.recordExpectedLocalFailure('RCP', error as Object);
    } finally {
      session.close();
    }
  }

  /**
   * Test an RCP request through the Trace interceptor path.
   */
  async testRCPTraceRequest() {
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult("⚠️ traceUrl not configured, skipping RCP Trace request");
        return;
      }

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const traceConfigManager = FTTraceConfigManager.getInstance();
      const isTraceEnabled = traceConfigManager.isAutoTraceEnabled();

      if (!isTraceEnabled) {
        this.addTestResult("⚠️ Trace is not enabled, skipping RCP Trace request");
        return;
      }

      const session = this.createRCPSession();

      // The RCP interceptor injects Trace headers before dispatching this request.
      const request = new rcp.Request(testUrl, 'GET');
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ RCP Trace request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ RCP Trace request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ RCP Trace request failed: ${errorMsg}`);
    }
  }

  /**
   * Test five concurrent RCP GET requests.
   */
  async testRCPConcurrentRequests() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createRCPSession();

      const promises: Promise<rcp.Response>[] = [];
      for (let i = 0; i < 5; i++) {
        const request = new rcp.Request(`https://httpbin.org/get?request=${i}`, 'GET');
        promises.push(session.fetch(request));
      }

      const responses = await Promise.all(promises);

      let success = 0;
      for (let i = 0; i < responses.length; i++) {
        this.requestCount++;
        if (responses[i].statusCode >= 200 && responses[i].statusCode < 300) {
          success++;
          this.successCount++;
        } else {
          this.errorCount++;
        }
      }

      this.addTestResult(`✅ 5 concurrent RCP GET requests completed: ${success}/${responses.length} successful`);

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Concurrent RCP GET requests failed: ${errorMsg}`);
    }
  }

  /**
   * Test GET request with NetworkKit http interceptor chain
   */
  async testHttpGetRequestWithInterceptorChain() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http GET test");
        return;
      }

      const response = await this.executeHttpRequest(this.getResourceTestUrl('network-http', 'https://httpbin.org/get'), {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        header: {
          'Accept': 'application/json'
        }
      });

      this.requestCount++;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ HTTP GET request succeeded: status=${response.responseCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ HTTP GET request returned status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ HTTP GET request failed: ${errorMsg}`);
    }
  }

  /**
   * Test POST request with NetworkKit http interceptor chain
   */
  async testHttpPostRequestWithInterceptorChain() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http POST test");
        return;
      }

      const postBody = JSON.stringify({
        name: 'HarmonyOS HTTP Interceptor Test',
        message: 'Testing FT http interceptor chain',
        timestamp: Date.now()
      });
      const response = await this.executeHttpRequest('https://httpbin.org/post', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: postBody
      });

      this.requestCount++;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ HTTP POST request succeeded: status=${response.responseCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ HTTP POST request returned status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ HTTP POST request failed: ${errorMsg}`);
    }
  }

  /**
   * Test a 404 response through the NetworkKit interceptor chain.
   */
  async testHttpErrorRequestWithInterceptorChain() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping HTTP error test");
        return;
      }

      const response = await this.executeHttpRequest('https://httpbin.org/status/404', {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' }
      });
      this.requestCount++;
      if (response.responseCode === 404) {
        this.successCount++;
        this.addTestResult("✅ HTTP error request returned expected status=404");
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ HTTP error request returned unexpected status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ HTTP error request failed: ${err.message || String(error)}`);
    }
  }

  /** Uses the same no-response endpoint as the RCP test through NetworkKit. */
  async testHttpLocalNetworkErrorFilter() {
    if (!this.isAutoTrackEnabled) {
      this.addTestResult('⚠️ Auto Track not enabled, skipping HTTP local failure test');
      return;
    }
    try {
      await this.executeHttpRequest(this.getLocalFailureUrl('http-chain'), {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3000
      });
      this.requestCount++;
      this.errorCount++;
      this.addTestResult('❌ HTTP local failure test unexpectedly received an HTTP response');
    } catch (error) {
      this.recordExpectedLocalFailure('HTTP chain', error as Object);
    }
  }

  /**
   * Test a native HTTP request through the Trace interceptor path.
   */
  async testHttpTraceRequest() {
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult("⚠️ traceUrl not configured, skipping HTTP Trace request");
        return;
      }
      if (!this.isAutoTrackEnabled || !FTTraceConfigManager.getInstance().isAutoTraceEnabled()) {
        this.addTestResult("⚠️ Trace is not enabled, skipping HTTP Trace request");
        return;
      }

      const response = await this.executeHttpRequest(testUrl, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' }
      });
      this.requestCount++;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ HTTP Trace request succeeded: status=${response.responseCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ HTTP Trace request returned status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ HTTP Trace request failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Test five concurrent native HTTP GET requests.
   */
  async testHttpConcurrentRequestsWithInterceptorChain() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping 5 concurrent HTTP GET requests");
        return;
      }

      const requests: Promise<http.HttpResponse>[] = [];
      for (let index = 0; index < 5; index++) {
        requests.push(this.executeHttpRequest(`https://httpbin.org/get?request=${index}`, {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json' }
        }));
      }

      const responses = await Promise.all(requests);
      let success = 0;
      for (let index = 0; index < responses.length; index++) {
        this.requestCount++;
        if (responses[index].responseCode >= 200 && responses[index].responseCode < 300) {
          success++;
          this.successCount++;
        } else {
          this.errorCount++;
        }
      }
      this.addTestResult(`✅ 5 concurrent HTTP GET requests completed: ${success}/5 successful`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Concurrent HTTP GET requests failed: ${err.message || String(error)}`);
    }
  }

  /** Uses the selected Axios integration mode with the same no-response endpoint. */
  async testAxiosLocalNetworkErrorFilter(mode: AxiosAutoTrackMode) {
    if (!this.isAutoTrackEnabled) {
      this.addTestResult('⚠️ Auto Track not enabled, skipping Axios local failure test');
      return;
    }
    try {
      await this.executeAxiosRequest(this.getLocalFailureUrl(`axios-${mode}`), 'get', undefined, mode);
      this.requestCount++;
      this.errorCount++;
      this.addTestResult(`❌ Axios ${this.getAxiosModeName()} local failure test unexpectedly received an HTTP response`);
    } catch (error) {
      this.recordExpectedLocalFailure(`Axios ${this.getAxiosModeName()}`, error as Object);
    }
  }

  private buildPreInitSmokeTestUrl(mode: 'compat' | 'chain'): string {
    const traceUrl = this.storedTraceUrl.trim();
    const source = mode === 'compat' ? 'entry-preinit-compat' : 'entry-preinit-chain';
    if (traceUrl.length > 0) {
      return `${traceUrl}${traceUrl.includes('?') ? '&' : '?'}from=${source}`;
    }
    return `https://httpbin.org/get?from=${source}`;
  }

  async testNetworkAutoTrackSmokeSuite() {
    const executionMode: PreInitAxiosSmokeExecutionMode = 'parallel';
    const urls: PreInitAxiosSmokeUrls = {
      compatUrl: this.buildPreInitSmokeTestUrl('compat'),
      chainUrl: this.buildPreInitSmokeTestUrl('chain')
    };
    this.addTestResult(
      `▶ Running network auto-track smoke suite: mode=${executionMode}, compatAt=${preInitCompatClientInfo.createdAt}, ` +
      `chainAt=${preInitChainClientInfo.createdAt}, controlAt=${preInitControlChainClientInfo.createdAt}`
    );

    try {
      const results = await runPreInitAxiosSmokeTestsWithMode(urls, executionMode);
      for (let index = 0; index < results.length; index++) {
        const result = results[index];
        this.requestCount++;
        if (result.success) {
          this.successCount++;
          this.addTestResult(`✅ Network smoke ${result.mode}: status=${result.statusCode}, bodyLength=${result.bodyLength}`);
        } else {
          this.errorCount++;
          this.addTestResult(`❌ Network smoke ${result.mode}: ${result.errorMessage || 'unknown error'}`);
        }
      }
    } catch (error) {
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Network auto-track smoke suite failed: ${err.message || String(error)}`);
    }
  }

  /**
   * Clear test results
   */
  clearResults() {
    this.testResults = [];
    this.requestCount = 0;
    this.successCount = 0;
    this.errorCount = 0;
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message,
        backCustomPropertyGroup: 'back-btn',
        backCustomPropertyValue: 'Back'
      })

      Text(`Interceptor Helper: ${this.isAutoTrackEnabled ? '✅ Available' : '❌ Unavailable'}`)
        .fontSize(14)
        .margin({ bottom: 10 })

      Text(`Requests: ${this.requestCount} | Success: ${this.successCount} | Errors: ${this.errorCount}`)
        .fontSize(12)
        .margin({ bottom: 20 })

      Scroll() {
        Column() {
          Text('Trace configuration: switch, not a global network hook')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .margin({ bottom: 6 })

          Text('setEnableAutoTrace(true) only enables Trace injection for FT SDK interceptors that have already been attached. It does not intercept every network request in the process.')
            .fontSize(12)
            .fontColor('#4E5969')
            .width('100%')
            .margin({ bottom: 4 })

          Text('Configure Trace before creating a Session, HttpRequest, Axios client, or interceptor chain. Existing recognized Trace headers are retained. setEnableLinkRUMData(true) links Trace IDs to RUM Resource data; it does not install an interceptor.')
            .fontSize(12)
            .fontColor('#4E5969')
            .width('100%')
            .margin({ bottom: 16 })

          Text('Local network Error filter')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ bottom: 4 })

          Text('This switch is passed to each newly created RCP, NetworkKit, and Axios integration. It filters only failures with no HTTP response; 4xx/5xx responses remain Errors.')
            .fontSize(12)
            .fontColor('#4E5969')
            .width('100%')
            .margin({ bottom: 8 })

          Button(this.localNetworkErrorFilterEnabled ? 'Local Error Filter: Enabled' : 'Local Error Filter: Disabled')
            .width('100%')
            .margin({ bottom: 16 })
            .backgroundColor(this.localNetworkErrorFilterEnabled ? '#2E7D32' : '#757575')
            .onClick(() => this.localNetworkErrorFilterEnabled = !this.localNetworkErrorFilterEnabled)
            .customProperty('test-network-error-filter-toggle-btn', 'Toggle Local Network Error Filter')

          Text('RCP: session-level interception')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ bottom: 4 })

          Text('These tests create an RCP Session with createFTRCPTrackConfig(). Only requests sent through that Session receive the RCP Trace/Resource interceptors.')
            .fontSize(12)
            .fontColor('#4E5969')
            .width('100%')
            .margin({ bottom: 10 })

          Button('Test GET Request (RCP)')
            .id('test-get-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .customProperty('test-get-btn', 'Test GET Request (RCP)')
            .onClick(() => this.testRCPGetRequest())

          Button('Test Resource URL Filter (RCP)')
            .id('test-resource-filter-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#607D8B')
            .onClick(() => this.testResourceUrlFilter())
            .customProperty('test-resource-filter-btn', 'Test Resource URL Filter (RCP)')

          Button('Test POST Request (RCP)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPPostRequest())
            .customProperty('test-post-btn', 'Test POST Request (RCP)')

          Button('Test Error Request (404)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPErrorRequest())
            .customProperty('test-error-btn', 'Test Error Request (404)')

          Button('Test Local Failure Filter (RCP)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#8E24AA')
            .onClick(() => this.testRCPLocalNetworkErrorFilter())
            .customProperty('test-rcp-local-network-error-filter-btn', 'Test Local Failure Filter (RCP)')

          Button('Test RCP Trace Request')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#4CAF50')
            .onClick(() => this.testRCPTraceRequest())
            .customProperty('test-rcp-trace-request-btn', 'Test RCP Trace Request')

          Button('Test 5 Concurrent RCP GET Requests')
            .width('100%')
            .margin({ bottom: 16 })
            .onClick(() => this.testRCPConcurrentRequests())
            .customProperty('test-multiple-requests-btn', 'Test 5 Concurrent RCP GET Requests')

          Text('The RCP Trace request verifies the request path. Inspect SDK logs or uploaded Resource data to verify the injected headers and trace_id/span_id values.')
            .fontSize(12)
            .fontColor('#8B5D00')
            .width('100%')
            .margin({ bottom: 16 })

          Text('Native HTTP (API 22+): request-level interception')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ bottom: 4 })

          Text('Each native HTTP test creates http.createHttp() and explicitly calls applyFTHttpTrack(request). A native HttpRequest without this call is outside auto-track coverage.')
            .fontSize(12)
            .fontColor('#4E5969')
            .width('100%')
            .margin({ bottom: 10 })

          Button('Test HTTP GET Request (API 22+)')
            .id('test-http-get-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpGetRequestWithInterceptorChain())
            .customProperty('test-http-get-btn', 'Test HTTP GET Request (API 22+)')

          Button('Test HTTP Resource URL Filter (API 22+)')
            .id('test-http-resource-filter-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#607D8B')
            .onClick(() => this.testHttpResourceUrlFilter())
            .customProperty('test-http-resource-filter-btn', 'Test HTTP Resource URL Filter (API 22+)')

          Button('Test HTTP POST Request (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpPostRequestWithInterceptorChain())
            .customProperty('test-http-post-btn', 'Test HTTP POST Request (API 22+)')

          Button('Test HTTP Error Request (404, API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpErrorRequestWithInterceptorChain())
            .customProperty('test-http-error-btn', 'Test HTTP Error Request (404, API 22+)')

          Button('Test Local Failure Filter (HTTP, API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#8E24AA')
            .onClick(() => this.testHttpLocalNetworkErrorFilter())
            .customProperty('test-http-local-network-error-filter-btn', 'Test Local Failure Filter (HTTP)')

          Button('Test HTTP Trace Request (API 22+)')
            .id('test-http-trace-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpTraceRequest())
            .customProperty('test-http-trace-btn', 'Test HTTP Trace Request (API 22+)')

          Button('Test 5 Concurrent HTTP GET Requests (API 22+)')
            .width('100%')
            .margin({ bottom: 16 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpConcurrentRequestsWithInterceptorChain())
            .customProperty('test-http-concurrent-btn', 'Test 5 Concurrent HTTP GET Requests (API 22+)')

          Text('The five HTTP tests all use applyFTHttpTrack(request). The Trace request validates the request path; inspect SDK logs or uploaded Resource data for Trace fields.')
            .fontSize(12)
            .fontColor('#8B5D00')
            .width('100%')
            .margin({ bottom: 16 })

          Text('Axios: client-level interception')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 4 })
            .width('100%')

          Text('Compat attaches applyFTAxiosTrack(client). Chain uses createFTHttpInterceptorChain() + applyFTAxiosChainMethodBridge(client). Only the registered Axios client is covered.')
            .fontSize(12)
            .fontColor('#4E5969')
            .margin({ bottom: 10 })
            .width('100%')

          Row() {
            Button('Compat')
              .layoutWeight(1)
              .margin({ right: 4 })
              .backgroundColor(this.axiosMode === 'compat' ? '#FF9800' : '#DDE3EA')
              .onClick(() => this.axiosMode = 'compat')

            Button('Chain')
              .layoutWeight(1)
              .margin({ left: 4 })
              .backgroundColor(this.axiosMode === 'chain' ? '#FB8C00' : '#DDE3EA')
              .onClick(() => this.axiosMode = 'chain')
          }
          .width('100%')
          .margin({ bottom: 8 })

          Text(`Selected mode: ${this.getAxiosModeName()}. The five buttons below use only the selected Axios client integration.`)
            .fontSize(12)
            .fontColor('#8B5D00')
            .margin({ bottom: 10 })
            .width('100%')

          Button(`Test Axios GET (${this.getAxiosModeName()})`)
            .id('test-axios-get-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosMethodRequest(this.axiosMode, 'get'))
            .customProperty('test-axios-get-btn', 'Test Axios GET')

          Button(`Test Axios Resource URL Filter (${this.getAxiosModeName()})`)
            .id('test-axios-resource-filter-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#607D8B')
            .onClick(() => this.testAxiosResourceUrlFilter(this.axiosMode))
            .customProperty('test-axios-resource-filter-btn', 'Test Axios Resource URL Filter')

          Button(`Test Axios POST (${this.getAxiosModeName()})`)
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosMethodRequest(this.axiosMode, 'post'))
            .customProperty('test-axios-post-btn', 'Test Axios POST')

          Button(`Test Axios Error Request (404, ${this.getAxiosModeName()})`)
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosErrorRequest(this.axiosMode))
            .customProperty('test-axios-error-btn', 'Test Axios Error Request (404)')

          Button(`Test Local Failure Filter (Axios ${this.getAxiosModeName()})`)
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#8E24AA')
            .onClick(() => this.testAxiosLocalNetworkErrorFilter(this.axiosMode))
            .customProperty('test-axios-local-network-error-filter-btn', 'Test Local Failure Filter (Axios)')

          Button(`Test Axios Trace Request (${this.getAxiosModeName()})`)
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosTraceRequest(this.axiosMode))
            .customProperty('test-axios-trace-btn', 'Test Axios Trace Request')

          Button(`Test 5 Concurrent Axios GET Requests (${this.getAxiosModeName()})`)
            .width('100%')
            .margin({ bottom: 16 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosConcurrentRequests(this.axiosMode))
            .customProperty('test-axios-concurrent-btn', 'Test 5 Concurrent Axios GET Requests')

          Text(`Network smoke suite: reuses module-created Axios clients and creates one Native HTTP plus one RCP request. CompatAt=${preInitCompatClientInfo.createdAt}, chainAt=${preInitChainClientInfo.createdAt}`)
            .fontSize(12)
            .fontColor('#8B5D00')
            .margin({ bottom: 8 })
            .width('100%')

          Button('Run Network Auto-track Smoke Suite (5)')
            .width('100%')
            .margin({ bottom: 16 })
            .backgroundColor('#4A148C')
            .onClick(() => this.testNetworkAutoTrackSmokeSuite())
            .customProperty('test-network-auto-track-smoke-suite-btn', 'Run Network Auto-track Smoke Suite (5)')

          Column() {
            Row() {
              Text('Test Results')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)

              Button('Clear Results')
                .height(36)
                .onClick(() => this.clearResults())
            }
            .width('100%')
            .margin({ top: 12, bottom: 10 })

            if (this.testResults.length === 0) {
              Text('No test results yet.')
                .fontSize(13)
                .fontColor('#666666')
                .width('100%')
            } else {
              ForEach(this.testResults, (result: string, index: number) => {
                Text(result)
                  .fontSize(12)
                  .fontColor('#222222')
                  .width('100%')
                  .padding({ top: 6, bottom: 6, left: 8, right: 8 })
                  .backgroundColor(index % 2 === 0 ? '#F7F8FA' : '#FFFFFF')
                  .borderRadius(4)
                  .margin({ bottom: 4 })
              }, (result: string, index: number) => `${index}-${result}`)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 12, bottom: 24 })

        }
        .width('100%')
        .padding(10)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
