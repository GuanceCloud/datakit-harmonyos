import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { UiTestUtils } from './helpers/UiTestUtils';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryRecordCapture } from './helpers/EntryRecordCapture';

async function readProbe(driver: Driver): Promise<string> {
  await UiTestUtils.clickId(driver, 'host-probe-inspect');
  const component = await driver.findComponent(ON.id('host-probe-result'));
  if (component === null || component === undefined) throw new Error('Host probe result is missing');
  return component.getText();
}

async function rebuildProbe(driver: Driver): Promise<string> {
  await UiTestUtils.clickId(driver, 'host-probe-rebuild');
  await driver.delayMs(500);
  return readProbe(driver);
}

export default function webViewHostUITest() {
  describe('WebViewHostUITest', () => {
    let driver: Driver;
    let capture: EntryRecordCapture;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      capture = new EntryRecordCapture();
      capture.start();
      await UiTestUtils.clickText(driver, 'WebView Host 验证');
    });

    afterEach(async () => {
      capture.stop();
      await UiTestUtils.pressBack(driver);
      await EntryDBAssert.cleanupAll();
    });

    it('ArkWeb should preserve bound policy then reject events after rebuild', 0, async () => {
      await UiTestUtils.clickId(driver, 'host-base-list');
      const allowed = await rebuildProbe(driver);
      if (!allowed.includes('"canUse": true')) throw new Error(`ArkWeb probe did not become ready: ${allowed}`);
      expect(allowed.includes('https://sub.example.com/host-probe')).assertTrue();
      expect(allowed.includes('"hostname": "sub.example.com"')).assertTrue();
      expect(allowed.includes('"canUse": true')).assertTrue();
      await UiTestUtils.clickId(driver, 'host-probe-log');
      await UiTestUtils.clickId(driver, 'host-probe-emit');
      expect(await capture.waitForRecord(DataType.RUM_WEBVIEW, ['web_host_probe_', 'is_web_view=true'], 6000) !== null)
        .assertTrue();
      expect(await capture.waitForRecord(DataType.LOG, ['web_host_probe_', 'log_source=webview'], 6000) !== null)
        .assertTrue();
      await UiTestUtils.clickId(driver, 'host-base-empty');
      expect((await readProbe(driver)).includes('"canUse": true')).assertTrue();
      const blocked = await rebuildProbe(driver);
      expect(blocked.includes('"wire": "[]"')).assertTrue();
      expect(blocked.includes('"canUse": false')).assertTrue();
      await UiTestUtils.clickId(driver, 'host-probe-emit');
      const result = await driver.findComponent(ON.id('host-probe-result'));
      const text = await result!.getText();
      const marker = text.match(/web_host_probe_\d+/);
      expect(marker !== null).assertTrue();
      expect(await capture.waitForRecord(DataType.RUM_WEBVIEW, [marker![0]], 1500) === null).assertTrue();
      expect(await capture.waitForRecord(DataType.LOG, [marker![0]], 1500) === null).assertTrue();
    });

    it('declarative ArkWeb proxy should use the same empty and null decisions', 0, async () => {
      await UiTestUtils.clickId(driver, 'host-probe-mode');
      await UiTestUtils.clickId(driver, 'host-base-empty');
      const denied = await rebuildProbe(driver);
      if (!denied.includes('"wire": "[]"')) throw new Error(`Declarative ArkWeb probe failed: ${denied}`);
      expect(denied.includes('"wire": "[]"')).assertTrue();
      expect(denied.includes('"canUse": false')).assertTrue();
      await UiTestUtils.clickId(driver, 'host-base-null');
      expect((await readProbe(driver)).includes('"canUse": false')).assertTrue();
      const allowed = await rebuildProbe(driver);
      expect(allowed.includes('"wire": null')).assertTrue();
      expect(allowed.includes('"canUse": true')).assertTrue();
    });
  });
}
