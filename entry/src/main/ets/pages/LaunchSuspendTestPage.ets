import { common } from '@kit.AbilityKit';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { LaunchSuspendProbe } from '../utils/LaunchSuspendProbe';
import { LaunchSuspendCaseResult } from '../utils/LaunchSuspendCases';
import { LaunchClockContinuity } from '../utils/LaunchClockContinuity';

@Entry
@Component
struct LaunchSuspendTestPage {
  @State results: LaunchSuspendCaseResult[] = [];
  @State summary: string = '';
  @State seconds: string = '30';
  @State message: string = '';
  @State continuitySummary: string = '';
  @State continuityRunning: boolean = false;
  private disposeContinuity: (() => void) | null = null;

  aboutToAppear(): void {
    this.disposeContinuity = LaunchClockContinuity.subscribe((): void => { this.refresh(); });
    this.refresh();
  }

  aboutToDisappear(): void {
    this.disposeContinuity?.();
    this.disposeContinuity = null;
  }

  onPageShow(): void { this.refresh(); }

  private refresh(): void {
    this.summary = LaunchSuspendProbe.summary();
    this.continuitySummary = LaunchClockContinuity.summary();
    this.continuityRunning = LaunchClockContinuity.isRunning();
  }

  private restart(beforeFrame: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.restartApp({ bundleName: context.abilityInfo.bundleName, moduleName: 'entry',
      abilityName: 'LaunchSuspendTestAbility', parameters: {
        launchSuspendBeforeFrame: beforeFrame, launchSuspendSeconds: Number(this.seconds)
      } }).catch((error: Error): void => { this.message = String(error); });
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        TestPageHeader({ title: '启动来源与挂起计时', backText: '返回 Demo', onBack: (): void => {
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          context.restartApp({ bundleName: context.abilityInfo.bundleName, moduleName: 'entry',
            abilityName: 'EntryAbility' }).catch((error: Error): void => { this.message = String(error); });
        } })
        Text('来源用例控制回调顺序，不代表真机冻结。计时用例读取真实系统时钟；没有冻结证据时不会显示 PASS。')
          .fontSize(14).fontColor('#92400E').width('100%')
        Button(this.continuityRunning ? '取消本轮时钟观察' : '验证冷启动统一时钟（失活/后台）')
          .id('launch-clock-continuity').width('100%').backgroundColor('#0F766E')
          .onClick(() => {
            try {
              if (LaunchClockContinuity.isRunning()) LaunchClockContinuity.cancel();
              else LaunchClockContinuity.start();
            } catch (error) { this.message = String(error); }
            this.refresh();
          })
        Text('点击后切换到其他应用或锁屏，约 30 秒后从最近任务返回。自动比较离开前后的 SDK STARTUP 时钟，无需手动结束。实际冻结仍需系统证据。')
          .fontSize(13).fontColor('#475569').width('100%')
        Text(this.continuitySummary).fontSize(13).copyOption(CopyOptions.InApp).width('100%')
        Button('运行来源竞态与阶段计时用例（13 项）')
          .id('launch-suspend-source-run').width('100%').onClick(() => {
            try { this.results = LaunchSuspendProbe.runLogic(); this.message = '结果与预期直接比较，当前缺陷保留 FAIL。'; }
            catch (error) { this.message = `ERROR：${String(error)}`; }
          })
        ForEach(this.results, (item: LaunchSuspendCaseResult) => {
          Column({ space: 5 }) {
            Text(`${item.id} ${item.status}：${item.name}`).fontWeight(FontWeight.Bold)
              .fontColor(item.status === 'PASS' ? '#047857' : '#B91C1C')
            Text(`预期：${item.expected}\n实际：${item.actual}`).fontSize(12)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor(Color.White).borderRadius(8)
        }, (item: LaunchSuspendCaseResult) => item.id)
        Text('真实时钟观察时长（秒）').width('100%').fontWeight(FontWeight.Bold)
        TextInput({ text: this.seconds }).type(InputType.Number).width('100%')
          .onChange((value: string) => { this.seconds = value; })
        Button('开始页面内计时').id('launch-suspend-clock-arm').width('100%').onClick(() => {
          try { LaunchSuspendProbe.arm(Number(this.seconds)); this.message = '可切后台、锁屏或运行外部受控暂停脚本。'; }
          catch (error) { this.message = String(error); }
          this.refresh();
        })
        Button('恢复后结束采样').id('launch-suspend-clock-finish').width('100%').onClick(() => {
          try { LaunchSuspendProbe.finish(); } catch (error) { this.message = String(error); }
          this.refresh();
        })
        Button('刷新报告').width('100%').onClick(() => { this.refresh(); })
        Button('重启：在真实首帧前等待').id('launch-suspend-before-frame').width('100%')
          .backgroundColor('#7C3AED').onClick(() => { this.restart(true); })
        Text('首帧前模式会重启并暂不加载页面。运行外部脚本后恢复页面；或从首页重新打开此测试入口退出等待。该模式不安装 RUM，不提交真实冷启动 Action。')
          .fontSize(13).fontColor('#475569').width('100%')
        Text(this.message).fontColor('#92400E').width('100%')
        Text(this.summary).fontSize(13).copyOption(CopyOptions.InApp).width('100%')
      }.width('100%').padding(16)
    }.width('100%').height('100%').backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
