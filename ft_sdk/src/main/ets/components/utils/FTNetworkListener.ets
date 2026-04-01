import connection from '@ohos.net.connection';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeviceUtils } from './DeviceUtils';
import { FTInnerLogger } from '../log/FTLogger';
import { SyncTaskManager } from '../SyncTaskManager';

const TAG = "FTNetworkListener";

/**
 * Network state monitoring class for HarmonyOS
 * Similar to Android's FTNetworkListener
 * Monitors network state changes and updates network type cache in real time
 */
export class FTNetworkListener {
  private static instance: FTNetworkListener | null = null;
  private netConnection: connection.NetConnection | null = null;
  private isMonitoring: boolean = false;

  private constructor() {
  }

  public static getInstance(): FTNetworkListener {
    if (!FTNetworkListener.instance) {
      FTNetworkListener.instance = new FTNetworkListener();
    }
    return FTNetworkListener.instance;
  }

  /**
   * Start monitoring network state changes
   * Similar to Android's monitor() method
   */
  public monitor(): void {
    if (this.isMonitoring) {
      return;
    }

    try {
      FTInnerLogger.i(TAG, "Starting network state monitoring");

      // Create network connection listener
      this.netConnection = connection.createNetConnection();
      
      // Register callback
      this.netConnection.register((error: BusinessError) => {
        if (error) {
          FTInnerLogger.e(TAG, `Failed to register network listener: ${error.message}`);
          this.isMonitoring = false;
        } else {
          this.isMonitoring = true;
          FTInnerLogger.i(TAG, "Network listener registered");
          
          // Fetch initial network state
          this.fetchNetworkState();
        }
      });

      // Listen for network capabilities changes (network type changes)
      // Note: The callback parameter structure may vary by API version
      this.netConnection.on("netCapabilitiesChange", (data: connection.NetCapabilityInfo) => {
        this.onNetworkCapabilitiesChanged(data);
      });

      // Listen for network availability changes (no network -> has network)
      // Note: The callback parameter type is connection.NetHandle
      this.netConnection.on("netAvailable", (data: connection.NetHandle) => {
        this.onNetworkAvailable(data);
      });

      // Listen for network lost (network disconnected)
      // Note: The callback parameter type is connection.NetHandle
      this.netConnection.on("netLost", (data: connection.NetHandle) => {
        this.onNetworkLost(data);
      });

      // Listen for network unavailable
      this.netConnection.on("netUnavailable", () => {
        this.onNetworkUnavailable();
      });

    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to start network monitoring: ${errorMsg}`);
      this.isMonitoring = false;
    }
  }

  /**
   * Fetch current network state and update cache
   * Similar to Android's fetchNetworkStateBean() method
   */
  private async fetchNetworkState(): Promise<void> {
    try {
      // Refresh network type cache to get latest network type
      await DeviceUtils.refreshNetworkTypeCache();
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `[fetchNetworkState] Failed to fetch network state: ${errorMsg}`);
    }
  }

  /**
   * Handle error safely (extract error message from unknown type)
   * Helper function to avoid ArkTS lint errors about any/unknown
   */
  private getErrorMessage(err: ESObject): string {
    if (err instanceof Error) {
      return err.message;
    } else if (typeof err === "string") {
      return err;
    } else {
      return String(err);
    }
  }

  /**
   * Handle network capabilities change event
   * Similar to Android's onCapabilitiesChanged() method
   */
  private onNetworkCapabilitiesChanged(data: connection.NetCapabilityInfo): void {
    try {
      FTInnerLogger.i(TAG, "Network capabilities changed");

      // Update network type cache when capabilities change
      this.fetchNetworkState().catch((err: ESObject) => {
        const errorMsg = this.getErrorMessage(err);
        FTInnerLogger.e(TAG, `[onNetworkCapabilitiesChanged] Failed to update network state: ${errorMsg}`);
      });
    } catch (err) {
      const errorMsg = this.getErrorMessage(err);
      FTInnerLogger.e(TAG, `[onNetworkCapabilitiesChanged] Error: ${errorMsg}`);
    }
  }

  /**
   * Handle network available event (no network -> has network)
   * Similar to Android's onAvailable() method
   */
  private onNetworkAvailable(data: connection.NetHandle): void {
    try {
      FTInnerLogger.i(TAG, `Network became available, netId=${data.netId}`);

      // Update network type cache
      this.fetchNetworkState().catch((err: ESObject) => {
        const errorMsg = this.getErrorMessage(err);
        FTInnerLogger.e(TAG, `[onNetworkAvailable] Failed to update network state: ${errorMsg}`);
      });
      
      // Trigger sync poll (similar to Android)
      SyncTaskManager.getInstance().executeSyncPoll();
    } catch (err) {
      const errorMsg = this.getErrorMessage(err);
      FTInnerLogger.e(TAG, `[onNetworkAvailable] Error: ${errorMsg}`);
    }
  }

  /**
   * Handle network lost event (network disconnected)
   * Similar to Android's onLost() method
   */
  private onNetworkLost(data: connection.NetHandle): void {
    try {
      FTInnerLogger.i(TAG, `Network lost, netId=${data.netId}`);

      // Update network type cache to "unknown"
      DeviceUtils.setCachedNetworkType("unknown");
    } catch (err) {
      const errorMsg = this.getErrorMessage(err);
      FTInnerLogger.e(TAG, `[onNetworkLost] Error: ${errorMsg}`);
    }
  }

  /**
   * Handle network unavailable event
   */
  private onNetworkUnavailable(): void {
    try {
      FTInnerLogger.i(TAG, "Network unavailable");

      // Update network type cache to "unknown"
      DeviceUtils.setCachedNetworkType("unknown");
    } catch (err) {
      const errorMsg = this.getErrorMessage(err);
      FTInnerLogger.e(TAG, `[onNetworkUnavailable] Error: ${errorMsg}`);
    }
  }

  /**
   * Stop monitoring network state changes
   * Similar to Android's unregister() method
   */
  public unregister(): void {
    try {
      if (this.netConnection) {
        this.netConnection.unregister((error: BusinessError) => {
          if (error) {
            FTInnerLogger.e(TAG, `Failed to unregister network listener: ${error.message}`);
          }
        });
        this.netConnection = null;
      }
      this.isMonitoring = false;
      FTInnerLogger.i(TAG, "Network monitoring stopped");
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to unregister network listener: ${errorMsg}`);
    }
  }

  /**
   * Release network listener
   * Similar to Android's release() method
   * Used when {@link FTSDK#shutDown()}
   */
  public static release(): void {
    if (FTNetworkListener.instance) {
      FTNetworkListener.instance.unregister();
      FTNetworkListener.instance = null;
    }
  }
}
