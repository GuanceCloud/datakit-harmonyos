/**
 * Data Upload Thread Pool for HarmonyOS SDK
 * Dedicated multi-core thread pool for data synchronization and upload
 * Data Upload Thread Pool for HarmonyOS SDK
 */
import { FTInnerLogger } from '../log/FTLogger';
import { ThreadPoolManager } from './ThreadPoolManager';

const TAG = "DataUploadThreadPool";

/**
 * Data Upload Thread Pool
 * Multi-core thread pool for data synchronization and upload
 */
export class DataUploadThreadPool {
  private static instance: DataUploadThreadPool | null = null;
  private threadPoolManager: ThreadPoolManager;
  private isRunning: boolean = false;
  private currentTask: (() => void) | null = null;
  private scheduledDelay: number = 0;
  private scheduledTime: number = 0; // Track when task was scheduled
  
  // Upload-specific configuration
  private static readonly UPLOAD_PROCESSING_INTERVAL = 1000; // 1s
  private static readonly SCHEDULE_TIMEOUT = 5000; // 5 seconds timeout for scheduled tasks
  private uploadQueue: (() => void)[] = [];
  private isProcessing: boolean = false;
  private isScheduled: boolean = false;
  private needReschedule: boolean = false;
  
  private constructor() {
    this.threadPoolManager = ThreadPoolManager.getInstance();
    FTInnerLogger.d(TAG, "DataUploadThreadPool initialized");
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): DataUploadThreadPool {
    if (!DataUploadThreadPool.instance) {
      DataUploadThreadPool.instance = new DataUploadThreadPool();
    }
    return DataUploadThreadPool.instance;
  }
  
  /**
   * Initialize upload runnable task
   */
  public initRunnable(runnable: () => void): void {
    FTInnerLogger.d(TAG, "******************* Sync Poll Ready *******************>>>");
    this.isScheduled = false;
    this.scheduledTime = 0;
    this.needReschedule = false;
    this.currentTask = runnable;
    FTInnerLogger.i(TAG, "DataUploadThreadPool runnable initialized");
  }
  
  /**
   * Set running status (for testing)
   */
  public setRunning(isScheduled: boolean): void {
    this.isScheduled = isScheduled;
  }
  
  /**
   * Execute upload task immediately
   */
  public executeUploadTask(task: () => void): void {
    // Removed verbose debug log to reduce log output
    
    // Use low priority for upload tasks
    this.threadPoolManager.executeLowPriority(() => {
      try {
        task();
        // Removed verbose debug log to reduce log output
      } catch (error) {
        FTInnerLogger.e(TAG, `<FT-UPLOAD-THREAD> Upload task failed: ${error}`);
      }
    });
  }
  
  /**
   * Execute upload task with delay
   */
  public executeUploadTaskWithDelay(task: () => void, delay: number = 0): void {
    // Removed verbose debug log to reduce log output
    
    if (delay > 0) {
      setTimeout(() => {
        this.executeUploadTask(task);
      }, delay);
    } else {
      this.executeUploadTask(task);
    }
  }
  
  /**
   * Add upload task to queue (unbounded queue)
   */
  public addUploadTaskToQueue(task: () => void): void {
    this.uploadQueue.push(task);
    // Removed verbose debug log to reduce log output
    
    // Trigger processing if not already processing
    if (!this.isProcessing) {
      this.processUploadQueue();
    }
  }
  
  /**
   * Process upload queue
   */
  private processUploadQueue(): void {
    if (this.isProcessing || this.uploadQueue.length === 0) {
      return;
    }
    
    this.isProcessing = true;
    // Removed verbose debug log to reduce log output
    
    // Process tasks in batches
    const batchSize = Math.min(3, this.uploadQueue.length);
    const tasks = this.uploadQueue.splice(0, batchSize);
    
    this.threadPoolManager.executeLowPriority(() => {
      try {
        for (const task of tasks) {
          try {
            task();
            // Removed verbose debug log to reduce log output
          } catch (error) {
            FTInnerLogger.e(TAG, `<FT-UPLOAD-THREAD> Upload task processing failed: ${error}`);
          }
        }
        
        // Removed verbose debug log to reduce log output
        
        // Continue processing if there are more tasks
        if (this.uploadQueue.length > 0) {
          setTimeout(() => {
            this.isProcessing = false;
            this.processUploadQueue();
          }, DataUploadThreadPool.UPLOAD_PROCESSING_INTERVAL);
        } else {
          this.isProcessing = false;
          // Removed verbose debug log to reduce log output
        }
        
      } catch (error) {
        this.isProcessing = false;
        FTInnerLogger.e(TAG, `<FT-UPLOAD-THREAD> Upload queue processing failed: ${error}`);
      }
    });
  }
  
  /**
   * Schedule upload task
   * Ensures only one upload task is scheduled/executing at a time to prevent concurrent duplicate uploads
   */
  public schedule(delay: number = 0): void {
    if (!this.currentTask) {
      FTInnerLogger.w(TAG, "<FT-UPLOAD-THREAD> No runnable task available");
      return;
    }

    // Prevent concurrent execution: if already running or scheduled, skip to prevent duplicate uploads
    if (this.isRunning) {
      // Removed verbose debug log to reduce log output
      return;
    }

    // Check if scheduled task has timed out (stuck in scheduled state)
    if (this.isScheduled && this.scheduledTime > 0) {
      const elapsed = Date.now() - this.scheduledTime;
      if (elapsed > DataUploadThreadPool.SCHEDULE_TIMEOUT) {
        FTInnerLogger.w(TAG, `<FT-UPLOAD-THREAD> Scheduled task timeout (${elapsed}ms), forcing reset`);
        this.isScheduled = false;
        this.scheduledTime = 0;
      }
    }

    if (!this.isScheduled) {
      this.isScheduled = true;
      this.scheduledTime = Date.now();
      this.needReschedule = false;
      this.scheduleTask(delay);
    } else {
      // Task already waiting or executing, skip scheduling
      this.needReschedule = true;
      // Removed verbose debug log to reduce log output
    }
  }
  
  /**
   * Schedule task with delay
   */
  private scheduleTask(delay: number): void {
    if (delay > 0) {
      // Removed verbose debug log to reduce log output
      setTimeout(() => {
        this.executeCurrentUploadTask();
      }, delay);
    } else {
      // Removed verbose debug log to reduce log output
      this.executeCurrentUploadTask();
    }
  }
  
  /**
   * Execute current upload task
   */
  private executeCurrentUploadTask(): void {
    // Removed verbose debug log to reduce log output
    
    if (!this.currentTask) {
      FTInnerLogger.w(TAG, `<FT-UPLOAD-THREAD> No current task available, resetting scheduled state`);
      this.isScheduled = false;
      this.scheduledTime = 0;
      return;
    }

    if (this.isRunning) {
      // Removed verbose debug log to reduce log output
      return;
    }

    // Reset scheduled state immediately when starting execution to prevent stuck state
    this.isScheduled = false;
    this.scheduledTime = 0;
    this.isRunning = true;
    // Removed verbose debug log to reduce log output

    try {
      // Use low priority for upload tasks
      this.threadPoolManager.executeLowPriority(() => {
        try {
          this.currentTask!();
          // Removed verbose debug log to reduce log output
        } catch (error) {
          FTInnerLogger.e(TAG, `<FT-UPLOAD-THREAD> Upload task execution failed: ${error}`);
        } finally {
          this.isRunning = false;
          // Ensure isScheduled is false (already reset above, but double-check)
          this.isScheduled = false;
          this.scheduledTime = 0;
          // Removed verbose debug log to reduce log output
          
          // Check if reschedule is needed
          if (this.needReschedule) {
            this.needReschedule = false;
            this.schedule(0);
          }
        }
      });

    } catch (error) {
      // If executeLowPriority fails, ensure state is reset
      this.isRunning = false;
      this.isScheduled = false;
      this.scheduledTime = 0;
      FTInnerLogger.e(TAG, `Failed to schedule upload task: ${error}`);
    }
  }
  
  /**
   * Get upload queue status
   */
  public getUploadQueueStatus(): UploadQueueStatus {
    return {
      queueSize: this.uploadQueue.length,
      isProcessing: this.isProcessing,
      isRunning: this.isRunning,
      isScheduled: this.isScheduled,
      needReschedule: this.needReschedule,
      maxQueueSize: -1 // Unbounded queue
    };
  }
  
  /**
   * Clear upload queue
   */
  public clearUploadQueue(): void {
    this.uploadQueue = [];
    this.isProcessing = false;
    this.isScheduled = false;
    this.scheduledTime = 0;
    this.needReschedule = false;
    // Removed verbose debug log to reduce log output
  }
  
  /**
   * Shutdown upload thread pool
   */
  public shutdown(): void {
    FTInnerLogger.i(TAG, "Shutting down DataUploadThreadPool");
    
    this.clearUploadQueue();
    this.currentTask = null;
    this.isRunning = false;
    
    FTInnerLogger.i(TAG, "DataUploadThreadPool shutdown completed");
  }
}

/**
 * Upload Queue Status Interface
 */
export interface UploadQueueStatus {
  queueSize: number;
  isProcessing: boolean;
  isRunning: boolean;
  isScheduled: boolean;
  needReschedule: boolean;
  maxQueueSize: number;
}