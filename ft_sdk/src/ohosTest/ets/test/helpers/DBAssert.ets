import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { FTDBManager } from '../../../../main/ets/components/db/FTDBManager';
import { SyncData } from '../../../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../../../main/ets/components/db/bean/ViewBean';
import { ActionBean } from '../../../../main/ets/components/db/bean/ActionBean';
import { DataType } from '../../../../main/ets/components/enum/Enums';
import { WaitUtils } from './WaitUtils';

export class DBAssert {
  static getAppContext(): Context {
    return AbilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
  }

  static async getManager(): Promise<FTDBManager> {
    const dbManager = FTDBManager.getInstance(DBAssert.getAppContext());
    await dbManager.init();
    return dbManager;
  }

  static async resetAll(): Promise<void> {
    const dbManager = await DBAssert.getManager();
    await dbManager.resetDatabase();
  }

  static async cleanupAll(): Promise<void> {
    const dbManager = await DBAssert.getManager();
    await dbManager.delete();
  }

  static async querySyncData(types: DataType[], limit: number = 100): Promise<SyncData[]> {
    const dbManager = await DBAssert.getManager();
    return await dbManager.queryFtOperation(types, limit);
  }

  static async querySyncCount(types: DataType[]): Promise<number> {
    const dbManager = await DBAssert.getManager();
    return await dbManager.queryTotalCount(types);
  }

  static async queryViews(limit: number = 50): Promise<ViewBean[]> {
    const dbManager = await DBAssert.getManager();
    return await dbManager.querySumView(limit);
  }

  static async queryActions(limit: number = 50): Promise<ActionBean[]> {
    const dbManager = await DBAssert.getManager();
    return await dbManager.querySumAction(limit);
  }

  static async waitForSyncCount(types: DataType[], expectedCount: number, timeoutMs: number = 5000): Promise<boolean> {
    return await WaitUtils.waitUntil(async () => {
      return await DBAssert.querySyncCount(types) === expectedCount;
    }, timeoutMs);
  }

  static async waitForSyncRecordContaining(type: DataType, fragments: string[], timeoutMs: number = 5000): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await WaitUtils.waitUntil(async () => {
      const records = await DBAssert.querySyncData([type], 100);
      for (const record of records) {
        if (DBAssert.containsAll(record.getDataString(), fragments)) {
          matched = record;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForViewNamed(viewName: string, timeoutMs: number = 5000): Promise<ViewBean | null> {
    let matched: ViewBean | null = null;
    const found = await WaitUtils.waitUntil(async () => {
      const views = await DBAssert.queryViews(100);
      for (const view of views) {
        if (view.getViewName().includes(viewName)) {
          matched = view;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
  }

  static async waitForActionNamed(actionName: string, timeoutMs: number = 5000): Promise<ActionBean | null> {
    let matched: ActionBean | null = null;
    const found = await WaitUtils.waitUntil(async () => {
      const actions = await DBAssert.queryActions(100);
      for (const action of actions) {
        if (action.getActionName().includes(actionName)) {
          matched = action;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? matched : null;
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
