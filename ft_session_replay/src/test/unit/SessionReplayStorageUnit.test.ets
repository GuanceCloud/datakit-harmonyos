import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { describe, beforeEach, afterEach, expect, it } from '@ohos/hypium';
import { FullSnapshotData, ReplayMetaData, ReplayMutationData, ReplayPlaceholderWireframe, ReplayRecordType, SessionReplayContext, SessionReplayRecord } from '../../main/ets/components/SessionReplayProtocol';
import { ReplaySnapshotProcessor } from '../../main/ets/components/ReplaySnapshotProcessor';
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

function checkpoint(timestamp: number, label: string, x: number = 0): SessionReplayRecord {
  const wireframe: ReplayPlaceholderWireframe = {
    id: 1, x, y: 0, width: 100, height: 100, type: 'placeholder', label
  };
  const data: FullSnapshotData = { wireframes: [wireframe] };
  return { timestamp, type: ReplayRecordType.FULL_SNAPSHOT, data };
}

function assertStoredState(store: SessionReplaySegmentStore, viewId: string, label: string, x: number): void {
  let current: ReplayPlaceholderWireframe | null = null;
  for (const segment of store.list()) {
    if (segment.context.viewId !== viewId) continue;
    for (const record of segment.records) {
      if (record.type === ReplayRecordType.FULL_SNAPSHOT) {
        const data = record.data as FullSnapshotData;
        current = JSON.parse(JSON.stringify(data.wireframes[0])) as ReplayPlaceholderWireframe;
      } else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT) {
        const data = record.data as ReplayMutationData;
        if (data.source !== 0) continue;
        // Replaying any mutation without its checkpoint would be corrupt.
        expect(current !== null).assertTrue();
        for (const update of data.updates) {
          if (update.x !== undefined) current!.x = update.x;
          if (update.label !== undefined) current!.label = update.label;
        }
      }
    }
  }
  expect(current !== null).assertTrue();
  expect(current!.label).assertEqual(label);
  expect(current!.x).assertEqual(x);
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

    it('publishes only ready segment files and migrates legacy batches', 0, () => {
      const store = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 10);
      expect(store.append(replayContext(), [replayRecord()])).assertTrue();
      const names = fs.listFileSync(store.getRoot());
      expect(names.length).assertEqual(1);
      expect(names[0].endsWith('.ready')).assertTrue();
      expect(names[0].endsWith('.writing')).assertFalse();
      const legacy = names[0].substring(0, names[0].length - '.ready'.length) + '.json';
      fs.renameSync(`${store.getRoot()}/${names[0]}`, `${store.getRoot()}/${legacy}`);
      const recovered = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 10);
      expect(recovered.list().length).assertEqual(1);
      expect(fs.listFileSync(recovered.getRoot())[0].endsWith('.ready')).assertTrue();
    });

    it('retains checkpoint and mutation dependencies when trimming and promoting an error window', 0, () => {
      const source = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 1, 'error');
      const destination = new SessionReplaySegmentStore(testRoot, 1024 * 1024, 1);
      const context = replayContext();
      const processor = new ReplaySnapshotProcessor();
      const first = checkpoint(1000, 'first');
      processor.setFullSnapshotBaseline(first);
      expect(source.append(context, [first])).assertTrue();
      const beforeWindow = checkpoint(2000, 'before-window');
      expect(source.append(context, [processor.createMutationRecord(beforeWindow)!])).assertTrue();
      const latest = checkpoint(4000, 'before-window', 20);
      expect(source.append(context, [processor.createMutationRecord(latest)!])).assertTrue();

      source.pruneBefore(3000);
      assertStoredState(source, context.viewId, 'before-window', 20);
      expect(source.promoteSessionWindow(context.sessionId, 5000, 2000, destination)).assertTrue();
      assertStoredState(destination, context.viewId, 'before-window', 20);
      expect(source.list().length).assertEqual(0);
    });

    it('rejects an orphan mutation during quota eviction and recovers without changing another View', 0, () => {
      const quota = 1024 * 1024;
      const store = new SessionReplaySegmentStore(testRoot, quota, 100);
      const context = replayContext();
      const processor = new ReplaySnapshotProcessor();
      const firstLabel = 'a'.repeat(600000);
      const first = checkpoint(1000, firstLabel);
      processor.setFullSnapshotBaseline(first);
      expect(store.append(context, [first])).assertTrue();
      const next = checkpoint(2000, firstLabel, 10);
      expect(store.append(context, [processor.createMutationRecord(next)!])).assertTrue();
      const other: SessionReplayContext = {
        applicationId: context.applicationId, sessionId: context.sessionId, viewId: 'other-view'
      };
      expect(store.append(other, [checkpoint(2000, 'other')])).assertTrue();

      const latestLabel = 'b'.repeat(600000);
      const latest = checkpoint(3000, latestLabel, 10);
      expect(store.append(context, [processor.createMutationRecord(latest)!])).assertFalse();
      assertStoredState(store, context.viewId, firstLabel, 10);
      expect(store.append(context, [latest])).assertTrue();
      assertStoredState(store, context.viewId, latestLabel, 10);
      assertStoredState(store, other.viewId, 'other', 0);

      let used = 0;
      for (const name of fs.listFileSync(store.getRoot())) used += fs.statSync(`${store.getRoot()}/${name}`).size;
      expect(used <= quota).assertTrue();
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
      const metadataNames = fs.listFileSync(`${root}/pending`);
      expect(metadataNames.length).assertEqual(1);
      expect(metadataNames[0].endsWith('.ready')).assertTrue();
      expect(metadataNames[0].endsWith('.writing')).assertFalse();
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
