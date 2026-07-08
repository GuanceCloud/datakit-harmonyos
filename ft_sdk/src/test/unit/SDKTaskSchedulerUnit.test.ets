import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKTask,
  SDKTaskPriority,
  SDKTaskScheduler,
  SDKTaskType
} from '../../main/ets/components/thread/SDKTaskScheduler';
import {
  SDKDedicatedPoolType,
  SDKWorkerCommand
} from '../../main/ets/components/thread/SDKWorkerProtocol';

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 5; i++) {
    await Promise.resolve();
  }
}

interface ReleaseGate {
  promise: Promise<void>;
  release: () => void;
}

function createGate(): ReleaseGate {
  let release = (): void => {
    // placeholder before promise executor assigns the actual resolver
  };

  const promise = new Promise<void>((resolve: (value?: void | PromiseLike<void>) => void) => {
    release = () => resolve();
  });

  return { promise, release };
}

export default function sdkTaskSchedulerUnitTest() {
  describe('SDKTaskSchedulerUnit', () => {
    let scheduler: SDKTaskScheduler;

    beforeEach(() => {
      SDKTaskScheduler.resetInternal();
      scheduler = SDKTaskScheduler.getInstance();
    });

    afterEach(() => {
      SDKTaskScheduler.resetInternal();
    });

    it('submitRunnableAndWaitShouldAwaitAsyncRun', 0, async () => {
      let completed = false;

      await scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'async-event',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          await Promise.resolve();
          completed = true;
        }
      });

      const status = scheduler.getStatus();
      expect(completed).assertTrue();
      expect(status.lanes[SDKTaskType.EVENT].completedTasks).assertEqual(1);
      expect(status.lanes[SDKTaskType.EVENT].failedTasks).assertEqual(0);
      expect(status.lanes[SDKTaskType.EVENT].missingWorkerRequestTasks).assertEqual(0);
      expect(status.lanes[SDKTaskType.EVENT].runnableFallbackTasks).assertEqual(1);
    });

    it('submitAndWaitShouldExecuteSerializableWorkerRequestWithoutRun', 0, async () => {
      let responseOk = false;

      await scheduler.submitTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'worker-request-only',
        priority: SDKTaskPriority.NORMAL,
        workerRequest: {
          id: 'worker-request-only',
          pool: SDKDedicatedPoolType.LOG_CONSUMER,
          command: SDKWorkerCommand.PING,
          priority: SDKTaskPriority.NORMAL,
          createdAt: Date.now()
        },
        workerResponseHandler: (response) => {
          responseOk = response.ok;
        }
      });

      const status = scheduler.getStatus();
      expect(responseOk).assertTrue();
      expect(status.lanes[SDKTaskType.LOG].completedTasks).assertEqual(1);
      expect(status.lanes[SDKTaskType.LOG].failedTasks).assertEqual(0);
      expect(status.lanes[SDKTaskType.LOG].missingWorkerRequestTasks).assertEqual(0);
      expect(status.lanes[SDKTaskType.LOG].runnableFallbackTasks).assertEqual(0);
    });

    it('extraLanesShouldUseDedicatedWorkerPools', 0, async () => {
      const status = scheduler.getStatus();

      expect(status.lanes[SDKTaskType.ANR].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.ANR].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.CRASH_FILE].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.CRASH_FILE].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.CUSTOM].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.BACKGROUND].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.INNER_LOG_FILE].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.BACKGROUND].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.DATA_PROCESS].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.DATA_PROCESS].maxConcurrency
      );
    });

    it('submitTaskAndWaitShouldRecordMissingWorkerRequest', 0, async () => {
      let rejected = false;
      const task = {
        type: SDKTaskType.LOG,
        name: 'missing-worker-request',
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        retryCount: 0
      } as SDKTask;

      try {
        await scheduler.submitAndWait(task);
      } catch (error) {
        rejected = true;
      }

      const status = scheduler.getStatus();
      expect(rejected).assertTrue();
      expect(status.lanes[SDKTaskType.LOG].completedTasks).assertEqual(0);
      expect(status.lanes[SDKTaskType.LOG].failedTasks).assertEqual(1);
      expect(status.lanes[SDKTaskType.LOG].missingWorkerRequestTasks).assertEqual(1);
      expect(status.lanes[SDKTaskType.LOG].lastMissingWorkerRequestTaskName).assertEqual('missing-worker-request');
    });

    it('eventLaneShouldRespectSerialKey', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'rum-event-state';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'first-event',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'second-event',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      releaseFirst();
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,first-end,second');
    });

    it('eventLaneShouldUseSerialWorkerPoolForTasksWithoutSerialKey', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const secondGateObject = createGate();
      const secondGate = secondGateObject.promise;
      const releaseSecond = secondGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'first-event-worker',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'second-event-worker',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('second-start');
          await secondGate;
          order.push('second-end');
        }
      });

      await flushPromises();
      const blockedStatus = scheduler.getStatus();
      const blockedPool = blockedStatus.dedicatedPools.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(order.join(',')).assertEqual('first-start');
      expect(blockedStatus.lanes[SDKTaskType.EVENT].maxConcurrency).assertEqual(1);
      expect(blockedPool.workerCount).assertEqual(1);
      expect(blockedPool.maxConcurrency).assertEqual(1);
      expect(blockedPool.running).assertEqual(1);
      expect(blockedPool.pending).assertEqual(1);

      releaseFirst();
      releaseSecond();
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,first-end,second-start,second-end');
    });

    it('eventLaneShouldDrainRunnableTasksIntoDedicatedWorkerPool', 0, async () => {
      const order: string[] = [];
      const initialStatus = scheduler.getStatus();
      const workerCount = initialStatus.lanes[SDKTaskType.EVENT].maxConcurrency;
      const taskCount = workerCount + 1;
      const gates: ReleaseGate[] = [];
      const tasks: Promise<void>[] = [];

      for (let i = 0; i < taskCount; i++) {
        const taskIndex = i;
        const gate = createGate();
        gates.push(gate);
        tasks.push(scheduler.submitRunnableTaskAndWait({
          type: SDKTaskType.EVENT,
          name: `event-worker-pool-${taskIndex}`,
          priority: SDKTaskPriority.HIGH,
          run: async () => {
            order.push(`task-${taskIndex}-start`);
            await gate.promise;
            order.push(`task-${taskIndex}-end`);
          }
        }));
      }

      await flushPromises();
      const status = scheduler.getStatus();
      const eventLane = status.lanes[SDKTaskType.EVENT];
      const eventPool = status.dedicatedPools.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(order.length).assertEqual(workerCount);
      expect(eventLane.pending).assertEqual(0);
      expect(eventLane.running).assertEqual(taskCount);
      expect(eventPool.running).assertEqual(workerCount);
      expect(eventPool.pending).assertEqual(1);

      for (let i = 0; i < gates.length; i++) {
        gates[i].release();
      }
      await Promise.all(tasks);

      const finalStatus = scheduler.getStatus();
      expect(finalStatus.lanes[SDKTaskType.EVENT].completedTasks).assertEqual(taskCount);
      expect(finalStatus.dedicatedPools.pools[SDKDedicatedPoolType.EVENT_CONSUMER].pending).assertEqual(0);
    });

    it('eventLaneShouldUseFifoFastPathForBacklog', 0, async () => {
      scheduler.configureLane(SDKTaskType.EVENT, 1);
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'first-event',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'second-event',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('second');
        }
      });

      const third = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'third-event',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('third');
        }
      });

      const fourth = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'fourth-event',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('fourth');
        }
      });

      await flushPromises();
      const blockedStatus = scheduler.getStatus();
      const blockedLane = blockedStatus.lanes[SDKTaskType.EVENT];
      const blockedPool = blockedStatus.dedicatedPools.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
      expect(blockedLane.pending).assertEqual(0);
      expect(blockedPool.pending).assertEqual(3);
      expect(blockedPool.running).assertEqual(1);

      releaseFirst();
      await first;
      await second;
      await third;
      await fourth;

      const finalStatus = scheduler.getStatus().lanes[SDKTaskType.EVENT];
      expect(order.join(',')).assertEqual('first-start,first-end,second,third,fourth');
      expect(finalStatus.completedTasks).assertEqual(4);
      expect(finalStatus.maxScanCount <= 1).assertTrue();
    });

    it('logLaneShouldRespectSerialKey', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'log-consumer-state';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'first-log',
        priority: SDKTaskPriority.NORMAL,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'second-log',
        priority: SDKTaskPriority.NORMAL,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      releaseFirst();
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(scheduler.getStatus().lanes[SDKTaskType.LOG].maxScanCount <= 1).assertTrue();
    });

    it('logLaneShouldUseWorkerPoolForTasksWithoutSerialKey', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const secondGateObject = createGate();
      const secondGate = secondGateObject.promise;
      const releaseSecond = secondGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'first-log-worker',
        priority: SDKTaskPriority.NORMAL,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'second-log-worker',
        priority: SDKTaskPriority.NORMAL,
        run: async () => {
          order.push('second-start');
          await secondGate;
          order.push('second-end');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start,second-start');
      expect(scheduler.getStatus().lanes[SDKTaskType.LOG].maxConcurrency >= 2).assertTrue();

      releaseFirst();
      releaseSecond();
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,second-start,first-end,second-end');
    });

    it('logLaneShouldNotWaitForRunningEventLane', 0, async () => {
      const order: string[] = [];
      const eventGateObject = createGate();
      const eventGate = eventGateObject.promise;
      const releaseEvent = eventGateObject.release;

      const eventTask = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'long-event',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('event-start');
          await eventGate;
          order.push('event-end');
        }
      });

      const logTask = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'independent-log',
        priority: SDKTaskPriority.NORMAL,
        run: () => {
          order.push('log');
        }
      });

      await flushPromises();
      await logTask;
      expect(order.join(',')).assertEqual('event-start,log');

      releaseEvent();
      await eventTask;

      expect(order.join(',')).assertEqual('event-start,log,event-end');
    });

    it('dataProcessLaneShouldAllowParallelTasks', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const secondGateObject = createGate();
      const secondGate = secondGateObject.promise;
      const releaseSecond = secondGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'first-data-process',
        priority: SDKTaskPriority.LOW,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'second-data-process',
        priority: SDKTaskPriority.LOW,
        run: async () => {
          order.push('second-start');
          await secondGate;
          order.push('second-end');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start,second-start');

      releaseFirst();
      releaseSecond();

      await first;
      await second;
      expect(order.join(',')).assertEqual('first-start,second-start,first-end,second-end');
    });

    it('dataProcessLaneShouldUseFifoFastPathForBacklog', 0, async () => {
      scheduler.configureLane(SDKTaskType.DATA_PROCESS, 1);
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'first-data-process-fifo',
        priority: SDKTaskPriority.LOW,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'second-data-process-fifo',
        priority: SDKTaskPriority.LOW,
        run: () => {
          order.push('second');
        }
      });

      const third = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'third-data-process-fifo',
        priority: SDKTaskPriority.LOW,
        run: () => {
          order.push('third');
        }
      });

      const fourth = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'fourth-data-process-fifo',
        priority: SDKTaskPriority.LOW,
        run: () => {
          order.push('fourth');
        }
      });

      await flushPromises();
      const blockedStatus = scheduler.getStatus();
      const blockedLane = blockedStatus.lanes[SDKTaskType.DATA_PROCESS];
      const blockedPool = blockedStatus.dedicatedPools.pools[SDKDedicatedPoolType.DATA_PROCESS];
      expect(blockedLane.pending).assertEqual(0);
      expect(blockedPool.pending).assertEqual(3);
      expect(blockedPool.running).assertEqual(1);

      releaseFirst();
      await first;
      await second;
      await third;
      await fourth;

      const finalStatus = scheduler.getStatus().lanes[SDKTaskType.DATA_PROCESS];
      expect(order.join(',')).assertEqual('first-start,first-end,second,third,fourth');
      expect(finalStatus.completedTasks).assertEqual(4);
      expect(finalStatus.maxScanCount <= 1).assertTrue();
    });

    it('laneStatusShouldRecordDispatchAndScanMetrics', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'same-data-process-serial-key';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'first-data-process-serial',
        priority: SDKTaskPriority.LOW,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'second-data-process-serial',
        priority: SDKTaskPriority.LOW,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      const blockedStatus = scheduler.getStatus().lanes[SDKTaskType.DATA_PROCESS];
      expect(blockedStatus.pending).assertEqual(1);
      expect(blockedStatus.dispatchCount > 0).assertTrue();
      expect(blockedStatus.maxScanCount >= 1).assertTrue();

      releaseFirst();
      await first;
      await second;

      const finalStatus = scheduler.getStatus().lanes[SDKTaskType.DATA_PROCESS];
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(finalStatus.completedTasks).assertEqual(2);
      expect(finalStatus.dispatchCount >= 3).assertTrue();
      expect(finalStatus.averageScanCount > 0).assertTrue();
      expect(finalStatus.maxScanCount >= 1).assertTrue();
    });

    it('crashFileLaneShouldRespectSerialKey', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'native-crash-file';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CRASH_FILE,
        name: 'first-crash-file',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CRASH_FILE,
        name: 'second-crash-file',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      releaseFirst();
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.CRASH_FILE].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.CRASH_FILE].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.CRASH_FILE].completedTasks).assertEqual(2);
    });

    it('anrLaneShouldRespectSerialKeyAndStayIndependentFromCrashFile', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'anr-freeze-processing';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.ANR,
        name: 'first-anr',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.ANR,
        name: 'second-anr',
        priority: SDKTaskPriority.HIGH,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      releaseFirst();
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.ANR].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.ANR].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.ANR].completedTasks).assertEqual(2);
      expect(status.lanes[SDKTaskType.CRASH_FILE].completedTasks).assertEqual(0);
    });

    it('customLaneShouldRespectSerialKeyForMaintenanceTasks', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;
      const serialKey = 'trace-cleanup-state';

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'first-custom-maintenance',
        priority: SDKTaskPriority.BACKGROUND,
        serialKey,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'second-custom-maintenance',
        priority: SDKTaskPriority.BACKGROUND,
        serialKey,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      releaseFirst();
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.CUSTOM].maxConcurrency).assertEqual(
        status.dedicatedPools.pools[SDKDedicatedPoolType.BACKGROUND].maxConcurrency
      );
      expect(status.lanes[SDKTaskType.CUSTOM].completedTasks).assertEqual(2);
      expect(status.lanes['remote'] === undefined).assertTrue();
    });

    it('customLaneSingleFlightShouldKeepLatestRescheduledTask', 0, async () => {
      const order: string[] = [];
      const firstGateObject = createGate();
      const firstGate = firstGateObject.promise;
      const releaseFirst = firstGateObject.release;

      const first = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'trace-cleanup-first',
        priority: SDKTaskPriority.BACKGROUND,
        singleFlightKey: 'trace-handler-cleanup',
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const replaced = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'trace-cleanup-replaced',
        priority: SDKTaskPriority.BACKGROUND,
        singleFlightKey: 'trace-handler-cleanup',
        run: () => {
          order.push('replaced');
        }
      }).then(() => {
        order.push('replaced-resolved');
      }).catch(() => {
        order.push('replaced-rejected');
      });

      const latest = scheduler.submitRunnableTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'trace-cleanup-latest',
        priority: SDKTaskPriority.BACKGROUND,
        singleFlightKey: 'trace-handler-cleanup',
        run: () => {
          order.push('latest');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start,replaced-rejected');

      releaseFirst();
      await first;
      await replaced;
      await latest;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,replaced-rejected,first-end,latest');
      expect(status.lanes[SDKTaskType.CUSTOM].completedTasks).assertEqual(2);
      expect(status.rescheduledSingleFlightTasks).assertEqual(0);
      expect(status.activeSingleFlightTasks).assertEqual(0);
    });

  });
}
