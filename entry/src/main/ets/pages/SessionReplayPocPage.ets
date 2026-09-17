import router from '@ohos.router';
import {
  FTSessionReplayConfig,
  FTSessionReplayPOC,
  SessionReplayContext,
  SessionReplayGlobalContext
} from '@guancecloud/ft_session_replay';

@Entry
@Component
struct SessionReplayPocPage {
  @State result: string = 'Ready to capture a privacy-safe Full Snapshot.';
  private readonly replay: FTSessionReplayPOC = new FTSessionReplayPOC(
    new FTSessionReplayConfig().setMaxNodesPerSnapshot(300)
  );

  build() {
    Column({ space: 16 }) {
      Text('Session Replay POC')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('API 12 FrameNode collection → Android replay envelope')
        .fontSize(14)
        .fontColor('#666666')
      Button('Capture Full Snapshot')
        .width('90%')
        .height(48)
        .onClick(() => {
          try {
            const globalContext: SessionReplayGlobalContext = {};
            globalContext['wgt_id'] = 'harmony-poc';
            const context: SessionReplayContext = {
              applicationId: 'harmony-session-replay-poc',
              sessionId: 'poc-session-id',
              viewId: 'poc-view-id',
              globalContext
            };
            const capture = this.replay.captureFullSnapshot(
              this.getUIContext(),
              'session-replay-poc-root',
              context,
              vp2px(1)
            );
            this.result = `Captured ${capture.wireframeCount} wireframes.\n${capture.payload.substring(0, 600)}`;
          } catch (error) {
            this.result = `Capture failed: ${String(error)}`;
          }
        })
      Scroll() {
        Text(this.result)
          .width('90%')
          .fontSize(12)
          .fontColor('#333333')
      }
      .layoutWeight(1)
      Button('Back')
        .width('90%')
        .height(44)
        .onClick(() => router.back())
    }
    .id('session-replay-poc-root')
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
