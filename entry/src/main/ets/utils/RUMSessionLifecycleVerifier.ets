import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import process from '@ohos.process';
import { FTSDK, FTRUMConfig } from '@guancecloud/ft_sdk/Index';
import { FTRUMInnerManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMInnerManager';

const TAG = 'RUMSessionLifecycleUI';
const DOMAIN = 0xFF00;
const TICK_TIMEOUT_MS = 75000;
const SETTLE_TIMEOUT_MS = 10000;

export class LifecycleCaseResult {
  id: string = '';
  name: string = '';
  status: string = 'PENDING';
  detail: string = '';
  elapsedMs: number = 0;
}

export class LifecycleDeviceReport {
  schemaVersion: number = 1;
  group: string = 'A';
  runId: string = '';
  pid: number = process.pid;
  parentPid: number = 0;
  startedAt: number = Date.now();
  finishedAt: number = 0;
  completed: boolean = false;
  timerMode: string = 'real platform setInterval, 60000ms; no manual dispatch';
  scope: string = 'Real main-thread Ark runtime in test-only cold start; controlled queue/barrier and forced expiry; no SDK install, network or RDB';
  nativeCrashObservation: string = 'NOT_ASSESSED_UNTIL_RUN_COMPLETES';
  results: LifecycleCaseResult[] = [];
  reportPath: string = '';
}

class LifecycleGate {
  readonly promise: Promise<void>;
  private resolveGate: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve): void => {
      this.resolveGate = resolve;
    });
  }

  release(): void {
    this.resolveGate();
  }
}

export type LifecycleProgress = (message: string, results: LifecycleCaseResult[]) => void;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve): void => {
    setTimeout(resolve, ms);
  });
}

async function bounded(pending: Promise<void>, label: string): Promise<void> {
  let timeoutId: number = -1;
  const timeout = new Promise<void>((_resolve, reject): void => {
    timeoutId = setTimeout((): void => {
      reject(new Error(`${label}: ${SETTLE_TIMEOUT_MS}ms timeout; result is invalid, not PASS`));
    }, SETTLE_TIMEOUT_MS);
  });
  try {
    await Promise.race([pending, timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

/** An offline fixture in an independent UIAbility process, not the Demo's live SDK singleton. */
export class RUMSessionLifecycleVerifier {
  private results: LifecycleCaseResult[] = [];
  private progress: LifecycleProgress;
  private gates: LifecycleGate[] = [];
  private managers: FTRUMInnerManager[] = [];

  constructor(progress: LifecycleProgress) {
    this.progress = progress;
  }

  private fixture(): FTRUMInnerManager {
    FTRUMInnerManager.resetStateInternal();
    const manager = FTRUMInnerManager.getInstance();
    manager.initParams(new FTRUMConfig());
    if (manager.getContext() !== null) {
      throw new Error('Fixture unexpectedly owns a persistence Context');
    }
    this.managers.push(manager);
    return manager;
  }

  private gate(): LifecycleGate {
    const gate = new LifecycleGate();
    this.gates.push(gate);
    return gate;
  }

  private async nativeTick(manager: FTRUMInnerManager, label: string): Promise<void> {
    const previous = manager.getSessionRefreshQueueForTest();
    const started = Date.now();
    let announcedSecond = -1;
    while (manager.getSessionRefreshQueueForTest() === previous) {
      const elapsed = Date.now() - started;
      if (elapsed > TICK_TIMEOUT_MS) {
        throw new Error('No real Session timer delivery within 75s; keep the test page foreground');
      }
      const second = Math.floor(elapsed / 1000);
      if (second !== announcedSecond) {
        announcedSecond = second;
        this.progress(`${label}：等待真实 60 秒定时器（${second}s）`, this.results.slice());
      }
      await delay(100);
    }
    hilog.info(DOMAIN, TAG, 'NATIVE_TICK %{public}s pid=%{public}d elapsedMs=%{public}d', label, process.pid,
      Date.now() - started);
    // Do not return/await the new queue here: it is intentionally held by some cases.
  }

  private async record(id: string, name: string, body: (result: LifecycleCaseResult) => Promise<void>): Promise<void> {
    const result = new LifecycleCaseResult();
    result.id = id;
    result.name = name;
    result.status = 'RUNNING';
    this.results.push(result);
    this.progress(name, this.results.slice());
    const started = Date.now();
    try {
      await body(result);
      if (result.status === 'RUNNING') {
        throw new Error('Case ended without a verdict');
      }
    } catch (error) {
      result.status = 'ERROR';
      result.detail = String(error);
    } finally {
      for (const gate of this.gates) gate.release();
      this.gates = [];
      try {
        for (const manager of this.managers) {
          await bounded(manager.getSessionRefreshQueueForTest(), 'cleanup queue');
          await bounded(manager.shutdown(), 'cleanup shutdown');
        }
        this.managers = [];
        FTRUMInnerManager.resetStateInternal();
      } catch (error) {
        result.status = 'ERROR';
        result.detail += `; cleanup failed: ${String(error)}`;
      }
      result.elapsedMs = Date.now() - started;
      hilog.info(DOMAIN, TAG, 'CASE_RESULT %{public}s', JSON.stringify(result));
      this.progress(`${name}：${result.status}`, this.results.slice());
    }
    if (result.status === 'ERROR') {
      throw new Error(`Fixture error in ${id}; remaining cases were not run`);
    }
  }

  async run(context: common.UIAbilityContext, group: string, parentPid: number): Promise<LifecycleDeviceReport> {
    const report = new LifecycleDeviceReport();
    report.group = group;
    report.parentPid = parentPid;
    report.runId = `${group}-${Date.now()}-${process.pid}`;
    // Refuse a fallback into the live application process or an initialized SDK.
    if (parentPid <= 0 || parentPid === process.pid || FTSDK.getRumConfig() !== null) {
      throw new Error('隔离检查失败：必须从 Demo 首页打开，且测试进程不得安装正常 SDK/RUM');
    }
    hilog.info(DOMAIN, TAG, 'RUN_START %{public}s', JSON.stringify(report));
    try {
      await this.record('timer_identity', '重复初始化与前后台回调', async (result): Promise<void> => {
        const manager = this.fixture();
        const before = manager.getSessionLifecycleStateForTest();
        let stable = before.timerId !== null;
        for (let index = 0; index < 100; index++) {
          stable = stable && FTRUMInnerManager.getInstance() === manager;
          manager.initParams(new FTRUMConfig());
          manager.onAppBackground();
          manager.onAppBackground();
          manager.onAppForeground();
          manager.onAppForeground();
          stable = stable && manager.getSessionLifecycleStateForTest().timerId === before.timerId;
        }
        // Drain the lifecycle closure work before cleanup.
        await delay(100);
        result.status = stable ? 'PASS' : 'FAIL';
        result.detail = `100 次调用；timerId=${before.timerId}；单例与定时器标识保持不变=${stable}。不代表全局定时器计数审计。`;
      });

      await this.record('normal_expiry', '对照：真实定时器刷新过期 Session', async (result): Promise<void> => {
        const manager = this.fixture();
        manager.expireSessionForTest();
        const before = manager.getSessionId();
        await this.nativeTick(manager, result.name);
        await bounded(manager.getSessionRefreshQueueForTest(), result.name);
        const after = manager.getSessionId();
        result.status = before !== after ? 'PASS' : 'FAIL';
        result.detail = `before=${before}; after=${after}; 强制过期后由真实 60 秒定时器完成刷新。`;
      });

      await this.record('queued_shutdown', '销毁后排队任务不得再改 Session', async (result): Promise<void> => {
        const manager = this.fixture();
        const gate = this.gate();
        manager.expireSessionForTest();
        manager.holdSessionRefreshQueueForTest(gate.promise);
        await this.nativeTick(manager, result.name);
        const pending = manager.getSessionRefreshQueueForTest();
        let sessionAtShutdown = '';
        let completedBeforeRelease = false;
        let released = false;
        const shutdown = manager.shutdown().then((): void => {
          sessionAtShutdown = manager.getSessionId();
          completedBeforeRelease = !released;
        });
        await delay(100);
        released = true;
        gate.release();
        await bounded(Promise.all([pending, shutdown]).then((): void => {}), result.name);
        const after = manager.getSessionId();
        result.status = after === sessionAtShutdown && manager.getSessionLifecycleStateForTest().timerId === null ?
          'PASS' : 'FAIL';
        result.detail = `shutdownCompletedBeforeRelease=${completedBeforeRelease}; atShutdown=${sessionAtShutdown}; afterOldTask=${after}`;
      });

      await this.record('queued_reset', 'reset 后旧实例不得再更新状态', async (result): Promise<void> => {
        const oldManager = this.fixture();
        const gate = this.gate();
        oldManager.expireSessionForTest();
        oldManager.holdSessionRefreshQueueForTest(gate.promise);
        await this.nativeTick(oldManager, result.name);
        const pending = oldManager.getSessionRefreshQueueForTest();
        FTRUMInnerManager.resetStateInternal();
        const resetState = oldManager.getSessionLifecycleStateForTest();
        const newManager = FTRUMInnerManager.getInstance();
        newManager.initParams(new FTRUMConfig());
        this.managers.push(newManager);
        const newSession = newManager.getSessionId();
        await delay(100);
        gate.release();
        await bounded(pending, result.name);
        const after = oldManager.getSessionLifecycleStateForTest();
        const oldUnchanged = after.lastUserActiveTime === resetState.lastUserActiveTime && after.sessionId === resetState.sessionId;
        const newUnchanged = newManager.getSessionId() === newSession;
        result.status = oldUnchanged && newUnchanged ? 'PASS' : 'FAIL';
        result.detail = `oldStateUnchanged=${oldUnchanged}; newSessionUnchanged=${newUnchanged}; oldActivityAtReset=${resetState.lastUserActiveTime}; afterOldTask=${after.lastUserActiveTime}`;
      });

      await this.record('inflight_reinit', '旧刷新不得覆盖重新初始化的 Session', async (result): Promise<void> => {
        const manager = this.fixture();
        const gate = this.gate();
        manager.expireSessionForTest();
        manager.holdSyntheticCloseForTest(gate.promise);
        await this.nativeTick(manager, result.name);
        const pending = manager.getSessionRefreshQueueForTest();
        let settled = false;
        pending.then((): void => { settled = true; });
        await delay(100);
        if (settled) throw new Error('Expected an in-flight refresh held by the synthetic-close barrier');
        manager.initParams(new FTRUMConfig());
        const reinitialized = manager.getSessionId();
        gate.release();
        await bounded(pending, result.name);
        const after = manager.getSessionId();
        result.status = reinitialized === after ? 'PASS' : 'FAIL';
        result.detail = `afterInit=${reinitialized}; afterOldRefresh=${after}`;
      });
      report.completed = true;
      report.nativeCrashObservation = 'NO_NATIVE_CRASH_OBSERVED_IN_THIS_COMPLETED_RUN';
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'RUN_ERROR %{public}s', String(error));
    } finally {
      report.finishedAt = Date.now();
      report.results = this.results.slice();
      report.reportPath = `${context.filesDir}/rum-session-lifecycle-${report.runId}.json`;
      const file = fileIo.openSync(report.reportPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(report, null, 2));
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'RUN_FINISH %{public}s', JSON.stringify(report));
    }
    return report;
  }
}
