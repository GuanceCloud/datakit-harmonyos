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

/** Source value embedded in the final mobile segment consumed by Studio. */
export const HARMONY_REPLAY_SOURCE = 'harmonyos';

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

/** Shared geometry carried by every Android mobile wireframe. */
export interface ReplayWireframeBase {
  id: number;
  x: number;
  y: number;
  width: number;
  height: number;
  /** Insets in Replay coordinates; clipping never changes the original geometry. */
  clip?: ReplayWireframeClip;
  /** Native stacking order when ArkUI exposes it. */
  zIndex?: number;
  permanentId?: string;
}

/** Android-compatible clipping insets. Four zeroes explicitly clear clipping. */
export interface ReplayWireframeClip {
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

/** A portable subset of ArkUI's gradient description. */
export interface ReplayGradient {
  kind: 'linear' | 'radial';
  colors: Array<string>;
  stops?: Array<number>;
  angle?: number;
}

/** A portable subset of ArkUI's shadow description. */
export interface ReplayShadow {
  color: string;
  offsetX: number;
  offsetY: number;
  blurRadius: number;
  spreadRadius?: number;
}

/** Numeric transform values are stored separately from geometry. */
export interface ReplayTransform {
  translateX?: number;
  translateY?: number;
  scaleX?: number;
  scaleY?: number;
  rotate?: number;
}

/** Android's RGBA color and shape presentation model. */
export interface ReplayShapeStyle {
  backgroundColor?: string;
  opacity?: number;
  cornerRadius?: number;
  backgroundGradient?: ReplayGradient;
  shadow?: ReplayShadow;
  transform?: ReplayTransform;
  visible?: boolean;
}

export interface ReplayShapeBorder {
  color: string;
  width: number;
}

export interface ReplayTextStyle {
  family: string;
  size: number;
  color: string;
  weight?: number;
  style?: 'normal' | 'italic';
  lineHeight?: number;
  letterSpacing?: number;
  decoration?: 'none' | 'underline' | 'line-through';
}

/** Insets used by Studio's Android mobile-text renderer. */
export interface ReplayTextPadding {
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

/** Alignment values accepted by Studio's Android mobile-text renderer. */
export interface ReplayTextAlignment {
  horizontal?: 'left' | 'right' | 'center';
  vertical?: 'top' | 'bottom' | 'center';
}

export interface ReplayTextPosition {
  padding?: ReplayTextPadding;
  alignment?: ReplayTextAlignment;
}

/** Image content placement derived from ArkUI's ImageFit modifier. */
export interface ReplayImageStyle {
  objectFit?: 'fill' | 'contain' | 'cover' | 'none' | 'scale-down';
  tintColor?: string;
}

/** A rectangular native component or container. */
export interface ReplayShapeWireframe extends ReplayWireframeBase {
  type: 'shape';
  shapeStyle?: ReplayShapeStyle;
  border?: ReplayShapeBorder;
}

/** A native text component. The text is filtered by the configured privacy policy. */
export interface ReplayTextWireframe extends ReplayWireframeBase {
  type: 'text';
  shapeStyle?: ReplayShapeStyle;
  border?: ReplayShapeBorder;
  text: string;
  textStyle: ReplayTextStyle;
  textPosition?: ReplayTextPosition;
}

/** A native image. `resourceId` refers to a separately uploaded Replay asset. */
export interface ReplayImageWireframe extends ReplayWireframeBase {
  type: 'image';
  shapeStyle?: ReplayShapeStyle;
  border?: ReplayShapeBorder;
  base64?: string;
  resourceId?: string;
  /** Mobile Replay MIME subtype (png, jpeg, svg+xml); the player supplies image/. */
  mimeType?: string;
  isEmpty?: boolean;
  imageStyle?: ReplayImageStyle;
}

/** Studio places Browser records with the same slotId into this native rectangle. */
export interface ReplayWebViewWireframe extends ReplayWireframeBase {
  type: 'webview';
  slotId: string;
  isVisible?: boolean;
  shapeStyle?: ReplayShapeStyle;
  border?: ReplayShapeBorder;
}

/** Safe fallback for nodes whose visual semantics are not yet mapped. */
export interface ReplayPlaceholderWireframe extends ReplayWireframeBase {
  type: 'placeholder';
  label: string;
}

/** Android mobile wireframe union used by Full Snapshot and mutation records. */
export type ReplayWireframe = ReplayShapeWireframe | ReplayTextWireframe |
  ReplayImageWireframe | ReplayPlaceholderWireframe | ReplayWebViewWireframe;

export interface SessionReplayRecord {
  timestamp: number;
  type: ReplayRecordType;
  data: object;
  slotId?: string;
}

/** Native mobile snapshots use 10; Browser rrweb snapshots use 2. */
export function isReplayFullSnapshot(record: SessionReplayRecord): boolean {
  return record.slotId === undefined ? record.type === ReplayRecordType.FULL_SNAPSHOT : (record.type as number) === 2;
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

/** Fields shared by Android's shape, text, image and placeholder updates. */
export interface ReplayWireframeUpdate {
  id: number;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  clip?: ReplayWireframeClip;
  zIndex?: number;
  shapeStyle?: ReplayShapeStyle;
  border?: ReplayShapeBorder;
  label?: string;
  text?: string;
  textStyle?: ReplayTextStyle;
  textPosition?: ReplayTextPosition;
  base64?: string;
  resourceId?: string;
  mimeType?: string;
  isEmpty?: boolean;
  imageStyle?: ReplayImageStyle;
  slotId?: string;
  isVisible?: boolean;
  type: 'shape' | 'text' | 'image' | 'placeholder' | 'webview';
}

/** Android's `MobileMutationData` payload (`source: 0`). */
export interface ReplayMutationData {
  source: 0;
  adds: Array<ReplayMutationAdd>;
  removes: Array<ReplayMutationRemove>;
  updates: Array<ReplayWireframeUpdate>;
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

/**
 * Final Android mobile segment uploaded to `v1/write/rum/replay`.
 *
 * Android first writes an EnrichedRecord (SessionReplayEnvelope), then
 * converts it to this shape immediately before compression and upload. The
 * player consumes this shape; sending the intermediate EnrichedRecord is
 * accepted by intake but has no renderable mobile segment.
 */
export interface AndroidReplayEntityReference {
  id: string;
}

export interface AndroidReplayMobileSegment {
  application: AndroidReplayEntityReference;
  session: AndroidReplayEntityReference;
  view: AndroidReplayEntityReference;
  start: number;
  end: number;
  records_count: number;
  has_full_snapshot: boolean;
  source: string;
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

/** Builds the final Android-compatible segment, ordered by record timestamp. */
export function createAndroidReplayMobileSegment(
  context: SessionReplayContext,
  records: Array<SessionReplayRecord>
): AndroidReplayMobileSegment {
  if (records.length === 0) {
    throw new Error('A Session Replay mobile segment requires at least one record.');
  }
  const orderedRecords = records.slice().sort((left: SessionReplayRecord, right: SessionReplayRecord): number =>
    left.timestamp - right.timestamp
  );
  let hasFullSnapshot = false;
  for (let index = 0; index < orderedRecords.length; index++) {
    if (isReplayFullSnapshot(orderedRecords[index])) {
      hasFullSnapshot = true;
      break;
    }
  }
  return {
    application: { id: context.applicationId },
    session: { id: context.sessionId },
    view: { id: context.viewId },
    start: orderedRecords[0].timestamp,
    end: orderedRecords[orderedRecords.length - 1].timestamp,
    records_count: orderedRecords.length,
    has_full_snapshot: hasFullSnapshot,
    source: HARMONY_REPLAY_SOURCE,
    records: orderedRecords
  };
}

export function serializeAndroidReplayMobileSegment(
  context: SessionReplayContext,
  records: Array<SessionReplayRecord>
): string {
  return JSON.stringify(createAndroidReplayMobileSegment(context, records));
}
