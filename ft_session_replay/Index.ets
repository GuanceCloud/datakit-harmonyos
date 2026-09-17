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
  ReplayRecordType,
  SessionReplayContext,
  SessionReplayGlobalContext,
  SessionReplayEnvelope,
  SessionReplayRecord,
  ReplayWireframe,
  createReplayEnvelope,
  serializeReplayEnvelope
} from './src/main/ets/components/SessionReplayProtocol';
export { ArkUIReplayCollector } from './src/main/ets/components/ArkUIReplayCollector';
export { FTSessionReplayPOC, SessionReplayCapture } from './src/main/ets/components/FTSessionReplayPOC';
