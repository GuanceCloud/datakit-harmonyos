/**
 * Device UUID Manager for HarmonyOS SDK
 * Manages device UUID generation using HarmonyOS ODID (Open Device Identifier)
 *
 * Features:
 * - Official ODID support (deviceInfo.odid) - Huawei recommended
 * - Fallback to UDID (deviceInfo.udid) if ODID not available
 * - Fallback to random UUID if both not available
 * - Privacy mode support (disable system ID access)
 * - Persistence across app uninstall/reinstall
 */
import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from './Utils';
import { Constants } from '../Constants';
import deviceInfo from '@ohos.deviceInfo';

const TAG = "DeviceUUIDManager";

/**
 * Device UUID Manager
 * Handles device UUID generation and persistence for HarmonyOS SDK
 * Aligned with Android LocalUUIDManager logic
 */
export class DeviceUUIDManager {
  private static instance: DeviceUUIDManager | null = null;
  private preferencesStore: preferences.Preferences | null = null;
  private deviceUUID: string = "";
  private randomUUID: string = ""; // Cached random UUID (for privacy mode)
  private isInitialized: boolean = false;
  private preferencesInitPromise: Promise<void> | null = null;
  // Constants
  private static readonly PREFERENCES_NAME = 'ftSDKDeviceFile';

  private constructor() {
    // Private constructor to enforce singleton pattern
  }

  /**
   * Get the singleton instance of DeviceUUIDManager
   * @returns The singleton instance
   */
  public static getInstance(): DeviceUUIDManager {
    if (!DeviceUUIDManager.instance) {
      DeviceUUIDManager.instance = new DeviceUUIDManager();
    }
    return DeviceUUIDManager.instance;
  }

  /**
   * Initialize the DeviceUUIDManager with the application context
   * @param context The UIAbilityContext of the application
   */
  public init(context: common.UIAbilityContext): void {
    if (this.isInitialized) {
      return;
    }
    this.isInitialized = true;
    this.preferencesInitPromise = this.initializePreferences(context);
  }

  /** Internal readiness fence used to refresh derived SDK tags after async restore. */
  public waitForPreferencesReady(): Promise<void> {
    return this.preferencesInitPromise || Promise.resolve();
  }

  private async initializePreferences(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: DeviceUUIDManager.PREFERENCES_NAME });
      this.preferencesStore = store;
      await this.loadRandomUUIDFromPreferences(store);
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to initialize DeviceUUIDManager: ${error}`);
    }
  }

  /**
   * Initialize random UUID (aligned with Android LocalUUIDManager.initRandomUUID())
   * Creates and saves random UUID if it doesn't exist in preferences
   * Synchronously sets memory cache, then asynchronously saves to preferences
   */
  public initRandomUUID(): void {
    const existingUUID = this.getRandomUUID();
    if (Utils.isEmpty(existingUUID)) {
      // Generate UUID and remove dashes (aligned with Android Utils.randomUUID())
      const uuid = Utils.generateUUID();
      this.randomUUID = "ft.rd_" + uuid;

      // Asynchronously save to preferences (aligned with Android SharedPreferences.apply())
      this.saveRandomUUIDToPreferences().catch((err: ESObject) => {
        const errorMsg = err instanceof Error ? err.message : String(err);
        FTInnerLogger.e(TAG, ` Failed to save random UUID: ${errorMsg}`);
      });
    }
  }

  /**
   * Save random UUID to preferences (asynchronous, aligned with Android SharedPreferences.apply())
   */
  private async saveRandomUUIDToPreferences(): Promise<void> {
    if (this.preferencesStore && Utils.isNotEmpty(this.randomUUID)) {
      try {
        await this.preferencesStore.put(Constants.FT_RANDOM_USER_ID, this.randomUUID);
        await this.preferencesStore.flush();
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        FTInnerLogger.e(TAG, ` Failed to save random UUID: ${errorMsg}`);
      }
    }
  }

  /**
   * Load random UUID from preferences asynchronously (called during init)
   */
  private async loadRandomUUIDFromPreferences(store: preferences.Preferences): Promise<void> {
    try {
      const storedUUID = await store.get(Constants.FT_RANDOM_USER_ID, "");
      if (storedUUID !== null && storedUUID !== undefined) {
        const uuidString = typeof storedUUID === 'string' ? storedUUID : String(storedUUID);
        if (Utils.isNotEmpty(uuidString)) {
          this.randomUUID = uuidString;
          if (this.deviceUUID.startsWith('ft.rd_')) {
            this.deviceUUID = uuidString;
          }
          return;
        }
      }
      if (Utils.isNotEmpty(this.randomUUID)) {
        await this.saveRandomUUIDToPreferences();
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      FTInnerLogger.e(TAG, ` Failed to load random UUID from preferences: ${errorMsg}`);
    }
  }

  /**
   * Get random UUID (aligned with Android LocalUUIDManager.getRandomUUID())
   * If local cache exists, get from local; otherwise create new one
   * Format: ft.rd_ + 32-char UUID (without dashes)
   * Note: This is synchronous - UUID should be pre-loaded in init() or created here if missing
   * @returns Random UUID string
   */
  public getRandomUUID(): string {
    // Check memory cache first (aligned with Android)
    if (Utils.isNotEmpty(this.randomUUID)) {
      return this.randomUUID;
    }

    // On first install, or when no cache is available, create a random UUID synchronously.
    FTInnerLogger.d(TAG, `Random UUID not found in cache; creating a new one`);
    // Generate UUID synchronously and save asynchronously (same logic as initRandomUUID)
    const uuid = Utils.generateUUID();
    this.randomUUID = "ft.rd_" + uuid;

    // Asynchronously save to preferences
    this.saveRandomUUIDToPreferences().catch((err: ESObject) => {
      const errorMsg = err instanceof Error ? err.message : String(err);
      FTInnerLogger.e(TAG, ` Failed to save random UUID: ${errorMsg}`);
    });

    return this.randomUUID;
  }


  /**
   * Get device UUID using ODID (Open Device Identifier) - Huawei recommended
   * Aligned with Android: when enableSystemID=false, use LocalUUIDManager.getRandomUUID()
   * @param enableSystemID Whether to enable system ID access
   * @returns Device UUID
   */
  public getDeviceUUID(enableSystemID: boolean = true): string {
    if (!enableSystemID) {
      // Privacy mode: return persisted random UUID (aligned with Android LocalUUIDManager.getRandomUUID())
      const randomUUID = this.getRandomUUID();
      this.deviceUUID = randomUUID; // Store for getDeviceUUIDType()
      return randomUUID;
    }

    // Try ODID first (Huawei recommended)
    try {
      const odid = deviceInfo.ODID;

      if (Utils.isNotEmpty(odid)) {
        this.deviceUUID = odid; // Store for getDeviceUUIDType()
        return odid;
      } else {
        FTInnerLogger.w(TAG, ` ODID is empty, trying UDID fallback`);
      }
    } catch (error) {
      FTInnerLogger.w(TAG, ` Failed to get ODID: ${error}, trying UDID fallback`);
    }

    // Fallback to UDID if ODID not available
    try {
      const udid = deviceInfo.udid;

      if (Utils.isNotEmpty(udid)) {
        this.deviceUUID = udid; // Store for getDeviceUUIDType()
        return udid;
      } else {
        FTInnerLogger.w(TAG, ` UDID is also empty, generating random UUID`);
      }
    } catch (error) {
      FTInnerLogger.w(TAG, ` Failed to get UDID: ${error}, generating random UUID`);
    }

    // Final fallback to random UUID (use persisted one)
    const randomUUID = this.getRandomUUID();
    this.deviceUUID = randomUUID; // Store for getDeviceUUIDType()
    FTInnerLogger.w(TAG, ` Both ODID and UDID unavailable, using persisted random UUID`);
    return randomUUID;
  }

  /**
   * Get device UUID type based on the actual UUID returned
   * @param uuid Optional UUID to check. If not provided, uses current deviceUUID
   * @returns 'odid', 'udid', 'random', or 'unknown'
   */
  public getDeviceUUIDType(uuid?: string): string {
    let uuidType = 'unknown';
    const uuidToCheck = uuid || this.deviceUUID;

    // Check if we have a UUID to check
    if (uuidToCheck && Utils.isNotEmpty(uuidToCheck)) {
      if (uuidToCheck.startsWith('ft.rd_')) {
        uuidType = 'random';
      } else {
        // Check if it's ODID or UDID by trying to get current values
        try {
          const currentOdid = deviceInfo.ODID;
          if (Utils.isNotEmpty(currentOdid) && uuidToCheck === currentOdid) {
            uuidType = 'odid';
          } else {
            const currentUdid = deviceInfo.udid;
            if (Utils.isNotEmpty(currentUdid) && uuidToCheck === currentUdid) {
              uuidType = 'udid';
            } else {
              uuidType = 'system'; // Fallback for other system IDs
            }
          }
        } catch (error) {
          uuidType = 'system'; // Fallback if unable to determine
        }
      }
    }

    return uuidType;
  }

}
