import { describe, expect, it } from '@ohos/hypium';
import {
  ANDROID_REPLAY_ENDPOINTS,
  createReplayEnvelope,
  ReplayRecordType,
  serializeReplayEnvelope,
  SessionReplayRecord
} from '../../main/ets/components/SessionReplayProtocol';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import { SessionReplaySampler, SessionReplaySamplingMode } from '../../main/ets/components/SessionReplaySampler';
import { FTSessionReplay } from '../../main/ets/components/FTSessionReplay';
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
      expect(startRecords[2].type).assertEqual(10);

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
      expect(fields.fields.get('app_id')).assertEqual('app-id');
      expect(fields.fields.get('release')).assertEqual('1');
      expect(fields.rawSegment.endsWith('\n')).assertTrue();
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
