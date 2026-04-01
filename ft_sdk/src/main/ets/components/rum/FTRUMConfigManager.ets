/**
 * HarmonyOS SDK RUM Configuration Manager
 * Reference HarmonyOS SDK: FTRUMConfigManager
 */
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { DeviceUtils } from '../utils/DeviceUtils';
import { Utils } from '../utils';
import { FTRUMConfig } from '../Configs';
import { UserDataManager } from './UserDataManager';

const TAG = "FTRUMConfigManager";

/**
 * RUM configuration manager
 * Manages RUM configuration and provides RUM-related functionality
 */
export class FTRUMConfigManager {
  private static instance: FTRUMConfigManager | null = null;
  private config: FTRUMConfig | null = null;

  private constructor() {
    // Private constructor for singleton
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): FTRUMConfigManager {
    if (!FTRUMConfigManager.instance) {
      FTRUMConfigManager.instance = new FTRUMConfigManager();
    }
    return FTRUMConfigManager.instance;
  }


  initWithConfig(config: FTRUMConfig): void {
    this.config = config;
  }

  initRUMGlobalContext(config: FTRUMConfig): void {
    this.config = config;
  }

  public getConfig(): FTRUMConfig | null {
    return this.config;
  }

  public isRumEnable(): boolean {
    return this.config !== null && this.config.getRumAppId().length > 0;
  }

  public isResourceTraceEnable(): boolean {
    return this.config !== null && this.config.isEnableTraceUserResource();
  }

  /**
   * Get RUM public dynamic tags
   * Reference HarmonyOS: FTRUMConfigManager.getRUMPublicDynamicTags()
   */
  public getRUMPublicDynamicTags(): Record<string, string> {
    const tags: Record<string, string> = {};

    const userData = UserDataManager.getInstance().getUserData()

    // Network type
    tags[Constants.KEY_RUM_NETWORK_TYPE] = this.getNetworkType();
    tags[Constants.KEY_RUM_IS_SIGN_IN] = userData?"T":"F";

    // User data
    if (userData) {
      tags[Constants.KEY_RUM_USER_ID] = userData.getId() || Utils.generateUUID();

      if (userData.getName()) {
        tags[Constants.KEY_RUM_USER_NAME] = userData.getName();
      }

      if (userData.getEmail()) {
        tags[Constants.KEY_RUM_USER_EMAIL] = userData.getEmail();
      }

      if (userData) {
        const userExts = userData.getExts();
        const extEntries = Object.entries(userExts);
        for (let i = 0; i < extEntries.length; i++) {
          const key = extEntries[i][0];
          const value = extEntries[i][1];
          if (key !== Constants.KEY_RUM_USER_ID &&
            key !== Constants.KEY_RUM_USER_NAME &&
            key !== Constants.KEY_RUM_USER_EMAIL) {
            tags[key] = value;
          }
        }
      }
    } else {
      tags[Constants.KEY_RUM_USER_ID] = Utils.generateUUID();
    }
    return tags;
  }

  /**
   * Get network type
   * Use DeviceUtils to get real network type (single source of truth)
   */
  private getNetworkType(): string {
    // Use DeviceUtils synchronous method to get network type
    return DeviceUtils.getNetworkTypeSync();
  }


  /**
   * Release resources
   */
  public release(): void {
    this.config = null;
    FTInnerLogger.d(TAG, "FTRUMConfigManager released");
  }
}
