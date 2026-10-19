import router from '@ohos.router';
import { Context } from '@kit.AbilityKit';
import { AppState, ErrorType, FTRUMGlobalManager, FTSDK } from '@guancecloud/ft_sdk';
import {
  FTSessionReplay,
  SessionReplayContext,
  SessionReplayGlobalContext
} from '@guancecloud/ft_session_replay';

@Entry
@Component
struct SessionReplayPocPage {
  @State result: string = 'Session Replay is off. Tap Enable Session Replay to start recording.';
  @State showMutationProbe: boolean = false;
  @State replayEnabled: boolean = false;
  @State uploadInFlight: boolean = false;
  private readonly replay: FTSessionReplay = FTSessionReplay.getInstance();

  aboutToAppear(): void {
    this.replayEnabled = this.replay.isEnabled();
    if (this.replayEnabled) {
      this.registerPocImageAsset();
    }
  }

  private toggleReplay(): void {
    if (this.replayEnabled) {
      this.disableReplay();
      return;
    }
    if (!this.requireRUMBridge()) {
      return;
    }
    this.replay.start();
    this.replayEnabled = this.replay.isEnabled();
    if (this.replayEnabled) {
      this.registerPocImageAsset();
    }
    this.result = this.replayEnabled
      ? 'Session Replay started. The page root will attach automatically after layout.'
      : 'Session Replay could not start.';
  }

  private disableReplay(): void {
    this.replay.disable();
    this.replayEnabled = false;
    this.result = 'Session Replay stopped. Tap Enable Session Replay to start a new recording.';
  }

  /** Registers the demo-only image bytes so the image wireframe can reference a durable Replay asset. */
  private registerPocImageAsset(): void {
    const context = getContext(this) as Context;
    context.resourceManager.getMediaContent($r('app.media.startIcon'))
      .then((bytes: Uint8Array): void => {
        this.replay.registerImageAsset('session-replay-poc-image', bytes, 'image/png');
      })
      .catch((): void => {
        // The page still records a masked image wireframe if a demo resource cannot be read.
      });
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
          ? `${source} did not produce a Replay capture because the page root is not available. Return to this page and retry.`
          : failure === null
            ? `${source} did not produce a Replay capture. Automatic root binding or the snapshot may still be pending; retry after the page is fully rendered.`
            : `${source} did not produce a Replay capture: ${failure}`;
        return;
      }
      const totalRecords = this.replay.getRecordedRecords({
        applicationId: capture.envelope.application_id,
        sessionId: capture.envelope.session_id,
        viewId: capture.envelope.view_id
      }).length;
      this.result = `${source} captured ${capture.wireframeCount} wireframes; buffered records: ${totalRecords}; durable segments: ${this.replay.getStoredSegments().length}; durable resources: ${this.replay.getStoredResources().length}; deferred error segments: ${this.replay.getDeferredErrorSegments().length}.\n${capture.payload}`;
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
        }).length}; durable segments: ${this.replay.getStoredSegments().length}; deferred error segments: ${this.replay.getDeferredErrorSegments().length}.\n${capture.payload}`;
        return;
      }
      this.result = 'No automatic mutation was observed. Keep Replay enabled, capture through the RUM View Bridge, then try again.';
    }, 320);
  }

  private showLifecycleSignal(source: string, payload: string | null): void {
    if (payload === null) {
      this.result = `${source} was ignored. Enable Replay and start the RUM View bridge first.`;
      return;
    }
    this.result = `${source} captured.\n${payload}`;
  }

  private recordFocusLoss(): void {
    const capture = this.replay.recordFocus(false);
    this.showLifecycleSignal('Focus signal', capture === null ? null : capture.payload);
  }

  private recordViewportResize(): void {
    const capture = this.replay.recordViewportResize(vp2px(720), vp2px(360));
    this.showLifecycleSignal('Viewport resize signal', capture === null ? null : capture.payload);
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

  onPageShow(): void {
    this.replayEnabled = this.replay.isEnabled();
  }

  private captureViewBridge(): void {
    if (!this.requireRUMBridge()) return;
    FTRUMGlobalManager.getInstance().startView('session-replay-poc-bridge')
      .then(() => {
        this.showBridgeCapture('RUM View bridge');
      })
      .catch((error: Error) => {
        this.result = `RUM View bridge failed: ${error.message}`;
      });
  }

  private captureErrorBridge(): void {
    if (!this.requireRUMBridge()) return;
    FTRUMGlobalManager.getInstance().addError(
      'SessionReplayPocError', 'Manual bridge verification error', ErrorType.CUSTOM, AppState.RUN
    );
    this.showBridgeCapture('RUM Error bridge');
  }

  private captureFullSnapshot(): void {
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
        this.getUIContext(), 'session-replay-poc-root', context, vp2px(1)
      );
      this.result = `Captured ${capture.wireframeCount} wireframes.\n${capture.payload}`;
    } catch (error) {
      this.result = `Capture failed: ${String(error)}`;
    }
  }

  private captureIncrementalMutation(): void {
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
          this.getUIContext(), 'session-replay-poc-root', context, vp2px(1)
        );
        this.result = capture === null
          ? 'No structural mutation detected after the baseline.'
          : `Mutation captured with type ${capture.record.type}.\n${capture.payload}`;
      } catch (error) {
        this.result = `Mutation capture failed: ${String(error)}`;
      }
    }, 80);
  }

  @Builder
  private sectionTitle(title: string, description: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(18).fontWeight(FontWeight.Medium)
      Text(description).fontSize(13).fontColor('#64748B')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('返回').height(36).onClick(() => router.back())
        Text('Session Replay 功能测试').fontSize(21).fontWeight(FontWeight.Bold).layoutWeight(1)
      }
      .width('100%').padding(16).backgroundColor(Color.White)
      Scroll() {
        Column({ space: 16 }) {
          this.sectionTitle('录制与上传', '开启会话回放 → 进入复杂组件采集测试页操作 → 返回本页上传 → 在 Studio 对照回放。')
          Text(this.replayEnabled ? '当前状态：会话回放已开启' : '当前状态：会话回放未开启')
            .id('session-replay-status')
            .width('100%').fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.replayEnabled ? '#15803D' : '#B91C1C')
          Button(this.replayEnabled ? 'Disable Session Replay' : 'Enable Session Replay')
            .id('session-replay-enable-button')
            .width('100%').height(48)
            .backgroundColor(this.replayEnabled ? '#B91C1C' : '#15803D')
            .onClick(() => this.toggleReplay())
          Button(this.uploadInFlight ? 'Uploading Replay Segments...' : 'Upload Durable Replay Segments')
            .id('session-replay-upload-button')
            .width('100%').height(48).enabled(!this.uploadInFlight)
            .onClick(() => this.uploadDurableSegments())
          Button('复杂组件采集测试页')
            .id('session-replay-transition-button')
            .width('100%').height(48).backgroundColor('#0E7490')
            .onClick(() => router.pushUrl({ url: 'pages/SessionReplayTransitionPage' }))
          Divider()
          this.sectionTitle('RUM 关联与快照', '使用非空 appId 启动 Demo；分别验证 View、错误关联、完整快照和增量快照。')
          Button('Capture through RUM View Bridge')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.captureViewBridge())
          Button('Capture through RUM Error Bridge')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.captureErrorBridge())
          Button('Capture Full Snapshot')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.captureFullSnapshot())
          Button('Capture Incremental Mutation')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.captureIncrementalMutation())
          Image($r('app.media.startIcon'))
            .id('session-replay-poc-image').width(48).height(48).objectFit(ImageFit.Contain)
          if (this.showMutationProbe) {
            Text('Incremental layout probe')
              .id('session-replay-functional-mutation')
              .width('100%').padding(12).backgroundColor('#DDF4FF')
          }
          Divider()
          this.sectionTitle('自动观察与生命周期', '验证布局变化、焦点丢失、视口变化及默认 Router 页面切换。')
          Button('Toggle Layout for Automatic Observation')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.triggerAutomaticObservation())
          Button('Emit Focus Loss Signal')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.recordFocusLoss())
          Button('Emit Viewport Resize Signal')
            .width('100%').height(48).enabled(this.replayEnabled)
            .onClick(() => this.recordViewportResize())
          Button('Default Router Transition')
            .id('session-replay-default-transition-button')
            .width('100%').height(48)
            .onClick(() => router.pushUrl({ url: 'pages/SessionReplayDefaultTransitionPage' }))
          Column({ space: 8 }) {
            Text('验证输出').fontSize(16).fontWeight(FontWeight.Medium)
            Text(this.result).width('100%').fontSize(12).fontColor('#333333')
          }
          .width('100%').padding(14).backgroundColor('#EEF6FF').borderRadius(10)
        }
        .width('100%').padding(20).alignItems(HorizontalAlign.Start)
      }
      .width('100%').layoutWeight(1)
    }
    .id('session-replay-poc-root')
    .width('100%').height('100%').backgroundColor('#F8FAFC')
  }

  // pageTransition(): void {
  //   PageTransitionEnter({ type: RouteType.None, duration: 0 })
  //   PageTransitionExit({ type: RouteType.None, duration: 0 })
  // }
}
