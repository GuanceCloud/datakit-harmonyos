import { describe, it, expect } from '@ohos/hypium';
import { FTCacheEnvelope, FTCacheFiles, FTCacheMutation } from '../../main/ets/components/db/FTCacheFiles';
import { FTRumFileStore, FTRumStoreAccess } from '../../main/ets/components/db/FTRumFileStore';
import { FTDBTaskPoolRumCounterDeltaDTO } from '../../main/ets/components/db/FTDBTaskPoolExecutor';
import { ViewBeanJSON } from '../../main/ets/components/db/bean/ViewBean';
import { ActionBeanJSON } from '../../main/ets/components/db/bean/ActionBean';

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

export default function cacheGovernanceUnitTest() {
  describe('CacheGovernanceUnitTest', () => {
    it('encodes UTF-8 physical bytes with a verifiable envelope', 0, () => {
      const body = '缓存';
      const envelope = JSON.parse(FTCacheFiles.encode(body)) as FTCacheEnvelope;
      expect(FTCacheFiles.bytes(body)).assertEqual(6);
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
