/**
 * Special character conversion verification for line protocol transmission data
 * Reference: com.ft.sdk.tests.LineProtocolEscapeTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';

export default function lineProtocolEscapeTest() {
  describe('LineProtocolEscape', () => {
    // Test data constants - exactly same as Android SDK
    const NEED_ESCAPE_STRING = "\"Test log\\,\\\\=";

    const FIELD_RESULT = "\"\\\"Test log\\\\,\\\\\\\\=\"";
    const MEASUREMENT_RESULT = "\"Test\\ log\\,=";
    const TAG_RESULT = "\"Test\\ log\\,\\=";

    const JSON_STRING = "{\"key\":\"value\",\"jsonString\":\"{\\\"key\\\":\\\"value\\\"}\"}";
    const MIX_FIELD = JSON_STRING + NEED_ESCAPE_STRING;
    const MIXED_RESULT = "\"{\\\"key\\\":\\\"value\\\",\\\"jsonString\\\":\\\"{\\\\\\\"key\\\\\\\":\\\\\\\"value\\\\\\\"}\\\"}\\\"Test log\\\\,\\\\\\\\=\"";

    /**
     * Whether special characters in field are correctly escaped in line protocol
     */
    it('escapeStringFields', 0, () => {
      const fieldValue = SyncDataHelper.translateFieldValue(NEED_ESCAPE_STRING);
      expect(fieldValue).assertEqual(FIELD_RESULT);
      console.info('LineProtocolEscapeTest', 'fieldEscape passed');
    });

    /**
     * Whether field in json format is correctly escaped in line protocol
     */
    it('escapeJsonFields', 0, () => {
      const fieldValue = SyncDataHelper.translateFieldValue(JSON_STRING);
      // Android uses JSONObject.quote(JSON_STRING) which wraps in quotes and escapes
      const quoted = '"{\\"key\\":\\"value\\",\\"jsonString\\":\\"{\\\\\\"key\\\\\\":\\\\\\"value\\\\\\"}\\"}"';
      expect(fieldValue).assertEqual(quoted);
      console.info('LineProtocolEscapeTest', 'fieldEscapeJson passed');
    });

    /**
     * Whether field is correctly escaped in mixed data in line protocol
     */
    it('escapeMixedStringFields', 0, () => {
      const fieldValue = SyncDataHelper.translateFieldValue(MIX_FIELD);
      expect(fieldValue).assertEqual(MIXED_RESULT);
      console.info('LineProtocolEscapeTest', 'fieldEscapeMixString passed');
    });

    /**
     * Whether special characters in measurement are correctly escaped in line protocol
     */
    it('escapeMeasurements', 0, () => {
      const measureValue = SyncDataHelper.translateMeasurements(NEED_ESCAPE_STRING);
      expect(measureValue).assertEqual(MEASUREMENT_RESULT);
      console.info('LineProtocolEscapeTest', 'measurementEscape passed');
    });

    /**
     * Whether special characters in tag are correctly escaped in line protocol
     */
    it('escapeTagValues', 0, () => {
      const tagValue = SyncDataHelper.translateTagKeyValue(NEED_ESCAPE_STRING);
      expect(tagValue).assertEqual(TAG_RESULT);
      console.info('LineProtocolEscapeTest', 'tagEscape passed');
    });
  });
}
