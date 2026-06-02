import { FTSDK } from '../../../../main/ets/components/FTSDK';
import FTTrackInner from '../../../../main/ets/components/FTTrackInner';
import { TrackLogManager } from '../../../../main/ets/components/log/TrackLogManager';
import { FTRUMGlobalManager } from '../../../../main/ets/components/rum/FTRUMGlobalManager';
import { SyncTaskManager } from '../../../../main/ets/components/SyncTaskManager';
import { WaitUtils } from './WaitUtils';

export class SdkTestLifecycle {
  static async waitForUploadIdle(timeoutMs: number = 5000): Promise<boolean> {
    try {
      return await WaitUtils.waitUntil(async () => {
        const status = SyncTaskManager.getInstance().getStatus();
        const queueStatus = status.dataUploadThreadPoolStatus;
        return !status.running &&
          !queueStatus.isRunning &&
          !queueStatus.isScheduled &&
          !queueStatus.isProcessing &&
          queueStatus.queueSize === 0;
      }, timeoutMs);
    } catch (_error) {
      return true;
    }
  }

  static async resetRuntimeState(timeoutMs: number = 2000): Promise<void> {
    await SdkTestLifecycle.waitForUploadIdle(timeoutMs);

    try {
      FTSDK.shutDown();
    } catch (_error) {
    }

    try {
      SyncTaskManager.getInstance().stop();
    } catch (_error) {
    }

    SyncTaskManager.resetStateForTest();
    FTRUMGlobalManager.resetStateForTest();
    TrackLogManager.resetStateForTest();
    FTTrackInner.resetInstanceForTest();
    FTSDK.resetStateForTest();
  }
}
