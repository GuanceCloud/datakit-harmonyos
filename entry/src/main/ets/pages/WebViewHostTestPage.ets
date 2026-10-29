import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { FTSDK, FTWebViewHandler, FTRemoteConfigFetchResult } from '@guancecloud/ft_sdk/Index';
import { FTSessionReplay } from '@guancecloud/ft_session_replay';
import { TestPageHeader } from '../components/TestPageHeader';

interface HostProbeConfig { appId: string; datakitOrigin: string; }

class HostProbeFetchResult implements FTRemoteConfigFetchResult {
  private listener: (success: boolean) => void;
  constructor(listener: (success: boolean) => void) { this.listener = listener; }
  onResult(success: boolean): void { this.listener(success); }
}

/** Offline ArkWeb probe; remote Host updates still use the real SDK fetch/cache path. */
@Entry
@Component
export struct WebViewHostTestPage {
  @State private pageUrl: string = 'https://sub.example.com/host-probe';
  @State private hosts: string = 'example.com';
  @State private result: string = '';
  @State private mounted: boolean = true;
  @State private declarative: boolean = false;
  @State private bindingMode: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private handler: FTWebViewHandler = new FTWebViewHandler();
  private rebuildTimer: number = -1;
  private pageGeneration: number = 0;
  private probeLoadRequested: boolean = false;

  aboutToDisappear(): void {
    this.pageGeneration++;
    if (this.rebuildTimer !== -1) clearTimeout(this.rebuildTimer);
    this.handler.clearWebController();
  }

  private applyPolicy(base: boolean, value: string[] | null): void {
    try {
      if (base) FTSDK.getSDKConfig()?.setAllowWebViewHost(value);
      else FTSDK.getRumConfig()?.setAllowWebViewHost(value);
      this.result = `${base ? 'Base' : 'RUM'} 已设置 ${JSON.stringify(value)}；已有绑定保持原策略。点击重建 Web 后验证。`;
    } catch (error) { this.result = `配置被拒绝：${(error as Error).message}`; }
  }

  private inputHosts(): string[] { return this.hosts.split(','); }

  private refreshRemote(): void {
    FTSDK.updateRemoteConfig(0, new HostProbeFetchResult((success: boolean): void => {
      this.result = `远程更新结果=${success}；请检查服务器响应并重建 Web。`;
    }));
  }

  private rebuild(): void {
    if (this.rebuildTimer !== -1) return;
    this.pageGeneration++;
    this.probeLoadRequested = false;
    this.mounted = false;
    this.handler.clearWebController();
    this.controller = new webview.WebviewController();
    this.bindingMode = this.declarative;
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.mounted = true;
    }, 100);
  }

  private async loadProbe(): Promise<void> {
    const generation = this.pageGeneration;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) throw new Error('缺少 UI Context');
      const bytes = await context.resourceManager.getRawFileContent('webview_host_probe.html');
      if (generation !== this.pageGeneration) return;
      const html = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const config: HostProbeConfig = { appId: FTSDK.getRumConfig()?.getRumAppId() ?? '',
        datakitOrigin: FTSDK.getSDKConfig()?.getDatakitUrl() ?? '' };
      const injected = html.replace('const config = window.HOST_PROBE_CONFIG || {};',
        `const config = ${JSON.stringify(config).replace(/</g, '\\u003c')};`);
      this.controller.loadData(injected, 'text/html', 'UTF-8', this.pageUrl, this.pageUrl);
    } catch (error) { this.result = `验证页加载失败：${(error as Error).message}`; }
  }

  private pageEnded(): void {
    // Wait until the Web component's initial src has loaded; otherwise it can
    // overwrite loadData called directly from onControllerAttached.
    if (this.probeLoadRequested) return;
    this.probeLoadRequested = true;
    this.loadProbe();
  }

  private async inspect(emit: boolean = false): Promise<void> {
    try {
      const script = emit ? 'window.webHostProbe.emit(true)' :
        'window.webHostProbe.report(window.webHostProbe.inspect())';
      const value = await this.controller.runJavaScript(script);
      let readable = value;
      try {
        const decoded = JSON.parse(value) as Object;
        if (typeof decoded === 'string') readable = decoded;
      } catch (_) {}
      this.result = `controllerUrl=${this.controller.getUrl()}\n${readable}`;
    } catch (error) { this.result = `读取失败：${(error as Error).message}`; }
  }

  build() {
    Column({ space: 6 }) {
      TestPageHeader({ title: 'WebView Host 验证' })
      Text('配置只影响新绑定。验证“未配置 Base”需重启应用且不点击 Base 按钮。')
        .fontSize(12).width('100%')
      TextInput({ text: this.pageUrl, placeholder: '离线页的 baseUrl/historyUrl' })
        .id('host-probe-url').onChange((value: string): void => { this.pageUrl = value; })
      TextInput({ text: this.hosts, placeholder: 'Host，多个用逗号分隔' })
        .id('host-probe-hosts').onChange((value: string): void => { this.hosts = value; })
      Row({ space: 6 }) {
        Button('Base null').id('host-base-null').onClick(() => this.applyPolicy(true, null))
        Button('Base []').id('host-base-empty').onClick(() => this.applyPolicy(true, []))
        Button('Base Host').id('host-base-list').onClick(() => this.applyPolicy(true, this.inputHosts()))
      }
      Row({ space: 6 }) {
        Button('RUM null').id('host-rum-null').onClick(() => this.applyPolicy(false, null))
        Button('RUM []').id('host-rum-empty').onClick(() => this.applyPolicy(false, []))
        Button('RUM Host').id('host-rum-list').onClick(() => this.applyPolicy(false, this.inputHosts()))
      }
      Row({ space: 6 }) {
        Button('重建 Web').id('host-probe-rebuild').onClick(() => this.rebuild())
        Button('检查').id('host-probe-inspect').onClick(() => this.inspect())
        Button('发送探针').id('host-probe-emit').onClick(() => this.inspect(true))
      }
      Row({ space: 6 }) {
        Text('声明式 Proxy').fontSize(12)
        Toggle({ type: ToggleType.Switch, isOn: this.declarative }).id('host-probe-mode')
          .onChange((value: boolean): void => { this.declarative = value; })
        Button('开启 Web Log').id('host-probe-log').onClick(() => {
          const logConfig = FTSDK.getLogConfig();
          if (logConfig === null) {
            this.result = '请先通过 FTSDK.installLogConfig 安装日志配置。';
            return;
          }
          FTSDK.installLogConfig(logConfig.setEnableWebViewLog(true));
          this.result = 'Web Log 已开启，当前日志配置的其他设置保持不变。';
        })
      }
      Row({ space: 6 }) {
        Button('刷新远程').id('host-probe-remote').onClick(() => this.refreshRemote())
        Button('开启 Replay 并重建').id('host-probe-replay').onClick(() => {
          FTSessionReplay.getInstance().start();
          this.rebuild();
        })
      }
      Scroll() { Text(this.result).id('host-probe-result').fontSize(11).width('100%') }
        .width('100%').height(110)
      if (this.mounted) {
        if (this.bindingMode) {
          Web({ src: $rawfile('webview_host_probe.html'), controller: this.controller })
            .id('host-probe-web-declarative').width('100%').layoutWeight(1).javaScriptAccess(true).domStorageAccess(true)
            .javaScriptProxy(this.handler.getJavaScriptProxy(this.controller))
            .onPageEnd(() => this.pageEnded())
        } else {
          Web({ src: $rawfile('webview_host_probe.html'), controller: this.controller })
            .id('host-probe-web').width('100%').layoutWeight(1).javaScriptAccess(true).domStorageAccess(true)
            .onControllerAttached(() => {
              this.handler.setWebView(this.controller);
            })
            .onPageEnd(() => this.pageEnded())
        }
      }
    }.width('100%').height('100%').padding(10)
  }
}
