import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { FTDBManager } from '../../main/ets/components/db/FTDBManager';
import { DBCacheDiscard, DataType, LogCacheDiscard, RUMCacheDiscard } from '../../main/ets/components/enum/Enums';
import { Constants } from '../../main/ets/components/Constants';
import { ConfigRecord } from '../../main/ets/components/SyncTaskManager';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';

class TestConfigRecord implements ConfigRecord {
  private readonly config: FTSDKConfig;

  constructor(config: FTSDKConfig) {
    this.config = config;
  }

  isLimitWithDbSize(): boolean {
    return this.config.isLimitWithDbSize();
  }

  getDbCacheLimit(): number {
    return this.config.getDbCacheLimit();
  }

  getLogCacheLimitCount(): number {
    return this.config.getLogCacheLimitCount();
  }

  getRumCacheLimitCount(): number {
    return this.config.getRumCacheLimitCount();
  }

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }

  getRumCacheDiscard(): string {
    return this.config.getRumCacheDiscard();
  }
}

function createContext(): Context {
  return new Object() as Context;
}

class FakeCachePolicyDbManager {
  currentDbSize: number = 0;
  totalCount: number = 0;
  deleteCount: number = 0;
  lastDeleteLimit: number = 0;
  lastDeleteTypes: string = '';

  async getCurrentDatabaseSize(): Promise<number> {
    return this.currentDbSize;
  }

  async deleteOldestData(types: DataType | DataType[], limit: number): Promise<void> {
    this.deleteCount++;
    this.lastDeleteLimit = limit;
    this.lastDeleteTypes = Array.isArray(types) ? types.map(type => type.toString()).join(',') : types.toString();
  }

  async queryTotalCount(_types: DataType[]): Promise<number> {
    return this.totalCount;
  }
}

class FakeCachePolicyRuntime {
  dbManager: FakeCachePolicyDbManager = new FakeCachePolicyDbManager();

  getDbManager(_context: Context): Object {
    return this.dbManager;
  }
}

function resetCachePolicyState(): void {
  const cachePolicy = FTDBCachePolicy.getInstance();
  cachePolicy.resetCounts();
  cachePolicy.resetTestConfig();
  cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)));
}

export default function cachePolicyUnitTest() {
  describe('CachePolicyUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
      FTDBCachePolicy.resetRuntimeForTest();
      resetCachePolicyState();
    });

    afterEach(() => {
      resetCachePolicyState();
      FTDBCachePolicy.resetRuntimeForTest();
      FTDBManager.resetInstanceForTest();
      TestReset.resetP0State();
    });

    it('cachePolicyShouldTrackCountAndDbSizeLimits', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(10, 5);

      cachePolicy.optLogCount(10);
      cachePolicy.optRumCount(5);
      expect(cachePolicy.isReachLogLimit()).assertTrue();
      expect(cachePolicy.isReachRumLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertTrue();

      cachePolicy.setTestDbSizeLimit(1024);
      cachePolicy.setCurrentDbSize(1024);
      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertTrue();
    });

    it('cachePolicyShouldMapDiscardStrategiesFromSdkConfig', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(Constants.DB_OLD_CACHE_REMOVE_COUNT)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');

      cachePolicy.initSDKParams(new TestConfigRecord(config));

      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_WEBVIEW)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
    });

    it('cachePolicyShouldResetCountsAndIgnoreCountUpdatesWhenDbSizeLimitEnabled', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(10, 10);
      cachePolicy.optLogCount(7);
      cachePolicy.optRumCount(8);

      cachePolicy.resetCounts();
      expect(cachePolicy.getLogCount()).assertEqual(0);
      expect(cachePolicy.getRumCount()).assertEqual(0);

      cachePolicy.setTestDbSizeLimit(1024);
      cachePolicy.optLogCount(10);
      cachePolicy.optRumCount(10);
      expect(cachePolicy.getLogCount()).assertEqual(0);
      expect(cachePolicy.getRumCount()).assertEqual(0);
    });

    it('cachePolicyAsyncCountPolicyShouldDeleteOldestOrDiscard', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 3;
      FTDBCachePolicy.setRuntimeForTest(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest')));
      cachePolicy.setTestLimits(5, 4);
      cachePolicy.optLogCount(4);
      cachePolicy.optRumCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(2);
      expect(await cachePolicy.optRUMCachePolicy(context, 7)).assertEqual(1);
      expect(runtime.dbManager.deleteCount).assertEqual(2);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(`${DataType.RUM_APP.toString()},${DataType.RUM_WEBVIEW.toString()}`);

      cachePolicy.resetCounts();
      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard')
        .setRumCacheDiscard('discard')));
      cachePolicy.setTestLimits(4, 4);
      cachePolicy.optLogCount(4);
      cachePolicy.optRumCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(-3);
      expect(await cachePolicy.optRUMCachePolicy(context, 3)).assertEqual(-1);
    });

    it('cachePolicyAsyncDbSizePolicyShouldDeleteOldestOrDiscard', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 11;
      FTDBCachePolicy.setRuntimeForTest(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      const oldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(4096)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');
      cachePolicy.initSDKParams(new TestConfigRecord(oldestConfig));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(5);
      expect(runtime.dbManager.lastDeleteLimit).assertEqual(Constants.DB_OLD_CACHE_REMOVE_COUNT);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(DataType.LOG.toString());

      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(4096)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD);
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(-5);
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(-1);
    });
  });
}
