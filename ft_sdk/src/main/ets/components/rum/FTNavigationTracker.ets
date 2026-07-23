import { UIContext, uiObserver } from '@kit.ArkUI';
import { FTRUMGlobalManager } from './FTRUMGlobalManager';
import { FTRUMInnerManager } from './FTRUMInnerManager';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMConfig } from '../Configs';
import { Utils } from '../utils/Utils';

const TAG = 'FTNavigationTracker';

export class FTNavigationTracker {
  private static instance: FTNavigationTracker | null = null;
  private uiContext: UIContext | null = null;
  private rumConfig: FTRUMConfig | null = null;
  private currentViewName: string = '';
  private lastSwitchTs: number = 0;
  private inited: boolean = false;
  // Track page creation start time for load time calculation
  // Map<viewName, startTime in nanoseconds>
  private pageCreateStartTimeMap: Map<string, number> = new Map();
  // Track page resume start time for returning pages (when page already exists)
  // Map<viewName, resumeStartTime in nanoseconds>
  // Used when returning to a previous page that was already created
  private pageResumeStartTimeMap: Map<string, number> = new Map();

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
    this.uiContext = uiContext;
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

    observer.on('navDestinationSwitch', (info: uiObserver.NavDestinationSwitchInfo) => {
      this.handleSwitchNav(info);
    });

    observer.on('routerPageUpdate', (info: uiObserver.RouterPageInfo) => {
      this.handleSwitchRouter(info);
    });

    this.inited = true;
  }

  public destroy(): void {
    this.uiContext = null;
    this.rumConfig = null;
    this.currentViewName = '';
    this.lastSwitchTs = 0;
    this.inited = false;
    this.pageCreateStartTimeMap.clear();
    this.pageResumeStartTimeMap.clear();
  }

  private async handleSwitchNav(info: uiObserver.NavDestinationSwitchInfo): Promise<void> {
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!this.rumConfig || !this.rumConfig.isEnableTraceUserView()) {
      return;
    }
    
    const now = Date.now();
    // simple debounce to merge duplicate events
    if (now - this.lastSwitchTs < 80) {
      return;
    }
    this.lastSwitchTs = now;

    const fromNameRaw: string = this.getNavName(info.from) || (this.currentViewName ? this.currentViewName : '');
    const toNameRaw: string = this.getNavName(info.to);
    
    // Normalize view names: convert route paths to page names
    const fromName: string = this.normalizeViewName(fromNameRaw);
    let toName: string = this.normalizeViewName(toNameRaw);

    if (!toName || toName.length === 0) {
      return;
    }

    if (this.currentViewName === toName) {
      return;
    }

    // Check if this is a returning page (page already exists, no creation start time)
    // If so, record resume start time for load time calculation
    // Aligned with Android: when returning to a previous Activity, onActivityResumed is called
    // and we need to measure the time from resume to shown
    const createStartTime = this.pageCreateStartTimeMap.get(toName);
    if (!createStartTime) {
      // This is likely a returning page (page already exists)
      // Record resume start time for load time calculation
      const resumeStartTime = Utils.getCurrentNanoTime();
      this.pageResumeStartTimeMap.set(toName, resumeStartTime);
    }

    const rum = FTRUMGlobalManager.getInstance();
    try {
      // stop previous view if exists
      if (this.currentViewName && this.currentViewName.length > 0) {
        await rum.stopView();
      }
    } catch (e) {
      FTInnerLogger.w(TAG, `stopView failed: ${e}`);
    }

    try {
      await rum.startView(toName);
      this.currentViewName = toName;
    } catch (e) {
      FTInnerLogger.w(TAG, `startView failed: ${e}`);
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

  private async handleSwitchRouter(info: uiObserver.RouterPageInfo): Promise<void> {
    // Check if view tracking is enabled (aligned with Android: FTActivityLifecycleCallbacks.onActivityResumed)
    if (!this.rumConfig || !this.rumConfig.isEnableTraceUserView()) {
      return;
    }
    
    const fromName: string = this.currentViewName ? this.currentViewName : '';
    let toName: string = info.name ? info.name : '';

    if (!toName || toName.length === 0) {
      return;
    }

    // Normalize view name: convert route path (e.g., "pages/ActionTestPage") to page name (e.g., "ActionTestPage")
    // This ensures consistency with manual startView calls that use page names
    toName = this.normalizeViewName(toName);

    // Handle state=0 (page created) - record creation start time for load time calculation
    // Aligned with Android: FTFragmentLifecycleHelper.onFragmentPreAttached records start time
    if (info.state === 0) {
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
      if (toName === this.currentViewName) {
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
      // Get the public RUM manager for view lifecycle reporting.
      const rum = FTRUMGlobalManager.getInstance();
      
      const createStartTime = this.pageCreateStartTimeMap.get(toName);
      if (createStartTime) {
        // New page creation: calculate load time from creation (state=0) to shown (state=2)
        const loadTime = Utils.getCurrentNanoTime() - createStartTime;
        this.pageCreateStartTimeMap.delete(toName);
        
        // Record load time through the SDK-internal automatic tracking entry point.
        FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(toName, loadTime);
      } else {
        // No creation start time found - this happens when:
        // 1. Returning to a previous page (page already exists, no state=0 event)
        // 2. Page creation event was missed or cleared
        // 
        // For returning pages, check if we have a resume start time (recorded in handleSwitchNav, state=3/4, or earlier state=2)
        // Aligned with Android: when returning to a previous Activity, onActivityResumed is called
        // and we need to measure the time from resume to shown
        let resumeStartTime = this.pageResumeStartTimeMap.get(toName);
        
        // If no resume start time for this specific page, check for pending resume time (from state=3/4 pushBack)
        if (!resumeStartTime) {
          const pendingResumeTime = this.pageResumeStartTimeMap.get('_pending_resume');
          if (pendingResumeTime) {
            // Use the pending resume time (recorded when pushBack started in state=3/4)
            resumeStartTime = pendingResumeTime;
            this.pageResumeStartTimeMap.delete('_pending_resume');
            // Store it with the page name for future reference
            this.pageResumeStartTimeMap.set(toName, resumeStartTime);
          } else {
            // No resume start time found - this happens when:
            // 1. handleSwitchNav was not called (only handleSwitchRouter was called)
            // 2. Resume start time was cleared or missed
            // 3. State=3/4 was not triggered or detected
            // 
            // Record current time as resume start (approximation)
            // In practice, resume should start slightly before state=2, but this is the best we can do
            // We'll use a small default loadTime to approximate the time from resume to shown
            resumeStartTime = Utils.getCurrentNanoTime();
            this.pageResumeStartTimeMap.set(toName, resumeStartTime);
          }
        }
        
        // Calculate load time from resume start to shown
        const loadTime = Utils.getCurrentNanoTime() - resumeStartTime;
        this.pageResumeStartTimeMap.delete(toName);
        
        // Record load time with resume key (aligned with Android's resume time handling)
        // Use resume key format: {viewName}_resume
        // getViewLoadTime() will prioritize resume key over create key
        const resumeKey = `${toName}_resume`;
        FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(resumeKey, loadTime);
      }
      
      // Continue with normal view start logic
      const now = Date.now();
      if (now - this.lastSwitchTs < 80) {
        return;
      }
      this.lastSwitchTs = now;

      if (this.currentViewName === toName) {
        return;
      }

      try {
        if (this.currentViewName && this.currentViewName.length > 0) {
          await rum.stopView();
        }
      } catch (e) {
        FTInnerLogger.w(TAG, `stopView failed: ${e}`);
      }

      try {
        await rum.startView(toName);
        this.currentViewName = toName;
      } catch (e) {
        FTInnerLogger.w(TAG, `startView failed: ${e}`);
      }
      return;
    }
  }

  /**
   * Normalize view name by converting route path to page name
   * Examples:
   *   "pages/ActionTestPage" -> "ActionTestPage"
   *   "pages/Index" -> "Index"
   *   "ActionTestPage" -> "ActionTestPage" (no change)
   * @param viewName Original view name (may be route path or page name)
   * @returns Normalized view name (page name)
   */
  private normalizeViewName(viewName: string): string {
    if (!viewName || viewName.length === 0) {
      return viewName;
    }
    
    // Remove "pages/" prefix if present
    if (viewName.startsWith('pages/')) {
      return viewName.substring(6); // Remove "pages/" (6 characters)
    }
    
    return viewName;
  }
}
