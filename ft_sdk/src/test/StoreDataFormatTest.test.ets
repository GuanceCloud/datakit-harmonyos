/**
 * Illegal character validation
 * Reference: com.ft.sdk.tests.StoreDataFormatTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';

/**
 * Determine whether it is a valid Values
 * @param jsonObject JSON object to check
 * @returns true if valid
 */
function isLegalValues(jsonObject: Record<string, Object> | null): boolean {
  if (jsonObject === null) {
    return false;
  }
  // Check if object has at least one key
  const keys = Object.keys(jsonObject);
  if (keys.length > 0) {
    return true;
  } else {
    return false;
  }
}

export default function storeDataFormatTest() {
  describe('StoreDataFormat', () => {

    /**
     * Empty data validity verification
     */
    it('isLegalValues', 0, () => {
      const result = isLegalValues(null);
      expect(result).assertFalse();
      console.info('StoreDataFormatTest', 'isLegalValues passed');
    });

    /**
     * String type data validity verification
     */
    it('isLegalValues1', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = '1';
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues1 passed');
    });

    /**
     * JSON object data validity verification (number type)
     */
    it('isLegalValues2', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = 2;
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues2 passed');
    });

    /**
     * Boolean type data validity verification
     */
    it('isLegalValues3', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = true;
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues3 passed');
    });

    /**
     * JSON object data validity verification (empty object)
     */
    it('isLegalValues4', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const emptyObj: Record<string, Object> = {};
      jsonObject['test'] = emptyObj;
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues4 passed');
    });

    /**
     * JSON object data validity verification (nested object)
     */
    it('isLegalValues5', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const jsonObject1: Record<string, Object> = {};
      jsonObject1['subTest'] = 'jack';
      jsonObject['test'] = jsonObject1;
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues5 passed');
    });

    /**
     * JSON array data validity verification
     */
    it('isLegalValues6', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const jsonArray: Object[] = [];
      jsonObject['test'] = jsonArray;
      const result = isLegalValues(jsonObject);
      expect(result).assertTrue();
      console.info('StoreDataFormatTest', 'isLegalValues6 passed');
    });
  });
}
