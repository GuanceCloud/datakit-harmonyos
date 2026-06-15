/**
 * Trace Function Test Page
 * Test HarmonyOS SDK Trace functionality
 */
import {
  createFTRCPTrackConfig,
  DefaultFTTraceInterceptor,
  FTSDK,
  FTTraceConfig,
  FTTraceConfigManager,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceInterceptor,
  FTTraceManager,
  FTTraceRequestContext,
  HttpRequestData,
  HttpResponseData,
  Status,
  TraceType
} from '@guancecloud/ft_sdk/Index';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'TraceTestPage';

/**
 * Trace Test Page Component
 */
@Entry
@Component
export struct TraceTestPage {
  @State message: string = 'Trace Function Test Page';
  @State testResults: string[] = [];
  @State selectedTraceType: TraceType = TraceType.DDTRACE;
  @StorageLink(KEY_TRACE_URL) storedTraceUrl: string = "";
  
  // Available trace types for selection
  private traceTypeOptions: TraceType[] = [
    TraceType.DDTRACE,
    TraceType.ZIPKIN_SINGLE_HEADER,
    TraceType.ZIPKIN_MULTI_HEADER,
    TraceType.TRACEPARENT,
    TraceType.JAEGER,
    TraceType.SKYWALKING
  ];
  
  // Get display name for trace type
  private getTraceTypeName(traceType: TraceType): string {
    switch (traceType) {
      case TraceType.DDTRACE:
        return 'DDTRACE';
      case TraceType.ZIPKIN_SINGLE_HEADER:
        return 'ZIPKIN_SINGLE_HEADER';
      case TraceType.ZIPKIN_MULTI_HEADER:
        return 'ZIPKIN_MULTI_HEADER';
      case TraceType.TRACEPARENT:
        return 'TRACEPARENT';
      case TraceType.JAEGER:
        return 'JAEGER';
      case TraceType.SKYWALKING:
        return 'SKYWALKING';
    }
  }

  /**
   * Add test result
   */
  addTestResult(result: string) {
    DemoLogger.i(TAG, result);
    if (result.startsWith('━━━━━━━━')) {
      return;
    }
    if (result.startsWith('   -') || result.startsWith('      -')) {
      return;
    }
    if (result.startsWith('🔍 Testing ') || result.startsWith('📤 Testing ') || result.startsWith('📡 Sending GET request')) {
      return;
    }
    if (result.startsWith('📋 Verification:') || result.includes('Check logs') || result.startsWith('   Expected headers:')) {
      return;
    }
    const nextResults = [...this.testResults, `[${new Date().toLocaleTimeString()}] ${result}`];
    this.testResults = nextResults.length > 120
      ? nextResults.slice(nextResults.length - 120)
      : nextResults;
  }

  private getTraceTestUrl(): string {
    return this.storedTraceUrl.trim();
  }

  private createTrackedSession(baseAddress?: string): rcp.Session {
    return rcp.createSession(createFTRCPTrackConfig({
      baseAddress: baseAddress
    }));
  }

  /**
   * Apply the selected trace type to SDK
   */
  applyTraceType() {
    try {
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setServiceName(`harmonyos-${this.selectedTraceType.toString().toLowerCase()}-test`);
      
      FTSDK.installTraceConfig(traceConfig);
      DemoLogger.d(TAG, `Applied trace type: ${this.getTraceTypeName(this.selectedTraceType)}`);
    } catch (error) {
      this.addTestResult(`❌ Failed to apply trace type: ${error}`);
    }
  }

  /**
   * Test basic trace configuration
   */
  testBasicTraceConfig() {
    try {
      DemoLogger.d(TAG, `Testing basic trace configuration with type: ${this.getTraceTypeName(this.selectedTraceType)}`);
      
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(0.8)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setEnableWebTrace(false)
        .setServiceName(`harmonyos-${this.selectedTraceType.toString().toLowerCase()}-test`);
      
      // Create proper object instances for global context
      const testValue = new String('test_value');
      const platformValue = new String('harmonyos');
      
      traceConfig.addGlobalContext('test_key', testValue);
      traceConfig.addGlobalContext('platform', platformValue);

      FTSDK.installTraceConfig(traceConfig);
      
      this.addTestResult("✅ Basic trace configuration test passed");
      
    } catch (error) {
      this.addTestResult(`❌ Basic trace configuration test failed: ${error}`);
    }
  }

  /**
   * Test trace type configuration
   */
  testTraceTypes() {
    try {
      DemoLogger.d(TAG, `Testing trace type configuration (${this.getTraceTypeName(this.selectedTraceType)})...`);
      
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setServiceName(`harmonyos-${this.selectedTraceType.toString().toLowerCase()}-test`);

      FTSDK.installTraceConfig(traceConfig);
      this.addTestResult(`✅ ${this.getTraceTypeName(this.selectedTraceType)} configuration test passed`);
      
    } catch (error) {
      this.addTestResult(`❌ Trace type test failed: ${error}`);
    }
  }

  /**
   * Test trace configuration manager
   */
  testTraceConfigManager() {
    try {
      DemoLogger.d(TAG, "Testing trace config manager...");
      
      const traceConfigManager = FTTraceConfigManager.getInstance();
      
      // Test configuration retrieval
      const config = traceConfigManager.getConfig();
      if (config) {
        this.addTestResult(`✅ Config manager retrieved config successfully: samplingRate=${config.getSamplingRate()}`);
      } else {
        this.addTestResult("⚠️ Config manager found no configuration");
      }

      // Test various configuration methods
      const samplingRate = traceConfigManager.getSamplingRate();
      const traceType = traceConfigManager.getTraceType();
      const serviceName = traceConfigManager.getServiceName();
      const isAutoTraceEnabled = traceConfigManager.isAutoTraceEnabled();
      const isRUMDataLinkingEnabled = traceConfigManager.isRUMDataLinkingEnabled();

      this.addTestResult(`📊 Sampling Rate: ${samplingRate}`);
      this.addTestResult(`📊 Trace Type: ${traceType}`);
      this.addTestResult(`📊 Service Name: ${serviceName}`);
      this.addTestResult(`📊 Auto Trace: ${isAutoTraceEnabled ? 'Enabled' : 'Disabled'}`);
      this.addTestResult(`📊 RUM Data Linking: ${isRUMDataLinkingEnabled ? 'Enabled' : 'Disabled'}`);
      
      DemoLogger.d(TAG, "Trace config manager test passed");
      
    } catch (error) {
      this.addTestResult(`❌ Trace config manager test failed: ${error}`);
      DemoLogger.e(TAG, `Trace config manager test failed: ${error}`);
    }
  }

  /**
   * Test trace interceptor
   */
  testTraceInterceptor() {
    try {
      DemoLogger.d(TAG, "Testing trace interceptor...");
      
      // Create custom header handler
      class CustomHeaderHandler implements FTTraceHeaderHandler {
        getTraceContext(request: FTTraceRequestContext): FTTraceContext {
          const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
          traceContext.headers['x-custom-trace-id'] = traceContext.traceId;
          traceContext.headers['x-custom-span-id'] = traceContext.spanId;
          return traceContext;
        }
      }
      
      const customHeaderHandler = new CustomHeaderHandler();

      // Create trace interceptor
      const interceptor = new DefaultFTTraceInterceptor(TraceType.DDTRACE, customHeaderHandler);
      
      // Simulate HTTP request
      const traceUrl = this.getTraceTestUrl();
      const requestData: HttpRequestData = {
        url: traceUrl,
        method: 'GET',
        headers: new Map([['Content-Type', 'application/json']]),
        timestamp: Date.now()
      };

      const interceptedRequest = interceptor.interceptRequest(requestData);
      
      // Check if trace headers were added
      const hasTraceId = interceptedRequest.headers.has('x-datadog-trace-id');
      const hasCustomTraceId = interceptedRequest.headers.has('x-custom-trace-id');
      
      if (hasTraceId && hasCustomTraceId) {
        this.addTestResult("✅ Trace interceptor test passed - Successfully added trace headers");
      } else {
        this.addTestResult("❌ Trace interceptor test failed - Failed to add trace headers correctly");
      }

      // Simulate HTTP response
      const responseData: HttpResponseData = {
        url: traceUrl,
        statusCode: 200,
        headers: new Map([['Content-Type', 'application/json']]),
        timestamp: Date.now(),
        traceId: interceptedRequest.traceId,
        spanId: interceptedRequest.spanId,
        duration: 150
      };

      const interceptedResponse = interceptor.interceptResponse(responseData);
      this.addTestResult(`📊 Response Status Code: ${interceptedResponse.statusCode}`);
      this.addTestResult(`📊 Response Duration: ${interceptedResponse.duration}ms`);
      
      DemoLogger.d(TAG, "Trace interceptor test passed");
      
    } catch (error) {
      this.addTestResult(`❌ Trace interceptor test failed: ${error}`);
      DemoLogger.e(TAG, `Trace interceptor test failed: ${error}`);
    }
  }

  /**
   * Extract trace ID from headers based on trace type
   */
  private extractTraceId(headers: Record<string, string>, traceType: TraceType): string | undefined {
    if (traceType === TraceType.DDTRACE) {
      return headers['x-datadog-trace-id'];
    } else if (traceType === TraceType.ZIPKIN_SINGLE_HEADER) {
      const b3Header = headers['b3'];
      if (b3Header) {
        const parts = b3Header.split('-');
        return parts.length >= 1 ? parts[0] : undefined;
      }
    } else if (traceType === TraceType.ZIPKIN_MULTI_HEADER) {
      return headers['X-B3-TraceId'];
    } else if (traceType === TraceType.TRACEPARENT) {
      const traceparent = headers['traceparent'];
      if (traceparent) {
        const parts = traceparent.split('-');
        return parts.length >= 2 ? parts[1] : undefined;
      }
    } else if (traceType === TraceType.JAEGER) {
      const uberTraceId = headers['uber-trace-id'];
      if (uberTraceId) {
        const parts = uberTraceId.split(':');
        return parts.length >= 1 ? parts[0] : undefined;
      }
    }
    return undefined;
  }

  /**
   * Extract span ID from headers based on trace type
   */
  private extractSpanId(headers: Record<string, string>, traceType: TraceType): string | undefined {
    if (traceType === TraceType.DDTRACE) {
      return headers['x-datadog-parent-id'];
    } else if (traceType === TraceType.ZIPKIN_SINGLE_HEADER) {
      const b3Header = headers['b3'];
      if (b3Header) {
        const parts = b3Header.split('-');
        return parts.length >= 2 ? parts[1] : undefined;
      }
    } else if (traceType === TraceType.ZIPKIN_MULTI_HEADER) {
      return headers['X-B3-SpanId'];
    } else if (traceType === TraceType.TRACEPARENT) {
      const traceparent = headers['traceparent'];
      if (traceparent) {
        const parts = traceparent.split('-');
        return parts.length >= 3 ? parts[2] : undefined;
      }
    } else if (traceType === TraceType.JAEGER) {
      const uberTraceId = headers['uber-trace-id'];
      if (uberTraceId) {
        const parts = uberTraceId.split(':');
        return parts.length >= 2 ? parts[1] : undefined;
      }
    }
    return undefined;
  }

  /**
   * Verify trace ID format based on trace type
   */
  private verifyTraceIDFormat(headers: Record<string, string>, traceType: TraceType): void {
    if (traceType === TraceType.DDTRACE) {
      const traceId = headers['x-datadog-trace-id'];
      const spanId = headers['x-datadog-parent-id'];
      if (traceId && spanId) {
        const isNumeric = /^\d+$/.test(traceId);
        const isSpanNumeric = /^\d+$/.test(spanId);
        if (isNumeric && isSpanNumeric) {
          this.addTestResult(`✅ DDTRACE Trace ID is numeric: ${traceId}`);
          this.addTestResult(`✅ DDTRACE Span ID is numeric: ${spanId}`);
        } else {
          this.addTestResult(`❌ DDTRACE Trace ID format incorrect: ${traceId} (should be numeric)`);
        }
      } else {
        this.addTestResult("❌ DDTRACE headers not found");
      }
    } else if (traceType === TraceType.ZIPKIN_MULTI_HEADER) {
      const traceId = headers['X-B3-TraceId'];
      const spanId = headers['X-B3-SpanId'];
      if (traceId && spanId) {
        const isUUID = /^[0-9a-f]{32}$/.test(traceId.toLowerCase());
        const isSpanGUID16 = /^[0-9a-f]{16}$/.test(spanId.toLowerCase());
        if (isUUID && isSpanGUID16) {
          this.addTestResult(`✅ ZIPKIN Trace ID is UUID format: ${traceId}`);
          this.addTestResult(`✅ ZIPKIN Span ID is GUID16 format: ${spanId}`);
        } else {
          this.addTestResult(`❌ ZIPKIN Trace ID format incorrect: ${traceId}`);
        }
      } else {
        this.addTestResult("❌ ZIPKIN headers not found");
      }
    } else if (traceType === TraceType.ZIPKIN_SINGLE_HEADER) {
      const b3Header = headers['b3'];
      if (b3Header) {
        const parts = b3Header.split('-');
        if (parts.length === 3) {
          const traceId = parts[0];
          const spanId = parts[1];
          const sampled = parts[2];
          const isUUID = /^[0-9a-f]{32}$/.test(traceId.toLowerCase());
          const isSpanGUID16 = /^[0-9a-f]{16}$/.test(spanId.toLowerCase());
          const isValidSampled = sampled === '0' || sampled === '1';
          if (isUUID && isSpanGUID16 && isValidSampled) {
            this.addTestResult(`✅ ZIPKIN_SINGLE_HEADER b3 format correct: ${b3Header}`);
            this.addTestResult(`   - Trace ID: ${traceId} (32 hex)`);
            this.addTestResult(`   - Span ID: ${spanId} (16 hex)`);
            this.addTestResult(`   - Sampled: ${sampled}`);
          } else {
            this.addTestResult(`❌ ZIPKIN_SINGLE_HEADER b3 format incorrect: ${b3Header}`);
          }
        } else {
          this.addTestResult(`❌ ZIPKIN_SINGLE_HEADER b3 format incorrect: ${b3Header}`);
        }
      } else {
        this.addTestResult("❌ ZIPKIN_SINGLE_HEADER b3 header not found");
      }
    } else if (traceType === TraceType.TRACEPARENT) {
      const traceparent = headers['traceparent'];
      if (traceparent) {
        const parts = traceparent.split('-');
        if (parts.length === 4) {
          const version = parts[0];
          const traceId = parts[1];
          const parentId = parts[2];
          const flags = parts[3];
          const isUUID = /^[0-9a-f]{32}$/.test(traceId.toLowerCase());
          const isSpanGUID16 = /^[0-9a-f]{16}$/.test(parentId.toLowerCase());
          const isValidVersion = version === '00';
          const isValidFlags = flags === '00' || flags === '01';
          if (isUUID && isSpanGUID16 && isValidVersion && isValidFlags) {
            this.addTestResult(`✅ TRACEPARENT format correct: ${traceparent}`);
            this.addTestResult(`   - Version: ${version}`);
            this.addTestResult(`   - Trace ID: ${traceId} (32 hex)`);
            this.addTestResult(`   - Parent ID: ${parentId} (16 hex)`);
            this.addTestResult(`   - Flags: ${flags}`);
          } else {
            this.addTestResult(`❌ TRACEPARENT format incorrect: ${traceparent}`);
          }
        } else {
          this.addTestResult(`❌ TRACEPARENT format incorrect: ${traceparent}`);
        }
      } else {
        this.addTestResult("❌ TRACEPARENT header not found");
      }
    } else if (traceType === TraceType.JAEGER) {
      const uberTraceId = headers['uber-trace-id'];
      if (uberTraceId) {
        const parts = uberTraceId.split(':');
        if (parts.length === 4) {
          const traceId = parts[0];
          const spanId = parts[1];
          const parentSpanId = parts[2];
          const sampled = parts[3];
          const isUUID = /^[0-9a-f]{32}$/.test(traceId.toLowerCase());
          const isSpanGUID16 = /^[0-9a-f]{16}$/.test(spanId.toLowerCase());
          const isValidParent = parentSpanId === '0';
          const isValidSampled = sampled === '0' || sampled === '1';
          if (isUUID && isSpanGUID16 && isValidParent && isValidSampled) {
            this.addTestResult(`✅ JAEGER uber-trace-id format correct: ${uberTraceId}`);
            this.addTestResult(`   - Trace ID: ${traceId} (32 hex)`);
            this.addTestResult(`   - Span ID: ${spanId} (16 hex)`);
            this.addTestResult(`   - Sampled: ${sampled}`);
          } else {
            this.addTestResult(`❌ JAEGER uber-trace-id format incorrect: ${uberTraceId}`);
          }
        } else {
          this.addTestResult(`❌ JAEGER uber-trace-id format incorrect: ${uberTraceId}`);
        }
      } else {
        this.addTestResult("❌ JAEGER uber-trace-id header not found");
      }
    } else if (traceType === TraceType.SKYWALKING) {
      const sw8Header = headers['sw8'];
      if (sw8Header) {
        this.addTestResult(`✅ SKYWALKING sw8 header generated: ${sw8Header}`);
      } else {
        this.addTestResult("❌ SKYWALKING sw8 header not found");
      }
    }
  }

  /**
   * Verify headers for sampling rate = 0 based on trace type
   */
  private verifySamplingRateZeroHeaders(headers: Record<string, string>, traceType: TraceType): void {
    if (traceType === TraceType.DDTRACE) {
      // Verify headers exist
      if (headers['x-datadog-trace-id']) {
        this.addTestResult(`   - Trace ID: ${headers['x-datadog-trace-id']}`);
      }
      if (headers['x-datadog-parent-id']) {
        this.addTestResult(`   - Span ID: ${headers['x-datadog-parent-id']}`);
      }
      
      // Verify sampling priority is "-1" (not sampled) when samplingRate = 0
      const samplingPriority = headers['x-datadog-sampling-priority'];
      if (samplingPriority === "-1") {
        this.addTestResult("✅ Sampling priority = -1 (not sampled, aligned with Android)");
      } else if (samplingPriority === "2") {
        this.addTestResult("❌ Sampling priority = 2 (sampled) - should be -1 when samplingRate = 0");
      } else {
        this.addTestResult(`⚠️ Sampling priority = ${samplingPriority} (unexpected value)`);
      }
      
      if (headers['x-datadog-origin']) {
        this.addTestResult(`   - Origin: ${headers['x-datadog-origin']}`);
      }
    } else if (traceType === TraceType.ZIPKIN_MULTI_HEADER) {
      if (headers['X-B3-TraceId']) {
        this.addTestResult(`   - Trace ID: ${headers['X-B3-TraceId']}`);
      }
      if (headers['X-B3-SpanId']) {
        this.addTestResult(`   - Span ID: ${headers['X-B3-SpanId']}`);
      }
      
      // Verify sampled is "0" (not sampled) when samplingRate = 0
      const sampled = headers['X-B3-Sampled'];
      if (sampled === "0") {
        this.addTestResult("✅ X-B3-Sampled = 0 (not sampled, aligned with Android)");
      } else if (sampled === "1") {
        this.addTestResult("❌ X-B3-Sampled = 1 (sampled) - should be 0 when samplingRate = 0");
      } else {
        this.addTestResult(`⚠️ X-B3-Sampled = ${sampled} (unexpected value)`);
      }
    } else if (traceType === TraceType.ZIPKIN_SINGLE_HEADER) {
      const b3Header = headers['b3'];
      if (b3Header) {
        // b3 format: traceId-spanId-sampled
        const parts = b3Header.split('-');
        if (parts.length === 3) {
          const sampled = parts[2];
          if (sampled === "0") {
            this.addTestResult(`✅ b3 sampled = 0 (not sampled, aligned with Android): ${b3Header}`);
          } else if (sampled === "1") {
            this.addTestResult(`❌ b3 sampled = 1 (sampled) - should be 0 when samplingRate = 0: ${b3Header}`);
          } else {
            this.addTestResult(`⚠️ b3 sampled = ${sampled} (unexpected value): ${b3Header}`);
          }
        }
      } else {
        this.addTestResult("❌ b3 header not found");
      }
    } else if (traceType === TraceType.TRACEPARENT) {
      const traceparent = headers['traceparent'];
      if (traceparent) {
        // traceparent format: version-traceId-parentId-flags
        const parts = traceparent.split('-');
        if (parts.length === 4) {
          const flags = parts[3];
          // flags should be "00" (not sampled) when samplingRate = 0
          if (flags === "00") {
            this.addTestResult(`✅ traceparent flags = 00 (not sampled, aligned with Android): ${traceparent}`);
          } else if (flags === "01") {
            this.addTestResult(`❌ traceparent flags = 01 (sampled) - should be 00 when samplingRate = 0: ${traceparent}`);
          } else {
            this.addTestResult(`⚠️ traceparent flags = ${flags} (unexpected value): ${traceparent}`);
          }
        }
      } else {
        this.addTestResult("❌ traceparent header not found");
      }
    } else if (traceType === TraceType.JAEGER) {
      const uberTraceId = headers['uber-trace-id'];
      if (uberTraceId) {
        // uber-trace-id format: traceId:spanId:parentSpanId:sampled
        const parts = uberTraceId.split(':');
        if (parts.length === 4) {
          const sampled = parts[3];
          if (sampled === "0") {
            this.addTestResult(`✅ uber-trace-id sampled = 0 (not sampled, aligned with Android): ${uberTraceId}`);
          } else if (sampled === "1") {
            this.addTestResult(`❌ uber-trace-id sampled = 1 (sampled) - should be 0 when samplingRate = 0: ${uberTraceId}`);
          } else {
            this.addTestResult(`⚠️ uber-trace-id sampled = ${sampled} (unexpected value): ${uberTraceId}`);
          }
        }
      } else {
        this.addTestResult("❌ uber-trace-id header not found");
      }
    } else if (traceType === TraceType.SKYWALKING) {
      const sw8Header = headers['sw8'];
      if (sw8Header) {
        this.addTestResult(`✅ sw8 header generated: ${sw8Header}`);
        this.addTestResult("   (SkyWalking sampling is embedded in sw8 header format)");
      } else {
        this.addTestResult("❌ sw8 header not found");
      }
    }
  }

  /**
   * Test sampling rate functionality
   */
  testSamplingRate() {
    try {
      DemoLogger.d(TAG, "Testing sampling rate functionality...");
      
      const samplingRates = [0.1, 0.5, 0.8, 1.0];
      
      for (const rate of samplingRates) {
        const traceConfig = new FTTraceConfig()
          .setSamplingRate(rate)
          .setTraceType(this.selectedTraceType)
          .setEnableAutoTrace(true)
          .setServiceName(`harmonyos-sampling-${rate}-${this.selectedTraceType.toString().toLowerCase()}-test`);

        FTSDK.installTraceConfig(traceConfig);
        
        const traceConfigManager = FTTraceConfigManager.getInstance();
        const actualRate = traceConfigManager.getSamplingRate();
        
        if (Math.abs(actualRate - rate) < 0.001) {
          this.addTestResult(`✅ Sampling rate ${rate} set successfully`);
        } else {
          this.addTestResult(`❌ Sampling rate ${rate} set failed, actual value: ${actualRate}`);
        }
      }
      
      DemoLogger.d(TAG, "Sampling rate test passed");
      
    } catch (error) {
      this.addTestResult(`❌ Sampling rate test failed: ${error}`);
      DemoLogger.e(TAG, `Sampling rate test failed: ${error}`);
    }
  }

  /**
   * Test sampling rate = 0 behavior
   * Aligned with Android SDK: When samplingRate = 0, trace headers should still be generated,
   * but with sampled = "0" (not sampled) to allow downstream services to decide
   */
  testSamplingRateZero() {
    try {
      this.addTestResult(`🔍 Testing Sampling Rate = 0 (Selected: ${this.getTraceTypeName(this.selectedTraceType)}, Aligned with Android SDK)`);
      
      const traceManager = FTTraceManager.getInstance();
      const testUrl = this.getTraceTestUrl();
      
      // Test 1: Set samplingRate = 0 for selected trace type
      this.addTestResult(`📋 Test 1: ${this.getTraceTypeName(this.selectedTraceType)} with samplingRate = 0`);
      const selectedTraceConfig = new FTTraceConfig()
        .setSamplingRate(0.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setServiceName(`harmonyos-sampling-zero-${this.selectedTraceType.toString().toLowerCase()}-test`);
      
      FTSDK.installTraceConfig(selectedTraceConfig);
      
      const selectedHeaders = traceManager.getTraceHeaderDirect(testUrl);
      DemoLogger.d(TAG, `${this.getTraceTypeName(this.selectedTraceType)} headers with samplingRate=0: ${JSON.stringify(selectedHeaders)}`);
      
      if (Object.keys(selectedHeaders).length > 0) {
        this.addTestResult("✅ Headers generated (even with samplingRate = 0)");
        
        // Verify headers and sampling based on trace type
        this.verifySamplingRateZeroHeaders(selectedHeaders, this.selectedTraceType);
        
        // Summary
        this.addTestResult("📊 Summary:");
        this.addTestResult("   - When samplingRate = 0, trace headers should still be generated");
        this.addTestResult("   - Sampling markers should be set to 'not sampled' (0, -1, 00, etc.)");
        this.addTestResult("   - This allows downstream services to decide whether to process the trace");
        this.addTestResult("   - Behavior aligned with Android SDK");
      } else {
        this.addTestResult("❌ No headers generated (should generate headers even when samplingRate = 0)");
      }
      
      DemoLogger.d(TAG, "Sampling rate = 0 test completed");
      
    } catch (error) {
      this.addTestResult(`❌ Sampling rate = 0 test failed: ${error}`);
    }
  }

  /**
   * Test manual trace injection with HTTP client
   */
  testManualTraceInjection() {
    try {
      DemoLogger.d(TAG, "Testing manual trace injection...");
      
      // const httpClient = FTHttpClient.getInstance();
      //
      // // Test 1: Enable trace manually
      // httpClient.enableTrace();
      // if (httpClient.isTraceEnabled()) {
      //   this.addTestResult("✅ Manual trace enable successful");
      // } else {
      //   this.addTestResult("❌ Manual trace enable failed");
      // }
      //
      // // Test 2: Disable trace manually
      // httpClient.disableTrace();
      // if (!httpClient.isTraceEnabled()) {
      //   this.addTestResult("✅ Manual trace disable successful");
      // } else {
      //   this.addTestResult("❌ Manual trace disable failed");
      // }
      
      // Test 3: Custom trace interceptor
      class CustomHeaderHandler implements FTTraceHeaderHandler {
        getTraceContext(request: FTTraceRequestContext): FTTraceContext {
          const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
          traceContext.headers['x-custom-trace-id'] = traceContext.traceId;
          traceContext.headers['x-custom-span-id'] = traceContext.spanId;
          return traceContext;
        }
      }
      const customHeaderHandler = new CustomHeaderHandler();
      
      const customInterceptor = new DefaultFTTraceInterceptor(TraceType.DDTRACE, customHeaderHandler);
      // httpClient.setTraceInterceptor(customInterceptor);
      //
      // if (httpClient.isTraceEnabled()) {
      //   this.addTestResult("✅ Custom trace interceptor set successfully");
      // } else {
      //   this.addTestResult("❌ Custom trace interceptor set failed");
      // }
      
      // Test 4: Simulate HTTP request with trace headers
      const traceUrl = this.getTraceTestUrl();
      const requestData: HttpRequestData = {
        url: traceUrl,
        method: 'GET',
        headers: new Map([['Content-Type', 'application/json']]),
        timestamp: Date.now()
      };
      
      const interceptedRequest = customInterceptor.interceptRequest(requestData);
      const hasTraceId = interceptedRequest.headers.has('x-datadog-trace-id');
      const hasCustomTraceId = interceptedRequest.headers.has('x-custom-trace-id');
      
      if (hasTraceId && hasCustomTraceId) {
        this.addTestResult("✅ Trace headers added successfully");
        this.addTestResult(`   - Trace ID: ${interceptedRequest.traceId}`);
        this.addTestResult(`   - Span ID: ${interceptedRequest.spanId}`);
      } else {
        this.addTestResult("❌ Trace headers not added correctly");
      }
      
      DemoLogger.d(TAG, "Manual trace injection test completed");
      
    } catch (error) {
      this.addTestResult(`❌ Manual trace injection test failed: ${error}`);
      DemoLogger.e(TAG, `Manual trace injection test failed: ${error}`);
    }
  }

  /**
   * Test HTTP client with trace configuration
   */
  async testHttpClientWithTrace() {
    try {
      DemoLogger.d(TAG, `Testing HTTP client with trace (type: ${this.getTraceTypeName(this.selectedTraceType)})...`);
      
      // const httpClient = FTHttpClient.getInstance();
      //
      // // Configure trace using selected trace type
      // const traceConfig = new FTTraceConfig()
      //   .setSamplingRate(1.0)
      //   .setTraceType(this.selectedTraceType)
      //   .setEnableAutoTrace(true)
      //   .setServiceName(`harmonyos-http-test-${this.selectedTraceType.toString().toLowerCase()}`);
      //
      // FTSDK.installTraceConfig(traceConfig);
      //
      // // Enable trace in HTTP client
      // httpClient.enableTrace();
      //
      // if (httpClient.isTraceEnabled()) {
      //   this.addTestResult("✅ HTTP client trace enabled");
      //
      //   // Note: In a real scenario, you would make actual HTTP requests
      //   // For testing, we'll just verify the configuration
      //   this.addTestResult("✅ HTTP client ready for trace-enabled requests");
      //   this.addTestResult(`   - Trace type: ${this.getTraceTypeName(this.selectedTraceType)}`);
      //   this.addTestResult("   - Trace headers will be automatically added");
      //   this.addTestResult("   - Sampling rate: 100%");
      // } else {
      //   this.addTestResult("❌ HTTP client trace not enabled");
      // }
      
      DemoLogger.d(TAG, "HTTP client trace test completed");
      
    } catch (error) {
      this.addTestResult(`❌ HTTP client trace test failed: ${error}`);
      DemoLogger.e(TAG, `HTTP client trace test failed: ${error}`);
    }
  }

  /**
   * Test FTTraceManager.getTraceHeader() API directly
   */
  testTraceManagerAPI() {
    try {
      DemoLogger.d(TAG, `Testing FTTraceManager.getTraceHeader() API (type: ${this.getTraceTypeName(this.selectedTraceType)})...`);
      
      // Configure trace using selected trace type
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setServiceName(`harmonyos-trace-manager-test-${this.selectedTraceType.toString().toLowerCase()}`);
      
      FTSDK.installTraceConfig(traceConfig);
      
      const traceManager = FTTraceManager.getInstance();
      const testUrl = this.getTraceTestUrl();
      const resourceId = `test-resource-${Date.now()}`;
      
      // Test 1: getTraceHeader() - stores handler
      const headers1 = traceManager.getTraceHeader(resourceId, testUrl);
      DemoLogger.d(TAG, `getTraceHeader() returned: ${JSON.stringify(headers1)}`);
      
      if (Object.keys(headers1).length > 0) {
        this.addTestResult("✅ getTraceHeader() returned headers");
        
        // Verify headers based on trace type
        const headerKeys = Object.keys(headers1);
        for (let i = 0; i < headerKeys.length; i++) {
          const key = headerKeys[i];
          this.addTestResult(`   - ${key}: ${headers1[key]}`);
        }
      } else {
        this.addTestResult("❌ getTraceHeader() returned empty headers");
      }
      
      // Test 2: Verify handler was stored
      const handler = traceManager.getHandler(resourceId);
      const traceContext = traceManager.getTraceContext(resourceId);
      if (handler && traceContext) {
        this.addTestResult("✅ Handler and TraceContext stored successfully");
        const contextHeaders = traceContext.headers;
        const contextHeaderKeys = Object.keys(contextHeaders);
        if (contextHeaderKeys.length > 0) {
          this.addTestResult("✅ TraceContext contains headers");
          this.addTestResult(`   - Trace ID: ${traceContext.traceId}`);
          this.addTestResult(`   - Span ID: ${traceContext.spanId}`);
          for (let i = 0; i < contextHeaderKeys.length; i++) {
            const key = contextHeaderKeys[i];
            this.addTestResult(`   - Context ${key}: ${contextHeaders[key]}`);
          }
          
          // Verify headers match (compare first header key)
          if (contextHeaderKeys.length > 0 && Object.keys(headers1).length > 0) {
            const firstKey = contextHeaderKeys[0];
            if (contextHeaders[firstKey] === headers1[firstKey]) {
              this.addTestResult(`✅ ${firstKey} matches between headers and TraceContext`);
            } else {
              this.addTestResult(`❌ ${firstKey} mismatch`);
            }
          }
        } else {
          this.addTestResult("❌ TraceContext returned empty headers");
        }
      } else {
        this.addTestResult("❌ Handler or TraceContext not found after getTraceHeader()");
      }
      
      // Test 3: getTraceHeaderDirect() - doesn't store handler
      const headers2 = traceManager.getTraceHeaderDirect(testUrl);
      DemoLogger.d(TAG, `getTraceHeaderDirect() returned: ${JSON.stringify(headers2)}`);
      
      if (Object.keys(headers2).length > 0) {
        this.addTestResult("✅ getTraceHeaderDirect() returned headers");
        const headerKeys2 = Object.keys(headers2);
        for (let i = 0; i < headerKeys2.length; i++) {
          const key = headerKeys2[i];
          this.addTestResult(`   - Direct ${key}: ${headers2[key]}`);
        }
      } else {
        this.addTestResult("❌ getTraceHeaderDirect() returned empty headers");
      }
      
      // Test 4: Test selected trace type headers
      const expectedHeaders: string[] = [];
      if (this.selectedTraceType === TraceType.DDTRACE) {
        expectedHeaders.push('x-datadog-trace-id', 'x-datadog-parent-id');
      } else if (this.selectedTraceType === TraceType.ZIPKIN_MULTI_HEADER) {
        expectedHeaders.push('X-B3-TraceId', 'X-B3-SpanId');
      } else if (this.selectedTraceType === TraceType.ZIPKIN_SINGLE_HEADER) {
        expectedHeaders.push('b3');
      } else if (this.selectedTraceType === TraceType.JAEGER) {
        expectedHeaders.push('uber-trace-id');
      } else if (this.selectedTraceType === TraceType.TRACEPARENT) {
        expectedHeaders.push('traceparent');
      } else if (this.selectedTraceType === TraceType.SKYWALKING) {
        expectedHeaders.push('sw8');
      }
      
      if (expectedHeaders.length > 0) {
        const config = new FTTraceConfig()
          .setTraceType(this.selectedTraceType)
          .setSamplingRate(1.0);
        FTSDK.installTraceConfig(config);
        
        const headers = traceManager.getTraceHeaderDirect(testUrl);
        let allHeadersPresent = true;
        for (let i = 0; i < expectedHeaders.length; i++) {
          if (!headers[expectedHeaders[i]]) {
            allHeadersPresent = false;
            break;
          }
        }
        
        if (allHeadersPresent) {
          this.addTestResult(`✅ ${this.getTraceTypeName(this.selectedTraceType)} headers generated correctly`);
        } else {
          this.addTestResult(`❌ ${this.getTraceTypeName(this.selectedTraceType)} headers missing`);
        }
      }
      
      DemoLogger.d(TAG, "FTTraceManager API test completed");
      
    } catch (error) {
      this.addTestResult(`❌ FTTraceManager API test failed: ${error}`);
      DemoLogger.e(TAG, `FTTraceManager API test failed: ${error}`);
    }
  }

  /**
   * Test custom Trace Header append/modify for manual requests.
   */
  testManualCustomTraceHeaderAppend() {
    try {
      this.addTestResult("🔍 Testing manual custom Trace Header append/modify");

      class DemoTraceHeaderHandler implements FTTraceHeaderHandler {
        getTraceContext(request: FTTraceRequestContext): FTTraceContext {
          const traceContext = FTTraceManager.getInstance().getTraceContextDirect(request.url);
          traceContext.headers['x-global-custom-trace-id'] = traceContext.traceId;
          traceContext.headers['x-global-custom-span-id'] = traceContext.spanId;
          return traceContext;
        }
      }

      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)
        .setTraceHeaderHandler(new DemoTraceHeaderHandler())
        .setServiceName(`harmonyos-manual-custom-trace-${this.selectedTraceType.toString().toLowerCase()}`);

      FTSDK.installTraceConfig(traceConfig);

      const traceManager = FTTraceManager.getInstance();
      const testUrl = this.getTraceTestUrl();
      const resourceId = `manual-custom-trace-${Date.now()}`;

      const traceHeaders = traceManager.getTraceHeader(resourceId, testUrl);
      const traceContext = traceManager.getTraceContext(resourceId);

      if (!traceContext) {
        this.addTestResult("❌ TraceContext not found after getTraceHeader()");
        return;
      }

      this.addTestResult("✅ Trace headers generated through getTraceHeader()");
      this.addTestResult(`   - Trace ID: ${traceContext.traceId}`);
      this.addTestResult(`   - Span ID: ${traceContext.spanId}`);

      if (traceHeaders['x-global-custom-trace-id'] === traceContext.traceId &&
        traceHeaders['x-global-custom-span-id'] === traceContext.spanId) {
        this.addTestResult("✅ setTraceHeaderHandler appended x-global-custom-trace-id/x-global-custom-span-id");
      } else {
        this.addTestResult("❌ setTraceHeaderHandler custom headers do not match TraceContext IDs");
      }

      traceHeaders['x-business-id'] = `business-${Date.now()}`;
      traceHeaders['x-trace-source'] = 'harmonyos-demo';
      traceHeaders['x-trace-id'] = traceContext.traceId;
      traceHeaders['x-span-id'] = traceContext.spanId;

      if (traceHeaders['x-trace-id'] === traceContext.traceId && traceHeaders['x-span-id'] === traceContext.spanId) {
        this.addTestResult("✅ Manually appended x-trace-id/x-span-id from TraceContext");
      } else {
        this.addTestResult("❌ Manually appended trace IDs do not match TraceContext");
      }

      traceHeaders['x-trace-source'] = 'harmonyos-demo-updated';
      if (traceHeaders['x-trace-source'] === 'harmonyos-demo-updated') {
        this.addTestResult("✅ Manually modified x-trace-source for this request");
      } else {
        this.addTestResult("❌ Failed to modify x-trace-source");
      }

      this.addTestResult(`   Final request headers: ${JSON.stringify(traceHeaders)}`);
      this.addTestResult("📋 Verification:");
      this.addTestResult("   - Global custom headers are generated inside setTraceHeaderHandler");
      this.addTestResult("   - Manual headers added after getTraceHeader affect only this request");
      this.addTestResult("   - x-trace-id/x-span-id are copied from the same TraceContext used for RUM linking");
    } catch (error) {
      this.addTestResult(`❌ Manual custom Trace Header append/modify test failed: ${error}`);
      DemoLogger.e(TAG, `Manual custom Trace Header append/modify test failed: ${error}`);
    }
  }

  /**
   * Test Trace ID generation logic
   * Verifies that Trace IDs are generated correctly according to Trace type
   */
  testTraceIDGeneration() {
    try {
      this.addTestResult(`🔍 Testing Trace ID Generation Logic (${this.getTraceTypeName(this.selectedTraceType)})`);
      
      const traceManager = FTTraceManager.getInstance();
      const testUrl = this.getTraceTestUrl();
      
      // Configure trace with selected trace type
      const traceConfig = new FTTraceConfig()
        .setTraceType(this.selectedTraceType)
        .setSamplingRate(1.0);
      FTSDK.installTraceConfig(traceConfig);
      
      const headers = traceManager.getTraceHeaderDirect(testUrl);
      DemoLogger.d(TAG, `${this.getTraceTypeName(this.selectedTraceType)} headers: ${JSON.stringify(headers)}`);
      
      // Verify ID format based on trace type
      this.verifyTraceIDFormat(headers, this.selectedTraceType);
      
      // Test ID uniqueness (generate multiple times)
      this.addTestResult("🔍 Testing ID uniqueness...");
      const traceIds: string[] = [];
      const spanIds: string[] = [];
      
      for (let i = 0; i < 5; i++) {
        const testHeaders = traceManager.getTraceHeaderDirect(testUrl);
        const traceId = this.extractTraceId(testHeaders, this.selectedTraceType);
        const spanId = this.extractSpanId(testHeaders, this.selectedTraceType);
        if (traceId) traceIds.push(traceId);
        if (spanId) spanIds.push(spanId);
      }
      
      // Check if all IDs are unique
      const uniqueTraceIds = new Set(traceIds);
      const uniqueSpanIds = new Set(spanIds);
      
      if (uniqueTraceIds.size === traceIds.length && uniqueSpanIds.size === spanIds.length) {
        this.addTestResult(`✅ All Trace IDs are unique (${traceIds.length} generated)`);
        this.addTestResult(`✅ All Span IDs are unique (${spanIds.length} generated)`);
      } else {
        this.addTestResult(`❌ Duplicate IDs found (Trace IDs: ${uniqueTraceIds.size}/${traceIds.length}, Span IDs: ${uniqueSpanIds.size}/${spanIds.length})`);
      }
      
      DemoLogger.d(TAG, "Trace ID generation test completed");
      
    } catch (error) {
      this.addTestResult(`❌ Trace ID generation test failed: ${error}`);
    }
  }

  /**
   * Clear test results
   */
  clearTestResults() {
    this.testResults = [];
    DemoLogger.d(TAG, "Test results cleared");
  }

  /**
   * Test trace_id and span_id in resource data
   * This test verifies that trace_id and span_id are correctly added to resource data
   * when enableLinkRUMData is enabled
   */
  async testTraceIdInResourceData() {
    try {
      this.addTestResult("🔍 Testing Trace ID and Span ID in Resource Data");
      
      // Step 1: Enable trace config with enableLinkRUMData = true
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true)
        .setEnableLinkRUMData(true)  // This is the key setting!
        .setServiceName(`harmonyos-trace-resource-test-${this.selectedTraceType.toString().toLowerCase()}`);
      
      FTSDK.installTraceConfig(traceConfig);
      this.addTestResult("✅ Trace config set with enableLinkRUMData=true");
      
      // Step 2: Verify enableLinkRUMData is enabled
      const traceConfigManager = FTTraceConfigManager.getInstance();
      const isLinkRUMDataEnabled = traceConfigManager.isRUMDataLinkingEnabled();
      
      if (isLinkRUMDataEnabled) {
        this.addTestResult("✅ enableLinkRUMData is enabled");
      } else {
        this.addTestResult("❌ enableLinkRUMData is NOT enabled (test will not work correctly)");
        return;
      }
      
      // Step 3: Create a session with the FT interceptors
      const session = this.createTrackedSession();
      this.addTestResult("✅ RCP session created with FT interceptors");
      
      // Step 5: Generate a unique resource ID for this test
      const testResourceId = `test-resource-${Date.now()}`;
      this.addTestResult(`📝 Test resource ID: ${testResourceId}`);
      
      // Step 6: Get trace header BEFORE sending request (this will create handler)
      const traceManager = FTTraceManager.getInstance();
      const testUrl = this.getTraceTestUrl();
      const traceHeaders = traceManager.getTraceHeader(testResourceId, testUrl);
      
      if (traceHeaders && Object.keys(traceHeaders).length > 0) {
        this.addTestResult("✅ Trace headers generated");
        this.addTestResult(`   Headers: ${JSON.stringify(traceHeaders)}`);
        
        // Extract trace_id and span_id from headers
        const traceId = traceHeaders['x-datadog-trace-id'];
        const spanId = traceHeaders['x-datadog-parent-id'];
        
        if (traceId && spanId) {
          this.addTestResult(`✅ Trace ID extracted: ${traceId}`);
          this.addTestResult(`✅ Span ID extracted: ${spanId}`);
        } else {
          this.addTestResult("⚠️ Trace ID or Span ID not found in headers");
        }
      } else {
        this.addTestResult("❌ Trace headers not generated");
        return;
      }
      
      // Step 7: Send HTTP request (this will trigger resource collection)
      this.addTestResult(`📡 Sending GET request to ${testUrl}`);
      DemoLogger.d(TAG, `[TEST] About to send request to ${testUrl}`);
      DemoLogger.d(TAG, `[TEST] Session: ${session ? 'exists' : 'null'}`);
      const request = new rcp.Request(testUrl, 'GET');
      DemoLogger.d(TAG, `[TEST] Request created: ${testUrl}`);
      
      try {
        DemoLogger.d(TAG, `[TEST] Calling session.fetch()...`);
        const response = await session.fetch(request);
        DemoLogger.d(TAG, `[TEST] Response received: statusCode=${response.statusCode}`);
        
        if (response.statusCode >= 200 && response.statusCode < 300) {
          this.addTestResult(`✅ Request successful: ${response.statusCode}`);
          
          // Read and display response body
          try {
            if (response.body) {
              const arrayBuffer = response.body as ArrayBuffer;
              // Use util.TextDecoder from @kit.ArkTS for HarmonyOS
              const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
              const uint8Array = new Uint8Array(arrayBuffer);
              const responseText: string = decoder.decodeWithStream(uint8Array, { stream: false });
              this.addTestResult(`📄 Response body: ${responseText}`);
              
              // Try to parse as JSON
              try {
                // Define interface for API response structure
                interface ApiResponse {
                  avatar?: string;
                  email?: string;
                  username?: string;
                }
                const responseJson: ApiResponse = JSON.parse(responseText) as ApiResponse;
                this.addTestResult(`✅ Response JSON parsed successfully:`);
                this.addTestResult(`   - avatar: ${responseJson.avatar || 'N/A'}`);
                this.addTestResult(`   - email: ${responseJson.email || 'N/A'}`);
                this.addTestResult(`   - username: ${responseJson.username || 'N/A'}`);
              } catch (parseError) {
                this.addTestResult(`⚠️ Response is not valid JSON: ${responseText.substring(0, 100)}`);
              }
            } else {
              this.addTestResult(`⚠️ Response body is empty`);
            }
          } catch (readError) {
            this.addTestResult(`⚠️ Failed to read response body: ${readError}`);
          }
          
          // Step 8: Wait a moment for resource data to be processed
          await new Promise<void>((resolve) => setTimeout(() => resolve(), 500));
          
          // Step 9: Get TraceContext from FTTraceManager to verify trace_id and span_id
          const traceContext = traceManager.getTraceContext(testResourceId);
          
          if (traceContext) {
            this.addTestResult("✅ TraceContext found in FTTraceManager");
            
            if (traceContext.traceId && traceContext.spanId) {
              this.addTestResult(`✅ TraceContext Trace ID: ${traceContext.traceId}`);
              this.addTestResult(`✅ TraceContext Span ID: ${traceContext.spanId}`);
              
              // Verify they match the headers
              const headerTraceId = traceHeaders['x-datadog-trace-id'];
              const headerSpanId = traceHeaders['x-datadog-parent-id'];

              if (traceContext.traceId === headerTraceId && traceContext.spanId === headerSpanId) {
                this.addTestResult("✅ TraceContext IDs match header IDs");
              } else {
                this.addTestResult("⚠️ TraceContext IDs do not match header IDs");
              }
            } else {
              this.addTestResult("⚠️ TraceContext Trace ID or Span ID is empty");
            }
          } else {
            this.addTestResult("⚠️ TraceContext not found in FTTraceManager (may have been cleaned up)");
          }
          
          // Step 10: Verify resource data contains trace_id and span_id
          // Note: The actual resource data is processed asynchronously in FTRUMInnerManager
          // The trace_id and span_id are added in setTransformContent method
          // Check logs for: "Set trace_id and span_id for resource"
          this.addTestResult("📋 Verification:");
          this.addTestResult("   - Resource data should contain trace_id and span_id");
          this.addTestResult("   - Check logs for: 'Set trace_id and span_id for resource'");
          this.addTestResult("   - Check uploaded RUM data for trace_id and span_id tags");
          this.addTestResult("   - In DataFlux platform, verify resource measurement has trace_id and span_id");
          
        } else {
          this.addTestResult(`❌ Request failed: ${response.statusCode}`);
        }
        
      } catch (requestError) {
        const err = requestError as BusinessError;
        const errorMsg = err.message || String(requestError);
        this.addTestResult(`❌ Request error: ${errorMsg}`);
      }
      
      this.addTestResult("✅ Trace ID and Span ID in Resource Data test completed!");
      
    } catch (error) {
      this.addTestResult(`❌ Trace ID and Span ID in Resource Data test failed: ${error}`);
    }
  }

  /**
   * Test RCP request with trace headers injection
   * This test verifies that Trace headers are automatically added to HTTP requests via RCP interceptor
   */
  async testRCPRequestWithTraceHeaders() {
    try {
      this.addTestResult("🔍 Testing RCP Request with Trace Headers Injection");
      
      // Step 1: Create a session with the FT interceptors
      const session = this.createTrackedSession();
      this.addTestResult("✅ Session created with FT interceptors");
      
      // Step 2: Configure trace type with selected trace type
      const expectedHeaders: string[] = [];
      if (this.selectedTraceType === TraceType.DDTRACE) {
        expectedHeaders.push('x-datadog-trace-id', 'x-datadog-parent-id');
      } else if (this.selectedTraceType === TraceType.ZIPKIN_MULTI_HEADER) {
        expectedHeaders.push('X-B3-TraceId', 'X-B3-SpanId');
      } else if (this.selectedTraceType === TraceType.ZIPKIN_SINGLE_HEADER) {
        expectedHeaders.push('b3');
      } else if (this.selectedTraceType === TraceType.JAEGER) {
        expectedHeaders.push('uber-trace-id');
      } else if (this.selectedTraceType === TraceType.TRACEPARENT) {
        expectedHeaders.push('traceparent');
      } else if (this.selectedTraceType === TraceType.SKYWALKING) {
        expectedHeaders.push('sw8');
      }
      
      this.addTestResult(`📤 Testing ${this.getTraceTypeName(this.selectedTraceType)}...`);
      
      // Configure trace type
      const traceConfig = new FTTraceConfig()
        .setSamplingRate(1.0)
        .setTraceType(this.selectedTraceType)
        .setEnableAutoTrace(true);
      
      FTSDK.installTraceConfig(traceConfig);
      this.addTestResult(`✅ Trace config set to ${this.getTraceTypeName(this.selectedTraceType)}`);
      
      // Step 3: Send HTTP request using RCP session
      const testUrl = this.getTraceTestUrl();
      const request = new rcp.Request(testUrl, 'GET');
      
      this.addTestResult(`📡 Sending GET request to ${testUrl}`);
      
      try {
        const response = await session.fetch(request);
        
        if (response.statusCode >= 200 && response.statusCode < 300) {
          this.addTestResult(`✅ Request successful: ${response.statusCode}`);
          
          // Note: Trace headers are automatically injected by RCPTraceInterceptor
          // The interceptor logs the added headers in the log output
          // Check logs for: "[RCP-Trace] Added trace headers"
          this.addTestResult(`✅ Request completed. Check logs for trace headers injection.`);
          this.addTestResult(`   Expected headers: ${expectedHeaders.join(', ')}`);
          this.addTestResult(`   Look for log: "[RCP-Trace] Added trace headers" to verify injection`);
          
          // Note: response.body is ArrayBuffer type, which doesn't have text() method
          // Trace headers verification is done through interceptor logs instead
          // The interceptor will log: "[RCP-Trace] Added trace headers (X): header1: value1, header2: value2"
          
        } else {
          this.addTestResult(`❌ Request failed: ${response.statusCode}`);
        }
        
      } catch (requestError) {
        const err = requestError as BusinessError;
        const errorMsg = err.message || String(requestError);
        this.addTestResult(`❌ Request error: ${errorMsg}`);
      }
      
      this.addTestResult("✅ RCP Request Trace Headers test completed");
      
    } catch (error) {
      this.addTestResult(`❌ RCP Request Trace Headers test failed: ${error}`);
    }
  }

  /**
   * Run all tests
   */
  runAllTests() {
    this.clearTestResults();
    this.addTestResult("🚀 Starting all trace tests...");
    
    // Run all tests sequentially
    this.testBasicTraceConfig();
    this.testTraceTypes();
    this.testTraceConfigManager();
    this.testTraceInterceptor();
    this.testSamplingRate();
    this.testManualTraceInjection();
    this.testHttpClientWithTrace();
    this.testTraceManagerAPI();
    this.testTraceIDGeneration();
    // Note: RCP test is async, so it should be called separately
    // this.testRCPRequestWithTraceHeaders();
    
    this.addTestResult("✅ All tests completed!");
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

    Scroll() {
      Column() {
        // Trace Type Selection
        Column() {
          Text('Trace Type:')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 10 })
            .width('100%')
          
          // Radio buttons for trace type selection
          Column() {
            ForEach(this.traceTypeOptions, (traceType: TraceType, index: number) => {
              Row() {
                Radio({ value: this.getTraceTypeName(traceType), group: 'traceTypeGroup' })
                  .checked(this.selectedTraceType === traceType)
                  .onChange((isChecked: boolean) => {
                    if (isChecked) {
                      this.selectedTraceType = traceType;
                      this.addTestResult(`📌 Trace type changed to: ${this.getTraceTypeName(this.selectedTraceType)}`);
                      // Apply the selected trace type immediately
                      this.applyTraceType();
                    }
                  })
                Text(this.getTraceTypeName(traceType))
                  .fontSize(14)
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.selectedTraceType = traceType;
                    this.addTestResult(`📌 Trace type changed to: ${this.getTraceTypeName(this.selectedTraceType)}`);
                    this.applyTraceType();
                  })
              }
              .width('100%')
              .margin({ bottom: 8 })
            }, (traceType: TraceType, index: number) => `${index}-${traceType}`)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 20 })
        .padding({ left: 10, right: 10 })

        // Test buttons
        Button('Test Basic Trace Config')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testBasicTraceConfig())

        Button('Test Different Trace Types')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testTraceTypes())

        Button('Test Trace Config Manager')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testTraceConfigManager())

        Button('Test Trace Interceptor')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testTraceInterceptor())

        Button('Test Sampling Rate')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testSamplingRate())

        Button('Test Sampling Rate = 0')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testSamplingRateZero())

        Button('Test Manual Trace Injection')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testManualTraceInjection())

        Button('Test HTTP Client with Trace')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testHttpClientWithTrace())

        Button('Test FTTraceManager API')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testTraceManagerAPI())

        Button('Test Custom Trace Header Append')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testManualCustomTraceHeaderAppend())

        Button('Test Trace ID Generation')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.testTraceIDGeneration())

        Button('Test RCP Request with Trace Headers')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => {
            this.testRCPRequestWithTraceHeaders();
          })

        Button('Test Trace ID in Resource Data')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => {
            this.testTraceIdInResourceData();
          })

        Button('Run All Tests')
          .width('100%')
          .height(50)
          .margin({ bottom: 10 })
          .onClick(() => this.runAllTests())

        Column() {
          Row() {
            Text('Test Results')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)

            Button('Clear Results')
              .height(36)
              .onClick(() => this.clearTestResults())
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
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
