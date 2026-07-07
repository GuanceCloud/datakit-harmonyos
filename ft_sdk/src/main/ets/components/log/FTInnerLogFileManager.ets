import { Context } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { Constants } from '../Constants';
import { SDKTaskPriority, SDKTaskScheduler, SDKTaskType } from '../thread/SDKTaskScheduler';
import {
  createSDKWorkerTaskBridgeHandler,
  createSDKWorkerTaskFallbackRunner,
  createSDKWorkerTaskRequest
} from '../thread/SDKWorkerTaskBridge';
import {
  SDKDedicatedPoolType,
  SDKWorkerCommand
} from '../thread/SDKWorkerProtocol';

interface InnerLogFileRuntimeConfig {
  singleFileMaxSize: number;
  totalFileMaxSize: number;
  flushBatchSize: number;
  flushIntervalMs: number;
}

interface InnerLogRecord {
  level: string;
  tag: string;
  message: string;
  timestampMs: number;
}

interface InnerLogFileSnapshot {
  path: string;
  size: number;
  mtime: number;
  isCurrent: boolean;
}

export interface FTInnerLogFileStatus {
  enabled: boolean;
  initialized: boolean;
  logDir: string;
  currentFilePath: string;
  queueSize: number;
  isFlushing: boolean;
  droppedCount: number;
  lastError: string;
  singleFileMaxSize: number;
  totalFileMaxSize: number;
  flushBatchSize: number;
  flushIntervalMs: number;
}

const TAG = "FTInnerLogFileManager";

export class FTInnerLogFileManager {
  private static instance: FTInnerLogFileManager | null = null;
  private static readonly DOMAIN = 0x0001;
  private static readonly LOG_DIR_NAME = "ft_sdk_logs";
  private static readonly CURRENT_FILE_NAME = "ft_inner_current.log";
  private static readonly HISTORY_FILE_PREFIX = "ft_inner_";
  private static readonly HISTORY_FILE_SUFFIX = ".log";
  private static readonly DEFAULT_SINGLE_FILE_MAX_SIZE = 5 * 1024 * 1024;
  private static readonly MAX_SINGLE_FILE_MAX_SIZE = 10 * 1024 * 1024;
  private static readonly MIN_SINGLE_FILE_MAX_SIZE = 1024 * 1024;
  private static readonly DEFAULT_TOTAL_FILE_MAX_SIZE = 50 * 1024 * 1024;
  private static readonly MAX_TOTAL_FILE_MAX_SIZE = 100 * 1024 * 1024;
  private static readonly MIN_TOTAL_FILE_MAX_SIZE = 10 * 1024 * 1024;
  private static readonly DEFAULT_FLUSH_BATCH_SIZE = 20;
  private static readonly MAX_FLUSH_BATCH_SIZE = 100;
  private static readonly MIN_FLUSH_BATCH_SIZE = 1;
  private static readonly DEFAULT_FLUSH_INTERVAL_MS = 200;
  private static readonly MIN_FLUSH_INTERVAL_MS = 50;
  private static readonly MAX_FLUSH_INTERVAL_MS = 5000;
  private static readonly SERIAL_KEY = "inner-log-file";

  private enabled: boolean = false;
  private initialized: boolean = false;
  private logDir: string = "";
  private currentFilePath: string = "";
  private queue: InnerLogRecord[] = [];
  private flushTimer: number = -1;
  private isFlushing: boolean = false;
  private droppedCount: number = 0;
  private lastError: string = "";
  private config: InnerLogFileRuntimeConfig = {
    singleFileMaxSize: FTInnerLogFileManager.DEFAULT_SINGLE_FILE_MAX_SIZE,
    totalFileMaxSize: FTInnerLogFileManager.DEFAULT_TOTAL_FILE_MAX_SIZE,
    flushBatchSize: FTInnerLogFileManager.DEFAULT_FLUSH_BATCH_SIZE,
    flushIntervalMs: FTInnerLogFileManager.DEFAULT_FLUSH_INTERVAL_MS
  };

  private constructor() {
  }

  public static getInstance(): FTInnerLogFileManager {
    if (FTInnerLogFileManager.instance === null) {
      FTInnerLogFileManager.instance = new FTInnerLogFileManager();
    }
    return FTInnerLogFileManager.instance;
  }

  public init(
    context: Context,
    singleFileMaxSize?: number,
    totalFileMaxSize?: number,
    flushBatchSize?: number,
    flushIntervalMs?: number
  ): void {
    this.config = this.normalizeConfig(singleFileMaxSize, totalFileMaxSize, flushBatchSize, flushIntervalMs);
    this.logDir = this.joinPath(context.filesDir, FTInnerLogFileManager.LOG_DIR_NAME);
    this.currentFilePath = this.joinPath(this.logDir, FTInnerLogFileManager.CURRENT_FILE_NAME);
    this.enabled = true;
    this.initialized = true;
    this.lastError = "";

    this.submitSilentTask("innerLog.init", async () => {
      await this.ensureLogDir();
      await this.cleanupIfNeeded();
    });
  }

  public shutdown(flushPending: boolean = true): void {
    this.enabled = false;
    this.initialized = false;
    this.clearFlushTimer();
    if (flushPending) {
      this.flushNow();
    } else {
      this.queue = [];
    }
  }

  public append(level: string, tag: string, message: string): void {
    if (!this.enabled || !this.initialized) {
      return;
    }

    if (this.queue.length >= Constants.MAX_QUEUE_SIZE) {
      this.queue.shift();
      this.droppedCount++;
    }

    this.queue.push({
      level,
      tag,
      message,
      timestampMs: Date.now()
    });

    if (this.queue.length >= this.config.flushBatchSize) {
      this.startFlushNow();
      return;
    }

    this.scheduleFlush();
  }

  public async flushNow(): Promise<void> {
    this.clearFlushTimer();
    if (this.queue.length === 0 || this.isFlushing) {
      return;
    }

    this.isFlushing = true;
    await this.submitSilentTaskAndWait("innerLog.flushNow", async () => {
      await this.flushQueueSafely();
    });
  }

  public async clear(): Promise<void> {
    this.queue = [];
    this.clearFlushTimer();
    await this.submitSilentTaskAndWait("innerLog.clear", async () => {
      if (this.logDir.length === 0) {
        return;
      }
      await this.ensureLogDir();
      const files = await this.listManagedLogFiles(true);
      for (let i = 0; i < files.length; i++) {
        await this.deleteFile(files[i].path);
      }
    });
  }

  public getStatus(): FTInnerLogFileStatus {
    return {
      enabled: this.enabled,
      initialized: this.initialized,
      logDir: this.logDir,
      currentFilePath: this.currentFilePath,
      queueSize: this.queue.length,
      isFlushing: this.isFlushing,
      droppedCount: this.droppedCount,
      lastError: this.lastError,
      singleFileMaxSize: this.config.singleFileMaxSize,
      totalFileMaxSize: this.config.totalFileMaxSize,
      flushBatchSize: this.config.flushBatchSize,
      flushIntervalMs: this.config.flushIntervalMs
    };
  }

  public async getTotalLogSize(): Promise<number> {
    if (this.logDir.length === 0) {
      return 0;
    }

    try {
      const files = await this.listManagedLogFiles(true);
      let totalSize = 0;
      for (let i = 0; i < files.length; i++) {
        totalSize += files[i].size;
      }
      return totalSize;
    } catch (error) {
      this.recordError(`getTotalLogSize failed: ${String(error)}`);
      return 0;
    }
  }

  public async getLogFileCount(): Promise<number> {
    if (this.logDir.length === 0) {
      return 0;
    }

    try {
      const files = await this.listManagedLogFiles(true);
      return files.length;
    } catch (error) {
      this.recordError(`getLogFileCount failed: ${String(error)}`);
      return 0;
    }
  }

  private scheduleFlush(): void {
    if (this.flushTimer >= 0 || this.isFlushing) {
      return;
    }

    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.startFlushNow();
    }, this.config.flushIntervalMs) as number;
  }

  private startFlushNow(): void {
    this.clearFlushTimer();
    if (this.queue.length === 0 || this.isFlushing) {
      return;
    }

    this.isFlushing = true;
    this.submitSilentTask("innerLog.flush", async () => {
      await this.flushQueueSafely();
    });
  }

  private async flushQueueSafely(): Promise<void> {
    try {
      await this.flushQueue();
    } catch (error) {
      this.recordError(`flushQueue failed: ${String(error)}`);
    } finally {
      this.isFlushing = false;
      if (this.enabled && this.queue.length > 0) {
        if (this.queue.length >= this.config.flushBatchSize) {
          this.startFlushNow();
        } else {
          this.scheduleFlush();
        }
      }
    }
  }

  private async flushQueue(): Promise<void> {
    if (this.currentFilePath.length === 0) {
      return;
    }

    const batch = this.queue.splice(0, this.queue.length);
    if (batch.length === 0) {
      return;
    }

    await this.ensureLogDir();
    const batchText = this.formatBatch(batch);
    await this.rotateIfNeeded(batchText.length);

    const file = await fileIo.open(
      this.currentFilePath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
    );
    try {
      await fileIo.write(file.fd, batchText);
    } finally {
      await fileIo.close(file);
    }

    await this.rotateIfNeeded(0);
  }

  private async rotateIfNeeded(incomingSize: number): Promise<void> {
    const currentSize = await this.getFileSize(this.currentFilePath);
    if (currentSize <= 0 && incomingSize <= this.config.singleFileMaxSize) {
      return;
    }

    if (currentSize + incomingSize <= this.config.singleFileMaxSize) {
      return;
    }

    await this.rotateCurrentFile();
    await this.cleanupIfNeeded();
  }

  private async rotateCurrentFile(): Promise<void> {
    if (this.currentFilePath.length === 0) {
      return;
    }

    const currentSize = await this.getFileSize(this.currentFilePath);
    if (currentSize <= 0) {
      return;
    }

    const rotatedPath = this.joinPath(this.logDir, this.buildHistoryFileName());
    try {
      await fileIo.rename(this.currentFilePath, rotatedPath);
    } catch (error) {
      this.recordError(`rotateCurrentFile failed: ${String(error)}`);
    }
  }

  private async cleanupIfNeeded(): Promise<void> {
    if (this.logDir.length === 0) {
      return;
    }

    const files = await this.listManagedLogFiles(true);
    let totalSize = 0;
    for (let i = 0; i < files.length; i++) {
      totalSize += files[i].size;
    }

    if (totalSize <= this.config.totalFileMaxSize) {
      return;
    }

    const deletableFiles = files.filter((file: InnerLogFileSnapshot) => !file.isCurrent)
      .sort((left: InnerLogFileSnapshot, right: InnerLogFileSnapshot) => left.mtime - right.mtime);

    for (let i = 0; i < deletableFiles.length && totalSize > this.config.totalFileMaxSize; i++) {
      await this.deleteFile(deletableFiles[i].path);
      totalSize -= deletableFiles[i].size;
    }
  }

  private async ensureLogDir(): Promise<void> {
    if (this.logDir.length === 0) {
      return;
    }

    try {
      const exists = await fileIo.access(this.logDir);
      if (exists) {
        return;
      }
    } catch (error) {
      // Create below.
    }

    try {
      await fileIo.mkdir(this.logDir);
    } catch (error) {
      const existsAfterCreate = await this.pathExists(this.logDir);
      if (!existsAfterCreate) {
        throw new Error(String(error));
      }
    }
  }

  private async listManagedLogFiles(includeCurrent: boolean): Promise<InnerLogFileSnapshot[]> {
    const snapshots: InnerLogFileSnapshot[] = [];
    if (this.logDir.length === 0) {
      return snapshots;
    }

    const exists = await this.pathExists(this.logDir);
    if (!exists) {
      return snapshots;
    }

    const names = await fileIo.listFile(this.logDir);
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const isCurrent = name === FTInnerLogFileManager.CURRENT_FILE_NAME;
      if (!includeCurrent && isCurrent) {
        continue;
      }
      if (!isCurrent && !this.isHistoryLogFile(name)) {
        continue;
      }

      const path = this.joinPath(this.logDir, name);
      try {
        const stat = await fileIo.stat(path);
        snapshots.push({
          path,
          size: stat.size,
          mtime: stat.mtime,
          isCurrent
        });
      } catch (error) {
        this.recordError(`stat log file failed: ${String(error)}`);
      }
    }

    return snapshots;
  }

  private isHistoryLogFile(name: string): boolean {
    return name.startsWith(FTInnerLogFileManager.HISTORY_FILE_PREFIX) &&
      name.endsWith(FTInnerLogFileManager.HISTORY_FILE_SUFFIX);
  }

  private async getFileSize(path: string): Promise<number> {
    if (path.length === 0) {
      return 0;
    }

    try {
      const exists = await this.pathExists(path);
      if (!exists) {
        return 0;
      }
      const stat = await fileIo.stat(path);
      return stat.size;
    } catch (error) {
      return 0;
    }
  }

  private async deleteFile(path: string): Promise<void> {
    try {
      const exists = await this.pathExists(path);
      if (!exists) {
        return;
      }
      await fileIo.unlink(path);
    } catch (error) {
      this.recordError(`deleteFile failed: ${String(error)}`);
    }
  }

  private async pathExists(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch (error) {
      return false;
    }
  }

  private submitSilentTask(name: string, task: () => Promise<void>): void {
    try {
      const command = SDKWorkerCommand.INNER_LOG_FILE_RUN;
      const runTask = async () => {
        await task();
      };
      SDKTaskScheduler.getInstance().submitTask({
        type: SDKTaskType.INNER_LOG_FILE,
        name,
        priority: SDKTaskPriority.BACKGROUND,
        serialKey: FTInnerLogFileManager.SERIAL_KEY,
        costHint: 'normal',
        silent: true,
        workerRequest: createSDKWorkerTaskRequest(
          SDKDedicatedPoolType.DATA_PROCESS,
          command,
          name,
          SDKTaskPriority.BACKGROUND
        ),
        workerFallbackRunner: createSDKWorkerTaskFallbackRunner(name, command, runTask),
        workerBridgeHandler: createSDKWorkerTaskBridgeHandler(name, command, runTask)
      });
    } catch (error) {
      this.isFlushing = false;
      this.recordError(`submitSilentTask failed: ${String(error)}`);
    }
  }

  private async submitSilentTaskAndWait(name: string, task: () => Promise<void>): Promise<void> {
    try {
      const command = SDKWorkerCommand.INNER_LOG_FILE_RUN;
      const runTask = async () => {
        await task();
      };
      await SDKTaskScheduler.getInstance().submitTaskAndWait({
        type: SDKTaskType.INNER_LOG_FILE,
        name,
        priority: SDKTaskPriority.BACKGROUND,
        serialKey: FTInnerLogFileManager.SERIAL_KEY,
        costHint: 'normal',
        silent: true,
        workerRequest: createSDKWorkerTaskRequest(
          SDKDedicatedPoolType.DATA_PROCESS,
          command,
          name,
          SDKTaskPriority.BACKGROUND
        ),
        workerFallbackRunner: createSDKWorkerTaskFallbackRunner(name, command, runTask),
        workerBridgeHandler: createSDKWorkerTaskBridgeHandler(name, command, runTask)
      });
    } catch (error) {
      this.recordError(`submitSilentTaskAndWait failed: ${String(error)}`);
    }
  }

  private normalizeConfig(
    inputSingleFileMaxSize?: number,
    inputTotalFileMaxSize?: number,
    inputFlushBatchSize?: number,
    inputFlushIntervalMs?: number
  ): InnerLogFileRuntimeConfig {
    const singleFileMaxSize = this.clampNumber(
      inputSingleFileMaxSize,
      FTInnerLogFileManager.DEFAULT_SINGLE_FILE_MAX_SIZE,
      FTInnerLogFileManager.MIN_SINGLE_FILE_MAX_SIZE,
      FTInnerLogFileManager.MAX_SINGLE_FILE_MAX_SIZE
    );
    const totalFileMaxSize = this.clampNumber(
      inputTotalFileMaxSize,
      FTInnerLogFileManager.DEFAULT_TOTAL_FILE_MAX_SIZE,
      Math.max(FTInnerLogFileManager.MIN_TOTAL_FILE_MAX_SIZE, singleFileMaxSize),
      FTInnerLogFileManager.MAX_TOTAL_FILE_MAX_SIZE
    );

    return {
      singleFileMaxSize,
      totalFileMaxSize,
      flushBatchSize: this.clampNumber(
        inputFlushBatchSize,
        FTInnerLogFileManager.DEFAULT_FLUSH_BATCH_SIZE,
        FTInnerLogFileManager.MIN_FLUSH_BATCH_SIZE,
        FTInnerLogFileManager.MAX_FLUSH_BATCH_SIZE
      ),
      flushIntervalMs: this.clampNumber(
        inputFlushIntervalMs,
        FTInnerLogFileManager.DEFAULT_FLUSH_INTERVAL_MS,
        FTInnerLogFileManager.MIN_FLUSH_INTERVAL_MS,
        FTInnerLogFileManager.MAX_FLUSH_INTERVAL_MS
      )
    };
  }

  private clampNumber(value: number | undefined, defaultValue: number, minValue: number, maxValue: number): number {
    if (value === undefined || isNaN(value) || !isFinite(value)) {
      return defaultValue;
    }
    return Math.max(minValue, Math.min(maxValue, Math.floor(value)));
  }

  private formatBatch(batch: InnerLogRecord[]): string {
    let result = "";
    for (let i = 0; i < batch.length; i++) {
      result += this.formatRecord(batch[i]);
    }
    return result;
  }

  private formatRecord(record: InnerLogRecord): string {
    const timestamp = new Date(record.timestampMs).toISOString();
    return `${timestamp} ${record.level}/${this.sanitize(record.tag)}: ${this.sanitize(record.message)}\n`;
  }

  private sanitize(value: string): string {
    return `${value}`.replace(/\r/g, "\\r").replace(/\n/g, "\\n");
  }

  private buildHistoryFileName(): string {
    return `${FTInnerLogFileManager.HISTORY_FILE_PREFIX}${this.formatFileTimestamp(new Date())}_${Date.now()}${FTInnerLogFileManager.HISTORY_FILE_SUFFIX}`;
  }

  private formatFileTimestamp(date: Date): string {
    return `${date.getFullYear()}${this.pad2(date.getMonth() + 1)}${this.pad2(date.getDate())}_${this.pad2(date.getHours())}${this.pad2(date.getMinutes())}${this.pad2(date.getSeconds())}`;
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private joinPath(parent: string, child: string): string {
    if (parent.endsWith('/')) {
      return `${parent}${child}`;
    }
    return `${parent}/${child}`;
  }

  private clearFlushTimer(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
  }

  private recordError(message: string): void {
    this.lastError = message;
    try {
      hilog.error(FTInnerLogFileManager.DOMAIN, TAG, '%{public}s', message);
    } catch (error) {
      // Keep file logging best-effort.
    }
  }
}
