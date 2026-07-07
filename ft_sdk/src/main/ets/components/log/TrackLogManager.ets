import { LogBean } from '../bean/LogBean';
import { BaseContentBean } from '../bean/BaseContentBean';
import { FTDBCachePolicy } from '../db/FTDBCachePolicy';
import FTTrackInner from '../FTTrackInner';
import { FTInnerLogger } from "../log/FTLogger";
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { StringWrapper } from '../utils/StringWrapper';
import { FTLoggerConfig } from '../Configs';
import { Constants } from '../Constants';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import {
  SDKTaskPriority,
  SDKTaskScheduler,
  SDKTaskType
} from '../thread/SDKTaskScheduler';
import {
  createSDKWorkerTaskBridgeHandler,
  createSDKWorkerTaskFallbackRunner,
  createSDKWorkerTaskRequest
} from '../thread/SDKWorkerTaskBridge';
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLogDTO,
  SDKStringRecord,
  SDKWorkerCommand,
  SDKWorkerPayload
} from '../thread/SDKWorkerProtocol';

const TAG = "TrackLogManager";

/**
 * Queue status interface
 */
export interface QueueStatus {
  queueSize: number;
  bufferSize: number;
  isProcessing: boolean;
  submittedCount: number;
  acceptedCount: number;
  droppedCount: number;
  filteredCount: number;
}

/**
 * Worker message interface
 */
interface WorkerMessage {
  type: string;
  batchSize?: number;
  isSilence?: boolean;
}

interface LogProcessSummary {
  drainedCount: number;
  flushedCount: number;
  batchSizes: string[];
  newInputCount: number;
  needNext: boolean;
}

interface LogWorkerBatchPayload {
  batches: SDKLogDTO[][];
  queueSize: number;
  bufferSize: number;
  coalesceDelayMs: number;
  batchSize: number;
}

interface LogWorkerEnqueueRequestPayload {
  logs: SDKLogDTO[];
  forceFlush: boolean;
}

/**
 * Log tracking manager - HarmonyOS implementation
 * Responsible for managing log queues, batch processing and async processing
 */
export class TrackLogManager {
  private static instance: TrackLogManager | null = null;
  
  // Configuration constants
  private static readonly DEFAULT_BATCH_SIZE = 20; // Match Android's value
  private static readonly LOG_PROCESS_COALESCE_DELAY_MS = 100;
  private static readonly LOG_SERIAL_KEY = "log-consumer-state";
  private static logTaskSequence: number = 0;
  private static logWorkerCommandSequence: number = 0;
  
  // Core components - Dual Queue Design
  // inputQueue: Receives new logs from producers (trackLog calls)
  // processingQueue: Used by processQueue to consume logs
  // This design prevents infinite loops by allowing processQueue to fully drain processingQueue
  // while new logs continue to be added to inputQueue without interference
  private inputQueue: LogBean[] = [];
  private processingQueue: LogBean[] = [];
  private logBatchBuffer: BaseContentBean[] = [];
  private isProcessing: boolean = false;
  private processScheduleTimer: number = -1;
  private scheduledIsSilence: boolean = true;
  private hasScheduledIsSilence: boolean = false;
  private bufferLocked: boolean = false;
  private submittedCount: number = 0;
  private acceptedCount: number = 0;
  private droppedCount: number = 0;
  private filteredCount: number = 0;
  
  // Log configuration
  private logConfig: FTLoggerConfig | null = null;
  
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
    this.submittedCount = 0;
    this.acceptedCount = 0;
    this.droppedCount = 0;
    this.filteredCount = 0;
  }
  
  /**
   * Set log configuration
   * @param config Log configuration
   */
  public setLogConfig(config: FTLoggerConfig): void {
    this.logConfig = config;
    FTInnerLogger.d(TAG, `Log config updated: samplingRate=${config.getSamplingRate()}, enableCustomLog=${config.isEnableCustomLog()}`);

    // If there are logs in queue and processing is not active, submit the LOG lane consumer.
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
    this.submittedCount++;
    if (!this.shouldProcessLog(logBean)) {
      this.filteredCount++;
      return;
    }
    
    
    
    // Queue size limit (check inputQueue only, as processingQueue is being processed)
    const cachePolicy = FTDBCachePolicy.getInstance();
    const maxSize = Math.min(cachePolicy.getLogLimitCount(), Constants.MAX_QUEUE_SIZE_LOG);
    
    
    
    if (this.inputQueue.length >= maxSize) {
      // Use default strategy: discard oldest log
      this.inputQueue.shift(); // Remove oldest log
      this.droppedCount++;
      FTInnerLogger.w(TAG, 'Input queue full, discarding oldest log');
    }
    
    this.inputQueue.push(logBean);
    this.acceptedCount++;
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

    const cachePolicy = FTDBCachePolicy.getInstance();
    const maxSize = Math.min(cachePolicy.getLogLimitCount(), Constants.MAX_QUEUE_SIZE_LOG);

    let acceptedCount = 0;
    for (const logBean of logBeans) {
      this.submittedCount++;
      if (!this.shouldProcessLog(logBean)) {
        this.filteredCount++;
        continue;
      }

      if (this.inputQueue.length >= maxSize) {
        this.inputQueue.shift();
        this.droppedCount++;
        FTInnerLogger.w(TAG, 'Input queue full, discarding oldest log');
      }

      this.inputQueue.push(logBean);
      acceptedCount++;
      this.acceptedCount++;
    }

    if (acceptedCount > 0) {
      this.triggerProcessing(isSilence);
    }

    FTInnerLogger.d(TAG, `Batch logged: accepted=${acceptedCount}, requested=${logBeans.length}`);
  }
  
  /**
   * Get queue status
   */
  public getQueueStatus(): QueueStatus {
    // Return total queue size (inputQueue + processingQueue)
    return {
      queueSize: this.inputQueue.length + this.processingQueue.length,
      bufferSize: this.logBatchBuffer.length,
      isProcessing: this.isProcessing,
      submittedCount: this.submittedCount,
      acceptedCount: this.acceptedCount,
      droppedCount: this.droppedCount,
      filteredCount: this.filteredCount
    };
  }
  
  /**
   * Force flush buffer
   */
  public forceFlush(isSilence: boolean = false): void {
    FTInnerLogger.d(TAG, "Force flushing log buffer");
    const totalQueueSize = this.inputQueue.length + this.processingQueue.length;
    if (totalQueueSize > 0 && !this.isProcessing) {
      this.mergeScheduledSilence(isSilence);
      this.startProcessingNow(isSilence);
      return;
    }

    this.clearProcessingSchedule();
    this.submitLogTask('log.forceFlush', (traceName: string) => {
      const flushedCount = this.flushBatch(isSilence);
      this.traceLogLane(
        `[CONSUMED] name=${traceName} flushed=${flushedCount} batches=${flushedCount > 0 ? String(flushedCount) : '0'} newInput=${this.inputQueue.length} next=false`
      );
    });
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
    this.mergeScheduledSilence(isSilence);

    if (this.isProcessing) {
      return;
    }

    if (this.shouldProcessImmediately()) {
      this.startProcessingNow(isSilence);
      return;
    }

    this.scheduleProcessing();
  }

  private shouldProcessImmediately(): boolean {
    return this.inputQueue.length + this.processingQueue.length >= TrackLogManager.DEFAULT_BATCH_SIZE;
  }

  private scheduleProcessing(): void {
    if (this.processScheduleTimer >= 0) {
      return;
    }

    this.processScheduleTimer = setTimeout(() => {
      this.processScheduleTimer = -1;
      if (this.isProcessing) {
        return;
      }

      const totalQueueSize = this.inputQueue.length + this.processingQueue.length;
      if (totalQueueSize <= 0) {
        this.resetScheduledSilence();
        return;
      }

      const scheduledIsSilence = this.consumeScheduledSilence(false);
      this.isProcessing = true;
      this.process(scheduledIsSilence);
    }, TrackLogManager.LOG_PROCESS_COALESCE_DELAY_MS);
  }

  private startProcessingNow(fallbackIsSilence: boolean): void {
    this.clearProcessingSchedule();
    if (this.isProcessing) {
      return;
    }

    const scheduledIsSilence = this.consumeScheduledSilence(fallbackIsSilence);
    this.isProcessing = true;
    this.process(scheduledIsSilence);
  }

  private clearProcessingSchedule(): void {
    if (this.processScheduleTimer >= 0) {
      clearTimeout(this.processScheduleTimer);
      this.processScheduleTimer = -1;
    }
  }

  private mergeScheduledSilence(isSilence: boolean): void {
    if (!this.hasScheduledIsSilence) {
      this.scheduledIsSilence = isSilence;
      this.hasScheduledIsSilence = true;
      return;
    }

    this.scheduledIsSilence = this.scheduledIsSilence && isSilence;
  }

  private consumeScheduledSilence(fallbackIsSilence: boolean): boolean {
    const isSilence = this.hasScheduledIsSilence ? this.scheduledIsSilence : fallbackIsSilence;
    this.resetScheduledSilence();
    return isSilence;
  }

  private resetScheduledSilence(): void {
    this.scheduledIsSilence = true;
    this.hasScheduledIsSilence = false;
  }

  private submitLogTask(name: string, task: (traceName: string) => void | Promise<void>): boolean {
    const traceName = this.nextLogTaskName(name);
    try {
      const command = SDKWorkerCommand.LOG_RUN;
      const runTask = async () => {
        await this.runLogTaskSafely(traceName, task);
      };
      this.traceLogLane(`[ENQUEUE] name=${traceName} input=${this.inputQueue.length} processing=${this.processingQueue.length} buffer=${this.logBatchBuffer.length}`);
      SDKTaskScheduler.getInstance().submitTask({
        type: SDKTaskType.LOG,
        name: traceName,
        priority: SDKTaskPriority.NORMAL,
        serialKey: TrackLogManager.LOG_SERIAL_KEY,
        costHint: 'normal',
        workerRequest: createSDKWorkerTaskRequest(
          SDKDedicatedPoolType.LOG_CONSUMER,
          command,
          traceName,
          SDKTaskPriority.NORMAL
        ),
        workerFallbackRunner: createSDKWorkerTaskFallbackRunner(traceName, command, runTask),
        workerBridgeHandler: createSDKWorkerTaskBridgeHandler(traceName, command, runTask)
      });
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-LOG-LANE> Failed to submit log task: name=${traceName}, error=${error}`);
      return false;
    }
  }

  private async runLogTaskSafely(traceName: string, task: (traceName: string) => void | Promise<void>): Promise<void> {
    try {
      await Promise.resolve(task(traceName));
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-LOG-LANE> Log task failed: name=${traceName}, error=${error}`);
    }
  }

  private nextLogTaskName(name: string): string {
    TrackLogManager.logTaskSequence++;
    return `${name}#${TrackLogManager.logTaskSequence}`;
  }

  private traceLogLane(message: string): void {
    FTInnerLogger.i(TAG, `<FT-LOG-LANE> ${message}`);
  }
  

  /**
   * Process through SDKTaskScheduler LOG lane.
   */
  private process(isSilence: boolean): void {

    try {
      const submitted = this.submitLogTask('log.processQueue', async (traceName: string) => {
        const startTime = Date.now();
        const summary = await this.processQueue(isSilence);
        const costTime = Math.max(0, Date.now() - startTime);
        this.traceLogLane(
          `[CONSUMED] name=${traceName} drained=${summary.drainedCount} flushed=${summary.flushedCount} batches=${this.formatBatchSizes(summary.batchSizes)} newInput=${summary.newInputCount} next=${summary.needNext} cost=${costTime}ms`
        );
        if (summary.needNext) {
          this.triggerProcessing(isSilence);
        }
      });
      if (!submitted) {
        this.isProcessing = false;
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error submitting log lane task: ${error}`);
      this.isProcessing = false;
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
  private async processQueue(isSilence: boolean): Promise<LogProcessSummary> {
    // Switch queues atomically at the start of processing
    // This creates a snapshot of logs to process, allowing us to fully drain processingQueue
    // while new logs continue to be added to inputQueue without interference
    this.switchQueues();
    
    const summary: LogProcessSummary = {
      drainedCount: 0,
      flushedCount: 0,
      batchSizes: [],
      newInputCount: 0,
      needNext: false
    };
    
    try {
      const logs = this.drainProcessingQueue();
      summary.drainedCount = logs.length;
      if (logs.length > 0) {
        await this.processLogsWithWorker(logs, isSilence, summary);
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error processing log queue: ${error}`);
    } finally {
      this.isProcessing = false;
      summary.newInputCount = this.inputQueue.length;
      summary.needNext = summary.newInputCount > 0;
      
      return summary;
    }
  }

  private drainProcessingQueue(): LogBean[] {
    const logs: LogBean[] = [];
    while (this.processingQueue.length > 0) {
      const logBean = this.processingQueue.shift();
      if (logBean) {
        logs.push(logBean);
      }
    }
    return logs;
  }

  private async processLogsWithWorker(
    logs: LogBean[],
    isSilence: boolean,
    summary: LogProcessSummary
  ): Promise<void> {
    const logDTOs: SDKLogDTO[] = [];
    for (let i = 0; i < logs.length; i++) {
      logDTOs.push(this.toLogDTO(logs[i]));
    }

    try {
      TrackLogManager.logWorkerCommandSequence++;
      const requestPayload: LogWorkerEnqueueRequestPayload = {
        logs: logDTOs,
        forceFlush: true
      };

      const response = await SDKDedicatedPoolManager.getInstance().executeCommand({
        id: `log.enqueue.${TrackLogManager.logWorkerCommandSequence}.${Date.now()}`,
        pool: SDKDedicatedPoolType.LOG_CONSUMER,
        command: SDKWorkerCommand.LOG_ENQUEUE,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: requestPayload as Object as SDKWorkerPayload
      });

      if (response.ok && response.payload) {
        const payload = response.payload as Object as LogWorkerBatchPayload;
        const batches = payload.batches || [];
        for (let i = 0; i < batches.length; i++) {
          const batch = batches[i];
          if (batch.length > 0) {
            FTTrackInner.getInstance().batchLogDTOSync(batch, isSilence);
            this.recordFlushSummary(summary, batch.length);
          }
        }
        return;
      }

      FTInnerLogger.w(TAG, `<FT-LOG-LANE> LogWorker failed, fallback to host batch: ${response.errorMessage || 'empty response'}`);
    } catch (error) {
      FTInnerLogger.w(TAG, `<FT-LOG-LANE> LogWorker error, fallback to host batch: ${error}`);
    }

    this.flushLogBeansInHost(logs, isSilence, summary);
  }

  private flushLogBeansInHost(logs: LogBean[], isSilence: boolean, summary: LogProcessSummary): void {
    let index = 0;
    while (index < logs.length) {
      const batch: BaseContentBean[] = [];
      while (index < logs.length && batch.length < TrackLogManager.DEFAULT_BATCH_SIZE) {
        batch.push(logs[index]);
        index++;
      }
      if (batch.length > 0) {
        FTTrackInner.getInstance().batchLogBeanSync(batch, isSilence);
        this.recordFlushSummary(summary, batch.length);
      }
    }
  }

  private toLogDTO(logBean: LogBean): SDKLogDTO {
    const tags = this.objectRecordToStringRecord(logBean.getAllTags());
    const fields = this.objectRecordToStringRecord(logBean.getAllFields());
    fields[Constants.KEY_MESSAGE] = logBean.getContent();
    return {
      measurement: logBean.getMeasurement() || Constants.FT_LOG_DEFAULT_MEASUREMENT,
      content: logBean.getContent(),
      status: logBean.getStatus(),
      time: logBean.getTime(),
      timeNano: logBean.getTimeNano(),
      tags,
      fields
    };
  }

  private objectRecordToStringRecord(record: Record<string, object>): SDKStringRecord {
    const result: SDKStringRecord = {};
    if (!record) {
      return result;
    }
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      result[key] = this.objectValueToString(record[key]);
    }
    return result;
  }

  private objectValueToString(value: object | string | number | boolean | null | undefined): string {
    if (value === null || value === undefined) {
      return '';
    }
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    const valueRecord = value as Record<string, object>;
    if (valueRecord && valueRecord['value'] !== undefined) {
      return String(valueRecord['value']);
    }
    try {
      return JSON.stringify(value);
    } catch (_) {
      return String(value);
    }
  }

  private recordFlushSummary(summary: LogProcessSummary, flushedCount: number): void {
    if (flushedCount <= 0) {
      return;
    }
    summary.flushedCount += flushedCount;
    summary.batchSizes.push(String(flushedCount));
  }

  private formatBatchSizes(batchSizes: string[]): string {
    if (batchSizes.length === 0) {
      return '0';
    }
    return batchSizes.join('+');
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
  private flushBatch(isSilence: boolean): number {
    FTInnerLogger.d(TAG, `flushBatch: isSilence=${isSilence}, bufferSize=${this.logBatchBuffer.length}`);
    
    const batchToSend = this.lockBuffer(() => {
      const batch = Array.from(this.logBatchBuffer);
      this.logBatchBuffer = [];
      return batch;
    });
    
    
    
    if (batchToSend.length === 0) {
      return 0;
    }
    
    FTInnerLogger.d(TAG, `Sending log batch, size: ${batchToSend.length}`);
    
    try {
      FTTrackInner.getInstance().batchLogBeanSync(batchToSend, isSilence);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to send log batch: ${error}`);
    }
    return batchToSend.length;
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
      this.clearProcessingSchedule();
      this.resetScheduledSilence();
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
