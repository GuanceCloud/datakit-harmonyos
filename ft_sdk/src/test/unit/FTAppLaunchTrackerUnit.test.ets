import { describe, expect, it } from '@ohos/hypium';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import {
  FTAppLaunchAction,
  FTAppLaunchClock,
  FTAppLaunchReporter,
  FTAppLaunchTracker
} from '../../main/ets/components/monitor/FTAppLaunchTracker';

class FixedLaunchClock implements FTAppLaunchClock {
  public uptimeNs: number = 100;
  public epochNs: number = 1_000_000;

  public nowUptimeNs(): number {
    return this.uptimeNs;
  }

  public nowEpochNs(): number {
    return this.epochNs;
  }
}

class LaunchAbilityToken {
}

class RecordingLaunchReporter implements FTAppLaunchReporter {
  public actions: FTAppLaunchAction[] = [];

  public report(action: FTAppLaunchAction): boolean {
    this.actions.push(action);
    return true;
  }
}

class FilteringLaunchReporter implements FTAppLaunchReporter {
  public callCount: number = 0;

  public report(_action: FTAppLaunchAction): 'filtered' {
    this.callCount++;
    return 'filtered';
  }
}

class RetryLaunchReporter implements FTAppLaunchReporter {
  public actions: FTAppLaunchAction[] = [];

  public report(action: FTAppLaunchAction): boolean {
    this.actions.push(action);
    return this.actions.length > 1;
  }
}

function propertyText(action: FTAppLaunchAction, key: string): string {
  return String(action.properties[key]);
}

function phaseProperty(action: FTAppLaunchAction, key: string): Record<string, number> {
  return action.properties[key] as Record<string, number>;
}

export default function ftAppLaunchTrackerUnitTest() {
  describe('FTAppLaunchTrackerUnit', () => {
    it('startAbilityReasonAcceptsTheInitialBackgroundIntentExecutor', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: ability, abilityName: 'EntryAbility' });
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      tracker.recordInsightIntentExecute(1, 'BackgroundDiagnostic', '', 'EntryAbility');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(1);
      expect(tracker.getSnapshot().sourceResolutionPending).assertFalse();
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordUIAbilityForeground(ability);
      tracker.recordFirstFrame(300_000_000_200);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
      expect(reporter.actions[0].durationNs).assertEqual(300_000_000_100);
    });

    it('firstFrameAndRumReadinessWaitForInitialDispatchResolution', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordInitialVisibility('foreground');
      expect(tracker.getSnapshot().launchType).assertEqual(null);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: ability, abilityName: 'EntryAbility' });
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordInsightIntentExecute(1, 'BackgroundDiagnostic', '', 'EntryAbility');
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(100);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('initialWantIntentIdentityResolvesModeWithStartAbilityReason', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, 1, false,
        { intentName: 'BackgroundDiagnostic', intentId: '17' });
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('initialForegroundIntentTakesPriorityOverACandidateBackgroundCall', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.CALL, undefined, false, { ability: ability });
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertFalse();
      tracker.recordInsightIntentExecute(0, 'InitialForeground');
      tracker.recordUIAbilityForeground(ability);
      tracker.recordFirstFrame(200);
      tracker.markRumReady(true);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('ordinaryBackgroundCallConfirmsAtItsInitialBackgroundDispatch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.CALL, undefined, false, { ability: ability });
      tracker.recordUIAbilityBackground(ability);
      expect(tracker.getSnapshot().sourceResolutionPending).assertFalse();
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertTrue();
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('ordinaryBackgroundCallCanConfirmAtTheQuiescentFirstRound', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.CALL, undefined, false,
        { ability: new LaunchAbilityToken() });
      tracker.completeInitialLifecycleRound();
      expect(tracker.getSnapshot().sourceResolutionPending).assertFalse();
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertTrue();
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('ordinaryForegroundSettlesAtItsOwnForegroundLifecycle', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false, { ability: ability });
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordUIAbilityForeground(ability);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      tracker.recordInsightIntentExecute(1);
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(null);
    });

    it('laterWantCannotChangePendingOriginalForegroundLaunch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false, { ability: ability });
      tracker.recordUIAbilityNewWant(ability);
      tracker.recordInsightIntentExecute(1, 'LaterBackgroundIntent');
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(null);
    });

    it('warmBackgroundIntentWithoutNewWantCannotChangeAPendingForegroundLaunch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false, { ability: ability });
      tracker.recordUIAbilityForeground(ability);
      // The system can execute a warm background intent without onNewWant,
      // while delayed RUM readiness still prevents the cold Action submission.
      tracker.recordInsightIntentExecute(1, 'LaterBackgroundIntent');
      tracker.recordFirstFrame(200);
      tracker.markRumReady(true);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(null);
    });

    it('unidentifiedLateExecutorCannotResolveAnInitialIntentAfterForeground', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: ability, intentName: 'Initial' });
      tracker.recordUIAbilityForeground(ability);
      tracker.recordInsightIntentExecute(1, 'Initial');
      tracker.recordFirstFrame(200);
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().sourceResolutionPending).assertTrue();
    });

    it('secondAbilityCannotSupplyItsIntentToOriginalLaunch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: new LaunchAbilityToken(), abilityName: 'EntryAbility' });
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: new LaunchAbilityToken(), abilityName: 'SecondaryLaunchAbility' });
      tracker.recordInsightIntentExecute(1, 'SecondaryIntent', '', 'SecondaryLaunchAbility');
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('initialIntentRejectsOtherNamesInstancesAndAbilities', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: new LaunchAbilityToken(), abilityName: 'EntryAbility', intentName: 'Initial', intentId: '17' });
      tracker.recordInsightIntentExecute(1, 'Other', '17', 'EntryAbility');
      tracker.recordInsightIntentExecute(1, 'Initial', '18', 'EntryAbility');
      tracker.recordInsightIntentExecute(1, 'Initial', '17', 'SecondaryLaunchAbility');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(null);
      expect(tracker.getSnapshot().sourceResolutionPending).assertTrue();
      tracker.recordInsightIntentExecute(0, 'Initial', '17', 'EntryAbility');
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('exactInitialIntentIdCanResolveADelayedCallbackAfterNewWant', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      const ability = new LaunchAbilityToken();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, undefined, false,
        { ability: ability, intentName: 'Initial', intentId: '17' });
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      tracker.recordUIAbilityNewWant(ability);
      tracker.recordInsightIntentExecute(1, 'Initial', '18');
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordInsightIntentExecute(1, 'Initial', '17');
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('uiAbilityCreationAloneDoesNotClassifyLaunch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(tracker.getSnapshot().launchType).assertEqual(null);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('systemForegroundReasonWinsOverInitialBackgroundSnapshot', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordInitialVisibility('background');
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY, 1);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertFalse();
    });

    it('backgroundCallCreatesAbilityBeforeFiveMinuteWaitAndKeepsOrigin', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordApplicationInit(120);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.CALL);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordApplicationForeground();
      tracker.recordWindowForeground();
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordFirstFrame(300_000_000_200);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(300_000_000_100);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('callExplicitlyRequestingForegroundUsesForegroundOrigin', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.CALL, undefined, true);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('foregroundIntentUsesExecuteModeEvenWithBackgroundProcessSnapshot', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordInitialVisibility('background');
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.INSIGHT_INTENT, 0);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(0);
    });

    it('backgroundIntentKeepsOriginAfterAbilityCreationAndForegrounding', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordInitialVisibility('foreground');
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.INSIGHT_INTENT, 1);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordApplicationForeground();
      tracker.recordWindowForeground();
      tracker.recordInsightIntentExecute(0);
      tracker.recordFirstFrame(300_000_000_200);
      tracker.recordFirstFrame(300_000_000_300);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(300_000_000_100);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
      expect(tracker.getSnapshot().insightIntentExecuteMode).assertEqual(1);
    });

    it('intentWaitsForActualExecutorModeAndPreservesEarlierFirstFrame', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordInitialVisibility('foreground');
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.INSIGHT_INTENT);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.recordApplicationForeground();
      tracker.recordWindowForeground();
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      tracker.recordInsightIntentExecute(2);
      expect(tracker.getSnapshot().launchType).assertEqual(null);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordInsightIntentExecute(0);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(100);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('pendingBackgroundIntentDoesNotGuessModeFromVisibilityOrUiCreation', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.INSIGHT_INTENT, Number.NaN);
      tracker.recordInitialVisibility('background');
      tracker.recordFirstUIAbilityCreated(150);
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      expect(tracker.getSnapshot().launchType).assertEqual(null);
      tracker.recordInsightIntentExecute(1);
      expect(tracker.getSnapshot().launchType).assertEqual('background');
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('laterBackgroundIntentCannotReplaceOriginalForegroundLaunch', 0, () => {
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.INSIGHT_INTENT, 1);
      tracker.recordInsightIntentExecute(1);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('systemBackgroundReasonsWaitForTheSameProcessFirstFrame', 0, () => {
      const reasons: number[] = [AbilityConstant.LaunchReason.AUTO_STARTUP,
        AbilityConstant.LaunchReason.PREPARE_CONTINUATION, 11];
      for (const reason of reasons) {
        const reporter = new RecordingLaunchReporter();
        const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
        tracker.recordLaunchReason(reason);
        tracker.recordFirstUIAbilityCreated(150);
        tracker.markRumReady(true);
        expect(reporter.actions.length).assertEqual(0);
        tracker.recordFirstFrame(200);
        expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
      }
    });

    it('reportForegroundLaunchWithPhaseFields', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 1_000_000);

      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(130);
      tracker.recordFirstUIAbilityCreated(190);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(240);

      expect(reporter.actions.length).assertEqual(1);
      const action = reporter.actions[0];
      expect(action.durationNs).assertEqual(140);
      expect(action.startEpochNs).assertEqual(1_000_000);
      expect(propertyText(action, 'app_launch_type')).assertEqual('foreground');
      expect(phaseProperty(action, 'app_pre_application_init_time')['start']).assertEqual(0);
      expect(phaseProperty(action, 'app_pre_application_init_time')['duration']).assertEqual(30);
      expect(phaseProperty(action, 'app_application_init_time')['start']).assertEqual(30);
      expect(phaseProperty(action, 'app_application_init_time')['duration']).assertEqual(60);
      expect(phaseProperty(action, 'app_first_frame_init_time')['start']).assertEqual(90);
      expect(phaseProperty(action, 'app_first_frame_init_time')['duration']).assertEqual(50);
    });

    it('launchCachesBoundariesAndReportsOnce', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 10, 500);

      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(20);
      tracker.recordFirstUIAbilityCreated(30);
      tracker.recordFirstFrame(40);
      expect(reporter.actions.length).assertEqual(0);

      tracker.markRumReady(true);
      tracker.recordFirstFrame(50);
      tracker.recordFirstUIAbilityCreated(35);

      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(30);
      expect(tracker.getSnapshot().reported).assertTrue();
    });

    it('notifyColdLaunchCompletionListenersOnce', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      let completionCount = 0;
      tracker.onReportSubmitted((): void => {
        completionCount++;
      });

      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      tracker.recordFirstFrame(210);

      expect(completionCount).assertEqual(1);
      tracker.onReportSubmitted((): void => {
        completionCount++;
      });
      expect(completionCount).assertEqual(2);
    });

    it('filteredLaunchFinishesWithoutReportingOrRetrying', 0, () => {
      const reporter = new FilteringLaunchReporter();
      const tracker = new FTAppLaunchTracker(new FixedLaunchClock(), reporter, 100, 900);
      let finishedCount = 0;
      let submittedCount = 0;
      tracker.onFinished((): void => { finishedCount++; });
      tracker.onReportSubmitted((): void => { submittedCount++; });

      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.markRumReady(true);
      tracker.recordFirstFrame(200);
      tracker.recordFirstFrame(210);

      expect(reporter.callCount).assertEqual(1);
      expect(tracker.getSnapshot().finished).assertTrue();
      expect(tracker.getSnapshot().reported).assertFalse();
      expect(finishedCount).assertEqual(1);
      expect(submittedCount).assertEqual(0);
      tracker.onFinished((): void => { finishedCount++; });
      expect(finishedCount).assertEqual(2);
    });

    it('backgroundLaunchIncludesFiveMinutesBeforeSameProcessFirstUiFrame', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const startNs = 1_000_000_000;
      const backgroundWaitNs = 300_000_000_000;
      const uiRenderNs = 50_000_000;
      const tracker = new FTAppLaunchTracker(clock, reporter, startNs, 900);

      tracker.recordApplicationInit(startNs + 60_000_000);
      tracker.recordInitialVisibility('background');
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertTrue();
      expect(tracker.getSnapshot().finished).assertFalse();

      // Even after five minutes and foreground transition, no Action is
      // emitted until this same tracker/process receives its first UI frame.
      clock.uptimeNs = startNs + backgroundWaitNs;
      tracker.markRumReady(true);
      tracker.recordApplicationForeground();
      tracker.recordFirstUIAbilityCreated(clock.uptimeNs);
      tracker.recordWindowForeground();
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().launchType).assertEqual('background');
      clock.uptimeNs += uiRenderNs;
      tracker.recordFirstFrame(clock.uptimeNs);

      expect(reporter.actions.length).assertEqual(1);
      const action = reporter.actions[0];
      expect(action.durationNs).assertEqual(backgroundWaitNs + uiRenderNs);
      expect(action.startEpochNs).assertEqual(900);
      expect(propertyText(action, 'app_launch_type')).assertEqual('background');
      expect(phaseProperty(action, 'app_pre_application_init_time')['start']).assertEqual(0);
      expect(phaseProperty(action, 'app_pre_application_init_time')['duration']).assertEqual(60_000_000);
      expect(phaseProperty(action, 'app_application_init_time')['start']).assertEqual(60_000_000);
      expect(phaseProperty(action, 'app_application_init_time')['duration'])
        .assertEqual(backgroundWaitNs - 60_000_000);
      expect(phaseProperty(action, 'app_first_frame_init_time')['start']).assertEqual(backgroundWaitNs);
      expect(phaseProperty(action, 'app_first_frame_init_time')['duration']).assertEqual(uiRenderNs);
      expect(tracker.getSnapshot().reported).assertTrue();
    });

    it('backgroundLaunchWaitsForQuiescenceAndNotifiesOnce', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      let detectionCount = 0;
      tracker.onBackgroundLaunchDetected((): void => {
        detectionCount++;
      });

      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      clock.uptimeNs = 200;
      tracker.completeInitialLifecycleRound();

      expect(detectionCount).assertEqual(1);
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().finished).assertFalse();

      tracker.recordFirstUIAbilityCreated(220);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(260);
      tracker.markRumReady(true);
      tracker.completeInitialLifecycleRound();
      tracker.recordFirstFrame(300);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(160);
      expect(tracker.getSnapshot().firstFrameUptimeNs).assertEqual(260);

      tracker.onBackgroundLaunchDetected((): void => {
        detectionCount++;
      });
      expect(detectionCount).assertEqual(2);
    });

    it('backgroundRetryPreservesFirstFrameDuration', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RetryLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      clock.uptimeNs = 200;
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      expect(tracker.getSnapshot().reported).assertFalse();
      expect(reporter.actions.length).assertEqual(0);

      clock.uptimeNs = 400;
      tracker.recordFirstUIAbilityCreated(300);
      tracker.recordFirstFrame(400);
      expect(reporter.actions.length).assertEqual(1);
      expect(tracker.getSnapshot().reported).assertFalse();
      clock.uptimeNs = 800;
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(2);
      expect(reporter.actions[0].durationNs).assertEqual(300);
      expect(reporter.actions[1].durationNs).assertEqual(300);
      expect(propertyText(reporter.actions[1], 'app_launch_type')).assertEqual('background');
      expect(phaseProperty(reporter.actions[1], 'app_first_frame_init_time')['duration']).assertEqual(100);
      expect(tracker.getSnapshot().reported).assertTrue();
    });

    it('backgroundLateRumReadinessUsesTheFirstFrameNotTheReadyTime', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      tracker.completeInitialLifecycleRound();
      tracker.recordApplicationForeground();
      tracker.recordFirstUIAbilityCreated(300);
      tracker.recordFirstFrame(350);
      expect(reporter.actions.length).assertEqual(0);

      clock.uptimeNs = 1000;
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(250);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
      expect(phaseProperty(reporter.actions[0], 'app_first_frame_init_time')['duration']).assertEqual(50);
    });

    it('backgroundFilteredLaunchFinishesWithoutRetry', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new FilteringLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      let submittedCount = 0;
      tracker.onReportSubmitted((): void => { submittedCount++; });
      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      clock.uptimeNs = 200;
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      expect(reporter.callCount).assertEqual(0);
      tracker.recordFirstUIAbilityCreated(220);
      tracker.recordFirstFrame(260);
      tracker.markRumReady(true);
      expect(reporter.callCount).assertEqual(1);
      expect(submittedCount).assertEqual(0);
      expect(tracker.getSnapshot().finished).assertTrue();
      expect(tracker.getSnapshot().reported).assertFalse();
    });

    it('backgroundLaunchWaitsForValidFirstFrame', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);
      tracker.recordFirstUIAbilityCreated(150);
      tracker.recordFirstFrame(Number.NaN);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(0);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(200);
      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(100);
    });

    it('shownWindowPreventsNoUiBackgroundReport', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      tracker.markRumReady(true);
      tracker.recordWindowForeground();
      clock.uptimeNs = 200;
      tracker.completeInitialLifecycleRound();
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstUIAbilityCreated(220);
      tracker.recordFirstFrame(260);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('invalidPhaseKeepsForegroundTotal', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(180);
      tracker.recordFirstUIAbilityCreated(170);
      tracker.recordFirstFrame(220);

      expect(reporter.actions.length).assertEqual(1);
      const action = reporter.actions[0];
      expect(action.durationNs).assertEqual(120);
      expect(action.properties['app_application_init_time'] === undefined).assertTrue();
      expect(phaseProperty(action, 'app_first_frame_init_time')['start']).assertEqual(70);
      expect(phaseProperty(action, 'app_first_frame_init_time')['duration']).assertEqual(50);
    });

    it('delayedUiRemainsForeground', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordApplicationInit(120);
      tracker.recordInitialVisibility('foreground');
      tracker.recordApplicationForeground();
      tracker.completeInitialLifecycleRound();
      expect(reporter.actions.length).assertEqual(0);

      tracker.recordFirstUIAbilityCreated(300);
      tracker.recordFirstFrame(350);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('launchUsesFirstUiAbilityOnly', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(180);
      tracker.recordFirstUIAbilityCreated(220);
      tracker.recordFirstFrame(240);

      expect(reporter.actions.length).assertEqual(1);
      expect(reporter.actions[0].durationNs).assertEqual(140);
      expect(phaseProperty(reporter.actions[0], 'app_application_init_time')['start']).assertEqual(20);
      expect(phaseProperty(reporter.actions[0], 'app_application_init_time')['duration']).assertEqual(60);
      expect(phaseProperty(reporter.actions[0], 'app_first_frame_init_time')['start']).assertEqual(80);
      expect(phaseProperty(reporter.actions[0], 'app_first_frame_init_time')['duration']).assertEqual(60);
    });

    it('launchRacePrefersForeground', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordApplicationInit(120);
      tracker.recordInitialVisibility('background');
      tracker.recordApplicationBackground();
      tracker.recordApplicationForeground();
      tracker.completeInitialLifecycleRound();
      expect(reporter.actions.length).assertEqual(0);

      tracker.recordFirstUIAbilityCreated(180);
      tracker.recordFirstFrame(210);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('foreground');
    });

    it('launchWaitsForInitialVisibility', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordApplicationInit(120);
      // A transition callback by itself is not a reliable initial-state read.
      tracker.recordInitialVisibility('unknown');
      tracker.recordApplicationBackground();
      tracker.completeInitialLifecycleRound();

      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().initialVisibility).assertEqual('unknown');

      tracker.recordInitialVisibility('background');
      // A late initial-state result only classifies the background origin;
      // submission must still wait for this process's first UI frame.
      clock.uptimeNs = 170;
      tracker.markRumReady(true);
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().backgroundLaunchDetected).assertTrue();
      tracker.recordFirstUIAbilityCreated(180);
      expect(reporter.actions.length).assertEqual(0);
      tracker.recordFirstFrame(210);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('headlessBackgroundProcessDoesNotReportOrTransferTimingToAnotherProcess', 0, () => {
      const clock = new FixedLaunchClock();
      const backgroundReporter = new RecordingLaunchReporter();
      const background = new FTAppLaunchTracker(clock, backgroundReporter, 100, 900);
      background.recordApplicationInit(120);
      background.recordInitialVisibility('background');
      background.completeInitialLifecycleRound();
      background.markRumReady(true);
      clock.uptimeNs = 300_000_000_100;
      background.markRumReady(true);
      expect(backgroundReporter.actions.length).assertEqual(0);
      expect(background.getSnapshot().finished).assertFalse();

      const uiReporter = new RecordingLaunchReporter();
      const uiStart = clock.uptimeNs;
      const uiProcess = new FTAppLaunchTracker(clock, uiReporter, uiStart, 2_000_000);
      uiProcess.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      uiProcess.recordApplicationInit(uiStart + 10);
      uiProcess.recordFirstUIAbilityCreated(uiStart + 20);
      uiProcess.markRumReady(true);
      uiProcess.recordFirstFrame(uiStart + 60);
      expect(uiReporter.actions.length).assertEqual(1);
      expect(uiReporter.actions[0].durationNs).assertEqual(60);
      expect(propertyText(uiReporter.actions[0], 'app_launch_type')).assertEqual('foreground');
      expect(backgroundReporter.actions.length).assertEqual(0);
    });

    it('earlyExitOmitsForegroundFirstFrame', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordLaunchReason(AbilityConstant.LaunchReason.START_ABILITY);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(180);

      // No first frame: a foreground process that exits before drawing must not produce
      // a synthetic first-frame phase or an incomplete launch_cold Action.
      expect(reporter.actions.length).assertEqual(0);
    });
  });
}
