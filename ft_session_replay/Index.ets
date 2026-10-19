/**
 * Public HarmonyOS Session Replay API.
 *
 * This HAR exposes a process-wide recorder, collection and protocol primitives,
 * durable storage, and upload support.
 */
export {
  FTSessionReplayConfig,
  ImagePrivacy,
  TextAndInputPrivacy,
  TouchPrivacy
} from './src/main/ets/components/FTSessionReplayConfig';
export {
  HARMONY_REPLAY_ENDPOINTS,
  HARMONY_REPLAY_SOURCE,
  HarmonyReplayEndpoints,
  HarmonyReplayEntityReference,
  HarmonyReplayMobileSegment,
  FullSnapshotData,
  ReplayFocusData,
  ReplayImageWireframe,
  ReplayMetaData,
  ReplayMutationData,
  ReplayPointerInteractionData,
  ReplayRecordType,
  ReplayViewportData,
  ReplayViewportResizeData,
  ReplayViewEndData,
  ReplayShapeBorder,
  ReplayShapeStyle,
  ReplayShapeWireframe,
  ReplayTextAlignment,
  ReplayTextPadding,
  ReplayTextPosition,
  ReplayTextStyle,
  ReplayTextWireframe,
  SessionReplayContext,
  SessionReplayGlobalContext,
  SessionReplayEnvelope,
  SessionReplayRecord,
  ReplayWireframe,
  ReplayWireframeBase,
  ReplayWireframeClip,
  ReplayWireframeUpdate,
  createReplayEnvelope,
  serializeReplayEnvelope,
  createHarmonyReplayMobileSegment,
  serializeHarmonyReplayMobileSegment
} from './src/main/ets/components/SessionReplayProtocol';
export {
  ArkUIReplayCollector,
  ArkUIReplayLightNode,
  ArkUIReplayLightSnapshot,
  ArkUIReplayPageTransition,
  ArkUIReplaySceneBounds,
  ArkUIReplayScenePage,
  CapturedReplayImageResource
} from './src/main/ets/components/ArkUIReplayCollector';
export { ReplaySnapshotProcessor } from './src/main/ets/components/ReplaySnapshotProcessor';
export { SessionReplaySampler, SessionReplaySamplingMode } from './src/main/ets/components/SessionReplaySampler';
export { FTSessionReplay } from './src/main/ets/components/FTSessionReplay';
export { ReplayVideoState, ReplayVideoFrameProvider } from './src/main/ets/components/ReplayVideoCapture';
// Runtime contract used only by the Guance Hvigor Replay page-root transform.
// Applications should use FTSessionReplay for initialization and configuration.
export { FTSessionReplayAutoRootBridge } from './src/main/ets/components/FTSessionReplayAutoRootBridge';
export {
  SessionReplayRecordStore,
  SessionReplaySegmentStore,
  SessionReplayStoredSegment
} from './src/main/ets/components/SessionReplaySegmentStore';
export {
  SessionReplayUploader,
  SessionReplayUploadFields,
  SessionReplayUploadResult,
  createHarmonyReplayUploadUrl,
  createSessionReplayUploadFields,
  isRetryableReplayUploadStatus
} from './src/main/ets/components/SessionReplayUploader';
export {
  SessionReplayResourceStore,
  SessionReplayStoredResource
} from './src/main/ets/components/SessionReplayResourceStore';
export {
  SessionReplayResourceUploader,
  SessionReplayResourceUploadResult,
  createHarmonyReplayResourceUrl
} from './src/main/ets/components/SessionReplayResourceUploader';
export { FTSessionReplayRecorder, SessionReplayCapture } from './src/main/ets/components/FTSessionReplayRecorder';
export { ReplayResourceCleanupResult } from './src/main/ets/components/ReplayResourceCleanup';
