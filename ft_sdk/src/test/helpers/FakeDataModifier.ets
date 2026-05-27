import { Constants } from '../../main/ets/components/Constants';
import { DataModifier, LineDataModifier } from '../../main/ets/components/DataModifier';

export const TEST_MASK_VALUE = 'xxx';

export class FakeDataModifier implements DataModifier {
  modify(key: string, value: string): string {
    if (key === Constants.KEY_DEVICE_UUID) {
      return TEST_MASK_VALUE;
    }
    return value;
  }
}

export class FakeLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result: Map<string, string> = new Map();
    tags.forEach((value: string, key: string) => result.set(key, value));
    fields.forEach((value: string, key: string) => result.set(key, value));
    result.set(Constants.KEY_RUM_USER_ID, TEST_MASK_VALUE);
    return result;
  }
}
