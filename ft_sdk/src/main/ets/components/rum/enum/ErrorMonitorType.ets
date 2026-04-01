/**
 * Error detection type, automatically added when calling addError in Error transmission type
 * Error Monitor Type for HarmonyOS
 */
export enum ErrorMonitorType {
  /**
   * All types (BATTERY, MEMORY, CPU)
   */
  ALL = 0xFFFFFFFF,
  /**
   * Current battery level of the phone, TV devices do not support
   */
  BATTERY = 1 << 1,
  /**
   * Current memory of the phone
   */
  MEMORY = 1 << 2,
  /**
   * Current CPU load
   */
  CPU = 1 << 3
}

/**
 * Unset state, used for monitoring unset judgment
 */
export const ERROR_MONITOR_NO_SET = 0;
