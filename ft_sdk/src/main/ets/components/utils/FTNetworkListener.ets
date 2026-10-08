import connection from '@ohos.net.connection';
import wifiManager from '@ohos.wifiManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { radio, data } from '@kit.TelephonyKit';
import { DeviceUtils } from './DeviceUtils';
import { FTInnerLogger } from '../log/FTLogger';
import { SyncTaskManager } from '../SyncTaskManager';
import { SDKRumResourceNetworkSnapshotDTO } from '../thread/SDKWorkerProtocol';

const TAG = "FTNetworkListener";

/**
 * A Wi-Fi API result is asynchronous, whereas the default network can switch
 * before that result is delivered. Both the network identity and revision
 * must still describe the same Wi-Fi network before it can enrich a snapshot.
 */
export function shouldApplyWifiSignalSnapshot(
  currentNetId: number,
  currentNetworkRevision: number,
  currentNetworkIsWifi: boolean,
  callbackNetId: number,
  callbackNetworkRevision: number
): boolean {
  return currentNetworkIsWifi && currentNetId > 0 && currentNetId === callbackNetId &&
    currentNetworkRevision === callbackNetworkRevision;
}

/** Wi-Fi Manager documents signal levels as the inclusive range 0 through 4. */
export function isKnownWifiSignalLevel(signalLevel: number): boolean {
  return Number.isInteger(signalLevel) && signalLevel >= 0 && signalLevel <= 4;
}

/**
 * Network state monitoring class for HarmonyOS
 * Similar to Android's FTNetworkListener
 * Monitors network state changes and updates network type cache in real time
 */
export class FTNetworkListener {
  private static instance: FTNetworkListener | null = null;
  private netConnection: connection.NetConnection | null = null;
  private isMonitoring: boolean = false;
  /** Tracks reachability so a recovery is scheduled once, not on every capability update. */
  private hasInternetCapability: boolean = false;
  /**
   * Resource creation reads only this value. Platform APIs run during listener
   * registration/callbacks, never on an application's request path.
   */
  private resourceNetworkSnapshot: SDKRumResourceNetworkSnapshotDTO = { available: false };
  private currentNetId: number = 0;
  /** Increments when the cached default network identity changes. */
  private networkRevision: number = 0;
  private currentNetworkIsWifi: boolean = false;
  /** One asynchronous Wi-Fi read is sufficient per network revision. */
  private wifiSignalRefreshRevision: number = 0;
  private isWifiRssiListenerRegistered: boolean = false;
  private readonly wifiRssiChangeCallback: (rssi: number) => void = (rssi: number): void => {
    this.onWifiRssiChanged(rssi);
  };

  private constructor() {
  }

  public static getInstance(): FTNetworkListener {
    if (!FTNetworkListener.instance) {
      FTNetworkListener.instance = new FTNetworkListener();
    }
    return FTNetworkListener.instance;
  }

  /**
   * Returns a fresh serializable copy for one Resource lifecycle. The copy is
   * intentionally primitive-only so later network callbacks cannot mutate a
   * Resource that has already started.
   */
  public getResourceNetworkSnapshot(): SDKRumResourceNetworkSnapshotDTO {
    const snapshot = this.resourceNetworkSnapshot;
    const copy: SDKRumResourceNetworkSnapshotDTO = { available: snapshot.available };
    if (snapshot.validated !== undefined) {
      copy.validated = snapshot.validated;
    }
    if (snapshot.downlinkKbps !== undefined) {
      copy.downlinkKbps = snapshot.downlinkKbps;
    }
    if (snapshot.uplinkKbps !== undefined) {
      copy.uplinkKbps = snapshot.uplinkKbps;
    }
    if (snapshot.signalStrength !== undefined) {
      copy.signalStrength = snapshot.signalStrength;
    }
    return copy;
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

      // HarmonyOS requires callbacks to be attached before register(), or a
      // fast network switch between those calls can be lost.
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

      // Signal changes are delivered independently from connectivity changes.
      // Keep this listener alive with the network listener, and do no I/O on a
      // Resource request path.
      this.registerWifiRssiListener();

      // Seed the cache before the first Resource can be started. Failure keeps
      // the conservative initial unavailable value and never blocks callers.
      this.refreshSnapshotFromDefaultNetwork();

      this.netConnection.register((error: BusinessError) => {
        if (error) {
          FTInnerLogger.e(TAG, `Failed to register network listener: ${error.message}`);
          this.isMonitoring = false;
        } else {
          this.isMonitoring = true;
          FTInnerLogger.i(TAG, "Network listener registered");
          this.fetchNetworkState();
        }
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
      this.refreshSnapshotFromDefaultNetwork();
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
      // This callback also reports routine capability updates while a network
      // remains available. Keep it diagnostic-only; it must never be treated
      // as a normal cold-launch upload gate.
      FTInnerLogger.d(TAG, "Network capabilities changed");
      // console.info('ft-lizhao',JSON.stringify(data.netCap))

      const hasInternetCapability = this.hasNetworkCapability(data, connection.NetCap.NET_CAPABILITY_INTERNET);
      // VALIDATED is a connectivity-probe result, not a network lifecycle
      // boundary. It can flip while the network stays available, so using it
      // here would schedule an empty upload round on every probe transition.
      const networkRecovered = hasInternetCapability && !this.hasInternetCapability;
      this.hasInternetCapability = hasInternetCapability;

      const netId = data && data.netHandle ? data.netHandle.netId : 0;
      if (netId > 0 && this.isCurrentDefaultNetwork(netId)) {
        this.updateSnapshotFromCapabilities(netId, data.netCap);
      }

      // Update network type cache when capabilities change. Some devices emit
      // this event, rather than netAvailable, when Internet access returns.
      this.fetchNetworkState().catch((err: ESObject) => {
        const errorMsg = this.getErrorMessage(err);
        FTInnerLogger.e(TAG, `[onNetworkCapabilitiesChanged] Failed to update network state: ${errorMsg}`);
      });
      if (networkRecovered) {
        this.resumePendingUploadAfterNetworkRecovery('capabilities changed');
      }
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

      this.hasInternetCapability = true;
      if (data.netId > 0 && this.isCurrentDefaultNetwork(data.netId)) {
        if (this.currentNetId !== data.netId) {
          this.updateCurrentNetworkIdentity(data.netId, false);
          // Capabilities can arrive after netAvailable. Record availability now
          // and let capability callbacks fill optional values when available.
          this.resourceNetworkSnapshot = { available: true };
        } else if (!this.resourceNetworkSnapshot.available) {
          this.resourceNetworkSnapshot = { available: true };
        }
      }
      this.refreshSnapshotFromDefaultNetwork();
      this.fetchNetworkState().catch((err: ESObject) => {
        const errorMsg = this.getErrorMessage(err);
        FTInnerLogger.e(TAG, `[onNetworkAvailable] Failed to update network state: ${errorMsg}`);
      });
      this.resumePendingUploadAfterNetworkRecovery('network available');
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
      // During Wi-Fi -> cellular handover HarmonyOS may deliver netLost for
      // the old network after the new default is already available.
      if (data.netId > 0 && this.currentNetId > 0 && data.netId !== this.currentNetId) {
        return;
      }
      this.hasInternetCapability = false;
      SyncTaskManager.getInstance().updateNetworkAvailability(false);
      this.setNetworkUnavailable();

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
      this.hasInternetCapability = false;
      SyncTaskManager.getInstance().updateNetworkAvailability(false);
      this.setNetworkUnavailable();

      // Update network type cache to "unknown"
      DeviceUtils.setCachedNetworkType("unknown");
    } catch (err) {
      const errorMsg = this.getErrorMessage(err);
      FTInnerLogger.e(TAG, `[onNetworkUnavailable] Error: ${errorMsg}`);
    }
  }

  private hasNetworkCapability(data: connection.NetCapabilityInfo, target: connection.NetCap): boolean {
    const capabilities = data && data.netCap ? data.netCap.networkCap : undefined;
    if (!capabilities) {
      return false;
    }
    for (let index = 0; index < capabilities.length; index++) {
      if (capabilities[index] === target) {
        return true;
      }
    }
    return false;
  }

  private refreshSnapshotFromDefaultNetwork(): void {
    try {
      if (!connection.hasDefaultNetSync()) {
        this.setNetworkUnavailable();
        return;
      }
      const netHandle = connection.getDefaultNetSync();
      if (!netHandle || netHandle.netId <= 0) {
        this.setNetworkUnavailable();
        return;
      }
      const netCapabilities = connection.getNetCapabilitiesSync(netHandle);
      this.updateSnapshotFromCapabilities(netHandle.netId, netCapabilities);
    } catch (err) {
      // A permission/API failure is an unknown capability state, not evidence
      // that a previously known network disappeared. Keep the last safe value.
      FTInnerLogger.w(TAG, `[refreshSnapshotFromDefaultNetwork] ${this.getErrorMessage(err)}`);
    }
  }

  private isCurrentDefaultNetwork(netId: number): boolean {
    try {
      if (!connection.hasDefaultNetSync()) {
        return false;
      }
      return connection.getDefaultNetSync().netId === netId;
    } catch (err) {
      // Do not replace the current cache with an arbitrary stale callback when
      // the default network can no longer be queried.
      return this.currentNetId === netId;
    }
  }

  private updateSnapshotFromCapabilities(netId: number, capabilities: connection.NetCapabilities): void {
    if (netId <= 0 || !capabilities) {
      return;
    }
    const isWifi = capabilities.bearerTypes !== undefined &&
      capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI);
    const canRetainWifiSignal = isWifi && this.resourceNetworkSnapshot.available &&
      this.currentNetId === netId && this.currentNetworkIsWifi;
    const cachedWifiSignal = canRetainWifiSignal ? this.resourceNetworkSnapshot.signalStrength : undefined;
    this.updateCurrentNetworkIdentity(netId, isWifi);
    const snapshot: SDKRumResourceNetworkSnapshotDTO = { available: true };
    const networkCapabilities = capabilities.networkCap;
    const isCheckingConnectivity = this.hasCapability(
      networkCapabilities,
      connection.NetCap.NET_CAPABILITY_CHECKING_CONNECTIVITY
    );
    if (!isCheckingConnectivity && networkCapabilities !== undefined) {
      snapshot.validated = this.hasCapability(networkCapabilities, connection.NetCap.NET_CAPABILITY_VALIDATED);
    }
    const downlinkKbps = this.toKnownPositiveInteger(capabilities.linkDownBandwidthKbps);
    if (downlinkKbps !== undefined) {
      snapshot.downlinkKbps = downlinkKbps;
    }
    const uplinkKbps = this.toKnownPositiveInteger(capabilities.linkUpBandwidthKbps);
    if (uplinkKbps !== undefined) {
      snapshot.uplinkKbps = uplinkKbps;
    }
    // If the default network reports Wi-Fi, its asynchronous platform signal
    // result replaces no value until it has been proven current below. Do not
    // temporarily assign a cellular signal from a mixed capability list.
    const signalStrength = isWifi ? undefined : this.readCellularSignalStrength(capabilities);
    if (signalStrength !== undefined) {
      snapshot.signalStrength = signalStrength;
    } else if (cachedWifiSignal !== undefined) {
      // A routine capability update must not create a gap in an otherwise
      // valid Wi-Fi signal cache. A later RSSI read can still replace it.
      snapshot.signalStrength = cachedWifiSignal;
    }
    this.resourceNetworkSnapshot = snapshot;
    if (isWifi) {
      this.refreshWifiSignal(netId, this.networkRevision);
    }
  }

  private updateCurrentNetworkIdentity(netId: number, isWifi: boolean): void {
    if (this.currentNetId !== netId || this.currentNetworkIsWifi !== isWifi) {
      this.networkRevision++;
      this.wifiSignalRefreshRevision = 0;
    }
    this.currentNetId = netId;
    this.currentNetworkIsWifi = isWifi;
  }

  private hasCapability(capabilities: connection.NetCap[] | undefined, target: connection.NetCap): boolean {
    if (!capabilities) {
      return false;
    }
    return capabilities.includes(target);
  }

  private toKnownPositiveInteger(value: number | undefined): number | undefined {
    // HarmonyOS documents bandwidth 0 as unavailable; it must be omitted.
    if (value === undefined || !Number.isInteger(value) || value <= 0) {
      return undefined;
    }
    return value;
  }

  private readCellularSignalStrength(capabilities: connection.NetCapabilities): number | undefined {
    if (!capabilities.bearerTypes || !capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)) {
      return undefined;
    }
    try {
      const slotId = data.getDefaultCellularDataSlotIdSync();
      if (slotId < 0) {
        return undefined;
      }
      const signals = radio.getSignalInformationSync(slotId);
      if (!signals || signals.length === 0 || !signals[0]) {
        return undefined;
      }
      const signalLevel = signals[0].signalLevel;
      // signalLevel is a native discrete level. Zero is retained only when it
      // was actually supplied by the platform, unlike bandwidth's sentinel 0.
      return Number.isInteger(signalLevel) && signalLevel >= 0 ? signalLevel : undefined;
    } catch (err) {
      FTInnerLogger.w(TAG, `[readCellularSignalStrength] ${this.getErrorMessage(err)}`);
      return undefined;
    }
  }

  /**
   * Reads Wi-Fi metadata only from listener work. The captured identity and
   * revision prevent a late promise from attributing old Wi-Fi signal to a
   * cellular, offline, or subsequently connected Wi-Fi Resource.
   */
  private refreshWifiSignal(netId: number, networkRevision: number): void {
    if (!this.isCurrentWifiNetwork(netId, networkRevision) ||
      this.wifiSignalRefreshRevision === networkRevision) {
      return;
    }
    this.wifiSignalRefreshRevision = networkRevision;
    wifiManager.getLinkedInfo()
      .then((linkedInfo: wifiManager.WifiLinkedInfo): void => {
        if (this.wifiSignalRefreshRevision === networkRevision) {
          this.wifiSignalRefreshRevision = 0;
        }
        if (!this.isCurrentWifiNetwork(netId, networkRevision)) {
          return;
        }
        const signalLevel = this.readWifiSignalLevel(linkedInfo.rssi, linkedInfo.band);
        if (signalLevel !== undefined) {
          this.mergeCurrentWifiSignal(netId, networkRevision, signalLevel);
        }
      })
      .catch((err: ESObject): void => {
        if (this.wifiSignalRefreshRevision === networkRevision) {
          this.wifiSignalRefreshRevision = 0;
        }
        FTInnerLogger.w(TAG, `[refreshWifiSignal] ${this.getErrorMessage(err)}`);
      });
  }

  private onWifiRssiChanged(_rssi: number): void {
    const netId = this.currentNetId;
    const networkRevision = this.networkRevision;
    if (this.isCurrentWifiNetwork(netId, networkRevision)) {
      // getLinkedInfo() supplies the current frequency band as well as RSSI.
      // Re-read both rather than applying an RSSI value with a stale band.
      this.refreshWifiSignal(netId, networkRevision);
    }
  }

  private readWifiSignalLevel(rssi: number, band: number): number | undefined {
    if (!Number.isFinite(rssi) || !Number.isFinite(band)) {
      return undefined;
    }
    try {
      const signalLevel = wifiManager.getSignalLevel(rssi, band);
      return isKnownWifiSignalLevel(signalLevel) ? signalLevel : undefined;
    } catch (err) {
      FTInnerLogger.w(TAG, `[readWifiSignalLevel] ${this.getErrorMessage(err as ESObject)}`);
      return undefined;
    }
  }

  private isCurrentWifiNetwork(netId: number, networkRevision: number): boolean {
    return this.resourceNetworkSnapshot.available &&
      shouldApplyWifiSignalSnapshot(
        this.currentNetId,
        this.networkRevision,
        this.currentNetworkIsWifi,
        netId,
        networkRevision
      ) && this.isCurrentDefaultNetwork(netId);
  }

  private mergeCurrentWifiSignal(netId: number, networkRevision: number, signalLevel: number): void {
    if (!this.isCurrentWifiNetwork(netId, networkRevision)) {
      return;
    }
    const snapshot = this.getResourceNetworkSnapshot();
    snapshot.signalStrength = signalLevel;
    this.resourceNetworkSnapshot = snapshot;
  }

  private registerWifiRssiListener(): void {
    if (this.isWifiRssiListenerRegistered) {
      return;
    }
    try {
      wifiManager.on('wifiRssiChange', this.wifiRssiChangeCallback);
      this.isWifiRssiListenerRegistered = true;
    } catch (err) {
      // Wi-Fi information is optional. Permission/API support failures must
      // not prevent normal network monitoring or Resource collection.
      FTInnerLogger.w(TAG, `[registerWifiRssiListener] ${this.getErrorMessage(err as ESObject)}`);
    }
  }

  private unregisterWifiRssiListener(): void {
    if (!this.isWifiRssiListenerRegistered) {
      return;
    }
    try {
      wifiManager.off('wifiRssiChange', this.wifiRssiChangeCallback);
    } catch (err) {
      FTInnerLogger.w(TAG, `[unregisterWifiRssiListener] ${this.getErrorMessage(err as ESObject)}`);
    } finally {
      this.isWifiRssiListenerRegistered = false;
    }
  }

  private setNetworkUnavailable(): void {
    if (this.currentNetId !== 0 || this.resourceNetworkSnapshot.available) {
      this.networkRevision++;
    }
    this.currentNetId = 0;
    this.currentNetworkIsWifi = false;
    this.wifiSignalRefreshRevision = 0;
    this.resourceNetworkSnapshot = { available: false };
  }

  private resumePendingUploadAfterNetworkRecovery(reason: string): void {
    // SyncTaskManager coalesces duplicate platform callbacks and delays the
    // recovery request briefly, allowing HarmonyOS to finish route setup.
    FTInnerLogger.i(TAG, `Network recovery (${reason}); scheduling pending upload`);
    SyncTaskManager.getInstance().updateNetworkAvailability(true, true);
  }

  /**
   * Stop monitoring network state changes
   * Similar to Android's unregister() method
   */
  public unregister(): void {
    try {
      this.unregisterWifiRssiListener();
      if (this.netConnection) {
        this.netConnection.unregister((error: BusinessError) => {
          if (error) {
            FTInnerLogger.e(TAG, `Failed to unregister network listener: ${error.message}`);
          }
        });
        this.netConnection = null;
      }
      this.isMonitoring = false;
      this.hasInternetCapability = false;
      this.setNetworkUnavailable();
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
