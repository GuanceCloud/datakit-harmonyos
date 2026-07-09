import { ActiveViewBean } from './bean/ActiveViewBean';
import { ActiveActionBean } from './bean/ActiveActionBean';
import { ResourceBean } from './bean/ResourceBean';
import { UserData } from './bean/UserData';
import { ResourceParams } from './bean/ResourceParams';
import { NetStatusBean } from './bean/NetStatusBean';
import { ViewBean } from '../db/bean/ViewBean';
import { ActionBean } from '../db/bean/ActionBean';
import {
  ErrorType, 
  ErrorSource, 
  AppState, 
  CollectType,
} from './enum/RUMEnums';
import FTTrackInner from '../FTTrackInner';
import {
  FTDBTaskPoolExecutor,
  FTDBTaskPoolRumCounterDeltaDTO
} from '../db/FTDBTaskPoolExecutor';
import { FTInnerLogger } from "../log/FTLogger";
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKRumCompletedActionBatchDTO,
  SDKRumCompletedActionDTO,
  SDKRumCounterDeltaDTO,
  SDKRumErrorCommandBatchDTO,
  SDKRumErrorCommandDTO,
  SDKRumResourceCommandBatchDTO,
  SDKRumResourceCommandDTO,
  SDKRumResourceContextDTO,
  SDKRumResourceNetStatusDTO,
  SDKRumResourceParamsDTO,
  SDKRumCounterUpdateBatchDTO,
  SDKRumCounterUpdateDTO,
  SDKStringRecord,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../thread/SDKWorkerProtocol';
import { Utils } from '../utils/Utils';
import { Constants } from '../Constants';
import { FTMonitorManager } from './FTMonitorManager';
import { DeviceMetricsMonitorType } from './enum/DeviceMetricsMonitorType';
import { Context } from '@kit.AbilityKit';
import { RunnerCompleteCallBack } from './callback/RunnerCompleteCallBack';
import { SamplingUtils } from '../utils/SamplingUtils';
import { FTRUMConfig } from '../Configs';
import { FTTraceManager } from '../trace/FTTraceManager';
import { FTTraceConfigManager } from '../trace/FTTraceConfigManager';
import { SyncTaskManager } from '../SyncTaskManager';
import { IS_PRE_CRASH } from '../FTExceptionHandler';
import preferences from '@ohos.data.preferences';
import { FTRUMConfigManager } from './FTRUMConfigManager';
import { DataType } from '../enum/Enums';

/**
 * Property wrapper interface for error properties
 * Value can be string, number, or boolean
 */
interface PropertyWrapper {
  value: string | number | boolean;
}

/**
 * URL parsing result interface
 */
interface UrlParseResult {
  host: string;
  path: string;
  query: string;
}

/**
 * Monitor data value object interface
 */
interface MonitorValue {
  value: string;
}

/**
 * Resource-specific tags for line protocol
 */
interface ResourceTags {
  resource_url?: string;
  resource_url_host?: string;
  resource_url_path?: string;
  resource_url_path_group?: string;
  resource_method?: string;
  resource_type?: string;
  resource_status?: string;
  resource_status_group?: string;
  resource_host_ip?: string;
  response_connection?: string;
  response_content_type?: string;
  response_content_encoding?: string;
  trace_id?: string;
  span_id?: string;
}

/**
 * Resource-specific fields for line protocol
 */
interface ResourceFields {
  resource_dns?: string;
  resource_tcp?: string;
  resource_ssl?: string;
  resource_ttfb?: string;
  resource_trans?: string;
  resource_first_byte?: string;
  duration?: string;
  request_header?: string;
  response_header?: string;
  resource_size?: string;
  resource_dns_time?: string;
  resource_connect_time?: string;
  resource_ssl_time?: string;
  resource_first_byte_time?: string;
  resource_download_time?: string;
}

/**
 * LongTask-specific fields for line protocol
 */
interface LongTaskFields {
  duration?: number;
  long_task_stack?: string;
}

/**
 * Error-specific tags for line protocol
 */
interface ErrorTags {
  error_source?: string;
  error_type?: string;
  error_situation?: string;
}

/**
 * Error-specific fields for line protocol
 */
interface ErrorFields {
  error_message?: string;
  error_stack?: string;
  memory_total?: string;
  memory_use?: number;
  cpu_use?: number;
  battery_use?: number;
  locale?: string;
}

/**
 * Log-specific fields for line protocol
 */
interface LogFields {
  message?: string;
  status?: string;
}

/**
 * Time duration interface for resource performance metrics
 */
interface TimeDuration {
  start: number;
  duration: number;
}

// FTExceptionHandler is now in a separate module: ../FTExceptionHandler.ets
// IS_PRE_CRASH is imported from that module

/**
 * RUM context for crash recovery
 */
interface RUMContext {
    viewId: string;
    viewName: string;
    viewReferrer: string;
    sessionId: string;
}

interface SDKRumCounterMailboxPayload {
  accepted?: boolean;
  pendingCount?: number;
  shouldFlush?: boolean;
  deltas?: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck?: boolean;
  needsRumDataGenerate?: boolean;
}

interface PendingCompletedActionWorkerCommand {
  actionId: string;
  actionName: string;
  payload: SDKRumCompletedActionDTO;
}

interface PendingRumResourceWorkerCommand {
  payload: SDKRumResourceCommandDTO;
}

interface PendingRumErrorWorkerCommand {
  payload: SDKRumErrorCommandDTO;
}



const TAG = "FTRUMInnerManager";

/**
 * RUM inner manager - manages RUM data collection and processing
 * RUM Inner Manager implementation for HarmonyOS
 * Internal class only, not exported to external users via index (aligned with Android design)
 * External users should use FTRUMGlobalManager instead
 * Exported for internal SDK use only
 */
export class FTRUMInnerManager {
  private static instance: FTRUMInnerManager | null = null;
  
  // Session management constants (nanoseconds)
  private static readonly MAX_RESTING_TIME = 900000000000; // 15 minutes no operation reset session
  private static readonly SESSION_EXPIRE_TIME = 14400000000000; // 4 hours session expire
  //private static readonly MAX_RESTING_TIME    = 900000000000/15;  // 1 minute  no operation reset session
  //private static readonly SESSION_EXPIRE_TIME = 900000000000/7.5; // 2 minutes session expire

  private static readonly SESSION_FILTER_CAPACITY = 5; // Session filter capacity
  
  // Action management constants
  private static readonly ACTION_FREQUENCY_LIMIT = 100000; // 100ms frequency limit (microseconds)
  private static readonly ACTION_COUNTER_FLUSH_MAX_EVENTS = 256;
  private static readonly ACTION_WORKER_BATCH_SIZE = 64;
  private static readonly ACTION_WORKER_BATCH_DELAY_MS = 16;
  private static readonly RUM_COUNTER_UPDATE_BATCH_SIZE = 64;
  private static readonly RUM_COUNTER_UPDATE_BATCH_DELAY_MS = 16;
  private static readonly RUM_COUNTER_FLUSH_MAX_EVENTS = 256;
  private static readonly RESOURCE_WORKER_BATCH_SIZE = 64;
  private static readonly RESOURCE_WORKER_BATCH_DELAY_MS = 16;
  private static readonly ERROR_WORKER_BATCH_SIZE = 64;
  private static readonly ERROR_WORKER_BATCH_DELAY_MS = 16;
  private static readonly ACTION_TIMEOUT = 5000000; // 5 seconds timeout (microseconds)
  private static rumEventTraceSequence: number = 0;

  /**
   * Get all keys of an object (alternative to for...in loop)
   * @param obj Object
   * @returns Array of keys
   */
  private static getObjectKeys(obj: Record<string, object> | Record<string, string> | Record<string, number>): string[] {
    const keys: string[] = [];
    // Use Object.keys instead of for...in loop, directly iterate all keys
    const objKeys = Object.keys(obj);
    for (let i = 0; i < objKeys.length; i++) {
      keys.push(objKeys[i]);
    }
    return keys;
  }
  
  // Core state
  private sessionId: string = Utils.generateUUID();
  private rumAppId: string = "";
  private context: Context | null = null;
  
  // Sampling rate control (aligned with Android: sampleRate and sessionErrorSampleError)
  private sampleRate: number = 1.0;
  private sessionErrorSampleRate: number = 1.0;
  
  // Current active state
  private activeView: ActiveViewBean | null = null;
  private activeAction: ActiveActionBean | null = null;
  
  // Resource management
  private resourceBeanMap: Map<string, ResourceBean> = new Map();
  
  // View history
  private viewList: string[] = [];
  
  // Action/View data is either sent directly or stored in database first, then queried
  
  // Sessions not to collect
  private notCollectArr: string[] = [];
  private notSessionErrorCollectArr: string[] = [];
  
  // Timer management
  private actionCheckTimer: number | null = null;
  private sessionCheckTimer: number | null = null;
  private rumGenerateTimer: number | null = null;
  private rumCounterFlushTimer: number | null = null;
  private rumCounterUpdateFlushTimer: number | null = null;
  private completedActionFlushTimer: number | null = null;
  private resourceCommandFlushTimer: number | null = null;
  private errorCommandFlushTimer: number | null = null;
  private pendingRumCounterUpdates: SDKRumCounterUpdateDTO[] = [];
  private pendingCompletedActions: PendingCompletedActionWorkerCommand[] = [];
  private pendingResourceCommands: PendingRumResourceWorkerCommand[] = [];
  private pendingErrorCommands: PendingRumErrorWorkerCommand[] = [];
  private resourceContextById: Map<string, SDKRumResourceContextDTO> = new Map();
  private resourceContentSubmittedIds: Set<string> = new Set();
  private resourceStoppedIds: Set<string> = new Set();
  
  // Frequency protection
  private lastActionTime: number = 0;
  
  // Performance monitoring (nanoseconds - aligned with ActiveActionBean)
  private lastUserActiveTime: number = Utils.getCurrentNanoTime();
  private lastSessionTime: number = Utils.getCurrentNanoTime(); // Session start time 
  private preActivityDuration: Map<string, number> = new Map();
  
  
  // User data management
  private userData: UserData | null = null;
  
  // RUM configuration
  private rumConfig: FTRUMConfig | null = null;
  
  // Flag to prevent concurrent execution of generateActionSum
  private isGeneratingActionSum: boolean = false;
  
  // Flag to prevent concurrent execution of generateViewSum
  private isGeneratingViewSum: boolean = false;
  
  // Timer for debouncing generateRumData calls (aligned with Android: mHandler.removeCallbacks)
  private rumDataGenerateTimer: number | null = null;
  
  // Set to track processed action IDs to prevent duplicate inserts
  // This ensures that even if an action is queried multiple times, it will only be inserted once
  private processedActionIds: Set<string> = new Set();
  
  // Set to track inserted action IDs to prevent duplicate uploads
  // This ensures that even if completed action submission is triggered multiple times, it will only upload once.
  private insertedActionIds: Set<string> = new Set();
  
  // Promise-based lock to ensure thread-safe insertion of actions
  // Prevents race condition where multiple threads check and insert the same action simultaneously
  private actionInsertLock: Promise<void> = Promise.resolve();

  // Promise-based lock to ensure thread-safe view operations (startView/stopView)
  // Prevents race condition where multiple threads modify activeView simultaneously
  private viewOperationLock: Promise<void> = Promise.resolve();

  // Promise-based lock to ensure thread-safe session refresh
  // Prevents race condition where multiple threads generate different sessionIds simultaneously
  private sessionRefreshLock: Promise<void> = Promise.resolve();

  // Preferences store for persisting RUM context (for crash recovery)
  private static readonly PREFERENCES_NAME = 'ft_sdk_rum_context';
  private static readonly KEY_VIEW_ID = 'ft.rum.view.id';
  private static readonly KEY_VIEW_NAME = 'ft.rum.view.name';
  private static readonly KEY_VIEW_REFERRER = 'ft.rum.view.referrer';
  private static readonly KEY_SESSION_ID = 'ft.rum.session.id';
  private preferencesStore: preferences.Preferences | null = null;
  private preferencesInitialized: boolean = false;


  // Maximum size for Set collections to prevent memory leak (using Constants.MAX_SET_SIZE_ACTION for Action, MAX_SET_SIZE_VIEW for View)
  
  private constructor() {
    this.initSessionTimer();
    // Note: Session ID is created in field initialization, but checkSessionKeep will be called
    // in initParams() after sampling rates are set from FTRUMConfig
    // Do NOT call checkSessionKeep here because sampleRate may not be set yet
  }

  private toRumCounterDeltaDTO(delta: SDKRumCounterDeltaDTO): FTDBTaskPoolRumCounterDeltaDTO {
    return {
      viewId: delta.viewId,
      actionId: delta.actionId,
      viewErrorDelta: delta.viewErrorDelta,
      actionErrorDelta: delta.actionErrorDelta,
      viewLongTaskDelta: delta.viewLongTaskDelta,
      actionLongTaskDelta: delta.actionLongTaskDelta,
      viewResourceDelta: delta.viewResourceDelta,
      actionResourceDelta: delta.actionResourceDelta,
      viewPendingDelta: delta.viewPendingDelta,
      actionPendingDelta: delta.actionPendingDelta,
      viewActionDelta: delta.viewActionDelta,
      viewUpdateTimeDelta: delta.viewUpdateTimeDelta
    };
  }

  private submitRumCounterUpdateTask(update: SDKRumCounterUpdateDTO): void {
    if (!this.context || !update || !update.updateType) {
      return;
    }

    const payload: SDKRumCounterUpdateDTO = {
      updateType: update.updateType,
      viewId: update.viewId || '',
      actionId: update.actionId || '',
      updateView: update.updateView,
      flushMaxKeys: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
    };

    this.pendingRumCounterUpdates.push(payload);
    if (this.pendingRumCounterUpdates.length >= FTRUMInnerManager.RUM_COUNTER_UPDATE_BATCH_SIZE) {
      this.flushRumCounterUpdateBatch(`rum.counter.${update.updateType}`);
    } else {
      this.scheduleRumCounterUpdateBatchFlush(`rum.counter.${update.updateType}`);
    }
    this.scheduleRumCounterFlush();
  }

  private scheduleRumCounterUpdateBatchFlush(traceBaseName: string): void {
    if (!this.context || this.rumCounterUpdateFlushTimer !== null) {
      return;
    }
    this.rumCounterUpdateFlushTimer = setTimeout(() => {
      this.rumCounterUpdateFlushTimer = null;
      this.flushRumCounterUpdateBatch(traceBaseName);
    }, FTRUMInnerManager.RUM_COUNTER_UPDATE_BATCH_DELAY_MS) as number;
  }

  private flushRumCounterUpdateBatch(traceBaseName: string = 'rum.counter.batch', drainAll: boolean = false): void {
    if (this.rumCounterUpdateFlushTimer !== null) {
      clearTimeout(this.rumCounterUpdateFlushTimer);
      this.rumCounterUpdateFlushTimer = null;
    }
    if (!this.context || this.pendingRumCounterUpdates.length === 0) {
      return;
    }

    let shouldContinue = true;
    while (this.pendingRumCounterUpdates.length > 0 && shouldContinue) {
      const batchSize = Math.min(
        FTRUMInnerManager.RUM_COUNTER_UPDATE_BATCH_SIZE,
        this.pendingRumCounterUpdates.length
      );
      const updates = this.pendingRumCounterUpdates.splice(0, batchSize);
      const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
      const batchPayload: SDKRumCounterUpdateBatchDTO = {
        updates
      };
      const workerRequest: SDKWorkerRequest = {
        id: `${SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH}:${traceName}:${Date.now()}`,
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH,
        priority: SDKTaskPriority.HIGH,
        createdAt: Date.now(),
        payload: batchPayload as Object as SDKWorkerPayload
      };

      const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
      if (!posted) {
        FTInnerLogger.e(TAG, `RUM counter worker mailbox batch post failed: size=${updates.length}`);
      }
      shouldContinue = drainAll;
    }
    if (this.pendingRumCounterUpdates.length > 0) {
      this.scheduleRumCounterUpdateBatchFlush(traceBaseName);
    }
  }

  private submitRumCounterFlushTask(): void {
    if (!this.context) {
      return;
    }

    this.flushRumCounterUpdateBatch('rum.counter.beforeFlush', true);
    const traceName = this.nextRumEventTaskName('rum.counter.flush');
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now()
    };

    const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
    if (!posted) {
      FTInnerLogger.e(TAG, 'RUM counter flush worker mailbox post failed');
    }
  }

  private scheduleRumCounterFlush(delayMs: number = 1000): void {
    if (!this.context) {
      return;
    }
    if (this.rumCounterFlushTimer !== null) {
      return;
    }
    this.rumCounterFlushTimer = setTimeout(() => {
      this.rumCounterFlushTimer = null;
      this.submitRumCounterFlushTask();
    }, delayMs) as number;
  }

  public handleRumCounterMailboxResponse(response: SDKWorkerResponse): void {
    if (!response.ok) {
      FTInnerLogger.e(TAG, `RUM counter mailbox failed: id=${response.id}, error=${response.errorMessage || 'unknown'}`);
      return;
    }
    if (!response.payload) {
      return;
    }
    const payload = response.payload as Object as SDKRumCounterMailboxPayload;
    this.handleRumCounterMailboxPayload(payload);
  }

  public handleRumCounterMailboxPayload(payload: SDKRumCounterMailboxPayload): void {
    if (!payload || !payload.deltas || payload.deltas.length === 0) {
      return;
    }
    this.applyRumCounterDeltasFromWorker(payload);
  }

  public handleRumCounterDeltas(
    deltas: SDKRumCounterDeltaDTO[],
    needsActionCloseCheck?: boolean,
    needsRumDataGenerate?: boolean
  ): void {
    const payload: SDKRumCounterMailboxPayload = {
      deltas,
      needsActionCloseCheck,
      needsRumDataGenerate
    };
    this.handleRumCounterMailboxPayload(payload);
  }

  private async applyRumCounterDeltasFromWorker(payload: SDKRumCounterMailboxPayload): Promise<void> {
    try {
      const context = this.context;
      const deltas = payload.deltas || [];
      if (!context || deltas.length === 0) {
        return;
      }

      const taskPoolDeltas: FTDBTaskPoolRumCounterDeltaDTO[] = [];
      for (let i = 0; i < deltas.length; i++) {
        const delta = deltas[i];
        if (this.hasRumCounterDelta(delta)) {
          taskPoolDeltas.push(this.toRumCounterDeltaDTO(delta));
        }
      }
      if (taskPoolDeltas.length === 0) {
        return;
      }

      await FTDBTaskPoolExecutor.applyRumCounterDeltas(context, taskPoolDeltas);
      if (payload.needsActionCloseCheck === true) {
        this.checkActionClose();
      }
      if (payload.needsRumDataGenerate === true) {
        this.generateRumData();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `RUM counter worker delta apply failed: ${error}`);
    }
  }

  private hasRumCounterDelta(delta: SDKRumCounterDeltaDTO): boolean {
    return delta.viewActionDelta !== 0 ||
      delta.viewErrorDelta !== 0 ||
      delta.actionErrorDelta !== 0 ||
      delta.viewResourceDelta !== 0 ||
      delta.actionResourceDelta !== 0 ||
      delta.viewLongTaskDelta !== 0 ||
      delta.actionLongTaskDelta !== 0 ||
      delta.viewPendingDelta !== 0 ||
      delta.actionPendingDelta !== 0 ||
      delta.viewUpdateTimeDelta !== 0;
  }

  private submitCompletedActionWorkerInput(actionBean: ActionBean, traceBaseName: string): void {
    const actionId = actionBean.getId();
    try {
      if (this.insertedActionIds.has(actionId)) {
        FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action ${actionId} (${actionBean.getActionName()}) already inserted, skipping duplicate insert`);
        return;
      }

      if (this.insertedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `insertedActionIds size (${this.insertedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.insertedActionIds.clear();
      }
      if (this.processedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `processedActionIds size (${this.processedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.processedActionIds.clear();
      }

      this.insertedActionIds.add(actionId);
      this.processedActionIds.add(actionId);
      this.submitCompletedActionWorkerRequest(actionBean, traceBaseName);
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Error scheduling completed action worker input: ${error}`);
      this.insertedActionIds.delete(actionId);
      this.processedActionIds.delete(actionId);
    }
  }

  private submitCompletedActionWorkerRequest(actionBean: ActionBean, traceBaseName: string): void {
    const actionId = actionBean.getId();
    const payload = this.createCompletedActionDTO(actionBean);
    this.postCompletedActionWorkerRequest(actionId, actionBean.getActionName(), payload, traceBaseName);
  }

  private submitCompletedActionDTO(
    actionId: string,
    actionName: string,
    payload: SDKRumCompletedActionDTO,
    traceBaseName: string
  ): void {
    try {
      if (this.insertedActionIds.has(actionId)) {
        FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action ${actionId} (${actionName}) already inserted, skipping duplicate insert`);
        return;
      }

      if (this.insertedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `insertedActionIds size (${this.insertedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.insertedActionIds.clear();
      }
      if (this.processedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `processedActionIds size (${this.processedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.processedActionIds.clear();
      }

      this.insertedActionIds.add(actionId);
      this.processedActionIds.add(actionId);
      this.postCompletedActionWorkerRequest(actionId, actionName, payload, traceBaseName);
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Error scheduling completed action DTO: ${error}`);
      this.insertedActionIds.delete(actionId);
      this.processedActionIds.delete(actionId);
    }
  }

  private postCompletedActionWorkerRequest(
    actionId: string,
    actionName: string,
    payload: SDKRumCompletedActionDTO,
    traceBaseName: string
  ): void {
    this.pendingCompletedActions.push({
      actionId,
      actionName,
      payload
    });
    if (this.pendingCompletedActions.length >= FTRUMInnerManager.ACTION_WORKER_BATCH_SIZE) {
      this.flushCompletedActionWorkerBatch(traceBaseName);
      return;
    }
    this.scheduleCompletedActionWorkerBatchFlush(traceBaseName);
  }

  private scheduleCompletedActionWorkerBatchFlush(traceBaseName: string): void {
    if (this.completedActionFlushTimer !== null) {
      return;
    }
    this.completedActionFlushTimer = setTimeout(() => {
      this.completedActionFlushTimer = null;
      this.flushCompletedActionWorkerBatch(traceBaseName);
    }, FTRUMInnerManager.ACTION_WORKER_BATCH_DELAY_MS) as number;
  }

  private flushCompletedActionWorkerBatch(traceBaseName: string = 'rum.completedAction.batch'): void {
    if (this.completedActionFlushTimer !== null) {
      clearTimeout(this.completedActionFlushTimer);
      this.completedActionFlushTimer = null;
    }
    if (this.pendingCompletedActions.length === 0) {
      return;
    }

    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    const batchSize = Math.min(
      FTRUMInnerManager.ACTION_WORKER_BATCH_SIZE,
      this.pendingCompletedActions.length
    );
    const batch = this.pendingCompletedActions.splice(0, batchSize);
    const actions: SDKRumCompletedActionDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      actions.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumCompletedActionBatchDTO = {
      actions
    };
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
    if (!posted) {
      FTInnerLogger.e(TAG, `Completed action worker mailbox batch post failed: size=${batch.length}`);
      for (let i = 0; i < batch.length; i++) {
        this.insertedActionIds.delete(batch[i].actionId);
        this.processedActionIds.delete(batch[i].actionId);
      }
    }
    if (this.pendingCompletedActions.length > 0) {
      this.scheduleCompletedActionWorkerBatchFlush(traceBaseName);
    }
  }

  public flushPendingWorkerCommandsBeforeUpload(): void {
    while (this.pendingErrorCommands.length > 0) {
      this.flushErrorWorkerCommandBatch('upload.beforeQuery.error');
    }
    while (this.pendingResourceCommands.length > 0) {
      this.flushResourceWorkerCommandBatch('upload.beforeQuery.resource');
    }
    while (this.pendingCompletedActions.length > 0) {
      this.flushCompletedActionWorkerBatch('upload.beforeQuery.action');
    }
    this.flushRumCounterUpdateBatch('upload.beforeQuery.counterUpdate', true);
    this.submitRumCounterFlushTask();
  }

  private createCompletedActionDTO(actionBean: ActionBean): SDKRumCompletedActionDTO {
    const payload: SDKRumCompletedActionDTO = {
      dataType: DataType.RUM_APP.toString(),
      measurement: Constants.FT_MEASUREMENT_RUM_ACTION,
      uuid: Utils.generateUUID(),
      time: actionBean.getStartTime(),
      actionId: actionBean.getId(),
      actionName: actionBean.getActionName(),
      actionType: actionBean.getActionType(),
      sessionId: actionBean.getSessionId(),
      viewId: actionBean.getViewId(),
      viewName: actionBean.getViewName(),
      viewReferrer: actionBean.getViewReferrer(),
      duration: actionBean.getDuration(),
      errorCount: actionBean.getErrorCount(),
      longTaskCount: actionBean.getLongTaskCount(),
      resourceCount: actionBean.getResourceCount(),
      properties: actionBean.getProperty()
    };
    this.attachCompletedActionDynamicTagsIfNeeded(payload);
    return payload;
  }

  private attachCompletedActionDynamicTagsIfNeeded(payload: SDKRumCompletedActionDTO): void {
    if (FTTrackInner.getInstance().getWorkerLineProtocolContextSnapshot() !== null) {
      return;
    }
    payload.dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
  }

  private nextRumEventTaskName(name: string): string {
    FTRUMInnerManager.rumEventTraceSequence++;
    return `${name}#${FTRUMInnerManager.rumEventTraceSequence}`;
  }
  
  /**
   * Generate RUM data 
   * Use debounce mechanism to avoid too frequent refresh (aligned with Android: mHandler.removeCallbacks)
   * Android: mHandler.removeCallbacks(mRUMGenerateRunner); mHandler.postDelayed(mRUMGenerateRunner, 100);
   */
  private generateRumData(): void {
    try {
      // Remove previous timer if exists (aligned with Android: mHandler.removeCallbacks)
      if (this.rumDataGenerateTimer !== null) {
        clearTimeout(this.rumDataGenerateTimer);
        this.rumDataGenerateTimer = null;
      }
      
      // Schedule new execution with 100ms delay (aligned with Android: mHandler.postDelayed)
      this.rumDataGenerateTimer = setTimeout(async () => {
        try {
          this.rumDataGenerateTimer = null;
          await this.generateActionSum();
          await this.generateViewSum();
        } catch (error) {
          FTInnerLogger.e(TAG, `Error generating RUM data: ${error}`);
        }
      }, 100) as number;
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error scheduling RUM data generation: ${error}`);
    }
  }

  /**
   * Process actions from actionBeanList and call FTTrackInner.rum()
   */
  private async generateActionSum(): Promise<void> {
    // Prevent concurrent execution
    if (this.isGeneratingActionSum) {
      return;
    }
    
    this.isGeneratingActionSum = true;
    
    try {
      if (!this.context) {
        FTInnerLogger.w(TAG, `generateActionSum: Context not available`);
        this.isGeneratingActionSum = false;
        return;
      }
      // Query actions from database 
      const LIMIT_SIZE = 50;
      let beans: ActionBean[] = [];
      
      do {
        try {
          beans = await FTDBTaskPoolExecutor.querySumAction(this.context!, LIMIT_SIZE);
          
          // Filter out already processed actions to prevent duplicate inserts
          // Check both processedActionIds and insertedActionIds to ensure no duplicates
          const unprocessedBeans: ActionBean[] = [];
          const deleteIds: string[] = [];
          
          for (const bean of beans) {
            const actionId = bean.getId();
            // Skip if already processed OR already inserted (double check for safety)
            if (this.processedActionIds.has(actionId) || this.insertedActionIds.has(actionId)) {
              // Still delete from database even if already processed/inserted
              deleteIds.push(actionId);
            } else {
              // Check and clean up processedActionIds if it exceeds limit before adding
              if (this.processedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
                FTInnerLogger.w(TAG, `processedActionIds size (${this.processedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
                this.processedActionIds.clear();
              }
              // Mark as processed immediately to prevent duplicate processing
              this.processedActionIds.add(actionId);
              unprocessedBeans.push(bean);
              deleteIds.push(actionId);
            }
          }
          
          // Update ActionBean counts from database BEFORE deleting actions
          // This ensures we have the latest counts even if resources/errors/long tasks complete asynchronously
          for (const bean of unprocessedBeans) {
            const actionId = bean.getId();
            try {
              const dbCounts = await FTDBTaskPoolExecutor.getActionCounts(this.context!, actionId);
              if (dbCounts) {
                bean.setErrorCount(dbCounts.errorCount);
                bean.setLongTaskCount(dbCounts.longTaskCount);
                bean.setResourceCount(dbCounts.resourceCount);
              }
            } catch (error) {
              const errorMessage = error instanceof Error ? error.message : String(error);
              FTInnerLogger.w(TAG, `Failed to update action counts from database before delete for ${actionId}: ${errorMessage}`);
            }
          }
          
          // Delete actions from database AFTER updating counts
          // This ensures that even if generateActionSum is called again, the same actions won't be queried
          if (deleteIds.length > 0) {
            await FTDBTaskPoolExecutor.cleanCloseActionData(this.context!, deleteIds);
          }
          
          // Then insert actions to sync table (only unprocessed ones)
          // Note: We delete after updating counts to ensure we can query the latest counts
          for (const bean of unprocessedBeans) {
            try {
              this.submitCompletedActionWorkerInput(bean, `rum.generateActionSum:${bean.getActionName()}`);
            } catch (error) {
              FTInnerLogger.e(TAG, `Error processing action ${bean.getActionName()}: ${error}`);
              // Remove from processed set if insert failed, so it can be retried
              this.processedActionIds.delete(bean.getId());
            }
          }
          
        } catch (error) {
          FTInnerLogger.e(TAG, `Error querying actions from database: ${error}`);
          break;
        }
      } while (beans.length >= LIMIT_SIZE);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in generateActionSum: ${error}`);
    } finally {
      // Always reset the flag, even if an error occurred
      this.isGeneratingActionSum = false;
    }
  }
  
  /**
   * Generate view summary 
   * Query views from database and call FTTrackInner.rum()
   */
  private async generateViewSum(): Promise<void> {
    // Prevent concurrent execution
    if (this.isGeneratingViewSum) {
      return;
    }
    
    this.isGeneratingViewSum = true;
    
    try {
      if (!this.context) {
        FTInnerLogger.w(TAG, `generateViewSum: Context not available`);
        this.isGeneratingViewSum = false;
        return;
      }
      // Query views from database 
      const LIMIT_SIZE = 50;
      let beans: ViewBean[] = [];
      
      do {
        try {
          beans = await FTDBTaskPoolExecutor.querySumView(this.context!, LIMIT_SIZE);
          
          for (const bean of beans) {
            this.insertView(bean);
          }

        } catch (error) {
          FTInnerLogger.e(TAG, `Error querying views from database: ${error}`);
          break;
        }
      } while (beans.length >= LIMIT_SIZE);
      
      // Clean up all closed views from database (aligned with Android: cleanCloseViewData() at the end)
      // This ensures all closed views are deleted, not just the ones we processed
      // This is important because the same view might have multiple closed versions in the database
      await FTDBTaskPoolExecutor.cleanCloseViewData(this.context!);
      
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in generateViewSum: ${error}`);
    } finally {
      // Always reset the flag, even if an error occurred
      this.isGeneratingViewSum = false;
    }
  }
  
  /**
   * Insert view data 
   * Call FTTrackInner.rum() to store and sync data
   */
  private insertView(viewBean: ViewBean): void {
    try {
      // Build tags and fields
      const tagsMap = new Map<string, string>();
      const fieldsMap = new Map<string, string>();
      
      const tags: Record<string, string> = {};

      const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      const dynamicTagKeys = Object.keys(dynamicTags);
      for (let i = 0; i < dynamicTagKeys.length; i++) {
        const key = dynamicTagKeys[i];
        tags[key] = dynamicTags[key];
      }

      const viewTags = viewBean.getTags();
      const viewTagKeys = Object.keys(viewTags);
      for (let i = 0; i < viewTagKeys.length; i++) {
        const key = viewTagKeys[i];
        tags[key] = viewTags[key];
      }

      // View-specific tags
      tags[Constants.KEY_RUM_VIEW_ID] = viewBean.getId();
      tags[Constants.KEY_RUM_VIEW_NAME] = viewBean.getViewName();
      tags[Constants.KEY_RUM_SESSION_ID] =  viewBean.getSessionId();
      tags[Constants.KEY_RUM_VIEW_REFERRER] =  viewBean.getViewReferrer();
      
      // Convert back to Map for FTTrackInner.rum()
      const entries = Object.entries(tags);
      for (let i = 0; i < entries.length; i++) {
        const key = entries[i][0];
        const value = entries[i][1];
        tagsMap.set(key, value);
      }
      
      // Add fields from ViewBean data (aligned with Android: use constants for field names)
      // Core view fields
      if (viewBean.getViewLoadTime() > 0) {
        fieldsMap.set(Constants.KEY_RUM_VIEW_LOAD_TIME, viewBean.getViewLoadTime().toString());
      }
      fieldsMap.set(Constants.KEY_RUM_VIEW_ACTION_COUNT, viewBean.getActionCount().toString());
      fieldsMap.set(Constants.KEY_RUM_VIEW_RESOURCE_COUNT, viewBean.getResourceCount().toString());
      fieldsMap.set(Constants.KEY_RUM_VIEW_ERROR_COUNT, viewBean.getErrorCount().toString());
      // Calculate time_spent with safety check to prevent abnormal values
      // Maximum reasonable time_spent: 4 hours (14400000000000 nanoseconds)
      const MAX_TIME_SPENT_NS = 14400000000000; // 4 hours in nanoseconds
      let timeSpent: number;
      if (viewBean.getIsClose()) {
        timeSpent = viewBean.getTimeSpent();
      } else {
        timeSpent = Utils.getCurrentNanoTime() - viewBean.getStartTime();
      }
      // Cap time_spent to prevent abnormal values (e.g., when app is killed and restarted)
      if (timeSpent > MAX_TIME_SPENT_NS || timeSpent < 0) {
        FTInnerLogger.w(TAG, `Abnormal view time_spent detected: ${timeSpent}ns, capping to ${MAX_TIME_SPENT_NS}ns`);
        timeSpent = Math.min(timeSpent, MAX_TIME_SPENT_NS);
        timeSpent = Math.max(timeSpent, 0);
      }
      fieldsMap.set(Constants.KEY_RUM_VIEW_TIME_SPENT, timeSpent.toString());
      fieldsMap.set(Constants.KEY_RUM_VIEW_LONG_TASK_COUNT, viewBean.getLongTaskCount().toString());
      fieldsMap.set(Constants.KEY_RUM_VIEW_IS_ACTIVE, (!viewBean.getIsClose()).toString());
      fieldsMap.set(Constants.KEY_SDK_VIEW_UPDATE_TIME, viewBean.getViewUpdateTime().toString());
      
      // Device performance fields (aligned with Android: conditional based on DeviceMetricsMonitorType)
      // Get monitor data from ViewBean.extraAttr (set by FTMonitorManager.attachMonitorData)
      const extraAttr = viewBean.getExtraAttr();
      
      // Define MonitorValue interface locally (same as in ViewBean.ets)
      interface MonitorValue {
        value: string;
      }
      
      // CPU monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)) {
        const cpuTickCountPerSecond = extraAttr.get("cpu_tick_count_per_second");
        const cpuTickCount = extraAttr.get("cpu_tick_count");
        if (cpuTickCountPerSecond) {
          const monitorValue = cpuTickCountPerSecond as MonitorValue;
          if (monitorValue && monitorValue.value && Number.parseFloat(monitorValue.value) > -1) {
            fieldsMap.set(Constants.KEY_CPU_TICK_COUNT_PER_SECOND, monitorValue.value);
          }
        }
        if (cpuTickCount) {
          const monitorValue = cpuTickCount as MonitorValue;
          if (monitorValue && monitorValue.value && Number.parseFloat(monitorValue.value) > -1) {
            fieldsMap.set(Constants.KEY_CPU_TICK_COUNT, monitorValue.value);
          }
        }
      }
      
      // Memory monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)) {
        const memoryMax = extraAttr.get(Constants.KEY_BATTERY_CURRENT_MAX);
        const memoryAvg = extraAttr.get(Constants.KEY_BATTERY_CURRENT_AVG);
        if (memoryMax) {
          const monitorValue = memoryMax as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_MEMORY_MAX, monitorValue.value);
          }
        }
        if (memoryAvg) {
          const monitorValue = memoryAvg as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_MEMORY_AVG, monitorValue.value);
          }
        }
      }
      
      // Battery monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)) {
        const batteryCurrentAvg = extraAttr.get(Constants.KEY_BATTERY_CURRENT_AVG);
        const batteryCurrentMax = extraAttr.get(Constants.KEY_BATTERY_CURRENT_MAX);
        if (batteryCurrentAvg) {
          const monitorValue = batteryCurrentAvg as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_BATTERY_CURRENT_AVG, monitorValue.value);
          }
        }
        if (batteryCurrentMax) {
          const monitorValue = batteryCurrentMax as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_BATTERY_CURRENT_MAX, monitorValue.value);
          }
        }
      }
      
      // FPS monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
        const fpsAvg = extraAttr.get("fps_avg");
        const fpsMini = extraAttr.get("fps_mini");
        if (fpsAvg) {
          const monitorValue = fpsAvg as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_FPS_AVG, monitorValue.value);
          }
        }
        if (fpsMini) {
          const monitorValue = fpsMini as MonitorValue;
          if (monitorValue && monitorValue.value) {
            fieldsMap.set(Constants.KEY_FPS_MINI, monitorValue.value);
          }
        }
      }
      
      // Session error timestamp (aligned with Android: if (bean.getLastErrorTime() > 0))
      if (viewBean.getLastErrorTime() > 0) {
        fieldsMap.set(Constants.KEY_SESSION_ERROR_TIMESTAMP, viewBean.getLastErrorTime().toString());
      }
      
      // Add properties if any (aligned with Android: exclude device monitoring fields as they are already added above)
      // Device monitoring field keys that should be excluded from property output
      const deviceMonitorKeys = new Set<string>([
        "battery_current_max",
        "battery_current_avg",
        "cpu_tick_count",
        "cpu_tick_count_per_second",
        "memory_max",
        "memory_avg",
        "fps_avg",
        "fps_mini"
      ]);
      
      const properties = viewBean.getProperty();
      if (properties && Object.keys(properties).length > 0) {
        const propertyKeys = Object.keys(properties);
        for (let i = 0; i < propertyKeys.length; i++) {
          const key = propertyKeys[i];
          // Skip device monitoring fields as they are already added with correct field names above
          if (deviceMonitorKeys.has(key)) {
            continue;
          }
          const value = properties[key];
          // Only add primitive types to avoid [object Object] issues
          if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
            fieldsMap.set(`view_property_${key}`, String(value));
          } else if (typeof value === 'object' && value !== null) {
            // If object has 'value' property (like MonitorValue), extract it directly
            if (value['value'] !== undefined) {
              fieldsMap.set(`view_property_${key}`, String(value['value']));
            } else {
              // Convert other objects to JSON string
              fieldsMap.set(`view_property_${key}`, JSON.stringify(value));
            }
          }
        }
      }
      
      // Call FTTrackInner.rum() to store and sync data
      // Aligned with Android: use callback to update upload_time after successful upload
      const self = this;
      class ViewUploadCallback implements RunnerCompleteCallBack {
        private viewId: string;
        
        constructor(viewId: string) {
          this.viewId = viewId;
        }
        
        onComplete(): void {
          // Update upload_time after successful upload (aligned with Android)
          if (self.context) {
            self.updateUploadedViewAfterComplete(self.context, this.viewId);
          }
        }
      }
      
      const callback = new ViewUploadCallback(viewBean.getId());
      // Aligned with Android SDK: pass nanoseconds directly (19 digits) without conversion
      // Android SDK: FTTrackInner.getInstance().rum(bean.getStartTime(), ...)
      FTTrackInner.getInstance().rum(
        viewBean.getStartTime(),
        Constants.FT_MEASUREMENT_RUM_VIEW,
        tagsMap,
        fieldsMap,
        callback
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in insertView: ${error}`);
      // Remove from both sets if insert failed, so it can be retried
    }
  }

  private async updateUploadedViewAfterComplete(context: Context, viewId: string): Promise<void> {
    try {
      const success = await FTDBTaskPoolExecutor.updateViewUploadTime(context, viewId, Date.now());
      if (!success) {
        return;
      }
      // After upload_time is updated, try to clean up this specific view if it's closed.
      await FTDBTaskPoolExecutor.cleanCloseViewData(context, [viewId]);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to update uploaded view state: ${error}`);
    }
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): FTRUMInnerManager {
    if (FTRUMInnerManager.instance === null) {
      FTRUMInnerManager.instance = new FTRUMInnerManager();
    }
    return FTRUMInnerManager.instance;
  }

  public static resetStateInternal(): void {
    if (FTRUMInnerManager.instance !== null) {
      FTRUMInnerManager.instance.resetInternalState();
    }
    FTRUMInnerManager.instance = null;
  }

  public static shutdownInternal(): void {
    const instance = FTRUMInnerManager.instance;
    if (instance === null) {
      return;
    }

    instance.shutdown().catch((error: Error) => {
      FTInnerLogger.e(TAG, `Error shutting down RUM manager: ${error.message}`);
    });
  }

  private resetInternalState(): void {
    if (this.actionCheckTimer !== null) {
      clearTimeout(this.actionCheckTimer);
      this.actionCheckTimer = null;
    }
    if (this.sessionCheckTimer !== null) {
      clearInterval(this.sessionCheckTimer);
      this.sessionCheckTimer = null;
    }
    if (this.rumGenerateTimer !== null) {
      clearTimeout(this.rumGenerateTimer);
      this.rumGenerateTimer = null;
    }
    if (this.rumDataGenerateTimer !== null) {
      clearTimeout(this.rumDataGenerateTimer);
      this.rumDataGenerateTimer = null;
    }
    if (this.rumCounterFlushTimer !== null) {
      clearTimeout(this.rumCounterFlushTimer);
      this.rumCounterFlushTimer = null;
    }
    if (this.rumCounterUpdateFlushTimer !== null) {
      clearTimeout(this.rumCounterUpdateFlushTimer);
      this.rumCounterUpdateFlushTimer = null;
    }
    if (this.completedActionFlushTimer !== null) {
      clearTimeout(this.completedActionFlushTimer);
      this.completedActionFlushTimer = null;
    }
    if (this.resourceCommandFlushTimer !== null) {
      clearTimeout(this.resourceCommandFlushTimer);
      this.resourceCommandFlushTimer = null;
    }
    if (this.errorCommandFlushTimer !== null) {
      clearTimeout(this.errorCommandFlushTimer);
      this.errorCommandFlushTimer = null;
    }
    this.pendingRumCounterUpdates = [];
    this.pendingCompletedActions = [];
    this.pendingResourceCommands = [];
    this.pendingErrorCommands = [];
    this.resourceContextById.clear();
    this.resourceContentSubmittedIds.clear();
    this.resourceStoppedIds.clear();

    this.sessionId = Utils.generateUUID();
    this.rumAppId = "";
    this.context = null;
    this.sampleRate = 1.0;
    this.sessionErrorSampleRate = 1.0;
    this.activeView = null;
    this.activeAction = null;
    this.resourceBeanMap.clear();
    this.viewList = [];
    this.notCollectArr = [];
    this.notSessionErrorCollectArr = [];
    this.lastActionTime = 0;
    this.lastUserActiveTime = Utils.getCurrentNanoTime();
    this.lastSessionTime = Utils.getCurrentNanoTime();
    this.preActivityDuration.clear();
    this.userData = null;
    this.rumConfig = null;
    this.isGeneratingActionSum = false;
    this.isGeneratingViewSum = false;
    this.processedActionIds.clear();
    this.insertedActionIds.clear();
    this.actionInsertLock = Promise.resolve();
    this.viewOperationLock = Promise.resolve();
    this.sessionRefreshLock = Promise.resolve();
    this.preferencesStore = null;
    this.preferencesInitialized = false;
  }
  
  /**
   * Initialize Context and static tags
   */
  public initContext(context: Context): void {
    this.context = context;

    // Initialize preferences store for RUM context persistence
    if (!this.preferencesInitialized) {
      this.initRumContextPreferences();
      this.preferencesInitialized = true;
    }

    FTInnerLogger.i(TAG, `initContext initialized`);
  }
  
  /**
   * Initialize preferences store for RUM context persistence
   */
  private initRumContextPreferences(): void {
    if (!this.context) {
      FTInnerLogger.w(TAG, "Context not available, skipping preferences initialization");
      return;
    }

    try {
      this.preferencesStore = preferences.getPreferencesSync(this.context, { name: FTRUMInnerManager.PREFERENCES_NAME })
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize RUM context preferences: ${error.message}`);

    }
  }

  /**
   * Save current RUM context to preferences (for crash recovery)
   * Saves viewId, viewName, viewReferrer, and sessionId
   * This is a fire-and-forget version for use during page transitions
   */
  public saveRumContext(): void {
    this.saveRumContextAsync().catch(() => {
      // Silently fail - logging is done in the async method
    });
  }

  /**
   * Save current RUM context to preferences (for crash recovery)
   * Saves viewId, viewName, viewReferrer, and sessionId
   * This is the async version that can be awaited for crash reporting
   *
   * IMPORTANT: This is called PROACTIVELY during normal operation (startView, startAction)
   * to ensure we have the crash-time context available when the app restarts.
   * HiAppEvent crash callback is triggered AFTER app restart, so we cannot save
   * context at crash time - we must have already saved it during normal operation.
   */
  public async saveRumContextAsync(): Promise<void> {
    if (!this.preferencesStore) {
      FTInnerLogger.w(TAG, "Preferences store not available, skipping RUM context save");
      return;
    }

    const viewId = this.activeView?.getId() || '';
    const viewName = this.activeView?.getViewName() || '';
    const viewReferrer = this.activeView?.getViewReferrer() || '';
    const sessionId = this.sessionId;

    try {
      // Use put() followed by flush() to ensure data is written immediately
      // This is critical for crash reporting - we need the data saved before the crash handler runs
      await this.preferencesStore.put(FTRUMInnerManager.KEY_VIEW_ID, viewId);
      await this.preferencesStore.put(FTRUMInnerManager.KEY_VIEW_NAME, viewName);
      await this.preferencesStore.put(FTRUMInnerManager.KEY_VIEW_REFERRER, viewReferrer);
      await this.preferencesStore.put(FTRUMInnerManager.KEY_SESSION_ID, sessionId);
      await this.preferencesStore.flush();

      FTInnerLogger.d(TAG, `RUM context saved: viewId=${viewId}, viewName=${viewName}, sessionId=${sessionId}`);
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to save RUM context: ${errorMsg}`);
    }
  }

  /**
   * Get saved RUM context from preferences (for crash recovery)
   * Returns an object with viewId, viewName, viewReferrer, and sessionId
   */
  public async getSavedRumContext(): Promise<RUMContext> {
    const defaultContext: RUMContext = {
      viewId: '',
      viewName: '',
      viewReferrer: '',
      sessionId: ''
    };

    if (!this.preferencesStore) {
      FTInnerLogger.w(TAG, "Preferences store not available, returning empty RUM context");
      return defaultContext;
    }

    try {
      const viewId = await this.preferencesStore.get(FTRUMInnerManager.KEY_VIEW_ID, '') as string;
      const viewName = await this.preferencesStore.get(FTRUMInnerManager.KEY_VIEW_NAME, '') as string;
      const viewReferrer = await this.preferencesStore.get(FTRUMInnerManager.KEY_VIEW_REFERRER, '') as string;
      const sessionId = await this.preferencesStore.get(FTRUMInnerManager.KEY_SESSION_ID, '') as string;

      FTInnerLogger.i(TAG, `Retrieved saved RUM context: viewId=${viewId}, viewName=${viewName}, sessionId=${sessionId}`);
      const result: RUMContext = { viewId, viewName, viewReferrer, sessionId };
      return result;
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to get saved RUM context: ${errorMsg}`);
      return defaultContext;
    }
  }

  /**
   * Clear saved RUM context from preferences (after crash report is sent)
   */
  public clearSavedRumContext(): void {
    if (!this.preferencesStore) {
      FTInnerLogger.w(TAG, "Preferences store not available, skipping RUM context clear");
      return;
    }

    this.clearSavedRumContextAsync(this.preferencesStore);
  }

  private async clearSavedRumContextAsync(store: preferences.Preferences): Promise<void> {
    try {
      await store.delete(FTRUMInnerManager.KEY_VIEW_ID);
      await store.delete(FTRUMInnerManager.KEY_VIEW_NAME);
      await store.delete(FTRUMInnerManager.KEY_VIEW_REFERRER);
      await store.delete(FTRUMInnerManager.KEY_SESSION_ID);
      await store.flush();
      FTInnerLogger.d(TAG, "Saved RUM context cleared");
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to clear saved RUM context: ${errorMessage}`);
    }
  }

  /**
   * Initialize RUM parameters from config (aligned with Android: FTRUMInnerManager.initParams)
   * @param config RUM configuration
   */
  public initParams(config: FTRUMConfig): void {
    // Save config reference
    this.rumConfig = config;
    
    // Note: Android FTRUMInnerManager.initParams() does NOT set rumAppId
    // rumAppId is stored in FTRUMConfig and accessed via FTRUMConfigManager.isRumEnable()
    // We keep rumAppId in FTRUMInnerManager for backward compatibility and HarmonyOS-specific usage
    
    // Set sampling rates from config
    this.sampleRate = config.getSamplingRate();
    this.sessionErrorSampleRate = config.getSessionErrorSampleRate();
    
    // Generate new session ID (aligned with Android)
    this.sessionId = Utils.generateUUID();
    this.lastSessionTime = Utils.getCurrentNanoTime();
    this.lastUserActiveTime = this.lastSessionTime;
    
    // Check session keep based on sampling rate
    this.checkSessionKeep(this.sessionId, this.sampleRate, this.sessionErrorSampleRate);
    
    // Close all existing actions and views (aligned with Android)
    // This is done asynchronously to avoid blocking initialization
    if (this.context) {
      this.closeAllActionAndViewAsync(this.context);
    }
    
    FTInnerLogger.i(TAG, `RUM params initialized: sessionId=${this.sessionId}, samplingRate=${this.sampleRate}, sessionErrorSampleRate=${this.sessionErrorSampleRate}`);
  }

  private async closeAllActionAndViewAsync(context: Context): Promise<void> {
    try {
      await FTDBTaskPoolExecutor.closeAllActionAndView(context);
      FTInnerLogger.d(TAG, "Closed all existing actions and views");
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to close all actions and views: ${errorMessage}`);
    }
  }

  /**
   * Set sampling rate configuration
   * @param sampleRate Normal sampling rate [0,1]
   * @param sessionErrorSampleRate Error sampling rate [0,1]
   */
  public setSamplingRates(sampleRate: number, sessionErrorSampleRate: number): void {
    const oldSampleRate = this.sampleRate;
    const oldErrorSampleRate = this.sessionErrorSampleRate;
    
    this.sampleRate = Math.max(0, Math.min(1, sampleRate));
    this.sessionErrorSampleRate = Math.max(0, Math.min(1, sessionErrorSampleRate));
    
    // Recalculate current Session sampling rate (aligned with Android)
    this.checkSessionKeep(this.sessionId, this.sampleRate, this.sessionErrorSampleRate);
    
    FTInnerLogger.i(TAG, ` Sampling rates updated: normal=${oldSampleRate}->${this.sampleRate}, error=${oldErrorSampleRate}->${this.sessionErrorSampleRate}`);
  }
  
  /**
   * Get current session ID
   */
  public getSessionId(): string {
    return this.sessionId;
  }

  /**
   * Get Context
   * @returns Context or null if not initialized
   */
  public getContext(): Context | null {
    return this.context;
  }

  /**
   * Start view
   */
  public async startView(viewName: string, property: Record<string, object> = {}): Promise<void> {
    // Use Promise-based lock to ensure thread-safe view operations
    // This prevents race condition where multiple threads modify activeView simultaneously
    this.viewOperationLock = this.viewOperationLock.then(async () => {
      try {
        FTInnerLogger.d(TAG, `startView begin: ${viewName}`);
      
      // Save previous view name before updating viewList (for referrer calculation)
      // This ensures we can use the previous active view as referrer even if viewList is empty
      // Note: Even if activeView is closed (isClose()=true), we should still use its viewName as previousViewName
      // because it represents the view we're navigating away from
      // IMPORTANT: Save previousViewName BEFORE any operations that might modify activeView
      // Priority: 1. activeView.getViewName() (even if closed) 2. viewList last element 3. root
      let previousViewName: string = Constants.VIEW_NAME_ROOT;
      if (this.activeView) {
        // Always use activeView's viewName as previousViewName, even if it's closed
        // This is crucial when navigating back from ActionTestPage to Index
        previousViewName = this.activeView.getViewName();
      } else if (this.viewList.length > 0) {
        previousViewName = this.viewList[this.viewList.length - 1];
      }
      
      // Update view history
      this.updateViewList(viewName);
      
      // Refresh session
      this.checkSessionRefresh(false);
      
      // Re-check previousViewName after checkSessionRefresh (in case activeView was modified)
      // But only if we don't have a valid previousViewName yet
      if (previousViewName === Constants.VIEW_NAME_ROOT || previousViewName === viewName) {
        const currentPreviousViewName: string = this.activeView 
          ? this.activeView.getViewName() 
          : (this.viewList.length > 0 ? this.viewList[this.viewList.length - 1] : Constants.VIEW_NAME_ROOT);
        if (currentPreviousViewName !== Constants.VIEW_NAME_ROOT && currentPreviousViewName !== viewName) {
          previousViewName = currentPreviousViewName;
        }
      }
      
      // Close current active view
      // Aligned with Android: if activeView exists and is not closed, close it before starting new view
      // Also check if the new viewName is the same as current active view (prevent duplicate startView calls)
      if (this.activeView && !this.activeView.isClose()) {
        // If starting the same view again, skip to prevent duplicate view creation
        if (this.activeView.getViewName() === viewName) {
          FTInnerLogger.d(TAG, ` startView skipped duplicate view: ${viewName}`);
          return;
        }
        
        // Force close action when view changes (aligned with Android: checkActionClose checks viewChanged)
        // This ensures action is closed before new view starts, even if 100ms timeout hasn't elapsed
        // When view changes, force close action regardless of pending resources (aligned with Android behavior)
        if (this.activeAction && !this.activeAction.isActionClose()) {
          this.activeAction.close();
          this.closeAction(this.activeAction, true); // true = force close when view changes (aligned with Android)
        }
        
        const closedViewName = this.activeView.getViewName();
        this.activeView.close();
        await this.closeView(this.activeView);
        
        // Ensure previousViewName is set to the closed view name (if not already set correctly)
        // This is important when the view was already closed by stopView() before startView()
        if (closedViewName !== viewName && closedViewName !== Constants.VIEW_NAME_ROOT) {
          previousViewName = closedViewName;
        }
      } else {
        // If no active view to close, but activeView exists (closed), ensure previousViewName is set correctly
        // This handles the case when stopView() was called before startView()
        if (this.activeView && this.activeView.isClose()) {
          const closedViewName = this.activeView.getViewName();
          if (closedViewName !== viewName && closedViewName !== Constants.VIEW_NAME_ROOT) {
            previousViewName = closedViewName;
          }
        }
      }
      
      // Get load time
      const loadTime = this.getViewLoadTime(viewName);
      // Get referrer: prefer previousViewName (from activeView), but fallback to getLastView() from viewList
      // This ensures correct referrer even when viewList is cleared or when navigating back to a previous view
      // Priority: 1. previousViewName (from activeView) 2. getLastView() (from viewList) 3. root
      let viewReferrer: string;
      // First, try to use previousViewName if it's valid and different from current viewName
      if (previousViewName !== viewName && previousViewName !== Constants.VIEW_NAME_ROOT) {
        viewReferrer = previousViewName;
      } else {
        // Fallback to getLastView() from viewList
        viewReferrer = this.getLastView();
        
        // If getLastView() returns root or same as viewName, but we have a valid previousViewName, use it
        // This is important when navigating back to a previous view (e.g., from ActionTestPage back to Index)
        if ((viewReferrer === Constants.VIEW_NAME_ROOT || viewReferrer === viewName) && 
            previousViewName !== viewName && previousViewName !== Constants.VIEW_NAME_ROOT) {
          viewReferrer = previousViewName;
        }
      }
      
      // Create new active view
      this.activeView = new ActiveViewBean(viewName, viewReferrer, loadTime, this.sessionId);
      
      // Set properties
      if (property && this.hasProperties(property)) {
        this.activeView.setProperty(property);
      }
      
      // Set tags
      this.activeView.setTags(FTRUMConfigManager.getInstance().getRUMPublicDynamicTags());
      
      // Initialize view
      this.initView(this.activeView);
      this.generateRumData();
      // Save RUM context to preferences for crash recovery
      this.saveRumContext();

      FTInnerLogger.d(TAG, `startView success: ${viewName}, referrer=${viewReferrer}, loadTime=${loadTime}, id=${this.activeView.getId()}`);

      } catch (error) {
        FTInnerLogger.e(TAG, `[ERROR] Error starting view ${viewName}: ${error}`);
        // Re-throw as Error to ensure lock chain continues
        if (error instanceof Error) {
          throw error;
        } else {
          throw new Error(String(error));
        }
      }
    });
    await this.viewOperationLock;
  }
  
  /**
   * Stop view
   */
  public async stopView(property: Record<string, object> = {}): Promise<void> {
    // Use Promise-based lock to ensure thread-safe view operations
    // This prevents race condition where multiple threads modify activeView simultaneously
    this.viewOperationLock = this.viewOperationLock.then(async () => {
      try {
      if (!this.activeView) {
        FTInnerLogger.w(TAG, " stopView ignored: no active view");
        return;
      }
      
      // Idempotency check: if view is already closed, skip to prevent duplicate processing
      // This handles cases where stopView() is called multiple times (e.g., onBackground + onDestroy)
      if (this.activeView.isClose()) {
        FTInnerLogger.d(TAG, ` stopView skipped closed view: ${this.activeView.getViewName()}`);
        return;
      }
      
      FTInnerLogger.d(TAG, `stopView begin: ${this.activeView.getViewName()}`);
      
      // Close current action
      this.checkActionClose();
      
      // Set properties
      if (property && this.hasProperties(property)) {
        this.activeView.setProperty(property);
      }
      
      // Update tags
      this.activeView.setTags(FTRUMConfigManager.getInstance().getRUMPublicDynamicTags());
      
      // Attach monitor data
      FTMonitorManager.getInstance().attachMonitorData(this.activeView);
      
      // Close view
      this.activeView.close();
      
      // Store view name before closing
      const viewName = this.activeView.getViewName();
      await this.closeView(this.activeView);
      FTInnerLogger.d(TAG, `stopView success: ${viewName}`);
      
      } catch (error) {
        FTInnerLogger.e(TAG, ` [ERROR] Error stopping view: ${error}`);
        // Re-throw as Error to ensure lock chain continues
        if (error instanceof Error) {
          throw error;
        } else {
          throw new Error(String(error));
        }
      }
    });
    await this.viewOperationLock;
  }
  
  /**
   * Update current view load time
   * @param duration Load time (milliseconds)
   */
  public updateLoadTime(duration: number): void {
    try {
      if (this.activeView) {
        const oldLoadTime = this.activeView.getLoadTime();
        this.activeView.setLoadTime(duration);
        FTInnerLogger.d(TAG, ` updateLoadTime: ${this.activeView.getViewName()}, old=${oldLoadTime}, new=${duration}`);
      } else {
        FTInnerLogger.w(TAG, " updateLoadTime: No active view to update");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to update load time: ${error}`);
    }
  }
  
  /**
   * Start action
   */
  public startAction(
    actionName: string, 
    actionType: string, 
    needWait: boolean = false,
    property: Record<string, object> = {}
  ): void {
    try {
      const currentTime = Utils.getCurrentTimestampMicros();
      
      // Frequency protection: Check if called within 100ms
      if (currentTime - this.lastActionTime < FTRUMInnerManager.ACTION_FREQUENCY_LIMIT) {
        return;
      }
      
      this.lastActionTime = currentTime;
      const viewId = this.activeView?.getId() || "";
      const viewName = this.activeView?.getViewName() || "";
      const viewReferrer = this.activeView?.getViewReferrer() || "";
      const hasReplay = this.activeView?.isHasReplay() || false;
      
      // Refresh session
      this.checkSessionRefresh(true);

      // Close current action
      this.checkActionClose();

      // Check if need to create new action
      if (!this.activeAction || this.activeAction.isActionClose()) {
        this.activeAction = new ActiveActionBean(
          actionName, 
          actionType, 
          this.sessionId, 
          viewId, 
          viewName, 
          viewReferrer, 
          needWait
        );
        
        this.activeAction.setHasReplay(hasReplay);
        // Set properties
        if (property && this.hasProperties(property)) {
          this.activeAction.setProperty(property);
        }
        
        // Set tags
        this.activeAction.setTags(FTRUMConfigManager.getInstance().getRUMPublicDynamicTags());

        // Initialize action
        this.initAction(this.activeAction, false);
        
        // Note: lastUserActiveTime is updated in checkSessionRefresh() (aligned with Android)
        // Android: // this.lastUserActiveTime = activeAction.getStartTime(); (commented out)
        
        // Set action check timer
        this.scheduleActionCheck();

      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [ERROR] Error starting action ${actionName}: ${error}`);
    }
  }
  
  /**
   * Add action (directly completed action)
   */
  public addAction(
    actionName: string,
    actionType: string,
    duration: number,
    startTime: number,
    property: Record<string, object> = {}
  ): void {
    try {
      const viewId = this.activeView?.getId() || "";
      const viewName = this.activeView?.getViewName() || "";
      const viewReferrer = this.activeView?.getViewReferrer() || "";

      // Refresh session
      this.checkSessionRefresh(true);

      const actionId = Utils.generateUUID();
      const actualStartTime = startTime > 0 ? startTime : Utils.getCurrentNanoTime();
      const actualDuration = duration > 0 ? duration : Math.max(0, Utils.getCurrentNanoTime() - actualStartTime);
      let actualProperty: Record<string, object> = {};
      if (property && this.hasProperties(property)) {
        actualProperty = property;
      }
      this.increaseActionCountInMemory(viewId);
      const payload: SDKRumCompletedActionDTO = {
        dataType: DataType.RUM_APP.toString(),
        measurement: Constants.FT_MEASUREMENT_RUM_ACTION,
        uuid: Utils.generateUUID(),
        time: actualStartTime,
        actionId,
        actionName,
        actionType,
        sessionId: this.sessionId,
        viewId,
        viewName,
        viewReferrer,
        duration: actualDuration,
        errorCount: 0,
        longTaskCount: 0,
        resourceCount: 0,
        properties: actualProperty,
        countViewAction: true,
        counterFlushMaxEvents: FTRUMInnerManager.ACTION_COUNTER_FLUSH_MAX_EVENTS
      };
      this.attachCompletedActionDynamicTagsIfNeeded(payload);
      this.submitCompletedActionDTO(
        actionId,
        actionName,
        payload,
        `rum.addAction:${actionName}`
      );
      this.scheduleRumCounterFlush();
      

    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Error in addAction: ${error}`);
    }
  }
  
  /**
   * Stop current action
   */
  public stopAction(): void {
    try {
      if (this.activeAction && this.activeAction.isNeedWaitAction()) {
        this.activeAction.close();
        this.closeAction(this.activeAction, false);
      } else {
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-TEST] Error stopping action: ${error}`);
    }
  }

  private createCurrentResourceContext(fallbackActionId: string = ''): SDKRumResourceContextDTO {
    let actionId = fallbackActionId || '';
    let actionName = '';
    if (this.activeAction && !this.activeAction.isActionClose()) {
      actionId = this.activeAction.getId();
      actionName = this.activeAction.getActionName();
    }
    return {
      sessionId: this.sessionId,
      viewId: this.activeView?.getId() || '',
      viewName: this.activeView?.getViewName() || '',
      viewReferrer: this.activeView?.getViewReferrer() || '',
      actionId,
      actionName
    };
  }

  private submitResourceWorkerCommand(command: SDKRumResourceCommandDTO, traceBaseName: string): void {
    if (!this.context || !command || !command.resourceId) {
      return;
    }
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    this.pendingResourceCommands.push({
      payload: command
    });
    if (this.pendingResourceCommands.length >= FTRUMInnerManager.RESOURCE_WORKER_BATCH_SIZE) {
      this.flushResourceWorkerCommandBatch(traceBaseName);
      return;
    }
    this.scheduleResourceWorkerCommandBatchFlush(traceBaseName);
  }

  private scheduleResourceWorkerCommandBatchFlush(traceBaseName: string): void {
    if (this.resourceCommandFlushTimer !== null) {
      return;
    }
    this.resourceCommandFlushTimer = setTimeout(() => {
      this.resourceCommandFlushTimer = null;
      this.flushResourceWorkerCommandBatch(traceBaseName);
    }, FTRUMInnerManager.RESOURCE_WORKER_BATCH_DELAY_MS) as number;
  }

  private flushResourceWorkerCommandBatch(traceBaseName: string = 'rum.resource.batch'): void {
    if (this.resourceCommandFlushTimer !== null) {
      clearTimeout(this.resourceCommandFlushTimer);
      this.resourceCommandFlushTimer = null;
    }
    if (this.pendingResourceCommands.length === 0) {
      return;
    }

    const batchSize = Math.min(
      FTRUMInnerManager.RESOURCE_WORKER_BATCH_SIZE,
      this.pendingResourceCommands.length
    );
    const batch = this.pendingResourceCommands.splice(0, batchSize);
    const commands: SDKRumResourceCommandDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      commands.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumResourceCommandBatchDTO = {
      commands
    };
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
    if (!posted) {
      FTInnerLogger.e(TAG, `RUM resource worker mailbox batch post failed: size=${batch.length}`);
    }
    if (this.pendingResourceCommands.length > 0) {
      this.scheduleResourceWorkerCommandBatchFlush(traceBaseName);
    }
  }

  private createResourceParamsDTO(resourceId: string, params: ResourceParams): SDKRumResourceParamsDTO {
    const traceContext = FTTraceManager.getInstance().getTraceContext(resourceId);
    const traceConfigManager = FTTraceConfigManager.getInstance();
    let traceId = '';
    let spanId = '';
    if (traceContext && traceConfigManager.isRUMDataLinkingEnabled()) {
      traceId = traceContext.traceId || '';
      spanId = traceContext.spanId || '';
    }
    return {
      url: params.url || '',
      requestHeader: params.requestHeader || this.convertHeadersToString(params.requestHeaderMap),
      responseHeader: params.responseHeader || this.convertHeadersToString(params.responseHeaderMap),
      responseConnection: params.responseConnection || '',
      responseContentType: params.responseContentType || '',
      responseContentEncoding: params.responseContentEncoding || '',
      responseContentLength: params.responseContentLength || 0,
      resourceMethod: params.resourceMethod || '',
      responseBody: params.responseBody || '',
      resourceStatus: params.resourceStatus || 0,
      resourceType: params.resourceType || 'network',
      requestErrorStack: params.requestErrorStack || '',
      requestErrorMsg: params.requestErrorMsg || '',
      property: this.resourcePropertyToRecord(params.property),
      traceId,
      spanId
    };
  }

  private createResourceNetStatusDTO(netStatusBean: NetStatusBean | null): SDKRumResourceNetStatusDTO {
    if (!netStatusBean) {
      return {
        dnsTime: -1,
        dnsStartTime: -1,
        tcpTime: -1,
        tcpStartTime: -1,
        sslTime: -1,
        sslStartTime: -1,
        ttfbTime: -1,
        responseTime: -1,
        firstByteTime: -1,
        firstByteStartTime: -1,
        downloadTime: -1,
        downloadStartTime: -1,
        holeRequestTime: -1,
        resourceHostIP: ''
      };
    }
    return {
      dnsTime: netStatusBean.getDNSTime(),
      dnsStartTime: netStatusBean.getDNSStartTime(),
      tcpTime: netStatusBean.getTcpTime(),
      tcpStartTime: netStatusBean.getConnectStartTime(),
      sslTime: netStatusBean.getSSLTime(),
      sslStartTime: netStatusBean.getSslStartTime(),
      ttfbTime: netStatusBean.getTTFB(),
      responseTime: netStatusBean.getResponseTime(),
      firstByteTime: netStatusBean.getFirstByteTime(),
      firstByteStartTime: netStatusBean.getFirstByteStartTime(),
      downloadTime: netStatusBean.getDownloadTime(),
      downloadStartTime: netStatusBean.getDownloadTimeStart(),
      holeRequestTime: netStatusBean.getHoleRequestTime(),
      resourceHostIP: netStatusBean.getResourceHostIP()
    };
  }

  private resourcePropertyToRecord(property: Map<string, object>): SDKStringRecord {
    const record: SDKStringRecord = {};
    if (!property || property.size === 0) {
      return record;
    }
    property.forEach((value: object, key: string) => {
      record[key] = this.resourcePropertyValueToString(value);
    });
    return record;
  }

  private resourcePropertyValueToString(value: object): string {
    if (value === null || value === undefined) {
      return '';
    }
    if (typeof value === 'object' && value['value'] !== undefined) {
      return String(value['value']);
    }
    return String(value);
  }

  private getResourceCustomDataType(collectType: CollectType): string | undefined {
    return collectType === CollectType.SAMPLING ? 'rum_app_error_sampled' : undefined;
  }

  private updateResourceContextMemoryOnStart(context: SDKRumResourceContextDTO): void {
    if (this.activeView && this.activeView.getId() === context.viewId) {
      this.activeView.increasePendingResourceCount();
      this.activeView.increaseResourceCount();
    }
    if (this.activeAction && this.activeAction.getId() === context.actionId) {
      this.activeAction.increasePendingResourceCount();
    }
  }

  private updateResourceContextMemoryOnStop(context: SDKRumResourceContextDTO): void {
    if (this.activeView && this.activeView.getId() === context.viewId) {
      this.activeView.increaseResourceCount();
      this.activeView.decreasePendingResourceCount();
    }
    if (this.activeAction && this.activeAction.getId() === context.actionId) {
      this.activeAction.decreasePendingResourceCount();
    }
  }

  private markResourceContentSubmitted(resourceId: string): void {
    this.resourceContentSubmittedIds.add(resourceId);
    this.cleanupResourceContextIfComplete(resourceId);
  }

  private markResourceStopped(resourceId: string): void {
    this.resourceStoppedIds.add(resourceId);
    this.cleanupResourceContextIfComplete(resourceId);
  }

  private cleanupResourceContextIfComplete(resourceId: string): void {
    if (!this.resourceContentSubmittedIds.has(resourceId) || !this.resourceStoppedIds.has(resourceId)) {
      return;
    }
    this.resourceContextById.delete(resourceId);
    this.resourceContentSubmittedIds.delete(resourceId);
    this.resourceStoppedIds.delete(resourceId);
  }

  private submitErrorWorkerCommand(command: SDKRumErrorCommandDTO, traceBaseName: string): void {
    if (!this.context || !command || !command.context || !command.context.sessionId) {
      return;
    }
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    this.pendingErrorCommands.push({
      payload: command
    });
    if (this.pendingErrorCommands.length >= FTRUMInnerManager.ERROR_WORKER_BATCH_SIZE) {
      this.flushErrorWorkerCommandBatch(traceBaseName);
      return;
    }
    this.scheduleErrorWorkerCommandBatchFlush(traceBaseName);
  }

  private scheduleErrorWorkerCommandBatchFlush(traceBaseName: string): void {
    if (this.errorCommandFlushTimer !== null) {
      return;
    }
    this.errorCommandFlushTimer = setTimeout(() => {
      this.errorCommandFlushTimer = null;
      this.flushErrorWorkerCommandBatch(traceBaseName);
    }, FTRUMInnerManager.ERROR_WORKER_BATCH_DELAY_MS) as number;
  }

  private flushErrorWorkerCommandBatch(traceBaseName: string = 'rum.error.batch'): void {
    if (this.errorCommandFlushTimer !== null) {
      clearTimeout(this.errorCommandFlushTimer);
      this.errorCommandFlushTimer = null;
    }
    if (this.pendingErrorCommands.length === 0) {
      return;
    }

    const batchSize = Math.min(
      FTRUMInnerManager.ERROR_WORKER_BATCH_SIZE,
      this.pendingErrorCommands.length
    );
    const batch = this.pendingErrorCommands.splice(0, batchSize);
    const commands: SDKRumErrorCommandDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      commands.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumErrorCommandBatchDTO = {
      commands
    };
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const posted = SDKDedicatedPoolManager.getInstance().postCommand(workerRequest);
    if (!posted) {
      FTInnerLogger.e(TAG, `RUM error worker mailbox batch post failed: size=${batch.length}`);
    }
    if (this.pendingErrorCommands.length > 0) {
      this.scheduleErrorWorkerCommandBatchFlush(traceBaseName);
    }
  }

  private errorPropertyToRecord(property: Record<string, object> | null): SDKStringRecord {
    const record: SDKStringRecord = {};
    if (property === null || property === undefined) {
      return record;
    }
    const keys = FTRUMInnerManager.getObjectKeys(property);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = property[key];
      if (value === null || value === undefined) {
        continue;
      }
      if (typeof value === 'object') {
        const wrapper = value as PropertyWrapper;
        if (wrapper.value !== undefined && wrapper.value !== null) {
          record[key] = String(wrapper.value);
        } else {
          record[key] = String(value);
        }
      } else {
        record[key] = String(value);
      }
    }
    return record;
  }

  private increaseErrorMemoryCount(context: SDKRumResourceContextDTO): void {
    if (this.activeView && this.activeView.getId() === context.viewId) {
      this.activeView.increaseErrorCount();
    }
    if (this.activeAction && this.activeAction.getId() === context.actionId) {
      this.activeAction.increaseErrorCount();
    }
  }
  
  /**
   * Start resource monitoring
   */
  public startResource(resourceId: string, property: Record<string, object> = {}): void {
    try {
      // Refresh session
      this.checkSessionRefresh(true);

      const context = this.createCurrentResourceContext();
      this.resourceContentSubmittedIds.delete(resourceId);
      this.resourceStoppedIds.delete(resourceId);
      this.resourceContextById.set(resourceId, context);
      this.updateResourceContextMemoryOnStart(context);
      this.submitResourceWorkerCommand({
        commandType: 'start',
        resourceId,
        context,
        startTime: Utils.getCurrentNanoTime(),
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.start');
      this.scheduleRumCounterFlush();
    } catch (error) {
      FTInnerLogger.e(TAG, `Error starting resource ${resourceId}: ${error}`);
    }
  }
  
  /**
   * Stop resource monitoring
   */
  public stopResource(resourceId: string, fallbackActionId?: string): void {
    try {
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext(fallbackActionId || '');
      this.updateResourceContextMemoryOnStop(context);
      this.submitResourceWorkerCommand({
        commandType: 'stop',
        resourceId,
        context,
        endTime: Utils.getCurrentNanoTime(),
        fallbackActionId: fallbackActionId || '',
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.stop');
      this.scheduleRumCounterFlush();
      this.markResourceStopped(resourceId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error stopping resource ${resourceId}: ${error}`);
    }
  }
  
  /**
   * Add error information
   * Compatible with multiple addError overloads
   * 
   * @param log       log
   * @param message   message
   * @param errorType error type
   * @param state     program running state
   * @param property  additional attribute parameters (optional)
   * @param dateline  occurrence time, nanosecond (optional, defaults to current time)
   * @param callBack  thread pool call back (optional)
   */
  public async addError(
    log: string, 
    message: string, 
    errorType: string,
    state: AppState, 
    property?: Record<string, object> | null, 
    dateline?: number,
    callBack?: RunnerCompleteCallBack | null
  ): Promise<void> {
    const actualDateline = dateline !== undefined ? dateline : Utils.getCurrentNanoTime();
    const actualProperty = property !== undefined ? property : null;
    const actualCallBack = callBack !== undefined ? callBack : null;
    try {
      FTInnerLogger.d(TAG, ` Starting error processing: ${message}, type: ${errorType}, state: ${state}`);
      
      // Refresh session
      this.checkSessionRefresh(true);
      const collectType = this.checkSessionWillCollect(this.sessionId);

      // Check if session should collect error data (aligned with Android)
      // Android SDK logic: error sampling is determined by session sampling state only
      // If collectType is DROP, discard the error
      if (collectType === CollectType.DROP) {
        FTInnerLogger.d(TAG, ` Session will not collect error data: sessionId=${this.sessionId}, collectType=DROP`);
        return;
      }
      
      // Debug log for sampling test
      FTInnerLogger.d(TAG, ` Error will be collected: sessionId=${this.sessionId}, collectType=${collectType}, message=${message}`);

	      if (actualProperty == null || String((actualProperty as Record<string, object>)[IS_PRE_CRASH]) !== "true") {
	        // Exclude the scenario of reporting the last native crash error
	        // Set error time line for error sampling (aligned with Android)
        // This enables collection of data within 1 minute before and after the error
        // Aligned with Android: SyncTaskManager.get().setErrorTimeLine(dateline, activeView)
        // Set lastErrorTime on activeView if available
        if (this.activeView) {
          this.activeView.setLastErrorTime(actualDateline);
          // Also set on ViewBean for SyncTaskManager (aligned with Android)
          const viewBean = this.activeView.convertToViewBean();
          SyncTaskManager.getInstance().setErrorTimeLine(actualDateline, viewBean);
        } else {
          SyncTaskManager.getInstance().setErrorTimeLine(actualDateline, null);
	        }
	      }

	      if (actualCallBack === null) {
	        const context = this.createCurrentResourceContext();
	        this.increaseErrorMemoryCount(context);
	        this.submitErrorWorkerCommand({
	          context,
	          log,
	          message,
	          errorType,
	          errorSource: ErrorSource.LOGGER.toString(),
	          appState: state.toString(),
	          property: this.errorPropertyToRecord(actualProperty),
	          time: actualDateline,
	          customDataType: this.getResourceCustomDataType(collectType),
	          counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
	        }, 'rum.error');
	        this.scheduleRumCounterFlush();
	        return;
	      }

	      // Build Error-specific data structures
	      const errorTagsData = this.buildErrorTags(ErrorSource.LOGGER, errorType, state);
      const errorFieldsData = this.buildErrorFields(message, log);
      
      // Merge with global RUM context and dynamic tags
      const allTags: Record<string, string> = {};
      
      // Layer 2: Dynamic tags
      const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      const dynamicKeys = Object.keys(dynamicTags);
      for (let i = 0; i < dynamicKeys.length; i++) {
        const key = dynamicKeys[i];
        allTags[key] = dynamicTags[key];
      }
      
      // Layer 3: RUM association
      this.attachRUMRelative(allTags,true)

      // Layer 4: Error-specific tags
      if (errorTagsData.error_source) allTags[Constants.KEY_RUM_ERROR_SOURCE] = errorTagsData.error_source;
      if (errorTagsData.error_type) allTags[Constants.KEY_RUM_ERROR_TYPE] = errorTagsData.error_type;
      // Always set error_situation (aligned with Android: tags.put(Constants.KEY_RUM_ERROR_SITUATION, state.toString()))
      // The state.toString() should always return a valid value ("run", "background", or "unknown")
      if (errorTagsData.error_situation !== undefined && errorTagsData.error_situation !== null) {
        allTags[Constants.KEY_RUM_ERROR_SITUATION] = errorTagsData.error_situation;
      } else {
        // Fallback: use state directly if error_situation is not set
        allTags[Constants.KEY_RUM_ERROR_SITUATION] = state.toString();
      }
      
      // Build Error-specific fields
      const allFields: Record<string, string> = {};
      if (errorFieldsData.error_message) allFields[Constants.KEY_RUM_ERROR_MESSAGE] = errorFieldsData.error_message;
      if (errorFieldsData.error_stack) allFields[Constants.KEY_RUM_ERROR_STACK] = errorFieldsData.error_stack;

      // Handle additional properties
      if (actualProperty != null) {
        const propertyKeys = FTRUMInnerManager.getObjectKeys(actualProperty);
        for (let i = 0; i < propertyKeys.length; i++) {
          const key = propertyKeys[i];
          const obj = (actualProperty as Record<string, object>)[key];
          // Extract value from PropertyWrapper objects (which have a .value property)
          if (obj && typeof obj === 'object') {
            try {
              // Try to extract .value property from PropertyWrapper
              const wrapper = obj as PropertyWrapper;
              allFields[key] = String(wrapper.value);
            } catch {
              // If not a PropertyWrapper, convert to string directly
              allFields[key] = String(obj);
            }
          } else {
            allFields[key] = String(obj);
          }
        }
      }

      const self = this;

      class ErrorCallback implements RunnerCompleteCallBack {
        onComplete(): void {
          self.increaseError(allTags);
          if (actualCallBack != null) {
            self.stopViewAfterErrorCallback(actualCallBack);
          }
        }
      }
      const callback = new ErrorCallback();

      FTTrackInner.getInstance().rumRecords(
        actualDateline,
        Constants.FT_MEASUREMENT_RUM_ERROR,
        allTags,
        allFields,
        callback,
        collectType
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding error: ${error}`);
      if (actualCallBack != null) {
        actualCallBack.onComplete();
      }
    }
  }

  /**
   * Add resource data
   * Add resource implementation
   * 
   * @param resourceId Resource ID
   * @param params Resource parameters
   * @param netStatusBean Network status Bean
   */
  public addResource(resourceId: string, params: ResourceParams, netStatusBean: NetStatusBean): void {
    try {
      const context = this.createCurrentResourceContext();
      this.resourceContextById.set(resourceId, context);
      const collectType = this.checkSessionWillCollect(context.sessionId);
      this.submitResourceWorkerCommand({
        commandType: 'add',
        resourceId,
        context,
        params: this.createResourceParamsDTO(resourceId, params),
        netStatus: this.createResourceNetStatusDTO(netStatusBean),
        eventTime: Utils.getCurrentNanoTime(),
        shouldCollect: collectType !== CollectType.DROP,
        customDataType: this.getResourceCustomDataType(collectType),
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.add');
      this.markResourceContentSubmitted(resourceId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding resource data for ${resourceId}: ${error}`);
    }
  }

  /**
   * Set resource content
   * Set transform content implementation
   * 
   * @param resourceId Resource ID
   * @param params Resource parameters
   */
  public setTransformContent(resourceId: string, params: ResourceParams): void {
    try {
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext();
      this.resourceContextById.set(resourceId, context);
      const collectType = this.checkSessionWillCollect(context.sessionId);
      this.submitResourceWorkerCommand({
        commandType: 'setContent',
        resourceId,
        context,
        params: this.createResourceParamsDTO(resourceId, params),
        eventTime: Utils.getCurrentNanoTime(),
        shouldCollect: collectType !== CollectType.DROP,
        customDataType: this.getResourceCustomDataType(collectType),
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.content');
      this.markResourceContentSubmitted(resourceId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error setting transform content for ${resourceId}: ${error}`);
    }
  }

  /**
   * Convert request headers Map to string
   */
  private convertHeadersToString(headerMap: Map<string, string[]>): string {
    if (!headerMap || headerMap.size === 0) {
      return "";
    }

    const lines: string[] = [];
    const headerKeys = Array.from(headerMap.keys());
    for (let i = 0; i < headerKeys.length; i++) {
      const key = headerKeys[i];
      const values = headerMap.get(key);
      if (values && values.length > 0) {
        lines.push(`${key}: ${values.join(', ')}`);
      }
    }
    return lines.join('\n');
  }

  /**
   * Set network status
   */
  public setNetState(resourceId: string, netStatusBean: NetStatusBean): void {
    try {
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext();
      this.resourceContextById.set(resourceId, context);
      this.submitResourceWorkerCommand({
        commandType: 'setNetState',
        resourceId,
        context,
        netStatus: this.createResourceNetStatusDTO(netStatusBean),
        eventTime: Utils.getCurrentNanoTime(),
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.net');
    } catch (error) {
      FTInnerLogger.e(TAG, `Error setting network status for ${resourceId}: ${error}`);
    }
  }
  
  
  // Private method implementation
  
  /**
   * Update view history list
   */
  private updateViewList(viewName: string): void {
    if (this.viewList.length === 0 || this.viewList[this.viewList.length - 1] !== viewName) {
      this.viewList.push(viewName);
      if (this.viewList.length > 2) {
        this.viewList.shift(); // Only keep the latest 2 views
      }
    }
  }
  
  /**
   * Get previous view name
   */
  private getLastView(): string {
    if (this.viewList.length > 1) {
      return this.viewList[this.viewList.length - 2] || Constants.VIEW_NAME_ROOT;
    }
    return Constants.VIEW_NAME_ROOT;
  }
  
  /**
   * Create view - record page load time
   * Aligned with Android: FTRUMInnerManager.onCreateView(String viewName, long loadTime)
   * 
   * @param viewName View name
   * @param loadTime Load time in nanoseconds
   */
  public onCreateView(viewName: string, loadTime: number): void {
    if (viewName && viewName.length > 0 && loadTime > 0) {
      this.preActivityDuration.set(viewName, loadTime);
      FTInnerLogger.d(TAG, `onCreateView: recorded load time for ${viewName}: ${loadTime / 1000000}ms (${loadTime}ns)`);
      
      // If activeView already exists, update it with the recorded loadTime
      // This handles the case where startView is called before onCreateView (e.g., manual startView calls)
      // Also handles the case where startView is called multiple times (e.g., navigation tracker + manual call)
      // Aligned with Android: onCreateView updates loadTime if view already exists
      if (this.activeView && this.activeView.getViewName() === viewName) {
        // Always update loadTime if activeView exists, even if it's not -1
        // This ensures loadTime is preserved even if startView is called multiple times
        const oldLoadTime = this.activeView.getLoadTime();
        this.activeView.setLoadTime(loadTime);
        FTInnerLogger.d(TAG, `onCreateView: updated activeView loadTime for ${viewName}: ${oldLoadTime}ns -> ${loadTime}ns (${loadTime / 1000000}ms)`);
      }
    } else {
      FTInnerLogger.w(TAG, `onCreateView: invalid parameters, viewName=${viewName}, loadTime=${loadTime}`);
    }
  }

  /**
   * Get view load time
   */
  private getViewLoadTime(viewName: string): number {
    // Prefer resume time
    const resumeKey = `${viewName}_resume`;
    if (this.preActivityDuration.has(resumeKey)) {
      const loadTime = this.preActivityDuration.get(resumeKey)!;
      this.preActivityDuration.delete(resumeKey);
      FTInnerLogger.d(TAG, `Using resume time for ${viewName}: ${loadTime / 1000}ms`);
      return loadTime;
    }
    
    // Fallback to onCreate time
    if (this.preActivityDuration.has(viewName)) {
      const loadTime = this.preActivityDuration.get(viewName)!;
      this.preActivityDuration.delete(viewName);
      FTInnerLogger.d(TAG, `Using create time for ${viewName}: ${loadTime / 1000}ms`);
      return loadTime;
    }
    
    return -1;
  }
  
  /**
   * Check session refresh
   */
  /**
   * Check reset session_id
   * Aligned with Android: FTRUMInnerManager.checkSessionRefresh(boolean checkRefreshView)
   * 
   * @param checkRefreshView Whether to refresh view when session is refreshed (aligned with Android)
   */
  private checkSessionRefresh(checkRefreshView: boolean): void {
    // Use Promise-based lock to ensure thread-safe session refresh
    // Prevents race condition where multiple threads generate different sessionIds simultaneously
    this.sessionRefreshLock = this.sessionRefreshLock.then(() => {
      return this.doCheckSessionRefresh(checkRefreshView);
    }).catch((error: Error) => {
      FTInnerLogger.e(TAG, `[FT-SESSION-REFRESH] Error in sessionRefreshLock: ${error}`);
    });
  }

  /**
   * Internal method to perform session refresh check
   * This method is called within the sessionRefreshLock to ensure thread safety
   */
  private async doCheckSessionRefresh(checkRefreshView: boolean): Promise<void> {
    const now = Utils.getCurrentNanoTime(); // Use nanoseconds (aligned with Android)
    const longResting = now - this.lastUserActiveTime > FTRUMInnerManager.MAX_RESTING_TIME;
    const longTimeSession = now - this.lastSessionTime > FTRUMInnerManager.SESSION_EXPIRE_TIME;
    
    if (longTimeSession || longResting) {
      this.lastSessionTime = now;
      const oldSessionId = this.sessionId;
      this.sessionId = Utils.generateUUID();
      
      FTInnerLogger.d(TAG, `Session Track -> New SessionId: ${this.sessionId}, longTimeSessionReset: ${longTimeSession}`);
      
      // Recalculate sampling rate
      this.checkSessionKeep(this.sessionId, this.sampleRate, this.sessionErrorSampleRate);
      
      // Update activeView's session ID in memory if it exists and is not closed
      // This ensures that when the view is closed later, it uses the new session ID
      // This is critical when checkRefreshView is false (e.g., from timer)
      // IMPORTANT: We do NOT modify existing data in database (preserve historical data)
      if (this.activeView && !this.activeView.isClose()) {
        const currentViewSessionId = this.activeView.getSessionId();
        if (currentViewSessionId === oldSessionId) {
          // Update the session ID of activeView in memory
          // When this view is closed later, convertToViewBean() will use the new session ID
          this.activeView.setSessionId(this.sessionId);
          FTInnerLogger.d(TAG, `Updated activeView session ID in memory: ${oldSessionId} -> ${this.sessionId}, viewId: ${this.activeView.getId()}, viewName: ${this.activeView.getViewName()}`);
        }
      }
      
      // Refresh view if needed (aligned with Android)
      if (checkRefreshView) {
        if (this.activeView && !this.activeView.isClose()) {
          this.activeView.close();
          // closeView will use activeView's session ID (which may have been updated above)
          // If view was already in database with old session ID, closeView will update it with new session ID
          await this.closeView(this.activeView);
          
          const viewName = this.activeView.getViewName();
          const viewReferrer = this.activeView.getViewReferrer();
          const property = this.activeView.getProperty();
          const loadTime = this.activeView.getLoadTime();
          
          // Create new view with new session ID
          this.activeView = new ActiveViewBean(viewName, viewReferrer, loadTime, this.sessionId);
          if (property && Object.keys(property).length > 0) {
            // Use addProperty to add each property individually (aligned with Android's putAll behavior)
            const propertyKeys = Object.keys(property);
            for (let i = 0; i < propertyKeys.length; i++) {
              const key = propertyKeys[i];
              const value = (property as Record<string, object>)[key];
              this.activeView.addProperty(key, value);
            }
          }
          this.activeView.setCollectType(this.checkSessionWillCollect(this.sessionId));
          // FTMonitorManager.getInstance().addMonitor(this.activeView.getId());
          FTMonitorManager.getInstance().attachMonitorData(this.activeView);
          this.initView(this.activeView);
          
          FTInnerLogger.d(TAG, `Session Track -> checkRefreshView sessionId: ${this.activeView.getSessionId()}, viewId: ${this.activeView.getId()}`);
        }
      }

      // Save RUM context to preferences for crash recovery
      this.saveRumContext();
    }
  
    // As long as there is RUM data collection activity, the user time will be extended, including background
    // Aligned with Android: always update lastUserActiveTime (not just for user actions)
    this.lastUserActiveTime = now;
  }
  
  
  /**
   * Check if action needs to be closed
   */
  private checkActionClose(): void {
    if (!this.activeAction) {
      return;
    }
    

    // Use nanoseconds to match ActiveActionBean.getStartTime() (aligned with Android)
    const now = Utils.getCurrentNanoTime();
    const lastActionTime = this.activeAction.getStartTime();
    const waiting = this.activeAction.isNeedWaitAction() && 
                   (this.activeView && !this.activeView.isClose());
    
    // Check timeout: 5 seconds timeout (ACTION_NEED_WAIT_TIME_OUT) - aligned with Android
    const timeOut = now - lastActionTime > ActiveActionBean.ACTION_NEED_WAIT_TIME_OUT;

    const viewChanged = this.activeView && 
                       !(this.activeView.getId().localeCompare(this.activeAction.getViewId()) === 0);


    // Aligned with Android SDK logic (see FTRUMInnerManager.java:277-292):
    // - If waiting (needWaitAction && view not closed), action waits
    // - If has pending resource and not timeout, action waits (checked in closeAction via database)
    // - Otherwise, check normal timeout (100ms), timeout (5s), or view changed
    const needClose = (!waiting && 
                      (now - lastActionTime >= ActiveActionBean.ACTION_NORMAL_TIME_OUT)) ||
                     timeOut || viewChanged;
    
    if (needClose && !this.activeAction.isActionClose()) {
      this.activeAction.close();
      // Pass timeout flag to closeAction: if timeout, force=true; otherwise, force=false (will check pending_resource in database)
      this.closeAction(this.activeAction, timeOut);
    }
  }
  
  /**
   * Schedule action check
   */
  private scheduleActionCheck(): void {
    if (this.actionCheckTimer) {
      clearTimeout(this.actionCheckTimer);
    }
    
    // Schedule auto-close at exactly 5000ms
    const delayMs = 5000;
    this.actionCheckTimer = setTimeout(() => {
      this.checkActionClose();
    }, delayMs);
  }
  
  /**
   * Initialize session timer
   */
  private initSessionTimer(): void {
    this.sessionCheckTimer = setInterval(() => {
      this.checkSessionRefresh(false);
      // Clean up Set collections periodically to prevent memory leak
      this.cleanupSetCollections();
    }, 60000); // Check session every minute
  }
  
  /**
   * Clean up Set collections to prevent memory leak
   * Clear Sets if they exceed MAX_SET_SIZE limit
   */
  private cleanupSetCollections(): void {
    try {
      // Clean up processedActionIds
      if (this.processedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `processedActionIds size (${this.processedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.processedActionIds.clear();
      }
      
      // Clean up insertedActionIds
      if (this.insertedActionIds.size > Constants.MAX_SET_SIZE_ACTION) {
        FTInnerLogger.w(TAG, `insertedActionIds size (${this.insertedActionIds.size}) exceeds limit, clearing to prevent memory leak`);
        this.insertedActionIds.clear();
      }
      
      // Clean up preActivityDuration (Map type, use MAX_MAP_SIZE_RESOURCE)
      if (this.preActivityDuration.size > Constants.MAX_MAP_SIZE_RESOURCE) {
        FTInnerLogger.w(TAG, `preActivityDuration size (${this.preActivityDuration.size}) exceeds limit, clearing to prevent memory leak`);
        this.preActivityDuration.clear();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error during Set collection cleanup: ${error}`);
    }
  }
  
  /**
   * Initialize view
   */
  private initView(activeViewBean: ActiveViewBean): void {
    const viewBean = activeViewBean.convertToViewBean();
    
    if (this.context) {
      this.initViewAsync(this.context, viewBean);
    }
  }

  private async initViewAsync(context: Context, viewBean: ViewBean): Promise<void> {
    try {
      const result = await FTDBTaskPoolExecutor.upsertRumView(context, viewBean);
      if (result) {
        FTInnerLogger.d(TAG, `View initialized in database successfully`);
      } else {
        FTInnerLogger.e(TAG, `View initialization in database failed`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Error in initView DB taskpool: ${errorMessage}`);
    }
  }

  /**
   * Close view
   */
  private async closeView(activeViewBean: ActiveViewBean): Promise<void> {
    try {
      // Remove monitor first
      FTMonitorManager.getInstance().removeMonitor(activeViewBean.getId());
      
      // Convert to ViewBean to get closure data
      // This will use activeViewBean's current session ID (which may have been updated if session refreshed)
      const viewBean = activeViewBean.convertToViewBean();
      const viewId = viewBean.getId();
      const viewSessionId = viewBean.getSessionId(); // Get session ID from activeViewBean (may be updated)
      const timeSpent = viewBean.getTimeSpent();
      const loadTime = viewBean.getViewLoadTime();
      const attr = viewBean.getAttrJsonString();
      
      // Close view in database (aligned with Android)
      // IMPORTANT: Android SDK's closeView() only updates is_close, view_time_spent, view_load_time, extra_attr
      // It does NOT update action_count, error_count, resource_count, long_task_count
      // These count fields are kept accurate through atomic SQL updates (increaseViewAction, etc.)
      // This approach avoids race conditions where async count updates might overwrite correct values
      if (this.context) {
        try {
          // Aligned with Android: closeView only updates closure-related fields, not count fields
          // Count fields (action_count, error_count, etc.) are maintained by atomic SQL updates
          // Update session_id if it differs from what's in database (e.g., session refreshed after view started)
          // This ensures the closed view uses the current session ID from activeViewBean
          await FTDBTaskPoolExecutor.closeRumView(this.context, viewId, loadTime, timeSpent, attr, viewSessionId);
          // Aligned with Android: updateViewUpdateTime increments view_update_time counter
          await FTDBTaskPoolExecutor.updateViewUpdateTime(this.context, viewId);
          FTInnerLogger.d(
            TAG,
            `closeView persisted: ${activeViewBean.getViewName()}, viewId=${viewId}, sessionId=${viewSessionId}, timeSpent=${timeSpent}, loadTime=${loadTime}, updateTime=${viewBean.getViewUpdateTime()}`
          );
          
          // Schedule a delayed task to force clear pending_resource if it's still > 0 after 30 seconds
          // This handles cases where resources never complete (e.g., network failures, timeouts)
          // After view is closed, wait 30 seconds for resources to complete, then force clear pending_resource
          // This allows cleanCloseViewData to delete the view data
          if (this.context) {
            setTimeout(() => {
              (async () => {
                try {
                  // Check if view still has pending_resource > 0
                  const viewPendingResource = await FTDBTaskPoolExecutor.getRumPendingResource(
                    this.context!,
                    'view',
                    viewId
                  );
                  if (viewPendingResource > 0) {
                    FTInnerLogger.w(TAG, `View ${viewId} still has pending_resource=${viewPendingResource} after 30 seconds, forcing clear to allow cleanup`);
                    // Force clear pending_resource to allow cleanCloseViewData to delete the view
                    await FTDBTaskPoolExecutor.forceClearRumPendingResource(this.context!, 'view', viewId);
                  }
                } catch (error) {
                  FTInnerLogger.e(TAG, `Error checking/clearing pending_resource for view ${viewId}: ${error}`);
                }
              })();
            }, 30 * 1000); // 30 seconds delay
          }
        } catch (error) {
          FTInnerLogger.e(TAG, `Error closing view in database: ${error}`);
        }
      }
      
      // Generate RUM data (aligned with Android)
      // This will call generateViewSum() which queries from database with latest view_update_time
      // Note: Android also calls generateRumData() immediately without waiting for database write
      // The 100ms debounce in generateRumData() gives time for database writes to complete
      this.generateRumData();
      FTInnerLogger.d(TAG, `closeView scheduled generateRumData: ${activeViewBean.getViewName()}`);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error closing view: ${error}`);
    }
  }
  
  /**
   * Initialize action
   * SDK implementation:
   * - startAction: First enters FT_TABLE_ACTION, then enters FT_SYNC_DATA_FLAT_TABLE_NAME
   * - addAction: Directly enters FT_SYNC_DATA_FLAT_TABLE_NAME
   */
  private initAction(activeActionBean: ActiveActionBean, isAddAction: boolean): void {
    const actionBean = activeActionBean.convertToActionBean();
    const actionName = activeActionBean.getActionName();
    
    if (isAddAction) {
      // addAction: Directly enters FT_SYNC_DATA_FLAT_TABLE_NAME
      this.increaseActionCount(actionBean.getViewId());
      this.submitCompletedActionWorkerInput(actionBean, `rum.addAction:${actionName}`);
    } else {
      // Increase action count
      this.increaseActionCount(actionBean.getViewId());
      // startAction: First stores to FT_TABLE_ACTION, then enters FT_SYNC_DATA_FLAT_TABLE_NAME after closing
      if (this.context) {
        this.insertRumActionAsync(this.context, actionBean, actionName);
      } else {
        FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-4] Context not available for startAction: ${actionName}`);
      }
    }
  }

  private async insertRumActionAsync(context: Context, actionBean: ActionBean, actionName: string): Promise<void> {
    try {
      const result = await FTDBTaskPoolExecutor.insertRumAction(context, actionBean);
      if (!result) {
        FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-5] startAction insertion failed: ${actionName}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-ERROR] Error in RUM DB taskpool: ${errorMessage}`);
    }
  }
  
  
  /**
   * Close action
   */
  private closeAction(activeActionBean: ActiveActionBean, isTimeout: boolean): void {
    try {
      const actionBean = activeActionBean.convertToActionBean();

      // Close action in database asynchronously, then generate RUM data after completion
      // This ensures the action is written to database before querying
      // Aligned with Android: if timeout, force=true; otherwise, force=false (will check pending_resource in database)
      if (this.context) {
        this.closeRumActionAsync(this.context, actionBean, isTimeout);
      } else {
        // If no context, still try to generate RUM data (may have other actions to process)
        this.generateRumData();
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-CLOSE-ERROR] Error closing action: ${error}`);
    }
  }

  private async closeRumActionAsync(context: Context, actionBean: ActionBean, isTimeout: boolean): Promise<void> {
    try {
      await FTDBTaskPoolExecutor.closeRumAction(
        context,
        actionBean.getId(),
        actionBean.getDuration(),
        isTimeout
      );
      // Generate RUM data after action is closed in database.
      this.generateRumData();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-CLOSE-ERROR] Error closing action in database: ${errorMessage}`);
      // Still try to generate RUM data even if closeAction failed.
      this.generateRumData();
    }
  }
  
  /**
   * Attach RUM relative information to tags
   * Attach RUM relative
   * 
   * @param tags Tags to attach RUM information to
   * @param isUserAction Whether this is a user action
   */
  public attachRUMRelative(tags: Record<string, string>, isUserAction: boolean): void {
    // Associate current view and action
    // Aligned with Android SDK: only set actionId if activeAction exists and is not closed
    // Android SDK logic: if (withAction) { if (activeAction != null && !activeAction.isClose()) { ... } }
    if (isUserAction) {
      if (this.activeAction && !this.activeAction.isActionClose()) {
        tags[Constants.KEY_RUM_ACTION_ID] = this.activeAction.getId();
        tags[Constants.KEY_RUM_ACTION_NAME] = this.activeAction.getActionName();
      }
    }
    
    if (this.activeView) {
      tags[Constants.KEY_RUM_VIEW_ID] = this.activeView.getId();
      tags[Constants.KEY_RUM_VIEW_NAME] = this.activeView.getViewName();
      tags[Constants.KEY_RUM_VIEW_REFERRER] = this.activeView.getViewReferrer();
    }
    
    tags[Constants.KEY_RUM_SESSION_ID] = this.sessionId;
  }

  /**
   * Associate RUM context for resource
   */
  private attachRUMRelativeForResource(resourceBean: ResourceBean): void {
    const sessionId = this.sessionId;
    const viewId = this.activeView?.getId() || "";
    const viewName = this.activeView?.getViewName() || "";
    const viewReferrer = this.activeView?.getViewReferrer() || "";
    
    // Aligned with Android SDK: only set actionId if activeAction exists and is not closed
    // Android SDK logic: if (activeAction != null && !activeAction.isClose()) { bean.actionId = getActionId(); }
    // If action is closed or doesn't exist, preserve existing actionId in ResourceBean (don't overwrite with empty string)
    let actionId = resourceBean.actionId || ""; // Preserve existing actionId if action is closed
    let actionName = resourceBean.actionName || ""; // Preserve existing actionName if action is closed
    if (this.activeAction && !this.activeAction.isActionClose()) {
      actionId = this.activeAction.getId();
      actionName = this.activeAction.getActionName();
      FTInnerLogger.d(TAG, `attachRUMRelativeForResource: Setting actionId=${actionId}, actionName=${actionName} for resource`);
    } else {
      FTInnerLogger.d(TAG, `attachRUMRelativeForResource: No activeAction or action is closed, preserving existing actionId=${actionId}. activeAction=${this.activeAction ? 'exists' : 'null'}, isActionClose=${this.activeAction ? this.activeAction.isActionClose() : 'N/A'}`);
    }
    
    resourceBean.setRUMContext(sessionId, viewId, viewName, viewReferrer, actionId, actionName);
    resourceBean.hasSessionReplay = this.activeView?.isHasReplay() || false;
  }
  
  
  /**
   * Add resource error
   * Aligned with Android SDK: FTRUMInnerManager.putRUMResourcePerformance() generates error data for HTTP errors
   */
  private addResourceError(resourceBean: ResourceBean, time: number, collectType: CollectType, resourceTags: Record<string, string>): void {
    try {
      // Aligned with Android SDK: set error timeline for error sampling
      // This enables collection of data within 1 minute before and after the error
      if (this.activeView) {
        const viewBean = this.activeView.convertToViewBean();
        SyncTaskManager.getInstance().setErrorTimeLine(time, viewBean);
      } else {
        SyncTaskManager.getInstance().setErrorTimeLine(time, null);
      }
      
      // Build error tags (aligned with Android SDK)
      // Merge with global RUM context and dynamic tags (aligned with putRUMResourcePerformance)
      const errorTags: Record<string, string> = {};
      
      // Layer 2: Dynamic tags (network_type, user info, etc.)
      const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      const dynamicKeys = Object.keys(dynamicTags);
      for (let i = 0; i < dynamicKeys.length; i++) {
        const key = dynamicKeys[i];
        errorTags[key] = dynamicTags[key];
      }
      
      const errorFields: Record<string, string> = {};
      
      // Set error type and source (aligned with Android)
      errorTags[Constants.KEY_RUM_ERROR_TYPE] = String(ErrorType.NETWORK);
      errorTags[Constants.KEY_RUM_ERROR_SOURCE] = String(ErrorSource.NETWORK);
      // Get app state from activeView if available (aligned with Android: FTActivityManager.get().getAppState())
      const appState = this.activeView ? AppState.RUN : AppState.UNKNOWN;
      errorTags[Constants.KEY_RUM_ERROR_SITUATION] = String(appState);
      
      // Set RUM association (aligned with Android)
      errorTags[Constants.KEY_RUM_ACTION_ID] = resourceBean.actionId || "";
      errorTags[Constants.KEY_RUM_ACTION_NAME] = resourceBean.actionName || "";
      errorTags[Constants.KEY_RUM_VIEW_ID] = resourceBean.viewId || "";
      errorTags[Constants.KEY_RUM_VIEW_NAME] = resourceBean.viewName || "";
      errorTags[Constants.KEY_RUM_VIEW_REFERRER] = resourceBean.viewReferrer || "";
      errorTags[Constants.KEY_RUM_SESSION_ID] = resourceBean.sessionId || "";
      
      // Set resource error information (aligned with Android)
      const resourceStatus = resourceBean.resourceStatus;
      errorTags[Constants.KEY_RUM_RESOURCE_STATUS] = String(resourceStatus);
      if (resourceStatus > 0) {
        errorTags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = resourceBean.getResourceStatusGroup();
      }
      errorTags[Constants.KEY_RUM_RESOURCE_URL] = resourceBean.url || "";
      errorTags[Constants.KEY_RUM_RESOURCE_URL_HOST] = resourceBean.urlHost || "";
      errorTags[Constants.KEY_RUM_RESOURCE_METHOD] = resourceBean.resourceMethod || "";
      
      // Set resource URL path if available (aligned with Android)
      if (resourceBean.urlPath && resourceBean.urlPath.length > 0) {
        errorTags[Constants.KEY_RUM_RESOURCE_URL_PATH] = resourceBean.urlPath;
        // Generate path group (aligned with Android: replaceAll("\\/([^\\/]*)\\d([^\\/]*)", "/?"))
        let urlPathGroup = resourceBean.urlPath;
        if (urlPathGroup && urlPathGroup.length > 0) {
          urlPathGroup = urlPathGroup.replace(/\/([^\/]*)\d([^\/]*)/g, '/?');
        }
        errorTags[Constants.KEY_RUM_RESOURCE_URL_PATH_GROUP] = urlPathGroup;
      }
      
      // Build error message (aligned with Android format: "[status][:errorMsg]" + "[" + url + "]")
      const localErrorMsg = (resourceBean.errorMsg && resourceBean.errorMsg.length > 0) ? `:${resourceBean.errorMsg}` : "";
      const errorMsg = `[${resourceStatus}${localErrorMsg}][${resourceBean.url || ""}]`;
      errorFields[Constants.KEY_RUM_ERROR_MESSAGE] = errorMsg;
      
      // Set error stack (aligned with Android)
      if (resourceBean.errorStack) {
        errorFields[Constants.KEY_RUM_ERROR_STACK] = resourceBean.errorStack;
      }
      
      // Send error data with callback to increase error count (aligned with Android)
      // Create callback class to implement RunnerCompleteCallBack interface (ArkTS requirement)
      const self = this;
      class ResourceErrorCallback implements RunnerCompleteCallBack {
        onComplete(): void {
          // Increase error count (aligned with Android: increaseError(tags))
          // Use resourceTags (from putRUMResourcePerformance) to increase error count
          // increaseError accepts Record<string, string>, not Map<string, string>
          self.increaseError(resourceTags);
        }
      }
      
      FTTrackInner.getInstance().rumRecords(
        time,
        Constants.FT_MEASUREMENT_RUM_ERROR,
        errorTags,
        errorFields,
        new ResourceErrorCallback(),
        collectType
      );
      
      FTInnerLogger.d(TAG, `Resource error data sent: status=${resourceStatus}, url=${resourceBean.url}`);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding resource error: ${error}`);
    }
  }

  /**
   * Process resource performance data and send to FTTrackInner
   * @param resourceId Resource ID
   */
  private putRUMResourcePerformance(resourceId: string): void {
    try {
      const resourceBean = this.resourceBeanMap.get(resourceId);
      if (!resourceBean) {
        FTInnerLogger.w(TAG, `putRUMResourcePerformance: Resource not found: ${resourceId}`);
        return;
      }

      // Check if this resource is already being processed (prevent duplicate uploads)
      if (resourceBean.isProcessing) {
        FTInnerLogger.d(TAG, `<FT-RESOURCE-UPLOAD> Resource ${resourceId} is already being processed, skipping duplicate call`);
        return;
      }

      // Mark as processing to prevent concurrent calls
      resourceBean.isProcessing = true;

      FTInnerLogger.d(TAG, `<FT-RESOURCE-UPLOAD> Processing resource performance: ${resourceId}`);
      
      const time = Utils.getCurrentNanoTime(); // Use nanoseconds (19 digits)
      
      // Build Resource-specific data structures
      const resourceTags = this.buildResourceTags(resourceBean);
      
      // Merge with global RUM context and dynamic tags
      const allTags: Record<string, string> = {};
      
      const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      const dynamicKeys = Object.keys(dynamicTags);
      for (let i = 0; i < dynamicKeys.length; i++) {
        const key = dynamicKeys[i];
        allTags[key] = dynamicTags[key];
      }
      
      // Layer 3: RUM association (session, view, action)
      // Aligned with Android SDK: use actionId stored in ResourceBean (set at startResource time)
      // Android SDK logic: String actionId = bean.actionId; tags.put(Constants.KEY_RUM_ACTION_ID, actionId);
      // We don't re-check activeAction here because the actionId was already set when resource started
      allTags[Constants.KEY_RUM_SESSION_ID] = resourceBean.sessionId;
      allTags[Constants.KEY_RUM_VIEW_ID] = resourceBean.viewId;
      allTags[Constants.KEY_RUM_VIEW_NAME] = resourceBean.viewName;
      allTags[Constants.KEY_RUM_VIEW_REFERRER] = resourceBean.viewReferrer;
      // Use actionId stored in ResourceBean (set at startResource time via attachRUMRelativeForResource)
      if (resourceBean.actionId) {
        allTags[Constants.KEY_RUM_ACTION_ID] = resourceBean.actionId;
        FTInnerLogger.d(TAG, `putRUMResourcePerformance: Using actionId=${resourceBean.actionId} from ResourceBean`);
      } else {
        FTInnerLogger.w(TAG, `putRUMResourcePerformance: ResourceBean.actionId is empty for resource ${resourceId}`);
      }
      if (resourceBean.actionName) {
        allTags[Constants.KEY_RUM_ACTION_NAME] = resourceBean.actionName;
      }
      
      // Layer 4: Resource-specific tags
      // Manually add each resource tag to avoid indexed access
      if (resourceTags.resource_url) allTags[Constants.KEY_RUM_RESOURCE_URL] = resourceTags.resource_url;
      if (resourceTags.resource_url_host) allTags[Constants.KEY_RUM_RESOURCE_URL_HOST] = resourceTags.resource_url_host;
      if (resourceTags.resource_url_path) allTags[Constants.KEY_RUM_RESOURCE_URL_PATH] = resourceTags.resource_url_path;
      if (resourceTags.resource_url_path_group) allTags[Constants.KEY_RUM_RESOURCE_URL_PATH_GROUP] = resourceTags.resource_url_path_group;
      if (resourceTags.resource_method) allTags[Constants.KEY_RUM_RESOURCE_METHOD] = resourceTags.resource_method;
      if (resourceTags.resource_type) allTags[Constants.KEY_RUM_RESOURCE_TYPE] = resourceTags.resource_type;
      if (resourceTags.resource_status) allTags[Constants.KEY_RUM_RESOURCE_STATUS] = resourceTags.resource_status;
      if (resourceTags.resource_status_group) allTags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = resourceTags.resource_status_group;
      // Optional extended tags
      if (resourceTags.resource_host_ip) allTags[Constants.KEY_RUM_RESOURCE_HOST_IP] = resourceTags.resource_host_ip;
      if (resourceTags.response_connection) allTags[Constants.KEY_RUM_RESPONSE_CONNECTION] = resourceTags.response_connection;
      if (resourceTags.response_content_type) allTags[Constants.KEY_RUM_RESPONSE_CONTENT_TYPE] = resourceTags.response_content_type;
      if (resourceTags.response_content_encoding) allTags[Constants.KEY_RUM_RESPONSE_CONTENT_ENCODING] = resourceTags.response_content_encoding;
      if (resourceTags.trace_id) allTags[Constants.KEY_RUM_RESOURCE_TRACE_ID] = resourceTags.trace_id;
      if (resourceTags.span_id) allTags[Constants.KEY_RUM_RESOURCE_SPAN_ID] = resourceTags.span_id;
      
      // Build resource fields using Record<string, string> with constants (aligned with action/error implementation)
      const allFields: Record<string, string> = this.buildResourceFields(resourceBean);
      
      // Log the time to verify it's nanoseconds (should be 19 digits)
      FTInnerLogger.d(TAG, `<FT-RESOURCE-UPLOAD> Using nanosecond timestamp: ${time}`);
      
      // Decide collect type once (aligned with Android: resource & its error use same collectType)
      const collectType = this.checkSessionWillCollect(resourceBean.sessionId);

      // Send resource data
      FTTrackInner.getInstance().rumRecords(
        time,
        Constants.FT_MEASUREMENT_RUM_RESOURCE,
        allTags,
        allFields,
        null,
        collectType
      );
      
      FTInnerLogger.d(TAG, `<FT-RESOURCE-UPLOAD> Resource performance data sent successfully: ${resourceId}`);
      
      // Aligned with Android SDK: generate error data for HTTP error status codes (>= 400)
      // Android logic: if (bean.resourceStatus >= HttpsURLConnection.HTTP_BAD_REQUEST || (bean.resourceStatus == 0 && !Utils.isNullOrEmpty(bean.errorStack)))
      const resourceStatus = resourceBean.resourceStatus;
      if (resourceStatus >= 400 || (resourceStatus === 0 && resourceBean.errorStack && resourceBean.errorStack.length > 0)) {
        FTInnerLogger.d(TAG, `<FT-RESOURCE-ERROR> Generating error data for resource ${resourceId}, status=${resourceStatus}`);
        // Build resourceTags for error callback (to increase error count)
        const resourceTagsForError: Record<string, string> = {};
        if (allTags[Constants.KEY_RUM_ACTION_ID]) resourceTagsForError[Constants.KEY_RUM_ACTION_ID] = allTags[Constants.KEY_RUM_ACTION_ID];
        if (allTags[Constants.KEY_RUM_ACTION_NAME]) resourceTagsForError[Constants.KEY_RUM_ACTION_NAME] = allTags[Constants.KEY_RUM_ACTION_NAME];
        if (allTags[Constants.KEY_RUM_VIEW_ID]) resourceTagsForError[Constants.KEY_RUM_VIEW_ID] = allTags[Constants.KEY_RUM_VIEW_ID];
        if (allTags[Constants.KEY_RUM_VIEW_NAME]) resourceTagsForError[Constants.KEY_RUM_VIEW_NAME] = allTags[Constants.KEY_RUM_VIEW_NAME];
        if (allTags[Constants.KEY_RUM_SESSION_ID]) resourceTagsForError[Constants.KEY_RUM_SESSION_ID] = allTags[Constants.KEY_RUM_SESSION_ID];
        // Call addResourceError to generate error data (aligned with Android SDK)
        this.addResourceError(resourceBean, time, collectType, resourceTagsForError);
      }
      
      // Aligned with Android SDK: putRUMResourcePerformance does NOT decrease pending_resource_count
      // Pending count is already decreased in stopResource (see stopResource method)
      // This prevents double-decrement of pending_resource_count
      
      // Remove completed ResourceBean without submitting another EVENT lane task.
      // If addResource arrives before stopResource, keep the bean until stopResource
      // records the resource counters.
      if (resourceBean.endTime > 0) {
        this.resourceBeanMap.delete(resourceId);
        FTInnerLogger.d(TAG, `<FT-RESOURCE-UPLOAD> ResourceBean removed from map: ${resourceId}`);
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error processing resource performance for ${resourceId}: ${error}`);
    }
  }
  
  // Statistical counting methods
  
  /**
   * Increase action count
   */
  private increaseActionCount(viewId: string): void {
    // Update memory (aligned with Android: activeView.increaseActionCount())
    this.increaseActionCountInMemory(viewId);
    
    // Update database (aligned with Android: FTDBManager.get().increaseViewAction(viewId))
    // This ensures database is updated when action occurs, preventing duplicate view uploads
    if (this.context && viewId) {
      this.submitRumCounterUpdateTask({
        updateType: 'view.action',
        viewId
      });
    }
  }

  private increaseActionCountInMemory(viewId: string): void {
    if (this.activeView && this.activeView.getId() === viewId) {
      this.activeView.increaseActionCount();
    }
  }
  

  /**
   * Increase error count for tags
   * Increase error
   * 
   * @param tags Tags containing view and action information
   */
  private increaseError(tags: Record<string, string>): void {
    // This method is called after error data is sent
    // Updates the error count for the associated view/action
    // Aligned with Android: extract actionId and viewId from tags and update database directly
    const actionId = tags[Constants.KEY_RUM_ACTION_ID];
    const viewId = tags[Constants.KEY_RUM_VIEW_ID];
    
    // Update memory count if activeAction/activeView exists
    // This updates the in-memory count for immediate use
    if (this.activeView) {
      this.activeView.increaseErrorCount();
    }
    if (this.activeAction) {
      this.activeAction.increaseErrorCount();
    }
    
    if (this.context) {
      this.submitRumCounterUpdateTask({
        updateType: 'rum.error',
        viewId: viewId || '',
        actionId: actionId || ''
      });
    }
  }
  
  /**
   * Increase resource count
   * Aligned with Android: updates both memory and database
   */
  private increaseResourceCount(viewId: string, actionId: string): void {
    try {
      if (this.activeView && this.activeView.getId() === viewId) {
        this.activeView.increaseResourceCount();
        this.activeView.decreasePendingResourceCount();
        // Update database count (aligned with Android SDK)
      }
      if (this.activeAction && this.activeAction.getId() === actionId) {
        this.activeAction.decreasePendingResourceCount();
      }
      if (this.context) {
        this.submitRumCounterUpdateTask({
          updateType: 'resource.complete',
          viewId: viewId || '',
          actionId: actionId || ''
        });
      }
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error increasing resource count: ${error}`);
    }
  }
  
  /**
   * Increase pending resource count
   */
  private increasePendingResourceCount(viewId: string, actionId: string): void {
    // Update memory counts
    if (this.activeView && this.activeView.getId() === viewId) {
      this.activeView.increasePendingResourceCount();
    }
    
    if (this.activeAction && this.activeAction.getId() === actionId) {
      this.activeAction.increasePendingResourceCount();
    }
    
    // Update database counts through the batched RUM counter flush.
    if (this.context) {
      this.submitRumCounterUpdateTask({
        updateType: 'resource.pending.increase',
        viewId: viewId || '',
        actionId: actionId || ''
      });
    }
  }
  
  /**
   * Decrease pending resource count
   * Aligned with Android counter semantics; persisted through the batched RUM counter flush.
   */
  private decreasePendingResourceCount(viewId: string, actionId: string, updateView: boolean = true): void {
    // Update memory counts
    if (updateView && this.activeView && this.activeView.getId() === viewId) {
      this.activeView.decreasePendingResourceCount();
    }
    
    if (this.activeAction && this.activeAction.getId() === actionId) {
      this.activeAction.decreasePendingResourceCount();
    }
    
    // Update database counts through the batched RUM counter flush.
    if (this.context) {
      this.submitRumCounterUpdateTask({
        updateType: 'resource.pending.decrease',
        viewId: viewId || '',
        actionId: actionId || '',
        updateView
      });
    }
  }
  
  /**
   * Check session keep - Decide whether to collect Session based on sampling rate
   * @param sessionId Session ID
   * @param sampleRate Normal sampling rate
   * @param errorSampleRate Error sampling rate
   */
  private checkSessionKeep(sessionId: string, sampleRate: number, errorSampleRate: number): void {
    const result = SamplingUtils.checkSessionKeep(sessionId, sampleRate, errorSampleRate);
    
    if (!result.sessionCollect) {
      this.addSessionToFilter(this.notCollectArr, sessionId);
      
      if (!result.sessionErrorCollect) {
        this.addSessionToFilter(this.notSessionErrorCollectArr, sessionId);
      } else {
        // If error sampling is enabled, remove from notSessionErrorCollectArr if present
        this.removeSessionFromFilter(this.notSessionErrorCollectArr, sessionId);
      }
    } else {
      // Session is collected by normal sampling, remove from both filter lists
      this.removeSessionFromFilter(this.notCollectArr, sessionId);
      this.removeSessionFromFilter(this.notSessionErrorCollectArr, sessionId);
    }
  }

  /**
   * Add Session to filter list
   * @param sessionList Filter list
   * @param sessionId Session ID
   */
  private addSessionToFilter(sessionList: string[], sessionId: string): void {
    if (sessionList.includes(sessionId)) {
      return;
    }
    if (sessionList.length >= FTRUMInnerManager.SESSION_FILTER_CAPACITY) {
      sessionList.shift(); // Remove oldest Session ID
    }
    sessionList.push(sessionId);
  }

  /**
   * Remove all occurrences of a Session from a filter list
   * @param sessionList Filter list
   * @param sessionId Session ID
   */
  private removeSessionFromFilter(sessionList: string[], sessionId: string): void {
    let index = sessionList.indexOf(sessionId);
    while (index >= 0) {
      sessionList.splice(index, 1);
      index = sessionList.indexOf(sessionId);
    }
  }

  /**
   * Check if session needs to be collected
   */
  public checkSessionWillCollect(sessionId?: string): CollectType {
    const id = sessionId || this.sessionId;
    
    // Check if in error session not collect list first (aligned with Android)
    // If session is in notSessionErrorCollectArr, it means both normal sampling and error sampling failed
    if (this.notSessionErrorCollectArr.includes(id)) {
      return CollectType.DROP;
    }
    
    // Check if in not collect list (normal sampling failed, but error sampling may still work)
    // If session is in notCollectArr but NOT in notSessionErrorCollectArr, it can be collected by error sampling
    if (this.notCollectArr.includes(id)) {
      return CollectType.SAMPLING;
    }
    
    // Session is not in any filter list, collect normally
    return CollectType.ALL;
  }
  
  /**
   * Get current active view
   */
  public getActiveView(): ActiveViewBean | null {
    return this.activeView;
  }
  
  /**
   * Get current active action
   */
  public getActiveAction(): ActiveActionBean | null {
    return this.activeAction;
  }

  /**
   * Shutdown RUM manager
   */
  public async shutdown(): Promise<void> {
    try {
      // Clear timers
      if (this.actionCheckTimer) {
        clearTimeout(this.actionCheckTimer);
        this.actionCheckTimer = null;
      }
      
      if (this.sessionCheckTimer) {
        clearInterval(this.sessionCheckTimer);
        this.sessionCheckTimer = null;
      }

      if (this.rumGenerateTimer) {
        clearTimeout(this.rumGenerateTimer);
        this.rumGenerateTimer = null;
      }
      
      // Close current activities
      if (this.activeAction && !this.activeAction.isActionClose()) {
        this.activeAction.close();
        this.closeAction(this.activeAction, false);
      }
      
      if (this.activeView && !this.activeView.isClose()) {
        this.activeView.close();
        await this.closeView(this.activeView);
      }
      this.activeAction = null;
      this.activeView = null;
      
      // Clear resources
      this.resourceBeanMap.clear();
      this.viewList = [];
      this.notCollectArr = [];
      this.notSessionErrorCollectArr = [];
      this.preActivityDuration.clear();
      
      // Clear Set collections to prevent memory leak
      this.processedActionIds.clear();
      this.insertedActionIds.clear();

      // Clear rumDataGenerateTimer if exists
      if (this.rumDataGenerateTimer) {
        clearTimeout(this.rumDataGenerateTimer);
        this.rumDataGenerateTimer = null;
      }

      if (this.rumCounterFlushTimer) {
        clearTimeout(this.rumCounterFlushTimer);
        this.rumCounterFlushTimer = null;
      }
      if (this.rumCounterUpdateFlushTimer) {
        clearTimeout(this.rumCounterUpdateFlushTimer);
        this.rumCounterUpdateFlushTimer = null;
      }
      if (this.completedActionFlushTimer) {
        clearTimeout(this.completedActionFlushTimer);
        this.completedActionFlushTimer = null;
      }
      if (this.resourceCommandFlushTimer) {
        clearTimeout(this.resourceCommandFlushTimer);
        this.resourceCommandFlushTimer = null;
      }
      if (this.errorCommandFlushTimer) {
        clearTimeout(this.errorCommandFlushTimer);
        this.errorCommandFlushTimer = null;
      }
      this.flushErrorWorkerCommandBatch('rum.shutdown');
      this.flushResourceWorkerCommandBatch('rum.shutdown');
      this.flushCompletedActionWorkerBatch('rum.shutdown');
      this.submitRumCounterFlushTask();
      this.pendingResourceCommands = [];
      this.pendingErrorCommands = [];
      this.resourceContextById.clear();
      this.resourceContentSubmittedIds.clear();
      this.resourceStoppedIds.clear();

      this.context = null;
      this.userData = null;
      this.rumConfig = null;
      this.preferencesStore = null;
      this.preferencesInitialized = false;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error during shutdown: ${error}`);
    }
  }

  /**
   * Check if object has properties (alternative to Object.keys check)
   * @param obj Object to check
   * @returns Whether it has properties
   */
  private hasProperties(obj: Record<string, object>): boolean {
    try {
      const keys = FTRUMInnerManager.getObjectKeys(obj);
      return keys.length > 0;
    } catch (error) {
      return false;
    }
  }

  private async stopViewAfterErrorCallback(callBack: RunnerCompleteCallBack): Promise<void> {
    try {
      await this.stopView();
      FTInnerLogger.i(TAG, "View stopped after error, calling crash callback");
      callBack.onComplete();
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to stop view after error: ${error}`);
      callBack.onComplete();
    }
  }


  /**
   * Add long task
   * @param log Long task log/stack trace
   * @param duration Duration in nanoseconds
   * @param property Additional properties (optional)
   */
  public addLongTask(log: string, duration: number, property: Record<string, string | number | boolean> = {}): void {
    try {
      // Check session refresh
      this.checkSessionRefresh(true);
      
      // Check if session will collect data
      const collectType = this.checkSessionWillCollect(this.sessionId);
      if (collectType === CollectType.DROP) {
        return;
      }
      
      // Get current time
      let time = Utils.getCurrentNanoTime() - duration;
      
      // If longtask is associated with an active action, ensure its start_time >= action start_time
      // This prevents longtask from appearing to start before the action that triggered it
      if (this.activeAction && !this.activeAction.isActionClose()) {
        const actionStartTime = this.activeAction.getStartTime();
        // Ensure longtask start_time is not earlier than action start_time
        if (time < actionStartTime) {
          FTInnerLogger.w(TAG, `Longtask calculated start_time (${time}) is earlier than action start_time (${actionStartTime}), adjusting to action start_time`);
          time = actionStartTime;
        }
      }
      
      // Build LongTask-specific data structures
      const longTaskFieldsData = this.buildLongTaskFields(duration, log);
      
      const allTags: Record<string, string> = {};
      
      const dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      const dynamicKeys = Object.keys(dynamicTags);
      for (let i = 0; i < dynamicKeys.length; i++) {
        const key = dynamicKeys[i];
        allTags[key] = dynamicTags[key];
      }

      this.attachRUMRelative(allTags,true);
      // Aligned with Android SDK: only set actionId if activeAction exists and is not closed
      // Android SDK uses attachRUMRelative(tags, true) which checks: if (activeAction != null && !activeAction.isClose())
      if (this.activeAction && !this.activeAction.isActionClose()) {
        allTags[Constants.KEY_RUM_ACTION_ID] = this.activeAction.getId();
        allTags[Constants.KEY_RUM_ACTION_NAME] = this.activeAction.getActionName();
      }
      
      // Build all fields (aligned with Android field names)
      const allFields: Record<string, string> = {};
      if (longTaskFieldsData.duration) allFields[Constants.KEY_RUM_LONG_TASK_DURATION] = String(longTaskFieldsData.duration);
      if (longTaskFieldsData.long_task_stack) allFields[Constants.KEY_RUM_LONG_TASK_STACK] = longTaskFieldsData.long_task_stack;
      
      // Add property fields if provided
      if (property) {
        const propertyKeys = Object.keys(property);
        for (let i = 0; i < propertyKeys.length; i++) {
          const key = propertyKeys[i];
          allFields[key] = String(property[key]);
        }
      }
      
      // Send long task data
      FTTrackInner.getInstance().rumRecords(
        time,
        Constants.FT_MEASUREMENT_RUM_LONG_TASK,
        allTags,
        allFields,
        null,
        collectType
      );
      
      // Increase long task count
      // increaseLongTaskCount() will update database if activeAction/activeView exists
      this.increaseLongTaskCount();
      
      // Also update database directly using actionId/viewId from tags (only if action/view is closed)
      // This ensures counts are updated even for automatically closed actions
      // Note: If activeAction/activeView exists, increaseLongTaskCount() already updated the database,
      // so we only need to update if action/view is closed (not in memory)
      const actionId = allTags[Constants.KEY_RUM_ACTION_ID];
      const viewId = allTags[Constants.KEY_RUM_VIEW_ID];
      
      if (this.context && (actionId || viewId)) {
        const isActionActive: boolean = !!(actionId && actionId.length > 0 && this.activeAction &&
          this.activeAction.getId() === actionId);
        const isViewActive: boolean = !!(viewId && viewId.length > 0 && this.activeView &&
          this.activeView.getId() === viewId);
        if (!isActionActive || !isViewActive) {
          if (!isActionActive && actionId && actionId.length > 0) {
            this.submitRumCounterUpdateTask({
              updateType: 'long_task.action',
              actionId
            });
          }
          if (!isViewActive && viewId && viewId.length > 0) {
            this.submitRumCounterUpdateTask({
              updateType: 'long_task.view',
              viewId
            });
          }
        }
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding long task: ${error}`);
    }
  }

  /**
   * Increase long task count for current session
   * Aligned with Android: updates both memory and database
   */
  private increaseLongTaskCount(): void {
    try {
      if (this.activeView) {
        const viewId = this.activeView.getId();
        // Update memory count
        this.activeView.increaseLongTaskCount();
        // Update database count (aligned with Android SDK)
        if (this.context) {
          this.submitRumCounterUpdateTask({
            updateType: 'long_task.view',
            viewId
          });
        }
      }
      if (this.activeAction) {
        const actionId = this.activeAction.getId();
        // Update memory count
        this.activeAction.increaseLongTaskCount();
        // Update database count (aligned with Android SDK)
        if (this.context) {
          this.submitRumCounterUpdateTask({
            updateType: 'long_task.action',
            actionId
          });
        }
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error increasing long task count: ${error}`);
    }
  }

  /**
   * Check if resource is ready to be sent
   * Check to add resource implementation
   * 
   * @param resourceId Resource ID
   */
  private checkToAddResource(resourceId: string): void {
    try {
      const resourceBean = this.resourceBeanMap.get(resourceId);
      if (!resourceBean) {
        FTInnerLogger.w(TAG, `checkToAddResource: Resource not found: ${resourceId}`);
        return;
      }

      // Check if both content and network state are set
      if (resourceBean.contentSet && resourceBean.netStateSet) {
        // Get viewId and actionId before calling putRUMResourcePerformance
        const viewId = resourceBean.viewId;
        const actionId = resourceBean.actionId;
        
        // Aligned with Android SDK: putRUMResourcePerformance does NOT call increaseResourceCount
        // increaseResourceCount is called in stopResource (see Android SDK: FTRUMInnerManager.java:374)
        // Android SDK: putRUMResourcePerformance deletes ResourceBean asynchronously in the event consumer path
        // So stopResource can still find ResourceBean and call increaseResourceCount
        // HarmonyOS: We also delete ResourceBean asynchronously, so stopResource can find it
        this.putRUMResourcePerformance(resourceId);
        // Fallback only: normal stopResource completion already reduces pending_resource.
        if (resourceBean.endTime <= 0 && (viewId || actionId)) {
          this.decreasePendingResourceCount(viewId || '', actionId || '');
        }
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in checkToAddResource for ${resourceId}: ${error}`);
    }
  }

  /**
   * Build Resource-specific tags from ResourceBean
   * @param resourceBean Resource bean
   * @returns Resource tags object
   */
  private buildResourceTags(resourceBean: ResourceBean): ResourceTags {
    const tags: ResourceTags = {};
    
    // Basic resource info (from Guance documentation)
    if (resourceBean.url) tags.resource_url = resourceBean.url;
    if (resourceBean.urlHost) tags.resource_url_host = resourceBean.urlHost;
    if (resourceBean.urlPath) {
      tags.resource_url_path = resourceBean.urlPath;
      // Aligned with Android: group similar URLs by replacing numeric segments with ?
      // Regex: \/([^\/]*)\d([^\/]*) matches path segments containing digits
      // Replace with /? to normalize paths like /api/user/123/profile -> /api/user/?/profile
      let urlPathGroup = resourceBean.urlPath;
      if (urlPathGroup && urlPathGroup.length > 0) {
        urlPathGroup = urlPathGroup.replace(/\/([^\/]*)\d([^\/]*)/g, '/?');
      }
      tags.resource_url_path_group = urlPathGroup;
    }
    if (resourceBean.resourceMethod) tags.resource_method = resourceBean.resourceMethod;
    if (resourceBean.resourceType) tags.resource_type = resourceBean.resourceType;
    if (resourceBean.resourceStatus > 0) {
      tags.resource_status = String(resourceBean.resourceStatus);
      tags.resource_status_group = resourceBean.getResourceStatusGroup();
    }
    
    // Extended info (optional, matching Android)
    if (resourceBean.resourceHostIP) tags.resource_host_ip = resourceBean.resourceHostIP;
    if (resourceBean.responseConnection) tags.response_connection = resourceBean.responseConnection;
    if (resourceBean.responseContentType) tags.response_content_type = resourceBean.responseContentType;
    if (resourceBean.responseContentEncoding) tags.response_content_encoding = resourceBean.responseContentEncoding;
    if (resourceBean.traceId) tags.trace_id = resourceBean.traceId;
    if (resourceBean.spanId) tags.span_id = resourceBean.spanId;
    
    return tags;
  }

  /**
   * Build Resource-specific fields from ResourceBean
   * Aligned with Android: uses constants for field names (like action/error implementation)
   * @param resourceBean Resource bean
   * @returns Resource fields Record using constants as keys
   */
  private buildResourceFields(resourceBean: ResourceBean): Record<string, string> {
    const fields: Record<string, string> = {};
    
    // Core performance metrics (aligned with Android: FTRUMInnerManager.putRUMResourcePerformance)
    // Only add timing fields if value > 0 (matching Android behavior)
    if (resourceBean.resourceSize > 0) {
      fields[Constants.KEY_RUM_RESOURCE_SIZE] = String(resourceBean.resourceSize);
    }
    if (resourceBean.resourceLoad > 0) {
      fields[Constants.KEY_RUM_RESOURCE_DURATION] = String(resourceBean.resourceLoad);
    }
    if (resourceBean.resourceDNS > 0) {
      fields[Constants.KEY_RUM_RESOURCE_DNS] = String(resourceBean.resourceDNS);
      // Aligned with Android: duration first, then start
      fields[Constants.KEY_RUM_RESOURCE_DNS_TIME] = JSON.stringify({
        duration: resourceBean.resourceDNS,
        start: resourceBean.resourceDNSStart
      });
    }
    if (resourceBean.resourceTCP > 0) {
      fields[Constants.KEY_RUM_RESOURCE_TCP] = String(resourceBean.resourceTCP);
      // Aligned with Android: duration first, then start
      fields[Constants.KEY_RUM_RESOURCE_CONNECT_TIME] = JSON.stringify({
        duration: resourceBean.resourceTCP,
        start: resourceBean.resourceTCPStart
      });
    }
    if (resourceBean.resourceSSL > 0) {
      fields[Constants.KEY_RUM_RESOURCE_SSL] = String(resourceBean.resourceSSL);
      // Aligned with Android: duration first, then start
      fields[Constants.KEY_RUM_RESOURCE_SSL_TIME] = JSON.stringify({
        duration: resourceBean.resourceSSL,
        start: resourceBean.resourceSSLStart
      });
    }
    if (resourceBean.resourceTTFB > 0) {
      fields[Constants.KEY_RUM_RESOURCE_TTFB] = String(resourceBean.resourceTTFB);
    }
    if (resourceBean.resourceTrans > 0) {
      fields[Constants.KEY_RUM_RESOURCE_TRANS] = String(resourceBean.resourceTrans);
    }
    if (resourceBean.resourceFirstByte > 0) {
      fields[Constants.KEY_RUM_RESOURCE_FIRST_BYTE] = String(resourceBean.resourceFirstByte);
      // Aligned with Android: duration first, then start
      fields[Constants.KEY_RUM_RESOURCE_FIRST_BYTE_TIME] = JSON.stringify({
        duration: resourceBean.resourceFirstByte,
        start: resourceBean.resourceFirstByteStart
      });
    }
    if (resourceBean.resourceDownloadTime > 0) {
      // Aligned with Android: use KEY_RUM_DOWNLOAD_TIME instead of KEY_RUM_RESOURCE_DOWNLOAD_TIME
      // Aligned with Android: duration first, then start
      fields[Constants.KEY_RUM_DOWNLOAD_TIME] = JSON.stringify({
        duration: resourceBean.resourceDownloadTime,
        start: resourceBean.resourceDownloadTimeStart
      });
    }
    
    // Headers (only add if not empty, aligned with Android)
    if (resourceBean.requestHeader && resourceBean.requestHeader.trim() !== '') {
      fields[Constants.KEY_RUM_RESOURCE_REQUEST_HEADER] = resourceBean.requestHeader;
    }
    if (resourceBean.responseHeader && resourceBean.responseHeader.trim() !== '') {
      fields[Constants.KEY_RUM_RESOURCE_RESPONSE_HEADER] = resourceBean.responseHeader;
    }
    
    // Add custom properties (aligned with Android: filter out performance metrics already handled above)
    // Map camelCase keys from property to snake_case constants to match Android output
    const performanceMetricKeys = new Set([
      'resourceDNS', 'resourceTCP', 'resourceSSL', 'resourceTTFB', 
      'resourceTrans', 'resourceFirstByte', 'resourceDownloadTime', 'resourceLoad'
    ]);
    
    if (resourceBean.property && Object.keys(resourceBean.property).length > 0) {
      const propertyKeys = Object.keys(resourceBean.property);
      for (let i = 0; i < propertyKeys.length; i++) {
        const key = propertyKeys[i];
        
        // Skip performance metrics that are already handled above (aligned with Android)
        // These are stored in ResourceBean fields, not in property
        if (performanceMetricKeys.has(key)) {
          continue; // Skip, already handled above
        }
        
        const value = (resourceBean.property as Record<string, object>)[key];
        if (value !== null && value !== undefined) {
          // Only add primitive types to avoid [object Object] issues
          if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
            (fields as Record<string, string>)[key] = String(value);
          } else if (typeof value === 'object' && value !== null) {
            // If object has 'value' property (like MonitorValue), extract it directly
            if (value['value'] !== undefined) {
              (fields as Record<string, string>)[key] = String(value['value']);
            } else {
              // Convert other objects to JSON string
              (fields as Record<string, string>)[key] = JSON.stringify(value);
            }
          }
        }
      }
    }
    
    return fields;
  }

  /**
   * Build LongTask-specific fields
   * @param duration Long task duration
   * @param log Long task log message
   * @returns LongTask fields object
   */
  private buildLongTaskFields(duration: number, log: string): LongTaskFields {
    const fields: LongTaskFields = {};
    fields.duration = duration;
    
    // Check if log is empty or looks like a description string (not a stack trace)
    const isStackTrace = log && (
      log.includes("at ") ||
      log.includes("Error:") ||
      log.includes(".ets:") ||
      log.includes(".ts:") ||
      log.includes(".js:") ||
      log.includes("\n") ||
      log.includes("Stack") ||
      log.length > 100
    );
    
    if (!log || log.trim().length === 0) {
      // If log is empty, capture current stack trace
      try {
        const error = new Error();
        if (error.stack) {
          fields.long_task_stack = error.stack;
        } else {
          fields.long_task_stack = "Stack trace not available";
        }
      } catch (e) {
        fields.long_task_stack = "Stack trace capture failed";
        FTInnerLogger.e(TAG, `Failed to capture stack trace: ${e}`);
      }
    } else if (!isStackTrace) {
      // If log looks like a description string, append stack trace
      try {
        const error = new Error();
        if (error.stack) {
          const stackLines = error.stack.split('\n');
          // Remove the first line (Error message) and keep the rest (stack trace)
          const stackTrace = stackLines.length > 1 ? stackLines.slice(1).join('\n') : error.stack;
          fields.long_task_stack = `${log}\n\nStack Trace:\n${stackTrace}`;
        } else {
          fields.long_task_stack = log;
        }
      } catch (e) {
        fields.long_task_stack = log;
        FTInnerLogger.e(TAG, `Failed to append stack trace: ${e}, using log as-is`);
      }
    } else {
      // log already looks like a stack trace, use it as-is
      fields.long_task_stack = log;
    }
    
    return fields;
  }

  /**
   * Build Error-specific tags
   * @param errorSource Error source
   * @param errorType Error type
   * @param state Application state
   * @returns Error tags object
   */
  private buildErrorTags(errorSource: ErrorSource, errorType: string, state: AppState): ErrorTags {
    const tags: ErrorTags = {};
    tags.error_source = errorSource.toString();
    tags.error_type = errorType;
    tags.error_situation = state.toString();
    return tags;
  }

  /**
   * Build Error-specific fields
   * Note: This method is called from addError which is async, 
   * so we don't populate device info here to avoid double async calls.
   * Device info should be gathered in the caller.
   * @param message Error message
   * @param log Error stack trace
   * @returns Error fields object
   */
  private buildErrorFields(message: string, log: string): ErrorFields {
    const fields: ErrorFields = {};
    fields.error_message = message;
    fields.error_stack = log;
    // Note: memory_total, memory_use, cpu_use, battery_use, locale 
    // should be populated in the caller (addError method)
    return fields;
  }

}
