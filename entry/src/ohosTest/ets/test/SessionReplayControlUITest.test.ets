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
  ReplayImageWireframe, ReplayMutationData, ReplayRecordType, ReplayShapeWireframe, ReplayTextWireframe, ReplayWireframe, SessionReplayContext,
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
    const controlFrames = async (id: string): Promise<Array<ReplayWireframe>> => {
      await show(id);
      for (let attempt = 0; attempt < 10; attempt++) {
        const light = id === 'session-replay-checkbox-group' ?
          collector.captureFrameNodeLight(frame(id).getParent()!, vp2px(1)) :
          collector.captureLightSnapshot(uiContext, id, vp2px(1));
        const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
        expect(data.wireframes.every((node): boolean => node.type !== 'image' || node.mimeType === 'svg+xml')).assertTrue();
        expect(collector.takeCapturedImageResources().every((resource): boolean => resource.mimeType === 'image/svg+xml')).assertTrue();
        if (!light.hasActiveAnimations) return id === 'session-replay-checkbox-group' ?
          data.wireframes.filter((node): boolean => node.permanentId === id || node.permanentId?.startsWith(`${id}:control:`) === true) :
          data.wireframes;
        await driver.delayMs(40);
      }
      throw new Error(`Frame control did not settle: ${id}`);
    };
    const removeDirectory = (directory: string): void => {
      for (const name of fileIo.listFileSync(directory)) {
        const path = `${directory}/${name}`;
        if (fileIo.statSync(path).isDirectory()) removeDirectory(path);
        else fileIo.unlinkSync(path);
      }
      fileIo.rmdirSync(directory);
    };

    it('renders normal, circle and disabled Button labels as text frames', 0, async () => {
      for (const id of ['session-replay-button-normal', 'session-replay-button-circle', 'session-replay-button-disabled']) {
        const frames = await controlFrames(id);
        expect(frames.length).assertEqual(1);
        expect(frames[0].type).assertEqual('text');
        expect((frames[0] as ReplayTextWireframe).text.length > 0).assertTrue();
        expect((frames[0] as ReplayTextWireframe).textPosition?.alignment?.horizontal).assertEqual('center');
        if (id.endsWith('disabled')) expect((frames[0] as ReplayTextWireframe).shapeStyle!.opacity! < 1).assertTrue();
      }
      const masked = new ArkUIReplayCollector(1500, new FTSessionReplayConfig());
      const frames = (masked.materializeLightSnapshot(masked.captureLightSnapshot(uiContext,
        'session-replay-button-normal', vp2px(1))).data as FullSnapshotData).wireframes;
      expect(frames.some((node): boolean => node.type === 'text')).assertTrue();
      expect(JSON.stringify(frames).includes('普通')).assertFalse();
    });

    it('updates Checkbox, partial CheckboxGroup, Radio and Switch shape frames', 0, async () => {
      const group = JSON.stringify(await controlFrames('session-replay-checkbox-group'));
      const before = JSON.stringify(await controlFrames('session-replay-checkbox-a'));
      const checkbox = await driver.findComponent(ON.id('session-replay-checkbox-a'));
      await checkbox!.click();
      expect(JSON.stringify(await controlFrames('session-replay-checkbox-a')) === before).assertFalse();
      const partial = await controlFrames('session-replay-checkbox-group');
      expect(JSON.stringify(partial) === group).assertFalse();
      expect(partial.some((node): boolean => node.permanentId?.includes('control:partial') === true &&
        (node as ReplayShapeWireframe).shapeStyle?.opacity === 1)).assertTrue();
      const radio = JSON.stringify(await controlFrames('session-replay-radio-b'));
      await (await driver.findComponent(ON.id('session-replay-radio-b')))!.click();
      expect(JSON.stringify(await controlFrames('session-replay-radio-b')) === radio).assertFalse();
      const toggle = JSON.stringify(await controlFrames('session-replay-toggle-switch'));
      await (await driver.findComponent(ON.id('session-replay-toggle-switch')))!.click();
      expect(JSON.stringify(await controlFrames('session-replay-toggle-switch')) === toggle).assertFalse();
    });

    it('captures Slider, determinate Progress and Gauge with analytic frames and vectors', 0, async () => {
      for (const id of ['session-replay-slider', 'session-replay-progress-linear',
        'session-replay-progress-ring', 'session-replay-gauge', 'session-replay-data-panel']) {
        const frames = await controlFrames(id);
        expect(frames.length > 1).assertTrue();
        expect(frames.some((node): boolean => node.id < 0 && (node.type === 'shape' || (node.type === 'image' && node.mimeType === 'svg+xml')))).assertTrue();
      }
    });

    it('updates Slider-linked Progress and Gauge without manual invalidation', 0, async () => {
      const slider = JSON.stringify(await controlFrames('session-replay-slider'));
      const progress = JSON.stringify(await controlFrames('session-replay-progress-linear'));
      const gauge = JSON.stringify(await controlFrames('session-replay-gauge'));
      await show('session-replay-slider');
      const bounds = await (await driver.findComponent(ON.id('session-replay-slider')))!.getBounds();
      await driver.click(Math.round(bounds.left + (bounds.right - bounds.left) * 0.8), Math.round((bounds.top + bounds.bottom) / 2));
      const sliderInfo = frame('session-replay-slider').getInspectorInfo() as Record<string, Object>;
      const sliderAttrs = sliderInfo['$attrs'] as Record<string, Object>;
      expect(Number(String((sliderAttrs['constructor'] as Record<string, Object>)['value'])) > 60).assertTrue();
      expect(JSON.stringify(await controlFrames('session-replay-slider')) === slider).assertFalse();
      expect(JSON.stringify(await controlFrames('session-replay-progress-linear')) === progress).assertFalse();
      expect(JSON.stringify(await controlFrames('session-replay-gauge')) === gauge).assertFalse();
    });

    it('records Slider motion as changing shape positions while images are masked', 0, async () => {
      await show('session-replay-slider');
      const directory = `${AbilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir}/replay-frame-motion-${Date.now()}`;
      fileIo.mkdirSync(directory);
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_ALL),
        new SessionReplaySegmentStore(directory, 1024 * 1024, 100));
      const context: FTSessionReplayRUMContext = { applicationId: 'frame-motion', sessionId: 'frame-motion',
        viewId: 'frame-motion', viewName: 'Slider', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      const replayContext: SessionReplayContext = { applicationId: context.applicationId,
        sessionId: context.sessionId, viewId: context.viewId };
      try {
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-transition-root', vp2px(1), true);
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(500);
        const bounds = await (await driver.findComponent(ON.id('session-replay-slider')))!.getBounds();
        const start = Date.now();
        await driver.swipe(Math.round(bounds.left + (bounds.right - bounds.left) * 0.1),
          Math.round((bounds.top + bounds.bottom) / 2), Math.round(bounds.left + (bounds.right - bounds.left) * 0.9),
          Math.round((bounds.top + bounds.bottom) / 2), 200);
        const end = Date.now();
        await driver.delayMs(500);
        await recorder.drainWrites();
        let thumbId = 0;
        const positions = new Set<number>();
        const times: Array<number> = [];
        for (const record of recorder.getRecordedRecords(replayContext)) {
          if (record.type === ReplayRecordType.FULL_SNAPSHOT) {
            const frames = (record.data as FullSnapshotData).wireframes;
            expect(frames.every((node): boolean => node.type !== 'image' || node.isEmpty === true || node.mimeType === 'svg+xml')).assertTrue();
            const thumb = frames.find((node): boolean => node.permanentId === 'session-replay-slider:control:thumb');
            if (thumb !== undefined) {
              expect(thumb.type).assertEqual('shape');
              thumbId = thumb.id;
            }
          } else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0 &&
            record.timestamp >= start && record.timestamp <= end) {
            for (const update of (record.data as ReplayMutationData).updates) if (update.id === thumbId && update.x !== undefined) {
              expect(update.type).assertEqual('shape');
              expect(update.resourceId === undefined && update.base64 === undefined).assertTrue();
              positions.add(update.x);
              times.push(record.timestamp);
            }
          }
        }
        expect(positions.size > 16).assertTrue();
        expect(new SessionReplayResourceStore(directory, 1024 * 1024).list().every((resource): boolean => resource.mimeType === 'image/svg+xml')).assertTrue();
        const gaps = times.slice(1).map((time, index): number => time - times[index]).sort((a, b): number => a - b);
        console.info(`REPLAY_FRAME_MOTION positions=${positions.size}, durationMs=${end - start}, gapMedianMs=${gaps[Math.floor(gaps.length / 2)]}`);
      } finally {
        recorder.stop();
        await recorder.drainWrites();
        removeDirectory(directory);
      }
    });

    it('updates the native Rating stars after an edit', 0, async () => {
      const rating = JSON.stringify(await controlFrames('session-replay-rating'));
      const stars = await (await driver.findComponent(ON.id('session-replay-rating')))!.getBounds();
      await driver.click(Math.round(stars.left + (stars.right - stars.left) * 0.9), Math.round((stars.top + stars.bottom) / 2));
      expect(JSON.stringify(await controlFrames('session-replay-rating')) === rating).assertFalse();
    });


    it('persists checkbox shape mutations through Worker without a component image', 0, async () => {
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
        const targets = new Set<number>();
        let mutations = 0;
        for (const record of recorder.getRecordedRecords(replayContext)) {
          const frames = record.type === ReplayRecordType.FULL_SNAPSHOT ? (record.data as FullSnapshotData).wireframes :
            record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0 ?
              (record.data as ReplayMutationData).adds.map((add): ReplayWireframe => add.wireframe) : [];
          for (const node of frames) if (node.permanentId?.startsWith('session-replay-checkbox-a') === true) {
            expect(node.type).assertEqual('shape');
            targets.add(node.id);
          }
          if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0) {
            for (const update of (record.data as ReplayMutationData).updates) if (targets.has(update.id)) {
              expect(update.type).assertEqual('shape');
              expect(update.resourceId === undefined && update.base64 === undefined).assertTrue();
              mutations++;
            }
          }
        }
        expect(targets.size > 1).assertTrue();
        expect(mutations > 0).assertTrue();
      } finally {
        recorder.stop();
        await recorder.drainWrites();
        removeDirectory(directory);
      }
    });
  });
}
