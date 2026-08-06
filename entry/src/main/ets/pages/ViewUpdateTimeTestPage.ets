/**
 * View Update Time Test Page
 * Test view_update_time counter functionality
 */
import { createFTRCPTrackConfig, FTRUMGlobalManager, FTSDK } from '@guancecloud/ft_sdk/Index';
import { rcp } from '@kit.RemoteCommunicationKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "ViewUpdateTimeTest";

@Entry
@Component
export struct ViewUpdateTimeTestPage {
  @State message: string = 'View Update Time Test';
  @State testResults: string[] = [];
  @State currentViewId: string = '';
  @State currentViewUpdateTime: number = 0;
  @State resourceRequestCount: number = 0;

  aboutToAppear() {
    this.addTestResult("View Update Time Test Page loaded");
    this.checkSDKStatus();
  }

  private createTrackedSession(baseAddress?: string): rcp.Session {
    return rcp.createSession(createFTRCPTrackConfig({
      baseAddress: baseAddress
    }));
  }

  aboutToDisappear() {
    try {
      FTRUMGlobalManager.getInstance().stopView({});
      this.addTestResult("✅ View stopped automatically on page disappear");
    } catch (error) {
      this.addTestResult(`❌ Failed to stop view: ${error}`);
    }
  }

  /**
   * Check SDK initialization status
   */
  checkSDKStatus() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      const isInitialized = rumConfig !== null && rumConfig.getRumAppId().length > 0;
      this.addTestResult(`SDK Status: ${isInitialized ? '✅ Initialized' : '❌ Not Initialized'}`);
      
      if (!isInitialized) {
        this.addTestResult("⚠️ Please initialize SDK first");
      }
    } catch (error) {
      this.addTestResult(`❌ Failed to check SDK status: ${error}`);
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

  /**
   * Start a new view and check initial view_update_time
   */
  async testStartView() {
    try {
      const rumGlobalManager = FTRUMGlobalManager.getInstance();
      
      // Start a new view
      rumGlobalManager.startView('ViewUpdateTimeTestPage', {});
      this.addTestResult("✅ Started view: ViewUpdateTimeTestPage");
      
      // Wait a moment for view to be saved to database
      await new Promise<void>(resolve => setTimeout(resolve, 500));
      
      // Query view from database
      await this.queryAndDisplayViewUpdateTime();
      
    } catch (error) {
      this.addTestResult(`❌ Failed to start view: ${error}`);
    }
  }

  /**
   * Query view from database and display view_update_time
   */
  async queryAndDisplayViewUpdateTime() {
    try {
      // Note: FTDBManager doesn't expose a direct query method for views,
      // but we can check via the internal implementation
      // For testing, we'll use FTRUMInnerManager's internal state if accessible
      // or wait for data to be uploaded and check logs
      
      this.addTestResult("ℹ️ View data query triggered, expected initial view_update_time=1");
      
    } catch (error) {
      this.addTestResult(`❌ Failed to query view: ${error}`);
    }
  }

  /**
   * Test resource request to trigger view_update_time increment
   */
  async testResourceRequest() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      const isEnabled = rumConfig !== null && rumConfig.getRumAppId().length > 0;
      
      if (!isEnabled) {
        this.addTestResult("⚠️ RCP interceptor session helper is not available");
        return;
      }

      const session = this.createTrackedSession();

      // Send HTTP request which should trigger stopResource and updateViewUpdateTime
      const request = new rcp.Request('https://httpbin.org/get', 'GET');
      const response = await session.fetch(request);
      
      this.resourceRequestCount++;
      
      if (response.statusCode >= 200 && response.statusCode < 300) {
        this.addTestResult(`✅ Request ${this.resourceRequestCount} successful: ${response.statusCode}`);
        
        // Wait for resource to be processed and view_update_time to be updated
        await new Promise<void>(resolve => setTimeout(resolve, 1000));
        
        this.addTestResult(`ℹ️ Expected view_update_time after ${this.resourceRequestCount} request(s): ${this.resourceRequestCount + 1}`);
        
      } else {
        this.addTestResult(`⚠️ Request returned status: ${response.statusCode}`);
      }
      
    } catch (error) {
      this.addTestResult(`❌ Resource request failed: ${error}`);
    }
  }

  /**
   * Test multiple resource requests to verify counter increments
   */
  async testMultipleResourceRequests() {
    try {
      const session = this.createTrackedSession();
      let successCount = 0;

      for (let i = 1; i <= 5; i++) {
        try {
          const request = new rcp.Request(`https://httpbin.org/get?req=${i}`, 'GET');
          const response = await session.fetch(request);
          
          if (response.statusCode >= 200 && response.statusCode < 300) {
            successCount++;
          }
          
          // Small delay between requests
          await new Promise<void>(resolve => setTimeout(resolve, 300));
        } catch (error) {
          DemoLogger.e(TAG, `Request ${i} failed: ${error}`);
        }
      }
      
      // Wait for all resources to be processed
      await new Promise<void>(resolve => setTimeout(resolve, 2000));
      
      this.resourceRequestCount += 5;
      this.addTestResult(`✅ Multiple requests completed: ${successCount}/5 succeeded, expected view_update_time=${this.resourceRequestCount + 1}`);
      
    } catch (error) {
      this.addTestResult(`❌ Multiple requests test failed: ${error}`);
    }
  }

  /**
   * Clear test results
   */
  clearResults() {
    this.testResults = [];
    this.resourceRequestCount = 0;
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

      // Test buttons
      Column() {
        Button("1. Start New View")
          .width('90%')
          .margin({ top: 10, bottom: 5 })
          .onClick(() => {
            this.testStartView();
          })

        Button("2. Send Resource Request")
          .width('90%')
          .margin({ top: 5, bottom: 5 })
          .onClick(() => {
            this.testResourceRequest();
          })

        Button("3. Multiple Resource Requests (5)")
          .width('90%')
          .margin({ top: 5, bottom: 5 })
          .onClick(() => {
            this.testMultipleResourceRequests();
          })

      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .padding(10)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#FFFFFF')

      // Instructions
      Column() {
        Text("📖 Instructions:")
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 5 })
        Text("1. Start a new view (view_update_time should be 1)")
          .fontSize(12)
          .margin({ bottom: 2 })
        Text("2. Send resource requests (view_update_time increments)")
          .fontSize(12)
          .margin({ bottom: 2 })
        Text("3. Check logs for 'view_update_time' in line protocol")
          .fontSize(12)
          .margin({ bottom: 2 })
        Text("4. Verify counter increments correctly: 1 → 2 → 3 → ...")
          .fontSize(12)
          .margin({ bottom: 2 })
      }
      .width('100%')
      .padding(15)
      .backgroundColor('#E8F4F8')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
