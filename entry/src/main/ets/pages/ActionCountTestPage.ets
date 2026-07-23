import {
  AppState,
  ErrorType,
  FTRUMGlobalManager,
  FTSDK,
  NetStatusBean,
  ResourceParams
} from '@guancecloud/ft_sdk/Index';
import { promptAction } from '@kit.ArkUI';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'ActionCountTestPage';

/**
 * Action Count Test Page
 * Tests action_error_count, action_long_task_count, and action_resource_count
 */
@Entry
@Component
export struct ActionCountTestPage {
  @State message: string = 'Action Count Test Page';
  @State isSDKInitialized: boolean = false;
  @State actionErrorCount: number = 0;
  @State actionLongTaskCount: number = 0;
  @State actionResourceCount: number = 0;
  
  // Settings for number of events to generate
  @State errorCountToGenerate: number = 1;
  @State longTaskCountToGenerate: number = 1;
  @State resourceCountToGenerate: number = 1;

  aboutToAppear() {
    this.checkSDKStatus();
  }

  /**
   * Check SDK initialization status
   */
  checkSDKStatus() {
    try {
      const rumConfig = FTSDK.getRumConfig();
      this.isSDKInitialized = rumConfig !== null && rumConfig.getRumAppId().length > 0;
      DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> SDK status: ${this.isSDKInitialized ? 'initialized' : 'not initialized'}`);
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to check SDK status:', error);
      this.isSDKInitialized = false;
    }
  }

  /**
   * Reset counts (for testing multiple actions)
   */
  resetCounts() {
    this.actionErrorCount = 0;
    this.actionLongTaskCount = 0;
    this.actionResourceCount = 0;
    
    promptAction.showToast({
      message: 'Counts reset',
      duration: 2000
    });
  }

  /**
   * Add errors to current action (based on errorCountToGenerate setting)
   */
  addErrorsToAction() {
    if (!this.isSDKInitialized) {
      promptAction.showToast({
        message: 'SDK not initialized',
        duration: 2000
      });
      return;
    }
    
    if (this.errorCountToGenerate <= 0) {
      promptAction.showToast({
        message: 'Error count must be greater than 0',
        duration: 2000
      });
      return;
    }
    
    try {
      const rumGlobalManager = FTRUMGlobalManager.getInstance();
      
      for (let i = 0; i < this.errorCountToGenerate; i++) {
        const errorMessage = `Test Error ${Date.now()}_${i}`;
        const errorStack = `Error: ${errorMessage}\n    at ActionCountTestPage.addErrorsToAction (ActionCountTestPage.ets:${120 + i})\n    at Object.onClick (ActionCountTestPage.ets:456)`;
        
        rumGlobalManager.addError(
          errorStack,
          errorMessage,
          ErrorType.CUSTOM,
          AppState.RUN
        );
        
        this.actionErrorCount++;
        
        DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Error ${i + 1}/${this.errorCountToGenerate} added to action, total count: ${this.actionErrorCount}`);
      }
      
      promptAction.showToast({
        message: `Adding ${this.errorCountToGenerate} error(s)...`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to add errors:', error);
      promptAction.showToast({
        message: `Failed to add errors: ${error}`,
        duration: 2000
      });
    }
  }

  /**
   * Add long tasks to current action (based on longTaskCountToGenerate setting)
   */
  addLongTasksToAction() {
    if (!this.isSDKInitialized) {
      promptAction.showToast({
        message: 'SDK not initialized',
        duration: 2000
      });
      return;
    }
    
    if (this.longTaskCountToGenerate <= 0) {
      promptAction.showToast({
        message: 'Long task count must be greater than 0',
        duration: 2000
      });
      return;
    }
    
    try {
      const rumGlobalManager = FTRUMGlobalManager.getInstance();
      
      for (let i = 0; i < this.longTaskCountToGenerate; i++) {
        setTimeout(() => {
          const duration = 1500000000; // 1.5 seconds in nanoseconds
          const log = `Long Task ${Date.now()}_${i}`;
          
          rumGlobalManager.addLongTask(log, duration);
          
          this.actionLongTaskCount++;
          
          DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Long task ${i + 1}/${this.longTaskCountToGenerate} added to action, total count: ${this.actionLongTaskCount}`);
        }, i * 200);
      }
      
      promptAction.showToast({
        message: `Adding ${this.longTaskCountToGenerate} long task(s)...`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to add long tasks:', error);
      promptAction.showToast({
        message: `Failed to add long tasks: ${error}`,
        duration: 2000
      });
    }
  }

  /**
   * Add resources to current action (based on resourceCountToGenerate setting)
   */
  addResourcesToAction() {
    if (!this.isSDKInitialized) {
      promptAction.showToast({
        message: 'SDK not initialized',
        duration: 2000
      });
      return;
    }
    
    if (this.resourceCountToGenerate <= 0) {
      promptAction.showToast({
        message: 'Resource count must be greater than 0',
        duration: 2000
      });
      return;
    }
    
    try {
      const rumGlobalManager = FTRUMGlobalManager.getInstance();
      
      for (let i = 0; i < this.resourceCountToGenerate; i++) {
        const resourceId = `resource_${Date.now()}_${i}_${Math.floor(Math.random() * 1000)}`;
        
        DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Adding resource ${i + 1}/${this.resourceCountToGenerate}: ${resourceId}`);
        
        // Start resource immediately
        rumGlobalManager.startResource(resourceId);
        
        // Simulate resource loading (async - action will wait for resource completion via pending_resource_count mechanism)
        setTimeout(() => {
          // Stop resource
          rumGlobalManager.stopResource(resourceId);
          
          // Add resource data
          const params = new ResourceParams();
          params.url = `https://api.example.com/resource/${Date.now()}_${i}`;
          params.resourceMethod = 'GET';
          params.resourceStatus = 200;
          params.resourceType = 'network';
          params.responseContentLength = 1024;
          params.responseHeader = 'Content-Type: application/json';
          params.responseBody = '{"status": "success"}';
          params.requestHeader = 'User-Agent: HarmonyOS-SDK';
          params.responseContentType = 'application/json';
          params.responseConnection = 'keep-alive';
          
          const netStatusBean = new NetStatusBean();
          // Use fixed values for fake data, converted to nanoseconds (relative start times)
          const dnsDuration = 10 * 1000000; // 10ms to ns
          const tcpDuration = 20 * 1000000; // 20ms to ns
          const sslDuration = 30 * 1000000; // 30ms to ns
          const ttfbDuration = 100 * 1000000; // 100ms to ns
          const downloadDuration = 50 * 1000000; // 50ms to ns

          netStatusBean.setDNSStartTime(0);
          netStatusBean.setDNSTime(dnsDuration);
          netStatusBean.setConnectStartTime(dnsDuration);
          netStatusBean.setTcpTime(tcpDuration);
          netStatusBean.setSslStartTime(dnsDuration + tcpDuration);
          netStatusBean.setSSLTime(sslDuration);
          netStatusBean.setFirstByteStartTime(dnsDuration + tcpDuration + sslDuration);
          netStatusBean.setFirstByteTime(ttfbDuration);
          netStatusBean.setDownloadTimeStart(dnsDuration + tcpDuration + sslDuration + ttfbDuration);
          netStatusBean.setDownloadTime(downloadDuration);
          netStatusBean.setHoleRequestTime(dnsDuration + tcpDuration + sslDuration + ttfbDuration + downloadDuration);
          
          rumGlobalManager.addResource(resourceId, params, netStatusBean);
          
          this.actionResourceCount++;
          
          DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Resource ${i + 1}/${this.resourceCountToGenerate} added to action, total count: ${this.actionResourceCount}`);
        }, 100);
      }
      
      promptAction.showToast({
        message: `Adding ${this.resourceCountToGenerate} resource(s)...`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to add resources:', error);
      promptAction.showToast({
        message: `Failed to add resources: ${error}`,
        duration: 2000
      });
    }
  }

  /**
   * Add all event types (errors, long tasks, and resources) to current action
   */
  addAllEventsToAction() {
    if (!this.isSDKInitialized) {
      promptAction.showToast({
        message: 'SDK not initialized',
        duration: 2000
      });
      return;
    }

    try {
      const rumGlobalManager = FTRUMGlobalManager.getInstance();
      let totalEvents = 0;

      // Add errors (immediately, no delay)
      for (let i = 0; i < this.errorCountToGenerate; i++) {
        try {
          const errorMessage = `Test Error ${Date.now()}_${i}`;
          const errorStack = `Error: ${errorMessage}\n    at ActionCountTestPage.addAllEventsToAction (ActionCountTestPage.ets:${260 + i})`;

          rumGlobalManager.addError(
            errorStack,
            errorMessage,
            ErrorType.CUSTOM,
            AppState.RUN
          );

          this.actionErrorCount++;
          totalEvents++;
          DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Error ${i + 1}/${this.errorCountToGenerate} added, total events: ${totalEvents}`);
        } catch (error) {
          DemoLogger.e(TAG, 'Failed to add error:', error);
        }
      }

      // Add long tasks
      for (let i = 0; i < this.longTaskCountToGenerate; i++) {
        setTimeout(() => {
          try {
            const longTaskLog = `Test Long Task ${Date.now()}_${i}`;
            const duration = 150 * 1000000; // 150ms in nanoseconds

            rumGlobalManager.addLongTask(longTaskLog, duration);

            this.actionLongTaskCount++;
            totalEvents++;
            DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Long Task ${i + 1}/${this.longTaskCountToGenerate} added, total events: ${totalEvents}`);
          } catch (error) {
            DemoLogger.e(TAG, 'Failed to add long task:', error);
          }
        }, (this.errorCountToGenerate * 100) + (i * 100));
      }

      // Add resources (start immediately, no delay)
      for (let i = 0; i < this.resourceCountToGenerate; i++) {
        try {
          const resourceId = `resource_${Date.now()}_${i}_${Math.floor(Math.random() * 1000)}`;

          // Start resource immediately
          rumGlobalManager.startResource(resourceId);

          // Simulate resource loading (async - action will wait for resource completion via pending_resource_count mechanism)
          setTimeout(() => {
            // Stop resource
            rumGlobalManager.stopResource(resourceId);

            // Add resource data
            const params = new ResourceParams();
            params.url = `https://api.example.com/resource/${Date.now()}_${i}`;
            params.resourceMethod = 'GET';
            params.resourceStatus = 200;
            params.resourceType = 'network';
            params.responseContentLength = 1024;
            params.responseHeader = 'Content-Type: application/json';
            params.responseBody = '{"status": "success"}';
            params.requestHeader = 'User-Agent: HarmonyOS-SDK';
            params.responseContentType = 'application/json';
            params.responseConnection = 'keep-alive';

            const netStatusBean = new NetStatusBean();
            // Use fixed values for fake data, converted to nanoseconds (relative start times)
            const dnsDuration = 10 * 1000000; // 10ms to ns
            const tcpDuration = 20 * 1000000; // 20ms to ns
            const sslDuration = 30 * 1000000; // 30ms to ns
            const ttfbDuration = 100 * 1000000; // 100ms to ns
            const downloadDuration = 50 * 1000000; // 50ms to ns

            netStatusBean.setDNSStartTime(0);
            netStatusBean.setDNSTime(dnsDuration);
            netStatusBean.setConnectStartTime(dnsDuration);
            netStatusBean.setTcpTime(tcpDuration);
            netStatusBean.setSslStartTime(dnsDuration + tcpDuration);
            netStatusBean.setSSLTime(sslDuration);
            netStatusBean.setFirstByteStartTime(dnsDuration + tcpDuration + sslDuration);
            netStatusBean.setFirstByteTime(ttfbDuration);
            netStatusBean.setDownloadTimeStart(dnsDuration + tcpDuration + sslDuration + ttfbDuration);
            netStatusBean.setDownloadTime(downloadDuration);
            netStatusBean.setHoleRequestTime(dnsDuration + tcpDuration + sslDuration + ttfbDuration + downloadDuration);

            rumGlobalManager.addResource(resourceId, params, netStatusBean);

            this.actionResourceCount++;
            totalEvents++;
            DemoLogger.i(TAG, `<FT-ACTION-COUNT-TEST> Resource ${i + 1}/${this.resourceCountToGenerate} added, total events: ${totalEvents}`);
          }, 100);
        } catch (error) {
          DemoLogger.e(TAG, 'Failed to add resource:', error);
        }
      }

      const totalExpected = this.errorCountToGenerate + this.longTaskCountToGenerate + this.resourceCountToGenerate;
      promptAction.showToast({
        message: `Adding ${totalExpected} events (${this.errorCountToGenerate} errors, ${this.longTaskCountToGenerate} long tasks, ${this.resourceCountToGenerate} resources)...`,
        duration: 3000
      });
    } catch (error) {
      DemoLogger.e(TAG, 'Failed to add all events:', error);
      promptAction.showToast({
        message: `Failed to add all events: ${error}`,
        duration: 2000
      });
    }
  }


  build() {
    Column() {
      TestPageHeader({
        title: this.message,
        backCustomPropertyGroup: 'action-count-test',
        backCustomPropertyValue: 'back'
      })

      Scroll() {
        Column({ space: 15 }) {
          // SDK Status
          Column({ space: 10 }) {
            Text('SDK Status')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
            
            Text(this.isSDKInitialized ? '✓ Initialized' : '✗ Not Initialized')
              .fontSize(14)
              .fontColor(this.isSDKInitialized ? Color.Green : Color.Red)
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          // Info
          Column({ space: 10 }) {
            Text('Test Info')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
            
            Text('Actions are automatically tracked when you click buttons')
              .fontSize(14)
              .fontColor(Color.Black)
            
            Text('Click the test buttons below to add errors, long tasks, or resources to the current action')
              .fontSize(12)
              .fontColor(Color.Gray)
              .margin({ top: 5 })
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          // Count Display
          Column({ space: 10 }) {
            Text('Action Counts')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 10 })
            
            Row() {
              Text('Error Count:')
                .fontSize(14)
                .fontColor(Color.Black)
              Text(`${this.actionErrorCount}`)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FF5252')
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            
            Row() {
              Text('Long Task Count:')
                .fontSize(14)
                .fontColor(Color.Black)
              Text(`${this.actionLongTaskCount}`)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FF9800')
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            
            Row() {
              Text('Resource Count:')
                .fontSize(14)
                .fontColor(Color.Black)
              Text(`${this.actionResourceCount}`)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#2196F3')
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          // Count Settings
          Column({ space: 15 }) {
            Text('Event Count Settings')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 10 })
            
            // Error count setting
            Column({ space: 5 }) {
              Text('Error Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 20 }) {
                Button('-')
                  .customProperty('action-count-test', 'decrease-error-count')
                  .onClick(() => {
                    if (this.errorCountToGenerate > 1) {
                      this.errorCountToGenerate--;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.errorCountToGenerate > 1)

                Text(`${this.errorCountToGenerate}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FF5252')
                  .width(80)
                  .textAlign(TextAlign.Center)

                Button('+')
                  .customProperty('action-count-test', 'increase-error-count')
                  .onClick(() => {
                    if (this.errorCountToGenerate < 10) {
                      this.errorCountToGenerate++;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.errorCountToGenerate < 10)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            
            // Long task count setting
            Column({ space: 5 }) {
              Text('Long Task Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 20 }) {
                Button('-')
                  .customProperty('action-count-test', 'decrease-long-task-count')
                  .onClick(() => {
                    if (this.longTaskCountToGenerate > 1) {
                      this.longTaskCountToGenerate--;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.longTaskCountToGenerate > 1)

                Text(`${this.longTaskCountToGenerate}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FF9800')
                  .width(80)
                  .textAlign(TextAlign.Center)

                Button('+')
                  .customProperty('action-count-test', 'increase-long-task-count')
                  .onClick(() => {
                    if (this.longTaskCountToGenerate < 10) {
                      this.longTaskCountToGenerate++;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.longTaskCountToGenerate < 10)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            
            // Resource count setting
            Column({ space: 5 }) {
              Text('Resource Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 20 }) {
                Button('-')
                  .customProperty('action-count-test', 'decrease-resource-count')
                  .onClick(() => {
                    if (this.resourceCountToGenerate > 1) {
                      this.resourceCountToGenerate--;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.resourceCountToGenerate > 1)

                Text(`${this.resourceCountToGenerate}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2196F3')
                  .width(80)
                  .textAlign(TextAlign.Center)

                Button('+')
                  .customProperty('action-count-test', 'increase-resource-count')
                  .onClick(() => {
                    if (this.resourceCountToGenerate < 10) {
                      this.resourceCountToGenerate++;
                    }
                  })
                  .width(60)
                  .height(50)
                  .enabled(this.resourceCountToGenerate < 10)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          // Test Buttons
          Column({ space: 10 }) {
            Text('Generate Events')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 10 })
            
            Button(`Add ${this.errorCountToGenerate} Error(s)`)
              .width('100%')
              .height(50)
              .fontSize(16)
              .backgroundColor('#FF5252')
              .fontColor(Color.White)
              .customProperty('action-count-test', 'add-errors')
              .onClick(() => {
                this.addErrorsToAction();
              })
            
            Button(`Add ${this.longTaskCountToGenerate} Long Task(s)`)
              .width('100%')
              .height(50)
              .fontSize(16)
              .backgroundColor('#FF9800')
              .fontColor(Color.White)
              .customProperty('action-count-test', 'add-long-tasks')
              .onClick(() => {
                this.addLongTasksToAction();
              })
            
            Button(`Add ${this.resourceCountToGenerate} Resource(s)`)
              .width('100%')
              .height(50)
              .fontSize(16)
              .backgroundColor('#2196F3')
              .fontColor(Color.White)
              .customProperty('action-count-test', 'add-resources')
              .onClick(() => {
                this.addResourcesToAction();
              })
            
            Button(`Add All Events (${this.errorCountToGenerate}E + ${this.longTaskCountToGenerate}LT + ${this.resourceCountToGenerate}R)`)
              .customProperty('action-count-test', 'add-all-events')
              .width('100%')
              .height(50)
              .fontSize(16)
              .backgroundColor('#9C27B0')
              .fontColor(Color.White)
              .margin({ top: 10 })
              .onClick(() => {
                this.addAllEventsToAction();
              })
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          // Instructions
          Column({ space: 10 }) {
            Text('Instructions')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 10 })
            
            Text('1. Actions are automatically tracked when you click buttons')
              .fontSize(12)
              .fontColor(Color.Gray)
            
            Text('2. Click test buttons below to add errors, long tasks, or resources')
              .fontSize(12)
              .fontColor(Color.Gray)
            
            Text('3. Each button click creates an action automatically')
              .fontSize(12)
              .fontColor(Color.Gray)
            
            Text('4. Check the counts above (local display only)')
              .fontSize(12)
              .fontColor(Color.Gray)
            
            Text('5. Check logs to verify action counts in uploaded data')
              .fontSize(12)
              .fontColor(Color.Gray)
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#E3F2FD')
          .borderRadius(8)
          .margin({ bottom: 20 })

          // Reset button
          Button('Reset Counts')
            .customProperty('action-count-test', 'reset-counts')
            .width('100%')
            .height(50)
            .fontSize(16)
            .backgroundColor('#9E9E9E')
            .fontColor(Color.White)
            .onClick(() => {
              this.resetCounts();
            })
            .margin({ bottom: 20 })
        }
        .width('100%')
        .padding(20)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
