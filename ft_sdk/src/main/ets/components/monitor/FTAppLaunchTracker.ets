import { systemDateTime } from '@kit.BasicServicesKit';
import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { Utils } from '../utils/Utils';

const TAG = 'FTAppLaunchTracker';

export type FTAppLaunchType = 'foreground' | 'background';
export type FTAppLaunchInitialVisibility = 'foreground' | 'background' | 'unknown';

export interface FTAppLaunchClock {
  nowUptimeNs(): number;
  nowEpochNs(): number;
}

export interface FTAppLaunchAction {
  durationNs: number;
  startEpochNs: number;
  properties: Record<string, object>;
}

export interface FTAppLaunchReporter {
  report(action: FTAppLaunchAction): boolean;
}

export interface FTAppLaunchSnapshot {
  appStartUptimeNs: number;
  applicationInitUptimeNs: number;
  firstUIAbilityUptimeNs: number;
  firstFrameUptimeNs: number;
  launchType: FTAppLaunchType | null;
  initialVisibility: FTAppLaunchInitialVisibility;
  initialLifecycleRoundComplete: boolean;
  rumReady: boolean;
  reported: boolean;
}

interface FTAppLaunchPhase {
  start: number;
  duration: number;
}

class SystemAppLaunchClock implements FTAppLaunchClock {
  public nowUptimeNs(): number {
    return FTAppLaunchTracker.getStartupUptimeNs();
  }

  public nowEpochNs(): number {
    return Utils.getCurrentNanoTime();
  }
}

class RumAppLaunchReporter implements FTAppLaunchReporter {
  public report(action: FTAppLaunchAction): boolean {
    try {
      const rumManager = FTRUMInnerManager.getInstance();
      if (!rumManager) {
        FTInnerLogger.w(TAG, 'RUM manager is unavailable; keeping launch result pending');
        return false;
      }
      rumManager.addAction(
        Constants.ACTION_NAME_LAUNCH_COLD,
        Constants.ACTION_TYPE_LAUNCH_COLD,
        action.durationNs,
        action.startEpochNs,
        action.properties
      );
      return true;
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to report cold launch: ${String(error)}`);
      return false;
    }
  }
}

/**
 * Internal cold-launch state machine.
 *
 * All duration boundaries use STARTUP uptime nanoseconds. Epoch time is kept
 * only as the Action timestamp so the RUM data pipeline remains unchanged.
 */
export class FTAppLaunchTracker {
  private static instance: FTAppLaunchTracker | null = null;
  private static readonly MODULE_LOAD_START_UPTIME_NS: number = FTAppLaunchTracker.getStartupUptimeNs();
  private static readonly MODULE_LOAD_START_EPOCH_NS: number = Utils.getCurrentNanoTime();

  private readonly clock: FTAppLaunchClock;
  private readonly reporter: FTAppLaunchReporter;
  private appStartUptimeNs: number;
  private appStartEpochNs: number;
  private applicationInitUptimeNs: number = 0;
  private firstUIAbilityUptimeNs: number = 0;
  private firstFrameUptimeNs: number = 0;
  private launchType: FTAppLaunchType | null = null;
  private rumReady: boolean = false;
  private reported: boolean = false;
  private applicationForegroundObserved: boolean = false;
  private windowForegroundObserved: boolean = false;
  private initialVisibility: FTAppLaunchInitialVisibility = 'unknown';
  private initialVisibilityCaptured: boolean = false;
  private initialLifecycleRoundComplete: boolean = false;

  public constructor(
    clock: FTAppLaunchClock = new SystemAppLaunchClock(),
    reporter: FTAppLaunchReporter = new RumAppLaunchReporter(),
    startUptimeNs: number = clock.nowUptimeNs(),
    startEpochNs: number = clock.nowEpochNs()
  ) {
    this.clock = clock;
    this.reporter = reporter;
    this.appStartUptimeNs = startUptimeNs;
    this.appStartEpochNs = startEpochNs;
  }

  public static getInstance(): FTAppLaunchTracker {
    if (!FTAppLaunchTracker.instance) {
      FTAppLaunchTracker.instance = new FTAppLaunchTracker(
        new SystemAppLaunchClock(),
        new RumAppLaunchReporter(),
        FTAppLaunchTracker.MODULE_LOAD_START_UPTIME_NS,
        FTAppLaunchTracker.MODULE_LOAD_START_EPOCH_NS
      );
    }
    return FTAppLaunchTracker.instance;
  }

  /**
   * Returns one monotonic duration clock for all cold-launch phases.
   * A zero result intentionally disables duration reporting instead of falling
   * back to wall-clock time.
   */
  public static getStartupUptimeNs(): number {
    try {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to read startup uptime: ${String(error)}`);
      return 0;
    }
  }

  /** Optional app-provided T0 for applications that initialize the SDK late. */
  public setAppStartTime(uptimeNs: number): void {
    if (this.reported || uptimeNs <= 0 || this.hasRecordedBoundary()) {
      FTInnerLogger.d(TAG, `Ignoring T0 override: reported=${this.reported}, uptimeNs=${uptimeNs}, hasBoundary=${this.hasRecordedBoundary()}`);
      return;
    }
    this.appStartUptimeNs = uptimeNs;
    FTInnerLogger.d(TAG, `T0 overridden: uptimeNs=${uptimeNs}`);
  }

  /** T1: AbilityStage/application initialization. */
  public recordApplicationInit(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.applicationInitUptimeNs > 0 || uptimeNs <= 0) {
      FTInnerLogger.d(TAG, `Ignoring T1: existing=${this.applicationInitUptimeNs}, uptimeNs=${uptimeNs}`);
      return;
    }
    this.applicationInitUptimeNs = uptimeNs;
    FTInnerLogger.d(TAG, `T1 recorded: uptimeNs=${uptimeNs}`);
    this.tryReport();
  }

  /**
   * Stores the application visibility sampled at AbilityStage/service entry.
   * State-change callbacks only correct races after this snapshot; they are not
   * used as the sole source for a background cold-launch classification.
   */
  public recordInitialVisibility(visibility: FTAppLaunchInitialVisibility): void {
    if (this.initialVisibilityCaptured) {
      FTInnerLogger.d(TAG, `Ignoring initial visibility: existing=${this.initialVisibility}, incoming=${visibility}`);
      return;
    }
    this.initialVisibility = visibility;
    // A process can still be STATE_CREATE while AbilityStage runs. Keep that
    // result diagnostic-only and allow a later Service/AbilityStage context to
    // replace it with an actual foreground/background snapshot.
    if (visibility === 'unknown') {
      FTInnerLogger.d(TAG, 'Initial application visibility is unknown; awaiting a later concrete snapshot');
      return;
    }
    this.initialVisibilityCaptured = true;
    if (visibility === 'foreground') {
      this.applicationForegroundObserved = true;
    }
    FTInnerLogger.d(TAG, `Initial application visibility recorded: ${visibility}`);
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** Completes the quiescent first lifecycle round used for no-UI launches. */
  public completeInitialLifecycleRound(): void {
    if (this.initialLifecycleRoundComplete) {
      return;
    }
    this.initialLifecycleRoundComplete = true;
    FTInnerLogger.d(TAG, 'Initial lifecycle round quiescence barrier completed');
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** @deprecated Internal compatibility alias; use completeInitialLifecycleRound(). */
  public completeFirstUIAbilityRound(): void {
    this.completeInitialLifecycleRound();
  }

  /** T2: the first UIAbility.onCreate entry. */
  public recordFirstUIAbilityCreated(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.firstUIAbilityUptimeNs > 0 || uptimeNs <= 0) {
      FTInnerLogger.d(TAG, `Ignoring T2: existing=${this.firstUIAbilityUptimeNs}, uptimeNs=${uptimeNs}`);
      return;
    }
    this.firstUIAbilityUptimeNs = uptimeNs;
    this.launchType = 'foreground';
    FTInnerLogger.d(TAG, `T2 recorded: uptimeNs=${uptimeNs}`);
    this.tryReport();
  }

  /** T3: the first frame callback from the API 22 extension. */
  public recordFirstFrame(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.firstFrameUptimeNs > 0 || uptimeNs <= 0) {
      FTInnerLogger.d(TAG, `Ignoring T3: existing=${this.firstFrameUptimeNs}, uptimeNs=${uptimeNs}`);
      return;
    }
    this.firstFrameUptimeNs = uptimeNs;
    this.launchType = 'foreground';
    FTInnerLogger.d(TAG, `T3 recorded: uptimeNs=${uptimeNs}`);
    this.tryReport();
  }

  public recordApplicationForeground(): void {
    this.applicationForegroundObserved = true;
    FTInnerLogger.d(TAG, 'Application foreground signal received');
    if (this.firstUIAbilityUptimeNs > 0 || this.windowForegroundObserved) {
      this.launchType = 'foreground';
    }
  }

  public recordApplicationBackground(): void {
    FTInnerLogger.d(TAG, 'Application background signal received');
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** Window SHOWN/ACTIVE is a foreground corroboration signal. */
  public recordWindowForeground(): void {
    this.windowForegroundObserved = true;
    FTInnerLogger.d(TAG, 'Window SHOWN/ACTIVE signal received');
    if (this.firstUIAbilityUptimeNs > 0 || this.applicationForegroundObserved) {
      this.launchType = 'foreground';
    }
  }

  /** RUM can become ready after any subset of T0-T3 has already been recorded. */
  public markRumReady(enabled: boolean): void {
    this.rumReady = enabled;
    FTInnerLogger.d(TAG, `RUM Action readiness=${enabled}`);
    this.tryReport();
  }

  public getSnapshot(): FTAppLaunchSnapshot {
    return {
      appStartUptimeNs: this.appStartUptimeNs,
      applicationInitUptimeNs: this.applicationInitUptimeNs,
      firstUIAbilityUptimeNs: this.firstUIAbilityUptimeNs,
      firstFrameUptimeNs: this.firstFrameUptimeNs,
      launchType: this.launchType,
      initialVisibility: this.initialVisibility,
      initialLifecycleRoundComplete: this.initialLifecycleRoundComplete,
      rumReady: this.rumReady,
      reported: this.reported
    };
  }

  private hasRecordedBoundary(): boolean {
    return this.applicationInitUptimeNs > 0 ||
      this.firstUIAbilityUptimeNs > 0 ||
      this.firstFrameUptimeNs > 0;
  }

  private resolveBackgroundLaunchIfNeeded(): void {
    if (this.reported || this.initialVisibility !== 'background' || !this.initialLifecycleRoundComplete) {
      return;
    }
    if (this.firstUIAbilityUptimeNs > 0 || this.windowForegroundObserved || this.applicationForegroundObserved) {
      return;
    }
    this.launchType = 'background';
    FTInnerLogger.d(TAG, 'Background cold launch settled: no UI/Window appeared in first scheduling round');
    this.tryReport();
  }

  private tryReport(): void {
    if (this.reported) {
      return;
    }
    if (!this.rumReady || !this.launchType) {
      FTInnerLogger.d(TAG, `Cold launch pending: rumReady=${this.rumReady}, launchType=${this.launchType}`);
      return;
    }

    const action = this.buildAction();
    if (!action) {
      FTInnerLogger.d(TAG, `Cold launch pending: terminal boundary missing or invalid for launchType=${this.launchType}`);
      return;
    }
    this.reported = this.reporter.report(action);
    FTInnerLogger.d(TAG, `Cold launch report submitted=${this.reported}, type=${this.launchType}, durationNs=${action.durationNs}`);
  }

  private buildAction(): FTAppLaunchAction | null {
    if (this.launchType === 'foreground') {
      const total = this.createPhase(this.appStartUptimeNs, this.firstFrameUptimeNs);
      if (!total) {
        return null;
      }
      const properties = this.buildProperties();
      return {
        durationNs: total.duration,
        startEpochNs: this.appStartEpochNs,
        properties
      };
    }

    // A background-only process has no T3. Finish it at the newest valid
    // completed boundary rather than waiting forever for a frame that cannot exist.
    const completionTime = this.firstUIAbilityUptimeNs > 0
      ? this.firstUIAbilityUptimeNs
      : this.applicationInitUptimeNs;
    const total = this.createPhase(this.appStartUptimeNs, completionTime);
    if (!total) {
      return null;
    }
    return {
      durationNs: total.duration,
      startEpochNs: this.appStartEpochNs,
      properties: this.buildProperties()
    };
  }

  private buildProperties(): Record<string, object> {
    const properties: Record<string, object> = {};
    properties['app_launch_type'] = new String(this.launchType || 'foreground');

    const preApplication = this.createPhase(this.appStartUptimeNs, this.applicationInitUptimeNs);
    if (preApplication) {
      const phaseProperty: FTAppLaunchPhase = {
        start: 0,
        duration: preApplication.duration
      };
      properties['app_pre_application_init_time'] = phaseProperty;
    }

    const application = this.createPhase(this.applicationInitUptimeNs, this.firstUIAbilityUptimeNs);
    if (application) {
      const phaseProperty: FTAppLaunchPhase = {
        start: application.start - this.appStartUptimeNs,
        duration: application.duration
      };
      properties['app_application_init_time'] = phaseProperty;
    }

    const firstFrame = this.createPhase(this.firstUIAbilityUptimeNs, this.firstFrameUptimeNs);
    if (firstFrame) {
      const phaseProperty: FTAppLaunchPhase = {
        start: firstFrame.start - this.appStartUptimeNs,
        duration: firstFrame.duration
      };
      properties['app_first_frame_init_time'] = phaseProperty;
    }
    return properties;
  }

  private createPhase(start: number, end: number): FTAppLaunchPhase | null {
    if (start <= 0 || end <= start) {
      return null;
    }
    return {
      start,
      duration: end - start
    };
  }
}
