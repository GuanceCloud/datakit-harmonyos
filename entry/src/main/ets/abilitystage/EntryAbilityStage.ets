import AbilityStage from '@ohos.app.ability.AbilityStage';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { initializeDemoColdLaunchRum } from '../utils/DemoColdLaunchRumInitializer';

/** Records application initialization before the first UIAbility is constructed. */
export default class EntryAbilityStage extends AbilityStage {
  onCreate(): void {
    FTSDK.recordAppApplicationInit(this.context);
  }
}
