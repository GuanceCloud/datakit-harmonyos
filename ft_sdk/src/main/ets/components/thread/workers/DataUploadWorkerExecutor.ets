import { Constants } from '../../Constants';
import { DataType } from '../../enum/Enums';
import { NetCodeStatus } from '../../http/HttpEngine';
import { FTInnerLogger } from '../../log/FTLogger';
import {
  DataUploadConsumeOptions,
  DataUploadConsumeMetrics,
  DataUploadConsumeResult,
  DataUploadDbCommitAction,
  DataUploadDbMaintenanceResult,
  DataUploadDbWriteResult,
  DataUploadHttpResult,
  DataUploadRow,
  DataUploadWorkerCapabilities
} from './DataUploadWorkerCapabilities';

const TAG = "DataUploadWorker";

enum UploadBatchResult {
  DELETE_NO_BACKOFF = 'delete-no-backoff',
  DELETE_WITH_IGNORED_BACKOFF = 'delete-with-ignored-backoff',
  RETRY_BACKOFF = 'retry-backoff'
}

interface DataUploadConsumeState {
  taskName: string;
  startTraced: boolean;
  consumedRows: number;
  startedAt: number;
  metrics: DataUploadConsumeMetrics;
}

interface DataUploadHandleResult {
  hasMoreData: boolean;
}

/**
 * Owns the real upload consumption loop for the DATA_UPLOAD worker lane.
 *
 * The executor is intentionally isolated from HarmonyOS-only objects. It runs
 * against DataUploadWorkerCapabilities so DB and HTTP capabilities stay behind
 * serializable TaskPool-backed adapter methods.
 */
export class DataUploadWorkerExecutor {
  private static readonly RETRY_DELAY_SLEEP_TIME = 500;
  private static readonly IGNORED_CLIENT_ERROR_BACKOFF_MAX_MS = 8000;
  private static readonly UPLOAD_MAX_PAGES_RUM_APP = 2;
  private static readonly UPLOAD_MAX_PAGES_RUM_WEBVIEW = 1;
  private static readonly UPLOAD_MAX_PAGES_LOG = 1;
  private static readonly ONE_MINUTE_DURATION_NS = 60_000_000_000;
  private static readonly ERROR_SAMPLED_SUFFIX = "_error_sampled";
  private static cachedProcessId: number | undefined = undefined;

  private readonly syncMap: DataType[] = [DataType.RUM_APP, DataType.RUM_WEBVIEW, DataType.LOG];
  private readonly errorSampledSyncMap: DataType[] = [DataType.RUM_APP, DataType.RUM_WEBVIEW];
  private readonly errorCountByType: Map<DataType, number> = new Map();
  private readonly ignoredClientErrorCountByType: Map<DataType, number> = new Map();
  private readonly uploadingDataIds: Set<string> = new Set();
  private rumGenerator = new IDGenerator();
  private logGenerator = new IDGenerator();

  public static resetStaticStateInternal(): void {
    DataUploadWorkerExecutor.cachedProcessId = undefined;
  }

  public async consume(
    capabilities: DataUploadWorkerCapabilities,
    options: DataUploadConsumeOptions
  ): Promise<DataUploadConsumeResult> {
    const consumeOptions = this.sanitizeConsumeOptions(options);
    const state: DataUploadConsumeState = {
      taskName: consumeOptions.taskName,
      startTraced: false,
      consumedRows: 0,
      startedAt: capabilities.getCurrentTimeMs(),
      metrics: this.createMetrics()
    };
    let hasMoreData = false;

    try {
      if (capabilities.isStopped()) {
        return this.createResult(state, capabilities, false);
      }

      for (const dataType of this.errorSampledSyncMap) {
        if (capabilities.isStopped()) {
          break;
        }
        const errorSampledStartTime = capabilities.getCurrentTimeMs();
        const result = await this.errorSampledConsume(capabilities, dataType, consumeOptions.errorTimeLine);
        this.addDbErrorSampledTime(state, capabilities, errorSampledStartTime);
        this.addDbMaintenanceQueueWait(state, result);
      }

      for (const dataType of this.syncMap) {
        if (capabilities.isStopped()) {
          break;
        }
        const result = await this.handleSyncOpt(capabilities, dataType, consumeOptions, state);
        hasMoreData = result.hasMoreData || hasMoreData;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${error as string}`);
    }

    return this.createResult(state, capabilities, hasMoreData);
  }

  public getErrorCount(): number {
    return this.getAggregateErrorCount();
  }

  private createResult(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities,
    hasMoreData: boolean
  ): DataUploadConsumeResult {
    return {
      consumedRows: state.consumedRows,
      hasMoreData,
      errorCount: this.getAggregateErrorCount(),
      metrics: this.finishMetrics(state.metrics, capabilities, state.startedAt)
    };
  }

  private createMetrics(): DataUploadConsumeMetrics {
    return {
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
    };
  }

  private finishMetrics(
    metrics: DataUploadConsumeMetrics,
    capabilities: DataUploadWorkerCapabilities,
    startedAt: number
  ): DataUploadConsumeMetrics {
    metrics.executeMs = metrics.dbMs + metrics.httpMs + metrics.sleepMs;
    const measuredTotal = Math.max(0, capabilities.getCurrentTimeMs() - startedAt);
    const accountedTime = metrics.computeMs + metrics.executeMs;
    metrics.unaccountedMs = Math.max(0, measuredTotal - accountedTime);
    metrics.totalMs = accountedTime + metrics.unaccountedMs;
    return metrics;
  }

  private elapsedSince(capabilities: DataUploadWorkerCapabilities, startTime: number): number {
    return Math.max(0, capabilities.getCurrentTimeMs() - startTime);
  }

  private addComputeTime(state: DataUploadConsumeState, capabilities: DataUploadWorkerCapabilities, startTime: number): void {
    state.metrics.computeMs += this.elapsedSince(capabilities, startTime);
  }

  private addDbErrorSampledTime(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities,
    startTime: number
  ): void {
    const elapsed = this.elapsedSince(capabilities, startTime);
    state.metrics.dbMs += elapsed;
    state.metrics.dbErrorSampledMs += elapsed;
  }

  private addDbQueryTime(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities,
    startTime: number
  ): void {
    const elapsed = this.elapsedSince(capabilities, startTime);
    state.metrics.dbMs += elapsed;
    state.metrics.dbQueryMs += elapsed;
  }

  private addDbDeleteTime(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities,
    startTime: number
  ): void {
    const elapsed = this.elapsedSince(capabilities, startTime);
    state.metrics.dbMs += elapsed;
    state.metrics.dbDeleteMs += elapsed;
  }

  private addDbInsertTime(
    state: DataUploadConsumeState,
    capabilities: DataUploadWorkerCapabilities,
    startTime: number
  ): void {
    const elapsed = this.elapsedSince(capabilities, startTime);
    state.metrics.dbMs += elapsed;
    state.metrics.dbInsertMs += elapsed;
  }

  private addDbWriteQueueWait(state: DataUploadConsumeState, result: DataUploadDbWriteResult | undefined): void {
    if (!result) {
      return;
    }
    state.metrics.dbWriteQueueWaitMs += Math.max(0, result.dbLaneWaitMs);
  }

  private addDbMaintenanceQueueWait(
    state: DataUploadConsumeState,
    result: DataUploadDbMaintenanceResult | undefined
  ): void {
    if (!result) {
      return;
    }
    state.metrics.dbWriteQueueWaitMs += Math.max(0, result.dbLaneWaitMs);
  }

  private addHttpTime(state: DataUploadConsumeState, capabilities: DataUploadWorkerCapabilities, startTime: number): void {
    state.metrics.httpMs += this.elapsedSince(capabilities, startTime);
  }

  private addSleepTime(state: DataUploadConsumeState, capabilities: DataUploadWorkerCapabilities, startTime: number): void {
    state.metrics.sleepMs += this.elapsedSince(capabilities, startTime);
  }

  private async sleepWithMetrics(
    capabilities: DataUploadWorkerCapabilities,
    state: DataUploadConsumeState,
    ms: number
  ): Promise<void> {
    const startTime = capabilities.getCurrentTimeMs();
    await capabilities.sleep(ms);
    this.addSleepTime(state, capabilities, startTime);
  }

  private sanitizeConsumeOptions(options: DataUploadConsumeOptions): DataUploadConsumeOptions {
    return {
      taskName: options.taskName || "upload.poll",
      pageSize: this.sanitizePageSize(options.pageSize),
      syncSleepTime: Math.max(0, options.syncSleepTime),
      errorTimeLine: options.errorTimeLine,
      stopped: options.stopped === true
    };
  }

  private sanitizePageSize(pageSize: number): number {
    if (pageSize !== pageSize || pageSize <= 0) {
      return 1;
    }
    return Math.max(1, Math.floor(pageSize));
  }

  private async errorSampledConsume(
    capabilities: DataUploadWorkerCapabilities,
    dataType: DataType,
    errorTimeLine: number
  ): Promise<DataUploadDbMaintenanceResult | undefined> {
    try {
      const errorSampledType = dataType.toString() + DataUploadWorkerExecutor.ERROR_SAMPLED_SUFFIX;
      const now = this.getCurrentNanoTime(capabilities);
      return await capabilities.maintainErrorSampled(
        errorSampledType,
        errorTimeLine,
        now,
        DataUploadWorkerExecutor.ONE_MINUTE_DURATION_NS
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> errorSampledConsume failed: ${dataType}, error: ${error as string}`);
      return undefined;
    }
  }

  private async handleSyncOpt(
    capabilities: DataUploadWorkerCapabilities,
    dataType: DataType,
    options: DataUploadConsumeOptions,
    state: DataUploadConsumeState
  ): Promise<DataUploadHandleResult> {
    const maxPages = this.getUploadMaxPages(dataType);
    let processedPages = 0;
    let lastQueryWasFull = false;
    let shouldReschedule = false;

    while (!capabilities.isStopped() && processedPages < maxPages) {
      const queryStartTime = capabilities.getCurrentTimeMs();
      const cacheDataList = await this.queryFromData(capabilities, dataType, options.pageSize);
      this.addDbQueryTime(state, capabilities, queryStartTime);
      this.traceUploadLane(`[QUERY] type=${dataType} rows=${cacheDataList.length} pageSize=${options.pageSize}`);
      lastQueryWasFull = cacheDataList.length >= options.pageSize;

      const computeStartTime = capabilities.getCurrentTimeMs();
      const deduplicatedDataList = this.deduplicateData(dataType, cacheDataList);
      if (deduplicatedDataList.length === 0) {
        this.addComputeTime(state, capabilities, computeStartTime);
        if (cacheDataList.length > 0) {
          this.traceUploadLane(
            `[SKIP] type=${dataType} rows=${cacheDataList.length} reason=all-deduplicated`
          );
        }
        break;
      }

      if (deduplicatedDataList.length < cacheDataList.length) {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> Deduplication filtered out ${cacheDataList.length -
        deduplicatedDataList.length} duplicate record(s) for ${dataType}`);
      }

      FTInnerLogger.d(TAG, `Sync Data Count:${deduplicatedDataList.length}`);

      const seqNumber = this.getSeqNumber(dataType);
      const pkgId = this.generatePackageId(capabilities, seqNumber, deduplicatedDataList.length);
      const body = this.formatLineProtocolData(deduplicatedDataList, pkgId);
      this.addComputeTime(state, capabilities, computeStartTime);
      if (body.trim().length === 0) {
        await this.deleteAndReduceCache(capabilities, state, dataType, deduplicatedDataList);
        processedPages++;
        this.traceUploadLane(`[SKIP] type=${dataType} rows=${deduplicatedDataList.length} reason=empty-body`);
        if (cacheDataList.length < options.pageSize) {
          break;
        }
        continue;
      }

      this.traceUploadStartIfNeeded(state, dataType, deduplicatedDataList.length);
      state.consumedRows += deduplicatedDataList.length;
      const markStartTime = capabilities.getCurrentTimeMs();
      this.markDataAsUploading(dataType, deduplicatedDataList);
      this.addComputeTime(state, capabilities, markStartTime);

      try {
        this.printUploadData(dataType, pkgId, deduplicatedDataList.length, body);
        const result = await this.uploadBatch(capabilities, state, dataType, pkgId, body, deduplicatedDataList);
        processedPages++;

        if (result === UploadBatchResult.RETRY_BACKOFF ||
          result === UploadBatchResult.DELETE_WITH_IGNORED_BACKOFF) {
          shouldReschedule = result === UploadBatchResult.RETRY_BACKOFF;
          break;
        }

        if (cacheDataList.length < options.pageSize) {
          break;
        }
        if (options.syncSleepTime > 0 && processedPages < maxPages) {
          await this.sleepWithMetrics(capabilities, state, options.syncSleepTime);
        }
      } catch (error) {
        const unmarkStartTime = capabilities.getCurrentTimeMs();
        this.unmarkDataAsUploading(dataType, deduplicatedDataList);
        this.addComputeTime(state, capabilities, unmarkStartTime);
        const retryCount = this.incrementErrorCount(dataType);
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${dataType}, error: ${error as string}`);

        const delayTime = this.getNormalBackoffMs(retryCount);
        await this.sleepWithMetrics(capabilities, state, delayTime);
        break;
      }
    }

    if (processedPages >= maxPages && lastQueryWasFull) {
      return { hasMoreData: true };
    }
    return { hasMoreData: shouldReschedule };
  }

  private async uploadBatch(
    capabilities: DataUploadWorkerCapabilities,
    state: DataUploadConsumeState,
    dataType: DataType,
    pkgId: string,
    body: string,
    dataList: DataUploadRow[]
  ): Promise<UploadBatchResult> {
    let result: DataUploadHttpResult;
    const httpStartTime = capabilities.getCurrentTimeMs();
    let httpMeasured = false;
    try {
      result = await capabilities.executeHttp(dataType, pkgId, body);
      this.addHttpTime(state, capabilities, httpStartTime);
      httpMeasured = true;
      if (result.code === NetCodeStatus.NETWORK_EXCEPTION_CODE) {
        FTInnerLogger.e(TAG, "Network not available");
        throw new Error("Network not available");
      }
    } catch (error) {
      if (!httpMeasured) {
        this.addHttpTime(state, capabilities, httpStartTime);
      }
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Network request failed: ${error as string}`);
      result = {
        code: NetCodeStatus.UNKNOWN_EXCEPTION_CODE,
        message: (error as Error).message || "",
        errorCode: ""
      };
    }

    return await this.handleUploadResponse(capabilities, state, dataType, pkgId, result, dataList, body);
  }

  private async handleUploadResponse(
    capabilities: DataUploadWorkerCapabilities,
    state: DataUploadConsumeState,
    dataType: DataType,
    pkgId: string,
    result: DataUploadHttpResult,
    dataList: DataUploadRow[],
    body: string
  ): Promise<UploadBatchResult> {
    const code = result.code;
    const response = result.message;
    const errorCode = result.errorCode;
    const model = result.model || "";

    if (this.isIgnoredClientError(code)) {
      const markStartTime = capabilities.getCurrentTimeMs();
      this.markDataAsUploaded(dataType, dataList);
      this.addComputeTime(state, capabilities, markStartTime);
      await this.deleteAndReduceCache(capabilities, state, dataType, dataList);
      this.resetErrorCount(dataType);
      const ignoredCount = this.incrementIgnoredClientErrorCount(dataType);
      const delayTime = this.getIgnoredClientBackoffMs(ignoredCount);
      FTInnerLogger.e(TAG,
        `pkg_id:${pkgId} Sync Fail (Ignore)-[code:${code},errorCode:${errorCode},response:${this.abbreviateForLog(response, 500)}]`);
      this.traceUploadLane(
        `[BATCH] type=${dataType} code=${code} rows=${dataList.length} action=delete ignoredBackoff=${delayTime}ms ignoredCount=${ignoredCount} pkg=${pkgId}`
      );
      await this.sleepWithMetrics(capabilities, state, delayTime);
      return UploadBatchResult.DELETE_WITH_IGNORED_BACKOFF;
    }

    if (this.shouldDeleteWithoutBackoff(code)) {
      const markStartTime = capabilities.getCurrentTimeMs();
      this.markDataAsUploaded(dataType, dataList);
      this.addComputeTime(state, capabilities, markStartTime);
      await this.deleteAndReduceCache(capabilities, state, dataType, dataList);
      this.resetErrorCount(dataType);
      this.resetIgnoredClientErrorCount(dataType);
      const advanceStartTime = capabilities.getCurrentTimeMs();
      this.advancePackageGenerator(dataType, code);
      this.addComputeTime(state, capabilities, advanceStartTime);
      if (code >= 200 && code < 300) {
        FTInnerLogger.d(TAG,
          `pkg_id:${pkgId} Sync Success-[code:${code},response:${this.abbreviateForLog(response, 500)}]`);
      } else {
        FTInnerLogger.e(TAG,
          `pkg_id:${pkgId} Sync Fail (Ignore)-[code:${code},errorCode:${errorCode},response:${this.abbreviateForLog(response, 500)}]`);
      }
      this.traceUploadLane(
        `[BATCH] type=${dataType} model=${model} code=${code} rows=${dataList.length} action=delete backoff=0ms ` +
          `response=${this.abbreviateForLog(response, 200)} firstLine=${this.getFirstLineForLog(body, 500)} pkg=${pkgId}`
      );
      return UploadBatchResult.DELETE_NO_BACKOFF;
    }

    if (this.isRetryableUploadError(code)) {
      const unmarkStartTime = capabilities.getCurrentTimeMs();
      this.unmarkDataAsUploading(dataType, dataList);
      this.addComputeTime(state, capabilities, unmarkStartTime);
      await this.reInsertData(capabilities, state, dataType, dataList);
      this.resetIgnoredClientErrorCount(dataType);
      const retryCount = this.incrementErrorCount(dataType);
      const delayTime = this.getNormalBackoffMs(retryCount);
      FTInnerLogger.e(TAG,
        `pkg_id:${pkgId} ${retryCount}:Sync Fail-[code:${code},errorCode:${errorCode},response:${this.abbreviateForLog(response, 500)}]`);
      FTInnerLogger.w(TAG,
        `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=reinsert retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
      await this.sleepWithMetrics(capabilities, state, delayTime);
      return UploadBatchResult.RETRY_BACKOFF;
    }

    const unmarkStartTime = capabilities.getCurrentTimeMs();
    this.unmarkDataAsUploading(dataType, dataList);
    this.addComputeTime(state, capabilities, unmarkStartTime);
    const retryCount = this.incrementErrorCount(dataType);
    const delayTime = this.getNormalBackoffMs(retryCount);
    FTInnerLogger.e(TAG,
      `pkg_id:${pkgId} ${retryCount}:Sync Fail-[code:${code},errorCode:${errorCode},response:${this.abbreviateForLog(response, 500)}]`);
    FTInnerLogger.w(TAG,
      `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=retry retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
    await this.sleepWithMetrics(capabilities, state, delayTime);
    return UploadBatchResult.RETRY_BACKOFF;
  }

  private getUploadMaxPages(dataType: DataType): number {
    switch (dataType) {
      case DataType.RUM_APP:
        return DataUploadWorkerExecutor.UPLOAD_MAX_PAGES_RUM_APP;
      case DataType.RUM_WEBVIEW:
        return DataUploadWorkerExecutor.UPLOAD_MAX_PAGES_RUM_WEBVIEW;
      case DataType.LOG:
      default:
        return DataUploadWorkerExecutor.UPLOAD_MAX_PAGES_LOG;
    }
  }

  private getFirstLineForLog(body: string, limit: number): string {
    if (!body || body.length === 0) {
      return "";
    }
    const newlineIndex = body.indexOf('\n');
    const firstLine = newlineIndex >= 0 ? body.substring(0, newlineIndex) : body;
    return this.abbreviateForLog(firstLine, limit);
  }

  private abbreviateForLog(value: string, limit: number): string {
    if (!value || value.length === 0) {
      return "";
    }
    const normalized = value.replace(/\n/g, "\\n");
    if (normalized.length <= limit) {
      return normalized;
    }
    return normalized.substring(0, limit) + "...";
  }

  private isIgnoredClientError(code: number): boolean {
    return code === 403 || code === 429;
  }

  private shouldDeleteWithoutBackoff(code: number): boolean {
    return code >= 200 && code < 500 && !this.isIgnoredClientError(code);
  }

  private isRetryableUploadError(code: number): boolean {
    return code >= 500 ||
      code === NetCodeStatus.NETWORK_EXCEPTION_CODE ||
      code === NetCodeStatus.UNKNOWN_EXCEPTION_CODE;
  }

  private getNormalBackoffMs(errorCount: number): number {
    return Math.max(1, Math.pow(2, Math.max(0, errorCount - 1))) *
      DataUploadWorkerExecutor.RETRY_DELAY_SLEEP_TIME;
  }

  private getIgnoredClientBackoffMs(errorCount: number): number {
    return Math.min(
      DataUploadWorkerExecutor.IGNORED_CLIENT_ERROR_BACKOFF_MAX_MS,
      this.getNormalBackoffMs(errorCount)
    );
  }

  private getTypeErrorCount(dataType: DataType): number {
    return this.errorCountByType.get(dataType) || 0;
  }

  private getTypeIgnoredClientErrorCount(dataType: DataType): number {
    return this.ignoredClientErrorCountByType.get(dataType) || 0;
  }

  private incrementErrorCount(dataType: DataType): number {
    const count = this.getTypeErrorCount(dataType) + 1;
    this.errorCountByType.set(dataType, count);
    return count;
  }

  private resetErrorCount(dataType: DataType): void {
    this.errorCountByType.set(dataType, 0);
  }

  private incrementIgnoredClientErrorCount(dataType: DataType): number {
    const count = this.getTypeIgnoredClientErrorCount(dataType) + 1;
    this.ignoredClientErrorCountByType.set(dataType, count);
    return count;
  }

  private resetIgnoredClientErrorCount(dataType: DataType): void {
    this.ignoredClientErrorCountByType.set(dataType, 0);
  }

  private getAggregateErrorCount(): number {
    let maxErrorCount = 0;
    this.errorCountByType.forEach((count) => {
      maxErrorCount = Math.max(maxErrorCount, count);
    });
    return maxErrorCount;
  }

  private advancePackageGenerator(dataType: DataType, code: number): void {
    if (code !== 200) {
      return;
    }
    if (dataType === DataType.LOG) {
      this.logGenerator.next();
    } else {
      this.rumGenerator.next();
    }
  }

  private extractUniqueId(dataType: DataType, dataString: string): string | null {
    try {
      if (dataString.startsWith('action,')) {
        const actionIdMatch = dataString.match(/action_id=([^,\s]+)/);
        if (actionIdMatch && actionIdMatch[1]) {
          return `action_id=${actionIdMatch[1]}`;
        }
      }

      if (dataString.startsWith('view,')) {
        const viewIdMatch = dataString.match(/view_id=([^,\s]+)/);
        const viewUpdateTimeMatch = dataString.match(/view_update_time=([^,\s]+)/);
        if (viewIdMatch && viewIdMatch[1]) {
          const viewId = viewIdMatch[1];
          if (viewUpdateTimeMatch && viewUpdateTimeMatch[1]) {
            return `view_id=${viewId}:view_update_time=${viewUpdateTimeMatch[1]}`;
          }
          return `view_id=${viewId}`;
        }
      }

      if (dataString.startsWith('resource,')) {
        const spanIdMatch = dataString.match(/span_id=([^,\s]+)/);
        if (spanIdMatch && spanIdMatch[1]) {
          return `span_id=${spanIdMatch[1]}`;
        }
        const traceIdMatch = dataString.match(/trace_id=([^,\s]+)/);
        if (traceIdMatch && traceIdMatch[1]) {
          return `trace_id=${traceIdMatch[1]}`;
        }
      }

      if (dataString.startsWith('error,')) {
        const errorTypeMatch = dataString.match(/error_type=([^,\s]+)/);
        const errorMessageMatch = dataString.match(/error_message="([^"]+)"/);
        const timestampMatch = dataString.match(/\s(\d+)$/);

        const errorType = errorTypeMatch ? errorTypeMatch[1] : '';
        const errorMessage = errorMessageMatch ? errorMessageMatch[1].substring(0, 100) : '';
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (errorType || errorMessage || timestamp) {
          return `error_type=${errorType}:error_message=${errorMessage}:timestamp=${timestamp}`;
        }
      }

      if (dataString.startsWith('longtask,') || dataString.startsWith('long_task,')) {
        const longTaskNameMatch = dataString.match(/long_task_name=([^,\s]+)/);
        const timestampMatch = dataString.match(/\s(\d+)$/);

        const longTaskName = longTaskNameMatch ? longTaskNameMatch[1] : '';
        const timestamp = timestampMatch ? timestampMatch[1] : '';

        if (longTaskName || timestamp) {
          return `long_task_name=${longTaskName}:timestamp=${timestamp}`;
        }
      }

      if (dataString.startsWith('df_rum_harmonyos_log,')) {
        const sdkDataIdMatch = dataString.match(/sdk_data_id=([^,\s]+)/);
        if (sdkDataIdMatch && sdkDataIdMatch[1]) {
          const uuidMatch = sdkDataIdMatch[1].match(/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i);
          if (uuidMatch && uuidMatch[1]) {
            return `uuid=${uuidMatch[1]}`;
          }
          return `sdk_data_id=${sdkDataIdMatch[1]}`;
        }
      }

      const timestampMatch = dataString.match(/\s(\d+)$/);
      if (timestampMatch && timestampMatch[1]) {
        return `timestamp=${timestampMatch[1]}`;
      }

      return null;
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Error extracting unique ID: ${error as string}`);
      return null;
    }
  }

  private deduplicateData(dataType: DataType, dataList: DataUploadRow[]): DataUploadRow[] {
    if (!dataList || dataList.length === 0) {
      return dataList;
    }

    const uniqueDataMap: Map<string, DataUploadRow> = new Map();
    const seenIds: Set<string> = new Set();

    for (const data of dataList) {
      const dataString = data.dataString;
      const uniqueId = this.extractUniqueId(dataType, dataString);
      const key = this.getUploadDedupKey(dataType, data, uniqueId);
      if (this.uploadingDataIds.has(key) || seenIds.has(key)) {
        continue;
      }
      seenIds.add(key);
      uniqueDataMap.set(key, data);
    }

    return Array.from(uniqueDataMap.values());
  }

  private getUploadDedupKey(dataType: DataType, data: DataUploadRow, uniqueId: string | null): string {
    if (uniqueId) {
      return `${dataType}:${uniqueId}`;
    }

    if (data.uuid) {
      return `${dataType}:uuid=${data.uuid}`;
    }

    FTInnerLogger.w(TAG,
      `<FT-BATCH-UPLOAD> [DEDUP] Warning: Cannot extract unique ID for data, using data string hash as fallback`);
    return `${dataType}:hash=${this.hashString(data.dataString)}`;
  }

  private hashString(str: string): string {
    let hash = 0;
    if (str.length === 0) {
      return '0';
    }
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return Math.abs(hash).toString(16);
  }

  private markDataAsUploading(dataType: DataType, dataList: DataUploadRow[]): void {
    for (const data of dataList) {
      const uniqueId = this.extractUniqueId(dataType, data.dataString);
      this.uploadingDataIds.add(this.getUploadDedupKey(dataType, data, uniqueId));
    }
  }

  private unmarkDataAsUploading(dataType: DataType, dataList: DataUploadRow[]): void {
    for (const data of dataList) {
      const uniqueId = this.extractUniqueId(dataType, data.dataString);
      this.uploadingDataIds.delete(this.getUploadDedupKey(dataType, data, uniqueId));
    }
  }

  private markDataAsUploaded(dataType: DataType, dataList: DataUploadRow[]): void {
    for (const data of dataList) {
      const uniqueId = this.extractUniqueId(dataType, data.dataString);
      const key = this.getUploadDedupKey(dataType, data, uniqueId);
      this.uploadingDataIds.delete(key);
    }

    if (this.uploadingDataIds.size > Constants.MAX_SET_SIZE_UPLOAD) {
      FTInnerLogger.w(TAG,
        `<FT-BATCH-UPLOAD> uploadingDataIds size (${this.uploadingDataIds.size}) exceeds limit, clearing to prevent memory leak`);
      this.uploadingDataIds.clear();
    }
  }

  private async queryFromData(
    capabilities: DataUploadWorkerCapabilities,
    dataType: DataType,
    pageSize: number
  ): Promise<DataUploadRow[]> {
    try {
      return await capabilities.queryRows(dataType, pageSize);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Query data failed: ${dataType}, error: ${error as string}`);
      return [];
    }
  }

  private printUploadData(dataType: DataType, pkgId: string, rows: number, body: string): void {
    FTInnerLogger.d(TAG,
      `<FT-BATCH-UPLOAD> ========== UPLOAD BODY PREVIEW（type=${dataType} rows=${rows} pkg=${pkgId}） ==========`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD>\n${body}`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> ========================================`);
  }

  private async deleteAndReduceCache(
    capabilities: DataUploadWorkerCapabilities,
    state: DataUploadConsumeState,
    dataType: DataType,
    list: DataUploadRow[]
  ): Promise<void> {
    try {
      if (!list || list.length === 0) {
        return;
      }

      const deleteStartTime = capabilities.getCurrentTimeMs();
      const result = await capabilities.commitUpload(
        dataType,
        DataUploadDbCommitAction.DELETE,
        list,
        [],
        list.length
      );
      this.addDbDeleteTime(state, capabilities, deleteStartTime);
      this.addDbWriteQueueWait(state, result);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Delete uploaded data failed: ${error as string}`);
    }
  }

  private async reInsertData(
    capabilities: DataUploadWorkerCapabilities,
    state: DataUploadConsumeState,
    dataType: DataType,
    list: DataUploadRow[]
  ): Promise<void> {
    try {
      const computeStartTime = capabilities.getCurrentTimeMs();
      const reInsertList: DataUploadRow[] = [];
      for (const data of list) {
        reInsertList.push({
          id: data.id,
          dataType: data.dataType,
          dataString: data.dataString,
          uuid: capabilities.generateUUID(),
          time: data.time,
          customDataType: data.customDataType
        });
      }
      this.addComputeTime(state, capabilities, computeStartTime);

      const insertStartTime = capabilities.getCurrentTimeMs();
      const result = await capabilities.commitUpload(
        dataType,
        DataUploadDbCommitAction.REINSERT,
        list,
        reInsertList,
        0
      );
      this.addDbInsertTime(state, capabilities, insertStartTime);
      this.addDbWriteQueueWait(state, result);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Reinsert data failed: ${error as string}`);
    }
  }

  private getSeqNumber(dataType: DataType): string {
    if (dataType === DataType.LOG) {
      return this.logGenerator.getCurrentId();
    }
    return this.rumGenerator.getCurrentId();
  }

  private generatePackageId(capabilities: DataUploadWorkerCapabilities, seqNumber: string, dataCount: number): string {
    const pid = this.getProcessId(capabilities);
    const pidEncoded = this.encodeBase62(pid);
    const nanoId = this.generateNanoId(capabilities);
    return `${seqNumber}.${pidEncoded}.${dataCount}.${nanoId}`;
  }

  private generateNanoId(capabilities: DataUploadWorkerCapabilities): string {
    const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const NANO_DIGIT = 12;
    let result = "";

    for (let i = 0; i < NANO_DIGIT; i++) {
      const randomIndex = Math.floor(capabilities.getRandom() * BASE62.length);
      result += BASE62.charAt(randomIndex);
    }

    return result;
  }

  private encodeBase62(value: number): string {
    const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    if (value === 0) {
      return "0";
    }

    let result = "";
    while (value > 0) {
      result = BASE62.charAt(value % 62) + result;
      value = Math.floor(value / 62);
    }

    return result;
  }

  private getProcessId(capabilities: DataUploadWorkerCapabilities): number {
    if (DataUploadWorkerExecutor.cachedProcessId === undefined) {
      const seed = capabilities.getCurrentTimeMs() ^ Math.floor(capabilities.getRandom() * 1e6);
      DataUploadWorkerExecutor.cachedProcessId = Math.abs(seed % 65535) + 1;
    }
    return DataUploadWorkerExecutor.cachedProcessId;
  }

  private getCurrentNanoTime(capabilities: DataUploadWorkerCapabilities): number {
    return capabilities.getCurrentTimeMs() * 1_000_000;
  }

  private formatLineProtocolData(dataList: DataUploadRow[], pkgId: string): string {
    if (!dataList || dataList.length === 0) {
      return "";
    }

    const lines: string[] = [];
    for (const data of dataList) {
      const dataString = this.applyPackageId(data.dataString, data.uuid, pkgId);
      if (dataString && dataString.trim().length > 0) {
        lines.push(this.addPackageIdToLine(dataString, pkgId));
      }
    }

    return lines.join('\n');
  }

  private applyPackageId(dataString: string, uuid: string, pkgId: string): string {
    if (!dataString || !uuid || !pkgId) {
      return dataString || "";
    }
    return dataString.replace(uuid, `${pkgId}.${uuid}`);
  }

  private addPackageIdToLine(line: string, _pkgId: string): string {
    return line;
  }

  private traceUploadLane(message: string): void {
    FTInnerLogger.i(TAG, `<FT-UPLOAD-LANE> ${message}`);
  }

  private traceUploadLaneDebug(message: string): void {
    FTInnerLogger.d(TAG, `<FT-UPLOAD-LANE> ${message}`);
  }

  private traceUploadStartIfNeeded(state: DataUploadConsumeState, dataType: DataType, rows: number): void {
    if (state.startTraced) {
      return;
    }
    state.startTraced = true;
    const taskName = state.taskName && state.taskName.length > 0 ? state.taskName : "upload.poll";
    this.traceUploadLane(`[START] name=${taskName} firstType=${dataType} rows=${rows}`);
  }
}

class IDGenerator {
  private static readonly BASE36_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz";
  private static readonly MAX_VALUE = Math.pow(36, 8);
  private currentValue: number = 0;

  getCurrentId(): string {
    return this.getBase36String(this.currentValue);
  }

  next(): void {
    this.currentValue++;
    if (this.currentValue > IDGenerator.MAX_VALUE) {
      this.currentValue = 0;
    }
  }

  private getBase36String(value: number): string {
    if (value === 0) {
      return "0";
    }

    let result = "";
    while (value > 0) {
      result = IDGenerator.BASE36_CHARS.charAt(value % 36) + result;
      value = Math.floor(value / 36);
    }

    return result;
  }
}
