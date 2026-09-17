import router from '@ohos.router';
import { Context } from '@kit.AbilityKit';
import { AppState, ErrorType, FTRUMGlobalManager, FTSDK } from '@guancecloud/ft_sdk';
import {
  FTSessionReplayConfig,
  FTSessionReplay,
  SessionReplayContext,
  SessionReplayGlobalContext,
  TouchPrivacy
} from '@guancecloud/ft_session_replay';

@Entry
@Component
struct SessionReplayPocPage {
  @State result: string = 'Ready to capture a privacy-safe Full Snapshot.';
  @State showMutationProbe: boolean = false;
  @State replayEnabled: boolean = false;
  @State uploadInFlight: boolean = false;
  private bridgeViewActive: boolean = false;
  private readonly replayConfig: FTSessionReplayConfig =
    new FTSessionReplayConfig().setMaxNodesPerSnapshot(300).setTouchPrivacy(TouchPrivacy.SHOW);
  private readonly replay: FTSessionReplay = FTSessionReplay.getInstance();

  aboutToAppear(): void {
    this.replayEnabled = this.replay.isEnabled();
    if (this.replayEnabled) {
      this.replay.registerRoot(this.getUIContext(), 'session-replay-poc-root', vp2px(1));
    }
  }

  aboutToDisappear(): void {
    this.replay.unregisterRoot();
    if (!this.bridgeViewActive) {
      return;
    }
    FTRUMGlobalManager.getInstance().stopView()
      .then(() => {
        this.bridgeViewActive = false;
      })
      .catch(() => {
        this.bridgeViewActive = false;
      });
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

  private requireRUMBridge(): boolean {
    const rumConfig = FTSDK.getRumConfig();
    if (rumConfig !== null && rumConfig.getRumAppId().trim().length > 0) {
      return true;
    }
    this.result = 'RUM View bridge is unavailable because RUM is not initialized. Relaunch the demo with a non-empty --ps appId <your_rum_app_id>, then enable Session Replay and try again.';
    return false;
  }

  private showBridgeCapture(source: string): void {
    setTimeout(() => {
      const capture = this.replay.getLastCapture();
      if (capture === null) {
        const root = this.getUIContext().getFrameNodeById('session-replay-poc-root');
        const failure = this.replay.getLastCaptureFailure();
        this.result = root === null
          ? `${source} did not produce a Replay capture because the Replay root is not attached. Return to this page, enable Replay again, and retry.`
          : failure === null
            ? `${source} did not produce a Replay capture. Replay is enabled and the root is attached; retry after the page is fully rendered.`
            : `${source} did not produce a Replay capture: ${failure}`;
        return;
      }
      const totalRecords = this.replay.getRecordedRecords({
        applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id,
        viewId: capture.envelope.view_id
      }).length;
      this.result = `${source} captured ${capture.wireframeCount} wireframes; buffered records: ${totalRecords}; durable segments: ${this.replay.getStoredSegments().length}; deferred error segments: ${this.replay.getDeferredErrorSegments().length}.\n${capture.payload.substring(0, 600)}`;
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
        }).length}; durable segments: ${this.replay.getStoredSegments().length}; deferred error segments: ${this.replay.getDeferredErrorSegments().length}.\n${capture.payload.substring(0, 600)}`;
        return;
      }
      this.result = 'No automatic mutation was observed. Keep Replay enabled, capture through the RUM View Bridge, then try again.';
    }, this.replayConfig.getSnapshotIntervalMs() + 200);
  }

  private showLifecycleSignal(source: string, payload: string | null): void {
    if (payload === null) {
      this.result = `${source} was ignored. Enable Replay and start the RUM View bridge first.`;
      return;
    }
    this.result = `${source} captured.\n${payload.substring(0, 600)}`;
  }

  private recordFocusLoss(): void {
    const capture = this.replay.recordFocus(false);
    this.showLifecycleSignal('Focus signal', capture === null ? null : capture.payload);
  }

  private recordViewportResize(): void {
    const capture = this.replay.recordViewportResize(vp2px(720), vp2px(360));
    this.showLifecycleSignal('Viewport resize signal', capture === null ? null : capture.payload);
  }

  private recordTouchSignal(): void {
    const capture = this.replay.recordTouch('down', 1, vp2px(120), vp2px(160));
    this.showLifecycleSignal('Touch signal', capture === null ? null : capture.payload);
  }

  private uploadDurableSegments(): void {
    if (this.uploadInFlight) {
      return;
    }
    this.uploadInFlight = true;
    this.result = 'Uploading durable Session Replay segments...';
    this.replay.flush()
      .then((upload) => {
        this.result = upload.success
          ? `Replay upload succeeded: ${upload.uploadedSegments} segment(s) acknowledged; ${upload.remainingSegments} remain.`
          : `Replay upload was not acknowledged (code ${upload.code}): ${upload.message} ${upload.remainingSegments} segment(s) remain for retry.`;
      })
      .catch(() => {
        this.result = `Replay upload failed unexpectedly. ${this.replay.getStoredSegments().length} segment(s) remain for retry.`;
      })
      .finally(() => {
        this.uploadInFlight = false;
      });
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Text('Session Replay POC')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('API 12 FrameNode collection → Android replay envelope')
            .fontSize(14)
            .fontColor('#666666')
          Column({ space: 8 }) {
            Text('功能说明')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
            Text('采集 ArkUI / ArkWeb 的页面结构和增量变化，并关联 RUM View、错误、焦点、视口及触摸信号，生成可上传到 Studio 的会话回放数据。')
              .fontSize(14)
              .fontColor('#444444')
          }
          .width('90%')
          .padding(14)
          .backgroundColor('#EEF6FF')
          .borderRadius(10)
          Column({ space: 8 }) {
            Text('如何开启会话回放')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
            Text('1. 使用非空 appId 初始化 FTSDK 与 RUM。\n2. 点击下方 Enable Session Replay。\n3. 点击 Capture through RUM View Bridge 建立关联的 RUM View。\n4. 使用其他采集按钮验证记录；配置 DataKit / Dataway 后点击 Upload Durable Replay Segments 上传。')
              .fontSize(14)
              .fontColor('#444444')
            Text('提示：本 POC 为便于验证将触摸隐私设为 SHOW；生产环境建议保留默认 HIDE。')
              .fontSize(12)
              .fontColor('#9A6700')
          }
          .width('90%')
          .padding(14)
          .backgroundColor('#FFF8E6')
          .borderRadius(10)
          Text(this.replayEnabled ? '当前状态：会话回放已开启' : '当前状态：会话回放未开启')
            .width('90%')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.replayEnabled ? '#15803D' : '#B91C1C')
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
              if (!this.requireRUMBridge()) {
                return;
              }
              // Bind again immediately before RUM creates the View. This makes
              // the POC resilient when ArkUI reconstructed its root after the
              // page's aboutToAppear callback.
              if (!this.replay.registerRoot(this.getUIContext(), 'session-replay-poc-root', vp2px(1))) {
                this.replayEnabled = false;
                this.result = 'Session Replay is disabled. Relaunch the demo with a non-empty RUM appId, then enable Replay before capturing.';
                return;
              }
              setTimeout(() => {
                FTRUMGlobalManager.getInstance().startView('session-replay-poc-bridge')
                  .then(() => {
                    this.bridgeViewActive = true;
                    this.showBridgeCapture('RUM View bridge');
                  })
                  .catch((error: Error) => {
                    this.result = `RUM View bridge failed: ${error.message}`;
                  });
              }, 16);
            })
          Button('Capture through RUM Error Bridge')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => {
              if (!this.requireRUMBridge()) {
                return;
              }
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
          Button('Emit Focus Loss Signal')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => this.recordFocusLoss())
          Button('Emit Viewport Resize Signal')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => this.recordViewportResize())
          Button('Emit Touch Signal')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => this.recordTouchSignal())
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
          Button(this.uploadInFlight ? 'Uploading Replay Segments...' : 'Upload Durable Replay Segments')
            .width('90%')
            .height(48)
            .enabled(!this.uploadInFlight)
            .onClick(() => this.uploadDurableSegments())
          Column({ space: 8 }) {
            Text('验证输出')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            Text(this.result)
              .width('100%')
              .fontSize(12)
              .fontColor('#333333')
          }
          .width('90%')
          .padding(12)
          .backgroundColor('#F6F8FA')
          .borderRadius(10)
          Button('Back')
            .width('90%')
            .height(44)
            .onClick(() => router.back())
        }
        .width('100%')
        .padding(20)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .id('session-replay-poc-root')
    .width('100%')
    .height('100%')
  }
}
