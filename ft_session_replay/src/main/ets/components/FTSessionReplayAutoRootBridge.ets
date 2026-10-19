import { FrameNode, UIContext } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { ArkUIReplayDefaultTransition, ArkUIReplayScenePage } from './SessionReplayScene';
import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { FTSessionReplay } from './FTSessionReplay';

/**
 * Runtime endpoint for the Hvigor Replay page-root transform.
 *
 * The compiler adds a tiny marker to each @Entry page.  This class owns the
 * mutable part of that instrumentation so pages never compete to call
 * `registerRoot()` themselves.  A page becomes eligible only after it is
 * shown and its generated (or pre-existing) root has a non-zero layout.
 */
interface AutoReplayRoot {
  token: string;
  uiContext: UIContext;
  rootId: string;
  vpToPxScale: number;
  visible: boolean;
  generation: number;
  shownOrder: number;
  paintOrder: number;
  routerIndex: number;
  retryTimer: number;
  sceneTimer: number;
  retainedUntil: number;
  disposed: boolean;
  layoutWarningGeneration: number;
  frameNode: FrameNode | null;
  exitProgressKnown: boolean;
  exitCompleted: boolean;
  defaultTransitionPending: boolean;
  defaultTransition: ArkUIReplayDefaultTransition | null;
  defaultTimer: number;
}

interface AutoReplayTransition {
  slide?: SlideEffect;
  opacity?: number;
}

export class FTSessionReplayAutoRootBridge {
  private static readonly MAX_LAYOUT_RETRIES: number = 16;
  private static readonly LAYOUT_RETRY_DELAY_MS: number = 16;
  private static readonly EXIT_WATCHDOG_MS: number = 10000;
  private static readonly UNKNOWN_EXIT_GRACE_MS: number = 1000;
  private static readonly DEFAULT_TRANSITION_MS: number = 450;
  private static readonly roots: Map<string, AutoReplayRoot> = new Map();
  private static nextToken: number = 0;
  private static nextShownOrder: number = 0;
  private static nextPaintOrder: number = 0;
  private static activeToken: string | null = null;
  private static releaseTimer: number = -1;
  private static readonly transitions: Map<string, AutoReplayTransition> = new Map();

  /** Creates an opaque per-page-instance identifier without exposing file paths. */
  public static createRootToken(sourceKey: string): string {
    FTSessionReplayAutoRootBridge.nextToken++;
    const normalized = sourceKey.trim().length === 0 ? 'page' : sourceKey.trim();
    return `ft-replay:${normalized}:${FTSessionReplayAutoRootBridge.nextToken}`;
  }

  /** Called by injected @Entry `onPageShow` code. */
  public static pageShown(
    uiContext: UIContext,
    token: string,
    rootId: string,
    vpToPxScale: number = 1,
    observeDefaultTransition: boolean = false
  ): void {
    FTSessionReplay.setAutoRootRefreshHandler(FTSessionReplayAutoRootBridge.refreshHandler);
    FTSessionReplay.setAutoRootTransitionEndHandler(FTSessionReplayAutoRootBridge.finishHandler);
    const entry = FTSessionReplayAutoRootBridge.upsert(uiContext, token, rootId, vpToPxScale);
    if (entry === null) {
      return;
    }
    entry.visible = true;
    entry.disposed = false;
    entry.layoutWarningGeneration = -1;
    entry.retainedUntil = 0;
    entry.exitProgressKnown = false;
    entry.exitCompleted = false;
    FTSessionReplayAutoRootBridge.cancelDefaultTransition(entry);
    FTSessionReplayAutoRootBridge.updateRouterIndex(entry);
    FTSessionReplay.getInstance().finishPageTransition(entry.token);
    FTSessionReplayAutoRootBridge.cancelSceneTimer(entry);
    FTSessionReplayAutoRootBridge.cancelRelease();
    FTSessionReplayAutoRootBridge.nextShownOrder++;
    entry.shownOrder = FTSessionReplayAutoRootBridge.nextShownOrder;
    // Keep the shared scene attached while the incoming page is laying out;
    // it contains both outgoing and incoming pages during the transition.
    // Wait one layout boundary for the native default start hook. A returning
    // page already has a layout: binding it immediately can persist B's final
    // position before ArkUI starts its animation. Non-animated shows still bind.
    entry.defaultTransitionPending = observeDefaultTransition;
    if (observeDefaultTransition) {
      FTSessionReplayAutoRootBridge.cancelRetry(entry);
      const generation = entry.generation;
      entry.retryTimer = setTimeout((): void => {
        entry.retryTimer = -1;
        if (entry.generation !== generation || !entry.visible) return;
        entry.defaultTransitionPending = false;
        FTSessionReplayAutoRootBridge.activateWhenLaidOut(entry, 0);
      }, FTSessionReplayAutoRootBridge.LAYOUT_RETRY_DELAY_MS);
    } else FTSessionReplayAutoRootBridge.activateWhenLaidOut(entry, 0);
  }

  /** Called by injected @Entry `onPageHide` code. */
  public static pageHidden(token: string): void {
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry === undefined) {
      return;
    }
    entry.visible = false;
    entry.defaultTransitionPending = false;
    FTSessionReplayAutoRootBridge.retainDepartingPage(entry);
    if (FTSessionReplayAutoRootBridge.activeToken === entry.token) {
      FTSessionReplay.getInstance().notifyTransition();
    }
    entry.generation++;
    FTSessionReplayAutoRootBridge.cancelRetry(entry);
    FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
  }

  /** Called by injected @Entry `aboutToDisappear` code. */
  public static pageDisposed(token: string): void {
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry === undefined) {
      return;
    }
    entry.generation++;
    FTSessionReplayAutoRootBridge.cancelRetry(entry);
    entry.visible = false;
    entry.disposed = true;
    const defaultExiting = entry.defaultTransition !== null && !entry.defaultTransition.entering &&
      Date.now() < entry.defaultTransition.startedAt + entry.defaultTransition.durationMs;
    if ((!entry.exitProgressKnown && !defaultExiting) || entry.exitCompleted) {
      // Keep detached content only while actual exit progress or the bounded
      // default reconstruction still owns it.
      FTSessionReplay.getInstance().finishPageTransition(entry.token);
      return;
    }
    FTSessionReplayAutoRootBridge.retainDepartingPage(entry);
    FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
  }

  /** Always false: a declarative condition observes start without adding effects. */
  public static defaultTransitionStarted(token: string): boolean {
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry === undefined || !FTSessionReplay.getInstance().isEnabled()) return false;
    let other: AutoReplayRoot | null = null;
    const now = Date.now();
    FTSessionReplayAutoRootBridge.roots.forEach((candidate: AutoReplayRoot): void => {
      if (candidate.token !== token && candidate.visible !== entry.visible &&
        (candidate.visible || candidate.retainedUntil > now) &&
        FTSessionReplayAutoRootBridge.sameWindow(candidate.uiContext, entry.uiContext) &&
        (other === null || candidate.shownOrder > other.shownOrder)) other = candidate;
    });
    if (other === null) return false;
    const incoming = entry.visible ? entry : other;
    const outgoing = entry.visible ? other : entry;
    if (incoming.routerIndex <= 0 || outgoing.routerIndex <= 0) return false;
    const pop = outgoing.routerIndex > incoming.routerIndex;
    let rtl = false;
    try { rtl = i18n.isRTL(i18n.System.getSystemLanguage()); } catch (_) { }
    const foreground = entry.visible ? !pop : pop;
    FTSessionReplayAutoRootBridge.cancelDefaultTransition(entry);
    entry.defaultTransitionPending = false;
    entry.defaultTransition = {
      entering: entry.visible, startedAt: now,
      durationMs: FTSessionReplayAutoRootBridge.DEFAULT_TRANSITION_MS,
      translateXRatio: foreground ? (rtl ? -0.2 : 0.5) : (rtl ? 0.5 : -0.2)
    };
    if (!entry.visible) {
      FTSessionReplayAutoRootBridge.cancelSceneTimer(entry);
      entry.retainedUntil = now + FTSessionReplayAutoRootBridge.DEFAULT_TRANSITION_MS;
    }
    entry.defaultTimer = setTimeout((): void => {
      entry.defaultTimer = -1;
      entry.defaultTransition = null;
      if (!entry.visible) FTSessionReplay.getInstance().finishPageTransition(entry.token);
      else FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
    }, FTSessionReplayAutoRootBridge.DEFAULT_TRANSITION_MS);
    // Register the incoming root with its start metadata before its first View
    // snapshot. This hook does not create or modify a native animation effect.
    FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
    FTSessionReplay.getInstance().notifyTransition();
    return false;
  }

  /**
   * Allows a startup switch to activate a page that was already visible when
   * Replay was enabled. The compiler normally reaches this through a fresh
   * page-show event, but exposing it keeps runtime configuration changes safe.
   */
  public static refresh(): void {
    FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
  }

  /** Called by compiler-injected root layout callbacks. */
  public static pageChanged(token: string): void {
    if (FTSessionReplayAutoRootBridge.activeToken === token) {
      FTSessionReplay.getInstance().notifyPageChanged();
      return;
    }
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry !== undefined && entry.visible) {
      // First layout can arrive after pageShown's retry window. Recheck on
      // the real ArkUI area-change signal so a slow cold start still binds.
      FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
    }
  }

  /** Available to generated Scroll/animation hooks without exposing a root id. */
  public static pageInMotion(token: string): void {
    if (FTSessionReplayAutoRootBridge.activeToken === token) {
      FTSessionReplay.getInstance().notifyScroll();
    }
  }

  /** TouchObject window coordinates are vp; the public recordTouch API takes px. */
  public static pageTouch(token: string, event: TouchEvent): void {
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    const active = FTSessionReplayAutoRootBridge.activeToken === null ? undefined :
      FTSessionReplayAutoRootBridge.roots.get(FTSessionReplayAutoRootBridge.activeToken);
    if (entry === undefined || active === undefined ||
      !FTSessionReplayAutoRootBridge.sameWindow(entry.uiContext, active.uiContext)) return;
    try {
      FTSessionReplay.getInstance().recordTouchEvent(event);
    } catch (_) { }
  }

  public static wrapTouch(token: string, handler: (event: TouchEvent) => void): (event: TouchEvent) => void {
    return (event: TouchEvent): void => {
      FTSessionReplayAutoRootBridge.pageTouch(token, event);
      handler(event);
    };
  }

  /** Return the original modifier value; observing a transition never changes it. */
  public static transitionSlide(token: string, spec: string, slide: SlideEffect): SlideEffect {
    const key = `${token}:${spec}`;
    const transition = FTSessionReplayAutoRootBridge.transitions.get(key) ?? {};
    transition.slide = slide;
    FTSessionReplayAutoRootBridge.transitions.set(key, transition);
    return slide;
  }

  public static transitionOpacity(token: string, spec: string, opacity: number): number {
    const key = `${token}:${spec}`;
    const transition = FTSessionReplayAutoRootBridge.transitions.get(key) ?? {};
    transition.opacity = opacity;
    FTSessionReplayAutoRootBridge.transitions.set(key, transition);
    return opacity;
  }

  public static transitionProgress(token: string, rootId: string, spec: string,
    entering: boolean, progress: number): void {
    const transition = FTSessionReplayAutoRootBridge.transitions.get(`${token}:${spec}`);
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry !== undefined) FTSessionReplayAutoRootBridge.cancelDefaultTransition(entry);
    if (entry !== undefined && !entering) {
      entry.exitProgressKnown = true;
      entry.exitCompleted = progress >= 1;
    }
    FTSessionReplay.getInstance().updatePageTransition(rootId, entering, progress,
      transition?.slide, transition?.opacity, token);
    if (entry !== undefined && !entering) {
      if (progress >= 1) {
        // Completion owns release and scene refresh together. Releasing a
        // disposed entry first would hide it from finishHandler and leave
        // its detached frame in the recorder's scene binding indefinitely.
        FTSessionReplay.getInstance().finishPageTransition(token);
      } else {
        // Progress callbacks also cover custom transitions longer than 1 second.
        FTSessionReplayAutoRootBridge.retainDepartingPage(entry);
      }
    }
  }

  public static wrapTransition(token: string, rootId: string, spec: string, entering: boolean,
    handler: (type: RouteType, progress: number) => void): (type: RouteType, progress: number) => void {
    return (type: RouteType, progress: number): void => {
      FTSessionReplayAutoRootBridge.transitionProgress(token, rootId, spec, entering, progress);
      handler(type, progress);
    };
  }

  private static cancelRelease(): void {
    if (FTSessionReplayAutoRootBridge.releaseTimer !== -1) {
      clearTimeout(FTSessionReplayAutoRootBridge.releaseTimer);
      FTSessionReplayAutoRootBridge.releaseTimer = -1;
    }
  }

  private static readonly refreshHandler = (): void => FTSessionReplayAutoRootBridge.refresh();
  private static readonly finishHandler = (key: string): Array<string> => {
    const released: Array<string> = [];
    FTSessionReplayAutoRootBridge.roots.forEach((entry: AutoReplayRoot): void => {
      if ((entry.token === key || entry.rootId === key) && !entry.visible) {
        entry.exitCompleted = true;
        FTSessionReplayAutoRootBridge.releaseDepartingPage(entry);
        released.push(entry.token);
      }
    });
    if (released.length > 0) FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
    return released;
  };

  private static upsert(
    uiContext: UIContext,
    token: string,
    rootId: string,
    vpToPxScale: number
  ): AutoReplayRoot | null {
    const normalizedToken = token.trim();
    const normalizedRootId = rootId.trim();
    if (normalizedToken.length === 0 || normalizedRootId.length === 0) {
      return null;
    }
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    const existing = FTSessionReplayAutoRootBridge.roots.get(normalizedToken);
    if (existing !== undefined) {
      existing.uiContext = uiContext;
      existing.rootId = normalizedRootId;
      existing.vpToPxScale = scale;
      return existing;
    }
    const entry: AutoReplayRoot = {
      token: normalizedToken,
      uiContext,
      rootId: normalizedRootId,
      vpToPxScale: scale,
      visible: false,
      generation: 0,
      shownOrder: 0,
      paintOrder: ++FTSessionReplayAutoRootBridge.nextPaintOrder,
      routerIndex: 0,
      retryTimer: -1,
      sceneTimer: -1,
      retainedUntil: 0,
      disposed: false,
      layoutWarningGeneration: -1,
      frameNode: null,
      exitProgressKnown: false,
      exitCompleted: false,
      defaultTransitionPending: false,
      defaultTransition: null,
      defaultTimer: -1
    };
    FTSessionReplayAutoRootBridge.roots.set(normalizedToken, entry);
    return entry;
  }

  private static activateMostRecentVisibleRoot(): void {
    let candidate: AutoReplayRoot | null = null;
    FTSessionReplayAutoRootBridge.roots.forEach((entry: AutoReplayRoot): void => {
      if (entry.visible && (candidate === null || entry.shownOrder > candidate.shownOrder)) {
        candidate = entry;
      }
    });
    if (candidate === null) {
      const current = FTSessionReplayAutoRootBridge.activeToken === null ? undefined :
        FTSessionReplayAutoRootBridge.roots.get(FTSessionReplayAutoRootBridge.activeToken);
      if (current !== undefined && current.retainedUntil > Date.now()) {
        FTSessionReplay.getInstance().registerRoot(current.uiContext, current.rootId, current.vpToPxScale,
          true, [current.rootId], [{ key: current.token, rootId: current.rootId,
            root: current.frameNode, retained: true, paintOrder: current.paintOrder }]);
      }
      if (FTSessionReplayAutoRootBridge.activeToken !== null && FTSessionReplayAutoRootBridge.releaseTimer === -1) {
        // Router hide/show callbacks can straddle a frame. Do not detach the
        // scene between them; release only when no successor page arrives.
        FTSessionReplayAutoRootBridge.releaseTimer = setTimeout((): void => {
          FTSessionReplayAutoRootBridge.releaseTimer = -1;
          const now = Date.now();
          let retaining = false;
          FTSessionReplayAutoRootBridge.roots.forEach((entry: AutoReplayRoot): void => {
            if (entry.retainedUntil > now) retaining = true;
          });
          if (retaining) {
            FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
            return;
          }
          FTSessionReplay.getInstance().unregisterRoot();
          FTSessionReplayAutoRootBridge.activeToken = null;
        }, 1000);
      }
      return;
    }
    FTSessionReplayAutoRootBridge.activateWhenLaidOut(candidate, 0);
  }

  private static activateWhenLaidOut(entry: AutoReplayRoot, attempt: number): void {
    if (!entry.visible || entry.defaultTransitionPending || FTSessionReplayAutoRootBridge.roots.get(entry.token) !== entry) {
      return;
    }
    FTSessionReplayAutoRootBridge.cancelRetry(entry);
    const replay = FTSessionReplay.getInstance();
    if (!replay.isEnabled()) {
      return;
    }

    let isLaidOut = false;
    let layoutFailure: string = 'root_not_found';
    try {
      const root = entry.uiContext.getFrameNodeById(entry.rootId);
      if (root !== null && root.isAttached()) {
        const size = root.getMeasuredSize();
        isLaidOut = Number.isFinite(size.width) && Number.isFinite(size.height) &&
          size.width > 0 && size.height > 0;
        layoutFailure = `root_has_no_size(${size.width}x${size.height})`;
        if (isLaidOut) entry.frameNode = root;
      } else if (root !== null) {
        layoutFailure = 'root_not_attached';
      }
    } catch (error) {
      isLaidOut = false;
      layoutFailure = String(error);
    }

    if (isLaidOut) {
      FTSessionReplayAutoRootBridge.cancelRelease();
      const pages: Array<AutoReplayRoot> = [];
      const now = Date.now();
      FTSessionReplayAutoRootBridge.roots.forEach((page: AutoReplayRoot): void => {
        if ((page.visible || page.retainedUntil > now) &&
          FTSessionReplayAutoRootBridge.sameWindow(page.uiContext, entry.uiContext)) pages.push(page);
      });
      // A returning root may have been recreated after the outgoing root.
      // Router stack positions keep it underneath on pop; instance order
      // still orders replace operations and integrations without Router state.
      pages.sort((left: AutoReplayRoot, right: AutoReplayRoot): number => {
        if (left.routerIndex > 0 && right.routerIndex > 0 && left.routerIndex !== right.routerIndex) {
          return left.routerIndex - right.routerIndex;
        }
        return left.paintOrder - right.paintOrder;
      });
      replay.registerRoot(entry.uiContext, entry.rootId, entry.vpToPxScale, true,
        pages.map((page: AutoReplayRoot): string => page.rootId),
        pages.map((page: AutoReplayRoot): ArkUIReplayScenePage => {
          return { key: page.token, rootId: page.rootId, root: page.frameNode,
            retained: !page.visible && page.retainedUntil > now, paintOrder: page.paintOrder,
            defaultTransition: page.defaultTransition ?? undefined };
        }));
      if (FTSessionReplayAutoRootBridge.activeToken !== entry.token) {
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay root ready: root=${entry.rootId}, layoutRetries=${attempt}, scenePages=${pages.length}`);
      }
      FTSessionReplayAutoRootBridge.activeToken = entry.token;
      replay.notifyTransition();
      return;
    }
    if (attempt >= FTSessionReplayAutoRootBridge.MAX_LAYOUT_RETRIES) {
      if (entry.layoutWarningGeneration !== entry.generation) {
        entry.layoutWarningGeneration = entry.generation;
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay root layout unavailable: root=${entry.rootId}, layoutRetries=${attempt}, reason=${layoutFailure}`,
          true);
      }
      return;
    }
    const generation = entry.generation;
    entry.retryTimer = setTimeout((): void => {
      entry.retryTimer = -1;
      if (entry.generation === generation) {
        FTSessionReplayAutoRootBridge.activateWhenLaidOut(entry, attempt + 1);
      }
    }, FTSessionReplayAutoRootBridge.LAYOUT_RETRY_DELAY_MS);
  }

  private static cancelRetry(entry: AutoReplayRoot): void {
    if (entry.retryTimer >= 0) {
      clearTimeout(entry.retryTimer);
      entry.retryTimer = -1;
    }
  }

  private static updateRouterIndex(entry: AutoReplayRoot): void {
    try {
      const index = entry.uiContext.getRouter().getState().index;
      if (Number.isFinite(index) && index > 0) entry.routerIndex = index;
    } catch (_) { }
  }

  private static cancelSceneTimer(entry: AutoReplayRoot): void {
    if (entry.sceneTimer !== -1) {
      clearTimeout(entry.sceneTimer);
      entry.sceneTimer = -1;
    }
  }

  private static cancelDefaultTransition(entry: AutoReplayRoot): void {
    if (entry.defaultTimer !== -1) clearTimeout(entry.defaultTimer);
    entry.defaultTimer = -1;
    entry.defaultTransition = null;
  }

  private static retainDepartingPage(entry: AutoReplayRoot): void {
    FTSessionReplayAutoRootBridge.cancelSceneTimer(entry);
    if (entry.defaultTransition !== null && !entry.defaultTransition.entering) return;
    if (entry.exitCompleted) {
      // Completion can precede onPageHide. Use the same recorder cleanup
      // path when the later lifecycle callback finally marks it hidden.
      FTSessionReplay.getInstance().finishPageTransition(entry.token);
      return;
    }
    // Known progress owns normal release. The longer watchdog only bounds
    // memory if an interrupted application animation never calls its end.
    const delay = entry.exitProgressKnown ? FTSessionReplayAutoRootBridge.EXIT_WATCHDOG_MS :
      FTSessionReplayAutoRootBridge.UNKNOWN_EXIT_GRACE_MS;
    const now = Date.now();
    // Hide and disposal belong to the same default transition; disposal
    // must not extend its grace period by another second.
    entry.retainedUntil = !entry.exitProgressKnown && entry.retainedUntil > now ? entry.retainedUntil : now + delay;
    entry.sceneTimer = setTimeout((): void => {
      entry.sceneTimer = -1;
      FTSessionReplay.getInstance().finishPageTransition(entry.token);
    }, Math.max(0, entry.retainedUntil - now));
  }

  private static releaseDepartingPage(entry: AutoReplayRoot): void {
    FTSessionReplayAutoRootBridge.cancelSceneTimer(entry);
    FTSessionReplayAutoRootBridge.cancelDefaultTransition(entry);
    entry.retainedUntil = 0;
    entry.frameNode = null;
    if (entry.disposed) {
      FTSessionReplayAutoRootBridge.roots.delete(entry.token);
      const prefix = `${entry.token}:`;
      FTSessionReplayAutoRootBridge.transitions.forEach((_value: AutoReplayTransition, key: string): void => {
        if (key.startsWith(prefix)) FTSessionReplayAutoRootBridge.transitions.delete(key);
      });
    }
  }

  private static sameWindow(left: UIContext, right: UIContext): boolean {
    if (left === right) return true;
    try {
      const id = left.getWindowId();
      return id !== undefined && id === right.getWindowId();
    } catch (_) { return false; }
  }
}
