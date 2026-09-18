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
  RUMEnumUtils,
} from './enum/RUMEnums';
import FTTrackInner from '../FTTrackInner';
import {
  FTDBTaskPoolExecutor,
  FTDBTaskPoolPendingRumResourceDTO,
  FTDBTaskPoolRumCounterDeltaDTO
} from '../db/FTDBTaskPoolExecutor';
import { FTCacheContext, isFTCacheSqlitePrimary } from '../db/FTCacheContext';
import { FTInnerLogger } from "../log/FTLogger";
import {
  SDKDedicatedPoolManager,
  SDKWorkerMailboxPostResult
} from '../thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolContextDTO,
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
  SDKPropertyRecord,
  SDKStringRecord,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../thread/SDKWorkerProtocol';
import { Utils } from '../utils/Utils';
import { DeviceUtils } from '../utils/DeviceUtils';
import { Constants } from '../Constants';
import { FTMonitorManager } from './FTMonitorManager';
import { ErrorMonitorType } from './enum/ErrorMonitorType';
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
import { FTCrashFreeDuration, FTCrashFreeDurationManager } from '../monitor/FTCrashFreeDurationManager';

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
  memory_total?: string;
  locale?: string;
}

/**
 * Error-specific fields for line protocol
 */
interface ErrorFields {
  error_message?: string;
  error_stack?: string;
  memory_use?: number;
  cpu_use?: number;
  battery_use?: number;
}

interface ErrorDeviceData {
  tags: SDKStringRecord;
  fields: Record<string, object>;
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
export interface FTRUMCrashRecoveryContext {
  viewId: string;
  viewName: string;
  viewReferrer: string;
  sessionId: string;
}

/** A recovery association is valid only when it identifies both its View and Session. */
export function hasFTRUMCrashRecoveryContext(
  context: FTRUMCrashRecoveryContext | null | undefined
): boolean {
  return context !== null && context !== undefined && context.viewId.length > 0 && context.sessionId.length > 0;
}

/**
 * Historical crashes are associated with the predecessor process. The data is
 * written as Tags so Error page correlation and aggregation can consume it.
 */
export function applyFTRUMCrashRecoveryContext(
  tags: Record<string, string>,
  context: FTRUMCrashRecoveryContext | null | undefined
): boolean {
  if (!hasFTRUMCrashRecoveryContext(context)) {
    return false;
  }
  const recovered = context as FTRUMCrashRecoveryContext;
  tags[Constants.KEY_RUM_SESSION_ID] = recovered.sessionId;
  tags[Constants.KEY_RUM_VIEW_ID] = recovered.viewId;
  tags[Constants.KEY_RUM_VIEW_NAME] = recovered.viewName;
  tags[Constants.KEY_RUM_VIEW_REFERRER] = recovered.viewReferrer;
  return true;
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

/** A closed-in-memory Action waiting for its resource counters to settle in RDB. */
interface PendingActionCloseState {
  actionBean: ActionBean;
  closeInFlight: boolean;
  waitingForResource: boolean;
}

interface RumSemanticJournalEntry {
  sequence: number;
  request: SDKWorkerRequest;
  /** Resource IDs represented by this request, captured once at enqueue time. */
  resourceIds: string[];
  workerAcknowledged: boolean;
  hostApplied: boolean;
  commitBarrier: boolean;
  semanticCommitted: boolean;
}

interface RumResourceDraftIds {
  resourceUuid: string;
  errorUuid: string;
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
  /** All Host RUM queues use the same thin transport micro-batch boundary. */
  private static readonly RUM_TRANSPORT_BATCH_SIZE = 64;
  private static readonly RUM_TRANSPORT_BATCH_DELAY_MS = 16;
  private static readonly RUM_COUNTER_FLUSH_MAX_EVENTS = 256;
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
  private sessionErrorSampleRate: number = 0.0;
  
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
  private rumSemanticReplayTimer: number | null = null;
  /**
   * Coalesce counter updates on the host before they cross the worker boundary.
   *
   * A burst of manually reported long tasks normally shares the same active
   * View/Action. Keeping one accumulated DTO per counter identity avoids
   * allocating and posting one worker message for every long task while the
   * worker and RDB still receive the exact final count.
   */
  private pendingRumCounterUpdates: Map<string, SDKRumCounterUpdateDTO> = new Map();
  private pendingCompletedActions: PendingCompletedActionWorkerCommand[] = [];
  private pendingResourceCommands: PendingRumResourceWorkerCommand[] = [];
  private pendingErrorCommands: PendingRumErrorWorkerCommand[] = [];
  /** Resource start persistence barriers; later lifecycle commands wait behind them. */
  private pendingResourceRegistrations: Map<string, Promise<boolean>> = new Map();
  /** Shared DB reads restore an original Resource context after process restart. */
  private pendingResourceContextRestores: Map<string, Promise<FTDBTaskPoolPendingRumResourceDTO | null>> = new Map();
  private resourceContextById: Map<string, SDKRumResourceContextDTO> = new Map();
  /** Resource IDs with an accepted start command; guards duplicate interceptors. */
  private startedResourceIds: Set<string> = new Set();
  private startedResourceActionIds: Map<string, string> = new Map();
  private resourceContentSubmittedIds: Set<string> = new Set();
  private resourceNetStateSubmittedIds: Set<string> = new Set();
  private resourceStoppedIds: Set<string> = new Set();
  /** Actions that are closed to new events but not yet durably closed in RDB. */
  private pendingActionCloseStates: Map<string, PendingActionCloseState> = new Map();
  /** Retries only transient database close failures; it never overrides Resource references. */
  private pendingActionCloseRetryTimer: number | null = null;
  private pendingActionRecoveryStarted: boolean = false;
  /** Allows an early close request to await the initial Action insert. */
  private pendingActionInsertions: Map<string, Promise<boolean>> = new Map();
  /**
   * Commands that own volatile Resource/Counter state remain journaled until a
   * counter-flush barrier is applied to DB. A Worker response alone is not a
   * semantic commit.
   */
  private rumSemanticJournal: RumSemanticJournalEntry[] = [];
  /**
   * The journal is a FIFO with a moving head. Keeping the consumed prefix in
   * place avoids copying the complete journal every time a flush is confirmed.
   */
  private rumSemanticJournalHead: number = 0;
  private rumSemanticJournalByRequestId: Map<string, RumSemanticJournalEntry> = new Map();
  private rumSemanticSequence: number = 0;
  private committedRumSemanticResponseIds: Map<string, boolean> = new Map();
  private committedRumSemanticResponseOrder: string[] = [];
  private committedRumSemanticResponseOrderHead: number = 0;
  private resourceDraftIdsById: Map<string, RumResourceDraftIds> = new Map();
  /** Prefix queue used to evict the oldest resource draft state at capacity. */
  private resourceDraftIdOrder: string[] = [];
  private resourceDraftIdOrderHead: number = 0;
  private completedRumResourceIds: Set<string> = new Set();
  /**
   * One reference is held for every resource command from its pending queue
   * through its journal entry. This makes the ownership check O(1).
   */
  private resourcePendingOrJournalRefCounts: Map<string, number> = new Map();
  /** A short completed-response window; this is not part of input flow control. */
  private static readonly RUM_SEMANTIC_RESPONSE_DEDUP_CAPACITY: number = 1024;
  /** Recent action IDs prevent duplicate completion only within this short window. */
  private static readonly RUM_ACTION_ID_DEDUP_CAPACITY: number = 1024;
  /** Keep replay state for the newest semantic commands without blocking collection. */
  private static readonly RUM_SEMANTIC_JOURNAL_HIGH_WATERMARK: number = 5000;
  /** Keep draft identifiers for the newest resource lifecycles without blocking collection. */
  private static readonly RUM_RESOURCE_DRAFT_HIGH_WATERMARK: number = 5000;
  private static readonly RUM_JOURNAL_COMPACTION_MIN_PREFIX: number = 128;
  private static readonly RUM_STATE_EVICTION_LOG_INTERVAL_MS: number = 10000;
  private static readonly PENDING_ACTION_CLOSE_RETRY_MS: number = 100;
  private lastRumStateEvictionLogAt: number = 0;
  
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
  private processedActionIdOrder: string[] = [];
  private processedActionIdOrderHead: number = 0;
  
  // Set to track inserted action IDs to prevent duplicate uploads
  // This ensures that even if completed action submission is triggered multiple times, it will only upload once.
  private insertedActionIds: Set<string> = new Set();
  private insertedActionIdOrder: string[] = [];
  private insertedActionIdOrderHead: number = 0;
  private lastRumCounterMailboxFailureLogAt: number = 0;
  
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
  private preferencesInitPromise: Promise<void> | null = null;
  private rumContextPersistChain: Promise<void> = Promise.resolve();


  // Maximum size for Set collections to prevent memory leak (using Constants.MAX_SET_SIZE_ACTION for Action, MAX_SET_SIZE_VIEW for View)
  
  private constructor() {
    this.initSessionTimer();
    // Note: Session ID is created in field initialization, but checkSessionKeep will be called
    // in initParams() after sampling rates are set from FTRUMConfig
    // Do NOT call checkSessionKeep here because sampleRate may not be set yet
  }

  private registerRumSemanticRequest(request: SDKWorkerRequest): void {
    if (this.rumSemanticJournalByRequestId.has(request.id)) {
      return;
    }
    this.trimRumSemanticJournalForLatest();
    this.rumSemanticSequence++;
    const entry: RumSemanticJournalEntry = {
      sequence: this.rumSemanticSequence,
      request,
      resourceIds: this.getResourceIdsFromWorkerRequest(request),
      workerAcknowledged: false,
      hostApplied: false,
      commitBarrier: false,
      semanticCommitted: false
    };
    this.rumSemanticJournal.push(entry);
    this.rumSemanticJournalByRequestId.set(request.id, entry);
  }

  /** Called by the EVENT mailbox response router before asynchronous DB work. */
  public markRumSemanticWorkerResponse(requestId: string): boolean {
    if (this.committedRumSemanticResponseIds.has(requestId)) {
      return false;
    }
    const entry = this.rumSemanticJournalByRequestId.get(requestId);
    if (entry) {
      entry.workerAcknowledged = true;
      return !entry.hostApplied;
    }
    return true;
  }

  /** Marks all Host-side effects for this Worker response as durable. */
  public markRumSemanticHostApplied(requestId: string): void {
    const entry = this.rumSemanticJournalByRequestId.get(requestId);
    if (entry) {
      entry.hostApplied = true;
      if (entry.request.command === SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH && this.context) {
        const payload = entry.request.payload as Object as SDKRumCompletedActionBatchDTO;
        const ids = payload.actions.map((a: SDKRumCompletedActionDTO) => a.actionId);
        FTDBTaskPoolExecutor.cleanCloseActionData(this.context, ids).catch((error: Error) => {
          for (const id of ids) { this.forgetInsertedActionId(id); this.forgetProcessedActionId(id); }
          FTInnerLogger.e(TAG, `Completed action cleanup failed: ${error.message}`);
        });
      }
    } else {
      // The replay state may have been evicted to preserve newer entries. The
      // response was still applied by the Host, so retain only its bounded
      // de-duplication marker rather than restoring an old journal entry.
      this.rememberCommittedRumSemanticResponse(requestId);
    }
  }

  /** A failed/lost transport attempt must not permanently pin a retained aggregate. */
  public markRumSemanticHostFailed(requestId: string): void {
    const entry = this.rumSemanticJournalByRequestId.get(requestId);
    if (entry) { this.releaseCompletedActionAttempt(entry); }
  }

  private releaseCompletedActionAttempt(entry: RumSemanticJournalEntry): void {
    if (entry.request.command !== SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH) { return; }
    const payload = entry.request.payload as Object as SDKRumCompletedActionBatchDTO;
    for (const action of payload.actions || []) {
      this.forgetInsertedActionId(action.actionId);
      this.forgetProcessedActionId(action.actionId);
    }
  }

  public async markRumResourcesCompleted(
    resourceIds: string[],
    counterDeltasApplied: boolean = false
  ): Promise<boolean> {
    let releasedResourceLifecycle = false;
    for (let i = 0; i < resourceIds.length; i++) {
      const resourceId = resourceIds[i];
      if (resourceId && resourceId.length > 0) {
        this.completedRumResourceIds.add(resourceId);
        // Only the resources explicitly completed by this worker response are
        // considered for cleanup. Do not scan every outstanding draft here.
        this.cleanupCompletedResourceDraftId(resourceId);
        if (counterDeltasApplied) {
          // This response carried the matching counter barrier, which was
          // committed before this callback. It is now safe to release the
          // Host-side guard for this Resource.
          this.clearResourceLifecycleRegistration(resourceId);
          releasedResourceLifecycle = true;
        }
      }
    }
    if (!counterDeltasApplied || resourceIds.length === 0) {
      return true;
    }
    if (isFTCacheSqlitePrimary(FTCacheContext.settings.mode)) {
      return await this.completePersistedResourceLifecycles(resourceIds);
    }
    if (releasedResourceLifecycle) {
      this.retryPendingActionClosures();
    }
    this.pruneCommittedRumSemanticPrefix();
    return true;
  }

  /** SQLite retains the cross-restart Resource-to-Action association separately. */
  private async completePersistedResourceLifecycles(resourceIds: string[]): Promise<boolean> {
    if (resourceIds.length === 0) {
      return true;
    }
    if (!this.context) {
      return false;
    }
    try {
      await FTDBTaskPoolExecutor.completePendingRumResources(this.context, resourceIds);
      for (let i = 0; i < resourceIds.length; i++) {
        const resourceId = resourceIds[i];
        if (resourceId && resourceId.length > 0) {
          this.clearResourceLifecycleRegistration(resourceId);
          this.cleanupCompletedResourceDraftId(resourceId);
        }
      }
      this.retryPendingActionClosures();
      this.pruneCommittedRumSemanticPrefix();
      return true;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to complete persisted Resource lifecycle: ${errorMessage}`);
      return false;
    }
  }

  /**
   * Commits all semantic state up to a counter-flush barrier. EVENT responses
   * are serialized by FTTrackInner, so earlier Resource drafts have completed
   * their DB write before this method is called.
   */
  public acknowledgeRumSemanticThrough(requestId: string): void {
    const barrier = this.rumSemanticJournalByRequestId.get(requestId);
    if (!barrier) {
      return;
    }
    barrier.commitBarrier = true;
    for (let i = this.rumSemanticJournalHead; i < this.rumSemanticJournal.length; i++) {
      const entry = this.rumSemanticJournal[i];
      if (!entry.hostApplied) {
        break;
      }
      entry.semanticCommitted = true;
      if (entry.request.id === requestId) {
        break;
      }
    }
    this.pruneCommittedRumSemanticPrefix();
  }

  private pruneCommittedRumSemanticPrefix(): void {
    while (this.rumSemanticJournalHead < this.rumSemanticJournal.length) {
      const entry = this.rumSemanticJournal[this.rumSemanticJournalHead];
      if (!entry.semanticCommitted || this.shouldRetainResourceStateCheckpoint(entry)) {
        break;
      }
      this.rumSemanticJournalByRequestId.delete(entry.request.id);
      this.rememberCommittedRumSemanticResponse(entry.request.id);
      this.releaseResourceTransportReferences(entry.resourceIds);
      this.rumSemanticJournalHead++;
    }
    this.compactRumSemanticJournalIfNeeded();
  }

  private shouldRetainResourceStateCheckpoint(entry: RumSemanticJournalEntry): boolean {
    for (let i = 0; i < entry.resourceIds.length; i++) {
      const resourceId = entry.resourceIds[i];
      if (resourceId && resourceId.length > 0 && !this.completedRumResourceIds.has(resourceId)) {
        return true;
      }
    }
    return false;
  }

  private rememberCommittedRumSemanticResponse(requestId: string): void {
    if (!requestId || this.committedRumSemanticResponseIds.has(requestId)) {
      return;
    }
    this.committedRumSemanticResponseIds.set(requestId, true);
    this.committedRumSemanticResponseOrder.push(requestId);
    while (this.committedRumSemanticResponseOrder.length - this.committedRumSemanticResponseOrderHead >
      FTRUMInnerManager.RUM_SEMANTIC_RESPONSE_DEDUP_CAPACITY) {
      const oldest = this.committedRumSemanticResponseOrder[this.committedRumSemanticResponseOrderHead];
      this.committedRumSemanticResponseOrderHead++;
      this.committedRumSemanticResponseIds.delete(oldest);
    }
    this.compactCommittedRumSemanticResponseOrder();
  }

  private compactCommittedRumSemanticResponseOrder(): void {
    if (this.committedRumSemanticResponseOrderHead === 0) {
      return;
    }
    if (this.committedRumSemanticResponseOrderHead >= this.committedRumSemanticResponseOrder.length) {
      this.committedRumSemanticResponseOrder = [];
      this.committedRumSemanticResponseOrderHead = 0;
      return;
    }
    if (this.committedRumSemanticResponseOrderHead >= FTRUMInnerManager.RUM_JOURNAL_COMPACTION_MIN_PREFIX &&
      this.committedRumSemanticResponseOrderHead * 2 >= this.committedRumSemanticResponseOrder.length) {
      this.committedRumSemanticResponseOrder =
        this.committedRumSemanticResponseOrder.slice(this.committedRumSemanticResponseOrderHead);
      this.committedRumSemanticResponseOrderHead = 0;
    }
  }

  private rememberProcessedActionId(actionId: string): void {
    if (!actionId || this.processedActionIds.has(actionId)) {
      return;
    }
    this.compactProcessedActionIdOrder();
    while (this.processedActionIds.size >= FTRUMInnerManager.RUM_ACTION_ID_DEDUP_CAPACITY &&
      this.processedActionIdOrderHead < this.processedActionIdOrder.length) {
      const oldest = this.processedActionIdOrder[this.processedActionIdOrderHead];
      this.processedActionIdOrderHead++;
      this.processedActionIds.delete(oldest);
    }
    this.processedActionIds.add(actionId);
    this.processedActionIdOrder.push(actionId);
    this.compactProcessedActionIdOrder();
  }

  private forgetProcessedActionId(actionId: string): void {
    this.processedActionIds.delete(actionId);
    this.compactProcessedActionIdOrder();
  }

  private compactProcessedActionIdOrder(): void {
    while (this.processedActionIdOrderHead < this.processedActionIdOrder.length &&
      !this.processedActionIds.has(this.processedActionIdOrder[this.processedActionIdOrderHead])) {
      this.processedActionIdOrderHead++;
    }
    if (this.processedActionIdOrderHead >= this.processedActionIdOrder.length) {
      this.processedActionIdOrder = [];
      this.processedActionIdOrderHead = 0;
      return;
    }
    if (this.processedActionIdOrderHead >= FTRUMInnerManager.RUM_JOURNAL_COMPACTION_MIN_PREFIX &&
      this.processedActionIdOrderHead * 2 >= this.processedActionIdOrder.length) {
      this.processedActionIdOrder = this.processedActionIdOrder.slice(this.processedActionIdOrderHead);
      this.processedActionIdOrderHead = 0;
    }
  }

  private rememberInsertedActionId(actionId: string): void {
    if (!actionId || this.insertedActionIds.has(actionId)) {
      return;
    }
    this.compactInsertedActionIdOrder();
    while (this.insertedActionIds.size >= FTRUMInnerManager.RUM_ACTION_ID_DEDUP_CAPACITY &&
      this.insertedActionIdOrderHead < this.insertedActionIdOrder.length) {
      const oldest = this.insertedActionIdOrder[this.insertedActionIdOrderHead];
      this.insertedActionIdOrderHead++;
      this.insertedActionIds.delete(oldest);
    }
    this.insertedActionIds.add(actionId);
    this.insertedActionIdOrder.push(actionId);
    this.compactInsertedActionIdOrder();
  }

  private forgetInsertedActionId(actionId: string): void {
    this.insertedActionIds.delete(actionId);
    this.compactInsertedActionIdOrder();
  }

  private compactInsertedActionIdOrder(): void {
    while (this.insertedActionIdOrderHead < this.insertedActionIdOrder.length &&
      !this.insertedActionIds.has(this.insertedActionIdOrder[this.insertedActionIdOrderHead])) {
      this.insertedActionIdOrderHead++;
    }
    if (this.insertedActionIdOrderHead >= this.insertedActionIdOrder.length) {
      this.insertedActionIdOrder = [];
      this.insertedActionIdOrderHead = 0;
      return;
    }
    if (this.insertedActionIdOrderHead >= FTRUMInnerManager.RUM_JOURNAL_COMPACTION_MIN_PREFIX &&
      this.insertedActionIdOrderHead * 2 >= this.insertedActionIdOrder.length) {
      this.insertedActionIdOrder = this.insertedActionIdOrder.slice(this.insertedActionIdOrderHead);
      this.insertedActionIdOrderHead = 0;
    }
  }

  private clearActionIdLedgers(): void {
    this.processedActionIds.clear();
    this.processedActionIdOrder = [];
    this.processedActionIdOrderHead = 0;
    this.insertedActionIds.clear();
    this.insertedActionIdOrder = [];
    this.insertedActionIdOrderHead = 0;
  }

  private cleanupCompletedResourceDraftId(resourceId: string): void {
    if (!this.completedRumResourceIds.has(resourceId) ||
      !this.resourceContentSubmittedIds.has(resourceId) ||
      !this.resourceStoppedIds.has(resourceId) ||
      this.hasPendingOrJournaledResource(resourceId)) {
      return;
    }
    this.resourceDraftIdsById.delete(resourceId);
    this.resourceContentSubmittedIds.delete(resourceId);
    this.resourceNetStateSubmittedIds.delete(resourceId);
    this.resourceStoppedIds.delete(resourceId);
    this.resourceContextById.delete(resourceId);
    this.completedRumResourceIds.delete(resourceId);
  }

  private clearResourceLifecycleRegistration(resourceId: string): void {
    this.startedResourceIds.delete(resourceId);
    this.startedResourceActionIds.delete(resourceId);
  }

  private hasStartedResourceForAction(actionId: string): boolean {
    if (!actionId || actionId.length === 0) {
      return false;
    }
    const resourceActionIds = Array.from(this.startedResourceActionIds.values());
    for (let i = 0; i < resourceActionIds.length; i++) {
      if (resourceActionIds[i] === actionId) {
        return true;
      }
    }
    return false;
  }

  /** Releases completed Resources once a later counter-flush reaches RDB. */
  private async releaseCompletedResourceLifecycleRegistrations(
    deltas: SDKRumCounterDeltaDTO[]
  ): Promise<boolean> {
    const actionIds = new Set<string>();
    for (let i = 0; i < deltas.length; i++) {
      const actionId = deltas[i].actionId;
      if (actionId && actionId.length > 0) {
        actionIds.add(actionId);
      }
    }
    if (actionIds.size === 0) {
      return false;
    }
    const readyResourceIds: string[] = [];
    const completedResourceIds = Array.from(this.completedRumResourceIds.values());
    for (let i = 0; i < completedResourceIds.length; i++) {
      const resourceId = completedResourceIds[i];
      const actionId = this.startedResourceActionIds.get(resourceId);
      if (actionId && actionIds.has(actionId)) {
        readyResourceIds.push(resourceId);
      }
    }
    if (!isFTCacheSqlitePrimary(FTCacheContext.settings.mode)) {
      for (let i = 0; i < readyResourceIds.length; i++) {
        this.clearResourceLifecycleRegistration(readyResourceIds[i]);
      }
      return readyResourceIds.length > 0;
    }
    return await this.completePersistedResourceLifecycles(readyResourceIds);
  }

  private hasPendingOrJournaledResource(resourceId: string): boolean {
    return (this.resourcePendingOrJournalRefCounts.get(resourceId) || 0) > 0;
  }

  private getResourceIdsFromWorkerRequest(request: SDKWorkerRequest): string[] {
    if (request.command !== SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH || !request.payload) {
      return [];
    }
    const batch = request.payload as Object as SDKRumResourceCommandBatchDTO;
    const commands = batch.commands || [];
    const resourceIds: string[] = [];
    for (let i = 0; i < commands.length; i++) {
      const resourceId = commands[i].resourceId;
      if (resourceId && resourceId.length > 0) {
        resourceIds.push(resourceId);
      }
    }
    return resourceIds;
  }

  private retainResourceTransportReference(resourceId: string): void {
    if (!resourceId) {
      return;
    }
    this.resourcePendingOrJournalRefCounts.set(resourceId,
      (this.resourcePendingOrJournalRefCounts.get(resourceId) || 0) + 1);
  }

  private releaseResourceTransportReferences(resourceIds: string[]): void {
    for (let i = 0; i < resourceIds.length; i++) {
      const resourceId = resourceIds[i];
      const next = (this.resourcePendingOrJournalRefCounts.get(resourceId) || 0) - 1;
      if (next > 0) {
        this.resourcePendingOrJournalRefCounts.set(resourceId, next);
      } else {
        this.resourcePendingOrJournalRefCounts.delete(resourceId);
      }
      this.cleanupCompletedResourceDraftId(resourceId);
    }
  }

  /** Final cleanup for commands deliberately abandoned by the transport. */
  private discardUncommittedResourceTransportState(resourceIds: string[]): void {
    for (let i = 0; i < resourceIds.length; i++) {
      const resourceId = resourceIds[i];
      if (!resourceId || this.hasPendingOrJournaledResource(resourceId)) {
        continue;
      }
      this.resourceDraftIdsById.delete(resourceId);
      this.completedRumResourceIds.delete(resourceId);
      this.clearResourceLifecycleRegistration(resourceId);
      if (this.resourceContentSubmittedIds.has(resourceId) && this.resourceStoppedIds.has(resourceId)) {
        this.resourceContentSubmittedIds.delete(resourceId);
        this.resourceNetStateSubmittedIds.delete(resourceId);
        this.resourceStoppedIds.delete(resourceId);
        this.resourceContextById.delete(resourceId);
      }
    }
  }

  private compactRumSemanticJournalIfNeeded(): void {
    if (this.rumSemanticJournalHead < FTRUMInnerManager.RUM_JOURNAL_COMPACTION_MIN_PREFIX ||
      this.rumSemanticJournalHead * 2 < this.rumSemanticJournal.length) {
      return;
    }
    this.rumSemanticJournal = this.rumSemanticJournal.slice(this.rumSemanticJournalHead);
    this.rumSemanticJournalHead = 0;
  }

  /**
   * Bounds only restart/replay state. Evicted entries have already been posted
   * to the Worker; their first normal response is still accepted and persisted.
   * New collection is never sampled because this replay ledger is full.
   */
  private trimRumSemanticJournalForLatest(): void {
    let evicted = 0;
    while (this.rumSemanticJournal.length - this.rumSemanticJournalHead >=
      FTRUMInnerManager.RUM_SEMANTIC_JOURNAL_HIGH_WATERMARK) {
      const entry = this.rumSemanticJournal[this.rumSemanticJournalHead];
      this.releaseCompletedActionAttempt(entry);
      this.rumSemanticJournalByRequestId.delete(entry.request.id);
      this.releaseResourceTransportReferences(entry.resourceIds);
      this.rumSemanticJournalHead++;
      evicted++;
    }
    this.compactRumSemanticJournalIfNeeded();
    if (evicted > 0) {
      this.logRumStateEviction('journal', evicted);
    }
  }

  private trimResourceDraftStateForLatest(): void {
    let evicted = 0;
    while (this.resourceDraftIdsById.size >= FTRUMInnerManager.RUM_RESOURCE_DRAFT_HIGH_WATERMARK &&
      this.resourceDraftIdOrderHead < this.resourceDraftIdOrder.length) {
      const resourceId = this.resourceDraftIdOrder[this.resourceDraftIdOrderHead];
      this.resourceDraftIdOrderHead++;
      if (!this.resourceDraftIdsById.has(resourceId)) {
        continue;
      }
      this.resourceDraftIdsById.delete(resourceId);
      this.clearResourceLifecycleRegistration(resourceId);
      this.resourceContentSubmittedIds.delete(resourceId);
      this.resourceNetStateSubmittedIds.delete(resourceId);
      this.resourceStoppedIds.delete(resourceId);
      this.resourceContextById.delete(resourceId);
      this.completedRumResourceIds.delete(resourceId);
      evicted++;
    }
    if (this.resourceDraftIdOrderHead >= FTRUMInnerManager.RUM_JOURNAL_COMPACTION_MIN_PREFIX &&
      this.resourceDraftIdOrderHead * 2 >= this.resourceDraftIdOrder.length) {
      this.resourceDraftIdOrder = this.resourceDraftIdOrder.slice(this.resourceDraftIdOrderHead);
      this.resourceDraftIdOrderHead = 0;
    }
    if (evicted > 0) {
      this.logRumStateEviction('resourceDraft', evicted);
    }
  }

  private logRumStateEviction(kind: string, count: number): void {
    const now = Date.now();
    if (now - this.lastRumStateEvictionLogAt < FTRUMInnerManager.RUM_STATE_EVICTION_LOG_INTERVAL_MS) {
      return;
    }
    this.lastRumStateEvictionLogAt = now;
    FTInnerLogger.w(TAG, `RUM ${kind} replay state evicted: count=${count}; preserving newest collection`);
  }

  /** Restores acknowledged Resource/Counter commands into a fresh Worker. */
  public replayRumSemanticStateAfterWorkerRestart(): void {
    for (let i = this.rumSemanticJournalHead; i < this.rumSemanticJournal.length; i++) {
      const entry = this.rumSemanticJournal[i];
      if (!entry.workerAcknowledged) {
        // The pool manager owns replay for unresolved mailbox messages.
        continue;
      }
      if (entry.semanticCommitted && !this.shouldRetainResourceStateCheckpoint(entry)) {
        continue;
      }
      const recoveryRequest = entry.semanticCommitted ?
        this.createResourceStateRecoveryRequest(entry.request) : entry.request;
      const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(recoveryRequest);
      if (postResult.posted) {
        entry.workerAcknowledged = false;
      } else {
        if (postResult.shouldRetry) {
          this.scheduleRumSemanticReplay(postResult.retryDelayMs);
        } else {
          this.degradeAcknowledgedRumSemanticRecovery(this.describeEventWorkerCircuit(postResult));
        }
        // A failed post represents a pool-wide transport failure. Do not burn
        // through the whole journal and open the circuit in one Host turn.
        break;
      }
    }
  }

  /**
   * Settles only requests that exhausted the generic Worker recovery window.
   * This is intentionally aggregate-driven: the Host must release the related
   * Resource state, but must not manufacture thousands of failed responses.
   */
  public discardRumSemanticRequestsAfterWorkerRecovery(requestIds: string[]): number {
    if (!requestIds || requestIds.length === 0) {
      return 0;
    }
    const discardedIds = new Set<string>();
    for (let i = 0; i < requestIds.length; i++) {
      discardedIds.add(requestIds[i]);
    }
    const retained: RumSemanticJournalEntry[] = [];
    let discarded = 0;
    for (let i = this.rumSemanticJournalHead; i < this.rumSemanticJournal.length; i++) {
      const entry = this.rumSemanticJournal[i];
      if (!discardedIds.has(entry.request.id)) {
        retained.push(entry);
        continue;
      }
      this.releaseCompletedActionAttempt(entry);
      this.rumSemanticJournalByRequestId.delete(entry.request.id);
      this.rememberCommittedRumSemanticResponse(entry.request.id);
      this.releaseResourceTransportReferences(entry.resourceIds);
      this.discardUncommittedResourceTransportState(entry.resourceIds);
      discarded++;
    }
    if (discarded > 0) {
      this.rumSemanticJournal = retained;
      this.rumSemanticJournalHead = 0;
    }
    return discarded;
  }

  private createResourceStateRecoveryRequest(request: SDKWorkerRequest): SDKWorkerRequest {
    if (request.command !== SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH || !request.payload) {
      return request;
    }
    const original = request.payload as Object as SDKRumResourceCommandBatchDTO;
    const recoveryPayload: SDKRumResourceCommandBatchDTO = {
      commands: original.commands || [],
      stateRecoveryOnly: true
    };
    if (original.lineContext) {
      recoveryPayload.lineContext = original.lineContext;
    }
    return {
      id: request.id,
      pool: request.pool,
      command: request.command,
      priority: request.priority,
      createdAt: request.createdAt,
      payload: recoveryPayload as Object as SDKWorkerPayload
    };
  }

  private scheduleRumSemanticReplay(delayMs: number): void {
    if (this.rumSemanticReplayTimer !== null) {
      return;
    }
    this.rumSemanticReplayTimer = setTimeout(() => {
      this.rumSemanticReplayTimer = null;
      this.replayRumSemanticStateAfterWorkerRestart();
    }, Math.max(1, delayMs)) as number;
  }

  private getOrCreateResourceDraftIds(resourceId: string): RumResourceDraftIds {
    let ids = this.resourceDraftIdsById.get(resourceId);
    if (!ids) {
      // This is only the Host's replay/idempotency cache. When it reaches its
      // window, evict the oldest state before recording the newest resource;
      // never reject the new resource command.
      this.trimResourceDraftStateForLatest();
      ids = {
        resourceUuid: Utils.generateUUID(),
        errorUuid: Utils.generateUUID()
      };
      this.resourceDraftIdsById.set(resourceId, ids);
      this.resourceDraftIdOrder.push(resourceId);
    }
    return ids;
  }

  private submitRumCounterUpdateTask(update: SDKRumCounterUpdateDTO): void {
    if (!this.context || !update || !update.updateType) {
      return;
    }

    const updateType = update.updateType;
    const viewId = update.viewId || '';
    const actionId = update.actionId || '';
    const updateView = update.updateView !== false;
    const count = this.normalizeRumCounterUpdateCount(update.count);
    const key = this.getRumCounterUpdateKey(updateType, viewId, actionId, updateView);
    const existing = this.pendingRumCounterUpdates.get(key);
    if (existing) {
      existing.count = this.normalizeRumCounterUpdateCount(existing.count) + count;
    } else {
      this.pendingRumCounterUpdates.set(key, {
        updateType,
        viewId,
        actionId,
        updateView,
        flushMaxKeys: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS,
        count
      });
    }

    if (this.pendingRumCounterUpdates.size >= FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE) {
      this.flushRumCounterUpdateBatch(`rum.counter.${update.updateType}`);
    } else {
      this.scheduleRumCounterUpdateBatchFlush(`rum.counter.${update.updateType}`);
    }
    this.scheduleRumCounterFlush();
  }

  private getRumCounterUpdateKey(
    updateType: string,
    viewId: string,
    actionId: string,
    updateView: boolean
  ): string {
    return `${updateType}|${viewId}|${actionId}|${updateView ? '1' : '0'}`;
  }

  private normalizeRumCounterUpdateCount(count: number | undefined): number {
    if (count === undefined || count !== count || count <= 0) {
      return 1;
    }
    return Math.max(1, Math.floor(count));
  }

  private scheduleRumCounterUpdateBatchFlush(
    traceBaseName: string,
    delayMs: number = FTRUMInnerManager.RUM_TRANSPORT_BATCH_DELAY_MS
  ): void {
    if (!this.context || this.rumCounterUpdateFlushTimer !== null) {
      return;
    }
    this.rumCounterUpdateFlushTimer = setTimeout(() => {
      this.rumCounterUpdateFlushTimer = null;
      this.flushRumCounterUpdateBatch(traceBaseName);
    }, Math.max(1, delayMs)) as number;
  }

  private flushRumCounterUpdateBatch(traceBaseName: string = 'rum.counter.batch', drainAll: boolean = false): void {
    if (this.rumCounterUpdateFlushTimer !== null) {
      clearTimeout(this.rumCounterUpdateFlushTimer);
      this.rumCounterUpdateFlushTimer = null;
    }
    if (!this.context || this.pendingRumCounterUpdates.size === 0) {
      return;
    }

    let shouldContinue = true;
    while (this.pendingRumCounterUpdates.size > 0 && shouldContinue) {
      const batchSize = Math.min(
        FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE,
        this.pendingRumCounterUpdates.size
      );
      const pendingEntries = Array.from(this.pendingRumCounterUpdates.entries());
      const batchEntries = pendingEntries.slice(0, batchSize);
      const updates: SDKRumCounterUpdateDTO[] = [];
      for (let i = 0; i < batchEntries.length; i++) {
        updates.push(batchEntries[i][1]);
      }
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

      const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
      if (!postResult.posted) {
        FTInnerLogger.e(TAG, `RUM counter worker mailbox batch post failed: size=${updates.length}`);
        if (postResult.shouldRetry) {
          this.scheduleRumCounterUpdateBatchFlush(traceBaseName, postResult.retryDelayMs);
        } else {
          this.degradePendingRumCounterUpdates(this.describeEventWorkerCircuit(postResult));
        }
        break;
      }
      for (let i = 0; i < batchEntries.length; i++) {
        this.pendingRumCounterUpdates.delete(batchEntries[i][0]);
      }
      this.registerRumSemanticRequest(workerRequest);
      this.scheduleRumCounterFlush();
      shouldContinue = drainAll;
    }
    if (this.pendingRumCounterUpdates.size > 0) {
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

    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, 'RUM counter flush worker mailbox post failed');
      if (postResult.shouldRetry) {
        this.scheduleRumCounterFlush(postResult.retryDelayMs);
      } else {
        FTInnerLogger.w(TAG,
          `RUM counter flush degraded: ${this.describeEventWorkerCircuit(postResult)}`);
      }
      return;
    }
    this.registerRumSemanticRequest(workerRequest);
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

  public async handleRumCounterMailboxResponse(response: SDKWorkerResponse): Promise<boolean> {
    if (!response.ok) {
      this.logRumCounterMailboxFailure(response.errorMessage || 'unknown');
      return false;
    }
    if (!response.payload) {
      return false;
    }
    const payload = response.payload as Object as SDKRumCounterMailboxPayload;
    const applied = await this.handleRumCounterMailboxPayload(payload);
    if (applied) {
      this.markRumSemanticHostApplied(response.id);
      if (this.isRumCounterFlushBarrier(response, payload)) {
        this.acknowledgeRumSemanticThrough(response.id);
      }
    }
    return applied;
  }

  public async handleRumCounterMailboxPayload(payload: SDKRumCounterMailboxPayload): Promise<boolean> {
    if (!payload || !payload.deltas || payload.deltas.length === 0) {
      return true;
    }
    return await this.applyRumCounterDeltasFromWorker(payload);
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

  private isRumCounterFlushBarrier(response: SDKWorkerResponse, payload: SDKRumCounterMailboxPayload): boolean {
    return response.id.indexOf(`${SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH}:`) === 0 ||
      !!(payload.deltas && payload.deltas.length > 0);
  }

  private async applyRumCounterDeltasFromWorker(payload: SDKRumCounterMailboxPayload): Promise<boolean> {
    try {
      const context = this.context;
      const deltas = payload.deltas || [];
      if (!context || deltas.length === 0) {
        return context !== null;
      }

      // EVENT_CONSUMER returns finalized, zero-filtered View/Action deltas.
      const taskPoolDeltas = deltas as Object as FTDBTaskPoolRumCounterDeltaDTO[];
      await FTDBTaskPoolExecutor.applyRumCounterDeltas(context, taskPoolDeltas);
      const releasedResourceLifecycle = await this.releaseCompletedResourceLifecycleRegistrations(deltas);
      if (payload.needsActionCloseCheck === true) {
        this.checkActionClose();
      }
      if (payload.needsActionCloseCheck === true || releasedResourceLifecycle) {
        // A closed Action may no longer be active after the next click. Retry
        // its own close transition once the resource decrement is durable.
        this.retryPendingActionClosures();
      }
      if (payload.needsRumDataGenerate === true) {
        this.generateRumData();
      }
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `RUM counter worker delta apply failed: ${error}`);
      return false;
    }
  }

  private logRumCounterMailboxFailure(errorMessage: string): void {
    const now = Date.now();
    if (now - this.lastRumCounterMailboxFailureLogAt < FTRUMInnerManager.RUM_STATE_EVICTION_LOG_INTERVAL_MS) {
      return;
    }
    this.lastRumCounterMailboxFailureLogAt = now;
    FTInnerLogger.w(TAG, `RUM counter mailbox failed: ${errorMessage}`);
  }

  private submitCompletedActionWorkerInput(actionBean: ActionBean, traceBaseName: string): void {
    const actionId = actionBean.getId();
    try {
      if (this.insertedActionIds.has(actionId)) {
        FTInnerLogger.d(TAG, `[FT-ACTION-DEBUG] Action ${actionId} (${actionBean.getActionName()}) already inserted, skipping duplicate insert`);
        return;
      }

      this.rememberInsertedActionId(actionId);
      this.rememberProcessedActionId(actionId);
      this.submitCompletedActionWorkerRequest(actionBean, traceBaseName);
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Error scheduling completed action worker input: ${error}`);
      this.forgetInsertedActionId(actionId);
      this.forgetProcessedActionId(actionId);
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

      this.rememberInsertedActionId(actionId);
      this.rememberProcessedActionId(actionId);
      this.postCompletedActionWorkerRequest(actionId, actionName, payload, traceBaseName);
    } catch (error) {
      FTInnerLogger.e(TAG, `[FT-ACTION-DEBUG] Error scheduling completed action DTO: ${error}`);
      this.forgetInsertedActionId(actionId);
      this.forgetProcessedActionId(actionId);
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
    if (this.pendingCompletedActions.length >= FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE) {
      this.flushCompletedActionWorkerBatch(traceBaseName);
      return;
    }
    this.scheduleCompletedActionWorkerBatchFlush(traceBaseName);
  }

  private scheduleCompletedActionWorkerBatchFlush(
    traceBaseName: string,
    delayMs: number = FTRUMInnerManager.RUM_TRANSPORT_BATCH_DELAY_MS
  ): void {
    if (this.completedActionFlushTimer !== null) {
      return;
    }
    this.completedActionFlushTimer = setTimeout(() => {
      this.completedActionFlushTimer = null;
      this.flushCompletedActionWorkerBatch(traceBaseName);
    }, Math.max(1, delayMs)) as number;
  }

  private flushCompletedActionWorkerBatch(traceBaseName: string = 'rum.completedAction.batch'): void {
    if (this.completedActionFlushTimer !== null) {
      clearTimeout(this.completedActionFlushTimer);
      this.completedActionFlushTimer = null;
    }
    if (this.pendingCompletedActions.length === 0) {
      return;
    }

    const trackInner = FTTrackInner.getInstance();
    const lineContext: SDKLineProtocolContextDTO | null = trackInner.getWorkerLineProtocolContextSnapshot();
    trackInner.ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    const batchSize = Math.min(
      FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE,
      this.pendingCompletedActions.length
    );
    const batch = this.pendingCompletedActions.slice(0, batchSize);
    const actions: SDKRumCompletedActionDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      actions.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumCompletedActionBatchDTO = {
      actions
    };
    if (lineContext) {
      payload.lineContext = lineContext;
    }
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, `Completed action worker mailbox batch post failed: size=${batch.length}`);
      if (postResult.shouldRetry) {
        this.scheduleCompletedActionWorkerBatchFlush(traceBaseName, postResult.retryDelayMs);
      } else {
        this.degradePendingCompletedActions(this.describeEventWorkerCircuit(postResult));
      }
      return;
    }
    this.pendingCompletedActions.splice(0, batchSize);
    this.registerRumSemanticRequest(workerRequest);
    this.scheduleRumCounterFlush();
    if (this.pendingCompletedActions.length > 0) {
      this.scheduleCompletedActionWorkerBatchFlush(traceBaseName);
    }
  }

  public flushPendingWorkerCommandsBeforeUpload(): void {
    while (this.pendingErrorCommands.length > 0) {
      const before = this.pendingErrorCommands.length;
      this.flushErrorWorkerCommandBatch('upload.beforeQuery.error');
      if (this.pendingErrorCommands.length >= before) {
        break;
      }
    }
    while (this.pendingResourceCommands.length > 0) {
      const before = this.pendingResourceCommands.length;
      this.flushResourceWorkerCommandBatch('upload.beforeQuery.resource');
      if (this.pendingResourceCommands.length >= before) {
        break;
      }
    }
    while (this.pendingCompletedActions.length > 0) {
      const before = this.pendingCompletedActions.length;
      this.flushCompletedActionWorkerBatch('upload.beforeQuery.action');
      if (this.pendingCompletedActions.length >= before) {
        break;
      }
    }
    this.flushRumCounterUpdateBatch('upload.beforeQuery.counterUpdate', true);
    this.submitRumCounterFlushTask();
  }

  private createCompletedActionDTO(actionBean: ActionBean): SDKRumCompletedActionDTO {
    const payload: SDKRumCompletedActionDTO = {
      dataType: DataType.RUM_APP.toString(),
      measurement: Constants.FT_MEASUREMENT_RUM_ACTION,
      uuid: `action-${actionBean.getId()}`,
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
    this.attachCompletedActionDynamicTags(payload);
    return payload;
  }

  private attachCompletedActionDynamicTags(payload: SDKRumCompletedActionDTO): void {
    payload.rumAppId = this.getSemanticRumAppId();
    // User and network state are event attributes, absent from the shared static context.
    payload.dynamicTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
  }

  /**
   * Semantic Action/Resource/Error commands can be handled after a Worker
   * restart, before its shared line context is restored. Keep the routing tag
   * on the command itself so those events cannot lose their RUM application.
   */
  private getSemanticRumAppId(): string {
    return this.rumConfig ? this.rumConfig.getRumAppId() : '';
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
          
          for (const bean of beans) {
            const actionId = bean.getId();
            // Skip if already processed OR already inserted (double check for safety)
            if (this.processedActionIds.has(actionId) || this.insertedActionIds.has(actionId)) {
              // The worker result has not necessarily reached durable storage yet.
            } else {
              // Mark as processed immediately to prevent duplicate processing
              this.rememberProcessedActionId(actionId);
              unprocessedBeans.push(bean);
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
          
          // Deletion is deferred to the durable worker-result acknowledgement.
          
          // Then insert actions to sync table (only unprocessed ones)
          // Note: We delete after updating counts to ensure we can query the latest counts
          for (const bean of unprocessedBeans) {
            try {
              this.submitCompletedActionWorkerInput(bean, `rum.generateActionSum:${bean.getActionName()}`);
            } catch (error) {
              FTInnerLogger.e(TAG, `Error processing action ${bean.getActionName()}: ${error}`);
              // Remove from processed set if insert failed, so it can be retried
              this.forgetProcessedActionId(bean.getId());
            }
          }
          
        } catch (error) {
          FTInnerLogger.e(TAG, `Error querying actions from database: ${error}`);
          break;
        }
      } while (false); // One bounded page per tick; in-flight aggregates remain queryable until committed.
      
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
      } while (false); // Callbacks are asynchronous; do not loop on the same uncommitted page.
      
      // The persistence callback acknowledges and cleans only its own snapshot.
      // A View may close after this query while its open snapshot is in flight.
      
      
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
      
      // CPU monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)) {
        const cpuTickCountPerSecond = extraAttr.get("cpu_tick_count_per_second");
        const cpuTickCount = extraAttr.get("cpu_tick_count");
        this.appendNumericViewMetricField(
          fieldsMap,
          Constants.KEY_CPU_TICK_COUNT_PER_SECOND,
          cpuTickCountPerSecond
        );
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_CPU_TICK_COUNT, cpuTickCount);
      }
      
      // Memory monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)) {
        const memoryMax = extraAttr.get(Constants.KEY_MEMORY_MAX);
        const memoryAvg = extraAttr.get(Constants.KEY_MEMORY_AVG);
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_MEMORY_MAX, memoryMax);
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_MEMORY_AVG, memoryAvg);
      }
      
      // Battery monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)) {
        const batteryCurrentAvg = extraAttr.get(Constants.KEY_BATTERY_CURRENT_AVG);
        const batteryCurrentMax = extraAttr.get(Constants.KEY_BATTERY_CURRENT_MAX);
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_BATTERY_CURRENT_AVG, batteryCurrentAvg, true);
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_BATTERY_CURRENT_MAX, batteryCurrentMax, true);
      }
      
      // FPS monitoring (aligned with Android: if (FTMonitorManager.get().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)))
      if (FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
        const fpsAvg = extraAttr.get("fps_avg");
        const fpsMini = extraAttr.get("fps_mini");
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_FPS_AVG, fpsAvg);
        this.appendNumericViewMetricField(fieldsMap, Constants.KEY_FPS_MINI, fpsMini);
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
            fieldsMap.set(key, String(value));
          } else if (typeof value === 'object' && value !== null) {
            // If object has 'value' property (like MonitorValue), extract it directly
            if (value['value'] !== undefined) {
              fieldsMap.set(key, String(value['value']));
            } else {
              // Convert other objects to JSON string
              fieldsMap.set(key, JSON.stringify(value));
            }
          }
        }
      }
      
      // Call FTTrackInner.rum() to store the completed View snapshot in the
      // durable sync queue. The callback must acknowledge that exact snapshot:
      // a closed View can then be removed, while a View changed in the meantime
      // remains eligible for a later summary.
      const self = this;
      class ViewUploadCallback implements RunnerCompleteCallBack {
        private snapshot: ViewBean;
        constructor(snapshot: ViewBean) {
          this.snapshot = snapshot;
        }
        
        onComplete(): void {
          // The sync row is durable at this point; acknowledge only the state
          // used to build it. This prevents restart-time closeAllActionAndView
          // from turning already-persisted closed Views into new RUM rows.
          if (self.context) {
            self.acknowledgePersistedViewAfterComplete(self.context, this.snapshot);
          }
        }
      }
      
      // querySumView returns mutable beans. Freeze the version used for this
      // row so a concurrent close/counter update cannot acknowledge newer data.
      const callback = new ViewUploadCallback(ViewBean.fromJSON(viewBean.toJSON()));
      // Aligned with Android SDK: pass nanoseconds directly (19 digits) without conversion
      // Android SDK: FTTrackInner.getInstance().rum(bean.getStartTime(), ...)
      FTTrackInner.getInstance().rum(
        viewBean.getStartTime(),
        Constants.FT_MEASUREMENT_RUM_VIEW,
        tagsMap,
        fieldsMap,
        callback,
        null,
        `view-${viewBean.getId()}-${viewBean.getDataUpdateTime()}-${viewBean.getViewUpdateTime()}`
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error in insertView: ${error}`);
      // Remove from both sets if insert failed, so it can be retried
    }
  }

  /**
   * Monitor samples begin as primitive numbers in ActiveViewBean, then are
   * persisted by ViewBean as `{ value: string }`. Accept both representations
   * so a View can be serialized before or after its database round trip.
   */
  private appendNumericViewMetricField(
    fieldsMap: Map<string, string>,
    fieldName: string,
    rawValue: object | undefined,
    allowNegative: boolean = false
  ): void {
    if (rawValue === undefined || rawValue === null) {
      return;
    }
    const monitorValue = rawValue as MonitorValue;
    const scalarValue = monitorValue.value === undefined ? rawValue : monitorValue.value;
    const value = Number.parseFloat(String(scalarValue));
    if (Number.isFinite(value) && (allowNegative || value >= 0)) {
      fieldsMap.set(fieldName, String(value));
    }
  }

  private async acknowledgePersistedViewAfterComplete(context: Context, snapshot: ViewBean): Promise<void> {
    try {
      const success = await FTDBTaskPoolExecutor.acknowledgeView(context, snapshot);
      if (!success) {
        // The database contains a newer state. Ensure it is serialized even if
        // its earlier generation request overlapped the previous summary pass.
        this.generateRumData();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to acknowledge persisted view state: ${error}`);
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
    if (this.rumSemanticReplayTimer !== null) {
      clearTimeout(this.rumSemanticReplayTimer);
      this.rumSemanticReplayTimer = null;
    }
    if (this.pendingActionCloseRetryTimer !== null) {
      clearTimeout(this.pendingActionCloseRetryTimer);
      this.pendingActionCloseRetryTimer = null;
    }
    this.pendingRumCounterUpdates.clear();
    this.pendingCompletedActions = [];
    this.pendingResourceCommands = [];
    this.pendingErrorCommands = [];
    this.pendingResourceRegistrations.clear();
    this.pendingResourceContextRestores.clear();
    this.resourceContextById.clear();
    this.startedResourceIds.clear();
    this.startedResourceActionIds.clear();
    this.resourceContentSubmittedIds.clear();
    this.resourceNetStateSubmittedIds.clear();
    this.resourceStoppedIds.clear();
    this.pendingActionCloseStates.clear();
    this.pendingActionRecoveryStarted = false;
    this.pendingActionInsertions.clear();
    this.rumSemanticJournal = [];
    this.rumSemanticJournalHead = 0;
    this.rumSemanticJournalByRequestId.clear();
    this.rumSemanticSequence = 0;
    this.committedRumSemanticResponseIds.clear();
    this.committedRumSemanticResponseOrder = [];
    this.committedRumSemanticResponseOrderHead = 0;
    this.resourceDraftIdsById.clear();
    this.resourceDraftIdOrder = [];
    this.resourceDraftIdOrderHead = 0;
    this.completedRumResourceIds.clear();
    this.resourcePendingOrJournalRefCounts.clear();
    this.lastRumStateEvictionLogAt = 0;
    this.lastRumCounterMailboxFailureLogAt = 0;

    this.sessionId = Utils.generateUUID();
    this.rumAppId = "";
    this.context = null;
    this.sampleRate = 1.0;
    this.sessionErrorSampleRate = 0.0;
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
    this.clearActionIdLedgers();
    this.actionInsertLock = Promise.resolve();
    this.viewOperationLock = Promise.resolve();
    this.sessionRefreshLock = Promise.resolve();
    this.preferencesStore = null;
    this.preferencesInitialized = false;
    this.preferencesInitPromise = null;
    this.rumContextPersistChain = Promise.resolve();
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

    // Actions that were waiting for Resources before a process restart have
    // no active in-memory owner. Rebuild their close state from RDB so a
    // later Resource callback can still finalize the original Action.
    if (isFTCacheSqlitePrimary(FTCacheContext.settings.mode)) {
      this.recoverPendingActionClosures();
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

    const context = this.context;
    this.preferencesInitPromise = preferences.getPreferences(context, {
      name: FTRUMInnerManager.PREFERENCES_NAME
    }).then((store: preferences.Preferences) => {
      this.preferencesStore = store;
    }).catch((error: Error) => {
      FTInnerLogger.e(TAG, `Failed to initialize RUM context preferences: ${error.message}`);
    });
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
    const viewId = this.activeView?.getId() || '';
    const viewName = this.activeView?.getViewName() || '';
    const viewReferrer = this.activeView?.getViewReferrer() || '';
    const sessionId = this.sessionId;
    const snapshot: FTRUMCrashRecoveryContext = { viewId, viewName, viewReferrer, sessionId };

    if (!this.preferencesStore && this.preferencesInitPromise) {
      await this.preferencesInitPromise;
    }
    const store = this.preferencesStore;
    if (!store) {
      FTInnerLogger.w(TAG, "Preferences store not available, skipping RUM context save");
      return;
    }

    const persist = async (): Promise<void> => {
      // Use put() followed by flush() to ensure data is written immediately
      // This is critical for crash reporting - we need the data saved before the crash handler runs
      await store.put(FTRUMInnerManager.KEY_VIEW_ID, snapshot.viewId);
      await store.put(FTRUMInnerManager.KEY_VIEW_NAME, snapshot.viewName);
      await store.put(FTRUMInnerManager.KEY_VIEW_REFERRER, snapshot.viewReferrer);
      await store.put(FTRUMInnerManager.KEY_SESSION_ID, snapshot.sessionId);
      await store.flush();
    };
    this.rumContextPersistChain = this.rumContextPersistChain.then(persist).catch((error: Error) => {
      const errorMsg = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to save RUM context: ${errorMsg}`);
    });
    await this.rumContextPersistChain;
  }

  /**
   * Get saved RUM context from preferences (for crash recovery)
   * Returns an object with viewId, viewName, viewReferrer, and sessionId
   */
  public async getSavedRumContext(): Promise<FTRUMCrashRecoveryContext> {
    const defaultContext: FTRUMCrashRecoveryContext = {
      viewId: '',
      viewName: '',
      viewReferrer: '',
      sessionId: ''
    };

    if (!this.preferencesStore && this.preferencesInitPromise) {
      await this.preferencesInitPromise;
    }
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
      const result: FTRUMCrashRecoveryContext = { viewId, viewName, viewReferrer, sessionId };
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
    this.clearSavedRumContextWhenReady();
  }

  private async clearSavedRumContextWhenReady(): Promise<void> {
    if (!this.preferencesStore && this.preferencesInitPromise) {
      await this.preferencesInitPromise;
    }
    if (!this.preferencesStore) {
      FTInnerLogger.w(TAG, "Preferences store not available, skipping RUM context clear");
      return;
    }
    const store = this.preferencesStore;
    this.rumContextPersistChain = this.rumContextPersistChain.then(async () => {
      await this.clearSavedRumContextAsync(store);
    }).catch((error: Error) => {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `Failed to clear saved RUM context: ${errorMessage}`);
    });
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
        
        // A View change closes the Action to new events, but an already-started
        // Resource still owns its durable Action reference and must be allowed
        // to write its final counters before this Action is generated.
        if (this.activeAction && !this.activeAction.isActionClose()) {
          this.activeAction.close();
          this.closeAction(this.activeAction);
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
      
      // Begin the View-scoped device metrics collection before the View is persisted.
      FTMonitorManager.getInstance().addMonitor(this.activeView.getId());
      this.collectInitialViewMetrics(this.activeView);

      // Initialize view
      this.initView(this.activeView);
      this.generateRumData();
      // Save RUM context to preferences for crash recovery
      this.saveRumContext();

      FTInnerLogger.d(TAG,
        `View started: name=${viewName}, referrer=${viewReferrer}, loadTimeNs=${loadTime}, id=${this.activeView.getId()}`);

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
        FTInnerLogger.w(TAG, "stopView ignored: no active view");
        return;
      }
      
      // Idempotency check: if view is already closed, skip to prevent duplicate processing
      // This handles cases where stopView() is called multiple times (e.g., onBackground + onDestroy)
      if (this.activeView.isClose()) {
        FTInnerLogger.d(TAG, `stopView skipped closed view: ${this.activeView.getViewName()}`);
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
   * @param duration Load time in nanoseconds
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
      this.attachCompletedActionDynamicTags(payload);
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
        this.closeAction(this.activeAction);
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
      actionName,
      rumAppId: this.getSemanticRumAppId(),
      dynamicTags: FTRUMConfigManager.getInstance().getRUMPublicDynamicTags()
    };
  }

  private submitResourceWorkerCommand(command: SDKRumResourceCommandDTO, traceBaseName: string): boolean {
    if (!this.context || !command || !command.resourceId) {
      return false;
    }
    const supportsPendingResourcePersistence = isFTCacheSqlitePrimary(FTCacheContext.settings.mode);
    const registration = supportsPendingResourcePersistence ?
      this.pendingResourceRegistrations.get(command.resourceId) : undefined;
    if (registration) {
      registration.then((registered: boolean): void => {
        this.pendingResourceRegistrations.delete(command.resourceId);
        if (!registered) {
          FTInnerLogger.e(TAG, `Skipping Resource command because its pending state was not persisted: ${command.resourceId}`);
          this.clearResourceLifecycleRegistration(command.resourceId);
          this.retryPendingActionClosures();
          return;
        }
        this.enqueueResourceWorkerCommand(command, traceBaseName);
      }).catch((error: Error): void => {
        FTInnerLogger.e(TAG, `Pending Resource registration failed: ${command.resourceId}, ${error.message}`);
        this.clearResourceLifecycleRegistration(command.resourceId);
        this.retryPendingActionClosures();
      });
      return true;
    }

    // After a process restart the original action is no longer active in
    // memory. Restore the context and stable draft IDs before processing the
    // callback so Resource/Error retain the original action_id.
    // Callers may create a temporary context before they submit an add/content
    // or network callback. That context is not evidence that this process saw
    // the original start. After a restart, use the durable row unless this
    // process owns a start marker, so the callback cannot overwrite the
    // original Action association.
    if (supportsPendingResourcePersistence && command.commandType !== 'start' &&
      !this.startedResourceIds.has(command.resourceId)) {
      this.restorePendingResourceContext(command.resourceId).then(
        (pending: FTDBTaskPoolPendingRumResourceDTO | null): void => {
          if (pending) {
            command.context = pending.context;
            command.draftUuid = pending.draftUuid;
            command.errorDraftUuid = pending.errorDraftUuid;
          }
          this.enqueueResourceWorkerCommand(command, traceBaseName);
        }
      ).catch((error: Error): void => {
        FTInnerLogger.e(TAG, `Failed to restore pending Resource context: ${command.resourceId}, ${error.message}`);
      });
      return true;
    }
    return this.enqueueResourceWorkerCommand(command, traceBaseName);
  }

  private restorePendingResourceContext(
    resourceId: string
  ): Promise<FTDBTaskPoolPendingRumResourceDTO | null> {
    const existing = this.pendingResourceContextRestores.get(resourceId);
    if (existing) {
      return existing;
    }
    const context = this.context;
    if (!context) {
      return Promise.resolve(null);
    }
    const restore = FTDBTaskPoolExecutor.getPendingRumResource(context, resourceId).then(
      (pending: FTDBTaskPoolPendingRumResourceDTO | null): FTDBTaskPoolPendingRumResourceDTO | null => {
        if (pending) {
          this.resourceContextById.set(resourceId, pending.context);
          this.startedResourceIds.add(resourceId);
          this.startedResourceActionIds.set(resourceId, pending.context.actionId);
          this.resourceDraftIdsById.set(resourceId, {
            resourceUuid: pending.draftUuid,
            errorUuid: pending.errorDraftUuid
          });
        }
        return pending;
      }
    ).finally((): void => {
      this.pendingResourceContextRestores.delete(resourceId);
    });
    this.pendingResourceContextRestores.set(resourceId, restore);
    return restore;
  }

  private enqueueResourceWorkerCommand(command: SDKRumResourceCommandDTO, traceBaseName: string): boolean {
    if (!this.context || !command || !command.resourceId) {
      return false;
    }
    const draftIds = this.getOrCreateResourceDraftIds(command.resourceId);
    command.draftUuid = draftIds.resourceUuid;
    command.errorDraftUuid = draftIds.errorUuid;
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    this.pendingResourceCommands.push({
      payload: command
    });
    this.retainResourceTransportReference(command.resourceId);
    if (this.pendingResourceCommands.length >= FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE) {
      this.flushResourceWorkerCommandBatch(traceBaseName);
      return true;
    }
    this.scheduleResourceWorkerCommandBatchFlush(traceBaseName);
    return true;
  }

  private scheduleResourceWorkerCommandBatchFlush(
    traceBaseName: string,
    delayMs: number = FTRUMInnerManager.RUM_TRANSPORT_BATCH_DELAY_MS
  ): void {
    if (this.resourceCommandFlushTimer !== null) {
      return;
    }
    this.resourceCommandFlushTimer = setTimeout(() => {
      this.resourceCommandFlushTimer = null;
      this.flushResourceWorkerCommandBatch(traceBaseName);
    }, Math.max(1, delayMs)) as number;
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
      FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE,
      this.pendingResourceCommands.length
    );
    const batch = this.pendingResourceCommands.slice(0, batchSize);
    const commands: SDKRumResourceCommandDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      commands.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumResourceCommandBatchDTO = {
      commands
    };
    const lineContext = FTTrackInner.getInstance().getWorkerLineProtocolContextSnapshot();
    if (lineContext) {
      payload.lineContext = lineContext;
    }
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, `RUM resource worker mailbox batch post failed: size=${batch.length}`);
      if (postResult.shouldRetry) {
        this.scheduleResourceWorkerCommandBatchFlush(traceBaseName, postResult.retryDelayMs);
      } else {
        this.degradePendingResourceCommands(this.describeEventWorkerCircuit(postResult));
      }
      return;
    }
    this.pendingResourceCommands.splice(0, batchSize);
    this.registerRumSemanticRequest(workerRequest);
    this.scheduleRumCounterFlush();
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

  private resourcePropertyToRecord(property: Map<string, object>): SDKPropertyRecord {
    const record: SDKPropertyRecord = {};
    if (!property || property.size === 0) {
      return record;
    }
    property.forEach((value: object, key: string) => {
      if (value !== null && value !== undefined) {
        record[key] = this.toRumPropertyTransferValue(value);
      }
    });
    return record;
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
  }

  private submitErrorWorkerCommand(command: SDKRumErrorCommandDTO, traceBaseName: string): void {
    if (!this.context || !command || !command.context || !command.context.sessionId) {
      return;
    }
    if (!command.uuid || command.uuid.length === 0) {
      command.uuid = Utils.generateUUID();
    }
    FTTrackInner.getInstance().ensureWorkerLineProtocolContextSynced(SDKDedicatedPoolType.EVENT_CONSUMER);
    this.pendingErrorCommands.push({
      payload: command
    });
    if (this.pendingErrorCommands.length >= FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE) {
      this.flushErrorWorkerCommandBatch(traceBaseName);
      return;
    }
    this.scheduleErrorWorkerCommandBatchFlush(traceBaseName);
  }

  private scheduleErrorWorkerCommandBatchFlush(
    traceBaseName: string,
    delayMs: number = FTRUMInnerManager.RUM_TRANSPORT_BATCH_DELAY_MS
  ): void {
    if (this.errorCommandFlushTimer !== null) {
      return;
    }
    this.errorCommandFlushTimer = setTimeout(() => {
      this.errorCommandFlushTimer = null;
      this.flushErrorWorkerCommandBatch(traceBaseName);
    }, Math.max(1, delayMs)) as number;
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
      FTRUMInnerManager.RUM_TRANSPORT_BATCH_SIZE,
      this.pendingErrorCommands.length
    );
    const batch = this.pendingErrorCommands.slice(0, batchSize);
    const commands: SDKRumErrorCommandDTO[] = [];
    for (let i = 0; i < batch.length; i++) {
      commands.push(batch[i].payload);
    }

    const traceName = this.nextRumEventTaskName(`${traceBaseName}.batch`);
    const payload: SDKRumErrorCommandBatchDTO = {
      commands
    };
    const lineContext = FTTrackInner.getInstance().getWorkerLineProtocolContextSnapshot();
    if (lineContext) {
      payload.lineContext = lineContext;
    }
    const workerRequest: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH}:${traceName}:${Date.now()}`,
      pool: SDKDedicatedPoolType.EVENT_CONSUMER,
      command: SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH,
      priority: SDKTaskPriority.HIGH,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };

    const postResult = SDKDedicatedPoolManager.getInstance().postCommandWithRetryPolicy(workerRequest);
    if (!postResult.posted) {
      FTInnerLogger.e(TAG, `RUM error worker mailbox batch post failed: size=${batch.length}`);
      if (postResult.shouldRetry) {
        this.scheduleErrorWorkerCommandBatchFlush(traceBaseName, postResult.retryDelayMs);
      } else {
        this.degradePendingErrorCommands(this.describeEventWorkerCircuit(postResult));
      }
      return;
    }
    this.pendingErrorCommands.splice(0, batchSize);
    this.registerRumSemanticRequest(workerRequest);
    this.scheduleRumCounterFlush();
    if (this.pendingErrorCommands.length > 0) {
      this.scheduleErrorWorkerCommandBatchFlush(traceBaseName);
    }
  }

  private degradePendingRumCounterUpdates(reason: string): void {
    if (this.rumCounterUpdateFlushTimer !== null) {
      clearTimeout(this.rumCounterUpdateFlushTimer);
      this.rumCounterUpdateFlushTimer = null;
    }
    const dropped = this.getPendingRumCounterUpdateCount();
    this.pendingRumCounterUpdates.clear();
    FTInnerLogger.w(TAG, `RUM counter transport degraded: dropped=${dropped}, ${reason}`);
  }

  private getPendingRumCounterUpdateCount(): number {
    let count = 0;
    const pendingUpdates = Array.from(this.pendingRumCounterUpdates.values());
    for (let i = 0; i < pendingUpdates.length; i++) {
      count += this.normalizeRumCounterUpdateCount(pendingUpdates[i].count);
    }
    return count;
  }

  private degradePendingCompletedActions(reason: string): void {
    if (this.completedActionFlushTimer !== null) {
      clearTimeout(this.completedActionFlushTimer);
      this.completedActionFlushTimer = null;
    }
    const dropped = this.pendingCompletedActions.length;
    for (let i = 0; i < this.pendingCompletedActions.length; i++) {
      const actionId = this.pendingCompletedActions[i].actionId;
      this.forgetInsertedActionId(actionId);
      this.forgetProcessedActionId(actionId);
    }
    this.pendingCompletedActions = [];
    FTInnerLogger.w(TAG, `Completed action transport degraded: dropped=${dropped}, ${reason}`);
  }

  private degradePendingResourceCommands(reason: string): void {
    if (this.resourceCommandFlushTimer !== null) {
      clearTimeout(this.resourceCommandFlushTimer);
      this.resourceCommandFlushTimer = null;
    }
    const dropped = this.pendingResourceCommands.length;
    const resourceIds: string[] = [];
    for (let i = 0; i < this.pendingResourceCommands.length; i++) {
      const resourceId = this.pendingResourceCommands[i].payload.resourceId;
      if (resourceId && resourceId.length > 0) {
        resourceIds.push(resourceId);
      }
    }
    this.pendingResourceCommands = [];
    this.releaseResourceTransportReferences(resourceIds);
    this.discardUncommittedResourceTransportState(resourceIds);
    FTInnerLogger.w(TAG, `RUM resource transport degraded: dropped=${dropped}, ${reason}`);
  }

  private degradePendingErrorCommands(reason: string): void {
    if (this.errorCommandFlushTimer !== null) {
      clearTimeout(this.errorCommandFlushTimer);
      this.errorCommandFlushTimer = null;
    }
    const dropped = this.pendingErrorCommands.length;
    this.pendingErrorCommands = [];
    FTInnerLogger.w(TAG, `RUM error transport degraded: dropped=${dropped}, ${reason}`);
  }

  private degradeAcknowledgedRumSemanticRecovery(reason: string): void {
    if (this.rumSemanticReplayTimer !== null) {
      clearTimeout(this.rumSemanticReplayTimer);
      this.rumSemanticReplayTimer = null;
    }
    const retained: RumSemanticJournalEntry[] = [];
    let dropped = 0;
    for (let i = this.rumSemanticJournalHead; i < this.rumSemanticJournal.length; i++) {
      const entry = this.rumSemanticJournal[i];
      if (entry.workerAcknowledged) {
        this.rumSemanticJournalByRequestId.delete(entry.request.id);
        this.rememberCommittedRumSemanticResponse(entry.request.id);
        this.releaseResourceTransportReferences(entry.resourceIds);
        this.discardUncommittedResourceTransportState(entry.resourceIds);
        dropped++;
      } else {
        retained.push(entry);
      }
    }
    this.rumSemanticJournal = retained;
    this.rumSemanticJournalHead = 0;
    FTInnerLogger.w(TAG, `RUM semantic recovery degraded: dropped=${dropped}, ${reason}`);
  }

  private describeEventWorkerCircuit(result: SDKWorkerMailboxPostResult): string {
    return `circuitOpen=${result.circuitOpen}, failures=${result.consecutiveFailures}`;
  }

  private propertyToRecord(property: Record<string, object> | null | undefined): SDKPropertyRecord {
    const record: SDKPropertyRecord = {};
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
      record[key] = this.toRumPropertyTransferValue(value);
    }
    return record;
  }

  private isCrashFreeDurationError(errorType: string): boolean {
    return RUMEnumUtils.isCrashErrorType(errorType);
  }

  private async prepareCrashFreeDuration(
    errorType: string,
    state: AppState,
    property: Record<string, object> | null,
    nativeCrashRecoveryId?: string
  ): Promise<FTCrashFreeDuration | null | undefined> {
    if (!this.isCrashFreeDurationError(errorType)) {
      return undefined;
    }
    const isPreCrash = this.readCrashPropertyText(property, IS_PRE_CRASH) === 'true';
    const crashWallClockMs = this.readCrashPropertyNumber(property, Constants.KEY_TIMESTAMP);
    // The HarmonyOS `uuid` value is a crash fingerprint: separate crashes at
    // the same C++ stack share it. Native recovery supplies the per-process
    // event id separately so duplicate suppression cannot hide a later crash.
    const nativeCrashId = nativeCrashRecoveryId && nativeCrashRecoveryId.length > 0 ?
      nativeCrashRecoveryId : this.readCrashPropertyText(property, Constants.KEY_UUID);
    return await FTCrashFreeDurationManager.getInstance().prepareCrashFreeDuration(
      state,
      isPreCrash,
      crashWallClockMs,
      nativeCrashId
    );
  }

  private appendCrashFreeDurationFields(
    property: Record<string, object> | null,
    duration: FTCrashFreeDuration
  ): Record<string, object> {
    const merged: Record<string, object> = {};
    if (property !== null) {
      const keys = FTRUMInnerManager.getObjectKeys(property);
      for (let index = 0; index < keys.length; index++) {
        const key = keys[index];
        merged[key] = property[key];
      }
    }
    merged[Constants.KEY_RUM_ERROR_FOREGROUND_CRASH_FREE_DURATION] =
      this.createCrashDurationProperty(duration.foregroundNs);
    merged[Constants.KEY_RUM_ERROR_BACKGROUND_CRASH_FREE_DURATION] =
      this.createCrashDurationProperty(duration.backgroundNs);
    return merged;
  }

  /** `is_pre_crash` controls recovery only and must not become an Error field. */
  private stripCrashRecoveryProperty(property: Record<string, object> | null): Record<string, object> | null {
    if (property === null || property[IS_PRE_CRASH] === undefined) {
      return property;
    }
    const result: Record<string, object> = {};
    const keys = FTRUMInnerManager.getObjectKeys(property);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      if (key !== IS_PRE_CRASH) {
        result[key] = property[key];
      }
    }
    return result;
  }

  private createCrashDurationProperty(value: number): object {
    const wrapper = new Object() as PropertyWrapper;
    wrapper.value = Math.max(0, Math.floor(value));
    return wrapper as object;
  }

  private readCrashPropertyText(property: Record<string, object> | null, key: string): string {
    if (property === null || property[key] === undefined || property[key] === null) {
      return '';
    }
    const value = property[key] as PropertyWrapper;
    if (value && value.value !== undefined && value.value !== null) {
      return String(value.value);
    }
    return String(property[key]);
  }

  private readCrashPropertyNumber(property: Record<string, object> | null, key: string): number {
    const numericValue = Number.parseFloat(this.readCrashPropertyText(property, key));
    return Number.isFinite(numericValue) && numericValue >= 0 ? numericValue : 0;
  }

  /** Strip ArkTS class prototypes at the Worker transfer boundary only. */
  private toRumPropertyTransferValue(value: object): object {
    try {
      const json = JSON.stringify(value);
      if (json && json.length > 0) {
        const cloned = JSON.parse(json) as object;
        if (typeof cloned === 'object' && cloned !== null) {
          return cloned;
        }
        const primitiveWrapper = new Object() as PropertyWrapper;
        primitiveWrapper.value = String(cloned);
        return primitiveWrapper;
      }
    } catch (_) {
    }
    const fallbackWrapper = new Object() as PropertyWrapper;
    fallbackWrapper.value = String(value);
    return fallbackWrapper;
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
      if (this.startedResourceIds.has(resourceId)) {
        FTInnerLogger.d(TAG, `Duplicate resource start ignored: ${resourceId}`);
        return;
      }
      // Refresh session
      this.checkSessionRefresh(true);

      const context = this.createCurrentResourceContext();
      const startTime = Utils.getCurrentNanoTime();
      this.startedResourceIds.add(resourceId);
      this.startedResourceActionIds.set(resourceId, context.actionId);
      this.resourceContentSubmittedIds.delete(resourceId);
      this.resourceNetStateSubmittedIds.delete(resourceId);
      this.resourceStoppedIds.delete(resourceId);
      this.completedRumResourceIds.delete(resourceId);
      this.resourceDraftIdsById.delete(resourceId);
      const draftIds = this.getOrCreateResourceDraftIds(resourceId);
      this.resourceContextById.set(resourceId, context);
      this.updateResourceContextMemoryOnStart(context);
      if (isFTCacheSqlitePrimary(FTCacheContext.settings.mode)) {
        const pendingResource: FTDBTaskPoolPendingRumResourceDTO = {
          resourceId,
          startTime,
          context,
          draftUuid: draftIds.resourceUuid,
          errorDraftUuid: draftIds.errorUuid
        };
        const registration = FTDBTaskPoolExecutor.registerPendingRumResource(this.context!, pendingResource)
          .catch((error: Error): boolean => {
            FTInnerLogger.e(TAG, `Failed to persist pending Resource ${resourceId}: ${error.message}`);
            return false;
          });
        this.pendingResourceRegistrations.set(resourceId, registration);
      }
      this.submitResourceWorkerCommand({
        commandType: 'start',
        resourceId,
        context,
        property: this.propertyToRecord(property),
        startTime,
        draftUuid: draftIds.resourceUuid,
        errorDraftUuid: draftIds.errorUuid,
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
  public stopResource(resourceId: string, property: Record<string, object> = {}): void {
    this.stopResourceInternal(resourceId, '', property);
  }

  /**
   * Stops a Resource while preserving the Action association captured by internal interceptors.
   * This is an SDK-internal bridge and must not be exposed through FTRUMGlobalManager.
   */
  public stopResourceInternal(
    resourceId: string,
    fallbackActionId: string = '',
    property: Record<string, object> = {}
  ): void {
    try {
      if (this.resourceStoppedIds.has(resourceId)) {
        FTInnerLogger.d(TAG, `Duplicate resource stop ignored: ${resourceId}`);
        return;
      }
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext(fallbackActionId);
      this.updateResourceContextMemoryOnStop(context);
      this.submitResourceWorkerCommand({
        commandType: 'stop',
        resourceId,
        context,
        property: this.propertyToRecord(property),
        endTime: Utils.getCurrentNanoTime(),
        fallbackActionId,
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.stop');
      this.scheduleRumCounterFlush();
      this.markResourceStopped(resourceId);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error stopping resource ${resourceId}: ${error}`);
    }
  }
  
  /**
   * Add error information for SDK internals.
   * 
   * @param log       log
   * @param message   message
   * @param errorType error type
   * @param state     program running state
   * @param property  additional attribute parameters (optional)
   * @param dateline  occurrence time, nanosecond (optional, defaults to current time)
   * @param callBack  thread pool call back (optional)
   */
  public async addErrorInternal(
    log: string, 
    message: string, 
    errorType: string,
    state: AppState, 
    property?: Record<string, object> | null, 
    dateline?: number,
    callBack?: RunnerCompleteCallBack | null,
    draftUuid?: string,
    nativeCrashRecoveryId?: string,
    recoveryContext?: FTRUMCrashRecoveryContext | null
  ): Promise<void> {
    const actualDateline = dateline !== undefined ? dateline : Utils.getCurrentNanoTime();
    const actualProperty = property !== undefined ? property : null;
    const validRecoveryContext: FTRUMCrashRecoveryContext | null =
      hasFTRUMCrashRecoveryContext(recoveryContext) ? recoveryContext as FTRUMCrashRecoveryContext : null;
    const actualCallBack = callBack !== undefined ? callBack : null;
    try {
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

      const errorDeviceData = this.getErrorDeviceData();
      const monitorFields = errorDeviceData.fields;
      let effectiveProperty: Record<string, object> | null = actualProperty;
      const monitorFieldKeys = Object.keys(monitorFields);
      if (monitorFieldKeys.length > 0) {
        const mergedProperty: Record<string, object> = {};
        if (actualProperty !== null) {
          const propertyKeys = FTRUMInnerManager.getObjectKeys(actualProperty);
          for (let i = 0; i < propertyKeys.length; i++) {
            const key = propertyKeys[i];
            mergedProperty[key] = actualProperty[key];
          }
        }
        for (let i = 0; i < monitorFieldKeys.length; i++) {
          const key = monitorFieldKeys[i];
          mergedProperty[key] = monitorFields[key];
        }
        effectiveProperty = mergedProperty;
      }

      const crashFreeDuration = await this.prepareCrashFreeDuration(
        errorType,
        state,
        effectiveProperty,
        nativeCrashRecoveryId
      );
      // A native crash id is acknowledged only after its Error data is stored.
      // Suppress an already-acknowledged crash file before it reaches counters.
      if (crashFreeDuration === null && this.isCrashFreeDurationError(errorType)) {
        return;
      }
      if (crashFreeDuration !== undefined && crashFreeDuration !== null) {
        effectiveProperty = this.appendCrashFreeDurationFields(effectiveProperty, crashFreeDuration);
      }
      
	      if (crashFreeDuration === undefined || crashFreeDuration === null || !crashFreeDuration.isPreCrash) {
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

      effectiveProperty = this.stripCrashRecoveryProperty(effectiveProperty);

	      if (actualCallBack === null && crashFreeDuration === undefined) {
	        const context = this.createCurrentResourceContext();
	        this.increaseErrorMemoryCount(context);
	        this.submitErrorWorkerCommand({
	          context,
	          log,
	          message,
	          errorType,
          errorSource: ErrorSource.LOGGER.toString(),
          appState: state.toString(),
          property: this.propertyToRecord(effectiveProperty),
          deviceTags: errorDeviceData.tags,
          time: actualDateline,
	          customDataType: this.getResourceCustomDataType(collectType),
	          uuid: draftUuid,
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
      
      // Historical crashes are correlated to their predecessor View and must
      // never inherit a View or Action created after process restart.
      if (validRecoveryContext !== null) {
        applyFTRUMCrashRecoveryContext(allTags, validRecoveryContext);
      } else {
        this.attachRUMRelative(allTags,true);
      }

      const errorDeviceTagKeys = Object.keys(errorDeviceData.tags);
      for (let i = 0; i < errorDeviceTagKeys.length; i++) {
        const key = errorDeviceTagKeys[i];
        allTags[key] = errorDeviceData.tags[key];
      }

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
      if (effectiveProperty != null) {
        const propertyKeys = FTRUMInnerManager.getObjectKeys(effectiveProperty);
        for (let i = 0; i < propertyKeys.length; i++) {
          const key = propertyKeys[i];
          const obj = (effectiveProperty as Record<string, object>)[key];
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
          const completeError = (): void => {
            if (actualCallBack != null) {
              self.stopViewAfterErrorCallback(actualCallBack);
            }
          };
          if (crashFreeDuration !== undefined && crashFreeDuration !== null) {
            FTCrashFreeDurationManager.getInstance().confirmCrashReported(crashFreeDuration)
              .then(completeError)
              .catch((error: Error): void => {
                FTInnerLogger.w(TAG, `Unable to confirm crash-free duration reset: ${error.message}`);
                completeError();
              });
            return;
          }
          completeError();
        }
      }
      const callback = new ErrorCallback();

      FTTrackInner.getInstance().rumRecords(
        actualDateline,
        Constants.FT_MEASUREMENT_RUM_ERROR,
        allTags,
        allFields,
        callback,
        collectType,
        draftUuid
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding error: ${error}`);
      // Crash callbacks acknowledge recovery state. They must never run from
      // an in-memory failure path because no Error row was persisted.
      if (actualCallBack != null && !this.isCrashFreeDurationError(errorType)) {
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
      if (this.resourceContentSubmittedIds.has(resourceId)) {
        FTInnerLogger.d(TAG, `Duplicate resource content ignored: ${resourceId}`);
        return;
      }
      // A resource can finish after another action starts. Keep the context
      // captured when this resource started so its resource and network-error
      // events remain associated with the initiating action.
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext();
      if (!storedContext) {
        this.resourceContextById.set(resourceId, context);
      }
      const collectType = this.checkSessionWillCollect(context.sessionId);
      const resourceParams = this.createResourceParamsDTO(resourceId, params);
      this.submitResourceWorkerCommand({
        commandType: 'add',
        resourceId,
        context,
        params: resourceParams,
        netStatus: this.createResourceNetStatusDTO(netStatusBean),
        eventTime: Utils.getCurrentNanoTime(),
        // stopResource may be queued behind an asynchronous persistence or
        // recovery barrier. Keep addResource from finalizing first if this
        // lifecycle has already been stopped on the Host.
        awaitStopCommand: this.resourceStoppedIds.has(resourceId),
        shouldCollect: collectType !== CollectType.DROP,
        customDataType: this.getResourceCustomDataType(collectType),
        counterFlushMaxEvents: FTRUMInnerManager.RUM_COUNTER_FLUSH_MAX_EVENTS
      }, 'rum.resource.add');
      this.markResourceContentSubmitted(resourceId);
      this.resourceNetStateSubmittedIds.add(resourceId);
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
      if (this.resourceContentSubmittedIds.has(resourceId)) {
        FTInnerLogger.d(TAG, `Duplicate resource content ignored: ${resourceId}`);
        return;
      }
      const storedContext = this.resourceContextById.get(resourceId);
      const context = storedContext || this.createCurrentResourceContext();
      this.resourceContextById.set(resourceId, context);
      const collectType = this.checkSessionWillCollect(context.sessionId);
      const resourceParams = this.createResourceParamsDTO(resourceId, params);
      this.submitResourceWorkerCommand({
        commandType: 'setContent',
        resourceId,
        context,
        params: resourceParams,
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
      if (this.resourceNetStateSubmittedIds.has(resourceId)) {
        FTInnerLogger.d(TAG, `Duplicate resource network state ignored: ${resourceId}`);
        return;
      }
      FTInnerLogger.d(TAG, `setNetState: resourceId=${resourceId}, netStatus=${JSON.stringify(netStatusBean.toJSON())}`);
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
      this.resourceNetStateSubmittedIds.add(resourceId);
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
   * Records navigation-tracker view load time. This is an SDK-internal automatic
   * tracking entry point and is intentionally not exposed through FTRUMGlobalManager.
   * 
   * @param viewName View name
   * @param loadTime Load time in nanoseconds
   */
  public recordViewLoadTimeInternal(viewName: string, loadTime: number): void {
    if (viewName && viewName.length > 0 && loadTime > 0) {
      this.preActivityDuration.set(viewName, loadTime);
      
      // If activeView already exists, update it with the recorded loadTime.
      // This handles load-time records that arrive after a manual startView call.
      // Also handles the case where startView is called multiple times (e.g., navigation tracker + manual call)
      // Keep the latest automatic-tracking load time when a matching view already exists.
      if (this.activeView && this.activeView.getViewName() === viewName) {
        // Always update loadTime if activeView exists, even if it's not -1
        // This ensures loadTime is preserved even if startView is called multiple times
        this.activeView.setLoadTime(loadTime);
      }
    } else {
      FTInnerLogger.w(TAG, `recordViewLoadTimeInternal: invalid parameters, viewName=${viewName}, loadTime=${loadTime}`);
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
      return loadTime;
    }
    
    // Fallback to onCreate time
    if (this.preActivityDuration.has(viewName)) {
      const loadTime = this.preActivityDuration.get(viewName)!;
      this.preActivityDuration.delete(viewName);
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
          FTMonitorManager.getInstance().addMonitor(this.activeView.getId());
          this.collectInitialViewMetrics(this.activeView);
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
    
    // The normal timeout ends the active Action in memory. Its database row
    // remains available until every Resource started by that Action has
    // settled its Resource/Error counter deltas.
    const timeOut = now - lastActionTime > ActiveActionBean.ACTION_NEED_WAIT_TIME_OUT;

    const viewChanged = this.activeView && 
                       !(this.activeView.getId().localeCompare(this.activeAction.getViewId()) === 0);


    // Aligned with Android SDK logic (see FTRUMInnerManager.java:277-292):
    // - If waiting (needWaitAction && view not closed), action waits
    // - If it has pending Resources, its database row waits for their durable completion
    // - Otherwise, check normal timeout (100ms), timeout (5s), or view changed
    const needClose = (!waiting && 
                      (now - lastActionTime >= ActiveActionBean.ACTION_NORMAL_TIME_OUT)) ||
                     timeOut || viewChanged;
    
    if (needClose && !this.activeAction.isActionClose()) {
      this.activeAction.close();
      // A closed Action remains in RDB until every persisted Resource reference
      // finishes and its Resource/Error counters are durably recorded.
      this.closeAction(this.activeAction);
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
  
  /** Maintains compact FIFO prefixes for the bounded action de-dup windows. */
  private cleanupSetCollections(): void {
    try {
      this.compactProcessedActionIdOrder();
      this.compactInsertedActionIdOrder();
      
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

  /**
   * Match Android's create-view behavior without blocking navigation on the
   * Worker round trip. A final snapshot is still captured before View close.
   */
  private collectInitialViewMetrics(activeViewBean: ActiveViewBean): void {
    void FTMonitorManager.getInstance().attachMonitorData(activeViewBean, false).catch((error: Error) => {
      FTInnerLogger.w(TAG, `Failed to capture initial View metrics: ${error.message}`);
    });
  }

  private async initViewAsync(context: Context, viewBean: ViewBean): Promise<void> {
    try {
      const result = await FTDBTaskPoolExecutor.upsertRumView(context, viewBean);
      if (!result) {
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
      // Capture the final View-scoped sample before stopping its monitor.
      await FTMonitorManager.getInstance().attachMonitorData(activeViewBean);
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
      // startAction atomically stores the Action and increments the persisted
      // View aggregate.  Do not enqueue the old independent counter update:
      // a C++ crash could otherwise persist the Action before that update.
      if (this.context) {
        this.insertRumActionAsync(this.context, actionBean, actionName);
      } else {
        FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-4] Context not available for startAction: ${actionName}`);
      }
    }
  }

  private async insertRumActionAsync(context: Context, actionBean: ActionBean, actionName: string): Promise<void> {
    const actionId = actionBean.getId();
    const insertion = FTDBTaskPoolExecutor.insertRumAction(context, actionBean).catch((error: Error): boolean => {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-ERROR] Error in RUM DB taskpool: ${errorMessage}`);
      return false;
    });
    this.pendingActionInsertions.set(actionId, insertion);
    try {
      const result = await insertion;
      if (!result) {
        FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-INIT-5] startAction insertion failed: ${actionName}`);
      } else {
        // The RDB transaction is authoritative. Mirror its committed count
        // in the active View only after both Action and aggregate succeeded.
        this.increaseActionCountInMemory(actionBean.getViewId());
      }
    } finally {
      if (this.pendingActionInsertions.get(actionId) === insertion) {
        this.pendingActionInsertions.delete(actionId);
      }
    }
  }
  
  
  /**
   * Close action
   */
  private closeAction(activeActionBean: ActiveActionBean): void {
    try {
      const actionBean = activeActionBean.convertToActionBean();
      this.requestActionClose(actionBean);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-CLOSE-ERROR] Error closing action: ${error}`);
    }
  }

  /** Registers an Action close intent without discarding its persisted Resource references. */
  private requestActionClose(actionBean: ActionBean): void {
    const actionId = actionBean.getId();
    if (!actionId || actionId.length === 0) {
      return;
    }
    const pending = this.pendingActionCloseStates.get(actionId);
    if (!pending) {
      this.pendingActionCloseStates.set(actionId, {
        actionBean,
        closeInFlight: false,
        waitingForResource: false
      });
    }
    if (this.context && isFTCacheSqlitePrimary(FTCacheContext.settings.mode)) {
      // Persist the close duration before waiting. Recovery can then generate
      // the original Action with the correct duration after a process restart.
      void FTDBTaskPoolExecutor.markRumActionCloseRequested(
        this.context,
        actionId,
        actionBean.getActionDuration()
      ).catch((error: Error): void => {
        FTInnerLogger.w(TAG, `Failed to persist Action close request ${actionId}: ${error.message}`);
      });
    }
    this.tryClosePendingAction(actionId);
  }

  /** Rebuilds close state for Actions left behind by a process restart. */
  private recoverPendingActionClosures(): void {
    if (!isFTCacheSqlitePrimary(FTCacheContext.settings.mode) || this.pendingActionRecoveryStarted || !this.context) {
      return;
    }
    this.pendingActionRecoveryStarted = true;
    const context = this.context;
    void FTDBTaskPoolExecutor.queryPendingRumActions(context, 100).then((actions: ActionBean[]): void => {
      const now = Utils.getCurrentNanoTime();
      for (let i = 0; i < actions.length; i++) {
        const action = actions[i];
        if (this.pendingActionCloseStates.has(action.getId())) {
          continue;
        }
        if (action.getActionDuration() <= 0) {
          action.setActionDuration(Math.max(0, now - action.getStartTime()));
        }
        this.requestActionClose(action);
      }
    }).catch((error: Error): void => {
      this.pendingActionRecoveryStarted = false;
      FTInnerLogger.e(TAG, `Failed to recover pending Action closures: ${error.message}`);
    });
  }

  private async tryClosePendingAction(actionId: string): Promise<void> {
    const pending = this.pendingActionCloseStates.get(actionId);
    if (!pending || pending.closeInFlight) {
      return;
    }
    if (!this.context) {
      this.pendingActionCloseStates.delete(actionId);
      this.generateRumData();
      return;
    }

    // A resource is registered synchronously on the Host, before its worker
    // counter delta reaches RDB. Do not close the Action in that gap.
    if (this.hasStartedResourceForAction(actionId)) {
      pending.waitingForResource = true;
      return;
    }

    pending.closeInFlight = true;
    try {
      const insertion = this.pendingActionInsertions.get(actionId);
      if (insertion) {
        const inserted = await insertion;
        if (!inserted) {
          FTInnerLogger.e(TAG, `Action insert failed before close: ${actionId}`);
          this.pendingActionCloseStates.delete(actionId);
          return;
        }
      }

      const closeResult = await FTDBTaskPoolExecutor.closeRumAction(
        this.context,
        actionId,
        pending.actionBean.getDuration()
      );
      if (closeResult.wasClosed) {
        this.pendingActionCloseStates.delete(actionId);
        // Generate the Action only after its close transition is durable.
        this.generateRumData();
        return;
      }

      pending.waitingForResource = closeResult.hadPendingResource;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      FTInnerLogger.e(TAG, `<FT-ACTION-TEST> [STEP-CLOSE-ERROR] Error closing action in database: ${errorMessage}`);
      this.schedulePendingActionCloseRetry();
    } finally {
      const current = this.pendingActionCloseStates.get(actionId);
      if (current) {
        current.closeInFlight = false;
      }
    }
  }

  private retryPendingActionClosures(): void {
    const pendingStates = Array.from(this.pendingActionCloseStates.entries());
    for (let i = 0; i < pendingStates.length; i++) {
      const actionId = pendingStates[i][0];
      const pending = pendingStates[i][1];
      if (pending.waitingForResource && this.hasStartedResourceForAction(actionId)) {
        continue;
      }
      pending.waitingForResource = false;
      this.tryClosePendingAction(actionId);
    }
  }

  private schedulePendingActionCloseRetry(): void {
    if (this.pendingActionCloseStates.size === 0 || this.pendingActionCloseRetryTimer !== null) {
      return;
    }
    // Resource completion explicitly re-enters the state machine. This timer
    // is reserved for an RDB close failure, not for timing out Resources.
    this.pendingActionCloseRetryTimer = setTimeout(() => {
      this.pendingActionCloseRetryTimer = null;
      this.retryPendingActionClosures();
    }, FTRUMInnerManager.PENDING_ACTION_CLOSE_RETRY_MS) as number;
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
      errorTags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = resourceBean.getResourceStatusGroup();
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
      allTags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = resourceTags.resource_status_group || '';
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
        this.closeAction(this.activeAction);
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
      
      this.clearActionIdLedgers();

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
      if (this.rumSemanticReplayTimer !== null) {
        clearTimeout(this.rumSemanticReplayTimer);
        this.rumSemanticReplayTimer = null;
      }
      if (this.pendingActionCloseRetryTimer !== null) {
        clearTimeout(this.pendingActionCloseRetryTimer);
        this.pendingActionCloseRetryTimer = null;
      }
      this.flushErrorWorkerCommandBatch('rum.shutdown');
      this.flushResourceWorkerCommandBatch('rum.shutdown');
      this.flushCompletedActionWorkerBatch('rum.shutdown');
      this.submitRumCounterFlushTask();
      this.pendingResourceCommands = [];
      this.pendingErrorCommands = [];
      this.pendingResourceRegistrations.clear();
      this.pendingResourceContextRestores.clear();
      this.resourceContextById.clear();
      this.startedResourceIds.clear();
      this.startedResourceActionIds.clear();
      this.resourceContentSubmittedIds.clear();
      this.resourceNetStateSubmittedIds.clear();
      this.resourceStoppedIds.clear();
      this.pendingActionCloseStates.clear();
      this.pendingActionRecoveryStarted = false;
      this.pendingActionInsertions.clear();
      this.rumSemanticJournal = [];
      this.rumSemanticJournalHead = 0;
      this.rumSemanticJournalByRequestId.clear();
      this.committedRumSemanticResponseIds.clear();
      this.committedRumSemanticResponseOrder = [];
      this.committedRumSemanticResponseOrderHead = 0;
      this.resourceDraftIdsById.clear();
      this.resourceDraftIdOrder = [];
      this.resourceDraftIdOrderHead = 0;
      this.completedRumResourceIds.clear();
      this.resourcePendingOrJournalRefCounts.clear();

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
    // Preserve the no-response sentinel in final line protocol, just like Network Errors.
    tags.resource_status = String(resourceBean.resourceStatus);
    tags.resource_status_group = resourceBean.getResourceStatusGroup();
    
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

    // `addLongTask` runs on the caller thread. Capturing Error.stack here is both
    // expensive under high-rate manual reporting and only describes this SDK call
    // path, not the work that caused the long task. Keep the caller-provided
    // description or stack unchanged; collectors that can obtain a useful stack
    // should supply it explicitly.
    fields.long_task_stack = log && log.trim().length > 0
      ? log
      : "Stack trace not provided";
    
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
   * Build Error-specific fields.
   * @param message Error message
   * @param log Error stack trace
   * @returns Error fields object
   */
  private buildErrorFields(message: string, log: string): ErrorFields {
    const fields: ErrorFields = {};
    fields.error_message = message;
    fields.error_stack = log;
    return fields;
  }

  /** Capture Error-only device tags and monitor fields on the host thread. */
  private getErrorDeviceData(): ErrorDeviceData {
    const tags: SDKStringRecord = {};
    const locale = DeviceUtils.getSystemLocale();
    if (locale.length > 0) {
      tags[Constants.KEY_DEVICE_LOCALE] = locale;
    }

    if (FTMonitorManager.getInstance().isErrorMonitorType(ErrorMonitorType.MEMORY)) {
      const memoryTotalGB = DeviceUtils.getMemoryTotalGB();
      if (memoryTotalGB > 0) {
        tags[Constants.KEY_MEMORY_TOTAL] = `${memoryTotalGB}GB`;
      }
    }

    return {
      tags,
      fields: FTMonitorManager.getInstance().getErrorMonitorData()
    };
  }

}
