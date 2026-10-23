import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';

/** Cold-start fixture: EntryAbility's SDK initialization is deliberately never invoked. */
export default class HeapPressureTestAbility extends UIAbility {
  onCreate(want: Want): void {
    AppStorage.setOrCreate('heapPressureAutoRun', want.parameters?.['heapPressureAutoRun'] === 'true');
    AppStorage.setOrCreate('heapPressureProbe', want.parameters?.['heapPressureProbe'] === 'true');
    AppStorage.setOrCreate('heapPressureOOMMode', String(want.parameters?.['heapPressureOOMMode'] ?? ''));
    AppStorage.setOrCreate('heapPressureTargetMiB', Number(want.parameters?.['heapPressureTargetMiB'] ?? 273));
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ApplicationHeapPressurePage');
  }
}
