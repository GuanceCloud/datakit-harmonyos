import { common } from '@kit.AbilityKit';
import process from '@ohos.process';
import { LifecycleCaseResult, LifecycleDeviceReport, RUMSessionLifecycleVerifier } from '../utils/RUMSessionLifecycleVerifier';

@Entry
@Component
struct RUMSessionLifecycleTestPage {
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  @State running: boolean = false;
  @State group: string = 'A';
  @State message: string = '就绪：请保持本页在前台，单轮约 4 分钟';
  @State summary: string = '尚未运行';
  @State results: LifecycleCaseResult[] = [];
  @State reportPath: string = '';
  @State reportCompleted: boolean = false;

  private async start(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.results = [];
    this.reportPath = '';
    this.reportCompleted = false;
    this.summary = 'RUNNING';
    try {
      const verifier = new RUMSessionLifecycleVerifier((message: string, results: LifecycleCaseResult[]): void => {
        this.message = message;
        this.results = results;
      });
      const report: LifecycleDeviceReport = await verifier.run(this.context, this.group,
        AppStorage.get<number>('rumLifecycleParentPid') ?? 0);
      this.results = report.results;
      this.reportPath = report.reportPath;
      this.reportCompleted = report.completed;
      const passed = report.results.filter((item: LifecycleCaseResult): boolean => item.status === 'PASS').length;
      const failed = report.results.filter((item: LifecycleCaseResult): boolean => item.status === 'FAIL').length;
      const errors = report.results.filter((item: LifecycleCaseResult): boolean => item.status === 'ERROR').length;
      this.summary = `${report.completed ? 'COMPLETED' : 'INCOMPLETE'} ${report.group}: PASS=${passed} FAIL=${failed} ERROR=${errors}`;
      this.message = report.completed ? '本轮结束；FAIL 表示发现生命周期缺陷，不是 Native 崩溃' : '环境或执行异常，本轮不能作为完整 A/B 结果';
    } catch (error) {
      this.summary = 'ERROR / INVALID RUN';
      this.message = String(error);
    } finally {
      this.running = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('RUM Session 生命周期 A/B')
        .fontSize(21).fontWeight(FontWeight.Bold)
      Text(`专用冷启动测试进程 PID=${process.pid}`)
        .fontSize(12).fontColor('#475569')
      Text('统一判据：A/B 只标记组别，不改变测试逻辑。真实 60s 定时器；仅控制过期时间和 Promise 等待屏障。')
        .fontSize(13)
      Text('不接入网络/RDB，不覆盖 View 持久化或公共 FTSDK.shutDown 全链路；不等同于 GetStringFromCache 闪退复现。')
        .fontSize(12).fontColor('#B45309')
      Row({ space: 12 }) {
        Button('A 未修复基线').onClick(() => { this.group = 'A'; }).enabled(!this.running)
          .backgroundColor(this.group === 'A' ? '#2563EB' : '#64748B')
        Button('B 修复后验证').onClick(() => { this.group = 'B'; }).enabled(!this.running)
          .backgroundColor(this.group === 'B' ? '#2563EB' : '#64748B')
      }
      Button(this.running ? '运行中，请勿离开本页' : '运行统一验证（约4分钟）')
        .id('rum-lifecycle-run').width('100%').enabled(!this.running)
        .onClick(() => { void this.start(); })
      Text(this.summary).id('rum-lifecycle-summary')
        .fontSize(14).fontWeight(FontWeight.Bold).width('100%')
      Text(this.message).id('rum-lifecycle-progress').fontSize(13).width('100%')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.results, (result: LifecycleCaseResult) => {
            Column({ space: 4 }) {
              Text(`${result.status} · ${result.name}`).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(result.status === 'PASS' ? '#15803D' : result.status === 'FAIL' ? '#DC2626' : '#475569')
                .width('100%')
              Text(result.detail).fontSize(11).width('100%').copyOption(CopyOptions.LocalDevice)
            }.padding(10).width('100%').backgroundColor('#F1F5F9').borderRadius(6)
          }, (result: LifecycleCaseResult): string => `${result.id}:${result.status}:${result.elapsedMs}`)
          if (this.reportPath.length > 0) {
            Text(`JSON 报告：${this.reportPath}`).fontSize(11).width('100%').copyOption(CopyOptions.LocalDevice)
            if (this.reportCompleted) {
              Text('完整完成本轮，未观察到 Native 崩溃；发生 Native 崩溃需另取系统 FaultLog，不能用 FAIL 数代替。')
                .fontSize(12).fontColor('#475569')
            }
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      Button('重启回 Demo').enabled(!this.running)
        .onClick(() => {
          this.context.restartApp({
            bundleName: this.context.abilityInfo.bundleName,
            moduleName: 'entry',
            abilityName: 'EntryAbility'
          }).catch((error: Error): void => { this.message = String(error); });
        })
    }.padding({ left: 16, right: 16, top: 40, bottom: 24 }).width('100%').height('100%')
  }
}
