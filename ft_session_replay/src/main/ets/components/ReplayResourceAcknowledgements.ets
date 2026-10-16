/** Positive server acknowledgements, independent of local resource file lifetime. */
export class ReplayResourceAcknowledgements {
  private static readonly MAX_ENTRIES: number = 2048;
  private static readonly VALID_FOR_MS: number = 60 * 60 * 1000;
  private scope: string = '';
  private readonly expiresAt: Map<string, number> = new Map();

  /** Endpoint URLs include routing credentials; keep them private and never log them. */
  public setScope(scope: string): void {
    if (scope === this.scope) return;
    this.scope = scope;
    this.expiresAt.clear();
  }

  /** IDs already include the content hash and application / wgt_id route. */
  public has(id: string): boolean {
    const expiry = this.expiresAt.get(id);
    if (expiry === undefined) return false;
    if (Date.now() >= expiry) {
      this.expiresAt.delete(id);
      return false;
    }
    return true;
  }

  public remember(ids: Array<string>): void {
    const expiry = Date.now() + ReplayResourceAcknowledgements.VALID_FOR_MS;
    for (const id of ids) {
      this.expiresAt.delete(id);
      this.expiresAt.set(id, expiry);
    }
    while (this.expiresAt.size > ReplayResourceAcknowledgements.MAX_ENTRIES) {
      const oldest = this.expiresAt.keys().next();
      if (oldest.done) break;
      this.expiresAt.delete(oldest.value);
    }
  }
}
