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
  ANDROID_REPLAY_ENDPOINTS,
  HARMONY_REPLAY_SOURCE,
  AndroidReplayEndpoints,
  AndroidReplayEntityReference,
  AndroidReplayMobileSegment,
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
  ReplayWireframeUpdate,
  createReplayEnvelope,
  serializeReplayEnvelope,
  createAndroidReplayMobileSegment,
  serializeAndroidReplayMobileSegment
} from './src/main/ets/components/SessionReplayProtocol';
export {
  ArkUIReplayCollector,
  ArkUIReplayLightNode,
  ArkUIReplayLightSnapshot,
  CapturedReplayImageResource
} from './src/main/ets/components/ArkUIReplayCollector';
export { ReplaySnapshotProcessor } from './src/main/ets/components/ReplaySnapshotProcessor';
export { SessionReplaySampler, SessionReplaySamplingMode } from './src/main/ets/components/SessionReplaySampler';
export { FTSessionReplay } from './src/main/ets/components/FTSessionReplay';
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
  createAndroidReplayUploadUrl,
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
  createAndroidReplayResourceUrl
} from './src/main/ets/components/SessionReplayResourceUploader';
export { FTSessionReplayRecorder, SessionReplayCapture } from './src/main/ets/components/FTSessionReplayRecorder';
