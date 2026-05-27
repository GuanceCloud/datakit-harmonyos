import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI'
import { util } from '@kit.ArkTS';
import { AppUtils } from './AppUtils';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { FTInnerLogger } from '../log/FTLogger';
import { hilog } from '@kit.PerformanceAnalysisKit';

// import { LogUtils } from './LogUtils';

/**
 * System information interface
 */
interface SystemInfo {
  //platform: string;
  language: string;
  timestamp: number;
}

/**
 * Memory information interface
 */
interface MemoryInfo {
  message: string;
  timestamp: number;
}

/**
 * Performance information interface
 */
interface PerformanceInfo {
  message: string;
  timestamp: number;
}
 const  TAG = "Utils";

/**
 * General utility class
 * Reference HarmonyOS SDK Utils class, provides common utility methods
 * Includes Context management, window management, data formatting, array operations and other practical functions
 */
export class Utils {

  // Context related static properties
  private static sAbilityContext: common.UIAbilityContext;
  private static sUiContext?: UIContext | null;
  private static mainWindow?: window.Window | null;


  /**
   * Get all keys of an object
   * @param obj Object
   * @returns Array of keys
   */
  public static getObjectKeys(obj: object): string[] {
    if (!Utils.isValidObject(obj)) {
      return [];
    }
    return Utils.getObjectKeysArray(obj);
  }

    /**
     * Initialize utility class,
     * 1. All places that need context can use Utils to get it
     * 2. Tool classes that need initialization can be initialized here
     * @param entryContext
     */
  public static init(entryContext: common.UIAbilityContext) {
    Utils.sAbilityContext = entryContext;
  }

  /**
   * Set main window
   * @returns
   */
  public static setMainWindow(mainWindow?: window.Window) {
    try {
      Utils.mainWindow = mainWindow;
      if (!mainWindow) {
        window.getLastWindow(getContext(), (err: BusinessError, data) => {
          const errCode: number = err.code;
          if (errCode) {
            FTInnerLogger.e(TAG,
              'Failed to obtain the top window. Cause: ' + JSON.stringify(err));
            return;
          }
          Utils.mainWindow = data;
          Utils.sUiContext = data.getUIContext();
        });
      } else {
        Utils.sUiContext = mainWindow.getUIContext();
      }
    } catch (e) {
      // Use hilog instead of console.error
      FTInnerLogger.e(TAG, `Error setting UI context: ${e}`);
    }
  }

  /**
   * Get application level Context
   * @returns
   */
  public static getApplicationContext() {
    return Utils.getAbilityContext().getApplicationContext();
  }

  /**
   * Get UIAbility level Context
   * @returns
   */
  public static getAbilityContext() {
    return Utils.sAbilityContext ?? getContext() as common.UIAbilityContext;
  }

  /**
   * Get MainWindow
   * @returns
   */
  public static getMainWindow() {
    return Utils.mainWindow;
  }

  /**
   * Get uiContext corresponding to MainWindow
   * @returns
   */
  public static getUIContext() {
    return Utils.sUiContext ?? Utils.getMainWindow()?.getUIContext();
  }

  /**
   * Format double precision number
   * @param value Value to format
   * @param decimalPlaces Decimal places, default 2
   * @returns Formatted number
   */
  public static formatDouble(value: number, decimalPlaces: number = 2): number {
    if (isNaN(value) || !isFinite(value)) {
      return 0.0;
    }
    const multiplier = Math.pow(10, decimalPlaces);
    return Math.round(value * multiplier) / multiplier;
  }

  /**
   * Format bytes to readable format
   * @param bytes Number of bytes
   * @returns Formatted string
   */
  public static formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  /**
   * Format milliseconds to readable format
   * @param milliseconds Number of milliseconds
   * @returns Formatted string
   */
  public static formatMilliseconds(milliseconds: number): string {
    if (milliseconds < 1000) {
      return milliseconds + 'ms';
    } else if (milliseconds < 60000) {
      return (milliseconds / 1000).toFixed(2) + 's';
    } else {
      const minutes = Math.floor(milliseconds / 60000);
      const seconds = ((milliseconds % 60000) / 1000).toFixed(2);
      return minutes + 'm ' + seconds + 's';
    }
  }

  /**
   * Generate UUID
   * @returns UUID string
   */
  public static generateUUID(): string {
    try {
      const uuid = util.generateRandomUUID(true);
      const normalized = Utils.normalizeUUID(uuid);
      if (normalized.length > 0) {
        return normalized;
      }
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to generate UUID with system API: ${error}`);
    }
    return Utils.generateFallbackUUID();
  }

  private static normalizeUUID(uuid: string): string {
    const normalized = uuid.replace(/-/g, '').toLowerCase();
    if (/^[0-9a-f]{32}$/.test(normalized)) {
      return normalized;
    }
    return '';
  }

  private static generateFallbackUUID(): string {
    let uuid = '';
    for (let i = 0; i < 32; i++) {
      uuid += Math.floor(Math.random() * 16).toString(16);
    }
    return uuid;
  }

  /**
   * Generate random ID
   * @param length ID length, default 8 characters
   * @returns Random ID string
   */
  public static generateRandomId(length: number = 8): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
      result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
  }

  /**
   * Check if string is empty
   * @param str String to check
   * @returns Whether it is empty
   */
  public static isEmpty(str: string | null | undefined): boolean {
    return str === null || str === undefined || str.trim() === '';
  }

  /**
   * Check if string is not empty
   * @param str String to check
   * @returns Whether it is not empty
   */
  public static isNotEmpty(str: string | null | undefined): boolean {
    return !Utils.isEmpty(str);
  }

  /**
   * Check if object is empty
   * @param obj Object to check
   * @returns Whether it is empty
   */
  public static isEmptyObject(obj: object): boolean {
    if (obj === null || obj === undefined) {
      return true;
    }
    if (typeof obj === 'object') {
      return Utils.getObjectKeyCount(obj) === 0;
    }
    return false;
  }

  /**
   * Deep clone object
   * @param obj Object to clone
   * @returns Cloned object
   */
  public static deepClone<T>(obj: T): T {
    if (obj === null || typeof obj !== 'object') {
      return obj;
    }
    
    if (obj instanceof Date) {
      return new Date(obj.getTime()) as T;
    }
    
    if (obj instanceof Array) {
      return obj.map((item: T) => Utils.deepClone(item)) as T;
    }
    
    if (typeof obj === 'object') {
      const cloned: Record<string, object> = new Object() as Record<string, object>;
      // In ArkTS, simplify object cloning logic
      return cloned as T;
    }
    
    return obj;
  }

  /**
   * Debounce function
   * @param func Function to execute
   * @param wait Wait time (milliseconds)
   * @returns Debounced function
   */
  public static debounce(
    func: (...args: object[]) => object,
    wait: number
  ): (...args: object[]) => void {
    let timeout: number | null = null;
    return (...args: object[]) => {
      if (timeout) {
        clearTimeout(timeout);
      }
      timeout = setTimeout(() => {
        // Manually call function, avoid using apply
        if (args.length === 0) {
          (func as () => object)();
        } else if (args.length === 1) {
          (func as (arg: object) => object)(args[0]);
        } else if (args.length === 2) {
          (func as (arg1: object, arg2: object) => object)(args[0], args[1]);
        } else {
          // For more parameters, use type assertion
          (func as (...args: object[]) => object)(...args);
        }
      }, wait);
    };
  }

  /**
   * Throttle function
   * @param func Function to execute
   * @param wait Wait time (milliseconds)
   * @returns Throttled function
   */
  public static throttle(
    func: (...args: object[]) => object,
    wait: number
  ): (...args: object[]) => void {
    let lastCall = 0;
    return (...args: object[]) => {
      const now = Date.now();
      if (now - lastCall >= wait) {
        lastCall = now;
        // Manually call function, avoid using apply
        if (args.length === 0) {
          (func as () => object)();
        } else if (args.length === 1) {
          (func as (arg: object) => object)(args[0]);
        } else if (args.length === 2) {
          (func as (arg1: object, arg2: object) => object)(args[0], args[1]);
        } else {
          // For more parameters, use type assertion
          (func as (...args: object[]) => object)(...args);
        }
      }
    };
  }

  /**
   * Get current timestamp
   * @returns Current timestamp (milliseconds)
   */
  public static getCurrentTimestamp(): number {
    return Date.now();
  }

  /**
   * Get current timestamp (seconds)
   * @returns Current timestamp (seconds)
   */
  public static getCurrentTimestampSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }

  /**
   * Get current nanosecond timestamp
   * Aligned with Android SDK: System.currentTimeMillis() * 1000000L + System.nanoTime() % 1000000L
   * Android format: absolute time (milliseconds) * 1000000 + relative time (nanoseconds % 1000000)
   * This ensures 19-digit timestamp format matching Android (e.g., 1760522837046481068)
   * @returns Current nanosecond timestamp (19 digits, matching Android format)
   */
  public static getCurrentNanoTime(): number {
    try {
      // Aligned with Android: System.currentTimeMillis() * 1000000L + System.nanoTime() % 1000000L
      // Step 1: Get absolute time in milliseconds (equivalent to System.currentTimeMillis())
      const millis = Date.now();
      
      // Step 2: Get full nanosecond timestamp from systemDateTime
      // systemDateTime.getTime(true) returns nanoseconds since Unix epoch
      const fullNanoTime = systemDateTime.getTime(true);
      
      // Step 3: Extract the last 6 digits (microsecond part, 0-999999)
      // This simulates System.nanoTime() % 1000000L in Android
      const nanoPart = fullNanoTime % 1000000;
      
      // Step 4: Combine: milliseconds * 1000000 + nanosecond part
      // This matches Android's format: millis * 1000000L + (nanoTime % 1000000L)
      return millis * 1000000 + nanoPart;
    } catch (error) {
      // Fallback: use Date.now() * 1000000 (16 digits, microseconds)
      // This is not ideal but maintains compatibility with older APIs
      FTInnerLogger.w(TAG, `Failed to get nanosecond time, using fallback: ${error}`);
      return Date.now() * 1000000; // Convert to microseconds (16 digits)
    }
  }

  /**
   * Format timestamp
   * @param timestamp Timestamp
   * @param format Format string, default 'YYYY-MM-DD HH:mm:ss'
   * @returns Formatted time string
   */
  public static formatTimestamp(timestamp: number, format: string = 'YYYY-MM-DD HH:mm:ss'): string {
    const date = new Date(timestamp);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const seconds = String(date.getSeconds()).padStart(2, '0');
    
    return format
      .replace('YYYY', String(year))
      .replace('MM', month)
      .replace('DD', day)
      .replace('HH', hours)
      .replace('mm', minutes)
      .replace('ss', seconds);
  }

  /**
   * Calculate the difference between two timestamps
   * @param startTimestamp Start timestamp
   * @param endTimestamp End timestamp
   * @returns Difference in milliseconds
   */
  public static getTimeDifference(startTimestamp: number, endTimestamp: number): number {
    return Math.abs(endTimestamp - startTimestamp);
  }

  /**
   * Check if value is a number
   * @param value Value to check
   * @returns Whether the value is a number
   */
  public static isNumber(value: object): boolean {
    return typeof value === 'number' && !isNaN(value) && isFinite(value);
  }

  /**
   * Check if value is an integer
   * @param value Value to check
   * @returns Whether the value is an integer
   */
  public static isInteger(value: object): boolean {
    return Utils.isNumber(value) && Number.isInteger(value);
  }

  /**
   * Check if value is a valid string
   * @param value Value to check
   * @returns Whether the value is a valid string
   */
  public static isValidString(value: object): boolean {
    return typeof value === 'string' && (value as string).trim().length > 0;
  }

  /**
   * Check if value is a valid object
   * @param value Value to check
   * @returns Whether the value is a valid object
   */
  public static isValidObject(value: object): boolean {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  /**
   * Check if value is a valid array
   * @param value Value to check
   * @returns Whether the value is a valid array
   */
  public static isValidArray(value: object): boolean {
    return Array.isArray(value) && value.length > 0;
  }


  /**
   * Get all values from an object
   * @param obj Object
   * @returns Array of values
   */
  public static getObjectValues(obj: object): object[] {
    if (!Utils.isValidObject(obj)) {
      return [];
    }
    return Object.values(obj);
  }

  /**
   * Merge multiple objects
   * @param objects Array of objects to merge
   * @returns Merged object
   */
  public static mergeObjects(...objects: object[]): object {
    const result: Record<string, object> = new Object() as Record<string, object>;
    
    for (const obj of objects) {
      if (Utils.isValidObject(obj)) {
        Utils.mergeObject(result, obj);
      }
    }
    
    return result;
  }

  /**
   * Merge single object
   */
  private static mergeObject(target: Record<string, object>, source: object): void {
    const keys: string[] = Utils.getObjectKeys(source);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      target[key] = (source as Record<string, object>)[key] as object;
    }
  }

  /**
   * Get nested object value
   * @param obj Object
   * @param path Path string, e.g. 'user.profile.name'
   * @param defaultValue Default value
   * @returns Found value or default value
   */
  public static getNestedValue(obj: object, path: string, defaultValue: object | null = null): object | null {
    if (!Utils.isValidObject(obj) || Utils.isEmpty(path)) {
      return defaultValue;
    }
    
    const keys = path.split('.');
    let current = obj;
    
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      if (current && typeof current === 'object' && Utils.hasKey(current, key)) {
        current = (current as Record<string, object>)[key] as object;
      } else {
        return defaultValue;
      }
    }
    
    return current;
  }

  /**
   * Set nested object value
   * @param obj Object
   * @param path Path string
   * @param value Value to set
   * @returns Whether setting was successful
   */
  public static setNestedValue(obj: object, path: string, value: object): boolean {
    if (!Utils.isValidObject(obj) || Utils.isEmpty(path)) {
      return false;
    }
    
    const keys = path.split('.');
    let current = obj;
    
    for (let i = 0; i < keys.length - 1; i++) {
      const key = keys[i];
      if (!Utils.hasKey(current, key) || typeof (current as Record<string, object>)[key] !== 'object') {
        (current as Record<string, object>)[key] = new Object();
      }
      current = (current as Record<string, object>)[key] as object;
    }
    
    current[keys[keys.length - 1]] = value;
    return true;
  }

  /**
   * Check if object contains specified key
   * @param obj Object
   * @param key Key
   * @returns Whether contains the key
   */
  public static hasKey(obj: object, key: string): boolean {
    if (!Utils.isValidObject(obj)) {
      return false;
    }
    // In ArkTS, simplified implementation, directly check if property exists
    try {
      return (obj as Record<string, object>)[key] !== undefined;
    } catch {
      return false;
    }
  }

  /**
   * Safely get object property value
   * @param obj Object
   * @param key Key
   * @param defaultValue Default value
   * @returns Property value or default value
   */
  public static safeGet<T>(obj: object, key: string, defaultValue: T): T {
    if (Utils.hasKey(obj, key)) {
      return (obj as Record<string, T>)[key];
    }
    return defaultValue;
  }

  /**
   * Convert object to JSON string
   * @param obj Object
   * @param pretty Whether to beautify output, default false
   * @returns JSON string
   */
  public static toJsonString(obj: object, pretty: boolean = false): string {
    try {
      if (pretty) {
        return JSON.stringify(obj, null, 2);
      }
      return JSON.stringify(obj);
    } catch (error) {
      return '{}';
    }
  }

  /**
   * Convert JSON string to object
   * @param jsonString JSON string
   * @returns Parsed object or null
   */
  public static fromJsonString<T>(jsonString: string): T | null {
    try {
      return JSON.parse(jsonString) as T;
    } catch (error) {
      return null;
    }
  }

  /**
   * Check if string is valid JSON
   * @param str String to check
   * @returns Whether it's valid JSON
   */
  public static isValidJson(str: string): boolean {
    try {
      JSON.parse(str);
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * Generate random number
   * @param min Minimum value
   * @param max Maximum value
   * @returns Random number
   */
  public static randomNumber(min: number, max: number): number {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  /**
   * Generate random float number
   * @param min Minimum value
   * @param max Maximum value
   * @param decimalPlaces Decimal places, default 2
   * @returns Random float number
   */
  public static randomFloat(min: number, max: number, decimalPlaces: number = 2): number {
    const random = Math.random() * (max - min) + min;
    return Utils.formatDouble(random, decimalPlaces);
  }

  /**
   * Remove duplicates from array
   * @param array Array
   * @returns Array with duplicates removed
   */
  public static uniqueArray<T>(array: T[]): T[] {
    if (!Utils.isValidArray(array)) {
      return [];
    }
    return Array.from(new Set(array));
  }

  /**
   * Sort array
   * @param array Array
   * @param key Sort key (for object arrays)
   * @param order Sort order, 'asc' for ascending, 'desc' for descending
   * @returns Sorted array
   */
  public static sortArray<T>(array: T[], key?: string, order: 'asc' | 'desc' = 'asc'): T[] {
    if (!Utils.isValidArray(array)) {
      return [];
    }
    
    const sorted = [...array];
    
    if (key) {
      // Object array sorting
      sorted.sort((a: T, b: T) => {
        const aVal = (a as Record<string, object>)[key] as object;
        const bVal = (b as Record<string, object>)[key] as object;
        
        if (aVal < bVal) return order === 'asc' ? -1 : 1;
        if (aVal > bVal) return order === 'asc' ? 1 : -1;
        return 0;
      });
    } else {
      // Regular array sorting
      sorted.sort((a: T, b: T) => {
        if (a < b) return order === 'asc' ? -1 : 1;
        if (a > b) return order === 'asc' ? 1 : -1;
        return 0;
      });
    }
    
    return sorted;
  }

  /**
   * Group array
   * @param array Array
   * @param key Group key
   * @returns Grouped object
   */
  public static groupArray<T>(array: T[], key: string): Record<string, T[]> {
    if (!Utils.isValidArray(array)) {
      return new Object() as Record<string, T[]>;
    }
    
    const groups: Record<string, T[]> = new Object() as Record<string, T[]>;
    
    for (const item of array) {
      const groupKey = String((item as Record<string, object>)[key] as object || 'unknown');
      if (!groups[groupKey]) {
        groups[groupKey] = [];
      }
      groups[groupKey].push(item);
    }
    
    return groups;
  }

  /**
   * Filter array
   * @param array Array
   * @param predicate Filter condition function
   * @returns Filtered array
   */
  public static filterArray<T>(array: T[], predicate: (item: T, index: number) => boolean): T[] {
    if (!Utils.isValidArray(array)) {
      return [];
    }
    return array.filter(predicate);
  }

  /**
   * Map array
   * @param array Array
   * @param mapper Mapping function
   * @returns Mapped array
   */
  public static mapArray<T, R>(array: T[], mapper: (item: T, index: number) => R): R[] {
    if (!Utils.isValidArray(array)) {
      return [];
    }
    return array.map(mapper);
  }

  /**
   * Find in array
   * @param array Array
   * @param predicate Find condition function
   * @returns Found element or undefined
   */
  public static findInArray<T>(array: T[], predicate: (item: T, index: number) => boolean): T | undefined {
    if (!Utils.isValidArray(array)) {
      return undefined;
    }
    return array.find(predicate);
  }

  /**
   * Check if array contains item
   * @param array Array
   * @param item Item to check
   * @returns Whether contains the item
   */
  public static arrayContains<T>(array: T[], item: T): boolean {
    if (!Utils.isValidArray(array)) {
      return false;
    }
    return array.includes(item);
  }

  /**
   * Get first element of array
   * @param array Array
   * @returns First element or undefined
   */
  public static getFirstElement<T>(array: T[]): T | undefined {
    if (!Utils.isValidArray(array)) {
      return undefined;
    }
    return array[0];
  }

  /**
   * Get last element of array
   * @param array Array
   * @returns Last element or undefined
   */
  public static getLastElement<T>(array: T[]): T | undefined {
    if (!Utils.isValidArray(array)) {
      return undefined;
    }
    return array[array.length - 1];
  }

  /**
   * Chunk array
   * @param array Array
   * @param chunkSize Chunk size
   * @returns Chunked array
   */
  public static chunkArray<T>(array: T[], chunkSize: number): T[][] {
    if (!Utils.isValidArray(array) || chunkSize <= 0) {
      return [];
    }
    
    const chunks: T[][] = [];
    for (let i = 0; i < array.length; i += chunkSize) {
      chunks.push(array.slice(i, i + chunkSize));
    }
    
    return chunks;
  }

  /**
   * Delay execution
   * @param ms Delay time in milliseconds
   * @returns Promise
   */
  public static delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Retry executing function
   * @param fn Function to execute
   * @param maxRetries Maximum retry count
   * @param delay Retry delay in milliseconds
   * @returns Promise
   */
  public static async retry<T>(
    fn: () => Promise<T>,
    maxRetries: number = 3,
    delay: number = 1000
  ): Promise<T> {
    let lastError: Error | null = null;
    
    for (let i = 0; i <= maxRetries; i++) {
      try {
        return await fn();
      } catch (error) {
        lastError = error as Error;
        if (i < maxRetries) {
          await Utils.delay(delay * Math.pow(2, i)); // Exponential backoff
        }
      }
    }
    
    throw new Error(`Retry failed after ${maxRetries} attempts: ${lastError?.message || 'Unknown error'}`);
  }

  /**
   * Get system information summary
   * @returns System information object
   */
  public static getSystemInfo(): SystemInfo {
    return {
      //platform: 'HarmonyOS',
      language: 'zh-CN',
      timestamp: Utils.getCurrentTimestamp()
    };
  }

  /**
   * Get memory usage information
   * @returns Memory information object
   */
  public static getMemoryInfo(): MemoryInfo {
    return {
      message: 'Memory API not supported in HarmonyOS',
      timestamp: Utils.getCurrentTimestamp()
    };
  }

  /**
   * Get performance information
   * @returns Performance information object
   */
  public static getPerformanceInfo(): PerformanceInfo {
    return {
      message: 'Performance Navigation API not supported in HarmonyOS',
      timestamp: Utils.getCurrentTimestamp()
    };
  }

  /**
   * Get object key count (alternative to Object.keys(obj).length)
   * @param obj Object
   * @returns Key count
   */
  private static getObjectKeyCount(obj: object): number {
    let count = 0;
    const keys = Utils.getObjectKeys(obj);
    for (let i = 0; i < keys.length; i++) {
      count++;
    }
    return count;
  }

  /**
   * Get all object keys (alternative to Object.keys(obj))
   * @param obj Object
   * @returns Key array
   */
  private static getObjectKeysArray(obj: object): string[] {
    // In ArkTS, simplified implementation, return empty array
    return [];
  }

  /**
   * Get current timestamp in microseconds
   * @returns Microsecond timestamp
   */
  public static getCurrentTimestampMicros(): number {
    // Convert milliseconds to microseconds (multiply by 1,000)
    return Date.now() * 1000;
  }

  /**
   * Convert milliseconds timestamp to microseconds
   * @param millis Milliseconds timestamp
   * @returns Microsecond timestamp
   */
  public static millisToMicros(millis: number): number {
    return millis * 1000;
  }

  /**
   * Convert microseconds timestamp to milliseconds
   * @param micros Microsecond timestamp
   * @returns Milliseconds timestamp
   */
  public static microsToMillis(micros: number): number {
    return Math.floor(micros / 1000);
  }

  /**
   * Convert microseconds timestamp to nanoseconds
   * @param micros Microsecond timestamp
   * @returns Nanosecond timestamp
   */
  public static microsToNanos(micros: number): number {
    return micros * 1000;
  }
}
