import { UiTestUtils } from './UiTestUtils';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { FTDBTaskPoolExecutor } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBTaskPoolExecutor';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { ViewBean } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/ViewBean';
import { ActionBean } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/ActionBean';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { DatabaseHelper } from '@guancecloud/ft_sdk/src/main/ets/components/db/base/DatabaseHelper';
import { FT_SYNC_DATA_FLAT_TABLE_NAME, RECORD_COLUMN_DATA_UUID } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTSQL';
import { EntryWaitUtils } from './EntryWaitUtils';

export class EntryDBAssert {
  static async getAppContext(): Promise<Context> {
    try {
      const ability = await AbilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
      return ability.context as Context;
    } catch (_error) {
      return globalThis.getContext() as Context;
    }
  }

  static async getManager(): Promise<FTDBManager> {
    const dbManager = FTDBManager.getInstance(await EntryDBAssert.getAppContext());
    await dbManager.init();
    return dbManager;
  }

  static async resetAll(): Promise<void> {
    if (!UiTestUtils.shouldClearData(true)) return;
    await FTDBTaskPoolExecutor.deleteAll(await EntryDBAssert.getAppContext());
  }

  static async cleanupAll(): Promise<void> {
    if (!UiTestUtils.shouldClearData(false)) return;
    await FTDBTaskPoolExecutor.deleteAll(await EntryDBAssert.getAppContext());
  }

  /** Query the exact batch even if later events move it outside a paged query. */
  static async countSyncRecordsWithUuids(uuids: string[]): Promise<number> {
    if (uuids.length === 0) {
      throw new Error('Upload verification requires a non-empty batch of UUIDs');
    }
    const store = await DatabaseHelper.getInstance(await EntryDBAssert.getAppContext()).initDatabase();
    const placeholders = uuids.map(() => '?').join(',');
    const result = await store.querySql(
      `SELECT COUNT(*) AS count FROM ${FT_SYNC_DATA_FLAT_TABLE_NAME} ` +
        `WHERE ${RECORD_COLUMN_DATA_UUID} IN (${placeholders})`, uuids
    );
    try {
      if (!result.goToFirstRow()) {
        throw new Error('Cannot count the pending upload batch');
      }
      return result.getLong(result.getColumnIndex('count'));
    } finally {
      result.close();
    }
  }

  static async querySyncRecords(types: DataType[], limit: number = 100, newestFirst: boolean = false): Promise<SyncData[]> {
    return await FTDBTaskPoolExecutor.querySyncData(await EntryDBAssert.getAppContext(), types, limit, newestFirst);
  }

  static async waitForViewMatching(candidates: string[], timeoutMs: number = 6000): Promise<ViewBean | null> {
    let matched: ViewBean | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const views = await (await EntryDBAssert.getManager()).querySumView(100);
      for (const view of views) {
        for (const candidate of candidates) {
          if (view.getViewName().includes(candidate)) {
            matched = view;
            return true;
          }
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForActionMatching(candidates: string[], timeoutMs: number = 6000): Promise<ActionBean | null> {
    let matched: ActionBean | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const actions = await (await EntryDBAssert.getManager()).querySumAction(100);
      for (const action of actions) {
        for (const candidate of candidates) {
          if (action.getActionName().includes(candidate)) {
            matched = action;
            return true;
          }
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForWebViewPayload(timeoutMs: number = 6000): Promise<boolean> {
    return await EntryWaitUtils.waitUntil(async () => {
      const records = await EntryDBAssert.querySyncRecords([DataType.RUM_WEBVIEW]);
      return records.length > 0;
    }, timeoutMs);
  }

  static async waitForSyncRecordContaining(type: DataType, fragments: string[], timeoutMs: number = 6000): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const records = await EntryDBAssert.querySyncRecords([type]);
      for (const record of records) {
        let containsAll = true;
        for (const fragment of fragments) {
          if (!record.getDataString().includes(fragment)) {
            containsAll = false;
            break;
          }
        }
        if (containsAll) {
          matched = record;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForRecentSyncRecordContainingAny(
    type: DataType,
    requiredFragments: string[],
    anyFragments: string[],
    timeoutMs: number = 6000
  ): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const records = await EntryDBAssert.querySyncRecords([type], 1000, true);
      for (const record of records) {
        const data = record.getDataString();
        const lowerData = data.toLowerCase();
        let containsRequired = true;
        for (const fragment of requiredFragments) {
          if (!lowerData.includes(fragment.toLowerCase())) {
            containsRequired = false;
            break;
          }
        }
        if (!containsRequired) {
          continue;
        }

        let containsAny = anyFragments.length === 0;
        for (const fragment of anyFragments) {
          if (lowerData.includes(fragment.toLowerCase())) {
            containsAny = true;
            break;
          }
        }
        if (containsAny) {
          matched = record;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForRecentSyncRecordContainingAnySince(
    type: DataType,
    requiredFragments: string[],
    anyFragments: string[],
    sinceTime: number,
    timeoutMs: number = 6000
  ): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const records = await EntryDBAssert.querySyncRecords([type], 1000, true);
      for (const record of records) {
        if (record.getTime() < sinceTime) {
          continue;
        }

        const data = record.getDataString();
        const lowerData = data.toLowerCase();
        let containsRequired = true;
        for (const fragment of requiredFragments) {
          if (!lowerData.includes(fragment.toLowerCase())) {
            containsRequired = false;
            break;
          }
        }
        if (!containsRequired) {
          continue;
        }

        let containsAny = anyFragments.length === 0;
        for (const fragment of anyFragments) {
          if (lowerData.includes(fragment.toLowerCase())) {
            containsAny = true;
            break;
          }
        }
        if (containsAny) {
          matched = record;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async dumpSyncRecords(limit: number = 20): Promise<string> {
    const records = await EntryDBAssert.querySyncRecords([], limit, true);
    if (records.length === 0) {
      return '<empty>';
    }

    const lines: string[] = [];
    for (let index = 0; index < records.length; index++) {
      const record = records[index];
      lines.push(
        `#${index + 1} [${record.getDataType()}] time=${record.getTime()} uuid=${record.getUuid()} ${record.getDataString()}`
      );
    }
    return lines.join('\n');
  }
}
