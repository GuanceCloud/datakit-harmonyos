import {
  SDKCrashFileDTO,
  SDKDedicatedPoolType,
  SDKLineProtocolContextDTO,
  SDKLineProtocolInputDTO,
  SDKLogDTO,
  SDKPropertyRecord,
  SDKRumCompletedActionBatchDTO,
  SDKRumCompletedActionDTO,
  SDKRumCounterDeltaDTO,
  SDKRumCounterUpdateBatchDTO,
  SDKRumCounterFlushResultDTO,
  SDKRumCounterUpdateDTO,
  SDKRumCounterUpdateResultDTO,
  SDKRumErrorCommandBatchDTO,
  SDKRumErrorCommandDTO,
  SDKRumEventBatchDTO,
  SDKRumEventDTO,
  SDKRumResourceCommandBatchDTO,
  SDKRumResourceCommandDTO,
  SDKRumResourceContextDTO,
  SDKRumResourceNetworkSnapshotDTO,
  SDKRumResourceNetStatusDTO,
  SDKRumResourceParamsDTO,
  SDKRumResourceTransportMetricsDTO,
  SDKStringRecord,
  SDKSyncDataDraftDTO,
  SDKUploadCheckpointDTO,
  SDKUploadCommitPageDTO,
  SDKUploadCommitPageResultDTO,
  SDKUploadDbActionDTO,
  SDKUploadExecutePageDTO,
  SDKUploadExecutePageResultDTO,
  SDKUploadHttpRequestDTO,
  SDKUploadHttpResultDTO,
  SDKUploadPageDTO,
  SDKUploadPageOutcome,
  SDKUploadPreparePageDTO,
  SDKUploadPreparePageResultDTO,
  SDKUploadRoundFinishDTO,
  SDKUploadRoundResultDTO,
  SDKUploadRoundStartDTO,
  SDKUploadRoundStartResultDTO,
  SDKUploadRowDTO,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from './SDKWorkerProtocol';
import { Constants } from '../Constants';
import { NetCodeStatus } from '../http/HttpEngine';
import { ErrorType } from '../rum/enum/RUMEnums';
import {
  DATA_UPLOAD_BODY_TARGET_BYTES,
  DATA_UPLOAD_LIMIT_RETRY_DELAY_MS,
  DATA_UPLOAD_MAX_PAGE_SIZE,
  DATA_UPLOAD_MAX_RETRY_COUNT
} from './workers/DataUploadLimits';
import { prepareDataUploadPayload } from './workers/DataUploadCompression';

const DEFAULT_BATCH_SIZE = 20;
const LOG_PROCESS_COALESCE_DELAY_MS = 100;
const WEBVIEW_RESOURCE_ERROR_LINK_MAX_KEYS = 256;
const WEBVIEW_ACTION_DEDUP_MAX_IDS = 1024;
const WEBVIEW_RESOURCE_ERROR_LINK_MAX_PER_KEY = 8;
const WEBVIEW_RESOURCE_ERROR_LINK_MAX_AGE_MS = 30 * 1000;

interface SDKWebViewResourceErrorLink {
  resourceUuid: string;
  eventTime: number;
}

export interface SDKWorkerRuntimeState {
  pool: SDKDedicatedPoolType;
  workerName: string;
  backend: string;
  eventSequence: number;
  activeViewId: string;
  activeViewName: string;
  activeActionId: string;
  activeActionName: string;
  activeResources: Map<string, string>;
  rumCounterDeltas: Record<string, SDKRumCounterDeltaDTO>;
  rumCounterPendingEventCount: number;
  rumCounterNeedsActionCloseCheck: boolean;
  rumCounterNeedsRumDataGenerate: boolean;
  rumResources: Map<string, SDKRumWorkerResourceState>;
  webViewResourceErrorLinks: Map<string, SDKWebViewResourceErrorLink[]>;
  webViewActionIds: Set<string>;
  logQueue: SDKLogDTO[];
  logBatchBuffer: SDKLogDTO[];
  uploadIsScheduled: boolean;
  uploadNeedReschedule: boolean;
  uploadScheduledDelay: number;
  uploadScheduledAt: number;
  uploadRunningTaskId: string;
  uploadRoundSequence: number;
  uploadOwnerId: string;
  uploadRoundId: string;
  uploadRoundPageSize: number;
  uploadRoundMaxRetryCount: number;
  uploadRoundSyncSleepTime: number;
  uploadRoundProcessedPages: Record<string, number>;
  uploadRoundHasMoreData: boolean;
  uploadRoundConsumedRows: number;
  uploadRoundComputeMs: number;
  uploadAttemptSequence: number;
  uploadCheckpointVersion: number;
  uploadPendingPage: SDKUploadPendingPageState | null;
  uploadErrorCounts: Record<string, number>;
  uploadIgnoredClientErrorCounts: Record<string, number>;
  uploadingDataIds: SDKStringRecord;
  uploadRumSequence: number;
  uploadLogSequence: number;
  uploadProcessId: number;
  lineContext: SDKLineProtocolContextDTO | null;
}

export interface SDKWorkerMessageData {
  data?: SDKWorkerRequest;
}

interface SDKWorkerPingPayload {
  pool: string;
  workerName: string;
  command: string;
  backend: string;
  receivedAt: number;
}

interface SDKWorkerSnapshotPayload {
  pool: string;
  workerName: string;
  eventSequence: number;
  activeViewId: string;
  activeViewName: string;
  activeActionId: string;
  activeActionName: string;
  activeResourceCount: number;
  activeResourceStateKeyCount: number;
  rumResourceStateKeyCount: number;
  rumCounterStateKeyCount: number;
  logQueueSize: number;
  logBatchBufferSize: number;
  uploadIsScheduled: boolean;
  uploadNeedReschedule: boolean;
  uploadScheduledDelay: number;
  uploadRunningTaskId: string;
}

interface SDKRumCommandResultPayload {
  sequence: number;
  eventType: string;
  activeViewId: string;
  activeViewName: string;
  activeActionId: string;
  activeActionName: string;
  activeResourceCount: number;
  syncDrafts: SDKSyncDataDraftDTO[];
  /** Semantic RUM events awaiting Host context merge and modification callbacks. */
  rawEvents?: SDKRumEventDTO[];
  /** Latest error timestamp represented by this RUM draft batch. */
  errorTimeLine?: number;
  completedResourceIds?: string[];
  deltas?: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck?: boolean;
  needsRumDataGenerate?: boolean;
}

interface SDKLogEnqueuePayload {
  logs: SDKLogDTO[];
  forceFlush?: boolean;
  lineContext?: SDKLineProtocolContextDTO;
}

interface SDKLogFlushPayload {
  lineContext?: SDKLineProtocolContextDTO;
}

interface SDKLogDrainResultPayload {
  batches: SDKLogDTO[][];
  draftBatches?: SDKSyncDataDraftDTO[][];
  batchSilences: boolean[];
  queueSize: number;
  bufferSize: number;
  coalesceDelayMs: number;
  batchSize: number;
}

interface SDKLineProtocolRecordsPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SDKLineProtocolRecordsWithDraftsPayload extends SDKLineProtocolRecordsPayload {
  syncDrafts: SDKSyncDataDraftDTO[];
  rawEvents?: SDKRumEventDTO[];
  deltas?: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck?: boolean;
  needsRumDataGenerate?: boolean;
}

interface SDKLineProtocolDraftsPayload {
  drafts: SDKSyncDataDraftDTO[];
}

interface SDKCrashParsePayload extends SDKLineProtocolDraftsPayload {
  originalLength: number;
  trimmedLength: number;
}

interface SDKUploadSchedulePayload {
  delay?: number;
}

interface SDKUploadScheduleResultPayload {
  accepted: boolean;
  needReschedule: boolean;
  delay: number;
  shouldRun: boolean;
  runningTaskId?: string;
}

interface SDKUploadRoundFinishPayload {
  shouldRunAgain: boolean;
  nextDelay: number;
  runningTaskId: string;
}

interface SDKUploadFormatBodyPayload {
  body: string;
  rowIds: number[];
  acceptedRows: number;
  dataType: string;
}

export interface SDKUploadWorkerHttpExecutor {
  execute(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO>;
}

interface SDKUploadPendingPageState {
  attemptId: string;
  dataType: string;
  rows: SDKUploadRowDTO[];
  checkpointAfterCommit: SDKUploadCheckpointDTO;
  processedPagesAfterCommit: number;
  roundHasMoreDataAfterCommit: boolean;
  consumedRowsDelta: number;
  delayMs: number;
  shouldContinueDataType: boolean;
}

interface SDKRumWorkerResourceState {
  resourceId: string;
  draftUuid: string;
  errorDraftUuid: string;
  startTime: number;
  endTime: number;
  eventTime: number;
  context: SDKRumResourceContextDTO;
  url: string;
  urlHost: string;
  urlPath: string;
  resourceUrlQuery: string;
  requestHeader: string;
  responseHeader: string;
  responseConnection: string;
  responseContentType: string;
  responseContentEncoding: string;
  resourceMethod: string;
  resourceStatus: number;
  resourceStatusGroup: string;
  resourceSize: number;
  requestBodySize: number;
  requestBodySizeSource?: string;
  requestHeaderSize: number;
  requestHeaderSizeSource?: string;
  requestSize: number;
  requestSizeSource?: string;
  requestSizeIsDerived: boolean;
  httpProtocol: string;
  httpProtocolSource?: string;
  connectionReuse?: boolean;
  connectionReuseSource?: string;
  resourceType: string;
  responseBody: string;
  requestErrorStack: string;
  requestErrorMsg: string;
  suppressNetworkError: boolean;
  traceId: string;
  spanId: string;
  resourceHostIP: string;
  resourceDNS: number;
  resourceDNSStart: number;
  resourceTCP: number;
  resourceTCPStart: number;
  resourceSSL: number;
  resourceSSLStart: number;
  resourceTTFB: number;
  resourceTrans: number;
  resourceFirstByte: number;
  resourceFirstByteStart: number;
  resourceDownloadTime: number;
  resourceDownloadTimeStart: number;
  resourceLoad: number;
  properties: SDKStringRecord;
  /** Keep public Resource properties in lifecycle order, independent of mailbox delivery order. */
  startProperties: SDKStringRecord;
  stopProperties: SDKStringRecord;
  contentProperties: SDKStringRecord;
  additionalProperties: SDKStringRecord;
  startRegistered: boolean;
  contentSet: boolean;
  netStateSet: boolean;
  isProcessing: boolean;
  shouldCollect: boolean;
  customDataType?: string;
}

interface SDKParsedUrl {
  host: string;
  path: string;
  query: string;
}

export function createSDKWorkerRuntimeStateWithBackend(
  pool: SDKDedicatedPoolType,
  workerName: string,
  backend: string
): SDKWorkerRuntimeState {
  return {
    pool,
    workerName,
    backend,
    eventSequence: 0,
    activeViewId: '',
    activeViewName: '',
    activeActionId: '',
    activeActionName: '',
    activeResources: new Map<string, string>(),
    rumCounterDeltas: {},
    rumCounterPendingEventCount: 0,
    rumCounterNeedsActionCloseCheck: false,
    rumCounterNeedsRumDataGenerate: false,
    rumResources: new Map<string, SDKRumWorkerResourceState>(),
    webViewResourceErrorLinks: new Map<string, SDKWebViewResourceErrorLink[]>(),
    webViewActionIds: new Set<string>(),
    logQueue: [],
    logBatchBuffer: [],
    uploadIsScheduled: false,
    uploadNeedReschedule: false,
    uploadScheduledDelay: 0,
    uploadScheduledAt: 0,
    uploadRunningTaskId: '',
    uploadRoundSequence: 0,
    uploadOwnerId: '',
    uploadRoundId: '',
    uploadRoundPageSize: 1,
    uploadRoundMaxRetryCount: DATA_UPLOAD_MAX_RETRY_COUNT,
    uploadRoundSyncSleepTime: 0,
    uploadRoundProcessedPages: {},
    uploadRoundHasMoreData: false,
    uploadRoundConsumedRows: 0,
    uploadRoundComputeMs: 0,
    uploadAttemptSequence: 0,
    uploadCheckpointVersion: 0,
    uploadPendingPage: null,
    uploadErrorCounts: {},
    uploadIgnoredClientErrorCounts: {},
    uploadingDataIds: {},
    uploadRumSequence: 0,
    uploadLogSequence: 0,
    uploadProcessId: 0,
    lineContext: null
  };
}

export function handleSDKWorkerRequest(request: SDKWorkerRequest, state: SDKWorkerRuntimeState): SDKWorkerResponse {
  try {
    const payload = handleSDKWorkerCommand(request, state);
    return {
      id: request.id,
      ok: true,
      payload
    };
  } catch (error) {
    const errorDTO = toSDKWorkerErrorDTO(error);
    const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
    return {
      id: request.id,
      ok: false,
      errorMessage: errorDTO.message,
      payload: errorPayload
    };
  }
}

export async function handleSDKDataUploadWorkerRequest(
  request: SDKWorkerRequest,
  state: SDKWorkerRuntimeState,
  httpExecutor: SDKUploadWorkerHttpExecutor
): Promise<SDKWorkerResponse> {
  if (request.command !== SDKWorkerCommand.UPLOAD_EXECUTE_PAGE) {
    return handleSDKWorkerRequest(request, state);
  }
  try {
    const payload = await handleUploadExecutePage(
      request.payload as SDKUploadExecutePageDTO,
      state,
      httpExecutor
    );
    return {
      id: request.id,
      ok: true,
      payload
    };
  } catch (error) {
    const errorDTO = toSDKWorkerErrorDTO(error);
    const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
    return {
      id: request.id,
      ok: false,
      errorMessage: errorDTO.message,
      payload: errorPayload
    };
  }
}

function handleSDKWorkerCommand(request: SDKWorkerRequest, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  switch (request.command) {
    case SDKWorkerCommand.PING:
      const pingPayload: SDKWorkerPingPayload = {
        pool: state.pool,
        workerName: state.workerName,
        command: request.command,
        backend: state.backend,
        receivedAt: Date.now()
      };
      return pingPayload as Object as SDKWorkerPayload;
    case SDKWorkerCommand.RESET:
      resetState(state);
      return getStateSnapshot(state);
    case SDKWorkerCommand.LINE_CONTEXT_UPDATE:
      state.lineContext = request.payload ? request.payload as Object as SDKLineProtocolContextDTO : null;
      return getStateSnapshot(state);
    case SDKWorkerCommand.EVENT_RUM_COMMAND:
      return handleRumCommand(request.payload as SDKRumEventDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH:
      return handleRumCommandBatch(request.payload as SDKRumEventBatchDTO, state);
    case SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH:
      return handleRumErrorCommandBatch(request.payload as SDKRumErrorCommandBatchDTO, state);
    case SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH:
      return handleRumResourceCommandBatch(request.payload as SDKRumResourceCommandBatchDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION:
      return handleRumCompletedAction(request.payload as SDKRumCompletedActionDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH:
      return handleRumCompletedActionBatch(request.payload as SDKRumCompletedActionBatchDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE:
      return handleRumCounterUpdate(request.payload as SDKRumCounterUpdateDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH:
      return handleRumCounterUpdateBatch(request.payload as SDKRumCounterUpdateBatchDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH:
      return handleRumCounterFlush(state);
    case SDKWorkerCommand.EVENT_RUM_SNAPSHOT:
      return getStateSnapshot(state);
    case SDKWorkerCommand.LOG_ENQUEUE:
      return handleLogEnqueue(request.payload as SDKLogEnqueuePayload, state);
    case SDKWorkerCommand.LOG_FLUSH:
      return handleLogFlush(state, true, request.payload as SDKLogFlushPayload);
    case SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL:
      return handleCreateLineProtocol(request.payload as SDKLineProtocolRecordsPayload);
    case SDKWorkerCommand.DATA_PARSE_CRASH_TEXT:
      return handleParseCrashText(request.payload as SDKCrashFileDTO);
    case SDKWorkerCommand.UPLOAD_SCHEDULE:
      return handleUploadSchedule(request.payload as SDKUploadSchedulePayload, state);
    case SDKWorkerCommand.UPLOAD_CONSUME:
      return handleUploadRoundStart(request.payload as SDKUploadRoundStartDTO, state);
    case SDKWorkerCommand.UPLOAD_PREPARE_PAGE:
      return handleUploadPreparePage(request.payload as SDKUploadPreparePageDTO, state);
    case SDKWorkerCommand.UPLOAD_COMMIT_PAGE:
      return handleUploadCommitPage(request.payload as SDKUploadCommitPageDTO, state);
    case SDKWorkerCommand.UPLOAD_CONSUME_FINISH:
      return handleUploadConsumeFinish(request.payload as SDKUploadRoundFinishDTO, state);
    case SDKWorkerCommand.UPLOAD_ROUND_FINISH:
      return handleUploadScheduleRoundFinish(state);
    case SDKWorkerCommand.UPLOAD_FORMAT_BODY:
      return handleUploadFormatBody(request.payload as SDKUploadPageDTO);
    default:
      throw new Error(`Unsupported worker command: ${request.command}`);
  }
}

function resetState(state: SDKWorkerRuntimeState): void {
  state.eventSequence = 0;
  state.activeViewId = '';
  state.activeViewName = '';
  state.activeActionId = '';
  state.activeActionName = '';
  state.activeResources.clear();
  state.rumCounterDeltas = {};
  state.rumCounterPendingEventCount = 0;
  state.rumCounterNeedsActionCloseCheck = false;
  state.rumCounterNeedsRumDataGenerate = false;
  state.rumResources.clear();
  state.webViewResourceErrorLinks.clear();
  state.webViewActionIds.clear();
  state.logQueue = [];
  state.logBatchBuffer = [];
  state.uploadIsScheduled = false;
  state.uploadNeedReschedule = false;
  state.uploadScheduledDelay = 0;
  state.uploadScheduledAt = 0;
  state.uploadRunningTaskId = '';
  state.uploadRoundSequence = 0;
  state.uploadOwnerId = '';
  state.uploadRoundId = '';
  state.uploadRoundPageSize = 1;
  state.uploadRoundMaxRetryCount = DATA_UPLOAD_MAX_RETRY_COUNT;
  state.uploadRoundSyncSleepTime = 0;
  state.uploadRoundProcessedPages = {};
  state.uploadRoundHasMoreData = false;
  state.uploadRoundConsumedRows = 0;
  state.uploadRoundComputeMs = 0;
  state.uploadAttemptSequence = 0;
  state.uploadCheckpointVersion = 0;
  state.uploadPendingPage = null;
  state.uploadErrorCounts = {};
  state.uploadIgnoredClientErrorCounts = {};
  state.uploadingDataIds = {};
  state.uploadRumSequence = 0;
  state.uploadLogSequence = 0;
  state.uploadProcessId = 0;
  state.lineContext = null;
}

function getStateSnapshot(state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const payload: SDKWorkerSnapshotPayload = {
    pool: state.pool,
    workerName: state.workerName,
    eventSequence: state.eventSequence,
    activeViewId: state.activeViewId,
    activeViewName: state.activeViewName,
    activeActionId: state.activeActionId,
    activeActionName: state.activeActionName,
    activeResourceCount: getActiveResourceCount(state),
    activeResourceStateKeyCount: state.activeResources.size,
    rumResourceStateKeyCount: state.rumResources.size,
    rumCounterStateKeyCount: Object.keys(state.rumCounterDeltas).length,
    logQueueSize: state.logQueue.length,
    logBatchBufferSize: state.logBatchBuffer.length,
    uploadIsScheduled: state.uploadIsScheduled,
    uploadNeedReschedule: state.uploadNeedReschedule,
    uploadScheduledDelay: state.uploadScheduledDelay,
    uploadRunningTaskId: state.uploadRunningTaskId
  };
  return payload as Object as SDKWorkerPayload;
}

function handleRumCommand(event: SDKRumEventDTO, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const payload = processRumEvent(event, state);
  return payload as Object as SDKWorkerPayload;
}

function handleRumCommandBatch(batch: SDKRumEventBatchDTO, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const events = sortRumEventsByTime(batch && batch.events ? batch.events : []);
  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  let eventType = '';
  let lastErrorTimeLine = -1;
  for (let i = 0; i < events.length; i++) {
    const event = events[i];
    if (!event) {
      continue;
    }
    const payload = processRumEvent(event, state);
    eventType = payload.eventType;
    for (let j = 0; j < payload.syncDrafts.length; j++) {
      syncDrafts.push(payload.syncDrafts[j]);
    }
    if (payload.errorTimeLine !== undefined && payload.errorTimeLine > lastErrorTimeLine) {
      lastErrorTimeLine = payload.errorTimeLine;
    }
  }

  const payload: SDKRumCommandResultPayload = {
    sequence: state.eventSequence,
    eventType,
    activeViewId: state.activeViewId,
    activeViewName: state.activeViewName,
    activeActionId: state.activeActionId,
    activeActionName: state.activeActionName,
    activeResourceCount: getActiveResourceCount(state),
    syncDrafts
  };
  if (lastErrorTimeLine > 0) {
    payload.errorTimeLine = lastErrorTimeLine;
  }
  return payload as Object as SDKWorkerPayload;
}

function processRumEvent(event: SDKRumEventDTO, state: SDKWorkerRuntimeState): SDKRumCommandResultPayload {
  if (!event) {
    throw new Error('RUM event payload is required');
  }

  const finalizedEvent = finalizeRumEvent(event);
  correlateWebViewResourceError(finalizedEvent, state);
  const eventType = finalizedEvent.eventType || '';

  state.eventSequence++;
  if (isDuplicateWebViewAction(finalizedEvent, state)) {
    return createRumCommandResultPayload(eventType, [], state);
  }
  if (eventType === 'view.start' || eventType === 'view.init') {
    state.activeViewId = finalizedEvent.viewId || '';
    state.activeViewName = finalizedEvent.viewName || finalizedEvent.name || '';
  } else if (eventType === 'view.stop') {
    state.activeViewId = '';
    state.activeViewName = '';
  } else if (eventType === 'action.start' || eventType === 'action.add') {
    state.activeActionId = finalizedEvent.actionId || '';
    state.activeActionName = finalizedEvent.actionName || finalizedEvent.name || '';
  } else if (eventType === 'action.complete') {
    // Completed actions are one-shot RUM events and must not become the active action.
  } else if (eventType === 'action.stop' || eventType === 'action.close') {
    state.activeActionId = '';
    state.activeActionName = '';
  } else if (eventType === 'resource.start' && finalizedEvent.resourceId) {
    state.activeResources.set(finalizedEvent.resourceId, finalizedEvent.name || finalizedEvent.resourceId);
  } else if ((eventType === 'resource.stop' || eventType === 'resource.complete') && finalizedEvent.resourceId) {
    state.activeResources.delete(finalizedEvent.resourceId);
  }

  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  if (finalizedEvent.measurement && finalizedEvent.uuid) {
    syncDrafts.push(createRumDraft(finalizedEvent, state));
  }

  const payload = createRumCommandResultPayload(eventType, syncDrafts, state);
  if (finalizedEvent.measurement === Constants.FT_MEASUREMENT_RUM_ERROR && syncDrafts.length > 0) {
    payload.errorTimeLine = finalizedEvent.time;
  }
  return payload;
}

/** Suppress repeated Browser actions before they create separate database rows. */
function isDuplicateWebViewAction(event: SDKRumEventDTO, state: SDKWorkerRuntimeState): boolean {
  if (event.dataType !== 'rum_webview' || event.measurement !== Constants.FT_MEASUREMENT_RUM_ACTION ||
    !event.actionId) {
    return false;
  }
  if (state.webViewActionIds.has(event.actionId)) {
    return true;
  }
  // Bound memory for long-running WebViews; keep the most recently accepted IDs.
  if (state.webViewActionIds.size >= WEBVIEW_ACTION_DEDUP_MAX_IDS) {
    const oldest = Array.from(state.webViewActionIds)[0];
    state.webViewActionIds.delete(oldest);
  }
  state.webViewActionIds.add(event.actionId);
  return false;
}

function createRumCommandResultPayload(
  eventType: string,
  syncDrafts: SDKSyncDataDraftDTO[],
  state: SDKWorkerRuntimeState
): SDKRumCommandResultPayload {
  return {
    sequence: state.eventSequence,
    eventType,
    activeViewId: state.activeViewId,
    activeViewName: state.activeViewName,
    activeActionId: state.activeActionId,
    activeActionName: state.activeActionName,
    activeResourceCount: getActiveResourceCount(state),
    syncDrafts
  };
}

function sortRumEventsByTime(events: SDKRumEventDTO[]): SDKRumEventDTO[] {
  const sorted: SDKRumEventDTO[] = [];
  for (let i = 0; i < events.length; i++) {
    const event = events[i];
    if (!event) {
      continue;
    }
    let insertAt = sorted.length;
    while (insertAt > 0 && getRumEventTime(sorted[insertAt - 1]) > getRumEventTime(event)) {
      insertAt--;
    }
    sorted.splice(insertAt, 0, event);
  }
  return sorted;
}

function getRumEventTime(event: SDKRumEventDTO): number {
  return event && event.time > 0 ? event.time : 0;
}

function finalizeRumEvent(event: SDKRumEventDTO): SDKRumEventDTO {
  const tags = copyStringRecord(event.tags || {});
  const fields = copyStringRecord(event.fields || {});
  const measurement = event.measurement || '';
  const viewId = readWorkerEventValue(tags, fields, Constants.KEY_RUM_VIEW_ID) || event.viewId || '';
  const viewName = readWorkerEventValue(tags, fields, Constants.KEY_RUM_VIEW_NAME) || event.viewName || '';
  const actionId = readWorkerEventValue(tags, fields, Constants.KEY_RUM_ACTION_ID) || event.actionId || '';
  const actionName = readWorkerEventValue(tags, fields, Constants.KEY_RUM_ACTION_NAME) || event.actionName || '';
  const sessionId = readWorkerEventValue(tags, fields, Constants.KEY_RUM_SESSION_ID) || event.sessionId || '';
  const eventType = deriveRumEventType(measurement, fields, event.eventType || '');
  const name = deriveRumEventName(measurement, tags, fields, event.name || '');
  const resourceId = deriveRumResourceId(tags, fields, event.resourceId || '');
  let uuid = event.uuid || readWorkerEventValue(tags, fields, Constants.KEY_SDK_DATA_FLAG);
  if ((!uuid || uuid.length === 0) && measurement.length > 0) {
    uuid = measurement === Constants.FT_MEASUREMENT_RUM_VIEW && viewId.length > 0 ?
      viewId.substring(0, Math.min(16, viewId.length)) : generateWorkerUuid();
  }

  return {
    eventType,
    name,
    time: event.time,
    dataType: event.dataType,
    customDataType: event.customDataType,
    measurement,
    uuid,
    integerCompatible: event.integerCompatible,
    lineContext: event.lineContext,
    lineProtocolPrepared: event.lineProtocolPrepared,
    viewId,
    viewName,
    actionId,
    actionName,
    resourceId,
    sessionId,
    tags,
    fields
  };
}

/**
 * Browser RUM sends a failed Resource and the generated network Error as two
 * independent WebView events.  Once the Resource has its final draft UUID,
 * retain that UUID briefly so the following Error can point to the Resource
 * record rather than receiving an unrelated `resource_id`.
 */
function correlateWebViewResourceError(event: SDKRumEventDTO, state: SDKWorkerRuntimeState): void {
  if (event.dataType !== 'rum_webview') {
    return;
  }

  const tags = event.tags || {};
  const fields = event.fields || {};
  event.tags = tags;
  const correlationKey = getWebViewResourceCorrelationKey(event);
  if (event.measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
    // A Resource's resource_id is its local persisted UUID. During upload the
    // sdk_data_id tag receives a package prefix, while resource_id stays the
    // stable UUID used to link its generated Error.
    tags[Constants.KEY_RUM_RESOURCE_ID] = event.uuid || '';
    if (correlationKey.length > 0 && event.uuid && event.uuid.length > 0) {
      rememberWebViewResourceErrorLink(correlationKey, event.uuid, event.time, state);
    }
    return;
  }

  if (event.measurement !== Constants.FT_MEASUREMENT_RUM_ERROR ||
    readWorkerEventValue(tags, fields, Constants.KEY_RUM_ERROR_SOURCE) !== 'network' ||
    correlationKey.length === 0) {
    return;
  }

  const resourceUuid = consumeWebViewResourceErrorLink(correlationKey, event.time, state);
  if (resourceUuid.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_ID] = resourceUuid;
  }
}

function getWebViewResourceCorrelationKey(event: SDKRumEventDTO): string {
  const tags = event.tags || {};
  const fields = event.fields || {};
  const resourceUrl = readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_URL);
  if (resourceUrl.length === 0) {
    return '';
  }
  const viewId = readWorkerEventValue(tags, fields, Constants.KEY_RUM_VIEW_ID) || event.viewId || '';
  const method = readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_METHOD);
  return `${viewId}\u0001${method}\u0001${resourceUrl}`;
}

function rememberWebViewResourceErrorLink(
  correlationKey: string,
  resourceUuid: string,
  eventTime: number,
  state: SDKWorkerRuntimeState
): void {
  discardExpiredWebViewResourceErrorLinksFromState(state, eventTime);
  let links = state.webViewResourceErrorLinks.get(correlationKey);
  if (!links) {
    if (state.webViewResourceErrorLinks.size >= WEBVIEW_RESOURCE_ERROR_LINK_MAX_KEYS) {
      const keys = Array.from(state.webViewResourceErrorLinks.keys());
      if (keys.length > 0) {
        state.webViewResourceErrorLinks.delete(keys[0]);
      }
    }
    links = [];
    state.webViewResourceErrorLinks.set(correlationKey, links);
  }
  links.push({ resourceUuid, eventTime });
  if (links.length > WEBVIEW_RESOURCE_ERROR_LINK_MAX_PER_KEY) {
    links.splice(0, links.length - WEBVIEW_RESOURCE_ERROR_LINK_MAX_PER_KEY);
  }
}

function consumeWebViewResourceErrorLink(
  correlationKey: string,
  errorTime: number,
  state: SDKWorkerRuntimeState
): string {
  discardExpiredWebViewResourceErrorLinksFromState(state, errorTime);
  const links = state.webViewResourceErrorLinks.get(correlationKey);
  if (!links || links.length === 0) {
    return '';
  }

  let matchedIndex = 0;
  let smallestTimeDistance = Math.abs(links[0].eventTime - errorTime);
  for (let i = 1; i < links.length; i++) {
    const timeDistance = Math.abs(links[i].eventTime - errorTime);
    if (timeDistance < smallestTimeDistance) {
      matchedIndex = i;
      smallestTimeDistance = timeDistance;
    }
  }
  const resourceUuid = links[matchedIndex].resourceUuid;
  links.splice(matchedIndex, 1);
  if (links.length === 0) {
    state.webViewResourceErrorLinks.delete(correlationKey);
  }
  return resourceUuid;
}

function discardExpiredWebViewResourceErrorLinksFromState(
  state: SDKWorkerRuntimeState,
  referenceTime: number
): void {
  const correlationKeys = Array.from(state.webViewResourceErrorLinks.keys());
  for (let i = 0; i < correlationKeys.length; i++) {
    const correlationKey = correlationKeys[i];
    const links = state.webViewResourceErrorLinks.get(correlationKey);
    if (!links) {
      continue;
    }
    discardExpiredWebViewResourceErrorLinks(links, referenceTime);
    if (links.length === 0) {
      state.webViewResourceErrorLinks.delete(correlationKey);
    }
  }
}

function discardExpiredWebViewResourceErrorLinks(
  links: SDKWebViewResourceErrorLink[],
  referenceTime: number
): void {
  for (let i = links.length - 1; i >= 0; i--) {
    if (Math.abs(links[i].eventTime - referenceTime) > WEBVIEW_RESOURCE_ERROR_LINK_MAX_AGE_MS) {
      links.splice(i, 1);
    }
  }
}

function deriveRumEventType(measurement: string, fields: SDKStringRecord, fallback: string): string {
  if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
    return readWorkerRecordValue(fields, Constants.KEY_RUM_VIEW_IS_ACTIVE) === 'false' ? 'view.stop' : 'view.start';
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
    return 'action.add';
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
    return 'resource.complete';
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
    return 'rum.error';
  }
  return fallback || measurement;
}

function deriveRumEventName(
  measurement: string,
  tags: SDKStringRecord,
  fields: SDKStringRecord,
  fallback: string
): string {
  if (measurement === Constants.FT_MEASUREMENT_RUM_VIEW) {
    return readWorkerEventValue(tags, fields, Constants.KEY_RUM_VIEW_NAME) || fallback || measurement;
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_ACTION) {
    return readWorkerEventValue(tags, fields, Constants.KEY_RUM_ACTION_NAME) || fallback || measurement;
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
    return readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_URL) || fallback || measurement;
  }
  if (measurement === Constants.FT_MEASUREMENT_RUM_ERROR) {
    return readWorkerEventValue(tags, fields, Constants.KEY_RUM_ERROR_TYPE) ||
      readWorkerEventValue(tags, fields, Constants.KEY_RUM_ERROR_MESSAGE) || fallback || measurement;
  }
  return fallback || measurement;
}

function deriveRumResourceId(tags: SDKStringRecord, fields: SDKStringRecord, fallback: string): string {
  const method = readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_METHOD);
  const url = readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_URL);
  if (method.length > 0 && url.length > 0) {
    return `${method}:${url}`;
  }
  return fallback || url ||
    readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_TRACE_ID) ||
    readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_SPAN_ID) ||
    readWorkerEventValue(tags, fields, Constants.KEY_RUM_RESOURCE_URL_PATH);
}

function readWorkerEventValue(tags: SDKStringRecord, fields: SDKStringRecord, key: string): string {
  return normalizeWorkerScalar(readWorkerRecordValue(tags, key) || readWorkerRecordValue(fields, key));
}

function readWorkerRecordValue(record: SDKStringRecord, key: string): string {
  if (!record) {
    return '';
  }
  const value = record[key];
  return value !== undefined && value !== null ? String(value) : '';
}

function normalizeWorkerScalar(value: string): string {
  if (!value || value.length < 2) {
    return value || '';
  }
  const first = value.charAt(0);
  const last = value.charAt(value.length - 1);
  if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

function createRumDraft(event: SDKRumEventDTO, state: SDKWorkerRuntimeState): SDKSyncDataDraftDTO {
  const lineContext = event.lineContext || state.lineContext;
  const shouldPrepareInWorker: boolean =
    event.lineProtocolPrepared !== true && lineContext !== null && lineContext !== undefined &&
      (event.dataType === 'rum_app' || event.dataType === 'rum_webview');
  let prepared = createPassthroughLineRecords(event);
  if (shouldPrepareInWorker && event.dataType === 'rum_webview') {
    prepared = prepareRumWebViewLineRecords(event, lineContext as SDKLineProtocolContextDTO);
  } else if (shouldPrepareInWorker) {
    prepared = prepareRumAppLineRecords(event, lineContext as SDKLineProtocolContextDTO);
  }
  return {
    dataType: event.dataType || '',
    customDataType: event.customDataType,
    dataString: buildLineProtocol(
      event.measurement || '',
      prepared.tags,
      prepared.fields,
      event.time,
      prepared.integerCompatible === true
    ),
    uuid: event.uuid || '',
    time: event.time
  };
}

interface PreparedWorkerLineRecords {
  tags: SDKStringRecord;
  fields: SDKStringRecord;
  integerCompatible: boolean;
}

function createPassthroughLineRecords(event: SDKRumEventDTO): PreparedWorkerLineRecords {
  return {
    tags: event.tags || {},
    fields: event.fields || {},
    integerCompatible: event.integerCompatible === true
  };
}

function prepareRumAppLineRecords(
  event: SDKRumEventDTO,
  lineContext: SDKLineProtocolContextDTO
): PreparedWorkerLineRecords {
  const tags: SDKStringRecord = {};
  const fields = copyStringRecord(event.fields || {});
  tags[Constants.KEY_SDK_DATA_FLAG] = event.uuid || '';
  mergeStringRecords(tags, lineContext.dynamicBaseTags);
  mergeStringRecords(tags, lineContext.rumTags);
  mergeStringRecords(tags, lineContext.dynamicRumTags);
  mergeStringRecords(tags, event.tags || {});
  tags[Constants.KEY_SDK_DATA_FLAG] = event.uuid || '';
  mergeStringRecords(fields, lineContext.rumStaticFields);
  return {
    tags,
    fields,
    integerCompatible: lineContext.integerCompatible === true
  };
}

function prepareRumWebViewLineRecords(
  event: SDKRumEventDTO,
  lineContext: SDKLineProtocolContextDTO
): PreparedWorkerLineRecords {
  const inputTags = event.tags || {};
  const tags: SDKStringRecord = {};
  const fields = copyStringRecord(event.fields || {});

  tags[Constants.KEY_SDK_DATA_FLAG] = event.uuid || '';
  // Mirror Android's SyncDataHelper ordering: Browser tags are received first,
  // then dynamic tags are overlaid, followed by static native RUM tags.
  mergeStringRecords(tags, inputTags);
  mergeStringRecords(tags, lineContext.dynamicBaseTags);
  mergeStringRecords(tags, lineContext.dynamicRumTags);
  const webviewSdkVersion = tags[Constants.KEY_SDK_VERSION] || '';

  const rumTagKeys = Object.keys(lineContext.rumTags);
  for (let i = 0; i < rumTagKeys.length; i++) {
    const key = rumTagKeys[i];
    if (key === Constants.KEY_SERVICE) {
      continue;
    }
    const value = lineContext.rumTags[key];
    tags[key] = key === Constants.KEY_SDK_PACKAGE_INFO ?
      appendWebSdkVersion(value, webviewSdkVersion) : value;
  }

  if (tags[Constants.KEY_SDK_PACKAGE_INFO]) {
    tags[Constants.KEY_SDK_PACKAGE_INFO] = appendWebSdkVersion(
      tags[Constants.KEY_SDK_PACKAGE_INFO],
      webviewSdkVersion
    );
  }
  tags[Constants.KEY_SDK_DATA_FLAG] = event.uuid || '';
  return {
    tags,
    fields,
    integerCompatible: lineContext.integerCompatible === true
  };
}

function appendWebSdkVersion(packageInfo: string, webSdkVersion: string): string {
  if (!packageInfo || packageInfo.length === 0) {
    return packageInfo || '';
  }
  let normalized = packageInfo.trim();
  if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
    (normalized.startsWith("'") && normalized.endsWith("'"))) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (normalized.includes(`"${Constants.KEY_RUM_SDK_PACKAGE_WEB}"`)) {
    return normalized;
  }
  try {
    const parsed = JSON.parse(normalized) as SDKStringRecord;
    parsed[Constants.KEY_RUM_SDK_PACKAGE_WEB] = webSdkVersion || '';
    return JSON.stringify(parsed);
  } catch (_) {
    if (normalized.startsWith('{') && normalized.endsWith('}')) {
      return normalized.substring(0, 1) +
        `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}":"${webSdkVersion || ''}",` +
        normalized.substring(1);
    }
  }
  return normalized;
}

function handleRumErrorCommandBatch(
  batch: SDKRumErrorCommandBatchDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const commands = sortRumErrorCommands(batch && batch.commands ? batch.commands : []);
  const lineContext = batch && batch.lineContext ? batch.lineContext : state.lineContext;
  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  const rawEvents: SDKRumEventDTO[] = [];
  let flushMaxEvents = 256;
  let lastErrorTimeLine = -1;
  for (let i = 0; i < commands.length; i++) {
    const command = commands[i];
    if (!command) {
      continue;
    }
    if (command.counterFlushMaxEvents && command.counterFlushMaxEvents > 0) {
      flushMaxEvents = command.counterFlushMaxEvents;
    }
    const eventCountBefore = syncDrafts.length + rawEvents.length;
    processRumErrorCommand(command, state, syncDrafts, rawEvents, lineContext);
    if (syncDrafts.length + rawEvents.length > eventCountBefore) {
      lastErrorTimeLine = Math.max(lastErrorTimeLine, command.time || Date.now());
    }
  }

  const payload: SDKRumCommandResultPayload = {
    sequence: state.eventSequence,
    eventType: 'error.batch',
    activeViewId: state.activeViewId,
    activeViewName: state.activeViewName,
    activeActionId: state.activeActionId,
    activeActionName: state.activeActionName,
    activeResourceCount: getActiveResourceCount(state),
    syncDrafts
  };
  if (rawEvents.length > 0) {
    payload.rawEvents = rawEvents;
  }
  if (lastErrorTimeLine > 0) {
    payload.errorTimeLine = lastErrorTimeLine;
  }
  if (state.rumCounterPendingEventCount >= flushMaxEvents) {
    const flushPayload = createRumCounterFlushPayload(state);
    payload.deltas = flushPayload.deltas;
    payload.needsActionCloseCheck = flushPayload.needsActionCloseCheck;
    payload.needsRumDataGenerate = flushPayload.needsRumDataGenerate;
  }
  return payload as Object as SDKWorkerPayload;
}

function processRumErrorCommand(
  command: SDKRumErrorCommandDTO,
  state: SDKWorkerRuntimeState,
  syncDrafts: SDKSyncDataDraftDTO[],
  rawEvents: SDKRumEventDTO[],
  lineContext: SDKLineProtocolContextDTO | null
): void {
  if (!command || !command.context) {
    return;
  }
  state.eventSequence++;
  const tags: SDKStringRecord = {};
  const context = command.context;
  mergeStringRecords(tags, context.dynamicTags || {});
  // DataKit runs source-map processing for RUM errors and requires sdk_name on
  // every error point, including points assembled without a line context.
  tags[Constants.KEY_SDK_NAME] = Constants.SDK_NAME.toString();
  tags[Constants.KEY_RUM_ERROR_SOURCE] = command.errorSource || 'logger';
  tags[Constants.KEY_RUM_ERROR_TYPE] = command.errorType || 'unknown';
  tags[Constants.KEY_RUM_ERROR_SITUATION] = command.appState || 'unknown';
  tags[Constants.KEY_RUM_SESSION_ID] = context.sessionId || '';
  tags[Constants.KEY_RUM_VIEW_ID] = context.viewId || '';
  tags[Constants.KEY_RUM_VIEW_NAME] = context.viewName || '';
  tags[Constants.KEY_RUM_VIEW_REFERRER] = context.viewReferrer || '';
  if (context.rumAppId && context.rumAppId.length > 0) {
    tags[Constants.KEY_RUM_APP_ID] = context.rumAppId;
  }
  if (context.actionId && context.actionId.length > 0) {
    tags[Constants.KEY_RUM_ACTION_ID] = context.actionId;
  }
  if (context.actionName && context.actionName.length > 0) {
    tags[Constants.KEY_RUM_ACTION_NAME] = context.actionName;
  }
  mergeStringRecords(tags, command.deviceTags || {});

  const fields: SDKStringRecord = {};
  fields[Constants.KEY_RUM_ERROR_MESSAGE] = command.message || '';
  fields[Constants.KEY_RUM_ERROR_STACK] = command.log || '';
  mergeStringRecords(fields, normalizeRumPropertyRecord(command.property || {}));

  const event: SDKRumEventDTO = {
    eventType: 'rum.error',
    name: command.message || '',
    time: command.time || Date.now(),
    dataType: 'rum_app',
    customDataType: command.customDataType,
    measurement: Constants.FT_MEASUREMENT_RUM_ERROR,
    uuid: command.uuid || generateWorkerUuid(),
    viewId: context.viewId,
    viewName: context.viewName,
    actionId: context.actionId,
    actionName: context.actionName,
    sessionId: context.sessionId,
    tags,
    fields
  };
  if (lineContext) {
    event.lineContext = lineContext;
    syncDrafts.push(createRumDraft(event, state));
  } else {
    rawEvents.push(event);
  }
  applyRumErrorDelta(state, context.viewId, context.actionId);
}

function sortRumErrorCommands(commands: SDKRumErrorCommandDTO[]): SDKRumErrorCommandDTO[] {
  const sorted: SDKRumErrorCommandDTO[] = [];
  for (let i = 0; i < commands.length; i++) {
    const command = commands[i];
    if (!command) {
      continue;
    }
    let insertAt = sorted.length;
    while (insertAt > 0 && (sorted[insertAt - 1].time || 0) > (command.time || 0)) {
      insertAt--;
    }
    sorted.splice(insertAt, 0, command);
  }
  return sorted;
}

function handleRumResourceCommandBatch(
  batch: SDKRumResourceCommandBatchDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const commands = sortRumResourceCommands(batch && batch.commands ? batch.commands : []);
  const lineContext = batch && batch.lineContext ? batch.lineContext : state.lineContext;
  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  const rawEvents: SDKRumEventDTO[] = [];
  const completedResourceIds: string[] = [];
  const stateRecoveryOnly = batch && batch.stateRecoveryOnly === true;
  let flushMaxEvents = 256;
  for (let i = 0; i < commands.length; i++) {
    const command = commands[i];
    if (!command) {
      continue;
    }
    if (command.counterFlushMaxEvents && command.counterFlushMaxEvents > 0) {
      flushMaxEvents = command.counterFlushMaxEvents;
    }
    if (processRumResourceCommand(command, state, syncDrafts, rawEvents, stateRecoveryOnly, lineContext)) {
      completedResourceIds.push(command.resourceId);
    }
  }

  const payload: SDKRumCommandResultPayload = {
    sequence: state.eventSequence,
    eventType: 'resource.batch',
    activeViewId: state.activeViewId,
    activeViewName: state.activeViewName,
    activeActionId: state.activeActionId,
    activeActionName: state.activeActionName,
    activeResourceCount: getActiveResourceCount(state),
    syncDrafts,
    completedResourceIds
  };
  if (rawEvents.length > 0) {
    payload.rawEvents = rawEvents;
  }
  // A completed Resource owns both its final RUM draft and the matching
  // View/Action counter transition. Do not leave that transition behind a
  // timer-only counter flush: the Worker may restart after the Resource draft
  // is durable but before the next periodic flush. Returning the delta with
  // the completed lifecycle lets the Host commit the draft, counters and
  // pending-resource release in one response path.
  if (completedResourceIds.length > 0 || state.rumCounterPendingEventCount >= flushMaxEvents) {
    const flushPayload = createRumCounterFlushPayload(state);
    payload.deltas = flushPayload.deltas;
    payload.needsActionCloseCheck = flushPayload.needsActionCloseCheck;
    payload.needsRumDataGenerate = flushPayload.needsRumDataGenerate;
  }
  return payload as Object as SDKWorkerPayload;
}

function sortRumResourceCommands(commands: SDKRumResourceCommandDTO[]): SDKRumResourceCommandDTO[] {
  const sorted: SDKRumResourceCommandDTO[] = [];
  for (let i = 0; i < commands.length; i++) {
    const command = commands[i];
    if (!command) {
      continue;
    }
    let insertAt = sorted.length;
    while (insertAt > 0 && getRumResourceCommandTime(sorted[insertAt - 1]) > getRumResourceCommandTime(command)) {
      insertAt--;
    }
    sorted.splice(insertAt, 0, command);
  }
  return sorted;
}

function getRumResourceCommandTime(command: SDKRumResourceCommandDTO): number {
  if (command.eventTime && command.eventTime > 0) {
    return command.eventTime;
  }
  if (command.startTime && command.startTime > 0) {
    return command.startTime;
  }
  if (command.endTime && command.endTime > 0) {
    return command.endTime;
  }
  return 0;
}

function processRumResourceCommand(
  command: SDKRumResourceCommandDTO,
  state: SDKWorkerRuntimeState,
  syncDrafts: SDKSyncDataDraftDTO[],
  rawEvents: SDKRumEventDTO[],
  stateRecoveryOnly: boolean = false,
  lineContext: SDKLineProtocolContextDTO | null = null
): boolean {
  const commandType = command.commandType || '';
  const resourceId = command.resourceId || '';
  if (resourceId.length === 0) {
    return false;
  }

  const resource = getOrCreateRumResourceState(resourceId, command, state);
  if (command.draftUuid && command.draftUuid.length > 0) {
    resource.draftUuid = command.draftUuid;
  }
  if (command.errorDraftUuid && command.errorDraftUuid.length > 0) {
    resource.errorDraftUuid = command.errorDraftUuid;
  }
  if (command.context) {
    mergeResourceContext(resource, command.context);
  }
  if (command.shouldCollect !== undefined) {
    resource.shouldCollect = command.shouldCollect === true;
  }
  if (command.customDataType !== undefined) {
    resource.customDataType = command.customDataType;
  }
  if (command.eventTime && command.eventTime > 0) {
    resource.eventTime = command.eventTime;
  }
  if (command.property) {
    recordResourceLifecycleProperties(resource, commandType, command.property);
    applyResourcePropertyMetrics(resource, command.property);
  }
  if (commandType === 'start') {
    if (resource.startRegistered) {
      return false;
    }
    resource.startRegistered = true;
    resource.startTime = command.startTime && command.startTime > 0 ? command.startTime : resource.startTime;
    return false;
  }

  if (commandType === 'stop') {
    resource.endTime = command.endTime && command.endTime > 0 ? command.endTime : resource.endTime;
    if (resource.context.actionId.length === 0 && command.fallbackActionId && command.fallbackActionId.length > 0) {
      resource.context.actionId = command.fallbackActionId;
    }
    return tryCreateRumResourceDraft(resource, state, syncDrafts, rawEvents, lineContext, stateRecoveryOnly);
  }

  if (commandType === 'setContent' || commandType === 'add') {
    if (command.params) {
      applyResourceParams(resource, command.params);
    }
    if (command.netStatus) {
      applyResourceNetStatus(resource, command.netStatus);
    }
    if (commandType === 'add' && resource.endTime <= 0 && command.awaitStopCommand !== true) {
      resource.endTime = resource.eventTime > 0 ? resource.eventTime : Date.now() * 1000000;
    }
    return tryCreateRumResourceDraft(resource, state, syncDrafts, rawEvents, lineContext, stateRecoveryOnly);
  }

  if (commandType === 'setNetState') {
    if (command.netStatus) {
      applyResourceNetStatus(resource, command.netStatus);
    }
    return tryCreateRumResourceDraft(resource, state, syncDrafts, rawEvents, lineContext, stateRecoveryOnly);
  }
  return false;
}

function getOrCreateRumResourceState(
  resourceId: string,
  command: SDKRumResourceCommandDTO,
  state: SDKWorkerRuntimeState
): SDKRumWorkerResourceState {
  const existing = state.rumResources.get(resourceId);
  if (existing !== undefined) {
    return existing;
  }
  const fallbackContext: SDKRumResourceContextDTO = {
    sessionId: '',
    viewId: state.activeViewId,
    viewName: state.activeViewName,
    viewReferrer: '',
    actionId: state.activeActionId,
    actionName: state.activeActionName
  };
  const resource: SDKRumWorkerResourceState = {
    resourceId,
    draftUuid: command.draftUuid || generateWorkerUuid(),
    errorDraftUuid: command.errorDraftUuid || generateWorkerUuid(),
    startTime: command.startTime && command.startTime > 0 ? command.startTime : 0,
    endTime: command.endTime && command.endTime > 0 ? command.endTime : -1,
    eventTime: command.eventTime && command.eventTime > 0 ? command.eventTime : 0,
    context: command.context || fallbackContext,
    url: '',
    urlHost: '',
    urlPath: '',
    resourceUrlQuery: '',
    requestHeader: '',
    responseHeader: '',
    responseConnection: '',
    responseContentType: '',
    responseContentEncoding: '',
    resourceMethod: '',
    resourceStatus: 0,
    resourceStatusGroup: '',
    resourceSize: -1,
    requestBodySize: -1,
    requestHeaderSize: -1,
    requestSize: -1,
    requestSizeIsDerived: false,
    httpProtocol: '',
    resourceType: 'network',
    responseBody: '',
    requestErrorStack: '',
    requestErrorMsg: '',
    suppressNetworkError: false,
    traceId: '',
    spanId: '',
    resourceHostIP: '',
    resourceDNS: -1,
    resourceDNSStart: -1,
    resourceTCP: -1,
    resourceTCPStart: -1,
    resourceSSL: -1,
    resourceSSLStart: -1,
    resourceTTFB: -1,
    resourceTrans: -1,
    resourceFirstByte: -1,
    resourceFirstByteStart: -1,
    resourceDownloadTime: -1,
    resourceDownloadTimeStart: -1,
    resourceLoad: -1,
    properties: {},
    startProperties: {},
    stopProperties: {},
    contentProperties: {},
    additionalProperties: {},
    startRegistered: false,
    contentSet: false,
    netStateSet: false,
    isProcessing: false,
    shouldCollect: command.shouldCollect !== false,
    customDataType: command.customDataType
  };
  state.rumResources.set(resourceId, resource);
  return resource;
}

function mergeResourceContext(resource: SDKRumWorkerResourceState, context: SDKRumResourceContextDTO): void {
  if (!context) {
    return;
  }
  // The start command owns resource context. Later lifecycle commands can
  // supply a context only when the resource did not have one (for example,
  // addResource without a preceding startResource), preventing a late
  // completion from being rebound to a newer action.
  resource.context.dynamicTags = resource.context.dynamicTags || context.dynamicTags;
  resource.context.networkSnapshot = resource.context.networkSnapshot || context.networkSnapshot;
  resource.context.sessionId = resource.context.sessionId || context.sessionId;
  resource.context.viewId = resource.context.viewId || context.viewId;
  resource.context.viewName = resource.context.viewName || context.viewName;
  resource.context.viewReferrer = resource.context.viewReferrer || context.viewReferrer;
  resource.context.actionId = resource.context.actionId || context.actionId;
  resource.context.actionName = resource.context.actionName || context.actionName;
}

function applyResourceParams(resource: SDKRumWorkerResourceState, params: SDKRumResourceParamsDTO): void {
  resource.url = params.url || '';
  const parsedUrl = parseWorkerResourceUrl(resource.url);
  resource.urlHost = parsedUrl.host;
  resource.urlPath = parsedUrl.path;
  resource.resourceUrlQuery = parsedUrl.query;
  resource.requestHeader = params.requestHeader || '';
  resource.responseHeader = params.responseHeader || '';
  resource.responseConnection = params.responseConnection || '';
  resource.responseContentType = params.responseContentType || '';
  resource.responseContentEncoding = params.responseContentEncoding || '';
  resource.resourceMethod = params.resourceMethod || '';
  resource.resourceStatus = params.resourceStatus || 0;
  resource.resourceStatusGroup = getResourceStatusGroup(resource.resourceStatus);
  resource.resourceType = params.resourceType || 'network';
  resource.responseBody = params.responseBody || '';
  resource.requestErrorStack = params.requestErrorStack || '';
  resource.requestErrorMsg = params.requestErrorMsg || '';
  resource.suppressNetworkError = params.suppressNetworkError === true;
  mergeResourceTransportMetrics(resource, params.transportMetrics);
  resource.resourceSize = params.responseContentLength || 0;
  if (resource.resourceSize <= 0) {
    resource.resourceSize = (resource.responseBody ? resource.responseBody.length : 0) + resource.responseHeader.length;
  }
  if (params.traceId && params.traceId.length > 0) {
    resource.traceId = params.traceId;
  }
  if (params.spanId && params.spanId.length > 0) {
    resource.spanId = params.spanId;
  }
  if (resource.resourceStatus >= 400) {
    resource.requestErrorStack = resource.responseBody || '';
    resource.requestErrorMsg = '';
  }
  const property = params.property || {};
  mergeStringRecords(resource.contentProperties, normalizeRumPropertyRecord(property));
  applyResourcePropertyMetrics(resource, property);
  resource.contentSet = true;
}

function resourceTransportSourceRank(source?: string): number {
  if (source === 'platform') {
    return 3;
  }
  if (source === 'integration') {
    return 2;
  }
  if (source === 'header') {
    return 1;
  }
  return 0;
}

function isKnownResourceRequestSize(value: number): boolean {
  return Number.isFinite(value) && value >= 0;
}

/**
 * Every Resource command is keyed by resourceId. Merge each transport metric
 * independently so a later timing/status callback cannot overwrite a stronger
 * value collected by the request/response interceptor for another source.
 */
function mergeResourceTransportMetrics(
  resource: SDKRumWorkerResourceState,
  metrics?: SDKRumResourceTransportMetricsDTO
): void {
  if (!metrics) {
    return;
  }
  if (metrics.requestBodySizeSource && isKnownResourceRequestSize(metrics.requestBodySize) &&
    resourceTransportSourceRank(metrics.requestBodySizeSource) >= resourceTransportSourceRank(resource.requestBodySizeSource)) {
    resource.requestBodySize = metrics.requestBodySize;
    resource.requestBodySizeSource = metrics.requestBodySizeSource;
  }
  if (metrics.requestHeaderSizeSource && isKnownResourceRequestSize(metrics.requestHeaderSize) &&
    resourceTransportSourceRank(metrics.requestHeaderSizeSource) >= resourceTransportSourceRank(resource.requestHeaderSizeSource)) {
    resource.requestHeaderSize = metrics.requestHeaderSize;
    resource.requestHeaderSizeSource = metrics.requestHeaderSizeSource;
  }
  if (metrics.requestSizeSource && isKnownResourceRequestSize(metrics.requestSize) &&
    resourceTransportSourceRank(metrics.requestSizeSource) >= resourceTransportSourceRank(resource.requestSizeSource)) {
    resource.requestSize = metrics.requestSize;
    resource.requestSizeSource = metrics.requestSizeSource;
    resource.requestSizeIsDerived = false;
  }
  if (metrics.httpProtocolSource && metrics.httpProtocol && metrics.httpProtocol.trim().length > 0 &&
    resourceTransportSourceRank(metrics.httpProtocolSource) >= resourceTransportSourceRank(resource.httpProtocolSource)) {
    resource.httpProtocol = metrics.httpProtocol.trim();
    resource.httpProtocolSource = metrics.httpProtocolSource;
  }
  if (metrics.connectionReuseSource && metrics.connectionReuse !== undefined &&
    resourceTransportSourceRank(metrics.connectionReuseSource) >= resourceTransportSourceRank(resource.connectionReuseSource)) {
    resource.connectionReuse = metrics.connectionReuse;
    resource.connectionReuseSource = metrics.connectionReuseSource;
  }
  deriveResourceRequestSize(resource);
}

function deriveResourceRequestSize(resource: SDKRumWorkerResourceState): void {
  if (resource.requestSizeSource && !resource.requestSizeIsDerived) {
    return;
  }
  if (!isKnownResourceRequestSize(resource.requestBodySize) || !isKnownResourceRequestSize(resource.requestHeaderSize) ||
    !resource.requestBodySizeSource || !resource.requestHeaderSizeSource) {
    return;
  }
  resource.requestSize = resource.requestBodySize + resource.requestHeaderSize;
  resource.requestSizeSource = resourceTransportSourceRank(resource.requestBodySizeSource) <=
    resourceTransportSourceRank(resource.requestHeaderSizeSource)
    ? resource.requestBodySizeSource
    : resource.requestHeaderSizeSource;
  resource.requestSizeIsDerived = true;
}

function recordResourceLifecycleProperties(
  resource: SDKRumWorkerResourceState,
  commandType: string,
  property: SDKPropertyRecord
): void {
  const normalized = normalizeRumPropertyRecord(property || {});
  if (commandType === 'start') {
    mergeStringRecords(resource.startProperties, normalized);
    return;
  }
  if (commandType === 'stop') {
    mergeStringRecords(resource.stopProperties, normalized);
    return;
  }
  mergeStringRecords(resource.additionalProperties, normalized);
}

function rebuildResourceCustomProperties(resource: SDKRumWorkerResourceState): void {
  resource.properties = {};
  mergeStringRecords(resource.properties, resource.startProperties);
  mergeStringRecords(resource.properties, resource.stopProperties);
  mergeStringRecords(resource.properties, resource.contentProperties);
  mergeStringRecords(resource.properties, resource.additionalProperties);
}

function applyResourcePropertyMetrics(resource: SDKRumWorkerResourceState, property: SDKPropertyRecord): void {
  const normalized = normalizeRumPropertyRecord(property || {});
  const dnsTime = readPositiveNumber(normalized, 'resourceDNS');
  const tcpTime = readPositiveNumber(normalized, 'resourceTCP');
  const sslTime = readPositiveNumber(normalized, 'resourceSSL');
  const ttfbTime = readPositiveNumber(normalized, 'resourceTTFB');
  const downloadTime = readPositiveNumber(normalized, 'resourceDownloadTime');

  if (dnsTime > 0) {
    resource.resourceDNS = dnsTime;
    resource.resourceDNSStart = 0;
  }
  if (tcpTime > 0) {
    resource.resourceTCP = tcpTime;
    resource.resourceTCPStart = dnsTime;
  }
  if (sslTime > 0) {
    resource.resourceSSL = sslTime;
    resource.resourceSSLStart = dnsTime + tcpTime;
  }
  if (ttfbTime > 0) {
    resource.resourceTTFB = ttfbTime;
  }
  const transTime = readPositiveNumber(normalized, 'resourceTrans');
  if (transTime > 0) {
    resource.resourceTrans = transTime;
  }
  const firstByteTime = readPositiveNumber(normalized, 'resourceFirstByte');
  if (firstByteTime > 0) {
    resource.resourceFirstByte = firstByteTime;
    resource.resourceFirstByteStart = dnsTime + tcpTime + sslTime;
  }
  if (downloadTime > 0) {
    resource.resourceDownloadTime = downloadTime;
    resource.resourceDownloadTimeStart = dnsTime + tcpTime + sslTime + ttfbTime;
  }
  const loadTime = readPositiveNumber(normalized, 'resourceLoad');
  if (loadTime > 0) {
    resource.resourceLoad = loadTime;
  }

  const keys = Object.keys(normalized);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (isResourceMetricProperty(key)) {
      continue;
    }
    resource.properties[key] = normalized[key];
  }
}

function applyResourceNetStatus(resource: SDKRumWorkerResourceState, netStatus: SDKRumResourceNetStatusDTO): void {
  mergeResourceTransportMetrics(resource, netStatus.transportMetrics);
  if (netStatus.dnsTime > 0) {
    resource.resourceDNS = netStatus.dnsTime;
    resource.resourceDNSStart = netStatus.dnsStartTime;
  }
  if (netStatus.tcpTime > 0) {
    resource.resourceTCP = netStatus.tcpTime;
    resource.resourceTCPStart = netStatus.tcpStartTime;
  }
  if (netStatus.sslTime > 0) {
    resource.resourceSSL = netStatus.sslTime;
    resource.resourceSSLStart = netStatus.sslStartTime;
  }
  if (netStatus.ttfbTime > 0) {
    resource.resourceTTFB = netStatus.ttfbTime;
  }
  if (netStatus.responseTime > 0) {
    resource.resourceTrans = netStatus.responseTime;
  }
  if (netStatus.firstByteTime > 0) {
    resource.resourceFirstByte = netStatus.firstByteTime;
    resource.resourceFirstByteStart = netStatus.firstByteStartTime;
  }
  if (netStatus.downloadTime > 0) {
    resource.resourceDownloadTime = netStatus.downloadTime;
    resource.resourceDownloadTimeStart = netStatus.downloadStartTime;
  }
  if (netStatus.holeRequestTime > 0) {
    resource.resourceLoad = netStatus.holeRequestTime;
  } else if (resource.endTime > 0 && resource.startTime > 0) {
    resource.resourceLoad = resource.endTime - resource.startTime;
  }
  if (netStatus.resourceHostIP && netStatus.resourceHostIP.length > 0) {
    resource.resourceHostIP = netStatus.resourceHostIP;
  }
  resource.netStateSet = true;
}

function tryCreateRumResourceDraft(
  resource: SDKRumWorkerResourceState,
  state: SDKWorkerRuntimeState,
  syncDrafts: SDKSyncDataDraftDTO[],
  rawEvents: SDKRumEventDTO[],
  lineContext: SDKLineProtocolContextDTO | null,
  stateRecoveryOnly: boolean = false
): boolean {
  if (!resource.contentSet || !resource.netStateSet || resource.endTime <= 0 || resource.isProcessing) {
    return false;
  }
  resource.isProcessing = true;
  rebuildResourceCustomProperties(resource);
  state.eventSequence++;

  if (resource.shouldCollect !== false) {
    const resourceEvent = createResourceRumEvent(resource);
    if (lineContext) {
      resourceEvent.lineContext = lineContext;
      syncDrafts.push(createRumDraft(resourceEvent, state));
    } else {
      // Custom LineDataModifier callbacks live on the Host. Keep the event
      // structured until the Host has merged public tags and run callbacks.
      rawEvents.push(resourceEvent);
    }
  }
  if (isWorkerResourceError(resource) && resource.shouldCollect !== false) {
    const errorEvent = createResourceErrorRumEvent(resource);
    if (lineContext) {
      errorEvent.lineContext = lineContext;
      syncDrafts.push(createRumDraft(errorEvent, state));
    } else {
      rawEvents.push(errorEvent);
    }
    if (!stateRecoveryOnly) {
      applyRumErrorDelta(state, resource.context.viewId, resource.context.actionId);
    }
  }
  if (!stateRecoveryOnly) {
    // Resource/Error counters are emitted together only after the lifecycle
    // is complete. The Host subsequently releases the durable pending
    // Resource reference after the corresponding drafts are persisted.
    applyResourceCompleteDelta(state, resource.context.viewId, resource.context.actionId);
  }
  state.rumResources.delete(resource.resourceId);
  return true;
}

function createResourceRumEvent(resource: SDKRumWorkerResourceState): SDKRumEventDTO {
  const tags = createResourceTags(resource);
  const fields = createResourceFields(resource);
  return {
    eventType: 'resource.complete',
    name: resource.url || resource.resourceId,
    time: resource.eventTime > 0 ? resource.eventTime : resource.endTime,
    dataType: 'rum_app',
    customDataType: resource.customDataType,
    measurement: Constants.FT_MEASUREMENT_RUM_RESOURCE,
    uuid: resource.draftUuid,
    viewId: resource.context.viewId,
    viewName: resource.context.viewName,
    actionId: resource.context.actionId,
    actionName: resource.context.actionName,
    resourceId: resource.resourceId,
    sessionId: resource.context.sessionId,
    tags,
    fields
  };
}

function createResourceErrorRumEvent(resource: SDKRumWorkerResourceState): SDKRumEventDTO {
  const tags: SDKStringRecord = {};
  mergeStringRecords(tags, resource.context.dynamicTags || {});
  tags[Constants.KEY_RUM_RESOURCE_ID] = resource.draftUuid;
  tags[Constants.KEY_RUM_ERROR_TYPE] = String(ErrorType.NETWORK);
  tags[Constants.KEY_RUM_ERROR_SOURCE] = 'network';
  tags[Constants.KEY_RUM_ERROR_SITUATION] = 'run';
  tags[Constants.KEY_RUM_ACTION_ID] = resource.context.actionId;
  tags[Constants.KEY_RUM_ACTION_NAME] = resource.context.actionName;
  tags[Constants.KEY_RUM_VIEW_ID] = resource.context.viewId;
  tags[Constants.KEY_RUM_VIEW_NAME] = resource.context.viewName;
  tags[Constants.KEY_RUM_VIEW_REFERRER] = resource.context.viewReferrer;
  tags[Constants.KEY_RUM_SESSION_ID] = resource.context.sessionId;
  if (resource.context.rumAppId && resource.context.rumAppId.length > 0) {
    tags[Constants.KEY_RUM_APP_ID] = resource.context.rumAppId;
  }
  tags[Constants.KEY_RUM_RESOURCE_STATUS] = String(resource.resourceStatus);
  tags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = getResourceStatusGroup(resource.resourceStatus);
  tags[Constants.KEY_RUM_RESOURCE_URL] = resource.url;
  tags[Constants.KEY_RUM_RESOURCE_URL_HOST] = resource.urlHost;
  tags[Constants.KEY_RUM_RESOURCE_METHOD] = resource.resourceMethod;
  if (resource.urlPath.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_URL_PATH] = resource.urlPath;
    tags[Constants.KEY_RUM_RESOURCE_URL_PATH_GROUP] = normalizeResourcePathGroup(resource.urlPath);
  }
  const fields: SDKStringRecord = {};
  const localErrorMsg = resource.requestErrorMsg.length > 0 ? `:${resource.requestErrorMsg}` : '';
  fields[Constants.KEY_RUM_ERROR_MESSAGE] = `[${resource.resourceStatus}${localErrorMsg}][${resource.url}]`;
  if (resource.requestErrorStack.length > 0) {
    fields[Constants.KEY_RUM_ERROR_STACK] = resource.requestErrorStack;
  }
  return {
    eventType: 'rum.error',
    name: fields[Constants.KEY_RUM_ERROR_MESSAGE],
    time: resource.eventTime > 0 ? resource.eventTime : resource.endTime,
    dataType: 'rum_app',
    customDataType: resource.customDataType,
    measurement: Constants.FT_MEASUREMENT_RUM_ERROR,
    uuid: resource.errorDraftUuid,
    viewId: resource.context.viewId,
    viewName: resource.context.viewName,
    actionId: resource.context.actionId,
    actionName: resource.context.actionName,
    resourceId: resource.resourceId,
    sessionId: resource.context.sessionId,
    tags,
    fields
  };
}

function createResourceTags(resource: SDKRumWorkerResourceState): SDKStringRecord {
  const tags: SDKStringRecord = {};
  mergeStringRecords(tags, resource.context.dynamicTags || {});
  tags[Constants.KEY_RUM_RESOURCE_ID] = resource.draftUuid;
  tags[Constants.KEY_RUM_SESSION_ID] = resource.context.sessionId;
  tags[Constants.KEY_RUM_VIEW_ID] = resource.context.viewId;
  tags[Constants.KEY_RUM_VIEW_NAME] = resource.context.viewName;
  tags[Constants.KEY_RUM_VIEW_REFERRER] = resource.context.viewReferrer;
  if (resource.context.rumAppId && resource.context.rumAppId.length > 0) {
    tags[Constants.KEY_RUM_APP_ID] = resource.context.rumAppId;
  }
  if (resource.context.actionId.length > 0) {
    tags[Constants.KEY_RUM_ACTION_ID] = resource.context.actionId;
  }
  if (resource.context.actionName.length > 0) {
    tags[Constants.KEY_RUM_ACTION_NAME] = resource.context.actionName;
  }
  if (resource.url.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_URL] = resource.url;
  }
  if (resource.urlHost.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_URL_HOST] = resource.urlHost;
  }
  if (resource.urlPath.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_URL_PATH] = resource.urlPath;
    tags[Constants.KEY_RUM_RESOURCE_URL_PATH_GROUP] = normalizeResourcePathGroup(resource.urlPath);
  }
  if (resource.resourceMethod.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_METHOD] = resource.resourceMethod;
  }
  if (resource.resourceType.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_TYPE] = resource.resourceType;
  }
  // Zero means no HTTP response; it is still a meaningful Resource status.
  tags[Constants.KEY_RUM_RESOURCE_STATUS] = String(resource.resourceStatus);
  tags[Constants.KEY_RUM_RESOURCE_STATUS_GROUP] = resource.resourceStatusGroup;
  if (resource.resourceHostIP.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_HOST_IP] = resource.resourceHostIP;
  }
  if (resource.responseConnection.length > 0) {
    tags[Constants.KEY_RUM_RESPONSE_CONNECTION] = resource.responseConnection;
  }
  if (resource.responseContentType.length > 0) {
    tags[Constants.KEY_RUM_RESPONSE_CONTENT_TYPE] = resource.responseContentType;
  }
  if (resource.responseContentEncoding.length > 0) {
    tags[Constants.KEY_RUM_RESPONSE_CONTENT_ENCODING] = resource.responseContentEncoding;
  }
  if (resource.traceId.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_TRACE_ID] = resource.traceId;
  }
  if (resource.spanId.length > 0) {
    tags[Constants.KEY_RUM_RESOURCE_SPAN_ID] = resource.spanId;
  }
  return tags;
}

function createResourceFields(resource: SDKRumWorkerResourceState): SDKStringRecord {
  const fields: SDKStringRecord = {};
  appendResourceNetworkSnapshot(fields, resource.context.networkSnapshot);
  if (resource.resourceSize > 0) {
    fields[Constants.KEY_RUM_RESOURCE_SIZE] = String(resource.resourceSize);
  }
  if (resource.resourceLoad > 0) {
    fields[Constants.KEY_RUM_RESOURCE_DURATION] = String(resource.resourceLoad);
  }
  if (resource.resourceDNS > 0) {
    fields[Constants.KEY_RUM_RESOURCE_DNS] = String(resource.resourceDNS);
    fields[Constants.KEY_RUM_RESOURCE_DNS_TIME] = JSON.stringify({ duration: resource.resourceDNS, start: resource.resourceDNSStart });
  }
  if (resource.resourceTCP > 0) {
    fields[Constants.KEY_RUM_RESOURCE_TCP] = String(resource.resourceTCP);
    fields[Constants.KEY_RUM_RESOURCE_CONNECT_TIME] = JSON.stringify({ duration: resource.resourceTCP, start: resource.resourceTCPStart });
  }
  if (resource.resourceSSL > 0) {
    fields[Constants.KEY_RUM_RESOURCE_SSL] = String(resource.resourceSSL);
    fields[Constants.KEY_RUM_RESOURCE_SSL_TIME] = JSON.stringify({ duration: resource.resourceSSL, start: resource.resourceSSLStart });
  }
  if (resource.resourceTTFB > 0) {
    fields[Constants.KEY_RUM_RESOURCE_TTFB] = String(resource.resourceTTFB);
  }
  if (resource.resourceTrans > 0) {
    fields[Constants.KEY_RUM_RESOURCE_TRANS] = String(resource.resourceTrans);
  }
  if (resource.resourceFirstByte > 0) {
    fields[Constants.KEY_RUM_RESOURCE_FIRST_BYTE] = String(resource.resourceFirstByte);
    fields[Constants.KEY_RUM_RESOURCE_FIRST_BYTE_TIME] = JSON.stringify({
      duration: resource.resourceFirstByte,
      start: resource.resourceFirstByteStart
    });
  }
  if (resource.resourceDownloadTime > 0) {
    fields[Constants.KEY_RUM_RESOURCE_DOWNLOAD_TIME] = JSON.stringify({
      duration: resource.resourceDownloadTime,
      start: resource.resourceDownloadTimeStart
    });
  }
  if (resource.requestHeader.length > 0) {
    fields[Constants.KEY_RUM_RESOURCE_REQUEST_HEADER] = resource.requestHeader;
  }
  if (resource.responseHeader.length > 0) {
    fields[Constants.KEY_RUM_RESOURCE_RESPONSE_HEADER] = resource.responseHeader;
  }
  mergeStringRecords(fields, resource.properties);
  // These are Resource Fields, never Tags. Add them after custom properties
  // so callers cannot weaken a platform/integration transport observation by
  // supplying a same-named generic property.
  if (resource.requestSize > 0) {
    fields[Constants.KEY_RUM_RESOURCE_REQUEST_SIZE] = String(resource.requestSize);
  }
  if (resource.httpProtocol.length > 0) {
    fields[Constants.KEY_RUM_RESOURCE_HTTP_PROTOCOL] = resource.httpProtocol;
  }
  if (resource.connectionReuse !== undefined) {
    fields[Constants.KEY_RUM_RESOURCE_CONNECTION_REUSE] = String(resource.connectionReuse);
  }
  return fields;
}

function appendResourceNetworkSnapshot(
  fields: SDKStringRecord,
  snapshot: SDKRumResourceNetworkSnapshotDTO | undefined
): void {
  if (!snapshot) {
    return;
  }
  fields[Constants.KEY_RUM_RESOURCE_NETWORK_AVAILABLE] = String(snapshot.available);
  // An unavailable network has no meaningful capability, bandwidth, or signal
  // values. Defend this invariant again in the Worker for recovered commands.
  if (!snapshot.available) {
    return;
  }
  if (snapshot.validated !== undefined) {
    fields[Constants.KEY_RUM_RESOURCE_NETWORK_VALIDATED] = String(snapshot.validated);
  }
  if (isValidResourceNetworkMetric(snapshot.downlinkKbps, false)) {
    fields[Constants.KEY_RUM_RESOURCE_NETWORK_DOWNLINK_KBPS] = String(snapshot.downlinkKbps);
  }
  if (isValidResourceNetworkMetric(snapshot.uplinkKbps, false)) {
    fields[Constants.KEY_RUM_RESOURCE_NETWORK_UPLINK_KBPS] = String(snapshot.uplinkKbps);
  }
  if (isValidResourceNetworkMetric(snapshot.signalStrength, true)) {
    fields[Constants.KEY_RUM_RESOURCE_NETWORK_SIGNAL_STRENGTH] = String(snapshot.signalStrength);
  }
}

function isValidResourceNetworkMetric(value: number | undefined, allowsZero: boolean): boolean {
  if (value === undefined || !Number.isInteger(value)) {
    return false;
  }
  return allowsZero ? value >= 0 : value > 0;
}

function applyResourceCompleteDelta(state: SDKWorkerRuntimeState, viewId: string, actionId: string): void {
  const delta = getOrCreateRumCounterDelta(state, viewId || '', actionId || '');
  if (viewId && viewId.length > 0) {
    delta.viewResourceDelta += 1;
    // The durable Resource lifecycle table owns pending_resource. Its
    // reference is released by the Host only after this Resource/Error draft
    // and these counter deltas have both committed to RDB.
    delta.viewUpdateTimeDelta += 1;
    // The initiating Action may already be closed when a slow request ends.
    // Its completion must still publish the updated View counter snapshot.
    state.rumCounterNeedsRumDataGenerate = true;
  }
  if (actionId && actionId.length > 0) {
    delta.actionResourceDelta += 1;
  }
  state.rumCounterNeedsActionCloseCheck = true;
  state.rumCounterPendingEventCount++;
}

function applyRumErrorDelta(state: SDKWorkerRuntimeState, viewId: string, actionId: string): void {
  const delta = getOrCreateRumCounterDelta(state, viewId || '', actionId || '');
  delta.viewErrorDelta += viewId && viewId.length > 0 ? 1 : 0;
  delta.actionErrorDelta += actionId && actionId.length > 0 ? 1 : 0;
  if (viewId && viewId.length > 0) {
    // A View summary is a persisted aggregate. Error-only changes must make
    // the associated View eligible for a newer snapshot as well.
    delta.viewUpdateTimeDelta += 1;
    state.rumCounterNeedsRumDataGenerate = true;
  }
  state.rumCounterNeedsActionCloseCheck = true;
  state.rumCounterPendingEventCount++;
}

function parseWorkerResourceUrl(url: string): SDKParsedUrl {
  if (!url || url.length === 0) {
    return { host: '', path: '', query: '' };
  }
  const match = url.match(/^(https?:\/\/)?([^\/\?]+)(\/[^\?]*)?(\?.*)?$/);
  if (!match) {
    return { host: '', path: '', query: '' };
  }
  return {
    host: match[2] || '',
    path: match[3] || '/',
    query: match[4] || ''
  };
}

function normalizeResourcePathGroup(path: string): string {
  if (!path || path.length === 0) {
    return '';
  }
  return path.replace(/\/([^\/]*)\d([^\/]*)/g, '/?');
}

function getResourceStatusGroup(status: number): string {
  if (status > 0) {
    return `${Math.floor(status / 100)}xx`;
  }
  return '';
}

function readPositiveNumber(record: SDKStringRecord, key: string): number {
  const value = record[key];
  if (!value || value.length === 0) {
    return -1;
  }
  const parsed = Number.parseFloat(value);
  return Number.isNaN(parsed) ? -1 : parsed;
}

function isResourceMetricProperty(key: string): boolean {
  return key === 'resourceDNS' ||
    key === 'resourceTCP' ||
    key === 'resourceSSL' ||
    key === 'resourceTTFB' ||
    key === 'resourceTrans' ||
    key === 'resourceFirstByte' ||
    key === 'resourceDownloadTime' ||
    key === 'resourceLoad';
}

function isWorkerResourceError(resource: SDKRumWorkerResourceState): boolean {
  return resource.resourceStatus >= 400 ||
    (resource.resourceStatus === 0 && resource.requestErrorStack.length > 0 && !resource.suppressNetworkError);
}

function handleRumCompletedAction(
  action: SDKRumCompletedActionDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  return createCompletedActionPayload([action], state) as Object as SDKWorkerPayload;
}

function handleRumCompletedActionBatch(
  batch: SDKRumCompletedActionBatchDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const actions = batch && batch.actions ? batch.actions : [];
  const lineContext = batch && batch.lineContext ? batch.lineContext : state.lineContext;
  return createCompletedActionPayload(actions, state, lineContext) as Object as SDKWorkerPayload;
}

function sortCompletedActionsByTime(actions: SDKRumCompletedActionDTO[]): SDKRumCompletedActionDTO[] {
  const sorted: SDKRumCompletedActionDTO[] = [];
  for (let i = 0; i < actions.length; i++) {
    const action = actions[i];
    if (!action) {
      continue;
    }
    let insertAt = sorted.length;
    while (insertAt > 0 && (sorted[insertAt - 1].time || 0) > (action.time || 0)) {
      insertAt--;
    }
    sorted.splice(insertAt, 0, action);
  }
  return sorted;
}

function createCompletedActionPayload(
  actions: SDKRumCompletedActionDTO[],
  state: SDKWorkerRuntimeState,
  batchLineContext: SDKLineProtocolContextDTO | null = null
): SDKLineProtocolRecordsWithDraftsPayload {
  const records: SDKLineProtocolInputDTO[] = [];
  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  const rawEvents: SDKRumEventDTO[] = [];
  let flushMaxEvents = 256;
  const sortedActions = sortCompletedActionsByTime(actions);
  for (let i = 0; i < sortedActions.length; i++) {
    const action = sortedActions[i];
    if (!action) {
      continue;
    }
    if (action.counterFlushMaxEvents && action.counterFlushMaxEvents > 0) {
      flushMaxEvents = action.counterFlushMaxEvents;
    }
    appendCompletedActionDraft(action, state, records, syncDrafts, rawEvents, batchLineContext);
  }

  const payload: SDKLineProtocolRecordsWithDraftsPayload = {
    records,
    syncDrafts
  };
  if (rawEvents.length > 0) {
    payload.rawEvents = rawEvents;
  }
  if (state.rumCounterPendingEventCount >= flushMaxEvents) {
    const flushPayload = createRumCounterFlushPayload(state);
    payload.deltas = flushPayload.deltas;
    payload.needsActionCloseCheck = flushPayload.needsActionCloseCheck;
    payload.needsRumDataGenerate = flushPayload.needsRumDataGenerate;
  }
  return payload;
}

function appendCompletedActionDraft(
  action: SDKRumCompletedActionDTO,
  state: SDKWorkerRuntimeState,
  records: SDKLineProtocolInputDTO[],
  syncDrafts: SDKSyncDataDraftDTO[],
  rawEvents: SDKRumEventDTO[],
  batchLineContext: SDKLineProtocolContextDTO | null
): void {
  if (!action) {
    throw new Error('RUM completed action payload is required');
  }

  state.eventSequence++;
  const uuid = action.uuid && action.uuid.length > 0 ? action.uuid : generateWorkerUuid();
  const lineContext = batchLineContext || state.lineContext;
  const tags: SDKStringRecord = {};
  if (lineContext) {
    mergeStringRecords(tags, lineContext.dynamicBaseTags);
    mergeStringRecords(tags, lineContext.rumTags);
    mergeStringRecords(tags, lineContext.dynamicRumTags);
  }
  mergeStringRecords(tags, action.dynamicTags || {});
  if (action.rumAppId && action.rumAppId.length > 0) {
    tags[Constants.KEY_RUM_APP_ID] = action.rumAppId;
  }
  tags[Constants.KEY_SDK_DATA_FLAG] = uuid;
  tags[Constants.KEY_RUM_VIEW_ID] = action.viewId || '';
  tags[Constants.KEY_RUM_VIEW_NAME] = action.viewName || '';
  tags[Constants.KEY_RUM_SESSION_ID] = action.sessionId || '';
  tags[Constants.KEY_RUM_VIEW_REFERRER] = action.viewReferrer || '';
  if (action.actionType && action.actionType.length > 0) {
    tags[Constants.KEY_RUM_ACTION_TYPE] = action.actionType;
  }
  tags[Constants.KEY_RUM_ACTION_ID] = action.actionId || '';
  tags[Constants.KEY_RUM_ACTION_NAME] = action.actionName || '';

  const fields: SDKStringRecord = {};
  // Map user/custom data first. The SDK applies reserved fields after the
  // static RUM context as well, because a global custom context must not
  // replace an Action duration or launch classification.
  copyActionPropertiesToFields(action.properties || {}, fields);
  if (lineContext) {
    mergeStringRecords(fields, lineContext.rumStaticFields);
  }
  fields[Constants.KEY_RUM_ACTION_DURATION] = String(action.duration || 0);
  fields[Constants.KEY_RUM_ACTION_ERROR_COUNT] = String(action.errorCount || 0);
  fields[Constants.KEY_RUM_ACTION_LONG_TASK_COUNT] = String(action.longTaskCount || 0);
  fields[Constants.KEY_RUM_ACTION_RESOURCE_COUNT] = String(action.resourceCount || 0);
  if (action.actionType === Constants.ACTION_TYPE_LAUNCH_COLD) {
    copyColdLaunchPropertiesToFields(action.properties || {}, fields);
  }

  const record: SDKLineProtocolInputDTO = {
    dataType: action.dataType || '',
    customDataType: action.customDataType,
    measurement: action.measurement || Constants.FT_MEASUREMENT_RUM_ACTION,
    tags,
    fields,
    time: action.time || 0,
    uuid
  };
  records.push(record);
  if (lineContext) {
    syncDrafts.push({
      dataType: record.dataType,
      customDataType: record.customDataType,
      dataString: buildLineProtocol(record.measurement, record.tags, record.fields, record.time, record.integerCompatible === true),
      uuid: record.uuid,
      time: record.time
    });
  } else {
    rawEvents.push({
      dataType: record.dataType,
      customDataType: record.customDataType,
      measurement: record.measurement,
      tags: record.tags,
      fields: record.fields,
      uuid: record.uuid,
      time: record.time
    });
  }
  if (action.countViewAction === true && action.viewId && action.viewId.length > 0) {
    appendViewActionCounterDelta(state, action.viewId);
  }
}

function appendViewActionCounterDelta(state: SDKWorkerRuntimeState, viewId: string, count: number = 1): void {
  const delta = getOrCreateRumCounterDelta(state, viewId, '');
  delta.viewActionDelta += viewId.length > 0 ? count : 0;
  state.rumCounterPendingEventCount += count;
}

function handleRumCounterUpdate(
  update: SDKRumCounterUpdateDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const flushMaxKeys = applyRumCounterUpdate(update, state);
  return createRumCounterUpdateResultPayload(state, flushMaxKeys) as Object as SDKWorkerPayload;
}

function handleRumCounterUpdateBatch(
  batch: SDKRumCounterUpdateBatchDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const updates = compactRumCounterUpdates(batch && batch.updates ? batch.updates : []);
  let flushMaxKeys = 256;
  for (let i = 0; i < updates.length; i++) {
    const update = updates[i];
    if (!update) {
      continue;
    }
    const updateFlushMaxKeys = applyRumCounterUpdate(update, state);
    if (updateFlushMaxKeys > 0 && updateFlushMaxKeys < flushMaxKeys) {
      flushMaxKeys = updateFlushMaxKeys;
    }
  }
  return createRumCounterUpdateResultPayload(state, flushMaxKeys) as Object as SDKWorkerPayload;
}

function compactRumCounterUpdates(updates: SDKRumCounterUpdateDTO[]): SDKRumCounterUpdateDTO[] {
  const aggregates: Record<string, SDKRumCounterUpdateDTO> = {};
  for (let i = 0; i < updates.length; i++) {
    const update = updates[i];
    if (!update || !update.updateType) {
      continue;
    }
    const key = `${update.updateType}|${update.viewId || ''}|${update.actionId || ''}|${
      update.updateView === false ? '0' : '1'}`;
    const existing = aggregates[key];
    if (existing) {
      existing.count = normalizeRumCounterUpdateCount(existing.count) + normalizeRumCounterUpdateCount(update.count);
      if (update.flushMaxKeys && update.flushMaxKeys > 0) {
        existing.flushMaxKeys = existing.flushMaxKeys && existing.flushMaxKeys > 0 ?
          Math.min(existing.flushMaxKeys, update.flushMaxKeys) : update.flushMaxKeys;
      }
      continue;
    }
    aggregates[key] = {
      updateType: update.updateType,
      viewId: update.viewId || '',
      actionId: update.actionId || '',
      updateView: update.updateView,
      flushMaxKeys: update.flushMaxKeys,
      count: normalizeRumCounterUpdateCount(update.count)
    };
  }
  const result: SDKRumCounterUpdateDTO[] = [];
  const keys = Object.keys(aggregates).sort();
  for (let i = 0; i < keys.length; i++) {
    result.push(aggregates[keys[i]]);
  }
  return result;
}

function normalizeRumCounterUpdateCount(count: number | undefined): number {
  if (count === undefined || count !== count || count <= 0) {
    return 1;
  }
  return Math.max(1, Math.floor(count));
}

function applyRumCounterUpdate(
  update: SDKRumCounterUpdateDTO,
  state: SDKWorkerRuntimeState
): number {
  if (!update) {
    throw new Error('RUM counter update payload is required');
  }

  const updateType = update.updateType || '';
  const viewId = update.viewId || '';
  const actionId = update.actionId || '';
  const updateView = update.updateView !== false;
  const count = normalizeRumCounterUpdateCount(update.count);
  if (updateType === 'view.action') {
    appendViewActionCounterDelta(state, viewId, count);
  } else if (updateType === 'rum.error') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewErrorDelta += viewId.length > 0 ? count : 0;
    delta.actionErrorDelta += actionId.length > 0 ? count : 0;
    if (viewId.length > 0) {
      delta.viewUpdateTimeDelta += count;
      state.rumCounterNeedsRumDataGenerate = true;
    }
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterPendingEventCount += count;
  } else if (updateType === 'resource.complete') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    if (viewId.length > 0) {
      delta.viewResourceDelta += count;
      delta.viewPendingDelta -= count;
      delta.viewUpdateTimeDelta += count;
      state.rumCounterNeedsRumDataGenerate = true;
    }
    if (actionId.length > 0) {
      delta.actionResourceDelta += count;
      delta.actionPendingDelta -= count;
    }
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterPendingEventCount += count;
  } else if (updateType === 'resource.pending.increase') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewPendingDelta += viewId.length > 0 ? count : 0;
    delta.actionPendingDelta += actionId.length > 0 ? count : 0;
    state.rumCounterPendingEventCount += count;
  } else if (updateType === 'resource.pending.decrease') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewPendingDelta -= updateView && viewId.length > 0 ? count : 0;
    delta.actionPendingDelta -= actionId.length > 0 ? count : 0;
    state.rumCounterPendingEventCount += count;
  } else if (updateType === 'long_task.view') {
    const delta = getOrCreateRumCounterDelta(state, viewId, '');
    if (viewId.length > 0) {
      delta.viewLongTaskDelta += count;
      delta.viewUpdateTimeDelta += count;
    }
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterNeedsRumDataGenerate = true;
    state.rumCounterPendingEventCount += count;
  } else if (updateType === 'long_task.action') {
    const delta = getOrCreateRumCounterDelta(state, '', actionId);
    delta.actionLongTaskDelta += actionId.length > 0 ? count : 0;
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterNeedsRumDataGenerate = true;
    state.rumCounterPendingEventCount += count;
  } else {
    throw new Error(`Unsupported RUM counter update type: ${updateType}`);
  }

  return update.flushMaxKeys && update.flushMaxKeys > 0 ? update.flushMaxKeys : 256;
}

function createRumCounterUpdateResultPayload(
  state: SDKWorkerRuntimeState,
  flushMaxKeys: number
): SDKRumCounterUpdateResultDTO {
  const pendingCount = state.rumCounterPendingEventCount;
  const effectiveFlushMaxKeys = flushMaxKeys > 0 ? flushMaxKeys : 256;
  const shouldFlush = pendingCount >= effectiveFlushMaxKeys;
  const payload: SDKRumCounterUpdateResultDTO = {
    accepted: true,
    pendingCount,
    shouldFlush
  };
  if (shouldFlush) {
    const flushPayload = createRumCounterFlushPayload(state);
    payload.deltas = flushPayload.deltas;
    payload.needsActionCloseCheck = flushPayload.needsActionCloseCheck;
    payload.needsRumDataGenerate = flushPayload.needsRumDataGenerate;
  }
  return payload;
}

function handleRumCounterFlush(state: SDKWorkerRuntimeState): SDKWorkerPayload {
  return createRumCounterFlushPayload(state) as Object as SDKWorkerPayload;
}

function createRumCounterFlushPayload(state: SDKWorkerRuntimeState): SDKRumCounterFlushResultDTO {
  const deltas = finalizeRumCounterDeltas(state.rumCounterDeltas);

  const payload: SDKRumCounterFlushResultDTO = {
    deltas,
    needsActionCloseCheck: state.rumCounterNeedsActionCloseCheck,
    needsRumDataGenerate: state.rumCounterNeedsRumDataGenerate
  };

  state.rumCounterDeltas = {};
  state.rumCounterPendingEventCount = 0;
  state.rumCounterNeedsActionCloseCheck = false;
  state.rumCounterNeedsRumDataGenerate = false;
  return payload;
}

function finalizeRumCounterDeltas(
  pending: Record<string, SDKRumCounterDeltaDTO>
): SDKRumCounterDeltaDTO[] {
  const views: Record<string, SDKRumCounterDeltaDTO> = {};
  const actions: Record<string, SDKRumCounterDeltaDTO> = {};
  const pendingKeys = Object.keys(pending).sort();
  for (let i = 0; i < pendingKeys.length; i++) {
    const delta = pending[pendingKeys[i]];
    if (!delta) {
      continue;
    }
    if (delta.viewId && delta.viewId.length > 0) {
      const view = getOrCreateFinalCounterDelta(views, delta.viewId, true);
      view.viewActionDelta += normalizePositiveCounterDelta(delta.viewActionDelta);
      view.viewErrorDelta += normalizePositiveCounterDelta(delta.viewErrorDelta);
      view.viewLongTaskDelta += normalizePositiveCounterDelta(delta.viewLongTaskDelta);
      view.viewResourceDelta += normalizePositiveCounterDelta(delta.viewResourceDelta);
      view.viewPendingDelta += normalizeSignedCounterDelta(delta.viewPendingDelta);
      view.viewUpdateTimeDelta += normalizePositiveCounterDelta(delta.viewUpdateTimeDelta);
    }
    if (delta.actionId && delta.actionId.length > 0) {
      const action = getOrCreateFinalCounterDelta(actions, delta.actionId, false);
      action.actionErrorDelta += normalizePositiveCounterDelta(delta.actionErrorDelta);
      action.actionLongTaskDelta += normalizePositiveCounterDelta(delta.actionLongTaskDelta);
      action.actionResourceDelta += normalizePositiveCounterDelta(delta.actionResourceDelta);
      action.actionPendingDelta += normalizeSignedCounterDelta(delta.actionPendingDelta);
    }
  }

  const result: SDKRumCounterDeltaDTO[] = [];
  appendFinalCounterDeltas(result, views);
  appendFinalCounterDeltas(result, actions);
  return result;
}

function getOrCreateFinalCounterDelta(
  aggregates: Record<string, SDKRumCounterDeltaDTO>,
  id: string,
  isView: boolean
): SDKRumCounterDeltaDTO {
  let delta = aggregates[id];
  if (!delta) {
    delta = createEmptyRumCounterDelta(isView ? id : '', isView ? '' : id);
    aggregates[id] = delta;
  }
  return delta;
}

function appendFinalCounterDeltas(
  target: SDKRumCounterDeltaDTO[],
  aggregates: Record<string, SDKRumCounterDeltaDTO>
): void {
  const keys = Object.keys(aggregates).sort();
  for (let i = 0; i < keys.length; i++) {
    const delta = aggregates[keys[i]];
    if (hasFinalCounterDelta(delta)) {
      target.push(delta);
    }
  }
}

function hasFinalCounterDelta(delta: SDKRumCounterDeltaDTO): boolean {
  return delta.viewErrorDelta !== 0 || delta.actionErrorDelta !== 0 ||
    delta.viewLongTaskDelta !== 0 || delta.actionLongTaskDelta !== 0 ||
    delta.viewResourceDelta !== 0 || delta.actionResourceDelta !== 0 ||
    delta.viewPendingDelta !== 0 || delta.actionPendingDelta !== 0 ||
    delta.viewActionDelta !== 0 || delta.viewUpdateTimeDelta !== 0;
}

function normalizePositiveCounterDelta(delta: number): number {
  return delta === delta ? Math.max(0, Math.floor(delta)) : 0;
}

function normalizeSignedCounterDelta(delta: number): number {
  return delta === delta ? Math.floor(delta) : 0;
}

function handleLogEnqueue(payload: SDKLogEnqueuePayload, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const logs = payload && payload.logs ? payload.logs : [];
  const forceFlush = payload && payload.forceFlush === true;
  for (let i = 0; i < logs.length; i++) {
    state.logQueue.push(logs[i]);
  }
  return drainLogQueue(state, forceFlush, payload ? payload.lineContext : undefined);
}

function handleLogFlush(
  state: SDKWorkerRuntimeState,
  forceFlush: boolean,
  payload?: SDKLogFlushPayload
): SDKWorkerPayload {
  return drainLogQueue(state, forceFlush, payload ? payload.lineContext : undefined);
}

function drainLogQueue(
  state: SDKWorkerRuntimeState,
  forceFlush: boolean,
  lineContext?: SDKLineProtocolContextDTO
): SDKWorkerPayload {
  const effectiveLineContext = lineContext || state.lineContext || undefined;
  while (state.logQueue.length > 0) {
    state.logBatchBuffer.push(state.logQueue.shift() as SDKLogDTO);
  }

  const batches: SDKLogDTO[][] = [];
  while (state.logBatchBuffer.length >= DEFAULT_BATCH_SIZE) {
    batches.push(shiftLogBatch(state, DEFAULT_BATCH_SIZE));
  }
  if (forceFlush && state.logBatchBuffer.length > 0) {
    batches.push(shiftLogBatch(state, DEFAULT_BATCH_SIZE));
  }

  const batchSilences = createLogBatchSilences(batches);
  const draftBatches = effectiveLineContext ? createLogDraftBatches(batches, effectiveLineContext) : undefined;
  const payload: SDKLogDrainResultPayload = {
    batches: draftBatches ? [] : batches,
    draftBatches,
    batchSilences,
    queueSize: state.logQueue.length,
    bufferSize: state.logBatchBuffer.length,
    coalesceDelayMs: LOG_PROCESS_COALESCE_DELAY_MS,
    batchSize: DEFAULT_BATCH_SIZE
  };
  return payload as Object as SDKWorkerPayload;
}

function shiftLogBatch(state: SDKWorkerRuntimeState, maxSize: number): SDKLogDTO[] {
  const batch: SDKLogDTO[] = [];
  while (state.logBatchBuffer.length > 0 && batch.length < maxSize) {
    batch.push(state.logBatchBuffer.shift() as SDKLogDTO);
  }
  return batch;
}

function createLogDraftBatches(
  batches: SDKLogDTO[][],
  lineContext: SDKLineProtocolContextDTO
): SDKSyncDataDraftDTO[][] {
  const draftBatches: SDKSyncDataDraftDTO[][] = [];
  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    const drafts: SDKSyncDataDraftDTO[] = [];
    for (let j = 0; j < batch.length; j++) {
      drafts.push(createLogDraft(batch[j], lineContext));
    }
    draftBatches.push(drafts);
  }
  return draftBatches;
}

function createLogBatchSilences(batches: SDKLogDTO[][]): boolean[] {
  const batchSilences: boolean[] = [];
  for (let i = 0; i < batches.length; i++) {
    batchSilences.push(isLogBatchSilence(batches[i]));
  }
  return batchSilences;
}

function isLogBatchSilence(batch: SDKLogDTO[]): boolean {
  if (!batch || batch.length === 0) {
    return true;
  }
  for (let i = 0; i < batch.length; i++) {
    if (batch[i].isSilence !== true) {
      return false;
    }
  }
  return true;
}

function createLogDraft(log: SDKLogDTO, lineContext: SDKLineProtocolContextDTO): SDKSyncDataDraftDTO {
  const uuid = generateWorkerUuid();
  const tags = prepareLogTags(log.tags || {}, uuid, lineContext);
  const fields = copyStringRecord(log.fields || {});
  if (!fields[Constants.KEY_MESSAGE] || fields[Constants.KEY_MESSAGE].length === 0) {
    fields[Constants.KEY_MESSAGE] = log.content || '';
  }
  const measurement = log.measurement && log.measurement.length > 0 ?
    log.measurement : Constants.FT_LOG_DEFAULT_MEASUREMENT;
  return {
    dataType: 'log',
    dataString: buildLineProtocol(measurement, tags, fields, log.timeNano, lineContext.integerCompatible === true),
    uuid,
    time: log.timeNano
  };
}

function prepareLogTags(
  logTags: SDKStringRecord,
  uuid: string,
  lineContext: SDKLineProtocolContextDTO
): SDKStringRecord {
  const merged: SDKStringRecord = {};
  merged[Constants.KEY_SDK_DATA_FLAG] = uuid;
  mergeStringRecords(merged, lineContext.dynamicBaseTags);
  mergeStringRecords(merged, lineContext.logTags);
  mergeStringRecords(merged, lineContext.dynamicLogTags);
  mergeStringRecords(merged, logTags);
  if (lineContext.logLinkRumData) {
    mergeStringRecords(merged, lineContext.rumTags);
  }
  merged[Constants.KEY_SDK_DATA_FLAG] = uuid;
  return merged;
}

function mergeStringRecords(target: SDKStringRecord, source: SDKStringRecord): void {
  if (!source) {
    return;
  }
  const keys = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    target[key] = source[key];
  }
}

function generateWorkerUuid(): string {
  const now = Date.now().toString(16);
  const randomA = Math.floor(Math.random() * 0x100000000).toString(16);
  const randomB = Math.floor(Math.random() * 0x100000000).toString(16);
  return `${now}-${randomA}-${randomB}`;
}

function handleCreateLineProtocol(payload: SDKLineProtocolRecordsPayload): SDKWorkerPayload {
  const inputs = payload && payload.records ? payload.records : [];
  const drafts: SDKSyncDataDraftDTO[] = [];
  for (let i = 0; i < inputs.length; i++) {
    const input = inputs[i];
    drafts.push({
      dataType: input.dataType,
      customDataType: input.customDataType,
      dataString: buildLineProtocol(input.measurement, input.tags, input.fields, input.time, input.integerCompatible === true),
      uuid: input.uuid,
      time: input.time
    });
  }
  const result: SDKLineProtocolDraftsPayload = { drafts };
  return result as Object as SDKWorkerPayload;
}

function handleParseCrashText(payload: SDKCrashFileDTO): SDKWorkerPayload {
  if (!payload) {
    throw new Error('Crash payload is required');
  }
  const maxLength = payload.maxLength > 0 ? payload.maxLength : 30720;
  const content = payload.content || '';
  const trimmedContent = content.length > maxLength ? content.substring(0, maxLength) : content;
  const fields = copyStringRecord(payload.fields || {});
  fields['message'] = trimmedContent;
  fields['file_name'] = payload.fileName || '';
  const draft: SDKSyncDataDraftDTO = {
    dataType: payload.dataType,
    dataString: buildLineProtocol(payload.measurement, payload.tags || {}, fields, payload.time, false),
    uuid: payload.uuid,
    time: payload.time
  };
  const result: SDKCrashParsePayload = {
    drafts: [draft],
    originalLength: content.length,
    trimmedLength: trimmedContent.length
  };
  return result as Object as SDKWorkerPayload;
}

function handleUploadSchedule(payload: SDKUploadSchedulePayload, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const delay = Math.max(0, payload && payload.delay ? payload.delay : 0);
  const now = Date.now();
  if (state.uploadIsScheduled || state.uploadRunningTaskId.length > 0) {
    state.uploadNeedReschedule = true;
    if (state.uploadScheduledDelay > 0) {
      state.uploadScheduledDelay = Math.min(state.uploadScheduledDelay, delay);
    } else {
      state.uploadScheduledDelay = delay;
    }
    const rescheduleResult: SDKUploadScheduleResultPayload = {
      accepted: false,
      needReschedule: true,
      delay: state.uploadScheduledDelay,
      shouldRun: false
    };
    return rescheduleResult as Object as SDKWorkerPayload;
  }

  state.uploadRoundSequence++;
  state.uploadIsScheduled = true;
  state.uploadNeedReschedule = false;
  state.uploadScheduledDelay = delay;
  state.uploadScheduledAt = now;
  state.uploadRunningTaskId = `upload-worker-round-${state.uploadRoundSequence}`;
  const result: SDKUploadScheduleResultPayload = {
    accepted: true,
    needReschedule: false,
    delay,
    shouldRun: true,
    runningTaskId: state.uploadRunningTaskId
  };
  return result as Object as SDKWorkerPayload;
}

function handleUploadScheduleRoundFinish(state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const shouldRunAgain = state.uploadNeedReschedule;
  const nextDelay = state.uploadScheduledDelay;
  state.uploadIsScheduled = shouldRunAgain;
  state.uploadNeedReschedule = false;
  state.uploadScheduledDelay = shouldRunAgain ? nextDelay : 0;
  state.uploadScheduledAt = shouldRunAgain ? Date.now() : 0;
  state.uploadRunningTaskId = shouldRunAgain ? `upload-worker-round-${state.uploadRoundSequence + 1}` : '';
  if (shouldRunAgain) {
    state.uploadRoundSequence++;
  }
  const payload: SDKUploadRoundFinishPayload = {
    shouldRunAgain,
    nextDelay,
    runningTaskId: state.uploadRunningTaskId
  };
  return payload as Object as SDKWorkerPayload;
}

function handleUploadRoundStart(payload: SDKUploadRoundStartDTO, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  if (!payload) {
    throw new Error('Upload round start payload is required');
  }
  if (!payload.ownerId) {
    throw new Error('Upload round owner is required');
  }
  if (state.uploadOwnerId !== payload.ownerId) {
    resetUploadOwnerState(state, payload.ownerId);
  }
  restoreUploadCheckpointIfNewer(payload.checkpoint, state);
  ensureUploadProcessId(state);
  clearPendingUploadPage(state);
  state.uploadRoundSequence++;
  state.uploadRoundId = `upload-worker-round-${state.uploadRoundSequence}`;
  state.uploadRoundPageSize = normalizeUploadPageSize(payload.pageSize);
  state.uploadRoundMaxRetryCount = normalizeUploadMaxRetryCount(payload.maxRetryCount);
  state.uploadRoundSyncSleepTime = Math.max(0, payload.syncSleepTime || 0);
  state.uploadRoundProcessedPages = {};
  state.uploadRoundHasMoreData = false;
  state.uploadRoundConsumedRows = 0;
  state.uploadRoundComputeMs = 0;
  state.uploadAttemptSequence = 0;
  state.uploadingDataIds = {};
  state.uploadRunningTaskId = state.uploadRoundId;
  const result: SDKUploadRoundStartResultDTO = {
    accepted: true,
    roundId: state.uploadRoundId,
    pageSize: state.uploadRoundPageSize,
    syncSleepTime: state.uploadRoundSyncSleepTime,
    maxRetryCount: state.uploadRoundMaxRetryCount,
    checkpoint: createUploadCheckpoint(state)
  };
  return result as Object as SDKWorkerPayload;
}

function resetUploadOwnerState(state: SDKWorkerRuntimeState, ownerId: string): void {
  state.uploadOwnerId = ownerId;
  state.uploadRoundSequence = 0;
  state.uploadCheckpointVersion = 0;
  state.uploadPendingPage = null;
  state.uploadErrorCounts = {};
  state.uploadIgnoredClientErrorCounts = {};
  state.uploadingDataIds = {};
  state.uploadRumSequence = 0;
  state.uploadLogSequence = 0;
  state.uploadProcessId = 0;
}

function ensureUploadProcessId(state: SDKWorkerRuntimeState): void {
  if (state.uploadProcessId > 0) {
    return;
  }
  const seed = Date.now() ^ Math.floor(Math.random() * 1000000);
  state.uploadProcessId = Math.abs(seed % 65535) + 1;
}

function createUploadCheckpoint(state: SDKWorkerRuntimeState): SDKUploadCheckpointDTO {
  return {
    ownerId: state.uploadOwnerId,
    version: state.uploadCheckpointVersion,
    rumSequence: state.uploadRumSequence,
    logSequence: state.uploadLogSequence,
    processId: state.uploadProcessId,
    errorCounts: copyNumberRecord(state.uploadErrorCounts),
    ignoredErrorCounts: copyNumberRecord(state.uploadIgnoredClientErrorCounts)
  };
}

function copyUploadCheckpoint(checkpoint: SDKUploadCheckpointDTO): SDKUploadCheckpointDTO {
  return {
    ownerId: checkpoint.ownerId,
    version: checkpoint.version,
    rumSequence: checkpoint.rumSequence,
    logSequence: checkpoint.logSequence,
    processId: checkpoint.processId,
    errorCounts: copyNumberRecord(checkpoint.errorCounts),
    ignoredErrorCounts: copyNumberRecord(checkpoint.ignoredErrorCounts)
  };
}

function copyNumberRecord(source: Record<string, number>): Record<string, number> {
  const result: Record<string, number> = {};
  if (!source) {
    return result;
  }
  const keys = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    result[keys[i]] = source[keys[i]];
  }
  return result;
}

function restoreUploadCheckpointIfNewer(
  checkpoint: SDKUploadCheckpointDTO | undefined,
  state: SDKWorkerRuntimeState
): void {
  if (!checkpoint || checkpoint.ownerId !== state.uploadOwnerId || checkpoint.version < state.uploadCheckpointVersion) {
    return;
  }
  applyUploadCheckpoint(checkpoint, state);
}

function applyUploadCheckpoint(checkpoint: SDKUploadCheckpointDTO, state: SDKWorkerRuntimeState): void {
  state.uploadCheckpointVersion = Math.max(0, checkpoint.version);
  state.uploadRumSequence = Math.max(0, checkpoint.rumSequence);
  state.uploadLogSequence = Math.max(0, checkpoint.logSequence);
  state.uploadProcessId = Math.max(0, checkpoint.processId);
  state.uploadErrorCounts = copyNumberRecord(checkpoint.errorCounts);
  state.uploadIgnoredClientErrorCounts = copyNumberRecord(checkpoint.ignoredErrorCounts);
}

function clearPendingUploadPage(state: SDKWorkerRuntimeState): void {
  const pending = state.uploadPendingPage;
  if (pending) {
    unmarkUploadRows(pending.dataType, pending.rows, state);
  }
  state.uploadPendingPage = null;
}

interface SDKUploadPreparedRows {
  sourceRows: SDKUploadRowDTO[];
  rows: SDKUploadRowDTO[];
  needsPersistence: boolean;
  deduplicatedRows: SDKUploadRowDTO[];
  packageId: string;
  bodySelection: SDKUploadBodySelection;
  deferredRows: number;
}

/**
 * Select exactly one package for an upload request. Existing package-prefixed
 * rows are kept together; raw rows are assigned one new package. This helper
 * is shared by the pre-HTTP persistence step and the HTTP execution step so
 * the Header package ID always matches every sdk_data_id in the request body.
 */
function prepareUploadRows(
  dataType: string,
  rows: SDKUploadRowDTO[],
  queryHasMore: boolean,
  requestedPackageId: string,
  state: SDKWorkerRuntimeState
): SDKUploadPreparedRows {
  const deduplicatedRows = deduplicateUploadRows(dataType, rows, state);
  const pageRows = deduplicatedRows.slice(0, state.uploadRoundPageSize);
  let packageId = requestedPackageId || findPersistedUploadPackageId(pageRows);
  let candidateRows: SDKUploadRowDTO[] = [];
  if (packageId.length > 0) {
    candidateRows = selectRowsForUploadPackage(pageRows, packageId);
  } else {
    candidateRows = selectRawUploadRows(pageRows);
  }

  let bodySelection: SDKUploadBodySelection = createEmptyUploadBodySelection();
  if (candidateRows.length > 0) {
    if (packageId.length === 0) {
      const provisionalPackageId = createUploadPackageId(dataType, candidateRows.length, state);
      bodySelection = selectUploadRowsForBody(candidateRows, provisionalPackageId);
      packageId = provisionalPackageId;
      if (bodySelection.rows.length > 0 && bodySelection.rows.length !== candidateRows.length) {
        const bodyLimitReached = bodySelection.bodyLimitReached;
        packageId = createUploadPackageId(dataType, bodySelection.rows.length, state);
        bodySelection = selectUploadRowsForBody(bodySelection.rows, packageId);
        bodySelection.bodyLimitReached = bodyLimitReached || bodySelection.bodyLimitReached;
      }
    } else {
      bodySelection = selectUploadRowsForBody(candidateRows, packageId);
    }
  }

  const sourceRows = bodySelection.rows;
  const preparedRows = createUploadReInsertRows(sourceRows, packageId);
  return {
    sourceRows,
    rows: preparedRows,
    needsPersistence: haveUploadRowsChanged(sourceRows, preparedRows),
    deduplicatedRows,
    packageId,
    bodySelection,
    deferredRows: Math.max(0, deduplicatedRows.length - sourceRows.length) + (queryHasMore ? 1 : 0)
  };
}

/**
 * UPLOAD_PREPARE_PAGE has already selected these rows. The Host has atomically
 * stored package-prefixed sdk_data_id values where the historical line has
 * that tag. Do not select the package a second time before HTTP: legacy RUM
 * resource/error rows can legitimately predate sdk_data_id, and a second
 * parser pass would drop the entire selected page and block later cold-launch
 * records behind it.
 */
function preparePersistedUploadRows(
  dataType: string,
  rows: SDKUploadRowDTO[],
  queryHasMore: boolean,
  packageId: string,
  state: SDKWorkerRuntimeState
): SDKUploadPreparedRows {
  const deduplicatedRows = deduplicateUploadRows(dataType, rows, state);
  const pageRows = deduplicatedRows.slice(0, state.uploadRoundPageSize);
  const bodySelection = selectUploadRowsForBody(pageRows, packageId);
  const sourceRows = bodySelection.rows;
  return {
    sourceRows,
    rows: sourceRows,
    needsPersistence: false,
    deduplicatedRows,
    packageId,
    bodySelection,
    deferredRows: Math.max(0, deduplicatedRows.length - sourceRows.length) + (queryHasMore ? 1 : 0)
  };
}

function handleUploadPreparePage(
  payload: SDKUploadPreparePageDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  const startedAt = Date.now();
  assertUploadRound(payload ? payload.roundId : '', state);
  if (state.uploadPendingPage !== null) {
    throw new Error(`Upload page commit is pending: ${state.uploadPendingPage.attemptId}`);
  }
  const inputRows = payload && payload.rows ? payload.rows : [];
  const prepared = prepareUploadRows(
    payload.dataType,
    inputRows,
    payload.queryHasMore === true,
    '',
    state
  );
  const body = prepared.bodySelection.lines.join('\n');
  const hasMoreData = prepared.deferredRows > 0;
  if (hasMoreData) {
    state.uploadRoundHasMoreData = true;
  }
  const result: SDKUploadPreparePageResultDTO = {
    roundId: state.uploadRoundId,
    dataType: payload.dataType,
    sourceRows: prepared.sourceRows,
    rows: prepared.rows,
    needsPersistence: prepared.needsPersistence,
    queriedRows: inputRows.length,
    acceptedRows: prepared.rows.length,
    duplicateRows: Math.max(0, inputRows.length - prepared.deduplicatedRows.length),
    deferredRows: prepared.deferredRows,
    packageId: prepared.packageId,
    bodyLength: body.length,
    bodyBytes: prepared.bodySelection.bodyBytes,
    bodyLimitReached: prepared.bodySelection.bodyLimitReached,
    transportLimitReached: payload.transportLimitReached === true,
    bodyPreview: body,
    shouldExecute: prepared.rows.length > 0,
    roundHasMoreData: state.uploadRoundHasMoreData,
    computeMs: finishUploadComputeMetric(state, startedAt)
  };
  return result as Object as SDKWorkerPayload;
}

async function handleUploadExecutePage(
  payload: SDKUploadExecutePageDTO,
  state: SDKWorkerRuntimeState,
  httpExecutor: SDKUploadWorkerHttpExecutor
): Promise<SDKWorkerPayload> {
  const prepareStartedAt = Date.now();
  assertUploadRound(payload ? payload.roundId : '', state);
  if (state.uploadPendingPage !== null) {
    throw new Error(`Upload page commit is pending: ${state.uploadPendingPage.attemptId}`);
  }

  const rows = payload && payload.rows ? payload.rows : [];
  const requestedPackageId = payload.packageId || '';
  const preparedRows = payload.sdkDataIdPersisted === true && requestedPackageId.length > 0 ?
    preparePersistedUploadRows(
      payload.dataType,
      rows,
      payload.queryHasMore === true,
      requestedPackageId,
      state
    ) : prepareUploadRows(
      payload.dataType,
      rows,
      payload.queryHasMore === true,
      requestedPackageId,
      state
    );
  const deduplicatedRows = preparedRows.deduplicatedRows;
  if (preparedRows.sourceRows.length === 0) {
    const queryHasMore = payload.queryHasMore === true;
    const hasDeferredRows = preparedRows.deferredRows > 0;
    if (queryHasMore || hasDeferredRows) {
      state.uploadRoundHasMoreData = true;
    }
    const computeMs = finishUploadComputeMetric(state, prepareStartedAt);
    const emptyResult: SDKUploadExecutePageResultDTO = {
      roundId: state.uploadRoundId,
      attemptId: '',
      dataType: payload.dataType,
      rows: [],
      queriedRows: rows.length,
      acceptedRows: 0,
      duplicateRows: Math.max(0, rows.length - deduplicatedRows.length),
      deferredRows: preparedRows.deferredRows,
      packageId: preparedRows.packageId,
      bodyLength: 0,
      bodyBytes: 0,
      bodyLimitReached: preparedRows.bodySelection.bodyLimitReached,
      transportLimitReached: payload.transportLimitReached === true,
      bodyPreview: '',
      shouldUpload: false,
      outcome: SDKUploadPageOutcome.EMPTY_BODY,
      httpResult: createEmptyUploadHttpResult(),
      dbAction: SDKUploadDbActionDTO.NONE,
      reInsertRows: [],
      reduceCount: 0,
      delayMs: queryHasMore ? DATA_UPLOAD_LIMIT_RETRY_DELAY_MS : 0,
      shouldContinueDataType: false,
      roundHasMoreData: state.uploadRoundHasMoreData,
      retryCount: getUploadErrorCount(state, payload.dataType),
      retryLimitReached: false,
      ignoredClientError: false,
      successfulResponse: false,
      errorCount: getAggregateUploadErrorCount(state),
      computeMs,
      checkpointAfterCommit: createUploadCheckpoint(state)
    };
    return emptyResult as Object as SDKWorkerPayload;
  }

  const bodySelection = preparedRows.bodySelection;
  const packageId = preparedRows.packageId;
  const acceptedRows = preparedRows.rows;
  const body = bodySelection.lines.join('\n');
  const deferredRows = preparedRows.deferredRows;
  const shouldUpload = body.length > 0;
  if (shouldUpload) {
    markUploadRows(payload.dataType, acceptedRows, state);
  }
  let computeMs = finishUploadComputeMetric(state, prepareStartedAt);

  let httpResult = createEmptyUploadHttpResult();
  if (shouldUpload) {
    const preparedPayload = await prepareDataUploadPayload(
      body,
      payload.httpConfig.compressIntakeRequests === true
    );
    const httpRequest: SDKUploadHttpRequestDTO = {
      datakitUrl: payload.httpConfig.datakitUrl,
      datawayUrl: payload.httpConfig.datawayUrl,
      clientToken: payload.httpConfig.clientToken,
      model: payload.httpConfig.model,
      deviceTimeMs: payload.httpConfig.deviceTimeMs,
      connectTimeoutMs: payload.httpConfig.connectTimeoutMs,
      readTimeoutMs: payload.httpConfig.readTimeoutMs,
      softTimeoutMs: payload.httpConfig.softTimeoutMs,
      compressIntakeRequests: payload.httpConfig.compressIntakeRequests,
      proxy: payload.httpConfig.proxy,
      dnsServers: payload.httpConfig.dnsServers,
      dnsOverHttps: payload.httpConfig.dnsOverHttps,
      body,
      packageId,
      compressedBody: preparedPayload.compressedBody,
      contentEncoding: preparedPayload.contentEncoding
    };
    const httpStartedAt = Date.now();
    if (payload.injectedHttpResult) {
      httpResult = copyInjectedUploadHttpResult(payload.injectedHttpResult);
    } else {
      try {
        httpResult = await httpExecutor.execute(httpRequest);
      } catch (error) {
        httpResult = {
          code: NetCodeStatus.UNKNOWN_EXCEPTION_CODE,
          message: error instanceof Error ? error.message : String(error),
          errorCode: '',
          elapsedMs: Math.max(0, Date.now() - httpStartedAt),
          softTimedOut: false
        };
      }
    }
  }

  const classifyStartedAt = Date.now();
  const checkpointAfterCommit = createNextUploadCheckpoint(state);
  const proposal = classifyUploadPageResult(
    payload.dataType,
    acceptedRows,
    rows.length,
    shouldUpload ? SDKUploadPageOutcome.HTTP : SDKUploadPageOutcome.EMPTY_BODY,
    httpResult.code,
    deferredRows > 0,
    packageId,
    payload.sdkDataIdPersisted === true,
    checkpointAfterCommit,
    state
  );
  computeMs += finishUploadComputeMetric(state, classifyStartedAt);
  state.uploadAttemptSequence++;
  const attemptId = `${state.uploadRoundId}:${payload.dataType}:${state.uploadAttemptSequence}`;
  state.uploadPendingPage = {
    attemptId,
    dataType: payload.dataType,
    rows: acceptedRows,
    checkpointAfterCommit: copyUploadCheckpoint(checkpointAfterCommit),
    processedPagesAfterCommit: proposal.processedPagesAfterCommit,
    roundHasMoreDataAfterCommit: proposal.roundHasMoreData,
    // A failed HTTP request is not consumed: its rows remain in the cache and
    // must not be interpreted by the scheduler as forward progress. Only a
    // delete decision removes records permanently.
    consumedRowsDelta: proposal.dbAction === SDKUploadDbActionDTO.DELETE ? proposal.reduceCount : 0,
    delayMs: proposal.delayMs,
    shouldContinueDataType: proposal.shouldContinueDataType
  };

  const result: SDKUploadExecutePageResultDTO = {
    roundId: state.uploadRoundId,
    attemptId,
    dataType: payload.dataType,
    rows: acceptedRows,
    queriedRows: rows.length,
    acceptedRows: acceptedRows.length,
    duplicateRows: Math.max(0, rows.length - deduplicatedRows.length),
    deferredRows,
    packageId,
    bodyLength: body.length,
    bodyBytes: bodySelection.bodyBytes,
    bodyLimitReached: bodySelection.bodyLimitReached,
    transportLimitReached: payload.transportLimitReached === true,
    // This value is emitted by the UPLOAD BODY PREVIEW diagnostic. Keep every
    // byte of the prepared request body so the log can be compared directly
    // with the payload sent to DataKit/Dataway.
    bodyPreview: body,
    shouldUpload,
    outcome: shouldUpload ? SDKUploadPageOutcome.HTTP : SDKUploadPageOutcome.EMPTY_BODY,
    httpResult,
    dbAction: proposal.dbAction,
    reInsertRows: proposal.reInsertRows,
    reduceCount: proposal.reduceCount,
    delayMs: proposal.delayMs,
    shouldContinueDataType: proposal.shouldContinueDataType,
    roundHasMoreData: proposal.roundHasMoreData,
    retryCount: proposal.retryCount,
    retryLimitReached: proposal.retryLimitReached,
    ignoredClientError: proposal.ignoredClientError,
    successfulResponse: proposal.successfulResponse,
    errorCount: getAggregateErrorCountFromRecord(checkpointAfterCommit.errorCounts),
    computeMs,
    checkpointAfterCommit
  };
  return result as Object as SDKWorkerPayload;
}

interface SDKUploadPageProposal {
  dbAction: SDKUploadDbActionDTO;
  reInsertRows: SDKUploadRowDTO[];
  reduceCount: number;
  delayMs: number;
  shouldContinueDataType: boolean;
  roundHasMoreData: boolean;
  retryCount: number;
  retryLimitReached: boolean;
  ignoredClientError: boolean;
  successfulResponse: boolean;
  processedPagesAfterCommit: number;
}

function classifyUploadPageResult(
  dataType: string,
  rows: SDKUploadRowDTO[],
  queriedRows: number,
  outcome: SDKUploadPageOutcome,
  httpCode: number,
  hasDeferredRows: boolean,
  packageId: string,
  sdkDataIdPersisted: boolean,
  checkpoint: SDKUploadCheckpointDTO,
  state: SDKWorkerRuntimeState
): SDKUploadPageProposal {
  let dbAction = SDKUploadDbActionDTO.NONE;
  let reInsertRows: SDKUploadRowDTO[] = [];
  let reduceCount = 0;
  let delayMs = 0;
  let retryCount = getCheckpointUploadErrorCount(checkpoint, dataType);
  let retryLimitReached = false;
  let ignoredClientError = false;
  let successfulResponse = false;
  let stopDataType = false;
  let rescheduleRound = false;

  if (outcome === SDKUploadPageOutcome.EMPTY_BODY) {
    dbAction = SDKUploadDbActionDTO.DELETE;
    reduceCount = rows.length;
    successfulResponse = true;
  } else if (httpCode === 403 || httpCode === 429) {
    dbAction = SDKUploadDbActionDTO.DELETE;
    reduceCount = rows.length;
    checkpoint.errorCounts[dataType] = 0;
    const ignoredCount = (checkpoint.ignoredErrorCounts[dataType] || 0) + 1;
    checkpoint.ignoredErrorCounts[dataType] = ignoredCount;
    delayMs = getUploadIgnoredBackoffMs(ignoredCount);
    ignoredClientError = true;
    stopDataType = true;
    retryCount = 0;
  } else if (httpCode >= 200 && httpCode < 500) {
    dbAction = SDKUploadDbActionDTO.DELETE;
    reduceCount = rows.length;
    checkpoint.errorCounts[dataType] = 0;
    checkpoint.ignoredErrorCounts[dataType] = 0;
    if (httpCode === 200) {
      advanceUploadCheckpointPackageSequence(dataType, checkpoint);
    }
    successfulResponse = httpCode >= 200 && httpCode < 300;
    retryCount = 0;
  } else if (isRetryableUploadCode(httpCode)) {
    // Production calls persist the package-prefixed sdk_data_id before HTTP.
    // Keep those rows untouched on a retry; legacy/direct callers still get
    // the old reinsert behavior so their first failed attempt is durable.
    if (sdkDataIdPersisted) {
      dbAction = SDKUploadDbActionDTO.NONE;
    } else {
      dbAction = SDKUploadDbActionDTO.REINSERT;
      reInsertRows = createUploadReInsertRows(rows, packageId);
    }
    checkpoint.ignoredErrorCounts[dataType] = 0;
    retryCount = Math.min(
      state.uploadRoundMaxRetryCount + 1,
      getCheckpointUploadErrorCount(checkpoint, dataType) + 1
    );
    checkpoint.errorCounts[dataType] = retryCount;
    retryLimitReached = retryCount > state.uploadRoundMaxRetryCount;
    delayMs = retryLimitReached ? 0 : getUploadNormalBackoffMs(retryCount);
    stopDataType = true;
    rescheduleRound = !retryLimitReached;
  } else {
    retryCount = Math.min(
      state.uploadRoundMaxRetryCount + 1,
      getCheckpointUploadErrorCount(checkpoint, dataType) + 1
    );
    checkpoint.errorCounts[dataType] = retryCount;
    retryLimitReached = retryCount > state.uploadRoundMaxRetryCount;
    delayMs = retryLimitReached ? 0 : getUploadNormalBackoffMs(retryCount);
    stopDataType = true;
    rescheduleRound = !retryLimitReached;
  }

  const processedPagesAfterCommit = (state.uploadRoundProcessedPages[dataType] || 0) + 1;
  const pageWasFull = queriedRows >= state.uploadRoundPageSize;
  const pageHasMoreData = pageWasFull || hasDeferredRows;
  const maxPages = getUploadMaxPages(dataType);
  const shouldContinueDataType = !stopDataType && pageHasMoreData && processedPagesAfterCommit < maxPages;
  let roundHasMoreData = state.uploadRoundHasMoreData;
  if (rescheduleRound || (!stopDataType && pageHasMoreData && processedPagesAfterCommit >= maxPages)) {
    roundHasMoreData = true;
  }
  if (shouldContinueDataType && delayMs === 0) {
    delayMs = state.uploadRoundSyncSleepTime;
  }
  return {
    dbAction,
    reInsertRows,
    reduceCount,
    delayMs,
    shouldContinueDataType,
    roundHasMoreData,
    retryCount,
    retryLimitReached,
    ignoredClientError,
    successfulResponse,
    processedPagesAfterCommit
  };
}

function handleUploadCommitPage(payload: SDKUploadCommitPageDTO, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  assertUploadRound(payload ? payload.roundId : '', state);
  const pending = state.uploadPendingPage;
  if (!pending || pending.attemptId !== payload.attemptId) {
    throw new Error(`Upload page commit mismatch: expected=${pending ? pending.attemptId : ''}, actual=${
      payload ? payload.attemptId : ''}`);
  }

  let delayMs = pending.delayMs;
  let shouldContinueDataType = pending.shouldContinueDataType;
  if (payload.dbSucceeded) {
    applyUploadCheckpoint(pending.checkpointAfterCommit, state);
    state.uploadRoundProcessedPages[pending.dataType] = pending.processedPagesAfterCommit;
    state.uploadRoundHasMoreData = pending.roundHasMoreDataAfterCommit;
    state.uploadRoundConsumedRows += pending.consumedRowsDelta;
  } else {
    state.uploadRoundHasMoreData = true;
    delayMs = Math.max(500, delayMs);
    shouldContinueDataType = false;
  }
  unmarkUploadRows(pending.dataType, pending.rows, state);
  const dataType = pending.dataType;
  state.uploadPendingPage = null;

  const result: SDKUploadCommitPageResultDTO = {
    roundId: state.uploadRoundId,
    dataType,
    delayMs,
    shouldContinueDataType,
    roundHasMoreData: state.uploadRoundHasMoreData,
    errorCount: getAggregateUploadErrorCount(state),
    consumedRows: state.uploadRoundConsumedRows,
    checkpoint: createUploadCheckpoint(state)
  };
  return result as Object as SDKWorkerPayload;
}

function createEmptyUploadHttpResult(): SDKUploadHttpResultDTO {
  return {
    code: 0,
    message: '',
    errorCode: '',
    elapsedMs: 0,
    softTimedOut: false
  };
}

function createNextUploadCheckpoint(state: SDKWorkerRuntimeState): SDKUploadCheckpointDTO {
  const checkpoint = createUploadCheckpoint(state);
  checkpoint.version = state.uploadCheckpointVersion + 1;
  return checkpoint;
}

function getCheckpointUploadErrorCount(checkpoint: SDKUploadCheckpointDTO, dataType: string): number {
  return checkpoint.errorCounts[dataType] || 0;
}

function advanceUploadCheckpointPackageSequence(dataType: string, checkpoint: SDKUploadCheckpointDTO): void {
  const maxValue = Math.pow(36, 8);
  if (dataType === 'log') {
    checkpoint.logSequence = checkpoint.logSequence >= maxValue ? 0 : checkpoint.logSequence + 1;
  } else {
    checkpoint.rumSequence = checkpoint.rumSequence >= maxValue ? 0 : checkpoint.rumSequence + 1;
  }
}

function getAggregateErrorCountFromRecord(errorCounts: Record<string, number>): number {
  const keys = Object.keys(errorCounts);
  let maxCount = 0;
  for (let i = 0; i < keys.length; i++) {
    maxCount = Math.max(maxCount, errorCounts[keys[i]] || 0);
  }
  return maxCount;
}

function handleUploadConsumeFinish(payload: SDKUploadRoundFinishDTO, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  assertUploadRound(payload ? payload.roundId : '', state);
  clearPendingUploadPage(state);
  const result: SDKUploadRoundResultDTO = {
    roundId: state.uploadRoundId,
    consumedRows: state.uploadRoundConsumedRows,
    hasMoreData: state.uploadRoundHasMoreData,
    errorCount: getAggregateUploadErrorCount(state),
    computeMs: state.uploadRoundComputeMs,
    checkpoint: createUploadCheckpoint(state)
  };
  state.uploadRoundId = '';
  state.uploadRoundProcessedPages = {};
  state.uploadRoundHasMoreData = false;
  state.uploadRoundConsumedRows = 0;
  state.uploadRoundComputeMs = 0;
  state.uploadAttemptSequence = 0;
  state.uploadingDataIds = {};
  state.uploadRunningTaskId = '';
  return result as Object as SDKWorkerPayload;
}

function assertUploadRound(roundId: string, state: SDKWorkerRuntimeState): void {
  if (!roundId || state.uploadRoundId.length === 0 || roundId !== state.uploadRoundId) {
    throw new Error(`Upload worker round mismatch: expected=${state.uploadRoundId}, actual=${roundId}`);
  }
}

function normalizeUploadPageSize(pageSize: number): number {
  if (pageSize !== pageSize || pageSize <= 0) {
    return 1;
  }
  return Math.min(DATA_UPLOAD_MAX_PAGE_SIZE, Math.max(1, Math.floor(pageSize)));
}

function normalizeUploadMaxRetryCount(retryCount: number | undefined): number {
  if (retryCount === undefined || retryCount !== retryCount) {
    return DATA_UPLOAD_MAX_RETRY_COUNT;
  }
  return Math.min(DATA_UPLOAD_MAX_RETRY_COUNT, Math.max(0, Math.floor(retryCount)));
}

function finishUploadComputeMetric(state: SDKWorkerRuntimeState, startedAt: number): number {
  const computeMs = Math.max(0, Date.now() - startedAt);
  state.uploadRoundComputeMs += computeMs;
  return computeMs;
}

function getUploadMaxPages(dataType: string): number {
  if (dataType === 'rum_app') {
    return 2;
  }
  return 1;
}

function deduplicateUploadRows(
  dataType: string,
  rows: SDKUploadRowDTO[],
  state: SDKWorkerRuntimeState
): SDKUploadRowDTO[] {
  const result: SDKUploadRowDTO[] = [];
  const seen: SDKStringRecord = {};
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (!row) {
      continue;
    }
    const key = getUploadDedupKey(dataType, row);
    if (state.uploadingDataIds[key] === '1' || seen[key] === '1') {
      continue;
    }
    seen[key] = '1';
    result.push(row);
  }
  return result;
}

function getUploadDedupKey(dataType: string, row: SDKUploadRowDTO): string {
  const uniqueId = extractUploadUniqueId(row.dataString || '');
  if (uniqueId.length > 0) {
    return `${dataType}:${uniqueId}`;
  }
  if (row.uuid && row.uuid.length > 0) {
    return `${dataType}:uuid=${row.uuid}`;
  }
  return `${dataType}:hash=${hashUploadString(row.dataString || '')}`;
}

function extractUploadUniqueId(dataString: string): string {
  if (dataString.startsWith('action,')) {
    const match = dataString.match(/action_id=([^,\s]+)/);
    return match && match[1] ? `action_id=${match[1]}` : '';
  }
  if (dataString.startsWith('view,')) {
    const viewId = dataString.match(/view_id=([^,\s]+)/);
    const updateTime = dataString.match(/view_update_time=([^,\s]+)/);
    if (viewId && viewId[1]) {
      return updateTime && updateTime[1] ?
        `view_id=${viewId[1]}:view_update_time=${updateTime[1]}` : `view_id=${viewId[1]}`;
    }
  }
  if (dataString.startsWith('resource,')) {
    const spanId = dataString.match(/span_id=([^,\s]+)/);
    if (spanId && spanId[1]) {
      return `span_id=${spanId[1]}`;
    }
    const traceId = dataString.match(/trace_id=([^,\s]+)/);
    if (traceId && traceId[1]) {
      return `trace_id=${traceId[1]}`;
    }
  }
  if (dataString.startsWith('error,')) {
    const errorType = dataString.match(/error_type=([^,\s]+)/);
    const errorMessage = dataString.match(/error_message="([^"]+)"/);
    const timestamp = dataString.match(/\s(\d+)$/);
    if (errorType || errorMessage || timestamp) {
      return `error_type=${errorType && errorType[1] ? errorType[1] : ''}:error_message=${
        errorMessage && errorMessage[1] ? errorMessage[1].substring(0, 100) : ''}:timestamp=${
        timestamp && timestamp[1] ? timestamp[1] : ''}`;
    }
  }
  if (dataString.startsWith('longtask,') || dataString.startsWith('long_task,')) {
    const name = dataString.match(/long_task_name=([^,\s]+)/);
    const timestamp = dataString.match(/\s(\d+)$/);
    if (name || timestamp) {
      return `long_task_name=${name && name[1] ? name[1] : ''}:timestamp=${
        timestamp && timestamp[1] ? timestamp[1] : ''}`;
    }
  }
  if (dataString.startsWith('df_rum_harmonyos_log,')) {
    const sdkDataId = dataString.match(/sdk_data_id=([^,\s]+)/);
    if (sdkDataId && sdkDataId[1]) {
      const uuid = sdkDataId[1].match(/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i);
      if (uuid && uuid[1]) {
        return `uuid=${uuid[1]}`;
      }
      return `sdk_data_id=${sdkDataId[1]}`;
    }
  }
  const timestamp = dataString.match(/\s(\d+)$/);
  return timestamp && timestamp[1] ? `timestamp=${timestamp[1]}` : '';
}

function hashUploadString(value: string): string {
  let hash = 0;
  for (let i = 0; i < value.length; i++) {
    hash = ((hash << 5) - hash) + value.charCodeAt(i);
    hash = hash & hash;
  }
  return Math.abs(hash).toString(16);
}

function markUploadRows(dataType: string, rows: SDKUploadRowDTO[], state: SDKWorkerRuntimeState): void {
  for (let i = 0; i < rows.length; i++) {
    state.uploadingDataIds[getUploadDedupKey(dataType, rows[i])] = '1';
  }
}

function unmarkUploadRows(dataType: string, rows: SDKUploadRowDTO[], state: SDKWorkerRuntimeState): void {
  for (let i = 0; i < rows.length; i++) {
    state.uploadingDataIds[getUploadDedupKey(dataType, rows[i])] = '';
  }
}

interface SDKUploadBodySelection {
  rows: SDKUploadRowDTO[];
  lines: string[];
  bodyBytes: number;
  bodyLimitReached: boolean;
}

function createEmptyUploadBodySelection(): SDKUploadBodySelection {
  return {
    rows: [],
    lines: [],
    bodyBytes: 0,
    bodyLimitReached: false,
  };
}

function haveUploadRowsChanged(sourceRows: SDKUploadRowDTO[], preparedRows: SDKUploadRowDTO[]): boolean {
  if (sourceRows.length !== preparedRows.length) {
    return true;
  }
  for (let i = 0; i < sourceRows.length; i++) {
    if (sourceRows[i].dataString !== preparedRows[i].dataString) {
      return true;
    }
  }
  return false;
}

/**
 * Returns only an established package prefix at the very start of
 * sdk_data_id. The suffix is intentionally opaque: legacy cache rows can
 * have a database UUID that differs from the line tag, or an old raw value
 * containing dots. This makes the outer persisted P authoritative.
 */
function getPersistedUploadPackageId(row: SDKUploadRowDTO): string {
  return getPersistedUploadPackageIdFromValue(getUploadSdkDataId(row));
}

function getUploadSdkDataId(row: SDKUploadRowDTO): string {
  if (!row || !row.dataString) {
    return '';
  }
  const match = row.dataString.match(/sdk_data_id=([^,\s]+)/);
  return match && match[1] ? match[1] : '';
}

function isGeneratedUploadPackageId(value: string): boolean {
  // `sequence.processId.rowCount.nanoId`; keep this strict so a legacy raw
  // sdk_data_id containing dots is never mistaken for an existing package.
  return /^[0-9a-z]+\.[0-9A-Za-z]+\.\d+\.[0-9A-Za-z]+$/.test(value);
}

function findPersistedUploadPackageId(rows: SDKUploadRowDTO[]): string {
  // Preserve the DB query order. The first row chooses the group; all rows
  // with a different historical package (or raw UUID) are deferred.
  return rows.length > 0 ? getPersistedUploadPackageId(rows[0]) : '';
}

function selectRowsForUploadPackage(rows: SDKUploadRowDTO[], packageId: string): SDKUploadRowDTO[] {
  const result: SDKUploadRowDTO[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (getPersistedUploadPackageId(rows[i]) === packageId) {
      result.push(rows[i]);
    }
  }
  return result;
}

function selectRawUploadRows(rows: SDKUploadRowDTO[]): SDKUploadRowDTO[] {
  const result: SDKUploadRowDTO[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (getPersistedUploadPackageId(rows[i]).length === 0) {
      result.push(rows[i]);
    }
  }
  return result;
}

function selectUploadRowsForBody(rows: SDKUploadRowDTO[], packageId: string): SDKUploadBodySelection {
  const result = createEmptyUploadBodySelection();
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    // The first upload assigns the established package-prefixed sdk_data_id
    // structure. A retry receives the persisted prefixed value and this helper
    // therefore leaves it unchanged.
    const line = row && row.dataString && row.dataString.trim().length > 0 ?
      applyPackageId(row.dataString, row.uuid, packageId) : '';
    if (line.length === 0) {
      result.rows.push(row);
      continue;
    }
    const lineBytes = getUploadUtf8ByteLength(line);
    const separatorBytes = result.lines.length > 0 ? 1 : 0;
    const exceedsBatchTarget = result.bodyBytes + separatorBytes + lineBytes > DATA_UPLOAD_BODY_TARGET_BYTES;
    if (exceedsBatchTarget && result.lines.length > 0) {
      result.bodyLimitReached = true;
      break;
    }
    result.rows.push(row);
    result.lines.push(line);
    result.bodyBytes += separatorBytes + lineBytes;
    if (exceedsBatchTarget) {
      // A large Error is sent alone rather than being retained forever by a
      // local request-size gate. The target still prevents normal batches
      // from growing without bound.
      result.bodyLimitReached = true;
      break;
    }
  }
  return result;
}

function getUploadUtf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code <= 0x7f) {
      bytes++;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const next = value.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function copyInjectedUploadHttpResult(result: SDKUploadHttpResultDTO): SDKUploadHttpResultDTO {
  return {
    code: result.code,
    message: result.message || '',
    errorCode: result.errorCode || '',
    elapsedMs: Math.max(0, result.elapsedMs || 0),
    softTimedOut: result.softTimedOut === true
  };
}

function createUploadPackageId(dataType: string, rowCount: number, state: SDKWorkerRuntimeState): string {
  if (state.uploadProcessId <= 0) {
    const seed = Date.now() ^ Math.floor(Math.random() * 1000000);
    state.uploadProcessId = Math.abs(seed % 65535) + 1;
  }
  const sequence = dataType === 'log' ? state.uploadLogSequence : state.uploadRumSequence;
  return `${encodeUploadNumber(sequence, 36)}.${encodeUploadNumber(state.uploadProcessId, 62)}.${rowCount}.${
    createUploadNanoId()}`;
}

function createUploadNanoId(): string {
  const characters = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  let result = '';
  for (let i = 0; i < 12; i++) {
    result += characters.charAt(Math.floor(Math.random() * characters.length));
  }
  return result;
}

function encodeUploadNumber(value: number, base: number): string {
  const characters = base === 36 ? '0123456789abcdefghijklmnopqrstuvwxyz' :
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  if (value <= 0) {
    return '0';
  }
  let current = Math.floor(value);
  let result = '';
  while (current > 0) {
    result = characters.charAt(current % base) + result;
    current = Math.floor(current / base);
  }
  return result;
}

function isRetryableUploadCode(code: number): boolean {
  return code >= 500 || code === NetCodeStatus.NETWORK_EXCEPTION_CODE ||
    code === NetCodeStatus.FILE_TIMEOUT_CODE || code === NetCodeStatus.UNKNOWN_EXCEPTION_CODE;
}

function getUploadErrorCount(state: SDKWorkerRuntimeState, dataType: string): number {
  return state.uploadErrorCounts[dataType] || 0;
}

function getAggregateUploadErrorCount(state: SDKWorkerRuntimeState): number {
  const keys = Object.keys(state.uploadErrorCounts);
  let maxCount = 0;
  for (let i = 0; i < keys.length; i++) {
    maxCount = Math.max(maxCount, state.uploadErrorCounts[keys[i]] || 0);
  }
  return maxCount;
}

function getUploadNormalBackoffMs(errorCount: number): number {
  return Math.max(1, Math.pow(2, Math.max(0, errorCount - 1))) * 500;
}

function getUploadIgnoredBackoffMs(errorCount: number): number {
  return Math.min(8000, getUploadNormalBackoffMs(errorCount));
}

function createUploadReInsertRows(rows: SDKUploadRowDTO[], packageId: string): SDKUploadRowDTO[] {
  const result: SDKUploadRowDTO[] = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    result.push({
      id: row.id,
      dataType: row.dataType,
      // Persist the exact sdk_data_id sent by the first attempt. This retains
      // the established package-prefixed format and prevents retries from
      // assigning another package prefix.
      dataString: applyPackageId(row.dataString, row.uuid, packageId),
      uuid: row.uuid,
      time: row.time,
      customDataType: row.customDataType
    });
  }
  return result;
}

function handleUploadFormatBody(payload: SDKUploadPageDTO): SDKWorkerPayload {
  if (!payload || !payload.rows) {
    throw new Error('Upload page payload is required');
  }
  const uniqueRows: SDKUploadRowDTO[] = [];
  const seen: SDKStringRecord = {};
  for (let i = 0; i < payload.rows.length && uniqueRows.length < DATA_UPLOAD_MAX_PAGE_SIZE; i++) {
    const row = payload.rows[i];
    if (!row || !row.dataString || seen[row.uuid]) {
      continue;
    }
    seen[row.uuid] = '1';
    uniqueRows.push(row);
  }
  const selection = selectUploadRowsForBody(uniqueRows, payload.packageId);
  const ids: number[] = [];
  for (let i = 0; i < selection.rows.length; i++) {
    ids.push(selection.rows[i].id);
  }
  const resultPayload: SDKUploadFormatBodyPayload = {
    body: selection.lines.join('\n'),
    rowIds: ids,
    acceptedRows: selection.lines.length,
    dataType: payload.dataType
  };
  return resultPayload as Object as SDKWorkerPayload;
}

/**
 * Assigns the established package-prefixed sdk_data_id only when no standard
 * package occupies its outer prefix. A non-standard historical value is raw:
 * it is wrapped exactly once, then its outer standard P is reused on every
 * retry without changing the value again.
 */
function applyPackageId(dataString: string, uuid: string, packageId: string): string {
  if (!dataString || !packageId) {
    return dataString || '';
  }
  const match = dataString.match(/sdk_data_id=([^,\s]+)/);
  if (!match || !match[1]) {
    return dataString;
  }
  const currentSdkDataId = match[1];
  if (getPersistedUploadPackageIdFromValue(currentSdkDataId).length > 0) {
    return dataString;
  }
  const replacement = `${Constants.KEY_SDK_DATA_FLAG}=${packageId}.${currentSdkDataId}`;
  return dataString.replace(`${Constants.KEY_SDK_DATA_FLAG}=${currentSdkDataId}`, replacement);
}

function getPersistedUploadPackageIdFromValue(value: string): string {
  // P is `sequence.processId.rowCount.nanoId`. Do not use the database UUID
  // or the last dot as a delimiter: both are historical data and may contain
  // dots. Matching only at the start prevents P.P.old-id prefix growth.
  const match = value.match(/^([0-9a-z]+\.[0-9A-Za-z]+\.\d+\.[0-9A-Za-z]+)\./);
  const packageId = match && match[1] ? match[1] : '';
  return isGeneratedUploadPackageId(packageId) ? packageId : '';
}

function buildLineProtocol(
  measurement: string,
  tags: SDKStringRecord,
  fields: SDKStringRecord,
  time: number,
  integerCompatible: boolean
): string {
  if (!measurement) {
    throw new Error('Measurement cannot be empty');
  }
  const tagText = buildRecord(tags, true, integerCompatible);
  const fieldText = buildRecord(fields, false, integerCompatible);
  let result = translateMeasurement(measurement);
  if (tagText.length > 0) {
    result += `,${tagText}`;
  }
  if (fieldText.length > 0) {
    result += ` ${fieldText}`;
  }
  if (time > 0) {
    result += ` ${time}`;
  }
  return result;
}

function buildRecord(record: SDKStringRecord, isTag: boolean, integerCompatible: boolean): string {
  const parts: string[] = [];
  if (!record) {
    return '';
  }
  const keys = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = record[key];
    if (value === undefined || value === null || String(value).length === 0) {
      continue;
    }
    const escapedKey = translateTagKeyValue(key);
    const stringValue = cleanLineProtocolValue(String(value));
    if (isTag) {
      const tagValue = key === 'sdk_pkg_info' && stringValue.startsWith('{') && stringValue.endsWith('}') ?
        translateTagKeyValueForJson(stringValue) : translateTagKeyValue(stringValue);
      parts.push(`${escapedKey}=${tagValue}`);
    } else if (isNumericOrBoolean(stringValue)) {
      parts.push(`${escapedKey}=${formatNumericOrBooleanField(stringValue, integerCompatible)}`);
    } else {
      parts.push(`${escapedKey}=${translateFieldValue(stringValue)}`);
    }
  }
  return parts.join(',');
}

function isNumericOrBoolean(value: string): boolean {
  return /^-?\d+$/.test(value) || /^-?\d+\.\d+$/.test(value) ||
  value === 'true' || value === 'false' || value === 'T' || value === 'F';
}

function formatNumericOrBooleanField(value: string, integerCompatible: boolean): string {
  if (/^-?\d+$/.test(value)) {
    return integerCompatible ? value : `${value}i`;
  }
  return value;
}

function translateMeasurement(value: string): string {
  return translateSpecialCharacters(' ', translateSpecialCharacters(',', value.replace(/\\/g, '')));
}

function translateTagKeyValue(value: string): string {
  let result = value.replace(/\n/g, ' ');
  result = result.replace(/\\/g, '');
  result = translateSpecialCharacters(',', result);
  result = translateSpecialCharacters('=', result);
  return translateSpecialCharacters(' ', result);
}

function translateTagKeyValueForJson(value: string): string {
  let result = value.replace(/\n/g, ' ');
  result = result.replace(/\r/g, ' ');
  result = result.replace(/\t/g, ' ');
  result = translateSpecialCharacters(',', result);
  result = translateSpecialCharacters('=', result);
  return translateSpecialCharacters(' ', result);
}

function translateFieldValue(value: string): string {
  let result = value.replace(/\\/g, '\\\\');
  result = translateSpecialCharacters('"', result);
  return `"${result}"`;
}

function cleanLineProtocolValue(value: string): string {
  if (!value) {
    return '';
  }
  if (value.startsWith('{') && value.endsWith('}')) {
    try {
      const parsed = JSON.parse(value) as Record<string, object>;
      if (parsed && typeof parsed === 'object' && parsed['value'] !== undefined) {
        let extractedValue = String(parsed['value']);
        if (extractedValue.startsWith('"') && extractedValue.endsWith('"')) {
          extractedValue = extractedValue.slice(1, -1);
        }
        return extractedValue;
      }
    } catch (_) {
    }
  } else if (value.startsWith('"') && value.endsWith('"')) {
    return value.slice(1, -1);
  }
  return value;
}

function translateSpecialCharacters(special: string, value: string): string {
  if (!special || !value) {
    return value;
  }
  let result = '';
  for (let i = 0; i < value.length; i++) {
    const current = value.charAt(i);
    result += current === special ? `\\${current}` : current;
  }
  return result;
}

function copyStringRecord(record: SDKStringRecord): SDKStringRecord {
  const copied: SDKStringRecord = {};
  if (!record) {
    return copied;
  }
  const keys = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    copied[key] = record[key];
  }
  return copied;
}

function copyActionPropertiesToFields(properties: Record<string, object>, fields: SDKStringRecord): void {
  const keys = Object.keys(properties);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    fields[key] = stringifyActionPropertyValue(properties[key]);
  }
}

/**
 * launch_cold properties are SDK-owned Field names. Reapply them after custom
 * and global-context mappings so a custom Action handler cannot lose or
 * override the launch type/phase data.
 */
function copyColdLaunchPropertiesToFields(properties: Record<string, object>, fields: SDKStringRecord): void {
  const coldLaunchKeys: string[] = [
    'app_launch_type',
    'app_pre_application_init_time',
    'app_application_init_time',
    'app_first_frame_init_time'
  ];
  for (let i = 0; i < coldLaunchKeys.length; i++) {
    const key = coldLaunchKeys[i];
    if (properties[key] !== undefined && properties[key] !== null) {
      fields[key] = stringifyActionPropertyValue(properties[key]);
    }
  }
}

function normalizeRumPropertyRecord(properties: SDKPropertyRecord): SDKStringRecord {
  const normalized: SDKStringRecord = {};
  if (!properties) {
    return normalized;
  }
  const keys = Object.keys(properties);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = properties[key];
    if (value !== null && value !== undefined) {
      normalized[key] = stringifyActionPropertyValue(value);
    }
  }
  return normalized;
}

function stringifyActionPropertyValue(value: object): string {
  let normalized = value;
  if (typeof normalized === 'object' && normalized !== null) {
    try {
      const wrapper = normalized as Record<string, object>;
      if (wrapper.value !== undefined) {
        normalized = wrapper.value;
      }
    } catch (_) {
    }
  }

  if (typeof normalized === 'string' || typeof normalized === 'number' || typeof normalized === 'boolean') {
    return String(normalized);
  }
  if (typeof normalized === 'object' && normalized !== null) {
    try {
      return JSON.stringify(normalized);
    } catch (_) {
      return String(normalized);
    }
  }
  return String(normalized);
}

function getOrCreateRumCounterDelta(
  state: SDKWorkerRuntimeState,
  viewId: string,
  actionId: string
): SDKRumCounterDeltaDTO {
  const key = `${viewId || 'none'}|${actionId || 'none'}`;
  let delta = state.rumCounterDeltas[key];
  if (!delta) {
    delta = createEmptyRumCounterDelta(viewId || '', actionId || '');
    state.rumCounterDeltas[key] = delta;
  }
  return delta;
}

function createEmptyRumCounterDelta(viewId: string, actionId: string): SDKRumCounterDeltaDTO {
  return {
    viewId,
    actionId,
    viewErrorDelta: 0,
    actionErrorDelta: 0,
    viewLongTaskDelta: 0,
    actionLongTaskDelta: 0,
    viewResourceDelta: 0,
    actionResourceDelta: 0,
    viewPendingDelta: 0,
    actionPendingDelta: 0,
    viewActionDelta: 0,
    viewUpdateTimeDelta: 0
  };
}

function getActiveResourceCount(state: SDKWorkerRuntimeState): number {
  return state.activeResources.size;
}
