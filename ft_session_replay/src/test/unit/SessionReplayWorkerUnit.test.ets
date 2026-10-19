import { describe, expect, it } from '@ohos/hypium';
import { ImagePrivacy, TextAndInputPrivacy } from '../../main/ets/components/FTSessionReplayConfig';
import {
  FullSnapshotData,
  ReplayPlaceholderWireframe,
  ReplayMutationData,
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
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
import {
  nextReplayUploadSchedule,
  ReplayUploadOutcome,
  replayInitialUploadDelayMs
} from '../../main/ets/components/SessionReplayUploadQueue';
import {
  canStartReplayUpload,
  isReplayBatteryHealthy
} from '../../main/ets/components/SessionReplayUploadConditions';

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

function newOperations(fullSnapshotIntervalMs: number = 30000): SessionReplayWorkerOperations {
  const options: ReplayWorkerOptions = {
    filesDir: '', maxNodes: 100, maxBytes: 1024 * 1024, maxRecordsPerSegment: 100,
    fullSnapshotIntervalMs, errorSampleWindowMs: 60000,
    textPrivacy: TextAndInputPrivacy.MASK_ALL, imagePrivacy: ImagePrivacy.MASK_ALL
  };
  return new SessionReplayWorkerOperations(options);
}

function automaticCommit(timestamp: number, childX: number): ReplayWorkerCommit {
  return {
    context: { applicationId: 'app', sessionId: 'session', viewId: 'view' },
    snapshot: fullSnapshot(timestamp, childX), viewport: { width: 100, height: 100 },
    previousViewport: null, lastFullSnapshotAt: 0, storeKind: 'none'
  };
}

export default function sessionReplayWorkerUnitTest(): void {
  describe('SessionReplayWorkerUnit', () => {
    it('expires ordinary samples but retains first frames, bounded transitions and settled boundaries', 0, () => {
      expect(isReplaySnapshotExpired(100, 1100)).assertFalse();
      expect(isReplaySnapshotExpired(100, 1101)).assertTrue();
      expect(isReplaySnapshotExpired(100, 1100, 'automatic')).assertFalse();
      expect(isReplaySnapshotExpired(100, 1101, 'automatic')).assertTrue();
      expect(isReplaySnapshotExpired(100, 1101, 'full')).assertTrue();
      expect(isReplaySnapshotExpired(100, 1101, 'start')).assertFalse();
      expect(isReplaySnapshotExpired(100, 60100, 'start')).assertFalse();
      expect(isReplaySnapshotExpired(100, 60100, 'settled')).assertFalse();
      expect(isReplaySnapshotExpired(100, 60100, 'transition')).assertFalse();
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

    it('writes the settled scene removal as Mutation under the existing checkpoint', 0, () => {
      const operations = newOperations();
      const commit = automaticCommit(1000, 50);
      operations.process('start', commit);
      commit.snapshot = fullSnapshot(1200, 50);
      (commit.snapshot.data as FullSnapshotData).wireframes.splice(1, 1);
      const settled = operations.process('settled', commit);
      expect(settled.records.length).assertEqual(1);
      expect(settled.records[0].type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      const mutation = settled.records[0].data as ReplayMutationData;
      expect(mutation.removes.length).assertEqual(1);
      expect(mutation.removes[0].id).assertEqual(2);
      expect(mutation.adds.length).assertEqual(0);
      expect(settled.lastFullSnapshotAt).assertEqual(1000);
    });

    it('does not emit periodic records for unchanged frames across a long idle interval', 0, () => {
      const operations = newOperations(3000);
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      for (const timestamp of [4000, 7000, 10000, 61000]) {
        commit.snapshot = fullSnapshot(timestamp, 0);
        const unchanged = operations.process('automatic', commit);
        expect(unchanged.records.length).assertEqual(0);
        expect(unchanged.payload).assertEqual('');
        expect(unchanged.lastFullSnapshotAt).assertEqual(1000);
        expect(unchanged.stored).assertTrue();
      }
      commit.snapshot = fullSnapshot(61100, 5);
      const changed = operations.process('automatic', commit);
      expect(changed.records.length).assertEqual(1);
      expect(changed.records[0].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      commit.snapshot = fullSnapshot(61200, 10);
      const mutation = operations.process('automatic', commit);
      expect(mutation.records[0].type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      expect((mutation.records[0].data as ReplayMutationData).updates[0].x).assertEqual(10);
    });

    it('uses visual diff equivalence without advancing the baseline during comparison', 0, () => {
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(fullSnapshot(1000, 0));
      const equivalent = fullSnapshot(4000, 0);
      (equivalent.data as FullSnapshotData).wireframes[1].clip = { top: 0, right: 0, bottom: 0, left: 0 };
      expect(processor.diffMutationRecord(equivalent) === null).assertTrue();
      const changed = fullSnapshot(4100, 10);
      expect(processor.diffMutationRecord(changed) !== null).assertTrue();
      expect(processor.diffMutationRecord(changed) !== null).assertTrue();
      processor.setFullSnapshotBaseline(changed);
      expect(processor.diffMutationRecord(changed) === null).assertTrue();
      const operations = newOperations(3000);
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      commit.snapshot = equivalent;
      expect(operations.process('automatic', commit).records.length).assertEqual(0);
    });

    it('retains explicit full and viewport checkpoints for otherwise identical content', 0, () => {
      const operations = newOperations(3000);
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      commit.snapshot = fullSnapshot(4000, 0);
      expect(operations.process('full', commit).records[0].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      commit.snapshot = fullSnapshot(4100, 0);
      commit.viewport = { width: 100, height: 80 };
      const resized = operations.process('automatic', commit);
      expect(resized.records.length).assertEqual(2);
      expect(resized.records[1].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
    });

    it('keeps queued frames incremental when UI checkpoint hints are stale', 0, () => {
      const operations = newOperations();
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      commit.snapshot = fullSnapshot(1100, 5);
      const next = operations.process('automatic', commit);
      expect(next.records.length).assertEqual(1);
      expect(next.records[0].type).assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      expect((next.records[0].data as ReplayMutationData).source).assertEqual(0);
      expect(next.lastFullSnapshotAt).assertEqual(1000);
      commit.snapshot = fullSnapshot(1200, 10);
      const following = operations.process('automatic', commit);
      expect(following.records.length).assertEqual(1);
      expect((following.records[0].data as ReplayMutationData).updates[0].x).assertEqual(10);
    });

    it('writes one resize checkpoint and one periodic checkpoint despite stale hints', 0, () => {
      const operations = newOperations();
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      commit.viewport = { width: 100, height: 80 };
      commit.snapshot = fullSnapshot(1100, 5);
      const resize = operations.process('automatic', commit);
      expect(resize.records.length).assertEqual(2);
      expect(resize.records[1].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      commit.snapshot = fullSnapshot(1200, 10);
      const motion = operations.process('automatic', commit);
      expect(motion.records.length).assertEqual(1);
      expect((motion.records[0].data as ReplayMutationData).source).assertEqual(0);
      commit.snapshot = fullSnapshot(31100, 15);
      const periodic = operations.process('automatic', commit);
      expect(periodic.records.length).assertEqual(1);
      expect(periodic.records[0].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      commit.snapshot = fullSnapshot(31200, 20);
      const after = operations.process('automatic', commit);
      expect(after.records.length).assertEqual(1);
      expect((after.records[0].data as ReplayMutationData).source).assertEqual(0);
      expect(after.lastFullSnapshotAt).assertEqual(31100);
    });

    it('syncs manual checkpoints and overlaid viewport with the automatic baseline', 0, () => {
      const operations = newOperations();
      const commit = automaticCommit(1000, 0);
      operations.process('start', commit);
      const manual = fullSnapshot(30000, 5);
      const viewport: ReplayViewport = { width: 100, height: 80 };
      expect(operations.appendRecords(commit.context, [manual], 'none', false, manual, viewport)).assertTrue();
      // The caller can mutate its object after handoff without changing the
      // Worker's accepted viewport.
      viewport.height = 60;
      commit.viewport = { width: 100, height: 80 };
      commit.snapshot = fullSnapshot(31100, 10);
      const automatic = operations.process('automatic', commit);
      expect(automatic.records.length).assertEqual(1);
      expect((automatic.records[0].data as ReplayMutationData).source).assertEqual(0);
      expect(automatic.lastFullSnapshotAt).assertEqual(30000);
      const latest = fullSnapshot(31200, 15);
      const processor = new ReplaySnapshotProcessor();
      processor.setFullSnapshotBaseline(commit.snapshot);
      const mutation = processor.createMutationRecord(latest)!;
      expect(operations.appendRecords(commit.context, [mutation], 'none', false, latest,
        { width: 100, height: 80 })).assertTrue();
      commit.snapshot = fullSnapshot(31300, 20);
      const mixed = operations.process('automatic', commit);
      expect((mixed.records[0].data as ReplayMutationData).updates[0].x).assertEqual(20);
      expect(mixed.lastFullSnapshotAt).assertEqual(30000);
    });

    it('still checkpoints after Worker restart or context change', 0, () => {
      const commit = automaticCommit(1000, 0);
      const first = newOperations();
      first.process('start', commit);
      const restarted = newOperations();
      commit.previousViewport = commit.viewport;
      commit.lastFullSnapshotAt = 1000;
      commit.snapshot = fullSnapshot(1100, 5);
      const recovery = restarted.process('automatic', commit);
      expect(recovery.records[0].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
      commit.snapshot = fullSnapshot(1200, 10);
      expect(restarted.process('automatic', commit).records[0].type)
        .assertEqual(ReplayRecordType.INCREMENTAL_SNAPSHOT);
      commit.context = { applicationId: 'app', sessionId: 'session', viewId: 'next-view' };
      commit.snapshot = fullSnapshot(1300, 15);
      expect(restarted.process('automatic', commit).records[0].type).assertEqual(ReplayRecordType.FULL_SNAPSHOT);
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

    it('starts immediately and matches HarmonyOS adaptive and retry delays', 0, () => {
      const failed: ReplayUploadOutcome = {
        success: false, retryable: true, endpointBlocked: false
      };
      expect(replayInitialUploadDelayMs(2500)).assertEqual(0);
      expect(replayInitialUploadDelayMs(0)).assertEqual(-1);
      const first = nextReplayUploadSchedule(2500, 0, failed);
      expect(first.delayMs).assertEqual(2500);
      const second = nextReplayUploadSchedule(first.delayMs, first.retryCount, failed);
      expect(second.delayMs).assertEqual(5000);
      const third = nextReplayUploadSchedule(second.delayMs, second.retryCount, failed);
      expect(third.delayMs).assertEqual(10000);
      const fourth = nextReplayUploadSchedule(third.delayMs, third.retryCount, failed);
      expect(fourth.delayMs).assertEqual(20000);
      const capped = nextReplayUploadSchedule(fourth.delayMs, fourth.retryCount, failed);
      expect(capped.delayMs).assertEqual(30000);
      const stillCapped = nextReplayUploadSchedule(capped.delayMs, capped.retryCount, failed);
      expect(stillCapped.delayMs).assertEqual(30000);
      const blocked: ReplayUploadOutcome = {
        success: false, retryable: false, endpointBlocked: true
      };
      const waitingForUrl = nextReplayUploadSchedule(capped.delayMs, capped.retryCount, blocked);
      expect(waitingForUrl.delayMs).assertEqual(5000);
      expect(waitingForUrl.retryCount).assertEqual(0);
      failed.success = true;
      failed.retryable = false;
      const recovered = nextReplayUploadSchedule(third.delayMs, third.retryCount, failed);
      expect(recovered.delayMs).assertEqual(9000);
      expect(recovered.retryCount).assertEqual(0);
      const success = nextReplayUploadSchedule(2500, 0, failed);
      expect(success.delayMs).assertEqual(2250);
      expect(nextReplayUploadSchedule(success.delayMs, 0, null).delayMs).assertEqual(2475);
      expect(nextReplayUploadSchedule(500, 0, failed).delayMs).assertEqual(500);
      expect(nextReplayUploadSchedule(5000, 0, null).delayMs).assertEqual(5000);
    });

    it('matches HarmonyOS network and battery upload gates', 0, () => {
      expect(canStartReplayUpload(null, true)).assertTrue();
      expect(canStartReplayUpload(true, true)).assertTrue();
      expect(canStartReplayUpload(false, true)).assertFalse();
      expect(canStartReplayUpload(true, false)).assertFalse();
      expect(isReplayBatteryHealthy({
        batterySOC: 21, chargingStatus: 0, pluggedType: 0, isBatteryPresent: true
      })).assertTrue();
      expect(isReplayBatteryHealthy({
        batterySOC: 20, chargingStatus: 0, pluggedType: 0, isBatteryPresent: true
      })).assertFalse();
      expect(isReplayBatteryHealthy({
        batterySOC: 1, chargingStatus: 0, pluggedType: 1, isBatteryPresent: true
      })).assertTrue();
      expect(isReplayBatteryHealthy({
        batterySOC: 1, chargingStatus: 3, pluggedType: 0, isBatteryPresent: true
      })).assertTrue();
      expect(isReplayBatteryHealthy({
        batterySOC: 1, chargingStatus: 0, pluggedType: 0, isBatteryPresent: false
      })).assertTrue();
    });
  });
}
