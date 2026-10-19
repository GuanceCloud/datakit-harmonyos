/** Compiler/runtime contract. Tokens associate controllers with nodes, never with uploaded slots. */
export class FTWebViewReplayBridge {
  public static readonly PROPERTY: string = '__guance_replay_web_controller';
  private static readonly controllers: WeakMap<Object, string> = new WeakMap();
  private static sequence: number = 0;
  private static readonly pending: Array<string> = [];

  /**
   * Compiler-only synchronous pair:
   * Web(prepare(options)).customProperty(PROPERTY, consumeBindingId()).
   * Evaluate the entire options expression exactly once, including controller factories.
   * A stack also preserves an outer creation if native creation re-enters a Builder.
   */
  public static prepare(options: WebOptions): WebOptions {
    // Retain only scalar tokens, even if Web.create throws before consuming one.
    if (FTWebViewReplayBridge.pending.length >= 64) FTWebViewReplayBridge.pending.length = 0;
    FTWebViewReplayBridge.pending.push(FTWebViewReplayBridge.bindingId(options.controller));
    return options;
  }

  public static consumeBindingId(): string {
    return FTWebViewReplayBridge.pending.pop() ?? '';
  }

  /** Stable for one controller, distinct across instances, without retaining controllers. */
  public static bindingId(controller: Object): string {
    const existing = FTWebViewReplayBridge.controllers.get(controller);
    if (existing !== undefined) return existing;
    if (FTWebViewReplayBridge.sequence >= Number.MAX_SAFE_INTEGER) {
      throw new Error('Web Replay controller identity exhausted.');
    }
    const id = `__guance_web_controller_${++FTWebViewReplayBridge.sequence}`;
    FTWebViewReplayBridge.controllers.set(controller, id);
    return id;
  }
}
