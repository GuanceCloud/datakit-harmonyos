/**
 * Type declarations for FT Native Crash Native Module
 */
declare module 'libftnativecrash.so' {
  export interface NativeCrashData {
    timestamp: number;
    crashType: string;
    foreground: boolean;
    bundleVersion: string;
    bundleName: string;
    pid: number;
    uid: number;
    appRunningUniqueId?: string;
    uuid: string;
    exception: string;
    hilogSize: number;
    externalLog: string;
    logOverLimit: boolean;
    memoryNearRegisters: string;
    maps: string;
    hilog: string;
  }

  export type NativeCrashCallback = (crashData: NativeCrashData) => void | Promise<void>;

  /**
   * Initialize the native crash handler
   * @returns true if successful, false otherwise
   */
  export function initNativeCrashHandler(): boolean;

  /**
   * Set the crash callback function
   * @param callback Callback function to receive crash events
   * @returns true if successful, false otherwise
   */
  export function setCrashCallback(callback: NativeCrashCallback): boolean;

  /**
   * Clear the crash callback function.
   */
  export function clearCrashCallback(): boolean;

  /**
   * Start watching for crash events
   * @returns true if successful, false otherwise
   */
  export function startWatching(): boolean;

  /**
   * Stop watching for crash events
   * @returns true if successful, false otherwise
   */
  export function stopWatching(): boolean;

  /**
   * Add a log entry to the runtime log buffer for crash reporting
   * @param level Log level (e.g., "D", "I", "W", "E")
   * @param tag Log tag
   * @param message Log message
   * @returns true if successful, false otherwise
   */
  export function addLog(level: string, tag: string, message: string): boolean;

  /**
   * Get collected runtime logs
   * @param maxLines Maximum number of lines to retrieve (0 for all)
   * @returns Collected logs as a string
   */
  export function getCollectedLogs(maxLines?: number): string;

  /**
   * Clear the runtime log buffer
   * @returns true if successful, false otherwise
   */
  export function clearLogs(): boolean;

  /**
   * Set the maximum log buffer size
   * @param maxSize Maximum number of log entries to keep
   * @returns true if successful, false otherwise
   */
  export function setMaxLogSize(maxSize: number): boolean;

  /**
   * Get the native crash handler version.
   * @returns Version string reported by the C++ module
   */
  export function getVersion(): string;
}
