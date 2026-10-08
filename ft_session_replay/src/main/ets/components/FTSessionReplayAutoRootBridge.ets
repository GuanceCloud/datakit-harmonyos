import { UIContext } from '@kit.ArkUI';
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
  retryTimer: number;
}

export class FTSessionReplayAutoRootBridge {
  private static readonly MAX_LAYOUT_RETRIES: number = 16;
  private static readonly LAYOUT_RETRY_DELAY_MS: number = 16;
  private static readonly roots: Map<string, AutoReplayRoot> = new Map();
  private static nextToken: number = 0;
  private static nextShownOrder: number = 0;
  private static activeToken: string | null = null;

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
    vpToPxScale: number = 1
  ): void {
    FTSessionReplay.setAutoRootRefreshHandler(FTSessionReplayAutoRootBridge.refreshHandler);
    const entry = FTSessionReplayAutoRootBridge.upsert(uiContext, token, rootId, vpToPxScale);
    if (entry === null) {
      return;
    }
    entry.visible = true;
    FTSessionReplayAutoRootBridge.nextShownOrder++;
    entry.shownOrder = FTSessionReplayAutoRootBridge.nextShownOrder;
    // Never let a newly started RUM View snapshot the previous page while the
    // incoming root is waiting for its first non-zero layout measurement. The
    // recorder retains that View-start and retries it after activation.
    if (FTSessionReplayAutoRootBridge.activeToken !== null &&
      FTSessionReplayAutoRootBridge.activeToken !== entry.token) {
      FTSessionReplay.getInstance().unregisterRoot();
      FTSessionReplayAutoRootBridge.activeToken = null;
    }
    FTSessionReplayAutoRootBridge.activateWhenLaidOut(entry, 0);
  }

  /** Called by injected @Entry `onPageHide` code. */
  public static pageHidden(token: string): void {
    const entry = FTSessionReplayAutoRootBridge.roots.get(token);
    if (entry === undefined) {
      return;
    }
    entry.visible = false;
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
    FTSessionReplayAutoRootBridge.roots.delete(token);
    FTSessionReplayAutoRootBridge.activateMostRecentVisibleRoot();
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

  private static readonly refreshHandler = (): void => FTSessionReplayAutoRootBridge.refresh();

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
      retryTimer: -1
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
      if (FTSessionReplayAutoRootBridge.activeToken !== null) {
        FTSessionReplay.getInstance().unregisterRoot();
        FTSessionReplayAutoRootBridge.activeToken = null;
      }
      return;
    }
    FTSessionReplayAutoRootBridge.activateWhenLaidOut(candidate, 0);
  }

  private static activateWhenLaidOut(entry: AutoReplayRoot, attempt: number): void {
    FTSessionReplayAutoRootBridge.cancelRetry(entry);
    if (!entry.visible || FTSessionReplayAutoRootBridge.roots.get(entry.token) !== entry) {
      return;
    }
    const replay = FTSessionReplay.getInstance();
    if (!replay.isEnabled()) {
      return;
    }

    let isLaidOut = false;
    try {
      const root = entry.uiContext.getFrameNodeById(entry.rootId);
      if (root !== null && root.isAttached()) {
        const size = root.getMeasuredSize();
        isLaidOut = Number.isFinite(size.width) && Number.isFinite(size.height) &&
          size.width > 0 && size.height > 0;
      }
    } catch (_) {
      isLaidOut = false;
    }

    if (isLaidOut) {
      replay.registerRoot(entry.uiContext, entry.rootId, entry.vpToPxScale);
      FTSessionReplayAutoRootBridge.activeToken = entry.token;
      replay.notifyTransition();
      return;
    }
    if (attempt >= FTSessionReplayAutoRootBridge.MAX_LAYOUT_RETRIES) {
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
}
