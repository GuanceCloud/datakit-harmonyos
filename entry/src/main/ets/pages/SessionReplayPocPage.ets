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
  @State fixedSizeProbe: string = 'Replay text A';
  @State orderedProbes: Array<string> = ['Replay node A', 'Replay node B'];
  @State touchResult: string = 'Touch and drag here';
  @State animationX: number = 0;
  @State animationOpacity: number = 1;
  private readonly swiper: SwiperController = new SwiperController();
  private bridgeViewActive: boolean = false;
  private readonly replay: FTSessionReplay = FTSessionReplay.getInstance();

  aboutToAppear(): void {
    this.replayEnabled = this.replay.isEnabled();
    if (this.replayEnabled) {
      this.registerPocImageAsset();
    }
  }

  aboutToDisappear(): void {
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
      this.result = `${source} captured ${capture.wireframeCount} wireframes; buffered records: ${totalRecords}; durable segments: ${this.replay.getStoredSegments().length}; durable resources: ${this.replay.getStoredResources().length}; deferred error segments: ${this.replay.getDeferredErrorSegments().length}.\n${capture.payload.substring(0, 600)}`;
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
    }, 320);
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
          Text('Session Replay Demo')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Image($r('app.media.startIcon'))
            .id('session-replay-poc-image')
            .width(72)
            .height(72)
            .objectFit(ImageFit.Contain)
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
            Text('1. 使用非空 appId 启动 Demo，点击 Enable Session Replay 开启，页面会自动关联 RUM View。\n2. 在触摸板拖动、滑动 Swiper，点击位移/淡入淡出按钮，再进入动画页面并返回。\n3. 配置 DataKit / Dataway 后点击 Upload Durable Replay Segments，在 Studio 对照轨迹、动画中间过程和最终画面。')
              .fontSize(14)
              .fontColor('#444444')
            Text('提示：此验证页面将触摸隐私设为 SHOW；生产环境建议保留默认 HIDE。')
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
          Text(this.touchResult)
            .id('session-replay-touch-pad')
            .width('90%')
            .height(120)
            .textAlign(TextAlign.Center)
            .backgroundColor('#DDF4FF')
            .onTouch((event: TouchEvent) => {
              const point = event.changedTouches[0];
              if (point !== undefined) this.touchResult = `Touch ${event.type}: ${Math.round(point.windowX)}, ${Math.round(point.windowY)}`;
            })
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
          Text(this.fixedSizeProbe)
            .id('session-replay-fixed-text')
            .width('90%')
            .height(32)
            .fontSize(16)
          Button('Change Fixed-size Text')
            .id('session-replay-fixed-text-button')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => {
              this.fixedSizeProbe = this.fixedSizeProbe === 'Replay text A' ? 'Replay text B' : 'Replay text A';
            })
          Column() {
            ForEach(this.orderedProbes, (label: string) => {
              Text(label)
                .id(label === 'Replay node A' ? 'session-replay-order-a' : 'session-replay-order-b')
                .width('100%')
                .height(28)
            }, (label: string) => label)
          }
          .width('90%')
          Button('Reorder Replay Nodes')
            .id('session-replay-reorder-button')
            .width('90%')
            .height(48)
            .enabled(this.replayEnabled)
            .onClick(() => {
              this.orderedProbes = this.orderedProbes.slice().reverse();
            })
          Swiper(this.swiper) {
            Text('Replay slide A').id('session-replay-slide-a')
              .fontSize(24).width('100%').height('100%').backgroundColor('#DDF4FF')
            Text('Replay slide B').id('session-replay-slide-b')
              .fontSize(24).width('100%').height('100%').backgroundColor('#DCFCE7')
            Text('Replay slide C').id('session-replay-slide-c')
              .fontSize(24).width('100%').height('100%').backgroundColor('#FEF3C7')
          }
          .id('session-replay-swiper')
          .width('90%').height(150).loop(false).duration(800)
          Button('Animate Next Slide')
            .id('session-replay-swiper-next')
            .width('90%').height(48)
            .onClick(() => this.swiper.showNext())
          Text('Replay moving probe')
            .id('session-replay-moving-probe')
            .width(160).height(40).backgroundColor('#93C5FD')
            .translate({ x: this.animationX }).opacity(this.animationOpacity)
          Button('Animate Translation and Fade')
            .id('session-replay-animation-button')
            .width('90%').height(48)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 800, curve: Curve.Linear }, () => {
                this.animationX = this.animationX === 0 ? 120 : 0;
                this.animationOpacity = this.animationOpacity === 1 ? 0.25 : 1;
              });
            })
          Button('Open Animated Replay Page')
            .id('session-replay-transition-button')
            .width('90%').height(48)
            .onClick(() => router.pushUrl({ url: 'pages/SessionReplayTransitionPage' }))
          Button('Default Router Transition')
            .id('session-replay-default-transition-button')
            .width('90%').height(44)
            .onClick(() => router.pushUrl({ url: 'pages/SessionReplayDefaultTransitionPage' }))
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
