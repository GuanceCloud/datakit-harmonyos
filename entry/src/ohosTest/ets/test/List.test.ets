import { beforeAll, afterAll } from '@ohos/hypium';
import { UiTestUtils } from './helpers/UiTestUtils';
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
  // Register on Hypium's root suite so existing class/case filters keep working.
  beforeAll(async () => { await UiTestUtils.beginTestSession(); });
  afterAll(async () => { await UiTestUtils.endTestSession(); });
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
}
