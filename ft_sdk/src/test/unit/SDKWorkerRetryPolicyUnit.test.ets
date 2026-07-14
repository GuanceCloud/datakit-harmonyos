import { describe, it, expect } from '@ohos/hypium';
import {
  SDK_WORKER_RETRY_CIRCUIT_COOLDOWN_MS,
  SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD,
  SDK_WORKER_RETRY_INITIAL_DELAY_MS,
  SDK_WORKER_RETRY_MAX_DELAY_MS,
  SDKWorkerRetryCircuit
} from '../../main/ets/components/thread/SDKWorkerRetryPolicy';

export default function sdkWorkerRetryPolicyUnitTest() {
  describe('SDKWorkerRetryPolicyUnit', () => {
    it('shouldBackOffExponentiallyAndOpenCircuitAtFailureThreshold', 0, () => {
      const circuit = new SDKWorkerRetryCircuit();
      let nowMs = 1000;

      for (let attempt = 1; attempt < SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD; attempt++) {
        expect(circuit.beginAttempt(nowMs)).assertTrue();
        const decision = circuit.recordFailure(nowMs);
        const expectedDelay = Math.min(
          SDK_WORKER_RETRY_MAX_DELAY_MS,
          SDK_WORKER_RETRY_INITIAL_DELAY_MS * Math.pow(2, attempt - 1)
        );
        expect(decision.shouldRetry).assertTrue();
        expect(decision.retryDelayMs).assertEqual(expectedDelay);
        expect(decision.circuitOpen).assertFalse();
        expect(circuit.beginAttempt(nowMs + expectedDelay - 1)).assertFalse();
        nowMs += expectedDelay;
      }

      expect(circuit.beginAttempt(nowMs)).assertTrue();
      const openDecision = circuit.recordFailure(nowMs);
      expect(openDecision.shouldRetry).assertFalse();
      expect(openDecision.retryDelayMs).assertEqual(0);
      expect(openDecision.circuitOpen).assertTrue();
      expect(circuit.beginAttempt(nowMs + SDK_WORKER_RETRY_CIRCUIT_COOLDOWN_MS - 1)).assertFalse();
    });

    it('shouldAllowOneHalfOpenProbeAndCloseAfterSuccess', 0, () => {
      const circuit = new SDKWorkerRetryCircuit();
      let nowMs = 2000;
      for (let attempt = 0; attempt < SDK_WORKER_RETRY_CIRCUIT_FAILURE_THRESHOLD; attempt++) {
        expect(circuit.beginAttempt(nowMs)).assertTrue();
        const decision = circuit.recordFailure(nowMs);
        if (decision.shouldRetry) {
          nowMs += decision.retryDelayMs;
        }
      }

      const recoveryTime = nowMs + SDK_WORKER_RETRY_CIRCUIT_COOLDOWN_MS;
      expect(circuit.beginAttempt(recoveryTime)).assertTrue();
      expect(circuit.beginAttempt(recoveryTime)).assertFalse();
      circuit.recordSuccess();
      expect(circuit.beginAttempt(recoveryTime)).assertTrue();
      const state = circuit.getState(recoveryTime);
      expect(state.circuitOpen).assertFalse();
      expect(state.consecutiveFailures).assertEqual(0);
    });
  });
}
