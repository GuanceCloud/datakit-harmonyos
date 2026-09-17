/**
 * Public Session Replay POC API.
 *
 * This HAR deliberately exposes protocol and collection primitives only. It
 * does not persist or upload replay data until the POC contract is validated.
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
export { FTSessionReplayPOC, SessionReplayCapture } from './src/main/ets/components/FTSessionReplayPOC';
