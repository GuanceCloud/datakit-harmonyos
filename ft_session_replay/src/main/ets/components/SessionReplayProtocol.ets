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
  VIEW_END = 7,
  VIEWPORT = 8,
  FULL_SNAPSHOT = 10,
  INCREMENTAL_SNAPSHOT = 11
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

/** Android mobile Meta record payload. */
export interface ReplayMetaData {
  width: number;
  height: number;
  href?: string;
}

/** Android mobile Focus record payload. */
export interface ReplayFocusData {
  has_focus: boolean;
}

/** Android mobile VisualViewport record payload. */
export interface ReplayViewportData {
  width: number;
  height: number;
  offsetLeft: number;
  offsetTop: number;
  pageLeft: number;
  pageTop: number;
  scale: number;
}

export interface ReplayMutationAdd {
  previousId?: number;
  wireframe: ReplayWireframe;
}

export interface ReplayMutationRemove {
  id: number;
}

/** Placeholder update shape used by Android's mobile mutation payload. */
export interface ReplayPlaceholderUpdate {
  id: number;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  label?: string;
  type: 'placeholder';
}

/** Android's `MobileMutationData` payload (`source: 0`). */
export interface ReplayMutationData {
  source: 0;
  adds: Array<ReplayMutationAdd>;
  removes: Array<ReplayMutationRemove>;
  updates: Array<ReplayPlaceholderUpdate>;
}

/** Android's resize incremental payload (`source: 4`). */
export interface ReplayViewportResizeData {
  source: 4;
  width: number;
  height: number;
}

/** Android's pointer interaction incremental payload (`source: 9`). */
export interface ReplayPointerInteractionData {
  source: 9;
  pointerEventType: 'down' | 'up' | 'move';
  pointerType: 'touch' | 'mouse' | 'pen';
  pointerId: number;
  x: number;
  y: number;
}

/** Android View End has no payload, but ArkTS requires a declared object type. */
export interface ReplayViewEndData {
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
