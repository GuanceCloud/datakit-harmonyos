import { FrameCallback, FrameNode, UIContext, uiObserver } from '@kit.ArkUI';
import window from '@ohos.window';
import {
  FTSessionReplayBridge,
  FTSessionReplayBridgeRegistry,
  FTSessionReplayErrorContext,
  FTSessionReplayRUMContext,
  FTSessionReplaySessionContext,
  FTSessionReplayWebDataContext,
  FTSessionReplayWebErrorContext,
  FTSessionReplayWebContextChange,
  FTSessionReplayWebViewOptions,
  FTSessionReplayViewMetadata
} from '@guancecloud/ft_sdk';
import {
  ArkUIReplayCollector,
  ArkUIReplayLightSnapshot,
  ArkUIReplayPageTransition,
  ArkUIReplaySceneBounds,
  ArkUIReplayScenePage,
  CapturedReplayImageResource
} from './ArkUIReplayCollector';
import { FTSessionReplayConfig, TextAndInputPrivacy, TouchPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from './SessionReplaySampler';
import { SessionReplaySegmentStore } from './SessionReplaySegmentStore';
import {
  ReplayWorkerCapture,
  ReplayWorkerResult,
  ReplaySnapshotKind,
  ReplayStoreKind,
  ReplayViewport,
  REPLAY_STALE_QUEUE_REASON,
  REPLAY_COALESCED_REASON,
  SessionReplayWorkQueue
} from './SessionReplayWorkQueue';
import {
  createReplayEnvelope,
  FullSnapshotData,
  ReplayImageWireframe,
  ReplayPointerInteractionData,
  ReplayRecordType,
  serializeReplayEnvelope,
  SessionReplayContext,
  SessionReplayEnvelope,
  SessionReplayRecord
} from './SessionReplayProtocol';

/** Result returned by one Full Snapshot capture. */
export interface SessionReplayCapture {
  envelope: SessionReplayEnvelope;
  payload: string;
  records: Array<SessionReplayRecord>;
  record: SessionReplayRecord;
  wireframeCount: number;
}

interface SessionReplayRootBinding {
  uiContext: UIContext;
  rootId: string;
  vpToPxScale: number;
  captureScene: boolean;
  sceneRoot: FrameNode | null;
  sceneRootIds: Array<string>;
  // null uses root IDs; an explicit empty list means all scene pages exited.
  scenePages: Array<ArkUIReplayScenePage> | null;
}

interface ReplayNavigationPage {
  key: string;
  root: FrameNode;
  parentKey: string;
  visible: boolean;
  retained: boolean;
  paintOrder: number;
  releaseTimer: number;
}

interface ReplayTouchPoint {
  x: number;
  y: number;
}

/** The normalized bounds of the currently visible native root. */
type SessionReplayViewportBounds = ReplayViewport;

interface BrowserReplayRecord {
  timestamp?: number;
  type?: number;
  data?: object;
}

class ReplaySamplingFrame extends FrameCallback {
  private readonly callback: () => void;
  constructor(callback: () => void) {
    super();
    this.callback = callback;
  }
  // Collect after layout/paint. willDraw still sees the pending timer and
  // cannot rearm collection for the frame requested by Replay itself.
  public onFrame(_frameTimeInNano: number): void {}
  public onIdle(_timeLeftInNano: number): void { this.callback(); }
}

/**
 * Recorder for ArkUI and ArkWeb collection, RUM linkage, and durable replay
 * segments.
 */
export class FTSessionReplayRecorder implements FTSessionReplayBridge {
  private static readonly MAX_RECORDS_PER_VIEW: number = 2000;
  private static readonly WEB_REPLAY_INACTIVE_GRACE_MS: number = 2_000;

  private readonly config: FTSessionReplayConfig;
  private readonly collector: ArkUIReplayCollector;
  private readonly processor: ReplaySnapshotProcessor = new ReplaySnapshotProcessor();
  private baselineContextKey: string = '';
  private readonly pendingManualBaseline: Array<SessionReplayRecord> = [];
  private readonly sampler: SessionReplaySampler;
  private readonly store: SessionReplaySegmentStore | null;
  private readonly errorSampleStore: SessionReplaySegmentStore | null;
  private rootBinding: SessionReplayRootBinding | null = null;
  private isStarted: boolean = false;
  // Stop seals input immediately while accepted detached snapshots finish.
  private isStopping: boolean = false;
  private lastCapture: SessionReplayCapture | null = null;
  // The bridge must return a useful reason to the host app. Previously this
  // detail was swallowed and the recorder incorrectly suggested Replay was off.
  private lastCaptureFailure: string = '';
  private activeContext: SessionReplayContext | null = null;
  // A page-show callback and RUM's route observer can arrive in either order.
  // Retain one sampled View-start until the generated page root completes its
  // first layout, then create the normal Meta/Focus/Full-Snapshot sequence.
  private pendingViewStartContext: FTSessionReplayRUMContext | null = null;
  private pendingViewStartFailure: string = '';
  private readonly viewMetadata: Map<string, FTSessionReplayViewMetadata> = new Map();
  private readonly recordedContextsByView: Map<string, SessionReplayContext> = new Map();
  private readonly recordedRecordsByView: Map<string, Array<SessionReplayRecord>> = new Map();
  private readonly promotedErrorSessions: Set<string> = new Set();
  private readonly errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null;
  private readonly resourceTouch: ((names: Array<string>, kind: ReplayStoreKind) => void) | null;
  private readonly imageResourceWriter: ((context: SessionReplayContext, data: Uint8Array, mimeType: string) => string | null) | null;
  // Zero means active. A positive timestamp retains the Android-compatible
  // two-second grace period after a WebView slot becomes inactive.
  private readonly webSlotInactiveAt: Map<string, number> = new Map();
  private readonly workQueue: SessionReplayWorkQueue;
  private readonly pendingViewStarts: Map<string, number> = new Map();
  private readonly endedViewStarts: Map<string, number> = new Map();
  // Generations protect the current UI shadow, while accepted immutable frames
  // keep their original View and finish in FIFO order through a transition.
  private captureGeneration: number = 0;
  private samplingFrameEpoch: number = 0;
  private nextSamplingDeadline: number = 0;
  private mutationCaptureTimer: number = -1;
  private viewportCaptureTimer: number = -1;
  private captureDeferred: boolean = false;
  private motionUntil: number = 0;
  private hasActiveComponentAnimations: boolean = false;
  private readonly activePointers: Map<number, ReplayTouchPoint> = new Map();
  private readonly pageTransitions: Map<string, ArkUIReplayPageTransition> = new Map();
  private readonly navigationPages: Map<string, ReplayNavigationPage> = new Map();
  private nextNavigationPaintOrder: number = 0;
  private transitionObserverContext: UIContext | null = null;
  private sceneViewport: ArkUIReplaySceneBounds | null = null;
  private readonly routerTransitionListener = (_info: uiObserver.RouterPageInfo): void => {
    this.captureActiveViewMutation();
    this.notifyTransition();
  };
  private readonly navigationSwitchListener = (info: uiObserver.NavDestinationSwitchInfo): void => {
    const from = info.from === 'navBar' ? null : this.ensureNavigationPage(info.from);
    const to = info.to === 'navBar' ? null : this.ensureNavigationPage(info.to);
    if (from !== null) this.retainNavigationPage(from);
    if (to !== null) {
      if (to.releaseTimer !== -1) clearTimeout(to.releaseTimer);
      to.releaseTimer = -1;
      to.visible = true;
      to.retained = false;
    }
    if (info.operation === NavigationOperation.POP && from !== null) from.paintOrder = ++this.nextNavigationPaintOrder;
    else if (to !== null) to.paintOrder = ++this.nextNavigationPaintOrder;
    this.captureActiveViewMutation();
    this.notifyTransition();
  };
  private readonly navigationStateListener = (info: uiObserver.NavDestinationInfo): void => {
    this.onNavigationPageState(info);
  };
  private drawObserverContext: UIContext | null = null;
  private readonly drawListener = (): void => this.notifyPageChanged();
  private lastFullSnapshotAt: number = 0;
  private observedViewport: SessionReplayViewportBounds | null = null;
  // Kept separately because an IME can reduce the root's layout height or
  // overlay it without a relayout, depending on the app's avoid-mode.
  private observedRootViewport: SessionReplayViewportBounds | null = null;
  private keyboardHeightPx: number = 0;
  private keyboardResizesRoot: boolean | null = null;
  private nativeWindow: window.Window | null = null;
  private windowObserverEpoch: number = 0;
  private readonly windowSizeChangeListener = (_size: window.Size): void => {
    this.refreshWindowSceneViewport();
    this.scheduleViewportCapture();
  };
  private readonly keyboardHeightChangeListener = (height: number): void => {
    this.keyboardHeightPx = Number.isFinite(height) && height > 0 ? Math.round(height) : 0;
    this.keyboardResizesRoot = null;
    this.refreshWindowSceneViewport();
    this.scheduleViewportCapture();
  };
  private readonly avoidAreaChangeListener = (): void => {
    this.refreshWindowSceneViewport();
    this.scheduleViewportCapture();
  };

  constructor(
    config: FTSessionReplayConfig = new FTSessionReplayConfig(),
    store: SessionReplaySegmentStore | null = null,
    errorSampleStore: SessionReplaySegmentStore | null = null,
    errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null = null,
    imageResourceWriter: ((context: SessionReplayContext, data: Uint8Array, mimeType: string) => string | null) | null = null,
    resourceTouch: ((names: Array<string>, kind: ReplayStoreKind) => void) | null = null
  ) {
    this.config = config;
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot(), config);
    this.sampler = new SessionReplaySampler(config);
    this.store = store;
    this.errorSampleStore = errorSampleStore;
    this.errorSampleResourcePromoter = errorSampleResourcePromoter;
    this.imageResourceWriter = imageResourceWriter;
    this.resourceTouch = resourceTouch;
    this.workQueue = new SessionReplayWorkQueue({
      filesDir: store?.getFilesDir() ?? errorSampleStore?.getFilesDir() ?? '',
      maxNodes: config.getMaxNodesPerSnapshot(),
      maxBytes: config.getStorageMaxBytes(),
      maxRecordsPerSegment: config.getMaxRecordsPerSegment(),
      fullSnapshotIntervalMs: config.getFullSnapshotIntervalMs(),
      errorSampleWindowMs: config.getErrorSampleWindowMs(),
      textPrivacy: config.getTextAndInputPrivacy(),
      imagePrivacy: config.getImagePrivacy(),
      diagnosticsEnabled: config.isPerformanceDiagnosticsEnabled()
    });
  }

  /** Enables RUM lifecycle capture through the core NoOp bridge registry. */
  public start(): void {
    if (this.isStarted || this.isStopping) {
      return;
    }
    this.isStarted = true;
    FTSessionReplayBridgeRegistry.register(this);
  }

  /** Stops RUM lifecycle capture without changing the core SDK. */
  public stop(): void {
    if (!this.isStarted) {
      this.workQueue.close();
      return;
    }
    if (this.captureDeferred || this.mutationCaptureTimer !== -1) this.captureActiveViewMutation('settled');
    FTSessionReplayBridgeRegistry.unregister(this);
    this.finishTouchPointers();
    this.isStarted = false;
    this.isStopping = true;
    this.pendingViewStartContext = null;
    this.pendingViewStartFailure = '';
    this.unbindWindowViewportObserver();
    this.unbindTransitionObserver();
    this.clearNavigationPages();
    this.pageTransitions.clear();
    this.collector.clearScene();
    this.stopObservation();
    // Do not advance the generation or clear the active context here: an
    // accepted snapshot may be materializing or committing in the Worker.
    // Its resources and segment must finish before the final View End.
    const context = this.activeContext;
    if (context !== null) {
      const record = this.processor.createViewEndRecord(Date.now());
      this.appendRecordedRecords(context, [record], true, true);
    }
    this.workQueue.close();
    this.workQueue.drain().then((): void => {
      const failure = this.workQueue.getLastFailure();
      if (failure.length > 0) FTSessionReplayBridgeRegistry.logDiagnostic(`Replay stop seal failed: ${failure}`, true);
      this.rootBinding = null;
      this.activeContext = null;
      this.resetViewportObservation();
      this.viewMetadata.clear();
      this.recordedContextsByView.clear();
      this.recordedRecordsByView.clear();
      this.promotedErrorSessions.clear();
      this.webSlotInactiveAt.clear();
      this.pendingViewStarts.clear();
      this.endedViewStarts.clear();
      this.captureGeneration++;
      this.processor.reset();
      this.sampler.reset();
    });
  }

  /** Registers the visible ArkUI root to record when RUM starts or errors a View. */
  public registerRoot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1,
    captureScene: boolean = false,
    sceneRootIds: Array<string> = [],
    scenePages: Array<ArkUIReplayScenePage> = []
  ): void {
    if (this.isStopping) return;
    const current = this.rootBinding;
    const sceneRoot = captureScene ? this.collector.findSceneRoot(uiContext, rootId) : null;
    const pageRoots = captureScene ? sceneRootIds.slice() : [];
    const pages = captureScene && scenePages.length > 0 ? scenePages.slice() : null;
    if (current !== null && current.uiContext === uiContext && current.rootId === rootId &&
      current.vpToPxScale === vpToPxScale && current.captureScene === captureScene) {
      const changed = current.sceneRootIds.join('\n') !== pageRoots.join('\n');
      current.sceneRootIds = pageRoots;
      current.scenePages = pages;
      this.capturePendingViewStart();
      if (changed) this.notifyTransition();
      return;
    }
    if (current !== null && sceneRoot !== null && current.sceneRoot !== null &&
      sceneRoot.getUniqueId() === current.sceneRoot.getUniqueId() && current.vpToPxScale === vpToPxScale &&
      this.sameWindow(current.uiContext, uiContext)) {
      this.rootBinding = { uiContext, rootId, vpToPxScale, captureScene, sceneRoot, sceneRootIds: pageRoots, scenePages: pages };
      this.bindTransitionObserver(uiContext);
      this.capturePendingViewStart();
      if (this.activeContext !== null) this.startObservation();
      this.notifyTransition();
      return;
    }
    if (current !== null && captureScene && current.captureScene &&
      current.vpToPxScale === vpToPxScale && this.sameWindow(current.uiContext, uiContext)) {
      this.rootBinding = { uiContext, rootId, vpToPxScale, captureScene, sceneRoot, sceneRootIds: pageRoots, scenePages: pages };
      this.bindTransitionObserver(uiContext);
      this.capturePendingViewStart();
      if (this.activeContext !== null) this.startObservation();
      this.notifyTransition();
      return;
    }
    this.captureGeneration++;
    this.stopObservation();
    this.processor.reset();
    this.baselineContextKey = '';
    this.unbindWindowViewportObserver();
    this.unbindTransitionObserver();
    this.sceneViewport = null;
    this.clearNavigationPages();
    this.pageTransitions.clear();
    this.collector.clearScene();
    const binding: SessionReplayRootBinding = {
      uiContext,
      rootId,
      vpToPxScale,
      captureScene,
      sceneRoot,
      sceneRootIds: pageRoots,
      scenePages: pages
    };
    this.rootBinding = binding;
    this.resetViewportObservation();
    this.lastFullSnapshotAt = 0;
    this.bindWindowViewportObserver(uiContext);
    this.bindTransitionObserver(uiContext);
    this.capturePendingViewStart();
    if (this.activeContext !== null) {
      this.startObservation();
    }
  }

  public unregisterRoot(): void {
    if (this.isStopping) return;
    this.captureGeneration++;
    this.stopObservation();
    this.processor.reset();
    this.baselineContextKey = '';
    this.rootBinding = null;
    this.lastFullSnapshotAt = 0;
    this.resetViewportObservation();
    this.unbindWindowViewportObserver();
    this.unbindTransitionObserver();
    this.sceneViewport = null;
    this.clearNavigationPages();
    this.pageTransitions.clear();
    this.collector.clearScene();
  }

  public getLastCapture(): SessionReplayCapture | null {
    return this.lastCapture;
  }

  /** Returns the most recent Full Snapshot failure for integration diagnostics. */
  public getLastCaptureFailure(): string | null {
    return this.lastCaptureFailure.length === 0 ? null : this.lastCaptureFailure;
  }

  /** Waits for all Replay batches accepted before this call to reach disk. */
  public drainWrites(): Promise<void> {
    return this.workQueue.drain();
  }

  public withWriteBarrier(action: () => void): Promise<void> {
    return this.workQueue.drain(action);
  }

  public getStorageFilesDir(): string {
    return this.store?.getFilesDir() ?? this.errorSampleStore?.getFilesDir() ?? '';
  }

  public removeUploadedResources(ids: Array<string>, canRemove: () => boolean): Promise<boolean> {
    return this.workQueue.removeResources(ids, canRemove);
  }

  public listPendingSegmentIds(): Promise<Array<string>> {
    return this.workQueue.listPendingIds();
  }

  public removeUploadedSegments(ids: Array<string>): Promise<boolean> {
    return new Promise<boolean>((resolve: (success: boolean) => void): void => {
      if (!this.workQueue.enqueueRemove('main', ids, (success: boolean, error: string): void => {
        if (!success) this.lastCaptureFailure = error;
        resolve(success);
      })) resolve(false);
    });
  }

  /** Returns a copy of the in-memory protocol stream for one RUM View. */
  public getRecordedRecords(context: SessionReplayContext): Array<SessionReplayRecord> {
    const records = this.recordedRecordsByView.get(
      this.getViewKey(context.applicationId, context.sessionId, context.viewId)
    );
    return records === undefined ? [] : records.slice();
  }

  /** Registers a binary asset by an ArkUI Image component id or public source string. */
  public registerImageAsset(componentId: string, data: ArrayBuffer | Uint8Array, mimeType: string = 'image/png'): boolean {
    const registered = this.collector.registerImageAsset(componentId, data, mimeType);
    if (registered) {
      const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
      this.workQueue.registerImageAsset(componentId, bytes, mimeType);
    }
    return registered;
  }

  public unregisterImageAsset(componentId: string): void {
    this.collector.unregisterImageAsset(componentId);
    this.workQueue.unregisterImageAsset(componentId);
  }

  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture {
    const record = this.collector.materializeLightSnapshot(this.captureRootLight(uiContext, rootId, vpToPxScale));
    this.persistCapturedImageResources(context, record);
    const capture = this.createCapture(context, [record], record);
    this.appendRecordedRecords(context, capture.records, true, false, record);
    this.lastCapture = capture;
    return capture;
  }

  /** Falls back to a checkpoint while earlier captures are still being committed. */
  public captureIncrementalSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture | null {
    const fullSnapshot = this.collector.materializeLightSnapshot(this.captureRootLight(uiContext, rootId, vpToPxScale));
    this.persistCapturedImageResources(context, fullSnapshot);
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    if (!this.workQueue.hasPendingWork()) {
      this.processor.applyCommittedRecords(this.pendingManualBaseline);
      this.pendingManualBaseline.splice(0);
    }
    const mutation = !this.workQueue.hasPendingWork() && this.processor.hasBaseline() &&
      this.baselineContextKey === key ? this.processor.createMutationRecord(fullSnapshot) : fullSnapshot;
    if (mutation === null) {
      return null;
    }
    const capture = this.createCapture(context, [mutation], fullSnapshot);
    this.appendRecordedRecords(context, capture.records, true, false, fullSnapshot);
    this.lastCapture = capture;
    return capture;
  }

  /** Emits a protocol-compatible pointer record only when touch privacy allows it. */
  public recordTouch(
    context: SessionReplayContext,
    pointerEventType: 'down' | 'up' | 'move',
    pointerId: number,
    x: number,
    y: number
  ): SessionReplayCapture | null {
    if (this.config.getTouchPrivacy() !== TouchPrivacy.SHOW) {
      return null;
    }
    if (this.captureDeferred && pointerEventType !== 'move' && this.activeContext !== null &&
      this.isSameReplayContext(this.activeContext, context)) this.captureActiveViewMutation('settled');
    const record = this.processor.createPointerRecord(pointerEventType, pointerId, x, y);
    const capture = this.createCapture(context, [record], null);
    this.appendRecordedRecords(context, capture.records);
    this.lastCapture = capture;
    return capture;
  }

  /** Emits a Focus record for the currently recorded native RUM View. */
  public recordActiveFocus(hasFocus: boolean): SessionReplayCapture | null {
    return this.appendActiveProtocolRecords([this.processor.createFocusRecord(hasFocus)], null);
  }

  /** Emits a VisualViewport record for the currently recorded native RUM View. */
  public recordActiveViewport(width: number, height: number, scale: number = 1): SessionReplayCapture | null {
    if (!Number.isFinite(width) || !Number.isFinite(height) || !Number.isFinite(scale) ||
      width < 0 || height < 0 || scale <= 0) {
      return null;
    }
    const normalizedWidth = this.normalizePhysicalLength(width);
    const normalizedHeight = this.normalizePhysicalLength(height);
    if (normalizedWidth > 0 && normalizedHeight > 0) {
      this.observedViewport = { width: normalizedWidth, height: normalizedHeight };
    }
    return this.appendActiveProtocolRecords([
      this.processor.createViewportRecord(normalizedWidth, normalizedHeight, scale)
    ], null);
  }

  /**
   * Emits Android's resize mutation and follows it with a Full Snapshot when
   * a root is still available. Use the captured native viewport for both
   * records; a caller's stale or synthetic dimensions must not resize the
   * persistent page scene. Inputs are a fallback when capture is unavailable.
   */
  public recordActiveViewportResize(width: number, height: number): SessionReplayCapture | null {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width < 0 || height < 0) {
      return null;
    }
    if (this.captureDeferred) this.captureActiveViewMutation('settled');
    const activeContext = this.activeContext;
    if (activeContext === null || !this.canRecordActiveContext(activeContext)) {
      return null;
    }
    this.refreshWindowSceneViewport();
    const snapshotCapture = this.captureWithRegisteredRoot(activeContext);
    const fullSnapshot = snapshotCapture?.record ?? null;
    const viewport = fullSnapshot === null ? null : this.getViewportBounds(fullSnapshot);
    const records: Array<SessionReplayRecord> = [
      this.processor.createViewportResizeRecord(
        viewport?.width ?? this.normalizePhysicalLength(width),
        viewport?.height ?? this.normalizePhysicalLength(height),
        fullSnapshot?.timestamp ?? Date.now())
    ];
    if (fullSnapshot !== null) {
      records.push(fullSnapshot);
      this.observedViewport = viewport;
      this.lastFullSnapshotAt = fullSnapshot.timestamp;
    }
    return this.appendActiveProtocolRecords(records, fullSnapshot);
  }

  /** Emits a touch interaction only when the configured privacy policy allows it. */
  public recordActiveTouch(
    pointerEventType: 'down' | 'up' | 'move',
    pointerId: number,
    x: number,
    y: number
  ): SessionReplayCapture | null {
    if (this.config.getTouchPrivacy() !== TouchPrivacy.SHOW || !Number.isFinite(pointerId) ||
      !Number.isFinite(x) || !Number.isFinite(y)) {
      return null;
    }
    const capture = this.appendActiveProtocolRecords([
      this.processor.createPointerRecord(
        pointerEventType,
        Math.floor(pointerId),
        this.normalizePhysicalLength(x) - this.sceneOriginX(),
        this.normalizePhysicalLength(y) - this.sceneOriginY()
      )
    ], null);
    if (pointerEventType === 'move') {
      this.notifyMotion();
    } else {
      this.notifyPageChanged();
    }
    return capture;
  }

  /** ArkUI events already contain window-space vp coordinates. */
  public recordTouchEvent(event: TouchEvent): void {
    if (!this.isStarted || this.activeContext === null || event === undefined || event === null) return;
    this.notifyMotion();
    if (this.config.getTouchPrivacy() !== TouchPrivacy.SHOW) {
      this.activePointers.clear();
      return;
    }
    const changed = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    const records: Array<SessionReplayRecord> = [];
    const timestamp = Date.now();
    const type = event.type === TouchType.Down ? 'down' : event.type === TouchType.Move ? 'move' : 'up';
    if (event.type !== TouchType.Down && event.type !== TouchType.Move &&
      event.type !== TouchType.Up && event.type !== TouchType.Cancel) return;
    for (let index = 0; index < changed.length; index++) {
      const point = changed[index];
      if (!Number.isFinite(point.id) || !Number.isFinite(point.windowX) || !Number.isFinite(point.windowY)) continue;
      const id = Math.floor(point.id);
      const position: ReplayTouchPoint = { x: Math.round((point.windowX - this.sceneOriginX()) * 100) / 100,
        y: Math.round((point.windowY - this.sceneOriginY()) * 100) / 100 };
      const previous = this.activePointers.get(id);
      if (type === 'up' && previous === undefined) continue;
      if (type === 'move' && previous === undefined) continue;
      if (type === 'move' && previous?.x === position.x && previous?.y === position.y) continue;
      records.push(this.processor.createPointerRecord(type, id, position.x, position.y, timestamp));
      if (type === 'up') this.activePointers.delete(id);
      else this.activePointers.set(id, position);
    }
    if (event.type === TouchType.Cancel) {
      this.activePointers.forEach((point: ReplayTouchPoint, id: number): void => {
        records.push(this.processor.createPointerRecord('up', id, point.x, point.y, timestamp));
      });
      this.activePointers.clear();
    }
    if (records.length > 0) this.appendActiveProtocolRecords(records, null);
  }

  private finishTouchPointers(): void {
    const records: Array<SessionReplayRecord> = [];
    this.activePointers.forEach((point: ReplayTouchPoint, id: number): void => {
      records.push(this.processor.createPointerRecord('up', id, point.x, point.y));
    });
    this.activePointers.clear();
    if (records.length > 0) this.appendActiveProtocolRecords(records, null);
  }

  /**
   * Generated page instrumentation and integration code call this after a
   * layout/state change. It coalesces many draws into one detached snapshot.
   */
  public notifyPageChanged(): void {
    this.scheduleAutomaticCapture();
  }

  /** Keeps captures running through motion, including its settled final frame. */
  public notifyMotion(): void {
    this.motionUntil = Date.now() + this.config.getMotionQuietPeriodMs();
    this.scheduleAutomaticCapture();
  }

  /** A navigation boundary starts the same continuous motion capture. */
  public notifyTransition(): void {
    this.notifyMotion();
  }

  public updatePageTransition(rootId: string, transition: ArkUIReplayPageTransition): void {
    this.pageTransitions.set(rootId, transition);
    const navigationPage = this.navigationPages.get(rootId);
    if (navigationPage !== undefined && !transition.entering && transition.progress < 1) {
      this.retainNavigationPage(navigationPage);
    }
    this.notifyTransition();
    // Preserve the actual callback boundary even when the ordinary sampling
    // timer would run only after a short transition has already finished.
    if (transition.progress === 0 || transition.progress === 1) this.captureActiveViewMutation('settled');
  }

  public finishPageTransition(key: string): void {
    this.pageTransitions.delete(key);
    const page = this.navigationPages.get(key);
    if (page !== undefined && !page.visible) {
      if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
      this.navigationPages.delete(key);
    }
    this.notifyTransition();
  }

  /** Release Router pages independently of the incoming root's layout readiness. */
  public releaseScenePages(keys: Array<string>): void {
    if (keys.length === 0) return;
    const binding = this.rootBinding;
    if (binding !== null && binding.captureScene) {
      const released = new Set<string>(keys);
      binding.scenePages = this.getRootScenePages(binding).filter((page: ArkUIReplayScenePage): boolean => {
        if (!released.has(page.key) && !released.has(page.rootId)) return true;
        this.pageTransitions.delete(page.key);
        this.pageTransitions.delete(page.rootId);
        return false;
      });
      binding.sceneRootIds = binding.scenePages.map((page: ArkUIReplayScenePage): string => page.rootId);
    }
    // Queue removal under the current View even if its new root is still
    // laying out. Keep the stable scene canvas when the last page exits.
    this.captureActiveViewMutation('settled');
    this.notifyTransition();
  }

  /** Converts public physical-pixel viewport and touch inputs into Replay vp units. */
  private normalizePhysicalLength(value: number): number {
    const rootBinding = this.rootBinding;
    const scale = rootBinding === null || !Number.isFinite(rootBinding.vpToPxScale) || rootBinding.vpToPxScale <= 0
      ? 1
      : rootBinding.vpToPxScale;
    return Math.max(0, Math.round(value / scale));
  }

  public renewRootEpoch(): void {
    if (this.isStopping) return;
    this.captureGeneration++;
    this.workQueue.clear();
    this.collector.renewRootEpoch();
    this.processor.reset();
    this.lastFullSnapshotAt = 0;
  }

  public getRUMLinkKeys(): Array<string> {
    return this.config.getRumLinkKeys();
  }

  public getSamplingMode(sessionId: string): SessionReplaySamplingMode {
    return this.sampler.decide(sessionId);
  }

  /** Supplies Android-compatible Browser SDK initialization values. */
  public getWebViewOptions(): FTSessionReplayWebViewOptions | null {
    if (!this.isStarted) {
      return null;
    }
    return {
      privacyLevel: this.getWebReplayPrivacyLevel(),
      capabilities: ['records']
    };
  }

  /** Accepts native-associated Browser SDK records without ArkUI conversion. */
  public onWebReplayData(context: FTSessionReplayWebDataContext): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE ||
      !this.isWebReplaySlotWithinGracePeriod(context.slotId, context.timestamp)) {
      return false;
    }
    const record = this.parseWebReplayRecord(context.payload, context.slotId);
    if (record === null) {
      return false;
    }
    const replayContext: SessionReplayContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
    if (Object.keys(context.linkContext).length > 0) {
      replayContext.globalContext = context.linkContext;
    }
    const capture = this.createCapture(replayContext, [record], null);
    if (!this.appendRecordedRecords(replayContext, capture.records)) {
      return false;
    }
    this.lastCapture = capture;
    return true;
  }

  /** Browser RUM Errors promote only the matching error-sampled session. */
  public onWebReplayError(context: FTSessionReplayWebErrorContext): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    if (this.sampler.decide(context.sessionId) !== SessionReplaySamplingMode.ERROR) {
      return true;
    }
    return this.promoteErrorSampledSession(context.sessionId, this.toEpochMilliseconds(context.timestamp));
  }

  /** Promotes a completed Resource's retained error window without a stale UI capture. */
  public onErrorTimeline(context: FTSessionReplayErrorContext): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    return this.sampler.decide(context.sessionId) !== SessionReplaySamplingMode.ERROR ||
      this.promoteErrorSampledSession(context.sessionId, this.toEpochMilliseconds(context.timestamp));
  }

  /**
   * Browser RUM link fields are attached to the native container View as a
   * new Full Snapshot, so batches before and after the rebind cannot share
   * stale association data.
   */
  public onWebReplayContextChanged(context: FTSessionReplayWebContextChange): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    const resolvedContext = this.mergeWebLinkContext(context);
    const nextContext = this.toReplayContext(resolvedContext);
    if (this.activeContext === null || !this.isSameView(this.activeContext, nextContext) ||
      this.isSameReplayContext(this.activeContext, nextContext)) {
      return false;
    }
    const previousContext = this.activeContext;
    this.captureGeneration++;
    this.activeContext = nextContext;
    if (!this.queueFullSnapshotFromRUMContext(resolvedContext)) {
      this.activeContext = previousContext;
      return false;
    }
    return true;
  }

  public onWebReplaySlotActive(slotId: string, active: boolean, timestamp: number): void {
    if (slotId.length === 0) {
      return;
    }
    this.webSlotInactiveAt.set(slotId, active ? 0 : timestamp);
  }

  public isWebReplayErrorSampled(sessionId: string): boolean {
    return this.isStarted && this.sampler.decide(sessionId) === SessionReplaySamplingMode.ERROR;
  }

  /** Lets the manager route error-sampled assets to the correct durable queue. */
  public isErrorSampledSessionPromoted(sessionId: string): boolean {
    return this.promotedErrorSessions.has(sessionId);
  }

  /** Returns Android-compatible Replay counters for the current RUM View. */
  public getViewMetadata(context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata {
    const metadata = this.viewMetadata.get(this.getViewMetadataKey(context));
    if (metadata === undefined) {
      return { hasReplay: false, recordsCount: 0, sampledOnError: false };
    }
    // Error-sampled records are intentionally invisible to RUM and upload
    // until a RUM Error promotes their rolling pre-error window.
    if (metadata.sampledOnError && !this.promotedErrorSessions.has(context.sessionId)) {
      return { hasReplay: false, recordsCount: 0, sampledOnError: false };
    }
    return {
      hasReplay: metadata.hasReplay,
      recordsCount: metadata.recordsCount,
      sampledOnError: metadata.sampledOnError
    };
  }

  public onViewStarted(context: FTSessionReplayRUMContext): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    if (this.queueViewStartedFromRUMContext(context)) {
      this.pendingViewStartContext = null;
      this.pendingViewStartFailure = '';
      return true;
    }
    this.pendingViewStartContext = context;
    this.pendingViewStartFailure = this.lastCaptureFailure;
    FTSessionReplayBridgeRegistry.logDiagnostic(
      `Replay View start waiting for root: session=${context.sessionId}, view=${context.viewId}, reason=${this.pendingViewStartFailure}`);
    return false;
  }

  public onViewStopped(context: FTSessionReplayRUMContext): void {
    if (!this.isStarted) return;
    const replayContext = this.toReplayContext(context);
    if (this.pendingViewStartContext !== null &&
      this.isSameView(this.toReplayContext(this.pendingViewStartContext), replayContext)) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay View ended before first root snapshot: session=${context.sessionId}, view=${context.viewId}, reason=${this.pendingViewStartFailure}`,
        true);
      this.pendingViewStartContext = null;
      this.pendingViewStartFailure = '';
    }
    if (this.activeContext === null || !this.isSameView(this.activeContext, replayContext)) {
      return;
    }
    if (this.captureDeferred || this.mutationCaptureTimer !== -1) this.captureActiveViewMutation('settled');
    this.finishTouchPointers();
    const viewKey = this.getViewKey(replayContext.applicationId, replayContext.sessionId, replayContext.viewId);
    if (this.pendingViewStarts.has(viewKey)) {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay View ended with first frame pending: session=${context.sessionId}, view=${context.viewId}`);
    }
    if (this.pendingViewStarts.get(viewKey) === this.captureGeneration) {
      this.endedViewStarts.set(viewKey, this.captureGeneration);
    }
    const record = this.processor.createViewEndRecord(this.toEpochMilliseconds(context.timestamp));
    const capture = this.createCapture(replayContext, [record], null);
    this.lastCapture = capture;
    this.appendRecordedRecords(replayContext, capture.records, true, true);
    this.activeContext = null;
    this.captureGeneration++;
    this.stopObservation();
    this.processor.reset();
  }

  public onError(context: FTSessionReplayErrorContext): boolean {
    if (!this.isStarted || this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    const replayContext = this.toReplayContext(context);
    let accepted: boolean;
    if (this.activeContext === null || !this.isSameReplayContext(this.activeContext, replayContext)) {
      accepted = this.queueViewStartedFromRUMContext(context, this.toEpochMilliseconds(context.timestamp));
    } else {
      accepted = this.queueFullSnapshotFromRUMContext(context, this.toEpochMilliseconds(context.timestamp));
    }
    if (!accepted) {
      return false;
    }
    return true;
  }

  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {
    if (!this.isStarted) return;
    this.finishTouchPointers();
    this.renewRootEpoch();
    this.activeContext = null;
    this.captureGeneration++;
    this.pendingViewStartContext = null;
    this.pendingViewStartFailure = '';
    this.stopObservation();
    this.promotedErrorSessions.clear();
    this.webSlotInactiveAt.clear();
  }

  private getWebReplayPrivacyLevel(): string {
    if (this.config.getTouchPrivacy() === TouchPrivacy.SHOW) {
      if (this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS) {
        return 'allow';
      }
      if (this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_ALL_INPUTS) {
        return 'mask-user-input';
      }
    }
    return 'mask';
  }

  /** Core RUM timestamps are nanoseconds; Replay records use epoch milliseconds. */
  private toEpochMilliseconds(timestamp: number): number {
    if (!Number.isFinite(timestamp) || timestamp <= 0) {
      return Date.now();
    }
    if (timestamp >= 100000000000000000) {
      return Math.floor(timestamp / 1000000);
    }
    if (timestamp >= 100000000000000) {
      return Math.floor(timestamp / 1000);
    }
    return Math.floor(timestamp);
  }

  private isWebReplaySlotWithinGracePeriod(slotId: string, timestamp: number): boolean {
    const inactiveAt = this.webSlotInactiveAt.get(slotId);
    if (inactiveAt === undefined || inactiveAt === 0) {
      return true;
    }
    return timestamp - inactiveAt < FTSessionReplayRecorder.WEB_REPLAY_INACTIVE_GRACE_MS;
  }

  private parseWebReplayRecord(payload: string, slotId: string): SessionReplayRecord | null {
    try {
      const browserRecord = JSON.parse(payload) as BrowserReplayRecord;
      const timestamp = browserRecord.timestamp;
      const type = browserRecord.type;
      const data = browserRecord.data;
      if (timestamp === undefined || type === undefined || data === undefined || data === null ||
        !Number.isFinite(timestamp) || !Number.isInteger(timestamp) ||
        !Number.isFinite(type) || !Number.isInteger(type) || type < 0 || type > 20 ||
        typeof data !== 'object' || Array.isArray(data)) {
        return null;
      }
      return {
        timestamp,
        type: type as ReplayRecordType,
        data,
        slotId
      };
    } catch (_error) {
      return null;
    }
  }

  private getWireframeCount(record: SessionReplayRecord): number {
    const data = record.data as FullSnapshotData;
    return data.wireframes.length;
  }

  /**
   * Queues the initial Meta/Focus/Viewport/Full Snapshot sequence. The caller
   * receives acceptance synchronously, but all Inspector, image, JSON and disk
   * work happens after the FrameNode-only capture has left the UI callback.
   */
  private queueViewStartedFromRUMContext(
    context: FTSessionReplayRUMContext,
    promoteErrorAt: number | null = null
  ): boolean {
    const replayContext = this.toReplayContext(context);
    const lightSnapshot = this.captureLightSnapshotForContext(replayContext);
    if (lightSnapshot === null) {
      return false;
    }
    if (this.activeContext !== null && !this.isSameView(this.activeContext, replayContext)) this.finishTouchPointers();
    this.captureGeneration++;
    this.processor.reset();
    this.resetViewportObservation(true);
    this.lastFullSnapshotAt = 0;
    this.activeContext = replayContext;
    const generation = this.captureGeneration;
    const contextSnapshot = this.copyReplayContext(replayContext);
    this.pendingViewStarts.set(
      this.getViewKey(replayContext.applicationId, replayContext.sessionId, replayContext.viewId), generation);
    const queuedAt = Date.now();
    FTSessionReplayBridgeRegistry.logDiagnostic(
      `Replay first frame queued: session=${context.sessionId}, view=${context.viewId}, frameTime=${lightSnapshot.timestamp}, nodes=${lightSnapshot.nodes.length}`);
    this.enqueueWorkerSnapshot('start', lightSnapshot, contextSnapshot, generation, context, promoteErrorAt, queuedAt);
    // A short page transition can finish before the first frame is saved.
    // Keep observing while that write is pending; the FIFO places subsequent
    // automatic frames after the View's start checkpoint.
    if (this.isCurrentCapture(replayContext, generation)) this.startObservation();
    return true;
  }

  /** Retries one View start after automatic root registration reaches layout. */
  private capturePendingViewStart(): void {
    const pending = this.pendingViewStartContext;
    if (pending === null || this.activeContext !== null ||
      this.sampler.decide(pending.sessionId) === SessionReplaySamplingMode.NONE) {
      return;
    }
    if (this.queueViewStartedFromRUMContext(pending)) {
      this.pendingViewStartContext = null;
      this.pendingViewStartFailure = '';
    } else {
      this.pendingViewStartFailure = this.lastCaptureFailure;
    }
  }

  /** Queues an out-of-band Full Snapshot for an Error or Browser context change. */
  private queueFullSnapshotFromRUMContext(
    context: FTSessionReplayRUMContext,
    promoteErrorAt: number | null = null
  ): boolean {
    const replayContext = this.toReplayContext(context);
    const lightSnapshot = this.captureLightSnapshotForContext(replayContext);
    if (lightSnapshot === null) {
      return false;
    }
    const generation = this.captureGeneration;
    const contextSnapshot = this.copyReplayContext(replayContext);
    this.enqueueWorkerSnapshot('full', lightSnapshot, contextSnapshot, generation, context, promoteErrorAt);
    return true;
  }

  private enqueueWorkerSnapshot(
    kind: ReplaySnapshotKind,
    snapshot: ArkUIReplayLightSnapshot,
    context: SessionReplayContext,
    generation: number,
    rumContext: FTSessionReplayRUMContext | null,
    promoteErrorAt: number | null,
    queuedAt: number = Date.now()
  ): void {
    const completePersistence = FTSessionReplayBridgeRegistry.beginViewPersistence(this.createReplayRUMContext(context));
    try {
      const targetStore = this.getStoreForContext(context);
      const capture: ReplayWorkerCapture = {
        context, viewport: this.getRootViewport(snapshot.nodes[0]?.width, snapshot.nodes[0]?.height), previousViewport: this.observedViewport,
        lastFullSnapshotAt: this.lastFullSnapshotAt,
        storeKind: targetStore === this.store && targetStore !== null ? 'main' :
          (targetStore === this.errorSampleStore && targetStore !== null ? 'error' : 'none')
      };
      this.workQueue.enqueue(kind, snapshot, capture,
        (result: ReplayWorkerResult | null, error: string): void => {
          try {
            this.completeWorkerSnapshot(kind, context, generation, result, error, rumContext, promoteErrorAt, queuedAt);
          } finally {
            completePersistence();
          }
        });
    } catch (error) {
      completePersistence();
      throw new Error(String(error));
    }
  }

  /** UI-only validation and FrameNode read shared by automatic lifecycle paths. */
  private captureRootLight(uiContext: UIContext, rootId: string, scale: number): ArkUIReplayLightSnapshot {
    const startedAt = Date.now();
    const snapshot = this.collectRootLight(uiContext, rootId, scale);
    this.hasActiveComponentAnimations = snapshot.hasActiveAnimations === true;
    if (this.config.isPerformanceDiagnosticsEnabled()) snapshot.collectionDurationMs = Math.max(0, Date.now() - startedAt);
    return snapshot;
  }

  private collectRootLight(uiContext: UIContext, rootId: string, scale: number): ArkUIReplayLightSnapshot {
    const binding = this.rootBinding;
    if (binding !== null && binding.rootId === rootId &&
      (binding.captureScene || this.navigationPages.size > 0)) {
      const pages = this.getScenePages(binding);
      if (this.sceneViewport === null) {
        const root = uiContext.getFrameNodeById(rootId);
        if (root !== null) {
          const position = root.getPositionToWindow();
          const size = root.getMeasuredSize();
          if (size.width > 0 && size.height > 0) this.sceneViewport = {
            x: position.x, y: position.y, width: size.width / scale, height: size.height / scale
          };
        }
      }
      const pageIds = pages.map((page: ArkUIReplayScenePage): string => page.rootId);
      return this.collector.captureSceneLight(uiContext, pageIds, scale, Date.now(),
        this.pageTransitions, this.sceneViewport, pages);
    }
    if (binding !== null && binding.rootId === rootId && binding.sceneRoot !== null && binding.sceneRoot.isAttached()) {
      return this.collector.captureFrameNodeLight(binding.sceneRoot, scale);
    }
    return this.collector.captureLightSnapshot(uiContext, rootId, scale);
  }

  private captureLightSnapshotForContext(context: SessionReplayContext): ArkUIReplayLightSnapshot | null {
    if (!this.isStarted) {
      this.lastCaptureFailure = 'Session Replay recorder is not started.';
      return null;
    }
    const rootBinding = this.rootBinding;
    if (rootBinding === null) {
      this.lastCaptureFailure = 'No ArkUI Replay root is registered for the active page.';
      return null;
    }
    if (context.applicationId.length === 0 || context.sessionId.length === 0 || context.viewId.length === 0) {
      this.lastCaptureFailure = 'The active RUM View does not have complete application, session, and view identifiers.';
      return null;
    }
    try {
      return this.captureRootLight(
        rootBinding.uiContext,
        rootBinding.rootId,
        rootBinding.vpToPxScale
      );
    } catch (error) {
      this.lastCaptureFailure = `ArkUI FrameNode snapshot failed: ${String(error)}`;
      return null;
    }
  }

  private completeWorkerSnapshot(
    kind: ReplaySnapshotKind,
    context: SessionReplayContext,
    generation: number,
    result: ReplayWorkerResult | null,
    error: string,
    rumContext: FTSessionReplayRUMContext | null,
    promoteErrorAt: number | null,
    queuedAt: number = 0
  ): void {
    if (error === REPLAY_COALESCED_REASON) return;
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    const endedStart = kind === 'start' && this.isEndedStart(context, generation);
    const currentCapture = this.isCurrentCapture(context, generation);
    if (kind === 'start' && this.pendingViewStarts.get(key) === generation) this.pendingViewStarts.delete(key);
    if (endedStart) this.endedViewStarts.delete(key);
    if (result === null || !result.stored) {
      if (currentCapture) this.baselineContextKey = '';
      this.lastCaptureFailure = result === null ? error : result.writeError;
      if (kind !== 'automatic') {
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay ${kind} snapshot failed: session=${context.sessionId}, view=${context.viewId}, reason=${this.lastCaptureFailure}`,
          true);
      }
      if (result !== null) this.removeWorkerSegments(result);
      if (currentCapture && (kind === 'automatic' || kind === 'settled') && error !== REPLAY_STALE_QUEUE_REASON) {
        this.lastFullSnapshotAt = 0;
      }
      if (currentCapture && this.isStarted && kind === 'start' && result === null && error === REPLAY_STALE_QUEUE_REASON && rumContext !== null) {
        this.queueViewStartedFromRUMContext(rumContext, promoteErrorAt);
      }
      if (currentCapture && this.isStarted && (kind === 'automatic' || kind === 'settled') &&
        (error === REPLAY_STALE_QUEUE_REASON || Date.now() < this.motionUntil)) this.scheduleAutomaticCapture();
      return;
    }
    this.resourceTouch?.(result.resourceNames ?? [], result.storeKind);
    if (currentCapture) {
      if (this.baselineContextKey !== key) {
        this.processor.reset();
        this.pendingManualBaseline.splice(0);
      }
      this.baselineContextKey = key;
      this.pendingManualBaseline.push(...result.records);
      if (this.pendingManualBaseline.length > FTSessionReplayRecorder.MAX_RECORDS_PER_VIEW) {
        this.pendingManualBaseline.splice(0);
        this.processor.reset();
      }
    }
    if (result.records.length === 0) return;
    const capture = this.createCaptureFromWorker(context, result);
    this.appendRecordedRecords(context, result.records, false);
    this.lastCapture = capture;
    this.lastCaptureFailure = '';
    if (currentCapture) {
      this.lastFullSnapshotAt = result.lastFullSnapshotAt;
      this.observedViewport = result.viewport;
    }
    if (kind === 'start') {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay first frame saved: session=${context.sessionId}, view=${context.viewId}, records=${result.records.length}, segments=${result.segmentIds.length}, elapsedMs=${Math.max(0, Date.now() - queuedAt)}`);
    }
    if (kind === 'start' && rumContext !== null) {
      this.recordViewMetadata(rumContext, result.records.length);
    } else {
      this.recordReplayMetadata(context, result.records.length);
    }
    if (promoteErrorAt !== null && this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.ERROR) {
      this.promoteErrorSampledSession(context.sessionId, promoteErrorAt);
    } else if (result.storeKind === 'error' && this.promotedErrorSessions.has(context.sessionId)) {
      this.enqueueReplayPromotion(context.sessionId, Date.now(),
        (success: boolean, failure: string): void => {
          if (!success) this.lastCaptureFailure = failure;
        });
    }
  }

  private removeWorkerSegments(result: ReplayWorkerResult): void {
    this.workQueue.enqueueRemove(result.storeKind, result.segmentIds,
      (success: boolean, failure: string): void => {
        if (!success) this.lastCaptureFailure = failure;
      });
  }

  private createCaptureFromWorker(context: SessionReplayContext, result: ReplayWorkerResult): SessionReplayCapture {
    return {
      envelope: createReplayEnvelope(context, result.records),
      payload: result.payload,
      records: result.records.slice(),
      record: result.records[result.records.length - 1],
      wireframeCount: result.wireframeCount
    };
  }

  private captureWithRegisteredRoot(context: SessionReplayContext): SessionReplayCapture | null {
    if (!this.isStarted) {
      this.lastCaptureFailure = 'Session Replay recorder is not started.';
      return null;
    }
    if (this.rootBinding === null) {
      this.lastCaptureFailure = 'No ArkUI Replay root is registered for the active page.';
      return null;
    }
    if (context.applicationId.length === 0 || context.sessionId.length === 0 || context.viewId.length === 0) {
      this.lastCaptureFailure = 'The active RUM View does not have complete application, session, and view identifiers.';
      return null;
    }
    try {
      const record = this.collector.materializeLightSnapshot(this.captureRootLight(
        this.rootBinding.uiContext, this.rootBinding.rootId, this.rootBinding.vpToPxScale));
      this.persistCapturedImageResources(context, record);
      return this.createCapture(context, [record], record);
    } catch (error) {
      this.lastCaptureFailure = `ArkUI Full Snapshot collection failed: ${String(error)}`;
      return null;
    }
  }

  private toReplayContext(context: FTSessionReplayRUMContext): SessionReplayContext {
    const replayContext: SessionReplayContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
    if (Object.keys(context.linkContext).length > 0) {
      replayContext.globalContext = context.linkContext;
    }
    return replayContext;
  }

  /** Keeps native RUM link fields while applying the changed Browser values. */
  private mergeWebLinkContext(context: FTSessionReplayWebContextChange): FTSessionReplayRUMContext {
    const linkContext: Record<string, string | number | boolean> = {};
    const activeContext = this.activeContext;
    if (activeContext !== null && activeContext.applicationId === context.applicationId &&
      activeContext.sessionId === context.sessionId && activeContext.viewId === context.viewId &&
      activeContext.globalContext !== undefined) {
      const previousKeys = Object.keys(activeContext.globalContext);
      for (let index = 0; index < previousKeys.length; index++) {
        const key = previousKeys[index];
        linkContext[key] = activeContext.globalContext[key];
      }
    }
    const webKeys = Object.keys(context.linkContext);
    for (let index = 0; index < webKeys.length; index++) {
      const key = webKeys[index];
      linkContext[key] = context.linkContext[key];
    }
    return {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId,
      viewName: context.viewName,
      viewReferrer: context.viewReferrer,
      linkContext,
      timestamp: context.timestamp
    };
  }

  private isSameView(left: SessionReplayContext, right: SessionReplayContext): boolean {
    return left.applicationId === right.applicationId && left.sessionId === right.sessionId && left.viewId === right.viewId;
  }

  private isSameReplayContext(left: SessionReplayContext, right: SessionReplayContext): boolean {
    return this.isSameView(left, right) && this.getContextSignature(left) === this.getContextSignature(right);
  }

  private getContextSignature(context: SessionReplayContext): string {
    const globalContext = context.globalContext;
    if (globalContext === undefined) {
      return '';
    }
    const keys = Object.keys(globalContext).sort();
    const values: Array<string> = [];
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      values.push(`${key}=${String(globalContext[key])}`);
    }
    return values.join('&');
  }

  private recordViewMetadata(context: FTSessionReplayRUMContext, recordsCount: number): void {
    const replayContext = this.toReplayContext(context);
    this.recordReplayMetadata(replayContext, recordsCount);
  }

  private recordReplayMetadata(context: SessionReplayContext, recordsCount: number): void {
    if (recordsCount <= 0) {
      return;
    }
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    const existing = this.viewMetadata.get(key);
    const sampledOnError = this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.ERROR;
    this.viewMetadata.set(key, {
      hasReplay: true,
      recordsCount: (existing === undefined ? 0 : existing.recordsCount) + recordsCount,
      sampledOnError
    });
    this.recordedContextsByView.set(key, this.copyReplayContext(context));
    this.notifyReplayMetadata(context);
  }

  private createReplayRUMContext(context: SessionReplayContext): FTSessionReplayRUMContext {
    return {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId,
      viewName: '',
      viewReferrer: '',
      linkContext: context.globalContext ?? {},
      timestamp: Date.now() * 1000000
    };
  }

  private notifyReplayMetadata(context: SessionReplayContext): void {
    const rumContext = this.createReplayRUMContext(context);
    FTSessionReplayBridgeRegistry.notifyViewMetadataChanged(rumContext, this.getViewMetadata(rumContext));
  }

  private getViewMetadataKey(context: FTSessionReplayRUMContext): string {
    return this.getViewKey(context.applicationId, context.sessionId, context.viewId);
  }

  private getViewKey(applicationId: string, sessionId: string, viewId: string): string {
    return `${applicationId}|${sessionId}|${viewId}`;
  }

  private appendRecordedRecords(
    context: SessionReplayContext,
    records: Array<SessionReplayRecord>,
    persist: boolean = true,
    requiresStart: boolean = false,
    baselineSnapshot: SessionReplayRecord | null = null
  ): boolean {
    if (records.length === 0) {
      return true;
    }
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    // Native manual snapshots join the in-memory stream at commit time too,
    // so an earlier automatic frame cannot appear after a later manual one.
    if (!persist || baselineSnapshot === null) {
      const current = this.recordedRecordsByView.get(key) ?? [];
      for (let index = 0; index < records.length; index++) current.push(records[index]);
      const overflow = current.length - FTSessionReplayRecorder.MAX_RECORDS_PER_VIEW;
      if (overflow > 0) current.splice(0, overflow);
      this.recordedRecordsByView.set(key, current);
    }
    if (!persist) {
      return true;
    }
    const targetStore = this.getStoreForContext(context);
    const storeKind: ReplayStoreKind = targetStore === this.store && targetStore !== null ? 'main' :
      (targetStore === this.errorSampleStore && targetStore !== null ? 'error' : 'none');
    const completePersistence = FTSessionReplayBridgeRegistry.beginViewPersistence(this.createReplayRUMContext(context));
    let accepted = false;
    try {
      accepted = this.workQueue.enqueueRecords(this.copyReplayContext(context), records, storeKind,
        (success: boolean, failure: string, writtenRecords?: Array<SessionReplayRecord>): void => {
          try {
            if (!success) {
              this.lastCaptureFailure = failure;
              this.baselineContextKey = '';
              return;
            }
            const committedRecords = writtenRecords ?? records;
            if (baselineSnapshot !== null) {
              this.appendRecordedRecords(context, committedRecords, false);
              this.pendingManualBaseline.splice(0);
              this.processor.setFullSnapshotBaseline(baselineSnapshot);
              this.baselineContextKey = key;
              if (committedRecords.some((record: SessionReplayRecord): boolean =>
                record.type === ReplayRecordType.FULL_SNAPSHOT && record.slotId === undefined)) {
                this.lastFullSnapshotAt = baselineSnapshot.timestamp;
              }
            }
            this.recordReplayMetadata(context, committedRecords.length);
            // Stop can queue View End before an earlier Error snapshot promotes
            // the session. Move that already-targeted error batch as well.
            if (storeKind === 'error' && this.promotedErrorSessions.has(context.sessionId)) {
              this.enqueueReplayPromotion(context.sessionId, Date.now(),
                (promoted: boolean, promotionFailure: string): void => {
                  if (!promoted) this.lastCaptureFailure = promotionFailure;
                });
            }
          } finally {
            completePersistence();
          }
        }, requiresStart, baselineSnapshot,
        baselineSnapshot === null ? null : this.getViewportBounds(baselineSnapshot));
    } finally {
      // enqueueRecords can reject before invoking its completion callback.
      if (!accepted) completePersistence();
    }
    if (!accepted) {
      this.lastCaptureFailure = 'Session Replay Worker did not accept the record batch.';
      this.baselineContextKey = '';
    }
    return accepted;
  }

  /** Appends a lifecycle signal only when it belongs to an active sampled View. */
  private appendActiveProtocolRecords(
    records: Array<SessionReplayRecord>,
    fullSnapshot: SessionReplayRecord | null
  ): SessionReplayCapture | null {
    const onlyPointerMoves = records.every((record: SessionReplayRecord): boolean => {
      const data = record.data as ReplayPointerInteractionData;
      return record.slotId === undefined && record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT &&
        data.source === 9 && data.pointerEventType === 'move';
    });
    if (this.captureDeferred && !onlyPointerMoves) this.captureActiveViewMutation('settled');
    const activeContext = this.activeContext;
    if (activeContext === null || !this.canRecordActiveContext(activeContext)) {
      return null;
    }
    const capture = this.createCapture(activeContext, records, fullSnapshot);
    if (!this.appendRecordedRecords(activeContext, capture.records, true, true, fullSnapshot)) {
      return null;
    }
    this.lastCapture = capture;
    return capture;
  }

  private canRecordActiveContext(context: SessionReplayContext): boolean {
    return this.isStarted &&
      this.sampler.decide(context.sessionId) !== SessionReplaySamplingMode.NONE;
  }

  private getStoreForContext(context: SessionReplayContext): SessionReplaySegmentStore | null {
    const sampling = this.sampler.decide(context.sessionId);
    if (sampling === SessionReplaySamplingMode.ERROR && !this.promotedErrorSessions.has(context.sessionId)) {
      return this.errorSampleStore;
    }
    return this.store;
  }

  private promoteErrorSampledSession(sessionId: string, timestamp: number): boolean {
    if (this.promotedErrorSessions.has(sessionId)) {
      return true;
    }
    if (this.errorSampleStore === null || this.store === null) {
      return false;
    }
    const resourcesPromoted = this.errorSampleResourcePromoter === null ||
      this.errorSampleResourcePromoter(sessionId, timestamp);
    if (!resourcesPromoted) return false;
    this.promotedErrorSessions.add(sessionId);
    const accepted = this.enqueueReplayPromotion(sessionId, timestamp,
      (success: boolean, failure: string): void => {
        if (!success) {
          this.lastCaptureFailure = failure;
          this.promotedErrorSessions.delete(sessionId);
        } else {
          this.recordedContextsByView.forEach((context: SessionReplayContext): void => {
            if (context.sessionId === sessionId) this.notifyReplayMetadata(context);
          });
        }
      });
    if (!accepted) this.promotedErrorSessions.delete(sessionId);
    return accepted;
  }

  private enqueueReplayPromotion(
    sessionId: string,
    timestamp: number,
    finish: (success: boolean, failure: string) => void
  ): boolean {
    const completions: Array<() => void> = [];
    this.recordedContextsByView.forEach((context: SessionReplayContext): void => {
      if (context.sessionId === sessionId) {
        completions.push(FTSessionReplayBridgeRegistry.beginViewPersistence(this.createReplayRUMContext(context)));
      }
    });
    const completePersistence = (): void => {
      for (let index = 0; index < completions.length; index++) completions[index]();
    };
    let accepted = false;
    try {
      accepted = this.workQueue.enqueuePromotion(sessionId, timestamp,
        (success: boolean, failure: string, resources?: Array<string>): void => {
          this.resourceTouch?.(resources ?? [], 'main');
          try {
            finish(success, failure);
          } finally {
            completePersistence();
          }
        });
    } finally {
      if (!accepted) completePersistence();
    }
    return accepted;
  }

  private startObservation(): void {
    this.stopObservation();
    if (!this.isStarted || this.rootBinding === null || this.activeContext === null) {
      return;
    }
    // Drawing also covers text/style changes that do not resize the root and
    // works independently of application-owned onAreaChange/onTouch callbacks.
    const uiContext = this.rootBinding.uiContext;
    try {
      uiContext.getUIObserver().on('willDraw', this.drawListener);
      this.drawObserverContext = uiContext;
    } catch (_) {
      // Explicit page notifications remain available on unsupported contexts.
    }
    this.notifyPageChanged();
  }

  private stopObservation(): void {
    this.hasActiveComponentAnimations = false;
    this.samplingFrameEpoch++;
    this.nextSamplingDeadline = 0;
    const uiContext = this.drawObserverContext;
    this.drawObserverContext = null;
    if (uiContext !== null) {
      try {
        uiContext.getUIObserver().off('willDraw', this.drawListener);
      } catch (_) { }
    }
    if (this.mutationCaptureTimer !== -1) {
      clearTimeout(this.mutationCaptureTimer);
      this.mutationCaptureTimer = -1;
    }
    if (this.viewportCaptureTimer !== -1) {
      clearTimeout(this.viewportCaptureTimer);
      this.viewportCaptureTimer = -1;
    }
  }

  private captureActiveViewMutation(kind: 'automatic' | 'transition' | 'settled' = 'automatic'): void {
    const context = this.activeContext;
    const rootBinding = this.rootBinding;
    if (!this.isStarted || context === null || rootBinding === null) {
      return;
    }
    const timestamp = Date.now();
    const defaultInFlight = kind === 'automatic' && this.getRootScenePages(rootBinding)
      .some((page: ArkUIReplayScenePage): boolean => {
        const transition = page.defaultTransition;
        return transition !== undefined && timestamp >= transition.startedAt &&
          timestamp < transition.startedAt + transition.durationMs;
      });
    const sampleKind: ReplaySnapshotKind = defaultInFlight ? 'transition' : kind;
    if (!this.workQueue.shouldCapture(context, sampleKind)) {
      this.captureDeferred = true;
      this.scheduleAutomaticCapture();
      return;
    }
    try {
      const lightSnapshot = this.captureRootLight(rootBinding.uiContext, rootBinding.rootId, rootBinding.vpToPxScale);
      this.captureDeferred = false;
      const generation = this.captureGeneration;
      const contextSnapshot = this.copyReplayContext(context);
      this.enqueueWorkerSnapshot(sampleKind,
        lightSnapshot, contextSnapshot, generation, null, null);
    } catch (_error) {
      // A root can disappear between an ArkUI lifecycle callback and capture.
      // The next page-change signal will retry after its layout has settled.
    }
  }

  /** Samples motion at the configured interval, retaining a final frame too. */
  private scheduleAutomaticCapture(): void {
    if (!this.isStarted || this.rootBinding === null || this.activeContext === null) {
      return;
    }
    // Keep the first deadline so neither drawing nor pointer moves postpone it.
    if (this.mutationCaptureTimer !== -1) return;
    const interval = this.config.getSnapshotIntervalMs();
    const now = Date.now();
    const next = this.nextSamplingDeadline === 0 ? now + interval : this.nextSamplingDeadline + interval;
    // Anchor to deadlines rather than frame completion; never burst to catch up.
    this.nextSamplingDeadline = next <= now ? now + interval : next;
    const delay = this.nextSamplingDeadline - now;
    const epoch = ++this.samplingFrameEpoch;
    const run = (): void => {
      if (epoch !== this.samplingFrameEpoch || this.mutationCaptureTimer === -1) return;
      this.samplingFrameEpoch++;
      clearTimeout(this.mutationCaptureTimer);
      this.mutationCaptureTimer = -1;
      const settled = this.motionUntil > 0 && Date.now() >= this.motionUntil && !this.hasSamplingSceneMotion();
      if (settled) this.motionUntil = 0;
      this.captureActiveViewMutation(settled ? 'settled' : 'automatic');
      if (Date.now() < this.motionUntil || this.hasSamplingSceneMotion()) this.scheduleAutomaticCapture();
      if (this.mutationCaptureTimer === -1) this.nextSamplingDeadline = 0;
    };
    try {
      this.rootBinding.uiContext.postDelayedFrameCallback(new ReplaySamplingFrame(run), delay);
      // An idle/detached surface may not produce a display frame. Keep a
      // bounded fallback for its final state; the epoch prevents duplicates.
      this.mutationCaptureTimer = setTimeout(run, delay + 32);
    } catch (_) {
      this.mutationCaptureTimer = setTimeout(run, delay);
    }
  }

  private hasSamplingSceneMotion(): boolean {
    if (this.hasActiveComponentAnimations) return true;
    if (this.hasRetainedScenePages()) return true;
    const binding = this.rootBinding;
    const now = Date.now();
    return binding !== null && this.getRootScenePages(binding).some((page: ArkUIReplayScenePage): boolean => {
      const transition = page.defaultTransition;
      return transition !== undefined && now >= transition.startedAt && now < transition.startedAt + transition.durationMs;
    });
  }

  private hasRetainedScenePages(): boolean {
    if (this.rootBinding?.scenePages?.some((page: ArkUIReplayScenePage): boolean => page.retained)) return true;
    let retained = false;
    this.navigationPages.forEach((page: ReplayNavigationPage): void => {
      if (page.retained) retained = true;
    });
    return retained;
  }

  private isCurrentCapture(context: SessionReplayContext, generation: number): boolean {
    return (this.isStarted || this.isStopping) && generation === this.captureGeneration && this.activeContext !== null &&
      this.isSameReplayContext(this.activeContext, context);
  }

  private isEndedStart(context: SessionReplayContext, generation: number): boolean {
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    return this.endedViewStarts.get(key) === generation;
  }

  private copyReplayContext(context: SessionReplayContext): SessionReplayContext {
    const result: SessionReplayContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
    if (context.globalContext !== undefined) {
      result.globalContext = {};
      const keys = Object.keys(context.globalContext);
      for (let index = 0; index < keys.length; index++) {
        const key = keys[index];
        result.globalContext[key] = context.globalContext[key];
      }
    }
    return result;
  }

  private sameWindow(left: UIContext, right: UIContext): boolean {
    if (left === right) return true;
    try {
      const id = left.getWindowId();
      return id !== undefined && id === right.getWindowId();
    } catch (_) { return false; }
  }

  private usesSceneCoordinates(): boolean {
    return this.rootBinding !== null &&
      (this.rootBinding.captureScene || this.navigationPages.size > 0);
  }

  private sceneOriginX(): number {
    return this.usesSceneCoordinates() ? (this.sceneViewport?.x ?? 0) : 0;
  }

  private sceneOriginY(): number {
    return this.usesSceneCoordinates() ? (this.sceneViewport?.y ?? 0) : 0;
  }

  private bindTransitionObserver(uiContext: UIContext): void {
    if (this.transitionObserverContext === uiContext) return;
    this.unbindTransitionObserver();
    this.transitionObserverContext = uiContext;
    try {
      const observer = uiContext.getUIObserver();
      // Subscribe independently: an unavailable event must not disable others.
      try { observer.on('routerPageUpdate', this.routerTransitionListener); } catch (_) { }
      try { observer.on('navDestinationSwitch', this.navigationSwitchListener); } catch (_) { }
      try { observer.on('navDestinationUpdate', this.navigationStateListener); } catch (_) { }
    } catch (_) { }
  }

  private unbindTransitionObserver(): void {
    const context = this.transitionObserverContext;
    this.transitionObserverContext = null;
    if (context === null) return;
    try {
      const observer = context.getUIObserver();
      try { observer.off('routerPageUpdate', this.routerTransitionListener); } catch (_) { }
      try { observer.off('navDestinationSwitch', this.navigationSwitchListener); } catch (_) { }
      try { observer.off('navDestinationUpdate', this.navigationStateListener); } catch (_) { }
    } catch (_) { }
  }

  private ensureNavigationPage(info: uiObserver.NavDestinationInfo): ReplayNavigationPage | null {
    const binding = this.rootBinding;
    if (binding === null || info.uniqueId === undefined) return null;
    const key = `navigation:${info.uniqueId}`;
    const existing = this.navigationPages.get(key);
    if (existing !== undefined) return existing;
    try {
      const root = binding.uiContext.getFrameNodeByUniqueId(info.uniqueId);
      if (root === null) return null;
      const parentKey = this.findNavigationHost(root, binding);
      if (parentKey === null) return null;
      const page: ReplayNavigationPage = {
        key, root, parentKey, visible: true, retained: false,
        paintOrder: ++this.nextNavigationPaintOrder, releaseTimer: -1
      };
      this.navigationPages.set(key, page);
      return page;
    } catch (_) { return null; }
  }

  private findNavigationHost(root: FrameNode, binding: SessionReplayRootBinding): string | null {
    if (binding.scenePages === null) return binding.rootId;
    let current: FrameNode | null = root;
    for (let depth = 0; depth < 64 && current !== null; depth++) {
      try {
        const id = current.getUniqueId();
        const host = binding.scenePages.find((page: ArkUIReplayScenePage): boolean => page.root?.getUniqueId() === id);
        if (host !== undefined) return host.key;
        current = current.getParent();
      } catch (_) { break; }
    }
    // A destination on a not-yet-registered Router page must not be attached
    // to the previous page just because its lifecycle observer ran first.
    return null;
  }

  private onNavigationPageState(info: uiObserver.NavDestinationInfo): void {
    const page = this.ensureNavigationPage(info);
    if (page === null) { this.notifyTransition(); return; }
    const state = info.state;
    if (state === uiObserver.NavDestinationState.ON_WILL_HIDE ||
      state === uiObserver.NavDestinationState.ON_WILL_DISAPPEAR) {
      this.retainNavigationPage(page);
      this.captureActiveViewMutation();
    } else if (state === uiObserver.NavDestinationState.ON_HIDDEN ||
      state === uiObserver.NavDestinationState.ON_DISAPPEAR) {
      page.visible = false;
      const progress = this.pageTransitions.get(page.key);
      if (progress === undefined || progress.progress >= 1) {
        if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
        this.navigationPages.delete(page.key);
      }
    } else if (state === uiObserver.NavDestinationState.ON_WILL_SHOW ||
      state === uiObserver.NavDestinationState.ON_SHOWN || state === uiObserver.NavDestinationState.ON_APPEAR) {
      page.visible = true;
      page.retained = false;
      if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
      page.releaseTimer = -1;
    }
    this.notifyTransition();
  }

  private retainNavigationPage(page: ReplayNavigationPage): void {
    page.visible = false;
    page.retained = true;
    if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
    page.releaseTimer = setTimeout((): void => {
      page.releaseTimer = -1;
      if (this.navigationPages.get(page.key) !== page || page.visible) return;
      this.navigationPages.delete(page.key);
      this.pageTransitions.delete(page.key);
      this.notifyTransition();
    }, 10000);
  }

  private clearNavigationPages(): void {
    this.navigationPages.forEach((page: ReplayNavigationPage): void => {
      if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
    });
    this.navigationPages.clear();
  }

  private getRootScenePages(binding: SessionReplayRootBinding): Array<ArkUIReplayScenePage> {
    return binding.scenePages ??
      (binding.sceneRootIds.length > 0 ? binding.sceneRootIds : [binding.rootId])
        .map((id: string): ArkUIReplayScenePage => {
          return { key: id, rootId: id, root: binding.uiContext.getFrameNodeById(id), retained: false };
        });
  }

  private getScenePages(binding: SessionReplayRootBinding): Array<ArkUIReplayScenePage> {
    const roots = this.getRootScenePages(binding);
    const result: Array<ArkUIReplayScenePage> = [];
    this.navigationPages.forEach((page: ReplayNavigationPage): void => {
      const host = this.findNavigationHost(page.root, binding);
      if (host !== null) page.parentKey = host;
    });
    const rootKeys = new Set<string>();
    for (const root of roots) {
      rootKeys.add(root.key);
      result.push(root);
      const children: Array<ReplayNavigationPage> = [];
      this.navigationPages.forEach((page: ReplayNavigationPage): void => {
        if (page.parentKey === root.key && (page.visible || page.retained)) children.push(page);
      });
      children.sort((left: ReplayNavigationPage, right: ReplayNavigationPage): number => left.paintOrder - right.paintOrder);
      for (const page of children) result.push({ key: page.key, rootId: page.key, root: page.root,
        retained: page.retained, parentKey: root.key, paintOrder: page.paintOrder });
    }
    this.navigationPages.forEach((page: ReplayNavigationPage, key: string): void => {
      if (!rootKeys.has(page.parentKey)) {
        if (page.releaseTimer !== -1) clearTimeout(page.releaseTimer);
        this.navigationPages.delete(key);
        this.pageTransitions.delete(key);
      }
    });
    return result;
  }

  private refreshWindowSceneViewport(): void {
    const nativeWindow = this.nativeWindow;
    const binding = this.rootBinding;
    if (nativeWindow === null || binding === null) return;
    try {
      const rect = nativeWindow.getWindowProperties().drawableRect;
      const scale = binding.vpToPxScale > 0 ? binding.vpToPxScale : 1;
      if (![rect.left, rect.top, rect.width, rect.height].every((value: number): boolean => Number.isFinite(value)) ||
        rect.width <= 0 || rect.height <= 0) return;
      this.sceneViewport = { x: rect.left / scale, y: rect.top / scale,
        width: rect.width / scale, height: rect.height / scale };
    } catch (_) { }
  }

  private attachWindowViewportObserver(nativeWindow: window.Window, epoch: number): void {
    if (epoch !== this.windowObserverEpoch || this.rootBinding === null) return;
    try {
      const windowId = this.rootBinding.uiContext.getWindowId();
      if (windowId !== undefined && windowId !== nativeWindow.getWindowProperties().id) return;
    } catch (_) { }
    this.nativeWindow = nativeWindow;
    this.refreshWindowSceneViewport();
    try { nativeWindow.on('windowSizeChange', this.windowSizeChangeListener); } catch (_) { }
    try { nativeWindow.on('keyboardHeightChange', this.keyboardHeightChangeListener); } catch (_) { }
    try { nativeWindow.on('avoidAreaChange', this.avoidAreaChangeListener); } catch (_) { }
    this.scheduleViewportCapture();
  }

  /** Reads the root's already normalized viewport dimensions from a snapshot. */
  private getViewportBounds(snapshot: SessionReplayRecord): SessionReplayViewportBounds | null {
    if (snapshot.type !== ReplayRecordType.FULL_SNAPSHOT) {
      return null;
    }
    const data = snapshot.data as FullSnapshotData;
    if (data.wireframes.length === 0) {
      return null;
    }
    return this.getRootViewport(data.wireframes[0].width, data.wireframes[0].height);
  }

  private getRootViewport(width: number | undefined, height: number | undefined): SessionReplayViewportBounds | null {
    if (width === undefined || height === undefined) return null;
    const root: ReplayViewport = { width, height };
    if (!Number.isFinite(root.width) || !Number.isFinite(root.height) || root.width <= 0 || root.height <= 0) {
      return null;
    }
    const rootBounds: SessionReplayViewportBounds = { width: root.width, height: root.height };
    let viewport = rootBounds;
    if (this.keyboardHeightPx > 0) {
      if (this.keyboardResizesRoot === null) {
        const previousRoot = this.observedRootViewport;
        this.keyboardResizesRoot = previousRoot !== null && rootBounds.height < previousRoot.height;
      }
      if (!this.keyboardResizesRoot) {
        const keyboardHeight = this.normalizePhysicalLength(this.keyboardHeightPx);
        const visibleHeight = rootBounds.height - keyboardHeight;
        if (visibleHeight > 0) {
          viewport = { width: rootBounds.width, height: visibleHeight };
        }
      }
    }
    this.observedRootViewport = rootBounds;
    return viewport;
  }

  private hasViewportChanged(next: SessionReplayViewportBounds): boolean {
    const previous = this.observedViewport;
    return previous === null || previous.width !== next.width || previous.height !== next.height;
  }

  /** Subscribes to native resize and IME events for the window hosting this root. */
  private bindWindowViewportObserver(uiContext: UIContext): void {
    const hostContext = uiContext.getHostContext();
    if (hostContext === undefined) {
      return;
    }
    const epoch = ++this.windowObserverEpoch;
    try {
      const name = uiContext.getWindowName();
      if (name !== undefined) {
        this.attachWindowViewportObserver(window.findWindow(name), epoch);
        return;
      }
    } catch (_) { }
    try {
      window.getLastWindow(hostContext)
        .then((nativeWindow: window.Window): void => {
          this.attachWindowViewportObserver(nativeWindow, epoch);
        })
        .catch((): void => {
          // A page can be detached while its UIContext is resolving a window.
        });
    } catch (_) {
      // Keep collection available for UI contexts without a host window.
    }
  }

  private unbindWindowViewportObserver(): void {
    this.windowObserverEpoch++;
    const nativeWindow = this.nativeWindow;
    this.nativeWindow = null;
    if (nativeWindow === null) {
      return;
    }
    try { nativeWindow.off('windowSizeChange', this.windowSizeChangeListener); } catch (_) { }
    try { nativeWindow.off('keyboardHeightChange', this.keyboardHeightChangeListener); } catch (_) { }
    try { nativeWindow.off('avoidAreaChange', this.avoidAreaChangeListener); } catch (_) { }
  }

  /** Defers until ArkUI has applied the new window or IME layout. */
  private scheduleViewportCapture(): void {
    if (this.viewportCaptureTimer !== -1) {
      clearTimeout(this.viewportCaptureTimer);
    }
    this.viewportCaptureTimer = setTimeout((): void => {
      this.viewportCaptureTimer = -1;
      this.captureActiveViewMutation();
    }, 16);
  }

  private resetViewportObservation(preserveWindowState: boolean = false): void {
    this.observedViewport = null;
    if (!preserveWindowState) {
      this.observedRootViewport = null;
      this.keyboardHeightPx = 0;
      this.keyboardResizesRoot = null;
    }
  }

  /**
   * Converts collector-local image tokens into content-addressed resource ids.
   * Resource files are queued before the replay segment that references them;
   * `FTSessionReplay.flush()` drains this resource queue first.
   */
  private persistCapturedImageResources(
    context: SessionReplayContext,
    record: SessionReplayRecord,
    capturedResources?: Array<CapturedReplayImageResource>
  ): void {
    const resources = capturedResources ?? this.collector.takeCapturedImageResources();
    if (resources.length === 0) {
      return;
    }
    const resourceIds = new Map<string, string>();
    if (this.imageResourceWriter !== null) {
      for (let index = 0; index < resources.length; index++) {
        const resource: CapturedReplayImageResource = resources[index];
        const resourceId = this.imageResourceWriter(context, resource.bytes, resource.mimeType);
        if (resourceId !== null) {
          resourceIds.set(resource.token, resourceId);
        }
      }
    }
    const data = record.data as FullSnapshotData;
    for (let index = 0; index < data.wireframes.length; index++) {
      const wireframe = data.wireframes[index];
      if (wireframe.type !== 'image' || wireframe.resourceId === undefined) {
        continue;
      }
      const resourceId = resourceIds.get(wireframe.resourceId);
      if (resourceId === undefined) {
        const image = wireframe as ReplayImageWireframe;
        const masked: ReplayImageWireframe = {
          id: image.id,
          x: image.x,
          y: image.y,
          width: image.width,
          height: image.height,
          type: 'image',
          isEmpty: true
        };
        if (image.shapeStyle !== undefined) masked.shapeStyle = image.shapeStyle;
        if (image.border !== undefined) masked.border = image.border;
        if (image.permanentId !== undefined) masked.permanentId = image.permanentId;
        if (image.clip !== undefined) masked.clip = image.clip;
        if (image.zIndex !== undefined) masked.zIndex = image.zIndex;
        data.wireframes[index] = masked;
      } else {
        wireframe.resourceId = resourceId;
      }
    }
  }

  private createCapture(
    context: SessionReplayContext,
    records: Array<SessionReplayRecord>,
    snapshotRecord: SessionReplayRecord | null
  ): SessionReplayCapture {
    const record = records[records.length - 1];
    return {
      envelope: createReplayEnvelope(context, records),
      payload: serializeReplayEnvelope(context, records),
      records: records.slice(),
      record,
      wireframeCount: snapshotRecord === null ? 0 : this.getWireframeCount(snapshotRecord)
    };
  }

}
