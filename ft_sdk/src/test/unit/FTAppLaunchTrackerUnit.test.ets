import { describe, expect, it } from '@ohos/hypium';
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

class RecordingLaunchReporter implements FTAppLaunchReporter {
  public actions: FTAppLaunchAction[] = [];

  public report(action: FTAppLaunchAction): boolean {
    this.actions.push(action);
    return true;
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
    it('reportForegroundLaunchWithPhaseFields', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 1_000_000);

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

    it('backgroundLaunchWaitsForFirstFrame', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.recordApplicationInit(160);
      tracker.recordInitialVisibility('background');
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);

      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().backgroundLaunchPendingUi).assertTrue();

      tracker.recordFirstUIAbilityCreated(220);
      tracker.recordFirstFrame(260);

      expect(reporter.actions.length).assertEqual(1);
      const action = reporter.actions[0];
      expect(action.durationNs).assertEqual(160);
      expect(propertyText(action, 'app_launch_type')).assertEqual('background');
      expect(phaseProperty(action, 'app_pre_application_init_time')['start']).assertEqual(0);
      expect(phaseProperty(action, 'app_pre_application_init_time')['duration']).assertEqual(60);
      expect(phaseProperty(action, 'app_application_init_time')['start']).assertEqual(60);
      expect(phaseProperty(action, 'app_application_init_time')['duration']).assertEqual(60);
      expect(phaseProperty(action, 'app_first_frame_init_time')['start']).assertEqual(120);
      expect(phaseProperty(action, 'app_first_frame_init_time')['duration']).assertEqual(40);
    });

    it('backgroundLaunchNotifiesWithoutAction', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);
      let detectionCount = 0;
      tracker.onBackgroundLaunchDetected((): void => {
        detectionCount++;
      });

      tracker.recordApplicationInit(130);
      tracker.recordInitialVisibility('background');
      tracker.completeInitialLifecycleRound();
      tracker.markRumReady(true);

      expect(detectionCount).assertEqual(1);
      expect(reporter.actions.length).assertEqual(0);

      tracker.onBackgroundLaunchDetected((): void => {
        detectionCount++;
      });
      expect(detectionCount).assertEqual(2);
    });

    it('invalidPhaseKeepsForegroundTotal', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
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
      expect(reporter.actions.length).assertEqual(0);
      expect(tracker.getSnapshot().backgroundLaunchPendingUi).assertTrue();
      tracker.recordFirstUIAbilityCreated(180);
      tracker.recordFirstFrame(210);
      expect(reporter.actions.length).assertEqual(1);
      expect(propertyText(reporter.actions[0], 'app_launch_type')).assertEqual('background');
    });

    it('earlyExitOmitsForegroundFirstFrame', 0, () => {
      const clock = new FixedLaunchClock();
      const reporter = new RecordingLaunchReporter();
      const tracker = new FTAppLaunchTracker(clock, reporter, 100, 900);

      tracker.markRumReady(true);
      tracker.recordApplicationInit(120);
      tracker.recordFirstUIAbilityCreated(180);

      // No first frame: a foreground process that exits before drawing must not produce
      // a synthetic first-frame phase or an incomplete launch_cold Action.
      expect(reporter.actions.length).assertEqual(0);
    });
  });
}
