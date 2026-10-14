export interface ReplayPatternPoint { x: number; y: number; }
export interface ReplayPatternState { points: Array<number>; pointer?: ReplayPatternPoint; }
interface PatternEntry extends ReplayPatternState {
  componentId: string; x: number; y: number; side: number; radius: number;
  autoReset: boolean; skip: boolean; visible: boolean; pointerId?: number;
}

/** Window-relative gestures are modelled before snapshots cross the Worker boundary. */
export class ReplayPatternLock {
  private readonly entries: Map<number, PatternEntry> = new Map();
  private readonly pending: Map<string, Array<number>> = new Map();
  public clear(): void { this.entries.clear(); this.pending.clear(); }
  public beginFrame(): void { this.entries.forEach((entry: PatternEntry): void => { entry.visible = false; }); }
  public retain(ids: Set<number>): void {
    this.entries.forEach((_entry: PatternEntry, id: number): void => { if (!ids.has(id)) this.entries.delete(id); });
  }
  public align(id: number, x: number, y: number): void {
    const entry = this.entries.get(id);
    if (entry !== undefined) { entry.x = x; entry.y = y; }
  }

  public observe(id: number, componentId: string, x: number, y: number, side: number,
    radius: number, autoReset: boolean, skip: boolean): ReplayPatternState {
    let entry = this.entries.get(id);
    if (entry === undefined) {
      entry = { componentId, x, y, side, radius, autoReset, skip, visible: true, points: this.pending.get(componentId)?.slice() ?? [] };
      this.pending.delete(componentId);
      this.entries.set(id, entry);
      while (this.entries.size > 32) this.entries.delete(this.entries.keys().next().value as number);
    }
    entry.componentId = componentId; entry.x = x; entry.y = y; entry.side = side;
    entry.radius = radius; entry.autoReset = autoReset; entry.skip = skip; entry.visible = true;
    return { points: entry.points.slice(), pointer: entry.pointer === undefined ? undefined :
      { x: entry.pointer.x, y: entry.pointer.y } };
  }

  /** Application-owned completion and controller resets can supply the exact native state. */
  public update(componentId: string, points: Array<number>, completed: boolean = true): void {
    const clean = points.filter((point, index): boolean => Number.isInteger(point) && point >= 0 && point < 9 &&
      points.indexOf(point) === index).slice(0, 9);
    let found = false;
    this.entries.forEach((entry: PatternEntry): void => {
      if (entry.componentId !== componentId) return;
      found = true; entry.points = clean.slice();
      if (completed) { entry.pointer = undefined; entry.pointerId = undefined; }
    });
    if (!found && componentId.trim().length > 0) {
      this.pending.set(componentId, clean);
      while (this.pending.size > 32) this.pending.delete(this.pending.keys().next().value as string);
    }
  }

  public touch(type: 'down' | 'move' | 'up' | 'cancel', pointerId: number, x: number, y: number): void {
    // Reverse order matches the most recently observed, uppermost control.
    const entries = Array.from(this.entries.values()).reverse();
    for (const entry of entries) {
      if (type === 'down') {
        if (!entry.visible || entry.pointerId !== undefined || x < entry.x || y < entry.y ||
          x > entry.x + entry.side || y > entry.y + entry.side || (!entry.autoReset && entry.points.length > 0)) continue;
        entry.points = []; entry.pointerId = pointerId;
      } else if (entry.pointerId !== pointerId) continue;
      if (type === 'up' || type === 'cancel') {
        if (type === 'cancel') entry.points = [];
        entry.pointer = undefined; entry.pointerId = undefined;
        return;
      }
      entry.pointer = { x: x - entry.x, y: y - entry.y };
      const hitRadius = Math.min(entry.side / 6, Math.max(16, entry.radius * 2));
      for (let point = 0; point < 9; point++) {
        const px = (point % 3 + 0.5) * entry.side / 3;
        const py = (Math.floor(point / 3) + 0.5) * entry.side / 3;
        if (Math.hypot(entry.pointer.x - px, entry.pointer.y - py) > hitRadius || entry.points.includes(point)) continue;
        const last = entry.points[entry.points.length - 1];
        if (last !== undefined && !entry.skip) {
          const dx = point % 3 - last % 3;
          const dy = Math.floor(point / 3) - Math.floor(last / 3);
          if ((Math.abs(dx) === 2 && (dy === 0 || Math.abs(dy) === 2)) || (dx === 0 && Math.abs(dy) === 2)) {
            const middle = (point + last) / 2;
            if (!entry.points.includes(middle)) entry.points.push(middle);
          }
        }
        entry.points.push(point);
        break;
      }
      return;
    }
  }
}
