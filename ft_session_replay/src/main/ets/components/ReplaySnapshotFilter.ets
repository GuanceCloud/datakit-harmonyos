import { ArkUIReplayLightSnapshot } from './SessionReplayScene';
import { copyReplayValue, replayValuesEqual } from './ReplayWireframeValues';
import { ReplaySnapshotKind, ReplayWorkerCapture } from './SessionReplayWorkQueue';

/** Conservative UI-side filter; only an acknowledged, idle FIFO can suppress a sample. */
export class ReplaySnapshotFilter {
  // A bounded Worker probe still detects reclaimed storage or a restarted Worker.
  private static readonly MAX_SKIP_WINDOW_MS: number = 1000;
  private snapshot: ArkUIReplayLightSnapshot | null = null;
  private capture: ReplayWorkerCapture | null = null;
  private generation: number = -1;
  private revision: number = 0;

  public getRevision(): number { return this.revision; }

  public invalidate(): void {
    this.revision++;
    this.snapshot = null;
    this.capture = null;
  }

  public canSkip(kind: ReplaySnapshotKind, next: ArkUIReplayLightSnapshot,
    capture: ReplayWorkerCapture, generation: number, queueIdle: boolean): boolean {
    const previous = this.snapshot;
    const previousCapture = this.capture;
    if (kind !== 'automatic' || !queueIdle || previous === null || previousCapture === null ||
      generation !== this.generation || next.hasActiveAnimations === true || previous.hasActiveAnimations === true) return false;
    const age = next.timestamp - previous.timestamp;
    if (age < 0 || age >= ReplaySnapshotFilter.MAX_SKIP_WINDOW_MS) return false;
    return capture.storeKind === previousCapture.storeKind &&
      replayValuesEqual(capture.context, previousCapture.context) &&
      replayValuesEqual(capture.viewport, previousCapture.viewport) &&
      next.vpToPxScale === previous.vpToPxScale && replayValuesEqual(next.nodes, previous.nodes);
  }

  public acknowledge(snapshot: ArkUIReplayLightSnapshot, capture: ReplayWorkerCapture,
    generation: number, revision: number): void {
    // A resource/manual update can arrive while this sample is in flight.
    if (revision !== this.revision) return;
    // Inspector/scene objects may be reused by the next UI pass. Never retain their aliases.
    this.snapshot = copyReplayValue(snapshot) as ArkUIReplayLightSnapshot;
    this.capture = copyReplayValue(capture) as ReplayWorkerCapture;
    this.generation = generation;
  }
}
