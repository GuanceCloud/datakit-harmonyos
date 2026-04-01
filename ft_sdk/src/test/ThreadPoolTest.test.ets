/**
 * Thread pool related tests
 * Reference: com.ft.sdk.tests.ThreadPoolTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { DataProcessThreadPool } from '../main/ets/components/thread/DataProcessThreadPool';
import { ThreadPoolManager } from '../main/ets/components/thread/ThreadPoolManager';

export default function threadPoolTest() {
  describe('ThreadPoolTest', () => {
    beforeAll(async () => {
      console.info('ThreadPoolTest', 'beforeAll called');
      // Initialize ThreadPoolManager
      await ThreadPoolManager.getInstance().initialize();
    });

    beforeEach(() => {
      console.info('ThreadPoolTest', 'beforeEach called');
    });

    afterEach(() => {
      console.info('ThreadPoolTest', 'afterEach called');
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
      // Get the singleton instance
      const pool = DataProcessThreadPool.getInstance();

      // Execute a task (in Android this is an infinite loop, we use a simpler task)
      let taskExecuted = false;
      pool.execute(() => {
        taskExecuted = true;
      });

      // Wait a bit for task to be queued
      await new Promise<void>(resolve => setTimeout(resolve, 100));

      // Shutdown the thread pool
      ThreadPoolManager.getInstance().shutdown();

      // Verify pool is shut down
      const status = ThreadPoolManager.getInstance().getStatus();
      expect(status.isShutdown).assertTrue();

      // Restart the pool (equivalent to reStartPool in Android)
      ThreadPoolManager.getInstance().reset();

      // Wait for initialization
      await new Promise<void>(resolve => setTimeout(resolve, 100));

      // Verify pool is running again
      const newStatus = ThreadPoolManager.getInstance().getStatus();
      expect(newStatus.isInitialized).assertTrue();
      expect(newStatus.isShutdown).assertFalse();

      console.info('ThreadPoolTest', 'testReThreadPool passed');
    });
  });
}
