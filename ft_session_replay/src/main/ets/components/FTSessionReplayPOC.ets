import { UIContext } from '@kit.ArkUI';
import {
  FTSessionReplayBridge,
  FTSessionReplayBridgeRegistry,
  FTSessionReplayErrorContext,
  FTSessionReplayRUMContext,
  FTSessionReplaySessionContext
} from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector } from './ArkUIReplayCollector';
import { FTSessionReplayConfig, TouchPrivacy } from './FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from './ReplaySnapshotProcessor';
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
  private readonly config: FTSessionReplayConfig;
  private readonly collector: ArkUIReplayCollector;
  private readonly processor: ReplaySnapshotProcessor = new ReplaySnapshotProcessor();
  private rootBinding: SessionReplayRootBinding | null = null;
  private isStarted: boolean = false;
  private lastCapture: SessionReplayCapture | null = null;
  private activeContext: SessionReplayContext | null = null;

  constructor(config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
    this.config = config;
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot());
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
    this.processor.reset();
  }

  /** Registers the visible ArkUI root to record when RUM starts or errors a View. */
  public registerRoot(uiContext: UIContext, rootId: string, vpToPxScale: number = 1): void {
    const binding: SessionReplayRootBinding = {
      uiContext,
      rootId,
      vpToPxScale
    };
    this.rootBinding = binding;
  }

  public unregisterRoot(): void {
    this.rootBinding = null;
  }

  public getLastCapture(): SessionReplayCapture | null {
    return this.lastCapture;
  }

  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture {
    const record = this.collector.captureFullSnapshot(uiContext, rootId, vpToPxScale);
    return this.createCapture(context, [record], record);
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
    this.lastCapture = capture;
    return capture;
  }

  public renewRootEpoch(): void {
    this.collector.renewRootEpoch();
    this.processor.reset();
  }

  public onViewStarted(context: FTSessionReplayRUMContext): boolean {
    return this.captureViewStartedFromRUMContext(context) !== null;
  }

  public onViewStopped(context: FTSessionReplayRUMContext): void {
    const replayContext = this.toReplayContext(context);
    if (this.activeContext === null || !this.isSameView(this.activeContext, replayContext)) {
      return;
    }
    const record = this.processor.createViewEndRecord(context.timestamp);
    this.lastCapture = this.createCapture(replayContext, [record], null);
    this.activeContext = null;
    this.processor.reset();
  }

  public onError(context: FTSessionReplayErrorContext): boolean {
    return this.captureFullSnapshotFromRUMContext(context) !== null;
  }

  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {
    this.renewRootEpoch();
    this.activeContext = null;
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
    return capture;
  }

  private captureFullSnapshotFromRUMContext(context: FTSessionReplayRUMContext): SessionReplayCapture | null {
    const replayContext = this.toReplayContext(context);
    const capture = this.captureWithRegisteredRoot(replayContext);
    if (capture !== null) {
      this.lastCapture = capture;
    }
    return capture;
  }

  private captureWithRegisteredRoot(context: SessionReplayContext): SessionReplayCapture | null {
    if (!this.isStarted || this.rootBinding === null || context.applicationId.length === 0 ||
      context.sessionId.length === 0 || context.viewId.length === 0) {
      return null;
    }
    try {
      const capture = this.captureFullSnapshot(
        this.rootBinding.uiContext,
        this.rootBinding.rootId,
        {
          applicationId: context.applicationId,
          sessionId: context.sessionId,
          viewId: context.viewId
        },
        this.rootBinding.vpToPxScale
      );
      this.lastCapture = capture;
      return capture;
    } catch (_error) {
      return null;
    }
  }

  private toReplayContext(context: FTSessionReplayRUMContext): SessionReplayContext {
    return {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
  }

  private isSameView(left: SessionReplayContext, right: SessionReplayContext): boolean {
    return left.applicationId === right.applicationId && left.sessionId === right.sessionId && left.viewId === right.viewId;
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
