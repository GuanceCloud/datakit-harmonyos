import { StressTestManager } from '../utils/StressTestManager';

@Component
export struct StressCollectionModeToggle {
  @Prop useReal: boolean = false;
  @Prop disabled: boolean = false;
  description: string = '';
  onModeChange: (useReal: boolean) => void = (): void => {};

  build() {
    Column({ space: 6 }) {
      Row({ space: 12 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.useReal })
          .enabled(!this.disabled)
          .onChange((value: boolean) => this.onModeChange(value))
        Text(this.useReal ? 'Real Collection' : 'Synthetic Events')
          .fontSize(15)
      }.width('100%')
      if (this.useReal) {
        Text(this.description).fontSize(12).fontColor(Color.Gray).width('100%')
      }
    }.width('100%')
  }
}

/** Only real UI input reaches the SDK willClick observer; this never calls addAction. */
@Component
export struct StressRealActionControl {
  @Prop running: boolean = false;
  private manager: StressTestManager = StressTestManager.getInstance();

  build() {
    if (this.running && this.manager.isRealActionScenarioEnabled()) {
      Column({ space: 6 }) {
        Button('Tap for Real Action')
          .id('stress-real-action')
          .width('100%')
          .height(48)
          .onClick(() => this.manager.recordRealActionClick())
        Text('Actual UI taps use SDK automatic Action tracking. The counter records input, not upload acknowledgements.')
          .fontSize(12).fontColor(Color.Gray)
      }.width('100%').padding(12)
    }
  }
}

@Component
export struct StressRealLongTaskControl {
  @Prop running: boolean = false;
  private manager: StressTestManager = StressTestManager.getInstance();

  build() {
    if (this.running && this.manager.isRealLongTaskScenarioEnabled()) {
      Column({ space: 6 }) {
        Button('Run Real Main-Thread Block')
          .id('stress-real-long-task')
          .width('100%').height(48)
          .onClick(() => this.manager.recordRealLongTaskClick())
        Text('Blocks inside actual UI dispatch. System MAIN_THREAD_JANK reports determine collected LongTasks.')
          .fontSize(12).fontColor(Color.Gray)
      }.width('100%').padding(12)
    }
  }
}
