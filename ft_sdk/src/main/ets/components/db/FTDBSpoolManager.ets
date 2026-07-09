import { Context } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { FTInnerLogger } from '../log/FTLogger';
import { FTDBManager } from './FTDBManager';
import { SyncData, SyncDataJSON } from './bean/SyncData';

interface SyncDataSpoolRecord {
  source: string;
  seq: number;
  createdAt: number;
  data: SyncDataJSON;
}

export interface FTDBSpoolStatus {
  initialized: boolean;
  spoolPath: string;
  pendingRecords: number;
  lastError: string;
}

const TAG = "FTDBSpoolManager";

export class FTDBSpoolManager {
  private static instance: FTDBSpoolManager | null = null;
  private static readonly SPOOL_DIR_NAME = "ft_sdk_spool";
  private static readonly SPOOL_FILE_NAME = "sync_data_spool.ndjson";

  private initialized: boolean = false;
  private spoolDir: string = "";
  private spoolPath: string = "";
  private fileTail: Promise<void> = Promise.resolve();
  private nextSeq: number = 0;
  private pendingRecords: number = 0;
  private lastError: string = "";

  private constructor() {
  }

  public static getInstance(): FTDBSpoolManager {
    if (FTDBSpoolManager.instance === null) {
      FTDBSpoolManager.instance = new FTDBSpoolManager();
    }
    return FTDBSpoolManager.instance;
  }

  public init(context: Context): void {
    this.spoolDir = this.joinPath(context.filesDir, FTDBSpoolManager.SPOOL_DIR_NAME);
    this.spoolPath = this.joinPath(this.spoolDir, FTDBSpoolManager.SPOOL_FILE_NAME);
    this.initialized = true;
    this.lastError = "";
    this.enqueueFileTask("spool.init", async () => {
      await this.ensureSpoolDir();
      this.pendingRecords = await this.countRecords();
    }).catch((error: Error) => {
      this.recordError(`init failed: ${error.message}`);
    });
  }

  public async appendSyncData(source: string, dataList: SyncData[]): Promise<number> {
    if (!this.initialized || this.spoolPath.length === 0 || !dataList || dataList.length === 0) {
      return 0;
    }

    const validRows = dataList.filter((data: SyncData) => data && data.isValid());
    if (validRows.length === 0) {
      return 0;
    }

    return await this.enqueueFileTask("spool.append", async () => {
      await this.ensureSpoolDir();
      const now = Date.now();
      let text = "";
      for (const data of validRows) {
        const record: SyncDataSpoolRecord = {
          source,
          seq: this.nextSeq++,
          createdAt: now,
          data: data.toJSON()
        };
        text += `${JSON.stringify(record)}\n`;
      }

      const file = await fileIo.open(
        this.spoolPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
      );
      try {
        await fileIo.write(file.fd, text);
      } finally {
        await fileIo.close(file);
      }
      this.pendingRecords += validRows.length;
      FTInnerLogger.d(TAG, `Spooled ${validRows.length} sync records from ${source}`);
      return validRows.length;
    });
  }

  public async removeSyncData(dataList: SyncData[]): Promise<number> {
    if (!this.initialized || this.spoolPath.length === 0 || !dataList || dataList.length === 0) {
      return 0;
    }

    return await this.enqueueFileTask("spool.remove", async () => {
      const records = await this.readRecordsLocked();
      if (records.length === 0) {
        return 0;
      }

      const keysToRemove: Set<string> = new Set();
      for (const data of dataList) {
        keysToRemove.add(this.buildSyncDataKey(data.toJSON()));
      }

      const remaining: SyncDataSpoolRecord[] = [];
      let removed = 0;
      for (const record of records) {
        const key = this.buildSyncDataKey(record.data);
        if (keysToRemove.has(key)) {
          removed++;
          continue;
        }
        remaining.push(record);
      }

      await this.rewriteRecordsLocked(remaining);
      this.pendingRecords = remaining.length;
      return removed;
    });
  }

  public async replay(context: Context, reason: string = "manual"): Promise<number> {
    if (!this.initialized) {
      this.init(context);
    }

    const records = await this.readRecords();
    if (records.length === 0) {
      return 0;
    }

    const rows: SyncData[] = [];
    for (const record of records) {
      const row = SyncData.fromJSON(record.data);
      if (row.isValid()) {
        rows.push(row);
      }
    }
    if (rows.length === 0) {
      return 0;
    }

    const dbManager = FTDBManager.getInstance(context);
    const result = await dbManager.writeSyncDataAtomically(
      `spool.replay:${reason}`,
      rows,
      {
        applyCachePolicy: true,
        reInsert: false,
        forceTransaction: true
      }
    );

    if (result.success) {
      await this.removeSyncData(rows);
      FTInnerLogger.i(TAG,
        `Replayed ${rows.length} spooled sync records, inserted=${result.inserted}, updated=${result.updated}, dropped=${result.dropped}`);
      return rows.length;
    }

    this.recordError(`replay failed: ${result.errorMessage}`);
    return 0;
  }

  public async clear(): Promise<void> {
    await this.enqueueFileTask("spool.clear", async () => {
      if (this.spoolPath.length === 0) {
        return;
      }
      const exists = await this.pathExists(this.spoolPath);
      if (exists) {
        await fileIo.unlink(this.spoolPath);
      }
      this.pendingRecords = 0;
    });
  }

  public getStatus(): FTDBSpoolStatus {
    return {
      initialized: this.initialized,
      spoolPath: this.spoolPath,
      pendingRecords: this.pendingRecords,
      lastError: this.lastError
    };
  }

  private async readRecords(): Promise<SyncDataSpoolRecord[]> {
    return await this.enqueueFileTask("spool.read", async () => {
      return await this.readRecordsLocked();
    });
  }

  private async countRecords(): Promise<number> {
    const records = await this.readRecordsLocked();
    return records.length;
  }

  private async readRecordsLocked(): Promise<SyncDataSpoolRecord[]> {
    if (this.spoolPath.length === 0) {
      return [];
    }
    const exists = await this.pathExists(this.spoolPath);
    if (!exists) {
      this.pendingRecords = 0;
      return [];
    }

    const stat = await fileIo.stat(this.spoolPath);
    if (stat.size <= 0) {
      this.pendingRecords = 0;
      return [];
    }

    const file = fileIo.openSync(this.spoolPath, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buffer);
      if (readLen <= 0) {
        this.pendingRecords = 0;
        return [];
      }
      const textDecoder = util.TextDecoder.create('utf-8');
      const content = textDecoder.decodeWithStream(new Uint8Array(buffer.slice(0, readLen)), { stream: false });
      const lines = content.split('\n');
      const records: SyncDataSpoolRecord[] = [];
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.length === 0) {
          continue;
        }
        try {
          const parsed = JSON.parse(trimmed) as SyncDataSpoolRecord;
          if (parsed && parsed.data) {
            records.push(parsed);
          }
        } catch (error) {
          this.recordError(`skip corrupt spool record: ${String(error)}`);
        }
      }
      this.pendingRecords = records.length;
      return records;
    } finally {
      fileIo.closeSync(file);
    }
  }

  private async rewriteRecordsLocked(records: SyncDataSpoolRecord[]): Promise<void> {
    if (this.spoolPath.length === 0) {
      return;
    }

    const exists = await this.pathExists(this.spoolPath);
    if (exists) {
      await fileIo.unlink(this.spoolPath);
    }

    if (records.length === 0) {
      return;
    }

    await this.ensureSpoolDir();
    let text = "";
    for (const record of records) {
      text += `${JSON.stringify(record)}\n`;
    }
    const file = await fileIo.open(
      this.spoolPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE
    );
    try {
      await fileIo.write(file.fd, text);
    } finally {
      await fileIo.close(file);
    }
  }

  private buildSyncDataKey(data: SyncDataJSON): string {
    const type = data.customDataTypeString && data.customDataTypeString.length > 0 ?
      data.customDataTypeString : `${data.dataType}`;
    return `${type}|${data.uuid || ''}|${data.time || 0}`;
  }

  private async enqueueFileTask<T>(name: string, runner: () => Promise<T>): Promise<T> {
    const previousTail = this.fileTail.catch(() => {});
    let releaseCurrent: () => void = () => {};
    const currentTail = new Promise<void>((resolve) => {
      releaseCurrent = resolve;
    });
    this.fileTail = previousTail.then(() => currentTail);

    await previousTail;
    try {
      return await runner();
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      this.recordError(`${name}: ${normalized.message}`);
      throw normalized;
    } finally {
      releaseCurrent();
    }
  }

  private async ensureSpoolDir(): Promise<void> {
    if (this.spoolDir.length === 0) {
      return;
    }
    const exists = await this.pathExists(this.spoolDir);
    if (exists) {
      return;
    }
    try {
      await fileIo.mkdir(this.spoolDir);
    } catch (error) {
      const existsAfterCreate = await this.pathExists(this.spoolDir);
      if (!existsAfterCreate) {
        throw new Error(String(error));
      }
    }
  }

  private async pathExists(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch (error) {
      return false;
    }
  }

  private joinPath(parent: string, child: string): string {
    if (parent.endsWith('/')) {
      return `${parent}${child}`;
    }
    return `${parent}/${child}`;
  }

  private recordError(message: string): void {
    this.lastError = message;
    FTInnerLogger.e(TAG, message);
  }
}
