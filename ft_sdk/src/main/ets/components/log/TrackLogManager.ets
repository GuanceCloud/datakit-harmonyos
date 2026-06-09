import { LogBean } from '../bean/LogBean';
import { BaseContentBean } from '../bean/BaseContentBean';
import { FTDBCachePolicy } from '../db/FTDBCachePolicy';
import { LogConsumerThreadPool } from '../thread/LogConsumerThreadPool';
import FTTrackInner from '../FTTrackInner';
import { FTInnerLogger } from "../log/FTLogger";
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { StringWrapper } from '../utils/StringWrapper';
import { FTLoggerConfig } from '../Configs';
import { Constants } from '../Constants';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';

const TAG = "TrackLogManager";

/**
 * Queue status interface
 */
export interface QueueStatus {
  queueSize: number;
  bufferSize: number;
  isProcessing: boolean;
}

/**
 * Worker message interface
 */
interface WorkerMessage {
  type: string;
  batchSize?: number;
  isSilence?: boolean;
}

/**
 * Log tracking manager - HarmonyOS implementation
 * Responsible for managing log queues, batch processing and async processing
 */
export class TrackLogManager {
  private static instance: TrackLogManager | null = null;
  
  // Configuration constants
  private static readonly DEFAULT_BATCH_SIZE = 20; // Match Android's value
  private static readonly POLL_TIMEOUT_MS = 200;
  
  // Core components - Dual Queue Design
  // inputQueue: Receives new logs from producers (trackLog calls)
  // processingQueue: Used by processQueue to consume logs
  // This design prevents infinite loops by allowing processQueue to fully drain processingQueue
  // while new logs continue to be added to inputQueue without interference
  private inputQueue: LogBean[] = [];
  private processingQueue: LogBean[] = [];
  private logBatchBuffer: BaseContentBean[] = [];
  private isProcessing: boolean = false;
  private bufferLocked: boolean = false;
  
  // Log configuration
  private logConfig: FTLoggerConfig | null = null;
  
  // Worker thread processing
  private processingTimer: number | null = null;
  
  private constructor() {
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): TrackLogManager {
    if (TrackLogManager.instance === null) {
      TrackLogManager.instance = new TrackLogManager();
    }
    return TrackLogManager.instance;
  }

  public static resetStateInternal(): void {
    if (TrackLogManager.instance !== null) {
      TrackLogManager.instance.resetInternalState();
    }
  }

  private resetInternalState(): void {
    this.shutdown();
    this.logConfig = null;
    this.bufferLocked = false;
  }
  
  /**
   * Set log configuration
   * @param config Log configuration
   */
  public setLogConfig(config: FTLoggerConfig): void {
    this.logConfig = config;
    FTInnerLogger.d(TAG, `Log config updated: samplingRate=${config.getSamplingRate()}, enableCustomLog=${config.isEnableCustomLog()}`);

    // If there are logs in queue and processing is not active, trigger processing
    // This handles the case where logs were queued before ThreadPoolManager was initialized
    const totalQueueSize = this.inputQueue.length + this.processingQueue.length;
    if (totalQueueSize > 0 && !this.isProcessing) {
      FTInnerLogger.d(TAG, `Log config updated, triggering processing for ${totalQueueSize} queued logs`);
      this.triggerProcessing(false);
    }
  }

  /**
   * Get log configuration
   * @return Log configuration or null if not set
   */
  public getLogConfig(): FTLoggerConfig | null {
    return this.logConfig;
  }
  


  /**
   * Track log
   * @param logBean Log data
   * @param isSilence Whether silent mode
   */
  public trackLog(logBean: LogBean, isSilence: boolean = false): void {
    // Removed verbose debug log to reduce log output
    if (!this.shouldProcessLog(logBean)) {
      return;
    }
    
    
    
    // Queue size limit (check inputQueue only, as processingQueue is being processed)
    const cachePolicy = FTDBCachePolicy.getInstance();
    const maxSize = Math.min(cachePolicy.getLogLimitCount(), Constants.MAX_QUEUE_SIZE_LOG);
    
    
    
    if (this.inputQueue.length >= maxSize) {
      // Use default strategy: discard oldest log
      this.inputQueue.shift(); // Remove oldest log
      FTInnerLogger.w(TAG, 'Input queue full, discarding oldest log');
    }
    
    this.inputQueue.push(logBean);
    // Removed verbose debug log to reduce log output
    // Trigger processing
    
    this.triggerProcessing(isSilence);
  }
  
  /**
   * Batch record logs
   * @param logBeans Log data array
   * @param isSilence Whether silent mode
   */
  public trackLogBatch(logBeans: LogBean[], isSilence: boolean = false): void {
    if (!logBeans || logBeans.length === 0) {
      return;
    }
    
    for (const logBean of logBeans) {
      this.trackLog(logBean, isSilence);
    }
    
    FTInnerLogger.d(TAG, `Batch logged: ${logBeans.length} logs`);
  }
  
  /**
   * Get queue status
   */
  public getQueueStatus(): QueueStatus {
    // Return total queue size (inputQueue + processingQueue)
    return {
      queueSize: this.inputQueue.length + this.processingQueue.length,
      bufferSize: this.logBatchBuffer.length,
      isProcessing: this.isProcessing
    };
  }
  
  /**
   * Force flush buffer
   */
  public forceFlush(isSilence: boolean = false): void {
    FTInnerLogger.d(TAG, "Force flushing log buffer");
    this.flushBatch(isSilence);
  }
  
  /**
   * Determine whether log should be processed
   */
  private shouldProcessLog(logBean: LogBean): boolean {
    // Check log configuration
    if (!this.logConfig) {
      FTInnerLogger.w(TAG, "Log config not set, discarding log");
      return false;
    }
    
    // Check if custom log is enabled
    if (!this.logConfig.isEnableCustomLog()) {
      FTInnerLogger.d(TAG, "Custom log disabled, discarding log");
      return false;
    }
    
    // Get sampling rate
    const samplingRate = this.logConfig.getSamplingRate();
    // Removed verbose debug log to reduce log output
    
    // Sampling rate check
    if (samplingRate < 1.0) {
      const randomValue = Math.random();
      // Removed verbose debug logs to reduce log output
      if (randomValue > samplingRate) {
        return false;
      }
    }
    
    // Check log level filter
    if (!this.logConfig.checkLogLevel(logBean.getStatus())) {
      return false;
    }
    
    // Check log prefix filter
    if (!this.logConfig.checkPrefix(logBean.getContent())) {
      return false;
    }
    
    // Link RUM data
    if (this.logConfig.isEnableLinkRumData()) {
      try {
        const rumManager = FTRUMConfigManager.getInstance();
        if (rumManager) {
          // Get RUM dynamic tags (similar to Android SDK)
          const rumTags = rumManager.getRUMPublicDynamicTags();
          
          // Attach RUM relative information (View, Action, Session)
          FTRUMInnerManager.getInstance().attachRUMRelative(rumTags, false);
          
          // Convert all RUM tags (including attached ones) to object tags for log using StringWrapper
          const logTags: Record<string, object> = {};
          const allTagKeys = Object.keys(rumTags);
          for (let i = 0; i < allTagKeys.length; i++) {
            const key = allTagKeys[i];
            const value: string = rumTags[key] as string;
            logTags[key] = new StringWrapper(value);
          }

          // Append tags to log bean
          logBean.appendTags(logTags);
          
          // FTInnerLogger.d(TAG, `RUM data attached to log: ${Object.keys(logTags).length} tags`);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to attach RUM data: ${error}`);
      }
    }
    
    return true;
  }
  
  /**
   * Trigger processing
   */
  private triggerProcessing(isSilence: boolean): void {
    // Removed verbose debug log to reduce log output
    
    if (this.isProcessing) {
      // If already processing, don't trigger again
      // The processing will continue and handle remaining queue items
      // Removed verbose debug log to reduce log output
      return;
    }
    
    this.isProcessing = true;
    this.process(isSilence);
  }
  

  /**
   * Process with main thread
   */
  private process(isSilence: boolean): void {

    try {
      
      LogConsumerThreadPool.getInstance().executeLogTask(() => {
        
        try {
          
          this.processQueue(isSilence);
          
        } catch (error) {
          FTInnerLogger.e(TAG, `Error in processQueue call: ${error}`);
        }
      });
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error calling LogConsumerThreadPool.execute: ${error}`);
    }
  }
  
  /**
   * Switch queues atomically (dual queue design)
   * Moves all logs from inputQueue to processingQueue
   * This creates a snapshot of logs to process, allowing processQueue to fully drain
   * while new logs continue to be added to inputQueue without interference
   */
  private switchQueues(): void {
    // Atomically move all logs from inputQueue to processingQueue
    if (this.inputQueue.length > 0) {
      this.processingQueue.push(...this.inputQueue);
      this.inputQueue = [];
      // Removed verbose debug log to reduce log output
    }
  }
  
  /**
   * Process queue (Dual Queue Design)
   * 1. Switch queues atomically at start (inputQueue -> processingQueue)
   * 2. Process all logs from processingQueue (snapshot)
   * 3. Add each log to batch buffer
   * 4. Flush when buffer reaches DEFAULT_BATCH_SIZE or queue is empty
   * 5. Exit when processingQueue is empty (natural exit, no timeout needed)
   */
  private async processQueue(isSilence: boolean): Promise<void> {
    // Switch queues atomically at the start of processing
    // This creates a snapshot of logs to process, allowing us to fully drain processingQueue
    // while new logs continue to be added to inputQueue without interference
    this.switchQueues();
    
    const initialQueueSize = this.processingQueue.length;
    // Removed verbose debug log to reduce log output
    
    try {
      const startTime = Date.now();
      let processedCount = 0;
      
      // Process all logs from processingQueue (snapshot)
      // Since processingQueue is a snapshot, we can fully drain it without worrying about new logs
      while (this.processingQueue.length > 0) {
        const queueSizeBeforePoll = this.processingQueue.length;
        const logBean = this.processingQueue.shift();
        
        if (logBean) {
          processedCount++;
          this.addToBatchBuffer(logBean);
          // Removed verbose debug log to reduce log output
        }
        
        // Check if should flush batch (matching Android's shouldFlushBatch logic)
        // Flush if: buffer >= DEFAULT_BATCH_SIZE OR (queue empty && buffer not empty)
        const shouldFlush = this.shouldFlushBatch(this.processingQueue.length === 0 ? undefined : logBean);
        if (shouldFlush) {
          this.flushBatch(isSilence);
        }
      }
      
      // Flush any remaining buffer when processingQueue is empty
      const shouldFlushRemaining = this.shouldFlushBatch(undefined);
      if (shouldFlushRemaining) {
        this.flushBatch(isSilence);
      }
      
      // Removed verbose debug log to reduce log output
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error processing log queue: ${error}`);
    } finally {
      this.isProcessing = false;
      
      // Check if there are new logs in inputQueue (added during processing)
      // If so, trigger processing again to handle them
      if (this.inputQueue.length > 0) {
        FTInnerLogger.d(TAG, `New logs arrived during processing (${this.inputQueue.length} in inputQueue), triggering next processing`);
        this.triggerProcessing(isSilence);
      }
    }
  }
  
  /**
   * Check if should flush batch
   * Matches Android's shouldFlushBatch logic:
   * - buffer >= DEFAULT_BATCH_SIZE, OR
   * - currentLog == null (queue empty) AND buffer not empty
   */
  private shouldFlushBatch(currentLog: LogBean | undefined): boolean {
    return this.lockBuffer(() => {
      const bufferSize = this.logBatchBuffer.length;
      const shouldFlush = bufferSize >= TrackLogManager.DEFAULT_BATCH_SIZE ||
                          (currentLog === undefined && bufferSize > 0);
      if (shouldFlush) {
        FTInnerLogger.d(TAG, `shouldFlushBatch: true (bufferSize=${bufferSize}, currentLog=${currentLog ? 'exists' : 'null'})`);
      }
      return shouldFlush;
    });
  }
  
  /**
   * Schedule next processing
   */
  private scheduleNextProcessing(isSilence: boolean): void {
    if (this.processingTimer !== null) {
      clearTimeout(this.processingTimer);
    }

    // Use LogConsumerThreadPool.executeLogTask for single-thread execution
    LogConsumerThreadPool.getInstance().executeLogTask(() => {
      this.triggerProcessing(isSilence);
    });
  }
  
  /**
   * Add to batch buffer
   */
  private addToBatchBuffer(logBean: LogBean): void {
    this.lockBuffer(() => {
      this.logBatchBuffer.push(logBean);
    });
  }
  
  
  /**
   * Flush batch
   */
  private flushBatch(isSilence: boolean): void {
    FTInnerLogger.d(TAG, `flushBatch: isSilence=${isSilence}, bufferSize=${this.logBatchBuffer.length}`);
    
    const batchToSend = this.lockBuffer(() => {
      const batch = Array.from(this.logBatchBuffer);
      this.logBatchBuffer = [];
      return batch;
    });
    
    
    
    if (batchToSend.length === 0) {
      return;
    }
    
    FTInnerLogger.d(TAG, `Sending log batch, size: ${batchToSend.length}`);
    
    try {
      FTTrackInner.getInstance().batchLogBeanSync(batchToSend, isSilence);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to send log batch: ${error}`);
    }
  }
  
  /**
   * Buffer lock operation - thread-safe implementation
   * Uses simple mutex pattern for HarmonyOS
   */
  private lockBuffer<T>(operation: () => T): T {
    // Wait for lock to be released
    while (this.bufferLocked) {
      // Simple spin-wait
    }
    
    this.bufferLocked = true;
    try {
      return operation();
    } finally {
      this.bufferLocked = false;
    }
  }
  
  /**
   * Shutdown manager
   */
  public shutdown(): void {
    FTInnerLogger.i(TAG, "Shutting down TrackLogManager");
    
    try {
      if (this.processingTimer !== null) {
        clearTimeout(this.processingTimer);
        this.processingTimer = null;
      }
      
      this.isProcessing = false;
      
      // Clear queues and buffer
      this.inputQueue = [];
      this.processingQueue = [];
      this.lockBuffer(() => {
        this.logBatchBuffer = [];
      });
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error during shutdown: ${error}`);
    }
  }
}

/**
 * Convenient method to get TrackLogManager instance
 */
export function getTrackLogManager(): TrackLogManager {
  return TrackLogManager.getInstance();
}
