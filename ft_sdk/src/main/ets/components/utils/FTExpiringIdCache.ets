import { Utils } from './Utils';

/**
 * A bounded completion window. Only IDs are retained; duplicates do not extend
 * their lifetime. One timer also releases expired IDs when collection is idle.
 */
export class FTExpiringIdCache {
  private readonly entries: Map<string, number> = new Map();
  private expirationTimer: number | null = null;
  private readonly capacity: number;
  private readonly retentionMs: number;
  private readonly now: () => number;

  constructor(
    capacity: number,
    retentionMs: number,
    now: () => number = (): number => Utils.getMonotonicNanoTime() / 1000000
  ) {
    this.capacity = capacity;
    this.retentionMs = retentionMs;
    this.now = now;
  }

  public has(id: string): boolean {
    const expiresAt = this.entries.get(id);
    if (expiresAt === undefined) {
      return false;
    }
    if (expiresAt <= this.now()) {
      this.delete(id);
      return false;
    }
    return true;
  }

  public add(id: string): void {
    if (!id || this.has(id)) {
      return;
    }
    this.removeExpired();
    while (this.entries.size >= this.capacity) {
      const oldest = this.entries.keys().next().value as string | undefined;
      if (oldest === undefined) {
        break;
      }
      this.entries.delete(oldest);
    }
    this.entries.set(id, this.now() + this.retentionMs);
    this.scheduleExpiration();
  }

  public delete(id: string): void {
    this.entries.delete(id);
    if (this.entries.size === 0) {
      this.clear();
    }
  }

  public clear(): void {
    if (this.expirationTimer !== null) {
      clearTimeout(this.expirationTimer);
      this.expirationTimer = null;
    }
    this.entries.clear();
  }

  public get size(): number {
    this.removeExpired();
    return this.entries.size;
  }

  private removeExpired(): void {
    const now = this.now();
    // Monotonic insertion times keep expiration order identical to Map order.
    // Only inspect the expired prefix, rather than scan up to 5000 IDs per add.
    while (this.entries.size > 0) {
      const oldest = this.entries.keys().next().value as string;
      if (this.entries.get(oldest)! > now) { break; }
      this.entries.delete(oldest);
    }
    if (this.entries.size === 0) {
      this.clear();
    }
  }

  private scheduleExpiration(): void {
    if (this.expirationTimer !== null || this.entries.size === 0) {
      return;
    }
    const oldest = this.entries.keys().next().value as string;
    const earliest = this.entries.get(oldest)!;
    this.expirationTimer = setTimeout((): void => {
      this.expirationTimer = null;
      this.removeExpired();
      this.scheduleExpiration();
    }, Math.max(1, earliest - this.now())) as number;
  }
}
