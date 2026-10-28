import { Context } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { FTInnerLogger } from '../log/FTLogger';
import { AppState } from '../rum/enum/RUMEnums';
import { FTDBTaskPoolExecutor } from '../db/FTDBTaskPoolExecutor';
import {
  applyCrashFreeCommit, FTCrashFreeCommit, FTCrashFreeSnapshot, MAX_CRASH_FREE_COMMITS
} from './FTCrashFreeState';

export { FTCrashFreeSnapshot } from './FTCrashFreeState';

const TAG = 'FTCrashFreeDurationManager';

const SNAPSHOT_SCHEMA_VERSION = 1;
const BOOT_MARKER_TOLERANCE_MS = 250;
const MAX_RECOVERED_TAIL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_REPORTED_NATIVE_CRASH_IDS = 32;
const MAX_PENDING_CRASH_SNAPSHOTS = 4;

/** One clock origin is used for every in-process duration boundary. */
export interface FTCrashFreeClock {
  nowUptimeNs(): number;
  nowWallClockMs(): number;
}

/** Storage is deliberately a one-value record, avoiding torn multi-key snapshots. */
export interface FTCrashFreeStorage {
  read(): Promise<string>;
  write(value: string): Promise<void>;
  readCommits?(): Promise<FTCrashFreeCommit[]>;
}

export interface FTCrashFreeDuration {
  foregroundNs: number;
  backgroundNs: number;
  reportToken: string;
  isPreCrash: boolean;
  nativeCrashId: string;
  /** Internal acknowledgement key; never serialized into Error data. */
  recoveredSnapshotRunId: string;
  commit: FTCrashFreeCommit;
}

interface FTCrashFreePersistedEnvelope {
  version: number;
  current: FTCrashFreeSnapshot | null;
  /** Legacy single recovery snapshot retained for forward/backward compatibility. */
  pending: FTCrashFreeSnapshot | null;
  /** Ordered recovery candidates, newest first. */
  pendingSnapshots?: FTCrashFreeSnapshot[];
  reportedNativeCrashIds: string[];
}

class SystemCrashFreeClock implements FTCrashFreeClock {
  public nowUptimeNs(): number {
    try {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true);
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to read uptime clock: ${String(error)}`);
      return 0;
    }
  }

  public nowWallClockMs(): number {
    return Date.now();
  }
}

class PreferenceCrashFreeStorage implements FTCrashFreeStorage {
  private static readonly PREFERENCES_NAME = 'ft_sdk_crash_free_duration';
  private static readonly SNAPSHOT_KEY = 'ft.crash.free.duration.snapshot';
  private readonly store: preferences.Preferences | null;
  private readonly context: Context;

  public constructor(store: preferences.Preferences | null, context: Context) {
    this.store = store;
    this.context = context;
  }

  public async read(): Promise<string> {
    if (!this.store) { return ''; }
    const value = await this.store.get(PreferenceCrashFreeStorage.SNAPSHOT_KEY, '');
    return typeof value === 'string' ? value : '';
  }

  public async write(value: string): Promise<void> {
    // Durable Error receipts remain available even if Preferences is disabled.
    if (!this.store) { return; }
    await this.store.put(PreferenceCrashFreeStorage.SNAPSHOT_KEY, value);
    await this.store.flush();
  }

  public async readCommits(): Promise<FTCrashFreeCommit[]> {
    return await FTDBTaskPoolExecutor.queryCrashFreeCommits(this.context);
  }

  public static async create(context: Context): Promise<PreferenceCrashFreeStorage> {
    try {
      const store = await preferences.getPreferences(context, {
        name: PreferenceCrashFreeStorage.PREFERENCES_NAME
      });
      return new PreferenceCrashFreeStorage(store, context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Crash-free Preferences unavailable: ${String(error)}`);
      return new PreferenceCrashFreeStorage(null, context);
    }
  }
}

/**
 * Process-wide foreground/background crash-free timer.
 *
 * Native crashes and historical system-freeze events are reported after the
 * application restarts. The persisted payload retains a small, ordered set of
 * predecessor snapshots until their corresponding Error rows are durable.
 */
export class FTCrashFreeDurationManager {
  private static instance: FTCrashFreeDurationManager | null = null;

  private readonly clock: FTCrashFreeClock;
  private storage: FTCrashFreeStorage | null = null;
  private current: FTCrashFreeSnapshot | null = null;
  private pendingSnapshots: FTCrashFreeSnapshot[] = [];
  private reportedNativeCrashIds: string[] = [];
  private currentProcessStartedWallClockMs: number = 0;
  private initialized: boolean = false;
  private readyPromise: Promise<void> = Promise.resolve();
  private operationChain: Promise<void> = Promise.resolve();
  private lastObservedState: AppState = AppState.UNKNOWN;
  private initialUptimeNs: number = 0;
  private initialWallClockMs: number = 0;
  private confirmedReportTokens: Set<string> = new Set<string>();

  public constructor(clock: FTCrashFreeClock = new SystemCrashFreeClock()) {
    this.clock = clock;
    this.captureInitialBoundary();
  }

  public static getInstance(): FTCrashFreeDurationManager {
    if (FTCrashFreeDurationManager.instance === null) {
      FTCrashFreeDurationManager.instance = new FTCrashFreeDurationManager();
    }
    return FTCrashFreeDurationManager.instance;
  }

  /** Test seam. Production code owns one instance for the process lifetime. */
  public static resetInstanceInternal(): void {
    FTCrashFreeDurationManager.instance = null;
  }

  /** Test seam for lifecycle tests that need a deterministic monotonic clock. */
  public static setInstanceForTesting(instance: FTCrashFreeDurationManager | null): void {
    FTCrashFreeDurationManager.instance = instance;
  }

  /**
   * Starts asynchronous preference recovery. Callers may immediately send
   * lifecycle events: every public mutation waits for this promise in order.
   */
  public initialize(context: Context, initialState: AppState = AppState.UNKNOWN): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    this.captureInitialBoundary();
    this.readyPromise = PreferenceCrashFreeStorage.create(context)
      .then((storage: PreferenceCrashFreeStorage): Promise<void> => this.initializeWithStorage(storage, initialState));
    // Keep the rejected recovery gate: a failed receipt read must not allow
    // unverified historical reports through. Lifecycle callers handle failures.
    this.readyPromise.catch((error: Error): void => {
      FTInnerLogger.w(TAG, `Crash-free recovery unavailable: ${error.message}`);
    });
  }

  /** Exposed for deterministic unit tests with an in-memory storage adapter. */
  public async initializeWithStorage(storage: FTCrashFreeStorage, initialState: AppState = AppState.UNKNOWN): Promise<void> {
    this.captureInitialBoundary();
    this.storage = storage;
    this.initialized = true;
    let envelope: FTCrashFreePersistedEnvelope | null = null;
    try {
      envelope = this.decodeEnvelope(await storage.read());
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to read crash-free snapshot: ${String(error)}`);
    }

    const commits = storage.readCommits ? await storage.readCommits() : [];
    if (envelope) {
      envelope.current = this.replayCommits(envelope.current, commits);
      envelope.pending = this.replayCommits(envelope.pending, commits);
      const pending: FTCrashFreeSnapshot[] = [];
      for (const snapshot of envelope.pendingSnapshots || []) {
        const recovered = this.replayCommits(snapshot, commits);
        if (recovered) { pending.push(recovered); }
      }
      envelope.pendingSnapshots = pending;
    }
    for (const commit of commits) { this.rememberConfirmedToken(commit.reportToken); }
    const nowUptimeNs = this.clock.nowUptimeNs();
    const nowWallClockMs = this.clock.nowWallClockMs();
    this.pendingSnapshots = this.collectCompatibleRecoverySnapshots(envelope, nowUptimeNs, nowWallClockMs);
    this.reportedNativeCrashIds = envelope ? this.sanitizeCrashIds(envelope.reportedNativeCrashIds) : [];
    this.reportedNativeCrashIds = this.sanitizeCrashIds(this.reportedNativeCrashIds.concat(
      commits.map((commit: FTCrashFreeCommit): string => commit.nativeCrashId)));
    this.currentProcessStartedWallClockMs = this.nonNegativeInteger(this.initialWallClockMs);
    // Early lifecycle events may have already established a timeline. Never
    // overwrite it when asynchronous Preferences recovery finally completes.
    if (!this.current && this.lastObservedState === AppState.UNKNOWN && this.isDurationState(initialState)) {
      this.lastObservedState = initialState;
      this.current = this.createFreshSnapshot(initialState, this.initialUptimeNs, this.initialWallClockMs);
    }
    await this.persistSnapshot();
    FTInnerLogger.d(TAG, `Crash-free timer initialized: recoveredPending=${this.pendingSnapshots.length > 0}`);
  }

  /** Records an application-level foreground/background transition. */
  public transition(nextState: AppState): Promise<void> {
    const uptimeNs = this.clock.nowUptimeNs();
    const wallClockMs = this.clock.nowWallClockMs();
    this.lastObservedState = this.normalizeState(nextState);
    return this.enqueue(async (): Promise<void> => {
      await this.awaitReady();
      if (!this.current) {
        this.current = this.createFreshSnapshot(nextState, uptimeNs, wallClockMs);
      }
      const current = this.current as FTCrashFreeSnapshot;
      const nowUptimeNs = Math.max(uptimeNs, current.stateStartUptimeNs);
      const nowWallClockMs = Math.max(wallClockMs, current.observedWallClockMs);
      this.settleCurrent(current, nowUptimeNs, nowWallClockMs);
      current.state = this.normalizeState(nextState);
      current.stateStartUptimeNs = nowUptimeNs > 0 ? nowUptimeNs : current.stateStartUptimeNs;
      current.observedUptimeNs = nowUptimeNs > 0 ? nowUptimeNs : current.observedUptimeNs;
      current.observedWallClockMs = nowWallClockMs;
      await this.persistSnapshot();
    });
  }

  /** A visibility query must not override a more recent lifecycle signal. */
  public recordInitialAppState(state: AppState): Promise<void> {
    if (!this.isDurationState(state) || this.lastObservedState !== AppState.UNKNOWN) {
      return Promise.resolve();
    }
    this.lastObservedState = state;
    this.captureInitialBoundary();
    return this.enqueue(async (): Promise<void> => {
      await this.awaitReady();
      if (!this.current) {
        this.current = this.createFreshSnapshot(state, this.initialUptimeNs, this.initialWallClockMs);
        await this.persistSnapshot();
      }
    });
  }

  /** Flushes the current interval for orderly SDK shutdown without resetting it. */
  public shutdown(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      await this.awaitReady();
      if (!this.current) {
        return;
      }
      this.settleCurrent(this.current, this.clock.nowUptimeNs(), this.clock.nowWallClockMs());
      await this.persistSnapshot();
    });
  }

  /**
   * Creates the two Error field values. A current-process crash reads the
   * monotonic uptime directly; a recovered native crash safely bridges its
   * persisted boundary with the native event's wall-clock timestamp.
   */
  public prepareCrashFreeDuration(
    crashState: AppState,
    isPreCrash: boolean,
    crashWallClockMs: number = 0,
    nativeCrashId: string = ''
  ): Promise<FTCrashFreeDuration | null> {
    const crashUptimeNs = this.clock.nowUptimeNs();
    const reportWallClockMs = this.clock.nowWallClockMs();
    return this.enqueue(async (): Promise<FTCrashFreeDuration | null> => {
      await this.awaitReady();
      // A fallback spool can durably finish an earlier Error without its
      // original callback. Reconcile it before selecting the next cycle.
      await this.refreshCommittedReports(crashUptimeNs, reportWallClockMs);
      const normalizedState = this.normalizeState(crashState);
      const normalizedCrashId = nativeCrashId || '';
      const isRecoveredCrash = isPreCrash || this.isCrashFromPreviousProcess(crashWallClockMs);
      if (isRecoveredCrash && normalizedCrashId.length > 0 && this.reportedNativeCrashIds.includes(normalizedCrashId)) {
        return null;
      }

      let source: FTCrashFreeSnapshot | null = isRecoveredCrash ?
        this.selectRecoverySnapshot(crashWallClockMs) : this.current;
      if (!source) {
        // Recovery happens in a new process. Its fresh interval has no
        // relationship to the crashed process and must never be reported as
        // that crash's stable-running duration.
        if (isRecoveredCrash) {
          FTInnerLogger.w(TAG, 'Recovered crash-free snapshot unavailable; reporting zero durations');
          const reportToken = `pre:${normalizedCrashId || crashWallClockMs}`;
          return {
            foregroundNs: 0,
            backgroundNs: 0,
            reportToken,
            isPreCrash: true,
            nativeCrashId: normalizedCrashId,
            recoveredSnapshotRunId: '',
            commit: { reportToken, sourceRunId: '', nativeCrashId: normalizedCrashId,
              recoveredSnapshotRunId: '', foregroundNs: 0, backgroundNs: 0, next: null }
          };
        }
        this.ensureCurrentState(normalizedState);
        source = this.current;
      }
      const result = this.copySnapshot(source as FTCrashFreeSnapshot);
      const resetBoundary = this.copySnapshot(result);
      if (isRecoveredCrash) {
        const recoveredEndUptimeNs = this.resolveRecoveredCrashUptime(result, crashWallClockMs);
        this.addTail(result, recoveredEndUptimeNs, normalizedState);
      } else {
        this.addTail(result, crashUptimeNs, normalizedState);
        // Error's supplied state owns its tail, but subtract the actual
        // tracked prefix when advancing the live timeline. These may differ
        // when a terminal callback precedes its queued lifecycle notification.
        this.addTail(resetBoundary, crashUptimeNs, resetBoundary.state);
      }

      const reportToken = isRecoveredCrash ? `pre:${normalizedCrashId || `${result.runId}:${crashWallClockMs}`}` :
        `current:${result.runId}`;
      const duration: FTCrashFreeDuration = {
        foregroundNs: this.nonNegativeInteger(result.foregroundNs),
        backgroundNs: this.nonNegativeInteger(result.backgroundNs),
        reportToken,
        isPreCrash: isRecoveredCrash,
        nativeCrashId: normalizedCrashId,
        recoveredSnapshotRunId: isRecoveredCrash ? result.runId : '',
        commit: {
          reportToken, sourceRunId: result.runId, nativeCrashId: normalizedCrashId,
          recoveredSnapshotRunId: isRecoveredCrash ? result.runId : '',
          foregroundNs: this.nonNegativeInteger(resetBoundary.foregroundNs),
          backgroundNs: this.nonNegativeInteger(resetBoundary.backgroundNs),
          next: isRecoveredCrash ? null : this.createFreshSnapshot(result.state,
            result.observedUptimeNs, reportWallClockMs)
        }
      };
      return duration;
    });
  }

  /**
   * Called only by the durable Error write callback. It is intentionally the
   * sole reset point, so a failed database write leaves the interval intact.
   */
  public confirmCrashReported(duration: FTCrashFreeDuration): Promise<boolean> {
    return this.enqueue(async (): Promise<boolean> => {
      await this.awaitReady();
      if (this.confirmedReportTokens.has(duration.reportToken)) {
        await this.persistSnapshot(true);
        return false;
      }
      const commits = this.storage?.readCommits ? await this.storage.readCommits() : [];
      const durableCommit = commits.find((item: FTCrashFreeCommit): boolean => item.reportToken === duration.reportToken);
      if (this.storage?.readCommits && !durableCommit) {
        throw new Error('Crash-free reset requires a durable Error receipt');
      }
      const commit = durableCommit || duration.commit;
      if (duration.isPreCrash) {
        if (duration.nativeCrashId.length > 0) {
          if (!this.reportedNativeCrashIds.includes(duration.nativeCrashId)) {
            this.reportedNativeCrashIds.push(duration.nativeCrashId);
            this.reportedNativeCrashIds = this.sanitizeCrashIds(this.reportedNativeCrashIds);
          }
        }
        this.removeRecoverySnapshot(duration.recoveredSnapshotRunId);
      } else {
        if (!this.current || this.current.runId !== commit.sourceRunId) { return false; }
        this.settleCurrent(this.current, this.clock.nowUptimeNs(), this.clock.nowWallClockMs());
        this.current = applyCrashFreeCommit(this.current, commit);
      }
      this.rememberConfirmedToken(duration.reportToken);
      await this.persistSnapshot(true);
      return true;
    });
  }

  /** Returns a copy for diagnostics and unit tests; it never includes a tail. */
  public getCurrentSnapshot(): Promise<FTCrashFreeSnapshot | null> {
    return this.enqueue(async (): Promise<FTCrashFreeSnapshot | null> => {
      await this.awaitReady();
      return this.current ? this.copySnapshot(this.current) : null;
    });
  }

  /** Best-effort state for synchronous crash callbacks. Duration calculation still serializes on the clock. */
  public getCurrentAppState(): AppState {
    return this.lastObservedState;
  }

  private captureInitialBoundary(): void {
    if (this.initialWallClockMs === 0) {
      this.initialUptimeNs = this.clock.nowUptimeNs();
      this.initialWallClockMs = this.clock.nowWallClockMs();
    }
  }

  private rememberConfirmedToken(token: string): void {
    this.confirmedReportTokens.add(token);
    while (this.confirmedReportTokens.size > MAX_CRASH_FREE_COMMITS) {
      this.confirmedReportTokens.delete(this.confirmedReportTokens.values().next().value);
    }
  }

  private replayCommits(snapshot: FTCrashFreeSnapshot | null, commits: FTCrashFreeCommit[]): FTCrashFreeSnapshot | null {
    let result = snapshot;
    for (const commit of commits) {
      if (result) { result = applyCrashFreeCommit(result, commit); }
    }
    return result;
  }

  private async refreshCommittedReports(uptimeNs: number, wallClockMs: number): Promise<void> {
    if (!this.storage?.readCommits) { return; }
    const commits = await this.storage.readCommits();
    if (this.current && commits.some((commit: FTCrashFreeCommit): boolean =>
      commit.sourceRunId === this.current!.runId && commit.next !== null)) {
      this.settleCurrent(this.current, uptimeNs, wallClockMs);
      this.current = this.replayCommits(this.current, commits);
    }
    const pending: FTCrashFreeSnapshot[] = [];
    for (const snapshot of this.pendingSnapshots) {
      const recovered = this.replayCommits(snapshot, commits);
      if (recovered) { pending.push(recovered); }
    }
    this.pendingSnapshots = pending;
    for (const commit of commits) { this.rememberConfirmedToken(commit.reportToken); }
    this.reportedNativeCrashIds = this.sanitizeCrashIds(this.reportedNativeCrashIds.concat(
      commits.map((commit: FTCrashFreeCommit): string => commit.nativeCrashId)));
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operationChain.then(operation, operation);
    this.operationChain = result.then((): void => undefined, (): void => undefined);
    return result;
  }

  private async awaitReady(): Promise<void> {
    try {
      await this.readyPromise;
    } catch (error) {
      if (!this.storage) { throw new Error(String(error)); }
      // A transient cache read failure must not disable crash collection for
      // the remaining process lifetime. Retry through the same serialized gate.
      this.readyPromise = this.initializeWithStorage(this.storage);
      await this.readyPromise;
    }
  }

  private startFreshState(initialState: AppState): void {
    this.captureInitialBoundary();
    this.lastObservedState = this.normalizeState(initialState);
    const nowWallClockMs = this.clock.nowWallClockMs();
    this.currentProcessStartedWallClockMs = this.nonNegativeInteger(nowWallClockMs);
    this.current = this.createFreshSnapshot(initialState, this.clock.nowUptimeNs(), nowWallClockMs);
  }

  private ensureCurrentState(initialState: AppState): void {
    if (!this.current) {
      this.startFreshState(initialState);
    }
  }

  private createFreshSnapshot(state: AppState, uptimeNs: number, wallClockMs: number): FTCrashFreeSnapshot {
    const safeUptimeNs = this.nonNegativeInteger(uptimeNs);
    return {
      foregroundNs: 0,
      backgroundNs: 0,
      state: this.normalizeState(state),
      stateStartUptimeNs: safeUptimeNs,
      observedUptimeNs: safeUptimeNs,
      observedWallClockMs: this.nonNegativeInteger(wallClockMs),
      bootMarkerMs: this.calculateBootMarkerMs(safeUptimeNs, wallClockMs),
      runId: this.createRunId()
    };
  }

  private settleCurrent(snapshot: FTCrashFreeSnapshot, uptimeNs: number, wallClockMs: number): void {
    this.addTail(snapshot, uptimeNs, snapshot.state);
    if (uptimeNs > 0) {
      snapshot.stateStartUptimeNs = uptimeNs;
      snapshot.observedUptimeNs = uptimeNs;
    }
    snapshot.observedWallClockMs = this.nonNegativeInteger(wallClockMs);
    snapshot.bootMarkerMs = this.calculateBootMarkerMs(snapshot.observedUptimeNs, wallClockMs);
  }

  private addTail(snapshot: FTCrashFreeSnapshot, endUptimeNs: number, state: AppState): void {
    const safeEndUptimeNs = this.nonNegativeInteger(endUptimeNs);
    if (safeEndUptimeNs <= 0 || safeEndUptimeNs < snapshot.stateStartUptimeNs) {
      return;
    }
    // The platform clock can be unavailable very early in process startup.
    // Do not turn a later successful clock read into an interval from boot.
    if (snapshot.stateStartUptimeNs <= 0) {
      snapshot.stateStartUptimeNs = safeEndUptimeNs;
      snapshot.observedUptimeNs = safeEndUptimeNs;
      return;
    }
    const durationNs = safeEndUptimeNs - snapshot.stateStartUptimeNs;
    if (this.normalizeState(state) === AppState.BACKGROUND) {
      snapshot.backgroundNs = this.safeAdd(snapshot.backgroundNs, durationNs);
    } else {
      snapshot.foregroundNs = this.safeAdd(snapshot.foregroundNs, durationNs);
    }
    snapshot.stateStartUptimeNs = safeEndUptimeNs;
    snapshot.observedUptimeNs = safeEndUptimeNs;
  }

  private resolveRecoveredCrashUptime(snapshot: FTCrashFreeSnapshot, crashWallClockMs: number): number {
    const safeCrashWallClockMs = this.nonNegativeInteger(crashWallClockMs);
    if (safeCrashWallClockMs <= 0 || safeCrashWallClockMs < snapshot.observedWallClockMs) {
      return 0;
    }
    const elapsedMs = safeCrashWallClockMs - snapshot.observedWallClockMs;
    if (elapsedMs > MAX_RECOVERED_TAIL_MS) {
      return 0;
    }
    return this.safeAdd(snapshot.observedUptimeNs, elapsedMs * 1000000);
  }

  private async persistSnapshot(strict: boolean = false): Promise<void> {
    if (!this.storage) {
      return;
    }
    const envelope: FTCrashFreePersistedEnvelope = {
      version: SNAPSHOT_SCHEMA_VERSION,
      current: this.current ? this.copySnapshot(this.current) : null,
      pending: this.pendingSnapshots.length > 0 ? this.copySnapshot(this.pendingSnapshots[0]) : null,
      pendingSnapshots: this.copySnapshots(this.pendingSnapshots),
      reportedNativeCrashIds: this.sanitizeCrashIds(this.reportedNativeCrashIds)
    };
    try {
      await this.storage.write(JSON.stringify(envelope));
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to persist crash-free snapshot: ${String(error)}`);
      if (strict) { throw new Error(String(error)); }
    }
  }

  private decodeEnvelope(value: string): FTCrashFreePersistedEnvelope | null {
    if (!value || value.length === 0) {
      return null;
    }
    try {
      const decoded = JSON.parse(value) as FTCrashFreePersistedEnvelope;
      if (!decoded || decoded.version !== SNAPSHOT_SCHEMA_VERSION) {
        return null;
      }
      return {
        version: SNAPSHOT_SCHEMA_VERSION,
        current: decoded.current || null,
        pending: decoded.pending || null,
        pendingSnapshots: Array.isArray(decoded.pendingSnapshots) ? decoded.pendingSnapshots : [],
        reportedNativeCrashIds: this.sanitizeCrashIds(decoded.reportedNativeCrashIds || [])
      };
    } catch (error) {
      FTInnerLogger.w(TAG, `Discarding malformed crash-free snapshot: ${String(error)}`);
      return null;
    }
  }

  private isSnapshotCompatible(snapshot: FTCrashFreeSnapshot | null, nowUptimeNs: number, nowWallClockMs: number): boolean {
    if (!snapshot || !this.isDurationState(snapshot.state) || !snapshot.runId ||
      !this.isNonNegativeNumber(snapshot.foregroundNs) || !this.isNonNegativeNumber(snapshot.backgroundNs) ||
      !this.isNonNegativeNumber(snapshot.stateStartUptimeNs) || !this.isNonNegativeNumber(snapshot.observedUptimeNs) ||
      !this.isNonNegativeNumber(snapshot.observedWallClockMs) || !this.isNonNegativeNumber(snapshot.bootMarkerMs) ||
      snapshot.observedUptimeNs < snapshot.stateStartUptimeNs || nowUptimeNs < snapshot.observedUptimeNs) {
      return false;
    }
    const currentBootMarker = this.calculateBootMarkerMs(nowUptimeNs, nowWallClockMs);
    return Math.abs(currentBootMarker - snapshot.bootMarkerMs) <= BOOT_MARKER_TOLERANCE_MS;
  }

  /**
   * Keeps every valid predecessor available until its own Error is confirmed.
   * Selecting by event time avoids a stale failed recovery shadowing a newer
   * crash when two processes terminate before either report can be persisted.
   */
  private collectCompatibleRecoverySnapshots(
    envelope: FTCrashFreePersistedEnvelope | null,
    nowUptimeNs: number,
    nowWallClockMs: number
  ): FTCrashFreeSnapshot[] {
    if (envelope === null) {
      return [];
    }
    const candidates: FTCrashFreeSnapshot[] = [];
    const pendingSnapshots = envelope.pendingSnapshots || [];
    for (let index = 0; index < pendingSnapshots.length; index++) {
      candidates.push(pendingSnapshots[index]);
    }
    if (envelope.pending !== null) {
      candidates.push(envelope.pending);
    }
    if (envelope.current !== null) {
      candidates.push(envelope.current);
    }

    const compatible: FTCrashFreeSnapshot[] = [];
    for (let index = 0; index < candidates.length; index++) {
      const snapshot = candidates[index];
      if (!this.isSnapshotCompatible(snapshot, nowUptimeNs, nowWallClockMs)) {
        FTInnerLogger.w(TAG, 'Discarded incompatible previous-process crash-free snapshot');
        continue;
      }
      if (!compatible.some((item: FTCrashFreeSnapshot): boolean => item.runId === snapshot.runId)) {
        compatible.push(this.copySnapshot(snapshot));
      }
    }
    compatible.sort((left: FTCrashFreeSnapshot, right: FTCrashFreeSnapshot): number =>
      right.observedWallClockMs - left.observedWallClockMs
    );
    return compatible.slice(0, MAX_PENDING_CRASH_SNAPSHOTS);
  }

  private isCrashFromPreviousProcess(crashWallClockMs: number): boolean {
    const safeCrashWallClockMs = this.nonNegativeInteger(crashWallClockMs);
    return safeCrashWallClockMs > 0 && this.currentProcessStartedWallClockMs > 0 &&
      safeCrashWallClockMs < this.currentProcessStartedWallClockMs;
  }

  private selectRecoverySnapshot(crashWallClockMs: number): FTCrashFreeSnapshot | null {
    if (this.pendingSnapshots.length === 0) {
      return null;
    }
    const safeCrashWallClockMs = this.nonNegativeInteger(crashWallClockMs);
    if (safeCrashWallClockMs <= 0) {
      return this.pendingSnapshots[0];
    }
    for (let index = 0; index < this.pendingSnapshots.length; index++) {
      const snapshot = this.pendingSnapshots[index];
      if (snapshot.observedWallClockMs <= safeCrashWallClockMs) {
        return snapshot;
      }
    }
    return null;
  }

  private removeRecoverySnapshot(runId: string): void {
    if (runId.length === 0) {
      return;
    }
    this.pendingSnapshots = this.pendingSnapshots.filter((snapshot: FTCrashFreeSnapshot): boolean => snapshot.runId !== runId);
  }

  private isDurationState(state: AppState): boolean {
    return state === AppState.RUN || state === AppState.BACKGROUND;
  }

  private normalizeState(state: AppState): AppState {
    return state === AppState.BACKGROUND ? AppState.BACKGROUND : AppState.RUN;
  }

  private calculateBootMarkerMs(uptimeNs: number, wallClockMs: number): number {
    return this.nonNegativeInteger(wallClockMs) - Math.floor(this.nonNegativeInteger(uptimeNs) / 1000000);
  }

  private copySnapshot(snapshot: FTCrashFreeSnapshot): FTCrashFreeSnapshot {
    return {
      foregroundNs: this.nonNegativeInteger(snapshot.foregroundNs),
      backgroundNs: this.nonNegativeInteger(snapshot.backgroundNs),
      state: this.normalizeState(snapshot.state),
      stateStartUptimeNs: this.nonNegativeInteger(snapshot.stateStartUptimeNs),
      observedUptimeNs: this.nonNegativeInteger(snapshot.observedUptimeNs),
      observedWallClockMs: this.nonNegativeInteger(snapshot.observedWallClockMs),
      bootMarkerMs: snapshot.bootMarkerMs,
      runId: snapshot.runId
    };
  }

  private copySnapshots(snapshots: FTCrashFreeSnapshot[]): FTCrashFreeSnapshot[] {
    const copies: FTCrashFreeSnapshot[] = [];
    for (let index = 0; index < snapshots.length; index++) {
      copies.push(this.copySnapshot(snapshots[index]));
    }
    return copies;
  }

  private sanitizeCrashIds(ids: string[]): string[] {
    const result: string[] = [];
    for (let index = Math.max(0, ids.length - MAX_REPORTED_NATIVE_CRASH_IDS); index < ids.length; index++) {
      const id = ids[index];
      if (id && id.length > 0 && !result.includes(id)) {
        result.push(id);
      }
    }
    return result;
  }

  private createRunId(): string {
    const uptimeNs = this.clock.nowUptimeNs();
    return `${this.clock.nowWallClockMs()}-${uptimeNs}-${Math.floor(Math.random() * 1000000000)}`;
  }

  private safeAdd(left: number, right: number): number {
    return this.nonNegativeInteger(left) + this.nonNegativeInteger(right);
  }

  private nonNegativeInteger(value: number): number {
    if (!this.isNonNegativeNumber(value)) {
      return 0;
    }
    return Math.floor(value);
  }

  private isNonNegativeNumber(value: number): boolean {
    return Number.isFinite(value) && value >= 0;
  }
}
