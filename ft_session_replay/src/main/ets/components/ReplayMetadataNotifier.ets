interface PendingReplayMetadata {
  publish: () => void;
  complete: () => void;
}

/** Fixed windows coalesce counts without delaying first availability or lifecycle boundaries. */
export class ReplayMetadataNotifier {
  private readonly pending: Map<string, PendingReplayMetadata> = new Map();
  private timer: number = -1;

  public notify(key: string, immediate: boolean, publish: () => void, hold: () => (() => void)): void {
    const pending = this.pending.get(key);
    if (pending !== undefined) pending.publish = publish;
    else if (!immediate) this.pending.set(key, { publish, complete: hold() });
    if (immediate) {
      if (pending !== undefined) this.flush(key);
      else publish();
    } else if (this.timer === -1) {
      // Do not reset this timer on every frame: continuous animation must not starve persistence.
      this.timer = setTimeout((): void => {
        this.timer = -1;
        this.flush();
      }, 1_000);
    }
  }

  public flush(key?: string): void {
    const keys = key === undefined ? Array.from(this.pending.keys()) : [key];
    for (const pendingKey of keys) {
      const pending = this.pending.get(pendingKey);
      if (pending === undefined) continue;
      this.pending.delete(pendingKey);
      try { pending.publish(); } finally { pending.complete(); }
    }
    if (this.pending.size === 0 && this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }
}
