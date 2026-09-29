import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { describe, beforeEach, afterEach, expect, it } from '@ohos/hypium';
import { ReplayMetaData, ReplayRecordType, SessionReplayContext, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';
import { SessionReplayResourceStore } from '../../main/ets/components/SessionReplayResourceStore';
import { SessionReplaySegmentStore } from '../../main/ets/components/SessionReplaySegmentStore';

let testSequence: number = 0;

function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_) {
    return false;
  }
}

function removeTree(path: string): void {
  if (!exists(path)) {
    return;
  }
  if (!fs.statSync(path).isDirectory()) {
    fs.unlinkSync(path);
    return;
  }
  const names = fs.listFileSync(path);
  for (let index = 0; index < names.length; index++) {
    removeTree(`${path}/${names[index]}`);
  }
  fs.rmdirSync(path);
}

function replayContext(): SessionReplayContext {
  return { applicationId: 'storage-app', sessionId: 'storage-session', viewId: 'storage-view' };
}

function replayRecord(): SessionReplayRecord {
  const data: ReplayMetaData = { width: 100, height: 200 };
  return { timestamp: 1700000000000, type: ReplayRecordType.META, data };
}

export default function sessionReplayStorageUnitTest() {
  describe('SessionReplayStorageUnit', () => {
    let testRoot: string;

    beforeEach(() => {
      const context = AbilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      testRoot = `${context.filesDir}/ft_session_replay_storage_test_${Date.now()}_${testSequence++}`;
      fs.mkdirSync(testRoot);
    });

    afterEach(() => {
      removeTree(testRoot);
    });

    it('creates the segment hierarchy and recreates it before a later append', 0, () => {
      const store = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 10, 'segments_regression');
      const replayRoot = `${testRoot}/ft_session_replay`;
      expect(exists(replayRoot)).assertTrue();
      expect(exists(store.getRoot())).assertTrue();

      removeTree(replayRoot);
      expect(store.append(replayContext(), [replayRecord()])).assertTrue();
      expect(exists(replayRoot)).assertTrue();
      expect(exists(store.getRoot())).assertTrue();
      expect(store.list().length).assertEqual(1);
    });

    it('keeps batches from UI and Worker store instances in one directory', 0, () => {
      const uiStore = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 10);
      const workerStore = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 10);
      expect(uiStore.append(replayContext(), [replayRecord()])).assertTrue();
      expect(workerStore.append(replayContext(), [replayRecord()])).assertTrue();
      expect(uiStore.list().length).assertEqual(2);
    });

    it('creates resource data and metadata directories before persisting bytes', 0, () => {
      const store = new SessionReplayResourceStore(testRoot, 1024 * 1024, 'resources_regression');
      const root = store.getRoot();
      expect(exists(root)).assertTrue();
      expect(exists(`${root}/data`)).assertTrue();
      expect(exists(`${root}/pending`)).assertTrue();

      removeTree(`${testRoot}/ft_session_replay`);
      const resourceId = store.put(replayContext(), new Uint8Array([1, 2, 3]), 'image/png');
      expect(resourceId !== null).assertTrue();
      expect(exists(`${root}/data`)).assertTrue();
      expect(exists(`${root}/pending`)).assertTrue();
      expect(store.list().length).assertEqual(1);
    });

    it('retains resources referenced after an upload snapshot', 0, () => {
      const store = new SessionReplayResourceStore(testRoot, 1024 * 1024);
      const bytes = new Uint8Array([1, 2, 3]);
      expect(store.put(replayContext(), bytes, 'image/png') !== null).assertTrue();
      const id = store.list()[0].id;
      const uploadEpoch = store.getTouchEpoch();
      expect(store.wasTouchedAfter([id], uploadEpoch)).assertFalse();
      expect(store.put(replayContext(), bytes, 'image/png') !== null).assertTrue();
      expect(store.wasTouchedAfter([id], uploadEpoch)).assertTrue();
    });
  });
}
