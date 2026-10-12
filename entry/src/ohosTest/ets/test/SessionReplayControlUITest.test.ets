import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { FrameNode, UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { FTSDK, FTSessionReplayRUMContext } from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector, FTSessionReplayConfig, FTSessionReplayRecorder, FullSnapshotData, ImagePrivacy,
  ReplayImageWireframe, ReplayMutationData, ReplayRecordType, ReplayTextWireframe, ReplayWireframe, SessionReplayContext,
  SessionReplayResourceStore, SessionReplaySegmentStore, TextAndInputPrivacy } from '@guancecloud/ft_session_replay';

export default function sessionReplayControlUITest(): void {
  describe('SessionReplayControlUITest', () => {
    let driver: Driver;
    let uiContext: UIContext;
    const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
      .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE));
    beforeAll(async () => {
      driver = Driver.create();
      const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
      await delegator.startAbility({ bundleName: AbilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility', moduleName: 'entry' });
      let home = await driver.findComponent(ON.text('Session Replay Demo'));
      for (let attempt = 0; home === null && attempt < 30; attempt++) {
        await driver.delayMs(200);
        home = await driver.findComponent(ON.text('Session Replay Demo'));
      }
      if (home === null) throw new Error('Demo home is unavailable');
      FTSDK.setAutoSync(false);
      await home.click();
      await driver.delayMs(1400);
      const complex = await driver.findComponent(ON.id('session-replay-transition-button'));
      if (complex === null) throw new Error('Complex component page is unavailable');
      await complex.click();
      await driver.delayMs(1400);
      const ability = await delegator.getCurrentTopAbility();
      uiContext = (await window.getLastWindow(ability.context)).getUIContext();
      const select = await driver.findComponent(ON.id('session-replay-category-select'));
      await select!.click();
      const option = await driver.findComponent(ON.text('按钮与选择'));
      await option!.click();
      await driver.delayMs(600);
    });

    const frame = (id: string): FrameNode => {
      const node = uiContext.getFrameNodeById(id);
      if (node === null) throw new Error(`Control fixture missing: ${id}`);
      return node;
    };
    const show = async (id: string): Promise<void> => {
      for (let attempt = 0; attempt < 8; attempt++) {
        const scroll = frame('session-replay-components-scroll');
        const position = scroll.getPositionToWindowWithTransform();
        const height = scroll.getMeasuredSize().height / vp2px(1);
        const target = frame(id);
        const bounds = target.getPositionToWindowWithTransform();
        const targetHeight = target.getMeasuredSize().height / vp2px(1);
        const top = position.y + 8;
        const bottom = position.y + height - 8;
        if (bounds.y >= top && bounds.y + targetHeight <= bottom) return;
        const above = bounds.y < top;
        const distance = Math.min(height * 0.55, Math.max(40,
          above ? top - bounds.y : bounds.y + targetHeight - bottom));
        const start = above ? top + 48 : bottom - 48;
        const end = above ? start + distance : start - distance;
        const x = Math.round(vp2px(position.x + 12));
        await driver.swipe(x, Math.round(vp2px(start)), x, Math.round(vp2px(end)), 1000);
        await driver.delayMs(250);
      }
      throw new Error(`Control did not enter the viewport: ${id}`);
    };
    const bitmap = async (id: string): Promise<Uint8Array> => {
      await show(id);
      for (let attempt = 0; attempt < 30; attempt++) {
        const light = collector.captureLightSnapshot(uiContext, id, vp2px(1));
        const frames = (collector.materializeLightSnapshot(light).data as FullSnapshotData).wireframes;
        const pixels = frames[0] as ReplayImageWireframe;
        const resources = collector.takeCapturedImageResources();
        if (pixels.type === 'image' && !pixels.isEmpty && !light.hasActiveAnimations) {
          expect(pixels.mimeType).assertEqual('png');
          expect(pixels.shapeStyle?.backgroundColor === undefined).assertTrue();
          expect(frames.length).assertEqual(1);
          expect(resources.length).assertEqual(1);
          return resources[0].bytes;
        }
        await driver.delayMs(100);
      }
      throw new Error(`Native control bitmap did not settle: ${id}`);
    };
    const encoded = (bytes: Uint8Array): string => new util.Base64Helper().encodeToStringSync(bytes);
    const ink = async (bytes: Uint8Array): Promise<number> => {
      const source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const map = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      try {
        const size = map.getImageInfoSync().size;
        const data = new Uint8Array(size.width * size.height * 4);
        map.readPixelsToBufferSync(data.buffer as ArrayBuffer);
        let count = 0;
        for (let offset = 3; offset < data.length; offset += 4) if (data[offset] > 0) count++;
        return count;
      } finally { await map.release(); await source.release(); }
    };
    const removeDirectory = (directory: string): void => {
      for (const name of fileIo.listFileSync(directory)) {
        const path = `${directory}/${name}`;
        if (fileIo.statSync(path).isDirectory()) removeDirectory(path);
        else fileIo.unlinkSync(path);
      }
      fileIo.rmdirSync(directory);
    };

    it('renders native normal, circle and disabled Button labels without duplicate chrome', 0, async () => {
      for (const id of ['session-replay-button-normal', 'session-replay-button-circle', 'session-replay-button-disabled']) {
        expect(await ink(await bitmap(id)) > 100).assertTrue();
      }
      const masked = new ArkUIReplayCollector(1500, new FTSessionReplayConfig());
      const frames = (masked.materializeLightSnapshot(masked.captureLightSnapshot(uiContext,
        'session-replay-button-normal', vp2px(1))).data as FullSnapshotData).wireframes;
      expect(frames.some((node): boolean => node.type === 'text')).assertTrue();
      expect(JSON.stringify(frames).includes('普通')).assertFalse();
    });

    it('renders and updates Checkbox, partial CheckboxGroup, Radio and Switch pixels', 0, async () => {
      const group = await bitmap('session-replay-checkbox-group');
      const before = await bitmap('session-replay-checkbox-a');
      const checkbox = await driver.findComponent(ON.id('session-replay-checkbox-a'));
      await checkbox!.click();
      expect(encoded(await bitmap('session-replay-checkbox-a')) === encoded(before)).assertFalse();
      expect(encoded(await bitmap('session-replay-checkbox-group')) === encoded(group)).assertFalse();
      const radio = await bitmap('session-replay-radio-b');
      await (await driver.findComponent(ON.id('session-replay-radio-b')))!.click();
      expect(encoded(await bitmap('session-replay-radio-b')) === encoded(radio)).assertFalse();
      const toggle = await bitmap('session-replay-toggle-switch');
      await (await driver.findComponent(ON.id('session-replay-toggle-switch')))!.click();
      expect(encoded(await bitmap('session-replay-toggle-switch')) === encoded(toggle)).assertFalse();
    });

    it('captures the native Slider, Rating, linear and ring Progress, Gauge and DataPanel', 0, async () => {
      for (const id of ['session-replay-slider', 'session-replay-rating', 'session-replay-progress-linear',
        'session-replay-progress-ring', 'session-replay-gauge', 'session-replay-data-panel']) {
        expect(await ink(await bitmap(id)) > 50).assertTrue();
      }
    });

    it('updates Slider-linked Progress and Gauge without manual invalidation', 0, async () => {
      const slider = await bitmap('session-replay-slider');
      const progress = await bitmap('session-replay-progress-linear');
      const gauge = await bitmap('session-replay-gauge');
      await show('session-replay-slider');
      const bounds = await (await driver.findComponent(ON.id('session-replay-slider')))!.getBounds();
      await driver.click(Math.round(bounds.left + (bounds.right - bounds.left) * 0.8), Math.round((bounds.top + bounds.bottom) / 2));
      const sliderInfo = frame('session-replay-slider').getInspectorInfo() as Record<string, Object>;
      const sliderAttrs = sliderInfo['$attrs'] as Record<string, Object>;
      expect(Number(String((sliderAttrs['constructor'] as Record<string, Object>)['value'])) > 60).assertTrue();
      expect(encoded(await bitmap('session-replay-slider')) === encoded(slider)).assertFalse();
      expect(encoded(await bitmap('session-replay-progress-linear')) === encoded(progress)).assertFalse();
      expect(encoded(await bitmap('session-replay-gauge')) === encoded(gauge)).assertFalse();
    });

    it('updates the native Rating stars after an edit', 0, async () => {
      const rating = await bitmap('session-replay-rating');
      const stars = await (await driver.findComponent(ON.id('session-replay-rating')))!.getBounds();
      await driver.click(Math.round(stars.left + (stars.right - stars.left) * 0.9), Math.round((stars.top + stars.bottom) / 2));
      expect(encoded(await bitmap('session-replay-rating')) === encoded(rating)).assertFalse();
    });

    it('persists changed native control images through the automatic Recorder Worker queue', 0, async () => {
      await show('session-replay-checkbox-a');
      const directory = `${AbilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir}/replay-controls-${Date.now()}`;
      fileIo.mkdirSync(directory);
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE),
        new SessionReplaySegmentStore(directory, 1024 * 1024, 100));
      const context: FTSessionReplayRUMContext = { applicationId: 'control-test', sessionId: 'control-session',
        viewId: 'control-view', viewName: 'Checkbox', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      const replayContext: SessionReplayContext = { applicationId: context.applicationId,
        sessionId: context.sessionId, viewId: context.viewId };
      try {
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-transition-root', vp2px(1), true);
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(1200);
        await (await driver.findComponent(ON.id('session-replay-checkbox-a')))!.click();
        await driver.delayMs(1200);
        await recorder.drainWrites();
        const images: Array<ReplayImageWireframe> = [];
        const resourceNames = new Set<string>();
        let targetId = 0;
        for (const record of recorder.getRecordedRecords(replayContext)) {
          const frames = record.type === ReplayRecordType.FULL_SNAPSHOT ? (record.data as FullSnapshotData).wireframes :
            record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0 ?
              (record.data as ReplayMutationData).adds.map((add): ReplayWireframe => add.wireframe) : [];
          for (const node of frames) if (node.permanentId === 'session-replay-checkbox-a') {
            targetId = node.id;
            if (node.type === 'image' && !node.isEmpty) images.push(node);
          }
          if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0) {
            for (const update of (record.data as ReplayMutationData).updates) {
              if (update.id === targetId && update.resourceId !== undefined) resourceNames.add(update.resourceId);
            }
          }
        }
        for (const node of images) if (node.resourceId !== undefined) resourceNames.add(node.resourceId);
        expect(images.length > 0).assertTrue();
        expect(resourceNames.size >= 2).assertTrue();
        const store = new SessionReplayResourceStore(directory, 1024 * 1024);
        for (const name of resourceNames) {
          const asset = store.list().find((resource): boolean => resource.fileName === name);
          expect(asset !== undefined && store.read(asset!)!.byteLength > 100).assertTrue();
        }
      } finally {
        recorder.stop();
        await recorder.drainWrites();
        removeDirectory(directory);
      }
    });
  });
}
