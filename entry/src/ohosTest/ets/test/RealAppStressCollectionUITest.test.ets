import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { RumAttributeAssert } from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/RumAttributeAssert';
import { createDefaultStressTestConfig, StressTestConfig, StressTestManager } from '../../../main/ets/utils/StressTestManager';
import { testArgument, testBoolean } from '../../../main/ets/utils/EntryTestConfig';
import { EntryRecordCapture } from './helpers/EntryRecordCapture';
import { EntryWaitUtils } from './helpers/EntryWaitUtils';
import { UiTestUtils } from './helpers/UiTestUtils';

const REPORT_TAG = 'FTRealStressUITest';
const RUN_CONTEXT_KEY = 'stress_run_id';
const JANK_EVIDENCE_WATCHER = 'entry_stress_jank_probe';
let systemJankEvidence: string = 'no OS event received';
let jankEvidenceWatcherRegistered: boolean = false;

interface StressTestArguments {
  parameters?: Record<string, string>;
}

interface RealCollectionCase {
  feature: string;
  runId: string;
  passed: boolean;
  triggered: number;
  collected: number;
  durationNs: number;
  evidence: string;
  error: string;
}

interface RealCollectionReport {
  runId: string;
  passed: boolean;
  elapsedMs: number;
  cases: RealCollectionCase[];
}

function argumentsForTest(): Record<string, string> {
  return (AbilityDelegatorRegistry.getArguments() as Object as StressTestArguments).parameters ?? {};
}

function actionCount(): number {
  const value = Number(testArgument(argumentsForTest(), 'entryRealStressActionCount') ?? '3');
  if (!Number.isFinite(value) || value < 1 || value > 10000) {
    throw new Error('entryRealStressActionCount must be between 1 and 10000');
  }
  return Math.floor(value);
}

function actionIntervalMs(): number {
  const value = Number(testArgument(argumentsForTest(), 'entryRealStressActionIntervalMs') ?? '500');
  if (!Number.isFinite(value) || value < 100 || value > 10000) {
    throw new Error('entryRealStressActionIntervalMs must be between 100 and 10000');
  }
  return Math.floor(value);
}

function scenarioConfig(feature: string): StressTestConfig {
  const config = createDefaultStressTestConfig();
  config.runMode = 'total';
  config.totalTargetCount = feature === 'action' ? actionCount() : feature === 'long_task' ? 6 : 3;
  config.enableLogs = feature === 'log';
  config.enableActions = feature === 'action';
  config.enableResources = false;
  config.enableNavigation = false;
  config.enableErrors = feature === 'error';
  config.enableLongTasks = feature === 'long_task';
  config.useRealLogs = true;
  config.useRealActions = true;
  config.useRealErrors = true;
  config.useRealLongTasks = true;
  config.logThreadCount = 1;
  config.logBatchSize = 1;
  config.logIntervalMs = 300;
  config.errorBatchSize = 1;
  config.errorIntervalMs = 500;
  config.longTaskBatchSize = 1;
  config.longTaskIntervalMs = 1000;
  // Exercise the system's stack-reporting range on developer devices. The
  // demo's default 600ms workload can select trace capture, which is restricted.
  config.realLongTaskDurationMs = 350;
  return config;
}

/** Demo-test process only: changes detection policy, never fabricates an OS event. */
async function prepareSystemJank(): Promise<void> {
  const watcher = hiAppEvent.addWatcher({
    name: JANK_EVIDENCE_WATCHER,
    appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.MAIN_THREAD_JANK] }],
    onReceive: (_domain: string, groups: Array<hiAppEvent.AppEventGroup>): void => {
      for (const group of groups) {
        for (const event of group.appEventInfos) {
          systemJankEvidence = JSON.stringify(event.params).substring(0, 500);
          hilog.info(0xD003, REPORT_TAG, '%{public}s', `REAL_STRESS_OS_EVENT ${systemJankEvidence}`);
        }
      }
    }
  });
  jankEvidenceWatcherRegistered = watcher !== null;
  await hiAppEvent.setEventConfig(hiAppEvent.event.MAIN_THREAD_JANK, {
    'log_type': '1', 'sample_interval': '50', 'ignore_startup_time': '3',
    'sample_count': '5', 'report_times_per_app': '3'
  });
  await EntryWaitUtils.delay(3500);
}

async function realClicks(driver: Driver, manager: StressTestManager): Promise<void> {
  const ready = await EntryWaitUtils.waitUntil(async () =>
    await driver.findComponent(ON.id('stress-real-action')) !== null, 8000);
  if (!ready) throw new Error('Real Action button did not become available');
  for (let index = 0; index < actionCount(); index++) {
    // Re-resolve every time. Never call the UI callback or the SDK Action API.
    const button = await driver.findComponent(ON.id('stress-real-action'));
    if (button === null) throw new Error(`Real Action button missing at input ${index}`);
    await button.click();
    const delivered = await EntryWaitUtils.waitUntil(async () =>
      manager.getStatsSnapshot().actionsGenerated > index, 3000);
    if (!delivered) throw new Error(`Actual UI click ${index} did not reach the application`);
    await driver.delayMs(actionIntervalMs());
  }
}

async function realBlockClicks(driver: Driver, manager: StressTestManager): Promise<void> {
  const ready = await EntryWaitUtils.waitUntil(async () =>
    await driver.findComponent(ON.id('stress-real-long-task')) !== null, 8000);
  if (!ready) throw new Error('Real LongTask button did not become available');
  const target = scenarioConfig('long_task').totalTargetCount;
  while (manager.getStatsSnapshot().longTasksGenerated < target) {
    const before = manager.getStatsSnapshot().longTasksGenerated;
    const button = await driver.findComponent(ON.id('stress-real-long-task'));
    if (button === null) throw new Error(`Real LongTask button missing at input ${before}`);
    // Pair physical taps to avoid UI-tree query latency between the separate
    // main-thread dispatches needed by system sampling.
    if (target - before >= 2) await button.doubleClick();
    else await button.click();
    const delivered = await EntryWaitUtils.waitUntil(async () =>
      manager.getStatsSnapshot().longTasksGenerated >= Math.min(target, before + 2), 3000);
    if (!delivered) throw new Error(`Real UI block pair at input ${before} did not execute`);
  }
}

async function collectCase(feature: string, runId: string, driver: Driver,
  capture: EntryRecordCapture): Promise<RealCollectionCase> {
  const result: RealCollectionCase = {
    feature, runId, passed: false, triggered: 0, collected: 0, durationNs: 0, evidence: '', error: ''
  };
  const manager = StressTestManager.getInstance();
  FTSDK.appendRUMGlobalContextKeyValue(RUN_CONTEXT_KEY, runId);
  FTSDK.appendLogGlobalContextKeyValue(RUN_CONTEXT_KEY, runId);
  try {
    if (feature === 'long_task') await prepareSystemJank();
    manager.runWithConfig(scenarioConfig(feature));
    if (feature === 'action') await realClicks(driver, manager);
    if (feature === 'long_task') await realBlockClicks(driver, manager);
    const stopped = await EntryWaitUtils.waitUntil(async () => !manager.isStressTestRunning(),
      feature === 'action' ? actionCount() * (actionIntervalMs() + 3000) + 10000 : 15000);
    if (!stopped) throw new Error('Real workload did not finish its configured target');
    const stats = manager.getStatsSnapshot();
    result.triggered = feature === 'action' ? stats.actionsGenerated : feature === 'log' ? stats.logsGenerated :
      feature === 'error' ? stats.errorsGenerated : stats.longTasksGenerated;
    const type = feature === 'log' ? DataType.LOG : DataType.RUM_APP;
    const fragments = [`${RUN_CONTEXT_KEY}=${runId}`];
    if (feature === 'action') fragments.push('action,', 'stress-real-action', 'action_type=click');
    if (feature === 'log') fragments.push('log_source=hilog', 'FTStressRealLog', 'STRESS_REAL_RUNTIME');
    if (feature === 'error') fragments.push('error,', 'real-caught-exception');
    if (feature === 'long_task') fragments.push('long_task,', 'long_task_stack=');
    const line = await capture.waitForRecord(type, fragments, feature === 'long_task' ? 45000 : 15000);
    if (line === null) {
      const candidates = await capture.matchingRecords(type,
        feature === 'log' ? ['FTStressRealLog'] : feature === 'error' ? ['real-caught-exception'] : ['long_task,']);
      result.evidence = candidates.slice(-2).map((candidate: string) => {
        const point = RumAttributeAssert.payload(candidate)[0];
        return `${point.measurement}: run=${point.tags.get(RUN_CONTEXT_KEY)}, ` +
          `message=${String(point.fields.get('error_message') ?? point.fields.get('message')).substring(0, 80)}`;
      }).join('; ');
      if (feature === 'long_task') result.evidence += `; system=${systemJankEvidence}`;
      throw new Error(`SDK did not collect a real ${feature} record for this run`);
    }
    const expected = feature === 'long_task' ? 1 : scenarioConfig(feature).totalTargetCount;
    const collected = await EntryWaitUtils.waitUntil(async () => {
      result.collected = (await capture.matchingRecords(type, fragments)).length;
      return result.collected >= expected;
    }, 15000);
    if (!collected) throw new Error(`SDK collected ${result.collected}/${expected} ${feature} records; check sampling, filters and collector delivery`);
    const point = RumAttributeAssert.payload(line)[0];
    result.durationNs = Number(point.fields.get('duration') ?? 0);
    if (feature === 'action' && result.durationNs <= 0) throw new Error('Automatic Action has no actual duration');
    if (feature === 'error' && (String(point.fields.get('error_stack') ?? '').length === 0 ||
      String(point.fields.get('error_stack')).includes('Stress custom error') ||
      String(point.fields.get('error_message') ?? '').length === 0)) {
      throw new Error('Expected the actual runtime exception message and stack');
    }
    if (feature === 'long_task' && (result.durationNs <= 300000000 ||
      String(point.fields.get('long_task_stack')).startsWith('Stress long task'))) {
      throw new Error('Expected a system-observed real LongTask over the SDK threshold');
    }
    result.evidence = feature === 'action' ? String(point.tags.get('action_name')) :
      feature === 'log' ? 'log_source=hilog; FTStressRealLog; runtime heap/time' :
        String(point.fields.get(feature === 'error' ? 'error_stack' : 'long_task_stack')).substring(0, 300);
    result.passed = true;
  } catch (error) {
    result.error = String(error);
  } finally {
    if (manager.isStressTestRunning()) manager.stop('manual');
  }
  hilog.info(0xD003, REPORT_TAG, '%{public}s', `REAL_STRESS_CASE ${JSON.stringify(result)}`);
  return result;
}

export default function realAppStressCollectionUITest() {
  if (!testBoolean(argumentsForTest(), 'entryRealStressEnabled', false)) return;
  describe('RealAppStressCollectionUITest', () => {
    it('automaticallyCollectsRealActionsLogsErrorsAndLongTasks', 0, async () => {
      const startedAt = Date.now();
      const runId = testArgument(argumentsForTest(), 'entryRealStressRunId') ?? `real_stress_${startedAt}`;
      const report: RealCollectionReport = { runId, passed: false, elapsedMs: 0, cases: [] };
      const capture = new EntryRecordCapture();
      try {
        const driver = await UiTestUtils.createDriver();
        await UiTestUtils.launchEntryAbility(driver);
        capture.start();
        await UiTestUtils.clickText(driver, 'Real App Stress Test');
        const selected = testArgument(argumentsForTest(), 'entryRealStressFeature') ?? 'all';
        // Reserve the system sampling window before the other UI workloads.
        const features = ['long_task', 'action', 'log', 'error'].filter((feature: string) =>
          selected === 'all' || feature === selected);
        if (features.length === 0) throw new Error('entryRealStressFeature must be all, action, log, error or long_task');
        for (const feature of features) {
          report.cases.push(await collectCase(feature, `${runId}_${feature}`, driver, capture));
        }
        report.passed = report.cases.length === features.length && report.cases.every((item: RealCollectionCase) => item.passed);
      } catch (error) {
        report.cases.push({ feature: 'setup', runId, passed: false, triggered: 0, collected: 0,
          durationNs: 0, evidence: '', error: String(error) });
      } finally {
        capture.stop();
        if (jankEvidenceWatcherRegistered) {
          hiAppEvent.removeWatcher({ name: JANK_EVIDENCE_WATCHER });
          jankEvidenceWatcherRegistered = false;
        }
        FTSDK.appendRUMGlobalContextKeyValue(RUN_CONTEXT_KEY, '');
        FTSDK.appendLogGlobalContextKeyValue(RUN_CONTEXT_KEY, '');
        report.elapsedMs = Date.now() - startedAt;
        const json = JSON.stringify(report);
        hilog.info(0xD003, REPORT_TAG, '%{public}s', `REAL_STRESS_REPORT ${json}`);
        const ability = await AbilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
        const file = fs.openSync(`${ability.context.filesDir}/real-stress-collection-last.json`,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try { fs.writeSync(file.fd, json); } finally { fs.closeSync(file); }
      }
      expect(report.passed).assertTrue();
    });
  });
}
