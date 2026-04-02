/**
 * HTTP Interceptor Test Page
 * Test RCP HTTP Axios
 */
import {
  createFTHttpInterceptorChain,
  applyFTHttpTrack,
  createFTRCPTrackConfig
} from 'shareLibrary/src/main/ets/components/network/FTHttpAutoTrack';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
import axios, {
  AxiosInstance,
  AxiosResponse
} from '@ohos/axios';
import { FTRUMGlobalManager } from 'shareLibrary/src/main/ets/components/rum/FTRUMGlobalManager';
import { FTTraceConfigManager } from 'shareLibrary/src/main/ets/components/trace/FTTraceConfigManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "HttpAutoTrackTestPage";

interface AxiosStylePostData {
  source: string;
  message: string;
  timestamp: number;
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
    method: 'get' | 'post',
    data?: Object
  ): Promise<string> {
    const client = this.createAxiosInstance();
    const response: AxiosResponse<string | Object, Object> = await client.request<
      string | Object,
      AxiosResponse<string | Object, Object>,
      Object
    >({
      url: url,
      method: method,
      data: data,
      responseType: 'string',
      interceptorChain: createFTHttpInterceptorChain(),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
    });

    return typeof response.data === 'string'
      ? response.data
      : JSON.stringify(response.data);
  }

  private createAxiosInstance(): AxiosInstance {
    const client = axios.create({
      interceptorChain:createFTHttpInterceptorChain(),
      timeout: 10000,
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
    });
    return client;
  }

  /**
   * Check interceptor helper status
   */
  checkAutoTrackStatus() {
    try {
      const rumEnabled = FTRUMGlobalManager.getInstance().isInitialized();
      this.isAutoTrackEnabled = rumEnabled;
      this.addTestResult(`RCP interceptor session helper: ${this.isAutoTrackEnabled ? '✅ Available' : '❌ Unavailable'}`);
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
      const request = new rcp.Request('https://httpbin.org/headers', 'GET');
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
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http POST test");
        return;
      }

      const response = await this.executeHttpRequest('https://httpbin.org/post', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: JSON.stringify({
          name: 'HarmonyOS HTTP Interceptor Test',
          message: 'Testing FT http interceptor chain',
          timestamp: Date.now()
        })
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
   * Test trace headers with NetworkKit http interceptor chain
   */
  async testHttpTraceHeaders() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http trace test");
        return;
      }

      const traceConfigManager = FTTraceConfigManager.getInstance();
      if (!traceConfigManager.isAutoTraceEnabled()) {
        this.addTestResult("⚠️ Trace is not enabled, skipping http trace header test");
        return;
      }

      const response = await this.executeHttpRequest('https://httpbin.org/headers', {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/json'
        }
      });

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
    }
  }

  /**
   * Test real axios GET request with FT auto track
   */
  async testAxiosGetRequest() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping axios GET test");
        return;
      }

      const responseText = await this.executeAxiosRequest('https://httpbin.org/get?from=axios-adapter', 'get');
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios GET request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Axios GET request failed: ${errorMsg}`);
    }
  }

  /**
   * Test real axios POST request with FT auto track.
   */
  async testAxiosPostRequest() {
    try {
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping axios POST test");
        return;
      }

      const postData: AxiosStylePostData = {
        source: 'axios',
        message: 'Testing FT axios auto track',
        timestamp: Date.now()
      };
      const responseText = await this.executeAxiosRequest(
        'https://httpbin.org/post',
        'post',
        postData
      );
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios POST request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Axios POST request failed: ${errorMsg}`);
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
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testRCPGetRequest())
	            .customProperty('test-get-btn', 'Test GET Request (RCP)')

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

          Button('Test Axios GET (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosGetRequest())
            .customProperty('test-axios-get-btn', 'Test Axios GET (API 22+)')

          Button('Test Axios POST (API 22+)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosPostRequest())
            .customProperty('test-axios-post-btn', 'Test Axios POST (API 22+)')

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
