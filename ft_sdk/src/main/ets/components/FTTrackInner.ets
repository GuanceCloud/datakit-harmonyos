import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, LogGlobalContextDictionary, LogGlobalContextValue } from './Configs';
import { DataType } from './enum/Enums';
import { CollectType } from './rum/enum/RUMEnums';
import { FTInnerLogger } from './log/FTLogger';
import { FTLogSeparator } from './log/FTLogSeparator';
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
import {
  SDKDedicatedPoolManager,
  SDKWorkerMailboxRecoveryDiscard,
  SDKWorkerMailboxPostResult,
  SDKWorkerMailboxSource
} from './thread/SDKDedicatedPoolManager';
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
import { FTDataFilter } from './FTDataFilter';
// SessionReplay functionality has been migrated to independent library @ft/session-replay-harmonyos
// import { FTSessionReplayManager, SessionReplayConfig } from '@ft/session-replay-harmonyos';

const TAG = "FTTrackInner";
/** Host-side RUM queue is only a bounded transport coalescer. */
const RUM_WORKER_TRANSPORT_BATCH_SIZE = 64;
const RUM_WORKER_TRANSPORT_BATCH_DELAY_MS = 16;
const RUM_BACKPRESSURE_LOG_INTERVAL_MS = 10000;

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
  errorTimeLine?: number;
  completedResourceIds?: string[];
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

interface LocalDataFilterDraftDecision {
  drafts: SDKSyncDataDraftDTO[];
  filtered: number;
}

interface LocalDataFilterRecordDecision {
  records: SyncData[];
  filtered: number;
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

interface PendingDirectRumWorkerRequest {
  request: SDKWorkerRequest;
}

/** Each ThreadWorker owns its own ordered Host response lane. */
interface RumSemanticResponseLane {
  tail: Promise<void>;
  pendingCount: number;
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
  private pendingDirectRumWorkerRequests: PendingDirectRumWorkerRequest[] = [];
  private rumWorkerEventFlushTimer: number | null = null;
  private directRumWorkerRetryTimer: number | null = null;
  /** Do not merge responses from different Worker slots into one Promise tail. */
  private rumSemanticResponseLanes: Map<string, RumSemanticResponseLane> = new Map();
  private lastRumCacheDiscardLogAt: number = 0;
  private lastEventMailboxFailureLogAt: number = 0;
  private lastEventMailboxRecoveryDiscardLogAt: number = 0;
  private workerLineProtocolContextSnapshot: SDKLineProtocolContextDTO | null = null;
  private workerLineProtocolContextVersion: number = 0;
  private syncedLineContextVersionByPool: Map<SDKDedicatedPoolType, number> = new Map();
  private syncedLineContextRestartByPool: Map<SDKDedicatedPoolType, number> = new Map();
  private pendingWorkerDbWriteCount: number = 0;
  // SessionReplay functionality has been migrated to independent library
  // private sessionReplayManager: FTSessionReplayManager;
  private sdkConfig: FTSDKConfig | null = null;
  private context: Context | null = null;
  private localDataFilters: Map<string, Array<string>> = new Map<string, Array<string>>();
  private remoteDataFilters: Map<string, Array<string>> = new Map<string, Array<string>>();
  private dataFilter: FTDataFilter = FTDataFilter.empty();

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
      const suppliedUuid = draftUuid && draftUuid.length > 0 ? draftUuid : undefined;
      const lineContext = dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW ?
        this.getWorkerLineProtocolContextSnapshot() : null;
      const contextSynced = lineContext !== null ?
        this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER) : false;
      const rumEvent = lineContext === null ?
        this.createPreparedRumWorkerEventDTO(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          suppliedUuid || this.createRumSyncDataUuid(measurement, tags)
        ) :
        this.createRawRumWorkerEventDTO(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          suppliedUuid,
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
      const suppliedUuid = draftUuid && draftUuid.length > 0 ? draftUuid : undefined;
      const lineContext = dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW ?
        this.getWorkerLineProtocolContextSnapshot() : null;
      const contextSynced = lineContext !== null ?
        this.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER) : false;
      const rumEvent = lineContext === null ?
        this.createPreparedRumWorkerEventDTOFromRecords(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          suppliedUuid || this.createRumSyncDataUuidFromRecord(measurement, tags)
        ) :
        this.createRawRumWorkerEventDTOFromRecords(
          dataType,
          customDataType,
          measurement,
          tags,
          fields,
          time,
          suppliedUuid,
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
    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, `RUM worker mailbox post failed: ${traceName}`);
      this.pendingDirectRumWorkerRequests.push({ request: workerRequest });
      if (postResult.shouldRetry) {
        this.scheduleDirectRumWorkerRetry(postResult.retryDelayMs);
      } else {
        this.degradePendingRumWorkerTransport(this.describeRumWorkerCircuit(postResult));
      }
    }
  }

  private scheduleDirectRumWorkerRetry(delayMs: number): void {
    if (this.directRumWorkerRetryTimer !== null) {
      return;
    }
    this.directRumWorkerRetryTimer = setTimeout(() => {
      this.directRumWorkerRetryTimer = null;
      this.flushDirectRumWorkerRequests();
    }, Math.max(1, delayMs)) as number;
  }

  private flushDirectRumWorkerRequests(): void {
    let sent = 0;
    while (this.pendingDirectRumWorkerRequests.length > 0 && sent < RUM_WORKER_TRANSPORT_BATCH_SIZE) {
      const pending = this.pendingDirectRumWorkerRequests[0];
      const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(pending.request);
      if (!postResult.posted) {
        if (postResult.shouldRetry) {
          this.scheduleDirectRumWorkerRetry(postResult.retryDelayMs);
        } else {
          this.degradePendingRumWorkerTransport(this.describeRumWorkerCircuit(postResult));
        }
        return;
      }
      this.pendingDirectRumWorkerRequests.shift();
      sent++;
    }
    if (this.pendingDirectRumWorkerRequests.length > 0) {
      this.scheduleDirectRumWorkerRetry(RUM_WORKER_TRANSPORT_BATCH_DELAY_MS);
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
    if (this.pendingRumWorkerEvents.length >= RUM_WORKER_TRANSPORT_BATCH_SIZE) {
      this.flushRumWorkerEventBatch(source);
      return;
    }
    this.scheduleRumWorkerEventBatchFlush(source);
  }

  private scheduleRumWorkerEventBatchFlush(
    source: string,
    delayMs: number = RUM_WORKER_TRANSPORT_BATCH_DELAY_MS
  ): void {
    if (this.rumWorkerEventFlushTimer !== null) {
      return;
    }
    this.rumWorkerEventFlushTimer = setTimeout(() => {
      this.rumWorkerEventFlushTimer = null;
      this.flushRumWorkerEventBatch(source);
    }, Math.max(1, delayMs)) as number;
  }

  private flushRumWorkerEventBatch(source: string = 'rum.worker.batch'): void {
    if (this.rumWorkerEventFlushTimer !== null) {
      clearTimeout(this.rumWorkerEventFlushTimer);
      this.rumWorkerEventFlushTimer = null;
    }
    if (this.pendingRumWorkerEvents.length === 0) {
      return;
    }

    const batchSize = Math.min(RUM_WORKER_TRANSPORT_BATCH_SIZE, this.pendingRumWorkerEvents.length);
    const batch = this.pendingRumWorkerEvents.slice(0, batchSize);
    const events: SDKRumEventDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      events.push(batch[i].rumEvent);
    }

    const traceName = this.nextRumWorkerTaskName(`${source}.batch`);
    const payload: SDKRumEventBatchDTO = {
      events
    };
    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy({
      id: `${SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    });
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, `RUM worker mailbox batch post failed: size=${batch.length}`);
      if (postResult.shouldRetry) {
        this.scheduleRumWorkerEventBatchFlush(source, postResult.retryDelayMs);
      } else {
        this.degradePendingRumWorkerTransport(this.describeRumWorkerCircuit(postResult));
      }
      return;
    }
    this.pendingRumWorkerEvents.splice(0, batchSize);
    if (this.pendingRumWorkerEvents.length > 0) {
      this.scheduleRumWorkerEventBatchFlush(source);
    }
  }

  private degradePendingRumWorkerTransport(reason: string): void {
    if (this.rumWorkerEventFlushTimer !== null) {
      clearTimeout(this.rumWorkerEventFlushTimer);
      this.rumWorkerEventFlushTimer = null;
    }
    if (this.directRumWorkerRetryTimer !== null) {
      clearTimeout(this.directRumWorkerRetryTimer);
      this.directRumWorkerRetryTimer = null;
    }
    const droppedEvents = this.pendingRumWorkerEvents.length;
    const droppedDirect = this.pendingDirectRumWorkerRequests.length;
    for (let i = 0; i < this.pendingDirectRumWorkerRequests.length; i++) {
      const requestId = this.pendingDirectRumWorkerRequests[i].request.id;
      const callback = this.pendingRumWorkerCallbacks.get(requestId);
      if (callback) {
        this.pendingRumWorkerCallbacks.delete(requestId);
        this.completeRumWorkerCallback(callback, false);
      }
    }
    this.pendingRumWorkerEvents = [];
    this.pendingDirectRumWorkerRequests = [];
    FTInnerLogger.w(TAG,
      `RUM Worker transport degraded: droppedEvents=${droppedEvents}, droppedDirect=${droppedDirect}, ${reason}`);
  }

  private describeRumWorkerCircuit(result: SDKWorkerMailboxPostResult): string {
    return `circuitOpen=${result.circuitOpen}, failures=${result.consecutiveFailures}`;
  }

  public async flushPendingWorkerDataBeforeUpload(timeoutMs: number = 10000): Promise<void> {
    this.flushDirectRumWorkerRequests();
    this.flushAllRumWorkerEventBatches('upload.beforeQuery');
    FTRUMInnerManager.getInstance().flushPendingWorkerCommandsBeforeUpload();
    this.trackLogManager.forceFlush(false);
    await this.waitForWorkerMailboxBarriers('upload.beforeQuery', timeoutMs);
    await this.waitForWorkerMailboxAndDbWrites(timeoutMs);
    FTInnerLogger.d(TAG, `flush pending worker data drained before upload: timeoutMs=${timeoutMs}`);
  }

  private flushAllRumWorkerEventBatches(source: string): void {
    while (this.pendingRumWorkerEvents.length > 0) {
      const before = this.pendingRumWorkerEvents.length;
      this.flushRumWorkerEventBatch(source);
      if (this.pendingRumWorkerEvents.length >= before) {
        break;
      }
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
    return eventPending === 0 && logPending === 0 && this.pendingWorkerDbWriteCount === 0 &&
      this.pendingRumWorkerEvents.length === 0 && this.pendingDirectRumWorkerRequests.length === 0 &&
      !this.hasPendingRumSemanticResponses();
  }

  private hasPendingRumSemanticResponses(): boolean {
    const lanes = Array.from(this.rumSemanticResponseLanes.values());
    for (let i = 0; i < lanes.length; i++) {
      if (lanes[i].pendingCount > 0) {
        return true;
      }
    }
    return false;
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
    uuid: string | undefined,
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
    uuid: string | undefined,
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
    uuid: string | undefined,
    integerCompatible: boolean
  ): SDKRumEventDTO {
    const event: SDKRumEventDTO = {
      time,
      dataType: dataType.toString(),
      customDataType,
      measurement,
      integerCompatible,
      tags,
      fields
    };
    if (uuid && uuid.length > 0) {
      event.uuid = uuid;
    }
    return event;
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

  private enqueueEventMailboxResponse(
    response: SDKWorkerResponse,
    source: SDKWorkerMailboxSource | null
  ): void {
    const laneKey = this.getRumSemanticResponseLaneKey(source);
    const lane = this.getRumSemanticResponseLane(laneKey);
    lane.pendingCount++;
    const run = async (): Promise<void> => {
      try {
        await this.handleEventMailboxResponse(response);
      } finally {
        lane.pendingCount = Math.max(0, lane.pendingCount - 1);
        if (source) {
          SDKDedicatedPoolManager.getInstance().grantEventResponseCredits(source, 1);
        }
        this.releaseRumSemanticResponseLane(laneKey, lane);
      }
    };
    lane.tail = lane.tail.then(run, run);
  }

  private getRumSemanticResponseLaneKey(source: SDKWorkerMailboxSource | null): string {
    return source ?
      `${source.pool}:${source.workerSlotIndex}:${source.workerGeneration}` :
      `${SDKDedicatedPoolType.EVENT_CONSUMER}:unscoped`;
  }

  private getRumSemanticResponseLane(key: string): RumSemanticResponseLane {
    let lane = this.rumSemanticResponseLanes.get(key);
    if (!lane) {
      lane = {
        tail: Promise.resolve(),
        pendingCount: 0
      };
      this.rumSemanticResponseLanes.set(key, lane);
    }
    return lane;
  }

  private releaseRumSemanticResponseLane(key: string, lane: RumSemanticResponseLane): void {
    if (lane.pendingCount === 0 && this.rumSemanticResponseLanes.get(key) === lane) {
      this.rumSemanticResponseLanes.delete(key);
    }
  }

  private async handleEventMailboxResponse(response: SDKWorkerResponse): Promise<void> {
    const rumManager = FTRUMInnerManager.getInstance();
    if (!rumManager.markRumSemanticWorkerResponse(response.id)) {
      return;
    }
    if (this.isRumCounterMailboxResponse(response)) {
      await rumManager.handleRumCounterMailboxResponse(response);
      return;
    }

    const callback = this.pendingRumWorkerCallbacks.get(response.id);
    if (callback) {
      this.pendingRumWorkerCallbacks.delete(response.id);
    }

    if (!response.ok) {
      this.logEventMailboxFailure(response.errorMessage || 'unknown');
      this.completeRumWorkerCallback(callback, false);
      return;
    }
    if (!response.payload) {
      this.completeRumWorkerCallback(callback, false);
      return;
    }

    const payload = response.payload as Object as SDKRumCommandResponsePayload;
    let countersApplied = true;
    if (payload.deltas && payload.deltas.length > 0) {
      countersApplied = await rumManager.handleRumCounterMailboxPayload({
        deltas: payload.deltas,
        needsActionCloseCheck: payload.needsActionCloseCheck,
        needsRumDataGenerate: payload.needsRumDataGenerate
      });
    }
    const drafts = payload.syncDrafts || [];
    if (drafts.length === 0) {
      this.completeRumWorkerCallback(callback, true);
      if (countersApplied) {
        rumManager.markRumResourcesCompleted(
          payload.completedResourceIds || [],
          !!(payload.deltas && payload.deltas.length > 0)
        );
        rumManager.markRumSemanticHostApplied(response.id);
        if (payload.deltas && payload.deltas.length > 0) {
          rumManager.acknowledgeRumSemanticThrough(response.id);
        }
      }
      return;
    }

    if (await this.shouldSkipRumDraftDbWriteForCacheDiscard()) {
      this.logRumCacheDiscard(drafts.length);
      this.completeRumWorkerCallback(callback, true);
      if (countersApplied) {
        rumManager.markRumResourcesCompleted(
          payload.completedResourceIds || [],
          !!(payload.deltas && payload.deltas.length > 0)
        );
        rumManager.markRumSemanticHostApplied(response.id);
        // DISCARD is terminal for these drafts. Advance the barrier here so
        // resource draft/context state is still converged without a DB task.
        rumManager.acknowledgeRumSemanticThrough(response.id);
      }
      return;
    }

    const source = callback ? callback.source : 'event.mailbox.rumWorkerDraft';
    const fallbackDataType = callback ? callback.dataType : this.resolveFallbackDataTypeFromDrafts(drafts);
    this.pendingWorkerDbWriteCount++;
    let draftsCommitted = false;
    try {
      draftsCommitted = await this.handleRumDraftWrite(
        source,
        fallbackDataType,
        callback ? callback.customDataType : undefined,
        callback ? callback.measurement : 'event.mailbox',
        drafts,
        payload.errorTimeLine,
        callback ? callback.callBack : null,
        callback ? callback.callbackOnFinish : false
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `EVENT mailbox draft write failed: id=${response.id}, error=${message}`);
      this.completeRumWorkerCallback(callback, false);
    } finally {
      this.pendingWorkerDbWriteCount = Math.max(0, this.pendingWorkerDbWriteCount - 1);
    }
    if (draftsCommitted && countersApplied) {
      rumManager.markRumResourcesCompleted(
        payload.completedResourceIds || [],
        !!(payload.deltas && payload.deltas.length > 0)
      );
      rumManager.markRumSemanticHostApplied(response.id);
      if (payload.deltas && payload.deltas.length > 0) {
        rumManager.acknowledgeRumSemanticThrough(response.id);
      }
    }
  }

  private logEventMailboxFailure(errorMessage: string): void {
    const now = Date.now();
    if (now - this.lastEventMailboxFailureLogAt < RUM_BACKPRESSURE_LOG_INTERVAL_MS) {
      return;
    }
    this.lastEventMailboxFailureLogAt = now;
    FTInnerLogger.w(TAG, `EVENT mailbox command failed: ${errorMessage}`);
  }

  /** Settles a recovery-window loss once, without per-request error callbacks. */
  private handleEventMailboxRecoveryDiscard(discard: SDKWorkerMailboxRecoveryDiscard): void {
    let callbacksSettled = 0;
    for (let i = 0; i < discard.requestIds.length; i++) {
      const requestId = discard.requestIds[i];
      const callback = this.pendingRumWorkerCallbacks.get(requestId);
      if (!callback) {
        continue;
      }
      this.pendingRumWorkerCallbacks.delete(requestId);
      this.completeRumWorkerCallback(callback, false);
      callbacksSettled++;
    }
    const semanticSettled = FTRUMInnerManager.getInstance()
      .discardRumSemanticRequestsAfterWorkerRecovery(discard.requestIds);
    const now = Date.now();
    if (now - this.lastEventMailboxRecoveryDiscardLogAt < RUM_BACKPRESSURE_LOG_INTERVAL_MS) {
      return;
    }
    this.lastEventMailboxRecoveryDiscardLogAt = now;
    FTInnerLogger.w(TAG,
      `EVENT mailbox recovery discarded=${discard.requestIds.length}, semantic=${semanticSettled}, ` +
        `callbacks=${callbacksSettled}; ${discard.message}`);
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

  private async shouldSkipRumDraftDbWriteForCacheDiscard(): Promise<boolean> {
    return await this.shouldSkipWorkerDraftDbWriteForCacheDiscard(DataType.RUM_APP);
  }

  private async shouldSkipWorkerDraftDbWriteForCacheDiscard(dataType: DataType): Promise<boolean> {
    const cachePolicy = FTDBCachePolicy.getInstance();
    if (this.context) {
      // This awaits only the one-time counter hydration. It avoids a first
      // full-cache response creating a DB write task just to discover DISCARD.
      await cachePolicy.ensureCountsInitialized(this.context);
    }
    return cachePolicy.isCacheDiscardingAtLimit(dataType);
  }

  private logRumCacheDiscard(draftCount: number, details: string = ''): void {
    this.logWorkerDraftCacheDiscard(DataType.RUM_APP, draftCount, details);
  }

  private logWorkerDraftCacheDiscard(dataType: DataType, draftCount: number, details: string = ''): void {
    const now = Date.now();
    if (now - this.lastRumCacheDiscardLogAt < RUM_BACKPRESSURE_LOG_INTERVAL_MS) {
      return;
    }
    this.lastRumCacheDiscardLogAt = now;
    FTInnerLogger.w(TAG,
      `Worker drafts skipped by cache DISCARD: type=${dataType.toString()}, count=${draftCount}` +
        `${details.length > 0 ? `, ${details}` : ''}`);
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
    errorTimeLine: number | undefined,
    callBack: RunnerCompleteCallBack | null,
    callbackOnFinish: boolean
  ): Promise<boolean> {
    const normalizedDrafts = drafts || [];
    if (normalizedDrafts.length === 0) {
      if (callbackOnFinish && callBack) {
        callBack.onComplete();
      }
      return true;
    }

    const writeResult = await this.writeWorkerDraftsToDb(source, normalizedDrafts, dataType, errorTimeLine);
    const result = this.getWriteAffectedCount(writeResult) > 0;
    const firstUuid = normalizedDrafts[0].uuid;

    this.logCompletedRumDraftWrites(measurement, dataType, normalizedDrafts, writeResult);

    if (result && customDataType && customDataType.length > 0) {
      FTInnerLogger.d(TAG,
        `[FT-ERROR-SAMPLING] Successfully stored data as ${customDataType}: uuid=${firstUuid}, measurement=${measurement}`);
    } else if (!result && writeResult !== null && (writeResult.filtered || 0) > 0) {
      this.logLocalDataFilterDrop(dataType, writeResult.filtered || 0);
    } else if (!result && writeResult !== null && writeResult.dropped > 0) {
      this.logRumCacheDiscard(normalizedDrafts.length,
        `${measurement} ${customDataType || dataType.toString()}, uuid=${firstUuid}`);
    }

    if (result && callBack) {
      callBack.onComplete();
    } else if (!result && callbackOnFinish && callBack) {
      callBack.onComplete();
    }

    if (result) {
      this.syncTaskManager.executeSyncPoll();
    }
    return writeResult !== null && (writeResult.success ||
      (writeResult.fallbackPersisted || 0) >= writeResult.requested);
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
    FTLogSeparator.data(TAG, "数据入库");
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
    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy({
      id: `${SDKWorkerCommand.LINE_CONTEXT_UPDATE}:${pool}:${currentVersion}:${FTTrackInner.lineContextCommandSequence}`,
      pool,
      command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload
    });
    if (postResult.posted) {
      this.syncedLineContextVersionByPool.set(pool, currentVersion);
      this.syncedLineContextRestartByPool.set(pool, restartCount);
    }
    return postResult.posted;
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
      if (await this.shouldSkipWorkerDraftDbWriteForCacheDiscard(DataType.LOG)) {
        this.logWorkerDraftCacheDiscard(DataType.LOG, drafts.length);
        return;
      }
      const writeResult = await this.writeWorkerDraftsToDb('data.prepare.logWorkerDraftBatch', drafts, DataType.LOG);
      const affected = this.getWriteAffectedCount(writeResult);
      if (affected > 0) {
        FTLogSeparator.data(TAG, "数据入库");
      }
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
    fallbackDataType: DataType,
    lastErrorTimeLine?: number
  ): Promise<SyncDataWriteResult | null> {
    if (!drafts || drafts.length === 0) {
      return null;
    }
    if (!this.context) {
      FTInnerLogger.e(TAG, `Context is null`);
      return null;
    }

    // Worker drafts are already finalized Line Protocol. Filtering here therefore runs
    // after LineDataModifier and before any cache policy or database write.
    const filterDecision = this.applyLocalDataFilterToDrafts(drafts, fallbackDataType);
    if (filterDecision.drafts.length === 0) {
      return this.createLocalDataFilterWriteResult(source, drafts.length, filterDecision.filtered);
    }

    const dbManager = FTDBManager.getInstance(this.context);
    const taskPoolDrafts = filterDecision.drafts as Object as FTDBTaskPoolSyncDraftDTO[];
    const result = await dbManager.writeSyncDraftsAtomically(source, taskPoolDrafts, fallbackDataType, {
      applyCachePolicy: true,
      reInsert: false,
      forceTransaction: filterDecision.drafts.length > 1,
      updateOrInsertByUuid: this.shouldUpdateOrInsertByDraftUuid(filterDecision.drafts),
      lastErrorTimeLine
    });
    return this.mergeLocalDataFilterResult(result, drafts.length, filterDecision.filtered);
  }

  private shouldUpdateOrInsertByDraftUuid(drafts: SDKSyncDataDraftDTO[]): boolean {
    if (!drafts || drafts.length === 0) {
      return false;
    }
    for (const draft of drafts) {
      if (!draft || !draft.uuid || draft.uuid.length === 0 ||
        (draft.dataType !== DataType.RUM_APP.toString() && draft.dataType !== DataType.RUM_WEBVIEW.toString())) {
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
    this.localDataFilters = config.isEnableDataFilter()
      ? config.getDataFilters()
      : new Map<string, Array<string>>();
    this.remoteDataFilters.clear();
    this.rebuildDataFilter();
    SDKDedicatedPoolManager.getInstance().setMailboxResponseHandler(
      SDKDedicatedPoolType.EVENT_CONSUMER,
      (response: SDKWorkerResponse, source: SDKWorkerMailboxSource | null) => {
        this.enqueueEventMailboxResponse(response, source);
      }
    );
    SDKDedicatedPoolManager.getInstance().setWorkerRecoveryHandler(
      SDKDedicatedPoolType.EVENT_CONSUMER,
      (_restartCount: number) => {
        FTRUMInnerManager.getInstance().replayRumSemanticStateAfterWorkerRestart();
      }
    );
    SDKDedicatedPoolManager.getInstance().setMailboxRecoveryDiscardHandler(
      SDKDedicatedPoolType.EVENT_CONSUMER,
      (discard: SDKWorkerMailboxRecoveryDiscard) => {
        this.handleEventMailboxRecoveryDiscard(discard);
      }
    );
    this.dataHelper.initBaseConfig(config);
    this.refreshWorkerLineProtocolContextSnapshot();
    this.syncLineProtocolContextToDefaultWorkers();

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
    collectTypeParam: CollectType | null = null,
    draftUuid?: string
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
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack, draftUuid);
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
      this.syncDataBackground(DataType.RUM_APP, time, measurement, tags, fields, callBack, draftUuid);
    } else if (collectType === CollectType.SAMPLING) {
      // Error sampling collection - store as rum_app_error_sampled
      // if (measurement === 'rum_action') {
      //   FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] ========== STAGE 4: syncDataBackground (error_sampled) START ==========`);
      // }
      // Store as error_sampled type by using string concatenation (aligned with database implementation)
      // Use DataType.RUM_APP for getBodyContent, but store as "rum_app_error_sampled" in database
      this.syncDataBackgroundWithErrorSampled(DataType.RUM_APP, "rum_app_error_sampled", time, measurement, tags,
        fields, callBack, draftUuid);
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
    collectType: CollectType = CollectType.ALL,
    draftUuid?: string
  ): void {
    FTInnerLogger.d(TAG, `TAG ========== rumWebView() called ==========`);
    FTInnerLogger.d(TAG, `TAG Measurement: ${measurement},Time: ${time}, Collect type: ${collectType}`);

    // Host only applies the sampling decision. WebView tag/field/package
    // normalization is finalized inside EVENT_CONSUMER.
    const sessionId = tags.get(Constants.KEY_RUM_SESSION_ID);
    FTInnerLogger.d(TAG, `TAG Session ID: ${sessionId}`);

    if (sessionId && this.dataHelper.checkSessionWillCollect(sessionId)) {
      FTInnerLogger.d(TAG, `TAG Session will collect, calling syncDataBackground`);
      this.syncDataBackground(DataType.RUM_WEBVIEW, time, measurement, tags, fields, null, draftUuid);
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

  private createLocalDataFilterWriteResult(
    source: string,
    requested: number,
    filtered: number
  ): SyncDataWriteResult {
    const result = this.createPolicyOnlyWriteResult(source, requested, filtered, 0);
    result.filtered = filtered;
    return result;
  }

  private mergeLocalDataFilterResult(
    result: SyncDataWriteResult,
    requested: number,
    filtered: number
  ): SyncDataWriteResult {
    result.requested = requested;
    if (filtered > 0) {
      result.dropped += filtered;
      result.filtered = (result.filtered || 0) + filtered;
    }
    return result;
  }

  /** Replace remote rules while retaining application-provided local rules. */
  public updateRemoteDataFilters(filters: Map<string, Array<string>>): void {
    if (this.sdkConfig === null || !this.sdkConfig.isEnableDataFilter()) {
      return;
    }
    this.remoteDataFilters = FTTrackInner.copyDataFilters(filters);
    this.rebuildDataFilter();
  }

  private rebuildDataFilter(): void {
    const merged = FTTrackInner.copyDataFilters(this.localDataFilters);
    this.remoteDataFilters.forEach((remoteRules: Array<string>, category: string) => {
      const localRules = merged.get(category);
      if (localRules === undefined) {
        merged.set(category, remoteRules.slice());
        return;
      }
      merged.set(category, localRules.concat(remoteRules));
    });
    this.dataFilter = FTDataFilter.compile(merged);
  }

  private static copyDataFilters(filters: Map<string, Array<string>>): Map<string, Array<string>> {
    const copied = new Map<string, Array<string>>();
    filters.forEach((rules: Array<string>, category: string) => {
      copied.set(category, rules.slice());
    });
    return copied;
  }

  private applyLocalDataFilterToDrafts(
    drafts: SDKSyncDataDraftDTO[],
    fallbackDataType: DataType
  ): LocalDataFilterDraftDecision {
    if (this.dataFilter.isEmpty()) {
      return { drafts, filtered: 0 };
    }

    const acceptedDrafts: SDKSyncDataDraftDTO[] = [];
    let filtered = 0;
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i];
      const dataType = this.dataTypeFromWorkerString(draft.dataType, fallbackDataType);
      if (this.dataFilter.isFilteredLine(dataType, draft.dataString)) {
        filtered++;
      } else {
        acceptedDrafts.push(draft);
      }
    }
    return { drafts: acceptedDrafts, filtered };
  }

  private applyLocalDataFilterToRecords(records: SyncData[]): LocalDataFilterRecordDecision {
    if (this.dataFilter.isEmpty()) {
      return { records, filtered: 0 };
    }

    const acceptedRecords: SyncData[] = [];
    let filtered = 0;
    for (let i = 0; i < records.length; i++) {
      const record = records[i];
      if (this.dataFilter.isFilteredLine(record.getDataType(), record.getDataString())) {
        filtered++;
      } else {
        acceptedRecords.push(record);
      }
    }
    return { records: acceptedRecords, filtered };
  }

  private logLocalDataFilterDrop(dataType: DataType, count: number): void {
    FTInnerLogger.d(TAG,
      `Local data filter dropped records before cache: type=${dataType.toString()}, count=${count}`);
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

    // SyncData contains the final Line Protocol created after LineDataModifier.
    // Filter before cache reservation and database persistence to match Android behavior.
    const filterDecision = this.applyLocalDataFilterToRecords(records);
    if (filterDecision.records.length === 0) {
      return this.createLocalDataFilterWriteResult(source, records.length, filterDecision.filtered);
    }

    const cacheDecision = await this.applyWriteCachePolicy(filterDecision.records);
    if (cacheDecision.records.length === 0) {
      const result = this.createPolicyOnlyWriteResult(
        source,
        records.length,
        cacheDecision.dropped + filterDecision.filtered,
        cacheDecision.deletedOld
      );
      if (filterDecision.filtered > 0) {
        result.filtered = filterDecision.filtered;
      }
      return result;
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
      const mergedResult = this.mergeCachePolicyDecision(writeResult, filterDecision.records.length, cacheDecision);
      const result = this.mergeLocalDataFilterResult(mergedResult, records.length, filterDecision.filtered);
      if (this.getWriteAffectedCount(result) > 0) {
        FTLogSeparator.data(TAG, "数据入库");
      }
      return result;
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
    callBack: RunnerCompleteCallBack | null = null,
    draftUuid?: string
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
      true,
      draftUuid
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
    callBack: RunnerCompleteCallBack | null = null,
    draftUuid?: string
  ): void {
    // Reduced logging - only log key information

    const taskName = `data.prepare:${measurement}`;
    this.submitRumWorkerDraftTask(
      taskName,
      dataType,
      undefined,
      time,
      measurement,
      tags,
      fields,
      callBack,
      false,
      draftUuid
    );
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
      if (this.directRumWorkerRetryTimer !== null) {
        clearTimeout(this.directRumWorkerRetryTimer);
        this.directRumWorkerRetryTimer = null;
      }
      this.pendingRumWorkerEvents = [];
      this.pendingDirectRumWorkerRequests = [];
      this.pendingRumWorkerCallbacks.clear();
      SDKDedicatedPoolManager.getInstance().setWorkerRecoveryHandler(SDKDedicatedPoolType.EVENT_CONSUMER, null);
      SDKDedicatedPoolManager.getInstance().setMailboxRecoveryDiscardHandler(
        SDKDedicatedPoolType.EVENT_CONSUMER,
        null
      );
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
