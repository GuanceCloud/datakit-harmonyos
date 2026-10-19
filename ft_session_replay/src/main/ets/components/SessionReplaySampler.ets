import { FTSessionReplayConfig } from './FTSessionReplayConfig';

/** Sampling result is fixed once for each RUM session. */
export enum SessionReplaySamplingMode {
  NONE = 'none',
  REGULAR = 'regular',
  ERROR = 'error'
}

/**
 * Deterministic session sampler aligned with HarmonyOS's regular-then-error
 * decision order. A session never switches mode during its lifetime.
 */
export class SessionReplaySampler {
  private readonly config: FTSessionReplayConfig;
  private readonly modes: Map<string, SessionReplaySamplingMode> = new Map();

  constructor(config: FTSessionReplayConfig) {
    this.config = config;
  }

  public decide(sessionId: string): SessionReplaySamplingMode {
    const existing = this.modes.get(sessionId);
    if (existing !== undefined) {
      return existing;
    }
    let mode = SessionReplaySamplingMode.NONE;
    if (this.matchesRate(sessionId, this.config.getSampleRate())) {
      mode = SessionReplaySamplingMode.REGULAR;
    } else if (this.matchesRate(`${sessionId}:error`, this.config.getSessionReplayOnErrorSampleRate())) {
      mode = SessionReplaySamplingMode.ERROR;
    }
    this.modes.set(sessionId, mode);
    return mode;
  }

  public clear(sessionId: string): void {
    this.modes.delete(sessionId);
  }

  public reset(): void {
    this.modes.clear();
  }

  private matchesRate(value: string, rate: number): boolean {
    if (rate <= 0) {
      return false;
    }
    if (rate >= 1) {
      return true;
    }
    return this.toUnitInterval(value) < rate;
  }

  private toUnitInterval(value: string): number {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0) / 4294967296;
  }
}
