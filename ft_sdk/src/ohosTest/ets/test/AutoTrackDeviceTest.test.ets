import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FrameNode, UIContext, UIObserver, uiObserver } from '@kit.ArkUI';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { FTActionTracker } from '../../../main/ets/components/rum/FTActionTracker';
import { FTNavigationTracker } from '../../../main/ets/components/rum/FTNavigationTracker';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { ActionEventWrapper } from '../../../main/ets/components/rum/bean/ActionEventWrapper';
import { HandlerAction } from '../../../main/ets/components/rum/bean/HandlerAction';
import { HandlerView } from '../../../main/ets/components/rum/bean/HandlerView';
import { FTActionTrackingHandler } from '../../../main/ets/components/rum/handler/FTActionTrackingHandler';
import { FTViewNavigationTrackingHandler } from '../../../main/ets/components/rum/handler/FTViewNavigationTrackingHandler';
import { FTViewRouterTrackingHandler } from '../../../main/ets/components/rum/handler/FTViewRouterTrackingHandler';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_HOST = 'http://127.0.0.1:9529';
const TEST_FAKE_RUM_ID = 'rumId';

type RouterPageCallback = (info: uiObserver.RouterPageInfo) => void | Promise<void>;
type NavDestinationSwitchCallback = (info: uiObserver.NavDestinationSwitchInfo) => void | Promise<void>;
type WillClickCallback = (event: Object, node?: FrameNode) => void | Promise<void>;

class FakeRouterPageInfo {
  name: string;
  state: number;

  constructor(name: string, state: number) {
    this.name = name;
    this.state = state;
  }
}

class FakeNavDestinationInfo {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class FakeNavDestinationSwitchInfo {
  from: FakeNavDestinationInfo | 'navBar' | undefined;
  to: FakeNavDestinationInfo | 'navBar' | undefined;

  constructor(from: FakeNavDestinationInfo | 'navBar' | undefined, to: FakeNavDestinationInfo | 'navBar' | undefined) {
    this.from = from;
    this.to = to;
  }
}

class EmptyClickEvent {
}

class ActionPropertyWrapper {
  value: string;

  constructor(value: string) {
    this.value = value;
  }
}

class FakeFrameNode {
  private nodeType: string;
  private nodeId: string;
  private uniqueId: number;
  private customProperties: Map<string, Object> = new Map();
  private inspectorAttributes: Record<string, Object> = {};
  private parent: FakeFrameNode | null = null;
  private previousSibling: FakeFrameNode | null = null;

  constructor(nodeType: string, nodeId: string, uniqueId: number) {
    this.nodeType = nodeType;
    this.nodeId = nodeId;
    this.uniqueId = uniqueId;
  }

  getNodeType(): string {
    return this.nodeType;
  }

  getId(): string {
    return this.nodeId;
  }

  getUniqueId(): number {
    return this.uniqueId;
  }

  setCustomProperty(key: string, value: Object): void {
    this.customProperties.set(key, value);
  }

  getCustomProperty(key: string): Object {
    return this.customProperties.get(key) || '';
  }

  setInspectorAttribute(key: string, value: Object): FakeFrameNode {
    this.inspectorAttributes[key] = value;
    return this;
  }

  getInspectorInfo(): Object {
    return { '$attrs': this.inspectorAttributes } as Object;
  }

  setParent(parent: FakeFrameNode): FakeFrameNode {
    this.parent = parent;
    return this;
  }

  getParent(): FrameNode | null {
    return this.parent as Object as FrameNode | null;
  }

  setPreviousSibling(previousSibling: FakeFrameNode): FakeFrameNode {
    this.previousSibling = previousSibling;
    return this;
  }

  getPreviousSibling(): FrameNode | null {
    return this.previousSibling as Object as FrameNode | null;
  }
}

class FakeUIObserver {
  private routerPageUpdateCallback: RouterPageCallback | null = null;
  private navDestinationSwitchCallback: NavDestinationSwitchCallback | null = null;
  private willClickCallback: WillClickCallback | null = null;

  on(eventName: string, callback: Object): void {
    if (eventName === 'routerPageUpdate') {
      this.routerPageUpdateCallback = callback as Object as RouterPageCallback;
      return;
    }
    if (eventName === 'navDestinationSwitch') {
      this.navDestinationSwitchCallback = callback as Object as NavDestinationSwitchCallback;
      return;
    }
    if (eventName === 'willClick') {
      this.willClickCallback = callback as Object as WillClickCallback;
    }
  }

  hasRouterPageUpdateCallback(): boolean {
    return this.routerPageUpdateCallback !== null;
  }

  hasNavDestinationSwitchCallback(): boolean {
    return this.navDestinationSwitchCallback !== null;
  }

  hasWillClickCallback(): boolean {
    return this.willClickCallback !== null;
  }

  async emitRouterPageUpdate(name: string, state: number): Promise<void> {
    if (!this.routerPageUpdateCallback) {
      return;
    }
    const info = new FakeRouterPageInfo(name, state);
    const result = this.routerPageUpdateCallback(info as Object as uiObserver.RouterPageInfo);
    if (result instanceof Promise) {
      await result;
    }
  }

  async emitNavDestinationSwitch(fromName: string, toName: string): Promise<void> {
    if (!this.navDestinationSwitchCallback) {
      return;
    }
    const info = new FakeNavDestinationSwitchInfo(new FakeNavDestinationInfo(fromName), new FakeNavDestinationInfo(toName));
    const result = this.navDestinationSwitchCallback(info as Object as uiObserver.NavDestinationSwitchInfo);
    if (result instanceof Promise) {
      await result;
    }
  }

  async emitWillClick(node: FakeFrameNode): Promise<void> {
    if (!this.willClickCallback) {
      return;
    }
    const result = this.willClickCallback(new EmptyClickEvent(), node as Object as FrameNode);
    if (result instanceof Promise) {
      await result;
    }
  }
}

class FakeUIContext {
  observer: FakeUIObserver = new FakeUIObserver();

  getUIObserver(): UIObserver {
    return this.observer as Object as UIObserver;
  }
}

class HandlerActionTrackingHandler implements FTActionTrackingHandler {
  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): HandlerAction | null {
    const source = actionEventWrapper.getSource();
    if (!source || source.getId() !== 'handler_button') {
      return null;
    }
    const property: Record<string, object> = {};
    property['handler_property'] = new ActionPropertyWrapper('handler_value');
    return new HandlerAction('handler_action_name', property);
  }
}

class FilteringRouterTrackingHandler implements FTViewRouterTrackingHandler {
  public resolvedRouteNames: string[] = [];

  resolveHandlerView(routeName: string): HandlerView | null {
    this.resolvedRouteNames.push(routeName);
    if (routeName === 'IgnoredRouterPage') {
      return null;
    }
    const property: Record<string, object> = {};
    property['view_handler_source'] = new ActionPropertyWrapper('router');
    return new HandlerView(`custom_router_${routeName}`, property);
  }
}

class FilteringNavigationTrackingHandler implements FTViewNavigationTrackingHandler {
  public resolvedDestinationNames: string[] = [];

  resolveHandlerView(destinationName: string): HandlerView | null {
    this.resolvedDestinationNames.push(destinationName);
    if (destinationName === 'IgnoredNavigationDestination') {
      return null;
    }
    const property: Record<string, object> = {};
    property['view_handler_source'] = new ActionPropertyWrapper('navigation');
    return new HandlerView(`custom_navigation_${destinationName}`, property);
  }
}

class EmptyViewNameNavigationTrackingHandler implements FTViewNavigationTrackingHandler {
  resolveHandlerView(_destinationName: string): HandlerView | null {
    return new HandlerView('   ');
  }
}

function buildSdkConfig(): FTSDKConfig {
  return FTSDKConfig.builder(TEST_HOST)
    .setDebug(true)
    .setAutoSync(false)
    .setEnv(EnvType.GRAY);
}

function buildRumConfig(
  enableView: boolean = true,
  enableAction: boolean = true,
  handler: FTActionTrackingHandler | null = null
): FTRUMConfig {
  return new FTRUMConfig()
    .setRumAppId(TEST_FAKE_RUM_ID)
    .setEnableTraceUserView(enableView)
    .setEnableTraceUserAction(enableAction)
    .setActionTrackingHandler(handler);
}

function initializeAutoTrack(context: Context, uiContext: FakeUIContext, rumConfig: FTRUMConfig): void {
  FTSDK.install(buildSdkConfig(), context);
  FTSDK.installRUMConfig(rumConfig);
  FTActionTracker.getInstance().destroy();
  FTNavigationTracker.getInstance().destroy();
  FTActionTracker.getInstance().init(uiContext as Object as UIContext, rumConfig);
  FTNavigationTracker.getInstance().init(uiContext as Object as UIContext, rumConfig);
}

function containsAll(value: string, fragments: string[]): boolean {
  for (let i = 0; i < fragments.length; i++) {
    if (!value.includes(fragments[i])) {
      return false;
    }
  }
  return true;
}

async function flushAndAssertPayload(collector: MockCollector, fragments: string[]): Promise<void> {
  const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 8000);
  expect(record !== null).assertTrue();
  expect(containsAll(record?.getDataString() ?? '', fragments)).assertTrue();

  collector.clearRequests();
  FTSDK.flushSyncData();

  const uploaded = await collector.waitForPayloadContaining(fragments, 8000);
  const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 8000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
}

async function closeCurrentViewAndWaitForRum(): Promise<void> {
  await WaitUtils.delay(800);
  await FTRUMGlobalManager.getInstance().stopView();
  await WaitUtils.delay(1200);
}

async function startViewForAction(viewName: string): Promise<void> {
  await FTRUMGlobalManager.getInstance().startView(viewName);
  await WaitUtils.delay(300);
}

async function assertActionStarted(actionName: string): Promise<void> {
  const action = await DBAssert.waitForActionNamed(actionName, 8000);
  expect(action !== null).assertTrue();
}

export default function autoTrackDeviceTest() {
  describe('AutoTrackDeviceTest', () => {
    let context: Context;
    let collector: MockCollector;
    let uiContext: FakeUIContext;

    beforeEach(async () => {
      FTActionTracker.getInstance().destroy();
      FTNavigationTracker.getInstance().destroy();
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      collector = new MockCollector(200, '');
      collector.start();
      uiContext = new FakeUIContext();
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      FTActionTracker.getInstance().destroy();
      FTNavigationTracker.getInstance().destroy();
      collector.stop();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
    });

    it('routerPageShouldUploadViewWithAndroidAlignedSimpleName', 0, async () => {
      const routeName = 'pages/account/AutoTrackRouterPage';
      const normalizedViewName = 'AutoTrackRouterPage';
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      expect(uiContext.observer.hasRouterPageUpdateCallback()).assertTrue();

      await uiContext.observer.emitRouterPageUpdate(routeName, 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate(routeName, 2);
      await WaitUtils.delay(300);

      const view = await DBAssert.waitForViewNamed(normalizedViewName, 5000);
      expect(view !== null).assertTrue();
      expect(view?.getViewName() ?? '').assertEqual(normalizedViewName);
      expect((view?.getViewLoadTime() ?? 0) > 0).assertTrue();

      await closeCurrentViewAndWaitForRum();
      await flushAndAssertPayload(collector, [
        'view,',
        `view_name=${normalizedViewName}`,
        'loading_time='
      ]);
    });

    it('routerPageDisabledShouldWriteNothing', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(false, false));

      await uiContext.observer.emitRouterPageUpdate('pages/DisabledAutoTrackPage', 0);
      await uiContext.observer.emitRouterPageUpdate('pages/DisabledAutoTrackPage', 2);
      await WaitUtils.delay(500);

      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('routerHandlerShouldCustomizeAndFilterAutomaticViews', 0, async () => {
      const handler = new FilteringRouterTrackingHandler();
      const rumConfig = buildRumConfig(true, false).setViewRouterTrackingHandler(handler);
      const routeName = 'pages/account/HandledRouterPage';
      const viewName = 'custom_router_HandledRouterPage';
      initializeAutoTrack(context, uiContext, rumConfig);

      await uiContext.observer.emitRouterPageUpdate(routeName, 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate(routeName, 2);
      await WaitUtils.delay(300);

      expect(handler.resolvedRouteNames.length).assertEqual(1);
      expect(handler.resolvedRouteNames[0]).assertEqual('HandledRouterPage');
      await closeCurrentViewAndWaitForRum();
      await flushAndAssertPayload(collector, [
        'view,',
        `view_name=${viewName}`,
        'view_handler_source='
      ]);

      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      const filteredHandler = new FilteringRouterTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewRouterTrackingHandler(filteredHandler));
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredRouterPage', 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredRouterPage', 2);
      await WaitUtils.delay(500);

      expect(filteredHandler.resolvedRouteNames.length).assertEqual(1);
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('navDestinationShouldUploadViewWithAndroidAlignedSimpleName', 0, async () => {
      const routeName = 'pages/account/AutoTrackNavDestination';
      const normalizedViewName = 'AutoTrackNavDestination';
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      expect(uiContext.observer.hasNavDestinationSwitchCallback()).assertTrue();

      await uiContext.observer.emitNavDestinationSwitch('pages/AutoTrackNavSource', routeName);
      await WaitUtils.delay(300);

      const view = await DBAssert.waitForViewNamed(normalizedViewName, 5000);
      expect(view !== null).assertTrue();
      expect(view?.getViewName() ?? '').assertEqual(normalizedViewName);

      await closeCurrentViewAndWaitForRum();
      await flushAndAssertPayload(collector, [
        'view,',
        `view_name=${normalizedViewName}`
      ]);
    });

    it('navDisabledShouldWriteNothing', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(false, false));

      await uiContext.observer.emitNavDestinationSwitch('pages/DisabledNavSource', 'pages/DisabledNavDestination');
      await WaitUtils.delay(500);

      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('navigationSwitchShouldNotSuppressRouterView', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/NavigationDestination');
      await uiContext.observer.emitRouterPageUpdate('pages/RouterDestination', 0);
      await uiContext.observer.emitRouterPageUpdate('pages/RouterDestination', 2);
      await WaitUtils.delay(300);

      const view = await DBAssert.waitForViewNamed('RouterDestination', 5000);
      expect(view !== null).assertTrue();
      expect(view?.getViewName() ?? '').assertEqual('RouterDestination');
    });

    it('navigationHandlerShouldCustomizeAndFilterAutomaticViews', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      const rumConfig = buildRumConfig(true, false).setViewNavigationTrackingHandler(handler);
      const destinationName = 'pages/account/HandledNavigationDestination';
      const viewName = 'custom_navigation_HandledNavigationDestination';
      initializeAutoTrack(context, uiContext, rumConfig);

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', destinationName);
      await WaitUtils.delay(300);

      expect(handler.resolvedDestinationNames.length).assertEqual(1);
      expect(handler.resolvedDestinationNames[0]).assertEqual('HandledNavigationDestination');
      await closeCurrentViewAndWaitForRum();
      await flushAndAssertPayload(collector, [
        'view,',
        `view_name=${viewName}`,
        'view_handler_source='
      ]);

      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      const filteredHandler = new FilteringNavigationTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewNavigationTrackingHandler(filteredHandler));
      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/IgnoredNavigationDestination');
      await WaitUtils.delay(500);

      expect(filteredHandler.resolvedDestinationNames.length).assertEqual(1);
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('navigationHandlerEmptyViewNameShouldSkipAutomaticView', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewNavigationTrackingHandler(new EmptyViewNameNavigationTrackingHandler()));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/BlankNavigationDestination');
      await WaitUtils.delay(300);

      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('filteredDestinationShouldCloseThePreviousAutomaticView', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewNavigationTrackingHandler(handler));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/TrackedNavigationDestination');
      await WaitUtils.delay(120);
      await uiContext.observer.emitNavDestinationSwitch('pages/TrackedNavigationDestination', 'pages/IgnoredNavigationDestination');

      const previousView = await DBAssert.waitForViewNamed('custom_navigation_TrackedNavigationDestination', 5000);
      expect(previousView !== null).assertTrue();
      const views = await DBAssert.queryViews(20);
      expect(views.length).assertEqual(1);
      expect(views[0].getViewName()).assertEqual('custom_navigation_TrackedNavigationDestination');
    });

    it('filteredNavigationShouldNotBlockSameNamedRouterView', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewNavigationTrackingHandler(handler));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/IgnoredNavigationDestination');
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredNavigationDestination', 0);
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredNavigationDestination', 2);
      await WaitUtils.delay(300);

      const view = await DBAssert.waitForViewNamed('IgnoredNavigationDestination', 5000);
      expect(view !== null).assertTrue();
      expect(view?.getViewName() ?? '').assertEqual('IgnoredNavigationDestination');
    });

    it('willClickShouldUploadAction', 0, async () => {
      const viewName = 'auto_action_view';
      const actionName = 'Button/登录#auto_action_button';
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true));
      expect(uiContext.observer.hasWillClickCallback()).assertTrue();
      await startViewForAction(viewName);

      const button = new FakeFrameNode('Button', 'auto_action_button', 1001)
        .setInspectorAttribute('label', '登录');
      await uiContext.observer.emitWillClick(button);
      await assertActionStarted(actionName);
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        `action_name=${actionName}`,
        `view_name=${viewName}`,
        `action_type=${Constants.EVENT_NAME_CLICK}`
      ]);
    });

    it('willClickShouldAppendListItemPosition', 0, async () => {
      const viewName = 'list_item_action_view';
      const actionName = 'Button/商品#item_action#position:1';
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true));
      await startViewForAction(viewName);

      const firstItem = new FakeFrameNode('ListItem', 'first_item', 1101);
      const secondItem = new FakeFrameNode('ListItem', 'second_item', 1102)
        .setPreviousSibling(firstItem);
      const button = new FakeFrameNode('Button', 'item_action', 1103)
        .setInspectorAttribute('label', '商品')
        .setParent(secondItem);

      await uiContext.observer.emitWillClick(button);
      await assertActionStarted(actionName);
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        `action_name=${actionName}`,
        `view_name=${viewName}`
      ]);
    });

    it('willClickShouldAppendTabPosition', 0, async () => {
      const viewName = 'tab_action_view';
      const actionName = 'Button/设置#tab_action#position:1';
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true));
      await startViewForAction(viewName);

      const firstTab = new FakeFrameNode('TabContent', 'first_tab', 1201);
      const secondTab = new FakeFrameNode('TabContent', 'second_tab', 1202)
        .setPreviousSibling(firstTab);
      const button = new FakeFrameNode('Button', 'tab_action', 1203)
        .setInspectorAttribute('label', '设置')
        .setParent(secondTab);

      await uiContext.observer.emitWillClick(button);
      await assertActionStarted(actionName);
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        `action_name=${actionName}`,
        `view_name=${viewName}`
      ]);
    });

    it('willClickShouldUseCustomHandler', 0, async () => {
      const viewName = 'handler_action_view';
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true, new HandlerActionTrackingHandler()));
      expect(uiContext.observer.hasWillClickCallback()).assertTrue();
      await startViewForAction(viewName);

      await uiContext.observer.emitWillClick(new FakeFrameNode('Button', 'handler_button', 1002));
      await assertActionStarted('handler_action_name');
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        'action_name=handler_action_name',
        `view_name=${viewName}`,
        'handler_property='
      ]);
    });
  });
}
