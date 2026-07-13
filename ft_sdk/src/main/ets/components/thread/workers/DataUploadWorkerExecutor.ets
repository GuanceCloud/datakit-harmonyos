import { DataType } from '../../enum/Enums';
import { FTInnerLogger } from '../../log/FTLogger';
import {
  SDKDedicatedPoolType,
  SDKUploadCheckpointDTO,
  SDKUploadCommitPageDTO,
  SDKUploadCommitPageResultDTO,
  SDKUploadDbActionDTO,
  SDKUploadExecutePageDTO,
  SDKUploadExecutePageResultDTO,
  SDKUploadPageOutcome,
  SDKUploadRoundFinishDTO,
  SDKUploadRoundResultDTO,
  SDKUploadRoundStartDTO,
  SDKUploadRoundStartResultDTO,
  SDKUploadRowDTO,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../SDKWorkerProtocol';
import {
  DataUploadConsumeMetrics,
  DataUploadConsumeOptions,
  DataUploadConsumeResult,
  DataUploadDbCommitAction,
  DataUploadDbMaintenanceResult,
  DataUploadQueryPage,
  DataUploadRow,
  DataUploadWorkerCapabilities
} from './DataUploadWorkerCapabilities';
import {
  DATA_UPLOAD_MAX_BODY_BYTES,
  DATA_UPLOAD_LIMIT_RETRY_DELAY_MS,
  DATA_UPLOAD_MAX_PAGE_SIZE,
  DATA_UPLOAD_MAX_RETRY_COUNT
} from './DataUploadLimits';

const TAG = 'DataUploadWorker';

interface DataUploadConsumeState {
  consumedRows: number;
  hasMoreData: boolean;
  errorCount: number;
  startedAt: number;
  metrics: DataUploadConsumeMetrics;
}

/**
 * Host-side upload orchestrator.
 *
 * DB capabilities remain TaskPool-backed. Page preparation, HTTPS, response
 * classification, page budgets, and retry state execute as one asynchronous
 * DATA_UPLOAD ThreadWorker command. Host code only orchestrates DB commit and
 * persists a lightweight serializable worker checkpoint.
 */
export class DataUploadWorkerExecutor {
  private static readonly ONE_MINUTE_DURATION_NS = 60_000_000_000;
  private static readonly ERROR_SAMPLED_SUFFIX = '_error_sampled';
  private static commandSequence: number = 0;

  private readonly syncMap: DataType[] = [DataType.RUM_APP, DataType.RUM_WEBVIEW, DataType.LOG];
  private readonly errorSampledSyncMap: DataType[] = [DataType.RUM_APP, DataType.RUM_WEBVIEW];
  private ownerId: string = '';
  private checkpoint: SDKUploadCheckpointDTO | null = null;

  public static resetStaticStateInternal(): void {
    DataUploadWorkerExecutor.commandSequence = 0;
  }

  public async consume(
    capabilities: DataUploadWorkerCapabilities,
    options: DataUploadConsumeOptions
  ): Promise<DataUploadConsumeResult> {
    const state = this.createConsumeState(capabilities);
    if (capabilities.isStopped()) {
      return this.createResult(state, capabilities);
    }

    let roundId = '';
    try {
      const roundStartPayload: SDKUploadRoundStartDTO = {
        ownerId: this.getOwnerId(capabilities),
        taskName: options.taskName || 'upload.poll',
        pageSize: this.normalizePageSize(options.pageSize),
        maxRetryCount: this.normalizeRetryCount(options.maxRetryCount),
        syncSleepTime: Math.max(0, options.syncSleepTime),
        checkpoint: this.checkpoint === null ? undefined : this.checkpoint
      };
      const startPayload = await this.executeUploadWorkerCommand(
        capabilities,
        SDKWorkerCommand.UPLOAD_CONSUME,
        roundStartPayload as Object as SDKWorkerPayload
      ) as Object as SDKUploadRoundStartResultDTO;
      if (!startPayload.accepted || !startPayload.roundId) {
        throw new Error('DATA_UPLOAD worker rejected upload round');
      }
      roundId = startPayload.roundId;
      this.adoptCheckpoint(startPayload.checkpoint);

      await this.maintainErrorSampledData(capabilities, options.errorTimeLine, state);
      for (let i = 0; i < this.syncMap.length; i++) {
        if (capabilities.isStopped()) {
          break;
        }
        await this.consumeDataType(capabilities, roundId, this.syncMap[i], startPayload.pageSize, state);
      }

      const finishPayload: SDKUploadRoundFinishDTO = { roundId };
      const roundResult = await this.executeUploadWorkerCommand(
        capabilities,
        SDKWorkerCommand.UPLOAD_CONSUME_FINISH,
        finishPayload as Object as SDKWorkerPayload
      ) as Object as SDKUploadRoundResultDTO;
      state.consumedRows = roundResult.consumedRows;
      state.hasMoreData = roundResult.hasMoreData;
      state.errorCount = roundResult.errorCount;
      state.metrics.computeMs = Math.max(state.metrics.computeMs, roundResult.computeMs);
      this.adoptCheckpoint(roundResult.checkpoint);
      roundId = '';
    } catch (error) {
      FTInnerLogger.e(TAG, `Sync Fail: ${error as string}`);
      state.hasMoreData = roundId.length > 0;
      if (roundId.length > 0) {
        await this.finishFailedRoundSilently(capabilities, roundId, state);
      }
    }

    return this.createResult(state, capabilities);
  }

  private createConsumeState(capabilities: DataUploadWorkerCapabilities): DataUploadConsumeState {
    return {
      consumedRows: 0,
      hasMoreData: false,
      errorCount: 0,
      startedAt: capabilities.getCurrentTimeMs(),
      metrics: {
        totalMs: 0,
        computeMs: 0,
        dbMs: 0,
        dbErrorSampledMs: 0,
        dbHasDataMs: 0,
        dbQueryMs: 0,
        dbDeleteMs: 0,
        dbInsertMs: 0,
        dbWriteQueueWaitMs: 0,
        httpMs: 0,
        sleepMs: 0,
        executeMs: 0,
        unaccountedMs: 0
      }
    };
  }

  private createResult(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities
  ): DataUploadConsumeResult {
    this.finishMetrics(state, capabilities);
    return {
      consumedRows: state.consumedRows,
      hasMoreData: state.hasMoreData,
      errorCount: state.errorCount,
      metrics: state.metrics
    };
  }

  private finishMetrics(state: DataUploadConsumeState, capabilities: DataUploadWorkerCapabilities): void {
    state.metrics.executeMs = state.metrics.dbMs + state.metrics.httpMs + state.metrics.sleepMs;
    const measuredTotal = Math.max(0, capabilities.getCurrentTimeMs() - state.startedAt);
    const accountedTime = state.metrics.computeMs + state.metrics.executeMs;
    state.metrics.unaccountedMs = Math.max(0, measuredTotal - accountedTime);
    state.metrics.totalMs = accountedTime + state.metrics.unaccountedMs;
  }

  private async maintainErrorSampledData(
    capabilities: DataUploadWorkerCapabilities,
    errorTimeLine: number,
    state: DataUploadConsumeState
  ): Promise<void> {
    for (let i = 0; i < this.errorSampledSyncMap.length; i++) {
      if (capabilities.isStopped()) {
        return;
      }
      const dataType = this.errorSampledSyncMap[i];
      const startedAt = capabilities.getCurrentTimeMs();
      try {
        const result = await capabilities.maintainErrorSampled(
          `${dataType.toString()}${DataUploadWorkerExecutor.ERROR_SAMPLED_SUFFIX}`,
          errorTimeLine,
          capabilities.getCurrentTimeMs() * 1_000_000,
          DataUploadWorkerExecutor.ONE_MINUTE_DURATION_NS
        );
        this.addDbMaintenanceMetrics(state, result);
      } catch (error) {
        FTInnerLogger.e(TAG, `errorSampledConsume failed: ${dataType}, error: ${error as string}`);
      } finally {
        const elapsed = this.elapsed(capabilities, startedAt);
        state.metrics.dbMs += elapsed;
        state.metrics.dbErrorSampledMs += elapsed;
      }
    }
  }

  private async consumeDataType(
    capabilities: DataUploadWorkerCapabilities,
    roundId: string,
    dataType: DataType,
    pageSize: number,
    state: DataUploadConsumeState
  ): Promise<void> {
    let shouldContinue = true;
    while (shouldContinue && !capabilities.isStopped()) {
      const queryPage = await this.queryRows(capabilities, dataType, pageSize, state);
      const rows = queryPage.rows;
      const executeRequest: SDKUploadExecutePageDTO = {
        roundId,
        dataType: dataType.toString(),
        rows: rows as Object as SDKUploadRowDTO[],
        queryHasMore: queryPage.hasMore,
        transportLimitReached: queryPage.byteLimitReached,
        httpConfig: capabilities.getHttpConfig(dataType),
        injectedHttpResult: rows.length > 0 ? capabilities.takeInjectedHttpResult?.() : undefined
      };
      const executed = await this.executeUploadWorkerCommand(
        capabilities,
        SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        executeRequest as Object as SDKWorkerPayload
      ) as Object as SDKUploadExecutePageResultDTO;
      state.metrics.computeMs += Math.max(0, executed.computeMs);
      state.metrics.httpMs += Math.max(0, executed.httpResult.elapsedMs);
      if (executed.duplicateRows > 0) {
        FTInnerLogger.w(TAG,
          `Deduplication filtered out ${executed.duplicateRows} duplicate record(s) for ${dataType}`);
      }
      if (!executed.rows || executed.rows.length === 0 || executed.attemptId.length === 0) {
        state.hasMoreData = state.hasMoreData || executed.roundHasMoreData;
        if (executed.delayMs > 0) {
          await this.sleep(capabilities, Math.max(DATA_UPLOAD_LIMIT_RETRY_DELAY_MS, executed.delayMs), state);
        }
        return;
      }

      if (executed.shouldUpload) {
        this.logPreparedUpload(dataType, executed.packageId, executed.acceptedRows,
          executed.bodyLength, executed.bodyBytes, executed.bodyLimitReached, executed.bodyPreview);
      } else if (executed.oversizedRows > 0) {
        FTInnerLogger.e(TAG,
          `Deferred ${executed.oversizedRows} oversized upload row(s) in DB: type=${dataType}, maxBodyBytes=${
            DATA_UPLOAD_MAX_BODY_BYTES}`);
      }
      const dbSucceeded = await this.applyDbDecision(capabilities, dataType, executed, state);
      if (dbSucceeded) {
        // Store before ACK. A Worker hard-timeout after DB commit can then be
        // recovered without reusing package/retry sequence values.
        this.adoptCheckpoint(executed.checkpointAfterCommit);
      }

      const commitRequest: SDKUploadCommitPageDTO = {
        roundId,
        attemptId: executed.attemptId,
        dbSucceeded
      };
      const committed = await this.executeUploadWorkerCommand(
        capabilities,
        SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        commitRequest as Object as SDKWorkerPayload
      ) as Object as SDKUploadCommitPageResultDTO;
      this.adoptCheckpoint(committed.checkpoint);
      state.hasMoreData = committed.roundHasMoreData;
      state.errorCount = committed.errorCount;
      state.consumedRows = committed.consumedRows;

      this.logUploadResult(dataType, executed, dbSucceeded);
      if (committed.delayMs > 0) {
        await this.sleep(capabilities, committed.delayMs, state);
      }
      shouldContinue = committed.shouldContinueDataType;
    }
  }

  private async queryRows(
    capabilities: DataUploadWorkerCapabilities,
    dataType: DataType,
    pageSize: number,
    state: DataUploadConsumeState
  ): Promise<DataUploadQueryPage> {
    const startedAt = capabilities.getCurrentTimeMs();
    try {
      return await capabilities.queryRows(dataType, pageSize);
    } catch (error) {
      FTInnerLogger.e(TAG, `Query data failed: ${dataType}, error: ${error as string}`);
      return {
        rows: [],
        hasMore: false,
        transportBytes: 0,
        byteLimitReached: false
      };
    } finally {
      const elapsed = this.elapsed(capabilities, startedAt);
      state.metrics.dbMs += elapsed;
      state.metrics.dbQueryMs += elapsed;
    }
  }

  private async applyDbDecision(
    capabilities: DataUploadWorkerCapabilities,
    dataType: DataType,
    executed: SDKUploadExecutePageResultDTO,
    state: DataUploadConsumeState
  ): Promise<boolean> {
    if (executed.dbAction === SDKUploadDbActionDTO.NONE || executed.rows.length === 0) {
      return true;
    }
    const startedAt = capabilities.getCurrentTimeMs();
    try {
      const action = executed.dbAction === SDKUploadDbActionDTO.REINSERT ?
        DataUploadDbCommitAction.REINSERT : DataUploadDbCommitAction.DELETE;
      const result = await capabilities.commitUpload(
        dataType,
        action,
        executed.rows as Object as DataUploadRow[],
        executed.reInsertRows as Object as DataUploadRow[],
        executed.reduceCount
      );
      state.metrics.dbWriteQueueWaitMs += Math.max(0, result.dbLaneWaitMs);
      const expectedAffectedRows = action === DataUploadDbCommitAction.REINSERT ?
        executed.rows.length + executed.reInsertRows.length : executed.rows.length;
      if (result.affectedRows < expectedAffectedRows) {
        throw new Error(`Upload DB commit affected ${result.affectedRows}/${expectedAffectedRows} expected row operations`);
      }
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG,
        `Upload DB commit failed: ${dataType}, action=${executed.dbAction}, error=${error as string}`);
      return false;
    } finally {
      const elapsed = this.elapsed(capabilities, startedAt);
      state.metrics.dbMs += elapsed;
      if (executed.dbAction === SDKUploadDbActionDTO.REINSERT) {
        state.metrics.dbInsertMs += elapsed;
      } else {
        state.metrics.dbDeleteMs += elapsed;
      }
    }
  }

  private async sleep(
    capabilities: DataUploadWorkerCapabilities,
    delayMs: number,
    state: DataUploadConsumeState
  ): Promise<void> {
    const startedAt = capabilities.getCurrentTimeMs();
    await capabilities.sleep(delayMs);
    state.metrics.sleepMs += this.elapsed(capabilities, startedAt);
  }

  private async executeUploadWorkerCommand(
    capabilities: DataUploadWorkerCapabilities,
    command: SDKWorkerCommand,
    payload?: SDKWorkerPayload
  ): Promise<SDKWorkerPayload> {
    DataUploadWorkerExecutor.commandSequence++;
    const request: SDKWorkerRequest = {
      id: `${command}:${Date.now()}:${DataUploadWorkerExecutor.commandSequence}`,
      pool: SDKDedicatedPoolType.DATA_UPLOAD,
      command,
      priority: 5,
      createdAt: Date.now(),
      payload
    };
    const response: SDKWorkerResponse = await capabilities.executeUploadWorkerCommand(request);
    if (!response.ok) {
      throw new Error(response.errorMessage || `DATA_UPLOAD worker command failed: ${command}`);
    }
    if (response.payload === undefined || response.payload === null) {
      throw new Error(`DATA_UPLOAD worker returned empty payload: ${command}`);
    }
    return response.payload;
  }

  private async finishFailedRoundSilently(
    capabilities: DataUploadWorkerCapabilities,
    roundId: string,
    state: DataUploadConsumeState
  ): Promise<void> {
    try {
      const payload: SDKUploadRoundFinishDTO = { roundId };
      const result = await this.executeUploadWorkerCommand(
        capabilities,
        SDKWorkerCommand.UPLOAD_CONSUME_FINISH,
        payload as Object as SDKWorkerPayload
      ) as Object as SDKUploadRoundResultDTO;
      state.consumedRows = result.consumedRows;
      state.hasMoreData = state.hasMoreData || result.hasMoreData;
      state.errorCount = result.errorCount;
      state.metrics.computeMs = Math.max(state.metrics.computeMs, result.computeMs);
      this.adoptCheckpoint(result.checkpoint);
    } catch (_) {
    }
  }

  private addDbMaintenanceMetrics(
    state: DataUploadConsumeState,
    result: DataUploadDbMaintenanceResult | undefined
  ): void {
    if (result) {
      state.metrics.dbWriteQueueWaitMs += Math.max(0, result.dbLaneWaitMs);
    }
  }

  private logPreparedUpload(
    dataType: DataType,
    packageId: string,
    rows: number,
    bodyLength: number,
    bodyBytes: number,
    bodyLimitReached: boolean,
    bodyPreview: string
  ): void {
    FTInnerLogger.d(TAG, '========== UPLOAD BODY PREVIEW ==========');
    FTInnerLogger.d(TAG,
      `type=${dataType}, pkg_id=${packageId}, rows=${rows}, bodyLength=${bodyLength}, bodyBytes=${bodyBytes}, ` +
        `bodyLimitReached=${bodyLimitReached}`);
    FTInnerLogger.d(TAG, bodyPreview);
    FTInnerLogger.d(TAG, '=========================================');
  }

  private logUploadResult(
    dataType: DataType,
    executed: SDKUploadExecutePageResultDTO,
    dbSucceeded: boolean
  ): void {
    if (!dbSucceeded) {
      FTInnerLogger.e(TAG,
        `pkg_id:${executed.packageId} DB commit failed; Worker upload state was not acknowledged`);
      return;
    }
    if (executed.outcome === SDKUploadPageOutcome.EMPTY_BODY) {
      FTInnerLogger.w(TAG, `Empty upload body deleted: type=${dataType}, pkg_id=${executed.packageId}`);
      return;
    }
    const httpResult = executed.httpResult;
    const response = this.abbreviateForLog(httpResult.message, 500);
    if (executed.successfulResponse) {
      FTInnerLogger.d(TAG,
        `pkg_id:${executed.packageId} Sync Success-[code:${httpResult.code},response:${response}]`);
      return;
    }
    const retryPart = executed.retryCount > 0 ? `${executed.retryCount}:` : '';
    const retryLimitPart = executed.retryLimitReached ? ' (Retry Limit Reached)' : '';
    const ignorePart = executed.ignoredClientError || executed.dbAction === SDKUploadDbActionDTO.DELETE ?
      ' (Ignore)' : '';
    FTInnerLogger.e(TAG,
      `pkg_id:${executed.packageId} ${retryPart}Sync Fail${ignorePart}${retryLimitPart}-[code:${httpResult.code},errorCode:${
        httpResult.errorCode},response:${response}]`);
  }

  private adoptCheckpoint(checkpoint: SDKUploadCheckpointDTO): void {
    if (!checkpoint || checkpoint.ownerId !== this.ownerId) {
      return;
    }
    if (this.checkpoint === null || checkpoint.version >= this.checkpoint.version) {
      this.checkpoint = checkpoint;
    }
  }

  private abbreviateForLog(value: string, limit: number): string {
    if (!value || value.length === 0) {
      return '';
    }
    const truncated = value.length <= limit ? value : `${value.substring(0, limit)}...`;
    return truncated.replace(/\n/g, '\\n');
  }

  private normalizePageSize(pageSize: number): number {
    if (pageSize !== pageSize || pageSize <= 0) {
      return 1;
    }
    return Math.min(DATA_UPLOAD_MAX_PAGE_SIZE, Math.max(1, Math.floor(pageSize)));
  }

  private normalizeRetryCount(retryCount: number): number {
    if (retryCount !== retryCount || retryCount <= 0) {
      return 0;
    }
    return Math.min(DATA_UPLOAD_MAX_RETRY_COUNT, Math.floor(retryCount));
  }

  private getOwnerId(capabilities: DataUploadWorkerCapabilities): string {
    if (this.ownerId.length === 0) {
      this.ownerId = capabilities.generateUUID();
    }
    return this.ownerId;
  }

  private elapsed(capabilities: DataUploadWorkerCapabilities, startedAt: number): number {
    return Math.max(0, capabilities.getCurrentTimeMs() - startedAt);
  }
}
