import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKDedicatedPoolManager
} from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolInputDTO,
  SDKRumCounterUpdateDTO,
  SDKRumEventDTO,
  SDKStringRecord,
  SDKUploadPageDTO,
  SDKUploadRowDTO,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest
} from '../../main/ets/components/thread/SDKWorkerProtocol';

interface ReleaseGate {
  promise: Promise<void>;
  release: () => void;
}

interface SDKLineProtocolRecordsTestPayload {
  records: SDKLineProtocolInputDTO[];
}

function createGate(): ReleaseGate {
  let release = (): void => {};
  const promise = new Promise<void>((resolve) => {
    release = () => resolve();
  });
  return { promise, release };
}

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 5; i++) {
    await Promise.resolve();
  }
}

async function waitUntil(predicate: () => boolean, maxTicks: number = 100): Promise<boolean> {
  for (let i = 0; i < maxTicks; i++) {
    await flushPromises();
    if (predicate()) {
      return true;
    }
  }
  return false;
}

function getPayloadString(payload: SDKWorkerPayload | undefined, key: string): string {
  const record = payload as Record<string, object>;
  if (!record || record[key] === undefined || record[key] === null) {
    return '';
  }
  return String(record[key]);
}

function getPayloadArray(payload: SDKWorkerPayload | undefined, key: string): object[] {
  const record = payload as Record<string, object>;
  if (!record || !Array.isArray(record[key])) {
    return [];
  }
  return record[key] as object[];
}

export default function sdkDedicatedPoolManagerUnitTest() {
  describe('SDKDedicatedPoolManagerUnit', () => {
    let manager: SDKDedicatedPoolManager;

    beforeEach(() => {
      SDKDedicatedPoolManager.resetInternal();
      manager = SDKDedicatedPoolManager.getInstance();
    });

    afterEach(() => {
      SDKDedicatedPoolManager.resetInternal();
    });

    it('eventConsumerPoolShouldRunSeriallyAndNotBlockLogPool', 0, async () => {
      const order: string[] = [];
      const eventGate = createGate();

      const firstEvent = manager.executeTask(
        SDKDedicatedPoolType.EVENT_CONSUMER,
        'event-1',
        'event.first',
        7,
        async () => {
          order.push('event-1-start');
          await eventGate.promise;
          order.push('event-1-end');
        }
      );

      const secondEvent = manager.executeTask(
        SDKDedicatedPoolType.EVENT_CONSUMER,
        'event-2',
        'event.second',
        7,
        () => {
          order.push('event-2');
        }
      );

      const logTask = manager.executeTask(
        SDKDedicatedPoolType.LOG_CONSUMER,
        'log-1',
        'log.independent',
        5,
        () => {
          order.push('log');
        }
      );

      await flushPromises();
      await logTask;
      expect(order.join(',')).assertEqual('event-1-start,log');

      eventGate.release();
      await firstEvent;
      await secondEvent;
      expect(order.join(',')).assertEqual('event-1-start,log,event-1-end,event-2');
      const status = manager.getStatus().pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(status.workerCount).assertEqual(1);
      expect(status.maxConcurrency).assertEqual(1);
    });

    it('eventConsumerPoolShouldSupportSamePoolReentry', 0, async () => {
      const order: string[] = [];

      await manager.executeEventReentrant('event.outer', async () => {
        order.push('outer-start');
        await manager.executeEventReentrant('event.inner', () => {
          order.push('inner');
        });
        order.push('outer-end');
      });

      expect(order.join(',')).assertEqual('outer-start,inner,outer-end');
      const status = manager.getStatus().pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(status.completedTasks).assertEqual(2);
      expect(status.pending).assertEqual(0);
      expect(status.running).assertEqual(0);
    });

    it('dataProcessPoolShouldUseConfiguredWorkerCountForParallelWork', 0, async () => {
      const workerCount = manager.getDataProcessWorkerCount();
      const order: string[] = [];
      const firstGate = createGate();
      const secondGate = createGate();

      const first = manager.executeTask(
        SDKDedicatedPoolType.DATA_PROCESS,
        'data-1',
        'data.first',
        3,
        async () => {
          order.push('first-start');
          await firstGate.promise;
          order.push('first-end');
        }
      );

      const second = manager.executeTask(
        SDKDedicatedPoolType.DATA_PROCESS,
        'data-2',
        'data.second',
        3,
        async () => {
          order.push('second-start');
          await secondGate.promise;
          order.push('second-end');
        }
      );

      await flushPromises();
      expect(workerCount >= 2).assertTrue();
      expect(order.join(',')).assertEqual('first-start,second-start');

      firstGate.release();
      secondGate.release();
      await first;
      await second;
      expect(order.join(',')).assertEqual('first-start,second-start,first-end,second-end');
    });

    it('dbWriteLaneShouldRunWritesSerially', 0, async () => {
      const order: string[] = [];
      const firstGate = createGate();

      const first = manager.runDbWrite('db.first', async () => {
        order.push('first-start');
        await firstGate.promise;
        order.push('first-end');
        return true;
      });

      const second = manager.runDbWrite('db.second', async () => {
        order.push('second');
        return true;
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      firstGate.release();
      await first;
      await second;
      expect(order.join(',')).assertEqual('first-start,first-end,second');
    });

    it('dataUploadPoolShouldCoalesceSchedulesWhileRunning', 0, async () => {
      const firstGate = createGate();
      let runCount = 0;
      const runner = async (): Promise<void> => {
        runCount++;
        if (runCount === 1) {
          await firstGate.promise;
        }
      };

      manager.scheduleDataUpload('upload.poll', runner, 0);
      await flushPromises();
      expect(manager.getUploadStatus().isRunning).assertTrue();

      manager.scheduleDataUpload('upload.poll', runner, 0);
      manager.scheduleDataUpload('upload.poll', runner, 0);
      expect(manager.getUploadStatus().needReschedule).assertTrue();

      firstGate.release();
      const completed = await waitUntil(() => runCount === 2 && !manager.getUploadStatus().isRunning);
      expect(completed).assertTrue();
      expect(runCount).assertEqual(2);
      expect(manager.getUploadStatus().isScheduled).assertFalse();
      expect(manager.getUploadStatus().needReschedule).assertFalse();
    });

    it('workerProtocolShouldRejectNonSerializablePayload', 0, async () => {
      let rejected = false;
      const request: SDKWorkerRequest = {
        id: 'bad-payload',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: 'bad.payload',
        priority: 3,
        createdAt: Date.now(),
        payload: new Map<string, string>() as object as SDKWorkerPayload
      };

      try {
        await manager.executeCommand(request, () => null);
      } catch (_) {
        rejected = true;
      }

      expect(rejected).assertTrue();
    });

    it('workerCommandShouldReturnPingPayloadWithFallbackAllowed', 0, async () => {
      const request: SDKWorkerRequest = {
        id: 'ping-data-process',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.PING,
        priority: 5,
        createdAt: Date.now(),
        payload: null
      };

      const response = await manager.executeCommand(request);
      expect(response.ok).assertTrue();
      expect(getPayloadString(response.payload, 'pool')).assertEqual(SDKDedicatedPoolType.DATA_PROCESS);
      expect(getPayloadString(response.payload, 'workerName').length > 0).assertTrue();
      expect(getPayloadString(response.payload, 'backend').length > 0).assertTrue();
    });

    it('extraWorkerPoolsShouldReturnIndependentPingPayloads', 0, async () => {
      const pools: SDKDedicatedPoolType[] = [
        SDKDedicatedPoolType.CRASH_FILE,
        SDKDedicatedPoolType.ANR,
        SDKDedicatedPoolType.BACKGROUND
      ];

      for (const pool of pools) {
        const response = await manager.executeCommand({
          id: `ping-${pool}`,
          pool,
          command: SDKWorkerCommand.PING,
          priority: 5,
          createdAt: Date.now(),
          payload: null
        });

        expect(response.ok).assertTrue();
        expect(getPayloadString(response.payload, 'pool')).assertEqual(pool);
        expect(getPayloadString(response.payload, 'workerName').length > 0).assertTrue();
      }

      const status = manager.getStatus().pools;
      expect(status[SDKDedicatedPoolType.CRASH_FILE].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.ANR].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.BACKGROUND].maxConcurrency).assertEqual(1);
    });

    it('dataProcessCommandShouldCreateLineProtocolDraftsFromDto', 0, async () => {
      const tags: SDKStringRecord = {};
      tags['sdk_data_id'] = 'uuid-1';
      tags['status'] = 'info';
      const fields: SDKStringRecord = {};
      fields['message'] = 'hello worker';
      fields['count'] = '3';
      const record: SDKLineProtocolInputDTO = {
        dataType: 'log',
        measurement: 'df_rum_harmonyos_log',
        tags,
        fields,
        time: 123,
        uuid: 'uuid-1'
      };
      const records: SDKLineProtocolInputDTO[] = [record];
      const payload: SDKLineProtocolRecordsTestPayload = {
        records
      };
      const request: SDKWorkerRequest = {
        id: 'line-protocol',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL,
        priority: 5,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      };

      const response = await manager.executeCommand(request);
      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'drafts');
      expect(drafts.length).assertEqual(1);
      const draft = drafts[0] as Record<string, object>;
      expect(String(draft['dataString']).includes('df_rum_harmonyos_log')).assertTrue();
      expect(String(draft['dataString']).includes('message=\"hello worker\"')).assertTrue();
      expect(String(draft['uuid'])).assertEqual('uuid-1');
    });

    it('eventRumCommandShouldCreateSyncDraftFromSerializableDto', 0, async () => {
      const tags: SDKStringRecord = {};
      tags['sdk_data_id'] = 'rum-uuid-1';
      tags['session_id'] = 'session-1';
      tags['view_id'] = 'view-1';
      tags['view_name'] = 'Home';
      const fields: SDKStringRecord = {};
      fields['duration'] = '42';
      fields['is_active'] = 'true';
      const rumEvent: SDKRumEventDTO = {
        eventType: 'view.start',
        name: 'Home',
        time: 456,
        dataType: 'rum_app',
        measurement: 'view',
        uuid: 'rum-uuid-1',
        viewId: 'view-1',
        viewName: 'Home',
        sessionId: 'session-1',
        tags,
        fields
      };
      const request: SDKWorkerRequest = {
        id: 'rum-dto',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: rumEvent as Object as SDKWorkerPayload
      };

      const response = await manager.executeCommand(request);
      expect(response.ok).assertTrue();
      expect(getPayloadString(response.payload, 'activeViewId')).assertEqual('view-1');
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const draft = drafts[0] as Record<string, object>;
      expect(String(draft['dataType'])).assertEqual('rum_app');
      expect(String(draft['uuid'])).assertEqual('rum-uuid-1');
      expect(String(draft['dataString']).includes('view')).assertTrue();
      expect(String(draft['dataString']).includes('sdk_data_id=rum-uuid-1')).assertTrue();
      expect(String(draft['dataString']).includes('duration=42i')).assertTrue();
    });

    it('eventRumCounterShouldBatchSerializableCounterUpdates', 0, async () => {
      const updates: SDKRumCounterUpdateDTO[] = [
        {
          updateType: 'resource.pending.increase',
          viewId: 'view-1',
          actionId: 'action-1'
        },
        {
          updateType: 'resource.complete',
          viewId: 'view-1',
          actionId: 'action-1'
        },
        {
          updateType: 'view.action',
          viewId: 'view-1'
        }
      ];

      for (let i = 0; i < updates.length; i++) {
        const update = updates[i];
        const response = await manager.executeCommand({
          id: `rum-counter-${i}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE,
          priority: 7,
          createdAt: Date.now(),
          payload: update as Object as SDKWorkerPayload
        });
        expect(response.ok).assertTrue();
      }

      const flushResponse = await manager.executeCommand({
        id: 'rum-counter-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      expect(flushResponse.ok).assertTrue();
      expect(getPayloadString(flushResponse.payload, 'needsActionCloseCheck')).assertEqual('true');
      const deltas = getPayloadArray(flushResponse.payload, 'deltas');
      expect(deltas.length).assertEqual(2);
      let resourceJoined = '';
      let viewActionDelta = '';
      for (let i = 0; i < deltas.length; i++) {
        const delta = deltas[i] as Record<string, object>;
        if (String(delta['actionId']) === 'action-1') {
          resourceJoined = `${String(delta['viewResourceDelta'])},${String(delta['viewPendingDelta'])},${String(delta['actionResourceDelta'])},${String(delta['actionPendingDelta'])}`;
        } else {
          viewActionDelta = String(delta['viewActionDelta']);
        }
      }
      expect(resourceJoined).assertEqual('1,0,1,0');
      expect(viewActionDelta).assertEqual('1');
    });

    it('eventRumLifecycleShouldTrackActionAndResourceStateFromDto', 0, async () => {
      const actionResponse = await manager.executeCommand({
        id: 'rum-action-complete',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: {
          eventType: 'action.complete',
          name: 'tap',
          time: 100,
          actionId: 'action-1',
          actionName: 'tap',
          viewId: 'view-1',
          viewName: 'Home',
          sessionId: 'session-1'
        } as Object as SDKWorkerPayload
      });
      expect(actionResponse.ok).assertTrue();
      expect(getPayloadString(actionResponse.payload, 'activeActionId')).assertEqual('');

      const startResponse = await manager.executeCommand({
        id: 'rum-resource-start',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: {
          eventType: 'resource.start',
          name: 'https://example.com',
          time: 101,
          resourceId: 'resource-1',
          viewId: 'view-1',
          actionId: 'action-1',
          sessionId: 'session-1'
        } as Object as SDKWorkerPayload
      });
      expect(startResponse.ok).assertTrue();
      expect(getPayloadString(startResponse.payload, 'activeResourceCount')).assertEqual('1');

      const completeResponse = await manager.executeCommand({
        id: 'rum-resource-complete',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: {
          eventType: 'resource.complete',
          name: 'https://example.com',
          time: 102,
          resourceId: 'resource-1',
          viewId: 'view-1',
          actionId: 'action-1',
          sessionId: 'session-1'
        } as Object as SDKWorkerPayload
      });
      expect(completeResponse.ok).assertTrue();
      expect(getPayloadString(completeResponse.payload, 'activeResourceCount')).assertEqual('0');
    });

    it('dataUploadCommandShouldFormatBodyInsideUploadPoolWithoutDeadlock', 0, async () => {
      let body = '';

      await manager.executeTask(
        SDKDedicatedPoolType.DATA_UPLOAD,
        'upload-outer',
        'upload.outer',
        5,
        async () => {
          const row: SDKUploadRowDTO = {
            id: 1,
            dataType: 'log',
            dataString: 'df_rum_harmonyos_log,sdk_data_id=uuid-1 message=\"hello\" 123',
            uuid: 'uuid-1',
            time: 123
          };
          const page: SDKUploadPageDTO = {
            dataType: 'log',
            rows: [row],
            packageId: 'pkg-1'
          };
          const request: SDKWorkerRequest = {
            id: 'upload-format-body',
            pool: SDKDedicatedPoolType.DATA_UPLOAD,
            command: SDKWorkerCommand.UPLOAD_FORMAT_BODY,
            priority: 5,
            createdAt: Date.now(),
            payload: page as Object as SDKWorkerPayload
          };

          const response = await manager.executeCommand(request);
          expect(response.ok).assertTrue();
          body = getPayloadString(response.payload, 'body');
        }
      );

      expect(body.includes('pkg-1.uuid-1')).assertTrue();
      expect(body.includes('message=\"hello\"')).assertTrue();
    });
  });
}
