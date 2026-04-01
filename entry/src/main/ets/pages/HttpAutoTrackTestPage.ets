/**
 * HTTP Interceptor Test Page
 * Test RCP HTTP request interception with FT session helpers
 */
import { createDefaultFTSessionConfiguration } from 'shareLibrary/src/main/ets/components/network/FTHttpAutoTrack';
import { rcp } from '@kit.RemoteCommunicationKit';
import { FTRUMGlobalManager } from 'shareLibrary/src/main/ets/components/rum/FTRUMGlobalManager';
import { FTTraceConfigManager } from 'shareLibrary/src/main/ets/components/trace/FTTraceConfigManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "HttpAutoTrackTestPage";

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
    this.testResults.push(`[${new Date().toLocaleTimeString()}] ${result}`);
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

      this.addTestResult("📤 Sending GET request to httpbin.org/get...");
      
      // Send GET request (should be automatically intercepted)
      const request = new rcp.Request('https://httpbin.org/get', 'GET');
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ GET request successful: ${response.statusCode}`);
        this.addTestResult(`Response effective URL: ${response.effectiveUrl?.href || 'N/A'}`);
        
        // Log time info if available
        if (response.timeInfo) {
          this.addTestResult(`TimeInfo available: ${JSON.stringify(response.timeInfo).substring(0, 100)}...`);
        }
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ GET request returned status: ${response.statusCode}`);
      }

      // Wait a moment for RUM data to be collected
      setTimeout(() => {
        this.addTestResult("✅ GET request with FT session helper completed");
      }, 500);

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

      this.addTestResult("📤 Sending POST request to httpbin.org/post...");
      
      // Send POST request (should be automatically intercepted)
      const headers: rcp.RequestHeaders = {
        'Content-Type': 'application/json'
      };
      const request = new rcp.Request('https://httpbin.org/post', 'POST', headers, postData);
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ POST request successful: ${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ POST request returned status: ${response.statusCode}`);
      }

      setTimeout(() => {
        this.addTestResult("✅ POST request with FT session helper completed");
      }, 500);

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

      this.addTestResult("📤 Sending GET request with custom session...");
      
      // Send GET request (should be automatically intercepted)
      const request = new rcp.Request('/get', 'GET');
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Custom session GET request successful: ${response.statusCode}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Custom session GET request returned status: ${response.statusCode}`);
      }

      setTimeout(() => {
        this.addTestResult("✅ Custom session with interceptors test completed");
      }, 500);

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

      this.addTestResult("📤 Sending GET request to non-existent endpoint...");
      
      // Send GET request to non-existent endpoint (should return 404)
      const request = new rcp.Request('https://httpbin.org/status/404', 'GET');
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode === 404) {
        this.addTestResult(`✅ Error request intercepted correctly: ${response.statusCode}`);
        // 404 is expected, so we don't count it as an error
        this.successCount++;
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Unexpected status code: ${response.statusCode}`);
      }

      setTimeout(() => {
        this.addTestResult("✅ Error request test completed");
      }, 500);

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

      this.addTestResult("📤 Sending GET request to check trace headers...");
      
      // Send GET request (trace headers should be added automatically)
      const request = new rcp.Request('https://httpbin.org/headers', 'GET');
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Trace headers request successful: ${response.statusCode}`);
        
        // Note: Response body access depends on RCP API
        this.addTestResult(`Response URL: ${response.effectiveUrl?.href || 'N/A'}`);
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Trace headers request returned status: ${response.statusCode}`);
      }

      setTimeout(() => {
        this.addTestResult("✅ Trace headers test completed");
      }, 500);

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
        this.addTestResult("   Please enable trace in SDK config: setEnableAutoTrace(true)");
        return;
      }

      const session = this.createTrackedSession();

      this.addTestResult(`📤 Sending GET request to ${testUrl}...`);
      this.addTestResult("   Check logs for: [RCP-Trace] Added trace headers");
      
      // Send GET request (trace headers should be added automatically)
      const request = new rcp.Request(testUrl, 'GET');
      const response = await session.fetch(request);
      
      this.requestCount++;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.successCount++;
        this.addTestResult(`✅ Request successful: ${response.statusCode}`);
        this.addTestResult(`   Response URL: ${response.effectiveUrl?.href || 'N/A'}`);
        this.addTestResult("   ✅ Trace headers should be added automatically");
        this.addTestResult("   📋 Check logs for trace header details:");
        this.addTestResult("      - [RCP-Trace] Added trace headers");
        this.addTestResult("      - Look for: x-datadog-trace-id, x-datadog-parent-id");
      } else {
        this.errorCount++;
        this.addTestResult(`⚠️ Request returned status: ${response.statusCode}`);
        this.addTestResult("   Trace headers may still be added (check logs)");
      }

      setTimeout(() => {
        this.addTestResult("✅ Trace id in resource request test completed");
        this.addTestResult("   💡 Tip: Check logcat/logs for '[RCP-Trace] Added trace headers'");
      }, 500);

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

      this.addTestResult("📤 Sending 5 concurrent GET requests...");
      
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
   * Clear test results
   */
  clearResults() {
    this.testResults = [];
    this.requestCount = 0;
    this.successCount = 0;
    this.errorCount = 0;
    this.addTestResult("Test results cleared");
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

          Button('Clear Results')
            .width('100%')
            .margin({ bottom: 10 })
            .type(ButtonType.Normal)
            .backgroundColor('#FF6B6B')
            .onClick(() => this.clearResults())
            .customProperty('clear-results-btn', 'Clear Results')

          Divider()
            .margin({ top: 20, bottom: 10 })

          Text('Test Results:')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .textAlign(TextAlign.Start)

          ForEach(this.testResults, (result: string, index: number) => {
            Text(result)
              .fontSize(12)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ top: 5, bottom: 5 })
              .borderRadius(4)
              .backgroundColor(index % 2 === 0 ? '#F5F5F5' : '#FFFFFF')
          }, (item: string) => item)

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
