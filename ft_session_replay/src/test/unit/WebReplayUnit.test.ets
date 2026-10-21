import { describe, expect, it } from '@ohos/hypium';
import { FTSessionReplayBridgeRegistry, FTSessionReplayWebDataContext, FTWebViewHandler,
  WebReplaySlotObservation } from '@guancecloud/ft_sdk';
import { ArkUIReplayCollector, ArkUIReplayLightNode, ArkUIReplayLightSnapshot } from '../../main/ets/components/ArkUIReplayCollector';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { FTSessionReplayRecorder } from '../../main/ets/components/FTSessionReplayRecorder';
import { FTSessionReplayConfig } from '../../main/ets/components/FTSessionReplayConfig';
import { createHarmonyReplayMobileSegment, FullSnapshotData, ReplayMutationData, ReplayRecordType,
  ReplayWebViewWireframe, SessionReplayContext, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';
import { createSessionReplayUploadFields } from '../../main/ets/components/SessionReplayUploader';
import { SessionReplayStoredSegment } from '../../main/ets/components/SessionReplaySegmentStore';

function webSnapshot(slotId: string, x: number, opacity: number = 1, id: number = 10): ArkUIReplayLightSnapshot {
  const inspector: Record<string, Object> = { 'content': '<p>must not become native text</p>' };
  const node: ArkUIReplayLightNode = {
    id, x, y: 40, width: 300, height: 200, componentId: 'test-web', nodeType: 'Web',
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
      expect(createHarmonyReplayMobileSegment(context, segment.records).has_full_snapshot).assertTrue();
      expect(createSessionReplayUploadFields(segment, 'test', '1').fields.get('has_full_snapshot')).assertEqual('true');
      browserFull.type = 3 as ReplayRecordType;
      expect(createHarmonyReplayMobileSegment(context, segment.records).has_full_snapshot).assertFalse();
      expect(createSessionReplayUploadFields(segment, 'test', '1').fields.get('has_full_snapshot')).assertEqual('false');
    });

    it('invalidates the old JS receiver generation after a controller is detached', 0, () => {
      const handler = new FTWebViewHandler();
      const generation = handler.getProxyGeneration();
      handler.getMessageReceiver();
      expect(handler.getSessionReplaySlotId()).assertEqual('');
      expect(handler.isCurrentProxy(generation)).assertTrue();
      handler.clearWebController();
      expect(handler.isCurrentProxy(generation)).assertFalse();
      expect(handler.getSessionReplaySlotId()).assertEqual('');
    });

    it('replaces a Web container when its native node ID changes', 0, () => {
      const collector = new ArkUIReplayCollector();
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(collector.materializeLightSnapshot(webSnapshot('old-slot', 0)));
      const mutation = processor.createMutationRecord(
        collector.materializeLightSnapshot(webSnapshot('new-slot', 0, 1, 20)))!.data as ReplayMutationData;
      expect(mutation.removes.length).assertEqual(1);
      expect(mutation.adds.length).assertEqual(1);
      expect((mutation.adds[0].wireframe as ReplayWebViewWireframe).slotId).assertEqual('20');
    });

    it('gates latest slots, background, unbound identities and the exact two-second tail', 0, () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig().setSampleRate(1));
      recorder.start();
      const registry = FTSessionReplayBridgeRegistry;
      registry.setWebReplayAppForeground(true);
      registry.registerWebReplayComponent('lifecycle-web-a');
      registry.registerWebReplayComponent('lifecycle-web-b');
      const a: WebReplaySlotObservation = { componentId: 'lifecycle-web-a', slotId: '1001' };
      const b: WebReplaySlotObservation = { componentId: 'lifecycle-web-b', slotId: '1002' };
      expect(registry.acceptsWebReplayData(a.slotId, 'app', 's', 1000)).assertFalse();
      registry.observeWebReplaySlots('app', 's', 'native', [a], 1000);
      expect(registry.acceptsWebReplayData(a.slotId, 'app', 'other', 1000)).assertFalse();
      registry.setWebReplayAppForeground(false);
      expect(registry.acceptsWebReplayData(a.slotId, 'app', 's', 1100)).assertFalse();
      registry.setWebReplayAppForeground(true);
      registry.observeWebReplaySlots('app', 's', 'native', [a, b], 1200);
      expect(registry.isWebReplaySlotActive(a.slotId)).assertFalse();
      expect(registry.isWebReplaySlotActive(b.slotId)).assertTrue();
      registry.observeWebReplaySlots('app', 's', 'native', [a, b], 1300);
      expect(registry.acceptsWebReplayData(a.slotId, 'app', 's', 3199)).assertTrue();
      expect(registry.acceptsWebReplayData(a.slotId, 'app', 's', 3200)).assertFalse();
      registry.observeWebReplaySlots('app', 's', 'returned-native', [a], 3300);
      expect(registry.isWebReplaySlotActive(a.slotId)).assertTrue();
      expect(registry.getWebReplaySlotBinding(a.slotId)?.viewId).assertEqual('returned-native');
      registry.unregisterWebReplayComponent(a.componentId);
      registry.unregisterWebReplayComponent(b.componentId);
      recorder.stop();
    });

    it('binds native containers, rejects duplicate component IDs and releases old views', 0, () => {
      const registry = FTSessionReplayBridgeRegistry;
      expect(registry.registerWebReplayComponent('web-unit-a')).assertTrue();
      expect(registry.registerWebReplayComponent('web-unit-a')).assertFalse();
      expect(registry.getWebReplaySlotId('web-unit-a')).assertEqual('');
      const visible: Array<WebReplaySlotObservation> = [{ componentId: 'web-unit-a', slotId: '1000000126' }];
      registry.observeWebReplaySlots('app', 'session', 'native-a', visible, 1000);
      expect(registry.getWebReplaySlotBinding('1000000126')?.viewId).assertEqual('native-a');
      expect(registry.getLatestWebReplaySlotId()).assertEqual('1000000126');
      registry.observeWebReplaySlots('app', 'session', 'native-b', visible, 1100);
      expect(registry.getWebReplaySlotBinding('1000000126')?.viewId).assertEqual('native-b');
      registry.observeWebReplaySlots('app', 'session', 'native-b', [], 1200);
      expect(registry.getWebReplaySlotBinding('1000000126')?.inactiveAt).assertEqual(1200);
      registry.unregisterWebReplayComponent('web-unit-a');
      expect(registry.getWebReplaySlotBinding('1000000126')).assertNull();
    });

    it('keeps Browser DOM separate and mutates the matching native Web rectangle', 0, () => {
      const collector = new ArkUIReplayCollector();
      const first = collector.materializeLightSnapshot(webSnapshot('web-slot', 0));
      const frames = (first.data as FullSnapshotData).wireframes;
      expect(frames.length).assertEqual(1);
      const web = frames[0] as ReplayWebViewWireframe;
      expect(web.type).assertEqual('webview');
      expect(web.slotId).assertEqual(String(web.id));
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

    it('normalizes Browser Meta and resize heights to the native Web wireframe', 0, () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig().setSampleRate(1));
      const registry = FTSessionReplayBridgeRegistry;
      const componentId = 'viewport-normalization-web';
      const slotId = '1000000320';
      const now = Date.now();
      const context: SessionReplayContext = { applicationId: 'viewport-app', sessionId: 'viewport-session',
        viewId: 'browser-view' };
      recorder.start();
      registry.setWebReplayAppForeground(true);
      registry.registerWebReplayComponent(componentId);
      try {
        registry.observeWebReplaySlots(context.applicationId, context.sessionId, 'native-view',
          [{ componentId, slotId, width: 320, height: 560 }], now);
        const meta: FTSessionReplayWebDataContext = {
          applicationId: context.applicationId, sessionId: context.sessionId, viewId: context.viewId,
          slotId, linkContext: {}, timestamp: now,
          payload: `{"timestamp":${now},"type":4,"data":{"width":320,"height":480,"href":"https://example.test"}}`
        };
        const resize: FTSessionReplayWebDataContext = {
          applicationId: context.applicationId, sessionId: context.sessionId, viewId: context.viewId,
          slotId, linkContext: {}, timestamp: now + 1,
          payload: `{"timestamp":${now + 1},"type":3,"data":{"source":4,"width":320,"height":500}}`
        };
        expect(recorder.onWebReplayData(meta)).assertTrue();
        expect(recorder.onWebReplayData(resize)).assertTrue();
        recorder.flushWebReplayData();
        const records = recorder.getRecordedRecords(context);
        expect(records.length).assertEqual(2);
        const metaViewport = records[0].data as Record<string, string | number>;
        const resizedViewport = records[1].data as Record<string, number>;
        expect(metaViewport.height as number).assertEqual(560);
        expect(resizedViewport.source).assertEqual(4);
        expect(resizedViewport.height).assertEqual(560);
      } finally {
        registry.unregisterWebReplayComponent(componentId);
        recorder.stop();
      }
    });

    it('persists Browser records with the native wireframe ID and rejects retired IDs', 0, () => {
      const collector = new ArkUIReplayCollector();
      const first = collector.materializeLightSnapshot(webSnapshot('ignored-alias', 0, 1, 1000000126));
      const web = (first.data as FullSnapshotData).wireframes[0] as ReplayWebViewWireframe;
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig().setSampleRate(1));
      const registry = FTSessionReplayBridgeRegistry;
      recorder.start();
      registry.setWebReplayAppForeground(true);
      registry.registerWebReplayComponent('test-web');
      try {
        const now = Date.now();
        const context: FTSessionReplayWebDataContext = { applicationId: 'app', sessionId: 's', viewId: 'browser-view',
          slotId: String(web.id), linkContext: {}, timestamp: now,
          payload: `{"timestamp":${now},"type":2,"slotId":"untrusted","data":{"node":{"id":1}}}` };
        const replayContext: SessionReplayContext = {
          applicationId: context.applicationId, sessionId: context.sessionId, viewId: context.viewId
        };
        registry.observeWebReplaySlots('app', 's', 'native',
          [{ componentId: 'test-web', slotId: String(web.id) }], now);
        expect(recorder.onWebReplayData(context)).assertTrue();
        // Re-observation seals the old batch before accepting the new native ID.
        registry.observeWebReplaySlots('app', 's', 'native',
          [{ componentId: 'test-web', slotId: '1000000127' }], now + 1);
        expect(recorder.onWebReplayData(context)).assertFalse();
        const records = recorder.getRecordedRecords(replayContext);
        expect(records.length).assertEqual(1);
        expect(records[0].slotId).assertEqual(String(web.id));
        expect(records[0].slotId).assertEqual(web.slotId);
        context.slotId = '1000000127';
        expect(recorder.onWebReplayData(context)).assertTrue();
        recorder.flushWebReplayData();
        expect(recorder.getRecordedRecords(replayContext)[1].slotId).assertEqual('1000000127');
      } finally {
        registry.unregisterWebReplayComponent('test-web');
        recorder.stop();
      }
    });
  });
}
