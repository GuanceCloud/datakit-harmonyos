import sessionReplayProtocolUnitTest from './unit/SessionReplayProtocolUnit.test';
import sessionReplayStorageUnitTest from './unit/SessionReplayStorageUnit.test';

export default function testsuite() {
  sessionReplayProtocolUnitTest();
  sessionReplayStorageUnitTest();
}
