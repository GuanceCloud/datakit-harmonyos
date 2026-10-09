import { describe, it, expect } from '@ohos/hypium';
import { FTCacheEnvelope, FTCacheFiles, FTCacheMutation } from '../../main/ets/components/db/FTCacheFiles';
import { FTRumFileStore, FTRumStoreAccess } from '../../main/ets/components/db/FTRumFileStore';
import { FTDBTaskPoolRumCounterDeltaDTO } from '../../main/ets/components/db/FTDBTaskPoolExecutor';
import { ViewBeanJSON } from '../../main/ets/components/db/bean/ViewBean';
import { ActionBeanJSON } from '../../main/ets/components/db/bean/ActionBean';
import { FTSessionReplayBridgeRegistry, FTSessionReplayRUMContext, FTSessionReplayViewMetadata } from '../../main/ets/components/sessionreplay/FTSessionReplayBridge';

interface CacheGovernanceReplayProperty {
  value: string;
}

class MemoryAggregateAccess implements FTRumStoreAccess {
  readonly records: Map<string, string> = new Map<string, string>();
  acceptWrites: boolean = true;
  path(kind: string, id: string): string { return `${kind}/${id}`; }
  read(kind: string, id: string): string | null { return this.records.get(this.path(kind, id)) || null; }
  list(kind: string): string[] {
    const ids: string[] = [];
    this.records.forEach((_value: string, key: string) => {
      if (key.startsWith(`${kind}/`)) { ids.push(key.substring(kind.length + 1)); }
    });
    return ids;
  }
  async commit(changes: FTCacheMutation[]): Promise<boolean> {
    if (!this.acceptWrites) { return false; }
    for (const change of changes) {
      if (change.body === null) { this.records.delete(change.path); }
      else { this.records.set(change.path, change.body); }
    }
    return true;
  }
}

function newView(): ViewBeanJSON {
  return { id: 'v', viewName: 'view', viewReferrer: '', startTime: 1, isClose: false, sessionId: 's',
    actionCount: 0, errorCount: 0, longTaskCount: 0, viewLoadTime: 0, timeSpent: 0,
    resourceCount: 0, pendingResource: 0, dataUpdateTime: 1, dataUploadTime: 0, viewUpdateTime: 0,
    extraAttr: {}, property: {}, tags: {} };
}

function newAction(id: string = 'a', viewId: string = 'v'): ActionBeanJSON {
  return {
    id, startTime: 1, actionDuration: 0, isClose: false, errorCount: 0,
    longTaskCount: 0, resourceCount: 0, pendingResource: 0, sessionId: 's',
    viewName: 'view', viewId, viewReferrer: '', actionName: 'tap',
    actionType: 'click', extraAttr: {}
  };
}

function replayContext(viewId: string = 'v'): FTSessionReplayRUMContext {
  return { applicationId: 'app', sessionId: 's', viewId,
    viewName: 'view', viewReferrer: '', linkContext: {}, timestamp: 1 };
}

export default function cacheGovernanceUnitTest() {
  describe('CacheGovernanceUnitTest', () => {
    it('keeps a closed View until delayed Replay metadata can create its final summary', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      await store.execute({ command: 'upsertRumView', view: newView() });
      await store.execute({ command: 'closeRumView', viewId: 'v', now: 100 });
      const summary = (await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view!;
      const completeCapture = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      let acknowledged = false;
      const acknowledge = FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'v').then(async () => {
        acknowledged = true;
        return (await store.execute({ command: 'acknowledgeView', view: summary })).value;
      });
      await Promise.resolve();
      expect(acknowledged).assertFalse();
      // The first frame finishes before the separate RUM metadata write.
      const completeMetadata = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      completeCapture();
      await Promise.resolve();
      expect(acknowledged).assertFalse();
      await store.execute({ command: 'updateRumViewReplay', viewId: 'v', replaySessionId: 's',
        replayMetadata: { hasReplay: true, recordsCount: 4, sampledOnError: false }, now: 101 });
      completeMetadata();
      expect(await acknowledge).assertFalse();
      const finalSummary = (await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view!;
      expect(finalSummary.hasReplay).assertTrue();
      expect(finalSummary.recordsCount).assertEqual(4);
      expect(finalSummary.viewUpdateTime > summary.viewUpdateTime).assertTrue();
      expect((await store.execute({ command: 'acknowledgeView', view: finalSummary })).value).assertTrue();
      expect((await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view).assertNull();
    });

    it('releases a failed capture without fabricating Replay on its closed View', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      await store.execute({ command: 'upsertRumView', view: newView() });
      await store.execute({ command: 'closeRumView', viewId: 'v', now: 100 });
      const summary = (await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view!;
      const completeCapture = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      const acknowledge = FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'v').then(async () => {
        return (await store.execute({ command: 'acknowledgeView', view: summary })).value;
      });
      expect(summary.hasReplay === true).assertFalse();
      completeCapture();
      completeCapture();
      expect(await acknowledge).assertTrue();
      expect((await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view).assertNull();
    });

    it('waits for the original View End without blocking other Views or sessions', 0, async () => {
      const completeCapture = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      const completeViewEnd = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      let drained = false;
      const wait = FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'v').then(() => { drained = true; });
      await FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'other');
      await FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 'other-session', 'v');
      await FTSessionReplayBridgeRegistry.waitForViewPersistence('other-app', 's', 'v');
      completeCapture();
      await Promise.resolve();
      expect(drained).assertFalse();
      completeViewEnd();
      await wait;
      expect(drained).assertTrue();
    });

    it('SDK reset releases old waits and isolates completion from new work with the same identity', 0, async () => {
      const provider = (): FTSessionReplayRUMContext | null => null;
      FTSessionReplayBridgeRegistry.bindRUMCallbacks(provider,
        (_context: FTSessionReplayRUMContext, _metadata: FTSessionReplayViewMetadata): void => {});
      const finishOld = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      const oldWait = FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'v');
      FTSessionReplayBridgeRegistry.clearRUMCallbacks(provider);
      const finishNew = FTSessionReplayBridgeRegistry.beginViewPersistence(replayContext());
      await oldWait;
      let drained = false;
      const newWait = FTSessionReplayBridgeRegistry.waitForViewPersistence('app', 's', 'v').then(() => { drained = true; });
      finishOld();
      await Promise.resolve();
      expect(drained).assertFalse();
      finishNew();
      await newWait;
      expect(drained).assertTrue();
    });

    it('encodes UTF-8 physical bytes with a verifiable envelope', 0, () => {
      const body = '缓存';
      const envelope = JSON.parse(FTCacheFiles.encode(body)) as FTCacheEnvelope;
      expect(FTCacheFiles.bytes(body)).assertEqual(6);
      expect(FTCacheFiles.bytes('A你😀')).assertEqual(8);
      expect(FTCacheFiles.bytes('\uD800')).assertEqual(3);
      expect(envelope.version).assertEqual(1);
      expect(envelope.body).assertEqual(body);
      expect(envelope.checksum).assertEqual(FTCacheFiles.checksum(body));
      expect(envelope.checksum === FTCacheFiles.checksum(`${body}!`)).assertFalse();
    });

    it('retains a closed view until its latest version reaches the sync queue', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      await store.execute({ command: 'upsertRumView', view: newView() });
      await store.execute({ command: 'closeRumView', viewId: 'v', now: 100 });
      expect((await store.execute({ command: 'cleanCloseViewData', now: 100 })).count).assertEqual(0);
      await store.execute({ command: 'updateViewUploadTime', viewId: 'v', dateTime: 99 });
      expect((await store.execute({ command: 'cleanCloseViewData', now: 100 })).count).assertEqual(0);
      await store.execute({ command: 'updateViewUploadTime', viewId: 'v', dateTime: 100 });
      expect((await store.execute({ command: 'cleanCloseViewData', now: 100 })).count).assertEqual(1);
      expect(access.list('view').length).assertEqual(0);
    });

    it('acknowledges only the current view snapshot and removes a closed view', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      await store.execute({ command: 'upsertRumView', view });
      const stale = JSON.parse(JSON.stringify(view)) as ViewBeanJSON;
      await store.execute({ command: 'closeRumView', viewId: view.id, now: 100 });
      expect((await store.execute({ command: 'acknowledgeView', view: stale })).value).assertFalse();
      expect((await store.execute({ command: 'queryRumViewById', viewId: view.id })).view?.isClose).assertTrue();
      const current = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(current !== null && current !== undefined).assertTrue();
      expect((await store.execute({ command: 'acknowledgeView', view: current! })).value).assertTrue();
      expect((await store.execute({ command: 'queryRumViewById', viewId: view.id })).view).assertNull();
    });

    it('retains committed Action Replay after the original View is removed', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      const action = newAction();
      action.hasReplay = false;
      action.errorCount = 2;
      const custom: CacheGovernanceReplayProperty = { value: 'preserved' };
      action.extraAttr = { custom };
      await store.execute({ command: 'upsertRumView', view });
      await store.execute({ command: 'insertRumAction', actionBean: action });
      expect((await store.execute({
        command: 'updateRumViewReplay', viewId: view.id, replaySessionId: view.sessionId,
        replayMetadata: { hasReplay: true, recordsCount: 4, sampledOnError: false }, now: 100
      })).value).assertTrue();
      await store.execute({ command: 'closeRumView', viewId: view.id, now: 101 });
      const closed = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      await store.execute({ command: 'acknowledgeView', view: closed! });
      expect((await store.execute({ command: 'queryRumViewById', viewId: view.id })).view).assertNull();
      await store.execute({ command: 'closeRumAction', actionId: action.id, duration: 1380000000 });
      const restored = (await new FTRumFileStore(access).execute({ command: 'querySumAction' })).actions!;
      expect(restored.length).assertEqual(1);
      expect(restored[0].hasReplay).assertTrue();
      expect(restored[0].actionDuration).assertEqual(1380000000);
      expect(restored[0].errorCount).assertEqual(2);
      expect(JSON.stringify(restored[0].extraAttr)).assertEqual(JSON.stringify(action.extraAttr));
    });

    it('promotes only original Actions even when the View row is already gone', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const original = newAction('original');
      const otherSession = newAction('other-session');
      otherSession.sessionId = 'other-s';
      const otherView = newAction('other-view', 'other-v');
      for (const action of [original, otherSession, otherView]) {
        access.records.set(access.path('action', action.id), JSON.stringify(action));
      }
      expect((await store.execute({
        command: 'updateRumViewReplay', viewId: 'v', replaySessionId: 's',
        replayMetadata: { hasReplay: true, recordsCount: 4, sampledOnError: false }
      })).value).assertTrue();
      const restored = (await store.execute({ command: 'exportRumState' })).actions!;
      expect(restored.find((a: ActionBeanJSON) => a.id === 'original')!.hasReplay).assertTrue();
      expect(restored.find((a: ActionBeanJSON) => a.id === 'other-session')!.hasReplay === true).assertFalse();
      expect(restored.find((a: ActionBeanJSON) => a.id === 'other-view')!.hasReplay === true).assertFalse();
      expect((await store.execute({
        command: 'updateRumViewReplay', viewId: 'v', replaySessionId: 's',
        replayMetadata: { hasReplay: true, recordsCount: 4, sampledOnError: false }
      })).value).assertFalse();
    });

    it('rejects invalid or uncommitted Replay without changing stored Actions', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const action = newAction();
      access.records.set(access.path('action', action.id), JSON.stringify(action));
      for (const count of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
        expect((await store.execute({
          command: 'updateRumViewReplay', viewId: 'v', replaySessionId: 's',
          replayMetadata: { hasReplay: true, recordsCount: count, sampledOnError: false }
        })).value).assertFalse();
      }
      expect((await store.execute({
        command: 'updateRumViewReplay', viewId: 'v', replaySessionId: 's',
        replayMetadata: { hasReplay: false, recordsCount: 4, sampledOnError: false }
      })).value).assertFalse();
      expect(access.read('action', action.id)).assertEqual(JSON.stringify(action));
    });

    it('commits Replay View and Action promotion together or keeps both unchanged', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      const action = newAction();
      await store.execute({ command: 'upsertRumView', view });
      await store.execute({ command: 'insertRumAction', actionBean: action });
      const viewBefore = access.read('view', view.id);
      const actionBefore = access.read('action', action.id);
      access.acceptWrites = false;
      let rejected = false;
      try {
        await store.execute({
          command: 'updateRumViewReplay', viewId: view.id, replaySessionId: view.sessionId,
          replayMetadata: { hasReplay: true, recordsCount: 4, sampledOnError: false }
        });
      } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
      expect(access.read('view', view.id)).assertEqual(viewBefore);
      expect(access.read('action', action.id)).assertEqual(actionBefore);
    });

    it('keeps a recovered closed view until its Error counter is re-emitted', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      await store.execute({ command: 'upsertRumView', view });
      await store.execute({ command: 'closeRumView', viewId: view.id, now: 100 });
      const closed = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(closed !== null && closed !== undefined).assertTrue();

      // Recovery acknowledges the predecessor View draft, but must retain its
      // aggregate row until the historical Error has incremented it.
      expect((await store.execute({
        command: 'acknowledgeView', view: closed!, keepClosedView: true
      })).value).assertTrue();
      const retained = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(retained !== null && retained !== undefined).assertTrue();

      const errorDelta: FTDBTaskPoolRumCounterDeltaDTO = {
        viewId: view.id, actionId: '', viewActionDelta: 0, viewErrorDelta: 1,
        viewLongTaskDelta: 0, viewResourceDelta: 0, viewPendingDelta: 0,
        viewUpdateTimeDelta: 1, actionErrorDelta: 0, actionLongTaskDelta: 0,
        actionResourceDelta: 0, actionPendingDelta: 0
      };
      await store.execute({ command: 'applyRumCounterDeltas', counterDeltas: [errorDelta], now: 101 });
      const refreshed = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(refreshed!.errorCount).assertEqual(1);
      expect((await store.execute({ command: 'querySumView', limit: 10 })).views?.length).assertEqual(1);
      expect((await store.execute({ command: 'acknowledgeView', view: refreshed! })).value).assertTrue();
      expect((await store.execute({ command: 'queryRumViewById', viewId: view.id })).view).assertNull();
    });

    it('keeps a closed view with pending resources after acknowledgement', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      view.isClose = true;
      view.pendingResource = 1;
      await store.execute({ command: 'upsertRumView', view });
      expect((await store.execute({ command: 'acknowledgeView', view })).value).assertTrue();
      const retained = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(retained !== null && retained !== undefined).assertTrue();
      expect(retained!.dataUploadTime).assertEqual(0);
      expect(retained!.viewUpdateTime).assertEqual(1);
    });

    it('persists aggregate deltas and clamps pending resources to zero', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      await store.execute({ command: 'upsertRumView', view: newView() });
      const delta: FTDBTaskPoolRumCounterDeltaDTO = { viewId: 'v', actionId: '', viewActionDelta: 2,
        viewErrorDelta: 1, viewLongTaskDelta: 0, viewResourceDelta: 3, viewPendingDelta: -4,
        viewUpdateTimeDelta: 1, actionErrorDelta: 0, actionLongTaskDelta: 0,
        actionResourceDelta: 0, actionPendingDelta: 0 };
      await store.execute({ command: 'applyRumCounterDeltas', counterDeltas: [delta], now: 50 });
      const result = await new FTRumFileStore(access).execute({ command: 'queryRumViewById', viewId: 'v' });
      expect(result.view?.actionCount).assertEqual(2);
      expect(result.view?.resourceCount).assertEqual(3);
      expect(result.view?.pendingResource).assertEqual(0);
      expect(result.view?.dataUpdateTime).assertEqual(50);
    });

    it('commits an Action and its View action count together', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      await store.execute({ command: 'upsertRumView', view: newView() });

      expect((await store.execute({ command: 'insertRumAction', actionBean: newAction(), now: 99 })).value).assertTrue();
      const view = (await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view;
      expect(view?.actionCount).assertEqual(1);
      expect(view?.viewUpdateTime).assertEqual(1);
      expect(view?.dataUpdateTime).assertEqual(99);
      expect(access.list('action').length).assertEqual(1);

      // The duplicate is rejected before any View mutation, so retrying a
      // recovered Action cannot double-count its owning View.
      expect((await store.execute({ command: 'insertRumAction', actionBean: newAction(), now: 100 })).value).assertFalse();
      const afterDuplicate = (await store.execute({ command: 'queryRumViewById', viewId: 'v' })).view;
      expect(afterDuplicate?.actionCount).assertEqual(1);
      expect(afterDuplicate?.viewUpdateTime).assertEqual(1);
    });

    it('marks a closed uploaded View as changed when an Action arrives in the same millisecond', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      const view = newView();
      view.isClose = true;
      view.dataUpdateTime = 99;
      view.dataUploadTime = 99;
      await store.execute({ command: 'upsertRumView', view });

      expect((await store.execute({ command: 'insertRumAction', actionBean: newAction(), now: 99 })).value).assertTrue();
      const refreshed = (await store.execute({ command: 'queryRumViewById', viewId: view.id })).view;
      expect(refreshed!.dataUpdateTime).assertEqual(100);
      expect((await store.execute({ command: 'querySumView', limit: 10 })).views?.length).assertEqual(1);
    });

    it('rejects an Action with an unavailable owning View without persisting either side', 0, async () => {
      const access = new MemoryAggregateAccess();
      const store = new FTRumFileStore(access);
      expect((await store.execute({ command: 'insertRumAction', actionBean: newAction() })).value).assertFalse();
      expect(access.list('action').length).assertEqual(0);
    });

    it('does not report aggregate success when capacity admission fails', 0, async () => {
      const access = new MemoryAggregateAccess();
      access.acceptWrites = false;
      let rejected = false;
      try { await new FTRumFileStore(access).execute({ command: 'upsertRumView', view: newView() }); }
      catch (_) { rejected = true; }
      expect(rejected).assertTrue();
      expect(access.list('view').length).assertEqual(0);
    });
  });
}
