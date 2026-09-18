import { describe, expect, it } from '@ohos/hypium';
import {
  ANDROID_REPLAY_ENDPOINTS,
  createAndroidReplayMobileSegment,
  createReplayEnvelope,
  ReplayImageWireframe,
  ReplayRecordType,
  ReplayMutationData,
  ReplayViewportData,
  serializeReplayEnvelope,
  SessionReplayRecord
} from '../../main/ets/components/SessionReplayProtocol';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from '../../main/ets/components/SessionReplaySampler';
import { FTSessionReplay } from '../../main/ets/components/FTSessionReplay';
import { FTSessionReplayPOC } from '../../main/ets/components/FTSessionReplayPOC';
import {
  createAndroidReplayUploadUrl,
  createSessionReplayUploadFields,
  isRetryableReplayUploadStatus
} from '../../main/ets/components/SessionReplayUploader';

export default function sessionReplayProtocolUnitTest() {
  describe('SessionReplayProtocolUnit', () => {
    it('serializes the Android enriched-record envelope', 0, () => {
      const records: Array<SessionReplayRecord> = [{
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: {
          wireframes: [{
            id: 1000000001,
            x: 0,
            y: 0,
            width: 1080,
            height: 2400,
            type: 'placeholder',
            label: 'ArkUI:Column',
            permanentId: 'session-replay-poc-root'
          }]
        }
      }];
      const context = {
        applicationId: 'android-compatible-app',
        sessionId: 'session-id',
        viewId: 'view-id',
        globalContext: { wgt_id: 'demo', release: 1 }
      };

      const envelope = createReplayEnvelope(context, records);
      expect(envelope.application_id).assertEqual('android-compatible-app');
      expect(envelope.session_id).assertEqual('session-id');
      expect(envelope.view_id).assertEqual('view-id');
      expect(envelope.records[0].type).assertEqual(10);
      expect(envelope.records[0].data !== undefined).assertTrue();
      const payload = serializeReplayEnvelope(context, records);
      expect(payload.includes('"application_id":"android-compatible-app"')).assertTrue();
      expect(payload.includes('"wireframes"')).assertTrue();
    });

    it('uses Android replay endpoints and safe privacy defaults', 0, () => {
      expect(ANDROID_REPLAY_ENDPOINTS.records).assertEqual('v1/write/rum/replay');
      expect(ANDROID_REPLAY_ENDPOINTS.assets).assertEqual('v1/write/rum/replay_assets');
      expect(ANDROID_REPLAY_ENDPOINTS.assetCheck).assertEqual('v1/check/rum/replay_assets');

      const config = new FTSessionReplayConfig();
      expect(config.getTextAndInputPrivacy()).assertEqual(TextAndInputPrivacy.MASK_ALL);
      expect(config.getImagePrivacy()).assertEqual(ImagePrivacy.MASK_ALL);
      expect(config.getTouchPrivacy()).assertEqual(TouchPrivacy.HIDE);
      expect(config.setSampleRate(2).getSampleRate()).assertEqual(1);
      expect(config.setSessionReplayOnErrorSampleRate(-1).getSessionReplayOnErrorSampleRate()).assertEqual(0);
      expect(config.setSnapshotIntervalMs(1).getSnapshotIntervalMs()).assertEqual(100);
      expect(config.setSnapshotIntervalMs(20000).getSnapshotIntervalMs()).assertEqual(10000);
      expect(config.setStorageMaxBytes(1).getStorageMaxBytes()).assertEqual(1024 * 1024);
      expect(config.setStorageMaxBytes(200 * 1024 * 1024).getStorageMaxBytes()).assertEqual(100 * 1024 * 1024);
      expect(config.setMaxRecordsPerSegment(0).getMaxRecordsPerSegment()).assertEqual(1);
      expect(config.setMaxRecordsPerSegment(1000).getMaxRecordsPerSegment()).assertEqual(500);
      expect(config.setUploadIntervalMs(1).getUploadIntervalMs()).assertEqual(1000);
      expect(config.setUploadIntervalMs(500000).getUploadIntervalMs()).assertEqual(300000);
      expect(config.setUploadIntervalMs(0).getUploadIntervalMs()).assertEqual(0);
      expect(config.getErrorSampleWindowMs()).assertEqual(60000);
    });

    it('serializes visual shape, text and resource-backed image wireframes', 0, () => {
      const records: Array<SessionReplayRecord> = [{
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: {
          wireframes: [
            {
              id: 1, x: 0, y: 0, width: 1080, height: 2400, type: 'shape',
              shapeStyle: {
                backgroundColor: '#FFFFFFFF',
                opacity: 1,
                cornerRadius: 8.5,
                backgroundGradient: {
                  kind: 'linear', colors: ['#112233FF', '#445566FF'], stops: [0, 1], angle: 90
                },
                shadow: { color: '#00000066', offsetX: 0, offsetY: 2, blurRadius: 8 },
                transform: { scaleX: 1, scaleY: 1 },
                visible: true
              },
              zIndex: 3
            },
            {
              id: 2, x: 40, y: 80, width: 600, height: 48, type: 'text', text: 'Replay title',
              textStyle: {
                family: 'HarmonyOS Sans, sans-serif', size: 20, color: '#1F2937FF', weight: 700,
                lineHeight: 28, letterSpacing: 0.5, decoration: 'underline'
              }
            },
            {
              id: 3, x: 40, y: 160, width: 72, height: 72, type: 'image',
              resourceId: 'a'.repeat(64), mimeType: 'image/png', isEmpty: false,
              imageStyle: { objectFit: 'contain', tintColor: '#FFFFFFFF' }
            }
          ]
        }
      }];
      const payload = serializeReplayEnvelope({
        applicationId: 'visual-app', sessionId: 'visual-session', viewId: 'visual-view'
      }, records);
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

    it('converts the persisted envelope into Studio\'s Android mobile segment', 0, () => {
      const older: SessionReplayRecord = {
        timestamp: 1700000000000, type: ReplayRecordType.META, data: { width: 100, height: 100 }
      };
      const newer: SessionReplayRecord = {
        timestamp: 1700000000100, type: ReplayRecordType.FULL_SNAPSHOT, data: { wireframes: [] }
      };
      const segment = createAndroidReplayMobileSegment({
        applicationId: 'app-id', sessionId: 'session-id', viewId: 'view-id', globalContext: { release: 1 }
      }, [newer, older]);
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

    it('uses Android native record types for view lifecycle and mutations', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const fullSnapshot: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: {
          wireframes: [{
            id: 1,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            type: 'placeholder',
            label: 'ArkUI:Column'
          }]
        }
      };
      const startRecords = processor.createViewStartRecords(fullSnapshot);
      expect(startRecords[0].type).assertEqual(4);
      expect(startRecords[1].type).assertEqual(6);
      expect(startRecords[2].type).assertEqual(8);
      expect(startRecords[3].type).assertEqual(10);
      const viewport = startRecords[2].data as ReplayViewportData;
      expect(viewport.width).assertEqual(100);
      expect(viewport.height).assertEqual(100);

      const changedSnapshot: SessionReplayRecord = {
        timestamp: 1700000000100,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: {
          wireframes: [{
            id: 1,
            x: 10,
            y: 0,
            width: 100,
            height: 100,
            type: 'placeholder',
            label: 'ArkUI:Column'
          }]
        }
      };
      const mutation = processor.createMutationRecord(changedSnapshot);
      expect(mutation !== null).assertTrue();
      expect(mutation?.type).assertEqual(11);
      processor.setFullSnapshotBaseline(changedSnapshot);
      expect(processor.createMutationRecord(changedSnapshot) === null).assertTrue();
      expect(processor.createViewEndRecord().type).assertEqual(7);
    });

    it('uses typed updates when visual wireframes change', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const first: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 7, x: 0, y: 0, width: 100, height: 100, type: 'shape',
          shapeStyle: { backgroundColor: '#FFFFFFFF' }, zIndex: 1
        }] }
      };
      processor.setFullSnapshotBaseline(first);
      const second: SessionReplayRecord = {
        timestamp: 1700000000100,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 7, x: 8, y: 0, width: 100, height: 100, type: 'shape',
          shapeStyle: { backgroundColor: '#0A59F7FF' }, zIndex: 4
        }] }
      };
      const mutation = processor.createMutationRecord(second);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(1);
      expect(mutationData.updates[0].type).assertEqual('shape');
      expect(mutationData.updates[0].x).assertEqual(8);
      expect(mutationData.updates[0].zIndex).assertEqual(4);
      expect(mutationData.updates[0].shapeStyle?.backgroundColor).assertEqual('#0A59F7FF');
    });

    it('preserves native text insets and alignment in Android wireframes', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      const first: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 8, x: 0, y: 0, width: 200, height: 64, type: 'text', text: 'Buy now',
          textStyle: { family: 'HarmonyOS Sans', size: 18, color: '#112233FF' },
          textPosition: {
            padding: { top: 12, right: 16, bottom: 12, left: 16 },
            alignment: { horizontal: 'center', vertical: 'center' }
          }
        }] }
      };
      processor.setFullSnapshotBaseline(first);
      const second: SessionReplayRecord = {
        timestamp: 1700000000100,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 8, x: 0, y: 0, width: 200, height: 64, type: 'text', text: 'Buy now',
          textStyle: { family: 'HarmonyOS Sans', size: 18, color: '#112233FF' },
          textPosition: {
            padding: { top: 12, right: 16, bottom: 12, left: 16 },
            alignment: { horizontal: 'right', vertical: 'center' }
          }
        }] }
      };
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
      const first: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 9, x: 0, y: 0, width: 100, height: 100, type: 'image',
          resourceId: 'b'.repeat(64), mimeType: 'image/png', isEmpty: false
        }] }
      };
      processor.setFullSnapshotBaseline(first);
      const masked: SessionReplayRecord = {
        timestamp: 1700000000100,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 9, x: 0, y: 0, width: 100, height: 100, type: 'image', isEmpty: true
        }] }
      };
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
      const first: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 10, x: 0, y: 0, width: 200, height: 100, type: 'image',
          resourceId: 'c'.repeat(64), mimeType: 'image/png', isEmpty: false,
          imageStyle: { objectFit: 'contain' }
        }] }
      };
      processor.setFullSnapshotBaseline(first);
      const second: SessionReplayRecord = {
        timestamp: 1700000000100,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [{
          id: 10, x: 0, y: 0, width: 200, height: 100, type: 'image',
          resourceId: 'c'.repeat(64), mimeType: 'image/png', isEmpty: false,
          imageStyle: { objectFit: 'cover' }
        }] }
      };
      const mutation = processor.createMutationRecord(second);
      expect(mutation !== null).assertTrue();
      const mutationData = mutation?.data as ReplayMutationData;
      expect(mutationData.updates.length).assertEqual(1);
      expect(mutationData.updates[0].imageStyle?.objectFit).assertEqual('cover');
    });

    it('keeps regular and error sampling decisions independent', 0, () => {
      const regularConfig = new FTSessionReplayConfig()
        .setSampleRate(1)
        .setSessionReplayOnErrorSampleRate(1);
      expect(new SessionReplaySampler(regularConfig).decide('regular-session'))
        .assertEqual(SessionReplaySamplingMode.REGULAR);

      const errorConfig = new FTSessionReplayConfig()
        .setSampleRate(0)
        .setSessionReplayOnErrorSampleRate(1);
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
      const recorder = new FTSessionReplayPOC(new FTSessionReplayConfig().setSampleRate(1));
      recorder.start();
      expect(recorder.getWebViewOptions()?.privacyLevel).assertEqual('mask');
      const now = Date.now();
      const context = {
        applicationId: 'browser-app',
        sessionId: 'browser-session',
        viewId: 'browser-view',
        slotId: 'harmony-web-test',
        linkContext: { order_id: 'A-1' },
        payload: JSON.stringify({ timestamp: now, type: 10, data: { node: 1 } }),
        timestamp: now
      };
      recorder.onWebReplaySlotActive(context.slotId, true, now);
      expect(recorder.onWebReplayData(context)).assertTrue();
      const records = recorder.getRecordedRecords({
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId
      });
      expect(records.length).assertEqual(1);
      expect(records[0].slotId).assertEqual('harmony-web-test');
      expect(records[0].timestamp).assertEqual(now);

      recorder.onWebReplaySlotActive(context.slotId, false, now);
      const withinGrace = {
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId,
        slotId: context.slotId,
        linkContext: context.linkContext,
        payload: JSON.stringify({ timestamp: now + 1000, type: 11, data: { source: 0 } }),
        timestamp: now + 1000
      };
      expect(recorder.onWebReplayData(withinGrace)).assertTrue();
      const afterGrace = {
        applicationId: context.applicationId,
        sessionId: context.sessionId,
        viewId: context.viewId,
        slotId: context.slotId,
        linkContext: context.linkContext,
        payload: JSON.stringify({ timestamp: now + 2000, type: 11, data: { source: 0 } }),
        timestamp: now + 2000
      };
      expect(recorder.onWebReplayData(afterGrace)).assertFalse();
      recorder.stop();
    });

    it('creates Android-compatible multipart Replay fields and intake URLs', 0, () => {
      const record: SessionReplayRecord = {
        timestamp: 1700000000000,
        type: ReplayRecordType.FULL_SNAPSHOT,
        data: { wireframes: [] }
      };
      const fields = createSessionReplayUploadFields({
        version: 1,
        id: '1700000000000-000001',
        createdAt: 1700000000000,
        context: {
          applicationId: 'app-id',
          sessionId: 'session-id',
          viewId: 'view-id',
          globalContext: { release: 1, enabled: true }
        },
        records: [record]
      }, 'prod', '1.2.3');
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
      expect(createAndroidReplayUploadUrl('https://dk.example', '', ''))
        .assertEqual('https://dk.example/v1/write/rum/replay?precision=ns');
      expect(createAndroidReplayUploadUrl('', 'https://dw.example/', 'token'))
        .assertEqual('https://dw.example/v1/write/rum/replay?token=token&to_headless=true&precision=ns');
      expect(isRetryableReplayUploadStatus(0)).assertTrue();
      expect(isRetryableReplayUploadStatus(429)).assertTrue();
      expect(isRetryableReplayUploadStatus(503)).assertTrue();
      expect(isRetryableReplayUploadStatus(400)).assertFalse();
    });
  });
}
