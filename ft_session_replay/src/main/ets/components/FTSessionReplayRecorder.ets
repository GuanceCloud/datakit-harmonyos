import { UIContext } from '@kit.ArkUI';
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
  CapturedReplayImageResource
} from './ArkUIReplayCollector';
import { FTSessionReplayConfig, TextAndInputPrivacy, TouchPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from './SessionReplaySampler';
import { SessionReplaySegmentStore } from './SessionReplaySegmentStore';
import {
  ReplayWorkerCommit,
  ReplayWorkerResult,
  ReplayStoreKind,
  ReplayViewport,
  REPLAY_STALE_QUEUE_REASON,
  SessionReplayWorkQueue
} from './SessionReplayWorkQueue';
import {
  createReplayEnvelope,
  FullSnapshotData,
  ReplayImageWireframe,
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
}

/** The normalized bounds of the currently visible native root. */
type SessionReplayViewportBounds = ReplayViewport;

interface BrowserReplayRecord {
  timestamp?: number;
  type?: number;
  data?: object;
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
  private readonly viewMetadata: Map<string, FTSessionReplayViewMetadata> = new Map();
  private readonly recordedContextsByView: Map<string, SessionReplayContext> = new Map();
  private readonly recordedRecordsByView: Map<string, Array<SessionReplayRecord>> = new Map();
  private readonly promotedErrorSessions: Set<string> = new Set();
  private readonly errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null;
  private readonly imageResourceWriter: ((context: SessionReplayContext, data: Uint8Array, mimeType: string) => string | null) | null;
  // Zero means active. A positive timestamp retains the Android-compatible
  // two-second grace period after a WebView slot becomes inactive.
  private readonly webSlotInactiveAt: Map<string, number> = new Map();
  private readonly workQueue: SessionReplayWorkQueue;
  private readonly pendingViewStarts: Map<string, number> = new Map();
  private readonly endedViewStarts: Map<string, number> = new Map();
  // Every root/view transition invalidates detached snapshots already waiting
  // in the queue. This keeps a page transition from writing a stale frame.
  private captureGeneration: number = 0;
  private mutationCaptureTimer: number = -1;
  private viewportCaptureTimer: number = -1;
  private motionUntil: number = 0;
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
    this.scheduleViewportCapture();
  };
  private readonly keyboardHeightChangeListener = (height: number): void => {
    this.keyboardHeightPx = Number.isFinite(height) && height > 0 ? Math.round(height) : 0;
    this.keyboardResizesRoot = null;
    this.scheduleViewportCapture();
  };

  constructor(
    config: FTSessionReplayConfig = new FTSessionReplayConfig(),
    store: SessionReplaySegmentStore | null = null,
    errorSampleStore: SessionReplaySegmentStore | null = null,
    errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null = null,
    imageResourceWriter: ((context: SessionReplayContext, data: Uint8Array, mimeType: string) => string | null) | null = null
  ) {
    this.config = config;
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot(), config);
    this.sampler = new SessionReplaySampler(config);
    this.store = store;
    this.errorSampleStore = errorSampleStore;
    this.errorSampleResourcePromoter = errorSampleResourcePromoter;
    this.imageResourceWriter = imageResourceWriter;
    this.workQueue = new SessionReplayWorkQueue({
      filesDir: store?.getFilesDir() ?? errorSampleStore?.getFilesDir() ?? '',
      maxNodes: config.getMaxNodesPerSnapshot(),
      maxBytes: config.getStorageMaxBytes(),
      maxRecordsPerSegment: config.getMaxRecordsPerSegment(),
      fullSnapshotIntervalMs: config.getFullSnapshotIntervalMs(),
      errorSampleWindowMs: config.getErrorSampleWindowMs(),
      textPrivacy: config.getTextAndInputPrivacy(),
      imagePrivacy: config.getImagePrivacy()
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
    FTSessionReplayBridgeRegistry.unregister(this);
    this.isStarted = false;
    this.isStopping = true;
    this.pendingViewStartContext = null;
    this.unbindWindowViewportObserver();
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
    vpToPxScale: number = 1
  ): void {
    if (this.isStopping) return;
    const current = this.rootBinding;
    if (current !== null && current.uiContext === uiContext && current.rootId === rootId &&
      current.vpToPxScale === vpToPxScale) {
      this.capturePendingViewStart();
      return;
    }
    this.captureGeneration++;
    this.workQueue.clear();
    this.unbindWindowViewportObserver();
    const binding: SessionReplayRootBinding = {
      uiContext,
      rootId,
      vpToPxScale
    };
    this.rootBinding = binding;
    this.resetViewportObservation();
    this.lastFullSnapshotAt = 0;
    this.bindWindowViewportObserver(uiContext);
    this.capturePendingViewStart();
    if (this.activeContext !== null) {
      this.startObservation();
    }
  }

  public unregisterRoot(): void {
    if (this.isStopping) return;
    this.captureGeneration++;
    this.workQueue.clear();
    this.rootBinding = null;
    this.lastFullSnapshotAt = 0;
    this.resetViewportObservation();
    this.unbindWindowViewportObserver();
    this.stopObservation();
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
    const record = this.collector.captureFullSnapshot(uiContext, rootId, vpToPxScale);
    this.persistCapturedImageResources(context, record);
    const capture = this.createCapture(context, [record], record);
    this.appendRecordedRecords(context, capture.records);
    this.lastCapture = capture;
    return capture;
  }

  /** Captures only structural changes using Android's mutation record grammar. */
  public captureIncrementalSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture | null {
    const fullSnapshot = this.collector.captureFullSnapshot(uiContext, rootId, vpToPxScale);
    this.persistCapturedImageResources(context, fullSnapshot);
    const mutation = this.processor.createMutationRecord(fullSnapshot);
    if (mutation === null) {
      return null;
    }
    const capture = this.createCapture(context, [mutation], fullSnapshot);
    this.appendRecordedRecords(context, capture.records);
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
   * a root is still available, so later mutations use the rotated layout as
   * their baseline.
   */
  public recordActiveViewportResize(width: number, height: number): SessionReplayCapture | null {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width < 0 || height < 0) {
      return null;
    }
    const activeContext = this.activeContext;
    if (activeContext === null || !this.canRecordActiveContext(activeContext)) {
      return null;
    }
    const records: Array<SessionReplayRecord> = [
      this.processor.createViewportResizeRecord(this.normalizePhysicalLength(width), this.normalizePhysicalLength(height))
    ];
    let fullSnapshot: SessionReplayRecord | null = null;
    const snapshotCapture = this.captureWithRegisteredRoot(activeContext);
    if (snapshotCapture !== null) {
      fullSnapshot = snapshotCapture.record;
      records.push(fullSnapshot);
      this.processor.setFullSnapshotBaseline(fullSnapshot);
      this.observedViewport = this.getViewportBounds(fullSnapshot);
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
        this.normalizePhysicalLength(x),
        this.normalizePhysicalLength(y)
      )
    ], null);
    if (pointerEventType === 'move') {
      this.notifyMotion();
    } else {
      this.notifyPageChanged();
    }
    return capture;
  }

  /**
   * Generated page instrumentation and integration code call this after a
   * layout/state change. It coalesces many draws into one detached snapshot.
   */
  public notifyPageChanged(): void {
    this.scheduleAutomaticCapture();
  }

  /** Marks scrolling/animation/transition activity and waits for it to settle. */
  public notifyMotion(): void {
    this.motionUntil = Date.now() + this.config.getMotionQuietPeriodMs();
    this.scheduleAutomaticCapture();
  }

  /** A navigation boundary keeps the final stable frame but skips intermediates. */
  public notifyTransition(): void {
    this.notifyMotion();
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
    this.workQueue.clear();
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
      return true;
    }
    this.pendingViewStartContext = context;
    return false;
  }

  public onViewStopped(context: FTSessionReplayRUMContext): void {
    if (!this.isStarted) return;
    const replayContext = this.toReplayContext(context);
    if (this.pendingViewStartContext !== null &&
      this.isSameView(this.toReplayContext(this.pendingViewStartContext), replayContext)) {
      this.pendingViewStartContext = null;
    }
    if (this.activeContext === null || !this.isSameView(this.activeContext, replayContext)) {
      return;
    }
    const viewKey = this.getViewKey(replayContext.applicationId, replayContext.sessionId, replayContext.viewId);
    if (this.pendingViewStarts.get(viewKey) === this.captureGeneration) {
      this.endedViewStarts.set(viewKey, this.captureGeneration);
    }
    const record = this.processor.createViewEndRecord(this.toEpochMilliseconds(context.timestamp));
    const capture = this.createCapture(replayContext, [record], null);
    this.lastCapture = capture;
    this.appendRecordedRecords(replayContext, capture.records, true, true);
    this.activeContext = null;
    this.captureGeneration++;
    this.workQueue.clear(true);
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
    this.renewRootEpoch();
    this.activeContext = null;
    this.captureGeneration++;
    this.workQueue.clear();
    this.pendingViewStartContext = null;
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
    this.captureGeneration++;
    this.workQueue.clear(this.endedViewStarts.size > 0);
    this.processor.reset();
    this.resetViewportObservation();
    this.lastFullSnapshotAt = 0;
    this.activeContext = replayContext;
    const generation = this.captureGeneration;
    const contextSnapshot = this.copyReplayContext(replayContext);
    this.pendingViewStarts.set(
      this.getViewKey(replayContext.applicationId, replayContext.sessionId, replayContext.viewId), generation);
    this.workQueue.enqueue('start', lightSnapshot,
      (snapshot: SessionReplayRecord, resources: Array<CapturedReplayImageResource>): ReplayWorkerCommit | null =>
        this.prepareWorkerSnapshot(contextSnapshot, generation, snapshot, resources, true),
      (result: ReplayWorkerResult | null, error: string): void =>
        this.completeWorkerSnapshot('start', contextSnapshot, generation, result, error, context, promoteErrorAt));
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
    this.workQueue.enqueue('full', lightSnapshot,
      (snapshot: SessionReplayRecord, resources: Array<CapturedReplayImageResource>): ReplayWorkerCommit | null =>
        this.prepareWorkerSnapshot(contextSnapshot, generation, snapshot, resources),
      (result: ReplayWorkerResult | null, error: string): void =>
        this.completeWorkerSnapshot('full', contextSnapshot, generation, result, error, context, promoteErrorAt));
    return true;
  }

  /** UI-only validation and FrameNode read shared by automatic lifecycle paths. */
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
      return this.collector.captureLightSnapshot(
        rootBinding.uiContext,
        rootBinding.rootId,
        rootBinding.vpToPxScale
      );
    } catch (error) {
      this.lastCaptureFailure = `ArkUI FrameNode snapshot failed: ${String(error)}`;
      return null;
    }
  }

  private prepareWorkerSnapshot(
    context: SessionReplayContext,
    generation: number,
    snapshot: SessionReplayRecord,
    resources: Array<CapturedReplayImageResource>,
    allowEndedStart: boolean = false
  ): ReplayWorkerCommit | null {
    if (!this.isCurrentCapture(context, generation) &&
      !(allowEndedStart && this.isEndedStart(context, generation))) return null;
    this.persistCapturedImageResources(context, snapshot, resources);
    if (!this.isCurrentCapture(context, generation) &&
      !(allowEndedStart && this.isEndedStart(context, generation))) return null;
    const targetStore = this.getStoreForContext(context);
    const storeKind: ReplayStoreKind = targetStore === this.store && targetStore !== null ? 'main' :
      (targetStore === this.errorSampleStore && targetStore !== null ? 'error' : 'none');
    const commit: ReplayWorkerCommit = {
      context,
      snapshot,
      viewport: this.getViewportBounds(snapshot),
      previousViewport: this.observedViewport,
      lastFullSnapshotAt: this.lastFullSnapshotAt,
      storeKind
    };
    return commit;
  }

  private completeWorkerSnapshot(
    kind: 'start' | 'full' | 'automatic',
    context: SessionReplayContext,
    generation: number,
    result: ReplayWorkerResult | null,
    error: string,
    rumContext: FTSessionReplayRUMContext | null,
    promoteErrorAt: number | null
  ): void {
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    const endedStart = kind === 'start' && this.isEndedStart(context, generation);
    if (kind === 'start' && this.pendingViewStarts.get(key) === generation) this.pendingViewStarts.delete(key);
    if (endedStart) this.endedViewStarts.delete(key);
    if (!this.isCurrentCapture(context, generation) && !endedStart) {
      if (result !== null) this.removeWorkerSegments(result);
      return;
    }
    if (result === null || !result.stored) {
      this.lastCaptureFailure = result === null ? error : result.writeError;
      if (kind !== 'automatic' && error !== REPLAY_STALE_QUEUE_REASON) {
        FTSessionReplayBridgeRegistry.logDiagnostic(
          `Replay ${kind} snapshot failed: session=${context.sessionId}, view=${context.viewId}, reason=${this.lastCaptureFailure}`,
          true);
      }
      if (result !== null) this.removeWorkerSegments(result);
      if (kind === 'automatic' && error !== REPLAY_STALE_QUEUE_REASON) {
        this.lastFullSnapshotAt = 0;
      }
      if (this.isStarted && kind === 'start' && !endedStart && result === null && error === REPLAY_STALE_QUEUE_REASON && rumContext !== null) {
        this.queueViewStartedFromRUMContext(rumContext, promoteErrorAt);
      }
      return;
    }
    if (result.records.length === 0) return;
    const capture = this.createCaptureFromWorker(context, result);
    this.appendRecordedRecords(context, result.records, false);
    this.lastCapture = capture;
    this.lastCaptureFailure = '';
    if (!endedStart) {
      this.lastFullSnapshotAt = result.lastFullSnapshotAt;
      this.observedViewport = result.viewport;
    }
    if (kind === 'start') {
      FTSessionReplayBridgeRegistry.logDiagnostic(
        `Replay first frame saved: session=${context.sessionId}, view=${context.viewId}, records=${result.records.length}, segments=${result.segmentIds.length}`);
    }
    if (kind === 'start' && rumContext !== null) {
      this.recordViewMetadata(rumContext, result.records.length);
      if (!endedStart) this.startObservation();
    } else {
      this.recordReplayMetadata(context, result.records.length);
    }
    if (promoteErrorAt !== null && this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.ERROR) {
      this.promoteErrorSampledSession(context.sessionId, promoteErrorAt);
    } else if (result.storeKind === 'error' && this.promotedErrorSessions.has(context.sessionId)) {
      this.workQueue.enqueuePromotion(context.sessionId, Date.now(),
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
      const record = this.collector.captureFullSnapshot(
        this.rootBinding.uiContext,
        this.rootBinding.rootId,
        this.rootBinding.vpToPxScale
      );
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

  private notifyReplayMetadata(context: SessionReplayContext): void {
    const rumContext: FTSessionReplayRUMContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId,
      viewName: '',
      viewReferrer: '',
      linkContext: context.globalContext ?? {},
      timestamp: Date.now() * 1000000
    };
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
    requiresStart: boolean = false
  ): boolean {
    if (records.length === 0) {
      return true;
    }
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    const current = this.recordedRecordsByView.get(key) ?? [];
    for (let index = 0; index < records.length; index++) {
      current.push(records[index]);
    }
    const overflow = current.length - FTSessionReplayRecorder.MAX_RECORDS_PER_VIEW;
    if (overflow > 0) {
      current.splice(0, overflow);
    }
    this.recordedRecordsByView.set(key, current);
    if (!persist) {
      return true;
    }
    const targetStore = this.getStoreForContext(context);
    const storeKind: ReplayStoreKind = targetStore === this.store && targetStore !== null ? 'main' :
      (targetStore === this.errorSampleStore && targetStore !== null ? 'error' : 'none');
    const accepted = this.workQueue.enqueueRecords(this.copyReplayContext(context), records, storeKind,
      (success: boolean, failure: string): void => {
        if (!success) {
          this.lastCaptureFailure = failure;
          return;
        }
        this.recordReplayMetadata(context, records.length);
        // Stop can queue View End before an earlier Error snapshot promotes
        // the session. Move that already-targeted error batch as well.
        if (storeKind === 'error' && this.promotedErrorSessions.has(context.sessionId)) {
          this.workQueue.enqueuePromotion(context.sessionId, Date.now(),
            (promoted: boolean, promotionFailure: string): void => {
              if (!promoted) this.lastCaptureFailure = promotionFailure;
            });
        }
      }, requiresStart);
    if (!accepted) this.lastCaptureFailure = 'Session Replay Worker did not accept the record batch.';
    return accepted;
  }

  /** Appends a lifecycle signal only when it belongs to an active sampled View. */
  private appendActiveProtocolRecords(
    records: Array<SessionReplayRecord>,
    fullSnapshot: SessionReplayRecord | null
  ): SessionReplayCapture | null {
    const activeContext = this.activeContext;
    if (activeContext === null || !this.canRecordActiveContext(activeContext)) {
      return null;
    }
    const capture = this.createCapture(activeContext, records, fullSnapshot);
    if (!this.appendRecordedRecords(activeContext, capture.records, true, true)) {
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
    const accepted = this.workQueue.enqueuePromotion(sessionId, timestamp,
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

  private startObservation(): void {
    this.stopObservation();
    if (!this.isStarted || this.rootBinding === null || this.activeContext === null) {
      return;
    }
    // Collection is signal-driven. A View start's Full Snapshot already owns
    // the baseline; this only asks for a coalesced incremental check after the
    // page has completed any immediate layout work.
    this.notifyPageChanged();
  }

  private stopObservation(): void {
    if (this.mutationCaptureTimer !== -1) {
      clearTimeout(this.mutationCaptureTimer);
      this.mutationCaptureTimer = -1;
    }
    if (this.viewportCaptureTimer !== -1) {
      clearTimeout(this.viewportCaptureTimer);
      this.viewportCaptureTimer = -1;
    }
  }

  private captureActiveViewMutation(): void {
    const context = this.activeContext;
    const rootBinding = this.rootBinding;
    if (!this.isStarted || context === null || rootBinding === null) {
      return;
    }
    try {
      // This is the only automatic code that runs in an ArkUI callback. It
      // reads FrameNode into a detached handoff and immediately returns. The
      // Replay Worker materializes and diffs it, then writes the record batch.
      const lightSnapshot = this.collector.captureLightSnapshot(
        rootBinding.uiContext,
        rootBinding.rootId,
        rootBinding.vpToPxScale
      );
      const generation = this.captureGeneration;
      const contextSnapshot = this.copyReplayContext(context);
      this.workQueue.enqueue('automatic', lightSnapshot,
        (snapshot: SessionReplayRecord, resources: Array<CapturedReplayImageResource>): ReplayWorkerCommit | null =>
          this.prepareWorkerSnapshot(contextSnapshot, generation, snapshot, resources),
        (result: ReplayWorkerResult | null, error: string): void =>
          this.completeWorkerSnapshot('automatic', contextSnapshot, generation, result, error, null, null));
    } catch (_error) {
      // A root can disappear between an ArkUI lifecycle callback and capture.
      // The next page-change signal will retry after its layout has settled.
    }
  }

  /** Coalesces change notifications and drops intermediate motion frames. */
  private scheduleAutomaticCapture(): void {
    if (!this.isStarted || this.rootBinding === null || this.activeContext === null) {
      return;
    }
    if (this.mutationCaptureTimer !== -1) {
      clearTimeout(this.mutationCaptureTimer);
    }
    const now = Date.now();
    const motionDelay = Math.max(0, this.motionUntil - now);
    const delay = Math.max(this.config.getSnapshotIntervalMs(), motionDelay);
    this.mutationCaptureTimer = setTimeout((): void => {
      this.mutationCaptureTimer = -1;
      // A continuous Scroll/animation keeps extending motionUntil. Do not
      // traverse the root until it becomes stable.
      if (Date.now() < this.motionUntil) {
        this.scheduleAutomaticCapture();
        return;
      }
      this.captureActiveViewMutation();
    }, delay);
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

  /** Reads the root's already normalized viewport dimensions from a snapshot. */
  private getViewportBounds(snapshot: SessionReplayRecord): SessionReplayViewportBounds | null {
    if (snapshot.type !== ReplayRecordType.FULL_SNAPSHOT) {
      return null;
    }
    const data = snapshot.data as FullSnapshotData;
    if (data.wireframes.length === 0) {
      return null;
    }
    const root = data.wireframes[0];
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
      window.getLastWindow(hostContext)
        .then((nativeWindow: window.Window): void => {
          if (epoch !== this.windowObserverEpoch || this.rootBinding === null) {
            return;
          }
          this.nativeWindow = nativeWindow;
          try {
            nativeWindow.on('windowSizeChange', this.windowSizeChangeListener);
            nativeWindow.on('keyboardHeightChange', this.keyboardHeightChangeListener);
          } catch (_) {
            // Compiler-injected root change callbacks remain available when a
            // host window does not expose viewport events.
          }
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
    try {
      nativeWindow.off('windowSizeChange', this.windowSizeChangeListener);
      nativeWindow.off('keyboardHeightChange', this.keyboardHeightChangeListener);
    } catch (_) {
      // The window can already be destroyed during an Ability transition.
    }
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

  private resetViewportObservation(): void {
    this.observedViewport = null;
    this.observedRootViewport = null;
    this.keyboardHeightPx = 0;
    this.keyboardResizesRoot = null;
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
