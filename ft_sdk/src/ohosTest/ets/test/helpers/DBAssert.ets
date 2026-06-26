import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import relationalStore from '@ohos.data.relationalStore';
import { FTDBManager } from '../../../../main/ets/components/db/FTDBManager';
import { SyncData } from '../../../../main/ets/components/db/bean/SyncData';
import { ViewBean } from '../../../../main/ets/components/db/bean/ViewBean';
import { ActionBean } from '../../../../main/ets/components/db/bean/ActionBean';
import { DataType } from '../../../../main/ets/components/enum/Enums';
import { DataBaseCallBack } from '../../../../main/ets/components/db/base/DataBaseCallBack';
import * as FTSQL from '../../../../main/ets/components/db/FTSQL';
import { WaitUtils } from './WaitUtils';

export class DBAssert {
  private static validContext: Context | null = null;

  private static async getAppContextCandidates(): Promise<Context[]> {
    const contexts: Context[] = [];
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();

    try {
      const context = delegator.getAppContext() as Context;
      if (context) {
        contexts.push(context);
      }
    } catch (_error) {
    }

    try {
      const ability = await delegator.getCurrentTopAbility();
      if (ability?.context) {
        contexts.push(ability.context as Context);
      }
    } catch (_error) {
    }

    try {
      const context = globalThis.getContext() as Context;
      if (context) {
        contexts.push(context);
      }
    } catch (_error) {
    }

    return contexts;
  }

  static async getAppContext(): Promise<Context> {
    if (DBAssert.validContext) {
      try {
        const dbManager = FTDBManager.getInstance(DBAssert.validContext);
        await dbManager.init();
        return DBAssert.validContext;
      } catch (error) {
        DBAssert.validContext = null;
        FTDBManager.resetInstanceInternal();
      }
    }

    const contexts = await DBAssert.getAppContextCandidates();
    if (contexts.length === 0) {
      throw new Error('No available test context');
    }

    let lastError = '';
    for (const context of contexts) {
      try {
        FTDBManager.resetInstanceInternal();
        const dbManager = FTDBManager.getInstance(context);
        await dbManager.init();
        DBAssert.validContext = context;
        return context;
      } catch (error) {
        lastError = String(error);
        FTDBManager.resetInstanceInternal();
      }
    }

    throw new Error(`No valid test context for FTDBManager: ${lastError}`);
  }

  static async getManager(): Promise<FTDBManager> {
    const context = await DBAssert.getAppContext();
    const dbManager = FTDBManager.getInstance(context);
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

  static async queryRawSyncData(typeValue: string, limit: number = 100): Promise<SyncData[]> {
    const dbManager = await DBAssert.getManager();

    class RawTypeQueryCallback implements DataBaseCallBack {
      public records: SyncData[] = [];
      private readonly rawType: string;
      private readonly maxLimit: number;

      constructor(rawType: string, maxLimit: number) {
        this.rawType = rawType;
        this.maxLimit = maxLimit;
      }

      async run(rdbStore: relationalStore.RdbStore): Promise<void> {
        const predicates = new relationalStore.RdbPredicates(FTSQL.FT_SYNC_DATA_FLAT_TABLE_NAME);
        predicates.equalTo(FTSQL.RECORD_COLUMN_DATA_TYPE, this.rawType);
        predicates.orderByAsc(FTSQL.RECORD_COLUMN_TM);
        if (this.maxLimit > 0) {
          predicates.limitAs(this.maxLimit);
        }

        const resultSet = await rdbStore.query(predicates);
        try {
          while (resultSet.goToNextRow()) {
            const id = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_ID));
            const uuid = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA_UUID));
            const data = resultSet.getString(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_DATA));
            const timestamp = resultSet.getLong(resultSet.getColumnIndex(FTSQL.RECORD_COLUMN_TM));
            if (uuid && data) {
              const syncData = new SyncData(DataType.RUM_APP);
              syncData.setId(id);
              syncData.setUuid(uuid);
              syncData.setDataString(data);
              syncData.setTime(timestamp);
              syncData.setCustomDataTypeString(this.rawType);
              this.records.push(syncData);
            }
          }
        } finally {
          resultSet.close();
        }
      }
    }

    const callback = new RawTypeQueryCallback(typeValue, limit);
    await dbManager.executeWithDB(false, callback);
    return callback.records;
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

  static async waitForRawSyncRecordContaining(typeValue: string, fragments: string[], timeoutMs: number = 5000): Promise<SyncData | null> {
    let matched: SyncData | null = null;
    const found = await WaitUtils.waitUntil(async () => {
      const records = await DBAssert.queryRawSyncData(typeValue, 100);
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

  static async waitForNoSyncRecordContaining(type: DataType, fragments: string[], timeoutMs: number = 5000): Promise<boolean> {
    return await WaitUtils.waitUntil(async () => {
      const records = await DBAssert.querySyncData([type], 100);
      for (const record of records) {
        if (DBAssert.containsAll(record.getDataString(), fragments)) {
          return false;
        }
      }
      return true;
    }, timeoutMs);
  }

  static async waitForNoSyncRecordWithUuid(type: DataType, uuid: string, timeoutMs: number = 5000): Promise<boolean> {
    if (uuid.length === 0) {
      return false;
    }

    return await WaitUtils.waitUntil(async () => {
      const records = await DBAssert.querySyncData([type], 100);
      for (const record of records) {
        if (record.getUuid() === uuid) {
          return false;
        }
      }
      return true;
    }, timeoutMs);
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
