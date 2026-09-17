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
  });
}
