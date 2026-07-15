import { Context } from '@kit.AbilityKit';
import relationalStore from '@ohos.data.relationalStore';
import { Constants } from '../Constants';
import { DBCacheDiscard, DataType } from '../enum/Enums';
import { FTDBConfig } from './FTDBConfig';
import * as FTSQL from './FTSQL';
import { SyncDataJSON } from './bean/SyncData';
import { ActionBeanJSON } from './bean/ActionBean';
import { ViewBeanJSON } from './bean/ViewBean';
import { SDKUploadRowDTO } from '../thread/SDKWorkerProtocol';

const DELETE_BATCH_CHUNK_SIZE: number = 500;
const TRANSACTION_LIMIT_COUNT: number = 10;
const ERROR_SAMPLED_SUFFIX: string = "_error_sampled";

enum FTDBTaskPoolCommand {
  INIT = 'init',
  HAS_SYNC_DATA = 'hasSyncData',
  QUERY_SYNC_DATA = 'querySyncData',
  QUERY_UPLOAD_DATA = 'queryUploadData',
  WRITE_SYNC_DATA = 'writeSyncData',
  WRITE_SYNC_DRAFTS = 'writeSyncDrafts',
  DELETE_SYNC_ROWS = 'deleteSyncRows',
  DELETE_SYNC_ROW_IDS = 'deleteSyncRowIds',
  QUERY_TOTAL_COUNT = 'queryTotalCount',
  GET_DB_SIZE = 'getDbSize',
  GET_LAST_ERROR_TIMELINE = 'getLastErrorTimeLine',
  UPDATE_LAST_ERROR_TIMELINE = 'updateLastErrorTimeLine',
  DELETE_OLDEST_SYNC_DATA = 'deleteOldestSyncData',
  UPDATE_DATA_TYPE = 'updateDataType',
  DELETE_EXPIRE_CACHE = 'deleteExpireCache',
  ERROR_SAMPLED_MAINTENANCE = 'errorSampledMaintenance',
  UPLOAD_COMMIT = 'uploadCommit',
  DELETE_ALL = 'deleteAll',
  CLEANUP_EXPIRED_RUM_VIEW = 'cleanupExpiredRumView',
  CLEANUP_EXPIRED_RUM_ACTION = 'cleanupExpiredRumAction',
  UPSERT_RUM_VIEW = 'upsertRumView',
  UPDATE_RUM_VIEW = 'updateRumView',
  CLOSE_RUM_VIEW = 'closeRumView',
  UPDATE_VIEW_UPLOAD_TIME = 'updateViewUploadTime',
  INCREASE_VIEW_ACTION = 'increaseViewAction',
  GET_RUM_PENDING_RESOURCE = 'getRumPendingResource',
  FORCE_CLEAR_RUM_PENDING_RESOURCE = 'forceClearRumPendingResource',
  GET_ACTION_INFO = 'getActionInfo',
  APPLY_RUM_COUNTER_DELTAS = 'applyRumCounterDeltas',
  UPDATE_VIEW_UPDATE_TIME = 'updateViewUpdateTime',
  INSERT_RUM_ACTION = 'insertRumAction',
  CLOSE_RUM_ACTION = 'closeRumAction',
  QUERY_SUM_ACTION = 'querySumAction',
  GET_ACTION_COUNTS = 'getActionCounts',
  QUERY_SUM_VIEW = 'querySumView',
  QUERY_RUM_VIEW_BY_ID = 'queryRumViewById',
  CLEAN_CLOSE_ACTION_DATA = 'cleanCloseActionData',
  CLEAN_CLOSE_VIEW_DATA = 'cleanCloseViewData',
  CLOSE_ALL_ACTION_AND_VIEW = 'closeAllActionAndView',
  QUERY_RELATED_UUIDS_BY_ACTION_ID = 'queryRelatedUUIDsByActionId'
}

export interface FTDBTaskPoolCachePolicySnapshot {
  enableLimitWithDbSize: boolean;
  dbLimitSize: number;
  dbCacheDiscard: string;
  logLimitCount: number;
  rumLimitCount: number;
  logDiscardStrategy: string;
  rumDiscardStrategy: string;
}

export interface FTDBTaskPoolWriteOptions {
  applyCachePolicy: boolean;
  reInsert: boolean;
  forceTransaction: boolean;
  updateOrInsertByUuid: boolean;
  /** Persisted with this write's transaction when the batch contains RUM errors. */
  lastErrorTimeLine?: number;
}

export interface FTDBTaskPoolWriteResult {
  success: boolean;
  source: string;
  requested: number;
  inserted: number;
  updated: number;
  dropped: number;
  duplicateSkipped: number;
  deletedOld: number;
  errorMessage: string;
}

export interface FTDBTaskPoolSyncDraftDTO {
  dataType: string;
  customDataType?: string;
  dataString: string;
  uuid: string;
  time: number;
}

export interface FTDBTaskPoolWriteResponse {
  result: FTDBTaskPoolWriteResult;
  logCountDelta: number;
  rumCountDelta: number;
  currentDbSize: number;
  dbLaneWaitMs: number;
  computeMs: number;
  executeMs: number;
  insertMs: number;
  sizeCheckMs: number;
  cleanupMs: number;
}

export interface FTDBTaskPoolUploadCommitResponse {
  deletedRows: number;
  insertedRows: number;
  affectedRows: number;
  logCountDelta: number;
  rumCountDelta: number;
  dbLaneWaitMs: number;
}

export interface FTDBTaskPoolMaintenanceResponse {
  updatedRows: number;
  deletedRows: number;
  dbLaneWaitMs: number;
}

export interface FTDBTaskPoolRumCounterDeltaDTO {
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

export interface FTDBTaskPoolActionInfoDTO {
  startTime: number;
}

export interface FTDBTaskPoolActionCountsDTO {
  errorCount: number;
  longTaskCount: number;
  resourceCount: number;
}

export interface FTDBTaskPoolCloseActionResponse {
  wasClosed: boolean;
  hadPendingResource: boolean;
}

interface FTDBTaskPoolRequest {
  command: string;
  source?: string;
  dataTypes?: string[];
  limit?: number;
  maxBytes?: number;
  newestFirst?: boolean;
  records?: SyncDataJSON[];
  options?: FTDBTaskPoolWriteOptions;
  policy?: FTDBTaskPoolCachePolicySnapshot;
  rowIds?: number[];
  drafts?: FTDBTaskPoolSyncDraftDTO[];
  fallbackDataType?: string;
  dataType?: string;
  commitAction?: string;
  reInsertRecords?: SyncDataJSON[];
  reduceCount?: number;
  errorTimeLine?: number;
  now?: number;
  duration?: number;
  cutoffTime?: number;
  view?: ViewBeanJSON;
  actionBean?: ActionBeanJSON;
  viewId?: string;
  actionId?: string;
  loadTime?: number;
  timeSpent?: number;
  attr?: string;
  newSessionId?: string;
  dateTime?: number;
  force?: boolean;
  target?: string;
  ids?: string[];
  counterDeltas?: FTDBTaskPoolRumCounterDeltaDTO[];
  measurementType?: string;
}

interface FTDBTaskPoolResponse {
  ok: boolean;
  value?: boolean;
  count?: number;
  rows?: SyncDataJSON[];
  uploadRows?: SDKUploadRowDTO[];
  hasMore?: boolean;
  byteCount?: number;
  byteLimitReached?: boolean;
  write?: FTDBTaskPoolWriteResponse;
  uploadCommit?: FTDBTaskPoolUploadCommitResponse;
  maintenance?: FTDBTaskPoolMaintenanceResponse;
  deleteAll?: FTDBTaskPoolDeleteAllResult;
  view?: ViewBeanJSON | null;
  views?: ViewBeanJSON[];
  actionBean?: ActionBeanJSON | null;
  actions?: ActionBeanJSON[];
  actionInfo?: FTDBTaskPoolActionInfoDTO | null;
  actionCounts?: FTDBTaskPoolActionCountsDTO | null;
  closeAction?: FTDBTaskPoolCloseActionResponse;
  strings?: string[];
  dbLaneWaitMs?: number;
  errorMessage?: string;
}

interface FTDBTaskPoolDeleteAllResult {
  sync: number;
  view: number;
  action: number;
}

interface FTDBTaskPoolTiming {
  computeMs: number;
  executeMs: number;
  insertMs: number;
  sizeCheckMs: number;
  cleanupMs: number;
}

interface FTDBTaskPoolUploadPageResult {
  rows: SDKUploadRowDTO[];
  hasMore: boolean;
  byteCount: number;
  byteLimitReached: boolean;
}

interface FTDBTaskPoolCountDelta {
  log: number;
  rum: number;
}

interface FTDBTaskPoolViewAttrParts {
  extraAttr: Record<string, object>;
  property: Record<string, object>;
  tags: Record<string, string>;
}

enum FTDBTaskPoolCacheCategory {
  LOG = 'log',
  RUM = 'rum',
  NONE = 'none'
}
export async function runFTDBTaskPoolExecute(contextObject: Object, requestObject: Object): Promise<Object> {
  const context = contextObject as Context;
  const request = requestObject as FTDBTaskPoolRequest;
  try {
    const rdbStore = await openTaskPoolRdbStore(context);
    switch (request.command) {
      case FTDBTaskPoolCommand.INIT:
        return okResponse();
      case FTDBTaskPoolCommand.HAS_SYNC_DATA:
        return okResponse(undefined, await hasSyncDataInTaskPool(rdbStore, request.dataTypes || []));
      case FTDBTaskPoolCommand.QUERY_SYNC_DATA:
        return {
          ok: true,
          rows: await querySyncDataInTaskPool(
            rdbStore,
            request.dataTypes || [],
            normalizeLimit(request.limit),
            request.newestFirst === true
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.QUERY_UPLOAD_DATA: {
        const uploadPage = await queryUploadDataInTaskPool(
          rdbStore,
          request.dataTypes || [],
          normalizeLimit(request.limit),
          normalizeByteLimit(request.maxBytes)
        );
        return {
          ok: true,
          uploadRows: uploadPage.rows,
          hasMore: uploadPage.hasMore,
          byteCount: uploadPage.byteCount,
          byteLimitReached: uploadPage.byteLimitReached
        } as FTDBTaskPoolResponse as Object;
      }
      case FTDBTaskPoolCommand.WRITE_SYNC_DATA:
        return {
          ok: true,
          write: await writeSyncDataInTaskPool(
            rdbStore,
            request.source || 'db.taskpool.write',
            request.records || [],
            request.options || defaultWriteOptions(),
            request.policy || defaultCachePolicySnapshot()
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.WRITE_SYNC_DRAFTS:
        return {
          ok: true,
          write: await writeSyncDataInTaskPool(
            rdbStore,
            request.source || 'db.taskpool.writeDrafts',
            syncDraftsToRows(request.drafts || [], request.fallbackDataType || DataType.LOG.toString()),
            request.options || defaultWriteOptions(),
            request.policy || defaultCachePolicySnapshot()
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.DELETE_SYNC_ROWS:
        return okCountResponse(await deleteSyncRowsInTaskPool(rdbStore, request.records || []));
      case FTDBTaskPoolCommand.DELETE_SYNC_ROW_IDS:
        return okCountResponse(await deleteSyncRowIdsInTaskPool(rdbStore, request.rowIds || []));
      case FTDBTaskPoolCommand.QUERY_TOTAL_COUNT:
        return okCountResponse(await queryTotalCountInTaskPool(rdbStore, request.dataTypes || []));
      case FTDBTaskPoolCommand.GET_DB_SIZE:
        return okCountResponse(await getCurrentDbSizeInTaskPool(rdbStore, createTiming()));
      case FTDBTaskPoolCommand.GET_LAST_ERROR_TIMELINE:
        return okCountResponse(await getLastErrorTimeLineInTaskPool(rdbStore));
      case FTDBTaskPoolCommand.UPDATE_LAST_ERROR_TIMELINE:
        await updateLastErrorTimeLineInTaskPool(rdbStore, request.errorTimeLine || -1);
        return okResponse();
      case FTDBTaskPoolCommand.DELETE_OLDEST_SYNC_DATA:
        return okCountResponse(
          await deleteOldestSyncDataInTaskPool(rdbStore, request.dataTypes || [], normalizeLimit(request.limit))
        );
      case FTDBTaskPoolCommand.UPDATE_DATA_TYPE:
        return okCountResponse(await updateDataTypeInTaskPool(rdbStore, request.dataType || '', request.errorTimeLine || -1));
      case FTDBTaskPoolCommand.DELETE_EXPIRE_CACHE:
        return okCountResponse(
          await deleteExpireCacheInTaskPool(rdbStore, request.dataType || '', request.now || 0, request.duration || 0)
        );
      case FTDBTaskPoolCommand.ERROR_SAMPLED_MAINTENANCE:
        return {
          ok: true,
          maintenance: await maintainErrorSampledInTaskPool(
            rdbStore,
            request.dataType || '',
            request.errorTimeLine || -1,
            request.now || 0,
            request.duration || 0
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.UPLOAD_COMMIT:
        return {
          ok: true,
          uploadCommit: await uploadCommitInTaskPool(
            rdbStore,
            request.dataType || '',
            request.commitAction || '',
            request.records || [],
            request.reInsertRecords || [],
            request.reduceCount || 0
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.DELETE_ALL:
        return {
          ok: true,
          deleteAll: await deleteAllInTaskPool(rdbStore)
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.CLEANUP_EXPIRED_RUM_VIEW:
        return okCountResponse(await cleanupExpiredRumTableInTaskPool(
          rdbStore,
          FTSQL.FT_TABLE_VIEW,
          request.cutoffTime || 0
        ));
      case FTDBTaskPoolCommand.CLEANUP_EXPIRED_RUM_ACTION:
        return okCountResponse(await cleanupExpiredRumTableInTaskPool(
          rdbStore,
          FTSQL.FT_TABLE_ACTION,
          request.cutoffTime || 0
        ));
      case FTDBTaskPoolCommand.UPSERT_RUM_VIEW:
        return okResponse(undefined, request.view ? await upsertRumViewInTaskPool(rdbStore, request.view) : false);
      case FTDBTaskPoolCommand.UPDATE_RUM_VIEW:
        return okResponse(undefined, request.view ? await updateRumViewInTaskPool(rdbStore, request.view) : false);
      case FTDBTaskPoolCommand.CLOSE_RUM_VIEW:
        return okResponse(undefined, await closeRumViewInTaskPool(
          rdbStore,
          request.viewId || '',
          request.loadTime || 0,
          request.timeSpent || 0,
          request.attr || '{}',
          request.newSessionId || '',
          request.now || 0
        ));
      case FTDBTaskPoolCommand.UPDATE_VIEW_UPLOAD_TIME:
        return okResponse(undefined, await updateViewUploadTimeInTaskPool(
          rdbStore,
          request.viewId || '',
          request.dateTime || 0
        ));
      case FTDBTaskPoolCommand.INCREASE_VIEW_ACTION:
        return okCountResponse(await increaseViewActionInTaskPool(rdbStore, request.viewId || ''));
      case FTDBTaskPoolCommand.GET_RUM_PENDING_RESOURCE:
        return okCountResponse(await getRumPendingResourceInTaskPool(
          rdbStore,
          request.target || '',
          firstString(request.ids || [])
        ));
      case FTDBTaskPoolCommand.FORCE_CLEAR_RUM_PENDING_RESOURCE:
        return okCountResponse(await forceClearRumPendingResourceInTaskPool(
          rdbStore,
          request.target || '',
          firstString(request.ids || [])
        ));
      case FTDBTaskPoolCommand.GET_ACTION_INFO:
        return {
          ok: true,
          actionInfo: await getActionInfoInTaskPool(rdbStore, request.actionId || '')
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.APPLY_RUM_COUNTER_DELTAS:
        return okCountResponse(await applyRumCounterDeltasInTaskPool(
          rdbStore,
          request.counterDeltas || [],
          request.now || 0
        ));
      case FTDBTaskPoolCommand.UPDATE_VIEW_UPDATE_TIME:
        return okResponse(undefined, await updateViewUpdateTimeInTaskPool(
          rdbStore,
          request.viewId || '',
          request.now || 0
        ));
      case FTDBTaskPoolCommand.INSERT_RUM_ACTION:
        return okResponse(undefined, request.actionBean ? await insertRumActionInTaskPool(rdbStore, request.actionBean) : false);
      case FTDBTaskPoolCommand.CLOSE_RUM_ACTION:
        return {
          ok: true,
          closeAction: await closeRumActionInTaskPool(
            rdbStore,
            request.actionId || '',
            request.duration || 0,
            request.force === true
          )
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.QUERY_SUM_ACTION:
        return {
          ok: true,
          actions: await querySumActionInTaskPool(rdbStore, normalizeLimit(request.limit))
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.GET_ACTION_COUNTS:
        return {
          ok: true,
          actionCounts: await getActionCountsInTaskPool(rdbStore, request.actionId || '')
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.QUERY_SUM_VIEW:
        return {
          ok: true,
          views: await querySumViewInTaskPool(rdbStore, normalizeLimit(request.limit))
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.QUERY_RUM_VIEW_BY_ID:
        return {
          ok: true,
          view: await queryRumViewByIdInTaskPool(rdbStore, request.viewId || '')
        } as FTDBTaskPoolResponse as Object;
      case FTDBTaskPoolCommand.CLEAN_CLOSE_ACTION_DATA:
        return okCountResponse(await cleanCloseActionDataInTaskPool(rdbStore, request.ids || []));
      case FTDBTaskPoolCommand.CLEAN_CLOSE_VIEW_DATA:
        return okCountResponse(await cleanCloseViewDataInTaskPool(rdbStore, request.ids || [], request.now || 0));
      case FTDBTaskPoolCommand.CLOSE_ALL_ACTION_AND_VIEW:
        return okCountResponse(await closeAllActionAndViewInTaskPool(rdbStore, request.now || 0));
      case FTDBTaskPoolCommand.QUERY_RELATED_UUIDS_BY_ACTION_ID:
        return {
          ok: true,
          strings: await queryRelatedUUIDsByActionIdInTaskPool(
            rdbStore,
            request.actionId || '',
            request.measurementType || '',
            request.dataType || ''
          )
        } as FTDBTaskPoolResponse as Object;
      default:
        throw new Error(`Unsupported DB taskpool command: ${request.command}`);
    }
  } catch (error) {
    return {
      ok: false,
      errorMessage: String(error)
    } as FTDBTaskPoolResponse as Object;
  }
}

async function openTaskPoolRdbStore(context: Context): Promise<relationalStore.RdbStore> {
  const config: relationalStore.StoreConfig = {
    name: FTDBConfig.DATABASE_NAME,
    securityLevel: FTDBConfig.SECURITY_LEVEL as relationalStore.SecurityLevel,
    encrypt: FTDBConfig.ENCRYPT_MODE
  };
  const rdbStore = await relationalStore.getRdbStore(context, config);
  await rdbStore.executeSql(FTSQL.FT_TABLE_SYNC_CREATE);
  await rdbStore.executeSql(FTSQL.FT_TABLE_VIEW_CREATE);
  await rdbStore.executeSql(FTSQL.FT_TABLE_ACTION_CREATE);
  await rdbStore.executeSql(FTSQL.FT_TABLE_SDK_META_CREATE);
  for (let i = 0; i < FTSQL.CREATE_INDEXES.length; i++) {
    await rdbStore.executeSql(FTSQL.CREATE_INDEXES[i]);
  }
  return rdbStore;
}

function okResponse(count?: number, value?: boolean): Object {
  const response: FTDBTaskPoolResponse = { ok: true };
  if (count !== undefined) {
    response.count = count;
  }
  if (value !== undefined) {
    response.value = value;
  }
  return response as Object;
}

function okCountResponse(count: number): Object {
  return {
    ok: true,
    count
  } as FTDBTaskPoolResponse as Object;
}

function normalizeLimit(limit?: number): number {
  if (typeof limit !== 'number' || limit !== limit || limit <= 0) {
    return 100;
  }
  return Math.max(1, Math.floor(limit));
}

function normalizeByteLimit(maxBytes?: number): number {
  if (typeof maxBytes !== 'number' || maxBytes !== maxBytes || maxBytes <= 0) {
    return 1024 * 1024;
  }
  return Math.max(1024, Math.floor(maxBytes));
}

function defaultWriteOptions(): FTDBTaskPoolWriteOptions {
  return {
    applyCachePolicy: false,
    reInsert: false,
    forceTransaction: false,
    updateOrInsertByUuid: false
  };
}

function defaultCachePolicySnapshot(): FTDBTaskPoolCachePolicySnapshot {
  return {
    enableLimitWithDbSize: false,
    dbLimitSize: 0,
    dbCacheDiscard: DBCacheDiscard.DISCARD,
    logLimitCount: 0,
    rumLimitCount: 0,
    logDiscardStrategy: DBCacheDiscard.DISCARD,
    rumDiscardStrategy: DBCacheDiscard.DISCARD
  };
}

function createTiming(): FTDBTaskPoolTiming {
  return {
    computeMs: 0,
    executeMs: 0,
    insertMs: 0,
    sizeCheckMs: 0,
    cleanupMs: 0
  };
}

function addComputeTime(timing: FTDBTaskPoolTiming, startTime: number): void {
  timing.computeMs += Math.max(0, Date.now() - startTime);
}

function addExecuteTime(timing: FTDBTaskPoolTiming, startTime: number): void {
  timing.executeMs += Math.max(0, Date.now() - startTime);
}

function addInsertTime(timing: FTDBTaskPoolTiming, startTime: number): void {
  timing.insertMs += Math.max(0, Date.now() - startTime);
}

function createWriteResult(source: string, requested: number): FTDBTaskPoolWriteResult {
  return {
    success: true,
    source,
    requested,
    inserted: 0,
    updated: 0,
    dropped: 0,
    duplicateSkipped: 0,
    deletedOld: 0,
    errorMessage: ''
  };
}

function createCountDelta(): FTDBTaskPoolCountDelta {
  return {
    log: 0,
    rum: 0
  };
}

function dataTypeToEnum(dataType: string): DataType {
  if (dataType === DataType.RUM_APP.toString()) {
    return DataType.RUM_APP;
  }
  if (dataType === DataType.RUM_WEBVIEW.toString()) {
    return DataType.RUM_WEBVIEW;
  }
  return DataType.LOG;
}

function syncDraftsToRows(drafts: FTDBTaskPoolSyncDraftDTO[], fallbackDataType: string): SyncDataJSON[] {
  const rows: SyncDataJSON[] = [];
  const fallback = dataTypeToEnum(fallbackDataType);
  for (let i = 0; i < drafts.length; i++) {
    const draft = drafts[i];
    if (!draft || !draft.dataString || !draft.uuid) {
      continue;
    }
    const row: SyncDataJSON = {
      id: 0,
      dataType: dataTypeToEnum(draft.dataType || fallback.toString()),
      dataString: draft.dataString,
      uuid: draft.uuid,
      time: draft.time || 0
    };
    if (draft.customDataType && draft.customDataType.length > 0) {
      row.customDataTypeString = draft.customDataType;
    }
    rows.push(row);
  }
  return rows;
}

function getStoredDataType(row: SyncDataJSON): string {
  return row.customDataTypeString && row.customDataTypeString.length > 0 ?
    row.customDataTypeString : String(row.dataType);
}

function getCacheCategoryForTypeString(dataTypeString: string): FTDBTaskPoolCacheCategory {
  if (dataTypeString === DataType.LOG.toString()) {
    return FTDBTaskPoolCacheCategory.LOG;
  }
  if (dataTypeString === DataType.RUM_APP.toString() || dataTypeString === DataType.RUM_WEBVIEW.toString()) {
    return FTDBTaskPoolCacheCategory.RUM;
  }
  return FTDBTaskPoolCacheCategory.NONE;
}

function addCountDelta(delta: FTDBTaskPoolCountDelta, category: FTDBTaskPoolCacheCategory, count: number): void {
  if (count === 0) {
    return;
  }
  if (category === FTDBTaskPoolCacheCategory.LOG) {
    delta.log += count;
  } else if (category === FTDBTaskPoolCacheCategory.RUM) {
    delta.rum += count;
  }
}

function addInsertedCountDelta(delta: FTDBTaskPoolCountDelta, records: SyncDataJSON[], inserted: number): void {
  const limit = Math.min(Math.max(0, inserted), records.length);
  for (let i = 0; i < limit; i++) {
    addCountDelta(delta, getCacheCategoryForTypeString(getStoredDataType(records[i])), 1);
  }
}

function addDeletedTypesDelta(delta: FTDBTaskPoolCountDelta, dataTypes: string[], deleted: number): void {
  if (deleted <= 0 || dataTypes.length === 0) {
    return;
  }
  let hasLog = false;
  let hasRum = false;
  for (let i = 0; i < dataTypes.length; i++) {
    const category = getCacheCategoryForTypeString(dataTypes[i]);
    if (category === FTDBTaskPoolCacheCategory.LOG) {
      hasLog = true;
    } else if (category === FTDBTaskPoolCacheCategory.RUM) {
      hasRum = true;
    }
  }
  if (hasLog && !hasRum) {
    delta.log -= deleted;
  } else if (hasRum && !hasLog) {
    delta.rum -= deleted;
  }
}

function toSyncDataValues(row: SyncDataJSON): relationalStore.ValuesBucket {
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RECORD_COLUMN_TM] = row.time;
  values[FTSQL.RECORD_COLUMN_DATA_UUID] = row.uuid;
  values[FTSQL.RECORD_COLUMN_DATA] = row.dataString;
  values[FTSQL.RECORD_COLUMN_DATA_TYPE] = getStoredDataType(row);
  return values;
}

function buildTypePredicates(dataTypes: string[]): relationalStore.RdbPredicates {
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  if (dataTypes.length > 0) {
    predicates.in(FTSQL.RECORD_COLUMN_DATA_TYPE, dataTypes);
  }
  return predicates;
}

async function hasSyncDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataTypes: string[]
): Promise<boolean> {
  const predicates = buildTypePredicates(dataTypes);
  predicates.limitAs(1);
  const resultSet = await rdbStore.query(predicates, [FTSQL.RECORD_COLUMN_ID]);
  try {
    return resultSet.goToNextRow();
  } finally {
    resultSet.close();
  }
}

async function querySyncDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataTypes: string[],
  limit: number,
  newestFirst: boolean
): Promise<SyncDataJSON[]> {
  const predicates = buildTypePredicates(dataTypes);
  if (newestFirst) {
    predicates.orderByDesc(FTSQL.RECORD_COLUMN_TM);
  } else {
    predicates.orderByAsc(FTSQL.RECORD_COLUMN_TM);
  }
  predicates.limitAs(limit);

  const rows: SyncDataJSON[] = [];
  const resultSet = await rdbStore.query(predicates, [
    FTSQL.RECORD_COLUMN_ID,
    FTSQL.RECORD_COLUMN_DATA_UUID,
    FTSQL.RECORD_COLUMN_DATA_TYPE,
    FTSQL.RECORD_COLUMN_DATA,
    FTSQL.RECORD_COLUMN_TM
  ]);
  try {
    while (resultSet.goToNextRow()) {
      const storedType = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_TYPE));
      const row: SyncDataJSON = {
        id: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_ID)),
        uuid: resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID)),
        dataType: dataTypeToEnum(storedType),
        dataString: resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA)),
        time: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_TM))
      };
      if (storedType !== row.dataType.toString()) {
        row.customDataTypeString = storedType;
      }
      rows.push(row);
    }
  } finally {
    resultSet.close();
  }
  return rows;
}

async function queryUploadDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataTypes: string[],
  limit: number,
  maxBytes: number
): Promise<FTDBTaskPoolUploadPageResult> {
  const predicates = buildTypePredicates(dataTypes);
  predicates.orderByAsc(FTSQL.RECORD_COLUMN_TM);
  // Read one extra row inside TaskPool to detect count-based pagination without
  // transporting it back to the Host.
  predicates.limitAs(limit + 1);
  const result: FTDBTaskPoolUploadPageResult = {
    rows: [],
    hasMore: false,
    byteCount: 0,
    byteLimitReached: false
  };
  const resultSet = await rdbStore.query(predicates, [
    FTSQL.RECORD_COLUMN_ID,
    FTSQL.RECORD_COLUMN_DATA_UUID,
    FTSQL.RECORD_COLUMN_DATA_TYPE,
    FTSQL.RECORD_COLUMN_DATA,
    FTSQL.RECORD_COLUMN_TM
  ]);
  try {
    while (resultSet.goToNextRow()) {
      if (result.rows.length >= limit) {
        result.hasMore = true;
        break;
      }
      const storedType = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_TYPE));
      const normalizedType = dataTypeToEnum(storedType).toString();
      const row: SDKUploadRowDTO = {
        id: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_ID)),
        uuid: resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID)),
        dataType: normalizedType,
        dataString: resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA)),
        time: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_TM))
      };
      if (storedType !== normalizedType) {
        row.customDataType = storedType;
      }
      const rowBytes = estimateUploadTransportRowBytes(row);
      if (result.byteCount + rowBytes > maxBytes) {
        result.hasMore = true;
        result.byteLimitReached = true;
        break;
      }
      result.rows.push(row);
      result.byteCount += rowBytes;
    }
  } finally {
    resultSet.close();
  }
  return result;
}

function estimateUploadTransportRowBytes(row: SDKUploadRowDTO): number {
  return getUtf8ByteLength(row.dataString || '') + getUtf8ByteLength(row.uuid || '') +
    getUtf8ByteLength(row.dataType || '') + getUtf8ByteLength(row.customDataType || '') + 64;
}

function getUtf8ByteLength(value: string): number {
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

async function queryTotalCountInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataTypes: string[]
): Promise<number> {
  const predicates = buildTypePredicates(dataTypes);
  const resultSet = await rdbStore.query(predicates, ['count(*) as count']);
  try {
    if (resultSet.goToFirstRow()) {
      return resultSet.getLong(0);
    }
    return 0;
  } finally {
    resultSet.close();
  }
}

async function getCurrentDbSizeInTaskPool(
  rdbStore: relationalStore.RdbStore,
  timing: FTDBTaskPoolTiming
): Promise<number> {
  const startTime = Date.now();
  const resultSet = await rdbStore.querySql("PRAGMA page_count");
  try {
    if (resultSet && resultSet.goToFirstRow()) {
      const pageCount = resultSet.getLong(resultSet.getColumnIndex("page_count"));
      return pageCount * 4096;
    }
    return 0;
  } finally {
    resultSet?.close();
    timing.sizeCheckMs += Math.max(0, Date.now() - startTime);
  }
}

async function getLastErrorTimeLineInTaskPool(rdbStore: relationalStore.RdbStore): Promise<number> {
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_SDK_META);
  predicates.equalTo(FTSQL.SDK_META_COLUMN_KEY, FTSQL.SDK_META_KEY_LAST_ERROR_TIMELINE);
  const resultSet = await rdbStore.query(predicates, [FTSQL.SDK_META_COLUMN_VALUE]);
  try {
    if (resultSet.goToFirstRow()) {
      return resultSet.getLong(0);
    }
    return -1;
  } finally {
    resultSet.close();
  }
}

/**
 * Store only an increasing error timeline. The task-pool DB lane serializes
 * callers, and this function is invoked before the caller commits its RDB
 * transaction so the metadata and its RUM batch are atomic.
 */
async function updateLastErrorTimeLineInTaskPool(
  rdbStore: relationalStore.RdbStore,
  errorTimeLine: number
): Promise<void> {
  if (errorTimeLine <= 0) {
    return;
  }
  const current = await getLastErrorTimeLineInTaskPool(rdbStore);
  if (current >= errorTimeLine) {
    return;
  }

  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.SDK_META_COLUMN_VALUE] = errorTimeLine;
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_SDK_META);
  predicates.equalTo(FTSQL.SDK_META_COLUMN_KEY, FTSQL.SDK_META_KEY_LAST_ERROR_TIMELINE);
  if (current > 0) {
    await rdbStore.update(values, predicates);
    return;
  }

  values[FTSQL.SDK_META_COLUMN_KEY] = FTSQL.SDK_META_KEY_LAST_ERROR_TIMELINE;
  await rdbStore.insert(FTSQL.FT_TABLE_SDK_META, values);
}

function escapeSqlString(value: string): string {
  return value.replace(/'/g, "''");
}

function buildDataTypeWhereClause(dataTypes: string[]): string {
  if (dataTypes.length === 0) {
    return '';
  }
  const escaped: string[] = [];
  for (let i = 0; i < dataTypes.length; i++) {
    escaped.push(`'${escapeSqlString(dataTypes[i])}'`);
  }
  return `${FTSQL.RECORD_COLUMN_DATA_TYPE} IN (${escaped.join(',')})`;
}

async function deleteOldestSyncDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataTypes: string[],
  limit: number,
  timing?: FTDBTaskPoolTiming
): Promise<number> {
  if (limit <= 0) {
    return 0;
  }
  const whereClause = buildDataTypeWhereClause(dataTypes);
  const wherePart = whereClause.length > 0 ? ` WHERE ${whereClause}` : '';
  const countSql = `SELECT COUNT(*) as count FROM (
    SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
    ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
  )`;

  let executeStart = Date.now();
  const resultSet = await rdbStore.querySql(countSql);
  let deleteCount = 0;
  try {
    if (resultSet.goToFirstRow()) {
      deleteCount = resultSet.getLong(0);
    }
  } finally {
    resultSet.close();
    if (timing) {
      addExecuteTime(timing, executeStart);
    }
  }

  if (deleteCount <= 0) {
    return 0;
  }

  const deleteSql = `DELETE FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME} WHERE _id IN (
    SELECT _id FROM ${FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME}${wherePart}
    ORDER BY ${FTSQL.RECORD_COLUMN_TM} ASC LIMIT ${limit}
  )`;
  executeStart = Date.now();
  await rdbStore.executeSql(deleteSql);
  if (timing) {
    addExecuteTime(timing, executeStart);
  }
  return deleteCount;
}

async function resolveAllowedInsertCount(
  rdbStore: relationalStore.RdbStore,
  category: FTDBTaskPoolCacheCategory,
  requested: number,
  policy: FTDBTaskPoolCachePolicySnapshot,
  result: FTDBTaskPoolWriteResult,
  delta: FTDBTaskPoolCountDelta,
  timing: FTDBTaskPoolTiming
): Promise<number> {
  if (requested <= 0 || category === FTDBTaskPoolCacheCategory.NONE) {
    return requested;
  }
  const dataTypes = category === FTDBTaskPoolCacheCategory.LOG ?
    [DataType.LOG.toString()] : [DataType.RUM_APP.toString(), DataType.RUM_WEBVIEW.toString()];

  if (policy.enableLimitWithDbSize) {
    const currentSize = await getCurrentDbSizeInTaskPool(rdbStore, timing);
    if (currentSize < Math.max(0, policy.dbLimitSize)) {
      return requested;
    }
    if (policy.dbCacheDiscard === DBCacheDiscard.DISCARD_OLDEST) {
      const cleanupStart = Date.now();
      const deleted = await deleteOldestSyncDataInTaskPool(
        rdbStore,
        dataTypes,
        Constants.DB_OLD_CACHE_REMOVE_COUNT,
        timing
      );
      result.deletedOld += deleted;
      addDeletedTypesDelta(delta, dataTypes, deleted);
      timing.cleanupMs += Math.max(0, Date.now() - cleanupStart);
      return requested;
    }
    return 0;
  }

  const currentCount = await queryTotalCountInTaskPool(rdbStore, dataTypes);
  const limit = category === FTDBTaskPoolCacheCategory.LOG ? policy.logLimitCount : policy.rumLimitCount;
  if (limit <= 0 || currentCount + requested <= limit) {
    return requested;
  }

  const overflow = currentCount + requested - limit;
  const discardStrategy = category === FTDBTaskPoolCacheCategory.LOG ?
    policy.logDiscardStrategy : policy.rumDiscardStrategy;
  if (discardStrategy === DBCacheDiscard.DISCARD_OLDEST) {
    const cleanupStart = Date.now();
    const deleted = await deleteOldestSyncDataInTaskPool(rdbStore, dataTypes, overflow, timing);
    result.deletedOld += deleted;
    addDeletedTypesDelta(delta, dataTypes, deleted);
    timing.cleanupMs += Math.max(0, Date.now() - cleanupStart);
    return requested;
  }
  return Math.max(0, limit - currentCount);
}

async function applyWriteCachePolicy(
  rdbStore: relationalStore.RdbStore,
  records: SyncDataJSON[],
  policy: FTDBTaskPoolCachePolicySnapshot,
  result: FTDBTaskPoolWriteResult,
  delta: FTDBTaskPoolCountDelta,
  timing: FTDBTaskPoolTiming
): Promise<SyncDataJSON[]> {
  let logRequested = 0;
  let rumRequested = 0;
  for (let i = 0; i < records.length; i++) {
    const category = getCacheCategoryForTypeString(getStoredDataType(records[i]));
    if (category === FTDBTaskPoolCacheCategory.LOG) {
      logRequested++;
    } else if (category === FTDBTaskPoolCacheCategory.RUM) {
      rumRequested++;
    }
  }

  let allowedLogs = await resolveAllowedInsertCount(
    rdbStore,
    FTDBTaskPoolCacheCategory.LOG,
    logRequested,
    policy,
    result,
    delta,
    timing
  );
  let allowedRum = await resolveAllowedInsertCount(
    rdbStore,
    FTDBTaskPoolCacheCategory.RUM,
    rumRequested,
    policy,
    result,
    delta,
    timing
  );

  const allowed: SyncDataJSON[] = [];
  for (let i = 0; i < records.length; i++) {
    const row = records[i];
    const category = getCacheCategoryForTypeString(getStoredDataType(row));
    if (category === FTDBTaskPoolCacheCategory.LOG) {
      if (allowedLogs > 0) {
        allowedLogs--;
        allowed.push(row);
      } else {
        result.dropped++;
      }
    } else if (category === FTDBTaskPoolCacheCategory.RUM) {
      if (allowedRum > 0) {
        allowedRum--;
        allowed.push(row);
      } else {
        result.dropped++;
      }
    } else {
      allowed.push(row);
    }
  }
  return allowed;
}

async function insertPreparedSyncData(
  rdbStore: relationalStore.RdbStore,
  records: SyncDataJSON[],
  result: FTDBTaskPoolWriteResult,
  delta: FTDBTaskPoolCountDelta,
  timing: FTDBTaskPoolTiming,
  countInserted: boolean = true
): Promise<void> {
  if (records.length === 0) {
    return;
  }
  if (records.length === 1) {
    const values = toSyncDataValues(records[0]);
    const executeStart = Date.now();
    const rowId = await rdbStore.insert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, values);
    addExecuteTime(timing, executeStart);
    addInsertTime(timing, executeStart);
    if (Number(rowId) > 0) {
      result.inserted++;
      if (countInserted) {
        addInsertedCountDelta(delta, records, 1);
      }
    } else {
      result.success = false;
      result.errorMessage = `Invalid rowId returned: ${rowId}`;
    }
    return;
  }

  const valuesArray: relationalStore.ValuesBucket[] = [];
  for (let i = 0; i < records.length; i++) {
    valuesArray.push(toSyncDataValues(records[i]));
  }
  const executeStart = Date.now();
  const inserted = await rdbStore.batchInsert(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME, valuesArray);
  addExecuteTime(timing, executeStart);
  addInsertTime(timing, executeStart);
  const insertedRows = Math.max(0, inserted);
  result.inserted += insertedRows;
  if (countInserted) {
    addInsertedCountDelta(delta, records, insertedRows);
  }
}

async function updatePreparedSyncDataByUuid(
  rdbStore: relationalStore.RdbStore,
  row: SyncDataJSON,
  timing: FTDBTaskPoolTiming
): Promise<number> {
  if (!row.uuid || row.uuid.length === 0) {
    return 0;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_UUID, row.uuid);
  const executeStart = Date.now();
  const updated = await rdbStore.update(toSyncDataValues(row), predicates);
  addExecuteTime(timing, executeStart);
  return Math.max(0, updated);
}

async function writeSyncDataBody(
  rdbStore: relationalStore.RdbStore,
  records: SyncDataJSON[],
  options: FTDBTaskPoolWriteOptions,
  policy: FTDBTaskPoolCachePolicySnapshot,
  result: FTDBTaskPoolWriteResult,
  delta: FTDBTaskPoolCountDelta,
  timing: FTDBTaskPoolTiming
): Promise<void> {
  if (options.updateOrInsertByUuid) {
    const upsertRows = deduplicateRowsForUpsert(records, result);
    const rowsToInsert: SyncDataJSON[] = [];
    for (let i = 0; i < upsertRows.length; i++) {
      const updated = await updatePreparedSyncDataByUuid(rdbStore, upsertRows[i], timing);
      if (updated > 0) {
        result.updated += updated;
      } else {
        rowsToInsert.push(upsertRows[i]);
      }
    }
    const allowedInserts = options.applyCachePolicy ?
      await applyWriteCachePolicy(rdbStore, rowsToInsert, policy, result, delta, timing) : rowsToInsert;
    await insertPreparedSyncData(rdbStore, allowedInserts, result, delta, timing, !options.reInsert);
    return;
  }

  let dataToWrite = records;
  if (options.applyCachePolicy) {
    dataToWrite = await applyWriteCachePolicy(rdbStore, records, policy, result, delta, timing);
  }
  if (dataToWrite.length === 0) {
    return;
  }
  await insertPreparedSyncData(rdbStore, dataToWrite, result, delta, timing, !options.reInsert);
}

function deduplicateRowsForUpsert(
  records: SyncDataJSON[],
  result: FTDBTaskPoolWriteResult
): SyncDataJSON[] {
  const rows: SyncDataJSON[] = [];
  const indexes: Record<string, number> = {};
  for (let i = 0; i < records.length; i++) {
    const row = records[i];
    if (!row.uuid || row.uuid.length === 0) {
      rows.push(row);
      continue;
    }
    const existingIndex = indexes[row.uuid];
    if (existingIndex !== undefined) {
      rows[existingIndex] = row;
      result.duplicateSkipped++;
      continue;
    }
    indexes[row.uuid] = rows.length;
    rows.push(row);
  }
  return rows;
}

async function writeSyncDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  source: string,
  records: SyncDataJSON[],
  options: FTDBTaskPoolWriteOptions,
  policy: FTDBTaskPoolCachePolicySnapshot
): Promise<FTDBTaskPoolWriteResponse> {
  const result = createWriteResult(source, records.length);
  const delta = createCountDelta();
  const timing = createTiming();
  const shouldTransaction =
    options.forceTransaction || options.applyCachePolicy || options.updateOrInsertByUuid ||
    options.lastErrorTimeLine !== undefined || records.length > TRANSACTION_LIMIT_COUNT;

  try {
    if (shouldTransaction) {
      rdbStore.beginTransaction();
    }
    await writeSyncDataBody(rdbStore, records, options, policy, result, delta, timing);
    const resolvedRecords = result.inserted + result.updated + result.dropped + result.duplicateSkipped;
    if (result.success && resolvedRecords < result.requested) {
      throw new Error(`Incomplete DB write: resolved=${resolvedRecords}, requested=${result.requested}`);
    }
    if (result.success && options.lastErrorTimeLine !== undefined) {
      await updateLastErrorTimeLineInTaskPool(rdbStore, options.lastErrorTimeLine);
    }
    if (shouldTransaction) {
      rdbStore.commit();
    }
  } catch (error) {
    if (shouldTransaction) {
      rdbStore.rollBack();
    }
    result.success = false;
    result.errorMessage = String(error);
    result.inserted = 0;
    result.updated = 0;
    result.dropped = 0;
    result.duplicateSkipped = 0;
    result.deletedOld = 0;
    // Cache deltas were computed inside the transaction and must not escape a rollback.
    delta.log = 0;
    delta.rum = 0;
  }

  return {
    result,
    logCountDelta: delta.log,
    rumCountDelta: delta.rum,
    currentDbSize: 0,
    dbLaneWaitMs: 0,
    computeMs: timing.computeMs,
    executeMs: timing.executeMs,
    insertMs: timing.insertMs,
    sizeCheckMs: timing.sizeCheckMs,
    cleanupMs: timing.cleanupMs
  };
}

function normalizeRowIds(rowIds: number[]): number[] {
  const ids: number[] = [];
  const seen: Record<string, boolean> = {};
  for (let i = 0; i < rowIds.length; i++) {
    const id = Math.floor(rowIds[i]);
    const key = String(id);
    if (id > 0 && seen[key] !== true) {
      seen[key] = true;
      ids.push(id);
    }
  }
  return ids;
}

async function deleteSyncRowIdsInTaskPool(
  rdbStore: relationalStore.RdbStore,
  rowIds: number[]
): Promise<number> {
  const ids = normalizeRowIds(rowIds);
  if (ids.length === 0) {
    return 0;
  }
  const useTransaction = ids.length > TRANSACTION_LIMIT_COUNT;
  try {
    if (useTransaction) {
      rdbStore.beginTransaction();
    }
    const deleted = await deleteSyncRowIdsBodyInTaskPool(rdbStore, ids);
    if (useTransaction) {
      rdbStore.commit();
    }
    return deleted;
  } catch (error) {
    if (useTransaction) {
      rdbStore.rollBack();
    }
    throw new Error(String(error));
  }
}

async function deleteSyncRowIdsBodyInTaskPool(
  rdbStore: relationalStore.RdbStore,
  rowIds: number[]
): Promise<number> {
  const ids = normalizeRowIds(rowIds);
  let deleted = 0;
  for (let start = 0; start < ids.length; start += DELETE_BATCH_CHUNK_SIZE) {
    const batchIds = ids.slice(start, start + DELETE_BATCH_CHUNK_SIZE);
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.in(FTSQL.RECORD_COLUMN_ID, batchIds);
    deleted += await rdbStore.delete(predicates);
  }
  return deleted;
}

async function deleteSyncRowsBodyInTaskPool(
  rdbStore: relationalStore.RdbStore,
  records: SyncDataJSON[]
): Promise<number> {
  const rowIds: number[] = [];
  const fallbackUuids: string[] = [];
  const seenUuids: Record<string, boolean> = {};
  for (let i = 0; i < records.length; i++) {
    const id = Math.floor(records[i].id);
    if (id > 0) {
      rowIds.push(id);
    }
    const uuid = records[i].uuid || '';
    if (uuid.length > 0 && seenUuids[uuid] !== true) {
      seenUuids[uuid] = true;
      fallbackUuids.push(uuid);
    }
  }
  let deleted = await deleteSyncRowIdsBodyInTaskPool(rdbStore, rowIds);
  if (fallbackUuids.length === 0) {
    return deleted;
  }
  if (deleted >= records.length) {
    return deleted;
  }
  for (let start = 0; start < fallbackUuids.length; start += DELETE_BATCH_CHUNK_SIZE) {
    const batchUuids = fallbackUuids.slice(start, start + DELETE_BATCH_CHUNK_SIZE);
    const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
    predicates.in(FTSQL.RECORD_COLUMN_DATA_UUID, batchUuids);
    deleted += await rdbStore.delete(predicates);
  }
  return deleted;
}

async function deleteSyncRowsInTaskPool(
  rdbStore: relationalStore.RdbStore,
  records: SyncDataJSON[]
): Promise<number> {
  if (records.length === 0) {
    return 0;
  }
  const useTransaction = records.length > TRANSACTION_LIMIT_COUNT;
  try {
    if (useTransaction) {
      rdbStore.beginTransaction();
    }
    const deleted = await deleteSyncRowsBodyInTaskPool(rdbStore, records);
    if (useTransaction) {
      rdbStore.commit();
    }
    return deleted;
  } catch (error) {
    if (useTransaction) {
      rdbStore.rollBack();
    }
    throw new Error(String(error));
  }
}

async function updateDataTypeInTaskPool(
  rdbStore: relationalStore.RdbStore,
  errorSampledDataType: string,
  errorTimeLine: number
): Promise<number> {
  if (!errorSampledDataType.endsWith(ERROR_SAMPLED_SUFFIX)) {
    return 0;
  }
  const targetType = errorSampledDataType.replace(ERROR_SAMPLED_SUFFIX, "");
  const countPredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  countPredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, errorSampledDataType);
  countPredicates.lessThanOrEqualTo(FTSQL.RECORD_COLUMN_TM, errorTimeLine);
  const count = await countRows(rdbStore, countPredicates);
  if (count <= 0) {
    return 0;
  }
  const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  updatePredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, errorSampledDataType);
  updatePredicates.lessThanOrEqualTo(FTSQL.RECORD_COLUMN_TM, errorTimeLine);
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RECORD_COLUMN_DATA_TYPE] = targetType;
  await rdbStore.update(values, updatePredicates);
  return count;
}

async function deleteExpireCacheInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataType: string,
  now: number,
  duration: number
): Promise<number> {
  const expireTimeline = now - duration;
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType);
  predicates.lessThan(FTSQL.RECORD_COLUMN_TM, expireTimeline);
  const count = await countRows(rdbStore, predicates);
  if (count <= 0) {
    return 0;
  }
  const deletePredicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  deletePredicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType);
  deletePredicates.lessThan(FTSQL.RECORD_COLUMN_TM, expireTimeline);
  await rdbStore.delete(deletePredicates);
  return count;
}

async function maintainErrorSampledInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataType: string,
  errorTimeLine: number,
  now: number,
  duration: number
): Promise<FTDBTaskPoolMaintenanceResponse> {
  let updatedRows = 0;
  let deletedRows = 0;
  try {
    rdbStore.beginTransaction();
    if (errorTimeLine > 0) {
      updatedRows = await updateDataTypeInTaskPool(rdbStore, dataType, errorTimeLine);
    }
    deletedRows = await deleteExpireCacheInTaskPool(rdbStore, dataType, now, duration);
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return {
    updatedRows,
    deletedRows,
    dbLaneWaitMs: 0
  };
}

async function uploadCommitInTaskPool(
  rdbStore: relationalStore.RdbStore,
  dataType: string,
  action: string,
  records: SyncDataJSON[],
  reInsertRecords: SyncDataJSON[],
  reduceCount: number
): Promise<FTDBTaskPoolUploadCommitResponse> {
  const delta = createCountDelta();
  let deletedRows = 0;
  let insertedRows = 0;
  try {
    rdbStore.beginTransaction();
    if (action === 'delete') {
      deletedRows = await deleteSyncRowsBodyInTaskPool(rdbStore, records);
      if (deletedRows !== records.length) {
        throw new Error(`Upload delete affected ${deletedRows}/${records.length} accepted rows`);
      }
      addCountDelta(delta, getCacheCategoryForTypeString(dataType),
        -Math.min(deletedRows, Math.max(0, reduceCount)));
    } else if (action === 'reinsert') {
      deletedRows = await deleteSyncRowsBodyInTaskPool(rdbStore, records);
      if (deletedRows !== records.length) {
        throw new Error(`Upload retry delete affected ${deletedRows}/${records.length} accepted rows`);
      }
      const result = createWriteResult('uploadCommit.reinsert', reInsertRecords.length);
      await insertPreparedSyncData(rdbStore, reInsertRecords, result, delta, createTiming(), false);
      insertedRows = result.inserted;
      if (!result.success || insertedRows !== reInsertRecords.length) {
        throw new Error(result.errorMessage || 'upload commit reinsert failed');
      }
    } else {
      throw new Error(`Unsupported upload commit action: ${action}`);
    }
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return {
    deletedRows,
    insertedRows,
    affectedRows: deletedRows + insertedRows,
    logCountDelta: delta.log,
    rumCountDelta: delta.rum,
    dbLaneWaitMs: 0
  };
}

async function countRows(
  rdbStore: relationalStore.RdbStore,
  predicates: relationalStore.RdbPredicates
): Promise<number> {
  const resultSet = await rdbStore.query(predicates, ['count(*) as count']);
  try {
    if (resultSet.goToFirstRow()) {
      return resultSet.getLong(0);
    }
    return 0;
  } finally {
    resultSet.close();
  }
}

async function deleteAllInTaskPool(rdbStore: relationalStore.RdbStore): Promise<FTDBTaskPoolDeleteAllResult> {
  const result: FTDBTaskPoolDeleteAllResult = {
    sync: 0,
    view: 0,
    action: 0
  };
  rdbStore.beginTransaction();
  try {
    result.sync = await rdbStore.delete(new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME));
    result.view = await rdbStore.delete(new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW));
    result.action = await rdbStore.delete(new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION));
    await rdbStore.delete(new relationalStore.RdbPredicates(FTSQL.FT_TABLE_SDK_META));
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return result;
}

async function cleanupExpiredRumTableInTaskPool(
  rdbStore: relationalStore.RdbStore,
  tableName: string,
  cutoffTime: number
): Promise<number> {
  const countPredicates = new relationalStore.RdbPredicates(tableName);
  countPredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
  const count = await countRows(rdbStore, countPredicates);
  if (count <= 0) {
    return 0;
  }
  const deletePredicates = new relationalStore.RdbPredicates(tableName);
  deletePredicates.lessThan(FTSQL.RUM_COLUMN_START_TIME, cutoffTime);
  await rdbStore.delete(deletePredicates);
  return count;
}

function firstString(values: string[]): string {
  return values.length > 0 ? values[0] : '';
}

function isActionTarget(target: string): boolean {
  return target === 'action';
}

function getRumTargetTable(target: string): string {
  return isActionTarget(target) ? FTSQL.FT_TABLE_ACTION : FTSQL.FT_TABLE_VIEW;
}

function parseJsonRecord(jsonString: string): Record<string, object> {
  if (!jsonString || jsonString.length === 0) {
    return {};
  }
  try {
    return JSON.parse(jsonString) as Record<string, object>;
  } catch (error) {
    return {};
  }
}

function emptyObjectRecord(): Record<string, object> {
  return new Object() as Record<string, object>;
}

function emptyStringRecord(): Record<string, string> {
  return new Object() as Record<string, string>;
}

function stringifyViewExtraAttr(view: ViewBeanJSON): string {
  const obj: Record<string, object> = {};
  const extraAttr = view.extraAttr ? view.extraAttr : emptyObjectRecord();
  const keys = Object.keys(extraAttr);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    obj[key] = extraAttr[key];
  }
  const property = view.property ? view.property : emptyObjectRecord();
  const tags = view.tags ? view.tags : emptyStringRecord();
  obj[Constants.KEY_RUM_PROPERTY] = property as Object as Record<string, object>;
  obj[Constants.KEY_RUM_TAGS] = tags as Object as Record<string, object>;
  return JSON.stringify(obj);
}

function stringifyActionExtraAttr(actionBean: ActionBeanJSON): string {
  return JSON.stringify(actionBean.extraAttr ? actionBean.extraAttr : emptyObjectRecord());
}

function splitViewExtraAttr(jsonString: string): FTDBTaskPoolViewAttrParts {
  const parsed = parseJsonRecord(jsonString);
  const extraAttr: Record<string, object> = {};
  const property: Record<string, object> = {};
  const tags: Record<string, string> = {};
  const keys = Object.keys(parsed);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = parsed[key];
    if (key === Constants.KEY_RUM_PROPERTY && value && typeof value === 'object') {
      const propertyValue = value as Record<string, object>;
      const propertyKeys = Object.keys(propertyValue);
      for (let j = 0; j < propertyKeys.length; j++) {
        const propertyKey = propertyKeys[j];
        property[propertyKey] = propertyValue[propertyKey];
      }
    } else if (key === Constants.KEY_RUM_TAGS && value && typeof value === 'object') {
      const tagsValue = value as Record<string, object>;
      const tagKeys = Object.keys(tagsValue);
      for (let j = 0; j < tagKeys.length; j++) {
        const tagKey = tagKeys[j];
        tags[tagKey] = String(tagsValue[tagKey]);
      }
    } else {
      extraAttr[key] = value;
    }
  }
  return {
    extraAttr,
    property,
    tags
  };
}

function toViewValues(view: ViewBeanJSON, includeId: boolean): relationalStore.ValuesBucket {
  const values = {} as relationalStore.ValuesBucket;
  if (includeId) {
    values[FTSQL.RUM_COLUMN_ID] = view.id;
  }
  values[FTSQL.RUM_COLUMN_VIEW_NAME] = view.viewName;
  values[FTSQL.RUM_COLUMN_VIEW_REFERRER] = view.viewReferrer;
  values[FTSQL.RUM_COLUMN_START_TIME] = view.startTime;
  values[FTSQL.RUM_COLUMN_IS_CLOSE] = view.isClose ? 1 : 0;
  values[FTSQL.RUM_COLUMN_SESSION_ID] = view.sessionId;
  values[FTSQL.RUM_COLUMN_ACTION_COUNT] = view.actionCount;
  values[FTSQL.RUM_COLUMN_ERROR_COUNT] = view.errorCount;
  values[FTSQL.RUM_COLUMN_LONG_TASK_COUNT] = view.longTaskCount;
  values[FTSQL.RUM_COLUMN_VIEW_LOAD_TIME] = view.viewLoadTime;
  values[FTSQL.RUM_COLUMN_VIEW_TIME_SPENT] = view.timeSpent;
  values[FTSQL.RUM_COLUMN_RESOURCE_COUNT] = view.resourceCount;
  values[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = view.pendingResource;
  values[FTSQL.RUM_DATA_UPDATE_TIME] = view.dataUpdateTime;
  values[FTSQL.RUM_DATA_UPLOAD_TIME] = view.dataUploadTime;
  values[FTSQL.RUM_VIEW_UPDATE_TIME] = view.viewUpdateTime;
  values[FTSQL.RUM_COLUMN_EXTRA_ATTR] = stringifyViewExtraAttr(view);
  return values;
}

function toActionValues(actionBean: ActionBeanJSON): relationalStore.ValuesBucket {
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RUM_COLUMN_ID] = actionBean.id;
  values[FTSQL.RUM_COLUMN_START_TIME] = actionBean.startTime;
  values[FTSQL.RUM_COLUMN_ACTION_DURATION] = actionBean.actionDuration;
  values[FTSQL.RUM_COLUMN_IS_CLOSE] = actionBean.isClose ? 1 : 0;
  values[FTSQL.RUM_COLUMN_ERROR_COUNT] = actionBean.errorCount;
  values[FTSQL.RUM_COLUMN_LONG_TASK_COUNT] = actionBean.longTaskCount;
  values[FTSQL.RUM_COLUMN_RESOURCE_COUNT] = actionBean.resourceCount;
  values[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = actionBean.pendingResource;
  values[FTSQL.RUM_COLUMN_SESSION_ID] = actionBean.sessionId;
  values[FTSQL.RUM_COLUMN_VIEW_NAME] = actionBean.viewName;
  values[FTSQL.RUM_COLUMN_VIEW_ID] = actionBean.viewId;
  values[FTSQL.RUM_COLUMN_VIEW_REFERRER] = actionBean.viewReferrer;
  values[FTSQL.RUM_COLUMN_ACTION_NAME] = actionBean.actionName;
  values[FTSQL.RUM_COLUMN_ACTION_TYPE] = actionBean.actionType;
  values[FTSQL.RUM_COLUMN_EXTRA_ATTR] = stringifyActionExtraAttr(actionBean);
  return values;
}

function readViewFromResultSet(resultSet: relationalStore.ResultSet): ViewBeanJSON {
  const attr = splitViewExtraAttr(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_EXTRA_ATTR)));
  const startTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
  return {
    id: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ID)),
    viewName: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_NAME)),
    viewReferrer: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_REFERRER)),
    startTime: startTimeStr ? Number.parseInt(startTimeStr, 10) : 0,
    isClose: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_IS_CLOSE)) === 1,
    sessionId: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_SESSION_ID)),
    actionCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_COUNT)),
    errorCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)),
    longTaskCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)),
    viewLoadTime: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_LOAD_TIME)),
    timeSpent: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_TIME_SPENT)),
    resourceCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT)),
    pendingResource: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE)),
    dataUpdateTime: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPDATE_TIME)),
    dataUploadTime: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_DATA_UPLOAD_TIME)),
    viewUpdateTime: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME)),
    extraAttr: attr.extraAttr,
    property: attr.property,
    tags: attr.tags
  };
}

function readActionFromResultSet(resultSet: relationalStore.ResultSet): ActionBeanJSON {
  const startTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
  return {
    id: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ID)),
    startTime: startTimeStr ? Number.parseInt(startTimeStr, 10) : 0,
    actionDuration: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_DURATION)),
    isClose: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_IS_CLOSE)) === 1,
    errorCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)),
    longTaskCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)),
    resourceCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT)),
    pendingResource: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE)),
    sessionId: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_SESSION_ID)),
    viewName: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_NAME)),
    viewId: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_ID)),
    viewReferrer: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_VIEW_REFERRER)),
    actionName: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_NAME)),
    actionType: resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_TYPE)),
    extraAttr: parseJsonRecord(resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_EXTRA_ATTR)))
  };
}

async function updateRumViewInTaskPool(
  rdbStore: relationalStore.RdbStore,
  view: ViewBeanJSON
): Promise<boolean> {
  if (!view.id || view.id.length === 0) {
    return false;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, view.id);
  const updated = await rdbStore.update(toViewValues(view, false), predicates);
  return updated > 0;
}

async function upsertRumViewInTaskPool(
  rdbStore: relationalStore.RdbStore,
  view: ViewBeanJSON
): Promise<boolean> {
  if (!view.id || view.id.length === 0) {
    return false;
  }
  try {
    const rowId = await rdbStore.insert(FTSQL.FT_TABLE_VIEW, toViewValues(view, true));
    return Number(rowId) > 0;
  } catch (error) {
    return await updateRumViewInTaskPool(rdbStore, view);
  }
}

async function closeRumViewInTaskPool(
  rdbStore: relationalStore.RdbStore,
  viewId: string,
  loadTime: number,
  timeSpent: number,
  attr: string,
  newSessionId: string,
  now: number
): Promise<boolean> {
  if (!viewId || viewId.length === 0) {
    return false;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, viewId);
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RUM_COLUMN_IS_CLOSE] = 1;
  values[FTSQL.RUM_COLUMN_VIEW_LOAD_TIME] = loadTime;
  values[FTSQL.RUM_COLUMN_VIEW_TIME_SPENT] = timeSpent;
  values[FTSQL.RUM_COLUMN_EXTRA_ATTR] = attr;
  values[FTSQL.RUM_DATA_UPDATE_TIME] = now;
  if (newSessionId && newSessionId.length > 0) {
    values[FTSQL.RUM_COLUMN_SESSION_ID] = newSessionId;
  }
  const updated = await rdbStore.update(values, predicates);
  return updated > 0;
}

async function updateViewUploadTimeInTaskPool(
  rdbStore: relationalStore.RdbStore,
  viewId: string,
  dateTime: number
): Promise<boolean> {
  if (!viewId || viewId.length === 0) {
    return false;
  }
  const queryPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  queryPredicates.equalTo(FTSQL.RUM_COLUMN_ID, viewId);
  const resultSet = await rdbStore.query(queryPredicates, [FTSQL.RUM_VIEW_UPDATE_TIME]);
  let currentUpdateTime = 0;
  try {
    if (!resultSet.goToFirstRow()) {
      return false;
    }
    currentUpdateTime = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_VIEW_UPDATE_TIME));
  } finally {
    resultSet.close();
  }
  const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, viewId);
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RUM_DATA_UPLOAD_TIME] = dateTime;
  values[FTSQL.RUM_VIEW_UPDATE_TIME] = currentUpdateTime + 1;
  const updated = await rdbStore.update(values, updatePredicates);
  return updated > 0;
}

async function increaseViewActionInTaskPool(
  rdbStore: relationalStore.RdbStore,
  viewId: string
): Promise<number> {
  if (!viewId || viewId.length === 0) {
    return 0;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, viewId);
  const values = {} as relationalStore.ValuesBucket;
  const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_ACTION_COUNT]);
  let currentCount = 0;
  try {
    if (!resultSet.goToFirstRow()) {
      return 0;
    }
    currentCount = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ACTION_COUNT));
  } finally {
    resultSet.close();
  }
  values[FTSQL.RUM_COLUMN_ACTION_COUNT] = currentCount + 1;
  return await rdbStore.update(values, predicates);
}

async function getRumPendingResourceInTaskPool(
  rdbStore: relationalStore.RdbStore,
  target: string,
  id: string
): Promise<number> {
  if (!id || id.length === 0) {
    return 0;
  }
  const predicates = new relationalStore.RdbPredicates(getRumTargetTable(target));
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, id);
  const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
  try {
    if (resultSet.goToFirstRow()) {
      return resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE));
    }
    return 0;
  } finally {
    resultSet.close();
  }
}

async function forceClearRumPendingResourceInTaskPool(
  rdbStore: relationalStore.RdbStore,
  target: string,
  id: string
): Promise<number> {
  if (!id || id.length === 0) {
    return 0;
  }
  const predicates = new relationalStore.RdbPredicates(getRumTargetTable(target));
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, id);
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = 0;
  return await rdbStore.update(values, predicates);
}

async function getActionInfoInTaskPool(
  rdbStore: relationalStore.RdbStore,
  actionId: string
): Promise<FTDBTaskPoolActionInfoDTO | null> {
  if (!actionId || actionId.length === 0) {
    return null;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, actionId);
  const resultSet = await rdbStore.query(predicates, [FTSQL.RUM_COLUMN_START_TIME]);
  try {
    if (!resultSet.goToFirstRow()) {
      return null;
    }
    const startTimeStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_START_TIME));
    return {
      startTime: startTimeStr ? Number.parseInt(startTimeStr, 10) : 0
    };
  } finally {
    resultSet.close();
  }
}

function appendPositiveCounterAssignment(assignments: string[], column: string, delta: number): void {
  const normalizedDelta = Math.max(0, Math.floor(delta));
  if (normalizedDelta > 0) {
    assignments.push(`${column} = ${column} + ${normalizedDelta}`);
  }
}

function appendPendingCounterAssignment(assignments: string[], column: string, delta: number): void {
  const normalizedDelta = Math.floor(delta);
  if (normalizedDelta > 0) {
    assignments.push(`${column} = ${column} + ${normalizedDelta}`);
  } else if (normalizedDelta < 0) {
    const decrement = Math.abs(normalizedDelta);
    assignments.push(`${column} = CASE WHEN ${column} > ${decrement} THEN ${column} - ${decrement} ELSE 0 END`);
  }
}

async function applyRumCounterDeltasInTaskPool(
  rdbStore: relationalStore.RdbStore,
  deltas: FTDBTaskPoolRumCounterDeltaDTO[],
  now: number
): Promise<number> {
  if (deltas.length === 0) {
    return 0;
  }
  let affected = 0;
  rdbStore.beginTransaction();
  try {
    // EVENT_CONSUMER finalizes one deterministic delta per View/Action ID.
    // This lane only applies the already-normalized DB mutation.
    for (let i = 0; i < deltas.length; i++) {
      const aggregate = deltas[i];
      if (!aggregate.viewId || aggregate.viewId.length === 0) {
        continue;
      }
      const assignments: string[] = [];
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_ACTION_COUNT, aggregate.viewActionDelta);
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_ERROR_COUNT, aggregate.viewErrorDelta);
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_LONG_TASK_COUNT, aggregate.viewLongTaskDelta);
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_RESOURCE_COUNT, aggregate.viewResourceDelta);
      appendPendingCounterAssignment(assignments, FTSQL.RUM_COLUMN_PENDING_RESOURCE, aggregate.viewPendingDelta);
      if (aggregate.viewUpdateTimeDelta > 0) {
        assignments.push(`${FTSQL.RUM_VIEW_UPDATE_TIME} = ${FTSQL.RUM_VIEW_UPDATE_TIME} + ${Math.floor(aggregate.viewUpdateTimeDelta)}`);
        assignments.push(`${FTSQL.RUM_DATA_UPDATE_TIME} = ${now}`);
      }
      if (assignments.length > 0) {
        await rdbStore.executeSql(
          `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ${assignments.join(', ')} ` +
          `WHERE ${FTSQL.RUM_COLUMN_ID} = '${escapeSqlString(aggregate.viewId)}'`
        );
        affected++;
      }
    }

    for (let i = 0; i < deltas.length; i++) {
      const aggregate = deltas[i];
      if (!aggregate.actionId || aggregate.actionId.length === 0) {
        continue;
      }
      const assignments: string[] = [];
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_ERROR_COUNT, aggregate.actionErrorDelta);
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_LONG_TASK_COUNT, aggregate.actionLongTaskDelta);
      appendPositiveCounterAssignment(assignments, FTSQL.RUM_COLUMN_RESOURCE_COUNT, aggregate.actionResourceDelta);
      appendPendingCounterAssignment(assignments, FTSQL.RUM_COLUMN_PENDING_RESOURCE, aggregate.actionPendingDelta);
      if (assignments.length > 0) {
        await rdbStore.executeSql(
          `UPDATE ${FTSQL.FT_TABLE_ACTION} SET ${assignments.join(', ')} ` +
          `WHERE ${FTSQL.RUM_COLUMN_ID} = '${escapeSqlString(aggregate.actionId)}'`
        );
        affected++;
      }
    }
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return affected;
}

async function updateViewUpdateTimeInTaskPool(
  rdbStore: relationalStore.RdbStore,
  viewId: string,
  now: number
): Promise<boolean> {
  if (!viewId || viewId.length === 0) {
    return false;
  }
  const updateSql =
    `UPDATE ${FTSQL.FT_TABLE_VIEW} SET ` +
    `${FTSQL.RUM_VIEW_UPDATE_TIME} = ${FTSQL.RUM_VIEW_UPDATE_TIME} + 1, ` +
    `${FTSQL.RUM_DATA_UPDATE_TIME} = ${now} ` +
    `WHERE ${FTSQL.RUM_COLUMN_ID} = '${escapeSqlString(viewId)}'`;
  await rdbStore.executeSql(updateSql);
  return true;
}

async function insertRumActionInTaskPool(
  rdbStore: relationalStore.RdbStore,
  actionBean: ActionBeanJSON
): Promise<boolean> {
  if (!actionBean.id || actionBean.id.length === 0) {
    return false;
  }
  const rowId = await rdbStore.insert(FTSQL.FT_TABLE_ACTION, toActionValues(actionBean));
  return Number(rowId) > 0;
}

async function closeRumActionInTaskPool(
  rdbStore: relationalStore.RdbStore,
  actionId: string,
  duration: number,
  force: boolean
): Promise<FTDBTaskPoolCloseActionResponse> {
  const response: FTDBTaskPoolCloseActionResponse = {
    wasClosed: false,
    hadPendingResource: false
  };
  if (!actionId || actionId.length === 0) {
    return response;
  }
  const queryPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  queryPredicates.equalTo(FTSQL.RUM_COLUMN_ID, actionId);
  const resultSet = await rdbStore.query(queryPredicates, [FTSQL.RUM_COLUMN_PENDING_RESOURCE]);
  let pendingResource = 0;
  try {
    if (!resultSet.goToFirstRow()) {
      return response;
    }
    pendingResource = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_PENDING_RESOURCE));
  } finally {
    resultSet.close();
  }
  if (!force && pendingResource > 0) {
    response.hadPendingResource = true;
    return response;
  }
  const updatePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  updatePredicates.equalTo(FTSQL.RUM_COLUMN_ID, actionId);
  const values = {} as relationalStore.ValuesBucket;
  values[FTSQL.RUM_COLUMN_IS_CLOSE] = 1;
  values[FTSQL.RUM_COLUMN_ACTION_DURATION] = duration;
  const updated = await rdbStore.update(values, updatePredicates);
  response.wasClosed = updated > 0;
  response.hadPendingResource = pendingResource > 0;
  return response;
}

async function querySumActionInTaskPool(
  rdbStore: relationalStore.RdbStore,
  limit: number
): Promise<ActionBeanJSON[]> {
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  predicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
  predicates.orderByAsc(FTSQL.RUM_COLUMN_START_TIME);
  predicates.limitAs(limit);
  const resultSet = await rdbStore.query(predicates);
  const result: ActionBeanJSON[] = [];
  try {
    if (resultSet.goToFirstRow()) {
      do {
        result.push(readActionFromResultSet(resultSet));
      } while (resultSet.goToNextRow());
    }
  } finally {
    resultSet.close();
  }
  return result;
}

async function getActionCountsInTaskPool(
  rdbStore: relationalStore.RdbStore,
  actionId: string
): Promise<FTDBTaskPoolActionCountsDTO | null> {
  if (!actionId || actionId.length === 0) {
    return null;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, actionId);
  const resultSet = await rdbStore.query(predicates, [
    FTSQL.RUM_COLUMN_ERROR_COUNT,
    FTSQL.RUM_COLUMN_LONG_TASK_COUNT,
    FTSQL.RUM_COLUMN_RESOURCE_COUNT
  ]);
  try {
    if (!resultSet.goToFirstRow()) {
      return null;
    }
    return {
      errorCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_ERROR_COUNT)),
      longTaskCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_LONG_TASK_COUNT)),
      resourceCount: resultSet.getLong(resultSet.getColumnIndex(FTSQL.RUM_COLUMN_RESOURCE_COUNT))
    };
  } finally {
    resultSet.close();
  }
}

async function querySumViewInTaskPool(
  rdbStore: relationalStore.RdbStore,
  limit: number
): Promise<ViewBeanJSON[]> {
  const sql = `
    SELECT * FROM ${FTSQL.FT_TABLE_VIEW}
    WHERE (
      ${FTSQL.RUM_COLUMN_IS_CLOSE} = 0
      OR (
        ${FTSQL.RUM_COLUMN_IS_CLOSE} = 1 AND (
          ${FTSQL.RUM_DATA_UPLOAD_TIME} = 0
          OR ${FTSQL.RUM_DATA_UPLOAD_TIME} < ${FTSQL.RUM_DATA_UPDATE_TIME}
        )
      )
    )
    ORDER BY ${FTSQL.RUM_COLUMN_START_TIME} ASC
    LIMIT ${limit}
  `;
  const resultSet = await rdbStore.querySql(sql);
  const result: ViewBeanJSON[] = [];
  try {
    if (resultSet.goToFirstRow()) {
      do {
        result.push(readViewFromResultSet(resultSet));
      } while (resultSet.goToNextRow());
    }
  } finally {
    resultSet.close();
  }
  return result;
}

async function queryRumViewByIdInTaskPool(
  rdbStore: relationalStore.RdbStore,
  viewId: string
): Promise<ViewBeanJSON | null> {
  if (!viewId || viewId.length === 0) {
    return null;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
  predicates.equalTo(FTSQL.RUM_COLUMN_ID, viewId);
  const resultSet = await rdbStore.query(predicates);
  try {
    if (resultSet.goToFirstRow()) {
      return readViewFromResultSet(resultSet);
    }
    return null;
  } finally {
    resultSet.close();
  }
}

async function cleanCloseActionDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  ids: string[]
): Promise<number> {
  if (ids.length === 0) {
    return 0;
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION);
  predicates.in(FTSQL.RUM_COLUMN_ID, ids);
  return await rdbStore.delete(predicates);
}

async function cleanCloseViewDataInTaskPool(
  rdbStore: relationalStore.RdbStore,
  ids: string[],
  now: number
): Promise<number> {
  const staleViewThresholdMs = 5 * 60 * 1000;
  let deleted = 0;
  rdbStore.beginTransaction();
  try {
    if (ids.length > 0) {
      for (let i = 0; i < ids.length; i++) {
        const predicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
        predicates.equalTo(FTSQL.RUM_COLUMN_ID, ids[i]);
        predicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
        predicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
        deleted += await rdbStore.delete(predicates);
      }
    } else {
      const normalPredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
      normalPredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
      normalPredicates.lessThanOrEqualTo(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
      deleted += await rdbStore.delete(normalPredicates);

      const stalePredicates = new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW);
      stalePredicates.equalTo(FTSQL.RUM_COLUMN_IS_CLOSE, 1);
      stalePredicates.greaterThan(FTSQL.RUM_COLUMN_PENDING_RESOURCE, 0);
      stalePredicates.lessThanOrEqualTo(FTSQL.RUM_DATA_UPDATE_TIME, now - staleViewThresholdMs);
      deleted += await rdbStore.delete(stalePredicates);
    }
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return deleted;
}

async function closeAllActionAndViewInTaskPool(
  rdbStore: relationalStore.RdbStore,
  now: number
): Promise<number> {
  let updated = 0;
  rdbStore.beginTransaction();
  try {
    const viewValues = {} as relationalStore.ValuesBucket;
    viewValues[FTSQL.RUM_COLUMN_IS_CLOSE] = 1;
    viewValues[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = 0;
    viewValues[FTSQL.RUM_DATA_UPDATE_TIME] = now;
    updated += await rdbStore.update(viewValues, new relationalStore.RdbPredicates(FTSQL.FT_TABLE_VIEW));

    const actionValues = {} as relationalStore.ValuesBucket;
    actionValues[FTSQL.RUM_COLUMN_IS_CLOSE] = 1;
    actionValues[FTSQL.RUM_COLUMN_PENDING_RESOURCE] = 0;
    updated += await rdbStore.update(actionValues, new relationalStore.RdbPredicates(FTSQL.FT_TABLE_ACTION));
    rdbStore.commit();
  } catch (error) {
    rdbStore.rollBack();
    throw new Error(String(error));
  }
  return updated;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function queryRelatedUUIDsByActionIdInTaskPool(
  rdbStore: relationalStore.RdbStore,
  actionId: string,
  measurementType: string,
  dataType: string
): Promise<string[]> {
  if (!actionId || actionId.length === 0 || !measurementType || measurementType.length === 0) {
    return [];
  }
  const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
  predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, dataType);
  const resultSet = await rdbStore.query(predicates, [FTSQL.RECORD_COLUMN_DATA, FTSQL.RECORD_COLUMN_DATA_UUID]);
  const result: string[] = [];
  const actionIdPattern = new RegExp(`(^|,)action_id=${escapeRegExp(actionId)}(,|$)`, 'g');
  try {
    if (resultSet.goToFirstRow()) {
      do {
        const dataStr = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA));
        const uuid = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID));
        if (!dataStr || !uuid) {
          continue;
        }
        const measurementMatch = dataStr.startsWith(`${measurementType},`) ||
          dataStr.startsWith(`${measurementType} `);
        if (!measurementMatch) {
          continue;
        }
        const firstSpaceIndex = dataStr.indexOf(' ');
        const tagsSection = firstSpaceIndex > 0 ? dataStr.substring(0, firstSpaceIndex) : dataStr;
        actionIdPattern.lastIndex = 0;
        if (actionIdPattern.test(tagsSection)) {
          result.push(uuid);
        }
      } while (resultSet.goToNextRow());
    }
  } finally {
    resultSet.close();
  }
  return result;
}
