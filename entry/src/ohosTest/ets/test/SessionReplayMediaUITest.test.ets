import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import window from '@ohos.window';
import { UIContext } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ArkUIReplayCollector, FTSessionReplayConfig, FullSnapshotData, ImagePrivacy,
  ReplayImageWireframe, TextAndInputPrivacy
} from '@guancecloud/ft_session_replay';
import { FTSDK } from '@guancecloud/ft_sdk';

export default function sessionReplayMediaUITest(): void {
  describe('SessionReplayMediaUITest', () => {
    let driver: Driver;
    let ui: UIContext;
    let directory: string;
    const collector = new ArkUIReplayCollector(1500, new FTSessionReplayConfig()
      .setImagePrivacy(ImagePrivacy.MASK_NONE).setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS));
    const click = async (id: string): Promise<void> => {
      const component = await driver.findComponent(ON.id(id));
      if (component === null) throw new Error(`Missing media control: ${id}`);
      await component.click(); await driver.delayMs(250);
    };
    const show = async (id: string): Promise<void> => {
      const primitive = ['rect', 'circle', 'ellipse', 'polygon', 'polyline', 'path', 'line'];
      const target = primitive.some((type): boolean => id === `session-replay-${type}`) ? 'session-replay-shape' : id;
      const scroll = await driver.findComponent(ON.id('session-replay-components-scroll'));
      if (scroll === null || await scroll.scrollSearch(ON.id(target)) === null) throw new Error(`Missing media fixture: ${id}`);
      await driver.delayMs(250);
    };
    const record = async (id: string, name: string, previous: string = ''): Promise<string> => {
      await show(id);
      let frame: ReplayImageWireframe | undefined;
      let bytes: Uint8Array | undefined;
      for (let attempt = 0; attempt < 50; attempt++) {
        const snapshot = collector.captureLightSnapshot(ui, id, vp2px(1));
        const data = collector.materializeLightSnapshot(snapshot).data as FullSnapshotData;
        frame = data.wireframes.find((node): boolean => node.permanentId === id) as ReplayImageWireframe;
        const resources = collector.takeCapturedImageResources();
        bytes = resources.find((resource): boolean => resource.token === frame?.resourceId)?.bytes;
        if (frame?.type === 'image' && frame.isEmpty === false && bytes !== undefined) {
          const file = fs.openSync(`${directory}/${name}.${frame.mimeType === 'jpeg' ? 'jpg' : 'png'}`,
            fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
          try { fs.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
          finally { fs.closeSync(file); }
          // Compare content without depending on native resource token identities.
          let hash = 2166136261;
          for (const byte of bytes) hash = Math.imul(hash ^ byte, 16777619);
          const result = `${bytes.length}:${hash}`;
          if (result !== previous) return result;
        }
        await driver.delayMs(200);
      }
      throw new Error(`Media resource was not captured: ${id}; ${JSON.stringify(frame)}`);
    };
    beforeAll(async () => {
      driver = Driver.create();
      const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
      await delegator.startAbility({ bundleName: AbilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility', moduleName: 'entry' });
      let home = await driver.findComponent(ON.text('Session Replay Demo'));
      for (let attempt = 0; home === null && attempt < 30; attempt++) {
        await driver.delayMs(200); home = await driver.findComponent(ON.text('Session Replay Demo'));
      }
      if (home === null) throw new Error('Demo home is unavailable.');
      FTSDK.setAutoSync(false);
      await home.click(); await driver.delayMs(600);
      await click('session-replay-transition-button'); await driver.delayMs(600);
      const nativeWindow = await window.getLastWindow((await delegator.getCurrentTopAbility()).context);
      ui = nativeWindow.getUIContext();
      directory = `${delegator.getAppContext().filesDir}/replay-media`;
      if (!fs.accessSync(directory)) fs.mkdirSync(directory);
      await click('session-replay-category-select');
      const option = await driver.findComponent(ON.text('图片、绘制与媒体'));
      if (option === null) throw new Error('Media category is unavailable.');
      await option.click(); await driver.delayMs(500);
    });
    it('extracts Image, QRCode and Shape resources without registerImageAsset', 0, async () => {
      await record('session-replay-component-image', 'image-a');
      const before = await record('session-replay-qrcode', 'qrcode-a');
      await show('session-replay-image-update'); await click('session-replay-image-update');
      await record('session-replay-component-image-alternate', 'image-b');
      const after = await record('session-replay-qrcode', 'qrcode-b', before);
      expect(before === after).assertFalse();
      await record('session-replay-shape', 'shape');
      for (const type of ['rect', 'circle', 'ellipse', 'polygon', 'polyline', 'path', 'line']) {
        await record(`session-replay-${type}`, type);
      }
    });
    it('captures ImageAnimator current frames and Canvas paint changes', 0, async () => {
      await show('session-replay-image-animation-toggle'); await click('session-replay-image-animation-toggle');
      const hashes: Set<string> = new Set();
      for (let attempt = 0; attempt < 8; attempt++) {
        hashes.add(await record('session-replay-image-animator', `animation-${attempt}`));
        await driver.delayMs(220);
      }
      expect(hashes.size > 1).assertTrue();
      await show('session-replay-image-animation-toggle'); await click('session-replay-image-animation-toggle');
      const before = await record('session-replay-canvas', 'canvas-a');
      await show('session-replay-canvas-update'); await click('session-replay-canvas-update');
      const after = await record('session-replay-canvas', 'canvas-b', before);
      expect(before === after).assertFalse();
    });
    it('captures Video poster and API20 network keyframes with scalar playback state', 0, async () => {
      collector.registerVideoSource('session-replay-video',
        'https://sf1-cdn-tos.huoshanstatic.com/obj/media-fe/xgplayer_doc_video/mp4/xgplayer-demo-360p.mp4', $r('app.media.startIcon'));
      const poster = await record('session-replay-video', 'video-poster');
      collector.updateVideoState('session-replay-video', { currentTime: 5, duration: 30, playing: true });
      await driver.delayMs(1200);
      const keyframe = await record('session-replay-video', 'video-keyframe', poster);
      expect(poster === keyframe).assertFalse();
      collector.updateVideoState('session-replay-video', { currentTime: 9, playing: false });
      const data = collector.materializeLightSnapshot(collector.captureLightSnapshot(ui, 'session-replay-video', vp2px(1))).data as FullSnapshotData;
      expect(data.wireframes.some((frame): boolean => frame.type === 'text' && frame.text.includes('Paused') && frame.text.includes('0:09'))).assertTrue();
      collector.unregisterVideoSource('session-replay-video');
      collector.clearScene();
    });
  });
}
