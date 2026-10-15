import sessionReplayProtocolUnitTest from './unit/SessionReplayProtocolUnit.test';
import sessionReplayStorageUnitTest from './unit/SessionReplayStorageUnit.test';
import arkUIReplayCollectorUnitTest from './unit/ArkUIReplayCollectorUnit.test';
import sessionReplayWorkerUnitTest from './unit/SessionReplayWorkerUnit.test';
import sessionReplaySceneUnitTest from './unit/SessionReplaySceneUnit.test';
import webReplayUnitTest from './unit/WebReplayUnit.test';

export default function testsuite() {
  sessionReplayProtocolUnitTest();
  sessionReplayStorageUnitTest();
  arkUIReplayCollectorUnitTest();
  sessionReplayWorkerUnitTest();
  sessionReplaySceneUnitTest();
  webReplayUnitTest();
}
