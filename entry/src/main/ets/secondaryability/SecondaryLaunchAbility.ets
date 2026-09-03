import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { FTColdLaunchBridge, FTSDK } from '@guancecloud/ft_sdk/Index';
import { KEY_COLD_LAUNCH_NEXT_UI_ABILITY } from '../entryability/EntryAbility';
import { initializeDemoColdLaunchRum } from '../utils/DemoColdLaunchRumInitializer';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'SecondaryLaunchAbility';

/**
 * Independent UIAbility B for the A-to-B/B-to-A cold-launch acceptance test.
 * It intentionally shares the same SDK bootstrap and first-frame collection
 * path as the main UIAbility, without reusing the main UIAbility instance.
 */
export default class SecondaryLaunchAbility extends UIAbility {
  private coldLaunchTestWant: Want | null = null;
  private entryLaunchStarted: boolean = false;

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    this.coldLaunchTestWant = want;
    await initializeDemoColdLaunchRum(this.context, TAG, want);
    DemoLogger.i(TAG, `onCreate: launchReason=${launchParam.launchReason}`);
  }

  /** B-to-A half of the multi-UIAbility cold-launch acceptance test. */
  private async startEntryAbilityIfRequested(): Promise<void> {
    const want = this.coldLaunchTestWant;
    if (want === null) {
      return;
    }
    const nextAbility = want.parameters?.[KEY_COLD_LAUNCH_NEXT_UI_ABILITY];
    if (String(nextAbility ?? '') !== 'EntryAbility') {
      return;
    }
    if (this.entryLaunchStarted) {
      return;
    }
    this.entryLaunchStarted = true;

    // Match A-to-B: do not discard the source cold-launch Action into a
    // subsequent SDK initialization. Drain it through the ordinary cache and
    // upload path before switching to the target UIAbility.
    FTSDK.flushSyncData();
    DemoLogger.i(TAG, 'Cold-launch test parameter requests SecondaryLaunchAbility -> EntryAbility after first frame');

    const targetWant: Want = {
      bundleName: this.context.abilityInfo.bundleName,
      moduleName: this.context.abilityInfo.moduleName,
      abilityName: 'EntryAbility',
      parameters: want.parameters
    };
    try {
      await this.context.startAbility(targetWant);
      DemoLogger.i(TAG, 'Cold-launch test parameter started EntryAbility');
    } catch (error) {
      this.entryLaunchStarted = false;
      DemoLogger.e(TAG, `Cold-launch test parameter failed to start EntryAbility: ${error}`);
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const startEntryAfterFirstFrame = (): void => {
      void this.startEntryAbilityIfRequested();
    };
    FTColdLaunchBridge.onFirstFrameRecorded(startEntryAfterFirstFrame);
    windowStage.loadContent('pages/SecondaryLaunchAbilityPage', (error) => {
      if (error.code) {
        DemoLogger.e(TAG, `loadContent failed: ${error.code}`);
        return;
      }
      DemoLogger.i(TAG, 'SecondaryLaunchAbility content loaded');
    });
  }
}
