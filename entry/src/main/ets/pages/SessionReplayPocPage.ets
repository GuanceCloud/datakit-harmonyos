import router from '@ohos.router';
import { Context } from '@kit.AbilityKit';
import { AppState, ErrorType, FTRUMGlobalManager } from '@guancecloud/ft_sdk';
import {
  FTSessionReplayConfig,
  FTSessionReplay,
  SessionReplayContext,
  SessionReplayGlobalContext
} from '@guancecloud/ft_session_replay';

@Entry
@Component
struct SessionReplayPocPage {
  @State result: string = 'Ready to capture a privacy-safe Full Snapshot.';
  @State showMutationProbe: boolean = false;
  @State replayEnabled: boolean = false;
  private bridgeViewActive: boolean = false;
  private readonly replayConfig: FTSessionReplayConfig =
    new FTSessionReplayConfig().setMaxNodesPerSnapshot(300);
  private readonly replay: FTSessionReplay = FTSessionReplay.getInstance();

  aboutToAppear(): void {
    this.replayEnabled = this.replay.isEnabled();
    if (this.replayEnabled) {
      this.replay.registerRoot(this.getUIContext(), 'session-replay-poc-root', vp2px(1));
    }
  }

  aboutToDisappear(): void {
    if (!this.bridgeViewActive) {
      this.disableReplay();
      return;
    }
    FTRUMGlobalManager.getInstance().stopView()
      .then(() => {
        this.bridgeViewActive = false;
        this.disableReplay();
      })
      .catch(() => this.disableReplay());
  }

  private toggleReplay(): void {
    if (this.replayEnabled) {
      if (this.bridgeViewActive) {
        FTRUMGlobalManager.getInstance().stopView()
          .then(() => {
            this.bridgeViewActive = false;
            this.disableReplay();
          })
          .catch(() => this.disableReplay());
      } else {
        this.disableReplay();
      }
      return;
    }
    this.replay.enable(this.replayConfig, this.getFilesDir());
    this.replay.registerRoot(this.getUIContext(), 'session-replay-poc-root', vp2px(1));
    this.replayEnabled = true;
    this.result = 'Session Replay is enabled. Select a capture action to validate the protocol.';
  }

  private disableReplay(): void {
    this.replay.unregisterRoot();
    this.replay.disable();
    this.replayEnabled = false;
  }

  private getFilesDir(): string {
    return (getContext(this) as Context).filesDir;
  }

  private showBridgeCapture(source: string): void {
    setTimeout(() => {
      const capture = this.replay.getLastCapture();
      if (capture === null) {
        this.result = `${source} did not produce a Replay capture. Confirm that RUM is initialized and try again.`;
        return;
      }
      const totalRecords = this.replay.getRecordedRecords({
        applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id,
        viewId: capture.envelope.view_id
      }).length;
      this.result = `${source} captured ${capture.wireframeCount} wireframes; buffered records: ${totalRecords}; durable segments: ${this.replay.getStoredSegments().length}.\n${capture.payload.substring(0, 600)}`;
    }, 200);
  }

  private triggerAutomaticObservation(): void {
    this.showMutationProbe = !this.showMutationProbe;
    setTimeout(() => {
      const capture = this.replay.getLastCapture();
      if (capture !== null && capture.record.type === 11) {
        this.result = `Automatic observer captured a structural mutation. Buffered records: ${this.replay.getRecordedRecords({
          applicationId: capture.envelope.application_id,
          sessionId: capture.envelope.session_id,
          viewId: capture.envelope.view_id
        }).length}; durable segments: ${this.replay.getStoredSegments().length}.\n${capture.payload.substring(0, 600)}`;
        return;
      }
      this.result = 'No automatic mutation was observed. Keep Replay enabled, capture through the RUM View Bridge, then try again.';
    }, this.replayConfig.getSnapshotIntervalMs() + 200);
  }

  build() {
    Column({ space: 16 }) {
      Text('Session Replay POC')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('API 12 FrameNode collection → Android replay envelope')
        .fontSize(14)
        .fontColor('#666666')
      Button(this.replayEnabled ? 'Disable Session Replay' : 'Enable Session Replay')
        .width('90%')
        .height(48)
        .backgroundColor(this.replayEnabled ? '#B91C1C' : '#15803D')
        .onClick(() => this.toggleReplay())
      Button('Capture through RUM View Bridge')
        .width('90%')
        .height(48)
        .enabled(this.replayEnabled)
        .onClick(() => {
          FTRUMGlobalManager.getInstance().startView('session-replay-poc-bridge')
            .then(() => {
              this.bridgeViewActive = true;
              this.showBridgeCapture('RUM View bridge');
            })
            .catch((error: Error) => {
              this.result = `RUM View bridge failed: ${error.message}`;
            });
        })
      Button('Capture through RUM Error Bridge')
        .width('90%')
        .height(48)
        .enabled(this.replayEnabled)
        .onClick(() => {
          FTRUMGlobalManager.getInstance().addError(
            'SessionReplayPocError',
            'Manual bridge verification error',
            ErrorType.CUSTOM,
            AppState.RUN
          );
          this.showBridgeCapture('RUM Error bridge');
        })
      Button('Toggle Layout for Automatic Observation')
        .width('90%')
        .height(48)
        .enabled(this.replayEnabled)
        .onClick(() => this.triggerAutomaticObservation())
      Button('Capture Incremental Mutation')
        .width('90%')
        .height(48)
        .enabled(this.replayEnabled)
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
        .enabled(this.replayEnabled)
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
