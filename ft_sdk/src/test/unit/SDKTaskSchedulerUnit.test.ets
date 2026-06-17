import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKTaskPriority,
  SDKTaskScheduler,
  SDKTaskType
} from '../../main/ets/components/thread/SDKTaskScheduler';

async function flushPromises(): Promise<void> {
  for (let i = 0; i < 5; i++) {
    await Promise.resolve();
  }
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

    it('submitAndWaitShouldAwaitAsyncRun', 0, async () => {
      let completed = false;

      await scheduler.submitTaskAndWait({
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
    });

    it('eventLaneShouldRunTasksSequentially', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'first-event',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'second-event',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      if (releaseFirst) {
        releaseFirst();
      }
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,first-end,second');
    });

    it('logLaneShouldRunTasksSequentially', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'first-log',
        priority: SDKTaskPriority.NORMAL,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
        type: SDKTaskType.LOG,
        name: 'second-log',
        priority: SDKTaskPriority.NORMAL,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      if (releaseFirst) {
        releaseFirst();
      }
      await first;
      await second;

      expect(order.join(',')).assertEqual('first-start,first-end,second');
    });

    it('logLaneShouldNotWaitForRunningEventLane', 0, async () => {
      const order: string[] = [];
      let releaseEvent: (() => void) | null = null;
      const eventGate = new Promise<void>((resolve) => {
        releaseEvent = resolve;
      });

      const eventTask = scheduler.submitTaskAndWait({
        type: SDKTaskType.EVENT,
        name: 'long-event',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('event-start');
          await eventGate;
          order.push('event-end');
        }
      });

      const logTask = scheduler.submitTaskAndWait({
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

      if (releaseEvent) {
        releaseEvent();
      }
      await eventTask;

      expect(order.join(',')).assertEqual('event-start,log,event-end');
    });

    it('dataProcessLaneShouldAllowParallelTasks', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      let releaseSecond: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      const secondGate = new Promise<void>((resolve) => {
        releaseSecond = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.DATA_PROCESS,
        name: 'first-data-process',
        priority: SDKTaskPriority.LOW,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
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

      if (releaseFirst) {
        releaseFirst();
      }
      if (releaseSecond) {
        releaseSecond();
      }

      await first;
      await second;
      expect(order.join(',')).assertEqual('first-start,second-start,first-end,second-end');
    });

    it('crashFileLaneShouldRunTasksSequentially', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.CRASH_FILE,
        name: 'first-crash-file',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
        type: SDKTaskType.CRASH_FILE,
        name: 'second-crash-file',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      if (releaseFirst) {
        releaseFirst();
      }
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.CRASH_FILE].maxConcurrency).assertEqual(1);
      expect(status.lanes[SDKTaskType.CRASH_FILE].completedTasks).assertEqual(2);
    });

    it('anrLaneShouldRunTasksSequentiallyAndStayIndependentFromCrashFile', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.ANR,
        name: 'first-anr',
        priority: SDKTaskPriority.HIGH,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
        type: SDKTaskType.ANR,
        name: 'second-anr',
        priority: SDKTaskPriority.HIGH,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      if (releaseFirst) {
        releaseFirst();
      }
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.ANR].maxConcurrency).assertEqual(1);
      expect(status.lanes[SDKTaskType.ANR].completedTasks).assertEqual(2);
      expect(status.lanes[SDKTaskType.CRASH_FILE].completedTasks).assertEqual(0);
    });

    it('customLaneShouldRunMaintenanceTasksSequentially', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'first-custom-maintenance',
        priority: SDKTaskPriority.BACKGROUND,
        run: async () => {
          order.push('first-start');
          await firstGate;
          order.push('first-end');
        }
      });

      const second = scheduler.submitTaskAndWait({
        type: SDKTaskType.CUSTOM,
        name: 'second-custom-maintenance',
        priority: SDKTaskPriority.BACKGROUND,
        run: () => {
          order.push('second');
        }
      });

      await flushPromises();
      expect(order.join(',')).assertEqual('first-start');

      if (releaseFirst) {
        releaseFirst();
      }
      await first;
      await second;

      const status = scheduler.getStatus();
      expect(order.join(',')).assertEqual('first-start,first-end,second');
      expect(status.lanes[SDKTaskType.CUSTOM].maxConcurrency).assertEqual(1);
      expect(status.lanes[SDKTaskType.CUSTOM].completedTasks).assertEqual(2);
      expect(status.lanes['remote'] === undefined).assertTrue();
    });

    it('customLaneSingleFlightShouldKeepLatestRescheduledTask', 0, async () => {
      const order: string[] = [];
      let releaseFirst: (() => void) | null = null;
      const firstGate = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });

      const first = scheduler.submitTaskAndWait({
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

      const replaced = scheduler.submitTaskAndWait({
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

      const latest = scheduler.submitTaskAndWait({
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

      if (releaseFirst) {
        releaseFirst();
      }
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
