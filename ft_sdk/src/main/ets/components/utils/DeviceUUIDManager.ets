/**
 * Device UUID Manager for HarmonyOS SDK
 * Manages device UUID generation using HarmonyOS ODID (Open Device Identifier)
 *
 * Features:
 * - Official ODID support (deviceInfo.odid) - Huawei recommended
 * - Fallback to UDID (deviceInfo.udid) if ODID not available
 * - Fallback to random UUID if both not available
 * - Privacy mode support (disable system ID access)
 * - Random UUID persistence across app restarts while application data is retained
 */
import { Context } from '@kit.AbilityKit';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from './Utils';
import deviceInfo from '@ohos.deviceInfo';
import { DeviceUUIDStorage, DeviceUUIDStorageFactory, PreferencesDeviceUUIDStorage } from './DeviceUUIDStorage';

const TAG = "DeviceUUIDManager";

/**
 * Device UUID Manager
 * Handles device UUID generation and persistence for HarmonyOS SDK
 * Aligned with Android LocalUUIDManager logic
 */
export class DeviceUUIDManager {
  private static instance: DeviceUUIDManager | null = null;
  private static storageFactory: DeviceUUIDStorageFactory =
    (context: Context): DeviceUUIDStorage => new PreferencesDeviceUUIDStorage(context);
  private context: Context | null = null;
  private storage: DeviceUUIDStorage | null = null;
  private deviceUUID: string = "";
  private randomUUID: string = ""; // Cached random UUID (for privacy mode)
  private isInitialized: boolean = false;
  private persistedUUID: string = '';
  private persistenceInFlight: boolean = false;
  private persistencePromise: Promise<void> = Promise.resolve();
  private persistenceRetryTimer: number | null = null;
  private persistenceRetries: number = 0;
  private restoreRetryTimer: number | null = null;
  private restoreRetries: number = 0;
  private restoreListener: (() => void) | null = null;
  private released: boolean = false;
  private static readonly MAX_PERSISTENCE_RETRIES: number = 3;

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

  /** Restore the UUID before the SDK publishes its first device tags. */
  public init(context: Context): void {
    if (this.isInitialized) {
      return;
    }
    this.context = context;
    try {
      if (this.storage === null) {
        this.storage = DeviceUUIDManager.storageFactory(context);
      }
      const previousUUID = this.randomUUID;
      const storedUUID = this.storage.load();
      if (Utils.isNotEmpty(storedUUID)) {
        this.randomUUID = storedUUID;
        if (this.deviceUUID.startsWith('ft.rd_')) {
          this.deviceUUID = storedUUID;
        }
      } else if (Utils.isEmpty(this.randomUUID)) {
        // Successful absence is the only condition that permits generation.
        // Generate here so timer-driven recovery can refresh device tags too.
        this.randomUUID = 'ft.rd_' + Utils.generateUUID();
      }
      // A failed read must remain retryable and must not overwrite an identity
      // that may still exist on disk with a temporary memory UUID.
      this.isInitialized = true;
      this.restoreRetries = 0;
      if (this.restoreRetryTimer !== null) {
        clearTimeout(this.restoreRetryTimer);
        this.restoreRetryTimer = null;
      }
      if (Utils.isNotEmpty(this.randomUUID)) {
        this.persistRandomUUID();
      }
      if (previousUUID !== this.randomUUID && this.restoreListener !== null) {
        try {
          this.restoreListener();
        } catch (error) {
          FTInnerLogger.w(TAG, `Failed to refresh restored device UUID tags: ${error}`);
        }
      }
    } catch (error) {
      this.storage = null;
      FTInnerLogger.e(TAG, ` Failed to initialize DeviceUUIDManager: ${error}`);
      this.scheduleRestoreRetry();
    }
  }

  /**
   * Generate only when no restored or in-memory UUID exists.
   */
  public initRandomUUID(): void {
    this.getRandomUUID();
  }

  /**
   * Commit the file before returning the UUID, then repair Preferences with
   * bounded retries. Each attempt keeps the same UUID.
   */
  private persistRandomUUID(): void {
    if (!this.isInitialized || this.storage === null || this.released ||
      Utils.isEmpty(this.randomUUID) || this.persistedUUID === this.randomUUID ||
      this.persistenceInFlight || this.persistenceRetryTimer !== null) {
      return;
    }
    const uuid = this.randomUUID;
    let fileSaved = false;
    try {
      this.storage.save(uuid);
      fileSaved = true;
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to save device UUID file: ${error}`);
    }
    this.persistenceInFlight = true;
    this.persistencePromise = this.storage.flushPreferences(uuid).then((): void => {
      if (fileSaved) {
        this.persistedUUID = uuid;
        this.persistenceRetries = 0;
      } else {
        this.schedulePersistenceRetry();
      }
    }).catch((error: Error): void => {
      FTInnerLogger.e(TAG, ` Failed to save random UUID Preferences: ${error}`);
      this.schedulePersistenceRetry();
    }).finally((): void => {
      this.persistenceInFlight = false;
    });
  }

  private schedulePersistenceRetry(): void {
    if (this.released || this.persistenceRetries >= DeviceUUIDManager.MAX_PERSISTENCE_RETRIES ||
      this.persistenceRetryTimer !== null) {
      return;
    }
    const delayMs = 250 * Math.pow(2, this.persistenceRetries++);
    this.persistenceRetryTimer = setTimeout((): void => {
      this.persistenceRetryTimer = null;
      this.persistRandomUUID();
    }, delayMs);
  }

  private scheduleRestoreRetry(): void {
    if (this.released || this.context === null || this.restoreRetryTimer !== null ||
      this.restoreRetries >= DeviceUUIDManager.MAX_PERSISTENCE_RETRIES) {
      return;
    }
    this.restoreRetryTimer = setTimeout((): void => {
      this.restoreRetryTimer = null;
      if (!this.released && this.context !== null) {
        this.init(this.context);
      }
    }, 250 * Math.pow(2, this.restoreRetries++));
  }

  /** Only fault recovery needs a later tag refresh; normal restoration is synchronous. */
  public setRestoreListenerInternal(listener: () => void): void {
    this.restoreListener = listener;
  }

  /** Internal test seams; never exported from the public SDK entry point. */
  public waitForPersistenceInternal(): Promise<void> {
    return this.persistencePromise;
  }

  public static setStorageFactoryInternal(factory: DeviceUUIDStorageFactory): void {
    DeviceUUIDManager.resetStateInternal();
    DeviceUUIDManager.storageFactory = factory;
  }

  public static resetStateInternal(): void {
    const instance = DeviceUUIDManager.instance;
    if (instance !== null) {
      instance.released = true;
      if (instance.persistenceRetryTimer !== null) {
        clearTimeout(instance.persistenceRetryTimer);
      }
      if (instance.restoreRetryTimer !== null) {
        clearTimeout(instance.restoreRetryTimer);
      }
      instance.restoreListener = null;
    }
    DeviceUUIDManager.instance = null;
    DeviceUUIDManager.storageFactory =
      (context: Context): DeviceUUIDStorage => new PreferencesDeviceUUIDStorage(context);
  }

  /**
   * Get random UUID (aligned with Android LocalUUIDManager.getRandomUUID())
   * If local cache exists, get from local; otherwise create new one
   * Format: ft.rd_ + 32-char UUID (without dashes)
   * init() restores the persisted value synchronously before SDK data is created.
   * @returns Random UUID string
   */
  public getRandomUUID(): string {
    if (!this.isInitialized && this.context !== null) {
      this.init(this.context);
    }
    // Until a read succeeds, neither absence nor the stored identity is known.
    // Collectors omit the tag instead of publishing a temporary identity.
    if (!this.isInitialized) {
      return '';
    }
    if (Utils.isEmpty(this.randomUUID)) {
      this.randomUUID = "ft.rd_" + Utils.generateUUID();
    }
    this.persistRandomUUID();
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
