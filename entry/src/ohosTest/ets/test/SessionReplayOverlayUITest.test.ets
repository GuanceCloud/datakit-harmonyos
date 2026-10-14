import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTSDK } from '@guancecloud/ft_sdk';
import {
  ArkUIReplayCollector, ArkUIReplayLightSnapshot, FTSessionReplayConfig, FullSnapshotData,
  ImagePrivacy, ReplayImageWireframe, ReplayShapeWireframe,
  ReplayTextWireframe, TextAndInputPrivacy
} from '@guancecloud/ft_session_replay';

interface ReplayModalGeometryProbe {
  id: number;
  type: string;
  x: number;
  y: number;
  layoutX: number;
  layoutY: number;
  width: number;
  height: number;
}

interface ReplayModalMotionProbe {
  timestamp: number;
  nodes: Array<ReplayModalGeometryProbe>;
  light: ArkUIReplayLightSnapshot;
}

export default function sessionReplayOverlayUITest(): void {
  describe('SessionReplayOverlayUITest', () => {
    let driver: Driver;
    let ui: UIContext;
    let nativeWindow: window.Window;
    let directory: string;
    const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
      .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE));

    const show = async (id: string): Promise<void> => {
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      if (scroll === null || await scroll.scrollSearch(ON.id(id)) === null) throw new Error(`Fixture is offscreen: ${id}`);
      await driver.delayMs(300);
    };
    const click = async (id: string): Promise<void> => {
      const component = await driver.findComponent(ON.id(id));
      if (component === null) throw new Error(`Fixture button is missing: ${id}`);
      await component.click();
    };
    const category = async (name: string): Promise<void> => {
      await click('session-replay-category-select');
      const option = await driver.findComponent(ON.text(name));
      if (option === null) throw new Error(`Fixture category is missing: ${name}`);
      await option.click(); await driver.delayMs(300);
    };
    const write = (name: string, data: string | ArrayBuffer): void => {
      const file = fs.openSync(`${directory}/${name}`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, data); } finally { fs.closeSync(file); }
    };
    const save = async (name: string, light: ArkUIReplayLightSnapshot): Promise<FullSnapshotData> => {
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      write(`${name}.json`, JSON.stringify({ light, data }));
      const pixels = await nativeWindow.snapshot();
      const packer = image.createImagePacker();
      try { write(`${name}.png`, await packer.packing(pixels, { format: 'image/png', quality: 100 })); }
      finally { await packer.release(); await pixels.release(); }
      return data;
    };
    const scene = (): ArkUIReplayLightSnapshot => collector.captureSceneLight(ui, ['session-replay-transition-root'], vp2px(1));

    const observeModalMotion = (kind: string, output: Array<ReplayModalMotionProbe>): number => setInterval(() => {
      const light = scene();
      const root = light.nodes.find((node): boolean => node.nodeType === kind);
      if (root === undefined || output.length >= 40) return;
      const nodes: Array<ReplayModalGeometryProbe> = [];
      for (const source of light.nodes.filter((node): boolean => node.sceneLayer === root.sceneLayer)) {
        const node = ui.getFrameNodeByUniqueId(source.id % 1000000000);
        if (node === null) continue;
        const layout = node.getPositionToWindow();
        const transformed = node.getPositionToWindowWithTransform();
        nodes.push({ id: source.id, type: source.nodeType, x: transformed.x, y: transformed.y,
          layoutX: layout.x, layoutY: layout.y, width: source.width, height: source.height });
      }
      output.push({ timestamp: Date.now(), nodes, light });
    }, 32);

    beforeAll(async () => {
      driver = Driver.create();
      const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
      await delegator.startAbility({ bundleName: AbilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility', moduleName: 'entry' });
      let home = await driver.findComponent(ON.text('Session Replay Demo'));
      for (let attempt = 0; home === null && attempt < 30; attempt++) {
        await driver.delayMs(200); home = await driver.findComponent(ON.text('Session Replay Demo'));
      }
      if (home === null) throw new Error('Demo home is unavailable');
      FTSDK.setAutoSync(false);
      await home.click(); await driver.delayMs(1000);
      await click('session-replay-transition-button'); await driver.delayMs(1000);
      nativeWindow = await window.getLastWindow((await delegator.getCurrentTopAbility()).context);
      ui = nativeWindow.getUIContext();
      directory = `${delegator.getAppContext().filesDir}/replay-overlay-styles`;
      if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    });

    it('captures the native Popup surface and label', 0, async () => {
      await category('弹层与导航'); await show('session-replay-popup-open'); await click('session-replay-popup-open');
      await driver.delayMs(400);
      const light = scene(); const data = await save('popup', light);
      const source = light.nodes.find((node): boolean => node.isPopupSurface === true)!;
      const bubble = data.wireframes.find((node): boolean => node.id === source.id) as ReplayImageWireframe;
      expect(bubble.type).assertEqual('image'); expect(bubble.mimeType).assertEqual('svg+xml'); expect(bubble.isEmpty).assertFalse();
      expect(data.wireframes.some((node): boolean => node.type === 'text' && node.text === 'Popup 演示文字')).assertTrue();
      const repeated = collector.materializeLightSnapshot(scene()).data as FullSnapshotData;
      expect((repeated.wireframes.find((node): boolean => node.id === source.id) as ReplayImageWireframe).resourceId)
        .assertEqual(bubble.resourceId);
      await driver.pressBack(); await driver.delayMs(300);
      expect(scene().nodes.some((node): boolean => node.nodeType === 'Popup')).assertFalse();
    });
    it('captures the native Sheet surface and modal mask', 0, async () => {
      await show('session-replay-sheet-open'); await click('session-replay-sheet-open'); await driver.delayMs(500);
      const light = scene(); const data = await save('sheet', light);
      expect(data.wireframes.some((node): boolean => node.type === 'text' && node.text === 'Sheet 采集测试')).assertTrue();
      const pane = data.wireframes.find((node): boolean => node.id === light.nodes.find((source): boolean => source.nodeType === 'SheetPage')?.id) as ReplayShapeWireframe;
      const mask = data.wireframes.find((node): boolean => node.id === light.nodes.find((source): boolean => source.nodeType === 'SheetWrapper')?.id) as ReplayShapeWireframe;
      expect(pane.shapeStyle?.backgroundColor).assertEqual('#F1F3F5FF'); expect(pane.shapeStyle?.cornerRadius).assertEqual(32);
      expect(mask.shapeStyle?.backgroundColor).assertEqual('#00000033');
      const close = data.wireframes.find((node): boolean => node.id === light.nodes.find((source): boolean => source.isOverlayCloseIcon === true)?.id) as ReplayImageWireframe;
      expect(close.type).assertEqual('image'); expect(close.mimeType).assertEqual('svg+xml'); expect(close.isEmpty).assertFalse();
      await click('session-replay-sheet-close');
      let closed = scene();
      for (let attempt = 0; attempt < 12 && closed.nodes.some((node): boolean => node.nodeType === 'SheetWrapper'); attempt++) {
        await driver.delayMs(100); closed = scene();
      }
      write('sheet-closed.json', JSON.stringify({ light: closed, data: collector.materializeLightSnapshot(closed).data }));
      expect(closed.nodes.some((node): boolean => node.nodeType === 'SheetWrapper')).assertFalse();
    });
    it('captures AlertDialog content and confirmation styling', 0, async () => {
      await show('session-replay-alert-open');
      const motion: Array<ReplayModalMotionProbe> = [];
      const timer = observeModalMotion('AlertDialog', motion);
      ui.showAlertDialog({ title: 'Replay 对话框', message: '观察对话框文字与背景遮挡',
        confirm: { value: '确认', action: (): void => {} } });
      await new Promise<void>((resolve): void => { setTimeout(resolve, 900); });
      clearInterval(timer); write('alert-motion.json', JSON.stringify(motion));
      const light = scene(); const data = await save('alert', light);
      const confirm = await driver.findComponent(ON.text('确认'));
      if (confirm === null) throw new Error('Dialog confirmation is missing');
      const closing: Array<ReplayModalMotionProbe> = [];
      const closeTimer = observeModalMotion('AlertDialog', closing);
      await confirm.click(); await driver.delayMs(300);
      clearInterval(closeTimer); write('alert-close-motion.json', JSON.stringify(closing));
      expect(data.wireframes.some((node): boolean => node.type === 'text' && node.text === 'Replay 对话框')).assertTrue();
      const title = data.wireframes.find((node): boolean => node.type === 'text' && node.text === 'Replay 对话框') as ReplayTextWireframe;
      expect(title.textStyle.size).assertEqual(20); expect(title.textStyle.weight).assertEqual(700);
      const button = data.wireframes.find((node): boolean => node.type === 'text' && node.text === '确认') as ReplayTextWireframe;
      expect(button.textStyle.color).assertEqual('#0A59F7FF');
      const layer = Math.max(...light.nodes.map((node): number => node.sceneLayer ?? 0));
      const panelId = light.nodes.find((node): boolean => node.nodeType === 'Column' && node.sceneLayer === layer)?.id;
      const panel = data.wireframes.find((node): boolean => node.id === panelId) as ReplayShapeWireframe;
      expect(panel.shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF'); expect(panel.shapeStyle?.cornerRadius).assertEqual(32);
      expect(Math.abs(panel.x - (light.nodes[0].width - panel.width) / 2) < 0.02).assertTrue();
      expect(panel.x >= 0 && panel.x + panel.width <= light.nodes[0].width).assertTrue();
      for (const sample of closing) {
        const pane = sample.light.nodes.find((node): boolean => node.isNativeModalSurface === true)!;
        expect(Math.abs(pane.x - panel.x) < 0.02).assertTrue();
        expect(Math.abs(pane.y - panel.y) < 0.02).assertTrue();
        expect(pane.width).assertEqual(panel.width); expect(pane.height).assertEqual(panel.height);
      }
      expect(motion.length > 0 && motion[0].light.hasActiveAnimations === true).assertTrue();
      expect(motion[motion.length - 1].light.hasActiveAnimations).assertFalse();
      expect(scene().nodes.some((node): boolean => node.nodeType === 'AlertDialog')).assertFalse();
    });
    it('captures ActionSheet options and their styling', 0, async () => {
      await show('session-replay-action-sheet-open');
      const motion: Array<ReplayModalMotionProbe> = [];
      const timer = observeModalMotion('ActionSheet', motion);
      ui.showActionSheet({ title: 'Replay 操作列表', message: '选择一项验证弹层关闭与文字更新', sheets: [
        { title: '选项 A', action: (): void => {} }, { title: '选项 B', action: (): void => {} }
      ] });
      await new Promise<void>((resolve): void => { setTimeout(resolve, 900); });
      clearInterval(timer); write('action-sheet-motion.json', JSON.stringify(motion));
      const light = scene(); const data = await save('action-sheet', light);
      const option = await driver.findComponent(ON.text('选项 A'));
      if (option === null) throw new Error('ActionSheet option is missing');
      const closing: Array<ReplayModalMotionProbe> = [];
      const closeTimer = observeModalMotion('ActionSheet', closing);
      await option.click(); await driver.delayMs(300);
      clearInterval(closeTimer); write('action-sheet-close-motion.json', JSON.stringify(closing));
      expect(data.wireframes.some((node): boolean => node.type === 'text' && node.text === 'Replay 操作列表')).assertTrue();
      const title = data.wireframes.find((node): boolean => node.type === 'text' && node.text === 'Replay 操作列表') as ReplayTextWireframe;
      expect(title.textStyle.size).assertEqual(20); expect(title.textStyle.weight).assertEqual(500);
      const optionText = data.wireframes.find((node): boolean => node.type === 'text' && node.text === '选项 A') as ReplayTextWireframe;
      expect(optionText.textStyle.size).assertEqual(16); expect(optionText.textStyle.color).assertEqual('#000000CE');
      const layer = Math.max(...light.nodes.map((node): number => node.sceneLayer ?? 0));
      const panelId = light.nodes.find((node): boolean => node.nodeType === 'Column' && node.sceneLayer === layer)?.id;
      const panel = data.wireframes.find((node): boolean => node.id === panelId) as ReplayShapeWireframe;
      expect(panel.shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF'); expect(panel.shapeStyle?.cornerRadius).assertEqual(32);
      expect(Math.abs(panel.x - (light.nodes[0].width - panel.width) / 2) < 0.02).assertTrue();
      expect(panel.x >= 0 && panel.x + panel.width <= light.nodes[0].width).assertTrue();
      for (const sample of closing) {
        const pane = sample.light.nodes.find((node): boolean => node.isNativeModalSurface === true)!;
        expect(Math.abs(pane.x - panel.x) < 0.02).assertTrue();
        expect(Math.abs(pane.y - panel.y) < 0.02).assertTrue();
        expect(pane.width).assertEqual(panel.width); expect(pane.height).assertEqual(panel.height);
      }
      expect(motion.length > 0 && motion[0].light.hasActiveAnimations === true).assertTrue();
      expect(motion[motion.length - 1].light.hasActiveAnimations).assertFalse();
      expect(scene().nodes.some((node): boolean => node.nodeType === 'ActionSheet')).assertFalse();
    });
  });
}
