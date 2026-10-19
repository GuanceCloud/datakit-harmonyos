import { describe, expect, it } from '@ohos/hypium';
import { ReplaySnapshotFilter } from '../../main/ets/components/ReplaySnapshotFilter';
import { ArkUIReplayLightSnapshot } from '../../main/ets/components/SessionReplayScene';
import { ReplayWorkerCapture } from '../../main/ets/components/SessionReplayWorkQueue';

function lightSnapshot(timestamp: number, x: number = 0): ArkUIReplayLightSnapshot {
  return { timestamp, vpToPxScale: 1, nodes: [{
    id: 1, x, y: 0, width: 100, height: 100, componentId: 'root', nodeType: 'Column',
    inspectorInfo: { backgroundColor: '#ffffff' }, shouldCaptureAsText: false,
    isRoot: true, usedTransformedPosition: false
  }] };
}

function captureContext(): ReplayWorkerCapture {
  return {
    context: { applicationId: 'app', sessionId: 'session', viewId: 'view' },
    viewport: { width: 100, height: 100 }, previousViewport: null,
    lastFullSnapshotAt: 1000, storeKind: 'main'
  };
}

export default function replaySnapshotFilterUnitTest(): void {
  describe('ReplaySnapshotFilterUnit', () => {
    it('filters unchanged acknowledged samples but periodically revalidates Worker state', 0, () => {
      const filter = new ReplaySnapshotFilter();
      const capture = captureContext();
      expect(filter.canSkip('automatic', lightSnapshot(1000), capture, 1, true)).assertFalse();
      filter.acknowledge(lightSnapshot(1000), capture, 1, filter.getRevision());
      const same = lightSnapshot(1500);
      same.collectionDurationMs = 20;
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertTrue();
      expect(filter.canSkip('automatic', lightSnapshot(1999), capture, 1, true)).assertTrue();
      expect(filter.canSkip('automatic', lightSnapshot(2000), capture, 1, true)).assertFalse();
      expect(filter.canSkip('automatic', lightSnapshot(999), capture, 1, true)).assertFalse();
      expect(filter.canSkip('automatic', lightSnapshot(1500, 10), capture, 1, true)).assertFalse();
    });

    it('retains lifecycle boundaries, motion, in-flight returns and context changes', 0, () => {
      const filter = new ReplaySnapshotFilter();
      const capture = captureContext();
      filter.acknowledge(lightSnapshot(1000), capture, 1, filter.getRevision());
      const same = lightSnapshot(1500);
      expect(filter.canSkip('start', same, capture, 1, true)).assertFalse();
      expect(filter.canSkip('full', same, capture, 1, true)).assertFalse();
      expect(filter.canSkip('transition', same, capture, 1, true)).assertFalse();
      expect(filter.canSkip('settled', same, capture, 1, true)).assertFalse();
      // A -> pending B -> A must not drop A just because the committed state is still A.
      expect(filter.canSkip('automatic', same, capture, 1, false)).assertFalse();
      expect(filter.canSkip('automatic', same, capture, 2, true)).assertFalse();
      same.hasActiveAnimations = true;
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertFalse();
      same.hasActiveAnimations = false;
      capture.viewport = { width: 100, height: 80 };
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertFalse();
      capture.viewport = { width: 100, height: 100 };
      capture.context.viewId = 'next-view';
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertFalse();
      capture.context.viewId = 'view';
      capture.context.globalContext = { theme: 'dark' };
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertFalse();
      capture.context.globalContext = undefined;
      capture.storeKind = 'error';
      expect(filter.canSkip('automatic', same, capture, 1, true)).assertFalse();
    });

    it('does not restore a stale cache after asynchronous resource updates or failures', 0, () => {
      const filter = new ReplaySnapshotFilter();
      const capture = captureContext();
      const snapshot = lightSnapshot(1000);
      const submittedRevision = filter.getRevision();
      filter.invalidate();
      filter.acknowledge(snapshot, capture, 1, submittedRevision);
      expect(filter.canSkip('automatic', lightSnapshot(1500), capture, 1, true)).assertFalse();
      filter.acknowledge(snapshot, capture, 1, filter.getRevision());
      snapshot.nodes[0].x = 10;
      expect(filter.canSkip('automatic', lightSnapshot(1500), capture, 1, true)).assertTrue();
      filter.invalidate();
      expect(filter.canSkip('automatic', lightSnapshot(1500), capture, 1, true)).assertFalse();
    });
  });
}
