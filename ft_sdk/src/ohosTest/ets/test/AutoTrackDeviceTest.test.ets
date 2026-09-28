import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FrameNode, UIContext, UIObserver, uiObserver } from '@kit.ArkUI';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { FTDBTaskPoolExecutor } from '../../../main/ets/components/db/FTDBTaskPoolExecutor';
import { ViewBean } from '../../../main/ets/components/db/bean/ViewBean';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { FTActionTracker } from '../../../main/ets/components/rum/FTActionTracker';
import { FTNavigationTracker } from '../../../main/ets/components/rum/FTNavigationTracker';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTRUMInnerManager } from '../../../main/ets/components/rum/FTRUMInnerManager';
import { ActionEventWrapper } from '../../../main/ets/components/rum/bean/ActionEventWrapper';
import { HandlerAction } from '../../../main/ets/components/rum/bean/HandlerAction';
import { HandlerView } from '../../../main/ets/components/rum/bean/HandlerView';
import { FTActionTrackingHandler } from '../../../main/ets/components/rum/handler/FTActionTrackingHandler';
import { FTViewTrackingContext } from '../../../main/ets/components/rum/handler/FTViewTrackingContext';
import { FTViewTrackingHandler } from '../../../main/ets/components/rum/handler/FTViewTrackingHandler';
import { FTViewTrackingType } from '../../../main/ets/components/rum/enum/FTViewTrackingType';
import { Utils } from '../../../main/ets/components/utils/Utils';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';
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
  pageId: string;
  index: number;
  path: string;

  constructor(name: string, state: number, pageId: string, index: number) {
    this.name = name;
    this.state = state;
    this.pageId = pageId;
    this.index = index;
    this.path = name;
  }
}

class FakeNavDestinationInfo {
  name: string;
  navDestinationId: string;
  navigationId: string = 'test-navigation';
  index: number = 1;

  constructor(name: string, navDestinationId: string) {
    this.name = name;
    this.navDestinationId = navDestinationId;
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

interface FakeInspectorInfo {
  $attrs: Record<string, Object>;
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
    const info: FakeInspectorInfo = { $attrs: this.inspectorAttributes };
    return info;
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
  private routerPageUpdateCallbacks: RouterPageCallback[] = [];
  private navDestinationSwitchCallbacks: NavDestinationSwitchCallback[] = [];
  private willClickCallbacks: WillClickCallback[] = [];

  on(eventName: string, callback: Object): void {
    if (eventName === 'routerPageUpdate') {
      this.routerPageUpdateCallbacks.push(callback as Object as RouterPageCallback);
      return;
    }
    if (eventName === 'navDestinationSwitch') {
      this.navDestinationSwitchCallbacks.push(callback as Object as NavDestinationSwitchCallback);
      return;
    }
    if (eventName === 'willClick') {
      this.willClickCallbacks.push(callback as Object as WillClickCallback);
    }
  }

  off(eventName: string, callback?: Object): void {
    if (eventName === 'routerPageUpdate') {
      this.routerPageUpdateCallbacks = this.routerPageUpdateCallbacks.filter((registered: RouterPageCallback) => {
        return callback !== undefined && registered !== callback;
      });
    }
    if (eventName === 'navDestinationSwitch') {
      this.navDestinationSwitchCallbacks = this.navDestinationSwitchCallbacks.filter((registered: NavDestinationSwitchCallback) => {
        return callback !== undefined && registered !== callback;
      });
    }
    if (eventName === 'willClick') {
      this.willClickCallbacks = this.willClickCallbacks.filter((registered: WillClickCallback) => {
        return callback !== undefined && registered !== callback;
      });
    }
  }

  getRouterPageUpdateCallbackCount(): number {
    return this.routerPageUpdateCallbacks.length;
  }

  getNavDestinationSwitchCallbackCount(): number {
    return this.navDestinationSwitchCallbacks.length;
  }

  getWillClickCallbackCount(): number {
    return this.willClickCallbacks.length;
  }

  hasRouterPageUpdateCallback(): boolean {
    return this.routerPageUpdateCallbacks.length > 0;
  }

  hasNavDestinationSwitchCallback(): boolean {
    return this.navDestinationSwitchCallbacks.length > 0;
  }

  hasWillClickCallback(): boolean {
    return this.willClickCallbacks.length > 0;
  }

  async emitRouterPageUpdate(name: string, state: number, pageId: string = name, index: number = 1): Promise<void> {
    const info = new FakeRouterPageInfo(name, state, pageId, index);
    for (const callback of this.routerPageUpdateCallbacks.slice()) {
      await callback(info as Object as uiObserver.RouterPageInfo);
    }
  }

  async emitNavDestinationSwitch(fromName: string, toName: string, toId: string = toName): Promise<void> {
    const info = new FakeNavDestinationSwitchInfo(new FakeNavDestinationInfo(fromName, fromName),
      new FakeNavDestinationInfo(toName, toId));
    for (const callback of this.navDestinationSwitchCallbacks.slice()) {
      await callback(info as Object as uiObserver.NavDestinationSwitchInfo);
    }
  }

  async emitWillClick(node: FakeFrameNode): Promise<void> {
    for (const callback of this.willClickCallbacks.slice()) {
      await callback(new EmptyClickEvent(), node as Object as FrameNode);
    }
  }
}

class FakeUIContext {
  observer: FakeUIObserver = new FakeUIObserver();
  currentRouterName: string = '';

  getUIObserver(): UIObserver {
    return this.observer as Object as UIObserver;
  }

  getRouter(): Object {
    return new FakeRouter(this.currentRouterName);
  }
}

class FakeRouterState {
  index: number = 1;
  name: string;
  path: string;

  constructor(path: string) {
    // HarmonyOS RouterState separates the directory path from the page name.
    // For pages/Index, getState() can return path='pages', name='Index'.
    const lastSeparator = path.lastIndexOf('/');
    this.path = lastSeparator >= 0 ? path.substring(0, lastSeparator) : '';
    this.name = path.substring(lastSeparator + 1);
  }
}

class FakeRouter {
  private path: string;

  constructor(path: string) {
    this.path = path;
  }

  getState(): FakeRouterState {
    return new FakeRouterState(this.path);
  }
}

class FilteringActionTrackingHandler implements FTActionTrackingHandler {
  public resolvedCount: number = 0;

  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): null | undefined {
    this.resolvedCount++;
    const source = actionEventWrapper.getSource();
    if (source?.getId() === 'ignore_action_view') {
      return null;
    }
    return undefined;
  }
}

class PassThroughActionTrackingHandler implements FTActionTrackingHandler {
  public resolvedCount: number = 0;

  resolveHandlerAction(_actionEventWrapper: ActionEventWrapper): null | undefined {
    this.resolvedCount += 1;
    return undefined;
  }
}

class CustomizingActionTrackingHandler implements FTActionTrackingHandler {
  public observedExtra: Record<string, object> | null = null;

  resolveHandlerAction(actionEventWrapper: ActionEventWrapper): HandlerAction | undefined {
    if (actionEventWrapper.getSource()?.getId() === 'custom_action_view') {
      this.observedExtra = actionEventWrapper.getExtra();
      const properties: Record<string, object> = {};
      properties['handler_property'] = new ActionPropertyWrapper('handler_value');
      properties['shared_property'] = new ActionPropertyWrapper('handler_wins');
      return new HandlerAction('custom_action_name', properties);
    }
    return undefined;
  }
}

class FilteringRouterTrackingHandler implements FTViewTrackingHandler {
  public resolvedRouteNames: string[] = [];

  resolveHandlerView(context: FTViewTrackingContext): HandlerView | null {
    const routeName = context.viewName;
    this.resolvedRouteNames.push(routeName);
    if (routeName === 'IgnoredRouterPage') {
      return null;
    }
    const property: Record<string, object> = {};
    property['view_handler_source'] = new ActionPropertyWrapper('router');
    return new HandlerView(`custom_router_${routeName}`, property);
  }
}

class FilteringNavigationTrackingHandler implements FTViewTrackingHandler {
  public resolvedDestinationNames: string[] = [];

  resolveHandlerView(context: FTViewTrackingContext): HandlerView | null {
    const destinationName = context.viewName;
    this.resolvedDestinationNames.push(destinationName);
    if (destinationName === 'IgnoredNavigationDestination') {
      return null;
    }
    const property: Record<string, object> = {};
    property['view_handler_source'] = new ActionPropertyWrapper('navigation');
    return new HandlerView(`custom_navigation_${destinationName}`, property);
  }
}

class MutableViewTrackingHandler implements FTViewTrackingHandler {
  public role: string = 'guest';
  public enabled: boolean = true;
  public resolvedCount: number = 0;

  resolveHandlerView(context: FTViewTrackingContext): HandlerView | null {
    this.resolvedCount++;
    if (!this.enabled) {
      return null;
    }
    const property: Record<string, object> = {};
    property['user_type'] = new ActionPropertyWrapper(this.role);
    return new HandlerView(`${context.viewName}_${this.role}`, property);
  }
}

class EmptyViewNameNavigationTrackingHandler implements FTViewTrackingHandler {
  resolveHandlerView(_context: FTViewTrackingContext): HandlerView | null {
    return new HandlerView('   ');
  }
}

class ContextFilteringViewTrackingHandler implements FTViewTrackingHandler {
  public contexts: FTViewTrackingContext[] = [];

  resolveHandlerView(context: FTViewTrackingContext): HandlerView | null {
    this.contexts.push(context);
    if (context.trackingType === FTViewTrackingType.ROUTER) {
      if (context.routerPageInfo.name.startsWith('pages/private/')) {
        return null;
      }
    }
    if (context.trackingType === FTViewTrackingType.NAVIGATION) {
      const from: uiObserver.NavDestinationInfo | 'navBar' | undefined = context.navigationInfo.from;
      if (from !== undefined && typeof from !== 'string' && typeof from.name === 'string' &&
        from.name === 'pages/Checkout') {
        return null;
      }
    }
    return new HandlerView(`context_${context.viewName}`);
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
      await runTestCleanup([
        () => { FTActionTracker.getInstance().destroy(); },
        () => { FTNavigationTracker.getInstance().destroy(); },
        async () => { await collector.stop(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await DBAssert.cleanupAll(); }
      ]);
    });

    it('autoTrackDestroyRemoveOnlySdkCallbacks', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, true));
      let appRouterCallbackCount = 0;
      let appNavigationCallbackCount = 0;
      let appClickCallbackCount = 0;
      uiContext.observer.on('routerPageUpdate', (_info: uiObserver.RouterPageInfo): void => {
        appRouterCallbackCount++;
      });
      uiContext.observer.on('navDestinationSwitch', (_info: uiObserver.NavDestinationSwitchInfo): void => {
        appNavigationCallbackCount++;
      });
      uiContext.observer.on('willClick', (_event: Object, _node?: FrameNode): void => {
        appClickCallbackCount++;
      });
      expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(2);
      expect(uiContext.observer.getNavDestinationSwitchCallbackCount()).assertEqual(2);
      expect(uiContext.observer.getWillClickCallbackCount()).assertEqual(2);

      FTNavigationTracker.getInstance().destroy();
      FTNavigationTracker.getInstance().destroy();
      FTActionTracker.getInstance().destroy();
      FTActionTracker.getInstance().destroy();
      expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(1);
      expect(uiContext.observer.getNavDestinationSwitchCallbackCount()).assertEqual(1);
      expect(uiContext.observer.getWillClickCallbackCount()).assertEqual(1);
      await uiContext.observer.emitRouterPageUpdate('pages/AppRouterPage', 0);
      await uiContext.observer.emitNavDestinationSwitch('pages/AppSource', 'pages/AppDestination');
      await uiContext.observer.emitWillClick(new FakeFrameNode('Button', 'app_button', 9001));
      expect(appRouterCallbackCount).assertEqual(1);
      expect(appNavigationCallbackCount).assertEqual(1);
      expect(appClickCallbackCount).assertEqual(1);
    });

    it('navigationReinitNotDuplicateObservers', 0, async () => {
      const routerHandler = new FilteringRouterTrackingHandler();
      const navigationHandler = new FilteringNavigationTrackingHandler();
      const rumConfig = buildRumConfig(true, false)
        .setViewTrackingHandler(routerHandler, FTViewTrackingType.ROUTER)
        .setViewTrackingHandler(navigationHandler, FTViewTrackingType.NAVIGATION);
      initializeAutoTrack(context, uiContext, rumConfig);
      for (let i = 0; i < 2; i++) {
        FTNavigationTracker.getInstance().destroy();
        expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(0);
        expect(uiContext.observer.getNavDestinationSwitchCallbackCount()).assertEqual(0);
        FTNavigationTracker.getInstance().init(uiContext as Object as UIContext, rumConfig);
      }
      expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(1);
      expect(uiContext.observer.getNavDestinationSwitchCallbackCount()).assertEqual(1);
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredRouterPage', 0);
      await uiContext.observer.emitNavDestinationSwitch('pages/Source', 'pages/IgnoredNavigationDestination');
      expect(routerHandler.resolvedRouteNames.length).assertEqual(1);
      expect(navigationHandler.resolvedDestinationNames.length).assertEqual(1);
    });

    it('lateObserverRestoresAlreadyShownIndexView', 0, async () => {
      uiContext.currentRouterName = 'pages/Index';
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));

      const view = await DBAssert.waitForViewNamed('Index', 8000);
      expect(view !== null).assertTrue();
      expect(view?.getIsClose()).assertFalse();
      const firstId = view?.getId() ?? '';

      await uiContext.observer.emitRouterPageUpdate('pages/Index', 2);
      const activeView = FTRUMInnerManager.getInstance().getActiveView();
      expect(activeView?.getId()).assertEqual(firstId);
    });

    it('backfilledIndexDoesNotSuppressNewSameNamedPage', 0, async () => {
      uiContext.currentRouterName = 'pages/Index';
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      expect((await DBAssert.waitForViewNamed('Index', 8000)) !== null).assertTrue();
      const first = FTRUMInnerManager.getInstance().getActiveView();

      await uiContext.observer.emitRouterPageUpdate('pages/Index', 0, 'second-index', 2);
      await uiContext.observer.emitRouterPageUpdate('pages/Index', 2, 'second-index', 2);
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.isClose()).assertTrue();
      expect(second?.getViewName()).assertEqual('Index');
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('rerunSerializesPredecessorIndexWithoutNewPageEvent', 0, async () => {
      const predecessor = new ViewBean('Index', 'root', Utils.getCurrentNanoTime());
      await FTDBTaskPoolExecutor.upsertRumView(context, predecessor);
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));

      const persisted = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_id=${predecessor.getId()}`, 'is_active=false'], 8000);
      expect(persisted !== null).assertTrue();
      expect(FTRUMInnerManager.getInstance().getActiveView()).assertNull();
    });

    it('actionReinitResetsObserversAndDebounce', 0, async () => {
      const handler = new FilteringActionTrackingHandler();
      const rumConfig = buildRumConfig(false, true, handler);
      const button = new FakeFrameNode('Button', 'ignore_action_view', 9002);
      initializeAutoTrack(context, uiContext, rumConfig);
      await uiContext.observer.emitWillClick(button);
      expect(handler.resolvedCount).assertEqual(1);
      for (let i = 0; i < 2; i++) {
        FTActionTracker.getInstance().destroy();
        expect(uiContext.observer.getWillClickCallbackCount()).assertEqual(0);
        FTActionTracker.getInstance().init(uiContext as Object as UIContext, rumConfig);
        expect(uiContext.observer.getWillClickCallbackCount()).assertEqual(1);
        await uiContext.observer.emitWillClick(button);
        expect(handler.resolvedCount).assertEqual(i + 2);
      }
    });

    it('routerViewUsesAndroidSimpleName', 0, async () => {
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

    it('routerHideClosesViewWithoutWaitingForAnotherPage', 0, async () => {
      const route = 'pages/Index';
      const pageId = 'hidden-index';
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      await uiContext.observer.emitRouterPageUpdate(route, 2, pageId);
      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.getViewName()).assertEqual('Index');

      await uiContext.observer.emitRouterPageUpdate('pages/Other', 3, 'other-page');
      await uiContext.observer.emitRouterPageUpdate(route, 4, pageId);
      await uiContext.observer.emitRouterPageUpdate(route, 1, pageId);
      expect(first?.isClose()).assertFalse();

      await uiContext.observer.emitRouterPageUpdate(route, 3, pageId);
      expect(first?.isClose()).assertTrue();
      const closed = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_id=${first?.getId()}`, 'is_active=false'], 8000);
      expect(closed !== null).assertTrue();
      const fallbackTags: Record<string, string> = {};
      FTRUMInnerManager.getInstance().attachRUMRelative(fallbackTags, false);
      expect(fallbackTags[Constants.KEY_RUM_VIEW_NAME]).assertEqual(Constants.VIEW_NAME_ROOT_FALLBACK);
      await FTNavigationTracker.getInstance().resumeAutomaticViewOnForeground();
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId()).assertEqual(first?.getId());

      await uiContext.observer.emitRouterPageUpdate(route, 2, pageId);
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(second?.getViewName()).assertEqual('Index');
      expect(second?.isClose()).assertFalse();
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('explicitSameNameStartViewCreatesNewView', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      const rum = FTRUMGlobalManager.getInstance();
      await rum.startView('RepeatedPage');
      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first !== null).assertTrue();

      await rum.startView('RepeatedPage');
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.isClose()).assertTrue();
      expect(second?.getViewName()).assertEqual('RepeatedPage');
      expect(second?.isClose()).assertFalse();
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('sameNamedRouterInstancesCreateSeparateViews', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      const route = 'pages/Index';
      await uiContext.observer.emitRouterPageUpdate(route, 0, 'router-first');
      await uiContext.observer.emitRouterPageUpdate(route, 2, 'router-first');
      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.getViewName()).assertEqual('Index');
      const firstLoadTime = first?.getLoadTime() ?? 0;

      await uiContext.observer.emitRouterPageUpdate(route, 2, 'router-first');
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId()).assertEqual(first?.getId());

      // Two distinct page IDs can be shown within the old 80 ms debounce window.
      await uiContext.observer.emitRouterPageUpdate(route, 0, 'router-second');
      await uiContext.observer.emitRouterPageUpdate(route, 2, 'router-second');
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.isClose()).assertTrue();
      expect(first?.getLoadTime()).assertEqual(firstLoadTime);
      expect(second?.getViewName()).assertEqual('Index');
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('manualSameNameViewSurvivesDuplicateRouterCallback', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      const route = 'pages/Index';
      await uiContext.observer.emitRouterPageUpdate(route, 2, 'router-index');
      const automatic = FTRUMInnerManager.getInstance().getActiveView();

      await FTRUMGlobalManager.getInstance().startView('Index');
      const manual = FTRUMInnerManager.getInstance().getActiveView();
      expect(manual?.getId() === automatic?.getId()).assertFalse();

      await uiContext.observer.emitRouterPageUpdate(route, 2, 'router-index');
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId()).assertEqual(manual?.getId());
    });

    it('sameNamedNavigationInstancesCreateSeparateViews', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      const route = 'pages/Details';
      await uiContext.observer.emitNavDestinationSwitch('pages/Index', route, 'navigation-first');
      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.getViewName()).assertEqual('Details');

      await uiContext.observer.emitNavDestinationSwitch('pages/Index', route, 'navigation-first');
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId()).assertEqual(first?.getId());

      await uiContext.observer.emitNavDestinationSwitch(route, route, 'navigation-second');
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.isClose()).assertTrue();
      expect(second?.getViewName()).assertEqual('Details');
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('sameNamedRouterAndNavigationPagesCreateSeparateViews', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      await uiContext.observer.emitNavDestinationSwitch('pages/Source', 'pages/Details', 'nav-details');
      const first = FTRUMInnerManager.getInstance().getActiveView();

      await uiContext.observer.emitRouterPageUpdate('pages/Details', 2, 'router-details');
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.isClose()).assertTrue();
      expect(second?.getViewName()).assertEqual('Details');
      expect(second?.getId() === first?.getId()).assertFalse();
    });

    it('switchingUiContextRebindsTheVisibleRouterView', 0, async () => {
      const rumConfig = buildRumConfig(true, false);
      initializeAutoTrack(context, uiContext, rumConfig);
      await uiContext.observer.emitRouterPageUpdate('pages/First', 2, 'first-page');
      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.getViewName()).assertEqual('First');

      const secondContext = new FakeUIContext();
      secondContext.currentRouterName = 'pages/Second';
      FTNavigationTracker.getInstance().init(secondContext as Object as UIContext, rumConfig);
      const rebound = await WaitUtils.waitUntil(async () =>
        FTRUMInnerManager.getInstance().getActiveView()?.getViewName() === 'Second', 5000);
      expect(rebound).assertTrue();
      expect(first?.isClose()).assertTrue();
      expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(0);
      expect(secondContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(1);

      const currentId = FTRUMInnerManager.getInstance().getActiveView()?.getId() ?? '';
      await uiContext.observer.emitRouterPageUpdate('pages/First', 2, 'old-window');
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId() ?? '').assertEqual(currentId);
    });

    it('foregroundResumeCreatesNewViewForSameRouterPage', 0, async () => {
      const routeName = 'pages/Index';
      const tracker = FTNavigationTracker.getInstance();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));

      await uiContext.observer.emitRouterPageUpdate(routeName, 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate(routeName, 2);
      const first = await DBAssert.waitForViewNamed('Index', 5000);
      expect(first !== null).assertTrue();
      const firstId = first?.getId() ?? '';

      await FTRUMGlobalManager.getInstance().stopView();
      await flushAndAssertPayload(collector, ['view,', 'view_name=Index', 'is_active=false']);

      // Returning to the same page need not produce another Router callback.
      await Promise.all([tracker.resumeAutomaticViewOnForeground(), tracker.resumeAutomaticViewOnForeground()]);
      const resumed = FTRUMInnerManager.getInstance().getActiveView();
      expect(resumed !== null).assertTrue();
      expect(resumed?.getViewName() ?? '').assertEqual('Index');
      expect(resumed?.isClose() ?? true).assertFalse();
      expect(resumed?.getId() === firstId).assertFalse();
      const resumedId = resumed?.getId() ?? '';

      const persisted = await WaitUtils.waitUntil(async () => {
        const views = await DBAssert.queryViews(20);
        return views.some(view => view.getId() === resumedId && !view.getIsClose());
      }, 5000);
      expect(persisted).assertTrue();

      await uiContext.observer.emitRouterPageUpdate(routeName, 2);
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getId() ?? '').assertEqual(resumedId);
    });

    it('repeatedForegroundResumeRecoversVisibleRouterPageWithoutCachedContext', 0, async () => {
      const tracker = FTNavigationTracker.getInstance();
      const manager = FTRUMInnerManager.getInstance();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));
      // The first observer recovery has already run before this route appears,
      // and Router will not replay state=2 on a foreground transition.
      await WaitUtils.delay(150);
      uiContext.currentRouterName = 'pages/Index';

      let previousId = '';
      for (let i = 0; i < 3; i++) {
        manager.onAppBackground();
        await FTRUMGlobalManager.getInstance().stopView();
        const background = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_BACKGROUND, 5000);
        expect(background !== null).assertTrue();

        manager.onAppForeground();
        await tracker.resumeAutomaticViewOnForeground();
        const current = manager.getActiveView();
        expect(current?.getViewName()).assertEqual('Index');
        expect(current?.isClose() ?? true).assertFalse();
        expect(current?.getId() === previousId).assertFalse();
        previousId = current?.getId() ?? '';
      }
    });

    it('foregroundResumeWaitsForWindowRebindBeforeRestoringPage', 0, async () => {
      const rumConfig = buildRumConfig(true, false);
      initializeAutoTrack(context, uiContext, rumConfig);
      await uiContext.observer.emitRouterPageUpdate('pages/First', 2, 'first-page');
      await FTRUMGlobalManager.getInstance().stopView();

      const secondContext = new FakeUIContext();
      secondContext.currentRouterName = 'pages/Second';
      const tracker = FTNavigationTracker.getInstance();
      tracker.init(secondContext as Object as UIContext, rumConfig);
      await tracker.resumeAutomaticViewOnForeground();

      const active = FTRUMInnerManager.getInstance().getActiveView();
      expect(active?.getViewName()).assertEqual('Second');
      expect(active?.isClose() ?? true).assertFalse();
      expect(uiContext.observer.getRouterPageUpdateCallbackCount()).assertEqual(0);
    });

    it('foregroundResumeReevaluatesViewHandler', 0, async () => {
      const handler = new MutableViewTrackingHandler();
      const rumConfig = buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.ROUTER);
      initializeAutoTrack(context, uiContext, rumConfig);
      await uiContext.observer.emitRouterPageUpdate('pages/Index', 2);

      const first = FTRUMInnerManager.getInstance().getActiveView();
      expect(first?.getViewName()).assertEqual('Index_guest');
      const firstId = first?.getId() ?? '';
      await FTRUMGlobalManager.getInstance().stopView();

      handler.role = 'member';
      await FTNavigationTracker.getInstance().resumeAutomaticViewOnForeground();
      const second = FTRUMInnerManager.getInstance().getActiveView();
      expect(second?.getViewName()).assertEqual('Index_member');
      expect(second?.getId() === firstId).assertFalse();
      const userType = second?.getProperty()['user_type'] as ActionPropertyWrapper;
      expect(userType.value).assertEqual('member');

      await FTRUMGlobalManager.getInstance().stopView();
      handler.enabled = false;
      await FTNavigationTracker.getInstance().resumeAutomaticViewOnForeground();
      const afterFilter = FTRUMInnerManager.getInstance().getActiveView();
      expect(afterFilter?.getId()).assertEqual(second?.getId());
      expect(afterFilter?.isClose()).assertTrue();
      expect(handler.resolvedCount).assertEqual(3);
    });

    it('foregroundResumeReevaluatesInitiallyFilteredNavigationView', 0, async () => {
      const handler = new MutableViewTrackingHandler();
      handler.role = 'member';
      handler.enabled = false;
      const rumConfig = buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.NAVIGATION);
      initializeAutoTrack(context, uiContext, rumConfig);
      await uiContext.observer.emitNavDestinationSwitch('pages/Index', 'pages/Settings');
      expect(FTRUMInnerManager.getInstance().getActiveView()).assertNull();

      handler.enabled = true;
      await FTNavigationTracker.getInstance().resumeAutomaticViewOnForeground();
      expect(FTRUMInnerManager.getInstance().getActiveView()?.getViewName()).assertEqual('Settings_member');
      expect(handler.resolvedCount).assertEqual(2);
    });

    it('routerPageDisabledShouldWriteNothing', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(false, false));

      await uiContext.observer.emitRouterPageUpdate('pages/DisabledAutoTrackPage', 0);
      await uiContext.observer.emitRouterPageUpdate('pages/DisabledAutoTrackPage', 2);
      await WaitUtils.delay(500);

      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('routerHandlerCustomizeAndFilterAutoViews', 0, async () => {
      const handler = new FilteringRouterTrackingHandler();
      const rumConfig = buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.ROUTER);
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
        .setViewTrackingHandler(filteredHandler, FTViewTrackingType.ROUTER));
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredRouterPage', 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate('pages/IgnoredRouterPage', 2);
      await WaitUtils.delay(500);

      expect(filteredHandler.resolvedRouteNames.length).assertEqual(1);
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('viewHandlerCanFilterByRouterAndNavigationContext', 0, async () => {
      const handler = new ContextFilteringViewTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.ALL));

      await uiContext.observer.emitRouterPageUpdate('pages/private/AccountDetail', 0);
      await WaitUtils.delay(120);
      await uiContext.observer.emitRouterPageUpdate('pages/private/AccountDetail', 2);
      await WaitUtils.delay(300);

      expect(handler.contexts.length).assertEqual(1);
      const routerContext = handler.contexts[0];
      expect(routerContext.trackingType).assertEqual(FTViewTrackingType.ROUTER);
      expect(routerContext.originalViewName).assertEqual('pages/private/AccountDetail');
      expect(routerContext.viewName).assertEqual('AccountDetail');
      expect(routerContext.originalFromViewName).assertEqual('');
      expect(routerContext.fromViewName).assertEqual('');
      if (routerContext.trackingType === FTViewTrackingType.ROUTER) {
        expect(routerContext.routerPageInfo.name).assertEqual('pages/private/AccountDetail');
        expect(routerContext.routerPageInfo.state).assertEqual(0);
        expect(routerContext.routerPageState).assertEqual(0);
      } else {
        expect(false).assertTrue();
      }
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);

      await uiContext.observer.emitNavDestinationSwitch('pages/Checkout', 'pages/orders/OrderDetail');
      await WaitUtils.delay(300);

      expect(handler.contexts.length).assertEqual(2);
      const navigationContext = handler.contexts[1];
      expect(navigationContext.trackingType).assertEqual(FTViewTrackingType.NAVIGATION);
      expect(navigationContext.originalViewName).assertEqual('pages/orders/OrderDetail');
      expect(navigationContext.viewName).assertEqual('OrderDetail');
      expect(navigationContext.originalFromViewName).assertEqual('pages/Checkout');
      expect(navigationContext.fromViewName).assertEqual('Checkout');
      if (navigationContext.trackingType === FTViewTrackingType.NAVIGATION) {
        const from: uiObserver.NavDestinationInfo | 'navBar' | undefined = navigationContext.navigationInfo.from;
        expect(from !== undefined && typeof from !== 'string' && typeof from.name === 'string' ? from.name : '')
          .assertEqual('pages/Checkout');
      } else {
        expect(false).assertTrue();
      }
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('navigationViewUsesAndroidSimpleName', 0, async () => {
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

    it('navigationSwitchNotSuppressRouterView', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/NavigationDestination');
      await uiContext.observer.emitRouterPageUpdate('pages/RouterDestination', 0);
      await uiContext.observer.emitRouterPageUpdate('pages/RouterDestination', 2);
      await WaitUtils.delay(300);

      const view = await DBAssert.waitForViewNamed('RouterDestination', 5000);
      expect(view !== null).assertTrue();
      expect(view?.getViewName() ?? '').assertEqual('RouterDestination');
    });

    it('navHandlerCustomizesAndFiltersViews', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      const rumConfig = buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.NAVIGATION);
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
        .setViewTrackingHandler(filteredHandler, FTViewTrackingType.NAVIGATION));
      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/IgnoredNavigationDestination');
      await WaitUtils.delay(500);

      expect(filteredHandler.resolvedDestinationNames.length).assertEqual(1);
      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('emptyNavNameSkipsView', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewTrackingHandler(new EmptyViewNameNavigationTrackingHandler(), FTViewTrackingType.NAVIGATION));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/BlankNavigationDestination');
      await WaitUtils.delay(300);

      expect((await DBAssert.queryViews(20)).length).assertEqual(0);
      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
    });

    it('filteredDestinationClosesPriorView', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.NAVIGATION));

      await uiContext.observer.emitNavDestinationSwitch('pages/NavigationSource', 'pages/TrackedNavigationDestination');
      await WaitUtils.delay(120);
      await uiContext.observer.emitNavDestinationSwitch('pages/TrackedNavigationDestination', 'pages/IgnoredNavigationDestination');

      // Closed views are removed from the aggregation table after serialization.
      const closedView = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view,', 'view_name=custom_navigation_TrackedNavigationDestination', 'is_active=false'
      ], 5000);
      expect(closedView !== null).assertTrue();
      const views = await DBAssert.queryViews(20);
      expect(views.some(view => view.getViewName().includes('IgnoredNavigationDestination'))).assertFalse();
      const records = await DBAssert.querySyncData([DataType.RUM_APP]);
      expect(records.some(record => record.getDataString().includes('view_name=custom_navigation_IgnoredNavigationDestination')))
        .assertFalse();
    });

    it('filteredNavAllowsSameNamedRouter', 0, async () => {
      const handler = new FilteringNavigationTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(true, false)
        .setViewTrackingHandler(handler, FTViewTrackingType.NAVIGATION));

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

    it('willClickHandlerFilterAutoAction', 0, async () => {
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true, new FilteringActionTrackingHandler()));
      await startViewForAction('filtered_action_view');

      // FilteringActionTrackingHandler returns null for the configured filtered ID.
      await uiContext.observer.emitWillClick(new FakeFrameNode('Button', 'ignore_action_view', 1003));
      await WaitUtils.delay(500);

      expect((await DBAssert.queryActions(20)).length).assertEqual(0);
      const records = await DBAssert.querySyncData([DataType.RUM_APP]);
      expect(records.some(record => record.getDataString().startsWith('action,'))).assertFalse();
    });

    it('undefinedClickUsesDefaultTracking', 0, async () => {
      const viewName = 'pass_through_action_view';
      const actionName = 'Button/继续默认采集#pass_through_action#position:1';
      const handler = new PassThroughActionTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true, handler));
      await startViewForAction(viewName);

      const firstTab = new FakeFrameNode('TabContent', 'pass_through_first_tab', 1004);
      const secondTab = new FakeFrameNode('TabContent', 'pass_through_second_tab', 1005)
        .setPreviousSibling(firstTab);
      const button = new FakeFrameNode('Button', 'pass_through_action', 1006)
        .setInspectorAttribute('label', '继续默认采集')
        .setParent(secondTab);
      await uiContext.observer.emitWillClick(button);
      expect(handler.resolvedCount).assertEqual(1);
      await assertActionStarted(actionName);
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        `action_name=${actionName}`,
        `view_name=${viewName}`
      ]);
    });

    it('handlerActionCustomizesClickNameAndProperties', 0, async () => {
      const handler = new CustomizingActionTrackingHandler();
      initializeAutoTrack(context, uiContext, buildRumConfig(false, true, handler));
      await startViewForAction('custom_action_view_page');

      const node = new FakeFrameNode('Button', 'custom_action_view', 1007);
      const automaticProperties: Record<string, object> = {};
      automaticProperties['automatic_only'] = new ActionPropertyWrapper('retained');
      automaticProperties['shared_property'] = new ActionPropertyWrapper('automatic_loses');
      node.setCustomProperty('action_property', automaticProperties);
      await uiContext.observer.emitWillClick(node);
      expect(handler.observedExtra !== null).assertTrue();
      expect(handler.observedExtra!['automatic_only'] !== undefined).assertTrue();
      expect(handler.observedExtra!['shared_property'] !== undefined).assertTrue();
      await assertActionStarted('custom_action_name');
      await closeCurrentViewAndWaitForRum();

      await flushAndAssertPayload(collector, [
        'action,',
        'action_name=custom_action_name',
        'handler_property=handler_value',
        'automatic_only=retained',
        'shared_property=handler_wins',
        'view_name=custom_action_view_page'
      ]);
    });
  });
}
