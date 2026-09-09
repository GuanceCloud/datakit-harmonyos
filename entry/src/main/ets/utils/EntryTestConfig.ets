import { isUploadEndpointAvailable } from '@guancecloud/ft_sdk/src/main/ets/components/http/UploadEndpoint';

/** UI instrumentation only; never changes launch configuration or persistence. */
export const ENTRY_UI_TEST_ACTIVE = 'entryUiTestActive';

export function testArgument(args: Record<string, string>, key: string): string | undefined {
  return args[`-s ${key}`] ?? args[key];
}

export function testBoolean(args: Record<string, string>, key: string, fallback: boolean): boolean {
  const value = testArgument(args, key);
  if (value === undefined) return fallback;
  const normalized = value.trim().toLowerCase();
  if (normalized === 'true') return true;
  if (normalized === 'false') return false;
  throw new Error(`${key} must be true or false`);
}

export function shouldClearEntryTestData(args: Record<string, string>, before: boolean): boolean {
  const keep = testBoolean(args, 'entryKeepData', false);
  const clear = testBoolean(args, before ? 'entryClearDataBeforeTest' : 'entryClearDataAfterTest', true);
  return !keep && clear;
}

export function validateEntryTestConfig(args: Record<string, string>, config: Record<string, string>): void {
  shouldClearEntryTestData(args, true);
  shouldClearEntryTestData(args, false);
  if (config.appId.length === 0) throw new Error('Configure appId in Demo or startup arguments');
  if (config.datawayUrl.length > 0 && config.clientToken.length === 0) {
    throw new Error('Dataway requires clientToken in the shared configuration');
  }
  const e2e = testBoolean(args, 'entryUploadE2EEnabled', false);
  // Real Axios timing tests are opt-in because they require caller-provided
  // HTTP/HTTPS endpoints reachable from the device.
  testBoolean(args, 'entryAxiosTimingE2EEnabled', false);
  if ((e2e || config.autoSync === 'true') &&
    !isUploadEndpointAvailable(config.datakitUrl, config.datawayUrl, config.clientToken)) {
    throw new Error('Uploading requires a valid saved endpoint or explicit datakitUrl / datawayUrl + clientToken');
  }
  if (e2e && (config.autoSync !== 'false' || config.localDataFilterEnabled !== 'false' ||
    config.remoteConfigTestEnabled !== 'false' || config.logSamplingRate !== '1' ||
    config.rumSamplingRate !== '1' || config.errorSamplingRate !== '1' ||
    config.traceSamplingRate !== '1')) {
    throw new Error('Upload E2E requires autoSync=false, sampling rates=1 and local/remote configuration filters disabled');
  }
}
