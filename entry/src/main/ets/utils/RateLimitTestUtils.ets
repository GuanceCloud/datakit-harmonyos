import { FTDBCachePolicy } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBCachePolicy';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { SamplingUtils } from '@guancecloud/ft_sdk/src/main/ets/components/utils/SamplingUtils';
import { DemoLogger } from './DemoLogger';

const TAG = 'RateLimitTestUtils';

export class SamplingRateTestResult {
  public actualRate: number;
  public expectedRate: number;
  public deviation: number;
  public passed: boolean;
  public details: string;

  constructor(actualRate: number, expectedRate: number, deviation: number, passed: boolean, details: string) {
    this.actualRate = actualRate;
    this.expectedRate = expectedRate;
    this.deviation = deviation;
    this.passed = passed;
    this.details = details;
  }
}

export class SessionKeepTestResult {
  public sessionCollectCount: number;
  public sessionErrorCollectCount: number;
  public sessionCollectRate: number;
  public sessionErrorCollectRate: number;
  public details: string;

  constructor(sessionCollectCount: number, sessionErrorCollectCount: number, sessionCollectRate: number, sessionErrorCollectRate: number, details: string) {
    this.sessionCollectCount = sessionCollectCount;
    this.sessionErrorCollectCount = sessionErrorCollectCount;
    this.sessionCollectRate = sessionCollectRate;
    this.sessionErrorCollectRate = sessionErrorCollectRate;
    this.details = details;
  }
}

export class CachePolicyTestResult {
  public initialCount: number;
  public limitReached: boolean;
  public shouldDiscard: boolean;
  public details: string;

  constructor(initialCount: number, limitReached: boolean, shouldDiscard: boolean, details: string) {
    this.initialCount = initialCount;
    this.limitReached = limitReached;
    this.shouldDiscard = shouldDiscard;
    this.details = details;
  }
}

export class DatabaseSizeTestResult {
  public initialSize: number;
  public limitReached: boolean;
  public shouldDiscard: boolean;
  public details: string;

  constructor(initialSize: number, limitReached: boolean, shouldDiscard: boolean, details: string) {
    this.initialSize = initialSize;
    this.limitReached = limitReached;
    this.shouldDiscard = shouldDiscard;
    this.details = details;
  }
}

export class RateLimitTestUtils {
  private static instance: RateLimitTestUtils | null = null;

  private constructor() {}

  public static getInstance(): RateLimitTestUtils {
    if (RateLimitTestUtils.instance === null) {
      RateLimitTestUtils.instance = new RateLimitTestUtils();
    }
    return RateLimitTestUtils.instance;
  }

  public testSamplingRateAccuracy(sampleRate: number, testCount: number = 1000): SamplingRateTestResult {
    DemoLogger.i(TAG, ` Starting sampling rate test: target=${sampleRate}, iterations=${testCount}`);

    let passedCount = 0;
    const startTime = Date.now();
    for (let i = 0; i < testCount; i++) {
      if (SamplingUtils.enableTraceSamplingRate(sampleRate)) {
        passedCount++;
      }
    }

    const actualRate = passedCount / testCount;
    const deviation = Math.abs(actualRate - sampleRate);
    const passed = deviation <= 0.1;
    const details = `Test completed in ${Date.now() - startTime}ms. Expected: ${sampleRate.toFixed(3)}, Actual: ${actualRate.toFixed(3)}, Deviation: ${deviation.toFixed(3)}, Passed: ${passed}`;

    DemoLogger.i(TAG, ` Sampling rate test result: ${details}`);
    return new SamplingRateTestResult(actualRate, sampleRate, deviation, passed, details);
  }

  public testSessionKeep(sampleRate: number, errorSampleRate: number, testCount: number = 100): SessionKeepTestResult {
    DemoLogger.i(TAG, ` Starting session keep test: normal=${sampleRate}, error=${errorSampleRate}, iterations=${testCount}`);

    let sessionCollectCount = 0;
    let sessionErrorCollectCount = 0;
    for (let i = 0; i < testCount; i++) {
      const result = SamplingUtils.checkSessionKeep(`test_session_${i}`, sampleRate, errorSampleRate);
      if (result.sessionCollect) {
        sessionCollectCount++;
      }
      if (result.sessionErrorCollect) {
        sessionErrorCollectCount++;
      }
    }

    const sessionCollectRate = sessionCollectCount / testCount;
    const sessionErrorCollectRate = sessionErrorCollectCount / testCount;
    const details = `Session keep test completed. Session collect: ${sessionCollectCount}/${testCount} (${sessionCollectRate.toFixed(3)}), Error collect: ${sessionErrorCollectCount}/${testCount} (${sessionErrorCollectRate.toFixed(3)})`;

    DemoLogger.i(TAG, ` Session keep test result: ${details}`);
    return new SessionKeepTestResult(sessionCollectCount, sessionErrorCollectCount, sessionCollectRate, sessionErrorCollectRate, details);
  }

  public testCachePolicyLimits(dataType: DataType, limitCount: number): CachePolicyTestResult {
    DemoLogger.i(TAG, ` Starting cache policy test: dataType=${dataType}, limitCount=${limitCount}`);

    const cachePolicy = FTDBCachePolicy.getInstance();
    const initialCount = dataType === DataType.LOG ? cachePolicy.getLogCount() : cachePolicy.getRumCount();

    if (dataType === DataType.LOG) {
      cachePolicy.setTestLimits(limitCount, 0);
    } else {
      cachePolicy.setTestLimits(0, limitCount);
    }

    const addCount = limitCount - initialCount + 10;
    if (dataType === DataType.LOG) {
      cachePolicy.optLogCount(addCount);
    } else {
      cachePolicy.optRumCount(addCount);
    }

    const limitReached = dataType === DataType.LOG ? cachePolicy.isReachLogLimit() : cachePolicy.isReachRumLimit();
    const shouldDiscard = cachePolicy.shouldDiscardData(dataType);
    const details = `Cache policy test completed. Initial count: ${initialCount}, Added: ${addCount}, Limit reached: ${limitReached}, Should discard: ${shouldDiscard}`;

    DemoLogger.i(TAG, ` Cache policy test result: ${details}`);
    cachePolicy.resetTestConfig();
    return new CachePolicyTestResult(initialCount, limitReached, shouldDiscard, details);
  }

  public testDatabaseSizeLimit(limitSize: number): DatabaseSizeTestResult {
    DemoLogger.i(TAG, ` Starting database size test: limitSize=${limitSize} bytes`);

    const cachePolicy = FTDBCachePolicy.getInstance();
    const initialSize = cachePolicy.getCurrentDbSize();
    cachePolicy.setTestDbSizeLimit(limitSize);

    const addSize = limitSize - initialSize + 1024;
    cachePolicy.optDbSize(addSize);

    const limitReached = cachePolicy.isReachDbLimit();
    const shouldDiscard = limitReached;
    const details = `DB cache size test completed. Initial size: ${initialSize} bytes, Added: ${addSize} bytes, Limit reached: ${limitReached}, Should discard: ${shouldDiscard}`;

    DemoLogger.i(TAG, ` DB cache size test result: ${details}`);
    cachePolicy.resetTestConfig();
    return new DatabaseSizeTestResult(initialSize, limitReached, shouldDiscard, details);
  }
}
