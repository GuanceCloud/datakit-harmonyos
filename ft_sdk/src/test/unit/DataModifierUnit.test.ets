import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import { FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { DataType } from '../../main/ets/components/enum/Enums';
import { DataModifier, DataModifierValue, LineDataModifier } from '../../main/ets/components/DataModifier';
import { FTDataFilter } from '../../main/ets/components/FTDataFilter';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_MASK_VALUE = 'xxx';

class MaskingLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> {
    const result = new Map<string, DataModifierValue>();
    result.set(Constants.KEY_RUM_USER_ID, TEST_MASK_VALUE);
    result.set('message', TEST_MASK_VALUE);
    return result;
  }
}

class NoopLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    return null;
  }
}

class FinalValueLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> {
    const result = new Map<string, DataModifierValue>();
    result.set(Constants.KEY_SESSION_SAMPLE_RATE, 'line-masked-rate');
    result.set(Constants.KEY_SERVICE, 'line-masked-service');
    result.set(Constants.KEY_SDK_VERSION, 'line-masked-version');
    result.set('new_field', 'must-not-be-added');
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

    it('filterReadsModifiedValues', 0, () => {
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

    it('lineModifierShouldTreatNullAsNoChange', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new NoopLineDataModifier());
      const fields = new Map<string, string>();
      fields.set('message', 'original-message');

      helper.initBaseConfig(config);
      const lineProtocol = helper.getBodyContent(
        'custom_log',
        new Map<string, string>(),
        fields,
        1234567890,
        DataType.LOG,
        'uuid-line-noop'
      );

      expect(lineProtocol.includes('message="original-message"')).assertTrue();
    });

    it('lineModifierKeepsNativeAndWebValues', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new FinalValueLineDataModifier());
      helper.initBaseConfig(config);
      helper.initRUMConfig(new FTRUMConfig().setSamplingRate(0.5));

      const rumFields = new Map<string, string>();
      rumFields.set('message', 'native-rum-message');
      const rumLineProtocol = helper.getBodyContent(
        'rum_action',
        new Map<string, string>(),
        rumFields,
        1234567890,
        DataType.RUM_APP,
        'uuid-line-rum'
      );

      const webTags = new Map<string, string>();
      webTags.set(Constants.KEY_SERVICE, 'browser');
      webTags.set(Constants.KEY_SDK_VERSION, 'web-original-version');
      const webFields = new Map<string, string>();
      webFields.set('message', 'webview-message');
      const webLineProtocol = helper.getBodyContent(
        'browser_sdk',
        webTags,
        webFields,
        1234567890,
        DataType.RUM_WEBVIEW,
        'uuid-line-webview'
      );

      expect(rumLineProtocol.includes(`${Constants.KEY_SESSION_SAMPLE_RATE}="line-masked-rate"`)).assertTrue();
      expect(webLineProtocol.includes(`${Constants.KEY_SERVICE}=line-masked-service`)).assertTrue();
      expect(webLineProtocol.includes(`${Constants.KEY_SDK_VERSION}=line-masked-version`)).assertTrue();
      expect(webLineProtocol.includes('new_field')).assertFalse();
    });

    it('modifierMasksDirectAndWorkerData', 0, () => {
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

    it('modifierHandlesNativeAndWebRum', 0, () => {
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
