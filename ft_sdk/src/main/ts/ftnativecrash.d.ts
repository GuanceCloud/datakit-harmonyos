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

  export function initNativeCrashHandler(): boolean;

  export function setCrashCallback(callback: NativeCrashCallback): boolean;

  export function clearCrashCallback(): boolean;

  export function startWatching(): boolean;

  export function stopWatching(): boolean;

  export function addLog(level: string, tag: string, message: string): boolean;

  export function getCollectedLogs(maxLines?: number): string;

  export function clearLogs(): boolean;

  export function setMaxLogSize(maxSize: number): boolean;

  export function getVersion(): string;
}
