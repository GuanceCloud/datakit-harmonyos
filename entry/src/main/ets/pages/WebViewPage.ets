import { webview } from "@kit.ArkWeb";
import { FTWebViewHandler } from "shareLibrary/src/main/ets/components/web/FTWebViewHandler";
import { FTRUMConfig } from "shareLibrary/src/main/ets/components/Configs";
import { KEY_WEB_VIEW_URL } from "../entryability/EntryAbility";
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';

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

  aboutToAppear() {
    // Initialize WebView handler early if controller is available
    if (this.browserTabController && !this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig);
      this.isInitialized = true;
    }
  }

  aboutToDisappear() {
    this.webViewHandler.clearWebController();
  }

  onPageShow() {
    // Ensure handler is initialized when page becomes visible
    if (!this.isInitialized) {
      const rumConfig = new FTRUMConfig();
      rumConfig.setEnableTraceWebView(true);
      this.webViewHandler.setWebView(this.browserTabController, rumConfig);
      this.isInitialized = true;
    }
  }

  onPageHide() {
    // No additional cleanup needed
  }

  build() {
    NavDestination() {
      Column() {
        TestPageHeader({
          title: 'WebView'
        })

        Row() {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .visibility(this.progress < 100 ? Visibility.Visible : Visibility.Hidden)
        }

        Row() {
          Web({ src: this.webViewUrl, controller: this.browserTabController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            // Register JavaScript proxy for direct communication with browser-sdk
            // browser-sdk will call window.FTWebViewJavascriptBridge.sendEvent() directly
            .javaScriptProxy(this.webViewHandler.getJavaScriptProxy(this.browserTabController))
            .onProgressChange((callback: OnProgressChangeEvent) => {
              this.progress = callback.newProgress
            })
            .onPageEnd(() => {
              // Handle blank page scenario - inject bridge first, then load target URL
              if (!this.hasLoadedTargetUrl && this.webViewUrl === "about:blank") {
                // Ensure handler is initialized
                if (!this.isInitialized) {
                  const rumConfig = new FTRUMConfig();
                  rumConfig.setEnableTraceWebView(true);
                  this.webViewHandler.setWebView(this.browserTabController, rumConfig);
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
                this.webViewHandler.setWebView(this.browserTabController, rumConfig);
                this.isInitialized = true;
              }
            })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
    }
  }
}
