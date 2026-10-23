import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import process from '@ohos.process';
import { FTRUMConfig, FTRUMGlobalManager, FTSDK, FTSDKConfig } from '@guancecloud/ft_sdk/Index';
import { ApplicationHeapPressure, ApplicationHeapSnapshot, heapPressureDelay } from '../utils/ApplicationHeapPressure';

const TAG = 'ApplicationHeapPressure';

@Entry
@Component
struct ApplicationHeapPressurePage {
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pressure: ApplicationHeapPressure = new ApplicationHeapPressure();
  private runId: string = `app-heap-${Date.now()}-${process.pid}`;
  private timer: number = -1;
  private probeRunning: boolean = false;
  private lastJournalAt: number = 0;
  private lastJournalPhase: string = '';
  private sdkInitializedByTest: boolean = false;
  private active: boolean = false;
  @State target: string = '273';
  @State busy: boolean = false;
  @State hasPressure: boolean = false;
  @State sdkReady: boolean = false;
  @State allocatorUnused: boolean = true;
  @State probes: number = 0;
  @State status: string = '先保持 SDK 未初始化，填充主线程 JS 堆';
  @State metrics: string = '';

  aboutToAppear(): void {
    this.active = true;
    this.target = String(AppStorage.get<number>('heapPressureTargetMiB') ?? 273);
    this.refresh(true);
    this.timer = setInterval((): void => { this.refresh(); }, 1000);
    if (AppStorage.get<boolean>('heapPressureAutoRun') === true) {
      AppStorage.set('heapPressureAutoRun', false);
      void this.autoRun();
    }
  }

  aboutToDisappear(): void {
    this.active = false;
    clearInterval(this.timer);
    this.pressure.release();
  }

  private refresh(forceJournal: boolean = false): void {
    try {
      const sample: ApplicationHeapSnapshot = this.pressure.snapshot();
      this.busy = this.pressure.isBusy() || this.probeRunning;
      this.hasPressure = sample.retainedCells > 0;
      this.allocatorUnused = this.pressure.canFill();
      this.sdkReady = FTSDK.getRumConfig() !== null;
      this.metrics = `PID=${process.pid} · ${sample.phase}\n` +
        `heapUsed=${(sample.heapUsedKB / 1024).toFixed(2)} MiB；totalHeap=${(sample.totalHeapKB / 1024).toFixed(2)} MiB\n` +
        `VM 上限=${(sample.vmHeapLimitKB / 1024).toFixed(0)} MiB；目标=${sample.targetMiB} MiB\n` +
        `应用持有：${sample.retainedCells} 组对象/Map/闭包，${sample.retainedLocalClasses} 组局部类\n` +
        `SDK 已初始化=${FTSDK.getSDKConfig() !== null}；已完成 View=${this.probes}\n` +
        `${this.context.filesDir}/${this.runId}.jsonl`;
      if (forceJournal || sample.phase !== this.lastJournalPhase || Date.now() - this.lastJournalAt >= 5000) {
        this.lastJournalAt = Date.now();
        this.lastJournalPhase = sample.phase;
        const record = JSON.stringify({
          runId: this.runId, at: Date.now(), pid: process.pid, snapshot: sample,
          sdkInstalled: FTSDK.getSDKConfig() !== null, rumInstalled: this.sdkReady,
          sdkInitializedByTest: this.sdkInitializedByTest, completedViews: this.probes
        });
        const file = fileIo.openSync(`${this.context.filesDir}/${this.runId}.jsonl`,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
        try { fileIo.writeSync(file.fd, `${record}\n`); fileIo.fsyncSync(file.fd); }
        finally { fileIo.closeSync(file); }
        hilog.info(0xFF00, TAG, '%{public}s', record);
      }
    } catch (error) {
      this.status = `测量/检查点失败：${String(error)}`;
    }
  }

  private async fill(): Promise<void> {
    if (this.busy) return;
    if (FTSDK.getSDKConfig() !== null || FTSDK.getRumConfig() !== null) {
      this.status = 'SDK 已初始化，不能作为无采集预填充基线；请冷启动本测试入口';
      return;
    }
    this.status = '应用分批创建并持有 JS 对象；以实测 heapUsed 为准';
    try {
      await this.pressure.fill(Number(this.target), (): void => { this.refresh(); });
      const sample = this.pressure.snapshot();
      this.status = sample.phase === 'HOLDING' ?
        '预填充达标，SDK 仍未初始化；可保持观察或开启少量 RUM View' : '填充已停止';
    } catch (error) { this.status = String(error); }
    this.refresh(true);
  }

  private async autoRun(): Promise<void> {
    await heapPressureDelay(500);
    if (!this.active) return;
    await this.fill();
    if (this.active && this.pressure.snapshot().phase === 'HOLDING' &&
      AppStorage.get<boolean>('heapPressureProbe') === true) {
      await this.probeViews();
    }
    const oomMode = AppStorage.get<string>('heapPressureOOMMode') ?? '';
    if (this.active && this.pressure.snapshot().phase === 'HOLDING' && oomMode.length > 0) {
      await this.runOOM(oomMode);
    }
  }

  private async probeViews(): Promise<void> {
    if (this.busy || !this.hasPressure) return;
    this.probeRunning = true;
    this.refresh(true);
    try {
      if (FTSDK.getSDKConfig() === null) {
        FTSDK.install(FTSDKConfig.builder().setDebug(true).setAutoSync(false), this.context);
        FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('application-heap-pressure-local')
          .setSessionSamplingRate(100).setEnableTraceUserView(false).setEnableTraceUserAction(false)
          .setEnableTraceUserResource(false).setEnableTrackAppCrash(true)
          .setEnableTrackAppANR(false).setEnableTrackAppUIBlock(false).setDeviceMetricsMonitorType(0));
        this.sdkInitializedByTest = true;
      }
      if (!this.sdkInitializedByTest || FTSDK.getRumConfig() === null) {
        throw new Error('检测到非本测试安装的 SDK，不覆盖已有配置');
      }
      this.refresh(true);
      const rum = FTRUMGlobalManager.getInstance();
      for (let i = 0; i < 3 && this.active; i++) {
        await rum.startView(`ApplicationHeapProbe-${this.probes + 1}`);
        await heapPressureDelay(500);
        await rum.stopView();
        this.probes++;
        this.refresh(true);
        await heapPressureDelay(1000);
      }
      this.status = '已提交 3 次正常 View 生命周期，等待异步汇总；应用对象继续持有';
    } catch (error) { this.status = `View 探测失败：${String(error)}`; }
    finally { this.probeRunning = false; this.refresh(true); }
  }

  private async addClasses(): Promise<void> {
    if (this.busy) return;
    this.status = '应用额外创建局部类及实例，单次 1000 组；可能触及 VM 空间边界';
    try { await this.pressure.addLocalClasses((): void => { this.refresh(); }); }
    catch (error) { this.status = String(error); }
    this.refresh(true);
  }

  private async runOOM(mode: string): Promise<void> {
    if (this.busy || !this.hasPressure) return;
    this.status = mode === 'heap' ? '应用持续保留普通对象，目标为真实 VM OOM' :
      '应用持续保留局部类及实例，目标为真实 VM OOM';
    try {
      await this.pressure.runUntilOOM(mode, (): void => { this.refresh(); });
      this.status = this.pressure.snapshot().phase === 'NO_OOM_WITHIN_TIME_LIMIT' ?
        '180 秒内未触发 OOM；不能将本轮标记为 OOM 成功' : '压力已停止';
    } catch (error) { this.status = `压力分配返回异常：${String(error)}`; }
    this.refresh(true);
  }

  private restart(abilityName: string): void {
    this.pressure.release();
    this.context.restartApp({ bundleName: this.context.abilityInfo.bundleName, moduleName: 'entry', abilityName })
      .catch((error: Error): void => { this.status = String(error); });
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('应用对象堆压力 · 273 MiB').fontSize(22).fontWeight(FontWeight.Bold).width('100%')
        Text('由应用持有对象、Map 和闭包，预填充期间不初始化 SDK。目标是主线程 Ark heapUsed，不是 RSS、Native 内存或调用栈。')
          .fontSize(14).width('100%')
        Row({ space: 10 }) {
          Text('目标 MiB')
          TextInput({ text: this.target }).id('app-heap-target').type(InputType.Number)
            .layoutWeight(1).enabled(!this.busy && !this.sdkReady)
            .onChange((value: string): void => { this.target = value; })
        }
        Button('1. 应用预填充（SDK 未初始化）').id('app-heap-fill').width('100%')
          .enabled(!this.busy && !this.sdkReady && this.allocatorUnused).onClick((): void => { void this.fill(); })
        Button('2. 保持内存，触发 3 次 RUM View').id('app-heap-probe').width('100%')
          .enabled(!this.busy && this.hasPressure).onClick((): void => { void this.probeViews(); })
        Text('View 使用本地测试 appId、真实持久化，不配置上传地址，autoSync=false。预填充由应用代码完成，不能用本实验认定原始事故的责任方。')
          .fontSize(12).fontColor('#475569').width('100%')
        Button('可选：追加 1000 组应用局部类').id('app-heap-classes').width('100%')
          .enabled(!this.busy && this.hasPressure).backgroundColor('#B45309')
          .onClick((): void => { void this.addClasses(); })
        Text('273 MiB 只匹配总堆使用量，不保证 NonMovableSpace 达到 64 MiB，也不保证 OOM 或相同崩溃栈。追加类压力可能使测试应用退出，阶段检查点用于确认最后执行位置。')
          .fontSize(12).fontColor('#B45309').width('100%')
        Button('持续应用堆压力（目标 OOM）').id('app-heap-oom').width('100%')
          .enabled(!this.busy && this.hasPressure).backgroundColor('#B91C1C')
          .onClick((): void => { void this.runOOM('heap'); })
        Button('持续应用局部类压力（目标 OOM）').id('app-heap-class-oom').width('100%')
          .enabled(!this.busy && this.hasPressure).backgroundColor('#9F1239')
          .onClick((): void => { void this.runOOM('classes'); })
        Text('持续模式不在 273 MiB 停止：应用持有引用并继续分配，直到 VM 报错或 180 秒边界。可点释放停止；进程退出后须匹配系统 OutOfMemoryError 日志确认原因。')
          .fontSize(12).fontColor('#B91C1C').width('100%')
        Button('停止填充 / 释放应用持有对象').id('app-heap-release').width('100%')
          .enabled(!this.probeRunning).onClick((): void => {
            this.pressure.release(); this.status = '应用持有引用已释放，等待 GC；重试请冷启动新一轮'; this.refresh(true);
          })
        Text(this.status).id('app-heap-status').fontSize(15).width('100%')
        Text(this.metrics).id('app-heap-metrics').fontSize(12).width('100%').copyOption(CopyOptions.LocalDevice)
        Button('冷启动新一轮').enabled(!this.busy)
          .onClick((): void => { this.restart('HeapPressureTestAbility'); })
        Button('重启回 Demo').enabled(!this.busy)
          .onClick((): void => { this.restart('EntryAbility'); })
      }.padding({ left: 16, right: 16, top: 48, bottom: 24 }).width('100%')
    }.width('100%').height('100%')
  }
}
