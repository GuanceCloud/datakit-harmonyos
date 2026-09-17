/** Android-compatible intake paths for Session Replay records and assets. */
export interface AndroidReplayEndpoints {
  records: string;
  assets: string;
  assetCheck: string;
}

export const ANDROID_REPLAY_ENDPOINTS: AndroidReplayEndpoints = {
  records: 'v1/write/rum/replay',
  assets: 'v1/write/rum/replay_assets',
  assetCheck: 'v1/check/rum/replay_assets'
};

/** Android Session Replay record type values. */
export enum ReplayRecordType {
  META = 4,
  FOCUS = 6,
  VIEWPORT = 8,
  FULL_SNAPSHOT = 10,
  INCREMENTAL_SNAPSHOT = 11,
  VIEW_END = 12
}

export type SessionReplayScalar = string | number | boolean;
export type SessionReplayGlobalContext = Record<string, SessionReplayScalar>;

/** Required Android replay envelope linkage values. */
export interface SessionReplayContext {
  applicationId: string;
  sessionId: string;
  viewId: string;
  globalContext?: SessionReplayGlobalContext;
}

/**
 * The POC uses Android's placeholder wireframe representation. It is safe for
 * unknown ArkUI nodes because it does not contain user content or image bytes.
 */
export interface ReplayWireframe {
  id: number;
  x: number;
  y: number;
  width: number;
  height: number;
  type: 'placeholder';
  label: string;
  permanentId?: string;
}

export interface SessionReplayRecord {
  timestamp: number;
  type: ReplayRecordType;
  data: object;
  slotId?: string;
}

export interface FullSnapshotData {
  wireframes: Array<ReplayWireframe>;
}

/** Serialized shape accepted by Android's `EnrichedRecord` contract. */
export interface SessionReplayEnvelope {
  application_id: string;
  session_id: string;
  view_id: string;
  globalContext?: SessionReplayGlobalContext;
  records: Array<SessionReplayRecord>;
}

export function createReplayEnvelope(
  context: SessionReplayContext,
  records: Array<SessionReplayRecord>
): SessionReplayEnvelope {
  const envelope: SessionReplayEnvelope = {
    application_id: context.applicationId,
    session_id: context.sessionId,
    view_id: context.viewId,
    records: records.slice()
  };
  if (context.globalContext !== undefined && Object.keys(context.globalContext).length > 0) {
    envelope.globalContext = context.globalContext;
  }
  return envelope;
}

export function serializeReplayEnvelope(
  context: SessionReplayContext,
  records: Array<SessionReplayRecord>
): string {
  return JSON.stringify(createReplayEnvelope(context, records));
}
