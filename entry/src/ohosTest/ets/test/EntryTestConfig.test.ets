import { describe, expect, it } from '@ohos/hypium';
import { entryLaunchParameters, resolveEntryRuntimeConfig } from '../../../main/ets/utils/EntryRuntimeConfig';
import { shouldClearEntryTestData, validateEntryTestConfig } from '../../../main/ets/utils/EntryTestConfig';

function assertInvalid(incoming: Record<string, string>): void {
  let rejected = false;
  try {
    resolveEntryRuntimeConfig(incoming, {});
  } catch (_) {
    rejected = true;
  }
  expect(rejected).assertTrue();
}

export default function entryTestConfigTest() {
  describe('EntryTestConfigTest', () => {
    it('testAndDemoLaunchesResolveIdentically', 0, () => {
      const saved: Record<string, string> = { 'appId': 'saved-app', 'datawayUrl': 'https://saved.example.com',
        'clientToken': 'saved-token', 'autoSync': 'true', 'localDataFilterEnabled': 'true' };
      const demo: Record<string, string> = { 'datakitUrl': 'http://test.example.com', 'rumSamplingRate': '0.25' };
      const test = entryLaunchParameters({ '-s datakitUrl': demo.datakitUrl, '-s rumSamplingRate': '0.25',
        'entryKeepData': 'true', 'entryUploadE2EEnabled': 'true', 'class': 'ignored' });
      expect(JSON.stringify(resolveEntryRuntimeConfig(test, saved))).assertEqual(
        JSON.stringify(resolveEntryRuntimeConfig(demo, saved)));
      expect(test.entryKeepData === undefined).assertTrue();
      expect(test.entryUploadE2EEnabled === undefined).assertTrue();
      expect(test['class'] === undefined).assertTrue();
      expect(test.autoSync === undefined).assertTrue();
    });
    it('noTestArgumentsPreserveSavedBehavior', 0, () => {
      const saved: Record<string, string> = { 'appId': 'saved-app', 'datakitUrl': 'https://saved.example.com',
        'autoSync': 'true', 'localDataFilterEnabled': 'true', 'remoteConfigTestEnabled': 'true',
        'logSamplingRate': '0', 'rumSamplingRate': '0.25', 'errorSamplingRate': '0.5', 'traceSamplingRate': '0.75' };
      const before = JSON.stringify(saved);
      const config = resolveEntryRuntimeConfig(entryLaunchParameters({}), saved);
      for (const key of Object.keys(saved)) expect(config[key]).assertEqual(saved[key]);
      expect(JSON.stringify(saved)).assertEqual(before);
      expect(Object.keys(entryLaunchParameters({})).length).assertEqual(0);
    });
    it('savedResolvedConfigurationSurvivesLaunchWithoutArguments', 0, () => {
      const first = resolveEntryRuntimeConfig({ 'datakitUrl': 'https://example.com', 'appId': 'app',
        'autoSync': 'false', 'logSamplingRate': '0', 'errorSamplingRate': '0.25' }, {});
      const second = resolveEntryRuntimeConfig({}, first);
      expect(JSON.stringify(second)).assertEqual(JSON.stringify(first));
      expect(second.autoSync).assertEqual('false');
      expect(second.logSamplingRate).assertEqual('0');
    });
    it('explicitDatakitClearsSavedDatawayAndToken', 0, () => {
      const config = resolveEntryRuntimeConfig({ 'datakitUrl': 'https://new.example.com' }, {
        'datawayUrl': 'https://old.example.com', 'clientToken': 'saved-token' });
      expect(config.datawayUrl).assertEqual('');
      expect(config.clientToken).assertEqual('');
      expect(resolveEntryRuntimeConfig({}, config).datakitUrl).assertEqual('https://new.example.com');
    });
    it('explicitDatawayCanReuseSavedToken', 0, () => {
      const config = resolveEntryRuntimeConfig({ 'datawayUrl': 'https://new.example.com' }, {
        'datakitUrl': 'https://old.example.com', 'clientToken': 'saved-token' });
      expect(config.datakitUrl).assertEqual('');
      expect(config.clientToken).assertEqual('saved-token');
    });
    it('explicitEmptyStringClearsSavedString', 0, () => {
      const config = resolveEntryRuntimeConfig({ 'resourceTestUrl': '', 'localDataFilterLogRule': '' }, {
        'resourceTestUrl': 'https://old.example.com', 'localDataFilterLogRule': 'saved-rule' });
      expect(config.resourceTestUrl).assertEqual('');
      expect(config.localDataFilterLogRule).assertEqual('');
    });
    it('legacyEmptyBehaviorUsesDemoDefaults', 0, () => {
      const config = resolveEntryRuntimeConfig({}, { 'autoSync': '', 'localDataFilterEnabled': '' });
      expect(config.autoSync).assertEqual('true');
      expect(config.localDataFilterEnabled).assertEqual('true');
      expect(config.remoteConfigTestEnabled).assertEqual('false');
      expect(config.fileDataStoreShadowTestEnabled).assertEqual('false');
      expect(config.datakitUrl).assertEqual('');
      expect(config.appId).assertEqual('');
    });
    it('normalizesSupportedBooleanForms', 0, () => {
      const config = resolveEntryRuntimeConfig({ 'autoSync': 'off', 'localDataFilterEnabled': 'ON',
        'remoteConfigTestEnabled': '1', 'fileDataStoreShadowTestEnabled': 'on',
        'networkRouteTestEnabled': '0' }, {});
      expect(config.autoSync).assertEqual('false');
      expect(config.localDataFilterEnabled).assertEqual('true');
      expect(config.remoteConfigTestEnabled).assertEqual('true');
      expect(config.fileDataStoreShadowTestEnabled).assertEqual('true');
      expect(config.networkRouteTestEnabled).assertEqual('false');
    });
    it('normalizesRouteModeOnceAndPreservesTheFallback', 0, () => {
      expect(resolveEntryRuntimeConfig({ 'networkRouteTestMode': ' DNS ' }, {}).networkRouteTestMode).assertEqual('dns');
      expect(resolveEntryRuntimeConfig({}, { 'networkRouteTestMode': 'PROXY' }).networkRouteTestMode).assertEqual('proxy');
      expect(resolveEntryRuntimeConfig({ 'networkRouteTestMode': 'unknown' }, {}).networkRouteTestMode).assertEqual('proxy');
    });
    it('rejectsInvalidValuesForBothEntrypoints', 0, () => {
      assertInvalid({ 'rumSamplingRate': '-1' });
      assertInvalid({ 'logSamplingRate': '1.1' });
      assertInvalid({ 'errorSamplingRate': 'NaN' });
      assertInvalid({ 'traceSamplingRate': '' });
      assertInvalid({ 'autoSync': 'maybe' });
      assertInvalid({ 'fileDataStoreShadowTestEnabled': 'maybe' });
      assertInvalid({ 'datakitUrl': 'http://one.example.com', 'datawayUrl': 'http://two.example.com' });
    });
    it('uploadValidationDoesNotChangeSharedConfiguration', 0, () => {
      const config = resolveEntryRuntimeConfig({ 'appId': 'app', 'datakitUrl': 'https://example.com' }, {});
      const before = JSON.stringify(config);
      let rejected = false;
      try {
        validateEntryTestConfig({ 'entryUploadE2EEnabled': 'true' }, config);
      } catch (_) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(JSON.stringify(config)).assertEqual(before);
      const controlled = resolveEntryRuntimeConfig({ 'autoSync': 'false', 'localDataFilterEnabled': 'false' }, config);
      validateEntryTestConfig({ 'entryUploadE2EEnabled': 'true' }, controlled);
    });
    it('keepDataTakesPriorityOverCleanupSwitches', 0, () => {
      const args: Record<string, string> = { 'entryKeepData': 'true',
        'entryClearDataBeforeTest': 'true', 'entryClearDataAfterTest': 'true' };
      expect(shouldClearEntryTestData(args, true)).assertFalse();
      expect(shouldClearEntryTestData(args, false)).assertFalse();
      expect(shouldClearEntryTestData({}, true)).assertTrue();
      expect(shouldClearEntryTestData({ 'entryClearDataBeforeTest': 'false' }, true)).assertFalse();
      expect(shouldClearEntryTestData({ 'entryClearDataAfterTest': 'false' }, false)).assertFalse();
    });
  });
}
