import { webview } from "@kit.ArkWeb";
import { FTSDK, FTRUMConfig, FTWebViewHandler } from "@guancecloud/ft_sdk/Index";
import { KEY_WEB_VIEW_URL } from "../entryability/EntryAbility";
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';
import { BrowserReplayState, formatWebReplayState, NativeReplayState, WebReplayProbe } from '../utils/WebReplayDiagnostics';

const WEB_TEST_SPACING: number = 12;
const WEB_TEST_BUTTON_HEIGHT: number = 44;

@Component
struct ReplaySecondaryWebPane {
  url: string = 'about:blank';
  useFixture: boolean = false;
  private controller: WebviewController = new webview.WebviewController();
  private handler: FTWebViewHandler = new FTWebViewHandler();

  aboutToAppear() {
    this.handler.setWebView(this.controller, new FTRUMConfig().setEnableTraceWebView(true), 'replay-secondary-web');
  }

  aboutToDisappear() { this.handler.clearWebController(); }

  build() {
    Web({ src: this.useFixture ? $rawfile('session_replay_web.html') : this.url, controller: this.controller })
      .id('replay-secondary-web')
      .width('100%')
      .height('100%')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .javaScriptProxy(this.handler.getJavaScriptProxy(this.controller))
      .onAreaChange(() => FTSessionReplay.getInstance().notifyPageChanged())
  }
}

@Entry
@Component
export struct WebViewPage {
  browserTabController: WebviewController = new webview.WebviewController();
  @State progress: number = 0;
  @State webViewUrl: string = "about:blank";
  @StorageLink(KEY_WEB_VIEW_URL) storedWebViewUrl: string = "about:blank";
  private webViewHandler: FTWebViewHandler = new FTWebViewHandler();
  private isInitialized: boolean = false;
  private hasLoadedTargetUrl: boolean = false;
  @State private mainWebMounted: boolean = true;
  @State private compactWeb: boolean = false;
  @State private mainWebVisible: boolean = true;
  @State private secondWebMounted: boolean = false;
  @State private secondWebVisible: boolean = true;
  @State private fixtureMode: boolean = false;
  @State private replayStatus: string = '';
  @State private nativeReplayEnabled: boolean = false;
  @State private replayDiagnostics: string = '';
  @State private checkingReplay: boolean = false;
  private readonly replayProbe: WebReplayProbe = new WebReplayProbe();
  private browserReplayState: BrowserReplayState | null = null;
  private browserReplayError: string = '';
  private documentLoaded: boolean = false;
  private replayEnabledAtLoad: boolean = false;
  private restoreSecondWeb: boolean = false;
  private rebuildTimer: number = -1;

  aboutToAppear() {
    // Initialize WebView handler early if controller is available
    if (this.browserTabController && !this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
      this.isInitialized = true;
    }
    this.refreshReplayDiagnostics();
  }

  aboutToDisappear() {
    if (this.rebuildTimer !== -1) clearTimeout(this.rebuildTimer);
    this.rebuildTimer = -1;
    this.cancelReplayCheck();
    this.webViewHandler.clearWebController();
    this.isInitialized = false;
    this.documentLoaded = false;
  }

  onPageShow() {
    // A retained document may have evaluated Browser SDK while Replay was off.
    // Recreate it after explicit activation elsewhere; never reload on a timer.
    if (this.documentLoaded && !this.replayEnabledAtLoad && FTSessionReplay.getInstance().isEnabled()) {
      this.rebuildWeb();
      return;
    }
    this.mainWebMounted = true;
    // Ensure handler is initialized when page becomes visible
    if (!this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
      this.isInitialized = true;
    }
    if (this.restoreSecondWeb) { this.secondWebMounted = true; this.restoreSecondWeb = false; }
    this.refreshReplayDiagnostics();
  }

  onPageHide() {
    this.cancelReplayCheck();
    if (this.rebuildTimer !== -1) clearTimeout(this.rebuildTimer);
    this.rebuildTimer = -1;
  }

  private cancelReplayCheck(): void {
    this.replayProbe.cancel();
    this.checkingReplay = false;
    this.browserReplayState = null;
    this.browserReplayError = '';
  }

  private refreshReplayDiagnostics(): void {
    this.nativeReplayEnabled = FTSessionReplay.getInstance().isEnabled();
    const native: NativeReplayState = {
      enabled: this.nativeReplayEnabled,
      webTracing: FTSDK.getRumConfig()?.isEnableTraceWebView() === true,
      slotId: this.webViewHandler.getSessionReplaySlotId()
    };
    this.replayDiagnostics = formatWebReplayState(native, this.browserReplayState, this.browserReplayError);
  }

  private async checkReplayState(): Promise<void> {
    if (!this.mainWebMounted || this.rebuildTimer !== -1) return;
    const controller = this.browserTabController;
    this.checkingReplay = true;
    const result = await this.replayProbe.read((script: string): Promise<string> => controller.runJavaScript(script));
    if (result === null) return;
    this.checkingReplay = false;
    this.browserReplayState = result.state;
    this.browserReplayError = result.error;
    this.refreshReplayDiagnostics();
  }

  private toggleWebSource(): void {
    if (this.rebuildTimer !== -1) return;
    if (this.fixtureMode && !/^https?:\/\/\S+$/i.test(this.storedWebViewUrl.trim())) {
      this.replayStatus = '未配置网络地址，请通过 webViewUrl 设置 HTTP(S) 地址后再切换。';
      return;
    }
    this.fixtureMode = !this.fixtureMode;
    this.replayStatus = this.fixtureMode
      ? '已切换至内置页，请手动启动 Browser Replay'
      : '已切换至网络页，使用 webViewUrl 配置的地址';
    this.rebuildWeb();
  }

  private rebuildWeb(): void {
    if (this.rebuildTimer !== -1) return;
    this.cancelReplayCheck();
    this.documentLoaded = false;
    // Both documents must renegotiate capabilities after Replay activation.
    this.restoreSecondWeb = this.secondWebMounted || this.restoreSecondWeb;
    this.secondWebMounted = false;
    this.mainWebMounted = false;
    this.webViewHandler.clearWebController();
    this.browserTabController = new webview.WebviewController();
    this.webViewUrl = 'about:blank';
    this.hasLoadedTargetUrl = false;
    this.isInitialized = false;
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.webViewHandler.setWebView(this.browserTabController,
        new FTRUMConfig().setEnableTraceWebView(true), 'replay-main-web');
      this.isInitialized = true;
      this.mainWebMounted = true;
      this.secondWebMounted = this.restoreSecondWeb;
      this.restoreSecondWeb = false;
      this.refreshReplayDiagnostics();
      FTSessionReplay.getInstance().notifyPageChanged();
    }, 50);
    this.refreshReplayDiagnostics();
  }

  @Builder
  private controlButton(label: string, buttonId: string, onTap: () => void,
    enabled: boolean = true, primary: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Text(label)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? Color.White : '#1D4ED8')
        .textAlign(TextAlign.Start)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .id(buttonId)
    .width('100%')
    .height(WEB_TEST_BUTTON_HEIGHT)
    .padding(8)
    .borderRadius(8)
    .backgroundColor(primary ? '#2563EB' : Color.White)
    .border({ width: 1, color: primary ? '#2563EB' : '#BFDBFE' })
    .enabled(enabled)
    .onClick(() => onTap())
  }

  @Builder
  private nativeControls() {
    Column({ space: WEB_TEST_SPACING }) {
      Text('NATIVE · 原生控制')
        .width('100%')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1D4ED8')
        .textAlign(TextAlign.Start)

      GridRow({ columns: 3, gutter: WEB_TEST_SPACING }) {
        GridCol() {
          this.controlButton(this.nativeReplayEnabled ? '关闭 Replay' : '开启 Replay',
            'web-replay-toggle-button', () => {
              const replay = FTSessionReplay.getInstance();
              if (replay.isEnabled()) { replay.disable(); this.cancelReplayCheck(); }
              else { replay.start(); this.rebuildWeb(); }
              this.replayStatus = replay.isEnabled() ? '原生 Replay 已开启，Web 重新加载后请检查 Browser 状态' : '原生 Replay 已关闭';
              this.refreshReplayDiagnostics();
            }, true, true)
        }
        GridCol() {
          this.controlButton('上传', 'web-replay-upload-button', () => {
            FTSessionReplay.getInstance().flush().then((result) => {
              this.replayStatus = `${result.success ? '上传成功' : '上传失败'}：${result.uploadedSegments}，剩余 ${result.remainingSegments}`;
              this.refreshReplayDiagnostics();
            }).catch((error: Error) => { this.replayStatus = error.message; });
          })
        }
        GridCol() {
          this.controlButton(this.checkingReplay ? '读取中…' : '检查状态', 'web-replay-check-button',
            () => this.checkReplayState(), !this.checkingReplay && this.mainWebMounted)
        }
        GridCol() {
          this.controlButton('重建 Web', 'web-replay-rebuild-button', () => this.rebuildWeb())
        }
        GridCol() {
          this.controlButton(this.fixtureMode ? '网络页' : '内置页', 'web-replay-fixture-button',
            () => this.toggleWebSource(), this.mainWebMounted)
        }
        GridCol() {
          this.controlButton('调整区域', 'web-replay-resize-button', () => {
            this.compactWeb = !this.compactWeb;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
        }
        GridCol() {
          this.controlButton('隐藏/显示', 'web-replay-visibility-button', () => {
            this.mainWebVisible = !this.mainWebVisible;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
        }
        GridCol() {
          this.controlButton('双 Web', 'web-replay-secondary-button', () => {
            this.secondWebMounted = !this.secondWebMounted;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
        }
        GridCol() {
          this.controlButton('第二个显隐', 'web-replay-secondary-visibility-button', () => {
            this.secondWebVisible = !this.secondWebVisible;
            FTSessionReplay.getInstance().notifyPageChanged();
          }, this.secondWebMounted)
        }
      }
      .width('100%')

      if (this.replayStatus.length > 0) {
        Text(this.replayStatus).width('100%').fontSize(11).lineHeight(16)
          .fontColor('#1D4ED8').textAlign(TextAlign.Start)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Scroll() {
        Column({ space: WEB_TEST_SPACING }) {
          Text(this.replayDiagnostics).id('web-replay-status')
            .width('100%').fontSize(11).lineHeight(16)
            .fontColor(TestPageTheme.RESULT_TEXT_COLOR).textAlign(TextAlign.Start)
          Text('检查状态只读，不会启动网页录制')
            .width('100%').fontSize(11).lineHeight(16)
            .fontColor('#64748B').textAlign(TextAlign.Start)
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(72).padding(WEB_TEST_SPACING)
      .align(Alignment.TopStart).scrollBar(BarState.Auto)
      .backgroundColor(Color.White).borderRadius(8)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding(WEB_TEST_SPACING)
    .backgroundColor('#EFF6FF').borderRadius(10)
    .border({ width: 1, color: '#BFDBFE' })
  }

  @Builder
  private webPaneHeader(title: string, visible: boolean) {
    Text(`${title}  /  ${visible ? (this.fixtureMode ? '内置验证页' : '网络页') : '已隐藏'}`)
      .width('100%')
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor('#0F766E')
      .textAlign(TextAlign.Start)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding(WEB_TEST_SPACING)
      .backgroundColor('#CCFBF1')
  }

  build() {
    NavDestination() {
      Column() {
        TestPageHeader({ title: 'WebView Test' })

        Column({ space: WEB_TEST_SPACING }) {
          this.nativeControls()

          Column() {
            this.webPaneHeader('WEB 01 · 主 WebView', this.mainWebVisible)
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .width('100%').height(2)
              .visibility(this.progress < 100 ? Visibility.Visible : Visibility.Hidden)

            Row() {
              if (this.mainWebMounted) {
                Web({ src: this.fixtureMode ? $rawfile('session_replay_web.html') : this.webViewUrl,
                  controller: this.browserTabController })
                  .id('replay-main-web')
                  .width(this.compactWeb ? '80%' : '100%')
                  .height('100%')
                  .visibility(this.mainWebVisible ? Visibility.Visible : Visibility.Hidden)
                  .javaScriptAccess(true)
                  .domStorageAccess(true)
                  // Keep native component IDs and bridge binding unchanged.
                  .javaScriptProxy(this.webViewHandler.getJavaScriptProxy(this.browserTabController))
                  .onAreaChange(() => FTSessionReplay.getInstance().notifyPageChanged())
                  .onProgressChange((callback: OnProgressChangeEvent) => {
                    this.progress = callback.newProgress
                  })
                  .onPageEnd(() => {
                    // Inject the bridge before loading the configured URL.
                    if (!this.fixtureMode && !this.hasLoadedTargetUrl && this.webViewUrl === "about:blank") {
                      if (!this.isInitialized) {
                        const rumConfig = new FTRUMConfig();
                        rumConfig.setEnableTraceWebView(true);
                        this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
                        this.isInitialized = true;
                      }

                      const targetUrl: string = this.storedWebViewUrl || "about:blank";
                      this.hasLoadedTargetUrl = true;
                      this.webViewUrl = targetUrl;
                      this.browserTabController.loadUrl(targetUrl);
                      return;
                    }

                    if (!this.isInitialized) {
                      const rumConfig = new FTRUMConfig();
                      rumConfig.setEnableTraceWebView(true);
                      this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
                      this.isInitialized = true;
                    }
                    this.documentLoaded = true;
                    this.replayEnabledAtLoad = FTSessionReplay.getInstance().isEnabled();
                    this.checkReplayState();
                  })
              }
            }
            .width('100%').layoutWeight(1)
            .padding(this.compactWeb ? WEB_TEST_SPACING : 0)
            .backgroundColor(Color.White).clip(true)
          }
          .width('100%').layoutWeight(1)
          .backgroundColor('#F0FDFA').borderRadius(10)
          .border({ width: 1, color: '#5EEAD4' }).clip(true)

          if (this.secondWebMounted) {
            Column() {
              this.webPaneHeader('WEB 02 · 第二 WebView', this.secondWebVisible)
              ReplaySecondaryWebPane({ url: this.storedWebViewUrl, useFixture: this.fixtureMode })
                .width('100%').layoutWeight(1)
                .visibility(this.secondWebVisible ? Visibility.Visible : Visibility.Hidden)
            }
            .width('100%').layoutWeight(1)
            .backgroundColor('#F0FDFA').borderRadius(10)
            .border({ width: 1, color: '#5EEAD4' }).clip(true)
          }
        }
        .width('100%').layoutWeight(1)
        .padding(WEB_TEST_SPACING)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
    }
  }
}
