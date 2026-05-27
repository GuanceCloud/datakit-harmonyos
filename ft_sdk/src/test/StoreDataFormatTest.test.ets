/**
 * Illegal character validation
 * Reference: com.ft.sdk.tests.StoreDataFormatTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, it, expect } from '@ohos/hypium';

class JsonArrayValue {
  public value: Object;

  constructor(value: Object) {
    this.value = value;
  }
}

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

    it('nullValuesShouldBeInvalid', 0, () => {
      expect(isLegalValues(null)).assertFalse();
    });

    it('emptyObjectShouldBeInvalid', 0, () => {
      expect(isLegalValues({})).assertFalse();
    });

    it('stringValueShouldBeValid', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = '1';

      expect(isLegalValues(jsonObject)).assertTrue();
    });

    it('numberValueShouldBeValid', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = 2;

      expect(isLegalValues(jsonObject)).assertTrue();
    });

    it('booleanValueShouldBeValid', 0, () => {
      const jsonObject: Record<string, Object> = {};
      jsonObject['test'] = true;

      expect(isLegalValues(jsonObject)).assertTrue();
    });

    it('emptyObjectValueShouldBeValidWhenParentHasKey', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const emptyObject: Record<string, Object> = {};
      jsonObject['test'] = emptyObject;

      expect(isLegalValues(jsonObject)).assertTrue();
      expect(Object.keys(jsonObject['test'] as Record<string, Object>).length).assertEqual(0);
    });

    it('nestedObjectValueShouldBeValid', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const jsonObject1: Record<string, Object> = {};
      jsonObject1['subTest'] = 'jack';
      jsonObject['test'] = jsonObject1;

      expect(isLegalValues(jsonObject)).assertTrue();
      expect((jsonObject['test'] as Record<string, Object>)['subTest']).assertEqual('jack');
    });

    it('arrayValueShouldBeValid', 0, () => {
      const jsonObject: Record<string, Object> = {};
      const jsonArray: Object[] = [];
      jsonArray.push(new JsonArrayValue('first' as Object));
      jsonArray.push(new JsonArrayValue(2 as Object));
      jsonObject['test'] = jsonArray;

      expect(isLegalValues(jsonObject)).assertTrue();
      expect((jsonObject['test'] as Object[]).length).assertEqual(2);
    });
  });
}
