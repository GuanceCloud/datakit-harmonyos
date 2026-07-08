import {
  SDKCrashFileDTO,
  SDKDedicatedPoolType,
  SDKLineProtocolRecordsDTO,
  SDKLineProtocolInputDTO,
  SDKLogDTO,
  SDKRumCompletedActionDTO,
  SDKRumCounterDeltaDTO,
  SDKRumCounterFlushResultDTO,
  SDKRumCounterUpdateDTO,
  SDKRumCounterUpdateResultDTO,
  SDKRumEventDTO,
  SDKStringRecord,
  SDKSyncDataDraftDTO,
  SDKUploadPageDTO,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from './SDKWorkerProtocol';
import { Constants } from '../Constants';

const DEFAULT_BATCH_SIZE = 20;
const LOG_PROCESS_COALESCE_DELAY_MS = 100;

export interface SDKWorkerRuntimeState {
  pool: SDKDedicatedPoolType;
  workerName: string;
  backend: string;
  eventSequence: number;
  activeViewId: string;
  activeViewName: string;
  activeActionId: string;
  activeActionName: string;
  activeResources: SDKStringRecord;
  rumCounterDeltas: Record<string, SDKRumCounterDeltaDTO>;
  rumCounterNeedsActionCloseCheck: boolean;
  rumCounterNeedsRumDataGenerate: boolean;
  logQueue: SDKLogDTO[];
  logBatchBuffer: SDKLogDTO[];
  uploadIsScheduled: boolean;
  uploadNeedReschedule: boolean;
  uploadScheduledDelay: number;
  uploadScheduledAt: number;
  uploadRunningTaskId: string;
  uploadRoundSequence: number;
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
}

interface SDKLogEnqueuePayload {
  logs: SDKLogDTO[];
  forceFlush?: boolean;
}

interface SDKLogDrainResultPayload {
  batches: SDKLogDTO[][];
  queueSize: number;
  bufferSize: number;
  coalesceDelayMs: number;
  batchSize: number;
}

interface SDKLineProtocolRecordsPayload {
  records: SDKLineProtocolInputDTO[];
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

export function createSDKWorkerRuntimeState(pool: SDKDedicatedPoolType, workerName: string): SDKWorkerRuntimeState {
  return createSDKWorkerRuntimeStateWithBackend(pool, workerName, 'inline');
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
    activeResources: {},
    rumCounterDeltas: {},
    rumCounterNeedsActionCloseCheck: false,
    rumCounterNeedsRumDataGenerate: false,
    logQueue: [],
    logBatchBuffer: [],
    uploadIsScheduled: false,
    uploadNeedReschedule: false,
    uploadScheduledDelay: 0,
    uploadScheduledAt: 0,
    uploadRunningTaskId: '',
    uploadRoundSequence: 0
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
    case SDKWorkerCommand.EVENT_RUM_COMMAND:
      return handleRumCommand(request.payload as SDKRumEventDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION:
      return handleRumCompletedAction(request.payload as SDKRumCompletedActionDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE:
      return handleRumCounterUpdate(request.payload as SDKRumCounterUpdateDTO, state);
    case SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH:
      return handleRumCounterFlush(state);
    case SDKWorkerCommand.EVENT_RUM_SNAPSHOT:
      return getStateSnapshot(state);
    case SDKWorkerCommand.LOG_ENQUEUE:
      return handleLogEnqueue(request.payload as SDKLogEnqueuePayload, state);
    case SDKWorkerCommand.LOG_FLUSH:
      return handleLogFlush(state, true);
    case SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL:
      return handleCreateLineProtocol(request.payload as SDKLineProtocolRecordsPayload);
    case SDKWorkerCommand.DATA_PASS_THROUGH_DRAFTS:
      if (request.payload) {
        return request.payload;
      }
      const emptyDrafts: SDKLineProtocolDraftsPayload = {
        drafts: []
      };
      return emptyDrafts as Object as SDKWorkerPayload;
    case SDKWorkerCommand.DATA_PASS_THROUGH_RUM_COUNTER_DELTAS:
      if (request.payload) {
        return request.payload;
      }
      const emptyCounterDeltas: SDKRumCounterFlushResultDTO = {
        deltas: [],
        needsActionCloseCheck: false,
        needsRumDataGenerate: false
      };
      return emptyCounterDeltas as Object as SDKWorkerPayload;
    case SDKWorkerCommand.DATA_PARSE_CRASH_TEXT:
      return handleParseCrashText(request.payload as SDKCrashFileDTO);
    case SDKWorkerCommand.UPLOAD_SCHEDULE:
      return handleUploadSchedule(request.payload as SDKUploadSchedulePayload, state);
    case SDKWorkerCommand.UPLOAD_ROUND_FINISH:
      return handleUploadRoundFinish(state);
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
  state.activeResources = {};
  state.rumCounterDeltas = {};
  state.rumCounterNeedsActionCloseCheck = false;
  state.rumCounterNeedsRumDataGenerate = false;
  state.logQueue = [];
  state.logBatchBuffer = [];
  state.uploadIsScheduled = false;
  state.uploadNeedReschedule = false;
  state.uploadScheduledDelay = 0;
  state.uploadScheduledAt = 0;
  state.uploadRunningTaskId = '';
  state.uploadRoundSequence = 0;
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
  if (!event) {
    throw new Error('RUM event payload is required');
  }

  state.eventSequence++;
  const eventType = event.eventType || '';
  if (eventType === 'view.start' || eventType === 'view.init') {
    state.activeViewId = event.viewId || '';
    state.activeViewName = event.viewName || event.name || '';
  } else if (eventType === 'view.stop') {
    state.activeViewId = '';
    state.activeViewName = '';
  } else if (eventType === 'action.start' || eventType === 'action.add') {
    state.activeActionId = event.actionId || '';
    state.activeActionName = event.actionName || event.name || '';
  } else if (eventType === 'action.complete') {
    // Completed actions are one-shot RUM events and must not become the active action.
  } else if (eventType === 'action.stop' || eventType === 'action.close') {
    state.activeActionId = '';
    state.activeActionName = '';
  } else if (eventType === 'resource.start' && event.resourceId) {
      state.activeResources[event.resourceId] = event.name || event.resourceId;
  } else if ((eventType === 'resource.stop' || eventType === 'resource.complete') && event.resourceId) {
    state.activeResources[event.resourceId] = '';
  }

  const syncDrafts: SDKSyncDataDraftDTO[] = [];
  if (event.measurement && event.uuid) {
    syncDrafts.push({
      dataType: event.dataType || '',
      customDataType: event.customDataType,
      dataString: buildLineProtocol(
        event.measurement,
        event.tags || {},
        event.fields || {},
        event.time,
        event.integerCompatible === true
      ),
      uuid: event.uuid,
      time: event.time
    });
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
  return payload as Object as SDKWorkerPayload;
}

function handleRumCompletedAction(
  action: SDKRumCompletedActionDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  if (!action) {
    throw new Error('RUM completed action payload is required');
  }

  state.eventSequence++;
  const tags = copyStringRecord(action.dynamicTags || {});
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
  fields[Constants.KEY_RUM_ACTION_DURATION] = String(action.duration || 0);
  fields[Constants.KEY_RUM_ACTION_ERROR_COUNT] = String(action.errorCount || 0);
  fields[Constants.KEY_RUM_ACTION_LONG_TASK_COUNT] = String(action.longTaskCount || 0);
  fields[Constants.KEY_RUM_ACTION_RESOURCE_COUNT] = String(action.resourceCount || 0);
  copyActionPropertiesToFields(action.properties || {}, fields);

  const records: SDKLineProtocolInputDTO[] = [{
    dataType: action.dataType || '',
    customDataType: action.customDataType,
    measurement: action.measurement || Constants.FT_MEASUREMENT_RUM_ACTION,
    tags,
    fields,
    time: action.time || 0,
    uuid: action.uuid || ''
  }];
  const payload: SDKLineProtocolRecordsDTO = {
    records
  };
  return payload as Object as SDKWorkerPayload;
}

function handleRumCounterUpdate(
  update: SDKRumCounterUpdateDTO,
  state: SDKWorkerRuntimeState
): SDKWorkerPayload {
  if (!update) {
    throw new Error('RUM counter update payload is required');
  }

  const updateType = update.updateType || '';
  const viewId = update.viewId || '';
  const actionId = update.actionId || '';
  const updateView = update.updateView !== false;
  if (updateType === 'view.action') {
    const delta = getOrCreateRumCounterDelta(state, viewId, '');
    delta.viewActionDelta += viewId.length > 0 ? 1 : 0;
  } else if (updateType === 'rum.error') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewErrorDelta += viewId.length > 0 ? 1 : 0;
    delta.actionErrorDelta += actionId.length > 0 ? 1 : 0;
    state.rumCounterNeedsActionCloseCheck = true;
  } else if (updateType === 'resource.complete') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    if (viewId.length > 0) {
      delta.viewResourceDelta += 1;
      delta.viewPendingDelta -= 1;
      delta.viewUpdateTimeDelta += 1;
    }
    if (actionId.length > 0) {
      delta.actionResourceDelta += 1;
      delta.actionPendingDelta -= 1;
    }
    state.rumCounterNeedsActionCloseCheck = true;
  } else if (updateType === 'resource.pending.increase') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewPendingDelta += viewId.length > 0 ? 1 : 0;
    delta.actionPendingDelta += actionId.length > 0 ? 1 : 0;
  } else if (updateType === 'resource.pending.decrease') {
    const delta = getOrCreateRumCounterDelta(state, viewId, actionId);
    delta.viewPendingDelta -= updateView && viewId.length > 0 ? 1 : 0;
    delta.actionPendingDelta -= actionId.length > 0 ? 1 : 0;
  } else if (updateType === 'long_task.view') {
    const delta = getOrCreateRumCounterDelta(state, viewId, '');
    if (viewId.length > 0) {
      delta.viewLongTaskDelta += 1;
      delta.viewUpdateTimeDelta += 1;
    }
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterNeedsRumDataGenerate = true;
  } else if (updateType === 'long_task.action') {
    const delta = getOrCreateRumCounterDelta(state, '', actionId);
    delta.actionLongTaskDelta += actionId.length > 0 ? 1 : 0;
    state.rumCounterNeedsActionCloseCheck = true;
    state.rumCounterNeedsRumDataGenerate = true;
  } else {
    throw new Error(`Unsupported RUM counter update type: ${updateType}`);
  }

  const pendingCount = getRumCounterPendingCount(state);
  const flushMaxKeys = update.flushMaxKeys && update.flushMaxKeys > 0 ? update.flushMaxKeys : 256;
  const payload: SDKRumCounterUpdateResultDTO = {
    accepted: true,
    pendingCount,
    shouldFlush: pendingCount >= flushMaxKeys
  };
  return payload as Object as SDKWorkerPayload;
}

function handleRumCounterFlush(state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const deltas: SDKRumCounterDeltaDTO[] = [];
  const keys = Object.keys(state.rumCounterDeltas);
  for (let i = 0; i < keys.length; i++) {
    const delta = state.rumCounterDeltas[keys[i]];
    if (delta) {
      deltas.push(delta);
    }
  }

  const payload: SDKRumCounterFlushResultDTO = {
    deltas,
    needsActionCloseCheck: state.rumCounterNeedsActionCloseCheck,
    needsRumDataGenerate: state.rumCounterNeedsRumDataGenerate
  };

  state.rumCounterDeltas = {};
  state.rumCounterNeedsActionCloseCheck = false;
  state.rumCounterNeedsRumDataGenerate = false;
  return payload as Object as SDKWorkerPayload;
}

function handleLogEnqueue(payload: SDKLogEnqueuePayload, state: SDKWorkerRuntimeState): SDKWorkerPayload {
  const logs = payload && payload.logs ? payload.logs : [];
  const forceFlush = payload && payload.forceFlush === true;
  for (let i = 0; i < logs.length; i++) {
    state.logQueue.push(logs[i]);
  }
  return drainLogQueue(state, forceFlush);
}

function handleLogFlush(state: SDKWorkerRuntimeState, forceFlush: boolean): SDKWorkerPayload {
  return drainLogQueue(state, forceFlush);
}

function drainLogQueue(state: SDKWorkerRuntimeState, forceFlush: boolean): SDKWorkerPayload {
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

  const payload: SDKLogDrainResultPayload = {
    batches,
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

function handleUploadRoundFinish(state: SDKWorkerRuntimeState): SDKWorkerPayload {
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

function handleUploadFormatBody(payload: SDKUploadPageDTO): SDKWorkerPayload {
  if (!payload || !payload.rows) {
    throw new Error('Upload page payload is required');
  }
  const lines: string[] = [];
  const ids: number[] = [];
  const seen: SDKStringRecord = {};
  for (let i = 0; i < payload.rows.length; i++) {
    const row = payload.rows[i];
    if (!row || !row.dataString || seen[row.uuid]) {
      continue;
    }
    seen[row.uuid] = '1';
    ids.push(row.id);
    lines.push(applyPackageId(row.dataString, row.uuid, payload.packageId));
  }
  const resultPayload: SDKUploadFormatBodyPayload = {
    body: lines.join('\n'),
    rowIds: ids,
    acceptedRows: lines.length,
    dataType: payload.dataType
  };
  return resultPayload as Object as SDKWorkerPayload;
}

function applyPackageId(dataString: string, uuid: string, packageId: string): string {
  if (!dataString || !uuid || !packageId) {
    return dataString || '';
  }
  return dataString.replace(uuid, `${packageId}.${uuid}`);
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
    delta = {
      viewId: viewId || '',
      actionId: actionId || '',
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
    state.rumCounterDeltas[key] = delta;
  }
  return delta;
}

function getRumCounterPendingCount(state: SDKWorkerRuntimeState): number {
  return Object.keys(state.rumCounterDeltas).length;
}

function getActiveResourceCount(state: SDKWorkerRuntimeState): number {
  let count = 0;
  const keys = Object.keys(state.activeResources);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (state.activeResources[key].length > 0) {
      count++;
    }
  }
  return count;
}
