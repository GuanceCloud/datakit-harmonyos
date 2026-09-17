/**
 * Public HarmonyOS Session Replay API.
 *
 * This HAR exposes a process-wide recorder entry point plus protocol and
 * collection primitives. Persistence and upload remain subsequent priorities.
 */
export {
  FTSessionReplayConfig,
  ImagePrivacy,
  TextAndInputPrivacy,
  TouchPrivacy
} from './src/main/ets/components/FTSessionReplayConfig';
export {
  ANDROID_REPLAY_ENDPOINTS,
  AndroidReplayEndpoints,
  FullSnapshotData,
  ReplayFocusData,
  ReplayMetaData,
  ReplayMutationData,
  ReplayPointerInteractionData,
  ReplayRecordType,
  ReplayViewportData,
  ReplayViewportResizeData,
  ReplayViewEndData,
  SessionReplayContext,
  SessionReplayGlobalContext,
  SessionReplayEnvelope,
  SessionReplayRecord,
  ReplayWireframe,
  createReplayEnvelope,
  serializeReplayEnvelope
} from './src/main/ets/components/SessionReplayProtocol';
export { ArkUIReplayCollector } from './src/main/ets/components/ArkUIReplayCollector';
export { ReplaySnapshotProcessor } from './src/main/ets/components/ReplaySnapshotProcessor';
export { SessionReplaySampler, SessionReplaySamplingMode } from './src/main/ets/components/SessionReplaySampler';
export { FTSessionReplay } from './src/main/ets/components/FTSessionReplay';
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
export { FTSessionReplayPOC, SessionReplayCapture } from './src/main/ets/components/FTSessionReplayPOC';
