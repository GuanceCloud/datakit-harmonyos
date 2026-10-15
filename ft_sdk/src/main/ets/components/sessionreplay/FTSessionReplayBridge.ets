import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';
import { WebReplaySlotBinder, WebReplaySlotBinding, WebReplaySlotObservation } from './WebReplaySlotBinder';

const TAG = 'FTSessionReplayBridge';

/** Immutable RUM identity handed to an optional Session Replay HAR. */
export interface FTSessionReplayRUMContext {
  applicationId: string;
  sessionId: string;
  viewId: string;
  viewName: string;
  viewReferrer: string;
  linkContext: Record<string, string | number | boolean>;
  timestamp: number;
}

export interface FTSessionReplayErrorContext extends FTSessionReplayRUMContext {
  errorType: string;
  appState: string;
}

export interface FTSessionReplaySessionContext {
  applicationId: string;
  previousSessionId: string;
  sessionId: string;
  timestamp: number;
}

/**
 * A Browser SDK Replay record forwarded by the native WebView bridge.
 *
 * `payload` is deliberately kept as the Browser SDK's JSON record instead of
 * being converted into an ArkUI snapshot. The optional Replay HAR owns its
 * validation and persistence, while core supplies the trusted RUM linkage and
 * the observed native wireframe ID directly as the WebView slot ID.
 */
export interface FTSessionReplayWebDataContext {
  applicationId: string;
  sessionId: string;
  viewId: string;
  slotId: string;
  linkContext: Record<string, string | number | boolean>;
  payload: string;
  timestamp: number;
}

/** A Browser RUM Error that can promote an error-sampled Replay session. */
export interface FTSessionReplayWebErrorContext {
  applicationId: string;
  sessionId: string;
  viewId: string;
  slotId: string;
  linkContext: Record<string, string | number | boolean>;
  timestamp: number;
}

/**
 * A Browser RUM link-context change bound to its current native container
 * View.  The optional HAR uses this to place a fresh native snapshot at the
 * association boundary, matching Android's WebView rebind behavior.
 */
export interface FTSessionReplayWebContextChange extends FTSessionReplayRUMContext {
  browserViewId: string;
  slotId: string;
}

/** Browser SDK capabilities provided only while the optional Replay HAR runs. */
export interface FTSessionReplayWebViewOptions {
  privacyLevel: string;
  capabilities: Array<string>;
}

/** Replay availability state that core RUM persists with a View. */
export interface FTSessionReplayViewMetadata {
  hasReplay: boolean;
  recordsCount: number;
  sampledOnError: boolean;
  /** Identifies the enable/disable interval that actually saved these frames. */
  recordingId?: string;
}

interface FTSessionReplayRecordingInterval {
  id: string;
  startedAt: number;
  stoppedAt: number;
  views: Set<string>;
}

interface FTSessionReplayPendingPersistence {
  count: number;
  completion: Promise<void>;
  resolve: () => void;
}

/**
 * Optional Replay contract. The core SDK owns no recorder, storage, or upload
 * implementation. A HAR registers this bridge only when Replay is enabled.
 */
export interface FTSessionReplayBridge {
  /** Returns the RUM key fragments that the optional Replay HAR may receive. */
  getRUMLinkKeys(): Array<string>;
  getViewMetadata(context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata;
  onViewStarted(context: FTSessionReplayRUMContext): boolean;
  onViewStopped(context: FTSessionReplayRUMContext): void;
  onError(context: FTSessionReplayErrorContext): boolean;
  onSessionRenewed(context: FTSessionReplaySessionContext): void;
  /** Returns Browser SDK privacy/capability negotiation values. */
  getWebViewOptions?(): FTSessionReplayWebViewOptions | null;
  /** Receives one Browser SDK record, already associated with RUM identity. */
  onWebReplayData?(context: FTSessionReplayWebDataContext): boolean;
  /** Seals a buffered Browser batch before detach or another lifecycle boundary. */
  flushWebReplayData?(): boolean;
  /** Promotes Browser Replay data when a Browser RUM Error is reported. */
  onWebReplayError?(context: FTSessionReplayWebErrorContext): boolean;
  /** Promotes an error-sampled session when no live native root can be captured. */
  onErrorTimeline?(context: FTSessionReplayErrorContext): boolean;
  /** Forces a native snapshot when Browser RUM association data changes. */
  onWebReplayContextChanged?(context: FTSessionReplayWebContextChange): boolean;
  /** Marks a stable WebView slot active or inactive for delayed draining. */
  onWebReplaySlotActive?(slotId: string, active: boolean, timestamp: number): void;
  /** Enables the Browser SDK's periodic full snapshots for error sampling. */
  isWebReplayErrorSampled?(sessionId: string): boolean;
}

/** NoOp-by-default registry preventing any Replay cost for existing SDK users. */
export class FTSessionReplayBridgeRegistry {
  private static readonly webSlots: WebReplaySlotBinder = new WebReplaySlotBinder();
  private static readonly webSlotListeners: Map<string, () => void> = new Map();
  private static webAppForeground: boolean = true;

  public static registerWebReplayComponent(componentId: string): boolean {
    return FTSessionReplayBridgeRegistry.webSlots.register(componentId);
  }

  public static unregisterWebReplayComponent(componentId: string): void {
    FTSessionReplayBridgeRegistry.flushWebReplayData();
    FTSessionReplayBridgeRegistry.webSlots.unregister(componentId);
    FTSessionReplayBridgeRegistry.webSlotListeners.delete(componentId);
  }

  public static setWebReplaySlotListener(componentId: string, listener: () => void): void {
    if (FTSessionReplayBridgeRegistry.webSlots.getComponent(componentId) !== null) {
      FTSessionReplayBridgeRegistry.webSlotListeners.set(componentId, listener);
    }
  }

  public static acceptsWebReplayData(slotId: string, applicationId: string, sessionId: string,
    timestamp: number): boolean {
    return FTSessionReplayBridgeRegistry.webAppForeground && FTSessionReplayBridgeRegistry.bridge !== null &&
      FTSessionReplayBridgeRegistry.webSlots.accepts(slotId, applicationId, sessionId, timestamp);
  }

  public static isWebReplaySlotActive(slotId: string): boolean {
    return FTSessionReplayBridgeRegistry.webAppForeground && FTSessionReplayBridgeRegistry.bridge !== null &&
      FTSessionReplayBridgeRegistry.webSlots.get(slotId)?.active === true &&
      FTSessionReplayBridgeRegistry.webSlots.getLatestSlotId() === slotId;
  }

  public static setWebReplayAppForeground(foreground: boolean): void {
    if (FTSessionReplayBridgeRegistry.webAppForeground === foreground) return;
    FTSessionReplayBridgeRegistry.webAppForeground = foreground;
    if (!foreground) FTSessionReplayBridgeRegistry.flushWebReplayData();
    FTSessionReplayBridgeRegistry.webSlotListeners.forEach((listener): void => listener());
  }

  public static getWebReplaySlotId(componentId: string): string {
    return FTSessionReplayBridgeRegistry.webSlots.getSlotId(componentId);
  }

  public static getWebReplaySlotBinding(slotId: string): WebReplaySlotBinding | null {
    return FTSessionReplayBridgeRegistry.webSlots.get(slotId);
  }

  public static getWebReplayComponentBinding(componentId: string): WebReplaySlotBinding | null {
    return FTSessionReplayBridgeRegistry.webSlots.getComponent(componentId);
  }

  public static getLatestWebReplaySlotId(): string {
    return FTSessionReplayBridgeRegistry.webSlots.getLatestSlotId();
  }

  public static observeWebReplaySlots(applicationId: string, sessionId: string, viewId: string,
    visibleSlots: Array<WebReplaySlotObservation>, timestamp: number): void {
    const previousLatest = FTSessionReplayBridgeRegistry.webSlots.getLatestSlotId();
    const previous: Map<string, WebReplaySlotBinding> = new Map();
    for (const componentId of FTSessionReplayBridgeRegistry.webSlots.getComponentIds()) {
      const binding = FTSessionReplayBridgeRegistry.webSlots.getComponent(componentId);
      if (binding !== null) previous.set(componentId, binding);
    }
    FTSessionReplayBridgeRegistry.webSlots.observe(applicationId, sessionId, viewId, visibleSlots, timestamp);
    const latest = FTSessionReplayBridgeRegistry.webSlots.getLatestSlotId();
    previous.forEach((before, componentId): void => {
      const after = FTSessionReplayBridgeRegistry.webSlots.getComponent(componentId);
      if (after === null || (before.active === after.active && before.viewId === after.viewId &&
        before.sessionId === after.sessionId && before.applicationId === after.applicationId &&
        before.slotId === after.slotId && previousLatest === latest)) return;
      FTSessionReplayBridgeRegistry.flushWebReplayData();
      if (before.slotId.length > 0 && before.slotId !== after.slotId) {
        FTSessionReplayBridgeRegistry.notifyWebReplaySlotActive(before.slotId, false, timestamp);
      }
      if (after.slotId.length > 0) {
        FTSessionReplayBridgeRegistry.notifyWebReplaySlotActive(after.slotId, after.active && latest === after.slotId, timestamp);
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay Web binding: component=${componentId}, wireframeId=${after.slotId}, slot=${after.slotId}, view=${after.viewId}, active=${after.active && latest === after.slotId}`);
      }
      // Enqueue the native frame before requesting a rebind Full Snapshot.
      const listener = FTSessionReplayBridgeRegistry.webSlotListeners.get(componentId);
      if (listener !== undefined) setTimeout((): void => {
        if (FTSessionReplayBridgeRegistry.webSlotListeners.get(componentId) === listener) listener();
      }, 0);
    });
  }
  private static bridge: FTSessionReplayBridge | null = null;
  private static currentViewProvider: (() => FTSessionReplayRUMContext | null) | null = null;
  private static metadataChangedCallback:
    ((context: FTSessionReplayRUMContext, metadata: FTSessionReplayViewMetadata) => void) | null = null;
  private static readonly MAX_PENDING_ERROR_TIMELINES: number = 8;
  /** Holds crash recovery notifications until an optional HAR registers. */
  private static pendingErrorTimelines: Array<FTSessionReplayErrorContext> = [];
  // Capture and core metadata writes share this lifetime, including accepted
  // work finishing after the optional HAR unregisters on stop.
  private static readonly pendingPersistence: Map<string, FTSessionReplayPendingPersistence> = new Map();
  private static persistenceEpoch: number = 0;
  // Actions persist their interval ID, not this history. Bound history for
  // callers that submit an Action later with its original occurrence time.
  private static readonly MAX_RECORDING_INTERVALS: number = 128;
  private static recordingSequence: number = 0;
  private static recordingIntervals: Array<FTSessionReplayRecordingInterval> = [];
  private static activeRecording: FTSessionReplayRecordingInterval | null = null;

  /** Empty means the event occurred outside every known recording interval. */
  public static getActionRecordingId(timestamp: number): string {
    if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
    const intervals = FTSessionReplayBridgeRegistry.recordingIntervals;
    for (let index = intervals.length - 1; index >= 0; index--) {
      const interval = intervals[index];
      if (timestamp >= interval.startedAt && (interval.stoppedAt === 0 || timestamp < interval.stoppedAt)) {
        return interval.id;
      }
    }
    return '';
  }

  /** A previous recording of the same View cannot make a new interval available. */
  public static hasReplayForRecording(
    applicationId: string, sessionId: string, viewId: string, recordingId: string
  ): boolean {
    if (recordingId.length === 0) return false;
    const key = FTSessionReplayBridgeRegistry.persistenceKey(applicationId, sessionId, viewId);
    return FTSessionReplayBridgeRegistry.recordingIntervals.some(
      (interval: FTSessionReplayRecordingInterval): boolean => interval.id === recordingId && interval.views.has(key));
  }

  /** Holds the original View until one accepted write finishes or fails. */
  public static beginViewPersistence(context: FTSessionReplayRUMContext): () => void {
    const key = FTSessionReplayBridgeRegistry.persistenceKey(context.applicationId, context.sessionId, context.viewId);
    let pending = FTSessionReplayBridgeRegistry.pendingPersistence.get(key);
    if (pending === undefined) {
      let complete = (): void => {};
      const completion = new Promise<void>((resolve: () => void): void => { complete = resolve; });
      pending = { count: 0, completion, resolve: complete };
      FTSessionReplayBridgeRegistry.pendingPersistence.set(key, pending);
    }
    const entry = pending;
    entry.count++;
    let finished = false;
    return (): void => {
      if (finished) return;
      finished = true;
      if (FTSessionReplayBridgeRegistry.pendingPersistence.get(key) !== entry) return;
      entry.count--;
      if (entry.count === 0) {
        FTSessionReplayBridgeRegistry.pendingPersistence.delete(key);
        entry.resolve();
      }
    };
  }

  public static hasPendingViewPersistence(applicationId: string, sessionId: string, viewId: string): boolean {
    const key = FTSessionReplayBridgeRegistry.persistenceKey(applicationId, sessionId, viewId);
    return FTSessionReplayBridgeRegistry.pendingPersistence.has(key);
  }

  /** Waits for storage and its RUM metadata update, without implying Replay. */
  public static async waitForViewPersistence(applicationId: string, sessionId: string, viewId: string): Promise<void> {
    const key = FTSessionReplayBridgeRegistry.persistenceKey(applicationId, sessionId, viewId);
    const epoch = FTSessionReplayBridgeRegistry.persistenceEpoch;
    let pending = FTSessionReplayBridgeRegistry.pendingPersistence.get(key);
    while (pending !== undefined && epoch === FTSessionReplayBridgeRegistry.persistenceEpoch) {
      await pending.completion;
      pending = FTSessionReplayBridgeRegistry.pendingPersistence.get(key);
    }
  }

  private static persistenceKey(applicationId: string, sessionId: string, viewId: string): string {
    return `${applicationId}|${sessionId}|${viewId}`;
  }

  public static register(bridge: FTSessionReplayBridge): string {
    if (FTSessionReplayBridgeRegistry.bridge === bridge) {
      return FTSessionReplayBridgeRegistry.activeRecording?.id ?? '';
    }
    const timestamp = Utils.getCurrentNanoTime();
    const previous = FTSessionReplayBridgeRegistry.activeRecording;
    if (previous !== null) previous.stoppedAt = timestamp;
    const interval: FTSessionReplayRecordingInterval = {
      id: `${timestamp}:${++FTSessionReplayBridgeRegistry.recordingSequence}`,
      startedAt: timestamp, stoppedAt: 0, views: new Set<string>()
    };
    FTSessionReplayBridgeRegistry.activeRecording = interval;
    FTSessionReplayBridgeRegistry.recordingIntervals.push(interval);
    if (FTSessionReplayBridgeRegistry.recordingIntervals.length > FTSessionReplayBridgeRegistry.MAX_RECORDING_INTERVALS) {
      FTSessionReplayBridgeRegistry.recordingIntervals.shift();
    }
    FTSessionReplayBridgeRegistry.bridge = bridge;
    // Resolve now, after the HAR's link keys become available. Remembering an
    // old View-start event would retain stale identity, timestamps and tags.
    const provider = FTSessionReplayBridgeRegistry.currentViewProvider;
    if (provider !== null) {
      try {
        const context = provider();
        if (context !== null) {
          FTSessionReplayBridgeRegistry.notifyViewStarted(context);
          FTSessionReplayBridgeRegistry.logDiagnostic(`Attached current RUM View: sessionId=${context.sessionId}, viewId=${context.viewId}`);
        }
      } catch (error) {
        FTSessionReplayBridgeRegistry.logDiagnostic(`Replay current-View callback failed: ${String(error)}`, true);
      }
    }
    const pending = FTSessionReplayBridgeRegistry.pendingErrorTimelines.slice();
    FTSessionReplayBridgeRegistry.pendingErrorTimelines = [];
    for (let index = 0; index < pending.length; index++) {
      FTSessionReplayBridgeRegistry.notifyErrorTimeline(pending[index]);
    }
    return interval.id;
  }

  /** Core callbacks stay independent of the optional recorder's lifetime. */
  public static bindRUMCallbacks(
    currentViewProvider: () => FTSessionReplayRUMContext | null,
    metadataChangedCallback: (context: FTSessionReplayRUMContext, metadata: FTSessionReplayViewMetadata) => void
  ): void {
    FTSessionReplayBridgeRegistry.currentViewProvider = currentViewProvider;
    FTSessionReplayBridgeRegistry.metadataChangedCallback = metadataChangedCallback;
  }

  public static clearRUMCallbacks(currentViewProvider: () => FTSessionReplayRUMContext | null): void {
    if (FTSessionReplayBridgeRegistry.currentViewProvider !== currentViewProvider) {
      return;
    }
    FTSessionReplayBridgeRegistry.currentViewProvider = null;
    FTSessionReplayBridgeRegistry.metadataChangedCallback = null;
    FTSessionReplayBridgeRegistry.pendingErrorTimelines = [];
    FTSessionReplayBridgeRegistry.persistenceEpoch++;
    FTSessionReplayBridgeRegistry.pendingPersistence.forEach((pending: FTSessionReplayPendingPersistence): void => {
      pending.resolve();
    });
    FTSessionReplayBridgeRegistry.pendingPersistence.clear();
  }

  /** Accepted capture work is not evidence of Replay; report committed data. */
  public static notifyViewMetadataChanged(
    context: FTSessionReplayRUMContext,
    metadata: FTSessionReplayViewMetadata
  ): void {
    if (metadata.hasReplay && metadata.recordsCount > 0 && metadata.recordingId) {
      const interval = FTSessionReplayBridgeRegistry.recordingIntervals.find(
        (candidate: FTSessionReplayRecordingInterval): boolean => candidate.id === metadata.recordingId);
      interval?.views.add(FTSessionReplayBridgeRegistry.persistenceKey(
        context.applicationId, context.sessionId, context.viewId));
    }
    const callback = FTSessionReplayBridgeRegistry.metadataChangedCallback;
    if (callback === null) {
      return;
    }
    try {
      // A stopped recorder can still finish its already accepted first frame.
      callback(context, metadata);
    } catch (error) {
      FTSessionReplayBridgeRegistry.logDiagnostic(`Replay metadata update failed: ${String(error)}`, true);
    }
  }

  /** Optional HAR diagnostics use the core logger's configured level. */
  public static logDiagnostic(message: string, warning: boolean = false): void {
    if (warning) {
      FTInnerLogger.w(TAG, message);
    } else {
      FTInnerLogger.d(TAG, message);
    }
  }

  public static unregister(bridge: FTSessionReplayBridge): void {
    if (FTSessionReplayBridgeRegistry.bridge === bridge) {
      FTSessionReplayBridgeRegistry.webSlots.resetBindings(Date.now());
      FTSessionReplayBridgeRegistry.webSlotListeners.forEach((listener): void => listener());
      const interval = FTSessionReplayBridgeRegistry.activeRecording;
      if (interval !== null) interval.stoppedAt = Utils.getCurrentNanoTime();
      FTSessionReplayBridgeRegistry.activeRecording = null;
      FTSessionReplayBridgeRegistry.bridge = null;
    }
  }

  public static getRUMLinkKeys(): Array<string> {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return [];
    }
    try {
      return bridge.getRUMLinkKeys().filter((key: string): boolean => key.length > 0);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay link-key callback failed: ${String(error)}`);
      return [];
    }
  }

  public static getViewMetadata(context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return { hasReplay: false, recordsCount: 0, sampledOnError: false };
    }
    try {
      return bridge.getViewMetadata(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay metadata callback failed: ${String(error)}`);
      return { hasReplay: false, recordsCount: 0, sampledOnError: false };
    }
  }

  public static notifyViewStarted(context: FTSessionReplayRUMContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return false;
    }
    try {
      return bridge.onViewStarted(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay view-start callback failed: ${String(error)}`);
      return false;
    }
  }

  public static notifyViewStopped(context: FTSessionReplayRUMContext): void {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return;
    }
    try {
      bridge.onViewStopped(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay view-stop callback failed: ${String(error)}`);
    }
  }

  public static notifyError(context: FTSessionReplayErrorContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return false;
    }
    try {
      return bridge.onError(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay error callback failed: ${String(error)}`);
      return false;
    }
  }

  public static notifySessionRenewed(context: FTSessionReplaySessionContext): void {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return;
    }
    try {
      bridge.onSessionRenewed(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay session callback failed: ${String(error)}`);
    }
  }

  public static getWebViewOptions(): FTSessionReplayWebViewOptions | null {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.getWebViewOptions === undefined) {
      return null;
    }
    try {
      return bridge.getWebViewOptions();
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView options callback failed: ${String(error)}`);
      return null;
    }
  }

  public static notifyWebReplayData(context: FTSessionReplayWebDataContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.onWebReplayData === undefined) {
      return false;
    }
    try {
      return bridge.onWebReplayData(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView data callback failed: ${String(error)}`);
      return false;
    }
  }

  public static flushWebReplayData(): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.flushWebReplayData === undefined) return true;
    try { return bridge.flushWebReplayData(); }
    catch (error) {
      FTInnerLogger.w(TAG, `Replay Web batch flush failed: ${String(error)}`);
      return false;
    }
  }

  public static notifyWebReplayError(context: FTSessionReplayWebErrorContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.onWebReplayError === undefined) {
      return false;
    }
    try {
      return bridge.onWebReplayError(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView error callback failed: ${String(error)}`);
      return false;
    }
  }

  /**
   * Error timelines from a completed Resource retain the Resource's View
   * identity but must not snapshot whichever ArkUI root happens to be visible
   * now. The optional HAR promotes its existing rolling window only.
   */
  public static notifyErrorTimeline(context: FTSessionReplayErrorContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.onErrorTimeline === undefined) {
      FTSessionReplayBridgeRegistry.rememberPendingErrorTimeline(context);
      return false;
    }
    try {
      return bridge.onErrorTimeline(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay error-timeline callback failed: ${String(error)}`);
      return false;
    }
  }

  private static rememberPendingErrorTimeline(context: FTSessionReplayErrorContext): void {
    if (context.applicationId.length === 0 || context.sessionId.length === 0 || context.viewId.length === 0) {
      return;
    }
    const pending = FTSessionReplayBridgeRegistry.pendingErrorTimelines;
    for (let index = 0; index < pending.length; index++) {
      const candidate = pending[index];
      if (candidate.applicationId === context.applicationId && candidate.sessionId === context.sessionId &&
        candidate.viewId === context.viewId && candidate.timestamp === context.timestamp) {
        return;
      }
    }
    pending.push(context);
    if (pending.length > FTSessionReplayBridgeRegistry.MAX_PENDING_ERROR_TIMELINES) {
      pending.splice(0, pending.length - FTSessionReplayBridgeRegistry.MAX_PENDING_ERROR_TIMELINES);
    }
  }

  public static notifyWebReplayContextChanged(context: FTSessionReplayWebContextChange): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.onWebReplayContextChanged === undefined) {
      return false;
    }
    try {
      return bridge.onWebReplayContextChanged(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView context callback failed: ${String(error)}`);
      return false;
    }
  }

  public static notifyWebReplaySlotActive(slotId: string, active: boolean, timestamp: number): void {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.onWebReplaySlotActive === undefined) {
      return;
    }
    try {
      bridge.onWebReplaySlotActive(slotId, active, timestamp);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView slot callback failed: ${String(error)}`);
    }
  }

  public static isWebReplayErrorSampled(sessionId: string): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null || bridge.isWebReplayErrorSampled === undefined) {
      return false;
    }
    try {
      return bridge.isWebReplayErrorSampled(sessionId);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay WebView sampling callback failed: ${String(error)}`);
      return false;
    }
  }
}
