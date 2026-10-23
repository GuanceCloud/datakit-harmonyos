import {
  FTAppLaunchAction,
  FTAppLaunchClock,
  FTAppLaunchReporter,
  FTAppLaunchTracker
} from '@guancecloud/ft_sdk/src/main/ets/components/monitor/FTAppLaunchTracker';

export class LaunchSuspendCaseResult {
  id: string = '';
  name: string = '';
  status: string = 'FAIL';
  expected: string = '';
  actual: string = '';
}

class ScenarioClock implements FTAppLaunchClock {
  uptimeNs: number = 1_000_000_000;
  nowUptimeNs(): number { return this.uptimeNs; }
  nowEpochNs(): number { return 1_790_000_000_000_000_000; }
}

class ScenarioReporter implements FTAppLaunchReporter {
  actions: FTAppLaunchAction[] = [];
  report(action: FTAppLaunchAction): boolean {
    this.actions.push(action);
    return true;
  }
}

class ScenarioAbility {}

class LaunchFixture {
  clock: ScenarioClock = new ScenarioClock();
  reporter: ScenarioReporter = new ScenarioReporter();
  tracker: FTAppLaunchTracker = new FTAppLaunchTracker(this.clock, this.reporter);
  ability: ScenarioAbility = new ScenarioAbility();

  constructor() { this.tracker.recordApplicationInit(1_010_000_000); }

  foregroundSource(): void {
    this.tracker.recordLaunchReason(1, undefined, false, { ability: this.ability, abilityName: 'InitialAbility' });
    this.tracker.recordFirstUIAbilityCreated(1_020_000_000);
  }

  finish(rumFirst: boolean = true): void {
    this.tracker.recordUIAbilityForeground(this.ability);
    this.tracker.recordApplicationForeground();
    this.tracker.completeInitialLifecycleRound();
    if (rumFirst) this.tracker.markRumReady(true);
    this.tracker.recordFirstFrame(61_120_000_000);
    if (!rumFirst) this.tracker.markRumReady(true);
  }

  type(): string {
    return this.reporter.actions.length === 1 ? String(this.reporter.actions[0].properties['app_launch_type']) :
      `actions=${this.reporter.actions.length}, pending=${this.tracker.getSnapshot().sourceResolutionPending}`;
  }
}

function result(id: string, name: string, expected: string, actual: string): LaunchSuspendCaseResult {
  const value = new LaunchSuspendCaseResult();
  value.id = id;
  value.name = name;
  value.expected = expected;
  value.actual = actual;
  value.status = expected === actual ? 'PASS' : 'FAIL';
  return value;
}

/** Offline event-order audit of production instances; never reset or mutate the live SDK singleton. */
export function runLaunchSuspendCases(): LaunchSuspendCaseResult[] {
  const results: LaunchSuspendCaseResult[] = [];
  for (const rumFirst of [true, false]) {
    const suffix = rumFirst ? 'rum-first' : 'frame-first';
    const a = new LaunchFixture();
    a.foregroundSource();
    const pending = a.tracker.getSnapshot().sourceResolutionPending;
    a.tracker.recordUIAbilityBackground(a.ability);
    a.tracker.recordApplicationBackground();
    a.finish(rumFirst);
    a.tracker.recordFirstFrame(70_000_000_000);
    a.tracker.markRumReady(true);
    results.push(result(`A1-${suffix}`, '已采集前台来源，未确认时退后台', 'foreground/pending=true/actions=1',
      `${a.type()}/pending=${pending}/actions=${a.reporter.actions.length}`));

    const b = new LaunchFixture();
    // Withhold source delivery, not the event loop. This is a deterministic
    // callback-order fixture, not proof that a device actually froze.
    b.tracker.recordInitialVisibility('background');
    b.tracker.recordApplicationBackground();
    b.tracker.completeInitialLifecycleRound();
    b.foregroundSource();
    b.finish(rumFirst);
    results.push(result(`A2-${suffix}`, '来源未采集，后台兜底先于原始前台证据', 'foreground', b.type()));
  }

  const c = new LaunchFixture();
  c.tracker.recordInitialVisibility('background');
  c.foregroundSource();
  c.finish();
  results.push(result('A3', '对照：原始前台证据先于后台兜底', 'foreground', c.type()));

  for (const mode of [0, 1]) {
    const d = new LaunchFixture();
    d.tracker.recordLaunchReason(9, undefined, false, { ability: d.ability,
      abilityName: 'InitialAbility', intentName: 'InitialIntent', intentId: '17' });
    d.tracker.recordFirstUIAbilityCreated(1_020_000_000);
    d.tracker.recordInitialVisibility('background');
    d.tracker.recordUIAbilityBackground(d.ability);
    d.tracker.completeInitialLifecycleRound();
    const pending = d.tracker.getSnapshot().sourceResolutionPending;
    d.tracker.recordInsightIntentExecute(mode, 'InitialIntent', '17', 'InitialAbility');
    d.finish();
    results.push(result(`A4-mode-${mode}`, '意图模式延迟，同一原始意图 ID 恢复关联',
      `${mode === 0 ? 'foreground' : 'background'}/pending=true`, `${d.type()}/pending=${pending}`));
  }

  const missing = new LaunchFixture();
  missing.tracker.recordLaunchReason(9, undefined, false, { ability: missing.ability,
    intentName: 'InitialIntent', intentId: '17' });
  missing.tracker.recordInitialVisibility('background');
  missing.tracker.recordUIAbilityBackground(missing.ability);
  missing.finish();
  results.push(result('A4-missing', '原始意图模式始终缺失', 'pending=true/actions=0',
    `pending=${missing.tracker.getSnapshot().sourceResolutionPending}/actions=${missing.reporter.actions.length}`));

  const e = new LaunchFixture();
  e.tracker.recordLaunchReason(9, 1, false, { ability: e.ability, intentName: 'BackgroundIntent', intentId: '18' });
  e.tracker.recordFirstUIAbilityCreated(1_020_000_000);
  e.tracker.recordUIAbilityBackground(e.ability);
  e.tracker.recordLaunchReason(1, undefined, false, { ability: new ScenarioAbility() });
  e.finish();
  results.push(result('A5', '真实后台来源不能被后来打开 UI 改写', 'background', e.type()));

  const old = new LaunchFixture();
  old.tracker.recordInitialVisibility('background');
  old.tracker.completeInitialLifecycleRound();
  const fresh = new LaunchFixture();
  fresh.foregroundSource();
  fresh.finish();
  results.push(result('A6', '独立进程状态隔离（逻辑实例对照）', 'old-actions=0/new=foreground',
    `old-actions=${old.reporter.actions.length}/new=${fresh.type()}`));

  for (const beforeCreate of [true, false]) {
    const timing = new LaunchFixture();
    timing.tracker.recordLaunchReason(1);
    timing.tracker.recordFirstUIAbilityCreated(beforeCreate ? 61_020_000_000 : 1_020_000_000);
    timing.finish();
    const action = timing.reporter.actions[0];
    const phase = action.properties[beforeCreate ? 'app_application_init_time' : 'app_first_frame_init_time'] as
      Record<string, number>;
    const expectedPhase = beforeCreate ? 60_010_000_000 : 60_100_000_000;
    results.push(result(beforeCreate ? 'B5-before-create' : 'B5-after-create', '挂起时间归入原定义的阶段（固定时钟）',
      `total=60120000000/phase=${expectedPhase}`, `total=${action.durationNs}/phase=${phase['duration']}`));
  }

  const late = new LaunchFixture();
  late.foregroundSource();
  late.tracker.recordUIAbilityForeground(late.ability);
  late.tracker.recordFirstFrame(1_120_000_000);
  late.clock.uptimeNs = 61_120_000_000;
  late.tracker.markRumReady(true);
  results.push(result('B6', '首帧后等待 RUM 不增加冷启动耗时', '120000000', String(late.reporter.actions[0].durationNs)));
  return results;
}
