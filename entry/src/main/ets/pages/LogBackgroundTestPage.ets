import { Context } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { FTLogger, FTLoggerConfig, FTSDK, LogGlobalContextValue, Status } from '@guancecloud/ft_sdk/Index';
import FTTrackInner from '@guancecloud/ft_sdk/src/main/ets/components/FTTrackInner';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'LogBackgroundTestPage';

/**
 * LogBackground feature test page
 * Tests the various usages and capabilities of FTLogger.logBackground
 */
@Entry
@Component
export struct LogBackgroundTestPage {
  @State logCount: number = 0;
  @State testResults: string[] = [];
  @State isConfigInitialized: boolean = false;
  @State context: Context = getContext(this) as Context;

  aboutToAppear() {
    this.addTestResult("🚀 LogBackground Test Page initialized");
    this.initializeLoggerConfig();
  }

  /**
   * Initialize the logger configuration
   */
  private initializeLoggerConfig(): void {
    try {
      const logConfig = new FTLoggerConfig();
      logConfig.setEnableCustomLog(true);
      logConfig.setEnableConsoleLog(true);
      logConfig.setPrintCustomLogToConsole(true);
      logConfig.setSamplingRate(1.0);
      logConfig.setServiceName("harmonyos_log_test");
      logConfig.setLogLevelFilters([Status.INFO, Status.WARN, Status.ERROR, Status.DEBUG]);
      logConfig.setLogCacheLimitCount(1000);

      const staticContext = new Map<string, LogGlobalContextValue>();
      staticContext.set('demo_log_static_tag', 'static_dictionary_value');
      staticContext.set('demo_log_number_tag', 101);
      staticContext.set('demo_log_boolean_tag', true);
      staticContext.set('demo_log_zero_tag', 0);
      staticContext.set('demo_log_false_tag', false);
      logConfig.addGlobalContext(staticContext);
      logConfig.addGlobalContext('demo_log_legacy_tag', 'legacy_key_value');

      // Use FTSDK.installLogConfig for proper initialization
      FTSDK.installLogConfig(logConfig);
      this.isConfigInitialized = true;
      this.addTestResult("✅ Logger configuration initialized successfully");
    } catch (error) {
      this.addTestResult(`❌ Logger configuration failed: ${error}`);
    }
  }

  /**
   * Add a test result
   */
  addTestResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    const nextResults = [`[${timestamp}] ${message}`, ...this.testResults];
    this.testResults = nextResults.length > 40
      ? nextResults.slice(0, 40)
      : nextResults;
    DemoLogger.i(TAG, message);
  }


  /**
   * Test the basic logBackground functionality
   */
  testBasicLogBackground() {
    try {
      // Test string status
      FTLogger.logBackground("Basic test log with string status", "info");
      // Test the Status enum
      FTLogger.logBackground("Basic test log with Status enum", Status.INFO);
      // Test different levels
      FTLogger.logBackground("Debug level log", Status.DEBUG);
      FTLogger.logBackground("Warning level log", Status.WARN);
      FTLogger.logBackground("Error level log", Status.ERROR);
      this.logCount += 4;
      this.addTestResult("✅ Basic logBackground test completed: 4 logs sent");
    } catch (error) {
      this.addTestResult(`❌ Basic logBackground test failed: ${error}`);
    }
  }

  /**
   * Test logBackground with properties
   */
  testLogBackgroundWithProperties() {
    try {
      const properties = new Map<string, object>();
      properties.set("userId", new String("12345"));
      properties.set("sessionId", new String("session_abc123"));
      properties.set("action", new String("test_action"));
      properties.set("timestamp", new Number(Date.now()));
      properties.set("isTest", new Boolean(true));
      
      // Test string status with properties
      FTLogger.logBackground("Log with properties (string status)", "info", properties);
      // Test the Status enum with properties
      FTLogger.logBackground("Log with properties (Status enum)", Status.INFO, properties);
      this.logCount += 2;
      this.addTestResult("✅ Properties logBackground test completed: 2 logs sent");
    } catch (error) {
      this.addTestResult(`❌ Properties logBackground test failed: ${error}`);
    }
  }

  /**
   * Test silent mode
   */
  testSilentMode() {
    try {
      // Test silent mode
      FTLogger.logBackground("Silent log message", Status.INFO.name, undefined, true);
      // Test non-silent mode
      FTLogger.logBackground("Non-silent log message", Status.INFO.name, undefined, false);
      this.logCount += 2;
      this.addTestResult("✅ Silent mode test completed: 2 logs sent");
    } catch (error) {
      this.addTestResult(`❌ Silent mode test failed: ${error}`);
    }
  }

  /**
   * Test all overloads
   */
  testAllOverloads() {
    try {
      const properties = new Map<string, object>();
      properties.set("testType", new String("overload_test"));
      
      // Test all overloads
      FTLogger.logBackground("Overload test 1", "info");
      FTLogger.logBackground("Overload test 2", Status.INFO);
      FTLogger.logBackground("Overload test 3", "warn", properties);
      FTLogger.logBackground("Overload test 4", Status.WARN, properties);
      FTLogger.logBackground("Overload test 5", "error", properties, true);
      FTLogger.logBackground("Overload test 6", Status.ERROR, properties, true);
      FTLogger.logBackground("Overload test 7", "debug", properties, false);
      FTLogger.logBackground("Overload test 8", Status.DEBUG, properties, false);
      
      this.logCount += 8;
      this.addTestResult("✅ Overload test completed: 8 logs sent");
    } catch (error) {
      this.addTestResult(`❌ Overload test failed: ${error}`);
    }
  }

  /**
   * Test batch logging
   */
  testBatchLogging() {
    try {
      const batchSize = 10;
      for (let i = 0; i < batchSize; i++) {
        const properties = new Map<string, object>();
        properties.set("batchIndex", new Number(i));
        properties.set("batchSize", new Number(batchSize));
        properties.set("timestamp", new Number(Date.now()));
        
        FTLogger.logBackground(`Batch log message ${i + 1}`, Status.INFO, properties);
      }
      
      this.addTestResult(`✅ Batch logging completed: ${batchSize} logs sent`);
      this.logCount += batchSize;
    } catch (error) {
      this.addTestResult(`❌ Batch logging test failed: ${error}`);
    }
  }

  /**
   * Test batch logging (20 entries)
   */
  testBatchLogging20() {
    try {
      const batchSize = 20;
      for (let i = 0; i < batchSize; i++) {
        const properties = new Map<string, object>();
        properties.set("batchIndex", new Number(i + 1));
        properties.set("totalBatches", new Number(batchSize));
        properties.set("timestamp", new Number(Date.now()));
        
        FTLogger.logBackground(`Batch log ${i + 1}/${batchSize}`, Status.INFO, properties);
      }
      
      this.addTestResult(`✅ Batch logging (20 logs) completed: ${batchSize} logs sent`);
      this.logCount += batchSize;
    } catch (error) {
      this.addTestResult(`❌ Batch logging (20 logs) test failed: ${error}`);
    }
  }

  /**
   * Test different status levels
   */
  testAllStatusLevels() {
    try {
      interface StatusTest {
        status: Status;
        name: string;
      }
      const statuses: StatusTest[] = [
        { status: Status.TRACE, name: "TRACE" },
        { status: Status.DEBUG, name: "DEBUG" },
        { status: Status.INFO, name: "INFO" },
        { status: Status.WARN, name: "WARN" },
        { status: Status.ERROR, name: "ERROR" },
        { status: Status.FATAL, name: "FATAL" }
      ];
      
      statuses.forEach((item: StatusTest) => {
        const status = item.status;
        FTLogger.logBackground(`${item.name} level test log`, status);
      });
      
      this.logCount += statuses.length;
      this.addTestResult(`✅ Status levels test completed: ${statuses.length} logs sent`);
    } catch (error) {
      this.addTestResult(`❌ Status levels test failed: ${error}`);
    }
  }

  /**
   * Test console output
   */
  testConsoleOutput() {
    try {
      // These logs should be printed to the console if printCustomLogToConsole is enabled
      FTLogger.logBackground("Console output test - INFO", Status.INFO);
      FTLogger.logBackground("Console output test - WARN", Status.WARN);
      FTLogger.logBackground("Console output test - ERROR", Status.ERROR);
      console.log('ft-demo','Console output test - log')
      
      this.addTestResult("✅ Console output test completed: 3 manual logs sent; 1 console log captured automatically");
      this.logCount += 4;
    } catch (error) {
      this.addTestResult(`❌ Console output test failed: ${error}`);
    }
  }

  /**
   * Test the service name setting
   */
  testServiceNameSetting() {
    try {
      const properties = new Map<string, object>();
      properties.set("testType", new String("service_name_test"));
      properties.set("expectedService", new String("harmonyos_log_test"));
      
      FTLogger.logBackground("Service name test log", Status.INFO, properties);
      this.logCount += 1;
      this.addTestResult("✅ Service name test completed: 1 log sent");
    } catch (error) {
      this.addTestResult(`❌ Service name test failed: ${error}`);
    }
  }

  /**
   * Test log global context with dictionary values.
   */
  testLogGlobalContextDictionary() {
    try {
      const dynamicContext = new Map<string, LogGlobalContextValue>();
      dynamicContext.set('demo_log_dynamic_tag', 'dynamic_dictionary_value');
      dynamicContext.set('demo_log_dynamic_number_tag', 202);
      const messageId = `log_global_context_dictionary_${Date.now()}`;
      const properties = new Map<string, object>();
      properties.set("testType", new String("log_global_context_dictionary"));
      properties.set("messageId", new String(messageId));

      FTSDK.appendLogGlobalContext(dynamicContext);
      FTSDK.appendLogGlobalContextKeyValue('demo_log_dynamic_single_tag', 'dynamic_single_value');

      FTLogger.logBackground(`Log global context dictionary test ${messageId}`, Status.INFO, properties);
      this.logCount += 1;
      this.addTestResult("✅ Log global context dictionary test completed: 1 log sent");
      this.addTestResult("🔎 Expected tags: demo_log_static_tag, demo_log_number_tag, demo_log_boolean_tag, demo_log_zero_tag, demo_log_false_tag, demo_log_dynamic_tag, demo_log_dynamic_single_tag");
    } catch (error) {
      this.addTestResult(`❌ Log global context dictionary test failed: ${error}`);
    }
  }

  /**
   * Manually trigger data upload
   */
  async triggerDataUpload() {
    try {
      this.addTestResult("🚀 Manually triggering data upload...");
      
      const syncTaskManager = SyncTaskManager.getInstance();
      if (syncTaskManager) {
        syncTaskManager.executeSyncPoll();
        this.addTestResult("✅ Data upload triggered successfully");
      } else {
        this.addTestResult("❌ SyncTaskManager not available");
      }
    } catch (error) {
      this.addTestResult(`❌ Data upload failed: ${error}`);
    }
  }

  /**
   * Clear test results
   */
  clearTestResults() {
    this.testResults = [];
    this.logCount = 0;
  }

  /**
   * Run all tests
   */
  async runAllTests() {
    this.addTestResult("🚀 Running all logBackground tests...");
    
    this.testBasicLogBackground();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testLogBackgroundWithProperties();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testSilentMode();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testAllOverloads();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testBatchLogging();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testAllStatusLevels();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testConsoleOutput();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.testServiceNameSetting();
    await new Promise<void>(resolve => setTimeout(resolve, 100));

    this.testLogGlobalContextDictionary();
    await new Promise<void>(resolve => setTimeout(resolve, 100));
    
    this.addTestResult(`🎉 All tests completed! Total logs sent: ${this.logCount}`);
  }

  build() {
    Column() {
      TestPageHeader({
        title: 'LogBackground Test Page'
      })

    Scroll() {
      Column() {
        // Configuration status
        Row() {
          Text(`Config Status: ${this.isConfigInitialized ? '✅ Initialized' : '❌ Not Initialized'}`)
            .fontSize(16)
            .fontColor(this.isConfigInitialized ? Color.Green : Color.Red)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F5F5F5')

        // Statistics
        Row() {
          Text(`Logs Sent: ${this.logCount}`)
            .fontSize(16)
            .fontColor('#333333')
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#E8F4FD')

        // Test button area
        Column({ space: 10 }) {
          // Basic functionality tests
          Button('Test Basic logBackground')
            .width('100%')
            .height(50)
            .backgroundColor('#007DFF')
            .onClick(() => this.testBasicLogBackground())

          Button('Test With Properties')
            .width('100%')
            .height(50)
            .backgroundColor('#28A745')
            .onClick(() => this.testLogBackgroundWithProperties())

          Button('Test Silent Mode')
            .width('100%')
            .height(50)
            .backgroundColor('#FFC107')
            .onClick(() => this.testSilentMode())

          Button('Test All Overloads')
            .width('100%')
            .height(50)
            .backgroundColor('#17A2B8')
            .onClick(() => this.testAllOverloads())

          Button('Test Batch Logging (10 logs)')
            .width('100%')
            .height(50)
            .backgroundColor('#6F42C1')
            .onClick(() => this.testBatchLogging())

          Button('Test Batch Logging (20 logs)')
            .width('100%')
            .height(50)
            .backgroundColor('#8E44AD')
            .onClick(() => this.testBatchLogging20())

          Button('Test All Status Levels')
            .width('100%')
            .height(50)
            .backgroundColor('#E83E8C')
            .onClick(() => this.testAllStatusLevels())

          Button('Test Console Output')
            .width('100%')
            .height(50)
            .backgroundColor('#20C997')
            .onClick(() => this.testConsoleOutput())

          Button('Test Service Name')
            .width('100%')
            .height(50)
            .backgroundColor('#FD7E14')
            .onClick(() => this.testServiceNameSetting())

          Button('Test Log Global Context Dictionary')
            .width('100%')
            .height(50)
            .backgroundColor('#495057')
            .onClick(() => this.testLogGlobalContextDictionary())

          // Advanced features
          Divider()
            .color('#CCCCCC')
            .margin({ top: 20, bottom: 10 })

          Button('🚀 Trigger Data Upload')
            .width('100%')
            .height(60)
            .backgroundColor('#DC3545')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .onClick(() => this.triggerDataUpload())

          Button('🎯 Run All Tests')
            .width('100%')
            .height(60)
            .backgroundColor('#28A745')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .onClick(() => this.runAllTests())

        }
        .padding(15)
        .backgroundColor('#FFFFFF')

        .width('100%')
        .padding(15)
        .backgroundColor('#F8F9FA')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor('#F5F5F5')
    .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
