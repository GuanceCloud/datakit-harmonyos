/** Initial retry delay after a synchronous Worker mailbox post failure. */
export const SDK_WORKER_RETRY_INITIAL_DELAY_MS: number = 50;
/** Maximum delay between Worker mailbox retry attempts. */
export const SDK_WORKER_RETRY_MAX_DELAY_MS: number = 5000;
/** Consecutive failures that open the circuit and stop automatic retries. */
export const SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD: number = 8;
/** Cooldown before one half-open recovery probe is allowed. */
export const SDK_WORKER_RETRY_CIRCUIT_COOLDOWN_MS: number = 30000;

export interface SDKWorkerRetryDecision {
  shouldRetry: boolean;
  retryDelayMs: number;
  circuitOpen: boolean;
  consecutiveFailures: number;
}

export interface SDKWorkerRetryState {
  circuitOpen: boolean;
  consecutiveFailures: number;
  nextAttemptAtMs: number;
  openUntilMs: number;
  halfOpenProbeInFlight: boolean;
}

/**
 * Small Host-side circuit breaker for synchronous ThreadWorker mailbox post
 * failures. It deliberately does not retry Worker business responses: those
 * remain owned by the pool replay policy and the upload retry state machine.
 */
export class SDKWorkerRetryCircuit {
  private consecutiveFailures: number = 0;
  private nextAttemptAtMs: number = 0;
  private openUntilMs: number = 0;
  private halfOpenProbeInFlight: boolean = false;

  /** Returns false while open; after cooldown exactly one half-open probe wins. */
  public beginAttempt(nowMs: number = Date.now()): boolean {
    if (this.openUntilMs === 0) {
      return nowMs >= this.nextAttemptAtMs;
    }
    if (nowMs < this.openUntilMs || this.halfOpenProbeInFlight) {
      return false;
    }
    this.halfOpenProbeInFlight = true;
    return true;
  }

  public recordSuccess(): void {
    this.consecutiveFailures = 0;
    this.nextAttemptAtMs = 0;
    this.openUntilMs = 0;
    this.halfOpenProbeInFlight = false;
  }

  public recordFailure(nowMs: number = Date.now()): SDKWorkerRetryDecision {
    if (this.halfOpenProbeInFlight) {
      this.consecutiveFailures = SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD;
      this.openCircuit(nowMs);
      return this.createDecision(false, 0, true);
    }

    this.consecutiveFailures++;
    if (this.consecutiveFailures >= SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD) {
      this.openCircuit(nowMs);
      return this.createDecision(false, 0, true);
    }

    const exponent = Math.max(0, this.consecutiveFailures - 1);
    const delayMs = Math.min(
      SDK_WORKER_RETRY_MAX_DELAY_MS,
      SDK_WORKER_RETRY_INITIAL_DELAY_MS * Math.pow(2, exponent)
    );
    this.nextAttemptAtMs = nowMs + delayMs;
    return this.createDecision(true, delayMs, false);
  }

  public getState(nowMs: number = Date.now()): SDKWorkerRetryState {
    return {
      circuitOpen: this.openUntilMs > nowMs || this.halfOpenProbeInFlight,
      consecutiveFailures: this.consecutiveFailures,
      nextAttemptAtMs: this.nextAttemptAtMs,
      openUntilMs: this.openUntilMs,
      halfOpenProbeInFlight: this.halfOpenProbeInFlight
    };
  }

  private openCircuit(nowMs: number): void {
    this.openUntilMs = nowMs + SDK_WORKER_RETRY_CIRCUIT_COOLDOWN_MS;
    this.nextAttemptAtMs = 0;
    this.halfOpenProbeInFlight = false;
  }

  private createDecision(
    shouldRetry: boolean,
    retryDelayMs: number,
    circuitOpen: boolean
  ): SDKWorkerRetryDecision {
    return {
      shouldRetry,
      retryDelayMs,
      circuitOpen,
      consecutiveFailures: this.consecutiveFailures
    };
  }
}
