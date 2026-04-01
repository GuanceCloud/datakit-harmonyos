/**
 * Type definitions for FT Native Crash NAPI module
 * This file provides TypeScript type hints for the native C++ module
 */

/**
 * Native crash data interface
 */
export interface NativeCrashData {
    timestamp: number;
    crashType: string;      // "JsError" or "NativeCrash"
    foreground: boolean;
    bundleVersion: string;
    bundleName: string;
    pid: number;
    uid: number;
    uuid: string;
    exception: string;      // JSON string containing exception details
    hilogSize: number;
    externalLog: string;    // JSON string containing external log paths
    logOverLimit: boolean;
    memoryNearRegisters: string;  // Memory dump near registers
    maps: string;           // Memory maps information
    hilog: string;          // System log content
}

/**
 * FT Native Crash module interface
 */
export interface FTNativeCrashModule {
    /**
     * Initialize the native crash handler
     * @returns true if successful, false otherwise
     */
    initNativeCrashHandler(): boolean;

    /**
     * Set the crash callback function
     * @param callback Callback function to receive crash events
     * @returns true if successful, false otherwise
     */
    setCrashCallback(callback: (crashData: NativeCrashData) => void): boolean;

    /**
     * Start watching for crash events
     * @returns true if successful, false otherwise
     */
    startWatching(): boolean;

    /**
     * Stop watching for crash events
     * @returns true if successful, false otherwise
     */
    stopWatching(): boolean;

    /**
     * Add a log entry to the runtime log buffer for crash reporting
     * @param level Log level (e.g., "D", "I", "W", "E")
     * @param tag Log tag
     * @param message Log message
     * @returns true if successful, false otherwise
     */
    addLog(level: string, tag: string, message: string): boolean;

    /**
     * Get collected runtime logs
     * @param maxLines Maximum number of lines to retrieve (0 for all)
     * @returns Collected logs as a string
     */
    getCollectedLogs(maxLines?: number): string;

    /**
     * Clear the runtime log buffer
     * @returns true if successful, false otherwise
     */
    clearLogs(): boolean;

    /**
     * Set the maximum log buffer size
     * @param maxSize Maximum number of log entries to keep
     * @returns true if successful, false otherwise
     */
    setMaxLogSize(maxSize: number): boolean;
}

/**
 * Declare the native module
 */
declare const ftnativecrash: FTNativeCrashModule;

export default ftnativecrash;
