import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { FTDBManager } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBManager';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { WaitUtils } from './WaitUtils';

export class ExtDBAssert {
  static async getAppContext(): Promise<Context> {
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    try {
      const ability = await delegator.getCurrentTopAbility();
      if (ability?.context) {
        return ability.context as Context;
      }
    } catch (_error) {
    }

    try {
      const context = globalThis.getContext() as Context;
      if (context) {
        return context;
      }
    } catch (_error) {
    }

    return delegator.getAppContext() as Context;
  }

  static async getManager(): Promise<FTDBManager> {
    const dbManager = FTDBManager.getInstance(await ExtDBAssert.getAppContext());
    await dbManager.init();
    return dbManager;
  }

  static async resetAll(): Promise<void> {
    const dbManager = await ExtDBAssert.getManager();
    await dbManager.resetDatabase();
  }

  static async cleanupAll(): Promise<void> {
    const dbManager = await ExtDBAssert.getManager();
    await dbManager.delete();
  }

  static async querySyncData(types: DataType[], limit: number = 100): Promise<SyncData[]> {
    const dbManager = await ExtDBAssert.getManager();
    return await dbManager.queryFtOperation(types, limit);
  }

  static async querySyncCount(types: DataType[]): Promise<number> {
    const dbManager = await ExtDBAssert.getManager();
    return await dbManager.queryTotalCount(types);
  }

  static async waitForSyncCount(
    types: DataType[],
    expectedCount: number,
    timeoutMs: number = 5000
  ): Promise<boolean> {
    return await WaitUtils.waitUntil(async () => {
      return await ExtDBAssert.querySyncCount(types) === expectedCount;
    }, timeoutMs);
  }

  static async waitForSyncRecordContaining(
    type: DataType,
    fragments: string[],
    timeoutMs: number = 5000
  ): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await WaitUtils.waitUntil(async () => {
      const records = await ExtDBAssert.querySyncData([type], 100);
      for (const record of records) {
        if (ExtDBAssert.containsAll(record.getDataString(), fragments)) {
          matched = record;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForNoSyncRecordWithUuid(
    type: DataType,
    uuid: string,
    timeoutMs: number = 5000
  ): Promise<boolean> {
    if (uuid.length === 0) {
      return false;
    }

    return await WaitUtils.waitUntil(async () => {
      const records = await ExtDBAssert.querySyncData([type], 100);
      for (const record of records) {
        if (record.getUuid() === uuid) {
          return false;
        }
      }
      return true;
    }, timeoutMs);
  }

  static async dumpSyncRecords(types: DataType[] = [DataType.RUM_APP], limit: number = 20): Promise<string> {
    const records = await ExtDBAssert.querySyncData(types, limit);
    const lines: string[] = [];
    for (const record of records) {
      lines.push(`${record.getUuid()} ${record.getDataString()}`);
    }
    return lines.join('\n');
  }

  static containsAll(value: string, fragments: string[]): boolean {
    for (const fragment of fragments) {
      if (!value.includes(fragment)) {
        return false;
      }
    }
    return true;
  }
}
