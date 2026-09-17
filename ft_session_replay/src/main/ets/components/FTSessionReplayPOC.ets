import { UIContext } from '@kit.ArkUI';
import {
  FTSessionReplayBridge,
  FTSessionReplayBridgeRegistry,
  FTSessionReplayErrorContext,
  FTSessionReplayRUMContext,
  FTSessionReplaySessionContext,
  FTSessionReplayViewMetadata
} from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector } from './ArkUIReplayCollector';
import { FTSessionReplayConfig, TouchPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from './SessionReplaySampler';
import {
  createReplayEnvelope,
  FullSnapshotData,
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

/**
 * Entry point used to validate ArkUI collection and Android replay serialization
 * before enabling persistence or network uploads.
 */
export class FTSessionReplayPOC implements FTSessionReplayBridge {
  private static readonly MAX_RECORDS_PER_VIEW: number = 2000;

  private readonly config: FTSessionReplayConfig;
  private readonly collector: ArkUIReplayCollector;
  private readonly processor: ReplaySnapshotProcessor = new ReplaySnapshotProcessor();
  private readonly sampler: SessionReplaySampler;
  private rootBinding: SessionReplayRootBinding | null = null;
  private isStarted: boolean = false;
  private lastCapture: SessionReplayCapture | null = null;
  private activeContext: SessionReplayContext | null = null;
  private readonly viewMetadata: Map<string, FTSessionReplayViewMetadata> = new Map();
  private readonly recordedRecordsByView: Map<string, Array<SessionReplayRecord>> = new Map();
  private observationTimer: number = -1;

  constructor(config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
    this.config = config;
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot());
    this.sampler = new SessionReplaySampler(config);
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

  /** Returns Android-compatible Replay counters for the current RUM View. */
  public getViewMetadata(context: FTSessionReplayRUMContext): FTSessionReplayViewMetadata {
    const metadata = this.viewMetadata.get(this.getViewMetadataKey(context));
    if (metadata === undefined) {
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
    this.appendRecordedRecords(replayContext, capture.records);
    this.recordViewMetadata(context, 1);
    this.activeContext = null;
    this.stopObservation();
    this.processor.reset();
  }

  public onError(context: FTSessionReplayErrorContext): boolean {
    if (this.sampler.decide(context.sessionId) === SessionReplaySamplingMode.NONE) {
      return false;
    }
    const replayContext = this.toReplayContext(context);
    if (this.activeContext !== null && !this.isSameReplayContext(this.activeContext, replayContext)) {
      return this.captureViewStartedFromRUMContext(context) !== null;
    }
    return this.captureFullSnapshotFromRUMContext(context) !== null;
  }

  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {
    this.renewRootEpoch();
    this.activeContext = null;
    this.stopObservation();
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
    this.lastCapture = capture;
    this.activeContext = replayContext;
    this.appendRecordedRecords(replayContext, records);
    this.recordViewMetadata(context, records.length);
    this.startObservation();
    return capture;
  }

  private captureFullSnapshotFromRUMContext(context: FTSessionReplayRUMContext): SessionReplayCapture | null {
    const replayContext = this.toReplayContext(context);
    const capture = this.captureWithRegisteredRoot(replayContext);
    if (capture !== null) {
      this.lastCapture = capture;
      this.appendRecordedRecords(replayContext, capture.records);
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

  private appendRecordedRecords(context: SessionReplayContext, records: Array<SessionReplayRecord>): void {
    if (records.length === 0) {
      return;
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
      this.appendRecordedRecords(context, capture.records);
      this.recordReplayMetadata(context, capture.records.length);
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
