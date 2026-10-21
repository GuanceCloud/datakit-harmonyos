import { systemDateTime } from '@kit.BasicServicesKit';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { ActionSourceType } from '../rum/enum/ActionSourceType';
import { resolveAutomaticLaunchAction } from '../rum/handler/FTAutomaticActionHandler';
import { Utils } from '../utils/Utils';

const TAG = 'FTAppLaunchTracker';
// PRELOAD was introduced in API 20. Its stable value is usable without
// requiring the newer enum member in the core HAR's API 12 declarations.
const LAUNCH_REASON_PRELOAD = 11;

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
  /** true when submitted, 'filtered' when intentionally skipped, false when retryable. */
  report(action: FTAppLaunchAction): boolean | 'filtered';
}

/** Internal identity supplied by compiler-injected lifecycle calls. */
export interface FTAppLaunchSource {
  ability?: Object;
  abilityName?: string;
  intentName?: string;
  intentId?: string;
}

export interface FTAppLaunchSnapshot {
  appStartUptimeNs: number;
  applicationInitUptimeNs: number;
  firstUIAbilityUptimeNs: number;
  firstFrameUptimeNs: number;
  launchType: FTAppLaunchType | null;
  initialVisibility: FTAppLaunchInitialVisibility;
  initialLifecycleRoundComplete: boolean;
  backgroundLaunchDetected: boolean;
  launchReason: number | null;
  insightIntentExecuteMode: number | null;
  sourceResolutionPending: boolean;
  rumReady: boolean;
  reported: boolean;
  finished: boolean;
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
  public report(action: FTAppLaunchAction): boolean | 'filtered' {
    try {
      const handler = FTRUMConfigManager.getInstance().getConfig()?.getActionTrackingHandler() ?? null;
      const resolved = resolveAutomaticLaunchAction(handler, ActionSourceType.LAUNCH_COLD,
        Constants.ACTION_NAME_LAUNCH_COLD, action.properties);
      if (resolved === null) {
        FTInnerLogger.d(TAG, 'Cold launch Action filtered by action tracking handler');
        return 'filtered';
      }
      const rumManager = FTRUMInnerManager.getInstance();
      if (!rumManager) {
        FTInnerLogger.w(TAG, 'RUM manager is unavailable; keeping launch result pending');
        return false;
      }
      rumManager.addAction(
        resolved.name,
        Constants.ACTION_TYPE_LAUNCH_COLD,
        action.durationNs,
        action.startEpochNs,
        resolved.properties
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
  private finished: boolean = false;
  private applicationForegroundObserved: boolean = false;
  private windowForegroundObserved: boolean = false;
  private initialVisibility: FTAppLaunchInitialVisibility = 'unknown';
  private initialVisibilityCaptured: boolean = false;
  private initialLifecycleRoundComplete: boolean = false;
  private backgroundLaunchDetected: boolean = false;
  private launchReason: number | null = null;
  private insightIntentExecuteMode: number | null = null;
  private firstLaunchAbility: Object | null = null;
  private firstLaunchAbilityName: string = '';
  private initialIntentName: string = '';
  private initialIntentId: string = '';
  private initialDispatchOpen: boolean = false;
  private initialDispatchInvalidated: boolean = false;
  private sourceResolutionPending: boolean = false;
  private expectsInitialIntent: boolean = false;
  private reportSubmittedListeners: Array<() => void> = [];
  private finishedListeners: Array<() => void> = [];
  private backgroundLaunchDetectedListeners: Array<() => void> = [];

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

  /** Internal test seam. A process normally has exactly one cold launch. */
  public static resetInstanceInternal(): void {
    FTAppLaunchTracker.instance = null;
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

  /** Optional host-provided application-start timestamp when the SDK loads late. */
  public setAppStartTime(uptimeNs: number): void {
    if (this.finished || uptimeNs <= 0 || this.hasRecordedBoundary()) {
      return;
    }
    this.appStartUptimeNs = uptimeNs;
  }

  /** Records application initialization from AbilityStage.onCreate() or another non-UI entry. */
  public recordApplicationInit(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.applicationInitUptimeNs > 0 || uptimeNs <= 0) {
      return;
    }
    this.applicationInitUptimeNs = uptimeNs;
    FTInnerLogger.d(TAG, 'Cold launch tracking started');
    this.tryReport();
  }

  /**
   * Stores the application visibility sampled at AbilityStage/service entry.
   * State-change callbacks only correct races after this snapshot; they are not
   * used as the sole source for a background cold-launch classification.
   */
  public recordInitialVisibility(visibility: FTAppLaunchInitialVisibility): void {
    if (this.initialVisibilityCaptured) {
      return;
    }
    this.initialVisibility = visibility;
    // A process can still be STATE_CREATE while AbilityStage runs. Keep that
    // result diagnostic-only and allow a later Service/AbilityStage context to
    // replace it with an actual foreground/background snapshot.
    if (visibility === 'unknown') {
      return;
    }
    this.initialVisibilityCaptured = true;
    if (visibility === 'foreground') {
      this.applicationForegroundObserved = true;
      this.resolveForegroundFallback();
    }
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** Completes the quiescent first lifecycle round used for no-UI launches. */
  public completeInitialLifecycleRound(): void {
    if (this.initialLifecycleRoundComplete) {
      return;
    }
    this.initialLifecycleRoundComplete = true;
    if (this.initialDispatchOpen && !this.expectsInitialIntent && this.launchType === 'background') {
      // Ordinary CALL/preload entries may stay in the background without a
      // foreground transition. Their quiescent first round confirms the reason.
      this.closeInitialDispatch('initial_background_round');
    }
    this.resolveForegroundFallback();
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** @deprecated Internal compatibility alias; use completeInitialLifecycleRound(). */
  public completeFirstUIAbilityRound(): void {
    this.completeInitialLifecycleRound();
  }

  /**
   * Captures the first system launch reason in this process. UIAbility creation
   * is a timing boundary only: CALL and background intents also create one.
   * A previously settled headless background origin belongs to the process,
   * so a later UIAbility's START_ABILITY must not replace it.
   */
  public recordLaunchReason(reason: number, intentMode?: number, callToForeground: boolean = false,
    source?: FTAppLaunchSource): void {
    if (source?.ability && this.firstLaunchAbility !== null && source.ability !== this.firstLaunchAbility) {
      this.closeInitialDispatch('another_ui_ability');
    }
    if (this.finished || this.launchReason !== null || !Number.isInteger(reason) || reason < 0) {
      return;
    }
    this.launchReason = reason;
    if (this.backgroundLaunchDetected) {
      return;
    }
    this.firstLaunchAbility = source?.ability ?? null;
    this.firstLaunchAbilityName = source?.abilityName ?? '';
    this.initialIntentName = source?.intentName ?? '';
    this.initialIntentId = source?.intentId ?? '';
    this.initialDispatchOpen = this.firstLaunchAbility !== null;
    this.expectsInitialIntent = reason === AbilityConstant.LaunchReason.INSIGHT_INTENT ||
      this.initialIntentName.length > 0 || this.initialIntentId.length > 0;
    this.sourceResolutionPending = this.initialDispatchOpen || this.expectsInitialIntent;
    FTInnerLogger.d(TAG, `Launch source received: reason=${reason}, mode=${intentMode}, ` +
      `ability=${this.firstLaunchAbilityName}, intent=${this.initialIntentName}, pending=${this.sourceResolutionPending}`);
    if (this.expectsInitialIntent) {
      // Some systems deliver START_ABILITY even for an intent. Initial Want
      // identity and the real executor callback can resolve that same launch.
      this.launchType = null;
      if (intentMode === 0 || intentMode === 1) {
        this.acceptInitialIntentMode(intentMode);
      }
      return;
    }
    if (reason === AbilityConstant.LaunchReason.CALL) {
      this.setLaunchType(callToForeground ? 'foreground' : 'background');
    } else if (reason === AbilityConstant.LaunchReason.AUTO_STARTUP ||
      reason === AbilityConstant.LaunchReason.PREPARE_CONTINUATION || reason === LAUNCH_REASON_PRELOAD) {
      this.setLaunchType('background');
    } else if (reason === AbilityConstant.LaunchReason.START_ABILITY ||
      reason === AbilityConstant.LaunchReason.CONTINUATION ||
      reason === AbilityConstant.LaunchReason.APP_RECOVERY || reason === AbilityConstant.LaunchReason.SHARE) {
      this.setLaunchType('foreground');
    }
  }

  /** Real system executor mode, also supplied by the compiler-injected executor hook. */
  public recordInsightIntentExecute(mode?: number, intentName: string = '', intentId: string = '',
    abilityName: string = ''): void {
    let ignored = '';
    const exactInitialId = this.initialIntentId.length > 0 && intentId === this.initialIntentId;
    if (this.finished) {
      ignored = 'launch_finished';
    } else if (mode !== 0 && mode !== 1) {
      ignored = 'unsupported_mode';
    } else if (this.insightIntentExecuteMode !== null) {
      ignored = 'mode_already_resolved';
    } else if (this.backgroundLaunchDetected) {
      ignored = 'background_origin_already_settled';
    } else if (this.firstLaunchAbilityName.length > 0 && abilityName.length > 0 &&
      this.firstLaunchAbilityName !== abilityName) {
      ignored = 'ability_mismatch';
    } else if (this.initialIntentName.length > 0 && intentName.length > 0 &&
      this.initialIntentName !== intentName) {
      ignored = 'intent_name_mismatch';
    } else if (this.initialIntentId.length > 0 && intentId.length > 0 && !exactInitialId) {
      ignored = 'intent_id_mismatch';
    } else if (this.initialDispatchInvalidated && !exactInitialId) {
      ignored = 'initial_dispatch_closed';
    } else if (!this.initialDispatchOpen && !this.expectsInitialIntent && !exactInitialId) {
      ignored = 'no_initial_launch_association';
    }
    FTInnerLogger.d(TAG, `Intent launch mode received: mode=${mode}, reason=${this.launchReason}, ` +
      `intent=${intentName}, ability=${abilityName}, accepted=${ignored.length === 0}, ` +
      `ignored=${ignored || 'none'}, firstFrame=${this.firstFrameUptimeNs > 0}`);
    if (ignored.length > 0 || (mode !== 0 && mode !== 1)) {
      return;
    }
    this.acceptInitialIntentMode(mode);
  }

  private acceptInitialIntentMode(mode: number): void {
    // insightIntent.ExecuteMode values: UI_ABILITY_FOREGROUND=0, UI_ABILITY_BACKGROUND=1.
    // Avoid importing the API 20 executor classes into the baseline core HAR.
    this.insightIntentExecuteMode = mode;
    this.expectsInitialIntent = true;
    this.sourceResolutionPending = false;
    this.setLaunchType(mode === 0 ? 'foreground' : 'background');
  }

  /** Initial foreground dispatch follows its intent executor, when one exists. */
  public recordUIAbilityForeground(ability: Object): void {
    if (ability !== this.firstLaunchAbility || this.finished) {
      return;
    }
    this.applicationForegroundObserved = true;
    // The initial executor starts before this lifecycle callback. A later
    // callback needs an exact initial intent ID; warm background intents can
    // execute without onNewWant and must not attach to the pending launch.
    this.closeInitialDispatch('initial_foreground');
  }

  /** A new Want belongs to a later invocation, even if first-frame/RUM is still pending. */
  public recordUIAbilityNewWant(ability: Object): void {
    if (ability === this.firstLaunchAbility) {
      this.closeInitialDispatch('new_want');
    }
  }

  public recordUIAbilityBackground(ability: Object): void {
    if (ability === this.firstLaunchAbility) {
      this.closeInitialDispatch('initial_background');
    }
  }

  private closeInitialDispatch(reason: string): void {
    if (!this.initialDispatchOpen || this.finished) {
      return;
    }
    this.initialDispatchOpen = false;
    this.initialDispatchInvalidated = true;
    if (!this.expectsInitialIntent || this.insightIntentExecuteMode !== null) {
      this.sourceResolutionPending = false;
    }
    FTInnerLogger.d(TAG, `Initial launch dispatch closed: cause=${reason}, pending=${this.sourceResolutionPending}`);
    this.resolveForegroundFallback();
    if (!this.sourceResolutionPending && this.launchType === 'background' && !this.backgroundLaunchDetected) {
      this.setLaunchType('background');
    }
    this.tryReport();
  }

  /** Records entry into the first UIAbility.onCreate(). */
  public recordFirstUIAbilityCreated(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.finished || this.firstUIAbilityUptimeNs > 0 || uptimeNs <= 0) {
      return;
    }
    this.firstUIAbilityUptimeNs = uptimeNs;
    this.tryReport();
  }

  /** Records the first rendered frame observed by the API 22 extension. */
  public recordFirstFrame(uptimeNs: number = this.clock.nowUptimeNs()): void {
    if (this.finished || this.firstFrameUptimeNs > 0 || uptimeNs <= 0) {
      return;
    }
    this.firstFrameUptimeNs = uptimeNs;
    this.tryReport();
  }

  public recordApplicationForeground(): void {
    this.applicationForegroundObserved = true;
    this.resolveForegroundFallback();
  }

  public recordApplicationBackground(): void {
    this.resolveBackgroundLaunchIfNeeded();
  }

  /** Window SHOWN/ACTIVE is a foreground corroboration signal. */
  public recordWindowForeground(): void {
    this.windowForegroundObserved = true;
    this.resolveForegroundFallback();
  }

  /** RUM can become ready after application, UIAbility, or first-frame boundaries are recorded. */
  public markRumReady(enabled: boolean): void {
    this.rumReady = enabled;
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
      backgroundLaunchDetected: this.backgroundLaunchDetected,
      launchReason: this.launchReason,
      insightIntentExecuteMode: this.insightIntentExecuteMode,
      sourceResolutionPending: this.sourceResolutionPending,
      rumReady: this.rumReady,
      reported: this.reported,
      finished: this.finished
    };
  }

  /**
   * Invoked once the cold-launch Action has been accepted by the RUM pipeline.
   * Internal non-essential startup work can use this to stay out of the cold
   * launch critical path. Returns a disposer for callers that are replaced
   * before the launch reaches its terminal boundary.
   */
  public onReportSubmitted(listener: () => void): () => void {
    if (this.finished) {
      if (this.reported) {
        listener();
      }
      return (): void => {};
    }
    this.reportSubmittedListeners.push(listener);
    return (): void => {
      const index = this.reportSubmittedListeners.indexOf(listener);
      if (index >= 0) {
        this.reportSubmittedListeners.splice(index, 1);
      }
    };
  }

  /** Fires after submission or intentional filtering, so startup control-plane work can proceed. */
  public onFinished(listener: () => void): () => void {
    if (this.finished) {
      listener();
      return (): void => {};
    }
    this.finishedListeners.push(listener);
    return (): void => {
      const index = this.finishedListeners.indexOf(listener);
      if (index >= 0) {
        this.finishedListeners.splice(index, 1);
      }
    };
  }

  /**
   * Invoked when a background source is identified by its system launch reason,
   * intent mode, or the extension process-state fallback. Action submission
   * still requires the same process's first UI frame and RUM readiness.
   */
  public onBackgroundLaunchDetected(listener: () => void): () => void {
    if (this.backgroundLaunchDetected) {
      listener();
      return (): void => {};
    }
    this.backgroundLaunchDetectedListeners.push(listener);
    return (): void => {
      const index = this.backgroundLaunchDetectedListeners.indexOf(listener);
      if (index >= 0) {
        this.backgroundLaunchDetectedListeners.splice(index, 1);
      }
    };
  }

  private hasRecordedBoundary(): boolean {
    return this.applicationInitUptimeNs > 0 ||
      this.firstUIAbilityUptimeNs > 0 ||
      this.firstFrameUptimeNs > 0;
  }

  private resolveBackgroundLaunchIfNeeded(): void {
    if (this.finished || this.backgroundLaunchDetected ||
      this.sourceResolutionPending || this.expectsInitialIntent ||
      this.launchType === 'foreground' ||
      this.initialVisibility !== 'background' || !this.initialLifecycleRoundComplete) {
      return;
    }
    if (this.windowForegroundObserved || this.applicationForegroundObserved) {
      return;
    }
    this.setLaunchType('background');
  }

  private resolveForegroundFallback(): void {
    if (!this.finished && this.launchType === null && this.initialLifecycleRoundComplete &&
      !this.sourceResolutionPending && !this.expectsInitialIntent &&
      (this.applicationForegroundObserved || this.windowForegroundObserved)) {
      this.setLaunchType('foreground');
    }
  }

  private setLaunchType(type: FTAppLaunchType): void {
    this.launchType = type;
    if (type === 'background' && !this.backgroundLaunchDetected && !this.sourceResolutionPending) {
      this.backgroundLaunchDetected = true;
      FTInnerLogger.d(TAG, 'Background launch detected; waiting for the same process first UI frame and RUM readiness');
      this.notifyBackgroundLaunchDetected();
    }
    FTInnerLogger.d(TAG, `Cold launch origin: reason=${this.launchReason}, intentMode=${this.insightIntentExecuteMode}, ` +
      `type=${type}, confirmed=${!this.sourceResolutionPending}`);
    this.tryReport();
  }

  private tryReport(): void {
    if (this.finished) {
      return;
    }
    if (!this.rumReady || !this.launchType || this.sourceResolutionPending) {
      return;
    }

    const action = this.buildAction();
    if (!action) {
      return;
    }
    const result = this.reporter.report(action);
    if (result !== true && result !== 'filtered') {
      return;
    }
    this.finished = true;
    this.reported = result === true;
    // The instance is needed only while correlating the initial dispatch.
    // Do not retain the UIAbility and its Context for the SDK's lifetime.
    this.firstLaunchAbility = null;
    this.initialDispatchOpen = false;
    this.initialDispatchInvalidated = true;
    FTInnerLogger.d(TAG,
      `Cold launch action finished=${this.finished}, submitted=${this.reported}, type=${this.launchType}, durationMs=${action.durationNs / 1_000_000}`);
    if (this.reported) {
      this.notifyReportSubmitted();
    } else {
      this.reportSubmittedListeners = [];
    }
    this.notifyFinished();
  }

  private notifyFinished(): void {
    const listeners = this.finishedListeners.slice();
    this.finishedListeners = [];
    for (let index = 0; index < listeners.length; index++) {
      try {
        listeners[index]();
      } catch (error) {
        FTInnerLogger.w(TAG, `Cold-launch finish listener failed: ${String(error)}`);
      }
    }
  }

  private notifyReportSubmitted(): void {
    const listeners = this.reportSubmittedListeners.slice();
    this.reportSubmittedListeners = [];
    for (let index = 0; index < listeners.length; index++) {
      try {
        listeners[index]();
      } catch (error) {
        FTInnerLogger.w(TAG, `Cold-launch completion listener failed: ${String(error)}`);
      }
    }
  }

  private notifyBackgroundLaunchDetected(): void {
    const listeners = this.backgroundLaunchDetectedListeners.slice();
    this.backgroundLaunchDetectedListeners = [];
    for (let index = 0; index < listeners.length; index++) {
      try {
        listeners[index]();
      } catch (error) {
        FTInnerLogger.w(TAG, `Background-launch listener failed: ${String(error)}`);
      }
    }
  }

  private buildAction(): FTAppLaunchAction | null {
    // Background classification does not finish timing. A later UI in this
    // process ends the launch at its real first frame, including all time
    // spent running in the background. Never synthesize a frame for headless work.
    const total = this.createPhase(this.appStartUptimeNs, this.firstFrameUptimeNs);
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
    if (!Number.isFinite(start) || !Number.isFinite(end) || start <= 0 || end <= start) {
      return null;
    }
    return {
      start,
      duration: end - start
    };
  }
}
