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
  queryCount: number = 0;
  lastDeleteLimit: number = 0;
  lastDeleteTypes: string = '';
  lastQueryTypes: string = '';

  async getCurrentDatabaseSize(): Promise<number> {
    return this.currentDbSize;
  }

  async deleteOldestData(types: DataType | DataType[], limit: number): Promise<void> {
    this.deleteCount++;
    this.lastDeleteLimit = limit;
    this.lastDeleteTypes = Array.isArray(types) ? types.map(type => type.toString()).join(',') : types.toString();
  }

  async queryTotalCount(types: DataType[]): Promise<number> {
    this.queryCount++;
    this.lastQueryTypes = types.map(type => type.toString()).join(',');
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

    it('cachePolicyShouldTrackRumCountLimit', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(100, 50);
      cachePolicy.optRumCount(50);

      expect(cachePolicy.getRumCount()).assertEqual(50);
      expect(cachePolicy.isReachRumLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertTrue();
    });

    it('cachePolicyShouldTrackDbSizeLimit', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestDbSizeLimit(1024);
      cachePolicy.setCurrentDbSize(512);
      cachePolicy.optDbSize(512);

      expect(cachePolicy.getCurrentDbSize()).assertEqual(1024);
      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertTrue();
    });

    it('cachePolicyShouldResetCountsAndTestConfig', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(10, 20);
      cachePolicy.optRumCount(5);
      cachePolicy.setTestDbSizeLimit(1024);
      cachePolicy.setCurrentDbSize(100);

      cachePolicy.resetCounts();
      expect(cachePolicy.getRumCount()).assertEqual(0);
      expect(cachePolicy.getCurrentDbSize()).assertEqual(0);

      cachePolicy.resetTestConfig();
      expect(cachePolicy.getLogLimitCount()).assertEqual(0);
      expect(cachePolicy.getRumLimitCount()).assertEqual(0);
      expect(cachePolicy.isEnableLimitWithDbSize()).assertFalse();
    });

    it('cachePolicyShouldTrackLogCountLimitAndClampNegativeDelta', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(2, 0);

      cachePolicy.optLogCount(1);
      expect(cachePolicy.getLogCount()).assertEqual(1);
      expect(cachePolicy.isReachLogLimit()).assertFalse();

      cachePolicy.optLogCount(-5);
      expect(cachePolicy.getLogCount()).assertEqual(0);

      cachePolicy.optLogCount(2);
      expect(cachePolicy.isReachLogLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertTrue();
    });

    it('cachePolicyShouldNotDiscardWhenBelowLimitsOrLimitsDisabled', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      cachePolicy.optLogCount(100);
      cachePolicy.optRumCount(100);
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertFalse();

      cachePolicy.resetCounts();
      cachePolicy.setTestLimits(10, 10);
      cachePolicy.optLogCount(9);
      cachePolicy.optRumCount(9);
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_WEBVIEW)).assertFalse();
    });

    it('cachePolicyShouldMapDiscardOldestStrategiesFromSdkConfig', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const config = FTSDKConfig.builder('http://www.test.url')
        .setDbCacheLimit(Constants.DB_OLD_CACHE_REMOVE_COUNT)
        .setLogCacheLimitCount(10)
        .setRumCacheLimitCount(10)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');

      cachePolicy.initSDKParams(new TestConfigRecord(config));
      cachePolicy.setCurrentDbSize(cachePolicy.getDbLimitSize());

      expect(cachePolicy.isEnableLimitWithDbSize()).assertTrue();
      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_WEBVIEW)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
    });

    it('cachePolicyShouldMapUnknownStrategiesToDiscard', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const config = FTSDKConfig.builder('http://www.test.url')
        .setDbCacheLimit(Constants.DB_OLD_CACHE_REMOVE_COUNT)
        .setDBCacheDiscard('unexpected')
        .setLogCacheDiscard('unexpected')
        .setRumCacheDiscard('unexpected');

      cachePolicy.initSDKParams(new TestConfigRecord(config));

      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_WEBVIEW)).assertEqual(RUMCacheDiscard.DISCARD);
    });

    it('when limit hits boundary then resetCounts should restore both counts to zero', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestLimits(2, 3);

      cachePolicy.optLogCount(2);
      cachePolicy.optRumCount(3);

      expect(cachePolicy.getLogCount()).assertEqual(2);
      expect(cachePolicy.getRumCount()).assertEqual(3);

      cachePolicy.resetCounts();
      expect(cachePolicy.getLogCount()).assertEqual(0);
      expect(cachePolicy.getRumCount()).assertEqual(0);
      expect(cachePolicy.getCurrentDbSize()).assertEqual(0);
    });

    it('when discard strategy is DISCARD vs DISCARD_OLDEST should branch predictably on boundary and next-operation', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(1024)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD)
        .setLogCacheDiscard('discard')
        .setRumCacheDiscard('discard');
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      cachePolicy.setCurrentDbSize(cachePolicy.getDbLimitSize());

      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertTrue();

      const oldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(1024)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');
      cachePolicy.initSDKParams(new TestConfigRecord(oldestConfig));
      cachePolicy.setCurrentDbSize(cachePolicy.getDbLimitSize());

      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
      expect(cachePolicy.shouldDiscardData(DataType.RUM_APP)).assertFalse();
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_APP)).assertEqual(RUMCacheDiscard.DISCARD_OLDEST);
    });

    it('when db-size path is crossed and then reset should not leak strategy state', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      const oldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(2048)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD_OLDEST)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');
      cachePolicy.initSDKParams(new TestConfigRecord(oldestConfig));
      cachePolicy.setCurrentDbSize(cachePolicy.getDbLimitSize());

      expect(cachePolicy.isReachDbLimit()).assertTrue();
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();

      cachePolicy.resetCounts();
      expect(cachePolicy.getCurrentDbSize()).assertEqual(0);
      expect(cachePolicy.getDiscardStrategy(DataType.LOG)).assertEqual(LogCacheDiscard.DISCARD_OLDEST);

      cachePolicy.setCurrentDbSize(cachePolicy.getDbLimitSize());
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();
    });

    it('cachePolicyShouldIgnoreCountUpdatesWhenDbSizeLimitEnabled', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.setTestDbSizeLimit(1024);

      cachePolicy.optLogCount(10);
      cachePolicy.optRumCount(10);

      expect(cachePolicy.getLogCount()).assertEqual(0);
      expect(cachePolicy.getRumCount()).assertEqual(0);
    });

    it('cachePolicyShouldExposeRuntimeIndependentGettersAndDefaultBranches', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      cachePolicy.updateLogCacheLimitCount(77);

      expect(cachePolicy.getLogLimitCount()).assertEqual(77);
      expect(cachePolicy.getDBCacheDiscard()).assertEqual(DBCacheDiscard.DISCARD);
      expect(cachePolicy.getLogLock() !== null).assertTrue();
      expect(cachePolicy.getRumLock() !== null).assertTrue();
      expect(cachePolicy.getDiscardStrategy(DataType.RUM_WEBVIEW)).assertEqual(RUMCacheDiscard.DISCARD);
      expect(cachePolicy.getDiscardStrategy('unknown' as DataType)).assertEqual(DBCacheDiscard.DISCARD);

      cachePolicy.resetTestConfig();
      expect(cachePolicy.isReachLogLimit()).assertFalse();
      expect(cachePolicy.isReachRumLimit()).assertFalse();
    });

    it('cachePolicyAsyncCountBranchesShouldDeleteOrDiscardForLogAndRum', 0, async () => {
      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 3;
      FTDBCachePolicy.setRuntimeForTest(runtime);
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      const discardOldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');
      cachePolicy.initSDKParams(new TestConfigRecord(discardOldestConfig));
      cachePolicy.setTestLimits(5, 4);
      cachePolicy.optLogCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(2);
      expect(runtime.dbManager.deleteCount).assertEqual(1);
      expect(runtime.dbManager.lastDeleteLimit).assertEqual(2);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(DataType.LOG.toString());
      expect(cachePolicy.getLogCount()).assertEqual(3);

      runtime.dbManager.totalCount = 2;
      cachePolicy.optRumCount(4);
      expect(await cachePolicy.optRUMCachePolicy(context, 7)).assertEqual(1);
      expect(runtime.dbManager.deleteCount).assertEqual(2);
      expect(runtime.dbManager.lastDeleteLimit).assertEqual(7);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(`${DataType.RUM_APP.toString()},${DataType.RUM_WEBVIEW.toString()}`);
      expect(cachePolicy.getRumCount()).assertEqual(2);

      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard')
        .setRumCacheDiscard('discard');
      cachePolicy.resetCounts();
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      cachePolicy.setTestLimits(4, 4);
      cachePolicy.optLogCount(4);
      cachePolicy.optRumCount(4);

      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(-3);
      expect(await cachePolicy.optRUMCachePolicy(context, 3)).assertEqual(-1);
    });

    it('cachePolicyAsyncDbSizeBranchesShouldUseFakeDbManager', 0, async () => {
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
      expect(cachePolicy.getLogCount()).assertEqual(11);

      runtime.dbManager.totalCount = 9;
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(1);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(`${DataType.RUM_APP.toString()},${DataType.RUM_WEBVIEW.toString()}`);
      expect(cachePolicy.getRumCount()).assertEqual(9);

      runtime.dbManager.currentDbSize = 1;
      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(0);
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(0);

      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDbCacheLimit(4096)
        .setDBCacheDiscard(DBCacheDiscard.DISCARD);
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      runtime.dbManager.currentDbSize = cachePolicy.getDbLimitSize();
      expect(await cachePolicy.optLogCachePolicy(context, 5)).assertEqual(-5);
      expect(await cachePolicy.optRUMCachePolicy(context, 5)).assertEqual(-1);
    });

    it('cachePolicyTailBranchesShouldCoverRuntimeLocksBelowLimitAndUnknownDataType', 0, async () => {
      const cachePolicy = FTDBCachePolicy.getInstance();
      const context = createContext();

      expect(cachePolicy.isReachDbLimit()).assertFalse();
      expect(cachePolicy.getRumLock() !== null).assertTrue();
      expect(cachePolicy.getLogLock() !== null).assertTrue();
      expect(cachePolicy.shouldDiscardData('unknown' as DataType)).assertFalse();
      expect(cachePolicy.getDiscardStrategy('unknown' as DataType)).assertEqual(DBCacheDiscard.DISCARD);

      cachePolicy.setTestDbSizeLimit(1024);
      cachePolicy.setCurrentDbSize(1);
      expect(cachePolicy.shouldDiscardData(DataType.LOG)).assertFalse();

      cachePolicy.resetCounts();
      cachePolicy.resetTestConfig();
      const discardConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard')
        .setRumCacheDiscard('discard');
      cachePolicy.initSDKParams(new TestConfigRecord(discardConfig));
      cachePolicy.setTestLimits(5, 5);
      cachePolicy.optLogCount(1);
      cachePolicy.optRumCount(1);
      expect(await cachePolicy.optLogCachePolicy(context, 2)).assertEqual(0);
      expect(await cachePolicy.optRUMCachePolicy(context, 2)).assertEqual(0);

      cachePolicy.optLogCount(3);
      expect(await cachePolicy.optLogCachePolicy(context, 3)).assertEqual(-2);

      const runtime = new FakeCachePolicyRuntime();
      runtime.dbManager.totalCount = 1;
      FTDBCachePolicy.setRuntimeForTest(runtime);
      const oldestConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLogCacheDiscard('discard_oldest')
        .setRumCacheDiscard('discard_oldest');
      cachePolicy.resetCounts();
      cachePolicy.initSDKParams(new TestConfigRecord(oldestConfig));
      cachePolicy.setTestLimits(2, 2);
      cachePolicy.optLogCount(2);
      expect(await cachePolicy.optLogCachePolicy(context, 4)).assertEqual(4);
      expect(runtime.dbManager.lastDeleteTypes).assertEqual(DataType.LOG.toString());

      expect(FTDBCachePolicy.getDbManagerForTest(context) === runtime.dbManager).assertTrue();
      FTDBCachePolicy.resetRuntimeForTest();
      expect(FTDBCachePolicy.getDbManagerForTest(context) !== null).assertTrue();
      FTDBManager.resetInstanceForTest();
    });
  });
}
