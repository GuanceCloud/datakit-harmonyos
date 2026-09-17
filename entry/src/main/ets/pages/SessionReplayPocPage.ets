import router from '@ohos.router';
import { AppState, ErrorType, FTRUMGlobalManager } from '@guancecloud/ft_sdk';
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
  @State showMutationProbe: boolean = false;
  private readonly replay: FTSessionReplayPOC = new FTSessionReplayPOC(
    new FTSessionReplayConfig().setMaxNodesPerSnapshot(300)
  );

  aboutToAppear(): void {
    this.replay.start();
    this.replay.registerRoot(this.getUIContext(), 'session-replay-poc-root', vp2px(1));
  }

  aboutToDisappear(): void {
    this.replay.stop();
  }

  private showBridgeCapture(source: string): void {
    setTimeout(() => {
      const capture = this.replay.getLastCapture();
      if (capture === null) {
        this.result = `${source} did not produce a Replay capture. Confirm that RUM is initialized and try again.`;
        return;
      }
      this.result = `${source} captured ${capture.wireframeCount} wireframes.\n${capture.payload.substring(0, 600)}`;
    }, 200);
  }

  build() {
    Column({ space: 16 }) {
      Text('Session Replay POC')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('API 12 FrameNode collection → Android replay envelope')
        .fontSize(14)
        .fontColor('#666666')
      Button('Capture through RUM View Bridge')
        .width('90%')
        .height(48)
        .onClick(() => {
          FTRUMGlobalManager.getInstance().startView('session-replay-poc-bridge')
            .then(() => this.showBridgeCapture('RUM View bridge'))
            .catch((error: Error) => {
              this.result = `RUM View bridge failed: ${error.message}`;
            });
        })
      Button('Capture through RUM Error Bridge')
        .width('90%')
        .height(48)
        .onClick(() => {
          FTRUMGlobalManager.getInstance().addError(
            'SessionReplayPocError',
            'Manual bridge verification error',
            ErrorType.CUSTOM,
            AppState.RUN
          );
          this.showBridgeCapture('RUM Error bridge');
        })
      Button('Capture Incremental Mutation')
        .width('90%')
        .height(48)
        .onClick(() => {
          const previousCapture = this.replay.getLastCapture();
          if (previousCapture === null) {
            this.result = 'Capture through the RUM View Bridge first to establish a Full Snapshot baseline.';
            return;
          }
          this.showMutationProbe = !this.showMutationProbe;
          setTimeout(() => {
            try {
              const context: SessionReplayContext = {
                applicationId: previousCapture.envelope.application_id,
                sessionId: previousCapture.envelope.session_id,
                viewId: previousCapture.envelope.view_id
              };
              const capture = this.replay.captureIncrementalSnapshot(
                this.getUIContext(),
                'session-replay-poc-root',
                context,
                vp2px(1)
              );
              this.result = capture === null
                ? 'No structural mutation detected after the baseline.'
                : `Mutation captured with type ${capture.record.type}.\n${capture.payload.substring(0, 600)}`;
            } catch (error) {
              this.result = `Mutation capture failed: ${String(error)}`;
            }
          }, 80);
        })
      if (this.showMutationProbe) {
        Text('Incremental layout probe')
          .fontSize(16)
          .padding(12)
          .backgroundColor('#DDF4FF')
      }
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
