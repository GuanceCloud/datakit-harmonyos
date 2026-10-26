import router from '@ohos.router';
import { RUMIntegratedReproManager } from '../utils/RUMIntegratedReproManager';

@Component
export struct RUMIntegratedWorkContent {
  variant: string = 'A';
  private manager: RUMIntegratedReproManager = RUMIntegratedReproManager.getInstance();
  private navigationTimer: number = -1;
  private displayTimer: number = -1;
  private returning: boolean = false;
  // Bounded, page-owned allocations. Dropped at destruction; never an unbounded/OOM crash injector.
  private strings: string[] = [];
  @State status: string = '运行中';
  @StorageLink('rumIntegratedForeground') @Watch('foregroundChanged') foreground: boolean = true;
  @StorageLink('rumIntegratedNavigating') @Watch('foregroundChanged') navigating: boolean = true;

  aboutToAppear(): void {
    this.manager.pageShown(this.variant);
    for (let index = 0; index < 32; index++) {
      this.strings.push(`${this.variant}-${Date.now()}-${index}-${'repro'.repeat(400)}`);
    }
    this.scheduleNavigation();
    this.displayTimer = setInterval((): void => {
      const report = this.manager.snapshot();
      const seconds = Math.max(0, Math.ceil((report.phaseUntil - Date.now()) / 1000));
      this.status = report.phase === 'TIMER_QUIET' ?
        `等待原始定时器（本窗口剩余 ${seconds}s）\n窗口内 Session 更新=${report.quietSessionChanges}；完整窗口=${report.quietWindowsCompleted}` :
        `页面流量阶段；创建=${report.pagesCreated}；Session 更新=${report.observedSessionChanges}`;
      if (report.status === 'INCOMPLETE_STOP') this.status = '收尾未完成，返回查看报告后重启 Demo';
      if (!this.manager.isBusy() && !this.returning) { this.returning = true; router.back(); }
    }, 1000);
  }

  private foregroundChanged(): void {
    clearTimeout(this.navigationTimer);
    if (this.foreground && this.navigating) this.scheduleNavigation();
  }

  private scheduleNavigation(): void {
    clearTimeout(this.navigationTimer);
    if (!this.foreground || !this.manager.canNavigate()) return;
    this.navigationTimer = setTimeout((): void => {
      if (!this.manager.isRunning()) {
        this.returning = true;
        router.back();
        return;
      }
      if (!this.manager.canNavigate()) return;
      const target = this.variant === 'A' ? 'pages/RUMIntegratedWorkBPage' : 'pages/RUMIntegratedWorkAPage';
      router.replaceUrl({ url: target }).catch((error: Error): void => { this.status = `导航失败：${error.message}`; });
    }, this.manager.navigationIntervalMs());
  }

  aboutToDisappear(): void {
    clearTimeout(this.navigationTimer);
    clearInterval(this.displayTimer);
    this.strings = [];
    this.manager.pageDestroyed();
  }

  build() {
    Column({ space: 18 }) {
      Text(`完整集成压力页面 ${this.variant}`).fontSize(25).fontWeight(FontWeight.Bold)
      Text(this.status).fontSize(16)
      Text('正常 SDK、真实 RDB、真实页面替换；没有故障注入。').fontSize(15)
      Text('现在可按 Home 切到后台，再从桌面返回。不要划掉进程；后台是否冻结由系统决定。').fontSize(15)
      Button('停止并查看报告').id('rum-integrated-work-stop').onClick(() => {
        this.returning = true;
        clearTimeout(this.navigationTimer);
        void this.manager.stop().then((): void => { router.back(); });
      })
      Button('返回控制页（继续运行）').onClick(() => { this.returning = true; clearTimeout(this.navigationTimer); router.back(); })
    }.padding(24).width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
