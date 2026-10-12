import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { FrameNode, UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { FTSDK, FTSessionReplayRUMContext } from '@guancecloud/ft_sdk';
import {
  ArkUIReplayCollector, FTSessionReplayConfig, FTSessionReplayRecorder, FullSnapshotData, ImagePrivacy,
  ReplayImageWireframe, ReplayMutationData, ReplayRecordType, ReplaySnapshotProcessor, ReplayTextWireframe,
  ReplayWireframe, SessionReplayContext, SessionReplayResourceStore, SessionReplaySegmentStore, TextAndInputPrivacy
} from '@guancecloud/ft_session_replay';
import arkUIReplayCollectorUnitTest from '@guancecloud/ft_session_replay/src/test/unit/ArkUIReplayCollectorUnit.test';
import { SessionReplayWorkQueue, ReplayWorkerResult } from '@guancecloud/ft_session_replay/src/main/ets/components/SessionReplayWorkQueue';

/** Runs collector regressions with the real ArkTS runtime as well as native components. */
export default function sessionReplayStyleUITest(): void {
  arkUIReplayCollectorUnitTest();
  describe('SessionReplayStyleUITest', () => {
    let driver: Driver;
    let uiContext: UIContext;
    const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
      .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE));

    const frame = (id: string): FrameNode => {
      const node = uiContext.getFrameNodeById(id);
      if (node === null) throw new Error(`Native style fixture is missing: ${id}`);
      return node;
    };

    const removeTestDirectory = (directory: string): void => {
      for (const name of fileIo.listFileSync(directory)) {
        const path = `${directory}/${name}`;
        if (fileIo.statSync(path).isDirectory()) removeTestDirectory(path);
        else fileIo.unlinkSync(path);
      }
      fileIo.rmdirSync(directory);
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
      uiContext = (await window.getLastWindow(ability.context)).getUIContext();
    });

    it('captures the native category Select capsule label and tinted spinner', 0, () => {
      const select = frame('session-replay-category-select');
      const data = collector.captureFrameNode(select, vp2px(1)).data as FullSnapshotData;
      const shape = data.wireframes.find((node: ReplayWireframe): boolean =>
        node.permanentId === 'session-replay-category-select');
      expect(shape?.type).assertEqual('shape');
      if (shape?.type !== 'shape') throw new Error('Select shape is missing');
      expect(shape.shapeStyle?.backgroundColor).assertEqual('#0000000C');
      expect(shape.shapeStyle?.cornerRadius).assertEqual(20);
      const label = data.wireframes.find((node: ReplayWireframe): boolean => node.type === 'text') as ReplayTextWireframe;
      expect(label.text).assertEqual('增量更新与动画');
      expect(label.textStyle.size).assertEqual(16);
      expect(label.textStyle.weight).assertEqual(500);
      expect(label.textStyle.color).assertEqual('#000000CE');
      expect(label.textPosition?.alignment?.horizontal).assertEqual('left');
      expect(label.textPosition?.alignment?.vertical).assertEqual('center');
      const arrow = data.wireframes.find((node: ReplayWireframe): boolean => node.type === 'image') as ReplayImageWireframe;
      expect(arrow.mimeType).assertEqual('svg+xml');
      expect(arrow.isEmpty).assertFalse();
      expect(arrow.width > 0 && arrow.height > 0).assertTrue();
      const svg = util.TextDecoder.create('utf-8').decodeWithStream(new util.Base64Helper().decodeSync(arrow.base64!));
      expect(svg.includes('fill="#000000"')).assertTrue();
      expect(svg.includes('fill-opacity="0.898')).assertTrue();
      // The normal multi-page collection must preserve the spinner marker too.
      const scene = collector.materializeLightSnapshot(collector.captureSceneLight(uiContext,
        ['session-replay-transition-root'], vp2px(1))).data as FullSnapshotData;
      expect(scene.wireframes.some((node: ReplayWireframe): boolean =>
        node.id === arrow.id && node.type === 'image' && node.base64 === arrow.base64)).assertTrue();
    });

    it('captures and removes the expanded native category popup above the page', 0, async () => {
      const first = collector.materializeLightSnapshot(collector.captureSceneLight(uiContext,
        ['session-replay-transition-root'], vp2px(1)));
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      const menu = await driver.findComponent(ON.id('session-replay-category-select'));
      if (menu === null) throw new Error('Category Select is unavailable');
      await menu.click();
      await driver.delayMs(600);
      const expandedLight = collector.captureSceneLight(uiContext, ['session-replay-transition-root'], vp2px(1));
      const expanded = collector.materializeLightSnapshot(expandedLight);
      const scene = expanded.data as FullSnapshotData;
      const panelNode = expandedLight.nodes.find((node): boolean => node.nodeType === 'Menu');
      const wrapperNode = expandedLight.nodes.find((node): boolean => node.nodeType === 'MenuWrapper');
      const panel = scene.wireframes.find((node): boolean => node.id === panelNode?.id);
      const wrapper = scene.wireframes.find((node): boolean => node.id === wrapperNode?.id);
      if (panel?.type !== 'shape' || wrapper?.type !== 'shape') throw new Error('Native menu surface is missing');
      expect(panel.shapeStyle?.backgroundColor).assertEqual('#FFFFFFFF');
      expect(panel.shapeStyle?.cornerRadius).assertEqual(20);
      expect(wrapper.shapeStyle?.backgroundColor).assertEqual('#00000000');
      const option = scene.wireframes.find((node: ReplayWireframe): boolean =>
        node.type === 'text' && node.text === '文字与富文本');
      expect(option !== undefined).assertTrue();
      const categories = ['增量更新与动画', '文字与富文本', '输入与编辑', '按钮与选择', '日期与时间',
        '滑动与列表', '布局与容器', '图片、绘制与媒体', '弹层与导航'];
      for (const category of categories) {
        expect(scene.wireframes.some((node: ReplayWireframe): boolean => node.type === 'text' &&
          node.text === category && (node.zIndex ?? 0) >= (option?.zIndex ?? 0))).assertTrue();
      }
      expect((option?.zIndex ?? 0) > Math.max(...(first.data as FullSnapshotData).wireframes.map(
        (node: ReplayWireframe): number => node.zIndex ?? 0))).assertTrue();
      const adds = processor.createMutationRecord(expanded)!.data as ReplayMutationData;
      expect(adds.adds.some((node): boolean => node.wireframe.id === option?.id)).assertTrue();
      const held = collector.materializeLightSnapshot(collector.captureSceneLight(uiContext,
        ['session-replay-transition-root'], vp2px(1)));
      expect((held.data as FullSnapshotData).wireframes.some((node: ReplayWireframe): boolean =>
        node.id === option?.id && node.type === 'text' && node.text === '文字与富文本')).assertTrue();
      await driver.pressBack();
      await driver.delayMs(600);
      const closed = collector.materializeLightSnapshot(collector.captureSceneLight(uiContext,
        ['session-replay-transition-root'], vp2px(1)));
      expect((closed.data as FullSnapshotData).wireframes.some((node: ReplayWireframe): boolean =>
        node.id === option?.id)).assertFalse();
      const removes = processor.createMutationRecord(closed)!.data as ReplayMutationData;
      expect(removes.removes.some((node): boolean => node.id === option?.id)).assertTrue();
    });

    it('keeps touch-pad text centered in both axes before and after a native text mutation', 0, async () => {
      const scroll = await driver.findComponent(ON.type('Scroll'));
      if (scroll === null) throw new Error('Complex component Scroll is missing');
      const pad = await scroll.scrollSearch(ON.id('session-replay-touch-pad'));
      if (pad === null) throw new Error('Native touch pad is unavailable');
      await driver.delayMs(600);
      const node = frame('session-replay-touch-pad');
      const first = collector.captureFrameNode(node, vp2px(1));
      const text = (first.data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(text.height).assertEqual(120);
      expect(text.textPosition?.alignment?.horizontal).assertEqual('center');
      expect(text.textPosition?.alignment?.vertical).assertEqual('center');
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      await pad.click();
      await driver.delayMs(200);
      const latest = collector.captureFrameNode(node, vp2px(1));
      const changed = (latest.data as FullSnapshotData).wireframes[0] as ReplayTextWireframe;
      expect(changed.text === text.text).assertFalse();
      expect(changed.textPosition?.alignment?.horizontal).assertEqual('center');
      expect(changed.textPosition?.alignment?.vertical).assertEqual('center');
      const mutation = processor.createMutationRecord(latest);
      expect(mutation !== null).assertTrue();
      const data = mutation!.data as ReplayMutationData;
      expect(data.updates.length).assertEqual(1);
      expect(data.updates[0].text).assertEqual(changed.text);
      expect(data.adds.length).assertEqual(0);
      expect(data.removes.length).assertEqual(0);
      expect(processor.createMutationRecord(latest) === null).assertTrue();
    });

    it('updates the internal Select label after selecting another native category', 0, async () => {
      const select = frame('session-replay-category-select');
      const first = collector.captureFrameNode(select, vp2px(1));
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      const menu = await driver.findComponent(ON.id('session-replay-category-select'));
      if (menu === null) throw new Error('Category Select is unavailable');
      await menu.click();
      const option = await driver.findComponent(ON.text('文字与富文本'));
      if (option === null) throw new Error('Category option is unavailable');
      await option.click();
      await driver.delayMs(600);
      const latest = collector.captureFrameNode(select, vp2px(1));
      const label = (latest.data as FullSnapshotData).wireframes.find((node: ReplayWireframe): boolean =>
        node.type === 'text') as ReplayTextWireframe;
      expect(label.text).assertEqual('文字与富文本');
      expect(label.textPosition?.alignment?.horizontal).assertEqual('left');
      expect(label.textPosition?.alignment?.vertical).assertEqual('center');
      const mutation = processor.createMutationRecord(latest);
      expect(mutation !== null).assertTrue();
      expect((mutation!.data as ReplayMutationData).updates.some((update): boolean =>
        update.type === 'text' && update.text === '文字与富文本')).assertTrue();
    });

    it('captures native inline image and symbols as nonempty PNGs without duplicate image children', 0, async () => {
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      if (scroll === null) throw new Error('Text Scroll missing');
      await scroll.scrollSearch(ON.id('session-replay-image-span'));
      await driver.delayMs(300);
      collector.invalidateComponentRasters();
      const first = collector.materializeLightSnapshot(collector.captureLightSnapshot(uiContext,
        'session-replay-image-span', vp2px(1)));
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      let light = collector.captureLightSnapshot(uiContext, 'session-replay-image-span', vp2px(1));
      for (let attempt = 0; light.nodes[0].componentRasterKey === undefined && attempt < 30; attempt++) {
        await driver.delayMs(100);
        light = collector.captureLightSnapshot(uiContext, 'session-replay-image-span', vp2px(1));
      }
      const latest = collector.materializeLightSnapshot(light);
      const frames = (latest.data as FullSnapshotData).wireframes;
      expect(frames.length).assertEqual(1);
      const bitmap = frames[0] as ReplayImageWireframe;
      expect(bitmap.type).assertEqual('image');
      expect(bitmap.isEmpty).assertFalse();
      expect(bitmap.mimeType).assertEqual('png');
      const resources = collector.takeCapturedImageResources();
      expect(resources.length).assertEqual(1);
      const source = image.createImageSource(resources[0].bytes.buffer as ArrayBuffer);
      const pixels = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      try {
        const size = pixels.getImageInfoSync().size;
        const bytes = new Uint8Array(size.width * size.height * 4);
        pixels.readPixelsToBufferSync(bytes.buffer as ArrayBuffer);
        let ink = 0;
        for (let offset = 3; offset < bytes.length; offset += 4) if (bytes[offset] > 0) ink++;
        expect(ink > 100).assertTrue();
      } finally { await pixels.release(); await source.release(); }
      expect(processor.createMutationRecord(latest) !== null).assertTrue();
      expect(processor.createMutationRecord(collector.materializeLightSnapshot(light)) === null).assertTrue();
      let symbol = collector.captureLightSnapshot(uiContext, 'session-replay-symbol-glyph', vp2px(1));
      for (let attempt = 0; symbol.nodes[0].componentRasterKey === undefined && attempt < 30; attempt++) {
        await driver.delayMs(100);
        symbol = collector.captureLightSnapshot(uiContext, 'session-replay-symbol-glyph', vp2px(1));
      }
      const icon = (collector.materializeLightSnapshot(symbol).data as FullSnapshotData).wireframes[0] as ReplayImageWireframe;
      expect(icon.type).assertEqual('image');
      expect(icon.isEmpty).assertFalse();
      const iconSource = image.createImageSource(collector.takeCapturedImageResources()[0].bytes.buffer as ArrayBuffer);
      const iconPixels = await iconSource.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      try {
        const size = iconPixels.getImageInfoSync().size;
        const bytes = new Uint8Array(size.width * size.height * 4);
        iconPixels.readPixelsToBufferSync(bytes.buffer as ArrayBuffer);
        let blue = 0;
        for (let offset = 0; offset < bytes.length; offset += 4) {
          if (bytes[offset + 3] > 128 && bytes[offset + 2] > bytes[offset] + 50) blue++;
        }
        expect(blue > 100).assertTrue();
      } finally { await iconPixels.release(); await iconSource.release(); }
      const privateCollector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig().setImagePrivacy(ImagePrivacy.MASK_NONE));
      const masked = privateCollector.materializeLightSnapshot(privateCollector.captureLightSnapshot(uiContext,
        'session-replay-image-span', vp2px(1))).data as FullSnapshotData;
      expect(masked.wireframes[0].type).assertEqual('text');
      expect(JSON.stringify(masked).includes('行内图片')).assertFalse();
      expect(privateCollector.takeCapturedImageResources().length).assertEqual(0);
    });

    it('captures a SymbolSpan-only Text even when FrameNode exposes no child frames', 0, async () => {
      let light = collector.captureLightSnapshot(uiContext, 'session-replay-symbol-span-only', vp2px(1));
      for (let attempt = 0; light.nodes[0].componentRasterKey === undefined && attempt < 30; attempt++) {
        await driver.delayMs(100);
        light = collector.captureLightSnapshot(uiContext, 'session-replay-symbol-span-only', vp2px(1));
      }
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      expect(data.wireframes.length).assertEqual(1);
      expect(data.wireframes[0].type).assertEqual('image');
      expect((data.wireframes[0] as ReplayImageWireframe).isEmpty).assertFalse();
      expect(collector.takeCapturedImageResources().length).assertEqual(1);
    });

    it('keeps visible native Marquee text moving instead of fully clipping its target position', 0, async () => {
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      if (scroll === null) throw new Error('Text samples Scroll is missing');
      await scroll.scrollSearch(ON.id('session-replay-marquee'));
      await driver.delayMs(300);
      const firstLight = collector.captureSceneLight(uiContext, ['session-replay-transition-root'], vp2px(1));
      expect(firstLight.hasActiveAnimations).assertTrue();
      const first = collector.materializeLightSnapshot(firstLight);
      const label = (first.data as FullSnapshotData).wireframes.find((node): boolean =>
        node.type === 'text' && node.text.includes('跑马灯文字采集测试')) as ReplayTextWireframe;
      expect(label !== undefined).assertTrue();
      expect(label.width - (label.clip?.left ?? 0) - (label.clip?.right ?? 0) > 0).assertTrue();
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      await driver.delayMs(500);
      const next = collector.materializeLightSnapshot(collector.captureSceneLight(uiContext,
        ['session-replay-transition-root'], vp2px(1)));
      const moving = (next.data as FullSnapshotData).wireframes.find((node): boolean => node.id === label.id)!;
      expect(Math.abs(moving.x - label.x) > 1).assertTrue();
      expect(moving.width - (moving.clip?.left ?? 0) - (moving.clip?.right ?? 0) > 0).assertTrue();
      expect((processor.createMutationRecord(next)!.data as ReplayMutationData).updates.some((node): boolean =>
        node.id === label.id && node.x !== undefined)).assertTrue();
    });

    it('captures native Hyperlink and HTML RichText typography and separate paragraphs', 0, () => {
      const light = collector.captureSceneLight(uiContext, ['session-replay-transition-root'], vp2px(1));
      const data = collector.materializeLightSnapshot(light).data as FullSnapshotData;
      const link = data.wireframes.find((node): boolean => node.type === 'text' && node.text === '观测云链接') as ReplayTextWireframe;
      expect(link !== undefined).assertTrue();
      expect(link.textStyle.color).assertEqual('#2563EBFF');
      expect(link.textStyle.size).assertEqual(16);
      const rich = collector.captureFrameNode(frame('session-replay-rich-text'), vp2px(1)).data as FullSnapshotData;
      const runs = rich.wireframes.filter((node): boolean => node.type === 'text') as Array<ReplayTextWireframe>;
      expect(runs.map((node): string => node.text).join('')).assertEqual('HTML 富文本段落与颜色采集测试');
      expect(runs.every((node): boolean => node.textStyle.color === '#2563EBFF' && node.textStyle.size === 18)).assertTrue();
      expect(runs[0].textStyle.weight).assertEqual(700);
      expect(runs[runs.length - 1].textStyle.weight).assertEqual(400);
      expect(runs[runs.length - 1].y > runs[0].y + 18).assertTrue();
      expect(JSON.stringify(rich).includes('<div')).assertFalse();
    });

    it('lays out rich inline styles in the real background Replay Worker', 0, async () => {
      const light = collector.captureFrameNodeLight(frame('session-replay-rich-text'), vp2px(1));
      const attrs: Record<string, Object> = { 'content': '<b>A</b><i>B</i>' };
      light.nodes[0].inspectorInfo = attrs;
      const queue = new SessionReplayWorkQueue({ filesDir: '', maxNodes: 1500, maxBytes: 1024 * 1024,
        maxRecordsPerSegment: 100, fullSnapshotIntervalMs: 30000, errorSampleWindowMs: 30000,
        textPrivacy: TextAndInputPrivacy.MASK_SENSITIVE_INPUTS, imagePrivacy: ImagePrivacy.MASK_NONE });
      try {
        const result = await new Promise<ReplayWorkerResult>((resolve, reject): void => {
          queue.enqueue('full', light, { context: { applicationId: 'style-test', sessionId: 'style-session', viewId: 'style-view' },
            viewport: null, previousViewport: null, lastFullSnapshotAt: 0, storeKind: 'none' },
            (result: ReplayWorkerResult | null, error: string): void => {
              if (result === null) reject(new Error(error)); else resolve(result);
            });
        });
        const snapshot = result.records.find((record): boolean => record.type === 10)!.data as FullSnapshotData;
        const a = snapshot.wireframes.find((node): boolean => node.type === 'text' && node.text === 'A') as ReplayTextWireframe;
        const b = snapshot.wireframes.find((node): boolean => node.type === 'text' && node.text === 'B') as ReplayTextWireframe;
        expect(a.textStyle.weight).assertEqual(700);
        expect(b.textStyle.style).assertEqual('italic');
        expect(b.x > a.x).assertTrue();
        expect(Math.abs(b.y - a.y) < 10).assertTrue();
      } finally {
        await queue.drain();
        queue.close();
      }
    });

    it('automatically records Marquee mutations beyond the motion tail without user gestures', 0, async () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setSnapshotIntervalMs(64).setMotionQuietPeriodMs(100)
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
      const context: FTSessionReplayRUMContext = { applicationId: 'style-test', sessionId: 'marquee-auto-session',
        viewId: 'marquee-auto-view', viewName: 'Marquee', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      try {
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-marquee', vp2px(1));
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(1200);
        await recorder.drainWrites();
        const replayContext: SessionReplayContext = { applicationId: context.applicationId,
          sessionId: context.sessionId, viewId: context.viewId };
        const records = recorder.getRecordedRecords(replayContext);
        const first = records.find((record): boolean => record.type === ReplayRecordType.FULL_SNAPSHOT)!.data as FullSnapshotData;
        const label = first.wireframes.find((node): boolean => node.type === 'text' && node.text.includes('跑马灯'))!;
        const late = records.filter((record): boolean => record.timestamp > context.timestamp + 500 &&
          record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT).map((record): ReplayMutationData => record.data as ReplayMutationData);
        const offsets = late.map((mutation): number => mutation.updates.find((node): boolean =>
          node.id === label.id && node.x !== undefined)?.x ?? label.x);
        expect(offsets.length >= 4).assertTrue();
        expect(new Set(offsets).size >= 4).assertTrue();
      } finally {
        recorder.stop();
        await recorder.drainWrites();
      }
    });

    it('forwards asynchronously packed component images through the automatic Recorder Worker queue', 0, async () => {
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      if (scroll === null) throw new Error('Text Scroll missing');
      await scroll.scrollSearch(ON.id('session-replay-image-span'));
      const directory = `${AbilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir}/replay-inline-${Date.now()}`;
      fileIo.mkdirSync(directory);
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig()
        .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS).setImagePrivacy(ImagePrivacy.MASK_NONE),
        new SessionReplaySegmentStore(directory, 1024 * 1024, 100));
      const context: FTSessionReplayRUMContext = { applicationId: 'style-test', sessionId: 'inline-auto-session',
        viewId: 'inline-auto-view', viewName: 'Inline media', viewReferrer: '', linkContext: {}, timestamp: Date.now() };
      try {
        recorder.start();
        recorder.registerRoot(uiContext, 'session-replay-image-span', vp2px(1));
        expect(recorder.onViewStarted(context)).assertTrue();
        await driver.delayMs(1600);
        await recorder.drainWrites();
        const replayContext: SessionReplayContext = { applicationId: context.applicationId,
          sessionId: context.sessionId, viewId: context.viewId };
        const records = recorder.getRecordedRecords(replayContext);
        const images: Array<ReplayImageWireframe> = [];
        for (const record of records) {
          const frames = record.type === ReplayRecordType.FULL_SNAPSHOT ? (record.data as FullSnapshotData).wireframes :
            record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT ? (record.data as ReplayMutationData).adds
              .map((add): ReplayWireframe => add.wireframe) : [];
          for (const node of frames) if (node.type === 'image') images.push(node as ReplayImageWireframe);
        }
        const bitmap = images.find((node): boolean => node.permanentId === 'session-replay-image-span' && !node.isEmpty);
        expect(bitmap !== undefined).assertTrue();
        expect(bitmap!.resourceId !== undefined).assertTrue();
        expect(bitmap!.mimeType).assertEqual('png');
        const resources = new SessionReplayResourceStore(directory, 1024 * 1024);
        const asset = resources.list().find((resource): boolean => resource.fileName === bitmap!.resourceId);
        expect(asset !== undefined).assertTrue();
        expect(resources.read(asset!)!.byteLength > 100).assertTrue();
      } finally {
        recorder.stop();
        await recorder.drainWrites();
        removeTestDirectory(directory);
      }
    });
  });
}
