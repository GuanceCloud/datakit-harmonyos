import { radio, data } from '@kit.TelephonyKit';
import { DeviceUtils } from './DeviceUtils';
import { FTInnerLogger } from '../log/FTLogger';

/**
 * Network information interface
 */
interface NetworkInfo {
  type: string;
  connected: boolean;
  strength: number;
  timestamp: number;
}

/**
 * Network utility class
 * Provides network status checks and connectivity validation
 */
export class NetworkUtils {
  private static instance: NetworkUtils | null = null;
  private isConnected: boolean = true; // Assume network connectivity by default
  private networkCheckTimer: number | null = null; // Timer for periodic network status checks

  private constructor() {
    this.initNetworkListener();
  }

  public static getInstance(): NetworkUtils {
    if (!NetworkUtils.instance) {
      NetworkUtils.instance = new NetworkUtils();
    }
    return NetworkUtils.instance;
  }

  /**
   * Check whether the network is connected
   */
  public static isConnected(): boolean {
    return NetworkUtils.getInstance().isConnected;
  }

  /**
   * Check the network connection status
   */
  public static async checkNetworkStatus(): Promise<boolean> {
    try {
      // HarmonyOS network status check
      // Due to API limitations, return true for now to indicate network availability
      return true;
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Network status check failed: ${error}`);
      return false;
    }
  }

  /**
   * Get the network type
   * Use DeviceUtils.getNetworkType() as single source of truth
   * Convert to uppercase format for backward compatibility
   */
  public static async getNetworkType(): Promise<string> {
    try {
      // Use DeviceUtils to get real network type
      const networkType = await DeviceUtils.getNetworkType();
      
      // Convert to uppercase format for backward compatibility
      // DeviceUtils returns: "wifi", "2g", "3g", "4g", "5g", "cellular", "ethernet", "unknown"
      // NetworkUtils expects: "WIFI", "CELLULAR", "ETHERNET", "UNKNOWN"
      if (networkType === "wifi") {
        return "WIFI";
      } else if (networkType === "2g" || networkType === "3g" || networkType === "4g" || networkType === "5g" || networkType === "cellular") {
        return "CELLULAR";
      } else if (networkType === "ethernet") {
        return "ETHERNET";
      } else {
        return "UNKNOWN";
      }
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Get network type failed: ${error}`);
      return 'UNKNOWN';
    }
  }

  /**
   * Get the network strength (WiFi and cellular only)
   * Returns signal strength as percentage (0-100)
   * For WiFi: returns medium strength (50%) as WiFi RSSI API may not be available
   * For Cellular: uses signalLevel (0-4) from SignalInformation converted to percentage
   */
  public static async getNetworkStrength(): Promise<number> {
    try {
      // Get network type first
      const networkType = await DeviceUtils.getNetworkType();
      
      // WiFi signal strength
      // Note: HarmonyOS WiFi RSSI API may not be available, return medium strength
      if (networkType === "wifi") {
        // WiFi signal strength detection not fully supported yet
        // Return medium strength as fallback
        return 50;
      }
      
      // Cellular signal strength
      if (networkType === "2g" || networkType === "3g" || networkType === "4g" || networkType === "5g" || networkType === "cellular") {
        try {
          const slotId: number = await data.getDefaultCellularDataSlotId();
          if (slotId < 0) {
            FTInnerLogger.w("NetworkUtils", 'No SIM card available for signal strength check');
            return 0;
          }
          
          const signals = radio.getSignalInformationSync(slotId);
          if (signals && signals.length > 0 && signals[0]) {
            const signalInfo = signals[0];
            
            // Use signalLevel if available (typically 0-4)
            // SignalInformation has signalLevel property (number, 0-4)
            const signalLevel = signalInfo.signalLevel;
            if (signalLevel !== undefined && signalLevel !== null) {
              // Convert signalLevel (0-4) to percentage (0-100)
              // signalLevel: 0 = 0%, 1 = 25%, 2 = 50%, 3 = 75%, 4 = 100%
              const percentage = (signalLevel / 4) * 100;
              // Removed verbose debug log to reduce log output
              return Math.round(percentage);
            }
          }
        } catch (err) {
          const errorMsg = err instanceof Error ? err.message : String(err);
          FTInnerLogger.w("NetworkUtils", `Failed to get cellular signal strength: ${errorMsg}`);
        }
        // Fallback: return medium strength if cellular info not available
        return 50;
      }
      
      // For ethernet, return 100% (always strong for wired connection)
      if (networkType === "ethernet") {
        return 100;
      }
      
      // Unknown network type
      return 0;
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e("NetworkUtils", `Get network strength failed: ${errorMsg}`);
      return 0;
    }
  }

  /**
   * Check whether it is a cellular network
   */
  public static async isMobileNetwork(): Promise<boolean> {
    const netType = await NetworkUtils.getNetworkType();
    return netType === 'CELLULAR';
  }

  /**
   * Check whether it is a WiFi network
   */
  public static async isWifiNetwork(): Promise<boolean> {
    const netType = await NetworkUtils.getNetworkType();
    return netType === 'WIFI';
  }

  /**
   * Check whether the network is available (ping test)
   */
  public static async pingTest(host: string = '8.8.8.8', timeout: number = 5000): Promise<boolean> {
    try {
      // HarmonyOS ping test
      // Due to API limitations, return the network status check result for now
      return await NetworkUtils.checkNetworkStatus();
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Ping test failed: ${error}`);
      return false;
    }
  }

  /**
   * Initialize the network listener
   */
  private initNetworkListener(): void {
    try {
      // Use the HarmonyOS network status API
      // Note: HarmonyOS network APIs differ from other platforms, so a simplified implementation is used here
      
      // Check the network connection status
      this.checkNetworkStatus();
      
      // Schedule periodic network status checks
      this.networkCheckTimer = setInterval(() => {
        this.checkNetworkStatus();
      }, 5000); // Check every 5 seconds

    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Init network listener failed: ${error}`);
    }
  }

  /**
   * Stop network monitoring
   * Used for memory leak debugging - stops the periodic network status check
   */
  public stopMonitoring(): void {
    if (this.networkCheckTimer !== null) {
      clearInterval(this.networkCheckTimer);
      this.networkCheckTimer = null;
      // Removed verbose debug log to reduce log output
    }
  }

  /**
   * Restart network monitoring
   * Used for memory leak debugging - restarts the periodic network status check
   */
  public startMonitoring(): void {
    if (this.networkCheckTimer === null) {
      this.initNetworkListener();
      // Removed verbose debug log to reduce log output
    }
  }

  /**
   * Check the network status
   */
  private checkNetworkStatus(): void {
    try {
      // Use a simplified network status check
      // In HarmonyOS, network status can be inferred with ping tests
      this.isConnected = true; // Assume network availability by default
      
      // More complex network status checks can be added here
      // Removed verbose debug log to reduce log output
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Check network status failed: ${error}`);
      this.isConnected = false;
    }
  }

  /**
   * Get a summary of network information
   */
  public static async getNetworkInfo(): Promise<NetworkInfo> {
    try {
      const netType = await NetworkUtils.getNetworkType();
      const isConnected = await NetworkUtils.checkNetworkStatus();
      const strength = await NetworkUtils.getNetworkStrength();
      
      return {
        type: netType,
        connected: isConnected,
        strength: strength,
        timestamp: Date.now()
      };
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Get network info failed: ${error}`);
      return {
        type: 'UNKNOWN',
        connected: false,
        strength: 0,
        timestamp: Date.now()
      };
    }
  }

  /**
   * Check network quality
   */
  public static async checkNetworkQuality(): Promise<'EXCELLENT' | 'GOOD' | 'FAIR' | 'POOR'> {
    try {
      const strength = await NetworkUtils.getNetworkStrength();
      const netType = await NetworkUtils.getNetworkType();
      
      if (netType === 'WIFI') {
        // WiFi signal strength evaluation
        if (strength >= -50) return 'EXCELLENT';
        if (strength >= -60) return 'GOOD';
        if (strength >= -70) return 'FAIR';
        return 'POOR';
      } else if (netType === 'CELLULAR') {
        // Cellular signal strength evaluation
        if (strength >= 4) return 'EXCELLENT';
        if (strength >= 3) return 'GOOD';
        if (strength >= 2) return 'FAIR';
        return 'POOR';
      }
      
      return 'FAIR';
    } catch (error) {
      FTInnerLogger.e("NetworkUtils", `Check network quality failed: ${error}`);
      return 'FAIR';
    }
  }
}
