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

export class FTNavigationTracker {
  private static instance: FTNavigationTracker | null = null;
  private uiObserver: UIObserver | null = null;
  private observedUIContext: UIContext | null = null;
  private rumConfig: FTRUMConfig | null = null;
  private automaticViewEventQueue: Promise<void> = Promise.resolve();
  private readonly navDestinationSwitchCallback = (info: uiObserver.NavDestinationSwitchInfo): Promise<void> => {
    this.automaticViewEventQueue = this.automaticViewEventQueue.then(() => this.handleSwitchNav(info)).catch((error: Error) => {
      FTInnerLogger.w(TAG, `Navigation View event failed: ${error}`);
    });
    return this.automaticViewEventQueue;
  };
  private readonly routerPageUpdateCallback = (info: uiObserver.RouterPageInfo): Promise<void> => {
    this.automaticViewEventQueue = this.automaticViewEventQueue.then(() => this.handleSwitchRouter(info)).catch((error: Error) => {
      FTInnerLogger.w(TAG, `Router View event failed: ${error}`);
    });
    return this.automaticViewEventQueue;
  };
  // The View name currently reported to RUM. It can differ from the route name
  // when an application configures an automatic View tracking handler.
  private currentViewName: string = '';
  private currentViewId: string = '';
  // Retain the visible source page, not the handler's previous result. Android
  // resolves its View handler on every Activity/Fragment resume.
  private lastVisibleContext: FTViewTrackingContext | null = null;
  private foregroundResumeInProgress: boolean = false;
  // Names describe a View, but only ArkUI's page IDs identify an instance.
  // Keep both so two different instances with the same name are reported.
  private currentRouteName: string = '';
  private currentPageKey: string = '';
  private startingPageKey: string = '';
  private inited: boolean = false;
  private routerShowObserved: boolean = false;
  // Track page creation start time for load time calculation
  // Map<page instance key, startTime in nanoseconds>
  private pageCreateStartTimeMap: Map<string, number> = new Map();
  // Track page resume start time for returning pages (when page already exists)
  // Map<page instance key or the pending back-navigation marker, resumeStartTime in nanoseconds>
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

    if (this.inited) {
      if (this.observedUIContext === uiContext) {
        return;
      }
      const previous = this.uiObserver;
      if (previous && previous !== observer) {
        try {
          previous.off('navDestinationSwitch', this.navDestinationSwitchCallback);
          previous.off('routerPageUpdate', this.routerPageUpdateCallback);
        } catch (error) {
          FTInnerLogger.w(TAG, `Unable to remove previous window observer: ${error}`);
        }
      }
      this.uiObserver = observer;
      this.observedUIContext = uiContext;
      this.routerShowObserved = false;
      this.automaticViewEventQueue = this.automaticViewEventQueue.then(async () => {
        await this.startAutomaticView('', null, '');
        this.lastVisibleContext = null;
        this.startingPageKey = '';
        this.pageCreateStartTimeMap.clear();
        this.pageResumeStartTimeMap.clear();
        this.pendingRouterHandlerViews.clear();
        await this.restoreVisibleRouterPage(uiContext);
      }).catch((error: Error) => {
        FTInnerLogger.w(TAG, `Window View recovery failed: ${error}`);
      });
      if (previous !== observer) {
        observer.on('navDestinationSwitch', this.navDestinationSwitchCallback);
        observer.on('routerPageUpdate', this.routerPageUpdateCallback);
      }
      return;
    }

    this.uiObserver = observer;
    this.observedUIContext = uiContext;
    observer.on('navDestinationSwitch', this.navDestinationSwitchCallback);
    observer.on('routerPageUpdate', this.routerPageUpdateCallback);

    this.inited = true;
    // UIContext may become available only after loadContent has already shown
    // the first page. In that case the observer cannot replay its state=2 event.
    setTimeout(() => {
      if (this.uiObserver === observer) {
        this.automaticViewEventQueue = this.automaticViewEventQueue.then(() =>
          this.restoreVisibleRouterPage(uiContext)).catch((error: Error) => {
          FTInnerLogger.w(TAG, `Router View recovery failed: ${error}`);
        });
      }
    }, 100);
  }

  public destroy(): void {
    const observer = this.uiObserver;
    this.uiObserver = null;
    this.observedUIContext = null;
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
    this.currentViewId = '';
    this.lastVisibleContext = null;
    this.foregroundResumeInProgress = false;
    this.currentRouteName = '';
    this.currentPageKey = '';
    this.startingPageKey = '';
    this.automaticViewEventQueue = Promise.resolve();
    this.inited = false;
    this.routerShowObserved = false;
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
      await this.startAutomaticView('', null, '');
      return;
    }

    const pageKey = this.getNavigationPageKey(info, toNameRaw);
    const trackingContext = this.createNavigationTrackingContext(toName, toNameRaw, info);
    if (this.isCurrentAutomaticPage(pageKey, toName)) {
      return;
    }
    const handlerView = this.resolveAutomaticViewHandler(FTViewTrackingType.NAVIGATION, toName,
      trackingContext, 'Navigation');
    if (handlerView === null) {
      this.lastVisibleContext = trackingContext;
      await this.startAutomaticView(toName, null, pageKey);
      return;
    }

    this.startingPageKey = pageKey;
    this.lastVisibleContext = trackingContext;
    try {
      await this.startAutomaticView(toName, handlerView, pageKey);
    } finally {
      if (this.startingPageKey === pageKey) {
        this.startingPageKey = '';
      }
    }
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

  private getNavigationPageKey(info: uiObserver.NavDestinationSwitchInfo, routeName: string): string {
    const destination: uiObserver.NavDestinationInfo | 'navBar' | undefined = info.to;
    if (destination && typeof destination !== 'string') {
      if (destination.navDestinationId) {
        return `navigation:${destination.navDestinationId}`;
      }
      return `navigation:${String(destination.navigationId)}:${destination.index}:${routeName}`;
    }
    return `navigation:${routeName}`;
  }

  private getRouterPageKey(info: uiObserver.RouterPageInfo, routeName: string): string {
    if (info.pageId) {
      return `router:${info.pageId}`;
    }
    // RouterState has no pageId when the first page is reconstructed.
    return `router:provisional:${info.path}:${info.index}:${routeName}`;
  }

  private isCurrentAutomaticPage(pageKey: string, routeName: string,
    routerInfo?: uiObserver.RouterPageInfo, hadCreationEvent: boolean = false): boolean {
    if (this.startingPageKey === pageKey) {
      return true;
    }
    const activeView = FTRUMInnerManager.getInstance().getActiveView();
    if (!activeView || activeView.isClose()) {
      return false;
    }
    if (this.currentPageKey === pageKey) {
      return true;
    }
    // Adopt the real pageId after an already-visible Router page was backfilled.
    const previousContext = this.lastVisibleContext;
    if (routerInfo && !hadCreationEvent && previousContext?.trackingType === FTViewTrackingType.ROUTER &&
      pageKey.startsWith('router:') && !pageKey.startsWith('router:provisional:') &&
      this.currentPageKey.startsWith('router:provisional:') &&
      this.currentRouteName === routeName && previousContext.routerPageInfo.index === routerInfo.index) {
      this.currentPageKey = pageKey;
      this.lastVisibleContext = this.createRouterTrackingContext(routeName, routerInfo.name, routerInfo);
      return true;
    }
    return false;
  }

  private isCurrentRouterPageHiding(pageKey: string, routeName: string, info: uiObserver.RouterPageInfo): boolean {
    if (this.currentPageKey === pageKey) {
      return true;
    }
    const context = this.lastVisibleContext;
    return this.currentPageKey.startsWith('router:provisional:') &&
      context?.trackingType === FTViewTrackingType.ROUTER && this.currentRouteName === routeName &&
      context.routerPageInfo.index === info.index;
  }

  private async handleSwitchRouter(info: uiObserver.RouterPageInfo): Promise<void> {
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!this.rumConfig || !this.rumConfig.isEnableTraceUserView()) {
      return;
    }
    if (info.state === 2) {
      this.routerShowObserved = true;
    }
    
    const toNameRaw: string = info.name ? info.name : '';
    let toName: string = toNameRaw;

    if (!toName || toName.length === 0) {
      if (info.state === 2) {
        this.lastVisibleContext = null;
        await this.startAutomaticView('', null, '');
      }
      return;
    }

    // Use the route's simple name for automatic views, matching Android's
    // Activity.getClass().getSimpleName() default naming rule.
    toName = this.normalizeViewName(toName);
    if (!toName || toName.length === 0) {
      if (info.state === 2) {
        this.lastVisibleContext = null;
        await this.startAutomaticView('', null, '');
      }
      return;
    }

    const pageKey = this.getRouterPageKey(info, toName);

    // Handle state=0 (page created) - determine whether this Router page is
    // tracked, then record its creation time only for Views that will be sent.
    // Aligned with Android: FTFragmentLifecycleHelper.onFragmentPreAttached records start time
    if (info.state === 0) {
      const handlerView = this.resolveRouterHandlerView(toName, toNameRaw, info);
      this.pendingRouterHandlerViews.set(pageKey, handlerView);
      if (handlerView === null) {
        this.pageCreateStartTimeMap.delete(pageKey);
        this.pageResumeStartTimeMap.delete(pageKey);
        return;
      }
      const createStartTime = Utils.getCurrentNanoTime();
      this.pageCreateStartTimeMap.set(pageKey, createStartTime);
      // Clear any existing resume start time (page is being created, not resumed)
      this.pageResumeStartTimeMap.delete(pageKey);
      return; // Don't start view yet, wait for state=2 (page shown)
    }
    
    // Showing a hidden page again begins another View lifecycle.
    if (info.state === 1) {
      if (this.isCurrentRouterPageHiding(pageKey, toName, info)) {
        this.currentPageKey = '';
        this.pageResumeStartTimeMap.set('_pending_resume', Utils.getCurrentNanoTime());
      }
      return;
    }
    
    // Handle state=3 or state=4 (page being hidden/removed) - record resume start time for returning pages
    // When current page is being hidden, the next page to show is likely a returning page
    // Record resume start time at this point to measure from pushBack to page shown
    if (info.state === 3 || info.state === 4) {
      // Check if this is the current active page being hidden
      if (this.isCurrentRouterPageHiding(pageKey, toName, info)) {
        this.currentPageKey = '';
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
      const trackingContext = this.createRouterTrackingContext(toName, toNameRaw, info);
      const hadCreationEvent = this.pendingRouterHandlerViews.has(pageKey);
      if (this.startingPageKey === pageKey) {
        return;
      }
      if (this.isCurrentAutomaticPage(pageKey, toName, info, hadCreationEvent)) {
        if (hadCreationEvent) {
          this.pendingRouterHandlerViews.delete(pageKey);
          if (FTRUMInnerManager.getInstance().getActiveView()?.getId() === this.currentViewId) {
            this.recordRouterViewLoadTime(pageKey, this.currentViewName, false, true);
          } else {
            this.pageCreateStartTimeMap.delete(pageKey);
            this.pageResumeStartTimeMap.delete(pageKey);
          }
        }
        return;
      }
      let handlerView: HandlerView | null;
      if (hadCreationEvent) {
        handlerView = this.pendingRouterHandlerViews.get(pageKey) ?? null;
        this.pendingRouterHandlerViews.delete(pageKey);
      } else {
        // A Router page may be restored without emitting state=0. Resolve it
        // at display time in that case, matching Android's resume behavior.
        handlerView = this.resolveRouterHandlerView(toName, toNameRaw, info);
      }

      if (handlerView === null) {
        this.lastVisibleContext = trackingContext;
        this.pageCreateStartTimeMap.delete(pageKey);
        this.pageResumeStartTimeMap.delete(pageKey);
        await this.startAutomaticView(toName, null, pageKey);
        return;
      }

      this.recordRouterViewLoadTime(pageKey, handlerView.getViewName(), true, false);

      this.startingPageKey = pageKey;
      this.lastVisibleContext = trackingContext;
      try {
        await this.startAutomaticView(toName, handlerView, pageKey);
      } finally {
        if (this.startingPageKey === pageKey) {
          this.startingPageKey = '';
        }
      }
      return;
    }
  }

  private async restoreVisibleRouterPage(uiContext: UIContext, onForeground: boolean = false): Promise<void> {
    if (!this.inited || (!onForeground && (this.routerShowObserved || this.currentRouteName.length > 0))) {
      return;
    }
    try {
      const state = uiContext.getRouter().getState();
      if (!state || !state.name || state.name.length === 0) {
        return;
      }
      // getState supplies the current page but no RouterPageInfo event. Its
      // name is the page file (Index); path can be only the directory (pages).
      // Supply both to the same filtering/naming path used by state=2.
      const pageInfo = {
        context: uiContext,
        index: state.index,
        name: state.name,
        path: state.path,
        state: 2,
        pageId: ''
      } as uiObserver.RouterPageInfo;
      await this.handleSwitchRouter(pageInfo);
    } catch (error) {
      FTInnerLogger.d(TAG, `Current Router page is not available for View recovery: ${String(error)}`);
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
    const context = this.createRouterTrackingContext(routeName, originalRouteName, routerPageInfo);
    return this.resolveAutomaticViewHandler(FTViewTrackingType.ROUTER, routeName, context, 'Router');
  }

  private createRouterTrackingContext(
    routeName: string,
    originalRouteName: string,
    routerPageInfo: uiObserver.RouterPageInfo
  ): FTViewTrackingContext {
    return {
      trackingType: FTViewTrackingType.ROUTER,
      routerPageInfo,
      originalViewName: originalRouteName,
      viewName: routeName,
      originalFromViewName: '',
      fromViewName: '',
      routerPageState: routerPageInfo.state
    };
  }

  /**
   * Uses the configured Navigation handler when present. Without a handler,
   * keep the existing automatic behavior and collect the normalized name.
   */
  private createNavigationTrackingContext(
    destinationName: string,
    originalDestinationName: string,
    navigationInfo: uiObserver.NavDestinationSwitchInfo
  ): FTViewTrackingContext {
    const originalFromName = this.getNavName(navigationInfo.from);
    const fromName = this.normalizeViewName(originalFromName);
    return {
      trackingType: FTViewTrackingType.NAVIGATION,
      navigationInfo,
      originalViewName: originalDestinationName,
      viewName: destinationName,
      originalFromViewName: originalFromName,
      fromViewName: fromName
    };
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

  /** Record Router load time by page instance, even for same-named pages. */
  private recordRouterViewLoadTime(pageKey: string, viewName: string, allowFallback: boolean,
    updateActiveView: boolean): void {
    const createStartTime = this.pageCreateStartTimeMap.get(pageKey);
    if (createStartTime !== undefined) {
      const loadTime = Utils.getCurrentNanoTime() - createStartTime;
      this.pageCreateStartTimeMap.delete(pageKey);
      FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(viewName, loadTime, updateActiveView);
      return;
    }

    let resumeStartTime = this.pageResumeStartTimeMap.get(pageKey);
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

    this.pageResumeStartTimeMap.delete(pageKey);
    const loadTime = Utils.getCurrentNanoTime() - resumeStartTime;
    const resumeKey = `${viewName}_resume`;
    FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(resumeKey, loadTime, updateActiveView);
  }

  /**
   * Transitions the automatic View state to a Router page or Navigation
   * destination. A null HandlerView closes the prior tracked View and
   * deliberately starts no replacement View.
   */
  private async startAutomaticView(routeName: string, handlerView: HandlerView | null, pageKey: string): Promise<void> {
    const rum = FTRUMGlobalManager.getInstance();
    try {
      if (this.currentViewName.length > 0 &&
        FTRUMInnerManager.getInstance().getActiveView()?.getId() === this.currentViewId) {
        await rum.stopView();
      }
    } catch (e) {
      FTInnerLogger.w(TAG, `stopView failed: ${e}`);
    }

    this.currentViewName = '';
    this.currentViewId = '';
    this.currentRouteName = '';
    this.currentPageKey = '';
    this.pageResumeStartTimeMap.delete('_pending_resume');

    if (handlerView === null) {
      FTInnerLogger.d(TAG, `automatic View filtered: ${routeName}`);
      return;
    }

    try {
      const property = this.copyViewProperty(handlerView.getProperty());
      await rum.startView(handlerView.getViewName(), property);
      this.currentViewName = handlerView.getViewName();
      this.currentViewId = FTRUMInnerManager.getInstance().getActiveView()?.getId() ?? '';
      this.currentRouteName = routeName;
      this.currentPageKey = pageKey;
    } catch (e) {
      FTInnerLogger.w(TAG, `startView failed: ${e}`);
    }
  }

  /** Resume the visible page after a lifecycle stop without a route change. */
  public resumeAutomaticViewOnForeground(shouldResume?: () => boolean): Promise<void> {
    // A WindowStage rebind and Router callbacks also use this queue. Resume
    // only after them, so an old window cannot recreate a stale page View.
    this.automaticViewEventQueue = this.automaticViewEventQueue.then(() => {
      if (!shouldResume || shouldResume()) {
        return this.resumeAutomaticViewOnForegroundInternal();
      }
      return Promise.resolve();
    }).catch((error: Error) => {
      FTInnerLogger.w(TAG, `Foreground View recovery failed: ${error}`);
    });
    return this.automaticViewEventQueue;
  }

  private async resumeAutomaticViewOnForegroundInternal(): Promise<void> {
    if (!this.inited || !this.rumConfig?.isEnableTraceUserView() ||
      this.foregroundResumeInProgress || this.startingPageKey.length > 0) {
      return;
    }
    const activeView = FTRUMInnerManager.getInstance().getActiveView();
    // A manual View may have replaced the automatic one. Leave it to its owner.
    if (activeView && (!activeView.isClose() ||
      (this.currentViewId.length > 0 && activeView.getId() !== this.currentViewId))) {
      return;
    }
    if (!this.lastVisibleContext) {
      // An observer may have been attached after the page was shown, or its
      // context may have been released with a destroyed WindowStage. Router
      // does not replay that page's state=2 event when the app resumes.
      if (this.observedUIContext) {
        await this.restoreVisibleRouterPage(this.observedUIContext, true);
      }
      return;
    }
    this.foregroundResumeInProgress = true;
    try {
      const context = this.lastVisibleContext;
      const source = context.trackingType === FTViewTrackingType.ROUTER ? 'Router' : 'Navigation';
      const handlerView = this.resolveAutomaticViewHandler(context.trackingType, context.viewName, context, source);
      if (handlerView === null) {
        this.currentViewName = '';
        this.currentViewId = '';
        this.currentRouteName = '';
        this.currentPageKey = '';
        return;
      }
      await FTRUMGlobalManager.getInstance().startView(handlerView.getViewName(),
        this.copyViewProperty(handlerView.getProperty()));
      this.currentViewName = handlerView.getViewName();
      this.currentViewId = FTRUMInnerManager.getInstance().getActiveView()?.getId() ?? '';
      this.currentRouteName = context.viewName;
      this.currentPageKey = context.trackingType === FTViewTrackingType.ROUTER
        ? this.getRouterPageKey(context.routerPageInfo, context.viewName)
        : this.getNavigationPageKey(context.navigationInfo, context.originalViewName);
      this.pageResumeStartTimeMap.delete('_pending_resume');
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to resume automatic View: ${error}`);
    } finally {
      this.foregroundResumeInProgress = false;
    }
  }

  private copyViewProperty(property: Record<string, object> | null): Record<string, object> {
    const copy: Record<string, object> = {};
    if (property) {
      const keys = Object.keys(property);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        copy[key] = property[key];
      }
    }
    return copy;
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
