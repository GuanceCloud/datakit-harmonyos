import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Want } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import EntryAbility, {
  KEY_RUNTIME_CONFIG_TEST_BOOTSTRAP,
  RUNTIME_CONFIG_PREFERENCES_NAME
} from '../../../../main/ets/entryability/EntryAbility';
import { EntryWaitUtils } from './EntryWaitUtils';
import { EntrySDKTestSession } from './EntrySDKTestSession';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';

const WEBVIEW_RUM_TEST_URL =
  'data:text/html;base64,' +
  'PCFkb2N0eXBlIGh0bWw+PGh0bWw+PGJvZHk+PGgxPkZUIFdlYlZpZXcgVGVzdDwvaDE+PHNjcmlwdD5zZXRUaW1lb3V0KGZ1bmN0aW9uKCl7dmFyIGV2ZW50PXtuYW1lOiJydW0iLGRhdGE6e21lYXN1cmVtZW50OiJ2aWV3Iix0YWdzOnt2aWV3X2lkOiJ3ZWJ2aWV3X3Rlc3RfdmlldyIsdmlld19uYW1lOiJXZWJWaWV3QnJpZGdlU21va2UiLHNlcnZpY2U6ImJyb3dzZXIiLHNka192ZXJzaW9uOiIxLjAuMCJ9LGZpZWxkczp7ZHVyYXRpb246MSxsb2FkaW5nX3RpbWU6MX19fTt3aW5kb3cuRlRXZWJWaWV3SmF2YXNjcmlwdEJyaWRnZS5zZW5kRXZlbnQoSlNPTi5zdHJpbmdpZnkoZXZlbnQpKTt9LDUwMCk7PC9zY3JpcHQ+PC9ib2R5PjwvaHRtbD4=';
const DEFAULT_ENTRY_DATAKIT_URL = 'http://127.0.0.1:9529';
const DEFAULT_ENTRY_TRACE_URL = 'http://127.0.0.1:9529/api/user';
const DEFAULT_ENTRY_APP_ID = 'entry-ohos-test-app';

interface EntryLaunchParameters {
  entryDatakitUrl?: string;
  entryDatawayUrl?: string;
  entryClientToken?: string;
  entryWebViewUrl?: string;
  entryTraceUrl?: string;
  entryAutoSync?: string;
  entryAppId?: string;
  /** Enables the opt-in physical-device upload test against the launch endpoint. */
  entryUploadE2EEnabled?: string;
}

interface EntryLaunchArguments extends EntryLaunchParameters {
  parameters?: EntryLaunchParameters;
}

function getEntryLaunchArguments(): EntryLaunchArguments {
  return AbilityDelegatorRegistry.getArguments() as Object as EntryLaunchArguments;
}

function readEntryLaunchParameter(args: EntryLaunchArguments, key: string, fallback: string): string {
  let value: string | undefined;
  switch (key) {
    case 'entryDatakitUrl':
      value = args.parameters?.entryDatakitUrl ?? args.entryDatakitUrl;
      break;
    case 'entryDatawayUrl':
      value = args.parameters?.entryDatawayUrl ?? args.entryDatawayUrl;
      break;
    case 'entryClientToken':
      value = args.parameters?.entryClientToken ?? args.entryClientToken;
      break;
    case 'entryWebViewUrl':
      value = args.parameters?.entryWebViewUrl ?? args.entryWebViewUrl;
      break;
    case 'entryTraceUrl':
      value = args.parameters?.entryTraceUrl ?? args.entryTraceUrl;
      break;
    case 'entryAutoSync':
      value = args.parameters?.entryAutoSync ?? args.entryAutoSync;
      break;
    case 'entryAppId':
      value = args.parameters?.entryAppId ?? args.entryAppId;
      break;
    case 'entryUploadE2EEnabled':
      value = args.parameters?.entryUploadE2EEnabled ?? args.entryUploadE2EEnabled;
      break;
    default:
      value = undefined;
      break;
  }
  return value === undefined || value === null ? fallback : String(value);
}

export class UiTestUtils {
  private static session: EntrySDKTestSession | null = null;
  private static ability: EntryAbility | null = null;
  private static savedPreferences: Record<string, preferences.ValueType> | null = null;

  /** Root-suite hook: runs before any case, including class-filtered runs. */
  static async beginTestSession(): Promise<void> {
    if (UiTestUtils.session !== null) {
      return;
    }
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    const store = await preferences.getPreferences(delegator.getAppContext(), RUNTIME_CONFIG_PREFERENCES_NAME);
    UiTestUtils.savedPreferences = await store.getAll() as Record<string, preferences.ValueType>;
    // Bootstrap with the saved baseline only. The real test endpoint is
    // applied explicitly after capturing the active SDK configuration.
    const parameters: Record<string, string> = {};
    parameters[KEY_RUNTIME_CONFIG_TEST_BOOTSTRAP] = 'true';
    await delegator.startAbility({
      bundleName: 'com.guance.hm.example', abilityName: 'EntryAbility', parameters: parameters
    });
    const ready = await EntryWaitUtils.waitUntil(async () => {
      try {
        const ability = await delegator.getCurrentTopAbility() as EntryAbility;
        if (!ability.isRuntimeConfigReadyForTest()) {
          return false;
        }
        UiTestUtils.ability = ability;
        return true;
      } catch (_error) {
        // The new Ability may not be visible to the delegator yet.
        return false;
      }
    });
    if (!ready || UiTestUtils.ability === null) {
      throw new Error('EntryAbility did not finish loading its original configuration');
    }
    UiTestUtils.session = new EntrySDKTestSession(UiTestUtils.ability);
    await UiTestUtils.session.apply(UiTestUtils.createTestWant());
    UiTestUtils.assertTestConfigurationApplied();
  }

  /** Root-suite cleanup also runs after setup failures and without E2E enabled. */
  static async endTestSession(): Promise<void> {
    try {
      if (UiTestUtils.session !== null) {
        await UiTestUtils.session.restore();
      }
    } finally {
      try {
        await UiTestUtils.verifyAndRestorePreferences();
      } finally {
        UiTestUtils.session = null;
        UiTestUtils.ability = null;
        UiTestUtils.savedPreferences = null;
      }
    }
  }

  /** Keeps real-endpoint upload verification opt-in for ordinary UI regressions. */
  static isUploadE2EEnabled(): boolean {
    const launchArgs = getEntryLaunchArguments();
    return readEntryLaunchParameter(launchArgs, 'entryUploadE2EEnabled', 'false').toLowerCase() === 'true';
  }

  /** Requires an explicit DataKit URL or a complete Dataway credential pair. */
  static hasConfiguredUploadEndpoint(): boolean {
    const launchArgs = getEntryLaunchArguments();
    const datakitUrl = readEntryLaunchParameter(launchArgs, 'entryDatakitUrl', '').trim();
    const datawayUrl = readEntryLaunchParameter(launchArgs, 'entryDatawayUrl', '').trim();
    const clientToken = readEntryLaunchParameter(launchArgs, 'entryClientToken', '').trim();
    return datakitUrl.length > 0 || (datawayUrl.length > 0 && clientToken.length > 0);
  }

  static async createDriver(): Promise<Driver> {
    const driver = Driver.create();
    await driver.delayMs(800);
    return driver;
  }

  static async launchEntryAbility(driver: Driver): Promise<void> {
    if (UiTestUtils.session === null) {
      throw new Error('UI tests require the root beforeAll configuration fixture');
    }
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    // Foreground the existing test instance without reinstalling for each case.
    await delegator.startAbility({ bundleName: 'com.guance.hm.example', abilityName: 'EntryAbility' });
    UiTestUtils.assertTestConfigurationApplied();
    await driver.delayMs(1200);
    await UiTestUtils.ensureHome(driver);
  }

  private static createTestWant(): Want {
    const launchArgs = getEntryLaunchArguments();
    const datakitUrl = readEntryLaunchParameter(launchArgs, 'entryDatakitUrl', DEFAULT_ENTRY_DATAKIT_URL).trim();
    const datawayUrl = readEntryLaunchParameter(launchArgs, 'entryDatawayUrl', '').trim();
    const clientToken = readEntryLaunchParameter(launchArgs, 'entryClientToken', '').trim();
    const webViewUrl = readEntryLaunchParameter(launchArgs, 'entryWebViewUrl', WEBVIEW_RUM_TEST_URL);
    const traceUrl = readEntryLaunchParameter(launchArgs, 'entryTraceUrl', DEFAULT_ENTRY_TRACE_URL);
    // The opt-in real-endpoint upload suite controls its upload boundary with
    // FTSDK.flushSyncData(). Disable startup auto-sync so its assertions are
    // tied to the explicit upload rather than an automatic background poll.
    const autoSync = UiTestUtils.isUploadE2EEnabled()
      ? 'false'
      : readEntryLaunchParameter(launchArgs, 'entryAutoSync', 'false');
    const appId = readEntryLaunchParameter(launchArgs, 'entryAppId', DEFAULT_ENTRY_APP_ID).trim();

    let want: Want;
    if (datawayUrl.length > 0 && clientToken.length > 0) {
      want = {
        bundleName: 'com.guance.hm.example',
        abilityName: 'EntryAbility',
        parameters: {
          datawayUrl: datawayUrl,
          datakitUrl: '',
          clientToken: clientToken,
          webViewUrl: webViewUrl,
          traceUrl: traceUrl,
          autoSync: autoSync,
          appId: appId,
          runtimeConfigTransient: 'true'
        }
      };
    } else {
      want = {
        bundleName: 'com.guance.hm.example',
        abilityName: 'EntryAbility',
        parameters: {
          datakitUrl: datakitUrl,
          datawayUrl: '',
          clientToken: '',
          webViewUrl: webViewUrl,
          traceUrl: traceUrl,
          autoSync: autoSync,
          appId: appId,
          runtimeConfigTransient: 'true'
        }
      };
    }
    return want;
  }

  /** Check the installed objects used to build upload requests, not AppStorage. */
  static assertTestConfigurationApplied(): void {
    const config = UiTestUtils.ability?.getSDKConfigForTest();
    const want = UiTestUtils.createTestWant();
    const expected = want.parameters;
    const expectedAutoSync = !['false', '0', 'off'].includes(String(expected?.['autoSync']).trim().toLowerCase());
    if (config === null || config === undefined || expected === undefined ||
      config.getDatakitUrl().trim() !== String(expected['datakitUrl']) ||
      config.getDatawayUrl().trim() !== String(expected['datawayUrl']) ||
      config.getClientToken().trim() !== String(expected['clientToken']) ||
      FTSDK.getRumConfig()?.getRumAppId() !== String(expected['appId']) ||
      config.isAutoSyncEnabled() !== expectedAutoSync ||
      SyncTaskManager.getInstance().getStatus().autoSync !== expectedAutoSync) {
      throw new Error('The installed SDK endpoint, RUM appId, or autoSync does not match the test launch arguments');
    }
  }

  private static async verifyAndRestorePreferences(): Promise<void> {
    const original = UiTestUtils.savedPreferences;
    if (original === null) {
      return;
    }
    const store = await preferences.getPreferences(
      AbilityDelegatorRegistry.getAbilityDelegator().getAppContext(), RUNTIME_CONFIG_PREFERENCES_NAME
    );
    const current = await store.getAll() as Record<string, preferences.ValueType>;
    const originalKeys = Object.keys(original).sort();
    const currentKeys = Object.keys(current).sort();
    let changed = JSON.stringify(originalKeys) !== JSON.stringify(currentKeys);
    for (const key of originalKeys) {
      changed = changed || JSON.stringify(original[key]) !== JSON.stringify(current[key]);
    }
    if (!changed) {
      return;
    }
    // Preserve key absence as well as values, even on a newly installed Demo.
    for (const key of currentKeys) {
      if (!originalKeys.includes(key)) {
        await store.delete(key);
      }
    }
    for (const key of originalKeys) {
      await store.put(key, original[key]);
    }
    await store.flush();
    throw new Error('UI tests changed the saved Demo preferences; the original values have been restored');
  }

  static async ensureHome(driver: Driver): Promise<void> {
    for (let index = 0; index < 5; index++) {
      const homeTitle = await driver.findComponent(ON.text('FT SDK HarmonyOS Test App'));
      if (homeTitle !== null && homeTitle !== undefined) {
        return;
      }
      await UiTestUtils.pressBack(driver);
    }
  }

  static async clickText(driver: Driver, text: string): Promise<void> {
    for (let index = 0; index < 4; index++) {
      const component = await driver.findComponent(ON.text(text));
      if (component !== null && component !== undefined) {
        await component.click();
        await driver.delayMs(800);
        return;
      }
      await driver.swipe(540, 1500, 540, 700, 1200);
      await driver.delayMs(250);
    }
    throw new Error(`UI text not found: ${text}`);
  }

  static async clickId(driver: Driver, id: string): Promise<void> {
    for (let index = 0; index < 4; index++) {
      const component = await driver.findComponent(ON.id(id));
      if (component !== null && component !== undefined) {
        await component.click();
        await driver.delayMs(800);
        return;
      }
      await driver.swipe(540, 1500, 540, 700, 1200);
      await driver.delayMs(250);
    }
    throw new Error(`UI id not found: ${id}`);
  }

  static async waitForText(driver: Driver, text: string, timeoutMs: number = 6000): Promise<boolean> {
    return await EntryWaitUtils.waitUntil(async () => {
      const component = await driver.findComponent(ON.text(text));
      return component !== null && component !== undefined;
    }, timeoutMs, 250);
  }

  static async pressBack(driver: Driver): Promise<void> {
    try {
      await driver.pressBack();
      await driver.delayMs(600);
    } catch (_error) {
      await EntryWaitUtils.delay(200);
    }
  }
}
