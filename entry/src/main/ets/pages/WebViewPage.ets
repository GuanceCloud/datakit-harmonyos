import { webview } from "@kit.ArkWeb";
import { FTRUMConfig, FTWebViewHandler } from "@guancecloud/ft_sdk/Index";
import { KEY_WEB_VIEW_URL } from "../entryability/EntryAbility";
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';

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
  private rebuildTimer: number = -1;

  aboutToAppear() {
    // Initialize WebView handler early if controller is available
    if (this.browserTabController && !this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
      this.isInitialized = true;
    }
  }

  aboutToDisappear() {
    if (this.rebuildTimer !== -1) clearTimeout(this.rebuildTimer);
    this.rebuildTimer = -1;
    this.webViewHandler.clearWebController();
    this.isInitialized = false;
  }

  onPageShow() {
    this.mainWebMounted = true;
    // Ensure handler is initialized when page becomes visible
    if (!this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
      this.isInitialized = true;
    }
  }

  onPageHide() {
    // No additional cleanup needed
  }

  private rebuildWeb(): void {
    if (this.rebuildTimer !== -1) return;
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
      FTSessionReplay.getInstance().notifyPageChanged();
    }, 50);
  }

  build() {
    NavDestination() {
      Column() {
        TestPageHeader({
          title: 'WebView'
        })

        Row({ space: 6 }) {
          Button('Replay 开/关').fontSize(12).onClick(() => {
            const replay = FTSessionReplay.getInstance();
            if (replay.isEnabled()) replay.disable();
            else { replay.start(); this.rebuildWeb(); }
            this.replayStatus = replay.isEnabled() ? 'Replay 已开启' : 'Replay 已关闭';
          })
          Button('上传').fontSize(12).onClick(() => {
            FTSessionReplay.getInstance().flush().then((result) => {
              this.replayStatus = `上传 ${result.uploadedSegments}，剩余 ${result.remainingSegments}`;
            }).catch((error: Error) => { this.replayStatus = error.message; });
          })
          Button('重建 Web').fontSize(12).onClick(() => this.rebuildWeb())
          Button('内置页').fontSize(12).onClick(() => { this.fixtureMode = true; this.rebuildWeb(); })
        }.padding(6)
        Row({ space: 6 }) {
          Button('调整区域').fontSize(12).onClick(() => {
            this.compactWeb = !this.compactWeb;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
          Button('隐藏/显示').fontSize(12).onClick(() => {
            this.mainWebVisible = !this.mainWebVisible;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
          Button('双 Web').fontSize(12).onClick(() => {
            this.secondWebMounted = !this.secondWebMounted;
            FTSessionReplay.getInstance().notifyPageChanged();
          })
          if (this.secondWebMounted) {
            Button('第二个显隐').fontSize(12).onClick(() => {
              this.secondWebVisible = !this.secondWebVisible;
              FTSessionReplay.getInstance().notifyPageChanged();
            })
          }
        }.padding(6)
        Text(`${this.replayStatus}  slot=${this.webViewHandler.getSessionReplaySlotId()}`)
          .fontSize(11).maxLines(2)

        Row() {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .visibility(this.progress < 100 ? Visibility.Visible : Visibility.Hidden)
        }

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
            // Register JavaScript proxy for direct communication with browser-sdk
            // browser-sdk will call window.FTWebViewJavascriptBridge.sendEvent() directly
            .javaScriptProxy(this.webViewHandler.getJavaScriptProxy(this.browserTabController))
            .onAreaChange(() => FTSessionReplay.getInstance().notifyPageChanged())
            .onProgressChange((callback: OnProgressChangeEvent) => {
              this.progress = callback.newProgress
            })
            .onPageEnd(() => {
              if (this.fixtureMode) return;
              // Handle blank page scenario - inject bridge first, then load target URL
              if (!this.hasLoadedTargetUrl && this.webViewUrl === "about:blank") {
                // Ensure handler is initialized
                if (!this.isInitialized) {
                  const rumConfig = new FTRUMConfig();
                  rumConfig.setEnableTraceWebView(true);
                  this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
                  this.isInitialized = true;
                }

                // Get target URL from StorageLink (synced from EntryAbility runtime config)
                const targetUrl: string = this.storedWebViewUrl || "about:blank";
                this.hasLoadedTargetUrl = true;
                this.webViewUrl = targetUrl;
                this.browserTabController.loadUrl(targetUrl);
                return;
              }

              // Normal page load - ensure monitoring is initialized (only once)
              if (!this.isInitialized) {
                const rumConfig = new FTRUMConfig();
                rumConfig.setEnableTraceWebView(true);
                this.webViewHandler.setWebView(this.browserTabController, rumConfig, 'replay-main-web');
                this.isInitialized = true;
              }
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: this.compactWeb ? 24 : 0, top: this.compactWeb ? 12 : 0 })
        .clip(true)
        .border({ width: 1, color: '#2563EB' })
        if (this.secondWebMounted) {
          ReplaySecondaryWebPane({ url: this.storedWebViewUrl, useFixture: this.fixtureMode })
            .height(180)
            .visibility(this.secondWebVisible ? Visibility.Visible : Visibility.Hidden)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
    }
  }
}
