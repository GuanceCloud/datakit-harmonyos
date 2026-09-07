import { UiTestUtils } from './helpers/UiTestUtils';
import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { SdkInternalTestAccess } from '@guancecloud/ft_sdk/src/main/ets/components/internal/testaccess/SdkInternalTestAccess';
import {
  SDKDedicatedPoolType, SDKNativeCrashLogBatchDTO, SDKTaskPriority, SDKWorkerCommand, SDKWorkerPayload
} from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKWorkerProtocol';

function waitForDelay(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, delayMs));
}

// The entry application packages ft_native; the standalone ft_sdk test HAP does not.
export default function nativeWorkerIntegrationUITest() {
  if (!UiTestUtils.shouldClearData(true) || !UiTestUtils.shouldClearData(false)) {
    console.info('NativeWorkerIntegrationUITest skipped: preserves previous native crash log evidence');
    return;
  }
  describe('NativeWorkerIntegrationUITest', () => {
    beforeAll(async () => {
      const driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
    });

    it('crashRecyclePreservesLogs', 0, async () => {
      const pool = SDKDedicatedPoolType.CRASH;
      const firstMarker = `crash-idle-before-${Date.now()}`;
      const secondMarker = `crash-idle-after-${Date.now()}`;
      expect(SdkInternalTestAccess.clearNativeCrashLogsForTest()).assertTrue();
      SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 50);
      try {
        const firstPayload: SDKNativeCrashLogBatchDTO = {
          logs: [{ level: 'I', tag: 'CrashIdleTest', message: firstMarker }]
        };
        const firstResponse = await SdkInternalTestAccess.postDedicatedWorkerCommandAndWait({
          id: `device-crash-idle-first-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: firstPayload as Object as SDKWorkerPayload
        }, 8000);
        if (!firstResponse.ok) throw new Error(`Crash Worker append failed: ${firstResponse.errorMessage}`);

        await waitForDelay(300);
        const idleStatus = SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool];
        expect(idleStatus.backend).assertEqual('thread-worker-idle');
        expect(idleStatus.idleRecycleCount >= 1).assertTrue();
        expect(SdkInternalTestAccess.getCollectedNativeCrashLogsForTest(20).includes(firstMarker))
          .assertTrue();

        const secondPayload: SDKNativeCrashLogBatchDTO = {
          logs: [{ level: 'I', tag: 'CrashIdleTest', message: secondMarker }]
        };
        const secondResponse = await SdkInternalTestAccess.postDedicatedWorkerCommandAndWait({
          id: `device-crash-idle-second-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: secondPayload as Object as SDKWorkerPayload
        }, 8000);
        if (!secondResponse.ok) throw new Error(`Recreated Crash Worker append failed: ${secondResponse.errorMessage}`);
        expect(SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool].backend ===
          'thread-worker-idle').assertFalse();
        const collectedLogs = SdkInternalTestAccess.getCollectedNativeCrashLogsForTest(20);
        expect(collectedLogs.includes(firstMarker)).assertTrue();
        expect(collectedLogs.includes(secondMarker)).assertTrue();
      } finally {
        SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 120000);
        SdkInternalTestAccess.clearNativeCrashLogsForTest();
      }
    });

  });
}
