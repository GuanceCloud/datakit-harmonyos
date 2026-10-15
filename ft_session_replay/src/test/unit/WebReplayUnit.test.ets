import { describe, expect, it } from '@ohos/hypium';
import { FTSessionReplayBridgeRegistry, FTWebViewHandler } from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector, ArkUIReplayLightNode, ArkUIReplayLightSnapshot } from '../../main/ets/components/ArkUIReplayCollector';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { FTSessionReplayRecorder } from '../../main/ets/components/FTSessionReplayRecorder';
import { FTSessionReplayConfig } from '../../main/ets/components/FTSessionReplayConfig';
import { createAndroidReplayMobileSegment, FullSnapshotData, ReplayMutationData, ReplayRecordType,
  ReplayWebViewWireframe, SessionReplayContext, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';
import { createSessionReplayUploadFields } from '../../main/ets/components/SessionReplayUploader';
import { SessionReplayStoredSegment } from '../../main/ets/components/SessionReplaySegmentStore';

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
    it('marks real rrweb full snapshots as checkpoints in both segment and multipart metadata', 0, () => {
      const context: SessionReplayContext = { applicationId: 'app', sessionId: 's', viewId: 'browser-view' };
      const data: Record<string, Object> = { 'node': 1 };
      const browserFull: SessionReplayRecord = {
        timestamp: 1700000000000, type: 2 as ReplayRecordType, slotId: 'slot', data
      };
      const segment: SessionReplayStoredSegment = {
        version: 1, id: 'browser-unit', createdAt: browserFull.timestamp, context, records: [browserFull]
      };
      expect(createAndroidReplayMobileSegment(context, segment.records).has_full_snapshot).assertTrue();
      expect(createSessionReplayUploadFields(segment, 'test', '1').fields.get('has_full_snapshot')).assertEqual('true');
      browserFull.type = 3 as ReplayRecordType;
      expect(createAndroidReplayMobileSegment(context, segment.records).has_full_snapshot).assertFalse();
      expect(createSessionReplayUploadFields(segment, 'test', '1').fields.get('has_full_snapshot')).assertEqual('false');
    });

    it('invalidates the old JS receiver generation after a controller is detached', 0, () => {
      const handler = new FTWebViewHandler();
      const originalSlot = handler.getSessionReplaySlotId();
      handler.getMessageReceiver();
      expect(handler.isCurrentProxy(originalSlot)).assertTrue();
      handler.clearWebController();
      expect(handler.isCurrentProxy(originalSlot)).assertFalse();
      expect(handler.getSessionReplaySlotId() !== originalSlot).assertTrue();
    });

    it('replaces a Web container when the component receives a new slot', 0, () => {
      const collector = new ArkUIReplayCollector();
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(collector.materializeLightSnapshot(webSnapshot('old-slot', 0)));
      const mutation = processor.createMutationRecord(
        collector.materializeLightSnapshot(webSnapshot('new-slot', 0)))!.data as ReplayMutationData;
      expect(mutation.removes.length).assertEqual(1);
      expect(mutation.adds.length).assertEqual(1);
      expect((mutation.adds[0].wireframe as ReplayWebViewWireframe).slotId).assertEqual('new-slot');
    });

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
