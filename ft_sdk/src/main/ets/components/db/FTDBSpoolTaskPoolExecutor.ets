import taskpool from '@ohos.taskpool';
import { SyncDataJSON } from './bean/SyncData';
import { runFTDBSpoolTaskPoolExecute } from './FTDBSpoolTaskPoolOperations';
import { FT_DB_SPOOL_MAX_BYTES } from './FTDBSpoolLimits';
import { FTCacheContext, FTCacheSettings } from './FTCacheContext';
import { runFTCacheSpool } from './FTCacheSpool';

enum FTDBSpoolTaskPoolCommand {
  INIT = 'init',
  APPEND = 'append',
  PREPARE_REPLAY = 'prepareReplay',
  ACK_REPLAY = 'ackReplay',
  CLEAR = 'clear',
  REMOVE_BY_UUIDS = 'removeByUuids',
  READ_PAGE = 'readPage',
  HAS_MARKER = 'hasMarker',
  WRITE_MARKER = 'writeMarker'
}

export interface FTDBSpoolPaths {
  spoolDir: string;
  activePath: string;
  inflightPath: string;
  legacyPath: string;
}

export interface FTDBSpoolRecordDTO {
  source: string;
  seq: number;
  createdAt: number;
  data: SyncDataJSON;
}

export interface FTDBSpoolTaskPoolRequest extends FTDBSpoolPaths {
  cache?: FTCacheSettings;
  filesDir?: string;
  databaseDir?: string;
  command: string;
  source?: string;
  seqStart?: number;
  records?: SyncDataJSON[];
  batchToken?: string;
  byteOffset?: number;
  recordLimit?: number;
  maxCapacityBytes?: number;
  uuids?: string[];
  readPath?: string;
  markerPath?: string;
}

export interface FTDBSpoolTaskPoolResponse {
  ok: boolean;
  appendedRecords: number;
  rejectedRecords: number;
  pendingRecords: number;
  pendingRecordsKnown: boolean;
  pendingBytes: number;
  capacityBytes: number;
  batchToken: string;
  batchFileRecords: number;
  skippedRecords: number;
  records: FTDBSpoolRecordDTO[];
  pageStartByteOffset: number;
  nextByteOffset: number;
  inflightBytes: number;
  hasMoreRecords: boolean;
  removedRecords: number;
  markerExists: boolean;
  errorMessage: string;
}

export class FTDBSpoolTaskPoolExecutor {
  private static spoolLaneTail: Promise<void> = Promise.resolve();

  public static async init(paths: FTDBSpoolPaths): Promise<FTDBSpoolTaskPoolResponse> {
    return await FTDBSpoolTaskPoolExecutor.execute(
      FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.INIT, paths)
    );
  }

  public static async append(
    paths: FTDBSpoolPaths,
    source: string,
    seqStart: number,
    records: SyncDataJSON[],
    maxCapacityBytes: number = FT_DB_SPOOL_MAX_BYTES
  ): Promise<FTDBSpoolTaskPoolResponse> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.APPEND, paths);
    request.source = source;
    request.seqStart = seqStart;
    request.records = records;
    request.maxCapacityBytes = Math.max(1, Math.floor(maxCapacityBytes));
    return await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  public static async prepareReplay(
    paths: FTDBSpoolPaths,
    byteOffset: number = 0,
    recordLimit: number = 256
  ): Promise<FTDBSpoolTaskPoolResponse> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.PREPARE_REPLAY, paths);
    request.byteOffset = Math.max(0, Math.floor(byteOffset));
    request.recordLimit = Math.max(1, Math.floor(recordLimit));
    return await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  public static async ackReplay(
    paths: FTDBSpoolPaths,
    batchToken: string
  ): Promise<FTDBSpoolTaskPoolResponse> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.ACK_REPLAY, paths);
    request.batchToken = batchToken;
    return await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  public static async clear(paths: FTDBSpoolPaths): Promise<FTDBSpoolTaskPoolResponse> {
    return await FTDBSpoolTaskPoolExecutor.execute(
      FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.CLEAR, paths)
    );
  }

  public static async removeByUuids(
    paths: FTDBSpoolPaths,
    uuids: string[],
    maxCapacityBytes: number = FT_DB_SPOOL_MAX_BYTES
  ): Promise<FTDBSpoolTaskPoolResponse> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.REMOVE_BY_UUIDS, paths);
    request.uuids = uuids;
    request.maxCapacityBytes = Math.max(1, Math.floor(maxCapacityBytes));
    return await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  public static async readPage(
    paths: FTDBSpoolPaths,
    readPath: string,
    byteOffset: number = 0,
    recordLimit: number = 256
  ): Promise<FTDBSpoolTaskPoolResponse> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.READ_PAGE, paths);
    request.readPath = readPath;
    request.byteOffset = Math.max(0, Math.floor(byteOffset));
    request.recordLimit = Math.max(1, Math.floor(recordLimit));
    return await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  public static async hasMarker(paths: FTDBSpoolPaths, markerPath: string): Promise<boolean> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.HAS_MARKER, paths);
    request.markerPath = markerPath;
    const response = await FTDBSpoolTaskPoolExecutor.execute(request);
    return response.markerExists === true;
  }

  public static async writeMarker(paths: FTDBSpoolPaths, markerPath: string): Promise<void> {
    const request = FTDBSpoolTaskPoolExecutor.createRequest(FTDBSpoolTaskPoolCommand.WRITE_MARKER, paths);
    request.markerPath = markerPath;
    await FTDBSpoolTaskPoolExecutor.execute(request);
  }

  private static createRequest(
    command: FTDBSpoolTaskPoolCommand,
    paths: FTDBSpoolPaths
  ): FTDBSpoolTaskPoolRequest {
    return {
      command,
      spoolDir: paths.spoolDir,
      activePath: paths.activePath,
      inflightPath: paths.inflightPath,
      legacyPath: paths.legacyPath
    };
  }

  private static async execute(request: FTDBSpoolTaskPoolRequest): Promise<FTDBSpoolTaskPoolResponse> {
    const run = async (): Promise<FTDBSpoolTaskPoolResponse> => {
      request.cache = FTCacheContext.settings;
      request.filesDir = FTCacheContext.filesDir;
      request.databaseDir = FTCacheContext.databaseDir;
      const response = await taskpool.execute(ftDBSpoolTaskPoolExecute, request as Object, FTCacheContext.context as Object);
      const typed = response as Object as FTDBSpoolTaskPoolResponse;
      if (!typed.ok) {
        throw new Error(typed.errorMessage || `Spool TaskPool command failed: ${request.command}`);
      }
      return typed;
    };
    const current = FTCacheContext.lane.then(run, run);
    FTCacheContext.lane = current.then(() => undefined, () => undefined);
    return await current;
  }
}

@Concurrent
async function ftDBSpoolTaskPoolExecute(requestObject: Object, contextObject: Object): Promise<Object> {
  return await runFTCacheSpool(requestObject, contextObject);
}
