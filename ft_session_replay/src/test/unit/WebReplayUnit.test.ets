import { describe, expect, it } from '@ohos/hypium';
import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector, ArkUIReplayLightNode, ArkUIReplayLightSnapshot } from '../../main/ets/components/ArkUIReplayCollector';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { FTSessionReplayRecorder } from '../../main/ets/components/FTSessionReplayRecorder';
import { FTSessionReplayConfig } from '../../main/ets/components/FTSessionReplayConfig';
import { FullSnapshotData, ReplayMutationData, ReplayWebViewWireframe } from '../../main/ets/components/SessionReplayProtocol';

function webSnapshot(slotId: string, x: number, opacity: number = 1): ArkUIReplayLightSnapshot {
  const inspector: Record<string, Object> = { 'content': '<p>must not become native text</p>' };
  const node: ArkUIReplayLightNode = {
    id: 10, x, y: 40, width: 300, height: 200, componentId: 'test-web', nodeType: 'Web',
    inspectorInfo: inspector, shouldCaptureAsText: false,
    isRoot: true, usedTransformedPosition: false, webViewSlotId: slotId, opacity
  };
  return {
    timestamp: 1700000000000 + x, vpToPxScale: 1,
    nodes: [node]
  };
}

export default function webReplayUnitTest() {
  describe('WebReplayUnit', () => {
    it('gates latest slots, background, unbound identities and the exact two-second tail', 0, () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig().setSampleRate(1));
      recorder.start();
      const registry = FTSessionReplayBridgeRegistry;
      registry.setWebReplayAppForeground(true);
      registry.registerWebReplaySlot('lifecycle-a', 'lifecycle-web-a');
      registry.registerWebReplaySlot('lifecycle-b', 'lifecycle-web-b');
      expect(registry.acceptsWebReplayData('lifecycle-a', 'app', 's', 1000)).assertFalse();
      registry.observeWebReplaySlots('app', 's', 'native', ['lifecycle-a'], 1000);
      expect(registry.acceptsWebReplayData('lifecycle-a', 'app', 'other', 1000)).assertFalse();
      registry.setWebReplayAppForeground(false);
      expect(registry.acceptsWebReplayData('lifecycle-a', 'app', 's', 1100)).assertFalse();
      registry.setWebReplayAppForeground(true);
      registry.observeWebReplaySlots('app', 's', 'native', ['lifecycle-a', 'lifecycle-b'], 1200);
      expect(registry.isWebReplaySlotActive('lifecycle-a')).assertFalse();
      expect(registry.isWebReplaySlotActive('lifecycle-b')).assertTrue();
      registry.observeWebReplaySlots('app', 's', 'native', ['lifecycle-a', 'lifecycle-b'], 1300);
      expect(registry.acceptsWebReplayData('lifecycle-a', 'app', 's', 3199)).assertTrue();
      expect(registry.acceptsWebReplayData('lifecycle-a', 'app', 's', 3200)).assertFalse();
      registry.observeWebReplaySlots('app', 's', 'returned-native', ['lifecycle-a'], 3300);
      expect(registry.isWebReplaySlotActive('lifecycle-a')).assertTrue();
      expect(registry.getWebReplaySlotBinding('lifecycle-a')?.viewId).assertEqual('returned-native');
      registry.unregisterWebReplaySlot('lifecycle-a');
      registry.unregisterWebReplaySlot('lifecycle-b');
      recorder.stop();
    });

    it('binds native containers, rejects duplicate component IDs and releases old views', 0, () => {
      const registry = FTSessionReplayBridgeRegistry;
      expect(registry.registerWebReplaySlot('slot-unit-a', 'web-unit-a')).assertTrue();
      expect(registry.registerWebReplaySlot('slot-unit-b', 'web-unit-a')).assertFalse();
      registry.observeWebReplaySlots('app', 'session', 'native-a', ['slot-unit-a'], 1000);
      expect(registry.getWebReplaySlotBinding('slot-unit-a')?.viewId).assertEqual('native-a');
      expect(registry.getLatestWebReplaySlotId()).assertEqual('slot-unit-a');
      registry.observeWebReplaySlots('app', 'session', 'native-b', ['slot-unit-a'], 1100);
      expect(registry.getWebReplaySlotBinding('slot-unit-a')?.viewId).assertEqual('native-b');
      registry.observeWebReplaySlots('app', 'session', 'native-b', [], 1200);
      expect(registry.getWebReplaySlotBinding('slot-unit-a')?.inactiveAt).assertEqual(1200);
      registry.unregisterWebReplaySlot('slot-unit-a');
      expect(registry.getWebReplaySlotBinding('slot-unit-a')).assertNull();
    });

    it('keeps Browser DOM separate and mutates the matching native Web rectangle', 0, () => {
      const collector = new ArkUIReplayCollector();
      const first = collector.materializeLightSnapshot(webSnapshot('web-slot', 0));
      const frames = (first.data as FullSnapshotData).wireframes;
      expect(frames.length).assertEqual(1);
      const web = frames[0] as ReplayWebViewWireframe;
      expect(web.type).assertEqual('webview');
      expect(web.slotId).assertEqual('web-slot');
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(first);
      const moved = collector.materializeLightSnapshot(webSnapshot('web-slot', 20, 0));
      const mutation = processor.createMutationRecord(moved);
      expect(mutation !== null).assertTrue();
      const update = (mutation!.data as ReplayMutationData).updates[0];
      expect(update.x).assertEqual(20);
      expect(update.isVisible).assertFalse();
      const shadow = new ReplaySnapshotProcessor();
      shadow.setFullSnapshotBaseline(first);
      shadow.applyCommittedRecords([mutation!]);
      expect(shadow.createMutationRecord(moved)).assertNull();
    });
  });
}
