import entryTestConfigTest from './EntryTestConfig.test';
import nativeWorkerIntegrationUITest from './NativeWorkerIntegrationUITest.test';
import abilityTest from './Ability.test';
import dbTest from './DBTest.test';
import rumAutoViewUITest from './RumAutoViewUITest.test';
import rumAutoActionUITest from './RumAutoActionUITest.test';
import rumDataChainUITest from './RumDataChainUITest.test';
import uiBlockLongTaskUITest from './UIBlockLongTaskUITest.test';
import webViewTrackUITest from './WebViewTrackUITest.test';
import logChainUITest from './LogChainUITest.test';
import traceAutoTrackUITest from './TraceAutoTrackUITest.test';
import rumUploadE2EUITest from './RumUploadE2EUITest.test';
import stressLogTimestampSequencerTest from './StressLogTimestampSequencer.test';

export default function testsuite() {
  entryTestConfigTest();
  abilityTest();
  dbTest();
  rumAutoViewUITest();
  rumAutoActionUITest();
  rumDataChainUITest();
  uiBlockLongTaskUITest();
  webViewTrackUITest();
  logChainUITest();
  traceAutoTrackUITest();
  rumUploadE2EUITest();
  stressLogTimestampSequencerTest();
  nativeWorkerIntegrationUITest();
}
