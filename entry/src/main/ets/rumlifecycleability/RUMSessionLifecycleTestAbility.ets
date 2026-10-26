import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import process from '@ohos.process';
import hilog from '@ohos.hilog';

/** Offline lifecycle fixture. Never install the normal Demo SDK in this process. */
export default class RUMSessionLifecycleTestAbility extends UIAbility {
  onCreate(want: Want): void {
    const parentPid = Number(want.parameters?.['lifecycleParentPid'] ?? 0);
    AppStorage.setOrCreate('rumLifecycleParentPid', parentPid);
    hilog.info(0xFF00, 'RUMSessionLifecycleUI', 'ABILITY_CREATE pid=%{public}d parentPid=%{public}d', process.pid, parentPid);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/RUMSessionLifecycleTestPage');
  }
}
