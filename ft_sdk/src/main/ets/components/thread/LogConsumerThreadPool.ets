/**
 * Log Consumer Thread Pool for HarmonyOS SDK
 * Dedicated single-core thread pool for log data processing
 * Log Consumer Thread Pool for HarmonyOS SDK
 */
import { FTInnerLogger } from '../log/FTLogger';
import { ThreadPoolManager } from './ThreadPoolManager';

const TAG = "LogConsumerThreadPool";

/**
 * Log Consumer Thread Pool
 * Single core thread pool for log data processing
 */
export class LogConsumerThreadPool {
  private static instance: LogConsumerThreadPool | null = null;
  private threadPoolManager: ThreadPoolManager;
  private isRunning: boolean = false;
  private currentTask: (() => void) | null = null;

  // Log-specific configuration
  private static readonly LOG_PROCESSING_INTERVAL = 200; // 200ms
  private logQueue: (() => void)[] = [];
  private isProcessing: boolean = false;
  
  private constructor() {
    this.threadPoolManager = ThreadPoolManager.getInstance();
    FTInnerLogger.d(TAG, "LogConsumerThreadPool initialized");
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): LogConsumerThreadPool {
    if (!LogConsumerThreadPool.instance) {
      LogConsumerThreadPool.instance = new LogConsumerThreadPool();
    }
    return LogConsumerThreadPool.instance;
  }
  
  /**
   * Initialize log runnable task
   */
  public initRunnable(runnable: () => void): void {
    this.currentTask = runnable;
    FTInnerLogger.i(TAG, "LogConsumerThreadPool runnable initialized");
  }
  
  /**
   * Execute log task immediately
   */
  public executeLogTask(task: () => void): void {
    FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Executing log task immediately`);
    
    try {
      // Check if ThreadPoolManager is initialized by checking status
      const status = this.threadPoolManager.getStatus();
      if (!status.isInitialized) {
        FTInnerLogger.w(TAG, `<FT-LOG-THREAD> ThreadPoolManager not initialized, attempting to initialize...`);
        // Try to initialize ThreadPoolManager synchronously (if possible)
        // Note: This is a fallback, ideally ThreadPoolManager should be initialized before log processing
        this.threadPoolManager.initialize().then(() => {
          FTInnerLogger.d(TAG, `<FT-LOG-THREAD> ThreadPoolManager initialized, executing task`);
          this.threadPoolManager.executeNormalPriority(() => {
            try {
              task();
              FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task completed successfully`);
            } catch (error) {
              FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log task failed: ${error}`);
            }
          });
        }).catch((error:Error) => {
          const errorMsg = error instanceof Error ? error.message : String(error);
          FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Failed to initialize ThreadPoolManager: ${errorMsg}`);
          // Fallback: execute task directly on main thread if ThreadPoolManager initialization fails
          try {
            task();
            FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task executed on main thread as fallback`);
          } catch (taskError) {
            const taskErrorMsg = taskError instanceof Error ? taskError.message : String(taskError);
            FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log task failed on main thread: ${taskErrorMsg}`);
          }
        });
        return;
      }
      
      // Use normal priority for log tasks
      this.threadPoolManager.executeNormalPriority(() => {
        try {
          task();
          FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task completed successfully`);
        } catch (error) {
          FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log task failed: ${error}`);
        }
      });
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Error executing log task: ${error}`);
      // Fallback: execute task directly on main thread if ThreadPoolManager is not available
      try {
        task();
        FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task executed on main thread as fallback`);
      } catch (taskError) {
        FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log task failed on main thread: ${taskError}`);
      }
    }
  }
  
  /**
   * Execute log task with delay
   */
  public executeLogTaskWithDelay(task: () => void, delay: number = 0): void {
    FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Executing log task with delay: ${delay}ms`);
    
    if (delay > 0) {
      setTimeout(() => {
        this.executeLogTask(task);
      }, delay);
    } else {
      this.executeLogTask(task);
    }
  }
  
  /**
   * Add log task to queue (unbounded queue)
   */
  public addLogTaskToQueue(task: () => void): void {
    this.logQueue.push(task);
    FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task added to queue, queue size: ${this.logQueue.length}`);
    
    // Trigger processing if not already processing
    if (!this.isProcessing) {
      this.processLogQueue();
    }
  }
  
  /**
   * Process log queue
   */
  private processLogQueue(): void {
    if (this.isProcessing || this.logQueue.length === 0) {
      return;
    }
    
    this.isProcessing = true;
    FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Starting log queue processing, queue size: ${this.logQueue.length}`);
    
    // Process tasks in batches
    const batchSize = Math.min(10, this.logQueue.length);
    const tasks = this.logQueue.splice(0, batchSize);
    
    this.threadPoolManager.executeNormalPriority(() => {
      try {
        for (const task of tasks) {
          try {
            task();
            FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log task processed successfully`);
          } catch (error) {
            FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log task processing failed: ${error}`);
          }
        }
        
        FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log batch processed: ${tasks.length} tasks`);
        
        // Continue processing if there are more tasks
        if (this.logQueue.length > 0) {
          setTimeout(() => {
            this.isProcessing = false;
            this.processLogQueue();
          }, LogConsumerThreadPool.LOG_PROCESSING_INTERVAL);
        } else {
          this.isProcessing = false;
          FTInnerLogger.d(TAG, `<FT-LOG-THREAD> Log queue processing completed`);
        }
        
      } catch (error) {
        this.isProcessing = false;
        FTInnerLogger.e(TAG, `<FT-LOG-THREAD> Log queue processing failed: ${error}`);
      }
    });
  }
  

  /**
   * Get log queue status
   */
  public getLogQueueStatus(): LogQueueStatus {
    return {
      queueSize: this.logQueue.length,
      isProcessing: this.isProcessing,
      isRunning: this.isRunning,
      maxQueueSize: -1 // Unbounded queue
    };
  }
  
  /**
   * Clear log queue
   */
  public clearLogQueue(): void {
    this.logQueue = [];
    this.isProcessing = false;
    FTInnerLogger.d(TAG, "<FT-LOG-THREAD> Log queue cleared");
  }
  
  /**
   * Shutdown log thread pool
   */
  public shutdown(): void {
    FTInnerLogger.i(TAG, "Shutting down LogConsumerThreadPool");
    
    this.clearLogQueue();
    this.currentTask = null;
    this.isRunning = false;
    
    FTInnerLogger.i(TAG, "LogConsumerThreadPool shutdown completed");
  }
}

/**
 * Log Queue Status Interface
 */
export interface LogQueueStatus {
  queueSize: number;
  isProcessing: boolean;
  isRunning: boolean;
  maxQueueSize: number;
}