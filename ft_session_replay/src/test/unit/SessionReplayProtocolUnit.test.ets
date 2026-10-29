import { describe, expect, it } from '@ohos/hypium';
import { FTSessionReplayBridgeRegistry, FTSessionReplayWebDataContext } from '@guancecloud/ft_sdk';
import {
  HARMONY_REPLAY_ENDPOINTS,
  createHarmonyReplayMobileSegment,
  createReplayEnvelope,
  FullSnapshotData,
  ReplayImageWireframe,
  ReplayMetaData,
  ReplayPlaceholderWireframe,
  ReplayRecordType,
  ReplayMutationData,
  ReplayMutationRemove,
  ReplayShapeWireframe,
  ReplayTextWireframe,
  ReplayViewportData,
  ReplayWireframe,
  serializeReplayEnvelope,
  SessionReplayContext,
  SessionReplayGlobalContext,
  SessionReplayRecord
} from '../../main/ets/components/SessionReplayProtocol';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from '../../main/ets/components/SessionReplaySampler';
import { FTSessionReplay } from '../../main/ets/components/FTSessionReplay';
import { FTSessionReplayRecorder } from '../../main/ets/components/FTSessionReplayRecorder';
import {
  createHarmonyReplayUploadUrl,
  createSessionReplayUploadFields,
  isReplayUploadEndpointAvailable,
  isValidReplayHttpUrl,
  isRetryableReplayUploadStatus,
  REPLAY_MAX_BATCHES_PER_UPLOAD_JOB,
  shouldDiscardReplayUploadStatus
} from '../../main/ets/components/SessionReplayUploader';
import {
  createHarmonyReplayResourceUrl,
  isRetryableReplayResourceFailure
} from '../../main/ets/components/SessionReplayResourceUploader';
import { SessionReplayStoredSegment } from '../../main/ets/components/SessionReplaySegmentStore';

function fullSnapshotRecord(timestamp: number, wireframes: Array<ReplayWireframe>): SessionReplayRecord {
  const data: FullSnapshotData = { wireframes };
  return { timestamp, type: ReplayRecordType.FULL_SNAPSHOT, data };
}

function orderedPlaceholders(ids: Array<number>): Array<ReplayWireframe> {
  return ids.map((id: number): ReplayPlaceholderWireframe => {
    return { id, x: 0, y: 0, width: 100, height: 40, type: 'placeholder', label: `node-${id}` };
  });
}

/** Reference application for the order/placeholder fixtures below. */
function applyPlaceholderMutation(
  previous: Array<ReplayWireframe>, mutation: ReplayMutationData
): Array<ReplayWireframe> {
  const result = (JSON.parse(JSON.stringify(previous)) as Array<ReplayWireframe>)
    .filter((node: ReplayWireframe): boolean => !mutation.removes.some((item: ReplayMutationRemove): boolean => item.id === node.id));
  for (const add of mutation.adds) {
    const insertionIndex = add.previousId === undefined ? 0 :
      result.findIndex((node: ReplayWireframe): boolean => node.id === add.previousId) + 1;
    expect(add.previousId === undefined || insertionIndex > 0).assertTrue();
    result.splice(insertionIndex, 0, add.wireframe);
  }
  for (const update of mutation.updates) {
    const node = result.find((candidate: ReplayWireframe): boolean => candidate.id === update.id)!;
    if (update.x !== undefined) node.x = update.x;
    if (update.y !== undefined) node.y = update.y;
    if (update.width !== undefined) node.width = update.width;
    if (update.height !== undefined) node.height = update.height;
    if (node.type === 'placeholder' && update.label !== undefined) node.label = update.label;
  }
  return result;
}

export default function sessionReplayProtocolUnitTest() {
  describe('SessionReplayProtocolUnit', () => {
    it('serializes the HarmonyOS enriched-record envelope', 0, () => {
      const root: ReplayPlaceholderWireframe = {
        id: 1000000001, x: 0, y: 0, width: 1080, height: 2400,
        type: 'placeholder', label: 'ArkUI:Column', permanentId: 'session-replay-poc-root'
      };
      const records: Array<SessionReplayRecord> = [fullSnapshotRecord(1700000000000, [root])];
      const globalContext: SessionReplayGlobalContext = {};
      globalContext['wgt_id'] = 'demo';
      globalContext['release'] = 1;
      const context: SessionReplayContext = {
        applicationId: 'harmony-compatible-app',
        sessionId: 'session-id',
        viewId: 'view-id',
        globalContext
      };

      const envelope = createReplayEnvelope(context, records);
      expect(envelope.application_id).assertEqual('harmony-compatible-app');
      expect(envelope.session_id).assertEqual('session-id');
      expect(envelope.view_id).assertEqual('view-id');
      expect(envelope.records[0].type).assertEqual(10);
      expect(envelope.records[0].data !== undefined).assertTrue();
      const payload = serializeReplayEnvelope(context, records);
      expect(payload.includes('"application_id":"harmony-compatible-app"')).assertTrue();
      expect(payload.includes('"wireframes"')).assertTrue();
    });

    it('uses HarmonyOS replay endpoints and safe privacy defaults', 0, () => {
      expect(HARMONY_REPLAY_ENDPOINTS.records).assertEqual('v1/write/rum/replay');
      expect(HARMONY_REPLAY_ENDPOINTS.assets).assertEqual('v1/write/rum/replay_assets');
      expect(HARMONY_REPLAY_ENDPOINTS.assetCheck).assertEqual('v1/check/rum/replay_assets');

      const config = new FTSessionReplayConfig();
      expect(config.getTextAndInputPrivacy()).assertEqual(TextAndInputPrivacy.MASK_ALL);
      expect(config.getImagePrivacy()).assertEqual(ImagePrivacy.MASK_ALL);
      expect(config.getTouchPrivacy()).assertEqual(TouchPrivacy.HIDE);
      expect(config.setSampleRate(200).getSampleRate()).assertEqual(100);
      expect(config.setSessionReplayOnErrorSampleRate(-1).getSessionReplayOnErrorSampleRate()).assertEqual(0);
      expect(config.setSnapshotIntervalMs(1).getSnapshotIntervalMs()).assertEqual(16);
      expect(config.setSnapshotIntervalMs(20000).getSnapshotIntervalMs()).assertEqual(10000);
      expect(config.setFullSnapshotIntervalMs(1).getFullSnapshotIntervalMs()).assertEqual(3000);
      expect(config.setFullSnapshotIntervalMs(400000).getFullSnapshotIntervalMs()).assertEqual(300000);
      expect(config.setMotionQuietPeriodMs(1).getMotionQuietPeriodMs()).assertEqual(50);
      expect(config.setMotionQuietPeriodMs(6000).getMotionQuietPeriodMs()).assertEqual(5000);
      expect(config.setStorageMaxBytes(1).getStorageMaxBytes()).assertEqual(1024 * 1024);
      expect(config.setStorageMaxBytes(200 * 1024 * 1024).getStorageMaxBytes()).assertEqual(100 * 1024 * 1024);
      expect(config.setMaxRecordsPerSegment(0).getMaxRecordsPerSegment()).assertEqual(1);
      expect(config.setMaxRecordsPerSegment(1000).getMaxRecordsPerSegment()).assertEqual(500);
      expect(config.getUploadIntervalMs()).assertEqual(2500);
      expect(config.setUploadIntervalMs(1).getUploadIntervalMs()).assertEqual(500);
      expect(config.setUploadIntervalMs(500000).getUploadIntervalMs()).assertEqual(5000);
      expect(config.setUploadIntervalMs(0).getUploadIntervalMs()).assertEqual(0);
      expect(config.getErrorSampleWindowMs()).assertEqual(60000);
    });

    it('serializes visual shape, text and resource-backed image wireframes', 0, () => {
      const shape: ReplayShapeWireframe = {
        id: 1, x: 0, y: 0, width: 1080, height: 2400, type: 'shape',
        shapeStyle: {
          backgroundColor: '#FFFFFFFF', opacity: 1, cornerRadius: 8.5,
          backgroundGradient: {
            kind: 'linear', colors: ['#112233FF', '#445566FF'], stops: [0, 1], angle: 90
          },
          shadow: { color: '#00000066', offsetX: 0, offsetY: 2, blurRadius: 8 },
          transform: { scaleX: 1, scaleY: 1 }, visible: true
        },
        zIndex: 3
      };
      const title: ReplayTextWireframe = {
        id: 2, x: 40, y: 80, width: 600, height: 48, type: 'text', text: 'Replay title',
        textStyle: {
          family: 'HarmonyOS Sans, sans-serif', size: 20, color: '#1F2937FF', weight: 700,
          lineHeight: 28, letterSpacing: 0.5, decoration: 'underline'
        }
      };
      const image: ReplayImageWireframe = {
        id: 3, x: 40, y: 160, width: 72, height: 72, type: 'image',
        resourceId: 'a'.repeat(64), mimeType: 'image/png', isEmpty: false,
        imageStyle: { objectFit: 'contain', tintColor: '#FFFFFFFF' }
      };
      const records: Array<SessionReplayRecord> = [fullSnapshotRecord(1700000000000, [shape, title, image])];
      const context: SessionReplayContext = {
        applicationId: 'visual-app', sessionId: 'visual-session', viewId: 'visual-view'
      };
      const payload = serializeReplayEnvelope(context, records);
      expect(payload.includes('"type":"shape"')).assertTrue();
      expect(payload.includes('"type":"text"')).assertTrue();
      expect(payload.includes('"type":"image"')).assertTrue();
      expect(payload.includes('"resourceId":"' + 'a'.repeat(64) + '"')).assertTrue();
      expect(payload.includes('"weight":700')).assertTrue();
      expect(payload.includes('"backgroundGradient"')).assertTrue();
      expect(payload.includes('"cornerRadius":8.5')).assertTrue();
      expect(payload.includes('"zIndex":3')).assertTrue();
      expect(payload.includes('"objectFit":"contain"')).assertTrue();
    });

    it('converts the persisted envelope into Studio\'s HarmonyOS mobile segment', 0, () => {
      const meta: ReplayMetaData = { width: 100, height: 100 };
      const older: SessionReplayRecord = {
        timestamp: 1700000000000, type: ReplayRecordType.META, data: meta
      };
      const newer = fullSnapshotRecord(1700000000100, []);
      const globalContext: SessionReplayGlobalContext = {};
      globalContext['release'] = 1;
      const context: SessionReplayContext = {
        applicationId: 'app-id', sessionId: 'session-id', viewId: 'view-id', globalContext
      };
      const segment = createHarmonyReplayMobileSegment(context, [newer, older]);
      expect(segment.application.id).assertEqual('app-id');
      expect(segment.session.id).assertEqual('session-id');
      expect(segment.view.id).assertEqual('view-id');
      expect(segment.source).assertEqual('harmonyos');
      expect(segment.start).assertEqual(1700000000000);
      expect(segment.end).assertEqual(1700000000100);
      expect(segment.records_count).assertEqual(2);
      expect(segment.has_full_snapshot).assertTrue();
      expect(segment.records[0].timestamp).assertEqual(1700000000000);
    });

    it('uses HarmonyOS native record types for view lifecycle and mutations', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const firstRoot: ReplayPlaceholderWireframe = {
        id: 1, x: 0, y: 0, width: 100, height: 100,
        type: 'placeholder', label: 'ArkUI:Column'
      };
      const fullSnapshot = fullSnapshotRecord(1700000000000, [firstRoot]);
      const startRecords = processor.createViewStartRecords(fullSnapshot);
      expect(startRecords[0].type).assertEqual(4);
      expect(startRecords[1].type).assertEqual(6);
      expect(startRecords[2].type).assertEqual(8);
      expect(startRecords[3].type).assertEqual(10);
      const viewport = startRecords[2].data as ReplayViewportData;
      expect(viewport.width).assertEqual(100);
      expect(viewport.height).assertEqual(100);

      const movedRoot: ReplayPlaceholderWireframe = {
        id: 1, x: 10, y: 0, width: 100, height: 100,
        type: 'placeholder', label: 'ArkUI:Column'
      };
      const changedSnapshot = fullSnapshotRecord(1700000000100, [movedRoot]);
      const mutation = processor.createMutationRecord(changedSnapshot);
      expect(mutation !== null).assertTrue();
      expect(mutation?.type).assertEqual(11);
      processor.setFullSnapshotBaseline(changedSnapshot);
      expect(processor.createMutationRecord(changedSnapshot) === null).assertTrue();
      expect(processor.createViewEndRecord().type).assertEqual(7);
    });

    it('uses typed updates when visual wireframes change', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const firstShape: ReplayShapeWireframe = {
        id: 7, x: 0, y: 0, width: 100, height: 100, type: 'shape',
        shapeStyle: { backgroundColor: '#FFFFFFFF' }, zIndex: 1
      };
      const first = fullSnapshotRecord(1700000000000, [firstShape]);
      processor.setFullSnapshotBaseline(first);
      const movedShape: ReplayShapeWireframe = {
        id: 7, x: 8, y: 0, width: 100, height: 100, type: 'shape',
        shapeStyle: { backgroundColor: '#0A59F7FF' }, zIndex: 4
      };
      const second = fullSnapshotRecord(1700000000100, [movedShape]);
      const mutation = processor.createMutationRecord(second);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(1);
      expect(mutationData.updates[0].type).assertEqual('shape');
      expect(mutationData.updates[0].x).assertEqual(8);
      expect(mutationData.updates[0].zIndex).assertEqual(4);
      expect(mutationData.updates[0].shapeStyle?.backgroundColor).assertEqual('#0A59F7FF');
    });

    it('moves only one node when rotating draw order in either direction', 0, () => {
      const first = orderedPlaceholders([0, 1, 2, 3, 4]);
      const rotations: Array<Array<number>> = [[0, 4, 1, 2, 3], [0, 2, 3, 4, 1]];
      for (const ids of rotations) {
        const processor = new ReplaySnapshotProcessor();
        processor.setFullSnapshotBaseline(fullSnapshotRecord(1000, first));
        const latest = orderedPlaceholders(ids);
        const mutation = processor.createMutationRecord(fullSnapshotRecord(1100, latest));
        const data = mutation?.data as ReplayMutationData;
        expect(data.removes.length).assertEqual(1);
        expect(data.adds.length).assertEqual(1);
        expect(data.updates.length).assertEqual(0);
        expect(JSON.stringify(applyPlaceholderMutation(first, data))).assertEqual(JSON.stringify(latest));
      }
    });

    it('reconstructs reordering with additions deletions and property changes', 0, () => {
      const first = orderedPlaceholders([0, 1, 2, 3, 4]);
      const latest = orderedPlaceholders([0, 4, 5, 1, 3]);
      (latest[3] as ReplayPlaceholderWireframe).label = 'updated';
      latest[3].x = 20;
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(fullSnapshotRecord(1000, first));
      const mutation = processor.createMutationRecord(fullSnapshotRecord(1100, latest));
      const data = mutation?.data as ReplayMutationData;
      expect(data.removes.length).assertEqual(2);
      expect(data.adds.length).assertEqual(2);
      expect(data.updates.length).assertEqual(1);
      expect(JSON.stringify(applyPlaceholderMutation(first, data))).assertEqual(JSON.stringify(latest));
      expect(processor.createMutationRecord(fullSnapshotRecord(1200, latest)) === null).assertTrue();
    });

    it('does not replace unchanged siblings when a retained candidate needs replacement', 0, () => {
      const first = orderedPlaceholders([0, 1, 2, 3, 4]);
      first[4].permanentId = 'old-component';
      const latest = orderedPlaceholders([0, 4, 1, 2, 3]);
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(fullSnapshotRecord(1000, first));
      const mutation = processor.createMutationRecord(fullSnapshotRecord(1100, latest));
      const data = mutation?.data as ReplayMutationData;
      expect(data.removes.length).assertEqual(1);
      expect(data.adds.length).assertEqual(1);
      expect(data.removes[0].id).assertEqual(4);
      expect(JSON.stringify(applyPlaceholderMutation(first, data))).assertEqual(JSON.stringify(latest));
    });

    it('suppresses id-only updates caused by serialized property order', 0, () => {
      const first: ReplayPlaceholderWireframe = {
        id: 1, x: 0, y: 0, width: 100, height: 40, type: 'placeholder', label: 'same'
      };
      const latest: ReplayPlaceholderWireframe = {
        type: 'placeholder', label: 'same', height: 40, width: 100, y: 0, x: 0, id: 1
      };
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(fullSnapshotRecord(1000, [first]));
      expect(processor.createMutationRecord(fullSnapshotRecord(1100, [latest])) === null).assertTrue();
    });

    it('clears clipping with updates for every wireframe type', 0, () => {
      const shape: ReplayShapeWireframe = { id: 1, x: 0, y: 0, width: 100, height: 40, type: 'shape' };
      const text: ReplayTextWireframe = {
        id: 2, x: 0, y: 0, width: 100, height: 40, type: 'text', text: 'Label',
        textStyle: { family: 'sans-serif', size: 16, color: '#000000FF' }
      };
      const image: ReplayImageWireframe = { id: 3, x: 0, y: 0, width: 100, height: 40, type: 'image', isEmpty: true };
      const placeholder: ReplayPlaceholderWireframe = {
        id: 4, x: 0, y: 0, width: 100, height: 40, type: 'placeholder', label: 'Hidden'
      };
      const nodes: Array<ReplayWireframe> = [shape, text, image, placeholder];
      for (const node of nodes) node.clip = { top: 10, right: 20, bottom: 5, left: 15 };
      const processor = new ReplaySnapshotProcessor();
      const first = fullSnapshotRecord(1700000000000, nodes);
      processor.setFullSnapshotBaseline(first);
      const clearNodes = JSON.parse(JSON.stringify(nodes)) as Array<ReplayWireframe>;
      for (const node of clearNodes) node.clip = { top: 0, right: 0, bottom: 0, left: 0 };
      const latest = fullSnapshotRecord(1700000000100, clearNodes);
      const mutation = processor.createMutationRecord(latest);
      const data = mutation?.data as ReplayMutationData;
      expect(data.adds.length).assertEqual(0);
      expect(data.removes.length).assertEqual(0);
      expect(data.updates.length).assertEqual(4);
      for (let index = 0; index < data.updates.length; index++) {
        const update = data.updates[index];
        expect(update.id).assertEqual(nodes[index].id);
        expect(update.type).assertEqual(nodes[index].type);
        expect(update.x === undefined && update.y === undefined).assertTrue();
        expect(update.width === undefined && update.height === undefined).assertTrue();
        expect(JSON.stringify(update.clip)).assertEqual(JSON.stringify(clearNodes[index].clip));
        nodes[index].clip = update.clip;
      }
      expect(JSON.stringify(nodes)).assertEqual(JSON.stringify(clearNodes));
      expect(processor.createMutationRecord(latest) === null).assertTrue();
    });

    it('resets a removed optional clip without replacing the node', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const clipped: ReplayShapeWireframe = {
        id: 1, x: 0, y: 0, width: 100, height: 40, type: 'shape', clip: { left: 20 }
      };
      processor.setFullSnapshotBaseline(fullSnapshotRecord(1700000000000, [clipped]));
      const restored: ReplayShapeWireframe = { id: 1, x: 0, y: 0, width: 100, height: 40, type: 'shape' };
      const mutation = processor.createMutationRecord(fullSnapshotRecord(1700000000100, [restored]));
      const data = mutation?.data as ReplayMutationData;
      expect(data.adds.length).assertEqual(0);
      expect(data.removes.length).assertEqual(0);
      expect(data.updates[0].clip?.top).assertEqual(0);
      expect(data.updates[0].clip?.right).assertEqual(0);
      expect(data.updates[0].clip?.bottom).assertEqual(0);
      expect(data.updates[0].clip?.left).assertEqual(0);
    });

    it('preserves native text insets and alignment in HarmonyOS wireframes', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const centeredText: ReplayTextWireframe = {
        id: 8, x: 0, y: 0, width: 200, height: 64, type: 'text', text: 'Buy now',
        textStyle: { family: 'HarmonyOS Sans', size: 18, color: '#112233FF' },
        textPosition: {
          padding: { top: 12, right: 16, bottom: 12, left: 16 },
          alignment: { horizontal: 'center', vertical: 'center' }
        }
      };
      const first = fullSnapshotRecord(1700000000000, [centeredText]);
      processor.setFullSnapshotBaseline(first);
      const rightAlignedText: ReplayTextWireframe = {
        id: 8, x: 0, y: 0, width: 200, height: 64, type: 'text', text: 'Buy now',
        textStyle: { family: 'HarmonyOS Sans', size: 18, color: '#112233FF' },
        textPosition: {
          padding: { top: 12, right: 16, bottom: 12, left: 16 },
          alignment: { horizontal: 'right', vertical: 'center' }
        }
      };
      const second = fullSnapshotRecord(1700000000100, [rightAlignedText]);
      const mutation = processor.createMutationRecord(second);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(1);
      expect(mutationData.updates[0].type).assertEqual('text');
      expect(mutationData.updates[0].textPosition?.padding?.left).assertEqual(16);
      expect(mutationData.updates[0].textPosition?.alignment?.horizontal).assertEqual('right');
    });

    it('replaces a visual wireframe when an optional image resource is removed', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const resourceImage: ReplayImageWireframe = {
        id: 9, x: 0, y: 0, width: 100, height: 100, type: 'image',
        resourceId: 'b'.repeat(64), mimeType: 'image/png', isEmpty: false
      };
      const first = fullSnapshotRecord(1700000000000, [resourceImage]);
      processor.setFullSnapshotBaseline(first);
      const maskedImage: ReplayImageWireframe = {
        id: 9, x: 0, y: 0, width: 100, height: 100, type: 'image', isEmpty: true
      };
      const masked = fullSnapshotRecord(1700000000100, [maskedImage]);
      const mutation = processor.createMutationRecord(masked);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(0);
      expect(mutationData.removes.length).assertEqual(1);
      expect(mutationData.adds.length).assertEqual(1);
      expect((mutationData.adds[0].wireframe as ReplayImageWireframe).isEmpty).assertTrue();
    });

    it('emits image placement changes as a typed visual mutation', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const containedImage: ReplayImageWireframe = {
        id: 10, x: 0, y: 0, width: 200, height: 100, type: 'image',
        resourceId: 'c'.repeat(64), mimeType: 'image/png', isEmpty: false,
        imageStyle: { objectFit: 'contain' }
      };
      const first = fullSnapshotRecord(1700000000000, [containedImage]);
      processor.setFullSnapshotBaseline(first);
      const coveredImage: ReplayImageWireframe = {
        id: 10, x: 0, y: 0, width: 200, height: 100, type: 'image',
        resourceId: 'c'.repeat(64), mimeType: 'image/png', isEmpty: false,
        imageStyle: { objectFit: 'cover' }
      };
      const second = fullSnapshotRecord(1700000000100, [coveredImage]);
      const mutation = processor.createMutationRecord(second);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(1);
      expect(mutationData.updates[0].imageStyle?.objectFit).assertEqual('cover');
    });

    it('keeps regular and error sampling decisions independent', 0, () => {
      const regularConfig = new FTSessionReplayConfig()
        .setSampleRate(100)
        .setSessionReplayOnErrorSampleRate(100);
      expect(new SessionReplaySampler(regularConfig).decide('regular-session'))
        .assertEqual(SessionReplaySamplingMode.REGULAR);

      const errorConfig = new FTSessionReplayConfig()
        .setSampleRate(0)
        .setSessionReplayOnErrorSampleRate(100);
      expect(new SessionReplaySampler(errorConfig).decide('error-session'))
        .assertEqual(SessionReplaySamplingMode.ERROR);

      const disabledConfig = new FTSessionReplayConfig()
        .setSampleRate(0)
        .setSessionReplayOnErrorSampleRate(0);
      expect(new SessionReplaySampler(disabledConfig).decide('disabled-session'))
        .assertEqual(SessionReplaySamplingMode.NONE);
    });

    it('supports a process-wide Replay enable switch and delayed start', 0, () => {
      const replay = FTSessionReplay.getInstance();
      replay.disable();
      expect(replay.isEnabled()).assertFalse();

      replay.init(new FTSessionReplayConfig().setDelayInit(true));
      expect(replay.isEnabled()).assertFalse();

      replay.start();
      expect(replay.isEnabled()).assertTrue();

      replay.disable();
      expect(replay.isEnabled()).assertFalse();
    });

    it('forwards Browser records only while the WebView slot is active or in grace period', 0, () => {
      const recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig().setSampleRate(100));
      recorder.start();
      expect(recorder.getWebViewOptions()?.privacyLevel).assertEqual('mask');
      const now = Date.now();
      const linkContext: SessionReplayGlobalContext = {};
      linkContext['order_id'] = 'A-1';
      const context: FTSessionReplayWebDataContext = {
        applicationId: 'browser-app',
        sessionId: 'browser-session',
        viewId: 'browser-view',
        slotId: '1000000126',
        linkContext,
        payload: `{"timestamp":${now},"type":2,"data":{"node":{"id":1}}}`,
        timestamp: now
      };
      recorder.onWebReplaySlotActive(context.slotId, true, now);
      FTSessionReplayBridgeRegistry.registerWebReplayComponent('web-test');
      FTSessionReplayBridgeRegistry.observeWebReplaySlots(context.applicationId, context.sessionId,
        'native-view', [{ componentId: 'web-test', slotId: context.slotId }], now);
      expect(recorder.onWebReplayData(context)).assertTrue();
      recorder.flushWebReplayData();
      const replayContext: SessionReplayContext = {
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId
      };
      const records = recorder.getRecordedRecords(replayContext);
      expect(records.length).assertEqual(1);
      expect(records[0].slotId).assertEqual('1000000126');
      expect(records[0].timestamp).assertEqual(now);

      recorder.onWebReplaySlotActive(context.slotId, false, now);
      FTSessionReplayBridgeRegistry.observeWebReplaySlots(context.applicationId, context.sessionId,
        'native-view', [], now);
      const withinGrace: FTSessionReplayWebDataContext = {
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId,
        slotId: context.slotId,
        linkContext: context.linkContext,
        payload: `{"timestamp":${now + 1000},"type":3,"data":{"source":0}}`,
        timestamp: now + 1000
      };
      expect(recorder.onWebReplayData(withinGrace)).assertTrue();
      const afterGrace: FTSessionReplayWebDataContext = {
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId,
        slotId: context.slotId,
        linkContext: context.linkContext,
        payload: `{"timestamp":${now + 2000},"type":3,"data":{"source":0}}`,
        timestamp: now + 2000
      };
      expect(recorder.onWebReplayData(afterGrace)).assertFalse();
      FTSessionReplayBridgeRegistry.unregisterWebReplayComponent('web-test');
      recorder.stop();
    });

    it('creates HarmonyOS-compatible multipart Replay fields and intake URLs', 0, () => {
      const record = fullSnapshotRecord(1700000000000, []);
      const globalContext: SessionReplayGlobalContext = {};
      globalContext['release'] = 1;
      globalContext['enabled'] = true;
      const context: SessionReplayContext = {
        applicationId: 'app-id', sessionId: 'session-id', viewId: 'view-id', globalContext
      };
      const segment: SessionReplayStoredSegment = {
        version: 1,
        id: '1700000000000-000001',
        createdAt: 1700000000000,
        context,
        records: [record]
      };
      const fields = createSessionReplayUploadFields(segment, 'prod', '1.2.3');
      expect(fields.fields.get('start')).assertEqual('1700000000000');
      expect(fields.fields.get('end')).assertEqual('1700000000000');
      expect(fields.fields.get('records_count')).assertEqual('1');
      expect(fields.fields.get('has_full_snapshot')).assertEqual('true');
      expect(fields.fields.get('source')).assertEqual('harmonyos');
      expect(fields.fields.get('sdk_name')).assertEqual('df_harmonyos_rum_sdk');
      expect(fields.fields.get('app_id')).assertEqual('app-id');
      expect(fields.fields.get('release')).assertEqual('1');
      expect(fields.rawSegment.endsWith('\n')).assertTrue();
      expect(fields.rawSegment.includes('"application":{"id":"app-id"}')).assertTrue();
      expect(fields.rawSegment.includes('"source":"harmonyos"')).assertTrue();
      expect(fields.rawSegment.includes('"application_id"')).assertFalse();
      expect(createHarmonyReplayUploadUrl('https://dk.example', '', ''))
        .assertEqual('https://dk.example/v1/write/rum/replay?precision=ns');
      expect(createHarmonyReplayUploadUrl('', 'https://dw.example/', 'token'))
        .assertEqual('https://dw.example/v1/write/rum/replay?token=token&to_headless=true&precision=ns');
      expect(createHarmonyReplayUploadUrl('localhost:9529', '', '')).assertEqual('');
      expect(createHarmonyReplayUploadUrl('', 'https://dw.example', '')).assertEqual('');
      expect(createHarmonyReplayUploadUrl('', 'https://dw.example', 'a+b/c'))
        .assertEqual('https://dw.example/v1/write/rum/replay?token=a%2Bb%2Fc&to_headless=true&precision=ns');
      expect(createHarmonyReplayResourceUrl('ftp://dk.example', '', '', HARMONY_REPLAY_ENDPOINTS.assets, true))
        .assertEqual('');
      expect(createHarmonyReplayResourceUrl('', 'https://dw.example', '', HARMONY_REPLAY_ENDPOINTS.assets, true))
        .assertEqual('');
      expect(isReplayUploadEndpointAvailable('https://dk.example', '', '')).assertTrue();
      expect(isReplayUploadEndpointAvailable('', 'https://dw.example', 'token')).assertTrue();
      expect(isReplayUploadEndpointAvailable('', 'https://dw.example', '')).assertFalse();
      expect(isValidReplayHttpUrl('http://localhost:9529/base')).assertTrue();
      expect(isValidReplayHttpUrl('https://[::1]:9529')).assertTrue();
      expect(isValidReplayHttpUrl('file:///tmp/replay')).assertFalse();
      expect(isValidReplayHttpUrl('https://')).assertFalse();
      expect(isValidReplayHttpUrl('https://dk.example/replay path')).assertFalse();
      expect(REPLAY_MAX_BATCHES_PER_UPLOAD_JOB).assertEqual(10);
      expect(isRetryableReplayUploadStatus(0)).assertTrue();
      expect(isRetryableReplayUploadStatus(204)).assertTrue();
      expect(isRetryableReplayUploadStatus(302)).assertTrue();
      expect(isRetryableReplayUploadStatus(408)).assertFalse();
      expect(isRetryableReplayUploadStatus(429)).assertFalse();
      expect(isRetryableReplayUploadStatus(503)).assertTrue();
      expect(isRetryableReplayUploadStatus(400)).assertFalse();
      expect(isRetryableReplayUploadStatus(200)).assertFalse();
      // A malformed resource check response is invalid even though its transport code is zero.
      expect(isRetryableReplayUploadStatus(0, true)).assertFalse();
      expect(isRetryableReplayResourceFailure(0, true, false)).assertFalse();
      expect(isRetryableReplayResourceFailure(0, true, true)).assertTrue();
      expect(shouldDiscardReplayUploadStatus(400)).assertTrue();
      expect(shouldDiscardReplayUploadStatus(408)).assertTrue();
      expect(shouldDiscardReplayUploadStatus(429)).assertTrue();
      expect(shouldDiscardReplayUploadStatus(503)).assertFalse();
      expect(shouldDiscardReplayUploadStatus(0, true)).assertTrue();
    });
  });
}
