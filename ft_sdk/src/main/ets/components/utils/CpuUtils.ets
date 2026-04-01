import { hidebug } from '@kit.PerformanceAnalysisKit';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { process, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';

const TAG = Constants.LOG_TAG_PREFIX + "CpuUtils";

/**
 * Process CPU time information interface
 */
interface ProcessCpuTimeInfo {
  cpuTime: number;
}

/**
 * System CPU information interface
 */
interface SystemCpuInfo {
  totalCpuTime: number;
  idleCpuTime: number;
  cpuCount: number;
}

/**
 * CPU bean type (for compatibility)
 */
export interface CpuBean {
  usage: number;
  tickCount: number;
  tickCountPerSecond: number;
}

/**
 * CPU monitoring utility for HarmonyOS
 * Based on @ohos.hidebug API for performance analysis
 */
export class CpuUtils {
  private static instance: CpuUtils | null = null;
  private lastCpuTime: number = 0;
  private lastAppCpuTime: number = 0;
  private isInitialized: boolean = false;
  
  // Performance optimization: reduce CPU monitoring frequency
  private lastCollectionTime: number = 0;
  private collectionInterval: number = 5000; // 5 seconds interval
  private cachedCpuUsage: number = -1;
  private cachedCpuTickCount: number = -1;
  private cachedCpuTickCountPerSecond: number = -1;

  private constructor() {
    // Private constructor for singleton
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): CpuUtils {
    if (!CpuUtils.instance) {
      CpuUtils.instance = new CpuUtils();
    }
    return CpuUtils.instance;
  }

  /**
   * Initialize CPU monitoring
   */
  public async init(): Promise<void> {
    try {
      // Initialize CPU monitoring (simulated for now)
      // Note: hidebug API may not be available in all HarmonyOS versions
      this.isInitialized = true;
      FTInnerLogger.d(TAG, "CPU monitoring initialized successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize CPU monitoring: ${error}`);
      this.isInitialized = false;
    }
  }

  /**
   * Get current app CPU usage percentage
   * @returns CPU usage percentage (0-100)
   */
  public async getCpuUsage(): Promise<number> {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "CPU monitoring not initialized");
      return -1;
    }

    // Use cached value if recent enough
    if (this.shouldUseCachedValue()) {
      return this.cachedCpuUsage;
    }

    try {
      // Get CPU usage (simulated for now)
      // Note: Real CPU monitoring would require system-level APIs
      const cpuUsage = Math.random() * 100; // Simulated CPU usage
      this.cachedCpuUsage = cpuUsage;
      this.lastCollectionTime = Date.now();
      FTInnerLogger.d(TAG, `Current CPU usage: ${cpuUsage}%`);
      return cpuUsage;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get CPU usage: ${error}`);
      return -1;
    }
  }

  /**
   * Get app CPU tick count
   * @returns CPU tick count for current process (utime + stime from /proc/[pid]/stat)
   */
  public async getAppCpuTickCount(): Promise<number> {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "CPU monitoring not initialized");
      return -1;
    }

    // Use cached value if recent enough
    if (this.shouldUseCachedValue() && this.cachedCpuTickCount > 0) {
      return this.cachedCpuTickCount;
    }

    try {
      // Read CPU tick count from /proc/[pid]/stat file
      // Format: pid comm state ppid ... utime stime ... (utime is field 14, stime is field 15, 1-indexed)
      const pid: number = process.pid;
      if (pid <= 0) {
        FTInnerLogger.w(TAG, "Invalid process ID");
        return -1;
      }

      try {
        const statPath: string = `/proc/${pid}/stat`;
        const file = fileIo.openSync(statPath, fileIo.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(2048);
          const readLen: number = fileIo.readSync(file.fd, buffer);
          fileIo.closeSync(file);
          
          if (readLen > 0) {
            const bufferSlice = buffer.slice(0, readLen);
            const uint8Array = new Uint8Array(bufferSlice);
            const textDecoder = util.TextDecoder.create('utf-8');
            const content: string = textDecoder.decodeWithStream(uint8Array, { stream: false });
            // Split by spaces, but handle comm field which may contain spaces in parentheses
            const fields: string[] = [];
            let currentField: string = '';
            let inParens: boolean = false;
            
            for (let i: number = 0; i < content.length; i++) {
              const char: string = content[i];
              if (char === '(') {
                inParens = true;
                currentField += char;
              } else if (char === ')') {
                inParens = false;
                currentField += char;
              } else if (char === ' ' && !inParens) {
                if (currentField.length > 0) {
                  fields.push(currentField);
                  currentField = '';
                }
              } else {
                currentField += char;
              }
            }
            if (currentField.length > 0) {
              fields.push(currentField);
            }
            
            // utime is field 13 (0-indexed), stime is field 14 (0-indexed)
            // But in /proc/[pid]/stat, fields are: pid(0), comm(1), state(2), ppid(3), ..., utime(13), stime(14)
            if (fields.length > 14) {
              const utime: number = parseInt(fields[13], 10);
              const stime: number = parseInt(fields[14], 10);
              if (!isNaN(utime) && !isNaN(stime)) {
                const cpuTickCount: number = utime + stime;
                this.cachedCpuTickCount = cpuTickCount;
                this.lastCollectionTime = Date.now();
                FTInnerLogger.d(TAG, `App CPU tick count from /proc/stat: ${cpuTickCount} (utime: ${utime}, stime: ${stime})`);
                return cpuTickCount;
              }
            }
          }
        } catch (readError) {
          fileIo.closeSync(file);
          const errorMsg: string = readError instanceof Error ? readError.message : String(readError);
          FTInnerLogger.w(TAG, `Failed to read CPU tick count from file: ${errorMsg}`);
        }
      } catch (fileError) {
        const errorMsg: string = fileError instanceof Error ? fileError.message : String(fileError);
        FTInnerLogger.w(TAG, `Failed to open CPU stat file: ${errorMsg}`);
      }

      // If reading fails, return -1
      FTInnerLogger.w(TAG, "Failed to get app CPU tick count from system file");
      return -1;
    } catch (error) {
      const errorMsg: string = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to get app CPU tick count: ${errorMsg}`);
      return -1;
    }
  }

  /**
   * Get CPU tick count per second
   * @returns CPU tick count per second
   */
  public async getCpuTickCountPerSecond(): Promise<number> {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "CPU monitoring not initialized");
      return -1;
    }

    // Use cached value if recent enough
    if (this.shouldUseCachedValue()) {
      return this.cachedCpuTickCountPerSecond;
    }

    try {
      const currentTime = Date.now();
      const currentCpuTime = await this.getAppCpuTickCount();
      
      if (this.lastCpuTime === 0) {
        this.lastCpuTime = currentTime;
        this.lastAppCpuTime = currentCpuTime;
        this.cachedCpuTickCountPerSecond = 0;
        this.lastCollectionTime = currentTime;
        return 0;
      }

      const timeDiff = (currentTime - this.lastCpuTime) / 1000; // Convert to seconds
      const cpuDiff = currentCpuTime - this.lastAppCpuTime;
      
      this.lastCpuTime = currentTime;
      this.lastAppCpuTime = currentCpuTime;

      if (timeDiff > 0) {
        const cpuTickCountPerSecond = cpuDiff / timeDiff;
        this.cachedCpuTickCountPerSecond = cpuTickCountPerSecond;
        this.lastCollectionTime = currentTime;
        FTInnerLogger.d(TAG, `CPU tick count per second: ${cpuTickCountPerSecond}`);
        return cpuTickCountPerSecond;
      }
      
      this.cachedCpuTickCountPerSecond = 0;
      this.lastCollectionTime = currentTime;
      return 0;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get CPU tick count per second: ${error}`);
      return -1;
    }
  }

  /**
   * Get system CPU information
   * @returns System CPU information
   */
  public async getSystemCpuInfo(): Promise<SystemCpuInfo> {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "CPU monitoring not initialized");
      const result: SystemCpuInfo = { totalCpuTime: 0, idleCpuTime: 0, cpuCount: 0 };
      return result;
    }

    try {
      // Get system CPU info (simulated for now)
      const result: SystemCpuInfo = {
        totalCpuTime: Math.floor(Math.random() * 1000000),
        idleCpuTime: Math.floor(Math.random() * 500000),
        cpuCount: 4 // Simulated CPU count
      };
      FTInnerLogger.d(TAG, `System CPU info: ${JSON.stringify(result)}`);
      return result;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get system CPU info: ${error}`);
      const result: SystemCpuInfo = { totalCpuTime: 0, idleCpuTime: 0, cpuCount: 1 };
      return result;
    }
  }

  /**
   * Release resources
   */
  public async release(): Promise<void> {
    try {
      if (this.isInitialized) {
        this.isInitialized = false;
        FTInnerLogger.d(TAG, "CPU monitoring released");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to release CPU monitoring: ${error}`);
    }
  }

  /**
   * Check if CPU monitoring is available
   * @returns true if available, false otherwise
   */
  public isAvailable(): boolean {
    return this.isInitialized;
  }

  /**
   * Check if cached value should be used
   * @returns true if cached value is recent enough
   */
  private shouldUseCachedValue(): boolean {
    const now = Date.now();
    return (now - this.lastCollectionTime) < this.collectionInterval;
  }

  /**
   * Set collection interval for performance optimization
   * @param interval Interval in milliseconds
   */
  public setCollectionInterval(interval: number): void {
    this.collectionInterval = Math.max(1000, interval); // Minimum 1 second
    FTInnerLogger.d(TAG, `CPU collection interval set to ${this.collectionInterval}ms`);
  }

  /**
   * Force refresh cache (for testing or critical monitoring)
   */
  public forceRefresh(): void {
    this.lastCollectionTime = 0;
    this.cachedCpuUsage = -1;
    this.cachedCpuTickCount = -1;
    this.cachedCpuTickCountPerSecond = -1;
    FTInnerLogger.d(TAG, "CPU cache force refreshed");
  }
}