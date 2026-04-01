/**
 * Data integer compatible test cases
 * Adapted from Android SDK: com.ft.sdk.tests.DataIntegerCompatibleTest
 *
 * Purpose: Test the effect of enabling/disabling FTSDKConfig.enableDataIntegerCompatible()
 *
 * When enabled, integer values are output without "i" suffix in Line Protocol
 * When disabled (default), integer values are output with "i" suffix
 *
 * Note: In ohosTest environment, we cannot test actual database operations.
 * This test focuses on configuration API validation.
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { SyncDataHelper } from '../../../main/ets/components/SyncDataHelper';

// Test constants
const TEST_FAKE_URL = 'http://www.test.url';

export default function dataIntegerCompatibleTest() {
  describe('DataIntegerCompatibleTest', () => {
    beforeAll(() => {
      console.info('DataIntegerCompatibleTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('DataIntegerCompatibleTest', 'beforeEach called');
    });

    afterEach(() => {
      console.info('DataIntegerCompatibleTest', 'afterEach called');
    });

    afterAll(() => {
      console.info('DataIntegerCompatibleTest', 'afterAll called');
    });

    /**
     * Default configuration test
     * Expected: isDataIntegerCompatible() returns false by default
     * Aligned with Android: defaultConfig()
     */
    it('defaultConfig', 0, () => {
      // Create config with default settings
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);

      // Verify default value is false (not compatible)
      const isEnabled: boolean = config.isDataIntegerCompatible();
      expect(isEnabled).assertFalse();

      console.info('DataIntegerCompatibleTest', 'defaultConfig passed');
    });

    /**
     * Enable compatible mode test
     * Expected: isDataIntegerCompatible() returns true after enableDataIntegerCompatible()
     * Aligned with Android: enableCompatible()
     */
    it('enableCompatible', 0, () => {
      // Create config with data integer compatible enabled
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableDataIntegerCompatible();

      // Verify it's enabled
      const isEnabled: boolean = config.isDataIntegerCompatible();
      expect(isEnabled).assertTrue();

      console.info('DataIntegerCompatibleTest', 'enableCompatible passed');
    });

    /**
     * Method chaining test
     */
    it('methodChaining', 0, () => {
      // Test that enableDataIntegerCompatible() returns FTSDKConfig for chaining
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableDataIntegerCompatible()
        .setDebug(true)
        .setServiceName('test_service');

      // Verify all settings were applied
      const isEnabled: boolean = config.isDataIntegerCompatible();
      const isDebug: boolean = config.isDebugMode();
      const serviceName: string = config.getServiceName();

      expect(isEnabled).assertTrue();
      expect(isDebug).assertTrue();
      expect(serviceName).assertEqual('test_service');

      console.info('DataIntegerCompatibleTest', 'methodChaining passed');
    });

    /**
     * Line Protocol format test - default mode
     * Expected: integer values are formatted with "i" suffix
     */
    it('lineProtocolFormatDefault', 0, () => {
      // Create fields map with integer value
      const fields: Map<string, string> = new Map();
      fields.set("integer_value", "1");
      fields.set("float_value", "3.14");

      // Convert to line protocol with default (integerCompatible = false)
      const lineProtocol: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        false // integerCompatible = false (default)
      );

      // Verify integer has "i" suffix (aligned with Android: "1i")
      expect(lineProtocol.includes("integer_value=1i")).assertTrue();

      // Verify float doesn't have "i" suffix
      expect(lineProtocol.includes("float_value=3.14")).assertTrue();
      const hasFloatI: boolean = lineProtocol.includes("float_value=3.14i");
      expect(hasFloatI).assertFalse();

      console.info('DataIntegerCompatibleTest', 'lineProtocolFormatDefault passed');
    });

    /**
     * Line Protocol format test - compatible mode
     * Expected: integer values are formatted without "i" suffix
     */
    it('lineProtocolFormatCompatible', 0, () => {
      // Create fields map with integer value
      const fields: Map<string, string> = new Map();
      fields.set("integer_value", "1");
      fields.set("float_value", "3.14");

      // Convert to line protocol with compatible mode enabled
      const lineProtocol: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        true // integerCompatible = true
      );

      // Verify integer does NOT have "i" suffix
      const hasIntegerI: boolean = lineProtocol.includes("integer_value=1i");
      expect(hasIntegerI).assertFalse();

      const hasInteger: boolean = lineProtocol.includes("integer_value=1");
      expect(hasInteger).assertTrue();

      // Verify float doesn't have "i" suffix (same as default)
      expect(lineProtocol.includes("float_value=3.14")).assertTrue();
      const hasFloatI: boolean = lineProtocol.includes("float_value=3.14i");
      expect(hasFloatI).assertFalse();

      console.info('DataIntegerCompatibleTest', 'lineProtocolFormatCompatible passed');
    });

    /**
     * Test multiple integer values in compatible mode
     */
    it('multipleIntegerValues', 0, () => {
      // Create fields map with multiple integer values
      const fields: Map<string, string> = new Map();
      fields.set("int_small", "0");
      fields.set("int_positive", "1");
      fields.set("int_negative", "-1");
      fields.set("int_large", "999");

      // Convert to line protocol with compatible mode
      const lineProtocol: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        true // integerCompatible = true
      );

      // Verify none have "i" suffix
      const hasSmallI: boolean = lineProtocol.includes("int_small=0i");
      expect(hasSmallI).assertFalse();

      const hasPosI: boolean = lineProtocol.includes("int_positive=1i");
      expect(hasPosI).assertFalse();

      const hasNegI: boolean = lineProtocol.includes("int_negative=-1i");
      expect(hasNegI).assertFalse();

      const hasLargeI: boolean = lineProtocol.includes("int_large=999i");
      expect(hasLargeI).assertFalse();

      // Verify all exist without "i" suffix
      expect(lineProtocol.includes("int_small=0")).assertTrue();
      expect(lineProtocol.includes("int_positive=1")).assertTrue();
      expect(lineProtocol.includes("int_negative=-1")).assertTrue();
      expect(lineProtocol.includes("int_large=999")).assertTrue();

      console.info('DataIntegerCompatibleTest', 'multipleIntegerValues passed');
    });

    /**
     * Test zero value special case
     */
    it('zeroValueHandling', 0, () => {
      // Create fields map with zero
      const fields: Map<string, string> = new Map();
      fields.set("zero_value", "0");

      // Default mode
      const lineProtocolDefault: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        false // default mode
      );

      const hasZeroI: boolean = lineProtocolDefault.includes("zero_value=0i");
      expect(hasZeroI).assertTrue();

      // Compatible mode
      const lineProtocolCompatible: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        true // compatible mode
      );

      const hasZeroCompatI: boolean = lineProtocolCompatible.includes("zero_value=0i");
      expect(hasZeroCompatI).assertFalse();

      const hasZeroCompat: boolean = lineProtocolCompatible.includes("zero_value=0");
      expect(hasZeroCompat).assertTrue();

      console.info('DataIntegerCompatibleTest', 'zeroValueHandling passed');
    });

    /**
     * Test that float values are not affected by the setting
     */
    it('floatValuesUnaffected', 0, () => {
      // Create fields map with float values
      const fields: Map<string, string> = new Map();
      fields.set("float1", "3.14");
      fields.set("float2", "0.0");
      fields.set("float3", "-2.5");

      // Both modes should produce the same output for floats
      const lineProtocolDefault: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        false // default mode
      );

      const lineProtocolCompatible: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        true // compatible mode
      );

      // Floats should not have "i" suffix in either mode
      const hasDefault1I: boolean = lineProtocolDefault.includes("float1=3.14i");
      expect(hasDefault1I).assertFalse();

      const hasCompat1I: boolean = lineProtocolCompatible.includes("float1=3.14i");
      expect(hasCompat1I).assertFalse();

      const hasDefault2I: boolean = lineProtocolDefault.includes("float2=0.0i");
      expect(hasDefault2I).assertFalse();

      const hasCompat2I: boolean = lineProtocolCompatible.includes("float2=0.0i");
      expect(hasCompat2I).assertFalse();

      console.info('DataIntegerCompatibleTest', 'floatValuesUnaffected passed');
    });

    /**
     * Test config integration with line protocol generation
     */
    it('configIntegration', 0, () => {
      // Create config with data integer compatible enabled
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .enableDataIntegerCompatible();

      // Verify config setting
      const isEnabled: boolean = config.isDataIntegerCompatible();
      expect(isEnabled).assertTrue();

      // Create test fields
      const fields: Map<string, string> = new Map();
      fields.set("test_value", "1");

      // Generate line protocol using config value
      const lineProtocol: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        config.isDataIntegerCompatible() // use config value
      );

      // Verify compatible mode is respected
      const hasSuffix: boolean = lineProtocol.includes("test_value=1i");
      expect(hasSuffix).assertFalse();

      const hasNoSuffix: boolean = lineProtocol.includes("test_value=1");
      expect(hasNoSuffix).assertTrue();

      console.info('DataIntegerCompatibleTest', 'configIntegration passed');
    });

    /**
     * Test negative integer values
     */
    it('negativeIntegerValues', 0, () => {
      // Create fields map with negative integer values
      const fields: Map<string, string> = new Map();
      fields.set("neg_small", "-1");
      fields.set("neg_large", "-2");

      // Default mode - should have "i" suffix
      const lineProtocolDefault: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        false
      );

      const hasNegSmallI: boolean = lineProtocolDefault.includes("neg_small=-1i");
      expect(hasNegSmallI).assertTrue();

      const hasNegLargeI: boolean = lineProtocolDefault.includes("neg_large=-2i");
      expect(hasNegLargeI).assertTrue();

      // Compatible mode - should NOT have "i" suffix
      const lineProtocolCompatible: string = SyncDataHelper.convertToLineProtocolLine(
        "test_measurement",
        new Map(),
        fields,
        1234567890000000000,
        true
      );

      const hasNegSmallCompatI: boolean = lineProtocolCompatible.includes("neg_small=-1i");
      expect(hasNegSmallCompatI).assertFalse();

      const hasNegLargeCompatI: boolean = lineProtocolCompatible.includes("neg_large=-2i");
      expect(hasNegLargeCompatI).assertFalse();

      console.info('DataIntegerCompatibleTest', 'negativeIntegerValues passed');
    });

    /**
     * Test toggle behavior
     */
    it('toggleBehavior', 0, () => {
      // Create config with default settings
      const config: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL);

      // Initially should be false
      let isEnabled: boolean = config.isDataIntegerCompatible();
      expect(isEnabled).assertFalse();

      // Enable it
      config.enableDataIntegerCompatible();
      isEnabled = config.isDataIntegerCompatible();
      expect(isEnabled).assertTrue();

      // Note: There's no disable method in Android SDK either
      // Once enabled, it stays enabled

      console.info('DataIntegerCompatibleTest', 'toggleBehavior passed');
    });
  });
}
