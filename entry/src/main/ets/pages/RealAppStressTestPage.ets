import { common, Want } from '@kit.AbilityKit';
import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import {
  createEmptyStressTestStats,
  DEFAULT_REAL_TRAFFIC_URL,
  StressTestConfig,
  StressTestManager,
  StressTestReport,
  StressRunMode,
  StressTestStats
} from '../utils/StressTestManager';
import { SDKTaskScheduler } from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKTaskScheduler';
import preferences from '@ohos.data.preferences';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';
import {
  KEY_STRESS_SERVICE_LAST_ERROR,
  KEY_STRESS_SERVICE_LAST_EVENT,
  KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS,
  KEY_STRESS_SERVICE_REQUEST_COUNT,
  KEY_STRESS_SERVICE_START_ID,
  KEY_STRESS_SERVICE_STATE,
  KEY_STRESS_SERVICE_STOP_REASON,
  markStressServiceError,
  markStressServiceEvent,
  markStressServiceStarting,
  markStressServiceUnsupported,
  resetStressServiceStatus,
  STRESS_SERVICE_STATE_DESTROYED,
  STRESS_SERVICE_STATE_ERROR,
  STRESS_SERVICE_STATE_IDLE,
  STRESS_SERVICE_STATE_KEEPALIVE,
  STRESS_SERVICE_STATE_STARTED,
  STRESS_SERVICE_STATE_STARTING,
  STRESS_SERVICE_STATE_STOPPED,
  STRESS_SERVICE_STATE_STOPPING,
  STRESS_SERVICE_STATE_UNSUPPORTED
} from '../utils/StressServiceStatusStore';

const TAG = "RealAppStressTestPage";
const PREFERENCES_NAME = 'real_app_stress_test_settings';
const KEY_TEST_MINUTES = 'test_minutes';
const KEY_TEST_SECONDS = 'test_seconds';
const KEY_STRESS_RUN_MODE = 'stress_run_mode';
const KEY_STRESS_TOTAL_COUNT = 'stress_total_count';
const KEY_USE_REAL_TRAFFIC = 'use_real_traffic';
const KEY_ENABLE_LOGS = 'enable_logs';
const KEY_ENABLE_ACTIONS = 'enable_actions';
const KEY_ENABLE_RESOURCES = 'enable_resources';
const KEY_ENABLE_NAVIGATION = 'enable_navigation';
const KEY_ENABLE_ERRORS = 'enable_errors';
const KEY_ENABLE_LONG_TASKS = 'enable_long_tasks';
const KEY_ENABLE_BACKGROUND_SERVICE = 'enable_background_service';
const KEY_REAL_RESOURCE_URL = 'real_resource_url';
const KEY_STRESS_LOG_BATCH_SIZE = 'stress_log_batch_size';
const KEY_STRESS_LOG_INTERVAL_MS = 'stress_log_interval_ms';
const KEY_STRESS_ACTION_TIMER_COUNT = 'stress_action_timer_count';
const KEY_STRESS_ACTION_INTERVAL_MS = 'stress_action_interval_ms';
const KEY_STRESS_RESOURCE_TIMER_COUNT = 'stress_resource_timer_count';
const KEY_STRESS_RESOURCE_INTERVAL_MS = 'stress_resource_interval_ms';
const KEY_STRESS_NAVIGATION_INTERVAL_MS = 'stress_navigation_interval_ms';
const KEY_STRESS_ERROR_BATCH_SIZE = 'stress_error_batch_size';
const KEY_STRESS_ERROR_INTERVAL_MS = 'stress_error_interval_ms';
const KEY_STRESS_LONG_TASK_BATCH_SIZE = 'stress_long_task_batch_size';
const KEY_STRESS_LONG_TASK_INTERVAL_MS = 'stress_long_task_interval_ms';
const DEFAULT_TEST_MINUTES = 1;
const DEFAULT_TEST_SECONDS = 0;
const DEFAULT_STRESS_RUN_MODE: StressRunMode = 'duration';
const DEFAULT_STRESS_TOTAL_COUNT = 200;
const DEFAULT_STRESS_LOG_BATCH_SIZE = 1;
const DEFAULT_STRESS_LOG_INTERVAL_MS = 20;
const DEFAULT_STRESS_ACTION_TIMER_COUNT = 2;
const DEFAULT_STRESS_ACTION_INTERVAL_MS = 20;
const DEFAULT_STRESS_RESOURCE_TIMER_COUNT = 2;
const DEFAULT_STRESS_RESOURCE_INTERVAL_MS = 200;
const DEFAULT_STRESS_NAVIGATION_INTERVAL_MS = 1000;
const DEFAULT_STRESS_ERROR_BATCH_SIZE = 1;
const DEFAULT_STRESS_ERROR_INTERVAL_MS = 1000;
const DEFAULT_STRESS_LONG_TASK_BATCH_SIZE = 1;
const DEFAULT_STRESS_LONG_TASK_INTERVAL_MS = 1500;
const DEFAULT_REAL_RESOURCE_URL = '';
const MIN_STRESS_LOG_BATCH_SIZE = 1;
const MIN_STRESS_LOG_INTERVAL_MS = 16;
const MIN_STRESS_ACTION_TIMER_COUNT = 1;
const MIN_STRESS_ACTION_INTERVAL_MS = 16;
const MIN_STRESS_RESOURCE_TIMER_COUNT = 1;
const MIN_STRESS_RESOURCE_INTERVAL_MS = 50;
const MIN_STRESS_NAVIGATION_INTERVAL_MS = 250;
const MIN_STRESS_ERROR_BATCH_SIZE = 1;
const MIN_STRESS_ERROR_INTERVAL_MS = 250;
const MIN_STRESS_LONG_TASK_BATCH_SIZE = 1;
const MIN_STRESS_LONG_TASK_INTERVAL_MS = 250;
const MIN_STRESS_TOTAL_COUNT = 1;
const SDK_LOG_LANE = 'log';
const SDK_EVENT_LANE = 'event';
const SDK_DATA_PROCESS_LANE = 'data-process';
const SDK_LOG_FLUSH_BATCH_SIZE = 20;
const SDK_LOG_PROCESS_COALESCE_MS = 100;
const SDK_SYNC_PAGE_SIZE = 100;
const DEFAULT_SDK_EVENT_COST_MS = 50;
const DEFAULT_SDK_DATA_PROCESS_COST_MS = 50;
const STATS_COMMIT_THROTTLE_MS = 250;

/**
 * Real App Stress Test Page
 * Simulates real user behavior patterns for stress testing.
 */
@Entry
@Component
export struct RealAppStressTestPage {
  @State abilityContext: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  @State testDuration: number = 60;
  @State testMinutes: number = DEFAULT_TEST_MINUTES;
  @State testSeconds: number = DEFAULT_TEST_SECONDS;
  @State stressRunMode: StressRunMode = DEFAULT_STRESS_RUN_MODE;
  @State stressTotalCount: number = DEFAULT_STRESS_TOTAL_COUNT;
  @State stressTotalCountInput: string = `${DEFAULT_STRESS_TOTAL_COUNT}`;
  @State isTestRunning: boolean = false;
  @State elapsedSeconds: number = 0;
  @State stats: StressTestStats = createEmptyStressTestStats();
  @State reportText: string = "";
  @State useRealTraffic: boolean = false;
  @State enableLogs: boolean = true;
  @State enableActions: boolean = true;
  @State enableResources: boolean = true;
  @State enableNavigation: boolean = true;
  @State enableErrors: boolean = false;
  @State enableLongTasks: boolean = false;
  @State enableBackgroundService: boolean = false;
  @State realResourceUrls: string[] = [DEFAULT_REAL_RESOURCE_URL];
  @State stressLogBatchSize: number = DEFAULT_STRESS_LOG_BATCH_SIZE;
  @State stressLogIntervalMs: number = DEFAULT_STRESS_LOG_INTERVAL_MS;
  @State stressActionTimerCount: number = DEFAULT_STRESS_ACTION_TIMER_COUNT;
  @State stressActionIntervalMs: number = DEFAULT_STRESS_ACTION_INTERVAL_MS;
  @State stressResourceTimerCount: number = DEFAULT_STRESS_RESOURCE_TIMER_COUNT;
  @State stressResourceIntervalMs: number = DEFAULT_STRESS_RESOURCE_INTERVAL_MS;
  @State stressNavigationIntervalMs: number = DEFAULT_STRESS_NAVIGATION_INTERVAL_MS;
  @State stressErrorBatchSize: number = DEFAULT_STRESS_ERROR_BATCH_SIZE;
  @State stressErrorIntervalMs: number = DEFAULT_STRESS_ERROR_INTERVAL_MS;
  @State stressLongTaskBatchSize: number = DEFAULT_STRESS_LONG_TASK_BATCH_SIZE;
  @State stressLongTaskIntervalMs: number = DEFAULT_STRESS_LONG_TASK_INTERVAL_MS;
  @StorageLink(KEY_STRESS_SERVICE_STATE) backgroundServiceState: string = STRESS_SERVICE_STATE_IDLE;
  @StorageLink(KEY_STRESS_SERVICE_LAST_EVENT) backgroundServiceLastEvent: string = 'none';
  @StorageLink(KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS) backgroundServiceLastEventTimeMs: number = 0;
  @StorageLink(KEY_STRESS_SERVICE_START_ID) backgroundServiceStartId: number = -1;
  @StorageLink(KEY_STRESS_SERVICE_REQUEST_COUNT) backgroundServiceRequestCount: number = 0;
  @StorageLink(KEY_STRESS_SERVICE_STOP_REASON) backgroundServiceStopReason: string = 'none';
  @StorageLink(KEY_STRESS_SERVICE_LAST_ERROR) backgroundServiceLastError: string = '';

  private stressTestManager: StressTestManager = StressTestManager.getInstance();
  private updateTimer: number | null = null;
  private statsCommitTimer: number | null = null;
  private pendingStatsSnapshot: StressTestStats | null = null;
  private preferencesStore: preferences.Preferences | null = null;
  private lastReportEndedAtMs: number = 0;

  async aboutToAppear() {
    DemoLogger.i(TAG, "RealAppStressTestPage initialized");
    await this.loadSettings();
    this.refreshStats();
    if (this.isTestRunning) {
      DemoLogger.i(TAG, `Resuming stress test monitoring: elapsed=${this.elapsedSeconds}s, duration=${this.testDuration}s`);
      this.startUpdateTimer();
    } else {
      this.refreshReportFromManager(false);
    }
  }

  async aboutToDisappear() {
    this.flushPendingStatsCommit();
    this.stopUpdateTimer();
    await this.saveSettings();
  }

  private startUpdateTimer(): void {
    this.stopUpdateTimer();
    this.updateTimer = setInterval((): void => {
      this.refreshStats();
      if (!this.isTestRunning) {
        DemoLogger.i(TAG, "StressTestManager stopped, stopping update timer");
        this.stopUpdateTimer();
        this.refreshReportFromManager(true);
      }
    }, 1000);
  }

  private stopUpdateTimer(): void {
    if (this.updateTimer !== null) {
      clearInterval(this.updateTimer);
      this.updateTimer = null;
    }
  }

  private refreshStats(): void {
    const snapshot = this.stressTestManager.getStatsSnapshot();
    this.isTestRunning = snapshot.isRunning;
    this.elapsedSeconds = snapshot.elapsedSeconds;
    this.pendingStatsSnapshot = snapshot;
    if (this.statsCommitTimer !== null) {
      return;
    }
    this.statsCommitTimer = setTimeout((): void => {
      this.statsCommitTimer = null;
      this.commitPendingStatsSnapshot();
    }, STATS_COMMIT_THROTTLE_MS);
  }

  private commitPendingStatsSnapshot(): void {
    const snapshot = this.pendingStatsSnapshot;
    if (snapshot === null) {
      return;
    }
    this.pendingStatsSnapshot = null;
    this.stats = snapshot;
    this.isTestRunning = snapshot.isRunning;
    this.elapsedSeconds = snapshot.elapsedSeconds;
  }

  private flushPendingStatsCommit(): void {
    if (this.statsCommitTimer !== null) {
      clearTimeout(this.statsCommitTimer);
      this.statsCommitTimer = null;
    }
    this.commitPendingStatsSnapshot();
  }

  private refreshReportFromManager(showToast: boolean): void {
    const report = this.stressTestManager.getLastReport();
    if (report === null || report.endedAtMs === this.lastReportEndedAtMs) {
      return;
    }

    this.lastReportEndedAtMs = report.endedAtMs;
    this.reportText = this.stressTestManager.formatReport(report);
    if (showToast) {
      promptAction.showToast({
        message: `Test completed (${report.elapsedSeconds}s)`,
        duration: 3000
      });
    }
  }

  async startStressTest(): Promise<void> {
    if (this.isTestRunning) {
      promptAction.showToast({
        message: "Test is already running",
        duration: 2000
      });
      return;
    }

    try {
      this.updateTestDuration();
      this.normalizeRunTargetSettings();
      this.normalizeStressLogSettings();
      this.normalizeStressActionSettings();
      this.normalizeStressResourceSettings();
      this.normalizeStressNavigationSettings();
      this.normalizeStressErrorSettings();
      this.normalizeStressLongTaskSettings();
      const config = this.buildStressConfig();
      if (!this.hasRunnableScenario(config)) {
        promptAction.showToast({
          message: "Enable at least one scenario",
          duration: 2000
        });
        return;
      }

      this.reportText = "";
      this.lastReportEndedAtMs = 0;
      if (this.enableBackgroundService) {
        resetStressServiceStatus();
      }
      await this.saveSettings();
      DemoLogger.i(TAG,
        `Starting stress test: mode=${config.runMode}, duration=${config.durationSeconds}s, totalTarget=${config.totalTargetCount}, traffic=${config.trafficMode}, logBatchSize=${config.logBatchSize}, logInterval=${config.logIntervalMs}, actionTimers=${config.actionThreadCount}, actionInterval=${config.actionIntervalMs}, resourceTimers=${config.resourceThreadCount}, resourceInterval=${config.resourceIntervalMs}, resourceUrls=${this.formatRealResourceUrlSummary(config.realResourceUrl)}, navigationInterval=${config.navigationIntervalMs}, errorBatchSize=${config.errorBatchSize}, errorInterval=${config.errorIntervalMs}, longTaskBatchSize=${config.longTaskBatchSize}, longTaskInterval=${config.longTaskIntervalMs}, background=${this.enableBackgroundService}`);

      this.stressTestManager.runWithConfig(config);
      this.refreshStats();
      if (!this.isTestRunning) {
        this.refreshReportFromManager(false);
        promptAction.showToast({
          message: this.stats.lastErrorMessage.length > 0 ? this.stats.lastErrorMessage : "Stress test failed to start",
          duration: 3000
        });
        return;
      }

      if (this.enableBackgroundService) {
        await this.startBackgroundStressService();
      }

      this.refreshStats();
      this.startUpdateTimer();

      promptAction.showToast({
        message: `Stress test started (${this.formatRunTargetForToast()})`,
        duration: 2000
      });

      if (config.enableNavigation) {
        this.navigateToStressTestPageA();
      }
    } catch (error) {
      const startErrorMessage = this.formatThrowableMessage(error);
      DemoLogger.e(TAG, `Failed to start stress test: ${startErrorMessage}`);
      if (this.stressTestManager.isStressTestRunning()) {
        this.stressTestManager.stop('error');
      }
      this.refreshStats();
      this.refreshReportFromManager(false);
      promptAction.showToast({
        message: `Failed to start: ${startErrorMessage}`,
        duration: 3000
      });
      this.isTestRunning = false;
    }
  }

  private navigateToStressTestPageA(): void {
    try {
      router.replaceUrl({ url: 'pages/StressTestAPage' });
      DemoLogger.i(TAG, "Auto navigation started at StressTestAPage (replaced)");
    } catch (error) {
      DemoLogger.e(TAG, `Failed to navigate to StressTestAPage: ${error}`);
      promptAction.showToast({
        message: `Navigation failed: ${error}`,
        duration: 2000
      });
    }
  }

  triggerCrash(): void {
    DemoLogger.i(TAG, "Triggering crash...");
    promptAction.showToast({
      message: "Crash triggered - app will crash",
      duration: 1000
    });
    // Throw asynchronously so HarmonyOS errorManager can catch it as an unhandled exception.
    setTimeout((): void => {
      throw new Error('Intentional crash for stress testing');
    }, 100);
  }

  async stopStressTest(): Promise<void> {
    if (!this.isTestRunning) {
      promptAction.showToast({
        message: "Test is not running",
        duration: 2000
      });
      return;
    }

    try {
      DemoLogger.i(TAG, "Stopping stress test");
      const report = this.stressTestManager.stop('manual');
      if (this.enableBackgroundService || this.stats.source === 'background-service') {
        await this.stopBackgroundStressService();
      }

      this.stopUpdateTimer();
      this.refreshStats();
      this.refreshReportFromReport(report);

      const finalSeconds = report !== null ? report.elapsedSeconds : this.elapsedSeconds;
      DemoLogger.i(TAG, `Stress test stopped successfully. Total runtime: ${finalSeconds} seconds`);
      promptAction.showToast({
        message: `Stress test stopped (ran for ${finalSeconds}s)`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, `Failed to stop stress test: ${error}`);
      promptAction.showToast({
        message: `Failed to stop: ${error}`,
        duration: 3000
      });
      this.isTestRunning = false;
      this.stopUpdateTimer();
    }
  }

  private refreshReportFromReport(report: StressTestReport | null): void {
    if (report === null) {
      return;
    }
    this.lastReportEndedAtMs = report.endedAtMs;
    this.reportText = this.stressTestManager.formatReport(report);
  }

  private buildStressConfig(): StressTestConfig {
    const useRealResourceTraffic = this.enableResources && this.useRealTraffic;
    const durationSeconds = this.stressRunMode === 'duration' ? this.testDuration : 0;
    const totalTargetCount = this.stressRunMode === 'total' ? this.stressTotalCount : 0;
    const config = this.stressTestManager.createConfig(
      durationSeconds,
      useRealResourceTraffic,
      this.enableLogs,
      this.enableActions,
      this.enableResources,
      this.enableNavigation,
      this.enableErrors,
      this.enableLongTasks,
      this.enableBackgroundService ? 'background-service' : 'foreground'
    );
    config.runMode = this.stressRunMode;
    config.totalTargetCount = totalTargetCount;
    config.logThreadCount = 1;
    config.logTotalCount = totalTargetCount;
    config.logBatchSize = this.stressLogBatchSize;
    config.logIntervalMs = this.stressLogIntervalMs;
    config.actionThreadCount = this.stressActionTimerCount;
    config.actionIntervalMs = this.stressActionIntervalMs;
    config.resourceThreadCount = this.stressResourceTimerCount;
    config.resourceIntervalMs = this.stressResourceIntervalMs;
    config.realResourceUrl = this.serializeRealResourceUrls();
    config.navigationIntervalMs = this.stressNavigationIntervalMs;
    config.errorBatchSize = this.stressErrorBatchSize;
    config.errorIntervalMs = this.stressErrorIntervalMs;
    config.longTaskBatchSize = this.stressLongTaskBatchSize;
    config.longTaskIntervalMs = this.stressLongTaskIntervalMs;
    return config;
  }

  private hasRunnableScenario(config: StressTestConfig): boolean {
    return config.enableLogs ||
      config.enableActions ||
      config.enableResources ||
      config.enableNavigation ||
      config.enableErrors ||
      config.enableLongTasks;
  }

  private async startBackgroundStressService(): Promise<void> {
    const want = this.createStressServiceWant('keepalive');
    markStressServiceStarting();
    try {
      await this.abilityContext.startAppServiceExtensionAbility(want);
      DemoLogger.i(TAG, "Background stress service start requested");
    } catch (error) {
      const errorMessage = this.formatBackgroundServiceStartError(error);
      if (this.isBackgroundServiceCapabilityUnsupported(errorMessage)) {
        markStressServiceUnsupported('start unsupported', errorMessage);
      } else {
        markStressServiceError('start failed', errorMessage);
      }
      throw new Error(errorMessage);
    }
  }

  private formatBackgroundServiceStartError(error: Object): string {
    const rawMessage = `${error}`;
    if (this.isBackgroundServiceCapabilityUnsupported(rawMessage)) {
      return 'Background Service is not supported by this device or HarmonyOS runtime. Disable Background Service and run foreground stress test, or use a runtime that supports AppServiceExtensionAbility.';
    }
    return rawMessage;
  }

  private isBackgroundServiceCapabilityUnsupported(message: string): boolean {
    return message.indexOf('Capability not support') >= 0 ||
      message.indexOf('Capability not supported') >= 0;
  }

  private formatThrowableMessage(error: Object): string {
    const message = `${error}`;
    const errorPrefix = 'Error: ';
    if (message.indexOf(errorPrefix) === 0) {
      return message.substring(errorPrefix.length);
    }
    return message;
  }

  private async stopBackgroundStressService(): Promise<void> {
    const want = this.createStressServiceWant('stop');
    markStressServiceEvent(STRESS_SERVICE_STATE_STOPPING, 'stop requested', -1, 'manual');
    try {
      await this.abilityContext.startAppServiceExtensionAbility(want);
    } catch (error) {
      markStressServiceError('stop command failed', `${error}`);
      DemoLogger.w(TAG, `Background stress service stop command failed: ${error}`);
    }

    try {
      await this.abilityContext.stopAppServiceExtensionAbility(want);
      markStressServiceEvent(STRESS_SERVICE_STATE_STOPPING, 'stopAppServiceExtensionAbility', -1, 'manual');
      DemoLogger.i(TAG, "Background stress service stop requested");
    } catch (error) {
      markStressServiceError('stop ability failed', `${error}`);
      DemoLogger.w(TAG, `Background stress service stop failed: ${error}`);
    }
  }

  private createStressServiceWant(action: string): Want {
    return {
      bundleName: this.abilityContext.abilityInfo.bundleName,
      moduleName: this.abilityContext.abilityInfo.moduleName,
      abilityName: 'StressServiceAbility',
      action
    };
  }

  private async loadSettings(): Promise<void> {
    try {
      this.preferencesStore = await preferences.getPreferences(this.abilityContext, PREFERENCES_NAME);
      if (this.preferencesStore) {
        const savedMinutes = await this.preferencesStore.get(KEY_TEST_MINUTES, 1) as number;
        const savedSeconds = await this.preferencesStore.get(KEY_TEST_SECONDS, 0) as number;

        if (savedMinutes >= 0 && savedSeconds >= 0) {
          this.testMinutes = savedMinutes;
          this.testSeconds = savedSeconds;
          this.updateTestDuration();
          DemoLogger.i(TAG, `Loaded time settings: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        } else {
          DemoLogger.w(TAG, `Invalid saved time settings, using defaults: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        }

        const savedRunMode = await this.preferencesStore.get(KEY_STRESS_RUN_MODE, DEFAULT_STRESS_RUN_MODE) as string;
        this.stressRunMode = savedRunMode === 'total' ? 'total' : 'duration';
        this.stressTotalCount =
          await this.preferencesStore.get(KEY_STRESS_TOTAL_COUNT, DEFAULT_STRESS_TOTAL_COUNT) as number;
        this.useRealTraffic = await this.preferencesStore.get(KEY_USE_REAL_TRAFFIC, false) as boolean;
        this.enableLogs = await this.preferencesStore.get(KEY_ENABLE_LOGS, true) as boolean;
        this.enableActions = await this.preferencesStore.get(KEY_ENABLE_ACTIONS, true) as boolean;
        this.enableResources = await this.preferencesStore.get(KEY_ENABLE_RESOURCES, true) as boolean;
        if (!this.enableResources) {
          this.useRealTraffic = false;
        }
        this.enableNavigation = await this.preferencesStore.get(KEY_ENABLE_NAVIGATION, true) as boolean;
        this.enableErrors = await this.preferencesStore.get(KEY_ENABLE_ERRORS, false) as boolean;
        this.enableLongTasks = await this.preferencesStore.get(KEY_ENABLE_LONG_TASKS, false) as boolean;
        this.enableBackgroundService = await this.preferencesStore.get(KEY_ENABLE_BACKGROUND_SERVICE, false) as boolean;
        const savedRealResourceUrl =
          await this.preferencesStore.get(KEY_REAL_RESOURCE_URL, DEFAULT_REAL_RESOURCE_URL) as string;
        this.realResourceUrls = this.normalizeRealResourceUrlInputs(this.parseRealResourceUrls(savedRealResourceUrl));
        this.stressLogBatchSize =
          await this.preferencesStore.get(KEY_STRESS_LOG_BATCH_SIZE, DEFAULT_STRESS_LOG_BATCH_SIZE) as number;
        this.stressLogIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_LOG_INTERVAL_MS, DEFAULT_STRESS_LOG_INTERVAL_MS) as number;
        this.stressActionTimerCount =
          await this.preferencesStore.get(KEY_STRESS_ACTION_TIMER_COUNT, DEFAULT_STRESS_ACTION_TIMER_COUNT) as number;
        this.stressActionIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_ACTION_INTERVAL_MS, DEFAULT_STRESS_ACTION_INTERVAL_MS) as number;
        this.stressResourceTimerCount =
          await this.preferencesStore.get(KEY_STRESS_RESOURCE_TIMER_COUNT, DEFAULT_STRESS_RESOURCE_TIMER_COUNT) as number;
        this.stressResourceIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_RESOURCE_INTERVAL_MS, DEFAULT_STRESS_RESOURCE_INTERVAL_MS) as number;
        this.stressNavigationIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_NAVIGATION_INTERVAL_MS, DEFAULT_STRESS_NAVIGATION_INTERVAL_MS) as number;
        this.stressErrorBatchSize =
          await this.preferencesStore.get(KEY_STRESS_ERROR_BATCH_SIZE, DEFAULT_STRESS_ERROR_BATCH_SIZE) as number;
        this.stressErrorIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_ERROR_INTERVAL_MS, DEFAULT_STRESS_ERROR_INTERVAL_MS) as number;
        this.stressLongTaskBatchSize =
          await this.preferencesStore.get(KEY_STRESS_LONG_TASK_BATCH_SIZE, DEFAULT_STRESS_LONG_TASK_BATCH_SIZE) as number;
        this.stressLongTaskIntervalMs =
          await this.preferencesStore.get(KEY_STRESS_LONG_TASK_INTERVAL_MS, DEFAULT_STRESS_LONG_TASK_INTERVAL_MS) as number;
        this.normalizeStressLogSettings();
        this.normalizeStressActionSettings();
        this.normalizeStressResourceSettings();
        this.normalizeStressNavigationSettings();
        this.normalizeStressErrorSettings();
        this.normalizeStressLongTaskSettings();
        this.normalizeRunTargetSettings();
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to load settings: ${error}`);
    }
  }

  private async saveSettings(): Promise<void> {
    try {
      if (!this.preferencesStore) {
        this.preferencesStore = await preferences.getPreferences(this.abilityContext, PREFERENCES_NAME);
      }
      if (this.preferencesStore) {
        await this.preferencesStore.put(KEY_TEST_MINUTES, this.testMinutes);
        await this.preferencesStore.put(KEY_TEST_SECONDS, this.testSeconds);
        await this.preferencesStore.put(KEY_STRESS_RUN_MODE, this.stressRunMode);
        await this.preferencesStore.put(KEY_STRESS_TOTAL_COUNT, this.stressTotalCount);
        await this.preferencesStore.put(KEY_USE_REAL_TRAFFIC, this.useRealTraffic);
        await this.preferencesStore.put(KEY_ENABLE_LOGS, this.enableLogs);
        await this.preferencesStore.put(KEY_ENABLE_ACTIONS, this.enableActions);
        await this.preferencesStore.put(KEY_ENABLE_RESOURCES, this.enableResources);
        await this.preferencesStore.put(KEY_ENABLE_NAVIGATION, this.enableNavigation);
        await this.preferencesStore.put(KEY_ENABLE_ERRORS, this.enableErrors);
        await this.preferencesStore.put(KEY_ENABLE_LONG_TASKS, this.enableLongTasks);
        await this.preferencesStore.put(KEY_ENABLE_BACKGROUND_SERVICE, this.enableBackgroundService);
        await this.preferencesStore.put(KEY_REAL_RESOURCE_URL, this.serializeRealResourceUrls());
        await this.preferencesStore.put(KEY_STRESS_LOG_BATCH_SIZE, this.stressLogBatchSize);
        await this.preferencesStore.put(KEY_STRESS_LOG_INTERVAL_MS, this.stressLogIntervalMs);
        await this.preferencesStore.put(KEY_STRESS_ACTION_TIMER_COUNT, this.stressActionTimerCount);
        await this.preferencesStore.put(KEY_STRESS_ACTION_INTERVAL_MS, this.stressActionIntervalMs);
        await this.preferencesStore.put(KEY_STRESS_RESOURCE_TIMER_COUNT, this.stressResourceTimerCount);
        await this.preferencesStore.put(KEY_STRESS_RESOURCE_INTERVAL_MS, this.stressResourceIntervalMs);
        await this.preferencesStore.put(KEY_STRESS_NAVIGATION_INTERVAL_MS, this.stressNavigationIntervalMs);
        await this.preferencesStore.put(KEY_STRESS_ERROR_BATCH_SIZE, this.stressErrorBatchSize);
        await this.preferencesStore.put(KEY_STRESS_ERROR_INTERVAL_MS, this.stressErrorIntervalMs);
        await this.preferencesStore.put(KEY_STRESS_LONG_TASK_BATCH_SIZE, this.stressLongTaskBatchSize);
        await this.preferencesStore.put(KEY_STRESS_LONG_TASK_INTERVAL_MS, this.stressLongTaskIntervalMs);
        await this.preferencesStore.flush();
        DemoLogger.i(TAG, `Saved stress settings: ${this.testMinutes}m ${this.testSeconds}s`);
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to save settings: ${error}`);
    }
  }

  updateTestDuration(): void {
    const newDuration = this.testMinutes * 60 + this.testSeconds;
    if (newDuration !== this.testDuration) {
      DemoLogger.i(TAG, `Test duration updated: ${this.testDuration}s -> ${newDuration}s`);
      this.testDuration = newDuration;
    }
  }

  private normalizeRunTargetSettings(): void {
    if (this.stressRunMode !== 'total') {
      this.stressRunMode = 'duration';
    }
    this.stressTotalCount = this.clampNumber(
      Math.floor(this.stressTotalCount),
      MIN_STRESS_TOTAL_COUNT
    );
    this.syncStressTotalCountInput();
  }

  setStressRunMode(mode: StressRunMode): void {
    if (this.isTestRunning || this.stressRunMode === mode) {
      return;
    }
    this.stressRunMode = mode;
    this.saveSettings();
  }

  private syncStressTotalCountInput(): void {
    this.stressTotalCountInput = `${this.stressTotalCount}`;
  }

  private extractDigits(value: string): string {
    let digits = "";
    for (let i = 0; i < value.length; i++) {
      const char = value.charAt(i);
      if (char >= '0' && char <= '9') {
        digits += char;
      }
    }
    return digits;
  }

  private parseNumberInput(value: string, currentValue: number, minValue: number): number {
    const digits = this.extractDigits(value);
    if (digits.length === 0) {
      return currentValue;
    }

    const parsedValue = Number(digits);
    if (isNaN(parsedValue)) {
      return currentValue;
    }

    return this.clampNumber(Math.floor(parsedValue), minValue);
  }

  updateStressTotalCountInput(value: string): void {
    const digits = this.extractDigits(value);
    this.stressTotalCountInput = digits;
    if (digits.length === 0) {
      return;
    }

    const parsedValue = Number(digits);
    if (isNaN(parsedValue)) {
      return;
    }

    this.stressTotalCount = this.clampNumber(
      Math.floor(parsedValue),
      MIN_STRESS_TOTAL_COUNT
    );
    if (digits !== `${this.stressTotalCount}`) {
      this.syncStressTotalCountInput();
    }
    this.saveSettings();
  }

  updateTestMinutesInput(value: string): void {
    this.testMinutes = this.parseNumberInput(value, this.testMinutes, 0);
    this.updateTestDuration();
    this.saveSettings();
  }

  updateTestSecondsInput(value: string): void {
    this.testSeconds = this.parseNumberInput(value, this.testSeconds, 0);
    this.updateTestDuration();
    this.saveSettings();
  }

  updateStressLogBatchSizeInput(value: string): void {
    this.stressLogBatchSize = this.parseNumberInput(
      value,
      this.stressLogBatchSize,
      MIN_STRESS_LOG_BATCH_SIZE
    );
    this.saveSettings();
  }

  updateStressLogIntervalInput(value: string): void {
    this.stressLogIntervalMs = this.parseNumberInput(
      value,
      this.stressLogIntervalMs,
      MIN_STRESS_LOG_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateStressActionTimerCountInput(value: string): void {
    this.stressActionTimerCount = this.parseNumberInput(
      value,
      this.stressActionTimerCount,
      MIN_STRESS_ACTION_TIMER_COUNT
    );
    this.saveSettings();
  }

  updateStressActionIntervalInput(value: string): void {
    this.stressActionIntervalMs = this.parseNumberInput(
      value,
      this.stressActionIntervalMs,
      MIN_STRESS_ACTION_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateStressResourceTimerCountInput(value: string): void {
    this.stressResourceTimerCount = this.parseNumberInput(
      value,
      this.stressResourceTimerCount,
      MIN_STRESS_RESOURCE_TIMER_COUNT
    );
    this.saveSettings();
  }

  updateStressResourceIntervalInput(value: string): void {
    this.stressResourceIntervalMs = this.parseNumberInput(
      value,
      this.stressResourceIntervalMs,
      MIN_STRESS_RESOURCE_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateStressNavigationIntervalInput(value: string): void {
    this.stressNavigationIntervalMs = this.parseNumberInput(
      value,
      this.stressNavigationIntervalMs,
      MIN_STRESS_NAVIGATION_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateStressErrorBatchSizeInput(value: string): void {
    this.stressErrorBatchSize = this.parseNumberInput(
      value,
      this.stressErrorBatchSize,
      MIN_STRESS_ERROR_BATCH_SIZE
    );
    this.saveSettings();
  }

  updateStressErrorIntervalInput(value: string): void {
    this.stressErrorIntervalMs = this.parseNumberInput(
      value,
      this.stressErrorIntervalMs,
      MIN_STRESS_ERROR_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateStressLongTaskBatchSizeInput(value: string): void {
    this.stressLongTaskBatchSize = this.parseNumberInput(
      value,
      this.stressLongTaskBatchSize,
      MIN_STRESS_LONG_TASK_BATCH_SIZE
    );
    this.saveSettings();
  }

  updateStressLongTaskIntervalInput(value: string): void {
    this.stressLongTaskIntervalMs = this.parseNumberInput(
      value,
      this.stressLongTaskIntervalMs,
      MIN_STRESS_LONG_TASK_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustMinutes(delta: number): void {
    const newMinutes = this.testMinutes + delta;
    if (newMinutes >= 0) {
      this.testMinutes = newMinutes;
      this.updateTestDuration();
      this.saveSettings();
    }
  }

  adjustSeconds(delta: number): void {
    const newSeconds = this.testSeconds + delta;
    if (newSeconds >= 0) {
      this.testSeconds = newSeconds;
      this.updateTestDuration();
      this.saveSettings();
    } else if (newSeconds < 0 && this.testMinutes > 0) {
      this.testMinutes -= 1;
      this.testSeconds = 60 + newSeconds;
      this.updateTestDuration();
      this.saveSettings();
    }
  }

  adjustStressTotalCount(delta: number): void {
    this.stressTotalCount = this.clampNumber(
      this.stressTotalCount + delta,
      MIN_STRESS_TOTAL_COUNT
    );
    this.syncStressTotalCountInput();
    this.saveSettings();
  }

  private normalizeStressLogSettings(): void {
    this.stressLogBatchSize = this.clampNumber(
      Math.floor(this.stressLogBatchSize),
      MIN_STRESS_LOG_BATCH_SIZE
    );
    this.stressLogIntervalMs = this.clampNumber(
      Math.floor(this.stressLogIntervalMs),
      MIN_STRESS_LOG_INTERVAL_MS
    );
  }

  private normalizeStressActionSettings(): void {
    this.stressActionTimerCount = this.clampNumber(
      Math.floor(this.stressActionTimerCount),
      MIN_STRESS_ACTION_TIMER_COUNT
    );
    this.stressActionIntervalMs = this.clampNumber(
      Math.floor(this.stressActionIntervalMs),
      MIN_STRESS_ACTION_INTERVAL_MS
    );
  }

  private normalizeStressResourceSettings(): void {
    this.stressResourceTimerCount = this.clampNumber(
      Math.floor(this.stressResourceTimerCount),
      MIN_STRESS_RESOURCE_TIMER_COUNT
    );
    this.stressResourceIntervalMs = this.clampNumber(
      Math.floor(this.stressResourceIntervalMs),
      MIN_STRESS_RESOURCE_INTERVAL_MS
    );
  }

  private normalizeStressNavigationSettings(): void {
    this.stressNavigationIntervalMs = this.clampNumber(
      Math.floor(this.stressNavigationIntervalMs),
      MIN_STRESS_NAVIGATION_INTERVAL_MS
    );
  }

  private normalizeStressErrorSettings(): void {
    this.stressErrorBatchSize = this.clampNumber(
      Math.floor(this.stressErrorBatchSize),
      MIN_STRESS_ERROR_BATCH_SIZE
    );
    this.stressErrorIntervalMs = this.clampNumber(
      Math.floor(this.stressErrorIntervalMs),
      MIN_STRESS_ERROR_INTERVAL_MS
    );
  }

  private normalizeStressLongTaskSettings(): void {
    this.stressLongTaskBatchSize = this.clampNumber(
      Math.floor(this.stressLongTaskBatchSize),
      MIN_STRESS_LONG_TASK_BATCH_SIZE
    );
    this.stressLongTaskIntervalMs = this.clampNumber(
      Math.floor(this.stressLongTaskIntervalMs),
      MIN_STRESS_LONG_TASK_INTERVAL_MS
    );
  }

  private parseRealResourceUrls(rawUrls: string): string[] {
    const urls: string[] = [];
    let url = "";
    for (let i = 0; i < rawUrls.length; i++) {
      const char = rawUrls.charAt(i);
      if (char === '\n' || char === '\r' || char === ',' || char === ';') {
        this.appendRealResourceUrl(urls, url);
        url = "";
      } else {
        url += char;
      }
    }
    this.appendRealResourceUrl(urls, url);
    return urls;
  }

  private appendRealResourceUrl(urls: string[], rawUrl: string): void {
    const trimmedUrl = rawUrl.trim();
    if (trimmedUrl.length > 0) {
      urls.push(trimmedUrl);
    }
  }

  private normalizeRealResourceUrlInputs(urls: string[]): string[] {
    const normalizedUrls = urls.slice();
    return normalizedUrls.length > 0 ? normalizedUrls : [DEFAULT_REAL_RESOURCE_URL];
  }

  private serializeRealResourceUrls(): string {
    const urls: string[] = [];
    for (let i = 0; i < this.realResourceUrls.length; i++) {
      this.appendRealResourceUrl(urls, this.realResourceUrls[i]);
    }
    return urls.join('\n');
  }

  private formatRealResourceUrlSummary(rawUrls: string): string {
    const urlCount = this.parseRealResourceUrls(rawUrls).length;
    return urlCount > 0 ? `${urlCount} configured` : 'traceUrl/default';
  }

  private clampNumber(value: number, minValue: number): number {
    if (value < minValue) {
      return minValue;
    }
    return value;
  }

  resetRunTargetSettings(): void {
    this.stressRunMode = DEFAULT_STRESS_RUN_MODE;
    this.stressTotalCount = DEFAULT_STRESS_TOTAL_COUNT;
    this.syncStressTotalCountInput();
    this.testMinutes = DEFAULT_TEST_MINUTES;
    this.testSeconds = DEFAULT_TEST_SECONDS;
    this.updateTestDuration();
    this.saveSettings();
  }

  resetStressLogSettings(): void {
    this.stressLogBatchSize = DEFAULT_STRESS_LOG_BATCH_SIZE;
    this.stressLogIntervalMs = DEFAULT_STRESS_LOG_INTERVAL_MS;
    this.saveSettings();
  }

  resetStressActionSettings(): void {
    this.stressActionTimerCount = DEFAULT_STRESS_ACTION_TIMER_COUNT;
    this.stressActionIntervalMs = DEFAULT_STRESS_ACTION_INTERVAL_MS;
    this.saveSettings();
  }

  resetStressResourceSettings(): void {
    this.useRealTraffic = false;
    this.realResourceUrls = [DEFAULT_REAL_RESOURCE_URL];
    this.stressResourceTimerCount = DEFAULT_STRESS_RESOURCE_TIMER_COUNT;
    this.stressResourceIntervalMs = DEFAULT_STRESS_RESOURCE_INTERVAL_MS;
    this.saveSettings();
  }

  resetStressNavigationSettings(): void {
    this.stressNavigationIntervalMs = DEFAULT_STRESS_NAVIGATION_INTERVAL_MS;
    this.saveSettings();
  }

  resetStressErrorSettings(): void {
    this.stressErrorBatchSize = DEFAULT_STRESS_ERROR_BATCH_SIZE;
    this.stressErrorIntervalMs = DEFAULT_STRESS_ERROR_INTERVAL_MS;
    this.saveSettings();
  }

  resetStressLongTaskSettings(): void {
    this.stressLongTaskBatchSize = DEFAULT_STRESS_LONG_TASK_BATCH_SIZE;
    this.stressLongTaskIntervalMs = DEFAULT_STRESS_LONG_TASK_INTERVAL_MS;
    this.saveSettings();
  }

  resetBackgroundServiceSettings(): void {
    this.enableBackgroundService = false;
    resetStressServiceStatus();
    this.saveSettings();
  }

  adjustStressLogBatchSize(delta: number): void {
    this.stressLogBatchSize = this.clampNumber(
      this.stressLogBatchSize + delta,
      MIN_STRESS_LOG_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressLogInterval(delta: number): void {
    this.stressLogIntervalMs = this.clampNumber(
      this.stressLogIntervalMs + delta,
      MIN_STRESS_LOG_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressActionTimerCount(delta: number): void {
    this.stressActionTimerCount = this.clampNumber(
      this.stressActionTimerCount + delta,
      MIN_STRESS_ACTION_TIMER_COUNT
    );
    this.saveSettings();
  }

  adjustStressActionInterval(delta: number): void {
    this.stressActionIntervalMs = this.clampNumber(
      this.stressActionIntervalMs + delta,
      MIN_STRESS_ACTION_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressResourceTimerCount(delta: number): void {
    this.stressResourceTimerCount = this.clampNumber(
      this.stressResourceTimerCount + delta,
      MIN_STRESS_RESOURCE_TIMER_COUNT
    );
    this.saveSettings();
  }

  adjustStressResourceInterval(delta: number): void {
    this.stressResourceIntervalMs = this.clampNumber(
      this.stressResourceIntervalMs + delta,
      MIN_STRESS_RESOURCE_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressNavigationInterval(delta: number): void {
    this.stressNavigationIntervalMs = this.clampNumber(
      this.stressNavigationIntervalMs + delta,
      MIN_STRESS_NAVIGATION_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressErrorBatchSize(delta: number): void {
    this.stressErrorBatchSize = this.clampNumber(
      this.stressErrorBatchSize + delta,
      MIN_STRESS_ERROR_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressErrorInterval(delta: number): void {
    this.stressErrorIntervalMs = this.clampNumber(
      this.stressErrorIntervalMs + delta,
      MIN_STRESS_ERROR_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressLongTaskBatchSize(delta: number): void {
    this.stressLongTaskBatchSize = this.clampNumber(
      this.stressLongTaskBatchSize + delta,
      MIN_STRESS_LONG_TASK_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressLongTaskInterval(delta: number): void {
    this.stressLongTaskIntervalMs = this.clampNumber(
      this.stressLongTaskIntervalMs + delta,
      MIN_STRESS_LONG_TASK_INTERVAL_MS
    );
    this.saveSettings();
  }

  updateRealResourceUrl(index: number, value: string): void {
    const urls = this.realResourceUrls.slice();
    if (index < 0 || index >= urls.length) {
      return;
    }
    urls[index] = value;
    this.realResourceUrls = urls;
    this.saveSettings();
  }

  addRealResourceUrl(): void {
    const urls = this.realResourceUrls.slice();
    urls.push(DEFAULT_REAL_RESOURCE_URL);
    this.realResourceUrls = urls;
    this.saveSettings();
  }

  removeRealResourceUrl(index: number): void {
    const urls = this.realResourceUrls.slice();
    if (index < 0 || index >= urls.length) {
      return;
    }
    urls.splice(index, 1);
    this.realResourceUrls = urls.length > 0 ? urls : [DEFAULT_REAL_RESOURCE_URL];
    this.saveSettings();
  }

  formatElapsedTime(seconds: number): string {
    if (seconds <= 0) {
      return "0s";
    }
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;

    if (minutes > 0 && remainingSeconds > 0) {
      return `${minutes} min ${remainingSeconds} s`;
    } else if (minutes > 0) {
      return `${minutes} min`;
    } else {
      return `${remainingSeconds} s`;
    }
  }

  private formatScenarioSummary(stats: StressTestStats): string {
    const scenarios: string[] = [];
    if (stats.enableLogs) {
      scenarios.push("Logs");
    }
    if (stats.enableActions) {
      scenarios.push("Actions");
    }
    if (stats.enableResources) {
      scenarios.push("Resources");
    }
    if (stats.enableNavigation) {
      scenarios.push("Navigation");
    }
    if (stats.enableErrors) {
      scenarios.push("Errors");
    }
    if (stats.enableLongTasks) {
      scenarios.push("LongTasks");
    }
    return scenarios.length > 0 ? scenarios.join(", ") : "None";
  }

  private formatConfiguredScenarioSummary(): string {
    const scenarios: string[] = [];
    if (this.enableLogs) {
      scenarios.push("Logs");
    }
    if (this.enableActions) {
      scenarios.push("Actions");
    }
    if (this.enableResources) {
      scenarios.push("Resources");
    }
    if (this.enableNavigation) {
      scenarios.push("Navigation");
    }
    if (this.enableErrors) {
      scenarios.push("Errors");
    }
    if (this.enableLongTasks) {
      scenarios.push("LongTasks");
    }
    return scenarios.length > 0 ? scenarios.join(", ") : "None";
  }

  private formatRealtimeScenarioSummary(): string {
    return this.hasStatsRun() ? this.formatScenarioSummary(this.stats) : this.formatConfiguredScenarioSummary();
  }

  private formatRealtimeSource(): string {
    if (this.hasStatsRun()) {
      return this.stats.source;
    }
    return this.enableBackgroundService ? 'background-service' : 'foreground';
  }

  private shouldShowBackgroundServiceDetails(): boolean {
    return this.enableBackgroundService ||
      this.backgroundServiceState !== STRESS_SERVICE_STATE_IDLE ||
      this.stats.source === 'background-service';
  }

  private formatBackgroundServiceState(): string {
    switch (this.backgroundServiceState) {
      case STRESS_SERVICE_STATE_STARTING:
        return 'Starting';
      case STRESS_SERVICE_STATE_STARTED:
        return 'Started';
      case STRESS_SERVICE_STATE_KEEPALIVE:
        return 'Keepalive';
      case STRESS_SERVICE_STATE_STOPPING:
        return 'Stopping';
      case STRESS_SERVICE_STATE_STOPPED:
        return 'Stopped';
      case STRESS_SERVICE_STATE_DESTROYED:
        return 'Destroyed';
      case STRESS_SERVICE_STATE_UNSUPPORTED:
        return 'Unsupported';
      case STRESS_SERVICE_STATE_ERROR:
        return 'Error';
      default:
        return 'Idle';
    }
  }

  private getBackgroundServiceStateColor(): string {
    switch (this.backgroundServiceState) {
      case STRESS_SERVICE_STATE_STARTED:
      case STRESS_SERVICE_STATE_KEEPALIVE:
        return '#00A870';
      case STRESS_SERVICE_STATE_STARTING:
      case STRESS_SERVICE_STATE_STOPPING:
        return '#D46B08';
      case STRESS_SERVICE_STATE_STOPPED:
      case STRESS_SERVICE_STATE_DESTROYED:
        return '#576B95';
      case STRESS_SERVICE_STATE_UNSUPPORTED:
      case STRESS_SERVICE_STATE_ERROR:
        return '#F53F3F';
      default:
        return '#86909C';
    }
  }

  private formatBackgroundServiceEventTime(): string {
    if (this.backgroundServiceLastEventTimeMs <= 0) {
      return 'Never';
    }
    return new Date(this.backgroundServiceLastEventTimeMs).toLocaleTimeString();
  }

  private formatBackgroundServiceStartId(): string {
    return this.backgroundServiceStartId >= 0 ? `${this.backgroundServiceStartId}` : 'N/A';
  }

  private formatBackgroundServiceStopReason(): string {
    return this.backgroundServiceStopReason.length > 0 ? this.backgroundServiceStopReason : 'none';
  }

  private formatBackgroundServiceLastError(): string {
    return this.backgroundServiceLastError.length > 0 ? this.backgroundServiceLastError : 'none';
  }

  private formatRealtimeTrafficMode(): string {
    if (this.hasStatsRun()) {
      return this.stats.trafficMode;
    }
    return this.enableResources && this.useRealTraffic ? 'real' : 'fake';
  }

  private formatRealtimeRunMode(): string {
    const mode = this.getRealtimeRunMode();
    return mode === 'total' ? 'Total Count' : 'Duration';
  }

  private getRealtimeRunMode(): StressRunMode {
    if (this.hasStatsRun()) {
      return this.stats.runMode;
    }
    return this.stressRunMode;
  }

  private isRealtimeTotalMode(): boolean {
    return this.getRealtimeRunMode() === 'total';
  }

  private getRealtimeTotalTargetCount(): number {
    if (this.hasStatsRun() && this.stats.totalTargetCount > 0) {
      return this.stats.totalTargetCount;
    }
    return this.stressTotalCount;
  }

  private formatRunTargetForToast(): string {
    if (this.stressRunMode === 'total') {
      return `${this.stressTotalCount} per enabled feature`;
    }
    return this.formatElapsedTime(this.testDuration);
  }

  private formatRunTargetSummary(): string {
    if (this.stressRunMode === 'total') {
      return `target ${this.stressTotalCount} per enabled feature`;
    }
    return `duration ${this.formatElapsedTime(this.testDuration)}`;
  }

  private hasStatsRun(): boolean {
    return this.stats.isRunning || this.stats.startedAtMs > 0 || this.stats.endedAtMs > 0;
  }

  private shouldShowLogStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableLogs : this.enableLogs;
  }

  private shouldShowActionStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableActions : this.enableActions;
  }

  private shouldShowResourceStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableResources : this.enableResources;
  }

  private shouldShowNavigationStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableNavigation : this.enableNavigation;
  }

  private shouldShowErrorStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableErrors : this.enableErrors;
  }

  private shouldShowLongTaskStats(): boolean {
    return this.hasStatsRun() ? this.stats.enableLongTasks : this.enableLongTasks;
  }

  private getExpectedDurationSeconds(): number {
    return this.stats.durationSeconds > 0 ? this.stats.durationSeconds : this.testDuration;
  }

  private formatExpectedTimedResult(
    unit: string,
    perInterval: number,
    intervalMs: number
  ): string {
    const safePerInterval = Math.max(1, Math.floor(perInterval));
    const safeIntervalMs = Math.max(1, Math.floor(intervalMs));
    const durationSeconds = this.getExpectedDurationSeconds();
    if (this.isRealtimeTotalMode()) {
      return `${this.getRealtimeTotalTargetCount()} ${unit}`;
    }
    if (durationSeconds <= 0) {
      return `${safePerInterval}/${safeIntervalMs}ms until stopped`;
    }

    const intervalCount = Math.floor((durationSeconds * 1000) / safeIntervalMs);
    const expectedCount = intervalCount * safePerInterval;
    return `~${expectedCount} ${unit}`;
  }

  private formatRateValue(rate: number): string {
    if (rate >= 100) {
      return Math.round(rate).toString();
    }
    if (rate >= 10) {
      return (Math.round(rate * 10) / 10).toString();
    }
    return (Math.round(rate * 100) / 100).toString();
  }

  private formatExpectedRate(perInterval: number, intervalMs: number, unit: string): string {
    const safePerInterval = Math.max(1, Math.floor(perInterval));
    const safeIntervalMs = Math.max(1, Math.floor(intervalMs));
    return `~${this.formatRateValue((safePerInterval * 1000) / safeIntervalMs)} ${unit}/s`;
  }

  private getSdkLaneConcurrency(laneName: string, fallback: number): number {
    try {
      const status = SDKTaskScheduler.getInstance().getStatus();
      const lane = status.lanes[laneName];
      if (lane !== undefined && lane.maxConcurrency > 0) {
        return lane.maxConcurrency;
      }
    } catch (error) {
      DemoLogger.w(TAG, `Failed to read SDK lane status for ${laneName}: ${error}`);
    }
    return fallback;
  }

  private getSdkLaneAverageCostMs(laneName: string, fallback: number): number {
    try {
      const status = SDKTaskScheduler.getInstance().getStatus();
      const lane = status.lanes[laneName];
      if (lane !== undefined && lane.averageCostTime > 0) {
        return lane.averageCostTime;
      }
    } catch (error) {
      DemoLogger.w(TAG, `Failed to read SDK lane cost for ${laneName}: ${error}`);
    }
    return fallback;
  }

  private estimateSdkLaneRate(laneName: string, fallbackConcurrency: number, fallbackCostMs: number): number {
    const concurrency = this.getSdkLaneConcurrency(laneName, fallbackConcurrency);
    const costMs = Math.max(1, this.getSdkLaneAverageCostMs(laneName, fallbackCostMs));
    return (concurrency * 1000) / costMs;
  }

  private estimateRumSdkRate(): number {
    const eventRate = this.estimateSdkLaneRate(SDK_EVENT_LANE, 1, DEFAULT_SDK_EVENT_COST_MS);
    const dataRate = this.estimateSdkLaneRate(SDK_DATA_PROCESS_LANE, 2, DEFAULT_SDK_DATA_PROCESS_COST_MS);
    return Math.min(eventRate, dataRate);
  }

  private formatLaneCostMs(laneName: string, fallback: number): string {
    return this.formatRateValue(this.getSdkLaneAverageCostMs(laneName, fallback));
  }

  private formatSdkCapacityPeak(capacitySummary: string, capacityDetail: string): string {
    return `${capacitySummary}\n${capacityDetail}`;
  }

  private formatLogSdkCapacityPeak(): string {
    const logLaneConcurrency = this.getSdkLaneConcurrency(SDK_LOG_LANE, 1);
    const dataLaneConcurrency = this.getSdkLaneConcurrency(SDK_DATA_PROCESS_LANE, 2);
    const estimatedRate =
      (SDK_LOG_FLUSH_BATCH_SIZE * logLaneConcurrency * 1000) / SDK_LOG_PROCESS_COALESCE_MS;
    return this.formatSdkCapacityPeak(
      `~${this.formatRateValue(estimatedRate)} log/s`,
      `LOG x${logLaneConcurrency} / DATA x${dataLaneConcurrency}\nbatch ${SDK_LOG_FLUSH_BATCH_SIZE}/${SDK_LOG_PROCESS_COALESCE_MS}ms, upload ${SDK_SYNC_PAGE_SIZE}`
    );
  }

  private formatRumSdkCapacityPeak(unit: string, prefix: string = 'EVENT'): string {
    const eventLaneConcurrency = this.getSdkLaneConcurrency(SDK_EVENT_LANE, 1);
    const dataLaneConcurrency = this.getSdkLaneConcurrency(SDK_DATA_PROCESS_LANE, 2);
    return this.formatSdkCapacityPeak(
      `~${this.formatRateValue(this.estimateRumSdkRate())} ${unit}/s`,
      `${prefix} x${eventLaneConcurrency} avg~${this.formatLaneCostMs(SDK_EVENT_LANE, DEFAULT_SDK_EVENT_COST_MS)}ms\nDATA x${dataLaneConcurrency} avg~${this.formatLaneCostMs(SDK_DATA_PROCESS_LANE, DEFAULT_SDK_DATA_PROCESS_COST_MS)}ms, upload ${SDK_SYNC_PAGE_SIZE}`
    );
  }

  private formatActualRate(count: number, unit: string): string {
    const elapsedSeconds = this.stats.elapsedSeconds > 0 ? this.stats.elapsedSeconds : 1;
    return `${this.formatRateValue(count / elapsedSeconds)} ${unit}/s`;
  }

  private formatRealtimeRate(count: number, unit: string, expectedRate: string): string {
    return this.hasStatsRun() ? this.formatActualRate(count, unit) : expectedRate;
  }

  private formatExpectedLogResult(): string {
    return this.formatExpectedTimedResult('logs', this.stressLogBatchSize, this.stressLogIntervalMs);
  }

  private formatExpectedLogRate(): string {
    return this.formatExpectedRate(this.stressLogBatchSize, this.stressLogIntervalMs, 'log');
  }

  private formatMaxLogPeak(): string {
    return this.formatLogSdkCapacityPeak();
  }

  private formatExpectedActionResult(): string {
    return this.formatExpectedTimedResult('actions', this.stressActionTimerCount, this.stressActionIntervalMs);
  }

  private formatExpectedActionRate(): string {
    return this.formatExpectedRate(this.stressActionTimerCount, this.stressActionIntervalMs, 'action');
  }

  private formatMaxActionPeak(): string {
    return this.formatRumSdkCapacityPeak('action');
  }

  private formatExpectedResourceResult(): string {
    return this.formatExpectedTimedResult('resources', this.stressResourceTimerCount, this.stressResourceIntervalMs);
  }

  private formatExpectedResourceRate(): string {
    return this.formatExpectedRate(this.stressResourceTimerCount, this.stressResourceIntervalMs, 'resource');
  }

  private formatMaxResourcePeak(): string {
    return this.formatRumSdkCapacityPeak(
      'resource',
      this.formatRealtimeTrafficMode() === 'real' ? 'network + EVENT' : 'EVENT'
    );
  }

  private formatExpectedNavigationResult(): string {
    return this.formatExpectedTimedResult('switches', 1, this.stressNavigationIntervalMs);
  }

  private formatExpectedNavigationRate(): string {
    return this.formatExpectedRate(1, this.stressNavigationIntervalMs, 'switch');
  }

  private formatMaxNavigationPeak(): string {
    return this.formatSdkCapacityPeak(
      `~${this.formatRateValue(1000 / MIN_STRESS_NAVIGATION_INTERVAL_MS)} switch/s`,
      `router timer min ${MIN_STRESS_NAVIGATION_INTERVAL_MS}ms\nforeground only`
    );
  }

  private formatExpectedErrorResult(): string {
    return this.formatExpectedTimedResult('errors', this.stressErrorBatchSize, this.stressErrorIntervalMs);
  }

  private formatExpectedErrorRate(): string {
    return this.formatExpectedRate(this.stressErrorBatchSize, this.stressErrorIntervalMs, 'error');
  }

  private formatMaxErrorPeak(): string {
    return this.formatRumSdkCapacityPeak('error');
  }

  private formatExpectedLongTaskResult(): string {
    return this.formatExpectedTimedResult('long tasks', this.stressLongTaskBatchSize, this.stressLongTaskIntervalMs);
  }

  private formatExpectedLongTaskRate(): string {
    return this.formatExpectedRate(this.stressLongTaskBatchSize, this.stressLongTaskIntervalMs, 'long task');
  }

  private formatMaxLongTaskPeak(): string {
    return this.formatRumSdkCapacityPeak('long task');
  }

  private formatActualLogResult(): string {
    return `${this.stats.logsGenerated} logs / ${this.stats.logBatchesGenerated} batches`;
  }

  private formatActualResourceResult(): string {
    return `${this.stats.resourcesGenerated} total / ${this.stats.resourcesSucceeded} OK / ${this.stats.resourcesFailed} fail`;
  }

  build() {
    Column() {
      TestPageHeader({
        title: 'Real App Stress Test'
      })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 10 }) {
            Text('Stress Run Target')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 8 })

            Row({ space: 10 }) {
              Button('By Duration')
                .onClick(() => this.setStressRunMode('duration'))
                .height(44)
                .fontSize(14)
                .backgroundColor(this.stressRunMode === 'duration' ? '#007DFF' : '#EAF3FF')
                .fontColor(this.stressRunMode === 'duration' ? Color.White : '#007DFF')
                .enabled(!this.isTestRunning)
                .layoutWeight(1)

              Button('By Total Count')
                .onClick(() => this.setStressRunMode('total'))
                .height(44)
                .fontSize(14)
                .backgroundColor(this.stressRunMode === 'total' ? '#007DFF' : '#EAF3FF')
                .fontColor(this.stressRunMode === 'total' ? Color.White : '#007DFF')
                .enabled(!this.isTestRunning)
                .layoutWeight(1)
            }
            .width('100%')

            if (this.stressRunMode === 'duration') {
              Column({ space: 5 }) {
                Text('Duration Minutes')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Row({ space: 8 }) {
                  Button('-')
                    .onClick(() => this.adjustMinutes(-1))
                    .width(56)
                    .height(44)
                    .enabled(!this.isTestRunning && this.testMinutes > 0)

                  TextInput({
                    placeholder: `${DEFAULT_TEST_MINUTES}`,
                    text: `${this.testMinutes}`
                  })
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .width(112)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(6)
                    .type(InputType.Number)
                    .enabled(!this.isTestRunning)
                    .onChange((value: string) => {
                      this.updateTestMinutesInput(value);
                    })

                  Button('+')
                    .onClick(() => this.adjustMinutes(1))
                    .width(56)
                    .height(44)
                    .enabled(!this.isTestRunning)
                }
                .justifyContent(FlexAlign.Center)
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            if (this.stressRunMode === 'duration') {
              Column({ space: 5 }) {
                Text('Duration Seconds')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Row({ space: 8 }) {
                  Button('-')
                    .onClick(() => this.adjustSeconds(-1))
                    .width(56)
                    .height(44)
                    .enabled(!this.isTestRunning && (this.testSeconds > 0 || this.testMinutes > 0))

                  TextInput({
                    placeholder: `${DEFAULT_TEST_SECONDS}`,
                    text: `${this.testSeconds}`
                  })
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .width(112)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(6)
                    .type(InputType.Number)
                    .enabled(!this.isTestRunning)
                    .onChange((value: string) => {
                      this.updateTestSecondsInput(value);
                    })

                  Button('+')
                    .onClick(() => this.adjustSeconds(1))
                    .width(56)
                    .height(44)
                    .enabled(!this.isTestRunning)
                }
                .justifyContent(FlexAlign.Center)
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            if (this.stressRunMode === 'total') {
              Column({ space: 5 }) {
                Text('Total Count Per Enabled Feature')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                Row({ space: 8 }) {
                  Button('-100')
                    .onClick(() => this.adjustStressTotalCount(-100))
                    .width(64)
                    .height(44)
                    .enabled(!this.isTestRunning && this.stressTotalCount > MIN_STRESS_TOTAL_COUNT)

                  TextInput({
                    placeholder: `${DEFAULT_STRESS_TOTAL_COUNT}`,
                    text: this.stressTotalCountInput
                  })
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .width(112)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(6)
                    .type(InputType.Number)
                    .enabled(!this.isTestRunning)
                    .onChange((value: string) => {
                      this.updateStressTotalCountInput(value);
                    })

                  Button('+100')
                    .onClick(() => this.adjustStressTotalCount(100))
                    .width(64)
                    .height(44)
                    .enabled(!this.isTestRunning)
                }
                .justifyContent(FlexAlign.Center)
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            Text(this.stressRunMode === 'total' ?
              `Total mode: ${this.stressTotalCount} per enabled feature` :
              `Duration mode: ${this.formatElapsedTime(this.testDuration)}`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#007DFF')
              .margin({ top: 6 })

            Button('Reset')
              .onClick(() => this.resetRunTargetSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Scenario Switches')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Row() {
              Toggle({ type: 0, isOn: this.enableLogs })
                .onChange((isOn: boolean) => {
                  this.enableLogs = isOn;
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Logs')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableActions })
                .onChange((isOn: boolean) => {
                  this.enableActions = isOn;
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('RUM Actions')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableResources })
                .onChange((isOn: boolean) => {
                  this.enableResources = isOn;
                  if (!isOn) {
                    this.useRealTraffic = false;
                  }
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Resources')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableLongTasks })
                .onChange((isOn: boolean) => {
                  this.enableLongTasks = isOn;
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Long Tasks')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableErrors })
                .onChange((isOn: boolean) => {
                  this.enableErrors = isOn;
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Custom Errors')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableNavigation })
                .onChange((isOn: boolean) => {
                  this.enableNavigation = isOn;
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Auto Navigation')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')

            Row() {
              Toggle({ type: 0, isOn: this.enableBackgroundService })
                .onChange((isOn: boolean) => {
                  this.enableBackgroundService = isOn;
                  if (!isOn) {
                    resetStressServiceStatus();
                  }
                  this.saveSettings();
                })
                .enabled(!this.isTestRunning)
              Text('Background Service')
                .fontSize(16)
                .margin({ left: 12 })
            }
            .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          if (this.enableNavigation) {
            Column({ space: 10 }) {
              Text('Auto Navigation Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Switch Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-250')
                  .onClick(() => this.adjustStressNavigationInterval(-250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressNavigationIntervalMs > MIN_STRESS_NAVIGATION_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_NAVIGATION_INTERVAL_MS}`,
                  text: `${this.stressNavigationIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressNavigationIntervalInput(value);
                  })

                Button('+250')
                  .onClick(() => this.adjustStressNavigationInterval(250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: switch page every ${this.stressNavigationIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressNavigationSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.enableLogs) {
            Column({ space: 10 }) {
              Text('Log Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-1')
                  .onClick(() => this.adjustStressLogBatchSize(-1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogBatchSize > MIN_STRESS_LOG_BATCH_SIZE)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_LOG_BATCH_SIZE}`,
                  text: `${this.stressLogBatchSize}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressLogBatchSizeInput(value);
                  })

                Button('+1')
                  .onClick(() => this.adjustStressLogBatchSize(1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-10')
                  .onClick(() => this.adjustStressLogInterval(-10))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogIntervalMs > MIN_STRESS_LOG_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_LOG_INTERVAL_MS}`,
                  text: `${this.stressLogIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressLogIntervalInput(value);
                  })

                Button('+10')
                  .onClick(() => this.adjustStressLogInterval(10))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: ${this.stressLogBatchSize} logs per ${this.stressLogIntervalMs}ms, ${this.formatRunTargetSummary()}`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressLogSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.enableActions) {
            Column({ space: 10 }) {
              Text('RUM Action Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Timer Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-1')
                  .onClick(() => this.adjustStressActionTimerCount(-1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionTimerCount > MIN_STRESS_ACTION_TIMER_COUNT)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_ACTION_TIMER_COUNT}`,
                  text: `${this.stressActionTimerCount}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressActionTimerCountInput(value);
                  })

                Button('+1')
                  .onClick(() => this.adjustStressActionTimerCount(1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-10')
                  .onClick(() => this.adjustStressActionInterval(-10))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionIntervalMs > MIN_STRESS_ACTION_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_ACTION_INTERVAL_MS}`,
                  text: `${this.stressActionIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressActionIntervalInput(value);
                  })

                Button('+10')
                  .onClick(() => this.adjustStressActionInterval(10))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: ${this.stressActionTimerCount} timers, action every ${this.stressActionIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressActionSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.enableResources) {
            Column({ space: 10 }) {
              Text('Resource Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 8 }) {
              Text('Resource Traffic Mode')
                .fontSize(14)
                .fontColor(Color.Gray)

              Row() {
                Toggle({ type: 0, isOn: this.useRealTraffic })
                  .onChange((isOn: boolean) => {
                    this.useRealTraffic = isOn;
                    this.saveSettings();
                  })
                  .enabled(!this.isTestRunning)
                Column({ space: 4 }) {
                  Text(this.useRealTraffic ? 'Real RCP Resource Traffic' : 'Synthetic Resource Traffic')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                  Text(this.useRealTraffic ? 'RCP GET requests from Resource URLs' : 'Local Resource timing data')
                    .fontSize(12)
                    .fontColor(Color.Gray)
                }
                .margin({ left: 12 })
                .layoutWeight(1)
              }
              .width('100%')
            }
            .width('100%')

            if (this.useRealTraffic) {
              Column({ space: 6 }) {
                Text('Resource Real Traffic URLs')
                  .fontSize(14)
                  .fontColor(Color.Gray)

                ForEach(this.realResourceUrls, (url: string, index: number) => {
                  Row({ space: 8 }) {
                    TextInput({
                      placeholder: index === 0 ? DEFAULT_REAL_TRAFFIC_URL : 'https://example.com/resource',
                      text: url
                    })
                      .height(44)
                      .layoutWeight(1)
                      .fontSize(13)
                      .backgroundColor('#F5F5F5')
                      .borderRadius(6)
                      .enabled(!this.isTestRunning)
                      .onChange((value: string) => {
                        this.updateRealResourceUrl(index, value);
                      })

                    Button('-')
                      .width(44)
                      .height(44)
                      .enabled(!this.isTestRunning && this.realResourceUrls.length > 1)
                      .onClick(() => {
                        this.removeRealResourceUrl(index);
                      })
                  }
                  .width('100%')
                }, (url: string, index: number) => `${index}`)

                Button('Add Resource URL')
                  .height(40)
                  .width('100%')
                  .enabled(!this.isTestRunning)
                  .onClick(() => {
                    this.addRealResourceUrl();
                  })

                Text(this.serializeRealResourceUrls().length > 0 ?
                  'Resource URL mapping: urls[N % urls.length]' :
                  'Resource URL fallback: launch traceUrl/default')
                  .fontSize(12)
                  .fontColor(Color.Gray)
              }
              .width('100%')
            }

            Column({ space: 5 }) {
              Text('Timer Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-1')
                  .onClick(() => this.adjustStressResourceTimerCount(-1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceTimerCount > MIN_STRESS_RESOURCE_TIMER_COUNT)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_RESOURCE_TIMER_COUNT}`,
                  text: `${this.stressResourceTimerCount}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressResourceTimerCountInput(value);
                  })

                Button('+1')
                  .onClick(() => this.adjustStressResourceTimerCount(1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-50')
                  .onClick(() => this.adjustStressResourceInterval(-50))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceIntervalMs > MIN_STRESS_RESOURCE_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_RESOURCE_INTERVAL_MS}`,
                  text: `${this.stressResourceIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressResourceIntervalInput(value);
                  })

                Button('+50')
                  .onClick(() => this.adjustStressResourceInterval(50))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: ${this.stressResourceTimerCount} timers, resource every ${this.stressResourceIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressResourceSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.enableErrors) {
            Column({ space: 10 }) {
              Text('Custom Error Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-1')
                  .onClick(() => this.adjustStressErrorBatchSize(-1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorBatchSize > MIN_STRESS_ERROR_BATCH_SIZE)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_ERROR_BATCH_SIZE}`,
                  text: `${this.stressErrorBatchSize}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressErrorBatchSizeInput(value);
                  })

                Button('+1')
                  .onClick(() => this.adjustStressErrorBatchSize(1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-250')
                  .onClick(() => this.adjustStressErrorInterval(-250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorIntervalMs > MIN_STRESS_ERROR_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_ERROR_INTERVAL_MS}`,
                  text: `${this.stressErrorIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressErrorIntervalInput(value);
                  })

                Button('+250')
                  .onClick(() => this.adjustStressErrorInterval(250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: ${this.stressErrorBatchSize} custom errors every ${this.stressErrorIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressErrorSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.enableLongTasks) {
            Column({ space: 10 }) {
              Text('Long Task Stress Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-1')
                  .onClick(() => this.adjustStressLongTaskBatchSize(-1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskBatchSize > MIN_STRESS_LONG_TASK_BATCH_SIZE)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_LONG_TASK_BATCH_SIZE}`,
                  text: `${this.stressLongTaskBatchSize}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressLongTaskBatchSizeInput(value);
                  })

                Button('+1')
                  .onClick(() => this.adjustStressLongTaskBatchSize(1))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 8 }) {
                Button('-250')
                  .onClick(() => this.adjustStressLongTaskInterval(-250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskIntervalMs > MIN_STRESS_LONG_TASK_INTERVAL_MS)

                TextInput({
                  placeholder: `${DEFAULT_STRESS_LONG_TASK_INTERVAL_MS}`,
                  text: `${this.stressLongTaskIntervalMs}`
                })
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .width(112)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(6)
                  .type(InputType.Number)
                  .enabled(!this.isTestRunning)
                  .onChange((value: string) => {
                    this.updateStressLongTaskIntervalInput(value);
                  })

                Button('+250')
                  .onClick(() => this.adjustStressLongTaskInterval(250))
                  .width(64)
                  .height(44)
                  .enabled(!this.isTestRunning)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            Text(`Current: ${this.stressLongTaskBatchSize} long tasks every ${this.stressLongTaskIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
                    .textAlign(TextAlign.Center)

            Button('Reset')
              .onClick(() => this.resetStressLongTaskSettings())
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor('#EAF3FF')
              .fontColor('#007DFF')
              .enabled(!this.isTestRunning)
          }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          if (this.shouldShowBackgroundServiceDetails()) {
            Column({ space: 10 }) {
              Text('Background Service Run Params')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)

              Row() {
                Text('Service State')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.formatBackgroundServiceState())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getBackgroundServiceStateColor())
              }
              .width('100%')

              Row() {
                Text('Last Event')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.backgroundServiceLastEvent)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Last Event Time')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.formatBackgroundServiceEventTime())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Start ID')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.formatBackgroundServiceStartId())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Request Count')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(`${this.backgroundServiceRequestCount}`)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Stop Reason')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.formatBackgroundServiceStopReason())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Last Error')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text(this.formatBackgroundServiceLastError())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.backgroundServiceLastError.length > 0 ? '#F53F3F' : '#1D2129')
                  .maxLines(2)
              }
              .width('100%')

              Row() {
                Text('Run Source')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text('background-service')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Row() {
                Text('Service Ability')
                  .fontSize(14)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
                Text('StressServiceAbility')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Button('Reset')
                .onClick(() => this.resetBackgroundServiceSettings())
                .width('100%')
                .height(42)
                .fontSize(14)
                .backgroundColor('#EAF3FF')
                .fontColor('#007DFF')
                .enabled(!this.isTestRunning)
            }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
          }

          Column({ space: 8 }) {
            Text('Realtime Stats')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Text(`Status: ${this.isTestRunning ? 'Running' : 'Idle'} | Mode: ${this.formatRealtimeRunMode()} | Source: ${this.formatRealtimeSource()} | Traffic: ${this.formatRealtimeTrafficMode()}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')

            Text(`Scenarios: ${this.formatRealtimeScenarioSummary()}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')

            Text(this.isRealtimeTotalMode() ?
              `Elapsed: ${this.formatElapsedTime(this.stats.elapsedSeconds)} | Target: ${this.getRealtimeTotalTargetCount()} per enabled feature` :
              `Elapsed: ${this.formatElapsedTime(this.stats.elapsedSeconds)} | Remaining: ${this.stats.remainingSeconds >= 0 ? this.formatElapsedTime(this.stats.remainingSeconds) : '∞'}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')

            Column({ space: 4 }) {
              Row() {
                Text('Feature')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2F5C8F')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                Text('Expected')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2F5C8F')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                Text('Max Peak')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2F5C8F')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                Text('Actual')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2F5C8F')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                Text('Rate')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2F5C8F')
                    .width('20%')
                    .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 10, bottom: 10 })
              .backgroundColor('#EAF3FF')
              .borderRadius(6)

              if (this.shouldShowLogStats()) {
                Row() {
                  Text('Logs')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedLogResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxLogPeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatActualLogResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.logsGenerated, 'log', this.formatExpectedLogRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }

              if (this.shouldShowActionStats()) {
                Row() {
                  Text('Actions')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedActionResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxActionPeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(`${this.stats.actionsGenerated} actions`)
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.actionsGenerated, 'action', this.formatExpectedActionRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }

              if (this.shouldShowResourceStats()) {
                Row() {
                  Text('Resources')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedResourceResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxResourcePeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatActualResourceResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.resourcesGenerated, 'resource', this.formatExpectedResourceRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }

              if (this.shouldShowNavigationStats()) {
                Row() {
                  Text('Navigation')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedNavigationResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxNavigationPeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(`${this.stats.navigationSwitches} switches`)
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.navigationSwitches, 'switch', this.formatExpectedNavigationRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }

              if (this.shouldShowErrorStats()) {
                Row() {
                  Text('Errors')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedErrorResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxErrorPeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(`${this.stats.errorsGenerated} errors`)
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.errorsGenerated, 'error', this.formatExpectedErrorRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }

              if (this.shouldShowLongTaskStats()) {
                Row() {
                  Text('LongTasks')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatExpectedLongTaskResult())
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatMaxLongTaskPeak())
                    .fontSize(12)
                    .fontColor('#6A4BC3')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(`${this.stats.longTasksGenerated} long tasks`)
                    .fontSize(12)
                    .width('20%')
                    .textAlign(TextAlign.Center)
                  Text(this.formatRealtimeRate(this.stats.longTasksGenerated, 'long task', this.formatExpectedLongTaskRate()))
                    .fontSize(12)
                    .fontColor('#007DFF')
                    .width('20%')
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(6)
              }
            }
            .width('100%')
            .padding(6)
            .backgroundColor('#DDEBFA')
            .borderRadius(8)

            if (this.stats.lastErrorMessage.length > 0) {
              Text(`Last Error: ${this.stats.lastErrorMessage}`)
                .fontSize(12)
                .fontColor('#FF5252')
                .width('100%')
            }
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#F7FBFF')
          .borderRadius(8)

          if (this.isTestRunning) {
            Button('Stop Stress Test')
              .onClick(() => {
                this.stopStressTest();
              })
              .width('100%')
              .height(58)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#FF5252')
              .fontColor(Color.White)

            Text(`Test running: ${this.formatElapsedTime(this.elapsedSeconds)}`)
              .fontSize(14)
              .fontColor(Color.Gray)
                    .textAlign(TextAlign.Center)
              .width('100%')
          } else {
            Button('Start Stress Test')
              .onClick(() => {
                this.startStressTest();
              })
              .width('100%')
              .height(58)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#4CAF50')
              .fontColor(Color.White)
          }

          Button('Crash')
            .onClick(() => this.triggerCrash())
            .width('100%')
            .height(58)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#FF5252')
            .fontColor(Color.White)

          if (this.reportText.length > 0) {
            Column({ space: 8 }) {
              Text('Last Report')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
              Text(this.reportText)
                .fontSize(13)
                .fontColor('#333333')
                .width('100%')
            }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFF8E8')
            .borderRadius(8)
          }

        }
        .width('100%')
        .padding(20)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .scrollBarColor(Color.Gray)
      .scrollBarWidth(4)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
