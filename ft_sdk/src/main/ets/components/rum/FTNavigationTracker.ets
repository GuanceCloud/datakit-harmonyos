import { UIContext, UIObserver, uiObserver } from '@kit.ArkUI';
import { FTRUMGlobalManager } from './FTRUMGlobalManager';
import { FTRUMInnerManager } from './FTRUMInnerManager';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMConfig } from '../Configs';
import { Utils } from '../utils/Utils';
import { HandlerView } from './bean/HandlerView';
import { FTViewTrackingType } from './enum/FTViewTrackingType';
import { FTViewTrackingContext } from './handler/FTViewTrackingContext';

const TAG = 'FTNavigationTracker';

interface InitialRouterPageInfo {
  context: UIContext;
  index: number;
  name: string;
  path: string;
  state: number;
  pageId: string;
}

export class FTNavigationTracker {
  private static instance: FTNavigationTracker | null = null;
  private uiObserver: UIObserver | null = null;
  private rumConfig: FTRUMConfig | null = null;
  private readonly navDestinationSwitchCallback = (info: uiObserver.NavDestinationSwitchInfo): void => {
    this.handleSwitchNav(info);
  };
  private readonly routerPageUpdateCallback = (info: uiObserver.RouterPageInfo): void => {
    this.handleSwitchRouter(info);
  };
  // The View name currently reported to RUM. It can differ from the route name
  // when an application configures an automatic View tracking handler.
  private currentViewName: string = '';
  // The normalized Router/Navigation name for the active automatic View.
  // A filtered page deliberately leaves this empty so it cannot suppress a
  // later callback from the other automatic source.
  private currentRouteName: string = '';
  private lastNavigationSwitchTs: number = 0;
  private lastRouterShownTs: number = 0;
  private inited: boolean = false;
  // Track page creation start time for load time calculation
  // Map<viewName, startTime in nanoseconds>
  private pageCreateStartTimeMap: Map<string, number> = new Map();
  // Track page resume start time for returning pages (when page already exists)
  // Map<viewName, resumeStartTime in nanoseconds>
  // Used when returning to a previous page that was already created
  private pageResumeStartTimeMap: Map<string, number> = new Map();
  // Router state=0 is the creation phase and state=2 is the shown phase. Keep
  // the handler's decision between them so a filtered route remains filtered
  // for its whole automatic View lifecycle.
  private pendingRouterHandlerViews: Map<string, HandlerView | null> = new Map();

  public static getInstance(): FTNavigationTracker {
    if (!FTNavigationTracker.instance) {
      FTNavigationTracker.instance = new FTNavigationTracker();
    }
    return FTNavigationTracker.instance;
  }

  public init(uiContext: UIContext, rumConfig: FTRUMConfig): void {
    if (this.inited) {
      return;
    }
    this.rumConfig = rumConfig;
    
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!rumConfig.isEnableTraceUserView()) {
      return;
    }
    
    const observer = uiContext.getUIObserver();
    if (!observer) {
      FTInnerLogger.w(TAG, 'UIObserver is null, skip navigation tracking');
      return;
    }

    this.uiObserver = observer;
    observer.on('navDestinationSwitch', this.navDestinationSwitchCallback);
    observer.on('routerPageUpdate', this.routerPageUpdateCallback);

    this.inited = true;
    // The first Router page can be shown before UIContext is available to the
    // SDK. UIObserver does not replay that event to a late subscriber, so seed
    // the same View path from the current Router state once subscribed.
    this.bootstrapCurrentRouterPage(uiContext);
  }

  private bootstrapCurrentRouterPage(uiContext: UIContext): void {
    try {
      const state = uiContext.getRouter().getState();
      // RouterState.path is the directory on some HarmonyOS releases (for
      // example "pages"), while name is the page file ("Index"). Rebuild
      // the route supplied by RouterPageInfo so View naming and app handlers
      // see the same page on cold start and later navigation.
      let routeName = state.name;
      if (state.path.length > 0 && state.name.length > 0 &&
        state.path !== state.name && !state.path.endsWith(`/${state.name}`)) {
        routeName = `${state.path}/${state.name}`;
      } else if (state.path.length > 0) {
        routeName = state.path;
      }
      if (routeName.length === 0) {
        return;
      }
      const pageInfo: InitialRouterPageInfo = {
        context: uiContext,
        index: state.index,
        name: routeName,
        path: state.path,
        state: 2,
        pageId: ''
      };
      this.handleSwitchRouter(pageInfo as Object as uiObserver.RouterPageInfo).catch((error: Error): void => {
        FTInnerLogger.w(TAG, `Initial Router View bootstrap failed: ${error}`);
      });
    } catch (error) {
      // Router state may still be unavailable while a WindowStage is created.
      // The normal Router observer remains registered for subsequent pages.
      FTInnerLogger.d(TAG, `Initial Router state unavailable: ${error}`);
    }
  }

  public destroy(): void {
    const observer = this.uiObserver;
    this.uiObserver = null;
    this.rumConfig = null;
    if (observer) {
      try {
        observer.off('navDestinationSwitch', this.navDestinationSwitchCallback);
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to remove Navigation observer: ${error}`);
      }
      try {
        observer.off('routerPageUpdate', this.routerPageUpdateCallback);
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to remove Router observer: ${error}`);
      }
    }
    this.currentViewName = '';
    this.currentRouteName = '';
    this.lastNavigationSwitchTs = 0;
    this.lastRouterShownTs = 0;
    this.inited = false;
    this.pageCreateStartTimeMap.clear();
    this.pageResumeStartTimeMap.clear();
    this.pendingRouterHandlerViews.clear();
  }

  private async handleSwitchNav(info: uiObserver.NavDestinationSwitchInfo): Promise<void> {
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!this.rumConfig || !this.rumConfig.isEnableTraceUserView()) {
      return;
    }
    
    const toNameRaw: string = this.getNavName(info.to);
    
    // Use the route's simple name for automatic views, matching Android's
    // Activity.getClass().getSimpleName() default naming rule.
    const toName: string = this.normalizeViewName(toNameRaw);

    if (!toName || toName.length === 0) {
      await this.startAutomaticView('', null);
      return;
    }

    const handlerView = this.resolveNavigationHandlerView(toName, toNameRaw, info);
    if (handlerView === null) {
      await this.startAutomaticView(toName, null);
      return;
    }

    if (this.currentRouteName === toName) {
      return;
    }

    const now = Date.now();
    // Merge duplicate Navigation callbacks only. Router lifecycle callbacks
    // use an independent debounce window and must not be suppressed here.
    if (now - this.lastNavigationSwitchTs < 80) {
      return;
    }
    this.lastNavigationSwitchTs = now;

    // A Navigation destination does not expose a Router state=0 creation
    // callback. Preserve the existing resume-to-shown load-time measurement
    // for a subsequent Router state=2 notification.
    if (!this.pageCreateStartTimeMap.get(toName)) {
      this.pageResumeStartTimeMap.set(toName, Utils.getCurrentNanoTime());
    }

    await this.startAutomaticView(toName, handlerView);
  }

  private getNavName(item: uiObserver.NavDestinationInfo | "navBar" | undefined): string {
    if (!item) {
      return '';
    }
    if (typeof item === 'string') {
      // ignore builtin string like "navBar" for view name
      return '';
    }
    const nameCandidate = item.name;
    return typeof nameCandidate === 'string' ? nameCandidate : '';
  }

  private async handleSwitchRouter(info: uiObserver.RouterPageInfo): Promise<void> {
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!this.rumConfig || !this.rumConfig.isEnableTraceUserView()) {
      return;
    }
    
    const toNameRaw: string = info.name ? info.name : '';
    let toName: string = toNameRaw;

    if (!toName || toName.length === 0) {
      if (info.state === 2) {
        await this.startAutomaticView('', null);
      }
      return;
    }

    // Use the route's simple name for automatic views, matching Android's
    // Activity.getClass().getSimpleName() default naming rule.
    toName = this.normalizeViewName(toName);
    if (!toName || toName.length === 0) {
      if (info.state === 2) {
        await this.startAutomaticView('', null);
      }
      return;
    }

    // Handle state=0 (page created) - determine whether this Router page is
    // tracked, then record its creation time only for Views that will be sent.
    // Aligned with Android: FTFragmentLifecycleHelper.onFragmentPreAttached records start time
    if (info.state === 0) {
      const handlerView = this.resolveRouterHandlerView(toName, toNameRaw, info);
      this.pendingRouterHandlerViews.set(toName, handlerView);
      if (handlerView === null) {
        this.pageCreateStartTimeMap.delete(toName);
        this.pageResumeStartTimeMap.delete(toName);
        return;
      }
      const createStartTime = Utils.getCurrentNanoTime();
      this.pageCreateStartTimeMap.set(toName, createStartTime);
      // Clear any existing resume start time (page is being created, not resumed)
      this.pageResumeStartTimeMap.delete(toName);
      return; // Don't start view yet, wait for state=2 (page shown)
    }
    
    // Handle state=1 (page hidden) - no action needed
    if (info.state === 1) {
      return;
    }
    
    // Handle state=3 or state=4 (page being hidden/removed) - record resume start time for returning pages
    // When current page is being hidden, the next page to show is likely a returning page
    // Record resume start time at this point to measure from pushBack to page shown
    if (info.state === 3 || info.state === 4) {
      // Check if this is the current active page being hidden
      if (toName === this.currentRouteName) {
        // Current page is being hidden, likely due to pushBack
        // Try to determine the next page that will be shown (returning page)
        // We can infer from the navigation stack: when pushing back, the previous page in the stack will be shown
        // Since we don't have direct access to navigation stack, we'll use a simpler approach:
        // Record a global resume start time, and when state=2 is received for a returning page, use this time
        const resumeStartTime = Utils.getCurrentNanoTime();
        // Store with a special key that will be matched in state=2
        // We'll use currentViewName as the key, since the next page shown will likely be the returning page
        // But we don't know which page yet, so we'll use a temporary marker
        this.pageResumeStartTimeMap.set('_pending_resume', resumeStartTime);
      }
      return;
    }
    
    // Handle state=2 (page shown) - calculate load time and start view
    // Aligned with Android: FTFragmentLifecycleHelper.onFragmentCreated calculates duration and calls onCreateView
    if (info.state === 2) {
      let handlerView: HandlerView | null;
      if (this.pendingRouterHandlerViews.has(toName)) {
        handlerView = this.pendingRouterHandlerViews.get(toName) ?? null;
        this.pendingRouterHandlerViews.delete(toName);
      } else {
        // A Router page may be restored without emitting state=0. Resolve it
        // at display time in that case, matching Android's resume behavior.
        handlerView = this.resolveRouterHandlerView(toName, toNameRaw, info);
      }

      if (handlerView === null) {
        this.pageCreateStartTimeMap.delete(toName);
        this.pageResumeStartTimeMap.delete(toName);
        await this.startAutomaticView(toName, null);
        return;
      }

      // A Navigation callback may already have started the same automatic
      // View. Keep that View and attach this Router lifecycle's load time to
      // it when timing data is available.
      if (this.currentRouteName === toName) {
        this.recordRouterViewLoadTime(toName, this.currentViewName, false);
        return;
      }

      const now = Date.now();
      if (now - this.lastRouterShownTs < 80) {
        this.pageCreateStartTimeMap.delete(toName);
        this.pageResumeStartTimeMap.delete(toName);
        return;
      }
      this.lastRouterShownTs = now;

      this.recordRouterViewLoadTime(toName, handlerView.getViewName(), true);

      await this.startAutomaticView(toName, handlerView);
      return;
    }
  }

  /**
   * Uses the configured Router handler when present. Without a handler, keep
   * the existing automatic behavior and collect the normalized route name.
   */
  private resolveRouterHandlerView(
    routeName: string,
    originalRouteName: string,
    routerPageInfo: uiObserver.RouterPageInfo
  ): HandlerView | null {
    const context: FTViewTrackingContext = {
      trackingType: FTViewTrackingType.ROUTER,
      routerPageInfo,
      originalViewName: originalRouteName,
      viewName: routeName,
      originalFromViewName: '',
      fromViewName: '',
      routerPageState: routerPageInfo.state
    };
    return this.resolveAutomaticViewHandler(FTViewTrackingType.ROUTER, routeName, context, 'Router');
  }

  /**
   * Uses the configured Navigation handler when present. Without a handler,
   * keep the existing automatic behavior and collect the normalized name.
   */
  private resolveNavigationHandlerView(
    destinationName: string,
    originalDestinationName: string,
    navigationInfo: uiObserver.NavDestinationSwitchInfo
  ): HandlerView | null {
    const originalFromName = this.getNavName(navigationInfo.from);
    const fromName = this.normalizeViewName(originalFromName);
    const context: FTViewTrackingContext = {
      trackingType: FTViewTrackingType.NAVIGATION,
      navigationInfo,
      originalViewName: originalDestinationName,
      viewName: destinationName,
      originalFromViewName: originalFromName,
      fromViewName: fromName
    };
    return this.resolveAutomaticViewHandler(FTViewTrackingType.NAVIGATION, destinationName, context, 'Navigation');
  }

  /**
   * Invokes either source's configured handler through one path so filtering,
   * name validation, and failure behavior are identical for Router and
   * Navigation Views.
   */
  private resolveAutomaticViewHandler(
    trackingType: FTViewTrackingType,
    viewName: string,
    context: FTViewTrackingContext,
    source: string
  ): HandlerView | null {
    const handler = this.rumConfig?.getViewTrackingHandler(trackingType) ?? null;
    if (handler === null) {
      return new HandlerView(viewName);
    }
    try {
      return this.validateHandlerView(handler.resolveHandlerView(context), source, viewName);
    } catch (e) {
      FTInnerLogger.w(TAG, `${source} View handler failed for ${viewName}: ${e}`);
      return null;
    }
  }

  /** Treat a blank handler View name as the same skip decision as null. */
  private validateHandlerView(handlerView: HandlerView | null, source: string, routeName: string): HandlerView | null {
    if (handlerView !== null && handlerView.getViewName().trim().length === 0) {
      FTInnerLogger.w(TAG, `${source} View handler returned an empty View name for ${routeName}`);
      return null;
    }
    return handlerView;
  }

  /**
   * Records the load time from Router lifecycle callbacks. If a Navigation
   * callback has already started the same View, `viewName` is that active
   * View's name instead of the Router handler's prospective name.
   */
  private recordRouterViewLoadTime(routeName: string, viewName: string, allowFallback: boolean): void {
    const createStartTime = this.pageCreateStartTimeMap.get(routeName);
    if (createStartTime !== undefined) {
      const loadTime = Utils.getCurrentNanoTime() - createStartTime;
      this.pageCreateStartTimeMap.delete(routeName);
      FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(viewName, loadTime);
      return;
    }

    let resumeStartTime = this.pageResumeStartTimeMap.get(routeName);
    if (resumeStartTime === undefined) {
      const pendingResumeTime = this.pageResumeStartTimeMap.get('_pending_resume');
      if (pendingResumeTime !== undefined) {
        resumeStartTime = pendingResumeTime;
        this.pageResumeStartTimeMap.delete('_pending_resume');
      }
    }

    if (resumeStartTime === undefined) {
      if (!allowFallback) {
        return;
      }
      resumeStartTime = Utils.getCurrentNanoTime();
    }

    this.pageResumeStartTimeMap.delete(routeName);
    const loadTime = Utils.getCurrentNanoTime() - resumeStartTime;
    const resumeKey = `${viewName}_resume`;
    FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(resumeKey, loadTime);
  }

  /**
   * Transitions the automatic View state to a Router page or Navigation
   * destination. A null HandlerView closes the prior tracked View and
   * deliberately starts no replacement View.
   */
  private async startAutomaticView(routeName: string, handlerView: HandlerView | null): Promise<void> {
    const rum = FTRUMGlobalManager.getInstance();
    try {
      if (this.currentViewName.length > 0) {
        await rum.stopView();
      }
    } catch (e) {
      FTInnerLogger.w(TAG, `stopView failed: ${e}`);
    }

    this.currentViewName = '';
    this.currentRouteName = '';

    if (handlerView === null) {
      FTInnerLogger.d(TAG, `automatic View filtered: ${routeName}`);
      return;
    }

    try {
      await rum.startView(handlerView.getViewName(), handlerView.getProperty() ?? {});
      this.currentViewName = handlerView.getViewName();
      this.currentRouteName = routeName;
    } catch (e) {
      FTInnerLogger.w(TAG, `startView failed: ${e}`);
    }
  }

  /**
   * Resolve the automatic View name from an ArkUI route.
   *
   * Android automatic View tracking uses Activity.getClass().getSimpleName().
   * An ArkUI route has no Activity class, so its final path segment is the
   * equivalent stable page name. Manual startView names are not passed here
   * and are intentionally left untouched.
   * Examples:
   *   "pages/ActionTestPage" -> "ActionTestPage"
   *   "pages/account/SettingsPage" -> "SettingsPage"
   *   "ActionTestPage" -> "ActionTestPage" (no change)
   * @param viewName Original view name (may be route path or page name)
   * @returns Simple automatic view name
   */
  private normalizeViewName(viewName: string): string {
    if (!viewName || viewName.length === 0) {
      return viewName;
    }
    
    let routeName = viewName.trim();
    while (routeName.endsWith('/')) {
      routeName = routeName.substring(0, routeName.length - 1);
    }

    const separatorIndex = routeName.lastIndexOf('/');
    const normalizedName = separatorIndex >= 0 ? routeName.substring(separatorIndex + 1) : routeName;
    return normalizedName;
  }
}
