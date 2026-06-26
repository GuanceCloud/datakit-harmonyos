import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { DataType, DBCacheDiscard, LogCacheDiscard, RUMCacheDiscard } from '../../main/ets/components/enum/Enums';
import { Constants } from '../../main/ets/components/Constants';
import { ConfigRecord } from '../../main/ets/components/SyncTaskManager';
import { DbInternalTestAccess } from '../../main/ets/components/internal/testaccess/DbInternalTestAccess';
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

  getDBCacheDiscard(): string {
    return this.config.getDBCacheDiscard();
  }

  getLogCacheDiscard(): string {
    return this.config.getLogCacheDiscard();
  }
}

function createContext(): Context {
  return new Object() as Context;
}

class FakeCachePolicyDbManager {
  currentDbSize: number = 0;
  totalCount: number = 0;
  logTotalCount: number = -1;
  rumTotalCount: number = -1;
  deleteCount: number = 0;
  queryTotalCountCallCount: number = 0;
  currentDatabaseSizeCallCount: number = 0;
  lastDeleteLimit: number = 0;
  lastDeleteTypes: string = '';
  lastQueryTypes: string = '';

  async getCurrentDatabaseSize(): Promise<number> {
    this.currentDatabaseSizeCallCount++;
    return this.currentDbSize;
  }

  async deleteOldestData(types: DataType | DataType[], limit: number): Promise<void> {
    this.deleteCount++;
    this.lastDeleteLimit = limit;
    this.lastDeleteTypes = Array.isArray(types) ? types.map(type => type.toString()).join(',') : types.toString();
  }

  async queryTotalCount(types: DataType[]): Promise<number> {
    this.queryTotalCountCallCount++;
    this.lastQueryTypes = types.map(type => type.toString()).join(',');
    let hasLog = false;
    let hasRum = false;
    for (let i = 0; i < types.length; i++) {
      if (types[i] === DataType.LOG) {
        hasLog = true;
      } else if (types[i] === DataType.RUM_APP || types[i] === DataType.RUM_WEBVIEW) {
        hasRum = true;
      }
    }
    if (hasLog && !hasRum) {
      return this.logTotalCount >= 0 ? this.logTotalCount : this.totalCount;
    }
    if (hasRum && !hasLog) {
      return this.rumTotalCount >= 0 ? this.rumTotalCount : this.totalCount;
    }
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
      DbInternalTestAccess.resetCachePolicyRuntime();
      resetCachePolicyState();
    });

    afterEach(() => {
      resetCachePolicyState();
      DbInternalTestAccess.resetCachePolicyRuntime();
      DbInternalTestAccess.resetDbManagerInstance();
      TestReset.resetP0State();
    });

    it('cachePolicyShouldTrackLimits', 0, () => {
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

    it('cachePolicyShouldMapDiscardStrategy', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(Constants.DB_OLD_CACHE_REMOVE_COUNT)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest');

      cachePolicy.initSDKParams(new TestConfigRecord(config));

      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD);

      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_WEBVIEW)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
    });

    it('dbCachePolicyShouldKeepLegacyDiscardSeparate', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(Constants.DB_OLD_CACHE_REMOVE_COUNT)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST);

      cachePolicy.initSDKParams(new TestConfigRecord(config));

      expect(config.isLimitWithDbSize()).assertTrue();
      expect(config.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.isEnableLimitWithDbSize()).assertTrue();
      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD_OLDEST);
    });

    it('dbSizePolicyShouldApplyOldestDiscard', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 3;
      DbInternalTestAccess.setCachePolicyRuntime(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(Constants.MINI_CACHE_LIMIT_SIZE)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST);
      cachePolicy.initSDKParams(new TestConfigRecord(config));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(5);
      expect(runtime.dbManager.deleteCount).assertEqual(1);
      expect(runtime.dbManager.lastDeleteLimit).assertEqual(Constants.DB_OLD_CACHE_REMOVE_COUNT);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(DataType.LOG.toString());
    });

    it('cachePolicyShouldIgnoreCountUpdates', 0, () => {
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

      cachePolicy.setCurrentDbSize(1);
      expect(cachePolicy.isReachLogLimit()).assertFalse();
      expect(cachePolicy.isReachRumLimit()).assertFalse();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertFalse();
    });

    it('countPolicyShouldRecoverExistingDbCountsBeforeFirstWrite', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.logTotalCount = 5;
      runtime.dbManager.rumTotalCount = 4;
      DbInternalTestAccess.setCachePolicyRuntime(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard')));
      cachePolicy.setTestLimits(5, 4);

      expect(await cachePolicy.optLogCachePolicy(context, 1)).assertEqual(-1);
      expect(cachePolicy.getLogCount()).assertEqual(5);
      expect(cachePolicy.getRumCount()).assertEqual(4);
      expect(runtime.dbManager.queryTotalCountCallCount).assertEqual(2);

      expect(await cachePolicy.optRUMCachePolicy(context, 1)).assertEqual(-1);
      expect(runtime.dbManager.queryTotalCountCallCount).assertEqual(2);
    });

    it('dbSizePolicyShouldSkipCountInitialization', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.logTotalCount = 100;
      runtime.dbManager.rumTotalCount = 100;
      DbInternalTestAccess.setCachePolicyRuntime(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(Constants.MINI_CACHE_LIMIT_SIZE)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD)));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(-5);
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(-1);
      expect(runtime.dbManager.queryTotalCountCallCount).assertEqual(0);
      expect(runtime.dbManager.currentDatabaseSizeCallCount).assertEqual(2);
    });

    it('countPolicyShouldDeleteOrDiscard', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 4;
      DbInternalTestAccess.setCachePolicyRuntime(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard_oldest')));
      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD_OLDEST);
      cachePolicy.setTestLimits(5, 4);
      cachePolicy.optLogCount(4);
      cachePolicy.optRumCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(2);
      expect(await cachePolicy.optRUMCachePolicy(context, 7)).assertEqual(1);
      expect(runtime.dbManager.deleteCount).assertEqual(2);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(`${DataType.RUM_APP.toString()},${DataType.RUM_WEBVIEW.toString()}`);

      cachePolicy.resetCounts();
      cachePolicy.initSDKParams(new TestConfigRecord(FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard')));
      cachePolicy.updateRumCacheDiscardStrategy(RUMCacheDiscard.DISCARD);
      cachePolicy.setTestLimits(4, 4);
      cachePolicy.optLogCount(4);
      cachePolicy.optRumCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(-3);
      expect(await cachePolicy.optRUMCachePolicy(context, 3)).assertEqual(-1);
    });

    it('dbSizePolicyShouldDeleteOrDiscard', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 11;
      DbInternalTestAccess.setCachePolicyRuntime(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      const oldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableLimitWithDbSize(4096)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD_OLDEST);
      cachePolicy.initSDKParams(new TestConfigRecord(oldestConfig));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(5);
      expect(runtime.dbManager.lastDeleteLimit).assertEqual(Constants.DB_OLD_CACHE_REMOVE_COUNT);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(DataType.LOG.toString());

      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(4096)
        .setDbCacheDiscard(DBCacheDiscard.DISCARD);
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();

      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(-5);
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(-1);
    });
  });
}
