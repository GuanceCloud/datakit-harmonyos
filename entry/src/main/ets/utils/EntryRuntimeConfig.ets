/** The same configuration schema is used by Demo launches and instrument tests. */
const ENTRY_RUNTIME_DEFAULTS: Record<string, string> = {
  'datakitUrl': '', 'datawayUrl': '', 'clientToken': '', 'appId': '',
  'webViewUrl': '', 'traceUrl': '', 'resourceTestUrl': '',
  'autoSync': 'true',
  'samplingRateConfigVersion': '2',
  'sessionSamplingRate': '100', 'logSamplingRate': '100',
  'sessionOnErrorSamplingRate': '0', 'traceSamplingRate': '100',
  'networkRouteTestEnabled': 'false', 'networkRouteTestMode': 'proxy', 'networkRouteTestHost': '',
  'remoteConfigTestEnabled': 'false', 'fileDataStoreShadowTestEnabled': 'false', 'localDataFilterEnabled': 'true',
  'localDataFilterLogRule': '', 'localDataFilterRumRule': ''
};

const SAMPLING_RATE_CONFIG_VERSION = '2';
const SAMPLING_RATE_KEYS = [
  'sessionSamplingRate', 'logSamplingRate', 'sessionOnErrorSamplingRate', 'traceSamplingRate'
];

/** Legacy Demo-only keys. They remain accepted as [0,1] launch inputs. */
export const ENTRY_RUNTIME_LEGACY_SAMPLING_KEYS = ['rumSamplingRate', 'errorSamplingRate'];
export const ENTRY_RUNTIME_KEYS: string[] = Object.keys(ENTRY_RUNTIME_DEFAULTS);

function normalizePercentageSamplingRate(value: string, key: string): string {
  const parsed = Number(value);
  if (value.length === 0 || !Number.isFinite(parsed) || parsed < 0 || parsed > 100) {
    throw new Error(`${key} must be a finite number between 0 and 100`);
  }
  return String(parsed);
}

function legacyProbabilityToPercentage(value: string, key: string): string {
  const parsed = Number(value);
  if (value.length === 0 || !Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    throw new Error(`${key} must be a finite number between 0 and 1`);
  }
  return String(parsed * 100);
}

function isLegacyPersistedSamplingConfig(saved: Record<string, string>): boolean {
  return saved.samplingRateConfigVersion !== SAMPLING_RATE_CONFIG_VERSION;
}

function resolveSamplingRate(
  incoming: Record<string, string>,
  saved: Record<string, string>,
  key: string,
  legacyKey?: string
): string {
  const incomingValue = incoming[key];
  if (incomingValue !== undefined) {
    return normalizePercentageSamplingRate(incomingValue.trim(), key);
  }

  const savedValue = saved[key];
  if (savedValue !== undefined && savedValue.trim().length > 0) {
    const normalized = savedValue.trim();
    // logSamplingRate and traceSamplingRate historically used the same key
    // with a [0,1] unit. Only saved values without version 2 are converted.
    if (isLegacyPersistedSamplingConfig(saved) && (key === 'logSamplingRate' || key === 'traceSamplingRate')) {
      return legacyProbabilityToPercentage(normalized, key);
    }
    return normalizePercentageSamplingRate(normalized, key);
  }

  if (legacyKey !== undefined) {
    const legacyIncoming = incoming[legacyKey];
    if (legacyIncoming !== undefined) {
      return legacyProbabilityToPercentage(legacyIncoming.trim(), legacyKey);
    }
    const legacySaved = saved[legacyKey];
    if (legacySaved !== undefined && legacySaved.trim().length > 0) {
      return legacyProbabilityToPercentage(legacySaved.trim(), legacyKey);
    }
  }
  return ENTRY_RUNTIME_DEFAULTS[key];
}

/** Forward only explicitly supplied app arguments, without test-specific defaults. */
export function entryLaunchParameters(args: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  const keys = ENTRY_RUNTIME_KEYS
    .concat(ENTRY_RUNTIME_LEGACY_SAMPLING_KEYS)
    .concat(['coldStartDelayMs', 'coldLaunchNextUIAbility']);
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
    if (SAMPLING_RATE_KEYS.indexOf(key) >= 0 || key === 'samplingRateConfigVersion') {
      continue;
    }
    const stored = saved[key];
    const fallback = stored === undefined || stored.length === 0 ? ENTRY_RUNTIME_DEFAULTS[key] : stored;
    result[key] = (incoming[key] ?? fallback).trim();
  }
  result.sessionSamplingRate = resolveSamplingRate(incoming, saved, 'sessionSamplingRate', 'rumSamplingRate');
  result.logSamplingRate = resolveSamplingRate(incoming, saved, 'logSamplingRate');
  result.sessionOnErrorSamplingRate = resolveSamplingRate(
    incoming,
    saved,
    'sessionOnErrorSamplingRate',
    'errorSamplingRate'
  );
  result.traceSamplingRate = resolveSamplingRate(incoming, saved, 'traceSamplingRate');
  // Every resolved configuration is written back in the new unit.
  result.samplingRateConfigVersion = SAMPLING_RATE_CONFIG_VERSION;

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
  return result;
}
