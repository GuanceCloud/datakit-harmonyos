import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import process from '@ohos.process';
import hilog from '@ohos.hilog';
import {
  FTAppLaunchSnapshot,
  FTAppLaunchTracker
} from '@guancecloud/ft_sdk/src/main/ets/components/monitor/FTAppLaunchTracker';
import { LaunchSuspendCaseResult, runLaunchSuspendCases } from './LaunchSuspendCases';

const TAG = 'LaunchSuspendTest';

export class LaunchClockSample {
  startupNs: number = 0;
  activeNs: number = 0;
  pid: number = process.pid;
  tracker: FTAppLaunchSnapshot = FTAppLaunchTracker.getInstance().getSnapshot();
}

export class LaunchClockReport {
  schemaVersion: number = 1;
  runId: string = '';
  pid: number = process.pid;
  processToken: string = '';
  controllerId: string = '';
  status: string = 'ARMED';
  scope: string = 'Real STARTUP clock; freeze requires separate system/controller evidence; no RUM install';
  requestedSeconds: number = 30;
  beforeFirstFrame: boolean = false;
  start: LaunchClockSample = new LaunchClockSample();
  end: LaunchClockSample | null = null;
  firstFrame: LaunchClockSample | null = null;
  startupDeltaNs: number = 0;
  activeDeltaNs: number = 0;
  freezeEvidence: string = 'NOT_VERIFIED';
  reportPath: string = '';
  error: string = '';
}

class LaunchLogicReport {
  schemaVersion: number = 1;
  runId: string = '';
  pid: number = process.pid;
  scope: string = 'Controlled event order and fixed clock on production tracker instances; no real freeze';
  results: LaunchSuspendCaseResult[] = [];
  status: string = 'FAIL';
}

/** Demo-only recorder. It observes the real singleton but never changes its source, clock or RUM readiness. */
export class LaunchSuspendProbe {
  private static context: common.UIAbilityContext | null = null;
  private static processToken: string = `${process.pid}-${systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true)}`;
  private static report: LaunchClockReport | null = null;
  private static logic: LaunchLogicReport | null = null;
  private static ioError: string = '';

  static initialize(context: common.UIAbilityContext): void { LaunchSuspendProbe.context = context; }

  static read(): LaunchClockSample {
    const sample = new LaunchClockSample();
    sample.startupNs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
    sample.activeNs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true);
    if (!Number.isFinite(sample.startupNs) || sample.startupNs <= 0 ||
      !Number.isFinite(sample.activeNs) || sample.activeNs <= 0) throw new Error('Invalid uptime sample');
    return sample;
  }

  static arm(seconds: number, beforeFirstFrame: boolean = false): LaunchClockReport {
    if (LaunchSuspendProbe.report?.status === 'ARMED') throw new Error('已有等待采样的测试，请先结束本轮');
    if (!Number.isFinite(seconds) || seconds < 1 || seconds > 3600) throw new Error('时长应为 1–3600 秒');
    const report = new LaunchClockReport();
    report.runId = `clock-${Date.now()}-${process.pid}`;
    report.processToken = LaunchSuspendProbe.processToken;
    report.requestedSeconds = seconds;
    report.start = LaunchSuspendProbe.read();
    report.beforeFirstFrame = beforeFirstFrame;
    if (beforeFirstFrame && report.start.tracker.firstFrameUptimeNs > 0) {
      throw new Error('本进程已有首帧，必须重启后验证首帧前挂起');
    }
    LaunchSuspendProbe.report = report;
    LaunchSuspendProbe.save();
    LaunchSuspendProbe.emit('CLOCK_ARMED');
    return report;
  }

  /** A controller brackets this fresh sample with its own monotonic timestamps. */
  static checkpoint(runId: string, controllerId: string = ''): void {
    const report = LaunchSuspendProbe.requireArmed(runId);
    report.controllerId = controllerId;
    report.start = LaunchSuspendProbe.read();
    if (report.beforeFirstFrame && report.start.tracker.firstFrameUptimeNs > 0) {
      throw new Error('首帧已提前出现，本轮不再覆盖首帧前场景');
    }
    LaunchSuspendProbe.save();
    LaunchSuspendProbe.emit('CLOCK_CHECKPOINT');
  }

  static finish(runId: string = '', controllerId: string = ''): LaunchClockReport {
    const report = LaunchSuspendProbe.requireArmed(runId);
    if (runId.length > 0 && controllerId !== report.controllerId) throw new Error('Controller identity mismatch');
    report.end = LaunchSuspendProbe.read();
    report.startupDeltaNs = report.end.startupNs - report.start.startupNs;
    report.activeDeltaNs = report.end.activeNs - report.start.activeNs;
    if (report.end.pid !== report.start.pid || report.startupDeltaNs <= 0 || report.activeDeltaNs < 0) {
      report.status = 'FAIL_INVALID_CLOCK_OR_PROCESS';
    } else if (report.startupDeltaNs < report.requestedSeconds * 1_000_000_000) {
      report.status = 'INCOMPLETE_SHORT_INTERVAL';
    } else {
      // Growth alone cannot establish that the process was frozen.
      report.status = 'INCOMPLETE_FREEZE_EVIDENCE';
    }
    LaunchSuspendProbe.save();
    LaunchSuspendProbe.emit('CLOCK_FINISHED');
    return report;
  }

  static observeFirstFrame(): void {
    if (LaunchSuspendProbe.report === null) return;
    LaunchSuspendProbe.report.firstFrame = LaunchSuspendProbe.read();
    LaunchSuspendProbe.save();
    LaunchSuspendProbe.emit('FIRST_FRAME_OBSERVED');
  }

  static lifecycle(event: string): void {
    if (LaunchSuspendProbe.report !== null) LaunchSuspendProbe.emit(event);
  }

  static status(runId: string): void {
    if (LaunchSuspendProbe.report === null || LaunchSuspendProbe.report.runId !== runId) {
      throw new Error('当前进程没有对应测试轮次');
    }
    LaunchSuspendProbe.emit('CLOCK_STATUS');
  }

  static runLogic(): LaunchSuspendCaseResult[] {
    const report = new LaunchLogicReport();
    report.runId = `source-${Date.now()}-${process.pid}`;
    report.results = runLaunchSuspendCases();
    report.status = report.results.every((item: LaunchSuspendCaseResult) => item.status === 'PASS') ? 'PASS' : 'FAIL';
    LaunchSuspendProbe.logic = report;
    LaunchSuspendProbe.write(`launch-suspend-${report.runId}.json`, JSON.stringify(report, null, 2));
    for (const item of report.results) {
      hilog.info(0xFF00, TAG, 'SOURCE_CASE %{public}s', JSON.stringify(item));
    }
    return report.results;
  }

  static current(): LaunchClockReport | null { return LaunchSuspendProbe.report; }

  static summary(): string {
    const report = LaunchSuspendProbe.report;
    if (report === null) return `尚未开始。${LaunchSuspendProbe.ioError}`;
    return `状态：${report.status}\nPID：${report.pid}\n轮次：${report.runId}\n` +
      `STARTUP 增量：${report.startupDeltaNs / 1_000_000_000}s\n` +
      `ACTIVE 增量：${report.activeDeltaNs / 1_000_000_000}s\n` +
      `冻结证据：${report.freezeEvidence}\n报告：${report.reportPath}\n${report.error}`;
  }

  private static requireArmed(runId: string): LaunchClockReport {
    const report = LaunchSuspendProbe.report;
    if (report === null || report.status !== 'ARMED' || (runId.length > 0 && report.runId !== runId)) {
      throw new Error('测试未等待采样或轮次不匹配');
    }
    return report;
  }

  private static write(name: string, content: string): string {
    if (LaunchSuspendProbe.context === null) throw new Error('Test Context unavailable');
    const path = `${LaunchSuspendProbe.context.filesDir}/${name}`;
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, content); } finally { fileIo.closeSync(file); }
    return path;
  }

  private static save(): void {
    const report = LaunchSuspendProbe.report;
    if (report === null) return;
    try {
      if (LaunchSuspendProbe.context !== null) {
        report.reportPath = `${LaunchSuspendProbe.context.filesDir}/launch-suspend-${report.runId}.json`;
      }
      LaunchSuspendProbe.write(`launch-suspend-${report.runId}.json`, JSON.stringify(report, null, 2));
    } catch (error) {
      LaunchSuspendProbe.ioError = String(error);
      report.error = `保存报告失败：${String(error)}`;
    }
  }

  private static emit(event: string): void {
    const report = LaunchSuspendProbe.report;
    if (report === null) return;
    // Keep each packet small enough for HiLog; the full report is in filesDir.
    hilog.info(0xFF00, TAG, '%{public}s %{public}s', event, JSON.stringify({
      runId: report.runId, pid: report.pid, processToken: report.processToken, controllerId: report.controllerId,
      status: report.status,
      requestedSeconds: report.requestedSeconds, beforeFirstFrame: report.beforeFirstFrame,
      startStartupNs: report.start.startupNs, endStartupNs: report.end?.startupNs ?? 0,
      startupDeltaNs: report.startupDeltaNs, activeDeltaNs: report.activeDeltaNs,
      firstFrameUptimeNs: FTAppLaunchTracker.getInstance().getSnapshot().firstFrameUptimeNs,
      appStartUptimeNs: FTAppLaunchTracker.getInstance().getSnapshot().appStartUptimeNs,
      applicationInitUptimeNs: FTAppLaunchTracker.getInstance().getSnapshot().applicationInitUptimeNs,
      firstUIAbilityUptimeNs: FTAppLaunchTracker.getInstance().getSnapshot().firstUIAbilityUptimeNs,
      launchType: FTAppLaunchTracker.getInstance().getSnapshot().launchType,
      reportPath: report.reportPath, error: report.error
    }));
  }
}
