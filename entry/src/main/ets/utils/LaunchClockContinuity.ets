import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import process from '@ohos.process';
import { FTAppLaunchTracker } from '@guancecloud/ft_sdk/src/main/ets/components/monitor/FTAppLaunchTracker';

export class ContinuitySample {
  startupNs: number = 0;
  activeNs: number = 0;
  wallMs: number = 0;
  pid: number = process.pid;
}

class ContinuityEvent {
  name: string = '';
  sample: ContinuitySample = new ContinuitySample();
}

export class ContinuityReport {
  schemaVersion: number = 1;
  runId: string = `continuity-${Date.now()}-${process.pid}`;
  pid: number = process.pid;
  phase: string = 'ARMED';
  conclusion: string = 'WAIT_LEAVE';
  detail: string = '请切换到其他应用或锁屏，等待约 30 秒，再从最近任务返回；恢复后自动判断。';
  clockSource: string = 'FTAppLaunchTracker.getStartupUptimeNs() / STARTUP nanoseconds';
  freezeEvidence: string = 'NOT_VERIFIED';
  armed: ContinuitySample = new ContinuitySample();
  leave: ContinuitySample | null = null;
  resume: ContinuitySample | null = null;
  events: ContinuityEvent[] = [];
  startupDeltaMs: number = 0;
  activeDeltaMs: number = 0;
  wallDeltaMs: number = 0;
  missingMs: number = 0;
  toleranceMs: number = 0;
  reportPath: string = '';
  error: string = '';
}

/** Lifecycle-driven observation only: no timer/keepalive, no SDK state reset or clock replacement. */
export class LaunchClockContinuity {
  private static context: common.UIAbilityContext | null = null;
  private static report: ContinuityReport | null = null;
  private static listeners: Array<() => void> = [];
  private static nextRun: number = 0;

  static initialize(context: common.UIAbilityContext): void { LaunchClockContinuity.context = context; }
  static current(): ContinuityReport | null { return LaunchClockContinuity.report; }
  static isRunning(): boolean {
    const phase = LaunchClockContinuity.report?.phase;
    return phase === 'ARMED' || phase === 'AWAY';
  }

  static subscribe(listener: () => void): () => void {
    LaunchClockContinuity.listeners.push(listener);
    return (): void => {
      const index = LaunchClockContinuity.listeners.indexOf(listener);
      if (index >= 0) LaunchClockContinuity.listeners.splice(index, 1);
    };
  }

  private static read(): ContinuitySample {
    const sample = new ContinuitySample();
    // Call the production getter itself, not a second implementation of the SDK clock.
    sample.startupNs = FTAppLaunchTracker.getStartupUptimeNs();
    sample.activeNs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
    sample.wallMs = Date.now();
    return sample;
  }

  static start(): void {
    if (LaunchClockContinuity.isRunning()) throw new Error('时钟观察尚未结束');
    const report = new ContinuityReport();
    report.runId += `-${++LaunchClockContinuity.nextRun}`;
    report.armed = LaunchClockContinuity.read();
    LaunchClockContinuity.report = report;
    if (!Number.isFinite(report.armed.startupNs) || report.armed.startupNs <= 0) {
      report.phase = 'FINISHED'; report.conclusion = 'INVALID_CLOCK'; report.detail = '无法读取 SDK 统一时钟，请重新测试。';
    }
    LaunchClockContinuity.publish();
  }

  static cancel(): void {
    if (!LaunchClockContinuity.isRunning()) return;
    const report = LaunchClockContinuity.report!;
    report.phase = 'FINISHED'; report.conclusion = 'CANCELLED'; report.detail = '本轮已取消，没有生成时钟连续性结论。';
    LaunchClockContinuity.publish();
  }

  static lifecycle(name: string): void {
    if (!LaunchClockContinuity.isRunning()) return;
    const report = LaunchClockContinuity.report!;
    const leaving = name === 'INACTIVE' || name === 'PAUSED' || name === 'HIDDEN' || name === 'BACKGROUND';
    const returning = name === 'ACTIVE' || name === 'RESUMED' || name === 'SHOWN' || name === 'FOREGROUND';
    if (!leaving && !returning) return;
    let sample: ContinuitySample;
    try { sample = LaunchClockContinuity.read(); }
    catch (error) {
      report.phase = 'FINISHED'; report.conclusion = 'INVALID_CLOCK'; report.detail = `采样失败：${String(error)}`;
      LaunchClockContinuity.publish(); return;
    }
    const event = new ContinuityEvent(); event.name = name; event.sample = sample;
    if (report.events.length < 64) report.events.push(event);
    if (sample.pid !== report.pid) {
      report.phase = 'FINISHED'; report.conclusion = 'PROCESS_CHANGED';
      report.detail = '进程已变化，不能跨进程比较；请重新开始。';
    } else if (leaving && report.leave === null) {
      // Keep the earliest actual loss of focus/background boundary. Do not
      // move it forward when HIDDEN/BACKGROUND arrives after INACTIVE.
      report.leave = sample; report.phase = 'AWAY'; report.conclusion = 'WAIT_RETURN';
      report.detail = '已记录失活/退后台时间，返回后自动比较；当前事件不能证明系统已冻结进程。';
    } else if (returning && report.leave !== null) {
      report.resume = sample; report.phase = 'FINISHED';
      LaunchClockContinuity.evaluate(report);
    }
    LaunchClockContinuity.publish();
  }

  private static evaluate(report: ContinuityReport): void {
    const start = report.leave!; const end = report.resume!;
    report.startupDeltaMs = (end.startupNs - start.startupNs) / 1_000_000;
    report.activeDeltaMs = (end.activeNs - start.activeNs) / 1_000_000;
    report.wallDeltaMs = end.wallMs - start.wallMs;
    report.missingMs = report.wallDeltaMs - report.startupDeltaMs;
    report.toleranceMs = Math.max(500, report.wallDeltaMs * 0.05);
    if (![start.startupNs, end.startupNs, start.activeNs, end.activeNs, start.wallMs, end.wallMs].every(
      (value: number) => Number.isFinite(value) && value > 0) || report.startupDeltaMs < 0 || report.activeDeltaMs < 0 ||
      report.wallDeltaMs <= 0) {
      report.conclusion = 'INVALID_CLOCK'; report.detail = '时钟采样异常或参考时间回退，本轮无法判断。';
    } else if (report.wallDeltaMs < 5000) {
      report.conclusion = 'SHORT_INTERVAL'; report.detail = '失活/后台区间不足 5 秒，请重新开始并等待约 30 秒。';
    } else if (report.startupDeltaMs === 0) {
      report.conclusion = 'UNCHANGED'; report.detail = 'SDK 统一时钟前后读数未变化；请结合参考时间与系统记录复核。';
    } else if (Math.abs(report.missingMs) <= report.toleranceMs) {
      report.conclusion = 'CONTINUED'; report.detail = 'SDK 统一时钟继续累计：失活/后台期间的耗时已计入。';
    } else if (report.missingMs > report.toleranceMs) {
      report.conclusion = 'LESS_ELAPSED';
      report.detail = '统一时钟少计了参考区间，疑似暂停或参考时间被调整；不能仅凭本轮确定原因。';
    } else {
      report.conclusion = 'REFERENCE_MISMATCH'; report.detail = '统一时钟与参考时间不一致，请排除系统校时后重测。';
    }
  }

  static summary(): string {
    const report = LaunchClockContinuity.report;
    if (report === null) return '尚未开始。点击按钮后离开前台，返回后自动显示结果。';
    let text = `${report.detail}\n状态：${report.conclusion}\nPID：${report.pid}\n轮次：${report.runId}\n`;
    if (report.leave !== null) text += `离开时 STARTUP：${report.leave.startupNs} ns\n`;
    if (report.resume !== null) {
      text += `恢复时 STARTUP：${report.resume.startupNs} ns\n` +
        `统一时钟增量：${(report.startupDeltaMs / 1000).toFixed(3)} 秒\n` +
        `参考时间间隔：${(report.wallDeltaMs / 1000).toFixed(3)} 秒\n` +
        `ACTIVE 增量：${(report.activeDeltaMs / 1000).toFixed(3)} 秒\n` +
        `少计区间：${(report.missingMs / 1000).toFixed(3)} 秒\n`;
    }
    text += `事件：${report.events.map((event: ContinuityEvent) => event.name).join(' → ')}\n` +
      '系统真正挂起/冻结：未证实；参考时间可能受系统校时影响。\n';
    if (report.reportPath.length > 0) text += `报告：${report.reportPath}\n`;
    return text + report.error;
  }

  private static publish(): void {
    const report = LaunchClockContinuity.report;
    if (report === null) return;
    try {
      if (LaunchClockContinuity.context === null) throw new Error('Test Context unavailable');
      report.reportPath = `${LaunchClockContinuity.context.filesDir}/launch-clock-${report.runId}.json`;
      const file = fileIo.openSync(report.reportPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, JSON.stringify(report, null, 2)); } finally { fileIo.closeSync(file); }
    } catch (error) { report.error = `保存失败：${String(error)}`; }
    hilog.info(0xFF00, 'LaunchSuspendTest', 'CLOCK_CONTINUITY %{public}s', JSON.stringify({
      runId: report.runId, pid: report.pid, phase: report.phase, conclusion: report.conclusion,
      startupDeltaMs: report.startupDeltaMs, wallDeltaMs: report.wallDeltaMs, freezeEvidence: report.freezeEvidence
    }));
    for (const listener of LaunchClockContinuity.listeners.slice()) listener();
  }
}
