import { describe, expect, it } from '@ohos/hypium';
import {
  ANDROID_REPLAY_ENDPOINTS,
  createReplayEnvelope,
  ReplayRecordType,
  serializeReplayEnvelope,
  SessionReplayRecord
} from '../../main/ets/components/SessionReplayProtocol';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from '../../main/ets/components/FTSessionReplayConfig';

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
  });
}
