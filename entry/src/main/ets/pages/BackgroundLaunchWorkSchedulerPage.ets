import { Context } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import {
  BACKGROUND_LAUNCH_WORK_ABILITY,
  BACKGROUND_LAUNCH_WORK_ID,
  BackgroundLaunchWorkStatus,
  markBackgroundLaunchExitRequested,
  markBackgroundLaunchWorkScheduleError,
  readBackgroundLaunchWorkStatus,
  resetBackgroundLaunchWorkStatus
} from '../utils/BackgroundLaunchWorkStatusStore';
import { DemoLogger } from '../utils/DemoLogger';
import { getDemoColdLaunchConfigurationIssue } from '../utils/DemoColdLaunchRumInitializer';

const TAG = 'BackgroundLaunchWorkSchedulerPage';
const DEFAULT_DELAY_SECONDS = 15;
const MAX_DELAY_SECONDS = 3600;

@Entry
@Component
struct BackgroundLaunchWorkSchedulerPage {
  private context: Context = getContext(this) as Context;
  @State delaySeconds: string = String(DEFAULT_DELAY_SECONDS);
  @State phase: string = 'not_scheduled';
  @State resultText: string = '尚未登记任务';
  @State passText: string = '等待验证';
  @State scheduling: boolean = false;

  aboutToAppear(): void {
    void this.refreshResult();
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        TestPageHeader({ title: 'WorkScheduler 后台启动诊断' })

        this.buildFlowCard();
        this.buildSchedulerCard();
        this.buildResultCard();
        this.buildNotesCard();
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }

  @Builder
  private buildFlowCard() {
    Column({ space: 7 }) {
      Text('验证链路')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
      Text('登记任务 → 结束当前进程 → 系统拉起独立扩展进程 → 初始化 SDK/RUM → 检查后台启动分类')
        .fontSize(13)
        .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
        .lineHeight(20)
      Text('本页不能验证同进程“后台运行 5 分钟后创建 UI”。后台分类不等于冷启动已上报；必须由同一进程的真实首帧结束计时。')
        .fontSize(13)
        .fontColor('#B45309')
        .lineHeight(20)
      Text(`当前 UI 进程 PID：${process.pid}`)
        .fontSize(13)
        .fontColor('#2563EB')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  private buildSchedulerCard() {
    Column({ space: 10 }) {
      Text('首次执行最早延迟（秒）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
      TextInput({ text: this.delaySeconds, placeholder: String(DEFAULT_DELAY_SECONDS) })
        .width('100%')
        .height(44)
        .type(InputType.Number)
        .backgroundColor('#F8FAFC')
        .borderRadius(8)
        .onChange((value: string) => {
          this.delaySeconds = value;
        })

      Text('触发条件：任意网络连接 + 最早延迟；USB 可一直连接，不要求充电或断电。')
        .fontSize(13)
        .fontColor(Color.Gray)
        .lineHeight(20)

      Button('登记并结束当前进程')
        .width('100%')
        .height(46)
        .backgroundColor('#2563EB')
        .enabled(!this.scheduling)
        .onClick(() => {
          void this.scheduleWork(true);
        })

      Button('仅登记任务（手动结束进程）')
        .width('100%')
        .height(44)
        .backgroundColor('#475569')
        .enabled(!this.scheduling)
        .onClick(() => {
          void this.scheduleWork(false);
        })

      Row({ space: 10 }) {
        Button('刷新结果')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#0F766E')
          .onClick(() => {
            void this.refreshResult();
          })
        Button('取消任务')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#B91C1C')
          .enabled(!this.scheduling)
          .onClick(() => {
            this.cancelWork();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  private buildResultCard() {
    Column({ space: 8 }) {
      Text(`状态：${this.phase}`)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
      Text(this.passText)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.passText.startsWith('PASS') ? '#15803D' : '#B45309')
      Text(this.resultText)
        .fontSize(13)
        .fontColor(TestPageTheme.RESULT_TEXT_COLOR)
        .lineHeight(20)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(TestPageTheme.RESULT_CARD_BACKGROUND)
    .borderRadius(10)
  }

  @Builder
  private buildNotesCard() {
    Column({ space: 7 }) {
      Text('操作说明')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
      Text('1. 先在启动参数中配置并持久化 appId 和上传地址；使用 Dataway 时还需 clientToken。')
        .fontSize(13)
        .fontColor(Color.Gray)
      Text('2. 保持 USB 调试连接，先关闭手机 Wi-Fi 和移动数据，再点击“登记并结束当前进程”。登记确认后约 1 秒退出；组合操作的延迟需至少 5 秒。')
        .fontSize(13)
        .fontColor(Color.Gray)
      Text('3. 进程退出后等待设置的最早延迟，再从系统控制中心恢复 Wi-Fi 或移动数据，不要打开 App。联网只是满足条件，实际执行时间仍由系统调度决定。')
        .fontSize(13)
        .fontColor(Color.Gray)
      Text('4. 不限定应用或 PID 查看 HiLog：WORK_STARTED → BACKGROUND_LAUNCH_CLASSIFIED。系统调试触发方法见 README，无需拔插 USB。')
        .fontSize(13)
        .fontColor(Color.Gray)
      Text('5. 纯后台无首帧时不生成 launch_cold。手动打开 App 通常属于另一个 UI 进程，不能用它的首帧补齐 WorkScheduler 的冷启动，也不能把两个进程的耗时合并。')
        .fontSize(13)
        .fontColor(Color.Gray)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  private createWorkInfo(delayMs: number): workScheduler.WorkInfo {
    return {
      workId: BACKGROUND_LAUNCH_WORK_ID,
      bundleName: this.context.applicationInfo.name,
      abilityName: BACKGROUND_LAUNCH_WORK_ABILITY,
      // Leave charging fields unset so USB debugging does not affect eligibility.
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      earliestStartTime: delayMs,
      isRepeat: false,
      isPersisted: true,
      parameters: {
        scenario: 'ft_sdk_background_cold_launch'
      }
    };
  }

  private async scheduleWork(exitAfterRegistration: boolean): Promise<void> {
    if (this.scheduling) {
      return;
    }
    const seconds = Number(this.delaySeconds);
    if (!Number.isFinite(seconds) || seconds < 0 || seconds > MAX_DELAY_SECONDS) {
      promptAction.showToast({ message: `延迟需为 0-${MAX_DELAY_SECONDS} 秒` });
      return;
    }
    const delayMs = Math.floor(seconds * 1000);
    if (exitAfterRegistration && delayMs < 5000) {
      promptAction.showToast({ message: '登记并退出时，请将最早延迟设为至少 5 秒' });
      return;
    }
    this.scheduling = true;
    let exitScheduled = false;
    const workInfo = this.createWorkInfo(delayMs);
    try {
      const issue = await getDemoColdLaunchConfigurationIssue(this.context);
      if (issue.length > 0) {
        this.passText = '请先完成后台上报配置';
        this.resultText = issue;
        promptAction.showToast({ message: issue });
        return;
      }
      try {
        workScheduler.stopWork(workInfo, true);
      } catch (_error) {
        // No previous work with this fixed demo ID is a normal first run.
      }
      await resetBackgroundLaunchWorkStatus(this.context, delayMs, process.pid);
      workScheduler.startWork(workInfo);
      const registered = await workScheduler.getWorkStatus(BACKGROUND_LAUNCH_WORK_ID);
      this.phase = 'scheduled';
      this.passText = '等待网络条件与系统调度';
      this.resultText = `任务已登记：workId=${registered.workId}, 触发条件=任意网络连接, earliestStartTime=${registered.earliestStartTime ?? delayMs}ms, 登记 PID=${process.pid}。保持 USB 连接，等待系统后台拉起后查看日志。`;
      DemoLogger.i(TAG, `WORK_REGISTERED: workId=${registered.workId}, pid=${process.pid}, networkType=${registered.networkType}, earliestStartTime=${delayMs}ms`);
      if (exitAfterRegistration) {
        await markBackgroundLaunchExitRequested(this.context);
        promptAction.showToast({ message: '任务已登记，1 秒后结束当前进程，请等待后台启动日志' });
        setTimeout((): void => {
          try {
            DemoLogger.i(TAG, `PROCESS_EXIT_REQUESTED: pid=${process.pid}, workId=${registered.workId}`);
            new process.ProcessManager().exit(0);
          } catch (error) {
            this.scheduling = false;
            this.resultText = `退出进程失败：${String(error)}`;
            DemoLogger.e(TAG, this.resultText);
          }
        }, 1000);
        exitScheduled = true;
      } else {
        promptAction.showToast({ message: '任务已登记，可手动结束当前进程并等待系统调度' });
      }
    } catch (error) {
      const businessError = error as BusinessError;
      const message = `登记失败：code=${businessError.code}, message=${businessError.message}`;
      await markBackgroundLaunchWorkScheduleError(this.context, message).catch((storeError: Error): void => {
        DemoLogger.e(TAG, `Failed to persist schedule error: ${String(storeError)}`);
      });
      this.phase = 'schedule_error';
      this.passText = 'FAIL：任务未登记';
      this.resultText = message;
      DemoLogger.e(TAG, message);
    } finally {
      if (!exitScheduled) {
        this.scheduling = false;
      }
    }
  }

  private cancelWork(): void {
    try {
      workScheduler.stopWork(this.createWorkInfo(0), true);
      this.phase = 'cancelled';
      this.passText = '任务已取消';
      this.resultText = `已停止并移除 workId=${BACKGROUND_LAUNCH_WORK_ID}`;
      promptAction.showToast({ message: '后台任务已取消' });
    } catch (error) {
      const businessError = error as BusinessError;
      this.resultText = `取消失败：code=${businessError.code}, message=${businessError.message}`;
      DemoLogger.e(TAG, this.resultText);
    }
  }

  private async refreshResult(): Promise<void> {
    try {
      const status = await readBackgroundLaunchWorkStatus(this.context);
      this.applyStatus(status);
    } catch (error) {
      this.phase = 'read_error';
      this.passText = 'FAIL：无法读取验证结果';
      this.resultText = String(error);
    }
  }

  private applyStatus(status: BackgroundLaunchWorkStatus): void {
    this.phase = status.phase;
    const separateProcess = status.scheduledPid > 0 && status.workPid > 0 &&
      status.workPid !== status.scheduledPid;
    const classified = separateProcess && status.rumReady && status.noUiCreated &&
      status.appLaunchType === 'background';
    this.passText = classified
      ? '后台拉起/分类已确认；本页未验证同进程首帧'
      : '等待后台拉起与分类';
    this.resultText = [
      `workId=${status.workId}`,
      `UI PID=${process.pid}`,
      `登记 PID=${status.scheduledPid || 'pending'}`,
      `Work PID=${status.workPid || 'pending'}`,
      `独立进程=${separateProcess}`,
      `RUM ready=${status.rumReady}`,
      `分类时无 UI=${status.noUiCreated}`,
      `app_launch_type=${status.appLaunchType}`,
      `launch_cold 已提交 RUM=${status.launchReported}`,
      `onWorkStart=${this.formatTime(status.startedAtMs)}`,
      `分类时间=${this.formatTime(status.classifiedAtMs)}`,
      `提交时间=${this.formatTime(status.reportedAtMs)}`,
      status.message
    ].join('\n');
  }

  private formatTime(timestampMs: number): string {
    return timestampMs > 0 ? new Date(timestampMs).toLocaleString() : 'pending';
  }
}
