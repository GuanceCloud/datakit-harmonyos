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

  });
}
