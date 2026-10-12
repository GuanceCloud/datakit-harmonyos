interface MarqueeClock {
  signature: string;
  elapsed: number;
  timestamp: number;
  running: boolean;
  nativeOffset: number;
  presentationAvailable: boolean;
}

export interface ReplayMarqueeSample {
  offset: number;
  active: boolean;
}

/** Bounded UI-only fallback for RS animations whose public coordinates expose the target. */
export class ReplayMarqueeAnimation {
  private readonly clocks: Map<number, MarqueeClock> = new Map();
  private readonly seen: Set<number> = new Set();

  public clear(): void { this.clocks.clear(); this.seen.clear(); }
  public beginFrame(): void { this.seen.clear(); }
  public endFrame(): void {
    this.clocks.forEach((_clock: MarqueeClock, id: number): void => {
      if (!this.seen.has(id)) this.clocks.delete(id);
    });
  }

  public sample(id: number, inspector: Object | null, width: number, textWidth: number,
    scale: number, timestamp: number, nativeOffset: number, visible: boolean): ReplayMarqueeSample {
    this.seen.add(id);
    const info = (inspector ?? {}) as Record<string, Object>;
    const attrs = (info['$attrs'] ?? info) as Record<string, Object>;
    const start = String(attrs['start'] ?? 'false').toLowerCase() === 'true';
    const left = String(attrs['fromStart'] ?? 'true').toLowerCase() === 'true';
    let step = Number(attrs['step'] ?? 6 * scale);
    if (!Number.isFinite(step) || step <= 0 || step > textWidth * scale) step = 6 * scale;
    const parsedLoop = Number(attrs['loop'] ?? -1);
    const loops = Number.isFinite(parsedLoop) ? Math.floor(parsedLoop) : -1;
    const signature = `${String(attrs['src'] ?? '').substring(0, 16384)}|${width}|${textWidth}|${step}|${loops}|${left}`;
    let clock = this.clocks.get(id);
    if (clock === undefined || clock.signature !== signature) {
      clock = { signature, elapsed: 0, timestamp, running: start,
        nativeOffset, presentationAvailable: false };
      this.clocks.set(id, clock);
    } else {
      if (clock.running) clock.elapsed += Math.max(0, timestamp - clock.timestamp);
      const end = left ? -textWidth : width;
      if (Math.abs(nativeOffset - clock.nativeOffset) > 0.01 &&
        Math.abs(nativeOffset - end) > 0.1 && Math.abs(nativeOffset) > 0.1) clock.presentationAvailable = true;
      clock.timestamp = timestamp;
      clock.running = start;
      clock.nativeOffset = nativeOffset;
    }
    if (textWidth <= width || width <= 0 || loops === 0) return { offset: 0, active: false };
    // ArkUI uses physical-pixel step per 85 ms, with a partial first traversal
    // from zero followed by full traversals from the opposite outside edge.
    const speed = step / scale / 85;
    const firstDistance = left ? textWidth : width;
    const firstDuration = firstDistance / speed;
    const fullDuration = (width + textWidth) / speed;
    const finished = loops > 0 && clock.elapsed >= firstDuration + (loops - 1) * fullDuration;
    if (finished) return { offset: 0, active: false };
    let offset = 0;
    if (clock.elapsed < firstDuration) offset = (left ? -1 : 1) * clock.elapsed * speed;
    else {
      const progress = (clock.elapsed - firstDuration) % fullDuration;
      offset = left ? width - progress * speed : -textWidth + progress * speed;
    }
    if (clock.presentationAvailable) offset = nativeOffset;
    return { offset, active: start && visible };
  }
}
