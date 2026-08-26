import AbilityStage from '@ohos.app.ability.AbilityStage';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { initializeDemoColdLaunchRum } from '../utils/DemoColdLaunchRumInitializer';

/** Records T1 before the first UIAbility is constructed. */
export default class EntryAbilityStage extends AbilityStage {
  onCreate(): void {
    FTSDK.recordAppApplicationInit(this.context);
    // This is intentionally independent from UIAbility.onCreate: a service or
    // push cold launch can have no UIAbility, yet must make the launch tracker
    // RUM-ready and report its bounded background cold-start Action.
    initializeDemoColdLaunchRum(this.context, 'AbilityStage');
  }
}
