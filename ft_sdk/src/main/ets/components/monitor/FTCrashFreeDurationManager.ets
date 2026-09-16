import { Context } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { FTInnerLogger } from '../log/FTLogger';
import { AppState } from '../rum/enum/RUMEnums';

const TAG = 'FTCrashFreeDurationManager';

const SNAPSHOT_SCHEMA_VERSION = 1;
const BOOT_MARKER_TOLERANCE_MS = 250;
const MAX_RECOVERED_TAIL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_REPORTED_NATIVE_CRASH_IDS = 32;

/** One clock origin is used for every in-process duration boundary. */
export interface FTCrashFreeClock {
  nowUptimeNs(): number;
  nowWallClockMs(): number;
}

/** Storage is deliberately a one-value record, avoiding torn multi-key snapshots. */
export interface FTCrashFreeStorage {
  read(): Promise<string>;
  write(value: string): Promise<void>;
}

export interface FTCrashFreeDuration {
  foregroundNs: number;
  backgroundNs: number;
  reportToken: string;
  isPreCrash: boolean;
  nativeCrashId: string;
}

export interface FTCrashFreeSnapshot {
  foregroundNs: number;
  backgroundNs: number;
  state: AppState;
  stateStartUptimeNs: number;
  observedUptimeNs: number;
  observedWallClockMs: number;
  bootMarkerMs: number;
  runId: string;
}

interface FTCrashFreePersistedEnvelope {
  version: number;
  current: FTCrashFreeSnapshot | null;
  pending: FTCrashFreeSnapshot | null;
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
  private readonly store: preferences.Preferences;

  public constructor(store: preferences.Preferences) {
    this.store = store;
  }

  public async read(): Promise<string> {
    const value = await this.store.get(PreferenceCrashFreeStorage.SNAPSHOT_KEY, '');
    return typeof value === 'string' ? value : '';
  }

  public async write(value: string): Promise<void> {
    await this.store.put(PreferenceCrashFreeStorage.SNAPSHOT_KEY, value);
    await this.store.flush();
  }

  public static async create(context: Context): Promise<PreferenceCrashFreeStorage> {
    const store = await preferences.getPreferences(context, {
      name: PreferenceCrashFreeStorage.PREFERENCES_NAME
    });
    return new PreferenceCrashFreeStorage(store);
  }
}

/**
 * Process-wide foreground/background crash-free timer.
 *
 * The persisted payload contains both the currently-running interval and one
 * pending interval from the preceding process. A native crash is reported
 * after the application restarts, so retaining the pending interval until the
 * Error row is durably stored is essential.
 */
export class FTCrashFreeDurationManager {
  private static instance: FTCrashFreeDurationManager | null = null;

  private readonly clock: FTCrashFreeClock;
  private storage: FTCrashFreeStorage | null = null;
  private current: FTCrashFreeSnapshot | null = null;
  private pending: FTCrashFreeSnapshot | null = null;
  private reportedNativeCrashIds: string[] = [];
  private initialized: boolean = false;
  private readyPromise: Promise<void> = Promise.resolve();
  private operationChain: Promise<void> = Promise.resolve();
  private reportSequence: number = 0;

  public constructor(clock: FTCrashFreeClock = new SystemCrashFreeClock()) {
    this.clock = clock;
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

  /**
   * Starts asynchronous preference recovery. Callers may immediately send
   * lifecycle events: every public mutation waits for this promise in order.
   */
  public initialize(context: Context, initialState: AppState = AppState.RUN): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    this.readyPromise = PreferenceCrashFreeStorage.create(context)
      .then((storage: PreferenceCrashFreeStorage): Promise<void> => this.initializeWithStorage(storage, initialState))
      .catch((error: Error): void => {
        FTInnerLogger.w(TAG, `Crash-free persistence unavailable: ${error.message}`);
        this.startFreshState(initialState);
      });
  }

  /** Exposed for deterministic unit tests with an in-memory storage adapter. */
  public async initializeWithStorage(storage: FTCrashFreeStorage, initialState: AppState = AppState.RUN): Promise<void> {
    this.storage = storage;
    this.initialized = true;
    let envelope: FTCrashFreePersistedEnvelope | null = null;
    try {
      envelope = this.decodeEnvelope(await storage.read());
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to read crash-free snapshot: ${String(error)}`);
    }

    const nowUptimeNs = this.clock.nowUptimeNs();
    const nowWallClockMs = this.clock.nowWallClockMs();
    const validCurrent = envelope && this.isSnapshotCompatible(envelope.current, nowUptimeNs, nowWallClockMs)
      ? envelope.current
      : null;
    const validPending = envelope && this.isSnapshotCompatible(envelope.pending, nowUptimeNs, nowWallClockMs)
      ? envelope.pending
      : null;

    if (envelope && envelope.current !== null && validCurrent === null) {
      FTInnerLogger.w(TAG, 'Discarded incompatible previous-process crash-free snapshot');
    }
    if (envelope && envelope.pending !== null && validPending === null) {
      FTInnerLogger.w(TAG, 'Discarded incompatible pending crash-free snapshot');
    }

    // Never replace an unacknowledged pending crash with a later startup.
    // This makes a repeated recovery of the same native crash id idempotent.
    this.pending = validPending || validCurrent;
    this.reportedNativeCrashIds = envelope ? this.sanitizeCrashIds(envelope.reportedNativeCrashIds) : [];
    this.current = this.createFreshSnapshot(initialState, nowUptimeNs, nowWallClockMs);
    await this.persistSnapshot();
    FTInnerLogger.d(TAG, `Crash-free timer initialized: recoveredPending=${this.pending !== null}`);
  }

  /** Records an application-level foreground/background transition. */
  public transition(nextState: AppState): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      await this.readyPromise;
      this.ensureCurrentState(nextState);
      const current = this.current as FTCrashFreeSnapshot;
      const nowUptimeNs = this.clock.nowUptimeNs();
      const nowWallClockMs = this.clock.nowWallClockMs();
      this.settleCurrent(current, nowUptimeNs, nowWallClockMs);
      current.state = this.normalizeState(nextState);
      current.stateStartUptimeNs = nowUptimeNs > 0 ? nowUptimeNs : current.stateStartUptimeNs;
      current.observedUptimeNs = nowUptimeNs > 0 ? nowUptimeNs : current.observedUptimeNs;
      current.observedWallClockMs = nowWallClockMs;
      await this.persistSnapshot();
    });
  }

  /** Flushes the current interval for orderly SDK shutdown without resetting it. */
  public shutdown(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      await this.readyPromise;
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
    return this.enqueue(async (): Promise<FTCrashFreeDuration | null> => {
      await this.readyPromise;
      const normalizedState = this.normalizeState(crashState);
      const normalizedCrashId = nativeCrashId || '';
      if (isPreCrash && normalizedCrashId.length > 0 && this.reportedNativeCrashIds.includes(normalizedCrashId)) {
        return null;
      }

      let source: FTCrashFreeSnapshot | null = isPreCrash ? this.pending : this.current;
      if (!source) {
        // Native recovery happens in a new process. Its fresh interval has no
        // relationship to the crashed process and must never be reported as
        // that crash's stable-running duration.
        if (isPreCrash) {
          this.reportSequence++;
          FTInnerLogger.w(TAG, 'Native crash-free snapshot unavailable; reporting zero durations');
          return {
            foregroundNs: 0,
            backgroundNs: 0,
            reportToken: `pre:missing:${this.reportSequence}`,
            isPreCrash: true,
            nativeCrashId: normalizedCrashId
          };
        }
        this.ensureCurrentState(normalizedState);
        source = this.current;
      }
      const result = this.copySnapshot(source as FTCrashFreeSnapshot);
      if (isPreCrash) {
        const recoveredEndUptimeNs = this.resolveRecoveredCrashUptime(result, crashWallClockMs);
        this.addTail(result, recoveredEndUptimeNs, normalizedState);
      } else {
        this.addTail(result, this.clock.nowUptimeNs(), normalizedState);
      }

      this.reportSequence++;
      return {
        foregroundNs: this.nonNegativeInteger(result.foregroundNs),
        backgroundNs: this.nonNegativeInteger(result.backgroundNs),
        reportToken: `${isPreCrash ? 'pre' : 'current'}:${result.runId}:${this.reportSequence}`,
        isPreCrash,
        nativeCrashId: normalizedCrashId
      };
    });
  }

  /**
   * Called only by the durable Error write callback. It is intentionally the
   * sole reset point, so a failed database write leaves the interval intact.
   */
  public confirmCrashReported(duration: FTCrashFreeDuration): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      await this.readyPromise;
      if (duration.isPreCrash) {
        if (duration.nativeCrashId.length > 0) {
          if (!this.reportedNativeCrashIds.includes(duration.nativeCrashId)) {
            this.reportedNativeCrashIds.push(duration.nativeCrashId);
            this.reportedNativeCrashIds = this.sanitizeCrashIds(this.reportedNativeCrashIds);
          }
        }
        this.pending = null;
      } else {
        const state = this.current ? this.current.state : AppState.RUN;
        this.current = this.createFreshSnapshot(state, this.clock.nowUptimeNs(), this.clock.nowWallClockMs());
      }
      await this.persistSnapshot();
    });
  }

  /** Returns a copy for diagnostics and unit tests; it never includes a tail. */
  public getCurrentSnapshot(): Promise<FTCrashFreeSnapshot | null> {
    return this.enqueue(async (): Promise<FTCrashFreeSnapshot | null> => {
      await this.readyPromise;
      return this.current ? this.copySnapshot(this.current) : null;
    });
  }

  /** Best-effort state for synchronous crash callbacks. Duration calculation still serializes on the clock. */
  public getCurrentAppState(): AppState {
    return this.current ? this.current.state : AppState.RUN;
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operationChain.then(operation, operation);
    this.operationChain = result.then((): void => undefined, (): void => undefined);
    return result;
  }

  private startFreshState(initialState: AppState): void {
    this.current = this.createFreshSnapshot(initialState, this.clock.nowUptimeNs(), this.clock.nowWallClockMs());
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

  private async persistSnapshot(): Promise<void> {
    if (!this.storage) {
      return;
    }
    const envelope: FTCrashFreePersistedEnvelope = {
      version: SNAPSHOT_SCHEMA_VERSION,
      current: this.current ? this.copySnapshot(this.current) : null,
      pending: this.pending ? this.copySnapshot(this.pending) : null,
      reportedNativeCrashIds: this.sanitizeCrashIds(this.reportedNativeCrashIds)
    };
    try {
      await this.storage.write(JSON.stringify(envelope));
    } catch (error) {
      FTInnerLogger.w(TAG, `Unable to persist crash-free snapshot: ${String(error)}`);
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
