/** The same configuration schema is used by Demo launches and instrument tests. */
const ENTRY_RUNTIME_DEFAULTS: Record<string, string> = {
  'datakitUrl': '', 'datawayUrl': '', 'clientToken': '', 'appId': '',
  'webViewUrl': '', 'traceUrl': '', 'resourceTestUrl': '',
  'autoSync': 'true', 'logSamplingRate': '1', 'rumSamplingRate': '1',
  'errorSamplingRate': '1', 'traceSamplingRate': '1',
  'networkRouteTestEnabled': 'false', 'networkRouteTestMode': 'proxy', 'networkRouteTestHost': '',
  'remoteConfigTestEnabled': 'false', 'fileDataStoreShadowTestEnabled': 'false', 'localDataFilterEnabled': 'true',
  'localDataFilterLogRule': '', 'localDataFilterRumRule': ''
};
export const ENTRY_RUNTIME_KEYS: string[] = Object.keys(ENTRY_RUNTIME_DEFAULTS);
/** Forward only explicitly supplied app arguments, without test-specific defaults. */
export function entryLaunchParameters(args: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  const keys = ENTRY_RUNTIME_KEYS.concat(['coldStartDelayMs', 'coldLaunchNextUIAbility']);
  for (const key of keys) {
    const value = args[`-s ${key}`] ?? args[key];
    if (value !== undefined) result[key] = value;
  }
  return result;
}

/** Missing arguments inherit saved values; explicit empty strings clear string settings. */
export function resolveEntryRuntimeConfig(
  incoming: Record<string, string>, saved: Record<string, string>
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of ENTRY_RUNTIME_KEYS) {
    const stored = saved[key];
    const fallback = stored === undefined || stored.length === 0 ? ENTRY_RUNTIME_DEFAULTS[key] : stored;
    result[key] = (incoming[key] ?? fallback).trim();
  }
  // Selecting an endpoint must not revive the other mode from saved preferences.
  const hasDatakit = incoming.datakitUrl !== undefined;
  const hasDataway = incoming.datawayUrl !== undefined;
  if (hasDatakit && hasDataway) {
    if (result.datakitUrl.length > 0 && result.datawayUrl.length > 0) {
      throw new Error('Specify only one of datakitUrl and datawayUrl');
    }
    if (result.datawayUrl.length === 0) result.clientToken = '';
  } else if (hasDatakit) {
    result.datawayUrl = '';
    result.clientToken = '';
  } else if (hasDataway) {
    result.datakitUrl = '';
  } else if (result.datawayUrl.length > 0) {
    // Preserve the Demo's selection for older preferences containing both endpoints.
    result.datakitUrl = '';
  }
  for (const key of ['autoSync', 'networkRouteTestEnabled', 'remoteConfigTestEnabled', 'fileDataStoreShadowTestEnabled', 'localDataFilterEnabled']) {
    const value = result[key].toLowerCase();
    if (value === 'true' || value === '1' || value === 'on') result[key] = 'true';
    else if (value === 'false' || value === '0' || value === 'off') result[key] = 'false';
    else throw new Error(`${key} must be true or false`);
  }
  const mode = result.networkRouteTestMode.toLowerCase();
  result.networkRouteTestMode = mode === 'dns' || mode === 'proxy' ? mode : ENTRY_RUNTIME_DEFAULTS.networkRouteTestMode;
  for (const key of ['logSamplingRate', 'rumSamplingRate', 'errorSamplingRate', 'traceSamplingRate']) {
    const value = Number(result[key]);
    if (result[key].length === 0 || !Number.isFinite(value) || value < 0 || value > 1) {
      throw new Error(`${key} must be a number between 0 and 1`);
    }
    result[key] = String(value);
  }
  return result;
}
