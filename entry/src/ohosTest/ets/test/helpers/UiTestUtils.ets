import { ENTRY_RUNTIME_KEYS, entryLaunchParameters } from '../../../../main/ets/utils/EntryRuntimeConfig';
import { ENTRY_UI_TEST_ACTIVE, shouldClearEntryTestData, testArgument, testBoolean, validateEntryTestConfig } from '../../../../main/ets/utils/EntryTestConfig';
import { Driver, ON, On } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Want } from '@kit.AbilityKit';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { EntryWaitUtils } from './EntryWaitUtils';

interface EntryLaunchArguments {
  parameters?: Record<string, string>;
}

function getEntryLaunchArguments(): EntryLaunchArguments {
  return AbilityDelegatorRegistry.getArguments() as Object as EntryLaunchArguments;
}

export class UiTestUtils {
  private static launched: boolean = false;

  static requireConfiguredPageUrl(key: string): string {
    const value = (AppStorage.get<string>(key) ?? '').trim();
    if (value.length === 0 || value === 'about:blank') {
      throw new Error(`Configure ${key} in Demo or shared startup arguments before running this UI case`);
    }
    return value;
  }

  static shouldClearData(before: boolean): boolean {
    return shouldClearEntryTestData(getEntryLaunchArguments().parameters ?? {}, before);
  }

  /** Keeps real-endpoint upload verification opt-in for ordinary UI regressions. */
  static isUploadE2EEnabled(): boolean {
    return testBoolean(getEntryLaunchArguments().parameters ?? {}, 'entryUploadE2EEnabled', false);
  }

  static getResourceErrorUrl(status: number = 500): string {
    const key = status === 404 ? 'entryResourceClientErrorUrl' : 'entryResourceErrorUrl';
    return (testArgument(getEntryLaunchArguments().parameters ?? {}, key) ??
      `https://httpbin.org/status/${status}`).trim();
  }

  static getResourceTimeoutUrl(): string {
    return (testArgument(getEntryLaunchArguments().parameters ?? {}, 'entryResourceTimeoutUrl') ??
      'https://httpbin.org/delay/30').trim();
  }

  static getWebViewExpectedMarker(): string {
    const marker = (testArgument(getEntryLaunchArguments().parameters ?? {}, 'entryWebViewExpectedMarker') ?? 'WebViewBridgeSmoke').trim();
    if (marker.length === 0) throw new Error('entryWebViewExpectedMarker must identify an event from the configured page');
    return marker;
  }

  static async createDriver(): Promise<Driver> {
    const driver = Driver.create();
    await driver.delayMs(800);
    return driver;
  }

  static async launchEntryAbility(driver: Driver): Promise<void> {
    // A test run owns one fresh app process. Do not replace an already installed
    // SDK or reconstruct its configuration inside the test process.
    const firstLaunch = !UiTestUtils.launched;
    if (firstLaunch && FTSDK.getRumConfig() !== null) {
      throw new Error('Start UI tests in a fresh app process so launch parameters reach EntryAbility.onCreate');
    }
    AppStorage.setOrCreate(ENTRY_UI_TEST_ACTIVE, true);
    await AbilityDelegatorRegistry.getAbilityDelegator().startAbility(UiTestUtils.createTestWant());
    const ready = await EntryWaitUtils.waitUntil(async () => {
      const appId = AppStorage.get<string>('appId') ?? '';
      return appId.length > 0 && FTSDK.getRumConfig()?.getRumAppId() === appId;
    }, 10000);
    if (!ready) throw new Error('RUM initialization did not complete; check appId and EntryAbility startup logs');
    if (firstLaunch && !await UiTestUtils.waitForText(driver, 'FT SDK HarmonyOS Test App', 5000)) {
      throw new Error('EntryAbility did not display the Demo home page');
    }
    if (firstLaunch) {
      const config: Record<string, string> = {};
      for (const key of ENTRY_RUNTIME_KEYS) config[key] = AppStorage.get<string>(key) ?? '';
      validateEntryTestConfig(getEntryLaunchArguments().parameters ?? {}, config);
    }
    UiTestUtils.launched = true;
    await UiTestUtils.ensureHome(driver);
  }

  private static createTestWant(): Want {
    return {
      bundleName: 'com.guance.hm.example',
      abilityName: 'EntryAbility',
      moduleName: 'entry',
      parameters: entryLaunchParameters(getEntryLaunchArguments().parameters ?? {})
    };
  }

  static async ensureHome(driver: Driver): Promise<void> {
    for (let index = 0; index < 6; index++) {
      const homeTitle = await driver.findComponent(ON.text('FT SDK HarmonyOS Test App'));
      if (homeTitle !== null && homeTitle !== undefined) {
        const list = await driver.findComponent(ON.type('List'));
        if (list !== null && list !== undefined) {
          await list.scrollToTop(2000);
        }
        return;
      }
      await UiTestUtils.pressBack(driver);
    }
    throw new Error('Cannot return to the Demo home page');
  }

  static async clickText(driver: Driver, text: string): Promise<void> {
    await UiTestUtils.clickMatching(driver, ON.text(text), text);
  }

  static async clickId(driver: Driver, id: string): Promise<void> {
    await UiTestUtils.clickMatching(driver, ON.id(id), id);
  }

  private static async clickMatching(driver: Driver, selector: On, label: string): Promise<void> {
    let component = await driver.findComponent(selector);
    if (component === null || component === undefined) {
      let container = await driver.findComponent(ON.type('Scroll'));
      if (container === null || container === undefined) {
        container = await driver.findComponent(ON.type('List'));
      }
      if (container !== null && container !== undefined) {
        await container.scrollToTop(2000);
        component = await container.scrollSearch(selector);
      }
    }
    if (component === null || component === undefined) {
      throw new Error(`UI component not found: ${label}`);
    }
    await component.click();
    await driver.delayMs(800);
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
