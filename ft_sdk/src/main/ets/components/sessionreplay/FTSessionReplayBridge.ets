import { FTInnerLogger } from '../log/FTLogger';

const TAG = 'FTSessionReplayBridge';

/** Immutable RUM identity handed to an optional Session Replay HAR. */
export interface FTSessionReplayRUMContext {
  applicationId: string;
  sessionId: string;
  viewId: string;
  viewName: string;
  viewReferrer: string;
  timestamp: number;
}

export interface FTSessionReplayErrorContext extends FTSessionReplayRUMContext {
  errorType: string;
  appState: string;
}

export interface FTSessionReplaySessionContext {
  applicationId: string;
  previousSessionId: string;
  sessionId: string;
  timestamp: number;
}

/**
 * Optional Replay contract. The core SDK owns no recorder, storage, or upload
 * implementation. A HAR registers this bridge only when Replay is enabled.
 */
export interface FTSessionReplayBridge {
  onViewStarted(context: FTSessionReplayRUMContext): boolean;
  onViewStopped(context: FTSessionReplayRUMContext): void;
  onError(context: FTSessionReplayErrorContext): boolean;
  onSessionRenewed(context: FTSessionReplaySessionContext): void;
}

/** NoOp-by-default registry preventing any Replay cost for existing SDK users. */
export class FTSessionReplayBridgeRegistry {
  private static bridge: FTSessionReplayBridge | null = null;

  public static register(bridge: FTSessionReplayBridge): void {
    FTSessionReplayBridgeRegistry.bridge = bridge;
  }

  public static unregister(bridge: FTSessionReplayBridge): void {
    if (FTSessionReplayBridgeRegistry.bridge === bridge) {
      FTSessionReplayBridgeRegistry.bridge = null;
    }
  }

  public static notifyViewStarted(context: FTSessionReplayRUMContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return false;
    }
    try {
      return bridge.onViewStarted(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay view-start callback failed: ${String(error)}`);
      return false;
    }
  }

  public static notifyViewStopped(context: FTSessionReplayRUMContext): void {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return;
    }
    try {
      bridge.onViewStopped(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay view-stop callback failed: ${String(error)}`);
    }
  }

  public static notifyError(context: FTSessionReplayErrorContext): boolean {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return false;
    }
    try {
      return bridge.onError(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay error callback failed: ${String(error)}`);
      return false;
    }
  }

  public static notifySessionRenewed(context: FTSessionReplaySessionContext): void {
    const bridge = FTSessionReplayBridgeRegistry.bridge;
    if (bridge === null) {
      return;
    }
    try {
      bridge.onSessionRenewed(context);
    } catch (error) {
      FTInnerLogger.w(TAG, `Replay session callback failed: ${String(error)}`);
    }
  }
}
