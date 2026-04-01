import { FTInnerLogger } from '../log/FTLogger';
import { MemoryUtils } from './MemoryUtils';

const TAG = "MemoryMonitor";

/**
 * Memory statistics interface
 */
interface MemoryStats {
  currentMemory: number;
  startMemory: number;
  totalGrowth: number;
  avgGrowthRate: number;
  sampleCount: number;
}

/**
 * Memory Monitor - Tool for tracking memory usage and detecting memory leaks
 * Internal utility class, exported for internal use only (not in Index.ets)
 * External SDK users should not use this class directly
 * 
 * Usage:
 *   MemoryMonitor.startMonitoring(1000); // Monitor every 1 second
 *   // ... run your code ...
 *   MemoryMonitor.stopMonitoring();
 */
export class MemoryMonitor {
  private static intervalId: number | null = null;
  private static startTime: number = 0;
  private static lastMemory: number = 0;
  private static samples: number[] = [];
  private static maxSamples: number = 100; // Keep last 100 samples
  
  /**
   * Start memory monitoring
   * @param intervalMs Monitoring interval in milliseconds (default: 1000ms)
   */
  public static startMonitoring(intervalMs: number = 1000): void {
    if (MemoryMonitor.intervalId !== null) {
      FTInnerLogger.w(TAG, "Memory monitoring already started");
      return;
    }
    
    MemoryMonitor.startTime = Date.now();
    MemoryMonitor.lastMemory = MemoryMonitor.getCurrentMemory();
    MemoryMonitor.samples = [];
    
    FTInnerLogger.i(TAG, `Memory monitoring started (interval: ${intervalMs}ms)`);
    
    MemoryMonitor.intervalId = setInterval(() => {
      // Use async method to get current memory
      MemoryMonitor.getCurrentMemoryAsync().then((currentMemory: number) => {
        const elapsed = (Date.now() - MemoryMonitor.startTime) / 1000; // seconds
        const growth = currentMemory - MemoryMonitor.lastMemory;
        const growthRate = growth / elapsed; // KB per second
        
        // Store sample
        MemoryMonitor.samples.push(currentMemory);
        if (MemoryMonitor.samples.length > MemoryMonitor.maxSamples) {
          MemoryMonitor.samples.shift(); // Remove oldest sample
        }
        
        // Calculate average growth rate from samples
        let avgGrowthRate = 0;
        if (MemoryMonitor.samples.length >= 2) {
          const totalGrowth = MemoryMonitor.samples[MemoryMonitor.samples.length - 1] - MemoryMonitor.samples[0];
          const totalTime = (MemoryMonitor.samples.length - 1) * (intervalMs / 1000);
          avgGrowthRate = totalTime > 0 ? totalGrowth / totalTime : 0;
        }
        
        FTInnerLogger.i(TAG, 
          `Memory: ${currentMemory.toFixed(2)}KB | ` +
          `Growth: ${growth.toFixed(2)}KB | ` +
          `Rate: ${growthRate.toFixed(2)}KB/s | ` +
          `Avg Rate: ${avgGrowthRate.toFixed(2)}KB/s | ` +
          `Samples: ${MemoryMonitor.samples.length}`
        );
        
        // Warn if growth rate is too high
        if (avgGrowthRate > 1.0) {
          FTInnerLogger.w(TAG, `⚠️ High memory growth rate detected: ${avgGrowthRate.toFixed(2)}KB/s`);
        }
        
        MemoryMonitor.lastMemory = currentMemory;
      }).catch((error: Error) => {
        FTInnerLogger.e(TAG, `Failed to get memory in monitoring interval: ${error}`);
      });
    }, intervalMs);
  }
  
  /**
   * Stop memory monitoring
   */
  public static stopMonitoring(): void {
    if (MemoryMonitor.intervalId === null) {
      FTInnerLogger.w(TAG, "Memory monitoring not started");
      return;
    }
    
    if (MemoryMonitor.intervalId !== null) {
      clearInterval(MemoryMonitor.intervalId);
      MemoryMonitor.intervalId = null;
    }
    
    const totalTime = (Date.now() - MemoryMonitor.startTime) / 1000;
    const finalMemory = MemoryMonitor.samples.length > 0 ? MemoryMonitor.samples[MemoryMonitor.samples.length - 1] : 0;
    const startMemory = MemoryMonitor.samples.length > 0 ? MemoryMonitor.samples[0] : 0;
    const totalGrowth = finalMemory - startMemory;
    const avgGrowthRate = totalTime > 0 ? totalGrowth / totalTime : 0;
    
    FTInnerLogger.i(TAG, 
      `Memory monitoring stopped | ` +
      `Total time: ${totalTime.toFixed(2)}s | ` +
      `Total growth: ${totalGrowth.toFixed(2)}KB | ` +
      `Average rate: ${avgGrowthRate.toFixed(2)}KB/s`
    );
    
    MemoryMonitor.samples = [];
  }
  
  /**
   * Get current memory usage in KB
   * Uses MemoryUtils to get actual memory usage
   * Note: This is async, but we use cached value for synchronous access
   * @returns Current memory usage in KB
   */
  private static getCurrentMemory(): number {
    try {
      // Use MemoryUtils singleton to get current memory usage
      const memoryUtils = MemoryUtils.getInstance();
      // Try to get cached value synchronously (MemoryUtils caches for 3 seconds)
      // For real-time monitoring, we'll use async method in the interval callback
      // For now, return 0 and update in async callback
      return 0; // Will be updated in async callback
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get current memory: ${error}`);
      return 0;
    }
  }
  
  /**
   * Get current memory usage asynchronously
   * @returns Promise with memory usage in KB
   */
  private static async getCurrentMemoryAsync(): Promise<number> {
    try {
      const memoryUtils = MemoryUtils.getInstance();
      // Initialize if not already initialized
      if (!memoryUtils.isAvailable()) {
        await memoryUtils.init();
      }
      const memoryBytes = await memoryUtils.getAppMemoryUsage();
      if (memoryBytes > 0) {
        // Convert bytes to KB
        const memoryKB = memoryBytes / 1024;
        return memoryKB;
      }
      return 0;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get current memory: ${error}`);
      return 0;
    }
  }
  
  /**
   * Get memory statistics
   * @returns Memory statistics object
   */
  public static getStats(): MemoryStats {
    const currentMemory = MemoryMonitor.samples.length > 0 ? MemoryMonitor.samples[MemoryMonitor.samples.length - 1] : 0;
    const startMemory = MemoryMonitor.samples.length > 0 ? MemoryMonitor.samples[0] : currentMemory;
    const totalGrowth = currentMemory - startMemory;
    const totalTime = (Date.now() - MemoryMonitor.startTime) / 1000;
    const avgGrowthRate = totalTime > 0 ? totalGrowth / totalTime : 0;
    
    const stats: MemoryStats = {
      currentMemory: currentMemory,
      startMemory: startMemory,
      totalGrowth: totalGrowth,
      avgGrowthRate: avgGrowthRate,
      sampleCount: MemoryMonitor.samples.length
    };
    return stats;
  }
  
  /**
   * Log current memory statistics
   */
  public static logStats(): void {
    const stats = MemoryMonitor.getStats();
    FTInnerLogger.i(TAG, 
      `Memory Stats: ` +
      `Current=${stats.currentMemory.toFixed(2)}KB, ` +
      `Start=${stats.startMemory.toFixed(2)}KB, ` +
      `Growth=${stats.totalGrowth.toFixed(2)}KB, ` +
      `Rate=${stats.avgGrowthRate.toFixed(2)}KB/s, ` +
      `Samples=${stats.sampleCount}`
    );
  }
  
  /**
   * Get current memory asynchronously and log stats
   */
  public static async logStatsAsync(): Promise<void> {
    try {
      const currentMemory = await MemoryMonitor.getCurrentMemoryAsync();
      const stats = MemoryMonitor.getStats();
      FTInnerLogger.i(TAG, 
        `Memory Stats (Async): ` +
        `Current=${currentMemory.toFixed(2)}KB, ` +
        `Start=${stats.startMemory.toFixed(2)}KB, ` +
        `Growth=${(currentMemory - stats.startMemory).toFixed(2)}KB, ` +
        `Rate=${stats.avgGrowthRate.toFixed(2)}KB/s, ` +
        `Samples=${stats.sampleCount}`
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get async memory stats: ${error}`);
    }
  }
}

