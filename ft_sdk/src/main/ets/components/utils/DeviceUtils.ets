/**
 * @author Tanranran
 * @date 2024/5/14 22:20
 * @description from https://github.com/tanranran/HarmonyUtilCode
 */
import deviceInfo from '@ohos.deviceInfo';
import { deviceInfo as kitDeviceInfo }   from '@kit.BasicServicesKit';
// import battery from '@system.battery';
import display from '@ohos.display';
import { i18n } from '@kit.LocalizationKit';
import connection from '@ohos.net.connection';
import { radio, data } from '@kit.TelephonyKit';
import { Utils } from './Utils';
import { FTInnerLogger } from '../log/FTLogger';

const TAG = "DeviceUtils";

/**
 * Language information interface
 */
interface LanguageInfo {
  language: string;
  region: string;
  locale: string;
}

/**
 * Screen information interface
 */
interface ScreenInfo {
  width: number;
  height: number;
  density: number;
  dpi: number;
  category: string;
}

/**
 * Language change event data interface
 */
interface LanguageChangeData {
  language: string;
}

/**
 * System information interface
 */
interface SystemInfo {
  brand: string;
  model: string;
  osName: string;
  osVersion: string;
  udid: string;
  abiList: string[];
}

/**
 * Device feature interface
 */
interface DeviceFeatures {
  touchscreen: boolean;
  geolocation: boolean;
  camera: boolean;
  microphone: boolean;
  vibration: boolean;
  bluetooth: boolean;
  nfc: boolean;
  fingerprint: boolean;
  faceRecognition: boolean;
  wirelessCharging: boolean;
}

/**
 * Network information interface
 */
interface NetworkInfo {
  online: boolean;
  connection: object | null;
  effectiveType: string;
  downlink: number;
  rtt: number;
  saveData: boolean;
}

/**
 * Storage information interface
 */
interface StorageInfo {
  total: string;
  available: string;
  used: string;
  usedPercentage: number;
}

/**
 * Battery information interface
 */
interface BatteryInfo {
  level: number;
  charging: boolean;
  chargingTime: number;
  dischargingTime: number;
}

/**
 * Device information interface
 */
interface DeviceInfo {
  deviceType: string;
  manufacture: string;
  brand: string;
  osFullName: string;
  sdkApiVersion: number;
  versionId: string;
  hardwareModel: string;
  productSeries: string;
}





/**
 * Device information utility class
 */
export class DeviceUtils {
  // Cache for network type (since network API is async but sync method is needed)
  private static cachedNetworkType: string = "unknown";
  private static networkTypeCacheTime: number = 0;
  private static readonly NETWORK_TYPE_CACHE_TTL: number = 5000; // 5 seconds cache TTL

  private constructor() {
    this.initDeviceInfo();
    // Initialize network type cache asynchronously
    //fixme
    //DeviceUtils.refreshNetworkTypeCache();
  }

  /**
   * Refresh network type cache asynchronously
   * Called automatically on initialization and can be called manually
   * Can be called by FTNetworkListener to update cache when network changes
   */
  public static async refreshNetworkTypeCache(): Promise<void> {
    try {
      const networkType = await DeviceUtils.getNetworkType();
      DeviceUtils.cachedNetworkType = networkType;
      DeviceUtils.networkTypeCacheTime = Date.now();
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to refresh network type cache: ${error}`);
    }
  }

  /**
   * Set cached network type directly
   * Used by FTNetworkListener when network is lost
   * @param networkType Network type string to cache
   */
  public static setCachedNetworkType(networkType: string): void {
    DeviceUtils.cachedNetworkType = networkType;
    DeviceUtils.networkTypeCacheTime = Date.now();
  }

  /**
   * Initialize device information manager
   */
  private async initDeviceInfo(): Promise<void> {
    try {
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize DeviceInfo: ${error}`);
    }
  }

  /**
   * Get device unique identifier
   * @returns Device UUID
   */
  public static getUuid(): string {
    try {
      const deviceId = deviceInfo.udid;
      return Utils.isNotEmpty(deviceId) ? deviceId : Utils.generateUUID();
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get device UUID: ${error}`);
      return Utils.generateUUID();
    }
  }


  /**
   * Get system version
   * Aligned with Android: DeviceUtils.getOSVersion() returns Build.VERSION.RELEASE directly
   * @returns System version
   */
  public static getOSVersion(): string {
    try {
      return kitDeviceInfo.distributionOSVersion|| "";
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get OS version: ${error}`);
      return "";
    }
  }

  /**
   * Get system major version number
   * Aligned with Android: extract major version from OS version string
   * @returns System major version number
   */
  public static getOSVersionMajor(): string {
    try {
      const version = DeviceUtils.getOSVersion();
      if (Utils.isEmpty(version)) {
        return "";
      }
      const parts = version.split('.');
      return parts.length > 0 && Utils.isNotEmpty(parts[0]) ? parts[0] : "";
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get OS version major: ${error}`);
      return "";
    }
  }

  /**
   * Get device brand
   * @returns Device brand
   */
  public static getDeviceBrand(): string {
    try {
      const brand = kitDeviceInfo.brand;
      return Utils.isNotEmpty(brand) ? brand : 'HUAWEI';
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get device brand: ${error}`);
      return 'HUAWEI';
    }
  }

  /**
   * Get device model
   * @returns Device model
   */
  public static getDeviceModel(): string {
    try {
      const model = kitDeviceInfo.productModel;
      return Utils.isNotEmpty(model) ? model : 'Unknown';
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get device model: ${error}`);
      return 'Unknown';
    }
  }

  /**
   * Get device architecture
   * @returns Device architecture
   */
  public static getDeviceArch(): string {
    try {
      const arch = deviceInfo.abiList;
      if (Utils.isNotEmpty(arch) && Array.isArray(arch) && arch.length > 0) {
        const archArray = arch as string[];
        return archArray[0] || 'aarch64';
      }
      return 'aarch64';
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get device arch: ${error}`);
      return 'aarch64';
    }
  }

  /**
   * Get system information
   * @returns System information object
   */
  public static getSystemInfo(): SystemInfo {
    try {
      return {
        brand: kitDeviceInfo.brand,
        model: kitDeviceInfo.productModel,
        osName: kitDeviceInfo.distributionOSName,
        osVersion: kitDeviceInfo.displayVersion,
        udid: deviceInfo.udid,
        abiList: Array.isArray(deviceInfo.abiList) ? deviceInfo.abiList : [deviceInfo.abiList]
      };
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get system info: ${error}`);
      return {
        brand: '',
        model: '',
        osName: '',
        osVersion: '',
        udid: '',
        abiList: []
      };
    }
  }

  /**
   * Get screen size
   * @returns Screen size string
   */
  public static getDisplay(): string {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return `${defaultDisplay.width}x${defaultDisplay.height}`;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get display: ${error}`);
      const width = DeviceUtils.getScreenWidth();
      const height = DeviceUtils.getScreenHeight();
      return `${width}x${height}`;
    }
  }

  /**
   * Get screen width
   * @returns Screen width
   */
  public static getScreenWidth(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return defaultDisplay.width;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen width: ${error}`);
      try {
        const systemInfo = globalThis.systemInfo as Record<string, number>;
        if (systemInfo && systemInfo.screenWidth) {
          return systemInfo.screenWidth;
        }
      } catch (fallbackError) {
        FTInnerLogger.e(TAG, `Failed to get screen width from system info: ${fallbackError}`);
      }
      return 1080;
    }
  }

  /**
   * Get screen height
   * @returns Screen height
   */
  public static getScreenHeight(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return defaultDisplay.height;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen height: ${error}`);
      try {
        const systemInfo = globalThis.systemInfo as Record<string, number>;
        if (systemInfo && systemInfo.screenHeight) {
          return systemInfo.screenHeight;
        }
      } catch (fallbackError) {
        FTInnerLogger.e(TAG, `Failed to get screen height from system info: ${fallbackError}`);
      }
      return 2400;
    }
  }

  /**
   * Get screen density
   * @returns Screen density
   */
  public static getScreenDensity(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return defaultDisplay.scaledDensity;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen density: ${error}`);
      return 1.0;
    }
  }

  /**
   * Get screen DPI
   * @returns Screen DPI
   */
  public static getScreenDPI(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return defaultDisplay.densityDPI;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen DPI: ${error}`);
      return 160;
    }
  }

  /**
   * Get screen density category
   * @returns Screen density category string
   */
  public static getScreenDensityCategory(): string {
    try {
      const density = DeviceUtils.getScreenDensity();
      if (density <= 0.75) {
        return 'ldpi'; // Low density
      } else if (density <= 1.0) {
        return 'mdpi'; // Medium density
      } else if (density <= 1.5) {
        return 'hdpi'; // High density
      } else if (density <= 2.0) {
        return 'xhdpi'; // Extra high density
      } else if (density <= 3.0) {
        return 'xxhdpi'; // Extra extra high density
      } else {
        return 'xxxhdpi'; // Extra extra extra high density
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen density category: ${error}`);
      return 'mdpi';
    }
  }

  /**
   * Get screen detailed information
   * @returns Screen information object
   */
  public static getScreenInfo(): ScreenInfo {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return {
        width: defaultDisplay.width,
        height: defaultDisplay.height,
        density: defaultDisplay.scaledDensity,
        dpi: defaultDisplay.densityDPI,
        category: DeviceUtils.getScreenDensityCategory()
      };
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get screen info: ${error}`);
      return {
        width: 1080,
        height: 2400,
        density: 1.0,
        dpi: 160,
        category: 'mdpi'
      };
    }
  }

  /**
   * Get RAM capacity and usage
   * @returns RAM information array [total capacity(GB), usage rate(%)]
   */
  public static async getRamData(): Promise<number[]> {
    /*
    try {
      // In HarmonyOS, get memory information through systemParameter
      const totalMemory = parseInt(systemParameter.getParameter('const.memory.total') as string) || 4096; // MB
      const availableMemory = parseInt(systemParameter.getParameter('const.memory.available') as string) || 3072; // MB
      const usedMemory = totalMemory - availableMemory;
      
      const totalGB = Utils.formatDouble(totalMemory / 1024, 2);
      const usedPercentage = Utils.formatDouble((usedMemory / totalMemory) * 100, 2);
      return [totalGB, usedPercentage];
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get RAM data: ${error}`);
      return [4.0, 25.0];
    }
    */

    return [4.0, 25.0];
  }

  /**
   * Get application memory usage (bytes)
   * @returns Memory usage
   */
  public static getAppMemoryUseSize(): number {
    /*
    try {
      // In HarmonyOS, get application memory usage through systemParameter
      const appMemoryMB = parseInt(systemParameter.getParameter('const.app.memory.used') as string) || 0;
      return appMemoryMB * 1024 * 1024; // Convert to bytes
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get app memory usage: ${error}`);
      return 0;
    }
    */
    return 0;
  }

  /**
   * Get CPU usage rate
   * @returns CPU usage percentage
   */
  public static getCpuUsage(): number {
    try {
      // HarmonyOS currently has no direct API to get CPU usage rate
      // Return a mock value here, actual projects can get it through other methods
      return Utils.randomFloat(10, 80, 1);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get CPU usage: ${error}`);
      return 0;
    }
  }

  /**
   * Get CPU context switch count
   * @returns CPU context switch count
   */
  public static getCpuTickCount(): number {
    try {
      // HarmonyOS currently has no direct API to get CPU context switch count
      // Return a mock value here
      return Utils.randomNumber(1000, 10000);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get CPU tick count: ${error}`);
      return 0;
    }
  }

  /**
   * Get CPU context switches per second
   * @returns CPU context switches per second
   */
  public static getCpuTickCountPerSecond(): number {
    try {
      // HarmonyOS currently has no direct API to get CPU context switch count
      // Return a mock value here
      return Utils.randomNumber(100, 1000);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get CPU tick count per second: ${error}`);
      return 0;
    }
  }

  /**
   * Get device carrier information
   * @returns Carrier name
   */
  public static async getCarrier(): Promise<string> {
    try {
      // HarmonyOS currently has no direct API to get carrier information
      // Return a default value here
      return 'China Mobile';
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get carrier: ${error}`);
      return 'Unknown';
    }
  }

  /**
   * Check if it is a TV device
   * @returns Whether it is a TV
   */
  public static isTv(): boolean {
    try {
      // Determine if it is a TV by screen size
      const width = DeviceUtils.getScreenWidth();
      const height = DeviceUtils.getScreenHeight();
      return width >= 1920 && height >= 1080;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to check if TV: ${error}`);
      return false;
    }
  }

  /**
   * Get device type
   * @returns Device type
   */
  public static getDeviceType(): string {
    try {
      if (DeviceUtils.isTv()) {
        return 'TV';
      }
      
      const width = DeviceUtils.getScreenWidth();
      const height = DeviceUtils.getScreenHeight();
      
      if (width < 600) {
        return 'Phone';
      } else if (width < 1200) {
        return 'Tablet';
      } else {
        return 'Desktop';
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get device type: ${error}`);
      return 'Phone';
    }
  }

  /**
   * Get device manufacturer
   * @returns Device manufacturer
   */
  public static async getManufacturer(): Promise<string> {
    try {
      const manufacturer = 'Huawei'; // Default manufacturer
      return Utils.isNotEmpty(manufacturer) ? manufacturer : 'HUAWEI';
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get manufacturer: ${error}`);
      return 'HUAWEI';
    }
  }

  /**
   * Get device battery information
   * @returns Battery information
   */
  public static async getBatteryInfo(): Promise<BatteryInfo> {
    try {
      return {
        level: 0,
        charging: false,
        chargingTime: 0,
        dischargingTime: 0
      };
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get battery info: ${error}`);
      return {
        level: 0,
        charging: false,
        chargingTime: 0,
        dischargingTime: 0
      };
    }
  }


  /**
   * Get network type
   * Using HarmonyOS @ohos.net.connection API
   * @returns Network type string (e.g., "wifi", "2g", "3g", "4g", "5g", "unknown")
   */
  public static async getNetworkType(): Promise<string> {
    try {
      if (!connection.hasDefaultNetSync()) {
        return "unknown";
      }
      
      const netHandle = connection.getDefaultNetSync();
      if (!netHandle) {
        return "unknown";
      }
      
      const capabilities = connection.getNetCapabilitiesSync(netHandle);
      if (!capabilities || !capabilities.bearerTypes || !Array.isArray(capabilities.bearerTypes)) {
        return "unknown";
      }
      
      const bearerTypes = capabilities.bearerTypes;
      const hasWifi = bearerTypes.includes(1);
      const hasCellular = bearerTypes.includes(0) || bearerTypes.includes(2) || 
                         (bearerTypes.includes(3) && (DeviceUtils.getDeviceType() === 'Phone' || DeviceUtils.getDeviceType() === 'Tablet'));
      
      // Try to get detailed cellular type if cellular exists
      if (hasCellular) {
        const cellularType = await DeviceUtils.tryGetCellularType();
        if (cellularType && cellularType !== "cellular" && cellularType !== "unknown") {
          return cellularType;
        }
      }
      
      // Return WiFi if available
      if (hasWifi) {
        return "wifi";
      }
      
      // Check bearerType 0 (cellular)
      if (bearerTypes.includes(0)) {
        const cellularType = await DeviceUtils.tryGetCellularType();
        return cellularType || "cellular";
      }
      
      // Check bearerType 3 (Ethernet on non-mobile, or cellular on mobile)
      if (bearerTypes.includes(3)) {
        const deviceType = DeviceUtils.getDeviceType();
        if (deviceType === 'Phone' || deviceType === 'Tablet') {
          const cellularType = await DeviceUtils.tryGetCellularType();
          return cellularType || "cellular";
        }
        return "ethernet";
      }
      
      return "unknown";
    } catch (error) {
      FTInnerLogger.e(TAG, `[getNetworkType] Failed to get network type: ${error}`);
      return "unknown";
    }
  }

  /**
   * Try to get detailed cellular network type (2g/3g/4g/5g)
   * @returns Network type string or null if failed
   */
  private static async tryGetCellularType(): Promise<string | null> {
    try {
      const slotId: number = await data.getDefaultCellularDataSlotId();
      if (slotId < 0) {
        return null;
      }
      
      const signals = radio.getSignalInformationSync(slotId);
      if (!signals || signals.length === 0 || !signals[0]) {
        return null;
      }
      
      return DeviceUtils.mapNetworkType(signals[0].signalType);
    } catch (err) {
      return null;
    }
  }

  /**
   * Get network type synchronously
   * @returns Network type string (e.g., "wifi", "2g", "3g", "4g", "5g", "ethernet", "unknown")
   */
  public static getNetworkTypeSync(): string {
    try {
      if (!connection.hasDefaultNetSync()) {
        return "unknown";
      }
      
      const netHandle = connection.getDefaultNetSync();
      if (!netHandle) {
        return "unknown";
      }
      
      const capabilities = connection.getNetCapabilitiesSync(netHandle);
      if (!capabilities || !capabilities.bearerTypes || !Array.isArray(capabilities.bearerTypes)) {
        return "unknown";
      }
      
      const bearerTypes = capabilities.bearerTypes;
      const hasWifi = bearerTypes.includes(1);
      const hasCellular = bearerTypes.includes(0) || bearerTypes.includes(2) || 
                         (bearerTypes.includes(3) && (DeviceUtils.getDeviceType() === 'Phone' || DeviceUtils.getDeviceType() === 'Tablet'));
      
      // Try to get detailed cellular type if cellular exists
      if (hasCellular) {
        const cellularType = DeviceUtils.tryGetCellularTypeSync();
        if (cellularType && cellularType !== "cellular" && cellularType !== "unknown") {
          return cellularType;
        }
      }
      
      // Return WiFi if available
      if (hasWifi) {
        return "wifi";
      }
      
      // Check bearerType 0 (cellular)
      if (bearerTypes.includes(0)) {
        const cellularType = DeviceUtils.tryGetCellularTypeSync();
        return cellularType || "cellular";
      }
      
      // Check bearerType 3 (Ethernet on non-mobile, or cellular on mobile)
      if (bearerTypes.includes(3)) {
        const deviceType = DeviceUtils.getDeviceType();
        if (deviceType === 'Phone' || deviceType === 'Tablet') {
          const cellularType = DeviceUtils.tryGetCellularTypeSync();
          return cellularType || "cellular";
        }
        return "ethernet";
      }
      
      return "unknown";
    } catch (error) {
      FTInnerLogger.e(TAG, `[getNetworkTypeSync] Failed to get network type: ${error}`);
      return "unknown";
    }
  }

  /**
   * Try to get detailed cellular network type synchronously (2g/3g/4g/5g)
   * Uses default slotId (0) since getDefaultCellularDataSlotId() is async
   * @returns Network type string or null if failed
   */
  private static tryGetCellularTypeSync(): string | null {
    try {
      const slotId = 0;
      const signals = radio.getSignalInformationSync(slotId);
      if (!signals || signals.length === 0 || !signals[0]) {
        return null;
      }
      return DeviceUtils.mapNetworkType(signals[0].signalType);
    } catch (err) {
      return null;
    }
  }


  /**
   * Map network type from HarmonyOS NetworkType enum to standard format
   * @param type NetworkType enum value
   * @returns Network type string (e.g., "2g", "3g", "4g", "5g", "cellular")
   */
  private static mapNetworkType(type: radio.NetworkType): string {
    if (type === radio.NetworkType.NETWORK_TYPE_NR) {
      return "5g";
    }
    if (type === radio.NetworkType.NETWORK_TYPE_LTE) {
      return "4g";
    }
    if (type === radio.NetworkType.NETWORK_TYPE_WCDMA || type === radio.NetworkType.NETWORK_TYPE_TDSCDMA) {
      return "3g";
    }
    if (type === radio.NetworkType.NETWORK_TYPE_GSM || type === radio.NetworkType.NETWORK_TYPE_CDMA) {
      return "2g";
    }
    return "cellular";
  }

}
