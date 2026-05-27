import abilityTest from './Ability.test';
import dbTest from './DBTest.test';
import rumAutoViewUITest from './RumAutoViewUITest.test';
import rumAutoActionUITest from './RumAutoActionUITest.test';
import webViewTrackUITest from './WebViewTrackUITest.test';
import nativeCrashAnrUITest from './NativeCrashAnrUITest.test';

export default function testsuite() {
  abilityTest();
  dbTest();
  rumAutoViewUITest();
  rumAutoActionUITest();
  webViewTrackUITest();
  nativeCrashAnrUITest();
}
