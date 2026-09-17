import { UIContext } from '@kit.ArkUI';
import {
  FTSessionReplayBridge,
  FTSessionReplayBridgeRegistry,
  FTSessionReplayErrorContext,
  FTSessionReplayRUMContext,
  FTSessionReplaySessionContext
} from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector } from './ArkUIReplayCollector';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
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
  private readonly collector: ArkUIReplayCollector;
  private rootBinding: SessionReplayRootBinding | null = null;
  private isStarted: boolean = false;
  private lastCapture: SessionReplayCapture | null = null;

  constructor(config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
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
    const records = [record];
    return {
      envelope: createReplayEnvelope(context, records),
      payload: serializeReplayEnvelope(context, records),
      record,
      wireframeCount: this.getWireframeCount(record)
    };
  }

  public renewRootEpoch(): void {
    this.collector.renewRootEpoch();
  }

  public onViewStarted(context: FTSessionReplayRUMContext): boolean {
    return this.captureFromRUMContext(context) !== null;
  }

  public onViewStopped(_context: FTSessionReplayRUMContext): void {
    // Android's View-end marker will be added with the durable recorder. The
    // POC keeps the already captured Full Snapshot available for inspection.
  }

  public onError(context: FTSessionReplayErrorContext): boolean {
    return this.captureFromRUMContext(context) !== null;
  }

  public onSessionRenewed(_context: FTSessionReplaySessionContext): void {
    this.collector.renewRootEpoch();
  }

  private getWireframeCount(record: SessionReplayRecord): number {
    const data = record.data as FullSnapshotData;
    return data.wireframes.length;
  }

  private captureFromRUMContext(context: FTSessionReplayRUMContext): SessionReplayCapture | null {
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
}
