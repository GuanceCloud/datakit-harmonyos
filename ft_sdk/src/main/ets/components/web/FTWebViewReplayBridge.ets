/** Compiler/runtime contract. Tokens associate controllers with nodes, never with uploaded slots. */
export class FTWebViewReplayBridge {
  public static readonly PROPERTY: string = '__guance_replay_web_controller';
  private static readonly controllers: WeakMap<Object, string> = new WeakMap();
  private static sequence: number = 0;

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
