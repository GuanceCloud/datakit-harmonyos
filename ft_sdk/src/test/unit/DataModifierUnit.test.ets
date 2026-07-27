import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import { FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { DataType } from '../../main/ets/components/enum/Enums';
import { DataModifier, DataModifierValue, LineDataModifier } from '../../main/ets/components/DataModifier';
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

class MaskingDataModifier implements DataModifier {
  modify(key: string, _value: DataModifierValue): DataModifierValue | null {
    if (key === 'secret_tag' || key === 'secret_field' || key === Constants.KEY_SESSION_SAMPLE_RATE) {
      return TEST_MASK_VALUE;
    }
    if (key === 'response_status') {
      return 204;
    }
    return null;
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

    it('dataModifierShouldMaskRawDataInDirectAndWorkerPaths', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setDataModifier(new MaskingDataModifier());
      const tags: Map<string, string> = new Map();
      tags.set('secret_tag', 'original-tag');
      const fields: Map<string, string> = new Map();
      fields.set('secret_field', 'original-field');
      fields.set('response_status', '500');

      helper.initBaseConfig(config);
      const directLineProtocol = helper.getBodyContent(
        'custom_log',
        tags,
        fields,
        1234567890,
        DataType.LOG,
        'uuid-data-modifier'
      );
      const prepared = helper.prepareLineProtocolContent(
        'custom_log',
        tags,
        fields,
        1234567890,
        DataType.LOG,
        'uuid-data-modifier'
      );

      expect(directLineProtocol.includes('secret_tag=xxx')).assertTrue();
      expect(directLineProtocol.includes('secret_field="xxx"')).assertTrue();
      expect(directLineProtocol.includes('response_status=204i')).assertTrue();
      expect(prepared.tags['secret_tag']).assertEqual(TEST_MASK_VALUE);
      expect(prepared.fields['secret_field']).assertEqual(TEST_MASK_VALUE);
      expect(prepared.fields['response_status']).assertEqual('204');
      expect(tags.get('secret_tag')).assertEqual('original-tag');
      expect(fields.get('secret_field')).assertEqual('original-field');
    });

    it('dataModifierShouldCoverNativeRumAndWebViewRawData', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setDataModifier(new MaskingDataModifier());
      helper.initBaseConfig(config);
      helper.initRUMConfig(new FTRUMConfig().setSamplingRate(0.5));

      const rumFields: Map<string, string> = new Map();
      rumFields.set('secret_field', 'native-rum-secret');
      const rumLineProtocol = helper.getBodyContent(
        'rum_action',
        new Map<string, string>(),
        rumFields,
        1234567890,
        DataType.RUM_APP,
        'uuid-rum-data-modifier'
      );

      const webTags: Map<string, string> = new Map();
      webTags.set('secret_tag', 'webview-secret');
      const webFields: Map<string, string> = new Map();
      webFields.set('secret_field', 'webview-field-secret');
      const webLineProtocol = helper.getBodyContent(
        'browser_sdk',
        webTags,
        webFields,
        1234567890,
        DataType.RUM_WEBVIEW,
        'uuid-web-data-modifier'
      );

      expect(rumLineProtocol.includes('secret_field="xxx"')).assertTrue();
      expect(rumLineProtocol.includes(`${Constants.KEY_SESSION_SAMPLE_RATE}="xxx"`)).assertTrue();
      expect(webLineProtocol.includes('secret_tag=xxx')).assertTrue();
      expect(webLineProtocol.includes('secret_field="xxx"')).assertTrue();
    });
  });
}
