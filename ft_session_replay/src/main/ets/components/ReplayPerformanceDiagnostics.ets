import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { ReplayWorkerResult } from './SessionReplayWorkQueue';

/** Numeric aggregates only: no Inspector contents, text, or image bytes. */
export class ReplayPerformanceDiagnostics {
  private lastCounters: string = '';
  private lastReportAt: number = Date.now();
  private count: number = 0;
  private effective: number = 0;
  private nodes: number = 0;
  private handoff: number = 0;
  private maxHandoff: number = 0;
  private collection: number = 0;
  private maxCollection: number = 0;
  private wait: number = 0;
  private maxWait: number = 0;
  private materialize: number = 0;
  private resources: number = 0;
  private diff: number = 0;
  private write: number = 0;
  private maxWrite: number = 0;
  private worker: number = 0;
  private maxWorker: number = 0;
  private intervalCount: number = 0;
  private intervals: number = 0;
  private maxInterval: number = 0;
  private captureCauses: Record<string, number> = {};

  public record(result: ReplayWorkerResult | null, queuedAt: number): void {
    const timings = result?.timings;
    if (result === null || timings === undefined) return;
    this.count++;
    // Counts describe sampled frames after coalescing, not raw UI callback counts.
    const triggers = result.captureTriggers?.join('+') || 'unspecified';
    const cause = `${triggers}->${result.captureReason || 'unknown'}`;
    this.captureCauses[cause] = (this.captureCauses[cause] ?? 0) + 1;
    if (result.stored && result.records.length > 0) this.effective++;
    this.nodes += result.wireframeCount;
    this.handoff += timings.handoffMs ?? 0;
    this.maxHandoff = Math.max(this.maxHandoff, timings.handoffMs ?? 0);
    this.collection += timings.collectionMs;
    this.maxCollection = Math.max(this.maxCollection, timings.collectionMs);
    const wait = Math.max(0, timings.startedAt - queuedAt);
    this.wait += wait;
    this.maxWait = Math.max(this.maxWait, wait);
    this.materialize += timings.materializeMs;
    this.resources += timings.resourceMs;
    this.diff += timings.diffMs;
    this.write += timings.writeMs;
    this.maxWrite = Math.max(this.maxWrite, timings.writeMs);
    this.worker += timings.workerMs;
    this.maxWorker = Math.max(this.maxWorker, timings.workerMs);
    if (timings.effectiveIntervalMs > 0) {
      this.intervalCount++;
      this.intervals += timings.effectiveIntervalMs;
      this.maxInterval = Math.max(this.maxInterval, timings.effectiveIntervalMs);
    }
  }

  public report(depth: number, maxDepth: number, coalesced: number, deferred: number,
    expired: number, failures: number, force: boolean): void {
    if (!force && Date.now() - this.lastReportAt < 5000) return;
    const counters = `${coalesced}|${deferred}|${expired}|${failures}`;
    if (this.count === 0 && counters === this.lastCounters) return;
    this.lastCounters = counters;
    // Counters and maxDepth are lifetime totals; durations cover this window.
    FTSessionReplayBridgeRegistry.logDiagnostic(`Replay perf: samples=${this.count}, effective=${this.effective}, ` +
      `nodesAvg=${this.average(this.nodes)}, collectionMsAvg=${this.average(this.collection)}, collectionMsMax=${this.maxCollection}, ` +
      `handoffMsAvg=${this.average(this.handoff)}, handoffMsMax=${this.maxHandoff}, waitMsAvg=${this.average(this.wait)}, waitMsMax=${this.maxWait}, materializeMsAvg=${this.average(this.materialize)}, ` +
      `resourceMsAvg=${this.average(this.resources)}, diffMsAvg=${this.average(this.diff)}, writeMsAvg=${this.average(this.write)}, ` +
      `writeMsMax=${this.maxWrite}, workerMsAvg=${this.average(this.worker)}, workerMsMax=${this.maxWorker}, ` +
      `effectiveIntervalMsAvg=${this.intervalCount === 0 ? 0 : Math.round(this.intervals / this.intervalCount)}, ` +
      `effectiveIntervalMsMax=${this.maxInterval}, queueDepth=${depth}, maxQueueDepth=${maxDepth}, ` +
      `coalesced=${coalesced}, deferred=${deferred}, expired=${expired}, failures=${failures}, ` +
      `captureCauses=${this.formatCaptureCauses()}`);
    this.count = 0;
    this.effective = 0;
    this.nodes = 0;
    this.handoff = 0;
    this.maxHandoff = 0;
    this.collection = 0;
    this.maxCollection = 0;
    this.wait = 0;
    this.maxWait = 0;
    this.materialize = 0;
    this.resources = 0;
    this.diff = 0;
    this.write = 0;
    this.maxWrite = 0;
    this.worker = 0;
    this.maxWorker = 0;
    this.intervalCount = 0;
    this.intervals = 0;
    this.maxInterval = 0;
    this.captureCauses = {};
    this.lastReportAt = Date.now();
  }

  private formatCaptureCauses(): string {
    return Object.keys(this.captureCauses).sort()
      .map((key: string): string => `${key}:${this.captureCauses[key]}`).join('|') || 'none';
  }

  private average(total: number): number {
    return this.count === 0 ? 0 : Math.round(total / this.count * 100) / 100;
  }
}
