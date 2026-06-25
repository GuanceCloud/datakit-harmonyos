import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Want } from '@kit.AbilityKit';
import { EntryWaitUtils } from './EntryWaitUtils';

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
    default:
      value = undefined;
      break;
  }
  return value === undefined || value === null ? fallback : String(value);
}

export class UiTestUtils {
  static async createDriver(): Promise<Driver> {
    const driver = Driver.create();
    await driver.delayMs(800);
    return driver;
  }

  static async launchEntryAbility(driver: Driver): Promise<void> {
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    const launchArgs = getEntryLaunchArguments();
    const datakitUrl = readEntryLaunchParameter(launchArgs, 'entryDatakitUrl', DEFAULT_ENTRY_DATAKIT_URL);
    const datawayUrl = readEntryLaunchParameter(launchArgs, 'entryDatawayUrl', '');
    const clientToken = readEntryLaunchParameter(launchArgs, 'entryClientToken', '');
    const webViewUrl = readEntryLaunchParameter(launchArgs, 'entryWebViewUrl', WEBVIEW_RUM_TEST_URL);
    const traceUrl = readEntryLaunchParameter(launchArgs, 'entryTraceUrl', DEFAULT_ENTRY_TRACE_URL);
    const autoSync = readEntryLaunchParameter(launchArgs, 'entryAutoSync', 'false');
    const appId = readEntryLaunchParameter(launchArgs, 'entryAppId', DEFAULT_ENTRY_APP_ID);

    let want: Want;
    if (datawayUrl.length > 0 && clientToken.length > 0) {
      want = {
        bundleName: 'com.guance.hm.example',
        abilityName: 'EntryAbility',
        parameters: {
          datawayUrl: datawayUrl,
          clientToken: clientToken,
          webViewUrl: webViewUrl,
          traceUrl: traceUrl,
          autoSync: autoSync,
          appId: appId
        }
      };
    } else {
      want = {
        bundleName: 'com.guance.hm.example',
        abilityName: 'EntryAbility',
        parameters: {
          datakitUrl: datakitUrl,
          webViewUrl: webViewUrl,
          traceUrl: traceUrl,
          autoSync: autoSync,
          appId: appId
        }
      };
    }
    await delegator.startAbility(want);
    await driver.delayMs(1200);
    await UiTestUtils.ensureHome(driver);
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
