/**
 * HTTP Interceptor Test Page
 * Test RCP HTTP Axios
 */
import {
  applyFTAxiosTrack,
  createFTRCPTrackConfig,
  FTRUMGlobalManager,
  FTSDK,
  FTTraceConfig,
  FTTraceConfigManager,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceManager,
  FTTraceRequestContext,
  TraceType
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
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from '../utils/DemoLogger';
import {
  preInitChainClient,
  preInitChainClientInfo,
  preInitCompatClient,
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
type AxiosHttpMethod = 'get' | 'post' | 'put' | 'patch' | 'delete';

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
  @StorageLink(KEY_TRACE_URL) storedTraceUrl: string = "";

  aboutToAppear() {
    this.checkAutoTrackStatus();
  }

  private createRCPSession(baseAddress?: string): rcp.Session {
    return rcp.createSession(createFTRCPTrackConfig({
      baseAddress: baseAddress
    }));
  }

  private async executeHttpRequest(
    url: string,
    options: http.HttpRequestOptions = {}
  ): Promise<http.HttpResponse> {
    const request = http.createHttp();
    applyFTHttpTrack(request);
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
    const client = this.createAxiosInstance(mode);
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

    return typeof response.data === 'string'
      ? response.data
      : JSON.stringify(response.data);
  }

  private async executeAxiosRequestWithClient(
    client: AxiosInstance,
    url: string,
    method: AxiosHttpMethod,
    data?: Object
  ): Promise<string> {
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

    return typeof response.data === 'string'
      ? response.data
      : JSON.stringify(response.data);
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
      axiosConfig.interceptorChain = createFTHttpInterceptorChain();
    }

    const client = axios.create(axiosConfig);
    if (mode === 'compat') {
      applyFTAxiosTrack(client);
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

  private getAxiosRequestUrl(method: AxiosHttpMethod, mode: AxiosAutoTrackMode): string {
    const from = mode === 'chain' ? 'axios-chain' : 'axios-adapter';
    if (method === 'get') {
      return `https://httpbin.org/get?from=${from}`;
    }
    if (method === 'delete') {
      return `https://httpbin.org/delete?from=${from}`;
    }
    return `https://httpbin.org/${method}`;
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

      const requestData = method === 'get' || method === 'delete'
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

      // Send GET request (should be automatically intercepted)
      const request = new rcp.Request('https://httpbin.org/get', 'GET');
      const response = await session.fetch(request);

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
   * Test creating custom session with interceptors
   */
  async testRCPWithInterceptors() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createRCPSession('https://httpbin.org');

      // Send GET request (should be automatically intercepted)
      const request = new rcp.Request('/get', 'GET');
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Custom session request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Custom session request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Custom session test failed: ${errorMsg}`);
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

  /**
   * Test trace headers (if trace is enabled)
   */
  async testRCPTraceHeaders() {
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult("⚠️ traceUrl not configured, skipping trace header test");
        return;
      }

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const traceConfigManager = FTTraceConfigManager.getInstance();
      const isTraceEnabled = traceConfigManager.isAutoTraceEnabled();

      if (!isTraceEnabled) {
        this.addTestResult("⚠️ Trace is not enabled, skipping trace header test");
        return;
      }

      const session = this.createRCPSession();

      // Send GET request (trace headers should be added automatically)
      const request = new rcp.Request(testUrl, 'GET');
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Trace headers request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Trace headers request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Trace headers test failed: ${errorMsg}`);
    }
  }

  /**
   * Test trace id in resource request to the configured traceUrl
   */
  async testRCPTraceWithRequest() {
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult("⚠️ traceUrl not configured, skipping trace id test");
        return;
      }

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const traceConfigManager = FTTraceConfigManager.getInstance();
      const isTraceEnabled = traceConfigManager.isAutoTraceEnabled();

      if (!isTraceEnabled) {
        this.addTestResult("⚠️ Trace is not enabled, skipping trace id test");
        return;
      }

      const session = this.createRCPSession();

      // Send GET request (trace headers should be added automatically)
      const request = new rcp.Request(testUrl, 'GET');
      const response = await session.fetch(request);

      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Trace-id request succeeded: status=${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Trace-id request returned status=${response.statusCode}`);
      }

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Trace id test failed: ${errorMsg}`);
    }
  }

  /**
   * Test multiple requests
   */
  async testMultipleRequests() {
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

      this.addTestResult(`✅ Multiple requests completed: ${success}/${responses.length} successful`);

    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Multiple requests test failed: ${errorMsg}`);
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

      const response = await this.executeHttpRequest('https://httpbin.org/get', {
        method: http.RequestMethod.GET,
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
    const previousTraceConfig = FTTraceConfigManager.getInstance().getConfig();
    let temporaryTraceConfigInstalled = false;
    const headerTraceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const headerSpanId = 'bbbbbbbbbbbbbbbb';

    class PostHeaderTraceHeaderHandler implements FTTraceHeaderHandler {
      public called: boolean = false;
      public requestMethod: string = "";
      public requestContentType: string = "";
      public parsedTraceId: string = "";
      public parsedSpanId: string = "";
      public finalTraceId: string = "";
      public finalSpanId: string = "";

      getTraceContext(request: FTTraceRequestContext): FTTraceContext {
        this.called = true;
        this.requestMethod = request.method;
        this.requestContentType = request.headers['Content-Type'] || request.headers['content-type'] || '';

        const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
        this.parsedTraceId = this.getHeaderValue(request.headers, 'x-existing-trace-id');
        this.parsedSpanId = this.getHeaderValue(request.headers, 'x-existing-span-id');
        if (this.isValidTraceId(this.parsedTraceId) && this.isValidSpanId(this.parsedSpanId)) {
          traceContext.traceId = this.parsedTraceId;
          traceContext.spanId = this.parsedSpanId;
          traceContext.headers['traceparent'] = `00-${this.parsedTraceId}-${this.parsedSpanId}-01`;
          traceContext.headers['x-header-trace-source'] = 'http-post-header';
        }

        this.finalTraceId = traceContext.traceId;
        this.finalSpanId = traceContext.spanId;
        return traceContext;
      }

      private getHeaderValue(headers: Record<string, string>, key: string): string {
        const directValue = headers[key];
        if (directValue !== undefined) {
          return directValue;
        }

        const normalizedKey = key.toLowerCase();
        const headerKeys = Object.keys(headers);
        for (let i = 0; i < headerKeys.length; i++) {
          const headerKey = headerKeys[i];
          if (headerKey.toLowerCase() === normalizedKey) {
            return headers[headerKey];
          }
        }
        return '';
      }

      private isValidTraceId(traceId: string): boolean {
        return traceId.length === 32 && this.isLowercaseHex(traceId);
      }

      private isValidSpanId(spanId: string): boolean {
        return spanId.length === 16 && this.isLowercaseHex(spanId);
      }

      private isLowercaseHex(value: string): boolean {
        for (let i = 0; i < value.length; i++) {
          const code = value.charCodeAt(i);
          const isDigit = code >= 48 && code <= 57;
          const isLowercaseHexLetter = code >= 97 && code <= 102;
          if (!isDigit && !isLowercaseHexLetter) {
            return false;
          }
        }
        return true;
      }
    }

    const traceHeaderHandler = new PostHeaderTraceHeaderHandler();
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http POST test");
        return;
      }

      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.TRACEPARENT)
        .setTraceHeaderHandler(traceHeaderHandler);
      FTSDK.installTraceConfig(traceConfig);
      temporaryTraceConfigInstalled = true;
      this.addTestResult("✅ Installed TraceConfig with POST header Trace Header handler");

      const postBody = JSON.stringify({
        name: 'HarmonyOS HTTP Interceptor Test',
        message: 'Testing FT http interceptor chain',
        timestamp: Date.now()
      });
      const response = await this.executeHttpRequest('https://httpbin.org/post', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'x-existing-trace-id': headerTraceId,
          'x-existing-span-id': headerSpanId
        },
        extraData: postBody
      });

      if (traceHeaderHandler.called &&
        traceHeaderHandler.parsedTraceId === headerTraceId &&
        traceHeaderHandler.parsedSpanId === headerSpanId &&
        traceHeaderHandler.finalTraceId === headerTraceId &&
        traceHeaderHandler.finalSpanId === headerSpanId) {
        this.addTestResult(`✅ Handler parsed trace_id/span_id from request.headers: traceId=${traceHeaderHandler.finalTraceId}, spanId=${traceHeaderHandler.finalSpanId}`);
        this.addTestResult("✅ Request header uses existing header trace context: traceparent + x-header-trace-source");
      } else if (traceHeaderHandler.called &&
        (traceHeaderHandler.parsedTraceId.length === 0 || traceHeaderHandler.parsedSpanId.length === 0)) {
        this.addTestResult("⚠️ Handler called, but x-existing-trace-id/x-existing-span-id headers are missing.");
      } else {
        this.addTestResult(`❌ Handler did not parse header trace context: parsedTraceId=${traceHeaderHandler.parsedTraceId}, parsedSpanId=${traceHeaderHandler.parsedSpanId}`);
      }

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
      if (traceHeaderHandler.called) {
        this.addTestResult(`⚠️ Handler already ran before POST failed: parsedTraceId=${traceHeaderHandler.parsedTraceId}, parsedSpanId=${traceHeaderHandler.parsedSpanId}`);
      }
    } finally {
      if (temporaryTraceConfigInstalled) {
        if (previousTraceConfig) {
          FTSDK.installTraceConfig(previousTraceConfig);
          this.addTestResult("✅ Restored previous TraceConfig after HTTP POST test");
        } else {
          FTTraceConfigManager.getInstance().reset();
          this.addTestResult("✅ Cleared temporary TraceConfig after HTTP POST test");
        }
      }
    }
  }

  /**
   * Test trace headers with NetworkKit http interceptor chain
   */
  async testHttpTraceHeaders() {
    const previousTraceConfig = FTTraceConfigManager.getInstance().getConfig();
    let temporaryTraceConfigInstalled = false;
    try {
      const testUrl = this.getTraceTestUrl();
      if (testUrl.length === 0) {
        this.addTestResult("⚠️ traceUrl not configured, skipping http trace header test");
        return;
      }

      class HttpTraceHeaderHandler implements FTTraceHeaderHandler {
        public called: boolean = false;
        public traceUrl: string = "";
        public traceId: string = "";
        public spanId: string = "";
        public requestMethod: string = "";
        public requestAccept: string = "";

        getTraceContext(request: FTTraceRequestContext): FTTraceContext {
          this.called = true;
          this.traceUrl = request.url;
          this.requestMethod = request.method;
          this.requestAccept = request.headers['Accept'] || '';
          const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
          this.traceId = traceContext.traceId;
          this.spanId = traceContext.spanId;
          traceContext.headers['x-handler-trace-id'] = traceContext.traceId;
          traceContext.headers['x-handler-span-id'] = traceContext.spanId;
          traceContext.headers['x-handler-source'] = 'http-api22';
          return traceContext;
        }
      }

      const traceHeaderHandler = new HttpTraceHeaderHandler();
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceType(TraceType.TRACEPARENT)
        .setTraceHeaderHandler(traceHeaderHandler);
      FTSDK.installTraceConfig(traceConfig);
      temporaryTraceConfigInstalled = true;
      this.addTestResult("✅ Installed TraceConfig with custom setTraceHeaderHandler for HTTP trace test");

      const traceConfigManager = FTTraceConfigManager.getInstance();
      if (!traceConfigManager.isAutoTraceEnabled()) {
        this.addTestResult("⚠️ Trace is not enabled, skipping http trace header test");
        return;
      }

      const response = await this.executeHttpRequest(testUrl, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/json'
        }
      });

      if (traceHeaderHandler.called &&
        traceHeaderHandler.traceId.length > 0 &&
        traceHeaderHandler.spanId.length > 0 &&
        traceHeaderHandler.traceUrl === testUrl) {
        this.addTestResult(`✅ setTraceHeaderHandler called: traceId=${traceHeaderHandler.traceId}, spanId=${traceHeaderHandler.spanId}`);
        this.addTestResult(`✅ Request context received: method=${traceHeaderHandler.requestMethod}, accept=${traceHeaderHandler.requestAccept}`);
        this.addTestResult("✅ Custom headers appended: x-handler-trace-id, x-handler-span-id, x-handler-source");
      } else {
        this.addTestResult("❌ setTraceHeaderHandler was not called by HTTP interceptor chain");
      }

      this.requestCount++;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ HTTP trace headers request succeeded: status=${response.responseCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ HTTP trace headers request returned status=${response.responseCode}`);
      }
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ HTTP trace headers test failed: ${errorMsg}`);
    } finally {
      if (temporaryTraceConfigInstalled) {
        if (previousTraceConfig) {
          FTSDK.installTraceConfig(previousTraceConfig);
          this.addTestResult("✅ Restored previous TraceConfig after HTTP trace test");
        } else {
          FTTraceConfigManager.getInstance().reset();
          this.addTestResult("✅ Cleared temporary TraceConfig after HTTP trace test");
        }
      }
    }
  }

  /**
   * Test real axios GET request with FT auto track compat interceptors.
   */
  async testAxiosGetCompatRequest() {
    await this.testAxiosMethodRequest('compat', 'get');
  }

  /**
   * Test real axios POST request with FT auto track compat interceptors.
   */
  async testAxiosPostCompatRequest() {
    await this.testAxiosMethodRequest('compat', 'post');
  }

  /**
   * Test real axios GET request with interceptorChain.
   */
  async testAxiosGetChainRequest() {
    await this.testAxiosMethodRequest('chain', 'get');
  }

  /**
   * Test real axios POST request with interceptorChain.
   */
  async testAxiosPostChainRequest() {
    await this.testAxiosMethodRequest('chain', 'post');
  }

  /**
   * Test real axios PUT request with interceptorChain.
   */
  async testAxiosPutChainRequest() {
    await this.testAxiosMethodRequest('chain', 'put');
  }

  /**
   * Test real axios PATCH request with interceptorChain.
   */
  async testAxiosPatchChainRequest() {
    await this.testAxiosMethodRequest('chain', 'patch');
  }

  /**
   * Test real axios DELETE request with interceptorChain.
   */
  async testAxiosDeleteChainRequest() {
    await this.testAxiosMethodRequest('chain', 'delete');
  }

  async testSharedPreInitAxiosCompatRequest() {
    try {
      const responseText = await this.executeAxiosRequestWithClient(
        preInitCompatClient,
        'https://httpbin.org/get?from=shared-preinit-compat',
        'get'
      );
      this.requestCount++;
      this.successCount++;
      this.addTestResult(
        `✅ Shared pre-init Axios compat request succeeded: createdAt=${preInitCompatClientInfo.createdAt}, bodyLength=${responseText.length}`
      );
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Shared pre-init Axios compat request failed: ${errorMsg}`);
    }
  }

  async testSharedPreInitAxiosChainRequest() {
    try {
      const responseText = await this.executeAxiosRequestWithClient(
        preInitChainClient,
        'https://httpbin.org/get?from=shared-preinit-chain',
        'get'
      );
      this.requestCount++;
      this.successCount++;
      this.addTestResult(
        `✅ Shared pre-init Axios chain request succeeded: createdAt=${preInitChainClientInfo.createdAt}, bodyLength=${responseText.length}`
      );
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Shared pre-init Axios chain request failed: ${errorMsg}`);
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

  async testSharedPreInitAxiosSmokeSuite() {
    const executionMode: PreInitAxiosSmokeExecutionMode = 'parallel';
    const urls: PreInitAxiosSmokeUrls = {
      compatUrl: this.buildPreInitSmokeTestUrl('compat'),
      chainUrl: this.buildPreInitSmokeTestUrl('chain')
    };
    this.addTestResult(
      `▶ Running pre-init Axios smoke suite: mode=${executionMode}, compatAt=${preInitCompatClientInfo.createdAt}, ` +
      `chainAt=${preInitChainClientInfo.createdAt}, controlAt=${preInitControlChainClientInfo.createdAt}`
    );

    try {
      const results = await runPreInitAxiosSmokeTestsWithMode(urls, executionMode);
      for (let index = 0; index < results.length; index++) {
        const result = results[index];
        this.requestCount++;
        if (result.success) {
          this.successCount++;
          this.addTestResult(`✅ Pre-init ${result.mode}: status=${result.statusCode}, bodyLength=${result.bodyLength}`);
        } else {
          this.errorCount++;
          this.addTestResult(`❌ Pre-init ${result.mode}: ${result.errorMessage || 'unknown error'}`);
        }
      }
    } catch (error) {
      this.errorCount++;
      const err = error as BusinessError;
      this.addTestResult(`❌ Pre-init Axios smoke suite failed: ${err.message || String(error)}`);
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
          Button('Test GET Request (RCP)')
            .id('test-get-btn')
            .width('100%')
            .margin({ bottom: 10 })
            .customProperty('test-get-btn', 'Test GET Request (RCP)')
            .onClick(() => this.testRCPGetRequest())

          Button('Test POST Request (RCP)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPPostRequest())
            .customProperty('test-post-btn', 'Test POST Request (RCP)')

          Button('Test Custom Session (With Interceptors)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPWithInterceptors())
            .customProperty('test-custom-session-btn', 'Test Custom Session (With Interceptors)')

          Button('Test Error Request (404)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPErrorRequest())
            .customProperty('test-error-btn', 'Test Error Request (404)')

          Button('Test Trace Headers')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPTraceHeaders())
            .customProperty('test-trace-headers-btn', 'Test Trace Headers')

          Button('Test HTTP GET Request (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpGetRequestWithInterceptorChain())
            .customProperty('test-http-get-btn', 'Test HTTP GET Request (API 22+)')

          Button('Test HTTP POST Request (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpPostRequestWithInterceptorChain())
            .customProperty('test-http-post-btn', 'Test HTTP POST Request (API 22+)')

          Button('Test HTTP Trace Headers (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpTraceHeaders())
            .customProperty('test-http-trace-btn', 'Test HTTP Trace Headers (API 22+)')

          Text('Axios Auto Track Modes')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 6, bottom: 8 })
            .width('100%')

          Text('Compat: applyFTAxiosTrack(client). Chain: createFTHttpInterceptorChain() + applyFTAxiosChainMethodBridge(client).')
            .fontSize(12)
            .margin({ bottom: 10 })
            .width('100%')

          Text(`Shared Axios clients are created when this test page is loaded. CompatAt=${preInitCompatClientInfo.createdAt}, chainAt=${preInitChainClientInfo.createdAt}`)
            .fontSize(12)
            .margin({ bottom: 10 })
            .width('100%')

          Button('Run Shared Pre-init Axios Smoke Suite (5)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#4A148C')
            .onClick(() => this.testSharedPreInitAxiosSmokeSuite())
            .customProperty('test-shared-preinit-smoke-suite-btn', 'Run Shared Pre-init Axios Smoke Suite (5)')

          Button('Use Shared Pre-init Axios (Compat)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#7B1FA2')
            .onClick(() => {
              this.testSharedPreInitAxiosCompatRequest()
            })
            .customProperty('test-shared-preinit-compat-btn', 'Use Shared Pre-init Axios (Compat)')

          Button('Use Shared Pre-init Axios (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#6A1B9A')
            .onClick(() => this.testSharedPreInitAxiosChainRequest())
            .customProperty('test-shared-preinit-chain-btn', 'Use Shared Pre-init Axios (Chain)')

          Button('Test Axios GET (Compat)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosGetCompatRequest())
            .customProperty('test-axios-compat-get-btn', 'Test Axios GET (Compat)')

          Button('Test Axios POST (Compat)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosPostCompatRequest())
            .customProperty('test-axios-compat-post-btn', 'Test Axios POST (Compat)')

          Button('Test Axios GET (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FB8C00')
            .onClick(() => this.testAxiosGetChainRequest())
            .customProperty('test-axios-chain-get-btn', 'Test Axios GET (Chain)')

          Button('Test Axios POST (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FB8C00')
            .onClick(() => {
              this.testAxiosPostChainRequest()
            })
            .customProperty('test-axios-chain-post-btn', 'Test Axios POST (Chain)')

          Button('Test Axios PUT (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FB8C00')
            .onClick(() => this.testAxiosPutChainRequest())
            .customProperty('test-axios-chain-put-btn', 'Test Axios PUT (Chain)')

          Button('Test Axios PATCH (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FB8C00')
            .onClick(() => this.testAxiosPatchChainRequest())
            .customProperty('test-axios-chain-patch-btn', 'Test Axios PATCH (Chain)')

          Button('Test Axios DELETE (Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FB8C00')
            .onClick(() => this.testAxiosDeleteChainRequest())
            .customProperty('test-axios-chain-delete-btn', 'Test Axios DELETE (Chain)')

          Button('Test Trace ID in /api/user')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#4CAF50')
            .onClick(() => this.testRCPTraceWithRequest())
            .customProperty('test-trace-id-btn', 'Test Trace ID in /api/user')

          Button('Test Multiple Requests')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testMultipleRequests())
            .customProperty('test-multiple-requests-btn', 'Test Multiple Requests')

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
