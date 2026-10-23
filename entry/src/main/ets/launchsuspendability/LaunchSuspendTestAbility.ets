import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { FTColdLaunchBridge } from '@guancecloud/ft_sdk/Index';
import { LaunchSuspendProbe } from '../utils/LaunchSuspendProbe';
import { LaunchClockContinuity } from '../utils/LaunchClockContinuity';

/** Test-only cold entry. Compiler hooks remain active; the fixture never installs RUM. */
export default class LaunchSuspendTestAbility extends UIAbility {
  private stage: window.WindowStage | null = null;
  private holdBeforeFrame: boolean = false;
  private contentLoaded: boolean = false;
  private seconds: number = 30;
  private clockWindowListener = (event: window.WindowStageEventType): void => {
    if (event === window.WindowStageEventType.INACTIVE) LaunchClockContinuity.lifecycle('INACTIVE');
    if (event === window.WindowStageEventType.PAUSED) LaunchClockContinuity.lifecycle('PAUSED');
    if (event === window.WindowStageEventType.HIDDEN) LaunchClockContinuity.lifecycle('HIDDEN');
    if (event === window.WindowStageEventType.ACTIVE) LaunchClockContinuity.lifecycle('ACTIVE');
    if (event === window.WindowStageEventType.RESUMED) LaunchClockContinuity.lifecycle('RESUMED');
    if (event === window.WindowStageEventType.SHOWN) LaunchClockContinuity.lifecycle('SHOWN');
  };

  onCreate(want: Want): void {
    LaunchSuspendProbe.initialize(this.context);
    LaunchClockContinuity.initialize(this.context);
    this.holdBeforeFrame = want.parameters?.['launchSuspendBeforeFrame'] === true ||
      want.parameters?.['launchSuspendBeforeFrame'] === 'true';
    this.seconds = Number(want.parameters?.['launchSuspendSeconds'] ?? 30);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    this.stage = stage;
    try { stage.on('windowStageEvent', this.clockWindowListener); }
    catch (error) { hilog.warn(0xFF00, 'LaunchSuspendTest', 'CLOCK_WINDOW_LISTENER_ERROR %{public}s', String(error)); }
    FTColdLaunchBridge.onFirstFrameRecorded((): void => { LaunchSuspendProbe.observeFirstFrame(); });
    try {
      if (this.holdBeforeFrame) {
        LaunchSuspendProbe.arm(this.seconds, true);
        return;
      }
    } catch (error) {
      hilog.error(0xFF00, 'LaunchSuspendTest', 'ARM_ERROR %{public}s', String(error));
    }
    this.loadPage();
  }

  onNewWant(want: Want): void {
    const command = String(want.parameters?.['launchSuspendCommand'] ?? '');
    const runId = String(want.parameters?.['launchSuspendRunId'] ?? '');
    const controllerId = String(want.parameters?.['launchSuspendControllerId'] ?? '');
    try {
      if (command === 'checkpoint') LaunchSuspendProbe.checkpoint(runId, controllerId);
      if (command === 'status') LaunchSuspendProbe.status(runId);
      if (command === 'sample') {
        LaunchSuspendProbe.finish(runId, controllerId);
        this.loadPage();
      }
      if (command === 'release') this.loadPage();
    } catch (error) {
      hilog.error(0xFF00, 'LaunchSuspendTest', 'COMMAND_ERROR %{public}s', String(error));
    }
  }

  onForeground(): void {
    LaunchSuspendProbe.lifecycle('FOREGROUND');
    LaunchClockContinuity.lifecycle('FOREGROUND');
  }
  onBackground(): void {
    LaunchSuspendProbe.lifecycle('BACKGROUND');
    LaunchClockContinuity.lifecycle('BACKGROUND');
  }

  onWindowStageDestroy(): void {
    try { this.stage?.off('windowStageEvent', this.clockWindowListener); }
    catch (error) { hilog.warn(0xFF00, 'LaunchSuspendTest', 'CLOCK_WINDOW_OFF_ERROR %{public}s', String(error)); }
    this.stage = null;
    this.contentLoaded = false;
  }

  private loadPage(): void {
    if (this.stage !== null && !this.contentLoaded) {
      this.stage.loadContent('pages/LaunchSuspendTestPage');
      this.contentLoaded = true;
    }
  }
}
