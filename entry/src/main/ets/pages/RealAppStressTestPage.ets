import { common, Want } from '@kit.AbilityKit';
import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import {
  createEmptyStressTestStats,
  DEFAULT_REAL_TRAFFIC_URL,
  StressTestConfig,
  StressTestManager,
  StressTestReport,
  StressTestStats
} from '../utils/StressTestManager';
import preferences from '@ohos.data.preferences';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "RealAppStressTestPage";
const PREFERENCES_NAME = 'real_app_stress_test_settings';
const KEY_TEST_MINUTES = 'test_minutes';
const KEY_TEST_SECONDS = 'test_seconds';
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
const KEY_IO_CACHE_TOTAL_LOGS = 'io_cache_total_logs';
const KEY_IO_CACHE_PEAK_SIZE = 'io_cache_peak_size';
const KEY_IO_CACHE_PEAK_INTERVAL_MS = 'io_cache_peak_interval_ms';
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
const MAX_REAL_RESOURCE_URL_COUNT = 10;
const DEFAULT_IO_CACHE_TOTAL_LOGS = 200;
const DEFAULT_IO_CACHE_PEAK_SIZE = 2;
const DEFAULT_IO_CACHE_PEAK_INTERVAL_MS = 50;
const MIN_STRESS_LOG_BATCH_SIZE = 1;
const MAX_STRESS_LOG_BATCH_SIZE = 1000;
const MIN_STRESS_LOG_INTERVAL_MS = 16;
const MAX_STRESS_LOG_INTERVAL_MS = 10000;
const MIN_STRESS_ACTION_TIMER_COUNT = 1;
const MAX_STRESS_ACTION_TIMER_COUNT = 20;
const MIN_STRESS_ACTION_INTERVAL_MS = 16;
const MAX_STRESS_ACTION_INTERVAL_MS = 10000;
const MIN_STRESS_RESOURCE_TIMER_COUNT = 1;
const MAX_STRESS_RESOURCE_TIMER_COUNT = 20;
const MIN_STRESS_RESOURCE_INTERVAL_MS = 50;
const MAX_STRESS_RESOURCE_INTERVAL_MS = 10000;
const MIN_STRESS_NAVIGATION_INTERVAL_MS = 250;
const MAX_STRESS_NAVIGATION_INTERVAL_MS = 10000;
const MIN_STRESS_ERROR_BATCH_SIZE = 1;
const MAX_STRESS_ERROR_BATCH_SIZE = 1000;
const MIN_STRESS_ERROR_INTERVAL_MS = 250;
const MAX_STRESS_ERROR_INTERVAL_MS = 10000;
const MIN_STRESS_LONG_TASK_BATCH_SIZE = 1;
const MAX_STRESS_LONG_TASK_BATCH_SIZE = 1000;
const MIN_STRESS_LONG_TASK_INTERVAL_MS = 250;
const MAX_STRESS_LONG_TASK_INTERVAL_MS = 10000;
const MIN_IO_CACHE_TOTAL_LOGS = 1;
const MAX_IO_CACHE_TOTAL_LOGS = 100000;
const MIN_IO_CACHE_PEAK_SIZE = 1;
const MAX_IO_CACHE_PEAK_SIZE = 1000;
const MIN_IO_CACHE_PEAK_INTERVAL_MS = 16;
const MAX_IO_CACHE_PEAK_INTERVAL_MS = 10000;

/**
 * Real App Stress Test Page
 * Simulates real user behavior patterns for stress testing.
 */
@Entry
@Component
export struct RealAppStressTestPage {
  @State abilityContext: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  @State testDuration: number = 60;
  @State testMinutes: number = 1;
  @State testSeconds: number = 0;
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
  @State ioCacheTotalLogs: number = DEFAULT_IO_CACHE_TOTAL_LOGS;
  @State ioCachePeakSize: number = DEFAULT_IO_CACHE_PEAK_SIZE;
  @State ioCachePeakIntervalMs: number = DEFAULT_IO_CACHE_PEAK_INTERVAL_MS;

  private stressTestManager: StressTestManager = StressTestManager.getInstance();
  private updateTimer: number | null = null;
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
    this.stats = snapshot;
    this.isTestRunning = snapshot.isRunning;
    this.elapsedSeconds = snapshot.elapsedSeconds;
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
      await this.saveSettings();
      DemoLogger.i(TAG,
        `Starting stress test: duration=${this.testDuration}s, traffic=${config.trafficMode}, logBatchSize=${config.logBatchSize}, logInterval=${config.logIntervalMs}, actionTimers=${config.actionThreadCount}, actionInterval=${config.actionIntervalMs}, resourceTimers=${config.resourceThreadCount}, resourceInterval=${config.resourceIntervalMs}, resourceUrls=${this.formatRealResourceUrlSummary(config.realResourceUrl)}, navigationInterval=${config.navigationIntervalMs}, errorBatchSize=${config.errorBatchSize}, errorInterval=${config.errorIntervalMs}, longTaskBatchSize=${config.longTaskBatchSize}, longTaskInterval=${config.longTaskIntervalMs}, background=${this.enableBackgroundService}`);

      this.stressTestManager.runWithConfig(config);
      if (this.enableBackgroundService) {
        await this.startBackgroundStressService();
      }

      this.refreshStats();
      this.startUpdateTimer();

      promptAction.showToast({
        message: `Stress test started (${this.testDuration}s)`,
        duration: 2000
      });

      if (config.enableNavigation) {
        this.navigateToStressTestPageA();
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to start stress test: ${error}`);
      promptAction.showToast({
        message: `Failed to start: ${error}`,
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

  startIoCacheStressTest(): void {
    if (this.isTestRunning) {
      promptAction.showToast({
        message: "Test is already running",
        duration: 2000
      });
      return;
    }

    try {
      this.normalizeIoCacheSettings();
      DemoLogger.i(TAG,
        `Starting I/O cache peak stress test: totalLogs=${this.ioCacheTotalLogs}, peakSize=${this.ioCachePeakSize}, peakIntervalMs=${this.ioCachePeakIntervalMs}`);
      this.reportText = "";
      this.lastReportEndedAtMs = 0;
      this.saveSettings();
      this.stressTestManager.runLogIoCacheStress(
        this.ioCacheTotalLogs,
        this.ioCachePeakSize,
        this.ioCachePeakIntervalMs
      );
      this.refreshStats();
      this.startUpdateTimer();

      promptAction.showToast({
        message: `I/O peak started (${this.ioCachePeakSize} / ${this.ioCachePeakIntervalMs}ms)`,
        duration: 2000
      });
    } catch (error) {
      DemoLogger.e(TAG, `Failed to start I/O cache stress test: ${error}`);
      promptAction.showToast({
        message: `Failed to start: ${error}`,
        duration: 3000
      });
      this.isTestRunning = false;
    }
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
    const config = this.stressTestManager.createConfig(
      this.testDuration,
      useRealResourceTraffic,
      this.enableLogs,
      this.enableActions,
      this.enableResources,
      this.enableNavigation,
      this.enableErrors,
      this.enableLongTasks,
      this.enableBackgroundService ? 'background-service' : 'foreground'
    );
    config.logThreadCount = 1;
    config.logTotalCount = 0;
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
    await this.abilityContext.startAppServiceExtensionAbility(want);
    DemoLogger.i(TAG, "Background stress service start requested");
  }

  private async stopBackgroundStressService(): Promise<void> {
    const want = this.createStressServiceWant('stop');
    try {
      await this.abilityContext.startAppServiceExtensionAbility(want);
    } catch (error) {
      DemoLogger.w(TAG, `Background stress service stop command failed: ${error}`);
    }

    try {
      await this.abilityContext.stopAppServiceExtensionAbility(want);
      DemoLogger.i(TAG, "Background stress service stop requested");
    } catch (error) {
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

        if (savedMinutes >= 0 && savedMinutes <= 30 && savedSeconds >= 0 && savedSeconds < 60) {
          this.testMinutes = savedMinutes;
          this.testSeconds = savedSeconds;
          this.updateTestDuration();
          DemoLogger.i(TAG, `Loaded time settings: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        } else {
          DemoLogger.w(TAG, `Invalid saved time settings, using defaults: ${savedMinutes} minutes, ${savedSeconds} seconds`);
        }

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
        this.ioCacheTotalLogs =
          await this.preferencesStore.get(KEY_IO_CACHE_TOTAL_LOGS, DEFAULT_IO_CACHE_TOTAL_LOGS) as number;
        this.ioCachePeakSize =
          await this.preferencesStore.get(KEY_IO_CACHE_PEAK_SIZE, DEFAULT_IO_CACHE_PEAK_SIZE) as number;
        this.ioCachePeakIntervalMs =
          await this.preferencesStore.get(KEY_IO_CACHE_PEAK_INTERVAL_MS, DEFAULT_IO_CACHE_PEAK_INTERVAL_MS) as number;
        this.normalizeStressLogSettings();
        this.normalizeStressActionSettings();
        this.normalizeStressResourceSettings();
        this.normalizeStressNavigationSettings();
        this.normalizeStressErrorSettings();
        this.normalizeStressLongTaskSettings();
        this.normalizeIoCacheSettings();
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
        await this.preferencesStore.put(KEY_IO_CACHE_TOTAL_LOGS, this.ioCacheTotalLogs);
        await this.preferencesStore.put(KEY_IO_CACHE_PEAK_SIZE, this.ioCachePeakSize);
        await this.preferencesStore.put(KEY_IO_CACHE_PEAK_INTERVAL_MS, this.ioCachePeakIntervalMs);
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

  adjustMinutes(delta: number): void {
    const newMinutes = this.testMinutes + delta;
    if (newMinutes >= 0 && newMinutes <= 30) {
      this.testMinutes = newMinutes;
      this.updateTestDuration();
      this.saveSettings();
    }
  }

  adjustSeconds(delta: number): void {
    const newSeconds = this.testSeconds + delta;
    if (newSeconds >= 0 && newSeconds < 60) {
      this.testSeconds = newSeconds;
      this.updateTestDuration();
      this.saveSettings();
    } else if (newSeconds >= 60 && this.testMinutes < 30) {
      this.testMinutes += 1;
      this.testSeconds = newSeconds - 60;
      this.updateTestDuration();
      this.saveSettings();
    } else if (newSeconds < 0 && this.testMinutes > 0) {
      this.testMinutes -= 1;
      this.testSeconds = 60 + newSeconds;
      this.updateTestDuration();
      this.saveSettings();
    }
  }

  private normalizeStressLogSettings(): void {
    this.stressLogBatchSize = this.clampNumber(
      Math.floor(this.stressLogBatchSize),
      MIN_STRESS_LOG_BATCH_SIZE,
      MAX_STRESS_LOG_BATCH_SIZE
    );
    this.stressLogIntervalMs = this.clampNumber(
      Math.floor(this.stressLogIntervalMs),
      MIN_STRESS_LOG_INTERVAL_MS,
      MAX_STRESS_LOG_INTERVAL_MS
    );
  }

  private normalizeStressActionSettings(): void {
    this.stressActionTimerCount = this.clampNumber(
      Math.floor(this.stressActionTimerCount),
      MIN_STRESS_ACTION_TIMER_COUNT,
      MAX_STRESS_ACTION_TIMER_COUNT
    );
    this.stressActionIntervalMs = this.clampNumber(
      Math.floor(this.stressActionIntervalMs),
      MIN_STRESS_ACTION_INTERVAL_MS,
      MAX_STRESS_ACTION_INTERVAL_MS
    );
  }

  private normalizeStressResourceSettings(): void {
    this.stressResourceTimerCount = this.clampNumber(
      Math.floor(this.stressResourceTimerCount),
      MIN_STRESS_RESOURCE_TIMER_COUNT,
      MAX_STRESS_RESOURCE_TIMER_COUNT
    );
    this.stressResourceIntervalMs = this.clampNumber(
      Math.floor(this.stressResourceIntervalMs),
      MIN_STRESS_RESOURCE_INTERVAL_MS,
      MAX_STRESS_RESOURCE_INTERVAL_MS
    );
  }

  private normalizeStressNavigationSettings(): void {
    this.stressNavigationIntervalMs = this.clampNumber(
      Math.floor(this.stressNavigationIntervalMs),
      MIN_STRESS_NAVIGATION_INTERVAL_MS,
      MAX_STRESS_NAVIGATION_INTERVAL_MS
    );
  }

  private normalizeStressErrorSettings(): void {
    this.stressErrorBatchSize = this.clampNumber(
      Math.floor(this.stressErrorBatchSize),
      MIN_STRESS_ERROR_BATCH_SIZE,
      MAX_STRESS_ERROR_BATCH_SIZE
    );
    this.stressErrorIntervalMs = this.clampNumber(
      Math.floor(this.stressErrorIntervalMs),
      MIN_STRESS_ERROR_INTERVAL_MS,
      MAX_STRESS_ERROR_INTERVAL_MS
    );
  }

  private normalizeStressLongTaskSettings(): void {
    this.stressLongTaskBatchSize = this.clampNumber(
      Math.floor(this.stressLongTaskBatchSize),
      MIN_STRESS_LONG_TASK_BATCH_SIZE,
      MAX_STRESS_LONG_TASK_BATCH_SIZE
    );
    this.stressLongTaskIntervalMs = this.clampNumber(
      Math.floor(this.stressLongTaskIntervalMs),
      MIN_STRESS_LONG_TASK_INTERVAL_MS,
      MAX_STRESS_LONG_TASK_INTERVAL_MS
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
    const normalizedUrls = urls.slice(0, MAX_REAL_RESOURCE_URL_COUNT);
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

  private normalizeIoCacheSettings(): void {
    this.ioCacheTotalLogs = this.clampNumber(
      Math.floor(this.ioCacheTotalLogs),
      MIN_IO_CACHE_TOTAL_LOGS,
      MAX_IO_CACHE_TOTAL_LOGS
    );
    this.ioCachePeakSize = this.clampNumber(
      Math.floor(this.ioCachePeakSize),
      MIN_IO_CACHE_PEAK_SIZE,
      MAX_IO_CACHE_PEAK_SIZE
    );
    this.ioCachePeakIntervalMs = this.clampNumber(
      Math.floor(this.ioCachePeakIntervalMs),
      MIN_IO_CACHE_PEAK_INTERVAL_MS,
      MAX_IO_CACHE_PEAK_INTERVAL_MS
    );
    if (this.ioCachePeakSize > this.ioCacheTotalLogs) {
      this.ioCachePeakSize = this.ioCacheTotalLogs;
    }
  }

  private clampNumber(value: number, minValue: number, maxValue: number): number {
    if (value < minValue) {
      return minValue;
    }
    if (value > maxValue) {
      return maxValue;
    }
    return value;
  }

  adjustStressLogBatchSize(delta: number): void {
    this.stressLogBatchSize = this.clampNumber(
      this.stressLogBatchSize + delta,
      MIN_STRESS_LOG_BATCH_SIZE,
      MAX_STRESS_LOG_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressLogInterval(delta: number): void {
    this.stressLogIntervalMs = this.clampNumber(
      this.stressLogIntervalMs + delta,
      MIN_STRESS_LOG_INTERVAL_MS,
      MAX_STRESS_LOG_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressActionTimerCount(delta: number): void {
    this.stressActionTimerCount = this.clampNumber(
      this.stressActionTimerCount + delta,
      MIN_STRESS_ACTION_TIMER_COUNT,
      MAX_STRESS_ACTION_TIMER_COUNT
    );
    this.saveSettings();
  }

  adjustStressActionInterval(delta: number): void {
    this.stressActionIntervalMs = this.clampNumber(
      this.stressActionIntervalMs + delta,
      MIN_STRESS_ACTION_INTERVAL_MS,
      MAX_STRESS_ACTION_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressResourceTimerCount(delta: number): void {
    this.stressResourceTimerCount = this.clampNumber(
      this.stressResourceTimerCount + delta,
      MIN_STRESS_RESOURCE_TIMER_COUNT,
      MAX_STRESS_RESOURCE_TIMER_COUNT
    );
    this.saveSettings();
  }

  adjustStressResourceInterval(delta: number): void {
    this.stressResourceIntervalMs = this.clampNumber(
      this.stressResourceIntervalMs + delta,
      MIN_STRESS_RESOURCE_INTERVAL_MS,
      MAX_STRESS_RESOURCE_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressNavigationInterval(delta: number): void {
    this.stressNavigationIntervalMs = this.clampNumber(
      this.stressNavigationIntervalMs + delta,
      MIN_STRESS_NAVIGATION_INTERVAL_MS,
      MAX_STRESS_NAVIGATION_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressErrorBatchSize(delta: number): void {
    this.stressErrorBatchSize = this.clampNumber(
      this.stressErrorBatchSize + delta,
      MIN_STRESS_ERROR_BATCH_SIZE,
      MAX_STRESS_ERROR_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressErrorInterval(delta: number): void {
    this.stressErrorIntervalMs = this.clampNumber(
      this.stressErrorIntervalMs + delta,
      MIN_STRESS_ERROR_INTERVAL_MS,
      MAX_STRESS_ERROR_INTERVAL_MS
    );
    this.saveSettings();
  }

  adjustStressLongTaskBatchSize(delta: number): void {
    this.stressLongTaskBatchSize = this.clampNumber(
      this.stressLongTaskBatchSize + delta,
      MIN_STRESS_LONG_TASK_BATCH_SIZE,
      MAX_STRESS_LONG_TASK_BATCH_SIZE
    );
    this.saveSettings();
  }

  adjustStressLongTaskInterval(delta: number): void {
    this.stressLongTaskIntervalMs = this.clampNumber(
      this.stressLongTaskIntervalMs + delta,
      MIN_STRESS_LONG_TASK_INTERVAL_MS,
      MAX_STRESS_LONG_TASK_INTERVAL_MS
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
    if (this.realResourceUrls.length >= MAX_REAL_RESOURCE_URL_COUNT) {
      return;
    }
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

  adjustIoCacheTotalLogs(delta: number): void {
    this.ioCacheTotalLogs = this.clampNumber(
      this.ioCacheTotalLogs + delta,
      MIN_IO_CACHE_TOTAL_LOGS,
      MAX_IO_CACHE_TOTAL_LOGS
    );
    if (this.ioCachePeakSize > this.ioCacheTotalLogs) {
      this.ioCachePeakSize = this.ioCacheTotalLogs;
    }
    this.saveSettings();
  }

  adjustIoCachePeakSize(delta: number): void {
    const maxPeakSize = this.ioCacheTotalLogs < MAX_IO_CACHE_PEAK_SIZE ? this.ioCacheTotalLogs : MAX_IO_CACHE_PEAK_SIZE;
    this.ioCachePeakSize = this.clampNumber(
      this.ioCachePeakSize + delta,
      MIN_IO_CACHE_PEAK_SIZE,
      maxPeakSize
    );
    this.saveSettings();
  }

  adjustIoCachePeakInterval(delta: number): void {
    this.ioCachePeakIntervalMs = this.clampNumber(
      this.ioCachePeakIntervalMs + delta,
      MIN_IO_CACHE_PEAK_INTERVAL_MS,
      MAX_IO_CACHE_PEAK_INTERVAL_MS
    );
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

  build() {
    Column() {
      TestPageHeader({
        title: 'Real App Stress Test'
      })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 10 }) {
            Text('Test Duration')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 8 })

            Column({ space: 5 }) {
              Text('Minutes')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 20 }) {
                Button('-')
                  .onClick(() => this.adjustMinutes(-1))
                  .width(60)
                  .height(50)
                  .enabled(!this.isTestRunning && this.testMinutes > 0)

                Text(`${this.testMinutes}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .width(80)
                  .textAlign(TextAlign.Center)

                Button('+')
                  .onClick(() => this.adjustMinutes(1))
                  .width(60)
                  .height(50)
                  .enabled(!this.isTestRunning && this.testMinutes < 30)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Seconds')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 20 }) {
                Button('-')
                  .onClick(() => this.adjustSeconds(-1))
                  .width(60)
                  .height(50)
                  .enabled(!this.isTestRunning && (this.testSeconds > 0 || this.testMinutes > 0))

                Text(`${this.testSeconds}`)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .width(80)
                  .textAlign(TextAlign.Center)

                Button('+')
                  .onClick(() => this.adjustSeconds(1))
                  .width(60)
                  .height(50)
                  .enabled(!this.isTestRunning && (this.testSeconds < 59 || this.testMinutes < 30))
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Total: ${this.formatElapsedTime(this.testDuration)}`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#007DFF')
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)

          Column({ space: 12 }) {
            Text('Resource Traffic Mode')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Row() {
                Toggle({ type: 0, isOn: this.enableResources && this.useRealTraffic })
                  .onChange((isOn: boolean) => {
                    if (!this.enableResources) {
                      this.useRealTraffic = false;
                      this.saveSettings();
                      return;
                    }
                    this.useRealTraffic = isOn;
                    this.saveSettings();
                  })
                  .enabled(!this.isTestRunning && this.enableResources)
                Column({ space: 4 }) {
                  Text(!this.enableResources ? 'Enable Resources First' :
                    (this.useRealTraffic ? 'Real RCP Resource Traffic' : 'Synthetic Resource Traffic'))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                  Text(!this.enableResources ? 'Turn on Resources in Scenario Switches to choose traffic mode' :
                    (this.useRealTraffic ? 'Sends real RCP requests through the configured URL' : 'Generates local resource timing data'))
                    .fontSize(12)
                    .fontColor(Color.Gray)
                }
              .margin({ left: 12 })
              .layoutWeight(1)
            }
            .width('100%')

            if (this.enableResources && this.useRealTraffic) {
              Column({ space: 6 }) {
                Text('Real Resource URLs')
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

                Button('Add URL')
                  .height(40)
                  .width('100%')
                  .enabled(!this.isTestRunning && this.realResourceUrls.length < MAX_REAL_RESOURCE_URL_COUNT)
                  .onClick(() => {
                    this.addRealResourceUrl();
                  })

                Text(this.serializeRealResourceUrls().length > 0 ?
                  'Round-robin by resource index: urls[N % urls.length]' :
                  'Empty uses launch traceUrl first, then default httpbin')
                  .fontSize(12)
                  .fontColor(Color.Gray)
              }
              .width('100%')
            }
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

          Column({ space: 10 }) {
            Text('Auto Navigation Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Switch Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-250')
                  .onClick(() => this.adjustStressNavigationInterval(-250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressNavigationIntervalMs > MIN_STRESS_NAVIGATION_INTERVAL_MS)

                Text(`${this.stressNavigationIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+250')
                  .onClick(() => this.adjustStressNavigationInterval(250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressNavigationIntervalMs < MAX_STRESS_NAVIGATION_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: switch page every ${this.stressNavigationIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Start Stress Test Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustStressLogBatchSize(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogBatchSize > MIN_STRESS_LOG_BATCH_SIZE)

                Text(`${this.stressLogBatchSize}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustStressLogBatchSize(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogBatchSize < MAX_STRESS_LOG_BATCH_SIZE)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-10')
                  .onClick(() => this.adjustStressLogInterval(-10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogIntervalMs > MIN_STRESS_LOG_INTERVAL_MS)

                Text(`${this.stressLogIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+10')
                  .onClick(() => this.adjustStressLogInterval(10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLogIntervalMs < MAX_STRESS_LOG_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.stressLogBatchSize} logs per ${this.stressLogIntervalMs}ms, duration ${this.formatElapsedTime(this.testDuration)}`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Action Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Timer Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustStressActionTimerCount(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionTimerCount > MIN_STRESS_ACTION_TIMER_COUNT)

                Text(`${this.stressActionTimerCount}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustStressActionTimerCount(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionTimerCount < MAX_STRESS_ACTION_TIMER_COUNT)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-10')
                  .onClick(() => this.adjustStressActionInterval(-10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionIntervalMs > MIN_STRESS_ACTION_INTERVAL_MS)

                Text(`${this.stressActionIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+10')
                  .onClick(() => this.adjustStressActionInterval(10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressActionIntervalMs < MAX_STRESS_ACTION_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.stressActionTimerCount} timers, action every ${this.stressActionIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Resource Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Timer Count')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustStressResourceTimerCount(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceTimerCount > MIN_STRESS_RESOURCE_TIMER_COUNT)

                Text(`${this.stressResourceTimerCount}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustStressResourceTimerCount(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceTimerCount < MAX_STRESS_RESOURCE_TIMER_COUNT)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-50')
                  .onClick(() => this.adjustStressResourceInterval(-50))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceIntervalMs > MIN_STRESS_RESOURCE_INTERVAL_MS)

                Text(`${this.stressResourceIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+50')
                  .onClick(() => this.adjustStressResourceInterval(50))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressResourceIntervalMs < MAX_STRESS_RESOURCE_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.stressResourceTimerCount} timers, resource every ${this.stressResourceIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Custom Error Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustStressErrorBatchSize(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorBatchSize > MIN_STRESS_ERROR_BATCH_SIZE)

                Text(`${this.stressErrorBatchSize}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustStressErrorBatchSize(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorBatchSize < MAX_STRESS_ERROR_BATCH_SIZE)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-250')
                  .onClick(() => this.adjustStressErrorInterval(-250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorIntervalMs > MIN_STRESS_ERROR_INTERVAL_MS)

                Text(`${this.stressErrorIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+250')
                  .onClick(() => this.adjustStressErrorInterval(250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressErrorIntervalMs < MAX_STRESS_ERROR_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.stressErrorBatchSize} custom errors every ${this.stressErrorIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('Long Task Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustStressLongTaskBatchSize(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskBatchSize > MIN_STRESS_LONG_TASK_BATCH_SIZE)

                Text(`${this.stressLongTaskBatchSize}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustStressLongTaskBatchSize(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskBatchSize < MAX_STRESS_LONG_TASK_BATCH_SIZE)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-250')
                  .onClick(() => this.adjustStressLongTaskInterval(-250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskIntervalMs > MIN_STRESS_LONG_TASK_INTERVAL_MS)

                Text(`${this.stressLongTaskIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+250')
                  .onClick(() => this.adjustStressLongTaskInterval(250))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.stressLongTaskIntervalMs < MAX_STRESS_LONG_TASK_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.stressLongTaskBatchSize} long tasks every ${this.stressLongTaskIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 10 }) {
            Text('I/O Cache Peak Params')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Column({ space: 5 }) {
              Text('Total Logs')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-100')
                  .onClick(() => this.adjustIoCacheTotalLogs(-100))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCacheTotalLogs > MIN_IO_CACHE_TOTAL_LOGS)

                Text(`${this.ioCacheTotalLogs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+100')
                  .onClick(() => this.adjustIoCacheTotalLogs(100))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCacheTotalLogs < MAX_IO_CACHE_TOTAL_LOGS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Batch Size')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-1')
                  .onClick(() => this.adjustIoCachePeakSize(-1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCachePeakSize > MIN_IO_CACHE_PEAK_SIZE)

                Text(`${this.ioCachePeakSize}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+1')
                  .onClick(() => this.adjustIoCachePeakSize(1))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCachePeakSize < this.ioCacheTotalLogs &&
                    this.ioCachePeakSize < MAX_IO_CACHE_PEAK_SIZE)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Column({ space: 5 }) {
              Text('Event Interval (ms)')
                .fontSize(14)
                .fontColor(Color.Gray)
              Row({ space: 14 }) {
                Button('-10')
                  .onClick(() => this.adjustIoCachePeakInterval(-10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCachePeakIntervalMs > MIN_IO_CACHE_PEAK_INTERVAL_MS)

                Text(`${this.ioCachePeakIntervalMs}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .width(100)
                  .textAlign(TextAlign.Center)

                Button('+10')
                  .onClick(() => this.adjustIoCachePeakInterval(10))
                  .width(76)
                  .height(44)
                  .enabled(!this.isTestRunning && this.ioCachePeakIntervalMs < MAX_IO_CACHE_PEAK_INTERVAL_MS)
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .width('100%')

            Text(`Current: ${this.ioCacheTotalLogs} logs, ${this.ioCachePeakSize} per ${this.ioCachePeakIntervalMs}ms`)
              .fontSize(13)
              .fontColor('#007DFF')
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)

          Column({ space: 8 }) {
            Text('Realtime Stats')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)

            Text(`Status: ${this.isTestRunning ? 'Running' : 'Idle'} | Source: ${this.stats.source} | Traffic: ${this.stats.trafficMode}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')

            Text(`Scenarios: ${this.formatScenarioSummary(this.stats)}`)
              .fontSize(13)
              .fontColor(Color.Gray)
              .width('100%')

            Text(`Elapsed: ${this.formatElapsedTime(this.stats.elapsedSeconds)} | Remaining: ${this.stats.remainingSeconds >= 0 ? this.formatElapsedTime(this.stats.remainingSeconds) : '∞'}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')

            Text(`Navigation: ${this.stats.navigationSwitches} switches | Interval ${this.stats.navigationIntervalMs}ms`)
              .fontSize(14)
              .width('100%')

            Text(`Logs: ${this.stats.logsGenerated} (${this.stats.logBatchesGenerated} batches)`)
              .fontSize(14)
              .width('100%')

            Text(`Actions: ${this.stats.actionsGenerated} | Resources: ${this.stats.resourcesGenerated} / OK ${this.stats.resourcesSucceeded} / Fail ${this.stats.resourcesFailed}`)
              .fontSize(14)
              .width('100%')

            Text(`Errors: ${this.stats.errorsGenerated} | LongTasks: ${this.stats.longTasksGenerated}`)
              .fontSize(14)
              .width('100%')

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

            Button('Start I/O Cache Peak')
              .onClick(() => this.startIoCacheStressTest())
              .width('100%')
              .height(58)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#7B61FF')
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
