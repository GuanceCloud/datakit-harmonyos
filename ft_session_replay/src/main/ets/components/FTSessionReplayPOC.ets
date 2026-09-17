import { UIContext } from '@kit.ArkUI';
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
import { ArkUIReplayCollector } from './ArkUIReplayCollector';
import { FTSessionReplayConfig, TextAndInputPrivacy, TouchPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from './SessionReplaySampler';
import { SessionReplaySegmentStore } from './SessionReplaySegmentStore';
import {
  createReplayEnvelope,
  FullSnapshotData,
  ReplayRecordType,
  serializeReplayEnvelope,
  SessionReplayContext,
  SessionReplayEnvelope,
  SessionReplayRecord
} from './SessionReplayProtocol';

/** Result returned by one POC Full Snapshot capture. */
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

interface BrowserReplayRecord {
  timestamp?: number;
  type?: number;
  data?: object;
}

/**
 * Entry point used to validate ArkUI collection and Android replay serialization
 * before enabling persistence or network uploads.
 */
export class FTSessionReplayPOC implements FTSessionReplayBridge {
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
  private lastCapture: SessionReplayCapture | null = null;
  private activeContext: SessionReplayContext | null = null;
  private readonly viewMetadata: Map<string, FTSessionReplayViewMetadata> = new Map();
  private readonly recordedRecordsByView: Map<string, Array<SessionReplayRecord>> = new Map();
  private readonly promotedErrorSessions: Set<string> = new Set();
  private readonly errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null;
  // Zero means active. A positive timestamp retains the Android-compatible
  // two-second grace period after a WebView slot becomes inactive.
  private readonly webSlotInactiveAt: Map<string, number> = new Map();
  private observationTimer: number = -1;

  constructor(
    config: FTSessionReplayConfig = new FTSessionReplayConfig(),
    store: SessionReplaySegmentStore | null = null,
    errorSampleStore: SessionReplaySegmentStore | null = null,
    errorSampleResourcePromoter: ((sessionId: string, timestamp: number) => boolean) | null = null
  ) {
    this.config = config;
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot());
    this.sampler = new SessionReplaySampler(config);
    this.store = store;
    this.errorSampleStore = errorSampleStore;
    this.errorSampleResourcePromoter = errorSampleResourcePromoter;
  }

  /** Enables RUM lifecycle capture through the core NoOp bridge registry. */
  public start(): void {
    if (this.isStarted) {
      return;
    }
    this.isStarted = true;
    FTSessionReplayBridgeRegistry.register(this);
  }

  /** Stops RUM lifecycle capture without changing the core SDK. */
  public stop(): void {
    if (!this.isStarted) {
      return;
    }
    FTSessionReplayBridgeRegistry.unregister(this);
    this.isStarted = false;
    this.rootBinding = null;
    this.activeContext = null;
    this.viewMetadata.clear();
    this.recordedRecordsByView.clear();
    this.promotedErrorSessions.clear();
    this.webSlotInactiveAt.clear();
    this.stopObservation();
    this.processor.reset();
    this.sampler.reset();
  }

  /** Registers the visible ArkUI root to record when RUM starts or errors a View. */
  public registerRoot(uiContext: UIContext, rootId: string, vpToPxScale: number = 1): void {
    const binding: SessionReplayRootBinding = {
      uiContext,
      rootId,
      vpToPxScale
    };
    this.rootBinding = binding;
    if (this.activeContext !== null) {
      this.startObservation();
    }
  }

  public unregisterRoot(): void {
    this.rootBinding = null;
    this.stopObservation();
  }

  public getLastCapture(): SessionReplayCapture | null {
    return this.lastCapture;
  }

  /** Returns a copy of the in-memory protocol stream for one RUM View. */
  public getRecordedRecords(context: SessionReplayContext): Array<SessionReplayRecord> {
    const records = this.recordedRecordsByView.get(
      this.getViewKey(context.applicationId, context.sessionId, context.viewId)
    );
    return records === undefined ? [] : records.slice();
  }

  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture {
    const record = this.collector.captureFullSnapshot(uiContext, rootId, vpToPxScale);
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
    return this.appendActiveProtocolRecords([this.processor.createViewportRecord(width, height, scale)], null);
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
    const records: Array<SessionReplayRecord> = [this.processor.createViewportResizeRecord(width, height)];
    let fullSnapshot: SessionReplayRecord | null = null;
    const snapshotCapture = this.captureWithRegisteredRoot(activeContext);
    if (snapshotCapture !== null) {
      fullSnapshot = snapshotCapture.record;
      records.push(fullSnapshot);
      this.processor.setFullSnapshotBaseline(fullSnapshot);
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
    return this.appendActiveProtocolRecords([
      this.processor.createPointerRecord(pointerEventType, Math.floor(pointerId), Math.round(x), Math.round(y))
    ], null);
  }

  public renewRootEpoch(): void {
    this.collector.renewRootEpoch();
    this.processor.reset();
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
    this.recordReplayMetadata(replayContext, capture.records.length);
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
    return this.promoteErrorSampledSession(context.sessionId, context.timestamp);
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
    const capture = this.captureFullSnapshotFromRUMContext(resolvedContext);
    if (capture === null) {
      return false;
    }
    this.activeContext = nextContext;
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
    if (this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    return this.captureViewStartedFromRUMContext(context) !== null;
  }

  public onViewStopped(context: FTSessionReplayRUMContext): void {
    const replayContext = this.toReplayContext(context);
    if (this.activeContext === null || !this.isSameView(this.activeContext, replayContext)) {
      return;
    }
    const record = this.processor.createViewEndRecord(context.timestamp);
    const capture = this.createCapture(replayContext, [record], null);
    this.lastCapture = capture;
    if (this.appendRecordedRecords(replayContext, capture.records)) {
      this.recordViewMetadata(context, 1);
    }
    this.activeContext = null;
    this.stopObservation();
    this.processor.reset();
  }

  public onError(context: FTSessionReplayErrorContext): boolean {
    if (this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    const replayContext = this.toReplayContext(context);
    let capture: SessionReplayCapture | null;
    if (this.activeContext !== null && !this.isSameReplayContext(this.activeContext, replayContext)) {
      capture = this.captureViewStartedFromRUMContext(context);
    } else {
      capture = this.captureFullSnapshotFromRUMContext(context);
    }
    if (capture === null) {
      return false;
    }
    if (this.sampler.decide(context.sessionId) !== SessionReplaySamplingMode.ERROR) {
      return true;
    }
    return this.promoteErrorSampledSession(context.sessionId, context.timestamp);
  }

  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {
    this.renewRootEpoch();
    this.activeContext = null;
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

  private isWebReplaySlotWithinGracePeriod(slotId: string, timestamp: number): boolean {
    const inactiveAt = this.webSlotInactiveAt.get(slotId);
    if (inactiveAt === undefined || inactiveAt === 0) {
      return true;
    }
    return timestamp - inactiveAt < FTSessionReplayPOC.WEB_REPLAY_INACTIVE_GRACE_MS;
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

  private captureViewStartedFromRUMContext(context: FTSessionReplayRUMContext): SessionReplayCapture | null {
    const replayContext = this.toReplayContext(context);
    const fullCapture = this.captureWithRegisteredRoot(replayContext);
    if (fullCapture === null) {
      return null;
    }
    const records = this.processor.createViewStartRecords(fullCapture.record);
    const capture = this.createCapture(replayContext, records, fullCapture.record);
    if (!this.appendRecordedRecords(replayContext, records)) {
      return null;
    }
    this.lastCapture = capture;
    this.activeContext = replayContext;
    this.recordViewMetadata(context, records.length);
    this.startObservation();
    return capture;
  }

  private captureFullSnapshotFromRUMContext(context: FTSessionReplayRUMContext): SessionReplayCapture | null {
    const replayContext = this.toReplayContext(context);
    const capture = this.captureWithRegisteredRoot(replayContext);
    if (capture !== null) {
      if (!this.appendRecordedRecords(replayContext, capture.records)) {
        return null;
      }
      this.processor.setFullSnapshotBaseline(capture.record);
      this.lastCapture = capture;
      this.recordViewMetadata(context, capture.records.length);
    }
    return capture;
  }

  private captureWithRegisteredRoot(context: SessionReplayContext): SessionReplayCapture | null {
    if (!this.isStarted || this.rootBinding === null || context.applicationId.length === 0 ||
      context.sessionId.length === 0 || context.viewId.length === 0) {
      return null;
    }
    try {
      const record = this.collector.captureFullSnapshot(
        this.rootBinding.uiContext,
        this.rootBinding.rootId,
        this.rootBinding.vpToPxScale
      );
      return this.createCapture(context, [record], record);
    } catch (_error) {
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
  }

  private getViewMetadataKey(context: FTSessionReplayRUMContext): string {
    return this.getViewKey(context.applicationId, context.sessionId, context.viewId);
  }

  private getViewKey(applicationId: string, sessionId: string, viewId: string): string {
    return `${applicationId}|${sessionId}|${viewId}`;
  }

  private appendRecordedRecords(context: SessionReplayContext, records: Array<SessionReplayRecord>): boolean {
    if (records.length === 0) {
      return true;
    }
    const key = this.getViewKey(context.applicationId, context.sessionId, context.viewId);
    const current = this.recordedRecordsByView.get(key) ?? [];
    for (let index = 0; index < records.length; index++) {
      current.push(records[index]);
    }
    const overflow = current.length - FTSessionReplayPOC.MAX_RECORDS_PER_VIEW;
    if (overflow > 0) {
      current.splice(0, overflow);
    }
    this.recordedRecordsByView.set(key, current);
    const targetStore = this.getStoreForContext(context);
    if (targetStore === null) {
      return true;
    }
    const appended = targetStore.append(context, records);
    if (appended && targetStore === this.errorSampleStore) {
      this.errorSampleStore?.pruneBefore(Date.now() - this.config.getErrorSampleWindowMs());
    }
    return appended;
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
    if (!this.appendRecordedRecords(activeContext, capture.records)) {
      return null;
    }
    this.recordReplayMetadata(activeContext, capture.records.length);
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
    const promoted = this.errorSampleStore.promoteSessionWindow(
      sessionId,
      timestamp,
      this.config.getErrorSampleWindowMs(),
      this.store
    );
    const resourcesPromoted = this.errorSampleResourcePromoter === null ||
      this.errorSampleResourcePromoter(sessionId, timestamp);
    if (promoted && resourcesPromoted) {
      this.promotedErrorSessions.add(sessionId);
    }
    return promoted && resourcesPromoted;
  }

  private startObservation(): void {
    this.stopObservation();
    if (!this.isStarted || this.rootBinding === null || this.activeContext === null) {
      return;
    }
    this.observationTimer = setInterval((): void => this.captureActiveViewMutation(), this.config.getSnapshotIntervalMs());
  }

  private stopObservation(): void {
    if (this.observationTimer !== -1) {
      clearInterval(this.observationTimer);
      this.observationTimer = -1;
    }
  }

  private captureActiveViewMutation(): void {
    const context = this.activeContext;
    const rootBinding = this.rootBinding;
    if (!this.isStarted || context === null || rootBinding === null) {
      return;
    }
    try {
      const fullSnapshot = this.collector.captureFullSnapshot(
        rootBinding.uiContext,
        rootBinding.rootId,
        rootBinding.vpToPxScale
      );
      const mutation = this.processor.createMutationRecord(fullSnapshot);
      if (mutation === null) {
        return;
      }
      const capture = this.createCapture(context, [mutation], fullSnapshot);
      if (this.appendRecordedRecords(context, capture.records)) {
        this.recordReplayMetadata(context, capture.records.length);
      }
      this.lastCapture = capture;
    } catch (_error) {
      // A root can disappear between an ArkUI lifecycle callback and polling.
      // Keep the current RUM View alive and retry on the next bounded interval.
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
