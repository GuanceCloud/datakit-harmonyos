import router from '@ohos.router';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';
import { SessionReplayComponentSamples } from '../components/SessionReplayComponentSamples';

@Entry
@Component
struct SessionReplayTransitionPage {
  @State replayEnabled: boolean = false;

  onPageShow(): void {
    this.replayEnabled = FTSessionReplay.getInstance().isEnabled();
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('返回功能测试')
          .id('session-replay-transition-back')
          .height(36).onClick(() => router.back())
        Text('复杂组件采集测试')
          .id('session-replay-transition-destination')
          .fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
      }
      .width('100%').padding(16).backgroundColor(Color.White)
      Text(this.replayEnabled ? '录制中：操作组件后返回功能测试页上传' : '会话回放未开启，请返回功能测试页开启后再验证采集')
        .width('100%').padding({ left: 16, right: 16, bottom: 10 })
        .fontSize(12).fontColor(this.replayEnabled ? '#15803D' : '#B91C1C')
      SessionReplayComponentSamples().layoutWeight(1)
    }
    .id('session-replay-transition-root')
    .width('100%').height('100%')
    .backgroundColor('#F8FAFC')
  }

  pageTransition(): void {
    PageTransitionEnter({ duration: 800, curve: Curve.Linear }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 800, curve: Curve.Linear }).slide(SlideEffect.Right)
  }
}
