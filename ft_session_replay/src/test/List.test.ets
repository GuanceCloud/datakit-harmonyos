import sessionReplayProtocolUnitTest from './unit/SessionReplayProtocolUnit.test';
import sessionReplaySamplerUnitTest from './unit/SessionReplaySamplerUnit.test';
import sessionReplayStorageUnitTest from './unit/SessionReplayStorageUnit.test';
import arkUIReplayCollectorUnitTest from './unit/ArkUIReplayCollectorUnit.test';
import sessionReplayWorkerUnitTest from './unit/SessionReplayWorkerUnit.test';
import replaySnapshotFilterUnitTest from './unit/ReplaySnapshotFilterUnit.test';
import sessionReplaySceneUnitTest from './unit/SessionReplaySceneUnit.test';
import webReplayUnitTest from './unit/WebReplayUnit.test';
import webReplayBatcherUnitTest from './unit/WebReplayBatcherUnit.test';

export default function testsuite() {
  sessionReplayProtocolUnitTest();
  sessionReplaySamplerUnitTest();
  sessionReplayStorageUnitTest();
  arkUIReplayCollectorUnitTest();
  sessionReplayWorkerUnitTest();
  replaySnapshotFilterUnitTest();
  sessionReplaySceneUnitTest();
  webReplayUnitTest();
  webReplayBatcherUnitTest();
}
