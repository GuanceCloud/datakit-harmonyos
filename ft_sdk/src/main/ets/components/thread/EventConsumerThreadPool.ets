/**
 * Event Consumer Thread Pool for HarmonyOS SDK
 * Dedicated single-core thread pool for RUM event data processing
 * Event Consumer Thread Pool for HarmonyOS SDK
 */
import { FTInnerLogger } from '../log/FTLogger';
import { ThreadPoolManager } from './ThreadPoolManager';

const TAG = "EventConsumerThreadPool";

/**
 * Event Consumer Thread Pool
 * Single core thread pool for RUM event data processing
 */
export class EventConsumerThreadPool {
  private static instance: EventConsumerThreadPool | null = null;
  private threadPoolManager: ThreadPoolManager;
  private isRunning: boolean = false;
  private currentTask: (() => void) | null = null;
  private scheduledDelay: number = 0;
  
  // Event-specific configuration
  private static readonly EVENT_PROCESSING_INTERVAL = 100; // 100ms
  private eventQueue: (() => void)[] = [];
  private isProcessing: boolean = false;
  
  private constructor() {
    this.threadPoolManager = ThreadPoolManager.getInstance();
    FTInnerLogger.d(TAG, "EventConsumerThreadPool initialized");
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): EventConsumerThreadPool {
    if (!EventConsumerThreadPool.instance) {
      EventConsumerThreadPool.instance = new EventConsumerThreadPool();
    }
    return EventConsumerThreadPool.instance;
  }
  
  /**
   * Initialize event runnable task
   */
  public initRunnable(runnable: () => void): void {
    this.currentTask = runnable;
    FTInnerLogger.i(TAG, "EventConsumerThreadPool runnable initialized");
  }
  
  /**
   * Execute event task immediately
   */
  public executeEventTask(task: () => void): void {
    
    // Use high priority for event tasks (RUM data)
    this.threadPoolManager.executeHighPriority(() => {
      try {
        task();
      } catch (error) {
        FTInnerLogger.e(TAG, `<FT-EVENT-THREAD> Event task failed: ${error}`);
      }
    });
  }
  
  /**
   * Execute event task with delay
   */
  public executeEventTaskWithDelay(task: () => void, delay: number = 0): void {
    
    if (delay > 0) {
      setTimeout(() => {
        this.executeEventTask(task);
      }, delay);
    } else {
      this.executeEventTask(task);
    }
  }
  
  /**
   * Add event task to queue (unbounded queue)
   */
  public addEventTaskToQueue(task: () => void): void {
    this.eventQueue.push(task);
    
    // Trigger processing if not already processing
    if (!this.isProcessing) {
      this.processEventQueue();
    }
  }
  
  /**
   * Process event queue
   */
  private processEventQueue(): void {
    if (this.isProcessing || this.eventQueue.length === 0) {
      return;
    }
    
    this.isProcessing = true;
    
    // Process tasks in batches
    const batchSize = Math.min(5, this.eventQueue.length);
    const tasks = this.eventQueue.splice(0, batchSize);
    
    this.threadPoolManager.executeHighPriority(() => {
      try {
        for (const task of tasks) {
          try {
            task();
          } catch (error) {
            FTInnerLogger.e(TAG, `<FT-EVENT-THREAD> Event task processing failed: ${error}`);
          }
        }
        
        
        // Continue processing if there are more tasks
        if (this.eventQueue.length > 0) {
          setTimeout(() => {
            this.isProcessing = false;
            this.processEventQueue();
          }, EventConsumerThreadPool.EVENT_PROCESSING_INTERVAL);
        } else {
          this.isProcessing = false;
        }
        
      } catch (error) {
        this.isProcessing = false;
        FTInnerLogger.e(TAG, `<FT-EVENT-THREAD> Event queue processing failed: ${error}`);
      }
    });
  }
  
  /**
   * Schedule event task
   */
  public schedule(delay: number = 0): void {
    if (!this.currentTask) {
      FTInnerLogger.w(TAG, "<FT-EVENT-THREAD> No runnable task available");
      return;
    }

    if (this.isRunning) {
      return;
    }

    this.scheduledDelay = delay;
    
    if (delay > 0) {
      setTimeout(() => {
        this.executeCurrentEventTask();
      }, delay);
    } else {
      this.executeCurrentEventTask();
    }
  }
  
  /**
   * Execute current event task
   */
  private executeCurrentEventTask(): void {
    
    if (!this.currentTask || this.isRunning) {
      return;
    }

    this.isRunning = true;

    try {
      // Use high priority for event tasks
      this.threadPoolManager.executeHighPriority(() => {
        try {
          this.currentTask!();
        } catch (error) {
          FTInnerLogger.e(TAG, `<FT-EVENT-THREAD> Event task execution failed: ${error}`);
        } finally {
          this.isRunning = false;
        }
      });

    } catch (error) {
      this.isRunning = false;
      FTInnerLogger.e(TAG, `Failed to schedule event task: ${error}`);
    }
  }
  
  /**
   * Get event queue status
   */
  public getEventQueueStatus(): EventQueueStatus {
    return {
      queueSize: this.eventQueue.length,
      isProcessing: this.isProcessing,
      isRunning: this.isRunning,
      maxQueueSize: -1 // Unbounded queue
    };
  }
  
  /**
   * Clear event queue
   */
  public clearEventQueue(): void {
    this.eventQueue = [];
    this.isProcessing = false;
  }
  
  /**
   * Shutdown event thread pool
   */
  public shutdown(): void {
    FTInnerLogger.i(TAG, "Shutting down EventConsumerThreadPool");
    
    this.clearEventQueue();
    this.currentTask = null;
    this.isRunning = false;
    
    FTInnerLogger.i(TAG, "EventConsumerThreadPool shutdown completed");
  }
}

/**
 * Event Queue Status Interface
 */
export interface EventQueueStatus {
  queueSize: number;
  isProcessing: boolean;
  isRunning: boolean;
  maxQueueSize: number;
}
