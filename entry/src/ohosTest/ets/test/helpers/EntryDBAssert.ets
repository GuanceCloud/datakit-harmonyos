import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { ViewBean } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/ViewBean';
import { ActionBean } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/ActionBean';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
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
    const dbManager = await EntryDBAssert.getManager();
    await dbManager.resetDatabase();
  }

  static async cleanupAll(): Promise<void> {
    const dbManager = await EntryDBAssert.getManager();
    await dbManager.delete();
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
      const records = await (await EntryDBAssert.getManager()).queryFtOperation([DataType.RUM_WEBVIEW], 100);
      const view = await EntryDBAssert.waitForViewMatching(['WebViewPage', 'WebView'], 300);
      return records.length > 0 || view !== null;
    }, timeoutMs);
  }

  static async waitForSyncRecordContaining(type: DataType, fragments: string[], timeoutMs: number = 6000): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await EntryWaitUtils.waitUntil(async () => {
      const records = await (await EntryDBAssert.getManager()).queryFtOperation([type], 100);
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
      const manager = await EntryDBAssert.getManager();
      const records = await manager.queryFtOperation([type], 1000, true);
      const fallbackRecords = await manager.queryFtOperation([], 1000, true);
      const candidates = records.concat(fallbackRecords);

      for (const record of candidates) {
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
}
