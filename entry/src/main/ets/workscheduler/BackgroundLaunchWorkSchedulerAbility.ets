import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { process } from '@kit.ArkTS';
import { FTColdLaunchBridge, FTSDK } from '@guancecloud/ft_sdk/Index';
import { initializeDemoColdLaunchRum } from '../utils/DemoColdLaunchRumInitializer';
import { DemoLogger } from '../utils/DemoLogger';
import {
  markBackgroundColdLaunchReported,
  markBackgroundLaunchClassified,
  markBackgroundLaunchRumReady,
  markBackgroundLaunchWorkStarted,
  markBackgroundLaunchWorkStopped,
  markBackgroundLaunchWorkError
} from '../utils/BackgroundLaunchWorkStatusStore';

const TAG = 'BackgroundLaunchWorkSchedulerAbility';

/**
 * No-UI background-launch diagnostic entry. The system creates a separate
 * extension process and invokes onWorkStart without a UIAbility or Window.
 * This entry alone cannot complete a cold launch, which requires a real
 * first frame in this same process.
 */
export default class BackgroundLaunchWorkSchedulerAbility extends WorkSchedulerExtensionAbility {
  private removeBackgroundLaunchListener: (() => void) | null = null;
  private removeReportListener: (() => void) | null = null;

  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    this.removeListeners();
    const processReused = FTSDK.getRumConfig() !== null;
    // The current compiler plugin instruments AbilityStage, UIAbility and
    // AppService entries, but not WorkSchedulerExtensionAbility. This
    // idempotent call preserves the AbilityStage boundary and retries the
    // visibility snapshot if the earliest query still returned STATE_CREATE.
    FTColdLaunchBridge.recordApplicationInit(this.context);
    DemoLogger.i(TAG, `WORK_STARTED: onWorkStart, pid=${process.pid}, processReused=${processReused}, workId=${workInfo.workId}`);
    void this.run(workInfo, processReused).catch((error: Error): void => {
      DemoLogger.e(TAG, `BACKGROUND_LAUNCH_ERROR: pid=${process.pid}, error=${String(error)}`);
    });
  }

  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    this.removeListeners();
    DemoLogger.i(TAG, `onWorkStop: pid=${process.pid}, workId=${workInfo.workId}`);
    void markBackgroundLaunchWorkStopped(
      this.context,
      `System stopped WorkScheduler execution for workId=${workInfo.workId}`
    ).catch((error: Error): void => {
      DemoLogger.e(TAG, `Failed to persist work stop: ${String(error)}`);
    });
  }

  private removeListeners(): void {
    this.removeBackgroundLaunchListener?.();
    this.removeReportListener?.();
    this.removeBackgroundLaunchListener = null;
    this.removeReportListener = null;
  }

  private async run(workInfo: workScheduler.WorkInfo, processReused: boolean): Promise<void> {
    await markBackgroundLaunchWorkStarted(this.context, process.pid, JSON.stringify(workInfo));

    if (processReused) {
      const message = 'WorkScheduler reused an initialized process; this execution is not a new cold launch';
      DemoLogger.w(TAG, `PROCESS_REUSED: pid=${process.pid}, ${message}`);
      await markBackgroundLaunchWorkError(this.context, 'process_reused', message);
      return;
    }

    // The callback also fires immediately when the SDK classified this process
    // before onWorkStart completed, so the demo does not depend on callback order.
    this.removeBackgroundLaunchListener = FTColdLaunchBridge.onBackgroundLaunchDetected((): void => {
      DemoLogger.i(TAG, `BACKGROUND_LAUNCH_CLASSIFIED: pid=${process.pid}, app_launch_type=background; waiting for a real first UI frame in this process`);
      void markBackgroundLaunchClassified(this.context).catch((error: Error): void => {
        DemoLogger.e(TAG, `Failed to persist classification: ${String(error)}`);
      });
    });
    this.removeReportListener = FTColdLaunchBridge.onColdLaunchReported((launchType): void => {
      if (launchType !== 'background') {
        DemoLogger.w(TAG, `Unexpected cold-launch type=${launchType}, pid=${process.pid}`);
        return;
      }
      DemoLogger.i(TAG, `COLD_LAUNCH_SUBMITTED: pid=${process.pid}, action_type=launch_cold, app_launch_type=background`);
      void markBackgroundColdLaunchReported(this.context).catch((error: Error): void => {
        DemoLogger.e(TAG, `Failed to persist launch submission: ${String(error)}`);
      });
      FTSDK.flushSyncData();
      DemoLogger.i(TAG, `COLD_LAUNCH_FLUSH_REQUESTED: pid=${process.pid}; check SDK HTTP status and backend data for delivery`);
    });

    await initializeDemoColdLaunchRum(this.context, TAG);
    // Retry after async bootstrap if the AbilityStage query was still pending
    // when onWorkStart ran and returned STATE_CREATE/unknown afterwards.
    FTColdLaunchBridge.recordApplicationInit(this.context);
    const rumReady = FTSDK.getRumConfig() !== null;
    await markBackgroundLaunchRumReady(this.context, rumReady);
    DemoLogger.i(TAG, `SDK/RUM bootstrap finished: rumReady=${rumReady}, noUiCreated=true, firstFrameRequired=true`);

    if (!rumReady) {
      DemoLogger.e(TAG, `RUM_NOT_READY: pid=${process.pid}; no cold-launch Action can be submitted`);
    }
  }
}
