/**
 * Thread pool related tests
 * Reference: com.ft.sdk.tests.ThreadPoolTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { DataProcessThreadPool } from '../main/ets/components/thread/DataProcessThreadPool';
import { ThreadPoolManager } from '../main/ets/components/thread/ThreadPoolManager';

async function resetThreadPoolForTest(): Promise<void> {
  ThreadPoolManager.getInstance().reset();
  await new Promise<void>(resolve => setTimeout(resolve, 100));
}

export default function threadPoolTest() {
  describe('ThreadPoolTest', () => {
    beforeAll(async () => {
      console.info('ThreadPoolTest', 'beforeAll called');
      // Initialize ThreadPoolManager
      await ThreadPoolManager.getInstance().initialize();
    });

    beforeEach(async () => {
      console.info('ThreadPoolTest', 'beforeEach called');
      await resetThreadPoolForTest();
    });

    afterEach(async () => {
      console.info('ThreadPoolTest', 'afterEach called');
      await resetThreadPoolForTest();
    });

    afterAll(() => {
      console.info('ThreadPoolTest', 'afterAll called');
    });

    /**
     * Thread pool execution process, restart in the middle, verify if the current state is correct
     * Note: HarmonyOS ThreadPoolManager doesn't have the exact same API as Android
     * We test the equivalent functionality: shutdown and reset
     */
    it('testReThreadPool', 0, async () => {
      try {
        // Get the singleton instance
        const pool = DataProcessThreadPool.getInstance();

        // Execute a task (in Android this is an infinite loop, we use a simpler task)
        let taskExecuted = false;
        pool.execute(() => {
          taskExecuted = true;
        });

        // Wait a bit for task to run through the simulated thread pool loop
        await new Promise<void>(resolve => setTimeout(resolve, 300));
        expect(taskExecuted).assertTrue();

        // Shutdown the thread pool
        ThreadPoolManager.getInstance().shutdown();

        // Verify pool is shut down
        const status = ThreadPoolManager.getInstance().getStatus();
        expect(status.isShutdown).assertTrue();

        let rejectedAfterShutdown = false;
        try {
          pool.execute(() => {
            taskExecuted = false;
          });
        } catch (error) {
          rejectedAfterShutdown = true;
        }
        expect(rejectedAfterShutdown).assertTrue();

        // Restart the pool (equivalent to reStartPool in Android)
        await resetThreadPoolForTest();

        // Verify pool is running again
        const newStatus = ThreadPoolManager.getInstance().getStatus();
        expect(newStatus.isInitialized).assertTrue();
        expect(newStatus.isShutdown).assertFalse();

        let taskExecutedAfterReset = false;
        pool.execute(() => {
          taskExecutedAfterReset = true;
        });
        await new Promise<void>(resolve => setTimeout(resolve, 300));
        expect(taskExecutedAfterReset).assertTrue();

        console.info('ThreadPoolTest', 'testReThreadPool passed');
      } finally {
        await resetThreadPoolForTest();
      }
    });
  });
}
