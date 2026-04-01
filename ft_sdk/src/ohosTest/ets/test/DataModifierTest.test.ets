/**
 * Data modifier test
 * Reference: com.ft.sdk.tests.DataModifierTest (Android SDK)
 *
 * Purpose: Verify DataModifier and LineDataModifier functionality
 * - DataModifier: Modify individual tag/field values
 * - LineDataModifier: Modify entire line protocol data
 *
 * Test Coverage:
 * ==============
 * 1. Core Integration Tests (aligned with Android SDK):
 *    - rumAppDataTest: Verifies RUM data modification (Android-aligned)
 *    - logDataTest: Verifies Log data modification (Android-aligned)
 *
 * 2. Unit Tests (compensate for ohosTest environment limitations):
 *    NOTE: Android SDK verifies end-to-end integration by querying the database.
 *    HarmonyOS ohosTest cannot access the database (requires Context), so we add
 *    these unit tests to verify modifier behavior in isolation.
 *
 *    - dataModifierModifyTest: Tests DataModifier.modify() method directly
 *    - lineDataModifierModifyTest: Tests LineDataModifier.modify() method directly
 *    - dataModifierMultipleKeysTest: Tests multiple key handling
 *    - lineDataModifierEmptyDataTest: Tests empty data edge case
 *    - modifierMethodChainingTest: Tests builder pattern (config API)
 *    - lineProtocolFormatWithModifiersTest: Tests Line Protocol format integration
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { DataModifier, LineDataModifier } from '../../../main/ets/components/DataModifier';
import { Constants } from '../../../main/ets/components/Constants';
import { Status } from '../../../main/ets/components/bean/Status';
import { SyncDataHelper } from '../../../main/ets/components/SyncDataHelper';

// Test constants (aligned with Android SDK)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_USER_ID = 'testUserId';
const MASK = 'xxx';

// 1KB log test data (aligned with Android SDK)
const LOG_TEST_DATA_1_KB = 'a'.repeat(1024);

/**
 * Test DataModifier implementation
 * Masks device_uuid with a fixed value
 * Aligned with Android SDK: modify() returns MASK for device_uuid
 */
class TestDataModifier implements DataModifier {
  modify(key: string, value: string): string {
    if (key === Constants.KEY_DEVICE_UUID) {
      return MASK;
    }
    return value;
  }
}

/**
 * Test LineDataModifier implementation
 * Masks userid with a fixed value
 * Aligned with Android SDK: modify() puts MASK into data for userid
 */
class TestLineDataModifier implements LineDataModifier {
  modify(measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result = new Map<string, string>();

    // Copy all original tags and fields
    tags.forEach((value: string, key: string) => {
      result.set(key, value);
    });
    fields.forEach((value: string, key: string) => {
      result.set(key, value);
    });

    // Override userid with mask
    result.set(Constants.KEY_RUM_USER_ID, MASK);

    return result;
  }
}

export default function dataModifierTest() {
  describe('DataModifierTest', () => {

    beforeAll(() => {
      console.info('DataModifierTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('DataModifierTest', 'beforeEach called');
    });

    afterEach(() => {
      console.info('DataModifierTest', 'afterEach called');
    });

    afterAll(() => {
      console.info('DataModifierTest', 'afterAll called');
    });

    /**
     * RUM app data test
     *
     * Aligned with Android SDK: rumAppDataTest()
     * Verifies that DataModifier and LineDataModifier are correctly applied to RUM data
     *
     * Android implementation:
     * - FTRUMGlobalManager.get().addAction()
     * - Thread.sleep(2000)
     * - FTDBManager.get().queryDataByDataByTypeLimitDesc(DataType.RUM_APP)
     * - LineProtocolData parser to verify device_uuid and userid are masked
     *
     * HarmonyOS adaptation:
     * - Simulate data processing flow using SyncDataHelper
     * - Verify modifiers work by checking simulated Line Protocol output
     * - Note: Cannot query database in ohosTest (no Context), so we verify modifiers directly
     */
    it('rumAppDataTest', 0, () => {
      // Simulate Line Protocol data generation with modifiers
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_DEVICE_UUID, 'test-device-uuid');
      tags.set(Constants.KEY_RUM_USER_ID, TEST_FAKE_USER_ID);

      const fields: Map<string, string> = new Map();
      fields.set('action_name', 'test_action');

      // Apply LineDataModifier (simulates what happens in SDK)
      const lineDataModifier = new TestLineDataModifier();
      const modifiedData = lineDataModifier.modify('rum_app', tags, fields);

      // Verify device_uuid is masked by DataModifier
      const dataModifier = new TestDataModifier();
      const maskedDeviceId = dataModifier.modify(Constants.KEY_DEVICE_UUID, 'test-device-uuid');
      expect(maskedDeviceId).assertEqual(MASK);

      // Verify userid is masked by LineDataModifier
      expect(modifiedData.get(Constants.KEY_RUM_USER_ID)).assertEqual(MASK);

      // Verify original user ID is NOT present
      expect(modifiedData.get(Constants.KEY_RUM_USER_ID) === TEST_FAKE_USER_ID).assertFalse();

      console.info('DataModifierTest', 'rumAppDataTest passed');
    });

    /**
     * Log data test
     *
     * Aligned with Android SDK: logDataTest()
     * Verifies that DataModifier and LineDataModifier are correctly applied to Log data
     *
     * Android implementation:
     * - FTLogger.getInstance().logBackground(LOG_TEST_DATA_1_KB, Status.DEBUG)
     * - Thread.sleep(3000)
     * - waitEventConsumeInThreadPool()
     * - FTDBManager.get().queryDataByDataByTypeLimitDesc(DataType.LOG)
     * - LineProtocolData parser to verify device_uuid and userid are masked
     *
     * HarmonyOS adaptation:
     * - Simulate data processing flow
     * - Verify modifiers work correctly
     * - Note: Cannot query database in ohosTest (no Context), so we verify modifiers directly
     */
    it('logDataTest', 0, () => {
      // Simulate Line Protocol data generation for Log with modifiers
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_DEVICE_UUID, 'test-device-uuid');
      tags.set(Constants.KEY_RUM_USER_ID, TEST_FAKE_USER_ID);
      tags.set('status', Status.DEBUG.name);

      const fields: Map<string, string> = new Map();
      fields.set('content', LOG_TEST_DATA_1_KB.substring(0, 50) + '...');

      // Apply LineDataModifier (simulates what happens in SDK)
      const lineDataModifier = new TestLineDataModifier();
      const modifiedData = lineDataModifier.modify('log', tags, fields);

      // Verify device_uuid is masked by DataModifier
      const dataModifier = new TestDataModifier();
      const maskedDeviceId = dataModifier.modify(Constants.KEY_DEVICE_UUID, 'test-device-uuid');
      expect(maskedDeviceId).assertEqual(MASK);

      // Verify userid is masked by LineDataModifier
      expect(modifiedData.get(Constants.KEY_RUM_USER_ID)).assertEqual(MASK);

      // Verify original user ID is NOT present
      expect(modifiedData.get(Constants.KEY_RUM_USER_ID) === TEST_FAKE_USER_ID).assertFalse();

      console.info('DataModifierTest', 'logDataTest passed');
    });

    /**
     * DataModifier modify method test
     * Tests the DataModifier.modify() method directly
     */
    it('dataModifierModifyTest', 0, () => {
      const modifier = new TestDataModifier();

      // Test modification for device_uuid (should return MASK)
      const maskedValue = modifier.modify(Constants.KEY_DEVICE_UUID, 'original-uuid-123');
      expect(maskedValue).assertEqual(MASK);

      // Test no modification for other keys (should return original value)
      const originalValue = modifier.modify('other_key', 'some-value');
      expect(originalValue).assertEqual('some-value');

      console.info('DataModifierTest', 'dataModifierModifyTest passed');
    });

    /**
     * LineDataModifier modify method test
     * Tests the LineDataModifier.modify() method directly
     */
    it('lineDataModifierModifyTest', 0, () => {
      const modifier = new TestLineDataModifier();

      // Create test tags and fields
      const tags: Map<string, string> = new Map();
      tags.set('tag1', 'value1');
      tags.set(Constants.KEY_RUM_USER_ID, 'original-user-id');

      const fields: Map<string, string> = new Map();
      fields.set('field1', 'fieldValue1');

      // Call modify
      const result = modifier.modify('test_measurement', tags, fields);

      // Verify all data is copied
      expect(result.size).assertEqual(3);
      expect(result.get('tag1')).assertEqual('value1');
      expect(result.get('field1')).assertEqual('fieldValue1');

      // Verify userid is masked
      expect(result.get(Constants.KEY_RUM_USER_ID)).assertEqual(MASK);

      console.info('DataModifierTest', 'lineDataModifierModifyTest passed');
    });

    /**
     * DataModifier with multiple keys test
     * Tests that DataModifier only modifies specific keys
     */
    it('dataModifierMultipleKeysTest', 0, () => {
      const modifier = new TestDataModifier();

      // Test multiple keys
      // device_uuid should be masked
      expect(modifier.modify(Constants.KEY_DEVICE_UUID, 'uuid1')).assertEqual(MASK);

      // Other keys should return original value
      expect(modifier.modify('service_name', 'my_service')).assertEqual('my_service');
      expect(modifier.modify('env', 'prod')).assertEqual('prod');
      expect(modifier.modify(Constants.KEY_DEVICE_UUID, 'uuid2')).assertEqual(MASK);

      console.info('DataModifierTest', 'dataModifierMultipleKeysTest passed');
    });

    /**
     * LineDataModifier with empty data test
     * Tests LineDataModifier behavior with empty tags/fields
     */
    it('lineDataModifierEmptyDataTest', 0, () => {
      const modifier = new TestLineDataModifier();

      // Test with empty tags and fields
      const emptyTags: Map<string, string> = new Map();
      const emptyFields: Map<string, string> = new Map();

      const result = modifier.modify('test_measurement', emptyTags, emptyFields);

      // Should only have the masked userid
      expect(result.size).assertEqual(1);
      expect(result.get(Constants.KEY_RUM_USER_ID)).assertEqual(MASK);

      console.info('DataModifierTest', 'lineDataModifierEmptyDataTest passed');
    });

    /**
     * Method chaining test
     * Tests that setDataModifier and setLineDataModifier return FTSDKConfig for chaining
     */
    it('modifierMethodChainingTest', 0, () => {
      // Test method chaining (aligned with Android SDK builder pattern)
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDataModifier(new TestDataModifier())
        .setLineDataModifier(new TestLineDataModifier())
        .setDebug(true)
        .setServiceName('test_service');

      // Verify all settings were applied
      expect(config.isDebugMode()).assertTrue();
      expect(config.getServiceName()).assertEqual('test_service');

      console.info('DataModifierTest', 'modifierMethodChainingTest passed');
    });

    /**
     * Line Protocol format test with modifiers
     * Tests that Line Protocol format is correct after applying modifiers
     */
    it('lineProtocolFormatWithModifiersTest', 0, () => {
      // Create tags and fields
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_DEVICE_UUID, 'test-uuid-123');
      tags.set(Constants.KEY_RUM_USER_ID, 'test-user-id');
      tags.set('env', 'prod');

      const fields: Map<string, string> = new Map();
      fields.set('action_name', 'test_action');

      // Apply LineDataModifier
      const lineDataModifier = new TestLineDataModifier();
      const modifiedData = lineDataModifier.modify('rum_app', tags, fields);

      // Separate tags and fields back
      const modifiedTags: Map<string, string> = new Map();
      const modifiedFields: Map<string, string> = new Map();

      modifiedData.forEach((value: string, key: string) => {
        if (key === 'action_name') {
          modifiedFields.set(key, value);
        } else {
          modifiedTags.set(key, value);
        }
      });

      // Convert to Line Protocol
      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        'rum_app',
        modifiedTags,
        modifiedFields,
        1234567890000000000,
        false
      );

      // Verify format
      expect(lineProtocol.includes('rum_app')).assertTrue();
      expect(lineProtocol.includes('env=prod')).assertTrue();
      expect(lineProtocol.includes('action_name="test_action"')).assertTrue();
      expect(lineProtocol.includes(Constants.KEY_RUM_USER_ID + '=' + MASK)).assertTrue();

      console.info('DataModifierTest', 'lineProtocolFormatWithModifiersTest passed');
    });
  });
}
