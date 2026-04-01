import { FTRUMConfig } from '../Configs';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';

const TAG = "FTUIBlockManager";

/**
 * UI Block Manager - Monitor UI blocking on main thread
 * 
 * HarmonyOS implementation note:
 * Uses two detection mechanisms:
 * 1. System-level detection: Subscribe to MAIN_THREAD_JANK events via hiAppEvent
 *    - Reference: https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-stability-app-freeze-ark-runtime
 *    - System triggers: >150ms generates sample stack, >450ms generates Trace file
 *    - This can detect blocking even when main thread is completely blocked
 *    - Uses hiAppEvent.addWatcher() to subscribe to MAIN_THREAD_JANK events
 * 2. Timer-based detection: Schedule a lightweight task on main thread periodically (every 100ms)
 *    - Record task start and end time
 *    - If task execution time exceeds threshold, it indicates main thread blocking
 *    - Note: This may not detect complete blocking as setInterval callback cannot execute
 * 
 * Aligned with Android: All UI blocks exceeding the threshold (default 1 second) are
 * reported as long_task. ANR detection is handled separately by ANRDetector.
 * 
 * Note: MAIN_THREAD_JANK is different from APP_FREEZE (ANR):
 * - MAIN_THREAD_JANK: Main thread jank/card (UI Block) - reported as long_task
 * - APP_FREEZE: Application freeze (ANR) - reported as anr_crash or anr_error
 */
export class FTUIBlockManager {
  /**
   * Default block duration: 1 second
   */
  public static readonly DEFAULT_TIME_BLOCK_MS = 1000;
  
  /**
   * Minimum block duration: 100ms (in nanoseconds)
   */
  private static readonly MINI_TIME_BLOCK_NS = 100000000;
  
  /**
   * Detection interval: 100ms (check every 100ms)
   */
  private static readonly DETECT_INTERVAL_MS = 100;
  
  private static instance: FTUIBlockManager | null = null;
  
  /**
   * Block duration in nanoseconds
   */
  private blockDurationNS: number = FTUIBlockManager.DEFAULT_TIME_BLOCK_MS * 1000000;
  
  /**
   * Detection timer
   */
  private detectTimer: number | null = null;
  
  /**
   * Last task execution start time (nanoseconds)
   */
  private lastTaskStartTime: number = 0;
  
  /**
   * Last scheduled task time (nanoseconds)
   */
  private lastScheduledTime: number = 0;
  
  /**
   * Blocking start time (nanoseconds) - when continuous blocking started
   */
  private blockingStartTime: number = 0;
  
  /**
   * Last report time (nanoseconds) - when we last reported a long task
   */
  private lastReportTime: number = 0;
  
  /**
   * Is currently in blocking state
   */
  private isBlocking: boolean = false;
  
  /**
   * Is detection running
   */
  private isRunning: boolean = false;
  
  /**
   * Current method name (for logging)
   */
  private currentMethod: string = "UIBlock";
  
  /**
   * hiAppEvent watcher name for MAIN_THREAD_JANK events
   */
  private appEventWatcherName: string = 'ft_sdk_main_thread_jank';
  
  private constructor() {
    // Private constructor for singleton
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): FTUIBlockManager {
    if (!FTUIBlockManager.instance) {
      FTUIBlockManager.instance = new FTUIBlockManager();
    }
    return FTUIBlockManager.instance;
  }
  
  /**
   * Start UI block detection
   * @param config RUM config
   */
  public start(config: FTRUMConfig): void {
    // Check if config exists and UI block tracking is enabled
    if (!config || !config.isEnableTrackAppUIBlock()) {
      FTInnerLogger.d(TAG, "UI block detection is disabled");
      return;
    }
    
    if (this.isRunning) {
      FTInnerLogger.w(TAG, "UI block detection is already running");
      return;
    }
    
    // Get block duration from config (default: 1000ms)
    const blockDurationMs = config.getBlockDurationMS() || FTUIBlockManager.DEFAULT_TIME_BLOCK_MS;
    this.blockDurationNS = Math.max(blockDurationMs * 1000000, FTUIBlockManager.MINI_TIME_BLOCK_NS);
    
    this.isRunning = true;
    this.lastScheduledTime = Utils.getCurrentNanoTime();
    this.lastTaskStartTime = Utils.getCurrentNanoTime();
    this.blockingStartTime = 0;
    this.lastReportTime = 0;
    this.isBlocking = false;
    
    // Start detection timer
    this.startDetection();
    
    // Subscribe to MAIN_THREAD_JANK events from system
    this.subscribeToMainThreadJankEvents();
    
    FTInnerLogger.i(TAG, `[FT-UI-BLOCK] UI block detection started with threshold: ${blockDurationMs}ms`);
  }
  
  /**
   * Stop UI block detection
   */
  public release(): void {
    if (!this.isRunning) {
      return;
    }
    
    this.isRunning = false;
    this.isBlocking = false;
    this.blockingStartTime = 0;
    this.lastReportTime = 0;
    
    // Clear detection timer
    if (this.detectTimer !== null) {
      clearInterval(this.detectTimer);
      this.detectTimer = null;
    }
    
    // Remove hiAppEvent watcher
    this.unsubscribeFromMainThreadJankEvents();
    
    FTInnerLogger.i(TAG, "UI block detection stopped");
  }
  
  /**
   * Subscribe to MAIN_THREAD_JANK events from system
   * System triggers: >150ms generates sample stack, >450ms generates Trace file
   */
  private subscribeToMainThreadJankEvents(): void {
    try {
      hiAppEvent.addWatcher({
        name: this.appEventWatcherName,
        appEventFilters: [
          {
            domain: hiAppEvent.domain.OS,
            names: ['MAIN_THREAD_JANK']  // Main thread jank event name
          }
        ],
        onReceive: async (_domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          this.handleMainThreadJankEvents(appEventGroups);
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to subscribe to MAIN_THREAD_JANK events: ${error}`);
    }
  }
  
  /**
   * Unsubscribe from MAIN_THREAD_JANK events
   */
  private unsubscribeFromMainThreadJankEvents(): void {
    try {
      hiAppEvent.removeWatcher({
        name: this.appEventWatcherName
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to unsubscribe from MAIN_THREAD_JANK events: ${error}`);
    }
  }
  
  /**
   * Handle MAIN_THREAD_JANK events from system
   */
  private handleMainThreadJankEvents(appEventGroups: Array<hiAppEvent.AppEventGroup>): void {
    try {
      appEventGroups.forEach((eventGroup: hiAppEvent.AppEventGroup) => {
        eventGroup.appEventInfos.forEach((eventInfo: hiAppEvent.AppEventInfo) => {
          // Check if this is a MAIN_THREAD_JANK event
          if (eventInfo.name === 'MAIN_THREAD_JANK') {
            this.handleMainThreadJankEvent(eventInfo);
          }
        });
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Error handling MAIN_THREAD_JANK events: ${error}`);
    }
  }
  
  /**
   * Handle a single MAIN_THREAD_JANK event
   */
  private handleMainThreadJankEvent(eventInfo: hiAppEvent.AppEventInfo): void {
    try {
      // Extract duration from event params
      // System triggers: >150ms generates sample stack, >450ms generates Trace file
      const params = eventInfo.params as Record<string, Object>;
      let durationMs = 0;
      
      // Try to extract duration from various possible fields
      if (params.duration !== undefined) {
        durationMs = Number(params.duration);
      } else if (params.blockDuration !== undefined) {
        durationMs = Number(params.blockDuration);
      } else if (params.jankDuration !== undefined) {
        durationMs = Number(params.jankDuration);
      } else {
        // Default: use threshold as minimum (system triggers at 150ms, but we report if >= threshold)
        durationMs = this.blockDurationNS / 1000000;
      }
      
      // Convert to nanoseconds
      const durationNS = durationMs * 1000000;
      
      // Only report if duration exceeds our threshold
      if (durationNS >= this.blockDurationNS) {
        // Extract stack trace if available
        // Priority: heaviest_stack > exception > stackTrace > stack > trace
        let stackTrace = '';
        
        // 1. Try heaviest_stack first (most reliable, provided by system)
        if (params.heaviest_stack !== undefined) {
          stackTrace = String(params.heaviest_stack);
        } 
        // 2. Try exception (may contain stack info)
        else if (params.exception !== undefined) {
          try {
            const exceptionObj = params.exception;
            if (typeof exceptionObj === 'string') {
              stackTrace = exceptionObj;
            } else if (typeof exceptionObj === 'object') {
              // Try to extract stack from exception object
              const exceptionStr = JSON.stringify(exceptionObj);
              stackTrace = exceptionStr;
            }
          } catch (e) {
            FTInnerLogger.w(TAG, `[FT-UI-BLOCK] Failed to parse exception: ${e}`);
          }
        }
        // 3. Try other possible stack fields
        else if (params.stackTrace !== undefined) {
          stackTrace = String(params.stackTrace);
        } else if (params.stack !== undefined) {
          stackTrace = String(params.stack);
        } else if (params.trace !== undefined) {
          stackTrace = String(params.trace);
        }
        
        // Build stack trace message
        const stackMessage = stackTrace && stackTrace.length > 0 
          ? `${this.currentMethod}\n${stackTrace}` 
          : this.currentMethod;
        
        // Report as long task
        try {
          const rumManager = FTRUMInnerManager.getInstance();
          rumManager.addLongTask(
            stackMessage,
            durationNS,
            {}
          );
          FTInnerLogger.i(TAG, `[FT-UI-BLOCK] Reported MAIN_THREAD_JANK long task: duration=${durationMs.toFixed(2)}ms`);
        } catch (error) {
          FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to report MAIN_THREAD_JANK as long task: ${error}`);
        }
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Error handling MAIN_THREAD_JANK event: ${error}`);
    }
  }
  
  /**
   * Start detection timer
   */
  private startDetection(): void {
    // Clear existing timer if any
    if (this.detectTimer !== null) {
      clearInterval(this.detectTimer);
    }
    
    // Schedule periodic detection task on main thread
    this.detectTimer = setInterval(() => {
      if (!this.isRunning) {
        return;
      }
      
      this.checkUIBlocking();
    }, FTUIBlockManager.DETECT_INTERVAL_MS);
  }
  
  /**
   * Get current call stack trace
   * Uses Error().stack to capture the current call stack
   * 
   * Note: Since this is called from a timer callback, the stack trace will show
   * the timer callback chain. While it may not directly show the blocking method,
   * it provides context about what was happening when the block was detected.
   * 
   * @returns Stack trace string with SDK internal calls filtered out
   */
  private getStackTrace(): string {
    try {
      // Use a timeout to prevent blocking if Error() construction takes too long
      // In case of severe blocking, we want to return quickly
      const error = new Error();
      if (error && error.stack) {
        try {
          const stackLines = error.stack.split('\n');
          
          const filteredLines: string[] = [];
          
          // Filter out SDK internal calls to show more relevant user code
          // Skip first line (Error message) and SDK internal paths
          for (let i = 1; i < stackLines.length; i++) {
            try {
              const line = stackLines[i];
              const trimmedLine = line.trim();
              
              // Skip empty lines
              if (trimmedLine.length === 0) {
                continue;
              }
              
              // Skip SDK internal paths (ft_sdk, FTUIBlockManager, etc.)
              if (trimmedLine.includes('FTUIBlockManager') || 
                  trimmedLine.includes('ft_sdk') ||
                  trimmedLine.includes('checkUIBlocking') ||
                  trimmedLine.includes('getStackTrace')) {
                continue;
              }
              
              filteredLines.push(trimmedLine);
            } catch (lineErr) {
              // Skip problematic lines
              continue;
            }
          }
          
          // If we filtered everything or result is empty, return original stack (skip first 2 lines)
          const result = filteredLines.join('\n');
          if (filteredLines.length === 0 || result.length === 0) {
            try {
              const fallbackStack = stackLines.length > 2 
                ? stackLines.slice(2).map(line => line.trim()).filter(line => line.length > 0).join('\n')
                : error.stack;
              return fallbackStack;
            } catch (fallbackErr) {
              FTInnerLogger.w(TAG, `Error creating fallback stack: ${fallbackErr}`);
              return "Stack trace processing failed";
            }
          }
          return result;
        } catch (processErr) {
          FTInnerLogger.w(TAG, `Error processing stack trace: ${processErr}`);
          // Return a simplified stack trace
          return error.stack ? error.stack.substring(0, 1000) : "Stack trace processing failed";
        }
      }
      FTInnerLogger.w(TAG, "Error.stack is undefined or empty");
      return "Stack trace not available";
    } catch (err) {
      FTInnerLogger.e(TAG, `Failed to get stack trace: ${err}`);
      // Return a safe fallback message
      return "Stack trace unavailable (Error construction failed)";
    }
  }

  /**
   * Check UI blocking by monitoring task execution time
   * 
   * Principle:
   * 1. Schedule a task to run on main thread
   * 2. Record the scheduled time
   * 3. When task executes, record the actual execution time
   * 4. If the delay between scheduled time and execution time exceeds threshold,
   *    it indicates main thread blocking
   * 5. When blocking is detected, capture the current call stack to identify
   *    which method is causing the blocking
   */
  private checkUIBlocking(): void {
    const now = Utils.getCurrentNanoTime();
    
    // If this is the first check, just record the time
    if (this.lastScheduledTime === 0) {
      this.lastScheduledTime = now;
      this.lastTaskStartTime = now;
      return;
    }
    
    // Calculate the delay between scheduled time and actual execution time
    // If main thread is blocked, this delay will be significant
    const delay = now - this.lastScheduledTime;
    // Update scheduled time for next check
    this.lastScheduledTime = now;
    
    // If delay exceeds threshold, it indicates UI blocking
    if (delay > this.blockDurationNS) {
      // Check if this is the start of a new blocking period
      if (!this.isBlocking) {
        // Start of new blocking period
        this.isBlocking = true;
        this.blockingStartTime = now - delay; // Blocking started (delay) nanoseconds ago
        this.lastReportTime = this.blockingStartTime;
      }
      
      // Calculate how long we've been blocking
      const totalBlockingDuration = now - this.blockingStartTime;
      const totalBlockingDurationMs = totalBlockingDuration / 1000000;
      
      // Check if we should report (every threshold interval)
      const timeSinceLastReport = now - this.lastReportTime;
      if (timeSinceLastReport >= this.blockDurationNS) {
        // Time to report another long task
        // Aligned with Android: All UI blocks exceeding threshold are reported as long_task,
        // regardless of duration (1s, 3s, 5s, 10s, etc.)
        const reportDuration = timeSinceLastReport; // Report the interval duration
        const reportDurationMs = reportDuration / 1000000;
        
        // Get current call stack to identify the blocking method
        const stackTrace = this.getStackTrace();
        
        // Build stack trace message with method name
        const stackMessage = stackTrace && stackTrace.length > 0 
          ? `${this.currentMethod}\n${stackTrace}` 
          : this.currentMethod;
        
        // Report blocking event as long task (aligned with Android: all UI blocks are long_task)
        try {
          const rumManager = FTRUMInnerManager.getInstance();
          
          try {
            rumManager.addLongTask(
              stackMessage,
              reportDuration, // Report the interval duration, not total
              {}
            );
            FTInnerLogger.i(TAG, `[FT-UI-BLOCK] Reported long task: interval=${reportDurationMs.toFixed(2)}ms, total=${totalBlockingDurationMs.toFixed(2)}ms`);
          } catch (addLongTaskException) {
            FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Exception in addLongTask: ${addLongTaskException}`);
            // Fallback: try to report without stack trace
            try {
              rumManager.addLongTask(
                this.currentMethod,
                reportDuration,
                {}
              );
              FTInnerLogger.i(TAG, `[FT-UI-BLOCK] Reported long task without stack trace: interval=${reportDurationMs.toFixed(2)}ms`);
            } catch (fallbackException) {
              FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Fallback addLongTask also failed: ${fallbackException}`);
            }
          }
        } catch (error) {
          FTInnerLogger.e(TAG, `[FT-UI-BLOCK] Failed to report blocking event: ${error}`);
        }
        
        // Update last report time
        this.lastReportTime = now;
      }
    } else {
      // Delay is within threshold, blocking has ended
      if (this.isBlocking) {
        // Reset blocking state
        this.isBlocking = false;
        this.blockingStartTime = 0;
        this.lastReportTime = 0;
      }
    }
    
    // Record task start time for next check
    this.lastTaskStartTime = now;
  }
}
