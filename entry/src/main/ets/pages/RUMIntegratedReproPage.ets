import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { TestPageHeader } from '../components/TestPageHeader';
import { IntegratedReproConfig, IntegratedReproReport, RUMIntegratedReproManager } from '../utils/RUMIntegratedReproManager';

@Entry
@Component
struct RUMIntegratedReproPage {
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private manager: RUMIntegratedReproManager = RUMIntegratedReproManager.getInstance();
  private uiTimer: number = -1;
  @State minutes: string = '3';
  @State group: string = 'A';
  @State accelerated: boolean = false;
  @State reconfigure: boolean = false;
  @State timerFocused: boolean = false;
  @State stringPressure: boolean = false;
  @State operationError: string = '';
  @State requestUrl: string = '';
  @State busy: boolean = false;
  @State issue: string = '';
  @State status: string = '尚未开始';
  @State evidence: string = '';
  @State previousRun: string = '';

  aboutToAppear(): void {
    this.previousRun = this.manager.previous(this.context);
    this.refresh();
  }
  onPageShow(): void {
    this.refresh();
    clearInterval(this.uiTimer);
    this.uiTimer = setInterval((): void => { this.refresh(); }, 1000);
  }
  onPageHide(): void { clearInterval(this.uiTimer); }
  aboutToDisappear(): void { clearInterval(this.uiTimer); }

  private refresh(): void {
    this.busy = this.manager.isBusy();
    this.issue = this.manager.readiness();
    const report: IntegratedReproReport = this.manager.snapshot();
    this.status = report.status;
    if (report.runId.length === 0) return;
    this.evidence = `runId=${report.runId}\nPID=${report.pid}；真实 RDB 预检=${report.rdbPreflightViewVerified}` +
      `；数据库中观察到本轮标记=${report.persistedRunMarkerObserved}\n` +
      `页面创建/销毁=${report.pagesCreated}/${report.pagesDestroyed}；前台/后台=${report.foregroundEvents}/${report.backgroundEvents}\n` +
      `Action 提交=${report.actionsSubmitted}；Log 提交=${report.logsSubmitted}；观察到 Session 变化=${report.observedSessionChanges}\n` +
      `强制过期=${report.forcedExpiries}；重新配置=${report.rumReconfigurations}；诊断错误=${report.diagnosticErrors}\n` +
      `阶段=${report.phase}；完整等待窗口=${report.quietWindowsCompleted}/${report.quietWindowsStarted}；有 Session 更新的完整窗口=${report.quietWindowsWithSessionChange}\n` +
      `窗口内 Session 更新=${report.quietSessionChanges}；队列变化采样=${report.observedQueueChanges}；timer ID 变化=${report.sessionTimerChanges}\n` +
      `字符串批次=${report.stringBatches}；累计分配=${report.stringsAllocated}；当前保留字符=${report.retainedStringChars}；压力暂停=${report.stringPressurePaused}\n` +
      `Crash 配置=${report.crashTrackingConfigured}；上传地址=${report.uploadEndpointConfigured}；autoSync=${report.autoSync}\n` +
      `Native 崩溃：尚未确认，需要匹配系统 FaultLog\n${report.lastError}\n${report.journalPath}`;
  }

  private async start(): Promise<void> {
    if (this.manager.isBusy()) return;
    this.operationError = '';
    try {
      const config = new IntegratedReproConfig();
      config.group = this.group;
      config.durationSeconds = Number(this.minutes) * 60;
      config.acceleratedExpiry = this.accelerated;
      config.reconfigureRum = this.reconfigure;
      config.timerFocused = this.timerFocused;
      config.stringPressure = this.stringPressure;
      config.requestUrl = this.requestUrl.trim();
      await this.manager.start(this.context, config);
      await router.pushUrl({ url: 'pages/RUMIntegratedWorkAPage' });
    } catch (error) { this.operationError = `未启动/启动失败：${String(error)}`; }
    this.refresh();
  }

  private localSetup(): void {
    AlertDialog.show({
      title: '启用本地完整 SDK/RUM',
      message: '仅在未配置 RUM 时可用。使用测试 appId、真实 RDB、真实 Crash 采集，不做任何故障注入。禁止上传，结束后也保持离线，重启 Demo 恢复正常配置。不清除数据库。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '启用本地完整链路', action: (): void => {
        try { this.manager.prepareLocal(this.context); this.status = '本地完整链路已启用'; }
        catch (error) { this.operationError = String(error); }
        this.refresh();
      } }
    });
  }

  build() {
    Column() {
      TestPageHeader({ title: '完整集成崩溃复现场景' })
      Scroll() {
        Column({ space: 12 }) {
          Text('当前版本 · 正常 SDK / 真实页面 / 真实 RDB / 实际系统前后台')
            .fontSize(17).fontWeight(FontWeight.Bold).width('100%')
          Text('这是尝试复现，不保证闪退。不会注入空指针、abort 或 JS 异常。没有系统证据时，不把状态异常或进程退出当作原始 Native 崩溃。')
            .fontSize(13).fontColor('#B45309')
          Text(this.issue.length === 0 ? '集成检查通过：可进行真实 RDB 预检' : this.issue)
            .id('rum-integrated-readiness').fontSize(13).fontColor(this.issue.length === 0 ? '#15803D' : '#B45309')
          if (FTSDK.getRumConfig() === null) {
            Button('本地完整初始化（不上传）').id('rum-integrated-local-setup')
              .enabled(!this.busy).onClick(() => { this.localSetup(); })
          }
          Row({ space: 12 }) {
            Button('A 当前基线').onClick(() => { this.group = 'A'; }).enabled(!this.busy)
              .backgroundColor(this.group === 'A' ? '#2563EB' : '#64748B')
            Button('B 修复后').onClick(() => { this.group = 'B'; }).enabled(!this.busy)
              .backgroundColor(this.group === 'B' ? '#2563EB' : '#64748B')
          }
          Row({ space: 8 }) {
            Text('时长（分钟）').fontSize(14)
            TextInput({ text: this.minutes }).id('rum-integrated-minutes').type(InputType.Number)
              .layoutWeight(1).enabled(!this.busy).onChange((value: string) => { this.minutes = value; })
            Button('长稳5小时').id('rum-integrated-natural').enabled(!this.busy).onClick(() => {
              this.minutes = '300'; this.accelerated = false; this.reconfigure = false; this.timerFocused = false; this.stringPressure = false;
            })
          }
          Row({ space: 8 }) {
            Button('定时器观察3分钟').id('rum-integrated-timer-profile').enabled(!this.busy).onClick(() => {
              this.minutes = '3'; this.accelerated = true; this.reconfigure = false; this.timerFocused = true; this.stringPressure = false;
            })
            Button('观察+字符串压力').id('rum-integrated-string-profile').enabled(!this.busy).onClick(() => {
              this.minutes = '3'; this.accelerated = true; this.reconfigure = false; this.timerFocused = true; this.stringPressure = true;
            })
          }
          Row({ space: 10 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.accelerated }).id('rum-integrated-expiry')
              .enabled(!this.busy && !this.timerFocused).onChange((value: boolean) => { this.accelerated = value; })
            Text('加速档：每分钟标记 Session 过期').fontSize(14)
          }.width('100%')
          Row({ space: 10 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.reconfigure }).id('rum-integrated-reconfigure')
              .enabled(!this.busy && !this.timerFocused).onChange((value: boolean) => { this.reconfigure = value; })
            Text('增强档：每分钟公开 API 重新配置 RUM').fontSize(14)
          }.width('100%')
          Row({ space: 10 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.timerFocused }).id('rum-integrated-timer-focused')
              .enabled(!this.busy).onChange((value: boolean) => {
                this.timerFocused = value;
                if (value) { this.accelerated = true; this.reconfigure = false; }
              })
            Text('定时器观察：10s 流量 + 70s 等待').fontSize(14)
          }.width('100%')
          Row({ space: 10 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.stringPressure }).id('rum-integrated-string-pressure')
              .enabled(!this.busy).onChange((value: boolean) => { this.stringPressure = value; })
            Text('有界字符串/JSON 压力（非 OOM）').fontSize(14)
          }.width('100%')
          Text('观察档暂停本工具的页面替换、Action/Log 和新 GET，标记过期后等待原始定时器。SDK 自身其他任务仍正常运行；窗口内更新不能单独证明来自 timer。字符串最多保留4批×128条，前台分配，堆达128MiB即暂停。')
            .fontSize(12).fontColor('#475569')
          Text('自然档不改 Session 时间。加速档也不改变 SDK 的 60s 定时器；刷新可能由定时器或公开采集入口触发，不能仅凭 Session 变化认定复现。')
            .fontSize(12).fontColor('#475569')
          TextInput({ text: this.requestUrl, placeholder: '可选：你控制的真实 GET 测试地址，留空不请求' })
            .id('rum-integrated-http-url').enabled(!this.busy).onChange((value: string) => { this.requestUrl = value; })
          Button('开始完整集成复现').id('rum-integrated-start').width('100%')
            .enabled(!this.busy && this.issue.length === 0).onClick(() => { void this.start(); })
          if (this.busy) {
            Button('返回运行中的压力页面').onClick(() => { router.pushUrl({ url: 'pages/RUMIntegratedWorkAPage' }); })
            Button('停止本轮（不销毁 SDK）').onClick(() => { void this.manager.stop().then((): void => { this.refresh(); }); })
          }
          Text(this.status).id('rum-integrated-status').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
          if (this.operationError.length > 0) {
            Text(this.operationError).id('rum-integrated-operation-error').fontSize(13).fontColor('#B91C1C').width('100%')
          }
          Text(this.evidence).id('rum-integrated-evidence').fontSize(12).width('100%').copyOption(CopyOptions.LocalDevice)
          Text(this.previousRun).fontSize(12).width('100%')
          Text('启动后每 750ms 真正替换 A/B 页面，持续生成 Action/Log 和有界字符串分配。按 Home 进入真实后台，稍后从桌面返回；不要划掉进程。应用文件与 HiLog 标签 RUMIntegratedRepro 持续保存检查点。')
            .fontSize(13).fontColor('#475569')
        }.padding(16).width('100%')
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%')
  }
}
