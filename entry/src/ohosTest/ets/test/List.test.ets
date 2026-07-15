import abilityTest from './Ability.test';
import dbTest from './DBTest.test';
import rumAutoViewUITest from './RumAutoViewUITest.test';
import rumAutoActionUITest from './RumAutoActionUITest.test';
import rumDataChainUITest from './RumDataChainUITest.test';
import uiBlockLongTaskUITest from './UIBlockLongTaskUITest.test';
import webViewTrackUITest from './WebViewTrackUITest.test';
import logChainUITest from './LogChainUITest.test';
import traceAutoTrackUITest from './TraceAutoTrackUITest.test';
import stressLogTimestampSequencerTest from './StressLogTimestampSequencer.test';

export default function testsuite() {
  abilityTest();
  dbTest();
  rumAutoViewUITest();
  rumAutoActionUITest();
  rumDataChainUITest();
  uiBlockLongTaskUITest();
  webViewTrackUITest();
  logChainUITest();
  traceAutoTrackUITest();
  stressLogTimestampSequencerTest();
}
