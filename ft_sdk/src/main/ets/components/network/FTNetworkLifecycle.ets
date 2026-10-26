import { FTInnerLogger } from '../log/FTLogger';

/** Internal transport owners. The registry must never keep a client/request alive. */
export interface FTNetworkDisposable {
  dispose(): void;
}

export class FTNetworkLifecycle {
  private static generation: number = 0;
  private static running: boolean = true;
  private static sequence: number = 0;
  private static owners: Map<number, WeakRef<FTNetworkDisposable>> = new Map();
  private static requests: Map<string, Set<number>> = new Map();
  private static requestByOwner: Map<number, string> = new Map();

  public static capture(): number { return FTNetworkLifecycle.generation; }
  public static isCurrent(generation: number): boolean {
    return FTNetworkLifecycle.running && generation === FTNetworkLifecycle.generation;
  }
  public static resume(): void { FTNetworkLifecycle.running = true; }

  public static register(owner: FTNetworkDisposable, requestId: string = ''): number {
    if (++FTNetworkLifecycle.sequence % 64 === 0) {
      FTNetworkLifecycle.owners.forEach((reference: WeakRef<FTNetworkDisposable>, id: number): void => {
        if (!reference.deref()) FTNetworkLifecycle.unregister(id);
      });
    }
    const id = FTNetworkLifecycle.sequence;
    FTNetworkLifecycle.owners.set(id, new WeakRef(owner));
    if (requestId) {
      let owners = FTNetworkLifecycle.requests.get(requestId);
      if (!owners) {
        owners = new Set<number>();
        FTNetworkLifecycle.requests.set(requestId, owners);
      }
      owners.add(id);
      FTNetworkLifecycle.requestByOwner.set(id, requestId);
    }
    return id;
  }

  public static unregister(id: number): void {
    FTNetworkLifecycle.owners.delete(id);
    const requestId = FTNetworkLifecycle.requestByOwner.get(id);
    if (requestId) {
      const owners = FTNetworkLifecycle.requests.get(requestId);
      owners?.delete(id);
      if (owners?.size === 0) FTNetworkLifecycle.requests.delete(requestId);
      FTNetworkLifecycle.requestByOwner.delete(id);
    }
  }

  public static finishRequest(requestId: string): void {
    const ids = Array.from(FTNetworkLifecycle.requests.get(requestId) || new Set<number>()).reverse();
    for (const id of ids) {
      const owner = FTNetworkLifecycle.owners.get(id)?.deref();
      FTNetworkLifecycle.unregister(id);
      try { owner?.dispose(); } catch (error) {
        FTInnerLogger.w('FTNetworkLifecycle', `Request cleanup failed: ${error}`);
      }
    }
  }

  public static shutdown(): void {
    FTNetworkLifecycle.running = false;
    FTNetworkLifecycle.generation++;
    const owners = Array.from(FTNetworkLifecycle.owners.values()).reverse();
    FTNetworkLifecycle.owners.clear();
    FTNetworkLifecycle.requests.clear();
    FTNetworkLifecycle.requestByOwner.clear();
    for (const reference of owners) {
      try { reference.deref()?.dispose(); } catch (error) {
        FTInnerLogger.w('FTNetworkLifecycle', `Transport cleanup failed: ${error}`);
      }
    }
  }
}
