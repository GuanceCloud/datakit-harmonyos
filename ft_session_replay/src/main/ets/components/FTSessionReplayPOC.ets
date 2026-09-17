import { UIContext } from '@kit.ArkUI';
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

/**
 * Entry point used to validate ArkUI collection and Android replay serialization
 * before enabling persistence or network uploads.
 */
export class FTSessionReplayPOC {
  private readonly collector: ArkUIReplayCollector;

  constructor(config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
    this.collector = new ArkUIReplayCollector(config.getMaxNodesPerSnapshot());
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

  private getWireframeCount(record: SessionReplayRecord): number {
    const data = record.data as FullSnapshotData;
    return data.wireframes.length;
  }
}
