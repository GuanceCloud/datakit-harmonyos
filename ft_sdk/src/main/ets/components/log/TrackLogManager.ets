import { LogBean } from '../bean/LogBean';
import FTTrackInner from '../FTTrackInner';
import { FTInnerLogger } from "../log/FTLogger";
import { FTRUMConfigManager } from '../rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../rum/FTRUMInnerManager';
import { StringWrapper } from '../utils/StringWrapper';
import { FTLoggerConfig } from '../Configs';
import { Constants } from '../Constants';
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolContextDTO,
  SDKLogDTO,
  SDKStringRecord,
  SDKSyncDataDraftDTO,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerResponse
} from '../thread/SDKWorkerProtocol';

const TAG = "TrackLogManager";
const LOG_HOST_MAILBOX_BATCH_SIZE = 64;
const LOG_HOST_MAILBOX_BATCH_DELAY_MS = 16;

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

interface LogWorkerBatchPayload {
  batches: SDKLogDTO[][];
  draftBatches?: SDKSyncDataDraftDTO[][];
  batchSilences?: boolean[];
  queueSize: number;
  bufferSize: number;
  coalesceDelayMs: number;
  batchSize: number;
}

interface LogWorkerEnqueueRequestPayload {
  logs: SDKLogDTO[];
  forceFlush: boolean;
  lineContext?: SDKLineProtocolContextDTO;
}

interface LogWorkerFlushRequestPayload {
  lineContext?: SDKLineProtocolContextDTO;
}

/**
 * Log tracking manager - HarmonyOS implementation.
 *
 * Host side keeps only counters and config. LOG data is sent directly into the
 * ThreadWorker mailbox so the UI runtime no longer owns a log FIFO or awaits
 * executeCommand Promise chains.
 */
export class TrackLogManager {
  private static instance: TrackLogManager | null = null;
  private static logWorkerCommandSequence: number = 0;

  private submittedCount: number = 0;
  private acceptedCount: number = 0;
  private droppedCount: number = 0;
  private filteredCount: number = 0;
  private logConfig: FTLoggerConfig | null = null;
  private mailboxHandlerRegistered: boolean = false;
  private pendingLogDTOs: SDKLogDTO[] = [];
  private pendingFlushTimer: number | null = null;

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
    this.submittedCount = 0;
    this.acceptedCount = 0;
    this.droppedCount = 0;
    this.filteredCount = 0;
    this.pendingLogDTOs = [];
    this.clearPendingFlushTimer();
  }

  /**
   * Set log configuration
   * @param config Log configuration
   */
  public setLogConfig(config: FTLoggerConfig): void {
    this.logConfig = config;
    this.ensureMailboxHandler();
    FTInnerLogger.d(TAG,
      `Log config updated: samplingRate=${config.getSamplingRate()}, enableCustomLog=${config.isEnableCustomLog()}`);
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
    this.submittedCount++;
    if (!this.shouldProcessLog(logBean)) {
      this.filteredCount++;
      return;
    }

    this.acceptedCount++;
    this.enqueueLogDTO(this.toLogDTO(logBean, isSilence));
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

    let accepted = 0;
    const batchDTOs: SDKLogDTO[] = [];
    for (let i = 0; i < logBeans.length; i++) {
      this.submittedCount++;
      const logBean = logBeans[i];
      if (!this.shouldProcessLog(logBean)) {
        this.filteredCount++;
        continue;
      }
      accepted++;
      this.acceptedCount++;
      batchDTOs.push(this.toLogDTO(logBean, isSilence));
    }

    if (accepted > 0) {
      this.flushPendingLogDTOs(true);
      this.postLogDTOs(batchDTOs, true);
    }
  }

  /**
   * Get queue status
   */
  public getQueueStatus(): QueueStatus {
    return {
      queueSize: 0,
      bufferSize: this.pendingLogDTOs.length + this.getLogMailboxPending(),
      isProcessing: false,
      submittedCount: this.submittedCount,
      acceptedCount: this.acceptedCount,
      droppedCount: this.droppedCount,
      filteredCount: this.filteredCount
    };
  }

  /**
   * Force flush worker-owned log buffer.
   */
  public forceFlush(_isSilence: boolean = false): void {
    this.ensureMailboxHandler();
    this.flushPendingLogDTOs(true);
    TrackLogManager.logWorkerCommandSequence++;
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.LOG_CONSUMER);
    const flushPayload: LogWorkerFlushRequestPayload = {};

    const posted = SDKDedicatedPoolManager.getInstance().postCommand({
      id: `log.flush.${TrackLogManager.logWorkerCommandSequence}.${Date.now()}`,
      pool: SDKDedicatedPoolType.LOG_CONSUMER,
      command: SDKWorkerCommand.LOG_FLUSH,
      priority: SDKTaskPriority.NORMAL,
      createdAt: Date.now(),
      payload: flushPayload as Object as SDKWorkerPayload
    });
    if (!posted) {
      FTInnerLogger.w(TAG, '<FT-LOG-LANE> LogWorker flush mailbox post failed');
    }
  }

  /**
   * Determine whether log should be processed
   */
  private shouldProcessLog(logBean: LogBean): boolean {
    if (!this.logConfig) {
      FTInnerLogger.w(TAG, "Log config not set, discarding log");
      return false;
    }

    if (!this.logConfig.isEnableCustomLog()) {
      FTInnerLogger.d(TAG, "Custom log disabled, discarding log");
      return false;
    }

    const samplingRate = this.logConfig.getSamplingRate();
    if (samplingRate < 1.0 && Math.random() > samplingRate) {
      return false;
    }

    if (!this.logConfig.checkLogLevel(logBean.getStatus())) {
      return false;
    }

    if (!this.logConfig.checkPrefix(logBean.getContent())) {
      return false;
    }

    if (this.logConfig.isEnableLinkRumData()) {
      try {
        const rumManager = FTRUMConfigManager.getInstance();
        if (rumManager) {
          const rumTags = rumManager.getRUMPublicDynamicTags();
          FTRUMInnerManager.getInstance().attachRUMRelative(rumTags, false);
          const logTags: Record<string, object> = {};
          const allTagKeys = Object.keys(rumTags);
          for (let i = 0; i < allTagKeys.length; i++) {
            const key = allTagKeys[i];
            const value: string = rumTags[key] as string;
            logTags[key] = new StringWrapper(value);
          }
          logBean.appendTags(logTags);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to attach RUM data: ${error}`);
      }
    }

    return true;
  }

  private enqueueLogDTO(logDTO: SDKLogDTO): void {
    this.pendingLogDTOs.push(logDTO);
    if (this.pendingLogDTOs.length >= LOG_HOST_MAILBOX_BATCH_SIZE) {
      this.flushPendingLogDTOs(true);
      return;
    }
    this.schedulePendingFlush();
  }

  private schedulePendingFlush(): void {
    if (this.pendingFlushTimer !== null) {
      return;
    }
    this.pendingFlushTimer = setTimeout(() => {
      this.pendingFlushTimer = null;
      this.flushPendingLogDTOs(true);
    }, LOG_HOST_MAILBOX_BATCH_DELAY_MS) as number;
  }

  private flushPendingLogDTOs(forceFlush: boolean): void {
    this.clearPendingFlushTimer();
    while (this.pendingLogDTOs.length > 0) {
      const batch = this.pendingLogDTOs.splice(0, LOG_HOST_MAILBOX_BATCH_SIZE);
      this.postLogDTOs(batch, forceFlush);
    }
  }

  private clearPendingFlushTimer(): void {
    if (this.pendingFlushTimer !== null) {
      clearTimeout(this.pendingFlushTimer);
      this.pendingFlushTimer = null;
    }
  }

  private postLogDTOs(logDTOs: SDKLogDTO[], forceFlush: boolean): void {
    if (!logDTOs || logDTOs.length === 0) {
      return;
    }
    this.ensureMailboxHandler();
    TrackLogManager.logWorkerCommandSequence++;
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.LOG_CONSUMER);
    const requestPayload: LogWorkerEnqueueRequestPayload = {
      logs: logDTOs,
      forceFlush
    };

    const posted = SDKDedicatedPoolManager.getInstance().postCommand({
      id: `log.enqueue.${TrackLogManager.logWorkerCommandSequence}.${Date.now()}`,
      pool: SDKDedicatedPoolType.LOG_CONSUMER,
      command: SDKWorkerCommand.LOG_ENQUEUE,
      priority: SDKTaskPriority.NORMAL,
      createdAt: Date.now(),
      payload: requestPayload as Object as SDKWorkerPayload
    });
    if (!posted) {
      this.droppedCount += logDTOs.length;
      this.acceptedCount = Math.max(0, this.acceptedCount - logDTOs.length);
      FTInnerLogger.w(TAG, '<FT-LOG-LANE> LogWorker mailbox post failed');
    }
  }

  private handleLogMailboxResponse(response: SDKWorkerResponse): void {
    if (!response || !response.ok || !response.payload) {
      const errorMessage = response ? response.errorMessage || 'empty response' : 'empty response';
      FTInnerLogger.w(TAG, `<FT-LOG-LANE> LogWorker mailbox failed: ${errorMessage}`);
      return;
    }

    const payload = response.payload as Object as LogWorkerBatchPayload;
    const draftBatches = payload.draftBatches || [];
    const batchSilences = payload.batchSilences || [];
    if (draftBatches.length > 0) {
      for (let i = 0; i < draftBatches.length; i++) {
        const draftBatch = draftBatches[i];
        if (draftBatch.length > 0) {
          FTTrackInner.getInstance().writeLogDraftsFromWorker(draftBatch, batchSilences[i] === true);
        }
      }
      return;
    }

    const batches = payload.batches || [];
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      if (batch.length > 0) {
        FTTrackInner.getInstance().batchLogDTOSync(batch, batchSilences[i] === true);
      }
    }
  }

  private getLogMailboxPending(): number {
    const status = SDKDedicatedPoolManager.getInstance().getStatus();
    const pool = status.pools[SDKDedicatedPoolType.LOG_CONSUMER];
    return pool ? pool.mailboxPending : 0;
  }

  private ensureMailboxHandler(): void {
    if (this.mailboxHandlerRegistered) {
      return;
    }
    SDKDedicatedPoolManager.getInstance().setMailboxResponseHandler(
      SDKDedicatedPoolType.LOG_CONSUMER,
      (response: SDKWorkerResponse) => {
        this.handleLogMailboxResponse(response);
      }
    );
    this.mailboxHandlerRegistered = true;
  }

  private toLogDTO(logBean: LogBean, isSilence: boolean): SDKLogDTO {
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
      fields,
      isSilence
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

  /**
   * Shutdown manager
   */
  public shutdown(): void {
    FTInnerLogger.i(TAG, "Shutting down TrackLogManager");
    this.flushPendingLogDTOs(true);
    if (this.mailboxHandlerRegistered) {
      SDKDedicatedPoolManager.getInstance().setMailboxResponseHandler(SDKDedicatedPoolType.LOG_CONSUMER, null);
      this.mailboxHandlerRegistered = false;
    }
  }
}

/**
 * Convenient method to get TrackLogManager instance
 */
export function getTrackLogManager(): TrackLogManager {
  return TrackLogManager.getInstance();
}
