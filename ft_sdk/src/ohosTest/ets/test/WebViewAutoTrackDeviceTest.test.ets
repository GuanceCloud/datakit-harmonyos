import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTWebViewHandler } from '../../../main/ets/components/web/FTWebViewHandler';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const TEST_HOST = 'http://127.0.0.1:9529';
const WEB_SDK_VERSION = '4.0.0';
const WEB_EVENT_TIME_MS = 1710000000000;

type JavaScriptCallback = (err?: Object) => void;

class FakeWebviewController {
  url: string;
  registerCount: number = 0;
  deleteCount: number = 0;
  runCount: number = 0;
  proxyName: string = '';
  methodListText: string = '';
  lastScript: string = '';

  constructor(url: string) {
    this.url = url;
  }

  registerJavaScriptProxy(_receiver: Object, name: string, methodList: string[], _asyncMethodList: string[]): void {
    this.registerCount++;
    this.proxyName = name;
    this.methodListText = methodList.join(',');
  }

  deleteJavaScriptRegister(_name: string): void {
    this.deleteCount++;
  }

  getUrl(): string {
    return this.url;
  }

  runJavaScript(script: string, callback?: JavaScriptCallback): void {
    this.runCount++;
    this.lastScript = script;
    if (callback) {
      callback();
    }
  }
}

interface WebViewProxyReceiver {
  sendEvent(event: string): void;
  sendEventWithCallback(event: string, callbackMethod: string): void;
  addEventListener(event: string, callbackMethod: string): void;
  getAllowedWebViewHosts(): string | null;
}

class WebViewRumEvent {
  name: string = 'rum';
  data: WebViewRumData;
  _tag: string;

  constructor(data: WebViewRumData, tag: string) {
    this.data = data;
    this._tag = tag;
  }
}

class EmptyWebViewData {
}

class SimpleWebViewEvent {
  name: string;
  data: EmptyWebViewData = new EmptyWebViewData();
  _tag: string;

  constructor(name: string, tag: string) {
    this.name = name;
    this._tag = tag;
  }
}

class WebViewRumData {
  measurement: string;
  tags: Object;
  fields: Object;
  time: number;

  constructor(measurement: string, tags: Object, fields: Object, time: number) {
    this.measurement = measurement;
    this.tags = tags;
    this.fields = fields;
    this.time = time;
  }
}

class WebViewViewTags {
  service: string = 'browser';
  sdk_version: string = WEB_SDK_VERSION;
  view_id: string;
  view_name: string;

  constructor(viewId: string, viewName: string) {
    this.view_id = viewId;
    this.view_name = viewName;
  }
}

class WebViewViewFields {
  loading_time: number;
  time_spent: number;

  constructor(loadingTime: number, timeSpent: number) {
    this.loading_time = loadingTime;
    this.time_spent = timeSpent;
  }
}

class WebViewActionTags {
  service: string = 'browser';
  sdk_version: string = WEB_SDK_VERSION;
  view_id: string;
  view_name: string;
  action_name: string;
  action_type: string;

  constructor(viewId: string, viewName: string, actionName: string, actionType: string) {
    this.view_id = viewId;
    this.view_name = viewName;
    this.action_name = actionName;
    this.action_type = actionType;
  }
}

class WebViewActionFields {
  action_id: string;
  duration: number;

  constructor(actionId: string, duration: number) {
    this.action_id = actionId;
    this.duration = duration;
  }
}

class WebViewResourceTags {
  service: string = 'browser';
  sdk_version: string = WEB_SDK_VERSION;
  view_id: string;
  view_name: string;
  resource_url: string;
  resource_url_host: string;
  resource_method: string;
  resource_status: string;

  constructor(viewId: string, viewName: string, resourceUrl: string, resourceStatus: string) {
    this.view_id = viewId;
    this.view_name = viewName;
    this.resource_url = resourceUrl;
    this.resource_url_host = 'webview.test';
    this.resource_method = 'GET';
    this.resource_status = resourceStatus;
  }
}

class WebViewNetworkErrorTags extends WebViewResourceTags {
  error_source: string = 'network';
  error_type: string = 'network';

  constructor(viewId: string, viewName: string, resourceUrl: string, resourceStatus: string) {
    super(viewId, viewName, resourceUrl, resourceStatus);
  }
}

class WebViewResourceFields {
  duration: number;

  constructor(duration: number) {
    this.duration = duration;
  }
}

class WebViewNetworkErrorFields {
  error_message: string;

  constructor(message: string) {
    this.error_message = message;
  }
}

function buildWebViewRumEvent(measurement: string, tags: Object, fields: Object, tag: string): string {
  return JSON.stringify(new WebViewRumEvent(new WebViewRumData(measurement, tags, fields, WEB_EVENT_TIME_MS), tag));
}

function buildSimpleWebViewEvent(name: string, tag: string): string {
  return JSON.stringify(new SimpleWebViewEvent(name, tag));
}

function buildLegacyWebViewEvent(event: string, callbackMethod: string): string {
  const wrapper: Record<string, string> = {};
  wrapper['callbackMethod'] = callbackMethod;
  wrapper['event'] = event;
  return JSON.stringify(wrapper);
}

function buildRumConfig(): FTRUMConfig {
  return new FTRUMConfig()
    .setRumAppId(TEST_FAKE_RUM_ID)
    .setEnableTraceUserView(true)
    .setEnableTraceWebView(true);
}

function containsAll(value: string, fragments: string[]): boolean {
  for (let i = 0; i < fragments.length; i++) {
    if (!value.includes(fragments[i])) {
      return false;
    }
  }
  return true;
}

function getLineProtocolTag(line: string, key: string): string {
  const match = line.match(new RegExp(`(?:^|,)${key}=([^,\\s]+)`));
  return match !== null && match.length > 1 ? match[1] : '';
}

async function countWebViewSyncRecordsContaining(fragments: string[]): Promise<number> {
  const records = await DBAssert.querySyncData([DataType.RUM_WEBVIEW], 100);
  let count = 0;
  for (let i = 0; i < records.length; i++) {
    if (containsAll(records[i].getDataString(), fragments)) {
      count++;
    }
  }
  return count;
}

export default function webViewAutoTrackDeviceTest() {
  describe('WebViewAutoTrackDeviceTest', () => {
    let collector: MockCollector;
    let context: Context;
    let rumConfig: FTRUMConfig;

    beforeEach(async () => {
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      collector = new MockCollector(200, '');
      collector.start();
      rumConfig = buildRumConfig();

      FTSDK.install(FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.GRAY), context);
      FTSDK.installRUMConfig(rumConfig);

      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      collector.stop();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
    });

    it('webViewHandlerShouldGateBridge', 0, () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/register');
      const disabledConfig = new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceWebView(false);

      handler.setWebView(fakeController as Object as webview.WebviewController, disabledConfig);
      expect(fakeController.registerCount).assertEqual(0);

      const proxy = handler.getJavaScriptProxy(fakeController as Object as webview.WebviewController);
      expect(proxy.name).assertEqual('FTWebViewJavascriptBridge');
      expect(proxy.methodList.join(',').includes('getAllowedWebViewHosts')).assertTrue();
      expect(proxy.object !== null).assertTrue();

      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);
      expect(fakeController.registerCount).assertEqual(1);
      expect(fakeController.proxyName).assertEqual('FTWebViewJavascriptBridge');
      expect(fakeController.methodListText.includes('sendEvent')).assertTrue();
      expect(fakeController.methodListText.includes('sendEventWithCallback')).assertTrue();
      expect(fakeController.methodListText.includes('getAllowedWebViewHosts')).assertTrue();
      expect(handler.getAllowedWebViewHosts() === null).assertTrue();

      handler.clearWebController();
      expect(fakeController.deleteCount).assertEqual(1);
    });

    it('traceWebViewShouldCollectRum', 0, async () => {
      const nativeViewName = 'native_webview_host_view';
      const webViewId = 'webview_view_id';
      const webViewName = 'webview_home';
      const webActionName = 'webview_tap';
      const webActionId = `webview_action_id_${Date.now()}`;
      const handler = new FTWebViewHandler();
      const fakeController =
        new FakeWebviewController('https://webview.test/products/list?tab=all#section');

      await FTRUMGlobalManager.getInstance().startView(nativeViewName);
      await WaitUtils.delay(300);
      handler.setNativeViewName(nativeViewName);
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.sendEventWithCallback(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_VIEW,
        new WebViewViewTags(webViewId, webViewName),
        new WebViewViewFields(123, 456),
        'webview_view_event'
      ), null);
      handler.sendEventWithCallback(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_ACTION,
        new WebViewActionTags(webViewId, webViewName, webActionName, 'click'),
        new WebViewActionFields(webActionId, 789),
        'webview_action_event'
      ), null);

      const viewFragments = [
        'view,',
        `view_id=${webViewId}`,
        `view_name=${webViewName}`,
        'is_web_view=true'
      ];
      const actionFragments = [
        'action,',
        `view_id=${webViewId}`,
        `view_name=${webViewName}`,
        `action_name=${webActionName}`,
        'action_type=click',
        'is_web_view=true'
      ];
      const viewRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, viewFragments, 5000);
      const actionRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, actionFragments, 5000);
      const viewLine = viewRecord?.getDataString() ?? '';
      const actionLine = actionRecord?.getDataString() ?? '';

      expect(viewRecord !== null).assertTrue();
      expect(actionRecord !== null).assertTrue();
      expect(viewLine.includes(`view_referrer=${nativeViewName}`)).assertTrue();
      expect(viewLine.includes('view_path_name=/products/list')).assertTrue();
      expect(viewLine.includes('service=browser')).assertTrue();
      expect(viewLine.includes(`sdk_version=${WEB_SDK_VERSION}`)).assertTrue();
      expect(viewLine.includes(`app_id=${TEST_FAKE_RUM_ID}`)).assertTrue();
      expect(viewLine.includes('loading_time=123')).assertTrue();
      expect(actionLine.includes('service=browser')).assertTrue();
      expect(actionLine.includes(`app_id=${TEST_FAKE_RUM_ID}`)).assertTrue();
      expect(actionLine.includes('duration=789')).assertTrue();
      expect(actionLine.includes(webActionId)).assertTrue();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const uploadedView = await collector.waitForPayloadContaining(viewFragments, 5000);
      const uploadedAction = await collector.waitForPayloadContaining(actionFragments, 5000);
      const viewConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_WEBVIEW, viewRecord?.getUuid() ?? '', 5000);
      const actionConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_WEBVIEW, actionRecord?.getUuid() ?? '', 5000);

      expect(uploadedView.length > 0).assertTrue();
      expect(uploadedAction.length > 0).assertTrue();
      expect(viewConsumed).assertTrue();
      expect(actionConsumed).assertTrue();
    });

    it('webViewResourceErrorShouldLinkToResourceSdkDataId', 0, async () => {
      const webViewId = 'webview_resource_error_view_id';
      const webViewName = 'webview_resource_error_view';
      const resourceUrl = 'https://webview.test/api/failed-request';
      const resourceStatus = '503';
      const errorMessage = '[503][https://webview.test/api/failed-request]';
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController(resourceUrl);
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.sendEvent(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_RESOURCE,
        new WebViewResourceTags(webViewId, webViewName, resourceUrl, resourceStatus),
        new WebViewResourceFields(123),
        'webview_resource_error_resource'
      ));
      handler.sendEvent(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_ERROR,
        new WebViewNetworkErrorTags(webViewId, webViewName, resourceUrl, resourceStatus),
        new WebViewNetworkErrorFields(errorMessage),
        'webview_resource_error_error'
      ));

      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, [
        'resource,',
        `view_id=${webViewId}`,
        `resource_url=${resourceUrl}`,
        `resource_status=${resourceStatus}`
      ], 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, [
        'error,',
        `view_id=${webViewId}`,
        'error_source=network',
        errorMessage
      ], 5000);
      const resourceLine = resourceRecord?.getDataString() ?? '';
      const errorLine = errorRecord?.getDataString() ?? '';
      const resourceId = getLineProtocolTag(resourceLine, 'resource_id');
      const resourceDataId = getLineProtocolTag(resourceLine, 'sdk_data_id');
      const errorResourceId = getLineProtocolTag(errorLine, 'resource_id');
      const errorDataId = getLineProtocolTag(errorLine, 'sdk_data_id');

      expect(resourceRecord !== null).assertTrue();
      expect(errorRecord !== null).assertTrue();
      expect(resourceId.length > 0).assertTrue();
      expect(/^[0-9a-f]{32}$/.test(resourceId)).assertTrue();
      expect(resourceId).assertEqual(resourceDataId);
      expect(errorResourceId).assertEqual(resourceId);
      expect(errorDataId !== resourceId).assertTrue();
    });

    it('webViewProxyShouldForwardCallback', 0, async () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/proxy/path');
      const proxy = handler.getJavaScriptProxy(fakeController as Object as webview.WebviewController);
      const receiver = proxy.object as Object as WebViewProxyReceiver;
      const webViewId = 'proxy_webview_view_id';
      const webViewName = 'proxy_webview_home';

      receiver.sendEvent(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_VIEW,
        new WebViewViewTags(webViewId, webViewName),
        new WebViewViewFields(321, 654),
        'proxy_webview_event'
      ));
      receiver.sendEventWithCallback(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_VIEW,
        new WebViewViewTags('proxy_callback_view_id', 'proxy_callback_view'),
        new WebViewViewFields(111, 222),
        'proxy_callback_event'
      ), 'FTCallback');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, [
        'view,',
        `view_id=${webViewId}`,
        `view_name=${webViewName}`,
        'is_web_view=true'
      ], 5000);

      expect(receiver.getAllowedWebViewHosts() === null).assertTrue();
      expect(record !== null).assertTrue();
      expect(fakeController.runCount > 0).assertTrue();
      expect(fakeController.lastScript.includes('FTCallback["proxy_callback_event"]')).assertTrue();
      expect(fakeController.lastScript.includes('"status":true')).assertTrue();
    });

    it('legacyWebViewShouldProcessCallback', 0, async () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/legacy/callback');
      const webActionId = `legacy_webview_action_${Date.now()}`;
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.handleWebViewData(buildLegacyWebViewEvent(buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_ACTION,
        new WebViewActionTags('legacy_view_id', 'legacy_view', 'legacy_webview_tap', 'click'),
        new WebViewActionFields(webActionId, 987),
        'legacy_callback_tag'
      ), 'LegacyCallback'));

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, [
        'action,',
        'view_id=legacy_view_id',
        'view_name=legacy_view',
        'action_name=legacy_webview_tap',
        webActionId
      ], 5000);

      expect(record !== null).assertTrue();
      expect(fakeController.runCount > 0).assertTrue();
      expect(fakeController.lastScript.includes('LegacyCallback["legacy_callback_tag"]')).assertTrue();
    });

    it('duplicateWebViewShouldWriteOnce', 0, async () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/action/duplicate');
      const webActionId = `duplicate_webview_action_${Date.now()}`;
      const event = buildWebViewRumEvent(
        Constants.FT_MEASUREMENT_RUM_ACTION,
        new WebViewActionTags('duplicate_view_id', 'duplicate_view', 'duplicate_webview_tap', 'click'),
        new WebViewActionFields(webActionId, 456),
        'duplicate_action_event'
      );
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.sendEvent(event);
      handler.sendEvent(event);

      const fragments = [
        'action,',
        'view_id=duplicate_view_id',
        'view_name=duplicate_view',
        'action_name=duplicate_webview_tap',
        webActionId
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_WEBVIEW, fragments, 5000);
      await WaitUtils.delay(500);

      expect(record !== null).assertTrue();
      expect(await countWebViewSyncRecordsContaining(fragments)).assertEqual(1);
    });

    it('invalidWebViewShouldWriteNothing', 0, async () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/non-rum');
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.sendEventWithCallback(buildSimpleWebViewEvent('track', 'track_tag'), null);
      handler.sendEventWithCallback(buildSimpleWebViewEvent('log', 'log_tag'), null);
      handler.sendEventWithCallback(buildSimpleWebViewEvent('urlVerify', 'url_tag'), null);
      handler.sendEventWithCallback(buildSimpleWebViewEvent('unknown', 'unknown_tag'), null);
      handler.sendEventWithCallback('not-json', null);
      handler.handleWebViewData('not-json');
      await WaitUtils.delay(500);

      expect(await DBAssert.querySyncCount([DataType.RUM_WEBVIEW])).assertEqual(0);
    });

    it('webViewHandlerShouldRunJavaScript', 0, () => {
      const handler = new FTWebViewHandler();
      const fakeController = new FakeWebviewController('https://webview.test/post-message');
      handler.setWebView(fakeController as Object as webview.WebviewController, rumConfig);

      handler.postMessageToWeb('native-message');
      expect(fakeController.runCount).assertEqual(1);
      expect(fakeController.lastScript.includes('nativeMessageHandler')).assertTrue();
      expect(fakeController.lastScript.includes('native-message')).assertTrue();

      handler.addEventListener('ready', 'ReadyCallback');
      expect(fakeController.runCount).assertEqual(2);
      expect(fakeController.lastScript.includes('ReadyCallback')).assertTrue();

      handler.clearWebController();
      handler.postMessageToWeb('after-clear');
      expect(fakeController.runCount).assertEqual(2);
    });
  });
}
