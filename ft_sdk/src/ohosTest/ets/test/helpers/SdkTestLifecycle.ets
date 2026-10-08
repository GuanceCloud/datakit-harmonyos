import { FTSDK } from '../../../../main/ets/components/FTSDK';
import { DbInternalTestAccess } from '../../../../main/ets/components/internal/testaccess/DbInternalTestAccess';
import { SdkInternalTestAccess } from '../../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { SyncInternalTestAccess } from '../../../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import { TelemetryInternalTestAccess } from '../../../../main/ets/components/internal/testaccess/TelemetryInternalTestAccess';
import { SyncTaskManager } from '../../../../main/ets/components/SyncTaskManager';
import { FTRUMInnerManager } from '../../../../main/ets/components/rum/FTRUMInnerManager';
import { FTActionTracker } from '../../../../main/ets/components/rum/FTActionTracker';
import { FTNavigationTracker } from '../../../../main/ets/components/rum/FTNavigationTracker';
import { SDKDedicatedPoolManager } from '../../../../main/ets/components/thread/SDKDedicatedPoolManager';
import { WaitUtils } from './WaitUtils';

export class SdkTestLifecycle {
  static async waitForUploadIdle(timeoutMs: number = 5000): Promise<boolean> {
    try {
      return await WaitUtils.waitUntil(async () => {
        const status = SyncTaskManager.getInstance().getStatus();
        const uploadStatus = status.uploadLaneStatus;
        return !status.running &&
          !uploadStatus.isRunning &&
          !uploadStatus.isScheduled &&
          !uploadStatus.needReschedule;
      }, timeoutMs);
    } catch (_error) {
      return true;
    }
  }

  static async resetRuntimeState(timeoutMs: number = 2000): Promise<void> {
    await SdkTestLifecycle.waitForUploadIdle(timeoutMs);

    FTActionTracker.getInstance().destroy();
    FTNavigationTracker.getInstance().destroy();

    try {
      // shutdown() closes views asynchronously; finish it before replacing singletons.
      await FTRUMInnerManager.getInstance().shutdown();
      FTSDK.shutDown();
    } catch (_error) {
    }

    try {
      SyncTaskManager.getInstance().stop();
    } catch (_error) {
    }

    SyncInternalTestAccess.resetState();
    // Host context versions restart with the singletons; discard Worker snapshots too.
    SDKDedicatedPoolManager.resetInternal();
    TelemetryInternalTestAccess.resetState();
    DbInternalTestAccess.resetDbManagerInstance();
    SdkInternalTestAccess.resetState();
  }
}
