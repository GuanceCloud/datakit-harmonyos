import { afterEach, beforeEach, describe, expect, it } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  FTSessionReplayConfig, FTSessionReplayRecorder, SessionReplayContext,
  SessionReplayResourceStore, SessionReplayStoredResource, SessionReplaySegmentStore
} from '@guancecloud/ft_session_replay';

function removeTree(path: string): void {
  if (!fs.accessSync(path)) return;
  if (!fs.statSync(path).isDirectory()) { fs.unlinkSync(path); return; }
  for (const name of fs.listFileSync(path)) removeTree(`${path}/${name}`);
  fs.rmdirSync(path);
}

export default function sessionReplayUploadStateTest(): void {
  describe('SessionReplayUploadStateTest', () => {
    let root: string = '';
    let recorder: FTSessionReplayRecorder | null = null;
    const context: SessionReplayContext = { applicationId: 'cleanup-test', sessionId: 'session', viewId: 'view' };
    beforeEach(() => {
      root = `${AbilityDelegatorRegistry.getAbilityDelegator().getAppContext().filesDir}/replay_cleanup_test_${Date.now()}`;
      fs.mkdirSync(root);
    });
    afterEach(async () => {
      if (recorder !== null) {
        recorder.stop();
        await recorder.drainWrites();
        recorder = null;
      }
      removeTree(root);
    });

    it('cleans stable resources through the native Worker while retaining only reused resources', 0, async () => {
      const resources = new SessionReplayResourceStore(root, 1024 * 1024);
      const first = resources.put(context, new Uint8Array([1]), 'image/png')!;
      resources.put(context, new Uint8Array([2]), 'image/png');
      const ids = resources.list().map((resource: SessionReplayStoredResource): string => resource.id);
      const epoch = resources.getTouchEpoch();
      resources.markTouched(first);
      recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig(),
        new SessionReplaySegmentStore(root, 1024 * 1024, 100));
      const result = await recorder.removeUploadedResources(ids,
        (id: string): boolean => !resources.wasTouchedAfter([id], epoch));
      expect(result.deletedResources).assertEqual(1);
      expect(result.deferredResources).assertEqual(1);
      expect(result.failedResources).assertEqual(0);
      expect(resources.list().length).assertEqual(1);
      expect(resources.list()[0].fileName).assertEqual(first);
      const drained = await recorder.removeUploadedResources(ids, (_id: string): boolean => true);
      expect(drained.failedResources).assertEqual(0);
      expect(resources.list().length).assertEqual(0);
    });

    it('retains shared bytes until both routes are acknowledged and tolerates repeated cleanup', 0, () => {
      const resources = new SessionReplayResourceStore(root, 1024 * 1024);
      const bytes = new Uint8Array([1, 2, 3]);
      resources.put(context, bytes, 'image/png');
      const tags: Record<string, string | number | boolean> = {};
      tags['wgt_id'] = 'other';
      const other: SessionReplayContext = {
        applicationId: context.applicationId, sessionId: context.sessionId, viewId: context.viewId,
        globalContext: tags
      };
      resources.put(other, bytes, 'image/png');
      const stored = resources.list();
      expect(stored.length).assertEqual(2);
      expect(resources.removeAcknowledged([stored[0].id]).failedResources).assertEqual(0);
      expect(resources.read(stored[1])!.byteLength).assertEqual(3);
      expect(resources.removeAcknowledged([stored[0].id, stored[1].id]).failedResources).assertEqual(0);
      expect(resources.removeAcknowledged([stored[1].id]).failedResources).assertEqual(0);
      expect(resources.list().length).assertEqual(0);
      expect(fs.listFileSync(`${resources.getRoot()}/data`).length).assertEqual(0);
    });

    it('reports a closed recorder explicitly without deleting resources', 0, async () => {
      const resources = new SessionReplayResourceStore(root, 1024 * 1024);
      resources.put(context, new Uint8Array([3]), 'image/png');
      const ids = resources.list().map((resource: SessionReplayStoredResource): string => resource.id);
      recorder = new FTSessionReplayRecorder(new FTSessionReplayConfig(),
        new SessionReplaySegmentStore(root, 1024 * 1024, 100));
      recorder.stop();
      const result = await recorder.removeUploadedResources(ids, (_id: string): boolean => true);
      expect(result.failedResources).assertEqual(1);
      expect(result.reason.indexOf('closing') >= 0).assertTrue();
      expect(resources.list().length).assertEqual(1);
    });
  });
}
