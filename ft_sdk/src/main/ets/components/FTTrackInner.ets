import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, LogGlobalContextDictionary, LogGlobalContextValue } from './Configs';
import { DataType } from './enum/Enums';
import { CollectType } from './rum/enum/RUMEnums';
import { FTInnerLogger } from './log/FTLogger';
import { SyncData } from './db/bean/SyncData';
import { TrackLogManager } from './log/TrackLogManager';
import { LogBean } from './bean/LogBean';
import { BaseContentBean } from './bean/BaseContentBean';
import { Context } from '@kit.AbilityKit';
import { RunnerCompleteCallBack } from './rum/callback/RunnerCompleteCallBack';
import { Constants } from './Constants';
import { PreparedLineProtocolContent, SyncDataHelper } from './SyncDataHelper';
import { SyncTaskManager } from './SyncTaskManager';
import { FTHiLogInterceptor } from './log/FTHiLogInterceptor';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import { SDKDedicatedPoolManager } from './thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolContextDTO,
  SDKLineProtocolInputDTO,
  SDKLogDTO,
  SDKRumCounterDeltaDTO,
  SDKRumEventBatchDTO,
  SDKRumEventDTO,
  SDKStringRecord,
  SDKSyncDataDraftDTO,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from './thread/SDKWorkerProtocol';
import { Utils } from './utils/Utils';
import { FTDBManager, SyncDataWriteResult } from './db/FTDBManager';
import { FTDBCachePolicy } from './db/FTDBCachePolicy';
import { FTDBTaskPoolSyncDraftDTO } from './db/FTDBTaskPoolExecutor';
// SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
// import { FTSessionReplayManager, SessionReplayConfig } from '@ft/session-replay-harmonyos';

const TAG = "FTTrackInner";
const RUM_WORKER_EVENT_BATCH_SIZE = 64;
const RUM_WORKER_EVENT_BATCH_DELAY_MS = 16;

enum WriteCacheCategory {
  LOG = 'log',
  RUM = 'rum',
  NONE = 'none',
  MIXED = 'mixed'
}

/**
 * Sync Data Parameters Interface
 */
interface SyncDataParams {
  measurement: string;
  tags: Map<string, string>;
  fields: Map<string, string>;
  time: number;
}

interface FTTrackValueAccessor {
  getValue(): string;
}

interface SDKLineProtocolDraftsResponsePayload {
  drafts: SDKSyncDataDraftDTO[];
}

interface SDKRumCommandResponsePayload {
  syncDrafts?: SDKSyncDataDraftDTO[];
  deltas?: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck?: boolean;
  needsRumDataGenerate?: boolean;
}

interface SDKLineProtocolRecordsRequestPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SyncDataCachePolicyDecision {
  records: SyncData[];
  dropped: number;
  deletedOld: number;
  reservedLog: number;
  reservedRum: number;
  useDatabaseCachePolicy: boolean;
}

interface SyncDataCacheCountSummary {
  log: number;
  rum: number;
}

interface PendingRumWorkerCallback {
  source: string;
  dataType: DataType;
  customDataType?: string;
  measurement: string;
  callBack: RunnerCompleteCallBack | null;
  callbackOnFinish: boolean;
}

interface PendingRumWorkerEventCommand {
  source: string;
  dataType: DataType;
  customDataType?: string;
  measurement: string;
  rumEvent: SDKRumEventDTO;
}

interface SDKWorkerDrainBarrierPayload {
  probe: boolean;
  source: string;
}

interface RumDraftWriteLogGroup {
  measurement: string;
  dataType: string;
  count: number;
}

/**
 * Data Tracking Core Class
 * Responsible for data collection, storage, and sync triggering
 */
class FTTrackInner {
  private static instance: FTTrackInner | null = null;
  private static rumWorkerTaskSequence: number = 0;
  private static lineContextCommandSequence: number = 0;
  private static workerDrainBarrierSequence: number = 0;
  private dataHelper: SyncDataHelper;
  private syncTaskManager: SyncTaskManager;
  private trackLogManager: TrackLogManager;
  private pendingRumWorkerCallbacks: Map<string, PendingRumWorkerCallback> = new Map();
  private pendingRumWorkerEvents: PendingRumWorkerEventCommand[] = [];
  private rumWorkerEventFlushTimer: number | null = null;
  private workerLineProtocolContextSnapshot: SDKLineProtocolContextDTO | null = null;
  private workerLineProtocolContextVersion: number = 0;
  private syncedLineContextVersionByPool: Map<SDKDedicatedPoolType, number> = new Map();
  private syncedLineContextRestartByPool: Map<SDKDedicatedPoolType, number> = new Map();
  private pendingWorkerDbWriteCount: number = 0;
  // SessionReplay functionality has been migrated to independent library
  // private sessionReplayManager: FTSessionReplayManager;
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;

  /**
   * Get all keys of an object (alternative to for...in loop)
   * @param obj Object
   * @returns Array of keys
   */
  private static getObjectKeys(obj: Record<string, object>): string[] {
    const keys: string[] = [];
    // Use Object.keys instead of for...in loop, directly iterate through all keys
    const objKeys = Object.keys(obj);
    for (let i = 0; i < objKeys.length; i++) {
      keys.push(objKeys[i]);
    }
    return keys;
  }

  private constructor() {
    this.dataHelper = new SyncDataHelper();
    this.syncTaskManager = SyncTaskManager.getInstance();
    this.trackLogManager = TrackLogManager.getInstance();
    // SessionReplay functionality has been migrated to independent library
    // this.sessionReplayManager = FTSessionReplayManager.getInstance();

    // Debug log for SyncTaskManager initialization
  }

  public static getInstance(): FTTrackInner {
    if (FTTrackInner.instance === null) {
      FTTrackInner.instance = new FTTrackInner();
      FTInnerLogger.d(TAG, `FTTrackInner new instance created`);
    }
    return FTTrackInner.instance;
  }

  public static resetInstanceInternal(): void {
    FTTrackInner.instance = null;
  }

  private submitRumWorkerDraftTask(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean,
    draftUuid?: string
  ): void {
    try {
      const uuid = draftUuid && draftUuid.length > 0 ? draftUuid : this.createRumSyncDataUuid(measurement, tags);
      const lineContext = dataType === DataType.RUM_APP ? this.getWorkerLineProtocolContextSnapshot() : null;
      const contextSynced = lineContext !== null ?
        this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER) : false;
      const rumEvent = lineContext === null ?
        this.createPreparedRumWorkerEventDTO(dataType, customDataType, measurement, tags, fields, time, uuid) :
        this.createRawRumWorkerEventDTO(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          uuid,
          lineContext,
          !contextSynced
        );
      this.postRumWorkerDraftEvent(
        source,
        dataType,
        customDataType,
        measurement,
        rumEvent,
        callBack,
        callbackOnFinish
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling RUM worker draft task: ${error}`);
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
    }
  }

  private submitRumWorkerDraftRecordTask(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    time: number,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean,
    draftUuid?: string
  ): void {
    try {
      const uuid = draftUuid && draftUuid.length > 0 ? draftUuid : this.createRumSyncDataUuidFromRecord(measurement, tags);
      const lineContext = dataType === DataType.RUM_APP ? this.getWorkerLineProtocolContextSnapshot() : null;
      const contextSynced = lineContext !== null ?
        this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER) : false;
      const rumEvent = lineContext === null ?
        this.createPreparedRumWorkerEventDTOFromRecords(dataType, customDataType, measurement, tags, fields, time, uuid) :
        this.createRawRumWorkerEventDTOFromRecords(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          uuid,
          lineContext,
          !contextSynced
        );
      this.postRumWorkerDraftEvent(
        source,
        dataType,
        customDataType,
        measurement,
        rumEvent,
        callBack,
        callbackOnFinish
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling RUM worker record draft task: ${error}`);
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
    }
  }

  private postRumWorkerDraftEvent(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    rumEvent: SDKRumEventDTO,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): void {
    if (!callBack && !callbackOnFinish) {
      this.enqueueRumWorkerDraftEvent(source, dataType, customDataType, measurement, rumEvent);
      return;
    }
    if (this.pendingRumWorkerEvents.length > 0) {
      this.flushRumWorkerEventBatch('rum.beforeCallback');
    }

    const traceName = this.nextRumWorkerTaskName(source);
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_COMMAND}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COMMAND,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: rumEvent as Object as SDKWorkerPayload
    };

    if (callBack || callbackOnFinish) {
      this.pendingRumWorkerCallbacks.set(workerRequest.id, {
        source,
        dataType,
        customDataType,
        measurement,
        callBack,
        callbackOnFinish
      });
    }
    const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
    if (!posted) {
      this.pendingRumWorkerCallbacks.delete(workerRequest.id);
      FTInnerLogger.e(TAG, `RUM worker mailbox post failed: ${traceName}`);
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
    }
  }

  private enqueueRumWorkerDraftEvent(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    rumEvent: SDKRumEventDTO
  ): void {
    this.pendingRumWorkerEvents.push({
      source,
      dataType,
      customDataType,
      measurement,
      rumEvent
    });
    if (this.pendingRumWorkerEvents.length >= RUM_WORKER_EVENT_BATCH_SIZE) {
      this.flushRumWorkerEventBatch(source);
      return;
    }
    this.scheduleRumWorkerEventBatchFlush(source);
  }

  private scheduleRumWorkerEventBatchFlush(source: string): void {
    if (this.rumWorkerEventFlushTimer !== null) {
      return;
    }
    this.rumWorkerEventFlushTimer = setTimeout(() => {
      this.rumWorkerEventFlushTimer = null;
      this.flushRumWorkerEventBatch(source);
    }, RUM_WORKER_EVENT_BATCH_DELAY_MS) as number;
  }

  private flushRumWorkerEventBatch(source: string = 'rum.worker.batch'): void {
    if (this.rumWorkerEventFlushTimer !== null) {
      clearTimeout(this.rumWorkerEventFlushTimer);
      this.rumWorkerEventFlushTimer = null;
    }
    if (this.pendingRumWorkerEvents.length === 0) {
      return;
    }

    const batchSize = Math.min(RUM_WORKER_EVENT_BATCH_SIZE, this.pendingRumWorkerEvents.length);
    const batch = this.pendingRumWorkerEvents.splice(0, batchSize);
    const events: SDKRumEventDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      events.push(batch[i].rumEvent);
    }

    const traceName = this.nextRumWorkerTaskName(`${source}.batch`);
    const payload: SDKRumEventBatchDTO = {
      events
    };
    const posted = SDKDedicatedPoolManager.getInstance().postCommand({
      id: `${SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    });
    if (!posted) {
      FTInnerLogger.e(TAG, `RUM worker mailbox batch post failed: size=${batch.length}`);
    }
    if (this.pendingRumWorkerEvents.length > 0) {
      this.scheduleRumWorkerEventBatchFlush(source);
    }
  }

  public async flushPendingWorkerDataBeforeUpload(timeoutMs: number = 10000): Promise<void> {
    this.flushAllRumWorkerEventBatches('upload.beforeQuery');
    FTRUMInnerManager.getInstance().flushPendingWorkerCommandsBeforeUpload();
    this.trackLogManager.forceFlush(false);
    await this.waitForWorkerMailboxBarriers('upload.beforeQuery', timeoutMs);
    await this.waitForWorkerMailboxAndDbWrites(timeoutMs);
    FTInnerLogger.d(TAG, `flush pending worker data drained before upload: timeoutMs=${timeoutMs}`);
  }

  private flushAllRumWorkerEventBatches(source: string): void {
    while (this.pendingRumWorkerEvents.length > 0) {
      this.flushRumWorkerEventBatch(source);
    }
  }

  private async waitForWorkerMailboxAndDbWrites(timeoutMs: number): Promise<void> {
    const startTime = Date.now();
    while (Date.now() - startTime <= timeoutMs) {
      if (this.isWorkerMailboxAndDbWriteDrained()) {
        return;
      }
      await this.sleep(16);
    }

    const status = SDKDedicatedPoolManager.getInstance().getStatus();
    const eventStatus = status.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
    const logStatus = status.pools[SDKDedicatedPoolType.LOG_CONSUMER];
    FTInnerLogger.w(TAG,
      `flush pending worker data timeout: eventMailbox=${eventStatus ? eventStatus.mailboxPending : 0}, ` +
        `logMailbox=${logStatus ? logStatus.mailboxPending : 0}, dbWrites=${this.pendingWorkerDbWriteCount}`);
  }

  private async waitForWorkerMailboxBarriers(source: string, timeoutMs: number): Promise<void> {
    await this.waitForWorkerMailboxBarrier(SDKDedicatedPoolType.EVENT_CONSUMER, source, timeoutMs);
    await this.waitForWorkerMailboxBarrier(SDKDedicatedPoolType.LOG_CONSUMER, source, timeoutMs);
  }

  private async waitForWorkerMailboxBarrier(
    pool: SDKDedicatedPoolType,
    source: string,
    timeoutMs: number
  ): Promise<void> {
    FTTrackInner.workerDrainBarrierSequence++;
    const requestId =
      `${SDKWorkerCommand.PING}:drain.${pool}.${source}.${Date.now()}.${FTTrackInner.workerDrainBarrierSequence}`;
    try {
      const payload: SDKWorkerDrainBarrierPayload = {
        probe: true,
        source
      };
      const response = await SDKDedicatedPoolManager.getInstance().postCommandAndWait({
        id: requestId,
        pool,
        command: SDKWorkerCommand.PING,
        priority: SDKTaskPriority.LOW,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      }, timeoutMs);
      if (!response.ok) {
        FTInnerLogger.w(TAG,
          `worker mailbox drain barrier failed: pool=${pool}, source=${source}, error=${response.errorMessage || 'unknown'}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.w(TAG, `worker mailbox drain barrier timeout: pool=${pool}, source=${source}, error=${errorMessage}`);
    }
  }

  private isWorkerMailboxAndDbWriteDrained(): boolean {
    const status = SDKDedicatedPoolManager.getInstance().getStatus();
    const eventStatus = status.pools[SDKDedicatedPoolType.EVENT_CONSUMER];
    const logStatus = status.pools[SDKDedicatedPoolType.LOG_CONSUMER];
    const eventPending = eventStatus ? eventStatus.mailboxPending : 0;
    const logPending = logStatus ? logStatus.mailboxPending : 0;
    return eventPending === 0 && logPending === 0 && this.pendingWorkerDbWriteCount === 0;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private nextRumWorkerTaskName(name: string): string {
    FTTrackInner.rumWorkerTaskSequence++;
    return `${name}#${FTTrackInner.rumWorkerTaskSequence}`;
  }

  private createPreparedRumWorkerEventDTO(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    time: number,
    uuid: string
  ): SDKRumEventDTO {
    const prepared = this.dataHelper.prepareLineProtocolContent(measurement, tags, fields, time, dataType, uuid);
    const event = this.createRumWorkerEventFromRecords(
      dataType,
      customDataType,
      prepared.measurement,
      prepared.tags as SDKStringRecord,
      prepared.fields as SDKStringRecord,
      prepared.time,
      uuid,
      prepared.integerCompatible
    );
    event.lineProtocolPrepared = true;
    return event;
  }

  private createPreparedRumWorkerEventDTOFromRecords(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    time: number,
    uuid: string
  ): SDKRumEventDTO {
    const prepared = this.dataHelper.prepareLineProtocolContent(
      measurement,
      this.stringRecordToMap(tags),
      this.stringRecordToMap(fields),
      time,
      dataType,
      uuid
    );
    const event = this.createRumWorkerEventFromRecords(
      dataType,
      customDataType,
      prepared.measurement,
      prepared.tags as SDKStringRecord,
      prepared.fields as SDKStringRecord,
      prepared.time,
      uuid,
      prepared.integerCompatible
    );
    event.lineProtocolPrepared = true;
    return event;
  }

  private createRawRumWorkerEventDTO(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    time: number,
    uuid: string,
    lineContext: SDKLineProtocolContextDTO,
    attachLineContext: boolean
  ): SDKRumEventDTO {
    const tagRecord = this.mapToStringRecord(tags);
    const fieldRecord = this.mapToStringRecord(fields);
    return this.createRawRumWorkerEventDTOFromRecords(
      dataType,
      customDataType,
      measurement,
      tagRecord,
      fieldRecord,
      time,
      uuid,
      lineContext,
      attachLineContext
    );
  }

  private createRawRumWorkerEventDTOFromRecords(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    time: number,
    uuid: string,
    lineContext: SDKLineProtocolContextDTO,
    attachLineContext: boolean
  ): SDKRumEventDTO {
    const event = this.createRumWorkerEventFromRecords(
      dataType,
      customDataType,
      measurement,
      tags,
      fields,
      time,
      uuid,
      lineContext.integerCompatible === true
    );
    if (attachLineContext) {
      event.lineContext = lineContext;
    }
    return event;
  }

  private createRumWorkerEventFromRecords(
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    time: number,
    uuid: string,
    integerCompatible: boolean
  ): SDKRumEventDTO {
    return {
      eventType: this.resolveRumWorkerEventType(measurement, fields),
      name: this.resolveRumWorkerEventName(measurement, tags, fields),
      time,
      dataType: dataType.toString(),
      customDataType,
      measurement,
      uuid,
      integerCompatible,
      viewId: this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_ID),
      viewName: this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_NAME),
      actionId: this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_ID),
      actionName: this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_NAME),
      resourceId: this.resolveRumWorkerResourceId(tags),
      sessionId: this.readStringRecordValue(tags, Constants.KEY_RUM_SESSION_ID),
      tags,
      fields
    };
  }

  private mapToStringRecord(map: Map<string, string>): SDKStringRecord {
    const record: SDKStringRecord = {};
    if (!map) {
      return record;
    }
    map.forEach((value, key) => {
      if (value !== null && value !== undefined) {
        record[key] = String(value);
      }
    });
    return record;
  }

  private handleEventMailboxResponse(response: SDKWorkerResponse): void {
    if (this.isRumCounterMailboxResponse(response)) {
      FTRUMInnerManager.getInstance().handleRumCounterMailboxResponse(response);
      return;
    }

    const callback = this.pendingRumWorkerCallbacks.get(response.id);
    if (callback) {
      this.pendingRumWorkerCallbacks.delete(response.id);
    }

    if (!response.ok) {
      FTInnerLogger.e(TAG, `EVENT mailbox command failed: id=${response.id}, error=${response.errorMessage || 'unknown'}`);
      this.completeRumWorkerCallback(callback, false);
      return;
    }
    if (!response.payload) {
      this.completeRumWorkerCallback(callback, false);
      return;
    }

    const payload = response.payload as Object as SDKRumCommandResponsePayload;
    if (payload.deltas && payload.deltas.length > 0) {
      FTRUMInnerManager.getInstance().handleRumCounterDeltas(
        payload.deltas,
        payload.needsActionCloseCheck,
        payload.needsRumDataGenerate
      );
    }
    const drafts = payload.syncDrafts || [];
    if (drafts.length === 0) {
      this.completeRumWorkerCallback(callback, true);
      return;
    }

    const source = callback ? callback.source : 'event.mailbox.rumWorkerDraft';
    const fallbackDataType = callback ? callback.dataType : this.resolveFallbackDataTypeFromDrafts(drafts);
    this.pendingWorkerDbWriteCount++;
    this.handleRumDraftWrite(
      source,
      fallbackDataType,
      callback ? callback.customDataType : undefined,
      callback ? callback.measurement : 'event.mailbox',
      drafts,
      callback ? callback.callBack : null,
      callback ? callback.callbackOnFinish : false
    ).then(() => {
      this.pendingWorkerDbWriteCount = Math.max(0, this.pendingWorkerDbWriteCount - 1);
    }).catch((error: Error) => {
      this.pendingWorkerDbWriteCount = Math.max(0, this.pendingWorkerDbWriteCount - 1);
      FTInnerLogger.e(TAG, `EVENT mailbox draft write failed: id=${response.id}, error=${error.message}`);
      this.completeRumWorkerCallback(callback, false);
    });
  }

  private isRumCounterMailboxResponse(response: SDKWorkerResponse): boolean {
    if (!response || !response.id) {
      return false;
    }
    return response.id.indexOf(`${SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE}:`) === 0 ||
      response.id.indexOf(`${SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH}:`) === 0 ||
      response.id.indexOf(`${SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH}:`) === 0;
  }

  private completeRumWorkerCallback(callback: PendingRumWorkerCallback | undefined, result: boolean): void {
    if (!callback || !callback.callBack) {
      return;
    }
    if (result || callback.callbackOnFinish) {
      callback.callBack.onComplete();
    }
  }

  private resolveFallbackDataTypeFromDrafts(drafts: SDKSyncDataDraftDTO[]): DataType {
    if (!drafts || drafts.length === 0) {
      return DataType.RUM_APP;
    }
    return this.dataTypeFromWorkerString(drafts[0].dataType, DataType.RUM_APP);
  }

  private async handleRumDraftWrite(
    source: string,
    dataType: DataType,
    customDataType: string | undefined,
    measurement: string,
    drafts: SDKSyncDataDraftDTO[],
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): Promise<void> {
    const normalizedDrafts = drafts || [];
    if (normalizedDrafts.length === 0) {
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
      return;
    }

    const writeResult = await this.writeWorkerDraftsToDb(source, normalizedDrafts, dataType);
    const result = this.getWriteAffectedCount(writeResult) > 0;
    const firstUuid = normalizedDrafts[0].uuid;

    this.logCompletedRumDraftWrites(measurement, dataType, normalizedDrafts, writeResult);

    if (result && customDataType && customDataType.length > 0) {
      FTInnerLogger.d(TAG,
        `[FT-ERROR-SAMPLING] Successfully stored data as ${customDataType}: uuid=${firstUuid}, measurement=${measurement}`);
    } else if (!result && writeResult !== null && writeResult.dropped > 0) {
      FTInnerLogger.e(TAG,
        `RUM worker draft write: ${measurement} ${customDataType || dataType.toString()}, uuid: ${firstUuid}, drop by Cache limit`);
    }

    if (result && callBack) {
      callBack.onComplete();
    } else if (!result && callbackOnFinish && callBack) {
      callBack.onComplete();
    }

    if (result) {
      this.syncTaskManager.executeSyncPoll();
    }
  }

  private logCompletedRumDraftWrites(
    fallbackMeasurement: string,
    fallbackDataType: DataType,
    drafts: SDKSyncDataDraftDTO[],
    writeResult: SyncDataWriteResult | null
  ): void {
    if (!writeResult || !writeResult.success || drafts.length === 0) {
      return;
    }

    const groups = this.buildRumDraftWriteLogGroups(fallbackMeasurement, fallbackDataType, drafts);
    const uuidSample = this.buildRumDraftUuidSample(drafts, 3);
    FTInnerLogger.d(TAG,
      `syncDataBackground:batch requested=${writeResult.requested},inserted=${writeResult.inserted},` +
        `updated=${writeResult.updated},dropped=${writeResult.dropped},duplicate=${writeResult.duplicateSkipped},` +
        `groups=${groups},uuid_sample=${uuidSample}`);
  }

  private buildRumDraftWriteLogGroups(
    fallbackMeasurement: string,
    fallbackDataType: DataType,
    drafts: SDKSyncDataDraftDTO[]
  ): string {
    const groups: RumDraftWriteLogGroup[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i];
      const measurement = this.getDraftMeasurement(draft, fallbackMeasurement);
      const dataType = this.dataTypeFromWorkerString(draft.dataType, fallbackDataType).toString();
      let matchedIndex = -1;
      for (let j = 0; j < groups.length; j++) {
        if (groups[j].measurement === measurement && groups[j].dataType === dataType) {
          matchedIndex = j;
          break;
        }
      }
      if (matchedIndex >= 0) {
        groups[matchedIndex].count++;
      } else {
        groups.push({ measurement, dataType, count: 1 });
      }
    }

    const parts: string[] = [];
    for (let i = 0; i < groups.length; i++) {
      parts.push(`${groups[i].measurement}/${groups[i].dataType}:${groups[i].count}`);
    }
    return parts.join('|');
  }

  private buildRumDraftUuidSample(drafts: SDKSyncDataDraftDTO[], maxCount: number): string {
    const samples: string[] = [];
    const count = Math.min(Math.max(0, maxCount), drafts.length);
    for (let i = 0; i < count; i++) {
      if (drafts[i].uuid && drafts[i].uuid.length > 0) {
        samples.push(drafts[i].uuid);
      }
    }
    return samples.join('|');
  }

  private getDraftMeasurement(draft: SDKSyncDataDraftDTO, fallbackMeasurement: string): string {
    const dataString = draft.dataString;
    const separatorIndex = dataString.indexOf(',');
    if (separatorIndex > 0) {
      return dataString.substring(0, separatorIndex);
    }
    return fallbackMeasurement;
  }

  public getWorkerLineProtocolContextSnapshot(): SDKLineProtocolContextDTO | null {
    return this.workerLineProtocolContextSnapshot;
  }

  public ensureWorkerLineProtocolContextSynced(pool: SDKDedicatedPoolType): boolean {
    const currentVersion = this.workerLineProtocolContextVersion;
    const restartCount = SDKDedicatedPoolManager.getInstance().getPoolRestartCount(pool);
    const syncedVersion = this.syncedLineContextVersionByPool.get(pool);
    const syncedRestart = this.syncedLineContextRestartByPool.get(pool);
    if (syncedVersion === currentVersion && syncedRestart === restartCount) {
      return true;
    }

    FTTrackInner.lineContextCommandSequence++;
    const payload: SDKWorkerPayload = this.workerLineProtocolContextSnapshot === null ?
      null : this.workerLineProtocolContextSnapshot as Object as SDKWorkerPayload;
    const posted = SDKDedicatedPoolManager.getInstance().postCommand({
      id: `${SDKWorkerCommand.LINE_CONTEXT_UPDATE}:${pool}:${currentVersion}:${FTTrackInner.lineContextCommandSequence}`,
      pool,
      command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload
    });
    if (posted) {
      this.syncedLineContextVersionByPool.set(pool, currentVersion);
      this.syncedLineContextRestartByPool.set(pool, restartCount);
    }
    return posted;
  }

  private refreshWorkerLineProtocolContextSnapshot(): void {
    this.flushRumWorkerEventBatch('lineContext.beforeUpdate');
    this.workerLineProtocolContextSnapshot = this.dataHelper.createWorkerLineProtocolContextSnapshot();
    this.workerLineProtocolContextVersion++;
    this.syncedLineContextVersionByPool.clear();
    this.syncedLineContextRestartByPool.clear();
  }

  private syncLineProtocolContextToDefaultWorkers(): void {
    this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.LOG_CONSUMER);
  }

  public writeLogDraftsFromWorker(drafts: SDKSyncDataDraftDTO[], isSilence: boolean): void {
    if (!drafts || drafts.length === 0) {
      return;
    }

    this.pendingWorkerDbWriteCount++;
    this.writeLogDraftsFromWorkerAsync(drafts, isSilence);
  }

  private async writeLogDraftsFromWorkerAsync(drafts: SDKSyncDataDraftDTO[], isSilence: boolean): Promise<void> {
    try {
      const writeResult = await this.writeWorkerDraftsToDb('data.prepare.logWorkerDraftBatch', drafts, DataType.LOG);
      const affected = this.getWriteAffectedCount(writeResult);
      if (affected > 0 && !isSilence) {
        this.syncTaskManager.executeSyncPoll();
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Log worker draft write failed: ${errorMessage}`);
    } finally {
      this.pendingWorkerDbWriteCount = Math.max(0, this.pendingWorkerDbWriteCount - 1);
    }
  }

  private async writeWorkerDraftsToDb(
    source: string,
    drafts: SDKSyncDataDraftDTO[],
    fallbackDataType: DataType
  ): Promise<SyncDataWriteResult | null> {
    if (!drafts || drafts.length === 0) {
      return null;
    }
    if (!this.context) {
      FTInnerLogger.e(TAG, `Context is null`);
      return null;
    }

    const dbManager = FTDBManager.getInstance(this.context);
    const taskPoolDrafts = drafts as Object as FTDBTaskPoolSyncDraftDTO[];
    return await dbManager.writeSyncDraftsAtomically(source, taskPoolDrafts, fallbackDataType, {
      applyCachePolicy: true,
      reInsert: false,
      forceTransaction: drafts.length > 1,
      updateOrInsertByUuid: this.shouldUpdateOrInsertByDraftUuid(drafts)
    });
  }

  private shouldUpdateOrInsertByDraftUuid(drafts: SDKSyncDataDraftDTO[]): boolean {
    if (!drafts || drafts.length === 0) {
      return false;
    }
    for (const draft of drafts) {
      if (!draft || !draft.dataString || !draft.dataString.startsWith(`${Constants.FT_MEASUREMENT_RUM_VIEW},`)) {
        return false;
      }
    }
    return true;
  }

  private dataTypeFromWorkerString(value: string | undefined, fallback: DataType): DataType {
    if (value === DataType.RUM_APP.toString()) {
      return DataType.RUM_APP;
    }
    if (value === DataType.RUM_WEBVIEW.toString()) {
      return DataType.RUM_WEBVIEW;
    }
    if (value === DataType.LOG.toString()) {
      return DataType.LOG;
    }
    return fallback;
  }

  private resolveRumWorkerEventType(measurement: string, fields: SDKStringRecord): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      const isActive = this.readStringRecordValue(fields, Constants.KEY_RUM_VIEW_IS_ACTIVE);
      return isActive === 'false' ? 'view.stop' : 'view.start';
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
      return 'action.add';
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
      return 'resource.complete';
    }
    return measurement || '';
  }

  private resolveRumWorkerEventName(
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord
  ): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_NAME) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_ACTION_NAME) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL) || measurement;
    }
    if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
      return this.readStringRecordValue(tags, Constants.KEY_RUM_ERROR_TYPE) ||
        this.readStringRecordValue(fields, Constants.KEY_RUM_ERROR_MESSAGE) ||
        measurement;
    }
    return measurement || '';
  }

  private resolveRumWorkerResourceId(tags: SDKStringRecord): string | undefined {
    const method = this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_METHOD);
    const url = this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL);
    if (method && url) {
      return `${method}:${url}`;
    }
    return url ||
      this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_TRACE_ID) ||
      this.readStringRecordValue(tags, Constants.KEY_RUM_RESOURCE_URL_PATH);
  }

  private readStringRecordValue(record: SDKStringRecord, key: string): string | undefined {
    if (!record) {
      return undefined;
    }
    const value = record[key];
    if (value !== undefined && value !== null && value.length > 0) {
      return value;
    }
    return undefined;
  }

  private createRumSyncDataUuid(measurement: string, tags: Map<string, string>): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      const viewId = tags.get(Constants.KEY_RUM_VIEW_ID);
      if (viewId && viewId.length > 0) {
        return viewId.substring(0, Math.min(16, viewId.length));
      }
    }
    return Utils.generateUUID();
  }

  private createRumSyncDataUuidFromRecord(measurement: string, tags: SDKStringRecord): string {
    if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
      const viewId = this.readStringRecordValue(tags, Constants.KEY_RUM_VIEW_ID);
      if (viewId && viewId.length > 0) {
        return viewId.substring(0, Math.min(16, viewId.length));
      }
    }
    return Utils.generateUUID();
  }

  private getWriteAffectedCount(result: SyncDataWriteResult | null): number {
    if (!result) {
      return 0;
    }
    return Math.max(0, result.inserted) + Math.max(0, result.updated);
  }

  private isViewSyncDataRecord(record: SyncData): boolean {
    return record.getDataString().startsWith(`${Constants.FT_MEASUREMENT_RUM_VIEW},`);
  }

  private shouldUpdateOrInsertByUuid(records: SyncData[]): boolean {
    if (!records || records.length === 0) {
      return false;
    }
    for (const record of records) {
      if (!this.isViewSyncDataRecord(record)) {
        return false;
      }
    }
    return true;
  }

  /**
   * Initialize basic configuration
   */
  initBaseConfig(config: FTSDKConfig, context: Context): void {

    this.sdkConfig = config;
    this.context = context;
    SDKDedicatedPoolManager.getInstance().setMailboxResponseHandler(
      SDKDedicatedPoolType.EVENT_CONSUMER,
      (response: SDKWorkerResponse) => {
        this.handleEventMailboxResponse(response);
      }
    );
    this.dataHelper.initBaseConfig(config);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();

    // Debug log for SyncTaskManager initialization
    this.syncTaskManager.init(config, context);

    FTInnerLogger.i(TAG, "FTTrackInner base config initialized");
  }

  /**
   * Initialize log configuration
   */
  initLogConfig(config: FTLoggerConfig): void {
    this.dataHelper.initLogConfig(config);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();

    // Also set to TrackLogManager
    this.trackLogManager.setLogConfig(config);

    // Initialize hilog interceptor if console log capture is enabled
    if (config.isEnableConsoleLog()) {
      FTHiLogInterceptor.getInstance().init();
    }

    FTInnerLogger.i(TAG, "FTTrackInner log config initialized");
  }

  /**
   * Initialize RUM configuration
   */
  initRUMConfig(config: FTRUMConfig): void {
    this.dataHelper.initRUMConfig(config);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
    FTInnerLogger.i(TAG, "FTTrackInner RUM config initialized");
  }

  /**
   * Add global context
   */
  appendGlobalContext(globalContext: Map<string, string>): void {
    this.dataHelper.appendGlobalContext(globalContext);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * Get data helper instance for RUM data consistency
   * @returns SyncDataHelper instance
   */
  getDataHelper(): SyncDataHelper {
    return this.dataHelper;
  }

  /**
   * Add global context key-value pair
   */
  appendGlobalContextKeyValue(key: string, value: string): void {
    this.dataHelper.appendGlobalContextByKeyValue(key, value);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * Add RUM global context
   */
  appendRUMGlobalContext(globalContext: Map<string, string>): void {
    this.dataHelper.appendRUMGlobalContext(globalContext);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * Add RUM global context key-value pair
   */
  appendRUMGlobalContextKeyValue(key: string, value: string): void {
    this.dataHelper.appendRUMGlobalContextByKeyValue(key, value);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * Add log global context
   */
  appendLogGlobalContext(globalContext: LogGlobalContextDictionary): void {
    this.dataHelper.appendLogGlobalContext(globalContext);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * Add log global context key-value pair
   */
  appendLogGlobalContextKeyValue(key: string, value: LogGlobalContextValue): void {
    this.dataHelper.appendLogGlobalContextByKeyValue(key, value);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();
  }

  /**
   * RUM data tracking
   */
  rum(
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null,
    collectTypeParam: CollectType | null = null
  ): void {

    // Debug log - use more obvious tags
    // FTInnerLogger.d(TAG, `<FT-VIEW-TEST> FTTrackInner.rum called: measurement=${measurement}`);
    // FTInnerLogger.d(TAG, ` FTTrackInner context status: ${this.context ? 'available' : 'null'}`);

    // If it's error data, add special logs
    if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
      const errorMessage = fields.get('error_message') || 'unknown';
      const errorType = tags.get('error_type') || 'unknown';
      FTInnerLogger.d(TAG,
        ` FTTrackInner.rum processing error: message=${errorMessage}, type=${errorType}`);
    }

    // Removed high-frequency action debug logs to reduce log output
    // if (measurement === 'rum_action') {
    //   const actionName = tags.get('action_name') || 'unknown';
    //   const actionType = tags.get('action_type') || 'unknown';
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== ACTION DATA PROCESSING ==========`);
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action name: ${actionName}, type: ${actionType}`);
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action tags (${tags.size}):`);
    //   tags.forEach((value, key) => {
    //     FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG]   ${key}=${value}`);
    //   });
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action fields (${fields.size}):`);
    //   fields.forEach((value, key) => {
    //     FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG]   ${key}=${value}`);
    //   });
    //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== ACTION DATA PROCESSING END ==========`);
    // }

    // Removed verbose long_task and resource debug logs to reduce log output

    // Check if session should be collected
    const sessionId = tags.get('session_id');

    if (!sessionId && (collectTypeParam === null || collectTypeParam === undefined)) {
      // If no session ID, collect by default
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack);
      return;
    }

    // Check session collection type (aligned with Android)
    const collectType = collectTypeParam !== null && collectTypeParam !== undefined
      ? collectTypeParam
      : FTRUMInnerManager.getInstance().checkSessionWillCollect(sessionId);

    if (collectType === CollectType.ALL) {
      // Normal collection - store as RUM_APP
      // if (measurement === 'rum_action') {
      //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== STAGE 4: syncDataBackground START ==========`);
      // }
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack);
    } else if (collectType === CollectType.SAMPLING) {
      // Error sampling collection - store as rum_app_error_sampled
      // if (measurement === 'rum_action') {
      //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== STAGE 4: syncDataBackground (error_sampled) START ==========`);
      // }
      // Store as error_sampled type by using string concatenation (aligned with database implementation)
      // Use DataType.RUM_APP for getBodyContent, but store as "rum_app_error_sampled" in database
      this.syncDataBackgroundWithErrorSampled(DataType.RUM_APP, "rum_app_error_sampled", time, measurement, tags,
        fields, callBack);
    } else {
      // CollectType.DROP - do not collect
      FTInnerLogger.w(TAG,
        `[FT-ACTION-DEBUG] Session will not collect: sessionId=${sessionId}, collectType=${collectType}`);
      if (measurement === 'rum_action') {
        FTInnerLogger.w(TAG, `[FT-ACTION-DEBUG] Action data will NOT be processed due to session collection check`);
      }
    }

  }

  public rumRecords(
    time: number,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    callBack: RunnerCompleteCallBack | null = null,
    collectTypeParam: CollectType | null = null
  ): void {
    if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
      const errorMessage = this.readStringRecordValue(fields, Constants.KEY_RUM_ERROR_MESSAGE) || 'unknown';
      const errorType = this.readStringRecordValue(tags, Constants.KEY_RUM_ERROR_TYPE) || 'unknown';
      FTInnerLogger.d(TAG,
        ` FTTrackInner.rumRecords processing error: message=${errorMessage}, type=${errorType}`);
    }

    const sessionId = this.readStringRecordValue(tags, Constants.KEY_RUM_SESSION_ID);
    if (!sessionId && (collectTypeParam === null || collectTypeParam === undefined)) {
      this.syncDataBackgroundRecords(DataType.RUM_APP, time, measurement, tags, fields, callBack);
      return;
    }

    const collectType = collectTypeParam !== null && collectTypeParam !== undefined
      ? collectTypeParam
      : FTRUMInnerManager.getInstance().checkSessionWillCollect(sessionId);

    if (collectType === CollectType.ALL) {
      this.syncDataBackgroundRecords(DataType.RUM_APP, time, measurement, tags, fields, callBack);
    } else if (collectType === CollectType.SAMPLING) {
      this.syncDataBackgroundWithErrorSampledRecords(
        DataType.RUM_APP,
        'rum_app_error_sampled',
        time,
        measurement,
        tags,
        fields,
        callBack
      );
    } else {
      FTInnerLogger.w(TAG,
        `[FT-ACTION-DEBUG] Session will not collect: sessionId=${sessionId}, collectType=${collectType}`);
    }
  }

  /**
   * WebView RUM data tracking
   */
  rumWebView(
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    collectType: CollectType = CollectType.ALL
  ): void {
    FTInnerLogger.d(TAG, `TAG ========== rumWebView() called ==========`);
    FTInnerLogger.d(TAG, `TAG Measurement: ${measurement},Time: ${time}, Collect type: ${collectType}`);

    const formattedTags = new Map<string, string>();
    tags.forEach((value, key) => {
      // Convert number values that might be JSON strings
      if (typeof value === 'string' && value.startsWith('"') && value.endsWith('"')) {
        formattedTags.set(key, value); // Already a JSON string
      } else {
        formattedTags.set(key, value);
      }
    });

    const formattedFields = new Map<string, string>();
    fields.forEach((value, key) => {
      // Convert number values that might be JSON strings
      if (typeof value === 'string' && value.startsWith('"') && value.endsWith('"')) {
        formattedFields.set(key, value); // Already a JSON string
      } else {
        formattedFields.set(key, value);
      }
    });

    // Check if session should be collected (aligned with rum() method)
    const sessionId = formattedTags.get('session_id');
    FTInnerLogger.d(TAG, `TAG Session ID: ${sessionId}`);

    if (sessionId && this.dataHelper.checkSessionWillCollect(sessionId)) {
      FTInnerLogger.d(TAG, `TAG Session will collect, calling syncDataBackground`);
      // Call syncDataBackground with RUM_WEBVIEW data type
      this.syncDataBackground(DataType.RUM_WEBVIEW, time, measurement, formattedTags, formattedFields, null);
    } else {
      const willCollect = sessionId ? this.dataHelper.checkSessionWillCollect(sessionId) : false;
      FTInnerLogger.w(TAG,
        `TAG Session will not collect: sessionId=${sessionId}, willCollect=${willCollect}`);
    }
  }

  /**
   * Batch LogBean sync processing - called by TrackLogManager
   */
  batchLogBeanSync(batchData: BaseContentBean[], isSilence: boolean): void {
    if (!batchData || batchData.length === 0) {
      return;
    }

    try {
      this.processLogBeanBatch(batchData, isSilence)
        .catch((error: Error) => {
          FTInnerLogger.e(TAG, `Error processing LogBean batch: ${error.message}`);
        });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in batchLogBeanSync: ${error}`);
    }
  }

  batchLogDTOSync(batchData: SDKLogDTO[], isSilence: boolean): void {
    if (!batchData || batchData.length === 0) {
      return;
    }

    try {
      this.processLogDTOBatch(batchData, isSilence)
        .catch((error: Error) => {
          FTInnerLogger.e(TAG, `Error processing LogDTO batch: ${error.message}`);
        });
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in batchLogDTOSync: ${error}`);
    }
  }

  private async processLogBeanBatch(batchData: BaseContentBean[], isSilence: boolean): Promise<void> {
    const createTasks: Promise<SyncData | null>[] = [];

    for (const logBean of batchData) {
      if (logBean instanceof LogBean) {
        createTasks.push(this.createSyncDataFromLogBean(logBean).catch((error: Error) => {
          FTInnerLogger.e(TAG, `Error creating SyncData from LogBean: ${error}`);
          return null;
        }));
      }
    }

    const createdRecords = await Promise.all(createTasks);
    const records: SyncData[] = [];
    for (const record of createdRecords) {
      if (record !== null) {
        records.push(record);
      }
    }

    const writeResult = await this.writePreparedSyncData('data.prepare.logBatch', records);
    const successCount = writeResult ? writeResult.inserted : 0;
    const droppedCount = writeResult ? writeResult.dropped : 0;
    const duplicateCount = writeResult ? writeResult.duplicateSkipped : 0;
    if (droppedCount > 0 || duplicateCount > 0) {
      FTInnerLogger.w(TAG,
        `Batch log processing partial: inserted=${successCount}/${batchData.length}, dropped=${droppedCount}, duplicate=${duplicateCount}`);
    }

    if (successCount > 0 && !isSilence) {
      this.syncTaskManager.executeSyncPoll();
    }
  }

  private async processLogDTOBatch(batchData: SDKLogDTO[], isSilence: boolean): Promise<void> {
    const records = await this.createSyncDataFromLogDTOs(batchData);
    const writeResult = await this.writePreparedSyncData('data.prepare.logDTOBatch', records);
    const successCount = writeResult ? writeResult.inserted : 0;
    const droppedCount = writeResult ? writeResult.dropped : 0;
    const duplicateCount = writeResult ? writeResult.duplicateSkipped : 0;
    if (droppedCount > 0 || duplicateCount > 0) {
      FTInnerLogger.w(TAG,
        `Batch log DTO processing partial: inserted=${successCount}/${batchData.length}, dropped=${droppedCount}, duplicate=${duplicateCount}`);
    }

    if (successCount > 0 && !isSilence) {
      this.syncTaskManager.executeSyncPoll();
    }
  }

  private getWriteCacheCategory(dataType: DataType): WriteCacheCategory {
    if (dataType === DataType.LOG) {
      return WriteCacheCategory.LOG;
    }
    if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      return WriteCacheCategory.RUM;
    }
    return WriteCacheCategory.NONE;
  }

  private getWriteCacheCategoryForRecords(records: SyncData[]): WriteCacheCategory {
    let result = WriteCacheCategory.NONE;
    for (const record of records) {
      const category = this.getWriteCacheCategory(record.getDataType());
      if (category === WriteCacheCategory.NONE) {
        continue;
      }
      if (result === WriteCacheCategory.NONE) {
        result = category;
        continue;
      }
      if (result !== category) {
        return WriteCacheCategory.MIXED;
      }
    }
    return result;
  }

  private createCachePolicyDecision(
    records: SyncData[],
    dropped: number,
    deletedOld: number,
    reservedLog: number,
    reservedRum: number,
    useDatabaseCachePolicy: boolean
  ): SyncDataCachePolicyDecision {
    return {
      records,
      dropped,
      deletedOld,
      reservedLog,
      reservedRum,
      useDatabaseCachePolicy
    };
  }

  private createPassthroughCachePolicyDecision(records: SyncData[]): SyncDataCachePolicyDecision {
    return this.createCachePolicyDecision(records, 0, 0, 0, 0, false);
  }

  private createPolicyOnlyWriteResult(
    source: string,
    requested: number,
    dropped: number,
    deletedOld: number
  ): SyncDataWriteResult {
    return {
      success: true,
      source,
      requested,
      inserted: 0,
      updated: 0,
      dropped,
      duplicateSkipped: 0,
      deletedOld,
      errorMessage: ''
    };
  }

  private async applyWriteCachePolicy(records: SyncData[]): Promise<SyncDataCachePolicyDecision> {
    const category = this.getWriteCacheCategoryForRecords(records);
    if (category === WriteCacheCategory.LOG || category === WriteCacheCategory.RUM) {
      return this.createCachePolicyDecision(records, 0, 0, 0, 0, true);
    }

    if (category === WriteCacheCategory.MIXED) {
      FTInnerLogger.w(TAG, `Mixed cache categories in one write batch, fallback to DB-side cache policy`);
      return this.createCachePolicyDecision(records, 0, 0, 0, 0, true);
    }

    return this.createPassthroughCachePolicyDecision(records);
  }

  private countInsertedCacheRecords(records: SyncData[], inserted: number): SyncDataCacheCountSummary {
    const summary: SyncDataCacheCountSummary = {
      log: 0,
      rum: 0
    };
    const insertedLimit = Math.min(records.length, Math.max(0, inserted));
    for (let i = 0; i < insertedLimit; i++) {
      const category = this.getWriteCacheCategory(records[i].getDataType());
      if (category === WriteCacheCategory.LOG) {
        summary.log++;
      } else if (category === WriteCacheCategory.RUM) {
        summary.rum++;
      }
    }
    return summary;
  }

  private rollbackReservedCacheCounts(
    decision: SyncDataCachePolicyDecision,
    inserted: number,
    dbDeletedOld: number
  ): void {
    if (decision.useDatabaseCachePolicy) {
      return;
    }

    const insertedCounts = this.countInsertedCacheRecords(decision.records, inserted);
    const cachePolicy = FTDBCachePolicy.getInstance();
    const logDbDeletes = decision.reservedLog > 0 ? dbDeletedOld : 0;
    const rumDbDeletes = decision.reservedRum > 0 ? dbDeletedOld : 0;
    const logRollback = Math.max(0, decision.reservedLog + logDbDeletes - insertedCounts.log);
    const rumRollback = Math.max(0, decision.reservedRum + rumDbDeletes - insertedCounts.rum);
    if (logRollback > 0) {
      cachePolicy.optLogCount(-logRollback);
    }
    if (rumRollback > 0) {
      cachePolicy.optRumCount(-rumRollback);
    }
  }

  private mergeCachePolicyDecision(
    result: SyncDataWriteResult,
    requested: number,
    decision: SyncDataCachePolicyDecision
  ): SyncDataWriteResult {
    result.requested = requested;
    result.dropped += decision.dropped;
    result.deletedOld += decision.deletedOld;
    return result;
  }

  private async writeRecordsToDb(
    source: string,
    records: SyncData[],
    useDatabaseCachePolicy: boolean,
    forceTransaction: boolean = false
  ): Promise<SyncDataWriteResult> {
    if (!this.context) {
      throw new Error('Context is null');
    }
    const dbManager = FTDBManager.getInstance(this.context);
    const updateOrInsertByUuid = this.shouldUpdateOrInsertByUuid(records);
    return await dbManager.writeSyncDataAtomically(source, records, {
      applyCachePolicy: useDatabaseCachePolicy,
      reInsert: false,
      forceTransaction: forceTransaction || updateOrInsertByUuid || useDatabaseCachePolicy,
      updateOrInsertByUuid
    });
  }

  private async writePreparedSyncData(source: string, records: SyncData[]): Promise<SyncDataWriteResult | null> {
    if (!records || records.length === 0) {
      return null;
    }
    if (!this.context) {
      FTInnerLogger.e(TAG, `Context is null`);
      return null;
    }

    const cacheDecision = await this.applyWriteCachePolicy(records);
    if (cacheDecision.records.length === 0) {
      return this.createPolicyOnlyWriteResult(source, records.length, cacheDecision.dropped, cacheDecision.deletedOld);
    }

    try {
      const writeResult = await this.writeRecordsToDb(
        source,
        cacheDecision.records,
        cacheDecision.useDatabaseCachePolicy,
        cacheDecision.records.length > 1
      );
      const dbDeletedOld = writeResult.deletedOld;
      this.rollbackReservedCacheCounts(cacheDecision, writeResult.inserted, dbDeletedOld);
      return this.mergeCachePolicyDecision(writeResult, records.length, cacheDecision);
    } catch (error) {
      this.rollbackReservedCacheCounts(cacheDecision, 0, 0);
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  /**
   * Track data async processing (background) with error sampled type
   * This method is used when session is collected by error sampling
   * @param dataTypeForContent DataType enum for getBodyContent (e.g., DataType.RUM_APP)
   * @param dataTypeForStorage String data type for database storage (e.g., "rum_app_error_sampled")
   */
  private syncDataBackgroundWithErrorSampled(
    dataTypeForContent: DataType,
    dataTypeForStorage: string,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    this.submitRumWorkerDraftTask(
      'data.prepare.errorSampled',
      dataTypeForContent,
      dataTypeForStorage,
      time,
      measurement,
      tags,
      fields,
      callBack,
      true
    );
  }

  private syncDataBackgroundWithErrorSampledRecords(
    dataTypeForContent: DataType,
    dataTypeForStorage: string,
    time: number,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    this.submitRumWorkerDraftRecordTask(
      'data.prepare.errorSampled',
      dataTypeForContent,
      dataTypeForStorage,
      time,
      measurement,
      tags,
      fields,
      callBack,
      true
    );
  }

  /**
   * Track data async processing (background)
   */
  private syncDataBackground(
    dataType: DataType,
    time: number,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    // Reduced logging - only log key information

    const taskName = `data.prepare:${measurement}`;
    this.submitRumWorkerDraftTask(taskName, dataType, undefined, time, measurement, tags, fields, callBack, false);
  }

  private syncDataBackgroundRecords(
    dataType: DataType,
    time: number,
    measurement: string,
    tags: SDKStringRecord,
    fields: SDKStringRecord,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    const taskName = `data.prepare:${measurement}`;
    this.submitRumWorkerDraftRecordTask(taskName, dataType, undefined, time, measurement, tags, fields, callBack, false);
  }

  public rumInputFromWorker(
    source: string,
    input: SDKLineProtocolInputDTO,
    callBack: RunnerCompleteCallBack | null = null
  ): void {
    if (!input) {
      if (callBack) {
        callBack.onComplete();
      }
      return;
    }

    const dataType = this.dataTypeFromWorkerString(input.dataType, DataType.RUM_APP);
    this.submitRumWorkerDraftRecordTask(
      source,
      dataType,
      input.customDataType,
      input.time,
      input.measurement,
      input.tags || {},
      input.fields || {},
      callBack,
      false,
      input.uuid
    );
  }

  private stringRecordToMap(record: SDKStringRecord): Map<string, string> {
    const result = new Map<string, string>();
    if (!record) {
      return result;
    }
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      result.set(key, record[key]);
    }
    return result;
  }

  /**
   * Create sync data record from LogBean
   */
  private async createSyncDataFromLogBean(logBean: LogBean): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = Utils.generateUUID();

      // Convert LogBean to Map format - let SyncDataHelper handle global context merging
      const tags = new Map<string, string>();
      const fields = new Map<string, string>();

      // Add LogBean tags and fields
      const logTags = logBean.getAllTags();
      const logFields = logBean.getAllFields();


      const tagKeys = FTTrackInner.getObjectKeys(logTags);
      // FTInnerLogger.d(TAG, `[FT-LOG-DEBUG] LogBean tag keys: ${tagKeys.join(',')}`);
      for (let i = 0; i < tagKeys.length; i++) {
        const key = tagKeys[i];
        const value: object | string = logTags[key];
        // Extract string value from object (handles StringWrapper and {value: string} objects)
        let stringValue: string;
        if (typeof value === 'string') {
          stringValue = value;
        } else if (typeof value === 'object' && value !== null) {
          // Check if it's a StringWrapper or object with 'value' property
          const valueObj = value as Record<string, object>;
          if (valueObj['value'] !== undefined && typeof valueObj['value'] === 'string') {
            stringValue = valueObj['value'] as string;
          } else if (typeof valueObj['getValue'] === 'function') {
            // StringWrapper with getValue method
            try {
              stringValue = (value as FTTrackValueAccessor).getValue();
            } catch (error) {
              stringValue = JSON.stringify(value);
            }
          } else {
            stringValue = JSON.stringify(value);
          }
        } else {
          stringValue = String(value);
        }
        tags.set(key, stringValue);
      }

      const fieldKeys = FTTrackInner.getObjectKeys(logFields);
      for (let i = 0; i < fieldKeys.length; i++) {
        const key = fieldKeys[i];
        const value = logFields[key];
        // Extract string value from object (handles StringWrapper and {value: string} objects)
        let stringValue: string;
        if (typeof value === 'string') {
          stringValue = value;
        } else if (typeof value === 'object' && value !== null) {
          // Check if it's a StringWrapper or object with 'value' property
          const valueObj = value as Record<string, object>;
          if (valueObj['value'] !== undefined && typeof valueObj['value'] === 'string') {
            stringValue = valueObj['value'] as string;
          } else if (typeof valueObj['getValue'] === 'function') {
            // StringWrapper with getValue method
            try {
              stringValue = (value as FTTrackValueAccessor).getValue();
            } catch (error) {
              stringValue = JSON.stringify(value);
            }
          } else {
            stringValue = JSON.stringify(value);
          }
        } else {
          stringValue = String(value);
        }
        fields.set(key, stringValue);
      }

      // Add content field
      fields.set('message', logBean.getContent());

      // Get measurement name from LogBean
      const measurement = logBean.getMeasurement();

      // Verify measurement is correct
      if (!measurement || measurement.length === 0) {
        FTInnerLogger.e(TAG, `LogBean measurement is empty! Using default: ${Constants.FT_LOG_DEFAULT_MEASUREMENT}`);
      }

      // Get data content - SyncDataHelper will merge global context automatically
      // Use logBean.getMeasurement() to get the measurement name (e.g., "df_rum_harmonyos_log")
      const finalMeasurement = measurement || Constants.FT_LOG_DEFAULT_MEASUREMENT;

      return await this.createSyncDataWithWorker(
        DataType.LOG,
        finalMeasurement,
        tags,
        fields,
        logBean.getTimeNano(),
        uuid
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error creating SyncData from LogBean: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Create sync data record
   */
  private async createSyncData(
    dataHelper: SyncDataHelper,
    dataType: DataType,
    data: SyncDataParams
  ): Promise<SyncData> {
    try {
      // Generate UUID
      const uuid = Utils.generateUUID();

      return await this.createSyncDataWithWorker(
        dataType,
        data.measurement,
        data.tags,
        data.fields,
        data.time,
        uuid,
        dataHelper
      );

    } catch (error) {
      FTInnerLogger.e(TAG, `createSyncData failed: ${error}`);
      throw new Error(`Operation failed: ${error}`);
    }
  }

  /**
   * Generate ID
   */
  private generateId(): number {
    return Date.now() + Math.floor(Math.random() * 1000);
  }

  private async createSyncDataFromLogDTOs(logDTOs: SDKLogDTO[]): Promise<SyncData[]> {
    const inputs: SDKLineProtocolInputDTO[] = [];
    const dataTypes: DataType[] = [];

    for (let i = 0; i < logDTOs.length; i++) {
      const logDTO = logDTOs[i];
      const uuid = Utils.generateUUID();
      const tags = SyncDataHelper.recordToStringMap(logDTO.tags || {});
      const fields = SyncDataHelper.recordToStringMap(logDTO.fields || {});
      if (!fields.has(Constants.KEY_MESSAGE)) {
        fields.set(Constants.KEY_MESSAGE, logDTO.content || '');
      }
      const measurement = logDTO.measurement && logDTO.measurement.length > 0 ?
        logDTO.measurement : Constants.FT_LOG_DEFAULT_MEASUREMENT;
      const prepared = this.dataHelper.prepareLineProtocolContent(
        measurement,
        tags,
        fields,
        logDTO.timeNano,
        DataType.LOG,
        uuid
      );
      inputs.push(this.toLineProtocolInput(DataType.LOG, uuid, prepared));
      dataTypes.push(DataType.LOG);
    }

    return await this.createSyncDataFromLineInputs(inputs, dataTypes);
  }

  private async createSyncDataWithWorker(
    dataType: DataType,
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    time: number,
    uuid: string,
    dataHelper: SyncDataHelper = this.dataHelper
  ): Promise<SyncData> {
    const prepared = dataHelper.prepareLineProtocolContent(measurement, tags, fields, time, dataType, uuid);
    const input = this.toLineProtocolInput(dataType, uuid, prepared);
    const records = await this.createSyncDataFromLineInputs([input], [dataType]);
    if (records.length > 0) {
      return records[0];
    }

    const fallbackDataString = dataHelper.getBodyContent(measurement, tags, fields, time, dataType, uuid);
    return this.createSyncDataFromDraft({
      dataType: dataType.toString(),
      dataString: fallbackDataString,
      uuid,
      time
    }, dataType);
  }

  private toLineProtocolInput(
    dataType: DataType,
    uuid: string,
    prepared: PreparedLineProtocolContent
  ): SDKLineProtocolInputDTO {
    return {
      dataType: dataType.toString(),
      measurement: prepared.measurement,
      tags: prepared.tags as SDKStringRecord,
      fields: prepared.fields as SDKStringRecord,
      time: prepared.time,
      uuid,
      integerCompatible: prepared.integerCompatible
    };
  }

  private async createSyncDataFromLineInputs(
    inputs: SDKLineProtocolInputDTO[],
    dataTypes: DataType[]
  ): Promise<SyncData[]> {
    if (inputs.length === 0) {
      return [];
    }

    try {
      const requestPayload: SDKLineProtocolRecordsRequestPayload = {
        records: inputs
      };

      const response = await SDKDedicatedPoolManager.getInstance().executeCommand({
        id: `data.createLineProtocol.${Date.now()}.${Math.floor(Math.random() * 100000)}`,
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: requestPayload as Object as SDKWorkerPayload
      });

      if (response.ok && response.payload) {
        const payload = response.payload as Object as SDKLineProtocolDraftsResponsePayload;
        const drafts = payload.drafts || [];
        const records: SyncData[] = [];
        for (let i = 0; i < drafts.length; i++) {
          const dataType = i < dataTypes.length ? dataTypes[i] : DataType.LOG;
          records.push(this.createSyncDataFromDraft(drafts[i], dataType));
        }
        return records;
      }

      FTInnerLogger.w(TAG, `DataProcessWorker line protocol failed: ${response.errorMessage || 'empty response'}`);
    } catch (error) {
      FTInnerLogger.w(TAG, `DataProcessWorker line protocol error: ${error}`);
    }

    const fallbackRecords: SyncData[] = [];
    for (let i = 0; i < inputs.length; i++) {
      const input = inputs[i];
      const dataType = i < dataTypes.length ? dataTypes[i] : DataType.LOG;
      const tags = SyncDataHelper.recordToStringMap(input.tags);
      const fields = SyncDataHelper.recordToStringMap(input.fields);
      const dataString = SyncDataHelper.convertToLineProtocolLine(
        input.measurement,
        tags,
        fields,
        input.time,
        input.integerCompatible === true
      );
      fallbackRecords.push(this.createSyncDataFromDraft({
        dataType: input.dataType,
        customDataType: input.customDataType,
        dataString,
        uuid: input.uuid,
        time: input.time
      }, dataType));
    }
    return fallbackRecords;
  }

  private createSyncDataFromDraft(draft: SDKSyncDataDraftDTO, dataType: DataType): SyncData {
    const syncData = new SyncData(dataType);
    syncData.setId(this.generateId());
    syncData.setUuid(draft.uuid);
    syncData.setDataString(draft.dataString);
    syncData.setTime(draft.time);
    if (draft.customDataType && draft.customDataType.length > 0) {
      syncData.setCustomDataTypeString(draft.customDataType);
    }
    return syncData;
  }

  /*
   * SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
   * 
   * To use SessionReplay functionality, please:
   * 1. Install independent library: ohpm install @ft/session-replay-harmonyos
   * 2. Import library: import { FTSessionReplayManager } from '@ft/session-replay-harmonyos'
   * 3. Refer to independent library documentation for integration
   */

  // /**
  //  * Initialize SessionReplay
  //  */
  // async initSessionReplay(config: SessionReplayConfig): Promise<boolean> {
  //   try {
  //     const result = await this.sessionReplayManager.initSessionReplay(config);
  //     FTInnerLogger.i(TAG, `SessionReplay initialization ${result ? 'succeeded' : 'failed'}`);
  //     return result;
  //   } catch (error) {
  //     FTInnerLogger.e(TAG, `Failed to initialize SessionReplay: ${error}`);
  //     return false;
  //   }
  // }

  /**
   * Close all managers
   */
  async shutdown(): Promise<void> {
    FTInnerLogger.i(TAG, "Shutting down FTTrackInner");

    try {
      this.flushRumWorkerEventBatch('rum.shutdown');
      if (this.rumWorkerEventFlushTimer !== null) {
        clearTimeout(this.rumWorkerEventFlushTimer);
        this.rumWorkerEventFlushTimer = null;
      }
      this.pendingRumWorkerEvents = [];
      this.pendingRumWorkerCallbacks.clear();
      this.trackLogManager.shutdown();
      this.syncTaskManager.stop();
      // SessionReplay functionality has been migrated to independent library
      // await this.sessionReplayManager.shutdown();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error during shutdown: ${error}`);
    }
  }
}

export default FTTrackInner;
