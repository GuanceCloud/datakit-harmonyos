import router from '@ohos.router';

@Entry
@Component
struct SessionReplayDefaultTransitionPage {
  build() {
    Column({ space: 24 }) {
      Text('Default Router destination')
        .id('session-replay-default-destination')
        .fontSize(24).width('90%').height(80)
      Button('Return with Default Animation')
        .id('session-replay-default-back')
        .width('90%').height(48)
        .onClick(() => router.back())
    }
    .id('session-replay-default-root')
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#DBEAFE')
  }
}
