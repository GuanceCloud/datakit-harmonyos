/**
 * Database creation, data insertion, data deletion test cases
 * Adapted from Android SDK: com.ft.sdk.tests.FTDBManagerTest
 *
 * Purpose: Verify database operations work correctly
 *
 * Adaptation Notes:
 * - Android: Tests access FTDBManager.get() with Context
 * - HarmonyOS: Tests FTDBCachePolicy (no Context needed in unit test)
 * - Database operations require Context and are tested in integration tests
 *
 * @author FT SDK Team
 */
 
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTDBCachePolicy } from '../../../main/ets/components/db/FTDBCachePolicy';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';

// Test constants (aligned with Android FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const REPEAT_TIME = 100;

export default function ftDBManagerTest() {
  describe('FTDBManagerTest', () => {
    beforeAll(() => {
      console.info('FTDBManagerTest', 'FTDBManagerTest beforeAll called');
    });

    beforeEach(() => {
      console.info('FTDBManagerTest', 'FTDBManagerTest beforeEach called');
      // Reset FTDBCachePolicy state before each test to avoid interference
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    afterEach(() => {
      console.info('FTDBManagerTest', 'FTDBManagerTest afterEach called');
      // Clean up after each test
      FTDBCachePolicy.getInstance().resetCounts();
      FTDBCachePolicy.getInstance().resetTestConfig();
    });

    afterAll(() => {
      console.info('FTDBManagerTest', 'FTDBManagerTest afterAll called');
    });

    /**
     * Test database creation
     * Adapted from Android: createDatabase()
     * Android: DatabaseHelper.getInstance(context, testDBName, dbVersion)
     * HarmonyOS: Database operations require Context, tested in integration tests
     * Here we verify FTDBCachePolicy singleton initialization
     */
    it('createDatabase', 0, () => {
      // Verify FTDBCachePolicy singleton exists
      const cachePolicy = FTDBCachePolicy.getInstance();
      expect(cachePolicy !== null).assertTrue();

      console.info('FTDBManagerTest', 'createDatabase passed - singleton initialized');
    });

    /**
     * Test inserting a piece of data into the database
     * Adapted from Android: insertDataTest()
     * Android: insertData() + queryDataByDescLimit(0) + assertEquals(1, size)
     * HarmonyOS: Data insertion requires Context, tested in integration tests
     * Here we verify count tracking works correctly
     */
    it('insertDataTest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Simulate data insertion by updating log count
      // In real scenario, FTDBManager.insertFtOperation() would be called
      cachePolicy.optLogCount(1);

      // Verify count increased
      expect(cachePolicy.getLogCount()).assertEqual(1);

      console.info('FTDBManagerTest', 'insertDataTest passed');
    });

    /**
     * Test inserting multiple pieces of data into the database
     * Adapted from Android: insertMultiDataTest()
     * Android: Insert REPEAT_TIME pieces + queryDataByDescLimit(0) + assertEquals(REPEAT_TIME, size)
     * HarmonyOS: Count-based test without actual database operations
     */
    it('insertMultiDataTest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set log limit to allow multiple inserts
      cachePolicy.setTestLimits(REPEAT_TIME + 10, REPEAT_TIME + 10);

      // Simulate inserting multiple pieces of data
      for (let i = 0; i < REPEAT_TIME; i++) {
        cachePolicy.optLogCount(1);
      }

      // Verify count matches inserted count
      expect(cachePolicy.getLogCount()).assertEqual(REPEAT_TIME);

      console.info('FTDBManagerTest', `insertMultiDataTest passed - inserted ${REPEAT_TIME} items`);
    });

    /**
     * Test deleting data by data ID
     * Adapted from Android: deleteDataByIdsTest()
     * Android: Insert 2 items + query + delete(ids) + query + assertEquals(0, size)
     * HarmonyOS: Count-based test without actual database operations
     */
    it('deleteDataByIdsTest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Simulate inserting 2 items
      cachePolicy.optLogCount(2);
      expect(cachePolicy.getLogCount()).assertEqual(2);

      // Simulate deleting 2 items (count goes down)
      cachePolicy.optLogCount(-2);

      // Verify count is 0
      expect(cachePolicy.getLogCount()).assertEqual(0);

      console.info('FTDBManagerTest', 'deleteDataByIdsTest passed');
    });

    /**
     * Test database limit check with LOG and RUM cache policy
     * Adapted from Android: enableDbLimitCheckLogAndRUM()
     * Android: Tests DISCARD and DISCARD_OLDEST strategies
     * HarmonyOS: Tests FTDBCachePolicy logic without Context
     *
     * Android test flow:
     * 1. Install SDK with DB size limit + DISCARD strategy
     * 2. Set current DB size to limit
     * 3. Verify isReachDbLimit() returns true
     * 4. Verify optRUMCachePolicy(10) returns -1 (DISCARD)
     * 5. Verify optLogCachePolicy(10) returns -10 (DISCARD)
     * 6. Reinstall with DISCARD_OLDEST strategy
     * 7. Verify optRUMCachePolicy(10) returns 1 (DELETE_OLDEST)
     * 8. Verify optLogCachePolicy(10) returns 10 (DELETE_OLDEST)
     */
    it('enableDbLimitCheckLogAndRUM', 0, async () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Test DISCARD strategy
      cachePolicy.setTestDbSizeLimit(1024*1024*1024);
      cachePolicy.setCurrentDbSize(1024*1024*1024);

      expect(cachePolicy.isReachDbLimit()).assertTrue();

      // Note: optRUMCachePolicy and optLogCachePolicy require Context in HarmonyOS
      // We verify the limit detection logic works
      const isDbLimitEnabled = cachePolicy.isEnableLimitWithDbSize();
      expect(isDbLimitEnabled).assertTrue();

      console.info('FTDBManagerTest', 'enableDbLimitCheckLogAndRUM passed - DISCARD strategy');
    });

    /**
     * Test database size check
     * Adapted from Android: dbSizeCheckTest()
     * Android: Insert 1KB data + get DB size + insert 1KB data + verify size increased
     * HarmonyOS: Tests size tracking without actual database
     */
    it('dbSizeCheckTest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Enable DB size limit
      cachePolicy.setTestDbSizeLimit(1024 * 1024); // 1MB

      // Simulate database size increase
      const initialSize = 100 * 1024; // 100KB
      cachePolicy.setCurrentDbSize(initialSize);
      expect(cachePolicy.getCurrentDbSize()).assertEqual(initialSize);

      // Simulate adding more data (50KB)
      const sizeIncrease = 50 * 1024;
      cachePolicy.optDbSize(sizeIncrease);
      const expectedSize = initialSize + sizeIncrease;
      expect(cachePolicy.getCurrentDbSize()).assertEqual(expectedSize);

      console.info('FTDBManagerTest', `dbSizeCheckTest passed - size increased to ${expectedSize} bytes`);
    });

    /**
     * Test database limit with DISCARD strategy
     * Adapted from Android: checkDbLimitDiscard()
     * Android: Set DB limit to 10 + insert data + verify data NOT inserted
     * HarmonyOS: Tests shouldDiscardData() logic
     */
    it('checkDbLimitDiscard', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set very small DB limit (10 bytes)
      cachePolicy.setTestDbSizeLimit(10);

      // Set current size to exceed limit
      cachePolicy.setCurrentDbSize(20);

      // Verify limit is reached
      expect(cachePolicy.isReachDbLimit()).assertTrue();

      // Verify data should be discarded with default DISCARD strategy
      const shouldDiscardLog = cachePolicy.shouldDiscardData(DataType.LOG);
      expect(shouldDiscardLog).assertTrue();

      const shouldDiscardRUM = cachePolicy.shouldDiscardData(DataType.RUM_APP);
      expect(shouldDiscardRUM).assertTrue();

      console.info('FTDBManagerTest', 'checkDbLimitDiscard passed');
    });

    /**
     * Test database limit with DISCARD_OLDEST strategy
     * Adapted from Android: checkDbLimitDiscardOldest()
     * Android: Set DB limit + DISCARD_OLDEST + insert data + verify old data deleted
     * HarmonyOS: Tests that limit detection works
     *
     * Note: Actual deleteOldestData() requires Context
     */
    it('checkDbLimitDiscardOldest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set DB size limit (testing requires Context for actual delete)
      cachePolicy.setTestDbSizeLimit(10);

      // Set current size to exceed limit
      cachePolicy.setCurrentDbSize(20);

      // Verify limit is reached
      expect(cachePolicy.isReachDbLimit()).assertTrue();

      // Note: With DISCARD_OLDEST strategy, shouldDiscardData returns false
      // because old data will be deleted instead of discarding new data
      // This behavior is tested in integration tests with Context

      console.info('FTDBManagerTest', 'checkDbLimitDiscardOldest passed - limit detected');
    });

    /**
     * Test log count limit
     * Additional test for HarmonyOS implementation
     */
    it('logCountLimit', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set log limit to 10
      const logLimit = 10;
      cachePolicy.setTestLimits(logLimit, 100);

      // Add 10 items
      cachePolicy.optLogCount(10);
      expect(cachePolicy.getLogCount()).assertEqual(10);

      // Verify limit NOT reached (count equals limit)
      expect(cachePolicy.isReachLogLimit()).assertTrue();

      console.info('FTDBManagerTest', 'logCountLimit passed');
    });

    /**
     * Test RUM count limit
     * Additional test for HarmonyOS implementation
     */
    it('rumCountLimit', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set RUM limit to 50
      const rumLimit = 50;
      cachePolicy.setTestLimits(100, rumLimit);

      // Add 50 items
      cachePolicy.optRumCount(50);
      expect(cachePolicy.getRumCount()).assertEqual(50);

      // Verify limit reached
      expect(cachePolicy.isReachRumLimit()).assertTrue();

      console.info('FTDBManagerTest', 'rumCountLimit passed');
    });

    /**
     * Test count decrement
     * Additional test for HarmonyOS implementation
     */
    it('countDecrement', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set limits
      cachePolicy.setTestLimits(100, 100);

      // Add items
      cachePolicy.optLogCount(10);
      expect(cachePolicy.getLogCount()).assertEqual(10);

      // Remove items (simulate delete)
      cachePolicy.optLogCount(-5);
      expect(cachePolicy.getLogCount()).assertEqual(5);

      // Verify count doesn't go below 0
      cachePolicy.optLogCount(-100);
      expect(cachePolicy.getLogCount()).assertEqual(0);

      console.info('FTDBManagerTest', 'countDecrement passed');
    });

    /**
     * Test reset functionality
     * Additional test for HarmonyOS implementation
     */
    it('resetTest', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Set limits and add counts
      cachePolicy.setTestLimits(50, 100);
      cachePolicy.optLogCount(25);
      cachePolicy.optRumCount(50);
      cachePolicy.setCurrentDbSize(1024);

      // Verify values are set
      expect(cachePolicy.getLogCount()).assertEqual(25);
      expect(cachePolicy.getRumCount()).assertEqual(50);
      expect(cachePolicy.getCurrentDbSize()).assertEqual(1024);

      // Reset counts
      cachePolicy.resetCounts();

      // Verify counts are reset to 0
      expect(cachePolicy.getLogCount()).assertEqual(0);
      expect(cachePolicy.getRumCount()).assertEqual(0);
      expect(cachePolicy.getCurrentDbSize()).assertEqual(0);

      console.info('FTDBManagerTest', 'resetTest passed');
    });

    /**
     * Test database size not increased when DB size limit is enabled
     * Adapted from Android: insertDataAndCheckDBIncrease()
     * Android: Insert 1KB + wait + get size + insert 1KB + wait + verify size increased
     * HarmonyOS: Tests that optDbSize is not called when enableLimitWithDbSize is true
     */
    it('dbSizeNotIncreasedWhenLimitEnabled', 0, () => {
      const cachePolicy = FTDBCachePolicy.getInstance();

      // Enable DB size limit
      cachePolicy.setTestDbSizeLimit(1024 * 1024); // 1MB
      cachePolicy.setCurrentDbSize(100 * 1024); // 100KB

      const initialSize = cachePolicy.getCurrentDbSize();

      // When DB size limit is enabled, optLogCount does NOT update counts
      // (aligned with Android: optLogCount checks enableLimitWithDbSize)
      cachePolicy.optLogCount(10);

      // Count should not be updated when DB size limit is enabled
      expect(cachePolicy.getLogCount()).assertEqual(0);

      // Size should remain unchanged
      expect(cachePolicy.getCurrentDbSize()).assertEqual(initialSize);

      console.info('FTDBManagerTest', 'dbSizeNotIncreasedWhenLimitEnabled passed');
    });
  });
}
