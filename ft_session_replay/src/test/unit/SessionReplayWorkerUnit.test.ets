import { describe, expect, it } from '@ohos/hypium';
import { ImagePrivacy, TextAndInputPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import {
  FullSnapshotData,
  ReplayPlaceholderWireframe,
  ReplayViewEndData,
  SessionReplayContext,
  SessionReplayRecord,
  ReplayRecordType
} from '../../main/ets/components/SessionReplayProtocol';
import {
  isReplaySnapshotExpired,
  ReplayWorkerCommit,
  ReplayWorkerOptions,
  ReplayViewport
} from '../../main/ets/components/SessionReplayWorkQueue';
import { SessionReplayWorkerOperations } from '../../main/ets/components/SessionReplayWorkerOperations';
import { nextReplayUploadSchedule } from '../../main/ets/components/SessionReplayUploadQueue';
import { SessionReplayUploadResult } from '../../main/ets/components/SessionReplayUploader';

function fullSnapshot(timestamp: number, childX: number): SessionReplayRecord {
  const root: ReplayPlaceholderWireframe = {
    id: 1, x: 0, y: 0, width: 100, height: 100, type: 'placeholder', label: 'root'
  };
  const child: ReplayPlaceholderWireframe = {
    id: 2, x: childX, y: 0, width: 10, height: 10, type: 'placeholder', label: 'child'
  };
  const data: FullSnapshotData = { wireframes: [root, child] };
  const snapshot: SessionReplayRecord = {
    timestamp,
    type: ReplayRecordType.FULL_SNAPSHOT,
    data
  };
  return snapshot;
}

export default function sessionReplayWorkerUnitTest(): void {
  describe('SessionReplayWorkerUnit', () => {
    it('drops only snapshots that waited longer than one second', 0, () => {
      expect(isReplaySnapshotExpired(100, 1100)).assertFalse();
      expect(isReplaySnapshotExpired(100, 1101)).assertTrue();
    });

    it('serially produces a baseline and a mutation from worker snapshots', 0, () => {
      const options: ReplayWorkerOptions = {
        filesDir: '',
        maxNodes: 100,
        maxBytes: 1024 * 1024,
        maxRecordsPerSegment: 100,
        fullSnapshotIntervalMs: 30000,
        errorSampleWindowMs: 60000,
        textPrivacy: TextAndInputPrivacy.MASK_ALL,
        imagePrivacy: ImagePrivacy.MASK_ALL
      };
      const operations = new SessionReplayWorkerOperations(options);
      const viewport: ReplayViewport = { width: 100, height: 100 };
      const commit: ReplayWorkerCommit = {
        context: { applicationId: 'app', sessionId: 'session', viewId: 'view' },
        snapshot: fullSnapshot(1000, 0),
        viewport,
        previousViewport: null,
        lastFullSnapshotAt: 0,
        storeKind: 'none'
      };
      const start = operations.process('start', commit);
      expect(start.records.length).assertEqual(4);
      expect(start.records[3].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      expect(start.stored).assertTrue();

      commit.snapshot = fullSnapshot(1100, 5);
      commit.previousViewport = viewport;
      commit.lastFullSnapshotAt = start.lastFullSnapshotAt;
      const mutation = operations.process('automatic', commit);
      expect(mutation.records.length).assertEqual(1);
      expect(mutation.records[0].type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      expect(mutation.payload.includes('"source":0')).assertTrue();

      expect(operations.process('automatic', commit).records.length).assertEqual(0);
    });

    it('keeps native protocol records behind a persisted View Start', 0, () => {
      const options: ReplayWorkerOptions = {
        filesDir: '', maxNodes: 100, maxBytes: 1024 * 1024, maxRecordsPerSegment: 100,
        fullSnapshotIntervalMs: 30000, errorSampleWindowMs: 60000,
        textPrivacy: TextAndInputPrivacy.MASK_ALL,
        imagePrivacy: ImagePrivacy.MASK_ALL
      };
      const operations = new SessionReplayWorkerOperations(options);
      const context: SessionReplayContext = { applicationId: 'app', sessionId: 'session', viewId: 'view' };
      const endData: ReplayViewEndData = {};
      const viewEnd: SessionReplayRecord = { timestamp: 1200, type: ReplayRecordType.VIEW_END, data: endData };
      expect(operations.appendRecords(context, [viewEnd], 'none', true)).assertFalse();
      const viewport: ReplayViewport = { width: 100, height: 100 };
      const start: ReplayWorkerCommit = {
        context, snapshot: fullSnapshot(1000, 0), viewport, previousViewport: null,
        lastFullSnapshotAt: 0, storeKind: 'none'
      };
      expect(operations.process('start', start).stored).assertTrue();
      expect(operations.appendRecords(context, [viewEnd], 'none', true)).assertTrue();
      expect(operations.appendRecords(context, [viewEnd], 'none', true)).assertFalse();
    });

    it('backs off retryable scheduled uploads and resets after success', 0, () => {
      const failed: SessionReplayUploadResult = {
        success: false, code: 503, message: 'retry', retryable: true,
        endpointBlocked: false, attemptedSegments: 1, uploadedSegments: 0, remainingSegments: 1
      };
      const first = nextReplayUploadSchedule(15000, 0, failed);
      expect(first.delayMs).assertEqual(15000);
      const second = nextReplayUploadSchedule(15000, first.retryCount, failed);
      expect(second.delayMs).assertEqual(30000);
      const third = nextReplayUploadSchedule(15000, second.retryCount, failed);
      expect(third.delayMs).assertEqual(60000);
      failed.success = true;
      const recovered = nextReplayUploadSchedule(15000, third.retryCount, failed);
      expect(recovered.delayMs).assertEqual(15000);
      expect(recovered.retryCount).assertEqual(0);
    });
  });
}
