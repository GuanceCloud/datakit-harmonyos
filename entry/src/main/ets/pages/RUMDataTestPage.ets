import {
  AppState,
  ErrorType,
  FTRUMGlobalManager,
  NetStatusBean,
  ResourceParams,
  StringWrapper
} from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'RUMDataTestPage';

class PropertyWrapper {
  value: string | number | boolean | object;

  constructor(value: string | number | boolean | object) {
    this.value = value;
  }
}

class PropertyBag {
  private properties: Map<string, string | number | boolean | object> = new Map();

  set(key: string, value: string | number | boolean | object): void {
    this.properties.set(key, value);
  }

  toWrappedRecord(): Record<string, object> {
    const result: Record<string, object> = {};
    this.properties.forEach((value, key) => {
      result[key] = new PropertyWrapper(value) as object;
    });
    return result;
  }

  toPrimitiveRecord(): Record<string, string | number | boolean> {
    const result: Record<string, string | number | boolean> = {};
    this.properties.forEach((value, key) => {
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
        result[key] = value;
      } else {
        result[key] = JSON.stringify(value);
      }
    });
    return result;
  }
}

class ViewPropertySet {
  private props: Record<string, object> = {};

  putString(key: string, value: string): void {
    this.props[key] = new String(value) as object;
  }

  putBoolean(key: string, value: boolean): void {
    this.props[key] = new Boolean(value) as object;
  }

  putNumber(key: string, value: number): void {
    this.props[key] = new Number(value) as object;
  }

  toRecord(): Record<string, object> {
    return this.props;
  }
}

class ActionPropertySet {
  button_id: StringWrapper;
  page_name: StringWrapper;
  user_type: StringWrapper;

  constructor(buttonId: string, pageName: string, userType: string) {
    this.button_id = new StringWrapper(buttonId);
    this.page_name = new StringWrapper(pageName);
    this.user_type = new StringWrapper(userType);
  }

  toRecord(): Record<string, object> {
    const result: Record<string, object> = {};
    result['button_id'] = this.button_id;
    result['page_name'] = this.page_name;
    result['user_type'] = this.user_type;
    return result;
  }
}

class LongTaskDurationItem {
  name: string;
  duration: number;

  constructor(name: string, duration: number) {
    this.name = name;
    this.duration = duration;
  }
}

@Entry
@Component
export struct RUMDataTestPage {
  @State message: string = 'RUM Unified Test Page';
  @State isSDKInitialized: boolean = false;
  @State actionCount: number = 0;
  @State errorCount: number = 0;
  @State longTaskCount: number = 0;
  @State resourceCount: number = 0;
  @State viewCount: number = 0;
  @State currentViewName: string = '';
  @State isViewActive: boolean = false;
  @State loadTime: number = 0;
  @State testResults: string = '';

  aboutToAppear(): void {
    this.checkSDKStatus();
    this.appendResult('RUM unified test page loaded');
  }

  private checkSDKStatus(): void {
    try {
      const rumManager = FTRUMGlobalManager.getInstance();
      this.isSDKInitialized = rumManager.isInitialized();
      this.appendResult(`SDK status: ${this.isSDKInitialized ? 'initialized' : 'not initialized'}`);
    } catch (error) {
      this.isSDKInitialized = false;
      this.appendResult(`Failed to check SDK status: ${error}`);
    }
  }

  private getRumManager(): FTRUMGlobalManager | null {
    if (!this.isSDKInitialized) {
      this.appendResult('SDK not initialized, skipping test');
      return null;
    }
    return FTRUMGlobalManager.getInstance();
  }

  private appendResult(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    this.testResults += `[${timestamp}] ${message}\n`;
    const lines = this.testResults.split('\n');
    if (lines.length > 80) {
      this.testResults = lines.slice(lines.length - 80).join('\n');
    }
    DemoLogger.i(TAG, message);
  }

  private clearResults(): void {
    this.testResults = '';
  }

  private resetCounts(): void {
    this.actionCount = 0;
    this.errorCount = 0;
    this.longTaskCount = 0;
    this.resourceCount = 0;
    this.viewCount = 0;
    this.loadTime = 0;
    this.currentViewName = '';
    this.isViewActive = false;
    this.appendResult('All counters reset');
  }

  private testBasicStartAction(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      rumManager.startAction('basic_click', 'click');
      this.actionCount++;
      this.appendResult('Action: startAction(basic_click) sent');
    } catch (error) {
      this.appendResult(`Action basic start failed: ${error}`);
    }
  }

  private testStartActionWithProperty(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const property = new ActionPropertySet('rum_unified_btn', 'RUMDataTestPage', 'test_user');
      rumManager.startActionWithProperty('property_click', 'click', property.toRecord());
      this.actionCount++;
      this.appendResult('Action: startActionWithProperty(property_click) sent');
    } catch (error) {
      this.appendResult(`Action with property failed: ${error}`);
    }
  }

  private testBasicAddAction(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      rumManager.addAction('basic_add', 'click');
      this.actionCount++;
      this.appendResult('Action: addAction(basic_add) sent');
    } catch (error) {
      this.appendResult(`Basic addAction failed: ${error}`);
    }
  }

  private testAddActionWithDuration(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      rumManager.addActionWithDuration('duration_add', 'click', 2_000_000_000);
      this.actionCount++;
      this.appendResult('Action: addActionWithDuration(duration_add, 2s) sent');
    } catch (error) {
      this.appendResult(`addActionWithDuration failed: ${error}`);
    }
  }

  private runActionSuite(): void {
    this.appendResult('Running action suite...');
    this.testBasicStartAction();
    this.testStartActionWithProperty();
    this.testBasicAddAction();
    this.testAddActionWithDuration();
  }

  private sendBasicError(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      rumManager.addError(
        'Error stack trace:\n  at sendBasicError (RUMDataTestPage.ets)\n  at onClick (RUMDataTestPage.ets)',
        'Basic error message',
        ErrorType.CUSTOM,
        AppState.RUN
      );
      this.errorCount++;
      this.appendResult('Error: basic addError sent');
    } catch (error) {
      this.appendResult(`Basic error failed: ${error}`);
    }
  }

  private sendErrorWithProperties(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const propertyBag = new PropertyBag();
      propertyBag.set('error_code', 'PROP_001');
      propertyBag.set('module', 'RUMDataTestPage');
      propertyBag.set('severity', 'high');
      propertyBag.set('test_group', 'unified');
      rumManager.addError(
        'Error stack trace:\n  at sendErrorWithProperties (RUMDataTestPage.ets)\n  at onClick (RUMDataTestPage.ets)',
        'Error with properties message',
        ErrorType.CUSTOM,
        AppState.RUN,
        propertyBag.toWrappedRecord()
      );
      this.errorCount++;
      this.appendResult('Error: addError with properties sent');
    } catch (error) {
      this.appendResult(`Error with properties failed: ${error}`);
    }
  }

  private sendCustomError(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const propertyBag = new PropertyBag();
      propertyBag.set('error_code', 'CUSTOM_001');
      propertyBag.set('module', 'RUMDataTestPage');
      propertyBag.set('method', 'addCustomError');
      rumManager.addCustomError(
        'Custom error message from unified test page',
        'Error stack trace:\n  at sendCustomError (RUMDataTestPage.ets)\n  at onClick (RUMDataTestPage.ets)',
        propertyBag.toWrappedRecord()
      );
      this.errorCount++;
      this.appendResult('Error: addCustomError sent');
    } catch (error) {
      this.appendResult(`Custom error failed: ${error}`);
    }
  }

  private runErrorSuite(): void {
    this.appendResult('Running error suite...');
    this.sendBasicError();
    this.sendErrorWithProperties();
    this.sendCustomError();
  }

  private sendBasicLongTask(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      rumManager.addLongTask('Basic long task test', 2_000_000_000);
      this.longTaskCount++;
      this.appendResult('LongTask: basic addLongTask(2s) sent');
    } catch (error) {
      this.appendResult(`Basic long task failed: ${error}`);
    }
  }

  private sendLongTaskWithProperties(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const propertyBag = new PropertyBag();
      propertyBag.set('task_type', 'performance_test');
      propertyBag.set('module', 'RUMDataTestPage');
      propertyBag.set('priority', 'high');
      propertyBag.set('session_id', 'session_456');
      rumManager.addLongTask('Long task with properties', 3_000_000_000, propertyBag.toPrimitiveRecord());
      this.longTaskCount++;
      this.appendResult('LongTask: addLongTask with properties sent');
    } catch (error) {
      this.appendResult(`Long task with properties failed: ${error}`);
    }
  }

  private sendLongTaskDurations(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    const durations: LongTaskDurationItem[] = [
      new LongTaskDurationItem('Short Task', 1_000_000_000),
      new LongTaskDurationItem('Medium Task', 5_000_000_000),
      new LongTaskDurationItem('Long Task', 10_000_000_000)
    ];

    try {
      for (let i = 0; i < durations.length; i++) {
        const task = durations[i];
        rumManager.addLongTask(`${task.name} execution`, task.duration);
        this.longTaskCount++;
      }
      this.appendResult('LongTask: duration suite sent (1s/5s/10s)');
    } catch (error) {
      this.appendResult(`Long task duration suite failed: ${error}`);
    }
  }

  private runLongTaskSuite(): void {
    this.appendResult('Running long task suite...');
    this.sendBasicLongTask();
    this.sendLongTaskWithProperties();
    this.sendLongTaskDurations();
  }

  private createResourceId(prefix: string): string {
    return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  private createResourceParams(url: string, status: number, method: string = 'GET'): ResourceParams {
    const params = new ResourceParams();
    params.url = url;
    params.resourceMethod = method;
    params.resourceStatus = status;
    params.resourceType = 'network';
    params.responseContentLength = 1024;
    params.responseHeader = 'Content-Type: application/json';
    params.responseBody = '{"status":"success"}';
    params.requestHeader = 'User-Agent: HarmonyOS-SDK';
    params.responseContentType = 'application/json';
    params.responseConnection = 'keep-alive';
    return params;
  }

  private createNetStatusBean(totalTime: number): NetStatusBean {
    const currentTime = Date.now();
    const bean = new NetStatusBean();
    bean.setDNSStartTime(currentTime);
    bean.setDNSTime(10);
    bean.setConnectStartTime(currentTime + 10);
    bean.setTcpTime(20);
    bean.setFirstByteStartTime(currentTime + 30);
    bean.setFirstByteTime(60);
    bean.setDownloadTimeStart(currentTime + 90);
    bean.setDownloadTime(40);
    bean.setHoleRequestTime(totalTime);
    return bean;
  }

  private sendBasicResource(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const resourceId = this.createResourceId('resource');
      rumManager.startResource(resourceId);
      setTimeout(() => {
        rumManager.stopResource(resourceId, 200, 1024);
        rumManager.addResource(
          resourceId,
          this.createResourceParams('https://api.example.com/resource', 200),
          this.createNetStatusBean(180)
        );
        this.resourceCount++;
        this.appendResult(`Resource: basic resource sent (${resourceId})`);
      }, 100);
    } catch (error) {
      this.appendResult(`Basic resource failed: ${error}`);
    }
  }

  private sendResourceWithProperties(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const resourceId = this.createResourceId('resource_prop');
      rumManager.startResource(resourceId);
      setTimeout(() => {
        rumManager.stopResource(resourceId, 201, 2048);
        rumManager.addResource(
          resourceId,
          this.createResourceParams('https://api.example.com/resource/with-meta', 201, 'POST'),
          this.createNetStatusBean(220)
        );
        this.resourceCount++;
        this.appendResult(`Resource: property-style resource sent (${resourceId})`);
      }, 120);
    } catch (error) {
      this.appendResult(`Resource with properties failed: ${error}`);
    }
  }

  private sendResourceStatusSuite(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    const statuses = [200, 404, 500];

    try {
      for (let i = 0; i < statuses.length; i++) {
        const status = statuses[i];
        const resourceId = this.createResourceId(`resource_${status}`);
        rumManager.startResource(resourceId);
        setTimeout(() => {
          rumManager.stopResource(resourceId, status, 1024 + i * 256);
          rumManager.addResource(
            resourceId,
            this.createResourceParams(`https://api.example.com/status/${status}`, status),
            this.createNetStatusBean(150 + i * 30)
          );
          this.resourceCount++;
        }, 60 + i * 40);
      }
      this.appendResult('Resource: status suite sent (200/404/500)');
    } catch (error) {
      this.appendResult(`Resource status suite failed: ${error}`);
    }
  }

  private runResourceSuite(): void {
    this.appendResult('Running resource suite...');
    this.sendBasicResource();
    this.sendResourceWithProperties();
    this.sendResourceStatusSuite();
  }

  private startViewTest(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const viewName = `TestView_${Date.now()}`;
      rumManager.startView(viewName);
      this.currentViewName = viewName;
      this.isViewActive = true;
      this.loadTime = 0;
      this.viewCount++;
      this.appendResult(`View: started ${viewName}`);
    } catch (error) {
      this.appendResult(`Start view failed: ${error}`);
    }
  }

  private stopViewTest(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const previousViewName = this.currentViewName;
      rumManager.stopView();
      this.isViewActive = false;
      this.currentViewName = '';
      this.appendResult(`View: stopped ${previousViewName || 'active view'}`);
    } catch (error) {
      this.appendResult(`Stop view failed: ${error}`);
    }
  }

  private updateViewLoadTime(): void {
    const rumManager = this.getRumManager();
    if (!rumManager || !this.isViewActive) {
      this.appendResult('No active view, skipping load time update');
      return;
    }

    try {
      const newLoadTime = Math.floor(Math.random() * 5000) + 1000;
      rumManager.updateLoadTime(newLoadTime);
      this.loadTime = newLoadTime;
      this.appendResult(`View: load time updated to ${newLoadTime}ms`);
    } catch (error) {
      this.appendResult(`Update load time failed: ${error}`);
    }
  }

  private startViewWithProperties(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const viewName = `PropertyView_${Date.now()}`;
      const properties = new ViewPropertySet();
      properties.putString('page_type', 'test');
      properties.putString('test_id', 'property_test_001');
      properties.putString('user_level', 'premium');
      properties.putBoolean('feature_flag', true);
      properties.putNumber('load_priority', 1);
      rumManager.startView(viewName, properties.toRecord());
      this.currentViewName = viewName;
      this.isViewActive = true;
      this.viewCount++;
      this.appendResult(`View: started ${viewName} with properties`);
    } catch (error) {
      this.appendResult(`View with properties failed: ${error}`);
    }
  }

  private testMultipleViews(): void {
    const rumManager = this.getRumManager();
    if (!rumManager) {
      return;
    }

    try {
      const view1 = `MultiView_A_${Date.now()}`;
      const view2 = `MultiView_B_${Date.now()}`;
      rumManager.startView(view1);
      this.viewCount++;
      setTimeout(() => {
        rumManager.startView(view2);
        this.viewCount++;
        this.currentViewName = view2;
        this.isViewActive = true;
      }, 120);
      this.appendResult(`View: multiple view sequence started (${view1} -> ${view2})`);
    } catch (error) {
      this.appendResult(`Multiple views failed: ${error}`);
    }
  }

  private runViewSuite(): void {
    this.appendResult('Running view suite...');
    this.startViewTest();
    this.updateViewLoadTime();
    this.startViewWithProperties();
    this.testMultipleViews();
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

      Text(`SDK Status: ${this.isSDKInitialized ? 'Initialized' : 'Not Initialized'}`)
        .fontSize(16)
        .fontColor(this.isSDKInitialized ? Color.Green : Color.Red)
        .margin({ bottom: 12 })

      Column() {
        Text(`Action Count: ${this.actionCount}`).fontSize(15).margin({ bottom: 6 })
        Text(`Error Count: ${this.errorCount}`).fontSize(15).margin({ bottom: 6 })
        Text(`Long Task Count: ${this.longTaskCount}`).fontSize(15).margin({ bottom: 6 })
        Text(`Resource Count: ${this.resourceCount}`).fontSize(15).margin({ bottom: 6 })
        Text(`View Count: ${this.viewCount}`).fontSize(15).margin({ bottom: 6 })
        Text(`Current View: ${this.currentViewName || 'None'}`).fontSize(15).margin({ bottom: 6 })
        Text(`Load Time: ${this.loadTime}ms`).fontSize(15)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F0F4F8')
      .borderRadius(8)
      .margin({ bottom: 16 })

      Scroll() {
        Column() {
          Text('Action Tests').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Run Action Suite').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.runActionSuite())
          Button('Basic startAction').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.testBasicStartAction())
          Button('startAction with Property').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.testStartActionWithProperty())
          Button('Basic addAction').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.testBasicAddAction())
          Button('addAction with Duration').width('100%').height(48).margin({ bottom: 18 }).onClick(() => this.testAddActionWithDuration())

          Text('Error Tests').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Run Error Suite').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.runErrorSuite())
          Button('Basic addError').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendBasicError())
          Button('addError with Properties').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendErrorWithProperties())
          Button('addCustomError').width('100%').height(48).margin({ bottom: 18 }).onClick(() => this.sendCustomError())

          Text('Long Task Tests').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Run Long Task Suite').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.runLongTaskSuite())
          Button('Basic addLongTask').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendBasicLongTask())
          Button('addLongTask with Properties').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendLongTaskWithProperties())
          Button('Long Task Duration Suite').width('100%').height(48).margin({ bottom: 18 }).onClick(() => this.sendLongTaskDurations())

          Text('Resource Tests').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Run Resource Suite').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.runResourceSuite())
          Button('Basic Resource').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendBasicResource())
          Button('Resource with Metadata').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.sendResourceWithProperties())
          Button('Resource Status Suite').width('100%').height(48).margin({ bottom: 18 }).onClick(() => this.sendResourceStatusSuite())

          Text('View Tests').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Run View Suite').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.runViewSuite())
          Button('Start View').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.startViewTest())
          Button('Stop View').width('100%').height(48).margin({ bottom: 10 }).enabled(this.isViewActive).onClick(() => this.stopViewTest())
          Button('Update Load Time').width('100%').height(48).margin({ bottom: 10 }).enabled(this.isViewActive).onClick(() => this.updateViewLoadTime())
          Button('View with Properties').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.startViewWithProperties())
          Button('Multiple Views').width('100%').height(48).margin({ bottom: 18 }).onClick(() => this.testMultipleViews())

          Text('Utilities').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 8, bottom: 12 })
          Button('Refresh SDK Status').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.checkSDKStatus())
          Button('Reset Counts').width('100%').height(48).margin({ bottom: 10 }).onClick(() => this.resetCounts())
        }
        .padding({ left: 20, right: 20, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
