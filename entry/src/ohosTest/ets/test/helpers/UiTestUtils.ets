import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Want } from '@kit.AbilityKit';
import { EntryWaitUtils } from './EntryWaitUtils';

export class UiTestUtils {
  static async createDriver(): Promise<Driver> {
    const driver = Driver.create();
    await driver.delayMs(800);
    return driver;
  }

  static async launchEntryAbility(driver: Driver): Promise<void> {
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    const want: Want = {
      bundleName: 'com.guance.hm.example',
      abilityName: 'EntryAbility',
      parameters: {
        datakitUrl: 'http://127.0.0.1:9529',
        webViewUrl: 'about:blank',
        traceUrl: 'http://127.0.0.1:9529/api/user',
        appId: 'entry-ohos-test-app'
      }
    };
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

  static async pressBack(driver: Driver): Promise<void> {
    try {
      await driver.pressBack();
      await driver.delayMs(600);
    } catch (_error) {
      await EntryWaitUtils.delay(200);
    }
  }
}
