/**
 * Internal worker message protocol for dedicated SDK pools.
 *
 * Worker payloads must stay serializable. Do not pass functions, SDK class
 * instances, Context/RdbStore objects, Promise, Error, Map, Set, or cyclic data.
 */

export type SDKWorkerPrimitive = string | number | boolean | null;
export type SDKWorkerPayload = SDKWorkerPrimitive | object;

export enum SDKDedicatedPoolType {
  EVENT_CONSUMER = 'event-consumer',
  LOG_CONSUMER = 'log-consumer',
  DATA_PROCESS = 'data-process',
  CRASH_FILE = 'crash-file',
  ANR = 'anr',
  BACKGROUND = 'background',
  DATA_UPLOAD = 'data-upload'
}

export interface SDKWorkerRequest {
  id: string;
  pool: SDKDedicatedPoolType;
  command: string;
  priority: number;
  createdAt: number;
  payload?: SDKWorkerPayload;
}

export interface SDKWorkerResponse {
  id: string;
  ok: boolean;
  payload?: SDKWorkerPayload;
  errorMessage?: string;
  metrics?: SDKWorkerTiming;
}

export interface SDKWorkerTiming {
  schedulerWaitMs?: number;
  schedulerComputeMs?: number;
  schedulerExecuteMs?: number;
  poolWaitMs?: number;
  poolExecuteMs?: number;
}

export enum SDKWorkerCommand {
  PING = 'sdk.ping',
  RESET = 'sdk.reset',
  EVENT_RUN = 'event.run',
  EVENT_RUM_COMMAND = 'event.rum.command',
  EVENT_RUM_COMPLETED_ACTION = 'event.rum.completedAction',
  EVENT_RUM_COUNTER_UPDATE = 'event.rum.counterUpdate',
  EVENT_RUM_COUNTER_FLUSH = 'event.rum.counterFlush',
  EVENT_RUM_SNAPSHOT = 'event.rum.snapshot',
  LOG_RUN = 'log.run',
  LOG_ENQUEUE = 'log.enqueue',
  LOG_FLUSH = 'log.flush',
  DATA_RUN = 'data.run',
  DATA_CREATE_LINE_PROTOCOL = 'data.createLineProtocol',
  DATA_PASS_THROUGH_DRAFTS = 'data.passThroughDrafts',
  DATA_PASS_THROUGH_RUM_COUNTER_DELTAS = 'data.passThroughRumCounterDeltas',
  CRASH_FILE_RUN = 'crashFile.run',
  ANR_RUN = 'anr.run',
  CUSTOM_RUN = 'custom.run',
  INNER_LOG_FILE_RUN = 'innerLogFile.run',
  DATA_PARSE_CRASH_TEXT = 'data.parseCrashText',
  UPLOAD_SCHEDULE = 'upload.schedule',
  UPLOAD_CONSUME = 'upload.consume',
  UPLOAD_ROUND_FINISH = 'upload.roundFinish',
  UPLOAD_FORMAT_BODY = 'upload.formatBody'
}

export interface SDKWorkerBridgeRequest {
  id: string;
  sourceRequestId: string;
  command: string;
  payload?: SDKWorkerPayload;
}

export interface SDKWorkerBridgeResponse {
  id: string;
  sourceRequestId: string;
  ok: boolean;
  payload?: SDKWorkerPayload;
  errorMessage?: string;
}

export interface SDKWorkerErrorDTO {
  name: string;
  message: string;
  stack: string;
}

export interface SDKWorkerErrorPayload {
  name: string;
  message: string;
  stack: string;
}

export type SDKStringRecord = Record<string, string>;
export type SDKNumberRecord = Record<string, number>;

export interface SDKLogDTO {
  measurement: string;
  content: string;
  status: string;
  time: number;
  timeNano: number;
  tags: SDKStringRecord;
  fields: SDKStringRecord;
}

export interface SDKRumEventDTO {
  eventType: string;
  name: string;
  time: number;
  dataType?: string;
  customDataType?: string;
  measurement?: string;
  uuid?: string;
  integerCompatible?: boolean;
  viewId?: string;
  viewName?: string;
  actionId?: string;
  actionName?: string;
  resourceId?: string;
  sessionId?: string;
  tags?: SDKStringRecord;
  fields?: SDKStringRecord;
}

export interface SDKRumCounterUpdateDTO {
  updateType: string;
  viewId?: string;
  actionId?: string;
  updateView?: boolean;
  flushMaxKeys?: number;
}

export interface SDKRumCompletedActionDTO {
  dataType: string;
  customDataType?: string;
  measurement: string;
  uuid: string;
  time: number;
  dynamicTags?: SDKStringRecord;
  actionId: string;
  actionName: string;
  actionType: string;
  sessionId: string;
  viewId: string;
  viewName: string;
  viewReferrer: string;
  duration: number;
  errorCount: number;
  longTaskCount: number;
  resourceCount: number;
  properties?: Record<string, object>;
}

export interface SDKLineProtocolRecordsDTO {
  records: SDKLineProtocolInputDTO[];
}

export interface SDKRumCounterDeltaDTO {
  viewId: string;
  actionId: string;
  viewErrorDelta: number;
  actionErrorDelta: number;
  viewLongTaskDelta: number;
  actionLongTaskDelta: number;
  viewResourceDelta: number;
  actionResourceDelta: number;
  viewPendingDelta: number;
  actionPendingDelta: number;
  viewActionDelta: number;
  viewUpdateTimeDelta: number;
}

export interface SDKRumCounterUpdateResultDTO {
  accepted: boolean;
  pendingCount: number;
  shouldFlush: boolean;
}

export interface SDKRumCounterFlushResultDTO {
  deltas: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck: boolean;
  needsRumDataGenerate: boolean;
}

export interface SDKLineProtocolInputDTO {
  dataType: string;
  measurement: string;
  tags: SDKStringRecord;
  fields: SDKStringRecord;
  time: number;
  uuid: string;
  customDataType?: string;
  integerCompatible?: boolean;
}

export interface SDKSyncDataDraftDTO {
  dataType: string;
  customDataType?: string;
  dataString: string;
  uuid: string;
  time: number;
}

export interface SDKCrashFileDTO {
  fileName: string;
  content: string;
  time: number;
  maxLength: number;
  dataType: string;
  measurement: string;
  tags: SDKStringRecord;
  fields: SDKStringRecord;
  uuid: string;
}

export interface SDKUploadRowDTO {
  id: number;
  dataType: string;
  dataString: string;
  uuid: string;
  time: number;
}

export interface SDKUploadPageDTO {
  dataType: string;
  rows: SDKUploadRowDTO[];
  packageId: string;
}

export interface SDKHttpRequestDTO {
  url: string;
  method: string;
  headers: SDKStringRecord;
  body: string;
  timeoutMs: number;
}

export function toSDKWorkerErrorDTO(error: object | string | number | boolean | null | undefined): SDKWorkerErrorDTO {
  if (error instanceof Error) {
    return {
      name: error.name || 'Error',
      message: error.message || String(error),
      stack: error.stack || ''
    };
  }

  return {
    name: 'Error',
    message: String(error),
    stack: ''
  };
}

export function toSDKWorkerErrorPayload(errorDTO: SDKWorkerErrorDTO): SDKWorkerErrorPayload {
  return {
    name: errorDTO.name,
    message: errorDTO.message,
    stack: errorDTO.stack
  };
}

export function assertSDKWorkerRequestSerializable(request: SDKWorkerRequest): void {
  assertSDKWorkerSerializable(request.payload === undefined ? null : request.payload, 'payload');
}

export function assertSDKWorkerSerializable(value: object | string | number | boolean | null | undefined, path: string = 'payload'): void {
  const visited: object[] = [];
  assertSerializableValue(value, path, visited);
}

function assertSerializableValue(
  value: object | string | number | boolean | null | undefined,
  path: string,
  visited: object[]
): void {
  if (value === null || value === undefined) {
    return;
  }

  const valueType = typeof value;
  if (valueType === 'string' || valueType === 'number' || valueType === 'boolean') {
    return;
  }

  if (valueType === 'function') {
    throw new Error(`${path} must be serializable: functions are not allowed`);
  }

  if (value instanceof Promise) {
    throw new Error(`${path} must be serializable: Promise is not allowed`);
  }

  if (value instanceof Error) {
    throw new Error(`${path} must be serializable: Error must be converted to SDKWorkerErrorDTO`);
  }

  if (value instanceof Map || value instanceof Set || value instanceof Date) {
    throw new Error(`${path} must be serializable: Map, Set, and Date are not allowed`);
  }

  const objectValue = value as object;
  if (visited.indexOf(objectValue) >= 0) {
    throw new Error(`${path} must be serializable: cyclic reference is not allowed`);
  }
  visited.push(objectValue);

  if (Array.isArray(objectValue)) {
    const arrayValue = objectValue as Array<object | string | number | boolean | null | undefined>;
    for (let i = 0; i < arrayValue.length; i++) {
      assertSerializableValue(arrayValue[i], `${path}[${i}]`, visited);
    }
    visited.pop();
    return;
  }

  const record = objectValue as Record<string, object | string | number | boolean | null | undefined>;
  const keys = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    assertSerializableValue(record[key], `${path}.${key}`, visited);
  }
  visited.pop();
}
