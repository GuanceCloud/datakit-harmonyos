import router from '@ohos.router';

@Entry
@Component
struct SessionReplayTransitionPage {
  @State touchCount: number = 0;
  build() {
    Column({ space: 24 }) {
      Text('Replay transition destination')
        .id('session-replay-transition-destination')
        .fontSize(24).width('90%').height(80)
      Text(`Touches: ${this.touchCount}`).fontSize(16)
      Button('Return with Animation')
        .id('session-replay-transition-back')
        .width('90%').height(48)
        .onClick(() => router.back())
    }
    .id('session-replay-transition-root')
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#DCFCE7')
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.touchCount++;
    })
  }

  pageTransition(): void {
    PageTransitionEnter({ duration: 800, curve: Curve.Linear }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 800, curve: Curve.Linear }).slide(SlideEffect.Right)
  }
}
