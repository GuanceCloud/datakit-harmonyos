import { Context } from '@kit.AbilityKit';
import Want from '@ohos.app.ability.Want';
import preferences from '@ohos.data.preferences';
import { FTRUMConfig, FTSDK, FTSDKConfig } from '@guancecloud/ft_sdk/Index';
import { DemoLogger } from './DemoLogger';

const TAG = 'DemoColdLaunchRumInitializer';
const PREFERENCES_NAME = 'entry_ability_runtime_config';
const KEY_DATAKIT_URL = 'datakitUrl';
const KEY_DATAWAY_URL = 'datawayUrl';
const KEY_CLIENT_TOKEN = 'clientToken';
const KEY_APP_ID = 'appId';

interface ColdLaunchRumSettings {
  datakitUrl: string;
  datawayUrl: string;
  clientToken: string;
  appId: string;
}

let initializationInFlight: Promise<void> | null = null;

/**
 * Minimal, idempotent bootstrap used before a UIAbility exists. It reads the
 * persisted Demo configuration and accepts equivalent Want parameters for an
 * AppService cold launch. The complete demo setup in EntryAbility may still
 * apply its optional log, trace, UI, and test configuration afterwards.
 */
export function initializeDemoColdLaunchRum(
  context: Context,
  source: string,
  want?: Want
): Promise<void> {
  if (FTSDK.getRumConfig() !== null) {
    // AbilityStage can have initialized RUM from persisted settings before a
    // UIAbility arrives with newer Want parameters. Refresh the intake route
    // instead of silently retaining an empty or stale endpoint.
    return refreshUploadEndpoint(context, source, want);
  }
  if (initializationInFlight !== null) {
    return initializationInFlight;
  }
  initializationInFlight = initialize(context, source, want);
  initializationInFlight.then((): void => {
    initializationInFlight = null;
  }).catch((): void => {
    initializationInFlight = null;
  });
  return initializationInFlight;
}

/** Validate the persisted configuration the next background process will read. */
export async function getDemoColdLaunchConfigurationIssue(context: Context): Promise<string> {
  const settings = await readSettings(context);
  if (settings.appId.length === 0) {
    return '请先通过启动参数配置并持久化 appId';
  }
  if (settings.datawayUrl.length > 0 && settings.clientToken.length === 0) {
    return '已保存 Dataway 地址，但缺少 clientToken';
  }
  if (settings.datawayUrl.length === 0 && settings.datakitUrl.length === 0) {
    return '请先通过启动参数配置并持久化 DataKit 或 Dataway 上传地址';
  }
  return '';
}

async function initialize(context: Context, source: string, want?: Want): Promise<void> {
  try {
    const settings = await readSettings(context, want);
    if (FTSDK.getRumConfig() !== null) {
      DemoLogger.i(TAG, `RUM became ready while reading startup config; source=${source}`);
      return;
    }
    if (settings.appId.length === 0) {
      DemoLogger.w(TAG, `Early RUM bootstrap skipped: no persisted or Want appId, source=${source}`);
      return;
    }

    FTSDK.install(createSdkConfig(settings), context);
    // A UIAbility may have completed its full initialization while the base SDK
    // was being installed. Do not replace that configuration.
    if (FTSDK.getRumConfig() !== null) {
      DemoLogger.i(TAG, `RUM became ready during early SDK install; source=${source}`);
      return;
    }
    const rumConfig = new FTRUMConfig()
      .setRumAppId(settings.appId)
      .setEnableTraceUserAction(true)
      .setEnableTraceUserView(false)
      .setEnableTraceUserResource(false)
      .setEnableTrackAppCrash(false)
      .setEnableTrackAppANR(false)
      .setEnableTrackAppUIBlock(false);
    FTSDK.installRUMConfig(rumConfig);
    DemoLogger.i(TAG, `Early SDK/RUM bootstrap completed, source=${source}`);
  } catch (error) {
    DemoLogger.e(TAG, `Early SDK/RUM bootstrap failed, source=${source}, error=${String(error)}`);
  }
}

async function refreshUploadEndpoint(context: Context, source: string, want?: Want): Promise<void> {
  try {
    const settings = await readSettings(context, want);
    if (settings.datawayUrl.length > 0 && settings.clientToken.length > 0) {
      FTSDK.setDatawayUrl(settings.datawayUrl, settings.clientToken);
      DemoLogger.i(TAG, `RUM already initialized; refreshed Dataway endpoint, source=${source}`);
      return;
    }
    if (settings.datakitUrl.length > 0) {
      FTSDK.setDatakitUrl(settings.datakitUrl);
      DemoLogger.i(TAG, `RUM already initialized; refreshed DataKit endpoint, source=${source}`);
      return;
    }
    DemoLogger.i(TAG, `RUM already initialized; no upload endpoint override, source=${source}`);
  } catch (error) {
    DemoLogger.e(TAG, `Failed to refresh RUM upload endpoint, source=${source}, error=${String(error)}`);
  }
}

async function readSettings(context: Context, want?: Want): Promise<ColdLaunchRumSettings> {
  const preferenceStore = await preferences.getPreferences(context, PREFERENCES_NAME);
  return {
    datakitUrl: await resolveValue(preferenceStore, want, KEY_DATAKIT_URL),
    datawayUrl: await resolveValue(preferenceStore, want, KEY_DATAWAY_URL),
    clientToken: await resolveValue(preferenceStore, want, KEY_CLIENT_TOKEN),
    appId: await resolveValue(preferenceStore, want, KEY_APP_ID)
  };
}

async function resolveValue(
  preferenceStore: preferences.Preferences,
  want: Want | undefined,
  key: string
): Promise<string> {
  const incomingValue = want?.parameters?.[key];
  if (incomingValue !== undefined && incomingValue !== null) {
    const stringValue = String(incomingValue).trim();
    if (stringValue.length > 0) {
      return stringValue;
    }
  }
  return String(await preferenceStore.get(key, '')).trim();
}

function createSdkConfig(settings: ColdLaunchRumSettings): FTSDKConfig {
  let config: FTSDKConfig;
  if (settings.datawayUrl.length > 0 && settings.clientToken.length > 0) {
    config = FTSDKConfig.builder(settings.datawayUrl, settings.clientToken);
  } else if (settings.datakitUrl.length > 0) {
    config = FTSDKConfig.builder(settings.datakitUrl);
  } else {
    config = FTSDKConfig.builder();
  }
  return config
    .setDebug(true)
    // This bootstrap is also used by independent ExtensionAbility processes.
    .setOnlySupportMainProcess(false)
    .setServiceName('HarmonyOS-Test-App');
}
