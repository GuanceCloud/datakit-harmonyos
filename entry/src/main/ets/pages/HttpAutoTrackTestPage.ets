/**
 * HTTP Interceptor Test Page
 * Test RCP HTTP request interception with FT session helpers
 */
import { createDefaultFTSessionConfiguration } from 'shareLibrary/src/main/ets/components/network/FTHttpAutoTrack';
import { applyDefaultFTHttpInterceptorChain } from 'shareLibrary/src/main/ets/components/network/FTHttpAutoTrack';
import { createFTAxiosAdapter } from 'shareLibrary/src/main/ets/components/network/FTAxiosAdapter';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http } from '@kit.NetworkKit';
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

  private createTrackedSession(baseAddress?: string): rcp.Session {
    return rcp.createSession(createDefaultFTSessionConfiguration({
      baseAddress: baseAddress
    }));
  }

  private async executeTrackedHttpRequest(
    url: string,
    options: http.HttpRequestOptions = {}
  ): Promise<http.HttpResponse> {
    const request = http.createHttp();
    applyDefaultFTHttpInterceptorChain(request);
    try {
      return await request.request(url, options);
    } finally {
      request.destroy();
    }
  }

  private async executeAxiosStyleRequest(
    url: string,
    method: 'get' | 'post',
    data?: Object
  ): Promise<string> {
    const adapter = createFTAxiosAdapter();
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json'
    };

    const response = await adapter({
      url: url,
      method: method,
      headers: headers,
      data: data,
      responseType: 'text'
    });

    if (typeof response.data === 'string') {
      return response.data;
    }
    return JSON.stringify(response.data);
  }

  /**
   * Check interceptor helper status
   */
  checkAutoTrackStatus() {
    try {
      const rumEnabled = FTRUMGlobalManager.getInstance().isInitialized();
      this.isAutoTrackEnabled = rumEnabled;
      this.addTestResult(`RCP interceptor session helper: ${this.isAutoTrackEnabled ? '✅ Available' : '❌ Unavailable'}`);
      
      if (this.isAutoTrackEnabled) {
        DemoLogger.i(TAG, "RCP interceptor session helper is available");
      } else {
        DemoLogger.w(TAG, "SDK is not initialized. Make sure RUM config has enableTraceUserResource=true");
      }
    } catch (error) {
      this.addTestResult(`❌ Failed to check interceptor helper status: ${error}`);
      DemoLogger.e(TAG, `Failed to check interceptor helper status: ${error}`);
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
   * Test GET request with FT session helper
   */
  async testGetRequestWithDefaultSession() {
    try {
      DemoLogger.i(TAG, "Testing GET request with FT session helper...");
      
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `GET request test failed: ${error}`);
    }
  }

  /**
   * Test POST request with FT session helper
   */
  async testPostRequestWithDefaultSession() {
    try {
      DemoLogger.i(TAG, "Testing POST request with FT session helper...");
      
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `POST request test failed: ${error}`);
    }
  }

  /**
   * Test creating custom session with interceptors
   */
  async testCustomSessionWithInterceptors() {
    try {
      DemoLogger.i(TAG, "Testing custom session with interceptors...");
      
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createTrackedSession('https://httpbin.org');

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
      DemoLogger.e(TAG, `Custom session test failed: ${error}`);
    }
  }

  /**
   * Test error request (404)
   */
  async testErrorRequest() {
    try {
      DemoLogger.i(TAG, "Testing error request (404)...");
      
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `Error request test failed: ${error}`);
    }
  }

  /**
   * Test trace headers (if trace is enabled)
   */
  async testTraceHeaders() {
    try {
      DemoLogger.i(TAG, "Testing trace headers...");
      
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

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `Trace headers test failed: ${error}`);
    }
  }

  /**
   * Test trace id in resource request to the configured traceUrl
   */
  async testTraceIdInResourceRequest() {
    try {
      const testUrl = this.getTraceTestUrl();
      DemoLogger.i(TAG, `Testing trace id in resource request to ${testUrl}...`);
      
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

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `Trace id test failed: ${error}`);
    }
  }

  /**
   * Test multiple requests
   */
  async testMultipleRequests() {
    try {
      DemoLogger.i(TAG, "Testing multiple requests...");
      
      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping test");
        return;
      }

      const session = this.createTrackedSession();

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
      DemoLogger.e(TAG, `Multiple requests test failed: ${error}`);
    }
  }

  /**
   * Test GET request with NetworkKit http interceptor chain
   */
  async testHttpGetRequestWithInterceptorChain() {
    try {
      DemoLogger.i(TAG, "Testing GET request with NetworkKit http interceptor chain...");

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http GET test");
        return;
      }

      const response = await this.executeTrackedHttpRequest('https://httpbin.org/get', {
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
      DemoLogger.e(TAG, `HTTP GET request test failed: ${error}`);
    }
  }

  /**
   * Test POST request with NetworkKit http interceptor chain
   */
  async testHttpPostRequestWithInterceptorChain() {
    try {
      DemoLogger.i(TAG, "Testing POST request with NetworkKit http interceptor chain...");

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http POST test");
        return;
      }

      const response = await this.executeTrackedHttpRequest('https://httpbin.org/post', {
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
      DemoLogger.e(TAG, `HTTP POST request test failed: ${error}`);
    }
  }

  /**
   * Test trace headers with NetworkKit http interceptor chain
   */
  async testHttpTraceHeaders() {
    try {
      DemoLogger.i(TAG, "Testing trace headers with NetworkKit http interceptor chain...");

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping http trace test");
        return;
      }

      const traceConfigManager = FTTraceConfigManager.getInstance();
      if (!traceConfigManager.isAutoTraceEnabled()) {
        this.addTestResult("⚠️ Trace is not enabled, skipping http trace header test");
        return;
      }

      const response = await this.executeTrackedHttpRequest('https://httpbin.org/headers', {
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
      DemoLogger.e(TAG, `HTTP trace headers test failed: ${error}`);
    }
  }

  /**
   * Test axios-compatible GET adapter
   */
  async testAxiosAdapterGetRequest() {
    try {
      DemoLogger.i(TAG, "Testing axios-compatible GET adapter...");

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping axios GET test");
        return;
      }

      const responseText = await this.executeAxiosStyleRequest('https://httpbin.org/get?from=axios-adapter', 'get');
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios-style GET request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Axios-style GET request failed: ${errorMsg}`);
      DemoLogger.e(TAG, `Axios-style GET request test failed: ${error}`);
    }
  }

  /**
   * Test axios-compatible POST adapter
   */
  async testAxiosAdapterPostRequest() {
    try {
      DemoLogger.i(TAG, "Testing axios-compatible POST adapter...");

      if (!this.isAutoTrackEnabled) {
        this.addTestResult("⚠️ Auto Track not enabled, skipping axios POST test");
        return;
      }

      const postData: AxiosStylePostData = {
        source: 'axios-adapter',
        message: 'Testing FT axios adapter',
        timestamp: Date.now()
      };
      const responseText = await this.executeAxiosStyleRequest(
        'https://httpbin.org/post',
        'post',
        postData
      );
      this.requestCount++;
      this.successCount++;
      this.addTestResult(`✅ Axios-style POST request succeeded: bodyLength=${responseText.length}`);
    } catch (error) {
      this.requestCount++;
      this.errorCount++;
      const err = error as BusinessError;
      const errorMsg = err.message || String(error);
      this.addTestResult(`❌ Axios-style POST request failed: ${errorMsg}`);
      DemoLogger.e(TAG, `Axios-style POST request test failed: ${error}`);
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
	          Button('Test GET Request (FT Session)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testGetRequestWithDefaultSession())
	            .customProperty('test-get-btn', 'Test GET Request (FT Session)')

	          Button('Test POST Request (FT Session)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testPostRequestWithDefaultSession())
	            .customProperty('test-post-btn', 'Test POST Request (FT Session)')

          Button('Test Custom Session (With Interceptors)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testCustomSessionWithInterceptors())
            .customProperty('test-custom-session-btn', 'Test Custom Session (With Interceptors)')

          Button('Test Error Request (404)')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testErrorRequest())
            .customProperty('test-error-btn', 'Test Error Request (404)')

          Button('Test Trace Headers')
            .width('100%')
            .margin({ bottom: 10 })
            .onClick(() => this.testTraceHeaders())
            .customProperty('test-trace-headers-btn', 'Test Trace Headers')

          Button('Test HTTP GET Request (Interceptor Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpGetRequestWithInterceptorChain())
            .customProperty('test-http-get-btn', 'Test HTTP GET Request (Interceptor Chain)')

          Button('Test HTTP POST Request (Interceptor Chain)')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpPostRequestWithInterceptorChain())
            .customProperty('test-http-post-btn', 'Test HTTP POST Request (Interceptor Chain)')

          Button('Test HTTP Trace Headers')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#1976D2')
            .onClick(() => this.testHttpTraceHeaders())
            .customProperty('test-http-trace-btn', 'Test HTTP Trace Headers')

          Button('Test Axios Adapter GET')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosAdapterGetRequest())
            .customProperty('test-axios-get-btn', 'Test Axios Adapter GET')

          Button('Test Axios Adapter POST')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#FF9800')
            .onClick(() => this.testAxiosAdapterPostRequest())
            .customProperty('test-axios-post-btn', 'Test Axios Adapter POST')

          Button('Test Trace ID in /api/user')
            .width('100%')
            .margin({ bottom: 10 })
            .backgroundColor('#4CAF50')
            .onClick(() => this.testTraceIdInResourceRequest())
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
