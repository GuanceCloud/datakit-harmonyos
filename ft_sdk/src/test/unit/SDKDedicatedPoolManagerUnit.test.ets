import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKDedicatedPoolManager
} from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolInputDTO,
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

    it('eventConsumerPoolShouldRunWithWorkerPoolAndNotBlockLogPool', 0, async () => {
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
      expect(order.join(',')).assertEqual('event-1-start,event-2,log');

      eventGate.release();
      await firstEvent;
      await secondEvent;
      expect(order.join(',')).assertEqual('event-1-start,event-2,log,event-1-end');
      const status = manager.getStatus().pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(status.maxConcurrency >= 2).assertTrue();
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
