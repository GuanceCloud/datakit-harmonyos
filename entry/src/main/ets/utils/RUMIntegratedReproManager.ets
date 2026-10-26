import { common } from '@kit.AbilityKit';
import ApplicationStateChangeCallback from '@ohos.app.ability.ApplicationStateChangeCallback';
import { fileIo } from '@kit.CoreFileKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import hilog from '@ohos.hilog';
import process from '@ohos.process';
import { rcp } from '@kit.RemoteCommunicationKit';
import { createFTRCPTrackConfig, FTLogger, FTLoggerConfig, FTRUMConfig, FTRUMGlobalManager, FTSDK, FTSDKConfig } from '@guancecloud/ft_sdk/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { LogEntry } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { FTRUMInnerManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMInnerManager';
import { FTDBTaskPoolExecutor } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBTaskPoolExecutor';
import { RUMIntegratedStringPressure } from './RUMIntegratedStringPressure';

const TAG = 'RUMIntegratedRepro';
const LAST_REPORT = 'rum-integrated-last.json';

export class IntegratedReproConfig {
  group: string = 'A';
  durationSeconds: number = 180;
  navigationIntervalMs: number = 750;
  acceleratedExpiry: boolean = false;
  reconfigureRum: boolean = false;
  timerFocused: boolean = false;
  stringPressure: boolean = false;
  requestUrl: string = '';
}

export class IntegratedReproReport {
  runId: string = '';
  pid: number = process.pid;
  timezoneOffsetMinutes: number = new Date().getTimezoneOffset();
  startedAt: number = 0;
  finishedAt: number = 0;
  status: string = 'IDLE';
  // A process disappearing or an unfinished journal is NOT proof of a native crash.
  nativeCrash: string = 'UNCONFIRMED_REQUIRES_MATCHING_SYSTEM_FAULTLOG';
  config: IntegratedReproConfig = new IntegratedReproConfig();
  sdkInstalled: boolean = false;
  rumInstalled: boolean = false;
  crashTrackingConfigured: boolean = false;
  uploadEndpointConfigured: boolean = false;
  autoSync: boolean = false;
  realContextAttached: boolean = false;
  rdbPreflightViewVerified: boolean = false;
  persistedRunMarkerObserved: boolean = false;
  applicationState: string = 'foreground';
  foregroundEvents: number = 0;
  backgroundEvents: number = 0;
  pagesCreated: number = 0;
  pagesDestroyed: number = 0;
  actionsSubmitted: number = 0;
  logsSubmitted: number = 0;
  httpCompleted: number = 0;
  httpFailed: number = 0;
  observedSessionChanges: number = 0;
  forcedExpiries: number = 0;
  rumReconfigurations: number = 0;
  scenarioVersion: string = 'integrated-v2';
  phase: string = 'TRAFFIC';
  phaseUntil: number = 0;
  quietWindowsStarted: number = 0;
  quietWindowsCompleted: number = 0;
  quietWindowsWithSessionChange: number = 0;
  quietSessionChanges: number = 0;
  observedQueueChanges: number = 0;
  sessionTimerIdAtStart: number | null = null;
  sessionTimerChanges: number = 0;
  quietCheckpointInFlightAtEntry: boolean = false;
  stringBatches: number = 0;
  stringsAllocated: number = 0;
  retainedStringChars: number = 0;
  stringPressurePaused: boolean = false;
  diagnosticErrors: number = 0;
  lastError: string = '';
  lastSessionId: string = '';
  lastViewName: string = '';
  heapUsedKB: number = 0;
  cacheStatus: string = '';
  checkpointAt: number = 0;
  journalPath: string = '';
}

interface IntegratedReproJournalEntry {
  kind: string;
  at: number;
  report: IntegratedReproReport;
}

/** Full, live SDK integration. No mocks, Promise gates, manual timer dispatch or injected faults. */
export class RUMIntegratedReproManager {
  private static instance: RUMIntegratedReproManager = new RUMIntegratedReproManager();
  private context: common.UIAbilityContext | null = null;
  private report: IntegratedReproReport = new IntegratedReproReport();
  private running: boolean = false;
  private starting: boolean = false;
  private stopping: boolean = false;
  private actionTimer: number = -1;
  private checkpointTimer: number = -1;
  private expiryTimer: number = -1;
  private deadlineTimer: number = -1;
  private phaseTimer: number = -1;
  private observerTimer: number = -1;
  private pressureTimer: number = -1;
  private pressure: RUMIntegratedStringPressure = new RUMIntegratedStringPressure();
  private lastQueue: Promise<void> | null = null;
  private quietChanged: boolean = false;
  private httpSession: rcp.Session | null = null;
  private httpBusy: boolean = false;
  private checkpointBusy: boolean = false;
  private lifecycle: ApplicationStateChangeCallback | null = null;

  static getInstance(): RUMIntegratedReproManager { return RUMIntegratedReproManager.instance; }
  isRunning(): boolean { return this.running; }
  isBusy(): boolean { return this.running || this.starting || this.stopping; }
  isForeground(): boolean { return this.report.applicationState === 'foreground'; }
  snapshot(): IntegratedReproReport { return JSON.parse(JSON.stringify(this.report)) as IntegratedReproReport; }
  navigationIntervalMs(): number { return this.report.config.navigationIntervalMs; }
  canNavigate(): boolean { return this.running && this.isForeground() && this.report.phase !== 'TIMER_QUIET'; }

  readiness(): string {
    const sdk = FTSDK.getSDKConfig();
    const rum = FTSDK.getRumConfig();
    if (sdk === null) return '正常 SDK 尚未初始化，请返回 Demo 或使用本地完整初始化';
    if (rum === null || rum.getRumAppId().length === 0) return 'RUM 未配置 appId；可选择本地完整初始化（真实数据库，禁止上传）';
    if (!rum.isEnableTrackAppCrash()) return '当前配置关闭了 Crash 采集，请先在 Demo 配置中开启；不会静默修改现有配置';
    if (sdk.isUseFileDataStore()) return '当前使用 FileStore；本模式要求真实 RDB，请使用 Demo 默认 RDB 配置重新启动';
    if (FTRUMInnerManager.getInstance().getContext() === null) return 'RUM 未绑定真实 Context，不能运行完整集成模式';
    return '';
  }

  /** Explicit UI opt-in only. Never overwrite an existing RUM identity or send the local identity to a saved endpoint. */
  prepareLocal(context: common.UIAbilityContext): void {
    if (this.isBusy()) throw new Error('Test is already running');
    if (FTSDK.getRumConfig() !== null) throw new Error('已有 RUM 配置，不覆盖现有身份；请直接运行或重启后调整配置');
    if (FTSDK.getSDKConfig() === null) {
      FTSDK.install(FTSDKConfig.builder().setDebug(true).setAutoSync(false), context);
    }
    FTSDK.setAutoSync(false);
    FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true).setLogSamplingRate(100));
    FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('rum-integrated-repro-local')
      .setSessionSamplingRate(100).setEnableTrackAppCrash(true)
      .setEnableTraceUserView(true).setEnableTraceUserAction(true).setEnableTraceUserResource(true));
  }

  previous(context: common.UIAbilityContext): string {
    const path = `${context.filesDir}/${LAST_REPORT}`;
    try {
      if (!fileIo.accessSync(path)) return '无上次完整集成记录';
      const previous = JSON.parse(fileIo.readTextSync(path)) as IntegratedReproReport;
      const unexplained = (previous.status === 'RUNNING' || previous.status === 'STOPPING') && previous.pid !== process.pid;
      return `${previous.runId}: ${unexplained ? '上轮进程未正常结束，原因未知，不能认定为 Native 崩溃' : previous.status}`;
    } catch (error) {
      return `上次检查点不可读：${String(error)}；不能据此认定崩溃`;
    }
  }

  private writeEvent(kind: string): void {
    const context = this.context;
    if (context === null) return;
    this.report.checkpointAt = Date.now();
    const data = JSON.stringify(this.report);
    try {
      const journal = fileIo.openSync(this.report.journalPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      try {
        const entry: IntegratedReproJournalEntry = { kind, at: Date.now(), report: this.report };
        fileIo.writeSync(journal.fd, `${JSON.stringify(entry)}\n`);
        fileIo.fsyncSync(journal.fd);
      } finally { fileIo.closeSync(journal); }
      const state = fileIo.openSync(`${context.filesDir}/${LAST_REPORT}`,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(state.fd, data); fileIo.fsyncSync(state.fd); }
      finally { fileIo.closeSync(state); }
    } catch (error) {
      // A harness disk/permission error must never become an uncaught JS exception.
      this.diagnostic(error as Object);
      if (kind === 'RUN_FINISH' && this.report.status !== 'INCOMPLETE_STOP') this.report.status = 'COMPLETED_WITH_DIAGNOSTICS';
    }
    hilog.info(0xFF00, TAG, '%{public}s %{public}s', kind, JSON.stringify(this.report));
  }

  private diagnostic(error: Object): void {
    this.report.diagnosticErrors++;
    this.report.lastError = String(error);
    // Diagnostics are NOT reported using addError or an intentional exception/crash.
    hilog.error(0xFF00, TAG, 'DIAGNOSTIC %{public}s', String(error));
  }

  async start(context: common.UIAbilityContext, config: IntegratedReproConfig): Promise<void> {
    if (this.isBusy()) throw new Error('已有测试运行中');
    const issue = this.readiness();
    if (issue.length > 0) throw new Error(issue);
    if (!Number.isFinite(config.durationSeconds) || config.durationSeconds < 60 || config.durationSeconds > 21600) {
      throw new Error('时长必须为 60–21600 秒');
    }
    if (config.requestUrl.length > 512 || (config.requestUrl.length > 0 && !/^https?:\/\//.test(config.requestUrl))) {
      throw new Error('GET 地址须为 HTTP(S)，且不超过512字符');
    }
    if (config.timerFocused && (!config.acceleratedExpiry || config.reconfigureRum)) {
      throw new Error('定时器观察档须开启过期标记，并关闭重新配置，避免其他入口提前刷新');
    }
    if (!Number.isFinite(config.navigationIntervalMs)) throw new Error('导航间隔无效');
    this.starting = true;
    this.context = context;
    this.report = new IntegratedReproReport();
    this.report.config = JSON.parse(JSON.stringify(config)) as IntegratedReproConfig;
    this.report.config.navigationIntervalMs = Math.max(250, Math.min(5000, config.navigationIntervalMs));
    this.report.startedAt = Date.now();
    this.report.runId = `${config.group}-${this.report.startedAt}-${process.pid}`;
    this.report.journalPath = `${context.filesDir}/rum-integrated-${this.report.runId}.jsonl`;
    this.report.status = 'PREFLIGHT';
    const sdk = FTSDK.getSDKConfig()!;
    const rum = FTSDK.getRumConfig()!;
    this.report.sdkInstalled = true;
    this.report.rumInstalled = true;
    this.report.crashTrackingConfigured = rum.isEnableTrackAppCrash();
    this.report.uploadEndpointConfigured = sdk.getDatakitUrl().length > 0 || sdk.getDatawayUrl().length > 0;
    this.report.autoSync = sdk.isAutoSyncEnabled();
    this.report.realContextAttached = true;
    try {
      this.writeEvent('PREFLIGHT');
      // A real public View insertion followed by an actual SQL-backed query; no fake persistence boundary.
      const global = FTRUMGlobalManager.getInstance();
      const preflightProperties: Record<string, object> = {};
      preflightProperties['repro_run_id'] = new String(this.report.runId);
      await global.startView(`RUMIntegratedPreflight-${this.report.runId}`, preflightProperties);
      const view = FTRUMInnerManager.getInstance().getActiveView();
      if (view === null) throw new Error('Preflight did not create a real View');
      const persisted = await FTDBTaskPoolExecutor.queryRumViewById(context, view.getId());
      if (persisted === null) throw new Error('真实 RDB 中未查到预检 View，本轮不得标记为完整集成');
      this.report.rdbPreflightViewVerified = true;
      await global.stopView();
      this.running = true;
      this.report.status = 'RUNNING';
      AppStorage.setOrCreate('rumIntegratedForeground', true);
      this.report.lastSessionId = FTRUMInnerManager.getInstance().getSessionId();
      this.lastQueue = FTRUMInnerManager.getInstance().getSessionRefreshQueueForTest();
      this.report.sessionTimerIdAtStart = FTRUMInnerManager.getInstance().getSessionLifecycleStateForTest().timerId;
      this.lifecycle = {
        onApplicationForeground: (): void => {
          if (!this.running) return;
          this.report.applicationState = 'foreground';
          this.report.foregroundEvents++;
          AppStorage.setOrCreate('rumIntegratedForeground', true);
          this.observeRuntime();
          this.updateNavigation();
          this.startForegroundTasks();
          this.writeEvent('FOREGROUND');
          void this.checkpoint();
        },
        onApplicationBackground: (): void => {
          if (!this.running) return;
          this.report.applicationState = 'background';
          this.report.backgroundEvents++;
          AppStorage.setOrCreate('rumIntegratedForeground', false);
          this.updateNavigation();
          clearInterval(this.actionTimer); clearInterval(this.checkpointTimer);
          if (this.report.config.acceleratedExpiry && !this.report.config.timerFocused) this.expireSession();
          this.writeEvent('BACKGROUND');
        }
      };
      context.getApplicationContext().on('applicationStateChange', this.lifecycle);
      this.startForegroundTasks();
      this.updateNavigation();
      if (config.timerFocused) this.scheduleQuietWindow();
      if (config.stringPressure) {
        this.pressureTimer = setInterval((): void => { this.allocateStrings(); }, 250);
      }
      this.deadlineTimer = setTimeout((): void => { void this.stop('COMPLETED_NO_CRASH'); }, config.durationSeconds * 1000);
      if (!config.timerFocused && (config.acceleratedExpiry || config.reconfigureRum)) {
        this.expiryTimer = setInterval((): void => {
          try {
            if (config.reconfigureRum) {
              const current = FTSDK.getRumConfig();
              if (current !== null) { FTSDK.installRUMConfig(current); this.report.rumReconfigurations++; }
            }
            if (config.acceleratedExpiry) this.expireSession();
          } catch (error) { this.diagnostic(error as Object); }
        }, 60000);
      }
      if (config.acceleratedExpiry && !config.timerFocused) this.expireSession();
      this.writeEvent('RUN_START');
    } catch (error) {
      this.report.status = 'SETUP_ERROR';
      this.diagnostic(error as Object);
      this.clearOwnTasks();
      this.writeEvent('SETUP_ERROR');
      throw new Error(String(error));
    } finally { this.starting = false; }
  }

  private startForegroundTasks(): void {
    clearInterval(this.actionTimer); clearInterval(this.checkpointTimer); clearInterval(this.observerTimer);
    this.actionTimer = setInterval((): void => { this.generateTraffic(); }, 250);
    this.checkpointTimer = setInterval((): void => { void this.checkpoint(); }, 5000);
    // Read-only observations: no refresh call, queue gate, manual tick, or injected error.
    this.observerTimer = setInterval((): void => {
      if (this.running && this.isForeground()) this.observeRuntime();
    }, 1000);
  }

  private updateNavigation(): void { AppStorage.setOrCreate('rumIntegratedNavigating', this.canNavigate()); }

  private scheduleQuietWindow(): void {
    this.report.phase = 'TRAFFIC';
    this.report.phaseUntil = Date.now() + 10000;
    this.phaseTimer = setTimeout((): void => {
      if (!this.running) return;
      this.report.phase = 'TIMER_QUIET';
      this.report.phaseUntil = Date.now() + 70000;
      this.report.quietWindowsStarted++;
      this.report.quietCheckpointInFlightAtEntry = this.checkpointBusy;
      this.quietChanged = false;
      this.updateNavigation();
      this.expireSession();
      this.writeEvent('QUIET_START');
      this.phaseTimer = setTimeout((): void => {
        if (!this.running) return;
        this.observeRuntime();
        this.report.quietWindowsCompleted++;
        if (this.quietChanged) this.report.quietWindowsWithSessionChange++;
        this.writeEvent('QUIET_END');
        this.scheduleQuietWindow();
        this.updateNavigation();
        this.writeEvent('TRAFFIC_START');
      }, 70000);
    }, 10000);
  }

  private observeRuntime(): void {
    const manager = FTRUMInnerManager.getInstance();
    const session = manager.getSessionId();
    if (session !== this.report.lastSessionId) {
      this.report.observedSessionChanges++;
      if (this.report.phase === 'TIMER_QUIET') {
        this.report.quietSessionChanges++;
        this.quietChanged = true;
      }
      this.report.lastSessionId = session;
      this.writeEvent('SESSION_CHANGED');
    }
    const queue = manager.getSessionRefreshQueueForTest();
    if (queue !== this.lastQueue) { this.report.observedQueueChanges++; this.lastQueue = queue; }
    const timerId = manager.getSessionLifecycleStateForTest().timerId;
    if (timerId !== this.report.sessionTimerIdAtStart && this.report.sessionTimerChanges === 0) {
      this.report.sessionTimerChanges++;
      this.writeEvent('TIMER_CHANGED');
    }
  }

  private allocateStrings(): void {
    if (!this.running || !this.isForeground() || this.report.stringPressurePaused) return;
    try {
      this.report.heapUsedKB = Number(hidebug.getAppVMMemoryInfo().heapUsed);
      if (!Number.isFinite(this.report.heapUsedKB) || this.report.heapUsedKB <= 0 || this.report.heapUsedKB >= 128 * 1024) {
        this.report.stringPressurePaused = true;
        this.pressure.clear();
        this.report.retainedStringChars = 0;
        this.writeEvent('PRESSURE_PAUSED');
        return;
      }
      this.report.stringsAllocated += this.pressure.step(`${this.report.runId}-${this.report.stringBatches}`);
      this.report.stringBatches++;
      this.report.retainedStringChars = this.pressure.retainedChars();
    } catch (error) {
      this.report.stringPressurePaused = true;
      this.diagnostic(error as Object);
    }
  }

  private expireSession(): void {
    FTRUMInnerManager.getInstance().expireSessionForTest();
    this.report.forcedExpiries++;
    // The SDK's original interval and public collection methods perform the refresh. No private refresh is invoked.
    this.writeEvent('FORCED_EXPIRY');
  }

  pageShown(variant: string): void {
    if (!this.running) return;
    this.report.pagesCreated++;
    this.report.lastViewName = variant;
  }

  pageDestroyed(): void { if (this.running) this.report.pagesDestroyed++; }

  private generateTraffic(): void {
    if (!this.running || !this.isForeground() || this.report.phase === 'TIMER_QUIET') return;
    try {
      const global = FTRUMGlobalManager.getInstance();
      for (let index = 0; index < 2; index++) {
        const properties: Record<string, object> = {};
        properties['repro_run_id'] = new String(this.report.runId);
        properties['repro_page'] = new String(this.report.lastViewName);
        global.addAction(`rum_integrated_action_${this.report.actionsSubmitted}`, 'click', properties);
        this.report.actionsSubmitted++;
      }
      if (this.report.actionsSubmitted % 8 === 0) {
        const logs: LogEntry[] = [{ tag: TAG, level: 'i', timestampMs: Date.now(),
          message: `${this.report.runId} live-integrated-${this.report.logsSubmitted}` }];
        FTLogger.batchLog(logs);
        this.report.logsSubmitted++;
      }
      this.observeRuntime();
    } catch (error) { this.diagnostic(error as Object); }
  }

  private async realRequest(): Promise<void> {
    if (!this.running || !this.isForeground() || this.report.phase === 'TIMER_QUIET' ||
      this.httpBusy || this.report.config.requestUrl.length === 0) return;
    this.httpBusy = true;
    try {
      if (this.httpSession === null) {
        this.httpSession = rcp.createSession(createFTRCPTrackConfig({ requestConfiguration: {
          transfer: { timeout: { connectMs: 3000, transferMs: 5000 } }
        } }));
      }
      await this.httpSession.fetch(new rcp.Request(this.report.config.requestUrl, 'GET'));
      this.report.httpCompleted++;
    } catch (error) { this.report.httpFailed++; this.diagnostic(error as Object); }
    finally { this.httpBusy = false; }
  }

  private async checkpoint(): Promise<void> {
    if (!this.running || this.checkpointBusy || this.context === null) return;
    if (Date.now() - this.report.startedAt >= this.report.config.durationSeconds * 1000) {
      await this.stop('COMPLETED_NO_CRASH');
      return;
    }
    if (this.report.phase === 'TIMER_QUIET') {
      this.observeRuntime();
      this.writeEvent('CHECKPOINT');
      return;
    }
    this.checkpointBusy = true;
    try {
      this.report.heapUsedKB = Number(hidebug.getAppVMMemoryInfo().heapUsed);
      this.report.cacheStatus = (await FTDBTaskPoolExecutor.getCacheStatus(this.context)).slice(0, 1000);
      const rows = await FTDBTaskPoolExecutor.querySyncData(this.context, [DataType.RUM_APP, DataType.LOG], 100, true);
      if (rows.some((row): boolean => row.getDataString().includes(this.report.runId))) this.report.persistedRunMarkerObserved = true;
      await this.realRequest();
      if (this.running) this.writeEvent('CHECKPOINT');
    } catch (error) { this.diagnostic(error as Object); }
    finally { this.checkpointBusy = false; }
  }

  private clearOwnTasks(): void {
    this.running = false;
    this.updateNavigation();
    clearInterval(this.actionTimer); clearInterval(this.checkpointTimer); clearInterval(this.expiryTimer);
    clearTimeout(this.deadlineTimer);
    clearTimeout(this.phaseTimer); clearInterval(this.observerTimer); clearInterval(this.pressureTimer);
    this.pressure.clear(); this.report.retainedStringChars = 0;
    this.actionTimer = -1; this.checkpointTimer = -1; this.expiryTimer = -1;
    if (this.lifecycle !== null && this.context !== null) {
      try { this.context.getApplicationContext().off('applicationStateChange', this.lifecycle); }
      catch (error) { this.diagnostic(error as Object); }
      this.lifecycle = null;
    }
    if (this.httpSession !== null) {
      try { this.httpSession.close(); } catch (error) { this.diagnostic(error as Object); }
      this.httpSession = null;
    }
  }

  async stop(status: string = 'STOPPED_NO_CRASH'): Promise<void> {
    if (!this.running || this.stopping) return;
    this.stopping = true;
    this.report.status = 'STOPPING';
    this.clearOwnTasks();
    this.writeEvent('RUN_STOPPING');
    let stopTimeout: number = -1;
    let pendingTimeout: number = -1;
    try {
      const complete = async (): Promise<void> => {
        await FTRUMGlobalManager.getInstance().stopView();
        FTSDK.flushSyncData();
        if (this.context !== null) this.report.cacheStatus = (await FTDBTaskPoolExecutor.getCacheStatus(this.context)).slice(0, 1000);
      };
      await Promise.race([complete(), new Promise<void>((_resolve, reject): void => {
        stopTimeout = setTimeout((): void => { reject(new Error('测试结束收尾超过15秒，本轮不记为完整结束')); }, 15000);
      })]);
      // A prior checkpoint can still own an HTTP/RDB await. Do not reuse this fixture until it settles.
      await Promise.race([new Promise<void>((resolve): void => {
        if (!this.checkpointBusy) { resolve(); return; }
        pendingTimeout = setInterval((): void => { if (!this.checkpointBusy) resolve(); }, 100);
      }), new Promise<void>((_resolve, reject): void => {
        clearTimeout(stopTimeout);
        stopTimeout = setTimeout((): void => { reject(new Error('旧检查点未结束，须重启 Demo 后再测试')); }, 10000);
      })]);
      this.report.status = this.report.diagnosticErrors > 0 || this.report.stringPressurePaused ? 'COMPLETED_WITH_DIAGNOSTICS' : status;
    } catch (error) {
      this.diagnostic(error as Object);
      this.report.status = 'INCOMPLETE_STOP';
    } finally {
      clearTimeout(stopTimeout); clearInterval(pendingTimeout);
      this.report.finishedAt = Date.now();
      this.writeEvent('RUN_FINISH');
      // If an await never settled, keep start disabled; a new run must not be touched by old callbacks.
      this.stopping = this.report.status === 'INCOMPLETE_STOP';
    }
    // Leave the SDK's own timers, runtime, database and crash monitoring intact.
  }
}
