import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { FrameNode, UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { FTSDK, FTSessionReplayRUMContext } from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector, FTSessionReplayConfig, FTSessionReplayRecorder, FullSnapshotData, ImagePrivacy,
  ReplayImageWireframe, ReplayMutationData, ReplayRecordType, ReplayTextWireframe, ReplayViewportResizeData,
  ReplayWireframe, SessionReplayContext, TextAndInputPrivacy } from '@guancecloud/ft_session_replay';

export default function sessionReplayInputUITest(): void {
  describe('SessionReplayInputUITest', () => {
    let driver: Driver;
    let uiContext: UIContext;
    let nativeWindow: window.Window;
    const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
      .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE));
    const frame = (id: string): FrameNode => {
      const node = uiContext.getFrameNodeById(id);
      if (node === null) throw new Error(`Native input fixture is missing: ${id}`);
      return node;
    };
    beforeAll(async () => {
      driver = Driver.create();
      const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
      await delegator.startAbility({ bundleName: AbilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility', moduleName: 'entry' });
      let home = await driver.findComponent(ON.text('Session Replay Demo'));
      for (let index = 0; home === null && index < 30; index++) {
        await driver.delayMs(200);
        home = await driver.findComponent(ON.text('Session Replay Demo'));
      }
      if (home === null) throw new Error('Demo home is unavailable');
      FTSDK.setAutoSync(false);
      await home.click();
      await driver.delayMs(1400);
      const complex = await driver.findComponent(ON.id('session-replay-transition-button'));
      if (complex === null) throw new Error('Complex component page button is unavailable');
      await complex.click();
      await driver.delayMs(1400);
      const ability = await delegator.getCurrentTopAbility();
      nativeWindow = await window.getLastWindow(ability.context);
      uiContext = nativeWindow.getUIContext();
      const select = await driver.findComponent(ON.id('session-replay-category-select'));
      await select!.click();
      const option = await driver.findComponent(ON.text('输入与编辑'));
      await option!.click();
      await driver.delayMs(600);
    });

    it('keeps empty input placeholders, native colors, and SearchField geometry', 0, () => {
      for (const id of ['session-replay-input', 'session-replay-password', 'session-replay-text-area']) {
        const data = collector.materializeLightSnapshot(collector.captureLightSnapshot(uiContext, id, vp2px(1))).data as FullSnapshotData;
        const text = data.wireframes[0] as ReplayTextWireframe;
        expect(text.type).assertEqual('text');
        expect(text.text.length > 0 && !text.text.includes('•')).assertTrue();
        expect(text.textStyle.color).assertEqual('#00000099');
        expect(text.border === undefined).assertTrue();
        expect(text.textPosition?.alignment?.vertical).assertEqual(id === 'session-replay-text-area' ? 'top' : 'center');
      }
      const search = collector.materializeLightSnapshot(collector.captureLightSnapshot(uiContext, 'session-replay-search', vp2px(1))).data as FullSnapshotData;
      expect(search.wireframes[0].type).assertEqual('shape');
      const input = search.wireframes.find((node): boolean => node.permanentId === '__SearchField__session-replay-search') as ReplayTextWireframe;
      expect(input.text).assertEqual('搜索内容');
      expect(input.x > search.wireframes[0].x).assertTrue();
      expect(input.textStyle.color).assertEqual('#00000099');
    });

    it('always masks password values and resolves its eye and Search icons separately', 0, async () => {
      const password = await driver.findComponent(ON.id('session-replay-password'));
      await password!.inputText('Demo-Password-123');
      await driver.pressBack();
      await driver.delayMs(350);
      let light = collector.captureLightSnapshot(uiContext, 'session-replay-password', vp2px(1));
      for (let attempt = 0; light.hasActiveAnimations && attempt < 30; attempt++) {
        await driver.delayMs(100);
        light = collector.captureLightSnapshot(uiContext, 'session-replay-password', vp2px(1));
      }
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      expect((data.wireframes[0] as ReplayTextWireframe).text).assertEqual('•'.repeat('Demo-Password-123'.length));
      expect(JSON.stringify(data).includes('Demo-Password')).assertFalse();
      const eye = data.wireframes.find((node): boolean => node.type === 'image') as ReplayImageWireframe;
      expect(eye !== undefined && !eye.isEmpty && eye.mimeType === 'png').assertTrue();
      expect(collector.takeCapturedImageResources().length).assertEqual(1);
      let search = collector.captureLightSnapshot(uiContext, 'session-replay-search', vp2px(1));
      for (let attempt = 0; search.hasActiveAnimations && attempt < 30; attempt++) {
        await driver.delayMs(100);
        search = collector.captureLightSnapshot(uiContext, 'session-replay-search', vp2px(1));
      }
      expect((collector.materializeLightSnapshot(search).data as FullSnapshotData).wireframes.some(
        (node): boolean => node.type === 'image' && !node.isEmpty)).assertTrue();
    });

    it('records native eye-toggle plaintext and masks it again with explicit visible-password capture', 0, async () => {
      const secret = 'Demo-Password-123';
      const masked = '•'.repeat(secret.length);
      const shown = (): boolean => {
        const info = frame('session-replay-password').getInspectorInfo() as Record<string, Object>;
        return String((info['$attrs'] as Record<string, Object>)['showPassword']) === 'true';
      };
      const clickEye = async (): Promise<void> => {
        const eye = frame('session-replay-password').getFirstChild();
        if (eye === null) throw new Error('Native password eye is missing');
        const position = eye.getPositionToWindowWithTransform();
        const size = eye.getMeasuredSize();
        await driver.click(Math.round(vp2px(position.x) + size.width / 2),
          Math.round(vp2px(position.y) + size.height / 2));
      };
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setCaptureVisiblePassword(true));
      const context: FTSessionReplayRUMContext = { applicationId: 'input-test', sessionId: 'password-eye-test',
        viewId: 'password-eye-view', viewName: 'Password eye', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      const replayContext: SessionReplayContext = { applicationId: context.applicationId,
        sessionId: context.sessionId, viewId: context.viewId };
      const updates = (): Array<string> => {
        const values: Array<string> = [];
        for (const record of recorder.getRecordedRecords(replayContext)) {
          if (record.type === ReplayRecordType.FULL_SNAPSHOT) {
            const text = (record.data as FullSnapshotData).wireframes.find((node): boolean =>
              node.permanentId === 'session-replay-password') as ReplayTextWireframe;
            if (text !== undefined) values.push(text.text);
          } else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && (record.data as ReplayMutationData).source === 0) {
            for (const update of (record.data as ReplayMutationData).updates) {
              if (update.type === 'text' && update.text !== undefined) values.push(update.text);
            }
          }
        }
        return values;
      };
      try {
        expect(shown()).assertFalse();
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-password', vp2px(1));
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(350);
        await recorder.drainWrites();
        expect(updates()[0]).assertEqual(masked);
        await clickEye();
        await driver.delayMs(450);
        expect(shown()).assertTrue();
        await recorder.drainWrites();
        expect(updates()[updates().length - 1]).assertEqual(secret);
        const stillMasked = collector.materializeLightSnapshot(collector.captureLightSnapshot(uiContext,
          'session-replay-password', vp2px(1))).data as FullSnapshotData;
        expect((stillMasked.wireframes[0] as ReplayTextWireframe).text).assertEqual(masked);
        await clickEye();
        await driver.delayMs(450);
        expect(shown()).assertFalse();
        await recorder.drainWrites();
        expect(updates()[updates().length - 1]).assertEqual(masked);
      } finally {
        if (shown()) await clickEye();
        recorder.stop();
        await recorder.drainWrites();
        if (nativeWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height > 0) await driver.pressBack();
      }
    });

    it('captures native RichEditor runs and colors while honoring all-input masking', 0, async () => {
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      const append = await scroll!.scrollSearch(ON.text('追加富文本'));
      await append!.click();
      await driver.delayMs(300);
      collector.invalidateComponentRasters();
      let light = collector.captureLightSnapshot(uiContext, 'session-replay-rich-editor', vp2px(1));
      for (let attempt = 0; light.nodes[0].componentRasterKey === undefined && attempt < 30; attempt++) {
        await driver.delayMs(100);
        light = collector.captureLightSnapshot(uiContext, 'session-replay-rich-editor', vp2px(1));
      }
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      expect(data.wireframes.length).assertEqual(1);
      expect(data.wireframes[0].type).assertEqual('image');
      expect((data.wireframes[0] as ReplayImageWireframe).isEmpty).assertFalse();
      const firstBytes = collector.takeCapturedImageResources()[0].bytes;
      const source = image.createImageSource(firstBytes.buffer as ArrayBuffer);
      const pixels = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      try {
        const size = pixels.getImageInfoSync().size;
        const bytes = new Uint8Array(size.width * size.height * 4);
        pixels.readPixelsToBufferSync(bytes.buffer as ArrayBuffer);
        let blue = 0;
        for (let offset = 0; offset < bytes.length; offset += 4) {
          if (bytes[offset + 3] > 128 && bytes[offset + 2] > bytes[offset] + 50) blue++;
        }
        expect(blue > 50).assertTrue();
      } finally { await pixels.release(); await source.release(); }
      await append!.click();
      collector.invalidateComponentRasters();
      let changedBytes = firstBytes;
      for (let attempt = 0; attempt < 30; attempt++) {
        await driver.delayMs(100);
        const changed = collector.captureLightSnapshot(uiContext, 'session-replay-rich-editor', vp2px(1));
        collector.materializeLightSnapshot(changed);
        changedBytes = collector.takeCapturedImageResources()[0]?.bytes ?? firstBytes;
        if (new util.Base64Helper().encodeToStringSync(changedBytes) !== new util.Base64Helper().encodeToStringSync(firstBytes)) break;
      }
      expect(new util.Base64Helper().encodeToStringSync(changedBytes) === new util.Base64Helper().encodeToStringSync(firstBytes)).assertFalse();
      const privateCollector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE));
      const masked = privateCollector.materializeLightSnapshot(privateCollector.captureLightSnapshot(uiContext,
        'session-replay-rich-editor', vp2px(1))).data as FullSnapshotData;
      expect(masked.wireframes.length).assertEqual(1);
      expect(masked.wireframes[0].type).assertEqual('text');
      expect((masked.wireframes[0] as ReplayTextWireframe).text.includes('•')).assertTrue();
      expect(privateCollector.takeCapturedImageResources().length).assertEqual(0);
    });

    it('keeps Recorder viewport, scene clipping and native panning in sync when IME opens and closes', 0, async () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_ALL_INPUTS));
      const context: FTSessionReplayRUMContext = { applicationId: 'input-test', sessionId: 'keyboard-test',
        viewId: 'keyboard-view', viewName: 'Input', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      const replayContext: SessionReplayContext = { applicationId: context.applicationId, sessionId: context.sessionId, viewId: context.viewId };
      try {
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-transition-root', vp2px(1), true);
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(350);
        await recorder.drainWrites();
        const before = recorder.getRecordedRecords(replayContext).filter((record): boolean => record.type === ReplayRecordType.FULL_SNAPSHOT);
        const fullHeight = (before[before.length - 1].data as FullSnapshotData).wireframes[0].height;
        const editor = await driver.findComponent(ON.id('session-replay-rich-editor'));
        await editor!.click();
        await driver.delayMs(1200);
        await recorder.drainWrites();
        const keyboard = nativeWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect;
        expect(keyboard.height > 0).assertTrue();
        const records = recorder.getRecordedRecords(replayContext);
        const resizes = records.filter((record): boolean => record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT &&
          (record.data as ReplayViewportResizeData).source === 4);
        const viewport = resizes[resizes.length - 1].data as ReplayViewportResizeData;
        const snapshots = records.filter((record): boolean => record.type === ReplayRecordType.FULL_SNAPSHOT);
        const latest = (snapshots[snapshots.length - 1].data as FullSnapshotData).wireframes;
        expect(Math.abs(viewport.height - keyboard.top / vp2px(1)) < 1).assertTrue();
        expect(Math.abs(latest[0].height - viewport.height) < 1).assertTrue();
        const replayEditor = JSON.parse(JSON.stringify(latest.find((node): boolean =>
          node.permanentId === 'session-replay-rich-editor')!)) as ReplayWireframe;
        // IME panning continues after its Resize/Full checkpoint. Apply the
        // subsequent geometry mutations as the player does before comparing.
        for (const record of records.slice(records.indexOf(snapshots[snapshots.length - 1]) + 1)) {
          if (record.type !== ReplayRecordType.INCREMENTAL_SNAPSHOT || (record.data as ReplayMutationData).source !== 0) continue;
          for (const update of (record.data as ReplayMutationData).updates) {
            if (update.id !== replayEditor.id) continue;
            if (update.x !== undefined) replayEditor.x = update.x;
            if (update.y !== undefined) replayEditor.y = update.y;
            if (update.clip !== undefined) replayEditor.clip = update.clip;
          }
        }
        expect(Math.abs(replayEditor.y - frame('session-replay-rich-editor').getPositionToWindowWithTransform().y) < 1).assertTrue();
        expect(Math.abs(replayEditor.y + replayEditor.height - (replayEditor.clip?.bottom ?? 0) - viewport.height) < 1).assertTrue();
        await driver.pressBack();
        await driver.delayMs(900);
        await recorder.drainWrites();
        const closed = recorder.getRecordedRecords(replayContext).filter((record): boolean => record.type === ReplayRecordType.FULL_SNAPSHOT);
        expect(Math.abs((closed[closed.length - 1].data as FullSnapshotData).wireframes[0].height - fullHeight) < 1).assertTrue();
      } finally {
        recorder.stop();
        await recorder.drainWrites();
        if (nativeWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height > 0) await driver.pressBack();
      }
    });
  });
}
