/**
 * Device detection type
 * In View transmission type startView
 * Output the battery, memory, CPU, FPS, etc. of the page
 * Device Metrics Monitor Type for HarmonyOS
 */
export enum DeviceMetricsMonitorType {
  /**
   * All types (BATTERY, MEMORY, CPU, FPS)
   */
  ALL = 0xFFFFFFFF,
  /**
   * Battery current remaining, TV devices do not support
   */
  BATTERY = 1 << 1,
  /**
   * Device memory usage
   */
  MEMORY = 1 << 2,
  /**
   * Device CPU usage
   */
  CPU = 1 << 3,
  /**
   * Frame number
   */
  FPS = 1 << 4
}

/**
 * Not set, used for monitoring un-set judgment
 */
export const DEVICE_METRICS_MONITOR_NO_SET = 0;
