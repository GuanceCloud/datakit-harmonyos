/**
 * HarmonyOS SDK database configuration class
 */
export class FTDBConfig {
  /**
   * Database name
   */
  public static readonly DATABASE_NAME: string = "ft_sdk_database.db";

  /**
   * Database version number
   */
  public static readonly DATABASE_VERSION: number = 1;

  /**
   * Database security level
   */
  public static readonly SECURITY_LEVEL: number = 1; // S1 level

  /**
   * Database storage type
   */
  public static readonly STORE_TYPE: string = "RDB";

  /**
   * Database encryption mode
   */
  public static readonly ENCRYPT_MODE: boolean = false;

  /**
   * Database backup mode
   */
  public static readonly BACKUP_MODE: boolean = true;

  /**
   * Database auto cleanup mode
   */
  public static readonly AUTO_CLEANUP_MODE: boolean = true;
}
