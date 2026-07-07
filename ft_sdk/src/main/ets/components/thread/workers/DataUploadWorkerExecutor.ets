import { Constants } from '../../Constants';
import { DataType } from '../../enum/Enums';
import { NetCodeStatus } from '../../http/HttpEngine';
import { FTInnerLogger } from '../../log/FTLogger';
import {
  DATA_UPLOAD_WORKER_MAX_BATCH_LIMIT,
  DataUploadConsumeOptions,
  DataUploadConsumeResult,
  DataUploadHttpResult,
  DataUploadRow,
  DataUploadWorkerRuntime
} from './DataUploadWorkerRuntime';

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
}

interface DataUploadHandleResult {
  hasMoreData: boolean;
}

/**
 * Owns the real upload consumption loop for the DATA_UPLOAD worker lane.
 *
 * The executor is intentionally isolated from HarmonyOS-only objects. It runs
 * against DataUploadWorkerRuntime so the same logic can be used by the inline
 * fallback runtime and the ThreadWorker bridge runtime.
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
  private readonly uploadedDataIds: Set<string> = new Set();
  private readonly uploadingDataIds: Set<string> = new Set();
  private rumGenerator = new IDGenerator();
  private logGenerator = new IDGenerator();

  public static resetStaticStateInternal(): void {
    DataUploadWorkerExecutor.cachedProcessId = undefined;
  }

  public async consume(
    runtime: DataUploadWorkerRuntime,
    options: DataUploadConsumeOptions
  ): Promise<DataUploadConsumeResult> {
    const consumeOptions = this.sanitizeConsumeOptions(options);
    const state: DataUploadConsumeState = {
      taskName: consumeOptions.taskName,
      startTraced: false,
      consumedRows: 0
    };
    let hasMoreData = false;

    try {
      if (runtime.isStopped()) {
        return this.createResult(state, false);
      }

      for (const dataType of this.errorSampledSyncMap) {
        if (runtime.isStopped()) {
          break;
        }
        await this.errorSampledConsume(runtime, dataType, consumeOptions.errorTimeLine);
      }

      for (const dataType of this.syncMap) {
        if (runtime.isStopped()) {
          break;
        }
        const result = await this.handleSyncOpt(runtime, dataType, consumeOptions, state);
        hasMoreData = result.hasMoreData || hasMoreData;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${error as string}`);
    }

    return this.createResult(state, hasMoreData);
  }

  public getErrorCount(): number {
    return this.getAggregateErrorCount();
  }

  private createResult(state: DataUploadConsumeState, hasMoreData: boolean): DataUploadConsumeResult {
    return {
      consumedRows: state.consumedRows,
      hasMoreData,
      errorCount: this.getAggregateErrorCount()
    };
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
      return DATA_UPLOAD_WORKER_MAX_BATCH_LIMIT;
    }
    return Math.min(Math.floor(pageSize), DATA_UPLOAD_WORKER_MAX_BATCH_LIMIT);
  }

  private async errorSampledConsume(
    runtime: DataUploadWorkerRuntime,
    dataType: DataType,
    errorTimeLine: number
  ): Promise<void> {
    try {
      const errorSampledType = dataType.toString() + DataUploadWorkerExecutor.ERROR_SAMPLED_SUFFIX;

      if (errorTimeLine > 0) {
        await runtime.updateDataType(errorSampledType, errorTimeLine);
      }

      const now = this.getCurrentNanoTime(runtime);
      await runtime.deleteExpireCache(
        errorSampledType,
        now,
        DataUploadWorkerExecutor.ONE_MINUTE_DURATION_NS
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> errorSampledConsume failed: ${dataType}, error: ${error as string}`);
    }
  }

  private async handleSyncOpt(
    runtime: DataUploadWorkerRuntime,
    dataType: DataType,
    options: DataUploadConsumeOptions,
    state: DataUploadConsumeState
  ): Promise<DataUploadHandleResult> {
    const hasData = await runtime.hasData(dataType);
    if (!hasData) {
      return { hasMoreData: false };
    }

    const maxPages = this.getUploadMaxPages(dataType);
    let processedPages = 0;
    let lastQueryWasFull = false;
    let shouldReschedule = false;

    while (!runtime.isStopped() && processedPages < maxPages) {
      const cacheDataList = await this.queryFromData(runtime, dataType, options.pageSize);
      lastQueryWasFull = cacheDataList.length >= options.pageSize;

      const deduplicatedDataList = this.deduplicateData(dataType, cacheDataList);
      if (deduplicatedDataList.length === 0) {
        break;
      }

      if (deduplicatedDataList.length < cacheDataList.length) {
        FTInnerLogger.w(TAG, `<FT-BATCH-UPLOAD> Deduplication filtered out ${cacheDataList.length -
        deduplicatedDataList.length} duplicate record(s) for ${dataType}`);
      }

      if (await runtime.shouldDiscardData(dataType)) {
        FTInnerLogger.w(TAG, `<FT-UPLOAD-LANE> [SKIP] type=${dataType} reason=cache-limit`);
        break;
      }

      const seqNumber = this.getSeqNumber(dataType);
      const pkgId = this.generatePackageId(runtime, seqNumber, deduplicatedDataList.length);
      const body = this.formatLineProtocolData(deduplicatedDataList, pkgId);
      if (body.trim().length === 0) {
        await this.deleteLastQuery(runtime, deduplicatedDataList);
        await runtime.reduceCacheCount(dataType, deduplicatedDataList.length);
        processedPages++;
        this.traceUploadLaneDebug(`[SKIP] type=${dataType} rows=${deduplicatedDataList.length} reason=empty-body`);
        if (cacheDataList.length < options.pageSize) {
          break;
        }
        continue;
      }

      this.traceUploadStartIfNeeded(state, dataType, deduplicatedDataList.length);
      state.consumedRows += deduplicatedDataList.length;
      this.markDataAsUploading(dataType, deduplicatedDataList);

      try {
        this.printUploadData(body);
        const result = await this.uploadBatch(runtime, dataType, pkgId, body, deduplicatedDataList);
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
          await runtime.sleep(options.syncSleepTime);
        }
      } catch (error) {
        this.unmarkDataAsUploading(dataType, deduplicatedDataList);
        const retryCount = this.incrementErrorCount(dataType);
        FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Sync Fail: ${dataType}, error: ${error as string}`);

        const delayTime = this.getNormalBackoffMs(retryCount);
        await runtime.sleep(delayTime);
        break;
      }
    }

    if (processedPages >= maxPages && lastQueryWasFull) {
      return { hasMoreData: await runtime.hasData(dataType) };
    }
    return { hasMoreData: shouldReschedule };
  }

  private async uploadBatch(
    runtime: DataUploadWorkerRuntime,
    dataType: DataType,
    pkgId: string,
    body: string,
    dataList: DataUploadRow[]
  ): Promise<UploadBatchResult> {
    let result: DataUploadHttpResult;
    try {
      result = await runtime.executeHttp(dataType, pkgId, body);
      if (result.code === NetCodeStatus.NETWORK_EXCEPTION_CODE) {
        FTInnerLogger.e(TAG, "Network not available");
        throw new Error("Network not available");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Network request failed: ${error as string}`);
      result = {
        code: NetCodeStatus.UNKNOWN_EXCEPTION_CODE,
        message: (error as Error).message || "",
        errorCode: ""
      };
    }

    return await this.handleUploadResponse(runtime, dataType, pkgId, result, dataList);
  }

  private async handleUploadResponse(
    runtime: DataUploadWorkerRuntime,
    dataType: DataType,
    pkgId: string,
    result: DataUploadHttpResult,
    dataList: DataUploadRow[]
  ): Promise<UploadBatchResult> {
    const code = result.code;
    const response = result.message;
    const errorCode = result.errorCode;

    if (this.isIgnoredClientError(code)) {
      this.markDataAsUploaded(dataType, dataList);
      await this.deleteLastQuery(runtime, dataList);
      await runtime.reduceCacheCount(dataType, dataList.length);
      this.resetErrorCount(dataType);
      const ignoredCount = this.incrementIgnoredClientErrorCount(dataType);
      const delayTime = this.getIgnoredClientBackoffMs(ignoredCount);
      this.traceUploadLane(
        `[BATCH] type=${dataType} code=${code} rows=${dataList.length} action=delete ignoredBackoff=${delayTime}ms ignoredCount=${ignoredCount} pkg=${pkgId}`
      );
      await runtime.sleep(delayTime);
      return UploadBatchResult.DELETE_WITH_IGNORED_BACKOFF;
    }

    if (this.shouldDeleteWithoutBackoff(code)) {
      this.markDataAsUploaded(dataType, dataList);
      await this.deleteLastQuery(runtime, dataList);
      await runtime.reduceCacheCount(dataType, dataList.length);
      this.resetErrorCount(dataType);
      this.resetIgnoredClientErrorCount(dataType);
      this.advancePackageGenerator(dataType, code);
      this.traceUploadLane(
        `[BATCH] type=${dataType} code=${code} rows=${dataList.length} action=delete backoff=0ms pkg=${pkgId}`
      );
      return UploadBatchResult.DELETE_NO_BACKOFF;
    }

    if (this.isRetryableUploadError(code)) {
      this.unmarkDataAsUploading(dataType, dataList);
      await this.reInsertData(runtime, dataList);
      this.resetIgnoredClientErrorCount(dataType);
      const retryCount = this.incrementErrorCount(dataType);
      const delayTime = this.getNormalBackoffMs(retryCount);
      FTInnerLogger.w(TAG,
        `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=reinsert retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
      await runtime.sleep(delayTime);
      return UploadBatchResult.RETRY_BACKOFF;
    }

    this.unmarkDataAsUploading(dataType, dataList);
    const retryCount = this.incrementErrorCount(dataType);
    const delayTime = this.getNormalBackoffMs(retryCount);
    FTInnerLogger.w(TAG,
      `<FT-UPLOAD-LANE> [BATCH] type=${dataType} code=${code} rows=${dataList.length} action=retry retryBackoff=${delayTime}ms retryCount=${retryCount} error=${errorCode} response=${response} pkg=${pkgId}`);
    await runtime.sleep(delayTime);
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
      if (this.uploadedDataIds.has(key) || this.uploadingDataIds.has(key) || seenIds.has(key)) {
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
      this.uploadedDataIds.add(key);
    }

    if (this.uploadedDataIds.size > Constants.MAX_SET_SIZE_UPLOAD) {
      const entries = Array.from(this.uploadedDataIds);
      this.uploadedDataIds.clear();
      const keepCount = Math.floor(Constants.MAX_SET_SIZE_UPLOAD / 2);
      for (let i = entries.length - keepCount; i < entries.length; i++) {
        this.uploadedDataIds.add(entries[i]);
      }
      FTInnerLogger.w(TAG,
        `<FT-BATCH-UPLOAD> Trimmed uploadedDataIds from ${entries.length} to ${this.uploadedDataIds.size} entries to prevent memory leak`);
    }

    if (this.uploadingDataIds.size > Constants.MAX_SET_SIZE_UPLOAD) {
      FTInnerLogger.w(TAG,
        `<FT-BATCH-UPLOAD> uploadingDataIds size (${this.uploadingDataIds.size}) exceeds limit, clearing to prevent memory leak`);
      this.uploadingDataIds.clear();
    }
  }

  private async queryFromData(
    runtime: DataUploadWorkerRuntime,
    dataType: DataType,
    pageSize: number
  ): Promise<DataUploadRow[]> {
    try {
      return await runtime.queryRows(dataType, pageSize);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Query data failed: ${dataType}, error: ${error as string}`);
      return [];
    }
  }

  private printUploadData(body: string): void {
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> ========== UPLOAD BODY PREVIEW ==========`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD>\n${body}`);
    FTInnerLogger.d(TAG, `<FT-BATCH-UPLOAD> ========================================`);
  }

  private async deleteLastQuery(runtime: DataUploadWorkerRuntime, list: DataUploadRow[]): Promise<void> {
    try {
      if (!list || list.length === 0) {
        return;
      }

      await runtime.deleteRows(list);
      await runtime.sleep(30);
    } catch (error) {
      FTInnerLogger.e(TAG, `<FT-BATCH-UPLOAD> Delete uploaded data failed: ${error as string}`);
    }
  }

  private async reInsertData(runtime: DataUploadWorkerRuntime, list: DataUploadRow[]): Promise<void> {
    try {
      await this.deleteLastQuery(runtime, list);

      const reInsertList: DataUploadRow[] = [];
      for (const data of list) {
        reInsertList.push({
          id: data.id,
          dataType: data.dataType,
          dataString: data.dataString,
          uuid: runtime.generateUUID(),
          time: data.time,
          customDataType: data.customDataType
        });
      }

      await runtime.insertRows(reInsertList, true);
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

  private generatePackageId(runtime: DataUploadWorkerRuntime, seqNumber: string, dataCount: number): string {
    const pid = this.getProcessId(runtime);
    const pidEncoded = this.encodeBase62(pid);
    const nanoId = this.generateNanoId(runtime);
    return `${seqNumber}.${pidEncoded}.${dataCount}.${nanoId}`;
  }

  private generateNanoId(runtime: DataUploadWorkerRuntime): string {
    const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const NANO_DIGIT = 12;
    let result = "";

    for (let i = 0; i < NANO_DIGIT; i++) {
      const randomIndex = Math.floor(runtime.getRandom() * BASE62.length);
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

  private getProcessId(runtime: DataUploadWorkerRuntime): number {
    if (DataUploadWorkerExecutor.cachedProcessId === undefined) {
      const seed = runtime.getCurrentTimeMs() ^ Math.floor(runtime.getRandom() * 1e6);
      DataUploadWorkerExecutor.cachedProcessId = Math.abs(seed % 65535) + 1;
    }
    return DataUploadWorkerExecutor.cachedProcessId;
  }

  private getCurrentNanoTime(runtime: DataUploadWorkerRuntime): number {
    return runtime.getCurrentTimeMs() * 1_000_000;
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
