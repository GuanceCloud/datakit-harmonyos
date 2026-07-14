import { Context } from '@kit.AbilityKit';
import taskpool from '@ohos.taskpool';
import { SyncData, SyncDataJSON } from './bean/SyncData';
import { ActionBean, ActionBeanJSON } from './bean/ActionBean';
import { ViewBean, ViewBeanJSON } from './bean/ViewBean';
import { runFTDBTaskPoolExecute } from './FTDBTaskPoolOperations';
import { SDKUploadRowDTO } from '../thread/SDKWorkerProtocol';

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

export interface FTDBTaskPoolUploadPage {
  rows: SDKUploadRowDTO[];
  hasMore: boolean;
  transportBytes: number;
  byteLimitReached: boolean;
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
  drafts?: FTDBTaskPoolSyncDraftDTO[];
  fallbackDataType?: string;
  options?: FTDBTaskPoolWriteOptions;
  policy?: FTDBTaskPoolCachePolicySnapshot;
  rowIds?: number[];
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

export class FTDBTaskPoolExecutor {
  private static dbLaneTail: Promise<void> = Promise.resolve();

  public static async init(context: Context): Promise<void> {
    await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.INIT
    });
  }

  public static async hasSyncData(context: Context, dataTypes: string[]): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.HAS_SYNC_DATA,
      dataTypes
    });
    return response.value === true;
  }

  public static async querySyncData(
    context: Context,
    dataTypes: string[],
    limit: number,
    newestFirst: boolean = false
  ): Promise<SyncData[]> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_SYNC_DATA,
      dataTypes,
      limit,
      newestFirst
    });
    const rows = response.rows || [];
    const result: SyncData[] = [];
    for (let i = 0; i < rows.length; i++) {
      result.push(SyncData.fromJSON(rows[i]));
    }
    return result;
  }

  public static async queryUploadData(
    context: Context,
    dataTypes: string[],
    limit: number,
    maxBytes: number
  ): Promise<FTDBTaskPoolUploadPage> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_UPLOAD_DATA,
      dataTypes,
      limit,
      maxBytes
    });
    return {
      rows: response.uploadRows || [],
      hasMore: response.hasMore === true,
      transportBytes: Math.max(0, response.byteCount || 0),
      byteLimitReached: response.byteLimitReached === true
    };
  }

  public static async writeSyncData(
    context: Context,
    source: string,
    records: SyncData[],
    options: FTDBTaskPoolWriteOptions,
    policy: FTDBTaskPoolCachePolicySnapshot
  ): Promise<FTDBTaskPoolWriteResponse> {
    const payload: SyncDataJSON[] = [];
    for (let i = 0; i < records.length; i++) {
      payload.push(records[i].toJSON());
    }
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.WRITE_SYNC_DATA,
      source,
      records: payload,
      options,
      policy
    });
    if (!response.write) {
      throw new Error(response.errorMessage || 'DB taskpool write returned empty response');
    }
    response.write.dbLaneWaitMs = response.dbLaneWaitMs || 0;
    return response.write;
  }

  public static async writeSyncDrafts(
    context: Context,
    source: string,
    drafts: FTDBTaskPoolSyncDraftDTO[],
    fallbackDataType: string,
    options: FTDBTaskPoolWriteOptions,
    policy: FTDBTaskPoolCachePolicySnapshot
  ): Promise<FTDBTaskPoolWriteResponse> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.WRITE_SYNC_DRAFTS,
      source,
      drafts,
      fallbackDataType,
      options,
      policy
    });
    if (!response.write) {
      throw new Error(response.errorMessage || 'DB taskpool draft write returned empty response');
    }
    response.write.dbLaneWaitMs = response.dbLaneWaitMs || 0;
    return response.write;
  }

  public static async deleteSyncRows(context: Context, records: SyncData[]): Promise<number> {
    const payload: SyncDataJSON[] = [];
    for (let i = 0; i < records.length; i++) {
      payload.push(records[i].toJSON());
    }
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.DELETE_SYNC_ROWS,
      records: payload
    });
    return response.count || 0;
  }

  public static async deleteSyncRowIds(context: Context, rowIds: number[]): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.DELETE_SYNC_ROW_IDS,
      rowIds
    });
    return response.count || 0;
  }

  public static async queryTotalCount(context: Context, dataTypes: string[]): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_TOTAL_COUNT,
      dataTypes
    });
    return response.count || 0;
  }

  public static async getCurrentDatabaseSize(context: Context): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.GET_DB_SIZE
    });
    return response.count || 0;
  }

  public static async deleteOldestSyncData(context: Context, dataTypes: string[], limit: number): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.DELETE_OLDEST_SYNC_DATA,
      dataTypes,
      limit
    });
    return response.count || 0;
  }

  public static async updateDataType(context: Context, dataType: string, errorTimeLine: number): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPDATE_DATA_TYPE,
      dataType,
      errorTimeLine
    });
    return response.count || 0;
  }

  public static async deleteExpireCache(
    context: Context,
    dataType: string,
    now: number,
    duration: number
  ): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.DELETE_EXPIRE_CACHE,
      dataType,
      now,
      duration
    });
    return response.count || 0;
  }

  public static async maintainErrorSampled(
    context: Context,
    dataType: string,
    errorTimeLine: number,
    now: number,
    duration: number
  ): Promise<FTDBTaskPoolMaintenanceResponse> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.ERROR_SAMPLED_MAINTENANCE,
      dataType,
      errorTimeLine,
      now,
      duration
    });
    const maintenance = response.maintenance || {
      updatedRows: 0,
      deletedRows: 0,
      dbLaneWaitMs: 0
    };
    maintenance.dbLaneWaitMs = response.dbLaneWaitMs || 0;
    return maintenance;
  }

  public static async uploadCommit(
    context: Context,
    dataType: string,
    action: string,
    records: SyncData[],
    reInsertRecords: SyncData[],
    reduceCount: number
  ): Promise<FTDBTaskPoolUploadCommitResponse> {
    const payload: SyncDataJSON[] = [];
    const reInsertPayload: SyncDataJSON[] = [];
    for (let i = 0; i < records.length; i++) {
      payload.push(records[i].toJSON());
    }
    for (let i = 0; i < reInsertRecords.length; i++) {
      reInsertPayload.push(reInsertRecords[i].toJSON());
    }
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPLOAD_COMMIT,
      dataType,
      commitAction: action,
      records: payload,
      reInsertRecords: reInsertPayload,
      reduceCount
    });
    const commit = response.uploadCommit || {
      deletedRows: 0,
      insertedRows: 0,
      affectedRows: 0,
      logCountDelta: 0,
      rumCountDelta: 0,
      dbLaneWaitMs: 0
    };
    commit.dbLaneWaitMs = response.dbLaneWaitMs || 0;
    return commit;
  }

  public static async deleteAll(context: Context): Promise<FTDBTaskPoolDeleteAllResult> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.DELETE_ALL
    });
    return response.deleteAll || { sync: 0, view: 0, action: 0 };
  }

  public static async cleanupExpiredRumView(context: Context, cutoffTime: number): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLEANUP_EXPIRED_RUM_VIEW,
      cutoffTime
    });
    return response.count || 0;
  }

  public static async cleanupExpiredRumAction(context: Context, cutoffTime: number): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLEANUP_EXPIRED_RUM_ACTION,
      cutoffTime
    });
    return response.count || 0;
  }

  public static async awaitIdle(context: Context): Promise<void> {
    await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.INIT
    });
  }

  public static async upsertRumView(context: Context, viewBean: ViewBean): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPSERT_RUM_VIEW,
      view: viewBean.toJSON()
    });
    return response.value === true;
  }

  public static async updateRumView(context: Context, viewBean: ViewBean): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPDATE_RUM_VIEW,
      view: viewBean.toJSON()
    });
    return response.value === true;
  }

  public static async closeRumView(
    context: Context,
    viewId: string,
    loadTime: number,
    timeSpent: number,
    attr: string,
    newSessionId?: string
  ): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLOSE_RUM_VIEW,
      viewId,
      loadTime,
      timeSpent,
      attr,
      newSessionId,
      now: Date.now()
    });
    return response.value === true;
  }

  public static async updateViewUploadTime(context: Context, viewId: string, dateTime: number): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPDATE_VIEW_UPLOAD_TIME,
      viewId,
      dateTime
    });
    return response.value === true;
  }

  public static async increaseViewAction(context: Context, viewId: string): Promise<void> {
    await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.INCREASE_VIEW_ACTION,
      viewId
    });
  }

  public static async getRumPendingResource(context: Context, target: string, id: string): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.GET_RUM_PENDING_RESOURCE,
      target,
      ids: [id]
    });
    return response.count || 0;
  }

  public static async forceClearRumPendingResource(context: Context, target: string, id: string): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.FORCE_CLEAR_RUM_PENDING_RESOURCE,
      target,
      ids: [id]
    });
    return response.count || 0;
  }

  public static async getActionInfo(context: Context, actionId: string): Promise<FTDBTaskPoolActionInfoDTO | null> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.GET_ACTION_INFO,
      actionId
    });
    return response.actionInfo || null;
  }

  public static async applyRumCounterDeltas(
    context: Context,
    deltas: FTDBTaskPoolRumCounterDeltaDTO[]
  ): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.APPLY_RUM_COUNTER_DELTAS,
      counterDeltas: deltas,
      now: Date.now()
    });
    return response.count || 0;
  }

  public static async updateViewUpdateTime(context: Context, viewId: string): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.UPDATE_VIEW_UPDATE_TIME,
      viewId,
      now: Date.now()
    });
    return response.value === true;
  }

  public static async insertRumAction(context: Context, actionBean: ActionBean): Promise<boolean> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.INSERT_RUM_ACTION,
      actionBean: actionBean.toJSON()
    });
    return response.value === true;
  }

  public static async closeRumAction(
    context: Context,
    actionId: string,
    duration: number,
    force: boolean
  ): Promise<FTDBTaskPoolCloseActionResponse> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLOSE_RUM_ACTION,
      actionId,
      duration,
      force
    });
    return response.closeAction || {
      wasClosed: false,
      hadPendingResource: false
    };
  }

  public static async querySumAction(context: Context, limit: number): Promise<ActionBean[]> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_SUM_ACTION,
      limit
    });
    const rows = response.actions || [];
    const result: ActionBean[] = [];
    for (let i = 0; i < rows.length; i++) {
      result.push(ActionBean.fromJSON(rows[i]));
    }
    return result;
  }

  public static async getActionCounts(context: Context, actionId: string): Promise<FTDBTaskPoolActionCountsDTO | null> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.GET_ACTION_COUNTS,
      actionId
    });
    return response.actionCounts || null;
  }

  public static async querySumView(context: Context, limit: number): Promise<ViewBean[]> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_SUM_VIEW,
      limit
    });
    const rows = response.views || [];
    const result: ViewBean[] = [];
    for (let i = 0; i < rows.length; i++) {
      result.push(ViewBean.fromJSON(rows[i]));
    }
    return result;
  }

  public static async queryRumViewById(context: Context, viewId: string): Promise<ViewBean | null> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_RUM_VIEW_BY_ID,
      viewId
    });
    return response.view ? ViewBean.fromJSON(response.view) : null;
  }

  public static async cleanCloseActionData(context: Context, ids: string[]): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLEAN_CLOSE_ACTION_DATA,
      ids
    });
    return response.count || 0;
  }

  public static async cleanCloseViewData(context: Context, ids?: string[]): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLEAN_CLOSE_VIEW_DATA,
      ids: ids || [],
      now: Date.now()
    });
    return response.count || 0;
  }

  public static async closeAllActionAndView(context: Context): Promise<number> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.CLOSE_ALL_ACTION_AND_VIEW,
      now: Date.now()
    });
    return response.count || 0;
  }

  public static async queryRelatedUUIDsByActionId(
    context: Context,
    actionId: string,
    measurementType: string,
    dataType: string
  ): Promise<string[]> {
    const response = await FTDBTaskPoolExecutor.execute(context, {
      command: FTDBTaskPoolCommand.QUERY_RELATED_UUIDS_BY_ACTION_ID,
      actionId,
      measurementType,
      dataType
    });
    return response.strings || [];
  }

  private static async execute(context: Context, request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    const enqueueTime = Date.now();
    const run = async (): Promise<FTDBTaskPoolResponse> => {
      const dbLaneWaitMs = Math.max(0, Date.now() - enqueueTime);
      const response = await taskpool.execute(ftDBTaskPoolExecute, context as Object, request as Object);
      const typed = response as Object as FTDBTaskPoolResponse;
      typed.dbLaneWaitMs = dbLaneWaitMs;
      if (!typed.ok) {
        throw new Error(typed.errorMessage || `DB taskpool command failed: ${request.command}`);
      }
      return typed;
    };

    const current = FTDBTaskPoolExecutor.dbLaneTail.then(run, run);
    FTDBTaskPoolExecutor.dbLaneTail = current.then(() => undefined, () => undefined);
    return await current;
  }
}

@Concurrent
async function ftDBTaskPoolExecute(contextObject: Object, requestObject: Object): Promise<Object> {
  return await runFTDBTaskPoolExecute(contextObject, requestObject);
}
