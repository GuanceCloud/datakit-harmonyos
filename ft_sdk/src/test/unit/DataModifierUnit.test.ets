import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { DataType } from '../../main/ets/components/enum/Enums';
import { LineDataModifier } from '../../main/ets/components/DataModifier';
import { FTDataFilter } from '../../main/ets/components/FTDataFilter';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_MASK_VALUE = 'xxx';

class MaskingLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result: Map<string, string> = new Map();
    tags.forEach((value: string, key: string) => result.set(key, value));
    fields.forEach((value: string, key: string) => result.set(key, value));
    result.set(Constants.KEY_RUM_USER_ID, TEST_MASK_VALUE);
    result.set('message', TEST_MASK_VALUE);
    return result;
  }
}

export default function dataModifierUnitTest() {
  describe('DataModifierUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('modifierShouldAffectLineProtocol', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new MaskingLineDataModifier());
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_RUM_USER_ID, 'original-user-id');
      tags.set('env', 'prod');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'sensitive-message');

      helper.initBaseConfig(config);
      const lineProtocol = helper.getBodyContent('rum_app', tags, fields, 1234567890, DataType.LOG, 'uuid-log-modifier');

      expect(lineProtocol.includes(`${Constants.KEY_RUM_USER_ID}=${TEST_MASK_VALUE}`)).assertTrue();
      expect(lineProtocol.includes('message="xxx"')).assertTrue();
      expect(lineProtocol.includes('original-user-id')).assertFalse();
      expect(lineProtocol.includes('sensitive-message')).assertFalse();
      expect(lineProtocol.includes('env=prod')).assertTrue();
    });

    it('localDataFilterShouldReadValuesAfterLineModifier', 0, () => {
      const helper = new SyncDataHelper();
      const rules = new Map<string, Array<string>>();
      rules.set('logging', ["{ message in ['xxx'] }"]);
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new MaskingLineDataModifier())
        .setDataFilters(rules);
      const fields = new Map<string, string>();
      fields.set('message', 'sensitive-message');

      helper.initBaseConfig(config);
      const lineProtocol = helper.getBodyContent(
        'df_rum_harmonyos_log', new Map<string, string>(), fields, 1234567890, DataType.LOG, 'uuid-filter-order'
      );
      const filter = FTDataFilter.compile(config.getDataFilters());

      expect(lineProtocol.includes('message="xxx"')).assertTrue();
      expect(filter.isFilteredLine(DataType.LOG, lineProtocol)).assertTrue();
    });
  });
}
