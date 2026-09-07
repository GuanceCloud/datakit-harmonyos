import { DefaultSyncTaskManagerRuntime } from '@guancecloud/ft_sdk/src/main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '@guancecloud/ft_sdk/src/main/ets/components/internal/testaccess/SyncInternalTestAccess';
import { SDKUploadExecutePageResultDTO, SDKWorkerCommand, SDKWorkerRequest, SDKWorkerResponse } from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKWorkerProtocol';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './EntryDBAssert';
import { EntryWaitUtils } from './EntryWaitUtils';

/** Per-case collection evidence, independent of whether automatic upload removes DB rows. */
export class EntryRecordCapture extends DefaultSyncTaskManagerRuntime {
  private readonly records: Map<string, string[]> = new Map();

  start(): void {
    SyncInternalTestAccess.setRuntime(this);
  }

  stop(): void {
    SyncInternalTestAccess.resetRuntime();
  }

  async executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    // Preserve real transport and database behavior, including failures and retries.
    const response = await super.executeUploadWorkerCommand(request);
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE && response.ok && response.payload) {
      const result = response.payload as Object as SDKUploadExecutePageResultDTO;
      for (const row of result.rows) this.remember(row.dataType, row.dataString);
    }
    return response;
  }

  private remember(type: string, data: string): void {
    const values = this.records.get(type) ?? [];
    if (!values.includes(data)) values.push(data);
    this.records.set(type, values);
  }

  async waitForRecord(type: DataType, fragments: string[], timeoutMs: number): Promise<string | null> {
    let matched: string | null = null;
    await EntryWaitUtils.waitUntil(async () => {
      for (const row of await EntryDBAssert.querySyncRecords([type], 1000, true)) {
        this.remember(type, row.getDataString());
      }
      for (const data of this.records.get(type) ?? []) {
        if (fragments.every((fragment: string) => data.includes(fragment))) {
          matched = data;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return matched;
  }
}
