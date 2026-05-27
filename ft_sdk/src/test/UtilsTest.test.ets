/**
 * Miscellaneous tests
 * Reference: com.ft.sdk.tests.UtilsTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { SyncDataHelper } from '../main/ets/components/SyncDataHelper';
import { Constants } from '../main/ets/components/Constants';

export default function utilsTest() {
  describe('UtilsTest', () => {
    // Test constants - exactly same as Android SDK
    const TEST_MEASUREMENT_INFLUX_DB_LINE = "TestInfluxDBLine";
    const KEY_TAGS = "tags1";
    const KEY_TAGS_EMPTY = "tagEmpty";
    const KEY_FIELD = "field1";
    const KEY_FIELD_EMPTY = "fieldEmpty";
    const VALUE_TAGS = "tags1-value";
    const VALUE_TAGS_EMPTY = "";
    const VALUE_FIELD = "field1-value";
    const VALUE_FIELD_EMPTY = "";
    const VALUE_TIME = 1598512145640000000;

    /**
     * Normal line protocol data
     * Note: convertToLineProtocolLine returns a single line WITHOUT trailing newline.
     * Newlines are added when joining multiple lines for batch upload (see SyncTaskManager.formatLineProtocolData).
     */
    const SINGLE_LINE_NORMAL_DATA = TEST_MEASUREMENT_INFLUX_DB_LINE + "," +
      KEY_TAGS + "=" + VALUE_TAGS + " " +
      KEY_FIELD + "=\"" + VALUE_FIELD + "\" " +
      VALUE_TIME;

    /**
     * Empty line protocol data
     * Note: convertToLineProtocolLine returns a single line WITHOUT trailing newline.
     * Empty field values are skipped in getCustomHash(), so no field output is expected.
     * Only measurement and timestamp remain after removing sdk_data_id tag.
     */
    const SINGLE_LINE_EMPTY_DATA = TEST_MEASUREMENT_INFLUX_DB_LINE + " " +
      VALUE_TIME;

    /**
     * Merge normal line protocol and empty line protocol data to form three lines of data
     */
    const LOG_EXPECT_DATA = SINGLE_LINE_NORMAL_DATA + SINGLE_LINE_NORMAL_DATA + SINGLE_LINE_NORMAL_DATA;

    beforeAll(() => {
      console.info('UtilsTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('UtilsTest', 'beforeEach called');
    });

    afterEach(() => {
      console.info('UtilsTest', 'afterEach called');
    });

    afterAll(() => {
      console.info('UtilsTest', 'afterAll called');
    });

    /**
     * Multi-line data validation, verify whether data errors occur during the data conversion
     * Aligned with Android's multiLineProtocolFormatTest
     */
    it('multiLineProtocolFormatTest', 0, () => {
      // Create tags map
      const tags: Map<string, string> = new Map();
      tags.set(KEY_TAGS, VALUE_TAGS);

      // Create fields map
      const fields: Map<string, string> = new Map();
      fields.set(KEY_FIELD, VALUE_FIELD);

      // Convert to line protocol line
      const lineData = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT_INFLUX_DB_LINE,
        tags,
        fields,
        VALUE_TIME,
        false
      );

      // Verify the line data format
      expect(lineData).assertEqual(SINGLE_LINE_NORMAL_DATA);

      console.info('UtilsTest', 'multiLineProtocolFormatTest passed');
    });

    /**
     * Single data validation, whether data errors occur during the data conversion process
     * Aligned with Android's singleLineProtocolFormatTest
     */
    it('singleLineProtocolFormatTest', 0, () => {
      // Create tags map
      const tags: Map<string, string> = new Map();
      tags.set(KEY_TAGS, VALUE_TAGS);

      // Create fields map
      const fields: Map<string, string> = new Map();
      fields.set(KEY_FIELD, VALUE_FIELD);

      // Convert to line protocol line
      const content = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT_INFLUX_DB_LINE,
        tags,
        fields,
        VALUE_TIME,
        false
      );

      // Remove sdk_data_id flag for comparison (aligned with Android)
      // Android: content.replaceFirst("(" + Constants.KEY_SDK_DATA_FLAG + "=)(.*),", "")
      const contentWithoutFlag = content.replace(new RegExp(Constants.KEY_SDK_DATA_FLAG + "=[^,]+,"), "");

      // Verify format matches expected
      expect(contentWithoutFlag).assertEqual(SINGLE_LINE_NORMAL_DATA);

      // Test with empty values
      const tagsEmpty: Map<string, string> = new Map();
      tagsEmpty.set(KEY_TAGS_EMPTY, VALUE_TAGS_EMPTY);

      const fieldsEmpty: Map<string, string> = new Map();
      fieldsEmpty.set(KEY_FIELD_EMPTY, VALUE_FIELD_EMPTY);

      const contentEmpty = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT_INFLUX_DB_LINE,
        tagsEmpty,
        fieldsEmpty,
        VALUE_TIME,
        false
      );

      // Remove sdk_data_id flag for comparison
      const contentEmptyWithoutFlag = contentEmpty.replace(new RegExp(",\\s?" + Constants.KEY_SDK_DATA_FLAG + "=[\\w\\d]+"), "");

      expect(contentEmptyWithoutFlag).assertEqual(SINGLE_LINE_EMPTY_DATA);

      console.info('UtilsTest', 'singleLineProtocolFormatTest passed');
    });

    /**
     * Test translateFieldValue method
     */
    it('testTranslateFieldValue', 0, () => {
      const testString = "test value";
      const result = SyncDataHelper.translateFieldValue(testString);
      expect(result).assertEqual('"test value"');

      // Test with special characters
      const specialString = "test\nvalue";
      const specialResult = SyncDataHelper.translateFieldValue(specialString);
      expect(specialResult).assertEqual('"test\nvalue"');

      console.info('UtilsTest', 'testTranslateFieldValue passed');
    });

    /**
     * Test translateMeasurements method
     */
    it('testTranslateMeasurements', 0, () => {
      const testString = "test,measurement";
      const result = SyncDataHelper.translateMeasurements(testString);
      expect(result).assertEqual('test\\,measurement');

      console.info('UtilsTest', 'testTranslateMeasurements passed');
    });

    /**
     * Test translateTagKeyValue method
     */
    it('testTranslateTagKeyValue', 0, () => {
      const testString = "test=value=with=equals";
      const result = SyncDataHelper.translateTagKeyValue(testString);
      expect(result).assertEqual('test\\=value\\=with\\=equals');

      console.info('UtilsTest', 'testTranslateTagKeyValue passed');
    });
  });
}
