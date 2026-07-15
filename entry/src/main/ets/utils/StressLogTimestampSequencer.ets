const DEFAULT_TIMESTAMP_STEP_MS = 0.001;

/**
 * Produces unique, ascending timestamps for logs emitted faster than Date.now()
 * can distinguish them. The default step is one microsecond so large stress
 * batches remain close to their actual production time.
 */
export class StressLogTimestampSequencer {
  private lastTimestampMs: number = 0;
  private readonly stepMs: number;

  constructor(stepMs: number = DEFAULT_TIMESTAMP_STEP_MS) {
    this.stepMs = stepMs > 0 ? stepMs : DEFAULT_TIMESTAMP_STEP_MS;
  }

  public next(nowMs: number = Date.now()): number {
    if (this.lastTimestampMs <= 0) {
      this.lastTimestampMs = nowMs;
      return this.lastTimestampMs;
    }

    this.lastTimestampMs = Math.max(nowMs, this.lastTimestampMs + this.stepMs);
    return this.lastTimestampMs;
  }

  public reset(): void {
    this.lastTimestampMs = 0;
  }
}
