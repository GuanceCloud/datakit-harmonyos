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
  CRASH = 'crash',
  ANR = 'anr',
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

/**
 * Each EVENT_CONSUMER Worker starts with this many response credits. The Host
 * returns one credit only after it has finished the corresponding response,
 * bounding each Worker-owned Host response lane while the Worker keeps its own
 * FIFO backlog.
 */
export const SDK_EVENT_RESPONSE_SOFT_CREDITS = 5000;

export interface SDKWorkerTiming {
  schedulerWaitMs?: number;
  schedulerComputeMs?: number;
  schedulerExecuteMs?: number;
  poolWaitMs?: number;
  poolExecuteMs?: number;
}

export enum SDKTaskPriority {
  CRITICAL = 9,
  HIGH = 7,
  NORMAL = 5,
  LOW = 3,
  BACKGROUND = 1
}

export enum SDKWorkerCommand {
  PING = 'sdk.ping',
  RESET = 'sdk.reset',
  LINE_CONTEXT_UPDATE = 'line.context.update',
  EVENT_RUM_COMMAND = 'event.rum.command',
  EVENT_RUM_COMMAND_BATCH = 'event.rum.commandBatch',
  EVENT_RUM_ERROR_COMMAND_BATCH = 'event.rum.errorCommandBatch',
  EVENT_RUM_RESOURCE_COMMAND_BATCH = 'event.rum.resourceCommandBatch',
  EVENT_RUM_COMPLETED_ACTION = 'event.rum.completedAction',
  EVENT_RUM_COMPLETED_ACTION_BATCH = 'event.rum.completedActionBatch',
  EVENT_RUM_COUNTER_UPDATE = 'event.rum.counterUpdate',
  EVENT_RUM_COUNTER_UPDATE_BATCH = 'event.rum.counterUpdateBatch',
  EVENT_RUM_COUNTER_FLUSH = 'event.rum.counterFlush',
  EVENT_RUM_SNAPSHOT = 'event.rum.snapshot',
  /** Host -> EVENT_CONSUMER control message; it deliberately has no response. */
  EVENT_RUM_RESPONSE_CREDIT = 'event.rum.responseCredit',
  LOG_ENQUEUE = 'log.enqueue',
  LOG_FLUSH = 'log.flush',
  DATA_CREATE_LINE_PROTOCOL = 'data.createLineProtocol',
  DATA_PARSE_CRASH_TEXT = 'data.parseCrashText',
  ANR_PARSE_EVENT = 'anr.parseEvent',
  BACKGROUND_COLLECT_METRICS = 'background.collectMetrics',
  NATIVE_CRASH_LOG_APPEND = 'nativeCrashLog.append',
  UPLOAD_SCHEDULE = 'upload.schedule',
  UPLOAD_CONSUME = 'upload.consume',
  /** Allocate or recover one persisted upload package before HTTP is sent. */
  UPLOAD_PREPARE_PAGE = 'upload.preparePage',
  UPLOAD_EXECUTE_PAGE = 'upload.executePage',
  UPLOAD_COMMIT_PAGE = 'upload.commitPage',
  UPLOAD_CONSUME_FINISH = 'upload.consumeFinish',
  UPLOAD_ROUND_FINISH = 'upload.roundFinish',
  UPLOAD_FORMAT_BODY = 'upload.formatBody'
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
export type SDKPropertyRecord = Record<string, object>;

/** Transport metric provenance is retained across asynchronous Resource commands. */
export type SDKRumResourceMetricSource = 'header' | 'integration' | 'platform';

export interface SDKRumResourceTransportMetricsDTO {
  requestBodySize: number;
  requestBodySizeSource?: SDKRumResourceMetricSource;
  requestHeaderSize: number;
  requestHeaderSizeSource?: SDKRumResourceMetricSource;
  requestSize: number;
  requestSizeSource?: SDKRumResourceMetricSource;
  /** Preserves whether requestSize is a body/header calculation, not a direct measurement. */
  requestSizeIsDerived?: boolean;
  httpProtocol: string;
  httpProtocolSource?: SDKRumResourceMetricSource;
  connectionReuse?: boolean;
  connectionReuseSource?: SDKRumResourceMetricSource;
}

/**
 * A point-in-time view of the default network captured when a Resource starts.
 * Optional values deliberately remain absent when HarmonyOS cannot provide a
 * trustworthy value; callers must never substitute a synthetic zero.
 */
export interface SDKRumResourceNetworkSnapshotDTO {
  available: boolean;
  validated?: boolean;
  downlinkKbps?: number;
  uplinkKbps?: number;
  signalStrength?: number;
}

export interface SDKLogDTO {
  measurement: string;
  content: string;
  status: string;
  time: number;
  timeNano: number;
  tags: SDKStringRecord;
  fields: SDKStringRecord;
  isSilence?: boolean;
}

/** A bounded, best-effort diagnostic record written by the native crash worker. */
export interface SDKNativeCrashLogDTO {
  level: string;
  tag: string;
  message: string;
}

export interface SDKNativeCrashLogBatchDTO {
  logs: SDKNativeCrashLogDTO[];
}

export interface SDKLineProtocolContextDTO {
  basePublicTags: SDKStringRecord;
  logTags: SDKStringRecord;
  rumTags: SDKStringRecord;
  dynamicBaseTags: SDKStringRecord;
  dynamicLogTags: SDKStringRecord;
  dynamicRumTags: SDKStringRecord;
  rumStaticFields: SDKStringRecord;
  logLinkRumData: boolean;
  integerCompatible: boolean;
}

export interface SDKRumEventDTO {
  /** Optional raw hints. EVENT_CONSUMER derives the canonical values. */
  eventType?: string;
  name?: string;
  time: number;
  /** Cache-row time; the Line Protocol timestamp remains `time`. */
  storageTime?: number;
  dataType?: string;
  customDataType?: string;
  measurement?: string;
  uuid?: string;
  integerCompatible?: boolean;
  lineContext?: SDKLineProtocolContextDTO;
  lineProtocolPrepared?: boolean;
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
  /** Number of coalesced counter changes represented by this update. */
  count?: number;
}

export interface SDKRumCounterUpdateBatchDTO {
  updates: SDKRumCounterUpdateDTO[];
}

export interface SDKRumEventBatchDTO {
  events: SDKRumEventDTO[];
}

export interface SDKWorkerResponseCreditDTO {
  credits: number;
}

export interface SDKRumResourceContextDTO {
  /** User and network attributes captured with the initiating event. */
  dynamicTags?: SDKStringRecord;
  /** Immutable default-network snapshot captured by startResource. */
  networkSnapshot?: SDKRumResourceNetworkSnapshotDTO;
  sessionId: string;
  viewId: string;
  viewName: string;
  viewReferrer: string;
  actionId: string;
  actionName: string;
  /** Host-side fallback for semantic events when the Worker line context is unavailable. */
  rumAppId?: string;
}

export interface SDKRumResourceParamsDTO {
  url: string;
  requestHeader: string;
  responseHeader: string;
  responseConnection: string;
  responseContentType: string;
  responseContentEncoding: string;
  responseContentLength: number;
  resourceMethod: string;
  responseBody: string;
  resourceStatus: number;
  resourceType: string;
  requestErrorStack: string;
  requestErrorMsg: string;
  /** Suppresses only the local network_error derived from a status-0 Resource. */
  suppressNetworkError?: boolean;
  transportMetrics?: SDKRumResourceTransportMetricsDTO;
  property: SDKPropertyRecord;
  traceId?: string;
  spanId?: string;
}

export interface SDKRumResourceNetStatusDTO {
  dnsTime: number;
  dnsStartTime: number;
  tcpTime: number;
  tcpStartTime: number;
  sslTime: number;
  sslStartTime: number;
  ttfbTime: number;
  responseTime: number;
  firstByteTime: number;
  firstByteStartTime: number;
  downloadTime: number;
  downloadStartTime: number;
  holeRequestTime: number;
  resourceHostIP: string;
  transportMetrics?: SDKRumResourceTransportMetricsDTO;
}

export interface SDKRumResourceCommandDTO {
  commandType: string;
  resourceId: string;
  /** Stable Host-generated IDs keep Resource replay idempotent across restarts. */
  draftUuid?: string;
  errorDraftUuid?: string;
  context?: SDKRumResourceContextDTO;
  params?: SDKRumResourceParamsDTO;
  netStatus?: SDKRumResourceNetStatusDTO;
  /** Custom properties supplied at the Resource lifecycle boundary. */
  property?: SDKPropertyRecord;
  startTime?: number;
  endTime?: number;
  eventTime?: number;
  fallbackActionId?: string;
  /** The Host has already accepted stopResource; do not let addResource finalize ahead of that command. */
  awaitStopCommand?: boolean;
  shouldCollect?: boolean;
  customDataType?: string;
  counterFlushMaxEvents?: number;
}

export interface SDKRumResourceCommandBatchDTO {
  commands: SDKRumResourceCommandDTO[];
  /** Host snapshot keeps completed resources tagged if the EventConsumer was restarted. */
  lineContext?: SDKLineProtocolContextDTO;
  /** Rebuilds volatile Resource state after restart without reapplying committed Counter deltas. */
  stateRecoveryOnly?: boolean;
}

export interface SDKRumErrorCommandDTO {
  /** Stable Host-generated ID keeps Error replay idempotent across restarts. */
  uuid?: string;
  context: SDKRumResourceContextDTO;
  log: string;
  message: string;
  errorType: string;
  errorSource: string;
  appState: string;
  property: SDKPropertyRecord;
  /** Error-only device tags captured on the host before the command reaches the Worker. */
  deviceTags?: SDKStringRecord;
  time: number;
  customDataType?: string;
  counterFlushMaxEvents?: number;
}

export interface SDKRumErrorCommandBatchDTO {
  commands: SDKRumErrorCommandDTO[];
  /** Host snapshot keeps errors tagged if the EventConsumer was restarted. */
  lineContext?: SDKLineProtocolContextDTO;
}

export interface SDKRumCompletedActionDTO {
  /** Base Line Protocol category; the local queue uses customDataType when set. */
  dataType: string;
  /** Error-sampled sessions stage here until an error opens the upload window. */
  customDataType?: string;
  /** False for sessions rejected by both normal and error sampling. */
  shouldCollect?: boolean;
  measurement: string;
  uuid: string;
  time: number;
  dynamicTags?: SDKStringRecord;
  actionId: string;
  actionName: string;
  actionType: string;
  /** Host-side fallback for semantic events when the Worker line context is unavailable. */
  rumAppId?: string;
  sessionId: string;
  viewId: string;
  viewName: string;
  viewReferrer: string;
  duration: number;
  hasReplay?: boolean;
  errorCount: number;
  longTaskCount: number;
  resourceCount: number;
  properties?: Record<string, object>;
  countViewAction?: boolean;
  counterFlushMaxEvents?: number;
}

export interface SDKRumCompletedActionBatchDTO {
  actions: SDKRumCompletedActionDTO[];
  /** Host snapshot keeps completed actions tagged if the EventConsumer was restarted. */
  lineContext?: SDKLineProtocolContextDTO;
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
  deltas?: SDKRumCounterDeltaDTO[];
  needsActionCloseCheck?: boolean;
  needsRumDataGenerate?: boolean;
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

export interface SDKANRParseRequestDTO {
  eventName: string;
  params: Object;
  dateline: number;
  /** Internal test seam. Production requests use the Worker defaults. */
  systemLogDirs?: string[];
  maxFileBytes?: number;
  maxFilesPerDirectory?: number;
  maxExternalFiles?: number;
  maxOutputLength?: number;
}

export interface SDKANRParseResultDTO {
  stackTrace: string;
  message: string;
  dateline: number;
  foreground: boolean;
  freezeType: string;
  properties: SDKStringRecord;
  missingStack: boolean;
  filesRead: number;
  truncatedFiles: number;
}

export interface SDKBackgroundMetricsRequestDTO {
  collectCpu: boolean;
  collectMemory: boolean;
  collectBattery: boolean;
  cpuCacheMs: number;
  memoryCacheMs: number;
}

export interface SDKBackgroundMetricsResultDTO {
  cpuTickCount: number;
  /** Resident memory in bytes, matching Android's VmRSS * 1000 contract. */
  memoryUsageBytes: number;
  batteryCurrent: number;
  hasBatteryCurrent: boolean;
  collectedAt: number;
  cpuFromCache: boolean;
  memoryFromCache: boolean;
}

export interface SDKUploadRowDTO {
  id: number;
  dataType: string;
  dataString: string;
  uuid: string;
  time: number;
  customDataType?: string;
}

export interface SDKUploadPageDTO {
  dataType: string;
  rows: SDKUploadRowDTO[];
  packageId: string;
}

export enum SDKUploadPageOutcome {
  EMPTY_BODY = 'empty-body',
  HTTP = 'http'
}

export enum SDKUploadDbActionDTO {
  NONE = 'none',
  DELETE = 'delete',
  REINSERT = 'reinsert'
}

export interface SDKUploadRoundStartDTO {
  ownerId: string;
  taskName: string;
  pageSize: number;
  syncSleepTime: number;
  maxRetryCount?: number;
  checkpoint?: SDKUploadCheckpointDTO;
}

export interface SDKUploadRoundStartResultDTO {
  accepted: boolean;
  roundId: string;
  pageSize: number;
  syncSleepTime: number;
  maxRetryCount: number;
  checkpoint: SDKUploadCheckpointDTO;
}

export interface SDKUploadCheckpointDTO {
  ownerId: string;
  version: number;
  rumSequence: number;
  logSequence: number;
  processId: number;
  errorCounts: SDKNumberRecord;
  ignoredErrorCounts: SDKNumberRecord;
}

export interface SDKUploadHttpConfigDTO {
  datakitUrl: string;
  datawayUrl: string;
  clientToken: string;
  model: string;
  deviceTimeMs: number;
  connectTimeoutMs: number;
  readTimeoutMs: number;
  softTimeoutMs: number;
  /** Whether the body should be compressed before the HTTP request is sent. */
  compressIntakeRequests: boolean;
  /** Optional per-request NetworkKit proxy configuration. */
  proxy?: SDKUploadHttpProxyDTO;
  /** Optional NetworkKit custom DNS servers, capped to three values by FTSDKConfig. */
  dnsServers?: string[];
  /** Optional NetworkKit DNS-over-HTTPS endpoint. */
  dnsOverHttps?: string;
}

export interface SDKUploadHttpProxyDTO {
  host: string;
  port: number;
  exclusionList: string[];
  username?: string;
  password?: string;
}

export interface SDKUploadHttpRequestDTO extends SDKUploadHttpConfigDTO {
  body: string;
  packageId: string;
  /** Set only when deflate compression completed successfully. */
  compressedBody?: ArrayBuffer;
  /** Set only when the matching Content-Encoding header must be sent. */
  contentEncoding?: string;
}

export interface SDKUploadHttpResultDTO {
  code: number;
  message: string;
  errorCode: string;
  elapsedMs: number;
  softTimedOut: boolean;
}

/**
 * Worker-only preparation request. The Host atomically persists `rows` before
 * forwarding the same package to UPLOAD_EXECUTE_PAGE.
 */
export interface SDKUploadPreparePageDTO {
  roundId: string;
  dataType: string;
  rows: SDKUploadRowDTO[];
  /** More rows remain in DB or were deferred by the Host transport byte cap. */
  queryHasMore?: boolean;
  transportLimitReached?: boolean;
}

export interface SDKUploadPreparePageResultDTO {
  roundId: string;
  dataType: string;
  /** Rows as read from DB; use these as the atomic replacement target. */
  sourceRows: SDKUploadRowDTO[];
  /** Rows with the selected package ID persisted in sdk_data_id. */
  rows: SDKUploadRowDTO[];
  /** True only when the Host must atomically replace raw cached rows before HTTP. */
  needsPersistence: boolean;
  queriedRows: number;
  acceptedRows: number;
  duplicateRows: number;
  deferredRows: number;
  packageId: string;
  bodyLength: number;
  bodyBytes: number;
  bodyLimitReached: boolean;
  transportLimitReached: boolean;
  bodyPreview: string;
  /** False only when no acceptable row can be sent in this round. */
  shouldExecute: boolean;
  roundHasMoreData: boolean;
  computeMs: number;
}

export interface SDKUploadExecutePageDTO {
  roundId: string;
  dataType: string;
  rows: SDKUploadRowDTO[];
  /**
   * The package selected by UPLOAD_PREPARE_PAGE. Upload retries must reuse
   * this value instead of allocating another package.
   */
  packageId?: string;
  /** The Host atomically stored the package-prefixed sdk_data_id before HTTP. */
  sdkDataIdPersisted?: boolean;
  /** More rows remain in DB or were deferred by the Host transport byte cap. */
  queryHasMore?: boolean;
  transportLimitReached?: boolean;
  httpConfig: SDKUploadHttpConfigDTO;
  /** Optional one-shot result supplied only by an injected test runtime. */
  injectedHttpResult?: SDKUploadHttpResultDTO;
}

export interface SDKUploadExecutePageResultDTO {
  roundId: string;
  attemptId: string;
  dataType: string;
  rows: SDKUploadRowDTO[];
  queriedRows: number;
  acceptedRows: number;
  duplicateRows: number;
  deferredRows: number;
  packageId: string;
  bodyLength: number;
  bodyBytes: number;
  bodyLimitReached: boolean;
  transportLimitReached: boolean;
  bodyPreview: string;
  shouldUpload: boolean;
  outcome: SDKUploadPageOutcome;
  httpResult: SDKUploadHttpResultDTO;
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
  errorCount: number;
  computeMs: number;
  checkpointAfterCommit: SDKUploadCheckpointDTO;
}

export interface SDKUploadCommitPageDTO {
  roundId: string;
  attemptId: string;
  dbSucceeded: boolean;
}

export interface SDKUploadCommitPageResultDTO {
  roundId: string;
  dataType: string;
  delayMs: number;
  shouldContinueDataType: boolean;
  roundHasMoreData: boolean;
  errorCount: number;
  consumedRows: number;
  checkpoint: SDKUploadCheckpointDTO;
}

export interface SDKUploadRoundFinishDTO {
  roundId: string;
}

export interface SDKUploadRoundResultDTO {
  roundId: string;
  consumedRows: number;
  hasMoreData: boolean;
  errorCount: number;
  computeMs: number;
  checkpoint: SDKUploadCheckpointDTO;
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
